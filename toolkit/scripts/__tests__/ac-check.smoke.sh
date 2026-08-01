#!/usr/bin/env bash
# Smoke test for scripts/ac-check.sh.
# bash-3.2-compatible. Run: bash scripts/__tests__/ac-check.smoke.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK="$SCRIPT_DIR/../ac-check.sh"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURE="$ROOT/schemas/fixtures/round_state.valid.json"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAILURES=0

assert_case() {
  name="$1"; expected="$2"; round_state="$3"; revision="$4"; test_names="$5"; expected_output="$6"
  output="$TMP_DIR/output.txt"
  ( bash "$CHECK" --round-state "$round_state" --manifest-revision "$revision" --tests "$test_names" ) >"$output" 2>/dev/null
  actual=$?
  if [ "$actual" -eq "$expected" ]; then
    echo "ok   - $name (exit $actual)"
  else
    echo "NOT OK - $name (expected exit $expected, got $actual)"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if [ -z "$expected_output" ]; then
    return
  fi
  if grep -F -q -- "$expected_output" "$output"; then
    echo "ok   - $name (output contains '$expected_output')"
  else
    echo "NOT OK - $name (output missing '$expected_output': $(cat "$output"))"
    FAILURES=$((FAILURES + 1))
  fi
}

BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD)"
BASE_SHA="$(git -C "$ROOT" merge-base HEAD "$BRANCH")"

cp "$FIXTURE" "$TMP_DIR/happy.json"
node -e '
  const fs = require("fs");
  const [file, root, branch, base, head] = process.argv.slice(1);
  const value = JSON.parse(fs.readFileSync(file, "utf8"));
  value.revision = 3;
  value.base_branch = branch;
  value.base_sha = base;
  value.head_sha = head;
  value.worktree_path = root;
  value.acceptance.criteria = [{id: "AC-1", statement: "first acceptance condition"}, {id: "AC-2", statement: "second acceptance condition"}];
  value.decisions = [];
  value.commit_scope.commits = [];
  fs.writeFileSync(file, JSON.stringify(value));
' "$TMP_DIR/happy.json" "$ROOT" "$BRANCH" "$BASE_SHA" "$HEAD_SHA"
printf '%s\n%s\n' 'test AC-1 behavior' 'test AC-2 behavior' > "$TMP_DIR/happy.tests"
assert_case "AC-1 happy path" 0 "$TMP_DIR/happy.json" 3 "$TMP_DIR/happy.tests" "OK revision 3: 2 acs mapped"

assert_case "AC-2 stale revision" 1 "$TMP_DIR/happy.json" 2 "$TMP_DIR/happy.tests" "STALE expected revision 2, found 3"
if grep -F -q -- 'OK' "$TMP_DIR/output.txt"; then
  echo "NOT OK - stale revision must not emit OK"
  FAILURES=$((FAILURES + 1))
else
  echo "ok   - stale revision emits no OK"
fi

cp "$TMP_DIR/happy.json" "$TMP_DIR/missing.json"
printf '%s\n' 'test AC-1 behavior' > "$TMP_DIR/missing.tests"
assert_case "AC-3 unmatched id" 1 "$TMP_DIR/missing.json" 3 "$TMP_DIR/missing.tests" 'MISSING AC-2: no discovered test name contains "AC-2"'
if grep -F -q -- 'OK' "$TMP_DIR/output.txt"; then
  echo "NOT OK - AC-3 unmatched id must not emit OK"
  FAILURES=$((FAILURES + 1))
else
  echo "ok   - AC-3 unmatched id emits no OK"
fi

cp "$TMP_DIR/happy.json" "$TMP_DIR/duplicate.json"
node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.acceptance.criteria=[{id:"AC-1",statement:"first acceptance condition"},{id:"AC-1",statement:"duplicate acceptance condition"}]; fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/duplicate.json"
printf '%s\n' 'test AC-1 behavior' > "$TMP_DIR/duplicate.tests"
assert_case "AC-4 duplicate id" 1 "$TMP_DIR/duplicate.json" 3 "$TMP_DIR/duplicate.tests" "DUP AC-1"

assert_case "AC-5 missing ROUND-STATE" 2 "$TMP_DIR/no-such.json" 3 "$TMP_DIR/happy.tests" ""

printf '%s' '{not-json' > "$TMP_DIR/malformed.json"
assert_case "AC-6 malformed JSON" 2 "$TMP_DIR/malformed.json" 3 "$TMP_DIR/happy.tests" ""

cp "$TMP_DIR/happy.json" "$TMP_DIR/empty.json"
node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.acceptance.criteria=[]; fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/empty.json"
assert_case "AC-7 empty criteria" 2 "$TMP_DIR/empty.json" 3 "$TMP_DIR/happy.tests" ""

cp "$TMP_DIR/happy.json" "$TMP_DIR/wrong-writer.json"
node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.producer_role="CODEX"; fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/wrong-writer.json"
assert_case "AC-8 non-CONDUCTOR writer" 2 "$TMP_DIR/wrong-writer.json" 3 "$TMP_DIR/happy.tests" ""

cp "$TMP_DIR/happy.json" "$TMP_DIR/superseded.json"
node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.lifecycle="superseded"; fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/superseded.json"
assert_case "AC-9 superseded state" 2 "$TMP_DIR/superseded.json" 3 "$TMP_DIR/happy.tests" ""

cp "$TMP_DIR/happy.json" "$TMP_DIR/stale-base.json"
node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.base_sha="0000000000000000000000000000000000000000"; fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/stale-base.json"
assert_case "AC-10 stale base" 1 "$TMP_DIR/stale-base.json" 3 "$TMP_DIR/happy.tests" "STALE ROUND-STATE freshness check failed"

printf '%s\n' 'test AC-10 behavior' > "$TMP_DIR/prefix.tests"
assert_case "AC-11 AC id boundary" 1 "$TMP_DIR/happy.json" 3 "$TMP_DIR/prefix.tests" 'MISSING AC-1: no discovered test name contains "AC-1"'

( bash "$CHECK" --manifest "$TMP_DIR/happy.json" --tests "$TMP_DIR/happy.tests" ) >/dev/null 2>&1
if [ "$?" -eq 2 ]; then
  echo "ok   - AC-12 standalone manifest interface rejected"
else
  echo "NOT OK - AC-12 standalone manifest interface must exit 2"
  FAILURES=$((FAILURES + 1))
fi

node -e '
  const fs = require("fs");
  const { validate } = require(process.argv[1]);
  const schema = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  const valid = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
  const invalid = JSON.parse(fs.readFileSync(process.argv[4], "utf8"));
  if (validate(schema, valid).length !== 0) process.exit(1);
  if (validate(schema, invalid).length === 0) process.exit(2);
  if (validate({...schema, oneOf: []}, valid).length === 0) process.exit(3);
' "$ROOT/scripts/lib/json-schema-subset.cjs" \
  "$ROOT/schemas/round_state.schema.json" \
  "$ROOT/schemas/fixtures/round_state.valid.json" \
  "$ROOT/schemas/fixtures/round_state.invalid.json"
if [ "$?" -eq 0 ]; then
  echo "ok   - AC-13 schema subset validates fixtures and rejects unknown keywords"
else
  echo "NOT OK - AC-13 schema subset validation contract"
  FAILURES=$((FAILURES + 1))
fi

echo "---"
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASS"
  exit 0
else
  echo "$FAILURES CASE(S) FAILED"
  exit 1
fi
