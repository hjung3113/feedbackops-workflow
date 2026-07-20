"use strict";

const fs = require("fs");

function count(data, key) {
  const value = data && data[key];
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}

function readReport(reportPath) {
  if (!fs.existsSync(reportPath)) {
    const error = new Error(`report file not found: ${reportPath} (fail closed — never trust an absent report)`);
    error.failureCode = "invalid_report";
    error.actual = "missing";
    throw error;
  }
  if (fs.statSync(reportPath).size === 0) {
    const error = new Error(`report file is empty: ${reportPath} (fail closed)`);
    error.failureCode = "invalid_report";
    error.actual = "empty";
    throw error;
  }
  let raw;
  try {
    raw = fs.readFileSync(reportPath, "utf8");
  } catch (error) {
    const wrapped = new Error(`cannot read report: ${error.message} (fail closed)`);
    wrapped.failureCode = "invalid_report";
    wrapped.actual = "unreadable";
    throw wrapped;
  }

  let data;
  try {
    data = JSON.parse(raw);
  } catch (error) {
    const wrapped = new Error(`report is not parseable JSON (fail closed): ${error.message}`);
    wrapped.failureCode = "invalid_report";
    wrapped.actual = "unparseable";
    throw wrapped;
  }
  if (data === null || typeof data !== "object") {
    const error = new Error("report JSON is not an object (fail closed)");
    error.failureCode = "invalid_report";
    error.actual = data === null ? "null" : typeof data;
    throw error;
  }
  return data;
}

function classify(data, vitestExitCode) {
  const passed = count(data, "numPassedTests");
  const failed = count(data, "numFailedTests");
  const pending = count(data, "numPendingTests");
  const failedSuites = count(data, "numFailedTestSuites");
  const results = Array.isArray(data.testResults) ? data.testResults : [];
  const failures = [];

  function fail(code, expected, actual, message) {
    failures.push({ code, expected: String(expected), actual: String(actual), message });
  }

  if (vitestExitCode !== 0) {
    fail("vitest_exit", 0, vitestExitCode, `vitest exited non-zero (${vitestExitCode}) — run crashed; JSON may be stale/partial`);
  }
  if (passed + failed === 0) {
    fail("no_executable_tests", "passed+failed>0", 0, `no executable tests ran (passed+failed==0); ${pending} pending — suite fully skipped or filter matched nothing; if integration, check DATABASE_URL/WORKSPACE_ID`);
  }
  if (failed > 0) fail("failed_tests", 0, failed, `${failed} failed test(s)`);
  if (failedSuites > 0) {
    fail("failed_suites", 0, failedSuites, `${failedSuites} failed test suite(s) (setup/import failure)`);
  }
  if (data.success === false) fail("overall_success", true, false, "top-level success===false (vitest overall verdict)");

  const failedResults = results.filter((result) => result && result.status === "failed").length;
  if (failedResults > 0) fail("failed_results", 0, failedResults, `${failedResults} failed testResults entr(y/ies)`);

  return { passed, failed, pending, failures };
}

function publicFailures(failures) {
  return failures.map(({ code, expected, actual }) => ({ code, expected, actual }));
}

function reportFailure(error) {
  return {
    code: error.failureCode || "invalid_report",
    expected: "parseable JSON object",
    actual: error.actual || "unreadable",
  };
}

function projectCleanState(clean) {
  const byCode = Object.fromEntries(clean.checks.map((check) => [check.code, check]));
  const project = (check) => ({ expected: check.expected, actual: check.actual });
  return {
    sentinel: project(byCode.sentinel),
    migration_hash: project(byCode.migration_hash),
    role: { name: clean.role.name, superuser: clean.role.superuser },
  };
}

function buildArtifact(data, env, reportReadFailure) {
  const parsedExitCode = Number.parseInt(env.VERIFY_ARTIFACT_EXIT_CODE, 10) || 0;
  const classification = reportReadFailure
    ? { failures: [reportReadFailure] }
    : classify(data, parsedExitCode);
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
      exit_code: parsedExitCode,
    },
    classifier: env.VERIFY_ARTIFACT_CLASSIFIER === "PASS" ? "PASS" : "FAIL",
    failures: publicFailures(classification.failures),
    created_at: env.VERIFY_ARTIFACT_CREATED_AT || "",
  };
  if (env.CODEX_VERSION) artifact.producer_version = `codex/${env.CODEX_VERSION}`;
  if (env.VERIFY_ARTIFACT_CLEAN_RESULT) {
    const clean = JSON.parse(fs.readFileSync(env.VERIFY_ARTIFACT_CLEAN_RESULT, "utf8"));
    artifact.clean_state = projectCleanState(clean);
  }
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
    let data;
    try {
      data = readReport(reportPath);
    } catch (error) {
      const failure = reportFailure(error);
      console.error(`FAIL: ${error.message}`);
      console.error(`VERIFY_FAILURE_JSON=${JSON.stringify({ failures: [failure] })}`);
      return 1;
    }
    const result = classify(data, vitestExitCode);
    if (result.failures.length > 0) {
      console.error(`FAIL: ${result.failures.map((failure) => failure.message).join("; ")}`);
      console.error(`VERIFY_FAILURE_JSON=${JSON.stringify({ failures: publicFailures(result.failures) })}`);
      return 1;
    }
    console.log(`PASS: ${result.passed} passed, ${result.pending} pending, 0 failed`);
    return 0;
  }

  if (command === "write-artifact") {
    let data = {};
    let readFailure;
    try {
      data = readReport(env.VERIFY_ARTIFACT_REPORT);
    } catch (error) {
      readFailure = reportFailure(error);
    }
    const artifact = buildArtifact(data, env, readFailure);
    fs.writeFileSync(env.VERIFY_ARTIFACT_PATH, `${JSON.stringify(artifact, null, 2)}\n`);
    return 0;
  }

  if (command === "validate-artifact") {
    const artifact = JSON.parse(fs.readFileSync(argv[3], "utf8"));
    const schema = JSON.parse(fs.readFileSync(argv[4], "utf8"));
    const { validate } = require(argv[5]);
    return validArtifact(artifact) && validate(schema, artifact).length === 0 ? 0 : 1;
  }

  if (command === "failure") {
    const failure = { code: argv[3], expected: String(argv[4]), actual: String(argv[5]) };
    console.error(`VERIFY_FAILURE_JSON=${JSON.stringify({ failures: [failure] })}`);
    return 0;
  }

  if (command === "clean") {
    let clean;
    try {
      clean = JSON.parse(fs.readFileSync(argv[3], "utf8"));
    } catch (error) {
      console.error(`FAIL: clean probe did not produce parseable JSON: ${error.message}`);
      console.error(`VERIFY_FAILURE_JSON=${JSON.stringify({ failures: [{ code: "clean_probe_invalid", expected: "clean probe JSON", actual: "unparseable" }] })}`);
      return 2;
    }
    const topLevelKeys = clean && typeof clean === "object" ? Object.keys(clean).sort() : [];
    const checks = clean && Array.isArray(clean.checks) ? clean.checks : [];
    const codes = checks.map((check) => check && check.code).sort();
    const validShape = topLevelKeys.join(",") === "checks,role"
      && codes.length === 2
      && codes[0] === "migration_hash"
      && codes[1] === "sentinel"
      && checks.every((check) => check && Object.keys(check).sort().join(",") === "actual,code,expected"
        && typeof check.expected === "string" && typeof check.actual === "string")
      && clean.role && Object.keys(clean.role).sort().join(",") === "name,superuser"
      && typeof clean.role.name === "string" && typeof clean.role.superuser === "boolean";
    if (!validShape) {
      console.error("FAIL: clean probe must provide exact role evidence plus sentinel and migration_hash checks");
      console.error(`VERIFY_FAILURE_JSON=${JSON.stringify({ failures: [{ code: "clean_probe_invalid", expected: "exact role, sentinel, and migration_hash shape", actual: topLevelKeys.join(",") || "missing" }] })}`);
      return 2;
    }
    const expectedRole = argv[4] || "";
    const failures = publicFailures(checks.filter((check) => check.expected !== check.actual));
    if (clean.role.name !== expectedRole) {
      failures.push({ code: "database_role_identity", expected: expectedRole, actual: clean.role.name });
    }
    if (clean.role.superuser) {
      failures.push({ code: "privileged_database_role", expected: "false", actual: "true" });
    }
    if (failures.length > 0) {
      console.error("FAIL: verification database is dirty");
      console.error(`VERIFY_FAILURE_JSON=${JSON.stringify({ failures })}`);
      return 1;
    }
    console.log("PASS: verification database is clean");
    return 0;
  }

  console.error("usage: verify-result.cjs classify <report-file> <vitest-exit-code> | clean <probe-file> <url-role> | write-artifact | validate-artifact <artifact-file> <schema> <validator> | failure <code> <expected> <actual>");
  return 2;
}

try {
  process.exitCode = main(process.argv, process.env);
} catch (error) {
  console.error(`FAIL: ${error.message}`);
  process.exitCode = 1;
}
