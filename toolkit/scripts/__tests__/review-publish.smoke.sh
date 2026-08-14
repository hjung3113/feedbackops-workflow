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
if [ "$unpinned_ec" -eq 2 ] && grep -q "explicit --model" "$unpinned_out"; then
  pass "produce-review refuses an unpinned REVIEWER model allocation"
else
  fail "produce-review should require an explicit model (exit=$unpinned_ec)"
fi

cat > "$BIN/cmux" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo 'cmux 0.64.18'; exit 0; fi
if [ "${1:-}" = "workspace" ] && [ "${2:-}" = "create" ] && [ "${3:-}" = "--help" ]; then echo 'create [flags]          Create a workspace (same flags as new-workspace)'; exit 0; fi
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
  head_drift)
    head_sha="$(git rev-parse HEAD)"
    printf '%s\n' "{\"schema_version\":\"1\",\"artifact_type\":\"review\",\"lifecycle\":\"final\",\"producer_role\":\"REVIEWER\",\"issue\":{\"number\":370},\"reviewed_head_sha\":\"$head_sha\",\"status\":\"pass\",\"checklist\":[{\"item\":\"smoke\",\"met\":true}]}" > "$output"
    git -c user.name=Smoke -c user.email=smoke@example.test commit --allow-empty -qm "drift after review"
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
  REVIEW_STUB_MODE="$mode" AGENT_WORKFLOW_MODEL_PROBE_CMD='[ "$MODEL" = "gpt-5.6-sol" ]' AGENT_WORKFLOW_POLL_INTERVAL=1 AGENT_WATCHDOG_POLL_INTERVAL=1 CODEX_WATCHDOG_POLL_INTERVAL=1 CODEX_WATCHDOG_PROBE_GAP=0 CODEX_WATCHDOG_PROBE_CMD=false PATH="$BIN:$PATH" \
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

review_head="$(git -C "$WT" rev-parse HEAD)"
snapshot="$WT/.review/ISSUE-370-REVIEW-$review_head.json"
if [ -f "$snapshot" ] && cmp -s "$snapshot" "$canonical"; then
  pass "valid REVIEW publication retains an immutable head-bound snapshot"
else
  fail "valid REVIEW publication did not retain an immutable head-bound snapshot"
fi
node - "$canonical" "$TMP_ROOT/conflicting-review.json" <<'NODE'
const fs=require("fs"); const [source,destination]=process.argv.slice(2); const value=JSON.parse(fs.readFileSync(source)); value.status="fail"; fs.writeFileSync(destination,JSON.stringify(value));
NODE
if node "$SCRIPT_DIR/../lib/review-snapshot.cjs" "$TMP_ROOT/conflicting-review.json" "$WT/.review" 370 >/dev/null 2>&1; then
  fail "immutable REVIEW snapshot refuses differing overwrite"
else
  pass "immutable REVIEW snapshot refuses differing overwrite"
fi

# Two writers racing to create the same head-bound snapshot must converge on
# the first byte sequence; the losing EEXIST path must compare bytes.
RACE_DIR="$TMP_ROOT/review-race"
mkdir -p "$RACE_DIR"
cp "$canonical" "$RACE_DIR/a.json"
cp "$TMP_ROOT/conflicting-review.json" "$RACE_DIR/b.json"
rm -f "$RACE_DIR/ISSUE-370-REVIEW-$review_head.json"
node "$SCRIPT_DIR/../lib/review-snapshot.cjs" "$RACE_DIR/a.json" "$RACE_DIR" 370 >/dev/null 2>&1 & race_a=$!
node "$SCRIPT_DIR/../lib/review-snapshot.cjs" "$RACE_DIR/b.json" "$RACE_DIR" 370 >/dev/null 2>&1 & race_b=$!
wait "$race_a"; race_a_ec=$?
wait "$race_b"; race_b_ec=$?
if { [ "$race_a_ec" -eq 0 ] && [ "$race_b_ec" -ne 0 ]; } || { [ "$race_a_ec" -ne 0 ] && [ "$race_b_ec" -eq 0 ]; }; then
  if [ -f "$RACE_DIR/ISSUE-370-REVIEW-$review_head.json" ] && { cmp -s "$RACE_DIR/ISSUE-370-REVIEW-$review_head.json" "$RACE_DIR/a.json" || cmp -s "$RACE_DIR/ISSUE-370-REVIEW-$review_head.json" "$RACE_DIR/b.json"; }; then
    pass "racing REVIEW snapshot writers preserve first content without overwrite"
  else
    fail "racing REVIEW snapshot destination differs from both writers"
  fi
else
  fail "racing REVIEW snapshot writers did not produce one winner (a=$race_a_ec b=$race_b_ec)"
fi

canonical_before="$(shasum -a 256 "$canonical" | awk '{print $1}')"
invalid_out="$TMP_ROOT/invalid.out"
run_review invalid >"$invalid_out" 2>&1
invalid_ec=$?
canonical_after="$(shasum -a 256 "$canonical" | awk '{print $1}')"
invalid_status="$(node -e 'const a=require(process.argv[1]); process.stdout.write(a.status)' "$WT/.review/ISSUE-370-RUN.json")"
invalid_reason="$(node -e 'const a=require(process.argv[1]); process.stdout.write(Object.prototype.hasOwnProperty.call(a,"refusal_reason")?"present":"absent")' "$WT/.review/ISSUE-370-RUN.json")"
if [ "$invalid_ec" -eq 0 ] && [ "$invalid_status" = "refused" ] && [ "$invalid_reason" = "absent" ] && [ "$canonical_before" = "$canonical_after" ] && [ "$(temp_count)" -eq 0 ]; then
  pass "Codex invalid REVIEW preserves prior evidence without typed refusal diagnostics"
else
  fail "Codex invalid REVIEW handling changed (dispatch=$invalid_ec run=$invalid_status reason=$invalid_reason)"
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

canonical_before_drift="$(shasum -a 256 "$canonical" | awk '{print $1}')"
drift_out="$TMP_ROOT/head-drift.out"
sleep 1
run_review head_drift >"$drift_out" 2>&1
drift_ec=$?
canonical_after_drift="$(shasum -a 256 "$canonical" | awk '{print $1}')"
drift_status="$(node -e 'const a=require(process.argv[1]); process.stdout.write(a.status)' "$WT/.review/ISSUE-370-RUN.json" 2>/dev/null || true)"
if [ "$canonical_before_drift" = "$canonical_after_drift" ] && [ "$drift_status" = refused ]; then
  pass "REVIEW HEAD drift refuses publication without replacing canonical evidence"
else
  fail "REVIEW HEAD drift was not atomically rejected (dispatch=$drift_ec run=$drift_status)"
fi

# Widen the final-check/rename window and commit concurrently. The helper must
# refuse the old-head bytes and leave the prior canonical artifact untouched.
window_before="$canonical_after_drift"
window_head="$(git -C "$WT" rev-parse HEAD)"
window_source="$TMP_ROOT/window-review.json"
node - "$canonical" "$window_source" "$window_head" <<'NODE'
const fs=require("fs"); const [source,destination,head]=process.argv.slice(2); const value=JSON.parse(fs.readFileSync(source)); value.reviewed_head_sha=head; fs.writeFileSync(destination,JSON.stringify(value));
NODE
window_expected="$(shasum -a 256 "$window_source" | awk '{print $1}')"
window_commit_status="$TMP_ROOT/window-commit.status"
REVIEW_PUBLISH_PRE_RENAME_DELAY=2 node "$SCRIPT_DIR/../lib/review-publish.cjs" "$window_source" "$WT/.review" 370 "$WT" "$window_head" >"$TMP_ROOT/window-publish.out" 2>&1 & window_publish_pid=$!
window_polls=0
window_lock_ready=0
while [ ! -d "$WT/.git/HEAD.lock" ] && [ "$window_polls" -lt 30 ]; do sleep 0.1; window_polls=$((window_polls + 1)); done
[ -d "$WT/.git/HEAD.lock" ] && window_lock_ready=1
git -C "$WT" -c user.name=Smoke -c user.email=smoke@example.test commit --allow-empty -qm "commit during review publication"
echo "$?" > "$window_commit_status"
wait "$window_publish_pid"
window_ec=$?
window_after="$(shasum -a 256 "$canonical" | awk '{print $1}')"
window_commit_ec="$(cat "$window_commit_status" 2>/dev/null || echo 99)"
if [ "$window_lock_ready" -eq 1 ] && [ "$window_ec" -eq 0 ] && [ "$window_commit_ec" -ne 0 ] && [ "$window_expected" = "$window_after" ] && [ "$(temp_count)" -eq 0 ]; then
  pass "Git commit cannot interleave locked REVIEW publication"
else
  fail "Git commit interleaved REVIEW publication (lock=$window_lock_ready publish=$window_ec commit=$window_commit_ec: $(cat "$TMP_ROOT/window-publish.out" 2>/dev/null))"
fi

# The runner's output path is mutable. Once publication has read and
# validated it, a later rewrite must not make the immutable snapshot differ
# from the canonical bytes.
# Advance to a fresh review target: the prior snapshot for the preceding HEAD
# is intentionally immutable and must reject different bytes.
git -C "$WT" -c user.name=Smoke -c user.email=smoke@example.test commit --allow-empty -qm "advance review snapshot fixture"
bytes_head="$(git -C "$WT" rev-parse HEAD)"
bytes_source="$TMP_ROOT/bytes-review.json"
bytes_original="$TMP_ROOT/bytes-review-original.json"
node - "$canonical" "$bytes_source" "$bytes_head" <<'NODE'
const fs=require("fs"); const [source,destination,head]=process.argv.slice(2); const value=JSON.parse(fs.readFileSync(source)); value.reviewed_head_sha=head; value.checklist=[{item:"validated-bytes",met:true}]; fs.writeFileSync(destination,JSON.stringify(value));
NODE
cp "$bytes_source" "$bytes_original"
bytes_sentinel="$TMP_ROOT/bytes-read.sentinel"
REVIEW_PUBLISH_POST_READ_SENTINEL="$bytes_sentinel" REVIEW_PUBLISH_POST_READ_DELAY=2 node "$SCRIPT_DIR/../lib/review-publish.cjs" "$bytes_source" "$WT/.review" 370 "$WT" "$bytes_head" >"$TMP_ROOT/bytes-publish.out" 2>&1 & bytes_publish_pid=$!
bytes_polls=0
while [ ! -f "$bytes_sentinel" ] && [ "$bytes_polls" -lt 30 ]; do sleep 0.1; bytes_polls=$((bytes_polls + 1)); done
node - "$bytes_source" "$bytes_head" <<'NODE'
const fs=require("fs"); const [file,head]=process.argv.slice(2); const value=JSON.parse(fs.readFileSync(file)); value.reviewed_head_sha=head; value.checklist=[{item:"mutated-after-read",met:true}]; fs.writeFileSync(file,JSON.stringify(value));
NODE
wait "$bytes_publish_pid"; bytes_ec=$?
bytes_snapshot="$WT/.review/ISSUE-370-REVIEW-$bytes_head.json"
if [ "$bytes_polls" -lt 30 ] && [ "$bytes_ec" -eq 0 ] && cmp -s "$bytes_original" "$canonical" && cmp -s "$bytes_original" "$bytes_snapshot"; then
  pass "REVIEW snapshot and canonical consume one validated byte sequence"
else
  fail "REVIEW publication reread mutable source bytes (ready=$bytes_polls exit=$bytes_ec: $(cat "$TMP_ROOT/bytes-publish.out" 2>/dev/null))"
fi

# SIGKILL in the pre-rename window must not strand either the workflow
# publication lock or Git's HEAD/ref locks. A second publisher reclaims only
# locks whose recorded owner is dead, and a normal commit works afterwards.
crash_head="$(git -C "$WT" rev-parse HEAD)"
crash_source="$TMP_ROOT/crash-review.json"
cp "$canonical" "$crash_source"
node - "$crash_source" "$crash_head" <<'NODE'
const fs=require("fs"); const [file,head]=process.argv.slice(2); const value=JSON.parse(fs.readFileSync(file,"utf8")); value.reviewed_head_sha=head; fs.writeFileSync(file,JSON.stringify(value));
NODE
REVIEW_PUBLISH_PRE_RENAME_DELAY=20 node "$SCRIPT_DIR/../lib/review-publish.cjs" "$crash_source" "$WT/.review" 370 "$WT" "$crash_head" >"$TMP_ROOT/crash-publish.out" 2>&1 & crash_publish_pid=$!
crash_polls=0
while [ ! -d "$WT/.git/HEAD.lock" ] && [ "$crash_polls" -lt 40 ]; do sleep 0.1; crash_polls=$((crash_polls + 1)); done
if [ -d "$WT/.git/HEAD.lock" ]; then kill -9 "$crash_publish_pid" >/dev/null 2>&1 || true; fi
wait "$crash_publish_pid" 2>/dev/null || true
node "$SCRIPT_DIR/../lib/review-publish.cjs" "$crash_source" "$WT/.review" 370 "$WT" "$crash_head" >"$TMP_ROOT/crash-retry.out" 2>&1
crash_retry_ec=$?
git -C "$WT" -c user.name=Smoke -c user.email=smoke@example.test commit --allow-empty -qm "commit after killed review publisher"
crash_commit_ec=$?
if [ "$crash_polls" -lt 40 ] && [ "$crash_retry_ec" -eq 0 ] && [ "$crash_commit_ec" -eq 0 ] && [ ! -e "$WT/.review/.ISSUE-370-REVIEW-publish.lock" ] && [ ! -e "$WT/.git/HEAD.lock" ]; then
  pass "SIGKILLed REVIEW publisher leaves reclaimable owned locks"
else
  fail "SIGKILLed REVIEW publisher stranded publication or Git locks (ready=$crash_polls retry=$crash_retry_ec commit=$crash_commit_ec: $(cat "$TMP_ROOT/crash-retry.out" 2>/dev/null))"
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
