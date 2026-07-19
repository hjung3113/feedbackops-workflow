#!/usr/bin/env bash
# Smoke test for scripts/codex-watchdog.sh.
# Offline: stubs codex, drives codex-safe through PATH.
# bash-3.2-compatible. Run: bash scripts/__tests__/codex-watchdog.smoke.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WATCHDOG="$SCRIPT_DIR/../codex-watchdog.sh"
RUN_SCHEMA="$SCRIPT_DIR/../../.review/schemas/run.schema.json"
RUN_FIXTURE="$SCRIPT_DIR/../../.review/schemas/fixtures/run.valid.json"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAILURES=0
pass() { echo "ok   - $1"; }
fail() { echo "NOT OK - $1"; FAILURES=$((FAILURES + 1)); }

BIN="$TMP_DIR/bin"
mkdir -p "$BIN"
cat > "$BIN/codex" <<'EOF'
#!/usr/bin/env bash
shift # exec
case "${CODEX_STUB_MODE:-success}" in
  success)
    printf '%s\n' "done" > "codex-success.txt"
    exit 0
    ;;
  stall)
    sleep 999
    exit 0
    ;;
  silent_success)
    sleep 4
    exit 0
    ;;
  silent_long_success)
    sleep 6
    exit 0
    ;;
  silent_7_success)
    sleep 7
    exit 0
    ;;
  progress)
    printf '%s\n' "one" > "codex-progress.txt"
    sleep 1
    printf '%s\n' "two" >> "codex-progress.txt"
    sleep 1
    exit 0
    ;;
  refuse)
    echo "404 model_not_found" >&2
    exit 1
    ;;
  pid_noise)
    # regression: a PID-like digit run containing "4dd" (bash prints these in
    # job-status lines on kill) must NOT be classified as a 4xx refusal.
    echo "codex-safe.sh: line 71: 74123 Terminated: 15  codex exec ..." >&2
    exit 1
    ;;
  status_code_content)
    echo "echoed file content: status 404 is ordinary fixture data" >&2
    exit 1
    ;;
  fail)
    echo "ordinary transient failure" >&2
    exit 1
    ;;
esac
exit 2
EOF
chmod +x "$BIN/codex"

cat > "$BIN/probe" <<'EOF'
#!/usr/bin/env bash
exit "${CODEX_PROBE_EXIT:-0}"
EOF
chmod +x "$BIN/probe"

make_wt() {
  d="$TMP_DIR/$1"
  mkdir -p "$d"
  printf '%s\n' "prompt" > "$d/prompt.txt"
  echo "$d"
}

marker_status() {
  node -e 'const fs=require("fs"); const o=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); process.stdout.write(o.status);' "$1"
}

validate_marker_basic() {
  file="$1"
  node -e '
    const fs = require("fs");
    const o = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const statuses = ["running", "exited", "killed_stall", "refused", "exhausted"];
    if (o.schema_version !== "1" || o.artifact_type !== "codex_run") process.exit(1);
    if (!Number.isInteger(o.issue) || !Number.isInteger(o.attempt)) process.exit(1);
    if (!o.started_at || !o.updated_at || statuses.indexOf(o.status) === -1) process.exit(1);
  ' "$file"
}

run_watchdog() {
  wt="$1"; mode="$2"; issue="$3"; retries="$4"
  CODEX_STUB_MODE="$mode" CODEX_WATCHDOG_POLL_INTERVAL=1 PATH="$BIN:$PATH" bash "$WATCHDOG" --issue "$issue" --prompt-file "$wt/prompt.txt" --cwd "$wt" --first-progress-timeout 2 --stall-timeout 3 --max-retries "$retries" >/dev/null 2>&1
  return $?
}

run_read_only_watchdog() {
  wt="$1"; issue="$2"
  CODEX_STUB_MODE=silent_7_success CODEX_SAFE_HEARTBEAT_INTERVAL=2 CODEX_WATCHDOG_POLL_INTERVAL=1 PATH="$BIN:$PATH" bash "$WATCHDOG" --issue "$issue" --prompt-file "$wt/prompt.txt" --cwd "$wt" --read-only --first-progress-timeout 2 --stall-timeout 4 --max-retries 0 >/dev/null 2>&1 &
  watchdog_pid=$!
  heartbeat="$wt/.review/HEARTBEAT-ISSUE-${issue}.json"
  # A 7s child with 2s ticks yields initial + at least two later mtimes;
  # the 4s stall budget must therefore never expire between ticks.
  ticks=0
  last_mtime=""
  i=0
  while [ "$i" -lt 8 ]; do
    sleep 1
    if [ -f "$heartbeat" ]; then
      mtime="$(stat -f %m "$heartbeat" 2>/dev/null || stat -c %Y "$heartbeat")"
      if [ "$mtime" != "$last_mtime" ]; then
        ticks=$((ticks + 1))
        last_mtime="$mtime"
      fi
    fi
    i=$((i + 1))
  done
  wait "$watchdog_pid"
  return $?
}

WT_A="$(make_wt wt-success)"
run_watchdog "$WT_A" success 201 0
ec=$?
[ "$ec" -eq 0 ] && pass "success exits 0" || fail "success exits 0 (got $ec)"
status="$(marker_status "$WT_A/.review/ISSUE-201-RUN.json")"
[ "$status" = "exited" ] && pass "success marker exited" || fail "success marker exited"
validate_marker_basic "$WT_A/.review/ISSUE-201-RUN.json" && pass "success marker valid shape" || fail "success marker valid shape"

WT_B="$(make_wt wt-stall)"
run_watchdog "$WT_B" silent_long_success 202 1
ec=$?
[ "$ec" -eq 6 ] && pass "non-read-only silent run exhausts with exit 6" || fail "non-read-only silent run exhausts with exit 6 (got $ec)"
status="$(marker_status "$WT_B/.review/ISSUE-202-RUN.json")"
[ "$status" = "exhausted" ] && pass "non-read-only silent marker exhausted" || fail "non-read-only silent marker exhausted"

WT_READ_ONLY="$(make_wt wt-read-only)"
run_read_only_watchdog "$WT_READ_ONLY" 206
ec=$?
[ "$ec" -eq 0 ] && pass "read-only silent run survives periodic stall budget" || fail "read-only silent run survives periodic stall budget (got $ec)"
status="$(marker_status "$WT_READ_ONLY/.review/ISSUE-206-RUN.json")"
[ "$status" = "exited" ] && pass "read-only silent run marker exited" || fail "read-only silent run marker exited"
[ "$ticks" -ge 3 ] && pass "read-only heartbeat advances at least twice after start" || fail "read-only heartbeat advances at least twice after start (ticks=$ticks)"

WT_C="$(make_wt wt-progress)"
run_watchdog "$WT_C" progress 203 0
ec=$?
[ "$ec" -eq 0 ] && pass "progressing run exits 0" || fail "progressing run exits 0 (got $ec)"
status="$(marker_status "$WT_C/.review/ISSUE-203-RUN.json")"
[ "$status" = "exited" ] && pass "progress marker exited" || fail "progress marker exited"

WT_D="$(make_wt wt-probe-refuse)"
CODEX_STUB_MODE=refuse CODEX_PROBE_EXIT=1 CODEX_WATCHDOG_PROBE_GAP=0 CODEX_WATCHDOG_PROBE_CMD="$BIN/probe" CODEX_WATCHDOG_POLL_INTERVAL=1 PATH="$BIN:$PATH" bash "$WATCHDOG" --issue 204 --prompt-file "$WT_D/prompt.txt" --cwd "$WT_D" --first-progress-timeout 2 --stall-timeout 3 --max-retries 2 >/dev/null 2>&1
ec=$?
[ "$ec" -eq 4 ] && pass "failed probe exits 4" || fail "failed probe exits 4 (got $ec)"
status="$(marker_status "$WT_D/.review/ISSUE-204-RUN.json")"
[ "$status" = "refused" ] && pass "failed probe marker refused" || fail "failed probe marker refused"

WT_D2="$(make_wt wt-probe-fail-then-succeed)"
PROBE_COUNT="$TMP_DIR/probe-count"
cat > "$BIN/probe-fail-then-succeed" <<'EOF'
#!/usr/bin/env bash
n=0
[ -f "$CODEX_PROBE_COUNT" ] && n="$(cat "$CODEX_PROBE_COUNT")"
n=$((n + 1))
printf '%s\n' "$n" > "$CODEX_PROBE_COUNT"
[ "$n" -eq 1 ] && exit 1
exit 0
EOF
chmod +x "$BIN/probe-fail-then-succeed"
CODEX_STUB_MODE=fail CODEX_PROBE_COUNT="$PROBE_COUNT" CODEX_WATCHDOG_PROBE_GAP=0 CODEX_WATCHDOG_PROBE_CMD="$BIN/probe-fail-then-succeed" CODEX_WATCHDOG_POLL_INTERVAL=1 PATH="$BIN:$PATH" bash "$WATCHDOG" --issue 208 --prompt-file "$WT_D2/prompt.txt" --cwd "$WT_D2" --first-progress-timeout 2 --stall-timeout 3 --max-retries 1 >/dev/null 2>&1
ec=$?
[ "$ec" -eq 6 ] && pass "fail-then-succeed probe keeps retrying" || fail "fail-then-succeed probe keeps retrying (got $ec)"
status="$(marker_status "$WT_D2/.review/ISSUE-208-RUN.json")"
[ "$status" = "exhausted" ] && pass "fail-then-succeed probe is not refused" || fail "fail-then-succeed probe is not refused (got $status)"

WT_E="$(make_wt wt-status-code-content)"
OUTPUT_E="$TMP_DIR/status-code-content.out"
CODEX_STUB_MODE=status_code_content CODEX_PROBE_EXIT=0 CODEX_WATCHDOG_PROBE_CMD="$BIN/probe" CODEX_WATCHDOG_POLL_INTERVAL=1 PATH="$BIN:$PATH" bash "$WATCHDOG" --issue 205 --prompt-file "$WT_E/prompt.txt" --cwd "$WT_E" --first-progress-timeout 2 --stall-timeout 3 --max-retries 1 >"$OUTPUT_E" 2>&1
ec=$?
[ "$ec" -eq 6 ] && pass "bare status-code stderr is not a refusal (exits 6)" || fail "bare status-code stderr is not a refusal (expected 6, got $ec)"
status="$(marker_status "$WT_E/.review/ISSUE-205-RUN.json")"
[ "$status" = "exhausted" ] && pass "bare status-code marker exhausted" || fail "bare status-code marker exhausted (got $status)"
stderr_e="$WT_E/.review/ISSUE-205-attempt1-stderr.log"
[ -f "$stderr_e" ] && pass "non-zero attempt stderr is preserved" || fail "non-zero attempt stderr is preserved"
grep -q "$stderr_e" "$OUTPUT_E" && pass "preserved stderr path is echoed" || fail "preserved stderr path is echoed"

WT_F="$(make_wt wt-probe-transient)"
CODEX_STUB_MODE=fail CODEX_PROBE_EXIT=0 CODEX_WATCHDOG_PROBE_CMD="$BIN/probe" CODEX_WATCHDOG_POLL_INTERVAL=1 PATH="$BIN:$PATH" bash "$WATCHDOG" --issue 207 --prompt-file "$WT_F/prompt.txt" --cwd "$WT_F" --first-progress-timeout 2 --stall-timeout 3 --max-retries 1 >/dev/null 2>&1
ec=$?
[ "$ec" -eq 6 ] && pass "successful probe keeps failed attempts retryable" || fail "successful probe keeps failed attempts retryable (got $ec)"
status="$(marker_status "$WT_F/.review/ISSUE-207-RUN.json")"
[ "$status" = "exhausted" ] && pass "successful probe never marks refused" || fail "successful probe never marks refused (got $status)"
[ -f "$WT_F/.review/ISSUE-207-attempt2-stderr.log" ] && pass "successful probe reaches retry attempt" || fail "successful probe reaches retry attempt"

validate_marker_basic "$RUN_FIXTURE" && pass "run fixture valid shape" || fail "run fixture valid shape"
node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$RUN_SCHEMA" >/dev/null 2>&1 && pass "run schema parses" || fail "run schema parses"

echo "---"
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASS"
  exit 0
else
  echo "$FAILURES CASE(S) FAILED"
  exit 1
fi
