# 0002. `route.cjs`'s digest-feeding `canonical()` is a distinct function from the shared `sameJson` equality check

Status: accepted

## Context

`toolkit/scripts/lib/route.cjs` has a `canonical(value)` function that recursively sorts
object keys and hand-serializes, feeding `sha256(canonical(...))` to produce `route_digest`
and `policy_digest`. Several other files independently implement a much simpler equality
check, effectively `JSON.stringify(a) === JSON.stringify(b)` — insertion-order sensitive,
drops `undefined` values (issue #129's consolidation work identified 4+ copies of this
pattern: `lib/verify-artifact.cjs`, `lib/verify-result.cjs`, `lib/json-schema-subset.cjs`,
`lib/candidate-close.cjs`).

These look similar enough (both are "are these two JSON values the same") that a
consolidation effort could plausibly merge them into one shared `sameJson` helper. Doing so
would be wrong: `canonical()`'s key-sorting changes the serialized bytes for any object whose
keys were inserted in a different order but represent the same logical value, while
`sameJson` treats those as different. Substituting one for the other would silently change
every `route_digest`/`policy_digest` value computed system-wide — a routing-integrity
regression, not a refactor.

## Decision

`route.cjs`'s `canonical()` stays a separate, untouched function. Only the true
`JSON.stringify`-equality copies (confirmed character-equivalent to `JSON.stringify(l) ===
JSON.stringify(r)`) consolidate into the shared `sameJson` helper in
`lib/contract-validators.cjs`. Before folding any additional existing copy into `sameJson`,
confirm character-equivalence first — a copy with sorted keys, a custom replacer, or
different `undefined` handling must NOT be folded in.

## Consequences

- `route_digest`/`policy_digest` computation is immune to any future `sameJson`
  refactor — the two code paths are permanently decoupled.
- Anyone extending the shared-validator consolidation (issue #129 and similar) must treat
  `route.cjs`'s `canonical()` as out of scope by default, not an oversight to "finish."
