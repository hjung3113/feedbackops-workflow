#!/usr/bin/env bash
# Called when codex aborts mid-work. Saves uncommitted diff AND copies
# untracked files (gitignored excluded). Caps untracked file count to
# avoid pathological recursive copies. NUL-safe path handling.
set -euo pipefail

ISSUE_N="${1:?usage: workflow-stash.sh <issue-number>}"
WORKTREE="${2:-$(pwd)}"
MAX_UNTRACKED="${MAX_UNTRACKED:-200}"      # hard cap; abort copy if exceeded
MAX_UNTRACKED_BYTES="${MAX_UNTRACKED_BYTES:-10485760}"   # 10 MB total

cd "$WORKTREE"

HAS_TRACKED=1
HAS_UNTRACKED=1
git diff --quiet && git diff --cached --quiet && HAS_TRACKED=0

# NUL-separated for safety against weird filenames
UNTRACKED_COUNT=$(git ls-files --others --exclude-standard -z | tr -cd '\0' | wc -c | tr -d ' ')
[[ "$UNTRACKED_COUNT" -eq 0 ]] && HAS_UNTRACKED=0

if [[ $HAS_TRACKED -eq 0 && $HAS_UNTRACKED -eq 0 ]]; then
  echo "no partial work to stash"
  exit 0
fi

mkdir -p .review
DIFF_OUT=".review/ISSUE-${ISSUE_N}-PARTIAL.diff"
UNTRACKED_LIST=".review/ISSUE-${ISSUE_N}-PARTIAL-UNTRACKED.txt"
UNTRACKED_DIR=".review/ISSUE-${ISSUE_N}-PARTIAL-UNTRACKED"

if [[ $HAS_TRACKED -eq 1 ]]; then
  git diff HEAD > "$DIFF_OUT"
  echo "stashed tracked diff to $DIFF_OUT ($(wc -l < "$DIFF_OUT" | tr -d ' ') lines)"
fi

if [[ $HAS_UNTRACKED -eq 1 ]]; then
  if [[ "$UNTRACKED_COUNT" -gt "$MAX_UNTRACKED" ]]; then
    echo "WARN: $UNTRACKED_COUNT untracked files exceeds MAX_UNTRACKED=$MAX_UNTRACKED — listing only, not copying" >&2
    git ls-files --others --exclude-standard > "$UNTRACKED_LIST"
    echo "untracked file list saved to $UNTRACKED_LIST (no copy)"
  else
    git ls-files --others --exclude-standard > "$UNTRACKED_LIST"
    rm -rf "$UNTRACKED_DIR"
    TOTAL_BYTES=0
    OVER_LIMIT=0
    while IFS= read -r -d '' f; do
      [[ -z "$f" ]] && continue
      SZ=$(wc -c < "$f" 2>/dev/null || echo 0)
      TOTAL_BYTES=$((TOTAL_BYTES + SZ))
      if [[ $TOTAL_BYTES -gt $MAX_UNTRACKED_BYTES ]]; then
        OVER_LIMIT=1
        break
      fi
      mkdir -p "$UNTRACKED_DIR/$(dirname "$f")"
      cp "$f" "$UNTRACKED_DIR/$f" 2>/dev/null || { echo "WARN: skipping unreadable $f" >&2; continue; }
    done < <(git ls-files --others --exclude-standard -z)
    if [[ $OVER_LIMIT -eq 1 ]]; then
      echo "WARN: total untracked size exceeded MAX_UNTRACKED_BYTES=$MAX_UNTRACKED_BYTES — partial copy in $UNTRACKED_DIR/" >&2
    else
      echo "stashed $UNTRACKED_COUNT untracked file(s) to $UNTRACKED_DIR/ ($TOTAL_BYTES bytes)"
    fi
  fi
fi
