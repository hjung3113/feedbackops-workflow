#!/usr/bin/env bash
# Contract smoke for legacy Codex provenance and runtime-neutral agent artifacts.
# bash-3.2-compatible. Run: bash scripts/__tests__/runtime-provenance-schema.smoke.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VALIDATOR="$ROOT/scripts/lib/json-schema-subset.cjs"

FAILURES=0
pass() { echo "ok   - $1"; }
fail() { echo "NOT OK - $1"; FAILURES=$((FAILURES + 1)); }

check_fixture() {
  schema_name="$1"
  fixture_name="$2"
  expected="$3"
  node - "$VALIDATOR" "$ROOT/schemas/$schema_name.schema.json" "$ROOT/schemas/fixtures/$fixture_name" "$expected" <<'NODE'
const fs = require("fs");
const { validate } = require(process.argv[2]);
const schema = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
const value = JSON.parse(fs.readFileSync(process.argv[4], "utf8"));
const expected = process.argv[5] === "valid";
process.exit((validate(schema, value).length === 0) === expected ? 0 : 1);
NODE
  if [ "$?" -eq 0 ]; then pass "$schema_name $fixture_name is $expected"; else fail "$schema_name $fixture_name is $expected"; fi
}

check_fixture run run.valid.json valid
check_fixture run run.invalid.json invalid
check_fixture run run.agent.valid.json valid
check_fixture run run.agent.invalid.json invalid
check_fixture pr_draft pr_draft.valid.json valid
check_fixture pr_draft pr_draft.runtime.valid.json valid
check_fixture pr_draft pr_draft.runtime.invalid.json invalid
check_fixture pr_draft pr_draft.worktree.invalid.json invalid
check_fixture blocker blocker.valid.json valid
check_fixture blocker blocker.runtime.valid.json valid
check_fixture blocker blocker.runtime.invalid.json invalid
check_fixture touch touch.valid.json valid
check_fixture touch touch.runtime.valid.json valid
check_fixture touch touch.runtime.invalid.json invalid
check_fixture transport_receipt transport_receipt.valid.json valid
check_fixture transport_receipt transport_receipt.runtime.valid.json valid
check_fixture transport_receipt transport_receipt.herdr.valid.json valid
check_fixture transport_receipt transport_receipt.runtime.invalid.json invalid
check_fixture transport_receipt transport_receipt.routing.valid.json valid
check_fixture transport_receipt transport_receipt.routing.invalid.json invalid
check_fixture transport_receipt transport_receipt.routing.legacy.invalid.json invalid

if [ "$FAILURES" -eq 0 ]; then
  echo "--- ALL CASES PASS"
  exit 0
fi
echo "--- $FAILURES CASE(S) FAILED"
exit 1
