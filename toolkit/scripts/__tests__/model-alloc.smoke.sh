#!/usr/bin/env bash
# Smoke test for scripts/model-alloc.sh. Bash 3.2 compatible.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ALLOC="$SCRIPT_DIR/../model-alloc.sh"
DEFAULT_CONFIG="$SCRIPT_DIR/../../schemas/fixtures/model_alloc.valid.json"
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

assert_json "default-fixture-without-adaptation" '{"impl_model":"gpt-5.6-terra","impl_effort":"low","review_model":"gpt-5.6-sol","review_effort":"medium"}' --role implementation --config "$DEFAULT_CONFIG"

node - "$DEFAULT_CONFIG" "$TMP_DIR/all-efforts.json" <<'NODE'
const fs=require("fs"), v=JSON.parse(fs.readFileSync(process.argv[2]));
v.roles.implementation={model:"gpt-5.6-terra",effort:"max"};
v.roles.reviewer={model:"gpt-5.6-sol",effort:"xhigh"};
v.roles.trivial_implementation={model:"gpt-5.6-luna",effort:"none"};
fs.writeFileSync(process.argv[3],JSON.stringify(v));
NODE
assert_json "terra-max-allocation" '{"impl_model":"gpt-5.6-terra","impl_effort":"max"}' --role implementation --config "$TMP_DIR/all-efforts.json"
assert_json "sol-xhigh-review-allocation" '{"review_model":"gpt-5.6-sol","review_effort":"xhigh"}' --role reviewer --config "$TMP_DIR/all-efforts.json"

node - "$DEFAULT_CONFIG" "$TMP_DIR/non-gpt-max.json" <<'NODE'
const fs=require("fs"), v=JSON.parse(fs.readFileSync(process.argv[2]));
v.reviewer_by_runtime.claude={model:"sonnet",effort:"max"};
fs.writeFileSync(process.argv[3],JSON.stringify(v));
NODE
if "$ALLOC" --role reviewer --runner claude --config "$TMP_DIR/non-gpt-max.json" >/dev/null 2>&1; then fail "non-GPT model rejects GPT-5.6-only effort"; else pass "non-GPT model rejects GPT-5.6-only effort"; fi

assert_json "claude-reviewer-uses-runtime-allocation" '{"review_model":"sonnet","review_effort":"medium"}' --role reviewer --runner claude --config "$DEFAULT_CONFIG"
"$ALLOC" --role reviewer --runner opencode --config "$DEFAULT_CONFIG" >/dev/null 2>"$TMP_DIR/opencode-reviewer.err"
if [ "$?" -eq 2 ] && grep -q 'reviewer_by_runtime.opencode' "$TMP_DIR/opencode-reviewer.err"; then
  pass "OpenCode reviewer requires a target-configured runtime allocation"
else
  fail "OpenCode reviewer requires a target-configured runtime allocation"
fi
node - "$DEFAULT_CONFIG" "$TMP_DIR/opencode-reviewer.json" <<'NODE'
const fs=require("fs"), value=JSON.parse(fs.readFileSync(process.argv[2]));
value.reviewer_by_runtime.opencode={model:"local/reviewer",effort:"high"};
fs.writeFileSync(process.argv[3],JSON.stringify(value));
NODE
assert_json "opencode-reviewer-uses-target-runtime-allocation" '{"review_model":"local/reviewer","review_effort":"high"}' --role reviewer --runner opencode --config "$TMP_DIR/opencode-reviewer.json"

"$ALLOC" --role implementation --config "$DEFAULT_CONFIG" --runner claude >/dev/null 2>"$TMP_DIR/runtime-mismatch.err"
if [ "$?" -eq 2 ] && grep -q 'unavailable via claude' "$TMP_DIR/runtime-mismatch.err"; then
  pass "allocation derives availability from selected runtime"
else
  fail "allocation derives availability from selected runtime"
fi

# Existing schema-v1 target configs predate available_via.  Known provider
# names migrate deterministically; unknown names still fail closed.
node - "$DEFAULT_CONFIG" "$TMP_DIR/legacy-v1.json" <<'NODE'
const fs=require("fs"), v=JSON.parse(fs.readFileSync(process.argv[2]));
for (const capability of Object.values(v.capabilities)) delete capability.available_via;
fs.writeFileSync(process.argv[3], JSON.stringify(v));
NODE
if "$ALLOC" --role implementation --config "$TMP_DIR/legacy-v1.json" --runner codex >/dev/null 2>&1; then pass "legacy schema-v1 config migrates known provider availability"; else fail "legacy schema-v1 config migration"; fi
node - "$TMP_DIR/legacy-v1.json" <<'NODE'
const fs=require("fs"), f=process.argv[2], v=JSON.parse(fs.readFileSync(f));
v.roles.implementation={model:"unknown-model",effort:"low"}; v.capabilities["unknown-model"]={agentic_coding:1,static_coding:1,reasoning:1,input_per_million:1,output_per_million:1}; fs.writeFileSync(f,JSON.stringify(v));
NODE
if "$ALLOC" --role implementation --config "$TMP_DIR/legacy-v1.json" --runner codex >/dev/null 2>&1; then fail "unknown legacy provider fails closed"; else pass "unknown legacy provider fails closed"; fi

node - "$DEFAULT_CONFIG" "$TMP_DIR/schema-invalid.json" <<'NODE'
const fs = require("fs");
const value = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
value.capabilities["gpt-5.6-terra"].unexpected = true;
fs.writeFileSync(process.argv[3], JSON.stringify(value));
NODE
"$ALLOC" --role implementation --config "$TMP_DIR/schema-invalid.json" >"$TMP_DIR/schema-invalid.out" 2>"$TMP_DIR/schema-invalid.err"
if [ "$?" -eq 2 ] && [ ! -s "$TMP_DIR/schema-invalid.out" ] && grep -q "does not satisfy schema" "$TMP_DIR/schema-invalid.err"; then
  pass "runtime config schema validation fails closed before output"
else
  fail "runtime config schema validation fails closed before output"
fi

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
assert_json "blocker-promotes-implementation" '{"impl_model":"gpt-5.6-terra","impl_effort":"medium"}' --role implementation --config "$DEFAULT_CONFIG" --evidence "$TMP_DIR/blocker.json"

node - "$TMP_DIR/all-efforts.json" "$TMP_DIR/none-implementation.json" <<'NODE'
const fs=require("fs"), v=JSON.parse(fs.readFileSync(process.argv[2]));
v.roles.implementation.effort="none"; fs.writeFileSync(process.argv[3],JSON.stringify(v));
NODE
assert_json "blocker-promotes-none-implementation" '{"impl_effort":"medium"}' --role implementation --config "$TMP_DIR/none-implementation.json" --evidence "$TMP_DIR/blocker.json"

cat > "$TMP_DIR/rereview.json" <<'EOF'
{"changed_lines":120,"file_count":3,"review_round":1,"consecutive_finding_rounds":[1],"blocker":false,"touch_set":["src/a.ts"]}
EOF
assert_json "rereview-demotes-review-effort" '{"review_model":"gpt-5.6-sol","review_effort":"low"}' --role reviewer --config "$DEFAULT_CONFIG" --evidence "$TMP_DIR/rereview.json"
assert_json "rereview-steps-xhigh-down-once" '{"review_model":"gpt-5.6-sol","review_effort":"high"}' --role reviewer --config "$TMP_DIR/all-efforts.json" --evidence "$TMP_DIR/rereview.json"

cat > "$TMP_DIR/contract.json" <<'EOF'
{"changed_lines":20,"file_count":1,"review_round":0,"consecutive_finding_rounds":[],"blocker":false,"touch_set":["packages/shared/index.ts"]}
EOF
assert_json "contract-selects-sol-gate" '{"impl_model":"gpt-5.6-terra","impl_effort":"medium","contract_model":"gpt-5.6-sol","contract_effort":"medium"}' --role implementation --config "$DEFAULT_CONFIG" --evidence "$TMP_DIR/contract.json"

node - "$DEFAULT_CONFIG" "$TMP_DIR/final-unavailable.json" <<'NODE'
const fs=require("fs"), v=JSON.parse(fs.readFileSync(process.argv[2]));
v.capabilities["gpt-5.6-luna"].available_via=["claude"]; fs.writeFileSync(process.argv[3],JSON.stringify(v));
NODE
cat > "$TMP_DIR/trivial.json" <<'EOF'
{"changed_lines":1,"file_count":1,"review_round":0,"consecutive_finding_rounds":[],"blocker":false,"touch_set":["src/a.ts"]}
EOF
if "$ALLOC" --role implementation --config "$TMP_DIR/final-unavailable.json" --runner codex --evidence "$TMP_DIR/trivial.json" >/dev/null 2>&1; then fail "adapted final model is revalidated"; else pass "adapted final model is revalidated"; fi

cat > "$TMP_DIR/large-blocker.json" <<'EOF'
{"changed_lines":401,"file_count":3,"review_round":2,"consecutive_finding_rounds":[1,2],"blocker":true,"touch_set":["src/a.ts"]}
EOF
assert_json "large-touch-high-is-not-demoted-by-findings" '{"impl_model":"gpt-5.6-terra","impl_effort":"high"}' --role implementation --config "$DEFAULT_CONFIG" --evidence "$TMP_DIR/large-blocker.json"
assert_json "max-is-not-demoted-by-large-touch" '{"impl_model":"gpt-5.6-terra","impl_effort":"max"}' --role implementation --config "$TMP_DIR/all-efforts.json" --evidence "$TMP_DIR/large-blocker.json"

node - "$DEFAULT_CONFIG" "$TMP_DIR/review-lower.json" <<'NODE'
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
"$ALLOC" --role implementation --config "$DEFAULT_CONFIG" --evidence "$TMP_DIR/nonconsecutive.json" >/dev/null 2>&1
if [ "$?" -eq 2 ]; then pass "findings must be distinct consecutive rounds"; else fail "findings must be distinct consecutive rounds"; fi

printf '%s\n' '{not json' > "$TMP_DIR/bad.json"
"$ALLOC" --role implementation --config "$TMP_DIR/bad.json" >/dev/null 2>&1
if [ "$?" -eq 2 ]; then pass "malformed-project-config-fails-closed"; else fail "malformed-project-config-fails-closed"; fi

"$ALLOC" --evidence "$TMP_DIR/blocker.json" >/dev/null 2>&1
if [ "$?" -eq 2 ]; then pass "role-is-explicit"; else fail "role-is-explicit"; fi

if [ "$FAILURES" -eq 0 ]; then echo "ALL TESTS PASS"; exit 0; fi
echo "$FAILURES CASE(S) FAILED"; exit 1
