#!/usr/bin/env bash
# Smoke test for scripts/round-state-render-ac.sh. Bash 3.2 compatible.
# The round-trip case is the regression guard for #159's copy-drift problem:
# render output must satisfy prompt-ac-check.sh verbatim.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RENDER="$SCRIPT_DIR/../round-state-render-ac.sh"
AC_CHECK="$SCRIPT_DIR/../prompt-ac-check.sh"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURE="$ROOT/schemas/fixtures/round_state.valid.json"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
FAILURES=0

pass() { echo "ok   - $1"; }
fail() { echo "NOT OK - $1"; FAILURES=$((FAILURES + 1)); }

# Canonical state at revision 5 with criteria deliberately stored in reversed
# (statement-first) key order: render must normalize to id-first output.
STATE="$TMP_DIR/state.json"
node - "$FIXTURE" "$STATE" <<'NODE'
const fs = require("fs");
const [fixture, out] = process.argv.slice(2);
const state = JSON.parse(fs.readFileSync(fixture, "utf8"));
state.revision = 5;
state.acceptance.criteria = [
  { statement: "the first observable completion condition", id: "AC-5-1" },
  { statement: "the second observable completion condition", id: "AC-5-2" }
];
fs.writeFileSync(out, JSON.stringify(state));
NODE

OUT="$TMP_DIR/block.md"
if bash "$RENDER" --round-state "$STATE" >"$OUT" 2>"$TMP_DIR/render.err"; then
  pass "render exits 0 for a schema-valid ROUND-STATE"
else
  fail "render exits 0 for a schema-valid ROUND-STATE (err=$(cat "$TMP_DIR/render.err"))"
fi

shape_ok=1
head -1 "$OUT" | grep -F -q '<!-- agent-workflow:ac-block:start -->' || shape_ok=0
tail -1 "$OUT" | grep -F -q '<!-- agent-workflow:ac-block:end -->' || shape_ok=0
grep -F -q '```json' "$OUT" || shape_ok=0
# key order: every object must serialize id before statement
node - "$OUT" <<'NODE' || shape_ok=0
const fs = require("fs");
const body = fs.readFileSync(process.argv[2], "utf8");
const json = body.match(/```json\s*\n([\s\S]*?)\n```/)[1];
for (const entry of JSON.parse(json)) {
  const keys = Object.keys(entry);
  if (keys.length !== 2 || keys[0] !== "id" || keys[1] !== "statement") process.exit(1);
}
NODE
if [ "$shape_ok" -eq 1 ]; then pass "render emits delimiters, json fence, id-first entries"; else fail "render emits delimiters, json fence, id-first entries"; fi

# --- round-trip: render output satisfies prompt-ac-check.sh ---------------
PROMPT="$TMP_DIR/prompt.md"
{ echo "worker instructions"; cat "$OUT"; } > "$PROMPT"
if bash "$AC_CHECK" --round-state "$STATE" --manifest-revision 5 --prompt-file "$PROMPT" >"$TMP_DIR/rt.out" 2>&1; then
  pass "round-trip: prompt-ac-check accepts rendered AC block (exit 0)"
else
  fail "round-trip: prompt-ac-check accepts rendered AC block (out=$(cat "$TMP_DIR/rt.out"))"
fi

# --- fail-closed inputs ----------------------------------------------------
EMPTY="$TMP_DIR/empty-criteria.json"
node - "$STATE" "$EMPTY" <<'NODE'
const fs = require("fs");
const state = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
state.acceptance.criteria = [];
fs.writeFileSync(process.argv[3], JSON.stringify(state));
NODE
if ! bash "$RENDER" --round-state "$EMPTY" >/dev/null 2>&1; then
  pass "empty criteria array is rejected"
else
  fail "empty criteria array was accepted"
fi

NO_CRIT="$TMP_DIR/no-criteria.json"
node - "$STATE" "$NO_CRIT" <<'NODE'
const fs = require("fs");
const state = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
delete state.acceptance.criteria;
fs.writeFileSync(process.argv[3], JSON.stringify(state));
NODE
if ! bash "$RENDER" --round-state "$NO_CRIT" >/dev/null 2>&1; then
  pass "missing criteria is rejected"
else
  fail "missing criteria was accepted"
fi

printf 'not json at all' > "$TMP_DIR/broken.json"
if ! bash "$RENDER" --round-state "$TMP_DIR/broken.json" >/dev/null 2>&1; then
  pass "unparseable ROUND-STATE is rejected"
else
  fail "unparseable ROUND-STATE was accepted"
fi

BAD_SCHEMA="$TMP_DIR/bad-schema.json"
node - "$STATE" "$BAD_SCHEMA" <<'NODE'
const fs = require("fs");
const state = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
delete state.lifecycle;
fs.writeFileSync(process.argv[3], JSON.stringify(state));
NODE
if ! bash "$RENDER" --round-state "$BAD_SCHEMA" >/dev/null 2>"$TMP_DIR/bad-schema.err" \
  && grep -F -q 'schema validation failed' "$TMP_DIR/bad-schema.err"; then
  pass "schema-invalid ROUND-STATE is rejected"
else
  fail "schema-invalid ROUND-STATE was accepted (err=$(cat "$TMP_DIR/bad-schema.err"))"
fi

# --- mutation check --------------------------------------------------------
# Mutation: replace the renderer's statement passthrough with a constant, so
# the rendered block drifts from canonical ROUND-STATE. The round-trip
# prompt-ac-check case must reject the mutated render output (exit != 0),
# proving the round-trip guard actually detects AC-block drift (#159).
# The mutated copy runs from a mirrored product root so lib/ and schemas/
# still resolve.
MUT_ROOT="$TMP_DIR/mut-root"
mkdir -p "$MUT_ROOT/scripts"
ln -s "$SCRIPT_DIR/../lib" "$MUT_ROOT/scripts/lib"
ln -s "$ROOT/schemas" "$MUT_ROOT/schemas"
sed 's|statement: criterion.statement|statement: "mutated drift"|' "$RENDER" > "$MUT_ROOT/scripts/render-mutated.sh"
MUT_OUT="$TMP_DIR/block-mutated.md"
bash "$MUT_ROOT/scripts/render-mutated.sh" --round-state "$STATE" > "$MUT_OUT" 2>/dev/null
MUT_PROMPT="$TMP_DIR/prompt-mutated.md"
{ echo "worker instructions"; cat "$MUT_OUT"; } > "$MUT_PROMPT"
if ! bash "$AC_CHECK" --round-state "$STATE" --manifest-revision 5 --prompt-file "$MUT_PROMPT" >/dev/null 2>&1; then
  pass "mutation check: drifted AC statements fail the round-trip guard"
else
  fail "mutation check: round-trip guard accepted drifted statements"
fi

if [ "$FAILURES" -eq 0 ]; then echo "ALL TESTS PASS"; exit 0; fi
echo "$FAILURES CASE(S) FAILED"
exit 1
