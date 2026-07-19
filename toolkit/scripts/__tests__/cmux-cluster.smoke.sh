#!/usr/bin/env bash
# Smoke test for scripts/cmux-cluster.sh early guard paths only.
# bash-3.2-compatible. Run: bash scripts/__tests__/cmux-cluster.smoke.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CMUX_CLUSTER="$SCRIPT_DIR/../cmux-cluster.sh"
TMP_ROOT="$(mktemp -d)"
REPO="$TMP_ROOT/repo"

trap 'rm -rf "$TMP_ROOT"' EXIT

FAILURES=0

mkdir -p "$REPO"
git init -q "$REPO"
git -C "$REPO" -c user.name="Smoke Test" -c user.email="smoke@example.test" commit --allow-empty -q -m "init"

run_case() {
  name="$1"; expected_ec="$2"; expected_stderr="$3"; shift 3
  stderr_file="$TMP_ROOT/$name.stderr"

  (cd "$REPO" && bash "$CMUX_CLUSTER" "$@") >/dev/null 2>"$stderr_file"
  actual_ec=$?

  ok=1
  if [ "$actual_ec" -ne "$expected_ec" ]; then
    ok=0
  fi
  if [ -n "$expected_stderr" ] && ! grep -q "$expected_stderr" "$stderr_file"; then
    ok=0
  fi

  if [ "$ok" -eq 1 ]; then
    echo "ok   - $name (expected exit $expected_ec, got $actual_ec)"
  else
    echo "NOT OK - $name (expected exit $expected_ec, got $actual_ec)"
    if [ -n "$expected_stderr" ]; then
      echo "        expected stderr to contain: $expected_stderr"
    fi
    FAILURES=$((FAILURES + 1))
  fi
}

run_case "missing both args is nonzero" 1 "usage: cmux-cluster.sh" 
run_case "missing slug is nonzero" 1 "usage: cmux-cluster.sh" 42

wt_missing_infra="$TMP_ROOT/wt-42-missing-infra"
mkdir -p "$wt_missing_infra"
run_case "existing worktree without workflow infra exits 1" 1 "missing workflow infra" 42 missing-infra

wt_old_layout="$TMP_ROOT/wt-43-old-layout"
mkdir -p "$wt_old_layout/scripts" "$wt_old_layout/.review/schemas"
touch "$wt_old_layout/scripts/codex-safe.sh"
run_case "old source-checkout layout is not installed workflow infra" 1 "missing workflow infra" 43 old-layout

wt_not_ready="$TMP_ROOT/wt-44-not-ready"
mkdir -p "$wt_not_ready/.agent-workflow/scripts" "$wt_not_ready/.agent-workflow/schemas"
touch "$wt_not_ready/.agent-workflow/scripts/codex-safe.sh"
run_case "installed workflow infra advances to deps env readiness" 1 "not dispatch-ready" 44 not-ready

echo "---"
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASS"
  exit 0
else
  echo "$FAILURES CASE(S) FAILED"
  exit 1
fi
