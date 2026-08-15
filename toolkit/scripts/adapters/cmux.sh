#!/usr/bin/env bash
# cmux transport adapter. Accepts only the typed seat fields below.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/adapter-helpers.sh"
CMUX_HANDLES="$SCRIPT_DIR/../lib/cmux-handles.cjs"

command_name="${1:-}"
shift || true
case "$command_name" in
  capabilities)
    [ "${1:-}" = "--worktree" ] || exit 2
    [ $# -eq 2 ] || exit 2
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
      node "$ADAPTER_JSON" capabilities cmux true available \
        "$(adapter_provenance_version "$version" "$digest")" \
        'workspace.create.cwd,workspace.create.command,workspace.list.read_only'
    else
      node "$ADAPTER_JSON" capabilities cmux false binary_not_found unknown ''
    fi
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
  *) exit 2 ;;
esac
