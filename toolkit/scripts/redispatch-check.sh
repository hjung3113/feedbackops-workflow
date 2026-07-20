#!/usr/bin/env bash
# redispatch-check.sh — derive implementation redispatch admission from the
# canonical ROUND-STATE failure history. This is correctness policy, not
# watchdog retry/liveness policy.
#
# Usage: scripts/redispatch-check.sh --round-state <json-file> --manifest-revision <n>
#
# Exit 0 = one declared dispatch mode is allowed; 1 = policy denial;
# exit 2 = malformed, stale, or uncheckable input.
set -u

PROG="redispatch-check"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PRODUCT_HOME_LIB="$SCRIPT_DIR/lib/product-home.sh"
SCHEMA_VALIDATOR="$SCRIPT_DIR/lib/json-schema-subset.cjs"
FRESH_CHECK="$SCRIPT_DIR/artifact-fresh.sh"
round_state=""
expected_revision=""

emit_error() {
  code="$1"
  printf '{"decision":"error","redispatch_allowed":false,"dispatch_mode":null,"same_origin_streak":0,"redispatches_completed":0,"trigger":null,"obligations":[],"errors":[{"code":"%s"}]}' "$code"
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
const [roundStateFile, schemaFile, validatorFile, expectedRevision] = process.argv.slice(2);

function write(payload, exitCode) {
  process.stdout.write(JSON.stringify(payload) + "\n");
  process.exit(exitCode);
}
function error(code, message, exitCode = 2) {
  write({
    decision: "error",
    redispatch_allowed: false,
    dispatch_mode: null,
    same_origin_streak: 0,
    redispatches_completed: 0,
    trigger: null,
    obligations: [],
    errors: [{ code }],
    error: message
  }, exitCode);
}
function sameMembers(left, right) {
  if (left.length !== right.length) return false;
  const expected = new Set(right);
  return left.every((value) => expected.has(value));
}

let state, schema, validate;
try {
  state = JSON.parse(fs.readFileSync(roundStateFile, "utf8"));
  schema = JSON.parse(fs.readFileSync(schemaFile, "utf8"));
  ({ validate } = require(validatorFile));
} catch (e) {
  error("invalid_round_state", "cannot parse ROUND-STATE or schema: " + e.message);
}
const schemaErrors = validate(schema, state);
if (schemaErrors.length) error("invalid_round_state", "ROUND-STATE schema validation failed");
if (state.lifecycle !== "active" && state.lifecycle !== "final") {
  error("invalid_round_state", "ROUND-STATE lifecycle is not gateable");
}
if (String(state.revision) !== expectedRevision) {
  error("stale_manifest_revision", "expected revision does not match ROUND-STATE", 1);
}

const control = state.round_control || { failures: [] };
const failures = control.failures;
const ids = new Set();
for (let index = 0; index < failures.length; index += 1) {
  const failure = failures[index];
  if (ids.has(failure.id) || failure.dispatch_ordinal !== index + 1) {
    error("invalid_failure_sequence", "failure ids must be unique and dispatch ordinals contiguous");
  }
  ids.add(failure.id);
  if (failure.secondary_origins.includes(failure.primary_origin)) {
    error("secondary_origin_conflict", "primary origin cannot also be secondary");
  }
}

let sameOriginStreak = 0;
if (failures.length > 0) {
  const latestOrigin = failures[failures.length - 1].primary_origin;
  for (let index = failures.length - 1; index >= 0; index -= 1) {
    if (failures[index].primary_origin !== latestOrigin) break;
    sameOriginStreak += 1;
  }
}
const redispatchesCompleted = Math.max(0, failures.length - 1);

function decision(name, allowed, mode, trigger, obligations, exitCode) {
  write({
    decision: name,
    redispatch_allowed: allowed,
    dispatch_mode: mode,
    same_origin_streak: sameOriginStreak,
    redispatches_completed: redispatchesCompleted,
    trigger,
    obligations,
    errors: []
  }, exitCode);
}

if (control.security_stop && control.security_stop.active) {
  decision("security_stop", false, null, "security", [], 1);
}

let trigger = null;
if (sameOriginStreak >= 2) trigger = "same_origin";
else if (redispatchesCompleted >= 2) trigger = "third_redispatch";

if (!trigger) {
  decision("allow_normal", true, "normal", null, [], 0);
}

const diagnosis = control.diagnosis;
const requiredKinds = ["oracle_contract_recheck", "hard_fact", "passing_analog"];
if (!diagnosis) {
  decision("diagnosis_required", false, null, trigger,
    ["oracle_contract_recheck", "hard_fact", "passing_analog_parity", "integrated_fix_batch"], 1);
}
if (diagnosis.trigger !== trigger) {
  error("diagnosis_trigger_mismatch", "diagnosis trigger does not match calculated breaker trigger");
}
const openFailureIds = failures.filter((failure) => failure.status === "open").map((failure) => failure.id);
if (!sameMembers(diagnosis.failure_ids, openFailureIds)) {
  error("diagnosis_failure_set_mismatch", "diagnosis must cover every open failure exactly once");
}
if (diagnosis.records.length > requiredKinds.length) {
  error("diagnosis_order_violation", "diagnosis contains extra records");
}
for (let index = 0; index < diagnosis.records.length; index += 1) {
  if (diagnosis.records[index].kind !== requiredKinds[index]) {
    error("diagnosis_order_violation", "oracle/contract, hard fact, and passing analog must be recorded in order");
  }
}
const passingAnalog = diagnosis.records[2];
if (passingAnalog && passingAnalog.instruction !== "guess_forbidden_copy_passing_analog_to_parity") {
  error("diagnosis_order_violation", "passing analog must pin the guess-forbidden parity instruction");
}
if (diagnosis.manifest_update
    && diagnosis.manifest_update.to_revision !== diagnosis.manifest_update.from_revision + 1) {
  error("manifest_update_count_invalid", "a diagnosis cycle permits at most one manifest revision increment");
}
if (diagnosis.records.length < requiredKinds.length) {
  const missing = requiredKinds.slice(diagnosis.records.length)
    .map((kind) => kind === "passing_analog" ? "passing_analog_parity" : kind);
  missing.push("integrated_fix_batch");
  decision("diagnosis_required", false, null, trigger, missing, 1);
}

const batch = diagnosis.integrated_fix_batch;
if (!batch) {
  decision("diagnosis_required", false, null, trigger, ["integrated_fix_batch"], 1);
}
if (batch.dispatch_ordinal !== failures.length + 1
    || !sameMembers(batch.failure_ids, diagnosis.failure_ids)) {
  error("invalid_integrated_fix_batch", "integrated fix batch must be the next dispatch and cover the diagnosed failures");
}
if (batch.status === "used") {
  decision("diagnosis_exhausted", false, null, trigger, ["blocker_or_new_decision"], 1);
}
decision("allow_integrated_fix", true, "integrated_fix", trigger, [], 0);
NODE
