#!/usr/bin/env bash
# verify.sh — env-load + false-green-proof vitest classifier.
#
# Modes:
#   verify.sh --classify-json <report-file> [<vitest-exit-code>]
#       Pure classifier. Reads a vitest JSON report (+ optional vitest
#       exit code) and exits 0 ONLY if the run is genuinely green.
#
#   verify.sh <vitest-filter>
#       Loads env, runs the scoped backend vitest filter with the JSON
#       reporter, captures vitest's exit code, then classifies.
#       NOTE: <vitest-filter> is a VITEST test name/path filter scoped to
#       the backend package — it matches test file paths/names WITHIN the
#       backend package. It is NOT a package selector. Example:
#         verify.sh create-voc
#       runs backend tests whose path/name matches "create-voc". Passing a
#       package name (e.g. "backend") would be treated as a name filter and
#       would likely match nothing.
#
# A fully-skipped (discovered-but-pending) suite, a failed suite, a
# top-level success:false, any failed testResults entry, or a non-zero
# vitest exit code are ALL treated as FAIL. This is deliberate: a
# silently-skipped suite once looked like a pass (false green).
#
# bash-3.2-compatible: no `declare -A`, no `${var,,}`.
set -u

usage() {
  echo "usage: verify.sh --classify-json <report-file> [<vitest-exit-code>]" >&2
  echo "       verify.sh --typecheck-diff <baseline-file> <current-file>" >&2
  echo "       verify.sh --typecheck" >&2
  echo "       verify.sh <vitest-filter>   (vitest test name/path filter scoped to backend; NOT a package selector)" >&2
}

# typecheck_diff <baseline-file> <current-file>
# Any error line in <current> but NOT in <baseline> is a NEW error → FAIL.
# Missing baseline is treated as empty (all current lines are new).
typecheck_diff() {
  baseline="$1"
  current="$2"

  if [ ! -f "$current" ]; then
    echo "FAIL: current typecheck file not found: $current (fail closed)" >&2
    return 1
  fi

  baseline_src="$baseline"
  if [ ! -f "$baseline" ]; then
    baseline_src="/dev/null"
  fi

  # New-only lines: present in current, absent from baseline.
  new_lines="$(comm -13 <(sort -u "$baseline_src") <(sort -u "$current"))"

  if [ -n "$new_lines" ]; then
    echo "FAIL: NEW typecheck error(s) not in baseline ($baseline):" >&2
    echo "$new_lines" >&2
    return 1
  fi

  echo "PASS: no new typecheck errors beyond baseline ($baseline)"
  return 0
}

# classify_json <report-file> <vitest-exit-code>
# Exits 0 (PASS) only if the run is genuinely green; non-zero otherwise.
classify_json() {
  report="$1"
  vitest_ec="$2"

  # Rule 1: report missing/empty → FAIL (fail closed).
  if [ ! -f "$report" ]; then
    echo "FAIL: report file not found: $report (fail closed — never trust an absent report)" >&2
    return 1
  fi
  if [ ! -s "$report" ]; then
    echo "FAIL: report file is empty: $report (fail closed)" >&2
    return 1
  fi

  # Parse + classify with node. The node script prints a single verdict
  # line and exits 0 (PASS) or 1 (FAIL). Rule 1 (unparseable JSON),
  # rules 2-6 are all enforced inside node. Rule 7 (vitest exit) is
  # passed in and checked there too.
  node -e '
    var fs = require("fs");
    var reportPath = process.argv[1];
    var vitestEc = parseInt(process.argv[2], 10);
    if (isNaN(vitestEc)) vitestEc = 0;

    var raw, data;
    try {
      raw = fs.readFileSync(reportPath, "utf8");
    } catch (e) {
      console.error("FAIL: cannot read report: " + e.message + " (fail closed)");
      process.exit(1);
    }
    try {
      data = JSON.parse(raw);
    } catch (e) {
      console.error("FAIL: report is not parseable JSON (fail closed): " + e.message);
      process.exit(1);
    }
    if (data === null || typeof data !== "object") {
      console.error("FAIL: report JSON is not an object (fail closed)");
      process.exit(1);
    }

    function num(k) {
      var v = data[k];
      return (typeof v === "number" && isFinite(v)) ? v : 0;
    }

    var passed       = num("numPassedTests");
    var failed       = num("numFailedTests");
    var pending      = num("numPendingTests");
    var failedSuites = num("numFailedTestSuites");
    var success      = data.success;
    var results      = Array.isArray(data.testResults) ? data.testResults : [];

    var reasons = [];

    // Rule 7: a non-zero vitest exit means the run crashed; JSON may be
    // stale/partial. FAIL even if the numbers look clean.
    if (vitestEc !== 0) {
      reasons.push("vitest exited non-zero (" + vitestEc + ") — run crashed; JSON may be stale/partial");
    }

    // Rule 2: discovered-but-fully-skipped suite — the false-green bug.
    if (passed + failed === 0) {
      reasons.push("no executable tests ran (passed+failed==0); " + pending + " pending — suite fully skipped or filter matched nothing; if integration, check DATABASE_URL/WORKSPACE_ID");
    }

    // Rule 3
    if (failed > 0) {
      reasons.push(failed + " failed test(s)");
    }

    // Rule 4: a suite failed during setup/import even with 0 failed tests.
    if (failedSuites > 0) {
      reasons.push(failedSuites + " failed test suite(s) (setup/import failure)");
    }

    // Rule 5: vitest overall verdict.
    if (success === false) {
      reasons.push("top-level success===false (vitest overall verdict)");
    }

    // Rule 6: any failed entry in testResults.
    var resFailed = 0;
    for (var i = 0; i < results.length; i++) {
      if (results[i] && results[i].status === "failed") resFailed++;
    }
    if (resFailed > 0) {
      reasons.push(resFailed + " failed testResults entr(y/ies)");
    }

    if (reasons.length > 0) {
      console.error("FAIL: " + reasons.join("; "));
      process.exit(1);
    }

    console.log("PASS: " + passed + " passed, " + pending + " pending, 0 failed");
    process.exit(0);
  ' "$report" "$vitest_ec"
  return $?
}

emit_verify_artifact() {
  issue="$1"
  filter="$2"
  report="$3"
  vitest_ec="$4"
  classifier="$5"

  case "$issue" in
    ""|*[!0-9]*)
      echo "WARN: VERIFY_ISSUE must be a non-empty integer; skipping verify artifact" >&2
      return 0
      ;;
  esac

  artifact_path=".review/ISSUE-${issue}-VERIFY.json"
  mkdir -p .review || {
    echo "WARN: unable to create .review directory; skipping verify artifact" >&2
    return 0
  }

  db_host=""
  db_database=""
  db_role=""
  if [ -n "${DATABASE_URL+x}" ] && [ -n "$DATABASE_URL" ]; then
    db_after_scheme="$(printf '%s\n' "$DATABASE_URL" | sed 's,^[^:][^:]*://,,')"
    db_role=""
    case "$db_after_scheme" in
      *@*) db_role="$(printf '%s\n' "$db_after_scheme" | sed 's/[:@].*//')" ;;
    esac

    db_authority="$db_after_scheme"
    case "$db_authority" in
      *@*) db_authority="${db_authority#*@}" ;;
    esac
    db_host="$(printf '%s\n' "$db_authority" | sed 's/[/:].*//')"
    case "$db_authority" in
      \[*\]*) db_host="$(printf '%s\n' "$db_authority" | sed 's/^\(\[[^]]*\]\).*/\1/')" ;;
      "::1"|::1/*|::1:*) db_host="::1" ;;
    esac
    case "$db_after_scheme" in
      */*) db_database="$(printf '%s\n' "$db_after_scheme" | sed 's/[?].*$//; s,.*/,,')" ;;
    esac
  fi

  head_sha="$(git rev-parse HEAD 2>/dev/null || printf '')"
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || printf '')"
  cwd="$(pwd)"
  verify_cmd="verify.sh $filter"
  created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  VERIFY_ARTIFACT_PATH="$artifact_path" \
  VERIFY_ARTIFACT_ISSUE="$issue" \
  VERIFY_ARTIFACT_BRANCH="$branch" \
  VERIFY_ARTIFACT_HEAD_SHA="$head_sha" \
  VERIFY_ARTIFACT_CWD="$cwd" \
  VERIFY_ARTIFACT_CMD="$verify_cmd" \
  VERIFY_ARTIFACT_DB_HOST="$db_host" \
  VERIFY_ARTIFACT_DB_DATABASE="$db_database" \
  VERIFY_ARTIFACT_DB_ROLE="$db_role" \
  VERIFY_ARTIFACT_EXIT_CODE="$vitest_ec" \
  VERIFY_ARTIFACT_CLASSIFIER="$classifier" \
  VERIFY_ARTIFACT_CREATED_AT="$created_at" \
  VERIFY_ARTIFACT_REPORT="$report" \
  node -e '
    var fs = require("fs");
    function count(data, key) {
      var value = data && data[key];
      return (typeof value === "number" && isFinite(value)) ? value : 0;
    }

    var data = {};
    try {
      data = JSON.parse(fs.readFileSync(process.env.VERIFY_ARTIFACT_REPORT, "utf8"));
    } catch (e) {
      data = {};
    }

    var artifact = {
      schema_version: "1",
      artifact_type: "verify_result",
      producer_role: "VERIFIER",
      issue: parseInt(process.env.VERIFY_ARTIFACT_ISSUE, 10),
      branch: process.env.VERIFY_ARTIFACT_BRANCH || "",
      head_sha: process.env.VERIFY_ARTIFACT_HEAD_SHA || "",
      cwd: process.env.VERIFY_ARTIFACT_CWD || "",
      verify_cmd: process.env.VERIFY_ARTIFACT_CMD || "",
      env_profile: "scrubbed",
      db_target: {
        host: process.env.VERIFY_ARTIFACT_DB_HOST || "",
        database: process.env.VERIFY_ARTIFACT_DB_DATABASE || "",
        role: process.env.VERIFY_ARTIFACT_DB_ROLE || ""
      },
      verdict: {
        passed: count(data, "numPassedTests"),
        failed: count(data, "numFailedTests"),
        pending: count(data, "numPendingTests"),
        exit_code: parseInt(process.env.VERIFY_ARTIFACT_EXIT_CODE, 10) || 0
      },
      classifier: process.env.VERIFY_ARTIFACT_CLASSIFIER === "PASS" ? "PASS" : "FAIL",
      created_at: process.env.VERIFY_ARTIFACT_CREATED_AT || ""
    };

    if (process.env.CODEX_VERSION) {
      artifact.producer_version = "codex/" + process.env.CODEX_VERSION;
    }

    fs.writeFileSync(process.env.VERIFY_ARTIFACT_PATH, JSON.stringify(artifact, null, 2) + "\n");
  ' || {
    echo "WARN: unable to write verify artifact: $artifact_path" >&2
    return 0
  }
}

main() {
  if [ "$#" -lt 1 ]; then
    usage
    exit 2
  fi

  if [ "$1" = "--classify-json" ]; then
    if [ "$#" -lt 2 ]; then
      usage
      exit 2
    fi
    report="$2"
    vitest_ec="${3:-0}"
    classify_json "$report" "$vitest_ec"
    exit $?
  fi

  if [ "$1" = "--typecheck-diff" ]; then
    if [ "$#" -lt 3 ]; then
      usage
      exit 2
    fi
    typecheck_diff "$2" "$3"
    exit $?
  fi

  if [ "$1" = "--typecheck" ]; then
    root="$(git rev-parse --show-toplevel)"
    cd "$root" || exit 2
    baseline=".review/typecheck-baseline.txt"
    if [ ! -f "$baseline" ]; then
      mkdir -p "$(dirname "$baseline")"
      : > "$baseline"
    fi
    tmp_current="$(mktemp -t verify-typecheck.XXXXXX)"
    trap 'rm -f "$tmp_current"' EXIT
    pnpm --filter backend run typecheck 2>&1 | grep -E "error TS[0-9]+" | sort -u > "$tmp_current" || true
    typecheck_diff "$baseline" "$tmp_current"
    exit $?
  fi

  # Filter mode: load env, run scoped vitest, classify.
  filter="$1"

  if [ -f ./.env ]; then
    set -a
    . ./.env
    set +a
  fi
  if [ -f apps/backend/.env ]; then
    set -a
    . apps/backend/.env
    set +a
  fi

  if [ -n "${VERIFY_DATABASE_URL+x}" ] && [ -n "$VERIFY_DATABASE_URL" ]; then
    export DATABASE_URL="$VERIFY_DATABASE_URL"
    export DATABASE_URL_MIGRATE="${VERIFY_DATABASE_URL_MIGRATE:-$VERIFY_DATABASE_URL}"
  fi

  if [ -n "${DATABASE_URL+x}" ] && [ -n "$DATABASE_URL" ]; then
    db_after_scheme="$(printf '%s\n' "$DATABASE_URL" | sed 's,^[^:][^:]*://,,')"
    db_user="$(printf '%s\n' "$db_after_scheme" | sed 's/[:@].*//')"
    if [ "$db_user" = "postgres" ]; then
      echo "WARN: verifier running as superuser role 'postgres' — prefer a low-privilege role (e.g. fops_app) via VERIFY_DATABASE_URL" >&2
    fi

    db_authority="$db_after_scheme"
    case "$db_authority" in
      *@*) db_authority="${db_authority#*@}" ;;
    esac
    db_host="$(printf '%s\n' "$db_authority" | sed 's/[/:].*//')"
    case "$db_authority" in
      \[*\]*) db_host="$(printf '%s\n' "$db_authority" | sed 's/^\(\[[^]]*\]\).*/\1/')" ;;
      "::1"|::1/*|::1:*) db_host="::1" ;;
    esac
    case "$db_host" in
      ""|"localhost"|"127.0.0.1"|"::1"|"[::1]") ;;
      *)
        echo "FAIL: refusing to verify against non-local DATABASE_URL host '$db_host' (fail closed — verifier must run against a local/ephemeral DB)" >&2
        exit 3
        ;;
    esac
  fi

  tmp_report="$(mktemp -t verify-vitest.XXXXXX)"
  trap 'rm -f "$tmp_report"' EXIT

  set -- env -i
  for env_name in PATH HOME SHELL TERM LANG LC_ALL TMPDIR TMP USER LOGNAME PWD NODE_OPTIONS NODE_ENV DATABASE_URL DATABASE_URL_MIGRATE WORKSPACE_ID CI; do
    eval 'if [ -n "${'"$env_name"'+x}" ]; then env_value=$'"$env_name"'; set -- "$@" "'"$env_name"'=$env_value"; fi'
  done
  for env_name in $(env | sed -n 's/^\(PNPM_[A-Za-z0-9_]*\)=.*/\1/p; s/^\(npm_config_[A-Za-z0-9_]*\)=.*/\1/p' | sort -u); do
    eval 'if [ -n "${'"$env_name"'+x}" ]; then env_value=$'"$env_name"'; set -- "$@" "'"$env_name"'=$env_value"; fi'
  done
  for env_name in ${VERIFY_ENV_ALLOW:-}; do
    case "$env_name" in
      [A-Za-z_][A-Za-z0-9_]*)
        eval 'if [ -n "${'"$env_name"'+x}" ]; then env_value=$'"$env_name"'; set -- "$@" "'"$env_name"'=$env_value"; fi'
        ;;
    esac
  done

  "$@" pnpm --filter backend exec vitest run "$filter" --reporter=json --outputFile="$tmp_report"
  vitest_ec=$?

  classify_json "$tmp_report" "$vitest_ec"
  cls_ec=$?
  if [ "$cls_ec" -eq 0 ]; then
    classifier="PASS"
  else
    classifier="FAIL"
  fi

  if [ -n "${VERIFY_ISSUE+x}" ] && [ -n "$VERIFY_ISSUE" ]; then
    emit_verify_artifact "$VERIFY_ISSUE" "$filter" "$tmp_report" "$vitest_ec" "$classifier"
  fi

  exit "$cls_ec"
}

main "$@"
