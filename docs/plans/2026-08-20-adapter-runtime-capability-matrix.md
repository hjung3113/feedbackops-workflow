# Adapter × runtime capability matrix — #136

Status: **draft design doc, not implemented, not reviewed**. Closes #136's own
deliverable ("설계 산출물, 코드 검증 대상 아님"). Author: CONDUCTOR session, 2026-08-20.

## 0. Axes (established by `docs/plans/2026-08-15-feature-abstraction-two-axis-design.md`, confirmed here against current source)

- **Transport axis** — WHERE the worker process runs: `cmux` / `orca` / `herdr` /
  (proposed, unimplemented) `native`.
- **Runtime axis** — WHICH model publisher executes inside that transport:
  `codex` / `claude` / `opencode`. Model-family effort-enum variance
  (`gpt-5[.-]6` → extended enum, `runtime-registry.cjs:99-108`) is a
  sub-dimension of this axis, not a 4th independent axis.
- **Native transport's runtime column is constrained**, not axis-less: per the
  (unmerged, branch-only) native-dispatch design's §3 eligibility check, native
  dispatch is only eligible when runtime/model match the CONDUCTOR's own
  harness identity and role ∈ {implementation, reviewer}. Recorded as a
  constraint on that row below, not "no runtime axis."

All cell claims below were checked against current `main` (`fcc514e`) source —
`toolkit/scripts/adapters/{cmux,orca,herdr}.sh`, `toolkit/scripts/lib/runtime-registry.cjs`,
`toolkit/scripts/agent-watchdog.sh`, `toolkit/scripts/agent-runtime.sh` — not assumed.

## 1. Functional unit × transport

All three adapters expose the **identical 4-command surface**:
`capabilities` / `launch` / `inspect` / `preview` — confirmed by grep, no adapter
exposes more. This means transport-axis variance only actually exists for 2 of
the 6 functional units; the other 4 are deliberately generic across every
transport (this is #150's own finding — not an oversight to "fix").

| Functional unit | cmux | orca | herdr | native (draft, unimplemented) |
|---|---|---|---|---|
| **launch** | Native — `cmux workspace create --cwd --command` (`cmux.sh:60`) | Native — `orca terminal create --worktree --command --json` (`orca.sh:99`) | Native — `workspace create` + `pane run` (`herdr.sh` launch case) | Would skip adapter launch entirely — CONDUCTOR's own `Agent` tool call. Draft only. |
| **completion-signal/liveness (handle existence)** | Native — `cmux workspace list --json` → live/stale/handle_unverifiable (`cmux.sh:81-85`) | Native — `orca terminal list --json` → live/stale/handle_unverifiable (`orca.sh:112-116`) | Native — `workspace get` exact-match only; only *defined* failures (`pane_not_found`/`invalid_key`/`pane_send_failed`) close the workspace, everything else stays `handle_unverifiable` rather than guessing (`herdr.sh` inspect case) | N/A — no external handle; liveness is the CONDUCTOR's own turn state. |
| **terminal-read** | **Generic fallback** — no read command in any adapter's 4-command surface. Output is captured by redirecting the runner script's stdout to a file at launch time, read by the watchdog as a file, not through the adapter. | Same generic fallback. (Note: `orca terminal read` exists at the *platform* CLI level, but is deliberately **not** wired into this axis — #150 confirmed it — because it wouldn't generalize to cmux/herdr and this layer is transport-neutral by design.) | Same generic fallback. | Would be direct in-process text (no file capture needed at all) — draft only. |
| **blocking-wait** | **Generic fallback** — RUN.json polling, hardened per `feedback_no_hand_rolled_polling` memory (background + notification, not a hand-rolled sleep loop). | Same generic fallback. (Note: `orca orchestration check --wait` exists but requires the orca-only `worker_done` message protocol — #150 confirmed `agent-workflow.sh dispatch` deliberately does **not** bind to it, since the same dispatch path must work identically under cmux/herdr too. This is a considered-and-rejected native option, not a gap.) | Same generic fallback. | Would be a direct awaited call return — no polling at all — draft only. |
| **artifact-retrieval** | **Generic, already transport-neutral** — reads `.review/*.json` disk artifacts directly, no adapter involvement. (#132, not in this session's scope, tracks a real duplication: 2 separate assembly code paths for the same disk-truth read — worth folding into this row's canonical shape when #132 is picked up, not before.) | Same. | Same. | Same — artifacts are already disk-truth regardless of how the worker was launched. |
| **teardown** | **No native close/remove command** — cmux adapter's 4-command surface has nothing to close a workspace. Teardown today is manual/generic: `git worktree remove --force` at the git layer (this session's own workflow), not adapter-mediated. | **No native close/remove command** either — same generic git-worktree-removal fallback. | **Partially native** — `herdr.sh` calls `workspace close` (`herdr.sh:246`), but only as *launch-failure* cleanup for defined failure codes, not as a general post-completion teardown hook. Normal post-completion teardown still falls back to the same generic git-worktree-removal path as cmux/orca. | Draft only — no worktree/process to tear down if it never left the CONDUCTOR's own turn. |

## 2. Functional unit × runtime

| Functional unit | codex | claude | opencode |
|---|---|---|---|
| **launch (exec argv)** | Native, registry-driven — `runtime-registry.cjs` `BIN.codex`/`PROBE.codex` (`exec --sandbox --cd --model --config --output-last-message [--json]`). | Native, registry-driven — `PROBE.claude` (`--print --permission-mode --output-format --model --effort --include-partial-messages`). | Native, registry-driven — `PROBE.opencode` (`run --dir --format --agent --model --variant`). |
| **completion-signal/liveness (progress events)** | **Generic fallback still** — `PROGRESS.codex.streams = false` (`runtime-registry.cjs:83`). Watchdog uses output-file mtime polling (`progressed()`, `agent-watchdog.sh:27`), not event parsing. `--json` flag/final-match shape is already declared in the registry but **not yet wired into launch argv** — this is #155's remaining open scope (blocked on quota until 2026-08-20 19:12 UTC). | **Native** — `PROGRESS.claude.streams = true`, NDJSON on stdout, `final.match` on `type=result,subtype=success` (`runtime-registry.cjs:72-77`). | **Native since #155 (2026-08-19)** — `PROGRESS.opencode.streams = true`, NDJSON, `final.match` on `type=text` (`runtime-registry.cjs:86-91`). |
| **completion-signal/liveness (stash-on-stall policy)** | **Native, self-owned** — `STASH_BY.codex = "runtime"`: `codex-safe.sh` stashes partial work itself; watchdog skips (`agent-watchdog.sh:131-159`, registry-driven, no hardcoded branch — this is what closed #133). | `STASH_BY.claude = "watchdog"` — generic watchdog-owned stash via `workflow-stash.sh`. | `STASH_BY.opencode = "watchdog"` — same generic watchdog-owned path as claude. |
| **terminal-read / blocking-wait / artifact-retrieval / teardown** | Runtime-neutral — same generic mechanisms as §1, no runtime-specific variance found in any of the 4 call sites checked (`agent-watchdog.sh`, `agent-runtime.sh`, `dispatch-core.sh`, adapters). | Same. | Same. |

## 3. What this confirms, and what's left

- **#133's entire premise is already closed** (see issue comment, 2026-08-20):
  every runtime-axis leak it named (probe/argv double-encoding, codex-specific
  stash branch, 3x hardcoded runtime lists) is now table-driven through
  `runtime-registry.cjs`, landed via #135 before #133 was even picked up. The
  "completion-signal/liveness row" this doc's own predecessor flagged as
  #133's remaining scope is therefore **already implemented**, not a future
  matrix-row task.
- **The only real open row-implementation gap left is #155's codex half**
  (flip `PROGRESS.codex.streams` to `true`, wire `--json` into both
  `agent-runtime.sh`'s codex branch and `codex-safe.sh`'s independent argv
  build) — already tracked, already blocked on quota, not new scope from this
  matrix.
- **#132 (artifact-retrieval dedup)** remains the one matrix-informed
  implementation still outstanding, and per this issue's own "하지 않는 것"
  instruction, is explicitly **not** implemented here — future pickup only.
- **No teardown gap was previously named by any filed issue** — cmux/orca lack
  any native close/remove command; herdr's is launch-failure-only. This matrix
  surfaces it as a fact, not a recommendation to build one (out of scope for
  #136, which is design-doc-only).
- Native transport row stays entirely draft/unimplemented — the underlying
  design doc it depends on (`docs/plans/2026-08-15-conductor-native-subagent-dispatch-design.md`)
  only exists on the unmerged branch `docs/conductor-native-subagent-dispatch-design`
  (commit `a21d2cd`), not on `main`. Any future §3-informed revision of that
  design doc (per #136's original "개선방향 §4") should happen only if/when
  that branch is actually picked back up — not assumed here.

## 4. Verification

Design doc only, no code changed. The matrix's claims are falsifiable the
next time any of these rows gets implemented (#132, #155 codex half): if the
real implementation's native/fallback choice doesn't match what's recorded
here, this doc is wrong and needs correcting, not the implementation.
