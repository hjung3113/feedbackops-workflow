#!/usr/bin/env bash
# round-state-init.sh — scaffold a schema-valid skeleton ROUND-STATE for an
# issue, replacing CONDUCTOR's copy-a-prior-issue step. The tool fills only
# mechanical fields (issue identity from `gh issue view`, git base/head,
# worktree path, timestamp, AC candidates extracted from the issue body);
# tier, objective, touch_allowlist, prohibitions, verify_filter,
# test_discovery_command, and expected_test_count remain explicit
# TODO-marked author decisions. The schema forbids empty strings/arrays in
# those slots (minLength 1 / minItems 1), so every author-owned slot is
# seeded with a "TODO: ..." placeholder that satisfies the schema while
# staying unmissable. This is a scaffold-once tool: CONDUCTOR owns every
# revision after creation, so an existing file is never overwritten without
# --force.
#
# base_branch strategy (deterministic): --base-branch when given; otherwise
# the worktree's origin default branch from
# `git symbolic-ref refs/remotes/origin/HEAD` (shortened to origin/<name>);
# otherwise the literal "main".
#
# AC extraction: markdown list items ("- ", "* ", "+ ", or "N. ") under any
# ATX heading whose text contains the standalone word "AC" or the word
# "Acceptance" (case-insensitive); if no such heading yields items, the same
# scan runs under headings containing "검증". Statements are list-marker-
# stripped, ids are sequential AC-<issue>-<k> in source order. With no match
# a single TODO placeholder entry is emitted plus a stderr WARNING — the
# criteria array is never empty. Extracted entries are candidates for the
# author to review, not final.
#
# Usage: round-state-init.sh <issue-number> --worktree <path> \
#   [--base-branch <ref>] [--out <path>] [--force]
#
# Exit 0 = scaffolded and schema-validated; 1 = runtime failure (gh/git/
# validation/overwrite refusal); 2 = usage. Bash-3.2-compatible.
set -u

PROG="round-state-init"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PRODUCT_HOME_LIB="$SCRIPT_DIR/lib/product-home.sh"
CONTRACT_VALIDATORS="$SCRIPT_DIR/lib/contract-validators.cjs"

usage() {
  echo "usage: $0 <issue-number> --worktree <path> [--base-branch <ref>] [--out <path>] [--force]" >&2
}

if [ ! -r "$PRODUCT_HOME_LIB" ]; then
  echo "$PROG: ERROR — product-home resolver is missing: $PRODUCT_HOME_LIB" >&2
  exit 2
fi
. "$PRODUCT_HOME_LIB"
PRODUCT_ROOT="$(agent_workflow_product_root "$SCRIPT_DIR")"
SCHEMA_DIR="$(agent_workflow_schema_dir "$PRODUCT_ROOT")" || {
  echo "$PROG: ERROR — product schemas are missing beneath: $PRODUCT_ROOT" >&2
  exit 2
}
ROUND_STATE_SCHEMA="$SCHEMA_DIR/round_state.schema.json"

issue_number=""
worktree=""
base_branch_arg=""
out_path=""
force=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --worktree) worktree="${2:-}"; shift 2 ;;
    --base-branch) base_branch_arg="${2:-}"; shift 2 ;;
    --out) out_path="${2:-}"; shift 2 ;;
    --force) force=1; shift ;;
    -*) usage; exit 2 ;;
    *)
      if [ -n "$issue_number" ]; then usage; exit 2; fi
      issue_number="$1"
      shift
      ;;
  esac
done

case "$issue_number" in
  ''|*[!0-9]*|0) usage; echo "$PROG: ERROR — issue number must be a positive integer" >&2; exit 2 ;;
esac
if [ -z "$worktree" ] || [ ! -d "$worktree" ]; then
  usage
  echo "$PROG: ERROR — --worktree requires an existing directory" >&2
  exit 2
fi
for required_file in "$ROUND_STATE_SCHEMA" "$CONTRACT_VALIDATORS"; do
  if [ ! -f "$required_file" ] || [ ! -r "$required_file" ]; then
    echo "$PROG: ERROR — required input is missing or unreadable: $required_file" >&2
    exit 2
  fi
done

if ! command -v gh >/dev/null 2>&1; then
  echo "$PROG: ERROR — gh CLI is unavailable; cannot fetch issue $issue_number" >&2
  exit 1
fi
if ! git -C "$worktree" rev-parse --git-dir >/dev/null 2>&1; then
  echo "$PROG: ERROR — not a git worktree: $worktree" >&2
  exit 1
fi

GH_JSON="$(mktemp "${TMPDIR:-/tmp}/round-state-init-gh.XXXXXX")" || exit 1
GH_ERR="$(mktemp "${TMPDIR:-/tmp}/round-state-init-gh-err.XXXXXX")" || exit 1
trap 'rm -f "$GH_JSON" "$GH_ERR"' EXIT
if ! gh issue view "$issue_number" --json number,title,body >"$GH_JSON" 2>"$GH_ERR"; then
  echo "$PROG: ERROR — gh issue view $issue_number failed:" >&2
  cat "$GH_ERR" >&2
  exit 1
fi

if [ -n "$base_branch_arg" ]; then
  base_branch="$base_branch_arg"
else
  default_ref="$(git -C "$worktree" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null)" || default_ref=""
  if [ -n "$default_ref" ]; then
    base_branch="${default_ref#refs/remotes/}"
  else
    base_branch="main"
  fi
fi

base_sha="$(git -C "$worktree" merge-base HEAD "$base_branch" 2>/dev/null)" || {
  echo "$PROG: ERROR — cannot compute merge-base of HEAD against '$base_branch' in $worktree" >&2
  exit 1
}
head_sha="$(git -C "$worktree" rev-parse HEAD)" || exit 1
worktree_abs="$(cd "$worktree" && pwd)" || exit 1
updated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [ -z "$out_path" ]; then
  out_path="$worktree_abs/.review/ISSUE-${issue_number}-ROUND-STATE.json"
fi
out_dir="$(dirname "$out_path")"
if [ ! -d "$out_dir" ]; then
  mkdir -p "$out_dir" || {
    echo "$PROG: ERROR — cannot create output directory: $out_dir" >&2
    exit 1
  }
fi
if [ -e "$out_path" ] && [ "$force" -ne 1 ]; then
  echo "$PROG: ERROR — refusing to overwrite existing file (CONDUCTOR owns revisions after creation): $out_path" >&2
  echo "$PROG: pass --force to overwrite anyway" >&2
  exit 1
fi

TMP_OUT="${out_path}.tmp.$$"
# The node block parses the gh JSON, extracts AC candidates, builds the
# skeleton, and validates it against round_state.schema.json via the shared
# loadSchema validator before anything reaches the final path.
if ! node - "$GH_JSON" "$CONTRACT_VALIDATORS" "$issue_number" "$base_branch" \
  "$base_sha" "$head_sha" "$worktree_abs" "$updated_at" >"$TMP_OUT" <<'NODE'
const fs = require("fs");
const [ghFile, contractValidatorsFile, issueNumber, baseBranch, baseSha, headSha, worktreePath, updatedAt] =
  process.argv.slice(2);
let gh;
try {
  gh = JSON.parse(fs.readFileSync(ghFile, "utf8"));
} catch (error) {
  console.error("cannot parse gh issue view output: " + error.message);
  process.exit(1);
}
if (!gh || typeof gh !== "object" || typeof gh.title !== "string" || !gh.title.trim() ||
    String(gh.number) !== String(issueNumber) || typeof gh.body !== "string") {
  console.error("gh issue view output is missing a non-empty title or number/body for issue " + issueNumber);
  process.exit(1);
}

// AC candidate extraction: list items under AC/Acceptance headings first,
// then 검증 headings, then one TODO placeholder. Never an empty array.
function itemsUnderHeading(body, headingTest) {
  const found = [];
  let collecting = false;
  for (const raw of body.split(/\r?\n/)) {
    const heading = raw.match(/^#{1,6}\s+(.*?)\s*#*\s*$/);
    if (heading) {
      collecting = headingTest(heading[1]);
      continue;
    }
    if (!collecting) continue;
    const item = raw.match(/^(?:[-*+]|\d+[.)])\s+(.*)$/);
    if (item) {
      const statement = item[1].trim();
      if (statement) found.push(statement);
    }
  }
  return found;
}
const acHeading = (text) => /(?:^|[^A-Za-z])AC(?:[^A-Za-z]|$)/i.test(text) || /acceptance/i.test(text);
let statements = itemsUnderHeading(gh.body, acHeading);
if (!statements.length) {
  statements = itemsUnderHeading(gh.body, (text) => text.indexOf("검증") !== -1);
}
let placeholderAc = false;
if (!statements.length) {
  statements = ["TODO: fill in acceptance criteria"];
  placeholderAc = true;
  console.error("WARNING: no AC list items found under an AC/Acceptance/검증 heading in issue " +
    issueNumber + "; emitted a TODO placeholder criterion.");
}
const criteria = statements.map((statement, index) => ({
  id: "AC-" + issueNumber + "-" + (index + 1),
  statement: statement
}));

const state = {
  schema_version: "1",
  artifact_type: "round_state",
  lifecycle: "active",
  producer_role: "CONDUCTOR",
  issue: { number: Number(issueNumber), title: gh.title.trim() },
  tier: {
    name: "standard",
    rationale: "TODO: pick tier (trivial|standard|full_cluster) and record rationale"
  },
  revision: 1,
  updated_at: updatedAt,
  base_branch: baseBranch,
  base_sha: baseSha,
  head_sha: headSha,
  worktree_path: worktreePath,
  contract: {
    objective: "TODO: fill in contract objective",
    touch_allowlist: ["TODO: fill in touch allowlist"],
    prohibitions: ["TODO: fill in prohibitions"],
    verify_filter: "TODO: fill in verify filter",
    test_discovery_command: "TODO: fill in test discovery command"
  },
  acceptance: {
    criteria: criteria,
    expected_test_count: 1
  },
  decisions: [],
  prior_findings: [],
  commit_scope: { commits: [] },
  live_probes: [],
  artifact_pointers: []
};

const { schema, validate } = require(contractValidatorsFile).loadSchema("round_state.schema.json");
const schemaErrors = validate(schema, state);
if (schemaErrors.length) {
  console.error("scaffold does not validate against round_state.schema.json: " + JSON.stringify(schemaErrors));
  process.exit(1);
}
process.stdout.write(JSON.stringify(state, null, 2) + "\n");
NODE
then
  rm -f "$TMP_OUT"
  echo "$PROG: ERROR — scaffold generation or schema validation failed" >&2
  exit 1
fi

if ! mv "$TMP_OUT" "$out_path"; then
  rm -f "$TMP_OUT"
  echo "$PROG: ERROR — cannot move scaffold into place: $out_path" >&2
  exit 1
fi

echo "wrote $out_path"
echo "author TODOs (schema forbids empty slots, placeholders are seeded):"
echo "  - tier.name/tier.rationale (seeded standard; pick trivial|standard|full_cluster)"
echo "  - contract.objective, contract.touch_allowlist, contract.prohibitions"
echo "  - contract.verify_filter, contract.test_discovery_command"
echo "  - acceptance.expected_test_count (seeded 1; set the real count)"
echo "acceptance.criteria entries are extraction candidates from the issue body — review and edit them."
if grep -q '"TODO: fill in acceptance criteria"' "$out_path"; then
  echo "WARNING: no AC list items were found under an AC/Acceptance/검증 heading; a TODO placeholder criterion was emitted." >&2
fi
