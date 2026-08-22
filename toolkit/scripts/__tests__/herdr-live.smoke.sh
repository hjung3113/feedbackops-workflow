#!/usr/bin/env bash
# Herdr live-TUI adapter smoke (issue #203 T3). Drives adapters/herdr.sh
# live subcommands against a stateful fake herdr CLI that records every
# received argv (stub capture contract, ADR 0004) and simulates the native
# agent-facade semantics, including the fresh/untrusted-worktree
# trust-prompt race that gates the live capability itself.
# bash-3.2-compatible.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ADAPTER="$ROOT/scripts/adapters/herdr.sh"
SUPERVISOR="$ROOT/scripts/lib/live-session-supervisor.sh"
TRANSPORT_REGISTRY="$ROOT/scripts/lib/transport-registry.cjs"
. "$SCRIPT_DIR/lib/stub-argv.sh"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
FAILURES=0

pass() { echo "ok   - $1"; }
fail() { echo "NOT OK - $1"; FAILURES=$((FAILURES + 1)); }

BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"
make_stub_capture_helper "$TMP_ROOT/stub-capture.sh"
export STUB_CAPTURE_HELPER="$TMP_ROOT/stub-capture.sh"
STUB_ARGS="$TMP_ROOT/herdr-argv.log"
export STUB_ARGS_LOG="$STUB_ARGS"

# Stateful fake herdr. Behavior modes come from HERDR_FAKE_* env vars; every
# invocation records its full "$*" line through the shared stub capture, and
# the agent-facade commands additionally record exact NUL-delimited argv so
# token boundaries (spaces/quotes/newlines) are provable.
cat > "$BIN/herdr" <<'EOF'
#!/usr/bin/env bash
. "${STUB_CAPTURE_HELPER:-/dev/null}"
set -u
STATE="${HERDR_FAKE_STATE:?}"
SCREEN="${HERDR_FAKE_SCREEN:?}"
mkdir -p "$STATE"
agent_json() {
  printf '{"result":{"agent":{"name":"%s","pane_id":"%s","agent_status":"%s"}}}\n' "$1" "$2" "$3"
}
error_json() {
  printf '{"error":{"code":"%s","message":"%s"}}\n' "$1" "$2" >&2
  exit 1
}
case "${1:-}" in
  --version) printf '%s\n' "${HERDR_FAKE_VERSION:-0.8.0}"; exit 0 ;;
  workspace)
    case "${2:-}" in
      --help) printf '%s\n' 'Commands: create get close'; exit 0 ;;
      create)
        if [ "${3:-}" = '--help' ]; then
          case "${HERDR_FAKE_CREATE_HELP:-full}" in
            missing_env_dash) printf '%s\n' 'workspace create --cwd PATH --label LABEL --no-focus'; exit 0 ;;
            *) printf '%s\n' 'workspace create --cwd PATH --label LABEL --no-focus'; exit 0 ;;
          esac
        fi
        create_cwd=""; create_label=""
        shift 2
        while [ $# -gt 0 ]; do
          case "$1" in --cwd) create_cwd="$2"; shift 2 ;; --label) create_label="$2"; shift 2 ;; *) shift ;; esac
        done
        printf '%s\n' "$create_cwd" >> "$STATE/create-cwd.log"
        printf '%s\n' "$create_label" >> "$STATE/create-label.log"
        case "$create_label" in
          agent-workflow-trust-probe) create_ws="ws-trust"; create_pane="w1:trust"; create_kind="trust" ;;
          *) create_ws="ws-live"; create_pane="w1:live"; create_kind="live" ;;
        esac
        printf '%s\n' "$create_ws" > "$STATE/ws-$create_kind.id"
        node - "$create_ws" "$create_label" "$create_pane" "$create_cwd" <<'NODE'
const [ws, label, pane, cwd] = process.argv.slice(2);
process.stdout.write(JSON.stringify({ id: "request-1", result: { type: "workspace_created", workspace: { workspace_id: ws, label }, root_pane: { pane_id: pane, workspace_id: ws, cwd } } }) + "\n");
NODE
        exit 0 ;;
      get)
        if [ "${3:-}" = '--help' ]; then printf '%s\n' 'Usage: herdr workspace get ID'; exit 0; fi
        case "${HERDR_FAKE_INSPECT:-live}" in
          live) node - "${3:-}" <<'NODE'
const id = process.argv[2];
process.stdout.write(JSON.stringify({ result: { type: "workspace_info", workspace: { workspace_id: id, label: "seat" } } }) + "\n");
NODE
          exit 0 ;;
          stale) error_json workspace_not_found 'workspace was not found' ;;
        esac
        exit 9 ;;
      close)
        if [ "${3:-}" = '--help' ]; then printf '%s\n' 'Usage: herdr workspace close ID'; exit 0; fi
        printf '%s\n' "${3:-}" >> "$STATE/close.log"
        [ "${HERDR_FAKE_CLOSE:-success}" = 'success' ] || exit 9
        exit 0 ;;
      list) printf '%s\n' '{"result":{"type":"workspace_list","workspaces":[]}}'; exit 0 ;;
    esac
    exit 9 ;;
  pane)
    case "${2:-}" in
      --help) printf '%s\n' 'Commands: run'; exit 0 ;;
      run)
        if [ "${3:-}" = '--help' ]; then printf '%s\n' 'Usage: herdr pane run PANE COMMAND'; exit 0; fi
        printf '%s\n' "${3:-} ${4:-}" >> "$STATE/trust-pane-run.log"
        [ "${HERDR_FAKE_PANE_RUN:-success}" = 'success' ] || exit 3
        exit 0 ;;
    esac
    exit 9 ;;
  agent)
    case "${2:-}" in
      --help)
        case "${HERDR_FAKE_AGENT_HELP:-full}" in
          missing_get) printf '%s\n' 'Commands: start prompt wait read send-keys' ;;
          *) printf '%s\n' 'Commands: start prompt wait read send-keys get' ;;
        esac
        exit 0 ;;
      start)
        if [ "${3:-}" = '--help' ]; then
          case "${HERDR_FAKE_START_HELP:-full}" in
            missing_kind) printf '%s\n' 'Usage: herdr agent start NAME --pane PANE --env ENV --timeout MS -- ARGS' ;;
            no_env) printf '%s\n' 'Usage: herdr agent start NAME --kind KIND --pane PANE --timeout MS -- ARGS' ;;
            *) printf '%s\n' 'Usage: herdr agent start NAME --kind KIND --pane PANE --env ENV --timeout MS -- ARGS' ;;
          esac
          exit 0
        fi
        printf '%s\0' "$@" >> "$STATE/agent-start-full.nul"
        dash_seen=0
        for arg in "$@"; do
          [ "$dash_seen" -eq 1 ] && printf '%s\0' "$arg" >> "$STATE/agent-start-args.nul"
          [ "$arg" = '--' ] && dash_seen=1
        done
        [ "${HERDR_FAKE_START:-success}" = 'success' ] || error_json agent_start_failed 'agent start rejected'
        agent_json "${3:-}" "w1:live" idle
        exit 0 ;;
      prompt)
        if [ "${3:-}" = '--help' ]; then
          case "${HERDR_FAKE_PROMPT_HELP:-full}" in
            missing_wait) printf '%s\n' 'Usage: herdr agent prompt NAME PROMPT --timeout MS' ;;
            *) printf '%s\n' 'Usage: herdr agent prompt NAME PROMPT --wait --timeout MS [--until STATE]' ;;
          esac
          exit 0
        fi
        count=0
        [ -f "$STATE/prompt.count" ] && count="$(cat "$STATE/prompt.count")"
        count=$((count + 1))
        printf '%s\n' "$count" > "$STATE/prompt.count"
        printf '%s\0' "${4:-}" >> "$STATE/prompt-bodies.nul"
        case "${HERDR_FAKE_PROMPT:-success}" in
          success)
            printf '%s\n' 'turn output: activity observed' >> "$SCREEN"
            agent_json "${3:-}" "w1:live" idle
            exit 0
            ;;
          stalled) error_json agent_prompt_stalled 'no lifecycle change after prompt' ;;
          timeout) error_json timeout 'wait timed out' ;;
        esac
        exit 9 ;;
      wait)
        if [ "${3:-}" = '--help' ]; then printf '%s\n' 'Usage: herdr agent wait NAME --until STATE --timeout MS'; exit 0; fi
        shift 2
        wait_target="${1:-}"
        shift
        wait_until_count=0
        wait_timeout=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --until) wait_until_count=$((wait_until_count + 1)); shift 2 ;;
            --timeout) wait_timeout="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        printf '%s\n' "$wait_target $wait_until_count $wait_timeout" >> "$STATE/wait-calls.log"
        if [ "$wait_until_count" -eq 1 ]; then
          # Trust-race acceptance probe: exactly one --until (blocked).
          case "${HERDR_FAKE_TRUST:-pass}" in
            pass) agent_json trust-probe "w1:trust" blocked; exit 0 ;;
            race) error_json timeout 'agent stayed idle' ;;
            unproven) error_json server_error 'classification unavailable' ;;
          esac
          exit 9
        fi
        if [ "$wait_until_count" -eq 2 ]; then
          # wait-ready: --until idle --until blocked.
          case "${HERDR_FAKE_READY:-idle}" in
            idle) agent_json "$wait_target" "w1:live" idle; exit 0 ;;
            blocked) agent_json "$wait_target" "w1:live" blocked; exit 0 ;;
            legacy-status) printf '{"result":{"agent":{"name":"%s","pane_id":"%s","status":"%s"}}}\n' "$wait_target" "w1:live" idle; exit 0 ;;
          esac
          exit 9
        fi
        # wait-settled: --until idle --until done --until blocked.
        case "${HERDR_FAKE_SETTLED_MODE:-state}" in
          timeout) error_json timeout 'still settling' ;;
          legacy-status) printf '{"result":{"agent":{"name":"%s","pane_id":"%s","status":"%s"}}}\n' "$wait_target" "w1:live" "${HERDR_FAKE_SETTLED:-idle}"; exit 0 ;;
          notrunning) error_json agent_not_running 'agent exited' ;;
          *) agent_json "$wait_target" "w1:live" "${HERDR_FAKE_SETTLED:-idle}"; exit 0 ;;
        esac
        exit 9 ;;
      read)
        if [ "${3:-}" = '--help' ]; then printf '%s\n' 'Usage: herdr agent read NAME --source SOURCE --lines N'; exit 0; fi
        printf '%s\n' "$*" >> "$STATE/read-args.log"
        cat "$SCREEN"
        exit 0 ;;
      send-keys)
        if [ "${3:-}" = '--help' ]; then
          case "${HERDR_FAKE_SENDKEYS_HELP:-full}" in
            missing_esc) printf '%s\n' 'Usage: herdr agent send-keys NAME KEY (enter|ctrl+c)' ;;
            *) printf '%s\n' 'Usage: herdr agent send-keys NAME KEY (esc|enter|ctrl+c)' ;;
          esac
          exit 0
        fi
        printf '%s\n' "$*" >> "$STATE/send-keys.log"
        exit 0 ;;
      get)
        case "${HERDR_FAKE_GET:-ok}" in
          ok) agent_json "${3:-}" "w1:live" "${HERDR_FAKE_GET_STATE:-working}"; exit 0 ;;
          gone) error_json agent_not_running 'agent not running' ;;
        esac
        exit 9 ;;
    esac
    exit 9 ;;
esac
exit 9
EOF
chmod +x "$BIN/herdr"

fake_state() {
  FAKE_STATE="$TMP_ROOT/state-$1"
  HERDR_SCREEN="$TMP_ROOT/screen-$1.txt"
  rm -rf "$FAKE_STATE"; mkdir -p "$FAKE_STATE"
  printf 'agent idle screen baseline\n' > "$HERDR_SCREEN"
  : > "$STUB_ARGS"
}

herdr_env() {
  HERDR_ENV=1
  HERDR_WORKSPACE_ID=fake-workspace
  HERDR_TAB_ID=fake-tab
  HERDR_PANE_ID=fake-pane
  HERDR_FAKE_STATE="$FAKE_STATE"
  HERDR_FAKE_SCREEN="$HERDR_SCREEN"
  export HERDR_ENV HERDR_WORKSPACE_ID HERDR_TAB_ID HERDR_PANE_ID HERDR_FAKE_STATE HERDR_FAKE_SCREEN
}

capabilities_json() {
  HERDR_ENV=1 HERDR_WORKSPACE_ID=fake-workspace HERDR_TAB_ID=fake-tab HERDR_PANE_ID=fake-pane \
    HERDR_FAKE_STATE="$FAKE_STATE" HERDR_FAKE_SCREEN="$HERDR_SCREEN" \
    PATH="$BIN:$PATH" bash "$ADAPTER" capabilities --worktree "$TMP_ROOT" "$@" 2>/dev/null
}

live_session_capability_count() {
  node - "$1" <<'NODE'
const fs = require("fs");
try {
  const value = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  const required = ["session.live.launch","session.ready.wait","session.input.send","session.output.read","session.activity.observe","session.state.wait","session.interrupt","session.close"];
  process.stdout.write(String(required.filter(entry => value.capabilities.indexOf(entry) !== -1).length));
} catch (error) { process.stdout.write("0"); }
NODE
}

make_session_json() {
  node - "$1" <<'NODE'
const fs = require("fs");
const state = process.argv[2];
fs.writeFileSync(state, JSON.stringify({
  schema_version: "1",
  execution_mode: "live-tui",
  adapter: "herdr",
  name: "codex-203",
  worktree_path: "/tmp/herdr-live-smoke-wt",
  lifecycle: "launched",
  handles: { lifecycle: "ws-live", io: "w1:live", agent: "codex-203" },
  launched_at: "2026-08-21T00:00:00Z",
  external_handle: "ws-live",
}, null, 2) + "\n");
NODE
}

# --- Capabilities: live offered only when tokens + trust race pass ---------

fake_state caps-headless-only
caps_out="$TMP_ROOT/caps-headless-only.json"
capabilities_json > "$caps_out"
if [ "$(live_session_capability_count "$caps_out")" = 0 ] \
  && grep -q '"available":true' "$caps_out" \
  && [ ! -f "$FAKE_STATE/trust-pane-run.log" ] \
  && [ ! -s "$FAKE_STATE/close.log" ]; then
  pass 'plain capabilities (no --probe-live) never runs the trust-race probe and stays side-effect-free'
else
  fail "plain capabilities leaked a live probe side effect ($(cat "$caps_out"))"
fi

fake_state caps-pass
caps_out="$TMP_ROOT/caps-pass.json"
capabilities_json --probe-live > "$caps_out"
if [ "$(live_session_capability_count "$caps_out")" = 8 ] \
  && grep -q 'agent.start' "$caps_out" && grep -q 'pane.run' "$caps_out" \
  && grep -q '"available":true' "$caps_out"; then
  pass 'capabilities offer the full live contract when tokens and trust race pass'
else
  fail "capabilities live pass ($(cat "$caps_out"))"
fi
if grep -q -- '--trust-probe' "$FAKE_STATE/trust-pane-run.log" 2>/dev/null \
  && grep -q '/agent-workflow-trust-probe/codex' "$FAKE_STATE/trust-pane-run.log" 2>/dev/null \
  && grep -qx 'ws-trust' "$FAKE_STATE/close.log" 2>/dev/null; then
  pass 'trust-race acceptance test runs the fresh-dir sentinel and cleans its workspace up'
else
  fail 'trust-race acceptance test protocol (sentinel pane run or cleanup missing)'
fi
leftover="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'herdr-trust-probe.*' -print 2>/dev/null | wc -l | tr -d ' ')"
if [ "$leftover" = 0 ]; then
  pass 'trust-race probe leaves no temporary worktree behind'
else
  fail "trust-race probe leaked $leftover temp dir(s)"
fi

for trust_case in race unproven; do
  fake_state "caps-$trust_case"
  caps_out="$TMP_ROOT/caps-$trust_case.json"
  HERDR_FAKE_TRUST="$trust_case" capabilities_json --probe-live > "$caps_out"
  if grep -q '"available":true' "$caps_out" \
    && [ "$(live_session_capability_count "$caps_out")" = 0 ] \
    && grep -q 'workspace.create.cwd' "$caps_out"; then
    pass "trust-race $trust_case leaves live unavailable while headless stays intact"
  else
    fail "trust-race $trust_case capabilities ($(cat "$caps_out"))"
  fi
done

for token_case in missing-prompt-wait missing-get missing-kind missing-esc; do
  fake_state "caps-$token_case"
  caps_out="$TMP_ROOT/caps-$token_case.json"
  case "$token_case" in
    missing-prompt-wait) token_env_var="HERDR_FAKE_PROMPT_HELP"; token_env_val="missing_wait" ;;
    missing-get) token_env_var="HERDR_FAKE_AGENT_HELP"; token_env_val="missing_get" ;;
    missing-kind) token_env_var="HERDR_FAKE_START_HELP"; token_env_val="missing_kind" ;;
    missing-esc) token_env_var="HERDR_FAKE_SENDKEYS_HELP"; token_env_val="missing_esc" ;;
  esac
  export "$token_env_var=$token_env_val"
  capabilities_json --probe-live > "$caps_out"
  unset "$token_env_var"
  if grep -q '"available":true' "$caps_out" \
    && [ "$(live_session_capability_count "$caps_out")" = 0 ] \
    && [ ! -f "$FAKE_STATE/trust-pane-run.log" ]; then
    pass "missing agent-facade token ($token_case) disables live only, without running the trust probe"
  else
    fail "missing token case $token_case ($(cat "$caps_out"))"
  fi
done

# --- launch-live: argv fidelity, kind forwarding, cleanup -------------------

make_worktree() {
  make_base="$TMP_ROOT/base-$1"
  make_wt="$TMP_ROOT/wt-$1"
  git init -q "$make_base"
  git -C "$make_base" config user.email t3@example.invalid
  git -C "$make_base" config user.name t3
  printf '%s\n' base > "$make_base/file.txt"
  git -C "$make_base" add file.txt
  git -C "$make_base" commit -qm initial
  git -C "$make_base" worktree add -q "$make_wt" HEAD
}

make_worktree launch
SPEC="$TMP_ROOT/spec.json"
node - "$SPEC" "$TMP_ROOT/wt-launch" <<'NODE'
const fs = require("fs");
const [file, wt] = process.argv.slice(2);
const tokens = ["/bin/codex", "--model", "m with spaces \"quotes\" 'semi; $()'", "line\nbreak\ttab"];
fs.writeFileSync(file, JSON.stringify({ runtime: "codex", cwd: wt, argv: tokens, env: { OPENCODE_CONFIG_CONTENT: "deny *" }, prompt_delivery: "transport" }));
fs.writeFileSync(file + ".expected", tokens.map(token => token + "\0").join(""));
NODE

fake_state launch
launch_out="$TMP_ROOT/launch.out"
herdr_env
PATH="$BIN:$PATH" bash "$ADAPTER" launch-live --name codex-203 --worktree "$TMP_ROOT/wt-launch" --launch-spec "$SPEC" > "$launch_out" 2>"$TMP_ROOT/launch.err"
launch_ec=$?
expected_start="$TMP_ROOT/agent-start.expected.nul"
printf '%s\0' agent start codex-203 --kind codex --pane w1:live --timeout 120000 --env 'OPENCODE_CONFIG_CONTENT=deny *' -- > "$expected_start"
cat "$SPEC.expected" >> "$expected_start"
if [ "$launch_ec" -eq 0 ] \
  && cmp -s "$FAKE_STATE/agent-start-full.nul" "$expected_start" \
  && node - "$launch_out" <<'NODE'
const value = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8"));
if (value.lifecycle !== "launched" || value.external_handle !== "ws-live") process.exit(2);
if (value.handles.lifecycle !== "ws-live" || value.handles.io !== "w1:live" || value.handles.agent !== "codex-203") process.exit(2);
NODE
then
  pass 'launch-live forwards workspace create + exact NUL-checked agent start argv and emits structured handles'
else
  fail "launch-live argv/handles (ec=$launch_ec $(cat "$launch_out") $(cat "$TMP_ROOT/launch.err"))"
fi

# --kind is spec data forwarded verbatim, never a runtime-name branch.
node - "$TMP_ROOT/spec-alien.json" "$TMP_ROOT/wt-launch" <<'NODE'
const fs = require("fs");
const [file, wt] = process.argv.slice(2);
fs.writeFileSync(file, JSON.stringify({ runtime: "zylophontest", cwd: wt, argv: ["/bin/zylo"], env: {}, prompt_delivery: "transport" }));
NODE
fake_state launch-alien
herdr_env
PATH="$BIN:$PATH" bash "$ADAPTER" launch-live --name seat-nine --worktree "$TMP_ROOT/wt-launch" --launch-spec "$TMP_ROOT/spec-alien.json" >/dev/null 2>&1
if grep -q -- '--kind zylophontest --pane' "$STUB_ARGS" && ! grep -q -- '--kind codex --pane w1:live --timeout 120000 -- -- /bin/zylo' "$STUB_ARGS"; then
  pass 'launch-live forwards an unregistered spec runtime as --kind data without branching'
else
  fail 'launch-live --kind spec-data forwarding'
fi

# Non-empty spec env requires the --env token on agent start.
fake_state launch-envless
herdr_env
HERDR_FAKE_START_HELP=no_env PATH="$BIN:$PATH" bash "$ADAPTER" launch-live --name codex-203 --worktree "$TMP_ROOT/wt-launch" --launch-spec "$SPEC" >"$TMP_ROOT/envless.out" 2>"$TMP_ROOT/envless.err"
envless_ec=$?
if [ "$envless_ec" -eq 2 ] && grep -q 'herdr_agent_env_unsupported' "$TMP_ROOT/envless.err" \
  && [ ! -f "$FAKE_STATE/create-cwd.log" ]; then
  pass 'launch-live refuses spec env without a proven --env token and creates no workspace'
else
  fail "launch-live env refusal (ec=$envless_ec $(cat "$TMP_ROOT/envless.err"))"
fi

# agent start failure closes the created workspace (no leaked seat).
fake_state launch-fail
herdr_env
HERDR_FAKE_START=fail PATH="$BIN:$PATH" bash "$ADAPTER" launch-live --name codex-203 --worktree "$TMP_ROOT/wt-launch" --launch-spec "$TMP_ROOT/spec-alien.json" >/dev/null 2>"$TMP_ROOT/startfail.err"
startfail_ec=$?
if [ "$startfail_ec" -ne 0 ] && grep -qx 'ws-live' "$FAKE_STATE/close.log"; then
  pass 'launch-live closes the workspace when agent start fails'
else
  fail "launch-live start-failure cleanup (ec=$startfail_ec close=$(cat "$FAKE_STATE/close.log" 2>/dev/null))"
fi

# Invalid herdr agent name and spec/worktree mismatch refuse before create.
fake_state launch-badname
herdr_env
PATH="$BIN:$PATH" bash "$ADAPTER" launch-live --name 'BAD NAME' --worktree "$TMP_ROOT/wt-launch" --launch-spec "$SPEC" >/dev/null 2>"$TMP_ROOT/badname.err"
badname_ec=$?
node - "$TMP_ROOT/spec-mismatch.json" "$TMP_ROOT/wt-launch" <<'NODE'
const fs = require("fs");
const [file, wt] = process.argv.slice(2);
fs.writeFileSync(file, JSON.stringify({ runtime: "codex", cwd: wt + "/..", argv: ["/bin/codex"], env: {}, prompt_delivery: "transport" }));
NODE
fake_state launch-mismatch
herdr_env
PATH="$BIN:$PATH" bash "$ADAPTER" launch-live --name codex-203 --worktree "$TMP_ROOT/wt-launch" --launch-spec "$TMP_ROOT/spec-mismatch.json" >/dev/null 2>"$TMP_ROOT/mismatch.err"
mismatch_ec=$?
if [ "$badname_ec" -eq 2 ] && grep -q 'herdr_agent_name_invalid' "$TMP_ROOT/badname.err" \
  && [ "$mismatch_ec" -eq 2 ] && grep -q 'herdr_launch_spec_worktree_mismatch' "$TMP_ROOT/mismatch.err"; then
  pass 'launch-live refuses invalid agent names and spec/worktree mismatch before any workspace create'
else
  fail 'launch-live name/mismatch refusals'
fi

# --- wait-ready: never trust agent start exit 0 -----------------------------

SESSION="$TMP_ROOT/session.json"
make_session_json "$SESSION"

for ready_case in idle blocked legacy-status timeout; do
  fake_state "ready-$ready_case"
  herdr_env
  HERDR_FAKE_READY="$ready_case" PATH="$BIN:$PATH" bash "$ADAPTER" wait-ready --session-json "$SESSION" --timeout-ms 4000 >"$TMP_ROOT/ready-$ready_case.out" 2>"$TMP_ROOT/ready-$ready_case.err"
  ready_ec=$?
  case "$ready_case" in
    idle) ready_want=0; ready_code='' ;;
    blocked) ready_want=1; ready_code='herdr_agent_blocked_before_ready' ;;
    legacy-status) ready_want=1; ready_code='herdr_agent_ready_state_invalid' ;;
    timeout) ready_want=1; ready_code='herdr_agent_not_ready:timeout' ;;
  esac
  ready_ok=0
  [ "$ready_ec" -eq "$ready_want" ] && ready_ok=1
  [ -n "$ready_code" ] && { grep -q "$ready_code" "$TMP_ROOT/ready-$ready_case.err" || ready_ok=0; }
  if grep -q -- '--until idle --until blocked --timeout 4000' "$STUB_ARGS"; then :; else ready_ok=0; fi
  if [ "$ready_ok" -eq 1 ]; then
    pass "wait-ready $ready_case is classified with the native lifecycle wait"
  else
    fail "wait-ready $ready_case (ec=$ready_ec $(cat "$TMP_ROOT/ready-$ready_case.err"))"
  fi
done

# --- send: native prompt-stall, no duplicate prompt body --------------------

PROMPT_FILE="$TMP_ROOT/prompt.txt"
printf 'implement the trust gate\nbody "with quotes" and $hell\n' > "$PROMPT_FILE"
PROMPT_BODY="$(cat "$PROMPT_FILE")"

send_case() {
  send_name="$1"; send_want_ec="$2"; send_want_stderr="$3"
  fake_state "send-$send_name"
  herdr_env
  HERDR_FAKE_PROMPT="$send_name" PATH="$BIN:$PATH" bash "$ADAPTER" send --session-json "$SESSION" --input-file "$PROMPT_FILE" >"$TMP_ROOT/send-$send_name.out" 2>"$TMP_ROOT/send-$send_name.err"
  send_ec=$?
  send_count="$(cat "$FAKE_STATE/prompt.count" 2>/dev/null || printf '%s' 0)"
  send_body_ok=0
  [ -f "$FAKE_STATE/prompt-bodies.nul" ] && { printf '%s\0' "$PROMPT_BODY" | cmp -s - "$FAKE_STATE/prompt-bodies.nul" && send_body_ok=1; }
  send_ok=0
  [ "$send_ec" -eq "$send_want_ec" ] && [ "$send_count" = 1 ] && [ "$send_body_ok" -eq 1 ] && send_ok=1
  if [ -n "$send_want_stderr" ]; then
    grep -q "$send_want_stderr" "$TMP_ROOT/send-$send_name.err" || send_ok=0
  else
    [ -s "$TMP_ROOT/send-$send_name.err" ] && send_ok=0
  fi
  if grep -q -- '--wait --timeout 15000' "$STUB_ARGS"; then :; else send_ok=0; fi
  if [ "$send_ok" -eq 1 ]; then
    pass "send $send_name keeps one exact prompt body through agent prompt --wait"
  else
    fail "send $send_name (ec=$send_ec count=$send_count body=$send_body_ok $(cat "$TMP_ROOT/send-$send_name.err"))"
  fi
}
send_case success 0 ''
send_case stalled 1 'herdr_agent_prompt_stalled'

# timeout-then-working: the wait window expired mid-turn; activity is proven
# through agent get and the prompt is never re-sent.
fake_state send-timeout-working
herdr_env
HERDR_FAKE_PROMPT=timeout HERDR_FAKE_GET=ok HERDR_FAKE_GET_STATE=working \
  PATH="$BIN:$PATH" bash "$ADAPTER" send --session-json "$SESSION" --input-file "$PROMPT_FILE" >/dev/null 2>"$TMP_ROOT/send-tw.err"
tw_ec=$?
tw_count="$(cat "$FAKE_STATE/prompt.count")"
if [ "$tw_ec" -eq 0 ] && [ "$tw_count" = 1 ]; then
  pass 'send timeout with observed working state succeeds without re-sending'
else
  fail "send timeout-then-working (ec=$tw_ec count=$tw_count)"
fi

# timeout-then-gone: turn never started; typed failure, still one prompt.
fake_state send-timeout-gone
herdr_env
HERDR_FAKE_PROMPT=timeout HERDR_FAKE_GET=gone \
  PATH="$BIN:$PATH" bash "$ADAPTER" send --session-json "$SESSION" --input-file "$PROMPT_FILE" >/dev/null 2>"$TMP_ROOT/send-tg.err"
tg_ec=$?
tg_count="$(cat "$FAKE_STATE/prompt.count")"
if [ "$tg_ec" -eq 1 ] && grep -q 'herdr_agent_send_unconfirmed' "$TMP_ROOT/send-tg.err" && [ "$tg_count" = 1 ]; then
  pass 'send timeout with a dead agent fails typed and never duplicates the prompt body'
else
  fail "send timeout-then-gone (ec=$tg_ec count=$tg_count)"
fi

# Mutation check: the single-prompt counter really increments when the fake
# is prompted again, so count=1 above proves the adapter sent exactly once.
fake_state send-counter-mutation
herdr_env
PATH="$BIN:$PATH" bash -c 'herdr agent prompt codex-203 body-one --wait --timeout 15000' >/dev/null 2>&1
PATH="$BIN:$PATH" bash -c 'herdr agent prompt codex-203 body-two --wait --timeout 15000' >/dev/null 2>&1
if [ "$(cat "$FAKE_STATE/prompt.count")" = 2 ]; then
  pass 'prompt counter mutation check: a second prompt would be visible'
else
  fail 'prompt counter mutation check'
fi

# --- read: stable envelope, real-change activity evidence -------------------

fake_state read-stable
herdr_env
PATH="$BIN:$PATH" bash "$ADAPTER" read --session-json "$SESSION" > "$TMP_ROOT/read-1.out"
PATH="$BIN:$PATH" bash "$ADAPTER" read --session-json "$SESSION" > "$TMP_ROOT/read-2.out"
printf '%s\n' 'screen changed: working output' >> "$HERDR_SCREEN"
PATH="$BIN:$PATH" bash "$ADAPTER" read --session-json "$SESSION" > "$TMP_ROOT/read-3.out"
if cmp -s "$TMP_ROOT/read-1.out" "$TMP_ROOT/read-2.out" \
  && ! cmp -s "$TMP_ROOT/read-2.out" "$TMP_ROOT/read-3.out" \
  && grep -q -- '--source recent-unwrapped --lines 200' "$STUB_ARGS" \
  && node - "$TMP_ROOT/read-1.out" <<'NODE'
const value = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8"));
if (value.adapter !== "herdr" || value.source !== "recent-unwrapped" || value.lines !== 200) process.exit(2);
if (value.text !== "agent idle screen baseline\n") process.exit(2);
NODE
then
  pass 'read returns a deterministic envelope that only changes on real screen change'
else
  fail 'read determinism/shape'
fi

# --- wait-settled: native state mapping, unknown is never success -----------

settled_case() {
  settled_name="$1"; settled_env="$2"; settled_want="$3"
  fake_state "settled-$settled_name"
  herdr_env
  eval "$settled_env PATH=\"\$BIN:\$PATH\" bash \"\$ADAPTER\" wait-settled --session-json \"\$SESSION\" --timeout-ms 3000" > "$TMP_ROOT/settled-$settled_name.out" 2>"$TMP_ROOT/settled-$settled_name.err"
  settled_ec=$?
  settled_got="$(cat "$TMP_ROOT/settled-$settled_name.out")"
  if [ "$settled_ec" -eq 0 ] && [ "$settled_got" = "{\"state\":\"$settled_want\"}" ]; then
    pass "wait-settled maps $settled_name to $settled_want"
  else
    fail "wait-settled $settled_name (ec=$settled_ec got=$settled_got $(cat "$TMP_ROOT/settled-$settled_name.err"))"
  fi
}
settled_case idle-direct 'HERDR_FAKE_SETTLED=idle' settled
settled_case done-direct 'HERDR_FAKE_SETTLED=done' settled
settled_case blocked-direct 'HERDR_FAKE_SETTLED=blocked' blocked
settled_case working-after-timeout 'HERDR_FAKE_SETTLED_MODE=timeout HERDR_FAKE_GET=ok HERDR_FAKE_GET_STATE=working' working
settled_case unknown-is-stale 'HERDR_FAKE_SETTLED_MODE=timeout HERDR_FAKE_GET=ok HERDR_FAKE_GET_STATE=unknown' stale
# Regression (#211): real herdr keys the lifecycle field as agent_status.
# The idle/done/blocked cases above would fail against the old `status`-keyed
# parser; a legacy `status`-shaped response must be refused, not misread.
settled_case idle-agent-status 'HERDR_FAKE_SETTLED=idle' settled
settled_case done-agent-status 'HERDR_FAKE_SETTLED=done' settled
settled_case blocked-agent-status 'HERDR_FAKE_SETTLED=blocked' blocked
if HERDR_FAKE_SETTLED_MODE=legacy-status PATH="$BIN:$PATH" \
  bash "$ADAPTER" wait-settled --session-json "$SESSION" --timeout-ms 3000 \
  >"$TMP_ROOT/settled-legacy.out" 2>"$TMP_ROOT/settled-legacy.err"; then
  fail "wait-settled legacy shape (unexpected success got=$(cat "$TMP_ROOT/settled-legacy.out"))"
elif grep -q 'herdr_settled_state_invalid' "$TMP_ROOT/settled-legacy.err"; then
  pass 'wait-settled refuses legacy status-shape response (#211)'
else
  fail "wait-settled legacy shape (got $(cat "$TMP_ROOT/settled-legacy.out") $(cat "$TMP_ROOT/settled-legacy.err"))"
fi
settled_case agent-gone-is-terminal 'HERDR_FAKE_SETTLED_MODE=notrunning' terminal
if grep -q -- '--until idle --until done --until blocked --timeout 3000' "$STUB_ARGS" \
  && ! grep -q -- 'wait codex-203 --until idle --until blocked --timeout 3000' "$STUB_ARGS"; then
  pass 'wait-settled queries the exact native until-set (mutation-checked)'
else
  fail 'wait-settled until-set argv'
fi

# --- interrupt / close / inspect --------------------------------------------

fake_state interrupt
herdr_env
PATH="$BIN:$PATH" bash "$ADAPTER" interrupt --session-json "$SESSION"
if [ $? -eq 0 ] && grep -q -- 'send-keys codex-203 esc' "$STUB_ARGS"; then
  pass 'interrupt sends the native esc key to the live agent'
else
  fail 'interrupt'
fi

fake_state close
herdr_env
PATH="$BIN:$PATH" bash "$ADAPTER" close --session-json "$SESSION"
close_ec=$?
HERDR_FAKE_CLOSE=fail PATH="$BIN:$PATH" bash "$ADAPTER" close --session-json "$SESSION" >/dev/null 2>&1
close_fail_ec=$?
if [ "$close_ec" -eq 0 ] && grep -qx 'ws-live' "$FAKE_STATE/close.log" && [ "$close_fail_ec" -ne 0 ]; then
  pass 'close tears the workspace down and reports close failures'
else
  fail 'close'
fi

fake_state inspect
herdr_env
HERDR_FAKE_INSPECT=live PATH="$BIN:$PATH" bash "$ADAPTER" inspect --session-json "$SESSION" > "$TMP_ROOT/inspect-live.out"
HERDR_FAKE_INSPECT=stale PATH="$BIN:$PATH" bash "$ADAPTER" inspect --session-json "$SESSION" > "$TMP_ROOT/inspect-stale.out"
if grep -q '"lifecycle":"live"' "$TMP_ROOT/inspect-live.out" && grep -q '"lifecycle":"stale"' "$TMP_ROOT/inspect-stale.out"; then
  pass 'live inspect resolves workspace liveness through the session handle'
else
  fail "live inspect ($(cat "$TMP_ROOT/inspect-live.out") / $(cat "$TMP_ROOT/inspect-stale.out"))"
fi

# --- Supervisor integration: launch ack + artifact authority ----------------

make_worktree super
SUPER_PROMPT="$TMP_ROOT/super-prompt.txt"
printf 'supervised live turn\n' > "$SUPER_PROMPT"
SUPER_SPEC="$TMP_ROOT/super-spec.json"
node - "$SUPER_SPEC" "$TMP_ROOT/wt-super" <<'NODE'
const fs = require("fs");
const [file, wt] = process.argv.slice(2);
fs.writeFileSync(file, JSON.stringify({ runtime: "codex", cwd: wt, argv: ["/bin/codex", "--model", "x"], env: {}, prompt_delivery: "transport" }));
NODE
fake_state super
herdr_env
SUPER_LIVE_DIR="$TMP_ROOT/wt-super/.review/ISSUE-203-launch.super"
mkdir -p "$SUPER_LIVE_DIR"
if LIVE_POLL_INTERVAL_MS=20 LIVE_WAIT_READY_TIMEOUT_MS=5000 LIVE_SEND_ACTIVITY_TIMEOUT_MS=5000 LIVE_SESSION_TIMEOUT_MS=10000 \
  PATH="$BIN:$PATH" bash -c '
    . "$1"
    live_session_start "$2" herdr codex-203 "$3" "$4" "$5" "$6" 203
  ' _ "$SUPERVISOR" "$ADAPTER" "$TMP_ROOT/wt-super" "$SUPER_SPEC" "$SUPER_PROMPT" "$SUPER_LIVE_DIR"; then
  supervisor_ok=1
else
  supervisor_ok=0
fi
supervisor_prompts="$(cat "$FAKE_STATE/prompt.count" 2>/dev/null || printf '%s' 0)"
if [ "$supervisor_ok" -eq 1 ] && [ "$supervisor_prompts" = 1 ] \
  && node - "$SUPER_LIVE_DIR/LIVE.json" "$SUPER_LIVE_DIR/session.json" <<'NODE'
const fs = require("fs");
const ack = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const session = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
if (ack.execution_mode !== "live-tui" || ack.state !== "prompt_started" || ack.activity_observed !== true) process.exit(2);
if (Object.prototype.hasOwnProperty.call(ack, "completion")) process.exit(2);
if (session.handles.lifecycle !== "ws-live" || session.handles.agent !== "codex-203") process.exit(2);
NODE
then
  pass 'live supervisor completes ready/send/activity once and writes non-completion evidence through the herdr adapter'
else
  fail 'live supervisor integration'
fi

# Artifact gate: settled without a fresh canonical artifact is a contract
# failure; a stale same-issue artifact is ignored; a fresh artifact passes.
STALE_RUN="$TMP_ROOT/wt-super/.review/ISSUE-203-RUN.json"
node - "$STALE_RUN" <<'NODE'
const fs = require("fs");
fs.writeFileSync(process.argv[2], JSON.stringify({ schema_version: "1", artifact_type: "codex_run", issue: 203, attempt: 1, started_at: "2026-08-20T00:00:00Z", updated_at: "2026-08-20T00:00:00Z", status: "running" }) + "\n");
NODE
run_before_sig="$(bash -c '. "$1"; live_session_artifact_signature "$2"' _ "$SUPERVISOR" "$STALE_RUN")"
if LIVE_POLL_INTERVAL_MS=20 PATH="$BIN:$PATH" bash -c '
    . "$1"
    if live_session_wait_settled "$2" "$3" 3000; then :; else exit 9; fi
    if live_session_artifact_gate 203 "$4" "$5" "$5" 1500 20; then exit 1; fi
    if [ "$LIVE_FAILURE_CODE" = "live_settled_without_artifact" ]; then exit 0; fi
    exit 2
  ' _ "$SUPERVISOR" "$ADAPTER" "$SUPER_LIVE_DIR/session.json" "$TMP_ROOT/wt-super" "$run_before_sig"; then
  pass 'settled herdr session without a fresh PR-DRAFT/BLOCKER is an output-contract failure'
else
  fail 'artifact gate: settled without fresh artifact must fail'
fi
if LIVE_POLL_INTERVAL_MS=20 PATH="$BIN:$PATH" bash -c '
    . "$1"
    live_session_wait_settled "$2" "$3" 3000 || exit 3
    node -e "const fs=require(\"fs\");const f=process.argv[1];const v=JSON.parse(fs.readFileSync(f,\"utf8\"));v.started_at=\"2026-08-21T01:02:03Z\";fs.writeFileSync(f,JSON.stringify(v)+\"\\n\")" "$4" &
    live_session_artifact_gate 203 "$5" "$6" "$6" 5000 20 || exit 4
    exit 0
  ' _ "$SUPERVISOR" "$ADAPTER" "$SUPER_LIVE_DIR/session.json" "$STALE_RUN" "$TMP_ROOT/wt-super" "$run_before_sig"; then
  pass 'a fresh canonical artifact satisfies the herdr settled-state gate'
else
  fail 'artifact gate: fresh artifact must pass'
fi
fake_state super-blocked
herdr_env
HERDR_FAKE_SETTLED=blocked
export HERDR_FAKE_SETTLED
blocked_result="$(LIVE_POLL_INTERVAL_MS=20 PATH="$BIN:$PATH" bash -c '
    . "$1"
    live_session_wait_settled "$2" "$3" 3000 >/dev/null 2>&1
    printf "%s" "$LIVE_FAILURE_CODE"
  ' _ "$SUPERVISOR" "$ADAPTER" "$SUPER_LIVE_DIR/session.json")"
if [ "$blocked_result" = "live_settled_blocked" ]; then
  pass 'native blocked state surfaces as the typed blocked classification'
else
  fail "blocked classification (got=$blocked_result)"
fi

# --- Full live dispatch through dispatch-core (fake codex + fake herdr) ------

cat > "$BIN/codex" <<'EOF'
#!/usr/bin/env bash
. "${STUB_CAPTURE_HELPER:-/dev/null}"
case "${1:-}" in
  --version) printf '%s\n' 'codex-test 1.0'; exit 0 ;;
  --help) printf '%s\n' 'exec --sandbox --cd --add-dir -m -c --ask-for-approval --model --config --output-last-message --json'; exit 0 ;;
  exec) if [ "${2:-}" = '--help' ]; then printf '%s\n' 'exec --sandbox --cd --model --config --output-last-message --json'; exit 0; fi ;;
esac
exit 0
EOF
chmod +x "$BIN/codex"

make_worktree e2e
mkdir -p "$TMP_ROOT/wt-e2e/.review"
E2E_PROMPT="$TMP_ROOT/wt-e2e/.review-prompt.txt"
mkdir -p "$(dirname "$E2E_PROMPT")"
printf 'run the live implementation turn\nsecond "quoted" line\n' > "$E2E_PROMPT"
fake_state e2e
herdr_env
E2E_OUT="$TMP_ROOT/e2e-dispatch.out"
LIVE_POLL_INTERVAL_MS=20 LIVE_WAIT_READY_TIMEOUT_MS=5000 LIVE_SEND_ACTIVITY_TIMEOUT_MS=5000 LIVE_SESSION_TIMEOUT_MS=15000 \
AGENT_WORKFLOW_CODEX_BIN="$BIN/codex" \
PATH="$BIN:$PATH" bash "$ROOT/scripts/dispatch-core.sh" \
  --adapter herdr --runtime codex --role implementation --issue 203 \
  --worktree "$TMP_ROOT/wt-e2e" --prompt-file "$E2E_PROMPT" \
  --model gpt-5.6-sol --effort high --tier trivial --execution-mode live-tui \
  > "$E2E_OUT" 2>&1
e2e_ec=$?
e2e_receipt="$TMP_ROOT/wt-e2e/.review/ISSUE-203-TRANSPORT.json"
e2e_live="$(find "$TMP_ROOT/wt-e2e/.review" -name LIVE.json -path '*launch.*' | sed -n '1p')"
e2e_prompts="$(cat "$FAKE_STATE/prompt.count" 2>/dev/null || printf '%s' 0)"
e2e_body_ok=0
[ -f "$FAKE_STATE/prompt-bodies.nul" ] && { printf '%s\0' "$(cat "$E2E_PROMPT")" | cmp -s - "$FAKE_STATE/prompt-bodies.nul" && e2e_body_ok=1; }
if [ "$e2e_ec" -eq 0 ] && [ -n "$e2e_live" ] && [ "$e2e_prompts" = 1 ] && [ "$e2e_body_ok" -eq 1 ] \
  && node - "$e2e_receipt" "$e2e_live" <<'NODE'
const fs = require("fs");
const receipt = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const ack = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
if (receipt.schema_version !== "4" || receipt.execution_mode !== "live-tui" || receipt.adapter !== "herdr") process.exit(2);
if (!/^[a-f0-9]{64}$/.test(receipt.launch_spec_sha256)) process.exit(2);
if (receipt.handles.lifecycle !== "ws-live" || receipt.handles.io !== "w1:live" || receipt.handles.agent !== "codex-203") process.exit(2);
if (receipt.runner !== undefined) process.exit(2);
if (ack.state !== "prompt_started" || ack.activity_observed !== true) process.exit(2);
NODE
then
  pass 'full live herdr dispatch publishes a v4 receipt and LIVE.json after exactly one prompt'
else
  fail "live dispatch E2E (ec=$e2e_ec prompts=$e2e_prompts body=$e2e_body_ok $(cat "$E2E_OUT"))"
fi
if find "$TMP_ROOT/wt-e2e/.review" -type f -name 'launch.sh' | grep -q .; then
  fail 'live dispatch must not generate a launch.sh runner'
else
  pass 'live dispatch generates no launch.sh runner (design section 7)'
fi

# Same-issue redispatch is refused by the write marker and never re-prompts.
fake_state e2e-redispatch
herdr_env
LIVE_POLL_INTERVAL_MS=20 AGENT_WORKFLOW_CODEX_BIN="$BIN/codex" \
PATH="$BIN:$PATH" bash "$ROOT/scripts/dispatch-core.sh" \
  --adapter herdr --runtime codex --role implementation --issue 203 \
  --worktree "$TMP_ROOT/wt-e2e" --prompt-file "$E2E_PROMPT" \
  --model gpt-5.6-sol --effort high --tier trivial --execution-mode live-tui \
  > "$TMP_ROOT/e2e-redispatch.out" 2>&1
redispatch_ec=$?
redispatch_prompts="$(cat "$FAKE_STATE/prompt.count" 2>/dev/null || printf '%s' 0)"
if [ "$redispatch_ec" -ne 0 ] \
  && { grep -q 'write redispatch requires --round-state and --manifest-revision' "$TMP_ROOT/e2e-redispatch.out" \
    || grep -q 'concurrent write dispatch' "$TMP_ROOT/e2e-redispatch.out"; } \
  && [ "$redispatch_prompts" = 0 ]; then
  pass 'same-issue redispatch is refused before launch and sends no duplicate prompt body'
else
  fail "same-issue redispatch duplicate-prompt prevention (ec=$redispatch_ec prompts=$redispatch_prompts)"
fi

if [ "$FAILURES" -eq 0 ]; then echo '--- ALL CASES PASS'; exit 0; fi
echo "--- $FAILURES CASE(S) FAILED"; exit 1
