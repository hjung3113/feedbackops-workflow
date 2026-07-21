#!/usr/bin/env bash
# Local opt-in model/task telemetry. Bash 3.2 compatible.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec node "$SCRIPT_DIR/lib/telemetry.mjs" "$@"
