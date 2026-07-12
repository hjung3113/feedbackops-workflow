#!/usr/bin/env bash
# codex-watchdog.sh — wrap codex-safe.sh with process + filesystem liveness.
# Liveness never depends on stdout/first-token output. It watches for the
# codex-safe process to stay alive while the worktree stops changing.
# bash-3.2-compatible.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEX_SAFE="$SCRIPT_DIR/codex-safe.sh"

ISSUE_N=""
PROMPT_FILE=""
CWD=""
FIRST_PROGRESS_TIMEOUT=240
STALL_TIMEOUT=180
MAX_RETRIES=2
POLL_INTERVAL="${CODEX_WATCHDOG_POLL_INTERVAL:-15}"

usage() {
  echo "usage: codex-watchdog.sh --issue N --prompt-file F --cwd WT [--first-progress-timeout seconds] [--stall-timeout seconds] [--max-retries N]" >&2
}

now() { date +%s; }
iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

write_marker() {
  status="$1"; attempt="$2"; pid="$3"; exit_code="$4"
  mkdir -p "$CWD/.review" || return 1
  marker="$CWD/.review/ISSUE-${ISSUE_N}-RUN.json"
  RUN_MARKER_PATH="$marker" RUN_ISSUE="$ISSUE_N" RUN_ATTEMPT="$attempt" RUN_PID="$pid" RUN_STATUS="$status" RUN_EXIT_CODE="$exit_code" RUN_TIME="$(iso_now)" node -e '
    const fs = require("fs");
    const artifact = {
      schema_version: "1",
      artifact_type: "codex_run",
      issue: parseInt(process.env.RUN_ISSUE, 10),
      attempt: parseInt(process.env.RUN_ATTEMPT, 10),
      started_at: process.env.RUN_TIME,
      updated_at: process.env.RUN_TIME,
      status: process.env.RUN_STATUS
    };
    if (process.env.RUN_PID) artifact.pid = parseInt(process.env.RUN_PID, 10);
    if (process.env.RUN_EXIT_CODE) artifact.exit_code = parseInt(process.env.RUN_EXIT_CODE, 10);
    fs.writeFileSync(process.env.RUN_MARKER_PATH, JSON.stringify(artifact, null, 2) + "\n");
  '
}

progressed() {
  find "$CWD" -path '*/node_modules' -prune -o -path '*/.git' -prune -o -newer "$STAMP" -print -quit | grep -q .
}

kill_tree() {
  pid="$1"
  pkill -TERM -P "$pid" 2>/dev/null || true
  kill -TERM "$pid" 2>/dev/null || true
  sleep 1
  pkill -KILL -P "$pid" 2>/dev/null || true
  kill -KILL "$pid" 2>/dev/null || true
}

while [ $# -gt 0 ]; do
  case "$1" in
    --issue) ISSUE_N="$2"; shift 2 ;;
    --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
    --cwd) CWD="$2"; shift 2 ;;
    --first-progress-timeout) FIRST_PROGRESS_TIMEOUT="$2"; shift 2 ;;
    --stall-timeout) STALL_TIMEOUT="$2"; shift 2 ;;
    --max-retries) MAX_RETRIES="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

[ -n "$ISSUE_N" ] || { echo "missing --issue" >&2; usage; exit 2; }
[ -n "$PROMPT_FILE" ] || { echo "missing --prompt-file" >&2; usage; exit 2; }
[ -n "$CWD" ] || { echo "missing --cwd" >&2; usage; exit 2; }
[ -d "$CWD" ] || { echo "cwd is not a directory: $CWD" >&2; exit 2; }
[ -f "$PROMPT_FILE" ] || { echo "prompt file not found: $PROMPT_FILE" >&2; exit 2; }

STAMP="$(mktemp -t codex-watchdog-stamp.XXXXXX)"
STDERR_LOG="$(mktemp -t codex-watchdog-stderr.XXXXXX)"
trap 'rm -f "$STAMP" "$STDERR_LOG"' EXIT

attempt=0
while [ "$attempt" -le "$MAX_RETRIES" ]; do
  attempt=$((attempt + 1))
  : > "$STDERR_LOG"
  write_marker "running" "$attempt" "" "" || true
  touch "$STAMP"
  NODE_OPTIONS= "$CODEX_SAFE" --issue "$ISSUE_N" --prompt-file "$PROMPT_FILE" --cwd "$CWD" 2>"$STDERR_LOG" &
  pid=$!
  write_marker "running" "$attempt" "$pid" "" || true
  touch "$STAMP"

  first_seen=0
  last_progress="$(now)"
  killed_for_stall=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep "$POLL_INTERVAL"
    if progressed; then
      touch "$STAMP"
      last_progress="$(now)"
      first_seen=1
    fi
    if [ "$first_seen" -eq 1 ]; then
      budget="$STALL_TIMEOUT"
    else
      budget="$FIRST_PROGRESS_TIMEOUT"
    fi
    elapsed=$(( $(now) - last_progress ))
    if [ "$elapsed" -ge "$budget" ]; then
      killed_for_stall=1
      kill_tree "$pid"
      write_marker "killed_stall" "$attempt" "$pid" "" || true
      break
    fi
  done

  wait "$pid" 2>/dev/null
  ec=$?
  if [ "$ec" -eq 0 ]; then
    write_marker "exited" "$attempt" "$pid" "0" || true
    exit 0
  fi

  if grep -qiE '4[0-9][0-9]|unsupported model|model_not_found|invalid.*(model|api key)|unauthorized' "$STDERR_LOG"; then
    write_marker "refused" "$attempt" "$pid" "$ec" || true
    echo "FAIL-FAST: model refusal (4xx) — retry futile" >&2
    exit 4
  fi

  if [ "$killed_for_stall" -eq 0 ]; then
    write_marker "killed_stall" "$attempt" "$pid" "$ec" || true
  fi
done

write_marker "exhausted" "$attempt" "" "" || true
echo "FAIL: codex stalled/failed after $MAX_RETRIES retries" >&2
exit 6
