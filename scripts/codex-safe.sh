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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue) ISSUE_N="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
    --cwd) CWD="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --effort) EFFORT="$2"; shift 2 ;;
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

# Trap to stash ONLY on non-zero exit (codex failure or abort).
# On success, leave artifacts alone — agent already wrote its handoff files.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
trap 's=$?; if [[ $s -ne 0 ]]; then "$SCRIPT_DIR/workflow-stash.sh" "$ISSUE_N" "$CWD" || true; fi; exit $s' EXIT

cd "$CWD"

EXTRA=()
[[ -n "$MODEL" ]] && EXTRA+=( -m "$MODEL" )
[[ -n "$EFFORT" ]] && EXTRA+=( -c "model_reasoning_effort=\"$EFFORT\"" )

if [[ "${#EXTRA[@]}" -gt 0 ]]; then
  codex exec \
    --sandbox workspace-write \
    --cd "$CWD" \
    "${EXTRA[@]}" \
    "$PROMPT"
else
  codex exec \
    --sandbox workspace-write \
    --cd "$CWD" \
    "$PROMPT"
fi
