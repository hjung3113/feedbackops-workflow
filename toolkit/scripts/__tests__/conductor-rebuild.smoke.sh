#!/usr/bin/env bash
# Smoke test for scripts/conductor-rebuild.sh
# Verifies CONDUCTOR state reconstruction trusts only canonical
# ISSUE-<n>-VERIFY.json artifacts written by VERIFIER, never embedded
# pr_draft.verify_result self-certification.
# bash-3.2-compatible. Run: bash scripts/__tests__/conductor-rebuild.smoke.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REBUILD="$SCRIPT_DIR/../conductor-rebuild.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAILURES=0
pass() { echo "ok   - $1"; }
fail() { echo "NOT OK - $1"; FAILURES=$((FAILURES + 1)); }

REVIEW="$TMP_DIR/.review"
mkdir -p "$REVIEW"

mk_repo() {
  local d="$1"
  local b="${2:-}"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" config user.email "smoke@test.local"
  git -C "$d" config user.name "smoke"
  echo "seed" > "$d/file.txt"
  git -C "$d" add -A
  git -C "$d" commit -q -m "seed"
  [ -n "$b" ] && git -C "$d" checkout -q -b "$b"
}
head_of() { git -C "$1" rev-parse HEAD; }

write_pr() {
  issue="$1"; branch="$2"; sha="$3"; status="$4"; worktree="$5"
  wt_line=""
  [ -n "$worktree" ] && wt_line=",\n  \"worktree_path\": \"$worktree\""
  printf '{
  "schema_version": "1",
  "artifact_type": "pr_draft",
  "lifecycle": "active",
  "producer_role": "CODEX",
  "issue": { "number": %s, "title": "case %s" },
  "branch": "%s",
  "base_sha": "%s",
  "head_sha": "%s",
  "files_touched": [ { "path": "file.txt", "change": "edit" } ],
  "verify_cmd": "verify.sh case-%s",
  "status": "%s",
  "verify_result": { "verified_head_sha": "%s", "passed": 999, "failed": 0, "exit_code": 0 }%b
}
' "$issue" "$issue" "$branch" "$sha" "$sha" "$issue" "$status" "$sha" "$wt_line" > "$REVIEW/ISSUE-${issue}-PR-DRAFT.json"
}

write_verify() {
  issue="$1"; branch="$2"; sha="$3"; role="$4"; class="$5"; failed="$6"; passed="$7"; exit_code="$8"; internal_issue="$9"
  cat > "$REVIEW/ISSUE-${issue}-VERIFY.json" <<EOF
{
  "schema_version": "1",
  "artifact_type": "verify_result",
  "producer_role": "$role",
  "issue": $internal_issue,
  "branch": "$branch",
  "head_sha": "$sha",
  "cwd": "$TMP_DIR",
  "verify_cmd": "verify.sh case-$issue",
  "env_profile": "scrubbed",
  "db_target": { "host": "127.0.0.1", "database": "verify_smoke", "role": "fops_app" },
  "verdict": { "passed": $passed, "failed": $failed, "pending": 0, "exit_code": $exit_code },
  "classifier": "$class",
  "created_at": "2026-07-12T00:00:00Z"
}
EOF
}

# C1 verified
REPO1="$TMP_DIR/wt-101"
mk_repo "$REPO1" "feat/101"
SHA1="$(head_of "$REPO1")"
write_pr 101 "feat/101" "$SHA1" "ready_for_review" "$REPO1"
write_verify 101 "feat/101" "$SHA1" "VERIFIER" "PASS" 0 5 0 101

# C2 stale_verify
REPO2="$TMP_DIR/wt-102"
mk_repo "$REPO2" "feat/102"
SHA2="$(head_of "$REPO2")"
write_pr 102 "feat/102" "$SHA2" "ready_for_review" "$REPO2"
write_verify 102 "feat/102" "$SHA2" "VERIFIER" "PASS" 0 3 0 102
echo "more" >> "$REPO2/file.txt"
git -C "$REPO2" commit -aq -m "post-verify commit"

# C3 no canonical artifact despite embedded verify_result
write_pr 103 "feat/103" "$SHA1" "ready_for_review" "$REPO1"

# C4 classifier FAIL
write_pr 104 "feat/104" "$SHA1" "ready_for_review" "$REPO1"
write_verify 104 "feat/104" "$SHA1" "VERIFIER" "FAIL" 1 4 1 104

# C5 wrong producer
write_pr 105 "feat/105" "$SHA1" "ready_for_review" "$REPO1"
write_verify 105 "feat/105" "$SHA1" "CODEX" "PASS" 0 4 0 105

# C6 issue mismatch
write_pr 106 "feat/106" "$SHA1" "ready_for_review" "$REPO1"
write_verify 106 "feat/106" "$SHA1" "VERIFIER" "PASS" 0 4 0 999

# C7 branch mismatch
write_pr 107 "feat/107" "$SHA1" "ready_for_review" "$REPO1"
write_verify 107 "feat/not-107" "$SHA1" "VERIFIER" "PASS" 0 4 0 107

# C8 fallback self-certify
FB_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
write_pr 108 "feat/108" "$FB_SHA" "ready_for_review" ""
write_verify 108 "feat/108" "$FB_SHA" "VERIFIER" "PASS" 0 4 0 108

# C9 branch identity mismatch
REPO9="$TMP_DIR/wt-109"
mk_repo "$REPO9" "feature/999"
SHA9="$(head_of "$REPO9")"
write_pr 109 "feature/109" "$SHA9" "ready_for_review" "$REPO9"
write_verify 109 "feature/109" "$SHA9" "VERIFIER" "PASS" 0 7 0 109

# C10 in_progress
write_pr 110 "feat/110" "$SHA1" "needs_amendment" "$REPO1"

# C11 superseded skip
write_pr 111 "feat/111" "$SHA1" "ready_for_review" "$REPO1"
node -e 'const fs=require("fs"); const p=process.argv[1]; const o=JSON.parse(fs.readFileSync(p,"utf8")); o.lifecycle="superseded"; fs.writeFileSync(p, JSON.stringify(o,null,2)+"\n");' "$REVIEW/ISSUE-111-PR-DRAFT.json"
write_verify 111 "feat/111" "$SHA1" "VERIFIER" "PASS" 0 5 0 111

# C12 blocker
cat > "$REVIEW/ISSUE-112-BLOCKER.json" <<EOF
{
  "schema_version": "1",
  "artifact_type": "blocker",
  "lifecycle": "active",
  "producer_role": "CODEX",
  "issue": { "number": 112, "title": "blocked case" },
  "head_sha": "$SHA1",
  "reason_code": "missing_dependency",
  "blocking_fact": "module foo not found in src/bar.ts",
  "attempted_commands": [ "pnpm test" ],
  "needed_decision": "ARCHITECT must add dependency"
}
EOF

OUT="$(bash "$REBUILD" "$REVIEW" 2>/dev/null)"
echo "----- conductor-rebuild output -----"
echo "$OUT"
echo "------------------------------------"

expect_state() {
  issue="$1"; state="$2"; label="$3"
  if printf '%s\n' "$OUT" | grep -q "^$issue	$state"; then pass "$label"; else fail "$label"; fi
}
expect_not_state() {
  issue="$1"; state="$2"; label="$3"
  if printf '%s\n' "$OUT" | grep -q "^$issue	$state"; then fail "$label"; else pass "$label"; fi
}

expect_state 101 verified "101 -> verified"
expect_state 102 stale_verify "102 -> stale_verify"
expect_not_state 102 verified "102 not verified"
expect_state 103 unknown "103 -> unknown (no VERIFY artifact)"
expect_not_state 103 verified "103 not verified despite embedded verify_result"
expect_state 104 unknown "104 -> unknown (classifier FAIL)"
expect_state 105 unknown "105 -> unknown (wrong producer)"
expect_state 106 unknown "106 -> unknown (issue mismatch)"
expect_state 107 unknown "107 -> unknown (branch mismatch)"
expect_state 109 unknown "109 -> unknown (branch-identity mismatch)"
expect_not_state 109 verified "109 not verified (wrong branch identity)"
expect_state 110 in_progress "110 -> in_progress"
if printf '%s\n' "$OUT" | grep -q "^111"; then fail "111 must be skipped (superseded)"; else pass "111 skipped (superseded)"; fi
if printf '%s\n' "$OUT" | grep -q "^112	blocked	missing_dependency"; then pass "112 -> blocked missing_dependency"; else fail "112 -> blocked missing_dependency"; fi

OUT_FB="$(bash "$REBUILD" "$REVIEW" "$FB_SHA" 2>/dev/null)"
echo "----- conductor-rebuild output (with fallback $FB_SHA) -----"
echo "$OUT_FB"
echo "------------------------------------------------------------"
if printf '%s\n' "$OUT_FB" | grep -q "^108	unknown"; then pass "108 -> unknown (fallback)"; else fail "108 -> unknown (fallback)"; fi
if printf '%s\n' "$OUT_FB" | grep -q "^108	verified"; then fail "108 must NOT be verified via fallback"; else pass "108 not verified via fallback"; fi
if printf '%s\n' "$OUT_FB" | grep -q "^101	verified"; then pass "101 -> verified (real worktree, fallback present)"; else fail "101 -> verified (real worktree, fallback present)"; fi

echo "---"
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASS"
  exit 0
else
  echo "$FAILURES CASE(S) FAILED"
  exit 1
fi
