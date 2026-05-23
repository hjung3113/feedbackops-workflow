#!/usr/bin/env bash
# Smoke test for scripts/rebase-inflight.sh
# Uses REAL git worktrees in a temp repo. bash-3.2-compatible.
# Run: bash scripts/__tests__/rebase-inflight.smoke.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REBASE="$SCRIPT_DIR/../rebase-inflight.sh"

TMP_DIR="$(mktemp -d)"
# Worktrees live as siblings; track them for forced removal in trap.
cleanup() {
  # Remove any added worktrees first (force) so rm -rf is clean.
  if [ -d "$TMP_DIR/main/.git" ] || [ -f "$TMP_DIR/main/.git" ]; then
    git -C "$TMP_DIR/main" worktree list --porcelain 2>/dev/null \
      | awk '/^worktree /{print $2}' \
      | while IFS= read -r w; do
          [ "$w" = "$TMP_DIR/main" ] && continue
          git -C "$TMP_DIR/main" worktree remove --force "$w" 2>/dev/null || true
        done
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

FAILURES=0
pass() { echo "ok   - $1"; }
fail() { echo "NOT OK - $1"; FAILURES=$((FAILURES + 1)); }

# Isolate from the developer's global git config / hooks.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

# --- build a temp main repo on branch develop ---
MAIN="$TMP_DIR/main"
mkdir -p "$MAIN"
git -C "$MAIN" init -q
git -C "$MAIN" config user.email t@t.t
git -C "$MAIN" config user.name t
git -C "$MAIN" checkout -q -b develop
printf 'base\n' > "$MAIN/base.txt"
git -C "$MAIN" add base.txt
git -C "$MAIN" commit -q -m "base"

# --- add a feature/x worktree off develop ---
FEAT="$TMP_DIR/feat-x"
git -C "$MAIN" worktree add -q -b feature/x "$FEAT" develop

# --- advance develop by one commit (a non-conflicting file) ---
printf 'advance\n' > "$MAIN/advance.txt"
git -C "$MAIN" add advance.txt
git -C "$MAIN" commit -q -m "advance develop"
ADVANCE_SHA="$(git -C "$MAIN" rev-parse HEAD)"

# === Assertion 1: --dry-run lists feature/x, no mutation, exit 0 ===
OUT="$(cd "$MAIN" && bash "$REBASE" --onto develop --dry-run 2>&1)"; RC=$?
case "$OUT" in
  *feature/x*) pass "dry-run lists feature/x worktree" ;;
  *) fail "dry-run lists feature/x worktree (out: $OUT)" ;;
esac
[ "$RC" -eq 0 ] && pass "dry-run exit 0" || fail "dry-run exit 0 (rc=$RC)"
# no mutation: feature/x must NOT yet contain advance commit
if git -C "$FEAT" merge-base --is-ancestor "$ADVANCE_SHA" HEAD 2>/dev/null; then
  fail "dry-run did not mutate feature/x"
else
  pass "dry-run did not mutate feature/x"
fi

# === Assertion 2: clean real rebase brings develop's commit into feature/x ===
OUT="$(cd "$MAIN" && bash "$REBASE" --onto develop 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && pass "clean rebase exit 0" || fail "clean rebase exit 0 (rc=$RC)"
if git -C "$FEAT" merge-base --is-ancestor "$ADVANCE_SHA" HEAD 2>/dev/null; then
  pass "feature/x rebased onto advanced develop"
else
  fail "feature/x rebased onto advanced develop (out: $OUT)"
fi

# === Assertion 3: dirty worktree is SKIPPED, not rebased, exit 0 ===
# Advance develop again so there is something to rebase.
printf 'advance2\n' > "$MAIN/advance2.txt"
git -C "$MAIN" add advance2.txt
git -C "$MAIN" commit -q -m "advance develop 2"
ADVANCE2_SHA="$(git -C "$MAIN" rev-parse HEAD)"
# make feature/x dirty (untracked file)
printf 'wip\n' > "$FEAT/wip.txt"
OUT="$(cd "$MAIN" && bash "$REBASE" --onto develop 2>&1)"; RC=$?
case "$OUT" in
  *WARNING*uncommitted*) pass "dirty worktree warned" ;;
  *) fail "dirty worktree warned (out: $OUT)" ;;
esac
[ "$RC" -eq 0 ] && pass "dirty run exit 0" || fail "dirty run exit 0 (rc=$RC)"
if git -C "$FEAT" merge-base --is-ancestor "$ADVANCE2_SHA" HEAD 2>/dev/null; then
  fail "dirty worktree NOT rebased (clobber-safe)"
else
  pass "dirty worktree NOT rebased (clobber-safe)"
fi
rm -f "$FEAT/wip.txt"

# === Assertion 4: lock contention exits 1 ===
LOCK="$MAIN/.review/.rebase-inflight.lock"
mkdir -p "$MAIN/.review"
mkdir -p "$LOCK"
OUT="$(cd "$MAIN" && bash "$REBASE" --onto develop 2>&1)"; RC=$?
[ "$RC" -eq 1 ] && pass "lock contention exits 1" || fail "lock contention exits 1 (rc=$RC)"
case "$OUT" in
  *lock*) pass "lock contention reports lock" ;;
  *) fail "lock contention reports lock (out: $OUT)" ;;
esac
rmdir "$LOCK"

echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL PASS"
  exit 0
else
  echo "$FAILURES FAILURE(S)"
  exit 1
fi
