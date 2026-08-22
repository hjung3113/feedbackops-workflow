#!/usr/bin/env bash
# cmux live-tui adapter smoke (issue #203, T4). Offline: drives a fake
# cmux CLI that records every received argv (ADR 0004: doubles assert on
# received input). bash-3.2-compatible.
# Run: bash toolkit/scripts/__tests__/cmux-live.smoke.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ADAPTER="$SCRIPT_DIR/../adapters/cmux.sh"
HANDLES="$SCRIPT_DIR/../adapters/cmux-handles.cjs"
SUPERVISOR="$SCRIPT_DIR/../lib/live-session-supervisor.sh"
TRANSPORT_REGISTRY="$SCRIPT_DIR/../lib/transport-registry.cjs"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
FAILURES=0

pass() { echo "ok   - $1"; }
fail() { echo "NOT OK - $1"; FAILURES=$((FAILURES + 1)); }

FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"
FAKE_LOG="$TMP_DIR/fake-calls.log"
FAKE_RUN_ARGVS="$TMP_DIR/fake-run-argvs.jsonl"
FAKE_SCREEN="$TMP_DIR/fake-screen.txt"
: > "$FAKE_LOG"
: > "$FAKE_RUN_ARGVS"
printf 'fake codex ready> \n' > "$FAKE_SCREEN"

# The fake implements the documented low-level command contract. Modes
# drop exactly one token group at a time so each fail-closed branch is
# exercised against a binary that is otherwise live-capable:
#   full             every live primitive proven
#   no-run           `run` unknown (installed 0.64.x CLI reality)
#   no-pattern-wait  wait-for is only the tmux named-token form
#   no-state         list-agents unknown (wait-settled unadmittable)
#   no-bytes         send lacks byte-exact --bytes delivery
#   installed        no-run + no-pattern-wait + no-state at once
cat > "$FAKE_BIN/cmux" <<'EOF'
#!/usr/bin/env bash
log() { printf '%s\n' "$*" >> "$CMUX_FAKE_LOG"; }
log "-> ${1:-}"
mode="${CMUX_FAKE_MODE:-full}"
case "${1:-}" in
  --version) echo 'cmux 0.65.0-fake'; exit 0 ;;
  workspace)
    if [ "${2:-}" = "create" ] && [ "${3:-}" = "--help" ]; then
      printf '%s\n' 'create [flags]          Create a workspace (same flags as new-workspace)'
      exit 0
    fi
    log "workspace create $*"
    printf '%s\n' '{"id":"workspace:headless"}'
    exit 0
    ;;
  new-workspace)
    [ "${2:-}" = "--help" ] && printf '%s\n' '--cwd PATH --command TEXT'
    exit 0
    ;;
  run)
    if [ "${2:-}" = "--help" ]; then
      case "$mode" in no-run|installed)
        echo "Error: Unknown command 'run'." >&2; exit 2 ;;
      esac
      printf '%s\n' 'Usage: cmux run [--pane <id> | --new-workspace [--key <key>]] [--cwd <path>] [--name <name>] --json -- <argv...>'
      printf '%s\n' 'Spawns argv directly without a shell. The --json result envelope documents the surface, workspace, and terminal_id handles.'
      exit 0
    fi
    shift
    run_cwd=""; run_name=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --cwd) run_cwd="$2"; shift 2 ;;
        --name) run_name="$2"; shift 2 ;;
        --json|--new-workspace) shift ;;
        --) shift; break ;;
        *) shift ;;
      esac
    done
    log "run --new-workspace --cwd $run_cwd --name $run_name --json -- argv:$#"
    node - "$CMUX_FAKE_RUN_ARGVS" "$run_cwd" "$run_name" "$@" <<'FNODE'
const fs = require("fs");
const [file, cwd, name, ...argv] = process.argv.slice(2);
fs.appendFileSync(file, JSON.stringify({ cwd, name, argv }) + "\n");
FNODE
    printf '%s\n' "{\"surface\":\"${CMUX_FAKE_SURFACE:-surface:9}\",\"workspace\":\"${CMUX_FAKE_WORKSPACE:-workspace:4}\",\"terminal_id\":\"terminal-1\",\"pane\":2,\"screen\":3,\"lifecycle\":\"running\",\"exit\":null,\"terminal_revision\":7,\"already_exited\":false}"
    exit 0
    ;;
  send)
    if [ "${2:-}" = "--help" ]; then
      case "$mode" in
        no-bytes) printf '%s\n' 'Usage: cmux send --surface <id> <text>'; ;;
        *) printf '%s\n' 'Usage: cmux send --surface <id> [--text <text>] [--bytes <base64>] [--paste]'; ;;
      esac
      exit 0
    fi
    shift
    send_surface=""; send_b64=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --surface) send_surface="$2"; shift 2 ;;
        --bytes) send_b64="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    if [ -n "$CMUX_FAKE_SEND_FAIL" ]; then
      log "send-failed --surface $send_surface"
      exit 1
    fi
    send_bytes="$(node -e 'process.stdout.write(String(Buffer.from(process.argv[1],"base64").length))' "$send_b64")"
    log "send --surface $send_surface --bytes $send_bytes"
    if [ -n "$send_b64" ] && [ -n "$CMUX_FAKE_ECHO" ]; then
      node - "$CMUX_FAKE_SCREEN" "$send_b64" <<'FNODE'
const fs = require("fs");
fs.appendFileSync(process.argv[2], Buffer.from(process.argv[3], "base64").toString("utf8"));
FNODE
    fi
    exit 0
    ;;
  send-key)
    if [ "${2:-}" = "--help" ]; then
      printf '%s\n' 'Usage: cmux send-key --surface <id> <key>...'
      printf '%s\n' 'Key chords: enter tab escape backspace ctrl+c alt+<key>'
      exit 0
    fi
    shift
    key_surface=""; key_name=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --surface) key_surface="$2"; shift 2 ;;
        *) key_name="$1"; shift ;;
      esac
    done
    log "send-key --surface $key_surface $key_name"
    exit 0
    ;;
  read-screen)
    if [ "${2:-}" = "--help" ]; then
      printf '%s\n' 'Usage: cmux read-screen --surface <id> [--scrollback] [--lines <n>]'
      exit 0
    fi
    shift
    read_surface=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --surface) read_surface="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    if [ "$read_surface" != "${CMUX_FAKE_SURFACE:-surface:9}" ]; then
      echo "Error: unknown surface $read_surface" >&2
      exit 1
    fi
    cat "$CMUX_FAKE_SCREEN"
    exit 0
    ;;
  wait-for)
    if [ "${2:-}" = "--help" ]; then
      case "$mode" in no-pattern-wait|installed)
        printf '%s\n' 'Usage: cmux wait-for [-S|--signal] <name> [--timeout <seconds>]'; ;;
      *)
        printf '%s\n' 'Usage: cmux wait-for --surface <id> --pattern <regex> --timeout-ms <n>'; ;;
      esac
      exit 0
    fi
    shift
    wf_surface=""; wf_pattern=""; wf_timeout=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --surface) wf_surface="$2"; shift 2 ;;
        --pattern) wf_pattern="$2"; shift 2 ;;
        --timeout-ms) wf_timeout="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    log "wait-for --surface $wf_surface --pattern $wf_pattern --timeout-ms $wf_timeout"
    [ "$wf_surface" = "${CMUX_FAKE_SURFACE:-surface:9}" ] || { echo "Error: unknown surface $wf_surface" >&2; exit 1; }
    wf_elapsed=0
    while [ "$wf_elapsed" -lt "$wf_timeout" ]; do
      [ -s "$CMUX_FAKE_SCREEN" ] && exit 0
      sleep 0.05
      wf_elapsed=$((wf_elapsed + 50))
    done
    [ -s "$CMUX_FAKE_SCREEN" ] && exit 0
    exit 1
    ;;
  list-agents)
    case "$mode" in no-state|installed)
      echo "Error: Unknown command 'list-agents'." >&2; exit 2 ;;
    esac
    if [ "${2:-}" = "--help" ]; then
      printf '%s\n' 'Usage: cmux list-agents [--surface <id>] [--state working|blocked|idle|done|unknown] --json'
      printf '%s\n' 'States: working blocked idle done unknown'
      exit 0
    fi
    shift
    la_surface=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --surface) la_surface="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    log "list-agents --surface $la_surface --json"
    printf '%s\n' "{\"agents\":[{\"surface\":\"$la_surface\",\"state\":\"${CMUX_FAKE_AGENT_STATE:-working}\",\"source\":\"hook\",\"session\":\"s1\",\"updated_at_ms\":1}]}"
    exit 0
    ;;
  close-workspace)
    if [ "${2:-}" = "--help" ]; then
      printf '%s\n' 'Usage: cmux close-workspace --workspace <id|ref|index>'
      exit 0
    fi
    shift
    close_ws=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --workspace) close_ws="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    log "close-workspace --workspace $close_ws"
    exit 0
    ;;
  *)
    log "UNEXPECTED $*"
    echo "Error: Unknown command '${1:-}'." >&2
    exit 2
    ;;
esac
EOF
chmod +x "$FAKE_BIN/cmux"

fake_env() {
  CMUX_FAKE_MODE="${FAKE_MODE:-full}" \
  CMUX_FAKE_LOG="$FAKE_LOG" \
  CMUX_FAKE_RUN_ARGVS="$FAKE_RUN_ARGVS" \
  CMUX_FAKE_SCREEN="$FAKE_SCREEN" \
  CMUX_FAKE_AGENT_STATE="${FAKE_AGENT_STATE:-working}" \
  CMUX_FAKE_ECHO="${FAKE_ECHO:-}" \
  CMUX_FAKE_SEND_FAIL="${CMUX_FAKE_SEND_FAIL:-}" \
  PATH="$FAKE_BIN:$PATH" "$@"
}

log_count() {
  [ -f "$FAKE_LOG" ] || { echo 0; return; }
  grep -Fc -- "$1" "$FAKE_LOG" || true
}

# --- fixture: a real git worktree with hostile argv fidelity payloads ---
WT="$TMP_DIR/wt space 'quote"
git init -q "$WT" 2>/dev/null || git init "$WT" >/dev/null 2>&1
git -C "$WT" -c user.name=smoke -c user.email=smoke@example.test commit --allow-empty -qm init
SPEC="$TMP_DIR/live-spec.json"
PROMPT="$TMP_DIR/live-prompt.txt"
printf 'implement the task\nliteral \\n two-char sequence\n$HOME `id`; rm -rf /\n' > "$PROMPT"

# ============================================================
# A. capability token probe (design §11-1)
# ============================================================
cap_json_for() {
  fake_env bash "$ADAPTER" capabilities --worktree "$WT" --probe-live 2>"$TMP_DIR/cap.stderr"
}

FAKE_MODE=full
FULL_CAPS="$(cap_json_for)" \
  && node - "$FULL_CAPS" "$TRANSPORT_REGISTRY" <<'NODE'
const [raw, registry] = process.argv.slice(2);
const v = JSON.parse(raw), required = require(registry).LIVE_CAPABILITIES;
if (v.available !== true || v.reason_code !== "available") process.exit(2);
const caps = v.capabilities;
for (const base of ["workspace.create.cwd", "workspace.create.command", "workspace.list.read_only"]) {
  if (!caps.includes(base)) process.exit(3);
}
for (const live of required) if (!caps.includes(live)) process.exit(4);
NODE
if [ "$?" -eq 0 ]; then pass "full token contract admits headless plus all eight session capabilities"; else fail "full token contract admits headless plus all eight session capabilities ($(cat "$TMP_DIR/cap.stderr" 2>/dev/null): $FULL_CAPS)"; fi

for FAKE_MODE in no-run no-pattern-wait no-state no-bytes installed; do
  MODE_CAPS="$(cap_json_for)" \
    && node - "$MODE_CAPS" <<'NODE'
const v = JSON.parse(process.argv[2]);
if (v.available !== true) process.exit(2);
if (v.capabilities.some(entry => entry.indexOf("session.") === 0)) process.exit(3);
NODE
  mode_status=$?
  if [ "$mode_status" -eq 0 ] && grep -q "cmux live unavailable" "$TMP_DIR/cap.stderr"; then
    pass "mode $FAKE_MODE keeps headless available, live unproven with a named reason"
  else
    fail "mode $FAKE_MODE keeps headless available, live unproven with a named reason (status=$mode_status stderr=$(cat "$TMP_DIR/cap.stderr"))"
  fi
done

if ! PATH="/usr/bin:/bin" bash "$ADAPTER" capabilities --worktree "$WT" 2>/dev/null | grep -q '"available":false'; then
  pass "missing cmux binary reports unavailable"
else
  fail "missing cmux binary reports unavailable"
fi

# Headless purity: the plain capability probe (what dispatch-core issues on
# every dispatch) must not make any live-probe vendor call.
: > "$FAKE_LOG"
FAKE_MODE=full fake_env bash "$ADAPTER" capabilities --worktree "$WT" >/dev/null 2>&1
plain_caps="$(FAKE_MODE=full fake_env bash "$ADAPTER" capabilities --worktree "$WT" 2>/dev/null)"
plain_live_tokens="$(printf '%s' "$plain_caps" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{const v=JSON.parse(d);process.stdout.write(String(v.capabilities.filter(c=>c.indexOf("session.")===0).length))})')"
if [ "$plain_live_tokens" = "0" ] && [ "$(log_count '-> run')" -eq 0 ]; then
  pass "plain capabilities probe emits no session capabilities and issues no live vendor calls"
else
  fail "plain capabilities probe emits no session capabilities and issues no live vendor calls (tokens=$plain_live_tokens run-help-calls=$(log_count '-> run'))"
fi

# ============================================================
# B. direct-argv E2E round-trip through the shared supervisor (§11-2)
# ============================================================
node - "$SPEC" "$WT" <<'NODE'
const fs = require("fs");
const [file, cwd] = process.argv.slice(2);
fs.writeFileSync(file, JSON.stringify({
  runtime: "codex",
  cwd,
  argv: [
    "/fake/bin/codex",
    "--sandbox", "workspace-write",
    "--model", "model with spaces \"quotes\" 'single' $HOME `id`; rm -rf /",
    "-c", "line1\nreal newline\nand literal \\n two-char\ttab",
  ],
  env: {},
  prompt_delivery: "transport",
}));
NODE

LIVE_DIR="$TMP_DIR/live-e2e"
mkdir -p "$LIVE_DIR"
FAKE_MODE=full FAKE_AGENT_STATE=working FAKE_ECHO=1 \
LIVE_WAIT_READY_TIMEOUT_MS=5000 LIVE_SEND_ACTIVITY_TIMEOUT_MS=5000 LIVE_SESSION_TIMEOUT_MS=15000 LIVE_POLL_INTERVAL_MS=20 \
  fake_env bash -c '. "$1" >/dev/null 2>&1; shift; live_session_start "$@"' _ "$SUPERVISOR" \
    "$ADAPTER" cmux codex-203 "$WT" "$SPEC" "$PROMPT" "$LIVE_DIR" 203 >"$TMP_DIR/e2e.out" 2>"$TMP_DIR/e2e.err"
e2e_status=$?
if [ "$e2e_status" -eq 0 ]; then
  pass "supervisor drives cmux launch-live/wait-ready/read/send to observed activity"
else
  fail "supervisor drives cmux launch-live/wait-ready/read/send to observed activity (status=$e2e_status $(cat "$TMP_DIR/e2e.err"))"
fi

node - "$FAKE_RUN_ARGVS" "$SPEC" <<'NODE'
const fs = require("fs");
const [argvsFile, specFile] = process.argv.slice(2);
const records = fs.readFileSync(argvsFile, "utf8").trim().split("\n").map(JSON.parse);
const spec = JSON.parse(fs.readFileSync(specFile, "utf8"));
const run = records.find(entry => entry.argv.length === spec.argv.length);
if (!run) process.exit(2);
if (JSON.stringify(run.argv) !== JSON.stringify(spec.argv)) process.exit(3);
if (run.cwd !== spec.cwd || run.name !== "codex-203") process.exit(4);
NODE
if [ "$?" -eq 0 ]; then
  pass "cmux run receives the spec argv byte-exactly (spaces/quotes/newline/metachars preserved)"
else
  fail "cmux run receives the spec argv byte-exactly (received: $(cat "$FAKE_RUN_ARGVS"))"
fi

if node - "$LIVE_DIR/session.json" <<'NODE'
const fs = require("fs");
const v = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (v.execution_mode !== "live-tui" || v.adapter !== "cmux") process.exit(2);
const h = v.handles;
if (h.lifecycle !== "workspace:4" || h.io !== "surface:9" || h.agent !== "terminal-1") process.exit(3);
if (v.external_handle !== undefined) process.exit(4);
NODE
then pass "launch-live returns structured {workspace,surface,terminal} handles with no collapsing alias"; else fail "launch-live returns structured {workspace,surface,terminal} handles with no collapsing alias"; fi

if node - "$LIVE_DIR/LIVE.json" "$WT" <<'NODE'
const fs = require("fs");
const v = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (v.state !== "prompt_started" || v.activity_observed !== true || v.worktree_path !== process.argv[3]) process.exit(2);
if (Object.prototype.hasOwnProperty.call(v, "completion")) process.exit(3);
NODE
then pass "LIVE.json records prompt-start evidence and never completion"; else fail "LIVE.json records prompt-start evidence and never completion"; fi

if [ "$(log_count 'send --surface surface:9')" -eq 1 ] && [ "$(log_count 'send-key --surface surface:9 enter')" -eq 1 ] \
  && [ "$(log_count 'wait-for --surface surface:9')" -ge 1 ] && [ "$(log_count 'close-workspace')" -eq 0 ]; then
  pass "io primitives target the surface handle exactly once each (send then enter)"
else
  fail "io primitives target the surface handle exactly once each (log: $(cat "$FAKE_LOG"))"
fi

prompt_bytes="$(wc -c < "$PROMPT" | tr -d ' ')"
send_log="$(grep -F 'send --surface surface:9' "$FAKE_LOG" | tail -n 1)"
if [ "${send_log##*--bytes }" = "$prompt_bytes" ]; then
  pass "prompt delivered byte-exactly via --bytes (length $prompt_bytes)"
else
  fail "prompt delivered byte-exactly via --bytes (log=$send_log want-bytes=$prompt_bytes)"
fi

# ============================================================
# C. wait-for pattern is never lifecycle authority (§11-5)
# ============================================================
: > "$FAKE_LOG"
FAKE_MODE=full FAKE_AGENT_STATE=working fake_env bash -c '
  . "$1" >/dev/null 2>&1
  if live_session_wait_settled "$2" "$3" 300; then
    echo "wrongly-settled"
  else
    echo "typed:$LIVE_FAILURE_CODE"
  fi
' _ "$SUPERVISOR" "$ADAPTER" "$LIVE_DIR/session.json" >"$TMP_DIR/settled-working.out" 2>/dev/null
working_out="$(cat "$TMP_DIR/settled-working.out")"
if [ "$working_out" = "typed:live_settled_working" ] && grep -q '^list-agents --surface surface:9 --json$' "$FAKE_LOG" && ! grep -q '^wait-for' "$FAKE_LOG"; then
  pass "wait-settled consults only the agent-state query; screen pattern working state is not settled"
else
  fail "wait-settled consults only the agent-state query (out=$working_out log=$(cat "$FAKE_LOG"))"
fi

: > "$FAKE_LOG"
FAKE_MODE=full FAKE_AGENT_STATE=idle fake_env bash "$ADAPTER" wait-settled --session-json "$LIVE_DIR/session.json" --timeout-ms 500 >"$TMP_DIR/settled-idle.out" 2>&1
if [ "$?" -eq 0 ] && grep -q '"state":"settled"' "$TMP_DIR/settled-idle.out"; then
  pass "idle agent state maps to settled (screen content unchanged)"
else
  fail "idle agent state maps to settled (out=$(cat "$TMP_DIR/settled-idle.out"))"
fi

FAKE_MODE=full FAKE_AGENT_STATE=unknown fake_env bash "$ADAPTER" wait-settled --session-json "$LIVE_DIR/session.json" --timeout-ms 200 >"$TMP_DIR/settled-unknown.out" 2>&1
if [ "$?" -eq 0 ] && grep -q '"state":"stale"' "$TMP_DIR/settled-unknown.out"; then
  pass "unknown agent state is never success evidence (classified stale)"
else
  fail "unknown agent state is never success evidence (out=$(cat "$TMP_DIR/settled-unknown.out"))"
fi

# ============================================================
# D. send accepted but no activity: fail without re-sending (§11-6)
# ============================================================
NOACT_DIR="$TMP_DIR/live-noact"
mkdir -p "$NOACT_DIR"
cp "$SPEC" "$NOACT_DIR/spec.json"
: > "$FAKE_LOG"
FAKE_MODE=full FAKE_ECHO= \
LIVE_WAIT_READY_TIMEOUT_MS=2000 LIVE_SEND_ACTIVITY_TIMEOUT_MS=250 LIVE_SESSION_TIMEOUT_MS=6000 LIVE_POLL_INTERVAL_MS=20 \
  fake_env bash -c '
  . "$1" >/dev/null 2>&1; shift
  if live_session_start "$@"; then
    echo "wrongly-succeeded"
  else
    echo "code:$LIVE_FAILURE_CODE"
  fi
' _ "$SUPERVISOR" \
    "$ADAPTER" cmux codex-203 "$WT" "$NOACT_DIR/spec.json" "$PROMPT" "$NOACT_DIR" 203 >"$TMP_DIR/noact.out" 2>/dev/null
noact_out="$(cat "$TMP_DIR/noact.out")"
if [ "$noact_out" = "code:live_session_stale" ] \
  && [ "$(log_count 'send --surface surface:9')" -eq 1 ] \
  && [ "$(log_count 'send-key --surface surface:9 enter')" -eq 1 ]; then
  pass "accepted send with no activity fails live_session_stale and never re-sends the prompt"
else
  fail "accepted send with no activity fails live_session_stale and never re-sends (out=$noact_out sends=$(log_count 'send --surface surface:9'))"
fi

# Send failure: no enter key after a refused send, no retry.
: > "$FAKE_LOG"
FAKE_MODE=full CMUX_FAKE_SEND_FAIL=1 fake_env bash "$ADAPTER" send --session-json "$LIVE_DIR/session.json" --input-file "$PROMPT" >/dev/null 2>&1
send_fail_status=$?
if [ "$send_fail_status" -ne 0 ] && [ "$(log_count 'send-key --surface')" -eq 0 ] && [ "$(log_count 'send-failed')" -eq 1 ]; then
  pass "failed send propagates without the enter key or a retry"
else
  fail "failed send propagates without the enter key or a retry (status=$send_fail_status log=$(cat "$FAKE_LOG"))"
fi

# ============================================================
# E. blocked handling (§11-7)
# ============================================================
FAKE_MODE=full FAKE_AGENT_STATE=blocked fake_env bash -c '
  . "$1" >/dev/null 2>&1
  if live_session_wait_settled "$2" "$3" 300; then exit 0; else printf "%s" "$LIVE_FAILURE_CODE"; exit 1; fi
' _ "$SUPERVISOR" "$ADAPTER" "$LIVE_DIR/session.json" >"$TMP_DIR/blocked.out" 2>/dev/null
blocked_status=$?
blocked_out="$(cat "$TMP_DIR/blocked.out")"
if [ "$blocked_status" -ne 0 ] && [ "$blocked_out" = "live_settled_blocked" ]; then
  pass "blocked agent state surfaces the typed live_settled_blocked failure"
else
  fail "blocked agent state surfaces the typed live_settled_blocked failure (status=$blocked_status out=$blocked_out)"
fi

# ============================================================
# F. artifact gate: canonical artifacts are the only completion (§11-8/9)
# ============================================================
GATE_WT="$TMP_DIR/gate-wt"
mkdir -p "$GATE_WT/.review"
FAKE_MODE=full fake_env bash -c '
  . "$1" >/dev/null 2>&1
  before_run="$(live_session_artifact_signature "$2/.review/ISSUE-203-RUN.json")"
  before_blocker="$(live_session_artifact_signature "$2/.review/ISSUE-203-BLOCKER.json")"
  if live_session_artifact_gate 203 "$2" "$before_run" "$before_blocker" 300 20; then
    echo "fresh:$LIVE_CANONICAL_ARTIFACT_FRESH"
  else
    echo "stale-timeout:$LIVE_FAILURE_CODE"
  fi
' _ "$SUPERVISOR" "$GATE_WT" >"$TMP_DIR/gate-stale.out" 2>&1
if grep -q 'stale-timeout:live_settled_without_artifact' "$TMP_DIR/gate-stale.out"; then
  pass "no fresh artifact settles as live_settled_without_artifact"
else
  fail "no fresh artifact settles as live_settled_without_artifact (out=$(cat "$TMP_DIR/gate-stale.out"))"
fi

FAKE_MODE=full fake_env bash -c '
  . "$1" >/dev/null 2>&1
  before_run="$(live_session_artifact_signature "$2/.review/ISSUE-203-RUN.json")"
  before_blocker="$(live_session_artifact_signature "$2/.review/ISSUE-203-BLOCKER.json")"
  printf "%s\n" "{\"schema_version\":\"1\",\"artifact_type\":\"codex_run\",\"issue\":203,\"attempt\":1,\"status\":\"running\"}" > "$2/.review/ISSUE-203-RUN.json"
  if live_session_artifact_gate 203 "$2" "$before_run" "$before_blocker" 2000 20; then
    echo "fresh:$LIVE_CANONICAL_ARTIFACT_FRESH"
  else
    echo "unexpected:$LIVE_FAILURE_CODE"
  fi
' _ "$SUPERVISOR" "$GATE_WT" >"$TMP_DIR/gate-fresh.out" 2>&1
if grep -q 'fresh:1' "$TMP_DIR/gate-fresh.out"; then
  pass "a freshly written canonical RUN artifact satisfies the gate"
else
  fail "a freshly written canonical RUN artifact satisfies the gate (out=$(cat "$TMP_DIR/gate-fresh.out"))"
fi

# Stale same-issue artifact: an unchanged signature never satisfies.
FAKE_MODE=full fake_env bash -c '
  . "$1" >/dev/null 2>&1
  before_run="$(live_session_artifact_signature "$2/.review/ISSUE-203-RUN.json")"
  if live_session_artifact_gate 203 "$2" "$before_run" "$(live_session_artifact_signature "$2/.review/ISSUE-203-BLOCKER.json")" 200 20; then
    echo "wrongly-fresh"
  else
    echo "stale-ignored:$LIVE_FAILURE_CODE"
  fi
' _ "$SUPERVISOR" "$GATE_WT" >"$TMP_DIR/gate-unchanged.out" 2>&1
if grep -q 'stale-ignored:live_settled_without_artifact' "$TMP_DIR/gate-unchanged.out"; then
  pass "an unchanged stale same-issue artifact is ignored by the gate"
else
  fail "an unchanged stale same-issue artifact is ignored by the gate (out=$(cat "$TMP_DIR/gate-unchanged.out"))"
fi

# ============================================================
# G. workspace vs surface handle confusion (§11-12)
# ============================================================
live_run_rejects() {
  node "$HANDLES" live-run "$1" >/dev/null 2>&1 && return 1 || return 0
}
if live_run_rejects '{"surface":"surface:9","terminal_id":"t","lifecycle":"running"}'; then
  pass "run envelope without a workspace handle is refused"
else
  fail "run envelope without a workspace handle is refused"
fi
if live_run_rejects '{"surface":null,"workspace":"workspace:4","terminal_id":"t","lifecycle":"exited","already_exited":true}'; then
  pass "already-exited run envelope (null surface) is refused"
else
  fail "already-exited run envelope (null surface) is refused"
fi
if live_run_rejects '{"result":{"surface":"surface:9","workspace":"workspace:4","terminal_id":"t","lifecycle":"running"},"request_id":"req-1"}'; then
  pass "nested id fields are never adopted as run handles"
else
  fail "nested id fields are never adopted as run handles"
fi

printf '%s\n' '{"schema_version":"1","execution_mode":"headless","handles":{"lifecycle":"w","io":"s","agent":"t"}}' > "$TMP_DIR/not-live-session.json"
if node "$HANDLES" live-session "$TMP_DIR/not-live-session.json" >/dev/null 2>&1; then
  fail "non-live-tui session json is refused by the live-session reader"
else
  pass "non-live-tui session json is refused by the live-session reader"
fi

: > "$FAKE_LOG"
FAKE_MODE=full fake_env bash "$ADAPTER" close --session-json "$LIVE_DIR/session.json" >/dev/null 2>&1
if [ "$(log_count 'close-workspace --workspace workspace:4')" -eq 1 ] && [ "$(log_count 'surface:9')" -eq 0 ]; then
  pass "close targets the workspace lifecycle handle, never the io surface"
else
  fail "close targets the workspace lifecycle handle, never the io surface (log=$(cat "$FAKE_LOG"))"
fi

# A session whose io handle points at the workspace id cannot drive I/O.
node - "$TMP_DIR/confused-session.json" <<'NODE'
const fs = require("fs");
fs.writeFileSync(process.argv[2], JSON.stringify({
  schema_version: "1", execution_mode: "live-tui", adapter: "cmux",
  name: "confused", lifecycle: "launched",
  handles: { lifecycle: "workspace:4", io: "workspace:4", agent: "terminal-1" },
  launched_at: "2026-08-21T00:00:00Z",
}));
NODE
FAKE_MODE=full fake_env bash "$ADAPTER" read --session-json "$TMP_DIR/confused-session.json" >"$TMP_DIR/confused-read.out" 2>&1
if [ "$?" -ne 0 ] && grep -q "unknown surface workspace:4" "$TMP_DIR/confused-read.out"; then
  pass "io routed through a workspace handle is rejected by the surface-scoped command"
else
  fail "io routed through a workspace handle is rejected by the surface-scoped command (out=$(cat "$TMP_DIR/confused-read.out"))"
fi

FAKE_MODE=full fake_env bash "$ADAPTER" inspect --session-json "$LIVE_DIR/session.json" >"$TMP_DIR/inspect-live.out" 2>&1
if grep -q '"lifecycle":"live"' "$TMP_DIR/inspect-live.out"; then
  pass "live inspect proves the surface readable"
else
  fail "live inspect proves the surface readable (out=$(cat "$TMP_DIR/inspect-live.out"))"
fi
FAKE_MODE=full fake_env bash "$ADAPTER" inspect --session-json "$TMP_DIR/confused-session.json" >"$TMP_DIR/inspect-stale.out" 2>&1
if grep -q '"lifecycle":"stale"' "$TMP_DIR/inspect-stale.out"; then
  pass "live inspect reports stale for an unreadable surface"
else
  fail "live inspect reports stale for an unreadable surface (out=$(cat "$TMP_DIR/inspect-stale.out"))"
fi

# ============================================================
# H. launch-spec guards the run envelope cannot honor
# ============================================================
node - "$TMP_DIR/spec-env.json" "$WT" <<'NODE'
const fs = require("fs");
fs.writeFileSync(process.argv[2], JSON.stringify({
  runtime: "opencode", cwd: process.argv[3], argv: ["/fake/opencode", "$WT"],
  env: { OPENCODE_CONFIG_CONTENT: "deny-first" }, prompt_delivery: "transport",
}));
NODE
FAKE_MODE=full fake_env bash "$ADAPTER" launch-live --name x --worktree "$WT" --launch-spec "$TMP_DIR/spec-env.json" >"$TMP_DIR/env-guard.out" 2>&1
if [ "$?" -eq 3 ] && grep -q "env delivery" "$TMP_DIR/env-guard.out"; then
  pass "a spec carrying env is refused: the run envelope documents no env delivery"
else
  fail "a spec carrying env is refused (out=$(cat "$TMP_DIR/env-guard.out"))"
fi

node - "$TMP_DIR/spec-initial.json" "$WT" <<'NODE'
const fs = require("fs");
fs.writeFileSync(process.argv[2], JSON.stringify({
  runtime: "codex", cwd: process.argv[3], argv: ["/fake/codex", "do the task"],
  env: {}, prompt_delivery: "initial-argv",
}));
NODE
FAKE_MODE=full fake_env bash "$ADAPTER" launch-live --name x --worktree "$WT" --launch-spec "$TMP_DIR/spec-initial.json" >"$TMP_DIR/initial-guard.out" 2>&1
if [ "$?" -eq 3 ] && grep -q "prompt_delivery transport" "$TMP_DIR/initial-guard.out"; then
  pass "initial-argv prompt delivery is refused (transport delivery only)"
else
  fail "initial-argv prompt delivery is refused (out=$(cat "$TMP_DIR/initial-guard.out"))"
fi

FAKE_MODE=no-run fake_env bash "$ADAPTER" launch-live --name x --worktree "$WT" --launch-spec "$SPEC" >"$TMP_DIR/norun-guard.out" 2>&1
if [ "$?" -eq 3 ] && grep -q "cmux_live_capability_missing" "$TMP_DIR/norun-guard.out"; then
  pass "launch-live on a cmux without the proven run contract fails closed"
else
  fail "launch-live on a cmux without the proven run contract fails closed (out=$(cat "$TMP_DIR/norun-guard.out"))"
fi

# ============================================================
# I. wait-settled without a proven state query (never reports settled)
# ============================================================
FAKE_MODE=no-state fake_env bash "$ADAPTER" wait-settled --session-json "$LIVE_DIR/session.json" --timeout-ms 200 >"$TMP_DIR/nostate.out" 2>&1
if [ "$?" -eq 3 ] && grep -q "never reports settled" "$TMP_DIR/nostate.out"; then
  pass "unproven agent-state query: wait-settled refuses instead of reporting settled"
else
  fail "unproven agent-state query: wait-settled refuses instead of reporting settled (out=$(cat "$TMP_DIR/nostate.out"))"
fi

# ============================================================
# J. dispatch gate ordering and duplicate-prompt prevention (§11-14)
# ============================================================
cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo 'codex-test 1.0'; exit 0 ;;
  --help) printf '%s\n' 'exec --sandbox --cd --add-dir -m -c --ask-for-approval --model --config --output-last-message --json'; exit 0 ;;
  exec) [ "${2:-}" = '--help' ] && printf '%s\n' '--sandbox --cd --model --config --output-last-message --json' && exit 0 ;;
esac
exit 0
EOF
chmod +x "$FAKE_BIN/codex"

DISPATCH_WT="$TMP_DIR/dispatch-wt"
mkdir -p "$DISPATCH_WT/.review"
git init -q "$DISPATCH_WT"
git -C "$DISPATCH_WT" -c user.name=smoke -c user.email=smoke@example.test commit --allow-empty -qm init
DISPATCH_PROMPT="$TMP_DIR/dispatch-prompt.txt"
printf '%s\n' "dispatch prompt body" > "$DISPATCH_PROMPT"
: > "$FAKE_LOG"
: > "$FAKE_RUN_ARGVS"
# dispatch-core now passes --probe-live to the adapter's capability check only
# when --execution-mode live-tui is requested (a prior gap this task
# originally deferred as a follow-up); with a fully-capable fake cmux this
# dispatch should complete live admission and deliver exactly one prompt.
LIVE_WAIT_READY_TIMEOUT_MS=5000 LIVE_SEND_ACTIVITY_TIMEOUT_MS=5000 LIVE_SESSION_TIMEOUT_MS=15000 LIVE_POLL_INTERVAL_MS=20 \
FAKE_MODE=full FAKE_AGENT_STATE=working FAKE_ECHO=1 \
fake_env bash "$ROOT/scripts/dispatch-core.sh" --adapter cmux --runtime codex --role implementation \
  --execution-mode live-tui --issue 204 --worktree "$DISPATCH_WT" --prompt-file "$DISPATCH_PROMPT" \
  --model gpt-5.6-terra --effort low --tier trivial >"$TMP_DIR/dispatch-live.out" 2>&1
dispatch_live_status=$?
dispatch_live_receipt="$DISPATCH_WT/.review/ISSUE-204-TRANSPORT.json"
dispatch_live_json="$(find "$DISPATCH_WT/.review" -name LIVE.json -path '*launch.*' | sed -n '1p')"
if [ "$dispatch_live_status" -eq 0 ] && [ "$(log_count 'run --new-workspace')" -eq 1 ] \
  && [ "$(log_count 'send --surface')" -eq 1 ] && [ "$(log_count 'send-key --surface')" -eq 1 ] \
  && [ -n "$dispatch_live_json" ] \
  && node - "$dispatch_live_receipt" "$dispatch_live_json" <<'NODE'
const fs = require("fs");
const receipt = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const ack = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
if (receipt.schema_version !== "4" || receipt.execution_mode !== "live-tui" || receipt.adapter !== "cmux") process.exit(2);
if (!receipt.handles || !receipt.handles.lifecycle || !receipt.handles.io || !receipt.handles.agent) process.exit(2);
if (receipt.external_handle !== undefined) process.exit(2);
if (ack.state !== "prompt_started" || ack.activity_observed !== true) process.exit(2);
NODE
then
  pass "dispatch delivers live cmux end-to-end once the capability gate proves the live contract"
else
  fail "dispatch live cmux E2E (status=$dispatch_live_status out=$(cat "$TMP_DIR/dispatch-live.out"))"
fi
if ! find "$DISPATCH_WT/.review" -type f -name 'launch.sh' | grep -q .; then
  pass "live cmux dispatch generates no launch.sh runner (design section 7)"
else
  fail "live cmux dispatch must not generate a launch.sh runner"
fi

# Each supervised session receives the prompt exactly once: two sequential
# starts produce two run launches and two sends, never a doubled send into
# one session, and an active session is never re-prompted by a restart.
: > "$FAKE_LOG"
SECOND_DIR="$TMP_DIR/live-second"
mkdir -p "$SECOND_DIR"
FAKE_MODE=full FAKE_AGENT_STATE=working FAKE_ECHO=1 \
LIVE_WAIT_READY_TIMEOUT_MS=5000 LIVE_SEND_ACTIVITY_TIMEOUT_MS=5000 LIVE_SESSION_TIMEOUT_MS=15000 LIVE_POLL_INTERVAL_MS=20 \
  fake_env bash -c '. "$1" >/dev/null 2>&1; shift; live_session_start "$@"' _ "$SUPERVISOR" \
    "$ADAPTER" cmux codex-203 "$WT" "$SPEC" "$PROMPT" "$SECOND_DIR" 203 >/dev/null 2>&1
second_status=$?
if [ "$second_status" -eq 0 ] \
  && [ "$(log_count 'run --new-workspace')" -eq 1 ] \
  && [ "$(log_count 'send --surface surface:9')" -eq 1 ] \
  && [ "$(log_count 'send-key --surface surface:9 enter')" -eq 1 ]; then
  pass "a fresh live session sends the prompt exactly once per session"
else
  fail "a fresh live session sends the prompt exactly once per session (status=$second_status sends=$(log_count 'send --surface surface:9'))"
fi

if [ "$FAILURES" -eq 0 ]; then echo '--- ALL CASES PASS'; exit 0; fi
echo "--- $FAILURES CASE(S) FAILED"; exit 1
