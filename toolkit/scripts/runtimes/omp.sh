#!/usr/bin/env bash
# OMP runtime member: approval-mode mapping and NDJSON progress invocation.
# bash-3.2 compatible.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_REGISTRY="$SCRIPT_DIR/../lib/runtime-registry.cjs"
COMMAND="${1:-}"
case "$COMMAND" in
  permission-file) exit 0;;
  pre-launch) exit 0;;
  launch-spec)
    # Write mode lifts the approval gate to writes only (--approval-mode
    # write) plus --auto-approve: relying on tools.approvalMode's default
    # (yolo on v17.4.2) proved version-fragile — v18.0.10 no longer defaults
    # to non-interactive, so headless write-mode dispatch stalled on bash
    # approval prompts (#confirmed on v18.0.10). Read mode is fail-closed and
    # config-independent: pinning a read-only tool surface (--tools
    # read,grep,glob) is what actually removes the write/bash tools —
    # approval mode alone cannot.
    if [ "$MODE" = write ]; then
      set -- "$BIN" --approval-mode write --auto-approve
    else
      set -- "$BIN" --tools read,grep,glob
    fi
    set -- "$@" --cwd "$CWD"
    [ -n "$MODEL" ] && set -- "$@" --model "$MODEL"
    [ -n "$EFFORT" ] && set -- "$@" --thinking "$EFFORT"
    # Bare `omp` is the interactive TUI. Headless -p and --mode json remain
    # exclusively in the probe/run branches below.
    node "$SCRIPT_DIR/../lib/launch-spec.cjs" emit omp "$CWD" "$(node "$RUNTIME_REGISTRY" prompt-delivery omp)" '{}' "$@"
    exit $?
    ;;
  probe)
    # The probe is a harmless preflight, but headless non-write launches get
    # the same fail-closed tool surface as workflow read mode.
    set -- "$BIN" -p --tools read,grep,glob --model "$MODEL" --thinking "$EFFORT" "reply exactly OK"
    exec "$@"
    ;;
  run) ;;
  *) exit 2;;
esac

# Same fail-closed read policy as launch-spec: a read-only tool surface,
# not an approval-mode default (see launch-spec comment above).
if [ "$MODE" = write ]; then set -- "$BIN" -p --approval-mode write --auto-approve; else set -- "$BIN" -p --tools read,grep,glob; fi
# The progress event stream is registry data (PROGRESS.omp.flags), not a
# hardcoded --mode json argv — agent-watchdog.sh's progressed() and
# transcribe_review() key off this same table to read the stream back.
# Fail closed like every other registry read in this file.
progress_flags="$(node "$RUNTIME_REGISTRY" progress-flags "$RUNTIME")" || { printf '%s\n' '{"ok":false,"code":"runtime_registry_unavailable","detail":"progress-flags lookup failed"}' >&2; exit 3; }
while IFS= read -r flag; do [ -n "$flag" ] && set -- "$@" "$flag"; done <<PROGRESS_FLAGS
$progress_flags
PROGRESS_FLAGS
[ -n "$MODEL" ] && set -- "$@" --model "$MODEL"; [ -n "$EFFORT" ] && set -- "$@" --thinking "$EFFORT"; cd "$CWD"
# POSIX separator: a prompt whose first character is "-" (e.g. a Markdown
# bullet) must never parse as a CLI flag.
exec "$@" -- "$PROMPT"
