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

node - "$SCRIPT_DIR/../../schemas/model_alloc.schema.json" "$SCRIPT_DIR/../../schemas/fixtures/model_alloc.valid.json" "$SCRIPT_DIR/../../schemas/fixtures/model_alloc.invalid.json" "$SCRIPT_DIR/../lib/json-schema-subset.cjs" <<'NODE'
const fs = require("fs");
const [schemaFile, validFile, invalidFile, validatorFile] = process.argv.slice(2);
const { validate } = require(validatorFile);
const schema = JSON.parse(fs.readFileSync(schemaFile, "utf8"));
const valid = JSON.parse(fs.readFileSync(validFile, "utf8"));
const invalid = JSON.parse(fs.readFileSync(invalidFile, "utf8"));
process.exit(validate(schema, valid).length === 0 && validate(schema, invalid).length > 0 ? 0 : 1);
NODE
if [ "$?" -eq 0 ]; then pass "model allocation schema accepts valid fixture and rejects invalid fixture"; else fail "model allocation schema fixture validation"; fi

cat > "$TMP_DIR/blocker.json" <<'EOF'
{"changed_lines":120,"file_count":3,"review_round":2,"consecutive_finding_rounds":[1,2],"blocker":true,"touch_set":["src/a.ts"]}
EOF
assert_json "blocker-promotes-implementation" '{"impl_model":"gpt-5.6-terra","impl_effort":"medium"}' --role implementation --evidence "$TMP_DIR/blocker.json"

cat > "$TMP_DIR/rereview.json" <<'EOF'
{"changed_lines":120,"file_count":3,"review_round":1,"consecutive_finding_rounds":[1],"blocker":false,"touch_set":["src/a.ts"]}
EOF
assert_json "rereview-demotes-review-effort" '{"review_model":"opus-4.8","review_effort":"low"}' --role reviewer --evidence "$TMP_DIR/rereview.json"

cat > "$TMP_DIR/contract.json" <<'EOF'
{"changed_lines":20,"file_count":1,"review_round":0,"consecutive_finding_rounds":[],"blocker":false,"touch_set":["packages/shared/index.ts"]}
EOF
assert_json "contract-selects-sol-gate" '{"impl_model":"gpt-5.6-terra","impl_effort":"medium","contract_model":"gpt-5.6-sol","contract_effort":"medium"}' --role implementation --evidence "$TMP_DIR/contract.json"

cat > "$TMP_DIR/large-blocker.json" <<'EOF'
{"changed_lines":401,"file_count":3,"review_round":2,"consecutive_finding_rounds":[1,2],"blocker":true,"touch_set":["src/a.ts"]}
EOF
assert_json "large-touch-high-is-not-demoted-by-findings" '{"impl_model":"gpt-5.6-terra","impl_effort":"high"}' --role implementation --evidence "$TMP_DIR/large-blocker.json"

node - "$SCRIPT_DIR/../../model-alloc.json" "$TMP_DIR/review-lower.json" <<'NODE'
const fs = require("fs");
const value = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
value.roles.reviewer = { model: "gpt-5.6-luna", effort: "medium" };
fs.writeFileSync(process.argv[3], JSON.stringify(value));
NODE
"$ALLOC" --role implementation --config "$TMP_DIR/review-lower.json" >/dev/null 2>&1
if [ "$?" -eq 2 ]; then pass "default review capability preference is enforced"; else fail "default review capability preference is enforced"; fi
node - "$TMP_DIR/review-lower.json" <<'NODE'
const fs = require("fs"); const file = process.argv[2]; const value = JSON.parse(fs.readFileSync(file, "utf8")); value.allow_review_below_implementation = true; fs.writeFileSync(file, JSON.stringify(value));
NODE
assert_json "explicit-review-capability-override-warns" '{"review_model":"gpt-5.6-luna"}' --role implementation --config "$TMP_DIR/review-lower.json"
if grep -q 'warning: project explicitly relaxed review capability preference' "$TMP_DIR/explicit-review-capability-override-warns.json"; then pass "review capability warning requires explicit override"; else fail "review capability warning requires explicit override"; fi

cat > "$TMP_DIR/nonconsecutive.json" <<'EOF'
{"changed_lines":120,"file_count":3,"review_round":3,"consecutive_finding_rounds":[1,3],"blocker":false,"touch_set":["src/a.ts"]}
EOF
"$ALLOC" --role implementation --evidence "$TMP_DIR/nonconsecutive.json" >/dev/null 2>&1
if [ "$?" -eq 2 ]; then pass "findings must be distinct consecutive rounds"; else fail "findings must be distinct consecutive rounds"; fi

printf '%s\n' '{not json' > "$TMP_DIR/bad.json"
"$ALLOC" --role implementation --config "$TMP_DIR/bad.json" >/dev/null 2>&1
if [ "$?" -eq 2 ]; then pass "malformed-project-config-fails-closed"; else fail "malformed-project-config-fails-closed"; fi

"$ALLOC" --evidence "$TMP_DIR/blocker.json" >/dev/null 2>&1
if [ "$?" -eq 2 ]; then pass "role-is-explicit"; else fail "role-is-explicit"; fi

if [ "$FAILURES" -eq 0 ]; then echo "ALL TESTS PASS"; exit 0; fi
echo "$FAILURES CASE(S) FAILED"; exit 1
