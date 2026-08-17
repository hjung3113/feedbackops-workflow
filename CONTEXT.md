# Routing Subsystem

The vocabulary for `lib/route.cjs` and `model-alloc.*` — the fail-closed model+effort
selection that runs inside an already-admitted runtime and role. Not general project
context: repo operating rules live in `AGENTS.md`, durable decisions in `docs/adr/`.

## Language

**Route**:
A fail-closed, deterministic decision of one exact `model + effort` tuple inside an already-admitted runtime and role.
_Avoid_: selection, allocation (those are broader — see model-alloc's role-default table in the playbook)

**Demand**:
Normalized, already-validated facts the workflow owns going into a Route decision.
_Avoid_: request, input

**Runner offer**:
A host-observed, expiry-bound statement of one pinned runtime executable and its resolved permission/configuration identity.
_Avoid_: capability, availability

**Routing policy**:
A host-pinned immutable project policy snapshot — an allowlist and deterministic candidate order.
_Avoid_: config, score model, ruleset

**Route digest**:
The digest binding one admitted demand, offer, policy, and selected decision together.
_Avoid_: hash, checksum

**Refusal**:
A typed, stdout-only routing outcome that consumes and publishes nothing (no admission, marker, runner, receipt, or fallback).
_Avoid_: rejection, error, failure

**Routing outcome**:
An immutable, advisory-only join of a validated Route binding with attempt telemetry and closure evidence.
_Avoid_: result, record
