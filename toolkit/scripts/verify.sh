#!/usr/bin/env bash
# verify.sh — env-load + false-green-proof vitest classifier.
# Current target contract: pnpm workspace package `backend` tested with Vitest.
# Do not generalize until a second real target and fixture exist.
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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERIFY_RESULT="$SCRIPT_DIR/lib/verify-result.cjs"

usage() {
  echo "usage: verify.sh --classify-json <report-file> [<vitest-exit-code>]" >&2
  echo "       verify.sh --typecheck-diff <baseline-file> <current-file>" >&2
  echo "       verify.sh --typecheck" >&2
  echo "       verify.sh --parse-db-url <database-url>   (hidden test mode)" >&2
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

  # Parse + classify with the result module. It prints a single verdict
  # line and exits 0 (PASS) or 1 (FAIL). Rule 1 (unparseable JSON),
  # rules 2-6 are all enforced inside node. Rule 7 (vitest exit) is
  # passed in and checked there too.
  node "$VERIFY_RESULT" classify "$report" "$vitest_ec"
  return $?
}

parse_db_url() {
  DB_HOST=""
  DB_DATABASE=""
  DB_ROLE=""
  [ -z "${1:-}" ] && return 0

  db_after_scheme="$(printf '%s\n' "$1" | sed 's,^[^:][^:]*://,,')"
  case "$db_after_scheme" in
    *@*) DB_ROLE="$(printf '%s\n' "$db_after_scheme" | sed 's/[:@].*//')" ;;
  esac

  db_authority="$db_after_scheme"
  case "$db_authority" in
    *@*) db_authority="${db_authority#*@}" ;;
  esac
  DB_HOST="$(printf '%s\n' "$db_authority" | sed 's/[/:].*//')"
  case "$db_authority" in
    \[*\]*) DB_HOST="$(printf '%s\n' "$db_authority" | sed 's/^\(\[[^]]*\]\).*/\1/')" ;;
    "::1"|::1/*|::1:*) DB_HOST="::1" ;;
  esac
  case "$db_after_scheme" in
    */*) DB_DATABASE="$(printf '%s\n' "$db_after_scheme" | sed 's/[?].*$//; s,.*/,,')" ;;
  esac
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
    echo "FAIL: unable to create .review directory; cannot write verify artifact" >&2
    return 1
  }

  parse_db_url "${DATABASE_URL:-}"

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
  VERIFY_ARTIFACT_DB_HOST="$DB_HOST" \
  VERIFY_ARTIFACT_DB_DATABASE="$DB_DATABASE" \
  VERIFY_ARTIFACT_DB_ROLE="$DB_ROLE" \
  VERIFY_ARTIFACT_EXIT_CODE="$vitest_ec" \
  VERIFY_ARTIFACT_CLASSIFIER="$classifier" \
  VERIFY_ARTIFACT_CREATED_AT="$created_at" \
  VERIFY_ARTIFACT_REPORT="$report" \
  node "$VERIFY_RESULT" write-artifact || {
    echo "FAIL: unable to write verify artifact: $artifact_path" >&2
    return 1
  }

  node "$VERIFY_RESULT" validate-artifact "$artifact_path" >/dev/null 2>&1 || {
    echo "FAIL: wrote invalid verify artifact: $artifact_path" >&2
    return 1
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

  if [ "$1" = "--parse-db-url" ]; then
    if [ "$#" -lt 2 ]; then
      usage
      exit 2
    fi
    parse_db_url "$2"
    printf '%s\t%s\t%s\n' "$DB_HOST" "$DB_DATABASE" "$DB_ROLE"
    exit 0
  fi

  if [ "$1" = "--typecheck" ]; then
    root="$(git rev-parse --show-toplevel)"
    cd "$root" || exit 2
    baseline=".review/typecheck-baseline.txt"
    if [ ! -f "$baseline" ]; then
      mkdir -p "$(dirname "$baseline")"
      : > "$baseline"
    fi
    raw="$(mktemp -t verify-typecheck-raw.XXXXXX)"
    tmp_current="$(mktemp -t verify-typecheck.XXXXXX)"
    trap 'rm -f "$raw" "$tmp_current"' EXIT
    pnpm --filter backend run typecheck > "$raw" 2>&1
    pnpm_ec=$?
    grep -E "error TS[0-9]+" "$raw" | sort -u > "$tmp_current" || true
    if [ "$pnpm_ec" -ne 0 ] && [ ! -s "$tmp_current" ]; then
      echo "FAIL: typecheck command did not run or crashed (exit $pnpm_ec) with no parseable 'error TS' lines — fail closed" >&2
      echo "----- typecheck output (head) -----" >&2
      sed -n '1,40p' "$raw" >&2
      exit 1
    fi
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
  elif [ -n "${VERIFY_ISSUE:-}" ]; then
    # Fail closed: in per-issue verification mode an unset/empty
    # VERIFY_DATABASE_URL must NEVER silently inherit the app .env's
    # DATABASE_URL (2026-07-13 incident: an upstream `eval $(... | tail -1)`
    # of empty stdout left it unset and the suite ran against the shared dev
    # DB, producing a garbage FAIL artifact with db_target "feedbackops").
    echo "FAIL: VERIFY_ISSUE=$VERIFY_ISSUE is set but VERIFY_DATABASE_URL is unset/empty — refusing to fall back to .env DATABASE_URL (fail closed; run prepare-verify-db.sh and export its VERIFY_DATABASE_URL)" >&2
    exit 4
  fi

  parse_db_url "${DATABASE_URL:-}"
  if [ -n "${DATABASE_URL+x}" ] && [ -n "$DATABASE_URL" ]; then
    if [ "$DB_ROLE" = "postgres" ]; then
      echo "WARN: verifier running as superuser role 'postgres' — prefer a low-privilege role (e.g. fops_app) via VERIFY_DATABASE_URL" >&2
    fi

    case "$DB_HOST" in
      ""|"localhost"|"127.0.0.1"|"::1"|"[::1]") ;;
      *)
        echo "FAIL: refusing to verify against non-local DATABASE_URL host '$DB_HOST' (fail closed — verifier must run against a local/ephemeral DB)" >&2
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

  # NOTE: vitest 2.1.8 with a JSON-ONLY reporter intermittently crashes the
  # worker and emits a false-fail report (every test marked failed with an
  # EMPTY failureMessage) even when the suite passes. Pairing the JSON reporter
  # with a console reporter stabilizes the worker. The `default` reporter writes
  # to stdout and does NOT touch the JSON outputFile, so the classifier still
  # reads a faithful machine report. Proven on FeedbackOps #112: json-only →
  # 0/7 (empty messages); json+default → 7/7. Do not drop the second reporter.
  echo "VERIFIER effective DB -> host=$DB_HOST db=$DB_DATABASE role=$DB_ROLE (injected into vitest child)" >&2
  "$@" pnpm --filter backend exec vitest run "$filter" --reporter=json --reporter=default --outputFile="$tmp_report"
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
    emit_ec=$?
    if [ "$emit_ec" -ne 0 ]; then
      if [ "$cls_ec" -eq 0 ]; then
        echo "FAIL: green run but could not write a valid verify artifact — evidence is the product (fail closed)" >&2
        exit 5
      else
        echo "WARN: verify artifact write failed on an already-failing run; preserving test FAIL (exit $cls_ec)" >&2
      fi
    fi
  fi

  exit "$cls_ec"
}

main "$@"
