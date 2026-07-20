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
f_array=$(write_json array.json '[]')
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

machine_err="$TMP_DIR/machine.stderr"
bash "$VERIFY" --classify-json "$f_failed_tests" >/dev/null 2>"$machine_err"
if node -e '
  const fs=require("fs");
  const line=fs.readFileSync(process.argv[1],"utf8").split("\n").find((value)=>value.startsWith("VERIFY_FAILURE_JSON="));
  if(!line) process.exit(1);
  const result=JSON.parse(line.slice("VERIFY_FAILURE_JSON=".length));
  const failure=result.failures.find((item)=>item.code==="failed_tests");
  if(!failure||failure.expected!=="0"||failure.actual!=="2") process.exit(1);
' "$machine_err"; then
  echo "ok   - classifier failure exposes typed expected/actual machine output"
else
  echo "NOT OK - classifier failure exposes typed expected/actual machine output"
  FAILURES=$((FAILURES + 1))
fi

for invalid_case in "$f_malformed" "$f_missing"; do
  invalid_err="$TMP_DIR/invalid-$(basename "$invalid_case").stderr"
  bash "$VERIFY" --classify-json "$invalid_case" >/dev/null 2>"$invalid_err"
  if grep -F -q 'VERIFY_FAILURE_JSON={"failures":[{"code":"invalid_report"' "$invalid_err"; then
    echo "ok   - invalid report exposes typed machine output ($(basename "$invalid_case"))"
  else
    echo "NOT OK - invalid report exposes typed machine output ($(basename "$invalid_case"))"
    FAILURES=$((FAILURES + 1))
  fi
done

array_err="$TMP_DIR/array.stderr"
bash "$VERIFY" --classify-json "$f_array" >/dev/null 2>"$array_err"
if grep -F -q "FAIL: no executable tests ran (passed+failed==0); 0 pending" "$array_err"; then
  echo "ok   - array report preserves classifier failure output"
else
  echo "NOT OK - array report preserves classifier failure output (got: $(cat "$array_err"))"
  FAILURES=$((FAILURES + 1))
fi

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
  malformed)
    printf '%s\n' '{not json' > "$out"
    exit 1
    ;;
esac
exit 2
STUB
  chmod +x "$bin/pnpm"
}

CLEAN_PROBE="$TMP_DIR/clean-probe.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s\n'\'' '\''{"checks":[{"code":"sentinel","expected":"clean","actual":"clean"},{"code":"migration_hash","expected":"sha256:expected","actual":"sha256:expected"}],"role":{"name":"fops_app","superuser":false}}'\''' > "$CLEAN_PROBE"
chmod +x "$CLEAN_PROBE"

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

  ( cd "$repo" && VERIFY_DATABASE_URL="postgres://fops_app@127.0.0.1/verify_smoke" VERIFY_CLEAN_COMMAND="$CLEAN_PROBE" VERIFY_ISSUE="$issue" PNPM_STUB_MODE="$mode" VERIFY_ENV_ALLOW="PNPM_STUB_MODE" PATH="$bin:$PATH" bash "$VERIFY" smoke-filter ) >/dev/null 2>&1
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
  node -e 'const fs=require("fs"); const o=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); if(o.artifact_type!=="verify_result"||o.producer_role!=="VERIFIER"||o.classifier!=="PASS"||!o.verdict||o.verdict.passed!==3||!o.clean_state||o.clean_state.sentinel.actual!=="clean"||o.clean_state.migration_hash.actual!=="sha256:expected"||o.clean_state.role.superuser!==false) process.exit(1);' "$TMP_DIR/filter-green-artifact-write-success-exits-0/.review/ISSUE-2-VERIFY.json" >/dev/null 2>&1
  if [ "$?" -eq 0 ]; then echo "ok   - green artifact has required verifier fields"; else echo "NOT OK - green artifact has required verifier fields"; FAILURES=$((FAILURES + 1)); fi
else
  echo "NOT OK - green artifact exists"
  FAILURES=$((FAILURES + 1))
fi
run_filter_case "failed-run-writes-typed-failures" 1 "dir" "fail" 4
if node -e '
  const fs=require("fs"); const o=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
  const failure=Array.isArray(o.failures)&&o.failures.find((item)=>item.code==="failed_tests");
  if(!failure||failure.expected!=="0"||failure.actual!=="1") process.exit(1);
' "$TMP_DIR/filter-failed-run-writes-typed-failures/.review/ISSUE-4-VERIFY.json" >/dev/null 2>&1; then
  echo "ok   - failed artifact records typed expected/actual failures"
else
  echo "NOT OK - failed artifact records typed expected/actual failures"
  FAILURES=$((FAILURES + 1))
fi
run_filter_case "invalid-report-retains-machine-failure" 1 "dir" "malformed" 5
if node -e '
  const fs=require("fs"); const o=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
  if(o.failures.length!==1||o.failures[0].code!=="invalid_report"||o.failures[0].expected!=="parseable JSON object"||o.failures[0].actual!=="unparseable") process.exit(1);
' "$TMP_DIR/filter-invalid-report-retains-machine-failure/.review/ISSUE-5-VERIFY.json" >/dev/null 2>&1; then
  echo "ok   - invalid report failure is retained in canonical evidence"
else
  echo "NOT OK - invalid report failure is retained in canonical evidence"
  FAILURES=$((FAILURES + 1))
fi
run_filter_case "fail-artifact-write-failure-preserves-classifier" 1 "file" "fail" 3
run_filter_case "no-verify-issue-green-unchanged" 0 "file" "green" ""

echo "--- full-module and privilege defaults ---"

clean_out="$TMP_DIR/clean.out"
VERIFY_DATABASE_URL="postgres://fops_app@127.0.0.1/verify_smoke" VERIFY_CLEAN_COMMAND="$CLEAN_PROBE" bash "$VERIFY" --verify-clean >"$clean_out" 2>&1
ec=$?
if [ "$ec" -eq 0 ] && grep -F -q 'PASS: verification database is clean' "$clean_out"; then
  echo "ok   - --verify-clean accepts matching sentinel and migration hash"
else
  echo "NOT OK - --verify-clean accepts matching sentinel and migration hash (got $ec)"
  FAILURES=$((FAILURES + 1))
fi

DIRTY_PROBE="$TMP_DIR/dirty-probe.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s\n'\'' '\''{"checks":[{"code":"sentinel","expected":"clean","actual":"dirty"},{"code":"migration_hash","expected":"sha256:expected","actual":"sha256:actual"}],"role":{"name":"fops_app","superuser":false}}'\''' > "$DIRTY_PROBE"
chmod +x "$DIRTY_PROBE"
dirty_err="$TMP_DIR/dirty.stderr"
VERIFY_DATABASE_URL="postgres://fops_app@127.0.0.1/verify_smoke" VERIFY_CLEAN_COMMAND="$DIRTY_PROBE" bash "$VERIFY" --verify-clean >/dev/null 2>"$dirty_err"
ec=$?
if [ "$ec" -eq 1 ] && grep -F -q '"code":"sentinel","expected":"clean","actual":"dirty"' "$dirty_err" && grep -F -q '"code":"migration_hash"' "$dirty_err"; then
  echo "ok   - --verify-clean rejects dirty state with typed differences"
else
  echo "NOT OK - --verify-clean rejects dirty state with typed differences (got $ec)"
  FAILURES=$((FAILURES + 1))
fi

LEAK_PROBE="$TMP_DIR/leak-probe.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s\n'\'' '\''{"checks":[{"code":"sentinel","expected":"clean","actual":"clean","credential":"secret"},{"code":"migration_hash","expected":"same","actual":"same"}],"role":{"name":"fops_app","superuser":false}}'\''' > "$LEAK_PROBE"
chmod +x "$LEAK_PROBE"
leak_err="$TMP_DIR/leak.stderr"
VERIFY_DATABASE_URL="postgres://fops_app@127.0.0.1/verify_smoke" VERIFY_CLEAN_COMMAND="$LEAK_PROBE" bash "$VERIFY" --verify-clean >/dev/null 2>"$leak_err"
ec=$?
if [ "$ec" -eq 2 ] && grep -F -q '"code":"clean_probe_invalid"' "$leak_err" && ! grep -F -q 'secret' "$leak_err"; then
  echo "ok   - clean probe rejects undeclared fields without echoing them"
else
  echo "NOT OK - clean probe rejects undeclared fields without echoing them (got $ec)"
  FAILURES=$((FAILURES + 1))
fi

SUPERUSER_PROBE="$TMP_DIR/superuser-probe.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s\n'\'' '\''{"checks":[{"code":"sentinel","expected":"clean","actual":"clean"},{"code":"migration_hash","expected":"same","actual":"same"}],"role":{"name":"custom_admin","superuser":true}}'\''' > "$SUPERUSER_PROBE"
chmod +x "$SUPERUSER_PROBE"
custom_superuser_err="$TMP_DIR/custom-superuser.stderr"
VERIFY_DATABASE_URL="postgres://custom_admin@127.0.0.1/verify_smoke" VERIFY_CLEAN_COMMAND="$SUPERUSER_PROBE" bash "$VERIFY" --verify-clean >/dev/null 2>"$custom_superuser_err"
ec=$?
if [ "$ec" -eq 1 ] && grep -F -q '"code":"privileged_database_role","expected":"false","actual":"true"' "$custom_superuser_err"; then
  echo "ok   - target privilege evidence rejects custom superusers"
else
  echo "NOT OK - target privilege evidence rejects custom superusers (got $ec)"
  FAILURES=$((FAILURES + 1))
fi

clean_missing_err="$TMP_DIR/clean-missing.stderr"
VERIFY_DATABASE_URL="postgres://fops_app@127.0.0.1/verify_smoke" env -u VERIFY_CLEAN_COMMAND bash "$VERIFY" --verify-clean >/dev/null 2>"$clean_missing_err"
ec=$?
if [ "$ec" -eq 4 ] && grep -F -q '"code":"clean_probe_unconfigured"' "$clean_missing_err"; then
  echo "ok   - --verify-clean requires a target clean probe"
else
  echo "NOT OK - --verify-clean requires a target clean probe (got $ec)"
  FAILURES=$((FAILURES + 1))
fi

full_repo="$TMP_DIR/filter-full-module-default"
full_bin="$full_repo/bin"
mkdir -p "$full_repo" "$full_bin"
git -C "$full_repo" init -q
git -C "$full_repo" config user.email "smoke@test.local"
git -C "$full_repo" config user.name "smoke"
printf '%s\n' '# smoke repo' > "$full_repo/README.md"
git -C "$full_repo" add -A
git -C "$full_repo" commit -q -m seed
write_pnpm_stub "$full_bin" green
( cd "$full_repo" && VERIFY_DATABASE_URL="postgres://fops_app@127.0.0.1/verify_smoke" PNPM_STUB_MODE=green VERIFY_ENV_ALLOW=PNPM_STUB_MODE PATH="$full_bin:$PATH" bash "$VERIFY" ) >/dev/null 2>&1
ec=$?
if [ "$ec" -eq 0 ]; then
  echo "ok   - no filter runs the full backend module"
else
  echo "NOT OK - no filter runs the full backend module (got $ec)"
  FAILURES=$((FAILURES + 1))
fi
( cd "$full_repo" && VERIFY_DATABASE_URL="postgres://fops_app@127.0.0.1/verify_smoke" PNPM_STUB_MODE=green VERIFY_ENV_ALLOW=PNPM_STUB_MODE PATH="$full_bin:$PATH" bash "$VERIFY" --full-module ) >/dev/null 2>&1
ec=$?
if [ "$ec" -eq 0 ]; then
  echo "ok   - --full-module reproduces the canonical full-module command"
else
  echo "NOT OK - --full-module reproduces the canonical full-module command (got $ec)"
  FAILURES=$((FAILURES + 1))
fi

superuser_err="$TMP_DIR/superuser.stderr"
( cd "$full_repo" && VERIFY_DATABASE_URL="postgres://postgres@127.0.0.1/verify_smoke" PATH="$full_bin:$PATH" bash "$VERIFY" smoke-filter ) >/dev/null 2>"$superuser_err"
ec=$?
if [ "$ec" -eq 3 ] && grep -F -q '"code":"privileged_database_role"' "$superuser_err"; then
  echo "ok   - superuser verifier role fails closed with machine output"
else
  echo "NOT OK - superuser verifier role fails closed with machine output (got $ec)"
  FAILURES=$((FAILURES + 1))
fi

fresh_err="$TMP_DIR/fresh.stderr"
bash "$VERIFY" --fresh >/dev/null 2>"$fresh_err"
ec=$?
if [ "$ec" -eq 2 ] && grep -F -q '"code":"fresh_requires_adapter"' "$fresh_err"; then
  echo "ok   - --fresh is reserved and fails with a stable machine code"
else
  echo "NOT OK - --fresh is reserved and fails with a stable machine code (got $ec)"
  FAILURES=$((FAILURES + 1))
fi

echo "--- VERIFY_ISSUE without VERIFY_DATABASE_URL fails closed ---"

# 2026-07-13 incident: VERIFY_DATABASE_URL was accidentally unset (upstream
# eval of empty stdout) and verify.sh silently fell back to the worktree
# .env's DATABASE_URL (the shared dev DB), producing a garbage artifact.
# Must now refuse with a distinct exit code, never inheriting .env's URL.
no_url_repo="$TMP_DIR/filter-no-verify-db-url"
mkdir -p "$no_url_repo"
printf '%s\n' 'DATABASE_URL=postgres://fops_app:pw@localhost:5434/feedbackops' > "$no_url_repo/.env"
no_url_err="$TMP_DIR/no-verify-db-url.stderr"
( cd "$no_url_repo" && env -u VERIFY_DATABASE_URL VERIFY_ISSUE=77 bash "$VERIFY" smoke-filter ) >/dev/null 2>"$no_url_err"
ec=$?
if [ "$ec" -eq 4 ]; then
  echo "ok   - VERIFY_ISSUE without VERIFY_DATABASE_URL exits 4"
else
  echo "NOT OK - VERIFY_ISSUE without VERIFY_DATABASE_URL exits 4 (got $ec)"
  FAILURES=$((FAILURES + 1))
fi
if grep -q "refusing to fall back to .env DATABASE_URL" "$no_url_err"; then
  echo "ok   - refusal message names the .env fallback"
else
  echo "NOT OK - refusal message names the .env fallback (got: $(cat "$no_url_err"))"
  FAILURES=$((FAILURES + 1))
fi
if grep -F -q '"code":"verify_database_url","expected":"explicit low-privilege VERIFY_DATABASE_URL","actual":"unset"' "$no_url_err"; then
  echo "ok   - missing verifier URL exposes typed machine output"
else
  echo "NOT OK - missing verifier URL exposes typed machine output"
  FAILURES=$((FAILURES + 1))
fi

( cd "$no_url_repo" && VERIFY_DATABASE_URL="" VERIFY_ISSUE=77 bash "$VERIFY" smoke-filter ) >/dev/null 2>&1
ec=$?
if [ "$ec" -eq 4 ]; then
  echo "ok   - empty (not just unset) VERIFY_DATABASE_URL also exits 4"
else
  echo "NOT OK - empty (not just unset) VERIFY_DATABASE_URL also exits 4 (got $ec)"
  FAILURES=$((FAILURES + 1))
fi

echo "--- database url parser ---"

run_parse_db_case() {
  name="$1"; url="$2"; expected="$3"
  out="$(bash "$VERIFY" --parse-db-url "$url" 2>/dev/null)"
  if [ "$out" = "$expected" ]; then
    echo "ok   - $name"
  else
    echo "NOT OK - $name (expected '$expected', got '$out')"
    FAILURES=$((FAILURES + 1))
  fi
  case "$out" in
    *secret*|*pass*) echo "NOT OK - $name leaked password"; FAILURES=$((FAILURES + 1)) ;;
  esac
}

run_parse_db_case "parse localhost url" "postgres://fops_app:secretpass@localhost:5432/feedbackops?sslmode=disable" "localhost	feedbackops	fops_app"
run_parse_db_case "parse ipv4 url" "postgres://fops_app@127.0.0.1/verify_smoke" "127.0.0.1	verify_smoke	fops_app"
run_parse_db_case "parse bracketed ipv6 url" "postgres://fops_app:secretpass@[::1]:5432/verify_ipv6" "[::1]	verify_ipv6	fops_app"

echo "--- verify schema clean-state contract ---"
SCHEMA_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
if node -e '
  const fs=require("fs"); const {validate}=require(process.argv[1]);
  const schema=JSON.parse(fs.readFileSync(process.argv[2],"utf8"));
  const valid=JSON.parse(fs.readFileSync(process.argv[3],"utf8"));
  const missing=JSON.parse(fs.readFileSync(process.argv[4],"utf8"));
  const extra=JSON.parse(fs.readFileSync(process.argv[5],"utf8"));
  if(validate(schema,valid).length!==0||validate(schema,missing).length===0||validate(schema,extra).length===0) process.exit(1);
' "$SCRIPT_DIR/../lib/json-schema-subset.cjs" "$SCHEMA_ROOT/schemas/verify.schema.json" "$SCHEMA_ROOT/schemas/fixtures/verify.valid.json" "$SCHEMA_ROOT/schemas/fixtures/verify.clean_state_missing.invalid.json" "$SCHEMA_ROOT/schemas/fixtures/verify.clean_state_extra.invalid.json"; then
  echo "ok   - schema requires exact canonical clean-state fields"
else
  echo "NOT OK - schema requires exact canonical clean-state fields"
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
