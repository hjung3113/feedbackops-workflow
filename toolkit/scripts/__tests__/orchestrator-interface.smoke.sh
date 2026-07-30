#!/usr/bin/env bash
# Offline contract for the transport-neutral orchestrator interface.
# bash-3.2-compatible. AC-ORCH-1 AC-ORCH-2 AC-ORCH-3 AC-ORCH-4
# AC-ORCH-5 AC-ORCH-6 AC-ORCH-7 AC-ORCH-8
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VALIDATOR="$ROOT/scripts/lib/json-schema-subset.cjs"
SCHEMA="$ROOT/schemas/transport_receipt.schema.json"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
PRODUCT_HOME="$TMP_ROOT/product-home"
mkdir -p "$PRODUCT_HOME"
cp -R "$ROOT/scripts" "$PRODUCT_HOME/scripts"
cp -R "$ROOT/schemas" "$PRODUCT_HOME/schemas"
cp "$ROOT/model-alloc.json" "$PRODUCT_HOME/model-alloc.json"
CLI="$PRODUCT_HOME/scripts/agent-workflow.sh"
FAILURES=0
pass() { echo "ok   - $1"; }
fail() { echo "NOT OK - $1"; FAILURES=$((FAILURES + 1)); }

make_worktree() {
  path="$1"
  issue="$2"
mkdir -p "$path/.review"
  git init -q "$path"
  git -C "$path" -c user.name=smoke -c user.email=smoke@example.test commit --allow-empty -qm init
  printf '%s\n' 'worker prompt' > "$path/.review/ISSUE-${issue}-PROMPT.md"
  "$ROOT/scripts/output-contract.sh" render --role implementation >> "$path/.review/ISSUE-${issue}-PROMPT.md"
}

BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"
# The runtime adapter pins the executable path reported by `command -v`.
# Preserve that spelling here: macOS maps /var to /private/var under pwd -P.
RESOLVED_BIN="$BIN"
cat > "$BIN/cmux" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo 'cmux 0.64.18'; exit 0; fi
if [ "${1:-}" = "workspace" ] && [ "${2:-}" = "create" ] && [ "${3:-}" = "--help" ]; then echo 'create [flags]'; exit 0; fi
if [ "${1:-}" = "new-workspace" ] && [ "${2:-}" = "--help" ]; then echo '--cwd PATH --command TEXT'; exit 0; fi
if [ "${1:-}" = "workspace" ] && [ "${2:-}" = "list" ] && [ "${3:-}" = "--json" ]; then
  case "${CMUX_LIST_MODE:-live}" in
    live) printf '%s\n' '{"workspaces":[{"ref":"workspace:11","name":"codex-502"}]}' ;;
    duplicate_name) printf '%s\n' '{"workspaces":[{"ref":"workspace:11","name":"same-name"},{"ref":"workspace:12","name":"same-name"}]}' ;;
    removed) printf '%s\n' '{"workspaces":[{"ref":"workspace:12","name":"codex-502"}]}' ;;
    invalid) printf '%s\n' '{"workspaces":' ;;
    fail) exit 2 ;;
  esac
  exit 0
fi
printf 'cmux' >> "$TRANSPORT_USED"
printf '%s\n' "$@" > "$CMUX_ARGV"
cwd=""; name=""
while [ $# -gt 0 ]; do
  case "$1" in
    --cwd) cwd="$2"; shift 2 ;;
    --name) name="$2"; shift 2 ;;
    *) shift ;;
  esac
done
issue="${CMUX_CREATE_ISSUE_OVERRIDE:-${name#codex-}}"
printf '%s\n' "{\"schema_version\":\"1\",\"artifact_type\":\"codex_run\",\"issue\":$issue,\"attempt\":1,\"started_at\":\"2026-07-21T01:00:00Z\",\"updated_at\":\"2026-07-21T01:00:00Z\",\"status\":\"running\"}" > "$cwd/.review/ISSUE-${issue}-RUN.json"
case "${CMUX_CREATE_SHAPE:-plain}" in
  plain) printf 'OK workspace:11\n' ;;
  id) node -e 'process.stdout.write(JSON.stringify({workspace:{id:`cmux-${process.argv[1]}`,name:process.argv[2]}})+"\n")' "$issue" "$name" ;;
  ref) node -e 'process.stdout.write(JSON.stringify({result:{ref:`cmux-${process.argv[1]}`}})+"\n")' "$issue" ;;
  name_only) node -e 'process.stdout.write(JSON.stringify({workspace:{name:process.argv[1]}})+"\n")' "$name" ;;
  ambiguous) printf '%s\n' '{"id":"cmux-one","ref":"cmux-two"}' ;;
  missing) printf '\n' ;;
  invalid) printf 'created workspace:cmux-%s\n' "$issue" ;;
esac
EOF
cat > "$BIN/orca" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "terminal" ] && [ "${2:-}" = "create" ] && [ "${3:-}" = "--help" ]; then
  printf '%s\n' 'Usage: orca terminal create --worktree PATH --title NAME --command TEXT --json'
  exit 0
fi
if [ "${1:-}" = "terminal" ] && [ "${2:-}" = "list" ] && [ "${3:-}" = "--help" ]; then
  printf '%s\n' 'Usage: orca terminal list --worktree PATH --json'
  exit 0
fi
if [ "${1:-}" = "--version" ]; then echo 'orca'; exit 0; fi
if [ "${1:-}" = "status" ] && [ "${2:-}" = "--json" ]; then
  case "${ORCA_STATUS_MODE:-real}" in
    real) printf '%s\n' '{"result":{"runtime":{"appVersion":"1.4.161"}}}' ;;
    missing) printf '%s\n' '{"result":{"runtime":{}}}' ;;
    non_string) printf '%s\n' '{"result":{"runtime":{"appVersion":104161}}}' ;;
    literal) printf '%s\n' '{"result":{"runtime":{"appVersion":"orca"}}}' ;;
    multiline) printf '%s\n' '{"result":{"runtime":{"appVersion":"1.4.161\\nUsage: orca"}}}' ;;
    usage) printf '%s\n' '{"result":{"runtime":{"appVersion":"Usage: orca status --json"}}}' ;;
    invalid) printf '%s\n' 'not JSON' ;;
    fail) exit 2 ;;
  esac
  exit 0
fi
if [ "${1:-}" = "terminal" ] && [ "${2:-}" = "list" ]; then
  case "${ORCA_LIST_MODE:-live}" in
    live) printf '%s\n' '{"result":{"terminals":[{"handle":"term-503"}]}}' ;;
    missing) printf '%s\n' '{"result":{"terminals":[]}}' ;;
    unknown) printf '%s\n' '{"result":{"terminals":[{"id":"request-503"}]}}' ;;
    invalid) printf '%s\n' '{"result":{}}' ;;
    fail) exit 2 ;;
  esac
  exit 0
fi
printf 'orca' >> "$TRANSPORT_USED"
printf '%s\n' "$@" > "$ORCA_ARGV"
worktree=""; title=""
while [ $# -gt 0 ]; do
  case "$1" in
    --worktree) worktree="${2#path:}"; shift 2 ;;
    --title) title="$2"; shift 2 ;;
    *) shift ;;
  esac
done
issue="${title#codex-}"
printf '%s\n' "{\"schema_version\":\"1\",\"artifact_type\":\"codex_run\",\"issue\":$issue,\"attempt\":1,\"started_at\":\"2026-07-21T01:00:01Z\",\"updated_at\":\"2026-07-21T01:00:01Z\",\"status\":\"running\"}" > "$worktree/.review/ISSUE-${issue}-RUN.json"
case "${ORCA_CREATE_MODE:-actual}" in
  actual) printf '%s\n' "{\"id\":\"request-$issue\",\"result\":{\"terminal\":{\"handle\":\"term-$issue\"}}}" ;;
  missing) printf '%s\n' "{\"id\":\"request-$issue\",\"result\":{\"terminal\":{}}}" ;;
  ambiguous) printf '%s\n' "{\"id\":\"request-$issue\",\"result\":{\"terminal\":[{\"handle\":\"term-$issue\"},{\"handle\":\"term-other\"}]}}" ;;
esac
EOF
chmod +x "$BIN/cmux" "$BIN/orca"
cat > "$BIN/codex" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo 'codex-cli 0.test'; exit 0; fi
if [ "${1:-}" = "--help" ]; then echo 'Commands: exec'; exit 0; fi
if [ "${1:-}" = "exec" ] && [ "${2:-}" = "--help" ]; then echo 'exec --sandbox --cd --model --config --output-last-message'; exit 0; fi
exit 0
EOF
chmod +x "$BIN/codex"
export AGENT_WORKFLOW_CODEX_BIN="$BIN/codex"

WT="$TMP_ROOT/choice"
make_worktree "$WT" 501
printf '%s\n' '{"orchestrator":"orca"}' > "$PRODUCT_HOME/workflow-config.json"
choice_out="$TMP_ROOT/choice.out"
AGENT_WORKFLOW_ORCHESTRATOR=orca bash "$CLI" dispatch --orchestrator cmux --issue 501 --worktree "$WT" --read-only --dry-run >"$choice_out" 2>&1
if grep -q 'orchestrator=cmux source=cli' "$choice_out"; then pass "CLI selection outranks environment and config"; else fail "CLI selection precedence"; fi
AGENT_WORKFLOW_ORCHESTRATOR=cmux bash "$CLI" dispatch --issue 501 --worktree "$WT" --read-only --dry-run >"$choice_out" 2>&1
if grep -q 'orchestrator=cmux source=environment' "$choice_out"; then pass "environment selection outranks config"; else fail "environment selection precedence"; fi
env -u AGENT_WORKFLOW_ORCHESTRATOR bash "$CLI" dispatch --issue 501 --worktree "$WT" --read-only --dry-run >"$choice_out" 2>&1
if grep -q 'orchestrator=orca source=config' "$choice_out"; then pass "product-home config supplies explicit selection"; else fail "config selection"; fi

rm "$PRODUCT_HOME/workflow-config.json"
missing_out="$TMP_ROOT/missing.out"
env -u AGENT_WORKFLOW_ORCHESTRATOR bash "$CLI" dispatch --issue 501 --worktree "$WT" --read-only --dry-run >"$missing_out" 2>&1
ec=$?
if [ "$ec" -eq 2 ] && grep -q 'orchestrator_not_configured' "$missing_out"; then pass "missing selection fails closed with setup text"; else fail "missing selection refusal"; fi
unknown_out="$TMP_ROOT/unknown.out"
bash "$CLI" dispatch --orchestrator auto --issue 501 --worktree "$WT" --read-only --dry-run >"$unknown_out" 2>&1
ec=$?
if [ "$ec" -eq 2 ] && grep -q 'unknown_orchestrator' "$unknown_out"; then pass "unknown selection is rejected"; else fail "unknown selection refusal"; fi

# An unavailable selected adapter must fail before the initial-write marker and
# must never call the other adapter.
BAD_BIN="$TMP_ROOT/bad-bin"
mkdir -p "$BAD_BIN"
cat > "$BAD_BIN/orca" <<'EOF'
#!/usr/bin/env bash
echo 'orca terminal create without required flags'
EOF
cat > "$BAD_BIN/cmux" <<'EOF'
#!/usr/bin/env bash
echo called > "$FALLBACK_LOG"
EOF
chmod +x "$BAD_BIN/orca" "$BAD_BIN/cmux"
unavailable_out="$TMP_ROOT/unavailable.out"
FALLBACK_LOG="$TMP_ROOT/fallback.log"
FALLBACK_LOG="$FALLBACK_LOG" PATH="$BAD_BIN:$PATH" bash "$CLI" dispatch --orchestrator orca --issue 501 --worktree "$WT" --tier trivial >"$unavailable_out" 2>&1
ec=$?
if [ "$ec" -eq 2 ] && grep -q 'required_capability_missing' "$unavailable_out" \
  && [ ! -e "$FALLBACK_LOG" ] && [ ! -d "$WT/.review/.write-dispatch-issue-501-started" ]; then
  pass "capability refusal precedes admission and never falls back"
else fail "pre-admission capability/no-fallback contract ($(cat "$unavailable_out"))"; fi

# A cmux binary that exists but exits 2 for side-effect-free version/help
# probes is unavailable before admission; no runner/marker may be consumed.
CMUX_BAD_WT="$TMP_ROOT/cmux-bad-wt"
make_worktree "$CMUX_BAD_WT" 504
CMUX_BAD_BIN="$TMP_ROOT/cmux-bad-bin"
mkdir -p "$CMUX_BAD_BIN"
cat > "$CMUX_BAD_BIN/cmux" <<'EOF'
#!/usr/bin/env bash
exit 2
EOF
chmod +x "$CMUX_BAD_BIN/cmux"
PATH="$CMUX_BAD_BIN:$PATH" bash "$CLI" dispatch --orchestrator cmux --issue 504 --worktree "$CMUX_BAD_WT" --tier trivial >"$TMP_ROOT/cmux-bad.out" 2>&1
ec=$?
if [ "$ec" -eq 2 ] && grep -q 'required_capability_missing' "$TMP_ROOT/cmux-bad.out" \
  && [ ! -d "$CMUX_BAD_WT/.review/.write-dispatch-issue-504-started" ] \
  && ! find "$CMUX_BAD_WT/.review" -type d -name 'ISSUE-504-launch.*' | grep -q .; then
  pass "cmux help/version capability refusal preserves admission"
else fail "cmux pre-admission help/version refusal (ec=$ec: $(cat "$TMP_ROOT/cmux-bad.out"))"; fi

# Orca launch uses --title, so missing-title help must fail before admission.
ORCA_BAD_WT="$TMP_ROOT/orca-bad-wt"
make_worktree "$ORCA_BAD_WT" 505
ORCA_BAD_BIN="$TMP_ROOT/orca-bad-bin"
mkdir -p "$ORCA_BAD_BIN"
cat > "$ORCA_BAD_BIN/orca" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "terminal" ] && [ "${2:-}" = "create" ] && [ "${3:-}" = "--help" ]; then
  echo 'terminal create --worktree PATH --command TEXT --json'
  exit 0
fi
if [ "${1:-}" = "terminal" ] && [ "${2:-}" = "list" ] && [ "${3:-}" = "--help" ]; then
  echo 'terminal list --worktree PATH --json'
  exit 0
fi
if [ "${1:-}" = "--version" ]; then echo 'orca 1.0'; exit 0; fi
exit 9
EOF
chmod +x "$ORCA_BAD_BIN/orca"
PATH="$ORCA_BAD_BIN:$PATH" bash "$CLI" dispatch --orchestrator orca --issue 505 --worktree "$ORCA_BAD_WT" --tier trivial >"$TMP_ROOT/orca-bad.out" 2>&1
ec=$?
if [ "$ec" -eq 2 ] && grep -q 'required_capability_missing' "$TMP_ROOT/orca-bad.out" \
  && [ ! -d "$ORCA_BAD_WT/.review/.write-dispatch-issue-505-started" ]; then
  pass "Orca missing-title capability is rejected before admission"
else fail "Orca title capability refusal (ec=$ec: $(cat "$TMP_ROOT/orca-bad.out"))"; fi

# Both adapters cross the same typed boundary and therefore inherit the same
# initial admission marker, runner identity, receipt, and freshness polling.
CMUX_WT="$TMP_ROOT/cmux-wt"
ORCA_WT="$TMP_ROOT/orca-wt"
make_worktree "$CMUX_WT" 502
make_worktree "$ORCA_WT" 503
TRANSPORT_USED="$TMP_ROOT/cmux-used" CMUX_ARGV="$TMP_ROOT/cmux-argv" ORCA_ARGV="$TMP_ROOT/unused-orca" \
AGENT_WORKFLOW_CODEX_BIN="$BIN/codex" PATH="$BIN:$PATH" CMUX_DISPATCH_POLL_INTERVAL=1 bash "$CLI" dispatch --orchestrator cmux --issue 502 --worktree "$CMUX_WT" --tier trivial --poll-timeout 3 >"$TMP_ROOT/cmux.out" 2>&1
cmux_ec=$?
TRANSPORT_USED="$TMP_ROOT/orca-used" CMUX_ARGV="$TMP_ROOT/unused-cmux" ORCA_ARGV="$TMP_ROOT/orca-argv" \
AGENT_WORKFLOW_CODEX_BIN="$BIN/codex" PATH="$BIN:$PATH" CMUX_DISPATCH_POLL_INTERVAL=1 bash "$CLI" dispatch --orchestrator orca --issue 503 --worktree "$ORCA_WT" --tier trivial --poll-timeout 3 >"$TMP_ROOT/orca.out" 2>&1
orca_ec=$?
if [ "$cmux_ec" -eq 0 ] && [ "$orca_ec" -eq 0 ] \
  && [ -d "$CMUX_WT/.review/.write-dispatch-issue-502-started" ] \
  && [ -d "$ORCA_WT/.review/.write-dispatch-issue-503-started" ] \
  && grep -Fx -- "$CMUX_WT" "$TMP_ROOT/cmux-argv" >/dev/null \
  && grep -Fx -- "path:$ORCA_WT" "$TMP_ROOT/orca-argv" >/dev/null \
  && grep -E '^bash \.review/ISSUE-502-launch\..*/launch\.sh$' "$TMP_ROOT/cmux-argv" >/dev/null \
  && grep -E '^bash \.review/ISSUE-503-launch\..*/launch\.sh$' "$TMP_ROOT/orca-argv" >/dev/null; then
  pass "cmux and Orca share exact cwd, runner, admission, and freshness behavior"
else fail "adapter parity (cmux=$cmux_ec orca=$orca_ec)"; fi

orca_version="$(node -e 'process.stdout.write(require(process.argv[1]).adapter_version)' "$ORCA_WT/.review/ISSUE-503-TRANSPORT.json")"
if [ "$orca_version" = "1.4.161" ] && [ "$orca_version" != "orca" ]; then
  pass "Orca receipt records runtime appVersion instead of executable-name output"
else fail "Orca receipt adapter version ($orca_version)"; fi

for bad_status_mode in missing non_string literal multiline usage invalid fail; do
  bad_capabilities="$(ORCA_STATUS_MODE="$bad_status_mode" PATH="$BIN:$PATH" bash "$ROOT/scripts/adapters/orca.sh" capabilities --worktree "$ORCA_WT")"
  if node -e 'const v=JSON.parse(process.argv[1]); if(!v.available || v.version!=="unknown")process.exit(1)' "$bad_capabilities"; then
    pass "Orca $bad_status_mode status version fails closed to unknown"
  else fail "Orca $bad_status_mode status version ($bad_capabilities)"; fi
done

cmux_runner="$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).runner.path)' "$CMUX_WT/.review/ISSUE-502-TRANSPORT.json")"
orca_runner="$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).runner.path)' "$ORCA_WT/.review/ISSUE-503-TRANSPORT.json")"
if grep -F -q "AGENT_WORKFLOW_RUNTIME_BIN=$RESOLVED_BIN/codex" "$cmux_runner" \
  && grep -F -q "AGENT_WORKFLOW_RUNTIME_BIN=$RESOLVED_BIN/codex" "$orca_runner"; then
  pass "both transports pin the validated runtime executable in the common runner"
else fail "common runner runtime executable pinning (cmux=$(sed -n '2p' "$cmux_runner"))"; fi

PIN_WT="$TMP_ROOT/pin-wt"
make_worktree "$PIN_WT" 506
AGENT_WORKFLOW_CODEX_BIN=relative/codex PATH="$BIN:$PATH" bash "$CLI" dispatch --orchestrator orca --issue 506 --worktree "$PIN_WT" --tier trivial >"$TMP_ROOT/pin.out" 2>&1
pin_ec=$?
if [ "$pin_ec" -eq 2 ] && grep -q 'required_runtime_capability_missing' "$TMP_ROOT/pin.out" \
  && [ ! -d "$PIN_WT/.review/.write-dispatch-issue-506-started" ]; then
  pass "invalid Codex executable pin fails before admission"
else fail "Codex executable pin pre-admission validation"; fi

for pair in "$CMUX_WT:502" "$ORCA_WT:503"; do
  path="${pair%:*}"; issue="${pair#*:}"
  node - "$VALIDATOR" "$SCHEMA" "$path/.review/ISSUE-${issue}-TRANSPORT.json" <<'NODE'
const { validate } = require(process.argv[2]);
const fs = require("fs");
const schema = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
const value = JSON.parse(fs.readFileSync(process.argv[4], "utf8"));
if (validate(schema, value).length || value.authoritative !== false) process.exit(1);
NODE
  [ "$?" -eq 0 ] || fail "schema-valid non-authoritative receipt for issue $issue"
done
if [ "$FAILURES" -eq 0 ]; then pass "dispatch publishes schema-valid non-authoritative receipts"; fi

inspect_out="$TMP_ROOT/inspect.out"
PATH="$BIN:$PATH" bash "$CLI" inspect --receipt "$CMUX_WT/.review/ISSUE-502-TRANSPORT.json" > "$inspect_out"
if grep -q '"adapter":"cmux"' "$inspect_out" && grep -q '"lifecycle":"live"' "$inspect_out"; then
  pass "inspect queries the cmux external workspace handle read-only"
else fail "cmux external handle inspection"; fi
cmux_handle="$(node -e 'process.stdout.write(require(process.argv[1]).external_handle)' "$CMUX_WT/.review/ISSUE-502-TRANSPORT.json")"
if [ "$cmux_handle" = "workspace:11" ]; then
  pass "cmux receipt normalizes the plain-text create workspace ref rather than the requested name"
else fail "cmux receipt unique create identity ($cmux_handle)"; fi
CMUX_LIST_MODE=duplicate_name PATH="$BIN:$PATH" bash "$CLI" inspect --receipt "$CMUX_WT/.review/ISSUE-502-TRANSPORT.json" > "$inspect_out"
if grep -q '"lifecycle":"live"' "$inspect_out"; then
  pass "duplicate cmux workspace names do not replace exact id inspection"
else fail "cmux duplicate-name exact identity"; fi
CMUX_LIST_MODE=removed PATH="$BIN:$PATH" bash "$CLI" inspect --receipt "$CMUX_WT/.review/ISSUE-502-TRANSPORT.json" > "$inspect_out"
if grep -q '"lifecycle":"stale"' "$inspect_out"; then
  pass "removed created cmux workspace is stale even when its name remains"
else fail "cmux removed workspace stale identity"; fi

weird_name="$(printf 'same "name"\nnext')"
weird_launch="$(TRANSPORT_USED="$TMP_ROOT/weird-used" CMUX_ARGV="$TMP_ROOT/weird-argv" CMUX_CREATE_SHAPE=id CMUX_CREATE_ISSUE_OVERRIDE=502 PATH="$BIN:$PATH" bash "$ROOT/scripts/adapters/cmux.sh" launch --name "$weird_name" --worktree "$CMUX_WT" --runner-relative .review/ISSUE-502-launch.fixture/launch.sh)"
if node -e 'const v=JSON.parse(process.argv[1]); if(v.external_handle!=="cmux-502")process.exit(1)' "$weird_launch"; then
  pass "cmux launch JSON-encodes quote and newline names without using them as identity"
else fail "cmux unusual name JSON safety"; fi
ref_launch="$(TRANSPORT_USED="$TMP_ROOT/ref-used" CMUX_ARGV="$TMP_ROOT/ref-argv" CMUX_CREATE_SHAPE=ref CMUX_CREATE_ISSUE_OVERRIDE=502 PATH="$BIN:$PATH" bash "$ROOT/scripts/adapters/cmux.sh" launch --name codex-502 --worktree "$CMUX_WT" --runner-relative .review/ISSUE-502-launch.fixture/launch.sh)"
if node -e 'const v=JSON.parse(process.argv[1]); if(v.external_handle!=="cmux-502")process.exit(1)' "$ref_launch"; then
  pass "cmux create ref response normalizes to the same unique handle"
else fail "cmux ref response normalization"; fi

id_launch="$(TRANSPORT_USED="$TMP_ROOT/id-used" CMUX_ARGV="$TMP_ROOT/id-argv" CMUX_CREATE_SHAPE=id CMUX_CREATE_ISSUE_OVERRIDE=502 PATH="$BIN:$PATH" bash "$ROOT/scripts/adapters/cmux.sh" launch --name codex-502 --worktree "$CMUX_WT" --runner-relative .review/ISSUE-502-launch.fixture/launch.sh)"
if node -e 'const v=JSON.parse(process.argv[1]); if(v.external_handle!=="cmux-502")process.exit(1)' "$id_launch"; then
  pass "cmux create id response remains compatible"
else fail "cmux id response normalization"; fi

for invalid_create_shape in name_only ambiguous missing invalid; do
  if TRANSPORT_USED="$TMP_ROOT/${invalid_create_shape}-used" CMUX_ARGV="$TMP_ROOT/${invalid_create_shape}-argv" CMUX_CREATE_SHAPE="$invalid_create_shape" CMUX_CREATE_ISSUE_OVERRIDE=502 PATH="$BIN:$PATH" \
    bash "$ROOT/scripts/adapters/cmux.sh" launch --name codex-502 --worktree "$CMUX_WT" --runner-relative .review/ISSUE-502-launch.fixture/launch.sh > "$TMP_ROOT/${invalid_create_shape}-create.out" 2>&1; then
    fail "cmux $invalid_create_shape create result must remain unprovable"
  else
    pass "cmux $invalid_create_shape create result remains unprovable"
  fi
done

CMUX_UNPROVABLE_WT="$TMP_ROOT/cmux-unprovable"
make_worktree "$CMUX_UNPROVABLE_WT" 507
CMUX_CREATE_SHAPE=name_only AGENT_WORKFLOW_CODEX_BIN="$BIN/codex" PATH="$BIN:$PATH" CMUX_DISPATCH_POLL_INTERVAL=1 \
bash "$CLI" dispatch --orchestrator cmux --issue 507 --worktree "$CMUX_UNPROVABLE_WT" --tier trivial --poll-timeout 1 > "$TMP_ROOT/cmux-unprovable.out" 2>&1
unprovable_ec=$?
if [ "$unprovable_ec" -eq 2 ] && grep -q 'did not return one provable workspace id/ref' "$TMP_ROOT/cmux-unprovable.out" \
  && [ ! -e "$CMUX_UNPROVABLE_WT/.review/ISSUE-507-TRANSPORT.json" ]; then
  pass "cmux launch without a provable id/ref fails before receipt publication"
else fail "cmux unprovable create identity (ec=$unprovable_ec)"; fi
PATH="$BIN:$PATH" bash "$CLI" inspect --receipt "$ORCA_WT/.review/ISSUE-503-TRANSPORT.json" > "$inspect_out"
if grep -q '"lifecycle":"live"' "$inspect_out" && grep -q '"authoritative":false' "$inspect_out" && grep -q 'canonical REVIEW and VERIFY' "$inspect_out"; then
  pass "inspect refuses to equate transport lifecycle with completion"
else fail "inspect authority boundary"; fi
orca_handle="$(node -e 'process.stdout.write(require(process.argv[1]).external_handle)' "$ORCA_WT/.review/ISSUE-503-TRANSPORT.json")"
if [ "$orca_handle" = "term-503" ]; then
  pass "Orca receipt uses nested terminal handle rather than create request id"
else fail "Orca nested terminal handle normalization ($orca_handle)"; fi
for invalid_create_shape in missing ambiguous; do
  if TRANSPORT_USED="$TMP_ROOT/fixture-used" ORCA_ARGV="$TMP_ROOT/fixture-argv" ORCA_CREATE_MODE="$invalid_create_shape" PATH="$BIN:$PATH" \
    bash "$ROOT/scripts/adapters/orca.sh" launch --name codex-503 --worktree "$ORCA_WT" --runner-relative .review/ISSUE-503-launch.fixture/launch.sh > "$TMP_ROOT/orca-${invalid_create_shape}.out" 2>&1; then
    fail "Orca $invalid_create_shape create result must remain unprovable"
  else
    pass "Orca $invalid_create_shape create result remains unprovable"
  fi
done
ORCA_UNPROVABLE_WT="$TMP_ROOT/orca-unprovable"
make_worktree "$ORCA_UNPROVABLE_WT" 508
ORCA_CREATE_MODE=missing AGENT_WORKFLOW_CODEX_BIN="$BIN/codex" PATH="$BIN:$PATH" CMUX_DISPATCH_POLL_INTERVAL=1 \
bash "$CLI" dispatch --orchestrator orca --issue 508 --worktree "$ORCA_UNPROVABLE_WT" --tier trivial --poll-timeout 1 > "$TMP_ROOT/orca-unprovable.out" 2>&1
orca_unprovable_ec=$?
if [ "$orca_unprovable_ec" -eq 2 ] && [ ! -e "$ORCA_UNPROVABLE_WT/.review/ISSUE-508-TRANSPORT.json" ]; then
  pass "Orca launch without a provable terminal handle fails before receipt publication"
else fail "Orca unprovable terminal handle (ec=$orca_unprovable_ec)"; fi
ORCA_LIST_MODE=missing PATH="$BIN:$PATH" bash "$CLI" inspect --receipt "$ORCA_WT/.review/ISSUE-503-TRANSPORT.json" > "$inspect_out"
if grep -q '"lifecycle":"stale"' "$inspect_out" && grep -q 'external terminal handle is absent' "$inspect_out"; then
  pass "inspect normalizes a missing external handle as stale"
else fail "missing external handle normalization"; fi
ORCA_LIST_MODE=unknown PATH="$BIN:$PATH" bash "$CLI" inspect --receipt "$ORCA_WT/.review/ISSUE-503-TRANSPORT.json" > "$inspect_out"
if grep -q '"lifecycle":"stale"' "$inspect_out"; then pass "inspect ignores request ids as terminal handles"; else fail "request id inspection rejection"; fi
ORCA_LIST_MODE=invalid PATH="$BIN:$PATH" bash "$CLI" inspect --receipt "$ORCA_WT/.review/ISSUE-503-TRANSPORT.json" > "$inspect_out"
if grep -q '"lifecycle":"handle_unverifiable"' "$inspect_out"; then pass "inspect rejects a missing terminal collection as unverifiable"; else fail "missing terminal collection normalization"; fi
ORCA_LIST_MODE=fail PATH="$BIN:$PATH" bash "$CLI" inspect --receipt "$ORCA_WT/.review/ISSUE-503-TRANSPORT.json" > "$inspect_out"
if grep -q '"lifecycle":"handle_unverifiable"' "$inspect_out"; then
  pass "inspect normalizes an unreadable adapter handle probe"
else fail "unverifiable external handle normalization"; fi
runner_path="$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).runner.path)' "$ORCA_WT/.review/ISSUE-503-TRANSPORT.json")"
printf '%s\n' '# changed' >> "$runner_path"
PATH="$BIN:$PATH" bash "$CLI" inspect --receipt "$ORCA_WT/.review/ISSUE-503-TRANSPORT.json" > "$inspect_out"
if grep -q '"lifecycle":"stale"' "$inspect_out"; then pass "inspect detects stale runner identity"; else fail "stale receipt detection"; fi

node - "$VALIDATOR" "$SCHEMA" "$ROOT/schemas/fixtures/transport_receipt.valid.json" "$ROOT/schemas/fixtures/transport_receipt.invalid.json" <<'NODE'
const { validate } = require(process.argv[2]);
const fs = require("fs");
const schema = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
const valid = JSON.parse(fs.readFileSync(process.argv[4], "utf8"));
const invalid = JSON.parse(fs.readFileSync(process.argv[5], "utf8"));
if (validate(schema, valid).length || !validate(schema, invalid).length) process.exit(1);
NODE
if [ "$?" -eq 0 ]; then pass "transport receipt valid and invalid fixtures enforce the contract"; else fail "transport receipt fixtures"; fi

capabilities_out="$TMP_ROOT/capabilities.json"
TRANSPORT_USED="$TMP_ROOT/capability-unused" CMUX_ARGV="$TMP_ROOT/capability-cmux" ORCA_ARGV="$TMP_ROOT/capability-orca" \
PATH="$BIN:$PATH" bash "$CLI" capabilities --worktree "$WT" > "$capabilities_out"
if node -e 'const v=require(process.argv[1]); if(v.adapters.length!==2 || !v.adapters.every(x=>x.available===true)) process.exit(1)' "$capabilities_out"; then
  pass "capabilities reports both adapters and their reasons"
else fail "capabilities report"; fi

echo "---"
if [ "$FAILURES" -eq 0 ]; then echo "ALL CASES PASS"; exit 0; fi
echo "$FAILURES CASE(S) FAILED"
exit 1
