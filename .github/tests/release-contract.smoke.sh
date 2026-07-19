#!/usr/bin/env bash
# Release gate for the repository/product authority and installation boundary.
# bash-3.2-compatible. Run from the source repository only.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
PRODUCT_ROOT="$REPOSITORY_ROOT/toolkit"
FAILURES=0
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

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

assert_command() {
  name="$1"
  shift
  if "$@"; then ok "$name"; else not_ok "$name"; fi
}

assert_equals() {
  name="$1"
  expected="$2"
  actual="$3"
  if [ "$expected" = "$actual" ]; then ok "$name"; else not_ok "$name"; fi
}

assert_rejects() {
  name="$1"
  needle="$2"
  shift 2
  output="$TMP_DIR/rejected-output.txt"
  "$@" >"$output" 2>&1
  command_status=$?
  if [ "$command_status" -ne 0 ] && grep -F -q -- "$needle" "$output"; then
    ok "$name"
  else
    not_ok "$name"
  fi
}

assert_fails() {
  name="$1"
  shift
  if "$@" >/dev/null 2>&1; then not_ok "$name"; else ok "$name"; fi
}

ci_has_active_run() {
  workflow="$1"
  expected="$2"
  awk -v expected="$expected" '
    {
      line = $0
      if (sub(/^[[:space:]]*-[[:space:]]*run:[[:space:]]*/, "", line)) {
        sub(/[[:space:]]+$/, "", line)
        if (line == expected) found = 1
      }
    }
    END { exit(found ? 0 : 1) }
  ' "$workflow"
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
# release-contract: repository-boundary-checks-begin
assert_exists "root maintainer issue tracker" "$REPOSITORY_ROOT/docs/agents/issue-tracker.md"
assert_exists "root maintainer domain config" "$REPOSITORY_ROOT/docs/agents/domain.md"
assert_exists "root maintainer triage config" "$REPOSITORY_ROOT/docs/agents/triage-labels.md"
assert_exists "root plans" "$REPOSITORY_ROOT/docs/plans"
assert_exists "root CI" "$REPOSITORY_ROOT/.github/workflows/smoke.yml"
assert_exists "release contract checker" "$SCRIPT_DIR/release-contract-check.cjs"
assert_exists "release contract exceptions" "$SCRIPT_DIR/release-contract-exceptions.json"
assert_exists "root hook" "$REPOSITORY_ROOT/.githooks/post-merge"
assert_exists "root runtime evidence" "$REPOSITORY_ROOT/.review"

assert_absent "no Matt-directory product skill" "$REPOSITORY_ROOT/.agents/skills/agent-workflow"
assert_absent "no root Claude product skill" "$REPOSITORY_ROOT/.claude/skills/agent-workflow"
assert_absent "no root product scripts" "$REPOSITORY_ROOT/scripts"
assert_absent "no root product schemas" "$REPOSITORY_ROOT/.review/schemas"
assert_absent "no root product STATUS" "$REPOSITORY_ROOT/STATUS.md"
assert_absent "no root product env example" "$REPOSITORY_ROOT/.env.example"
assert_absent "no root product playbook" "$REPOSITORY_ROOT/docs/agents/multi-agent-workflow.md"
# release-contract: repository-boundary-checks-end

canonical_skill_count="$(git -C "$REPOSITORY_ROOT" ls-files | grep -E '/agent-workflow/SKILL\.md$' | wc -l | tr -d ' ')"
assert_equals "exactly one canonical product skill" "1" "$canonical_skill_count"
non_product_schemas="$(git -C "$REPOSITORY_ROOT" ls-files '*.schema.json' | grep -v '^toolkit/schemas/' || true)"
assert_equals "all product schemas are contained" "" "$non_product_schemas"

if grep -R -F 'docs/agents/issue-tracker.md' \
  "$PRODUCT_ROOT/docs" "$PRODUCT_ROOT/.claude/skills/agent-workflow" >/dev/null 2>&1; then
  not_ok "product documents do not depend on maintainer tracker"
else
  ok "product documents do not depend on maintainer tracker"
fi

if grep -R -E '\.github/|\.githooks/|docs/agents/(issue-tracker|domain|triage-labels)\.md' \
  "$PRODUCT_ROOT/README.md" "$PRODUCT_ROOT/AGENTS.md" "$PRODUCT_ROOT/STATUS.md" \
  "$PRODUCT_ROOT/docs" "$PRODUCT_ROOT/.claude/skills/agent-workflow" >/dev/null 2>&1; then
  not_ok "product documents do not depend on repository infrastructure"
else
  ok "product documents do not depend on repository infrastructure"
fi

assert_command "CI actively runs release contract" ci_has_active_run \
  "$REPOSITORY_ROOT/.github/workflows/smoke.yml" 'bash .github/tests/release-contract.smoke.sh'
assert_command "CI actively runs product smoke suite with clean NODE_OPTIONS" ci_has_active_run \
  "$REPOSITORY_ROOT/.github/workflows/smoke.yml" 'NODE_OPTIONS= bash toolkit/scripts/__tests__/run-all.sh'
commented_workflow="$TMP_DIR/commented-smoke.yml"
printf '%s\n' '# - run: bash .github/tests/release-contract.smoke.sh' > "$commented_workflow"
assert_fails "commented CI command does not satisfy routing" ci_has_active_run \
  "$commented_workflow" 'bash .github/tests/release-contract.smoke.sh'
assert_contains "hook routes to product rebase helper" 'toolkit/scripts/rebase-inflight.sh' "$REPOSITORY_ROOT/.githooks/post-merge"
assert_contains "maintainer instructions route to product scripts" 'toolkit/scripts/' "$REPOSITORY_ROOT/AGENTS.md"
assert_contains "root README routes to product README" 'toolkit/README.md' "$REPOSITORY_ROOT/README.md"
assert_contains "trial log remains marked historical" 'Historical record' "$PRODUCT_ROOT/docs/agents/workflow-trial-log.md"
assert_contains "trial log preserves dated legacy evidence" 'feature/31-idem-audit-assertion' "$PRODUCT_ROOT/docs/agents/workflow-trial-log.md"
assert_contains "product instructions forbid duplicate authority" 'Do not recreate an `agent-workflow` authority outside this product root.' "$PRODUCT_ROOT/AGENTS.md"
assert_contains "root instructions identify Matt development skills" 'Matt Pocock skills under `.agents/skills/`' "$REPOSITORY_ROOT/AGENTS.md"

assert_command "tracked source references and Markdown links are valid" \
  node "$SCRIPT_DIR/release-contract-check.cjs" source "$REPOSITORY_ROOT"

# release-contract: release-sensitivity-fixtures-begin
LEGACY_REVIEW_SCHEMAS=".review/schemas"
contract_fixture="$TMP_DIR/contract fixture"
mkdir -p "$contract_fixture/.github/tests" "$contract_fixture/toolkit" "$contract_fixture/docs/plans"
git init -q "$contract_fixture"
printf '%s\n' '# fixture' '[toolkit](toolkit/)' > "$contract_fixture/README.md"
printf '%s\n' '# current product docs' > "$contract_fixture/toolkit/current.md"
printf '%s\n' '{"historicalReferences":[],"compatibilityReferences":[]}' \
  > "$contract_fixture/.github/tests/release-contract-exceptions.json"
git -C "$contract_fixture" add README.md toolkit/current.md .github/tests/release-contract-exceptions.json
assert_command "minimal current-reference fixture passes" \
  node "$SCRIPT_DIR/release-contract-check.cjs" source "$contract_fixture"
printf '%s\n' '# fixture' 'bash scripts/install-into.sh ../target' > "$contract_fixture/README.md"
assert_rejects "bare root product command fails" 'legacy root product path' \
  node "$SCRIPT_DIR/release-contract-check.cjs" source "$contract_fixture"
printf '%s\n' '# fixture' '[toolkit](toolkit/)' > "$contract_fixture/README.md"

printf '%s\n' '# current product docs' "$LEGACY_REVIEW_SCHEMAS/current.schema.json" \
  > "$contract_fixture/toolkit/current.md"
assert_rejects "unapproved current legacy reference fails" 'unapproved legacy-review-schemas' \
  node "$SCRIPT_DIR/release-contract-check.cjs" source "$contract_fixture"

printf '%s\n' '# current product docs' > "$contract_fixture/toolkit/current.md"
printf '%s\n' "$LEGACY_REVIEW_SCHEMAS/historical.schema.json" > "$contract_fixture/docs/plans/history.md"
git -C "$contract_fixture" add docs/plans/history.md
printf '%s\n' \
  '{' \
  '  "historicalReferences": [{' \
  '    "path": "docs/plans/history.md",' \
  '    "token": "legacy-review-schemas",' \
  "    \"context\": \"$LEGACY_REVIEW_SCHEMAS/historical.schema.json\"," \
  '    "expectedCount": 1,' \
  '    "reason": "immutable fixture evidence"' \
  '  }],' \
  '  "compatibilityReferences": []' \
  '}' > "$contract_fixture/.github/tests/release-contract-exceptions.json"
assert_command "exact historical exception passes" \
  node "$SCRIPT_DIR/release-contract-check.cjs" source "$contract_fixture"
printf '%s\n' "$LEGACY_REVIEW_SCHEMAS/historical.schema.json" >> "$contract_fixture/docs/plans/history.md"
assert_rejects "historical exception count drift fails" 'count mismatch' \
  node "$SCRIPT_DIR/release-contract-check.cjs" source "$contract_fixture"

region_fixture="$TMP_DIR/region fixture"
mkdir -p "$region_fixture/.github/tests" "$region_fixture/toolkit/scripts"
git init -q "$region_fixture"
printf '%s\n' \
  '# release-contract: compatibility-fixture-begin' \
  "$LEGACY_REVIEW_SCHEMAS/compat.schema.json" \
  '# release-contract: compatibility-fixture-end' > "$region_fixture/toolkit/scripts/install.sh"
printf '%s\n' \
  '{' \
  '  "historicalReferences": [],' \
  '  "compatibilityReferences": [{' \
  '    "path": "toolkit/scripts/install.sh",' \
  '    "token": "legacy-review-schemas",' \
  '    "region": "compatibility-fixture",' \
  "    \"context\": \"$LEGACY_REVIEW_SCHEMAS/compat.schema.json\"," \
  '    "expectedCount": 1,' \
  '    "reason": "named compatibility fixture"' \
  '  }]' \
  '}' > "$region_fixture/.github/tests/release-contract-exceptions.json"
git -C "$region_fixture" add toolkit/scripts/install.sh .github/tests/release-contract-exceptions.json
assert_command "named compatibility region passes" \
  node "$SCRIPT_DIR/release-contract-check.cjs" source "$region_fixture"
printf '%s\n' \
  "$LEGACY_REVIEW_SCHEMAS/compat.schema.json" \
  '# release-contract: compatibility-fixture-begin' \
  '# release-contract: compatibility-fixture-end' > "$region_fixture/toolkit/scripts/install.sh"
assert_rejects "compatibility line moved outside region fails" 'unapproved legacy-review-schemas' \
  node "$SCRIPT_DIR/release-contract-check.cjs" source "$region_fixture"

printf '%s\n' "$LEGACY_REVIEW_SCHEMAS/historical.schema.json" > "$contract_fixture/docs/plans/history.md"
printf '%s\n' '# current product docs' '[missing](missing.md)' > "$contract_fixture/toolkit/current.md"
assert_rejects "missing current Markdown link fails" 'missing Markdown link' \
  node "$SCRIPT_DIR/release-contract-check.cjs" source "$contract_fixture"
printf '%s\n' '# current product docs' '```md' '[example](missing.md)' '```' \
  > "$contract_fixture/toolkit/current.md"
assert_command "fenced Markdown example is ignored" \
  node "$SCRIPT_DIR/release-contract-check.cjs" source "$contract_fixture"
printf '%s\n' '# current product docs' '````md' '[example](missing.md)' '```' \
  '[still fenced](missing.md)' '````' > "$contract_fixture/toolkit/current.md"
assert_command "shorter inner fence does not close outer fence" \
  node "$SCRIPT_DIR/release-contract-check.cjs" source "$contract_fixture"
printf '%s\n' '# current product docs' '```invalid`' '[broken](missing.md)' \
  > "$contract_fixture/toolkit/current.md"
assert_rejects "backtick in fence info does not mask active links" 'missing Markdown link' \
  node "$SCRIPT_DIR/release-contract-check.cjs" source "$contract_fixture"
printf '%s\n' '# current product docs' '`[example](missing.md)`' 'plain text](missing.md)' \
  > "$contract_fixture/toolkit/current.md"
assert_command "inline code and non-link delimiters are ignored" \
  node "$SCRIPT_DIR/release-contract-check.cjs" source "$contract_fixture"
printf '%s\n' '# current product docs' '\[escaped](missing.md)' '[escaped\](missing.md)' \
  '<!-- [commented](missing.md) -->' > "$contract_fixture/toolkit/current.md"
assert_command "escaped and commented Markdown links are ignored" \
  node "$SCRIPT_DIR/release-contract-check.cjs" source "$contract_fixture"
printf '%s\n' '# current product docs' '[broken\\](missing.md)' \
  > "$contract_fixture/toolkit/current.md"
assert_rejects "even backslashes keep the closing bracket active" 'missing Markdown link' \
  node "$SCRIPT_DIR/release-contract-check.cjs" source "$contract_fixture"
printf '%s\n' '# current product docs' '\\[broken](missing.md)' \
  > "$contract_fixture/toolkit/current.md"
assert_rejects "even backslashes keep the opening bracket active" 'missing Markdown link' \
  node "$SCRIPT_DIR/release-contract-check.cjs" source "$contract_fixture"
printf '%s\n' '# current product docs' '\`[broken](missing.md)\`' \
  > "$contract_fixture/toolkit/current.md"
assert_rejects "escaped backticks do not hide active links" 'missing Markdown link' \
  node "$SCRIPT_DIR/release-contract-check.cjs" source "$contract_fixture"
printf '%s\n' '# outside product root' > "$TMP_DIR/outside.md"
ln -s "$TMP_DIR/outside.md" "$contract_fixture/toolkit/outside.md"
git -C "$contract_fixture" add toolkit/outside.md
printf '%s\n' '# current product docs' '[escape](outside.md)' > "$contract_fixture/toolkit/current.md"
assert_rejects "source symlink escape fails" 'resolves outside its documented context' \
  node "$SCRIPT_DIR/release-contract-check.cjs" source "$contract_fixture"
printf '%s\n' '# current product docs' '[bad anchor](#not-present)' > "$contract_fixture/toolkit/current.md"
assert_rejects "missing Markdown anchor fails" 'missing Markdown anchor' \
  node "$SCRIPT_DIR/release-contract-check.cjs" source "$contract_fixture"
printf '%s\n' '# current product docs' '[file URI](file:///tmp/example.md)' > "$contract_fixture/toolkit/current.md"
assert_rejects "file URI Markdown link fails" 'machine-absolute Markdown link' \
  node "$SCRIPT_DIR/release-contract-check.cjs" source "$contract_fixture"
printf '%s\n' '# current product docs' '[drive path](C:\\workspace\\example.md)' > "$contract_fixture/toolkit/current.md"
assert_rejects "Windows drive Markdown link fails" 'machine-absolute Markdown link' \
  node "$SCRIPT_DIR/release-contract-check.cjs" source "$contract_fixture"
printf '%s\n' '# balanced target' > "$contract_fixture/toolkit/a_(b).md"
git -C "$contract_fixture" add 'toolkit/a_(b).md'
printf '%s\n' \
  'Setext Heading' \
  '==============' \
  '# Repeat' \
  '# Repeat-1' \
  '# Repeat' \
  '[setext](#setext-heading)' \
  '[global collision](#repeat-2)' \
  '[balanced](a_(b).md)' > "$contract_fixture/toolkit/current.md"
assert_command "balanced destinations and GitHub heading anchors pass" \
  node "$SCRIPT_DIR/release-contract-check.cjs" source "$contract_fixture"
# release-contract: release-sensitivity-fixtures-end

copy_target="$TMP_DIR/copy target"
mkdir -p "$copy_target"
printf '%s\n' '# target-owned README' > "$copy_target/README.md"
assert_command "release copy installation succeeds" \
  bash "$PRODUCT_ROOT/scripts/install-into.sh" "$copy_target" --mode copy
assert_command "installed Markdown links are valid in copy context" \
  node "$SCRIPT_DIR/release-contract-check.cjs" installed "$copy_target"
assert_command "copy scripts are not symlinked to source" test ! -L "$copy_target/.agent-workflow/scripts"
assert_command "copy schemas are not symlinked to source" test ! -L "$copy_target/.agent-workflow/schemas"
assert_command "copy docs are not symlinked to source" test ! -L "$copy_target/.agent-workflow/docs/agents"
assert_command "copy skill is not symlinked to source" test ! -L "$copy_target/.claude/skills/agent-workflow"
printf '%s\n' '[source-only](../../../README.md)' \
  > "$copy_target/.agent-workflow/docs/agents/release-contract-negative.md"
assert_rejects "installed target-owned Markdown link fails" 'escapes its documented context' \
  node "$SCRIPT_DIR/release-contract-check.cjs" installed "$copy_target"
assert_absent "copy excludes Matt skills" "$copy_target/.agents"
assert_absent "copy excludes Matt lockfile" "$copy_target/skills-lock.json"
assert_absent "copy excludes root instructions" "$copy_target/AGENTS.md"
assert_absent "copy excludes maintainer tracker" "$copy_target/docs/agents/issue-tracker.md"
assert_absent "copy excludes maintainer domain config" "$copy_target/docs/agents/domain.md"
assert_absent "copy excludes maintainer triage config" "$copy_target/docs/agents/triage-labels.md"
assert_absent "copy excludes maintainer plans" "$copy_target/docs/plans"
assert_absent "copy excludes repository evidence" "$copy_target/.review/source"
assert_absent "copy excludes repository CI" "$copy_target/.github"
assert_absent "copy excludes repository hooks" "$copy_target/.githooks"

symlink_target="$TMP_DIR/symlink target"
mkdir -p "$symlink_target"
assert_command "release symlink installation succeeds" \
  bash "$PRODUCT_ROOT/scripts/install-into.sh" "$symlink_target"
assert_command "installed Markdown links are valid in symlink context" \
  node "$SCRIPT_DIR/release-contract-check.cjs" installed "$symlink_target"

broken_product="$TMP_DIR/broken product"
broken_target="$TMP_DIR/broken symlink target"
mkdir -p "$broken_product/docs/agents" "$broken_product/skill" \
  "$broken_target/.agent-workflow/docs" "$broken_target/.claude/skills"
printf '%s\n' '[broken](missing.md)' > "$broken_product/docs/agents/broken.md"
printf '%s\n' '# skill' > "$broken_product/skill/SKILL.md"
ln -s "$broken_product/docs/agents" "$broken_target/.agent-workflow/docs/agents"
ln -s "$broken_product/skill" "$broken_target/.claude/skills/agent-workflow"
assert_rejects "broken symlink-installed Markdown link fails" 'missing Markdown link' \
  node "$SCRIPT_DIR/release-contract-check.cjs" installed "$broken_target"
empty_installed="$TMP_DIR/empty installed target"
mkdir -p "$empty_installed"
assert_rejects "missing installed authorities fail" 'missing product docs or the canonical skill' \
  node "$SCRIPT_DIR/release-contract-check.cjs" installed "$empty_installed"

if bash "$PRODUCT_ROOT/scripts/__tests__/run-all.sh" --list | grep -F -x -q 'install-into.smoke.sh'; then
  ok "full product suite includes installer contract"
else
  not_ok "full product suite includes installer contract"
fi

echo "---"
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASS"
  exit 0
fi
echo "$FAILURES CASE(S) FAILED"
exit 1
