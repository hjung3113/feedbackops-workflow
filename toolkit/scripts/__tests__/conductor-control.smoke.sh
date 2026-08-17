#!/usr/bin/env bash
# Offline host-publication contract for read-only conductors.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; WATCHDOG="$SCRIPT_DIR/../agent-watchdog.sh"; TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT; FAIL=0
ok(){ echo "ok   - $1"; }; bad(){ echo "NOT OK - $1"; FAIL=$((FAIL + 1)); }
BIN="$TMP/bin"; WT="$TMP/wt"; mkdir -p "$BIN" "$WT"; printf 'conductor prompt\n' > "$WT/prompt.txt"
git -C "$WT" init -q -b main; git -C "$WT" config user.email t@t; git -C "$WT" config user.name t; git -C "$WT" add prompt.txt; git -C "$WT" commit -qm seed
for runtime in codex claude opencode; do
  cat > "$BIN/$runtime" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then echo 9.9; exit 0; fi
if [ "$1" = "--help" ] || [ "$2" = "--help" ]; then echo 'exec --sandbox --cd --model --config --output-last-message --json --print --permission-mode --output-format --effort --include-partial-messages run --dir --format --agent --variant json'; exit 0; fi
cat "$CONTROL_PROPOSAL"
EOF
  chmod +x "$BIN/$runtime"
done
printf '{"permission":{"*":"deny","read":"allow","external_directory":"deny","bash":"deny","webfetch":"deny","websearch":"deny"},"agent":{"agent-workflow":{"mode":"primary","permission":{"*":"deny","read":"allow","external_directory":"deny","bash":"deny","webfetch":"deny","websearch":"deny"}}}}\n' > "$TMP/read.json"
make_proposal() {
  CONTROL_PROPOSAL="$TMP/proposal.json" CONTROL_ISSUE="$1" CONTROL_REVISION="$2" CONTROL_PATH="$3" CONTROL_WT="$WT" node <<'NODE'
const fs=require("fs"),{execFileSync}=require("child_process");
const cwd=process.env.CONTROL_WT, head=execFileSync("git",["-C",cwd,"rev-parse","HEAD"],{encoding:"utf8"}).trim();
const content={schema_version:"1",artifact_type:"round_state",lifecycle:"active",producer_role:"CONDUCTOR",issue:{number:Number(process.env.CONTROL_ISSUE),title:"control"},tier:{name:"trivial",rationale:"test"},revision:Number(process.env.CONTROL_REVISION),updated_at:"2026-07-22T00:00:00Z",base_branch:"main",base_sha:head,head_sha:head,worktree_path:cwd,contract:{objective:"test",touch_allowlist:["x"],prohibitions:["no source write"],verify_filter:"test",test_discovery_command:"test"},acceptance:{expected_test_count:1,criteria:[{id:"AC-1",statement:"test"}]},decisions:[],prior_findings:[],commit_scope:{commits:[]},live_probes:[],artifact_pointers:[]};
fs.writeFileSync(process.env.CONTROL_PROPOSAL,JSON.stringify({schema_version:"1",artifact_type:"conductor_control_proposal",issue:Number(process.env.CONTROL_ISSUE),head_sha:head,actions:[{kind:"publish",artifact_type:"round_state",relative_path:process.env.CONTROL_PATH,content}]}));
NODE
}
issue=710
for runtime in codex claude opencode; do
  make_proposal "$issue" 1 ".review/ISSUE-$issue-ROUND-STATE.json"
  CONTROL_PROPOSAL="$TMP/proposal.json" PATH="$BIN:$PATH" AGENT_WATCHDOG_POLL_INTERVAL=1 bash "$WATCHDOG" --issue "$issue" --runtime "$runtime" --role conductor --mode read --prompt-file "$WT/prompt.txt" --cwd "$WT" --opencode-permission-file "$TMP/read.json" --conductor-control --max-retries 0 >"$TMP/$runtime.out" 2>&1
  if [ $? -eq 0 ] && node -e 'const a=require(process.argv[1]),r=require(process.argv[2]); if(a.producer_role!=="CONDUCTOR"||r.status!=="exited"||r.runtime!==process.argv[3]||r.role!=="conductor")process.exit(1)' "$WT/.review/ISSUE-$issue-ROUND-STATE.json" "$WT/.review/ISSUE-$issue-RUN.json" "$runtime"; then ok "$runtime conductor publishes only host-validated control"; else cat "$TMP/$runtime.out" >&2; bad "$runtime conductor control publication"; fi
  issue=$((issue + 1))
done
cat > "$BIN/claude-ndjson" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then echo 9.9; exit 0; fi
if [ "$1" = "--help" ] || [ "$2" = "--help" ]; then echo 'exec --sandbox --cd --model --config --output-last-message --json --print --permission-mode --output-format --effort --include-partial-messages run --dir --format --agent --variant json'; exit 0; fi
printf '%s\n' '{"type":"system","subtype":"init"}'
CLAUDE_NDJSON_PROPOSAL_PATH="$CONTROL_PROPOSAL" CLAUDE_NDJSON_FENCE="${CLAUDE_NDJSON_FENCE:-0}" node <<'NODE'
const fs=require("fs");
const proposal=fs.readFileSync(process.env.CLAUDE_NDJSON_PROPOSAL_PATH,"utf8");
const body = process.env.CLAUDE_NDJSON_FENCE === "1" ? "here is the proposal\n\n```json\n"+proposal+"\n```\n" : proposal;
process.stdout.write(JSON.stringify({type:"result",subtype:"success",is_error:false,result:body})+"\n");
NODE
EOF
chmod +x "$BIN/claude-ndjson"
make_proposal 721 1 '.review/ISSUE-721-ROUND-STATE.json'
CONTROL_PROPOSAL="$TMP/proposal.json" AGENT_WORKFLOW_RUNTIME_BIN="$BIN/claude-ndjson" PATH="$BIN:$PATH" AGENT_WATCHDOG_POLL_INTERVAL=1 bash "$WATCHDOG" --issue 721 --runtime claude --role conductor --mode read --prompt-file "$WT/prompt.txt" --cwd "$WT" --conductor-control --max-retries 0 >"$TMP/721.out" 2>&1
if [ $? -eq 0 ] && node -e 'if(require(process.argv[1]).producer_role!=="CONDUCTOR")process.exit(1)' "$WT/.review/ISSUE-721-ROUND-STATE.json"; then ok 'AC-142-A2b2-4 claude stream-json NDJSON conductor proposal publishes host-validated control'; else cat "$TMP/721.out" >&2; bad 'AC-142-A2b2-4 claude stream-json NDJSON conductor proposal publishes host-validated control'; fi
make_proposal 722 1 '.review/ISSUE-722-ROUND-STATE.json'
CONTROL_PROPOSAL="$TMP/proposal.json" CLAUDE_NDJSON_FENCE=1 AGENT_WORKFLOW_RUNTIME_BIN="$BIN/claude-ndjson" PATH="$BIN:$PATH" AGENT_WATCHDOG_POLL_INTERVAL=1 bash "$WATCHDOG" --issue 722 --runtime claude --role conductor --mode read --prompt-file "$WT/prompt.txt" --cwd "$WT" --conductor-control --max-retries 0 >"$TMP/722.out" 2>&1
if [ $? -eq 0 ] && node -e 'if(require(process.argv[1]).producer_role!=="CONDUCTOR")process.exit(1)' "$WT/.review/ISSUE-722-ROUND-STATE.json"; then ok 'AC-142-A2b2-5 claude stream-json NDJSON conductor proposal with fenced-json body publishes host-validated control'; else cat "$TMP/722.out" >&2; bad 'AC-142-A2b2-5 claude stream-json NDJSON conductor proposal with fenced-json body publishes host-validated control'; fi
issue=705; make_proposal "$issue" 1 ".review/ISSUE-$issue-ROUND-STATE.json"
CONTROL_PROPOSAL="$TMP/proposal.json" PATH="$BIN:$PATH" AGENT_WATCHDOG_POLL_INTERVAL=1 bash "$WATCHDOG" --issue "$issue" --runtime codex --role conductor --mode read --prompt-file "$WT/prompt.txt" --cwd "$WT" --conductor-control --max-retries 0 >/dev/null 2>&1
make_proposal "$issue" 2 ".review/ISSUE-$issue-ROUND-STATE.json"
CONTROL_PROPOSAL="$TMP/proposal.json" PATH="$BIN:$PATH" AGENT_WATCHDOG_POLL_INTERVAL=1 bash "$WATCHDOG" --issue "$issue" --runtime codex --role conductor --mode read --prompt-file "$WT/prompt.txt" --cwd "$WT" --conductor-control --max-retries 0 >/dev/null 2>&1
if [ $? -eq 0 ] && node -e 'if(require(process.argv[1]).revision!==2)process.exit(1)' "$WT/.review/ISSUE-$issue-ROUND-STATE.json"; then ok 'restart publishes only an advanced revision'; else bad 'restart revision advancement'; fi
make_proposal "$issue" 2 ".review/ISSUE-$issue-ROUND-STATE.json"
CONTROL_PROPOSAL="$TMP/proposal.json" PATH="$BIN:$PATH" AGENT_WATCHDOG_POLL_INTERVAL=1 bash "$WATCHDOG" --issue "$issue" --runtime codex --role conductor --mode read --prompt-file "$WT/prompt.txt" --cwd "$WT" --conductor-control --max-retries 0 >/dev/null 2>&1
if [ $? -ne 0 ] && node -e 'if(require(process.argv[1]).revision!==2)process.exit(1)' "$WT/.review/ISSUE-$issue-ROUND-STATE.json"; then ok 'same revision is rejected without replacement'; else bad 'same revision rejection'; fi
make_proposal 709 1 '.review/ISSUE-709-ROUND-STATE.json'
node - "$TMP/proposal.json" <<'NODE'
const fs=require('fs'), f=process.argv[2], p=JSON.parse(fs.readFileSync(f,'utf8')); p.actions[0].content.base_branch='missing-base-ref'; fs.writeFileSync(f,JSON.stringify(p));
NODE
bash "$SCRIPT_DIR/../conductor-control-publish.sh" --issue 709 --cwd "$WT" --proposal "$TMP/proposal.json" >/dev/null 2>&1
if [ $? -ne 0 ] && [ ! -e "$WT/.review/ISSUE-709-ROUND-STATE.json" ]; then ok 'non-live base branch is rejected'; else bad 'live merge-base binding'; fi
make_proposal 7090 1 '.review/ISSUE-7090-ROUND-STATE.json'
OTHER_BASE="$(printf 'unrelated\n' | git -C "$WT" -c user.name=smoke -c user.email=smoke@example.test commit-tree "$(git -C "$WT" rev-parse 'HEAD^{tree}')")"
CONTROL_OTHER_BASE="$OTHER_BASE" node - "$TMP/proposal.json" <<'NODE'
const fs=require('fs'), f=process.argv[2], p=JSON.parse(fs.readFileSync(f,'utf8')); p.actions[0].content.base_sha=process.env.CONTROL_OTHER_BASE; fs.writeFileSync(f,JSON.stringify(p));
NODE
bash "$SCRIPT_DIR/../conductor-control-publish.sh" --issue 7090 --cwd "$WT" --proposal "$TMP/proposal.json" >/dev/null 2>&1
if [ $? -ne 0 ] && [ ! -e "$WT/.review/ISSUE-7090-ROUND-STATE.json" ]; then ok 'existing non-merge-base commit is rejected'; else bad 'exact live merge-base binding'; fi
make_proposal 706 1 'README.md'
CONTROL_PROPOSAL="$TMP/proposal.json" PATH="$BIN:$PATH" AGENT_WATCHDOG_POLL_INTERVAL=1 bash "$WATCHDOG" --issue 706 --runtime claude --role conductor --mode read --prompt-file "$WT/prompt.txt" --cwd "$WT" --conductor-control --max-retries 0 >/dev/null 2>&1
if [ $? -ne 0 ] && [ ! -e "$WT/README.md" ]; then ok 'source path proposal is denied'; else bad 'source path denial'; fi
PATH="$BIN:$PATH" bash "$WATCHDOG" --issue 707 --runtime opencode --role conductor --mode write --prompt-file "$WT/prompt.txt" --cwd "$WT" --opencode-permission-file "$TMP/read.json" --conductor-control --max-retries 0 >/dev/null 2>&1
if [ $? -ne 0 ]; then ok 'control mode cannot grant conductor write mode'; else bad 'conductor write denial'; fi
ESCAPE_WT="$TMP/escape-wt"; ESCAPE_OUT="$TMP/escape-out"; mkdir -p "$ESCAPE_WT" "$ESCAPE_OUT"; git -C "$ESCAPE_WT" init -q; ln -s "$ESCAPE_OUT" "$ESCAPE_WT/.review"
printf '{}\n' > "$TMP/escape-proposal.json"
bash "$SCRIPT_DIR/../conductor-control-publish.sh" --issue 708 --cwd "$ESCAPE_WT" --proposal "$TMP/escape-proposal.json" > /dev/null 2>"$TMP/escape.err"
if [ $? -ne 0 ] && grep -q 'conductor_control_review_dir_symlink' "$TMP/escape.err" && [ -z "$(find "$ESCAPE_OUT" -mindepth 1 -print -quit)" ]; then ok 'symlinked review directory cannot escape control publication'; else bad 'review directory escape denial'; fi
[ "$FAIL" -eq 0 ] && { echo 'ALL CASES PASS'; exit 0; }; exit 1
