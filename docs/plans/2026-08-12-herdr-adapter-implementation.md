# Herdr transport adapter implementation plan

Status: Final after Opus 5 adversarial review on 2026-08-13.

## Outcome

Ship Herdr `v0.8.0+` as the third explicit transport behind the existing
`capabilities | launch | inspect` adapter interface. The public path remains:

```text
agent-workflow.sh dispatch --orchestrator herdr ...
  -> dispatch-core.sh --adapter herdr ...
  -> scripts/adapters/herdr.sh capabilities|launch|inspect
```

The change is complete only when the public smoke tests, transport contracts,
installed output, and release gate all agree that `cmux`, `orca`, and `herdr`
are the supported closed set. The accepted design in
`docs/plans/2026-08-12-herdr-adapter-design.md` remains the behavioral authority.

## Starting state and constraints

- Work on branch `docs/herdr-adapter-design` from
  `19ec1e4b776cc43885803ff363b508e260166b41`, currently equal to
  `origin/main`.
- Preserve all unrelated untracked paths listed in the root `HANDOFF.md`,
  including the handoff itself and the accepted Herdr design.
- Do not create an issue or PR, commit, push, or run a live Herdr launch without
  fresh authorization.
- Keep every shell change compatible with macOS Bash 3.2.
- Do not add another dispatch path, compatibility facade, socket client,
  direct `herdr agent start`, automatic fallback, or completion inference from
  workspace state.

## Adversarial review decisions

An independent Opus 5 review returned `REVISE`. This plan incorporates the
findings that are observable at the existing public seam: adapter exit
contracts, per-case session environment, three-row capability reporting,
stateful fake wiring, root-pane cwd verification, create/run partial failures,
bounded cleanup evidence, telemetry parameterization, and installed-output
assertions.

One proposed requirement was rejected: proving a separate "plain shell pane
kind" from the create response. Herdr `v0.8.0` creates a fresh shell runtime for
`workspace create`; it does not reuse or create an agent pane, and its public
`PaneInfo` has no pane-kind field. Inventing one would require an upstream or
adapter-interface change. The returned `root_pane.cwd` does exist, so validating
that field against the requested worktree is retained as a concrete guard.

## Slice 1: establish RED at the public transport seam

Primary file:

- `toolkit/scripts/__tests__/orchestrator-interface.smoke.sh`

Add one stateful fake `herdr` executable. Its requested label, request ID,
returned workspace ID, returned root-pane workspace ID, pane ID, and root-pane
cwd must be independently configurable and distinct where applicable. Persist
the workspace-to-cwd and pane-to-workspace mappings so the `pane run` branch,
not the create branch, writes a fresh RUN fixture. Record create/run/close argv
and seed a decoy workspace so tests can prove ordering, exact cleanup scope,
and absence of fallback.

Keep environment and mode explicit per case:

- selection precedence uses `--dry-run`, which deliberately skips capabilities;
- capability/launch/inspect cases set `HERDR_ENV=1` and a non-empty
  `HERDR_SOCKET_PATH` on that invocation; and
- session-refusal cases explicitly unset both variables, plus one case with
  `HERDR_ENV=1` and an empty socket path.

Add failing cases for:

1. explicit CLI/environment/config selection of `herdr` under `--dry-run`;
   rewrite the existing two-adapter capability assertion to key three rows by
   adapter name, proving Herdr availability or refusal independently without
   changing the cmux/Orca rows;
2. refusal outside a Herdr session with `session_context_missing`, before
   admission marker, launch directory, receipt, workspace creation, or another
   adapter; assert the literal reason rather than only the exit code;
3. numeric semver behavior: reject `0.7.9`, `0.8.0-rc.1`, empty, and garbage;
   accept `0.8.0`, `v0.8.0`, `0.10.0`, and `0.9.0-rc.1`; also reject a missing
   required workspace/pane help surface and non-zero or malformed `workspace
   list`, all as literal `required_capability_missing` before side effects;
4. successful dispatch using exact `--cwd`, label, and `--no-focus`, followed
   by `pane run <returned-pane-id> "bash <short-runner>"`; empty stdout with
   exit 0 must cause the stateful fake to write fresh RUN evidence and publish
   a receipt whose adapter is `herdr` and whose handle is the returned
   workspace ID;
5. create non-zero/timeout, malformed create output, wrong `result.type`,
   missing IDs, cross-wired `root_pane.workspace_id`, and a root-pane cwd that
   does not resolve to the requested worktree; all are rejected before `pane
   run` and without close or receipt;
6. one schema-valid `pane_not_found`, `invalid_key`, or `pane_send_failed`
   stderr object: the close log contains exactly the newly created workspace
   ID and not the decoy, no handle is emitted, and no receipt is published;
   close failure or noisy close stdout cannot replace the original run status
   or contaminate adapter stdout;
7. empty, multiple, malformed, or other non-zero post-create errors: no close,
   the created handle is retained, a receipt is published, and the existing
   `adapter launch returned ...` diagnostic plus fresh RUN/BLOCKER path decides
   the result; fresh evidence may make the core return 0, while absent evidence
   returns the original adapter status after a short timeout;
8. exact-ID inspect success as `live`, exact `workspace_not_found` as `stale`
   even when the label exists elsewhere, and every malformed, mismatched, or
   other error as `handle_unverifiable`; assert distinct reason strings and the
   adapter-normalized exit 0 for all three lifecycle results.

RED is established only when the new assertions fail for missing Herdr support
while the existing cmux and Orca cases remain green.

## Slice 2: implement the adapter and minimal closed-set wiring

Implementation files:

- `toolkit/scripts/adapters/herdr.sh` (new, executable)
- `toolkit/scripts/agent-workflow.sh`
- `toolkit/scripts/dispatch-core.sh`

Implement `herdr.sh` as the sole owner of Herdr-specific JSON and lifecycle
translation:

- `capabilities` verifies the binary, inherited session variables, semver
  floor, required help commands/flags, and schema-shaped `workspace list`. Its
  version string includes the parsed version and resolved-binary SHA-256. It
  always emits exactly one JSON object and exits 0, including unavailable
  results, so the core can preserve `session_context_missing` versus
  `required_capability_missing`. Compare numeric semver components and apply
  normal prerelease ordering at the `0.8.0` floor; never compare version text
  lexicographically.
- `launch` validates the existing short runner-relative pattern, creates one
  non-focused workspace, proves workspace/root-pane coherence, realpath-compares
  returned `root_pane.cwd` with the requested worktree, and runs the common
  runner in the returned pane. Capture run stdout, stderr, and status separately
  in adapter-owned temporary files; JSON-parse the complete stderr bytes so
  empty, concatenated, or trailing non-whitespace data cannot look like one
  server error. Normalize empty-stdout success, preserve the original non-zero
  run status across best-effort cleanup, suppress cleanup output, distinguish
  definite rejection from ambiguous acknowledgement, and never treat a label
  as identity.
- `inspect` uses only `workspace get <external_handle>` and maps exact success,
  exact not-found stderr, and every unverifiable result to the shared lifecycle
  vocabulary. It always emits exactly one normalized lifecycle JSON object and
  exits 0; upstream `workspace get` exit 1 must not escape and collapse `stale`
  into the CLI's generic `handle_unverifiable` fallback.

Limit core edits to closed-set membership, usage/setup text, adapter lookup,
and capability enumeration. Preserve the existing core ordering that parses a
valid launch handle before checking the adapter exit status; do not add Herdr
branches to runner creation, admission, receipt publication, polling, runtime,
watchdog, or completion logic.

GREEN checkpoint:

```bash
NODE_OPTIONS= bash toolkit/scripts/__tests__/orchestrator-interface.smoke.sh
bash -n toolkit/scripts/adapters/herdr.sh \
  toolkit/scripts/agent-workflow.sh \
  toolkit/scripts/dispatch-core.sh
```

## Slice 3: extend durable transport contracts

Contract files:

- `toolkit/schemas/transport_receipt.schema.json`
- `toolkit/schemas/telemetry_sample.schema.json`
- `toolkit/scripts/lib/admission-recover.cjs`
- Herdr receipt/telemetry fixtures under `toolkit/schemas/fixtures/`

Regression files:

- `toolkit/scripts/__tests__/runtime-provenance-schema.smoke.sh`
- `toolkit/scripts/__tests__/admission-recover.smoke.sh`
- `toolkit/scripts/__tests__/telemetry.smoke.sh`

Add `herdr` to the three authoritative allowlists without changing schema
versions. Add a valid Herdr receipt fixture with a workspace ID handle. Change
the routed-telemetry fixture helper to accept one transport parameter and apply
it to both the admission binding and receipt; use it to prove that route
binding and derived transport both remain `herdr`. Keep the existing cmux/Orca
fixture checks and unknown-transport rejection rather than duplicating them.

Checkpoint:

```bash
NODE_OPTIONS= bash toolkit/scripts/__tests__/runtime-provenance-schema.smoke.sh
NODE_OPTIONS= bash toolkit/scripts/__tests__/admission-recover.smoke.sh
NODE_OPTIONS= bash toolkit/scripts/__tests__/telemetry.smoke.sh
```

## Slice 4: synchronize installation and operator guidance

Installation/release files:

- `toolkit/scripts/__tests__/install-into.smoke.sh`
- `.github/tests/release-contract.smoke.sh`

Require the source and installed `scripts/adapters/herdr.sh` to exist and be
executable. Use bounded assertions over the named shipped guidance files:
require `herdr` where each file enumerates transports and reject only literal
exhaustive forms such as `cmux|orca` or `cmux or Orca`. Do not use an open-ended
grep that would reject legitimate single-transport examples or the retained
legacy `cmux-dispatch.sh` facade.

Update the operator-facing closed set in:

- `toolkit/README.md`
- `toolkit/docs/agents/multi-agent-workflow.md`
- `toolkit/scripts/install-profiles/generic/docs/agents/multi-agent-workflow.md`
- `toolkit/.claude/skills/agent-workflow/SKILL.md`
- `toolkit/.claude/skills/agent-workflow/references/adoption.md`
- `toolkit/docs/agents/conductor-persona.md`
- `toolkit/STATUS.md`

First verify and then leave unchanged the two `workflow-config.example.json`
files and `toolkit/scripts/install-profiles/generic/skill/SKILL.md`: they contain
example values or generic wording, not an exhaustive transport set.

Describe explicit selection, inherited Herdr-session requirements, no fallback,
workspace-ID provenance, and the fact that workspace liveness is not workflow
completion. State that a receipt records launch intent/provenance, not confirmed
command delivery. Do not copy adapter implementation details into every guide;
the shipped product playbook is the single detailed operator reference. Shipped
toolkit files must not link to the repository-only `docs/plans/` design.

Checkpoint:

```bash
NODE_OPTIONS= bash toolkit/scripts/__tests__/install-into.smoke.sh
NODE_OPTIONS= bash .github/tests/release-contract.smoke.sh
```

## Final verification order

Run gates once the four slices are green, in this order:

```bash
NODE_OPTIONS= bash toolkit/scripts/__tests__/orchestrator-interface.smoke.sh
NODE_OPTIONS= bash toolkit/scripts/__tests__/runtime-provenance-schema.smoke.sh
NODE_OPTIONS= bash toolkit/scripts/__tests__/admission-recover.smoke.sh
NODE_OPTIONS= bash toolkit/scripts/__tests__/telemetry.smoke.sh
NODE_OPTIONS= bash toolkit/scripts/__tests__/install-into.smoke.sh
NODE_OPTIONS= bash .github/tests/release-contract.smoke.sh
bash -n toolkit/scripts/adapters/herdr.sh \
  toolkit/scripts/agent-workflow.sh \
  toolkit/scripts/dispatch-core.sh
git diff --check
```

Then run the complete offline suite if the focused gates are green:

```bash
NODE_OPTIONS= bash toolkit/scripts/__tests__/run-all.sh
```

A red focused, installation, release, syntax, diff, or full-suite gate means
the adapter is not complete. A manual live launch/inspect check is a separate
final validation: run it only from a Herdr-managed pane with `HERDR_ENV=1` and
`HERDR_SOCKET_PATH` present, and do not weaken the capability gate when that
environment is unavailable.

## Definition of done

- Herdr selection is explicit, fail-closed, and never falls back.
- No admission, runner, receipt, or transport side effect occurs after a failed
  capability probe.
- Capability and inspect refusals remain typed JSON results with adapter exit 0,
  so the public core preserves their literal reason and lifecycle class.
- Launch identity comes only from coherent returned workspace/root-pane JSON,
  and the returned root-pane cwd resolves to the requested worktree.
- Empty-stdout `pane run` success, definite rejection cleanup, and ambiguous
  acknowledgement provenance all behave as designed through the public seam.
- Inspect returns only the three shared lifecycle classifications and never
  treats existence as completion authority.
- Receipt, routing, telemetry, source installation, portable installation, and
  all shipped guidance agree on the three-adapter closed set.
- Existing cmux and Orca behavior remains covered and green.
- No unrelated protected file is modified, and no commit, push, issue, PR, or
  live Herdr action occurs without authorization.
