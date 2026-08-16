#!/usr/bin/env bash
# Offline contract for the transport-neutral orchestrator interface.
# bash-3.2-compatible. AC-ORCH-1 AC-ORCH-2 AC-ORCH-3 AC-ORCH-4
# AC-ORCH-5 AC-ORCH-6 AC-ORCH-7 AC-ORCH-8
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VALIDATOR="$ROOT/scripts/lib/json-schema-subset.cjs"
SCHEMA="$ROOT/schemas/transport_receipt.schema.json"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
PRODUCT_HOME="$TMP_ROOT/product-home"
mkdir -p "$PRODUCT_HOME"
cp -R "$ROOT/scripts" "$PRODUCT_HOME/scripts"
cp -R "$ROOT/schemas" "$PRODUCT_HOME/schemas"
cp "$ROOT/model-alloc.json" "$PRODUCT_HOME/model-alloc.json"
CLI="$PRODUCT_HOME/scripts/agent-workflow.sh"
FAILURES=0
pass() { echo "ok   - $1"; }
fail() { echo "NOT OK - $1"; FAILURES=$((FAILURES + 1)); }

make_worktree() {
  path="$1"
  issue="$2"
mkdir -p "$path/.review"
  git init -q "$path"
  git -C "$path" -c user.name=smoke -c user.email=smoke@example.test commit --allow-empty -qm init
  printf '%s\n' 'worker prompt' > "$path/.review/ISSUE-${issue}-PROMPT.md"
  "$ROOT/scripts/output-contract.sh" render --role implementation >> "$path/.review/ISSUE-${issue}-PROMPT.md"
}

BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"
# The runtime adapter pins the executable path reported by `command -v`.
# Preserve that spelling here: macOS maps /var to /private/var under pwd -P.
RESOLVED_BIN="$BIN"
cat > "$BIN/cmux" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo 'cmux 0.64.18'; exit 0; fi
if [ "${1:-}" = "workspace" ] && [ "${2:-}" = "create" ] && [ "${3:-}" = "--help" ]; then
  case "${CMUX_HELP_MODE:-live}" in
    direct)
      printf '%s\n' 'Usage: cmux workspace create [flags]' '  --cwd PATH       Working directory for the workspace' '  --command TEXT   Command the workspace runs'
      ;;
    delegation)
      printf '%s\n' 'Usage: cmux workspace create [flags]' '  create accepts the same flag set as new-workspace'
      ;;
    mention_only)
      printf '%s\n' 'cmux workspace' 'Legacy verbs (new-workspace, list-workspaces) keep working.' 'All workspace verbs apply the same validation rules.'
      ;;
    unrelated)
      printf '%s\n' 'Usage: cmux workspace create' 'create [flags]'
      ;;
    flagless)
      printf '%s\n' 'Usage: cmux workspace create [flags]' '  --name TEXT      Workspace name' '  --json           Emit JSON output'
      ;;
    live)
      printf '%s\n' 'cmux workspace' '' 'Usage: cmux workspace <subcommand> [flags]' '' 'Canonical noun for workspace operations. Legacy verbs' '(new-workspace, list-workspaces, close-workspace,' 'rename-workspace, select-workspace) keep working and print a' 'one-time deprecation hint pointing here.' '' 'Subcommands:' '  list                    List workspaces in a window' '  create [flags]          Create a workspace (same flags as new-workspace)' '  env [workspace] [--mask]' '  close <workspace>       Close a workspace' '  rename <workspace> --title <new>' '  select <workspace>      Make a workspace active' '' 'Examples:' '  cmux workspace list --json' '  cmux workspace create --name Build --cwd ~/projects/myapp' '  cmux workspace close workspace:3'
      ;;
  esac
  exit 0
fi
if [ "${1:-}" = "new-workspace" ] && [ "${2:-}" = "--help" ]; then
  if [ "${CMUX_NEW_WORKSPACE_HELP_MODE:-flags}" = "flagless" ]; then
    printf '%s\n' 'Usage: cmux new-workspace [name]' '  Create a workspace with default settings'
  else
    echo '--cwd PATH --command TEXT'
  fi
  exit 0
fi
if [ "${1:-}" = "workspace" ] && [ "${2:-}" = "list" ] && [ "${3:-}" = "--json" ]; then
  case "${CMUX_LIST_MODE:-live}" in
    live) printf '%s\n' '{"workspaces":[{"ref":"workspace:11","name":"codex-502"}]}' ;;
    id_key) printf '%s\n' '{"workspaces":[{"id":"cmux-502","name":"codex-502"}]}' ;;
    duplicate_name) printf '%s\n' '{"workspaces":[{"ref":"workspace:11","name":"same-name"},{"ref":"workspace:12","name":"same-name"}]}' ;;
    removed) printf '%s\n' '{"workspaces":[{"ref":"workspace:12","name":"codex-502"}]}' ;;
    decoy) printf '%s\n' '{"workspaces":[{"ref":"workspace:12","name":"codex-502","request":{"id":"workspace:11"}}]}' ;;
    invalid) printf '%s\n' '{"workspaces":' ;;
    fail) exit 2 ;;
  esac
  exit 0
fi
printf 'cmux' >> "$TRANSPORT_USED"
printf '%s\n' "$@" > "$CMUX_ARGV"
cwd=""; name=""
while [ $# -gt 0 ]; do
  case "$1" in
    --cwd) cwd="$2"; shift 2 ;;
    --name) name="$2"; shift 2 ;;
    *) shift ;;
  esac
done
issue="${CMUX_CREATE_ISSUE_OVERRIDE:-${name#codex-}}"
printf '%s\n' "{\"schema_version\":\"1\",\"artifact_type\":\"codex_run\",\"issue\":$issue,\"attempt\":1,\"started_at\":\"2026-07-21T01:00:00Z\",\"updated_at\":\"2026-07-21T01:00:00Z\",\"status\":\"running\"}" > "$cwd/.review/ISSUE-${issue}-RUN.json"
case "${CMUX_CREATE_SHAPE:-plain}" in
  plain) printf 'OK workspace:11\n' ;;
  id) node -e 'process.stdout.write(JSON.stringify({workspace:{id:`cmux-${process.argv[1]}`,name:process.argv[2]}})+"\n")' "$issue" "$name" ;;
  ref) node -e 'process.stdout.write(JSON.stringify({result:{ref:`cmux-${process.argv[1]}`}})+"\n")' "$issue" ;;
  name_only) node -e 'process.stdout.write(JSON.stringify({workspace:{name:process.argv[1]}})+"\n")' "$name" ;;
  ambiguous) printf '%s\n' '{"id":"cmux-one","ref":"cmux-two"}' ;;
  decoy_id) node -e 'process.stdout.write(JSON.stringify({workspace:{id:`cmux-${process.argv[1]}`,name:process.argv[2],request:{id:"nested-decoy-502"}}})+"\n")' "$issue" "$name" ;;
  missing) printf '\n' ;;
  invalid) printf 'created workspace:cmux-%s\n' "$issue" ;;
esac
EOF
cat > "$BIN/orca" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "terminal" ] && [ "${2:-}" = "create" ] && [ "${3:-}" = "--help" ]; then
  printf '%s\n' 'Usage: orca terminal create --worktree PATH --title NAME --command TEXT --json'
  exit 0
fi
if [ "${1:-}" = "terminal" ] && [ "${2:-}" = "list" ] && [ "${3:-}" = "--help" ]; then
  printf '%s\n' 'Usage: orca terminal list --worktree PATH --json'
  exit 0
fi
if [ "${1:-}" = "--version" ]; then echo 'orca'; exit 0; fi
if [ "${1:-}" = "status" ] && [ "${2:-}" = "--json" ]; then
  case "${ORCA_STATUS_MODE:-real}" in
    real) printf '%s\n' '{"result":{"runtime":{"appVersion":"1.4.161"}}}' ;;
    missing) printf '%s\n' '{"result":{"runtime":{}}}' ;;
    non_string) printf '%s\n' '{"result":{"runtime":{"appVersion":104161}}}' ;;
    literal) printf '%s\n' '{"result":{"runtime":{"appVersion":"orca"}}}' ;;
    multiline) printf '%s\n' '{"result":{"runtime":{"appVersion":"1.4.161\\nUsage: orca"}}}' ;;
    usage) printf '%s\n' '{"result":{"runtime":{"appVersion":"Usage: orca status --json"}}}' ;;
    invalid) printf '%s\n' 'not JSON' ;;
    fail) exit 2 ;;
  esac
  exit 0
fi
if [ "${1:-}" = "terminal" ] && [ "${2:-}" = "list" ]; then
  case "${ORCA_LIST_MODE:-live}" in
    live) printf '%s\n' '{"result":{"terminals":[{"handle":"term-503"}]}}' ;;
    missing) printf '%s\n' '{"result":{"terminals":[]}}' ;;
    unknown) printf '%s\n' '{"result":{"terminals":[{"id":"request-503"}]}}' ;;
    invalid) printf '%s\n' '{"result":{}}' ;;
    fail) exit 2 ;;
  esac
  exit 0
fi
printf 'orca' >> "$TRANSPORT_USED"
printf '%s\n' "$@" > "$ORCA_ARGV"
worktree=""; title=""
while [ $# -gt 0 ]; do
  case "$1" in
    --worktree) worktree="${2#path:}"; shift 2 ;;
    --title) title="$2"; shift 2 ;;
    *) shift ;;
  esac
done
issue="${title#codex-}"
printf '%s\n' "{\"schema_version\":\"1\",\"artifact_type\":\"codex_run\",\"issue\":$issue,\"attempt\":1,\"started_at\":\"2026-07-21T01:00:01Z\",\"updated_at\":\"2026-07-21T01:00:01Z\",\"status\":\"running\"}" > "$worktree/.review/ISSUE-${issue}-RUN.json"
case "${ORCA_CREATE_MODE:-actual}" in
  actual) printf '%s\n' "{\"id\":\"request-$issue\",\"result\":{\"terminal\":{\"handle\":\"term-$issue\"}}}" ;;
  missing) printf '%s\n' "{\"id\":\"request-$issue\",\"result\":{\"terminal\":{}}}" ;;
  ambiguous) printf '%s\n' "{\"id\":\"request-$issue\",\"result\":{\"terminal\":[{\"handle\":\"term-$issue\"},{\"handle\":\"term-other\"}]}}" ;;
esac
EOF
cat > "$BIN/herdr" <<'EOF'
#!/usr/bin/env bash
set -u

STATE_DIR="${HERDR_STATE_DIR:-${TMPDIR:-/tmp}/herdr-fake-state}"
CREATE_LOG="${HERDR_CREATE_LOG:-$STATE_DIR/create.log}"
RUN_LOG="${HERDR_RUN_LOG:-$STATE_DIR/run.log}"
CLOSE_LOG="${HERDR_CLOSE_LOG:-$STATE_DIR/close.log}"
GET_LOG="${HERDR_GET_LOG:-$STATE_DIR/get.log}"
mkdir -p "$STATE_DIR"

log_args() {
  target="$1"
  operation="$2"
  shift 2
  {
    printf '%s\n' "$operation"
    for arg in "$@"; do printf '%s\n' "$arg"; done
    printf '%s\n' '--END--'
  } >> "$target"
}

write_run() {
  run_cwd="$1"
  run_command="$2"
  if [ -n "${HERDR_RUN_ISSUE:-}" ]; then
    run_issue="$HERDR_RUN_ISSUE"
  else
    run_issue="$(printf '%s\n' "$run_command" | sed -n 's/.*ISSUE-\([0-9][0-9]*\)-launch.*/\1/p')"
    [ -n "$run_issue" ] || run_issue="$(printf '%s\n' "$run_command" | sed -n 's/.*--issue \([0-9][0-9]*\).*/\1/p')"
  fi
  [ -n "$run_issue" ] || run_issue="0"
  run_started="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  node - "$run_cwd" "$run_issue" "$run_started" <<'NODE'
const fs = require("fs");
const path = require("path");
const [cwd, issue, started] = process.argv.slice(2);
fs.mkdirSync(path.join(cwd, ".review"), { recursive: true });
fs.writeFileSync(path.join(cwd, ".review", `ISSUE-${issue}-RUN.json`), JSON.stringify({
  schema_version: "1", artifact_type: "codex_run", issue: Number(issue), attempt: 1,
  started_at: started, updated_at: started, status: "running"
}) + "\n");
NODE
}

workspace_help() {
  case "${HERDR_HELP_MODE:-complete}" in
    workspace_fail) printf '%s\n' 'workspace help unavailable'; return 2 ;;
    missing_get) printf '%s\n' 'Commands: create close'; return 0 ;;
    missing_close) printf '%s\n' 'Commands: create get'; return 0 ;;
    *) printf '%s\n' 'Commands: create get close'; return 0 ;;
  esac
}

workspace_create_help() {
  case "${HERDR_HELP_MODE:-complete}" in
    missing_cwd) printf '%s\n' 'workspace create --label LABEL --no-focus'; return 0 ;;
    missing_label) printf '%s\n' 'workspace create --cwd PATH --no-focus'; return 0 ;;
    missing_focus) printf '%s\n' 'workspace create --cwd PATH --label LABEL'; return 0 ;;
    *) printf '%s\n' 'workspace create --cwd PATH --label LABEL --no-focus'; return 0 ;;
  esac
}

pane_help() {
  case "${HERDR_HELP_MODE:-complete}" in
    pane_fail) printf '%s\n' 'pane help unavailable'; return 2 ;;
    missing_pane_run) printf '%s\n' 'Commands: send'; return 0 ;;
    *) printf '%s\n' 'Commands: run'; return 0 ;;
  esac
}

pane_run_help() {
  case "${HERDR_HELP_MODE:-complete}" in
    missing_pane_run) printf '%s\n' 'pane send PANE COMMAND'; return 0 ;;
    *) printf '%s\n' 'Usage: herdr pane run PANE COMMAND'; return 0 ;
  esac
}

if [ "${1:-}" = "--version" ]; then
  case "${HERDR_VERSION_MODE:-default}" in
    empty) exit 0 ;;
    garbage) printf '%s\n' 'herdr version unknown'; exit 0 ;;
    *) printf '%s\n' "${HERDR_VERSION:-0.8.0}"; exit 0 ;;
  esac
fi

if [ "${1:-}" = "workspace" ] && [ "${2:-}" = "--help" ]; then
  workspace_help
  exit $?
fi
if [ "${1:-}" = "workspace" ] && [ "${2:-}" = "create" ] && [ "${3:-}" = "--help" ]; then
  workspace_create_help
  exit $?
fi
if [ "${1:-}" = "workspace" ] && [ "${2:-}" = "get" ] && [ "${3:-}" = "--help" ]; then
  printf '%s\n' 'Usage: herdr workspace get ID'
  exit 0
fi
if [ "${1:-}" = "workspace" ] && [ "${2:-}" = "close" ] && [ "${3:-}" = "--help" ]; then
  printf '%s\n' 'Usage: herdr workspace close ID'
  exit 0
fi
if [ "${1:-}" = "pane" ] && [ "${2:-}" = "--help" ]; then
  pane_help
  exit $?
fi
if [ "${1:-}" = "pane" ] && [ "${2:-}" = "run" ] && [ "${3:-}" = "--help" ]; then
  pane_run_help
  exit $?
fi

if [ "${1:-}" = "workspace" ] && [ "${2:-}" = "list" ]; then
  case "${HERDR_LIST_MODE:-valid}" in
    valid) printf '%s\n' '{"result":{"type":"workspace_list","workspaces":[{"workspace_id":"decoy-workspace","label":"requested-label"}]}}'; exit 0 ;;
    malformed) printf '%s\n' '{"result":'; exit 0 ;;
    wrong_shape) printf '%s\n' '{"result":{"type":"workspace_list","workspaces":{}}}'; exit 0 ;;
    fail) printf '%s\n' 'workspace list failed' >&2; exit 7 ;;
    *) printf '%s\n' ''; exit 0 ;;
  esac
fi

if [ "${1:-}" = "workspace" ] && [ "${2:-}" = "create" ]; then
  log_args "$CREATE_LOG" create "$@"
  cwd=""; label=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --cwd) cwd="$2"; shift 2 ;;
      --label) label="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  case "${HERDR_CREATE_MODE:-success}" in
    fail) printf '%s\n' 'workspace create failed' >&2; exit "${HERDR_CREATE_STATUS:-7}" ;;
    timeout) exit 124 ;;
    malformed) printf '%s\n' 'not json'; exit 0 ;;
  esac
  workspace_id="${HERDR_WORKSPACE_ID:-workspace-created}"
  pane_id="${HERDR_PANE_ID:-pane-created}"
  request_id="${HERDR_REQUEST_ID:-request-created}"
  root_workspace_id="${HERDR_ROOT_WORKSPACE_ID:-$workspace_id}"
  root_cwd="${HERDR_ROOT_PANE_CWD:-$cwd}"
  case "${HERDR_CREATE_MODE:-success}" in
    wrong_type) result_type="workspace_info" ;;
    missing_workspace_id) workspace_id=""; result_type="workspace_created" ;;
    missing_pane_id) pane_id=""; result_type="workspace_created" ;;
    cross_wired) root_workspace_id="other-workspace"; result_type="workspace_created" ;;
    wrong_cwd) root_cwd="${HERDR_WRONG_CWD:-$cwd/nonexistent}"; result_type="workspace_created" ;;
    *) result_type="workspace_created" ;;
  esac
  if [ "${HERDR_SEED_DECOY:-0}" -eq 1 ]; then
    printf '%s\n' 'requested-label' > "$STATE_DIR/decoy-workspace.label"
  fi
  if [ -n "$workspace_id" ] && [ -n "$pane_id" ]; then
    printf '%s\n' "$workspace_id" > "$STATE_DIR/pane-$pane_id.workspace"
    printf '%s\n' "$root_cwd" > "$STATE_DIR/pane-$pane_id.cwd"
  fi
  node - "$result_type" "$workspace_id" "$label" "$root_workspace_id" "$pane_id" "$root_cwd" "$request_id" <<'NODE'
const [type, workspaceId, label, rootWorkspaceId, paneId, cwd, requestId] = process.argv.slice(2);
process.stdout.write(JSON.stringify({ id: requestId, result: {
  type,
  workspace: { workspace_id: workspaceId, label },
  root_pane: { pane_id: paneId, workspace_id: rootWorkspaceId, cwd }
} }) + "\n");
NODE
  exit 0
fi

if [ "${1:-}" = "pane" ] && [ "${2:-}" = "run" ]; then
  pane_id="${3:-}"
  run_command="${4:-}"
  log_args "$RUN_LOG" run "$@"
  pane_cwd_file="$STATE_DIR/pane-$pane_id.cwd"
  if [ ! -r "$pane_cwd_file" ]; then
    printf '%s\n' '{"error":{"code":"pane_not_found","message":"pane was not found"}}' >&2
    exit 1
  fi
  pane_cwd="$(sed -n '1p' "$pane_cwd_file")"
  run_mode="${HERDR_RUN_MODE:-success}"
  case "$run_mode" in
    success)
      write_run "$pane_cwd" "$run_command"
      exit 0
      ;;
    pane_not_found|invalid_key|pane_send_failed)
      printf '%s\n' "{\"error\":{\"code\":\"$run_mode\",\"message\":\"run rejected\"}}" >&2
      exit "${HERDR_RUN_STATUS:-1}"
      ;;
    ambiguous_empty|ambiguous_multiple|ambiguous_malformed|ambiguous_other)
      if [ "${HERDR_WRITE_RUN_ON_AMBIGUOUS:-0}" -eq 1 ]; then write_run "$pane_cwd" "$run_command"; fi
      case "$run_mode" in
        ambiguous_multiple) printf '%s\n%s\n' '{"error":{"code":"server_error","message":"first"}}' '{"error":{"code":"server_error","message":"second"}}' >&2 ;;
        ambiguous_malformed) printf '%s\n' 'not json' >&2 ;;
        ambiguous_other) printf '%s\n' '{"error":{"code":"server_error","message":"unknown"}}' >&2 ;;
        *) : ;;
      esac
      exit "${HERDR_RUN_STATUS:-7}"
      ;;
    *) printf '%s\n' 'unrecognized run mode' >&2; exit 9 ;;
  esac
fi

if [ "${1:-}" = "workspace" ] && [ "${2:-}" = "close" ]; then
  workspace_id="${3:-}"
  log_args "$CLOSE_LOG" close "$@"
  if [ -n "${HERDR_CLOSE_STDOUT:-}" ]; then printf '%s\n' "$HERDR_CLOSE_STDOUT"; fi
  if [ "${HERDR_CLOSE_MODE:-success}" = "fail" ]; then exit "${HERDR_CLOSE_STATUS:-9}"; fi
  exit 0
fi

if [ "${1:-}" = "workspace" ] && [ "${2:-}" = "get" ]; then
  handle="${3:-}"
  log_args "$GET_LOG" get "$@"
  case "${HERDR_GET_MODE:-live}" in
    live) get_workspace_id="${HERDR_GET_WORKSPACE_ID:-$handle}"; node - "$get_workspace_id" <<'NODE'
const id = process.argv[2];
process.stdout.write(JSON.stringify({ result: { type: "workspace_info", workspace: { workspace_id: id, label: "requested-label" } } }) + "\n");
NODE
      exit 0 ;;
    live_other) node - "other-workspace" <<'NODE'
const id = process.argv[2];
process.stdout.write(JSON.stringify({ result: { type: "workspace_info", workspace: { workspace_id: id, label: "requested-label" } } }) + "\n");
NODE
      exit 0 ;;
    stale) printf '%s\n' '{"error":{"code":"workspace_not_found","message":"workspace was not found"}}' >&2; exit 1 ;;
    stale_nonzero) printf '%s\n' '{"error":{"code":"workspace_not_found","message":"workspace was not found"}}' >&2; exit 7 ;;
    malformed_success) printf '%s\n' '{"result":'; exit 0 ;;
    malformed_error) printf '%s\n' 'not json' >&2; exit 1 ;;
    multiple_error) printf '%s\n%s\n' '{"error":{"code":"workspace_not_found","message":"first"}}' '{"error":{"code":"workspace_not_found","message":"second"}}' >&2; exit 1 ;;
    other_error) printf '%s\n' '{"error":{"code":"server_error","message":"unknown"}}' >&2; exit 1 ;;
    empty_error) exit 1 ;;
    *) exit 9 ;;
  esac
fi

exit 9
EOF
chmod +x "$BIN/cmux" "$BIN/orca" "$BIN/herdr"
cat > "$BIN/codex" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo 'codex-cli 0.test'; exit 0; fi
if [ "${1:-}" = "--help" ]; then echo 'Commands: exec'; exit 0; fi
if [ "${1:-}" = "exec" ] && [ "${2:-}" = "--help" ]; then echo 'exec --sandbox --cd --model --config --output-last-message --json'; exit 0; fi
exit 0
EOF
chmod +x "$BIN/codex"
export AGENT_WORKFLOW_CODEX_BIN="$BIN/codex"
# The generic runtime pin outranks the per-runtime pin, so a value inherited
# from a dispatching session would bypass the fake codex binary above.
unset AGENT_WORKFLOW_RUNTIME_BIN

WT="$TMP_ROOT/choice"
make_worktree "$WT" 501
printf '%s\n' '{"orchestrator":"orca"}' > "$PRODUCT_HOME/workflow-config.json"
choice_out="$TMP_ROOT/choice.out"
AGENT_WORKFLOW_ORCHESTRATOR=orca bash "$CLI" dispatch --orchestrator cmux --issue 501 --worktree "$WT" --read-only --dry-run >"$choice_out" 2>&1
if grep -q 'orchestrator=cmux source=cli' "$choice_out"; then pass "CLI selection outranks environment and config"; else fail "CLI selection precedence"; fi
AGENT_WORKFLOW_ORCHESTRATOR=cmux bash "$CLI" dispatch --issue 501 --worktree "$WT" --read-only --dry-run >"$choice_out" 2>&1
if grep -q 'orchestrator=cmux source=environment' "$choice_out"; then pass "environment selection outranks config"; else fail "environment selection precedence"; fi
env -u AGENT_WORKFLOW_ORCHESTRATOR bash "$CLI" dispatch --issue 501 --worktree "$WT" --read-only --dry-run >"$choice_out" 2>&1
if grep -q 'orchestrator=orca source=config' "$choice_out"; then pass "product-home config supplies explicit selection"; else fail "config selection"; fi

AGENT_WORKFLOW_ORCHESTRATOR=orca bash "$CLI" dispatch --orchestrator herdr --issue 501 --worktree "$WT" --read-only --dry-run >"$choice_out" 2>&1
if grep -q 'orchestrator=herdr source=cli' "$choice_out" && grep -q '^herdr launch ' "$choice_out"; then
  pass "Herdr CLI selection outranks environment and config"
else fail "Herdr CLI selection"; fi
AGENT_WORKFLOW_ORCHESTRATOR=herdr bash "$CLI" dispatch --issue 501 --worktree "$WT" --read-only --dry-run >"$choice_out" 2>&1
if grep -q 'orchestrator=herdr source=environment' "$choice_out"; then
  pass "Herdr environment selection is explicit"
else fail "Herdr environment selection"; fi
printf '%s\n' '{"orchestrator":"herdr"}' > "$PRODUCT_HOME/workflow-config.json"
env -u AGENT_WORKFLOW_ORCHESTRATOR bash "$CLI" dispatch --issue 501 --worktree "$WT" --read-only --dry-run >"$choice_out" 2>&1
if grep -q 'orchestrator=herdr source=config' "$choice_out"; then
  pass "Herdr product-home config selection is explicit"
else fail "Herdr config selection"; fi

rm "$PRODUCT_HOME/workflow-config.json"
missing_out="$TMP_ROOT/missing.out"
env -u AGENT_WORKFLOW_ORCHESTRATOR bash "$CLI" dispatch --issue 501 --worktree "$WT" --read-only --dry-run >"$missing_out" 2>&1
ec=$?
if [ "$ec" -eq 2 ] && grep -q 'orchestrator_not_configured' "$missing_out"; then pass "missing selection fails closed with setup text"; else fail "missing selection refusal"; fi
unknown_out="$TMP_ROOT/unknown.out"
bash "$CLI" dispatch --orchestrator auto --issue 501 --worktree "$WT" --read-only --dry-run >"$unknown_out" 2>&1
ec=$?
if [ "$ec" -eq 2 ] && grep -q 'unknown_orchestrator' "$unknown_out"; then pass "unknown selection is rejected"; else fail "unknown selection refusal"; fi

# Herdr is inherited from the current session only. A selected adapter that
# lacks that context must refuse before admission, runners, receipts, or any
# other transport are touched.
HERDR_REFUSAL_WT="$TMP_ROOT/herdr-session-refusal-wt"
make_worktree "$HERDR_REFUSAL_WT" 509
HERDR_REFUSAL_OUT="$TMP_ROOT/herdr-session-refusal.out"
env -u HERDR_ENV -u HERDR_SOCKET_PATH TRANSPORT_USED="$TMP_ROOT/herdr-session-refusal-transport" \
PATH="$BIN:$PATH" bash "$CLI" dispatch --orchestrator herdr --issue 509 --worktree "$HERDR_REFUSAL_WT" --read-only --poll-timeout 1 >"$HERDR_REFUSAL_OUT" 2>&1
ec=$?
if [ "$ec" -eq 2 ] && grep -q 'session_context_missing' "$HERDR_REFUSAL_OUT" \
  && [ ! -e "$HERDR_REFUSAL_WT/.review/ISSUE-509-TRANSPORT.json" ] \
  && ! find "$HERDR_REFUSAL_WT/.review" -type d -name 'ISSUE-509-launch.*' | grep -q . \
  && [ ! -e "$TMP_ROOT/herdr-session-refusal-transport" ]; then
  pass "Herdr session context refusal precedes admission and never falls back"
else fail "Herdr session context refusal ($(cat "$HERDR_REFUSAL_OUT"))"; fi

HERDR_CAP_SCRIPT="$ROOT/scripts/adapters/herdr.sh"
herdr_capability_expectation() {
  case_name="$1"
  expected_reason="$2"
  shift 2
  output_file="$TMP_ROOT/herdr-capability-$case_name.json"
  HERDR_STATE_DIR="$TMP_ROOT/herdr-capability-$case_name-state" "$@" >"$output_file" 2>&1
  status=$?
  if [ "$status" -eq 0 ] && node - "$output_file" "$expected_reason" <<'NODE'
const fs = require("fs");
try {
  const value = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  if (value.available !== false || value.reason_code !== process.argv[3]) process.exit(1);
} catch (error) { process.exit(1); }
NODE
  then pass "Herdr capability $case_name returns $expected_reason with exit 0"
  else fail "Herdr capability $case_name ($(cat "$output_file"))"; fi
}

herdr_capability_expectation session-unset session_context_missing env -u HERDR_ENV -u HERDR_SOCKET_PATH \
  PATH="$BIN:$PATH" bash "$HERDR_CAP_SCRIPT" capabilities --worktree "$WT"
herdr_capability_expectation session-empty-socket session_context_missing \
  env HERDR_ENV=1 HERDR_SOCKET_PATH= PATH="$BIN:$PATH" bash "$HERDR_CAP_SCRIPT" capabilities --worktree "$WT"

herdr_capability_matrix() {
  case_name="$1"
  version_value="$2"
  expected_available="$3"
  output_file="$TMP_ROOT/herdr-version-$case_name.json"
  HERDR_ENV=1 HERDR_SOCKET_PATH=socket HERDR_VERSION_MODE=default HERDR_VERSION="$version_value" \
  HERDR_STATE_DIR="$TMP_ROOT/herdr-version-$case_name-state" PATH="$BIN:$PATH" bash "$HERDR_CAP_SCRIPT" capabilities --worktree "$WT" >"$output_file" 2>&1
  status=$?
  if [ "$status" -eq 0 ] && node - "$output_file" "$expected_available" <<'NODE'
const fs = require("fs");
try {
  const value = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  if (value.available !== (process.argv[3] === "true")) process.exit(1);
  if (!value.available && value.reason_code !== "required_capability_missing") process.exit(1);
} catch (error) { process.exit(1); }
NODE
  then pass "Herdr semver $case_name is classified correctly"
  else fail "Herdr semver $case_name ($(cat "$output_file"))"; fi
}
herdr_capability_matrix below-floor 0.7.9 false
herdr_capability_matrix floor 0.8.0 true
herdr_capability_matrix floor-prerelease 0.8.0-rc.1 false
herdr_capability_matrix prefixed-floor v0.8.0 true
herdr_capability_matrix double-digit-minor 0.10.0 true
herdr_capability_matrix later-prerelease 0.9.0-rc.1 true
herdr_capability_matrix garbage 'not-a-version' false
HERDR_ENV=1 HERDR_SOCKET_PATH=socket HERDR_VERSION=0.8.0 HERDR_STATE_DIR="$TMP_ROOT/herdr-version-digest-state" \
PATH="$BIN:$PATH" bash "$HERDR_CAP_SCRIPT" capabilities --worktree "$WT" >"$TMP_ROOT/herdr-version-digest.json" 2>&1
if node - "$TMP_ROOT/herdr-version-digest.json" <<'NODE'
const value = require(process.argv[2]);
if (!value.available || !/^0\.8\.0;binary-sha256:[a-f0-9]{64}$/.test(value.version)) process.exit(1);
NODE
then pass "Herdr capabilities record parsed semver and resolved binary digest"; else fail "Herdr capability provenance ($(cat "$TMP_ROOT/herdr-version-digest.json"))"; fi
HERDR_VERSION_MODE=empty HERDR_ENV=1 HERDR_SOCKET_PATH=socket HERDR_STATE_DIR="$TMP_ROOT/herdr-version-empty-state" \
PATH="$BIN:$PATH" bash "$HERDR_CAP_SCRIPT" capabilities --worktree "$WT" >"$TMP_ROOT/herdr-version-empty.json" 2>&1
ec=$?
if [ "$ec" -eq 0 ] && node - "$TMP_ROOT/herdr-version-empty.json" <<'NODE'
const value = require(process.argv[2]);
if (value.available || value.reason_code !== "required_capability_missing") process.exit(1);
NODE
then pass "Herdr empty semver is rejected as required_capability_missing"; else fail "Herdr empty semver ($(cat "$TMP_ROOT/herdr-version-empty.json"))"; fi

for help_mode in workspace_fail missing_cwd missing_label missing_focus missing_get missing_close pane_fail missing_pane_run; do
  HERDR_ENV=1 HERDR_SOCKET_PATH=socket HERDR_HELP_MODE="$help_mode" HERDR_STATE_DIR="$TMP_ROOT/herdr-help-$help_mode-state" \
  PATH="$BIN:$PATH" bash "$HERDR_CAP_SCRIPT" capabilities --worktree "$WT" >"$TMP_ROOT/herdr-help-$help_mode.json" 2>&1
  ec=$?
  if [ "$ec" -eq 0 ] && node - "$TMP_ROOT/herdr-help-$help_mode.json" <<'NODE'
const value = require(process.argv[2]);
if (value.available || value.reason_code !== "required_capability_missing") process.exit(1);
NODE
  then pass "Herdr $help_mode help surface is required"; else fail "Herdr $help_mode help surface ($(cat "$TMP_ROOT/herdr-help-$help_mode.json"))"; fi
done
for list_mode in malformed wrong_shape fail; do
  HERDR_ENV=1 HERDR_SOCKET_PATH=socket HERDR_LIST_MODE="$list_mode" HERDR_STATE_DIR="$TMP_ROOT/herdr-list-$list_mode-state" \
  PATH="$BIN:$PATH" bash "$HERDR_CAP_SCRIPT" capabilities --worktree "$WT" >"$TMP_ROOT/herdr-list-$list_mode.json" 2>&1
  ec=$?
  if [ "$ec" -eq 0 ] && node - "$TMP_ROOT/herdr-list-$list_mode.json" <<'NODE'
const value = require(process.argv[2]);
if (value.available || value.reason_code !== "required_capability_missing") process.exit(1);
NODE
  then pass "Herdr workspace list $list_mode is required"; else fail "Herdr workspace list $list_mode ($(cat "$TMP_ROOT/herdr-list-$list_mode.json"))"; fi
done

# The cmux capability probe must prove --cwd/--command support from the same
# help surface the launch command uses (`workspace create --help`): a direct
# flag listing, or an explicit same-line new-workspace delegation that the
# delegated `new-workspace --help` surface itself confirms by listing both
# flags. The legacy new-workspace help surface still answers in this fake, so
# the unrelated and mention_only cases also prove the cross-command proof no
# longer admits, and the flagless case proves a delegation claim alone is not
# accepted without the delegated surface's own flag listing.
CMUX_CAP_SCRIPT="$ROOT/scripts/adapters/cmux.sh"
cmux_capability_matrix() {
  case_name="$1"
  help_mode="$2"
  expected_available="$3"
  legacy_help_mode="${4:-flags}"
  output_file="$TMP_ROOT/cmux-capability-$help_mode-${legacy_help_mode}.json"
  CMUX_HELP_MODE="$help_mode" CMUX_NEW_WORKSPACE_HELP_MODE="$legacy_help_mode" \
    PATH="$BIN:$PATH" bash "$CMUX_CAP_SCRIPT" capabilities --worktree "$WT" >"$output_file" 2>&1
  status=$?
  if [ "$status" -eq 0 ] && node - "$output_file" "$expected_available" <<'NODE'
const fs = require("fs");
try {
  const value = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  if (value.adapter !== "cmux" || value.available !== (process.argv[3] === "true")) process.exit(1);
  if (!value.available && value.reason_code !== "required_capability_missing") process.exit(1);
  if (!value.available && (value.version !== "unknown" || value.capabilities.length)) process.exit(1);
} catch (error) { process.exit(1); }
NODE
  then pass "$case_name"
  else fail "$case_name ($(cat "$output_file"))"; fi
}
cmux_capability_matrix "AC-112-1 cmux workspace create --help directly listing --cwd/--command proves capability" direct true
cmux_capability_matrix "AC-112-2 cmux workspace create --help explicit new-workspace delegation wording proves capability" delegation true
cmux_capability_matrix "AC-112-3 cmux live 0.64.22 delegation help text still proves capability" live true
cmux_capability_matrix "AC-112-5 cmux delegation wording without new-workspace --help flags is rejected as required_capability_missing" delegation false flagless
cmux_capability_matrix "AC-112-4 cmux unrelated workspace create --help is rejected as required_capability_missing" unrelated false
cmux_capability_matrix "AC-112-4 cmux scattered new-workspace mention without same-line delegation is rejected" mention_only false
cmux_capability_matrix "AC-130-6 cmux workspace create --help listing real flags but not --cwd/--command is rejected as required_capability_missing" flagless false flagless

# An unavailable selected adapter must fail before the initial-write marker and
# must never call the other adapter.
BAD_BIN="$TMP_ROOT/bad-bin"
mkdir -p "$BAD_BIN"
cat > "$BAD_BIN/orca" <<'EOF'
#!/usr/bin/env bash
echo 'orca terminal create without required flags'
EOF
cat > "$BAD_BIN/cmux" <<'EOF'
#!/usr/bin/env bash
echo called > "$FALLBACK_LOG"
EOF
chmod +x "$BAD_BIN/orca" "$BAD_BIN/cmux"
unavailable_out="$TMP_ROOT/unavailable.out"
FALLBACK_LOG="$TMP_ROOT/fallback.log"
FALLBACK_LOG="$FALLBACK_LOG" PATH="$BAD_BIN:$PATH" bash "$CLI" dispatch --orchestrator orca --issue 501 --worktree "$WT" --tier trivial >"$unavailable_out" 2>&1
ec=$?
if [ "$ec" -eq 2 ] && grep -q 'required_capability_missing' "$unavailable_out" \
  && [ ! -e "$FALLBACK_LOG" ] && [ ! -d "$WT/.review/.write-dispatch-issue-501-started" ]; then
  pass "capability refusal precedes admission and never falls back"
else fail "pre-admission capability/no-fallback contract ($(cat "$unavailable_out"))"; fi

# A cmux binary that exists but exits 2 for side-effect-free version/help
# probes is unavailable before admission; no runner/marker may be consumed.
CMUX_BAD_WT="$TMP_ROOT/cmux-bad-wt"
make_worktree "$CMUX_BAD_WT" 504
CMUX_BAD_BIN="$TMP_ROOT/cmux-bad-bin"
mkdir -p "$CMUX_BAD_BIN"
cat > "$CMUX_BAD_BIN/cmux" <<'EOF'
#!/usr/bin/env bash
exit 2
EOF
chmod +x "$CMUX_BAD_BIN/cmux"
PATH="$CMUX_BAD_BIN:$PATH" bash "$CLI" dispatch --orchestrator cmux --issue 504 --worktree "$CMUX_BAD_WT" --tier trivial >"$TMP_ROOT/cmux-bad.out" 2>&1
ec=$?
if [ "$ec" -eq 2 ] && grep -q 'required_capability_missing' "$TMP_ROOT/cmux-bad.out" \
  && [ ! -d "$CMUX_BAD_WT/.review/.write-dispatch-issue-504-started" ] \
  && ! find "$CMUX_BAD_WT/.review" -type d -name 'ISSUE-504-launch.*' | grep -q .; then
  pass "cmux help/version capability refusal preserves admission"
else fail "cmux pre-admission help/version refusal (ec=$ec: $(cat "$TMP_ROOT/cmux-bad.out"))"; fi

# Orca launch uses --title, so missing-title help must fail before admission.
ORCA_BAD_WT="$TMP_ROOT/orca-bad-wt"
make_worktree "$ORCA_BAD_WT" 505
ORCA_BAD_BIN="$TMP_ROOT/orca-bad-bin"
mkdir -p "$ORCA_BAD_BIN"
cat > "$ORCA_BAD_BIN/orca" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "terminal" ] && [ "${2:-}" = "create" ] && [ "${3:-}" = "--help" ]; then
  echo 'terminal create --worktree PATH --command TEXT --json'
  exit 0
fi
if [ "${1:-}" = "terminal" ] && [ "${2:-}" = "list" ] && [ "${3:-}" = "--help" ]; then
  echo 'terminal list --worktree PATH --json'
  exit 0
fi
if [ "${1:-}" = "--version" ]; then echo 'orca 1.0'; exit 0; fi
exit 9
EOF
chmod +x "$ORCA_BAD_BIN/orca"
PATH="$ORCA_BAD_BIN:$PATH" bash "$CLI" dispatch --orchestrator orca --issue 505 --worktree "$ORCA_BAD_WT" --tier trivial >"$TMP_ROOT/orca-bad.out" 2>&1
ec=$?
if [ "$ec" -eq 2 ] && grep -q 'required_capability_missing' "$TMP_ROOT/orca-bad.out" \
  && [ ! -d "$ORCA_BAD_WT/.review/.write-dispatch-issue-505-started" ]; then
  pass "Orca missing-title capability is rejected before admission"
else fail "Orca title capability refusal (ec=$ec: $(cat "$TMP_ROOT/orca-bad.out"))"; fi

# Herdr's public adapter seam is deliberately exercised with a stateful fake:
# create records only the workspace, pane run owns the fresh RUN fixture, and
# every identity used by the assertions is distinct from the requested label.
HERDR_DIRECT_WT="$TMP_ROOT/herdr-direct-wt"
make_worktree "$HERDR_DIRECT_WT" 601
HERDR_DIRECT_STATE="$TMP_ROOT/herdr-direct-state"
HERDR_DIRECT_CREATE_LOG="$HERDR_DIRECT_STATE/create.log"
HERDR_DIRECT_RUN_LOG="$HERDR_DIRECT_STATE/run.log"
HERDR_DIRECT_CLOSE_LOG="$HERDR_DIRECT_STATE/close.log"
HERDR_DIRECT_SUCCESS_OUT="$TMP_ROOT/herdr-direct-success.json"
HERDR_DIRECT_SUCCESS_ERR="$TMP_ROOT/herdr-direct-success.err"
HERDR_ENV=1 HERDR_SOCKET_PATH=socket HERDR_STATE_DIR="$HERDR_DIRECT_STATE" \
HERDR_CREATE_LOG="$HERDR_DIRECT_CREATE_LOG" HERDR_RUN_LOG="$HERDR_DIRECT_RUN_LOG" HERDR_CLOSE_LOG="$HERDR_DIRECT_CLOSE_LOG" \
HERDR_WORKSPACE_ID=herdr-workspace-601 HERDR_PANE_ID=herdr-pane-601 HERDR_RUN_ISSUE=601 HERDR_SEED_DECOY=1 \
HERDR_REQUEST_ID=herdr-request-601 \
PATH="$BIN:$PATH" bash "$ROOT/scripts/adapters/herdr.sh" launch --name requested-label-601 --worktree "$HERDR_DIRECT_WT" \
  --runner-relative .review/ISSUE-601-launch.fixture/launch.sh >"$HERDR_DIRECT_SUCCESS_OUT" 2>"$HERDR_DIRECT_SUCCESS_ERR"
herdr_direct_success_ec=$?
node - "$HERDR_DIRECT_SUCCESS_OUT" <<'NODE'
const fs = require("fs");
const value = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (value.external_handle !== "herdr-workspace-601" || value.lifecycle !== "launched") process.exit(1);
NODE
herdr_direct_json_ec=$?
if [ "$herdr_direct_success_ec" -eq 0 ] && [ "$herdr_direct_json_ec" -eq 0 ] \
  && grep -Fx -- '--cwd' "$HERDR_DIRECT_CREATE_LOG" >/dev/null \
  && grep -Fx -- "$HERDR_DIRECT_WT" "$HERDR_DIRECT_CREATE_LOG" >/dev/null \
  && grep -Fx -- '--label' "$HERDR_DIRECT_CREATE_LOG" >/dev/null \
  && grep -Fx -- 'requested-label-601' "$HERDR_DIRECT_CREATE_LOG" >/dev/null \
  && grep -Fx -- '--no-focus' "$HERDR_DIRECT_CREATE_LOG" >/dev/null \
  && grep -Fx -- 'herdr-pane-601' "$HERDR_DIRECT_RUN_LOG" >/dev/null \
  && grep -Fx -- 'bash .review/ISSUE-601-launch.fixture/launch.sh' "$HERDR_DIRECT_RUN_LOG" >/dev/null \
  && [ -f "$HERDR_DIRECT_WT/.review/ISSUE-601-RUN.json" ] \
  && [ ! -e "$HERDR_DIRECT_CLOSE_LOG" ]; then
  pass "Herdr launch proves exact cwd, label, no-focus, root pane, and empty-stdout success"
else fail "Herdr successful launch seam (ec=$herdr_direct_success_ec out=$(cat "$HERDR_DIRECT_SUCCESS_OUT") err=$(cat "$HERDR_DIRECT_SUCCESS_ERR"))"; fi

HERDR_WRONG_CWD="$TMP_ROOT/herdr-wrong-cwd"
mkdir -p "$HERDR_WRONG_CWD"
for create_mode in fail timeout malformed wrong_type missing_workspace_id missing_pane_id cross_wired wrong_cwd; do
  create_state="$TMP_ROOT/herdr-create-$create_mode-state"
  create_out="$TMP_ROOT/herdr-create-$create_mode.out"
  create_err="$TMP_ROOT/herdr-create-$create_mode.err"
  create_workspace="herdr-workspace-$create_mode"
  HERDR_ENV=1 HERDR_SOCKET_PATH=socket HERDR_STATE_DIR="$create_state" \
  HERDR_CREATE_LOG="$create_state/create.log" HERDR_RUN_LOG="$create_state/run.log" HERDR_CLOSE_LOG="$create_state/close.log" \
  HERDR_CREATE_MODE="$create_mode" HERDR_WRONG_CWD="$HERDR_WRONG_CWD" HERDR_WORKSPACE_ID="$create_workspace" HERDR_PANE_ID="herdr-pane-$create_mode" \
  PATH="$BIN:$PATH" bash "$ROOT/scripts/adapters/herdr.sh" launch --name "requested-$create_mode" --worktree "$HERDR_DIRECT_WT" \
    --runner-relative .review/ISSUE-601-launch.fixture/launch.sh >"$create_out" 2>"$create_err"
  create_ec=$?
  expected_create_ec=2
  [ "$create_mode" = "fail" ] && expected_create_ec=7
  [ "$create_mode" = "timeout" ] && expected_create_ec=124
  if [ "$create_ec" -eq "$expected_create_ec" ] && [ ! -s "$create_out" ] \
    && [ ! -e "$create_state/run.log" ] && [ ! -e "$create_state/close.log" ]; then
    pass "Herdr $create_mode create rejection precedes pane run and cleanup"
  else fail "Herdr $create_mode create rejection (ec=$create_ec out=$(cat "$create_out") err=$(cat "$create_err"))"; fi
done

for run_mode in pane_not_found invalid_key pane_send_failed; do
  run_state="$TMP_ROOT/herdr-definite-$run_mode-state"
  run_out="$TMP_ROOT/herdr-definite-$run_mode.out"
  run_err="$TMP_ROOT/herdr-definite-$run_mode.err"
  run_workspace="herdr-workspace-$run_mode"
  HERDR_ENV=1 HERDR_SOCKET_PATH=socket HERDR_STATE_DIR="$run_state" \
  HERDR_CREATE_LOG="$run_state/create.log" HERDR_RUN_LOG="$run_state/run.log" HERDR_CLOSE_LOG="$run_state/close.log" \
  HERDR_WORKSPACE_ID="$run_workspace" HERDR_PANE_ID="herdr-pane-$run_mode" HERDR_REQUEST_ID="herdr-request-$run_mode" HERDR_RUN_MODE="$run_mode" HERDR_RUN_STATUS=1 HERDR_SEED_DECOY=1 \
  PATH="$BIN:$PATH" bash "$ROOT/scripts/adapters/herdr.sh" launch --name "requested-$run_mode" --worktree "$HERDR_DIRECT_WT" \
    --runner-relative .review/ISSUE-601-launch.fixture/launch.sh >"$run_out" 2>"$run_err"
  run_ec=$?
  close_count="$(grep -Fx -- "$run_workspace" "$run_state/close.log" 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$run_ec" -eq 1 ] && [ ! -s "$run_out" ] && [ "$close_count" = "1" ] \
    && ! grep -Fx -- 'decoy-workspace' "$run_state/close.log" >/dev/null 2>&1; then
    pass "Herdr definite $run_mode rejection closes only its created workspace"
  else fail "Herdr definite $run_mode rejection (ec=$run_ec out=$(cat "$run_out") err=$(cat "$run_err"))"; fi
done

HERDR_CLOSE_NOISY_STATE="$TMP_ROOT/herdr-close-noisy-state"
HERDR_CLOSE_NOISY_OUT="$TMP_ROOT/herdr-close-noisy.out"
HERDR_CLOSE_NOISY_ERR="$TMP_ROOT/herdr-close-noisy.err"
HERDR_ENV=1 HERDR_SOCKET_PATH=socket HERDR_STATE_DIR="$HERDR_CLOSE_NOISY_STATE" \
HERDR_CREATE_LOG="$HERDR_CLOSE_NOISY_STATE/create.log" HERDR_RUN_LOG="$HERDR_CLOSE_NOISY_STATE/run.log" HERDR_CLOSE_LOG="$HERDR_CLOSE_NOISY_STATE/close.log" \
HERDR_WORKSPACE_ID=herdr-workspace-close-noisy HERDR_PANE_ID=herdr-pane-close-noisy HERDR_REQUEST_ID=herdr-request-close-noisy HERDR_RUN_MODE=pane_not_found HERDR_RUN_STATUS=1 HERDR_SEED_DECOY=1 \
HERDR_CLOSE_MODE=fail HERDR_CLOSE_STATUS=9 HERDR_CLOSE_STDOUT=noisy-close-output \
PATH="$BIN:$PATH" bash "$ROOT/scripts/adapters/herdr.sh" launch --name requested-close-noisy --worktree "$HERDR_DIRECT_WT" \
  --runner-relative .review/ISSUE-601-launch.fixture/launch.sh >"$HERDR_CLOSE_NOISY_OUT" 2>"$HERDR_CLOSE_NOISY_ERR"
close_noisy_ec=$?
if [ "$close_noisy_ec" -eq 1 ] && [ ! -s "$HERDR_CLOSE_NOISY_OUT" ] \
  && ! grep -q 'noisy-close-output' "$HERDR_CLOSE_NOISY_OUT" "$HERDR_CLOSE_NOISY_ERR"; then
  pass "Herdr cleanup output cannot replace the original pane rejection"
else fail "Herdr cleanup status/output preservation (ec=$close_noisy_ec out=$(cat "$HERDR_CLOSE_NOISY_OUT") err=$(cat "$HERDR_CLOSE_NOISY_ERR"))"; fi

for run_mode in ambiguous_empty ambiguous_multiple ambiguous_malformed ambiguous_other; do
  ambiguous_state="$TMP_ROOT/herdr-ambiguous-$run_mode-state"
  ambiguous_out="$TMP_ROOT/herdr-ambiguous-$run_mode.out"
  ambiguous_err="$TMP_ROOT/herdr-ambiguous-$run_mode.err"
  ambiguous_workspace="herdr-workspace-$run_mode"
  HERDR_ENV=1 HERDR_SOCKET_PATH=socket HERDR_STATE_DIR="$ambiguous_state" \
  HERDR_CREATE_LOG="$ambiguous_state/create.log" HERDR_RUN_LOG="$ambiguous_state/run.log" HERDR_CLOSE_LOG="$ambiguous_state/close.log" \
  HERDR_WORKSPACE_ID="$ambiguous_workspace" HERDR_PANE_ID="herdr-pane-$run_mode" HERDR_RUN_MODE="$run_mode" HERDR_RUN_STATUS=7 \
  PATH="$BIN:$PATH" bash "$ROOT/scripts/adapters/herdr.sh" launch --name "requested-$run_mode" --worktree "$HERDR_DIRECT_WT" \
    --runner-relative .review/ISSUE-601-launch.fixture/launch.sh >"$ambiguous_out" 2>"$ambiguous_err"
  ambiguous_ec=$?
  if [ "$ambiguous_ec" -eq 7 ] && node - "$ambiguous_out" "$ambiguous_workspace" <<'NODE'
const fs = require("fs");
const value = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (value.external_handle !== process.argv[3] || value.lifecycle !== "command_unconfirmed") process.exit(1);
NODE
  then
    if [ ! -e "$ambiguous_state/close.log" ] \
      && { [ "$run_mode" != ambiguous_other ] || grep -F -q '"server_error"' "$ambiguous_err"; }; then
      pass "Herdr $run_mode preserves handle/status without cleanup"
    else fail "Herdr $run_mode performed ambiguous cleanup or lost stderr"; fi
  else fail "Herdr $run_mode ambiguity (ec=$ambiguous_ec out=$(cat "$ambiguous_out") err=$(cat "$ambiguous_err"))"; fi
done

herdr_inspect_case() {
  inspect_mode="$1"
  expected_lifecycle="$2"
  expected_reason="$3"
  inspect_out_file="$TMP_ROOT/herdr-inspect-$inspect_mode.json"
  HERDR_ENV=1 HERDR_SOCKET_PATH=socket HERDR_STATE_DIR="$HERDR_DIRECT_STATE" HERDR_GET_MODE="$inspect_mode" \
  PATH="$BIN:$PATH" bash "$ROOT/scripts/adapters/herdr.sh" inspect --worktree "$HERDR_DIRECT_WT" --external-handle herdr-workspace-601 >"$inspect_out_file" 2>&1
  inspect_ec=$?
  if [ "$inspect_ec" -eq 0 ] && node - "$inspect_out_file" "$expected_lifecycle" "$expected_reason" <<'NODE'
const fs = require("fs");
const value = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (value.lifecycle !== process.argv[3] || value.reason !== process.argv[4]) process.exit(1);
NODE
  then pass "Herdr inspect $inspect_mode normalizes to $expected_lifecycle"; else fail "Herdr inspect $inspect_mode (ec=$inspect_ec out=$(cat "$inspect_out_file"))"; fi
}
herdr_inspect_case live live 'exact workspace handle is present'
herdr_inspect_case live_other handle_unverifiable 'workspace handle identity is mismatched'
herdr_inspect_case stale stale 'workspace handle is not found'
herdr_inspect_case malformed_success handle_unverifiable 'workspace response is malformed'
for inspect_mode in malformed_success malformed_error multiple_error other_error empty_error stale_nonzero; do
  [ "$inspect_mode" = "malformed_success" ] && continue
  herdr_inspect_case "$inspect_mode" handle_unverifiable 'workspace handle cannot be verified'
done

for run_mode in pane_not_found invalid_key pane_send_failed; do
  unconfirmed_state="$TMP_ROOT/herdr-unconfirmed-$run_mode-state"
  unconfirmed_out="$TMP_ROOT/herdr-unconfirmed-$run_mode.out"
  unconfirmed_err="$TMP_ROOT/herdr-unconfirmed-$run_mode.err"
  unconfirmed_workspace="herdr-workspace-unconfirmed-$run_mode"
  HERDR_ENV=1 HERDR_SOCKET_PATH=socket HERDR_STATE_DIR="$unconfirmed_state" \
  HERDR_CREATE_LOG="$unconfirmed_state/create.log" HERDR_RUN_LOG="$unconfirmed_state/run.log" HERDR_CLOSE_LOG="$unconfirmed_state/close.log" \
  HERDR_WORKSPACE_ID="$unconfirmed_workspace" HERDR_PANE_ID="herdr-pane-unconfirmed-$run_mode" HERDR_REQUEST_ID="herdr-request-unconfirmed-$run_mode" HERDR_RUN_MODE="$run_mode" HERDR_RUN_STATUS=7 \
  PATH="$BIN:$PATH" bash "$ROOT/scripts/adapters/herdr.sh" launch --name "requested-unconfirmed-$run_mode" --worktree "$HERDR_DIRECT_WT" \
    --runner-relative .review/ISSUE-601-launch.fixture/launch.sh >"$unconfirmed_out" 2>"$unconfirmed_err"
  unconfirmed_ec=$?
  if [ "$unconfirmed_ec" -eq 7 ] && node - "$unconfirmed_out" "$unconfirmed_workspace" <<'NODE'
const fs = require("fs");
const value = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (value.external_handle !== process.argv[3] || value.lifecycle !== "command_unconfirmed") process.exit(1);
NODE
  then
    if [ ! -e "$unconfirmed_state/close.log" ]; then pass "Herdr non-1 $run_mode preserves handle/status without cleanup"; else fail "Herdr non-1 $run_mode performed cleanup"; fi
  else fail "Herdr non-1 $run_mode ambiguity (ec=$unconfirmed_ec out=$(cat "$unconfirmed_out") err=$(cat "$unconfirmed_err"))"; fi
done

HERDR_INSPECT_SESSION_OUT="$TMP_ROOT/herdr-inspect-session-missing.json"
env -u HERDR_ENV -u HERDR_SOCKET_PATH HERDR_STATE_DIR="$HERDR_DIRECT_STATE" PATH="$BIN:$PATH" \
bash "$ROOT/scripts/adapters/herdr.sh" inspect --worktree "$HERDR_DIRECT_WT" --external-handle herdr-workspace-601 >"$HERDR_INSPECT_SESSION_OUT" 2>&1
herdr_inspect_session_ec=$?
if [ "$herdr_inspect_session_ec" -eq 0 ] && node - "$HERDR_INSPECT_SESSION_OUT" <<'NODE'
const value = require(process.argv[2]);
if (value.lifecycle !== "handle_unverifiable" || value.reason !== "session_context_missing") process.exit(1);
NODE
then pass "Herdr inspect reports missing session context as typed JSON"; else fail "Herdr inspect session context ($(cat "$HERDR_INSPECT_SESSION_OUT"))"; fi

HERDR_DISPATCH_WT="$TMP_ROOT/herdr-dispatch-wt"
make_worktree "$HERDR_DISPATCH_WT" 602
HERDR_DISPATCH_STATE="$TMP_ROOT/herdr-dispatch-state"
HERDR_DISPATCH_OUT="$TMP_ROOT/herdr-dispatch.out"
HERDR_ENV=1 HERDR_SOCKET_PATH=socket HERDR_STATE_DIR="$HERDR_DISPATCH_STATE" \
HERDR_CREATE_LOG="$HERDR_DISPATCH_STATE/create.log" HERDR_RUN_LOG="$HERDR_DISPATCH_STATE/run.log" HERDR_CLOSE_LOG="$HERDR_DISPATCH_STATE/close.log" \
HERDR_WORKSPACE_ID=herdr-workspace-602 HERDR_PANE_ID=herdr-pane-602 HERDR_RUN_MODE=success HERDR_SEED_DECOY=1 \
AGENT_WORKFLOW_CODEX_BIN="$BIN/codex" PATH="$BIN:$PATH" AGENT_WORKFLOW_POLL_INTERVAL=1 \
bash "$CLI" dispatch --orchestrator herdr --issue 602 --worktree "$HERDR_DISPATCH_WT" --name requested-label-602 --read-only --poll-timeout 3 >"$HERDR_DISPATCH_OUT" 2>&1
herdr_dispatch_ec=$?
HERDR_DISPATCH_RECEIPT="$HERDR_DISPATCH_WT/.review/ISSUE-602-TRANSPORT.json"
if [ "$herdr_dispatch_ec" -eq 0 ] && [ -f "$HERDR_DISPATCH_RECEIPT" ] \
  && grep -Fx -- '--cwd' "$HERDR_DISPATCH_STATE/create.log" >/dev/null \
  && grep -Fx -- "$HERDR_DISPATCH_WT" "$HERDR_DISPATCH_STATE/create.log" >/dev/null \
  && grep -Fx -- '--label' "$HERDR_DISPATCH_STATE/create.log" >/dev/null \
  && grep -Fx -- 'requested-label-602' "$HERDR_DISPATCH_STATE/create.log" >/dev/null \
  && grep -Fx -- '--no-focus' "$HERDR_DISPATCH_STATE/create.log" >/dev/null \
  && grep -Fx -- 'herdr-pane-602' "$HERDR_DISPATCH_STATE/run.log" >/dev/null \
  && grep -E '^bash \.review/ISSUE-602-launch\..*/launch\.sh$' "$HERDR_DISPATCH_STATE/run.log" >/dev/null \
  && node - "$HERDR_DISPATCH_RECEIPT" <<'NODE'
const value = require(process.argv[2]);
if (value.adapter !== "herdr" || value.external_handle !== "herdr-workspace-602") process.exit(1);
NODE
then pass "Herdr public dispatch publishes the returned workspace receipt"; else fail "Herdr public dispatch (ec=$herdr_dispatch_ec out=$(cat "$HERDR_DISPATCH_OUT"))"; fi

# The live inspection of this receipt is proven for every registry adapter by
# the shared AC-116-1 loop below; only Herdr-specific error mappings remain.
HERDR_INSPECT_OUT="$TMP_ROOT/herdr-inspect.out"
HERDR_ENV=1 HERDR_SOCKET_PATH=socket HERDR_STATE_DIR="$HERDR_DISPATCH_STATE" HERDR_GET_MODE=stale \
PATH="$BIN:$PATH" bash "$CLI" inspect --receipt "$HERDR_DISPATCH_RECEIPT" >"$HERDR_INSPECT_OUT" 2>&1
if grep -q '"lifecycle":"stale"' "$HERDR_INSPECT_OUT" && grep -q 'workspace handle is not found' "$HERDR_INSPECT_OUT"; then
  pass "Herdr CLI inspect classifies exact workspace_not_found as stale"
else fail "Herdr CLI stale inspect ($(cat "$HERDR_INSPECT_OUT"))"; fi
HERDR_ENV=1 HERDR_SOCKET_PATH=socket HERDR_STATE_DIR="$HERDR_DISPATCH_STATE" HERDR_GET_MODE=live_other \
PATH="$BIN:$PATH" bash "$CLI" inspect --receipt "$HERDR_DISPATCH_RECEIPT" >"$HERDR_INSPECT_OUT" 2>&1
if grep -q '"lifecycle":"handle_unverifiable"' "$HERDR_INSPECT_OUT" && grep -q 'workspace handle identity is mismatched' "$HERDR_INSPECT_OUT"; then
  pass "Herdr CLI inspect rejects a mismatched workspace identity"
else fail "Herdr CLI mismatched inspect ($(cat "$HERDR_INSPECT_OUT"))"; fi

node - "$VALIDATOR" "$SCHEMA" "$HERDR_DISPATCH_RECEIPT" <<'NODE'
const { validate } = require(process.argv[2]);
const fs = require("fs");
const schema = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
const value = JSON.parse(fs.readFileSync(process.argv[4], "utf8"));
if (validate(schema, value).length) process.exit(1);
NODE
if [ "$?" -eq 0 ]; then pass "Herdr public receipt remains schema-valid"; else fail "Herdr public receipt schema"; fi

HERDR_AMBIGUOUS_WT="$TMP_ROOT/herdr-ambiguous-dispatch-wt"
make_worktree "$HERDR_AMBIGUOUS_WT" 603
HERDR_AMBIGUOUS_STATE="$TMP_ROOT/herdr-ambiguous-dispatch-state"
HERDR_AMBIGUOUS_OUT="$TMP_ROOT/herdr-ambiguous-dispatch.out"
HERDR_ENV=1 HERDR_SOCKET_PATH=socket HERDR_STATE_DIR="$HERDR_AMBIGUOUS_STATE" \
HERDR_CREATE_LOG="$HERDR_AMBIGUOUS_STATE/create.log" HERDR_RUN_LOG="$HERDR_AMBIGUOUS_STATE/run.log" HERDR_CLOSE_LOG="$HERDR_AMBIGUOUS_STATE/close.log" \
HERDR_WORKSPACE_ID=herdr-workspace-603 HERDR_PANE_ID=herdr-pane-603 HERDR_RUN_MODE=ambiguous_malformed HERDR_RUN_STATUS=7 HERDR_WRITE_RUN_ON_AMBIGUOUS=1 \
AGENT_WORKFLOW_CODEX_BIN="$BIN/codex" PATH="$BIN:$PATH" AGENT_WORKFLOW_POLL_INTERVAL=1 \
bash "$CLI" dispatch --orchestrator herdr --issue 603 --worktree "$HERDR_AMBIGUOUS_WT" --read-only --poll-timeout 3 >"$HERDR_AMBIGUOUS_OUT" 2>&1
herdr_ambiguous_ec=$?
if [ "$herdr_ambiguous_ec" -eq 0 ] && [ -f "$HERDR_AMBIGUOUS_WT/.review/ISSUE-603-TRANSPORT.json" ] \
  && grep -q 'adapter launch returned 7' "$HERDR_AMBIGUOUS_OUT" \
  && [ ! -e "$HERDR_AMBIGUOUS_STATE/close.log" ]; then
  pass "Herdr ambiguous run preserves handle and lets fresh RUN evidence classify success"
else fail "Herdr ambiguous fresh-evidence dispatch (ec=$herdr_ambiguous_ec out=$(cat "$HERDR_AMBIGUOUS_OUT"))"; fi

HERDR_AMBIGUOUS_ABSENT_WT="$TMP_ROOT/herdr-ambiguous-absent-wt"
make_worktree "$HERDR_AMBIGUOUS_ABSENT_WT" 604
HERDR_AMBIGUOUS_ABSENT_STATE="$TMP_ROOT/herdr-ambiguous-absent-state"
HERDR_AMBIGUOUS_ABSENT_OUT="$TMP_ROOT/herdr-ambiguous-absent.out"
HERDR_ENV=1 HERDR_SOCKET_PATH=socket HERDR_STATE_DIR="$HERDR_AMBIGUOUS_ABSENT_STATE" \
HERDR_CREATE_LOG="$HERDR_AMBIGUOUS_ABSENT_STATE/create.log" HERDR_RUN_LOG="$HERDR_AMBIGUOUS_ABSENT_STATE/run.log" HERDR_CLOSE_LOG="$HERDR_AMBIGUOUS_ABSENT_STATE/close.log" \
HERDR_WORKSPACE_ID=herdr-workspace-604 HERDR_PANE_ID=herdr-pane-604 HERDR_RUN_MODE=ambiguous_empty HERDR_RUN_STATUS=7 \
AGENT_WORKFLOW_CODEX_BIN="$BIN/codex" PATH="$BIN:$PATH" AGENT_WORKFLOW_POLL_INTERVAL=1 \
bash "$CLI" dispatch --orchestrator herdr --issue 604 --worktree "$HERDR_AMBIGUOUS_ABSENT_WT" --read-only --poll-timeout 1 >"$HERDR_AMBIGUOUS_ABSENT_OUT" 2>&1
herdr_ambiguous_absent_ec=$?
if [ "$herdr_ambiguous_absent_ec" -eq 7 ] && [ -f "$HERDR_AMBIGUOUS_ABSENT_WT/.review/ISSUE-604-TRANSPORT.json" ] \
  && grep -q 'adapter launch returned 7' "$HERDR_AMBIGUOUS_ABSENT_OUT" \
  && [ ! -e "$HERDR_AMBIGUOUS_ABSENT_STATE/close.log" ]; then
  pass "Herdr ambiguous run preserves handle and original status without evidence"
else fail "Herdr ambiguous absent-evidence dispatch (ec=$herdr_ambiguous_absent_ec out=$(cat "$HERDR_AMBIGUOUS_ABSENT_OUT"))"; fi

HERDR_DEFINITE_WT="$TMP_ROOT/herdr-definite-dispatch-wt"
make_worktree "$HERDR_DEFINITE_WT" 605
HERDR_DEFINITE_STATE="$TMP_ROOT/herdr-definite-dispatch-state"
HERDR_DEFINITE_OUT="$TMP_ROOT/herdr-definite-dispatch.out"
HERDR_ENV=1 HERDR_SOCKET_PATH=socket HERDR_STATE_DIR="$HERDR_DEFINITE_STATE" \
HERDR_CREATE_LOG="$HERDR_DEFINITE_STATE/create.log" HERDR_RUN_LOG="$HERDR_DEFINITE_STATE/run.log" HERDR_CLOSE_LOG="$HERDR_DEFINITE_STATE/close.log" \
HERDR_WORKSPACE_ID=herdr-workspace-605 HERDR_PANE_ID=herdr-pane-605 HERDR_RUN_MODE=pane_not_found HERDR_RUN_STATUS=1 \
AGENT_WORKFLOW_CODEX_BIN="$BIN/codex" PATH="$BIN:$PATH" AGENT_WORKFLOW_POLL_INTERVAL=1 \
bash "$CLI" dispatch --orchestrator herdr --issue 605 --worktree "$HERDR_DEFINITE_WT" --read-only --poll-timeout 1 >"$HERDR_DEFINITE_OUT" 2>&1
herdr_definite_ec=$?
if [ "$herdr_definite_ec" -eq 1 ] && [ ! -e "$HERDR_DEFINITE_WT/.review/ISSUE-605-TRANSPORT.json" ] \
  && [ "$(grep -Fx -- herdr-workspace-605 "$HERDR_DEFINITE_STATE/close.log" | wc -l | tr -d ' ')" = "1" ] \
  && [ ! -e "$HERDR_DEFINITE_STATE/close.log.decoy" ]; then
  pass "Herdr definite public rejection publishes no receipt and closes its handle"
else fail "Herdr definite public rejection (ec=$herdr_definite_ec out=$(cat "$HERDR_DEFINITE_OUT"))"; fi

# Both adapters cross the same typed boundary and therefore inherit the same
# initial admission marker, runner identity, receipt, and freshness polling.
CMUX_WT="$TMP_ROOT/cmux-wt"
ORCA_WT="$TMP_ROOT/orca-wt"
make_worktree "$CMUX_WT" 502
make_worktree "$ORCA_WT" 503
TRANSPORT_USED="$TMP_ROOT/cmux-used" CMUX_ARGV="$TMP_ROOT/cmux-argv" ORCA_ARGV="$TMP_ROOT/unused-orca" \
AGENT_WORKFLOW_CODEX_BIN="$BIN/codex" PATH="$BIN:$PATH" AGENT_WORKFLOW_POLL_INTERVAL=1 bash "$CLI" dispatch --orchestrator cmux --issue 502 --worktree "$CMUX_WT" --tier trivial --poll-timeout 3 >"$TMP_ROOT/cmux.out" 2>&1
cmux_ec=$?
TRANSPORT_USED="$TMP_ROOT/orca-used" CMUX_ARGV="$TMP_ROOT/unused-cmux" ORCA_ARGV="$TMP_ROOT/orca-argv" \
AGENT_WORKFLOW_CODEX_BIN="$BIN/codex" PATH="$BIN:$PATH" AGENT_WORKFLOW_POLL_INTERVAL=1 bash "$CLI" dispatch --orchestrator orca --issue 503 --worktree "$ORCA_WT" --tier trivial --poll-timeout 3 >"$TMP_ROOT/orca.out" 2>&1
orca_ec=$?
if [ "$cmux_ec" -eq 0 ] && [ "$orca_ec" -eq 0 ] \
  && [ -d "$CMUX_WT/.review/.write-dispatch-issue-502-started" ] \
  && [ -d "$ORCA_WT/.review/.write-dispatch-issue-503-started" ] \
  && grep -Fx -- "$CMUX_WT" "$TMP_ROOT/cmux-argv" >/dev/null \
  && grep -Fx -- "path:$ORCA_WT" "$TMP_ROOT/orca-argv" >/dev/null \
  && grep -E '^bash \.review/ISSUE-502-launch\..*/launch\.sh$' "$TMP_ROOT/cmux-argv" >/dev/null \
  && grep -E '^bash \.review/ISSUE-503-launch\..*/launch\.sh$' "$TMP_ROOT/orca-argv" >/dev/null; then
  pass "cmux and Orca share exact cwd, runner, admission, and freshness behavior"
else fail "adapter parity (cmux=$cmux_ec orca=$orca_ec)"; fi

cmux_launch_argv="$(paste -s -d ' ' "$TMP_ROOT/cmux-argv")"
if printf '%s\n' "$cmux_launch_argv" | grep -Eq '^workspace create --name codex-502 --cwd [^ ]+ --command bash \.review/ISSUE-502-launch\.[^ ]+/launch\.sh$'; then
  pass "AC-112-5 cmux launch argv still uses workspace create --name/--cwd/--command"
else fail "AC-112-5 cmux launch argv unchanged ($cmux_launch_argv)"; fi

orca_version="$(node -e 'process.stdout.write(require(process.argv[1]).adapter_version)' "$ORCA_WT/.review/ISSUE-503-TRANSPORT.json")"
if [ "$orca_version" = "1.4.161" ] && [ "$orca_version" != "orca" ]; then
  pass "Orca receipt records runtime appVersion instead of executable-name output"
else fail "Orca receipt adapter version ($orca_version)"; fi

for bad_status_mode in missing non_string literal multiline usage invalid fail; do
  bad_capabilities="$(ORCA_STATUS_MODE="$bad_status_mode" PATH="$BIN:$PATH" bash "$ROOT/scripts/adapters/orca.sh" capabilities --worktree "$ORCA_WT")"
  if node -e 'const v=JSON.parse(process.argv[1]); if(!v.available || v.version!=="unknown")process.exit(1)' "$bad_capabilities"; then
    pass "Orca $bad_status_mode status version fails closed to unknown"
  else fail "Orca $bad_status_mode status version ($bad_capabilities)"; fi
done

cmux_runner="$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).runner.path)' "$CMUX_WT/.review/ISSUE-502-TRANSPORT.json")"
orca_runner="$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).runner.path)' "$ORCA_WT/.review/ISSUE-503-TRANSPORT.json")"
if grep -F -q "AGENT_WORKFLOW_RUNTIME_BIN=$RESOLVED_BIN/codex" "$cmux_runner" \
  && grep -F -q "AGENT_WORKFLOW_RUNTIME_BIN=$RESOLVED_BIN/codex" "$orca_runner"; then
  pass "both transports pin the validated runtime executable in the common runner"
else fail "common runner runtime executable pinning (cmux=$(sed -n '2p' "$cmux_runner"))"; fi

PIN_WT="$TMP_ROOT/pin-wt"
make_worktree "$PIN_WT" 506
AGENT_WORKFLOW_CODEX_BIN=relative/codex PATH="$BIN:$PATH" bash "$CLI" dispatch --orchestrator orca --issue 506 --worktree "$PIN_WT" --tier trivial >"$TMP_ROOT/pin.out" 2>&1
pin_ec=$?
if [ "$pin_ec" -eq 2 ] && grep -q 'required_runtime_capability_missing' "$TMP_ROOT/pin.out" \
  && [ ! -d "$PIN_WT/.review/.write-dispatch-issue-506-started" ]; then
  pass "invalid Codex executable pin fails before admission"
else fail "Codex executable pin pre-admission validation"; fi

for pair in "$CMUX_WT:502" "$ORCA_WT:503" "$HERDR_DISPATCH_WT:602"; do
  path="${pair%:*}"; issue="${pair#*:}"
  node - "$VALIDATOR" "$SCHEMA" "$path/.review/ISSUE-${issue}-TRANSPORT.json" <<'NODE'
const { validate } = require(process.argv[2]);
const fs = require("fs");
const schema = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
const value = JSON.parse(fs.readFileSync(process.argv[4], "utf8"));
if (validate(schema, value).length || value.authoritative !== false) process.exit(1);
NODE
  [ "$?" -eq 0 ] || fail "schema-valid non-authoritative receipt for issue $issue"
done
if [ "$FAILURES" -eq 0 ]; then pass "dispatch publishes schema-valid non-authoritative receipts"; fi

# AC-116-1: every registry adapter's dispatched receipt crosses the same CLI
# inspect boundary with the same evidence shape — its own adapter identity, a
# live probe of the handle dispatch returned, and the non-authoritative
# completion note. Only the receipt fixture and the inherited-session env
# needed to reach Herdr's probe differ.
inspect_out="$TMP_ROOT/inspect.out"
for adapter in $(node "$PRODUCT_HOME/scripts/lib/transport-registry.cjs" lines); do
  case "$adapter" in
    cmux) live_receipt="$CMUX_WT/.review/ISSUE-502-TRANSPORT.json" ;;
    orca) live_receipt="$ORCA_WT/.review/ISSUE-503-TRANSPORT.json" ;;
    herdr) live_receipt="$HERDR_DISPATCH_WT/.review/ISSUE-602-TRANSPORT.json" ;;
  esac
  if [ "$adapter" = herdr ]; then
    HERDR_ENV=1 HERDR_SOCKET_PATH=socket HERDR_STATE_DIR="$HERDR_DISPATCH_STATE" HERDR_GET_MODE=live \
      PATH="$BIN:$PATH" bash "$CLI" inspect --receipt "$live_receipt" > "$inspect_out" 2>&1
  else
    PATH="$BIN:$PATH" bash "$CLI" inspect --receipt "$live_receipt" > "$inspect_out" 2>&1
  fi
  if grep -q "\"adapter\":\"$adapter\"" "$inspect_out" && grep -q '"lifecycle":"live"' "$inspect_out" \
    && grep -q '"authoritative":false' "$inspect_out" && grep -q 'canonical REVIEW and VERIFY' "$inspect_out"; then
    pass "AC-116-1 $adapter receipt inspects live through the shared boundary without completion authority"
  else fail "AC-116-1 $adapter live inspect ($(cat "$inspect_out"))"; fi
done
cmux_handle="$(node -e 'process.stdout.write(require(process.argv[1]).external_handle)' "$CMUX_WT/.review/ISSUE-502-TRANSPORT.json")"
if [ "$cmux_handle" = "workspace:11" ]; then
  pass "cmux receipt normalizes the plain-text create workspace ref rather than the requested name"
else fail "cmux receipt unique create identity ($cmux_handle)"; fi

# A later receipt may retire only an earlier receipt-backed runner. An
# unmarked runner models another same-issue seat that has been created but has
# not yet published its own receipt, so cleanup must leave it runnable.
pending_runner_dir="$CMUX_WT/.review/ISSUE-502-launch.pending"
mkdir -p "$pending_runner_dir"
printf '%s\n' '#!/usr/bin/env bash' > "$pending_runner_dir/launch.sh"
chmod 700 "$pending_runner_dir/launch.sh"
old_cmux_runner="$cmux_runner"
# Simulate a publisher killed after receipt rename but before writing its
# marker. The next same-issue publication must recover that marker and retire
# the now-superseded receipt runner without touching the pending runner.
rm -f "${old_cmux_runner%/launch.sh}/.receipt-published"
TRANSPORT_USED="$TMP_ROOT/cmux-redispatch-used" CMUX_ARGV="$TMP_ROOT/cmux-redispatch-argv" ORCA_ARGV="$TMP_ROOT/unused-orca" \
AGENT_WORKFLOW_CODEX_BIN="$BIN/codex" PATH="$BIN:$PATH" AGENT_WORKFLOW_POLL_INTERVAL=1 bash "$CLI" dispatch --orchestrator cmux --issue 502 --worktree "$CMUX_WT" --read-only --poll-timeout 3 >"$TMP_ROOT/cmux-redispatch.out" 2>&1
cmux_redispatch_ec=$?
current_cmux_runner="$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).runner.path)' "$CMUX_WT/.review/ISSUE-502-TRANSPORT.json")"
if [ "$cmux_redispatch_ec" -eq 1 ] && [ "$current_cmux_runner" != "$old_cmux_runner" ] \
  && [ -x "$current_cmux_runner" ] && [ -f "${current_cmux_runner%/launch.sh}/.receipt-published" ] \
  && [ ! -e "$old_cmux_runner" ] && [ -x "$pending_runner_dir/launch.sh" ]; then
  pass "new receipt repairs then retires only the prior receipt runner"
else fail "receipt-bound runner retention and recovery (ec=$cmux_redispatch_ec old=$old_cmux_runner current=$current_cmux_runner)"; fi

CMUX_LIST_MODE=duplicate_name PATH="$BIN:$PATH" bash "$CLI" inspect --receipt "$CMUX_WT/.review/ISSUE-502-TRANSPORT.json" > "$inspect_out"
if grep -q '"lifecycle":"live"' "$inspect_out"; then
  pass "duplicate cmux workspace names do not replace exact id inspection"
else fail "cmux duplicate-name exact identity"; fi
CMUX_LIST_MODE=removed PATH="$BIN:$PATH" bash "$CLI" inspect --receipt "$CMUX_WT/.review/ISSUE-502-TRANSPORT.json" > "$inspect_out"
if grep -q '"lifecycle":"stale"' "$inspect_out"; then
  pass "removed created cmux workspace is stale even when its name remains"
else fail "cmux removed workspace stale identity"; fi
CMUX_LIST_MODE=decoy PATH="$BIN:$PATH" bash "$CLI" inspect --receipt "$CMUX_WT/.review/ISSUE-502-TRANSPORT.json" > "$inspect_out"
if grep -q '"lifecycle":"stale"' "$inspect_out"; then
  pass "AC-111-12 cmux inspect does not adopt a nested decoy id as the workspace handle"
else fail "AC-111-12 cmux inspect decoy id rejection ($(cat "$inspect_out"))"; fi

weird_name="$(printf 'same "name"\nnext')"
weird_launch="$(TRANSPORT_USED="$TMP_ROOT/weird-used" CMUX_ARGV="$TMP_ROOT/weird-argv" CMUX_CREATE_SHAPE=id CMUX_CREATE_ISSUE_OVERRIDE=502 PATH="$BIN:$PATH" bash "$ROOT/scripts/adapters/cmux.sh" launch --name "$weird_name" --worktree "$CMUX_WT" --runner-relative .review/ISSUE-502-launch.fixture/launch.sh)"
if node -e 'const v=JSON.parse(process.argv[1]); if(v.external_handle!=="cmux-502")process.exit(1)' "$weird_launch"; then
  pass "cmux launch JSON-encodes quote and newline names without using them as identity"
else fail "cmux unusual name JSON safety"; fi
ref_launch="$(TRANSPORT_USED="$TMP_ROOT/ref-used" CMUX_ARGV="$TMP_ROOT/ref-argv" CMUX_CREATE_SHAPE=ref CMUX_CREATE_ISSUE_OVERRIDE=502 PATH="$BIN:$PATH" bash "$ROOT/scripts/adapters/cmux.sh" launch --name codex-502 --worktree "$CMUX_WT" --runner-relative .review/ISSUE-502-launch.fixture/launch.sh)"
if node -e 'const v=JSON.parse(process.argv[1]); if(v.external_handle!=="cmux-502")process.exit(1)' "$ref_launch"; then
  pass "cmux create ref response normalizes to the same unique handle"
else fail "cmux ref response normalization"; fi

id_launch="$(TRANSPORT_USED="$TMP_ROOT/id-used" CMUX_ARGV="$TMP_ROOT/id-argv" CMUX_CREATE_SHAPE=id CMUX_CREATE_ISSUE_OVERRIDE=502 PATH="$BIN:$PATH" bash "$ROOT/scripts/adapters/cmux.sh" launch --name codex-502 --worktree "$CMUX_WT" --runner-relative .review/ISSUE-502-launch.fixture/launch.sh)"
if node -e 'const v=JSON.parse(process.argv[1]); if(v.external_handle!=="cmux-502")process.exit(1)' "$id_launch"; then
  pass "cmux create id response remains compatible"
else fail "cmux id response normalization"; fi

id_key_inspect="$(CMUX_LIST_MODE=id_key PATH="$BIN:$PATH" bash "$ROOT/scripts/adapters/cmux.sh" inspect --worktree "$CMUX_WT" --external-handle cmux-502)"
if node -e 'const v=JSON.parse(process.argv[1]); if(v.lifecycle!=="live")process.exit(1)' "$id_key_inspect"; then
  pass "AC-111-13 cmux id-shaped create handle inspects live when workspace list exposes the same id"
else fail "AC-111-13 cmux id-key list inspection ($(cat "$id_key_inspect" 2>/dev/null))"; fi

decoy_launch="$(TRANSPORT_USED="$TMP_ROOT/decoy-used" CMUX_ARGV="$TMP_ROOT/decoy-argv" CMUX_CREATE_SHAPE=decoy_id CMUX_CREATE_ISSUE_OVERRIDE=502 PATH="$BIN:$PATH" bash "$ROOT/scripts/adapters/cmux.sh" launch --name codex-502 --worktree "$CMUX_WT" --runner-relative .review/ISSUE-502-launch.fixture/launch.sh)"
if node -e 'const v=JSON.parse(process.argv[1]); if(v.external_handle!=="cmux-502")process.exit(1)' "$decoy_launch"; then
  pass "AC-111-12 cmux create adopts only the documented workspace result id, never a nested request id"
else fail "AC-111-12 cmux create decoy id rejection ($(cat "$TMP_ROOT/decoy-argv" 2>/dev/null))"; fi

for invalid_create_shape in name_only ambiguous missing invalid; do
  if TRANSPORT_USED="$TMP_ROOT/${invalid_create_shape}-used" CMUX_ARGV="$TMP_ROOT/${invalid_create_shape}-argv" CMUX_CREATE_SHAPE="$invalid_create_shape" CMUX_CREATE_ISSUE_OVERRIDE=502 PATH="$BIN:$PATH" \
    bash "$ROOT/scripts/adapters/cmux.sh" launch --name codex-502 --worktree "$CMUX_WT" --runner-relative .review/ISSUE-502-launch.fixture/launch.sh > "$TMP_ROOT/${invalid_create_shape}-create.out" 2>&1; then
    fail "cmux $invalid_create_shape create result must remain unprovable"
  else
    pass "cmux $invalid_create_shape create result remains unprovable"
  fi
done

CMUX_UNPROVABLE_WT="$TMP_ROOT/cmux-unprovable"
make_worktree "$CMUX_UNPROVABLE_WT" 507
CMUX_CREATE_SHAPE=name_only AGENT_WORKFLOW_CODEX_BIN="$BIN/codex" PATH="$BIN:$PATH" AGENT_WORKFLOW_POLL_INTERVAL=1 \
bash "$CLI" dispatch --orchestrator cmux --issue 507 --worktree "$CMUX_UNPROVABLE_WT" --tier trivial --poll-timeout 1 > "$TMP_ROOT/cmux-unprovable.out" 2>&1
unprovable_ec=$?
if [ "$unprovable_ec" -eq 2 ] && grep -q 'did not return one provable workspace id/ref' "$TMP_ROOT/cmux-unprovable.out" \
  && [ ! -e "$CMUX_UNPROVABLE_WT/.review/ISSUE-507-TRANSPORT.json" ]; then
  pass "cmux launch without a provable id/ref fails before receipt publication"
else fail "cmux unprovable create identity (ec=$unprovable_ec)"; fi
orca_handle="$(node -e 'process.stdout.write(require(process.argv[1]).external_handle)' "$ORCA_WT/.review/ISSUE-503-TRANSPORT.json")"
if [ "$orca_handle" = "term-503" ]; then
  pass "Orca receipt uses nested terminal handle rather than create request id"
else fail "Orca nested terminal handle normalization ($orca_handle)"; fi
for invalid_create_shape in missing ambiguous; do
  if TRANSPORT_USED="$TMP_ROOT/fixture-used" ORCA_ARGV="$TMP_ROOT/fixture-argv" ORCA_CREATE_MODE="$invalid_create_shape" PATH="$BIN:$PATH" \
    bash "$ROOT/scripts/adapters/orca.sh" launch --name codex-503 --worktree "$ORCA_WT" --runner-relative .review/ISSUE-503-launch.fixture/launch.sh > "$TMP_ROOT/orca-${invalid_create_shape}.out" 2>&1; then
    fail "Orca $invalid_create_shape create result must remain unprovable"
  else
    pass "Orca $invalid_create_shape create result remains unprovable"
  fi
done
ORCA_UNPROVABLE_WT="$TMP_ROOT/orca-unprovable"
make_worktree "$ORCA_UNPROVABLE_WT" 508
ORCA_CREATE_MODE=missing AGENT_WORKFLOW_CODEX_BIN="$BIN/codex" PATH="$BIN:$PATH" AGENT_WORKFLOW_POLL_INTERVAL=1 \
bash "$CLI" dispatch --orchestrator orca --issue 508 --worktree "$ORCA_UNPROVABLE_WT" --tier trivial --poll-timeout 1 > "$TMP_ROOT/orca-unprovable.out" 2>&1
orca_unprovable_ec=$?
if [ "$orca_unprovable_ec" -eq 2 ] && [ ! -e "$ORCA_UNPROVABLE_WT/.review/ISSUE-508-TRANSPORT.json" ]; then
  pass "Orca launch without a provable terminal handle fails before receipt publication"
else fail "Orca unprovable terminal handle (ec=$orca_unprovable_ec)"; fi
ORCA_LIST_MODE=missing PATH="$BIN:$PATH" bash "$CLI" inspect --receipt "$ORCA_WT/.review/ISSUE-503-TRANSPORT.json" > "$inspect_out"
if grep -q '"lifecycle":"stale"' "$inspect_out" && grep -q 'external terminal handle is absent' "$inspect_out"; then
  pass "inspect normalizes a missing external handle as stale"
else fail "missing external handle normalization"; fi
ORCA_LIST_MODE=unknown PATH="$BIN:$PATH" bash "$CLI" inspect --receipt "$ORCA_WT/.review/ISSUE-503-TRANSPORT.json" > "$inspect_out"
if grep -q '"lifecycle":"stale"' "$inspect_out"; then pass "inspect ignores request ids as terminal handles"; else fail "request id inspection rejection"; fi
ORCA_LIST_MODE=invalid PATH="$BIN:$PATH" bash "$CLI" inspect --receipt "$ORCA_WT/.review/ISSUE-503-TRANSPORT.json" > "$inspect_out"
if grep -q '"lifecycle":"handle_unverifiable"' "$inspect_out"; then pass "inspect rejects a missing terminal collection as unverifiable"; else fail "missing terminal collection normalization"; fi
ORCA_LIST_MODE=fail PATH="$BIN:$PATH" bash "$CLI" inspect --receipt "$ORCA_WT/.review/ISSUE-503-TRANSPORT.json" > "$inspect_out"
if grep -q '"lifecycle":"handle_unverifiable"' "$inspect_out"; then
  pass "inspect normalizes an unreadable adapter handle probe"
else fail "unverifiable external handle normalization"; fi
runner_path="$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).runner.path)' "$ORCA_WT/.review/ISSUE-503-TRANSPORT.json")"
printf '%s\n' '# changed' >> "$runner_path"
PATH="$BIN:$PATH" bash "$CLI" inspect --receipt "$ORCA_WT/.review/ISSUE-503-TRANSPORT.json" > "$inspect_out"
if grep -q '"lifecycle":"stale"' "$inspect_out"; then pass "inspect detects stale runner identity"; else fail "stale receipt detection"; fi

check_transport_fault_fixture() {
  fixture_name="$1"
  expected_error="$2"
  node - "$VALIDATOR" "$SCHEMA" "$ROOT/schemas/fixtures/$fixture_name" "$expected_error" <<'NODE'
const { validate } = require(process.argv[2]);
const fs = require("fs");
const schema = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
const value = JSON.parse(fs.readFileSync(process.argv[4], "utf8"));
const expectedError = process.argv[5];
const errors = validate(schema, value);
process.exit(errors.length > 0 && errors.some((message) => message.includes(expectedError)) ? 0 : 1);
NODE
  if [ "$?" -eq 0 ]; then pass "transport receipt one-fault fixture $fixture_name names its specific fault"; else fail "transport receipt one-fault fixture $fixture_name fault naming"; fi
}
node - "$VALIDATOR" "$SCHEMA" "$ROOT/schemas/fixtures/transport_receipt.valid.json" <<'NODE'
const { validate } = require(process.argv[2]);
const fs = require("fs");
const schema = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
const value = JSON.parse(fs.readFileSync(process.argv[4], "utf8"));
process.exit(validate(schema, value).length ? 1 : 0);
NODE
if [ "$?" -eq 0 ]; then pass "transport receipt valid fixture still enforces the contract"; else fail "transport receipt valid fixture"; fi
check_transport_fault_fixture transport_receipt.fault-authoritative.invalid.json '$.authoritative: must equal false'
check_transport_fault_fixture transport_receipt.fault-adapter.invalid.json '$.adapter: must be one of ["cmux","orca","herdr"]'
check_transport_fault_fixture transport_receipt.fault-capabilities.invalid.json '$.capabilities: must contain at least 1 items'
check_transport_fault_fixture transport_receipt.fault-external_handle.invalid.json '$.external_handle: must contain at least 1 characters'
check_transport_fault_fixture transport_receipt.fault-runner_sha256.invalid.json '$.runner.sha256: must match ^[a-f0-9]{64}$'
check_transport_fault_fixture transport_receipt.fault-launched_at.invalid.json '$.launched_at: must match'
check_transport_fault_fixture transport_receipt.fault-created_at.invalid.json '$.created_at: must match'

capabilities_out="$TMP_ROOT/capabilities.json"
TRANSPORT_USED="$TMP_ROOT/capability-unused" CMUX_ARGV="$TMP_ROOT/capability-cmux" ORCA_ARGV="$TMP_ROOT/capability-orca" \
HERDR_ENV=1 HERDR_SOCKET_PATH=socket HERDR_STATE_DIR="$TMP_ROOT/capability-herdr-state" PATH="$BIN:$PATH" \
bash "$CLI" capabilities --worktree "$WT" > "$capabilities_out"
capabilities_ec=$?
if [ "$capabilities_ec" -eq 0 ] && node -e '
const v = require(process.argv[1]);
const { ADAPTERS } = require(process.argv[2]);
if (v.schema_version !== "1" || !Array.isArray(v.adapters) || !Array.isArray(v.runtimes)) process.exit(1);
const names = v.adapters.map(x => x.adapter).sort().join(",");
if (names !== ADAPTERS.slice().sort().join(",")) process.exit(1);
for (const entry of v.adapters) {
  if (typeof entry.available !== "boolean" || entry.available !== true) process.exit(1);
  if (typeof entry.version !== "string" || !entry.version.trim()) process.exit(1);
  if (!Array.isArray(entry.capabilities) || !entry.capabilities.length) process.exit(1);
  const seen = new Set();
  for (const item of entry.capabilities) {
    if (typeof item !== "string" || !item.trim() || seen.has(item)) process.exit(1);
    seen.add(item);
  }
}
' "$capabilities_out" "$PRODUCT_HOME/scripts/lib/transport-registry.cjs"; then
  pass "AC-111-6 capabilities aggregate keeps schema_version/adapters/runtimes with strict per-adapter shape"
else fail "AC-111-6 strict capabilities aggregate ($(cat "$capabilities_out"))"; fi

# --- strict adapter-output contract (issue 111) -------------------------------
# The shared dispatch core must reject malformed adapter output instead of
# accepting it as a proven capability/launch/inspect result. These cases run
# against a fake adapter installed into the product copy so the exact bytes a
# malformed adapter would emit reach dispatch-core.sh unchanged.
cat > "$PRODUCT_HOME/scripts/adapters/cmux.sh" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "capabilities" ]; then
  printf '%s\n' "${FAKE_CMUX_CAPABILITY_JSON:-}"
  exit "${FAKE_CMUX_CAPABILITY_STATUS:-0}"
fi
if [ "${1:-}" = "launch" ]; then
  printf '%s\n' "${FAKE_CMUX_LAUNCH_JSON:-}"
  exit "${FAKE_CMUX_LAUNCH_STATUS:-0}"
fi
if [ "${1:-}" = "inspect" ]; then
  printf '%s\n' "${FAKE_CMUX_INSPECT_JSON:-}"
  exit 0
fi
exit 2
EOF
chmod +x "$PRODUCT_HOME/scripts/adapters/cmux.sh"

STRICT_CAPABILITY='{"adapter":"cmux","available":true,"reason_code":"available","version":"0.64.18","capabilities":["workspace.create.cwd"]}'
strict_capability_case() {
  case_name="$1"; expected_reason="$2"; payload="$3"
  case_wt="$TMP_ROOT/strict-cap-$case_name-wt"
  make_worktree "$case_wt" 610
  case_out="$TMP_ROOT/strict-cap-$case_name.out"
  FAKE_CMUX_CAPABILITY_JSON="$payload" AGENT_WORKFLOW_CODEX_BIN="$BIN/codex" PATH="$BIN:$PATH" \
    bash "$CLI" dispatch --orchestrator cmux --issue 610 --worktree "$case_wt" --read-only --poll-timeout 1 >"$case_out" 2>&1
  case_ec=$?
  if [ "$case_ec" -eq 2 ] && grep -q "$expected_reason" "$case_out" \
    && [ ! -e "$case_wt/.review/ISSUE-610-TRANSPORT.json" ] \
    && ! find "$case_wt/.review" -type d -name 'ISSUE-610-launch.*' | grep -q .; then
    pass "AC-111 capability $case_name is rejected before runner or receipt"
  else fail "AC-111 capability $case_name (ec=$case_ec $(cat "$case_out"))"; fi
}
strict_capability_case AC-111-1-empty-capabilities required_capability_missing '{"adapter":"cmux","available":true,"version":"0.64.18","capabilities":[]}'
strict_capability_case AC-111-2-duplicate-capabilities required_capability_missing '{"adapter":"cmux","available":true,"version":"0.64.18","capabilities":["workspace.create.cwd","workspace.create.cwd"]}'
strict_capability_case AC-111-3-non-string-capability required_capability_missing '{"adapter":"cmux","available":true,"version":"0.64.18","capabilities":["workspace.create.cwd",7]}'
strict_capability_case AC-111-3-blank-capability-entry required_capability_missing '{"adapter":"cmux","available":true,"version":"0.64.18","capabilities":["workspace.create.cwd","   "]}'
strict_capability_case AC-111-4-whitespace-version required_capability_missing '{"adapter":"cmux","available":true,"version":"   ","capabilities":["workspace.create.cwd"]}'
strict_capability_case AC-111-unavailable-reason-preserved binary_not_found '{"adapter":"cmux","available":false,"reason_code":"binary_not_found","version":"unknown","capabilities":[]}'

strict_launch_case() {
  case_name="$1"; launch_json="$2"; launch_status="${3:-0}"
  case_wt="$TMP_ROOT/strict-launch-$case_name-wt"
  make_worktree "$case_wt" 611
  case_out="$TMP_ROOT/strict-launch-$case_name.out"
  FAKE_CMUX_CAPABILITY_JSON="$STRICT_CAPABILITY" \
  FAKE_CMUX_LAUNCH_JSON="$launch_json" FAKE_CMUX_LAUNCH_STATUS="$launch_status" \
  AGENT_WORKFLOW_CODEX_BIN="$BIN/codex" PATH="$BIN:$PATH" AGENT_WORKFLOW_POLL_INTERVAL=1 \
    bash "$CLI" dispatch --orchestrator cmux --issue 611 --worktree "$case_wt" --read-only --poll-timeout 1 >"$case_out" 2>&1
  case_ec=$?
  if [ "$case_ec" -eq 2 ] && grep -q 'invalid or ambiguous external handle' "$case_out" \
    && [ ! -e "$case_wt/.review/ISSUE-611-TRANSPORT.json" ]; then
    pass "AC-111 launch $case_name is rejected with no receipt published"
  else fail "AC-111 launch $case_name (ec=$case_ec $(cat "$case_out"))"; fi
}
strict_launch_case AC-111-5-whitespace-handle '{"external_handle":"   ","lifecycle":"launched"}'
strict_launch_case AC-111-8-failed-lifecycle '{"external_handle":"cmux-611","lifecycle":"failed"}'
strict_launch_case AC-111-9-unknown-lifecycle '{"external_handle":"cmux-611","lifecycle":"pending"}'
strict_launch_case AC-111-9-missing-lifecycle '{"external_handle":"cmux-611"}'

# The preserved Herdr-style ambiguous path: command_unconfirmed with a
# non-zero launch exit is still accepted and still publishes its receipt.
unconfirmed_wt="$TMP_ROOT/strict-launch-unconfirmed-wt"
make_worktree "$unconfirmed_wt" 613
unconfirmed_out="$TMP_ROOT/strict-launch-unconfirmed.out"
FAKE_CMUX_CAPABILITY_JSON="$STRICT_CAPABILITY" \
FAKE_CMUX_LAUNCH_JSON='{"external_handle":"cmux-613","lifecycle":"command_unconfirmed"}' FAKE_CMUX_LAUNCH_STATUS=7 \
AGENT_WORKFLOW_CODEX_BIN="$BIN/codex" PATH="$BIN:$PATH" AGENT_WORKFLOW_POLL_INTERVAL=1 \
  bash "$CLI" dispatch --orchestrator cmux --issue 613 --worktree "$unconfirmed_wt" --read-only --poll-timeout 1 >"$unconfirmed_out" 2>&1
unconfirmed_ec=$?
if [ "$unconfirmed_ec" -eq 7 ] && [ -f "$unconfirmed_wt/.review/ISSUE-613-TRANSPORT.json" ]; then
  pass "AC-111 command_unconfirmed launch with non-zero status still publishes its receipt"
else fail "AC-111 command_unconfirmed preservation (ec=$unconfirmed_ec $(cat "$unconfirmed_out"))"; fi

# Inspect results are validated against the same strict lifecycle contract.
strict_inspect_wt="$TMP_ROOT/strict-inspect-wt"
make_worktree "$strict_inspect_wt" 612
strict_runner="$TMP_ROOT/strict-runner-612.sh"
printf '%s\n' '#!/usr/bin/env bash' > "$strict_runner"
strict_runner_sha="$(node -e 'const fs=require("fs"),crypto=require("crypto"); process.stdout.write(crypto.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"))' "$strict_runner")"
strict_receipt="$strict_inspect_wt/.review/ISSUE-612-TRANSPORT.json"
node - "$strict_receipt" "$strict_inspect_wt" "$strict_runner" "$strict_runner_sha" <<'NODE'
const fs = require("fs");
const [file, worktree, runner, sha] = process.argv.slice(2);
fs.writeFileSync(file, JSON.stringify({
  schema_version: "1", artifact_type: "transport_receipt", authoritative: false,
  issue: 612, adapter: "cmux", adapter_version: "0.64.18",
  capabilities: ["workspace.create.cwd"],
  external_handle: "workspace:612",
  worktree_path: worktree,
  runner: { path: runner, relative_path: ".review/ISSUE-612-launch.fixture/launch.sh", sha256: sha },
  launched_at: "2026-07-21T01:00:00Z", created_at: "2026-07-21T01:00:00Z"
}, null, 2) + "\n");
NODE
strict_inspect_case() {
  case_name="$1"; payload="$2"
  case_out="$TMP_ROOT/strict-inspect-$case_name.out"
  FAKE_CMUX_INSPECT_JSON="$payload" PATH="$BIN:$PATH" \
    bash "$CLI" inspect --receipt "$strict_receipt" >"$case_out" 2>&1
  case_ec=$?
  if [ "$case_ec" -ne 0 ] && grep -q 'invalid adapter inspection' "$case_out" \
    && ! grep -q '"lifecycle":"live"' "$case_out" && ! grep -q '"lifecycle":"stale"' "$case_out"; then
    pass "AC-111 inspect $case_name is rejected, never promoted to live or stale"
  else fail "AC-111 inspect $case_name (ec=$case_ec $(cat "$case_out"))"; fi
}
strict_inspect_case AC-111-10-blank-reason-live '{"lifecycle":"live","reason":"   "}'
strict_inspect_case AC-111-10-blank-reason-unverifiable '{"lifecycle":"handle_unverifiable","reason":"   "}'
strict_inspect_case AC-111-10-missing-reason '{"lifecycle":"live"}'
strict_inspect_case AC-111-11-unknown-lifecycle '{"lifecycle":"zombie","reason":"looks alive"}'
strict_inspect_case AC-111-11-unknown-lifecycle-blank-reason '{"lifecycle":"zombie"}'
valid_inspect_out="$TMP_ROOT/strict-inspect-valid.out"
FAKE_CMUX_INSPECT_JSON='{"lifecycle":"live","reason":"workspace handle is present"}' PATH="$BIN:$PATH" \
  bash "$CLI" inspect --receipt "$strict_receipt" >"$valid_inspect_out" 2>&1
valid_inspect_ec=$?
if [ "$valid_inspect_ec" -eq 0 ] && grep -q '"lifecycle":"live"' "$valid_inspect_out"; then
  pass "AC-111 well-formed inspect result with a non-blank reason is still accepted"
else fail "AC-111 inspect valid control (ec=$valid_inspect_ec $(cat "$valid_inspect_out"))"; fi

# Aggregate fallbacks: a failing or malformed child probe folds into the
# synthetic unavailable entry while the overall aggregate stays exit 0.
cat > "$PRODUCT_HOME/scripts/adapters/herdr.sh" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "capabilities" ]; then
  printf '%s\n' "${FAKE_HERDR_CAP_STDOUT:-}"
  exit "${FAKE_HERDR_CAP_STATUS:-0}"
fi
exit 2
EOF
chmod +x "$PRODUCT_HOME/scripts/adapters/herdr.sh"
strict_aggregate_case() {
  case_name="$1"; stdout_payload="$2"; exit_status="$3"
  case_out="$TMP_ROOT/strict-aggregate-$case_name.json"
  FAKE_CMUX_CAPABILITY_JSON="$STRICT_CAPABILITY" \
  FAKE_HERDR_CAP_STDOUT="$stdout_payload" FAKE_HERDR_CAP_STATUS="$exit_status" \
  TRANSPORT_USED="$TMP_ROOT/strict-aggregate-unused" CMUX_ARGV="$TMP_ROOT/strict-aggregate-cmux" ORCA_ARGV="$TMP_ROOT/strict-aggregate-orca" \
  PATH="$BIN:$PATH" bash "$CLI" capabilities --worktree "$WT" > "$case_out" 2>&1
  case_ec=$?
  if [ "$case_ec" -eq 0 ] && node - "$case_out" <<'NODE'
const fs = require("fs");
try {
  const value = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  if (value.schema_version !== "1" || !Array.isArray(value.adapters) || !Array.isArray(value.runtimes)) process.exit(2);
  const byName = {};
  for (const entry of value.adapters) byName[entry.adapter] = entry;
  const herdr = byName.herdr;
  if (!herdr || herdr.available !== false || herdr.reason_code !== "capability_probe_failed"
      || herdr.version !== "unknown" || !Array.isArray(herdr.capabilities) || herdr.capabilities.length) process.exit(2);
  if (!byName.cmux || byName.cmux.available !== true || !byName.orca || byName.orca.available !== true) process.exit(2);
} catch (error) { process.exit(2); }
NODE
  then
    pass "AC-111 aggregate $case_name folds into the synthetic unavailable fallback with exit 0"
  else fail "AC-111 aggregate $case_name (ec=$case_ec $(cat "$case_out"))"; fi
}
strict_aggregate_case AC-111-6-child-exit-nonzero '{"adapter":"herdr","available":true,"version":"0.8.0","capabilities":["workspace.create.cwd"]}' 3
strict_aggregate_case AC-111-7-child-non-json-stdout 'definitely not json' 0
strict_aggregate_case AC-111-7-child-wrong-shape '{"adapter":"orca","available":true,"version":"1.4.161","capabilities":["terminal.create.title"]}' 0
strict_aggregate_case AC-111-7-child-empty-stdout '' 0
strict_aggregate_case AC-111-8-child-blank-version '{"adapter":"herdr","available":true,"version":"   ","capabilities":["workspace.create.cwd"]}' 0
strict_aggregate_case AC-111-8-child-empty-capabilities '{"adapter":"herdr","available":true,"version":"0.8.0","capabilities":[]}' 0
strict_aggregate_case AC-111-8-child-duplicate-capabilities '{"adapter":"herdr","available":true,"version":"0.8.0","capabilities":["workspace.create.cwd","workspace.create.cwd"]}' 0
strict_aggregate_case AC-111-8-child-blank-capability-entry '{"adapter":"herdr","available":true,"version":"0.8.0","capabilities":["workspace.create.cwd","   "]}' 0

# Restore the real adapters so later consumers of the product copy are intact.
cp "$ROOT/scripts/adapters/cmux.sh" "$PRODUCT_HOME/scripts/adapters/cmux.sh"
cp "$ROOT/scripts/adapters/herdr.sh" "$PRODUCT_HOME/scripts/adapters/herdr.sh"

# --- transport-neutral dispatch timing env names (ISSUE-119) ---
# The shared poll/pre-marker test seam must accept the generic
# AGENT_WORKFLOW_* names while CMUX_DISPATCH_* remains the legacy fallback;
# when both are set the generic name wins. Each case dispatches through a
# cmux stub that never runs the launch command, so no RUN.json can appear
# and the dispatch can only end via the poll timeout: the wall-clock
# duration therefore observes which env name supplied the timing.
ENV_BIN="$TMP_ROOT/bin-env-cmux"
mkdir -p "$ENV_BIN"
cat > "$ENV_BIN/cmux" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo 'cmux 0.64.18'; exit 0; fi
if [ "${1:-}" = "workspace" ] && [ "${2:-}" = "create" ] && [ "${3:-}" = "--help" ]; then
  printf '%s\n' 'Usage: cmux workspace create [flags]' '  --cwd PATH       Working directory for the workspace' '  --command TEXT   Command the workspace runs'
  exit 0
fi
printf '%s\n' '{"id":"cmux-env-precedence"}'
EOF
chmod +x "$ENV_BIN/cmux"
env_precedence_case() {
  case_id="$1"; case_issue="$2"; case_env="$3"; min_seconds="$4"; max_seconds="$5"
  case_wt="$TMP_ROOT/env-precedence-$case_issue"
  make_worktree "$case_wt" "$case_issue"
  case_out="$TMP_ROOT/env-precedence-$case_issue.out"
  case_start="$(date +%s)"
  env $case_env AGENT_WORKFLOW_CODEX_BIN="$BIN/codex" PATH="$ENV_BIN:$PATH" \
    bash "$CLI" dispatch --orchestrator cmux --issue "$case_issue" --worktree "$case_wt" --tier trivial --poll-timeout 2 >"$case_out" 2>&1
  case_ec=$?
  case_duration=$(( $(date +%s) - case_start ))
  if [ "$case_ec" -ne 0 ] && grep -q 'dispatch-core: transport receipt=' "$case_out" \
    && [ "$case_duration" -ge "$min_seconds" ] && [ "$case_duration" -lt "$max_seconds" ]; then
    pass "$case_id"
  else
    fail "$case_id (ec=$case_ec duration=${case_duration}s $(cat "$case_out"))"
  fi
}
env_precedence_case "AC-119-1 AGENT_WORKFLOW_POLL_INTERVAL alone sets the poll interval" 613 "AGENT_WORKFLOW_POLL_INTERVAL=1" 2 4
env_precedence_case "AC-119-2 legacy CMUX_DISPATCH_POLL_INTERVAL alone still sets the poll interval" 614 "CMUX_DISPATCH_POLL_INTERVAL=1" 2 4
env_precedence_case "AC-119-3 AGENT_WORKFLOW_POLL_INTERVAL wins over a set CMUX_DISPATCH_POLL_INTERVAL" 615 "AGENT_WORKFLOW_POLL_INTERVAL=1 CMUX_DISPATCH_POLL_INTERVAL=5" 2 4
env_precedence_case "AC-119-4 AGENT_WORKFLOW_PRE_MARKER_DELAY alone delays the write marker" 616 "AGENT_WORKFLOW_PRE_MARKER_DELAY=2 AGENT_WORKFLOW_POLL_INTERVAL=1" 3 6
env_precedence_case "AC-119-5 legacy CMUX_DISPATCH_PRE_MARKER_DELAY alone still delays the write marker" 617 "CMUX_DISPATCH_PRE_MARKER_DELAY=2 AGENT_WORKFLOW_POLL_INTERVAL=1" 3 6
env_precedence_case "AC-119-6 AGENT_WORKFLOW_PRE_MARKER_DELAY wins over a set CMUX_DISPATCH_PRE_MARKER_DELAY" 618 "AGENT_WORKFLOW_PRE_MARKER_DELAY=1 CMUX_DISPATCH_PRE_MARKER_DELAY=5 AGENT_WORKFLOW_POLL_INTERVAL=1" 3 5

# --- shared adapter helpers (issue 130) ----------------------------------------
# The three transport adapters must share one implementation each of semver
# parsing, capability emission, help probing, the runner-path guard, and the
# graceful handle_unverifiable fallback — while keeping their own per-adapter
# CLI arg loops and case dispatch (no generic dispatch framework).
SHARED_ADAPTER_LIB="$ROOT/scripts/lib/adapter-helpers.sh"
AC130_ADAPTERS="cmux orca herdr"

ac130_adapters_pass() {
  check_description="$1"
  shift
  for ac130_adapter in $AC130_ADAPTERS; do
    "$@" "$ROOT/scripts/adapters/$ac130_adapter.sh" || { fail "$check_description ($ac130_adapter)"; return 1; }
  done
  pass "$check_description"
  return 0
}

ac130_adapters_pass "AC-130-1 every adapter sources the shared helper lib and calls the shared semver authority" sh -c 'grep -F -q "adapter-helpers.sh" "$1" && grep -F -q "ADAPTER_SEMVER" "$1"' _
ac130_semver_case() {
  ac130_raw="$1"; ac130_floor="$2"; ac130_expected="$3"
  ac130_got="$(node "$ROOT/scripts/lib/semver.cjs" parse-floor "$ac130_raw" "$ac130_floor" 2>/dev/null)"
  ac130_ec=$?
  [ "$ac130_ec" -eq 0 ] && [ "$ac130_got" = "$ac130_expected" ]
}
if ac130_semver_case 'herdr 0.9.1' 0.8.0 0.9.1 \
  && ac130_semver_case 'v0.8.0' 0.8.0 0.8.0 \
  && ! ac130_semver_case '0.8.0-rc.1' 0.8.0 '' \
  && ! ac130_semver_case 'not-a-version' 0.8.0 ''; then
  pass "AC-130-1 shared semver parser is prerelease-aware and floor-checked"
else fail "AC-130-1 shared semver parser"; fi

if node - "$ROOT/scripts/lib/adapter-json.cjs" "$ROOT/scripts/lib/capability-result.cjs" <<'NODE'
const { emitCapabilities } = require(process.argv[2]);
const { CAPABILITY_RESULT_FIELDS, validateCapabilityResult } = require(process.argv[3]);
if (!Array.isArray(CAPABILITY_RESULT_FIELDS) || !CAPABILITY_RESULT_FIELDS.length) process.exit(1);
const emitted = emitCapabilities("herdr", "true", "available", "0.8.0;binary-sha256:abc", ["session.inherited", "pane.run"]);
const value = JSON.parse(emitted);
if (Object.keys(value).sort().join(",") !== CAPABILITY_RESULT_FIELDS.slice().sort().join(",")) process.exit(1);
if (!validateCapabilityResult(value, "herdr")) process.exit(1);
NODE
then pass "AC-130-2 emitCapabilities shares the capability-result field set and stays acceptance-valid"
else fail "AC-130-2 emitCapabilities field-set sharing"; fi
ac130_adapters_pass "AC-130-2 every adapter emits capabilities through adapter-json.cjs" sh -c 'grep -F -q "ADAPTER_JSON" "$1"' _

ac130_single_definition() {
  ac130_symbol="$1"
  grep -E -q "^${ac130_symbol}\(\)" "$SHARED_ADAPTER_LIB" \
    && [ "$(grep -R -l -E "^${ac130_symbol}\(\)" "$ROOT/scripts/adapters" | wc -l | tr -d ' ')" = "0" ]
}
if ac130_single_definition help_has \
  && ac130_single_definition runner_path_allowed \
  && ac130_single_definition adapter_handle_unverifiable; then
  pass "AC-130-3 help_has, runner guard, and graceful fallback each have exactly one shared definition"
else fail "AC-130-3 shared probe/guard/fallback single ownership"; fi
if [ "$(grep -R -l -F '.review/ISSUE-*-launch.*/launch.sh' "$ROOT/scripts/adapters" | wc -l | tr -d ' ')" = "0" ] \
  && grep -F -q '.review/ISSUE-*-launch.*/launch.sh' "$SHARED_ADAPTER_LIB"; then
  pass "AC-130-3 the runner-path glob guard lives only in the shared helper lib"
else fail "AC-130-3 runner glob guard ownership"; fi
ac130_adapters_pass "AC-130-3 every adapter probes help output and runner paths through the shared helpers" sh -c 'grep -F -q "help_has" "$1" && grep -F -q "runner_path_allowed" "$1"' _

ac130_adapters_pass "AC-130-4 each adapter keeps its own CLI arg loop and case dispatch" sh -c 'grep -F -q "while [ \$# -gt 0 ]" "$1" && grep -F -q "case \"\$command_name\"" "$1"' _
if [ ! -e "$ROOT/scripts/lib/dispatch-framework.sh" ] && ! ls "$ROOT/scripts/adapters" | grep -F -q 'common'; then
  pass "AC-130-4 no generic CLI-arg/case-dispatch framework was introduced"
else fail "AC-130-4 forbidden generic dispatch framework"; fi

if [ "$FAILURES" -eq 0 ]; then
  pass "AC-130-5 shared helpers keep the full adapter interface contract green"
else fail "AC-130-5 adapter interface contract regressions above"; fi

echo "---"
if [ "$FAILURES" -eq 0 ]; then echo "ALL CASES PASS"; exit 0; fi
echo "$FAILURES CASE(S) FAILED"
exit 1
