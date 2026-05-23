#!/usr/bin/env bash
# Smoke test for scripts/tier-probe.sh.
# Builds throwaway git repos so git diff/git show behave realistically.
# bash-3.2-compatible. Run: bash scripts/__tests__/tier-probe.smoke.sh
#
# Exit-code contract under test:
#   1 = Trivial DISALLOWED (escalate)
#   0 = Trivial permissible
#   2 = usage error
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROBE="$SCRIPT_DIR/../tier-probe.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

FAILURES=0
CASE_NUM=0

# fresh_repo — make an isolated git repo, echo its path.
fresh_repo() {
  CASE_NUM=$((CASE_NUM + 1))
  repo="$TMP_ROOT/repo$CASE_NUM"
  mkdir -p "$repo"
  (
    cd "$repo" || exit 1
    git init -q
    git config user.email t@t.test
    git config user.name tester
  )
  echo "$repo"
}

# assert_exit <name> <expected-code> <repo> <file...>
assert_exit() {
  name="$1"; expected="$2"; repo="$3"; shift 3
  ( cd "$repo" && bash "$PROBE" "$@" ) >/dev/null 2>&1
  actual=$?
  if [ "$actual" -eq "$expected" ]; then
    echo "ok   - $name (expected $expected, got $actual)"
  else
    echo "NOT OK - $name (expected $expected, got $actual)"
    FAILURES=$((FAILURES + 1))
  fi
}

# --- Case 1: exported interface signature change -> DISALLOW (1) ---
r=$(fresh_repo)
printf '%s\n' 'export interface User { id: number; }' > "$r/user.ts"
( cd "$r" && git add user.ts && git commit -qm base )
printf '%s\n' 'export interface User { id: string; name: string; }' > "$r/user.ts"
assert_exit "exported interface signature change -> DISALLOW" 1 "$r" user.ts

# --- Case 2: internal non-export .ts, comment only -> permissible (0) ---
r=$(fresh_repo)
printf '%s\n' 'function helper() { return 1; }' > "$r/helper.ts"
( cd "$r" && git add helper.ts && git commit -qm base )
printf '%s\n%s\n' '// a new note' 'function helper() { return 1; }' > "$r/helper.ts"
assert_exit "internal non-export .ts comment only -> permissible" 0 "$r" helper.ts

# --- Case 3: file HAS exports, diff is real change to non-export line -> DISALLOW (catch-all) ---
r=$(fresh_repo)
printf '%s\n%s\n' 'export const NAME = "x";' 'let internal = 1;' > "$r/mod.ts"
( cd "$r" && git add mod.ts && git commit -qm base )
printf '%s\n%s\n' 'export const NAME = "x";' 'let internal = 999;' > "$r/mod.ts"
assert_exit "exported file, real non-export code change -> DISALLOW (catch-all)" 1 "$r" mod.ts

# --- Case 4: index.ts barrel touched at all -> DISALLOW (1) ---
r=$(fresh_repo)
mkdir -p "$r/pkg"
printf '%s\n' 'export * from "./a";' > "$r/pkg/index.ts"
( cd "$r" && git add pkg/index.ts && git commit -qm base )
printf '%s\n%s\n' 'export * from "./a";' 'export * from "./b";' > "$r/pkg/index.ts"
assert_exit "index.ts barrel touched -> DISALLOW" 1 "$r" pkg/index.ts

# --- Case 5: non-TS file (README.md) changed -> permissible (0) ---
r=$(fresh_repo)
printf '%s\n' '# Title' > "$r/README.md"
( cd "$r" && git add README.md && git commit -qm base )
printf '%s\n%s\n' '# Title' 'new line' > "$r/README.md"
assert_exit "non-TS file changed -> permissible" 0 "$r" README.md

# --- Case 6: file with exports, ONLY diff is a comment line -> permissible (0) ---
r=$(fresh_repo)
printf '%s\n' 'export const VALUE = 42;' > "$r/const.ts"
( cd "$r" && git add const.ts && git commit -qm base )
printf '%s\n%s\n' '// document the value' 'export const VALUE = 42;' > "$r/const.ts"
assert_exit "exported file, comment-only diff -> permissible (provably comment-only)" 0 "$r" const.ts

echo "---"
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASS"
  exit 0
else
  echo "$FAILURES CASE(S) FAILED"
  exit 1
fi
