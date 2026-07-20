# Multi-Agent Workflow — Operating Playbook

This file is the detailed operating authority for the cmux × Claude × Codex workflow. The project skill at `.claude/skills/agent-workflow/SKILL.md` is deliberately a thin router into this playbook; do not duplicate model maps, incident contracts, or verifier rules there.

The coordination model is reusable, but some shipped adapters are still target-shaped: `prepare-worktree.sh` assumes pnpm and `apps/backend/.env`, `tier-probe.sh` targets exported TypeScript contracts, and `verify.sh` assumes a pnpm `backend` package tested by Vitest. Read `.claude/skills/agent-workflow/references/adoption.md` before applying the toolkit to a repository with a different shape.

## Product home and repository context

The workflow product home is the physical parent of the running command's `scripts/` directory. Scripts, schemas, and docs are sibling product resources in source, installed, and exported layouts; `ac-check.sh` and `completion-check.sh` resolve the canonical schema through this interface.

`install-into.sh` resolves `PRODUCT_ROOT` from its own location. An enclosing Git root, when discoverable, is optional `REPOSITORY_ROOT` context used only for repository-specific safety checks. Missing Git metadata does not make an exported product invalid. Target runtime evidence remains target-owned under `<target>/.review`; it is not a product schema directory.

Each recognized pre-separation absolute symlink fails closed with an actionable `--migrate-legacy` command, even when only part of an installation remains or its former repository root moved or disappeared. The same recognizer covers a relocated or deleted post-separation product home. Because a current-layout `schemas/` suffix is otherwise ambiguous with a custom target link, it is recognized only when a scripts, docs, or skill sibling identifies the same former product home. Migration preflights all managed destinations, removes only recognized managed link nodes, and preserves files, directories, copy snapshots, and unrecognized links. `--force` is the separate explicit full-replacement interface and cannot be combined with migration.

Managed parent paths (`.agent-workflow`, `.agent-workflow/docs`, `.claude`, `.claude/skills`, and `.review`) must be real directories inside the target. The installer rejects symlinked parents before legacy detection or any mutation in default, migration, and force modes, preventing managed writes or removals from escaping the target root.

Product containment, classified legacy-path evidence, and maintainer-file non-leakage are release concerns owned by infrastructure outside this distributable product and are not installed into targets. Product-local Markdown links must resolve from both source and installed paths. The legacy symlink recognizer above is a documented compatibility contract, not a product-home fallback.

When a target run reveals a toolkit problem, follow the downstream feedback loop in the adoption
guide and `docs/agents/issue-reporting.md`: preserve a sanitized reproduction, classify the failing
boundary without overclaiming, search existing issues, and—only with external-write
authorization—file it in the toolkit repository. Link that upstream issue from the target handoff
or completion report so temporary target-owned workarounds remain traceable.

## Risk Tier Routing

Every issue is one of three tiers. The tier picks the agent set.

| Tier | When | Agents | Artifacts |
|---|---|---|---|
| **Trivial** | P3 cleanup, single file, no API/domain/UI change | CODEX + VERIFIER | pr_draft only |
| **Standard** | P2 / single-module behavior change | CODEX + REVIEWER + VERIFIER | pr_draft + review |
| **Full Cluster** | Any of: migration, auth, permissions, shared UI shells, `packages/shared`, cross-module contract, prod data path | ARCHITECT + CODEX + REVIEWER + VERIFIER (+ VISUAL if UI) | all of pr_draft, touch, review, verify |

**Escalation rule:** if a Trivial or Standard issue's actual touch set hits any Full Cluster trigger (e.g. `packages/shared/*`, migrations), CODEX MUST abort with a `blocker` artifact. Set `reason_code` from the enum (`tier_escalation_required` for this case) and put the ACTUAL out-of-scope files/symbols you hit into `blocking_fact` — never copy the dispatch prompt's example phrasing. In trial #1 CODEX parroted the canned phrase `"touches packages/shared"` straight from the prompt even though the real cause was backend modules (`src/voc`, `src/permissions`); the structured `reason_code` + `blocking_fact` fields exist to kill that leak.

### Pre-dispatch tier probe

Before assigning the **Trivial** tier, run the probe over the touched files:

```
scripts/tier-probe.sh <touched-file> [<touched-file>...]
```

A non-zero exit **forbids Trivial — escalate.** The probe disallows Trivial when the diff changes an exported contract (`export interface|type|class|enum|function|const`, `export default`, named/star re-exports, `... from` re-exports, `constructor(`, `as const`, generic-constraint changes), when an `index.ts`/`index.tsx` barrel is touched at all, or — the catch-all anti-false-negative bias — when an exported-TS file's diff is not provably comment/whitespace-only.

The probe answers exactly one question: **"is Trivial disallowed?"** — NOT "is this change safe?". It is biased to disallow: **false positives (disallowing Trivial when it might've been fine) are acceptable; false negatives (allowing Trivial when a contract changed) are the harm.** The probe is advisory; `scripts/verify.sh --typecheck` is the precise blast-radius oracle and must still cover importing modules.

This exists because of trial **#33**: narrowing one exported TS type in a "single file" broke 5 importing modules. **File count is not the tier** — an exported-contract or ambiguous exported-TS change is non-Trivial regardless of how few files it touches.

### Pre-scope-lock impact pass

Before locking the touch set for a chunk that changes an exported contract, CONDUCTOR must enumerate the changed exports' compile-time consumers. Use the target profile recorded during adoption and the target repository's native search/index facilities; CodeGraph may be used when available, but it is not a workflow dependency. Do not add a toolkit-level `impact-manifest` script without new evidence that repository-native discovery is insufficient.

The pre-lock output is the enumerated consumer set: use it to propose the touch allowlist and review scope. Enumeration does not imply that every consumer needs an edit. For an exported-contract chunk, copy the exact repository-relative consumer paths into the canonical `contract.chunk_boundary.compile_consumers[]` interface described below.

After the contract change is implemented, run the target profile's full typecheck command as the deterministic gate. A passing typecheck does not replace pre-lock consumer enumeration; it checks the resulting implementation at a realizable checkpoint. `completion-check.sh` executes the canonical `contract.chunk_boundary.typecheck_command`; record the same command and concise result in `live_probes[]` so the observation remains reconstructable.

Record each discovery and typecheck command in canonical ROUND-STATE `live_probes[]`, including its exit code, observation time, and a concise result summary. The discovery probes are recorded before lock and the typecheck probe after it runs. The existing `live_probes[]` interface is sufficient; add a separate impact section only when a concrete target demonstrates information that it cannot represent.

This pass does not claim completeness for dynamic registries or convention-coupled consumers. Represent those concrete residuals as triggered convention watches rather than ambient prompt text.

### Compile-atomic chunk boundary

An exported compile-time contract and every consumer enumerated by the pre-scope-lock impact pass form one compile-atomic correctness module. Put them in the same chunk or split the proposed work before dispatch so every resulting chunk can pass the repository-wide typecheck. A listed consumer is always in that chunk's review scope but does not require an edit when the invariant already holds. Compile atomicity is an admission rule, not permission to absorb independently testable behavior into a feature-sized mega-chunk.

Record this contract in optional `contract.chunk_boundary`: `chunk_id`, the target-native `typecheck_command`, exact repository-relative `compile_consumers[]`, and `convention_watch[]`. Every compile consumer must match `contract.touch_allowlist`; `completion-check.sh` rejects an out-of-chunk consumer and a non-zero typecheck before review. Revisions to the consumer set, command, or watches increment ROUND-STATE `revision` like any other normative contract change.

Each convention watch has exactly `surface`, path-glob `trigger[]`, `expected_invariant`, `owner`, `review_by_chunk`, and `closed_by`. `closed_by` selects the exact REVIEW artifact checklist item that must close the watch with `met: true` and a note citing the observed evidence. Keep dormant watches in ROUND-STATE so they survive session rotation. Only watches triggered by the live `base_sha..HEAD` diff and assigned to the current `chunk_id` appear in `completion-check.sh`'s `review_obligations[]`; untriggered watches do not enter that chunk's narrative or review checklist. Use `**` only when a convention trigger cannot be narrowed safely. Trigger globs and consumer paths are repository-relative and may not escape through `..`.

The watch trigger is deliberately a conservative changed-path predicate, not a shell command or semantic DSL. Mechanically enumerable registry or exhaustiveness consumers belong in `compile_consumers[]`; reserve watches for convention-only relationships. ROUND-STATE remains the only authority—do not create an impact manifest, watch registry, or reviewer-owned shadow state.

### Repeated-round circuit breaker

Implementation redispatch is CONDUCTOR correctness policy, not watchdog retry policy. Before every implementation redispatch, classify the failed round in canonical ROUND-STATE `round_control.failures[]` and run:

```bash
scripts/redispatch-check.sh \
  --round-state <ISSUE-N-ROUND-STATE.json> \
  --manifest-revision <revision>
```

For the actual write-capable redispatch, pass the same inputs to the mandatory entry point:

```bash
scripts/cmux-dispatch.sh \
  --issue <N> \
  --worktree <worktree> \
  --round-state <ISSUE-N-ROUND-STATE.json> \
  --manifest-revision <revision> \
  --model <pinned-model> \
  --effort <pinned-effort>
```

When a same-issue RUN or BLOCKER already exists, `cmux-dispatch.sh` refuses write dispatch without those inputs, executes `redispatch-check.sh` immediately before cmux creation, requires at least one classified active failure, and atomically creates a revision/ordinal/mode-specific admission directory. Reusing the same ROUND-STATE admission fails closed; a crash after consumption requires investigation and a new canonical revision rather than deleting the marker and replaying the batch. `--dry-run` evaluates but never consumes admission. Read-only seats remain outside the implementation circuit.

Each immutable failure entry has one `primary_origin`—`environment`, `dispatch_contract`, `implementation`, `test_oracle`, `verification_harness`, or `integration_drift`—plus optional unique `secondary_origins[]`, failed AC ids, an owner, a typed next action, and evidence pointers bound to content hash and observed HEAD. Primary origin alone drives the breaker; secondary origins preserve nuance without diffusing ownership. Model or effort escalation is not an action kind and never clears a failure. Preserve failed VERIFY/REVIEW evidence at the referenced history path before a later run replaces a current artifact. The gate resolves each evidence file inside the declared worktree, verifies its SHA-256 and that its HEAD names a repository commit, and rejects a ROUND-STATE whose `head_sha` differs from the live worktree. Every failed round needs VERIFY or REVIEW evidence; failures with AC ids retain those ids per entry. Changing a failure to `closed` additionally requires a hash/HEAD-bound `closed_by` VERIFY/REVIEW reference, so editing status alone cannot reset the active sequence.

The gate is biased to trip over the active open-failure sequence: two consecutive open failures with the same primary origin, or two completed redispatches before a proposed third redispatch, returns `diagnosis_required` and forbids another normal implementation dispatch. Verified-closed historical failures remain evidence but do not retrip a later active cycle. The initial implementation is ordinal 1; ordinary redispatches are ordinals 2 and 3, so another dispatch after three active recorded failures is the forbidden third redispatch. Watchdog attempts, refusal probes, RUN states, heartbeats, and process retries never increment these ordinals. An active `security_stop` returns immediately at any count.

A tripped circuit admits at most one `integrated_fix` batch. ROUND-STATE diagnosis records are an ordered prefix: (1) recheck oracle and contract first, (2) capture one reproducible hard fact, and (3) identify a passing analog with the fixed `guess_forbidden_copy_passing_analog_to_parity` instruction. This means: do not guess; copy the known-green wiring to parity; if it remains red, report a blocker instead of committing another speculative patch. The optional singleton `manifest_update` permits at most one revision increment and its `to_revision` must equal the current ROUND-STATE revision. The singleton integrated batch must cover every open failure while retaining each failure's AC ids and evidence. `cmux-dispatch.sh` consumes its admission key atomically before launch; once the batch status is `used`, `redispatch-check.sh` also returns `diagnosis_exhausted`. Another implementation batch needs an explicit new decision or blocker, not an automatic redispatch.

The gate is read-only and deterministic. Exit 0 allows exactly the emitted `dispatch_mode` (`normal` or `integrated_fix`); exit 1 denies dispatch with the calculated trigger and obligations; exit 2 rejects malformed, stale, contradictory, or uncheckable state. It never reads prompt prose, model telemetry, RUN/HEARTBEAT, stderr text, or pane state. ROUND-STATE remains the sole ledger and CONDUCTOR remains its sole writer.

### ARCH feasibility evidence

Before ARCHITECT locks a decision for a Full Cluster change involving migrations, authorization, persistence constraints, or another repository-dependent capability, attach a feasibility appendix to the authoritative contract. It must cover the actual grants/privileges, the migration principal's capabilities, the immediately preceding migration and journal conventions, and the relevant uniqueness constraints; an inapplicable item needs an explicit reason, not an assumption.

For every live or repository observation, record the exact command and a concise observed result in the existing canonical ROUND-STATE `live_probes[]`; the appendix interprets that evidence, while `live_probes[]` remains the durable command/result record. A missing safe read path or an infeasible capability is a blocker or ARCH decision, never a speculative implementation instruction; this front-loads fact finding so verification confirms the design rather than discovering that it cannot run.

Use one appendix row per concern: `concern | exact command | concise result | decision impact`. The four required concerns are `grants/privileges`, `migration principal capability`, `prior migration/journal convention`, and `relevant uniqueness constraint`; the exact command/result pair is copied into `live_probes[]`, not a new artifact field.

## Model Allocation — role × model map, dynamic by tier

The current operator profile exposes suffixed OpenAI 5.6 aliases: **`gpt-5.6-sol` (top, heavy reasoning) > `gpt-5.6-terra` (everyday implementation) > `gpt-5.6-luna` (light/mechanical)**. These are environment capabilities, not portable toolkit dependencies. On a new machine/account, preflight the intended aliases and substitute an explicitly pinned ladder with the same capability ordering. The operator currently keeps fast mode off; that preference lives in machine config and is not installed by this repository.

| Role | Claude side | OpenAI side (codex) |
|---|---|---|
| CONDUCTOR | session model (Fable/Opus) | — |
| ARCHITECT / adversarial co-design | Opus or Fable | `gpt-5.6-sol` medium, read-only (thinking-heavy) |
| CODEX implementation | — | `gpt-5.6-terra` medium (fast off) |
| REVIEWER (code, clean context) | Fable/Opus alternative | one tier above implementer: `gpt-5.6-sol` medium (fast off) |
| VERIFIER | pane script; Sonnet subagent for log triage | — |
| VISUAL-REVIEWER | Opus | — |
| Scoping / utility subagents | Haiku / Sonnet | `gpt-5.6-luna` low for mechanical edits |

Dynamic selection by risk tier: **Trivial** → impl `gpt-5.6-luna` low (no REVIEWER on this tier). **Standard** → impl `gpt-5.6-terra` medium, review `gpt-5.6-sol` medium. **Full Cluster** → design `gpt-5.6-sol`; impl `gpt-5.6-terra` medium; review `gpt-5.6-sol` medium + Fable/Opus clean-context final pass for shared-contract chunks.

Invariants: review model ≥ one tier above implementation model, never same-or-lower. **Pin the model explicitly on every dispatch** (`--model <X> --effort medium`, forwarded by `cmux-dispatch.sh` to `codex-safe.sh`) — omitting it silently runs the config default instead of the tier you selected. On a model refusal, move only to another preflight-validated explicit model that preserves the role ordering; never fall back by omitting `--model`. `codex-safe.sh` enforces the 5.6 effort cap (max medium).

Before a bulk parallel dispatch, preflight-probe the pinned model once so a 400 surfaces on one cheap call instead of on every worker:

```
NODE_OPTIONS= codex exec --skip-git-repo-check -m <X> -c model_reasoning_effort=low "reply exactly OK"
```

Workload scaling (v1): review depth scales with the actual diff — ≤~50 changed lines with no exported-contract touch → single clean-context review round; >~400 lines OR >8 files OR any `packages/shared` touch → plan 2 review rounds (gap-audit + fix-verification) with re-verify after each fix commit; everything between uses the default single round + re-review-on-findings loop.

## Non-Negotiable Rules

- **Implementation is separate from review and verification.** The same agent/session must not implement and then approve or verify its own work. Re-review uses a new clean context.
- **Do not run two workspace-write Codex jobs in the same repo at the same time.** `codex-safe.sh` stashes partial work on failure; concurrent jobs in one checkout can race on stash state. Parallel implementation requires separate prepared worktrees.
- **Clear `NODE_OPTIONS=` before codex/node dispatch and verification.** cmux or shell preloads can leak `--require` instrumentation into codex/vitest children. `verify.sh` uses an explicit env allowlist, but operators should still dispatch with a clean `NODE_OPTIONS`.

## CONDUCTOR

The **CONDUCTOR** is the 5th role: the orchestrator. Claude Opus, in a **dedicated pane OUTSIDE all clusters**, overseeing every in-flight cluster (one CONDUCTOR, not one per cluster). It dispatches work to the worker roles (ARCHITECT, CODEX, REVIEWER, VERIFIER, VISUAL) and tracks chunk state.

- **READ-ONLY on product code.** CONDUCTOR never edits source files — any source edit is *role bleed*, a defect. It reads `.review/*.json` and dispatches.
- **Disk is truth.** It reads worker state EXCLUSIVELY from `.review/*.json` via `scripts/conductor-rebuild.sh` — never inferred from pane scrollback or prose. It holds no in-memory-only state and is rotatable/reconstructable.
- **Owns:** serial vs parallel, task split, role/model/persona assignment, tier (via `scripts/tier-probe.sh`).
- **Anti-bottleneck:** ARCHITECT may make routine intra-chunk choices (within-module refactors, adding tests, doc fixes, implementation details inside a scoped chunk) WITHOUT waiting on CONDUCTOR; CONDUCTOR is consulted only for cross-chunk/contract/tier decisions.

Full operating prompt: **`docs/agents/conductor-persona.md`**.

## VISUAL-REVIEWER

The tier table's `(+ VISUAL if UI)` is the **VISUAL-REVIEWER** — a sub-role run **under the REVIEWER umbrella** (its own pane when the UI surface is complex). It runs only on the **Full Cluster** tier when the change actually touches UI: **layout / copy placement / interaction states / design tokens / shells / reusable UI**. SKIP it for pure API-hook wiring or other non-visual logic.

- **Two tools, two jobs.** The environment's available **Playwright browser automation surface** is the live driver—discover its current tool identifier instead of pinning one here. It navigates the running app, screenshots, and asserts interaction states in a real browser (authoritative). `impeccable` is an optional plugin for static design-vocabulary/anti-pattern critique; if it is unavailable the role degrades to Playwright + heuristics.
- **A visual pass ALONE cannot close a chunk.** It MUST pair with an **INTERACTION SCRIPT** covering **create / edit / error / empty / permission** states. REVIEWER (incl. VISUAL-REVIEWER) owns the checklist + live smoke; **VERIFIER owns the durable Playwright specs.** The verdict feeds the existing `review` artifact — it does not invent a new type.
- **Enabling impeccable is OPTIONAL and LOCAL:** add `"impeccable@impeccable": true` to gitignored `.claude/settings.local.json` (confirm the exact `name@marketplace` ref first) — **never** the committed project `.claude/settings.json`, which would break teammates without the plugin.

Full operating prompt: **`docs/agents/visual-reviewer-persona.md`**.

## Release Captain

Every issue has one **Release Captain**. The Captain owns merge readiness with override authority.

- **Default Captain:** the user (interactive mode) or, in orchestrated mode, **CONDUCTOR (v0.2)** — the dedicated read-only orchestrator role (see `docs/agents/conductor-persona.md`). As Captain, CONDUCTOR stays READ-ONLY on product code and merges only on **evidence-backed** readiness: a canonical `ISSUE-<n>-VERIFY.json` with `producer_role: "VERIFIER"`, `classifier: "PASS"`, `verdict.exit_code: 0`, `verdict.failed: 0`, `verdict.passed >= 1`, matching issue/branch, and `head_sha` equal to the branch's live worktree HEAD (per R5/R6 below) — never on prose claims or CODEX-authored embedded fields.
- **Authority:** may reject merge despite all-green artifacts.
- **Mandate:** verify *integrated behavior* — does the change work end-to-end, not just pass local tests?
- **Why:** REVIEWER checks design fit and VERIFIER checks commands, but neither owns "does this actually ship safely."

**Machine-checkable readiness (R5).** A `pr_draft` with `status: "ready_for_review"` is NOT done unless the matching canonical `.review/ISSUE-<n>-VERIFY.json` exists and satisfies all verifier gates: `producer_role: "VERIFIER"`, `classifier: "PASS"`, `verdict.failed == 0`, `verdict.passed >= 1`, `verdict.exit_code == 0`, internal `issue` equal to the draft issue, `branch` equal to the draft branch, and `head_sha` equal to the branch HEAD. The old `pr_draft.verify_result` field is deprecated and ignored by CONDUCTOR; the schema still allows it only so old artifacts/fixtures do not hard-fail. Prose claims of "tests pass" do not count.

**State reconstruction (R6).** CONDUCTOR holds no in-memory state; it rebuilds chunk states purely from `.review/*.json` artifacts via `scripts/conductor-rebuild.sh <review-dir> [<fallback-head-sha>]`. Because CONDUCTOR spans MULTIPLE branches/worktrees, there is no single global branch HEAD — each `pr_draft` is resolved against ITS OWN worktree: if the artifact carries a `worktree_path`, the script runs `git -C <worktree_path> rev-parse HEAD` to get that branch's real HEAD and cross-checks that the worktree is on the draft's declared branch. A draft is reported **verified** only when `status: ready_for_review`, the deterministic `ISSUE-<n>-VERIFY.json` satisfies the R5 verifier gates, and its `head_sha` equals that worktree's current HEAD. If `head_sha` no longer matches (work landed after verify) the state is **stale_verify**; if the canonical verify artifact is missing/invalid, if branch/issue identity mismatches, or if no `worktree_path` (and no fallback) can resolve a live HEAD, the state is **unknown** — NEVER `verified`. A fallback HEAD may only demote; it can never promote to verified. Superseded artifacts are skipped; blockers report `blocked` with their `reason_code`.

**Verify-filter coverage limit.** CONDUCTOR can prove producer/issue/branch/head/classifier identity, but it cannot prove the verifier chose a sufficiently broad test filter. It warns when `pr_draft.verify_cmd` and `VERIFY.json.verify_cmd` differ; REVIEWER and Release Captain must still check that the verifier filter covers the touched behavior.

## Codex Sandbox Rule

All write-capable task dispatches MUST go through `scripts/codex-safe.sh`, which enforces:

- `--sandbox workspace-write` (no read/write outside the working root)
- `--cd <worktree>` on the codex call (locks codex's writable root to one worktree). The wrapper's own CLI flag is `--cwd`; it maps that to codex's `-C/--cd`.
- `sandbox_workspace_write.writable_roots=["<resolved Git metadata dir>"]` when `--cwd` is a Git checkout or linked worktree (see below)
- abort-time `workflow-stash.sh` (preserve partial diff on non-zero exit)

Direct `codex exec` is forbidden for implementation and review tasks. The cheap model-availability preflight in "Model Allocation" is the only direct non-task exception; it uses `--skip-git-repo-check`, requests an exact harmless reply, and must not carry project work.

#### Why a Git checkout needs its metadata directory as a writable root

**Incident (2026-07-16, issue #127 chunk d):** codex finished seven consecutive dispatches with `exit_code: 0`, every line of the chunk written — and **zero commits**. Prompts said `git commit` was part of the task, in capitals, naming how many prior runs had skipped it. It made no difference, because the model was never the problem.

`workspace-write` makes only `--cd` (plus `/tmp`) writable. A git worktree's `.git` is a *file* pointing at the MAIN repo's `.git/worktrees/<name>` — outside `--cd`. So every commit died:

```
fatal: Unable to create '/path/to/main/.git/worktrees/<n>/index.lock': Operation not permitted
```

The failure mode is nasty because it is **silent and looks behavioural**: codex reports the work it did, exits 0, and the missing commit reads as an instruction-following defect. It was a sandbox denial. No prompt wording can fix a sandbox denial — a mistake that cost seven rounds of conductor commit fallbacks before anyone probed the actual `git commit` stderr.

`codex-safe.sh` resolves `git rev-parse --git-common-dir` and grants **only that resolved Git metadata directory** as a writable root. This covers both a linked worktree (whose common dir is outside `--cd`) and a plain checkout (whose in-tree `.git` is still denied by `workspace-write`); it does not grant the checkout, a parent directory, or another metadata path. Guarded by `scripts/__tests__/codex-safe.smoke.sh` (worktree and plain repo each grant their resolved gitdir / non-git cwd still dispatches).

**Diagnostic lesson:** a scratch-repo repro under `/tmp` shows the bug **passing** — codex's sandbox makes `/tmp` writable by default, which masks it. Reproduce this class of bug in a worktree of the real repo, not a temp fixture.

### Codex stall watchdog

Dispatch CODEX through `scripts/codex-watchdog.sh --issue <N> --prompt-file <file> --cwd <worktree>` when running automated clusters. The watchdog calls `scripts/codex-safe.sh` by absolute path, so the sandbox and stash rules still come from the single sanctioned wrapper. Clear `NODE_OPTIONS=` for the dispatch. `--prompt-file` may be relative — it is resolved against `--cwd`, not the calling shell's cwd (see incident below) — or absolute. On startup the watchdog echoes its resolved config (`issue`, `prompt-file`, `cwd`) so pane scrollback always shows what it actually tried.

Liveness is **process + filesystem progress**, never stdout first-token output. The watchdog waits for the codex-safe process to stay alive and for files in the worktree to advance (`find -newer`, excluding `.git` and `node_modules`). If no file progress appears within `--first-progress-timeout` or later stalls for `--stall-timeout`, it kills the process tree and retries up to `--max-retries`. For a deliberately read-only dispatch, pass `--read-only`: codex-safe rewrites `<worktree>/.review/HEARTBEAT-ISSUE-<N>.json` every 20 seconds while its child is alive, so thinking-heavy work satisfies that same mtime check; write tasks remain strict.

After a non-stall non-zero exit, the watchdog does not inspect stderr. It preserves the diagnostic log at `<worktree>/.review/ISSUE-<N>-attempt<k>-stderr.log` and echoes that path, then probes Codex directly with a low-effort `reply exactly OK` request (overridable by `CODEX_WATCHDOG_PROBE_CMD`). A passing probe means transient failure and retries. One failed probe is inconclusive: after 10 seconds (overridable by `CODEX_WATCHDOG_PROBE_GAP`) it probes once more; only two failed probes mean model/auth-level refusal, write `status:"refused"`, and exit 4.

Each attempt writes `<worktree>/.review/ISSUE-<N>-RUN.json` with `artifact_type: "codex_run"` and status `running | exited | killed_stall | refused | exhausted` (schema `schemas/run.schema.json`). This marker is a dispatch liveness record, not verification evidence.

**RUN.json terminal-state contract — read this before writing any polling logic.** `status:"running"` while the codex-safe process is alive and still attempting. Terminal states are `status:"exited"` (codex process finished; `exit_code` present — `exit_code === 0` means the *process* finished cleanly, it does **not** mean the task succeeded; task success is judged by commits + a canonical `VERIFY.json` artifact, never by exit code alone), `status:"killed_stall"` (watchdog killed it for no progress), `status:"refused"` (probe says model/auth-level failure; retry is futile), and `status:"exhausted"` (retries used up). There is no `"completed"` or `"failed"` string anywhere in this schema — do not poll for them. A `.review/ISSUE-<N>-BLOCKER.json` file appearing instead of/alongside `RUN.json` is a scoped abort (codex chose to stop, not crash).

### `cmux-dispatch.sh` — the mandated way to dispatch into a visible cmux workspace

**Incident (2026-07-13):** a dispatch ran `cmux new-workspace --command "codex-watchdog.sh --issue 147 --prompt-file .review/ISSUE-147-PROMPT.txt --cwd <worktree>"` but forgot `--cwd <worktree>` **on the cmux workspace itself**. The workspace opened in cmux's default project dir; the watchdog validated the relative `--prompt-file` against *that* dir instead of the intended worktree and hit `exit 2` before writing any artifact. Nothing recorded the failure except pane scrollback — no `RUN.json`, no `BLOCKER.json`. Separately, the CONDUCTOR's poller assumed terminal values like `"completed"`/`"failed"`, which don't exist in this schema (see the contract above), so it never noticed the dispatch was dead.

Do not hand-roll `cmux new-workspace`/`cmux workspace create --command "codex-watchdog.sh ..."`. Use `scripts/cmux-dispatch.sh --issue <N> --worktree <path> [--prompt-file <p>] [--name <workspace-name>] [--model <M>] [--effort <E>] [--read-only] [--first-progress-timeout <secs>] [--stall-timeout <secs>] [--poll-timeout <secs>] [--dry-run]` instead:

- Defaults: `--prompt-file` = `<worktree>/.review/ISSUE-<N>-PROMPT.txt`, `--name` = `codex-<N>`, `--poll-timeout` = `300`.
- **`--model`/`--effort` are forwarded through `codex-watchdog.sh` to `codex-safe.sh`; pin them on every dispatch.** Until 2026-07-15 neither script accepted them, so a dispatched implementer silently ran on whatever `~/.codex/config.toml` had as its default (`gpt-5.6-sol` at `low`) instead of the "Model Allocation" role assignment. That is worse than a cost bug: it inverts the invariant that the REVIEWER must sit one tier ABOVE the implementer — with the implementer already on `sol`, no compliant reviewer model exists. Omitting the flags still falls back to the config default, so omission is a defect, not a default. `codex-safe.sh` remains the sole owner of the policy cap (5.6 above `medium` is refused).
- **`--read-only` is forwarded to the watchdog, which gives codex-safe a heartbeat file so deliberate read-only work remains live without writing task files.**
- **`--first-progress-timeout` and `--stall-timeout` are forwarded only when supplied; the watchdog consumes those liveness budgets rather than passing them to codex-safe.**
- Validates the worktree exists and is an actual git worktree, the prompt file exists, and (unless `--dry-run`) that `cmux` is on `PATH` — all before touching cmux, with a clear error naming what's wrong.
- Absolutizes both the worktree and prompt-file paths, then builds `NODE_OPTIONS= <abs codex-watchdog.sh> --issue <N> --prompt-file <abs-prompt> --cwd <abs-worktree>` and launches it via `cmux workspace create --name <name> --cwd <abs-worktree> --command <that command>` — so `--cwd` is always set on the cmux workspace, closing the exact gap in the incident.
- `--dry-run` prints the exact `cmux workspace create ...` invocation and exits 0 without calling cmux — the test seam.
- On a real run it polls every 5s up to `--poll-timeout` for `<worktree>/.review/ISSUE-<N>-RUN.json` or `-BLOCKER.json`. A **fresh** artifact appearing means the dispatch is alive (or scoped-aborted) and it exits 0. Timeout with no fresh artifact means the watchdog never started — it exits non-zero with a diagnostic pointing at the workspace pane.

**Same-issue re-dispatch is a supported pattern** (e.g. a second prompt file for the same issue after a first attempt), and it has a trap: the previous run's `RUN.json` (typically `status:"exited"`) is still sitting in `.review/`. On `cmux-dispatch.sh`'s first production use (issue 147 re-dispatch, 2026-07-13) the poll accepted that stale file immediately and reported success before the new watchdog had even started — had the new watchdog died pre-start, the dispatch would still have claimed success. The script now records the identity (mtime + `started_at`) of any pre-existing `RUN.json`/`BLOCKER.json` **before** creating the workspace, prints `waiting for fresh RUN.json (stale one from <started_at> present)`, and the poll only accepts an artifact whose identity changed (every watchdog attempt rewrites `started_at`) or that newly appeared. A stale artifact alone times out non-zero, exactly like no artifact.

### Sandbox network containment — why the worker can't self-verify DB tests (v0.3)

`workspace-write` blocks **all** network egress, including **loopback**. A v0.3 spike proved this is total: a probe run inside the sandbox cannot `connect()` even to `127.0.0.1` (TCP) **nor** to a Unix-domain socket placed inside the writable root — both fail with `EPERM`. (Repro: host-side relay `scripts/uds-pg-relay.mjs` + in-sandbox `scripts/__tests__/uds-sandbox-probe.mjs`; the TCP-loopback case is the live layer of the network-deny smoke below.) So there is **no containment-preserving way** to give a sandboxed worker access to the local Postgres on current codex (0.133.0):

- A loopback-only network allowance is **not shipped** (codex issue #6737 open; #6807 closed-folded). `network_access` is all-or-nothing.
- The "UDS proxy" idea (front Postgres with a socket in a writable root) was **rejected** — Seatbelt denies AF_UNIX `connect()` too.
- A full-egress `dbtest` profile (`network_access=true`) was **rejected** as a standing workflow: with the principled UDS fallback dead, it is a pure risk-trade (tests run arbitrary dep/app code → exfil surface), and VERIFIER already runs the same tests cleanly outside the sandbox.

**Decision: status-quo.** The worker stays network-denied; the **VERIFIER runs DB tests outside the sandbox** (see VERIFIER protocol). Revisit only when (a) codex ships loopback-only network (#6737), or (b) data shows DB-test verifier churn is a real throughput bottleneck.

Hardening shipped alongside this decision: `scripts/__tests__/sandbox-network-deny.smoke.sh` guards against regression. Layer 1 (offline) asserts `codex-safe.sh` still pins `--sandbox workspace-write` and grants no `danger-full-access`/`network_access`; Layer 2 (opt-in, `RUN_LIVE_SANDBOX_PROBE=1`) runs `scripts/__tests__/net-deny-probe.mjs` inside the sandbox and asserts loopback is `BLOCKED`. Machine-global Codex defaults are operator configuration and are not installed or assumed by this repository.

## Worktree Prep

A fresh `git worktree` is **NOT dispatch-ready**: it has no `node_modules` and no gitignored `.env`. Because the codex sandbox blocks network, deps and env cannot self-provision inside it — provisioning MUST happen host-side, **outside the sandbox**, before dispatch.

Run `scripts/prepare-worktree.sh <wt>` on the host. It installs deps from the frozen lockfile (`pnpm install --frozen-lockfile`) and copies env files (`.env`, `apps/backend/.env`), printing every copied key (values redacted) and loudly flagging high-risk keys (DATABASE_URL, WORKSPACE_ID, PORT, anything with STORAGE/BUCKET/S3/SECRET/TOKEN/KEY/PASSWORD/CREDENTIAL).

`scripts/cmux-cluster.sh` **refuses to launch** if `<wt>/node_modules` or `<wt>/.env` is missing, naming what's missing and pointing at prepare-worktree.sh.

**Env is shared-state coupling.** Copying one `.env` into multiple worktrees points them all at the same mutable DATABASE_URL / WORKSPACE_ID / storage bucket — parallel clusters corrupt each other. When ANY other prepared worktree already exists (>=1 other), prepare-worktree.sh refuses to copy env unless you pass `--env-profile <path>` (per-worktree env file, recommended) or `--allow-shared-env` (explicitly accept the risk). So the first worktree prepares without a flag; the second and beyond require one. Profile mode writes the same profile to both `<wt>/.env` and `<wt>/apps/backend/.env` so a stale backend env cannot override the profile later; the profile must therefore be self-contained for the target's verification needs.

**Rebasing in-flight worktrees when the integration branch advances.** When a merge lands on the integration branch (commonly `develop`), in-flight `feature/*` worktrees drift behind it. From the branch that just advanced, run `scripts/rebase-inflight.sh --onto <branch>` (default onto = current branch) to rebase every sibling feature worktree. It is **dirty-safe** — it REFUSES to rebase a worktree with uncommitted changes (loud SKIP, never clobbers work) — and **conflict-aborting** — on a rebase conflict it runs `git rebase --abort` so a worktree is never left mid-rebase; that worktree is flagged for a manual rebase and the others continue. A single failure never hard-fails the command (exit 0; exit 1/2 only on lock contention or bad args). After a successful rebase it prints a generic suggestion to run `scripts/verify.sh <test-name-filter>` for the affected area — it never auto-runs tests, and it deliberately does NOT emit a package name (the arg is a vitest name/path filter, not a package selector). A `mkdir`-based lock under `.review/.rebase-inflight.lock` serializes concurrent invocations. A host repository may add a warn-only post-merge hook that points at this script, but automatic rebasing inside a hook is too risky; rebasing remains an explicit operator/CONDUCTOR action.

**Parallel-cluster DB isolation (Trial 3).** Running two clusters in parallel requires **one throwaway database per cluster** — NOT a shared DB with distinct schema or `WORKSPACE_ID`. The backend hardcodes Postgres schemas `core`/`permission` (drizzle `schemaFilter`), and instance-global state (`pg_locks`, sequences) plus shared schema objects mean schema/workspace isolation only separates workspace-scoped *rows*, not the tables/locks two suites contend on. Procedure: `createdb -O fops_migrate feedbackops_<cluster>` (needs a superuser — `fops_migrate` lacks `CREATEDB`), `drizzle-kit migrate` with `DATABASE_URL_MIGRATE` → the new DB, then **seed with BOTH `DATABASE_URL` and `DATABASE_URL_MIGRATE` targeted at it** (the seed's VOC owner team is created via the migrate role). Point each worktree at its DB via `prepare-worktree.sh --env-profile`. Validated: `create-voc` 31/31 in two DBs concurrently, zero cross-contamination. See `docs/agents/workflow-trial-log.md` Trial 3.

## Artifact Lifecycle

Every `.review/ISSUE-*.json` carries `lifecycle: draft | active | superseded | final`. Superseded files MUST be ignored by readers. See `docs/agents/artifact-lifecycle.md`.

### Canonical ROUND-STATE

CONDUCTOR maintains one `.review/ISSUE-<n>-ROUND-STATE.json` as the normative contract state from dispatch 0. It replaces amendment prose; reviewers never reconstruct an effective contract by merging prompt fragments. The artifact contains the current contract, acceptance criteria, decisions, prior findings, commit scope, live-probe results, and artifact pointers. Its schema is `schemas/round_state.schema.json`.

CONDUCTOR is the sole writer. `revision` increments whenever the normative contract or acceptance criteria change, with the reason recorded in `decisions`. CODEX, REVIEWER, and VERIFIER consume but do not edit it. The acceptance manifest is not a separate file: it is the `acceptance.criteria[]` view at the ROUND-STATE `revision`. A task narrative is at most 2 KB and carries only current intent/delta, failing AC ids, and evidence pointers; it must not restate normative criteria or allowlists.

## Workflow Tax Brake

If a Trivial issue routes through more than CODEX + VERIFIER, the workflow has failed and must be re-evaluated. The workflow exists to ship faster, not slower.

### Pre-review AC-ID gate

Run the deterministic coverage check against the exact ROUND-STATE revision pinned by the dispatch before review:

```bash
scripts/ac-check.sh \
  --round-state <ISSUE-N-ROUND-STATE.json> \
  --manifest-revision <revision> \
  --tests <discovered-tests.txt>
```

The gate first validates the complete artifact against the canonical schema and runs `artifact-fresh.sh`; partial, superseded, wrong-writer, or base-stale state is rejected. `--manifest-revision` must then equal the artifact's top-level `revision`; a mismatch is stale and fails before AC mapping. AC ids come from `acceptance.criteria[].id`. The tests file contains actually discovered test names or paths. Duplicate or undiscovered ids fail the gate; ID matching is boundary-aware, so `AC-10` cannot satisfy `AC-1`. This proves only that every declared id is represented in discovery output—it does not prove behavior, so REVIEWER and VERIFIER still run.

### CONDUCTOR completion calculation gate

Before REVIEWER consumes a worker handoff, CONDUCTOR runs:

```bash
scripts/completion-check.sh \
  --round-state <ISSUE-N-ROUND-STATE.json> \
  --manifest-revision <revision>
```

The command validates the canonical ROUND-STATE and freshness, calculates `base_sha..HEAD` in its declared live worktree, and compares that independent diff against `contract.touch_allowlist`. It directly executes the target profile's `contract.test_discovery_command` in that worktree, compares `acceptance.criteria[].id` against its output, and compares its non-empty record count exactly against canonical `acceptance.expected_test_count`. When `contract.chunk_boundary` is present it also rejects compile consumers outside the touch allowlist, runs the target-native full typecheck, and emits only the current chunk's triggered `review_obligations[]` in declaration order. It does not consume RUN.json, PR-DRAFT claims, diffstat prose, a supplied discovery file, or a worker's reported test count. Exit 1 emits a machine-readable JSON `mismatches` list and hard-stops review; exit 2 emits a stable machine-readable error code for invalid input, an uncheckable state, failed discovery, or an invalid chunk boundary and also fails closed. The target profile owns both commands and must emit one record per discovered test; the reusable core does not hard-code Vitest. This gate establishes completion-contract coverage and review scope only; the REVIEWER closes each emitted watch through its declared checklist selector, and independent verification remains required for behavioral correctness.

### Test-matrix row contract

The authoritative acceptance contract is also the test-matrix template: every test-matrix row is a canonical `acceptance.criteria[]` entry; its `id` is the sole AC-ID authority, and its `statement` contains an explicit precondition and observable checkpoint. Do not use cited authoritative detail as a substitute for required inline content: the canonical `statement` is the complete row authority. An expected status alone is not a checkpoint: the precondition must make the target behavior reachable, and the checkpoint must observe the state or output that proves it occurred.

When a row exercises a privacy boundary, its canonical `statement` also requires a **positive field allowlist assertion**—that the returned object contains only the permitted fields, not merely assertions that named sensitive fields are absent. Clarify privacy applicability explicitly only when it would otherwise be ambiguous; non-privacy rows need no non-applicability ceremony. `ac-check.sh` deliberately enforces only AC-ID discovery coverage; REVIEWER audits the precondition, checkpoint, and applicable allowlist for non-vacuousness, and this template never thins the independent verifier or final review.

Use this compact inline statement shape: `precondition | observable checkpoint | positive field allowlist (when privacy-relevant)`. It is a contract template inside the existing `statement`, not an analyzer input or a new schema field.

## VERIFIER protocol

VERIFIER MUST confirm green by running `scripts/verify.sh <filter>` — never by eyeballing test output and never by running a bare `pnpm test`. A bare `pnpm test` is forbidden as a green signal: in a trial it silently skipped all 31 integration tests (missing `DATABASE_URL`/`WORKSPACE_ID`) and a fully-skipped suite looked like a pass — a false green.

VERIFIER and REVIEWER must be different agents/sessions from the implementer. A worker's own "I ran tests" claim is not verification evidence; the canonical evidence is the VERIFIER-owned `ISSUE-<n>-VERIFY.json` plus the review artifact where applicable.

The verify oracle currently assumes a pnpm workspace package named `backend` tested with Vitest. The `<filter>` arg is a **Vitest test name/path filter scoped to the backend package** (it matches test file paths/names within backend), **not** a package selector — e.g. `scripts/verify.sh create-voc` runs backend tests whose path/name matches "create-voc"; passing a package name like `backend` would be treated as a name filter and likely match nothing. `scripts/verify.sh --typecheck` likewise assumes the target has `pnpm --filter backend run typecheck`. Generalizing these commands is deferred until there is a second real target and fixture.

`scripts/verify.sh` loads env (`.env` and `apps/backend/.env` if present), runs the scoped vitest filter via the JSON reporter, and classifies the result. It treats as a **FAIL**:

- a fully-skipped suite (`numPassedTests + numFailedTests == 0` — discovered but pending),
- any failed test (`numFailedTests > 0`),
- a failed suite (`numFailedTestSuites > 0` — setup/import failure even with 0 failed tests),
- a top-level `success === false`,
- any `testResults[]` entry with `status === "failed"`,
- a non-zero vitest exit code (the run crashed; JSON may be stale/partial),
- a missing, empty, or unparseable report (fail closed).

A PASS is reported only when none of the above trip.

### Verifier hardening (v0.3)

Because the VERIFIER runs tests **outside** the sandbox (full host access), the filter-mode run is hardened:

- **Local-DB guard (fail closed).** `verify.sh` extracts the `DATABASE_URL` host and **refuses with `exit 3`** if it is not local (`localhost`/`127.0.0.1`/`::1`/`[::1]`/empty unix-socket form). The verifier must never run against a remote/staging/prod DB.
- **Least-privilege role.** Set `VERIFY_DATABASE_URL` (and optionally `VERIFY_DATABASE_URL_MIGRATE`) to point the run at a low-privilege role; it overrides `DATABASE_URL` for the run only. If the effective role is the superuser `postgres`, `verify.sh` prints a `WARN` recommending `fops_app`. Pair with an **ephemeral per-issue DB** (see Parallel-cluster DB isolation) so a verifier run can never mutate shared state.
- **No silent `.env` fallback in issue mode (fail closed, `exit 4`).** When `VERIFY_ISSUE` is set but `VERIFY_DATABASE_URL` is unset or empty, `verify.sh` **refuses with `exit 4`** ("refusing to fall back to .env DATABASE_URL") instead of inheriting the worktree `.env`'s `DATABASE_URL`. Incident (2026-07-13): an upstream `eval $(prepare-verify-db.sh ... | tail -1)` of empty stdout left `VERIFY_DATABASE_URL` unset, the suite ran against the shared dev DB `feedbackops`, and produced a garbage FAIL artifact. Run `prepare-verify-db.sh` and export its printed `VERIFY_DATABASE_URL` first.
- **Effective DB assertion.** Before running Vitest, `verify.sh` prints the effective database host/name/role injected into the child process, using the same redacted parser that writes `db_target` into the VERIFY artifact. Passwords are never printed or recorded.
- **Env scrub (default-deny allowlist).** The vitest child runs under `env -i` with only an allowlist passed through (`PATH HOME SHELL TERM LANG LC_ALL TMPDIR TMP USER LOGNAME PWD NODE_OPTIONS NODE_ENV DATABASE_URL DATABASE_URL_MIGRATE WORKSPACE_ID CI`, plus `PNPM_*`/`npm_config_*`, plus any names in `VERIFY_ENV_ALLOW`). Arbitrary host secrets (tokens/keys) do **not** leak into test/app code.
- **Canonical provenance artifact.** When `VERIFY_ISSUE=<n>` is set, `verify.sh` writes `.review/ISSUE-<n>-VERIFY.json` (schema `schemas/verify.schema.json`, `artifact_type: "verify_result"`, `producer_role: "VERIFIER"`): branch, `head_sha`, cwd, `verify_cmd`, `env_profile`, `db_target` (host/database/role — **never a password**), `verdict` (passed/failed/pending/exit_code), `classifier` (PASS/FAIL), `created_at`. This makes verifier output the canonical readiness signal, not worker prose. If a green run cannot write and re-read a valid artifact, the run fails closed with exit 5; evidence is the product. If the test run is already failing, an artifact-write failure preserves that failing classifier exit and never turns it green. With `VERIFY_ISSUE` unset, behavior is unchanged (no artifact).

### Per-issue verify DB provisioning (`prepare-verify-db.sh`)

`scripts/prepare-verify-db.sh --issue <N>` provisions the ephemeral `verify_issue_<N>` database and prints `VERIFY_DATABASE_URL=<url>` as its **last stdout line** — that line is the contract; consumers capture it with `eval $(... | tail -1)`. Two hardening rules (both from the 2026-07-13 incident):

- **Fail closed on any mandatory step.** If the base-url connection, `CREATE DATABASE`, or a supplied `--migrate-cmd`/`--seed-cmd` fails, the script exits non-zero and the `VERIFY_DATABASE_URL` line is **never printed** — printing it for a DB that doesn't exist poisons every downstream eval pipeline. (Previously a failed create was warned past and the line still printed.)
- **All DDL goes through `psql`, never the `createdb`/`dropdb` clients.** Those clients do not accept `-d <url>` (their `-d`-shaped option is `--maintenance-db`); on modern pg clients the old `createdb -d "$BASE_URL"` invocation failed with `invalid option -- d`. `psql` accepts the connection URI directly.
- **The admin URL's role must have the `CREATEDB` privilege.** On a stock `docker-compose.dev.yml` box only `postgres` (port 5434) can create databases — `fops_migrate` cannot. Use e.g. `PGADMIN_URL=postgres://postgres:...@localhost:5434/postgres` for provisioning, then hand the tests a low-privilege role via `VERIFY_DB_ROLE`/`VERIFY_DATABASE_URL`.

### Baseline-aware typecheck

Typecheck is **baseline-aware**: VERIFIER runs `scripts/verify.sh --typecheck`. It runs `pnpm --filter backend run typecheck`, extracts `error TS…` lines, and diffs them against `.review/typecheck-baseline.txt`. It fails **only** on errors absent from that baseline — i.e. NEW compile errors the change introduced. A pre-existing baseline error is never permission to merge a NEW compile error. If the typecheck command itself fails without any parseable `error TS...` lines, the oracle fails closed; an empty parsed result from a crashed command is not a pass.

Refresh `.review/typecheck-baseline.txt` (noting it in the commit) **only** when a pre-existing error is independently fixed — never to silence a new error.
