#!/usr/bin/env bash
# Smoke test for scripts/codex-safe.sh argument validation only.
# bash-3.2-compatible. Run: bash scripts/__tests__/codex-safe.smoke.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CODEX_SAFE="$SCRIPT_DIR/../codex-safe.sh"
FAILURES=0

run_exit_case() {
  name="$1"; expected="$2"; shift 2
  bash "$CODEX_SAFE" "$@" >/dev/null 2>&1
  actual=$?
  if [ "$actual" -eq "$expected" ]; then
    echo "ok   - $name (exit $actual)"
  else
    echo "NOT OK - $name (expected exit $expected, got $actual)"
    FAILURES=$((FAILURES + 1))
  fi
}

run_nonzero_case() {
  name="$1"; shift
  bash "$CODEX_SAFE" "$@" >/dev/null 2>&1
  actual=$?
  if [ "$actual" -ne 0 ]; then
    echo "ok   - $name (exit $actual)"
  else
    echo "NOT OK - $name (expected non-zero exit, got 0)"
    FAILURES=$((FAILURES + 1))
  fi
}

run_exit_case "missing --issue exits 2" 2 --prompt "hello"
run_exit_case "missing prompt exits 2" 2 --issue 33
run_nonzero_case "unknown arg exits non-zero" --bogus

if grep -q -- '--sandbox workspace-write' "$CODEX_SAFE"; then
  echo "ok   - wrapper pins --sandbox workspace-write"
else
  echo "NOT OK - wrapper should contain --sandbox workspace-write"
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
