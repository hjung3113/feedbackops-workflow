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

guidance_has_no_stale_transport_set() {
  path="$1"
  if grep -E -i -q 'cmux\|orca([^[:alnum:]_|]|$)' "$path" || \
     grep -F -i -q '`cmux` or `orca`' "$path" || \
     grep -F -i -q 'cmux or Orca' "$path" || \
     grep -F -i -q 'Orca or cmux' "$path" || \
     grep -F -i -q 'Orca/cmux' "$path"; then
    return 1
  fi
  return 0
}

assert_transport_guidance_files() {
  label="$1"
  root="$2"
  shift 2
  for relative in "$@"; do
    path="$root/$relative"
    assert_command "$label includes named guidance $relative" test -f "$path"
    assert_command "$label names Herdr in $relative" grep -F -i -q 'Herdr' "$path"
    assert_command "$label updates exhaustive transport set in $relative" guidance_has_no_stale_transport_set "$path"
  done
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
assert_exists "transport-neutral public CLI" "$PRODUCT_ROOT/scripts/agent-workflow.sh"
assert_exists "shared dispatch core" "$PRODUCT_ROOT/scripts/dispatch-core.sh"
assert_exists "cmux transport adapter" "$PRODUCT_ROOT/scripts/adapters/cmux.sh"
assert_exists "Orca transport adapter" "$PRODUCT_ROOT/scripts/adapters/orca.sh"
assert_command "Herdr transport adapter is executable" test -x "$PRODUCT_ROOT/scripts/adapters/herdr.sh"
assert_exists "product smoke suite" "$PRODUCT_ROOT/scripts/__tests__/run-all.sh"
assert_exists "product schemas" "$PRODUCT_ROOT/schemas/round_state.schema.json"
assert_exists "target profile schema" "$PRODUCT_ROOT/schemas/target-profile.schema.json"
assert_exists "target profile examples" "$PRODUCT_ROOT/schemas/profiles/node.example.json"
assert_exists "target-neutral verifier" "$PRODUCT_ROOT/scripts/target-verify.sh"
assert_exists "target-neutral VERIFY semantic validator" "$PRODUCT_ROOT/scripts/lib/verify-artifact.cjs"
assert_exists "transport receipt schema" "$PRODUCT_ROOT/schemas/transport_receipt.schema.json"
assert_exists "routing receipt fixture" "$PRODUCT_ROOT/schemas/fixtures/transport_receipt.routing.valid.json"
assert_exists "review capsule schema" "$PRODUCT_ROOT/schemas/review_capsule.schema.json"
assert_exists "review capsule renderer" "$PRODUCT_ROOT/scripts/review-capsule.sh"
assert_exists "parallel planner" "$PRODUCT_ROOT/scripts/parallel-plan.sh"
assert_exists "candidate integrator" "$PRODUCT_ROOT/scripts/candidate-integrate.sh"
assert_exists "candidate closure gate" "$PRODUCT_ROOT/scripts/candidate-close.sh"
assert_exists "shared RFC3339 parser" "$PRODUCT_ROOT/scripts/lib/rfc3339.cjs"
assert_exists "shared cmux handle normalizer" "$PRODUCT_ROOT/scripts/lib/cmux-handles.cjs"
assert_exists "telemetry sample semantic validator" "$PRODUCT_ROOT/scripts/lib/telemetry-sample.cjs"
assert_contains "closure requires final review lifecycle" 'value.lifecycle !== "final"' "$PRODUCT_ROOT/scripts/lib/candidate-close.cjs"
assert_contains "closure requires active PR draft lifecycle" 'value.lifecycle !== "active"' "$PRODUCT_ROOT/scripts/lib/candidate-close.cjs"
assert_exists "product smoke suite" "$PRODUCT_ROOT/scripts/__tests__/run-all.sh"
assert_exists "product schemas" "$PRODUCT_ROOT/schemas/round_state.schema.json"
assert_exists "execution plan schema" "$PRODUCT_ROOT/schemas/execution_plan.schema.json"
assert_exists "candidate evidence schema" "$PRODUCT_ROOT/schemas/candidate_evidence_set.schema.json"
assert_exists "candidate closure schema" "$PRODUCT_ROOT/schemas/candidate_closure.schema.json"
assert_exists "completion evidence schema" "$PRODUCT_ROOT/schemas/completion_evidence.schema.json"
assert_exists "seat outcome schema" "$PRODUCT_ROOT/schemas/seat_outcome.schema.json"
assert_contains "review schema carries direct closure binding" '"closure_binding"' "$PRODUCT_ROOT/schemas/review.schema.json"
assert_contains "verification schema carries direct closure binding" '"closure_binding"' "$PRODUCT_ROOT/schemas/verify.schema.json"
assert_contains "PR draft schema carries direct closure binding" '"closure_binding"' "$PRODUCT_ROOT/schemas/pr_draft.schema.json"
assert_contains "candidate timestamps use RFC3339 shape" '(?:Z|[+-]\\d{2}:\\d{2})' "$PRODUCT_ROOT/schemas/candidate_closure.schema.json"
assert_transport_guidance_files "source transport guidance" "$PRODUCT_ROOT" \
  "README.md" \
  "docs/agents/multi-agent-workflow.md" \
  "scripts/install-profiles/generic/docs/agents/multi-agent-workflow.md" \
  ".claude/skills/agent-workflow/SKILL.md" \
  ".claude/skills/agent-workflow/references/adoption.md" \
  "docs/agents/conductor-persona.md" \
  "STATUS.md"
assert_exists "telemetry sample schema" "$PRODUCT_ROOT/schemas/telemetry_sample.schema.json"
assert_exists "telemetry report schema" "$PRODUCT_ROOT/schemas/telemetry_report.schema.json"
assert_exists "semantic closure telemetry fixture" "$PRODUCT_ROOT/schemas/fixtures/telemetry_sample.closure.valid.json"
assert_exists "invalid semantic closure telemetry fixture" "$PRODUCT_ROOT/schemas/fixtures/telemetry_sample.closure.invalid.json"
assert_exists "routed telemetry sample fixture" "$PRODUCT_ROOT/schemas/fixtures/telemetry_sample.routing.valid.json"
assert_exists "routed telemetry report fixture" "$PRODUCT_ROOT/schemas/fixtures/telemetry_report.routing.valid.json"
assert_exists "candidate closure schema" "$PRODUCT_ROOT/schemas/candidate_closure.schema.json"
assert_exists "candidate closure RFC3339 fixture" "$PRODUCT_ROOT/schemas/fixtures/candidate_closure.timestamp.invalid.json"
assert_exists "candidate integration schema" "$PRODUCT_ROOT/schemas/integration_result.schema.json"
assert_exists "candidate evidence schema" "$PRODUCT_ROOT/schemas/candidate_evidence_set.schema.json"
assert_exists "local telemetry command" "$PRODUCT_ROOT/scripts/telemetry.sh"
assert_exists "product schema fixtures" "$PRODUCT_ROOT/schemas/fixtures/round_state.valid.json"
assert_exists "invalid RUN schema fixture" "$PRODUCT_ROOT/schemas/fixtures/run.invalid.json"

# The transport registry is the single runtime source of truth for the adapter
# set; the hand-authored schema enums must stay in exact parity with it.
transport_registry_parity() {
  schema_file="$1"
  property_name="$2"
  allowed_extra="$3"
  node - "$PRODUCT_ROOT/scripts/lib/transport-registry.cjs" "$schema_file" "$property_name" "$allowed_extra" <<'NODE'
const { ADAPTERS } = require(process.argv[2]);
const fs = require("fs");
const schema = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
const enumValues = schema.properties[process.argv[4]].enum;
const expected = new Set(ADAPTERS);
if (process.argv[5]) expected.add(process.argv[5]);
process.exit(enumValues.length === expected.size && enumValues.every(value => expected.has(value)) ? 0 : 1);
NODE
}

assert_exists "transport registry module" "$PRODUCT_ROOT/scripts/lib/transport-registry.cjs"
assert_command "transport registry matches the receipt schema adapter enum" \
  transport_registry_parity "$PRODUCT_ROOT/schemas/transport_receipt.schema.json" adapter ""
assert_command "transport registry matches the telemetry transport enum plus legacy local" \
  transport_registry_parity "$PRODUCT_ROOT/schemas/telemetry_sample.schema.json" transport local
parity_negative_fixture="$TMP_DIR/transport-receipt-missing-adapter.schema.json"
node - "$PRODUCT_ROOT/schemas/transport_receipt.schema.json" "$parity_negative_fixture" <<'NODE'
const fs = require("fs");
const schema = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
schema.properties.adapter.enum = schema.properties.adapter.enum.filter(value => value !== "herdr");
fs.writeFileSync(process.argv[3], JSON.stringify(schema) + "\n");
NODE
assert_fails "transport parity gate rejects a schema enum missing a registered adapter" \
  transport_registry_parity "$parity_negative_fixture" adapter ""
assert_contains "shared core pins the selected capability-probed runtime executable" 'AGENT_WORKFLOW_RUNTIME_BIN=' "$PRODUCT_ROOT/scripts/dispatch-core.sh"
assert_contains "cmux create recognizes documented workspace id fields" '"id", "workspace_id", "workspaceId"' "$PRODUCT_ROOT/scripts/lib/cmux-handles.cjs"
assert_contains "cmux create/inspect recognize the documented ref field" 'WORKSPACE_REF_KEYS = ["ref"]' "$PRODUCT_ROOT/scripts/lib/cmux-handles.cjs"
assert_exists "product playbook" "$PRODUCT_ROOT/docs/agents/multi-agent-workflow.md"
assert_exists "product conductor persona" "$PRODUCT_ROOT/docs/agents/conductor-persona.md"
assert_exists "product visual reviewer persona" "$PRODUCT_ROOT/docs/agents/visual-reviewer-persona.md"
assert_exists "product historical trial log" "$PRODUCT_ROOT/docs/agents/workflow-trial-log.md"
assert_exists "product issue reporting" "$PRODUCT_ROOT/docs/agents/issue-reporting.md"
assert_exists "canonical product skill" "$PRODUCT_ROOT/.claude/skills/agent-workflow/SKILL.md"
assert_exists "product adoption guide" "$PRODUCT_ROOT/.claude/skills/agent-workflow/references/adoption.md"
assert_exists "workflow config example" "$PRODUCT_ROOT/docs/agents/workflow-config.example.json"

assert_command "generic quickstart avoids FeedbackOps-only adapters" \
  awk '
    /^## 5분 안에 첫 controlled run/ { quickstart = 1; next }
    /^## FeedbackOps compatibility alternative/ { quickstart = 0 }
    quickstart && /prepare-worktree\.sh|prepare-verify-db\.sh|scripts\/verify\.sh/ { failed = 1 }
    END { exit failed }
  ' "$PRODUCT_ROOT/README.md"

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

REPOSITORY_INFRA_PATTERN='\.github/|\.githooks/|\.review/source|docs/plans/|skills-lock\.json|\.agents/skills|docs/agents/(issue-tracker|domain|triage-labels)\.md'
if grep -R -E "$REPOSITORY_INFRA_PATTERN" \
  "$PRODUCT_ROOT/README.md" "$PRODUCT_ROOT/AGENTS.md" "$PRODUCT_ROOT/STATUS.md" \
  "$PRODUCT_ROOT/CLAUDE.md" "$PRODUCT_ROOT/docs" \
  "$PRODUCT_ROOT/.claude/skills/agent-workflow" >/dev/null 2>&1; then
  not_ok "product documents do not depend on repository infrastructure"
else
  ok "product documents do not depend on repository infrastructure"
fi
repository_infra_fixture="$TMP_DIR/product-claude-infra-fixture.md"
printf '%s\n' 'Follow .github/private-policy.md.' > "$repository_infra_fixture"
assert_command "repository infrastructure pattern covers product Claude pointer" \
  grep -E -q "$REPOSITORY_INFRA_PATTERN" "$repository_infra_fixture"

assert_command "CI actively runs release contract" ci_has_active_run \
  "$REPOSITORY_ROOT/.github/workflows/smoke.yml" 'bash .github/tests/release-contract.smoke.sh'
assert_command "CI actively runs product smoke suite with clean NODE_OPTIONS" ci_has_active_run \
  "$REPOSITORY_ROOT/.github/workflows/smoke.yml" 'NODE_OPTIONS= bash toolkit/scripts/__tests__/run-all.sh'
assert_command "CI actively runs the run-all runner contract test" ci_has_active_run \
  "$REPOSITORY_ROOT/.github/workflows/smoke.yml" 'bash toolkit/scripts/__tests__/run-all-contract.test.sh'
commented_workflow="$TMP_DIR/commented-smoke.yml"
printf '%s\n' '# - run: bash .github/tests/release-contract.smoke.sh' > "$commented_workflow"
assert_fails "commented CI command does not satisfy routing" ci_has_active_run \
  "$commented_workflow" 'bash .github/tests/release-contract.smoke.sh'
printf '%s\n' '# - run: bash toolkit/scripts/__tests__/run-all-contract.test.sh' >> "$commented_workflow"
assert_fails "commented CI command does not satisfy contract test routing" ci_has_active_run \
  "$commented_workflow" 'bash toolkit/scripts/__tests__/run-all-contract.test.sh'
assert_contains "hook routes to product rebase helper" 'toolkit/scripts/rebase-inflight.sh' "$REPOSITORY_ROOT/.githooks/post-merge"
assert_contains "maintainer instructions route to product scripts" 'toolkit/scripts/' "$REPOSITORY_ROOT/AGENTS.md"
assert_contains "root README routes to product README" 'toolkit/README.md' "$REPOSITORY_ROOT/README.md"
assert_contains "trial log remains marked historical" 'Historical record' "$PRODUCT_ROOT/docs/agents/workflow-trial-log.md"
assert_contains "trial log preserves dated legacy evidence" 'feature/31-idem-audit-assertion' "$PRODUCT_ROOT/docs/agents/workflow-trial-log.md"
assert_contains "product instructions forbid duplicate authority" 'Do not recreate an `agent-workflow` authority outside this product root.' "$PRODUCT_ROOT/AGENTS.md"
assert_contains "shared dispatch core requires canonical initial state" 'initial write requires --round-state and --manifest-revision' "$PRODUCT_ROOT/scripts/dispatch-core.sh"
assert_exists "product Claude pointer" "$PRODUCT_ROOT/CLAUDE.md"
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
  bash "$PRODUCT_ROOT/scripts/install-into.sh" "$copy_target"
assert_command "installed Markdown links are valid in copy context" \
  node "$SCRIPT_DIR/release-contract-check.cjs" installed "$copy_target"
assert_command "copy scripts are not symlinked to source" test ! -L "$copy_target/.agent-workflow/scripts"
assert_command "copy schemas are not symlinked to source" test ! -L "$copy_target/.agent-workflow/schemas"
assert_command "copy docs are not symlinked to source" test ! -L "$copy_target/.agent-workflow/docs/agents"
assert_command "copy skill is not symlinked to source" test ! -L "$copy_target/.claude/skills/agent-workflow"
assert_command "installed Herdr transport adapter is executable" test -x "$copy_target/.agent-workflow/scripts/adapters/herdr.sh"
assert_transport_guidance_files "installed transport guidance" "$copy_target" \
  ".agent-workflow/docs/agents/multi-agent-workflow.md" \
  ".agent-workflow/docs/agents/conductor-persona.md" \
  ".claude/skills/agent-workflow/SKILL.md" \
  ".claude/skills/agent-workflow/references/adoption.md"
assert_contains "copy preserves canonical initial-state admission" 'initial write requires --round-state and --manifest-revision' "$copy_target/.agent-workflow/scripts/dispatch-core.sh"
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

broken_product="$TMP_DIR/broken product"
broken_target="$TMP_DIR/broken installed target"
mkdir -p "$broken_product/docs/agents" "$broken_product/skill" \
  "$broken_target/.agent-workflow/docs/agents" "$broken_target/.claude/skills/agent-workflow"
printf '%s\n' '[broken](missing.md)' > "$broken_product/docs/agents/broken.md"
printf '%s\n' '# skill' > "$broken_product/skill/SKILL.md"
cp -R "$broken_product/docs/agents/." "$broken_target/.agent-workflow/docs/agents"
cp -R "$broken_product/skill/." "$broken_target/.claude/skills/agent-workflow"
assert_rejects "broken portable-installed Markdown link fails" 'missing Markdown link' \
  node "$SCRIPT_DIR/release-contract-check.cjs" installed "$broken_target"
empty_installed="$TMP_DIR/empty installed target"
mkdir -p "$empty_installed"
assert_rejects "missing installed authorities fail" 'missing product docs or the canonical skill' \
  node "$SCRIPT_DIR/release-contract-check.cjs" installed "$empty_installed"

smoke_inventory_matches() {
  manifest_file="$1"
  if [ "$(sort "$manifest_file" | uniq -d | wc -l | tr -d ' ')" -ne 0 ]; then
    return 1
  fi
  diff -q <(bash "$PRODUCT_ROOT/scripts/__tests__/run-all.sh" --list | sort) \
    <(sort "$manifest_file") >/dev/null 2>&1
}

SMOKE_INVENTORY_MANIFEST="$PRODUCT_ROOT/scripts/__tests__/smoke-inventory.manifest"
assert_exists "smoke inventory manifest" "$SMOKE_INVENTORY_MANIFEST"
assert_command "full product suite matches the closed-set smoke inventory manifest" \
  smoke_inventory_matches "$SMOKE_INVENTORY_MANIFEST"
manifest_missing_entry="$TMP_DIR/smoke-inventory-missing.manifest"
grep -v -F -x -- 'telemetry.smoke.sh' "$SMOKE_INVENTORY_MANIFEST" > "$manifest_missing_entry"
assert_fails "manifest missing a real smoke entry fails inventory parity" \
  smoke_inventory_matches "$manifest_missing_entry"

# The runner's own contract test must stay outside the live inventory: the
# runner discovers work by the *.smoke.sh suffix and would otherwise re-enter
# itself.
assert_exists "smoke runner contract test" "$PRODUCT_ROOT/scripts/__tests__/run-all-contract.test.sh"
if bash "$PRODUCT_ROOT/scripts/__tests__/run-all.sh" --list | grep -F -q 'run-all-contract'; then
  not_ok "smoke runner contract test stays outside the live inventory"
else
  ok "smoke runner contract test stays outside the live inventory"
fi

echo "---"
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASS"
  exit 0
fi
echo "$FAILURES CASE(S) FAILED"
exit 1
