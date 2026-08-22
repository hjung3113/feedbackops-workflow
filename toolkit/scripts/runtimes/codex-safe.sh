#!/usr/bin/env bash
# codex exec wrapper. Enforces: workspace-write sandbox, --cd working-dir lock,
# optional abort-stash for partial work preservation.
#
# Usage:
#   scripts/runtimes/codex-safe.sh --issue 33 --prompt-file /path/to/prompt.txt
#   scripts/runtimes/codex-safe.sh --issue 33 --prompt "inline prompt"
set -euo pipefail

ISSUE_N=""
PROMPT=""
PROMPT_FILE=""
CWD="$(pwd)"
MODEL=""
EFFORT=""
EFFORT_EXPLICIT=0
HEARTBEAT_FILE=""
HEARTBEAT_PID=""
HEARTBEAT_INTERVAL="${CODEX_SAFE_HEARTBEAT_INTERVAL:-20}"
PRODUCE_REVIEW=0
REVIEW_OUTPUT_FILE=""
CODEX_BIN="${AGENT_WORKFLOW_CODEX_BIN:-codex}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/codex-policy.sh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue) ISSUE_N="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
    --cwd) CWD="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --effort) EFFORT="$2"; EFFORT_EXPLICIT=1; shift 2 ;;
    --heartbeat-file) HEARTBEAT_FILE="$2"; shift 2 ;;
    --produce-review) PRODUCE_REVIEW=1; shift 1 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# As of
# 2026-07-15 the 5.6 family IS available on the ChatGPT account via suffixed
# variants; bare "gpt-5.6" still 400s. Ladder: sol (top, reasoning-heavy) >
# terra (everyday impl) > luna (light). Default allocation: design/contract =
# gpt-5.6-sol medium, implementation = gpt-5.6-terra low, mechanical =
# gpt-5.6-luna low. Review remains an external clean-context Opus medium seat
# (docs/agents/multi-agent-workflow.md "Model Allocation").
# If effort is omitted for 5.6, pin the dispatched config to its documented
# medium default so user/global config cannot silently change it.
EFFORT="$(codex_pin_effort "$MODEL" "$EFFORT")"

[[ -z "$ISSUE_N" ]] && { echo "missing --issue" >&2; exit 2; }
[[ -z "$PROMPT" && -z "$PROMPT_FILE" ]] && { echo "missing --prompt or --prompt-file" >&2; exit 2; }
[[ -n "$PROMPT_FILE" ]] && PROMPT="$(cat "$PROMPT_FILE")"
[[ -z "$PROMPT" ]] && { echo "prompt is empty (check --prompt-file content)" >&2; exit 2; }
if [[ "$PRODUCE_REVIEW" -eq 1 ]]; then
  [[ -n "$MODEL" && "$EFFORT_EXPLICIT" -eq 1 ]] || { echo "--produce-review requires explicit --model and --effort" >&2; exit 2; }
  REVIEW_OUTPUT_FILE="$CWD/.review/.ISSUE-${ISSUE_N}-REVIEW.json.tmp.$$"
fi

# Stop the heartbeat ticker before any failure-path stash. The explicit
# post-wait stop below is the normal path; this trap covers signals and shell
# failures so a read-only dispatch never leaves a ticker behind.
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
  if [[ "$PRODUCE_REVIEW" -eq 1 && -n "$REVIEW_OUTPUT_FILE" ]]; then
    rm -f "$REVIEW_OUTPUT_FILE"
  fi
  if [[ $s -ne 0 && "$PRODUCE_REVIEW" -eq 0 ]]; then
    codex_stash_partial_work "$SCRIPT_DIR/../workflow-stash.sh" "$ISSUE_N" "$CWD" || true
  fi
  trap - EXIT
  exit "$s"
}
trap cleanup EXIT

cd "$CWD"
REVIEW_START_HEAD=""
if [[ "$PRODUCE_REVIEW" -eq 1 ]]; then
  REVIEW_START_HEAD="$(git -C "$CWD" rev-parse HEAD 2>/dev/null || true)"
  [[ "$REVIEW_START_HEAD" =~ ^[0-9a-f]{40}$ ]] || { echo "ERROR: cannot pin REVIEW start HEAD" >&2; exit 2; }
fi

blocker_signature() {
  file="$1"
  [ -f "$file" ] || { printf '%s\n' "absent"; return; }
  node - "$file" <<'NODE'
const fs=require("fs"), crypto=require("crypto"), file=process.argv[2];
try {
  const stat=fs.statSync(file);
  const hash=crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
  process.stdout.write(String(stat.size)+":"+String(stat.mtimeMs)+":"+hash+"\n");
} catch (_) { process.stdout.write("unreadable\n"); }
NODE
}
BLOCKER_PATH="$CWD/.review/ISSUE-$ISSUE_N-BLOCKER.json"
BLOCKER_BEFORE_SIG="$(blocker_signature "$BLOCKER_PATH")"

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
# instruction. No prompt wording can fix a sandbox denial. Grant only the
# resolved git common dir explicitly: a plain checkout needs its in-tree .git
# too, because workspace-write still denies Git metadata writes by default.
GIT_COMMON_DIR="$(codex_git_common_dir "$CWD" || true)"
if [[ "$PRODUCE_REVIEW" -eq 0 && -n "$GIT_COMMON_DIR" ]]; then
  EXTRA+=( -c "sandbox_workspace_write.writable_roots=[\"$GIT_COMMON_DIR\"]" )
fi

if [[ "$PRODUCE_REVIEW" -eq 1 ]]; then
  mkdir -p "$CWD/.review"
  rm -f "$REVIEW_OUTPUT_FILE"
  set -- "$CODEX_BIN" exec --sandbox read-only --cd "$CWD" --output-last-message "$REVIEW_OUTPUT_FILE"
  [[ -n "$MODEL" ]] && set -- "$@" -m "$MODEL"
  [[ -n "$EFFORT" ]] && set -- "$@" -c "model_reasoning_effort=\"$EFFORT\""
  "$@" "$PROMPT" &
elif [[ "${#EXTRA[@]}" -gt 0 ]]; then
  "$CODEX_BIN" exec \
    --sandbox workspace-write \
    --cd "$CWD" \
    "${EXTRA[@]}" \
    "$PROMPT" &
else
  "$CODEX_BIN" exec \
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
BLOCKER_AFTER_SIG="$(blocker_signature "$BLOCKER_PATH")"
if [[ "$PRODUCE_REVIEW" -eq 0 && "$BLOCKER_AFTER_SIG" != "$BLOCKER_BEFORE_SIG" && "$BLOCKER_AFTER_SIG" != "absent" ]]; then
  if ! node "$SCRIPT_DIR/../lib/blocker-check.cjs" "$BLOCKER_PATH" "$SCRIPT_DIR/../../schemas/blocker.schema.json" "$SCRIPT_DIR/../lib/json-schema-subset.cjs" "$ISSUE_N" "$CWD" >/dev/null 2>&1
  then
    echo "ERROR: BLOCKER output is not schema-valid/current/consumable for this issue; preserve it and regenerate the canonical artifact before redispatch" >&2
    CODEX_EXIT=1
  fi
fi
if [[ "$CODEX_EXIT" -eq 0 && "$PRODUCE_REVIEW" -eq 1 ]]; then
  canonical_review="$CWD/.review/ISSUE-${ISSUE_N}-REVIEW.json"
if ! node - "$REVIEW_OUTPUT_FILE" "$SCRIPT_DIR/../../schemas/review.schema.json" "$SCRIPT_DIR/../lib/json-schema-subset.cjs" "$ISSUE_N" "$CWD" "$REVIEW_START_HEAD" <<'NODE'
const fs = require("fs");
const [artifactFile, schemaFile, validatorFile, issueNumber, worktree, expectedHead] = process.argv.slice(2);
try {
  const artifact = JSON.parse(fs.readFileSync(artifactFile, "utf8"));
  const schema = JSON.parse(fs.readFileSync(schemaFile, "utf8"));
  const { validate } = require(validatorFile);
  const baseSchema = Object.assign({}, schema);
  delete baseSchema.if;
  delete baseSchema.then;
  const invalidFailedReview = artifact.status === "fail"
    && (!Array.isArray(artifact.findings) || artifact.findings.length < 1 || typeof artifact.patch_instructions !== "string");
  const errors = validate(baseSchema, artifact);
  if (errors.length || invalidFailedReview || String(artifact.issue.number) !== issueNumber || artifact.reviewed_head_sha !== expectedHead) {
    console.error(errors.join("; ") || "review issue, failed-review fields, or live HEAD mismatch");
    process.exit(2);
  }
} catch (error) {
  process.exit(2);
}
NODE
  then
    echo "ERROR: REVIEW output is not a schema-valid canonical artifact for this issue and live HEAD" >&2
    exit 1
  fi
  if ! node "$SCRIPT_DIR/../lib/review-publish.cjs" "$REVIEW_OUTPUT_FILE" "$CWD/.review" "$ISSUE_N" "$CWD" "$REVIEW_START_HEAD" >/dev/null 2>&1; then
    echo "ERROR: REVIEW publication lost its pinned HEAD or conflicted with immutable evidence" >&2
    exit 1
  fi
fi
exit "$CODEX_EXIT"
