#!/usr/bin/env bash
# Orca transport adapter. Headless mode opens one fresh bare-shell terminal in
# the exact existing worktree and starts only the common launch runner. Live
# mode owns the terminal session itself through the documented
# `orca terminal` primitives: create/wait/read/send/close plus list.
# bash-3.2-compatible: no associative arrays, mapfile, or lowercase expansion.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/adapter-helpers.sh"

command_name="${1:-}"
shift || true
HEADLESS_CAPABILITIES='terminal.create.worktree_path,terminal.create.title,terminal.create.command,terminal.create.json,terminal.list.read_only'

# Every interactive primitive the live subcommands use must be proven from the
# same help surface they call. One missing token withholds only the semantic
# session vocabulary: the headless claim above stays intact.
live_help_all_tokens() {
  live_read_help="$(orca terminal read --help 2>&1)"
  help_has "$live_read_help" '--terminal' || return 1
  help_has "$live_read_help" '--cursor' || return 1
  live_send_help="$(orca terminal send --help 2>&1)"
  help_has "$live_send_help" '--terminal' || return 1
  help_has "$live_send_help" '--text' || return 1
  help_has "$live_send_help" '--enter' || return 1
  live_wait_help="$(orca terminal wait --help 2>&1)"
  help_has "$live_wait_help" '--terminal' || return 1
  help_has "$live_wait_help" '--for' || return 1
  help_has "$live_wait_help" 'tui-idle' || return 1
  help_has "$live_wait_help" '--timeout-ms' || return 1
  live_close_help="$(orca terminal close --help 2>&1)"
  help_has "$live_close_help" '--terminal' || return 1
  return 0
}

capability_json() {
  worktree="$1"
  if ! command -v orca >/dev/null 2>&1; then
    node "$ADAPTER_JSON" capabilities orca false binary_not_found unknown ''
    return
  fi
  help="$(orca terminal create --help 2>&1)"
  for flag in '--worktree' '--title' '--command' '--json'; do
    if ! help_has "$help" "$flag"; then
      node "$ADAPTER_JSON" capabilities orca false required_capability_missing unknown ''
      return
    fi
  done
  list_help="$(orca terminal list --help 2>&1)"
  for flag in '--worktree' '--json'; do
    if ! help_has "$list_help" "$flag"; then
      node "$ADAPTER_JSON" capabilities orca false required_capability_missing unknown ''
      return
    fi
  done
  status_json="$(orca status --json 2>/dev/null)"
  version="$(node - "$status_json" <<'NODE'
try {
  const value = JSON.parse(process.argv[2]);
  const version = value && value.result && value.result.runtime && value.result.runtime.appVersion;
  if (typeof version !== "string") process.exit(1);
  process.stdout.write(version);
} catch (error) {
  process.exit(1);
}
NODE
  )"
  [ -n "$version" ] || version="unknown"
  if [ "$version" != "unknown" ]; then
    version="$(node "$ADAPTER_SEMVER" exact "$version" 2>/dev/null)" || version="unknown"
  fi
  live_csv=""
  if live_help_all_tokens; then
    live_csv="$(node "$ADAPTER_TRANSPORT_REGISTRY" live-capabilities | tr '\n' ',')"
    live_csv="${live_csv%,}"
  fi
  if [ -n "$live_csv" ]; then
    node "$ADAPTER_JSON" capabilities orca true available "$version" "$HEADLESS_CAPABILITIES,$live_csv"
  else
    node "$ADAPTER_JSON" capabilities orca true available "$version" "$HEADLESS_CAPABILITIES"
  fi
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

# --- Live session subcommands -------------------------------------------------

ORCA_LIVE_TMP=""
# Ensure the per-invocation temp dir exists in the current shell. Called at
# the top of each live subcommand; temp paths are built from $ORCA_LIVE_TMP
# directly so no subshell ever owns (and deletes) it.
orca_live_ensure_tmp() {
  if [ -z "$ORCA_LIVE_TMP" ]; then
    ORCA_LIVE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/orca-live-adapter.XXXXXX")" || return 1
    trap 'rm -rf "$ORCA_LIVE_TMP"' EXIT
  fi
  return 0
}

orca_live_session_fields() {
  # <session-json> -> "handle<TAB>worktree<TAB>seat-name" on stdout
  node - "$1" <<'NODE'
const fs = require("fs");
try {
  const value = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  const handle = value && value.handles && typeof value.handles.lifecycle === "string" ? value.handles.lifecycle : "";
  const worktree = value && typeof value.worktree_path === "string" ? value.worktree_path : "";
  const name = value && typeof value.name === "string" ? value.name : "";
  if (!handle || !worktree || !name) process.exit(2);
  process.stdout.write([handle, worktree, name].join("\t") + "\n");
} catch (error) { process.exit(2); }
NODE
}

orca_live_positive_int() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    0) return 1 ;;
    *) return 0 ;;
  esac
}

# Extract orca's typed error code from a captured output/error file.
orca_live_error_code() {
  node - "$1" <<'NODE'
const fs = require("fs");
try {
  const value = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  const code = value && value.error && value.error.code;
  if (typeof code === "string" && code) {
    process.stdout.write(code);
    process.exit(0);
  }
} catch (error) {}
process.exit(1);
NODE
}

# Stale-handle reacquisition: Orca terminal handles are runtime-scoped, so a
# restarted runtime invalidates them. Reacquire strictly by exact worktree +
# seat (terminal title) identity and only when exactly one terminal matches;
# zero or several matches fail closed.
orca_live_reacquire() {
  reacquire_worktree="$1"
  reacquire_name="$2"
  reacquire_out="$(orca terminal list --worktree "path:$reacquire_worktree" --json 2>/dev/null)" || return 1
  node - "$reacquire_out" "$reacquire_name" <<'NODE'
const fs = require("fs");
try {
  const value = JSON.parse(process.argv[2]);
  const terminals = value && value.result && Array.isArray(value.result.terminals) ? value.result.terminals : null;
  if (!terminals) process.exit(2);
  const matches = terminals.filter((terminal) => terminal && typeof terminal === "object"
    && terminal.title === process.argv[3]
    && typeof terminal.handle === "string" && terminal.handle);
  if (matches.length !== 1) process.exit(2);
  process.stdout.write(matches[0].handle + "\n");
} catch (error) { process.exit(2); }
NODE
}

# Parse handle/worktree/name fields from the session file into the
# live_handle/live_worktree/live_seat_name variables. Fails closed.
orca_live_load_session() {
  live_fields="$(orca_live_session_fields "$1" 2>/dev/null)" || return 1
  live_oldIFS="$IFS"
  IFS="$(printf '\t')"
  set -- $live_fields
  IFS="$live_oldIFS"
  live_handle="${1:-}"
  live_worktree="${2:-}"
  live_seat_name="${3:-}"
  [ -n "$live_handle" ] && [ -n "$live_worktree" ] && [ -n "$live_seat_name" ]
}

# If the captured failure is a stale handle, reacquire once and retry through
# the caller-provided runner function. orca_live_retry_stale <run-fn> <out> <err>
orca_live_retry_stale() {
  retry_fn="$1"
  retry_out="$2"
  retry_err="$3"
  [ "$ORCA_LIVE_STATUS" -ne 0 ] || return 1
  retry_code="$(orca_live_error_code "$retry_out" 2>/dev/null)"
  if [ "$?" -ne 0 ] || [ "$retry_code" != "terminal_handle_stale" ]; then
    retry_code="$(orca_live_error_code "$retry_err" 2>/dev/null)" || retry_code=""
  fi
  [ "$retry_code" = "terminal_handle_stale" ] || return 1
  retry_handle="$(orca_live_reacquire "$live_worktree" "$live_seat_name")" || return 1
  live_handle="$retry_handle"
  "$retry_fn" "$retry_out" "$retry_err"
}

wait_ready() {
  wait_session=""; wait_timeout=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --session-json) [ $# -ge 2 ] || exit 2; wait_session="$2"; shift 2 ;;
      --timeout-ms) [ $# -ge 2 ] || exit 2; wait_timeout="$2"; shift 2 ;;
      *) exit 2 ;;
    esac
  done
  [ -n "$wait_session" ] && [ -n "$wait_timeout" ] || exit 2
  orca_live_positive_int "$wait_timeout" || exit 2
  orca_live_load_session "$wait_session" || exit 2
  orca_live_ensure_tmp || exit 2
  wait_out="$ORCA_LIVE_TMP/wait.out"
  wait_err="$ORCA_LIVE_TMP/wait.err"
  wait_run() {
    orca terminal wait --terminal "$live_handle" --for tui-idle --timeout-ms "$wait_timeout" --json >"$1" 2>"$2"
    ORCA_LIVE_STATUS=$?
    return 0
  }
  wait_run "$wait_out" "$wait_err"
  if [ "$ORCA_LIVE_STATUS" -ne 0 ]; then
    orca_live_retry_stale wait_run "$wait_out" "$wait_err" || {
      echo 'ERROR: live_wait_not_ready: terminal did not reach tui-idle before the timeout' >&2
      exit 1
    }
  fi
  # Readiness gate only: a satisfied tui-idle means the TUI accepts input; it
  # is never completion evidence.
  node - "$wait_out" <<'NODE' || { echo 'ERROR: live_wait_result_invalid: wait did not report a satisfied tui-idle' >&2; exit 1; }
const fs = require("fs");
try {
  const value = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  if (!(value && value.result && value.result.wait && value.result.wait.satisfied === true)) process.exit(2);
} catch (error) { process.exit(2); }
NODE
}

live_read() {
  read_session=""; read_cursor=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --session-json) [ $# -ge 2 ] || exit 2; read_session="$2"; shift 2 ;;
      --cursor) [ $# -ge 2 ] || exit 2; read_cursor="$2"; shift 2 ;;
      *) exit 2 ;;
    esac
  done
  [ -n "$read_session" ] || exit 2
  case "$read_cursor" in
    '') ;;
    *[!0-9]*) exit 2 ;;
  esac
  orca_live_load_session "$read_session" || exit 2
  orca_live_ensure_tmp || exit 2
  read_out="$ORCA_LIVE_TMP/read.out"
  read_err="$ORCA_LIVE_TMP/read.err"
  read_run() {
    if [ -n "$read_cursor" ]; then
      orca terminal read --terminal "$live_handle" --cursor "$read_cursor" --json >"$1" 2>"$2"
    else
      orca terminal read --terminal "$live_handle" --json >"$1" 2>"$2"
    fi
    ORCA_LIVE_STATUS=$?
    return 0
  }
  read_run "$read_out" "$read_err"
  if [ "$ORCA_LIVE_STATUS" -ne 0 ]; then
    orca_live_retry_stale read_run "$read_out" "$read_err" || {
      echo 'ERROR: live_read_failed: terminal read failed' >&2
      exit 1
    }
  fi
  # Emit only stable fields (joined output + cursor). Volatile vendor fields
  # (request ids, timestamps, runtime metadata) are dropped so repeated reads
  # byte-compare equal until real output activity happens.
  node - "$read_out" <<'NODE' || { echo 'ERROR: live_read_result_invalid: terminal read returned malformed JSON' >&2; exit 1; }
const fs = require("fs");
try {
  const value = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  const terminal = value && value.result && value.result.terminal;
  if (!terminal || typeof terminal !== "object" || !Array.isArray(terminal.tail)) process.exit(2);
  const cursor = terminal.nextCursor === null || terminal.nextCursor === undefined ? null : String(terminal.nextCursor);
  process.stdout.write(JSON.stringify({ output: terminal.tail.join("\n"), cursor }) + "\n");
} catch (error) { process.exit(2); }
NODE
}

live_send() {
  send_session=""; send_input=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --session-json) [ $# -ge 2 ] || exit 2; send_session="$2"; shift 2 ;;
      --input-file) [ $# -ge 2 ] || exit 2; send_input="$2"; shift 2 ;;
      *) exit 2 ;;
    esac
  done
  [ -n "$send_session" ] && [ -n "$send_input" ] || exit 2
  [ -r "$send_input" ] || exit 2
  send_text="$(cat "$send_input")"
  [ -n "$send_text" ] || exit 2
  orca_live_load_session "$send_session" || exit 2
  orca_live_ensure_tmp || exit 2
  send_out="$ORCA_LIVE_TMP/send.out"
  send_err="$ORCA_LIVE_TMP/send.err"
  send_run() {
    orca terminal send --terminal "$live_handle" --text "$send_text" --enter --json >"$1" 2>"$2"
    ORCA_LIVE_STATUS=$?
    return 0
  }
  send_run "$send_out" "$send_err"
  if [ "$ORCA_LIVE_STATUS" -ne 0 ]; then
    orca_live_retry_stale send_run "$send_out" "$send_err" || {
      echo 'ERROR: live_send_failed: terminal send failed' >&2
      exit 1
    }
  fi
  node - "$send_out" <<'NODE' || { echo 'ERROR: live_send_unconfirmed: send returned no byte evidence' >&2; exit 1; }
const fs = require("fs");
try {
  const value = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  const send = value && value.result && value.result.send;
  if (!send || typeof send.bytesWritten !== "number" || send.bytesWritten <= 0) process.exit(2);
} catch (error) { process.exit(2); }
NODE
}

wait_settled() {
  settled_session=""; settled_timeout=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --session-json) [ $# -ge 2 ] || exit 2; settled_session="$2"; shift 2 ;;
      --timeout-ms) [ $# -ge 2 ] || exit 2; settled_timeout="$2"; shift 2 ;;
      *) exit 2 ;;
    esac
  done
  [ -n "$settled_session" ] && [ -n "$settled_timeout" ] || exit 2
  orca_live_positive_int "$settled_timeout" || exit 2
  orca_live_load_session "$settled_session" || exit 2
  orca_live_ensure_tmp || exit 2
  settled_out="$ORCA_LIVE_TMP/settled.out"
  settled_err="$ORCA_LIVE_TMP/settled.err"
  settled_run() {
    orca terminal wait --terminal "$live_handle" --for tui-idle --timeout-ms "$settled_timeout" --json >"$1" 2>"$2"
    ORCA_LIVE_STATUS=$?
    return 0
  }
  settled_classify() {
    node - "$settled_out" <<'NODE'
const fs = require("fs");
try {
  const value = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  if (value && value.error && value.error.code === "terminal_handle_stale") {
    process.stdout.write(JSON.stringify({ state: "stale" }) + "\n");
    process.exit(0);
  }
  const wait = value && value.result && value.result.wait;
  if (!wait) process.exit(2);
  if (wait.satisfied === true) {
    process.stdout.write(JSON.stringify({ state: "settled" }) + "\n");
  } else if (typeof wait.blockedReason === "string" && wait.blockedReason) {
    process.stdout.write(JSON.stringify({ state: "blocked" }) + "\n");
  } else {
    process.stdout.write(JSON.stringify({ state: "working" }) + "\n");
  }
} catch (error) { process.exit(2); }
NODE
  }
  settled_run "$settled_out" "$settled_err"
  if [ "$ORCA_LIVE_STATUS" -ne 0 ]; then
    if ! orca_live_retry_stale settled_run "$settled_out" "$settled_err"; then
      # Not a stale handle (or reacquisition itself failed closed): classify
      # a provable stale handle, otherwise fail the query typed.
      if settled_classify; then
        exit 0
      fi
      echo 'ERROR: live_settled_query_failed: terminal wait failed' >&2
      exit 1
    fi
    if [ "$ORCA_LIVE_STATUS" -ne 0 ]; then
      if settled_classify; then
        exit 0
      fi
      echo 'ERROR: live_settled_query_failed: terminal wait failed after reacquisition' >&2
      exit 1
    fi
  fi
  # tui-idle is a settled hint only. Completion authority stays with the
  # canonical artifact gate; the caller must not treat this state as success.
  settled_classify || { echo 'ERROR: live_settled_result_invalid: terminal wait returned malformed JSON' >&2; exit 1; }
}

live_interrupt() {
  interrupt_session=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --session-json) [ $# -ge 2 ] || exit 2; interrupt_session="$2"; shift 2 ;;
      *) exit 2 ;;
    esac
  done
  [ -n "$interrupt_session" ] || exit 2
  orca_live_load_session "$interrupt_session" || exit 2
  orca_live_ensure_tmp || exit 2
  interrupt_out="$ORCA_LIVE_TMP/interrupt.out"
  interrupt_err="$ORCA_LIVE_TMP/interrupt.err"
  interrupt_run() {
    orca terminal send --terminal "$live_handle" --interrupt --json >"$1" 2>"$2"
    ORCA_LIVE_STATUS=$?
    return 0
  }
  interrupt_run "$interrupt_out" "$interrupt_err"
  if [ "$ORCA_LIVE_STATUS" -ne 0 ]; then
    orca_live_retry_stale interrupt_run "$interrupt_out" "$interrupt_err" || {
      echo 'ERROR: live_interrupt_failed: terminal interrupt failed' >&2
      exit 1
    }
  fi
  adapter_lifecycle_json interrupted 'terminal interrupt input accepted'
}

live_close() {
  close_session=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --session-json) [ $# -ge 2 ] || exit 2; close_session="$2"; shift 2 ;;
      *) exit 2 ;;
    esac
  done
  [ -n "$close_session" ] || exit 2
  orca_live_load_session "$close_session" || exit 2
  orca_live_ensure_tmp || exit 2
  close_out="$ORCA_LIVE_TMP/close.out"
  close_err="$ORCA_LIVE_TMP/close.err"
  close_run() {
    orca terminal close --terminal "$live_handle" --json >"$1" 2>"$2"
    ORCA_LIVE_STATUS=$?
    return 0
  }
  close_run "$close_out" "$close_err"
  if [ "$ORCA_LIVE_STATUS" -ne 0 ]; then
    orca_live_retry_stale close_run "$close_out" "$close_err" || {
      echo 'ERROR: live_close_failed: terminal close failed' >&2
      exit 1
    }
  fi
  adapter_lifecycle_json closed 'terminal closed'
}

# Validate the runtime-owned launch spec (runtime-agnostic: the runtime field
# is never compared to a name here) and dump its env pairs and argv tokens as
# NUL-separated streams for the shell-side quoting pass.
launch_live_dump_tokens() {
  node - "$1" "$ADAPTER_LIB_DIR" "$2" "$3" <<'NODE'
const fs = require("fs");
const path = require("path");
const [specFile, libDir, envFile, argvFile] = process.argv.slice(2);
const { normalizeLaunchSpec } = require(path.join(libDir, "launch-spec.cjs"));
let value;
try { value = JSON.parse(fs.readFileSync(specFile, "utf8")); } catch (error) { process.exit(2); }
const spec = normalizeLaunchSpec(value);
if (!spec) process.exit(2);
try {
  const envFd = fs.openSync(envFile, "w");
  for (const key of Object.keys(spec.env).sort()) {
    fs.writeSync(envFd, key + "\0" + spec.env[key] + "\0");
  }
  fs.closeSync(envFd);
  const argvFd = fs.openSync(argvFile, "w");
  for (const token of spec.argv) fs.writeSync(argvFd, token + "\0");
  fs.closeSync(argvFd);
} catch (error) { process.exit(2); }
NODE
}

launch_live() {
  launch_name=""; launch_worktree=""; launch_spec=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) [ $# -ge 2 ] || exit 2; launch_name="$2"; shift 2 ;;
      --worktree) [ $# -ge 2 ] || exit 2; launch_worktree="$2"; shift 2 ;;
      --launch-spec) [ $# -ge 2 ] || exit 2; launch_spec="$2"; shift 2 ;;
      *) exit 2 ;;
    esac
  done
  [ -n "$launch_name" ] && [ -n "$launch_worktree" ] && [ -n "$launch_spec" ] || exit 2
  [ -r "$launch_spec" ] || exit 2
  launch_tmp="$(mktemp -d "${TMPDIR:-/tmp}/orca-live-launch.XXXXXX")" || exit 2
  trap 'rm -rf "$launch_tmp"' EXIT
  # Same-issue duplicate-prompt prevention starts here: never create a second
  # terminal for one worktree + seat. An operator must inspect or close the
  # existing seat instead of silently double-prompting it.
  dup_out="$(orca terminal list --worktree "path:$launch_worktree" --json 2>"$launch_tmp/dup.err")" \
    || dup_out=""
  dup_count="$(node - "$dup_out" "$launch_name" <<'NODE'
try {
  const value = JSON.parse(process.argv[2]);
  const terminals = value && value.result && Array.isArray(value.result.terminals) ? value.result.terminals : null;
  if (!terminals) process.exit(2);
  process.stdout.write(String(terminals.filter((terminal) => terminal && terminal.title === process.argv[3]).length));
} catch (error) { process.exit(2); }
NODE
  )"
  if [ "$?" -ne 0 ] || [ -z "$dup_count" ]; then
    echo 'ERROR: live_seat_check_failed: terminal list could not prove the seat is absent' >&2
    exit 1
  fi
  if [ "$dup_count" != "0" ]; then
    echo "ERROR: live_seat_already_exists: worktree already has $dup_count terminal(s) titled for this seat; inspect or close the existing live seat instead of double-prompting" >&2
    exit 1
  fi
  launch_live_dump_tokens "$launch_spec" "$launch_tmp/env.tokens" "$launch_tmp/argv.tokens" || {
    echo 'ERROR: live_launch_spec_invalid: launch-spec is malformed' >&2
    exit 2
  }
  # Orca's --command accepts a single string (no argv-array form), so each
  # spec token is shell-quoted with printf %q before joining. Naive
  # concatenation would let spec values break out as shell syntax.
  command_str=""
  while IFS= read -r -d '' env_key && IFS= read -r -d '' env_val; do
    command_str+="$(printf '%s=%q ' "$env_key" "$env_val")"
  done <"$launch_tmp/env.tokens"
  while IFS= read -r -d '' argv_token; do
    command_str+="$(printf '%q ' "$argv_token")"
  done <"$launch_tmp/argv.tokens"
  command_str="${command_str% }"
  [ -n "$command_str" ] || exit 2
  create_out="$(orca terminal create --worktree "path:$launch_worktree" --title "$launch_name" --command "$command_str" --json 2>"$launch_tmp/create.err")"
  if [ "$?" -ne 0 ]; then
    cat "$launch_tmp/create.err" >&2
    exit 1
  fi
  terminal_handle="$(node - "$create_out" <<'NODE'
try {
  const value = JSON.parse(process.argv[2]);
  const terminal = value && value.result && value.result.terminal;
  if (!terminal || typeof terminal !== "object" || Array.isArray(terminal)
    || typeof terminal.handle !== "string" || !terminal.handle.length) process.exit(2);
  process.stdout.write(terminal.handle + "\n");
} catch (error) { process.exit(2); }
NODE
  )"
  if [ "$?" -ne 0 ] || [ -z "$terminal_handle" ]; then
    echo 'ERROR: live_launch_result_invalid: terminal create returned no terminal handle' >&2
    exit 2
  fi
  handles_json="$(node -e 'const h = process.argv[1]; process.stdout.write(JSON.stringify({ lifecycle: h, io: h, agent: h }))' "$terminal_handle")"
  adapter_session_json launched "$handles_json" "$terminal_handle"
}

live_inspect() {
  orca_live_load_session "$1" || exit 2
  output="$(orca terminal list --worktree "path:$live_worktree" --json 2>/dev/null)" || {
    adapter_handle_unverifiable 'Orca terminal list failed'
    return 0
  }
  normalize_handle_json inspect "$output" "$live_handle"
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
    runner_path_allowed "$RUNNER" || exit 2
    output="$(orca terminal create --worktree "path:$WORKTREE" --title "$NAME" --command "bash $RUNNER" --json)" || exit $?
    normalize_handle_json launch "$output"
    ;;
  inspect)
    WORKTREE=""; HANDLE=""; SESSION_JSON=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --worktree) WORKTREE="$2"; shift 2 ;;
        --external-handle) HANDLE="$2"; shift 2 ;;
        --session-json) SESSION_JSON="$2"; shift 2 ;;
        *) exit 2 ;;
      esac
    done
    if [ -n "$SESSION_JSON" ]; then
      [ -z "$WORKTREE" ] && [ -z "$HANDLE" ] || exit 2
      live_inspect "$SESSION_JSON"
      exit $?
    fi
    [ -n "$WORKTREE" ] && [ -n "$HANDLE" ] || exit 2
    output="$(orca terminal list --worktree "path:$WORKTREE" --json 2>/dev/null)" || {
      adapter_handle_unverifiable 'Orca terminal list failed'
      exit 0
    }
    normalize_handle_json inspect "$output" "$HANDLE"
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
    echo "orca launch --name \"$NAME\" --worktree \"$WORKTREE\" --runner-relative \"$RUNNER\""
    ;;
  launch-live)
    launch_live "$@"
    ;;
  wait-ready)
    wait_ready "$@"
    ;;
  read)
    live_read "$@"
    ;;
  send)
    live_send "$@"
    ;;
  wait-settled)
    wait_settled "$@"
    ;;
  interrupt)
    live_interrupt "$@"
    ;;
  close)
    live_close "$@"
    ;;
  *) exit 2 ;;
esac
