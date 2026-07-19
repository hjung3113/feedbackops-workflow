#!/usr/bin/env bash
# rebase-inflight.sh — EXPLICIT operator command to rebase in-flight feature
# worktrees onto an advanced integration branch.
#
# Codex review R9: the post-merge hook intentionally stays WARN-ONLY — auto
# rebasing inside a git hook is too risky / under-specified. This script is the
# deliberate counterpart the operator/CONDUCTOR runs by hand.
#
# Usage: scripts/rebase-inflight.sh [--onto <integration-branch>] [--dry-run]
#   --onto <branch>  integration branch to rebase onto (default: current branch)
#   --dry-run        list what WOULD happen; mutate nothing
#
# Safety:
#   - SKIPS a worktree with an in-progress git operation (rebase/merge/
#     cherry-pick/revert) — even when `git status --porcelain` looks clean —
#     so we never clobber an agent's hand-resolution in progress.
#   - REFUSES to rebase a dirty worktree (never clobbers uncommitted work).
#   - On rebase conflict it aborts the rebase — never leaves a worktree
#     mid-rebase.
#   - A single worktree failure never hard-fails the whole command.
#
# bash-3.2-compatible: no `declare -A`, no `${var,,}`.
set -euo pipefail

ONTO=""
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --onto)
      [ $# -ge 2 ] || { echo "error: --onto requires a branch argument" >&2; exit 2; }
      ONTO="$2"; shift 2 ;;
    --onto=*)
      ONTO="${1#--onto=}"; shift ;;
    --dry-run)
      DRY_RUN=1; shift ;;
    -h|--help)
      echo "usage: scripts/rebase-inflight.sh [--onto <integration-branch>] [--dry-run]" >&2
      exit 0 ;;
    *)
      echo "error: unknown argument: $1" >&2
      echo "usage: scripts/rebase-inflight.sh [--onto <integration-branch>] [--dry-run]" >&2
      exit 2 ;;
  esac
done

REPO_ROOT="$(git rev-parse --show-toplevel)"

if [ -z "$ONTO" ]; then
  ONTO="$(git rev-parse --abbrev-ref HEAD)"
fi

# --- concurrency guard: mkdir-based lock, removed on EXIT ---
LOCK="$REPO_ROOT/.review/.rebase-inflight.lock"
mkdir -p "$REPO_ROOT/.review"
mkdir "$LOCK" 2>/dev/null || { echo "another rebase-inflight is running (lock: $LOCK) — aborting"; exit 1; }
# Only this process should remove the lock it acquired.
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

# print a suggested verify command for a freshly-rebased worktree.
# NOTE: scripts/verify.sh's positional arg is a VITEST test name/path filter
# scoped to the backend package — NOT a package selector. So we deliberately
# do NOT emit a package name (e.g. "backend"), which vitest would treat as a
# name filter and likely match nothing. Stay a SUGGESTION only (never auto-run).
suggest_verify() {
  echo "    suggest: run scripts/verify.sh <test-name-filter> for the affected area (e.g. a touched test's name)"
}

# --- discover sibling in-flight feature worktrees (mirrors .githooks/post-merge) ---
WORKTREES=()
while IFS= read -r wt; do
  WORKTREES+=("$wt")
done < <(git worktree list --porcelain | awk '/^worktree /{print $2}')

SIBLINGS=()
for wt in ${WORKTREES[@]+"${WORKTREES[@]}"}; do
  [ "$wt" = "$REPO_ROOT" ] && continue
  if [ -d "$wt" ]; then
    BRANCH="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
    case "$BRANCH" in
      feature/*) SIBLINGS+=("$wt|$BRANCH") ;;
    esac
  fi
done

# detect a foreign in-progress git operation in a worktree (rebase / merge /
# cherry-pick / revert). Resolves state paths via rev-parse --git-path so it is
# correct for LINKED worktrees (whose git dir is not <wt>/.git). Returns 0 if an
# operation is in progress.
has_inprogress_op() {
  wt="$1"
  [ -d "$(git -C "$wt" rev-parse --git-path rebase-merge 2>/dev/null)" ] && return 0
  [ -d "$(git -C "$wt" rev-parse --git-path rebase-apply 2>/dev/null)" ] && return 0
  git -C "$wt" rev-parse -q --verify MERGE_HEAD       >/dev/null 2>&1 && return 0
  git -C "$wt" rev-parse -q --verify CHERRY_PICK_HEAD >/dev/null 2>&1 && return 0
  git -C "$wt" rev-parse -q --verify REVERT_HEAD      >/dev/null 2>&1 && return 0
  return 1
}

REBASED=0
SKIPPED=0
SKIPPED_INPROG=0
FAILED=0

echo "=== rebase-inflight: onto '$ONTO' (${#SIBLINGS[@]} in-flight feature worktree(s)) ==="
if [ "$DRY_RUN" -eq 1 ]; then
  echo "(dry-run: no worktrees will be modified)"
fi

for entry in ${SIBLINGS[@]+"${SIBLINGS[@]}"}; do
  WT="${entry%%|*}"
  BR="${entry##*|}"
  echo ""
  echo "  • $BR at $WT"

  # GUARD: a foreign git operation may be in progress while the tree still
  # looks clean to `git status --porcelain` (e.g. an agent hand-resolving a
  # rebase). Attempting a rebase here would fail and our abort path would
  # CLOBBER that work. Skip such worktrees outright — never touch them.
  if has_inprogress_op "$WT"; then
    echo "    WARNING: $WT has an in-progress git operation (rebase/merge/cherry-pick) — skipping to avoid clobbering it"
    SKIPPED_INPROG=$((SKIPPED_INPROG + 1))
    continue
  fi

  # REFUSE dirty worktrees — never rebase over uncommitted work.
  if [ -n "$(git -C "$WT" status --porcelain 2>/dev/null)" ]; then
    echo "    WARNING: $WT has uncommitted changes — skipping rebase to avoid clobbering work"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "    would: git -C $WT rebase $ONTO"
    continue
  fi

  if git -C "$WT" rebase "$ONTO"; then
    REBASED=$((REBASED + 1))
    suggest_verify "$WT"
  else
    echo "    WARNING: rebase of $BR onto $ONTO FAILED — aborting to leave a clean tree"
    git -C "$WT" rebase --abort 2>/dev/null || true
    echo "    WARNING: $WT needs a MANUAL rebase onto $ONTO"
    FAILED=$((FAILED + 1))
  fi
done

echo ""
echo "=== summary: rebased=$REBASED skipped(dirty)=$SKIPPED skipped(in-progress op)=$SKIPPED_INPROG failed(aborted)=$FAILED ==="

exit 0
