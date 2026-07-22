#!/usr/bin/env bash
# prompt-ac-check.sh — require a prompt's delimited AC block to exactly copy
# the canonical ROUND-STATE acceptance criteria.
#
# Usage: scripts/prompt-ac-check.sh --round-state <json-file> \
#   --manifest-revision <n> --prompt-file <markdown-file> [--output-contract-role ROLE]
#
# Exit 0 = exact match; 1 = prompt block is missing/malformed/mismatched;
# 2 = usage or canonical input error. Bash-3.2-compatible.
set -u

PROG="prompt-ac-check"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PRODUCT_HOME_LIB="$SCRIPT_DIR/lib/product-home.sh"
SCHEMA_VALIDATOR="$SCRIPT_DIR/lib/json-schema-subset.cjs"
round_state=""
expected_revision=""
prompt_file=""
output_contract_role=""

usage() {
  echo "usage: $0 --round-state <json-file> --manifest-revision <n> --prompt-file <markdown-file>" >&2
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

while [ "$#" -gt 0 ]; do
  case "$1" in
    --round-state) round_state="${2:-}"; shift 2 ;;
    --manifest-revision) expected_revision="${2:-}"; shift 2 ;;
    --prompt-file) prompt_file="${2:-}"; shift 2 ;;
    --output-contract-role) output_contract_role="${2:-}"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

if [ -z "$round_state" ] || [ -z "$expected_revision" ] || [ -z "$prompt_file" ]; then
  usage
  exit 2
fi
case "$expected_revision" in
  ''|*[!0-9]*|0) echo "$PROG: ERROR — --manifest-revision requires a positive integer" >&2; exit 2 ;;
esac
for required_file in "$round_state" "$prompt_file" "$ROUND_STATE_SCHEMA" "$SCHEMA_VALIDATOR"; do
  if [ ! -f "$required_file" ] || [ ! -r "$required_file" ]; then
    echo "$PROG: ERROR — required input is missing or unreadable: $required_file" >&2
    exit 2
  fi
done

if [ -n "$output_contract_role" ]; then
  if ! "$SCRIPT_DIR/output-contract.sh" check --role "$output_contract_role" --prompt-file "$prompt_file"; then
    echo "$PROG: output contract is missing or drifted" >&2
    exit 1
  fi
fi

node - "$round_state" "$ROUND_STATE_SCHEMA" "$SCHEMA_VALIDATOR" "$expected_revision" "$prompt_file" <<'NODE'
const fs = require("fs");
const [stateFile, schemaFile, validatorFile, expectedRevision, promptFile] = process.argv.slice(2);
const START = "<!-- agent-workflow:ac-block:start -->";
const END = "<!-- agent-workflow:ac-block:end -->";
function result(code, message) {
  process.stdout.write(code + " " + message + "\n");
  process.exit(code.indexOf("MALFORMED") !== -1 ? 1 : 1);
}
let state, schema, prompt, validate;
try {
  state = JSON.parse(fs.readFileSync(stateFile, "utf8"));
  schema = JSON.parse(fs.readFileSync(schemaFile, "utf8"));
  prompt = fs.readFileSync(promptFile, "utf8");
  ({ validate } = require(validatorFile));
} catch (error) {
  console.error("cannot read canonical input: " + error.message);
  process.exit(2);
}
if (validate(schema, state).length) {
  console.error("ROUND-STATE schema validation failed");
  process.exit(2);
}
if ((state.lifecycle !== "active" && state.lifecycle !== "final") || String(state.revision) !== expectedRevision) {
  console.error("ROUND-STATE lifecycle or revision is not gateable");
  process.exit(2);
}
const criteria = state.acceptance && state.acceptance.criteria;
if (!Array.isArray(criteria) || !criteria.length) {
  console.error("ROUND-STATE acceptance criteria are missing");
  process.exit(2);
}
const canonicalIds = new Set();
for (const criterion of criteria) {
  if (!criterion || Array.isArray(criterion) || Object.keys(criterion).length !== 2 ||
      typeof criterion.id !== "string" || !criterion.id || /[\r\n]/.test(criterion.id) ||
      typeof criterion.statement !== "string" || !criterion.statement || canonicalIds.has(criterion.id)) {
    console.error("ROUND-STATE acceptance criteria must contain unique id and statement pairs only");
    process.exit(2);
  }
  canonicalIds.add(criterion.id);
}
const starts = prompt.split(START).length - 1;
const ends = prompt.split(END).length - 1;
if (starts !== 1 || ends !== 1) result("PROMPT_AC_MALFORMED", "expected exactly one delimited AC block");
const startAt = prompt.indexOf(START) + START.length;
const endAt = prompt.indexOf(END);
if (endAt < startAt) result("PROMPT_AC_MALFORMED", "AC block delimiters are out of order");
const body = prompt.slice(startAt, endAt).trim();
const fence = body.match(/^```json\s*\n([\s\S]*?)\n```$/);
if (!fence) result("PROMPT_AC_MALFORMED", "AC block must be one fenced JSON array");
let supplied;
try { supplied = JSON.parse(fence[1]); }
catch (error) { result("PROMPT_AC_MALFORMED", "AC block JSON is invalid"); }
if (!Array.isArray(supplied)) result("PROMPT_AC_MALFORMED", "AC block must be a JSON array");
const suppliedIds = new Set();
for (const criterion of supplied) {
  if (!criterion || Array.isArray(criterion) || Object.keys(criterion).length !== 2 ||
      typeof criterion.id !== "string" || !criterion.id || /[\r\n]/.test(criterion.id) ||
      typeof criterion.statement !== "string" || !criterion.statement || suppliedIds.has(criterion.id)) {
    result("PROMPT_AC_MALFORMED", "AC entries must contain unique id and statement pairs only");
  }
  suppliedIds.add(criterion.id);
}
if (supplied.length !== criteria.length || supplied.some((criterion, index) =>
  criterion.id !== criteria[index].id || criterion.statement !== criteria[index].statement)) {
  result("PROMPT_AC_MISMATCH", "prompt AC block must exactly copy canonical ROUND-STATE criteria");
}
process.stdout.write("OK revision " + state.revision + ": prompt AC block matches canonical ROUND-STATE\n");
NODE
