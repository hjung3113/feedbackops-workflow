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

echo "--- typecheck baseline diff ---"

# run_diff_case <name> <expected: PASS|FAIL> <baseline-file> <current-file>
run_diff_case() {
  name="$1"; expected="$2"; baseline="$3"; current="$4"
  bash "$VERIFY" --typecheck-diff "$baseline" "$current" >/dev/null 2>&1
  actual_ec=$?
  if [ "$actual_ec" -eq 0 ]; then actual="PASS"; else actual="FAIL"; fi
  if [ "$actual" = "$expected" ]; then
    echo "ok   - $name (expected $expected, got $actual)"
  else
    echo "NOT OK - $name (expected $expected, got $actual)"
    FAILURES=$((FAILURES + 1))
  fi
}

tc_baseline="$TMP_DIR/tc_baseline.txt"
printf '%s\n' 'a.ts(1,1): error TS1 known' > "$tc_baseline"
tc_current="$TMP_DIR/tc_current.txt"
printf '%s\n%s\n' 'a.ts(1,1): error TS1 known' 'b.ts(2,2): error TS2 NEW' > "$tc_current"
tc_missing="$TMP_DIR/tc_does_not_exist.txt"

run_diff_case "new error vs baseline is FAIL"        FAIL "$tc_baseline" "$tc_current"
run_diff_case "current==baseline is PASS"            PASS "$tc_baseline" "$tc_baseline"
run_diff_case "missing baseline + errors is FAIL"    FAIL "$tc_missing"  "$tc_current"

echo "--- typecheck command fail-closed ---"

run_typecheck_case() {
  name="$1"; expected="$2"; stub_body="$3"
  repo="$TMP_DIR/typecheck-$name"
  bin="$repo/bin"
  mkdir -p "$repo/.review" "$bin"
  git -C "$repo" init -q
  git -C "$repo" config user.email "smoke@test.local"
  git -C "$repo" config user.name "smoke"
  printf '%s\n' '# smoke repo' > "$repo/README.md"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "seed"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' "$stub_body"
  } > "$bin/pnpm"
  chmod +x "$bin/pnpm"

  ( cd "$repo" && PATH="$bin:$PATH" bash "$VERIFY" --typecheck ) >/dev/null 2>&1
  actual_ec=$?
  if [ "$actual_ec" -eq 0 ]; then actual="PASS"; else actual="FAIL"; fi
  if [ "$actual" = "$expected" ]; then
    echo "ok   - $name (expected $expected, got $actual)"
  else
    echo "NOT OK - $name (expected $expected, got $actual; exit $actual_ec)"
    FAILURES=$((FAILURES + 1))
  fi
}

run_typecheck_case "typecheck-crash-without-ts-lines" FAIL 'echo "tsconfig unreadable" >&2; exit 1'
run_typecheck_case "typecheck-ts-errors-diff-path" FAIL 'echo "src/x.ts(1,1): error TS2304: Cannot find name X" >&2; exit 1'
run_typecheck_case "typecheck-clean-pass" PASS 'exit 0'

echo "--- verify artifact fail-closed ---"

write_pnpm_stub() {
  bin="$1"; mode="$2"
  cat > "$bin/pnpm" <<'STUB'
#!/usr/bin/env bash
out=""
for arg in "$@"; do
  case "$arg" in
    --outputFile=*) out="${arg#--outputFile=}" ;;
  esac
done
[ -n "$out" ] || { echo "missing --outputFile" >&2; exit 2; }
case "${PNPM_STUB_MODE:-green}" in
  green)
    printf '%s\n' '{"numPassedTests":3,"numFailedTests":0,"numPendingTests":0,"numFailedTestSuites":0,"success":true,"testResults":[]}' > "$out"
    exit 0
    ;;
  fail)
    printf '%s\n' '{"numPassedTests":2,"numFailedTests":1,"numPendingTests":0,"numFailedTestSuites":0,"success":false,"testResults":[{"status":"failed"}]}' > "$out"
    exit 1
    ;;
esac
exit 2
STUB
  chmod +x "$bin/pnpm"
}

run_filter_case() {
  name="$1"; expected_ec="$2"; review_shape="$3"; mode="$4"; issue="$5"
  repo="$TMP_DIR/filter-$name"
  bin="$repo/bin"
  mkdir -p "$repo" "$bin"
  git -C "$repo" init -q
  git -C "$repo" config user.email "smoke@test.local"
  git -C "$repo" config user.name "smoke"
  printf '%s\n' '# smoke repo' > "$repo/README.md"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "seed"
  write_pnpm_stub "$bin" "$mode"
  if [ "$review_shape" = "file" ]; then
    printf '%s\n' "not a directory" > "$repo/.review"
  elif [ "$review_shape" = "dir" ]; then
    mkdir -p "$repo/.review"
  fi

  ( cd "$repo" && VERIFY_DATABASE_URL="postgres://fops_app@127.0.0.1/verify_smoke" VERIFY_ISSUE="$issue" PNPM_STUB_MODE="$mode" VERIFY_ENV_ALLOW="PNPM_STUB_MODE" PATH="$bin:$PATH" bash "$VERIFY" smoke-filter ) >/dev/null 2>&1
  actual_ec=$?
  if [ "$actual_ec" -eq "$expected_ec" ]; then
    echo "ok   - $name (exit $actual_ec)"
  else
    echo "NOT OK - $name (expected exit $expected_ec, got $actual_ec)"
    FAILURES=$((FAILURES + 1))
  fi
}

run_filter_case "green-artifact-write-failure-exits-5" 5 "file" "green" 1
run_filter_case "green-artifact-write-success-exits-0" 0 "dir" "green" 2
if [ -f "$TMP_DIR/filter-green-artifact-write-success-exits-0/.review/ISSUE-2-VERIFY.json" ]; then
  node -e 'const fs=require("fs"); const o=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); if(o.artifact_type!=="verify_result"||o.producer_role!=="VERIFIER"||o.classifier!=="PASS"||!o.verdict||o.verdict.passed!==3) process.exit(1);' "$TMP_DIR/filter-green-artifact-write-success-exits-0/.review/ISSUE-2-VERIFY.json" >/dev/null 2>&1
  if [ "$?" -eq 0 ]; then echo "ok   - green artifact has required verifier fields"; else echo "NOT OK - green artifact has required verifier fields"; FAILURES=$((FAILURES + 1)); fi
else
  echo "NOT OK - green artifact exists"
  FAILURES=$((FAILURES + 1))
fi
run_filter_case "fail-artifact-write-failure-preserves-classifier" 1 "file" "fail" 3
run_filter_case "no-verify-issue-green-unchanged" 0 "file" "green" ""

echo "---"
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASS"
  exit 0
else
  echo "$FAILURES CASE(S) FAILED"
  exit 1
fi
