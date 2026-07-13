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
#   - status:"refused"       4xx/model-refusal signature; retry is futile.
#   - status:"exhausted"     retries used up with no success.
#   A `.review/ISSUE-<N>-BLOCKER.json` file appearing instead of/alongside
#   RUN.json is a scoped abort — codex chose to stop, not crash.
#
# Usage:
#   scripts/cmux-dispatch.sh --issue <N> --worktree <path> \
#     [--prompt-file <p>] [--name <workspace-name>] \
#     [--poll-timeout <secs>] [--dry-run]
#
# Defaults:
#   --prompt-file    <worktree>/.review/ISSUE-<N>-PROMPT.txt
#   --name           codex-<N>
#   --poll-timeout   300
#
# bash-3.2-compatible: no `declare -A`, no `${var,,}`, no `mapfile`.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHDOG="$SCRIPT_DIR/codex-watchdog.sh"

ISSUE_N=""
WORKTREE=""
PROMPT_FILE=""
WS_NAME=""
POLL_TIMEOUT=300
DRY_RUN=0

usage() {
  echo "usage: cmux-dispatch.sh --issue N --worktree PATH [--prompt-file P] [--name WSNAME] [--poll-timeout SECS] [--dry-run]" >&2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --issue) ISSUE_N="$2"; shift 2 ;;
    --worktree) WORKTREE="$2"; shift 2 ;;
    --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
    --name) WS_NAME="$2"; shift 2 ;;
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

CMD="NODE_OPTIONS= $WATCHDOG --issue $ISSUE_N --prompt-file $ABS_PROMPT_FILE --cwd $ABS_WORKTREE"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "cmux workspace create --name \"$WS_NAME\" --cwd \"$ABS_WORKTREE\" --command \"$CMD\""
  exit 0
fi

echo "cmux-dispatch: issue=$ISSUE_N worktree=$ABS_WORKTREE name=$WS_NAME poll-timeout=${POLL_TIMEOUT}s"

cmux workspace create --name "$WS_NAME" --cwd "$ABS_WORKTREE" --command "$CMD" >/dev/null

RUN_FILE="$ABS_WORKTREE/.review/ISSUE-${ISSUE_N}-RUN.json"
BLOCKER_FILE="$ABS_WORKTREE/.review/ISSUE-${ISSUE_N}-BLOCKER.json"

elapsed=0
while [ "$elapsed" -lt "$POLL_TIMEOUT" ]; do
  if [ -f "$RUN_FILE" ]; then
    status="$(node -e 'const fs=require("fs"); try { const o=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); process.stdout.write(String(o.status||"")); } catch(e) { process.stdout.write(""); }' "$RUN_FILE")"
    echo "cmux-dispatch: RUN.json present at $RUN_FILE (status=$status)"
    exit 0
  fi
  if [ -f "$BLOCKER_FILE" ]; then
    echo "cmux-dispatch: BLOCKER.json present at $BLOCKER_FILE — scoped abort"
    exit 0
  fi
  sleep 5
  elapsed=$((elapsed + 5))
done

echo "ERROR: watchdog never wrote RUN.json — likely died before start; check the workspace pane (name=$WS_NAME)" >&2
exit 1
