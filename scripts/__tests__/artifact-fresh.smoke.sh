#!/usr/bin/env bash
# Smoke test for scripts/artifact-fresh.sh — base_branch-aware staleness.
# bash-3.2-compatible. Run: bash scripts/__tests__/artifact-fresh.smoke.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRESH="$SCRIPT_DIR/../artifact-fresh.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAILURES=0

# --- build a real git repo with branch topology ---
REPO="$TMP_DIR/repo"
mkdir -p "$REPO"
(
  cd "$REPO" || exit 1
  git init -q
  git config user.email "smoke@test"
  git config user.name "smoke"
  git checkout -q -b base
  echo a > a.txt
  git add a.txt
  git commit -q -m "base commit"
) || { echo "repo setup failed"; exit 1; }

MB="$(cd "$REPO" && git rev-parse HEAD)"

(
  cd "$REPO" || exit 1
  git checkout -q -b feature
  echo b > b.txt
  git add b.txt
  git commit -q -m "feature commit"
) || { echo "feature setup failed"; exit 1; }

OTHER_SHA="0000000000000000000000000000000000000000"

write_json() {
  printf '%s' "$2" > "$TMP_DIR/$1"
  echo "$TMP_DIR/$1"
}

# run_case <name> <expected-exit> <artifact> [override]
run_case() {
  name="$1"; expected="$2"; artifact="$3"; override="${4:-}"
  if [ -n "$override" ]; then
    ( cd "$REPO" && bash "$FRESH" "$artifact" "$override" ) >/dev/null 2>"$TMP_DIR/err.txt"
  else
    ( cd "$REPO" && bash "$FRESH" "$artifact" ) >/dev/null 2>"$TMP_DIR/err.txt"
  fi
  actual=$?
  if [ "$actual" -eq "$expected" ]; then
    echo "ok   - $name (exit $actual)"
  else
    echo "NOT OK - $name (expected exit $expected, got $actual)"
    FAILURES=$((FAILURES + 1))
  fi
}

a_fresh=$(write_json fresh.json "{\"base_sha\":\"$MB\",\"base_branch\":\"base\"}")
a_stale=$(write_json stale.json "{\"base_sha\":\"$OTHER_SHA\",\"base_branch\":\"base\"}")
a_nobranch=$(write_json nobranch.json "{\"base_sha\":\"$MB\"}")
a_override=$(write_json override.json "{\"base_sha\":\"$MB\"}")
a_nosha=$(write_json nosha.json "{\"base_branch\":\"base\"}")

run_case "fresh: base_branch set, base_sha==MB"        0 "$a_fresh"
run_case "stale: base_branch set, base_sha!=MB"        1 "$a_stale"
run_case "no base_branch + no override refuses (2)"    2 "$a_nobranch"

# Case 3 also asserts stderr mentions refusing to assume.
( cd "$REPO" && bash "$FRESH" "$a_nobranch" ) >/dev/null 2>"$TMP_DIR/err.txt"
if grep -qi "refus" "$TMP_DIR/err.txt"; then
  echo "ok   - no-branch stderr mentions refusing"
else
  echo "NOT OK - no-branch stderr should mention refusing (got: $(cat "$TMP_DIR/err.txt"))"
  FAILURES=$((FAILURES + 1))
fi

run_case "override path: no base_branch but override arg" 0 "$a_override" "base"
run_case "no base_sha is error (2)"                    2 "$a_nosha"

echo "---"
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASS"
  exit 0
else
  echo "$FAILURES CASE(S) FAILED"
  exit 1
fi
