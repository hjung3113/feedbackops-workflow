# 0006. Each axis member owns one file for its own concern; nothing else inline-branches on it

Status: accepted

## Context

Transport adapters (`toolkit/scripts/adapters/cmux.sh`, `orca.sh`, `herdr.sh`) already
follow one-file-per-member. Reading what actually varies between them: `launch` takes the
identical `--name --worktree --runner-relative` interface in every adapter, and the file
differs only in how *that transport's* workspace/session gets created and how its response
handle gets read back and normalized — `cmux workspace create` + a node handle-validator vs.
`orca terminal create --json` + `normalize_handle_json`. Read/write mode never appears in an
adapter file; the `read_only` strings in their capability lists just advertise that the
underlying transport CLI supports a read-only listing operation, not a mode branch.

`toolkit/scripts/agent-runtime.sh` does the equivalent job for the Runtime axis, and what
varies there is a different concern entirely: invocation shape (codex's effort flag is
`-c model_reasoning_effort=...`, claude's is `--effort`, opencode's is `--variant`), the
mode-to-permission mapping (codex delegates write mode to the separate hardened
`codex-safe.sh` wrapper entirely; claude passes `--permission-mode acceptEdits|plan`; opencode
loads a different JSON permission file per mode), and the response/progress-reading
convention (claude reads its `--output-format`/progress flags from `runtime-registry.cjs`'s
`progress-flags` table to parse the stream back). Unlike the transport adapters, all three
runtimes are inline `case` branches in one file, sharing `runtime-registry.cjs` as their
declarative twin without a matching one-file-per-runtime split.

This was surfaced during a 2026-08-17 domain-modeling session, first as a bare asymmetry
("why does Transport get files but Runtime gets inline `case` branches?"), then refined once
the actual per-file contents were read: the split was never about "features" or "roles" —
role/mode/prompt are just parameters passed through either kind of file. It's about each axis
owning a genuinely different concern: **Transport = workspace/session lifecycle + response
normalization; Runtime = invocation shape + mode-to-permission mapping + response-parsing
convention.** A feature-per-file grid (one file per feature per transport, containing one
file per feature per runtime) was considered and rejected — it doesn't match either axis's
actual variance and would multiply files for no reason, since one transport file already
handles every action (`capabilities`/`launch`/`inspect`) as subcommands, and one runtime file
already handles every role/mode as parameters.

The same session's architecture audit found the inline-branching pattern had already leaked
past `agent-runtime.sh` into files that are supposed to be axis-neutral: `dispatch-core.sh`
inline-branches on `$RUNTIME = "opencode"` to resolve which permission file to use (issue
#169) — logic that belongs inside the opencode runtime file once the split lands, since
mode-to-permission mapping is exactly the Runtime axis's concern. And `lib/admission-recover.cjs`
validates a route binding's `transport` field through `transport-registry.cjs` but its
`runtime` field through a hardcoded literal array right next to it (issue #168) — the exact
duplication the Axis registry pattern exists to prevent.

## Decision

Each axis member (one Transport, one Runtime) owns exactly one file. That file is the sole
owner of its axis's concern — Transport: workspace/session creation and response
normalization; Runtime: invocation shape, mode-to-permission mapping, response-parsing
convention — and handles every action/role/mode as a parameter or subcommand, never as a
reason to add another file. No other file (core/shared scripts like `dispatch-core.sh`,
`admission-recover.cjs`, or the opposite axis's files) may inline-branch on a hardcoded
transport or runtime name; they call through the per-member file or an Axis registry lookup
instead.

`agent-runtime.sh`'s inline codex/claude/opencode branches are to be split into per-runtime
files (mirroring `adapters/<transport>.sh`), each keeping its full existing mode-handling
logic (codex's delegation to `codex-safe.sh` on write, claude's permission-mode mapping,
opencode's permission-file selection) — that logic already lives at the right axis, it just
needs to move into its own file. `dispatch-core.sh`'s opencode permission-file leak (#169)
gets fixed by moving into the opencode runtime file, not by adding a third axis or a
runtime × mode file grid. `admission-recover.cjs`'s hardcoded runtime literal (#168) gets
fixed by delegating to `runtime-registry.cjs`, matching the `transport` check beside it.

## Consequences

- Adding a fourth runtime or transport is "add one file, register it, and put that member's
  full lifecycle/invocation logic inside it" — never "add a case branch to an existing file"
  and never "add a new file per feature."
- Mode (read/write) is not a third axis needing its own file split; it is Runtime-owned
  parameter data, handled inside each runtime's one file (up to and including delegating to
  an entirely different wrapper script for one mode, as codex already does).
- A reviewer's fast check: `grep` a core/shared file for a literal `"codex"`/`"claude"`/
  `"opencode"` or `"cmux"`/`"orca"`/`"herdr"` outside its own per-member file or the two
  `*-registry.cjs` files — a hit is a violation unless it's a deliberate, self-documented
  legacy-compat shim (e.g. `cmux-dispatch.sh`'s `--runtime codex` default, which exists for
  historical callers and says so in its own header comment).
- `agent-runtime.sh`, `dispatch-core.sh`, and `admission-recover.cjs` each need a follow-up
  fix to reach this shape (tracked as issues #168, #169, and this ADR for `agent-runtime.sh`).
