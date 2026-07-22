#!/usr/bin/env bash
# Schema-derived output-contract interface. Bash 3.2 compatible.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
usage() { echo "usage: output-contract.sh render|check --role ROLE [--prompt-file FILE] [--schema-dir DIR]" >&2; }
COMMAND="${1:-}"; [ -n "$COMMAND" ] || { usage; exit 2; }; shift
ROLE=""; PROMPT=""; SCHEMAS=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --role) ROLE="${2:-}"; shift 2 ;;
    --prompt-file) PROMPT="${2:-}"; shift 2 ;;
    --schema-dir) SCHEMAS="${2:-}"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
[ -n "$ROLE" ] || { usage; exit 2; }
if [ "$COMMAND" = "check" ] && [ -z "$PROMPT" ]; then usage; exit 2; fi
exec node "$SCRIPT_DIR/lib/output-contract.mjs" "$COMMAND" "$ROLE" "$PROMPT" "$SCHEMAS"
