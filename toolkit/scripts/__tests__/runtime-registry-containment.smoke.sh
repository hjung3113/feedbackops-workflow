#!/usr/bin/env bash
# AC-135 containment gate: the runtime-axis literal set (codex, claude,
# opencode, omp) may live only inside lib/runtime-registry.cjs. Mirrors the
# repository release gate's leak-detection technique: a grep-based source scan
# plus negative fixtures proving the detector actually fires, so a call site
# that revives its own case statement cannot stay green next to a passing
# registry lookup (delegation-branch false-green prevention).
# bash-3.2-compatible. Offline: exercises fakes, never a real runtime.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PRODUCT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTRY="$PRODUCT_ROOT/lib/runtime-registry.cjs"
FAILURES=0
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ok() { echo "ok   - $1"; }
not_ok() { echo "NOT OK - $1"; FAILURES=$((FAILURES + 1)); }

assert_command() {
  name="$1"
  shift
  if "$@"; then ok "$name"; else not_ok "$name"; fi
}

assert_contains() {
  name="$1"
  needle="$2"
  path="$3"
  if grep -F -q -- "$needle" "$path"; then ok "$name"; else not_ok "$name"; fi
}

assert_absent() {
  name="$1"
  needle="$2"
  path="$3"
  if grep -F -q -- "$needle" "$path"; then not_ok "$name"; else ok "$name"; fi
}

assert_equals() {
  name="$1"
  expected="$2"
  actual="$3"
  if [ "$expected" = "$actual" ]; then ok "$name"; else not_ok "$name"; fi
}

# A literal enumeration of the full runtime set — pipe-joined (case patterns,
# usage strings), whitespace-joined (for-lists), or comma-joined — as literal
# source text. A runtime value flowing through a variable does not match.
runtime_set_literal() {
  grep -E -q 'codex[[:space:]]*\|[[:space:]]*claude[[:space:]]*\|[[:space:]]*opencode[[:space:]]*\|[[:space:]]*omp' "$1" && return 0
  grep -E -q 'codex[[:space:]]+claude[[:space:]]+opencode[[:space:]]+omp' "$1" && return 0
  grep -E -q 'codex,[[:space:]]*claude,[[:space:]]*opencode,[[:space:]]*(or[[:space:]]+)?omp' "$1" && return 0
  return 1
}

CALL_SITES="$PRODUCT_ROOT/agent-workflow.sh $PRODUCT_ROOT/dispatch-core.sh $PRODUCT_ROOT/route.sh $PRODUCT_ROOT/agent-runtime.sh $PRODUCT_ROOT/agent-watchdog.sh"

# --- AC-135-1: the registry exists and owns the runtime-axis data ---

[ -f "$REGISTRY" ] && ok "AC-135-1 runtime registry exists at scripts/lib/runtime-registry.cjs" || not_ok "AC-135-1 runtime registry exists at scripts/lib/runtime-registry.cjs"
assert_equals "AC-135-1 registry lines output is the admitted runtime set" \
  "codex
claude
opencode
omp" "$(node "$REGISTRY" lines)"
assert_equals "AC-135-1 registry pipe output is the runtime enumeration" \
  "codex|claude|opencode|omp" "$(node "$REGISTRY" pipe)"
assert_equals "AC-135-1 registry default-runtime output is the documented default" \
  "codex" "$(node "$REGISTRY" default-runtime)"
assert_command "AC-135-1 registry exports RUNTIMES, stash_by table, and effort validity" \
  node - "$REGISTRY" <<'NODE'
const { RUNTIMES, STASH_BY, EFFORT_ENUMS, effortValid } = require(process.argv[2]);
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
process.exit(
  same(RUNTIMES, ["codex", "claude", "opencode", "omp"])
  && STASH_BY.codex === "runtime" && STASH_BY.claude === "watchdog" && STASH_BY.opencode === "watchdog" && STASH_BY.omp === "watchdog"
  && same(EFFORT_ENUMS.extended, ["none", "low", "medium", "high", "xhigh", "max"])
  && same(EFFORT_ENUMS.base, ["low", "medium", "high"])
  && effortValid("gpt-5.6", "none") && effortValid("gpt-5.6-sol", "xhigh") && effortValid("gpt-5-6", "max")
  && !effortValid("gpt-5.6", "turbo") && effortValid("claude-sonnet", "low") && !effortValid("claude-sonnet", "none")
  && !effortValid("claude-sonnet", "xhigh") && effortValid("gpt-5.7", "high") && !effortValid("gpt-5.7", "max")
  ? 0 : 1);
NODE
assert_command "AC-135-1 registry CLI answers membership, bin pin, and stash policy" \
  sh -c 'node "$1" is-registered codex && ! node "$1" is-registered bogus && node "$1" is-registered omp && [ "$(node "$1" stash-by codex)" = runtime ] && [ "$(node "$1" stash-by claude)" = watchdog ] && [ "$(node "$1" stash-by opencode)" = watchdog ] && [ "$(node "$1" stash-by omp)" = watchdog ] && [ "$(node "$1" bin omp)" = omp ] && AGENT_WORKFLOW_OMP_BIN=/abs/pin node "$1" bin omp | grep -F -x -q -- /abs/pin' sh "$REGISTRY"

# --- AC-142-A2a: extract-final last-match and read-error contract ---

two_match="$TMP_DIR/extract-final-two-match.ndjson"
printf '%s\n%s\n' '{"type":"result","subtype":"success","result":"first"}' '{"type":"result","subtype":"success","result":"second"}' > "$two_match"
assert_equals "AC-142-A2a-1 extract-final returns the LAST matching line's text" \
  "second" "$(node "$REGISTRY" extract-final claude "$two_match")"
node "$REGISTRY" extract-final claude "$TMP_DIR/extract-final-missing.ndjson" >"$TMP_DIR/extract-final.err" 2>&1
ef_ec=$?
if [ "$ef_ec" -eq 3 ] && [ "$(wc -l < "$TMP_DIR/extract-final.err" | tr -d ' ')" -eq 1 ] && grep -F -q 'extract-final: cannot read' "$TMP_DIR/extract-final.err"; then ok "AC-142-A2a-2 extract-final unreadable input exits 3 with one stderr line, no stack trace"; else not_ok "AC-142-A2a-2 extract-final unreadable input exits 3 with one stderr line, no stack trace"; fi

# --- AC-135-2: agent-workflow.sh validates runtimes through the registry ---

assert_contains "AC-135-2 agent-workflow.sh wires the runtime registry" "lib/runtime-registry.cjs" "$PRODUCT_ROOT/agent-workflow.sh"
assert_contains "AC-135-2 agent-workflow.sh membership check names the registry helper" "is_registered_runtime" "$PRODUCT_ROOT/agent-workflow.sh"
bash "$PRODUCT_ROOT/agent-workflow.sh" >"$TMP_DIR/aw-usage.out" 2>&1
if grep -F -q -- '[--runtime codex|claude|opencode|omp]' "$TMP_DIR/aw-usage.out"; then ok "AC-135-2 usage renders the runtime set from the registry byte-identically"; else not_ok "AC-135-2 usage renders the runtime set from the registry byte-identically"; fi
CAP_WT="$TMP_DIR/capabilities-worktree"
mkdir -p "$CAP_WT"
node - "$PRODUCT_ROOT/agent-workflow.sh" "$REGISTRY" "$CAP_WT" >"$TMP_DIR/aw-caps.out" 2>"$TMP_DIR/aw-caps.err" <<'NODE'
const { execFileSync } = require("child_process");
const { RUNTIMES } = require(process.argv[3]);
const out = JSON.parse(execFileSync("bash", [process.argv[2], "capabilities", "--worktree", process.argv[4]], { encoding: "utf8" }));
process.exit(JSON.stringify(out.runtimes.map(entry => entry.runtime)) === JSON.stringify(RUNTIMES) ? 0 : 1);
NODE
if [ $? -eq 0 ]; then ok "AC-135-2 capabilities enumerates exactly the registry runtime set in order"; else not_ok "AC-135-2 capabilities enumerates exactly the registry runtime set in order"; fi
bash "$PRODUCT_ROOT/agent-workflow.sh" dispatch --orchestrator cmux --runtime bogus --issue 135 --worktree "$CAP_WT" >"$TMP_DIR/aw-refusal.out" 2>&1
aw_refusal_ec=$?
if [ "$aw_refusal_ec" -eq 2 ] && grep -F -q -- 'ERROR: unknown_runtime: bogus (expected a registry-admitted runtime name)' "$TMP_DIR/aw-refusal.out"; then ok "AC-135-2 unknown runtime refusal is byte-identical"; else not_ok "AC-135-2 unknown runtime refusal is byte-identical"; fi

# --- AC-135-3: dispatch-core admission, effort enums, and preflight ---

assert_contains "AC-135-3 dispatch-core.sh wires the runtime registry" "lib/runtime-registry.cjs" "$PRODUCT_ROOT/dispatch-core.sh"
assert_contains "AC-135-3 dispatch-core.sh membership check names the registry helper" "is_registered_runtime" "$PRODUCT_ROOT/dispatch-core.sh"
assert_contains "AC-135-3 dispatch-core.sh reads the registry default-runtime command" 'node "$RUNTIME_REGISTRY" default-runtime' "$PRODUCT_ROOT/dispatch-core.sh"
assert_absent "AC-135-3 dispatch-core.sh does not truncate registry lines for its default" 'node "$RUNTIME_REGISTRY" lines | head -n 1' "$PRODUCT_ROOT/dispatch-core.sh"
effort_delegations="$(grep -c -F -- 'effortValid(model, effort)' "$PRODUCT_ROOT/dispatch-core.sh")"
if [ "$effort_delegations" -ge 1 ]; then ok "AC-135-3 allocator validation delegates effort enums to the registry"; else not_ok "AC-135-3 allocator validation delegates effort enums to the registry"; fi
bash "$PRODUCT_ROOT/dispatch-core.sh" >"$TMP_DIR/dc-usage.out" 2>&1
dc_usage_ec=$?
if [ "$dc_usage_ec" -eq 2 ] && grep -F -q -- '--runtime codex|claude|opencode|omp' "$TMP_DIR/dc-usage.out"; then ok "AC-135-3 usage renders the runtime set from the registry byte-identically"; else not_ok "AC-135-3 usage renders the runtime set from the registry byte-identically"; fi
bash "$PRODUCT_ROOT/dispatch-core.sh" --adapter cmux --runtime bogus --role implementation --issue 135 --worktree "$CAP_WT" >"$TMP_DIR/dc-refusal.out" 2>&1
dc_refusal_ec=$?
if [ "$dc_refusal_ec" -eq 2 ] && grep -F -q -- 'unknown runtime: bogus' "$TMP_DIR/dc-refusal.out"; then ok "AC-135-3 unknown runtime admission refusal is byte-identical"; else not_ok "AC-135-3 unknown runtime admission refusal is byte-identical"; fi

# --- AC-135-4: route.sh probe membership ---

assert_contains "AC-135-4 route.sh probe membership reads the runtime registry" "lib/runtime-registry.cjs" "$PRODUCT_ROOT/route.sh"
bash "$PRODUCT_ROOT/route.sh" probe --runtime bogus --depth static >"$TMP_DIR/route-bogus.out" 2>&1
route_bogus_ec=$?
AGENT_WORKFLOW_ROUTE_EXECUTABLE=relative bash "$PRODUCT_ROOT/route.sh" probe --runtime codex --depth static >"$TMP_DIR/route-codex.out" 2>&1
route_codex_ec=$?
if [ "$route_bogus_ec" -eq 2 ] && [ "$route_codex_ec" -eq 3 ]; then ok "AC-135-4 probe refuses unregistered runtimes with exit 2 and admits registered ones past membership"; else not_ok "AC-135-4 probe refuses unregistered runtimes with exit 2 and admits registered ones past membership"; fi

# --- AC-135-5: agent-runtime.sh binary resolution and probe contract ---

assert_contains "AC-135-5 agent-runtime.sh resolves binaries through the registry" 'node "$RUNTIME_REGISTRY" bin' "$PRODUCT_ROOT/agent-runtime.sh"
assert_contains "AC-135-5 agent-runtime.sh loads the probe token contract from the registry" "probe-help-tokens" "$PRODUCT_ROOT/agent-runtime.sh"
assert_contains "AC-135-5 agent-runtime.sh loads the subcommand token contract from the registry" "probe-subcommand-help-tokens" "$PRODUCT_ROOT/agent-runtime.sh"
bash "$PRODUCT_ROOT/agent-runtime.sh" >"$TMP_DIR/ar-usage.out" 2>&1
if grep -F -q -- 'capabilities --runtime codex|claude|opencode|omp' "$TMP_DIR/ar-usage.out"; then ok "AC-135-5 usage renders the runtime set from the registry byte-identically"; else not_ok "AC-135-5 usage renders the runtime set from the registry byte-identically"; fi
FAKE_BIN="$TMP_DIR/fake-bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/codex-full" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then echo 'containment fake 1.0'; exit 0; fi
if [ "$1" = "--help" ]; then echo 'Commands: exec'; exit 0; fi
if [ "$1" = "exec" ] && [ "$2" = "--help" ]; then echo 'exec --sandbox --cd --model --config --output-last-message --json'; exit 0; fi
exit 0
EOF
cat > "$FAKE_BIN/codex-partial" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then echo 'containment fake 1.0'; exit 0; fi
if [ "$1" = "--help" ]; then echo 'Commands: exec'; exit 0; fi
if [ "$1" = "exec" ] && [ "$2" = "--help" ]; then echo 'exec --sandbox --cd'; exit 0; fi
exit 0
EOF
chmod +x "$FAKE_BIN/codex-full" "$FAKE_BIN/codex-partial"
AGENT_WORKFLOW_RUNTIME_BIN="$FAKE_BIN/codex-full" bash "$PRODUCT_ROOT/agent-runtime.sh" capabilities --runtime codex >"$TMP_DIR/ar-full.json" 2>/dev/null
ar_full_ec=$?
if [ "$ar_full_ec" -eq 0 ] && grep -F -q '"available":true' "$TMP_DIR/ar-full.json" && grep -F -q '"codex_workspace_write"' "$TMP_DIR/ar-full.json"; then ok "AC-135-5 full registry token contract probes available"; else not_ok "AC-135-5 full registry token contract probes available"; fi
AGENT_WORKFLOW_RUNTIME_BIN="$FAKE_BIN/codex-partial" bash "$PRODUCT_ROOT/agent-runtime.sh" capabilities --runtime codex >"$TMP_DIR/ar-partial.json" 2>/dev/null
ar_partial_ec=$?
if [ "$ar_partial_ec" -eq 1 ] && grep -F -q '"code":"capability_missing_exec_contract"' "$TMP_DIR/ar-partial.json"; then ok "AC-135-5 missing registry token fails closed with the unchanged reason code"; else not_ok "AC-135-5 missing registry token fails closed with the unchanged reason code"; fi
bash "$PRODUCT_ROOT/agent-runtime.sh" capabilities --runtime bogus >"$TMP_DIR/ar-bogus.json" 2>&1
ar_bogus_ec=$?
if [ "$ar_bogus_ec" -eq 3 ] && grep -F -q '"code":"unknown_runtime"' "$TMP_DIR/ar-bogus.json"; then ok "AC-135-5 unknown runtime keeps the typed machine error"; else not_ok "AC-135-5 unknown runtime keeps the typed machine error"; fi

# --- AC-135-6: watchdog stash ownership ---

assert_contains "AC-135-6 agent-watchdog.sh resolves stash ownership from the registry" 'node "$RUNTIME_REGISTRY" stash-by' "$PRODUCT_ROOT/agent-watchdog.sh"
assert_contains "AC-135-6 stash decisions branch on the registry policy value" '"$STASH_BY" = watchdog' "$PRODUCT_ROOT/agent-watchdog.sh"
assert_absent "AC-135-6 no direct RUNTIME=codex stash branch survives" '[ "$RUNTIME" = codex ]' "$PRODUCT_ROOT/agent-watchdog.sh"
assert_absent "AC-135-6 no direct RUNTIME!=codex stash branch survives" '[ "$RUNTIME" != codex ]' "$PRODUCT_ROOT/agent-watchdog.sh"
bash "$PRODUCT_ROOT/agent-watchdog.sh" >"$TMP_DIR/wd-usage.out" 2>&1
if grep -F -q -- '--runtime codex|claude|opencode|omp' "$TMP_DIR/wd-usage.out"; then ok "AC-135-6 usage renders the runtime set from the registry byte-identically"; else not_ok "AC-135-6 usage renders the runtime set from the registry byte-identically"; fi

# --- AC-135-7: containment — the literal set lives only in the registry ---

for site in $CALL_SITES; do
  site_name="$(basename "$site")"
  if runtime_set_literal "$site"; then
    not_ok "AC-135-7 $site_name carries no literal runtime-set enumeration"
  else
    ok "AC-135-7 $site_name carries no literal runtime-set enumeration"
  fi
done
assert_command "AC-135-7 the registry itself owns the runtime set" \
  node - "$REGISTRY" <<'NODE'
const fs = require("fs");
const source = fs.readFileSync(process.argv[2], "utf8");
process.exit(source.includes('"codex"') && source.includes('"claude"') && source.includes('"opencode"') ? 0 : 1);
NODE

# False-green prevention, modeled on the release gate's negative fixtures: a
# call site that keeps (or revives) its own enumeration next to a passing
# registry lookup must fail the detector above.
pipe_fixture="$TMP_DIR/pipe-fixture.sh"
cp "$PRODUCT_ROOT/route.sh" "$pipe_fixture"
printf '%s\n' 'case "$RUNTIME" in codex|claude|opencode|omp) ;; *) exit 2 ;; esac' >> "$pipe_fixture"
assert_command "AC-135-7 detector catches a surviving pipe-form case literal" runtime_set_literal "$pipe_fixture"
space_fixture="$TMP_DIR/space-fixture.sh"
cp "$PRODUCT_ROOT/route.sh" "$space_fixture"
printf '%s\n' 'for runtime in codex claude opencode omp; do :; done' >> "$space_fixture"
assert_command "AC-135-7 detector catches a surviving for-list enumeration" runtime_set_literal "$space_fixture"
comma_fixture="$TMP_DIR/comma-fixture.sh"
cp "$PRODUCT_ROOT/route.sh" "$comma_fixture"
printf '%s\n' 'echo "expected codex, claude, opencode, or omp"' >> "$comma_fixture"
assert_command "AC-135-7 detector catches a surviving comma-form enumeration" runtime_set_literal "$comma_fixture"

echo "---"
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASS"
  exit 0
fi
echo "$FAILURES CASE(S) FAILED"
exit 1
