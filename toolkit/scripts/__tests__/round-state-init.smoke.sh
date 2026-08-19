#!/usr/bin/env bash
# Smoke test for scripts/round-state-init.sh. Bash 3.2 compatible.
# Uses the shared #164 stub argv-capture contract for the gh stub.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/stub-argv.sh"
INIT="$SCRIPT_DIR/../round-state-init.sh"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
FAILURES=0

pass() { echo "ok   - $1"; }
fail() { echo "NOT OK - $1"; FAILURES=$((FAILURES + 1)); }

make_stub_capture_helper "$TMP_DIR/stub-capture.sh"
export STUB_CAPTURE_HELPER="$TMP_DIR/stub-capture.sh"
export STUB_ARGS_LOG="$TMP_DIR/gh-args.log"
: > "$STUB_ARGS_LOG"

BIN_DIR="$TMP_DIR/bin"
mkdir -p "$BIN_DIR"
cat > "$BIN_DIR/gh" <<'EOF'
#!/usr/bin/env bash
. "$STUB_CAPTURE_HELPER"
if [ -n "${GH_STUB_FAIL:-}" ]; then echo "gh: stub failure" >&2; exit 1; fi
cat "${GH_STUB_JSON:?}"
EOF
chmod +x "$BIN_DIR/gh"

write_gh_json() {
  GH_STUB_JSON="$TMP_DIR/gh-$1.json"
  export GH_STUB_JSON
}

# Real temp git repo + linked worktree: main -> feature(+commit) -> worktree.
REPO="$TMP_DIR/repo"
WT="$TMP_DIR/wt"
git init -q "$REPO"
git -C "$REPO" config user.email smoke@test.local
git -C "$REPO" config user.name smoke
git -C "$REPO" checkout -q -b main
echo seed > "$REPO/file.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -qm seed
git -C "$REPO" checkout -q -b feature
echo more > "$REPO/file.txt"
git -C "$REPO" commit -qam more
git -C "$REPO" worktree add -q "$WT" -b wtbranch feature
BASE_SHA="$(git -C "$WT" merge-base HEAD main)"
HEAD_SHA="$(git -C "$WT" rev-parse HEAD)"
WT_ABS="$(cd "$WT" && pwd)"

run_init() {
  PATH="$BIN_DIR:$PATH" bash "$1" "${2:-159}" --worktree "$WT" >"$TMP_DIR/init.out" 2>"$TMP_DIR/init.err"
}

state_value() {
  node -e 'const s=require(process.argv[1]); console.log(JSON.stringify(eval("s"+process.argv[2])))' "$1" "$2"
}

# --- happy path: AC heading with -, *, and numbered items ---------------
write_gh_json happy
cat > "$GH_STUB_JSON" <<'EOF'
{"number":159,"title":"scaffold round-state","body":"## 개요\ntext\n- not extracted (no AC heading)\n\n## AC\n- first criterion\n* second criterion\n1. third criterion\n\n## 검증\n- korean fallback item"}
EOF
STATE="$WT/.review/ISSUE-159-ROUND-STATE.json"
run_init "$INIT"
ec=$?
if [ "$ec" -eq 0 ] && [ -f "$STATE" ]; then
  pass "happy path writes ROUND-STATE"
else
  fail "happy path writes ROUND-STATE (exit=$ec stderr=$(cat "$TMP_DIR/init.err"))"
fi
happy_ok=1
[ "$(state_value "$STATE" .base_branch)" = '"main"' ] || happy_ok=0
[ "$(state_value "$STATE" .base_sha)" = "\"$BASE_SHA\"" ] || happy_ok=0
[ "$(state_value "$STATE" .head_sha)" = "\"$HEAD_SHA\"" ] || happy_ok=0
[ "$(state_value "$STATE" .worktree_path)" = "\"$WT_ABS\"" ] || happy_ok=0
[ "$(state_value "$STATE" .lifecycle)" = '"active"' ] || happy_ok=0
[ "$(state_value "$STATE" .revision)" = '1' ] || happy_ok=0
[ "$(state_value "$STATE" .producer_role)" = '"CONDUCTOR"' ] || happy_ok=0
[ "$(state_value "$STATE" .issue.title)" = '"scaffold round-state"' ] || happy_ok=0
if [ "$happy_ok" -eq 1 ]; then pass "scaffold binds base/head/worktree/canonical fields"; else fail "scaffold binds base/head/worktree/canonical fields"; fi

crit_ok=1
[ "$(state_value "$STATE" '.acceptance.criteria.length')" = '3' ] || crit_ok=0
[ "$(state_value "$STATE" '.acceptance.criteria[0].id')" = '"AC-159-1"' ] || crit_ok=0
[ "$(state_value "$STATE" '.acceptance.criteria[0].statement')" = '"first criterion"' ] || crit_ok=0
[ "$(state_value "$STATE" '.acceptance.criteria[2].statement')" = '"third criterion"' ] || crit_ok=0
if [ "$crit_ok" -eq 1 ]; then pass "AC extraction finds -, *, and numbered items under AC heading"; else fail "AC extraction finds -, *, and numbered items under AC heading"; fi

if node - "$STATE" "$SCRIPT_DIR/../lib/contract-validators.cjs" <<'NODE'
const fs = require("fs");
const state = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const { schema, validate } = require(process.argv[3]).loadSchema("round_state.schema.json");
const errors = validate(schema, state);
if (errors.length) { console.error(errors); process.exit(1); }
NODE
then pass "produced file validates against round_state.schema.json"; else fail "produced file validates against round_state.schema.json"; fi

# --- #164 stub argv capture: exact gh argv -------------------------------
if grep -F -q -- 'issue view 159 --json number,title,body' "$STUB_ARGS_LOG"; then
  pass "gh stub captured exact issue-view argv"
else
  fail "gh stub captured exact issue-view argv (log=$(cat "$STUB_ARGS_LOG"))"
fi
# Mutation check: a token-glued argv (reverted/space-lost flag value) must
# NOT satisfy the same adjacent-pair grep, proving the grep has teeth.
mutated_argv='issue view 159 --jsonnumber,title,body'
if ! printf '%s\n' "$mutated_argv" | grep -F -q -- '--json number,title,body'; then
  pass "#164 gh argv mutation check rejects glued --json value"
else
  fail "#164 gh argv mutation check accepted a glued --json value"
fi

# --- Korean 검증 fallback ------------------------------------------------
write_gh_json korean
cat > "$GH_STUB_JSON" <<'EOF'
{"number":159,"title":"korean body","body":"## 배경\n- 무시 항목\n\n## 검증\n- 첫 번째 항목\n- 두 번째 항목"}
EOF
K_STATE="$TMP_DIR/korean-state.json"
PATH="$BIN_DIR:$PATH" bash "$INIT" 159 --worktree "$WT" --out "$K_STATE" >/dev/null 2>&1
k_ok=1
[ "$(state_value "$K_STATE" '.acceptance.criteria.length')" = '2' ] || k_ok=0
[ "$(state_value "$K_STATE" '.acceptance.criteria[0].statement')" = '"첫 번째 항목"' ] || k_ok=0
[ "$(state_value "$K_STATE" '.acceptance.criteria[1].id')" = '"AC-159-2"' ] || k_ok=0
if [ "$k_ok" -eq 1 ]; then pass "검증 heading fallback extracts items"; else fail "검증 heading fallback extracts items"; fi

# --- no matching heading: placeholder + WARNING ---------------------------
write_gh_json none
cat > "$GH_STUB_JSON" <<'EOF'
{"number":159,"title":"no ac here","body":"## 배경\n설명만 있습니다."}
EOF
P_STATE="$TMP_DIR/none-state.json"
PATH="$BIN_DIR:$PATH" bash "$INIT" 159 --worktree "$WT" --out "$P_STATE" >"$TMP_DIR/none.out" 2>"$TMP_DIR/none.err"
ec=$?
p_ok=1
[ "$ec" -eq 0 ] || p_ok=0
[ "$(state_value "$P_STATE" '.acceptance.criteria.length')" = '1' ] || p_ok=0
[ "$(state_value "$P_STATE" '.acceptance.criteria[0].id')" = '"AC-159-1"' ] || p_ok=0
[ "$(state_value "$P_STATE" '.acceptance.criteria[0].statement')" = '"TODO: fill in acceptance criteria"' ] || p_ok=0
grep -F -q 'WARNING' "$TMP_DIR/none.err" || p_ok=0
grep -F -q 'TODO placeholder' "$TMP_DIR/none.err" || p_ok=0
if [ "$p_ok" -eq 1 ]; then pass "no-match body yields placeholder criterion + WARNING"; else fail "no-match body yields placeholder criterion + WARNING (exit=$ec err=$(cat "$TMP_DIR/none.err"))"; fi

# --- refuse overwrite without --force ------------------------------------
BEFORE="$(git hash-object "$STATE")"
PATH="$BIN_DIR:$PATH" bash "$INIT" 159 --worktree "$WT" >"$TMP_DIR/ow.out" 2>"$TMP_DIR/ow.err"
ec=$?
AFTER="$(git hash-object "$STATE")"
if [ "$ec" -ne 0 ] && [ "$BEFORE" = "$AFTER" ] && grep -F -q 'refusing to overwrite' "$TMP_DIR/ow.err"; then
  pass "refuses to overwrite existing ROUND-STATE without --force"
else
  fail "refuses to overwrite existing ROUND-STATE without --force (exit=$ec err=$(cat "$TMP_DIR/ow.err"))"
fi
write_gh_json happy2
cat > "$GH_STUB_JSON" <<'EOF'
{"number":159,"title":"scaffold round-state","body":"## AC\n- first criterion\n* second criterion\n1. third criterion"}
EOF
run_init_force() {
  PATH="$BIN_DIR:$PATH" bash "$INIT" 159 --worktree "$WT" --force >/dev/null 2>&1
}
if run_init_force && [ "$(state_value "$STATE" .issue.title)" = '"scaffold round-state"' ]; then
  pass "--force overwrites the existing file"
else
  fail "--force overwrites the existing file"
fi

# --- gh failure: non-zero, no file written -------------------------------
write_gh_json fail
GH_STUB_FAIL=1
export GH_STUB_FAIL
N_STATE="$TMP_DIR/ghfail-state.json"
PATH="$BIN_DIR:$PATH" bash "$INIT" 159 --worktree "$WT" --out "$N_STATE" >/dev/null 2>"$TMP_DIR/ghfail.err"
ec=$?
unset GH_STUB_FAIL
if [ "$ec" -ne 0 ] && [ ! -e "$N_STATE" ] && grep -F -q 'gh issue view 159 failed' "$TMP_DIR/ghfail.err"; then
  pass "gh failure exits non-zero without writing a file"
else
  fail "gh failure exits non-zero without writing a file (exit=$ec err=$(cat "$TMP_DIR/ghfail.err"))"
fi

# --- mutation check on the script itself ---------------------------------
# Mutation: break head_sha by resolving HEAD^ instead of HEAD in a script
# copy mirrored over symlinked lib/ and schemas/. The happy-path head_sha
# binding assertion must reject the mutated scaffold (its head_sha equals
# the seed/base commit, not the worktree HEAD).
MUT_ROOT="$TMP_DIR/mut-root"
mkdir -p "$MUT_ROOT/scripts"
ln -s "$SCRIPT_DIR/../lib" "$MUT_ROOT/scripts/lib"
ln -s "$ROOT/schemas" "$MUT_ROOT/schemas"
sed 's|git -C "$worktree" rev-parse HEAD|git -C "$worktree" rev-parse HEAD^|' "$INIT" > "$MUT_ROOT/scripts/init-mutated.sh"
write_gh_json mut
cat > "$GH_STUB_JSON" <<'EOF'
{"number":159,"title":"mutation","body":"## AC\n- criterion"}
EOF
M_STATE="$TMP_DIR/mutated-state.json"
PATH="$BIN_DIR:$PATH" bash "$MUT_ROOT/scripts/init-mutated.sh" 159 --worktree "$WT" --out "$M_STATE" >/dev/null 2>"$TMP_DIR/mut.err"
if [ "$(state_value "$M_STATE" .head_sha)" != "\"$HEAD_SHA\"" ]; then
  pass "mutation check: broken head_sha resolution is rejected by the binding assertion"
else
  fail "mutation check: mutated script produced the correct head_sha (assertion has no teeth)"
fi

if [ "$FAILURES" -eq 0 ]; then echo "ALL TESTS PASS"; exit 0; fi
echo "$FAILURES CASE(S) FAILED"
exit 1
