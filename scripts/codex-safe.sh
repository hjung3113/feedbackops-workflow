#!/usr/bin/env bash
# codex exec wrapper. Enforces: workspace-write sandbox, --cwd lock,
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue) ISSUE_N="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
    --cwd) CWD="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -z "$ISSUE_N" ]] && { echo "missing --issue" >&2; exit 2; }
[[ -z "$PROMPT" && -z "$PROMPT_FILE" ]] && { echo "missing --prompt or --prompt-file" >&2; exit 2; }
[[ -n "$PROMPT_FILE" ]] && PROMPT="$(cat "$PROMPT_FILE")"

# Trap to stash ONLY on non-zero exit (codex failure or abort).
# On success, leave artifacts alone — agent already wrote its handoff files.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
trap 's=$?; if [[ $s -ne 0 ]]; then "$SCRIPT_DIR/workflow-stash.sh" "$ISSUE_N" "$CWD" || true; fi; exit $s' EXIT

cd "$CWD"

codex exec \
  --sandbox workspace-write \
  --cwd "$CWD" \
  "$PROMPT"
