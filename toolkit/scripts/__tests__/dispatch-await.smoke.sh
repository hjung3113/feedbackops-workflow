#!/usr/bin/env bash
# #163 await subcommand smoke: dispatch-core.sh await blocks on the append-only
# EVENTS.jsonl log until a terminal status line (exited/killed_stall/refused/
# exhausted) appears, or times out. Purely a reader: nothing is launched.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DISPATCH="$SCRIPT_DIR/../dispatch-core.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0
ok() { echo "ok   - $1"; }
bad() { echo "NOT OK - $1"; FAIL=$((FAIL + 1)); }

AW_CWD="$TMP/wt"
mkdir -p "$AW_CWD/.review"
EVENTS="$AW_CWD/.review/ISSUE-163-EVENTS.jsonl"

# (a) non-terminal running line only: await must NOT return before timeout.
printf '%s\n' '{"ts":"2026-08-18T12:00:00Z","attempt":1,"event":"run_status","status":"running","detail":""}' > "$EVENTS"
AWAIT_TIMEOUT_OUT="$TMP/await-timeout.out"
AGENT_WORKFLOW_POLL_INTERVAL=1 bash "$DISPATCH" await --issue 163 --cwd "$AW_CWD" --timeout-seconds 2 >"$AWAIT_TIMEOUT_OUT" 2>"$TMP/await-timeout.err"
ec=$?
if [ "$ec" -eq 1 ] && grep -q "ERROR: await timed out after 2s waiting for terminal status in $EVENTS" "$TMP/await-timeout.err" && [ ! -s "$AWAIT_TIMEOUT_OUT" ]; then
  ok "#163 await times out on non-terminal-only EVENTS.jsonl"
else
  bad "#163 await timeout on non-terminal-only EVENTS.jsonl (ec=$ec: $(cat "$TMP/await-timeout.err"))"
fi

# (b) terminal line appended while await is polling: returns 0 promptly with
# that exact line on stdout.
rm -f "$EVENTS"
( sleep 2; printf '%s\n' '{"ts":"2026-08-18T12:00:05Z","attempt":1,"event":"run_status","status":"running","detail":""}' '{"ts":"2026-08-18T12:00:10Z","attempt":1,"event":"run_status","status":"exited","detail":""}' >> "$EVENTS" ) &
appender_pid=$!
AWAIT_LIVE_OUT="$TMP/await-live.out"
AWAIT_START="$(date +%s)"
AGENT_WORKFLOW_POLL_INTERVAL=1 bash "$DISPATCH" await --issue 163 --cwd "$AW_CWD" --timeout-seconds 30 >"$AWAIT_LIVE_OUT" 2>"$TMP/await-live.err"
ec=$?
AWAIT_ELAPSED=$(( $(date +%s) - AWAIT_START ))
wait "$appender_pid" 2>/dev/null
expected_terminal='{"ts":"2026-08-18T12:00:10Z","attempt":1,"event":"run_status","status":"exited","detail":""}'
if [ "$ec" -eq 0 ] && [ "$AWAIT_ELAPSED" -le 15 ] && [ "$(cat "$AWAIT_LIVE_OUT")" = "$expected_terminal" ]; then
  ok "#163 await returns terminal line appended while polling"
else
  bad "#163 await live terminal append (ec=$ec elapsed=${AWAIT_ELAPSED}s out=$(cat "$AWAIT_LIVE_OUT"))"
fi

# (c) admission-failure case: a lone admission_refused/refused line is already
# terminal — await returns 0 immediately. This is the exact gap the issue
# calls out: admission failures never write RUN.json at all.
AWAIT_ADMIT_OUT="$TMP/await-admission.out"
printf '%s\n' '{"ts":"2026-08-18T12:00:15Z","attempt":0,"event":"admission_refused","status":"refused","detail":"route_mode_unbound"}' >> "$EVENTS"
AGENT_WORKFLOW_POLL_INTERVAL=1 bash "$DISPATCH" await --issue 163 --cwd "$AW_CWD" --timeout-seconds 30 >"$AWAIT_ADMIT_OUT" 2>/dev/null
ec=$?
if [ "$ec" -eq 0 ] && grep -q '"event":"admission_refused"' "$AWAIT_ADMIT_OUT" && grep -q '"status":"refused"' "$AWAIT_ADMIT_OUT"; then
  ok "#163 await treats admission_refused line as terminal"
else
  bad "#163 await admission_refused terminal (ec=$ec out=$(cat "$AWAIT_ADMIT_OUT"))"
fi

echo "---"
if [ "$FAIL" -eq 0 ]; then
  echo "ALL CASES PASS"
  exit 0
fi
echo "$FAIL CASE(S) FAILED"
exit 1
