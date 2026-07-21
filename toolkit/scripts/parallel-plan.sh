#!/usr/bin/env bash
# Validate/decide a canonical execution plan or bind one seat to admission.
# bash-3.2-compatible.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NODE_IMPL="$SCRIPT_DIR/lib/parallel-plan.cjs"
SCHEMA="$SCRIPT_DIR/../schemas/execution_plan.schema.json"
VALIDATOR="$SCRIPT_DIR/lib/json-schema-subset.cjs"
COMMAND="${1:-}"
shift || true
case "$COMMAND" in decide|admit) ;; *) echo '{"status":"error","errors":[{"code":"invalid_arguments"}]}' ; exit 2 ;; esac
exec node "$NODE_IMPL" "$COMMAND" "$@" --schema "$SCHEMA" --validator "$VALIDATOR"
