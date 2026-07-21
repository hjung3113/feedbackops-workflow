#!/usr/bin/env bash
# Public transport-neutral workflow interface.
# bash-3.2-compatible.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE="$SCRIPT_DIR/dispatch-core.sh"
SCHEMA="$SCRIPT_DIR/../schemas/transport_receipt.schema.json"
VALIDATOR="$SCRIPT_DIR/lib/json-schema-subset.cjs"

usage() {
  echo "usage: agent-workflow.sh capabilities [--worktree PATH]" >&2
  echo "       agent-workflow.sh dispatch [--orchestrator cmux|orca] --issue N --worktree PATH [dispatch options]" >&2
  echo "       agent-workflow.sh inspect --receipt PATH" >&2
}

adapter_script() {
  case "$1" in
    cmux|orca) printf '%s/adapters/%s.sh\n' "$SCRIPT_DIR" "$1" ;;
    *) return 1 ;;
  esac
}

capabilities() {
  worktree="${1:-$PWD}"
  printf '{"schema_version":"1","adapters":['
  first=1
  for adapter in cmux orca; do
    script="$(adapter_script "$adapter")"
    result="$(bash "$script" capabilities --worktree "$worktree" 2>/dev/null)"
    [ -n "$result" ] || result="{\"adapter\":\"$adapter\",\"available\":false,\"reason_code\":\"capability_probe_failed\",\"version\":\"unknown\",\"capabilities\":[]}"
    [ "$first" -eq 1 ] || printf ','
    printf '%s' "$result"
    first=0
  done
  printf ']}\n'
}

resolve_config_choice() {
  config="$1/.agent-workflow/workflow-config.json"
  [ -f "$config" ] || return 1
  node - "$config" <<'NODE'
const fs = require("fs");
try {
  const value = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  const keys = Object.keys(value);
  if (keys.length !== 1 || keys[0] !== "orchestrator" || typeof value.orchestrator !== "string") process.exit(2);
  process.stdout.write(value.orchestrator);
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
    WORKTREE=""
    FORWARD_FILE="$(mktemp)" || exit 2
    trap 'rm -f "$FORWARD_FILE"' EXIT
    while [ $# -gt 0 ]; do
      case "$1" in
        --orchestrator) CLI_CHOICE="$2"; shift 2 ;;
        --worktree)
          WORKTREE="$2"
          printf '%s\n' "$1" "$2" >> "$FORWARD_FILE"
          shift 2
          ;;
        *) printf '%s\n' "$1" >> "$FORWARD_FILE"; shift ;;
      esac
    done
    [ -n "$WORKTREE" ] || { echo "ERROR: dispatch requires --worktree" >&2; exit 2; }
    [ -d "$WORKTREE" ] || { echo "ERROR: worktree does not exist: $WORKTREE" >&2; exit 2; }
    ABS_WORKTREE="$(cd "$WORKTREE" && pwd -P)"
    CHOICE="$CLI_CHOICE"
    SOURCE="cli"
    if [ -z "$CHOICE" ] && [ -n "${AGENT_WORKFLOW_ORCHESTRATOR:-}" ]; then
      CHOICE="$AGENT_WORKFLOW_ORCHESTRATOR"
      SOURCE="environment"
    fi
    if [ -z "$CHOICE" ]; then
      CHOICE="$(resolve_config_choice "$ABS_WORKTREE")"
      config_status=$?
      if [ "$config_status" -eq 2 ]; then
        echo "ERROR: invalid workflow config: only {\"orchestrator\":\"cmux|orca\"} is allowed" >&2
        exit 2
      fi
      SOURCE="config"
    fi
    if [ -z "$CHOICE" ]; then
      echo "ERROR: orchestrator_not_configured: choose --orchestrator cmux|orca, set AGENT_WORKFLOW_ORCHESTRATOR, or create .agent-workflow/workflow-config.json" >&2
      exit 2
    fi
    case "$CHOICE" in
      cmux|orca) ;;
      *) echo "ERROR: unknown_orchestrator: $CHOICE (expected cmux or orca)" >&2; exit 2 ;;
    esac
    set --
    while IFS= read -r arg; do set -- "$@" "$arg"; done < "$FORWARD_FILE"
    echo "agent-workflow: orchestrator=$CHOICE source=$SOURCE" >&2
    exec bash "$CORE" --adapter "$CHOICE" "$@"
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
      || typeof inspection.reason !== "string" || !inspection.reason) throw new Error("invalid adapter inspection");
  let lifecycle = inspection.lifecycle;
  let reason = inspection.reason;
  try {
    const actual = crypto.createHash("sha256").update(fs.readFileSync(receipt.runner.path)).digest("hex");
    if (actual !== receipt.runner.sha256) { lifecycle = "stale"; reason = "runner identity changed"; }
  } catch (error) { lifecycle = "stale"; reason = "runner is missing or unreadable"; }
  process.stdout.write(JSON.stringify({
    schema_version: "1",
    adapter: receipt.adapter,
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
