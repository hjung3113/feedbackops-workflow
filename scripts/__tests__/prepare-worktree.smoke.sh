#!/usr/bin/env bash
# Smoke test for scripts/prepare-worktree.sh env key reporting + redaction.
# Avoids the pnpm install path via the hidden --report-env-only mode.
# bash-3.2-compatible. Run: bash scripts/__tests__/prepare-worktree.smoke.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREP="$SCRIPT_DIR/../prepare-worktree.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAILURES=0

pass() { echo "ok   - $1"; }
fail() { echo "NOT OK - $1"; FAILURES=$((FAILURES + 1)); }

# --- fixture: env file mixing high-risk + benign keys ---
ENV_FILE="$TMP_DIR/.env"
{
  printf '%s\n' 'DATABASE_URL=postgres://secretuser:secretpass@db.internal/prod'
  printf '%s\n' 'LOG_LEVEL=info'
  printf '%s\n' 'WORKSPACE_ID=ws_supersecret_123'
  printf '%s\n' 'API_TOKEN=tok_should_never_print'
  printf '%s\n' '# a comment line that is not a key'
  printf '%s\n' 'PORT=3000'
  printf '%s\n' 'database_url=postgres://lc_secret@db/lc'
  printf '%s\n' 'aws_s3_bucket=lc-bucket-name'
} > "$ENV_FILE"

OUT="$(bash "$PREP" --report-env-only "$ENV_FILE" 2>&1)"

# Case 1: DATABASE_URL flagged as high-risk
case "$OUT" in
  *"high-risk env key copied: DATABASE_URL"*) pass "DATABASE_URL flagged high-risk" ;;
  *) fail "DATABASE_URL flagged high-risk" ;;
esac

# Case 2: benign LOG_LEVEL key printed (but NOT high-risk-flagged)
case "$OUT" in
  *LOG_LEVEL*) pass "benign LOG_LEVEL key printed" ;;
  *) fail "benign LOG_LEVEL key printed" ;;
esac

# Case 3: secret VALUEs never printed (redaction)
leaked=0
for secret in secretpass secretuser ws_supersecret_123 tok_should_never_print lc_secret lc-bucket-name "postgres://"; do
  case "$OUT" in
    *"$secret"*) echo "    LEAKED: $secret" >&2; leaked=1 ;;
  esac
done
if [ "$leaked" -eq 0 ]; then pass "no secret values printed (redacted)"; else fail "no secret values printed (redacted)"; fi

# Case 4: WORKSPACE_ID, token, PORT also flagged high-risk
for hk in WORKSPACE_ID API_TOKEN PORT; do
  case "$OUT" in
    *"high-risk env key copied: $hk"*) pass "$hk flagged high-risk" ;;
    *) fail "$hk flagged high-risk" ;;
  esac
done

# Case 4b: lowercase/mixed-case keys flagged high-risk (regression: classifier
# was uppercase-only, so database_url / aws_s3_bucket slipped through as benign).
for hk in database_url aws_s3_bucket; do
  case "$OUT" in
    *"high-risk env key copied: $hk"*) pass "lowercase $hk flagged high-risk" ;;
    *) fail "lowercase $hk flagged high-risk" ;;
  esac
done

# Case 5: comment line not treated as a key
case "$OUT" in
  *"a comment line"*) fail "comment line ignored" ;;
  *) pass "comment line ignored" ;;
esac

# Case 6: non-existent worktree path exits non-zero
bash "$PREP" "$TMP_DIR/does-not-exist-worktree" >/dev/null 2>&1
ec=$?
if [ "$ec" -ne 0 ]; then pass "missing worktree path exits non-zero (got $ec)"; else fail "missing worktree path exits non-zero (got $ec)"; fi

# --- Case 7: shared-env guard threshold (off-by-one regression RF4) ---
# The guard must refuse to copy shared env when ANY other prepared worktree
# already exists (>=1), not only when >1. Driven via the hidden
# --check-shared-env-guard <count> mode so no pnpm install runs.
guard() { bash "$PREP" --check-shared-env-guard "$@" 2>&1; }

# 0 others → ALLOW even with no flag (first worktree is fine).
case "$(guard 0)" in
  ALLOW) pass "guard: 0 others → ALLOW (no flag)" ;;
  *) fail "guard: 0 others → ALLOW (no flag) [got: $(guard 0)]" ;;
esac

# 1 other → REFUSE without a flag (this is the off-by-one being fixed).
case "$(guard 1)" in
  REFUSE) pass "guard: 1 other → REFUSE (no flag)" ;;
  *) fail "guard: 1 other → REFUSE (no flag) [got: $(guard 1)]" ;;
esac

# 1 other + --allow-shared-env → ALLOW (explicit override).
case "$(guard 1 --allow-shared-env)" in
  ALLOW) pass "guard: 1 other + --allow-shared-env → ALLOW" ;;
  *) fail "guard: 1 other + --allow-shared-env → ALLOW [got: $(guard 1 --allow-shared-env)]" ;;
esac

# 1 other + --env-profile → ALLOW (per-worktree env file).
case "$(guard 1 --env-profile "$ENV_FILE")" in
  ALLOW) pass "guard: 1 other + --env-profile → ALLOW" ;;
  *) fail "guard: 1 other + --env-profile → ALLOW [got: $(guard 1 --env-profile "$ENV_FILE")]" ;;
esac

# 2 others → REFUSE without a flag (unchanged behaviour).
case "$(guard 2)" in
  REFUSE) pass "guard: 2 others → REFUSE (no flag)" ;;
  *) fail "guard: 2 others → REFUSE (no flag) [got: $(guard 2)]" ;;
esac

echo "---"
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASS"
  exit 0
else
  echo "$FAILURES CASE(S) FAILED"
  exit 1
fi
