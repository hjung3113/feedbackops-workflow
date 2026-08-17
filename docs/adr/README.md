# Architecture Decision Records

This directory holds this project's durable design decisions — the ones that survive past
the session that made them. It exists because decisions were previously scattered across
`HANDOFF.md` (a rolling session log, now pruned to the latest entry only — see
`docs/handoff-archive/`) and CONDUCTOR's own private memory, neither of which is a place a
future contributor, a fresh CONDUCTOR session, or a fresh reader of this repo would ever
think to check. A decision that only lives in a session log or an agent's private memory is
not actually recorded — it just looks recorded until the next session starts cold.

## When to write one

Write an ADR when a decision would otherwise get silently re-litigated or accidentally
reversed by someone (human or agent) who did not see the discussion that produced it.
Concretely: anything an agent might "clean up" or "simplify" without realizing it would break
an invariant, any rejected-but-tempting alternative worth remembering as rejected, any rule
this repo's own tooling depends on that is not obvious from reading the code alone.

Do not write one for routine implementation detail that the code and its tests already make
self-evident — an ADR restates a *decision*, not a changelog entry.

## Format

One file per decision: `NNNN-short-title.md`, numbered sequentially, never renumbered.

```markdown
# NNNN. Title

Status: proposed | accepted | superseded by NNNN

## Context
What forces/constraints made a decision necessary. The problem, not the solution.

## Decision
What was decided, stated plainly.

## Consequences
What this makes easier, what it makes harder, what it forecloses.
```

**Immutable once accepted.** If a decision changes, write a NEW ADR that supersedes the old
one (set the old one's status to `superseded by NNNN`) — never rewrite an accepted ADR's
Context/Decision/Consequences in place. Typo fixes are fine; changing the substance is not.

## Index

| # | Title | Status |
| --- | --- | --- |
| [0001](0001-orchestrator-adapters-shell-out-to-real-clis.md) | Orchestrator adapters must shell out to the real transport CLI, never hand-roll the equivalent | accepted |
| [0002](0002-route-canonical-serializer-is-not-samejson.md) | `route.cjs`'s digest-feeding `canonical()` is a distinct function from the shared `sameJson` equality check | accepted |
| [0003](0003-dispatch-retry-timeouts-do-not-scale-with-task-size.md) | Watchdog stall/retry timeouts are fixed regardless of task scope | proposed — filed as #157 |
| [0004](0004-test-doubles-must-assert-on-received-input.md) | Smoke-test doubles must capture and assert on received input, not just that they ran | accepted (retrofit tracked as #164) |
