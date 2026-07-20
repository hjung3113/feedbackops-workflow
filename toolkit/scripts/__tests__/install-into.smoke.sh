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

ok() { echo "ok   - $1"; }
not_ok() { echo "NOT OK - $1"; FAILURES=$((FAILURES + 1)); }

assert_true() {
  name="$1"; shift
  if "$@"; then ok "$name"; else not_ok "$name"; fi
}

assert_exit() {
  name="$1"; expected="$2"; shift 2
  "$@" >/dev/null 2>&1
  actual=$?
  if { [ "$expected" = PASS ] && [ "$actual" -eq 0 ]; } || \
     { [ "$expected" = FAIL ] && [ "$actual" -ne 0 ]; }; then
    ok "$name"
  else
    not_ok "$name"
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
  assert_true "$label includes schemas" test -e "$target/.agent-workflow/schemas/round_state.schema.json"
  assert_true "$label includes playbook" test -e "$target/.agent-workflow/docs/agents/multi-agent-workflow.md"
  assert_true "$label includes skill" test -e "$target/.claude/skills/agent-workflow/SKILL.md"
}

assert_no_maintainer_leakage() {
  target="$1"
  assert_true "install excludes Matt skills" test ! -e "$target/.agents"
  assert_true "install excludes root instructions" test ! -e "$target/AGENTS.md"
  assert_true "install excludes maintainer tracker" test ! -e "$target/docs/agents/issue-tracker.md"
  assert_true "install excludes plans" test ! -e "$target/docs/plans"
}

prepare_gate_fixture() {
  target="$1"
  fixture="$target/.agent-workflow/schemas/fixtures/round_state.valid.json"
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
    v.contract.touch_allowlist=["allowed/**"]; v.contract.test_discovery_command="printf '\''AC-1\\n'\''";
    delete v.contract.chunk_boundary; v.acceptance.criteria=[{id:"AC-1"}]; v.acceptance.expected_test_count=1;
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
  printf '%s\n' 'implementation prompt' > "$target/.review/ISSUE-188-PROMPT.txt"
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
  assert_exit "$label executes redispatch-check" PASS bash "$scripts/redispatch-check.sh" --round-state "$GATE_STATE" --manifest-revision 3
  assert_exit "$label accepts dispatch-contract BLOCKER redispatch evidence" PASS bash "$scripts/redispatch-check.sh" --round-state "$GATE_BLOCKER_STATE" --manifest-revision 3
  assert_exit_output "$label rejects superseded BLOCKER redispatch evidence" 2 "superseded_evidence_artifact" bash "$scripts/redispatch-check.sh" --round-state "$GATE_SUPERSEDED_BLOCKER_STATE" --manifest-revision 3
  assert_exit "$label enforces canonical initial-write admission" PASS bash "$scripts/cmux-dispatch.sh" --issue 188 --worktree "$target" --tier full_cluster --round-state "$GATE_STATE" --manifest-revision 3 --dry-run
  assert_exit_output "$label exposes canonical REVIEW publication" 0 "--produce-review" bash "$scripts/cmux-dispatch.sh" --issue 188 --worktree "$target" --produce-review --model gpt-5.6-sol --effort medium --dry-run
}

assert_installed_real_dispatch() {
  label="$1"; target="$2"; scripts="$target/.agent-workflow/scripts"
  installed_watchdog="$scripts/codex-watchdog.sh"
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
(cd "$cwd" && /bin/sh -c "$command")
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

fresh="$TMP_DIR/fresh target"
mkdir -p "$fresh/.review"
printf '%s\n' evidence > "$fresh/.review/keep.txt"
printf '%s\n' project > "$fresh/project.txt"
assert_exit "fresh install succeeds" PASS bash "$INSTALL" "$fresh"
assert_portable_layout "fresh install" "$fresh"
assert_current_content "fresh install" "$fresh"
assert_true "fresh install preserves review evidence" grep -F -q evidence "$fresh/.review/keep.txt"
assert_true "fresh install preserves unrelated project files" grep -F -q project "$fresh/project.txt"
assert_no_maintainer_leakage "$fresh"

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
assert_exit_output "restore removal failure reports manual recovery" 70 "could not remove replacement" env INSTALL_MV_COUNTER="$mv_counter" INSTALL_MV_FAIL_AT=6 INSTALL_RM_FAIL_PATH="$rollback_remove_root/.agent-workflow/scripts" PATH="$mv_bin:$PATH" bash "$INSTALL" "$rollback_remove_failure" --upgrade
assert_true "restore removal failure does not nest backup" test ! -e "$rollback_remove_failure/.agent-workflow/scripts/scripts"
assert_true "restore removal failure retains old scripts backup" bash -c 'test -n "$(find "$1" -path "*/scripts/old.txt" -print -quit)"' _ "$rollback_remove_failure/.review/agent-workflow-install-backups"

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
