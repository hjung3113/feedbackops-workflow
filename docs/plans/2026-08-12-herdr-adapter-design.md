# Herdr transport adapter design

## Outcome

Add Herdr as a third explicit transport behind the existing transport adapter seam:

```text
agent-workflow.sh dispatch --orchestrator herdr ...
  -> dispatch-core.sh --adapter herdr ...
  -> adapters/herdr.sh capabilities|launch|inspect
```

This is feasible against the latest stable Herdr release, `v0.8.0`, without an upstream Herdr change. Herdr already exposes the required deterministic CLI operations and JSON identities:

- `workspace create --cwd ... --label ... --no-focus` creates an isolated surface and returns `.result.workspace.workspace_id` plus `.result.root_pane.pane_id`;
- `pane run <pane_id> <command>` atomically submits the common launch runner to that pane; and
- `workspace get <workspace_id>` checks the exact created surface without relying on a label or UI order.

The implementation target is Herdr `v0.8.0` (tag commit `346411fa21afd297f5ed3b3fa56f9e3fbf7654b7`). The current upstream `master` snapshot inspected for this design was `06ca0baa12f4203c5bbad9ecadf53f9a475a52b2`; no master-only capability is required.

Primary upstream evidence:

- [Herdr v0.8.0 release](https://github.com/herdrdev/herdr/releases/tag/v0.8.0)
- [v0.8.0 CLI reference](https://github.com/herdrdev/herdr/blob/v0.8.0/docs/preview/website/src/content/docs/cli-reference.mdx)
- [v0.8.0 workspace CLI contract tests](https://github.com/herdrdev/herdr/blob/v0.8.0/tests/cli/workspace.rs)
- [v0.8.0 workspace command parser](https://github.com/herdrdev/herdr/blob/v0.8.0/src/cli/workspace.rs)
- [v0.8.0 pane command parser](https://github.com/herdrdev/herdr/blob/v0.8.0/src/cli/pane.rs)

## Existing authority remains unchanged

| Existing module | Authority retained after this change |
| --- | --- |
| `agent-workflow.sh` | Explicit transport selection and precedence: CLI, environment, then product config. No automatic fallback. |
| `dispatch-core.sh` | Worktree realpath, runtime/role/model selection, admission, runner creation, receipt publication, liveness polling, and completion evidence. |
| Runtime adapters and watchdog | The exact agent executable and arguments. Herdr launches only the already-created common runner. |
| `transport_receipt` | Canonical transport provenance and the opaque external handle. |
| Herdr | Workspace, tab, pane, terminal, server/session, and UI lifecycle. The workflow does not recreate Herdr state or parse its TUI. |

The Herdr adapter is deliberately shallow in policy and deep in translation: callers learn no Herdr-specific workspace/pane sequence, JSON shape, session routing, error JSON, or lifecycle lookup. They continue to use the same three-command interface as cmux and Orca.

## Adapter interface

Add one Bash 3.2-compatible adapter:

```text
toolkit/scripts/adapters/herdr.sh

capabilities --worktree <absolute-path>
  -> {adapter, available, reason_code, version, capabilities[]}

launch --name <seat-name> --worktree <absolute-path>
       --runner-relative <.review/ISSUE-N-launch.X/launch.sh>
  -> {external_handle: <workspace-id>, lifecycle: "launched"}
  -> on ambiguous post-create failure, the same JSON shape with
     lifecycle: "command_unconfirmed" plus a non-zero exit

inspect --worktree <absolute-path> --external-handle <workspace-id>
  -> {lifecycle: "live"|"stale"|"handle_unverifiable", reason}
```

`external_handle` is the returned `workspace_id`, not the requested label, sidebar position, pane number, or terminal ID. A new workspace is the Herdr analogue of the fresh cmux workspace used by the current adapter. The root `pane_id` is an internal launch target and is never promoted to workflow identity.

### `capabilities`

The probe is read-only and runs before admission or runner creation. It must:

1. require `herdr` on `PATH`;
2. require `HERDR_ENV=1` and a non-empty `HERDR_SOCKET_PATH`, so the selected session is inherited from the invoking Herdr pane rather than guessed from another client or server;
3. parse `herdr --version` as semver and require `>=0.8.0`;
4. run `herdr workspace --help` and prove `workspace create` exposes `--cwd`, `--label`, and `--no-focus`, plus `workspace get` and `workspace close`;
5. run `herdr pane --help` and prove `pane run` exists; and
6. run `herdr workspace list`, requiring schema-shaped JSON from the selected live server.

The successful capability set is:

```json
[
  "session.inherited",
  "workspace.create.cwd",
  "workspace.create.label",
  "workspace.create.no_focus",
  "workspace.get.read_only",
  "workspace.close",
  "pane.run"
]
```

The recorded adapter version should include both the parsed Herdr version and the SHA-256 of the resolved binary, matching the stronger cmux provenance style. A missing session context returns `session_context_missing`; a missing server, bad version, missing command, non-zero help/list probe, or malformed list JSON returns `required_capability_missing`. The core retains its existing no-fallback behavior.

### `launch`

Launch is a bounded two-step translation:

1. Execute `herdr workspace create --cwd "$WORKTREE" --label "$NAME" --no-focus`.
2. Require `result.type === "workspace_created"`, non-empty `workspace.workspace_id` and `root_pane.pane_id`, and `root_pane.workspace_id === workspace.workspace_id`.
3. Execute `herdr pane run "$PANE_ID" "bash $RUNNER"`.
4. Treat exit 0 as success—Herdr `v0.8.0` deliberately emits no success JSON for `pane run`—then emit the adapter's own launch JSON with the created `workspace_id`.

The adapter must pass all values as argv, preserve the exact worktree path, and accept only the same short runner-relative pattern as the existing adapters. It must not create a Git worktree, start an agent directly with `herdr agent start`, choose a runtime/model, focus the UI, reuse a workspace, or depend on the caller's focused pane.

Herdr v0.8.0 has no single CLI operation that both creates a workspace and runs a command, so the launch cannot be transport-atomic. `pane run` writes schema-shaped server errors to stderr and returns exit 1; a successful command returns exit 0 with empty stdout. The adapter captures those channels and keeps stdout reserved for its one normalized result.

A schema-valid `pane_not_found`, `invalid_key`, or `pane_send_failed` response is a definite pre-delivery rejection: Herdr did not enqueue command bytes. The adapter may best-effort close only the workspace ID it just created, returns non-zero without a launch result, and the core publishes no receipt. Any other non-zero result—including an empty, multiple, malformed, server/protocol, or I/O error—is an ambiguous acknowledgement. The adapter must not close a possibly running seat; it emits `{external_handle:<created-workspace-id>, lifecycle:"command_unconfirmed"}` on stdout while preserving the non-zero exit. This detail is required because the existing core parses the external handle before examining the launch status. The valid handle lets it publish inspectable provenance and check fresh canonical RUN/BLOCKER evidence before classifying transport failure. On timeout it preserves the adapter's non-zero exit. A later retry may therefore leave an inert Herdr workspace; automatic orphan cleanup is deferred until Herdr exposes a provable launch transaction or the workflow has durable pre-receipt transport intent.

### `inspect`

Inspection calls `herdr workspace get "$HANDLE"` against the inherited session:

- exit 0 with `result.type === "workspace_info"` and `.result.workspace.workspace_id` exactly equal to the receipt handle is `live`;
- exit 1 with exactly one schema-shaped stderr JSON whose `error.code === "workspace_not_found"` is `stale`; and
- server failure, another error code, empty/multiple/malformed stderr, malformed success JSON, or an identity mismatch is `handle_unverifiable`.

Inspection is read-only. It does not infer completion from workspace existence, pane text, agent detection status, or a Herdr `idle`/`done` label. Canonical RUN, BLOCKER, REVIEW, and VERIFY evidence remain the only workflow authorities.

## Core and contract changes

Herdr must be added everywhere the current closed transport set is authoritative, not only to the adapter directory:

| Area | Required change |
| --- | --- |
| Public selection | Add `herdr` to `agent-workflow.sh` usage, adapter lookup, capability enumeration, config/env/CLI validation, and setup errors. |
| Dispatch core | Add `herdr` to adapter validation and usage. Keep generic dry-run output; do not add a Herdr-specific launch implementation to the core. |
| Admission routing | Add `herdr` to the validated transport allowlist in `lib/admission-recover.cjs`, so policy-routed transactions can bind the selected transport. |
| Receipt schema | Add `herdr` to `transport_receipt.schema.json`'s adapter enum and add a valid Herdr fixture. Existing cmux/Orca receipts remain valid and the version continues to describe the current runtime/routing feature family, so no schema-version bump is needed. This is not forward compatibility with an old reader: producer, schema, and reader must ship together in one toolkit installation. |
| Telemetry schema | Add `herdr` to `telemetry_sample.schema.json`'s transport enum and cover derivation from a Herdr receipt. |
| Installation | Ensure `scripts/adapters/herdr.sh` is copied, executable, and covered by source/install containment checks. |
| Operator and installed guidance | Update `toolkit/README.md`, both product playbook copies, workflow-config examples, `toolkit/.claude/skills/agent-workflow/SKILL.md`, its `references/adoption.md`, `toolkit/docs/agents/conductor-persona.md`, and `toolkit/STATUS.md` in the implementation commit. |

Do not add a Herdr compatibility facade analogous to `cmux-dispatch.sh`; that file is a legacy cmux entrypoint, not the transport interface. New callers use `agent-workflow.sh`.

## Verification design

Extend `orchestrator-interface.smoke.sh` with a fake `herdr` executable whose request ID, workspace ID, pane ID, and requested label are deliberately distinct. Tests must prove behavior through the public seam:

| Case | Required observation |
| --- | --- |
| capability probe outside Herdr | unavailable with `session_context_missing`; no admission marker, runner, receipt, or fallback adapter call |
| missing `workspace create` flag or `pane run` command | `required_capability_missing` before any side effect |
| unavailable/malformed `workspace list` server response | selected adapter fails closed before admission |
| successful dispatch | exact `--cwd`, label, `--no-focus`, root pane target, and `bash <short-runner>`; `pane run` exit 0 with empty stdout is accepted; receipt adapter is `herdr` and handle is the returned workspace ID |
| requested label differs from returned IDs | identity comes only from returned JSON, never the label |
| cross-wired or malformed create response | mismatched `root_pane.workspace_id` or another shape is rejected before `pane run`; no receipt |
| definite `pane run` rejection | fake writes one schema-valid error JSON to stderr and exits 1; only the just-created workspace is eligible for compensating close, stdout has no handle, core exits immediately, and no receipt is published |
| ambiguous run acknowledgement | fake emits empty, multiple, or malformed stderr and exits non-zero; adapter emits the created handle JSON on stdout without cleanup, core publishes a receipt, and fresh RUN/BLOCKER follows the existing freshness path; absent evidence, core returns the adapter status after timeout |
| exact handle present | inspect reports `live` |
| exact handle missing with same label elsewhere | inspect reports `stale` |
| other exit 1, empty/multiple/malformed stderr, or malformed success inspect response | inspect reports `handle_unverifiable` |
| capabilities command | three adapters are reported independently; probing Herdr never suppresses cmux or Orca results |
| routed receipt and telemetry | schemas accept `herdr`, route binding and derived telemetry transport agree, legacy cmux/Orca fixtures remain valid |
| installed closed-set audit | no installed skill, adoption guide, persona, playbook, or usage text still presents `cmux|orca` as the complete transport set |

After the focused smoke is green, run the affected transport, telemetry, installation, and release gates. A schema or documentation mismatch is a failed implementation, even if the adapter smoke passes.

## Explicit non-goals

- No upstream Herdr change, socket client, plugin, or TUI parsing.
- No operation from outside a Herdr-managed session and no guessing a default/focused Herdr session.
- No automatic transport selection or fallback among Herdr, cmux, and Orca.
- No Herdr-owned Git worktree creation/removal.
- No direct `herdr agent start`, agent naming, lifecycle-based completion, prompt sending, pane reading, or focus changes.
- No automatic cleanup after ambiguous launch acknowledgement.
- No changes to runtime, role, model allocation, admission ordinal, watchdog, or completion authority.

## Implementation slices

1. Add the fake Herdr CLI and failing public-seam tests for selection, capability proof, exact returned identity, launch ordering, and inspect classification.
2. Add `adapters/herdr.sh` and the minimal closed-set changes in `agent-workflow.sh` and `dispatch-core.sh` until the focused transport smoke is green.
3. Extend receipt, admission-routing, and telemetry transport enums plus fixtures and regression cases.
4. Add installation/release containment coverage, including a closed-set search over installed guidance, and update the operator documentation and STATUS in the same implementation commit.

The first implementation should stay in these slices. A future upstream atomic `workspace create --command` capability could deepen `launch` by replacing the two-step implementation without changing the adapter interface or any caller.
