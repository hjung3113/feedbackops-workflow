#!/usr/bin/env bash
# Orca live-TUI adapter contract smoke (issue #203, T2). Every case drives the
# real adapters/orca.sh against a fake `orca` CLI that records the argv it
# receives (ADR 0004: assert on received input, not just exit codes) and the
# real lib/live-session-supervisor.sh for the shared live state machine.
# bash-3.2-compatible.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ORCA_ADAPTER="$ROOT/scripts/adapters/orca.sh"
RUNTIME="$ROOT/scripts/agent-runtime.sh"
TRANSPORT_REGISTRY="$ROOT/scripts/lib/transport-registry.cjs"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
FAILURES=0

pass() { echo "ok   - $1"; }
fail() { echo "NOT OK - $1"; FAILURES=$((FAILURES + 1)); }

ISSUE=203
SEAT="codex-${ISSUE}"

# --- shared fixtures -----------------------------------------------------------

# A git base repo plus one linked worktree whose path contains spaces, quotes,
# newlines, and shell metacharacters: launch-spec argv fidelity must survive.
BASE="$TMP_ROOT/base"
mkdir -p "$BASE"
git init -q "$BASE"
git -C "$BASE" config user.email t2@example.invalid
git -C "$BASE" config user.name t2
printf '%s\n' base > "$BASE/file.txt"
git -C "$BASE" add file.txt
git -C "$BASE" commit -qm initial
WT="$(printf '%s\n%s' "$TMP_ROOT/wt space 'quote" 'line;[] & $()')"
git -C "$BASE" worktree add -q "$WT" HEAD
mkdir -p "$WT/.review"

BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"

# Fake codex: help surfaces satisfy both the headless probe contract and the
# LIVE_PROBE token contract; any direct invocation records its argv
# NUL-separated so a shell round-trip can be compared byte-for-byte.
cat > "$BIN/codex" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo 'codex-test 1.0'; exit 0 ;;
  --help) printf '%s\n' 'Commands: exec'; printf '%s\n' 'exec --sandbox --cd --add-dir -m -c --ask-for-approval --model --config --output-last-message --json'; exit 0 ;;
esac
if [ "${1:-}" = "exec" ] && [ "${2:-}" = "--help" ]; then
  printf '%s\n' 'exec --sandbox --cd --model --config --output-last-message --json'
  exit 0
fi
if [ -n "${RUNTIME_ARGV:-}" ]; then printf '%s\0' "$@" > "$RUNTIME_ARGV"; fi
exit 0
EOF
# Fake opencode: root TUI help carries the live tokens; `run --help` satisfies
# the headless probe. Records argv plus OPENCODE_CONFIG_CONTENT when set.
cat > "$BIN/opencode" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo 'opencode-test 1.0'; exit 0; fi
if [ "${1:-}" = "--help" ]; then printf '%s\n' '--agent --model --variant run'; exit 0; fi
if [ "${1:-}" = "run" ] && [ "${2:-}" = "--help" ]; then printf '%s\n' '--dir --format --agent --model --variant json'; exit 0; fi
if [ -n "${RUNTIME_ARGV:-}" ]; then printf '%s\0' "$@" > "$RUNTIME_ARGV"; fi
if [ -n "${RUNTIME_ENV_RECORD:-}" ]; then printf '%s' "${OPENCODE_CONFIG_CONTENT:-}" > "$RUNTIME_ENV_RECORD"; fi
exit 0
EOF
chmod +x "$BIN/codex" "$BIN/opencode"

# Fake orca CLI: stateful (terminal registry, send counter) with per-invocation
# NUL-separated argv recording. One ORCA_LIVE_HELP_MODE token category can be
# dropped at a time to prove the fail-closed live probe.
cat > "$BIN/orca" <<'EOF'
#!/usr/bin/env bash
LOG_DIR="${ORCA_LIVE_LOG_DIR:?}"
STATE_DIR="${ORCA_LIVE_STATE_DIR:?}"
mkdir -p "$LOG_DIR" "$STATE_DIR"
terminals_file="$STATE_DIR/terminals.json"

log_argv() {
  log_op="$1"; shift
  log_count=0
  [ -f "$LOG_DIR/$log_op.count" ] && log_count="$(cat "$LOG_DIR/$log_op.count")"
  log_count=$((log_count + 1))
  printf '%s\n' "$log_count" > "$LOG_DIR/$log_op.count"
  printf '%s\0' "$@" > "$LOG_DIR/$log_op.$log_count.argv"
}

read_terminals() {
  if [ -f "$terminals_file" ]; then cat "$terminals_file"; else printf '{"result":{"terminals":[]}}'; fi
}

add_terminal() {
  node - "$terminals_file" "$1" "$2" <<'NODE'
const fs = require("fs");
const [file, handle, title] = process.argv.slice(2);
let value = { result: { terminals: [] } };
try { value = JSON.parse(fs.readFileSync(file, "utf8")); } catch (error) {}
if (!value.result || !Array.isArray(value.result.terminals)) value = { result: { terminals: [] } };
value.result.terminals.push({ handle, title });
fs.writeFileSync(file, JSON.stringify(value) + "\n");
NODE
}

is_stale() { [ -n "${ORCA_STALE_HANDLE:-}" ] && [ "$1" = "$ORCA_STALE_HANDLE" ]; }

emit() {
  node - "$@" <<'NODE'
const payload = JSON.parse(process.argv[2]);
process.stdout.write(JSON.stringify(payload) + "\n");
NODE
}

if [ "${1:-}" = "status" ] && [ "${2:-}" = "--json" ]; then
  printf '%s\n' '{"result":{"runtime":{"appVersion":"1.4.161"}}}'
  exit 0
fi

if [ "${1:-}" = "terminal" ] && [ "${3:-}" = "--help" ]; then
  help_mode="${ORCA_LIVE_HELP_MODE:-full}"
  case "$2" in
    create) printf '%s\n' 'Usage: orca terminal create --worktree PATH --title NAME --command TEXT --json' ;;
    list) printf '%s\n' 'Usage: orca terminal list --worktree PATH --json' ;;
    read)
      case "$help_mode" in
        no_read_terminal) printf '%s\n' 'Usage: orca terminal read [--cursor <n>] [--limit <n>] [--json]' ;;
        no_cursor) printf '%s\n' 'Usage: orca terminal read --terminal <handle> [--limit <n>] [--json]' ;;
        *) printf '%s\n' 'Usage: orca terminal read --terminal <handle> --cursor <n> --limit <n> [--json]' ;;
      esac ;;
    send)
      case "$help_mode" in
        no_send_terminal) printf '%s\n' 'Usage: orca terminal send --text <text> [--enter] [--json]' ;;
        no_text) printf '%s\n' 'Usage: orca terminal send --terminal <handle> [--enter] [--json]' ;;
        no_enter) printf '%s\n' 'Usage: orca terminal send --terminal <handle> --text <text> [--json]' ;;
        *) printf '%s\n' 'Usage: orca terminal send --terminal <handle> --text <text> [--enter] [--interrupt] [--json]' ;;
      esac ;;
    wait)
      case "$help_mode" in
        no_wait_terminal) printf '%s\n' 'Usage: orca terminal wait --for <condition> [--timeout-ms <ms>] [--json]' ;;
        no_for) printf '%s\n' 'Usage: orca terminal wait --terminal <handle> [--timeout-ms <ms>] [--json]' ;;
        no_tui_idle) printf '%s\n' 'Usage: orca terminal wait --terminal <handle> --for exit [--timeout-ms <ms>] [--json]' ;;
        no_timeout_ms) printf '%s\n' 'Usage: orca terminal wait --terminal <handle> --for exit|tui-idle [--json]' ;;
        *) printf '%s\n' 'Usage: orca terminal wait --terminal <handle> --for exit|tui-idle [--timeout-ms <ms>] [--json]' ;;
      esac ;;
    close)
      case "$help_mode" in
        no_close_terminal) printf '%s\n' 'Usage: orca terminal close [--tab] [--json]' ;;
        *) printf '%s\n' 'Usage: orca terminal close --terminal <handle> [--tab] [--json]' ;;
      esac ;;
  esac
  exit 0
fi

if [ "${1:-}" != "terminal" ]; then exit 9; fi
sub="$2"
shift 2
case "$sub" in
  list)
    log_argv list "$@"
    if [ "${ORCA_LIST_FAIL:-0}" = "1" ]; then
      printf '%s\n' '{"ok":false,"error":{"code":"list_failed"}}' >&2
      exit 2
    fi
    read_terminals
    exit 0
    ;;
  create)
    log_argv create "$@"
    if [ "${ORCA_CREATE_FAIL:-0}" = "1" ]; then
      printf '%s\n' '{"ok":false,"error":{"code":"create_failed"}}'
      exit 3
    fi
    create_title=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --worktree) shift 2 ;;
        --title) create_title="$2"; shift 2 ;;
        --command) shift 2 ;;
        --json) shift ;;
        *) shift ;;
      esac
    done
    create_handle="${ORCA_CREATE_HANDLE:-term-created}"
    add_terminal "$create_handle" "$create_title"
    printf '{"id":"req-create","result":{"terminal":{"handle":"%s","title":"%s"}}}\n' "$create_handle" "$create_title"
    exit 0
    ;;
  read)
    log_argv read "$@"
    read_handle=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --terminal) read_handle="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    if is_stale "$read_handle"; then
      printf '%s\n' '{"id":"fake-read","ok":false,"error":{"code":"terminal_handle_stale","message":"stale handle"}}'
      exit 1
    fi
    read_sends=0
    [ -f "$STATE_DIR/send.count" ] && read_sends="$(cat "$STATE_DIR/send.count")"
    if [ "${ORCA_READ_MODE:-static}" = "grow_after_send" ] && [ "$read_sends" -gt 0 ]; then
      printf '{"id":"r-grow","ok":true,"result":{"terminal":{"handle":"%s","status":"connected","tail":["agent turn output"],"nextCursor":"41","latestCursor":"41","requestVolatile":"changed"}}}\n' "$read_handle"
    else
      printf '{"id":"r-base","ok":true,"result":{"terminal":{"handle":"%s","status":"connected","tail":["base screen"],"nextCursor":"7","latestCursor":"9","requestVolatile":"stable"}}}\n' "$read_handle"
    fi
    exit 0
    ;;
  send)
    log_argv send "$@"
    send_handle=""; send_text=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --terminal) send_handle="$2"; shift 2 ;;
        --text) send_text="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    if is_stale "$send_handle"; then
      printf '%s\n' '{"id":"fake-send","ok":false,"error":{"code":"terminal_handle_stale","message":"stale handle"}}'
      exit 1
    fi
    send_count=0
    [ -f "$STATE_DIR/send.count" ] && send_count="$(cat "$STATE_DIR/send.count")"
    send_count=$((send_count + 1))
    printf '%s\n' "$send_count" > "$STATE_DIR/send.count"
    send_bytes="$(printf '%s' "$send_text" | wc -c | tr -d ' ')"
    [ "$send_bytes" -eq 0 ] && send_bytes=1
    printf '{"id":"s-ok","ok":true,"result":{"send":{"handle":"%s","bytesWritten":%s}}}\n' "$send_handle" "$send_bytes"
    exit 0
    ;;
  wait)
    log_argv wait "$@"
    wait_handle=""; wait_for=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --terminal) wait_handle="$2"; shift 2 ;;
        --for) wait_for="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    if is_stale "$wait_handle"; then
      printf '%s\n' '{"id":"fake-wait","ok":false,"error":{"code":"terminal_handle_stale","message":"stale handle"}}'
      exit 1
    fi
    case "${ORCA_WAIT_MODE:-idle}" in
      idle)
        printf '{"id":"w-idle","ok":true,"result":{"wait":{"handle":"%s","condition":"%s","satisfied":true,"status":"idle","exitCode":null}}}\n' "$wait_handle" "$wait_for"
        exit 0
        ;;
      busy)
        printf '{"id":"w-busy","ok":true,"result":{"wait":{"handle":"%s","condition":"%s","satisfied":false,"status":"working","exitCode":null}}}\n' "$wait_handle" "$wait_for"
        exit 1
        ;;
      busy_blocked)
        printf '{"id":"w-blocked","ok":true,"result":{"wait":{"handle":"%s","condition":"%s","satisfied":false,"status":"blocked","blockedReason":"approval request","exitCode":null}}}\n' "$wait_handle" "$wait_for"
        exit 1
        ;;
    esac
    exit 9
    ;;
  close)
    log_argv close "$@"
    close_handle=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --terminal) close_handle="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    if is_stale "$close_handle"; then
      printf '%s\n' '{"id":"fake-close","ok":false,"error":{"code":"terminal_handle_stale","message":"stale handle"}}'
      exit 1
    fi
    printf '{"id":"c-ok","ok":true,"result":{"close":{"handle":"%s","closeMode":"pane","ptyKilled":true}}}\n' "$close_handle"
    exit 0
    ;;
esac
exit 9
EOF
chmod +x "$BIN/orca"

# argv_assert <file> <mode:has|pair|not> <args...>
argv_assert() {
  argv_assert_file="$1"; argv_assert_mode="$2"; shift 2
  node - "$argv_assert_file" "$argv_assert_mode" "$@" <<'NODE'
const fs = require("fs");
const [file, mode, ...needles] = process.argv.slice(2);
let argv;
try {
  argv = fs.readFileSync(file).toString("utf8").split("\0");
  while (argv.length && argv[argv.length - 1] === "") argv.pop();
} catch (error) { argv = []; }
let ok;
if (mode === "has") ok = needles.every((needle) => argv.includes(needle));
else if (mode === "not") ok = !needles.some((needle) => argv.includes(needle));
else if (mode === "pair") ok = argv.indexOf(needles[0]) !== -1 && argv[argv.indexOf(needles[0]) + 1] === needles[1];
else ok = false;
process.exit(ok ? 0 : 1);
NODE
}

# command_flag_value <argv-file> <flag>: the token after the flag.
command_flag_value() {
  node - "$1" "$2" <<'NODE'
const fs = require("fs");
const [file, flag] = process.argv.slice(2);
let argv;
try {
  argv = fs.readFileSync(file).toString("utf8").split("\0");
  while (argv.length && argv[argv.length - 1] === "") argv.pop();
} catch (error) { process.exit(2); }
const at = argv.indexOf(flag);
if (at === -1) process.exit(2);
process.stdout.write(argv[at + 1]);
NODE
}

invocations_of() {
  invocations_count=0
  [ -f "$1" ] && invocations_count="$(cat "$1")"
  printf '%s' "$invocations_count"
}

fresh_env() {
  # fresh_env <case-name>: new fake-orca log/state directories for one case
  CASE_NAME="$1"
  CASE_LOG="$TMP_ROOT/log-$CASE_NAME"
  CASE_STATE="$TMP_ROOT/state-$CASE_NAME"
  mkdir -p "$CASE_LOG" "$CASE_STATE"
}

# A supervisor-shaped session.json for direct adapter subcommand calls.
write_session_json() {
  node - "$1" "$2" "$SEAT" "$WT" <<'NODE'
const fs = require("fs");
const [file, handle, name, worktree] = process.argv.slice(2);
fs.writeFileSync(file, JSON.stringify({
  schema_version: "1", execution_mode: "live-tui", adapter: "orca", name, worktree_path: worktree,
  lifecycle: "launched", handles: { lifecycle: handle, io: handle, agent: handle },
  launched_at: "2026-08-21T00:00:00Z", external_handle: handle,
}, null, 2) + "\n");
NODE
}

# Independently rebuild the expected --command string for a spec: env pairs
# (sorted keys) then argv tokens, each shell-quoted with printf %q.
expected_command_for() {
  spec_env_stream="$TMP_ROOT/spec-env.$$.stream"
  spec_argv_stream="$TMP_ROOT/spec-argv.$$.stream"
  node - "$1" > "$spec_env_stream" <<'NODE'
const fs = require("fs");
const spec = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
for (const key of Object.keys(spec.env).sort()) process.stdout.write(key + "\0" + spec.env[key] + "\0");
NODE
  node - "$1" > "$spec_argv_stream" <<'NODE'
const fs = require("fs");
const spec = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
for (const token of spec.argv) process.stdout.write(token + "\0");
NODE
  expected_command_result=""
  while IFS= read -r -d '' exp_key && IFS= read -r -d '' exp_val; do
    expected_command_result+="$(printf '%s=%q ' "$exp_key" "$exp_val")"
  done <"$spec_env_stream"
  while IFS= read -r -d '' exp_token; do
    expected_command_result+="$(printf '%q ' "$exp_token")"
  done <"$spec_argv_stream"
  expected_command_result="${expected_command_result% }"
  rm -f "$spec_env_stream" "$spec_argv_stream"
  printf '%s' "$expected_command_result"
}

# --- 1. capability probe: complete live contract --------------------------------

fresh_env caps-full
if ORCA_LIVE_LOG_DIR="$CASE_LOG" ORCA_LIVE_STATE_DIR="$CASE_STATE" PATH="$BIN:$PATH" \
  bash "$ORCA_ADAPTER" capabilities --worktree "$WT" > "$TMP_ROOT/caps-full.json" 2>"$TMP_ROOT/caps-full.err"; then
  if node - "$TMP_ROOT/caps-full.json" "$TRANSPORT_REGISTRY" <<'NODE'
const fs = require("fs");
const value = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const required = require(process.argv[3]).LIVE_CAPABILITIES;
if (value.adapter !== "orca" || value.available !== true || value.version !== "1.4.161") process.exit(2);
if (!required.every((entry) => value.capabilities.includes(entry))) process.exit(2);
if (!value.capabilities.includes("terminal.create.command")) process.exit(2);
NODE
  then pass 'capabilities prove the complete live token contract with headless strings intact'
  else fail 'capabilities complete live contract'; fi
else fail 'capabilities complete live contract (command failed)'; fi

for help_mode in no_read_terminal no_cursor no_send_terminal no_text no_enter no_wait_terminal no_for no_tui_idle no_timeout_ms no_close_terminal; do
  fresh_env "caps-$help_mode"
  ORCA_LIVE_LOG_DIR="$CASE_LOG" ORCA_LIVE_STATE_DIR="$CASE_STATE" ORCA_LIVE_HELP_MODE="$help_mode" \
    PATH="$BIN:$PATH" bash "$ORCA_ADAPTER" capabilities --worktree "$WT" > "$TMP_ROOT/caps-$help_mode.json" 2>/dev/null
  caps_status=$?
  if [ "$caps_status" -eq 0 ] && node - "$TMP_ROOT/caps-$help_mode.json" <<'NODE'
const fs = require("fs");
const value = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (value.available !== true) process.exit(2);
if (value.capabilities.some((entry) => entry.startsWith("session."))) process.exit(2);
if (!value.capabilities.includes("terminal.create.command")) process.exit(2);
NODE
  then pass "missing live token ($help_mode) withholds live but keeps headless available"
  else fail "missing live token ($help_mode) split"; fi
done

# --- 2. launch-live argv E2E round-trip ------------------------------------------

MODEL="$(printf '%s\n%s' 'model with spaces "quotes"' 'semi; $() `and`')"
fresh_env launch-e2e
CODEX_SPEC="$TMP_ROOT/codex-live-spec.json"
PATH="$BIN:$PATH" bash "$RUNTIME" launch-spec --runtime codex --role implementation --mode write \
  --cwd "$WT" --model "$MODEL" --effort high > "$CODEX_SPEC" 2>"$TMP_ROOT/spec.err" \
  || fail 'codex launch-spec generation failed'
launch_out="$TMP_ROOT/launch-e2e.out"
if ORCA_LIVE_LOG_DIR="$CASE_LOG" ORCA_LIVE_STATE_DIR="$CASE_STATE" ORCA_CREATE_HANDLE="term-e2e" \
  PATH="$BIN:$PATH" bash "$ORCA_ADAPTER" launch-live --name "$SEAT" --worktree "$WT" --launch-spec "$CODEX_SPEC" \
  > "$launch_out" 2>"$TMP_ROOT/launch-e2e.err"; then
  if node - "$launch_out" <<'NODE'
const fs = require("fs");
const value = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (value.lifecycle !== "launched") process.exit(2);
if (value.handles.lifecycle !== "term-e2e" || value.handles.io !== "term-e2e" || value.handles.agent !== "term-e2e") process.exit(2);
if (value.external_handle !== "term-e2e") process.exit(2);
NODE
  then pass 'launch-live returns structured terminal handles'
  else fail 'launch-live structured handles'; fi
else fail "launch-live structured handles (command failed: $(cat "$TMP_ROOT/launch-e2e.err"))"; fi

create_argv="$CASE_LOG/create.1.argv"
if argv_assert "$create_argv" pair --worktree "path:$WT" \
  && argv_assert "$create_argv" pair --title "$SEAT" \
  && argv_assert "$create_argv" has --json; then
  pass 'launch-live create receives exact worktree selector, seat title, and json flag'
else fail 'launch-live create argv'; fi

command_string="$(command_flag_value "$create_argv" --command)" \
  || fail 'launch-live create argv has no --command'
expected_command="$(expected_command_for "$CODEX_SPEC")"
if [ "$command_string" = "$expected_command" ]; then
  pass 'launch-live --command is the printf %q join of the spec env assignments and argv tokens'
else
  fail "launch-live --command quoting (received=$command_string expected=$expected_command)"
fi

# Shell round-trip: executing the received --command in a real shell must run
# the runtime binary with the exact spec argv bytes (the fake records argv;
# argv[0] is the program path itself and is not part of the recorded args).
ROUNDTRIP="$TMP_ROOT/roundtrip.argv"
if RUNTIME_ARGV="$ROUNDTRIP" eval "$command_string" 2>/dev/null; then
  if node - "$CODEX_SPEC" "$ROUNDTRIP" <<'NODE'
const fs = require("fs");
const spec = JSON.parse(fs.readFileSync(process.argv[2], "utf8")).argv.slice(1);
const received = fs.readFileSync(process.argv[3]).toString("utf8").split("\0");
while (received.length && received[received.length - 1] === "") received.pop();
if (received.length !== spec.length) process.exit(2);
for (let index = 0; index < received.length; index += 1) {
  if (received[index] !== spec[index]) process.exit(2);
}
NODE
  then pass 'shell round-trip: the --command string re-parses to the exact spec argv bytes'
  else fail 'launch-live shell round-trip'; fi
else fail 'launch-live shell round-trip (eval failed)'; fi

# Env-carrying spec (opencode): env pairs must be quoted into the command
# string and survive the shell round-trip as real environment assignments.
OPENCODE_SPEC="$TMP_ROOT/opencode-live-spec.json"
PATH="$BIN:$PATH" bash "$RUNTIME" launch-spec --runtime opencode --role implementation --mode write \
  --cwd "$WT" --model "$MODEL" --effort medium \
  --opencode-permission-file "$ROOT/scripts/runtimes/opencode-write.json" > "$OPENCODE_SPEC" 2>"$TMP_ROOT/opencode-spec.err" \
  || fail 'opencode launch-spec generation failed'
fresh_env launch-opencode
ORCA_LIVE_LOG_DIR="$CASE_LOG" ORCA_LIVE_STATE_DIR="$CASE_STATE" ORCA_CREATE_HANDLE="term-oc" \
  PATH="$BIN:$PATH" bash "$ORCA_ADAPTER" launch-live --name "$SEAT" --worktree "$WT" --launch-spec "$OPENCODE_SPEC" \
  > "$TMP_ROOT/launch-oc.out" 2>"$TMP_ROOT/launch-oc.err" \
  || fail "opencode launch-live failed ($(cat "$TMP_ROOT/launch-oc.err"))"
opencode_command="$(command_flag_value "$CASE_LOG/create.1.argv" --command)" \
  || fail 'opencode create argv has no --command'
opencode_expected="$(expected_command_for "$OPENCODE_SPEC")"
if [ "$opencode_command" = "$opencode_expected" ]; then
  pass 'env-carrying launch-spec is quoted as env assignments plus argv tokens'
else
  fail 'launch-live env quoting'
fi
OC_ROUNDTRIP="$TMP_ROOT/oc-roundtrip.argv"
OC_ENV_RECORD="$TMP_ROOT/oc-roundtrip.env"
if RUNTIME_ARGV="$OC_ROUNDTRIP" RUNTIME_ENV_RECORD="$OC_ENV_RECORD" eval "$opencode_command" 2>/dev/null; then
  if node - "$OPENCODE_SPEC" "$OC_ROUNDTRIP" "$OC_ENV_RECORD" "$ROOT/scripts/runtimes/opencode-write.json" <<'NODE'
const fs = require("fs");
const spec = JSON.parse(fs.readFileSync(process.argv[2], "utf8")).argv.slice(1);
const received = fs.readFileSync(process.argv[3]).toString("utf8").split("\0");
while (received.length && received[received.length - 1] === "") received.pop();
if (received.length !== spec.length) process.exit(2);
for (let index = 0; index < received.length; index += 1) {
  if (received[index] !== spec[index]) process.exit(2);
}
const envRecord = fs.readFileSync(process.argv[4], "utf8");
const config = fs.readFileSync(process.argv[5], "utf8");
if (envRecord !== config) process.exit(2);
NODE
  then pass 'env-carrying command round-trips argv bytes and env content through a real shell'
  else fail 'launch-live env round-trip'; fi
else fail 'launch-live env round-trip (eval failed)'; fi

# --- 3. duplicate seat / duplicate prompt prevention ------------------------------

fresh_env dup-seat
printf '%s\n' '{"result":{"terminals":[{"handle":"term-existing","title":"codex-203"}]}}' > "$CASE_STATE/terminals.json"
if ORCA_LIVE_LOG_DIR="$CASE_LOG" ORCA_LIVE_STATE_DIR="$CASE_STATE" PATH="$BIN:$PATH" \
  bash "$ORCA_ADAPTER" launch-live --name "$SEAT" --worktree "$WT" --launch-spec "$CODEX_SPEC" \
  > "$TMP_ROOT/dup.out" 2>"$TMP_ROOT/dup.err"; then
  fail 'launch-live refuses an existing same-seat terminal'
else
  dup_ec=$?
  if [ "$dup_ec" -eq 1 ] && grep -F 'live_seat_already_exists' "$TMP_ROOT/dup.err" >/dev/null \
    && [ "$(invocations_of "$CASE_LOG/create.count")" = "0" ]; then
    pass 'same-issue redispatch duplicate-prompt prevention: launch-live refuses an existing seat before create'
  else fail "duplicate-seat refusal (ec=$dup_ec err=$(cat "$TMP_ROOT/dup.err"))"; fi
fi

fresh_env list-fail
ORCA_LIVE_LOG_DIR="$CASE_LOG" ORCA_LIVE_STATE_DIR="$CASE_STATE" ORCA_LIST_FAIL=1 PATH="$BIN:$PATH" \
  bash "$ORCA_ADAPTER" launch-live --name "$SEAT" --worktree "$WT" --launch-spec "$CODEX_SPEC" \
  > "$TMP_ROOT/listfail.out" 2>"$TMP_ROOT/listfail.err"
listfail_ec=$?
if [ "$listfail_ec" -eq 1 ] && grep -F 'live_seat_check_failed' "$TMP_ROOT/listfail.err" >/dev/null \
  && [ "$(invocations_of "$CASE_LOG/create.count")" = "0" ]; then
  pass 'launch-live fails closed when seat absence cannot be proven'
else fail "launch-live seat-check failure path (ec=$listfail_ec)"; fi

# --- 4. wait-ready / read / send / interrupt / close / inspect adapter surface ----

SESSION="$TMP_ROOT/session.json"
write_session_json "$SESSION" "term-live"

fresh_env adapter-surface

if ORCA_LIVE_LOG_DIR="$CASE_LOG" ORCA_LIVE_STATE_DIR="$CASE_STATE" PATH="$BIN:$PATH" \
  bash "$ORCA_ADAPTER" wait-ready --session-json "$SESSION" --timeout-ms 1500 > "$TMP_ROOT/ready.out" 2>"$TMP_ROOT/ready.err"; then
  if argv_assert "$CASE_LOG/wait.1.argv" pair --terminal term-live \
    && argv_assert "$CASE_LOG/wait.1.argv" pair --for tui-idle \
    && argv_assert "$CASE_LOG/wait.1.argv" pair --timeout-ms 1500 \
    && argv_assert "$CASE_LOG/wait.1.argv" has --json \
    && argv_assert "$CASE_LOG/wait.1.argv" not exit; then
    pass 'wait-ready is a tui-idle readiness gate with the requested timeout'
  else fail 'wait-ready argv gate'; fi
else fail 'wait-ready happy path'; fi

if ORCA_LIVE_LOG_DIR="$CASE_LOG" ORCA_LIVE_STATE_DIR="$CASE_STATE" ORCA_WAIT_MODE=busy PATH="$BIN:$PATH" \
  bash "$ORCA_ADAPTER" wait-ready --session-json "$SESSION" --timeout-ms 1500 > "$TMP_ROOT/ready-busy.out" 2>"$TMP_ROOT/ready-busy.err"; then
  fail 'wait-ready refuses an unsatisfied tui-idle'
else
  if grep -F 'live_wait_not_ready' "$TMP_ROOT/ready-busy.err" >/dev/null; then
    pass 'wait-ready exits typed when tui-idle is not satisfied'
  else fail 'wait-ready unsatisfied refusal'; fi
fi

read_one="$TMP_ROOT/read1.json"
read_two="$TMP_ROOT/read2.json"
ORCA_LIVE_LOG_DIR="$CASE_LOG" ORCA_LIVE_STATE_DIR="$CASE_STATE" PATH="$BIN:$PATH" \
  bash "$ORCA_ADAPTER" read --session-json "$SESSION" > "$read_one" 2>/dev/null
read_ec=$?
ORCA_LIVE_LOG_DIR="$CASE_LOG" ORCA_LIVE_STATE_DIR="$CASE_STATE" PATH="$BIN:$PATH" \
  bash "$ORCA_ADAPTER" read --session-json "$SESSION" > "$read_two" 2>/dev/null
if [ "$read_ec" -eq 0 ] && cmp -s "$read_one" "$read_two" && node - "$read_one" <<'NODE'
const fs = require("fs");
const value = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const keys = Object.keys(value).sort();
if (JSON.stringify(keys) !== JSON.stringify(["cursor", "output"])) process.exit(2);
if (value.output !== "base screen" || value.cursor !== "7") process.exit(2);
NODE
then pass 'read emits a stable normalized output+cursor shape without volatile vendor fields'
else fail 'read normalization/stability'; fi

if ORCA_LIVE_LOG_DIR="$CASE_LOG" ORCA_LIVE_STATE_DIR="$CASE_STATE" PATH="$BIN:$PATH" \
  bash "$ORCA_ADAPTER" read --session-json "$SESSION" --cursor 42 > /dev/null 2>&1 \
  && argv_assert "$CASE_LOG/read.3.argv" pair --cursor 42; then
  pass 'read forwards a numeric cursor'
else fail 'read --cursor forwarding'; fi
if ORCA_LIVE_LOG_DIR="$CASE_LOG" ORCA_LIVE_STATE_DIR="$CASE_STATE" PATH="$BIN:$PATH" \
  bash "$ORCA_ADAPTER" read --session-json "$SESSION" --cursor not-a-number > /dev/null 2>&1; then
  fail 'read rejects a non-numeric cursor'
else pass 'read rejects a non-numeric cursor'; fi

PROMPT_FILE="$TMP_ROOT/prompt.txt"
PROMPT_BODY="$(printf '%s\n%s' 'do the work; `rm -rf /` && $(echo injected)' 'second "line" with quotes')"
printf '%s\n' "$PROMPT_BODY" > "$PROMPT_FILE"
if ORCA_LIVE_LOG_DIR="$CASE_LOG" ORCA_LIVE_STATE_DIR="$CASE_STATE" PATH="$BIN:$PATH" \
  bash "$ORCA_ADAPTER" send --session-json "$SESSION" --input-file "$PROMPT_FILE" > /dev/null 2>"$TMP_ROOT/send.err" \
  && argv_assert "$CASE_LOG/send.1.argv" pair --text "$PROMPT_BODY" \
  && argv_assert "$CASE_LOG/send.1.argv" pair --terminal term-live \
  && argv_assert "$CASE_LOG/send.1.argv" has --enter --json; then
  pass 'send delivers the exact prompt file bytes via --text --enter'
else fail 'send argv contract'; fi
: > "$TMP_ROOT/empty-prompt.txt"
if ORCA_LIVE_LOG_DIR="$CASE_LOG" ORCA_LIVE_STATE_DIR="$CASE_STATE" PATH="$BIN:$PATH" \
  bash "$ORCA_ADAPTER" send --session-json "$SESSION" --input-file "$TMP_ROOT/empty-prompt.txt" > /dev/null 2>&1; then
  fail 'send refuses an empty prompt'
else pass 'send refuses an empty prompt'; fi

if ORCA_LIVE_LOG_DIR="$CASE_LOG" ORCA_LIVE_STATE_DIR="$CASE_STATE" PATH="$BIN:$PATH" \
  bash "$ORCA_ADAPTER" interrupt --session-json "$SESSION" > "$TMP_ROOT/interrupt.out" 2>/dev/null \
  && argv_assert "$CASE_LOG/send.2.argv" pair --terminal term-live \
  && argv_assert "$CASE_LOG/send.2.argv" has --interrupt \
  && argv_assert "$CASE_LOG/send.2.argv" not --text \
  && grep -F '"interrupted"' "$TMP_ROOT/interrupt.out" >/dev/null; then
  pass 'interrupt sends interrupt-style input without a text payload'
else fail 'interrupt argv'; fi

if ORCA_LIVE_LOG_DIR="$CASE_LOG" ORCA_LIVE_STATE_DIR="$CASE_STATE" PATH="$BIN:$PATH" \
  bash "$ORCA_ADAPTER" close --session-json "$SESSION" > "$TMP_ROOT/close.out" 2>/dev/null \
  && argv_assert "$CASE_LOG/close.1.argv" pair --terminal term-live \
  && argv_assert "$CASE_LOG/close.1.argv" has --json \
  && grep -F '"closed"' "$TMP_ROOT/close.out" >/dev/null; then
  pass 'close addresses the exact terminal handle'
else fail 'close argv'; fi

printf '%s\n' '{"result":{"terminals":[{"handle":"term-live","title":"codex-203"}]}}' > "$CASE_STATE/terminals.json"
if ORCA_LIVE_LOG_DIR="$CASE_LOG" ORCA_LIVE_STATE_DIR="$CASE_STATE" PATH="$BIN:$PATH" \
  bash "$ORCA_ADAPTER" inspect --session-json "$SESSION" > "$TMP_ROOT/inspect-live.out" 2>/dev/null \
  && grep -F '"lifecycle":"live"' "$TMP_ROOT/inspect-live.out" >/dev/null; then
  pass 'inspect --session-json reports a live session handle'
else fail 'inspect session-json live'; fi
printf '%s\n' '{"result":{"terminals":[]}}' > "$CASE_STATE/terminals.json"
if ORCA_LIVE_LOG_DIR="$CASE_LOG" ORCA_LIVE_STATE_DIR="$CASE_STATE" PATH="$BIN:$PATH" \
  bash "$ORCA_ADAPTER" inspect --session-json "$SESSION" > "$TMP_ROOT/inspect-stale.out" 2>/dev/null \
  && grep -F '"lifecycle":"stale"' "$TMP_ROOT/inspect-stale.out" >/dev/null; then
  pass 'inspect --session-json reports a stale session handle'
else fail 'inspect session-json stale'; fi

# --- 5. stale-handle reacquisition ------------------------------------------------

STALE_SESSION="$TMP_ROOT/stale-session.json"
write_session_json "$STALE_SESSION" "term-old"

fresh_env reacquire-one
printf '%s\n' '{"result":{"terminals":[{"handle":"term-decoy","title":"other-seat"},{"handle":"term-new","title":"codex-203"}]}}' > "$CASE_STATE/terminals.json"
if ORCA_LIVE_LOG_DIR="$CASE_LOG" ORCA_LIVE_STATE_DIR="$CASE_STATE" ORCA_STALE_HANDLE="term-old" PATH="$BIN:$PATH" \
  bash "$ORCA_ADAPTER" read --session-json "$STALE_SESSION" > "$TMP_ROOT/reacquire.out" 2>"$TMP_ROOT/reacquire.err" \
  && argv_assert "$CASE_LOG/read.1.argv" pair --terminal term-old \
  && argv_assert "$CASE_LOG/read.2.argv" pair --terminal term-new \
  && argv_assert "$CASE_LOG/list.1.argv" pair --worktree "path:$WT"; then
  pass 'stale handle is reacquired once by exact worktree + seat identity and retried'
else fail 'stale-handle reacquisition (single match)'; fi

fresh_env reacquire-zero
printf '%s\n' '{"result":{"terminals":[{"handle":"term-decoy","title":"other-seat"}]}}' > "$CASE_STATE/terminals.json"
ORCA_LIVE_LOG_DIR="$CASE_LOG" ORCA_LIVE_STATE_DIR="$CASE_STATE" ORCA_STALE_HANDLE="term-old" PATH="$BIN:$PATH" \
  bash "$ORCA_ADAPTER" read --session-json "$STALE_SESSION" > "$TMP_ROOT/reacquire-zero.out" 2>"$TMP_ROOT/reacquire-zero.err"
reacquire_zero_ec=$?
if [ "$reacquire_zero_ec" -ne 0 ] && [ "$(invocations_of "$CASE_LOG/read.count")" = "1" ] \
  && grep -F 'live_read_failed' "$TMP_ROOT/reacquire-zero.err" >/dev/null; then
  pass 'reacquisition with zero identity matches fails closed without a second read'
else fail "reacquisition zero-match fail-closed (ec=$reacquire_zero_ec)"; fi

fresh_env reacquire-two
printf '%s\n' '{"result":{"terminals":[{"handle":"term-a","title":"codex-203"},{"handle":"term-b","title":"codex-203"}]}}' > "$CASE_STATE/terminals.json"
ORCA_LIVE_LOG_DIR="$CASE_LOG" ORCA_LIVE_STATE_DIR="$CASE_STATE" ORCA_STALE_HANDLE="term-old" PATH="$BIN:$PATH" \
  bash "$ORCA_ADAPTER" read --session-json "$STALE_SESSION" > "$TMP_ROOT/reacquire-two.out" 2>"$TMP_ROOT/reacquire-two.err"
reacquire_two_ec=$?
if [ "$reacquire_two_ec" -ne 0 ] && [ "$(invocations_of "$CASE_LOG/read.count")" = "1" ]; then
  pass 'reacquisition with ambiguous identity matches fails closed'
else fail "reacquisition two-match fail-closed (ec=$reacquire_two_ec)"; fi

# --- 6. supervisor state machine ---------------------------------------------------

# run_supervisor <live-dir>: drives the real shared supervisor against the real
# adapter; prints supervisor:ok or supervisor:fail:<code>.
run_supervisor() {
  mkdir -p "$1"
  LIVE_WAIT_READY_TIMEOUT_MS=1500 LIVE_SEND_ACTIVITY_TIMEOUT_MS=600 \
    LIVE_SESSION_TIMEOUT_MS=10000 LIVE_POLL_INTERVAL_MS=20 \
    bash -c '. "$1/scripts/lib/live-session-supervisor.sh"
      if live_session_start "$2" orca "$3" "$4" "$5" "$6" "$7" "$8"; then
        printf "supervisor:ok\n"
      else
        printf "supervisor:fail:%s\n" "${LIVE_FAILURE_CODE:-unknown}"
        exit 1
      fi' \
    _ "$ROOT" "$ORCA_ADAPTER" "$SEAT" "$WT" "$CODEX_SPEC" "$PROMPT_FILE" "$1" "$ISSUE"
}

# Send-before-ready: an unsatisfied tui-idle must stop the sequence before any
# prompt is delivered (design §11 item 4).
fresh_env sup-not-ready
if ORCA_LIVE_LOG_DIR="$CASE_LOG" ORCA_LIVE_STATE_DIR="$CASE_STATE" ORCA_WAIT_MODE=busy PATH="$BIN:$PATH" \
  run_supervisor "$TMP_ROOT/live-not-ready" > "$TMP_ROOT/sup-not-ready.out" 2>&1; then
  fail 'supervisor refuses to send before readiness'
else
  if grep -F 'supervisor:fail:live_ready_timeout' "$TMP_ROOT/sup-not-ready.out" >/dev/null \
    && [ "$(invocations_of "$CASE_LOG/send.count")" = "0" ] \
    && [ ! -f "$TMP_ROOT/live-not-ready/LIVE.json" ]; then
    pass 'send-before-ready is refused and no prompt is ever delivered'
  else fail "supervisor send-before-ready sequencing ($(cat "$TMP_ROOT/sup-not-ready.out"))"; fi
fi

# Send accepted but no activity: fail without re-sending the prompt body
# (design §11 item 6).
fresh_env sup-no-activity
if ORCA_LIVE_LOG_DIR="$CASE_LOG" ORCA_LIVE_STATE_DIR="$CASE_STATE" ORCA_READ_MODE=static PATH="$BIN:$PATH" \
  run_supervisor "$TMP_ROOT/live-no-activity" > "$TMP_ROOT/sup-no-activity.out" 2>&1; then
  fail 'supervisor fails when a send never produces activity'
else
  if grep -F 'supervisor:fail:live_session_stale' "$TMP_ROOT/sup-no-activity.out" >/dev/null \
    && [ "$(cat "$CASE_STATE/send.count")" = "1" ] \
    && [ ! -f "$TMP_ROOT/live-no-activity/LIVE.json" ]; then
    pass 'send-accepted-no-activity fails without re-sending the prompt'
  else fail "supervisor no-activity handling ($(cat "$TMP_ROOT/sup-no-activity.out"))"; fi
fi

# Happy path: ready -> baseline read -> one send -> observed activity -> LIVE
# launch/liveness ack (never completion).
fresh_env sup-happy
mkdir -p "$TMP_ROOT/live-happy"
if ORCA_LIVE_LOG_DIR="$CASE_LOG" ORCA_LIVE_STATE_DIR="$CASE_STATE" ORCA_READ_MODE=grow_after_send PATH="$BIN:$PATH" \
  run_supervisor "$TMP_ROOT/live-happy" > "$TMP_ROOT/sup-happy.out" 2>&1; then
  if [ "$(cat "$CASE_STATE/send.count")" = "1" ] && node - "$TMP_ROOT/live-happy/LIVE.json" "$WT" <<'NODE'
const fs = require("fs");
const value = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (value.execution_mode !== "live-tui" || value.state !== "prompt_started") process.exit(2);
if (value.activity_observed !== true || value.worktree_path !== process.argv[3]) process.exit(2);
if (Object.prototype.hasOwnProperty.call(value, "completion")) process.exit(2);
NODE
  then pass 'supervisor happy path writes non-completion LIVE evidence after observed activity'
  else fail 'supervisor happy path LIVE evidence'; fi
else fail "supervisor happy path ($(cat "$TMP_ROOT/sup-happy.out"))"; fi

# Same-seat relaunch after the live session exists: launch-live refuses, so a
# re-dispatch can never deliver a second prompt to the same seat. (Above the
# adapter seam, dispatch-core's admission markers refuse the same-issue write
# re-dispatch before the transport is ever touched.)
fresh_env dup-after-live
printf '%s\n' '{"result":{"terminals":[{"handle":"term-created","title":"codex-203"}]}}' > "$CASE_STATE/terminals.json"
if ORCA_LIVE_LOG_DIR="$CASE_LOG" ORCA_LIVE_STATE_DIR="$CASE_STATE" PATH="$BIN:$PATH" \
  bash "$ORCA_ADAPTER" launch-live --name "$SEAT" --worktree "$WT" --launch-spec "$CODEX_SPEC" \
  > "$TMP_ROOT/dup-after-live.out" 2>"$TMP_ROOT/dup-after-live.err"; then
  fail 'live seat relaunch refuses duplicate prompt'
else
  if grep -F 'live_seat_already_exists' "$TMP_ROOT/dup-after-live.err" >/dev/null; then
    pass 'an existing live seat cannot be relaunched into a duplicate prompt'
  else fail 'duplicate live seat refusal'; fi
fi

# --- 7. settled-state mapping and artifact authority -------------------------------

SETTLED_SESSION="$TMP_ROOT/settled-session.json"
write_session_json "$SETTLED_SESSION" "term-settled"

settled_case() {
  fresh_env "settled-$1"
  ORCA_LIVE_LOG_DIR="$CASE_LOG" ORCA_LIVE_STATE_DIR="$CASE_STATE" ORCA_WAIT_MODE="$2" PATH="$BIN:$PATH" \
    bash "$ORCA_ADAPTER" wait-settled --session-json "$SETTLED_SESSION" --timeout-ms 1200 > "$TMP_ROOT/settled-$1.out" 2>/dev/null
  printf '%s' "$?"
}

if [ "$(settled_case idle idle)" = "0" ] && grep -F '"settled"' "$TMP_ROOT/settled-idle.out" >/dev/null; then
  pass 'wait-settled maps a satisfied tui-idle to the settled hint'
else fail 'wait-settled idle mapping'; fi

# Non-settled classifications are successful queries with a non-settled state:
# the supervisor (asserted below) turns them into typed failures, never success.
if [ "$(settled_case busy busy)" = "0" ] && grep -F '"working"' "$TMP_ROOT/settled-busy.out" >/dev/null; then
  pass 'wait-settled maps an unsatisfied tui-idle to working (never settled)'
else fail 'wait-settled busy mapping'; fi

if [ "$(settled_case blocked busy_blocked)" = "0" ] && grep -F '"blocked"' "$TMP_ROOT/settled-blocked.out" >/dev/null; then
  pass 'wait-settled surfaces a native blockedReason as blocked'
else fail 'wait-settled blocked mapping'; fi

# Supervisor-level settled mapping and stash policy.
supervisor_state() {
  bash -c '
    . "$1/scripts/lib/live-session-supervisor.sh"
    if live_session_wait_settled "$2" "$3" 1200; then
      printf "ok:%s" "$LIVE_SETTLED_STATE"
    else
      printf "fail:%s" "$LIVE_FAILURE_CODE"
    fi
    if live_session_should_stash; then printf " stash:yes"; else printf " stash:no"; fi
  ' _ "$ROOT" "$ORCA_ADAPTER" "$1"
}

fresh_env sup-settled-blocked
blocked_result="$(ORCA_LIVE_LOG_DIR="$CASE_LOG" ORCA_LIVE_STATE_DIR="$CASE_STATE" ORCA_WAIT_MODE=busy_blocked PATH="$BIN:$PATH" supervisor_state "$SETTLED_SESSION")"
if printf '%s' "$blocked_result" | grep -F 'fail:live_settled_blocked' >/dev/null \
  && printf '%s' "$blocked_result" | grep -F 'stash:no' >/dev/null; then
  pass 'blocked is a typed supervisor failure and never a stash trigger'
else fail "supervisor blocked mapping (got: $blocked_result)"; fi

fresh_env sup-settled-working
working_result="$(ORCA_LIVE_LOG_DIR="$CASE_LOG" ORCA_LIVE_STATE_DIR="$CASE_STATE" ORCA_WAIT_MODE=busy PATH="$BIN:$PATH" supervisor_state "$SETTLED_SESSION")"
if printf '%s' "$working_result" | grep -F 'fail:live_settled_working' >/dev/null; then
  pass 'working is a typed supervisor failure'
else fail "supervisor working mapping (got: $working_result)"; fi

# Idle/settled without a fresh canonical artifact is an output contract
# failure, not success (design §11 item 8): the artifact gate must refuse both
# a missing artifact and an unchanged stale one (item 9).
artifact_gate_case() {
  bash -c '
    . "$1/scripts/lib/live-session-supervisor.sh"
    if live_session_artifact_gate "$2" "$3" "$4" "$5" 400 40; then
      printf "gate:pass"
    else
      printf "gate:fail:%s" "$LIVE_FAILURE_CODE"
    fi
  ' _ "$ROOT" "$ISSUE" "$GATE_WT" "$1" "$2"
}

GATE_WT="$TMP_ROOT/gate-wt"
mkdir -p "$GATE_WT/.review"
missing_result="$(artifact_gate_case "" "")"
if printf '%s' "$missing_result" | grep -F 'gate:fail:live_settled_without_artifact' >/dev/null; then
  pass 'settled without any canonical artifact is a contract failure'
else fail "artifact gate missing-artifact case (got: $missing_result)"; fi

printf '%s\n' '{"schema_version":"1","artifact_type":"codex_run","issue":203,"attempt":1,"started_at":"2026-08-21T00:00:00Z","updated_at":"2026-08-21T00:00:00Z","status":"running"}' > "$GATE_WT/.review/ISSUE-203-RUN.json"
before_sig="$(bash -c '. "$1/scripts/lib/live-session-supervisor.sh"; live_session_artifact_signature "$2"' _ "$ROOT" "$GATE_WT/.review/ISSUE-203-RUN.json")"
stale_result="$(artifact_gate_case "$before_sig" "")"
if printf '%s' "$stale_result" | grep -F 'gate:fail:live_settled_without_artifact' >/dev/null; then
  pass 'an unchanged stale same-issue artifact is ignored by the artifact gate'
else fail "artifact gate stale-artifact case (got: $stale_result)"; fi

sleep 1
node - "$GATE_WT/.review/ISSUE-203-RUN.json" <<'NODE'
const fs = require("fs");
const file = process.argv[2];
const value = JSON.parse(fs.readFileSync(file, "utf8"));
value.started_at = "2026-08-21T00:00:09Z";
fs.writeFileSync(file, JSON.stringify(value, null, 2) + "\n");
NODE
fresh_result="$(artifact_gate_case "$before_sig" "")"
if printf '%s' "$fresh_result" | grep -F 'gate:pass' >/dev/null; then
  pass 'a freshly written canonical artifact passes the completion gate'
else fail "artifact gate fresh-artifact case (got: $fresh_result)"; fi

# --- 8. headless surface unchanged --------------------------------------------------

fresh_env headless-intact
runner_rel=".review/ISSUE-${ISSUE}-launch.fixture/launch.sh"
headless_launch_ec=0
ORCA_LIVE_LOG_DIR="$CASE_LOG" ORCA_LIVE_STATE_DIR="$CASE_STATE" ORCA_CREATE_HANDLE="term-headless" PATH="$BIN:$PATH" \
  bash "$ORCA_ADAPTER" launch --name "$SEAT" --worktree "$WT" --runner-relative "$runner_rel" > "$TMP_ROOT/headless-launch.out" 2>/dev/null \
  || headless_launch_ec=$?
headless_shape_ok=0
if node - "$TMP_ROOT/headless-launch.out" <<'NODE'
const fs = require("fs");
const value = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (value.external_handle !== "term-headless" || value.lifecycle !== "launched") process.exit(2);
NODE
then headless_shape_ok=1; fi
if [ "$headless_launch_ec" -eq 0 ] && [ "$headless_shape_ok" -eq 1 ] \
  && argv_assert "$CASE_LOG/create.1.argv" pair --command "bash $runner_rel"; then
  pass 'headless launch keeps the generated runner command and handle shape'
else fail 'headless launch unchanged'; fi

if ORCA_LIVE_LOG_DIR="$CASE_LOG" ORCA_LIVE_STATE_DIR="$CASE_STATE" PATH="$BIN:$PATH" \
  bash "$ORCA_ADAPTER" inspect --worktree "$WT" --external-handle term-headless 2>/dev/null | grep -F '"lifecycle":"live"' >/dev/null; then
  pass 'headless inspect contract unchanged'
else fail 'headless inspect unchanged'; fi

preview_out="$(bash "$ORCA_ADAPTER" preview --name "$SEAT" --worktree "$WT" --runner-relative "$runner_rel")"
if [ "$preview_out" = "orca launch --name \"$SEAT\" --worktree \"$WT\" --runner-relative \"$runner_rel\"" ]; then
  pass 'headless preview output unchanged'
else fail 'headless preview unchanged'; fi

if [ "$FAILURES" -eq 0 ]; then echo '--- ALL CASES PASS'; exit 0; fi
echo "--- $FAILURES CASE(S) FAILED"; exit 1
