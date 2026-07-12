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
esac
exit 2
EOF
chmod +x "$BIN/codex"

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

WT_A="$(make_wt wt-success)"
run_watchdog "$WT_A" success 201 0
ec=$?
[ "$ec" -eq 0 ] && pass "success exits 0" || fail "success exits 0 (got $ec)"
status="$(marker_status "$WT_A/.review/ISSUE-201-RUN.json")"
[ "$status" = "exited" ] && pass "success marker exited" || fail "success marker exited"
validate_marker_basic "$WT_A/.review/ISSUE-201-RUN.json" && pass "success marker valid shape" || fail "success marker valid shape"

WT_B="$(make_wt wt-stall)"
run_watchdog "$WT_B" stall 202 1
ec=$?
[ "$ec" -eq 6 ] && pass "stall exhausts with exit 6" || fail "stall exhausts with exit 6 (got $ec)"
status="$(marker_status "$WT_B/.review/ISSUE-202-RUN.json")"
[ "$status" = "exhausted" ] && pass "stall marker exhausted" || fail "stall marker exhausted"

WT_C="$(make_wt wt-progress)"
run_watchdog "$WT_C" progress 203 0
ec=$?
[ "$ec" -eq 0 ] && pass "progressing run exits 0" || fail "progressing run exits 0 (got $ec)"
status="$(marker_status "$WT_C/.review/ISSUE-203-RUN.json")"
[ "$status" = "exited" ] && pass "progress marker exited" || fail "progress marker exited"

WT_D="$(make_wt wt-refuse)"
run_watchdog "$WT_D" refuse 204 2
ec=$?
[ "$ec" -eq 4 ] && pass "4xx refusal exits 4" || fail "4xx refusal exits 4 (got $ec)"
status="$(marker_status "$WT_D/.review/ISSUE-204-RUN.json")"
[ "$status" = "refused" ] && pass "4xx marker refused" || fail "4xx marker refused"

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
