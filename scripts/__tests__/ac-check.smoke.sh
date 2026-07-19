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
  name="$1"; expected="$2"; manifest="$3"; test_names="$4"; expected_output="$5"
  output="$TMP_DIR/output.txt"
  ( bash "$CHECK" --manifest "$manifest" --tests "$test_names" ) >"$output" 2>/dev/null
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

printf '%s' '{"acs":[{"id":"AC-1"},{"id":"AC-2"}]}' > "$TMP_DIR/happy.json"
printf '%s\n%s\n' 'test AC-1 behavior' 'test AC-2 behavior' > "$TMP_DIR/happy.tests"
assert_case "AC-1 happy path" 0 "$TMP_DIR/happy.json" "$TMP_DIR/happy.tests" "OK 2 acs mapped"

printf '%s' '{"acs":[{"id":"AC-1"},{"id":"AC-2"}]}' > "$TMP_DIR/missing.json"
printf '%s\n' 'test AC-1 behavior' > "$TMP_DIR/missing.tests"
assert_case "AC-2 unmatched id" 1 "$TMP_DIR/missing.json" "$TMP_DIR/missing.tests" "MISSING AC-2"
if grep -F -q -- 'OK' "$TMP_DIR/output.txt"; then
  echo "NOT OK - AC-2 unmatched id must not emit OK"
  FAILURES=$((FAILURES + 1))
else
  echo "ok   - AC-2 unmatched id emits no OK"
fi

printf '%s' '{"acs":[{"id":"AC-1"},{"id":"AC-1"}]}' > "$TMP_DIR/duplicate.json"
printf '%s\n' 'test AC-1 behavior' > "$TMP_DIR/duplicate.tests"
assert_case "AC-3 duplicate id" 1 "$TMP_DIR/duplicate.json" "$TMP_DIR/duplicate.tests" "DUP AC-1"

assert_case "AC-4 missing manifest" 2 "$TMP_DIR/no-such.json" "$TMP_DIR/happy.tests" ""

printf '%s' '{not-json' > "$TMP_DIR/malformed.json"
assert_case "AC-5 malformed JSON" 2 "$TMP_DIR/malformed.json" "$TMP_DIR/happy.tests" ""

echo "---"
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASS"
  exit 0
else
  echo "$FAILURES CASE(S) FAILED"
  exit 1
fi
