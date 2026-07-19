#!/usr/bin/env bash
# Smoke test for scripts/completion-check.sh.
# bash-3.2-compatible. Run: bash scripts/__tests__/completion-check.smoke.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK="$SCRIPT_DIR/../completion-check.sh"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURE="$ROOT/schemas/fixtures/round_state.valid.json"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAILURES=0

assert_case() {
  name="$1"; expected="$2"; state="$3"; expected_code="$4"
  output="$TMP_DIR/output.json"
  ( bash "$CHECK" --round-state "$state" --manifest-revision 3 ) >"$output" 2>/dev/null
  actual=$?
  if [ "$actual" -ne "$expected" ]; then
    echo "NOT OK - $name (expected exit $expected, got $actual)"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if node -e 'const v=require(process.argv[1]); process.exit(v.mismatches.some((m) => m.code === process.argv[2]) ? 0 : 1)' "$output" "$expected_code"; then
    echo "ok   - $name"
  else
    echo "NOT OK - $name (missing mismatch $expected_code)"
    FAILURES=$((FAILURES + 1))
  fi
}

WORKTREE="$TMP_DIR/worktree"
git init -q "$WORKTREE"
git -C "$WORKTREE" config user.email smoke@example.test
git -C "$WORKTREE" config user.name smoke
mkdir -p "$WORKTREE/allowed"
printf 'base\n' > "$WORKTREE/allowed/file.txt"
git -C "$WORKTREE" add allowed/file.txt
git -C "$WORKTREE" commit -qm base
git -C "$WORKTREE" branch -M main
BASE_SHA="$(git -C "$WORKTREE" rev-parse HEAD)"
git -C "$WORKTREE" switch -q -c feat/completion-smoke
printf 'changed\n' >> "$WORKTREE/allowed/file.txt"
git -C "$WORKTREE" commit -am allowed-change -q

cp "$FIXTURE" "$TMP_DIR/state.json"
node -e '
  const fs = require("fs");
  const [file, worktree, base] = process.argv.slice(1);
  const v = JSON.parse(fs.readFileSync(file, "utf8"));
  v.revision = 3; v.base_branch = "main"; v.base_sha = base;
  v.worktree_path = worktree; v.contract.touch_allowlist = ["allowed/**"];
  v.acceptance.criteria = [{id: "AC-1"}]; v.acceptance.expected_test_count = 1;
  v.contract.test_discovery_command = "printf '\''AC-1\\n'\''";
  v.decisions = []; v.commit_scope.commits = [];
  fs.writeFileSync(file, JSON.stringify(v));
' "$TMP_DIR/state.json" "$WORKTREE" "$BASE_SHA"
( bash "$CHECK" --round-state "$TMP_DIR/state.json" --manifest-revision 3 ) > "$TMP_DIR/pass.json" 2>/dev/null
if [ "$?" -eq 0 ] && node -e 'const v=require(process.argv[1]); process.exit(v.status === "pass" && v.mismatches.length === 0 ? 0 : 1)' "$TMP_DIR/pass.json"; then
  echo "ok   - completion passes for allowed diff and discovered AC"
else
  echo "NOT OK - completion happy path"
  FAILURES=$((FAILURES + 1))
fi

mkdir -p "$WORKTREE/unpromised"
printf 'surprise\n' > "$WORKTREE/unpromised/file.txt"
git -C "$WORKTREE" add unpromised/file.txt
git -C "$WORKTREE" commit -qm unpromised-change
assert_case "rejects changed path outside allowlist" 1 "$TMP_DIR/state.json" "changed_path_outside_allowlist"

node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.contract.test_discovery_command="printf '\''different test\\n'\''"; fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/state.json"
assert_case "rejects undiscovered acceptance criterion" 1 "$TMP_DIR/state.json" "acceptance_not_discovered"

node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.contract.test_discovery_command="printf '\''AC-1\\n'\''"; v.acceptance.expected_test_count=2; fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/state.json"
assert_case "rejects unexpected discovered test count" 1 "$TMP_DIR/state.json" "unexpected_discovered_test_count"

node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); delete v.acceptance.expected_test_count; fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/state.json"
( bash "$CHECK" --round-state "$TMP_DIR/state.json" --manifest-revision 3 ) > "$TMP_DIR/error.json" 2>/dev/null
if [ "$?" -eq 2 ] && node -e 'const v=require(process.argv[1]); process.exit(v.status === "error" && v.mismatches[0].code === "invalid_round_state" ? 0 : 1)' "$TMP_DIR/error.json"; then
  echo "ok   - invalid ROUND-STATE has machine-readable error"
else
  echo "NOT OK - invalid ROUND-STATE machine-readable error"
  FAILURES=$((FAILURES + 1))
fi

node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.acceptance.expected_test_count=1; v.contract.test_discovery_command="false"; fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/state.json"
( bash "$CHECK" --round-state "$TMP_DIR/state.json" --manifest-revision 3 ) > "$TMP_DIR/discovery-error.json" 2>/dev/null
if [ "$?" -eq 2 ] && node -e 'const v=require(process.argv[1]); process.exit(v.status === "error" && v.mismatches[0].code === "test_discovery_failed" ? 0 : 1)' "$TMP_DIR/discovery-error.json"; then
  echo "ok   - failed discovery has machine-readable error"
else
  echo "NOT OK - failed discovery machine-readable error"
  FAILURES=$((FAILURES + 1))
fi

echo "---"
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASS"
  exit 0
fi
echo "$FAILURES CASE(S) FAILED"
exit 1
