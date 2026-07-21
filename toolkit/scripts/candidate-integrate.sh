#!/usr/bin/env bash
# Integrate planned seat deltas into a clean candidate in declared order.
# Never resets, checks out, aborts, or discards candidate changes.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec node "$SCRIPT_DIR/lib/candidate-integrate.cjs" "$@" \
  --schema "$SCRIPT_DIR/../schemas/integration_result.schema.json" \
  --validator "$SCRIPT_DIR/lib/json-schema-subset.cjs" \
  --planner "$SCRIPT_DIR/parallel-plan.sh"
