#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; WATCHDOG="$SCRIPT_DIR/../agent-watchdog.sh"; TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT; FAIL=0
ok(){ echo "ok   - $1"; }; bad(){ echo "NOT OK - $1"; FAIL=$((FAIL + 1)); }
BIN="$TMP/bin"; WT="$TMP/wt"; mkdir -p "$BIN" "$WT"; printf 'p\n' > "$WT/prompt.txt"; git -C "$WT" init -q; git -C "$WT" config user.email t@t; git -C "$WT" config user.name t; git -C "$WT" add prompt.txt; git -C "$WT" commit -qm seed; HEAD="$(git -C "$WT" rev-parse HEAD)"
cat > "$BIN/opencode" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then echo 9.9; exit 0; fi
if [ "$1" = "--help" ] || { [ "$1" = run ] && [ "$2" = "--help" ]; }; then echo 'run --dir --format --agent --model --variant'; exit 0; fi
if [ "$OPENCODE_STUB_MODE" = fail ]; then exit 9; fi
if [ "$OPENCODE_STUB_MODE" = authfail ]; then echo 'authentication failed: invalid api key' >&2; exit 9; fi
if [ "$OPENCODE_STUB_MODE" = transient ]; then
  n=0; [ -f "$OPENCODE_STUB_COUNT" ] && n="$(cat "$OPENCODE_STUB_COUNT")"; n=$((n + 1)); printf '%s\n' "$n" > "$OPENCODE_STUB_COUNT"
  [ "$n" -eq 1 ] && { echo 'temporary upstream failure' >&2; exit 9; }
fi
printf '%s\n' "$OPENCODE_STUB_OUTPUT"
EOF
chmod +x "$BIN/opencode"
cat > "$BIN/codex" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then echo 9.9; exit 0; fi
if [ "$1" = "--help" ]; then echo exec; exit 0; fi
if [ "$1" = exec ] && [ "$2" = "--help" ]; then echo 'exec --sandbox --cd --model --config --output-last-message'; exit 0; fi
if [ "$1" = exec ]; then printf '%s\n' "${CODEX_STUB_OUTPUT:-ok}"; exit 0; fi
exit 2
EOF
cat > "$BIN/probe" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$BIN/codex" "$BIN/probe"
cp "$SCRIPT_DIR/../runtime-permissions/opencode-read.json" "$TMP/read.json"
review="{\"schema_version\":\"1\",\"artifact_type\":\"review\",\"lifecycle\":\"final\",\"producer_role\":\"REVIEWER\",\"issue\":{\"number\":77},\"reviewed_head_sha\":\"$HEAD\",\"status\":\"pass\",\"checklist\":[{\"item\":\"ok\",\"met\":true}]}"
OPENCODE_STUB_OUTPUT="$review" AGENT_WATCHDOG_POLL_INTERVAL=1 PATH="$BIN:$PATH" bash "$WATCHDOG" --issue 77 --runtime opencode --role reviewer --mode read --prompt-file "$WT/prompt.txt" --cwd "$WT" --opencode-permission-file "$TMP/read.json" --produce-review --first-progress-timeout 5 --stall-timeout 5 >/dev/null 2>&1
if [ $? -eq 0 ] && node -e 'const o=require(process.argv[1]); if(o.artifact_type!=="agent_run"||o.runtime!=="opencode"||o.role!=="reviewer"||!o.runtime_version||o.status!=="exited")process.exit(1)' "$WT/.review/ISSUE-77-RUN.json" && [ -f "$WT/.review/ISSUE-77-REVIEW.json" ]; then ok 'opencode reviewer publishes validated review and typed run'; else bad 'validated review publication'; fi
cp "$SCRIPT_DIR/../runtime-permissions/opencode-write.json" "$TMP/write.json"
OPENCODE_STUB_MODE=authfail AGENT_WATCHDOG_POLL_INTERVAL=1 PATH="$BIN:$PATH" bash "$WATCHDOG" --issue 78 --runtime opencode --role implementation --mode write --prompt-file "$WT/prompt.txt" --cwd "$WT" --opencode-permission-file "$TMP/write.json" --first-progress-timeout 5 --stall-timeout 5 >/dev/null 2>&1
if [ $? -ne 0 ] && node -e 'const o=require(process.argv[1]); if(o.status!=="refused"||o.runtime!=="opencode")process.exit(1)' "$WT/.review/ISSUE-78-RUN.json"; then ok 'runtime failure retains typed refused marker'; else bad 'runtime failure marker'; fi
COUNT="$TMP/transient-count"
OPENCODE_STUB_MODE=transient OPENCODE_STUB_COUNT="$COUNT" AGENT_WATCHDOG_PROBE_CMD="$BIN/probe" AGENT_WATCHDOG_PROBE_GAP=0 AGENT_WATCHDOG_POLL_INTERVAL=1 PATH="$BIN:$PATH" bash "$WATCHDOG" --issue 79 --runtime opencode --role implementation --mode write --prompt-file "$WT/prompt.txt" --cwd "$WT" --opencode-permission-file "$TMP/write.json" --first-progress-timeout 5 --stall-timeout 5 --max-retries 1 >/dev/null 2>&1
if [ $? -eq 0 ] && node -e 'const o=require(process.argv[1]); if(o.status!=="exited"||o.attempt!==2||o.runtime!=="opencode")process.exit(1)' "$WT/.review/ISSUE-79-RUN.json" && [ -f "$WT/.review/ISSUE-79-agent-attempt1-stderr.log" ]; then ok 'transient runtime failure retries with canonical attempt increment'; else bad 'transient retry attempt identity'; fi
AGENT_WATCHDOG_POLL_INTERVAL=1 PATH="$BIN:$PATH" bash "$WATCHDOG" --issue 80 --runtime codex --role reviewer --mode read --prompt-file "$WT/prompt.txt" --cwd "$WT" --first-progress-timeout 5 --stall-timeout 5 >/dev/null 2>&1
if [ $? -eq 0 ] && node -e 'const o=require(process.argv[1]); if(o.status!=="exited"||o.attempt!==1||o.runtime!=="codex"||o.role!=="reviewer")process.exit(1)' "$WT/.review/ISSUE-80-RUN.json"; then ok 'codex read runtime remains compatible with typed watchdog'; else bad 'codex runtime compatibility'; fi
[ "$FAIL" -eq 0 ] && { echo 'ALL CASES PASS'; exit 0; }; exit 1
