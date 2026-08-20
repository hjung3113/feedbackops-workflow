#!/usr/bin/env bash
# Codex runtime member: invocation shape and Codex write isolation.
# bash-3.2 compatible.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMAND="${1:-}"
case "$COMMAND" in
  permission-file) exit 0;;
  probe)
    set -- "$BIN" exec --skip-git-repo-check -m "$MODEL" -c "model_reasoning_effort=\"$EFFORT\"" "reply exactly OK"
    exec "$@"
    ;;
  run) ;;
  *) exit 2;;
esac

# Delegate write/review launches to the existing hardened wrapper. This
# preserves writable Git metadata, effort forwarding, abort stash, heartbeat,
# and atomic REVIEW publication rather than reimplementing the contract.
if [ "$MODE" = write ] || [ "$PRODUCE_REVIEW" -eq 1 ]; then
  [ -n "$ISSUE_N" ] || { printf '%s\n' '{"ok":false,"code":"issue_required","detail":"Codex write/review requires --issue for codex-safe invariants"}' >&2; exit 3; }
  AGENT_WORKFLOW_CODEX_BIN="$BIN"
  export AGENT_WORKFLOW_CODEX_BIN
  set -- "$SCRIPT_DIR/codex-safe.sh" --issue "$ISSUE_N" --prompt-file "$PROMPT_FILE" --cwd "$CWD"
  [ -n "$MODEL" ] && set -- "$@" --model "$MODEL"; [ -n "$EFFORT" ] && set -- "$@" --effort "$EFFORT"
  [ "$PRODUCE_REVIEW" -eq 1 ] && set -- "$@" --produce-review
  exec "$@"
fi
set -- "$BIN" exec --sandbox read-only --cd "$CWD"; [ -n "$MODEL" ] && set -- "$@" -m "$MODEL"; [ -n "$EFFORT" ] && set -- "$@" -c "model_reasoning_effort=\"$EFFORT\""; exec "$@" "$PROMPT"
