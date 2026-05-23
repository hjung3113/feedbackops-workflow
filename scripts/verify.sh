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
  echo "       verify.sh <vitest-filter>" >&2
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

  tmp_report="$(mktemp -t verify-vitest.XXXXXX)"
  trap 'rm -f "$tmp_report"' EXIT

  pnpm --filter backend exec vitest run "$filter" --reporter=json --outputFile="$tmp_report"
  vitest_ec=$?

  classify_json "$tmp_report" "$vitest_ec"
  exit $?
}

main "$@"
