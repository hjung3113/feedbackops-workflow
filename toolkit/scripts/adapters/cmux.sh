#!/usr/bin/env bash
# cmux transport adapter. Accepts only the typed seat fields below.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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
      workspace_help="$(cmux workspace create --help 2>&1)"
      workspace_help_status=$?
      launch_flags_proven=false
      if printf '%s\n' "$workspace_help" | grep -F -q -- '--cwd' \
        && printf '%s\n' "$workspace_help" | grep -F -q -- '--command'; then
        launch_flags_proven=true
      elif printf '%s\n' "$workspace_help" | grep -F 'new-workspace' | grep -F 'same' | grep -F -q 'create'; then
        # An explicit delegation claim is only proof when the delegated
        # surface itself lists both launch flags.
        delegation_help="$(cmux new-workspace --help 2>&1)"
        if printf '%s\n' "$delegation_help" | grep -F -q -- '--cwd' \
          && printf '%s\n' "$delegation_help" | grep -F -q -- '--command'; then
          launch_flags_proven=true
        fi
      fi
      if [ "$workspace_help_status" -ne 0 ] || [ "$launch_flags_proven" != "true" ] \
        || ! node - "$version" <<'NODE'
const match = /(?:^|\s)(\d+)\.(\d+)\.(\d+)(?:\s|$)/.exec(process.argv[2] || "");
if (!match) process.exit(1);
const actual = match.slice(1).map(Number);
const floor = [0, 64, 0];
for (let i = 0; i < 3; i++) {
  if (actual[i] > floor[i]) process.exit(0);
  if (actual[i] < floor[i]) process.exit(1);
}
NODE
      then
        printf '{"adapter":"cmux","available":false,"reason_code":"required_capability_missing","version":"unknown","capabilities":[]}\n'
        exit 0
      fi
      node - "$version" "$digest" <<'NODE'
process.stdout.write(JSON.stringify({
  adapter: "cmux", available: true, reason_code: "available",
  version: `${process.argv[2]};binary-sha256:${process.argv[3]}`,
  capabilities: ["workspace.create.cwd", "workspace.create.command", "workspace.list.read_only"]
}) + "\n");
NODE
    else
      printf '{"adapter":"cmux","available":false,"reason_code":"binary_not_found","version":"unknown","capabilities":[]}\n'
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
    case "$RUNNER" in .review/ISSUE-*-launch.*/launch.sh) ;; *) exit 2 ;; esac
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
      printf '{"lifecycle":"handle_unverifiable","reason":"cmux workspace list failed"}\n'
      exit 0
    }
    node "$CMUX_HANDLES" inspect "$output" "$HANDLE"
    ;;
  *) exit 2 ;;
esac
