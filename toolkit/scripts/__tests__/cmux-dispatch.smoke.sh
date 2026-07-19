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

# --- watchdog flags are forwarded only when explicitly supplied ---
timeout_out="$TMP_ROOT/dry-run-timeouts.stdout"
bash "$DISPATCH" --issue 301 --worktree "$WT" --read-only --first-progress-timeout 1500 --stall-timeout 900 --dry-run >"$timeout_out" 2>&1
ec=$?
timeout_printed="$(cat "$timeout_out")"
if [ "$ec" -eq 0 ] && printf '%s\n' "$timeout_printed" | grep -q -- "--read-only" && printf '%s\n' "$timeout_printed" | grep -q -- "--first-progress-timeout 1500" && printf '%s\n' "$timeout_printed" | grep -q -- "--stall-timeout 900"; then
  pass "dry-run forwards combined read-only and watchdog timeout flags"
else
  fail "dry-run forwards combined read-only and watchdog timeout flags (ec=$ec: $timeout_printed)"
fi

if ! printf '%s\n' "$printed" | grep -q -- "--read-only" && ! printf '%s\n' "$printed" | grep -q -- "--first-progress-timeout" && ! printf '%s\n' "$printed" | grep -q -- "--stall-timeout"; then
  pass "dry-run omits read-only and watchdog timeout flags when unspecified"
else
  fail "dry-run omits read-only and watchdog timeout flags when unspecified (got: $printed)"
fi

usage_out="$TMP_ROOT/usage.stderr"
bash "$DISPATCH" > /dev/null 2>"$usage_out"
ec=$?
if [ "$ec" -ne 0 ] && grep -q -- "--first-progress-timeout" "$usage_out" && grep -q -- "--stall-timeout" "$usage_out"; then
  pass "usage mentions both watchdog timeout flags"
else
  fail "usage mentions both watchdog timeout flags (ec=$ec: $(cat "$usage_out"))"
fi

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

# --- poll path: a STALE RUN.json from a previous run must NOT count ---
# First production use hit this: re-dispatch of the same issue found the
# previous run's status:"exited" RUN.json and reported success immediately,
# before the new watchdog had even started.
STALE_WT="$TMP_ROOT/wt-stale"
mkdir -p "$STALE_WT/.review"
git init -q "$STALE_WT"
git -C "$STALE_WT" -c user.name="Smoke Test" -c user.email="smoke@example.test" commit --allow-empty -q -m "init"
printf '%s\n' "prompt body" > "$STALE_WT/.review/ISSUE-304-PROMPT.txt"
printf '%s\n' '{"schema_version":"1","artifact_type":"codex_run","issue":304,"attempt":1,"started_at":"2026-07-13T00:00:00Z","updated_at":"2026-07-13T00:00:00Z","status":"exited","exit_code":0}' > "$STALE_WT/.review/ISSUE-304-RUN.json"
# make the stale file's mtime clearly old
touch -t 202607130000 "$STALE_WT/.review/ISSUE-304-RUN.json" 2>/dev/null || true

# cmux stub that does NOTHING (watchdog never starts): stale file must not
# be accepted → dispatch must time out non-zero.
NOOP_BIN="$TMP_ROOT/bin-noop-cmux"
mkdir -p "$NOOP_BIN"
cat > "$NOOP_BIN/cmux" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$NOOP_BIN/cmux"
stale_out="$TMP_ROOT/stale-timeout.out"
CMUX_DISPATCH_POLL_INTERVAL=1 PATH="$NOOP_BIN:$PATH" bash "$DISPATCH" --issue 304 --worktree "$STALE_WT" --poll-timeout 2 >"$stale_out" 2>&1
ec=$?
if [ "$ec" -ne 0 ]; then
  pass "stale RUN.json alone is not accepted (dispatch times out non-zero)"
else
  fail "stale RUN.json alone is not accepted (got exit 0: $(cat "$stale_out"))"
fi
if grep -q "waiting for fresh RUN.json (stale one from 2026-07-13T00:00:00Z present)" "$stale_out"; then
  pass "stale RUN.json prints waiting-for-fresh notice with its started_at"
else
  fail "stale RUN.json prints waiting-for-fresh notice (got: $(cat "$stale_out"))"
fi

# cmux stub that writes a FRESH RUN.json (new started_at) on workspace create:
# dispatch must accept it and exit 0.
FRESH_BIN="$TMP_ROOT/bin-fresh-cmux"
mkdir -p "$FRESH_BIN"
cat > "$FRESH_BIN/cmux" <<EOF
#!/usr/bin/env bash
printf '%s\n' '{"schema_version":"1","artifact_type":"codex_run","issue":304,"attempt":1,"started_at":"2026-07-14T09:00:00Z","updated_at":"2026-07-14T09:00:00Z","status":"running"}' > "$STALE_WT/.review/ISSUE-304-RUN.json"
exit 0
EOF
chmod +x "$FRESH_BIN/cmux"
fresh_out="$TMP_ROOT/fresh-accept.out"
CMUX_DISPATCH_POLL_INTERVAL=1 PATH="$FRESH_BIN:$PATH" bash "$DISPATCH" --issue 304 --worktree "$STALE_WT" --poll-timeout 5 >"$fresh_out" 2>&1
ec=$?
if [ "$ec" -eq 0 ] && grep -q "fresh RUN.json present" "$fresh_out" && grep -q "status=running" "$fresh_out"; then
  pass "fresh RUN.json (new started_at) is accepted after a stale one"
else
  fail "fresh RUN.json (new started_at) is accepted after a stale one (ec=$ec: $(cat "$fresh_out"))"
fi

# stale BLOCKER.json must not be accepted either.
printf '%s\n' '{"artifact_type":"blocker","issue":305,"reason_code":"tier_escalation_required"}' > "$STALE_WT/.review/ISSUE-305-BLOCKER.json"
touch -t 202607130000 "$STALE_WT/.review/ISSUE-305-BLOCKER.json" 2>/dev/null || true
printf '%s\n' "prompt body" > "$STALE_WT/.review/ISSUE-305-PROMPT.txt"
blocker_out="$TMP_ROOT/stale-blocker.out"
CMUX_DISPATCH_POLL_INTERVAL=1 PATH="$NOOP_BIN:$PATH" bash "$DISPATCH" --issue 305 --worktree "$STALE_WT" --poll-timeout 2 >"$blocker_out" 2>&1
ec=$?
if [ "$ec" -ne 0 ] && grep -q "waiting past stale BLOCKER.json" "$blocker_out"; then
  pass "stale BLOCKER.json alone is not accepted"
else
  fail "stale BLOCKER.json alone is not accepted (ec=$ec: $(cat "$blocker_out"))"
fi

# no pre-existing artifact: a newly appearing RUN.json is still accepted
# (regression guard on the fresh-first-dispatch path).
printf '%s\n' "prompt body" > "$STALE_WT/.review/ISSUE-306-PROMPT.txt"
FRESH306_BIN="$TMP_ROOT/bin-fresh306-cmux"
mkdir -p "$FRESH306_BIN"
cat > "$FRESH306_BIN/cmux" <<EOF
#!/usr/bin/env bash
printf '%s\n' '{"schema_version":"1","artifact_type":"codex_run","issue":306,"attempt":1,"started_at":"2026-07-14T09:00:00Z","updated_at":"2026-07-14T09:00:00Z","status":"running"}' > "$STALE_WT/.review/ISSUE-306-RUN.json"
exit 0
EOF
chmod +x "$FRESH306_BIN/cmux"
first_out="$TMP_ROOT/first-dispatch.out"
CMUX_DISPATCH_POLL_INTERVAL=1 PATH="$FRESH306_BIN:$PATH" bash "$DISPATCH" --issue 306 --worktree "$STALE_WT" --poll-timeout 5 >"$first_out" 2>&1
ec=$?
if [ "$ec" -eq 0 ] && grep -q "fresh RUN.json present" "$first_out"; then
  pass "first dispatch with no pre-existing artifact still accepts a new RUN.json"
else
  fail "first dispatch with no pre-existing artifact still accepts a new RUN.json (ec=$ec: $(cat "$first_out"))"
fi

# --- codex-watchdog.sh: relative --prompt-file resolves against --cwd ---
WT_REL="$TMP_ROOT/wt-relative"
mkdir -p "$WT_REL/.review"
printf '%s\n' "prompt body" > "$WT_REL/.review/ISSUE-303-PROMPT.txt"
watchdog_out="$TMP_ROOT/watchdog-relative.out"
# no codex on PATH here: expect it to get PAST the existence check (prints the
# resolved-path echo line) and fail later trying to invoke codex-safe.sh —
# that later failure is expected and NOT what this case asserts on.
CODEX_WATCHDOG_PROBE_GAP=0 PATH="/usr/bin:/bin" bash "$WATCHDOG" --issue 303 --prompt-file ".review/ISSUE-303-PROMPT.txt" --cwd "$WT_REL" --max-retries 0 >"$watchdog_out" 2>&1
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
