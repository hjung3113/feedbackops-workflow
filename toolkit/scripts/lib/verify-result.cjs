"use strict";

const fs = require("fs");
const path = require("path");

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

function sameJson(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function runFromArtifact(artifact) {
  return {
    verify_cmd: artifact.verify_cmd,
    clean_state: artifact.clean_state,
    verdict: artifact.verdict,
    classifier: artifact.classifier,
    failures: artifact.failures,
    created_at: artifact.created_at,
  };
}

function sameIdentity(left, right) {
  return left.issue === right.issue
    && left.branch === right.branch
    && left.head_sha === right.head_sha
    && left.cwd === right.cwd
    && sameJson(left.db_target, right.db_target);
}

function aggregateArtifact(current, runs) {
  const latest = runs[runs.length - 1];
  const allPass = runs.every((run) => run.classifier === "PASS");
  const aggregate = {
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
  return aggregate;
}

function appendRun(existing, current) {
  if (!existing || !sameIdentity(existing, current)) {
    return aggregateArtifact(current, [runFromArtifact(current)]);
  }
  const priorRuns = Array.isArray(existing.runs) ? existing.runs : [runFromArtifact(existing)];
  return aggregateArtifact(current, priorRuns.concat([runFromArtifact(current)]));
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
    return passed >= 1 && failed === 0 && exitCode === 0 && run.failures.length === 0;
  }
  return failed > 0 || exitCode !== 0 || run.failures.length > 0;
}

function validAggregate(artifact) {
  if (!Object.prototype.hasOwnProperty.call(artifact, "runs")) return true; // v1 flat artifact: synthetic one-run legacy input.
  if (!Array.isArray(artifact.runs)) return false;
  if (artifact.runs.length === 0 || !artifact.runs.every(validRun)) return false;
  const expected = aggregateArtifact({...artifact, runs: undefined}, artifact.runs);
  return artifact.verify_cmd === expected.verify_cmd
    && sameJson(artifact.clean_state, expected.clean_state)
    && sameJson(artifact.verdict, expected.verdict)
    && artifact.classifier === expected.classifier
    && sameJson(artifact.failures, expected.failures)
    && artifact.created_at === expected.created_at;
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
    && typeof artifact.verdict === "object"
    && validAggregate(artifact);
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
    const current = buildArtifact(data, env, readFailure);
    let artifact = current;
    if (fs.existsSync(env.VERIFY_ARTIFACT_PATH)) {
      let existing;
      try {
        existing = JSON.parse(fs.readFileSync(env.VERIFY_ARTIFACT_PATH, "utf8"));
      } catch (error) {
        throw new Error(`cannot append to existing canonical VERIFY artifact: ${error.message}`);
      }
      if (!validArtifact(existing)) {
        throw new Error("cannot append to an invalid canonical VERIFY artifact");
      }
      artifact = appendRun(existing, current);
    } else {
      artifact = appendRun(null, current);
    }
    const artifactPath = env.VERIFY_ARTIFACT_PATH;
    const temporaryPath = path.join(path.dirname(artifactPath),
      `.${path.basename(artifactPath)}.tmp-${process.pid}-${Date.now()}`);
    try {
      fs.writeFileSync(temporaryPath, `${JSON.stringify(artifact, null, 2)}\n`);
      const schemaPath = argv[3];
      const validatorPath = argv[4];
      if (!schemaPath || !validatorPath) throw new Error("schema and validator are required for canonical artifact publication");
      const schema = JSON.parse(fs.readFileSync(schemaPath, "utf8"));
      const { validate } = require(validatorPath);
      const temporaryArtifact = JSON.parse(fs.readFileSync(temporaryPath, "utf8"));
      if (!validArtifact(temporaryArtifact) || validate(schema, temporaryArtifact).length !== 0) {
        throw new Error("temporary canonical VERIFY artifact failed validation");
      }
      if (env.VERIFY_ARTIFACT_TEST_FAIL_BEFORE_RENAME === "1") {
        throw new Error("test-injected failure before atomic rename");
      }
      fs.renameSync(temporaryPath, artifactPath);
    } catch (error) {
      try { fs.unlinkSync(temporaryPath); } catch (unlinkError) { /* best-effort temporary cleanup */ }
      throw error;
    }
    return 0;
  }

  if (command === "validate-artifact") {
    const artifact = JSON.parse(fs.readFileSync(argv[3], "utf8"));
    const schema = JSON.parse(fs.readFileSync(argv[4], "utf8"));
    const { validate } = require(argv[5]);
    return validArtifact(artifact) && validate(schema, artifact).length === 0 ? 0 : 1;
  }

  if (command === "aggregate-exit-code") {
    const artifact = JSON.parse(fs.readFileSync(argv[3], "utf8"));
    if (!validArtifact(artifact)) return 2;
    return artifact.classifier === "PASS" ? 0 : 1;
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
      && typeof clean.role.name === "string" && clean.role.name.length > 0
      && typeof clean.role.superuser === "boolean";
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

  console.error("usage: verify-result.cjs classify <report-file> <vitest-exit-code> | clean <probe-file> <url-role> | write-artifact <schema> <validator> | validate-artifact <artifact-file> <schema> <validator> | aggregate-exit-code <artifact-file> | failure <code> <expected> <actual>");
  return 2;
}

try {
  process.exitCode = main(process.argv, process.env);
} catch (error) {
  console.error(`FAIL: ${error.message}`);
  process.exitCode = 1;
}
