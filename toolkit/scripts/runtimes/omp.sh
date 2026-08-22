#!/usr/bin/env bash
# OMP runtime member: approval-mode mapping and NDJSON progress invocation.
# bash-3.2 compatible.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_REGISTRY="$SCRIPT_DIR/../lib/runtime-registry.cjs"
COMMAND="${1:-}"
case "$COMMAND" in
  permission-file) exit 0;;
  launch-spec)
    # omp has no separate read-only sandbox; write mode lifts the approval
    # gate to writes only, read mode keeps the configured default (ask).
    [ "$MODE" = write ] && set -- "$BIN" --approval-mode write || set -- "$BIN"
    set -- "$@" --cwd "$CWD"
    [ -n "$MODEL" ] && set -- "$@" --model "$MODEL"
    [ -n "$EFFORT" ] && set -- "$@" --thinking "$EFFORT"
    # Bare `omp` is the interactive TUI. Headless -p and --mode json remain
    # exclusively in the probe/run branches below.
    node "$SCRIPT_DIR/../lib/launch-spec.cjs" emit omp "$CWD" "$(node "$RUNTIME_REGISTRY" prompt-delivery omp)" '{}' "$@"
    exit $?
    ;;
  probe)
    set -- "$BIN" -p --model "$MODEL" --thinking "$EFFORT" "reply exactly OK"
    exec "$@"
    ;;
  run) ;;
  *) exit 2;;
esac

[ "$MODE" = write ] && set -- "$BIN" -p --approval-mode write || set -- "$BIN" -p
# The progress event stream is registry data (PROGRESS.omp.flags), not a
# hardcoded --mode json argv — agent-watchdog.sh's progressed() and
# transcribe_review() key off this same table to read the stream back.
# Fail closed like every other registry read in this file.
progress_flags="$(node "$RUNTIME_REGISTRY" progress-flags "$RUNTIME")" || { printf '%s\n' '{"ok":false,"code":"runtime_registry_unavailable","detail":"progress-flags lookup failed"}' >&2; exit 3; }
while IFS= read -r flag; do [ -n "$flag" ] && set -- "$@" "$flag"; done <<PROGRESS_FLAGS
$progress_flags
PROGRESS_FLAGS
[ -n "$MODEL" ] && set -- "$@" --model "$MODEL"; [ -n "$EFFORT" ] && set -- "$@" --thinking "$EFFORT"; cd "$CWD"; exec "$@" "$PROMPT"
