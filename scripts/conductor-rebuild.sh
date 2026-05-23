#!/usr/bin/env bash
# conductor-rebuild.sh — reconstruct CONDUCTOR chunk states purely from
# .review/*.json artifacts on disk (no in-memory state).
#
# Codex review R6 (CRITICAL): the CONDUCTOR spans MULTIPLE branches/worktrees,
# so there is NO single global branch HEAD. Each pr_draft is resolved against
# ITS OWN worktree's current HEAD. A pr_draft is "verified" ONLY if, in its own
# worktree, `git rev-parse HEAD` equals its verify_result.verified_head_sha
# (and failed==0, passed>0). If the artifact has no resolvable worktree HEAD,
# its state is "unknown" — NEVER "verified".
#
# Usage: scripts/conductor-rebuild.sh <review-dir> [<fallback-head-sha>]
# Output: a header line, then one TSV line per (non-superseded) artifact:
#   <issue>\tblocked\t<reason_code>     (blocker)
#   <issue>\t<state>\t<branch>          (pr_draft)
# States: verified | stale_verify | unknown | in_progress
# Exit 0 (reporting tool). bash-3.2-compatible.
set -u

REVIEW_DIR="${1:-}"
FALLBACK_HEAD="${2:-}"

if [ -z "$REVIEW_DIR" ] || [ ! -d "$REVIEW_DIR" ]; then
  echo "usage: $0 <review-dir> [<fallback-head-sha>]" >&2
  echo "  (review-dir must be an existing directory)" >&2
  exit 0
fi

if ! command -v node >/dev/null 2>&1; then
  echo "conductor-rebuild: node is required for JSON parsing" >&2
  exit 0
fi

echo "# conductor state rebuild — $REVIEW_DIR"
echo "# issue<TAB>state<TAB>detail"

# parse_field <file> <dotted.path>
# Walks a dotted property path (e.g. "verify_result.passed") and prints the
# value, or empty string if any segment is missing. node handles
# missing/malformed JSON safely (empty output, no crash).
parse_field() {
  node -e '
    const fs = require("fs");
    let o;
    try { o = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); }
    catch (e) { process.exit(2); }
    let v = o;
    const path = process.argv[2].split(".");
    for (let i = 0; i < path.length; i++) {
      if (v === undefined || v === null) { v = undefined; break; }
      v = v[path[i]];
    }
    if (v === undefined || v === null) { process.stdout.write(""); }
    else { process.stdout.write(String(v)); }
  ' "$1" "$2" 2>/dev/null
}

process_blocker() {
  f="$1"
  lifecycle="$(parse_field "$f" 'lifecycle')"
  [ "$lifecycle" = "superseded" ] && return 0
  issue="$(parse_field "$f" 'issue.number')"
  reason="$(parse_field "$f" 'reason_code')"
  if [ -z "$issue" ]; then
    echo "conductor-rebuild: skipping malformed blocker $f (no issue.number)" >&2
    return 0
  fi
  [ -z "$reason" ] && reason="unknown_reason"
  printf '%s\t%s\t%s\n' "$issue" "blocked" "$reason"
}

process_pr_draft() {
  f="$1"
  lifecycle="$(parse_field "$f" 'lifecycle')"
  [ "$lifecycle" = "superseded" ] && return 0

  issue="$(parse_field "$f" 'issue.number')"
  branch="$(parse_field "$f" 'branch')"
  if [ -z "$issue" ]; then
    echo "conductor-rebuild: skipping malformed pr_draft $f (no issue.number)" >&2
    return 0
  fi
  [ -z "$branch" ] && branch="(unknown-branch)"

  status="$(parse_field "$f" 'status')"
  worktree="$(parse_field "$f" 'worktree_path')"
  v_head="$(parse_field "$f" 'verify_result.verified_head_sha')"
  v_passed="$(parse_field "$f" 'verify_result.passed')"
  v_failed="$(parse_field "$f" 'verify_result.failed')"
  v_exit="$(parse_field "$f" 'verify_result.exit_code')"
  # verify_result is "present" iff it carries a verified_head_sha (its required field).
  has_vr=""
  [ -n "$v_head" ] && has_vr="yes"

  # Resolve THIS artifact's real branch HEAD against its OWN worktree.
  # head_source records WHERE actual_head came from: only a "worktree" source
  # (an independent live `git rev-parse HEAD` on the artifact's own worktree)
  # is trustworthy enough to certify `verified`. The optional fallback arg is
  # NOT a per-branch HEAD — it may only ever DEMOTE, never produce `verified`
  # (R6: an artifact must not be able to certify itself).
  actual_head=""
  head_source=""
  if [ -n "$worktree" ] && [ -d "$worktree" ]; then
    actual_head="$(git -C "$worktree" rev-parse HEAD 2>/dev/null)"
    [ -n "$actual_head" ] && head_source="worktree"
  elif [ -n "$FALLBACK_HEAD" ]; then
    actual_head="$FALLBACK_HEAD"
    head_source="fallback"
  fi

  state="in_progress"
  if [ "$status" = "ready_for_review" ] && [ "$has_vr" = "yes" ] \
     && [ "$v_exit" = "0" ] && [ "$v_failed" = "0" ] \
     && [ -n "$v_passed" ] && [ "$v_passed" != "0" ]; then
    if [ -z "$actual_head" ]; then
      # ready, verified clean, but we cannot prove against any HEAD → unknown.
      state="unknown"
    elif [ "$head_source" = "fallback" ]; then
      # A fallback HEAD is not a trustworthy per-branch HEAD. It can never
      # produce `verified` (that would let an artifact certify itself). Cap
      # at `unknown` regardless of whether it happens to match verified_head_sha.
      state="unknown"
    elif [ "$v_head" = "$actual_head" ]; then
      # head_source == "worktree": an INDEPENDENT live lookup agreed → verified.
      state="verified"
    else
      # work landed after verify
      state="stale_verify"
    fi
  fi

  printf '%s\t%s\t%s\n' "$issue" "$state" "$branch"
}

# Iterate blockers + pr_drafts. Use a glob guard so an empty match is a no-op.
for f in "$REVIEW_DIR"/ISSUE-*-BLOCKER.json; do
  [ -e "$f" ] || continue
  process_blocker "$f"
done

for f in "$REVIEW_DIR"/ISSUE-*-PR-DRAFT.json; do
  [ -e "$f" ] || continue
  process_pr_draft "$f"
done

exit 0
