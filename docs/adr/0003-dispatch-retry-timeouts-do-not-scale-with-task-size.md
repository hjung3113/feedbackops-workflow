# 0003. Watchdog stall/retry timeouts are fixed regardless of task scope

Status: proposed (known limitation, not yet fixed — primary issue is #157; related:
#133/#150 already track watchdog-liveness/orca-wait investigation, #163 tracks the adjacent
"no await primitive for dispatch completion" cause. A broader 2026-08-17 multi-agent
root-cause audit of recurring toolkit failures also produced #158-#162, #164, #165 — see
each for its own scope, not all are timeout-scaling specifically)

## Context

`toolkit/scripts/agent-watchdog.sh` defaults (line ~11): `FIRST_PROGRESS_TIMEOUT=240s`,
`STALL_TIMEOUT=180s`, `MAX_RETRIES=2` (3 total attempts), `MAX_WALLCLOCK=3600s`. These are
flat constants — nothing in `dispatch-core.sh` reads a task-scope signal (ROUND-STATE's
`touch_allowlist` breadth, `acceptance.criteria` count, or `model-alloc.json`'s existing-but-
apparently-unused `signals.large_changed_lines`/`large_file_count` config) to scale them up
for broad, multi-file work.

Observed directly (2026-08-17 session, issue #129 — a 5-batch, ~20-call-site refactor):
3 consecutive dispatch attempts each hit `STALL_TIMEOUT` while still reading files, before
any edit landed, then fully restarted with no memory of what the prior attempt had already
explored. This exact failure shape ("revision 1 exhausted 3 attempts reading files, wrote
nothing") is documented recurring across multiple past HANDOFF entries for different issues
(#128, #135, #129), not a one-off. `dispatch-core.sh` does expose `--stall-timeout`/
`--first-progress-timeout` as CLI flags (an operator can raise them manually per dispatch),
but nothing scales them automatically, and `--max-retries`/`--max-wallclock` are not exposed
as `dispatch-core.sh` flags at all (env-var override only:
`AGENT_WATCHDOG_MAX_RETRIES`/`AGENT_WATCHDOG_MAX_WALLCLOCK`).

## Decision

Filed, not yet implemented — per [[feedback_toolkit_fixes_file_issue_dont_implement]] this is
toolkit-code scope and must be designed via GitHub issue before implementation, not patched
ad hoc by CONDUCTOR. #157 records the corrected direction after adversarial (Opus) review of
a first proposal: do NOT compute scope from a `git diff` at admission time (the diff is empty
before work starts, so this would route every dispatch to the smallest model/effort — the
opposite of the intent). Instead scale `FIRST_PROGRESS_TIMEOUT`/`STALL_TIMEOUT`/`MAX_RETRIES`/
`MAX_WALLCLOCK` off signals already known and validated at admission time: ROUND-STATE's
`touch_allowlist` size, `acceptance.criteria` count, and `tier`. `model-alloc.json`'s
`signals` config is confirmed dead code in production (verified: zero real callers ever pass
`--alloc-evidence`, every real dispatch lands in `model-alloc.sh`'s
`no_canonical_evidence: default allocation retained` branch) — do not assume it is wired to
anything without re-checking.

## Consequences

- Until fixed, any broad-scope dispatch should be split into small batches by the prompt
  author (as issue #129's prompt was, successfully, after 3 blind-restart failures), or
  launched with manually-raised `--stall-timeout`/`--first-progress-timeout` — not routed
  around via a hand-built bypass (see [0001](0001-orchestrator-adapters-shell-out-to-real-clis.md)).
- This ADR should be closed out (status updated to `accepted`, with a decision recorded) once
  the corresponding GitHub issue is filed and designed.
