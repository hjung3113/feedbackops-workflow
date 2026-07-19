#!/usr/bin/env bash
# codex exec wrapper. Enforces: workspace-write sandbox, --cd working-dir lock,
# optional abort-stash for partial work preservation.
#
# Usage:
#   scripts/codex-safe.sh --issue 33 --prompt-file /path/to/prompt.txt
#   scripts/codex-safe.sh --issue 33 --prompt "inline prompt"
set -euo pipefail

ISSUE_N=""
PROMPT=""
PROMPT_FILE=""
CWD="$(pwd)"
MODEL=""
EFFORT=""
HEARTBEAT_FILE=""
HEARTBEAT_PID=""
HEARTBEAT_INTERVAL="${CODEX_SAFE_HEARTBEAT_INTERVAL:-20}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue) ISSUE_N="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
    --cwd) CWD="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --effort) EFFORT="$2"; shift 2 ;;
    --heartbeat-file) HEARTBEAT_FILE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Policy guard: gpt-5.6 ABOVE medium reasoning is forbidden (cost). As of
# 2026-07-15 the 5.6 family IS available on the ChatGPT account via suffixed
# variants; bare "gpt-5.6" still 400s. Ladder: sol (top, reasoning-heavy) >
# terra (everyday impl) > luna (light). Standard allocation: design/review =
# gpt-5.6-sol medium, implementation = gpt-5.6-terra medium, mechanical =
# gpt-5.6-luna low (docs/agents/multi-agent-workflow.md "Model Allocation").
# If effort is omitted for 5.6, pin the dispatched config to medium so
# user/global config cannot silently raise it.
case "$MODEL" in
  *5.6*|*5-6*)
    [[ -z "$EFFORT" ]] && EFFORT="medium"
    case "$EFFORT" in
      high|xhigh|max)
        echo "REFUSED: gpt-5.6 at '$EFFORT' reasoning is banned (max allowed: medium); lower --effort or change model" >&2
        exit 2 ;;
    esac ;;
esac

[[ -z "$ISSUE_N" ]] && { echo "missing --issue" >&2; exit 2; }
[[ -z "$PROMPT" && -z "$PROMPT_FILE" ]] && { echo "missing --prompt or --prompt-file" >&2; exit 2; }
[[ -n "$PROMPT_FILE" ]] && PROMPT="$(cat "$PROMPT_FILE")"
[[ -z "$PROMPT" ]] && { echo "prompt is empty (check --prompt-file content)" >&2; exit 2; }

# Stop the heartbeat ticker before any failure-path stash. The explicit
# post-wait stop below is the normal path; this trap covers signals and shell
# failures so a read-only dispatch never leaves a ticker behind.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
stop_heartbeat() {
  if [[ -n "$HEARTBEAT_PID" ]]; then
    # The ticker shell may be between `sleep &` and recording that child's
    # PID when cleanup arrives. Kill its direct children first, then let the
    # ticker trap reap the recorded sleep child before reaping the ticker.
    pkill -TERM -P "$HEARTBEAT_PID" 2>/dev/null || true
    kill "$HEARTBEAT_PID" 2>/dev/null || true
    wait "$HEARTBEAT_PID" 2>/dev/null || true
    HEARTBEAT_PID=""
  fi
}
cleanup() {
  s=$?
  stop_heartbeat
  if [[ $s -ne 0 ]]; then
    "$SCRIPT_DIR/workflow-stash.sh" "$ISSUE_N" "$CWD" || true
  fi
  trap - EXIT
  exit "$s"
}
trap cleanup EXIT

cd "$CWD"

EXTRA=()
[[ -n "$MODEL" ]] && EXTRA+=( -m "$MODEL" )
[[ -n "$EFFORT" ]] && EXTRA+=( -c "model_reasoning_effort=\"$EFFORT\"" )

# workspace-write makes ONLY --cd (plus /tmp) writable. A git WORKTREE keeps its
# real gitdir in the MAIN repo at .git/worktrees/<name> — outside that root — so
# `git commit` cannot create index.lock and dies:
#   fatal: Unable to create '.../.git/worktrees/<n>/index.lock': Operation not permitted
# Incident 2026-07-16: this silently ate EVERY commit for seven consecutive
# dispatches (issue #127 chunk d). Codex wrote each chunk in full, failed to
# commit, and exited 0, so the failure looked like the model ignoring an
# instruction. No prompt wording can fix a sandbox denial. Grant the git common
# dir explicitly, and ONLY when it lies outside --cd, so a plain checkout (gitdir
# already inside) does not widen the sandbox for nothing.
GIT_COMMON_DIR="$(git -C "$CWD" rev-parse --git-common-dir 2>/dev/null || true)"
if [[ -n "$GIT_COMMON_DIR" ]]; then
  GIT_COMMON_DIR="$(cd "$CWD" && cd "$GIT_COMMON_DIR" 2>/dev/null && pwd || true)"
fi
if [[ -n "$GIT_COMMON_DIR" ]]; then
  ABS_CWD="$(cd "$CWD" && pwd)"
  case "$GIT_COMMON_DIR" in
    "$ABS_CWD"/*) ;;  # gitdir already inside the writable root — nothing to add
    *) EXTRA+=( -c "sandbox_workspace_write.writable_roots=[\"$GIT_COMMON_DIR\"]" ) ;;
  esac
fi

if [[ "${#EXTRA[@]}" -gt 0 ]]; then
  codex exec \
    --sandbox workspace-write \
    --cd "$CWD" \
    "${EXTRA[@]}" \
    "$PROMPT" &
else
  codex exec \
    --sandbox workspace-write \
    --cd "$CWD" \
    "$PROMPT" &
fi
CODEX_PID=$!

if [[ -n "$HEARTBEAT_FILE" ]]; then
  (
    ticker_sleep=""
    stop_ticker_sleep() {
      if [[ -n "$ticker_sleep" ]]; then
        kill "$ticker_sleep" 2>/dev/null || true
        wait "$ticker_sleep" 2>/dev/null || true
        ticker_sleep=""
      fi
    }
    trap 'stop_ticker_sleep; exit 0' TERM INT
    while true; do
      mkdir -p "$(dirname "$HEARTBEAT_FILE")" || exit 1
      : > "$HEARTBEAT_FILE"
      sleep "$HEARTBEAT_INTERVAL" &
      ticker_sleep=$!
      wait "$ticker_sleep" || exit 0
      ticker_sleep=""
    done
  ) &
  HEARTBEAT_PID=$!
  # Test seam: lets the offline smoke assert that cleanup reaps both levels.
  if [[ -n "${CODEX_SAFE_HEARTBEAT_PID_FILE:-}" ]]; then
    printf '%s\n' "$HEARTBEAT_PID" > "$CODEX_SAFE_HEARTBEAT_PID_FILE"
  fi
fi

set +e
wait "$CODEX_PID"
CODEX_EXIT=$?
set -e
stop_heartbeat
exit "$CODEX_EXIT"
