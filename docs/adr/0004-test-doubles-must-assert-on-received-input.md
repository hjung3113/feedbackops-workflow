# 0004. Smoke-test doubles must capture and assert on the input they received, not just that they ran

Status: accepted (as a going-forward testing rule; retrofitting existing stubs is tracked as #164)

## Context

A 2026-08-17 multi-agent root-cause audit (mining HANDOFF.md's full session history plus a
direct code read of the dispatch/verify pipeline) found the single most-repeated recurring
failure shape in this project's history: a fix ships, its smoke suite goes green, and the
fix is later found to have never actually taken effect (or to have been silently reverted)
because the smoke test's stub/double never asserted anything about the arguments or stdin it
was actually invoked with — only that the pipeline ran to completion.

Confirmed instances (all independently verified against the actual files):
- PR #154 (issue #142 Phase A2b-part2): "no test asserted the new argv actually reaches
  claude's process — the existing stub ignored `"$@"` entirely, so the new smoke cases would
  have passed even with the streaming-argv change reverted."
- The same PR: zero smoke coverage existed for `--conductor-control` × claude NDJSON — "the
  exact regression class that got A2b-part1 reverted" (a prior phase of the same issue).
- A2b-part1 itself: "nothing would have caught the regression before merge."
- Issues #112, #124, #130 (capability-probe false-green class): each was caught only by a
  pre-merge Opus review, not by the smoke suite meant to catch exactly that class of defect.

The one place this is done correctly — `runtime-model-preflight.smoke.sh:105` sets
`RUNTIME_ARGS_LOG="$TMP/allocated-claude.args"` and asserts against the captured argv — shows
the fix is not exotic; it simply is not a required contract for writing a new stub, so most
stubs default to the weaker "ran without crashing" shape.

## Decision

Every stub/double used in this project's smoke suites must capture the argv and/or stdin it
actually received (following the `runtime-model-preflight.smoke.sh:105` pattern) and the
smoke case exercising it must assert against that capture, not merely that the stub was
invoked and returned success. A smoke case protecting a specific behavior change should
additionally include a mutation check: reverting the change under test must make that
specific case fail — a case that stays green whether or not the behavior is present is not
a passing test of that behavior, it is a passing test of "the pipeline still runs."

## Consequences

- New smoke coverage written against this rule costs slightly more to author (a capture
  file/variable plus an assertion, instead of just an exit-code check).
- It directly targets why fixes in this project have repeatedly needed a second, human/Opus
  review pass to catch what the automated suite should have caught — per the audit, this
  pattern explains why unrelated defect classes (capability-probe false-greens, streaming-argv
  regressions, NDJSON extraction gaps) kept resurfacing after being "fixed": the fix shipped
  without a test that could detect its own removal.
- Retrofitting the existing stub inventory is out of scope for this ADR (tracked separately,
  #164) — this ADR establishes the rule for new/touched stubs going forward.
