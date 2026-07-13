#!/usr/bin/env bash
# Smoke test for scripts/prepare-verify-db.sh pure guard/derivation paths.
# No real Postgres required. Run: bash scripts/__tests__/prepare-verify-db.smoke.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREP="$SCRIPT_DIR/../prepare-verify-db.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAILURES=0

pass() { echo "ok   - $1"; }
fail() { echo "NOT OK - $1"; FAILURES=$((FAILURES + 1)); }

run_prep() {
  env -u PGADMIN_URL bash "$PREP" "$@" > "$TMP_DIR/out.txt" 2>&1
  return $?
}

# Case 1: non-numeric issue is refused.
run_prep --issue abc --base-url postgres://u:p@localhost/postgres
ec=$?
OUT="$(cat "$TMP_DIR/out.txt")"
if [ "$ec" -ne 0 ]; then pass "non-numeric issue exits non-zero"; else fail "non-numeric issue exits non-zero"; fi
case "$OUT" in
  *"issue must be numeric"*) pass "non-numeric issue explains numeric requirement" ;;
  *) fail "non-numeric issue explains numeric requirement" ;;
esac

# Case 2: non-local base URL fails closed with exit 3.
run_prep --issue 12 --base-url postgres://u:p@example.com/postgres
ec=$?
OUT="$(cat "$TMP_DIR/out.txt")"
if [ "$ec" -eq 3 ]; then pass "non-local base-url exits 3"; else fail "non-local base-url exits 3 (got $ec)"; fi
case "$OUT" in
  *"refusing to prepare verify DB against non-local"*|*"fail closed"*) pass "non-local base-url prints fail-closed message" ;;
  *) fail "non-local base-url prints fail-closed message" ;;
esac

# Case 3: missing base-url and no PGADMIN_URL gives guidance.
run_prep --issue 12
ec=$?
OUT="$(cat "$TMP_DIR/out.txt")"
if [ "$ec" -ne 0 ]; then pass "missing base-url exits non-zero"; else fail "missing base-url exits non-zero"; fi
case "$OUT" in
  *"PGADMIN_URL"*|*"--base-url"*) pass "missing base-url mentions PGADMIN_URL or --base-url" ;;
  *) fail "missing base-url mentions PGADMIN_URL or --base-url" ;;
esac

# Case 4: DB name derivation appears in output, with psql/createdb stubbed.
FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/psql" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$FAKE_BIN/createdb" <<'SH'
#!/usr/bin/env bash
printf 'createdb args: %s\n' "$*" >> "$PREPARE_VERIFY_DB_FAKE_LOG"
exit 0
SH
chmod +x "$FAKE_BIN/psql" "$FAKE_BIN/createdb"
PREPARE_VERIFY_DB_FAKE_LOG="$TMP_DIR/fake.log" PATH="$FAKE_BIN:/usr/bin:/bin" env -u PGADMIN_URL bash "$PREP" --issue 456 --base-url postgres://u:p@localhost/postgres > "$TMP_DIR/out.txt" 2>&1
ec=$?
OUT="$(cat "$TMP_DIR/out.txt")"
if [ "$ec" -eq 0 ]; then pass "stubbed create exits zero"; else fail "stubbed create exits zero (got $ec)"; fi
case "$OUT" in
  *"verify_issue_456"*) pass "derived DB name appears in output" ;;
  *) fail "derived DB name appears in output" ;;
esac
LAST_LINE="$(tail -n 1 "$TMP_DIR/out.txt")"
if [ "$LAST_LINE" = "VERIFY_DATABASE_URL=postgres://u:p@localhost/verify_issue_456" ]; then
  pass "last line is exact VERIFY_DATABASE_URL"
else
  fail "last line is exact VERIFY_DATABASE_URL (got: $LAST_LINE)"
fi

# Case 5: --drop still requires a base URL / PGADMIN_URL.
run_prep --issue 12 --drop
ec=$?
OUT="$(cat "$TMP_DIR/out.txt")"
if [ "$ec" -ne 0 ]; then pass "--drop without base-url exits non-zero"; else fail "--drop without base-url exits non-zero"; fi
case "$OUT" in
  *"PGADMIN_URL"*|*"--base-url"*) pass "--drop without base-url gives guidance" ;;
  *) fail "--drop without base-url gives guidance" ;;
esac

# Case 6: createdb client must NOT be used (its "-d <url>" is an invalid
# option on modern pg clients — 2026-07-13 incident); all DDL goes via psql.
if [ -s "$TMP_DIR/fake.log" ]; then
  fail "createdb client is never invoked (got: $(cat "$TMP_DIR/fake.log"))"
else
  pass "createdb client is never invoked"
fi

# Case 7: failed CREATE DATABASE → non-zero exit, CREATEDB hint, and NO
# VERIFY_DATABASE_URL line on stdout (fail closed; that line feeds
# `eval $(... | tail -1)` pipelines downstream).
FAIL_BIN="$TMP_DIR/bin-create-fail"
mkdir -p "$FAIL_BIN"
cat > "$FAIL_BIN/psql" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    "CREATE DATABASE"*) echo "ERROR: permission denied to create database" >&2; exit 1 ;;
  esac
done
exit 0
SH
chmod +x "$FAIL_BIN/psql"
PATH="$FAIL_BIN:/usr/bin:/bin" env -u PGADMIN_URL bash "$PREP" --issue 457 --base-url postgres://u:p@localhost/postgres > "$TMP_DIR/out.stdout" 2> "$TMP_DIR/out.stderr"
ec=$?
if [ "$ec" -ne 0 ]; then pass "failed CREATE DATABASE exits non-zero"; else fail "failed CREATE DATABASE exits non-zero"; fi
case "$(cat "$TMP_DIR/out.stderr")" in
  *CREATEDB*) pass "failed create mentions CREATEDB privilege" ;;
  *) fail "failed create mentions CREATEDB privilege" ;;
esac
if grep -q "^VERIFY_DATABASE_URL=" "$TMP_DIR/out.stdout"; then
  fail "failed create must not print VERIFY_DATABASE_URL on stdout"
else
  pass "failed create must not print VERIFY_DATABASE_URL on stdout"
fi

# Case 8: failed migrate cmd → non-zero exit and NO VERIFY_DATABASE_URL line.
OK_BIN="$TMP_DIR/bin-all-ok"
mkdir -p "$OK_BIN"
cat > "$OK_BIN/psql" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    "SELECT 1 FROM pg_database"*) echo "1"; exit 0 ;;
  esac
done
exit 0
SH
chmod +x "$OK_BIN/psql"
PATH="$OK_BIN:/usr/bin:/bin" env -u PGADMIN_URL bash "$PREP" --issue 458 --base-url postgres://u:p@localhost/postgres --migrate-cmd "exit 9" > "$TMP_DIR/out.stdout" 2> "$TMP_DIR/out.stderr"
ec=$?
if [ "$ec" -ne 0 ]; then pass "failed migrate cmd exits non-zero"; else fail "failed migrate cmd exits non-zero"; fi
if grep -q "^VERIFY_DATABASE_URL=" "$TMP_DIR/out.stdout"; then
  fail "failed migrate must not print VERIFY_DATABASE_URL on stdout"
else
  pass "failed migrate must not print VERIFY_DATABASE_URL on stdout"
fi

# Case 9: base-url connection failure during the existence probe → non-zero
# exit and NO VERIFY_DATABASE_URL line (previously `|| true` swallowed it).
DEAD_BIN="$TMP_DIR/bin-conn-fail"
mkdir -p "$DEAD_BIN"
cat > "$DEAD_BIN/psql" <<'SH'
#!/usr/bin/env bash
echo "psql: connection refused" >&2
exit 2
SH
chmod +x "$DEAD_BIN/psql"
PATH="$DEAD_BIN:/usr/bin:/bin" env -u PGADMIN_URL bash "$PREP" --issue 459 --base-url postgres://u:p@localhost/postgres > "$TMP_DIR/out.stdout" 2> "$TMP_DIR/out.stderr"
ec=$?
if [ "$ec" -ne 0 ]; then pass "base-url connection failure exits non-zero"; else fail "base-url connection failure exits non-zero"; fi
if grep -q "^VERIFY_DATABASE_URL=" "$TMP_DIR/out.stdout"; then
  fail "connection failure must not print VERIFY_DATABASE_URL on stdout"
else
  pass "connection failure must not print VERIFY_DATABASE_URL on stdout"
fi

echo "---"
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASS"
  exit 0
else
  echo "$FAILURES CASE(S) FAILED"
  exit 1
fi
