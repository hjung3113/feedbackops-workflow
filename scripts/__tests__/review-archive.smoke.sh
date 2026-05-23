#!/usr/bin/env bash
# Smoke test for scripts/review-archive.sh — archive merged issue artifacts.
# bash-3.2-compatible. Run: bash scripts/__tests__/review-archive.smoke.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARCHIVE="$SCRIPT_DIR/../review-archive.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAILURES=0

# --- setup: create a temp git repo ---
REPO="$TMP_DIR/repo"
mkdir -p "$REPO"
(
  cd "$REPO" || exit 1
  git init -q
  git config user.email "smoke@test"
  git config user.name "smoke"
  echo "init" > init.txt
  git add init.txt
  git commit -q -m "init"
) || { echo "repo setup failed"; exit 1; }

# --- setup: create .review and archive dirs ---
mkdir -p "$REPO/.review/archive"

# --- run_case <name> <expected-exit> <assertion> ---
run_case() {
  local name="$1"
  local expected_exit="$2"
  local assertion="$3"

  # Run the script and capture exit code
  if eval "$assertion" >/dev/null 2>&1; then
    actual_exit=0
  else
    actual_exit=$?
  fi

  if [ "$actual_exit" -eq "$expected_exit" ]; then
    echo "ok   - $name"
  else
    echo "NOT OK - $name (expected exit $expected_exit, got $actual_exit)"
    FAILURES=$((FAILURES + 1))
  fi
}

# --- Case 1: archive two ISSUE-9 files, leave ISSUE-10 untouched ---
touch "$REPO/.review/ISSUE-9-PR-DRAFT.json"
touch "$REPO/.review/ISSUE-9-REVIEW.json"
touch "$REPO/.review/ISSUE-10-PR-DRAFT.json"

output=$( cd "$REPO" && bash "$ARCHIVE" 9 2>&1 )
exit_code=$?

if [ "$exit_code" -eq 0 ]; then
  echo "ok   - case 1: exit 0"
else
  echo "NOT OK - case 1: exit (expected 0, got $exit_code)"
  FAILURES=$((FAILURES + 1))
fi

# Check both ISSUE-9 files moved
if [ ! -f "$REPO/.review/ISSUE-9-PR-DRAFT.json" ] && \
   [ -f "$REPO/.review/archive/$(date +%Y-%m)/ISSUE-9-PR-DRAFT.json" ]; then
  echo "ok   - case 1: ISSUE-9-PR-DRAFT.json moved to archive"
else
  echo "NOT OK - case 1: ISSUE-9-PR-DRAFT.json not correctly moved"
  FAILURES=$((FAILURES + 1))
fi

if [ ! -f "$REPO/.review/ISSUE-9-REVIEW.json" ] && \
   [ -f "$REPO/.review/archive/$(date +%Y-%m)/ISSUE-9-REVIEW.json" ]; then
  echo "ok   - case 1: ISSUE-9-REVIEW.json moved to archive"
else
  echo "NOT OK - case 1: ISSUE-9-REVIEW.json not correctly moved"
  FAILURES=$((FAILURES + 1))
fi

# Check ISSUE-10 untouched
if [ -f "$REPO/.review/ISSUE-10-PR-DRAFT.json" ]; then
  echo "ok   - case 1: ISSUE-10 untouched"
else
  echo "NOT OK - case 1: ISSUE-10 should remain in .review"
  FAILURES=$((FAILURES + 1))
fi

# Check output mentions "moved 2"
if echo "$output" | grep -q "moved 2"; then
  echo "ok   - case 1: output mentions 'moved 2'"
else
  echo "NOT OK - case 1: output should mention 'moved 2', got: $output"
  FAILURES=$((FAILURES + 1))
fi

# --- Case 2: no matches returns exit 0 ---
output=$( cd "$REPO" && bash "$ARCHIVE" 999 2>&1 )
exit_code=$?

if [ "$exit_code" -eq 0 ]; then
  echo "ok   - case 2: no matches exit 0"
else
  echo "NOT OK - case 2: no matches should exit 0 (got $exit_code)"
  FAILURES=$((FAILURES + 1))
fi

if echo "$output" | grep -q "no artifacts"; then
  echo "ok   - case 2: output mentions 'no artifacts'"
else
  echo "NOT OK - case 2: output should mention 'no artifacts', got: $output"
  FAILURES=$((FAILURES + 1))
fi

# --- Case 3: invalid issue number returns exit 2 ---
output=$( cd "$REPO" && bash "$ARCHIVE" abc 2>&1 )
exit_code=$?

if [ "$exit_code" -eq 2 ]; then
  echo "ok   - case 3: invalid issue exit 2"
else
  echo "NOT OK - case 3: invalid issue should exit 2 (got $exit_code)"
  FAILURES=$((FAILURES + 1))
fi

echo "---"
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASS"
  exit 0
else
  echo "$FAILURES CASE(S) FAILED"
  exit 1
fi
