#!/usr/bin/env bash
# Smoke test for scripts/ac-check.sh.
# bash-3.2-compatible. Run: bash scripts/__tests__/ac-check.smoke.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK="$SCRIPT_DIR/../ac-check.sh"
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

prefix='{"schema_version":"1","artifact_type":"round_state","lifecycle":"active","producer_role":"CONDUCTOR","revision":3,"acceptance":{'
printf '%s' "${prefix}\"criteria\":[{\"id\":\"AC-1\"},{\"id\":\"AC-2\"}]}}" > "$TMP_DIR/happy.json"
printf '%s\n%s\n' 'test AC-1 behavior' 'test AC-2 behavior' > "$TMP_DIR/happy.tests"
assert_case "AC-1 happy path" 0 "$TMP_DIR/happy.json" 3 "$TMP_DIR/happy.tests" "OK revision 3: 2 acs mapped"

assert_case "AC-2 stale revision" 1 "$TMP_DIR/happy.json" 2 "$TMP_DIR/happy.tests" "STALE expected revision 2, found 3"
if grep -F -q -- 'OK' "$TMP_DIR/output.txt"; then
  echo "NOT OK - stale revision must not emit OK"
  FAILURES=$((FAILURES + 1))
else
  echo "ok   - stale revision emits no OK"
fi

printf '%s' "${prefix}\"criteria\":[{\"id\":\"AC-1\"},{\"id\":\"AC-2\"}]}}" > "$TMP_DIR/missing.json"
printf '%s\n' 'test AC-1 behavior' > "$TMP_DIR/missing.tests"
assert_case "AC-3 unmatched id" 1 "$TMP_DIR/missing.json" 3 "$TMP_DIR/missing.tests" "MISSING AC-2"
if grep -F -q -- 'OK' "$TMP_DIR/output.txt"; then
  echo "NOT OK - AC-3 unmatched id must not emit OK"
  FAILURES=$((FAILURES + 1))
else
  echo "ok   - AC-3 unmatched id emits no OK"
fi

printf '%s' "${prefix}\"criteria\":[{\"id\":\"AC-1\"},{\"id\":\"AC-1\"}]}}" > "$TMP_DIR/duplicate.json"
printf '%s\n' 'test AC-1 behavior' > "$TMP_DIR/duplicate.tests"
assert_case "AC-4 duplicate id" 1 "$TMP_DIR/duplicate.json" 3 "$TMP_DIR/duplicate.tests" "DUP AC-1"

assert_case "AC-5 missing ROUND-STATE" 2 "$TMP_DIR/no-such.json" 3 "$TMP_DIR/happy.tests" ""

printf '%s' '{not-json' > "$TMP_DIR/malformed.json"
assert_case "AC-6 malformed JSON" 2 "$TMP_DIR/malformed.json" 3 "$TMP_DIR/happy.tests" ""

printf '%s' "${prefix}\"criteria\":[]}}" > "$TMP_DIR/empty.json"
assert_case "AC-7 empty criteria" 2 "$TMP_DIR/empty.json" 3 "$TMP_DIR/happy.tests" ""

printf '%s' '{"schema_version":"1","artifact_type":"round_state","lifecycle":"active","producer_role":"CODEX","revision":3,"acceptance":{"criteria":[{"id":"AC-1"}]}}' > "$TMP_DIR/wrong-writer.json"
assert_case "AC-8 non-CONDUCTOR writer" 2 "$TMP_DIR/wrong-writer.json" 3 "$TMP_DIR/happy.tests" ""

printf '%s' '{"schema_version":"1","artifact_type":"round_state","lifecycle":"superseded","producer_role":"CONDUCTOR","revision":3,"acceptance":{"criteria":[{"id":"AC-1"}]}}' > "$TMP_DIR/superseded.json"
assert_case "AC-9 superseded state" 2 "$TMP_DIR/superseded.json" 3 "$TMP_DIR/happy.tests" ""

( bash "$CHECK" --manifest "$TMP_DIR/happy.json" --tests "$TMP_DIR/happy.tests" ) >/dev/null 2>&1
if [ "$?" -eq 2 ]; then
  echo "ok   - AC-10 standalone manifest interface rejected"
else
  echo "NOT OK - AC-10 standalone manifest interface must exit 2"
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
