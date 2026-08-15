#!/usr/bin/env bash
# Public transport-neutral workflow interface.
# bash-3.2-compatible.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRODUCT_HOME="$(cd "$SCRIPT_DIR/.." && pwd -P)"
CORE="$SCRIPT_DIR/dispatch-core.sh"
SCHEMA="$SCRIPT_DIR/../schemas/transport_receipt.schema.json"
VALIDATOR="$SCRIPT_DIR/lib/json-schema-subset.cjs"
CAPABILITY_RESULT="$SCRIPT_DIR/lib/capability-result.cjs"
TRANSPORT_REGISTRY="$SCRIPT_DIR/lib/transport-registry.cjs"

registry_adapters() {
  node "$TRANSPORT_REGISTRY" lines
}

registry_adapter_pipe() {
  node "$TRANSPORT_REGISTRY" pipe
}

is_registered_adapter() {
  for adapter in $(registry_adapters); do
    [ "$1" = "$adapter" ] && return 0
  done
  return 1
}

usage() {
  echo "usage: agent-workflow.sh capabilities [--worktree PATH]" >&2
  echo "       agent-workflow.sh dispatch [--orchestrator $(registry_adapter_pipe)] [--runtime codex|claude|opencode] [--role ROLE] --issue N --worktree PATH [dispatch options]" >&2
  echo "       agent-workflow.sh inspect --receipt PATH" >&2
}

adapter_script() {
  is_registered_adapter "$1" || return 1
  printf '%s/adapters/%s.sh\n' "$SCRIPT_DIR" "$1"
}

capabilities() {
  worktree="${1:-$PWD}"
  printf '{"schema_version":"1","adapters":['
  first=1
  for adapter in $(registry_adapters); do
    script="$(adapter_script "$adapter")"
    result="$(bash "$script" capabilities --worktree "$worktree" 2>/dev/null)"
    probe_status=$?
    # A child probe that fails or emits anything other than the shared
    # capability-result shape is folded into the synthetic unavailable
    # fallback; a child being unavailable is not a fatal aggregate failure.
    # An available claim must clear the same strict acceptance rules the
    # dispatch admission gate applies (shared capability-result validator).
    if [ "$probe_status" -ne 0 ] || ! node "$CAPABILITY_RESULT" aggregate "$result" "$adapter"; then
      result="{\"adapter\":\"$adapter\",\"available\":false,\"reason_code\":\"capability_probe_failed\",\"version\":\"unknown\",\"capabilities\":[]}"
    fi
    [ "$first" -eq 1 ] || printf ','
    printf '%s' "$result"
    first=0
  done
  printf '],"runtimes":['
  first=1
  for runtime in codex claude opencode; do
    script="$SCRIPT_DIR/agent-runtime.sh"
    if [ -x "$script" ]; then
      result="$(bash "$script" capabilities --runtime "$runtime" 2>/dev/null)"
    else
      result=""
    fi
    [ -n "$result" ] || result="{\"runtime\":\"$runtime\",\"available\":false,\"reason_code\":\"runtime_adapter_missing\",\"version\":\"unknown\",\"roles\":[]}"
    [ "$first" -eq 1 ] || printf ','
    printf '%s' "$result"
    first=0
  done
  printf ']}\n'
}

resolve_config() {
  config="$1/workflow-config.json"
  [ -f "$config" ] || return 1
  node - "$config" <<'NODE'
const fs = require("fs");
try {
  const value = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  const keys = Object.keys(value);
  const allowed = new Set(["orchestrator", "runtime", "role"]);
  if (!keys.length || keys.some(key => !allowed.has(key)) || keys.some(key => typeof value[key] !== "string")) process.exit(2);
  process.stdout.write([value.orchestrator || "__unset__", value.runtime || "__unset__", value.role || "__unset__"].join("\t"));
} catch (error) { process.exit(2); }
NODE
}

COMMAND="${1:-}"
[ -n "$COMMAND" ] || { usage; exit 2; }
shift

case "$COMMAND" in
  capabilities)
    WORKTREE=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --worktree) WORKTREE="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; usage; exit 2 ;;
      esac
    done
    capabilities "${WORKTREE:-$PWD}"
    ;;
  dispatch)
    CLI_CHOICE=""
    CLI_RUNTIME=""
    CLI_ROLE=""
    LEGACY_READ_ONLY=0
    LEGACY_PRODUCE_REVIEW=0
    WORKTREE=""
    FORWARD_FILE="$(mktemp)" || exit 2
    trap 'rm -f "$FORWARD_FILE"' EXIT
    while [ $# -gt 0 ]; do
      case "$1" in
        --orchestrator) CLI_CHOICE="$2"; shift 2 ;;
        --runtime) CLI_RUNTIME="$2"; shift 2 ;;
        --role) CLI_ROLE="$2"; shift 2 ;;
        --worktree)
          WORKTREE="$2"
          printf '%s\n' "$1" "$2" >> "$FORWARD_FILE"
          shift 2
          ;;
        --read-only) LEGACY_READ_ONLY=1; printf '%s\n' "$1" >> "$FORWARD_FILE"; shift ;;
        --produce-review) LEGACY_PRODUCE_REVIEW=1; printf '%s\n' "$1" >> "$FORWARD_FILE"; shift ;;
        --conductor-control) printf '%s\n' "$1" >> "$FORWARD_FILE"; shift ;;
        *) printf '%s\n' "$1" >> "$FORWARD_FILE"; shift ;;
      esac
    done
    [ -n "$WORKTREE" ] || { echo "ERROR: dispatch requires --worktree" >&2; exit 2; }
    [ -d "$WORKTREE" ] || { echo "ERROR: worktree does not exist: $WORKTREE" >&2; exit 2; }
    ABS_WORKTREE="$(cd "$WORKTREE" && pwd -P)"
    CONFIG_FIELDS=""
    CONFIG_FIELDS="$(resolve_config "$PRODUCT_HOME")"
    config_status=$?
    if [ "$config_status" -eq 2 ]; then
      echo "ERROR: invalid workflow config: only string orchestrator, runtime, and role keys are allowed" >&2
      exit 2
    fi
    CONFIG_ORCHESTRATOR=""
    CONFIG_RUNTIME=""
    CONFIG_ROLE=""
    if [ -n "$CONFIG_FIELDS" ]; then
      oldIFS=$IFS
      IFS="$(printf '\t')"
      set -- $CONFIG_FIELDS
      IFS=$oldIFS
      CONFIG_ORCHESTRATOR="${1:-}"
      CONFIG_RUNTIME="${2:-}"
      CONFIG_ROLE="${3:-}"
      [ "$CONFIG_ORCHESTRATOR" = "__unset__" ] && CONFIG_ORCHESTRATOR=""
      [ "$CONFIG_RUNTIME" = "__unset__" ] && CONFIG_RUNTIME=""
      [ "$CONFIG_ROLE" = "__unset__" ] && CONFIG_ROLE=""
    fi
    CHOICE="$CLI_CHOICE"
    SOURCE="cli"
    if [ -z "$CHOICE" ] && [ -n "${AGENT_WORKFLOW_ORCHESTRATOR:-}" ]; then
      CHOICE="$AGENT_WORKFLOW_ORCHESTRATOR"
      SOURCE="environment"
    fi
    if [ -z "$CHOICE" ]; then
      CHOICE="$CONFIG_ORCHESTRATOR"
      SOURCE="config"
    fi
    if [ -z "$CHOICE" ]; then
      echo "ERROR: orchestrator_not_configured: choose --orchestrator $(registry_adapter_pipe), set AGENT_WORKFLOW_ORCHESTRATOR, or create $PRODUCT_HOME/workflow-config.json" >&2
      exit 2
    fi
    if ! is_registered_adapter "$CHOICE"; then
      echo "ERROR: unknown_orchestrator: $CHOICE (expected $(registry_adapter_pipe))" >&2; exit 2
    fi
    RUNTIME="$CLI_RUNTIME"
    RUNTIME_SOURCE="cli"
    if [ -z "$RUNTIME" ] && [ -n "${AGENT_WORKFLOW_RUNTIME:-}" ]; then
      RUNTIME="$AGENT_WORKFLOW_RUNTIME"
      RUNTIME_SOURCE="environment"
    fi
    if [ -z "$RUNTIME" ] && [ -n "$CONFIG_RUNTIME" ]; then
      RUNTIME="$CONFIG_RUNTIME"
      RUNTIME_SOURCE="config"
    fi
    if [ -z "$RUNTIME" ]; then
      RUNTIME="codex"
      RUNTIME_SOURCE="legacy_compatibility"
    fi
    case "$RUNTIME" in
      codex|claude|opencode) ;;
      *) echo "ERROR: unknown_runtime: $RUNTIME (expected codex, claude, or opencode)" >&2; exit 2 ;;
    esac
    ROLE="$CLI_ROLE"
    ROLE_SOURCE="cli"
    if [ -z "$ROLE" ] && [ -n "${AGENT_WORKFLOW_ROLE:-}" ]; then
      ROLE="$AGENT_WORKFLOW_ROLE"
      ROLE_SOURCE="environment"
    fi
    if [ -z "$ROLE" ] && [ -n "$CONFIG_ROLE" ]; then
      ROLE="$CONFIG_ROLE"
      ROLE_SOURCE="config"
    fi
    if [ -z "$ROLE" ]; then
      if [ "$LEGACY_PRODUCE_REVIEW" -eq 1 ]; then
        ROLE="reviewer"
      elif [ "$LEGACY_READ_ONLY" -eq 1 ]; then
        ROLE="architect"
      else
        ROLE="implementation"
      fi
      ROLE_SOURCE="legacy_compatibility"
    fi
    case "$ROLE" in
      conductor|architect|implementation|reviewer|verifier|visual|release) ;;
      *) echo "ERROR: unknown_role: $ROLE" >&2; exit 2 ;;
    esac
    set --
    while IFS= read -r arg; do set -- "$@" "$arg"; done < "$FORWARD_FILE"
    echo "agent-workflow: orchestrator=$CHOICE source=$SOURCE runtime=$RUNTIME runtime_source=$RUNTIME_SOURCE role=$ROLE role_source=$ROLE_SOURCE" >&2
    exec bash "$CORE" --adapter "$CHOICE" --runtime "$RUNTIME" --role "$ROLE" "$@"
    ;;
  inspect)
    RECEIPT=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --receipt) RECEIPT="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; usage; exit 2 ;;
      esac
    done
    [ -r "$RECEIPT" ] || { echo "ERROR: receipt is unreadable: $RECEIPT" >&2; exit 2; }
    RECEIPT_IDENTITY="$(node - "$RECEIPT" "$SCHEMA" "$VALIDATOR" <<'NODE'
const fs = require("fs");
const [file, schemaFile, validatorFile] = process.argv.slice(2);
try {
  const receipt = JSON.parse(fs.readFileSync(file, "utf8"));
  const schema = JSON.parse(fs.readFileSync(schemaFile, "utf8"));
  const { validate } = require(validatorFile);
  if (validate(schema, receipt).length) process.exit(2);
  process.stdout.write(JSON.stringify({ adapter: receipt.adapter, worktree: receipt.worktree_path, handle: receipt.external_handle }));
} catch (error) { process.exit(2); }
NODE
)" || { echo "ERROR: invalid transport receipt" >&2; exit 2; }
    RECEIPT_ADAPTER="$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).adapter)' "$RECEIPT_IDENTITY")"
    RECEIPT_WORKTREE="$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).worktree)' "$RECEIPT_IDENTITY")"
    RECEIPT_HANDLE="$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).handle)' "$RECEIPT_IDENTITY")"
    INSPECT_ADAPTER="$(adapter_script "$RECEIPT_ADAPTER")" || { echo "ERROR: invalid receipt adapter" >&2; exit 2; }
    ADAPTER_INSPECTION="$(bash "$INSPECT_ADAPTER" inspect --worktree "$RECEIPT_WORKTREE" --external-handle "$RECEIPT_HANDLE" 2>/dev/null)"
    inspect_status=$?
    if [ "$inspect_status" -ne 0 ] || [ -z "$ADAPTER_INSPECTION" ]; then
      ADAPTER_INSPECTION='{"lifecycle":"handle_unverifiable","reason":"adapter status probe failed"}'
    fi
    node - "$RECEIPT" "$SCHEMA" "$VALIDATOR" "$ADAPTER_INSPECTION" <<'NODE'
const fs = require("fs");
const crypto = require("crypto");
const [file, schemaFile, validatorFile, adapterInspectionJson] = process.argv.slice(2);
try {
  const receipt = JSON.parse(fs.readFileSync(file, "utf8"));
  const schema = JSON.parse(fs.readFileSync(schemaFile, "utf8"));
  const { validate } = require(validatorFile);
  const errors = validate(schema, receipt);
  if (errors.length) throw new Error(errors.join("; "));
  const inspection = JSON.parse(adapterInspectionJson);
  if (!["live", "stale", "handle_unverifiable"].includes(inspection.lifecycle)
      || typeof inspection.reason !== "string" || !inspection.reason.trim()) throw new Error("invalid adapter inspection");
  let lifecycle = inspection.lifecycle;
  let reason = inspection.reason;
  try {
    const actual = crypto.createHash("sha256").update(fs.readFileSync(receipt.runner.path)).digest("hex");
    if (actual !== receipt.runner.sha256) { lifecycle = "stale"; reason = "runner identity changed"; }
  } catch (error) { lifecycle = "stale"; reason = "runner is missing or unreadable"; }
  process.stdout.write(JSON.stringify({
      schema_version: "1",
      adapter: receipt.adapter,
      runtime: receipt.runtime || "codex",
      role: receipt.role || "implementation",
      external_handle: receipt.external_handle,
    lifecycle,
    reason,
    authoritative: false,
    completion_authority: "canonical REVIEW and VERIFY artifacts bound to live HEAD"
  }) + "\n");
} catch (error) {
  console.error(`ERROR: invalid transport receipt: ${error.message}`);
  process.exit(2);
}
NODE
    ;;
  *) echo "unknown command: $COMMAND" >&2; usage; exit 2 ;;
esac
