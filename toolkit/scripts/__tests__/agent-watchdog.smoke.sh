#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; WATCHDOG="$SCRIPT_DIR/../agent-watchdog.sh"; TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT; FAIL=0
ok(){ echo "ok   - $1"; }; bad(){ echo "NOT OK - $1"; FAIL=$((FAIL + 1)); }
BIN="$TMP/bin"; WT="$TMP/wt"; mkdir -p "$BIN" "$WT"; printf 'p\n' > "$WT/prompt.txt"; git -C "$WT" init -q; git -C "$WT" config user.email t@t; git -C "$WT" config user.name t; git -C "$WT" add prompt.txt; git -C "$WT" commit -qm seed; HEAD="$(git -C "$WT" rev-parse HEAD)"
. "$SCRIPT_DIR/lib/stub-argv.sh"; make_stub_capture_helper "$TMP/stub-capture.sh"; STUB_CAPTURE_HELPER="$TMP/stub-capture.sh"; export STUB_CAPTURE_HELPER
cat > "$BIN/opencode" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then echo 9.9; exit 0; fi
if [ "$1" = "--help" ] || { [ "$1" = run ] && [ "$2" = "--help" ]; }; then echo 'run --dir --format --agent --model --variant json'; exit 0; fi
if [ "$OPENCODE_STUB_MODE" = fail ]; then exit 9; fi
if [ "$OPENCODE_STUB_MODE" = authfail ]; then echo 'authentication failed: invalid api key' >&2; exit 9; fi
if [ "$OPENCODE_STUB_MODE" = transient ]; then
  n=0; [ -f "$OPENCODE_STUB_COUNT" ] && n="$(cat "$OPENCODE_STUB_COUNT")"; n=$((n + 1)); printf '%s\n' "$n" > "$OPENCODE_STUB_COUNT"
  [ "$n" -eq 1 ] && { echo 'temporary upstream failure' >&2; exit 9; }
fi
if [ "$OPENCODE_STUB_MODE" = heartbeat ]; then
  worktree=""
  while [ "$#" -gt 0 ]; do
    if [ "$1" = --dir ]; then worktree="$2"; break; fi
    shift
  done
  while :; do touch "$worktree/hb" 2>/dev/null; sleep 1; done
fi
if [ -n "${OPENCODE_STUB_PR_DRAFT:-}" ]; then
  worktree=""
  while [ "$#" -gt 0 ]; do
    if [ "$1" = --dir ]; then worktree="$2"; break; fi
    shift
  done
  mkdir -p "$worktree/.review"
  printf '%s\n' "$OPENCODE_STUB_PR_DRAFT" > "$worktree/.review/ISSUE-${OPENCODE_STUB_ISSUE}-PR-DRAFT.json"
fi
if [ -n "${OPENCODE_STUB_CAPTURE_PROMPT:-}" ]; then
  last=""
  for a in "$@"; do last="$a"; done
  printf '%s' "$last" > "$OPENCODE_STUB_CAPTURE_PROMPT"
fi
printf '%s\n' "$OPENCODE_STUB_OUTPUT"
EOF
chmod +x "$BIN/opencode"
cat > "$BIN/claude" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then echo 9.9; exit 0; fi
if [ "$1" = "--help" ]; then echo '--print --permission-mode --output-format --model --effort --include-partial-messages'; exit 0; fi
# Real stream-json-shaped NDJSON output: partial content_block_delta events
# (proving incremental progress) then a terminal type=result/subtype=success
# event whose result field carries the canonical text, exactly like claude's
# --output-format stream-json --verbose --include-partial-messages contract.
printf '%s\n' '{"type":"system","subtype":"init"}'
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"thinking"}]}}'
printf '%s\n' "$CLAUDE_STUB_RESULT_EVENT"
exit 0
EOF
chmod +x "$BIN/claude"
cat > "$BIN/codex" <<'EOF'
#!/usr/bin/env bash
. "$STUB_CAPTURE_HELPER"
if [ "$1" = "--version" ]; then echo 9.9; exit 0; fi
if [ "$1" = "--help" ]; then echo exec; exit 0; fi
if [ "$1" = exec ] && [ "$2" = "--help" ]; then echo 'exec --sandbox --cd --model --config --output-last-message --json'; exit 0; fi
if [ "$1" = exec ]; then printf '%s\n' "${CODEX_STUB_OUTPUT:-ok}"; exit 0; fi
exit 2
EOF
cat > "$BIN/probe" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$BIN/codex" "$BIN/probe"
cat > "$BIN/codex-ndjson" <<'EOF'
#!/usr/bin/env bash
. "$STUB_CAPTURE_HELPER"
if [ "$1" = "--version" ]; then echo 9.9; exit 0; fi
if [ "$1" = "--help" ]; then echo 'exec --sandbox --cd --model --config --output-last-message --json'; exit 0; fi
if [ "$1" = exec ] && [ "$2" = "--help" ]; then echo 'exec --sandbox --cd --model --config --output-last-message --json'; exit 0; fi
[ "$1" = exec ] || exit 2
last_message=""
previous=""
for arg in "$@"; do
  if [ "$previous" = --output-last-message ]; then last_message="$arg"; fi
  previous="$arg"
done
if [ -n "$last_message" ]; then printf '%s\n' "${CODEX_NDJSON_REVIEW_BODY:-}" > "$last_message"; fi
CODEX_NDJSON_REVIEW_BODY="${CODEX_NDJSON_REVIEW_BODY:-ok}" node <<'NODE'
const body=process.env.CODEX_NDJSON_REVIEW_BODY;
const command=(id,command)=>({id,type:"command_execution",command,aggregated_output:"",exit_code:0});
const events=[
  {type:"thread.started",thread_id:"thread_test"},
  {type:"turn.started",turn_id:"turn_test"},
  {type:"item.started",item:command("cmd_1","pwd")},
  {type:"item.completed",item:command("cmd_1","pwd")},
  {type:"item.started",item:command("cmd_2","git status --short")},
  {type:"item.completed",item:command("cmd_2","git status --short")},
  {type:"item.started",item:command("cmd_3","git log -1")},
  {type:"item.completed",item:command("cmd_3","git log -1")},
  {type:"item.completed",item:{id:"message_1",type:"agent_message",text:body}},
  {type:"turn.completed",turn_id:"turn_test"},
];
process.stdout.write(events.map(JSON.stringify).join("\n")+"\n");
NODE
EOF
chmod +x "$BIN/codex-ndjson"
cp "$SCRIPT_DIR/../runtimes/opencode-read.json" "$TMP/read.json"
review="{\"schema_version\":\"1\",\"artifact_type\":\"review\",\"lifecycle\":\"final\",\"producer_role\":\"REVIEWER\",\"issue\":{\"number\":77},\"reviewed_head_sha\":\"$HEAD\",\"status\":\"pass\",\"checklist\":[{\"item\":\"ok\",\"met\":true}]}"
wrapped_review="$(printf 'reviewer summary\n\n```json\n%s\n```\n\n```json\nnot valid JSON\n```\n' "$review")"
OPENCODE_STUB_OUTPUT="$wrapped_review" AGENT_WATCHDOG_POLL_INTERVAL=1 PATH="$BIN:$PATH" bash "$WATCHDOG" --issue 77 --runtime opencode --role reviewer --mode read --prompt-file "$WT/prompt.txt" --cwd "$WT" --opencode-permission-file "$TMP/read.json" --produce-review --first-progress-timeout 5 --stall-timeout 5 >/dev/null 2>&1
if [ $? -eq 0 ] && node -e 'const o=require(process.argv[1]); if(o.artifact_type!=="agent_run"||o.runtime!=="opencode"||o.role!=="reviewer"||!o.runtime_version||o.status!=="exited")process.exit(1)' "$WT/.review/ISSUE-77-RUN.json" && [ -f "$WT/.review/ISSUE-77-REVIEW.json" ]; then ok 'prose-wrapped non-Codex reviewer JSON publishes validated review'; else bad 'prose-wrapped reviewer publication'; fi
# #163: write_marker must also append a run_status line per call to the
# append-only EVENTS.jsonl log alongside (never instead of) RUN.json.
if node -e 'const fs=require("fs");const lines=fs.readFileSync(process.argv[1],"utf8").trim().split("\n").map(JSON.parse);const last=lines[lines.length-1];if(lines.length<2||last.event!=="run_status"||last.status!=="exited"||last.attempt!==1||typeof last.ts!=="string"||!("detail" in last))process.exit(1)' "$WT/.review/ISSUE-77-EVENTS.jsonl" && node -e 'const o=require(process.argv[1]); if(o.status!=="exited")process.exit(1)' "$WT/.review/ISSUE-77-RUN.json"; then ok '#163 write_marker appends terminal run_status line to EVENTS.jsonl'; else bad '#163 EVENTS.jsonl run_status append'; fi
# #137 regression: bash-denied reviewer receives the host-pinned HEAD in the
# launch prompt (a), and a wrong model-returned reviewed_head_sha is corrected
# to the host's launch-time value before schema validation (b).
CAPTURED_PROMPT="$TMP/captured-prompt.txt"
review_137="{\"schema_version\":\"1\",\"artifact_type\":\"review\",\"lifecycle\":\"final\",\"producer_role\":\"REVIEWER\",\"issue\":{\"number\":137},\"reviewed_head_sha\":\"0000000000000000000000000000000000000000\",\"status\":\"pass\",\"checklist\":[{\"item\":\"head-injection\",\"met\":true}]}"
OPENCODE_STUB_CAPTURE_PROMPT="$CAPTURED_PROMPT" OPENCODE_STUB_OUTPUT="$review_137" AGENT_WATCHDOG_POLL_INTERVAL=1 PATH="$BIN:$PATH" bash "$WATCHDOG" --issue 137 --runtime opencode --role reviewer --mode read --prompt-file "$WT/prompt.txt" --cwd "$WT" --opencode-permission-file "$TMP/read.json" --produce-review --first-progress-timeout 5 --stall-timeout 5 >/dev/null 2>&1
if [ $? -eq 0 ] && grep -q "reviewed_head_sha must be exactly $HEAD" "$CAPTURED_PROMPT" && node -e 'const o=require(process.argv[1]); if(o.reviewed_head_sha!==process.argv[2])process.exit(1)' "$WT/.review/ISSUE-137-REVIEW.json" "$HEAD" && [ -f "$WT/.review/ISSUE-137-REVIEW-$HEAD.json" ]; then ok '#137 bash-deny reviewer gets host-pinned HEAD injected and wrong model value corrected'; else bad '#137 host-pinned HEAD injection/correction'; fi
OPENCODE_STUB_OUTPUT='reviewer prose without JSON' AGENT_WATCHDOG_POLL_INTERVAL=1 PATH="$BIN:$PATH" bash "$WATCHDOG" --issue 81 --runtime opencode --role reviewer --mode read --prompt-file "$WT/prompt.txt" --cwd "$WT" --opencode-permission-file "$TMP/read.json" --produce-review --first-progress-timeout 5 --stall-timeout 5 >/dev/null 2>&1
if [ $? -ne 0 ] && node -e 'const o=require(process.argv[1]); if(o.status!=="refused"||o.refusal_reason!=="unparseable_output")process.exit(1)' "$WT/.review/ISSUE-81-RUN.json" && grep -q 'reviewer prose without JSON' "$WT/.review/ISSUE-81-review-attempt1-output.log"; then ok 'unparseable non-Codex review preserves output diagnostics with typed reason'; else bad 'unparseable reviewer diagnostics'; fi
review_82="{\"schema_version\":\"1\",\"artifact_type\":\"review\",\"lifecycle\":\"final\",\"producer_role\":\"REVIEWER\",\"issue\":{\"number\":82},\"reviewed_head_sha\":\"$HEAD\",\"status\":\"pass\",\"checklist\":[{\"item\":\"publication\",\"met\":true}]}"
printf '%s\n' '{"conflicting":"snapshot"}' > "$WT/.review/ISSUE-82-REVIEW-$HEAD.json"
OPENCODE_STUB_OUTPUT="$review_82" AGENT_WATCHDOG_POLL_INTERVAL=1 PATH="$BIN:$PATH" bash "$WATCHDOG" --issue 82 --runtime opencode --role reviewer --mode read --prompt-file "$WT/prompt.txt" --cwd "$WT" --opencode-permission-file "$TMP/read.json" --produce-review --first-progress-timeout 5 --stall-timeout 5 >/dev/null 2>&1
if [ $? -ne 0 ] && node -e 'const o=require(process.argv[1]); if(o.status!=="refused"||o.refusal_reason!=="publication_failed")process.exit(1)' "$WT/.review/ISSUE-82-RUN.json" && grep -q '"number":82' "$WT/.review/ISSUE-82-review-attempt1-output.log"; then ok 'publication refusal preserves non-Codex output diagnostics'; else bad 'publication refusal diagnostics'; fi
cp "$SCRIPT_DIR/../runtimes/opencode-write.json" "$TMP/write.json"
BRANCH="$(git -C "$WT" rev-parse --abbrev-ref HEAD)"
pr_draft() {
  issue="$1"; worktree="${2:-$WT}"; lifecycle="${3:-active}"; branch="${4:-$BRANCH}"
  printf '{"schema_version":"1","artifact_type":"pr_draft","lifecycle":"%s","producer_role":"CODEX","issue":{"number":%s,"title":"watchdog"},"branch":"%s","base_sha":"%s","head_sha":"%s","files_touched":[{"path":"prompt.txt","change":"edit"}],"verify_cmd":"smoke","status":"needs_amendment","worktree_path":"%s"}' "$lifecycle" "$issue" "$branch" "$HEAD" "$HEAD" "$worktree"
}
OPENCODE_STUB_MODE=authfail AGENT_WATCHDOG_POLL_INTERVAL=1 PATH="$BIN:$PATH" bash "$WATCHDOG" --issue 78 --runtime opencode --role implementation --mode write --prompt-file "$WT/prompt.txt" --cwd "$WT" --opencode-permission-file "$TMP/write.json" --first-progress-timeout 5 --stall-timeout 5 >/dev/null 2>&1
if [ $? -ne 0 ] && node -e 'const o=require(process.argv[1]); if(o.status!=="refused"||o.runtime!=="opencode")process.exit(1)' "$WT/.review/ISSUE-78-RUN.json"; then ok 'runtime failure retains typed refused marker'; else bad 'runtime failure marker'; fi
COUNT="$TMP/transient-count"
OPENCODE_STUB_MODE=transient OPENCODE_STUB_COUNT="$COUNT" OPENCODE_STUB_ISSUE=79 OPENCODE_STUB_PR_DRAFT="$(pr_draft 79)" AGENT_WATCHDOG_PROBE_CMD="$BIN/probe" AGENT_WATCHDOG_PROBE_GAP=0 AGENT_WATCHDOG_POLL_INTERVAL=1 PATH="$BIN:$PATH" bash "$WATCHDOG" --issue 79 --runtime opencode --role implementation --mode write --prompt-file "$WT/prompt.txt" --cwd "$WT" --opencode-permission-file "$TMP/write.json" --first-progress-timeout 5 --stall-timeout 5 --max-retries 1 >/dev/null 2>&1
if [ $? -eq 0 ] && node -e 'const o=require(process.argv[1]); if(o.status!=="exited"||o.attempt!==2||o.runtime!=="opencode")process.exit(1)' "$WT/.review/ISSUE-79-RUN.json" && [ -f "$WT/.review/ISSUE-79-agent-attempt1-stderr.log" ]; then ok 'transient runtime failure retries with canonical attempt increment'; else bad 'transient retry attempt identity'; fi
AGENT_WATCHDOG_POLL_INTERVAL=1 PATH="$BIN:$PATH" bash "$WATCHDOG" --issue 83 --runtime opencode --role implementation --mode write --prompt-file "$WT/prompt.txt" --cwd "$WT" --opencode-permission-file "$TMP/write.json" --first-progress-timeout 5 --stall-timeout 5 --max-retries 0 >/dev/null 2>&1
if [ $? -ne 0 ] && node -e 'const o=require(process.argv[1]); if(o.status!=="refused")process.exit(1)' "$WT/.review/ISSUE-83-RUN.json"; then ok 'implementation exit without fresh PR-DRAFT is refused'; else bad 'implementation exit without fresh PR-DRAFT is refused'; fi
OPENCODE_STUB_ISSUE=84 OPENCODE_STUB_PR_DRAFT="$(pr_draft 84 "$TMP/not-this-worktree")" AGENT_WATCHDOG_POLL_INTERVAL=1 PATH="$BIN:$PATH" bash "$WATCHDOG" --issue 84 --runtime opencode --role implementation --mode write --prompt-file "$WT/prompt.txt" --cwd "$WT" --opencode-permission-file "$TMP/write.json" --first-progress-timeout 5 --stall-timeout 5 --max-retries 0 >/dev/null 2>&1
if [ $? -ne 0 ] && node -e 'const o=require(process.argv[1]); if(o.status!=="refused")process.exit(1)' "$WT/.review/ISSUE-84-RUN.json"; then ok 'implementation PR-DRAFT requires its real worktree binding'; else bad 'implementation PR-DRAFT requires its real worktree binding'; fi
OPENCODE_STUB_ISSUE=85 OPENCODE_STUB_PR_DRAFT="$(pr_draft 85)" AGENT_WATCHDOG_POLL_INTERVAL=1 PATH="$BIN:$PATH" bash "$WATCHDOG" --issue 85 --runtime opencode --role implementation --mode write --prompt-file "$WT/prompt.txt" --cwd "$WT" --opencode-permission-file "$TMP/write.json" --first-progress-timeout 5 --stall-timeout 5 --max-retries 0 >/dev/null 2>&1
if [ $? -eq 0 ] && node -e 'const o=require(process.argv[1]); if(o.status!=="exited")process.exit(1)' "$WT/.review/ISSUE-85-RUN.json"; then ok 'fresh schema-valid PR-DRAFT allows implementation exit'; else bad 'fresh schema-valid PR-DRAFT allows implementation exit'; fi
OPENCODE_STUB_ISSUE=86 OPENCODE_STUB_PR_DRAFT="$(pr_draft 86 "$WT" superseded)" AGENT_WATCHDOG_POLL_INTERVAL=1 PATH="$BIN:$PATH" bash "$WATCHDOG" --issue 86 --runtime opencode --role implementation --mode write --prompt-file "$WT/prompt.txt" --cwd "$WT" --opencode-permission-file "$TMP/write.json" --first-progress-timeout 5 --stall-timeout 5 --max-retries 0 >/dev/null 2>&1
if [ $? -ne 0 ] && node -e 'const o=require(process.argv[1]); if(o.status!=="refused")process.exit(1)' "$WT/.review/ISSUE-86-RUN.json"; then ok 'superseded implementation PR-DRAFT is refused'; else bad 'superseded implementation PR-DRAFT is refused'; fi
OPENCODE_STUB_ISSUE=87 OPENCODE_STUB_PR_DRAFT="$(pr_draft 87 "$WT" active wrong-branch)" AGENT_WATCHDOG_POLL_INTERVAL=1 PATH="$BIN:$PATH" bash "$WATCHDOG" --issue 87 --runtime opencode --role implementation --mode write --prompt-file "$WT/prompt.txt" --cwd "$WT" --opencode-permission-file "$TMP/write.json" --first-progress-timeout 5 --stall-timeout 5 --max-retries 0 >/dev/null 2>&1
if [ $? -ne 0 ] && node -e 'const o=require(process.argv[1]); if(o.status!=="refused")process.exit(1)' "$WT/.review/ISSUE-87-RUN.json"; then ok 'implementation PR-DRAFT requires live branch binding'; else bad 'implementation PR-DRAFT requires live branch binding'; fi
AGENT_WATCHDOG_POLL_INTERVAL=1 PATH="$BIN:$PATH" bash "$WATCHDOG" --issue 80 --runtime codex --role reviewer --mode read --prompt-file "$WT/prompt.txt" --cwd "$WT" --first-progress-timeout 5 --stall-timeout 5 >/dev/null 2>&1
if [ $? -eq 0 ] && node -e 'const o=require(process.argv[1]); if(o.status!=="exited"||o.attempt!==1||o.runtime!=="codex"||o.role!=="reviewer")process.exit(1)' "$WT/.review/ISSUE-80-RUN.json"; then ok 'codex read runtime remains compatible with typed watchdog'; else bad 'codex runtime compatibility'; fi
review_89="{\"schema_version\":\"1\",\"artifact_type\":\"review\",\"lifecycle\":\"final\",\"producer_role\":\"REVIEWER\",\"issue\":{\"number\":89},\"reviewed_head_sha\":\"$HEAD\",\"status\":\"pass\",\"checklist\":[{\"item\":\"claude-stream-json\",\"met\":true}]}"
result_event_89="$(node -e 'process.stdout.write(JSON.stringify({type:"result",subtype:"success",is_error:false,result:process.argv[1]}))' "$review_89")"
CLAUDE_STUB_RESULT_EVENT="$result_event_89" AGENT_WATCHDOG_POLL_INTERVAL=1 PATH="$BIN:$PATH" bash "$WATCHDOG" --issue 89 --runtime claude --role reviewer --mode read --prompt-file "$WT/prompt.txt" --cwd "$WT" --produce-review --first-progress-timeout 5 --stall-timeout 5 >/dev/null 2>&1
if [ $? -eq 0 ] && node -e 'const o=require(process.argv[1]); if(o.artifact_type!=="agent_run"||o.runtime!=="claude"||o.role!=="reviewer"||o.status!=="exited")process.exit(1)' "$WT/.review/ISSUE-89-RUN.json" && [ -f "$WT/.review/ISSUE-89-REVIEW.json" ]; then ok 'AC-142-A2b2-1 claude stream-json NDJSON result event publishes validated review'; else bad 'AC-142-A2b2-1 claude stream-json NDJSON result event publishes validated review'; fi
review_90="{\"schema_version\":\"1\",\"artifact_type\":\"review\",\"lifecycle\":\"final\",\"producer_role\":\"REVIEWER\",\"issue\":{\"number\":90},\"reviewed_head_sha\":\"$HEAD\",\"status\":\"pass\",\"checklist\":[{\"item\":\"claude-fenced\",\"met\":true}]}"
wrapped_90="$(printf 'reviewer summary\n\n```json\n%s\n```\n' "$review_90")"
result_event_90="$(node -e 'process.stdout.write(JSON.stringify({type:"result",subtype:"success",is_error:false,result:process.argv[1]}))' "$wrapped_90")"
CLAUDE_STUB_RESULT_EVENT="$result_event_90" AGENT_WATCHDOG_POLL_INTERVAL=1 PATH="$BIN:$PATH" bash "$WATCHDOG" --issue 90 --runtime claude --role reviewer --mode read --prompt-file "$WT/prompt.txt" --cwd "$WT" --produce-review --first-progress-timeout 5 --stall-timeout 5 >/dev/null 2>&1
if [ $? -eq 0 ] && [ -f "$WT/.review/ISSUE-90-REVIEW.json" ]; then ok 'AC-142-A2b2-2 claude stream-json result event with fenced-json body publishes validated review'; else bad 'AC-142-A2b2-2 claude stream-json result event with fenced-json body publishes validated review'; fi
# #155: opencode now launches with --format json (PROGRESS.opencode.streams
# is true), so transcribe_review walks its NDJSON stream. The stream shape is
# the real 12-event sequence from the issue-155 reproduction evidence:
# step_start/tool_use/step_finish x3, then step_start/text/step_finish, with
# the terminal {"type":"text"} event carrying the payload in part.text.
opencode_stream() {
  OPENCODE_TEXT_BODY="$1" node <<'NODE'
const body=process.env.OPENCODE_TEXT_BODY;
const step=t=>JSON.stringify({type:t,sessionID:"ses_test",part:{type:t==="step_start"?"step-start":"step-finish"}});
const out=[];
for (const file of ["runtime-registry.cjs","opencode-read.json","STATUS.md"]) {
  out.push(step("step_start"));
  out.push(JSON.stringify({type:"tool_use",sessionID:"ses_test",part:{type:"tool",tool:"read",state:{status:"completed",input:{filePath:"/wt/"+file}}}}));
  out.push(step("step_finish"));
}
out.push(step("step_start"));
out.push(JSON.stringify({type:"text",sessionID:"ses_test",part:{type:"text",text:body}}));
out.push(step("step_finish"));
process.stdout.write(out.join("\n")+"\n");
NODE
}
review_92="{\"schema_version\":\"1\",\"artifact_type\":\"review\",\"lifecycle\":\"final\",\"producer_role\":\"REVIEWER\",\"issue\":{\"number\":92},\"reviewed_head_sha\":\"$HEAD\",\"status\":\"pass\",\"checklist\":[{\"item\":\"opencode-stream-json\",\"met\":true}]}"
OPENCODE_STUB_OUTPUT="$(opencode_stream "$review_92")" AGENT_WATCHDOG_POLL_INTERVAL=1 PATH="$BIN:$PATH" bash "$WATCHDOG" --issue 92 --runtime opencode --role reviewer --mode read --prompt-file "$WT/prompt.txt" --cwd "$WT" --opencode-permission-file "$TMP/read.json" --produce-review --first-progress-timeout 5 --stall-timeout 5 >/dev/null 2>&1
if [ $? -eq 0 ] && node -e 'const o=require(process.argv[1]); if(o.artifact_type!=="agent_run"||o.runtime!=="opencode"||o.role!=="reviewer"||o.status!=="exited")process.exit(1)' "$WT/.review/ISSUE-92-RUN.json" && [ -f "$WT/.review/ISSUE-92-REVIEW.json" ]; then ok '#155 opencode NDJSON terminal text event publishes validated review'; else bad '#155 opencode NDJSON terminal text event publishes validated review'; fi
review_93="{\"schema_version\":\"1\",\"artifact_type\":\"review\",\"lifecycle\":\"final\",\"producer_role\":\"REVIEWER\",\"issue\":{\"number\":93},\"reviewed_head_sha\":\"$HEAD\",\"status\":\"pass\",\"checklist\":[{\"item\":\"opencode-fenced\",\"met\":true}]}"
wrapped_93="$(printf 'reviewer summary\n\n```json\n%s\n```\n' "$review_93")"
OPENCODE_STUB_OUTPUT="$(opencode_stream "$wrapped_93")" AGENT_WATCHDOG_POLL_INTERVAL=1 PATH="$BIN:$PATH" bash "$WATCHDOG" --issue 93 --runtime opencode --role reviewer --mode read --prompt-file "$WT/prompt.txt" --cwd "$WT" --opencode-permission-file "$TMP/read.json" --produce-review --first-progress-timeout 5 --stall-timeout 5 >/dev/null 2>&1
if [ $? -eq 0 ] && [ -f "$WT/.review/ISSUE-93-REVIEW.json" ]; then ok '#155 opencode NDJSON terminal text event with fenced-json body publishes validated review'; else bad '#155 opencode NDJSON terminal text event with fenced-json body publishes validated review'; fi
# #155: Codex review owns canonical output in --output-last-message while its
# stdout carries the real multi-event JSONL stream. The safe wrapper and the
# outer watchdog must preserve both the exact canonical review and snapshot.
review_94="{\"schema_version\":\"1\",\"artifact_type\":\"review\",\"lifecycle\":\"final\",\"producer_role\":\"REVIEWER\",\"issue\":{\"number\":94},\"reviewed_head_sha\":\"$HEAD\",\"status\":\"pass\",\"checklist\":[{\"item\":\"codex-ndjson\",\"met\":true}]}"
CODEX_NDJSON_REVIEW_BODY="$review_94" AGENT_WORKFLOW_RUNTIME_BIN="$BIN/codex-ndjson" AGENT_WATCHDOG_POLL_INTERVAL=1 PATH="$BIN:$PATH" bash "$WATCHDOG" --issue 94 --runtime codex --role reviewer --mode read --prompt-file "$WT/prompt.txt" --cwd "$WT" --produce-review --model gpt-5.6-sol --effort medium --first-progress-timeout 5 --stall-timeout 5 >/dev/null 2>&1
if [ $? -eq 0 ] && node -e 'const o=require(process.argv[1]); if(o.status!=="exited"||o.runtime!=="codex"||o.role!=="reviewer")process.exit(1)' "$WT/.review/ISSUE-94-RUN.json" && [ -f "$WT/.review/ISSUE-94-REVIEW.json" ] && [ -f "$WT/.review/ISSUE-94-REVIEW-$HEAD.json" ] && cmp -s "$WT/.review/ISSUE-94-REVIEW.json" "$WT/.review/ISSUE-94-REVIEW-$HEAD.json"; then ok 'AC-142-A2b2-1 codex NDJSON reviewer publishes canonical and immutable exact review'; else bad 'AC-142-A2b2-1 codex NDJSON reviewer publication'; fi
review_95="{\"schema_version\":\"1\",\"artifact_type\":\"review\",\"lifecycle\":\"final\",\"producer_role\":\"REVIEWER\",\"issue\":{\"number\":95},\"reviewed_head_sha\":\"$HEAD\",\"status\":\"pass\",\"checklist\":[{\"item\":\"codex-fenced\",\"met\":true}]}"
wrapped_95="$(printf 'reviewer summary\n\n```json\n%s\n```\n' "$review_95")"
CODEX_NDJSON_REVIEW_BODY="$wrapped_95" AGENT_WORKFLOW_RUNTIME_BIN="$BIN/codex-ndjson" AGENT_WATCHDOG_POLL_INTERVAL=1 PATH="$BIN:$PATH" bash "$WATCHDOG" --issue 95 --runtime codex --role reviewer --mode read --prompt-file "$WT/prompt.txt" --cwd "$WT" --produce-review --model gpt-5.6-sol --effort medium --first-progress-timeout 5 --stall-timeout 5 >/dev/null 2>&1
if [ $? -ne 0 ] && node -e 'const o=require(process.argv[1]); if(o.status!=="refused")process.exit(1)' "$WT/.review/ISSUE-95-RUN.json" && [ ! -e "$WT/.review/ISSUE-95-REVIEW.json" ] && [ ! -e "$WT/.review/ISSUE-95-REVIEW-$HEAD.json" ]; then ok 'AC-142-A2b2-2 codex fenced NDJSON reviewer refuses non-exact canonical output'; else bad 'AC-142-A2b2-2 codex fenced NDJSON reviewer refusal'; fi
# Truncated OpenCode JSONL must fail closed even though its process exits 0;
# the registered streams=true bit cannot turn an incomplete stream into proof.
if node -e 'const p=require("./toolkit/scripts/lib/runtime-registry.cjs").PROGRESS; if(!p.opencode||p.opencode.streams!==true)process.exit(1)' >/dev/null 2>&1; then
  opencode_streams_true=1
else
  opencode_streams_true=0
fi
opencode_stream_truncated() {
  node <<'NODE'
const step=t=>JSON.stringify({type:t,sessionID:"ses_truncated",part:{type:t==="step_start"?"step-start":"step-finish"}});
const out=[];
for (const file of ["runtime-registry.cjs","opencode-read.json","STATUS.md"]) {
  out.push(step("step_start"));
  out.push(JSON.stringify({type:"tool_use",sessionID:"ses_truncated",part:{type:"tool",tool:"read",state:{status:"completed",input:{filePath:"/wt/"+file}}}}));
  out.push(step("step_finish"));
}
process.stdout.write(out.join("\n")+"\n");
NODE
}
OPENCODE_STUB_OUTPUT="$(opencode_stream_truncated)" AGENT_WATCHDOG_POLL_INTERVAL=1 PATH="$BIN:$PATH" bash "$WATCHDOG" --issue 96 --runtime opencode --role reviewer --mode read --prompt-file "$WT/prompt.txt" --cwd "$WT" --opencode-permission-file "$TMP/read.json" --produce-review --first-progress-timeout 5 --stall-timeout 5 >/dev/null 2>&1
opencode_truncated_ec=$?
if [ "$opencode_streams_true" -eq 1 ] && [ "$opencode_truncated_ec" -ne 0 ] && node -e 'const o=require(process.argv[1]); if(o.status!=="refused"||o.refusal_reason!=="unparseable_output")process.exit(1)' "$WT/.review/ISSUE-96-RUN.json" && [ ! -e "$WT/.review/ISSUE-96-REVIEW.json" ]; then ok '#155 truncated OpenCode NDJSON exits fail-closed without terminal text'; else bad '#155 truncated OpenCode NDJSON fail-closed reviewer contract'; fi
wallclock_start="$(date +%s)"
OPENCODE_STUB_MODE=heartbeat AGENT_WATCHDOG_MAX_WALLCLOCK=2 AGENT_WATCHDOG_POLL_INTERVAL=1 PATH="$BIN:$PATH" timeout 20 bash "$WATCHDOG" --issue 88 --runtime opencode --role reviewer --mode read --prompt-file "$WT/prompt.txt" --cwd "$WT" --opencode-permission-file "$TMP/read.json" --first-progress-timeout 5 --stall-timeout 5 --max-retries 0 >/dev/null 2>&1
wallclock_ec=$?; wallclock_elapsed=$(( $(date +%s) - wallclock_start )); rm -f "$WT/hb"
if [ "$wallclock_ec" -eq 6 ] && [ "$wallclock_elapsed" -le 10 ] && node -e 'const o=require(process.argv[1]); if(o.attempt!==1||o.status!=="exhausted")process.exit(1)' "$WT/.review/ISSUE-88-RUN.json" 2>/dev/null; then ok 'AC-142-A2a-3 wall-clock cap kills a continuously progressing runtime that never stalls'; else bad 'AC-142-A2a-3 wall-clock cap kills a continuously progressing runtime that never stalls'; fi
eval "$(grep -E '^progressed\(\) ' "$WATCHDOG")"
progressed_tmp="$TMP/progressed"; mkdir -p "$progressed_tmp/wt/.review"; CWD="$progressed_tmp/wt"; STAMP="$progressed_tmp/stamp"; OUTPUT="$progressed_tmp/out"
touch "$STAMP"; sleep 1; touch "$OUTPUT"
if progressed; then ok 'AC-142-A2a-4 progressed() treats OUTPUT newer than STAMP as progress even with .review pruned'; else bad 'AC-142-A2a-4 progressed() treats OUTPUT newer than STAMP as progress even with .review pruned'; fi
# #164 stub argv capture contract: the codex read seat must launch with the
# read-only sandbox, the manual model tuple, and the effort config token as
# adjacent argv pairs. The mutation check proves the same pair greps reject a
# reverted sandbox and a wrong-model mutation.
: > "$TMP/codex-model.args"
AGENT_WATCHDOG_POLL_INTERVAL=1 STUB_ARGS_LOG="$TMP/codex-model.args" PATH="$BIN:$PATH" bash "$WATCHDOG" --issue 91 --runtime codex --role reviewer --mode read --prompt-file "$WT/prompt.txt" --cwd "$WT" --model gpt-5.6-terra --effort low --first-progress-timeout 5 --stall-timeout 5 >/dev/null 2>&1
codex_args="$(tail -n 1 "$TMP/codex-model.args")"
if [ "$(printf '%s\n' "$codex_args" | grep -c -- '--sandbox read-only')" -eq 1 ] && printf '%s\n' "$codex_args" | grep -q -- '-m gpt-5.6-terra' && printf '%s\n' "$codex_args" | grep -q -- 'model_reasoning_effort=' && printf '%s\n' "$codex_args" | grep -q -- 'model_reasoning_effort="low"'; then ok '#164 codex watchdog seat forwards read-only sandbox and model/effort pairs'; else bad '#164 codex watchdog argv pair capture (got: '"$codex_args"')'; fi
codex_mutation_reverted='exec --sandbox workspace-write --cd /wt -m gpt-5.6-terra -c model_reasoning_effort="low"'
codex_mutation_model='exec --sandbox read-only --cd /wt -m wrong-model -c model_reasoning_effort="low"'
if ! printf '%s\n' "$codex_mutation_reverted" | grep -q -- '--sandbox read-only' && ! printf '%s\n' "$codex_mutation_model" | grep -q -- '-m gpt-5.6-terra'; then ok '#164 codex argv mutation check rejects reverted sandbox and wrong model'; else bad '#164 codex argv mutation check accepted a mutated argv'; fi
[ "$FAIL" -eq 0 ] && { echo 'ALL CASES PASS'; exit 0; }; exit 1
