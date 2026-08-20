#!/usr/bin/env bash
# Runtime-specific manual model preflight regression. bash-3.2-compatible.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CORE="$SCRIPT_DIR/../dispatch-core.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
mkdir -p "$BIN"
FAILURES=0
ok() { echo "ok   - $1"; }
bad() { echo "NOT OK - $1"; FAILURES=$((FAILURES + 1)); }

if [ "$(node "$SCRIPT_DIR/../lib/runtime-registry.cjs" effort-default codex)" = low ] \
  && [ "$(node "$SCRIPT_DIR/../lib/runtime-registry.cjs" effort-default claude)" = medium ] \
  && [ "$(node "$SCRIPT_DIR/../lib/runtime-registry.cjs" effort-default opencode)" = medium ]; then
  ok "runtime registry owns per-runtime omitted-effort defaults"
else
  bad "runtime registry omitted-effort defaults"
fi

cat > "$BIN/cmux" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo 'cmux 0.64.18'; exit 0; fi
if [ "${1:-}" = "workspace" ] && [ "${2:-}" = "create" ] && [ "${3:-}" = "--help" ]; then
  case "${CMUX_HELP_MODE:-live}" in
    direct) printf '%s\n' 'Usage: cmux workspace create --name NAME --cwd PATH --command TEXT'; exit 0 ;;
    unrelated) printf '%s\n' 'Usage: cmux workspace create [flags]'; exit 0 ;;
    *) printf '%s\n' '  create [flags]          Create a workspace (same flags as new-workspace)'; exit 0 ;;
  esac
fi
if [ "${1:-}" = "new-workspace" ] && [ "${2:-}" = "--help" ]; then echo '--cwd PATH --command TEXT'; exit 0; fi
while [ "$#" -gt 0 ]; do
  case "$1" in --cwd) cwd="$2"; shift 2;; --command) command="$2"; shift 2;; *) shift;; esac
done

[ -n "${command:-}" ] && [ -n "${cwd:-}" ] || exit 2
echo create >> "$CMUX_LOG"
(cd "$cwd" && bash -c "$command") >/dev/null 2>&1 || :
echo '{"id":"runtime-model-preflight"}'
EOF
chmod +x "$BIN/cmux"

make_runtime() {
  name="$1"
  cat > "$BIN/$name" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo 'runtime model smoke 1.0'; exit 0; fi
if [ "${1:-}" = "--help" ] || [ "${2:-}" = "--help" ]; then echo 'exec --sandbox --cd --model --config --output-last-message --json --print --permission-mode --output-format --effort --include-partial-messages run --dir --format --agent --variant json'; exit 0; fi
for arg in "$@"; do [ "$arg" = bad-model ] && exit 7; done
cwd="$PWD"
for arg in "$@"; do
  case "$arg" in
    --dir|--cd) next=1; continue ;;
    *) if [ "${next:-0}" -eq 1 ]; then cwd="$arg"; next=0; fi ;;
  esac
done
if [ -n "${RUNTIME_ARGS_LOG:-}" ]; then printf '%s\n' "$*" >> "$RUNTIME_ARGS_LOG"; fi
head="$(git -C "$cwd" rev-parse HEAD 2>/dev/null || true)"
if [ "${#head}" -eq 40 ]; then
  printf '%s\n' "{\"schema_version\":\"1\",\"artifact_type\":\"review\",\"lifecycle\":\"final\",\"producer_role\":\"REVIEWER\",\"producer_version\":\"runtime-smoke\",\"issue\":{\"number\":901},\"reviewed_head_sha\":\"$head\",\"status\":\"pass\",\"checklist\":[{\"item\":\"runtime smoke\",\"met\":true}]}"
fi
if [ "${EMIT_BLOCKER:-0}" = 1 ] && [ -n "${BLOCKER_TARGET:-}" ]; then
  printf '%s\n' '{"artifact_type":"blocker","reason_code":"malformed-runtime-smoke"}' > "$BLOCKER_TARGET"
fi
exit 0
EOF
  chmod +x "$BIN/$name"
}
make_runtime claude
make_runtime opencode

for runtime in claude opencode; do
  case "$runtime" in claude) runtime_var=AGENT_WORKFLOW_CLAUDE_BIN;; opencode) runtime_var=AGENT_WORKFLOW_OPENCODE_BIN;; esac
  case "$runtime" in claude) effort_marker='--effort medium';; opencode) effort_marker='--variant medium';; esac
  WT="$TMP/$runtime"
  mkdir -p "$WT/.review"
  git init -q "$WT"
  git -C "$WT" -c user.name=smoke -c user.email=smoke@example.test commit --allow-empty -qm init
  echo 'review prompt' > "$WT/.review/ISSUE-901-PROMPT.txt"
  export CMUX_LOG="$TMP/$runtime.cmux.log"
  : > "$CMUX_LOG"
  if env PATH="$BIN:$PATH" "$runtime_var=$BIN/$runtime" bash "$CORE" --adapter cmux --runtime "$runtime" --role reviewer --issue 901 --worktree "$WT" --produce-review --model bad-model --effort medium --poll-timeout 1 >"$TMP/$runtime.bad" 2>&1; then
    bad "$runtime rejects unavailable manual model before admission"
  elif grep -q 'model_compatibility_unavailable' "$TMP/$runtime.bad" && [ ! -s "$CMUX_LOG" ]; then
    ok "$runtime rejects unavailable manual model before adapter admission"
  else
    bad "$runtime manual model rejection is fail-closed"
  fi
  if RUNTIME_ARGS_LOG="$TMP/$runtime.args" env PATH="$BIN:$PATH" "$runtime_var=$BIN/$runtime" bash "$CORE" --adapter cmux --runtime "$runtime" --role reviewer --issue 901 --worktree "$WT" --produce-review --model good-model --poll-timeout 1 >"$TMP/$runtime.good" 2>&1; then
    head="$(git -C "$WT" rev-parse HEAD)"
    case "$runtime" in claude) probe_marker='--output-format text';; opencode) probe_marker='--format default';; esac
    if [ -f "$WT/.review/ISSUE-901-REVIEW.json" ] && [ -f "$WT/.review/ISSUE-901-REVIEW-$head.json" ] && cmp -s "$WT/.review/ISSUE-901-REVIEW.json" "$WT/.review/ISSUE-901-REVIEW-$head.json" && grep -q -- "$effort_marker" "$TMP/$runtime.args" && grep -q -- "$probe_marker" "$TMP/$runtime.args"; then
      ok "$runtime publishes immutable REVIEW snapshot before canonical publication"
      ok "$runtime model probe delegates its runtime-specific argv"
    else
      bad "$runtime did not publish head-bound snapshot before canonical publication: $(cat "$TMP/$runtime.good" 2>/dev/null)"
      bad "$runtime model probe did not delegate its runtime-specific argv"
    fi
  elif [ -s "$CMUX_LOG" ]; then
    ok "$runtime reached launch after selected model preflight"
  else
    bad "$runtime valid manual model did not reach launch"
  fi
done

# A reviewer may ask the allocator for the runtime-specific tuple. Claude's
# shipped alias must reach the same preflight and publication path as a manual
# tuple; OpenCode remains target-configured because provider/model IDs vary.
WT="$TMP/allocated-claude"
mkdir -p "$WT/.review"
git init -q "$WT"
git -C "$WT" -c user.name=smoke -c user.email=smoke@example.test commit --allow-empty -qm init
echo 'review prompt' > "$WT/.review/ISSUE-903-PROMPT.txt"
: > "$TMP/allocated-claude.args"
if RUNTIME_ARGS_LOG="$TMP/allocated-claude.args" CMUX_LOG="$TMP/allocated-claude.cmux.log" PATH="$BIN:$PATH" AGENT_WORKFLOW_CLAUDE_BIN="$BIN/claude" bash "$CORE" --adapter cmux --runtime claude --role reviewer --issue 903 --worktree "$WT" --produce-review --allocate --allocator-role reviewer --poll-timeout 1 >"$TMP/allocated-claude.out" 2>&1; then
  if grep -q -- '--model sonnet' "$TMP/allocated-claude.args" && grep -q -- '--effort medium' "$TMP/allocated-claude.args"; then
    ok "Claude reviewer allocation forwards the runtime-specific tuple"
  else
    bad "Claude reviewer allocation did not forward the runtime-specific tuple"
  fi
else
  bad "Claude reviewer allocation did not reach preflight and launch: $(cat "$TMP/allocated-claude.out")"
fi

# The cmux capability probe must prove --cwd/--command from `workspace create
# --help` itself (direct listing or explicit new-workspace delegation). The
# legacy new-workspace surface still answers in this fake, so an unrelated
# summary must be refused before any cmux side effect.
CAP_WT="$TMP/capability-probe"
mkdir -p "$CAP_WT/.review"
git init -q "$CAP_WT"
git -C "$CAP_WT" -c user.name=smoke -c user.email=smoke@example.test commit --allow-empty -qm init
capability_issue=905
for help_mode in live direct; do
  echo 'review prompt' > "$CAP_WT/.review/ISSUE-${capability_issue}-PROMPT.txt"
  : > "$TMP/capability-$help_mode.cmux.log"
  if CMUX_HELP_MODE="$help_mode" CMUX_LOG="$TMP/capability-$help_mode.cmux.log" \
    PATH="$BIN:$PATH" AGENT_WORKFLOW_CLAUDE_BIN="$BIN/claude" bash "$CORE" --adapter cmux --runtime claude \
    --role reviewer --issue "$capability_issue" --worktree "$CAP_WT" --produce-review --model good-model --poll-timeout 1 \
    >"$TMP/capability-$help_mode.out" 2>&1 && [ -s "$TMP/capability-$help_mode.cmux.log" ]; then
    ok "AC-112 $help_mode workspace create --help proves --cwd/--command and reaches launch"
  else
    bad "AC-112 $help_mode workspace create --help did not reach launch: $(cat "$TMP/capability-$help_mode.out")"
  fi
  capability_issue=$((capability_issue + 1))
done
echo 'review prompt' > "$CAP_WT/.review/ISSUE-${capability_issue}-PROMPT.txt"
: > "$TMP/capability-unrelated.cmux.log"
CMUX_HELP_MODE=unrelated CMUX_LOG="$TMP/capability-unrelated.cmux.log" \
  PATH="$BIN:$PATH" AGENT_WORKFLOW_CLAUDE_BIN="$BIN/claude" bash "$CORE" --adapter cmux --runtime claude \
  --role reviewer --issue "$capability_issue" --worktree "$CAP_WT" --produce-review --model good-model --poll-timeout 1 \
  >"$TMP/capability-unrelated.out" 2>&1
capability_ec=$?
if [ "$capability_ec" -eq 2 ] && grep -q 'required_capability_missing' "$TMP/capability-unrelated.out" \
  && [ ! -s "$TMP/capability-unrelated.cmux.log" ]; then
  ok "AC-112 unrelated workspace create --help is rejected before any cmux side effect"
else
  bad "AC-112 unrelated workspace create --help refusal (ec=$capability_ec: $(cat "$TMP/capability-unrelated.out"))"
fi

# Claude/OpenCode implementation seats must apply the same canonical BLOCKER
# schema/identity/lifecycle gate as codex-safe when the runtime emits one.
for runtime in claude opencode; do
  case "$runtime" in claude) runtime_var=AGENT_WORKFLOW_CLAUDE_BIN;; opencode) runtime_var=AGENT_WORKFLOW_OPENCODE_BIN;; esac
  WT="$TMP/blocker-$runtime"
  mkdir -p "$WT/.review"
  git init -q "$WT"
  git -C "$WT" -c user.name=smoke -c user.email=smoke@example.test commit --allow-empty -qm init
  echo 'implementation prompt' > "$WT/.review/ISSUE-902-PROMPT.txt"
  blocker_target="$WT/.review/ISSUE-902-BLOCKER.json"
  permission_args=""
  [ "$runtime" = opencode ] && permission_args="--opencode-permission-file $SCRIPT_DIR/../runtimes/opencode-write.json"
  if env EMIT_BLOCKER=1 BLOCKER_TARGET="$blocker_target" PATH="$BIN:$PATH" "$runtime_var=$BIN/$runtime" bash "$SCRIPT_DIR/../agent-watchdog.sh" --issue 902 --runtime "$runtime" --role implementation --mode write --prompt-file "$WT/.review/ISSUE-902-PROMPT.txt" --cwd "$WT" --model good-model --effort medium $permission_args --max-retries 0 >"$TMP/$runtime.blocker.out" 2>&1; then
    bad "$runtime rejects malformed BLOCKER output"
  elif grep -q 'BLOCKER output is not schema-valid' "$TMP/$runtime.blocker.out" && [ -f "$blocker_target" ]; then
    ok "$runtime applies canonical BLOCKER validation"
  else
    bad "$runtime BLOCKER validation is fail-closed"
  fi
done

echo "---"
if [ "$FAILURES" -eq 0 ]; then echo 'ALL CASES PASS'; exit 0; fi
echo "$FAILURES CASE(S) FAILED"; exit 1
