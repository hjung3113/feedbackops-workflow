#!/usr/bin/env bash
# Smoke test for scripts/install-into.sh.
# bash-3.2-compatible. Run: bash scripts/__tests__/install-into.smoke.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL="$SCRIPT_DIR/../install-into.sh"
PRODUCT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
REPOSITORY_ROOT="$(git -C "$PRODUCT_ROOT" rev-parse --show-toplevel)"
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

assert_exit_output() {
  name="$1"; expected="$2"; expected_output="$3"; shift 3
  output="$TMP_DIR/command-output.txt"
  "$@" >"$output" 2>&1
  actual_ec=$?
  if [ "$actual_ec" -eq "$expected" ] && grep -F -q -- "$expected_output" "$output"; then
    ok "$name"
  else
    not_ok "$name"
  fi
}

# release-contract: legacy-link-fixture-begin
make_legacy_links() {
  target="$1"
  legacy_root="$2"
  live="$3"

  mkdir -p "$target/.agent-workflow/docs" "$target/.claude/skills"
  if [ "$live" = "live" ]; then
    mkdir -p "$legacy_root/scripts" "$legacy_root/.review/schemas" \
      "$legacy_root/docs/agents" "$legacy_root/.claude/skills/agent-workflow"
  fi
  ln -s "$legacy_root/scripts" "$target/.agent-workflow/scripts"
  ln -s "$legacy_root/.review/schemas" "$target/.agent-workflow/schemas"
  ln -s "$legacy_root/docs/agents" "$target/.agent-workflow/docs/agents"
  ln -s "$legacy_root/.claude/skills/agent-workflow" "$target/.claude/skills/agent-workflow"
}

assert_legacy_links() {
  label="$1"
  target="$2"
  legacy_root="$3"
  assert_true "$label preserves scripts link" test "$(readlink "$target/.agent-workflow/scripts")" = "$legacy_root/scripts"
  assert_true "$label preserves schemas link" test "$(readlink "$target/.agent-workflow/schemas")" = "$legacy_root/.review/schemas"
  assert_true "$label preserves docs link" test "$(readlink "$target/.agent-workflow/docs/agents")" = "$legacy_root/docs/agents"
  assert_true "$label preserves skill link" test "$(readlink "$target/.claude/skills/agent-workflow")" = "$legacy_root/.claude/skills/agent-workflow"
}
# release-contract: legacy-link-fixture-end

assert_no_maintainer_leakage() {
  target="$1"
  assert_true "install excludes Matt skills" test ! -e "$target/.agents"
  assert_true "install excludes Matt lockfile" test ! -e "$target/skills-lock.json"
  assert_true "install excludes root instructions" test ! -e "$target/AGENTS.md"
  assert_true "install excludes maintainer tracker" test ! -e "$target/docs/agents/issue-tracker.md"
  assert_true "install excludes maintainer domain config" test ! -e "$target/docs/agents/domain.md"
  assert_true "install excludes maintainer triage config" test ! -e "$target/docs/agents/triage-labels.md"
  assert_true "install excludes plans" test ! -e "$target/docs/plans"
  assert_true "install excludes repository evidence" test ! -e "$target/.review/source"
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
assert_true "scripts link points at product scripts" test "$(readlink "$target_symlink/.agent-workflow/scripts")" = "$PRODUCT_ROOT/scripts"
assert_true "symlink mode creates schemas link" test -L "$target_symlink/.agent-workflow/schemas"
assert_true "schemas link points at product schemas" test "$(readlink "$target_symlink/.agent-workflow/schemas")" = "$PRODUCT_ROOT/schemas"
assert_true "symlink mode creates docs link" test -L "$target_symlink/.agent-workflow/docs/agents"
assert_true "docs link points at product docs" test "$(readlink "$target_symlink/.agent-workflow/docs/agents")" = "$PRODUCT_ROOT/docs/agents"
assert_true "symlink mode creates project skill link" test -L "$target_symlink/.claude/skills/agent-workflow"
assert_true "skill link points at product skill" test "$(readlink "$target_symlink/.claude/skills/agent-workflow")" = "$PRODUCT_ROOT/.claude/skills/agent-workflow"
assert_true "install creates target .review" test -d "$target_symlink/.review"
assert_no_maintainer_leakage "$target_symlink"
prepare_gate_fixture "$target_symlink"
assert_gate_contract "source layout" "$PRODUCT_ROOT/scripts"
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
assert_true "skill documents source self-application refusal" grep -F -q 'resolves to `TARGET`, stop' "$target_copy/.claude/skills/agent-workflow/SKILL.md"

printf '%s\n' 'local target customization' > "$target_copy/.claude/skills/agent-workflow/SKILL.md"
printf '%s\n' 'preserve runtime evidence' > "$target_copy/.review/force-sentinel"
printf '%s\n' 'preserve unrelated file' > "$target_copy/unrelated-sentinel"
assert_exit "reinstall without force exits zero" PASS bash "$INSTALL" "$target_copy" --mode copy
assert_true "reinstall without force preserves target skill" grep -F -q 'local target customization' "$target_copy/.claude/skills/agent-workflow/SKILL.md"
assert_exit "force reinstall exits zero" PASS bash "$INSTALL" "$target_copy" --mode copy --force
assert_true "force reinstall restores canonical skill" grep -F -q 'name: agent-workflow' "$target_copy/.claude/skills/agent-workflow/SKILL.md"
assert_true "force preserves target runtime evidence" grep -F -q 'preserve runtime evidence' "$target_copy/.review/force-sentinel"
assert_true "force preserves unrelated target files" grep -F -q 'preserve unrelated file' "$target_copy/unrelated-sentinel"
assert_no_maintainer_leakage "$target_copy"
prepare_gate_fixture "$target_copy"
assert_gate_contract "copy install" "$target_copy/.agent-workflow/scripts"

legacy_live="$TMP_DIR/legacy-live-target"
legacy_live_root="$TMP_DIR/legacy live root"
mkdir -p "$legacy_live"
make_legacy_links "$legacy_live" "$legacy_live_root" live
assert_exit_output "live legacy install is detected without mutation" 2 \
  "legacy absolute-symlink installation detected" bash "$INSTALL" "$legacy_live"
assert_exit_output "legacy diagnostic gives narrow migration command" 2 \
  "--migrate-legacy" bash "$INSTALL" "$legacy_live"
assert_legacy_links "live legacy refusal" "$legacy_live" "$legacy_live_root"

legacy_dangling="$TMP_DIR/legacy-dangling-target"
legacy_dangling_root="$TMP_DIR/missing legacy root"
mkdir -p "$legacy_dangling"
make_legacy_links "$legacy_dangling" "$legacy_dangling_root" dangling
assert_exit_output "dangling legacy install is detected" 2 \
  "legacy absolute-symlink installation detected" bash "$INSTALL" "$legacy_dangling"
assert_legacy_links "dangling legacy refusal" "$legacy_dangling" "$legacy_dangling_root"

assert_exit "legacy links migrate to current symlink mode" PASS \
  bash "$INSTALL" "$legacy_dangling" --migrate-legacy
assert_true "migrated scripts link uses product" test "$(readlink "$legacy_dangling/.agent-workflow/scripts")" = "$PRODUCT_ROOT/scripts"
assert_true "migrated schemas link uses product" test "$(readlink "$legacy_dangling/.agent-workflow/schemas")" = "$PRODUCT_ROOT/schemas"
assert_true "migrated docs link uses product" test "$(readlink "$legacy_dangling/.agent-workflow/docs/agents")" = "$PRODUCT_ROOT/docs/agents"
assert_true "migrated skill link uses product" test "$(readlink "$legacy_dangling/.claude/skills/agent-workflow")" = "$PRODUCT_ROOT/.claude/skills/agent-workflow"
prepare_gate_fixture "$legacy_dangling"
assert_gate_contract "migrated symlink install" "$legacy_dangling/.agent-workflow/scripts"

legacy_copy="$TMP_DIR/legacy-copy-target"
legacy_copy_root="$TMP_DIR/legacy-copy-root"
mkdir -p "$legacy_copy"
make_legacy_links "$legacy_copy" "$legacy_copy_root" live
assert_exit "legacy links migrate to copy snapshot" PASS \
  bash "$INSTALL" "$legacy_copy" --mode copy --migrate-legacy
assert_true "migrated copy scripts are real" test ! -L "$legacy_copy/.agent-workflow/scripts"
assert_true "migrated copy schemas are real" test ! -L "$legacy_copy/.agent-workflow/schemas"
assert_true "migrated copy includes completion gate" test -e "$legacy_copy/.agent-workflow/scripts/completion-check.sh"
assert_true "migrated copy includes schema" test -e "$legacy_copy/.agent-workflow/schemas/round_state.schema.json"
prepare_gate_fixture "$legacy_copy"
assert_gate_contract "migrated copy install" "$legacy_copy/.agent-workflow/scripts"

# release-contract: repository-legacy-fixture-begin
legacy_mixed="$TMP_DIR/legacy-mixed-target"
mkdir -p "$legacy_mixed/.agent-workflow/docs" "$legacy_mixed/.claude/skills/agent-workflow"
ln -s "$REPOSITORY_ROOT/scripts" "$legacy_mixed/.agent-workflow/scripts"
ln -s "$REPOSITORY_ROOT/.review/schemas" "$legacy_mixed/.agent-workflow/schemas"
ln -s "$REPOSITORY_ROOT/docs/agents" "$legacy_mixed/.agent-workflow/docs/agents"
# release-contract: repository-legacy-fixture-end
printf '%s\n' 'custom skill stays' > "$legacy_mixed/.claude/skills/agent-workflow/SKILL.md"
assert_exit "known partial legacy links migrate without deleting customization" PASS \
  bash "$INSTALL" "$legacy_mixed" --migrate-legacy
assert_true "mixed migration rewires scripts" test "$(readlink "$legacy_mixed/.agent-workflow/scripts")" = "$PRODUCT_ROOT/scripts"
assert_true "mixed migration rewires schemas" test "$(readlink "$legacy_mixed/.agent-workflow/schemas")" = "$PRODUCT_ROOT/schemas"
assert_true "mixed migration rewires docs" test "$(readlink "$legacy_mixed/.agent-workflow/docs/agents")" = "$PRODUCT_ROOT/docs/agents"
assert_true "mixed migration preserves custom skill" grep -F -q 'custom skill stays' "$legacy_mixed/.claude/skills/agent-workflow/SKILL.md"

legacy_conflict="$TMP_DIR/legacy-conflict-target"
legacy_conflict_root="$TMP_DIR/legacy-conflict-root"
mkdir -p "$legacy_conflict"
make_legacy_links "$legacy_conflict" "$legacy_conflict_root" dangling
assert_exit_output "force and legacy migration are mutually exclusive" 2 \
  "cannot be combined" bash "$INSTALL" "$legacy_conflict" --force --migrate-legacy
assert_legacy_links "conflicting flags" "$legacy_conflict" "$legacy_conflict_root"

legacy_rollback="$TMP_DIR/legacy-rollback-target"
legacy_rollback_root="$TMP_DIR/legacy-rollback-root"
fake_bin="$TMP_DIR/fake-bin"
cp_count="$TMP_DIR/cp-count"
mkdir -p "$legacy_rollback" "$fake_bin"
make_legacy_links "$legacy_rollback" "$legacy_rollback_root" live
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'count_file="${CP_COUNT_FILE:?}"' \
  'count=0' \
  '[[ -f "$count_file" ]] && count="$(cat "$count_file")"' \
  'count=$((count + 1))' \
  'printf '\''%s\n'\'' "$count" > "$count_file"' \
  '[[ "$count" -eq 4 ]] && exit 97' \
  'exec /bin/cp "$@"' > "$fake_bin/cp"
chmod +x "$fake_bin/cp"
assert_exit_output "failed copy migration reports rollback" 97 \
  "restoring the previous installation" env PATH="$fake_bin:$PATH" CP_COUNT_FILE="$cp_count" \
  bash "$INSTALL" "$legacy_rollback" --mode copy --migrate-legacy
assert_legacy_links "failed copy migration rollback" "$legacy_rollback" "$legacy_rollback_root"

for custom_mode in symlink copy; do
  custom_target="$TMP_DIR/custom-$custom_mode"
  custom_docs="$TMP_DIR/custom-docs-$custom_mode"
  mkdir -p "$custom_target/.agent-workflow/schemas" "$custom_target/.agent-workflow/docs" \
    "$custom_target/.claude/skills" "$custom_docs"
  printf '%s\n' 'custom scripts' > "$custom_target/.agent-workflow/scripts"
  printf '%s\n' 'custom schema' > "$custom_target/.agent-workflow/schemas/custom-marker"
  ln -s "$custom_docs" "$custom_target/.agent-workflow/docs/agents"
  ln -s "../../missing-custom-skill" "$custom_target/.claude/skills/agent-workflow"
  assert_exit "custom destinations are preserved in $custom_mode mode" PASS \
    bash "$INSTALL" "$custom_target" --mode "$custom_mode"
  assert_true "$custom_mode preserves custom scripts" grep -F -q 'custom scripts' "$custom_target/.agent-workflow/scripts"
  assert_true "$custom_mode preserves custom schemas" grep -F -q 'custom schema' "$custom_target/.agent-workflow/schemas/custom-marker"
  assert_true "$custom_mode preserves custom docs link" test "$(readlink "$custom_target/.agent-workflow/docs/agents")" = "$custom_docs"
  assert_true "$custom_mode preserves custom skill link" test "$(readlink "$custom_target/.claude/skills/agent-workflow")" = "../../missing-custom-skill"
  assert_exit_output "migration refuses custom $custom_mode destinations" 2 \
    "no recognized legacy" bash "$INSTALL" "$custom_target" --mode "$custom_mode" --migrate-legacy
done

product_export="$TMP_DIR/product export"
export_target="$TMP_DIR/export target"
mkdir -p "$product_export/docs" "$product_export/.claude/skills" "$export_target"
product_export_real="$(cd "$product_export" && pwd -P)"
cp -R "$PRODUCT_ROOT/scripts" "$product_export/scripts"
cp -R "$PRODUCT_ROOT/schemas" "$product_export/schemas"
cp -R "$PRODUCT_ROOT/docs/agents" "$product_export/docs/agents"
cp -R "$PRODUCT_ROOT/.claude/skills/agent-workflow" "$product_export/.claude/skills/agent-workflow"

assert_exit "git-metadata-free product export installs from a path with spaces" PASS \
  bash "$product_export/scripts/install-into.sh" "$export_target" --mode copy
assert_true "export install includes completion gate" test -e "$export_target/.agent-workflow/scripts/completion-check.sh"
assert_true "export install includes canonical schema" test -e "$export_target/.agent-workflow/schemas/round_state.schema.json"
assert_no_maintainer_leakage "$export_target"
prepare_gate_fixture "$export_target"
assert_gate_contract "git-free export copy install" "$export_target/.agent-workflow/scripts"

export_legacy_target="$TMP_DIR/export legacy target"
export_legacy_root="$TMP_DIR/export old root"
export_legacy_output="$TMP_DIR/export-legacy-output.txt"
mkdir -p "$export_legacy_target"
make_legacy_links "$export_legacy_target" "$export_legacy_root" dangling
bash "$product_export/scripts/install-into.sh" "$export_legacy_target" >"$export_legacy_output" 2>&1
export_legacy_status=$?
export_legacy_command="$(grep -- '--migrate-legacy$' "$export_legacy_output")"
assert_true "spaced export legacy detection exits two" test "$export_legacy_status" -eq 2
assert_true "spaced export migration guidance quotes product path" grep -F -q 'product\ export/scripts/install-into.sh' "$export_legacy_output"
assert_exit "spaced export migration guidance is executable" PASS bash -c "$export_legacy_command"
assert_true "spaced export migration rewires scripts" test "$(readlink "$export_legacy_target/.agent-workflow/scripts")" = "$product_export_real/scripts"

assert_exit "refuses product root" FAIL bash "$INSTALL" "$PRODUCT_ROOT"
assert_exit "errors on missing target path" FAIL bash "$INSTALL" "$TMP_DIR/does-not-exist"

assert_true "README documents copy snapshot" grep -F -q 'snapshot' "$PRODUCT_ROOT/README.md"
assert_true "README documents narrow legacy migration" grep -F -q -- '--migrate-legacy' "$PRODUCT_ROOT/README.md"
assert_true "README documents explicit copy update" grep -F -q -- '--mode copy --force' "$PRODUCT_ROOT/README.md"
assert_true "adoption guide names managed scripts destination" grep -F -q '.agent-workflow/scripts' "$PRODUCT_ROOT/.claude/skills/agent-workflow/references/adoption.md"
assert_true "adoption guide names managed skill destination" grep -F -q '.claude/skills/agent-workflow' "$PRODUCT_ROOT/.claude/skills/agent-workflow/references/adoption.md"
assert_true "adoption usage documents mutually exclusive migration flags" grep -F -q -- '[--migrate-legacy|--force]' "$PRODUCT_ROOT/.claude/skills/agent-workflow/references/adoption.md"

echo "---"
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASS"
  exit 0
else
  echo "$FAILURES CASE(S) FAILED"
  exit 1
fi
