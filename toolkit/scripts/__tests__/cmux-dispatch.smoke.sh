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
ROUTE="$SCRIPT_DIR/../route.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
PRODUCT_HOME="$TMP_ROOT/product-home"
mkdir -p "$PRODUCT_HOME"
cp -R "$ROOT/scripts" "$PRODUCT_HOME/scripts"
cp -R "$ROOT/schemas" "$PRODUCT_HOME/schemas"
cp "$ROOT/model-alloc.json" "$PRODUCT_HOME/model-alloc.json"
PRODUCT_DISPATCH="$PRODUCT_HOME/scripts/cmux-dispatch.sh"
# Runtime admission capability-probes the executable. Use a deterministic
# Codex-shaped fake instead of /usr/bin/true, which correctly lacks `exec`.
if [ -z "${AGENT_WORKFLOW_CODEX_BIN:-}" ]; then
  RUNTIME_FAKE="$TMP_ROOT/codex-runtime-fake"
  cat > "$RUNTIME_FAKE" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo 'codex smoke runtime 1.0'; exit 0 ;;
  --help) echo 'Commands: exec'; exit 0 ;;
  exec) [ "${2:-}" = "--help" ] && { echo 'exec --sandbox --cd --model --config --output-last-message'; exit 0; }; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$RUNTIME_FAKE"
  export AGENT_WORKFLOW_CODEX_BIN="$RUNTIME_FAKE"
fi
CMUX_PROBE_HELPER="$TMP_ROOT/cmux-probe-helper.sh"
cat > "$CMUX_PROBE_HELPER" <<'EOF'
if [ "${1:-}" = "--version" ]; then echo 'cmux 0.64.18'; exit 0; fi
if [ "${1:-}" = "workspace" ] && [ "${2:-}" = "create" ] && [ "${3:-}" = "--help" ]; then
  case "${CMUX_HELP_MODE:-live}" in
    direct) printf '%s\n' 'Usage: cmux workspace create --name NAME --cwd PATH --command TEXT'; exit 0 ;;
    unrelated) printf '%s\n' 'Usage: cmux workspace create [flags]'; exit 0 ;;
    *) printf '%s\n' '  create [flags]          Create a workspace (same flags as new-workspace)'; exit 0 ;;
  esac
fi
if [ "${1:-}" = "new-workspace" ] && [ "${2:-}" = "--help" ]; then echo '--cwd PATH --command TEXT'; exit 0; fi
if [ "${1:-}" = "workspace" ] && [ "${2:-}" = "list" ] && [ "${3:-}" = "--json" ]; then echo '{"workspaces":[]}'; exit 0; fi
EOF
export CMUX_PROBE_HELPER

FAILURES=0
pass() { echo "ok   - $1"; }
fail() { echo "NOT OK - $1"; FAILURES=$((FAILURES + 1)); }

# Asynchronous cmux fixtures are event-driven. Wait on the observable condition
# up to a declared deadline instead of sleeping a fixed span, and name the
# condition that never held when the deadline expires, so a timeout reports the
# missing event rather than a downstream race.
wait_for_condition() {
  condition_name="$1"
  deadline_seconds="$2"
  shift 2
  wait_polls=0
  wait_limit=$((deadline_seconds * 10))
  while [ "$wait_polls" -lt "$wait_limit" ]; do
    if "$@"; then
      return 0
    fi
    sleep 0.1
    wait_polls=$((wait_polls + 1))
  done
  fail "condition not met within ${deadline_seconds}s: $condition_name"
  return 1
}

deferred_commands_at_least() {
  [ -f "$DEFERRED_COMMANDS" ] || return 1
  [ "$(wc -l < "$DEFERRED_COMMANDS")" -ge "$1" ]
}
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
// The dispatch preflight deliberately refuses an allowlist that cannot touch
// any path in the planned base tree.  These tiny fixture repositories often
// begin with an empty commit, so give the generated state one real, tracked
// scope rather than inheriting the product fixture's packages/shared/** path.
let basePaths = execFileSync("git", ["-C", worktree, "ls-tree", "-r", "--name-only", "HEAD"], { encoding: "utf8" })
  .split("\n").filter(Boolean);
if (basePaths.length === 0) {
  const scope = "workflow-smoke-scope.txt";
  fs.writeFileSync(`${worktree}/${scope}`, "tracked fixture scope\n");
  execFileSync("git", ["-C", worktree, "add", "--", scope]);
  execFileSync("git", ["-C", worktree, "-c", "user.name=Smoke Test", "-c", "user.email=smoke@example.test", "commit", "-m", "add smoke scope"], { stdio: "ignore" });
  basePaths = [scope];
}
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
state.contract.touch_allowlist = [basePaths[0]];
state.contract.new_file_allowlist = [];
state.artifact_pointers = [
  { artifact_type: "pr_draft", path: `.review/ISSUE-${issue}-PR-DRAFT.json` },
  { artifact_type: "review", path: `.review/ISSUE-${issue}-REVIEW.json` }
];
delete state.round_control;
fs.writeFileSync(file, JSON.stringify(state, null, 2) + "\n");
fs.writeFileSync(
  `${worktree}/.review/ISSUE-${issue}-PROMPT.txt`,
  [
    "worker instructions",
    "<!-- agent-workflow:ac-block:start -->",
    "```json",
    JSON.stringify(state.acceptance.criteria),
    "```",
    "<!-- agent-workflow:ac-block:end -->",
    ""
  ].join("\n")
);
NODE
}

# --- setup: a real git worktree with a prompt file ---
WT="$TMP_ROOT/wt"
mkdir -p "$WT/.review"
git init -q "$WT"
git -C "$WT" -c user.name="Smoke Test" -c user.email="smoke@example.test" commit --allow-empty -q -m "init"
printf '%s\n' "prompt body" > "$WT/.review/ISSUE-301-PROMPT.txt"

# Allocation is validated before any marker or cmux side effect. Only the
# Codex implementation allocation may be auto-forwarded; Opus/Fable never is.
alloc_out="$TMP_ROOT/allocator-dry-run.out"
bash "$DISPATCH" --issue 301 --worktree "$WT" --tier trivial --allocate --allocator-role implementation --dry-run >"$alloc_out" 2>&1
ec=$?
if [ "$ec" -eq 0 ] && grep -q -- '--model gpt-5.6-terra --effort low' "$alloc_out"; then
  pass "implementation allocation forwards an explicit Codex model"
else
  fail "implementation allocation forwards an explicit Codex model (ec=$ec: $(cat "$alloc_out"))"
fi
default_tuple_out="$TMP_ROOT/default-tuple-dry-run.out"
bash "$DISPATCH" --issue 301 --worktree "$WT" --tier trivial --dry-run >"$default_tuple_out" 2>&1
ec=$?
if [ "$ec" -eq 0 ] && grep -q -- '--model gpt-5.6-terra --effort low' "$default_tuple_out"; then
  pass "write dispatch resolves a model and effort without --allocate"
else
  fail "write dispatch resolves a model and effort without --allocate (ec=$ec: $(cat "$default_tuple_out"))"
fi
node - "$PRODUCT_HOME/model-alloc.json" <<'NODE'
const fs=require("fs"); const file=process.argv[2]; const value=JSON.parse(fs.readFileSync(file,"utf8")); value.roles.implementation.model="gpt-5.6-luna"; value.roles.implementation.effort="xhigh"; fs.writeFileSync(file,JSON.stringify(value));
NODE
configured_tuple_out="$TMP_ROOT/configured-tuple-dry-run.out"
bash "$PRODUCT_DISPATCH" --issue 301 --worktree "$WT" --tier trivial --dry-run >"$configured_tuple_out" 2>&1
ec=$?
if [ "$ec" -eq 0 ] && grep -q -- '--model gpt-5.6-luna --effort xhigh' "$configured_tuple_out"; then
  pass "omitted-model dispatch honors the PRODUCT_HOME model allocation tuple"
else
  fail "omitted-model dispatch honors the PRODUCT_HOME model allocation tuple (ec=$ec: $(cat "$configured_tuple_out"))"
fi
# Keep later routing fixtures on the shipped allocation while this assertion
# proves that a worktree cannot override PRODUCT_HOME configuration.
cp "$ROOT/model-alloc.json" "$PRODUCT_HOME/model-alloc.json"
bad_alloc_out="$TMP_ROOT/allocator-review.stderr"
bash "$DISPATCH" --issue 301 --worktree "$WT" --tier trivial --allocate --allocator-role reviewer --dry-run >/dev/null 2>"$bad_alloc_out"
ec=$?
if [ "$ec" -eq 2 ] && grep -q "requires --role reviewer --produce-review" "$bad_alloc_out"; then
  pass "reviewer allocation is limited to reviewer publication"
else
  fail "reviewer allocation is limited to reviewer publication (ec=$ec: $(cat "$bad_alloc_out"))"
fi

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

# An explicit host policy refuses every initial-write tier before allocation or
# the remote compatibility probe. Manual tuples and dry-runs remain complete
# routing bypasses even while that policy is active.
ROUTE_HOST_STATE="$TMP_ROOT/route-host-state"
ROUTE_POLICY="$TMP_ROOT/route-policy.json"
GIT_COMMON_DIR="$(git -C "$WT" rev-parse --path-format=absolute --git-common-dir)"
printf '%s\n' '{"version":1,"rules":[{"when":{"runtime":"codex","role":"implementation"},"candidates":{"from":"model_alloc"},"fallback":"deny"}]}' > "$ROUTE_POLICY"
route_install_out="$TMP_ROOT/route-policy-install.out"
AGENT_WORKFLOW_HOST_STATE="$ROUTE_HOST_STATE" bash "$ROUTE" policy install --git-common-dir "$GIT_COMMON_DIR" --worktree "$WT" --policy-file "$ROUTE_POLICY" >"$route_install_out" 2>&1
if [ "$?" -eq 0 ]; then
  pass "host policy install enables an explicit dispatch opt-in"
else
  fail "host policy install enables an explicit dispatch opt-in ($(cat "$route_install_out"))"
fi
for policy_tier in trivial standard full_cluster; do
  policy_initial_out="$TMP_ROOT/policy-initial-$policy_tier.out"
  probe_sentinel="$TMP_ROOT/probe-called-$policy_tier"
  AGENT_WORKFLOW_HOST_STATE="$ROUTE_HOST_STATE" AGENT_WORKFLOW_MODEL_PROBE_CMD="touch '$probe_sentinel'; exit 9" bash "$DISPATCH" --issue 301 --worktree "$WT" --tier "$policy_tier" --round-state "$INITIAL_STATE" --manifest-revision 1 >"$policy_initial_out" 2>&1
  ec=$?
  if [ "$ec" -eq 3 ] && grep -q 'route_mode_unbound' "$policy_initial_out" && [ ! -e "$probe_sentinel" ]; then
    pass "policy initial $policy_tier refuses before model allocation probe"
  else
    fail "policy initial $policy_tier refuses before model allocation probe (ec=$ec: $(cat "$policy_initial_out"))"
  fi
done
manual_policy_out="$TMP_ROOT/manual-policy-bypass.out"
manual_probe="$TMP_ROOT/manual-policy-probe"
AGENT_WORKFLOW_HOST_STATE="$ROUTE_HOST_STATE" AGENT_WORKFLOW_MODEL_PROBE_CMD="touch '$manual_probe'; exit 9" bash "$DISPATCH" --issue 301 --worktree "$WT" --tier standard --round-state "$INITIAL_STATE" --manifest-revision 1 --model gpt-5.6-terra --effort low >"$manual_policy_out" 2>&1
ec=$?
if [ "$ec" -eq 2 ] && [ -e "$manual_probe" ] && grep -q 'model_compatibility_unavailable' "$manual_policy_out" && ! grep -q 'route_mode_unbound' "$manual_policy_out"; then
  pass "manual tuple bypasses active routing policy"
else
  fail "manual tuple bypasses active routing policy (ec=$ec: $(cat "$manual_policy_out"))"
fi
policy_dry_run_out="$TMP_ROOT/policy-dry-run-bypass.out"
AGENT_WORKFLOW_HOST_STATE="$ROUTE_HOST_STATE" bash "$DISPATCH" --issue 301 --worktree "$WT" --tier standard --round-state "$INITIAL_STATE" --manifest-revision 1 --dry-run >"$policy_dry_run_out" 2>&1
ec=$?
if [ "$ec" -eq 0 ] && ! grep -q 'route_mode_unbound' "$policy_dry_run_out"; then
  pass "dry-run bypasses active routing policy"
else
  fail "dry-run bypasses active routing policy (ec=$ec: $(cat "$policy_dry_run_out"))"
fi
AGENT_WORKFLOW_HOST_STATE="$ROUTE_HOST_STATE" bash "$ROUTE" policy deactivate --git-common-dir "$GIT_COMMON_DIR" --worktree "$WT" >/dev/null 2>&1
if [ "$?" -eq 0 ]; then
  pass "host policy deactivate restores no-policy dispatch"
else
  fail "host policy deactivate restores no-policy dispatch"
fi
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

# Standard/Full writes fail before launch when the worker-facing AC block is
# absent, then accept only the exact canonical copy.
printf '%s\n' 'prompt without canonical acceptance criteria' > "$WT/.review/ISSUE-301-PROMPT.txt"
prompt_ac_denied="$TMP_ROOT/prompt-ac-denied.out"
bash "$DISPATCH" --issue 301 --worktree "$WT" --tier standard --round-state "$INITIAL_STATE" --manifest-revision 1 --dry-run >"$prompt_ac_denied" 2>&1
ec=$?
if [ "$ec" -eq 1 ] && grep -q "prompt AC gate denied" "$prompt_ac_denied"; then
  pass "Standard write rejects a prompt without the canonical AC block before launch"
else
  fail "Standard write rejects a prompt without the canonical AC block before launch (ec=$ec: $(cat "$prompt_ac_denied"))"
fi
node - "$INITIAL_STATE" "$WT/.review/ISSUE-301-PROMPT.txt" <<'NODE'
const fs = require("fs");
const [stateFile, promptFile] = process.argv.slice(2);
const state = JSON.parse(fs.readFileSync(stateFile, "utf8"));
fs.writeFileSync(promptFile, ["worker instructions", "<!-- agent-workflow:ac-block:start -->", "```json", JSON.stringify(state.acceptance.criteria), "```", "<!-- agent-workflow:ac-block:end -->", ""].join("\n"));
NODE

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
if [ "$ec" -eq 0 ] && printf '%s\n' "$timeout_printed" | grep -q -- "--role architect" && printf '%s\n' "$timeout_printed" | grep -q -- "--mode read" && printf '%s\n' "$timeout_printed" | grep -q -- "--first-progress-timeout 1500" && printf '%s\n' "$timeout_printed" | grep -q -- "--stall-timeout 900"; then
  pass "dry-run maps legacy read-only to an explicit read role and watchdog timeouts"
else
  fail "dry-run maps legacy read-only and watchdog timeout flags (ec=$ec: $timeout_printed)"
fi

if printf '%s\n' "$printed" | grep -q -- "--role implementation" && printf '%s\n' "$printed" | grep -q -- "--mode write" && ! printf '%s\n' "$printed" | grep -q -- "--first-progress-timeout" && ! printf '%s\n' "$printed" | grep -q -- "--stall-timeout"; then
  pass "dry-run defaults legacy writes to an explicit implementation role"
else
  fail "dry-run omits optional watchdog timeouts when unspecified (got: $printed)"
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
. "$CMUX_PROBE_HELPER"
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
cp "$SCRIPT_DIR/../dispatch-core.sh" "$RUNNER_FIXTURE/dispatch-core.sh"
cp "$SCRIPT_DIR/../agent-runtime.sh" "$RUNNER_FIXTURE/agent-runtime.sh"
mkdir -p "$RUNNER_FIXTURE/adapters" "$TMP_ROOT/schemas" "$RUNNER_FIXTURE/lib"
cp "$SCRIPT_DIR/../adapters/cmux.sh" "$RUNNER_FIXTURE/adapters/cmux.sh"
cp "$ROOT/schemas/transport_receipt.schema.json" "$TMP_ROOT/schemas/transport_receipt.schema.json"
cp "$SCRIPT_DIR/../lib/json-schema-subset.cjs" "$RUNNER_FIXTURE/lib/json-schema-subset.cjs"
cp "$SCRIPT_DIR/../lib/cmux-handles.cjs" "$RUNNER_FIXTURE/lib/cmux-handles.cjs"
cp "$SCRIPT_DIR/../lib/transport-registry.cjs" "$RUNNER_FIXTURE/lib/transport-registry.cjs"
cat > "$RUNNER_FIXTURE/agent-watchdog.sh" <<'EOF'
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
chmod +x "$RUNNER_FIXTURE/agent-watchdog.sh"

RUNNER_BIN="$TMP_ROOT/bin-runner-cmux"
mkdir -p "$RUNNER_BIN"
cat > "$RUNNER_BIN/cmux" <<'EOF'
#!/usr/bin/env bash
. "$CMUX_PROBE_HELPER"
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
printf '%s\n' '{"id":"cmux-runner"}'
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
  && grep -Fx -- "--role" "$TMP_ROOT/watchdog-argv.txt" >/dev/null \
  && grep -Fx -- "architect" "$TMP_ROOT/watchdog-argv.txt" >/dev/null \
  && grep -Fx -- "--mode" "$TMP_ROOT/watchdog-argv.txt" >/dev/null \
  && grep -Fx -- "read" "$TMP_ROOT/watchdog-argv.txt" >/dev/null \
  && grep -Fx -- "--first-progress-timeout" "$TMP_ROOT/watchdog-argv.txt" >/dev/null && grep -Fx -- "1500" "$TMP_ROOT/watchdog-argv.txt" >/dev/null \
  && grep -Fx -- "--stall-timeout" "$TMP_ROOT/watchdog-argv.txt" >/dev/null && grep -Fx -- "900" "$TMP_ROOT/watchdog-argv.txt" >/dev/null; then
  pass "deep dispatch uses a short relative runner and preserves watchdog argv"
else
  fail "deep dispatch uses a short relative runner and preserves watchdog argv (ec=$ec: $(cat "$runner_transport_out"))"
fi

# --- capability proof comes from workspace create --help itself (AC-112) ---
# The dispatch seam admits a delegation-style help (live 0.64.22 wording) and
# a direct --cwd/--command listing, and refuses an unrelated summary before
# any runner is created, even though the legacy new-workspace surface in this
# fake still advertises both flags.
CAP_WT="$TMP_ROOT/capability-wt"
mkdir -p "$CAP_WT/.review"
git init -q "$CAP_WT"
git -C "$CAP_WT" -c user.name="Smoke Test" -c user.email="smoke@example.test" commit --allow-empty -q -m "init"
capability_issue=311
for help_mode in live direct; do
  printf '%s\n' "prompt body" > "$CAP_WT/.review/ISSUE-${capability_issue}-PROMPT.txt"
  cap_mode_out="$TMP_ROOT/capability-$help_mode.out"
  WATCHDOG_ARGV_FILE="$TMP_ROOT/capability-$help_mode-watchdog-argv.txt" \
  CMUX_HELP_MODE="$help_mode" CMUX_DISPATCH_POLL_INTERVAL=1 PATH="$RUNNER_BIN:$PATH" \
    bash "$RUNNER_FIXTURE/cmux-dispatch.sh" --issue "$capability_issue" --worktree "$CAP_WT" \
    --read-only --poll-timeout 3 >"$cap_mode_out" 2>&1
  ec=$?
  if [ "$ec" -eq 0 ] && grep -q "fresh RUN.json present" "$cap_mode_out"; then
    pass "AC-112 $help_mode workspace create --help proves --cwd/--command through dispatch"
  else
    fail "AC-112 $help_mode workspace create --help dispatch (ec=$ec: $(cat "$cap_mode_out"))"
  fi
  capability_issue=$((capability_issue + 1))
done
printf '%s\n' "prompt body" > "$CAP_WT/.review/ISSUE-${capability_issue}-PROMPT.txt"
cap_refusal_out="$TMP_ROOT/capability-unrelated.out"
CMUX_HELP_MODE=unrelated CMUX_DISPATCH_POLL_INTERVAL=1 PATH="$RUNNER_BIN:$PATH" \
  bash "$RUNNER_FIXTURE/cmux-dispatch.sh" --issue "$capability_issue" --worktree "$CAP_WT" \
  --read-only --poll-timeout 1 >"$cap_refusal_out" 2>&1
ec=$?
if [ "$ec" -eq 2 ] && grep -q 'required_capability_missing' "$cap_refusal_out" \
  && ! find "$CAP_WT/.review" -type d -name "ISSUE-${capability_issue}-launch.*" | grep -q .; then
  pass "AC-112 unrelated workspace create --help is refused before any launch runner"
else
  fail "AC-112 unrelated workspace create --help refusal (ec=$ec: $(cat "$cap_refusal_out"))"
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
# The waits below are condition/deadline bound, not fixed sleeps (AC-OBS-3).
printf '%s\n' "seat A" > "$DEEP_WT/.review/ISSUE-335-PROMPT-A.txt"
printf '%s\n' "seat B" > "$DEEP_WT/.review/ISSUE-335-PROMPT-B.txt"
DEFERRED_BIN="$TMP_ROOT/bin-deferred-cmux"
mkdir -p "$DEFERRED_BIN"
cat > "$DEFERRED_BIN/cmux" <<'EOF'
#!/usr/bin/env bash
. "$CMUX_PROBE_HELPER"
command=""
shift 2
while [ $# -gt 0 ]; do
  case "$1" in
    --command) command="$2"; shift 2 ;;
    *) shift 1 ;;
  esac
done
printf '%s\n' "$command" >> "$DEFERRED_COMMANDS"
printf '%s\n' '{"id":"cmux-deferred"}'
exit 0
EOF
chmod +x "$DEFERRED_BIN/cmux"

DEFERRED_COMMANDS="$TMP_ROOT/deferred-commands.txt"
: > "$DEFERRED_COMMANDS"
DEFERRED_COMMANDS="$DEFERRED_COMMANDS" CMUX_DISPATCH_POLL_INTERVAL=1 PATH="$DEFERRED_BIN:$PATH" \
bash "$RUNNER_FIXTURE/cmux-dispatch.sh" --issue 335 --worktree "$DEEP_WT" \
  --prompt-file .review/ISSUE-335-PROMPT-A.txt --read-only --poll-timeout 5 >"$TMP_ROOT/overlap-a.out" 2>&1 &
overlap_a_pid=$!
wait_for_condition "seat A workspace create recorded its launch command" 3 \
  deferred_commands_at_least 1
DEFERRED_COMMANDS="$DEFERRED_COMMANDS" CMUX_DISPATCH_POLL_INTERVAL=1 PATH="$DEFERRED_BIN:$PATH" \
bash "$RUNNER_FIXTURE/cmux-dispatch.sh" --issue 335 --worktree "$DEEP_WT" \
  --prompt-file .review/ISSUE-335-PROMPT-B.txt --read-only --poll-timeout 5 >"$TMP_ROOT/overlap-b.out" 2>&1 &
overlap_b_pid=$!
wait_for_condition "seat B workspace create recorded its launch command" 3 \
  deferred_commands_at_least 2
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

# An asynchronous fixture event that never arrives must be reported by name
# rather than falling through into an unrelated downstream assertion (AC-OBS-3).
never_true() { return 1; }
timeout_report="$(wait_for_condition "fixture event that never arrives" 1 never_true 2>&1)"
if printf '%s\n' "$timeout_report" \
  | grep -F -q -- 'condition not met within 1s: fixture event that never arrives'; then
  pass "missing asynchronous event fails with the named condition"
else
  fail "missing asynchronous event fails with the named condition (report=$timeout_report)"
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
  const artifact={schema_version:"1",artifact_type:"verify_result",producer_role:"VERIFIER",issue,branch:"main",head_sha:head,content_sha256:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",cwd:worktree,verify_cmd:"smoke verify",db_target:{host:"localhost",database:"smoke",role:"verifier"},clean_state:{sentinel:{expected:"clean",actual:"clean"},migration_hash:{expected:"same",actual:"same"},role:{name:"verifier",superuser:false}},verdict:{passed:0,failed:1,pending:0,exit_code:1},classifier:"FAIL",failures:[{code:"failed_tests",expected:"0",actual:"1"}],created_at:"2026-07-20T00:00:00Z"};
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
printf '%s\n' '{"schema_version":"1","artifact_type":"codex_run","issue":307,"attempt":1,"started_at":"2026-07-13T00:00:00Z","updated_at":"2026-07-13T00:00:00Z","status":"exited","exit_code":1}' > "$ADMIT_WT/.review/ISSUE-307-RUN.json"
cp "$ROOT/schemas/fixtures/round_state.valid.json" "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json"
node -e '
  const fs=require("fs"); const crypto=require("crypto"); const path=require("path");
  const [file,worktree,head]=process.argv.slice(1); const value=JSON.parse(fs.readFileSync(file,"utf8"));
  const evidencePath=".review/evidence/F-307.json"; const content=fs.readFileSync(path.join(worktree,evidencePath));
  value.issue={number:307,title:"redispatch admission"}; value.revision=5; value.base_branch="main"; value.base_sha=head; value.head_sha=head; value.worktree_path=worktree; value.contract.touch_allowlist=[".review/evidence/**"]; value.contract.new_file_allowlist=[];
  value.round_control={failures:[{id:"F-1",dispatch_ordinal:1,status:"open",primary_origin:"implementation",secondary_origins:[],failed_ac_ids:["AC-1"],owner:"CONDUCTOR",next_action:{kind:"implementation_fix",summary:"apply the classified fix"},evidence:[{kind:"verify",path:evidencePath,content_sha256:crypto.createHash("sha256").update(content).digest("hex"),head_sha:process.argv[4]}]}]};
  fs.writeFileSync(file,JSON.stringify(value));
' "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json" "$ADMIT_WT" "$ADMIT_HEAD" "$ADMIT_EVIDENCE_HEAD"
node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.round_control.next_dispatch_ordinal=2; if(v.round_control.diagnosis&&v.round_control.diagnosis.integrated_fix_batch) v.round_control.diagnosis.integrated_fix_batch.dispatch_ordinal=6; fs.writeFileSync(f,JSON.stringify(v));' "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json"
node - "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json" "$ADMIT_WT/.review/ISSUE-307-PROMPT.txt" <<'NODE'
const fs = require("fs");
const [stateFile, promptFile] = process.argv.slice(2);
const state = JSON.parse(fs.readFileSync(stateFile, "utf8"));
fs.writeFileSync(promptFile, ["worker instructions", "<!-- agent-workflow:ac-block:start -->", "```json", JSON.stringify(state.acceptance.criteria), "```", "<!-- agent-workflow:ac-block:end -->", ""].join("\n"));
NODE
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

# A bad redispatch prompt must be rejected before the durable issue/ordinal
# admission or integrated-fix singleton is consumed, so fixing the prompt can
# retry the same canonical admission.
printf '%s\n' 'bad redispatch prompt' > "$ADMIT_WT/.review/ISSUE-307-PROMPT.txt"
admission_bad_prompt="$TMP_ROOT/admission-bad-prompt.out"
PATH="$BIN:$PATH" bash "$DISPATCH" --issue 307 --worktree "$ADMIT_WT" --round-state "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json" --manifest-revision 5 --poll-timeout 3 >"$admission_bad_prompt" 2>&1
ec=$?
admit_common_raw="$(git -C "$ADMIT_WT" rev-parse --git-common-dir)"
case "$admit_common_raw" in
  /*) admit_common="$admit_common_raw" ;;
  *) admit_common="$(cd "$ADMIT_WT/$admit_common_raw" && pwd -P)" ;;
esac
if [ "$ec" -eq 1 ] && grep -q "prompt AC gate denied" "$admission_bad_prompt" \
  && [ ! -e "$admit_common/agent-workflow/redispatch-admissions/issue-307-dispatch-2" ] \
  && [ ! -e "$admit_common/agent-workflow/redispatch-admissions/issue-307-integrated-fix" ]; then
  pass "bad redispatch prompt leaves durable admission retryable"
else
  fail "bad redispatch prompt leaves durable admission retryable (ec=$ec: $(cat "$admission_bad_prompt"))"
fi
node - "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json" "$ADMIT_WT/.review/ISSUE-307-PROMPT.txt" <<'NODE'
const fs = require("fs");
const [stateFile, promptFile] = process.argv.slice(2);
const state = JSON.parse(fs.readFileSync(stateFile, "utf8"));
fs.writeFileSync(promptFile, ["worker instructions", "<!-- agent-workflow:ac-block:start -->", "```json", JSON.stringify(state.acceptance.criteria), "```", "<!-- agent-workflow:ac-block:end -->", ""].join("\n"));
NODE

admission_root="$admit_common/agent-workflow/redispatch-admissions"
admission_dry_lock="$admission_root/.issue-307-lock/.admission-lock.json"
mkdir -p "$(dirname "$admission_dry_lock")"
printf '%s\n' '{"pid":999999,"admission_key":"issue-307-dispatch-2","status":"locked"}' > "$admission_dry_lock"
admission_dry_lock_sha="$(shasum -a 256 "$admission_dry_lock" | awk '{print $1}')"
admission_dry_state_sha="$(shasum -a 256 "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json" | awk '{print $1}')"
admission_dry="$TMP_ROOT/admission-dry.out"
bash "$DISPATCH" --issue 307 --worktree "$ADMIT_WT" --round-state "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json" --manifest-revision 5 --dry-run >"$admission_dry" 2>&1
ec=$?
if [ "$ec" -eq 0 ] && grep -q "redispatch admission: mode=normal" "$admission_dry" && [ -f "$admission_dry_lock" ] && [ "$(shasum -a 256 "$admission_dry_lock" | awk '{print $1}')" = "$admission_dry_lock_sha" ] && [ "$(shasum -a 256 "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json" | awk '{print $1}')" = "$admission_dry_state_sha" ] && ! find "$ADMIT_WT/.review" -maxdepth 1 -type d -name '.redispatch-admission-*' | grep -q .; then
  pass "dry-run checks redispatch policy without mutating durable admission"
else
  fail "dry-run checks redispatch policy without mutating durable admission (ec=$ec: $(cat "$admission_dry"))"
fi
rmdir "$(dirname "$admission_dry_lock")" 2>/dev/null || true

# Dispatch proves declared modification scope against base_sha before it can
# consume an ordinal. A typo/glob for a future path and an "new" existing path
# are both rejected; only exact absent new_file_allowlist entries are allowed.
ALLOWLIST_MISS_STATE="$TMP_ROOT/allowlist-miss-state.json"
cp "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json" "$ALLOWLIST_MISS_STATE"
node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.contract.touch_allowlist=["missing/scope/**"]; fs.writeFileSync(f,JSON.stringify(v));' "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json"
allowlist_miss="$TMP_ROOT/allowlist-miss.out"
bash "$DISPATCH" --issue 307 --worktree "$ADMIT_WT" --round-state "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json" --manifest-revision 5 --dry-run >"$allowlist_miss" 2>&1
allowlist_miss_ec=$?
cp "$ALLOWLIST_MISS_STATE" "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json"
ALLOWLIST_NEW_STATE="$TMP_ROOT/allowlist-new-state.json"
cp "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json" "$ALLOWLIST_NEW_STATE"
node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.contract.new_file_allowlist=[".review/evidence/F-307.json"]; fs.writeFileSync(f,JSON.stringify(v));' "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json"
allowlist_new="$TMP_ROOT/allowlist-new.out"
bash "$DISPATCH" --issue 307 --worktree "$ADMIT_WT" --round-state "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json" --manifest-revision 5 --dry-run >"$allowlist_new" 2>&1
allowlist_new_ec=$?
cp "$ALLOWLIST_NEW_STATE" "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json"
ALLOWLIST_SCOPE_STATE="$TMP_ROOT/allowlist-scope-state.json"
cp "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json" "$ALLOWLIST_SCOPE_STATE"
node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.contract.new_file_allowlist=["future/outside.txt"]; fs.writeFileSync(f,JSON.stringify(v));' "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json"
allowlist_scope="$TMP_ROOT/allowlist-scope.out"
bash "$DISPATCH" --issue 307 --worktree "$ADMIT_WT" --round-state "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json" --manifest-revision 5 --dry-run >"$allowlist_scope" 2>&1
allowlist_scope_ec=$?
cp "$ALLOWLIST_SCOPE_STATE" "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json"
if [ "$allowlist_miss_ec" -eq 2 ] && grep -q "touch_allowlist_no_base_match" "$allowlist_miss" \
  && [ "$allowlist_new_ec" -eq 2 ] && grep -q "new_file_allowlist_not_new" "$allowlist_new" \
  && [ "$allowlist_scope_ec" -eq 2 ] && grep -q "new_file_allowlist_not_in_touch_allowlist" "$allowlist_scope"; then
  pass "dispatch preflight proves existing scope and bounded exact new-file exception"
else
  fail "dispatch touch allowlist preflight was bypassed (missing=$allowlist_miss_ec new=$allowlist_new_ec scope=$allowlist_scope_ec)"
fi

ADMIT_BIN="$TMP_ROOT/bin-admission-cmux"
mkdir -p "$ADMIT_BIN"
cat > "$ADMIT_BIN/cmux" <<EOF
#!/usr/bin/env bash
. "$CMUX_PROBE_HELPER"
printf '%s\n' '{"schema_version":"1","artifact_type":"codex_run","issue":307,"attempt":2,"started_at":"2026-07-20T10:00:00Z","updated_at":"2026-07-20T10:00:00Z","status":"running"}' > "$ADMIT_WT/.review/ISSUE-307-RUN.json"
printf '%s\n' '{"id":"cmux-admit"}'
exit 0
EOF
chmod +x "$ADMIT_BIN/cmux"

# A policy-selected canonical redispatch binds the same opaque digest to the
# authoritative ordinal and its integrated-fix recovery companion. This uses
# an isolated repository so the ordinary no-policy admission checks below keep
# proving their legacy digest-free record shape.
ROUTE_ADMIT_WT="$TMP_ROOT/wt-route-admission"
git clone -q "$ADMIT_WT" "$ROUTE_ADMIT_WT"
mkdir -p "$ROUTE_ADMIT_WT/.review/evidence"
ROUTE_ADMIT_STATE="$ROUTE_ADMIT_WT/.review/ISSUE-308-ROUND-STATE.json"
cp "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json" "$ROUTE_ADMIT_STATE"
node - "$ROUTE_ADMIT_WT" "$ROUTE_ADMIT_STATE" "$ADMIT_EVIDENCE_HEAD" <<'NODE'
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const [worktree, stateFile, evidenceHead] = process.argv.slice(2);
const artifact = JSON.parse(fs.readFileSync(path.join(worktree, ".review/evidence/F-307.json"), "utf8"));
artifact.issue = 308;
artifact.cwd = worktree;
for (const name of ["F-308.json", "F-308-2.json", "hard-fact-308.json"]) {
  fs.writeFileSync(path.join(worktree, ".review/evidence", name), JSON.stringify(artifact));
}
const state = JSON.parse(fs.readFileSync(stateFile, "utf8"));
const ref = name => {
  const relative = `.review/evidence/${name}`;
  const content = fs.readFileSync(path.join(worktree, relative));
  return { kind: "verify", path: relative, content_sha256: crypto.createHash("sha256").update(content).digest("hex"), head_sha: evidenceHead };
};
state.issue = { number: 308, title: "route digest binding" };
state.worktree_path = worktree;
const first = state.round_control.failures[0];
first.id = "F-1";
first.dispatch_ordinal = 1;
first.evidence = [ref("F-308.json")];
const second = JSON.parse(JSON.stringify(first));
second.id = "F-2";
second.dispatch_ordinal = 2;
second.evidence = [ref("F-308-2.json")];
state.round_control = {
  next_dispatch_ordinal: 3,
  failures: [first, second],
  diagnosis: {
    trigger: "same_origin",
    failure_ids: ["F-1", "F-2"],
    records: [
      { kind: "oracle_contract_recheck", summary: "oracle checked", evidence: { kind: "live_probe", path: ".review/evidence/oracle.json", content_sha256: crypto.createHash("sha256").update(fs.readFileSync(path.join(worktree, ".review/evidence/oracle.json"))).digest("hex"), head_sha: evidenceHead } },
      { kind: "hard_fact", summary: "hard fact", evidence: { kind: "verify", path: ".review/evidence/hard-fact-308.json", content_sha256: crypto.createHash("sha256").update(fs.readFileSync(path.join(worktree, ".review/evidence/hard-fact-308.json"))).digest("hex"), head_sha: evidenceHead } },
      { kind: "passing_analog", summary: "passing analog", instruction: "guess_forbidden_copy_passing_analog_to_parity", evidence: { kind: "diff", path: ".review/evidence/passing.json", content_sha256: crypto.createHash("sha256").update(fs.readFileSync(path.join(worktree, ".review/evidence/passing.json"))).digest("hex"), head_sha: evidenceHead } }
    ],
    integrated_fix_batch: { dispatch_ordinal: 3, failure_ids: ["F-1", "F-2"], status: "ready" }
  }
};
fs.writeFileSync(stateFile, JSON.stringify(state));
fs.writeFileSync(path.join(worktree, ".review/ISSUE-308-PROMPT.txt"), ["worker instructions", "<!-- agent-workflow:ac-block:start -->", "```json", JSON.stringify(state.acceptance.criteria), "```", "<!-- agent-workflow:ac-block:end -->", ""].join("\n"));
fs.writeFileSync(path.join(worktree, ".review/ISSUE-308-RUN.json"), '{"schema_version":"1","artifact_type":"codex_run","issue":308,"attempt":1,"started_at":"2026-07-13T00:00:00Z","updated_at":"2026-07-13T00:00:00Z","status":"exited","exit_code":1}\n');
NODE
ROUTE_ADMIT_COMMON="$(git -C "$ROUTE_ADMIT_WT" rev-parse --path-format=absolute --git-common-dir)"
ROUTE_ADMIT_HOST_STATE="$TMP_ROOT/route-admission-host-state"
ROUTE_ADMIT_POLICY="$TMP_ROOT/route-admission-policy.json"
printf '%s\n' '{"version":1,"rules":[{"when":{"runtime":"codex","role":"implementation"},"candidates":{"from":"model_alloc"},"fallback":"deny"}]}' > "$ROUTE_ADMIT_POLICY"
route_admit_install="$TMP_ROOT/route-admission-policy-install.out"
AGENT_WORKFLOW_HOST_STATE="$ROUTE_ADMIT_HOST_STATE" bash "$ROUTE" policy install --git-common-dir "$ROUTE_ADMIT_COMMON" --worktree "$ROUTE_ADMIT_WT" --policy-file "$ROUTE_ADMIT_POLICY" >"$route_admit_install" 2>&1
ROUTE_ADMIT_BIN="$TMP_ROOT/bin-route-admission-cmux"
mkdir -p "$ROUTE_ADMIT_BIN"
cat > "$ROUTE_ADMIT_BIN/cmux" <<EOF
#!/usr/bin/env bash
. "$CMUX_PROBE_HELPER"
printf '%s\n' '{"schema_version":"1","artifact_type":"codex_run","issue":308,"attempt":2,"started_at":"2026-07-20T10:00:00Z","updated_at":"2026-07-20T10:00:00Z","status":"running"}' > "$ROUTE_ADMIT_WT/.review/ISSUE-308-RUN.json"
printf '%s\n' '{"id":"cmux-route-admit"}'
exit 0
EOF
chmod +x "$ROUTE_ADMIT_BIN/cmux"
route_admit_wrong_tier="$TMP_ROOT/route-admission-wrong-tier.out"
AGENT_WORKFLOW_HOST_STATE="$ROUTE_ADMIT_HOST_STATE" CMUX_DISPATCH_POLL_INTERVAL=1 PATH="$ROUTE_ADMIT_BIN:$PATH" \
  bash "$DISPATCH" --issue 308 --worktree "$ROUTE_ADMIT_WT" --tier standard --round-state "$ROUTE_ADMIT_STATE" --manifest-revision 5 --poll-timeout 3 >"$route_admit_wrong_tier" 2>&1
route_admit_wrong_tier_ec=$?
if [ "$route_admit_wrong_tier_ec" -eq 3 ] && grep -q 'route_demand_invalid' "$route_admit_wrong_tier"; then
  pass "policy redispatch derives tier from canonical ROUND-STATE"
else
  fail "policy redispatch rejects a CLI tier that disagrees with ROUND-STATE (ec=$route_admit_wrong_tier_ec: $(cat "$route_admit_wrong_tier"))"
fi
route_admit_out="$TMP_ROOT/route-admission.out"
AGENT_WORKFLOW_HOST_STATE="$ROUTE_ADMIT_HOST_STATE" CMUX_DISPATCH_POLL_INTERVAL=1 PATH="$ROUTE_ADMIT_BIN:$PATH" \
  bash "$DISPATCH" --issue 308 --worktree "$ROUTE_ADMIT_WT" --round-state "$ROUTE_ADMIT_STATE" --manifest-revision 5 --poll-timeout 3 >"$route_admit_out" 2>&1
route_admit_ec=$?
route_admit_root="$ROUTE_ADMIT_COMMON/agent-workflow/redispatch-admissions"
if [ "$route_admit_ec" -eq 0 ] && node - "$route_admit_root/issue-308-dispatch-3/.admission-transaction.json" "$route_admit_root/issue-308-integrated-fix/.admission-transaction.json" "$ROUTE_ADMIT_WT/.review/ISSUE-308-TRANSPORT.json" <<'NODE'
const fs = require("fs");
const [ordinalFile, singletonFile, receiptFile] = process.argv.slice(2);
try {
  const ordinal = JSON.parse(fs.readFileSync(ordinalFile, "utf8"));
  const singleton = JSON.parse(fs.readFileSync(singletonFile, "utf8"));
  const receipt = JSON.parse(fs.readFileSync(receiptFile, "utf8"));
  process.exit(/^[a-f0-9]{64}$/.test(ordinal.route_digest || "") && ordinal.route_digest === singleton.route_digest && ordinal.routing && ordinal.routing.tier === "full_cluster" && ordinal.routing.runtime === "codex" && ordinal.routing.transport === "cmux" && ordinal.routing.selected.model === "gpt-5.6-terra" && ordinal.routing.selected.effort === "low" && receipt.schema_version === "3" && receipt.routing && receipt.routing.route_digest === ordinal.route_digest && receipt.routing.selected.model === "gpt-5.6-terra" && receipt.routing.selected.effort === "low" ? 0 : 1);
} catch (_) { process.exit(1); }
NODE
then
  pass "policy redispatch binds one route digest to admission and receipt provenance"
else
  fail "policy redispatch route digest receipt binding (ec=$route_admit_ec: $(cat "$route_admit_out"))"
fi
# A live issue-lock owner remains authoritative even when its lock file is
# older than the recovery threshold. Staleness may only reclaim a dead owner.
live_lock_dir="$admission_root/.issue-307-lock"
live_lock_file="$live_lock_dir/.admission-lock.json"
live_singleton="$admission_root/issue-307-integrated-fix"
live_ordinal="$admission_root/issue-307-dispatch-2"
mkdir -p "$live_lock_dir" "$live_singleton" "$live_ordinal"
printf '{"pid":%s,"admission_key":"issue-307-dispatch-2","status":"locked"}\n' "$$" > "$live_lock_file"
node -e 'const fs=require("fs"); fs.utimesSync(process.argv[1], new Date(0), new Date(0));' "$live_lock_file"
if node "$SCRIPT_DIR/../lib/admission-recover.cjs" recover-lock "$live_lock_file" "$live_singleton" "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json" 307 >/dev/null 2>&1; then
  live_lock_ec=0
else
  live_lock_ec=$?
fi
if [ "$live_lock_ec" -eq 1 ] && [ -f "$live_lock_file" ] && [ -d "$live_singleton" ] && [ -d "$live_ordinal" ]; then
  pass "stale-looking issue lock is never reclaimed from a live owner"
else
  fail "stale-looking live issue lock was reclaimed (ec=$live_lock_ec)"
fi
rmdir "$live_ordinal" "$live_singleton" 2>/dev/null || true
rm -f "$live_lock_file"
rmdir "$live_lock_dir" 2>/dev/null || true
# Older dispatchers could be SIGKILLed after mkdir(.issue-N-lock) and before
# owner JSON existed. Current acquire-lock publishes owner JSON before rename,
# so an ownerless visible directory is provably an old crash orphan and can be
# reclaimed without stealing a live current owner.
mkdir -p "$live_lock_dir"
if node "$SCRIPT_DIR/../lib/admission-recover.cjs" recover-lock "$live_lock_file" "$live_singleton" "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json" 307 >/dev/null 2>&1 \
  && [ ! -e "$live_lock_dir" ] \
  && node "$SCRIPT_DIR/../lib/admission-recover.cjs" acquire-lock "$live_lock_file" "$live_singleton" "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json" 307 issue-307-dispatch-2 "$$" >/dev/null 2>&1 \
  && node -e 'const fs=require("fs"); const v=JSON.parse(fs.readFileSync(process.argv[1])); process.exit(v.pid===Number(process.argv[2]) ? 0 : 1)' "$live_lock_file" "$$" \
  && node "$SCRIPT_DIR/../lib/admission-recover.cjs" release-lock "$live_lock_file" >/dev/null 2>&1; then
  pass "SIGKILL-era empty issue lock is reclaimed while current locks publish an owner atomically"
else
  fail "issue lock ownership protocol did not recover empty crash orphan safely"
fi
admission_first="$TMP_ROOT/admission-first.out"
CMUX_DISPATCH_POLL_INTERVAL=1 PATH="$ADMIT_BIN:$PATH" bash "$DISPATCH" --issue 307 --worktree "$ADMIT_WT" --round-state "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json" --manifest-revision 5 --poll-timeout 3 >"$admission_first" 2>&1
first_ec=$?
admission_second="$TMP_ROOT/admission-second.out"
CMUX_DISPATCH_POLL_INTERVAL=1 PATH="$ADMIT_BIN:$PATH" bash "$DISPATCH" --issue 307 --worktree "$ADMIT_WT" --round-state "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json" --manifest-revision 5 --poll-timeout 3 >"$admission_second" 2>&1
second_ec=$?
if [ "$first_ec" -eq 0 ] && [ "$second_ec" -eq 2 ] && grep -q "key=issue-307-dispatch-2" "$admission_first" && grep -q "unbound_last_admission" "$admission_second" \
  && node - "$admission_root/issue-307-dispatch-2/.admission-transaction.json" <<'NODE'
const fs = require("fs");
try {
  const transaction = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  process.exit(Object.prototype.hasOwnProperty.call(transaction, "route_digest") ? 1 : 0);
} catch (_) { process.exit(1); }
NODE
then
  pass "no-policy redispatch keeps its admission record digest-free"
else
  fail "no-policy redispatch admission shape (first=$first_ec second=$second_ec: $(cat "$admission_second"))"
fi

node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.revision=6; fs.writeFileSync(f,JSON.stringify(v));' "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json"
admission_revision_bump="$TMP_ROOT/admission-revision-bump.out"
CMUX_DISPATCH_POLL_INTERVAL=1 PATH="$ADMIT_BIN:$PATH" bash "$DISPATCH" --issue 307 --worktree "$ADMIT_WT" --round-state "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json" --manifest-revision 6 --poll-timeout 3 >"$admission_revision_bump" 2>&1
ec=$?
if [ "$ec" -eq 2 ] && grep -q "unbound_last_admission" "$admission_revision_bump"; then
  pass "manifest revision bump cannot bypass missing failure evidence"
else
  fail "manifest revision bump bypassed missing failure evidence (ec=$ec: $(cat "$admission_revision_bump"))"
fi

RECREATED_WT="$TMP_ROOT/wt-recreated-admission"
git -C "$ADMIT_WT" worktree add --detach -q "$RECREATED_WT" "$ADMIT_HEAD"
mkdir -p "$RECREATED_WT/.review"
cp "$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json" "$RECREATED_WT/.review/ISSUE-307-ROUND-STATE.json"
node - "$RECREATED_WT/.review/ISSUE-307-ROUND-STATE.json" "$RECREATED_WT/.review/ISSUE-307-PROMPT.txt" <<'NODE'
const fs = require("fs");
const [stateFile, promptFile] = process.argv.slice(2);
const state = JSON.parse(fs.readFileSync(stateFile, "utf8"));
fs.writeFileSync(promptFile, ["worker instructions", "<!-- agent-workflow:ac-block:start -->", "```json", JSON.stringify(state.acceptance.criteria), "```", "<!-- agent-workflow:ac-block:end -->", ""].join("\n"));
NODE
printf '%s\n' '{}' > "$RECREATED_WT/.review/ISSUE-307-RUN.json"
node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.worktree_path=process.argv[2]; fs.writeFileSync(f,JSON.stringify(v));' "$RECREATED_WT/.review/ISSUE-307-ROUND-STATE.json" "$RECREATED_WT"
admission_recreated="$TMP_ROOT/admission-recreated.out"
CMUX_DISPATCH_POLL_INTERVAL=1 PATH="$ADMIT_BIN:$PATH" bash "$DISPATCH" --issue 307 --worktree "$RECREATED_WT" --round-state "$RECREATED_WT/.review/ISSUE-307-ROUND-STATE.json" --manifest-revision 6 --poll-timeout 3 >"$admission_recreated" 2>&1
ec=$?
if [ "$ec" -eq 2 ] && grep -q "unbound_last_admission" "$admission_recreated"; then
  pass "worktree recreation cannot bypass missing failure evidence"
else
  fail "worktree recreation bypassed missing failure evidence (ec=$ec: $(cat "$admission_recreated"))"
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

# A pre-transaction integrated singleton is a legacy durable "consumed"
# sentinel.  Its matching ROUND-STATE can still propose the same integrated
# batch, but the selector must fail closed rather than mistake the old marker for
# an interrupted current transaction and admit a second batch.
legacy_singleton="$admit_common/agent-workflow/redispatch-admissions/issue-307-integrated-fix"
legacy_ordinal="$admit_common/agent-workflow/redispatch-admissions/issue-307-dispatch-3"
rmdir "$legacy_ordinal" 2>/dev/null || true
rmdir "$legacy_singleton" 2>/dev/null || true
mkdir -p "$legacy_singleton"
legacy_integrated="$TMP_ROOT/legacy-integrated-sentinel.out"
if CMUX_DISPATCH_POLL_INTERVAL=1 PATH="$ADMIT_BIN:$PATH" bash "$DISPATCH" --issue 307 --worktree "$ADMIT_WT" --round-state "$INTEGRATED_STATE" --manifest-revision 6 --poll-timeout 3 >"$legacy_integrated" 2>&1; then
  legacy_integrated_ec=0
else
  legacy_integrated_ec=$?
fi
if [ "$legacy_integrated_ec" -ne 0 ] && grep -q '"decision":"diagnosis_exhausted"' "$legacy_integrated" \
  && [ -d "$legacy_singleton" ] && [ ! -e "$legacy_ordinal" ]; then
  pass "legacy integrated singleton remains a consumed sentinel"
else
  fail "legacy integrated singleton was reclaimed or admitted again (ec=$legacy_integrated_ec: $(cat "$legacy_integrated"))"
fi
rmdir "$legacy_singleton" 2>/dev/null || true

# Admission markers are provisional until host-owned ROUND-STATE advances.
# Force that advance to fail and prove both the ordinal marker and integrated
# singleton are rolled back while the state bytes remain unchanged.
admit_rollback_marker="$admit_common/agent-workflow/redispatch-admissions/issue-307-dispatch-3"
admit_rollback_singleton="$admit_common/agent-workflow/redispatch-admissions/issue-307-integrated-fix"
rmdir "$admit_rollback_marker" 2>/dev/null || true
rmdir "$admit_rollback_singleton" 2>/dev/null || true
rollback_state_hash="$(shasum -a 256 "$INTEGRATED_STATE" | awk '{print $1}')"
integrated_rollback="$TMP_ROOT/integrated-rollback.out"
AGENT_WORKFLOW_ADMISSION_ADVANCE_FAIL=1 CMUX_DISPATCH_POLL_INTERVAL=1 PATH="$ADMIT_BIN:$PATH" bash "$DISPATCH" --issue 307 --worktree "$ADMIT_WT" --round-state "$INTEGRATED_STATE" --manifest-revision 6 --poll-timeout 3 >"$integrated_rollback" 2>&1
integrated_rollback_ec=$?
rollback_state_after="$(shasum -a 256 "$INTEGRATED_STATE" | awk '{print $1}')"
if [ "$integrated_rollback_ec" -eq 2 ] && [ ! -e "$admit_rollback_marker" ] && [ ! -e "$admit_rollback_singleton" ] && [ "$rollback_state_hash" = "$rollback_state_after" ]; then
  pass "failed integrated host-state advance rolls back ordinal and singleton admission"
else
  fail "failed integrated host-state advance left partial admission (ec=$integrated_rollback_ec: $(cat "$integrated_rollback"))"
fi

# Exercise each current journal boundary in a disposable child.  The seam
# exits at the same point a SIGKILL would leave durable bytes, while avoiding
# signalling this smoke runner's process group.
cp "$INTEGRATED_READY_SNAPSHOT" "$INTEGRATED_STATE"
node "$SCRIPT_DIR/../lib/admission-recover.cjs" rollback "$admit_rollback_singleton" "$admit_rollback_marker" >/dev/null 2>&1 || true
singleton_window="$TMP_ROOT/integrated-singleton-window.out"
AGENT_WORKFLOW_ADMISSION_KILL_WINDOW=1 CMUX_DISPATCH_POLL_INTERVAL=1 PATH="$ADMIT_BIN:$PATH" \
  bash "$DISPATCH" --issue 307 --worktree "$ADMIT_WT" --round-state "$INTEGRATED_STATE" --manifest-revision 6 --poll-timeout 3 >"$singleton_window" 2>&1
singleton_window_ec=$?
if [ "$singleton_window_ec" -ne 0 ] && [ -f "$admit_rollback_singleton/.admission-transaction.json" ] && [ ! -e "$admit_rollback_marker" ]; then
  pass "singleton-publication crash leaves a journal before visible ordinal"
else
  fail "singleton-publication crash was not journalled (ec=$singleton_window_ec: $(cat "$singleton_window"))"
fi
singleton_recover="$TMP_ROOT/integrated-singleton-recovery.out"
CMUX_DISPATCH_POLL_INTERVAL=1 PATH="$ADMIT_BIN:$PATH" bash "$DISPATCH" --issue 307 --worktree "$ADMIT_WT" --round-state "$INTEGRATED_STATE" --manifest-revision 6 --poll-timeout 3 >"$singleton_recover" 2>&1
singleton_recover_ec=$?
if [ "$singleton_recover_ec" -eq 0 ] && [ ! -e "$admit_common/agent-workflow/redispatch-admissions/.issue-307-lock" ]; then
  pass "singleton-only crash is reclaimed and re-admitted"
else
  fail "singleton-only crash recovery was not safe (crash=$singleton_window_ec recovery=$singleton_recover_ec: $(cat "$singleton_recover"))"
fi

cp "$INTEGRATED_READY_SNAPSHOT" "$INTEGRATED_STATE"
node "$SCRIPT_DIR/../lib/admission-recover.cjs" rollback "$admit_rollback_singleton" "$admit_rollback_marker" >/dev/null 2>&1 || true
# Simulate a process crash after ordinal publication but before host-state
# advance. The singleton transaction must let the next dispatch reclaim the
# otherwise-orphaned ordinal, then admit a fresh pair.
kill_window="$TMP_ROOT/integrated-kill-window.out"
# Run the crash-window fixture in a distinct disposable process. The dispatch
# seam exits non-zero at the interruption point; no signal can reach the
# parent harness terminal.
kill_window_child="$TMP_ROOT/kill-window-child.sh"
cat > "$kill_window_child" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
chmod +x "$kill_window_child"
AGENT_WORKFLOW_ADMISSION_KILL_WINDOW=2 CMUX_DISPATCH_POLL_INTERVAL=1 PATH="$ADMIT_BIN:$PATH" \
  "$kill_window_child" bash "$DISPATCH" --issue 307 --worktree "$ADMIT_WT" --round-state "$INTEGRATED_STATE" --manifest-revision 6 --poll-timeout 3 >"$kill_window" 2>&1 &
kill_window_pid=$!
if wait "$kill_window_pid"; then
  kill_window_ec=0
else
  kill_window_ec=$?
fi
sleep 2
if [ -f "$admit_rollback_singleton/.admission-transaction.json" ] && [ -d "$admit_rollback_marker" ]; then
  pass "ordinal-creation crash retains a recoverable singleton transaction"
else
  fail "ordinal-creation crash left no transaction for orphan recovery"
fi
recover_window="$TMP_ROOT/integrated-kill-recovery.out"
if CMUX_DISPATCH_POLL_INTERVAL=1 PATH="$ADMIT_BIN:$PATH" bash "$DISPATCH" --issue 307 --worktree "$ADMIT_WT" --round-state "$INTEGRATED_STATE" --manifest-revision 6 --poll-timeout 3 >"$recover_window" 2>&1; then
  recover_window_ec=0
else
  recover_window_ec=$?
fi
if [ "$kill_window_ec" -ne 0 ] && [ "$recover_window_ec" -eq 0 ] && grep -q "redispatch admission: mode=integrated_fix" "$recover_window" && [ ! -e "$admit_common/agent-workflow/redispatch-admissions/.issue-307-lock" ]; then
  pass "crashed ordinal and singleton are reclaimed and re-admitted as one transaction"
else
  fail "crashed ordinal recovery was not safe (crash=$kill_window_ec recovery=$recover_window_ec: $(cat "$recover_window"))"
fi

# Once the host ordinal is advanced, recovery must retain the prepared pair
# and finalize its journals instead of making dispatch-3 reusable.
cp "$INTEGRATED_READY_SNAPSHOT" "$INTEGRATED_STATE"
node "$SCRIPT_DIR/../lib/admission-recover.cjs" rollback "$admit_rollback_singleton" "$admit_rollback_marker" >/dev/null 2>&1 || true
advance_window="$TMP_ROOT/integrated-advance-window.out"
AGENT_WORKFLOW_ADMISSION_KILL_WINDOW=3 CMUX_DISPATCH_POLL_INTERVAL=1 PATH="$ADMIT_BIN:$PATH" \
  bash "$DISPATCH" --issue 307 --worktree "$ADMIT_WT" --round-state "$INTEGRATED_STATE" --manifest-revision 6 --poll-timeout 3 >"$advance_window" 2>&1
advance_window_ec=$?
node "$SCRIPT_DIR/../lib/admission-recover.cjs" recover "$admit_rollback_singleton" "$admit_rollback_marker" "$INTEGRATED_STATE" 307 >/dev/null 2>&1
advance_recover_ec=$?
if [ "$advance_window_ec" -ne 0 ] && [ "$advance_recover_ec" -eq 0 ] && [ -d "$admit_rollback_singleton" ] && [ -d "$admit_rollback_marker" ] \
  && node -e 'const fs=require("fs"); for(const f of process.argv.slice(1)){if(JSON.parse(fs.readFileSync(f)).status!=="committed")process.exit(1)}' "$admit_rollback_singleton/.admission-transaction.json" "$admit_rollback_marker/.admission-transaction.json"; then
  pass "post-advance crash commits journals without reopening consumed ordinal"
else
  fail "post-advance crash reopened or lost admission (crash=$advance_window_ec recovery=$advance_recover_ec: $(cat "$advance_window"))"
fi

# Restore the pre-admission fixture so the ordinary integrated admission case
# below remains an independent assertion.
cp "$INTEGRATED_READY_SNAPSHOT" "$INTEGRATED_STATE"
node "$SCRIPT_DIR/../lib/admission-recover.cjs" rollback "$admit_rollback_singleton" "$admit_rollback_marker" >/dev/null 2>&1 || true

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
  value.round_control.diagnosis.failure_ids=["F-1","F-2","F-3"]; value.round_control.diagnosis.integrated_fix_batch={dispatch_ordinal:value.round_control.next_dispatch_ordinal,failure_ids:["F-1","F-2","F-3"],status:"ready"}; fs.writeFileSync(file,JSON.stringify(value));
' "$SECOND_INTEGRATED_STATE"
integrated_second="$TMP_ROOT/integrated-second.out"
CMUX_DISPATCH_POLL_INTERVAL=1 PATH="$ADMIT_BIN:$PATH" bash "$DISPATCH" --issue 307 --worktree "$ADMIT_WT" --round-state "$SECOND_INTEGRATED_STATE" --manifest-revision 6 --poll-timeout 3 >"$integrated_second" 2>&1
ec=$?
if [ "$ec" -ne 0 ] && grep -q '"decision":"diagnosis_exhausted"' "$integrated_second" \
  && [ ! -e "$admit_common/agent-workflow/redispatch-admissions/issue-307-dispatch-4" ]; then
  pass "a later ordinal cannot admit a second integrated fix"
else
  fail "a later ordinal cannot admit a second integrated fix without orphaning an ordinal marker (ec=$ec: $(cat "$integrated_second"))"
fi

NORMAL_SAME_ORDINAL_STATE="$ADMIT_WT/.review/ISSUE-307-ROUND-STATE.json"
cp "$INTEGRATED_READY_SNAPSHOT" "$NORMAL_SAME_ORDINAL_STATE"
node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.round_control.failures[1].primary_origin="test_oracle"; v.round_control.failures[1].next_action.kind="oracle_fix"; v.round_control.next_dispatch_ordinal=4; delete v.round_control.diagnosis; fs.writeFileSync(f,JSON.stringify(v));' "$NORMAL_SAME_ORDINAL_STATE"
normal_same_ordinal="$TMP_ROOT/normal-same-ordinal.out"
CMUX_DISPATCH_POLL_INTERVAL=1 PATH="$ADMIT_BIN:$PATH" bash "$DISPATCH" --issue 307 --worktree "$ADMIT_WT" --round-state "$NORMAL_SAME_ORDINAL_STATE" --manifest-revision 6 --poll-timeout 3 >"$normal_same_ordinal" 2>&1
ec=$?
if [ "$ec" -ne 0 ] && grep -q '"decision":"diagnosis_exhausted"' "$normal_same_ordinal"; then
  pass "a consumed integrated admission cannot replay under a corrected mode"
else
  fail "a consumed integrated admission cannot replay under a corrected mode (ec=$ec: $(cat "$normal_same_ordinal"))"
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
. "$CMUX_PROBE_HELPER"
printf '%s\n' '{"id":"cmux-noop"}'
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
. "$CMUX_PROBE_HELPER"
printf '%s\n' '{"schema_version":"1","artifact_type":"codex_run","issue":304,"attempt":1,"started_at":"2026-07-14T09:00:00Z","updated_at":"2026-07-14T09:00:00Z","status":"running"}' > "$STALE_WT/.review/ISSUE-304-RUN.json"
printf '%s\n' '{"id":"cmux-fresh"}'
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

# A pre-existing malformed worker BLOCKER is quarantined as raw bytes and
# recorded by host-owned ROUND-STATE recovery metadata before a fresh ordinal
# is admitted; it is never promoted into canonical evidence.
RECOVERY_WT="$TMP_ROOT/blocker-recovery-wt"
mkdir -p "$RECOVERY_WT/.review"
git init -q "$RECOVERY_WT"
git -C "$RECOVERY_WT" -c user.name=Smoke -c user.email=smoke@example.test commit --allow-empty -q -m init
RECOVERY_STATE="$RECOVERY_WT/.review/ISSUE-307-ROUND-STATE.json"
make_round_state 307 "$RECOVERY_WT" 1 "$RECOVERY_STATE"
echo '{"artifact_type":"blocker","reason_code":"legacy-malformed"}' > "$RECOVERY_WT/.review/ISSUE-307-BLOCKER.json"
RECOVERY_BYTES_SHA="$(shasum -a 256 "$RECOVERY_WT/.review/ISSUE-307-BLOCKER.json" | awk '{print $1}')"
RECOVERY_STATE_SHA="$(shasum -a 256 "$RECOVERY_STATE" | awk '{print $1}')"
recovery_dry_out="$TMP_ROOT/blocker-recovery-dry.out"
bash "$DISPATCH" --issue 307 --worktree "$RECOVERY_WT" --tier standard --round-state "$RECOVERY_STATE" --manifest-revision 1 --dry-run --poll-timeout 1 >"$recovery_dry_out" 2>&1
dry_recovery_ec=$?
if [ -f "$RECOVERY_WT/.review/ISSUE-307-BLOCKER.json" ] && [ ! -e "$RECOVERY_WT/.review/ISSUE-307-BLOCKER-QUARANTINED-$RECOVERY_BYTES_SHA.json" ] && [ "$(shasum -a 256 "$RECOVERY_STATE" | awk '{print $1}')" = "$RECOVERY_STATE_SHA" ]; then
  pass "dry-run malformed BLOCKER recovery leaves artifacts and ROUND-STATE unchanged"
else
  fail "dry-run malformed BLOCKER recovery mutated state or artifacts (ec=$dry_recovery_ec)"
fi
RECOVERY_BIN="$TMP_ROOT/bin-recovery-cmux"
mkdir -p "$RECOVERY_BIN"
cat > "$RECOVERY_BIN/cmux" <<EOF
#!/usr/bin/env bash
. "$CMUX_PROBE_HELPER"
echo '{"schema_version":"1","artifact_type":"codex_run","issue":307,"attempt":1,"started_at":"2026-07-14T09:00:00Z","updated_at":"2026-07-14T09:00:00Z","status":"running"}' > "$RECOVERY_WT/.review/ISSUE-307-RUN.json"
echo '{"id":"cmux-blocker-recovery"}'
exit 0
EOF
chmod +x "$RECOVERY_BIN/cmux"
recovery_out="$TMP_ROOT/blocker-recovery.out"
CMUX_DISPATCH_POLL_INTERVAL=1 PATH="$RECOVERY_BIN:$PATH" bash "$DISPATCH" --issue 307 --worktree "$RECOVERY_WT" --tier standard --round-state "$RECOVERY_STATE" --manifest-revision 1 --poll-timeout 3 >"$recovery_out" 2>&1
ec=$?
recovery_raw="$(find "$RECOVERY_WT/.review" -name 'ISSUE-307-BLOCKER-QUARANTINED-*.json' -type f | head -1)"
if [ "$ec" -eq 0 ] && [ ! -f "$RECOVERY_WT/.review/ISSUE-307-BLOCKER.json" ] && [ -n "$recovery_raw" ] && [ "$(shasum -a 256 "$recovery_raw" | awk '{print $1}')" = "$RECOVERY_BYTES_SHA" ] && node - "$RECOVERY_STATE" "$recovery_raw" <<'NODE'
const fs=require("fs"), crypto=require("crypto"), [stateFile,rawFile]=process.argv.slice(2), state=JSON.parse(fs.readFileSync(stateFile)), raw=fs.readFileSync(rawFile), recovery=state.round_control && state.round_control.blocker_recovery;
process.exit(recovery && recovery.kind === "malformed_preexisting_blocker_quarantined" && recovery.raw_sha256 === crypto.createHash("sha256").update(raw).digest("hex") && state.round_control.next_dispatch_ordinal === 2 ? 0 : 1);
NODE
then
  pass "malformed pre-existing BLOCKER is quarantined with host-owned recovery evidence"
else
  fail "malformed pre-existing BLOCKER recovery is explicit and ordinal-safe (ec=$ec: $(cat "$recovery_out"))"
fi

# Recovery metadata is durable before canonical removal: an injected crash at
# that boundary must retain malformed bytes, quarantine bytes, and state.
CRASH_WT="$TMP_ROOT/blocker-recovery-crash-wt"
mkdir -p "$CRASH_WT/.review"
git init -q "$CRASH_WT"
git -C "$CRASH_WT" -c user.name=Smoke -c user.email=smoke@example.test commit --allow-empty -q -m init
CRASH_STATE="$CRASH_WT/.review/ISSUE-308-ROUND-STATE.json"
make_round_state 308 "$CRASH_WT" 1 "$CRASH_STATE"
printf '%s\n' '{"artifact_type":"blocker","reason_code":"legacy-malformed"}' > "$CRASH_WT/.review/ISSUE-308-BLOCKER.json"
crash_raw_sha="$(shasum -a 256 "$CRASH_WT/.review/ISSUE-308-BLOCKER.json" | awk '{print $1}')"
AGENT_WORKFLOW_BLOCKER_RECOVERY_CRASH_AFTER_STATE=1 node "$SCRIPT_DIR/../lib/blocker-recovery.cjs" "$CRASH_WT/.review/ISSUE-308-BLOCKER.json" "$CRASH_STATE" 308 >/dev/null 2>&1
crash_ec=$?
crash_raw="$CRASH_WT/.review/ISSUE-308-BLOCKER-QUARANTINED-$crash_raw_sha.json"
if [ "$crash_ec" -eq 99 ] && [ -f "$CRASH_WT/.review/ISSUE-308-BLOCKER.json" ] && [ -f "$crash_raw" ] && node - "$CRASH_STATE" "$crash_raw" <<'NODE'
const fs=require("fs"), crypto=require("crypto"), [stateFile,rawFile]=process.argv.slice(2);
const state=JSON.parse(fs.readFileSync(stateFile)), raw=fs.readFileSync(rawFile), recovery=state.round_control && state.round_control.blocker_recovery;
process.exit(recovery && recovery.status === "ready" && recovery.raw_sha256 === crypto.createHash("sha256").update(raw).digest("hex") ? 0 : 1);
NODE
then
  pass "BLOCKER recovery crash boundary leaves canonical bytes and durable metadata"
else
  fail "BLOCKER recovery crash boundary is not durable (ec=$crash_ec)"
fi

# A fresh malformed BLOCKER must not be masked by a simultaneously fresh RUN.
# The poll validates BLOCKER first and rejects it as non-liveness evidence.
ORDER_BIN="$TMP_ROOT/bin-blocker-run-order"
mkdir -p "$ORDER_BIN"
cat > "$ORDER_BIN/cmux" <<EOF
#!/usr/bin/env bash
. "$CMUX_PROBE_HELPER"
printf '%s\n' '{"artifact_type":"blocker","issue":310,"reason_code":"tier_escalation_required"}' > "$STALE_WT/.review/ISSUE-310-BLOCKER.json"
printf '%s\n' '{"schema_version":"1","artifact_type":"codex_run","issue":310,"attempt":1,"started_at":"2026-07-14T09:00:00Z","updated_at":"2026-07-14T09:00:00Z","status":"running"}' > "$STALE_WT/.review/ISSUE-310-RUN.json"
printf '%s\n' '{"id":"cmux-blocker-run-order"}'
exit 0
EOF
chmod +x "$ORDER_BIN/cmux"
printf '%s\n' "prompt body" > "$STALE_WT/.review/ISSUE-310-PROMPT.txt"
order_out="$TMP_ROOT/fresh-blocker-run-order.out"
CMUX_DISPATCH_POLL_INTERVAL=1 PATH="$ORDER_BIN:$PATH" bash "$DISPATCH" --issue 310 --worktree "$STALE_WT" --read-only --poll-timeout 3 >"$order_out" 2>&1
ec=$?
if [ "$ec" -ne 0 ] && grep -q "fresh BLOCKER.json is not schema-valid" "$order_out" && ! grep -q "fresh RUN.json present" "$order_out"; then
  pass "fresh malformed BLOCKER is not masked by fresh RUN.json"
else
  fail "fresh malformed BLOCKER is not masked by fresh RUN.json (ec=$ec: $(cat "$order_out"))"
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
. "$CMUX_PROBE_HELPER"
printf '%s\n' '{"schema_version":"1","artifact_type":"codex_run","issue":306,"attempt":1,"started_at":"2026-07-14T09:00:00Z","updated_at":"2026-07-14T09:00:00Z","status":"running"}' > "$STALE_WT/.review/ISSUE-306-RUN.json"
printf '%s\n' '{"id":"cmux-fresh306"}'
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
# The prior successful write leaves an explicit pre-launch marker when a
# later write is attempted before a new RUN.json exists.  Create that marker
# directly here: without it this would be a fresh initial write, which now
# correctly requires an explicit tier rather than silently choosing one.
mkdir -p "$STALE_WT/.review/.write-dispatch-issue-306-started"
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
. "$CMUX_PROBE_HELPER"
printf '%s\n' '{"schema_version":"1","artifact_type":"codex_run","issue":308,"attempt":1,"started_at":"2026-07-20T11:00:00Z","updated_at":"2026-07-20T11:00:00Z","status":"running"}' > "$RACE_WT/.review/ISSUE-308-RUN.json"
printf '%s\n' '{"id":"cmux-race"}'
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
CODEX_WATCHDOG_POLL_INTERVAL=1 CODEX_WATCHDOG_PROBE_GAP=0 PATH="/usr/bin:/bin" bash "$WATCHDOG" --issue 303 --prompt-file ".review/ISSUE-303-PROMPT.txt" --cwd "$WT_REL" --max-retries 0 >"$watchdog_out" 2>&1
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
