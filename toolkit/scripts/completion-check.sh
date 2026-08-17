#!/usr/bin/env bash
# completion-check.sh — independently calculate whether a worker met its contract
# and derive compile-atomic review obligations from the live diff.
#
# Usage: scripts/completion-check.sh --round-state <json-file> --manifest-revision <n>
#
# Exit 0 = completion facts match the contract; 1 = mismatches; 2 = input error.
# The target profile owns test discovery. This command consumes its text output;
# it never accepts RUN.json or worker prose as completion evidence.
set -u

PROG="completion-check"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PRODUCT_HOME_LIB="$SCRIPT_DIR/lib/product-home.sh"
SCHEMA_VALIDATOR="$SCRIPT_DIR/lib/json-schema-subset.cjs"
CONTRACT_VALIDATORS="$SCRIPT_DIR/lib/contract-validators.cjs"
FRESH_CHECK="$SCRIPT_DIR/artifact-fresh.sh"
round_state=""
expected_revision=""

emit_error() {
  code="$1"
  printf '{"status":"error","mismatches":[{"code":"%s"}]}' "$code"
  printf '\n'
}

if [ ! -r "$PRODUCT_HOME_LIB" ]; then
  emit_error "unreadable_input"
  exit 2
fi
. "$PRODUCT_HOME_LIB"
PRODUCT_ROOT="$(agent_workflow_product_root "$SCRIPT_DIR")"
SCHEMA_DIR="$(agent_workflow_schema_dir "$PRODUCT_ROOT")" || {
  emit_error "unreadable_input"
  exit 2
}
ROUND_STATE_SCHEMA="$SCHEMA_DIR/round_state.schema.json"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --round-state|--manifest-revision)
      if [ "$#" -lt 2 ]; then
        emit_error "invalid_arguments"
        exit 2
      fi
      case "$1" in
        --round-state) round_state="$2" ;;
        --manifest-revision) expected_revision="$2" ;;
      esac
      shift 2
      ;;
    *) emit_error "invalid_arguments"; exit 2 ;;
  esac
done

if [ -z "$round_state" ] || [ -z "$expected_revision" ]; then
  emit_error "invalid_arguments"
  exit 2
fi
case "$expected_revision" in ''|*[!0-9]*|0) emit_error "invalid_manifest_revision"; exit 2 ;; esac
if [ ! -r "$round_state" ] || [ ! -r "$SCHEMA_VALIDATOR" ] || [ ! -r "$ROUND_STATE_SCHEMA" ]; then
  emit_error "unreadable_input"
  exit 2
fi
if [ ! -x "$FRESH_CHECK" ]; then
  emit_error "missing_freshness_checker"
  exit 2
fi

bash "$FRESH_CHECK" "$round_state" >/dev/null
fresh_status=$?
if [ "$fresh_status" -ne 0 ]; then
  emit_error "round_state_not_fresh"
  exit 2
fi

node - "$round_state" "$CONTRACT_VALIDATORS" "$expected_revision" <<'NODE'
const fs = require("fs");
const { execFileSync } = require("child_process");
const [roundStateFile, contractValidatorsFile, expectedRevision] = process.argv.slice(2);

function error(code, message) {
  process.stdout.write(JSON.stringify({ status: "error", mismatches: [{ code }], error: message }) + "\n");
  process.exit(2);
}
const DISCOVERY_DIAGNOSTIC_LIMIT = 4096;
function utf8Prefix(buffer, limit) {
  if (buffer.length <= limit) return buffer;
  let end = limit;
  while (end > 0 && (buffer[end - 1] & 0xc0) === 0x80) end -= 1;
  const lead = buffer[end - 1];
  const width = lead < 0x80 ? 1 : (lead & 0xe0) === 0xc0 ? 2 : (lead & 0xf0) === 0xe0 ? 3 : (lead & 0xf8) === 0xf0 ? 4 : 1;
  return end - 1 + width > limit ? buffer.subarray(0, end - 1) : buffer.subarray(0, limit);
}
function discoveryFailure(errorValue) {
  const stdout = Buffer.isBuffer(errorValue.stdout) ? errorValue.stdout : Buffer.from(errorValue.stdout || "", "utf8");
  const stderr = Buffer.isBuffer(errorValue.stderr) ? errorValue.stderr : Buffer.from(errorValue.stderr || "", "utf8");
  const output = Buffer.concat([stdout, stderr]);
  process.stdout.write(JSON.stringify({
    status: "error",
    mismatches: [{ code: "test_discovery_failed" }],
    error: "target-native test discovery failed",
    exit_code: Number.isInteger(errorValue.status) ? errorValue.status : 1,
    output: utf8Prefix(output, DISCOVERY_DIAGNOSTIC_LIMIT).toString("utf8"),
    output_truncated: output.length > DISCOVERY_DIAGNOSTIC_LIMIT
  }) + "\n");
  process.exit(2);
}
function globMatches(pattern, value) {
  let source = "^";
  for (let i = 0; i < pattern.length; i += 1) {
    const c = pattern[i];
    if (c === "*") {
      if (pattern[i + 1] === "*") { source += ".*"; i += 1; }
      else source += "[^/]*";
    } else if (c === "?") source += "[^/]";
    else source += c.replace(/[|\\{}()[\]^$+?.]/g, "\\$&");
  }
  return new RegExp(source + "$").test(value);
}
function discovered(id, text) {
  const escaped = id.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return new RegExp("(^|[^A-Za-z0-9_.-])" + escaped + "([^A-Za-z0-9_.-]|$)", "m").test(text);
}
function isRepositoryRelative(value) {
  return typeof value === "string"
    && value.length > 0
    && !value.startsWith("/")
    && !value.startsWith("\\")
    && !/^[A-Za-z]:/.test(value)
    && !value.split("/").includes("..");
}
function isAllowlistPattern(value) {
  // Patterns are target-relative path globs, never filesystem paths. Reject
  // empty segments/traversal before matching, so a permissive `**` cannot
  // quietly turn a malformed contract into an escape hatch.
  return isRepositoryRelative(value)
    && !value.split("/").some(part => part === "" || part === ".")
    && !/[\\\0]/.test(value);
}
function isExplicitNewFile(value) {
  // New files are an intentional exception, not another glob.  Requiring one
  // exact repository-relative filename makes a misspelled existing path fail
  // closed instead of creating a broad write capability.
  return isRepositoryRelative(value)
    && !value.split("/").some(part => part === "" || part === ".")
    && !/[\\\0*?\[\]{}]/.test(value);
}

let state;
try {
  state = JSON.parse(fs.readFileSync(roundStateFile, "utf8"));
} catch (e) { error("invalid_round_state", "cannot parse ROUND-STATE or schema: " + e.message); }
let schema, validate;
try { ({ schema, validate } = require(contractValidatorsFile).loadSchema("round_state.schema.json")); }
catch (e) { error("invalid_round_state", "cannot load schema validator: " + e.message); }
const schemaErrors = validate(schema, state);
if (schemaErrors.length) error("invalid_round_state", "ROUND-STATE schema validation failed");
if (state.lifecycle !== "active" && state.lifecycle !== "final") error("invalid_round_state", "ROUND-STATE lifecycle is not gateable");

const mismatches = [];
if (!Array.isArray(state.contract.touch_allowlist) || !state.contract.touch_allowlist.every(isAllowlistPattern)) {
  error("invalid_touch_allowlist", "touch_allowlist must contain only safe target-relative path globs");
}
const newFileAllowlist = state.contract.new_file_allowlist || [];
if (!Array.isArray(newFileAllowlist) || !newFileAllowlist.every(isExplicitNewFile)) {
  error("invalid_new_file_allowlist", "new_file_allowlist must contain only exact safe target-relative file paths");
}
if (String(state.revision) !== expectedRevision) {
  mismatches.push({ code: "stale_manifest_revision", expected: Number(expectedRevision), actual: state.revision });
}
let changedPaths, headSha;
try {
  headSha = execFileSync("git", ["-C", state.worktree_path, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
  changedPaths = execFileSync("git", ["-C", state.worktree_path, "diff", "--name-only", state.base_sha + "..HEAD"], { encoding: "utf8" }).trim().split("\n").filter(Boolean);
} catch (e) { error("uncheckable_worktree", "cannot independently calculate base..HEAD diff: " + e.message); }
let tests;
try {
  tests = execFileSync("/bin/sh", ["-c", state.contract.test_discovery_command], {
    cwd: state.worktree_path
  });
} catch (e) { discoveryFailure(e); }
tests = tests.toString("utf8");

const boundary = state.contract.chunk_boundary;
let typecheck = null;
let compileConsumers = [];
let reviewObligations = [];
if (boundary) {
  const surfaces = new Set();
  for (const consumer of boundary.compile_consumers) {
    if (!isRepositoryRelative(consumer)) {
      error("invalid_chunk_boundary", "compile consumers must be repository-relative paths");
    }
  }
  for (const watch of boundary.convention_watch) {
    if (surfaces.has(watch.surface)) {
      error("invalid_chunk_boundary", "convention watch surfaces must be unique");
    }
    surfaces.add(watch.surface);
    if (!watch.trigger.every(isRepositoryRelative)) {
      error("invalid_chunk_boundary", "convention watch triggers must be repository-relative globs");
    }
  }

  compileConsumers = boundary.compile_consumers;
  for (const consumer of compileConsumers) {
    if (!state.contract.touch_allowlist.some((pattern) => globMatches(pattern, consumer))) {
      mismatches.push({ code: "compile_consumer_outside_chunk", path: consumer });
    }
  }

  let typecheckExit = 0;
  try {
    execFileSync("/bin/sh", ["-c", boundary.typecheck_command], {
      cwd: state.worktree_path,
      encoding: "utf8"
    });
  } catch (e) {
    typecheckExit = Number.isInteger(e.status) ? e.status : 1;
    mismatches.push({ code: "typecheck_failed", exit_code: typecheckExit });
  }
  typecheck = { command: boundary.typecheck_command, exit_code: typecheckExit };

  reviewObligations = boundary.convention_watch
    .filter((watch) => watch.review_by_chunk === boundary.chunk_id
      && watch.trigger.some((pattern) => changedPaths.some((path) => globMatches(pattern, path))))
    .map((watch) => ({
      surface: watch.surface,
      expected_invariant: watch.expected_invariant,
      owner: watch.owner,
      closed_by: watch.closed_by
    }));
}
for (const path of changedPaths) {
  if (!state.contract.touch_allowlist.some((pattern) => globMatches(pattern, path))) {
    mismatches.push({ code: "changed_path_outside_allowlist", path });
  }
  let existedAtBase = false;
  try {
    execFileSync("git", ["-C", state.worktree_path, "cat-file", "-e", state.base_sha + ":" + path]);
    existedAtBase = true;
  } catch (_) {}
  if (!existedAtBase && newFileAllowlist.indexOf(path) === -1) {
    mismatches.push({ code: "new_path_not_explicitly_allowed", path });
  }
}
let discoveredTestCount;
if (state.contract.test_count) {
  let match;
  try {
    match = new RegExp(state.contract.test_count.pattern, "m").exec(tests);
  } catch (_) {
    error("test_count_extractor_invalid_regex", "test_count pattern is not a valid regular expression");
  }
  if (!match) error("test_count_extractor_no_match", "test_count pattern did not match discovery output");
  const captured = match[state.contract.test_count.group];
  if (captured === undefined) error("test_count_extractor_missing_capture", "test_count group was not captured");
  if (!/^[0-9]+$/.test(captured) || !Number.isSafeInteger(Number(captured))) {
    error("test_count_extractor_non_integer", "test_count capture is not a decimal integer");
  }
  discoveredTestCount = Number(captured);
  if (discoveredTestCount <= 0) error("test_count_extractor_non_positive", "test_count capture must be positive");
} else {
  discoveredTestCount = tests.split(/\r?\n/).filter((line) => line.length > 0).length;
}
if (discoveredTestCount !== state.acceptance.expected_test_count) {
  mismatches.push({ code: "unexpected_discovered_test_count", expected: state.acceptance.expected_test_count, actual: discoveredTestCount });
}
const seen = new Set();
for (const criterion of state.acceptance.criteria) {
  if (seen.has(criterion.id)) {
    mismatches.push({ code: "duplicate_acceptance_id", id: criterion.id });
  } else {
    seen.add(criterion.id);
    if (!discovered(criterion.id, tests)) mismatches.push({ code: "acceptance_not_discovered", id: criterion.id });
  }
}
process.stdout.write(JSON.stringify({
  status: mismatches.length ? "fail" : "pass",
  revision: state.revision,
  base_sha: state.base_sha,
  head_sha: headSha,
  changed_paths: changedPaths,
  discovered_test_count: discoveredTestCount,
  typecheck,
  compile_consumers: compileConsumers,
  review_obligations: reviewObligations,
  mismatches
}) + "\n");
process.exit(mismatches.length ? 1 : 0);
NODE
