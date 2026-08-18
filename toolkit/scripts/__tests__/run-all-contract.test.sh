#!/usr/bin/env bash
# Contract test for scripts/__tests__/run-all.sh failure observability.
#
# Deliberately NOT named *.smoke.sh: run-all.sh discovers the live smoke
# inventory by that suffix, so a smoke-named copy of this file would make the
# runner execute itself recursively. It drives run-all.sh against deliberate
# pass/fail fixtures in a throwaway directory instead of the live inventory.
#
# bash-3.2-compatible. Run: bash scripts/__tests__/run-all-contract.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SELF="$(basename "$0")"
RUNNER="$SCRIPT_DIR/run-all.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

FAILURES=0
pass() { echo "ok   - $1"; }
fail() { echo "NOT OK - $1"; FAILURES=$((FAILURES + 1)); }

# Fixture suite: a copy of the runner beside one passing and one failing smoke.
# The runner resolves its inventory from its own directory, so the copy sees
# only these fixtures.
FIXTURE_DIR="$TMP_ROOT/fixture-suite"
FIXTURE_TMP="$TMP_ROOT/fixture-tmp"
mkdir -p "$FIXTURE_DIR" "$FIXTURE_TMP"
cp "$RUNNER" "$FIXTURE_DIR/run-all.sh"

INNER_ASSERTION='NOT OK - fixture inner assertion RUN-ALL-CONTRACT-CANARY'
cat > "$FIXTURE_DIR/deliberate-pass.smoke.sh" <<'EOF'
#!/usr/bin/env bash
echo "ok   - deliberate pass fixture"
exit 0
EOF
cat > "$FIXTURE_DIR/deliberate-fail.smoke.sh" <<EOF
#!/usr/bin/env bash
echo "$INNER_ASSERTION"
echo "stdout secret: \$SECRET_FIXTURE_TOKEN"
echo "stderr secret: \$SECRET_FIXTURE_TOKEN" >&2
exit 3
EOF

# --- AC-OBS-1: a failing fixture surfaces its exact redacted diagnostic ---
fail_out="$TMP_ROOT/failing-run.out"
SECRET_VALUE='run-all-contract-secret-value'
PARTIAL_SECRET='contract-secret'
redaction_values="$TMP_ROOT/redaction-values.txt"
# Put the contained value first to prove matching is based on the earliest,
# longest literal at that position rather than caller ordering.
printf '%s\n%s\n' "$PARTIAL_SECRET" "$SECRET_VALUE" > "$redaction_values"
TMPDIR="$FIXTURE_TMP" SECRET_FIXTURE_TOKEN='run-all-contract-secret-value' \
  bash "$FIXTURE_DIR/run-all.sh" --redact-values-file "$redaction_values" >"$fail_out" 2>&1
fail_ec=$?
retained="$(sed -n 's/^diagnostic retained: //p' "$fail_out" | sed -n '1p')"
if [ "$fail_ec" -ne 0 ] \
  && grep -F -q -- "$INNER_ASSERTION" "$fail_out" \
  && grep -F -q -- 'NOT OK - deliberate-fail.smoke.sh (exit 3)' "$fail_out" \
  && [ "$(grep -F -c -- '[REDACTED]' "$fail_out")" -ge 2 ] \
  && [ -n "$retained" ] && [ -f "$retained" ] \
  && grep -F -q -- "$INNER_ASSERTION" "$retained" \
  && [ "$(grep -F -c -- '[REDACTED]' "$retained")" -eq 2 ]; then
  pass "AC-OBS-1 failing smoke emits and retains its exact redacted diagnostic"
else
  fail "AC-OBS-1 failing smoke emits and retains its exact redacted diagnostic (ec=$fail_ec retained=$retained)"
fi

if grep -F -q -- "$SECRET_VALUE" "$fail_out" \
  || grep -F -q -- "$PARTIAL_SECRET" "$fail_out" \
  || { [ -n "$retained" ] && [ -f "$retained" ] \
    && { grep -F -q -- "$SECRET_VALUE" "$retained" \
      || grep -F -q -- "$PARTIAL_SECRET" "$retained"; }; }; then
  fail "AC-OBS-1 explicit secret is absent from CI and retained diagnostics"
else
  pass "AC-OBS-1 explicit secret is absent from CI and retained diagnostics"
fi

if find "$FIXTURE_TMP" -type f -name '*.raw' -print | grep -q .; then
  fail "AC-OBS-1 raw failing capture is not retained"
else
  pass "AC-OBS-1 raw failing capture is not retained"
fi

# --- AC-STDIN-1: a smoke that drains stdin cannot truncate the inventory ---
# The 0- prefix makes this fixture sort first, so without driver-level stdin
# isolation its stdin read would consume the runner's remaining inventory
# pipe and the later deliberate-* smokes would silently never run.
cat > "$FIXTURE_DIR/0-stdin-drain.smoke.sh" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
exit 4
EOF
drain_out="$TMP_ROOT/stdin-drain-run.out"
TMPDIR="$FIXTURE_TMP" bash "$FIXTURE_DIR/run-all.sh" >"$drain_out" 2>&1
drain_ec=$?
if [ "$drain_ec" -ne 0 ] \
  && grep -F -x -q -- 'NOT OK - 0-stdin-drain.smoke.sh (exit 4)' "$drain_out" \
  && grep -F -x -q -- 'NOT OK - deliberate-fail.smoke.sh (exit 3)' "$drain_out" \
  && grep -F -x -q -- '--- 1/3 passed' "$drain_out"; then
  pass "AC-STDIN-1 stdin-draining smoke does not truncate the smoke inventory"
else
  fail "AC-STDIN-1 stdin-draining smoke does not truncate the smoke inventory (ec=$drain_ec output=$(cat "$drain_out"))"
fi
rm -f "$FIXTURE_DIR/0-stdin-drain.smoke.sh"

# --- AC-OBS-2: --list answers without allocating temporary storage ---
EMPTY_TMP="$TMP_ROOT/empty-tmp"
mkdir -p "$EMPTY_TMP"
list_out="$TMP_ROOT/list-empty-tmp.out"
TMPDIR="$EMPTY_TMP" bash "$RUNNER" --list >"$list_out" 2>&1
list_ec=$?
allocated="$(find "$EMPTY_TMP" -mindepth 1 -print | wc -l | tr -d ' ')"

expected_list="$TMP_ROOT/expected-list.txt"
find "$SCRIPT_DIR" -maxdepth 1 -type f -name '*.smoke.sh' -print \
  | sed 's|.*/||' | sort > "$expected_list"

if [ "$list_ec" -eq 0 ] && [ "$allocated" -eq 0 ] \
  && cmp -s "$list_out" "$expected_list"; then
  pass "AC-OBS-2 --list reports the live inventory without allocating temporary storage"
else
  fail "AC-OBS-2 --list reports the live inventory without allocating temporary storage (ec=$list_ec allocated=$allocated)"
fi

missing_tmp_out="$TMP_ROOT/list-missing-tmp.out"
TMPDIR="$TMP_ROOT/does-not-exist" bash "$RUNNER" --list >"$missing_tmp_out" 2>&1
missing_tmp_ec=$?
if [ "$missing_tmp_ec" -eq 0 ] && cmp -s "$missing_tmp_out" "$expected_list"; then
  pass "AC-OBS-2 --list survives unavailable temporary storage"
else
  fail "AC-OBS-2 --list survives unavailable temporary storage (ec=$missing_tmp_ec: $(cat "$missing_tmp_out"))"
fi

if grep -F -x -q -- "$SELF" "$expected_list"; then
  fail "AC-OBS-2 contract test stays outside the live smoke inventory"
else
  pass "AC-OBS-2 contract test stays outside the live smoke inventory"
fi

# --- AC-OBS-4: the passing path keeps its existing output and leaves no logs ---
rm -f "$FIXTURE_DIR/deliberate-fail.smoke.sh"
rm -rf "$FIXTURE_TMP"
mkdir -p "$FIXTURE_TMP"
green_out="$TMP_ROOT/green-run.out"
TMPDIR="$FIXTURE_TMP" bash "$FIXTURE_DIR/run-all.sh" >"$green_out" 2>&1
green_ec=$?
green_leftover="$(find "$FIXTURE_TMP" -mindepth 1 -print | wc -l | tr -d ' ')"
if [ "$green_ec" -eq 0 ] \
  && grep -F -x -q -- 'ok - deliberate-pass.smoke.sh' "$green_out" \
  && grep -F -x -q -- '--- 1/1 passed' "$green_out" \
  && [ "$green_leftover" -eq 0 ]; then
  pass "AC-OBS-4 passing suite keeps its success output and retains no diagnostics"
else
  fail "AC-OBS-4 passing suite keeps its success output and retains no diagnostics (ec=$green_ec leftover=$green_leftover output=$(cat "$green_out"))"
fi

usage_out="$TMP_ROOT/usage.out"
bash "$RUNNER" --list extra >"$usage_out" 2>&1
usage_ec=$?
if [ "$usage_ec" -eq 2 ] && grep -F -q -- 'usage: run-all.sh [--list] [--redact-values-file <path>]' "$usage_out"; then
  pass "AC-OBS-4 unknown argument shapes still fail with usage"
else
  fail "AC-OBS-4 unknown argument shapes still fail with usage (ec=$usage_ec: $(cat "$usage_out"))"
fi

# --- AC-INV-*: smoke inventory manifest parity ---
MANIFEST="$SCRIPT_DIR/smoke-inventory.manifest"

manifest_has_no_duplicates() {
  sort "$1" | uniq -d | grep -q .
  [ "$?" -ne 0 ]
}

inventory_matches_manifest() {
  list_file="$1"
  manifest_file="$2"
  manifest_has_no_duplicates "$manifest_file" \
    && diff <(sort "$list_file") <(sort "$manifest_file") >/dev/null 2>&1
}

undeclared_discovered() {
  list_file="$1"
  manifest_file="$2"
  comm -13 <(sort "$manifest_file") <(sort "$list_file")
}

declared_but_missing() {
  list_file="$1"
  manifest_file="$2"
  comm -23 <(sort "$manifest_file") <(sort "$list_file")
}

# --- AC-INV-1: the live inventory matches the manifest exactly ---
live_list="$TMP_ROOT/live-list.txt"
bash "$RUNNER" --list >"$live_list" 2>&1
live_ec=$?
if [ "$live_ec" -eq 0 ] \
  && inventory_matches_manifest "$live_list" "$MANIFEST"; then
  pass "AC-INV-1 live smoke inventory matches the manifest exactly"
else
  fail "AC-INV-1 live smoke inventory matches the manifest exactly (ec=$live_ec)"
fi

# Fixture suite for inventory drift: a runner copy beside one declared smoke
# and its own manifest copy.
INV_FIXTURE_DIR="$TMP_ROOT/inv-fixture-suite"
mkdir -p "$INV_FIXTURE_DIR"
cp "$RUNNER" "$INV_FIXTURE_DIR/run-all.sh"
cat > "$INV_FIXTURE_DIR/fixture-only.smoke.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
inv_manifest="$INV_FIXTURE_DIR/smoke-inventory.manifest"
printf '%s\n' 'fixture-only.smoke.sh' > "$inv_manifest"
inv_list="$TMP_ROOT/inv-list.txt"

# --- AC-INV-2: an added-but-undeclared smoke is caught ---
printf '#!/usr/bin/env bash\nexit 0\n' > "$INV_FIXTURE_DIR/undeclared-extra.smoke.sh"
bash "$INV_FIXTURE_DIR/run-all.sh" --list >"$inv_list" 2>&1
inv2_ec=$?
if [ "$inv2_ec" -eq 0 ] \
  && ! inventory_matches_manifest "$inv_list" "$inv_manifest" \
  && [ "$(undeclared_discovered "$inv_list" "$inv_manifest")" = 'undeclared-extra.smoke.sh' ]; then
  pass "AC-INV-2 added-but-undeclared smoke is reported as a manifest mismatch"
else
  fail "AC-INV-2 added-but-undeclared smoke is reported as a manifest mismatch (ec=$inv2_ec)"
fi

# --- AC-INV-3: a deleted/renamed-out smoke is caught ---
rm -f "$INV_FIXTURE_DIR/undeclared-extra.smoke.sh"
mv "$INV_FIXTURE_DIR/fixture-only.smoke.sh" "$INV_FIXTURE_DIR/fixture-only.test.sh"
printf '%s\n' 'fixture-only.smoke.sh' > "$inv_manifest"
bash "$INV_FIXTURE_DIR/run-all.sh" --list >"$inv_list" 2>&1
inv3_ec=$?
if [ "$inv3_ec" -eq 0 ] \
  && ! inventory_matches_manifest "$inv_list" "$inv_manifest" \
  && [ "$(declared_but_missing "$inv_list" "$inv_manifest")" = 'fixture-only.smoke.sh' ]; then
  pass "AC-INV-3 manifest smoke renamed out of the inventory is reported missing"
else
  fail "AC-INV-3 manifest smoke renamed out of the inventory is reported missing (ec=$inv3_ec)"
fi

# --- AC-INV-4: a duplicate manifest entry is itself invalid ---
printf '%s\n%s\n' 'fixture-only.smoke.sh' 'fixture-only.smoke.sh' > "$inv_manifest"
if ! manifest_has_no_duplicates "$inv_manifest" \
  && ! inventory_matches_manifest "$inv_list" "$inv_manifest"; then
  pass "AC-INV-4 duplicate manifest entry is rejected before set-equality"
else
  fail "AC-INV-4 duplicate manifest entry is rejected before set-equality"
fi

# --- AC-165-*: --for-paths selection and flake registry ---
# Fixture suite: runner copy beside two smokes, one covered by a fixture
# coverage manifest and one uncovered by it.
FP_FIXTURE_DIR="$TMP_ROOT/for-paths-suite"
FP_TMP="$TMP_ROOT/for-paths-tmp"
mkdir -p "$FP_FIXTURE_DIR" "$FP_TMP"
cp "$RUNNER" "$FP_FIXTURE_DIR/run-all.sh"
cat > "$FP_FIXTURE_DIR/covered-fixture.smoke.sh" <<'EOF'
#!/usr/bin/env bash
echo "ok   - covered fixture ran"
exit 0
EOF
cat > "$FP_FIXTURE_DIR/uncovered-fixture.smoke.sh" <<'EOF'
#!/usr/bin/env bash
echo "ok   - uncovered fixture ran"
exit 0
EOF
printf '%s\n' 'toolkit/scripts/covered-source.sh covered-fixture.smoke.sh' \
  > "$FP_FIXTURE_DIR/smoke-coverage.manifest"

# --- AC-165-1: a covered path runs only the matching subset ---
fp_out="$TMP_ROOT/for-paths-covered.out"
TMPDIR="$FP_TMP" bash "$FP_FIXTURE_DIR/run-all.sh" \
  --for-paths 'toolkit/scripts/covered-source.sh' >"$fp_out" 2>&1
fp_ec=$?
if [ "$fp_ec" -eq 0 ] \
  && grep -F -x -q -- 'ok - covered-fixture.smoke.sh' "$fp_out" \
  && ! grep -F -q -- 'uncovered-fixture' "$fp_out" \
  && grep -F -x -q -- '--- 1/1 passed' "$fp_out"; then
  pass "AC-165-1 covered path runs only the matching smoke subset"
else
  fail "AC-165-1 covered path runs only the matching smoke subset (ec=$fp_ec output=$(cat "$fp_out"))"
fi

# --- AC-165-2: a directory-prefix path also narrows correctly ---
fp_dir_out="$TMP_ROOT/for-paths-dir.out"
TMPDIR="$FP_TMP" bash "$FP_FIXTURE_DIR/run-all.sh" \
  --for-paths 'toolkit/scripts/' >"$fp_dir_out" 2>&1
fp_dir_ec=$?
if [ "$fp_dir_ec" -eq 0 ] \
  && grep -F -q -- 'ok - covered-fixture.smoke.sh' "$fp_dir_out" \
  && ! grep -F -q -- 'uncovered-fixture' "$fp_dir_out"; then
  pass "AC-165-2 directory-prefix path narrows via prefix matching"
else
  fail "AC-165-2 directory-prefix path narrows via prefix matching (ec=$fp_dir_ec output=$(cat "$fp_dir_out"))"
fi

# --- AC-165-3: an uncovered path fails open to the full suite ---
fp_fb_out="$TMP_ROOT/for-paths-fallback.out"
TMPDIR="$FP_TMP" bash "$FP_FIXTURE_DIR/run-all.sh" \
  --for-paths 'docs/nothing-covers-this.md' >"$fp_fb_out" 2>&1
fp_fb_ec=$?
if [ "$fp_fb_ec" -eq 0 ] \
  && grep -F -q -- 'WARNING: docs/nothing-covers-this.md has no known smoke coverage in smoke-coverage.manifest — falling back to the full suite' "$fp_fb_out" \
  && grep -F -q -- 'ok - covered-fixture.smoke.sh' "$fp_fb_out" \
  && grep -F -q -- 'ok - uncovered-fixture.smoke.sh' "$fp_fb_out" \
  && grep -F -x -q -- '--- 2/2 passed' "$fp_fb_out"; then
  pass "AC-165-3 uncovered path warns and falls back to the full suite"
else
  fail "AC-165-3 uncovered path warns and falls back to the full suite (ec=$fp_fb_ec output=$(cat "$fp_fb_out"))"
fi

# --- AC-165-3b: a covered path followed by an uncovered path still falls
# fully open (not a partial run of just the already-matched smoke) ---
fp_fb2_out="$TMP_ROOT/for-paths-fallback-partial.out"
TMPDIR="$FP_TMP" bash "$FP_FIXTURE_DIR/run-all.sh" \
  --for-paths 'toolkit/scripts/covered-source.sh
docs/nothing-covers-this.md' >"$fp_fb2_out" 2>&1
fp_fb2_ec=$?
if [ "$fp_fb2_ec" -eq 0 ] \
  && grep -F -q -- 'WARNING: docs/nothing-covers-this.md has no known smoke coverage in smoke-coverage.manifest — falling back to the full suite' "$fp_fb2_out" \
  && grep -F -q -- 'ok - covered-fixture.smoke.sh' "$fp_fb2_out" \
  && grep -F -q -- 'ok - uncovered-fixture.smoke.sh' "$fp_fb2_out" \
  && grep -F -x -q -- '--- 2/2 passed' "$fp_fb2_out"; then
  pass "AC-165-3b covered-then-uncovered path still falls open to the full suite, not a partial run"
else
  fail "AC-165-3b covered-then-uncovered path still falls open to the full suite, not a partial run (ec=$fp_fb2_ec output=$(cat "$fp_fb2_out"))"
fi

# --- AC-165-4: --for-paths with --list, or empty, is a usage error ---
fp_usage1_ec=0
bash "$FP_FIXTURE_DIR/run-all.sh" --list --for-paths 'toolkit/scripts/x.sh' \
  >"$TMP_ROOT/fp-usage1.out" 2>&1 || fp_usage1_ec=$?
fp_usage2_ec=0
bash "$FP_FIXTURE_DIR/run-all.sh" --for-paths '   ' >"$TMP_ROOT/fp-usage2.out" 2>&1 || fp_usage2_ec=$?
if [ "$fp_usage1_ec" -eq 2 ] && [ "$fp_usage2_ec" -eq 2 ]; then
  pass "AC-165-4 --for-paths misuse (--list combination, empty value) exits 2"
else
  fail "AC-165-4 --for-paths misuse (--list combination, empty value) exits 2 (ec1=$fp_usage1_ec ec2=$fp_usage2_ec)"
fi

# Flake-registry fixtures: one failing smoke per registry state.
make_flake_suite() {
  flake_dir="$1"
  mkdir -p "$flake_dir"
  cp "$RUNNER" "$flake_dir/run-all.sh"
  cat > "$flake_dir/flaky-fixture.smoke.sh" <<'EOF'
#!/usr/bin/env bash
echo "flaky fixture failed on purpose"
exit 5
EOF
  cat > "$flake_dir/passing-fixture.smoke.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
}

FUTURE_DATE="$(date -u -v+30d +%Y-%m-%d)"
PAST_DATE="$(date -u -v-30d +%Y-%m-%d)"

# --- AC-165-5: a registered, unexpired flake prints FLAKY and exits 0 ---
FLAKE_DIR="$TMP_ROOT/flake-active-suite"
FLAKE_TMP="$TMP_ROOT/flake-active-tmp"
make_flake_suite "$FLAKE_DIR"
mkdir -p "$FLAKE_TMP"
printf '%s\n' "flaky-fixture.smoke.sh testowner $FUTURE_DATE AC165_test_flake" \
  > "$FLAKE_DIR/flake-registry.manifest"
flake_out="$TMP_ROOT/flake-active.out"
TMPDIR="$FLAKE_TMP" bash "$FLAKE_DIR/run-all.sh" >"$flake_out" 2>&1
flake_ec=$?
if [ "$flake_ec" -eq 0 ] \
  && grep -F -x -q -- "FLAKY - flaky-fixture.smoke.sh (exit 5, known flake: owner=testowner expires=$FUTURE_DATE reason=AC165_test_flake)" "$flake_out" \
  && ! grep -F -q -- 'NOT OK - flaky-fixture' "$flake_out" \
  && grep -F -x -q -- '--- 1/2 passed (1 known-flake)' "$flake_out" \
  && grep -F -q -- 'diagnostic retained:' "$flake_out"; then
  pass "AC-165-5 unexpired registered flake reports FLAKY, retains diagnostics, exits 0"
else
  fail "AC-165-5 unexpired registered flake reports FLAKY, retains diagnostics, exits 0 (ec=$flake_ec output=$(cat "$flake_out"))"
fi

# --- AC-165-6: an expired flake registration graduates to a failure ---
EXP_DIR="$TMP_ROOT/flake-expired-suite"
EXP_TMP="$TMP_ROOT/flake-expired-tmp"
make_flake_suite "$EXP_DIR"
mkdir -p "$EXP_TMP"
printf '%s\n' "flaky-fixture.smoke.sh testowner $PAST_DATE AC165_test_flake" \
  > "$EXP_DIR/flake-registry.manifest"
exp_out="$TMP_ROOT/flake-expired.out"
TMPDIR="$EXP_TMP" bash "$EXP_DIR/run-all.sh" >"$exp_out" 2>&1
exp_ec=$?
if [ "$exp_ec" -eq 1 ] \
  && grep -F -x -q -- 'NOT OK - flaky-fixture.smoke.sh (exit 5)' "$exp_out" \
  && ! grep -F -q -- 'FLAKY -' "$exp_out" \
  && grep -F -x -q -- '--- 1/2 passed' "$exp_out"; then
  pass "AC-165-6 expired flake registration falls through to ordinary failure"
else
  fail "AC-165-6 expired flake registration falls through to ordinary failure (ec=$exp_ec output=$(cat "$exp_out"))"
fi

# --- AC-165-7: a malformed registry line warns and does not crash ---
MAL_DIR="$TMP_ROOT/flake-malformed-suite"
MAL_TMP="$TMP_ROOT/flake-malformed-tmp"
make_flake_suite "$MAL_DIR"
mkdir -p "$MAL_TMP"
printf '%s\n' 'flaky-fixture.smoke.sh testowner not-a-date AC165_test_flake' \
  > "$MAL_DIR/flake-registry.manifest"
mal_out="$TMP_ROOT/flake-malformed.out"
TMPDIR="$MAL_TMP" bash "$MAL_DIR/run-all.sh" >"$mal_out" 2>&1
mal_ec=$?
if [ "$mal_ec" -eq 1 ] \
  && grep -F -q -- 'WARNING: malformed flake-registry.manifest line for flaky-fixture.smoke.sh: flaky-fixture.smoke.sh testowner not-a-date AC165_test_flake' "$mal_out" \
  && grep -F -x -q -- 'NOT OK - flaky-fixture.smoke.sh (exit 5)' "$mal_out" \
  && grep -F -x -q -- '--- 1/2 passed' "$mal_out"; then
  pass "AC-165-7 malformed registry line warns, falls through to NOT OK, run continues"
else
  fail "AC-165-7 malformed registry line warns, falls through to NOT OK, run continues (ec=$mal_ec output=$(cat "$mal_out"))"
fi

# --- AC-165-8: zero-flake summary stays byte-identical to today ---
if grep -F -x -q -- '--- 2/2 passed' "$fp_fb_out" \
  && ! grep -F -q -- '(0 known-flake)' "$fp_fb_out" \
  && ! grep -F -q -- '(0 known-flake)' "$green_out"; then
  pass "AC-165-8 zero-flake summary line keeps today's exact text"
else
  fail "AC-165-8 zero-flake summary line keeps today's exact text"
fi

# --- AC-165-9: the live coverage manifest names only real smoke files ---
COVERAGE="$SCRIPT_DIR/smoke-coverage.manifest"
live_list2="$TMP_ROOT/live-list2.txt"
bash "$RUNNER" --list >"$live_list2" 2>&1
coverage_bad=""
cov_dups="$TMP_ROOT/coverage-dups.txt"
cov_lines="$TMP_ROOT/coverage-lines.txt"
cov_names="$TMP_ROOT/coverage-names.txt"
cov_live="$TMP_ROOT/coverage-live.txt"
sort "$COVERAGE" > "$cov_lines"
uniq -d "$cov_lines" > "$cov_dups"
[ -s "$cov_dups" ] && coverage_bad="$(cat "$cov_dups")"
awk '{print $2}' "$cov_lines" | sort -u > "$cov_names"
sort "$live_list2" > "$cov_live"
cov_only="$(comm -23 "$cov_names" "$cov_live")"
[ -n "$cov_only" ] && coverage_bad="${coverage_bad}${coverage_bad:+
}${cov_only}"
coverage_missing_src="$(grep -v '^#' "$COVERAGE" | awk '{print $1}' | while IFS= read -r cov_src; do
  [ -n "$cov_src" ] || continue
  [ -f "$SCRIPT_DIR/../../${cov_src#toolkit/}" ] || echo "$cov_src"
done)"
if [ -z "$coverage_bad" ] && [ -z "$coverage_missing_src" ]; then
  pass "AC-165-9 coverage manifest references only real smokes and real source files"
else
  fail "AC-165-9 coverage manifest references only real smokes and real source files (bad=$coverage_bad missing=$coverage_missing_src)"
fi

echo "---"
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASS"
  exit 0
fi
echo "$FAILURES CASE(S) FAILED"
exit 1
