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
  # Post-admission launch preparation, invoked by the transport immediately
  # before the real launch (never at launch-spec preflight). Pre-seeds
  # codex's own per-directory trust store (#215): its first-run trust prompt
  # can never be classified by screen-scraping transports (#212). Runtime-
  # owned per the axis rule; claude/opencode's pre-launch is a no-op.
  # Only ENOENT counts as absent config; anything else fails closed.
  pre-launch)
    prelaunch_cwd=""
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        --cwd)
          [ $# -ge 2 ] || exit 2
          prelaunch_cwd="$2"; shift 2 ;;
        *) exit 2 ;;
      esac
    done
    [ -n "$prelaunch_cwd" ] || exit 2
    codex_trust_preseed "$prelaunch_cwd" || {
      printf '%s\n' '{"ok":false,"code":"codex_trust_preseed_failed","detail":"Codex live launch could not pre-seed the per-directory trust entry in ${CODEX_HOME:-$HOME/.codex}/config.toml"}' >&2
      exit 3
    }
    exit 0
    ;;
  launch-spec)
    # Pure/spec-only: dispatch-core calls launch-spec as a side-effect-free
    # preflight before admission, so it must never mutate user config.
    # Trust-store pre-seeding lives in pre-launch below (#218 review).
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
set -- "$BIN" exec --sandbox read-only --cd "$CWD"
# The progress event stream is registry data (PROGRESS.codex.flags), not a
# hardcoded --json argv. Both direct read launches and codex-safe.sh own their
# respective headless Codex argv construction and fail closed if the registry
# cannot provide the streaming contract.
progress_flags="$(node "$RUNTIME_REGISTRY" progress-flags "$RUNTIME")" || { printf '%s\n' '{"ok":false,"code":"runtime_registry_unavailable","detail":"progress-flags lookup failed"}' >&2; exit 3; }
while IFS= read -r flag; do [ -n "$flag" ] && set -- "$@" "$flag"; done <<PROGRESS_FLAGS
$progress_flags
PROGRESS_FLAGS
[ -n "$MODEL" ] && set -- "$@" -m "$MODEL"; [ -n "$EFFORT" ] && set -- "$@" -c "model_reasoning_effort=\"$EFFORT\""; exec "$@" "$PROMPT"
