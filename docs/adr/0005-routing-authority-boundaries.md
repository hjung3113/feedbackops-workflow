# 0005. Routing authority stays diagnostic-only; completion authority stays with REVIEW/VERIFY

Moved out of `CONTEXT.md` (a Route is scoped narrowly: it decides one model+effort tuple
inside an already-admitted runtime/role — it must not become a second source of truth for
anything else). Decided: CONDUCTOR remains the sole writer of canonical ROUND-STATE; existing
admission owns issue/revision/worktree/HEAD/attempt identity and routing adds no parallel
authority; runtime adapters own runtime-native invocation/sandbox behavior; REVIEW and VERIFY
evidence remain the only completion authority — a Route or its receipt is diagnostic
provenance only; telemetry is advisory-only and can report outcomes but never feed back into
route selection or mutate policy.

Consequence: nothing may treat a Route decision, its digest, or its receipt as proof a
workflow completed, admitted state changed, or telemetry should influence a future routing
decision — those boundaries are load-bearing for `lib/route.cjs`'s fail-closed guarantee.
