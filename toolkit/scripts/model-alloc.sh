#!/usr/bin/env bash
# Emit a deterministic, project-configurable allocation. This does not dispatch.
# Bash 3.2 compatible; Node performs JSON parsing/validation only.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROLE=""
CONFIG=""
EVIDENCE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --role) ROLE="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --evidence) EVIDENCE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$ROLE" ] || { echo "ERROR: --role implementation|reviewer is required" >&2; exit 2; }
case "$ROLE" in implementation|reviewer) ;; *) echo "ERROR: unsupported role: $ROLE" >&2; exit 2 ;; esac
[ -n "$CONFIG" ] || CONFIG="${AGENT_WORKFLOW_MODEL_ALLOC:-$SCRIPT_DIR/../model-alloc.json}"

node - "$CONFIG" "$EVIDENCE" "$ROLE" <<'NODE'
const fs = require("fs");
const [configFile, evidenceFile, role] = process.argv.slice(2);
function fail(message) { console.error(`ERROR: ${message}`); process.exit(2); }
function readJson(file, label) { try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch (_) { fail(`${label} is malformed or unreadable: ${file}`); } }
const config = readJson(configFile, "model allocation config");
const requiredRoles = ["implementation", "reviewer", "contract_gate", "trivial_implementation"];
if (config.schema_version !== "1" || typeof config.source !== "string" || typeof config.release !== "string" || !config.roles || !config.capabilities || !config.signals || requiredRoles.some(key => !config.roles[key])) fail("model allocation config does not satisfy schema version 1");
for (const key of requiredRoles) { const value = config.roles[key]; if (!value || typeof value.model !== "string" || !["low", "medium", "high"].includes(value.effort) || !config.capabilities[value.model] || !Number.isFinite(config.capabilities[value.model].review_capability)) fail(`invalid role allocation: ${key}`); }
const clone = key => ({ model: config.roles[key].model, effort: config.roles[key].effort });
let impl = clone("implementation"), review = clone("reviewer"), contract = clone("contract_gate");
const rationale = [`config:${config.source}@${config.release}`, `role:${role}`];
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
  if (contractTouch) { impl.effort = "medium"; rationale.push("exported_contract: implementation promoted; sol contract gate selected"); }
  else if (evidence.changed_lines <= config.signals.trivial_changed_lines && evidence.file_count <= 1) { impl = clone("trivial_implementation"); rationale.push("small_touch_set: trivial implementation allocation"); }
  else if (large) { impl.effort = "high"; rationale.push("large_touch_set: implementation effort promoted"); }
  if (evidence.blocker || findingRounds.length >= 2) {
    if (impl.effort === "low") impl.effort = "medium";
    rationale.push("blocker_or_consecutive_finding_rounds: implementation promoted without demotion");
  }
  if (evidence.review_round > 0) { review.effort = review.effort === "high" ? "medium" : "low"; rationale.push("rereview: review effort demoted"); }
}
const output = { impl_model: impl.model, impl_effort: impl.effort, review_model: review.model, review_effort: review.effort, contract_model: contract.model, contract_effort: contract.effort, rationale };
const reviewCapability = config.capabilities[review.model].review_capability;
const implCapability = config.capabilities[impl.model].review_capability;
if (reviewCapability < implCapability) {
  if (config.allow_review_below_implementation === true) output.rationale.push("warning: project explicitly relaxed review capability preference");
  else fail("default review capability preference is violated by project config");
}
process.stdout.write(JSON.stringify(output) + "\n");
NODE
