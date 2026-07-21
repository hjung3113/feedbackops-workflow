#!/usr/bin/env bash
# Host-side publisher for an untrusted read-only CONDUCTOR proposal. It is the
# sole writer of the narrow canonical control surface; runtimes never receive
# source write permission merely because they are conducting.
# bash-3.2 compatible.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROPOSAL_SCHEMA="$SCRIPT_DIR/../schemas/conductor_control_proposal.schema.json"
ROUND_STATE_SCHEMA="$SCRIPT_DIR/../schemas/round_state.schema.json"
VALIDATOR="$SCRIPT_DIR/lib/json-schema-subset.cjs"
ISSUE_N=""; CWD=""; PROPOSAL=""

usage() { echo "usage: conductor-control-publish.sh --issue N --cwd DIR --proposal FILE" >&2; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --issue) ISSUE_N="$2"; shift 2 ;;
    --cwd) CWD="$2"; shift 2 ;;
    --proposal) PROPOSAL="$2"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
[ -n "$ISSUE_N" ] && [ -d "$CWD" ] && [ -r "$PROPOSAL" ] || { usage; exit 2; }
ABS_CWD="$(cd "$CWD" && pwd -P)"

# A mkdir lock makes revision comparison and publication one host transaction.
REVIEW_DIR="$ABS_CWD/.review"
if [ -L "$REVIEW_DIR" ]; then
  echo '{"ok":false,"code":"conductor_control_review_dir_symlink"}' >&2
  exit 2
fi
mkdir -p "$REVIEW_DIR"
REAL_REVIEW_DIR="$(cd "$REVIEW_DIR" && pwd -P)"
if [ "$REAL_REVIEW_DIR" != "$REVIEW_DIR" ]; then
  echo '{"ok":false,"code":"conductor_control_review_dir_escape"}' >&2
  exit 2
fi
LOCK="$REVIEW_DIR/.conductor-control-${ISSUE_N}.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  echo '{"ok":false,"code":"conductor_control_busy"}' >&2
  exit 1
fi
cleanup() { rmdir "$LOCK" 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM

node - "$PROPOSAL" "$PROPOSAL_SCHEMA" "$ROUND_STATE_SCHEMA" "$VALIDATOR" "$ISSUE_N" "$ABS_CWD" <<'NODE'
const fs = require("fs");
const { execFileSync } = require("child_process");
const [proposalFile, proposalSchemaFile, roundSchemaFile, validatorFile, issueText, cwd] = process.argv.slice(2);
function die(code) { process.stderr.write(JSON.stringify({ ok: false, code }) + "\n"); process.exit(2); }
try {
  const proposal = JSON.parse(fs.readFileSync(proposalFile, "utf8"));
  const proposalSchema = JSON.parse(fs.readFileSync(proposalSchemaFile, "utf8"));
  const roundSchema = JSON.parse(fs.readFileSync(roundSchemaFile, "utf8"));
  const { validate } = require(validatorFile);
  if (validate(proposalSchema, proposal).length) die("conductor_control_proposal_invalid");
  const head = execFileSync("git", ["-C", cwd, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
  const action = proposal.actions[0];
  const expectedPath = `.review/ISSUE-${issueText}-ROUND-STATE.json`;
  if (proposal.issue !== Number(issueText)) die("conductor_control_issue_mismatch");
  if (proposal.head_sha !== head) die("conductor_control_head_mismatch");
  if (action.relative_path !== expectedPath) die("conductor_control_path_denied");
  const value = action.content;
  if (validate(roundSchema, value).length) die("conductor_control_round_state_invalid");
  if (value.issue.number !== Number(issueText) || value.head_sha !== head) die("conductor_control_round_state_identity_mismatch");
  if (fs.realpathSync(cwd) !== fs.realpathSync(value.worktree_path)) die("conductor_control_worktree_mismatch");
  execFileSync("git", ["-C", cwd, "cat-file", "-e", `${value.base_sha}^{commit}`]);
  const baseRef = execFileSync("git", ["-C", cwd, "rev-parse", "--verify", `${value.base_branch}^{commit}`], { encoding: "utf8" }).trim();
  const liveBase = execFileSync("git", ["-C", cwd, "merge-base", head, baseRef], { encoding: "utf8" }).trim();
  if (value.base_sha !== liveBase) die("conductor_control_base_mismatch");
  const target = require("path").join(cwd, action.relative_path);
  if (fs.existsSync(target)) {
    const prior = JSON.parse(fs.readFileSync(target, "utf8"));
    if (validate(roundSchema, prior).length) die("conductor_control_existing_invalid");
    if (prior.issue.number !== Number(issueText)) die("conductor_control_existing_issue_mismatch");
    if (value.revision <= prior.revision) die("conductor_control_revision_not_advanced");
  }
  const temporary = `${target}.tmp-${process.pid}`;
  fs.writeFileSync(temporary, JSON.stringify(value, null, 2) + "\n", { mode: 0o600, flag: "wx" });
  // Validate the exact bytes that will be published before replacement.
  const published = JSON.parse(fs.readFileSync(temporary, "utf8"));
  if (validate(roundSchema, published).length) die("conductor_control_publish_invalid");
  fs.renameSync(temporary, target);
  process.stdout.write(JSON.stringify({ ok: true, artifact: action.artifact_type, path: action.relative_path, revision: value.revision, head_sha: head }) + "\n");
} catch (error) {
  if (error && error.code === "EEXIST") die("conductor_control_temp_exists");
  die("conductor_control_publish_failed");
}
NODE
