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

echo "---"
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASS"
  exit 0
fi
echo "$FAILURES CASE(S) FAILED"
exit 1
