"use strict";

const fs = require("fs");

function count(data, key) {
  const value = data && data[key];
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}

function sameJson(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function validGenericPassGroups(groups) {
  return Array.isArray(groups) && groups.length > 0 && groups.every((group) => group
    && group.required === true
    && Array.isArray(group.commands) && group.commands.length > 0
    && group.commands.every((command) => command && command.exit_code === 0)
    && (!Object.prototype.hasOwnProperty.call(group, "test_count")
      || (Number.isInteger(group.test_count) && group.test_count > 0)));
}

function validRun(run) {
  if (!run || typeof run !== "object" || Array.isArray(run)
      || (run.classifier !== "PASS" && run.classifier !== "FAIL")
      || !run.verdict || typeof run.verdict !== "object"
      || !Array.isArray(run.failures) || !run.verify_cmd || !run.created_at) return false;
  const passed = count(run.verdict, "passed");
  const failed = count(run.verdict, "failed");
  const exitCode = run.verdict.exit_code;
  if (!Number.isInteger(exitCode)) return false;
  if (run.classifier === "PASS") {
    const genericGroupsPass = !Object.prototype.hasOwnProperty.call(run, "groups")
      || validGenericPassGroups(run.groups);
    return passed >= 1 && failed === 0 && exitCode === 0 && run.failures.length === 0 && genericGroupsPass;
  }
  return failed > 0 || exitCode !== 0 || run.failures.length > 0;
}

function aggregateArtifact(current, runs) {
  const latest = runs[runs.length - 1];
  const allPass = runs.every((run) => run.classifier === "PASS");
  return {
    ...current,
    verify_cmd: latest.verify_cmd,
    clean_state: latest.clean_state,
    verdict: {
      passed: runs.reduce((total, run) => total + count(run.verdict, "passed"), 0),
      failed: runs.reduce((total, run) => total + count(run.verdict, "failed"), 0),
      pending: runs.reduce((total, run) => total + count(run.verdict, "pending"), 0),
      exit_code: allPass ? 0 : 1,
    },
    classifier: allPass ? "PASS" : "FAIL",
    failures: runs.reduce((all, run) => all.concat(run.failures), []),
    created_at: latest.created_at,
    runs,
  };
}

function validAggregate(artifact) {
  if (!Object.prototype.hasOwnProperty.call(artifact, "runs")) return true;
  if (!Array.isArray(artifact.runs) || artifact.runs.length === 0 || !artifact.runs.every(validRun)) return false;
  const latest = artifact.runs[artifact.runs.length - 1];
  if (artifact.target_profile && !artifact.runs.every((run) => Array.isArray(run.groups)
      && run.groups.length > 0
      && run.groups.every((group) => group.required === true && Array.isArray(group.commands) && group.commands.length > 0))) return false;
  const expected = aggregateArtifact({...artifact, runs: undefined}, artifact.runs);
  return artifact.verify_cmd === expected.verify_cmd
    && sameJson(artifact.clean_state, expected.clean_state)
    && sameJson(artifact.groups, latest.groups)
    && sameJson(artifact.verdict, expected.verdict)
    && artifact.classifier === expected.classifier
    && sameJson(artifact.failures, expected.failures)
    && artifact.created_at === expected.created_at;
}

function validArtifact(artifact) {
  const generic = Boolean(artifact && artifact.target_profile);
  const shapeValid = generic
    ? Array.isArray(artifact.groups) && artifact.groups.length > 0
      && artifact.groups.every((group) => group.required === true && Array.isArray(group.commands) && group.commands.length > 0)
    : Boolean(artifact && artifact.db_target && artifact.clean_state);
  return artifact
    && typeof artifact === "object"
    && (artifact.classifier === "PASS" || artifact.classifier === "FAIL")
    && Boolean(artifact.head_sha)
    && typeof artifact.content_sha256 === "string"
    && /^[0-9a-f]{64}$/.test(artifact.content_sha256)
    && artifact.verdict
    && typeof artifact.verdict === "object"
    && shapeValid
    && (!(generic && artifact.classifier === "PASS") || validGenericPassGroups(artifact.groups))
    && validAggregate(artifact);
}

function main(argv) {
  const artifact = JSON.parse(fs.readFileSync(argv[3], "utf8"));
  if (argv[2] === "validate-artifact") {
    const schema = JSON.parse(fs.readFileSync(argv[4], "utf8"));
    const { validate } = require(argv[5]);
    return validArtifact(artifact) && validate(schema, artifact).length === 0 ? 0 : 1;
  }
  if (argv[2] === "aggregate-exit-code") return !validArtifact(artifact) ? 2 : artifact.classifier === "PASS" ? 0 : 1;
  console.error("usage: verify-artifact.cjs validate-artifact <artifact-file> <schema> <validator> | aggregate-exit-code <artifact-file>");
  return 2;
}

module.exports = { aggregateArtifact, validArtifact };

if (require.main === module) {
  try { process.exitCode = main(process.argv); }
  catch (error) { console.error(`FAIL: ${error.message}`); process.exitCode = 1; }
}
