#!/usr/bin/env bash
# cmux-dispatch.sh — the one true way to dispatch codex into a VISIBLE cmux
# workspace running scripts/codex-watchdog.sh. Do not hand-roll
# `cmux new-workspace --command "codex-watchdog.sh ..."` — this script exists
# because that hand-rolled form silently died in production (2026-07-13):
# --cwd was forgotten on the cmux workspace itself, the workspace opened in
# cmux's default project dir, and codex-watchdog.sh validated its
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
#   scripts/cmux-dispatch.sh --issue <N> --worktree <path> \
#     [--prompt-file <p>] [--name <workspace-name>] \
#     [--round-state <json> --manifest-revision <n>] \
#     [--poll-timeout <secs>] [--dry-run]
#
# Defaults:
#   --prompt-file    <worktree>/.review/ISSUE-<N>-PROMPT.txt
#   --name           codex-<N>
#   --poll-timeout   300   (poll interval 5s; CMUX_DISPATCH_POLL_INTERVAL overrides, test seam)
#
# Same-issue re-dispatch (e.g. a second prompt file for the same issue) is
# supported: a pre-existing RUN.json/BLOCKER.json from a previous run is
# treated as STALE — the poll only accepts an artifact whose mtime+started_at
# changed after this dispatch (or that newly appeared).
#
# bash-3.2-compatible: no `declare -A`, no `${var,,}`, no `mapfile`.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHDOG="$SCRIPT_DIR/codex-watchdog.sh"
REDISPATCH_CHECK="$SCRIPT_DIR/redispatch-check.sh"

ISSUE_N=""
WORKTREE=""
PROMPT_FILE=""
WS_NAME=""
MODEL=""
EFFORT=""
FIRST_PROGRESS_TIMEOUT=""
STALL_TIMEOUT=""
ROUND_STATE=""
MANIFEST_REVISION=""
READ_ONLY=0
POLL_TIMEOUT=300
DRY_RUN=0
POLL_INTERVAL="${CMUX_DISPATCH_POLL_INTERVAL:-5}"
PRE_MARKER_DELAY="${CMUX_DISPATCH_PRE_MARKER_DELAY:-0}"

usage() {
  echo "usage: cmux-dispatch.sh --issue N --worktree PATH [--prompt-file P] [--name WSNAME] [--model M] [--effort E] [--read-only] [--round-state JSON --manifest-revision N] [--first-progress-timeout SECS] [--stall-timeout SECS] [--poll-timeout SECS] [--dry-run]" >&2
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
  m="$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)"
  s="$(node -e 'try { process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).started_at || "")); } catch (e) {}' "$f" 2>/dev/null)"
  printf '%s|%s\n' "$m" "$s"
}

file_started_at() {
  node -e 'try { process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).started_at || "unknown")); } catch (e) { process.stdout.write("unknown"); }' "$1" 2>/dev/null
}

while [ $# -gt 0 ]; do
  case "$1" in
    --issue) ISSUE_N="$2"; shift 2 ;;
    --worktree) WORKTREE="$2"; shift 2 ;;
    --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
    --name) WS_NAME="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --effort) EFFORT="$2"; shift 2 ;;
    --first-progress-timeout) FIRST_PROGRESS_TIMEOUT="$2"; shift 2 ;;
    --stall-timeout) STALL_TIMEOUT="$2"; shift 2 ;;
    --round-state) ROUND_STATE="$2"; shift 2 ;;
    --manifest-revision) MANIFEST_REVISION="$2"; shift 2 ;;
    --read-only) READ_ONLY=1; shift 1 ;;
    --poll-timeout) POLL_TIMEOUT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift 1 ;;
    *) echo "unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

[ -n "$ISSUE_N" ] || { echo "missing --issue" >&2; usage; exit 2; }
[ -n "$WORKTREE" ] || { echo "missing --worktree" >&2; usage; exit 2; }

[ -d "$WORKTREE" ] || { echo "ERROR: worktree does not exist: $WORKTREE" >&2; exit 2; }
ABS_WORKTREE="$(cd "$WORKTREE" && pwd)"

if ! git -C "$ABS_WORKTREE" rev-parse --git-dir >/dev/null 2>&1; then
  echo "ERROR: not a git worktree (git rev-parse --git-dir failed): $ABS_WORKTREE" >&2
  exit 2
fi
GIT_COMMON_RAW="$(git -C "$ABS_WORKTREE" rev-parse --git-common-dir)"
case "$GIT_COMMON_RAW" in
  /*) GIT_COMMON_DIR="$GIT_COMMON_RAW" ;;
  *) GIT_COMMON_DIR="$(cd "$ABS_WORKTREE/$GIT_COMMON_RAW" && pwd -P)" ;;
esac

[ -n "$PROMPT_FILE" ] || PROMPT_FILE="$ABS_WORKTREE/.review/ISSUE-${ISSUE_N}-PROMPT.txt"
case "$PROMPT_FILE" in
  /*) ABS_PROMPT_FILE="$PROMPT_FILE" ;;
  *) ABS_PROMPT_FILE="$ABS_WORKTREE/$PROMPT_FILE" ;;
esac

[ -f "$ABS_PROMPT_FILE" ] || {
  echo "ERROR: prompt file not found: $ABS_PROMPT_FILE" >&2
  exit 2
}

[ -n "$WS_NAME" ] || WS_NAME="codex-${ISSUE_N}"

if [ "$DRY_RUN" -eq 0 ]; then
  command -v cmux >/dev/null 2>&1 || {
    echo "ERROR: cmux binary not found on PATH" >&2
    exit 2
  }
fi

RUN_FILE="$ABS_WORKTREE/.review/ISSUE-${ISSUE_N}-RUN.json"
BLOCKER_FILE="$ABS_WORKTREE/.review/ISSUE-${ISSUE_N}-BLOCKER.json"
DEFAULT_ROUND_STATE="$ABS_WORKTREE/.review/ISSUE-${ISSUE_N}-ROUND-STATE.json"
WRITE_ATTEMPT_DIR="$ABS_WORKTREE/.review/.write-dispatch-issue-${ISSUE_N}-started"

# A prior same-issue RUN/BLOCKER makes this a write-capable implementation
# redispatch. Bind admission to canonical ROUND-STATE policy before cmux is
# allowed to start. Read-only seats do not mutate implementation state and are
# outside this circuit.
ADMISSION_KEY=""
REDISPATCH_REQUIRED=0
INITIAL_WRITE=0
if [ "$READ_ONLY" -eq 0 ]; then
  if [ -f "$RUN_FILE" ] || [ -f "$BLOCKER_FILE" ] || [ -d "$WRITE_ATTEMPT_DIR" ]; then
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
if [ "$REDISPATCH_REQUIRED" -eq 1 ]; then
  if [ -z "$ROUND_STATE" ] || [ -z "$MANIFEST_REVISION" ]; then
    echo "ERROR: write redispatch requires --round-state and --manifest-revision" >&2
    exit 2
  fi
  case "$ROUND_STATE" in
    /*) ABS_ROUND_STATE="$ROUND_STATE" ;;
    *) ABS_ROUND_STATE="$ABS_WORKTREE/$ROUND_STATE" ;;
  esac
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
  echo "cmux-dispatch: redispatch admission: mode=$ADMISSION_MODE key=$ADMISSION_KEY"
  if [ "$DRY_RUN" -eq 0 ]; then
    ADMISSION_ROOT="$GIT_COMMON_DIR/agent-workflow/redispatch-admissions"
    if ! mkdir -p "$ADMISSION_ROOT" 2>/dev/null; then
      echo "ERROR: cannot create durable redispatch admission store" >&2
      exit 2
    fi
    ADMISSION_DIR="$ADMISSION_ROOT/$ADMISSION_KEY"
    if ! mkdir "$ADMISSION_DIR" 2>/dev/null; then
      echo "ERROR: redispatch admission already consumed: $ADMISSION_KEY" >&2
      exit 1
    fi
  fi
fi

if [ "$DRY_RUN" -eq 0 ]; then
  if [ "$INITIAL_WRITE" -eq 1 ]; then
    [ "$PRE_MARKER_DELAY" = "0" ] || sleep "$PRE_MARKER_DELAY"
    if ! mkdir "$WRITE_ATTEMPT_DIR" 2>/dev/null; then
      echo "ERROR: concurrent write dispatch detected before launch" >&2
      exit 1
    fi
  elif [ "$READ_ONLY" -eq 0 ] && [ ! -d "$WRITE_ATTEMPT_DIR" ]; then
    if ! mkdir "$WRITE_ATTEMPT_DIR" 2>/dev/null; then
      echo "ERROR: concurrent write dispatch detected before launch" >&2
      exit 1
    fi
  fi
fi

CMD="NODE_OPTIONS= $WATCHDOG --issue $ISSUE_N --prompt-file $ABS_PROMPT_FILE --cwd $ABS_WORKTREE"
# Unpinned dispatch silently inherits the user's codex config default model,
# which is not the workflow's per-role allocation (and breaks the invariant
# that the reviewer outranks the implementer). Pin it at the dispatch site.
[ -n "$MODEL" ] && CMD="$CMD --model $MODEL"
[ -n "$EFFORT" ] && CMD="$CMD --effort $EFFORT"
# Read-heavy dispatches (ARCH briefs, debate rounds, large reviews) legitimately
# produce NO file progress for many minutes; the watchdog's 240s default
# first-progress timeout kills them mid-read. Forward larger budgets for those
# (or declare --read-only so heartbeat liveness applies).
[ -n "$FIRST_PROGRESS_TIMEOUT" ] && CMD="$CMD --first-progress-timeout $FIRST_PROGRESS_TIMEOUT"
[ -n "$STALL_TIMEOUT" ] && CMD="$CMD --stall-timeout $STALL_TIMEOUT"
[ "$READ_ONLY" -eq 1 ] && CMD="$CMD --read-only"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "cmux workspace create --name \"$WS_NAME\" --cwd \"$ABS_WORKTREE\" --command \"$CMD\""
  exit 0
fi

echo "cmux-dispatch: issue=$ISSUE_N worktree=$ABS_WORKTREE name=$WS_NAME poll-timeout=${POLL_TIMEOUT}s"

# Record the identity of any PRE-EXISTING artifacts (same-issue re-dispatch,
# e.g. with a second prompt file, is a supported pattern) so the poll below
# only accepts an artifact NEWER than this dispatch — never a stale one.
STALE_RUN_SIG=""
if [ -f "$RUN_FILE" ]; then
  STALE_RUN_SIG="$(file_sig "$RUN_FILE")"
  echo "cmux-dispatch: waiting for fresh RUN.json (stale one from $(file_started_at "$RUN_FILE") present)"
fi
STALE_BLOCKER_SIG=""
if [ -f "$BLOCKER_FILE" ]; then
  STALE_BLOCKER_SIG="$(file_sig "$BLOCKER_FILE")"
  echo "cmux-dispatch: waiting past stale BLOCKER.json (from a previous run)"
fi

cmux workspace create --name "$WS_NAME" --cwd "$ABS_WORKTREE" --command "$CMD" >/dev/null

elapsed=0
while [ "$elapsed" -lt "$POLL_TIMEOUT" ]; do
  if [ -f "$RUN_FILE" ] && [ "$(file_sig "$RUN_FILE")" != "$STALE_RUN_SIG" ]; then
    status="$(node -e 'const fs=require("fs"); try { const o=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); process.stdout.write(String(o.status||"")); } catch(e) { process.stdout.write(""); }' "$RUN_FILE")"
    echo "cmux-dispatch: fresh RUN.json present at $RUN_FILE (status=$status)"
    exit 0
  fi
  if [ -f "$BLOCKER_FILE" ] && [ "$(file_sig "$BLOCKER_FILE")" != "$STALE_BLOCKER_SIG" ]; then
    echo "cmux-dispatch: fresh BLOCKER.json present at $BLOCKER_FILE — scoped abort"
    exit 0
  fi
  sleep "$POLL_INTERVAL"
  elapsed=$((elapsed + POLL_INTERVAL))
done

echo "ERROR: watchdog never wrote a FRESH RUN.json — likely died before start; check the workspace pane (name=$WS_NAME)" >&2
exit 1
