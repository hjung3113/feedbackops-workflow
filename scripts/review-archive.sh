#!/usr/bin/env bash
# review-archive.sh — archive merged issue artifacts to .review/archive/YYYY-MM/
#
# Usage: scripts/review-archive.sh <issue-number>
#
# On PR merge, move all .review/ISSUE-<N>-* artifacts to the monthly archive
# to prevent readers from processing stale artifacts.
#
# Exit codes:
#   0 = success (artifacts moved, or no artifacts found)
#   2 = usage error (invalid issue number)
#
# bash-3.2-compatible.
set -euo pipefail

PROG="review-archive"

# --- Usage check ---
if [ "$#" -ne 1 ]; then
  echo "$PROG: usage: $0 <issue-number>" >&2
  exit 2
fi

issue_number="$1"

# --- Validate issue-number is a positive integer ---
if ! echo "$issue_number" | grep -qE '^[0-9]+$'; then
  echo "$PROG: ERROR — issue number must be a positive integer, got: $issue_number" >&2
  exit 2
fi

# --- Find REPO_ROOT ---
REPO_ROOT="$(git rev-parse --show-toplevel)"

# --- Create archive destination ---
ARCHIVE_DEST="$REPO_ROOT/.review/archive/$(date +%Y-%m)"
mkdir -p "$ARCHIVE_DEST"

# --- Move artifacts matching ISSUE-<N>-* (nullglob-safe) ---
shopt -s nullglob
count=0
for f in "$REPO_ROOT/.review/ISSUE-${issue_number}-"*; do
  [ -e "$f" ] || continue
  mv "$f" "$ARCHIVE_DEST/"
  count=$((count + 1))
done

# --- Report ---
if [ "$count" -eq 0 ]; then
  echo "$PROG: no artifacts for issue #$issue_number"
  exit 0
fi

echo "$PROG: moved $count artifact(s) for issue #$issue_number to $ARCHIVE_DEST"
exit 0
