#!/usr/bin/env bash
# Codex runtime member: invocation shape and Codex write isolation.
# bash-3.2 compatible.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_REGISTRY="$SCRIPT_DIR/../lib/runtime-registry.cjs"
. "$SCRIPT_DIR/../lib/codex-policy.sh"
COMMAND="${1:-}"
case "$COMMAND" in
  permission-file) exit 0;;
  launch-spec)
    EFFORT="$(codex_pin_effort "$MODEL" "$EFFORT")"
    if [ "$MODE" = write ]; then
      sandbox="workspace-write"
      git_common_dir="$(codex_git_common_dir "$CWD")" || {
        printf '%s\n' '{"ok":false,"code":"git_common_dir_unavailable","detail":"Codex live write launch requires a resolvable git common directory"}' >&2
        exit 3
      }
    else
      sandbox="read-only"
      git_common_dir=""
    fi
    set -- "$BIN" --sandbox "$sandbox" --cd "$CWD"
    [ -n "$git_common_dir" ] && set -- "$@" --add-dir "$git_common_dir"
    [ -n "$MODEL" ] && set -- "$@" -m "$MODEL"
    [ -n "$EFFORT" ] && set -- "$@" -c "model_reasoning_effort=\"$EFFORT\""
    # Interactive Codex must not inherit an approval prompt from user config.
    set -- "$@" --ask-for-approval never
    node "$SCRIPT_DIR/../lib/launch-spec.cjs" emit codex "$CWD" "$(node "$RUNTIME_REGISTRY" prompt-delivery codex)" '{}' "$@"
    exit $?
    ;;
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
