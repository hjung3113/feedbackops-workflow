#!/usr/bin/env bash
# Offline contract test. bash-3.2 compatible.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; RUNTIME="$SCRIPT_DIR/../agent-runtime.sh"; TMP_DIR="$(mktemp -d)"; trap 'rm -rf "$TMP_DIR"' EXIT; FAILURES=0
ok() { echo "ok   - $1"; }; bad() { echo "NOT OK - $1"; FAILURES=$((FAILURES + 1)); }
BIN="$TMP_DIR/bin"; WT="$TMP_DIR/wt"; mkdir -p "$BIN" "$WT"; printf 'prompt\n' > "$WT/prompt.txt"
. "$SCRIPT_DIR/lib/stub-argv.sh"; make_stub_capture_helper "$TMP_DIR/stub-capture.sh"; STUB_CAPTURE_HELPER="$TMP_DIR/stub-capture.sh"; export STUB_CAPTURE_HELPER
make_bin() { name="$1"; help="$2"; printf '#!/usr/bin/env bash\nif [ "$1" = "--version" ]; then echo test-version; exit 0; fi\nif [ "$1" = "--help" ] || [ "$2" = "--help" ]; then printf "%%s\\n" %s; exit 0; fi\nprintf "%%s\\n" "$@" > "$RUNTIME_ARGV"\n. "$STUB_CAPTURE_HELPER"\n' "'$help'" > "$BIN/$name"; chmod +x "$BIN/$name"; }
make_bin codex 'exec --sandbox --cd --model --config --output-last-message --json'; make_bin claude '--print --permission-mode --output-format --model --effort --include-partial-messages'; make_bin opencode 'run --dir --format --agent --model --variant json'
# Refuse launches unless the documented inline config and explicit primary
# agent are consumed. This proves config application, not only local parsing.
cat > "$BIN/opencode" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then echo test-version; exit 0; fi
if [ "$1" = "--help" ] || { [ "$1" = "run" ] && [ "$2" = "--help" ]; }; then printf '%s\n' 'run --dir --format --agent --model --variant json'; exit 0; fi
node - "$OPENCODE_CONFIG_CONTENT" "$@" <<'NODE'
const raw=process.argv[2], argv=process.argv.slice(3);
try {
  const c=JSON.parse(raw), p=c.permission, a=c.agent && c.agent['agent-workflow'];
  const agent=argv.indexOf('--agent'), auto=argv.indexOf('--auto');
  if (agent < 0 || argv[agent + 1] !== 'agent-workflow' || auto >= 0) process.exit(20);
  if (!p || !a || a.mode !== 'primary' || !a.permission) process.exit(21);
  for (const key of ['*','external_directory']) {
    if (p[key] !== 'deny' || a.permission[key] !== 'deny') process.exit(22);
  }
  if (p.edit !== a.permission.edit) process.exit(23);
  if (p.webfetch !== a.permission.webfetch || p.websearch !== a.permission.websearch) process.exit(26);
  const expectedBash=p.edit==='allow'?'allow':'deny';
  if (p.bash !== expectedBash || a.permission.bash !== expectedBash) process.exit(25);
} catch (_) { process.exit(24); }
NODE
status=$?
[ "$status" -eq 0 ] || exit "$status"
printf '%s\n' "$@" > "$RUNTIME_ARGV"
. "$STUB_CAPTURE_HELPER"
EOF
chmod +x "$BIN/opencode"
# omp stub: refuses (exit 21/22) any headless launch that is not a write
# launch but lacks the pinned read-only --tools surface, or whose read
# surface still exposes a write/exec tool. This is the mutation-negative
# read-isolation contract: a regression in omp.sh cannot stay green.
cat > "$BIN/omp" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then echo test-version; exit 0; fi
if [ "$1" = "--help" ]; then printf '%s\n' '--print --approval-mode --model --thinking --mode --cwd --tools'; exit 0; fi
is_read=1
for arg in "$@"; do [ "$arg" = "--approval-mode" ] && is_read=0; done
if [ "$is_read" -eq 1 ]; then
  tools_ok=0
  for arg in "$@"; do [ "$arg" = "read,grep,glob" ] && tools_ok=1; done
  [ "$tools_ok" -eq 1 ] || exit 21
  for arg in "$@"; do case "$arg" in *bash*|*edit*|*write*|*computer*|*browser*|*python*) exit 22;; esac; done
fi
printf '%s\n' "$@" > "$RUNTIME_ARGV"
. "$STUB_CAPTURE_HELPER"
EOF
chmod +x "$BIN/omp"
for runtime in codex claude opencode omp; do out="$TMP_DIR/$runtime.json"; PATH="$BIN:$PATH" bash "$RUNTIME" capabilities --runtime "$runtime" > "$out" 2>/dev/null; if [ $? -eq 0 ] && grep -F '"fallback":false' "$out" >/dev/null && grep -F '"conductor"' "$out" >/dev/null && grep -F '"implementation"' "$out" >/dev/null && grep -F '"executable":' "$out" >/dev/null && grep -F '"version":' "$out" >/dev/null; then ok "$runtime declares complete roles, pin, and no fallback"; else bad "$runtime capability contract"; fi; done
# Negative capability contract: an omp whose --help lacks --tools must be
# refused at the capability-probe stage, not later at dispatch. Pin the
# binary through its registry env seam and use a PATH that cannot reach a
# real host omp, so the probe can only see this stub.
sed 's/ --tools//' "$BIN/omp" > "$BIN/omp-no-tools"; chmod +x "$BIN/omp-no-tools"
AGENT_WORKFLOW_OMP_BIN="$BIN/omp-no-tools" PATH="$(dirname "$(command -v node)"):/usr/bin:/bin" bash "$RUNTIME" capabilities --runtime omp >"$TMP_DIR/omp-no-tools.json" 2>/dev/null
omp_no_tools_ec=$?
if [ "$omp_no_tools_ec" -ne 0 ] && grep -F -q '"code":"capability_missing_print_model_thinking_or_mode"' "$TMP_DIR/omp-no-tools.json"; then ok 'omp without --tools in --help fails the capability probe before admission'; else bad 'omp --tools capability probe gate'; fi
AGENT_WORKFLOW_RUNTIME_BIN="$BIN/codex" PATH="$(dirname "$(command -v node)"):/usr/bin:/bin" bash "$RUNTIME" capabilities --runtime codex > "$TMP_DIR/pinned.json" 2>/dev/null; if [ $? -eq 0 ] && grep -F "\"executable\":\"$BIN/codex\"" "$TMP_DIR/pinned.json" >/dev/null; then ok 'generic absolute runtime pin is honored'; else bad 'generic runtime pin'; fi
PATH="$BIN:$PATH" AGENT_WORKFLOW_CODEX_BIN=missing-codex bash "$RUNTIME" capabilities --runtime codex >"$TMP_DIR/missing.json" 2>/dev/null; if [ $? -ne 0 ] && grep -F runtime_unavailable "$TMP_DIR/missing.json" >/dev/null; then ok 'unavailable runtime fails closed'; else bad 'unavailable runtime fails closed'; fi
RUNTIME_ARGV="$TMP_DIR/codex.argv" PATH="$BIN:$PATH" bash "$RUNTIME" run --runtime codex --role implementation --mode write --cwd "$WT" --prompt-file "$WT/prompt.txt" --issue 1; if grep -Fx -- workspace-write "$TMP_DIR/codex.argv" >/dev/null; then ok 'codex write preserves codex-safe workspace-write'; else bad 'codex write isolation'; fi
RUNTIME_ARGV="$TMP_DIR/claude.argv" PATH="$BIN:$PATH" bash "$RUNTIME" run --runtime claude --role conductor --mode read --cwd "$WT" --prompt-file "$WT/prompt.txt"; if grep -Fx -- plan "$TMP_DIR/claude.argv" >/dev/null; then ok 'claude conductor read pins plan'; else bad 'claude read isolation'; fi
if grep -Fx -- stream-json "$TMP_DIR/claude.argv" >/dev/null && grep -Fx -- --verbose "$TMP_DIR/claude.argv" >/dev/null && grep -Fx -- --include-partial-messages "$TMP_DIR/claude.argv" >/dev/null; then ok 'AC-142-A2b2-3 claude launch applies registry PROGRESS.flags, not a hardcoded --output-format text'; else bad 'AC-142-A2b2-3 claude launch applies registry PROGRESS.flags, not a hardcoded --output-format text'; fi
# omp read: headless, fail-closed tool surface, no approval lift.
RUNTIME_ARGV="$TMP_DIR/omp-read.argv" PATH="$BIN:$PATH" bash "$RUNTIME" run --runtime omp --role reviewer --mode read --cwd "$WT" --prompt-file "$WT/prompt.txt" >/dev/null 2>&1; omp_read_ec=$?
if [ "$omp_read_ec" -eq 0 ] && grep -Fx -- -p "$TMP_DIR/omp-read.argv" >/dev/null && grep -Fx -- --tools "$TMP_DIR/omp-read.argv" >/dev/null && grep -Fx -- read,grep,glob "$TMP_DIR/omp-read.argv" >/dev/null && ! grep -Fx -- --approval-mode "$TMP_DIR/omp-read.argv" >/dev/null; then ok 'omp read pins the read-only tool surface without approval lift'; else bad 'omp read isolation (exit '"$omp_read_ec"')'; fi
if grep -Fx -- --mode "$TMP_DIR/omp-read.argv" >/dev/null && grep -Fx -- json "$TMP_DIR/omp-read.argv" >/dev/null; then ok 'omp read launch applies registry PROGRESS.flags (--mode json)'; else bad 'omp progress flags'; fi
# Mutation-negative: a read launch whose tool surface exposes a write/exec
# tool is refused by the same contract stub.
OMP_MUTATE=1 "$BIN/omp" -p --tools read,grep,glob --tools bash "x" >/dev/null 2>&1; if [ $? -eq 22 ]; then ok 'omp read-isolation contract stub refuses a write/exec-capable tool surface'; else bad 'omp read-isolation mutation check'; fi
"$BIN/omp" -p --model m "x" >/dev/null 2>&1; if [ $? -eq 21 ]; then ok 'omp read-isolation contract stub refuses a missing --tools pin'; else bad 'omp missing-tools mutation check'; fi
# omp write: lifts the approval gate and forwards model/thinking pairs.
: > "$TMP_DIR/omp-write.args"
RUNTIME_ARGV="$TMP_DIR/omp-write.argv" STUB_ARGS_LOG="$TMP_DIR/omp-write.args" PATH="$BIN:$PATH" bash "$RUNTIME" run --runtime omp --role implementation --mode write --cwd "$WT" --prompt-file "$WT/prompt.txt" --model m3 --effort low
omp_args="$(tail -n 1 "$TMP_DIR/omp-write.args")"
if [ "$(printf '%s\n' "$omp_args" | grep -c -- '--approval-mode write')" -eq 1 ] && printf '%s\n' "$omp_args" | grep -q -- '--model m3' && printf '%s\n' "$omp_args" | grep -q -- '--thinking low' && [ "$(printf '%s\n' "$omp_args" | grep -c -- '--mode json')" -eq 1 ]; then ok 'omp write forwards approval lift and model/thinking pairs with the --mode json streaming pair'; else bad 'omp write argv pair capture (got: '"$omp_args"')'; fi
omp_mutation_glued='--approval-modewrite --model m3'
if ! printf '%s\n' "$omp_mutation_glued" | grep -q -- '--approval-mode write'; then ok 'omp argv mutation check rejects a token-glued approval pair'; else bad 'omp argv mutation check accepted a mutated argv'; fi
# omp run forwards the prompt behind a POSIX separator: a leading-dash
# prompt must arrive as the final positional, not parse as a flag.
printf '%s\n' '- leading dash prompt' > "$WT/dash-prompt.txt"
RUNTIME_ARGV="$TMP_DIR/omp-dash.argv" PATH="$BIN:$PATH" bash "$RUNTIME" run --runtime omp --role reviewer --mode read --cwd "$WT" --prompt-file "$WT/dash-prompt.txt" >/dev/null 2>&1
if grep -Fx -- -- "$TMP_DIR/omp-dash.argv" >/dev/null && [ "$(tail -n 1 "$TMP_DIR/omp-dash.argv")" = '- leading dash prompt' ]; then ok 'omp run passes the prompt behind a POSIX -- separator'; else bad 'omp leading-dash prompt forwarding'; fi
RUNTIME_ARGV="$TMP_DIR/omp-probe.argv" PATH="$BIN:$PATH" bash "$RUNTIME" probe --runtime omp --model m3 --effort low; if grep -Fx -- -p "$TMP_DIR/omp-probe.argv" >/dev/null && grep -Fx -- read,grep,glob "$TMP_DIR/omp-probe.argv" >/dev/null && grep -Fx -- m3 "$TMP_DIR/omp-probe.argv" >/dev/null && grep -Fx -- low "$TMP_DIR/omp-probe.argv" >/dev/null; then ok 'omp probe stays headless, read-only, and forwards model/thinking'; else bad 'omp probe argv'; fi
cp "$SCRIPT_DIR/../runtimes/opencode-read.json" "$TMP_DIR/read.json"; cp "$SCRIPT_DIR/../runtimes/opencode-write.json" "$TMP_DIR/write.json"
RUNTIME_ARGV="$TMP_DIR/opencode.argv" PATH="$BIN:$PATH" bash "$RUNTIME" run --runtime opencode --role reviewer --mode read --cwd "$WT" --prompt-file "$WT/prompt.txt" --opencode-permission-file "$TMP_DIR/read.json"; if ! grep -Fx -- --auto "$TMP_DIR/opencode.argv" >/dev/null && grep -Fx -- agent-workflow "$TMP_DIR/opencode.argv" >/dev/null; then ok 'opencode applies deny-first inline config through explicit agent without auto'; else bad 'opencode config and explicit agent application'; fi
PATH="$BIN:$PATH" bash "$RUNTIME" run --runtime opencode --role implementation --mode write --cwd "$WT" --prompt-file "$WT/prompt.txt" >/dev/null 2>&1; if [ $? -ne 0 ]; then ok 'opencode missing permission config refused'; else bad 'opencode missing permission config'; fi
PATH="$BIN:$PATH" bash "$RUNTIME" probe --runtime opencode --model good-model --effort medium >"$TMP_DIR/opencode-probe-missing.out" 2>&1; if [ $? -eq 3 ] && grep -F -q '"code":"opencode_permission_config_required"' "$TMP_DIR/opencode-probe-missing.out"; then ok 'opencode probe missing permission config is typed'; else bad 'opencode probe missing permission config is typed'; fi
printf '{"permission":{"*":"deny","edit":"allow","external_directory":"deny","bash":"deny","webfetch":"deny"}}\n' > "$TMP_DIR/no-agent.json"
PATH="$BIN:$PATH" bash "$RUNTIME" run --runtime opencode --role implementation --mode write --cwd "$WT" --prompt-file "$WT/prompt.txt" --opencode-permission-file "$TMP_DIR/no-agent.json" >/dev/null 2>&1; if [ $? -ne 0 ]; then ok 'opencode config without explicit primary agent refused'; else bad 'opencode explicit primary agent'; fi
node - "$TMP_DIR/write.json" "$TMP_DIR/websearch-mismatch.json" <<'NODE'
const fs=require('fs'), c=JSON.parse(fs.readFileSync(process.argv[2],'utf8')); c.permission.websearch='deny'; fs.writeFileSync(process.argv[3],JSON.stringify(c));
NODE
PATH="$BIN:$PATH" bash "$RUNTIME" run --runtime opencode --role implementation --mode write --cwd "$WT" --prompt-file "$WT/prompt.txt" --opencode-permission-file "$TMP_DIR/websearch-mismatch.json" >/dev/null 2>&1; if [ $? -ne 0 ]; then ok 'opencode write requires webfetch/websearch allow on both scopes'; else bad 'opencode websearch allow required'; fi
PATH="$BIN:$PATH" bash "$RUNTIME" run --runtime opencode --role implementation --mode write --cwd "$WT" --prompt-file "$WT/prompt.txt" --opencode-permission-file "$TMP_DIR/read.json" >/dev/null 2>&1; if [ $? -ne 0 ]; then ok 'opencode write requires edit allow'; else bad 'opencode write permission'; fi
RUNTIME_ARGV="$TMP_DIR/opencode-write.argv" PATH="$BIN:$PATH" bash "$RUNTIME" run --runtime opencode --role release --mode write --cwd "$WT" --prompt-file "$WT/prompt.txt" --opencode-permission-file "$TMP_DIR/write.json"; if grep -Fx -- "$WT" "$TMP_DIR/opencode-write.argv" >/dev/null && grep -Fx -- agent-workflow "$TMP_DIR/opencode-write.argv" >/dev/null; then ok 'opencode write uses explicit cwd and configured agent'; else bad 'opencode write argv'; fi
# #155: the opencode launch must carry the streaming format as an adjacent
# argv pair. Per-token greps cannot see adjacency; the single "$*" capture
# line can. Mutation checks prove the pair greps reject a reverted
# --format default and a token-glued mutation.
: > "$TMP_DIR/opencode-format.args"
RUNTIME_ARGV="$TMP_DIR/opencode-format.argv" STUB_ARGS_LOG="$TMP_DIR/opencode-format.args" PATH="$BIN:$PATH" bash "$RUNTIME" run --runtime opencode --role reviewer --mode read --cwd "$WT" --prompt-file "$WT/prompt.txt" --opencode-permission-file "$TMP_DIR/read.json"
opencode_args="$(tail -n 1 "$TMP_DIR/opencode-format.args")"
if [ "$(printf '%s\n' "$opencode_args" | grep -c -- '--format json')" -eq 1 ]; then ok '#155 opencode launch forwards the --format json streaming pair'; else bad '#155 opencode argv pair capture (got: '"$opencode_args"')'; fi
opencode_mutation_reverted='run --dir /wt --format default --agent agent-workflow'
opencode_mutation_glued='run --dir /wt --formatjson --agent agent-workflow'
if ! printf '%s\n' "$opencode_mutation_reverted" | grep -q -- '--format json' && ! printf '%s\n' "$opencode_mutation_glued" | grep -q -- '--format json'; then ok '#155 opencode argv mutation check rejects reverted and glued format pairs'; else bad '#155 opencode argv mutation check accepted a mutated argv'; fi
# #164 stub argv capture contract: the claude launcher must forward the manual
# model/effort tuple as adjacent argv pairs and keep the plan permission mode.
# Per-token greps above cannot see adjacency; the single "$*" capture line can.
: > "$TMP_DIR/claude-model.args"
RUNTIME_ARGV="$TMP_DIR/claude-model.argv" STUB_ARGS_LOG="$TMP_DIR/claude-model.args" PATH="$BIN:$PATH" bash "$RUNTIME" run --runtime claude --role conductor --mode read --cwd "$WT" --prompt-file "$WT/prompt.txt" --model m2 --effort high
claude_args="$(tail -n 1 "$TMP_DIR/claude-model.args")"
if [ "$(printf '%s\n' "$claude_args" | grep -c -- '--permission-mode plan')" -eq 1 ] && printf '%s\n' "$claude_args" | grep -q -- '--model m2' && printf '%s\n' "$claude_args" | grep -q -- '--effort high'; then ok '#164 claude launch forwards model/effort pairs with plan permission adjacency'; else bad '#164 claude launch argv pair capture (got: '"$claude_args"')'; fi
# Mutation check: the same pair greps must reject a reverted permission mode
# and a token-glued mutation that per-token greps would still accept.
mutation_reverted='--print --permission-mode acceptEdits --model m2 --effort high'
mutation_glued='--print --permission-mode--model m2 --effort high'
if ! printf '%s\n' "$mutation_reverted" | grep -q -- '--permission-mode plan' && ! printf '%s\n' "$mutation_glued" | grep -q -- '--permission-mode plan'; then ok '#164 claude argv mutation check rejects reverted and glued permission pairs'; else bad '#164 claude argv mutation check accepted a mutated argv'; fi
[ "$FAILURES" -eq 0 ] && { echo 'ALL CASES PASS'; exit 0; }; echo "$FAILURES CASE(S) FAILED"; exit 1
