#!/usr/bin/env bash
# Smoke test for scripts/prompt-ac-check.sh. Bash 3.2 compatible.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK="$SCRIPT_DIR/../prompt-ac-check.sh"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURE="$ROOT/schemas/fixtures/round_state.valid.json"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
FAILURES=0

pass() { echo "ok   - $1"; }
fail() { echo "NOT OK - $1"; FAILURES=$((FAILURES + 1)); }

BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD)"
BASE_SHA="$(git -C "$ROOT" merge-base HEAD "$BRANCH")"
STATE="$TMP_DIR/state.json"
cp "$FIXTURE" "$STATE"
node - "$STATE" "$ROOT" "$BRANCH" "$BASE_SHA" "$HEAD_SHA" <<'NODE'
const fs = require("fs");
const [file, root, branch, base, head] = process.argv.slice(2);
const value = JSON.parse(fs.readFileSync(file, "utf8"));
value.worktree_path = root;
value.base_branch = branch;
value.base_sha = base;
value.head_sha = head;
value.revision = 3;
value.acceptance.criteria = [
  {id: "AC-1", statement: "the first observable completion condition"},
  {id: "AC-2", statement: "the second observable completion condition"}
];
fs.writeFileSync(file, JSON.stringify(value));
NODE

write_prompt() {
  file="$1"
  payload="$2"
  printf '%s\n' 'worker instructions' '<!-- agent-workflow:ac-block:start -->' '```json' > "$file"
  printf '%s\n' "$payload" >> "$file"
  printf '%s\n' '```' '<!-- agent-workflow:ac-block:end -->' >> "$file"
}

assert_case() {
  name="$1"; expected="$2"; prompt="$3"; expected_text="$4"
  out="$TMP_DIR/$name.out"
  bash "$CHECK" --round-state "$STATE" --manifest-revision 3 --prompt-file "$prompt" >"$out" 2>&1
  ec=$?
  if [ "$ec" -eq "$expected" ] && { [ -z "$expected_text" ] || grep -F -q -- "$expected_text" "$out"; }; then
    pass "$name"
  else
    fail "$name (exit=$ec output=$(cat "$out"))"
  fi
}

write_prompt "$TMP_DIR/happy.md" '[{"id":"AC-1","statement":"the first observable completion condition"},{"id":"AC-2","statement":"the second observable completion condition"}]'
assert_case "exact canonical AC block passes" 0 "$TMP_DIR/happy.md" "OK revision 3: prompt AC block matches canonical ROUND-STATE"

write_prompt "$TMP_DIR/key-order.md" '[{"statement":"the first observable completion condition","id":"AC-1"},{"statement":"the second observable completion condition","id":"AC-2"}]'
assert_case "semantic object key order passes" 0 "$TMP_DIR/key-order.md" "OK revision 3: prompt AC block matches canonical ROUND-STATE"

write_prompt "$TMP_DIR/missing.md" '[{"id":"AC-1","statement":"the first observable completion condition"}]'
assert_case "missing canonical entry is rejected" 1 "$TMP_DIR/missing.md" "PROMPT_AC_MISMATCH"

write_prompt "$TMP_DIR/extra.md" '[{"id":"AC-1","statement":"the first observable completion condition"},{"id":"AC-2","statement":"the second observable completion condition"},{"id":"AC-3","statement":"extra"}]'
assert_case "extra prompt entry is rejected" 1 "$TMP_DIR/extra.md" "PROMPT_AC_MISMATCH"

write_prompt "$TMP_DIR/duplicate.md" '[{"id":"AC-1","statement":"the first observable completion condition"},{"id":"AC-1","statement":"the first observable completion condition"}]'
assert_case "duplicate prompt entry is rejected" 1 "$TMP_DIR/duplicate.md" "PROMPT_AC_MALFORMED"

write_prompt "$TMP_DIR/changed.md" '[{"id":"AC-1","statement":"changed wording"},{"id":"AC-2","statement":"the second observable completion condition"}]'
assert_case "changed AC wording is rejected" 1 "$TMP_DIR/changed.md" "PROMPT_AC_MISMATCH"

printf '%s\n' 'worker instructions only' > "$TMP_DIR/no-block.md"
assert_case "missing delimiters are rejected" 1 "$TMP_DIR/no-block.md" "PROMPT_AC_MALFORMED"

write_prompt "$TMP_DIR/malformed.md" '[{"id":"AC-1"}]'
assert_case "malformed entry is rejected" 1 "$TMP_DIR/malformed.md" "PROMPT_AC_MALFORMED"

if [ "$FAILURES" -eq 0 ]; then echo "ALL TESTS PASS"; exit 0; fi
echo "$FAILURES CASE(S) FAILED"
exit 1
