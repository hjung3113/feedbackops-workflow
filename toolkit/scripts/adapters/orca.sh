#!/usr/bin/env bash
# Orca transport adapter. It opens one fresh bare-shell terminal in the exact
# existing worktree and starts only the common launch runner.
set -u

command_name="${1:-}"
shift || true
capability_json() {
  worktree="$1"
  if ! command -v orca >/dev/null 2>&1; then
    printf '{"adapter":"orca","available":false,"reason_code":"binary_not_found","version":"unknown","capabilities":[]}\n'
    return
  fi
  help="$(orca terminal create --help 2>&1)"
  for flag in '--worktree' '--title' '--command' '--json'; do
    if ! printf '%s\n' "$help" | grep -F -q -- "$flag"; then
      printf '{"adapter":"orca","available":false,"reason_code":"required_capability_missing","version":"unknown","capabilities":[]}\n'
      return
    fi
  done
  list_help="$(orca terminal list --help 2>&1)"
  for flag in '--worktree' '--json'; do
    if ! printf '%s\n' "$list_help" | grep -F -q -- "$flag"; then
      printf '{"adapter":"orca","available":false,"reason_code":"required_capability_missing","version":"unknown","capabilities":[]}\n'
      return
    fi
  done
  status_json="$(orca status --json 2>/dev/null)"
  version="$(node - "$status_json" <<'NODE'
try {
  const value = JSON.parse(process.argv[2]);
  const version = value && value.result && value.result.runtime && value.result.runtime.appVersion;
  if (typeof version !== "string" || version !== version.trim()
    || !/^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/.test(version)) process.exit(1);
  process.stdout.write(version);
} catch (error) {
  process.exit(1);
}
NODE
  )"
  [ -n "$version" ] || version="unknown"
  node - "$version" <<'NODE'
process.stdout.write(JSON.stringify({
  adapter: "orca", available: true, reason_code: "available",
  version: process.argv[2],
  capabilities: ["terminal.create.worktree_path", "terminal.create.title", "terminal.create.command", "terminal.create.json", "terminal.list.read_only"]
}) + "\n");
NODE
}

normalize_handle_json() {
  mode="$1"
  json="$2"
  expected="${3:-}"
  node - "$mode" "$json" "$expected" <<'NODE'
const [mode, json, expected] = process.argv.slice(2);
try {
  const value = JSON.parse(json);
  if (mode === "launch") {
    const terminal = value && value.result && value.result.terminal;
    if (!terminal || typeof terminal !== "object" || Array.isArray(terminal)
      || typeof terminal.handle !== "string" || !terminal.handle.length) process.exit(2);
    process.stdout.write(JSON.stringify({ external_handle: terminal.handle, lifecycle: "launched" }) + "\n");
  } else if (mode === "inspect") {
    const terminals = value && value.result && Array.isArray(value.result.terminals) ? value.result.terminals : null;
    if (!terminals) throw new Error("missing terminals");
    const seen = new Set(terminals
      .filter((terminal) => terminal && typeof terminal === "object" && !Array.isArray(terminal))
      .map((terminal) => terminal.handle)
      .filter((handle) => typeof handle === "string" && handle.length));
    process.stdout.write(JSON.stringify(seen.has(expected)
      ? { lifecycle: "live", reason: "external terminal handle is present" }
      : { lifecycle: "stale", reason: "external terminal handle is absent" }) + "\n");
  } else process.exit(2);
} catch (error) {
  if (mode !== "inspect") process.exit(2);
  process.stdout.write(JSON.stringify({ lifecycle: "handle_unverifiable", reason: "Orca terminal list returned invalid JSON" }) + "\n");
}
NODE
}

case "$command_name" in
  capabilities)
    [ "${1:-}" = "--worktree" ] || exit 2
    [ $# -eq 2 ] || exit 2
    capability_json "$2"
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
    output="$(orca terminal create --worktree "path:$WORKTREE" --title "$NAME" --command "bash $RUNNER" --json)" || exit $?
    normalize_handle_json launch "$output"
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
    output="$(orca terminal list --worktree "path:$WORKTREE" --json 2>/dev/null)" || {
      printf '{"lifecycle":"handle_unverifiable","reason":"Orca terminal list failed"}\n'
      exit 0
    }
    normalize_handle_json inspect "$output" "$HANDLE"
    ;;
  *) exit 2 ;;
esac
