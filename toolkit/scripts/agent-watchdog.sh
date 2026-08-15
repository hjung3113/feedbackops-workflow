#!/usr/bin/env bash
# Runtime-neutral watchdog.
# RUN records process liveness only; it never completes a workflow.
# bash-3.2 compatible.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_EXEC="$SCRIPT_DIR/agent-runtime.sh"
CONTROL_PUBLISHER="$SCRIPT_DIR/conductor-control-publish.sh"
ISSUE_N=""; RUNTIME=""; ROLE=""; MODE=""; PROMPT_FILE=""; CWD=""; MODEL=""; EFFORT=""; PERMISSION_FILE=""; PRODUCE_REVIEW=0; CONDUCTOR_CONTROL=0
FIRST_PROGRESS_TIMEOUT="${AGENT_WATCHDOG_FIRST_PROGRESS_TIMEOUT:-240}"; STALL_TIMEOUT="${AGENT_WATCHDOG_STALL_TIMEOUT:-180}"; MAX_RETRIES="${AGENT_WATCHDOG_MAX_RETRIES:-2}"; POLL_INTERVAL="${AGENT_WATCHDOG_POLL_INTERVAL:-15}"; PROBE_GAP="${AGENT_WATCHDOG_PROBE_GAP:-10}"
usage() { echo "usage: agent-watchdog.sh --issue N --runtime codex|claude|opencode --role conductor|architect|implementation|reviewer|verifier|visual|release --mode read|write --prompt-file F --cwd DIR [--model M] [--effort E] [--opencode-permission-file F] [--produce-review|--conductor-control] [--max-retries N]" >&2; }
iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
write_marker() {
  status="$1"; attempt="$2"; pid="$3"; exit_code="$4"; refusal_reason="${5:-}"; marker="$CWD/.review/ISSUE-${ISSUE_N}-RUN.json"
  mkdir -p "$CWD/.review" || return 1
  AGENT_MARKER="$marker" AGENT_ISSUE="$ISSUE_N" AGENT_ATTEMPT="$attempt" AGENT_RUNTIME="$RUNTIME" AGENT_ROLE="$ROLE" AGENT_VERSION="$RUNTIME_VERSION" AGENT_STATUS="$status" AGENT_PID="$pid" AGENT_EXIT="$exit_code" AGENT_REFUSAL_REASON="$refusal_reason" AGENT_TIME="$(iso_now)" node -e '
const fs=require("fs"); const o={schema_version:"1",artifact_type:"agent_run",issue:Number(process.env.AGENT_ISSUE),attempt:Number(process.env.AGENT_ATTEMPT),runtime:process.env.AGENT_RUNTIME,role:process.env.AGENT_ROLE,runtime_version:process.env.AGENT_VERSION,started_at:process.env.AGENT_TIME,updated_at:process.env.AGENT_TIME,status:process.env.AGENT_STATUS}; if(process.env.AGENT_PID)o.pid=Number(process.env.AGENT_PID); if(process.env.AGENT_EXIT)o.exit_code=Number(process.env.AGENT_EXIT); if(process.env.AGENT_REFUSAL_REASON)o.refusal_reason=process.env.AGENT_REFUSAL_REASON; fs.writeFileSync(process.env.AGENT_MARKER,JSON.stringify(o,null,2)+"\n");'
}
progressed() { find "$CWD" -path '*/node_modules' -prune -o -path '*/.git' -prune -o -path '*/.review' -prune -o -newer "$STAMP" -print -quit | grep -q .; }
kill_tree() { pkill -TERM -P "$1" 2>/dev/null || true; kill -TERM "$1" 2>/dev/null || true; sleep 1; pkill -KILL -P "$1" 2>/dev/null || true; kill -KILL "$1" 2>/dev/null || true; }
validate_review() {
  node - "$1" "$SCRIPT_DIR/../schemas/review.schema.json" "$SCRIPT_DIR/lib/json-schema-subset.cjs" "$ISSUE_N" "$CWD" "$REVIEW_START_HEAD" <<'NODE'
const fs=require("fs"); try { const a=JSON.parse(fs.readFileSync(process.argv[2],"utf8")), s=JSON.parse(fs.readFileSync(process.argv[3],"utf8")); delete s.if; delete s.then; const {validate}=require(process.argv[4]); const fail=a.status==="fail"&&(!Array.isArray(a.findings)||a.findings.length<1||typeof a.patch_instructions!=="string"); if(validate(s,a).length||fail)throw "schema_invalid"; if(String(a.issue.number)!==process.argv[5])throw "issue_mismatch"; if(a.reviewed_head_sha!==process.argv[7])throw "head_mismatch"; } catch (reason) { process.stdout.write(typeof reason==="string" ? reason : "schema_invalid"); process.exit(2); }
NODE
}
transcribe_review() {
  node - "$1" "$2" <<'NODE'
const fs=require("fs");
const source=fs.readFileSync(process.argv[2],"utf8");
try { JSON.parse(source); fs.writeFileSync(process.argv[3],source); process.exit(0); } catch (_) {}
const matches=[...source.matchAll(/```json[ \t]*\r?\n([\s\S]*?)\r?\n?```/gi)];
if(!matches.length)process.exit(2);
for(let i=matches.length-1;i>=0;i--) { const candidate=matches[i][1]; try { JSON.parse(candidate); fs.writeFileSync(process.argv[3],candidate); process.exit(0); } catch (_) {} }
process.exit(2);
NODE
}
preserve_review_output() {
  mkdir -p "$CWD/.review" || return 1
  cp "$OUTPUT" "$CWD/.review/ISSUE-${ISSUE_N}-review-attempt${attempt}-output.log"
}
blocker_signature() {
  file="$1"; [ -f "$file" ] || { printf '%s\n' absent; return; }
  node - "$file" <<'NODE'
const fs=require("fs"),crypto=require("crypto"); try { const f=process.argv[2],s=fs.statSync(f); process.stdout.write(`${s.size}:${s.mtimeMs}:${crypto.createHash("sha256").update(fs.readFileSync(f)).digest("hex")}\n`); } catch (_) { process.stdout.write("unreadable\n"); }
NODE
}
probe_runtime() {
  # Tests and operators may supply a real selected-runtime probe.  The default
  # remains the typed capability probe, which never substitutes a runtime.
  if [ -n "${AGENT_WATCHDOG_PROBE_CMD:-}" ]; then
    AGENT_WATCHDOG_PROBE_RUNTIME="$RUNTIME" sh -c "$AGENT_WATCHDOG_PROBE_CMD" </dev/null
  else
    "$RUNTIME_EXEC" capabilities --runtime "$RUNTIME" >/dev/null
  fi
}
failure_is_refused() {
  # A returned CLI failure with an explicit auth/model/permission/capability
  # diagnostic is not a transient work failure. Keep this deliberately narrow.
  grep -Eiq 'auth(entication|orization)?|unauthori[sz]ed|forbidden|invalid[ _-]?(api[ _-]?)?key|api[ _-]?key|model[[:space:]_-].*(not[[:space:]_-]?(found|available)|unsupported)|capability[_ -]missing|runtime[_ -](unavailable|capability)|opencode_permission|permission[_ -](config|required|not)|unsupported_(role|mode)' "$1"
}
while [ "$#" -gt 0 ]; do case "$1" in --issue) ISSUE_N="$2"; shift 2;; --runtime) RUNTIME="$2"; shift 2;; --role) ROLE="$2"; shift 2;; --mode) MODE="$2"; shift 2;; --prompt-file) PROMPT_FILE="$2"; shift 2;; --cwd) CWD="$2"; shift 2;; --model) MODEL="$2"; shift 2;; --effort) EFFORT="$2"; shift 2;; --opencode-permission-file) PERMISSION_FILE="$2"; shift 2;; --produce-review) PRODUCE_REVIEW=1; shift;; --conductor-control) CONDUCTOR_CONTROL=1; shift;; --first-progress-timeout) FIRST_PROGRESS_TIMEOUT="$2"; shift 2;; --stall-timeout) STALL_TIMEOUT="$2"; shift 2;; --max-retries) MAX_RETRIES="$2"; shift 2;; *) usage; exit 2;; esac; done
[ -n "$ISSUE_N" ] && [ -n "$RUNTIME" ] && [ -n "$ROLE" ] && [ -n "$MODE" ] && [ -n "$PROMPT_FILE" ] && [ -n "$CWD" ] || { usage; exit 2; }
[ -d "$CWD" ] && [ -f "$PROMPT_FILE" ] || { echo 'invalid cwd or prompt file' >&2; exit 2; }
[ "$PRODUCE_REVIEW" -eq 0 ] || { [ "$ROLE" = reviewer ] && [ "$MODE" = read ] || { echo '--produce-review requires reviewer read mode' >&2; exit 2; }; }
[ "$CONDUCTOR_CONTROL" -eq 0 ] || { [ "$ROLE" = conductor ] && [ "$MODE" = read ] && [ "$PRODUCE_REVIEW" -eq 0 ] || { echo '--conductor-control requires conductor read mode' >&2; exit 2; }; [ -x "$CONTROL_PUBLISHER" ] || { echo 'conductor control publisher missing' >&2; exit 2; }; }
REVIEW_START_HEAD=""
if [ "$PRODUCE_REVIEW" -eq 1 ]; then
  REVIEW_START_HEAD="$(git -C "$CWD" rev-parse HEAD 2>/dev/null || true)"
  printf '%s' "$REVIEW_START_HEAD" | grep -Eq '^[0-9a-f]{40}$' || { echo 'cannot pin REVIEW start HEAD' >&2; exit 2; }
fi
BLOCKER_PATH="$CWD/.review/ISSUE-${ISSUE_N}-BLOCKER.json"
BLOCKER_BEFORE_SIG="$(blocker_signature "$BLOCKER_PATH")"
PR_DRAFT_PATH="$CWD/.review/ISSUE-${ISSUE_N}-PR-DRAFT.json"
PR_DRAFT_BEFORE_SIG="$(blocker_signature "$PR_DRAFT_PATH")"
case "$MAX_RETRIES" in ''|*[!0-9]*) echo '--max-retries must be a non-negative integer' >&2; exit 2;; esac
CAPABILITIES="$($RUNTIME_EXEC capabilities --runtime "$RUNTIME")" || { echo "$CAPABILITIES" >&2; exit 3; }
RUNTIME_VERSION="$(printf '%s' "$CAPABILITIES" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(JSON.parse(s).version||"")}catch(_){process.exit(2)}})')" || { echo 'runtime capability output lacks version' >&2; exit 3; }
STAMP="$(mktemp -t agent-watchdog-stamp.XXXXXX)"; OUTPUT="$(mktemp -t agent-watchdog-output.XXXXXX)"; STDERR="$(mktemp -t agent-watchdog-stderr.XXXXXX)"; REVIEW_TRANSCRIPT="$(mktemp -t agent-watchdog-review.XXXXXX)"; trap 'rm -f "$STAMP" "$OUTPUT" "$STDERR" "$REVIEW_TRANSCRIPT"' EXIT
set -- --runtime "$RUNTIME" --role "$ROLE" --mode "$MODE" --cwd "$CWD" --prompt-file "$PROMPT_FILE" --issue "$ISSUE_N"; [ -n "$MODEL" ] && set -- "$@" --model "$MODEL"; [ -n "$EFFORT" ] && set -- "$@" --effort "$EFFORT"; [ -n "$PERMISSION_FILE" ] && set -- "$@" --opencode-permission-file "$PERMISSION_FILE"; [ "$PRODUCE_REVIEW" -eq 1 ] && set -- "$@" --produce-review
attempt=0
while [ "$attempt" -le "$MAX_RETRIES" ]; do
  attempt=$((attempt + 1)); : > "$OUTPUT"; : > "$STDERR"; write_marker running "$attempt" '' '' || true; touch "$STAMP"
  "$RUNTIME_EXEC" run "$@" >"$OUTPUT" 2>"$STDERR" & pid=$!; write_marker running "$attempt" "$pid" '' || true
  first_seen=0; last_progress="$(date +%s)"; killed=0
  while kill -0 "$pid" 2>/dev/null; do sleep "$POLL_INTERVAL"; if progressed; then touch "$STAMP"; last_progress="$(date +%s)"; first_seen=1; fi; [ "$first_seen" -eq 1 ] && budget="$STALL_TIMEOUT" || budget="$FIRST_PROGRESS_TIMEOUT"; elapsed=$(( $(date +%s) - last_progress )); if [ "$elapsed" -ge "$budget" ]; then killed=1; kill_tree "$pid"; write_marker killed_stall "$attempt" "$pid" '' || true; break; fi; done
  wait "$pid" 2>/dev/null; ec=$?
  if [ "$ec" -ne 0 ]; then
    mkdir -p "$CWD/.review" || exit 1; attempt_stderr="$CWD/.review/ISSUE-${ISSUE_N}-agent-attempt${attempt}-stderr.log"; mv "$STDERR" "$attempt_stderr"; STDERR="$(mktemp -t agent-watchdog-stderr.XXXXXX)"
    # codex stashes partial work itself inside codex-safe.sh; claude/opencode
    # have no equivalent wrapper, so a stall-kill or crash here would otherwise
    # leave the worktree dirty for the next retry with nothing preserved.
    if [ "$MODE" = write ] && [ "$PRODUCE_REVIEW" -eq 0 ] && [ "$RUNTIME" != codex ]; then
      "$SCRIPT_DIR/workflow-stash.sh" "$ISSUE_N" "$CWD" || true
    fi
    if [ "$killed" -eq 1 ]; then continue; fi
    # Review runners own canonical-output validation. A non-zero review exit is
    # therefore a terminal refusal, not a transport failure worth retrying.
    # This also preserves any previously published canonical review.
    if [ "$PRODUCE_REVIEW" -eq 1 ]; then
      if [ "$RUNTIME" = codex ]; then write_marker refused "$attempt" "$pid" "$ec" || true; else preserve_review_output || true; write_marker refused "$attempt" "$pid" "$ec" runtime_exit_nonzero || true; fi
      exit 4
    fi
    if failure_is_refused "$attempt_stderr"; then write_marker refused "$attempt" "$pid" "$ec" || true; exit 4; fi
    if probe_runtime >/dev/null 2>&1; then :; else sleep "$PROBE_GAP"; if ! probe_runtime >/dev/null 2>&1; then write_marker refused "$attempt" "$pid" "$ec" || true; exit 4; fi; fi
    continue
  fi
  BLOCKER_AFTER_SIG="$(blocker_signature "$BLOCKER_PATH")"
  FRESH_BLOCKER=0
  if [ "$PRODUCE_REVIEW" -eq 0 ] && [ "$BLOCKER_AFTER_SIG" != "$BLOCKER_BEFORE_SIG" ] && [ "$BLOCKER_AFTER_SIG" != absent ]; then
    if ! node "$SCRIPT_DIR/lib/blocker-check.cjs" "$BLOCKER_PATH" "$SCRIPT_DIR/../schemas/blocker.schema.json" "$SCRIPT_DIR/lib/json-schema-subset.cjs" "$ISSUE_N" "$CWD" >/dev/null 2>&1; then
      echo 'ERROR: BLOCKER output is not schema-valid/current/consumable for this issue' >&2
      write_marker refused "$attempt" "$pid" 1 || true
      exit 1
    fi
    FRESH_BLOCKER=1
  fi
  if [ "$ROLE" = "implementation" ] && [ "$MODE" = "write" ] && [ "$FRESH_BLOCKER" -eq 0 ]; then
    PR_DRAFT_AFTER_SIG="$(blocker_signature "$PR_DRAFT_PATH")"
    if [ "$PR_DRAFT_AFTER_SIG" = "$PR_DRAFT_BEFORE_SIG" ] || [ "$PR_DRAFT_AFTER_SIG" = absent ]; then
      echo 'ERROR: implementation exited without a fresh canonical PR-DRAFT artifact' >&2
      write_marker refused "$attempt" "$pid" 1 || true
      exit 1
    fi
    if ! node "$SCRIPT_DIR/lib/pr-draft-check.cjs" "$PR_DRAFT_PATH" "$SCRIPT_DIR/../schemas/pr_draft.schema.json" "$SCRIPT_DIR/lib/json-schema-subset.cjs" "$ISSUE_N" "$CWD" >/dev/null 2>&1; then
      echo 'ERROR: PR-DRAFT output is not schema-valid/current/bound to this issue worktree' >&2
      write_marker refused "$attempt" "$pid" 1 || true
      exit 1
    fi
  fi
  if [ "$PRODUCE_REVIEW" -eq 1 ]; then
  if [ "$RUNTIME" = codex ]; then
    REVIEW_SOURCE="$CWD/.review/ISSUE-${ISSUE_N}-REVIEW.json"
  elif transcribe_review "$OUTPUT" "$REVIEW_TRANSCRIPT"; then
    REVIEW_SOURCE="$REVIEW_TRANSCRIPT"
  else
    preserve_review_output || true
    echo 'ERROR: REVIEW output has no parseable canonical JSON object' >&2
    write_marker refused "$attempt" "$pid" 1 unparseable_output || true
    exit 1
  fi
  REVIEW_REFUSAL_REASON="$(validate_review "$REVIEW_SOURCE")"; review_validation_ec=$?
  if [ "$review_validation_ec" -ne 0 ]; then
    echo 'ERROR: REVIEW output is not canonical for this issue and live HEAD' >&2
    if [ "$RUNTIME" = codex ]; then write_marker refused "$attempt" "$pid" 1 || true; else preserve_review_output || true; write_marker refused "$attempt" "$pid" 1 "${REVIEW_REFUSAL_REASON:-schema_invalid}" || true; fi
    exit 1
  fi
  if ! node "$SCRIPT_DIR/lib/review-publish.cjs" "$REVIEW_SOURCE" "$CWD/.review" "$ISSUE_N" "$CWD" "$REVIEW_START_HEAD" >/dev/null 2>&1; then
    echo 'ERROR: REVIEW publication lost its pinned HEAD or conflicted with immutable evidence' >&2
    if [ "$RUNTIME" = codex ]; then write_marker refused "$attempt" "$pid" 1 || true; else preserve_review_output || true; write_marker refused "$attempt" "$pid" 1 publication_failed || true; fi
    exit 1
  fi
  if [ "$RUNTIME" != codex ]; then OUTPUT=""; fi
  fi
  if [ "$CONDUCTOR_CONTROL" -eq 1 ]; then
    if ! "$CONTROL_PUBLISHER" --issue "$ISSUE_N" --cwd "$CWD" --proposal "$OUTPUT"; then
      echo 'ERROR: CONDUCTOR control proposal was denied; no canonical control artifact was published' >&2
      write_marker refused "$attempt" "$pid" 1 || true
      exit 1
    fi
  fi
  write_marker exited "$attempt" "$pid" 0 || true
  exit 0
done
write_marker exhausted "$attempt" '' '' || true
echo "FAIL: $RUNTIME stalled/failed after $MAX_RETRIES retries" >&2
exit 6
