#!/usr/bin/env bash
# Smoke test for scripts/cmux-dispatch.sh (and the codex-watchdog.sh
# relative --prompt-file resolution it depends on).
# Offline: never touches a real cmux binary (only --dry-run paths and
# early-guard failure paths exercise cmux-dispatch.sh; watchdog resolution
# is exercised directly against codex-watchdog.sh).
# bash-3.2-compatible. Run: bash scripts/__tests__/cmux-dispatch.smoke.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DISPATCH="$SCRIPT_DIR/../cmux-dispatch.sh"
WATCHDOG="$SCRIPT_DIR/../codex-watchdog.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

FAILURES=0
pass() { echo "ok   - $1"; }
fail() { echo "NOT OK - $1"; FAILURES=$((FAILURES + 1)); }

# --- setup: a real git worktree with a prompt file ---
WT="$TMP_ROOT/wt"
mkdir -p "$WT/.review"
git init -q "$WT"
git -C "$WT" -c user.name="Smoke Test" -c user.email="smoke@example.test" commit --allow-empty -q -m "init"
printf '%s\n' "prompt body" > "$WT/.review/ISSUE-301-PROMPT.txt"

# --- missing worktree ---
NOT_A_DIR="$TMP_ROOT/does-not-exist"
stderr_file="$TMP_ROOT/missing-worktree.stderr"
bash "$DISPATCH" --issue 301 --worktree "$NOT_A_DIR" --dry-run >/dev/null 2>"$stderr_file"
ec=$?
if [ "$ec" -ne 0 ] && grep -q "worktree does not exist" "$stderr_file"; then
  pass "missing worktree is non-zero with message"
else
  fail "missing worktree is non-zero with message (ec=$ec)"
fi

# --- worktree exists but isn't a git worktree ---
NOT_GIT="$TMP_ROOT/not-a-git-dir"
mkdir -p "$NOT_GIT"
stderr_file="$TMP_ROOT/not-git.stderr"
bash "$DISPATCH" --issue 301 --worktree "$NOT_GIT" --dry-run >/dev/null 2>"$stderr_file"
ec=$?
if [ "$ec" -ne 0 ] && grep -q "not a git worktree" "$stderr_file"; then
  pass "non-git worktree is non-zero with message"
else
  fail "non-git worktree is non-zero with message (ec=$ec)"
fi

# --- missing prompt file (default path, none written) ---
WT_NO_PROMPT="$TMP_ROOT/wt-no-prompt"
mkdir -p "$WT_NO_PROMPT"
git init -q "$WT_NO_PROMPT"
git -C "$WT_NO_PROMPT" -c user.name="Smoke Test" -c user.email="smoke@example.test" commit --allow-empty -q -m "init"
stderr_file="$TMP_ROOT/missing-prompt.stderr"
bash "$DISPATCH" --issue 302 --worktree "$WT_NO_PROMPT" --dry-run >/dev/null 2>"$stderr_file"
ec=$?
if [ "$ec" -ne 0 ] && grep -q "prompt file not found" "$stderr_file"; then
  pass "missing prompt file is non-zero with message"
else
  fail "missing prompt file is non-zero with message (ec=$ec)"
fi

# --- dry-run happy path ---
out_file="$TMP_ROOT/dry-run.stdout"
bash "$DISPATCH" --issue 301 --worktree "$WT" --dry-run >"$out_file" 2>&1
ec=$?
printed="$(cat "$out_file")"
if [ "$ec" -eq 0 ]; then pass "dry-run exits 0"; else fail "dry-run exits 0 (got $ec)"; fi

case "$printed" in
  *"--cwd $WT"*) pass "dry-run command contains absolute --cwd worktree" ;;
  *) fail "dry-run command contains absolute --cwd worktree (got: $printed)" ;;
esac
case "$printed" in
  *"--prompt-file $WT/.review/ISSUE-301-PROMPT.txt"*) pass "dry-run command contains absolute prompt path" ;;
  *) fail "dry-run command contains absolute prompt path (got: $printed)" ;;
esac
case "$printed" in
  *"NODE_OPTIONS="*) pass "dry-run command clears NODE_OPTIONS" ;;
  *) fail "dry-run command clears NODE_OPTIONS (got: $printed)" ;;
esac
case "$printed" in
  *"cmux workspace create"*) pass "dry-run uses cmux workspace create" ;;
  *) fail "dry-run uses cmux workspace create (got: $printed)" ;;
esac

# --- dry-run does not call the real cmux binary ---
BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"
cat > "$BIN/cmux" <<'EOF'
#!/usr/bin/env bash
echo "CMUX WAS CALLED" >&2
exit 1
EOF
chmod +x "$BIN/cmux"
PATH="$BIN:$PATH" bash "$DISPATCH" --issue 301 --worktree "$WT" --dry-run >/dev/null 2>"$TMP_ROOT/no-call.stderr"
ec=$?
if [ "$ec" -eq 0 ] && ! grep -q "CMUX WAS CALLED" "$TMP_ROOT/no-call.stderr"; then
  pass "dry-run never invokes cmux"
else
  fail "dry-run never invokes cmux"
fi

# --- codex-watchdog.sh: relative --prompt-file resolves against --cwd ---
WT_REL="$TMP_ROOT/wt-relative"
mkdir -p "$WT_REL/.review"
printf '%s\n' "prompt body" > "$WT_REL/.review/ISSUE-303-PROMPT.txt"
watchdog_out="$TMP_ROOT/watchdog-relative.out"
# no codex on PATH here: expect it to get PAST the existence check (prints the
# resolved-path echo line) and fail later trying to invoke codex-safe.sh —
# that later failure is expected and NOT what this case asserts on.
PATH="/usr/bin:/bin" bash "$WATCHDOG" --issue 303 --prompt-file ".review/ISSUE-303-PROMPT.txt" --cwd "$WT_REL" --max-retries 0 >"$watchdog_out" 2>&1
if grep -q "prompt-file=$WT_REL/.review/ISSUE-303-PROMPT.txt" "$watchdog_out"; then
  pass "watchdog resolves relative prompt-file against --cwd"
else
  fail "watchdog resolves relative prompt-file against --cwd (got: $(cat "$watchdog_out"))"
fi
if ! grep -q "prompt file not found" "$watchdog_out"; then
  pass "watchdog does not report missing prompt file for the resolved path"
else
  fail "watchdog does not report missing prompt file for the resolved path"
fi

echo "---"
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASS"
  exit 0
else
  echo "$FAILURES CASE(S) FAILED"
  exit 1
fi
