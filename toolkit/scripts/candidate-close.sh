#!/usr/bin/env bash
# Evaluate or inspect integrated-candidate closure. Transport/worker state is
# never consulted; only canonical artifacts bound to the live candidate HEAD.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec node "$SCRIPT_DIR/lib/candidate-close.cjs" "$@" \
  --plan-schema "$SCRIPT_DIR/../schemas/execution_plan.schema.json" \
  --integration-schema "$SCRIPT_DIR/../schemas/integration_result.schema.json" \
  --evidence-schema "$SCRIPT_DIR/../schemas/candidate_evidence_set.schema.json" \
  --closure-schema "$SCRIPT_DIR/../schemas/candidate_closure.schema.json" \
  --schema "$SCRIPT_DIR/../schemas/candidate_closure.schema.json" \
  --review-schema "$SCRIPT_DIR/../schemas/review.schema.json" \
  --verify-schema "$SCRIPT_DIR/../schemas/verify.schema.json" \
  --verify-result "$SCRIPT_DIR/lib/verify-artifact.cjs" \
  --pr-schema "$SCRIPT_DIR/../schemas/pr_draft.schema.json" \
  --completion-schema "$SCRIPT_DIR/../schemas/completion_evidence.schema.json" \
  --seat-schema "$SCRIPT_DIR/../schemas/seat_outcome.schema.json" \
  --blocker-schema "$SCRIPT_DIR/../schemas/blocker.schema.json" \
  --validator "$SCRIPT_DIR/lib/json-schema-subset.cjs" \
  --planner "$SCRIPT_DIR/lib/parallel-plan.cjs"
