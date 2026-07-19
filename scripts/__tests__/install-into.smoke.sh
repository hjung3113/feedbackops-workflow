#!/usr/bin/env bash
# Smoke test for scripts/install-into.sh.
# bash-3.2-compatible. Run: bash scripts/__tests__/install-into.smoke.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL="$SCRIPT_DIR/../install-into.sh"
TOOLKIT_ROOT="$(cd "$SCRIPT_DIR/../.." && git rev-parse --show-toplevel)"
TOOLKIT_ROOT="$(cd "$TOOLKIT_ROOT" && pwd -P)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAILURES=0

ok() {
  echo "ok   - $1"
}

not_ok() {
  echo "NOT OK - $1"
  FAILURES=$((FAILURES + 1))
}

assert_true() {
  name="$1"; shift
  if "$@"; then
    ok "$name"
  else
    not_ok "$name"
  fi
}

assert_exit() {
  name="$1"; expected="$2"; shift 2
  "$@" >/dev/null 2>&1
  actual_ec=$?
  if [ "$expected" = "PASS" ] && [ "$actual_ec" -eq 0 ]; then
    ok "$name"
  elif [ "$expected" = "FAIL" ] && [ "$actual_ec" -ne 0 ]; then
    ok "$name"
  else
    not_ok "$name"
  fi
}

target_symlink="$TMP_DIR/target-symlink"
mkdir -p "$target_symlink"

assert_exit "symlink mode exits zero" PASS bash "$INSTALL" "$target_symlink"
assert_true "symlink mode creates scripts link" test -L "$target_symlink/.agent-workflow/scripts"
assert_true "scripts link points at toolkit scripts" test "$(readlink "$target_symlink/.agent-workflow/scripts")" = "$TOOLKIT_ROOT/scripts"
assert_true "symlink mode creates schemas link" test -L "$target_symlink/.agent-workflow/schemas"
assert_true "schemas link points at toolkit schemas" test "$(readlink "$target_symlink/.agent-workflow/schemas")" = "$TOOLKIT_ROOT/.review/schemas"
assert_true "symlink mode creates docs link" test -L "$target_symlink/.agent-workflow/docs/agents"
assert_true "docs link points at toolkit docs" test "$(readlink "$target_symlink/.agent-workflow/docs/agents")" = "$TOOLKIT_ROOT/docs/agents"
assert_true "symlink mode creates project skill link" test -L "$target_symlink/.claude/skills/agent-workflow"
assert_true "skill link points at toolkit skill" test "$(readlink "$target_symlink/.claude/skills/agent-workflow")" = "$TOOLKIT_ROOT/.claude/skills/agent-workflow"
assert_true "install creates target .review" test -d "$target_symlink/.review"

target_copy="$TMP_DIR/target-copy"
mkdir -p "$target_copy"

assert_exit "copy mode exits zero" PASS bash "$INSTALL" "$target_copy" --mode copy
assert_true "copy mode creates real scripts dir" test -d "$target_copy/.agent-workflow/scripts"
assert_true "copy mode scripts is not a symlink" test ! -L "$target_copy/.agent-workflow/scripts"
assert_true "copy mode creates real schemas dir" test -d "$target_copy/.agent-workflow/schemas"
assert_true "copy mode schemas is not a symlink" test ! -L "$target_copy/.agent-workflow/schemas"
assert_true "copy mode creates real docs dir" test -d "$target_copy/.agent-workflow/docs/agents"
assert_true "copy mode docs is not a symlink" test ! -L "$target_copy/.agent-workflow/docs/agents"
assert_true "copy mode creates real project skill" test -d "$target_copy/.claude/skills/agent-workflow"
assert_true "copy mode skill is not a symlink" test ! -L "$target_copy/.claude/skills/agent-workflow"
assert_true "copy mode includes install script" test -e "$target_copy/.agent-workflow/scripts/install-into.sh"
assert_true "copy mode includes schema files" test -e "$target_copy/.agent-workflow/schemas/blocker.schema.json"
assert_true "copy mode includes ROUND-STATE schema" test -e "$target_copy/.agent-workflow/schemas/round_state.schema.json"
assert_true "copy mode includes dependency-free schema validator" test -e "$target_copy/.agent-workflow/scripts/lib/json-schema-subset.cjs"
assert_true "copy mode includes playbook" test -e "$target_copy/.agent-workflow/docs/agents/multi-agent-workflow.md"
assert_true "copy mode includes skill entrypoint" test -e "$target_copy/.claude/skills/agent-workflow/SKILL.md"
assert_true "skill has no machine-specific toolkit path" sh -c "! grep -F '/Desktop/2026/feedbackops-workflow' '$target_copy/.claude/skills/agent-workflow/SKILL.md' >/dev/null"
assert_true "skill requires explicit toolkit self-test" grep -F -q -- '--self-test' "$target_copy/.claude/skills/agent-workflow/SKILL.md"
assert_true "skill documents toolkit self-application refusal" grep -F -q 'If `TARGET` and `WF` are the same repository, stop' "$target_copy/.claude/skills/agent-workflow/SKILL.md"

printf '%s\n' 'local target customization' > "$target_copy/.claude/skills/agent-workflow/SKILL.md"
assert_exit "reinstall without force exits zero" PASS bash "$INSTALL" "$target_copy" --mode copy
assert_true "reinstall without force preserves target skill" grep -F -q 'local target customization' "$target_copy/.claude/skills/agent-workflow/SKILL.md"
assert_exit "force reinstall exits zero" PASS bash "$INSTALL" "$target_copy" --mode copy --force
assert_true "force reinstall restores canonical skill" grep -F -q 'name: agent-workflow' "$target_copy/.claude/skills/agent-workflow/SKILL.md"

assert_exit "refuses toolkit root" FAIL bash "$INSTALL" "$TOOLKIT_ROOT"
assert_exit "errors on missing target path" FAIL bash "$INSTALL" "$TMP_DIR/does-not-exist"

echo "---"
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASS"
  exit 0
else
  echo "$FAILURES CASE(S) FAILED"
  exit 1
fi
