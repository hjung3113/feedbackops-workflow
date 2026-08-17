#!/usr/bin/env bash
# Emit a deterministic, project-configurable allocation. This does not dispatch.
# Bash 3.2 compatible; Node performs JSON parsing/validation only.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROLE=""
CONFIG=""
EVIDENCE=""
RUNNER="codex"

while [ $# -gt 0 ]; do
  case "$1" in
    --role) ROLE="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --evidence) EVIDENCE="$2"; shift 2 ;;
    --runner) RUNNER="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$ROLE" ] || { echo "ERROR: --role implementation|reviewer is required" >&2; exit 2; }
case "$ROLE" in implementation|reviewer) ;; *) echo "ERROR: unsupported role: $ROLE" >&2; exit 2 ;; esac
[ -n "$CONFIG" ] || CONFIG="${AGENT_WORKFLOW_MODEL_ALLOC:-$SCRIPT_DIR/../model-alloc.json}"

node - "$CONFIG" "$EVIDENCE" "$ROLE" "$SCRIPT_DIR/../schemas/model_alloc.schema.json" "$SCRIPT_DIR/lib/json-schema-subset.cjs" "$RUNNER" <<'NODE'
const fs = require("fs");
const [configFile, evidenceFile, role, schemaFile, validatorFile, runner] = process.argv.slice(2);
function fail(message) { console.error(`ERROR: ${message}`); process.exit(2); }
function readJson(file, label) { try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch (_) { fail(`${label} is malformed or unreadable: ${file}`); } }
const config = readJson(configFile, "model allocation config");
const schema = readJson(schemaFile, "model allocation schema");
let validate;
try { ({ validate } = require(validatorFile)); } catch (_) { fail(`model allocation validator is unreadable: ${validatorFile}`); }
if (validate(schema, config).length) fail("model allocation config does not satisfy schema version 1");
// Legacy-compat shim: `available_via` was added after schema v1 had already
// been installed into targets.  Preserve those valid v1 configs by deriving
// only well-known provider ownership via model-name prefix; unknown legacy
// names fail closed and ask for migration.  runtime-registry.cjs carries no
// model-to-runtime ownership mapping, so this inference stays here rather
// than re-hardcoding per call sites (ADR 0006): current configs declare
// `available_via` explicitly and never reach this path.
function legacyAvailability(model) {
  if (/^(gpt-|o[0-9])/.test(model)) return ["codex"];
  if (/^(opus-|sonnet-|haiku-)/.test(model)) return ["claude"];
  return null;
}
for (const [model, capability] of Object.entries(config.capabilities)) {
  if (!capability.available_via) {
    const inferred = legacyAvailability(model);
    if (!inferred) fail(`legacy model ${model} needs available_via migration`);
    capability.available_via = inferred;
  }
}
const requiredRoles = ["implementation", "reviewer", "contract_gate", "trivial_implementation"];
for (const key of requiredRoles) { const value = config.roles[key]; if (!value || !config.capabilities[value.model]) fail(`invalid role allocation: ${key}`); }
const clone = key => ({ model: config.roles[key].model, effort: config.roles[key].effort });
const promote = (allocation, effort) => {
  const rank = { none: 0, low: 1, medium: 2, high: 3, xhigh: 4, max: 5 };
  if (rank[allocation.effort] < rank[effort]) allocation.effort = effort;
};
const stepDown = allocation => {
  allocation.effort = { none: "none", low: "low", medium: "low", high: "medium", xhigh: "high", max: "xhigh" }[allocation.effort];
};
const defaultReview = clone("reviewer");
const runtimeReview = role === "reviewer" && config.reviewer_by_runtime && config.reviewer_by_runtime[runner];
if (role === "reviewer" && runner !== "codex" && !runtimeReview) fail(`reviewer allocation is not configured for ${runner}; set reviewer_by_runtime.${runner} to a preflightable model`);
const runtimeImpl = config.implementation_by_runtime && config.implementation_by_runtime[runner];
let impl = runtimeImpl ? { model: runtimeImpl.model, effort: runtimeImpl.effort } : clone("implementation"), review = runtimeReview ? { model: runtimeReview.model, effort: runtimeReview.effort } : defaultReview, contract = clone("contract_gate");
const rationale = [`config:${config.source}@${config.release}`, `role:${role}`];
if (runtimeReview) rationale.push(`runtime_reviewer:${runner}`);
if (runtimeImpl) rationale.push(`runtime_implementation:${runner}`);
if (!evidenceFile) {
  rationale.push("no_canonical_evidence: default allocation retained");
} else {
  const evidence = readJson(evidenceFile, "canonical allocation evidence");
  const numeric = ["changed_lines", "file_count", "review_round"];
  const findingRounds = evidence && evidence.consecutive_finding_rounds;
  const distinctConsecutive = Array.isArray(findingRounds) && findingRounds.every(round => Number.isInteger(round) && round > 0) && new Set(findingRounds).size === findingRounds.length && findingRounds.every((round, index) => index === 0 || round === findingRounds[index - 1] + 1) && (findingRounds.length === 0 || findingRounds[findingRounds.length - 1] === evidence.review_round);
  if (!evidence || numeric.some(key => !Number.isInteger(evidence[key]) || evidence[key] < 0) || !distinctConsecutive || typeof evidence.blocker !== "boolean" || !Array.isArray(evidence.touch_set) || evidence.touch_set.some(path => typeof path !== "string")) fail("canonical allocation evidence is incomplete");
  const contractTouch = evidence.touch_set.some(path => path === "packages/shared" || path.indexOf("packages/shared/") === 0 || /(^|\/)shared\//.test(path) || /contract/i.test(path));
  const large = evidence.changed_lines > config.signals.large_changed_lines || evidence.file_count > config.signals.large_file_count;
  if (contractTouch) { promote(impl, "medium"); rationale.push("exported_contract: implementation promoted; sol contract gate selected"); }
  else if (!runtimeImpl && evidence.changed_lines <= config.signals.trivial_changed_lines && evidence.file_count <= 1) { impl = clone("trivial_implementation"); rationale.push("small_touch_set: trivial implementation allocation"); }
  else if (large) { promote(impl, "high"); rationale.push("large_touch_set: implementation effort promoted"); }
  if (evidence.blocker || findingRounds.length >= 2) {
    promote(impl, "medium");
    rationale.push("blocker_or_consecutive_finding_rounds: implementation promoted without demotion");
  }
  if (evidence.review_round > 0) { stepDown(review); rationale.push("rereview: review effort stepped down one level"); }
}
const output = { impl_model: impl.model, impl_effort: impl.effort, review_model: review.model, review_effort: review.effort, contract_model: contract.model, contract_effort: contract.effort, rationale };
// Evidence adaptation can replace the configured implementation allocation
// (for example with trivial_implementation). Revalidate the final tuple, not
// merely the pre-adaptation role entry, before it reaches dispatch.
const finalSeat = role === "reviewer" ? review : impl;
const seatOverride = role === "reviewer" ? runtimeReview : runtimeImpl;
if (!seatOverride && (!config.capabilities[finalSeat.model] || !config.capabilities[finalSeat.model].available_via.includes(runner))) {
  fail(`final model ${finalSeat.model} is unavailable via ${runner} for role ${role}`);
}
const reviewScore = config.capabilities[defaultReview.model].static_coding + config.capabilities[defaultReview.model].reasoning;
const implScore = config.capabilities[impl.model].static_coding + config.capabilities[impl.model].reasoning;
if (reviewScore < implScore) {
  if (config.allow_review_below_implementation === true) output.rationale.push("warning: project explicitly relaxed review capability preference");
  else fail("default review capability preference is violated by project config");
}
process.stdout.write(JSON.stringify(output) + "\n");
NODE
