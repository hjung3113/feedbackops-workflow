#!/usr/bin/env bash
# conductor-rebuild.sh — reconstruct CONDUCTOR chunk states purely from
# .review/*.json artifacts on disk (no in-memory state).
#
# Codex review R6 (CRITICAL): the CONDUCTOR spans MULTIPLE branches/worktrees,
# so there is NO single global branch HEAD. Each pr_draft is resolved against
# ITS OWN worktree's current HEAD. A pr_draft is "verified" ONLY from the
# canonical ISSUE-<n>-VERIFY.json written by VERIFIER; embedded
# pr_draft.verify_result is deprecated and ignored. If the artifact has no
# resolvable worktree HEAD, its state is "unknown" — NEVER "verified".
#
# Usage: scripts/conductor-rebuild.sh <review-dir> [<fallback-head-sha>]
# Output: a header line, then one TSV line per (non-superseded) artifact:
#   <issue>\tblocked\t<reason_code>     (blocker)
#   <issue>\t<state>\t<branch>          (pr_draft)
# States: verified | stale_verify | unknown | in_progress
# Exit 0 (reporting tool). bash-3.2-compatible.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PRODUCT_HOME_LIB="$SCRIPT_DIR/lib/product-home.sh"
SCHEMA_VALIDATOR="$SCRIPT_DIR/lib/json-schema-subset.cjs"
WORKTREE_CONTENT_ID="$SCRIPT_DIR/lib/worktree-content-id.cjs"
VERIFY_SCHEMA=""
PR_DRAFT_SCHEMA=""
if [ -r "$PRODUCT_HOME_LIB" ] && [ -r "$SCHEMA_VALIDATOR" ]; then
  . "$PRODUCT_HOME_LIB"
  PRODUCT_ROOT="$(agent_workflow_product_root "$SCRIPT_DIR")"
  SCHEMA_DIR="$(agent_workflow_schema_dir "$PRODUCT_ROOT" 2>/dev/null || printf '')"
  if [ -n "$SCHEMA_DIR" ] && [ -r "$SCHEMA_DIR/verify.schema.json" ] && [ -r "$SCHEMA_DIR/pr_draft.schema.json" ]; then
    VERIFY_SCHEMA="$SCHEMA_DIR/verify.schema.json"
    PR_DRAFT_SCHEMA="$SCHEMA_DIR/pr_draft.schema.json"
  fi
fi

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

parse_verify_artifact() {
  node -e '
    const fs = require("fs");
    let o;
    try { o = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); }
    catch (e) { process.exit(2); }
    if (!o || typeof o !== "object" || Array.isArray(o)) process.exit(2);
    let schema, validate;
    try {
      schema = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
      ({ validate } = require(process.argv[3]));
    } catch (e) { process.exit(3); }
    if (validate(schema, o).length) process.exit(3);
    const sameJson = (left, right) => JSON.stringify(left) === JSON.stringify(right);
    const count = (value, key) => value && typeof value[key] === "number" && Number.isFinite(value[key]) ? value[key] : 0;
    function validRun(run) {
      if (!run || typeof run !== "object" || Array.isArray(run)
          || (run.classifier !== "PASS" && run.classifier !== "FAIL")
          || !run.verdict || !Array.isArray(run.failures) || !run.verify_cmd || !run.created_at) return false;
      const passed = count(run.verdict, "passed");
      const failed = count(run.verdict, "failed");
      if (!Number.isInteger(run.verdict.exit_code)) return false;
      return run.classifier === "PASS"
        ? passed >= 1 && failed === 0 && run.verdict.exit_code === 0 && run.failures.length === 0
        : failed > 0 || run.verdict.exit_code !== 0 || run.failures.length > 0;
    }
    if (Object.prototype.hasOwnProperty.call(o, "runs")) {
      if (!Array.isArray(o.runs)) process.exit(3);
      if (o.runs.length === 0 || !o.runs.every(validRun)) process.exit(3);
      const latest = o.runs[o.runs.length - 1];
      const allPass = o.runs.every((run) => run.classifier === "PASS");
      const expectedVerdict = {
        passed: o.runs.reduce((total, run) => total + count(run.verdict, "passed"), 0),
        failed: o.runs.reduce((total, run) => total + count(run.verdict, "failed"), 0),
        pending: o.runs.reduce((total, run) => total + count(run.verdict, "pending"), 0),
        exit_code: allPass ? 0 : 1
      };
      const expectedFailures = o.runs.reduce((all, run) => all.concat(run.failures), []);
      if (o.verify_cmd !== latest.verify_cmd || !sameJson(o.clean_state, latest.clean_state)
          || !sameJson(o.verdict, expectedVerdict) || o.classifier !== (allPass ? "PASS" : "FAIL")
          || !sameJson(o.failures, expectedFailures) || o.created_at !== latest.created_at) process.exit(3);
    }
    function get(path) {
      let v = o;
      for (let i = 0; i < path.length; i++) {
        if (v === undefined || v === null) return "";
        v = v[path[i]];
      }
      if (v === undefined || v === null) return "";
      return String(v);
    }
    const values = [
      get(["producer_role"]),
      get(["classifier"]),
      get(["verdict", "failed"]),
      get(["verdict", "passed"]),
      get(["verdict", "exit_code"]),
      get(["head_sha"]),
      get(["content_sha256"]),
      get(["issue"]),
      get(["branch"]),
      get(["verify_cmd"])
    ];
    process.stdout.write(values.join("\t"));
  ' "$1" "$VERIFY_SCHEMA" "$SCHEMA_VALIDATOR" 2>/dev/null
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

  if [ -z "$PR_DRAFT_SCHEMA" ] || ! node - "$f" "$PR_DRAFT_SCHEMA" "$SCHEMA_VALIDATOR" <<'NODE' >/dev/null 2>&1
const fs=require("fs"); try { const value=JSON.parse(fs.readFileSync(process.argv[2],"utf8")), schema=JSON.parse(fs.readFileSync(process.argv[3],"utf8")), {validate}=require(process.argv[4]); process.exit(validate(schema,value).length ? 1 : 0); } catch (_) { process.exit(1); }
NODE
  then
    echo "conductor-rebuild: $f failed PR-DRAFT schema validation — unknown" >&2
    printf '%s\t%s\t%s\n' "$issue" "unknown" "$branch"
    return 0
  fi

  status="$(parse_field "$f" 'status')"
  worktree="$(parse_field "$f" 'worktree_path')"
  verify_cmd="$(parse_field "$f" 'verify_cmd')"

  if [ "$status" != "ready_for_review" ]; then
    printf '%s\t%s\t%s\n' "$issue" "in_progress" "$branch"
    return 0
  fi

  vfile="$REVIEW_DIR/ISSUE-${issue}-VERIFY.json"
  if [ ! -f "$vfile" ]; then
    echo "conductor-rebuild: $f ready_for_review but missing canonical verify artifact $vfile — unknown" >&2
    printf '%s\t%s\t%s\n' "$issue" "unknown" "$branch"
    return 0
  fi

  vline="$(parse_verify_artifact "$vfile")"
  vrc=$?
  if [ "$vrc" -ne 0 ] || [ -z "$vline" ]; then
    echo "conductor-rebuild: $vfile parse failed — unknown (fail closed)" >&2
    printf '%s\t%s\t%s\n' "$issue" "unknown" "$branch"
    return 0
  fi

  oldIFS=$IFS
  IFS="$(printf '\t')"
  set -- $vline
  IFS=$oldIFS
  v_role="${1:-}"
  v_class="${2:-}"
  v_failed="${3:-}"
  v_passed="${4:-}"
  v_exit="${5:-}"
  v_head="${6:-}"
  v_content="${7:-}"
  v_issue="${8:-}"
  v_branch="${9:-}"
  v_cmd="${10:-}"

  if [ -n "$verify_cmd" ] && [ -n "$v_cmd" ] && [ "$verify_cmd" != "$v_cmd" ]; then
    echo "conductor-rebuild: WARN $f verify_cmd '$verify_cmd' differs from $vfile verify_cmd '$v_cmd' — reviewer must check filter coverage" >&2
  fi

  if [ "$v_role" != "VERIFIER" ] || [ "$v_class" != "PASS" ] \
     || [ "$v_failed" != "0" ] || [ -z "$v_passed" ] || [ "$v_passed" = "0" ] \
     || [ "$v_exit" != "0" ] || [ "$v_issue" != "$issue" ] \
     || [ -z "$branch" ] || [ "$branch" = "(unknown-branch)" ] || [ "$v_branch" != "$branch" ]; then
    echo "conductor-rebuild: $vfile does not satisfy canonical verify gates — unknown" >&2
    printf '%s\t%s\t%s\n' "$issue" "unknown" "$branch"
    return 0
  fi

  # Resolve THIS artifact's real branch HEAD against its OWN worktree.
  # head_source records WHERE actual_head came from: only a "worktree" source
  # (an independent live `git rev-parse HEAD` on the artifact's own worktree)
  # is trustworthy enough to certify `verified`. The optional fallback arg is
  # NOT a per-branch HEAD — it may only ever DEMOTE, never produce `verified`
  # (R6: an artifact must not be able to certify itself).
  #
  # RF2 (branch-identity binding): a worktree HEAD is only trustworthy if that
  # worktree is actually checked out on the artifact's DECLARED branch. A stale
  # or wrong worktree_path (symlink, sibling branch's checkout) could point at a
  # DIFFERENT branch whose HEAD coincidentally equals verified_head_sha — that
  # certifies the wrong identity. So when the artifact carries a `branch` field
  # and the worktree's live branch does NOT match it, we refuse to treat the
  # worktree as a trustworthy source (head_source stays empty → state `unknown`).
  # With no `branch` field we cannot cross-check, so we keep prior behavior.
  actual_head=""
  actual_content=""
  head_source=""
  if [ -n "$worktree" ] && [ -d "$worktree" ]; then
    actual_branch="$(git -C "$worktree" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    if [ -n "$branch" ] && [ "$branch" != "(unknown-branch)" ] \
       && [ -n "$actual_branch" ] && [ "$actual_branch" != "$branch" ]; then
      # identity mismatch: worktree is on a different branch than the artifact
      # claims. Do NOT trust it as a `verified` source.
      echo "conductor-rebuild: $f worktree on branch '$actual_branch' but artifact claims '$branch' — identity mismatch, not verifiable" >&2
    else
      actual_head="$(git -C "$worktree" rev-parse HEAD 2>/dev/null)"
      actual_content="$(node "$WORKTREE_CONTENT_ID" "$worktree" 2>/dev/null)"
      if [ -n "$actual_head" ] && [ -n "$actual_content" ]; then
        head_source="worktree"
      else
        actual_head=""
        actual_content=""
      fi
    fi
  fi
  if [ -z "$head_source" ] && [ -z "$actual_head" ] && [ -n "$FALLBACK_HEAD" ]; then
    actual_head="$FALLBACK_HEAD"
    head_source="fallback"
  fi

  state="unknown"
  if [ -z "$actual_head" ]; then
    state="unknown"
  elif [ "$head_source" = "fallback" ]; then
    # A fallback HEAD is not a trustworthy per-branch HEAD. It can never
    # produce `verified` (that would let an artifact certify itself). Cap
    # at `unknown` regardless of whether it happens to match head_sha.
    state="unknown"
  elif [ "$v_head" = "$actual_head" ] && [ "$v_content" = "$actual_content" ]; then
    # head_source == "worktree": independent live HEAD and content lookups agreed → verified.
    state="verified"
  else
    # work landed or its Git-visible content changed after verify
    state="stale_verify"
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
