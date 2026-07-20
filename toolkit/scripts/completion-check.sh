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

node - "$round_state" "$ROUND_STATE_SCHEMA" "$SCHEMA_VALIDATOR" "$expected_revision" <<'NODE'
const fs = require("fs");
const { execFileSync } = require("child_process");
const [roundStateFile, schemaFile, validatorFile, expectedRevision] = process.argv.slice(2);

function error(code, message) {
  process.stdout.write(JSON.stringify({ status: "error", mismatches: [{ code }], error: message }) + "\n");
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
  return value.length > 0
    && !value.startsWith("/")
    && !value.split("/").includes("..");
}

let state, schema;
try {
  state = JSON.parse(fs.readFileSync(roundStateFile, "utf8"));
  schema = JSON.parse(fs.readFileSync(schemaFile, "utf8"));
} catch (e) { error("invalid_round_state", "cannot parse ROUND-STATE or schema: " + e.message); }
let validate;
try { ({ validate } = require(validatorFile)); }
catch (e) { error("invalid_round_state", "cannot load schema validator: " + e.message); }
const schemaErrors = validate(schema, state);
if (schemaErrors.length) error("invalid_round_state", "ROUND-STATE schema validation failed");
if (state.lifecycle !== "active" && state.lifecycle !== "final") error("invalid_round_state", "ROUND-STATE lifecycle is not gateable");

const mismatches = [];
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
    cwd: state.worktree_path,
    encoding: "utf8"
  });
} catch (e) { error("test_discovery_failed", "target-native test discovery failed: " + e.message); }

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
}
const discoveredTestCount = tests.split(/\r?\n/).filter((line) => line.length > 0).length;
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
