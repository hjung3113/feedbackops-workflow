"use strict";

const fs = require("fs");

function count(data, key) {
  const value = data && data[key];
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}

function readReport(reportPath) {
  let raw;
  try {
    raw = fs.readFileSync(reportPath, "utf8");
  } catch (error) {
    throw new Error(`cannot read report: ${error.message} (fail closed)`);
  }

  let data;
  try {
    data = JSON.parse(raw);
  } catch (error) {
    throw new Error(`report is not parseable JSON (fail closed): ${error.message}`);
  }
  if (data === null || typeof data !== "object" || Array.isArray(data)) {
    throw new Error("report JSON is not an object (fail closed)");
  }
  return data;
}

function classify(data, vitestExitCode) {
  const passed = count(data, "numPassedTests");
  const failed = count(data, "numFailedTests");
  const pending = count(data, "numPendingTests");
  const failedSuites = count(data, "numFailedTestSuites");
  const results = Array.isArray(data.testResults) ? data.testResults : [];
  const reasons = [];

  if (vitestExitCode !== 0) {
    reasons.push(`vitest exited non-zero (${vitestExitCode}) — run crashed; JSON may be stale/partial`);
  }
  if (passed + failed === 0) {
    reasons.push(`no executable tests ran (passed+failed==0); ${pending} pending — suite fully skipped or filter matched nothing; if integration, check DATABASE_URL/WORKSPACE_ID`);
  }
  if (failed > 0) reasons.push(`${failed} failed test(s)`);
  if (failedSuites > 0) {
    reasons.push(`${failedSuites} failed test suite(s) (setup/import failure)`);
  }
  if (data.success === false) reasons.push("top-level success===false (vitest overall verdict)");

  const failedResults = results.filter((result) => result && result.status === "failed").length;
  if (failedResults > 0) reasons.push(`${failedResults} failed testResults entr(y/ies)`);

  return { passed, failed, pending, reasons };
}

function buildArtifact(data, env) {
  const artifact = {
    schema_version: "1",
    artifact_type: "verify_result",
    producer_role: "VERIFIER",
    issue: Number.parseInt(env.VERIFY_ARTIFACT_ISSUE, 10),
    branch: env.VERIFY_ARTIFACT_BRANCH || "",
    head_sha: env.VERIFY_ARTIFACT_HEAD_SHA || "",
    cwd: env.VERIFY_ARTIFACT_CWD || "",
    verify_cmd: env.VERIFY_ARTIFACT_CMD || "",
    env_profile: "scrubbed",
    db_target: {
      host: env.VERIFY_ARTIFACT_DB_HOST || "",
      database: env.VERIFY_ARTIFACT_DB_DATABASE || "",
      role: env.VERIFY_ARTIFACT_DB_ROLE || "",
    },
    verdict: {
      passed: count(data, "numPassedTests"),
      failed: count(data, "numFailedTests"),
      pending: count(data, "numPendingTests"),
      exit_code: Number.parseInt(env.VERIFY_ARTIFACT_EXIT_CODE, 10) || 0,
    },
    classifier: env.VERIFY_ARTIFACT_CLASSIFIER === "PASS" ? "PASS" : "FAIL",
    created_at: env.VERIFY_ARTIFACT_CREATED_AT || "",
  };
  if (env.CODEX_VERSION) artifact.producer_version = `codex/${env.CODEX_VERSION}`;
  return artifact;
}

function validArtifact(artifact) {
  return artifact
    && typeof artifact === "object"
    && (artifact.classifier === "PASS" || artifact.classifier === "FAIL")
    && Boolean(artifact.head_sha)
    && artifact.verdict
    && typeof artifact.verdict === "object";
}

function main(argv, env) {
  const command = argv[2];
  if (command === "classify") {
    const reportPath = argv[3];
    const parsedExitCode = Number.parseInt(argv[4], 10);
    const vitestExitCode = Number.isNaN(parsedExitCode) ? 0 : parsedExitCode;
    const result = classify(readReport(reportPath), vitestExitCode);
    if (result.reasons.length > 0) {
      console.error(`FAIL: ${result.reasons.join("; ")}`);
      return 1;
    }
    console.log(`PASS: ${result.passed} passed, ${result.pending} pending, 0 failed`);
    return 0;
  }

  if (command === "write-artifact") {
    let data = {};
    try {
      data = readReport(env.VERIFY_ARTIFACT_REPORT);
    } catch (_) {
      data = {};
    }
    const artifact = buildArtifact(data, env);
    fs.writeFileSync(env.VERIFY_ARTIFACT_PATH, `${JSON.stringify(artifact, null, 2)}\n`);
    return 0;
  }

  if (command === "validate-artifact") {
    const artifact = JSON.parse(fs.readFileSync(argv[3], "utf8"));
    return validArtifact(artifact) ? 0 : 1;
  }

  console.error("usage: verify-result.cjs classify <report-file> <vitest-exit-code> | write-artifact | validate-artifact <artifact-file>");
  return 2;
}

try {
  process.exitCode = main(process.argv, process.env);
} catch (error) {
  console.error(`FAIL: ${error.message}`);
  process.exitCode = 1;
}
