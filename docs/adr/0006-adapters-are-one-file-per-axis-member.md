# 0006. Every feature executes through per-member adapter files, on both axes, never inline

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

This asymmetry was surfaced during a 2026-08-17 domain-modeling session, and the same
session's follow-up architecture audit found the inline-branching pattern had already leaked
past `agent-runtime.sh` into files that are supposed to be axis-neutral: `dispatch-core.sh`
inline-branches on `$RUNTIME = "opencode"` for permission-file resolution (issue #169), and
`lib/admission-recover.cjs` validates the `transport` field of a route binding through
`transport-registry.cjs` but the `runtime` field through a hardcoded literal array right next
to it (issue #168) — the exact duplication the Axis registry pattern exists to prevent.

## Decision

For any feature the workflow performs (dispatch, admission recovery, capability probing,
etc.), execution goes through an abstracted interface per axis member on **both** axes, and
never inline-branches on a hardcoded transport or runtime name outside that member's own
file. Concretely, for one feature: one file per Transport member (`orca`/`cmux`/`herdr`), and
inside each, when it needs to run an agent, it calls through the Runtime abstraction — which
is itself one file per Runtime member (`codex`/`claude`/`opencode`), not a `case` block. A
core/shared file (`dispatch-core.sh`, `admission-recover.cjs`, etc.) may *call* per-member
files or an Axis registry lookup, but must not itself contain axis-member-specific logic.

`agent-runtime.sh`'s inline codex/claude/opencode branches are to be split into per-runtime
files (mirroring `adapters/<transport>.sh`). `dispatch-core.sh` and `admission-recover.cjs`'s
leaks (issues #168, #169) are to be fixed the same way: delegate to the registry or the
per-member file instead of re-deciding axis membership inline. Until these land, the inline
branching is known debt, not the intended shape.

## Consequences

- Adding a fourth runtime or transport is always "add one file, register it," never "add a
  case branch to an existing file" — anywhere in the codebase, not just in the two adapter
  entrypoints.
- A code reviewer's fast check for this rule: `grep` a core/shared file for a literal
  `"codex"`/`"claude"`/`"opencode"` or `"cmux"`/`"orca"`/`"herdr"` outside its own per-member
  file or the two `*-registry.cjs` files — a hit is a violation unless it's a deliberate,
  self-documented legacy-compat shim (e.g. `cmux-dispatch.sh`'s `--runtime codex` default,
  which exists for historical callers and says so in its own header comment).
- `agent-runtime.sh`, `dispatch-core.sh`, and `admission-recover.cjs` each need a follow-up
  fix to reach this shape (tracked as issues #168, #169, and this ADR for `agent-runtime.sh`).
