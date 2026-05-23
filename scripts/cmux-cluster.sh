#!/usr/bin/env bash
# Set up 4-pane cmux workspace for a single-issue trial.
# Layout:
#   ARCHITECT (top-left)   |  CODEX (top-right)
#   REVIEWER  (bottom-left)|  VERIFIER (bottom-right)
#
# Usage: scripts/cmux-cluster.sh <issue-N> <slug>
set -euo pipefail

ISSUE_N="${1:?usage: cmux-cluster.sh <issue-N> <slug>}"
SLUG="${2:?usage: cmux-cluster.sh <issue-N> <slug>}"
REPO_ROOT="$(git rev-parse --show-toplevel)"

# Create worktree
WT_PATH="${REPO_ROOT}/../wt-${ISSUE_N}-${SLUG}"
BRANCH="feature/${ISSUE_N}-${SLUG}"
TRIAL_BASE="${TRIAL_BASE:-develop}"   # override for trial runs where infra lives on a non-develop branch

if [[ ! -d "$WT_PATH" ]]; then
  git worktree add "$WT_PATH" -b "$BRANCH" "$TRIAL_BASE"
else
  # Worktree already exists. Validate it has workflow infra; refuse silent reuse
  # of a stale worktree branched from the wrong base.
  if [[ ! -f "$WT_PATH/scripts/codex-safe.sh" || ! -d "$WT_PATH/.review/schemas" ]]; then
    echo "ERROR: worktree at $WT_PATH exists but is missing workflow infra." >&2
    echo "       (no scripts/codex-safe.sh or .review/schemas/). Likely branched from" >&2
    echo "       a base that predates T1-T5. Remove it explicitly before re-running:" >&2
    echo "         git worktree remove --force $WT_PATH && git branch -D $BRANCH" >&2
    exit 1
  fi
fi

# Spawn cmux workspace
WS=$(cmux new-workspace --name "issue-${ISSUE_N}-${SLUG}" --cwd "$WT_PATH" | awk 'NR==1{print $2; exit}')
LEFT=$(cmux list-pane-surfaces --workspace "$WS" | awk 'NR==1{print $2; exit}')

RIGHT=$(cmux new-split right --workspace "$WS" --surface "$LEFT" | awk 'NR==1{print $2; exit}')
BL=$(cmux new-split down --workspace "$WS" --surface "$LEFT" | awk 'NR==1{print $2; exit}')
BR=$(cmux new-split down --workspace "$WS" --surface "$RIGHT" | awk 'NR==1{print $2; exit}')

for v in WS LEFT RIGHT BL BR; do
  if [[ -z "${!v}" ]]; then
    echo "ERROR: cmux produced no ID for $v — aborting (workspace may be half-built)." >&2
    exit 1
  fi
done

cmux rename-tab --workspace "$WS" --surface "$LEFT"  "ARCHITECT-${ISSUE_N}"
cmux rename-tab --workspace "$WS" --surface "$RIGHT" "CODEX-${ISSUE_N}"
cmux rename-tab --workspace "$WS" --surface "$BL"    "REVIEWER-${ISSUE_N}"
cmux rename-tab --workspace "$WS" --surface "$BR"    "VERIFIER-${ISSUE_N}"

# Banners
for pair in "$LEFT|ARCHITECT — plan + dispatch" \
            "$RIGHT|CODEX — codex-safe wrapper" \
            "$BL|REVIEWER — checklist + review.json" \
            "$BR|VERIFIER — pnpm test + typecheck"; do
  SURF="${pair%%|*}"
  MSG="${pair##*|}"
  cmux send --workspace "$WS" --surface "$SURF" "clear && echo '=== $MSG ==='"
  cmux send-key --workspace "$WS" --surface "$SURF" Enter
done

echo "workspace=$WS worktree=$WT_PATH branch=$BRANCH"
echo "panes: ARCH=$LEFT CODEX=$RIGHT REV=$BL VER=$BR"
