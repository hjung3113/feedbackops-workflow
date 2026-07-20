#!/usr/bin/env bash
# Smoke test for scripts/model-alloc.sh. Bash 3.2 compatible.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ALLOC="$SCRIPT_DIR/../model-alloc.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
FAILURES=0

pass() { echo "ok   - $1"; }
fail() { echo "NOT OK - $1"; FAILURES=$((FAILURES + 1)); }

assert_json() {
  name="$1"; expected="$2"; shift 2
  out="$TMP_DIR/$name.json"
  "$ALLOC" "$@" >"$out" 2>"$out.err"
  ec=$?
  if [ "$ec" -ne 0 ]; then
    fail "$name (exit $ec: $(cat "$out.err"))"
    return
  fi
  if node - "$out" "$expected" <<'NODE'
const fs = require("fs");
const value = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const expected = JSON.parse(process.argv[3]);
for (const key of Object.keys(expected)) if (value[key] !== expected[key]) process.exit(1);
if (!Array.isArray(value.rationale) || !value.rationale.length) process.exit(1);
NODE
  then pass "$name"; else fail "$name"; fi
}

assert_json "missing-config-uses-default-without-adaptation" '{"impl_model":"gpt-5.6-terra","impl_effort":"low","review_model":"opus-4.8","review_effort":"medium"}' --role implementation

cat > "$TMP_DIR/blocker.json" <<'EOF'
{"changed_lines":120,"file_count":3,"review_round":0,"prior_findings":2,"blocker":true,"touch_set":["src/a.ts"]}
EOF
assert_json "blocker-promotes-implementation" '{"impl_model":"gpt-5.6-terra","impl_effort":"medium"}' --role implementation --evidence "$TMP_DIR/blocker.json"

cat > "$TMP_DIR/rereview.json" <<'EOF'
{"changed_lines":120,"file_count":3,"review_round":1,"prior_findings":1,"blocker":false,"touch_set":["src/a.ts"]}
EOF
assert_json "rereview-demotes-review-effort" '{"review_model":"opus-4.8","review_effort":"low"}' --role reviewer --evidence "$TMP_DIR/rereview.json"

cat > "$TMP_DIR/contract.json" <<'EOF'
{"changed_lines":20,"file_count":1,"review_round":0,"prior_findings":0,"blocker":false,"touch_set":["packages/shared/index.ts"]}
EOF
assert_json "contract-selects-sol-gate" '{"impl_model":"gpt-5.6-terra","impl_effort":"medium","contract_model":"gpt-5.6-sol","contract_effort":"medium"}' --role implementation --evidence "$TMP_DIR/contract.json"

printf '%s\n' '{not json' > "$TMP_DIR/bad.json"
"$ALLOC" --role implementation --config "$TMP_DIR/bad.json" >/dev/null 2>&1
if [ "$?" -eq 2 ]; then pass "malformed-project-config-fails-closed"; else fail "malformed-project-config-fails-closed"; fi

"$ALLOC" --evidence "$TMP_DIR/blocker.json" >/dev/null 2>&1
if [ "$?" -eq 2 ]; then pass "role-is-explicit"; else fail "role-is-explicit"; fi

if [ "$FAILURES" -eq 0 ]; then echo "ALL TESTS PASS"; exit 0; fi
echo "$FAILURES CASE(S) FAILED"; exit 1
