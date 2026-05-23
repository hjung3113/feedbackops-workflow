#!/usr/bin/env bash
# Smoke test that the codex worker wrapper preserves sandbox network denial.
set -u

repo_root="$(git rev-parse --show-toplevel)"
SCRIPT="$repo_root/scripts/codex-safe.sh"
FAILURES=0

run_case() {
  name="$1"; expected="$2"; command="$3"
  if eval "$command"; then actual="PASS"; else actual="FAIL"; fi
  if [ "$actual" = "$expected" ]; then
    echo "ok - $name (expected $expected, got $actual)"
  else
    echo "NOT OK - $name (expected $expected, got $actual)"
    FAILURES=$((FAILURES + 1))
  fi
}

run_live_probe() {
  out=".review/netdeny-probe.$$"
  trap 'rm -f "$repo_root/$out"' EXIT
  rm -f "$repo_root/$out"

  (
    cd "$repo_root" &&
      codex exec --sandbox workspace-write --cd "$repo_root" "Run exactly this one command from the repo root and nothing else: node scripts/__tests__/net-deny-probe.mjs 127.0.0.1 5434 $out"
  ) >/dev/null 2>&1

  if [ ! -s "$repo_root/$out" ]; then
    echo "NOT OK - loopback blocked in sandbox (probe output missing)"
    FAILURES=$((FAILURES + 1))
  elif grep -q "BLOCKED" "$repo_root/$out"; then
    echo "ok - loopback blocked in sandbox"
  else
    echo "NOT OK - loopback blocked in sandbox ($(cat "$repo_root/$out"))"
    FAILURES=$((FAILURES + 1))
  fi

  rm -f "$repo_root/$out"
}

run_case "wrapper pins workspace-write" PASS "grep -q -- '--sandbox workspace-write' \"\$SCRIPT\""
run_case "wrapper has no danger-full-access" PASS "! grep -q -- 'danger-full-access' \"\$SCRIPT\""
run_case "wrapper grants no network_access" PASS "! grep -q -- 'network_access' \"\$SCRIPT\""

if [ "${RUN_LIVE_SANDBOX_PROBE:-}" = "1" ] && command -v codex >/dev/null 2>&1; then
  run_live_probe
else
  echo "ok - SKIP live in-sandbox probe (set RUN_LIVE_SANDBOX_PROBE=1 and ensure codex on PATH)"
fi

echo "---"
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASS"
  exit 0
else
  echo "$FAILURES CASE(S) FAILED"
  exit 1
fi
