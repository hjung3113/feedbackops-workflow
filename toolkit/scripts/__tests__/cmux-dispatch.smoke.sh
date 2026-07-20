#!/usr/bin/env bash
# Smoke test for scripts/cmux-dispatch.sh (and the codex-watchdog.sh
# relative --prompt-file resolution it depends on).
# Offline: never touches a real cmux binary (only --dry-run paths and
# early-guard failure paths exercise cmux-dispatch.sh; watchdog resolution
# is exercised directly against codex-watchdog.sh).
# bash-3.2-compatible. Run: bash scripts/__tests__/cmux-dispatch.smoke.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DISPATCH="$SCRIPT_DIR/../cmux-dispatch.sh"
WATCHDOG="$SCRIPT_DIR/../codex-watchdog.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

FAILURES=0
pass() { echo "ok   - $1"; }
fail() { echo "NOT OK - $1"; FAILURES=$((FAILURES + 1)); }
make_round_state() {
  issue="$1"
  worktree="$2"
  revision="$3"
  output="$4"
  cp "$ROOT/schemas/fixtures/round_state.valid.json" "$output"
  node - "$output" "$issue" "$worktree" "$revision" <<'NODE'
const fs = require("fs");
const { execFileSync } = require("child_process");
const [file, issue, worktree, revision] = process.argv.slice(2);
const state = JSON.parse(fs.readFileSync(file, "utf8"));
const head = execFileSync("git", ["-C", worktree, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
const branch = execFileSync("git", ["-C", worktree, "rev-parse", "--abbrev-ref", "HEAD"], { encoding: "utf8" }).trim();
state.issue = { number: Number(issue), title: "standard round-0 smoke" };
state.tier = { name: "standard", rationale: "single-module behavior change" };
state.revision = Number(revision);
state.base_branch = branch;
state.base_sha = head;
state.head_sha = head;
state.worktree_path = fs.realpathSync(worktree);
state.decisions = [];
state.prior_findings = [];
state.live_probes = [];
state.artifact_pointers = [
  { artifact_type: "pr_draft", path: `.review/ISSUE-${issue}-PR-DRAFT.json` },
  { artifact_type: "review", path: `.review/ISSUE-${issue}-REVIEW.json` }
];
delete state.round_control;
fs.writeFileSync(file, JSON.stringify(state, null, 2) + "\n");
NODE
}

# --- setup: a real git worktree with a prompt file ---
WT="$TMP_ROOT/wt"
mkdir -p "$WT/.review"
git init -q "$WT"
git -C "$WT" -c user.name="Smoke Test" -c user.email="smoke@example.test" commit --allow-empty -q -m "init"
printf '%s\n' "prompt body" > "$WT/.review/ISSUE-301-PROMPT.txt"

# --- initial writes require the canonical round-0 contract ---
stderr_file="$TMP_ROOT/missing-initial-round-state.stderr"
bash "$DISPATCH" --issue 301 --worktree "$WT" --tier standard --dry-run >/dev/null 2>"$stderr_file"
ec=$?
if [ "$ec" -eq 2 ] && grep -q "initial write requires --round-state and --manifest-revision" "$stderr_file"; then
  pass "initial write refuses dispatch without canonical ROUND-STATE"
else
  fail "initial write refuses dispatch without canonical ROUND-STATE (ec=$ec: $(cat "$stderr_file"))"
fi
INITIAL_STATE="$WT/.review/ISSUE-301-ROUND-STATE.json"
make_round_state 301 "$WT" 1 "$INITIAL_STATE"
VALID_INITIAL_STATE="$TMP_ROOT/valid-initial-state.json"
cp "$INITIAL_STATE" "$VALID_INITIAL_STATE"
printf '%s\n' '{}' > "$INITIAL_STATE"
stderr_file="$TMP_ROOT/malformed-initial-round-state.stderr"
bash "$DISPATCH" --issue 301 --worktree "$WT" --tier standard --round-state "$INITIAL_STATE" --manifest-revision 1 --dry-run >/dev/null 2>"$stderr_file"
ec=$?
if [ "$ec" -eq 2 ] && grep -q "initial ROUND-STATE admission denied" "$stderr_file"; then
  pass "initial write rejects a malformed ROUND-STATE"
else
  fail "initial write rejects a malformed ROUND-STATE (ec=$ec: $(cat "$stderr_file"))"
fi
make_round_state 999 "$WT" 2 "$INITIAL_STATE"
stderr_file="$TMP_ROOT/wrong-initial-identity.stderr"
bash "$DISPATCH" --issue 301 --worktree "$WT" --tier standard --round-state "$INITIAL_STATE" --manifest-revision 1 --dry-run >/dev/null 2>"$stderr_file"
ec=$?
if [ "$ec" -eq 2 ] && grep -q "initial ROUND-STATE admission denied" "$stderr_file"; then
  pass "initial write binds ROUND-STATE to issue and manifest revision"
else
  fail "initial write binds ROUND-STATE to issue and manifest revision (ec=$ec: $(cat "$stderr_file"))"
fi
cp "$VALID_INITIAL_STATE" "$INITIAL_STATE"
node - "$INITIAL_STATE" <<'NODE'
const fs = require("fs");
const file = process.argv[2];
const state = JSON.parse(fs.readFileSync(file, "utf8"));
state.head_sha = "0000000000000000000000000000000000000000";
fs.writeFileSync(file, JSON.stringify(state));
NODE
stderr_file="$TMP_ROOT/wrong-initial-head.stderr"
bash "$DISPATCH" --issue 301 --worktree "$WT" --tier standard --round-state "$INITIAL_STATE" --manifest-revision 1 --dry-run >/dev/null 2>"$stderr_file"
ec=$?
if [ "$ec" -eq 2 ] && grep -q "initial ROUND-STATE admission denied" "$stderr_file"; then
  pass "initial write binds ROUND-STATE to the live worktree HEAD"
else
  fail "initial write binds ROUND-STATE to the live worktree HEAD (ec=$ec: $(cat "$stderr_file"))"
fi
cp "$VALID_INITIAL_STATE" "$INITIAL_STATE"
node - "$INITIAL_STATE" <<'NODE'
const fs = require("fs");
const file = process.argv[2];
const state = JSON.parse(fs.readFileSync(file, "utf8"));
state.base_sha = "0000000000000000000000000000000000000000";
fs.writeFileSync(file, JSON.stringify(state));
NODE
stderr_file="$TMP_ROOT/stale-initial-base.stderr"
bash "$DISPATCH" --issue 301 --worktree "$WT" --tier standard --round-state "$INITIAL_STATE" --manifest-revision 1 --dry-run >/dev/null 2>"$stderr_file"
ec=$?
if [ "$ec" -eq 2 ] && grep -q "initial ROUND-STATE admission denied" "$stderr_file"; then
  pass "initial write rejects a stale ROUND-STATE base"
else
  fail "initial write rejects a stale ROUND-STATE base (ec=$ec: $(cat "$stderr_file"))"
fi
NONCANONICAL_INITIAL_STATE="$TMP_ROOT/noncanonical-initial-state.json"
cp "$VALID_INITIAL_STATE" "$INITIAL_STATE"
cp "$VALID_INITIAL_STATE" "$NONCANONICAL_INITIAL_STATE"
stderr_file="$TMP_ROOT/noncanonical-initial-state.stderr"
bash "$DISPATCH" --issue 301 --worktree "$WT" --tier standard --round-state "$NONCANONICAL_INITIAL_STATE" --manifest-revision 1 --dry-run >/dev/null 2>"$stderr_file"
ec=$?
if [ "$ec" -eq 2 ] && grep -q "canonical path" "$stderr_file"; then
  pass "initial write rejects a second ROUND-STATE authority"
else
  fail "initial write rejects a second ROUND-STATE authority (ec=$ec: $(cat "$stderr_file"))"
fi

cp "$VALID_INITIAL_STATE" "$INITIAL_STATE"
node - "$INITIAL_STATE" <<'NODE'
const fs = require("fs");
const file = process.argv[2];
const state = JSON.parse(fs.readFileSync(file, "utf8"));
state.artifact_pointers = [];
fs.writeFileSync(file, JSON.stringify(state));
NODE
stderr_file="$TMP_ROOT/missing-standard-pointers.stderr"
bash "$DISPATCH" --issue 301 --worktree "$WT" --tier standard --round-state "$INITIAL_STATE" --manifest-revision 1 --dry-run >/dev/null 2>"$stderr_file"
ec=$?
if [ "$ec" -eq 2 ] && grep -q "pr_draft and review pointers must be retained" "$stderr_file"; then
  pass "Standard round-0 state requires pr_draft and review pointers"
else
  fail "Standard round-0 state requires pr_draft and review pointers (ec=$ec: $(cat "$stderr_file"))"
fi
cp "$VALID_INITIAL_STATE" "$INITIAL_STATE"

trivial_out="$TMP_ROOT/trivial-initial.out"
bash "$DISPATCH" --issue 301 --worktree "$WT" --tier trivial --dry-run >"$trivial_out" 2>&1
ec=$?
if [ "$ec" -eq 0 ]; then
  pass "Trivial initial write keeps its pr_draft-only contract"
else
  fail "Trivial initial write keeps its pr_draft-only contract (ec=$ec: $(cat "$trivial_out"))"
fi

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
bash "$DISPATCH" --issue 301 --worktree "$WT" --tier standard --round-state "$INITIAL_STATE" --manifest-revision 1 --dry-run >"$out_file" 2>&1
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
PATH="$BIN:$PATH" bash "$DISPATCH" --issue 301 --worktree "$WT" --tier standard --round-state "$INITIAL_STATE" --manifest-revision 1 --dry-run >/dev/null 2>"$TMP_ROOT/no-call.stderr"
ec=$?
if [ "$ec" -eq 0 ] && ! grep -q "CMUX WAS CALLED" "$TMP_ROOT/no-call.stderr"; then
  pass "dry-run never invokes cmux"
else
  fail "dry-run never invokes cmux"
fi

# --- real cmux transport: deep paths must use a short relative launch runner ---
# cmux truncates long --command values in production. Exercise the public
# dispatcher seam with a stub that rejects inline commands at 1.5 KB, then
# executes the supplied short command from the mandatory workspace cwd.
DEEP_WT="$TMP_ROOT/deep runner; \$shell"
deep_component="abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz"
deep_index=1
while [ "$deep_index" -le 9 ]; do
  DEEP_WT="$DEEP_WT/$deep_component-$deep_index"
  deep_index=$((deep_index + 1))
done
mkdir -p "$DEEP_WT/.review"
git init -q "$DEEP_WT"
git -C "$DEEP_WT" -c user.name="Smoke Test" -c user.email="smoke@example.test" commit --allow-empty -q -m "init"
printf '%s\n' "prompt body" > "$DEEP_WT/.review/ISSUE-333-PROMPT.txt"

RUNNER_FIXTURE="$TMP_ROOT/runner-fixture"
mkdir -p "$RUNNER_FIXTURE"
cp "$DISPATCH" "$RUNNER_FIXTURE/cmux-dispatch.sh"
cat > "$RUNNER_FIXTURE/codex-watchdog.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$WATCHDOG_ARGV_FILE"
issue=""
cwd=""
prompt=""
while [ $# -gt 0 ]; do
  case "$1" in
    --issue) issue="$2"; shift 2 ;;
    --prompt-file) prompt="$2"; shift 2 ;;
    --cwd) cwd="$2"; shift 2 ;;
    *) shift 1 ;;
  esac
done
[ -z "${WATCHDOG_PROMPT_LOG:-}" ] || printf '%s\n' "$prompt" >> "$WATCHDOG_PROMPT_LOG"
printf '%s\n' "{\"schema_version\":\"1\",\"artifact_type\":\"codex_run\",\"issue\":$issue,\"attempt\":1,\"started_at\":\"2026-07-21T00:00:00Z\",\"updated_at\":\"2026-07-21T00:00:00Z\",\"status\":\"running\"}" > "$cwd/.review/ISSUE-${issue}-RUN.json"
EOF
chmod +x "$RUNNER_FIXTURE/codex-watchdog.sh"

RUNNER_BIN="$TMP_ROOT/bin-runner-cmux"
mkdir -p "$RUNNER_BIN"
cat > "$RUNNER_BIN/cmux" <<'EOF'
#!/usr/bin/env bash
cwd=""
command=""
shift 2
while [ $# -gt 0 ]; do
  case "$1" in
    --cwd) cwd="$2"; shift 2 ;;
    --command) command="$2"; shift 2 ;;
    *) shift 1 ;;
  esac
done
if [ "${#command}" -gt 1500 ]; then
  echo "inline cmux command exceeds 1.5KB" >&2
  exit 64
fi
case "$command" in
  "bash .review/ISSUE-"*-launch.*/launch.sh) : ;;
  *) echo "cmux command was not the expected relative runner: $command" >&2; exit 65 ;;
esac
(cd "$cwd" && /bin/sh -c "$command")
EOF
chmod +x "$RUNNER_BIN/cmux"

runner_transport_out="$TMP_ROOT/runner-transport.out"
WATCHDOG_ARGV_FILE="$TMP_ROOT/watchdog-argv.txt" \
CMUX_DISPATCH_POLL_INTERVAL=1 PATH="$RUNNER_BIN:$PATH" \
bash "$RUNNER_FIXTURE/cmux-dispatch.sh" --issue 333 --worktree "$DEEP_WT" \
  --read-only --model gpt-5.6-terra --effort medium \
  --first-progress-timeout 1500 --stall-timeout 900 --poll-timeout 3 >"$runner_transport_out" 2>&1
ec=$?
runner_333="$(find "$DEEP_WT/.review" -path '*/ISSUE-333-launch.*/launch.sh' -type f -print -quit)"
if [ "$ec" -eq 0 ] && [ -n "$runner_333" ] && [ -x "$runner_333" ] && grep -q "fresh RUN.json present" "$runner_transport_out" \
  && grep -Fx -- "--issue" "$TMP_ROOT/watchdog-argv.txt" >/dev/null && grep -Fx -- "333" "$TMP_ROOT/watchdog-argv.txt" >/dev/null \
  && grep -Fx -- "--prompt-file" "$TMP_ROOT/watchdog-argv.txt" >/dev/null && grep -Fx -- "$DEEP_WT/.review/ISSUE-333-PROMPT.txt" "$TMP_ROOT/watchdog-argv.txt" >/dev/null \
  && grep -Fx -- "--cwd" "$TMP_ROOT/watchdog-argv.txt" >/dev/null && grep -Fx -- "$DEEP_WT" "$TMP_ROOT/watchdog-argv.txt" >/dev/null \
  && grep -Fx -- "--model" "$TMP_ROOT/watchdog-argv.txt" >/dev/null && grep -Fx -- "gpt-5.6-terra" "$TMP_ROOT/watchdog-argv.txt" >/dev/null \
  && grep -Fx -- "--effort" "$TMP_ROOT/watchdog-argv.txt" >/dev/null && grep -Fx -- "medium" "$TMP_ROOT/watchdog-argv.txt" >/dev/null \
  && grep -Fx -- "--read-only" "$TMP_ROOT/watchdog-argv.txt" >/dev/null \
  && grep -Fx -- "--first-progress-timeout" "$TMP_ROOT/watchdog-argv.txt" >/dev/null && grep -Fx -- "1500" "$TMP_ROOT/watchdog-argv.txt" >/dev/null \
  && grep -Fx -- "--stall-timeout" "$TMP_ROOT/watchdog-argv.txt" >/dev/null && grep -Fx -- "900" "$TMP_ROOT/watchdog-argv.txt" >/dev/null; then
  pass "deep dispatch uses a short relative runner and preserves watchdog argv"
else
  fail "deep dispatch uses a short relative runner and preserves watchdog argv (ec=$ec: $(cat "$runner_transport_out"))"
fi

printf '%s\n' "prompt body" > "$DEEP_WT/.review/ISSUE-334-PROMPT.txt"
produce_review_out="$TMP_ROOT/produce-review-runner.out"
WATCHDOG_ARGV_FILE="$TMP_ROOT/produce-review-watchdog-argv.txt" \
CMUX_DISPATCH_POLL_INTERVAL=1 PATH="$RUNNER_BIN:$PATH" \
bash "$RUNNER_FIXTURE/cmux-dispatch.sh" --issue 334 --worktree "$DEEP_WT" \
  --produce-review --model gpt-5.6-sol --effort medium --poll-timeout 3 >"$produce_review_out" 2>&1
ec=$?
runner_334="$(find "$DEEP_WT/.review" -path '*/ISSUE-334-launch.*/launch.sh' -type f -print -quit)"
if [ "$ec" -eq 0 ] && [ -n "$runner_334" ] && [ -x "$runner_334" ] \
  && grep -Fx -- "--produce-review" "$TMP_ROOT/produce-review-watchdog-argv.txt" >/dev/null \
  && grep -Fx -- "gpt-5.6-sol" "$TMP_ROOT/produce-review-watchdog-argv.txt" >/dev/null; then
  pass "launch runner preserves produce-review mode and pinned model"
else
  fail "launch runner preserves produce-review mode and pinned model (ec=$ec: $(cat "$produce_review_out"))"
fi

# Same-issue read/review seats may overlap. cmux starts asynchronously, so a
# later dispatch must not overwrite the earlier seat's runner before cmux
# executes it. Delay both runner executions until both workspace creates have
# returned, then require distinct commands and the original prompt for each.
printf '%s\n' "seat A" > "$DEEP_WT/.review/ISSUE-335-PROMPT-A.txt"
printf '%s\n' "seat B" > "$DEEP_WT/.review/ISSUE-335-PROMPT-B.txt"
DEFERRED_BIN="$TMP_ROOT/bin-deferred-cmux"
mkdir -p "$DEFERRED_BIN"
cat > "$DEFERRED_BIN/cmux" <<'EOF'
#!/usr/bin/env bash
command=""
shift 2
while [ $# -gt 0 ]; do
  case "$1" in
    --command) command="$2"; shift 2 ;;
    *) shift 1 ;;
  esac
done
printf '%s\n' "$command" >> "$DEFERRED_COMMANDS"
exit 0
EOF
chmod +x "$DEFERRED_BIN/cmux"

DEFERRED_COMMANDS="$TMP_ROOT/deferred-commands.txt"
: > "$DEFERRED_COMMANDS"
DEFERRED_COMMANDS="$DEFERRED_COMMANDS" CMUX_DISPATCH_POLL_INTERVAL=1 PATH="$DEFERRED_BIN:$PATH" \
bash "$RUNNER_FIXTURE/cmux-dispatch.sh" --issue 335 --worktree "$DEEP_WT" \
  --prompt-file .review/ISSUE-335-PROMPT-A.txt --read-only --poll-timeout 5 >"$TMP_ROOT/overlap-a.out" 2>&1 &
overlap_a_pid=$!
overlap_wait=0
while [ "$(wc -l < "$DEFERRED_COMMANDS")" -lt 1 ] && [ "$overlap_wait" -lt 30 ]; do
  sleep 0.1
  overlap_wait=$((overlap_wait + 1))
done
DEFERRED_COMMANDS="$DEFERRED_COMMANDS" CMUX_DISPATCH_POLL_INTERVAL=1 PATH="$DEFERRED_BIN:$PATH" \
bash "$RUNNER_FIXTURE/cmux-dispatch.sh" --issue 335 --worktree "$DEEP_WT" \
  --prompt-file .review/ISSUE-335-PROMPT-B.txt --read-only --poll-timeout 5 >"$TMP_ROOT/overlap-b.out" 2>&1 &
overlap_b_pid=$!
overlap_wait=0
while [ "$(wc -l < "$DEFERRED_COMMANDS")" -lt 2 ] && [ "$overlap_wait" -lt 30 ]; do
  sleep 0.1
  overlap_wait=$((overlap_wait + 1))
done
overlap_command_a="$(sed -n '1p' "$DEFERRED_COMMANDS")"
overlap_command_b="$(sed -n '2p' "$DEFERRED_COMMANDS")"
(
  cd "$DEEP_WT" || exit 1
  WATCHDOG_ARGV_FILE="$TMP_ROOT/overlap-argv.txt" WATCHDOG_PROMPT_LOG="$TMP_ROOT/overlap-prompts.txt" /bin/sh -c "$overlap_command_a"
)
(
  cd "$DEEP_WT" || exit 1
  WATCHDOG_ARGV_FILE="$TMP_ROOT/overlap-argv.txt" WATCHDOG_PROMPT_LOG="$TMP_ROOT/overlap-prompts.txt" /bin/sh -c "$overlap_command_b"
)
wait "$overlap_a_pid"
overlap_a_ec=$?
wait "$overlap_b_pid"
overlap_b_ec=$?
if [ "$overlap_a_ec" -eq 0 ] && [ "$overlap_b_ec" -eq 0 ] \
  && [ -n "$overlap_command_a" ] && [ "$overlap_command_a" != "$overlap_command_b" ] \
  && [ "$(grep -Fxc -- "$DEEP_WT/.review/ISSUE-335-PROMPT-A.txt" "$TMP_ROOT/overlap-prompts.txt")" -eq 1 ] \
  && [ "$(grep -Fxc -- "$DEEP_WT/.review/ISSUE-335-PROMPT-B.txt" "$TMP_ROOT/overlap-prompts.txt")" -eq 1 ]; then
  pass "overlapping same-issue seats retain launch-unique runners"
else
  fail "overlapping same-issue seats retain launch-unique runners (a=$overlap_a_ec b=$overlap_b_ec commands=$overlap_command_a|$overlap_command_b prompts=$(cat "$TMP_ROOT/overlap-prompts.txt"))"
fi

# A read-only seat writes RUN.json but must remain outside the implementation
# circuit; the first later write is still an initial write.
READ_THEN_WRITE_WT="$TMP_ROOT/wt-read-then-write"
mkdir -p "$READ_THEN_WRITE_WT/.review"
git init -q "$READ_THEN_WRITE_WT"
git -C "$READ_THEN_WRITE_WT" -c user.name=smoke -c user.email=smoke@example.test commit --allow-empty -qm init
printf '%s\n' 'prompt body' > "$READ_THEN_WRITE_WT/.review/ISSUE-309-PROMPT.txt"
printf '%s\n' '{"schema_version":"1","artifact_type":"codex_run","issue":309,"attempt":1,"started_at":"2026-07-20T10:00:00Z","updated_at":"2026-07-20T10:00:00Z","status":"exited","exit_code":0}' > "$READ_THEN_WRITE_WT/.review/ISSUE-309-RUN.json"
READ_THEN_WRITE_STATE="$READ_THEN_WRITE_WT/.review/ISSUE-309-ROUND-STATE.json"
make_round_state 309 "$READ_THEN_WRITE_WT" 1 "$READ_THEN_WRITE_STATE"
read_then_write_out="$TMP_ROOT/read-then-write.out"
bash "$DISPATCH" --issue 309 --worktree "$READ_THEN_WRITE_WT" --tier standard --round-state "$READ_THEN_WRITE_STATE" --manifest-revision 1 --dry-run >"$read_then_write_out" 2>&1
ec=$?
if [ "$ec" -eq 0 ]; then
  pass "read-only RUN.json does not turn the first write into redispatch"
else
  fail "read-only RUN.json does not turn the first write into redispatch (ec=$ec: $(cat "$read_then_write_out"))"
fi

# --- write-capable same-issue redispatch is gate-bound and single-use ---
ADMIT_WT="$TMP_ROOT/wt-admission"
mkdir -p "$ADMIT_WT/.review/evidence"
git init -q "$ADMIT_WT"
git -C "$ADMIT_WT" config user.email smoke@example.test
git -C "$ADMIT_WT" config user.name smoke
git -C "$ADMIT_WT" commit --allow-empty -qm baseline
ADMIT_EVIDENCE_HEAD="$(git -C "$ADMIT_WT" rev-parse HEAD)"
node - "$ADMIT_WT" "$ADMIT_EVIDENCE_HEAD" <<'NODE'
const fs=require("fs"); const path=require("path"); const [worktree,head]=process.argv.slice(2);
for (const issue of [307,999]) {
  const artifact={schema_version:"1",artifact_type:"verify_result",producer_role:"VERIFIER",issue,branch:"main",head_sha:head,cwd:worktree,verify_cmd:"smoke verify",db_target:{host:"localhost",database:"smoke",role:"verifier"},clean_state:{sentinel:{expected:"clean",actual:"clean"},migration_hash:{expected:"same",actual:"same"},role:{name:"verifier",superuser:false}},verdict:{passed:0,failed:1,pending:0,exit_code:1},classifier:"FAIL",failures:[{code:"failed_tests",expected:"0",actual:"1"}],created_at:"2026-07-20T00:00:00Z"};
  fs.writeFileSync(path.join(worktree,".review/evidence/F-"+issue+".json"),JSON.stringify(artifact));
  if (issue === 307) {
    fs.writeFileSync(path.join(worktree,".review/evidence/F-307-2.json"),JSON.stringify(artifact));
    fs.writeFileSync(path.join(worktree,".review/evidence/hard-fact.json"),JSON.stringify(artifact));
  }
}
fs.writeFileSync(path.join(worktree,".review/evidence/oracle.json"),"oracle evidence\n");
fs.writeFileSync(path.join(worktree,".review/evidence/passing.json"),"passing evidence\n");
NODE
git -C "$ADMIT_WT" add .review/evidence
git -C "$ADMIT_WT" commit -qm evidence
git -C "$ADMIT_WT" branch -M main
ADMIT_HEAD="$(git -C "$ADMIT_WT" rev-parse HEAD)"
printf '%s\n' 'prompt body' > "$ADMIT_WT/.review/ISSUE-307-PROMPT.txt"
printf '%s\n' '{"schema_version":"1","artifact_type":"codex_run","issue":307,"attempt":1,"started_at":"2026-07-13T00:00:00Z","updated_at":"2026-07-13T00:00:00Z","status":"exited","exit_code":1}' > "$ADMIT_WT/.review/ISSUE-307-RUN.json"
cp "$ROOT/schemas/fixtures/round_state.valid.json" "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json"
node -e '
  const fs=require("fs"); const crypto=require("crypto"); const path=require("path");
  const [file,worktree,head]=process.argv.slice(1); const value=JSON.parse(fs.readFileSync(file,"utf8"));
  const evidencePath=".review/evidence/F-307.json"; const content=fs.readFileSync(path.join(worktree,evidencePath));
  value.issue={number:307,title:"redispatch admission"}; value.revision=5; value.base_branch="main"; value.base_sha=head; value.head_sha=head; value.worktree_path=worktree;
  value.round_control={failures:[{id:"F-1",dispatch_ordinal:1,status:"open",primary_origin:"implementation",secondary_origins:[],failed_ac_ids:["AC-1"],owner:"CONDUCTOR",next_action:{kind:"implementation_fix",summary:"apply the classified fix"},evidence:[{kind:"verify",path:evidencePath,content_sha256:crypto.createHash("sha256").update(content).digest("hex"),head_sha:process.argv[4]}]}]};
  fs.writeFileSync(file,JSON.stringify(value));
' "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json" "$ADMIT_WT" "$ADMIT_HEAD" "$ADMIT_EVIDENCE_HEAD"
VALID_ADMIT_STATE="$TMP_ROOT/valid-admit-state.json"
cp "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json" "$VALID_ADMIT_STATE"

cp "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json" "$ADMIT_WT/.review/ISSUE-999-ROUND-STATE.json"
node -e '
  const fs=require("fs"); const crypto=require("crypto"); const path=require("path"); const [file,worktree]=process.argv.slice(1); const value=JSON.parse(fs.readFileSync(file,"utf8"));
  const evidencePath=".review/evidence/F-999.json"; const content=fs.readFileSync(path.join(worktree,evidencePath)); value.issue={number:999,title:"other issue"};
  value.round_control.failures[0].evidence[0].path=evidencePath; value.round_control.failures[0].evidence[0].content_sha256=crypto.createHash("sha256").update(content).digest("hex");
  fs.writeFileSync(file,JSON.stringify(value));
' "$ADMIT_WT/.review/ISSUE-999-ROUND-STATE.json" "$ADMIT_WT"

admission_missing="$TMP_ROOT/admission-missing.out"
bash "$DISPATCH" --issue 307 --worktree "$ADMIT_WT" --dry-run >"$admission_missing" 2>&1
ec=$?
if [ "$ec" -eq 2 ] && grep -q "redispatch requires --round-state" "$admission_missing"; then
  pass "write redispatch requires canonical round-control input"
else
  fail "write redispatch requires canonical round-control input (ec=$ec: $(cat "$admission_missing"))"
fi

POINTERLESS_ADMIT_STATE="$TMP_ROOT/pointerless-admit-state.json"
cp "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json" "$POINTERLESS_ADMIT_STATE"
node - "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json" <<'NODE'
const fs = require("fs");
const file = process.argv[2];
const state = JSON.parse(fs.readFileSync(file, "utf8"));
state.artifact_pointers = [];
fs.writeFileSync(file, JSON.stringify(state));
NODE
pointerless_redispatch_out="$TMP_ROOT/pointerless-redispatch.out"
bash "$DISPATCH" --issue 307 --worktree "$ADMIT_WT" --round-state "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json" --manifest-revision 5 --dry-run >"$pointerless_redispatch_out" 2>&1
ec=$?
cp "$POINTERLESS_ADMIT_STATE" "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json"
if [ "$ec" -eq 2 ] && grep -q "pr_draft and review pointers must be retained" "$pointerless_redispatch_out"; then
  pass "redispatch retains Standard pr_draft and review pointers"
else
  fail "redispatch retains Standard pr_draft and review pointers (ec=$ec: $(cat "$pointerless_redispatch_out"))"
fi

admission_wrong_issue="$TMP_ROOT/admission-wrong-issue.out"
cp "$ADMIT_WT/.review/ISSUE-999-ROUND-STATE.json" "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json"
bash "$DISPATCH" --issue 307 --worktree "$ADMIT_WT" --round-state "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json" --manifest-revision 5 --dry-run >"$admission_wrong_issue" 2>&1
ec=$?
cp "$VALID_ADMIT_STATE" "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json"
if [ "$ec" -eq 2 ] && grep -q "does not match the dispatched issue and worktree" "$admission_wrong_issue"; then
  pass "redispatch admission is bound to the CLI issue"
else
  fail "redispatch admission is bound to the CLI issue (ec=$ec: $(cat "$admission_wrong_issue"))"
fi

OTHER_WT="$TMP_ROOT/wt-other-admission"
mkdir -p "$OTHER_WT/.review"
git init -q "$OTHER_WT"
git -C "$OTHER_WT" -c user.name=smoke -c user.email=smoke@example.test commit --allow-empty -qm init
printf '%s\n' 'prompt body' > "$OTHER_WT/.review/ISSUE-307-PROMPT.txt"
printf '%s\n' '{}' > "$OTHER_WT/.review/ISSUE-307-RUN.json"
cp "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json" "$OTHER_WT/.review/ISSUE-307-ROUND-STATE.json"
admission_wrong_worktree="$TMP_ROOT/admission-wrong-worktree.out"
bash "$DISPATCH" --issue 307 --worktree "$OTHER_WT" --round-state "$OTHER_WT/.review/ISSUE-307-ROUND-STATE.json" --manifest-revision 5 --dry-run >"$admission_wrong_worktree" 2>&1
ec=$?
if [ "$ec" -eq 2 ] && grep -q "does not match the dispatched issue and worktree" "$admission_wrong_worktree"; then
  pass "redispatch admission is bound to the CLI worktree"
else
  fail "redispatch admission is bound to the CLI worktree (ec=$ec: $(cat "$admission_wrong_worktree"))"
fi

mv "$ADMIT_WT/.review/ISSUE-307-RUN.json" "$ADMIT_WT/.review/ISSUE-307-RUN.saved"
admission_history_missing="$TMP_ROOT/admission-history-missing.out"
bash "$DISPATCH" --issue 307 --worktree "$ADMIT_WT" --dry-run >"$admission_history_missing" 2>&1
ec=$?
mv "$ADMIT_WT/.review/ISSUE-307-RUN.saved" "$ADMIT_WT/.review/ISSUE-307-RUN.json"
if [ "$ec" -eq 2 ] && grep -q "redispatch requires --round-state" "$admission_history_missing"; then
  pass "round failure history keeps redispatch gate mandatory when RUN is absent"
else
  fail "round failure history keeps redispatch gate mandatory when RUN is absent (ec=$ec: $(cat "$admission_history_missing"))"
fi

admission_dry="$TMP_ROOT/admission-dry.out"
bash "$DISPATCH" --issue 307 --worktree "$ADMIT_WT" --round-state "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json" --manifest-revision 5 --dry-run >"$admission_dry" 2>&1
ec=$?
if [ "$ec" -eq 0 ] && grep -q "redispatch admission: mode=normal" "$admission_dry" && ! find "$ADMIT_WT/.review" -maxdepth 1 -type d -name '.redispatch-admission-*' | grep -q .; then
  pass "dry-run checks redispatch policy without consuming admission"
else
  fail "dry-run checks redispatch policy without consuming admission (ec=$ec: $(cat "$admission_dry"))"
fi

ADMIT_BIN="$TMP_ROOT/bin-admission-cmux"
mkdir -p "$ADMIT_BIN"
cat > "$ADMIT_BIN/cmux" <<EOF
#!/usr/bin/env bash
printf '%s\n' '{"schema_version":"1","artifact_type":"codex_run","issue":307,"attempt":2,"started_at":"2026-07-20T10:00:00Z","updated_at":"2026-07-20T10:00:00Z","status":"running"}' > "$ADMIT_WT/.review/ISSUE-307-RUN.json"
exit 0
EOF
chmod +x "$ADMIT_BIN/cmux"
admission_first="$TMP_ROOT/admission-first.out"
CMUX_DISPATCH_POLL_INTERVAL=1 PATH="$ADMIT_BIN:$PATH" bash "$DISPATCH" --issue 307 --worktree "$ADMIT_WT" --round-state "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json" --manifest-revision 5 --poll-timeout 3 >"$admission_first" 2>&1
first_ec=$?
admission_second="$TMP_ROOT/admission-second.out"
CMUX_DISPATCH_POLL_INTERVAL=1 PATH="$ADMIT_BIN:$PATH" bash "$DISPATCH" --issue 307 --worktree "$ADMIT_WT" --round-state "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json" --manifest-revision 5 --poll-timeout 3 >"$admission_second" 2>&1
second_ec=$?
if [ "$first_ec" -eq 0 ] && [ "$second_ec" -ne 0 ] && grep -q "redispatch admission already consumed" "$admission_second"; then
  pass "write redispatch admission is atomically single-use"
else
  fail "write redispatch admission is atomically single-use (first=$first_ec second=$second_ec: $(cat "$admission_second"))"
fi

node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.revision=6; fs.writeFileSync(f,JSON.stringify(v));' "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json"
admission_revision_bump="$TMP_ROOT/admission-revision-bump.out"
CMUX_DISPATCH_POLL_INTERVAL=1 PATH="$ADMIT_BIN:$PATH" bash "$DISPATCH" --issue 307 --worktree "$ADMIT_WT" --round-state "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json" --manifest-revision 6 --poll-timeout 3 >"$admission_revision_bump" 2>&1
ec=$?
if [ "$ec" -ne 0 ] && grep -q "redispatch admission already consumed" "$admission_revision_bump"; then
  pass "manifest revision bump cannot replay a consumed redispatch admission"
else
  fail "manifest revision bump cannot replay a consumed redispatch admission (ec=$ec: $(cat "$admission_revision_bump"))"
fi

RECREATED_WT="$TMP_ROOT/wt-recreated-admission"
git -C "$ADMIT_WT" worktree add --detach -q "$RECREATED_WT" "$ADMIT_HEAD"
mkdir -p "$RECREATED_WT/.review"
cp "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json" "$RECREATED_WT/.review/ISSUE-307-ROUND-STATE.json"
printf '%s\n' 'prompt body' > "$RECREATED_WT/.review/ISSUE-307-PROMPT.txt"
printf '%s\n' '{}' > "$RECREATED_WT/.review/ISSUE-307-RUN.json"
node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.worktree_path=process.argv[2]; fs.writeFileSync(f,JSON.stringify(v));' "$RECREATED_WT/.review/ISSUE-307-ROUND-STATE.json" "$RECREATED_WT"
admission_recreated="$TMP_ROOT/admission-recreated.out"
CMUX_DISPATCH_POLL_INTERVAL=1 PATH="$ADMIT_BIN:$PATH" bash "$DISPATCH" --issue 307 --worktree "$RECREATED_WT" --round-state "$RECREATED_WT/.review/ISSUE-307-ROUND-STATE.json" --manifest-revision 6 --poll-timeout 3 >"$admission_recreated" 2>&1
ec=$?
if [ "$ec" -ne 0 ] && grep -q "redispatch admission already consumed" "$admission_recreated"; then
  pass "git-common admission survives worktree recreation"
else
  fail "git-common admission survives worktree recreation (ec=$ec: $(cat "$admission_recreated"))"
fi

NONCANONICAL_REDISPATCH_STATE="$TMP_ROOT/noncanonical-redispatch-state.json"
cp "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json" "$NONCANONICAL_REDISPATCH_STATE"
noncanonical_redispatch_out="$TMP_ROOT/noncanonical-redispatch.out"
bash "$DISPATCH" --issue 307 --worktree "$ADMIT_WT" --round-state "$NONCANONICAL_REDISPATCH_STATE" --manifest-revision 6 --dry-run >"$noncanonical_redispatch_out" 2>&1
ec=$?
if [ "$ec" -eq 2 ] && grep -q "canonical path" "$noncanonical_redispatch_out"; then
  pass "redispatch extends the same canonical ROUND-STATE"
else
  fail "redispatch extends the same canonical ROUND-STATE (ec=$ec: $(cat "$noncanonical_redispatch_out"))"
fi

INTEGRATED_STATE="$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json"
node -e '
  const fs=require("fs"); const crypto=require("crypto"); const path=require("path"); const [file,worktree,head]=process.argv.slice(1); const value=JSON.parse(fs.readFileSync(file,"utf8"));
  const ref=(kind,name)=>{const relative=".review/evidence/"+name; const content=fs.readFileSync(path.join(worktree,relative)); return {kind,path:relative,content_sha256:crypto.createHash("sha256").update(content).digest("hex"),head_sha:head};};
  const second=JSON.parse(JSON.stringify(value.round_control.failures[0])); second.id="F-2"; second.dispatch_ordinal=2; second.evidence=[ref("verify","F-307-2.json")]; value.round_control.failures.push(second);
  value.round_control.diagnosis={trigger:"same_origin",failure_ids:["F-1","F-2"],records:[{kind:"oracle_contract_recheck",summary:"oracle checked",evidence:ref("live_probe","oracle.json")},{kind:"hard_fact",summary:"hard fact",evidence:ref("verify","hard-fact.json")},{kind:"passing_analog",summary:"passing analog",instruction:"guess_forbidden_copy_passing_analog_to_parity",evidence:ref("diff","passing.json")}],integrated_fix_batch:{dispatch_ordinal:3,failure_ids:["F-1","F-2"],status:"ready"}};
  fs.writeFileSync(file,JSON.stringify(value));
' "$INTEGRATED_STATE" "$ADMIT_WT" "$ADMIT_EVIDENCE_HEAD"
INTEGRATED_READY_SNAPSHOT="$TMP_ROOT/integrated-ready-snapshot.json"
cp "$INTEGRATED_STATE" "$INTEGRATED_READY_SNAPSHOT"
integrated_first="$TMP_ROOT/integrated-first.out"
CMUX_DISPATCH_POLL_INTERVAL=1 PATH="$ADMIT_BIN:$PATH" bash "$DISPATCH" --issue 307 --worktree "$ADMIT_WT" --round-state "$INTEGRATED_STATE" --manifest-revision 6 --poll-timeout 3 >"$integrated_first" 2>&1
integrated_first_ec=$?
if [ "$integrated_first_ec" -eq 0 ] && grep -q "redispatch admission: mode=integrated_fix" "$integrated_first"; then
  pass "first integrated fix consumes the issue singleton admission"
else
  fail "first integrated fix consumes the issue singleton admission (ec=$integrated_first_ec: $(cat "$integrated_first"))"
fi

SECOND_INTEGRATED_STATE="$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json"
node -e '
  const fs=require("fs"); const file=process.argv[1]; const value=JSON.parse(fs.readFileSync(file,"utf8")); const third=JSON.parse(JSON.stringify(value.round_control.failures[1])); third.id="F-3"; third.dispatch_ordinal=3; value.round_control.failures.push(third);
  value.round_control.diagnosis.failure_ids=["F-1","F-2","F-3"]; value.round_control.diagnosis.integrated_fix_batch={dispatch_ordinal:4,failure_ids:["F-1","F-2","F-3"],status:"ready"}; fs.writeFileSync(file,JSON.stringify(value));
' "$SECOND_INTEGRATED_STATE"
integrated_second="$TMP_ROOT/integrated-second.out"
CMUX_DISPATCH_POLL_INTERVAL=1 PATH="$ADMIT_BIN:$PATH" bash "$DISPATCH" --issue 307 --worktree "$ADMIT_WT" --round-state "$SECOND_INTEGRATED_STATE" --manifest-revision 6 --poll-timeout 3 >"$integrated_second" 2>&1
ec=$?
if [ "$ec" -ne 0 ] && grep -q "integrated fix admission already consumed" "$integrated_second"; then
  pass "a later ordinal cannot admit a second integrated fix"
else
  fail "a later ordinal cannot admit a second integrated fix (ec=$ec: $(cat "$integrated_second"))"
fi

NORMAL_SAME_ORDINAL_STATE="$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json"
cp "$INTEGRATED_READY_SNAPSHOT" "$NORMAL_SAME_ORDINAL_STATE"
node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.round_control.failures[1].primary_origin="test_oracle"; v.round_control.failures[1].next_action.kind="oracle_fix"; delete v.round_control.diagnosis; fs.writeFileSync(f,JSON.stringify(v));' "$NORMAL_SAME_ORDINAL_STATE"
normal_same_ordinal="$TMP_ROOT/normal-same-ordinal.out"
CMUX_DISPATCH_POLL_INTERVAL=1 PATH="$ADMIT_BIN:$PATH" bash "$DISPATCH" --issue 307 --worktree "$ADMIT_WT" --round-state "$NORMAL_SAME_ORDINAL_STATE" --manifest-revision 6 --poll-timeout 3 >"$normal_same_ordinal" 2>&1
ec=$?
if [ "$ec" -ne 0 ] && grep -q "redispatch admission already consumed" "$normal_same_ordinal"; then
  pass "the same dispatch ordinal cannot replay under another mode"
else
  fail "the same dispatch ordinal cannot replay under another mode (ec=$ec: $(cat "$normal_same_ordinal"))"
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
CMUX_DISPATCH_POLL_INTERVAL=1 PATH="$NOOP_BIN:$PATH" bash "$DISPATCH" --issue 304 --worktree "$STALE_WT" --read-only --poll-timeout 2 >"$stale_out" 2>&1
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
CMUX_DISPATCH_POLL_INTERVAL=1 PATH="$FRESH_BIN:$PATH" bash "$DISPATCH" --issue 304 --worktree "$STALE_WT" --read-only --poll-timeout 5 >"$fresh_out" 2>&1
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
CMUX_DISPATCH_POLL_INTERVAL=1 PATH="$NOOP_BIN:$PATH" bash "$DISPATCH" --issue 305 --worktree "$STALE_WT" --read-only --poll-timeout 2 >"$blocker_out" 2>&1
ec=$?
if [ "$ec" -ne 0 ] && grep -q "waiting past stale BLOCKER.json" "$blocker_out"; then
  pass "stale BLOCKER.json alone is not accepted"
else
  fail "stale BLOCKER.json alone is not accepted (ec=$ec: $(cat "$blocker_out"))"
fi

# no pre-existing artifact: a newly appearing RUN.json is still accepted
# (regression guard on the fresh-first-dispatch path).
printf '%s\n' "prompt body" > "$STALE_WT/.review/ISSUE-306-PROMPT.txt"
INITIAL_306_STATE="$STALE_WT/.review/ISSUE-306-ROUND-STATE.json"
make_round_state 306 "$STALE_WT" 1 "$INITIAL_306_STATE"
FRESH306_BIN="$TMP_ROOT/bin-fresh306-cmux"
mkdir -p "$FRESH306_BIN"
cat > "$FRESH306_BIN/cmux" <<EOF
#!/usr/bin/env bash
printf '%s\n' '{"schema_version":"1","artifact_type":"codex_run","issue":306,"attempt":1,"started_at":"2026-07-14T09:00:00Z","updated_at":"2026-07-14T09:00:00Z","status":"running"}' > "$STALE_WT/.review/ISSUE-306-RUN.json"
exit 0
EOF
chmod +x "$FRESH306_BIN/cmux"
first_out="$TMP_ROOT/first-dispatch.out"
CMUX_DISPATCH_POLL_INTERVAL=1 PATH="$FRESH306_BIN:$PATH" bash "$DISPATCH" --issue 306 --worktree "$STALE_WT" --tier standard --round-state "$INITIAL_306_STATE" --manifest-revision 1 --poll-timeout 5 >"$first_out" 2>&1
ec=$?
if [ "$ec" -eq 0 ] && grep -q "fresh RUN.json present" "$first_out"; then
  pass "first dispatch with no pre-existing artifact still accepts a new RUN.json"
else
  fail "first dispatch with no pre-existing artifact still accepts a new RUN.json (ec=$ec: $(cat "$first_out"))"
fi

rm "$STALE_WT/.review/ISSUE-306-RUN.json"
attempt_marker_out="$TMP_ROOT/write-attempt-marker.out"
bash "$DISPATCH" --issue 306 --worktree "$STALE_WT" --dry-run >"$attempt_marker_out" 2>&1
ec=$?
if [ "$ec" -eq 2 ] && grep -q "redispatch requires --round-state" "$attempt_marker_out"; then
  pass "pre-launch write marker keeps a pre-RUN failure visible"
else
  fail "pre-launch write marker keeps a pre-RUN failure visible (ec=$ec: $(cat "$attempt_marker_out"))"
fi

RACE_WT="$TMP_ROOT/wt-initial-race"
mkdir -p "$RACE_WT/.review"
git init -q "$RACE_WT"
git -C "$RACE_WT" -c user.name=smoke -c user.email=smoke@example.test commit --allow-empty -qm init
printf '%s\n' 'prompt body' > "$RACE_WT/.review/ISSUE-308-PROMPT.txt"
INITIAL_308_STATE="$RACE_WT/.review/ISSUE-308-ROUND-STATE.json"
make_round_state 308 "$RACE_WT" 1 "$INITIAL_308_STATE"
RACE_BIN="$TMP_ROOT/bin-race-cmux"
mkdir -p "$RACE_BIN"
cat > "$RACE_BIN/cmux" <<EOF
#!/usr/bin/env bash
printf '%s\n' '{"schema_version":"1","artifact_type":"codex_run","issue":308,"attempt":1,"started_at":"2026-07-20T11:00:00Z","updated_at":"2026-07-20T11:00:00Z","status":"running"}' > "$RACE_WT/.review/ISSUE-308-RUN.json"
exit 0
EOF
chmod +x "$RACE_BIN/cmux"
CMUX_DISPATCH_PRE_MARKER_DELAY=1 CMUX_DISPATCH_POLL_INTERVAL=1 PATH="$RACE_BIN:$PATH" bash "$DISPATCH" --issue 308 --worktree "$RACE_WT" --tier standard --round-state "$INITIAL_308_STATE" --manifest-revision 1 --poll-timeout 3 >"$TMP_ROOT/race-one.out" 2>&1 &
race_one_pid=$!
CMUX_DISPATCH_PRE_MARKER_DELAY=1 CMUX_DISPATCH_POLL_INTERVAL=1 PATH="$RACE_BIN:$PATH" bash "$DISPATCH" --issue 308 --worktree "$RACE_WT" --tier standard --round-state "$INITIAL_308_STATE" --manifest-revision 1 --poll-timeout 3 >"$TMP_ROOT/race-two.out" 2>&1 &
race_two_pid=$!
wait "$race_one_pid"; race_one_ec=$?
wait "$race_two_pid"; race_two_ec=$?
race_successes=0
[ "$race_one_ec" -eq 0 ] && race_successes=$((race_successes + 1))
[ "$race_two_ec" -eq 0 ] && race_successes=$((race_successes + 1))
if [ "$race_successes" -eq 1 ] && { grep -q "concurrent write dispatch" "$TMP_ROOT/race-one.out" || grep -q "concurrent write dispatch" "$TMP_ROOT/race-two.out"; }; then
  pass "concurrent first writes atomically admit exactly one launch"
else
  fail "concurrent first writes atomically admit exactly one launch (one=$race_one_ec two=$race_two_ec)"
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
