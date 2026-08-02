#!/usr/bin/env bash
# Smoke test for scripts/install-into.sh.
# Bash 3.2 compatible. Run: bash scripts/__tests__/install-into.smoke.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL="$SCRIPT_DIR/../install-into.sh"
PRODUCT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
FAILURES=0
# Installed dispatch capability-probes the selected runtime. Keep the portable
# smoke hermetic with a Codex-shaped fake instead of /usr/bin/true.
if [ -z "${AGENT_WORKFLOW_CODEX_BIN:-}" ]; then
  RUNTIME_FAKE="$TMP_DIR/codex-runtime-fake"
  cat > "$RUNTIME_FAKE" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo 'codex install smoke 1.0'; exit 0 ;;
  --help) echo 'Commands: exec'; exit 0 ;;
  exec) [ "${2:-}" = "--help" ] && { echo 'exec --sandbox --cd --model --config --output-last-message'; exit 0; } ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$RUNTIME_FAKE"
  export AGENT_WORKFLOW_CODEX_BIN="$RUNTIME_FAKE"
fi

ok() { echo "ok   - $1"; }
not_ok() { echo "NOT OK - $1"; FAILURES=$((FAILURES + 1)); }

assert_true() {
  name="$1"; shift
  if "$@"; then ok "$name"; else not_ok "$name"; fi
}

assert_exit() {
  name="$1"; expected="$2"; shift 2
  output="$TMP_DIR/assert-exit-$FAILURES.txt"
  "$@" >"$output" 2>&1
  actual=$?
  if { [ "$expected" = PASS ] && [ "$actual" -eq 0 ]; } || \
     { [ "$expected" = FAIL ] && [ "$actual" -ne 0 ]; }; then
    ok "$name"
  else
    not_ok "$name ($(cat "$output"))"
  fi
}

assert_exit_output() {
  name="$1"; expected_exit="$2"; expected_text="$3"; shift 3
  output="$TMP_DIR/output-$FAILURES.txt"
  "$@" >"$output" 2>&1
  actual=$?
  if [ "$actual" -eq "$expected_exit" ] && grep -F -q -- "$expected_text" "$output"; then
    ok "$name"
  else
    not_ok "$name"
  fi
}

assert_portable_layout() {
  label="$1"; target="$2"
  for leaf in \
    "$target/.agent-workflow/scripts" \
    "$target/.agent-workflow/schemas" \
    "$target/.agent-workflow/docs/agents" \
    "$target/.claude/skills/agent-workflow"; do
    assert_true "$label creates real directory $leaf" test -d "$leaf"
    assert_true "$label creates no managed leaf symlink $leaf" test ! -L "$leaf"
  done
}

assert_current_content() {
  label="$1"; target="$2"
  assert_true "$label includes install script" test -x "$target/.agent-workflow/scripts/install-into.sh"
  assert_true "$label seeds default model allocation config" test -f "$target/.agent-workflow/model-alloc.json"
  assert_true "$label includes verify result module" test -e "$target/.agent-workflow/scripts/lib/verify-result.cjs"
  assert_true "$label includes review capsule renderer" test -x "$target/.agent-workflow/scripts/review-capsule.sh"
  assert_true "$label includes review capsule schema" test -e "$target/.agent-workflow/schemas/review_capsule.schema.json"
  assert_true "$label includes local telemetry command" test -x "$target/.agent-workflow/scripts/telemetry.sh"
  assert_true "$label includes shared RFC3339 parser" test -e "$target/.agent-workflow/scripts/lib/rfc3339.cjs"
  assert_true "$label includes shared cmux handle normalizer" test -e "$target/.agent-workflow/scripts/lib/cmux-handles.cjs"
  assert_true "$label includes telemetry sample semantic validator" test -e "$target/.agent-workflow/scripts/lib/telemetry-sample.cjs"
  assert_true "$label includes telemetry schemas" test -e "$target/.agent-workflow/schemas/telemetry_sample.schema.json"
  assert_true "$label includes telemetry report schema" test -e "$target/.agent-workflow/schemas/telemetry_report.schema.json"
  assert_true "$label includes semantic closure telemetry fixtures" test -e "$target/.agent-workflow/schemas/fixtures/telemetry_sample.closure.valid.json"
  assert_true "$label includes invalid semantic closure telemetry fixture" test -e "$target/.agent-workflow/schemas/fixtures/telemetry_sample.closure.invalid.json"
  assert_true "$label includes routed telemetry sample fixture" test -e "$target/.agent-workflow/schemas/fixtures/telemetry_sample.routing.valid.json"
  assert_true "$label includes routed telemetry report fixture" test -e "$target/.agent-workflow/schemas/fixtures/telemetry_report.routing.valid.json"
  assert_true "$label includes candidate closure schema" test -e "$target/.agent-workflow/schemas/candidate_closure.schema.json"
  assert_true "$label includes candidate closure RFC3339 fixture" test -e "$target/.agent-workflow/schemas/fixtures/candidate_closure.timestamp.invalid.json"
  assert_true "$label includes candidate integration schema" test -e "$target/.agent-workflow/schemas/integration_result.schema.json"
  assert_true "$label includes candidate evidence schema" test -e "$target/.agent-workflow/schemas/candidate_evidence_set.schema.json"
  assert_true "$label includes schemas" test -e "$target/.agent-workflow/schemas/round_state.schema.json"
  assert_true "$label includes invalid RUN fixture" test -e "$target/.agent-workflow/schemas/fixtures/run.invalid.json"
  assert_true "$label includes target profile schema" test -e "$target/.agent-workflow/schemas/target-profile.schema.json"
  assert_true "$label includes Node target profile example" test -e "$target/.agent-workflow/schemas/profiles/node.example.json"
  assert_true "$label includes generic target verifier" test -x "$target/.agent-workflow/scripts/target-verify.sh"
  assert_true "$label includes transport-neutral CLI" test -x "$target/.agent-workflow/scripts/agent-workflow.sh"
  assert_true "$label includes shared dispatch core" test -x "$target/.agent-workflow/scripts/dispatch-core.sh"
  assert_true "$label includes cmux adapter" test -x "$target/.agent-workflow/scripts/adapters/cmux.sh"
  assert_true "$label includes Orca adapter" test -x "$target/.agent-workflow/scripts/adapters/orca.sh"
  assert_true "$label includes receipt schema" test -e "$target/.agent-workflow/schemas/transport_receipt.schema.json"
  assert_true "$label includes routing receipt fixtures" test -e "$target/.agent-workflow/schemas/fixtures/transport_receipt.routing.valid.json"
  assert_true "$label includes workflow config example" test -e "$target/.agent-workflow/docs/agents/workflow-config.example.json"
  assert_true "$label includes parallel planner" test -x "$target/.agent-workflow/scripts/parallel-plan.sh"
  assert_true "$label includes candidate integrator" test -x "$target/.agent-workflow/scripts/candidate-integrate.sh"
  assert_true "$label includes candidate closure" test -x "$target/.agent-workflow/scripts/candidate-close.sh"
  assert_true "$label installs final review lifecycle guard" grep -F -q 'value.lifecycle !== "final"' "$target/.agent-workflow/scripts/lib/candidate-close.cjs"
  assert_true "$label installs active PR draft lifecycle guard" grep -F -q 'value.lifecycle !== "active"' "$target/.agent-workflow/scripts/lib/candidate-close.cjs"
  assert_true "$label includes schemas" test -e "$target/.agent-workflow/schemas/round_state.schema.json"
  assert_true "$label includes execution plan schema" test -e "$target/.agent-workflow/schemas/execution_plan.schema.json"
  assert_true "$label includes candidate closure schema" test -e "$target/.agent-workflow/schemas/candidate_closure.schema.json"
  assert_true "$label installs direct closure bindings" grep -q '"closure_binding"' "$target/.agent-workflow/schemas/review.schema.json"
  assert_true "$label installs RFC3339 closure timestamps" grep -F -q '(?:Z|[+-]\\d{2}:\\d{2})' "$target/.agent-workflow/schemas/candidate_closure.schema.json"
  assert_true "$label includes playbook" test -e "$target/.agent-workflow/docs/agents/multi-agent-workflow.md"
  assert_true "$label includes skill" test -e "$target/.claude/skills/agent-workflow/SKILL.md"
}

assert_no_maintainer_leakage() {
  target="$1"
  assert_true "install excludes Matt skills" test ! -e "$target/.agents"
  assert_true "install excludes maintainer tracker" test ! -e "$target/docs/agents/issue-tracker.md"
  assert_true "install excludes plans" test ! -e "$target/docs/plans"
}

assert_generic_profile() {
  target="$1"
  assert_true "generic install records generic profile" grep -F -q '"profile":"generic"' "$target/.agent-workflow/install-profile.json"
  assert_true "generic install retains target-neutral verifier" test -x "$target/.agent-workflow/scripts/target-verify.sh"
  assert_true "generic install includes VERIFY semantic validator" test -e "$target/.agent-workflow/scripts/lib/verify-artifact.cjs"
  assert_true "generic install excludes FeedbackOps verifier" test ! -e "$target/.agent-workflow/scripts/verify.sh"
  assert_true "generic install excludes FeedbackOps DB adapter" test ! -e "$target/.agent-workflow/scripts/prepare-verify-db.sh"
  assert_true "generic install excludes FeedbackOps worktree adapter" test ! -e "$target/.agent-workflow/scripts/prepare-worktree.sh"
  assert_true "generic install excludes TypeScript tier adapter" test ! -e "$target/.agent-workflow/scripts/tier-probe.sh"
  assert_true "generic install excludes private Vitest classifier" test ! -e "$target/.agent-workflow/scripts/lib/verify-result.cjs"
  assert_true "generic install excludes source smoke tests" test ! -e "$target/.agent-workflow/scripts/__tests__"
  assert_true "generic install excludes source install assets" test ! -e "$target/.agent-workflow/scripts/install-profiles"
  assert_true "generic install excludes schema fixtures" test ! -e "$target/.agent-workflow/schemas/fixtures"
  assert_true "generic install excludes FeedbackOps profile example" test ! -e "$target/.agent-workflow/schemas/profiles/feedbackops.example.json"
  assert_true "generic install excludes source installer" test ! -e "$target/.agent-workflow/scripts/install-into.sh"
  assert_true "generic install creates Codex skill discovery" test -f "$target/.agents/skills/agent-workflow/SKILL.md"
  assert_true "generic install creates OpenCode agent discovery" test -f "$target/.opencode/agents/agent-workflow.md"
  assert_true "generic install creates deny-first OpenCode config" node -e 'const v=require(process.argv[1]); process.exit(v.permission && v.permission["*"] === "deny" ? 0 : 1)' "$target/opencode.json"
  assert_true "Claude and Codex use one router content" cmp -s "$target/.claude/skills/agent-workflow/SKILL.md" "$target/.agents/skills/agent-workflow/SKILL.md"
  assert_true "generic managed inventory has no compatibility leakage" bash -c '! grep -E -R -i "feedbackops|vitest|postgres|fops_" "$@"' _ "$target/.agent-workflow" "$target/.claude/skills/agent-workflow" "$target/.agents/skills/agent-workflow" "$target/.opencode" "$target/opencode.json"
}

prepare_gate_fixture() {
  target="$1"
  fixture="$target/.agent-workflow/schemas/fixtures/round_state.valid.json"
  if [ ! -r "$fixture" ]; then
    fixture="$PRODUCT_ROOT/schemas/fixtures/round_state.valid.json"
  fi
  GATE_STATE="$target/.review/ISSUE-188-ROUND-STATE.json"
  GATE_BLOCKER_STATE="$target/.review/ISSUE-188-BLOCKER-ROUND-STATE.json"
  GATE_SUPERSEDED_BLOCKER_STATE="$target/.review/ISSUE-188-SUPERSEDED-BLOCKER-ROUND-STATE.json"
  GATE_TESTS="$target/.review/discovered-tests.txt"
  git init -q "$target"
  git -C "$target" config user.email smoke@example.test
  git -C "$target" config user.name smoke
  mkdir -p "$target/allowed"
  printf '%s\n' base > "$target/allowed/file.txt"
  git -C "$target" add allowed/file.txt
  git -C "$target" commit -qm base
  git -C "$target" branch -M main
  base_sha="$(git -C "$target" rev-parse HEAD)"
  git -C "$target" switch -q -c feat/install-smoke
  printf '%s\n' changed >> "$target/allowed/file.txt"
  git -C "$target" commit -am change -q
  head_sha="$(git -C "$target" rev-parse HEAD)"
  cp "$fixture" "$GATE_STATE"
  node -e '
    const fs=require("fs"); const [file,root,base,head]=process.argv.slice(1); const v=JSON.parse(fs.readFileSync(file,"utf8"));
    v.revision=3; v.base_branch="main"; v.base_sha=base; v.head_sha=head; v.worktree_path=root;
    v.contract.touch_allowlist=["allowed/**"]; v.contract.test_discovery_command="printf '\''AC-1\\n'\''"; delete v.contract.test_count;
    delete v.contract.chunk_boundary; v.acceptance.criteria=[{id:"AC-1",statement:"the installed gate discovers AC-1"}]; v.acceptance.expected_test_count=1;
    v.decisions=[]; delete v.round_control; v.commit_scope.commits=[]; fs.writeFileSync(file,JSON.stringify(v));
  ' "$GATE_STATE" "$target" "$base_sha" "$head_sha"
  node -e '
    const fs=require("fs"); const crypto=require("crypto"); const path=require("path");
    const [source,destination,supersededDestination,root,head]=process.argv.slice(1); const blockerPath=".review/installed-dispatch-contract-blocker.json";
    const blocker={schema_version:"1",artifact_type:"blocker",lifecycle:"active",producer_role:"CODEX",issue:{number:188,title:"installed dispatch contract"},head_sha:head,reason_code:"failing_precondition",blocking_fact:"the installed cmux command did not start the watchdog",attempted_commands:["cmux workspace create --command ..."],needed_decision:"repair the dispatch wrapper"};
    const content=JSON.stringify(blocker); fs.writeFileSync(path.join(root,blockerPath),content);
    const value=JSON.parse(fs.readFileSync(source,"utf8")); value.round_control={failures:[{id:"F-1",dispatch_ordinal:1,status:"open",primary_origin:"dispatch_contract",secondary_origins:[],failed_ac_ids:["AC-1"],owner:"CONDUCTOR",next_action:{kind:"contract_fix",summary:"repair the dispatch contract"},evidence:[{kind:"blocker",path:blockerPath,content_sha256:crypto.createHash("sha256").update(content).digest("hex"),head_sha:head}]}]}; fs.writeFileSync(destination,JSON.stringify(value));
    const supersededPath=".review/installed-superseded-blocker.json"; const supersededContent=JSON.stringify({...blocker,lifecycle:"superseded"}); fs.writeFileSync(path.join(root,supersededPath),supersededContent);
    const supersededState=JSON.parse(JSON.stringify(value)); supersededState.round_control.failures[0].evidence[0].path=supersededPath; supersededState.round_control.failures[0].evidence[0].content_sha256=crypto.createHash("sha256").update(supersededContent).digest("hex"); fs.writeFileSync(supersededDestination,JSON.stringify(supersededState));
  ' "$GATE_STATE" "$GATE_BLOCKER_STATE" "$GATE_SUPERSEDED_BLOCKER_STATE" "$target" "$head_sha"
  printf '%s\n' 'test AC-1 behavior' > "$GATE_TESTS"
  printf '%s\n' 'implementation prompt' '<!-- agent-workflow:ac-block:start -->' '```json' '[{"id":"AC-1","statement":"the installed gate discovers AC-1"}]' '```' '<!-- agent-workflow:ac-block:end -->' > "$target/.review/ISSUE-188-PROMPT.md"
  "$PRODUCT_ROOT/scripts/output-contract.sh" render --role implementation >> "$target/.review/ISSUE-188-PROMPT.md"
  "$PRODUCT_ROOT/scripts/output-contract.sh" render --role reviewer > "$target/.review/ISSUE-188-REVIEW-PROMPT.md"
}

assert_installed_gates() {
  label="$1"; target="$2"; scripts="$target/.agent-workflow/scripts"
  installed_report="$target/.review/installed-verify-green.json"
  printf '%s\n' '{"numPassedTests":1,"numFailedTests":0,"numPendingTests":0,"numFailedTestSuites":0,"success":true}' > "$installed_report"
  assert_exit "$label executes verify classifier" PASS bash "$scripts/verify.sh" --classify-json "$installed_report"

  installed_bin="$target/.review/installed-verify-bin"
  installed_clean="$target/.review/installed-clean.sh"
  mkdir -p "$installed_bin"
  cat > "$installed_bin/pnpm" <<'STUB'
#!/usr/bin/env bash
for arg in "$@"; do case "$arg" in --outputFile=*) output="${arg#--outputFile=}" ;; esac; done
case "${PNPM_STUB_MODE:-green}" in
  fail) printf '%s\n' '{"numPassedTests":0,"numFailedTests":1,"numPendingTests":0,"numFailedTestSuites":0,"success":false}' > "$output"; exit 1 ;;
  *) printf '%s\n' '{"numPassedTests":1,"numFailedTests":0,"numPendingTests":0,"numFailedTestSuites":0,"success":true}' > "$output"; exit 0 ;;
esac
STUB
  chmod +x "$installed_bin/pnpm"
  cat > "$installed_clean" <<'CLEAN'
#!/usr/bin/env bash
printf '%s\n' '{"checks":[{"code":"sentinel","expected":"clean","actual":"clean"},{"code":"migration_hash","expected":"same","actual":"same"}],"role":{"name":"fops_app","superuser":false}}'
CLEAN
  chmod +x "$installed_clean"
  ( cd "$target" && VERIFY_DATABASE_URL="postgres://fops_app@127.0.0.1/verify_smoke" VERIFY_CLEAN_COMMAND="sh '$installed_clean'" VERIFY_ISSUE=189 PNPM_STUB_MODE=fail VERIFY_ENV_ALLOW=PNPM_STUB_MODE PATH="$installed_bin:$PATH" bash "$scripts/verify.sh" permissions ) >/dev/null 2>&1
  installed_first_ec=$?
  ( cd "$target" && VERIFY_DATABASE_URL="postgres://fops_app@127.0.0.1/verify_smoke" VERIFY_CLEAN_COMMAND="sh '$installed_clean'" VERIFY_ISSUE=189 PNPM_STUB_MODE=green VERIFY_ENV_ALLOW=PNPM_STUB_MODE PATH="$installed_bin:$PATH" bash "$scripts/verify.sh" surveys ) >/dev/null 2>&1
  installed_second_ec=$?
  if [ "$installed_first_ec" -eq 1 ] && [ "$installed_second_ec" -eq 1 ] && node -e 'const o=require(process.argv[1]); process.exit(Array.isArray(o.runs)&&o.runs.length===2&&o.classifier==="FAIL"&&o.runs[1].classifier==="PASS" ? 0 : 1)' "$target/.review/ISSUE-189-VERIFY.json"; then
    ok "$label installed verify preserves a red-latched aggregate"
  else
    not_ok "$label installed verify preserves a red-latched aggregate"
  fi
  ( cd "$target" && VERIFY_DATABASE_URL="postgres://fops_app@127.0.0.1/verify_smoke" VERIFY_CLEAN_COMMAND="sh '$installed_clean'" VERIFY_ISSUE=190 PNPM_STUB_MODE=green VERIFY_ENV_ALLOW=PNPM_STUB_MODE PATH="$installed_bin:$PATH" bash "$scripts/verify.sh" installed-conductor ) >/dev/null 2>&1
  installed_conductor_verify_ec=$?
  installed_branch="$(git -C "$target" rev-parse --abbrev-ref HEAD)"
  installed_head="$(git -C "$target" rev-parse HEAD)"
  node - "$target/.review/ISSUE-190-PR-DRAFT.json" "$target" "$installed_branch" "$installed_head" <<'NODE'
const fs=require("fs"); const [file,worktree,branch,head]=process.argv.slice(2);
fs.writeFileSync(file,JSON.stringify({schema_version:"1",artifact_type:"pr_draft",lifecycle:"active",producer_role:"CODEX",issue:{number:190,title:"installed conductor schema"},branch,base_sha:head,head_sha:head,files_touched:[{path:"allowed/file.txt",change:"edit"}],verify_cmd:"verify.sh installed-conductor",status:"ready_for_review",worktree_path:worktree}));
NODE
  installed_conductor_out="$(bash "$scripts/conductor-rebuild.sh" "$target/.review" 2>/dev/null)"
  if [ "$installed_conductor_verify_ec" -eq 0 ] && printf '%s\n' "$installed_conductor_out" | grep -q '^190	verified'; then
    ok "$label installed conductor resolves its sibling VERIFY schema"
  else
    not_ok "$label installed conductor resolves its sibling VERIFY schema"
  fi
  assert_exit "$label executes ac-check" PASS bash "$scripts/ac-check.sh" --round-state "$GATE_STATE" --manifest-revision 3 --tests "$GATE_TESTS"
  assert_exit "$label executes completion-check" PASS bash "$scripts/completion-check.sh" --round-state "$GATE_STATE" --manifest-revision 3
  node -e '
    const fs=require("fs"); const file=process.argv[1]; const v=JSON.parse(fs.readFileSync(file,"utf8"));
    v.contract.test_discovery_command="printf '\''TAP version 13\\n# AC-1\\n# tests 3\\n'\''";
    v.contract.test_count={pattern:"(?:ℹ |# )?tests ([0-9]+)",group:1}; v.acceptance.expected_test_count=3;
    fs.writeFileSync(file,JSON.stringify(v));
  ' "$GATE_STATE"
  assert_exit "$label installed completion-check extracts native test count" PASS bash "$scripts/completion-check.sh" --round-state "$GATE_STATE" --manifest-revision 3
  assert_exit "$label executes redispatch-check" PASS bash "$scripts/redispatch-check.sh" --round-state "$GATE_STATE" --manifest-revision 3
  assert_exit "$label accepts dispatch-contract BLOCKER redispatch evidence" PASS bash "$scripts/redispatch-check.sh" --round-state "$GATE_BLOCKER_STATE" --manifest-revision 3
  assert_exit_output "$label rejects superseded BLOCKER redispatch evidence" 2 "superseded_evidence_artifact" bash "$scripts/redispatch-check.sh" --round-state "$GATE_SUPERSEDED_BLOCKER_STATE" --manifest-revision 3
  assert_exit "$label enforces canonical initial-write admission" PASS bash "$scripts/cmux-dispatch.sh" --issue 188 --worktree "$target" --tier full_cluster --round-state "$GATE_STATE" --manifest-revision 3 --dry-run
  assert_exit_output "$label exposes canonical REVIEW publication" 0 "--produce-review" bash "$scripts/cmux-dispatch.sh" --issue 188 --worktree "$target" --prompt-file .review/ISSUE-188-REVIEW-PROMPT.md --produce-review --model gpt-5.6-sol --effort medium --dry-run
}

assert_installed_real_dispatch() {
  label="$1"; target="$2"; scripts="$target/.agent-workflow/scripts"
  installed_watchdog="$scripts/agent-watchdog.sh"
  watchdog_backup="$TMP_DIR/installed-watchdog.backup"
  cp "$installed_watchdog" "$watchdog_backup"
  cat > "$installed_watchdog" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$0" "$@" > "$INSTALLED_WATCHDOG_LOG"
issue=""
cwd=""
while [ $# -gt 0 ]; do
  case "$1" in
    --issue) issue="$2"; shift 2 ;;
    --cwd) cwd="$2"; shift 2 ;;
    *) shift 1 ;;
  esac
done
printf '%s\n' "{\"schema_version\":\"1\",\"artifact_type\":\"codex_run\",\"issue\":$issue,\"attempt\":1,\"started_at\":\"2026-07-21T00:00:00Z\",\"updated_at\":\"2026-07-21T00:00:00Z\",\"status\":\"running\"}" > "$cwd/.review/ISSUE-${issue}-RUN.json"
EOF
  chmod +x "$installed_watchdog"
  installed_cmux_bin="$TMP_DIR/installed-cmux-bin"
  mkdir -p "$installed_cmux_bin"
  cat > "$installed_cmux_bin/cmux" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo 'cmux 0.64.18'; exit 0; fi
if [ "${1:-}" = "workspace" ] && [ "${2:-}" = "create" ] && [ "${3:-}" = "--help" ]; then echo 'create [flags]'; exit 0; fi
if [ "${1:-}" = "new-workspace" ] && [ "${2:-}" = "--help" ]; then echo '--cwd PATH --command TEXT'; exit 0; fi
cwd=""
command=""
shift 2
while [ $# -gt 0 ]; do
  case "$1" in
    --cwd) cwd="$2"; shift 2 ;;
    --command) command="$2"; shift 2 ;;
    *) shift 1 ;;
  esac
done
printf '%s\n' "$command" > "$INSTALLED_CMUX_COMMAND"
(cd "$cwd" && /bin/sh -c "$command") >/dev/null 2>&1 || :
printf '%s\n' '{"id":"installed-portable-workspace"}'
EOF
  chmod +x "$installed_cmux_bin/cmux"
  printf '%s\n' 'portable runner prompt' > "$target/.review/ISSUE-189-PROMPT.txt"
  installed_dispatch_out="$TMP_DIR/installed-real-dispatch.out"
  INSTALLED_WATCHDOG_LOG="$TMP_DIR/installed-watchdog.log" \
  INSTALLED_CMUX_COMMAND="$TMP_DIR/installed-cmux-command.txt" \
  CMUX_DISPATCH_POLL_INTERVAL=1 PATH="$installed_cmux_bin:$PATH" \
  bash "$scripts/cmux-dispatch.sh" --issue 189 --worktree "$target" --read-only --poll-timeout 3 >"$installed_dispatch_out" 2>&1
  installed_dispatch_exit=$?
  installed_command="$(cat "$TMP_DIR/installed-cmux-command.txt" 2>/dev/null)"
  installed_runner_relative="${installed_command#bash }"
  if [ "$installed_dispatch_exit" -eq 0 ] && [ "$installed_command" != "$installed_runner_relative" ] \
    && [ "${#installed_command}" -lt 256 ] && [ -x "$target/$installed_runner_relative" ] \
    && grep -Fx -- "$installed_watchdog" "$TMP_DIR/installed-watchdog.log" >/dev/null \
    && grep -Fx -- "$target/.review/ISSUE-189-PROMPT.txt" "$TMP_DIR/installed-watchdog.log" >/dev/null \
    && grep -q 'fresh RUN.json present' "$installed_dispatch_out"; then
    ok "$label executes retained runner from portable copy"
  else
    not_ok "$label executes retained runner from portable copy"
  fi
  cp "$watchdog_backup" "$installed_watchdog"
  chmod +x "$installed_watchdog"
}

assert_product_home_worktree_contract() {
  target="$1"
  product_home="$target/.agent-workflow"
  worktree="$TMP_DIR/fresh-linked-worktree"
  transport_bin="$TMP_DIR/product-home-transport-bin"
  mkdir -p "$transport_bin"
  cat > "$transport_bin/cmux" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo 'cmux 0.64.0'; exit 0 ;;
  workspace) [ "${2:-}" = create ] && [ "${3:-}" = --help ] && { echo 'create [flags]'; exit 0; } ;;
  new-workspace) [ "${2:-}" = --help ] && { echo '--cwd PATH --command COMMAND'; exit 0; } ;;
esac
exit 2
EOF
  chmod +x "$transport_bin/cmux"

  git init -q "$target"
  git -C "$target" config user.email smoke@example.test
  git -C "$target" config user.name smoke
  printf '%s\n' '.agent-workflow/' > "$target/.gitignore"
  git -C "$target" add .gitignore project.txt
  git -C "$target" commit -qm 'initial target'
  git -C "$target" worktree add -q -b issue-62 "$worktree" HEAD
  mkdir -p "$worktree/.review"
  printf '%s\n' 'worktree-owned evidence' > "$worktree/.review/keep.txt"
  printf '%s\n' 'worker prompt' > "$worktree/.review/ISSUE-62-PROMPT.md"
  bash "$product_home/scripts/output-contract.sh" render --role implementation >> "$worktree/.review/ISSUE-62-PROMPT.md"
  printf '%s\n' '{"orchestrator":"cmux"}' > "$product_home/workflow-config.json"

  assert_true "fresh linked worktree omits ignored product home" test ! -e "$worktree/.agent-workflow"
  assert_true "product-home output contract renders in fresh linked worktree" grep -F -q 'agent-workflow:output-contract' "$worktree/.review/ISSUE-62-PROMPT.md"
  assert_exit "product-home output contract checks fresh linked worktree prompt" PASS bash "$product_home/scripts/output-contract.sh" check --role implementation --prompt-file "$worktree/.review/ISSUE-62-PROMPT.md"
  dispatch_out="$TMP_DIR/product-home-dispatch.out"
  PATH="$transport_bin:$PATH" AGENT_WORKFLOW_CODEX_BIN="$AGENT_WORKFLOW_CODEX_BIN" \
    bash "$product_home/scripts/agent-workflow.sh" dispatch --issue 62 --worktree "$worktree" --read-only --dry-run >"$dispatch_out" 2>&1
  dispatch_status=$?
  if [ "$dispatch_status" -eq 0 ] && grep -F -q 'orchestrator=cmux source=config' "$dispatch_out"; then
    ok "product-home dispatch dry-run works from fresh linked worktree"
  else
    not_ok "product-home dispatch dry-run works from fresh linked worktree"
  fi
  assert_true "product-home commands preserve worktree-local review evidence" grep -F -q 'worktree-owned evidence' "$worktree/.review/keep.txt"
}

fresh="$TMP_DIR/fresh target"
mkdir -p "$fresh/.review"
printf '%s\n' evidence > "$fresh/.review/keep.txt"
printf '%s\n' project > "$fresh/project.txt"
assert_exit "fresh install succeeds" PASS bash "$INSTALL" "$fresh"
assert_portable_layout "fresh install" "$fresh"
assert_current_content "fresh install" "$fresh"
assert_true "fresh install omits source-only smoke suite" test ! -e "$fresh/.agent-workflow/scripts/__tests__"
assert_true "fresh install preserves review evidence" grep -F -q evidence "$fresh/.review/keep.txt"
assert_true "fresh install preserves unrelated project files" grep -F -q project "$fresh/project.txt"
assert_true "fresh install does not create target instructions" test ! -e "$fresh/AGENTS.md"
assert_true "fresh install implementation contract requires canonical AC ids in test names" grep -F -q 'Name each test so it contains the canonical AC id it satisfies' "$fresh/.agent-workflow/scripts/lib/output-contract.mjs"
assert_true "fresh install skill documents canonical AC ids in test names" grep -F -q 'Name each test so it contains the canonical AC id it satisfies' "$fresh/.claude/skills/agent-workflow/SKILL.md"
assert_true "fresh install ships Claude reviewer allocation" node -e 'const v=require(process.argv[1]); process.exit(v.reviewer_by_runtime && v.reviewer_by_runtime.claude && v.reviewer_by_runtime.claude.model === "sonnet" && v.reviewer_by_runtime.claude.effort === "medium" ? 0 : 1)' "$fresh/.agent-workflow/model-alloc.json"
assert_no_maintainer_leakage "$fresh"
assert_true "default install records FeedbackOps profile" grep -F -q '"profile":"feedbackops"' "$fresh/.agent-workflow/install-profile.json"
assert_product_home_worktree_contract "$fresh"

agents_target="$TMP_DIR/agents-target"
mkdir -p "$agents_target"
printf '%s\n' '# Target instructions' 'Keep this target-owned preamble.' > "$agents_target/AGENTS.md"
chmod 640 "$agents_target/AGENTS.md"
assert_exit "install appends one managed AGENTS pointer" PASS bash "$INSTALL" "$agents_target"
assert_true "managed AGENTS pointer preserves preamble" grep -F -q 'Keep this target-owned preamble.' "$agents_target/AGENTS.md"
assert_true "managed AGENTS pointer names allocation contract" grep -F -q '.agent-workflow/model-alloc.json' "$agents_target/AGENTS.md"
assert_true "managed AGENTS pointer has one begin marker" bash -c '[ "$(grep -F -c "<!-- agent-workflow:begin (managed by install-into.sh — do not edit) -->" "$1")" -eq 1 ]' _ "$agents_target/AGENTS.md"
assert_true "managed AGENTS install preserves target mode" node -e 'const fs=require("fs"); process.exit((fs.statSync(process.argv[1]).mode & 0o7777) === 0o640 ? 0 : 1)' "$agents_target/AGENTS.md"
printf '%s\n' 'Keep this target-owned suffix.' >> "$agents_target/AGENTS.md"
node -e 'const fs=require("fs"); const file=process.argv[1]; fs.writeFileSync(file, fs.readFileSync(file, "utf8").replace("### Model routing (installed by the agent-workflow toolkit)", "### outdated pointer"));' "$agents_target/AGENTS.md"
agents_upgrade_output="$TMP_DIR/agents-upgrade-output.txt"
bash "$INSTALL" "$agents_target" --upgrade >"$agents_upgrade_output" 2>&1
agents_upgrade_exit=$?
if [ "$agents_upgrade_exit" -eq 0 ]; then ok "upgrade rewrites managed AGENTS pointer"; else not_ok "upgrade rewrites managed AGENTS pointer"; fi
assert_true "managed AGENTS upgrade preserves preamble" grep -F -q 'Keep this target-owned preamble.' "$agents_target/AGENTS.md"
assert_true "managed AGENTS upgrade preserves suffix" grep -F -q 'Keep this target-owned suffix.' "$agents_target/AGENTS.md"
assert_true "managed AGENTS upgrade replaces old pointer bytes" bash -c '! grep -F -q "### outdated pointer" "$1"' _ "$agents_target/AGENTS.md"
assert_true "managed AGENTS upgrade has one begin marker" bash -c '[ "$(grep -F -c "<!-- agent-workflow:begin (managed by install-into.sh — do not edit) -->" "$1")" -eq 1 ]' _ "$agents_target/AGENTS.md"
assert_true "managed AGENTS upgrade preserves target mode" node -e 'const fs=require("fs"); process.exit((fs.statSync(process.argv[1]).mode & 0o7777) === 0o640 ? 0 : 1)' "$agents_target/AGENTS.md"
agents_backup_root="$(sed -n 's/^upgrade backup: //p' "$agents_upgrade_output")"
assert_true "managed AGENTS upgrade backs up previous pointer bytes" grep -F -q '### outdated pointer' "$agents_backup_root/agents"

malformed_agents="$TMP_DIR/malformed-agents"
mkdir -p "$malformed_agents"
printf '%s\n' '# Target instructions' '<!-- agent-workflow:begin (managed by install-into.sh — do not edit) -->' > "$malformed_agents/AGENTS.md"
assert_exit_output "unpaired AGENTS pointer markers fail closed" 2 "malformed or duplicate agent-workflow pointer markers" bash "$INSTALL" "$malformed_agents"
assert_true "malformed AGENTS pointer leaves installer paths absent" test ! -e "$malformed_agents/.agent-workflow"
assert_true "malformed AGENTS pointer preserves target file" grep -F -q '# Target instructions' "$malformed_agents/AGENTS.md"

duplicate_agents="$TMP_DIR/duplicate-agents"
mkdir -p "$duplicate_agents"
printf '%s\n' '<!-- agent-workflow:begin (managed by install-into.sh — do not edit) -->' '<!-- agent-workflow:end -->' '<!-- agent-workflow:begin (managed by install-into.sh — do not edit) -->' '<!-- agent-workflow:end -->' > "$duplicate_agents/AGENTS.md"
assert_exit_output "duplicate AGENTS pointer markers fail closed" 2 "malformed or duplicate agent-workflow pointer markers" bash "$INSTALL" "$duplicate_agents"
assert_true "duplicate AGENTS pointer leaves installer paths absent" test ! -e "$duplicate_agents/.agent-workflow"

generic="$TMP_DIR/generic target"
mkdir -p "$generic"
assert_exit "generic install succeeds" PASS bash "$INSTALL" "$generic" --profile generic
assert_portable_layout "generic install" "$generic"
assert_generic_profile "$generic"
git -C "$generic" init -q
git -C "$generic" config user.email smoke@example.test
git -C "$generic" config user.name smoke
printf '%s\n' seed > "$generic/README.md"
git -C "$generic" add README.md
git -C "$generic" commit -qm seed
mkdir -p "$generic/bin"
cat > "$generic/bin/generic-pass" <<'EOF'
#!/usr/bin/env bash
echo "1 tests"
EOF
chmod +x "$generic/bin/generic-pass"
cat > "$generic/generic-profile.json" <<'EOF'
{"schema_version":"1","id":"installed-generic","runtime":{"executables":["generic-pass"]},"setup":[],"verification":{"groups":[{"id":"test","required":true,"commands":[{"argv":["generic-pass"]}],"test_count":{"pattern":"([0-9]+) tests","group":1}}]}}
EOF
if (cd "$generic" && PATH="$generic/bin:$PATH" bash .agent-workflow/scripts/target-verify.sh generic-profile.json 76) >/dev/null 2>&1 \
  && node "$generic/.agent-workflow/scripts/lib/verify-artifact.cjs" validate-artifact "$generic/.review/ISSUE-76-VERIFY.json" "$generic/.agent-workflow/schemas/verify.schema.json" "$generic/.agent-workflow/scripts/lib/json-schema-subset.cjs" >/dev/null 2>&1; then
  ok "generic install executes target verifier and publishes semantic PASS evidence"
else
  not_ok "generic install executes target verifier and publishes semantic PASS evidence"
fi
assert_true "generic install does not create root instructions" test ! -e "$generic/AGENTS.md"
assert_true "generic install excludes maintainer docs" test ! -e "$generic/docs"
assert_exit_output "generic upgrade refuses FeedbackOps profile substitution" 2 "refusing to change an existing generic installation" bash "$INSTALL" "$generic" --upgrade
assert_exit "generic same-profile upgrade succeeds" PASS bash "$INSTALL" "$generic" --profile generic --upgrade
assert_generic_profile "$generic"
generic_partial="$TMP_DIR/generic-partial"
cp -R "$generic" "$generic_partial"
rm -rf "$generic_partial/.agents/skills/agent-workflow"
assert_exit_output "generic upgrade rejects missing client discovery leaf" 2 "not a complete recognized" bash "$INSTALL" "$generic_partial" --profile generic --upgrade

bad_profile="$TMP_DIR/bad-profile"
mkdir -p "$bad_profile"
bash "$INSTALL" "$bad_profile" >/dev/null
printf '%s\n' '{"schema_version":"999","profile":"feedbackops"}' > "$bad_profile/.agent-workflow/install-profile.json"
assert_exit_output "invalid profile marker fails closed" 2 "install profile marker is invalid" bash "$INSTALL" "$bad_profile" --upgrade

assert_exit_output "default rerun refuses existing install" 2 "--upgrade" bash "$INSTALL" "$fresh"
printf '%s\n' customized > "$fresh/.agent-workflow/scripts/install-into.sh"
printf '%s\n' '{"project_owned":true}' > "$fresh/.agent-workflow/model-alloc.json"
upgrade_output="$TMP_DIR/upgrade-output.txt"
bash "$INSTALL" "$fresh" --upgrade >"$upgrade_output" 2>&1
upgrade_exit=$?
if [ "$upgrade_exit" -eq 0 ]; then ok "copy upgrade succeeds"; else not_ok "copy upgrade succeeds"; fi
assert_current_content "copy upgrade" "$fresh"
backup_root="$(sed -n 's/^upgrade backup: //p' "$upgrade_output")"
assert_true "upgrade reports a retained backup" test -d "$backup_root"
assert_true "upgrade backup preserves customized managed content" grep -F -q customized "$backup_root/scripts/install-into.sh"
assert_true "upgrade preserves project-owned model allocation config" grep -F -q project_owned "$fresh/.agent-workflow/model-alloc.json"
assert_true "upgrade preserves review evidence" grep -F -q evidence "$fresh/.review/keep.txt"
# The default-write admission contract requires a schema-valid allocation;
# restore the shipped valid config before exercising the portable dispatch gate.
cp "$PRODUCT_ROOT/model-alloc.json" "$fresh/.agent-workflow/model-alloc.json"

legacy_alloc="$TMP_DIR/legacy-allocation"
mkdir -p "$legacy_alloc"
assert_exit "legacy allocation install succeeds" PASS bash "$INSTALL" "$legacy_alloc"
printf '%s\n' '{"schema_version":"1","source":"legacy","release":"old","roles":{"implementation":{"model":"gpt-5.6-terra","effort":"low"},"reviewer":{"model":"gpt-5.6-sol","effort":"medium"},"contract_gate":{"model":"gpt-5.6-sol","effort":"medium"},"trivial_implementation":{"model":"gpt-5.6-luna","effort":"low"}},"capabilities":{"gpt-5.6-terra":{"agentic_coding":1,"static_coding":1,"reasoning":1,"input_per_million":1,"output_per_million":1},"gpt-5.6-sol":{"agentic_coding":1,"static_coding":1,"reasoning":1,"input_per_million":1,"output_per_million":1},"gpt-5.6-luna":{"agentic_coding":1,"static_coding":1,"reasoning":1,"input_per_million":1,"output_per_million":1}},"signals":{"trivial_changed_lines":50,"large_changed_lines":400,"large_file_count":8}}' > "$legacy_alloc/.agent-workflow/model-alloc.json"
assert_exit_output "upgrade preserves legacy allocation with runtime migration warning" 0 "preserving legacy schema-v1 config" bash "$INSTALL" "$legacy_alloc" --upgrade
assert_true "upgrade leaves legacy allocation project-owned" grep -F -q '"source":"legacy"' "$legacy_alloc/.agent-workflow/model-alloc.json"

current_links="$TMP_DIR/current-links"
mkdir -p "$current_links/.agent-workflow/docs" "$current_links/.claude/skills"
ln -s "$PRODUCT_ROOT/scripts" "$current_links/.agent-workflow/scripts"
ln -s "$PRODUCT_ROOT/schemas" "$current_links/.agent-workflow/schemas"
ln -s "$PRODUCT_ROOT/docs/agents" "$current_links/.agent-workflow/docs/agents"
ln -s "$PRODUCT_ROOT/.claude/skills/agent-workflow" "$current_links/.claude/skills/agent-workflow"
assert_exit "current symlink install upgrades to copy" PASS bash "$INSTALL" "$current_links" --upgrade
assert_portable_layout "current symlink upgrade" "$current_links"

current_dangling="$TMP_DIR/current-dangling"
current_dangling_root="$TMP_DIR/deleted current root"
mkdir -p "$current_dangling/.agent-workflow/docs" "$current_dangling/.claude/skills"
ln -s "$current_dangling_root/scripts" "$current_dangling/.agent-workflow/scripts"
ln -s "$current_dangling_root/schemas" "$current_dangling/.agent-workflow/schemas"
ln -s "$current_dangling_root/docs/agents" "$current_dangling/.agent-workflow/docs/agents"
ln -s "$current_dangling_root/.claude/skills/agent-workflow" "$current_dangling/.claude/skills/agent-workflow"
assert_exit "dangling current symlink install upgrades to copy" PASS bash "$INSTALL" "$current_dangling" --upgrade
assert_portable_layout "dangling current symlink upgrade" "$current_dangling"

# release-contract: legacy-link-fixture-begin
legacy_links="$TMP_DIR/legacy-links"
legacy_root="$TMP_DIR/deleted legacy root"
mkdir -p "$legacy_links/.agent-workflow/docs" "$legacy_links/.claude/skills"
ln -s "$legacy_root/scripts" "$legacy_links/.agent-workflow/scripts"
ln -s "$legacy_root/.review/schemas" "$legacy_links/.agent-workflow/schemas"
ln -s "$legacy_root/docs/agents" "$legacy_links/.agent-workflow/docs/agents"
ln -s "$legacy_root/.claude/skills/agent-workflow" "$legacy_links/.claude/skills/agent-workflow"
assert_exit "dangling legacy symlink install upgrades to copy" PASS bash "$INSTALL" "$legacy_links" --upgrade
assert_portable_layout "legacy symlink upgrade" "$legacy_links"

legacy_live="$TMP_DIR/legacy-live"
legacy_live_root="$TMP_DIR/live legacy root"
mkdir -p "$legacy_live/.agent-workflow/docs" "$legacy_live/.claude/skills" \
  "$legacy_live_root/scripts" "$legacy_live_root/.review/schemas" \
  "$legacy_live_root/docs/agents" "$legacy_live_root/.claude/skills/agent-workflow"
ln -s "$legacy_live_root/scripts" "$legacy_live/.agent-workflow/scripts"
ln -s "$legacy_live_root/.review/schemas" "$legacy_live/.agent-workflow/schemas"
ln -s "$legacy_live_root/docs/agents" "$legacy_live/.agent-workflow/docs/agents"
ln -s "$legacy_live_root/.claude/skills/agent-workflow" "$legacy_live/.claude/skills/agent-workflow"
# release-contract: legacy-link-fixture-end
assert_exit "live legacy symlink install upgrades to copy" PASS bash "$INSTALL" "$legacy_live" --upgrade
assert_portable_layout "live legacy symlink upgrade" "$legacy_live"

mixed="$TMP_DIR/mixed-topology"
mkdir -p "$mixed"
bash "$INSTALL" "$mixed" >/dev/null
rm -rf "$mixed/.agent-workflow/docs/agents" "$mixed/.claude/skills/agent-workflow"
ln -s "$PRODUCT_ROOT/docs/agents" "$mixed/.agent-workflow/docs/agents"
ln -s "$PRODUCT_ROOT/.claude/skills/agent-workflow" "$mixed/.claude/skills/agent-workflow"
assert_exit_output "mixed copy and link topology fails closed" 2 "not a complete recognized" bash "$INSTALL" "$mixed" --upgrade
assert_true "mixed topology refusal preserves docs link" test -L "$mixed/.agent-workflow/docs/agents"

uncorrelated_links="$TMP_DIR/uncorrelated-links"
mkdir -p "$uncorrelated_links/.agent-workflow/docs" "$uncorrelated_links/.claude/skills"
ln -s "$TMP_DIR/root-a/scripts" "$uncorrelated_links/.agent-workflow/scripts"
ln -s "$TMP_DIR/root-b/schemas" "$uncorrelated_links/.agent-workflow/schemas"
ln -s "$TMP_DIR/root-c/docs/agents" "$uncorrelated_links/.agent-workflow/docs/agents"
ln -s "$TMP_DIR/root-d/.claude/skills/agent-workflow" "$uncorrelated_links/.claude/skills/agent-workflow"
assert_exit_output "uncorrelated absolute links fail closed" 2 "not a complete recognized" bash "$INSTALL" "$uncorrelated_links" --upgrade
assert_true "uncorrelated link refusal preserves scripts" test "$(readlink "$uncorrelated_links/.agent-workflow/scripts")" = "$TMP_DIR/root-a/scripts"

filesystem_root_links="$TMP_DIR/filesystem-root-links"
filesystem_other_root="$TMP_DIR/other-root"
mkdir -p "$filesystem_root_links/.agent-workflow/docs" "$filesystem_root_links/.claude/skills"
ln -s /scripts "$filesystem_root_links/.agent-workflow/scripts"
ln -s "$filesystem_other_root/schemas" "$filesystem_root_links/.agent-workflow/schemas"
ln -s "$filesystem_other_root/docs/agents" "$filesystem_root_links/.agent-workflow/docs/agents"
ln -s "$filesystem_other_root/.claude/skills/agent-workflow" "$filesystem_root_links/.claude/skills/agent-workflow"
assert_exit_output "filesystem-root link cannot reset correlation" 2 "not a complete recognized" bash "$INSTALL" "$filesystem_root_links" --upgrade

partial="$TMP_DIR/partial"
mkdir -p "$partial/.agent-workflow/scripts"
printf '%s\n' custom > "$partial/.agent-workflow/scripts/custom.txt"
assert_exit_output "partial custom topology fails closed" 2 "not a complete recognized" bash "$INSTALL" "$partial" --upgrade
assert_true "partial custom topology is preserved" grep -F -q custom "$partial/.agent-workflow/scripts/custom.txt"

external="$TMP_DIR/external"
parent_link="$TMP_DIR/parent-link"
mkdir -p "$external" "$parent_link"
printf '%s\n' outside > "$external/sentinel"
ln -s "$external" "$parent_link/.agent-workflow"
assert_exit_output "symlinked managed parent is rejected" 2 "managed parent must not be a symlink" bash "$INSTALL" "$parent_link"
assert_true "managed-parent refusal preserves outside tree" grep -F -q outside "$external/sentinel"

backup_parent_target="$TMP_DIR/backup-parent-target"
backup_parent_outside="$TMP_DIR/backup-parent-outside"
mkdir -p "$backup_parent_target" "$backup_parent_outside"
bash "$INSTALL" "$backup_parent_target" >/dev/null
ln -s "$backup_parent_outside" "$backup_parent_target/.review/agent-workflow-install-backups"
assert_exit_output "symlinked backup parent is rejected" 2 "managed parent must not be a symlink" bash "$INSTALL" "$backup_parent_target" --upgrade
assert_true "backup-parent refusal leaves outside unchanged" bash -c 'test -z "$(find "$1" -mindepth 1 -print -quit)"' _ "$backup_parent_outside"

empty_upgrade="$TMP_DIR/empty-upgrade"
mkdir -p "$empty_upgrade"
assert_exit_output "upgrade requires an existing install" 2 "requires an existing installation" bash "$INSTALL" "$empty_upgrade" --upgrade
assert_exit_output "symlink mode is removed" 2 "installs are always portable copies" bash "$INSTALL" "$empty_upgrade" --mode symlink
assert_exit_output "copy mode flag is removed" 2 "installs are always portable copies" bash "$INSTALL" "$empty_upgrade" --mode copy
assert_exit_output "force points to upgrade" 2 "replaced by --upgrade" bash "$INSTALL" "$empty_upgrade" --force
assert_exit_output "legacy migration points to upgrade" 2 "replaced by --upgrade" bash "$INSTALL" "$empty_upgrade" --migrate-legacy

stage_failure="$TMP_DIR/stage-failure"
mkdir -p "$stage_failure"
cp_bin="$TMP_DIR/cp-bin"
mkdir -p "$cp_bin"
printf '%s\n' '#!/usr/bin/env bash' 'exit 19' > "$cp_bin/cp"
chmod +x "$cp_bin/cp"
assert_exit_output "staging failure changes no target installation" 1 "target installation was not changed" env PATH="$cp_bin:$PATH" bash "$INSTALL" "$stage_failure"
assert_true "staging failure leaves managed scripts absent" test ! -e "$stage_failure/.agent-workflow/scripts"

rollback="$TMP_DIR/rollback"
mkdir -p "$rollback"
bash "$INSTALL" "$rollback" >/dev/null
printf '%s\n' rollback-sentinel > "$rollback/.agent-workflow/scripts/rollback.txt"
mv_bin="$TMP_DIR/mv-bin"
mkdir -p "$mv_bin"
mv_counter="$TMP_DIR/mv-counter"
printf '%s\n' 0 > "$mv_counter"
cat > "$mv_bin/mv" <<'MVEOF'
#!/usr/bin/env bash
count="$(cat "$INSTALL_MV_COUNTER")"
count=$((count + 1))
printf '%s\n' "$count" > "$INSTALL_MV_COUNTER"
if [ "$count" -eq "${INSTALL_MV_FAIL_AT:-5}" ] || \
   [ "$count" -eq "${INSTALL_MV_FAIL_AT_2:--1}" ]; then exit 23; fi
exec /bin/mv "$@"
MVEOF
chmod +x "$mv_bin/mv"
cat > "$mv_bin/rm" <<'RMEOF'
#!/usr/bin/env bash
if [ -n "${INSTALL_RM_FAIL_PATH:-}" ] && [ "${2:-}" = "$INSTALL_RM_FAIL_PATH" ]; then exit 31; fi
exec /bin/rm "$@"
RMEOF
chmod +x "$mv_bin/rm"
assert_exit_output "commit failure rolls back prior installation" 23 "restoring the previous installation" env INSTALL_MV_COUNTER="$mv_counter" PATH="$mv_bin:$PATH" bash "$INSTALL" "$rollback" --upgrade
assert_true "rollback restores previous managed content" grep -F -q rollback-sentinel "$rollback/.agent-workflow/scripts/rollback.txt"
printf '%s\n' 0 > "$mv_counter"
assert_exit_output "backup failure preserves unmoved destinations" 23 "restoring the previous installation" env INSTALL_MV_COUNTER="$mv_counter" INSTALL_MV_FAIL_AT=2 PATH="$mv_bin:$PATH" bash "$INSTALL" "$rollback" --upgrade
assert_true "backup rollback preserves scripts" grep -F -q rollback-sentinel "$rollback/.agent-workflow/scripts/rollback.txt"
assert_true "backup rollback preserves schemas" test -e "$rollback/.agent-workflow/schemas/round_state.schema.json"

rollback_incomplete="$TMP_DIR/rollback-incomplete"
mkdir -p "$rollback_incomplete"
bash "$INSTALL" "$rollback_incomplete" >/dev/null
printf '%s\n' rollback-sentinel > "$rollback_incomplete/.agent-workflow/scripts/rollback.txt"
printf '%s\n' 0 > "$mv_counter"
assert_exit_output "restore failure reports manual recovery" 70 "manual recovery required" env INSTALL_MV_COUNTER="$mv_counter" INSTALL_MV_FAIL_AT=5 INSTALL_MV_FAIL_AT_2=6 PATH="$mv_bin:$PATH" bash "$INSTALL" "$rollback_incomplete" --upgrade
assert_true "restore failure retains scripts backup" bash -c 'test -n "$(find "$1" -path "*/scripts/rollback.txt" -print -quit)"' _ "$rollback_incomplete/.review/agent-workflow-install-backups"

rollback_remove_failure="$TMP_DIR/rollback-remove-failure"
mkdir -p "$rollback_remove_failure"
bash "$INSTALL" "$rollback_remove_failure" >/dev/null
printf '%s\n' old-sentinel > "$rollback_remove_failure/.agent-workflow/scripts/old.txt"
rollback_remove_root="$(cd "$rollback_remove_failure" && pwd -P)"
printf '%s\n' 0 > "$mv_counter"
assert_exit_output "restore removal failure reports manual recovery" 70 "could not remove replacement" env INSTALL_MV_COUNTER="$mv_counter" INSTALL_MV_FAIL_AT=7 INSTALL_RM_FAIL_PATH="$rollback_remove_root/.agent-workflow/scripts" PATH="$mv_bin:$PATH" bash "$INSTALL" "$rollback_remove_failure" --upgrade
assert_true "restore removal failure does not nest backup" test ! -e "$rollback_remove_failure/.agent-workflow/scripts/scripts"
assert_true "restore removal failure retains old scripts backup" bash -c 'test -n "$(find "$1" -path "*/scripts/old.txt" -print -quit)"' _ "$rollback_remove_failure/.review/agent-workflow-install-backups"

agents_rollback="$TMP_DIR/agents-rollback"
mkdir -p "$agents_rollback"
printf '%s\n' '# Target instructions' > "$agents_rollback/AGENTS.md"
bash "$INSTALL" "$agents_rollback" >/dev/null
printf '%s\n' rollback-agents-sentinel >> "$agents_rollback/AGENTS.md"
printf '%s\n' 0 > "$mv_counter"
assert_exit_output "AGENTS replacement failure rolls back target instructions" 23 "restoring the previous installation" env INSTALL_MV_COUNTER="$mv_counter" INSTALL_MV_FAIL_AT=12 PATH="$mv_bin:$PATH" bash "$INSTALL" "$agents_rollback" --upgrade
assert_true "AGENTS rollback restores target-owned instructions" grep -F -q rollback-agents-sentinel "$agents_rollback/AGENTS.md"

product_export="$TMP_DIR/product export"
export_target="$TMP_DIR/export target"
cp -R "$PRODUCT_ROOT" "$product_export"
mkdir -p "$export_target"
assert_exit "git-free export installs from path with spaces" PASS bash "$product_export/scripts/install-into.sh" "$export_target"
assert_portable_layout "git-free export install" "$export_target"
assert_no_maintainer_leakage "$export_target"

prepare_gate_fixture "$fresh"
assert_installed_gates "portable install" "$fresh"
assert_installed_real_dispatch "portable install" "$fresh"

prepare_gate_fixture "$generic"
assert_exit "generic portable install completion-check preserves legacy fallback" PASS bash "$generic/.agent-workflow/scripts/completion-check.sh" --round-state "$GATE_STATE" --manifest-revision 3
node -e '
  const fs=require("fs"); const file=process.argv[1]; const v=JSON.parse(fs.readFileSync(file,"utf8"));
  v.contract.test_discovery_command="printf '\''TAP version 13\\n# AC-1\\n# tests 3\\n'\''";
  v.contract.test_count={pattern:"(?:ℹ |# )?tests ([0-9]+)",group:1}; v.acceptance.expected_test_count=3;
  fs.writeFileSync(file,JSON.stringify(v));
' "$GATE_STATE"
assert_exit "generic portable install completion-check extracts native test count" PASS bash "$generic/.agent-workflow/scripts/completion-check.sh" --round-state "$GATE_STATE" --manifest-revision 3

assert_true "README documents copy-only install" grep -F -q 'self-contained' "$PRODUCT_ROOT/README.md"
assert_true "README documents explicit upgrade" grep -F -q -- '--upgrade' "$PRODUCT_ROOT/README.md"
assert_true "adoption guide documents upgrade" grep -F -q -- '--upgrade' "$PRODUCT_ROOT/.claude/skills/agent-workflow/references/adoption.md"
assert_true "installed skill routes dispatch liveness rules" grep -F -q 'Preserve its direct exit code' "$fresh/.claude/skills/agent-workflow/SKILL.md"

echo "---"
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASS"
  exit 0
fi
echo "$FAILURES CASE(S) FAILED"
exit 1
