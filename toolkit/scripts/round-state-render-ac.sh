#!/usr/bin/env bash
# round-state-render-ac.sh — single-source renderer for the delimited AC
# block that prompt-ac-check.sh requires verbatim in a prompt file. Reads
# acceptance.criteria from the given ROUND-STATE, validates the file against
# schemas/round_state.schema.json, and prints the block to stdout:
#
#   <!-- agent-workflow:ac-block:start -->
#   ```json
#   [{"id": "...", "statement": "..."} ...]
#   ```
#   <!-- agent-workflow:ac-block:end -->
#
# Each object carries exactly `id` then `statement` (in that key order),
# matching the criteria array order. Pipe or splice the output into
# ISSUE-N-PROMPT.md; this script never edits prompt files in place.
#
# Usage: round-state-render-ac.sh --round-state <json-file>
#
# Exit 0 = block printed; 1 = ROUND-STATE failed schema or criteria checks;
# 2 = usage or unreadable input. Bash-3.2-compatible.
set -u

PROG="round-state-render-ac"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PRODUCT_HOME_LIB="$SCRIPT_DIR/lib/product-home.sh"
CONTRACT_VALIDATORS="$SCRIPT_DIR/lib/contract-validators.cjs"
round_state=""

usage() {
  echo "usage: $0 --round-state <json-file>" >&2
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
    *) usage; exit 2 ;;
  esac
done

if [ -z "$round_state" ]; then
  usage
  exit 2
fi
for required_file in "$round_state" "$ROUND_STATE_SCHEMA" "$CONTRACT_VALIDATORS"; do
  if [ ! -f "$required_file" ] || [ ! -r "$required_file" ]; then
    echo "$PROG: ERROR — required input is missing or unreadable: $required_file" >&2
    exit 2
  fi
done

exec node - "$round_state" "$CONTRACT_VALIDATORS" <<'NODE'
const fs = require("fs");
const PROG_LITERAL = "round-state-render-ac:";
const [stateFile, contractValidatorsFile] = process.argv.slice(2);
const START = "<!-- agent-workflow:ac-block:start -->";
const END = "<!-- agent-workflow:ac-block:end -->";
let state;
try {
  state = JSON.parse(fs.readFileSync(stateFile, "utf8"));
} catch (error) {
  console.error(PROG_LITERAL + " cannot parse ROUND-STATE: " + error.message);
  process.exit(1);
}
const { schema, validate } = require(contractValidatorsFile).loadSchema("round_state.schema.json");
const schemaErrors = validate(schema, state);
if (schemaErrors.length) {
  console.error(PROG_LITERAL + " ROUND-STATE schema validation failed: " + JSON.stringify(schemaErrors));
  process.exit(1);
}
const criteria = state.acceptance && state.acceptance.criteria;
if (!Array.isArray(criteria) || !criteria.length) {
  console.error(PROG_LITERAL + " acceptance.criteria is missing or empty");
  process.exit(1);
}
const seen = new Set();
for (const criterion of criteria) {
  if (!criterion || Array.isArray(criterion) || Object.keys(criterion).length !== 2 ||
      typeof criterion.id !== "string" || !criterion.id || /[\r\n]/.test(criterion.id) ||
      typeof criterion.statement !== "string" || !criterion.statement || seen.has(criterion.id)) {
    console.error(PROG_LITERAL + " acceptance.criteria must contain unique non-empty id and statement pairs only");
    process.exit(1);
  }
  seen.add(criterion.id);
}
const rendered = criteria.map((criterion) => ({ id: criterion.id, statement: criterion.statement }));
process.stdout.write(
  START + "\n```json\n" + JSON.stringify(rendered, null, 2) + "\n```\n" + END + "\n"
);
NODE
