#!/usr/bin/env bash
# Smoke test for the repository/product authority boundary.
# bash-3.2-compatible. Run from the source repository only.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
PRODUCT_ROOT="$REPOSITORY_ROOT/toolkit"
FAILURES=0

ok() { echo "ok   - $1"; }
not_ok() { echo "NOT OK - $1"; FAILURES=$((FAILURES + 1)); }

assert_exists() {
  name="$1"
  path="$2"
  if [ -e "$path" ]; then ok "$name"; else not_ok "$name"; fi
}

assert_absent() {
  name="$1"
  path="$2"
  if [ ! -e "$path" ]; then ok "$name"; else not_ok "$name"; fi
}

assert_contains() {
  name="$1"
  needle="$2"
  path="$3"
  if grep -F -q -- "$needle" "$path"; then ok "$name"; else not_ok "$name"; fi
}

assert_exists "product scoped instructions" "$PRODUCT_ROOT/AGENTS.md"
assert_exists "product README" "$PRODUCT_ROOT/README.md"
assert_exists "product STATUS" "$PRODUCT_ROOT/STATUS.md"
assert_exists "product env example" "$PRODUCT_ROOT/.env.example"
assert_exists "product scripts" "$PRODUCT_ROOT/scripts/ac-check.sh"
assert_exists "product smoke suite" "$PRODUCT_ROOT/scripts/__tests__/run-all.sh"
assert_exists "product schemas" "$PRODUCT_ROOT/schemas/round_state.schema.json"
assert_exists "product schema fixtures" "$PRODUCT_ROOT/schemas/fixtures/round_state.valid.json"
assert_exists "product playbook" "$PRODUCT_ROOT/docs/agents/multi-agent-workflow.md"
assert_exists "product conductor persona" "$PRODUCT_ROOT/docs/agents/conductor-persona.md"
assert_exists "product visual reviewer persona" "$PRODUCT_ROOT/docs/agents/visual-reviewer-persona.md"
assert_exists "product historical trial log" "$PRODUCT_ROOT/docs/agents/workflow-trial-log.md"
assert_exists "product issue reporting" "$PRODUCT_ROOT/docs/agents/issue-reporting.md"
assert_exists "canonical product skill" "$PRODUCT_ROOT/.claude/skills/agent-workflow/SKILL.md"
assert_exists "product adoption guide" "$PRODUCT_ROOT/.claude/skills/agent-workflow/references/adoption.md"

assert_exists "root maintainer instructions" "$REPOSITORY_ROOT/AGENTS.md"
assert_exists "root Claude pointer" "$REPOSITORY_ROOT/CLAUDE.md"
assert_exists "root repository map" "$REPOSITORY_ROOT/README.md"
assert_exists "root Matt skills lock" "$REPOSITORY_ROOT/skills-lock.json"
assert_exists "root imported review skill" "$REPOSITORY_ROOT/.agents/skills/code-review/SKILL.md"
assert_exists "root maintainer issue tracker" "$REPOSITORY_ROOT/docs/agents/issue-tracker.md"
assert_exists "root maintainer domain config" "$REPOSITORY_ROOT/docs/agents/domain.md"
assert_exists "root maintainer triage config" "$REPOSITORY_ROOT/docs/agents/triage-labels.md"
assert_exists "root plans" "$REPOSITORY_ROOT/docs/plans"
assert_exists "root CI" "$REPOSITORY_ROOT/.github/workflows/smoke.yml"
assert_exists "root hook" "$REPOSITORY_ROOT/.githooks/post-merge"
assert_exists "root runtime evidence" "$REPOSITORY_ROOT/.review"

assert_absent "no Matt-directory product skill" "$REPOSITORY_ROOT/.agents/skills/agent-workflow"
assert_absent "no root Claude product skill" "$REPOSITORY_ROOT/.claude/skills/agent-workflow"
assert_absent "no root product scripts" "$REPOSITORY_ROOT/scripts"
assert_absent "no root product schemas" "$REPOSITORY_ROOT/.review/schemas"
assert_absent "no root product STATUS" "$REPOSITORY_ROOT/STATUS.md"
assert_absent "no root product env example" "$REPOSITORY_ROOT/.env.example"
assert_absent "no root product playbook" "$REPOSITORY_ROOT/docs/agents/multi-agent-workflow.md"

if grep -R -F 'docs/agents/issue-tracker.md' \
  "$PRODUCT_ROOT/docs" "$PRODUCT_ROOT/.claude/skills/agent-workflow" >/dev/null 2>&1; then
  not_ok "product documents do not depend on maintainer tracker"
else
  ok "product documents do not depend on maintainer tracker"
fi

assert_contains "CI runs product smoke suite" 'bash toolkit/scripts/__tests__/run-all.sh' "$REPOSITORY_ROOT/.github/workflows/smoke.yml"
assert_contains "hook routes to product rebase helper" 'toolkit/scripts/rebase-inflight.sh' "$REPOSITORY_ROOT/.githooks/post-merge"
assert_contains "maintainer instructions route to product scripts" 'toolkit/scripts/' "$REPOSITORY_ROOT/AGENTS.md"
assert_contains "root README routes to product README" 'toolkit/README.md' "$REPOSITORY_ROOT/README.md"
assert_contains "trial log remains marked historical" 'Historical record' "$PRODUCT_ROOT/docs/agents/workflow-trial-log.md"
assert_contains "trial log preserves dated legacy evidence" 'feature/31-idem-audit-assertion' "$PRODUCT_ROOT/docs/agents/workflow-trial-log.md"

echo "---"
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASS"
  exit 0
fi
echo "$FAILURES CASE(S) FAILED"
exit 1
