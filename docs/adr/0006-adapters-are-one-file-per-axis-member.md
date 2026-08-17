# 0006. Every axis adapter is one file per member, no inline case-branching

Status: accepted

## Context

Transport adapters (`toolkit/scripts/adapters/cmux.sh`, `orca.sh`, `herdr.sh`) already
follow one-file-per-member: each transport's differing session model is normalized behind
a shared seat seam, and adding a transport means adding a file, registered in
`transport-registry.cjs`.

`toolkit/scripts/agent-runtime.sh` does the equivalent job for the Runtime axis — it
normalizes codex/claude/opencode's genuinely different CLI shapes (e.g. the effort flag is
`-c model_reasoning_effort=...` for codex, `--effort` for claude, `--variant` for opencode)
behind one uniform `agent-runtime.sh run --runtime R ...` interface. But unlike the
transport adapters, all three runtimes are inline `case` branches in a single file, sharing
`runtime-registry.cjs` as their declarative twin without a matching one-file-per-runtime
split.

This asymmetry was surfaced during a 2026-08-17 domain-modeling session: it reads as if
Runtime and Transport use different patterns (adapter vs. inline boundary), when in fact
both already do the same normalization work — only the file layout differs.

## Decision

Every axis adapter, Transport or Runtime, is one file per axis member. `agent-runtime.sh`'s
inline codex/claude/opencode branches are to be split into per-runtime files (mirroring
`adapters/<transport>.sh`), consistent with how the Transport axis already works. Until that
split lands, `agent-runtime.sh`'s inline branching is known debt, not the intended shape.

## Consequences

- Adding a fourth runtime or transport is always "add one file, register it," never "add a
  case branch to an existing file."
- `agent-runtime.sh` needs a follow-up refactor to reach this shape; until then, new runtime
  branches should not be added inline without acknowledging they compound the debt this ADR
  flags.
