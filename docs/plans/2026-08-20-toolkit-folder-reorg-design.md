# toolkit/scripts folder reorg by adapter × runtime axis — #198

Status: **design deliverable, not implemented**. No file under `toolkit/scripts/`
is moved, renamed, or edited by this issue. Author: ARCHITECT seat, 2026-08-20.
Input authority: `docs/plans/2026-08-20-adapter-runtime-capability-matrix.md`
(the #136 matrix, merged to `main` via #199 before this document's own PR
#200 — this document has a hard dependency on that content existing on
`main`, not an independent one) and
`docs/adr/0006-adapters-are-one-file-per-axis-member.md` (accepted). All file
paths and line ranges below were read against the current worktree (base
`fcc514e`), not assumed.

## 1. What "reorganize by adapter × runtime axis" actually means here

The matrix's central finding constrains this whole design: of the 6 functional
units, only **launch** and **completion-signal/liveness** vary per axis. The
other 4 — terminal-read (file-capture at launch, read by the watchdog),
blocking-wait (RUN.json/EVENTS.jsonl polling), artifact-retrieval (`.review/`
disk reads), teardown (generic `git worktree remove`; herdr's `workspace close`
at `herdr.sh:246` is launch-failure cleanup only) — are the **same code path**
whichever adapter/runtime launched the worker. A literal "N adapters × M
runtimes subfolder" reorg would split those shared paths 3–4 ways for zero
variance to enclose. That is explicitly prohibited (ROUND-STATE prohibition 5)
and explicitly rejected here.

The reorg that matches reality is the completion of the axis architecture that
`ADR 0006` already accepted:

- **Transport axis is already correctly foldered.** One file per member under
  `adapters/` (`cmux.sh` 101 lines, `orca.sh` 132, `herdr.sh` 366), all sharing
  `lib/adapter-helpers.sh` + `lib/adapter-json.cjs` + `lib/semver.cjs`, all
  exposing the identical 4-command surface. Nothing to do.
- **Runtime axis is NOT foldered yet.** ADR 0006 §Decision: "`agent-runtime.sh`'s
  inline codex/claude/opencode branches are to be split into per-runtime files
  (mirroring `adapters/<transport>.sh`)". That split has never landed.
  `agent-runtime.sh:113-148` is one `case "$RUNTIME"` block; `codex-safe.sh`
  (the codex member's write-mode wrapper) sits at the scripts root;
  `runtime-permissions/opencode-*.json` (opencode-member data) sits in its own
  root-level folder.
- **The axis-mixed core files stay shared and stay put.** `dispatch-core.sh`
  (1,447 lines) and `agent-watchdog.sh` (246 lines) are axis-neutral
  orchestration with exactly **two** remaining inline runtime branches in
  `dispatch-core.sh` (§5.3) and **zero** in `agent-watchdog.sh` (its
  completion-signal parsing `transcribe_review`, `agent-watchdog.sh:34-73`,
  already reads the `PROGRESS` table from `lib/runtime-registry.cjs:71-93`;
  stash ownership is the `stash-by` registry lookup at `agent-watchdog.sh:131`).
  Splitting either file by adapter/runtime would duplicate the shared
  orchestration the matrix confirmed as shared.

So the design is: **add the missing `runtimes/` member folder (the ADR 0006
split), move the two misplaced runtime-member assets into it, extract the two
inline runtime branches in `dispatch-core.sh` into registry/member delegation,
and colocate the one per-adapter helper currently stranded in `lib/`.**
Everything else — the 20+ axis-neutral operator scripts at the root, the shared
`lib/`, `adapters/` — is already in the right place and does not move.

### Considered and rejected: a `core/` folder for the root scripts

Moving the axis-neutral root scripts (`dispatch-core.sh`, `agent-watchdog.sh`,
`redispatch-check.sh`, `route.sh`, …) into `core/` was considered and rejected:

- It relocates files whose current location already *is* the axis-neutral
  shared home. The root/lib/adapters split is the existing axis architecture;
  only the runtime member folder is missing from it.
- The churn is large and buys no axis alignment: ~42 smoke files under
  `__tests__/` reference `../<script>` paths (§7 has counts), the repository
  release gate hardcodes ~21 of these paths
  (`.github/tests/release-contract.smoke.sh:112-141,191,476,510-512`), and
  `smoke-coverage.manifest` maps every script path to its covering test.
- YAGNI per `AGENTS.md`: no current requirement or demonstrated failure is
  answered by the extra folder.

## 2. Target directory tree for `toolkit/scripts/` (AC-198-1)

```
toolkit/scripts/
├── agent-workflow.sh              # STAYS — public transport-neutral CLI entry
├── cmux-dispatch.sh               # STAYS — documented legacy facade (ADR 0006
│                                  #   reviewer-check exemption, cmux-dispatch.sh:2-4)
├── dispatch-core.sh               # STAYS — axis-neutral dispatch core; two inline
│                                  #   runtime branches extracted (§5.3)
├── agent-watchdog.sh              # STAYS — axis-neutral watchdog (already registry-driven)
├── agent-runtime.sh               # STAYS — runtime-axis boundary/router; per-runtime
│                                  #   `run`/`permission-file` bodies move out (§5.1)
├── redispatch-check.sh            # STAYS — axis-neutral admission gate
├── route.sh / model-alloc.sh / output-contract.sh / prompt-ac-check.sh
├── review-capsule.sh / round-state-init.sh / round-state-render-ac.sh
├── completion-check.sh / artifact-fresh.sh / candidate-close.sh
├── candidate-integrate.sh / rebase-inflight.sh / review-archive.sh
├── conductor-control-publish.sh / conductor-rebuild.sh / ac-check.sh
├── target-verify.sh / telemetry.sh / workflow-stash.sh / install-into.sh
│                                  # ALL STAY — axis-neutral operators; the scripts
│                                  #   root IS the shared/core location for shell
│                                  #   orchestration (terminal-read, blocking-wait,
│                                  #   artifact-retrieval, teardown logic lives here
│                                  #   and in lib/ — deliberately NOT per-axis)
├── adapters/                      # UNCHANGED axis membership (still cmux/orca/herdr,
│                                  #   no 4th real member) — gains one colocated file
│   ├── cmux.sh                    #   (edit only: cmux-handles.cjs path, §5.4)
│   ├── orca.sh
│   ├── herdr.sh
│   └── cmux-handles.cjs           # MOVE HERE from lib/ — cmux-only handle
│                                  #   normalizer (sole consumer: adapters/cmux.sh:6,65,85)
├── runtimes/                      # NEW — runtime axis members (the ADR 0006 split)
│   ├── codex.sh                   # SPLIT from agent-runtime.sh:114-127 (§5.1)
│   ├── codex-safe.sh              # MOVE from scripts root — codex write-mode wrapper
│   ├── claude.sh                  # SPLIT from agent-runtime.sh:128-140
│   ├── opencode.sh                # SPLIT from agent-runtime.sh:60-79 + 90-105 + 141-148
│   ├── opencode-read.json         # MOVE from runtime-permissions/ (folder dissolves)
│   └── opencode-write.json        # MOVE from runtime-permissions/
├── lib/                           # STAYS — shared axis-neutral libraries + the two
│   │                              #   axis REGISTRIES (axis *data*, consumed by core,
│   │                              #   both axes' files, route/model-alloc/validators —
│   │                              #   shared location is correct; do NOT move them into
│   │                              #   runtimes/ or adapters/)
│   ├── runtime-registry.cjs       #   + new EFFORT_DEFAULT table (§5.3, absorbs
│   │                              #     dispatch-core.sh:714-719)
│   ├── transport-registry.cjs
│   ├── adapter-helpers.sh / adapter-json.cjs / semver.cjs   # cross-adapter shared
│   └── (all other .cjs/.mjs — axis-neutral, unchanged)
├── install-profiles/generic/      # UNCHANGED — contains NO scripts (docs/, opencode/,
│                                  #   skill/ only); see §8
└── __tests__/                     # STAYS FLAT — run-all.sh:10 discovers at maxdepth 1;
                                   #   ~14 test files need path updates (§7)
```

`runtime-permissions/` disappears as a top-level folder (its two opencode-only
members move into `runtimes/`). No other folder is created or removed.

## 3. File-by-file disposition table (AC-198-1)

Every file currently under `toolkit/scripts/` except `__tests__/` (covered in
§7). "Stay" means no move and no edit unless a §5 boundary names lines.

### 3.1 Root-level scripts (27 files)

| Current path | Disposition | Axis classification / evidence |
|---|---|---|
| `agent-workflow.sh` | **Stay (no edit)** | Public entry. Registry-driven adapter/runtime loops (`agent-workflow.sh:14-44`), delegates to `adapters/$x.sh` via `adapter_script()` (:52-55) and `dispatch-core.sh` (:8, :235). Referenced by install marker `install-into.sh:282` and release gate `:112`. |
| `cmux-dispatch.sh` | **Stay (no edit)** | 15-line legacy facade pinning `--adapter cmux --runtime codex` (`cmux-dispatch.sh:15`); ADR 0006 explicitly exempts it. Release gate executes it (`release-contract.smoke.sh:510-512`). |
| `dispatch-core.sh` | **Stay + 2 extractions** | Axis-neutral core. Inline axis branches to extract: `:714-719` (effort default) and `:775-782` (model-probe argv) — see §5.3. Everything else already delegates: adapter selection `:803`, adapter launch `:1338`, runtime capability `:599-606`, permission-file `:622-630`, ws-name `:792-798` (registry). Blocking-wait poll loop `:1425-1447` is the axis-neutral unit — stays whole. |
| `agent-watchdog.sh` | **Stay (no edit)** | Axis-neutral liveness/retry core. `progressed()` `:27` (file mtime = terminal-read), `transcribe_review` `:34-73` (registry-driven completion-signal), `stash-by` lookup `:131`, watchdog stash branch `:158-160` (registry-driven). Zero hardcoded runtime names. |
| `agent-runtime.sh` | **Stay + split out** | Runtime-axis boundary/router. Keeps: `runtime_bin` `:11-22`, `probe_runtime` `:27-59`, arg/role/mode validation `:80-82,108-112`, `capabilities` `:83`. Moves out: `validate_opencode_permissions` `:60-79`, opencode `permission-file` body `:90-105`, and the three `run` branches `:114-148` (§5.1). Router then `exec`s `runtimes/$RUNTIME.sh`, mirroring `dispatch-core.sh:803` (`adapters/$ADAPTER.sh`). |
| `codex-safe.sh` | **Move → `runtimes/codex-safe.sh`** | Codex-member write-mode wrapper (ADR 0006 blesses the delegation, `agent-runtime.sh:114-126`). Sole caller is the codex branch; skill doc references it (`toolkit/.claude/skills/agent-workflow/SKILL.md:29`). Internal `SCRIPT_DIR` refs to edit on move: `:64` (gains `/..`), `$SCRIPT_DIR/workflow-stash.sh` `:83`, `$SCRIPT_DIR/lib/*` `:189,197,222`. |
| `redispatch-check.sh` | **Stay** | Axis-neutral admission (573 lines; BLOCKER/ROUND-STATE policy). No runtime/adapter literals. |
| `route.sh` | **Stay** | Policy routing; runtime set read from registry (`route.sh:8,32`). |
| `model-alloc.sh` | **Stay** | Allocation config logic; runtime arrives as `--runner` parameter data. Pre-existing note: `:66` contains a `runner !== "codex"` reviewer-default literal — an ADR 0006 tension this reorg does not widen and does not fix (out of scope; not a launch branch). |
| `output-contract.sh`, `prompt-ac-check.sh`, `ac-check.sh`, `completion-check.sh`, `artifact-fresh.sh`, `candidate-close.sh`, `candidate-integrate.sh`, `conductor-control-publish.sh`, `conductor-rebuild.sh`, `rebase-inflight.sh`, `review-archive.sh`, `review-capsule.sh`, `round-state-init.sh`, `round-state-render-ac.sh`, `target-verify.sh`, `telemetry.sh`, `workflow-stash.sh`, `install-into.sh` | **Stay** | Axis-neutral operators/validators/publishers — grep for literal adapter/runtime names returns nothing (the only hits repo-wide are the 9 files named above). `workflow-stash.sh`'s header comment says "codex" (:2) but the body is pure git; comment-only. `install-into.sh` copies `scripts/` wholesale (`install-into.sh:90,97`) so it inherits the reorg with no structural change; its `lib/product-home.sh` ref `:56` is unaffected. |

### 3.2 `adapters/` (3 files)

| Current path | Disposition |
|---|---|
| `adapters/cmux.sh` | **Stay + 1-line edit**: `:6` `CMUX_HANDLES="$SCRIPT_DIR/../lib/cmux-handles.cjs"` → `"$SCRIPT_DIR/cmux-handles.cjs"` (§5.4). Launch `:60`, inspect `:81-85` unchanged. |
| `adapters/orca.sh` | **Stay (no edit)** — sources `../lib/adapter-helpers.sh` `:6`, which stays in `lib/`. |
| `adapters/herdr.sh` | **Stay (no edit)** — same `:7` sourcing; `workspace close` at `:246` stays (launch-failure cleanup, matrix §1 teardown row). |

### 3.3 `runtime-permissions/` (2 files — folder dissolves)

| Current path | Disposition |
|---|---|
| `runtime-permissions/opencode-read.json` | **Move → `runtimes/opencode-read.json`** — opencode-member mode-to-permission data; ref owners move to `runtimes/opencode.sh` (from `agent-runtime.sh:94-96`). |
| `runtime-permissions/opencode-write.json` | **Move → `runtimes/opencode-write.json`** — same. |

### 3.4 `lib/` (33 files)

| Current path | Disposition | Note |
|---|---|---|
| `lib/cmux-handles.cjs` | **Move → `adapters/cmux-handles.cjs`** | Only cmux-axis file in shared lib. Consumers: `adapters/cmux.sh:6,65,85`, `__tests__/install-into.smoke.sh`, `__tests__/orchestrator-interface.smoke.sh`, release gate `:131,216,227`. |
| `lib/runtime-registry.cjs` | **Stay + additive edit** | Runtime-axis registry = shared axis *data* (RUNTIMES/STASH_BY/BIN/PROBE/PROGRESS tables, `:9-110`); consumed by 8 non-test files including core files — belongs in shared `lib/`, not `runtimes/`. Gains `EFFORT_DEFAULT` table + `effort-default` CLI case (§5.3). |
| `lib/transport-registry.cjs` | **Stay (no edit)** | Same rationale on the transport side (9 lines). |
| `lib/adapter-helpers.sh` | **Stay (comment edit only)** | Cross-adapter shared helpers; sourcing-pattern doc comment `:3-4` updated to reflect `cmux-handles.cjs` colocation. Sets `ADAPTER_SEMVER`/`ADAPTER_JSON` relative to itself `:7-9` — unchanged. |
| `lib/adapter-json.cjs`, `lib/semver.cjs` | **Stay (no edit)** | Cross-adapter shared (all 3 adapters via `adapter-helpers.sh`). |
| `lib/admission-advance.cjs`, `admission-recover.cjs`, `atomic-fs.cjs`, `blocker-check.cjs`, `blocker-recovery.cjs`, `candidate-close.cjs`, `candidate-integrate.cjs`, `capability-result.cjs`, `contract-validators.cjs`, `json-schema-subset.cjs`, `launch-result.cjs`, `output-contract.mjs`, `parallel-plan.cjs`, `pr-draft-check.cjs`, `product-home.sh`, `review-capsule.mjs`, `review-publish.cjs`, `review-snapshot.cjs`, `rfc3339.cjs`, `route-policy.cjs`, `route.cjs`, `target-verify.mjs`, `telemetry-sample.cjs`, `telemetry.mjs`, `touch-allowlist-preflight.cjs`, `verify-artifact.cjs`, `worktree-content-id.cjs` | **Stay (no edit)** | Axis-neutral shared logic. `admission-recover.cjs:33,36` already delegates both axes to the two registries (#168 landed). `capability-result.cjs`/`launch-result.cjs` parse adapter output *generically* (no adapter names). |

### 3.5 `install-profiles/generic/` (5 files) — see §8

| Current path | Disposition |
|---|---|
| `install-profiles/generic/docs/agents/multi-agent-workflow.md`, `docs/agents/workflow-config.example.json`, `opencode/agent-workflow.md`, `opencode/opencode.json`, `skill/SKILL.md` | **Stay (no edit)** — staged *docs/skill/config*, not scripts. |

## 4. AC-198-2 mapping — where the 4 axis-neutral units live, and why they are not split

| Matrix unit | Shared location in this design | Evidence it is one code path |
|---|---|---|
| terminal-read | `agent-watchdog.sh` (output capture/`progressed()` `:27`) + `agent-runtime.sh` launch argv (file/stream capture per runtime is *launch*, the one varying unit) | Watchdog reads `$OUTPUT` temp file regardless of runtime; no adapter owns a read command (matrix §1 row 3) |
| blocking-wait | `dispatch-core.sh:1425-1447` (RUN/BLOCKER freshness poll), `:336-376` (`await` EVENTS.jsonl reader), `agent-watchdog.sh:146-150` (retry loop) | Same poll for every adapter/runtime; file-signature based (`file_sig` `:131-149`) |
| artifact-retrieval | `dispatch-core.sh` admission reads + `lib/{blocker-check,pr-draft-check,review-publish,artifact-fresh…}` | Direct `.review/*.json` disk reads; no adapter involvement (matrix §1 row 5) |
| teardown | Generic git-worktree removal on the operator/CONDUCTOR side (not adapter-mediated); herdr's launch-failure `workspace close` stays inside `adapters/herdr.sh:246` | No adapter exposes a general teardown command (matrix §1 row 6) |

None of these gain a per-adapter or per-runtime folder anywhere in §2/§3. The
only new per-axis real estate (`runtimes/`) encloses exactly the two varying
units' member code: launch invocation shape and mode-to-permission mapping
(plus completion-signal *facts* as registry data, which stays in shared `lib/`).

## 5. Precise split boundaries

### 5.1 `agent-runtime.sh` → `runtimes/{codex,claude,opencode}.sh` (ADR 0006 split)

- **`runtimes/codex.sh`** — pull `agent-runtime.sh:114-127`: write/review
  delegation to `codex-safe.sh` (:118-126, repoint
  `$SCRIPT_DIR/codex-safe.sh` → sibling `$SCRIPT_DIR/codex-safe.sh` now inside
  `runtimes/`) and the read-only `exec --sandbox read-only --cd …` argv (:127).
- **`runtimes/claude.sh`** — pull `:128-140`: permission-mode mapping
  (:129) and launch argv with `progress-flags` read from the registry
  (:136-139 — registry lookup stays; ADR 0006 names this exact pattern as
  correct).
- **`runtimes/opencode.sh`** — pull `:60-79` (`validate_opencode_permissions`),
  `:90-105` (opencode `permission-file` body incl. the default
  `runtime-permissions/opencode-{read,write}.json` resolution at :94-96,
  repointed to siblings), and `:141-148` (permission validation + `OPENCODE_CONFIG_CONTENT`
  + `run --dir --format json --agent agent-workflow` argv).
- **`agent-runtime.sh` keeps** the shared, registry-driven scaffolding:
  `runtime_bin` :11-22, `probe_runtime` :27-59 (help-token contract is registry
  data), CLI/role/mode validation :80-112, `capabilities` :83. Its `run` and
  `permission-file` paths become `exec "$SCRIPT_DIR/runtimes/$RUNTIME.sh" …`
  — the direct mirror of `dispatch-core.sh:803`
  (`ADAPTER_SCRIPT="$SCRIPT_DIR/adapters/$ADAPTER.sh"`). Non-opencode
  `permission-file` keeps printing nothing/exit 0 in the router (generic
  default, `dispatch-core.sh:622-630` depends on it).

### 5.2 `codex-safe.sh` and `runtime-permissions/*.json` moves

Pure `git mv` + same-commit `SCRIPT_DIR` repoints (listed in §3.1/§3.3). No
logic changes.

### 5.3 `dispatch-core.sh` — the two inline runtime branches (the "mixed" residue)

1. **`:714-719`** — `case "$RUNTIME" in codex) EFFORT="low";; claude|opencode) EFFORT="medium";; esac` (effort default). Extract to a new `EFFORT_DEFAULT` table + `effort-default` subcommand in `lib/runtime-registry.cjs` (beside `WS_SHORT_IMPL` :23-27, which solved the identical leak the same way); `dispatch-core.sh` reads it like `:793` already reads `ws-short-impl`.
2. **`:775-782`** — the per-runtime model-compatibility probe argv inside `model_compatibility_preflight` (`codex exec --skip-git-repo-check …` / `claude --print …` / `opencode run …`). These duplicate the member launch argv shapes (vs `agent-runtime.sh:127,130,147`). **Owner, decided (not "or"): `agent-runtime.sh`**, not the individual `runtimes/*.sh` member files — it is already the runtime-axis router/boundary that `dispatch-core.sh` calls through for every other cross-cutting runtime concern (`capabilities`, `permission-file`), so the probe becomes a third subcommand on the same boundary: `agent-runtime.sh probe --runtime R --model M --effort E`, contract `exit 0` = compatible / non-zero = incompatible, stdout/stderr silenced by the caller exactly as the existing inline `>/dev/null 2>&1` redirects do. `dispatch-core.sh:775-782` becomes `bash "$RUNTIME_ADAPTER" probe --runtime "$RUNTIME" --model "$MODEL" --effort "$EFFORT" </dev/null >/dev/null 2>&1`, mirroring the existing `permission-file`/`capabilities` subcommand call shape at `dispatch-core.sh:622-630`. Internally `agent-runtime.sh probe` may `exec` into `runtimes/$RUNTIME.sh` for the actual argv, consistent with how `run` and `permission-file` delegate (§5.1) — but the *caller-facing* contract (the subcommand `dispatch-core.sh` invokes) lives on `agent-runtime.sh`, not on the member files directly, so `dispatch-core.sh` never needs to know the `runtimes/` path shape. Keeps the `AGENT_WORKFLOW_MODEL_PROBE_CMD` host override (:770-774) and the fail-closed default (:781) verbatim.

After both extractions, `grep -E 'codex|claude|opencode|cmux|orca|herdr' dispatch-core.sh` returns nothing but comments — the ADR 0006 reviewer check passes. No other lines of `dispatch-core.sh` move anywhere.

### 5.4 `lib/cmux-handles.cjs` → `adapters/cmux-handles.cjs`

One-line consumer edit (`adapters/cmux.sh:6`). Aligns lib/ with "shared only";
the transport axis then owns 100% of its member-specific code under `adapters/`.

## 6. Migration ordering (AC-198-3)

Guiding rule: `lib/` never moves (except the single cmux-handles file), so the
broad `SCRIPT_DIR/lib/…` web (27 root scripts, 46 references in
`dispatch-core.sh` alone) is never broken wholesale. Each step lands green
(`bash -n` on touched shell files + the affected `*.smoke.sh` mid-flight; full
`run-all.sh` at the PR gate, per toolkit/AGENTS.md cadence).

**Same-commit rule, applied literally**: every step below bundles its `git mv`
+ its `SCRIPT_DIR`/caller repoints + its smoke-test path updates +
`smoke-coverage.manifest` rows + the release-gate asserts for exactly the
paths that step moves, all in that step's own commit — no step defers a gate
update for a path it just moved. A prior draft of this section deferred all
docs/gates to a final step, which is wrong: it would leave every intermediate
commit's release gate red for the paths already moved. Corrected below.

1. **Step 1 — create `runtimes/` member files AND flip the router AND move
   the assets, atomically in one commit.** This step was previously split into
   "create files" then "flip router" as two commits; that's broken as written
   because the in-between state has `agent-runtime.sh`'s router still
   resolving `$SCRIPT_DIR/codex-safe.sh` and
   `$SCRIPT_DIR/runtime-permissions/opencode-{read,write}.json` while those
   exact paths no longer exist post-`git mv`. Corrected: do the `git mv`, the
   `SCRIPT_DIR` repoints inside the moved files (`codex-safe.sh:64` gains
   `/..`; `:83,189,197,222`), creating `runtimes/{codex,claude,opencode}.sh`
   from the §5.1 extractions, AND replacing `agent-runtime.sh:113-148` /
   `:90-105` with `exec` into `runtimes/$RUNTIME.sh` — all in this one commit,
   so there is no intermediate state where old paths are gone but the router
   still points at them. Same commit: `agent-runtime.smoke.sh`,
   `agent-watchdog.smoke.sh` (indirect), `runtime-registry-containment.smoke.sh`,
   `codex-safe.smoke.sh`, `output-contract.smoke.sh` (its `../codex-safe.sh`
   references, §7.1), and `smoke-coverage.manifest` rows for
   `agent-runtime.sh`/`codex-safe.sh`/the 3 new `runtimes/*.sh` files.
2. **Step 2 — `dispatch-core.sh` extractions** (§5.3), now that Step 1's
   delegation targets exist: registry `effort-default` first (self-contained),
   then the probe-argv delegation (owner decided in §5.3 below — no "or").
   Same commit: `runtime-model-preflight.smoke.sh` (references
   `../dispatch-core.sh`).
3. **Step 3 — `cmux-handles.cjs` colocation** (independent of steps 1-2; can
   run in parallel or any order relative to them): `git mv lib/cmux-handles.cjs
   adapters/`, edit `adapters/cmux.sh:6`, same commit: update
   `__tests__/install-into.smoke.sh`, `__tests__/orchestrator-interface.smoke.sh`,
   `smoke-coverage.manifest`, and the release-gate asserts
   (`.github/tests/release-contract.smoke.sh:131,216,227`).
4. **Step 4 — end-state documentation sweep only** (playbook, README, STATUS,
   skill doc path mentions: `toolkit/docs/agents/multi-agent-workflow.md` 11
   refs, `toolkit/README.md` 6, `toolkit/STATUS.md` 5,
   `toolkit/.claude/skills/agent-workflow/SKILL.md:29` — `$WF/scripts/codex-safe.sh`
   → `$WF/scripts/runtimes/codex-safe.sh`). This step must contain **only**
   descriptive prose updates — every path reference that functions as an
   enforced contract (release-gate asserts, smoke-test sourcing, the manifest)
   was already updated in the step that moved its target (Steps 1-3), per the
   same-commit rule above. If any release-gate assert or smoke path still
   needs updating by the time Step 4 starts, that is evidence a prior step's
   commit was incomplete, not something Step 4 should absorb.

Ordering rationale (why this sequence): Step 1 is one atomic unit because
splitting file-creation from router-flip creates the broken intermediate state
above; `dispatch-core.sh`'s probe delegation (Step 2) needs Step 1's member
files to exist; Step 3 is fully independent (different files, no shared
dependency) and may interleave anywhere; Step 4 is end-state docs only,
carrying no enforced path contract of its own. `agent-workflow.sh`,
`install-into.sh`, and the installed-link contract never change because
`agent-workflow.sh` stays at the scripts root.

## 7. Named risks (AC-198-3)

1. **Hardcoded smoke-test paths.** 42 of the `__tests__/*.smoke.sh` files
   reference `../` script paths. This design's moves touch a bounded subset
   (measured `rg -o '\.\./[A-Za-z0-9_.-]+'`):
   - `codex-safe.smoke.sh` (`../codex-safe.sh`), `agent-runtime.smoke.sh`
     (`../agent-runtime.sh`, `../runtime-permissions/` ×2),
     `agent-watchdog.smoke.sh` (`../runtime-permissions/` ×2),
     `runtime-model-preflight.smoke.sh` (`../runtime-permissions`,
     `../dispatch-core.sh`, `../agent-watchdog.sh`),
     `output-contract.smoke.sh` (`../codex-safe.sh` ×3),
     `install-into.smoke.sh` + `orchestrator-interface.smoke.sh`
     (cmux-handles refs), plus `cmux-dispatch.smoke.sh` if any
     `codex-safe`/runtime-permission stubs reference the moved names.
   - Unaffected but audit anyway: the `../cmux-dispatch.sh` (×11 across
     output-contract/review-capsule/review-publish), `../lib` (×21), `../..`
     (×9) references — none of those targets move.
   - `smoke-coverage.manifest` maps every script path to its covering test and
     must be updated for each moved file; `run-all.sh:10` discovers tests at
     `maxdepth 1`, so **no test may move into a subfolder** — `__tests__/`
     stays flat, `__tests__/lib/stub-argv.sh` stays.
2. **`SCRIPT_DIR`-relative sourcing.** 27 of 27 root scripts + 3 adapters
   compute `SCRIPT_DIR` and resolve siblings/lib relative to it. Moves
   root→`runtimes/` change depth by one: every `$SCRIPT_DIR/lib/…` and
   `$SCRIPT_DIR/workflow-stash.sh` inside moved files becomes `$SCRIPT_DIR/../…`
   in the same commit (enumerated in §3.1). The subtle one: `dispatch-core.sh:57`
   pins `WATCHDOG="$SCRIPT_DIR/agent-watchdog.sh"` and bakes the **absolute**
   path into each generated `launch.sh` runner (`write_launch_runner`,
   `dispatch-core.sh:166-208`) — an upgrade deployed between dispatch and
   worker start leaves stale runners pointing at pre-move paths. Mitigation:
   land the move between dispatch rounds, or accept the existing
   `cleanup_superseded_runners` (:210-224) expiry path; `agent-watchdog.sh`
   itself does not move, so the common case (watchdog pinned, wrapper moved)
   only affects `codex-safe.sh` reached via `AGENT_WORKFLOW_CODEX_BIN`/member
   exec — re-resolved per run, low residual risk.
3. **`install-profiles/generic/` staging.** Verified contents:
   `docs/agents/{multi-agent-workflow.md,workflow-config.example.json}`,
   `opencode/{agent-workflow.md,opencode.json}`, `skill/SKILL.md` — **no
   scripts**. The install flow copies `scripts/` wholesale
   (`install-into.sh:90,97`) so the reorg propagates to targets verbatim; no
   parallel restructure of the staging tree is needed or safe (it must not
   diverge into containing scripts). The only install-side path contract is the
   recognized-layout marker `agent-workflow.sh`
   (`install-into.sh:282`), which stays at the root. Post-move `--upgrade`
   replaces the whole installed `scripts/` dir — old installs keep the old
   layout until upgraded (acceptable; identical to any prior scripts change).
4. **Release gate coupling.** `.github/tests/release-contract.smoke.sh`
   asserts ~21 concrete script paths (`:112-141` layout asserts, `:191`
   transport-registry, `:476` installed herdr adapter, `:510-512`
   cmux-dispatch dry-runs) and contains a leaked-path denylist (`:238`).
   Steps 1-3 (the steps that actually move paths) each need their gate
   asserts updated same-commit, per §6's rule, or the repository release gate
   fails CI. Step 4 (docs-only) carries no gate-assert obligation of its own.
5. **Docs/skill path drift.** `SKILL.md:29` hardcodes
   `$WF/scripts/codex-safe.sh`; playbook/README/STATUS carry 22 more script
   path references. Root AGENTS.md requires playbook/README/STATUS updates in
   the same commit as any script contract change — a folder move counts.
6. **No transient duplication window** — §6's corrected Step 1 does file
   creation, the `git mv`s, and the router flip atomically in one commit, so
   there is never a commit where both the new member files and the old inline
   router branches exist simultaneously. (An earlier draft of this document
   split those into two steps/commits and would have had this window along
   with the broken-intermediate-state defect §6 documents fixing — both are
   resolved by the same correction.)

## 8. `install-profiles/generic` — decision

Stays flat and unchanged. It is a staged copy of *product documents and target
config*, not of scripts; the "staged copy of scripts" premise does not hold on
current `main`. If a future change stages scripts there, that change — not this
design — owns keeping it structurally identical to `scripts/`.

## 9. What this document does NOT do

- Moves, renames, or edits **nothing** under `toolkit/scripts/` (or anywhere
  else); `touch_allowlist` = this file only. All §5/§6 content is
  follow-up implementation scope, suggested as the step-1-through-5 breakdown
  in §6 (each step a separate commit within one PR, or small PR sequence).
- Does not implement ADR 0006's split itself, #155's codex `--json` wiring, or
  #132's artifact-retrieval dedup — this design only reserves the folder
  boundaries those issues will land into. `runtimes/codex.sh` in this design
  still contains the non-streaming launch; #155 changes its content, not its
  location.
- Does not change any schema, adapter 4-command surface, CLI flag, or artifact
  contract. `agent-workflow.sh`, `cmux-dispatch.sh`, and all operator scripts
  keep their exact invocation shapes.
- Does not create `core/`, per-axis subfolders for shared units, or any
  adapter×runtime grid (§1).

## 10. Acceptance-criteria check

- **AC-198-1** — §2 concrete target tree; §3 per-file table for all 70
  non-test files (27 root + 3 adapters + 2 runtime-permissions + 33 lib + 5
  install-profile, §3.1-§3.5) with real current paths; §5 split boundaries
  cite exact read line ranges (`agent-runtime.sh:60-79,90-105,114-148`;
  `dispatch-core.sh:714-719,775-782`; `adapters/cmux.sh:6`).
- **AC-198-2** — §4 maps terminal-read / blocking-wait / artifact-retrieval /
  teardown to their shared locations with line evidence; no table row or tree
  entry places any of them in `adapters/` or `runtimes/`; §1 explicitly rejects
  the grid.
- **AC-198-3** — §6 five-step ordering with dependency rationale
  (members-before-router, router-before-core-extraction, docs-last);
  §7 names the three required risks with measured counts (42 smoke files,
  per-file `../` tallies, `SCRIPT_DIR` inventory, install staging verdict) plus
  release-gate coupling and the stale-runner absolute-path hazard.
