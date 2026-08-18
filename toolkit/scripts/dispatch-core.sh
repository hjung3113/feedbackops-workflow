#!/usr/bin/env bash
# dispatch-core.sh — transport-neutral correctness core for a typed seat.
# Public callers use agent-workflow.sh; cmux-dispatch.sh is the compatibility
# facade that explicitly selects cmux. Adapters only launch the runner created
# here and never own admission or workflow completion.
# A hand-rolled transport command silently died in production (2026-07-13):
# --cwd was forgotten on the cmux workspace itself, the workspace opened in
# cmux's default project dir, and the watchdog validated its
# --prompt-file relative to the CALLING shell's cwd (not the intended
# worktree) and exited 2 before writing any artifact. Nothing but pane
# scrollback recorded the failure.
#
# RUN.json terminal-state contract (as it actually is — do not assume
# "completed"/"failed" strings):
#   - status:"running"       codex-safe process is alive, still attempting.
#   - status:"exited"        codex process finished; exit_code present.
#                             exit_code 0 means the codex process finished
#                             cleanly — it does NOT by itself mean the task
#                             succeeded. Task success is judged by commits +
#                             a VERIFY artifact, never by exit_code alone.
#   - status:"killed_stall"  watchdog killed it for no file/process progress.
#   - status:"refused"       failed model/auth probe; retry is futile.
#   - status:"exhausted"     retries used up with no success.
#   A `.review/ISSUE-<N>-BLOCKER.json` file appearing instead of/alongside
#   RUN.json is a scoped abort — codex chose to stop, not crash.
#
# Usage:
#   scripts/agent-workflow.sh dispatch --orchestrator <registered adapter> --issue <N> --worktree <path> \
#     [--prompt-file <p>] [--name <workspace-name>] \
#     [--tier trivial|standard|full_cluster] \
#     [--round-state <json> --manifest-revision <n>] \
#     [--poll-timeout <secs>] [--dry-run]
#   Initial writes require an explicit tier. Standard/Full Cluster initial
#   writes and every redispatch require canonical ROUND-STATE + revision;
#   Trivial initial writes retain the pr_draft-only contract.
#
# Defaults:
#   --prompt-file    <worktree>/.review/ISSUE-<N>-PROMPT.md
#   --name           codex-<N>
#   --poll-timeout   300   (poll interval 5s; AGENT_WORKFLOW_POLL_INTERVAL overrides; test seam)
#
# Same-issue re-dispatch (e.g. a second prompt file for the same issue) is
# supported: a pre-existing RUN.json/BLOCKER.json from a previous run is
# treated as STALE — the poll only accepts an artifact whose mtime+started_at
# changed after this dispatch (or that newly appeared).
#
# The selected adapter receives only a short relative launch-runner. Each launch gets
# a unique runner directory, atomically populated under <worktree>/.review
# before transport launch, preserving the fully quoted watchdog argv without either
# a length-sensitive inline command or same-issue seat overwrites.
#
# bash-3.2-compatible: no `declare -A`, no `${var,,}`, no `mapfile`.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRODUCT_HOME="$(cd "$SCRIPT_DIR/.." && pwd -P)"
WATCHDOG="$SCRIPT_DIR/agent-watchdog.sh"
REDISPATCH_CHECK="$SCRIPT_DIR/redispatch-check.sh"
PROMPT_AC_CHECK="$SCRIPT_DIR/prompt-ac-check.sh"
PARALLEL_PLAN="$SCRIPT_DIR/lib/parallel-plan.cjs"
ROUND_STATE_SCHEMA="$SCRIPT_DIR/../schemas/round_state.schema.json"
SCHEMA_VALIDATOR="$SCRIPT_DIR/lib/json-schema-subset.cjs"
TRANSPORT_REGISTRY="$SCRIPT_DIR/lib/transport-registry.cjs"
RUNTIME_REGISTRY="$SCRIPT_DIR/lib/runtime-registry.cjs"
TOUCH_ALLOWLIST_PREFLIGHT="$SCRIPT_DIR/lib/touch-allowlist-preflight.cjs"
RECEIPT_SCHEMA="$SCRIPT_DIR/../schemas/transport_receipt.schema.json"

ISSUE_N=""
ADAPTER=""
RUNTIME="codex"
ROLE="implementation"
RUNTIME_PERMISSION_FILE=""
WORKTREE=""
PROMPT_FILE=""
WS_NAME=""
MODEL=""
EFFORT=""
MODEL_SUPPLIED=0
EFFORT_SUPPLIED=0
ALLOCATE=0
ALLOCATOR_ROLE=""
TIER=""
FIRST_PROGRESS_TIMEOUT=""
STALL_TIMEOUT=""
MAX_RETRIES=""
MAX_WALLCLOCK=""
ROUND_STATE=""
MANIFEST_REVISION=""
READ_ONLY=0
PRODUCE_REVIEW=0
CONDUCTOR_CONTROL=0
REREVIEW=0
REVIEW_CAPSULE=""
EXECUTION_PLAN=""
PLAN_SEAT=""
POLL_TIMEOUT=300
DRY_RUN=0
POLL_INTERVAL="${AGENT_WORKFLOW_POLL_INTERVAL:-5}"
PRE_MARKER_DELAY="${AGENT_WORKFLOW_PRE_MARKER_DELAY:-0}"

usage() {
  echo "usage: dispatch-core.sh --adapter $(node "$TRANSPORT_REGISTRY" pipe) --runtime $(node "$RUNTIME_REGISTRY" pipe) --role ROLE --issue N --worktree PATH [--prompt-file P] [--name SEATNAME] [--model M] [--effort E] [--allocate --allocator-role implementation] [--tier trivial|standard|full_cluster] [--read-only|--produce-review|--conductor-control [--re-review --review-capsule PATH]] [--round-state JSON --manifest-revision N] [--execution-plan JSON --seat ID] [--first-progress-timeout SECS] [--stall-timeout SECS] [--max-retries N] [--max-wallclock SECS] [--poll-timeout SECS] [--dry-run]" >&2
}

# is_registered_adapter <name> — membership in the transport registry, which is
# the single source of truth for the admitted adapter set.
is_registered_adapter() {
  for adapter in $(node "$TRANSPORT_REGISTRY" lines); do
    [ "$1" = "$adapter" ] && return 0
  done
  return 1
}

# is_registered_runtime <name> — membership in the runtime registry, which is
# the single source of truth for the admitted runtime set.
is_registered_runtime() {
  for runtime in $(node "$RUNTIME_REGISTRY" lines); do
    [ "$1" = "$runtime" ] && return 0
  done
  return 1
}

# file_sig <file> — identity signature (mtime + started_at) used to tell a
# STALE artifact from a previous run apart from a FRESH one this dispatch
# produced. First production use of this script (issue 147 re-dispatch with a
# second prompt file) hit this: a status:"exited" RUN.json from the PREVIOUS
# watchdog run was still present and the poll accepted it immediately —
# before the new watchdog had even started. Every watchdog attempt rewrites
# started_at, so mtime+started_at changing (or the file newly appearing)
# means the artifact is fresh.
file_sig() {
  f="$1"
  node -e '
    const fs = require("fs");
    try {
      const file = process.argv[1];
      const mtimeNs = fs.statSync(file, { bigint: true }).mtimeNs;
      let startedAt = "";
      try { startedAt = String(JSON.parse(fs.readFileSync(file, "utf8")).started_at || ""); } catch (error) {}
      process.stdout.write(`${mtimeNs}|${startedAt}`);
    } catch (error) {
      process.stdout.write("0|");
    }
  ' "$f" 2>/dev/null
}

file_started_at() {
  node -e 'try { process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).started_at || "unknown")); } catch (e) { process.stdout.write("unknown"); }' "$1" 2>/dev/null
}

# append_event <event> <status> [detail] — append one line to the issue's
# append-only EVENTS.jsonl log alongside RUN.json (#163). Callers that exit
# before the watchdog ever runs (admission refusals) have no RUN.json at all;
# this gives every failure path a pollable artifact. Never truncates.
append_event() {
  events_file="$ABS_WORKTREE/.review/ISSUE-${ISSUE_N}-EVENTS.jsonl"
  mkdir -p "$ABS_WORKTREE/.review" || return 1
  AGENT_EVENT="$1" AGENT_STATUS="$2" AGENT_DETAIL="${3:-}" AGENT_EVENTS_FILE="$events_file" node -e '
const fs=require("fs");
const line=JSON.stringify({ts:new Date().toISOString().replace(/\.\d+Z$/,"Z"),attempt:0,event:process.env.AGENT_EVENT,status:process.env.AGENT_STATUS,detail:process.env.AGENT_DETAIL})+"\n";
fs.appendFileSync(process.env.AGENT_EVENTS_FILE,line);
' || return 1
  return 0
}

write_launch_runner() {
  runner_dir="$(mktemp -d "$ABS_WORKTREE/.review/ISSUE-${ISSUE_N}-launch.XXXXXX")" || return 1
  runner="$runner_dir/launch.sh"
  runner_tmp="$runner_dir/.launch.sh.tmp"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    # Policy state is host-only. A worker receives the selected tuple and
    # never the host-state override/path that made the selection possible.
    printf '%s\n' 'unset AGENT_WORKFLOW_HOST_STATE'
    printf 'exec env NODE_OPTIONS= '
    printf '%q ' "AGENT_WORKFLOW_RUNTIME_BIN=$RUNTIME_BIN_PIN"
    printf '%q ' "$WATCHDOG" --runtime "$RUNTIME" --role "$ROLE" --mode "$RUNTIME_MODE" --issue "$ISSUE_N" --prompt-file "$ABS_PROMPT_FILE" --cwd "$ABS_WORKTREE"
    [ -n "$MODEL" ] && printf '%q %q ' --model "$MODEL"
    [ -n "$EFFORT" ] && printf '%q %q ' --effort "$EFFORT"
    [ -n "$FIRST_PROGRESS_TIMEOUT" ] && printf '%q %q ' --first-progress-timeout "$FIRST_PROGRESS_TIMEOUT"
    [ -n "$STALL_TIMEOUT" ] && printf '%q %q ' --stall-timeout "$STALL_TIMEOUT"
    [ -n "$MAX_RETRIES" ] && printf '%q %q ' --max-retries "$MAX_RETRIES"
    [ -n "$MAX_WALLCLOCK" ] && printf '%q %q ' --max-wallclock "$MAX_WALLCLOCK"
    [ "$PRODUCE_REVIEW" -eq 1 ] && printf '%q ' --produce-review
    [ "$CONDUCTOR_CONTROL" -eq 1 ] && printf '%q ' --conductor-control
    [ -n "$RUNTIME_PERMISSION_FILE" ] && printf '%q %q ' --opencode-permission-file "$RUNTIME_PERMISSION_FILE"
    printf '\n'
  } > "$runner_tmp" || {
    rm -f "$runner_tmp"
    rmdir "$runner_dir" 2>/dev/null || true
    return 1
  }
  chmod 700 "$runner_tmp" || {
    rm -f "$runner_tmp"
    rmdir "$runner_dir" 2>/dev/null || true
    return 1
  }
  mv -f "$runner_tmp" "$runner" || {
    rm -f "$runner_tmp"
    rmdir "$runner_dir" 2>/dev/null || true
    return 1
  }
  runner_dir_name="${runner_dir##*/}"
  RUNNER_RELATIVE=".review/$runner_dir_name/launch.sh"
  RUNNER_FILE="$runner"
  RUNNER_COMMAND="bash $RUNNER_RELATIVE"
  RUNNER_RECEIPT_MARKER="$runner_dir/.receipt-published"
}

cleanup_superseded_runners() {
  review_dir="$ABS_WORKTREE/.review"
  current_runner_dir="${RUNNER_FILE%/launch.sh}"
  find "$review_dir" -type f -path "$review_dir/ISSUE-${ISSUE_N}-launch.*/.receipt-published" -print0 2>/dev/null |
  while IFS= read -r -d '' marker; do
    runner_dir="${marker%/.receipt-published}"
    [ "$runner_dir" = "$current_runner_dir" ] && continue
    case "$runner_dir" in
      "$review_dir"/ISSUE-"$ISSUE_N"-launch.*) ;;
      *) continue ;;
    esac
    rm -f "$marker" "$runner_dir/launch.sh"
    rmdir "$runner_dir" 2>/dev/null || true
  done
}

release_runner_retention_lock() {
  [ "${RUNNER_RETENTION_LOCK_HELD:-0}" -eq 1 ] || return 0
  node - "$RUNNER_RETENTION_LOCK" "$$" <<'NODE' >/dev/null 2>&1 || true
const fs = require("fs");
const path = require("path");
const [lock, pid] = process.argv.slice(2);
try {
  const owner = JSON.parse(fs.readFileSync(path.join(lock, ".agent-workflow-owner.json"), "utf8"));
  if (String(owner.pid) === pid) fs.rmSync(lock, { recursive: true, force: true });
} catch (_) {}
NODE
  RUNNER_RETENTION_LOCK_HELD=0
}

acquire_runner_retention_lock() {
  RUNNER_RETENTION_LOCK="$ABS_WORKTREE/.review/.ISSUE-${ISSUE_N}-runner-retention.lock"
  RUNNER_RETENTION_LOCK_HELD=0
  while :; do
    node - "$RUNNER_RETENTION_LOCK" "$$" <<'NODE' >/dev/null 2>&1
const fs = require("fs");
const path = require("path");
const [lock, pid] = process.argv.slice(2);
const pending = `${lock}.pending.${pid}.${Date.now()}`;
try {
  fs.mkdirSync(pending, { mode: 0o700 });
  fs.writeFileSync(path.join(pending, ".agent-workflow-owner.json"), JSON.stringify({ version: 1, pid: Number(pid), kind: "runner-retention" }) + "\n", { flag: "wx", mode: 0o600 });
  fs.renameSync(pending, lock);
  process.exit(0);
} catch (_) {
  try { fs.rmSync(pending, { recursive: true, force: true }); } catch (_) {}
  process.exit(fs.existsSync(lock) ? 1 : 2);
}
NODE
    lock_status=$?
    if [ "$lock_status" -eq 0 ]; then
      RUNNER_RETENTION_LOCK_HELD=1
      return 0
    fi
    [ "$lock_status" -eq 1 ] || return 1
    node - "$RUNNER_RETENTION_LOCK" "$$" <<'NODE' >/dev/null 2>&1
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");
const [lock, pid] = process.argv.slice(2);
function alive(value) {
  if (!Number.isInteger(value) || value < 1) return false;
  try {
    process.kill(value, 0);
    return execFileSync("ps", ["-p", String(value), "-o", "stat="], { encoding: "utf8" }).trim().indexOf("Z") === -1;
  } catch (_) { return false; }
}
try {
  const stat = fs.lstatSync(lock);
  if (!stat.isDirectory()) process.exit(2);
  let owner;
  try { owner = JSON.parse(fs.readFileSync(path.join(lock, ".agent-workflow-owner.json"), "utf8")); } catch (_) { owner = null; }
  if (owner && alive(owner.pid)) process.exit(1);
  const reclaimed = `${lock}.reclaim.${pid}.${Date.now()}`;
  fs.renameSync(lock, reclaimed);
  fs.rmSync(reclaimed, { recursive: true, force: true });
  process.exit(0);
} catch (_) { process.exit(fs.existsSync(lock) ? 1 : 0); }
NODE
    reclaim_status=$?
    [ "$reclaim_status" -eq 2 ] && return 1
    sleep 1
  done
}

mark_current_receipt_runner() {
  [ -r "$RECEIPT_FILE" ] || return 0
  receipt_runner="$(node - "$RECEIPT_FILE" "$RECEIPT_SCHEMA" "$SCHEMA_VALIDATOR" "$ISSUE_N" "$ABS_WORKTREE" <<'NODE'
const fs = require("fs");
const [file, schemaFile, validatorFile, issue, worktree] = process.argv.slice(2);
try {
  const value = JSON.parse(fs.readFileSync(file, "utf8"));
  const schema = JSON.parse(fs.readFileSync(schemaFile, "utf8"));
  const { validate } = require(validatorFile);
  if (validate(schema, value).length || value.issue !== Number(issue)
      || value.worktree_path !== worktree || !value.runner || typeof value.runner.path !== "string") process.exit(2);
  process.stdout.write(value.runner.path);
} catch (_) { process.exit(2); }
NODE
)" || return 0
  case "$receipt_runner" in
    "$ABS_WORKTREE"/.review/ISSUE-"$ISSUE_N"-launch.*/launch.sh) ;;
    *) return 0 ;;
  esac
  [ -f "$receipt_runner" ] || return 0
  : > "${receipt_runner%/launch.sh}/.receipt-published"
}

require_standard_artifact_pointers() {
  node - "$1" <<'NODE'
const fs = require("fs");
try {
  const state = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  const pointerTypes = new Set((state.artifact_pointers || []).map(pointer => pointer.artifact_type));
  if (!pointerTypes.has("pr_draft") || !pointerTypes.has("review")) process.exit(2);
} catch (error) {
  process.exit(2);
}
NODE
  if [ "$?" -ne 0 ]; then
    echo "ERROR: ROUND-STATE admission denied: pr_draft and review pointers must be retained" >&2
    return 2
  fi
  return 0
}

# await subcommand (#163): purely a reader of the append-only EVENTS.jsonl.
# It launches nothing, never touches RUN.json, and never enters the normal
# dispatch logic below — the existing launch-supervision poll loop's exit-code
# semantics are unchanged for every existing caller.
if [ "${1:-}" = "await" ]; then
  shift
  AW_ISSUE=""; AW_CWD=""; AW_TIMEOUT=3600
  while [ $# -gt 0 ]; do
    case "$1" in
      --issue) AW_ISSUE="$2"; shift 2 ;;
      --cwd) AW_CWD="$2"; shift 2 ;;
      --timeout-seconds) AW_TIMEOUT="$2"; shift 2 ;;
      *) echo "usage: dispatch-core.sh await --issue N --cwd DIR [--timeout-seconds SECS]" >&2; exit 2 ;;
    esac
  done
  [ -n "$AW_ISSUE" ] && [ -n "$AW_CWD" ] || { echo "usage: dispatch-core.sh await --issue N --cwd DIR [--timeout-seconds SECS]" >&2; exit 2; }
  [ -d "$AW_CWD" ] || { echo "ERROR: await cwd not found: $AW_CWD" >&2; exit 2; }
  AW_EVENTS="$AW_CWD/.review/ISSUE-${AW_ISSUE}-EVENTS.jsonl"
  AW_STARTED="$(date +%s)"
  while :; do
    AW_TERMINAL="$(node -e '
const fs=require("fs");
const terminal=new Set(["exited","killed_stall","refused","exhausted"]);
try {
  const lines=fs.readFileSync(process.argv[1],"utf8").split("\n");
  for (let i=lines.length-1;i>=0;i--) {
    const text=lines[i].trim();
    if (!text) continue;
    try { const value=JSON.parse(text); if (value && terminal.has(value.status)) { process.stdout.write(text); process.exit(0); } } catch (_) {}
  }
} catch (_) {}
' "$AW_EVENTS" 2>/dev/null || true)"
    if [ -n "$AW_TERMINAL" ]; then printf '%s\n' "$AW_TERMINAL"; exit 0; fi
    AW_ELAPSED=$(( $(date +%s) - AW_STARTED ))
    if [ "$AW_ELAPSED" -ge "$AW_TIMEOUT" ]; then
      echo "ERROR: await timed out after ${AW_TIMEOUT}s waiting for terminal status in $AW_EVENTS" >&2
      exit 1
    fi
    sleep "$POLL_INTERVAL"
  done
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --adapter) ADAPTER="$2"; shift 2 ;;
    --runtime) RUNTIME="$2"; shift 2 ;;
    --role) ROLE="$2"; shift 2 ;;
    --issue) ISSUE_N="$2"; shift 2 ;;
    --worktree) WORKTREE="$2"; shift 2 ;;
    --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
    --name) WS_NAME="$2"; shift 2 ;;
    --model) MODEL="$2"; MODEL_SUPPLIED=1; shift 2 ;;
    --effort) EFFORT="$2"; EFFORT_SUPPLIED=1; shift 2 ;;
    --allocate) ALLOCATE=1; shift 1 ;;
    --allocator-role) ALLOCATOR_ROLE="$2"; shift 2 ;;
    --tier) TIER="$2"; shift 2 ;;
    --first-progress-timeout) FIRST_PROGRESS_TIMEOUT="$2"; shift 2 ;;
    --stall-timeout) STALL_TIMEOUT="$2"; shift 2 ;;
    --max-retries) MAX_RETRIES="$2"; shift 2 ;;
    --max-wallclock) MAX_WALLCLOCK="$2"; shift 2 ;;
    --round-state) ROUND_STATE="$2"; shift 2 ;;
    --manifest-revision) MANIFEST_REVISION="$2"; shift 2 ;;
    --read-only) READ_ONLY=1; shift 1 ;;
    --produce-review) PRODUCE_REVIEW=1; shift 1 ;;
    --conductor-control) CONDUCTOR_CONTROL=1; shift 1 ;;
    --re-review) REREVIEW=1; shift 1 ;;
    --review-capsule) REVIEW_CAPSULE="$2"; shift 2 ;;
    --execution-plan) EXECUTION_PLAN="$2"; shift 2 ;;
    --seat) PLAN_SEAT="$2"; shift 2 ;;
    --poll-timeout) POLL_TIMEOUT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift 1 ;;
    *) echo "unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

[ -n "$ADAPTER" ] || { echo "missing --adapter" >&2; usage; exit 2; }
is_registered_adapter "$ADAPTER" || { echo "unknown adapter: $ADAPTER" >&2; exit 2; }
is_registered_runtime "$RUNTIME" || { echo "unknown runtime: $RUNTIME" >&2; exit 2; }
case "$ROLE" in conductor|architect|implementation|reviewer|verifier|visual|release) ;; *) echo "unknown role: $ROLE" >&2; exit 2 ;; esac
[ -n "$ISSUE_N" ] || { echo "missing --issue" >&2; usage; exit 2; }
[ -n "$WORKTREE" ] || { echo "missing --worktree" >&2; usage; exit 2; }
if [ "$ALLOCATE" -eq 1 ] && { [ -n "$MODEL" ] || [ -n "$EFFORT" ]; }; then
  echo "ERROR: --allocate cannot be combined with --model or --effort" >&2
  exit 2
fi
if [ "$ALLOCATE" -eq 1 ]; then
  case "$ALLOCATOR_ROLE:$ROLE:$PRODUCE_REVIEW" in
    implementation:implementation:0|reviewer:reviewer:1) ;;
    implementation:*) echo "ERROR: --allocator-role implementation requires a write-capable implementation dispatch" >&2; exit 2 ;;
    reviewer:*) echo "ERROR: --allocator-role reviewer requires --role reviewer --produce-review" >&2; exit 2 ;;
    *) echo "ERROR: --allocator-role must be implementation or reviewer" >&2; exit 2 ;;
  esac
fi
if [ "$ALLOCATE" -eq 0 ] && [ -n "$ALLOCATOR_ROLE" ]; then
  echo "ERROR: --allocator-role requires --allocate" >&2
  exit 2
fi
if [ "$READ_ONLY" -eq 1 ] && [ "$PRODUCE_REVIEW" -eq 1 ]; then
  echo "ERROR: --read-only and --produce-review are mutually exclusive" >&2
  exit 2
fi
if [ "$CONDUCTOR_CONTROL" -eq 1 ] && [ "$PRODUCE_REVIEW" -eq 1 ]; then
  echo "ERROR: --conductor-control and --produce-review are mutually exclusive" >&2
  exit 2
fi
if [ "$PRODUCE_REVIEW" -eq 1 ] && [ -z "$MODEL" ] && [ "$ALLOCATE" -eq 0 ]; then
  echo "ERROR: --produce-review requires an explicit --model or --allocate --allocator-role reviewer" >&2
  exit 2
fi
if [ "$PRODUCE_REVIEW" -eq 1 ] && [ "$ROLE" != "reviewer" ]; then
  echo "ERROR: --produce-review requires --role reviewer" >&2
  exit 2
fi
if [ "$ROLE" = "reviewer" ] && [ "$PRODUCE_REVIEW" -eq 0 ]; then
  echo "ERROR: --role reviewer requires --produce-review" >&2
  exit 2
fi
if [ "$CONDUCTOR_CONTROL" -eq 1 ] && { [ "$ROLE" != conductor ] || [ "$READ_ONLY" -eq 0 ]; }; then
  echo "ERROR: --conductor-control requires --role conductor --read-only; source-writing role bleed is denied" >&2
  exit 2
fi
case "$ROLE" in
  conductor|architect|verifier|visual|release)
    if [ "$READ_ONLY" -eq 0 ]; then
      echo "ERROR: role $ROLE requires --read-only; source-writing role bleed is denied" >&2
      exit 2
    fi
    ;;
  implementation)
    if [ "$READ_ONLY" -eq 1 ] || [ "$PRODUCE_REVIEW" -eq 1 ]; then
      echo "ERROR: implementation role requires a write-capable non-review dispatch" >&2
      exit 2
    fi
    ;;
esac
RUNTIME_MODE="read"
[ "$ROLE" = "implementation" ] && RUNTIME_MODE="write"
# Tier-scaled watchdog budgets (#157): fill in only what the caller did NOT
# pass explicitly; any explicit CLI flag wins over the tier default. Tier is
# already known and validated at admission time — no evidence computation.
# Standard equals the watchdog's own hardcoded defaults. Tier-absent
# dispatches synthesize nothing, so watchdog env-var defaults apply exactly
# as before this change.
case "$TIER" in
  trivial)
    [ -z "$FIRST_PROGRESS_TIMEOUT" ] && FIRST_PROGRESS_TIMEOUT=120
    [ -z "$STALL_TIMEOUT" ] && STALL_TIMEOUT=90
    [ -z "$MAX_RETRIES" ] && MAX_RETRIES=1
    [ -z "$MAX_WALLCLOCK" ] && MAX_WALLCLOCK=1800
    ;;
  standard)
    [ -z "$FIRST_PROGRESS_TIMEOUT" ] && FIRST_PROGRESS_TIMEOUT=240
    [ -z "$STALL_TIMEOUT" ] && STALL_TIMEOUT=180
    [ -z "$MAX_RETRIES" ] && MAX_RETRIES=2
    [ -z "$MAX_WALLCLOCK" ] && MAX_WALLCLOCK=3600
    ;;
  full_cluster)
    [ -z "$FIRST_PROGRESS_TIMEOUT" ] && FIRST_PROGRESS_TIMEOUT=480
    [ -z "$STALL_TIMEOUT" ] && STALL_TIMEOUT=360
    [ -z "$MAX_RETRIES" ] && MAX_RETRIES=3
    [ -z "$MAX_WALLCLOCK" ] && MAX_WALLCLOCK=7200
    ;;
esac
if [ "$REREVIEW" -eq 1 ] && [ "$PRODUCE_REVIEW" -eq 0 ]; then
  echo "ERROR: --re-review requires --produce-review" >&2
  exit 2
fi
if [ -n "$REVIEW_CAPSULE" ] && [ "$REREVIEW" -eq 0 ]; then
  echo "ERROR: --review-capsule requires --re-review" >&2
  exit 2
fi
if { [ -n "$EXECUTION_PLAN" ] && [ -z "$PLAN_SEAT" ]; } || { [ -z "$EXECUTION_PLAN" ] && [ -n "$PLAN_SEAT" ]; }; then
  echo "ERROR: --execution-plan and --seat must be supplied together" >&2
  exit 2
fi
if [ -n "$EXECUTION_PLAN" ] && { [ "$READ_ONLY" -eq 1 ] || [ "$PRODUCE_REVIEW" -eq 1 ]; }; then
  echo "ERROR: execution-plan admission applies only to write seats" >&2
  exit 2
fi

[ -d "$WORKTREE" ] || { echo "ERROR: worktree does not exist: $WORKTREE" >&2; exit 2; }
ABS_WORKTREE="$(cd "$WORKTREE" && pwd)"
# Reject a non-Git target before probing or selecting an external runtime. This
# keeps the target validation seam deterministic and prevents a malformed
# worktree from entering any capability/preflight path.
if ! git -C "$ABS_WORKTREE" rev-parse --git-dir >/dev/null 2>&1; then
  echo "ERROR: not a git worktree (git rev-parse --git-dir failed): $ABS_WORKTREE" >&2
  exit 2
fi

# Classify write mode before any allocation or remote model compatibility
# preflight.  Route binding extends canonical redispatch admission only; later
# policy code consumes this one classification rather than re-reading mutable
# RUN/BLOCKER state at each allocator site.
RUN_FILE="$ABS_WORKTREE/.review/ISSUE-${ISSUE_N}-RUN.json"
BLOCKER_FILE="$ABS_WORKTREE/.review/ISSUE-${ISSUE_N}-BLOCKER.json"
DEFAULT_ROUND_STATE="$ABS_WORKTREE/.review/ISSUE-${ISSUE_N}-ROUND-STATE.json"
WRITE_ATTEMPT_DIR="$ABS_WORKTREE/.review/.write-dispatch-issue-${ISSUE_N}-started"
ADMISSION_KEY=""
REDISPATCH_REQUIRED=0
INITIAL_WRITE=0
if [ "$READ_ONLY" -eq 0 ] && [ "$PRODUCE_REVIEW" -eq 0 ]; then
  if [ -f "$BLOCKER_FILE" ] || [ -d "$WRITE_ATTEMPT_DIR" ]; then
    REDISPATCH_REQUIRED=1
  elif [ -f "$DEFAULT_ROUND_STATE" ] && node -e '
    try {
      const value=require(process.argv[1]);
      process.exit(value.round_control && Array.isArray(value.round_control.failures) && value.round_control.failures.length > 0 ? 0 : 1);
    } catch (e) { process.exit(1); }
  ' "$DEFAULT_ROUND_STATE"; then
    REDISPATCH_REQUIRED=1
  fi
  if [ "$REDISPATCH_REQUIRED" -eq 0 ]; then
    INITIAL_WRITE=1
  fi
fi

# A policy is an explicit host-side opt-in. Manual model/effort flags and
# dry-runs never inspect it, so their legacy paths cannot be blocked by stale
# host policy state. The policy reader is deliberately not the selector.
GIT_COMMON_RAW="$(git -C "$ABS_WORKTREE" rev-parse --git-common-dir)"
case "$GIT_COMMON_RAW" in
  /*) GIT_COMMON_DIR="$GIT_COMMON_RAW" ;;
  *) GIT_COMMON_DIR="$(cd "$ABS_WORKTREE/$GIT_COMMON_RAW" && pwd -P)" ;;
esac
ROUTE_SCRIPT="$SCRIPT_DIR/route.sh"
ROUTE_POLICY_ACTIVE=0
ROUTE_POLICY_JSON=""
ROUTE_POLICY_DIGEST=""
ROUTE_DIGEST=""
ROUTE_BINDING=""
if [ "$ROLE" = "implementation" ] && [ "$READ_ONLY" -eq 0 ] && [ "$PRODUCE_REVIEW" -eq 0 ] \
    && [ "$DRY_RUN" -eq 0 ] && [ "$MODEL_SUPPLIED" -eq 0 ] && [ "$EFFORT_SUPPLIED" -eq 0 ]; then
  ROUTE_POLICY_READ="$(bash "$ROUTE_SCRIPT" policy read --git-common-dir "$GIT_COMMON_DIR" --worktree "$ABS_WORKTREE")"
  route_policy_status=$?
  if [ "$route_policy_status" -ne 0 ]; then
    printf '%s\n' "$ROUTE_POLICY_READ"
    exit "$route_policy_status"
  fi
  ROUTE_POLICY_STATUS="$(node -e 'try { const v=JSON.parse(process.argv[1]); process.stdout.write(v.status || ""); } catch (e) { process.exit(2); }' "$ROUTE_POLICY_READ")" || {
    echo "ERROR: route_policy_invalid" >&2
    exit 3
  }
  if [ "$ROUTE_POLICY_STATUS" = "active" ]; then
    ROUTE_POLICY_ACTIVE=1
    ROUTE_POLICY_JSON="$(node -e 'try { const v=JSON.parse(process.argv[1]); if (!v.policy || typeof v.policy_digest !== "string") process.exit(2); process.stdout.write(JSON.stringify(v.policy)); } catch (e) { process.exit(2); }' "$ROUTE_POLICY_READ")" || {
      echo "ERROR: route_policy_invalid" >&2
      exit 3
    }
    ROUTE_POLICY_DIGEST="$(node -e 'try { const v=JSON.parse(process.argv[1]); if (!/^[a-f0-9]{64}$/.test(v.policy_digest || "")) process.exit(2); process.stdout.write(v.policy_digest); } catch (e) { process.exit(2); }' "$ROUTE_POLICY_READ")" || {
      echo "ERROR: route_policy_invalid" >&2
      exit 3
    }
    if [ "$INITIAL_WRITE" -eq 1 ]; then
      append_event admission_refused refused route_mode_unbound || true
      printf '%s\n' '{"status":"refused","code":"route_mode_unbound"}'
      exit 3
    fi
  elif [ "$ROUTE_POLICY_STATUS" != "bypass" ]; then
    echo "ERROR: route_policy_invalid" >&2
    exit 3
  fi
fi
RUNTIME_ADAPTER="$SCRIPT_DIR/agent-runtime.sh"
[ -x "$RUNTIME_ADAPTER" ] || { echo "ERROR: runtime_adapter_missing: $RUNTIME_ADAPTER" >&2; exit 2; }
RUNTIME_CAPABILITY_JSON="$(bash "$RUNTIME_ADAPTER" capabilities --runtime "$RUNTIME" 2>/dev/null)"
runtime_capability_status=$?
if [ "$runtime_capability_status" -ne 0 ] || [ -z "$RUNTIME_CAPABILITY_JSON" ]; then
  echo "ERROR: required_runtime_capability_missing: $RUNTIME capability probe failed; no fallback attempted" >&2
  exit 2
fi
RUNTIME_BIN_PIN="$(node - "$RUNTIME_CAPABILITY_JSON" "$RUNTIME" "$ROLE" <<'NODE'
try {
  const value = JSON.parse(process.argv[2]);
  const expected = process.argv[3];
  const role = process.argv[4];
  if (value.runtime !== expected || value.available !== true || !Array.isArray(value.roles) || !value.roles.includes(role)) process.exit(2);
  if (typeof value.executable !== "string" || !value.executable.startsWith("/")) process.exit(2);
  process.stdout.write(value.executable);
} catch (error) { process.exit(2); }
NODE
)" || {
  reason="$(node -e 'try { process.stdout.write(JSON.parse(process.argv[1]).reason_code || "required_runtime_capability_missing") } catch (e) { process.stdout.write("required_runtime_capability_missing") }' "$RUNTIME_CAPABILITY_JSON")"
  echo "ERROR: $reason: runtime=$RUNTIME role=$ROLE unavailable; no fallback attempted" >&2
  exit 2
}
# Permission-file resolution is Runtime-axis logic: delegate to the runtime
# adapter instead of branching on a runtime name here. Runtimes without a
# permission file resolve to an empty string.
if [ -n "$RUNTIME_PERMISSION_FILE" ]; then
  RESOLVED_PERMISSION_FILE="$(bash "$RUNTIME_ADAPTER" permission-file --runtime "$RUNTIME" --role "$ROLE" --cwd "$ABS_WORKTREE" --opencode-permission-file "$RUNTIME_PERMISSION_FILE")"
else
  RESOLVED_PERMISSION_FILE="$(bash "$RUNTIME_ADAPTER" permission-file --runtime "$RUNTIME" --role "$ROLE" --cwd "$ABS_WORKTREE")"
fi
[ -n "$RESOLVED_PERMISSION_FILE" ] && RUNTIME_PERMISSION_FILE="$RESOLVED_PERMISSION_FILE"
if [ "$REREVIEW" -eq 1 ]; then
  if [ -z "$REVIEW_CAPSULE" ]; then
    echo "ERROR: re-review requires --review-capsule for the current HEAD and manifest revision" >&2
    exit 2
  fi
  case "$REVIEW_CAPSULE" in /*) ABS_REVIEW_CAPSULE="$REVIEW_CAPSULE" ;; *) ABS_REVIEW_CAPSULE="$ABS_WORKTREE/$REVIEW_CAPSULE" ;; esac
  CANONICAL_REVIEW_CAPSULE="$ABS_WORKTREE/.review/ISSUE-${ISSUE_N}-REVIEW-CAPSULE.json"
  CANONICAL_REVIEW_PROMPT="$ABS_WORKTREE/.review/ISSUE-${ISSUE_N}-REVIEW-CAPSULE.md"
  if ! node - "$ABS_REVIEW_CAPSULE" "$CANONICAL_REVIEW_CAPSULE" <<'NODE'
const fs = require("fs");
try {
  if (fs.realpathSync(process.argv[2]) !== fs.realpathSync(process.argv[3])) process.exit(2);
} catch (error) {
  process.exit(2);
}
NODE
  then
    echo "ERROR: re-review requires canonical capsule JSON $CANONICAL_REVIEW_CAPSULE" >&2
    exit 2
  fi
  if [ -z "$PROMPT_FILE" ]; then
    PROMPT_FILE="$CANONICAL_REVIEW_PROMPT"
  fi
  case "$PROMPT_FILE" in /*) REREVIEW_PROMPT="$PROMPT_FILE" ;; *) REREVIEW_PROMPT="$ABS_WORKTREE/$PROMPT_FILE" ;; esac
  if ! node - "$REREVIEW_PROMPT" "$CANONICAL_REVIEW_PROMPT" <<'NODE'
const fs = require("fs");
try {
  if (fs.realpathSync(process.argv[2]) !== fs.realpathSync(process.argv[3])) process.exit(2);
} catch (error) {
  process.exit(2);
}
NODE
  then
    echo "ERROR: re-review prompt must be canonical capsule Markdown $CANONICAL_REVIEW_PROMPT" >&2
    exit 2
  fi
  if ! bash "$SCRIPT_DIR/review-capsule.sh" --worktree "$ABS_WORKTREE" --capsule "$ABS_REVIEW_CAPSULE" >/dev/null; then
    echo "ERROR: re-review capsule is stale or invalid" >&2
    exit 1
  fi
fi

# Allocation is a pure preflight. Parse and validate it before write-admission
# markers, launch runners, or transport side effects. Implementation allocation
# remains Codex-only; reviewer allocation is runtime-specific and still needs
# the selected runtime's independent compatibility preflight.
# resolve_model_allocation <role> <runner>: invoke model-alloc once and parse
# its allocation into ALLOC_RESOLVED_MODEL/ALLOC_RESOLVED_EFFORT. model-alloc
# owns config-path default resolution, so no caller duplicates it.
resolve_model_allocation() {
  local alloc_role="$1" alloc_runner="$2" alloc_json alloc_fields old_ifs
  MODEL_ALLOC="$SCRIPT_DIR/model-alloc.sh"
  [ -x "$MODEL_ALLOC" ] || { echo "ERROR: model allocator is missing or not executable: $MODEL_ALLOC" >&2; exit 2; }
  alloc_json="$(bash "$MODEL_ALLOC" --role "$alloc_role" --runner "$alloc_runner")" || { echo "ERROR: model allocation denied" >&2; exit 2; }
  alloc_fields="$(node -e 'const { effortValid } = require(process.argv[1]); try { const v=JSON.parse(process.argv[2]), key=process.argv[3] === "reviewer" ? "review" : "impl", model=v[key + "_model"], effort=v[key + "_effort"]; if (typeof model !== "string" || !effortValid(model, effort)) process.exit(2); process.stdout.write(model + "\t" + effort); } catch (e) { process.exit(2); }' "$RUNTIME_REGISTRY" "$alloc_json" "$alloc_role")" || { echo "ERROR: model allocator returned invalid JSON" >&2; exit 2; }
  old_ifs=$IFS; IFS="$(printf '\t')"; set -- $alloc_fields; IFS=$old_ifs
  ALLOC_RESOLVED_MODEL="${1:-}"
  ALLOC_RESOLVED_EFFORT="${2:-}"
}
if [ "$ALLOCATE" -eq 1 ]; then
  resolve_model_allocation "$ALLOCATOR_ROLE" "$RUNTIME"
  MODEL="$ALLOC_RESOLVED_MODEL"
  EFFORT="$ALLOC_RESOLVED_EFFORT"
  if [ -z "$MODEL" ]; then
    echo "ERROR: allocator returned no model for runtime=$RUNTIME; refusing dispatch" >&2
    exit 2
  fi
fi

# Every write seat must carry an explicit, capability-checked model/effort
# tuple. When operators omit both --model and --allocate, resolve the normal
# implementation allocation through the same model allocator (no runtime
# default and no fallback launch).
if [ "$ROLE" = "implementation" ] && [ -z "$MODEL" ]; then
  resolve_model_allocation implementation "$RUNTIME"
  MODEL="$ALLOC_RESOLVED_MODEL"
  [ -n "$EFFORT" ] || EFFORT="$ALLOC_RESOLVED_EFFORT"
  [ -n "$MODEL" ] && [ -n "$EFFORT" ] || { echo "ERROR: default allocation did not resolve model and effort" >&2; exit 2; }
fi

# Resolve one explicit effort for the selected model before compatibility
# probing, then forward that exact value to the runtime launch. This avoids a
# preflight using a fallback tier while the runtime silently chooses its own.
if [ -n "$MODEL" ] && [ -z "$EFFORT" ]; then
  case "$RUNTIME" in
    codex) EFFORT="low" ;;
    claude|opencode) EFFORT="medium" ;;
  esac
fi

if [ -z "$PROMPT_FILE" ]; then
  PROMPT_FILE="$ABS_WORKTREE/.review/ISSUE-${ISSUE_N}-PROMPT.md"
  # Compatibility only: existing operators may still have a pre-v0.20 .txt
  # prompt. New CONDUCTOR authoring writes .md; an explicit --prompt-file is
  # always authoritative.
  if [ ! -f "$PROMPT_FILE" ] && [ -f "$ABS_WORKTREE/.review/ISSUE-${ISSUE_N}-PROMPT.txt" ]; then
    PROMPT_FILE="$ABS_WORKTREE/.review/ISSUE-${ISSUE_N}-PROMPT.txt"
  fi
fi
case "$PROMPT_FILE" in
  /*) ABS_PROMPT_FILE="$PROMPT_FILE" ;;
  *) ABS_PROMPT_FILE="$ABS_WORKTREE/$PROMPT_FILE" ;;
esac

[ -f "$ABS_PROMPT_FILE" ] || {
  echo "ERROR: prompt file not found: $ABS_PROMPT_FILE" >&2
  exit 2
}

# New prompt authoring uses every non-.txt path. Require the schema-derived
# output contract before any plan, write marker, runner, or transport
# admission. The pre-v0.20 .txt path remains the only legacy exemption.
case "$ABS_PROMPT_FILE" in
  *.txt) ;;
  *)
    case "$ROLE" in
      reviewer) OUTPUT_CONTRACT_ROLE="reviewer" ;;
      implementation) OUTPUT_CONTRACT_ROLE="implementation" ;;
      architect) OUTPUT_CONTRACT_ROLE="architect" ;;
      *) OUTPUT_CONTRACT_ROLE="" ;;
    esac
    if [ -n "$OUTPUT_CONTRACT_ROLE" ]; then
      OUTPUT_CONTRACT="$PRODUCT_HOME/scripts/output-contract.sh"
      if [ ! -x "$OUTPUT_CONTRACT" ] || ! bash "$OUTPUT_CONTRACT" check --role "$OUTPUT_CONTRACT_ROLE" --prompt-file "$ABS_PROMPT_FILE" >/dev/null; then
        echo "ERROR: output-contract admission denied: prompt must contain the exact schema-derived contract for role '$OUTPUT_CONTRACT_ROLE'." >&2
        printf 'Fix: bash %q render --role %q >> %q\n' "$OUTPUT_CONTRACT" "$OUTPUT_CONTRACT_ROLE" "$ABS_PROMPT_FILE" >&2
        printf 'Then verify: bash %q check --role %q --prompt-file %q\n' "$OUTPUT_CONTRACT" "$OUTPUT_CONTRACT_ROLE" "$ABS_PROMPT_FILE" >&2
        exit 1
      fi
    fi
    ;;
esac

# Compatibility is proven before any adapter launch, runner creation, or write
# admission. The probe is intentionally tiny and may be replaced by a
# host-owned command for offline/managed runtimes. Policy-routed dispatches
# defer this until canonical redispatch facts have produced a Route digest.
model_compatibility_preflight() {
  [ "$DRY_RUN" -eq 0 ] && [ -n "$MODEL" ] || return 0
  if [ -n "${AGENT_WORKFLOW_MODEL_PROBE_CMD:-}" ]; then
    if ! RUNTIME="$RUNTIME" MODEL="$MODEL" EFFORT="$EFFORT" sh -c "$AGENT_WORKFLOW_MODEL_PROBE_CMD" </dev/null >/dev/null 2>&1; then
      echo "ERROR: model_compatibility_unavailable: selected $RUNTIME model '$MODEL' failed the preflight; no admission or fallback attempted" >&2
      return 2
    fi
  elif ! case "$RUNTIME" in
    codex) "$RUNTIME_BIN_PIN" exec --skip-git-repo-check -m "$MODEL" -c "model_reasoning_effort=\"$EFFORT\"" "reply exactly OK" </dev/null >/dev/null 2>&1 ;;
    claude) "$RUNTIME_BIN_PIN" --print --permission-mode plan --output-format text --model "$MODEL" --effort "$EFFORT" "reply exactly OK" </dev/null >/dev/null 2>&1 ;;
    opencode) OPENCODE_CONFIG_CONTENT="$(cat "$RUNTIME_PERMISSION_FILE")" "$RUNTIME_BIN_PIN" run --dir "$ABS_WORKTREE" --format default --agent agent-workflow --model "$MODEL" --variant "$EFFORT" "reply exactly OK" </dev/null >/dev/null 2>&1 ;;
    # A registered runtime with no argv branch here must fail closed, not
    # fall through the case as a silent pass (Opus scoped review, #135).
    *) false ;;
  esac; then
    echo "ERROR: model_compatibility_unavailable: selected $RUNTIME model '$MODEL' failed the preflight; no admission or fallback attempted" >&2
    return 2
  fi
  return 0
}
if [ "$ROUTE_POLICY_ACTIVE" -eq 0 ]; then
  model_compatibility_preflight || exit $?
fi

if [ -z "$WS_NAME" ]; then
  if [ "$(node "$RUNTIME_REGISTRY" ws-short-impl "$RUNTIME")" = "true" ] && [ "$ROLE" = "implementation" ]; then
    WS_NAME="codex-${ISSUE_N}"
  else
    WS_NAME="$RUNTIME-$ROLE-${ISSUE_N}"
  fi
fi

# Capability proof is deliberately before all write-admission markers and
# runner creation. A selected adapter that cannot prove its exact typed-seat
# contract fails closed; the core never tries another adapter.
ADAPTER_SCRIPT="$SCRIPT_DIR/adapters/$ADAPTER.sh"
[ -x "$ADAPTER_SCRIPT" ] || { echo "ERROR: required_capability_missing: adapter is missing or not executable: $ADAPTER_SCRIPT" >&2; exit 2; }
ADAPTER_VERSION="dry-run"
ADAPTER_CAPABILITIES_JSON="[]"
ADAPTER_AMBIGUOUS_LIFECYCLES_JSON="[]"
if [ "$DRY_RUN" -eq 0 ]; then
  CAPABILITY_JSON="$(bash "$ADAPTER_SCRIPT" capabilities --worktree "$ABS_WORKTREE" 2>/dev/null)"
  capability_status=$?
  if [ "$capability_status" -ne 0 ] || [ -z "$CAPABILITY_JSON" ]; then
    echo "ERROR: required_capability_missing: $ADAPTER capability probe failed" >&2
    exit 2
  fi
  CAPABILITY_FIELDS="$(node "$SCRIPT_DIR/lib/capability-result.cjs" dispatch "$CAPABILITY_JSON" "$ADAPTER")"
  if [ "$?" -ne 0 ]; then
    reason="$(node -e 'try { process.stdout.write(JSON.parse(process.argv[1]).reason_code || "required_capability_missing") } catch (e) { process.stdout.write("required_capability_missing") }' "$CAPABILITY_JSON")"
    echo "ERROR: $reason: selected $ADAPTER adapter is unavailable; no fallback attempted" >&2
    exit 2
  fi
  ADAPTER_VERSION="${CAPABILITY_FIELDS%%	*}"
  CAPABILITY_FIELDS_REST="${CAPABILITY_FIELDS#*	}"
  ADAPTER_CAPABILITIES_JSON="${CAPABILITY_FIELDS_REST%%	*}"
  ADAPTER_AMBIGUOUS_LIFECYCLES_JSON="${CAPABILITY_FIELDS_REST#*	}"
fi

# Preserve the legacy no-policy error ordering: mode classification is early,
# but its initial-write contract remains checked where callers historically saw
# it. A later opted-in route check may refuse an initial write earlier without
# altering this compatibility path.
if [ "$INITIAL_WRITE" -eq 1 ]; then
  case "$TIER" in
    trivial)
      if [ -n "$ROUND_STATE" ] || [ -n "$MANIFEST_REVISION" ]; then
        echo "ERROR: Trivial initial write uses the pr_draft-only contract, not ROUND-STATE" >&2
        exit 2
      fi
      ;;
    standard|full_cluster)
      if [ -z "$ROUND_STATE" ] || [ -z "$MANIFEST_REVISION" ]; then
        echo "ERROR: $TIER initial write requires --round-state and --manifest-revision" >&2
        exit 2
      fi
      ;;
    *)
      echo "ERROR: initial write requires --tier trivial|standard|full_cluster" >&2
      exit 2
      ;;
  esac
fi

if [ "$READ_ONLY" -eq 0 ] && [ "$PRODUCE_REVIEW" -eq 0 ] && [ -n "$ROUND_STATE" ]; then
  case "$ROUND_STATE" in
    /*) ABS_ROUND_STATE="$ROUND_STATE" ;;
    *) ABS_ROUND_STATE="$ABS_WORKTREE/$ROUND_STATE" ;;
  esac
  if [ ! -r "$ABS_ROUND_STATE" ]; then
    echo "ERROR: ROUND-STATE admission denied: canonical input is unreadable" >&2
    exit 2
  fi
  node - "$ABS_ROUND_STATE" "$DEFAULT_ROUND_STATE" <<'NODE'
const fs = require("fs");
const [supplied, canonical] = process.argv.slice(2);
try {
  if (fs.realpathSync(supplied) !== fs.realpathSync(canonical)) process.exit(2);
} catch (error) {
  process.exit(2);
}
NODE
  if [ "$?" -ne 0 ]; then
    echo "ERROR: ROUND-STATE admission denied: use canonical path $DEFAULT_ROUND_STATE" >&2
    exit 2
  fi
fi
if [ "$DRY_RUN" -eq 0 ] && [ "$REDISPATCH_REQUIRED" -eq 1 ] && [ -f "$BLOCKER_FILE" ]; then
  if ! node "$SCRIPT_DIR/lib/blocker-check.cjs" "$BLOCKER_FILE" "$SCRIPT_DIR/../schemas/blocker.schema.json" "$SCHEMA_VALIDATOR" "$ISSUE_N" "$ABS_WORKTREE" >/dev/null 2>&1; then
    if [ -z "${ABS_ROUND_STATE:-}" ]; then
      echo "ERROR: malformed pre-existing BLOCKER requires canonical ROUND-STATE for quarantine recovery" >&2
      exit 2
    fi
    if ! node "$SCRIPT_DIR/lib/blocker-recovery.cjs" "$BLOCKER_FILE" "$ABS_ROUND_STATE" "$ISSUE_N" >/dev/null 2>&1; then
      echo "ERROR: malformed pre-existing BLOCKER recovery could not preserve raw bytes and update ROUND-STATE" >&2
      exit 2
    fi
    echo "dispatch-core: quarantined malformed pre-existing BLOCKER; canonical worker evidence remains absent" >&2
  fi
fi
if [ -n "$EXECUTION_PLAN" ]; then
  if [ -z "$ROUND_STATE" ] || [ -z "$MANIFEST_REVISION" ]; then
    echo "ERROR: planned write seat requires --round-state and --manifest-revision" >&2
    exit 2
  fi
  case "$EXECUTION_PLAN" in
    /*) ABS_EXECUTION_PLAN="$EXECUTION_PLAN" ;;
    *) ABS_EXECUTION_PLAN="$ABS_WORKTREE/$EXECUTION_PLAN" ;;
  esac
  CANONICAL_EXECUTION_PLAN="$ABS_WORKTREE/.review/ISSUE-${ISSUE_N}-EXECUTION-PLAN.json"
  node - "$ABS_EXECUTION_PLAN" "$CANONICAL_EXECUTION_PLAN" <<'NODE'
const fs = require("fs");
try { if (fs.realpathSync(process.argv[2]) !== fs.realpathSync(process.argv[3])) process.exit(2); }
catch (error) { process.exit(2); }
NODE
  if [ "$?" -ne 0 ]; then
    echo "ERROR: plan admission denied: use canonical path $CANONICAL_EXECUTION_PLAN" >&2
    exit 2
  fi
  if [ ! -f "$PARALLEL_PLAN" ]; then
    echo "ERROR: plan admission gate is missing or not executable" >&2
    exit 2
  fi
  PLAN_ADMISSION="$(node "$PARALLEL_PLAN" admit --plan "$ABS_EXECUTION_PLAN" --target "$ABS_WORKTREE" --round-state "$ABS_ROUND_STATE" --issue "$ISSUE_N" --revision "$MANIFEST_REVISION" --seat "$PLAN_SEAT" --consume false)"
  plan_status=$?
  if [ "$plan_status" -ne 0 ]; then
    echo "ERROR: plan admission denied: $PLAN_ADMISSION" >&2
    exit "$plan_status"
  fi
fi
if [ "$INITIAL_WRITE" -eq 1 ] && [ "$TIER" != "trivial" ]; then
  if [ ! -r "$ROUND_STATE_SCHEMA" ] || [ ! -r "$SCHEMA_VALIDATOR" ]; then
    echo "ERROR: initial ROUND-STATE admission denied: schema validator is unreadable" >&2
    exit 2
  fi
  node - "$ABS_ROUND_STATE" "$ROUND_STATE_SCHEMA" "$SCHEMA_VALIDATOR" "$ISSUE_N" "$MANIFEST_REVISION" "$ABS_WORKTREE" "$TIER" <<'NODE'
const fs = require("fs");
const { execFileSync } = require("child_process");
const [stateFile, schemaFile, validatorFile, issueNumber, manifestRevision, worktree, tier] = process.argv.slice(2);
try {
  const state = JSON.parse(fs.readFileSync(stateFile, "utf8"));
  const schema = JSON.parse(fs.readFileSync(schemaFile, "utf8"));
  const { validate } = require(validatorFile);
  if (validate(schema, state).length || state.lifecycle !== "active") process.exit(2);
  if (String(state.issue.number) !== issueNumber || String(state.revision) !== manifestRevision) process.exit(2);
  if (state.tier.name !== tier) process.exit(2);
  if (fs.realpathSync(state.worktree_path) !== fs.realpathSync(worktree)) process.exit(2);
  const liveHead = execFileSync("git", ["-C", worktree, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
  if (state.head_sha !== liveHead) process.exit(2);
  const liveBase = execFileSync("git", ["-C", worktree, "merge-base", "HEAD", state.base_branch], { encoding: "utf8" }).trim();
  if (state.base_sha !== liveBase) process.exit(2);
} catch (error) {
  process.exit(2);
}
NODE
  if [ "$?" -ne 0 ]; then
    echo "ERROR: initial ROUND-STATE admission denied: schema or lifecycle is invalid" >&2
    exit 2
  fi
  require_standard_artifact_pointers "$ABS_ROUND_STATE" || exit $?
fi
# Scope declarations must point at the base tree before any write admission.
# A glob may authorize modifications to existing scope, but never create an
# arbitrary new path; exact new_file_allowlist is the only creation authority.
# For a redispatch, first bind the supplied state to the CLI issue/worktree:
# an alien state must report that identity error rather than trying to inspect
# its unrelated base SHA in this worktree.
if [ "$READ_ONLY" -eq 0 ] && [ "$REDISPATCH_REQUIRED" -eq 0 ] && [ -n "${ABS_ROUND_STATE:-}" ]; then
  if [ ! -r "$TOUCH_ALLOWLIST_PREFLIGHT" ]; then
    echo "ERROR: touch allowlist preflight is missing or unreadable" >&2
    exit 2
  fi
  if ! node "$TOUCH_ALLOWLIST_PREFLIGHT" "$ABS_ROUND_STATE" "$ABS_WORKTREE"; then
    echo "ERROR: dispatch touch allowlist preflight denied" >&2
    exit 2
  fi
fi
if [ "$REDISPATCH_REQUIRED" -eq 1 ]; then
  if [ -z "$ROUND_STATE" ] || [ -z "$MANIFEST_REVISION" ]; then
    echo "ERROR: write redispatch requires --round-state and --manifest-revision" >&2
    exit 2
  fi
  if [ ! -x "$REDISPATCH_CHECK" ]; then
    echo "ERROR: redispatch gate is missing or not executable: $REDISPATCH_CHECK" >&2
    exit 2
  fi
  ADMISSION_JSON="$(bash "$REDISPATCH_CHECK" --round-state "$ABS_ROUND_STATE" --manifest-revision "$MANIFEST_REVISION" 2>/dev/null)"
  ADMISSION_EXIT=$?
  if [ "$ADMISSION_EXIT" -ne 0 ]; then
    echo "ERROR: redispatch gate denied: $ADMISSION_JSON" >&2
    exit "$ADMISSION_EXIT"
  fi
  require_standard_artifact_pointers "$ABS_ROUND_STATE" || exit $?
  ADMISSION_FIELDS="$(node -e '
    try {
      const value=JSON.parse(process.argv[1]);
      process.stdout.write([value.redispatch_allowed, value.dispatch_mode || "", value.classified_failures, value.admission_key || "", value.issue_number, value.worktree_path || ""].join("\t"));
    } catch (e) { process.exit(2); }
  ' "$ADMISSION_JSON")"
  ADMISSION_PARSE_EXIT=$?
  if [ "$ADMISSION_PARSE_EXIT" -ne 0 ]; then
    echo "ERROR: redispatch gate returned invalid JSON" >&2
    exit 2
  fi
  oldIFS=$IFS
  IFS="$(printf '\t')"
  set -- $ADMISSION_FIELDS
  IFS=$oldIFS
  ADMISSION_ALLOWED="${1:-false}"
  ADMISSION_MODE="${2:-}"
  CLASSIFIED_FAILURES="${3:-0}"
  ADMISSION_KEY="${4:-}"
  ADMISSION_ISSUE="${5:-}"
  ADMISSION_WORKTREE="${6:-}"
  case "$CLASSIFIED_FAILURES" in
    ''|*[!0-9]*)
      echo "ERROR: redispatch gate returned an invalid failure count" >&2
      exit 2
      ;;
  esac
  case "$ADMISSION_KEY" in
    ''|*[!A-Za-z0-9._-]*)
      echo "ERROR: redispatch gate returned an invalid admission key" >&2
      exit 2
      ;;
  esac
  if [ "$ADMISSION_ALLOWED" != "true" ] || [ "$CLASSIFIED_FAILURES" -lt 1 ] || [ -z "$ADMISSION_KEY" ]; then
    echo "ERROR: redispatch gate did not authorize a classified implementation failure" >&2
    exit 2
  fi
  REAL_WORKTREE="$(cd "$ABS_WORKTREE" && pwd -P)"
  if [ "$ADMISSION_ISSUE" != "$ISSUE_N" ] || [ "$ADMISSION_WORKTREE" != "$REAL_WORKTREE" ]; then
    echo "ERROR: redispatch admission does not match the dispatched issue and worktree" >&2
    exit 2
  fi

  if [ ! -r "$TOUCH_ALLOWLIST_PREFLIGHT" ]; then
    echo "ERROR: touch allowlist preflight is missing or unreadable" >&2
    exit 2
  fi
  if ! node "$TOUCH_ALLOWLIST_PREFLIGHT" "$ABS_ROUND_STATE" "$ABS_WORKTREE"; then
    echo "ERROR: dispatch touch allowlist preflight denied" >&2
    exit 2
  fi

  # Validate the worker-facing AC block after canonical redispatch admission
  # is known, but before consuming its durable issue/ordinal admission.
  if [ ! -x "$PROMPT_AC_CHECK" ]; then
    echo "ERROR: prompt AC gate is missing or not executable: $PROMPT_AC_CHECK" >&2
    exit 2
  fi
  if ! bash "$PROMPT_AC_CHECK" --round-state "$ABS_ROUND_STATE" --manifest-revision "$MANIFEST_REVISION" --prompt-file "$ABS_PROMPT_FILE"; then
    echo "ERROR: prompt AC gate denied dispatch" >&2
    exit 1
  fi

  # The pure selector consumes only canonical admission facts and the tuple
  # already produced by model-alloc. It runs before the remote model probe and
  # before any durable admission, marker, runner, or transport side effect.
  if [ "$ROUTE_POLICY_ACTIVE" -eq 1 ]; then
    ROUTE_DEMAND="$(node - "$ABS_ROUND_STATE" "$RUNTIME" "$ROLE" "$TIER" "$ADMISSION_KEY" <<'NODE'
const fs = require("fs");
try {
  const [stateFile, runtime, role, suppliedTier, admissionKey] = process.argv.slice(2);
  const state = JSON.parse(fs.readFileSync(stateFile, "utf8"));
  const tier = state.tier && state.tier.name;
  if (!["trivial", "standard", "full_cluster"].includes(tier)
      || (suppliedTier && suppliedTier !== tier)) process.exit(2);
  const value = {
    runtime, role, write_mode: "canonical_redispatch", tier,
    issue: state.issue && state.issue.number,
    worktree_path: state.worktree_path,
    head_sha: state.head_sha,
    base_sha: state.base_sha,
    round_state_revision: state.revision,
    admission_key: admissionKey
  };
  process.stdout.write(JSON.stringify(value));
} catch (_) { process.exit(2); }
NODE
)" || { append_event admission_refused refused route_demand_invalid || true; printf '%s\n' '{"status":"refused","code":"route_demand_invalid"}'; exit 3; }
    ROUTE_PROBE="$(AGENT_WORKFLOW_ROUTE_EXECUTABLE="$RUNTIME_BIN_PIN" AGENT_WORKFLOW_ROUTE_CAPABILITY_JSON="$RUNTIME_CAPABILITY_JSON" AGENT_WORKFLOW_ROUTE_PERMISSION_FILE="$RUNTIME_PERMISSION_FILE" bash "$ROUTE_SCRIPT" probe --runtime "$RUNTIME" --depth static)"
    route_probe_status=$?
    if [ "$route_probe_status" -ne 0 ]; then
      printf '%s\n' "$ROUTE_PROBE"
      exit "$route_probe_status"
    fi
    ROUTE_OFFER="$(node -e 'try { const value=JSON.parse(process.argv[1]); if (value.status !== "admitted" || !value.offer || typeof value.offer !== "object") process.exit(2); process.stdout.write(JSON.stringify(value.offer)); } catch (_) { process.exit(2); }' "$ROUTE_PROBE")" || { append_event admission_refused refused runner_offer_invalid || true; printf '%s\n' '{"status":"refused","code":"runner_offer_invalid"}'; exit 3; }
    ROUTE_ALLOC="$(node - "$MODEL" "$EFFORT" <<'NODE'
const [model, effort] = process.argv.slice(2);
if (!model || !effort) process.exit(2);
process.stdout.write(JSON.stringify({ model, effort }));
NODE
)" || { append_event admission_refused refused route_demand_invalid || true; printf '%s\n' '{"status":"refused","code":"route_demand_invalid"}'; exit 3; }
    ROUTE_RESULT="$(bash "$ROUTE_SCRIPT" decide --demand "$ROUTE_DEMAND" --offer "$ROUTE_OFFER" --policy "$ROUTE_POLICY_JSON" --policy-digest "$ROUTE_POLICY_DIGEST" --model-alloc "$ROUTE_ALLOC" --now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')")"
    route_status=$?
    if [ "$route_status" -ne 0 ]; then
      printf '%s\n' "$ROUTE_RESULT"
      exit "$route_status"
    fi
    ROUTE_DIGEST="$(node -e 'try { const v=JSON.parse(process.argv[1]); if (v.status !== "admitted" || !/^[a-f0-9]{64}$/.test(v.route_digest || "")) process.exit(2); process.stdout.write(v.route_digest); } catch (e) { process.exit(2); }' "$ROUTE_RESULT")" || {
      append_event admission_refused refused route_demand_invalid || true
      printf '%s\n' '{"status":"refused","code":"route_demand_invalid"}'
      exit 3
    }
    ROUTE_BINDING="$(node - "$RUNTIME_REGISTRY" "$ROUTE_RESULT" "$ROUTE_DEMAND" "$ADAPTER" <<'NODE'
try {
  const [registryPath, resultJson, demandJson, transport] = process.argv.slice(2);
  const { effortValid } = require(registryPath);
  const result = JSON.parse(resultJson), demand = JSON.parse(demandJson);
  if (result.status !== "admitted" || !/^[a-f0-9]{64}$/.test(result.route_digest || "")
      || !/^[a-f0-9]{64}$/.test(result.policy_digest || "")
      || !result.selected || typeof result.selected.model !== "string"
      || !effortValid(result.selected.model, result.selected.effort || "")
      || !Array.isArray(result.reasons) || !result.reasons.length) process.exit(2);
  process.stdout.write(JSON.stringify({
    route_digest: result.route_digest, policy_digest: result.policy_digest,
    runtime: demand.runtime, role: demand.role, tier: demand.tier, transport,
    selection_basis: "ordered_policy", decision_reason_codes: result.reasons,
    selected: result.selected
  }));
} catch (_) { process.exit(2); }
NODE
)" || { append_event admission_refused refused route_demand_invalid || true; printf '%s\n' '{"status":"refused","code":"route_demand_invalid"}'; exit 3; }
    model_compatibility_preflight || exit $?
  fi

  echo "dispatch-core: redispatch admission: mode=$ADMISSION_MODE key=$ADMISSION_KEY"
  if [ "$DRY_RUN" -eq 0 ]; then
    ADMISSION_ROOT="$GIT_COMMON_DIR/agent-workflow/redispatch-admissions"
    if ! mkdir -p "$ADMISSION_ROOT" 2>/dev/null; then
      echo "ERROR: cannot create durable redispatch admission store" >&2
      exit 2
    fi
    ISSUE_ADMISSION_LOCK="$ADMISSION_ROOT/.issue-${ISSUE_N}-lock"
    # Publish an owner-bearing lock directory atomically.  A direct mkdir
    # followed by writing .admission-lock.json leaves an empty permanent lock
    # if this shell is SIGKILLed in between.
    if ! node "$SCRIPT_DIR/lib/admission-recover.cjs" acquire-lock "$ISSUE_ADMISSION_LOCK/.admission-lock.json" "$ADMISSION_ROOT/issue-${ISSUE_N}-integrated-fix" "$ABS_ROUND_STATE" "$ISSUE_N" "$ADMISSION_KEY" "$$" >/dev/null 2>&1; then
      if ! node "$SCRIPT_DIR/lib/admission-recover.cjs" recover-lock "$ISSUE_ADMISSION_LOCK/.admission-lock.json" "$ADMISSION_ROOT/issue-${ISSUE_N}-integrated-fix" "$ABS_ROUND_STATE" "$ISSUE_N" >/dev/null 2>&1 || ! node "$SCRIPT_DIR/lib/admission-recover.cjs" acquire-lock "$ISSUE_ADMISSION_LOCK/.admission-lock.json" "$ADMISSION_ROOT/issue-${ISSUE_N}-integrated-fix" "$ABS_ROUND_STATE" "$ISSUE_N" "$ADMISSION_KEY" "$$" >/dev/null 2>&1; then
        echo "ERROR: concurrent redispatch admission update for issue $ISSUE_N" >&2
        exit 1
      fi
    fi
    ADMISSION_DIR="$ADMISSION_ROOT/$ADMISSION_KEY"
    INTEGRATED_DIR="$ADMISSION_ROOT/issue-${ISSUE_N}-integrated-fix"
    if [ -n "$ROUTE_DIGEST" ]; then
      RECOVERY_OUTPUT="$(node "$SCRIPT_DIR/lib/admission-recover.cjs" recover "$INTEGRATED_DIR" "$ADMISSION_DIR" "$ABS_ROUND_STATE" "$ISSUE_N" "$ADMISSION_KEY" --route-digest "$ROUTE_DIGEST")"
    else
      RECOVERY_OUTPUT="$(node "$SCRIPT_DIR/lib/admission-recover.cjs" recover "$INTEGRATED_DIR" "$ADMISSION_DIR" "$ABS_ROUND_STATE" "$ISSUE_N")"
    fi
    recovery_status=$?
    if [ "$recovery_status" -ne 0 ]; then
      node "$SCRIPT_DIR/lib/admission-recover.cjs" release-lock "$ISSUE_ADMISSION_LOCK/.admission-lock.json" >/dev/null 2>&1 || true
      if [ "$recovery_status" -eq 3 ]; then
        printf '%s\n' "$RECOVERY_OUTPUT"
        exit 3
      fi
      echo "ERROR: could not recover interrupted integrated admission" >&2
      exit 2
    fi
    if [ "$ADMISSION_MODE" = "integrated_fix" ]; then
      # Journal before visibility for both the singleton and ordinal.  A
      # SIGKILL can therefore be recovered as a current prepared record;
      # metadata-free directories remain legacy consumed sentinels.
      if [ -n "$ROUTE_DIGEST" ]; then
        node "$SCRIPT_DIR/lib/admission-recover.cjs" publish "$ADMISSION_ROOT" "$INTEGRATED_DIR" "$ABS_ROUND_STATE" "$ISSUE_N" "$ADMISSION_KEY" "$$" integrated --route-digest "$ROUTE_DIGEST" --route-binding "$ROUTE_BINDING" >/dev/null 2>&1
      else
        node "$SCRIPT_DIR/lib/admission-recover.cjs" publish "$ADMISSION_ROOT" "$INTEGRATED_DIR" "$ABS_ROUND_STATE" "$ISSUE_N" "$ADMISSION_KEY" "$$" integrated >/dev/null 2>&1
      fi
      if [ "$?" -ne 0 ]; then
        node "$SCRIPT_DIR/lib/admission-recover.cjs" release-lock "$ISSUE_ADMISSION_LOCK/.admission-lock.json" >/dev/null 2>&1 || true
        echo "ERROR: redispatch admission already consumed: integrated fix admission already consumed for issue $ISSUE_N" >&2
        exit 1
      fi
      if [ "${AGENT_WORKFLOW_ADMISSION_KILL_WINDOW:-0}" = "1" ]; then
        # Test-only crash injector. Exit from the disposable dispatch child
        # after singleton transaction preparation and before ordinal creation; this
        # leaves the same recoverable transaction as a hard crash without any
        # signal that could target a parent harness terminal.
        # A non-signal code keeps the smoke harness process group intact while
        # still bypassing all subsequent admission work (there are no traps).
        exit 97
      fi
      if [ -n "$ROUTE_DIGEST" ]; then
        node "$SCRIPT_DIR/lib/admission-recover.cjs" publish "$ADMISSION_ROOT" "$ADMISSION_DIR" "$ABS_ROUND_STATE" "$ISSUE_N" "$ADMISSION_KEY" "$$" integrated --route-digest "$ROUTE_DIGEST" --route-binding "$ROUTE_BINDING" >/dev/null 2>&1
      else
        node "$SCRIPT_DIR/lib/admission-recover.cjs" publish "$ADMISSION_ROOT" "$ADMISSION_DIR" "$ABS_ROUND_STATE" "$ISSUE_N" "$ADMISSION_KEY" "$$" integrated >/dev/null 2>&1
      fi
      if [ "$?" -ne 0 ]; then
        node "$SCRIPT_DIR/lib/admission-recover.cjs" rollback "$INTEGRATED_DIR" "$ADMISSION_DIR" >/dev/null 2>&1 || true
        node "$SCRIPT_DIR/lib/admission-recover.cjs" release-lock "$ISSUE_ADMISSION_LOCK/.admission-lock.json" >/dev/null 2>&1 || true
        echo "ERROR: redispatch admission already consumed: $ADMISSION_KEY" >&2
        exit 1
      fi
      if [ "${AGENT_WORKFLOW_ADMISSION_KILL_WINDOW:-0}" = "2" ]; then
        # Test-only crash injector for the former orphan-ordinal window.
        exit 97
      fi
    elif [ -d "$ADMISSION_ROOT/issue-${ISSUE_N}-integrated-fix" ]; then
      node "$SCRIPT_DIR/lib/admission-recover.cjs" release-lock "$ISSUE_ADMISSION_LOCK/.admission-lock.json" >/dev/null 2>&1 || true
      echo "ERROR: redispatch admission already consumed: issue $ISSUE_N exhausted its integrated fix admission" >&2
      exit 1
    elif [ -n "$ROUTE_DIGEST" ]; then
      node "$SCRIPT_DIR/lib/admission-recover.cjs" publish "$ADMISSION_ROOT" "$ADMISSION_DIR" "$ABS_ROUND_STATE" "$ISSUE_N" "$ADMISSION_KEY" "$$" normal --route-digest "$ROUTE_DIGEST" --route-binding "$ROUTE_BINDING" >/dev/null 2>&1
      if [ "$?" -ne 0 ]; then
        node "$SCRIPT_DIR/lib/admission-recover.cjs" release-lock "$ISSUE_ADMISSION_LOCK/.admission-lock.json" >/dev/null 2>&1 || true
        echo "ERROR: redispatch admission already consumed: $ADMISSION_KEY" >&2
        exit 1
      fi
    elif ! node "$SCRIPT_DIR/lib/admission-recover.cjs" publish "$ADMISSION_ROOT" "$ADMISSION_DIR" "$ABS_ROUND_STATE" "$ISSUE_N" "$ADMISSION_KEY" "$$" normal >/dev/null 2>&1; then
      node "$SCRIPT_DIR/lib/admission-recover.cjs" release-lock "$ISSUE_ADMISSION_LOCK/.admission-lock.json" >/dev/null 2>&1 || true
      echo "ERROR: redispatch admission already consumed: $ADMISSION_KEY" >&2
      exit 1
    fi
    if [ -n "${ABS_ROUND_STATE:-}" ]; then
      if ! node "$SCRIPT_DIR/lib/admission-advance.cjs" "$ABS_ROUND_STATE" "$ADMISSION_KEY" >/dev/null 2>&1; then
        # Keep the issue lock held across the host-state advance.  If the
        # durable state write fails, neither half of an integrated admission
        # may survive and make a later retry look consumed.
        node "$SCRIPT_DIR/lib/admission-recover.cjs" rollback "$INTEGRATED_DIR" "$ADMISSION_DIR" >/dev/null 2>&1 || true
        node "$SCRIPT_DIR/lib/admission-recover.cjs" release-lock "$ISSUE_ADMISSION_LOCK/.admission-lock.json" >/dev/null 2>&1 || true
        echo "ERROR: could not durably advance host-owned admission ordinal" >&2
        exit 2
      fi
    fi
    if [ "${AGENT_WORKFLOW_ADMISSION_KILL_WINDOW:-0}" = "3" ]; then
      # State has advanced but the marker journal is still prepared. Recovery
      # must retain and commit it, never reuse this ordinal.
      exit 97
    fi
    if [ "$ADMISSION_MODE" = "integrated_fix" ]; then
      if ! node "$SCRIPT_DIR/lib/admission-recover.cjs" commit "$INTEGRATED_DIR" "$ADMISSION_DIR" >/dev/null 2>&1; then
        echo "ERROR: could not finalize integrated admission transaction" >&2
        exit 2
      fi
    elif ! node "$SCRIPT_DIR/lib/admission-recover.cjs" commit-admission "$ADMISSION_DIR" "" "" "$ISSUE_N" "$ADMISSION_KEY" >/dev/null 2>&1; then
      node "$SCRIPT_DIR/lib/admission-recover.cjs" release-lock "$ISSUE_ADMISSION_LOCK/.admission-lock.json" >/dev/null 2>&1 || true
      echo "ERROR: could not finalize normal admission transaction" >&2
      exit 2
    fi
    if ! node "$SCRIPT_DIR/lib/admission-recover.cjs" release-lock "$ISSUE_ADMISSION_LOCK/.admission-lock.json" >/dev/null 2>&1; then
      echo "ERROR: cannot release redispatch admission lock for issue $ISSUE_N" >&2
      exit 2
    fi
  fi
fi

# The canonical ROUND-STATE is the only AC wording authority. Standard/Full
# writes and every canonical redispatch must hand the worker its exact AC
# block before any durable write-admission marker or transport side effect exists.
PROMPT_AC_REQUIRED=0
if [ "$INITIAL_WRITE" -eq 1 ] && { [ "$TIER" = "standard" ] || [ "$TIER" = "full_cluster" ]; }; then
  PROMPT_AC_REQUIRED=1
fi
if [ "$PROMPT_AC_REQUIRED" -eq 1 ]; then
  if [ ! -x "$PROMPT_AC_CHECK" ]; then
    echo "ERROR: prompt AC gate is missing or not executable: $PROMPT_AC_CHECK" >&2
    exit 2
  fi
  if ! bash "$PROMPT_AC_CHECK" --round-state "$ABS_ROUND_STATE" --manifest-revision "$MANIFEST_REVISION" --prompt-file "$ABS_PROMPT_FILE"; then
    echo "ERROR: prompt AC gate denied dispatch" >&2
    exit 1
  fi
fi

# Consume the immutable plan/seat binding only after every canonical prompt and
# redispatch check has passed, but before the existing write-attempt marker or
# transport launch. The legacy no-plan path remains a conservative sequential seat.
if [ -n "$EXECUTION_PLAN" ] && [ "$DRY_RUN" -eq 0 ]; then
  PLAN_ADMISSION="$(node "$PARALLEL_PLAN" admit --plan "$ABS_EXECUTION_PLAN" --target "$ABS_WORKTREE" --round-state "$ABS_ROUND_STATE" --issue "$ISSUE_N" --revision "$MANIFEST_REVISION" --seat "$PLAN_SEAT" --consume true)"
  plan_status=$?
  if [ "$plan_status" -ne 0 ]; then
    echo "ERROR: plan admission denied: $PLAN_ADMISSION" >&2
    exit "$plan_status"
  fi
  echo "dispatch-core: plan admission: $PLAN_ADMISSION"
fi

if [ "$DRY_RUN" -eq 0 ]; then
  if [ "$INITIAL_WRITE" -eq 1 ]; then
    [ "$PRE_MARKER_DELAY" = "0" ] || sleep "$PRE_MARKER_DELAY"
    if ! mkdir "$WRITE_ATTEMPT_DIR" 2>/dev/null; then
      echo "ERROR: concurrent write dispatch detected before launch" >&2
      exit 1
    fi
  elif [ "$READ_ONLY" -eq 0 ] && [ "$PRODUCE_REVIEW" -eq 0 ] && [ ! -d "$WRITE_ATTEMPT_DIR" ]; then
    if ! mkdir "$WRITE_ATTEMPT_DIR" 2>/dev/null; then
      echo "ERROR: concurrent write dispatch detected before launch" >&2
      exit 1
    fi
  fi
fi

RUNNER_RELATIVE=""
RUNNER_FILE=""
RUNNER_COMMAND=""
DRY_RUNNER_RELATIVE=".review/ISSUE-${ISSUE_N}-launch.<unique>/launch.sh"
RUNNER_PREVIEW="exec env NODE_OPTIONS="
RUNNER_PREVIEW="unset AGENT_WORKFLOW_HOST_STATE; $RUNNER_PREVIEW"
RUNNER_PREVIEW="$RUNNER_PREVIEW AGENT_WORKFLOW_RUNTIME_BIN=$RUNTIME_BIN_PIN"
RUNNER_PREVIEW="$RUNNER_PREVIEW $WATCHDOG --runtime $RUNTIME --role $ROLE --mode $RUNTIME_MODE --issue $ISSUE_N --prompt-file $ABS_PROMPT_FILE --cwd $ABS_WORKTREE"
# Unpinned dispatch silently inherits the user's codex config default model,
# which is not the workflow's per-role allocation (and breaks the invariant
# that the reviewer outranks the implementer). Pin it at the dispatch site.
[ -n "$MODEL" ] && RUNNER_PREVIEW="$RUNNER_PREVIEW --model $MODEL"
[ -n "$EFFORT" ] && RUNNER_PREVIEW="$RUNNER_PREVIEW --effort $EFFORT"
# Read-heavy dispatches (ARCH briefs, debate rounds, large reviews) legitimately
# produce NO file progress for many minutes; the watchdog's 240s default
# first-progress timeout kills them mid-read. Forward larger budgets for those
# (or declare --read-only so heartbeat liveness applies).
[ -n "$FIRST_PROGRESS_TIMEOUT" ] && RUNNER_PREVIEW="$RUNNER_PREVIEW --first-progress-timeout $FIRST_PROGRESS_TIMEOUT"
[ -n "$STALL_TIMEOUT" ] && RUNNER_PREVIEW="$RUNNER_PREVIEW --stall-timeout $STALL_TIMEOUT"
[ -n "$MAX_RETRIES" ] && RUNNER_PREVIEW="$RUNNER_PREVIEW --max-retries $MAX_RETRIES"
[ -n "$MAX_WALLCLOCK" ] && RUNNER_PREVIEW="$RUNNER_PREVIEW --max-wallclock $MAX_WALLCLOCK"
[ "$PRODUCE_REVIEW" -eq 1 ] && RUNNER_PREVIEW="$RUNNER_PREVIEW --produce-review"
[ "$CONDUCTOR_CONTROL" -eq 1 ] && RUNNER_PREVIEW="$RUNNER_PREVIEW --conductor-control"
[ -n "$RUNTIME_PERMISSION_FILE" ] && RUNNER_PREVIEW="$RUNNER_PREVIEW --opencode-permission-file $RUNTIME_PERMISSION_FILE"

if [ "$DRY_RUN" -eq 1 ]; then
  bash "$ADAPTER_SCRIPT" preview --name "$WS_NAME" --worktree "$ABS_WORKTREE" --runner-relative "$DRY_RUNNER_RELATIVE" || {
    echo "ERROR: $ADAPTER adapter preview failed" >&2
    exit 2
  }
  echo "runner $DRY_RUNNER_RELATIVE: $RUNNER_PREVIEW"
  exit 0
fi

if ! write_launch_runner; then
  echo "ERROR: cannot atomically record launch runner under $ABS_WORKTREE/.review" >&2
  exit 2
fi

echo "dispatch-core: adapter=$ADAPTER issue=$ISSUE_N worktree=$ABS_WORKTREE name=$WS_NAME runner=$RUNNER_RELATIVE poll-timeout=${POLL_TIMEOUT}s"

# Record the identity of any PRE-EXISTING artifacts (same-issue re-dispatch,
# e.g. with a second prompt file, is a supported pattern) so the poll below
# only accepts an artifact NEWER than this dispatch — never a stale one.
STALE_RUN_SIG=""
if [ -f "$RUN_FILE" ]; then
  STALE_RUN_SIG="$(file_sig "$RUN_FILE")"
  echo "dispatch-core: waiting for fresh RUN.json (stale one from $(file_started_at "$RUN_FILE") present)"
fi
STALE_BLOCKER_SIG=""
if [ -f "$BLOCKER_FILE" ]; then
  STALE_BLOCKER_SIG="$(file_sig "$BLOCKER_FILE")"
  echo "dispatch-core: waiting past stale BLOCKER.json (from a previous run)"
fi

LAUNCHED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
LAUNCH_JSON="$(bash "$ADAPTER_SCRIPT" launch --name "$WS_NAME" --worktree "$ABS_WORKTREE" --runner-relative "$RUNNER_RELATIVE")"
launch_status=$?
# A launch result is only acceptable when the adapter reports "launched" or
# one of its own capabilities-declared ambiguous lifecycles (e.g. Herdr's
# command_unconfirmed) together with a non-blank handle. Any other lifecycle
# value or a whitespace-only handle is rejected exactly like a missing handle:
# no receipt, no runner/admission progression from this point.
EXTERNAL_HANDLE="$(node - "$SCRIPT_DIR/lib/launch-result.cjs" "$LAUNCH_JSON" "$ADAPTER_AMBIGUOUS_LIFECYCLES_JSON" <<'NODE'
const { normalizeLaunchResult } = require(process.argv[2]);
let result = null;
try {
  const ambiguous = JSON.parse(process.argv[4]);
  const accepted = ["launched"].concat(Array.isArray(ambiguous) ? ambiguous : []);
  result = normalizeLaunchResult(JSON.parse(process.argv[3]), accepted);
} catch (e) { result = null; }
if (!result) process.exit(2);
process.stdout.write(result.external_handle);
NODE
)" || {
  echo "ERROR: $ADAPTER adapter returned an invalid or ambiguous external handle or launch lifecycle" >&2
  if [ "$launch_status" -ne 0 ]; then exit "$launch_status"; else exit 2; fi
}
if [ "$launch_status" -ne 0 ]; then
  echo "dispatch-core: adapter launch returned $launch_status; checking canonical RUN/BLOCKER freshness before classifying transport failure" >&2
fi
RECEIPT_FILE="$ABS_WORKTREE/.review/ISSUE-${ISSUE_N}-TRANSPORT.json"
RUNNER_SHA="$(node -e 'const fs=require("fs"),crypto=require("crypto"); process.stdout.write(crypto.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"))' "$RUNNER_FILE")"
CREATED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
if ! acquire_runner_retention_lock; then
  echo "ERROR: could not acquire same-issue runner retention lock" >&2
  exit 2
fi
# A SIGKILL may have happened after an earlier receipt rename but before its
# marker write. Under this lock, recover that receipt-backed runner before the
# new publication can supersede it.
mark_current_receipt_runner
node - "$RECEIPT_FILE" "$RECEIPT_SCHEMA" "$SCHEMA_VALIDATOR" "$ISSUE_N" "$ADAPTER" "$ADAPTER_VERSION" "$ADAPTER_CAPABILITIES_JSON" "$EXTERNAL_HANDLE" "$ABS_WORKTREE" "$RUNNER_FILE" "$RUNNER_RELATIVE" "$RUNNER_SHA" "$LAUNCHED_AT" "$CREATED_AT" "$RUNTIME" "$ROLE" "$RUNTIME_CAPABILITY_JSON" "$ROUTE_DIGEST" "$ROUTE_POLICY_DIGEST" "$MODEL" "$EFFORT" "${ADMISSION_MODE:-}" "${ADMISSION_DIR:-}" "${INTEGRATED_DIR:-}" <<'NODE'
const fs = require("fs");
const [file, schemaFile, validatorFile, issue, adapter, version, capabilitiesJson, handle, worktree, runnerPath, runnerRelative, runnerSha, launchedAt, createdAt, runtime, role, runtimeCapabilitiesJson, routeDigest, policyDigest, model, effort, admissionMode, admissionDir, integratedDir] = process.argv.slice(2);
const runtimeCapabilities = JSON.parse(runtimeCapabilitiesJson);
const value = {
  schema_version: routeDigest ? "3" : "2", artifact_type: "transport_receipt", authoritative: false,
  issue: Number(issue), adapter, adapter_version: version,
  runtime, role, runtime_version: runtimeCapabilities.version,
  capabilities: JSON.parse(capabilitiesJson), external_handle: handle,
  worktree_path: worktree,
  runner: { path: runnerPath, relative_path: runnerRelative, sha256: runnerSha },
  launched_at: launchedAt, created_at: createdAt
};
if (routeDigest) {
  if (!/^[a-f0-9]{64}$/.test(routeDigest) || !/^[a-f0-9]{64}$/.test(policyDigest || "")) process.exit(2);
  const readBinding = directory => JSON.parse(fs.readFileSync(`${directory}/.admission-transaction.json`, "utf8"));
  let ordinal;
  try { ordinal = readBinding(admissionDir); } catch (_) { process.exit(2); }
  if (ordinal.route_digest !== routeDigest) process.exit(2);
  if (admissionMode === "integrated_fix") {
    let singleton;
    try { singleton = readBinding(integratedDir); } catch (_) { process.exit(2); }
    if (singleton.route_digest !== routeDigest) process.exit(2);
  }
  value.routing = {
    route_digest: routeDigest, policy_digest: policyDigest,
    selection_basis: "ordered_policy", decision_reason_codes: ["model_alloc", "ordered_policy"],
    selected: { model, effort }
  };
}
const schema = JSON.parse(fs.readFileSync(schemaFile, "utf8"));
const { validate } = require(validatorFile);
const errors = validate(schema, value);
if (errors.length) { console.error(errors.join("\n")); process.exit(2); }
const temp = `${file}.tmp-${process.pid}`;
fs.writeFileSync(temp, JSON.stringify(value, null, 2) + "\n", { mode: 0o600 });
fs.renameSync(temp, file);
NODE
if [ "$?" -ne 0 ]; then
  release_runner_retention_lock
  echo "ERROR: could not publish schema-valid non-authoritative transport receipt" >&2
  exit 2
fi
if : > "$RUNNER_RECEIPT_MARKER"; then
  cleanup_superseded_runners
else
  echo "WARNING: transport receipt published but runner retention marker could not be recorded" >&2
fi
release_runner_retention_lock
echo "dispatch-core: transport receipt=$RECEIPT_FILE authoritative=false external-handle=$EXTERNAL_HANDLE"

elapsed=0
while [ "$elapsed" -lt "$POLL_TIMEOUT" ]; do
  if [ -f "$BLOCKER_FILE" ] && [ "$(file_sig "$BLOCKER_FILE")" != "$STALE_BLOCKER_SIG" ]; then
    blocker_check="$(node "$SCRIPT_DIR/lib/blocker-check.cjs" "$BLOCKER_FILE" "$SCRIPT_DIR/../schemas/blocker.schema.json" "$SCHEMA_VALIDATOR" "$ISSUE_N" "$ABS_WORKTREE" 2>/dev/null)"
    if [ "$?" -eq 0 ] && [ "$blocker_check" = "ok" ]; then
      echo "dispatch-core: fresh schema-valid BLOCKER.json present at $BLOCKER_FILE — scoped abort"
      exit 0
    fi
    echo "ERROR: fresh BLOCKER.json is not schema-valid/current/consumable (${blocker_check:-unknown}); it is not liveness evidence" >&2
    exit 1
  fi
  if [ -f "$RUN_FILE" ] && [ "$(file_sig "$RUN_FILE")" != "$STALE_RUN_SIG" ]; then
    status="$(node -e 'const fs=require("fs"); try { const o=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); process.stdout.write(String(o.status||"")); } catch(e) { process.stdout.write(""); }' "$RUN_FILE")"
    echo "dispatch-core: fresh RUN.json present at $RUN_FILE (status=$status)"
    exit 0
  fi
  sleep "$POLL_INTERVAL"
  elapsed=$((elapsed + POLL_INTERVAL))
done

echo "ERROR: watchdog never wrote a FRESH RUN.json — transport launch is not workflow completion; inspect receipt=$RECEIPT_FILE handle=$EXTERNAL_HANDLE" >&2
if [ "$launch_status" -ne 0 ]; then exit "$launch_status"; fi
exit 1
