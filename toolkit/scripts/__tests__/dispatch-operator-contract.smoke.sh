#!/usr/bin/env bash
# Smoke test for the documented dispatch/RUN operator contract.
# bash-3.2-compatible. Run: bash scripts/__tests__/dispatch-operator-contract.smoke.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PRODUCT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLAYBOOK="$PRODUCT_ROOT/docs/agents/multi-agent-workflow.md"
README="$PRODUCT_ROOT/README.md"
LIFECYCLE="$PRODUCT_ROOT/docs/agents/artifact-lifecycle.md"
CONDUCTOR="$PRODUCT_ROOT/docs/agents/conductor-persona.md"
ADOPTION="$PRODUCT_ROOT/.claude/skills/agent-workflow/references/adoption.md"

FAILURES=0
pass() { echo "ok   - $1"; }
fail() { echo "NOT OK - $1"; FAILURES=$((FAILURES + 1)); }

assert_contains() {
  label="$1"
  needle="$2"
  file="$3"
  if grep -F -q -- "$needle" "$file"; then
    pass "$label"
  else
    fail "$label"
  fi
}

assert_contains "playbook preserves the dispatch exit code" \
  'Capture the dispatch command exit code directly; do not pipe the command through `tail`, `tee`, or another consumer' \
  "$PLAYBOOK"
assert_contains "playbook binds polling to the current dispatch identity" \
  'Accept RUN/BLOCKER only when its `mtime + started_at` identity is fresh relative to the current dispatch' \
  "$PLAYBOOK"
assert_contains "playbook treats exited as process termination only" \
  '`status:"exited"` means process termination, not task completion' \
  "$PLAYBOOK"
assert_contains "playbook requires process confirmation for retry ambiguity" \
  'confirm that the recorded process is absent before treating an ambiguous retry as terminal' \
  "$PLAYBOOK"
assert_contains "playbook rejects artifact absence as a death signal" \
  'Missing artifacts alone do not prove that a dispatch is dead' \
  "$PLAYBOOK"
assert_contains "playbook gives sol medium runs an operator budget" \
  'allow at least eight minutes before manual intervention' \
  "$PLAYBOOK"
assert_contains "playbook documents stderr liveness diagnosis" \
  'A growing attempt stderr file is an additional liveness signal' \
  "$PLAYBOOK"
assert_contains "playbook documents stdin block diagnosis" \
  'a small frozen stderr file plus a live process can indicate a stdin block' \
  "$PLAYBOOK"
assert_contains "playbook binds completion evidence to live HEAD" \
  'Bind REVIEW and VERIFY evidence to the live HEAD' \
  "$PLAYBOOK"
assert_contains "README points operators to the liveness rules" \
  '디스패치 오퍼레이터 규칙' \
  "$README"
assert_contains "artifact lifecycle documents issue-scoped RUN identity" \
  'issue-scoped liveness snapshot' \
  "$LIFECYCLE"
assert_contains "conductor persona preserves dispatch status and freshness" \
  'preserve the dispatch command exit code' \
  "$CONDUCTOR"
assert_contains "adoption guide routes targets to operator rules" \
  'dispatch liveness operator rules' \
  "$ADOPTION"

echo "---"
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASS"
  exit 0
fi

echo "$FAILURES CASE(S) FAILED"
exit 1
