#!/usr/bin/env bash
# Smoke test for scripts/codex-safe.sh argument validation only.
# bash-3.2-compatible. Run: bash scripts/__tests__/codex-safe.smoke.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CODEX_SAFE="$SCRIPT_DIR/../codex-safe.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
FAILURES=0

run_exit_case() {
  name="$1"; expected="$2"; shift 2
  bash "$CODEX_SAFE" "$@" >/dev/null 2>&1
  actual=$?
  if [ "$actual" -eq "$expected" ]; then
    echo "ok   - $name (exit $actual)"
  else
    echo "NOT OK - $name (expected exit $expected, got $actual)"
    FAILURES=$((FAILURES + 1))
  fi
}

run_nonzero_case() {
  name="$1"; shift
  bash "$CODEX_SAFE" "$@" >/dev/null 2>&1
  actual=$?
  if [ "$actual" -ne 0 ]; then
    echo "ok   - $name (exit $actual)"
  else
    echo "NOT OK - $name (expected non-zero exit, got 0)"
    FAILURES=$((FAILURES + 1))
  fi
}

run_exit_case "missing --issue exits 2" 2 --prompt "hello"
run_exit_case "missing prompt exits 2" 2 --issue 33
run_nonzero_case "unknown arg exits non-zero" --bogus

BIN="$TMP_DIR/bin"
WT="$TMP_DIR/wt"
mkdir -p "$BIN" "$WT"
cat > "$BIN/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$CODEX_STUB_ARGS"
exit 0
EOF
chmod +x "$BIN/codex"

run_stub_case() {
  name="$1"; expect_medium="$2"; shift 2
  args_file="$TMP_DIR/$name.args"
  CODEX_STUB_ARGS="$args_file" PATH="$BIN:$PATH" bash "$CODEX_SAFE" --issue 33 --prompt "hello" --cwd "$WT" "$@" >/dev/null 2>&1
  ec=$?
  if [ "$ec" -ne 0 ]; then
    echo "NOT OK - $name (expected exit 0, got $ec)"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if grep -q 'model_reasoning_effort="medium"' "$args_file"; then
    got_medium=1
  else
    got_medium=0
  fi
  if [ "$expect_medium" -eq "$got_medium" ]; then
    echo "ok   - $name"
  else
    echo "NOT OK - $name (medium pin expectation failed)"
    FAILURES=$((FAILURES + 1))
  fi
}

run_stub_case "gpt-5.6-omitted-effort-pins-medium" 1 --model gpt-5.6
run_stub_case "gpt-5.6-explicit-medium-passes" 1 --model gpt-5.6 --effort medium
run_stub_case "gpt-5.5-omitted-effort-does-not-pin" 0 --model gpt-5.5

CODEX_STUB_ARGS="$TMP_DIR/high.args" PATH="$BIN:$PATH" bash "$CODEX_SAFE" --issue 33 --prompt "hello" --cwd "$WT" --model gpt-5.6 --effort high >/dev/null 2>&1
high_ec=$?
if [ "$high_ec" -eq 2 ] && [ ! -f "$TMP_DIR/high.args" ]; then
  echo "ok   - gpt-5.6 high effort refused before codex call"
else
  echo "NOT OK - gpt-5.6 high effort refused before codex call (exit $high_ec)"
  FAILURES=$((FAILURES + 1))
fi

if grep -q -- '--sandbox workspace-write' "$CODEX_SAFE"; then
  echo "ok   - wrapper pins --sandbox workspace-write"
else
  echo "NOT OK - wrapper should contain --sandbox workspace-write"
  FAILURES=$((FAILURES + 1))
fi

# --- git worktree writable_roots (incident 2026-07-16) -----------------------
# workspace-write makes only --cd (and /tmp) writable. A git WORKTREE keeps its
# real gitdir in the MAIN repo's .git/worktrees/<name>, outside that root, so
# every `git commit` died with
#   fatal: Unable to create '.../.git/worktrees/<n>/index.lock': Operation not permitted
# Codex wrote whole chunks and committed nothing, seven runs straight, while
# exiting 0. The wrapper must grant the git common dir as a writable root.
GIT_MAIN="$TMP_DIR/gitmain"
mkdir -p "$GIT_MAIN"
(
  cd "$GIT_MAIN" || exit 1
  git init -q .
  git config user.email t@t
  git config user.name t
  echo seed > seed.txt
  git add -A
  git commit -qm seed
  git worktree add -q "$TMP_DIR/gitwt" -b probe
) >/dev/null 2>&1

if [ -d "$TMP_DIR/gitwt" ]; then
  args_file="$TMP_DIR/worktree.args"
  CODEX_STUB_ARGS="$args_file" PATH="$BIN:$PATH" bash "$CODEX_SAFE" \
    --issue 33 --prompt "hello" --cwd "$TMP_DIR/gitwt" >/dev/null 2>&1
  if grep -q 'writable_roots' "$args_file" 2>/dev/null && grep -q "$GIT_MAIN/.git" "$args_file" 2>/dev/null; then
    echo "ok   - worktree cwd grants git common dir as writable root"
  else
    echo "NOT OK - worktree cwd must pass writable_roots containing $GIT_MAIN/.git"
    FAILURES=$((FAILURES + 1))
  fi

  # A NON-worktree checkout keeps its gitdir inside --cd, so it needs nothing
  # extra; a redundant writable root would widen the sandbox for free.
  args_file="$TMP_DIR/plain.args"
  CODEX_STUB_ARGS="$args_file" PATH="$BIN:$PATH" bash "$CODEX_SAFE" \
    --issue 33 --prompt "hello" --cwd "$GIT_MAIN" >/dev/null 2>&1
  if grep -q 'writable_roots' "$args_file" 2>/dev/null; then
    echo "NOT OK - plain repo cwd must not widen the sandbox with writable_roots"
    FAILURES=$((FAILURES + 1))
  else
    echo "ok   - plain repo cwd passes no extra writable root"
  fi

  # A non-git cwd must still dispatch.
  args_file="$TMP_DIR/nongit.args"
  CODEX_STUB_ARGS="$args_file" PATH="$BIN:$PATH" bash "$CODEX_SAFE" \
    --issue 33 --prompt "hello" --cwd "$WT" >/dev/null 2>&1
  nongit_ec=$?
  if [ "$nongit_ec" -eq 0 ] && [ -f "$args_file" ]; then
    echo "ok   - non-git cwd still dispatches"
  else
    echo "NOT OK - non-git cwd should still dispatch (exit $nongit_ec)"
    FAILURES=$((FAILURES + 1))
  fi
else
  echo "NOT OK - could not build git worktree fixture"
  FAILURES=$((FAILURES + 1))
fi

echo "---"
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASS"
  exit 0
else
  echo "$FAILURES CASE(S) FAILED"
  exit 1
fi
