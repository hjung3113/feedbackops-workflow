#!/usr/bin/env bash
# Herdr transport adapter. It translates the public typed seat seam into one
# inherited-session workspace, root-pane command, and exact workspace probe.
# bash-3.2-compatible: no associative arrays, lowercase expansion, or arrays.
set -u

command_name="${1:-}"
shift || true

adapter_json() {
  reason="$1"
  version="$2"
  available="$3"
  node - "$reason" "$version" "$available" <<'NODE'
const [reason, version, available] = process.argv.slice(2);
process.stdout.write(JSON.stringify({
  adapter: "herdr",
  available: available === "true",
  reason_code: reason,
  version,
  capabilities: available === "true" ? [
    "session.inherited",
    "workspace.create.cwd",
    "workspace.create.label",
    "workspace.create.no_focus",
    "workspace.get.read_only",
    "workspace.close",
    "pane.run"
  ] : []
}) + "\n");
NODE
}

lifecycle_json() {
  lifecycle="$1"
  reason="$2"
  node - "$lifecycle" "$reason" <<'NODE'
const [lifecycle, reason] = process.argv.slice(2);
process.stdout.write(JSON.stringify({ lifecycle, reason }) + "\n");
NODE
}

session_context_available() {
  [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_SOCKET_PATH:-}" ]
}

resolved_herdr_binary() {
  binary="$(command -v herdr 2>/dev/null)" || return 1
  case "$binary" in
    /*) resolved="$binary" ;;
    *) resolved="$(cd "$(dirname "$binary")" 2>/dev/null && pwd -P)/${binary##*/}" || return 1 ;;
  esac
  [ -x "$resolved" ] || return 1
  printf '%s\n' "$resolved"
}

parse_version() {
  raw="$1"
  node - "$raw" <<'NODE'
const raw = (process.argv[2] || "").trim();
const match = /(?:^|\s)v?(\d+\.\d+\.\d+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?)(?=$|\s)/.exec(raw);
if (!match) process.exit(2);
const normalized = match[1];
const main = normalized.split(/[+-]/, 1)[0].split(".").map(Number);
const prerelease = normalized.indexOf("-") >= 0 ? normalized.split("-")[1].split("+")[0] : "";
const floor = [0, 8, 0];
for (let i = 0; i < 3; i++) {
  if (main[i] > floor[i]) break;
  if (main[i] < floor[i]) process.exit(2);
  if (i === 2 && prerelease) process.exit(2);
}
process.stdout.write(normalized);
NODE
}

capabilities() {
  if ! binary="$(resolved_herdr_binary)"; then
    adapter_json binary_not_found unknown false
    return 0
  fi
  if ! session_context_available; then
    adapter_json session_context_missing unknown false
    return 0
  fi

  version_output="$("$binary" --version 2>/dev/null)"
  version_status=$?
  if [ "$version_status" -ne 0 ] || [ -z "$version_output" ]; then
    adapter_json required_capability_missing unknown false
    return 0
  fi
  parsed_version="$(parse_version "$version_output" 2>/dev/null)"
  version_parse_status=$?
  if [ "$version_parse_status" -ne 0 ] || [ -z "$parsed_version" ]; then
    adapter_json required_capability_missing unknown false
    return 0
  fi
  binary_digest="$(node - "$binary" <<'NODE'
const fs = require("fs");
const crypto = require("crypto");
try {
  process.stdout.write(crypto.createHash("sha256").update(fs.readFileSync(process.argv[2])).digest("hex"));
} catch (error) { process.exit(2); }
NODE
  2>/dev/null)"
  if [ "$?" -ne 0 ] || [ -z "$binary_digest" ]; then
    adapter_json required_capability_missing unknown false
    return 0
  fi

  workspace_help="$("$binary" workspace --help 2>&1)"
  workspace_help_status=$?
  if [ "$workspace_help_status" -ne 0 ] \
    || ! printf '%s\n' "$workspace_help" | grep -F -q 'create' \
    || ! printf '%s\n' "$workspace_help" | grep -F -q 'get' \
    || ! printf '%s\n' "$workspace_help" | grep -F -q 'close'; then
    adapter_json required_capability_missing unknown false
    return 0
  fi
  create_help="$("$binary" workspace create --help 2>&1)"
  create_help_status=$?
  if [ "$create_help_status" -ne 0 ] \
    || ! printf '%s\n' "$create_help" | grep -F -q -- '--cwd' \
    || ! printf '%s\n' "$create_help" | grep -F -q -- '--label' \
    || ! printf '%s\n' "$create_help" | grep -F -q -- '--no-focus'; then
    adapter_json required_capability_missing unknown false
    return 0
  fi
  get_help="$("$binary" workspace get --help 2>&1)"
  get_help_status=$?
  close_help="$("$binary" workspace close --help 2>&1)"
  close_help_status=$?
  if [ "$get_help_status" -ne 0 ] || [ "$close_help_status" -ne 0 ]; then
    adapter_json required_capability_missing unknown false
    return 0
  fi
  pane_help="$("$binary" pane --help 2>&1)"
  pane_help_status=$?
  if [ "$pane_help_status" -ne 0 ] || ! printf '%s\n' "$pane_help" | grep -F -q 'run'; then
    adapter_json required_capability_missing unknown false
    return 0
  fi
  pane_run_help="$("$binary" pane run --help 2>&1)"
  pane_run_help_status=$?
  if [ "$pane_run_help_status" -ne 0 ] || ! printf '%s\n' "$pane_run_help" | grep -F -q 'pane run'; then
    adapter_json required_capability_missing unknown false
    return 0
  fi
  list_json="$("$binary" workspace list 2>/dev/null)"
  list_status=$?
  if [ "$list_status" -ne 0 ] || ! node - "$list_json" <<'NODE'
try {
  const value = JSON.parse(process.argv[2] || "");
  if (!value || typeof value !== "object" || Array.isArray(value)
      || !value.result || value.result.type !== "workspace_list"
      || !Array.isArray(value.result.workspaces)) process.exit(2);
} catch (error) { process.exit(2); }
NODE
  then
    adapter_json required_capability_missing unknown false
    return 0
  fi
  adapter_json available "$parsed_version;binary-sha256:$binary_digest" true
  return 0
}

parse_create_result() {
  create_file="$1"
  node - "$create_file" <<'NODE'
const fs = require("fs");
try {
  const value = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  const result = value && value.result;
  const workspace = result && result.workspace;
  const rootPane = result && result.root_pane;
  if (!result || result.type !== "workspace_created"
      || !workspace || typeof workspace.workspace_id !== "string" || !workspace.workspace_id
      || !rootPane || typeof rootPane.pane_id !== "string" || !rootPane.pane_id
      || typeof rootPane.workspace_id !== "string" || !rootPane.workspace_id
      || typeof rootPane.cwd !== "string" || !rootPane.cwd) process.exit(2);
  process.stdout.write([workspace.workspace_id, rootPane.pane_id, rootPane.workspace_id, rootPane.cwd].join("\t"));
} catch (error) { process.exit(2); }
NODE
}

parse_run_error() {
  error_file="$1"
  node - "$error_file" <<'NODE'
const fs = require("fs");
try {
  const value = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  const error = value && value.error;
  if (!error || typeof error !== "object" || Array.isArray(error)
      || typeof error.code !== "string" || !error.code
      || typeof error.message !== "string" || !error.message) process.exit(2);
  process.stdout.write(error.code);
} catch (error) { process.exit(2); }
NODE
}

launch() {
  name=""; worktree=""; runner=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --name)
        [ $# -ge 2 ] || exit 2
        name="$2"; shift 2 ;;
      --worktree)
        [ $# -ge 2 ] || exit 2
        worktree="$2"; shift 2 ;;
      --runner-relative)
        [ $# -ge 2 ] || exit 2
        runner="$2"; shift 2 ;;
      *) exit 2 ;;
    esac
  done
  [ -n "$name" ] && [ -n "$worktree" ] && [ -n "$runner" ] || exit 2
  case "$runner" in .review/ISSUE-*-launch.*/launch.sh) ;; *) exit 2 ;; esac
  if ! session_context_available; then
    echo 'ERROR: session_context_missing' >&2
    exit 2
  fi
  binary="$(resolved_herdr_binary)" || { echo 'ERROR: required_capability_missing: herdr binary is absent' >&2; exit 2; }
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/herdr-adapter.XXXXXX")" || exit 2
  trap 'rm -rf "$temp_dir"' EXIT
  create_stdout="$temp_dir/create.stdout"
  create_stderr="$temp_dir/create.stderr"
  "$binary" workspace create --cwd "$worktree" --label "$name" --no-focus >"$create_stdout" 2>"$create_stderr"
  create_status=$?
  if [ "$create_status" -ne 0 ]; then
    if [ -s "$create_stderr" ]; then cat "$create_stderr" >&2; fi
    exit "$create_status"
  fi
  create_fields="$(parse_create_result "$create_stdout" 2>/dev/null)"
  create_parse_status=$?
  if [ "$create_parse_status" -ne 0 ] || [ -z "$create_fields" ]; then
    echo 'ERROR: Herdr workspace create returned malformed or unprovable JSON' >&2
    exit 2
  fi
  oldIFS="$IFS"
  IFS="$(printf '\t')"
  set -- $create_fields
  IFS="$oldIFS"
  workspace_id="${1:-}"
  pane_id="${2:-}"
  root_workspace_id="${3:-}"
  root_cwd="${4:-}"
  [ "$root_workspace_id" = "$workspace_id" ] || {
    echo 'ERROR: Herdr root pane is not coherent with its created workspace' >&2
    exit 2
  }
  requested_realpath="$(cd "$worktree" 2>/dev/null && pwd -P)" || {
    echo 'ERROR: requested Herdr worktree is not readable' >&2
    exit 2
  }
  returned_realpath="$(cd "$root_cwd" 2>/dev/null && pwd -P)" || {
    echo 'ERROR: Herdr root pane cwd is not readable' >&2
    exit 2
  }
  [ "$returned_realpath" = "$requested_realpath" ] || {
    echo 'ERROR: Herdr root pane cwd does not match the requested worktree' >&2
    exit 2
  }

  run_stdout="$temp_dir/run.stdout"
  run_stderr="$temp_dir/run.stderr"
  run_command="bash $runner"
  "$binary" pane run "$pane_id" "$run_command" >"$run_stdout" 2>"$run_stderr"
  run_status=$?
  if [ "$run_status" -eq 0 ]; then
    node - "$workspace_id" <<'NODE'
const id = process.argv[2];
process.stdout.write(JSON.stringify({ external_handle: id, lifecycle: "launched" }) + "\n");
NODE
    exit 0
  fi
  run_error_code="$(parse_run_error "$run_stderr" 2>/dev/null)"
  run_error_parse_status=$?
  case "$run_error_code" in
    pane_not_found|invalid_key|pane_send_failed)
      if [ "$run_status" -eq 1 ]; then
        "$binary" workspace close "$workspace_id" >"$temp_dir/close.stdout" 2>"$temp_dir/close.stderr" || true
        exit "$run_status"
      fi
      ;;
  esac
  if [ -s "$run_stderr" ]; then cat "$run_stderr" >&2; fi
  node - "$workspace_id" <<'NODE'
const id = process.argv[2];
process.stdout.write(JSON.stringify({ external_handle: id, lifecycle: "command_unconfirmed" }) + "\n");
NODE
  exit "$run_status"
}

parse_inspect_success() {
  inspect_file="$1"
  expected_handle="$2"
  node - "$inspect_file" "$expected_handle" <<'NODE'
const fs = require("fs");
try {
  const value = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  const workspace = value && value.result && value.result.workspace;
  if (!value.result || value.result.type !== "workspace_info"
      || !workspace || workspace.workspace_id !== process.argv[3]) {
    process.stdout.write("mismatch");
    process.exit(0);
  }
  process.stdout.write("live");
} catch (error) {
  process.stdout.write("malformed");
  process.exit(0);
}
NODE
}

parse_inspect_error() {
  error_file="$1"
  node - "$error_file" <<'NODE'
const fs = require("fs");
try {
  const value = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  const error = value && value.error;
  if (!error || typeof error !== "object" || Array.isArray(error)
      || typeof error.code !== "string" || !error.code
      || typeof error.message !== "string" || !error.message) process.exit(2);
  process.stdout.write(error.code);
} catch (error) { process.exit(2); }
NODE
}

inspect() {
  worktree=""; handle=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --worktree)
        [ $# -ge 2 ] || exit 2
        worktree="$2"; shift 2 ;;
      --external-handle)
        [ $# -ge 2 ] || exit 2
        handle="$2"; shift 2 ;;
      *) exit 2 ;;
    esac
  done
  [ -n "$worktree" ] && [ -n "$handle" ] || exit 2
  if ! session_context_available; then
    lifecycle_json handle_unverifiable session_context_missing
    return 0
  fi
  binary="$(resolved_herdr_binary)" || {
    lifecycle_json handle_unverifiable 'herdr binary is absent'
    return 0
  }
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/herdr-adapter.XXXXXX")" || {
    lifecycle_json handle_unverifiable 'workspace handle cannot be verified'
    return 0
  }
  trap 'rm -rf "$temp_dir"' EXIT
  inspect_stdout="$temp_dir/inspect.stdout"
  inspect_stderr="$temp_dir/inspect.stderr"
  "$binary" workspace get "$handle" >"$inspect_stdout" 2>"$inspect_stderr"
  inspect_status=$?
  if [ "$inspect_status" -eq 0 ]; then
    inspect_result="$(parse_inspect_success "$inspect_stdout" "$handle" 2>/dev/null)"
    if [ "$inspect_result" = "live" ]; then
      lifecycle_json live 'exact workspace handle is present'
    elif [ "$inspect_result" = "malformed" ]; then
      lifecycle_json handle_unverifiable 'workspace response is malformed'
    else
      lifecycle_json handle_unverifiable 'workspace handle identity is mismatched'
    fi
    return 0
  fi
  inspect_error_code="$(parse_inspect_error "$inspect_stderr" 2>/dev/null)"
  if [ "$inspect_status" -eq 1 ] && [ "$inspect_error_code" = "workspace_not_found" ]; then
    lifecycle_json stale 'workspace handle is not found'
  else
    lifecycle_json handle_unverifiable 'workspace handle cannot be verified'
  fi
  return 0
}

case "$command_name" in
  capabilities)
    [ "${1:-}" = "--worktree" ] && [ $# -eq 2 ] || exit 2
    capabilities "$2"
    ;;
  launch)
    launch "$@"
    ;;
  inspect)
    inspect "$@"
    ;;
  *) exit 2 ;;
esac
