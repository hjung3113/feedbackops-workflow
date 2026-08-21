#!/usr/bin/env bash
# T1 public-seam contract smoke. bash-3.2-compatible.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNTIME="$ROOT/scripts/agent-runtime.sh"
REGISTRY="$ROOT/scripts/lib/runtime-registry.cjs"
TRANSPORT_REGISTRY="$ROOT/scripts/lib/transport-registry.cjs"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
FAILURES=0

pass() { echo "ok   - $1"; }
fail() { echo "NOT OK - $1"; FAILURES=$((FAILURES + 1)); }

BIN="$TMP_DIR/bin"
BASE="$TMP_DIR/base"
mkdir -p "$BIN" "$BASE"
git init -q "$BASE"
git -C "$BASE" config user.email t1@example.invalid
git -C "$BASE" config user.name t1
printf '%s\n' base > "$BASE/file.txt"
git -C "$BASE" add file.txt
git -C "$BASE" commit -qm initial
WT="$(printf '%s\n%s' "$TMP_DIR/wt space 'quote" 'line;[]')"
git -C "$BASE" worktree add -q "$WT" HEAD
COMMON_RAW="$(git -C "$WT" rev-parse --git-common-dir)"
case "$COMMON_RAW" in
  /*) COMMON_DIR="$(cd "$COMMON_RAW" && pwd -P)" ;;
  *) COMMON_DIR="$(cd "$WT" && cd "$COMMON_RAW" && pwd -P)" ;;
esac

cat > "$BIN/codex" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo 'codex-test 1.0'; exit 0 ;;
  --help) printf '%s\n' 'exec --sandbox --cd --add-dir -m -c --ask-for-approval --model --config --output-last-message --json'; exit 0 ;;
  exec) [ "${2:-}" = '--help' ] && printf '%s\n' '--sandbox --cd --model --config --output-last-message --json' && exit 0 ;;
esac
printf '%s\n' "$@" > "${RUNTIME_ARGV:-/dev/null}"
EOF
chmod +x "$BIN/codex"
cat > "$BIN/claude" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo 'claude-test 1.0'; exit 0 ;;
  --help) printf '%s\n' '--print --permission-mode --output-format --model --effort --include-partial-messages'; exit 0 ;;
esac
printf '%s\n' "$@" > "${RUNTIME_ARGV:-/dev/null}"
EOF
chmod +x "$BIN/claude"
cat > "$BIN/opencode" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = '--version' ]; then echo 'opencode-test 1.0'; exit 0; fi
if [ "${1:-}" = '--help' ]; then printf '%s\n' '--agent --model --variant run'; exit 0; fi
if [ "${1:-}" = 'run' ] && [ "${2:-}" = '--help' ]; then printf '%s\n' '--dir --format --agent --model --variant json'; exit 0; fi
printf '%s\n' "$@" > "${RUNTIME_ARGV:-/dev/null}"
EOF
chmod +x "$BIN/opencode"

MODEL="$(printf '%s\n%s' 'model with spaces "quotes"' 'semi; $()')"
EFFORT='high'
CODEX_SPEC="$TMP_DIR/codex-spec.json"
PATH="$BIN:$PATH" bash "$RUNTIME" launch-spec --runtime codex --role implementation --mode write --cwd "$WT" --model "$MODEL" --effort "$EFFORT" > "$CODEX_SPEC" 2>"$TMP_DIR/codex.err"
if [ "$?" -eq 0 ] && node - "$CODEX_SPEC" "$WT" "$COMMON_DIR" "$MODEL" "$EFFORT" "$BIN/codex" <<'NODE'
const fs=require("fs");
const [file,cwd,common,model,effort,bin]=process.argv.slice(2), s=JSON.parse(fs.readFileSync(file,"utf8"));
const a=s.argv, at=(x)=>a.indexOf(x), pair=(x,y)=>at(x)>=0 && a[at(x)+1]===y;
if (s.runtime!=="codex" || s.cwd!==cwd || s.prompt_delivery!=="transport" || Object.keys(s.env).length) process.exit(2);
if (a[0]!==bin || pair("--sandbox","workspace-write")===false || pair("--cd",cwd)===false || pair("--add-dir",common)===false) process.exit(2);
if (pair("-m",model)===false || pair("-c",`model_reasoning_effort="${effort}"`)===false || pair("--ask-for-approval","never")===false) process.exit(2);
if (["exec","--print","run"].some(x=>a.indexOf(x)>=0)) process.exit(2);
NODE
then pass 'Codex live launch-spec preserves special argv tokens and write policy'; else fail 'Codex live launch-spec preserves special argv tokens and write policy'; fi

if node - "$CODEX_SPEC" "$ROOT/scripts/lib/launch-spec.cjs" <<'NODE'
const fs=require("fs"), {normalizeLaunchSpec}=require(process.argv[3]);
const value=JSON.parse(fs.readFileSync(process.argv[2],"utf8"));
value.unexpected="must be rejected";
process.exit(normalizeLaunchSpec(value,"codex")===null?0:1);
NODE
then pass 'launch-spec rejects undeclared top-level fields'; else fail 'launch-spec rejects undeclared top-level fields'; fi

CLAUDE_SPEC="$TMP_DIR/claude-spec.json"
PATH="$BIN:$PATH" bash "$RUNTIME" launch-spec --runtime claude --role reviewer --mode read --cwd "$WT" --model "$MODEL" --effort medium > "$CLAUDE_SPEC" 2>"$TMP_DIR/claude.err"
if [ "$?" -eq 0 ] && node - "$CLAUDE_SPEC" "$WT" "$MODEL" "$BIN/claude" <<'NODE'
const fs=require("fs");
const [file,cwd,model,bin]=process.argv.slice(2), s=JSON.parse(fs.readFileSync(file,"utf8")), a=s.argv;
const at=x=>a.indexOf(x);
if (s.runtime!=="claude" || s.cwd!==cwd || a[0]!==bin || a[at("--permission-mode")+1]!=="plan" || a[at("--model")+1]!==model || a[at("--effort")+1]!=="medium") process.exit(2);
if (["--print","--output-format","stream-json","--include-partial-messages","run","exec"].some(x=>a.indexOf(x)>=0)) process.exit(2);
NODE
then pass 'Claude live launch-spec is a bare permissioned REPL'; else fail 'Claude live launch-spec is a bare permissioned REPL'; fi

OPENCODE_SPEC="$TMP_DIR/opencode-spec.json"
OPENCODE_CONFIG="$ROOT/scripts/runtimes/opencode-write.json"
PATH="$BIN:$PATH" bash "$RUNTIME" launch-spec --runtime opencode --role implementation --mode write --cwd "$WT" --model "$MODEL" --effort medium --opencode-permission-file "$OPENCODE_CONFIG" > "$OPENCODE_SPEC" 2>"$TMP_DIR/opencode.err"
if [ "$?" -eq 0 ] && node - "$OPENCODE_SPEC" "$WT" "$MODEL" "$BIN/opencode" "$OPENCODE_CONFIG" <<'NODE'
const fs=require("fs");
const [file,cwd,model,bin,configFile]=process.argv.slice(2), s=JSON.parse(fs.readFileSync(file,"utf8")), a=s.argv;
const at=x=>a.indexOf(x), expected=fs.readFileSync(configFile,"utf8");
if (s.runtime!=="opencode" || s.cwd!==cwd || a[0]!==bin || a[1]!==cwd || a[at("--agent")+1]!=="agent-workflow" || a[at("--model")+1]!==model || a[at("--variant")+1]!=="medium") process.exit(2);
if (s.env.OPENCODE_CONFIG_CONTENT!==expected) process.exit(2);
if (["run","--format","json","--print","exec"].some(x=>a.indexOf(x)>=0)) process.exit(2);
NODE
then pass 'OpenCode live launch-spec carries deny-first config in env and drops run envelope'; else fail 'OpenCode live launch-spec carries deny-first config in env and drops run envelope'; fi

cat > "$BIN/codex-headless" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo 'codex-test 1.0'; exit 0 ;;
  --help) printf '%s\n' 'exec'; exit 0 ;;
  exec) [ "${2:-}" = '--help' ] && printf '%s\n' '--sandbox --cd --model --config --output-last-message --json' && exit 0 ;;
esac
EOF
chmod +x "$BIN/codex-headless"
PATH="$BIN:$PATH" AGENT_WORKFLOW_RUNTIME_BIN="$BIN/codex-headless" bash "$RUNTIME" capabilities --runtime codex > "$TMP_DIR/headless-capabilities.json" 2>/dev/null
if [ "$?" -eq 0 ] && PATH="$BIN:$PATH" AGENT_WORKFLOW_RUNTIME_BIN="$BIN/codex-headless" bash "$RUNTIME" launch-spec --runtime codex --role implementation --mode write --cwd "$WT" > "$TMP_DIR/live-fail.json" 2>"$TMP_DIR/live-fail.err"; then
  fail 'headless/live capability split refuses missing interactive contract'
else
  if grep -F 'runtime_live_capability_unavailable' "$TMP_DIR/live-fail.err" >/dev/null; then pass 'headless/live capability split refuses missing interactive contract'; else fail 'headless/live capability split refusal is typed'; fi
fi

if node "$TRANSPORT_REGISTRY" live-capabilities | grep -F 'session.live.launch' >/dev/null \
  && node "$TRANSPORT_REGISTRY" live-subcommands | grep -Fx 'launch-live' >/dev/null \
  && node "$TRANSPORT_REGISTRY" live-settled-states | grep -Fx 'blocked' >/dev/null; then
  pass 'transport registry exposes the normalized live vocabulary'
else
  fail 'transport registry exposes the normalized live vocabulary'
fi
HANDLES='{"lifecycle":"life-1","io":"io-1","agent":"agent-1"}'
SESSION_JSON="$(node "$ROOT/scripts/lib/adapter-json.cjs" session launched "$HANDLES")"
if node - "$SESSION_JSON" <<'NODE'
const v=JSON.parse(process.argv[2]);
if (v.lifecycle!=="launched" || JSON.stringify(v.handles)!==JSON.stringify({lifecycle:"life-1",io:"io-1",agent:"agent-1"}) || v.external_handle) process.exit(2);
NODE
then pass 'structured live handles normalize without inventing an external alias'; else fail 'structured live handles normalize without inventing an external alias'; fi
SPLIT_JSON="$(node "$ROOT/scripts/lib/adapter-json.cjs" availability cmux '{"available":true,"reason_code":"available"}' '{"available":false,"reason_code":"required_capability_missing"}')"
if node - "$SPLIT_JSON" <<'NODE'
const v=JSON.parse(process.argv[2]);
if (!v.headless || v.headless.available!==true || !v.live || v.live.available!==false) process.exit(2);
NODE
then pass 'adapter capability emission keeps headless and live availability separate'; else fail 'adapter capability emission keeps headless and live availability separate'; fi

SCHEMA="$ROOT/schemas/transport_receipt.schema.json"
for fixture in "$ROOT"/schemas/fixtures/transport_receipt.v4.*.json; do
  case "$fixture" in *invalid*) expected=false ;; *) expected=true ;; esac
  node - "$ROOT/scripts/lib/json-schema-subset.cjs" "$SCHEMA" "$fixture" "$expected" <<'NODE'
const fs=require("fs"), v=require(process.argv[2]);
const schema=JSON.parse(fs.readFileSync(process.argv[3],"utf8")), value=JSON.parse(fs.readFileSync(process.argv[4],"utf8"));
const errors=v.validate(schema,value), expected=process.argv[5]==="true";
process.exit((errors.length===0)===expected?0:1);
NODE
  if [ "$?" -eq 0 ]; then pass "v4 fixture $(basename "$fixture")"; else fail "v4 fixture $(basename "$fixture")"; fi
done

FAKE_ADAPTER="$TMP_DIR/fake-adapter.sh"
FAKE_ACTIVITY="$TMP_DIR/activity.sent"
FAKE_SEND_COUNT="$TMP_DIR/send.count"
cat > "$FAKE_ADAPTER" <<'EOF'
#!/usr/bin/env bash
command_name="${1:-}"
case "$command_name" in
  launch-live) printf '%s\n' '{"lifecycle":"launched","handles":{"lifecycle":"life","io":"io","agent":"agent"}}' ;;
  wait-ready) exit 0 ;;
  read)
    if [ -f "$FAKE_ACTIVITY_FILE" ]; then printf '%s\n' '{"output":"changed"}'; else printf '%s\n' '{"output":"baseline"}'; fi
    ;;
  send) count=0; [ -f "$FAKE_SEND_COUNT_FILE" ] && count="$(cat "$FAKE_SEND_COUNT_FILE")"; count=$((count + 1)); printf '%s\n' "$count" > "$FAKE_SEND_COUNT_FILE"; : > "$FAKE_ACTIVITY_FILE" ;;
  wait-settled) printf '{"state":"%s"}\n' "${FAKE_SETTLED_STATE:-settled}" ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$FAKE_ADAPTER"
LIVE_DIR="$TMP_DIR/live"
mkdir -p "$LIVE_DIR"
printf '%s\n' '{}' > "$TMP_DIR/live-spec.json"
printf '%s\n' 'prompt' > "$TMP_DIR/live-prompt.txt"
if FAKE_ACTIVITY_FILE="$FAKE_ACTIVITY" FAKE_SEND_COUNT_FILE="$FAKE_SEND_COUNT" LIVE_WAIT_READY_TIMEOUT_MS=5000 LIVE_SEND_ACTIVITY_TIMEOUT_MS=5000 LIVE_SESSION_TIMEOUT_MS=15000 LIVE_POLL_INTERVAL_MS=20 bash -c '
  . "$1/scripts/lib/live-session-supervisor.sh"
  live_session_start "$2" orca live-seat "$3" "$4" "$5" "$6" 203
' _ "$ROOT" "$FAKE_ADAPTER" "$WT" "$TMP_DIR/live-spec.json" "$TMP_DIR/live-prompt.txt" "$LIVE_DIR"; then
  if [ "$(cat "$FAKE_SEND_COUNT")" = 1 ] && node - "$LIVE_DIR/LIVE.json" "$WT" <<'NODE'
const fs=require("fs"), v=JSON.parse(fs.readFileSync(process.argv[2],"utf8"));
if (v.execution_mode!=="live-tui" || v.state!=="prompt_started" || v.activity_observed!==true || v.worktree_path!==process.argv[3] || v.prompt_started_at===undefined || v.handles.agent!=="agent") process.exit(2);
if (Object.prototype.hasOwnProperty.call(v,"completion")) process.exit(2);
NODE
  then pass 'live supervisor performs ready/send/activity once and writes non-completion LIVE evidence'; else fail 'live supervisor writes correct launch/liveness evidence'; fi
else
  fail 'live supervisor performs ready/send/activity once';
fi

if FAKE_SETTLED_STATE=settled FAKE_ACTIVITY_FILE="$FAKE_ACTIVITY" FAKE_SEND_COUNT_FILE="$FAKE_SEND_COUNT" bash -c '. "$1/scripts/lib/live-session-supervisor.sh"; live_session_wait_settled "$2" "$3" 1000' _ "$ROOT" "$FAKE_ADAPTER" "$LIVE_DIR/session.json"; then
  pass 'live supervisor settled query accepts canonical settled state'
else
  fail 'live supervisor settled query accepts canonical settled state'
fi
if FAKE_SETTLED_STATE=blocked FAKE_ACTIVITY_FILE="$FAKE_ACTIVITY" FAKE_SEND_COUNT_FILE="$FAKE_SEND_COUNT" bash -c '. "$1/scripts/lib/live-session-supervisor.sh"; live_session_wait_settled "$2" "$3" 1000' _ "$ROOT" "$FAKE_ADAPTER" "$LIVE_DIR/session.json"; then
  fail 'blocked live state is not treated as settled'
else
  pass 'blocked live state is not treated as settled'
fi

dispatch_error="$(bash "$ROOT/scripts/dispatch-core.sh" --adapter cmux --execution-mode live-tui --role reviewer --issue 203 --worktree /definitely/not-a-worktree 2>&1)"
dispatch_exit=$?
if [ "$dispatch_exit" -eq 2 ] && printf '%s\n' "$dispatch_error" | grep -F live_tui_requires_implementation_write >/dev/null; then
  pass 'dispatch live phase-1 admission is typed and implementation/write-only'
else
  fail 'dispatch live phase-1 admission is typed and implementation/write-only'
fi

if [ "$FAILURES" -eq 0 ]; then echo '--- ALL CASES PASS'; exit 0; fi
echo "--- $FAILURES CASE(S) FAILED"; exit 1
