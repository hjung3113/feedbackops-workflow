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

**Evidence provenance.** Every cell in the `cmux`/`orca`/`herdr`/`codex`/`claude`/
`opencode` columns of §1-§2 was checked against current `main` (`fcc514e`)
source at that commit — reproduce with:
`git show fcc514e:toolkit/scripts/adapters/cmux.sh`,
`...adapters/orca.sh`, `...adapters/herdr.sh`, `...lib/runtime-registry.cjs`,
`...agent-watchdog.sh`, `...agent-runtime.sh`, plus
`grep -n "close\|remove\|teardown\|cleanup" toolkit/scripts/adapters/*.sh` for
the teardown row. The `native` column in every table is **not** verified
against `main` — it does not exist on `main`. Its only source is the
unmerged, draft-status branch `docs/conductor-native-subagent-dispatch-design`
(commit `a21d2cd`), and every native-column cell is prefixed "draft" or "N/A"
below for that reason — treat that column as proposed/future-state, not
current-state, throughout.

## 1. Functional unit × transport

**Scope of this section's headline claim, stated precisely**: among the 3
**currently implemented, external, current-`main`** transports (cmux, orca,
herdr), transport-axis variance exists in only 2 of 6 functional units for the
normal (non-launch-failure) path. This is narrower than "2 of 6 vary,
period" — the draft `native` column (not on `main`) shows different behavior
in 4 of 6 rows precisely because it is a different mechanism (no external
process, no adapter) by construction, and herdr's teardown row is **partially**
native (launch-failure cleanup only, detailed in that cell) rather than fully
generic. Both of those are surfaced explicitly in their own table cells below,
not hidden in the summary.

All three implemented adapters expose the **identical 4-command surface**:
`capabilities` / `launch` / `inspect` / `preview` — confirmed by grep, no
implemented adapter exposes more. This is why transport-axis variance among
them only actually exists for 2 of the 6 functional units; the other 4 are
deliberately generic across every implemented transport (this is #150's own
finding — not an oversight to "fix").

| Functional unit | cmux | orca | herdr | native (draft, unimplemented) |
|---|---|---|---|---|
| **launch** | Native — `cmux workspace create --cwd --command` (`cmux.sh:60`) | Native — `orca terminal create --worktree --command --json` (`orca.sh:99`) | Native — `workspace create` + `pane run` (`herdr.sh` launch case) | Would skip adapter launch entirely — CONDUCTOR's own `Agent` tool call. Draft only. |
| **completion-signal/liveness (handle existence)** | Native — `cmux workspace list --json` → live/stale/handle_unverifiable (`cmux.sh:81-85`) | Native — `orca terminal list --json` → live/stale/handle_unverifiable (`orca.sh:112-116`) | Native — `workspace get` exact-match only; only *defined* failures (`pane_not_found`/`invalid_key`/`pane_send_failed`) close the workspace, everything else stays `handle_unverifiable` rather than guessing (`herdr.sh` inspect case) | N/A — no external handle; liveness is the CONDUCTOR's own turn state. |
| **terminal-read** | **Generic fallback** — no read command in any adapter's 4-command surface. Output is captured by redirecting the runner script's stdout to a file at launch time, read by the watchdog as a file, not through the adapter. | Same generic fallback. (Note: `orca terminal read` exists at the *platform* CLI level, but is deliberately **not** wired into this axis — #150 confirmed it — because it wouldn't generalize to cmux/herdr and this layer is transport-neutral by design.) | Same generic fallback. | Would be direct in-process text (no file capture needed at all) — draft only. |
| **blocking-wait** | **Generic fallback** — RUN.json polling, hardened against hand-rolled sleep loops (background job + completion notification instead). | Same generic fallback. (Note: `orca orchestration check --wait` exists but requires the orca-only `worker_done` message protocol — #150 confirmed `agent-workflow.sh dispatch` deliberately does **not** bind to it, since the same dispatch path must work identically under cmux/herdr too. This is a considered-and-rejected native option, not a gap.) | Same generic fallback. | Would be a direct awaited call return — no polling at all — draft only. |
| **artifact-retrieval** | **Generic, already transport-neutral** — reads `.review/*.json` disk artifacts directly, no adapter involvement. (#132, not in this session's scope, tracks a real duplication: 2 separate assembly code paths for the same disk-truth read — worth folding into this row's canonical shape when #132 is picked up, not before.) | Same. | Same. | Same — artifacts are already disk-truth regardless of how the worker was launched. |
| **teardown** | **No native close/remove command** — cmux adapter's 4-command surface has nothing to close a workspace. Teardown today is manual/generic: `git worktree remove --force` at the git layer (this session's own workflow), not adapter-mediated. | **No native close/remove command** either — same generic git-worktree-removal fallback. | **Partially native** — `herdr.sh` calls `workspace close` (`herdr.sh:246`), but only as *launch-failure* cleanup for defined failure codes, not as a general post-completion teardown hook. Normal post-completion teardown still falls back to the same generic git-worktree-removal path as cmux/orca. | Draft only — no worktree/process to tear down if it never left the CONDUCTOR's own turn. |

## 2. Functional unit × runtime

| Functional unit | codex | claude | opencode |
|---|---|---|---|
| **launch (exec argv)** | Native, registry-driven, **but `--json` is declared-only, not effective**: `PROBE.codex.subcommand_help_tokens` lists `--json` as a *capability the binary supports* (`runtime-registry.cjs:46`), but the actual argv `agent-runtime.sh` emits at launch (`agent-runtime.sh:127`, `exec --sandbox read-only --cd …`) does not include it — confirmed by direct read, not inferred from the probe table. See the next row: `PROGRESS.codex.streams = false` is the authoritative "is this wired" signal, not the probe declaration above. | Native, registry-driven and effective — `PROBE.claude` (`--print --permission-mode --output-format --model --effort --include-partial-messages`), and `agent-runtime.sh`'s claude launch branch actually emits `progress-flags` from the same registry (`agent-runtime.sh:136-139`). | Native, registry-driven and effective — `PROBE.opencode` (`run --dir --format --agent --model --variant`), and `agent-runtime.sh`'s opencode launch branch emits `--format json` since #155 (`agent-runtime.sh:147`). |
| **completion-signal/liveness (progress events)** | **Generic fallback still** — `PROGRESS.codex.streams = false` (`runtime-registry.cjs:83`). Watchdog uses output-file mtime polling (`progressed()`, `agent-watchdog.sh:27`), not event parsing. `--json` flag/final-match shape is already declared in the registry but **not yet wired into launch argv** — this is #155's remaining open scope (blocked on codex quota; see #155 for the current reset time, not repeated here since it's transient). | **Native** — `PROGRESS.claude.streams = true`, NDJSON on stdout, `final.match` on `type=result,subtype=success` (`runtime-registry.cjs:72-77`). | **Native since #155 (2026-08-19)** — `PROGRESS.opencode.streams = true`, NDJSON, `final.match` on `type=text` (`runtime-registry.cjs:86-91`). |
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
- Two different kinds of "open" remain, named explicitly so they aren't
  conflated: a **capability gap** (a cell's native mechanism exists but isn't
  wired into the live path yet) versus a **dedup/refactor** (the mechanism
  works today but has duplicate implementations worth consolidating).
  - **Capability gap: #155's codex half** — `PROGRESS.codex.streams` is
    `false` and codex's launch argv doesn't emit `--json` yet (§2 row 2, and
    the launch-row correction above). Flip `PROGRESS.codex.streams` to `true`,
    wire `--json` into both `agent-runtime.sh`'s codex branch and
    `codex-safe.sh`'s independent argv build — already tracked, already
    blocked on quota, not new scope from this matrix.
  - **Dedup/refactor: #132's artifact-retrieval row** — the mechanism already
    works (disk-truth `.review/*.json` reads, transport-and-runtime-neutral),
    but has 2 duplicate assembly code paths worth folding into one canonical
    shape. Per this issue's own "하지 않는 것" instruction, explicitly **not**
    implemented here — future pickup only.
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
