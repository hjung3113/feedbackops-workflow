#!/usr/bin/env bash
# Offline contract test. bash-3.2 compatible.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; RUNTIME="$SCRIPT_DIR/../agent-runtime.sh"; TMP_DIR="$(mktemp -d)"; trap 'rm -rf "$TMP_DIR"' EXIT; FAILURES=0
ok() { echo "ok   - $1"; }; bad() { echo "NOT OK - $1"; FAILURES=$((FAILURES + 1)); }
BIN="$TMP_DIR/bin"; WT="$TMP_DIR/wt"; mkdir -p "$BIN" "$WT"; printf 'prompt\n' > "$WT/prompt.txt"
make_bin() { name="$1"; help="$2"; printf '#!/usr/bin/env bash\nif [ "$1" = "--version" ]; then echo test-version; exit 0; fi\nif [ "$1" = "--help" ] || [ "$2" = "--help" ]; then printf "%%s\\n" %s; exit 0; fi\nprintf "%%s\\n" "$@" > "$RUNTIME_ARGV"\n' "'$help'" > "$BIN/$name"; chmod +x "$BIN/$name"; }
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
EOF
chmod +x "$BIN/opencode"
for runtime in codex claude opencode; do out="$TMP_DIR/$runtime.json"; PATH="$BIN:$PATH" bash "$RUNTIME" capabilities --runtime "$runtime" > "$out" 2>/dev/null; if [ $? -eq 0 ] && grep -F '"fallback":false' "$out" >/dev/null && grep -F '"conductor"' "$out" >/dev/null && grep -F '"implementation"' "$out" >/dev/null && grep -F '"executable":' "$out" >/dev/null && grep -F '"version":' "$out" >/dev/null; then ok "$runtime declares complete roles, pin, and no fallback"; else bad "$runtime capability contract"; fi; done
AGENT_WORKFLOW_RUNTIME_BIN="$BIN/codex" PATH="$(dirname "$(command -v node)"):/usr/bin:/bin" bash "$RUNTIME" capabilities --runtime codex > "$TMP_DIR/pinned.json" 2>/dev/null; if [ $? -eq 0 ] && grep -F "\"executable\":\"$BIN/codex\"" "$TMP_DIR/pinned.json" >/dev/null; then ok 'generic absolute runtime pin is honored'; else bad 'generic runtime pin'; fi
PATH="$BIN:$PATH" AGENT_WORKFLOW_CODEX_BIN=missing-codex bash "$RUNTIME" capabilities --runtime codex >"$TMP_DIR/missing.json" 2>/dev/null; if [ $? -ne 0 ] && grep -F runtime_unavailable "$TMP_DIR/missing.json" >/dev/null; then ok 'unavailable runtime fails closed'; else bad 'unavailable runtime fails closed'; fi
RUNTIME_ARGV="$TMP_DIR/codex.argv" PATH="$BIN:$PATH" bash "$RUNTIME" run --runtime codex --role implementation --mode write --cwd "$WT" --prompt-file "$WT/prompt.txt" --issue 1; if grep -Fx -- workspace-write "$TMP_DIR/codex.argv" >/dev/null; then ok 'codex write preserves codex-safe workspace-write'; else bad 'codex write isolation'; fi
RUNTIME_ARGV="$TMP_DIR/claude.argv" PATH="$BIN:$PATH" bash "$RUNTIME" run --runtime claude --role conductor --mode read --cwd "$WT" --prompt-file "$WT/prompt.txt"; if grep -Fx -- plan "$TMP_DIR/claude.argv" >/dev/null; then ok 'claude conductor read pins plan'; else bad 'claude read isolation'; fi
if grep -Fx -- stream-json "$TMP_DIR/claude.argv" >/dev/null && grep -Fx -- --verbose "$TMP_DIR/claude.argv" >/dev/null && grep -Fx -- --include-partial-messages "$TMP_DIR/claude.argv" >/dev/null; then ok 'AC-142-A2b2-3 claude launch applies registry PROGRESS.flags, not a hardcoded --output-format text'; else bad 'AC-142-A2b2-3 claude launch applies registry PROGRESS.flags, not a hardcoded --output-format text'; fi
cp "$SCRIPT_DIR/../runtime-permissions/opencode-read.json" "$TMP_DIR/read.json"; cp "$SCRIPT_DIR/../runtime-permissions/opencode-write.json" "$TMP_DIR/write.json"
RUNTIME_ARGV="$TMP_DIR/opencode.argv" PATH="$BIN:$PATH" bash "$RUNTIME" run --runtime opencode --role reviewer --mode read --cwd "$WT" --prompt-file "$WT/prompt.txt" --opencode-permission-file "$TMP_DIR/read.json"; if ! grep -Fx -- --auto "$TMP_DIR/opencode.argv" >/dev/null && grep -Fx -- agent-workflow "$TMP_DIR/opencode.argv" >/dev/null; then ok 'opencode applies deny-first inline config through explicit agent without auto'; else bad 'opencode config and explicit agent application'; fi
PATH="$BIN:$PATH" bash "$RUNTIME" run --runtime opencode --role implementation --mode write --cwd "$WT" --prompt-file "$WT/prompt.txt" >/dev/null 2>&1; if [ $? -ne 0 ]; then ok 'opencode missing permission config refused'; else bad 'opencode missing permission config'; fi
printf '{"permission":{"*":"deny","edit":"allow","external_directory":"deny","bash":"deny","webfetch":"deny"}}\n' > "$TMP_DIR/no-agent.json"
PATH="$BIN:$PATH" bash "$RUNTIME" run --runtime opencode --role implementation --mode write --cwd "$WT" --prompt-file "$WT/prompt.txt" --opencode-permission-file "$TMP_DIR/no-agent.json" >/dev/null 2>&1; if [ $? -ne 0 ]; then ok 'opencode config without explicit primary agent refused'; else bad 'opencode explicit primary agent'; fi
node - "$TMP_DIR/write.json" "$TMP_DIR/websearch-mismatch.json" <<'NODE'
const fs=require('fs'), c=JSON.parse(fs.readFileSync(process.argv[2],'utf8')); c.permission.websearch='deny'; fs.writeFileSync(process.argv[3],JSON.stringify(c));
NODE
PATH="$BIN:$PATH" bash "$RUNTIME" run --runtime opencode --role implementation --mode write --cwd "$WT" --prompt-file "$WT/prompt.txt" --opencode-permission-file "$TMP_DIR/websearch-mismatch.json" >/dev/null 2>&1; if [ $? -ne 0 ]; then ok 'opencode write requires webfetch/websearch allow on both scopes'; else bad 'opencode websearch allow required'; fi
PATH="$BIN:$PATH" bash "$RUNTIME" run --runtime opencode --role implementation --mode write --cwd "$WT" --prompt-file "$WT/prompt.txt" --opencode-permission-file "$TMP_DIR/read.json" >/dev/null 2>&1; if [ $? -ne 0 ]; then ok 'opencode write requires edit allow'; else bad 'opencode write permission'; fi
RUNTIME_ARGV="$TMP_DIR/opencode-write.argv" PATH="$BIN:$PATH" bash "$RUNTIME" run --runtime opencode --role release --mode write --cwd "$WT" --prompt-file "$WT/prompt.txt" --opencode-permission-file "$TMP_DIR/write.json"; if grep -Fx -- "$WT" "$TMP_DIR/opencode-write.argv" >/dev/null && grep -Fx -- agent-workflow "$TMP_DIR/opencode-write.argv" >/dev/null; then ok 'opencode write uses explicit cwd and configured agent'; else bad 'opencode write argv'; fi
[ "$FAILURES" -eq 0 ] && { echo 'ALL CASES PASS'; exit 0; }; echo "$FAILURES CASE(S) FAILED"; exit 1
