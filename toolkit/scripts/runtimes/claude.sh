#!/usr/bin/env bash
# Claude runtime member: permission-mode and progress-stream invocation.
# bash-3.2 compatible.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_REGISTRY="$SCRIPT_DIR/../lib/runtime-registry.cjs"
COMMAND="${1:-}"
case "$COMMAND" in
  permission-file) exit 0;;
  run) ;;
  *) exit 2;;
esac

[ "$MODE" = write ] && permission=acceptEdits || permission=plan
set -- "$BIN" --print --permission-mode "$permission"
# The progress event stream is registry data (PROGRESS.claude.flags), not
# a hardcoded --output-format text argv — agent-watchdog.sh's progressed()
# and transcribe_review() key off this same table to read the stream back.
# Fail closed like every other registry read in this file: a missing
# entry must never silently launch with no --output-format at all.
progress_flags="$(node "$RUNTIME_REGISTRY" progress-flags "$RUNTIME")" || { printf '%s\n' '{"ok":false,"code":"runtime_registry_unavailable","detail":"progress-flags lookup failed"}' >&2; exit 3; }
while IFS= read -r flag; do [ -n "$flag" ] && set -- "$@" "$flag"; done <<PROGRESS_FLAGS
$progress_flags
PROGRESS_FLAGS
[ -n "$MODEL" ] && set -- "$@" --model "$MODEL"; [ -n "$EFFORT" ] && set -- "$@" --effort "$EFFORT"; cd "$CWD"; exec "$@" "$PROMPT"
