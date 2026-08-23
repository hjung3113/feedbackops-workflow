#!/usr/bin/env bash
# Herdr transport adapter. It translates the public typed seat seam into one
# inherited-session workspace, root-pane command, and exact workspace probe.
# Live sessions use the agent facade (start/prompt/wait/read/send-keys), not
# `pane run`; pane run stays the headless runner and generic-shell fallback.
# bash-3.2-compatible: no associative arrays, lowercase expansion, or arrays.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/adapter-helpers.sh"

command_name="${1:-}"
shift || true

# Headless capability vocabulary (workspace + pane facade).
HERDR_HEADLESS_CAPABILITIES='session.inherited,workspace.create.cwd,workspace.create.label,workspace.create.no_focus,workspace.get.read_only,workspace.close,pane.run'
# Agent-facade evidence appended to the headless set when the full live
# contract (help tokens + trust-race acceptance test) is proven.
HERDR_LIVE_AGENT_CAPABILITIES='agent.start,agent.prompt_wait,agent.read_recent,agent.wait_state,agent.send_keys'
# Live session tuning. These are adapter-internal bounds; the supervisor's
# LIVE_* timeouts own the caller-facing budgets.
HERDR_LIVE_READ_LINES=200
HERDR_LIVE_SEND_WAIT_MS=15000
HERDR_LIVE_TRUST_WAIT_MS=8000
HERDR_LIVE_START_TIMEOUT_MS=120000
# The trust-race sentinel is launched through `pane run` as a manually
# started agent, so its executable basename must be a herdr-supported agent
# kind for lifecycle classification. This is herdr vendor vocabulary for the
# documented trust-prompt race (herdrdev/herdr#2410), not a dispatch branch
# on a workflow runtime name.
HERDR_TRUST_PROBE_KIND='codex'

adapter_json() {
  reason="$1"
  version="$2"
  available="$3"
  if [ "$available" = "true" ]; then
    node "$ADAPTER_JSON" capabilities herdr true available "$version" \
      "${4:-$HERDR_HEADLESS_CAPABILITIES}" \
      'command_unconfirmed'
  else
    node "$ADAPTER_JSON" capabilities herdr false "$reason" unknown ''
  fi
}

# Real Herdr's own `herdr --skill` contract only documents HERDR_ENV plus the
# workspace/tab/pane identity vars; HERDR_SOCKET_PATH is not part of it and is
# never set on a genuine Herdr-managed pane.
session_context_available() {
  [ "${HERDR_ENV:-}" = "1" ] \
    && [ -n "${HERDR_WORKSPACE_ID:-}" ] \
    && [ -n "${HERDR_TAB_ID:-}" ] \
    && [ -n "${HERDR_PANE_ID:-}" ]
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

# Extract .result.agent.agent_status from a successful agent JSON response
# (herdr's `agent get` / `agent wait` put the lifecycle state there).
parse_agent_state() {
  agent_file="$1"
  node - "$agent_file" <<'NODE'
const fs = require("fs");
try {
  const value = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  const agent = value && value.result && value.result.agent;
  if (!agent || typeof agent !== "object" || typeof agent.agent_status !== "string" || !agent.agent_status) process.exit(2);
  process.stdout.write(agent.agent_status);
} catch (error) { process.exit(2); }
NODE
}

# Help-token contract for the agent facade. One missing token means only the
# live capability is unavailable; the headless contract above is untouched.
agent_facade_help_proven() {
  facade_binary="$1"
  agent_help="$("$facade_binary" agent --help 2>&1)" || return 1
  for facade_token in start prompt wait read send-keys get; do
    help_has "$agent_help" "$facade_token" || return 1
  done
  start_help="$("$facade_binary" agent start --help 2>&1)" || return 1
  for facade_token in --kind --pane --timeout --; do
    help_has "$start_help" "$facade_token" || return 1
  done
  prompt_help="$("$facade_binary" agent prompt --help 2>&1)" || return 1
  for facade_token in --wait --timeout; do
    help_has "$prompt_help" "$facade_token" || return 1
  done
  wait_help="$("$facade_binary" agent wait --help 2>&1)" || return 1
  for facade_token in --until --timeout; do
    help_has "$wait_help" "$facade_token" || return 1
  done
  read_help="$("$facade_binary" agent read --help 2>&1)" || return 1
  for facade_token in --source --lines; do
    help_has "$read_help" "$facade_token" || return 1
  done
  send_keys_help="$("$facade_binary" agent send-keys --help 2>&1)" || return 1
  help_has "$send_keys_help" 'esc' || return 1
  return 0
}

# Fresh/untrusted-worktree trust-prompt race acceptance test (design #203
# Herdr, herdrdev/herdr#2410). herdr 0.8.0-era builds reported
# interactive-ready while a first-run trust prompt was still blocking, so a
# prompt sent after `agent start` could be eaten by the trust dialog. The
# fixed contract makes a trust-prompt-blocked agent discoverable as
# `blocked`. This probe launches a sentinel that renders a trust-prompt
# screen in a never-trusted temp worktree and requires herdr itself to
# classify it as blocked; anything else (idle, unknown, timeout, error)
# means the race is unhandled or unprovable, so live stays unavailable.
# Note (#215): for codex launches the trust prompt is prevented upstream by
# the codex runtime member itself, which pre-seeds codex's own
# per-directory trust store while emitting the launch spec (see
# lib/codex-policy.sh), so live codex capability does not depend on this
# probe for the trust case. The probe still guards the general
# blocked-classification contract herdr must honor for any other blocking
# UI (approval prompts, other vendors' dialogs).
herdr_trust_race_proven() {
  trust_binary="$1"
  trust_root="$(mktemp -d "${TMPDIR:-/tmp}/herdr-trust-probe.XXXXXX")" || return 1
  trust_workspace=""
  herdr_trust_cleanup() {
    if [ -n "$trust_workspace" ]; then
      "$trust_binary" workspace close "$trust_workspace" >/dev/null 2>&1 || true
    fi
    rm -rf "$trust_root"
  }
  trust_dir="$trust_root/agent-workflow-trust-probe"
  mkdir -p "$trust_dir" || { rm -rf "$trust_root"; return 1; }
  trust_sentinel="$trust_dir/$HERDR_TRUST_PROBE_KIND"
  cat > "$trust_sentinel" <<'SENTINEL'
#!/usr/bin/env bash
# agent-workflow herdr trust-race probe sentinel. Renders a first-run
# directory trust prompt and blocks, exactly the screen state that must be
# classified as a blocked agent rather than interactive-ready.
printf '%s\n' 'Do you trust the files in this folder?'
printf '%s\n' 'Do you trust the contents of this directory?'
printf '%s\n' '1. Yes, proceed with the session  2. No, exit'
sleep 120
SENTINEL
  chmod +x "$trust_sentinel" || { rm -rf "$trust_root"; return 1; }
  trust_stdout="$trust_root/.create.stdout"
  trust_stderr="$trust_root/.create.stderr"
  "$trust_binary" workspace create --cwd "$trust_root" --label agent-workflow-trust-probe --no-focus >"$trust_stdout" 2>"$trust_stderr" || {
    herdr_trust_cleanup
    return 1
  }
  trust_fields="$(parse_create_result "$trust_stdout" 2>/dev/null)" || {
    herdr_trust_cleanup
    return 1
  }
  trust_oldIFS="$IFS"
  IFS="$(printf '\t')"
  set -- $trust_fields
  IFS="$trust_oldIFS"
  trust_workspace="${1:-}"
  trust_pane="${2:-}"
  if [ -z "$trust_workspace" ] || [ -z "$trust_pane" ]; then
    trust_workspace=""
    herdr_trust_cleanup
    return 1
  fi
  "$trust_binary" pane run "$trust_pane" "'$trust_sentinel' --trust-probe" >/dev/null 2>&1 || {
    herdr_trust_cleanup
    return 1
  }
  trust_wait_out="$trust_root/.wait.stdout"
  trust_wait_err="$trust_root/.wait.stderr"
  "$trust_binary" agent wait "$trust_pane" --until blocked --timeout "$HERDR_LIVE_TRUST_WAIT_MS" >"$trust_wait_out" 2>"$trust_wait_err"
  trust_wait_status=$?
  if [ "$trust_wait_status" -eq 0 ] \
    && trust_state="$(parse_agent_state "$trust_wait_out" 2>/dev/null)" \
    && [ "$trust_state" = "blocked" ]; then
    herdr_trust_cleanup
    return 0
  fi
  herdr_trust_cleanup
  return 1
}

capabilities() {
  cap_probe_live="${2:-false}"
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
  parsed_version="$(node "$ADAPTER_SEMVER" parse-floor "$version_output" 0.8.0 2>/dev/null)"
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
    || ! help_has "$workspace_help" 'create' \
    || ! help_has "$workspace_help" 'get' \
    || ! help_has "$workspace_help" 'close'; then
    adapter_json required_capability_missing unknown false
    return 0
  fi
  create_help="$("$binary" workspace create --help 2>&1)"
  create_help_status=$?
  if [ "$create_help_status" -ne 0 ] \
    || ! help_has "$create_help" '--cwd' \
    || ! help_has "$create_help" '--label' \
    || ! help_has "$create_help" '--no-focus'; then
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
  if [ "$pane_help_status" -ne 0 ] || ! help_has "$pane_help" 'run'; then
    adapter_json required_capability_missing unknown false
    return 0
  fi
  pane_run_help="$("$binary" pane run --help 2>&1)"
  pane_run_help_status=$?
  if [ "$pane_run_help_status" -ne 0 ] || ! help_has "$pane_run_help" 'pane run'; then
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
  # Live admission is proven separately and fails closed: the agent-facade
  # help tokens plus the trust-race acceptance test must both pass before the
  # semantic session capabilities are offered. A missing token or an
  # unproven race leaves this payload headless-only; callers refuse live
  # dispatch on the missing capabilities instead of silently falling back.
  # The trust-race test itself creates and closes a real workspace, so it
  # only runs under an explicit live-intent probe (--probe-live) — a plain
  # headless capability check must stay side-effect-free.
  live_csv=""
  if [ "$cap_probe_live" = "true" ] && agent_facade_help_proven "$binary" && herdr_trust_race_proven "$binary"; then
    live_csv="$(node "$ADAPTER_TRANSPORT_REGISTRY" live-capabilities | tr '\n' ',' | sed 's/,$//')"
    live_csv="$live_csv,$HERDR_LIVE_AGENT_CAPABILITIES"
  fi
  adapter_json available "$(adapter_provenance_version "$parsed_version" "$binary_digest")" true "$HERDR_HEADLESS_CAPABILITIES${live_csv:+,$live_csv}"
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

# Shared {error:{code,message}} parser for adapter command stderr.
parse_adapter_error() {
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
  runner_path_allowed "$runner" || exit 2
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
  run_error_code="$(parse_adapter_error "$run_stderr" 2>/dev/null)"
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

# --- Live session path (agent facade) -------------------------------------

# Validate a herdr agent name ([a-z][a-z0-9_-]{0,31}) without bash 3.2
# quantifier globs.
herdr_agent_name_valid() {
  case "$1" in
    ''|*[!a-z0-9_-]*) return 1 ;;
  esac
  case "$1" in
    [a-z]*) ;;
    *) return 1 ;;
  esac
  [ "${#1}" -le 32 ] || return 1
  return 0
}

# Load the supervisor-owned session.json and emit
# workspace<TAB>pane<TAB>agent from the structured handles.
live_session_fields() {
  live_session_file="$1"
  node - "$live_session_file" <<'NODE'
const fs = require("fs");
try {
  const value = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  const handles = value && value.handles;
  if (!value || value.adapter !== "herdr" || value.execution_mode !== "live-tui"
      || !handles || typeof handles !== "object"
      || typeof handles.lifecycle !== "string" || !handles.lifecycle
      || typeof handles.io !== "string" || !handles.io
      || typeof handles.agent !== "string" || !handles.agent) process.exit(2);
  process.stdout.write([handles.lifecycle, handles.io, handles.agent].join("\t"));
} catch (error) { process.exit(2); }
NODE
}

# Parse + strictly validate a runtime launch-spec. Argv and env entries are
# written NUL-delimited so the caller can forward every token without any
# shell re-parsing; stdout is runtime<TAB>cwd.
live_parse_launch_spec() {
  spec_file="$1"
  spec_argv_file="$2"
  spec_env_file="$3"
  node - "$spec_file" "$spec_argv_file" "$spec_env_file" "$ADAPTER_LIB_DIR/launch-spec.cjs" <<'NODE'
const fs = require("fs");
const [specFile, argvFile, envFile, launchSpecModule] = process.argv.slice(2);
const { normalizeLaunchSpec } = require(launchSpecModule);
let normalized;
try {
  normalized = normalizeLaunchSpec(JSON.parse(fs.readFileSync(specFile, "utf8")));
} catch (error) { process.exit(2); }
if (!normalized) process.exit(2);
fs.writeFileSync(argvFile, normalized.argv.map(entry => entry + "\0").join(""));
fs.writeFileSync(envFile, Object.keys(normalized.env).sort()
  .map(key => key + "=" + normalized.env[key] + "\0").join(""));
process.stdout.write(normalized.runtime + "\t" + normalized.cwd);
NODE
}

live_handles_json() {
  node - "$1" "$2" "$3" <<'NODE'
const value = { lifecycle: process.argv[2], io: process.argv[3], agent: process.argv[4] };
if (Object.keys(value).some(key => typeof value[key] !== "string" || !value[key])) process.exit(2);
process.stdout.write(JSON.stringify(value));
NODE
}


# launch-live: workspace create -> root pane -> agent start. The --kind value
# is the launch-spec runtime field forwarded as data; this file never
# branches on a runtime name. Runtime-owned launch preparation (such as
# codex's trust-store pre-seed, #215) happens through the generic per-runtime
# `pre-launch` command below, once at the real launch — never at
# dispatch-core's side-effect-free launch-spec preflight.
launch_live() {
  live_name=""; live_worktree=""; live_spec_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --name)
        [ $# -ge 2 ] || exit 2
        live_name="$2"; shift 2 ;;
      --worktree)
        [ $# -ge 2 ] || exit 2
        live_worktree="$2"; shift 2 ;;
      --launch-spec)
        [ $# -ge 2 ] || exit 2
        live_spec_file="$2"; shift 2 ;;
      *) exit 2 ;;
    esac
  done
  [ -n "$live_name" ] && [ -n "$live_worktree" ] && [ -n "$live_spec_file" ] || exit 2
  [ -f "$live_spec_file" ] || exit 2
  herdr_agent_name_valid "$live_name" || {
    echo 'ERROR: herdr_agent_name_invalid' >&2
    exit 2
  }
  if ! session_context_available; then
    echo 'ERROR: session_context_missing' >&2
    exit 2
  fi
  binary="$(resolved_herdr_binary)" || { echo 'ERROR: required_capability_missing: herdr binary is absent' >&2; exit 2; }
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/herdr-adapter.XXXXXX")" || exit 2
  trap 'rm -rf "$temp_dir"' EXIT
  spec_fields="$(live_parse_launch_spec "$live_spec_file" "$temp_dir/spec.argv" "$temp_dir/spec.env")" || {
    echo 'ERROR: herdr_launch_spec_invalid' >&2
    exit 2
  }
  spec_oldIFS="$IFS"
  IFS="$(printf '\t')"
  set -- $spec_fields
  IFS="$spec_oldIFS"
  spec_runtime="${1:-}"
  spec_cwd="${2:-}"
  [ -n "$spec_runtime" ] && [ -n "$spec_cwd" ] || { echo 'ERROR: herdr_launch_spec_invalid' >&2; exit 2; }
  live_worktree_real="$(cd "$live_worktree" 2>/dev/null && pwd -P)" || {
    echo 'ERROR: requested Herdr worktree is not readable' >&2
    exit 2
  }
  spec_cwd_real="$(cd "$spec_cwd" 2>/dev/null && pwd -P)" || {
    echo 'ERROR: launch-spec cwd is not readable' >&2
    exit 2
  }
  [ "$spec_cwd_real" = "$live_worktree_real" ] || {
    echo 'ERROR: herdr_launch_spec_worktree_mismatch' >&2
    exit 2
  }

  # Runtime-owned launch preparation (#215/#218): dispatch-core treats
  # launch-spec as a side-effect-free preflight, so mutations like codex's
  # trust-store pre-seed belong here — once, at the real launch, immediately
  # before the workspace/agent is started. Called generically per runtime
  # (same seam as launch-spec/probe/run); this file never branches on a
  # runtime name. Runtimes without launch preparation (or unknown --kind
  # values) have no executable member script and are skipped.
  case "$spec_runtime" in
    */*|*..*) echo 'ERROR: herdr_launch_spec_invalid' >&2; exit 2 ;;
  esac
  runtime_pre_launch="$SCRIPT_DIR/../runtimes/$spec_runtime.sh"
  if [ -x "$runtime_pre_launch" ]; then
    "$runtime_pre_launch" pre-launch --cwd "$spec_cwd_real" || {
      echo 'ERROR: runtime_pre_launch_failed' >&2
      exit 2
    }
  fi
  if [ -s "$temp_dir/spec.env" ]; then
    env_start_help="$("$binary" agent start --help 2>&1)" \
      && help_has "$env_start_help" '--env' || {
        echo 'ERROR: herdr_agent_env_unsupported' >&2
        exit 2
      }
  fi

  create_stdout="$temp_dir/create.stdout"
  create_stderr="$temp_dir/create.stderr"
  "$binary" workspace create --cwd "$live_worktree" --label "$live_name" --no-focus >"$create_stdout" 2>"$create_stderr"
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
    "$binary" workspace close "$workspace_id" >"$temp_dir/close.stdout" 2>"$temp_dir/close.stderr" || true
    exit 2
  }
  requested_realpath="$(cd "$live_worktree" 2>/dev/null && pwd -P)" || {
    echo 'ERROR: requested Herdr worktree is not readable' >&2
    "$binary" workspace close "$workspace_id" >"$temp_dir/close.stdout" 2>"$temp_dir/close.stderr" || true
    exit 2
  }
  returned_realpath="$(cd "$root_cwd" 2>/dev/null && pwd -P)" || {
    echo 'ERROR: Herdr root pane cwd is not readable' >&2
    "$binary" workspace close "$workspace_id" >"$temp_dir/close.stdout" 2>"$temp_dir/close.stderr" || true
    exit 2
  }
  [ "$returned_realpath" = "$requested_realpath" ] || {
    echo 'ERROR: Herdr root pane cwd does not match the requested worktree' >&2
    "$binary" workspace close "$workspace_id" >"$temp_dir/close.stdout" 2>"$temp_dir/close.stderr" || true
    exit 2
  }

  set -- agent start "$live_name" --kind "$spec_runtime" --pane "$pane_id" --timeout "$HERDR_LIVE_START_TIMEOUT_MS"
  while IFS= read -r -d '' spec_env_pair; do
    set -- "$@" --env "$spec_env_pair"
  done < "$temp_dir/spec.env"
  set -- "$@" --
  while IFS= read -r -d '' spec_argv_token; do
    set -- "$@" "$spec_argv_token"
  done < "$temp_dir/spec.argv"
  start_stdout="$temp_dir/start.stdout"
  start_stderr="$temp_dir/start.stderr"
  "$binary" "$@" >"$start_stdout" 2>"$start_stderr"
  start_status=$?
  if [ "$start_status" -eq 0 ]; then
    # agent start exit 0 alone is never readiness proof (trust-prompt race);
    # wait-ready verifies lifecycle before any prompt is sent.
    live_handles="$(live_handles_json "$workspace_id" "$pane_id" "$live_name")" || exit 2
    adapter_session_json launched "$live_handles" "$workspace_id"
    exit 0
  fi
  if [ -s "$start_stderr" ]; then cat "$start_stderr" >&2; fi
  "$binary" workspace close "$workspace_id" >"$temp_dir/close.stdout" 2>"$temp_dir/close.stderr" || true
  exit "$start_status"
}

live_load_session() {
  live_session_json="$1"
  live_fields="$(live_session_fields "$live_session_json")" || {
    echo 'ERROR: herdr_session_json_invalid' >&2
    exit 2
  }
  live_oldIFS="$IFS"
  IFS="$(printf '\t')"
  set -- $live_fields
  IFS="$live_oldIFS"
  sess_workspace="${1:-}"
  sess_pane="${2:-}"
  sess_agent="${3:-}"
  [ -n "$sess_workspace" ] && [ -n "$sess_pane" ] && [ -n "$sess_agent" ] || {
    echo 'ERROR: herdr_session_json_invalid' >&2
    exit 2
  }
}

live_require_context() {
  session_context_available || {
    echo 'ERROR: session_context_missing' >&2
    exit 2
  }
  binary="$(resolved_herdr_binary)" || { echo 'ERROR: required_capability_missing: herdr binary is absent' >&2; exit 2; }
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/herdr-adapter.XXXXXX")" || exit 2
  trap 'rm -rf "$temp_dir"' EXIT
}

# wait-ready never trusts `agent start` exit 0. Readiness is herdr's own
# lifecycle answer, and a blocked agent (first-run trust prompt or approval
# UI) is a typed refusal, never a send target.
wait_ready() {
  wait_session=""; wait_timeout=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --session-json)
        [ $# -ge 2 ] || exit 2
        wait_session="$2"; shift 2 ;;
      --timeout-ms)
        [ $# -ge 2 ] || exit 2
        wait_timeout="$2"; shift 2 ;;
      *) exit 2 ;;
    esac
  done
  [ -n "$wait_session" ] && [ -f "$wait_session" ] || exit 2
  case "$wait_timeout" in ''|*[!0-9]*) exit 2 ;; esac
  [ "$wait_timeout" -gt 0 ] || exit 2
  live_require_context
  live_load_session "$wait_session"
  wait_stdout="$temp_dir/wait.stdout"
  wait_stderr="$temp_dir/wait.stderr"
  "$binary" agent wait "$sess_agent" --until idle --until blocked --timeout "$wait_timeout" >"$wait_stdout" 2>"$wait_stderr"
  wait_status=$?
  if [ "$wait_status" -eq 0 ]; then
    wait_state="$(parse_agent_state "$wait_stdout" 2>/dev/null)" || {
      echo 'ERROR: herdr_agent_ready_state_invalid' >&2
      exit 1
    }
    if [ "$wait_state" = "idle" ]; then
      exit 0
    fi
    if [ "$wait_state" = "blocked" ]; then
      echo 'ERROR: herdr_agent_blocked_before_ready' >&2
      exit 1
    fi
    echo 'ERROR: herdr_agent_ready_state_invalid' >&2
    exit 1
  fi
  wait_code="$(parse_adapter_error "$wait_stderr" 2>/dev/null)"
  echo "ERROR: herdr_agent_not_ready:${wait_code:-timeout}" >&2
  exit 1
}

# send = `agent prompt --wait`. herdr's native agent_prompt_stalled (no
# lifecycle change within its own window after an ineffective submit) is the
# stall authority; this function never re-sends the prompt body.
send_live() {
  send_session=""; send_input=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --session-json)
        [ $# -ge 2 ] || exit 2
        send_session="$2"; shift 2 ;;
      --input-file)
        [ $# -ge 2 ] || exit 2
        send_input="$2"; shift 2 ;;
      *) exit 2 ;;
    esac
  done
  [ -n "$send_session" ] && [ -f "$send_session" ] || exit 2
  [ -n "$send_input" ] && [ -f "$send_input" ] || exit 2
  prompt_body="$(cat "$send_input")" || exit 2
  [ -n "$prompt_body" ] || {
    echo 'ERROR: herdr_prompt_body_empty' >&2
    exit 2
  }
  live_require_context
  live_load_session "$send_session"
  send_stdout="$temp_dir/prompt.stdout"
  send_stderr="$temp_dir/prompt.stderr"
  "$binary" agent prompt "$sess_agent" "$prompt_body" --wait --timeout "$HERDR_LIVE_SEND_WAIT_MS" >"$send_stdout" 2>"$send_stderr"
  send_status=$?
  [ "$send_status" -eq 0 ] && exit 0
  send_code="$(parse_adapter_error "$send_stderr" 2>/dev/null)"
  case "$send_code" in
    agent_prompt_stalled)
      echo 'ERROR: herdr_agent_prompt_stalled' >&2
      exit 1
      ;;
    agent_not_running)
      echo 'ERROR: herdr_agent_not_running' >&2
      exit 1
      ;;
    timeout)
      # The bounded wait expired mid-turn. Confirm the turn actually started;
      # an ambiguous picture is left to the supervisor's activity gate, which
      # fails closed without ever re-sending the prompt body.
      "$binary" agent get "$sess_agent" >"$temp_dir/get.stdout" 2>"$temp_dir/get.stderr"
      get_status=$?
      if [ "$get_status" -eq 0 ]; then
        get_state="$(parse_agent_state "$temp_dir/get.stdout" 2>/dev/null)" || get_state=""
        case "$get_state" in
          working|blocked|idle|done|unknown) exit 0 ;;
        esac
      fi
      echo 'ERROR: herdr_agent_send_unconfirmed' >&2
      exit 1
      ;;
    *)
      if [ -s "$send_stderr" ]; then cat "$send_stderr" >&2; fi
      echo "ERROR: herdr_agent_prompt_failed:${send_code:-unparsed}" >&2
      exit 1
      ;;
  esac
}

# read returns a deterministic JSON envelope (no volatile cursor/timestamp
# fields) so the supervisor's byte-diff observes real screen change only.
read_live() {
  read_session=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --session-json)
        [ $# -ge 2 ] || exit 2
        read_session="$2"; shift 2 ;;
      *) exit 2 ;;
    esac
  done
  [ -n "$read_session" ] && [ -f "$read_session" ] || exit 2
  live_require_context
  live_load_session "$read_session"
  "$binary" agent read "$sess_agent" --source recent-unwrapped --lines "$HERDR_LIVE_READ_LINES" >"$temp_dir/read.raw" 2>"$temp_dir/read.stderr"
  read_status=$?
  if [ "$read_status" -ne 0 ]; then
    if [ -s "$temp_dir/read.stderr" ]; then cat "$temp_dir/read.stderr" >&2; fi
    exit 1
  fi
  node - "$temp_dir/read.raw" "$HERDR_LIVE_READ_LINES" <<'NODE'
const fs = require("fs");
const text = fs.readFileSync(process.argv[2], "utf8");
process.stdout.write(JSON.stringify({
  adapter: "herdr",
  source: "recent-unwrapped",
  lines: Number(process.argv[3]),
  text,
}) + "\n");
NODE
}

# wait-settled maps herdr's native lifecycle vocabulary onto the shared
# settled|working|blocked|stale|terminal enum; unknown is never success
# evidence.
wait_settled() {
  settled_session=""; settled_timeout=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --session-json)
        [ $# -ge 2 ] || exit 2
        settled_session="$2"; shift 2 ;;
      --timeout-ms)
        [ $# -ge 2 ] || exit 2
        settled_timeout="$2"; shift 2 ;;
      *) exit 2 ;;
    esac
  done
  [ -n "$settled_session" ] && [ -f "$settled_session" ] || exit 2
  case "$settled_timeout" in ''|*[!0-9]*) exit 2 ;; esac
  [ "$settled_timeout" -gt 0 ] || exit 2
  live_require_context
  live_load_session "$settled_session"
  settled_stdout="$temp_dir/settled.stdout"
  settled_stderr="$temp_dir/settled.stderr"
  "$binary" agent wait "$sess_agent" --until idle --until done --until blocked --timeout "$settled_timeout" >"$settled_stdout" 2>"$settled_stderr"
  settled_status=$?
  if [ "$settled_status" -eq 0 ]; then
    settled_state="$(parse_agent_state "$settled_stdout" 2>/dev/null)" || {
      echo 'ERROR: herdr_settled_state_invalid' >&2
      exit 1
    }
    case "$settled_state" in
      idle|done) printf '{"state":"settled"}\n'; exit 0 ;;
      blocked) printf '{"state":"blocked"}\n'; exit 0 ;;
      *) echo 'ERROR: herdr_settled_state_invalid' >&2; exit 1 ;;
    esac
  fi
  settled_code="$(parse_adapter_error "$settled_stderr" 2>/dev/null)"
  case "$settled_code" in
    agent_not_running)
      printf '{"state":"terminal"}\n'
      exit 0
      ;;
    timeout)
      "$binary" agent get "$sess_agent" >"$temp_dir/settled-get.stdout" 2>"$temp_dir/settled-get.stderr"
      get_status=$?
      if [ "$get_status" -eq 0 ] && settled_get_state="$(parse_agent_state "$temp_dir/settled-get.stdout" 2>/dev/null)"; then
        case "$settled_get_state" in
          working) printf '{"state":"working"}\n'; exit 0 ;;
          blocked) printf '{"state":"blocked"}\n'; exit 0 ;;
          idle|done) printf '{"state":"settled"}\n'; exit 0 ;;
          unknown) printf '{"state":"stale"}\n'; exit 0 ;;
        esac
      fi
      echo 'ERROR: herdr_settled_query_failed' >&2
      exit 1
      ;;
    *)
      if [ -s "$settled_stderr" ]; then cat "$settled_stderr" >&2; fi
      echo "ERROR: herdr_settled_query_failed:${settled_code:-unparsed}" >&2
      exit 1
      ;;
  esac
}

interrupt_live() {
  interrupt_session=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --session-json)
        [ $# -ge 2 ] || exit 2
        interrupt_session="$2"; shift 2 ;;
      *) exit 2 ;;
    esac
  done
  [ -n "$interrupt_session" ] && [ -f "$interrupt_session" ] || exit 2
  live_require_context
  live_load_session "$interrupt_session"
  "$binary" agent send-keys "$sess_agent" esc >/dev/null 2>"$temp_dir/send-keys.stderr" || {
    if [ -s "$temp_dir/send-keys.stderr" ]; then cat "$temp_dir/send-keys.stderr" >&2; fi
    exit 1
  }
  exit 0
}

close_live() {
  close_session=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --session-json)
        [ $# -ge 2 ] || exit 2
        close_session="$2"; shift 2 ;;
      *) exit 2 ;;
    esac
  done
  [ -n "$close_session" ] && [ -f "$close_session" ] || exit 2
  live_require_context
  live_load_session "$close_session"
  "$binary" workspace close "$sess_workspace" >/dev/null 2>"$temp_dir/close.stderr" || {
    if [ -s "$temp_dir/close.stderr" ]; then cat "$temp_dir/close.stderr" >&2; fi
    exit 1
  }
  exit 0
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

inspect_core() {
  expected_handle="$1"
  if ! session_context_available; then
    adapter_lifecycle_json handle_unverifiable session_context_missing
    return 0
  fi
  binary="$(resolved_herdr_binary)" || {
    adapter_handle_unverifiable 'herdr binary is absent'
    return 0
  }
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/herdr-adapter.XXXXXX")" || {
    adapter_handle_unverifiable 'workspace handle cannot be verified'
    return 0
  }
  trap 'rm -rf "$temp_dir"' EXIT
  inspect_stdout="$temp_dir/inspect.stdout"
  inspect_stderr="$temp_dir/inspect.stderr"
  "$binary" workspace get "$expected_handle" >"$inspect_stdout" 2>"$inspect_stderr"
  inspect_status=$?
  if [ "$inspect_status" -eq 0 ]; then
    inspect_result="$(parse_inspect_success "$inspect_stdout" "$expected_handle" 2>/dev/null)"
    if [ "$inspect_result" = "live" ]; then
      adapter_lifecycle_json live 'exact workspace handle is present'
    elif [ "$inspect_result" = "malformed" ]; then
      adapter_handle_unverifiable 'workspace response is malformed'
    else
      adapter_handle_unverifiable 'workspace handle identity is mismatched'
    fi
    return 0
  fi
  inspect_error_code="$(parse_adapter_error "$inspect_stderr" 2>/dev/null)"
  if [ "$inspect_status" -eq 1 ] && [ "$inspect_error_code" = "workspace_not_found" ]; then
    adapter_lifecycle_json stale 'workspace handle is not found'
  else
    adapter_handle_unverifiable 'workspace handle cannot be verified'
  fi
  return 0
}

inspect_live() {
  inspect_session=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --session-json)
        [ $# -ge 2 ] || exit 2
        inspect_session="$2"; shift 2 ;;
      *) exit 2 ;;
    esac
  done
  [ -n "$inspect_session" ] && [ -f "$inspect_session" ] || exit 2
  live_load_session "$inspect_session"
  inspect_core "$sess_workspace"
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
  inspect_core "$handle"
}

preview() {
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
  echo "herdr launch --name \"$name\" --worktree \"$worktree\" --runner-relative \"$runner\""
}

case "$command_name" in
  capabilities)
    [ "${1:-}" = "--worktree" ] || exit 2
    cap_worktree="$2"
    cap_probe_live_flag=false
    if [ "$#" -eq 3 ] && [ "$3" = "--probe-live" ]; then
      cap_probe_live_flag=true
    elif [ "$#" -ne 2 ]; then
      exit 2
    fi
    capabilities "$cap_worktree" "$cap_probe_live_flag"
    ;;
  launch)
    launch "$@"
    ;;
  launch-live)
    launch_live "$@"
    ;;
  wait-ready)
    wait_ready "$@"
    ;;
  send)
    send_live "$@"
    ;;
  read)
    read_live "$@"
    ;;
  wait-settled)
    wait_settled "$@"
    ;;
  interrupt)
    interrupt_live "$@"
    ;;
  close)
    close_live "$@"
    ;;
  inspect)
    if [ "${1:-}" = "--session-json" ]; then
      inspect_live "$@"
    else
      inspect "$@"
    fi
    ;;
  preview)
    preview "$@"
    ;;
  *) exit 2 ;;
esac
