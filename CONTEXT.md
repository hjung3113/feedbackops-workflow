# Workflow Toolkit Context

## Routing vocabulary

- **Route** — a fail-closed, deterministic decision of one exact `model + effort` tuple inside an already admitted runtime and role. A Route does not select runtime, transport, scope, sandbox, or verification obligations.
- **Demand** — normalized, already-validated facts that the existing workflow owns. It is not CONDUCTOR prose or an LLM assessment.
- **Runner offer** — a host-observed, expiry-bound statement of one pinned runtime executable and its resolved permission/configuration identity. It never attests remote model availability, workflow scope, or verification authority.
- **Routing policy** — a host-pinned immutable project policy snapshot. It is an allowlist and deterministic candidate order, not a score model, self-learning system, mutable worktree configuration, or a second CONDUCTOR.
- **Route digest** — the digest binding a particular admitted demand, offer, policy, and selected decision. It joins the existing atomic admission identity; receipts only copy it. A refusal has no digest binding or receipt.
- **Refusal** — a typed stdout-only routing outcome. It consumes and publishes no admission, attempt marker, runner, worktree, transport, receipt, telemetry sample, or fallback.
- **Routing outcome** — an immutable, advisory-only join of a validated admitted Route binding with existing attempt telemetry and canonical closure evidence. It stores only a locally salted route pseudonym, and is never a routing input, policy editor, or completion authority.

## Authority rules

- CONDUCTOR remains the sole writer of canonical ROUND-STATE.
- Existing admission owns issue, revision, worktree, live HEAD, attempt, and ordinal identity; routing adds no parallel authority.
- Runtime adapters own runtime-native invocation and sandbox/permission behavior.
- REVIEW and VERIFY evidence remain the only completion authority. A Route or its receipt is diagnostic provenance only.
- Telemetry is advisory-only evidence: it can report outcomes but cannot be an input to route selection or mutate policy.
