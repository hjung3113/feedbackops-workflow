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

prepare_gate_fixture() {
  target="$1"
  fixture="$target/.agent-workflow/schemas/fixtures/round_state.valid.json"
  GATE_STATE="$target/.review/ROUND-STATE.json"
  GATE_TESTS="$target/.review/discovered-tests.txt"

  git init -q "$target"
  git -C "$target" config user.email smoke@example.test
  git -C "$target" config user.name smoke
  mkdir -p "$target/allowed"
  printf '%s\n' 'base' > "$target/allowed/file.txt"
  git -C "$target" add allowed/file.txt
  git -C "$target" commit -qm base
  git -C "$target" branch -M main
  base_sha="$(git -C "$target" rev-parse HEAD)"
  git -C "$target" switch -q -c feat/product-home-smoke
  printf '%s\n' 'changed' >> "$target/allowed/file.txt"
  git -C "$target" commit -am allowed-change -q

  cp "$fixture" "$GATE_STATE"
  node -e '
    const fs = require("fs");
    const [file, worktree, base] = process.argv.slice(1);
    const value = JSON.parse(fs.readFileSync(file, "utf8"));
    value.revision = 3;
    value.base_branch = "main";
    value.base_sha = base;
    value.worktree_path = worktree;
    value.contract.touch_allowlist = ["allowed/**"];
    value.contract.test_discovery_command = "printf '\''AC-1\\n'\''";
    value.acceptance.criteria = [{id: "AC-1"}];
    value.acceptance.expected_test_count = 1;
    value.decisions = [];
    value.commit_scope.commits = [];
    fs.writeFileSync(file, JSON.stringify(value));
  ' "$GATE_STATE" "$target" "$base_sha"
  printf '%s\n' 'test AC-1 behavior' > "$GATE_TESTS"
}

assert_gate_contract() {
  label="$1"
  scripts="$2"
  ac_output="$TMP_DIR/ac-output.txt"
  completion_output="$TMP_DIR/completion-output.json"

  bash "$scripts/ac-check.sh" --round-state "$GATE_STATE" --manifest-revision 3 --tests "$GATE_TESTS" > "$ac_output" 2>/dev/null
  ac_exit=$?
  if [ "$ac_exit" -eq 0 ] && grep -F -q 'OK revision 3: 1 acs mapped' "$ac_output"; then
    ok "$label executes ac-check through product home"
  else
    not_ok "$label executes ac-check through product home"
  fi

  bash "$scripts/completion-check.sh" --round-state "$GATE_STATE" --manifest-revision 3 > "$completion_output" 2>/dev/null
  completion_exit=$?
  if [ "$completion_exit" -eq 0 ] && node -e '
    const value = require(process.argv[1]);
    process.exit(value.status === "pass" && value.mismatches.length === 0 ? 0 : 1);
  ' "$completion_output"; then
    ok "$label executes completion-check through product home"
  else
    not_ok "$label executes completion-check through product home"
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
prepare_gate_fixture "$target_symlink"
assert_gate_contract "source layout" "$TOOLKIT_ROOT/scripts"
assert_gate_contract "symlink install" "$target_symlink/.agent-workflow/scripts"

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
assert_true "copy mode includes completion gate" test -e "$target_copy/.agent-workflow/scripts/completion-check.sh"
assert_true "copy mode includes schema files" test -e "$target_copy/.agent-workflow/schemas/blocker.schema.json"
assert_true "copy mode includes ROUND-STATE schema" test -e "$target_copy/.agent-workflow/schemas/round_state.schema.json"
assert_true "copy mode includes dependency-free schema validator" test -e "$target_copy/.agent-workflow/scripts/lib/json-schema-subset.cjs"
assert_true "copy mode includes playbook" test -e "$target_copy/.agent-workflow/docs/agents/multi-agent-workflow.md"
assert_true "installed playbook requires repository-native impact pass" grep -F -q '### Pre-scope-lock impact pass' "$target_copy/.agent-workflow/docs/agents/multi-agent-workflow.md"
assert_true "installed playbook requires ARCH feasibility evidence before decisions lock" grep -F -q '### ARCH feasibility evidence' "$target_copy/.agent-workflow/docs/agents/multi-agent-workflow.md"
assert_true "installed playbook provides reusable ARCH appendix row shape" grep -F -q 'concern | exact command | concise result | decision impact' "$target_copy/.agent-workflow/docs/agents/multi-agent-workflow.md"
assert_true "installed playbook makes criterion id the sole AC-ID authority" grep -F -q 'its `id` is the sole AC-ID authority, and its `statement` contains an explicit precondition and observable checkpoint' "$target_copy/.agent-workflow/docs/agents/multi-agent-workflow.md"
assert_true "installed playbook requires inline row fields without external authority" grep -F -q 'Do not use cited authoritative detail as a substitute for required inline content' "$target_copy/.agent-workflow/docs/agents/multi-agent-workflow.md"
assert_true "installed playbook requires allowlists only for privacy rows" grep -F -q 'When a row exercises a privacy boundary, its canonical `statement` also requires a **positive field allowlist assertion**' "$target_copy/.agent-workflow/docs/agents/multi-agent-workflow.md"
assert_true "installed playbook avoids non-privacy allowlist ceremony" grep -F -q 'non-privacy rows need no non-applicability ceremony' "$target_copy/.agent-workflow/docs/agents/multi-agent-workflow.md"
assert_true "copy mode includes skill entrypoint" test -e "$target_copy/.claude/skills/agent-workflow/SKILL.md"
assert_true "skill has no machine-specific toolkit path" sh -c "! grep -F '/Desktop/2026/feedbackops-workflow' '$target_copy/.claude/skills/agent-workflow/SKILL.md' >/dev/null"
assert_true "skill requires explicit toolkit self-test" grep -F -q -- '--self-test' "$target_copy/.claude/skills/agent-workflow/SKILL.md"
assert_true "skill documents toolkit self-application refusal" grep -F -q 'If `TARGET` and `WF` are the same repository, stop' "$target_copy/.claude/skills/agent-workflow/SKILL.md"

printf '%s\n' 'local target customization' > "$target_copy/.claude/skills/agent-workflow/SKILL.md"
assert_exit "reinstall without force exits zero" PASS bash "$INSTALL" "$target_copy" --mode copy
assert_true "reinstall without force preserves target skill" grep -F -q 'local target customization' "$target_copy/.claude/skills/agent-workflow/SKILL.md"
assert_exit "force reinstall exits zero" PASS bash "$INSTALL" "$target_copy" --mode copy --force
assert_true "force reinstall restores canonical skill" grep -F -q 'name: agent-workflow' "$target_copy/.claude/skills/agent-workflow/SKILL.md"
prepare_gate_fixture "$target_copy"
assert_gate_contract "copy install" "$target_copy/.agent-workflow/scripts"

product_export="$TMP_DIR/product export"
export_target="$TMP_DIR/export target"
mkdir -p "$product_export/docs" "$product_export/.claude/skills" "$export_target"
cp -R "$TOOLKIT_ROOT/scripts" "$product_export/scripts"
cp -R "$TOOLKIT_ROOT/.review/schemas" "$product_export/schemas"
cp -R "$TOOLKIT_ROOT/docs/agents" "$product_export/docs/agents"
cp -R "$TOOLKIT_ROOT/.claude/skills/agent-workflow" "$product_export/.claude/skills/agent-workflow"

assert_exit "git-metadata-free product export installs from a path with spaces" PASS \
  bash "$product_export/scripts/install-into.sh" "$export_target" --mode copy
assert_true "export install includes completion gate" test -e "$export_target/.agent-workflow/scripts/completion-check.sh"
assert_true "export install includes canonical schema" test -e "$export_target/.agent-workflow/schemas/round_state.schema.json"

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
