#!/usr/bin/env bash
# Smoke test for scripts/workflow-stash.sh pure preservation behavior.
# bash-3.2-compatible. Run: bash scripts/__tests__/workflow-stash.smoke.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKFLOW_STASH="$SCRIPT_DIR/../workflow-stash.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAILURES=0

fail_case() {
  name="$1"; detail="$2"
  echo "NOT OK - $name ($detail)"
  FAILURES=$((FAILURES + 1))
}

pass_case() {
  name="$1"
  echo "ok   - $name"
}

setup_repo() {
  repo="$1"
  mkdir -p "$repo"
  (
    cd "$repo" || exit 1
    git init -q
    git config user.email "smoke@test"
    git config user.name "smoke"
    printf '%s\n' "base" > tracked.txt
    git add tracked.txt
    git commit -q -m "base commit"
  )
}

CLEAN_REPO="$TMP_DIR/clean-repo"
setup_repo "$CLEAN_REPO" || { echo "repo setup failed"; exit 1; }

bash "$WORKFLOW_STASH" 42 "$CLEAN_REPO" >/dev/null 2>&1
clean_ec=$?
if [ "$clean_ec" -eq 0 ]; then
  pass_case "clean tree no-op exits 0"
else
  fail_case "clean tree no-op exits 0" "exit $clean_ec"
fi

if [ ! -e "$CLEAN_REPO/.review" ]; then
  pass_case "clean tree no-op creates no review artifacts"
else
  fail_case "clean tree no-op creates no review artifacts" ".review exists"
fi

DIRTY_REPO="$TMP_DIR/dirty-repo"
setup_repo "$DIRTY_REPO" || { echo "repo setup failed"; exit 1; }

(
  cd "$DIRTY_REPO" || exit 1
  printf '%s\n' "base" "dirty change" > tracked.txt
  printf '%s\n' "new work" > untracked.txt
)

bash "$WORKFLOW_STASH" 77 "$DIRTY_REPO" >/dev/null 2>&1
dirty_ec=$?
if [ "$dirty_ec" -eq 0 ]; then
  pass_case "dirty tree preservation exits 0"
else
  fail_case "dirty tree preservation exits 0" "exit $dirty_ec"
fi

DIFF_OUT="$DIRTY_REPO/.review/ISSUE-77-PARTIAL.diff"
UNTRACKED_LIST="$DIRTY_REPO/.review/ISSUE-77-PARTIAL-UNTRACKED.txt"
UNTRACKED_COPY="$DIRTY_REPO/.review/ISSUE-77-PARTIAL-UNTRACKED/untracked.txt"

if [ -s "$DIFF_OUT" ] && grep -q "dirty change" "$DIFF_OUT"; then
  pass_case "tracked diff is written"
else
  fail_case "tracked diff is written" "missing expected diff content"
fi

if [ -s "$UNTRACKED_LIST" ] && grep -q '^untracked\.txt$' "$UNTRACKED_LIST"; then
  pass_case "untracked file list is written"
else
  fail_case "untracked file list is written" "missing untracked.txt"
fi

if [ -f "$UNTRACKED_COPY" ] && grep -q "new work" "$UNTRACKED_COPY"; then
  pass_case "untracked file is copied"
else
  fail_case "untracked file is copied" "missing copied file"
fi

(
  cd "$DIRTY_REPO" || exit 1
  git diff --quiet
)
tracked_clean_ec=$?
if [ "$tracked_clean_ec" -ne 0 ]; then
  pass_case "original tracked dirty change remains in place"
else
  fail_case "original tracked dirty change remains in place" "git diff is clean"
fi

echo "---"
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASS"
  exit 0
else
  echo "$FAILURES CASE(S) FAILED"
  exit 1
fi
