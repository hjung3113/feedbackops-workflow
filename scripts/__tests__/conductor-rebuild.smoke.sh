#!/usr/bin/env bash
# Smoke test for scripts/conductor-rebuild.sh
# Verifies CONDUCTOR state reconstruction resolves each pr_draft against ITS OWN
# worktree HEAD (Codex R6: no global branch-HEAD, no false "verified").
# Builds real temp git repos so `git -C ... rev-parse HEAD` is genuine.
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

# --- helper: make a temp git repo, return its HEAD sha via stdout ---
mk_repo() {
  # $1 = repo dir
  local d="$1"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" config user.email "smoke@test.local"
  git -C "$d" config user.name "smoke"
  echo "seed" > "$d/file.txt"
  git -C "$d" add -A
  git -C "$d" commit -q -m "seed"
}
head_of() { git -C "$1" rev-parse HEAD; }

# --- Case 1: verified (worktree HEAD == verified_head_sha) ---
REPO1="$TMP_DIR/wt-101"
mk_repo "$REPO1"
SHA1="$(head_of "$REPO1")"
cat > "$REVIEW/ISSUE-101-PR-DRAFT.json" <<EOF
{
  "schema_version": "1",
  "artifact_type": "pr_draft",
  "lifecycle": "active",
  "producer_role": "CODEX",
  "issue": { "number": 101, "title": "verified case" },
  "branch": "feat/101",
  "base_sha": "$SHA1",
  "head_sha": "$SHA1",
  "files_touched": [ { "path": "file.txt", "change": "edit" } ],
  "verify_cmd": "true",
  "status": "ready_for_review",
  "worktree_path": "$REPO1",
  "verify_result": { "verified_head_sha": "$SHA1", "passed": 5, "failed": 0, "exit_code": 0 }
}
EOF

# --- Case 2: stale_verify (advance HEAD after writing artifact) ---
REPO2="$TMP_DIR/wt-102"
mk_repo "$REPO2"
SHA2="$(head_of "$REPO2")"
cat > "$REVIEW/ISSUE-102-PR-DRAFT.json" <<EOF
{
  "schema_version": "1",
  "artifact_type": "pr_draft",
  "lifecycle": "active",
  "producer_role": "CODEX",
  "issue": { "number": 102, "title": "stale case" },
  "branch": "feat/102",
  "base_sha": "$SHA2",
  "head_sha": "$SHA2",
  "files_touched": [ { "path": "file.txt", "change": "edit" } ],
  "verify_cmd": "true",
  "status": "ready_for_review",
  "worktree_path": "$REPO2",
  "verify_result": { "verified_head_sha": "$SHA2", "passed": 3, "failed": 0, "exit_code": 0 }
}
EOF
# work landed after verify
echo "more" >> "$REPO2/file.txt"
git -C "$REPO2" commit -aq -m "post-verify commit"

# --- Case 3: unknown (ready_for_review, NO worktree_path, NO fallback) ---
SHA3="$(head_of "$REPO1")"
cat > "$REVIEW/ISSUE-103-PR-DRAFT.json" <<EOF
{
  "schema_version": "1",
  "artifact_type": "pr_draft",
  "lifecycle": "active",
  "producer_role": "CODEX",
  "issue": { "number": 103, "title": "no worktree case" },
  "branch": "feat/103",
  "base_sha": "$SHA3",
  "head_sha": "$SHA3",
  "files_touched": [ { "path": "file.txt", "change": "edit" } ],
  "verify_cmd": "true",
  "status": "ready_for_review",
  "verify_result": { "verified_head_sha": "$SHA3", "passed": 2, "failed": 0, "exit_code": 0 }
}
EOF

# --- Case 4: in_progress (needs_amendment) ---
cat > "$REVIEW/ISSUE-104-PR-DRAFT.json" <<EOF
{
  "schema_version": "1",
  "artifact_type": "pr_draft",
  "lifecycle": "active",
  "producer_role": "CODEX",
  "issue": { "number": 104, "title": "needs amendment case" },
  "branch": "feat/104",
  "base_sha": "$SHA1",
  "head_sha": "$SHA1",
  "files_touched": [ { "path": "file.txt", "change": "edit" } ],
  "verify_cmd": "true",
  "status": "needs_amendment"
}
EOF

# --- Case 5: blocker ---
cat > "$REVIEW/ISSUE-105-BLOCKER.json" <<EOF
{
  "schema_version": "1",
  "artifact_type": "blocker",
  "lifecycle": "active",
  "producer_role": "CODEX",
  "issue": { "number": 105, "title": "blocked case" },
  "reason_code": "missing_dependency",
  "blocking_fact": "module foo not found in src/bar.ts",
  "attempted_commands": [ "pnpm test" ],
  "needed_decision": "ARCHITECT must add dependency"
}
EOF

# --- Case 6: superseded pr_draft (must be skipped) ---
cat > "$REVIEW/ISSUE-106-PR-DRAFT.json" <<EOF
{
  "schema_version": "1",
  "artifact_type": "pr_draft",
  "lifecycle": "superseded",
  "producer_role": "CODEX",
  "issue": { "number": 106, "title": "superseded case" },
  "branch": "feat/106",
  "base_sha": "$SHA1",
  "head_sha": "$SHA1",
  "files_touched": [ { "path": "file.txt", "change": "edit" } ],
  "verify_cmd": "true",
  "status": "ready_for_review",
  "worktree_path": "$REPO1",
  "verify_result": { "verified_head_sha": "$SHA1", "passed": 5, "failed": 0, "exit_code": 0 }
}
EOF

# --- Case 7 (R6 regression): ready_for_review, NO worktree_path, run WITH a
# fallback X that equals verified_head_sha. A fallback must NEVER promote to
# verified — the artifact would be certifying itself. Expect `unknown`. ---
FB_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
cat > "$REVIEW/ISSUE-107-PR-DRAFT.json" <<EOF
{
  "schema_version": "1",
  "artifact_type": "pr_draft",
  "lifecycle": "active",
  "producer_role": "CODEX",
  "issue": { "number": 107, "title": "fallback self-certify case" },
  "branch": "feat/107",
  "base_sha": "$FB_SHA",
  "head_sha": "$FB_SHA",
  "files_touched": [ { "path": "file.txt", "change": "edit" } ],
  "verify_cmd": "true",
  "status": "ready_for_review",
  "verify_result": { "verified_head_sha": "$FB_SHA", "passed": 4, "failed": 0, "exit_code": 0 }
}
EOF

# --- Case 8 (R6 regression): worktree_path points at a NON-EXISTENT dir, run
# WITH fallback X == verified_head_sha. Missing dir falls back, must NOT verify. ---
cat > "$REVIEW/ISSUE-108-PR-DRAFT.json" <<EOF
{
  "schema_version": "1",
  "artifact_type": "pr_draft",
  "lifecycle": "active",
  "producer_role": "CODEX",
  "issue": { "number": 108, "title": "missing worktree dir + fallback case" },
  "branch": "feat/108",
  "base_sha": "$FB_SHA",
  "head_sha": "$FB_SHA",
  "files_touched": [ { "path": "file.txt", "change": "edit" } ],
  "verify_cmd": "true",
  "status": "ready_for_review",
  "worktree_path": "$TMP_DIR/no-such-worktree-dir",
  "verify_result": { "verified_head_sha": "$FB_SHA", "passed": 4, "failed": 0, "exit_code": 0 }
}
EOF

# --- run (no fallback arg, so case 3 stays unknown) ---
OUT="$(bash "$REBUILD" "$REVIEW" 2>/dev/null)"
echo "----- conductor-rebuild output -----"
echo "$OUT"
echo "------------------------------------"

# Case 1: verified
if printf '%s\n' "$OUT" | grep -q "^101	verified"; then pass "101 -> verified"; else fail "101 -> verified"; fi

# Case 2: stale_verify (and NOT verified)
if printf '%s\n' "$OUT" | grep -q "^102	stale_verify"; then pass "102 -> stale_verify"; else fail "102 -> stale_verify"; fi
if printf '%s\n' "$OUT" | grep -q "^102	verified"; then fail "102 must NOT be verified"; else pass "102 not verified"; fi

# Case 3: unknown, anti-false-verify (R6)
if printf '%s\n' "$OUT" | grep -q "^103	unknown"; then pass "103 -> unknown"; else fail "103 -> unknown"; fi
if printf '%s\n' "$OUT" | grep -q "^103	verified"; then fail "103 must NOT be verified (R6)"; else pass "103 not verified (R6)"; fi

# Case 4: in_progress
if printf '%s\n' "$OUT" | grep -q "^104	in_progress"; then pass "104 -> in_progress"; else fail "104 -> in_progress"; fi

# Case 5: blocked with reason_code
if printf '%s\n' "$OUT" | grep -q "^105	blocked	missing_dependency"; then pass "105 -> blocked missing_dependency"; else fail "105 -> blocked missing_dependency"; fi

# Case 6: superseded skipped
if printf '%s\n' "$OUT" | grep -q "^106"; then fail "106 must be skipped (superseded)"; else pass "106 skipped (superseded)"; fi

# --- second run WITH a fallback SHA == verified_head_sha of cases 7 & 8.
# This is the regression guard for the fallback self-certify hole. ---
OUT_FB="$(bash "$REBUILD" "$REVIEW" "$FB_SHA" 2>/dev/null)"
echo "----- conductor-rebuild output (with fallback $FB_SHA) -----"
echo "$OUT_FB"
echo "------------------------------------------------------------"

# Case 7: NO worktree_path + matching fallback → unknown, NEVER verified (R6).
if printf '%s\n' "$OUT_FB" | grep -q "^107	unknown"; then pass "107 -> unknown (fallback)"; else fail "107 -> unknown (fallback)"; fi
if printf '%s\n' "$OUT_FB" | grep -q "^107	verified"; then fail "107 must NOT be verified via fallback (R6)"; else pass "107 not verified via fallback (R6)"; fi

# Case 8: non-existent worktree_path + matching fallback → NOT verified (R6).
if printf '%s\n' "$OUT_FB" | grep -q "^108	verified"; then fail "108 must NOT be verified via fallback (R6)"; else pass "108 not verified via fallback (R6)"; fi

# Case 1 regression: a REAL worktree HEAD still earns verified even with fallback present.
if printf '%s\n' "$OUT_FB" | grep -q "^101	verified"; then pass "101 -> verified (real worktree, fallback present)"; else fail "101 -> verified (real worktree, fallback present)"; fi

echo "---"
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASS"
  exit 0
else
  echo "$FAILURES CASE(S) FAILED"
  exit 1
fi
