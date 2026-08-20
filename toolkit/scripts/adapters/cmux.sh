#!/usr/bin/env bash
# cmux transport adapter. Accepts only the typed seat fields below.
# Live-tui subcommands (design issue #203) use the generic direct-argv
# `cmux run ... -- <argv...>` path with structured {workspace, surface}
# handles. Every vendor command is gated on the installed binary's own
# --help tokens, never on a version number: a missing token fails closed.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/adapter-helpers.sh"
CMUX_HANDLES="$SCRIPT_DIR/cmux-handles.cjs"

# help_has <help-text> <token> comes from adapter-helpers.sh; this wrapper
# proves a whole token group from one captured --help text.
cmux_help_proves() {
  cmux_hay="$1"
  shift
  for cmux_token in "$@"; do
    help_has "$cmux_hay" "$cmux_token" || return 1
  done
}

# Token contracts mirror the documented low-level command surface:
#   run          --new-workspace --cwd --name --json, argv list, and the
#                  envelope's own surface/workspace identity fields
#   send         --surface with byte-exact --bytes payload delivery
#   send-key     --surface with documented key names (enter)
#   read-screen  --surface
#   wait-for     --surface --pattern --timeout-ms (screen regex sync; a
#                 synchronization primitive only, never lifecycle authority)
#   close-workspace --workspace
#   list-agents  --surface --state --json with the exact state vocabulary
#                 working|blocked|idle|done|unknown; only this query can
#                 admit wait-settled, otherwise cmux never reports settled
cmux_live_run_proven() {
  cmux_run_help="$(cmux run --help 2>&1)" || return 1
  cmux_help_proves "$cmux_run_help" --new-workspace --cwd --name --json argv surface workspace
}

cmux_live_send_proven() {
  cmux_send_help="$(cmux send --help 2>&1)" || return 1
  cmux_help_proves "$cmux_send_help" --surface --bytes || return 1
  cmux_sendkey_help="$(cmux send-key --help 2>&1)" || return 1
  cmux_help_proves "$cmux_sendkey_help" --surface enter
}

cmux_live_sendkey_proven() {
  cmux_sendkey_help="$(cmux send-key --help 2>&1)" || return 1
  cmux_help_proves "$cmux_sendkey_help" --surface
}

cmux_live_readscreen_proven() {
  cmux_readscreen_help="$(cmux read-screen --help 2>&1)" || return 1
  cmux_help_proves "$cmux_readscreen_help" --surface
}

cmux_live_waitfor_proven() {
  cmux_waitfor_help="$(cmux wait-for --help 2>&1)" || return 1
  cmux_help_proves "$cmux_waitfor_help" --surface --pattern --timeout-ms
}

cmux_live_close_proven() {
  cmux_close_help="$(cmux close-workspace --help 2>&1)" || return 1
  cmux_help_proves "$cmux_close_help" --workspace
}

cmux_live_state_proven() {
  cmux_state_help="$(cmux list-agents --help 2>&1)" || return 1
  cmux_help_proves "$cmux_state_help" --surface --state --json working blocked idle done unknown
}

# The complete semantic live contract is all-or-none: every session.*
# capability requires the state query too, because wait-settled must never
# be claimed on a cmux that cannot prove agent state.
cmux_live_contract_proven() {
  cmux_live_run_proven || return 1
  cmux_live_send_proven || return 1
  cmux_live_readscreen_proven || return 1
  cmux_live_waitfor_proven || return 1
  cmux_live_close_proven || return 1
  cmux_live_state_proven || return 1
}

cmux_live_refuse() {
  echo "ERROR: cmux_live_capability_missing: $1 is not help-proven on the installed cmux" >&2
  exit 3
}

# Extract the cmux-domain identities from the supervisor-written
# session.json. Sets CMUX_LIVE_WORKSPACE (lifecycle), CMUX_LIVE_SURFACE
# (io), and CMUX_LIVE_AGENT; refuses any file that is not a live-tui
# session carrying the full structured tuple.
cmux_live_load_session() {
  CMUX_LIVE_HANDLES="$(node "$CMUX_HANDLES" live-session "$1")" || {
    echo "ERROR: cmux live session json is not a structured live-tui session" >&2
    exit 3
  }
  CMUX_LIVE_WORKSPACE="$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).workspace)' "$CMUX_LIVE_HANDLES")" || exit 3
  CMUX_LIVE_SURFACE="$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).surface)' "$CMUX_LIVE_HANDLES")" || exit 3
  CMUX_LIVE_AGENT="$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).agent)' "$CMUX_LIVE_HANDLES")" || exit 3
}

cmux_live_arg_session() {
  CMUX_LIVE_SESSION_JSON=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --session-json) CMUX_LIVE_SESSION_JSON="$2"; shift 2 ;;
      *) exit 2 ;;
    esac
  done
  [ -n "$CMUX_LIVE_SESSION_JSON" ] || exit 2
  [ -f "$CMUX_LIVE_SESSION_JSON" ] || exit 2
}

cmux_live_arg_session_timeout() {
  CMUX_LIVE_SESSION_JSON=""
  CMUX_LIVE_TIMEOUT_MS=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --session-json) CMUX_LIVE_SESSION_JSON="$2"; shift 2 ;;
      --timeout-ms) CMUX_LIVE_TIMEOUT_MS="$2"; shift 2 ;;
      *) exit 2 ;;
    esac
  done
  [ -n "$CMUX_LIVE_SESSION_JSON" ] && [ -n "$CMUX_LIVE_TIMEOUT_MS" ] || exit 2
  [ -f "$CMUX_LIVE_SESSION_JSON" ] || exit 2
  case "$CMUX_LIVE_TIMEOUT_MS" in ''|*[!0-9]*) exit 2 ;; esac
}

cmux_live_now_ms() {
  node -e 'process.stdout.write(String(Date.now()))'
}

command_name="${1:-}"
shift || true
case "$command_name" in
  capabilities)
    [ "${1:-}" = "--worktree" ] || exit 2
    probe_live=false
    if [ "$#" -eq 3 ] && [ "$3" = "--probe-live" ]; then
      probe_live=true
    elif [ "$#" -ne 2 ]; then
      exit 2
    fi
    if command -v cmux >/dev/null 2>&1; then
      binary="$(command -v cmux)"
      digest="$(node -e 'const fs=require("fs"),crypto=require("crypto"); process.stdout.write(crypto.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"))' "$binary" 2>/dev/null)"
      [ -n "$digest" ] || digest="unreadable"
      version="$(cmux --version 2>/dev/null)"
      parsed_version="$(node "$ADAPTER_SEMVER" parse-floor "$version" 0.64.0 2>/dev/null)"
      parsed_version_status=$?
      workspace_help="$(cmux workspace create --help 2>&1)"
      workspace_help_status=$?
      launch_flags_proven=false
      if help_has "$workspace_help" '--cwd' \
        && help_has "$workspace_help" '--command'; then
        launch_flags_proven=true
      elif printf '%s\n' "$workspace_help" | grep -F 'new-workspace' | grep -F 'same' | grep -F -q 'create'; then
        # An explicit delegation claim is only proof when the delegated
        # surface itself lists both launch flags.
        delegation_help="$(cmux new-workspace --help 2>&1)"
        if help_has "$delegation_help" '--cwd' \
          && help_has "$delegation_help" '--command'; then
          launch_flags_proven=true
        fi
      fi
      if [ "$workspace_help_status" -ne 0 ] || [ "$launch_flags_proven" != "true" ] \
        || [ "$parsed_version_status" -ne 0 ] || [ -z "$parsed_version" ]; then
        node "$ADAPTER_JSON" capabilities cmux false required_capability_missing unknown ''
        exit 0
      fi
      caps_csv='workspace.create.cwd,workspace.create.command,workspace.list.read_only'
      if [ "$probe_live" = "true" ]; then
        live_reason=""
        if ! cmux_live_run_proven; then live_reason="cmux run direct-argv contract"
        elif ! cmux_live_send_proven; then live_reason="cmux send/send-key surface contract"
        elif ! cmux_live_readscreen_proven; then live_reason="cmux read-screen surface contract"
        elif ! cmux_live_waitfor_proven; then live_reason="cmux wait-for pattern contract"
        elif ! cmux_live_close_proven; then live_reason="cmux close-workspace contract"
        elif ! cmux_live_state_proven; then live_reason="cmux list-agents state query (cmux never reports settled without it)"
        fi
        if [ -z "$live_reason" ]; then
          live_csv="$(node "$ADAPTER_TRANSPORT_REGISTRY" live-capabilities | tr '\n' ',' | sed -e 's/,$//')"
          caps_csv="$caps_csv,$live_csv"
        else
          echo "cmux live unavailable: $live_reason is not help-proven" >&2
        fi
      fi
      node "$ADAPTER_JSON" capabilities cmux true available \
        "$(adapter_provenance_version "$version" "$digest")" \
        "$caps_csv"
    else
      node "$ADAPTER_JSON" capabilities cmux false binary_not_found unknown ''
    fi
    ;;
  launch-live)
    NAME=""; WORKTREE=""; SPEC=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --name) NAME="$2"; shift 2 ;;
        --worktree) WORKTREE="$2"; shift 2 ;;
        --launch-spec) SPEC="$2"; shift 2 ;;
        *) exit 2 ;;
      esac
    done
    [ -n "$NAME" ] && [ -n "$WORKTREE" ] && [ -n "$SPEC" ] || exit 2
    [ -f "$SPEC" ] || exit 2
    cmux_live_run_proven || cmux_live_refuse "cmux run direct-argv contract"
    # run-argv refuses non-transport prompt delivery and any spec env the
    # documented run envelope cannot deliver, and single-quotes every
    # spec-derived token so nothing crosses a shell unquoted.
    run_args="$(node "$CMUX_HANDLES" run-argv "$SPEC" "$NAME")" || exit 3
    create_output="$(eval "cmux run --new-workspace $run_args")" || exit $?
    live_json="$(node "$CMUX_HANDLES" live-run "$create_output")" || exit 3
    normalized="$(node "$ADAPTER_HANDLE_RESULT" normalize "$live_json")" || {
      echo "ERROR: cmux run envelope did not yield one provable {workspace,surface,terminal_id} tuple" >&2
      exit 2
    }
    printf '%s\n' "$normalized"
    ;;
  wait-ready)
    cmux_live_arg_session_timeout "$@"
    cmux_live_waitfor_proven || cmux_live_refuse "cmux wait-for pattern contract"
    cmux_live_load_session "$CMUX_LIVE_SESSION_JSON"
    # Screen regex is a synchronization primitive: `.` matches as soon as
    # the launched argv paints any cell, which is the readiness gate. It
    # is never evidence about completion.
    cmux wait-for --surface "$CMUX_LIVE_SURFACE" --pattern '.' --timeout-ms "$CMUX_LIVE_TIMEOUT_MS"
    ;;
  read)
    cmux_live_arg_session "$@"
    cmux_live_readscreen_proven || cmux_live_refuse "cmux read-screen surface contract"
    cmux_live_load_session "$CMUX_LIVE_SESSION_JSON"
    cmux read-screen --surface "$CMUX_LIVE_SURFACE"
    ;;
  send)
    INPUT_FILE=""
    CMUX_LIVE_SESSION_JSON=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --session-json) CMUX_LIVE_SESSION_JSON="$2"; shift 2 ;;
        --input-file) INPUT_FILE="$2"; shift 2 ;;
        *) exit 2 ;;
      esac
    done
    [ -n "$CMUX_LIVE_SESSION_JSON" ] && [ -n "$INPUT_FILE" ] || exit 2
    [ -f "$CMUX_LIVE_SESSION_JSON" ] && [ -f "$INPUT_FILE" ] || exit 2
    cmux_live_send_proven || cmux_live_refuse "cmux send/send-key surface contract"
    cmux_live_load_session "$CMUX_LIVE_SESSION_JSON"
    # Byte-exact delivery: --bytes carries the prompt base64-encoded so no
    # CLI-side escape-sequence interpretation can alter the body, then a
    # separate send-key enter submits it. A failed send never gets the
    # enter key, and an uncertain send is never retried here.
    prompt_b64="$(node "$CMUX_HANDLES" base64 "$INPUT_FILE")" || exit 2
    cmux send --surface "$CMUX_LIVE_SURFACE" --bytes "$prompt_b64" || exit $?
    cmux send-key --surface "$CMUX_LIVE_SURFACE" enter
    ;;
  wait-settled)
    cmux_live_arg_session_timeout "$@"
    cmux_live_state_proven || {
      echo "ERROR: cmux_live_state_unproven: agent-state query is not help-proven; cmux never reports settled, canonical artifacts are the only completion authority" >&2
      exit 3
    }
    cmux_live_load_session "$CMUX_LIVE_SESSION_JSON"
    CMUX_LIVE_POLL_MS="${CMUX_LIVE_STATE_POLL_MS:-100}"
    case "$CMUX_LIVE_POLL_MS" in ''|*[!0-9]*) exit 2 ;; esac
    settled_started="$(cmux_live_now_ms)"
    settled_state="none"
    while :; do
      agents_raw="$(cmux list-agents --surface "$CMUX_LIVE_SURFACE" --json 2>/dev/null)" || exit $?
      settled_state="$(node - "$agents_raw" "$CMUX_LIVE_SURFACE" <<'NODE'
const [raw, surface] = process.argv.slice(2);
try {
  const value = JSON.parse(raw);
  const agents = value && Array.isArray(value.agents) ? value.agents : [];
  const hit = agents.find(entry => entry && typeof entry === "object"
    && String(entry.surface) === String(surface));
  process.stdout.write(hit && hit.state ? String(hit.state) : "none");
} catch (_) { process.exit(2); }
NODE
      )" || exit 2
      case "$settled_state" in
        idle|done)
          # idle/done means the agent stopped foreground work; only the
          # canonical artifact gate may call this success.
          printf '{"state":"settled"}\n'
          exit 0
          ;;
        blocked)
          printf '{"state":"blocked"}\n'
          exit 0
          ;;
        unknown)
          # unknown is never success evidence; keep waiting and classify
          # as stale if it persists to the deadline.
          ;;
        working|none)
          ;;
        *)
          exit 2
          ;;
      esac
      settled_now="$(cmux_live_now_ms)"
      if [ $((settled_now - settled_started)) -ge "$CMUX_LIVE_TIMEOUT_MS" ]; then
        case "$settled_state" in
          unknown|none) printf '{"state":"stale"}\n' ;;
          *) printf '{"state":"%s"}\n' "$settled_state" ;;
        esac
        exit 0
      fi
      sleep "$(node -e 'process.stdout.write(String(Number(process.argv[1]) / 1000))' "$CMUX_LIVE_POLL_MS")"
    done
    ;;
  interrupt)
    cmux_live_arg_session "$@"
    cmux_live_sendkey_proven || cmux_live_refuse "cmux send-key surface contract"
    cmux_live_load_session "$CMUX_LIVE_SESSION_JSON"
    cmux send-key --surface "$CMUX_LIVE_SURFACE" ctrl+c
    ;;
  close)
    cmux_live_arg_session "$@"
    cmux_live_close_proven || cmux_live_refuse "cmux close-workspace contract"
    cmux_live_load_session "$CMUX_LIVE_SESSION_JSON"
    # Lifecycle identity is the workspace handle; the I/O surface is never
    # substituted for it.
    cmux close-workspace --workspace "$CMUX_LIVE_WORKSPACE"
    ;;
  launch)
    NAME=""; WORKTREE=""; RUNNER=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --name) NAME="$2"; shift 2 ;;
        --worktree) WORKTREE="$2"; shift 2 ;;
        --runner-relative) RUNNER="$2"; shift 2 ;;
        *) exit 2 ;;
      esac
    done
    [ -n "$NAME" ] && [ -n "$WORKTREE" ] && [ -n "$RUNNER" ] || exit 2
    runner_path_allowed "$RUNNER" || exit 2
    create_output="$(cmux workspace create --name "$NAME" --cwd "$WORKTREE" --command "bash $RUNNER")"
    launch_status=$?
    if [ "$launch_status" -ne 0 ]; then
      exit "$launch_status"
    fi
    node "$CMUX_HANDLES" create "$create_output"
    if [ "$?" -ne 0 ]; then
      echo "ERROR: cmux create did not return one provable workspace id/ref" >&2
      exit 2
    fi
    ;;
  inspect)
    if [ "${1:-}" = "--session-json" ]; then
      [ $# -eq 2 ] || exit 2
      [ -f "$2" ] || exit 2
      cmux_live_readscreen_proven || cmux_live_refuse "cmux read-screen surface contract"
      cmux_live_load_session "$2"
      if cmux read-screen --surface "$CMUX_LIVE_SURFACE" >/dev/null 2>&1; then
        adapter_lifecycle_json live "live surface handle is readable"
      else
        adapter_lifecycle_json stale "live surface handle is not readable"
      fi
      exit 0
    fi
    WORKTREE=""; HANDLE=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --worktree) WORKTREE="$2"; shift 2 ;;
        --external-handle) HANDLE="$2"; shift 2 ;;
        *) exit 2 ;;
      esac
    done
    [ -n "$WORKTREE" ] && [ -n "$HANDLE" ] || exit 2
    output="$(cmux workspace list --json 2>/dev/null)" || {
      adapter_handle_unverifiable 'cmux workspace list failed'
      exit 0
    }
    node "$CMUX_HANDLES" inspect "$output" "$HANDLE"
    ;;
  preview)
    NAME=""; WORKTREE=""; RUNNER=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --name) NAME="$2"; shift 2 ;;
        --worktree) WORKTREE="$2"; shift 2 ;;
        --runner-relative) RUNNER="$2"; shift 2 ;;
        *) exit 2 ;;
      esac
    done
    [ -n "$NAME" ] && [ -n "$WORKTREE" ] && [ -n "$RUNNER" ] || exit 2
    echo "cmux workspace create --name \"$NAME\" --cwd \"$WORKTREE\" --command \"bash $RUNNER\""
    ;;
  *) exit 2 ;;
esac
