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

# map a touched file path to a top-level workspace package name.
# apps/<pkg>/... → <pkg>;  packages/<pkg>/... → <pkg>;  else empty.
pkg_from_path() {
  case "$1" in
    apps/*/*)     p="${1#apps/}";     echo "${p%%/*}" ;;
    packages/*/*) p="${1#packages/}"; echo "${p%%/*}" ;;
    *) echo "" ;;
  esac
}

# print a suggested verify command for a freshly-rebased worktree.
suggest_verify() {
  wt="$1"
  draft=""
  for f in "$wt"/.review/ISSUE-*-PR-DRAFT.json; do
    [ -f "$f" ] && { draft="$f"; break; }
  done
  if [ -z "$draft" ]; then
    echo "    suggest: run scripts/verify.sh for affected area"
    return
  fi
  # Extract files_touched[].path values without a JSON dep: grep the path keys.
  pkgs=""
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    pkg="$(pkg_from_path "$path")"
    [ -n "$pkg" ] || continue
    case " $pkgs " in
      *" $pkg "*) ;;            # already present
      *) pkgs="$pkgs $pkg" ;;
    esac
  done <<EOF
$(grep -o '"path"[[:space:]]*:[[:space:]]*"[^"]*"' "$draft" 2>/dev/null \
    | sed 's/.*"path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
EOF
  pkgs="$(echo "$pkgs" | sed 's/^ *//;s/ *$//')"
  if [ -n "$pkgs" ]; then
    echo "    suggest: scripts/verify.sh $pkgs"
  else
    echo "    suggest: run scripts/verify.sh for affected area"
  fi
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

REBASED=0
SKIPPED=0
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
echo "=== summary: rebased=$REBASED skipped(dirty)=$SKIPPED failed(aborted)=$FAILED ==="

exit 0
