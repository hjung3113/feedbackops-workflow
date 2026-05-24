#!/usr/bin/env bash
# Provision a per-issue local verification database and print VERIFY_DATABASE_URL.
#
# Usage:
#   prepare-verify-db.sh --issue <N> [--target <repo>] [--base-url <admin-pg-url>]
#                        [--migrate-cmd <cmd>] [--seed-cmd <cmd>] [--drop]
#
# bash-3.2-compatible: no `declare -A`, no `${var,,}`, no `mapfile`.
set -u

usage() {
  echo "usage: prepare-verify-db.sh --issue <N> [--target <repo>] [--base-url <admin-pg-url>] [--migrate-cmd <cmd>] [--seed-cmd <cmd>] [--drop]" >&2
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    die "required command not found on PATH: $name"
  fi
}

redact_url() {
  url="$1"
  printf '%s\n' "$url" | sed 's,\(://[^:/@][^:/@]*:\)[^@/]*@,\1REDACTED@,'
}

url_without_scheme() {
  printf '%s\n' "$1" | sed 's,^[^:][^:]*://,,'
}

url_host() {
  rest="$(url_without_scheme "$1")"
  authority="$rest"
  case "$authority" in
    */*) authority="${authority%%/*}" ;;
  esac
  case "$authority" in
    *@*) authority="${authority#*@}" ;;
  esac
  case "$authority" in
    \[*\]*) printf '%s\n' "$authority" | sed 's/^\(\[[^]]*\]\).*/\1/' ;;
    ::1|::1:*) printf '%s\n' "::1" ;;
    *) printf '%s\n' "$authority" | sed 's/:.*//' ;;
  esac
}

url_user() {
  rest="$(url_without_scheme "$1")"
  case "$rest" in
    *@*) printf '%s\n' "$rest" | sed 's/[:@].*//' ;;
    *) printf '%s\n' "" ;;
  esac
}

local_host_or_exit() {
  host="$(url_host "$1")"
  case "$host" in
    localhost|127.0.0.1|::1|\[::1\]) return 0 ;;
    *)
      echo "FAIL: refusing to prepare verify DB against non-local base-url host '$host' (fail closed — verifier DB must be local/ephemeral)" >&2
      exit 3
      ;;
  esac
}

swap_dbname() {
  url="$1"
  db="$2"
  prefix="$(printf '%s\n' "$url" | sed 's,\(^[^:][^:]*://\).*,\1,')"
  rest="$(url_without_scheme "$url")"
  query=""
  case "$rest" in
    *\?*) query="?${rest#*\?}"; rest="${rest%%\?*}" ;;
  esac
  authority="$rest"
  case "$authority" in
    */*) authority="${authority%%/*}" ;;
  esac
  printf '%s%s/%s%s\n' "$prefix" "$authority" "$db" "$query"
}

with_role() {
  url="$1"
  role="$2"
  rest="$(url_without_scheme "$url")"
  prefix="$(printf '%s\n' "$url" | sed 's,\(^[^:][^:]*://\).*,\1,')"
  case "$rest" in
    *@*) after_at="${rest#*@}" ;;
    *) after_at="$rest" ;;
  esac
  printf '%s%s@%s\n' "$prefix" "$role" "$after_at"
}

run_in_target() {
  cmd="$1"
  target="$2"
  verify_url="$3"
  migrate_url="$4"

  if [ -n "$target" ]; then
    if [ ! -d "$target" ]; then
      die "--target is not a directory: $target"
    fi
    ( cd "$target" && DATABASE_URL="$verify_url" DATABASE_URL_MIGRATE="$migrate_url" sh -c "$cmd" )
  else
    DATABASE_URL="$verify_url" DATABASE_URL_MIGRATE="$migrate_url" sh -c "$cmd"
  fi
}

ISSUE=""
TARGET=""
BASE_URL="${PGADMIN_URL:-}"
MIGRATE_CMD=""
SEED_CMD=""
DROP=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --issue)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      ISSUE="$2"; shift 2 ;;
    --target)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      TARGET="$2"; shift 2 ;;
    --base-url)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      BASE_URL="$2"; shift 2 ;;
    --migrate-cmd)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      MIGRATE_CMD="$2"; shift 2 ;;
    --seed-cmd)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      SEED_CMD="$2"; shift 2 ;;
    --drop)
      DROP=1; shift ;;
    --help|-h)
      usage; exit 0 ;;
    *)
      echo "unknown arg: $1" >&2
      usage
      exit 2 ;;
  esac
done

if [ -z "$ISSUE" ]; then
  usage
  die "--issue is required"
fi
case "$ISSUE" in
  *[!0-9]*|"")
    die "issue must be numeric; got '$ISSUE'"
    ;;
esac

if [ -z "$BASE_URL" ]; then
  die "--base-url is required unless PGADMIN_URL is set. Example: PGADMIN_URL=postgres://fops_migrate:REDACTED@localhost:5434/postgres"
fi

DB_NAME="verify_issue_$ISSUE"
OWNER="${VERIFY_DB_OWNER:-fops_migrate}"
VERIFY_URL="$(swap_dbname "$BASE_URL" "$DB_NAME")"
MIGRATE_URL="$VERIFY_URL"
if [ -n "${VERIFY_DB_ROLE:-}" ]; then
  VERIFY_URL="$(with_role "$VERIFY_URL" "$VERIFY_DB_ROLE")"
else
  VERIFY_USER="$(url_user "$VERIFY_URL")"
  if [ "$VERIFY_USER" = "postgres" ]; then
    echo "WARN: verify DB URL uses superuser role 'postgres'; prefer VERIFY_DB_ROLE=fops_app" >&2
  fi
fi

local_host_or_exit "$BASE_URL"

if [ "$DROP" -eq 1 ]; then
  require_cmd dropdb
  echo "=== prepare-verify-db: drop $DB_NAME ==="
  dropdb -d "$BASE_URL" --if-exists "$DB_NAME"
  echo "dropped verify DB if present: $DB_NAME"
  exit 0
fi

require_cmd psql
require_cmd createdb

echo "=== prepare-verify-db: $DB_NAME ==="
echo "  base-url: $(redact_url "$BASE_URL")"
echo "  verify DB: $DB_NAME"
echo "  owner: $OWNER"

exists="$(psql -Atqc "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'" "$BASE_URL" 2>/dev/null || true)"
case "$exists" in
  *1*)
    echo "  database already exists: $DB_NAME"
    ;;
  *)
    echo "  creating database: $DB_NAME"
    createdb -d "$BASE_URL" -O "$OWNER" "$DB_NAME"
    ;;
esac

if [ -n "$MIGRATE_CMD" ]; then
  echo "  running migrations"
  run_in_target "$MIGRATE_CMD" "$TARGET" "$MIGRATE_URL" "$MIGRATE_URL"
else
  echo "  migrations not run; run manually with DATABASE_URL_MIGRATE and DATABASE_URL pointed at $DB_NAME"
fi

if [ -n "$SEED_CMD" ]; then
  echo "  running seed"
  run_in_target "$SEED_CMD" "$TARGET" "$VERIFY_URL" "$MIGRATE_URL"
else
  echo "  seed not run; run manually with DATABASE_URL and DATABASE_URL_MIGRATE pointed at $DB_NAME"
fi

echo "VERIFY_DATABASE_URL=$VERIFY_URL"
