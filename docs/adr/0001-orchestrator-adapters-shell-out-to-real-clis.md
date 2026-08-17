# 0001. Orchestrator adapters must shell out to the real transport CLI, never hand-roll the equivalent

Status: accepted

## Context

This toolkit supports three transport adapters — `toolkit/scripts/adapters/cmux.sh`,
`herdr.sh`, `orca.sh` — each backing `agent-workflow.sh dispatch --orchestrator <cmux|orca>`.
Each adapter's `launch`/`inspect`/`capabilities` actions are thin wrappers that shell out to
the real `cmux`/`herdr`/`orca` binary (`orca terminal create`, `cmux workspace create`,
`herdr workspace create` + `pane run`), never reimplementing terminal/process lifecycle
themselves. `AGENTS.md` states this explicitly: "Use `toolkit/scripts/agent-workflow.sh
dispatch` with an explicit `cmux` or `orca` selection for write-capable dispatch. Do not
hand-build transport or watchdog launches."

This was confirmed by direct code read during a 2026-08-17 session where CONDUCTOR, while
trying to route around a stuck dispatch, twice hand-built the equivalent invocation directly
(a raw `opencode run ...` Bash call, then a raw `orca terminal send` call) instead of going
back through `agent-workflow.sh dispatch` with adjusted `--stall-timeout`/
`--first-progress-timeout` flags that already exist for exactly this situation. Both were
corrected after the user pointed out the adapter layer already does this correctly and the
rule already says not to bypass it.

## Decision

Every write-capable dispatch goes through `agent-workflow.sh dispatch --orchestrator
<cmux|orca>`, which delegates to the matching `adapters/*.sh` file, which shells out to the
real transport CLI. When a dispatch is stuck or misbehaving, the fix is to adjust the
sanctioned flags (`--stall-timeout`, `--first-progress-timeout`, `--tier`, etc.) or fix the
underlying toolkit defect (filed as an issue, see
[0003](0003-dispatch-retry-timeouts-do-not-scale-with-task-size.md)) — never to hand-build a
raw invocation of the underlying runtime CLI or transport CLI as a workaround, even
temporarily, even under time pressure.

## Consequences

- A stuck dispatch must be diagnosed and fixed at the toolkit level (or its flags adjusted),
  not routed around — this is slower in the moment but keeps the transport-adapter contract
  meaningful; an adapter nobody actually goes through is dead weight.
- Any future workaround-under-pressure should reach for `agent-watchdog.sh`'s existing
  `--stall-timeout`/`--first-progress-timeout`/`--max-retries` (env-var only currently, see
  0003) flags before reaching for a raw CLI call.
