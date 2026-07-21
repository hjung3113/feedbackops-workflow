#!/usr/bin/env bash
# End-to-end smoke for the public REVIEWER publication seam.
# bash-3.2-compatible.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DISPATCH="$SCRIPT_DIR/../cmux-dispatch.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
FAILURES=0

pass() { echo "ok   - $1"; }
fail() { echo "NOT OK - $1"; FAILURES=$((FAILURES + 1)); }

WT="$TMP_ROOT/wt"
BIN="$TMP_ROOT/bin"
mkdir -p "$WT/.review" "$BIN"
git init -q "$WT"
git -C "$WT" -c user.name=smoke -c user.email=smoke@example.test commit --allow-empty -qm init
printf '%s\n' "return one REVIEW JSON object only" > "$WT/.review/ISSUE-370-PROMPT.txt"

both_out="$TMP_ROOT/both.out"
bash "$DISPATCH" --issue 370 --worktree "$WT" --read-only --produce-review --dry-run >"$both_out" 2>&1
both_ec=$?
if [ "$both_ec" -eq 2 ] && grep -q "mutually exclusive" "$both_out"; then
  pass "produce-review is an explicit mode, not an add-on to liveness-only read-only"
else
  fail "read-only and produce-review should be mutually exclusive (exit=$both_ec)"
fi

unpinned_out="$TMP_ROOT/unpinned.out"
bash "$DISPATCH" --issue 370 --worktree "$WT" --produce-review --dry-run >"$unpinned_out" 2>&1
unpinned_ec=$?
if [ "$unpinned_ec" -eq 2 ] && grep -q "explicit --model and --effort" "$unpinned_out"; then
  pass "produce-review refuses an unpinned REVIEWER model allocation"
else
  fail "produce-review should require model and effort (exit=$unpinned_ec)"
fi

cat > "$BIN/cmux" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo 'cmux 0.64.18'; exit 0; fi
if [ "${1:-}" = "workspace" ] && [ "${2:-}" = "create" ] && [ "${3:-}" = "--help" ]; then echo 'create [flags]'; exit 0; fi
if [ "${1:-}" = "new-workspace" ] && [ "${2:-}" = "--help" ]; then echo '--cwd PATH --command TEXT'; exit 0; fi
cwd=""
command=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --cwd) cwd="$2"; shift 2 ;;
    --command) command="$2"; shift 2 ;;
    *) shift 1 ;;
  esac
done
[ -n "$command" ] || exit 8
[ -n "$cwd" ] || exit 11
(cd "$cwd" && bash -c "$command") >/dev/null 2>&1 || :
printf '%s\n' '{"id":"review-publish-smoke-workspace"}'
EOF
chmod +x "$BIN/cmux"

cat > "$BIN/codex" <<'EOF'
#!/usr/bin/env bash
output=""
sandbox=""
if [ "${1:-}" = "--version" ]; then echo 'codex review smoke 1.0'; exit 0; fi
if [ "${1:-}" = "--help" ]; then echo 'Commands: exec'; exit 0; fi
if [ "${1:-}" = "exec" ] && [ "${2:-}" = "--help" ]; then
  echo 'exec --sandbox --cd --model --config --output-last-message'
  exit 0
fi
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output-last-message) output="$2"; shift 2 ;;
    --sandbox) sandbox="$2"; shift 2 ;;
    *) shift 1 ;;
  esac
done
[ "$sandbox" = "read-only" ] || exit 9
[ -n "$output" ] || exit 10
case "${REVIEW_STUB_MODE:-valid}" in
  valid)
    head_sha="$(git rev-parse HEAD)"
    printf '%s\n' "{\"schema_version\":\"1\",\"artifact_type\":\"review\",\"lifecycle\":\"final\",\"producer_role\":\"REVIEWER\",\"issue\":{\"number\":370},\"reviewed_head_sha\":\"$head_sha\",\"status\":\"pass\",\"checklist\":[{\"item\":\"smoke\",\"met\":true}]}" > "$output"
    ;;
  invalid)
    printf '%s\n' '{"status":"fail"}' > "$output"
    ;;
  wrong_issue)
    head_sha="$(git rev-parse HEAD)"
    printf '%s\n' "{\"schema_version\":\"1\",\"artifact_type\":\"review\",\"lifecycle\":\"final\",\"producer_role\":\"REVIEWER\",\"issue\":{\"number\":371},\"reviewed_head_sha\":\"$head_sha\",\"status\":\"pass\",\"checklist\":[{\"item\":\"smoke\",\"met\":true}]}" > "$output"
    ;;
  stale_head)
    printf '%s\n' '{"schema_version":"1","artifact_type":"review","lifecycle":"final","producer_role":"REVIEWER","issue":{"number":370},"reviewed_head_sha":"0000000000000000000000000000000000000000","status":"pass","checklist":[{"item":"smoke","met":true}]}' > "$output"
    ;;
  fail_missing_fields)
    head_sha="$(git rev-parse HEAD)"
    printf '%s\n' "{\"schema_version\":\"1\",\"artifact_type\":\"review\",\"lifecycle\":\"final\",\"producer_role\":\"REVIEWER\",\"issue\":{\"number\":370},\"reviewed_head_sha\":\"$head_sha\",\"status\":\"fail\",\"checklist\":[{\"item\":\"smoke\",\"met\":false}]}" > "$output"
    ;;
  nonzero)
    printf '%s\n' '{"untrusted":"partial"}' > "$output"
    exit 7
    ;;
esac
EOF
chmod +x "$BIN/codex"

run_review() {
  mode="$1"
  REVIEW_STUB_MODE="$mode" CMUX_DISPATCH_POLL_INTERVAL=1 AGENT_WATCHDOG_POLL_INTERVAL=1 CODEX_WATCHDOG_POLL_INTERVAL=1 CODEX_WATCHDOG_PROBE_GAP=0 CODEX_WATCHDOG_PROBE_CMD=false PATH="$BIN:$PATH" \
    bash "$DISPATCH" --issue 370 --worktree "$WT" --produce-review --model gpt-5.6-sol --effort medium --poll-timeout 5
}

valid_out="$TMP_ROOT/valid.out"
run_review valid >"$valid_out" 2>&1
valid_ec=$?
canonical="$WT/.review/ISSUE-370-REVIEW.json"
temp_count() { find "$WT/.review" -name '.ISSUE-370-REVIEW.json.tmp.*' -type f | wc -l | tr -d ' '; }
if [ "$valid_ec" -eq 0 ] && [ -f "$canonical" ] && [ "$(temp_count)" -eq 0 ] && node -e 'const a=require(process.argv[1]); process.exit(a.producer_role === "REVIEWER" && a.issue.number === 370 && a.status === "pass" ? 0 : 1)' "$canonical"; then
  pass "produce-review publishes a validated canonical REVIEW under real read-only sandbox arguments"
else
  fail "valid REVIEW publication failed (exit=$valid_ec: $(cat "$valid_out"))"
fi

canonical_before="$(shasum -a 256 "$canonical" | awk '{print $1}')"
invalid_out="$TMP_ROOT/invalid.out"
run_review invalid >"$invalid_out" 2>&1
invalid_ec=$?
canonical_after="$(shasum -a 256 "$canonical" | awk '{print $1}')"
invalid_status="$(node -e 'const a=require(process.argv[1]); process.stdout.write(a.status)' "$WT/.review/ISSUE-370-RUN.json")"
if [ "$invalid_ec" -eq 0 ] && [ "$invalid_status" = "refused" ] && [ "$canonical_before" = "$canonical_after" ] && [ "$(temp_count)" -eq 0 ]; then
  pass "invalid REVIEW output preserves the prior canonical artifact and removes temp output"
else
  fail "invalid REVIEW handling was not atomic (dispatch=$invalid_ec run=$invalid_status)"
fi

for rejected_mode in wrong_issue stale_head fail_missing_fields; do
  sleep 1
  rejected_out="$TMP_ROOT/$rejected_mode.out"
  run_review "$rejected_mode" >"$rejected_out" 2>&1
  rejected_ec=$?
  rejected_status="$(node -e 'const a=require(process.argv[1]); process.stdout.write(a.status)' "$WT/.review/ISSUE-370-RUN.json")"
  rejected_hash="$(shasum -a 256 "$canonical" | awk '{print $1}')"
  if [ "$rejected_ec" -eq 0 ] && [ "$rejected_status" = "refused" ] && [ "$canonical_before" = "$rejected_hash" ] && [ "$(temp_count)" -eq 0 ]; then
    pass "$rejected_mode REVIEW output is rejected without replacing canonical evidence"
  else
    fail "$rejected_mode REVIEW rejection failed (dispatch=$rejected_ec run=$rejected_status)"
  fi
done

nonzero_out="$TMP_ROOT/nonzero.out"
# RUN freshness uses second-resolution mtime + started_at; keep this distinct
# from the immediately preceding same-issue attempt.
sleep 1
run_review nonzero >"$nonzero_out" 2>&1
nonzero_ec=$?
canonical_final="$(shasum -a 256 "$canonical" | awk '{print $1}')"
nonzero_status="$(node -e 'const a=require(process.argv[1]); process.stdout.write(a.status)' "$WT/.review/ISSUE-370-RUN.json")"
if [ "$nonzero_ec" -eq 0 ] && [ "$nonzero_status" = "refused" ] && [ "$canonical_before" = "$canonical_final" ] && [ "$(temp_count)" -eq 0 ]; then
  pass "nonzero reviewer exit cannot replace canonical REVIEW and leaves no temp output"
else
  fail "nonzero REVIEW handling was not atomic (dispatch=$nonzero_ec run=$nonzero_status)"
fi

if [ ! -d "$WT/.review/.write-dispatch-issue-370-started" ]; then
  pass "produce-review remains outside write admission"
else
  fail "produce-review created a write-admission marker"
fi

echo "---"
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASS"
  exit 0
fi
echo "$FAILURES CASE(S) FAILED"
exit 1
