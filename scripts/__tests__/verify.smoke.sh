#!/usr/bin/env bash
# Smoke test for scripts/verify.sh --classify-json mode.
# bash-3.2-compatible. Run: bash scripts/__tests__/verify.smoke.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERIFY="$SCRIPT_DIR/../verify.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAILURES=0

# run_case <name> <expected: PASS|FAIL> <report-file> [exit-code-arg]
run_case() {
  name="$1"; expected="$2"; report="$3"; ec_arg="${4:-}"
  if [ -n "$ec_arg" ]; then
    bash "$VERIFY" --classify-json "$report" "$ec_arg" >/dev/null 2>&1
  else
    bash "$VERIFY" --classify-json "$report" >/dev/null 2>&1
  fi
  actual_ec=$?
  if [ "$actual_ec" -eq 0 ]; then actual="PASS"; else actual="FAIL"; fi
  if [ "$actual" = "$expected" ]; then
    echo "ok   - $name (expected $expected, got $actual)"
  else
    echo "NOT OK - $name (expected $expected, got $actual)"
    FAILURES=$((FAILURES + 1))
  fi
}

write_json() {
  printf '%s' "$2" > "$TMP_DIR/$1"
  echo "$TMP_DIR/$1"
}

f_all_skipped=$(write_json all_skipped.json '{"numTotalTests":31,"numPassedTests":0,"numFailedTests":0,"numPendingTests":31,"numTotalTestSuites":1,"numFailedTestSuites":0,"success":true}')
f_green=$(write_json green.json '{"numTotalTests":31,"numPassedTests":31,"numFailedTests":0,"numPendingTests":0,"numTotalTestSuites":1,"numFailedTestSuites":0,"success":true}')
f_green_results=$(write_json green_results.json '{"numPassedTests":3,"numFailedTests":0,"numPendingTests":0,"numTotalTestSuites":1,"numFailedTestSuites":0,"success":true,"testResults":[{"status":"passed"},{"status":"passed"}]}')
f_failed_tests=$(write_json failed_tests.json '{"numTotalTests":31,"numPassedTests":29,"numFailedTests":2,"numPendingTests":0,"numTotalTestSuites":1,"numFailedTestSuites":0,"success":false}')
f_failed_suite=$(write_json failed_suite.json '{"numTotalTests":5,"numPassedTests":5,"numFailedTests":0,"numPendingTests":0,"numTotalTestSuites":1,"numFailedTestSuites":1,"success":false}')
f_results_failed=$(write_json results_failed.json '{"numTotalTests":31,"numPassedTests":31,"numFailedTests":0,"numPendingTests":0,"numTotalTestSuites":1,"numFailedTestSuites":0,"success":true,"testResults":[{"status":"failed"}]}')
f_success_false=$(write_json success_false.json '{"numPassedTests":5,"numFailedTests":0,"success":false}')
f_malformed=$(write_json malformed.json '{not json')
f_missing="$TMP_DIR/does_not_exist.json"

run_case "all-skipped suite is FAIL"        FAIL "$f_all_skipped"
run_case "genuine green is PASS"            PASS "$f_green"
run_case "green w/ passed testResults PASS" PASS "$f_green_results"
run_case "failed tests is FAIL"             FAIL "$f_failed_tests"
run_case "failed suite zero failed is FAIL" FAIL "$f_failed_suite"
run_case "testResults failed is FAIL"       FAIL "$f_results_failed"
run_case "success:false w/ passes is FAIL"  FAIL "$f_success_false"
run_case "non-zero vitest exit is FAIL"     FAIL "$f_green" "1"
run_case "malformed JSON is FAIL"           FAIL "$f_malformed"
run_case "missing report file is FAIL"      FAIL "$f_missing"

echo "---"
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASS"
  exit 0
else
  echo "$FAILURES CASE(S) FAILED"
  exit 1
fi
