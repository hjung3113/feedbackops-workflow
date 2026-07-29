# Multi-Agent Workflow — Operating Playbook

This file is the detailed operating authority for the transport-selectable Orca/cmux × Codex/Claude Code/OpenCode workflow. The project skill at `.claude/skills/agent-workflow/SKILL.md` is deliberately a thin router into this playbook; do not duplicate model maps, incident contracts, or verifier rules there.

## Distribution, runtime, role, and transport axes

`install-into.sh <target> --profile feedbackops|generic` is the sole
distribution selector. `feedbackops` preserves the named compatibility
adapters and their pnpm, Vitest, PostgreSQL, tracker, labels, domain, layout,
and maintainer conventions. `generic` installs target-neutral docs and skill
only; it inherits none of those facts. The installed generic assets under
`scripts/install-profiles/generic/` are the generic distribution authority.

Dispatch has independent distribution profile, runtime
(`codex|claude|opencode`), role
(`conductor|architect|implementation|reviewer|verifier|visual|release`), and
transport (`cmux|orca`) axes. Profile supplies target adoption facts; runtime
supplies execution/isolation capability; role supplies workflow responsibility;
transport supplies pane/worktree lifecycle. None implies another. CLI >
environment > target config applies independently to transport, runtime, and
role. Legacy omitted runtime/role resolve to Codex/implementation only for
compatibility.

Before admission, the public capability probe and shared core prove selected
runtime/role/mode and selected transport. Missing capability, unsupported
isolation, or invalid configuration fails before admission with a
machine-readable reason; no runtime, role, model, or transport fallback is
permitted. RUN/receipt runtime, role, and observed-version fields are
diagnostic provenance, never completion authority: only fresh canonical REVIEW
and VERIFY evidence bound to live HEAD completes work.

OpenCode requires an explicit deny-first permission JSON. Both top-level
`permission` and the named primary `agent["agent-workflow"].permission` deny
`*`, `external_directory`, `webfetch`, and `websearch`; write explicitly allows
`edit` and `bash` in both scopes so implementation can build, test, and use Git,
while read denies both. The adapter supplies that exact
JSON through `OPENCODE_CONFIG_CONTENT` and invokes `opencode run --agent
agent-workflow`; it never accepts OpenCode's default-agent fallback. A model
choice cannot waive this gate. Codex, Claude Code, and OpenCode may each
conduct or perform any role only after their own capability probe passes.

The coordination model consumes one target-owned profile (`schemas/target-profile.schema.json`) for target facts. `target-verify.sh` is target-neutral; `verify.sh` remains the explicit FeedbackOps pnpm/Vitest/Postgres compatibility adapter. `prepare-worktree.sh` and `tier-probe.sh` retain their legacy adapters in this wave; profile-driven setup/tier migration is deferred to avoid two competing partial parsers. Read `.claude/skills/agent-workflow/references/adoption.md` before adoption.

## Product home and repository context

The workflow product home is the physical parent of the running command's `scripts/` directory. Scripts, schemas, and docs are sibling product resources in source, installed, and exported layouts; `ac-check.sh` and `completion-check.sh` resolve the canonical schema through this interface.

`install-into.sh` resolves `PRODUCT_ROOT` from its own location. An enclosing Git root, when discoverable, is optional `REPOSITORY_ROOT` context used only for repository-specific safety checks. Missing Git metadata does not make an exported product invalid. Target runtime evidence remains target-owned under `<target>/.review`; it is not a product schema directory.

Fresh installation always creates self-contained real-directory copies at the four managed leaves. It never creates source-path symlinks and never skips an existing leaf; any existing or partial topology stops with an explicit `--upgrade` instruction.

`install-into.sh <target> --upgrade` recognizes a complete current copy or a complete correlated current/legacy absolute-symlink installation, including dangling source paths. Mixed tree/link topologies fail closed. It stages all four source trees inside the target before mutation, backs up the old leaf nodes under `.review/agent-workflow-install-backups/`, then swaps all four. Changed content in a recognized copy remains in that backup. A failure verifies restoration of the prior nodes; if the filesystem refuses restoration, exit `70` reports the retained backup for manual recovery. Partial or structurally unrecognized trees, uncorrelated links, and a symlinked backup parent fail closed. The removed `--mode`, `--force`, and `--migrate-legacy` interfaces never mutate and point operators to `--upgrade`.

Managed parent paths (`.agent-workflow`, `.agent-workflow/docs`, `.claude`, `.claude/skills`, and `.review`) must be real directories inside the target. The installer rejects symlinked parents before install/upgrade recognition or mutation, preventing managed writes or removals from escaping the target root.

Product containment, classified legacy-path evidence, and maintainer-file non-leakage are release concerns owned by infrastructure outside this distributable product and are not installed into targets. Product-local Markdown links must resolve from both source and portable installed paths. Legacy symlink recognition is an upgrade-only compatibility adapter, not a product-home fallback or install mode.

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

**Escalation rule:** if a Trivial or Standard issue's actual touch set hits any Full Cluster trigger (e.g. `packages/shared/*`, migrations), CODEX MUST abort with a `blocker` artifact. Record the exact Git `HEAD` observed at abort time in `head_sha`, set `reason_code` from the enum (`tier_escalation_required` for this case), and put the ACTUAL out-of-scope files/symbols you hit into `blocking_fact` — never copy the dispatch prompt's example phrasing. In trial #1 CODEX parroted the canned phrase `"touches packages/shared"` straight from the prompt even though the real cause was backend modules (`src/voc`, `src/permissions`); the structured `reason_code` + `blocking_fact` fields exist to kill that leak.

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

For the actual write-capable redispatch, pass the same inputs to the public entry point with an explicit transport:

```bash
scripts/agent-workflow.sh dispatch --orchestrator <cmux|orca> \
  --issue <N> \
  --worktree <worktree> \
  --round-state <ISSUE-N-ROUND-STATE.json> \
  --manifest-revision <revision> \
  --model <pinned-model> \
  --effort <pinned-effort>
```

Every write launch atomically acquires a pre-cmux attempt marker, so concurrent initial launches admit exactly one process and a crash before RUN/BLOCKER creation cannot make the next launch look initial. When that marker, a same-issue RUN/BLOCKER, or canonical failure history exists, `cmux-dispatch.sh` refuses write dispatch without state/revision inputs. Before any write admission it proves every `touch_allowlist` path/glob matches at least one `base_sha` tree path; future files require exact absent `new_file_allowlist` entries and cannot be authorized by a glob. It executes `redispatch-check.sh` immediately before cmux creation, requires at least one classified active failure (or one `round_control.blocker_recovery.status:"ready"` recovery), binds the result's issue and real worktree to the CLI target, and atomically creates an immutable issue/ordinal admission directory under the Git common dir. Every current normal and integrated marker is journalled in a private directory before atomic rename into its visible name. Integrated fix first publishes its issue-wide prepared singleton transaction, then its paired ordinal, so a crash at any visibility boundary repairs incomplete records while an advanced/committed admission is never cleared. Recovery reclaims only a singleton carrying that current transaction identity; a metadata-free pre-transaction singleton is a legacy consumed sentinel and is preserved fail-closed. The redispatch gate requires unique, strictly ordered active failure ordinals and binds `last_admission_key` to exactly one same-issue failure ordinal; it excludes only that matching prepared transaction ordinal from consumed history until lock recovery finalizes it. Stale-lock recovery never reclaims a lock owned by a live process solely because its mtime is old. Excluding mutable revision, mode, and failure IDs prevents replay after edits, while the common-dir location survives worktree recreation. A crash after consumption requires investigation and a new classified failure or explicit blocker rather than deleting the marker. `--dry-run` evaluates but never consumes or recovers admission. Read-only seats remain outside the implementation circuit.

Each immutable failure entry has one `primary_origin`—`environment`, `dispatch_contract`, `implementation`, `test_oracle`, `verification_harness`, or `integration_drift`—plus optional unique `secondary_origins[]`, failed AC ids, an owner, a typed next action, and evidence pointers bound to content hash and observed HEAD. Non-diagnosis routing is fixed respectively to `environment_fix`, `contract_fix`, `implementation_fix`, `oracle_fix`, `harness_fix`, or `integration_fix`; model escalation is never a remedy. `diagnosis` is only dispatch-admissible after the circuit trips; below threshold it returns `routing_required` until concrete origin-compatible action is selected. Preserve failed evidence before a later run replaces it: REVIEW publication retains `ISSUE-N-REVIEW-<reviewed_head_sha>.json`, and round-state evidence should cite that immutable snapshot.

After that preservation, and **before implementation redispatch**, CONDUCTOR collects the failure-class-specific evidence on the host. This is a required diagnosis step after every failed VERIFY or REVIEW, not work delegated to the implementation worker:

- **Test failure:** the failing host verification command, its exit status, and the exact failing test/assertion output.
- **Database failure:** the VERIFIER's host-side `db_target`, `clean_state`, and the relevant typed failure diagnostic or database-test output.
- **Runtime failure:** a host reproduction command, exit status, and the relevant service/process log or observed response.
- **Visual failure:** the VISUAL-REVIEWER's host-browser screenshot/reference and the failed interaction-script step with its observed result.
- **Review failure:** the immutable failed REVIEW snapshot's exact finding/checklist text, including its cited file/line or acceptance criterion.

CONDUCTOR places the collected material **verbatim** in the next implementation prompt, with a clear statement that it is host-collected evidence to address. Do not paraphrase it into a diagnosis, omit failing output, or ask the worker to recreate it. Database, runtime, and visual failures remain host-only checks: the worker sandbox cannot self-verify them and worker prose or local substitutes cannot replace the host evidence.

The evidence schema's `blocker` union remains available for all artifact relationships, but the redispatch gate recognizes a canonical BLOCKER as the **sole** failed-round evidence only when `primary_origin:"dispatch_contract"` and `next_action.kind:"contract_fix"`; it accepts only `lifecycle:"active"` or `"final"`, schema-validates the artifact, verifies issue and content hash, resolves the referenced commit, and requires the reference `head_sha` to equal the producer's embedded `head_sha`. A pre-existing malformed worker BLOCKER follows the explicit quarantine path: raw bytes are retained under `ISSUE-N-BLOCKER-QUARANTINED-<sha>.json`, `round_control.blocker_recovery` records the reason/digest, and exactly one fresh host-ordinal admission is allowed without treating the raw copy as worker evidence. A `superseded` BLOCKER deterministically returns `superseded_evidence_artifact`; legacy BLOCKER files without `head_sha` must be regenerated, and every other origin still requires failed VERIFY or REVIEW. Coherent failure means VERIFY `classifier:FAIL` plus nonzero exit or positive failed count, or REVIEW `fail`/`blocked`. Closing a failure normally requires `closed_by.closes_ac_ids` to equal its AC set. VERIFY closure needs a **passing run** whose `verify_cmd` contains canonical `contract.verify_filter` as a command token. REVIEW closure needs `lifecycle:"final"`, `status:"pass"`, every checklist item `met:true`, and exact `failure:<id>:<comma-separated-ac-ids>` checklist identity. A later failing REVIEW may use `closed_by.kind:"superseded_by"` with a checked immutable REVIEW reference and explicit `met:true` checklist assertion to close a non-empty subset of prior AC ids; it remains failing evidence for its own later round. A failed predicate returns exit 2 with `failure_closure_not_verified` and stable `errors[0].detail` of `review_lifecycle_not_final`, `review_status_not_pass`, or `review_checklist_unmet`. The PASS HEAD strictly descends from every failed artifact HEAD, remains an ancestor of live HEAD, and VERIFY matches the live branch, preventing unrelated, stale, or sibling-branch evidence from resetting the active sequence. `live_probe`, `dispatch_log`, and `diff` references are informational only and cannot satisfy failed-round or closure evidence.

The gate trips over one explicit active cycle: verified-closed history must be a prefix, followed by the contiguous open-failure suffix. Interleaved open/closed entries are invalid rather than being filtered into false consecutiveness. Two consecutive open failures with the same primary origin, or two completed redispatches before a proposed third redispatch, returns `diagnosis_required` and forbids another normal implementation dispatch. The initial implementation is ordinal 1; ordinary redispatches are ordinals 2 and 3, so another dispatch after three active recorded failures is the forbidden third redispatch. Watchdog attempts, refusal probes, RUN states, heartbeats, and process retries never increment these ordinals. An active `security_stop` returns immediately at any count.

A tripped circuit admits at most one `integrated_fix` batch. ROUND-STATE diagnosis records are an ordered prefix: (1) recheck oracle and contract first, (2) capture one reproducible hard fact, and (3) identify a passing analog with the fixed `guess_forbidden_copy_passing_analog_to_parity` instruction. This means: do not guess; copy the known-green wiring to parity; if it remains red, report a blocker instead of committing another speculative patch. The optional singleton `manifest_update` permits at most one revision increment and its `to_revision` must equal the current ROUND-STATE revision. The singleton integrated batch must cover every open failure while retaining each failure's AC ids and evidence. `cmux-dispatch.sh` acquires the issue-wide singleton before the ordinal marker for integrated mode and rolls the singleton back if ordinal acquisition fails, so no failed path leaves one marker without its pair; once the batch status is `used`, `redispatch-check.sh` also returns `diagnosis_exhausted`. Another implementation batch needs an explicit new decision or blocker, not an automatic redispatch.

The gate is read-only and deterministic. Exit 0 allows exactly the emitted `dispatch_mode` (`normal` or `integrated_fix`); exit 1 denies dispatch with the calculated trigger and obligations; exit 2 rejects malformed, stale, contradictory, or uncheckable state. It never reads prompt prose, model telemetry, RUN/HEARTBEAT, stderr text, or pane state. ROUND-STATE remains the sole ledger and CONDUCTOR its semantic owner; in read-only conductor-control mode, the locked host publisher is the sole byte writer after validating the conductor's proposal.

For `closed_by.kind:"superseded_by"`, a subset closure is valid only when every failed AC not listed in `closes_ac_ids` appears on a later **active** failure. This prevents partial supersession from silently deleting unresolved acceptance work. Host dispatch ordinals are contiguous: `next_dispatch_ordinal` must be exactly one more than the greatest recorded or durable consumed ordinal. `last_admission_key` must name this issue and a recorded failure ordinal before the next dispatch; it is never a free-form high-water marker.

### ARCH feasibility evidence

Before ARCHITECT locks a decision for a Full Cluster change involving migrations, authorization, persistence constraints, or another repository-dependent capability, attach a feasibility appendix to the authoritative contract. It must cover the actual grants/privileges, the migration principal's capabilities, the immediately preceding migration and journal conventions, and the relevant uniqueness constraints; an inapplicable item needs an explicit reason, not an assumption.

For every live or repository observation, record the exact command and a concise observed result in the existing canonical ROUND-STATE `live_probes[]`; the appendix interprets that evidence, while `live_probes[]` remains the durable command/result record. A missing safe read path or an infeasible capability is a blocker or ARCH decision, never a speculative implementation instruction; this front-loads fact finding so verification confirms the design rather than discovering that it cannot run.

Use one appendix row per concern: `concern | exact command | concise result | decision impact`. The four required concerns are `grants/privileges`, `migration principal capability`, `prior migration/journal convention`, and `relevant uniqueness constraint`; the exact command/result pair is copied into `live_probes[]`, not a new artifact field.

## Model Allocation — project-owned defaults with evidence-gated adaptation

The installed `.agent-workflow/model-alloc.json` is the project-owned allocation contract; its schema is `schemas/model_alloc.schema.json`. The default table carries `source: "livebench"` and `release: "2026-06-25"` alongside the capability and price data, so a benchmark refresh replaces data rather than dispatch code. `model-alloc.sh` validates every runtime config through that same schema before output or dispatch; missing project config safely uses the toolkit default, while malformed existing config fails closed. Fresh install seeds the file and `--upgrade` preserves it (with a warning rather than an implicit migration). Its `prompt_authoring.target_tokens` is the single project-owned prompt-compression target; it is guidance/telemetry, never a dispatch rejection.

| Role | Default allocation |
|---|---|
| CONDUCTOR | Opus medium |
| ARCHITECT / adversarial co-design | terra medium; sol medium for exported-contract decisions |
| CODEX implementation | terra low; luna low only for small trivial touch sets |
| REVIEWER / VISUAL-REVIEWER | Opus medium; visual recheck may use Sonnet high |
| Final exported-contract gate | sol medium |
| VERIFIER log classification / mechanical edits | luna medium / luna low |
| Fable 5 | not allocated |

`scripts/model-alloc.sh --role implementation|reviewer [--evidence <canonical-json>]` emits JSON with implementation, review, contract-gate model/effort values and rationale. Its evidence must explicitly contain changed lines, file count, review round, `consecutive_finding_rounds` (unique adjacent completed rounds ending at the supplied round), blocker state, and touch set. Without it the script makes **no adaptive change**; with it, an exported contract, blocker, or two consecutive finding rounds promotes low implementation effort to terra medium without lowering a large-touch terra high allocation; a small one-file touch can use luna low, and a re-review lowers review effort before changing models. The allocation uses Agentic Coding for implementation and static Coding + Reasoning for review/contract decisions; benchmark scores guide ordering, not hard telemetry thresholds.

### Local model/task telemetry

Telemetry is local, offline, and opt-in. `scripts/telemetry.sh collect` validates canonical ROUND-STATE/RUN plus optional final REVIEW, VERIFY, and BLOCKER artifacts. A supplied parallel-candidate `ISSUE-N-CLOSURE.json` additionally requires the canonical target-local `ISSUE-N-INTEGRATION.json` and `ISSUE-N-CANDIDATE-EVIDENCE.json`; all three are realpath-, schema-, identity-, and semantic-validated. Closure dependency digests must equal the actual integration/evidence bytes, evidence generation cannot precede integration, and closure evaluation cannot precede integration, evidence, or the admitted RUN end. Collector, report, and candidate closure reuse one strict calendar-valid RFC3339 parser, so regex-shaped impossible dates such as February 30 are rejected; copied branches pin byte-identical schema/fixture provenance so integration leaves one contract per artifact. Stored closure samples bind closure source/hash/value to exactly one canonical candidate-closure, integration, and candidate-evidence artifact and their recorded digests. A green terminal requires `status:"closed"` whose source, digests, project membership, issue, round, manifest revision, and candidate HEAD match the sample; REVIEW or VERIFY pass alone is never green. A policy-routed v2 sample additionally requires canonical v3 `ISSUE-N-TRANSPORT.json`; the collector validates every receipt routing field against the current Git-common-dir host admission transaction (and paired integrated binding when applicable), then derives runtime/model/effort/transport and a local-salt HMAC route pseudonym from that host-bound tuple. Receipt roles `implementation`/`reviewer`/`verifier` map only to telemetry roles `implementation`/`review`/`verification`; every other receipt role is a typed collection refusal. Raw route digests and CLI-supplied routing tuples are refused. The target supplies a local salt used to pseudonymize project identity. Existing salt/store components and the created store are resolved physically: benign symlinks to in-project files/directories are allowed, while any symlink escaping the target is rejected. Collection allowlists enums, timestamps, SHAs, relative artifact paths and hashes, and token/cost provenance; it excludes prompt/output text, environment or file bodies, raw provider request IDs, usernames, emails, and absolute paths. `observed`, `estimated`, and `unavailable` are distinct: unavailable values stay null and are never interpreted as zero.

`scripts/telemetry.sh report --worktree <target> --from <ISO> --to <ISO> --minimum-samples <N> --minimum-completeness <0..1>` revalidates each stored closure snapshot against its canonical source/digest record, then reconstructs retry chains by the immutable salted-project/issue/round/manifest-revision lineage. Complete chains start at admitted attempt 1, cover every contiguous attempt, use an edge to the immediately preceding sample, and end in canonical green closure; a cross-issue edge, missing attempt, or attempt 1→9 jump remains incomplete. Reports expose every attempt's role/task/tier/model/effort/usage allocation. Mixed-model chains remain visible and can be complete, but are suppressed from single-model cohorts as `mixed-model:<chain-id>` rather than attributed to the first model. Legacy v1 parsing remains unchanged. Routing cohorts use only homogeneous v2 policy chains and group selection basis, policy digest, runtime, role, task class, tier, model, and effort; the per-sample salted route pseudonym is not a cohort dimension. Their declared minimum is complete independent-chain count, emitted as `policy.minimum_complete_independent_chains` and currently set from `--minimum-samples`; admitted cohorts additionally expose complete-green rate, mean retries-to-green, and mean wall time. A v2 report says insufficient evidence when those cohorts or usage completeness are below threshold and includes a confounder warning. The report is advisory evidence only and never mutates model allocation or tier policy. The operator owns retention and export; the toolkit performs no upload or background collection. Exact-ID deletion additionally requires `--confirm DELETE`, and no bulk automatic deletion is provided. See `schemas/fixtures/telemetry_report.valid.json` and `telemetry_report.routing.valid.json` for the stable report shapes.

`cmux-dispatch.sh --allocate --allocator-role implementation` parses and validates allocation before any marker, runner, or cmux side effect, then forwards only the explicit `gpt-*` implementation pair to `codex-safe.sh`. v1 auto-dispatch is deliberately **Codex-executor only**: it never forwards Opus, Fable, or another Claude role through Codex. REVIEWER remains a fresh external clean-context seat. Direct dispatches must remain explicitly pinned; allocation dispatches must use `--allocate`, never omit both mechanisms.

`codex-safe.sh` permits 5.6 `low`, `medium`, and `high`, pins omitted 5.6 effort to medium, and refuses `xhigh` and `max`.

Before a bulk parallel dispatch, preflight-probe each selected runtime's pinned model once so an unavailable model surfaces on one cheap call instead of on every worker. Resolve one effective effort for the selected model first (Codex defaults to `low`; Claude/OpenCode default to `medium` when omitted), then use that exact tuple for both probe and launch; never let runtime-global effort fill the gap:

```
NODE_OPTIONS= codex exec --skip-git-repo-check -m <X> -c model_reasoning_effort=<effective-effort> "reply exactly OK"
```

Workload scaling (v1): review depth scales with the actual diff — ≤~50 changed lines with no exported-contract touch → single clean-context review round; >~400 lines OR >8 files OR any `packages/shared` touch → plan 2 review rounds (gap-audit + fix-verification) with re-verify after each fix commit; everything between uses the default single round + re-review-on-findings loop.

## Non-Negotiable Rules

- **Implementation is separate from review and verification.** The same agent/session must not implement and then approve or verify its own work. Re-review uses a new clean context.
- **Authoring context stops at the prompt-file boundary.** CONDUCTOR's context dump and user reverse-question conversation never enter the worker session; CODEX receives only the compressed prompt file.
- **Clean context is non-negotiable; review capability is enforced by default.** Using the source-dated LiveBench table, `model-alloc.sh` compares the deterministic unweighted sum `static_coding + reasoning` for reviewer and selected implementation models. It rejects a lower reviewer score unless the project sets `allow_review_below_implementation: true`; only that explicit relaxation emits the allocation warning.
- **Do not run two workspace-write Codex jobs in the same repo at the same time.** `codex-safe.sh` stashes partial work on failure; concurrent jobs in one checkout can race on stash state. Parallel implementation requires separate prepared worktrees.
- **Clear `NODE_OPTIONS=` before codex/node dispatch and verification.** cmux or shell preloads can leak `--require` instrumentation into codex/vitest children. `verify.sh` uses an explicit env allowlist, but operators should still dispatch with a clean `NODE_OPTIONS`.

## CONDUCTOR

The **CONDUCTOR** is the orchestrator role, executed by the explicitly selected Codex, Claude Code, or OpenCode runtime in a **dedicated pane OUTSIDE all clusters**, overseeing every in-flight cluster (one CONDUCTOR, not one per cluster). It dispatches work to the worker roles (ARCHITECT, implementation, REVIEWER, VERIFIER, VISUAL) and tracks chunk state.

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

All write-capable **Codex** executions reached through the shared runtime adapter MUST delegate to `scripts/codex-safe.sh`, which enforces:

- `--sandbox workspace-write` (no read/write outside the working root)
- `--cd <worktree>` on the codex call (locks codex's writable root to one worktree). The wrapper's own CLI flag is `--cwd`; it maps that to codex's `-C/--cd`.
- `sandbox_workspace_write.writable_roots=["<resolved Git metadata dir>"]` when `--cwd` is a Git checkout or linked worktree (see below)
- abort-time `workflow-stash.sh` (preserve partial diff on non-zero exit)

Direct `codex exec` is forbidden for implementation and review tasks. Claude Code and OpenCode use their own typed runtime isolation contracts above; runtime-specific wrappers remain the authority for task launches. The cheap model-availability preflight in "Model Allocation" is the only direct non-task exception; it invokes the selected runtime's pinned CLI, requests an exact harmless reply, and must not carry project work.

#### Why a Git checkout needs its metadata directory as a writable root

**Incident (2026-07-16, issue #127 chunk d):** codex finished seven consecutive dispatches with `exit_code: 0`, every line of the chunk written — and **zero commits**. Prompts said `git commit` was part of the task, in capitals, naming how many prior runs had skipped it. It made no difference, because the model was never the problem.

`workspace-write` makes only `--cd` (plus `/tmp`) writable. A git worktree's `.git` is a *file* pointing at the MAIN repo's `.git/worktrees/<name>` — outside `--cd`. So every commit died:

```
fatal: Unable to create '/path/to/main/.git/worktrees/<n>/index.lock': Operation not permitted
```

The failure mode is nasty because it is **silent and looks behavioural**: codex reports the work it did, exits 0, and the missing commit reads as an instruction-following defect. It was a sandbox denial. No prompt wording can fix a sandbox denial — a mistake that cost seven rounds of conductor commit fallbacks before anyone probed the actual `git commit` stderr.

`codex-safe.sh` resolves `git rev-parse --git-common-dir` and grants **only that resolved Git metadata directory** as a writable root. This covers both a linked worktree (whose common dir is outside `--cd`) and a plain checkout (whose in-tree `.git` is still denied by `workspace-write`); it does not grant the checkout, a parent directory, or another metadata path. Guarded by `scripts/__tests__/codex-safe.smoke.sh` (worktree and plain repo each grant their resolved gitdir / non-git cwd still dispatches).

**Diagnostic lesson:** a scratch-repo repro under `/tmp` shows the bug **passing** — codex's sandbox makes `/tmp` writable by default, which masks it. Reproduce this class of bug in a worktree of the real repo, not a temp fixture.

### Runtime-neutral stall watchdog

New dispatches run through `scripts/agent-watchdog.sh`, which invokes the typed
`agent-runtime.sh` boundary with the selected runtime, role, mode, pinned
executable, model/effort, and OpenCode permission file. `codex-watchdog.sh`
remains only a legacy direct-call compatibility path; it is not the public
multi-runtime authority. Codex write/review execution still delegates inside
the runtime adapter to hardened `codex-safe.sh`, preserving its Git metadata,
stash, effort-cap, and atomic review-publication invariants.

Liveness is process plus filesystem progress, never stdout first-token output.
The shared watchdog excludes `.git`, `.review`, and `node_modules` from the
progress scan, applies first-progress and stall budgets, kills the process tree
on a stall, and permits `MAX_RETRIES + 1` total attempts. Each attempt first
publishes `running`, republishes it with the child PID, and on failure stores
`ISSUE-N-agent-attempt<K>-stderr.log`. Explicit auth/model/permission/capability
diagnostics refuse immediately; otherwise two failed selected-runtime probes
separated by the configured gap refuse. Stall and ordinary non-zero failures
retry when budget remains. Exhaustion writes `exhausted` and exits non-zero.

Each shared attempt writes `ISSUE-N-RUN.json` as `artifact_type:"agent_run"`
with selected `runtime`, `role`, observed `runtime_version`, and status
`running|exited|killed_stall|refused|exhausted`. `attempt` is a watchdog process
attempt counter, not an admission ordinal or workflow failure round; retries do
not consume redispatch admission. `exited` is written only after a zero process
exit and any requested host publication gate succeeds. It proves termination,
not completion. Legacy `codex_run` remains schema-readable only for historical
compatibility. No RUN shape has `completed` or `failed` status.

`--produce-review` requires reviewer read mode and host-validates canonical
review JSON against live HEAD before publication. `--conductor-control`
requires conductor read mode. The untrusted runtime may propose exactly one
ROUND-STATE publication; `conductor-control-publish.sh` takes a host lock,
schema/issue/live-HEAD/worktree/base/revision/path-validates it, and atomically
publishes only `.review/ISSUE-N-ROUND-STATE.json`. The conductor runtime never
gets product-code write permission from this mode. A denied proposal publishes
nothing and makes the RUN refused/non-successful.

### `agent-workflow.sh` — explicit Orca/cmux selection over one correctness core

The deep `lib/output-contract.mjs` module derives reviewer/BLOCKER prompt instructions from installed schemas, including nested object/array shapes, required fields, and enum/const values; `output-contract.sh check` rejects missing or drifted blocks in new Markdown prompts before admission. A fresh BLOCKER is liveness evidence only after schema validation, so malformed artifacts cannot unblock redispatch. The `.txt` prompt path remains an explicit legacy compatibility path.

The public interface has three commands: `capabilities`, `dispatch`, and `inspect`. An installed checkout's absolute `.agent-workflow` directory is **PRODUCT_HOME**. A fresh linked worktree does not contain ignored PRODUCT_HOME files, so invoke every workflow command as `"$PRODUCT_HOME/scripts/<command>"` and pass the fresh checkout only through `--worktree`. `dispatch` resolves `orchestrator`, `runtime`, and `role` independently by CLI, then the matching `AGENT_WORKFLOW_*` environment value, then `$PRODUCT_HOME/workflow-config.json`. The config accepts exactly those three string axes; copy [the installed example](workflow-config.example.json) into PRODUCT_HOME rather than adding command or executable fields. Missing transport, unknown values, or failed selected transport/runtime/role capability fails before write admission. Runtime/role omission maps to Codex/implementation only for legacy compatibility; it is not runtime fallback. Prompt-file relative paths remain relative to `--worktree`.

`dispatch-core.sh` remains the sole owner of prompt/ROUND-STATE validation, issue/worktree/HEAD binding, atomic initial and redispatch admission, unique runner creation, RUN/BLOCKER freshness, polling timeout, and exit classification. Both transport adapters receive the same typed seat request and cannot receive arbitrary target-configured argv. Every new launch atomically publishes schema-valid `.review/ISSUE-<N>-TRANSPORT.json` schema v2 with selected runtime, role, observed runtime version, adapter capability evidence, external handle, worktree/runner identity, and timestamps. A policy-opted allocator-owned canonical redispatch derives tier from canonical ROUND-STATE, reuses a host-cached static executable/configuration offer (1800-second default, 3600-second maximum), and upgrades only its receipt to schema v3 after the complete route tuple matches its authoritative ordinal admission record (and the paired integrated singleton when present); v3 copies provenance and cannot recreate route authority. All receipt versions are explicitly non-authoritative. Schema v1 receipts remain readable as legacy transport-only evidence; missing v2 runtime provenance is interpreted only as legacy Codex/implementation for inspection display, never as proof of a current dispatch. `inspect` normalizes external handle/runner state to `live`, `stale`, or `handle_unverifiable`; none completes work.

The typed `role` is an admission, access-mode, and provenance contract; it is not a runtime-specific hidden persona prompt. The canonical prompt/capsule supplied by the conductor remains the explicit source of role instructions and task scope. This keeps the same auditable prompt semantics across Codex, Claude Code, and OpenCode instead of silently injecting different vendor behavior.

The cmux adapter creates one workspace with the exact `--cwd` and short runner command. Before admission it runs only side-effect-free version/help probes: cmux must be at least `0.64.0`, `workspace create` must exist, and its documented create flags must include `--cwd` and `--command`. A present binary whose probes exit non-zero is unavailable. The Orca adapter first proves `orca terminal create` supports every launch flag (`--worktree`, `--title`, `--command`, `--json`) and that read-only terminal listing supports `--worktree` and `--json`; it then creates one fresh bare-shell terminal with `--worktree path:<exact-worktree>` and the same short runner. It does not create or open a repository/worktree/UI, inject another agent, focus the GUI, reuse a supplied handle, or fall back. Missing proof returns `required_capability_missing` before admission and does not consume a marker. `cmux-dispatch.sh` remains an explicit-cmux compatibility facade over this same core.

Before admission, the shared core resolves the selected runtime from its runtime-specific host seam (`AGENT_WORKFLOW_CODEX_BIN`, `AGENT_WORKFLOW_CLAUDE_BIN`, or `AGENT_WORKFLOW_OPENCODE_BIN`) or caller `PATH` to one canonical absolute executable. It exports only the generic absolute `AGENT_WORKFLOW_RUNTIME_BIN` pin into the retained runner, shared watchdog probes, and runtime adapter. Relative, missing, non-executable, mismatched, or unavailable pins fail before admission; target workflow config cannot set one. This prevents a transport terminal with a different inherited PATH from changing runtime identity. cmux handle creation/inspection remains identity-strict as documented below.

Use `scripts/agent-workflow.sh dispatch --orchestrator <cmux|orca> --runtime <codex|claude|opencode> --role <role> --issue <N> --worktree <path> ...` for new callers. Add `--read-only --conductor-control` only for the narrow conductor ROUND-STATE publication mode. Use `capabilities` before operator setup. The remaining correctness options below are shared across transports and runtimes.

### Historical cmux incident and compatibility contract

**Incident (2026-07-13):** a dispatch ran `cmux new-workspace --command "codex-watchdog.sh --issue 147 --prompt-file .review/ISSUE-147-PROMPT.txt --cwd <worktree>"` but forgot `--cwd <worktree>` **on the cmux workspace itself**. The workspace opened in cmux's default project dir; the watchdog validated the relative `--prompt-file` against *that* dir instead of the intended worktree and hit `exit 2` before writing any artifact. Nothing recorded the failure except pane scrollback — no `RUN.json`, no `BLOCKER.json`. Separately, the CONDUCTOR's poller assumed terminal values like `"completed"`/`"failed"`, which don't exist in this schema (see the contract above), so it never noticed the dispatch was dead.

Do not hand-roll `cmux new-workspace`, `orca terminal create`, or a watchdog command. New callers use the public interface above with optional planned-write arguments `--execution-plan <json> --seat <id>`. Existing `scripts/cmux-dispatch.sh --issue <N> --worktree <path> ...` calls retain their explicit-cmux behavior and accept the same correctness arguments. Initial writes require an explicit tier. Standard/Full Cluster initial writes and every redispatch require the canonical ROUND-STATE arguments; Trivial initial writes retain the `pr_draft`-only contract, and read-only seats remain outside write admission:

- Defaults: `--prompt-file` = `<worktree>/.review/ISSUE-<N>-PROMPT.md` (the legacy `.txt` path remains accepted for compatibility), `--name` = `codex-<N>`, `--poll-timeout` = `300`.
- **Every write launch has explicit pins before admission.** `--model`/`--effort` are forwarded through `agent-watchdog.sh` to the selected runtime adapter; `--allocate --allocator-role implementation` or an omitted-model implementation dispatch resolves PRODUCT_HOME `model-alloc.json` (falling back to the shipped default only when absent) and forwards the same explicit pair before launch. A missing manual model never falls through to a runtime-global default; unavailable selected-runtime capability fails closed. For Codex write/review seats the adapter delegates to the compatibility-hardened `codex-safe.sh`, which remains the sole owner of its 5.6 effort cap: `high` is permitted, while `xhigh` and `max` are refused.
- **`--read-only` selects a typed read seat:** the runtime-neutral watchdog launches the selected adapter in read mode. Codex uses `--sandbox read-only`, Claude uses permission mode `plan`, and OpenCode requires the installed deny-first read config plus the named `agent-workflow` primary agent. It remains outside write admission.
- **`--produce-review` is the runtime-neutral REVIEWER publication mode and requires an explicit `--model`; effort is resolved once (Codex `low`, Claude/OpenCode `medium` when omitted) and that same value is used for preflight and launch.** It stays outside write admission. Codex, Claude, and OpenCode all validate against the pinned start HEAD, then use the shared repo-local temp/atomic publication seam for the immutable snapshot and canonical REVIEW; a HEAD change or snapshot conflict refuses publication. Non-Codex implementation watchers apply the same schema/issue/HEAD/lifecycle BLOCKER gate as Codex. Invalid or non-zero output is a terminal `refused` run and never replaces an existing canonical REVIEW. Pane prose is never converted into evidence.
- **`--first-progress-timeout` and `--stall-timeout` are forwarded only when supplied; `agent-watchdog.sh` consumes those liveness budgets rather than passing them to the runtime adapter.**
- Validates the worktree exists and is an actual git worktree, the prompt file exists, and (unless `--dry-run`) that the selected adapter proves its typed capabilities — all before consuming admission, with a machine-readable reason naming what's wrong.
- Before a Standard/Full Cluster initial write, validates the complete canonical ROUND-STATE against `schemas/round_state.schema.json`, requires active lifecycle, pins the CLI issue, tier, and manifest revision, binds `worktree_path` and `head_sha` to the live checkout, and rejects a `base_sha` that is not the live merge-base with `base_branch`. Standard also requires `pr_draft` and `review` pointers. Redispatch accepts only the same canonical path, so escalation extends that artifact; no Standard-only mini-state or second authority exists.
- Planned write seats supply `--execution-plan` and `--seat` together. The canonical plan must live at `.review/ISSUE-N-EXECUTION-PLAN.json`; its issue/revision/base/worktree/seat/write-set binding is validated before any existing admission is consumed, then its immutable Git-common seat binding is consumed after prompt/redispatch gates and before the write marker. Read-only and REVIEWER seats cannot consume it.
- Absolutizes both the worktree and prompt-file paths, then atomically writes a launch-unique `<worktree>/.review/ISSUE-<N>-launch.<unique>/launch.sh`. That executable preserves the fully shell-quoted `exec env NODE_OPTIONS= AGENT_WORKFLOW_RUNTIME_BIN=<abs-selected-runtime> <abs agent-watchdog.sh> --issue <N> --runtime <runtime> --role <role> --prompt-file <abs-prompt> --cwd <abs-worktree>` argv (plus pinned model, effort, liveness, and mode flags). cmux receives only the short relative `bash .review/ISSUE-<N>-launch.<unique>/launch.sh` command while retaining mandatory `--cwd <abs-worktree>` on its workspace. Unique paths prevent a later same-issue seat from replacing an earlier runner before asynchronous execution. Each runner is retained for diagnosis and its exact relative path is printed at launch; do not replace it with an issue-wide or absolute inline command.
- `--dry-run` prints the selected typed launch and runner preview, then exits 0 without calling the transport or recording a runner — the test seam. The legacy facade retains its historical cmux preview.
- On a real run it polls every 5s up to `--poll-timeout` for `<worktree>/.review/ISSUE-<N>-RUN.json` or `-BLOCKER.json`. A **fresh** artifact appearing means the dispatch is alive (or scoped-aborted) and it exits 0. Timeout with no fresh artifact means the watchdog never started — it exits non-zero with a diagnostic pointing at the workspace pane.

**Same-issue re-dispatch is a supported pattern** (e.g. a second prompt file for the same issue after a first attempt), and it has a trap: the previous run's `RUN.json` (typically `status:"exited"`) is still sitting in `.review/`. On `cmux-dispatch.sh`'s first production use (issue 147 re-dispatch, 2026-07-13) the poll accepted that stale file immediately and reported success before the new watchdog had even started — had the new watchdog died pre-start, the dispatch would still have claimed success. The script now records the identity (cross-platform nanosecond mtime + `started_at`) of any pre-existing `RUN.json`/`BLOCKER.json` **before** creating the workspace, prints `waiting for fresh RUN.json (stale one from <started_at> present)`, and the poll only accepts an artifact whose identity changed (every watchdog attempt rewrites `started_at`) or that newly appeared. A stale artifact alone times out non-zero, exactly like no artifact.

### Dispatch liveness operator rules

RUN/BLOCKER files are issue-scoped and can be overwritten by read-heavy, REVIEWER, and implementation seats for the same issue. A hand-rolled poller therefore must not treat the file's current contents as the identity of the launch it intended to observe.

1. Capture the dispatch command exit code directly; do not pipe the command through `tail`, `tee`, or another consumer unless the shell explicitly preserves the dispatch status. A rejected launch may write no new RUN artifact at all.
2. Accept RUN/BLOCKER only when its `mtime + started_at` identity is fresh relative to the current dispatch. Prefer `cmux-dispatch.sh`'s built-in poll instead of recreating this check.
3. `status:"exited"` means process termination, not task completion. The current watchdog writes `exited` only after exit code 0 and immediately returns; an ordinary non-zero retry rewrites `running` for the next attempt, while a stall retry may move from `killed_stall` back to `running`. The historical claim that a failed attempt necessarily flips `exited -> running` is not this implementation's contract.
4. If RUN identity or retry timing is ambiguous, confirm that the recorded process is absent before treating an ambiguous retry as terminal. A live process plus advancing worktree or heartbeat mtime is liveness; RUN alone is not completion.
5. Missing artifacts alone do not prove that a dispatch is dead. Combine the dispatch exit code, process presence, and filesystem or heartbeat progress; a pre-RUN validation failure, slow first progress, and a dead child otherwise look alike to a file-only poller.
6. If a launch is silent, inspect the pane before retrying: `cmux read-screen --workspace <name> --scrollback --lines <N>`. A repeated `dquote>` or `heredoc>` continuation prompt indicates a malformed shell transport; preserve the pane evidence and inspect the exact launch-unique runner path printed by `cmux-dispatch.sh` rather than guessing from absent RUN/BLOCKER files.
7. For a `gpt-5.6-sol` medium dispatch, allow at least eight minutes before manual intervention unless the configured watchdog budget or a hard failure has already produced a terminal signal. Two real runs were killed early while still on a normal completion path; silence by itself is not an earlier deadline.
8. A growing attempt stderr file is an additional liveness signal. If stderr stays small and frozen while the process remains alive and there is no filesystem/heartbeat progress, a small frozen stderr file plus a live process can indicate a stdin block; check whether an unsanctioned wrapper omitted the required stdin redirection before killing the process.
9. Bind REVIEW and VERIFY evidence to the live HEAD. Commits and canonical evidence decide completion; RUN status, process absence, and pane prose do not.

### Sandbox network containment — why the worker can't self-verify DB tests (v0.3)

`workspace-write` blocks **all** network egress, including **loopback**. A v0.3 spike proved this is total: a probe run inside the sandbox cannot `connect()` even to `127.0.0.1` (TCP) **nor** to a Unix-domain socket placed inside the writable root — both fail with `EPERM`. (Repro: host-side relay `scripts/uds-pg-relay.mjs` + in-sandbox `scripts/__tests__/uds-sandbox-probe.mjs`; the TCP-loopback case is the live layer of the network-deny smoke below.) So there is **no containment-preserving way** to give a sandboxed worker access to the local Postgres on current codex (0.133.0):

- A loopback-only network allowance is **not shipped** (codex issue #6737 open; #6807 closed-folded). `network_access` is all-or-nothing.
- The "UDS proxy" idea (front Postgres with a socket in a writable root) was **rejected** — Seatbelt denies AF_UNIX `connect()` too.
- A full-egress `dbtest` profile (`network_access=true`) was **rejected** as a standing workflow: with the principled UDS fallback dead, it is a pure risk-trade (tests run arbitrary dep/app code → exfil surface), and VERIFIER already runs the same tests cleanly outside the sandbox.

**Decision: status-quo.** The worker stays network-denied; the **VERIFIER runs DB tests outside the sandbox** (see VERIFIER protocol). Revisit only when (a) codex ships loopback-only network (#6737), or (b) data shows DB-test verifier churn is a real throughput bottleneck.

Hardening shipped alongside this decision: `scripts/__tests__/sandbox-network-deny.smoke.sh` guards against regression. Layer 1 (offline) asserts `codex-safe.sh` still pins `--sandbox workspace-write` and grants no `danger-full-access`/`network_access`; Layer 2 (opt-in, `RUN_LIVE_SANDBOX_PROBE=1`) runs `scripts/__tests__/net-deny-probe.mjs` inside the sandbox and asserts loopback is `BLOCKED`. Machine-global Codex defaults are operator configuration and are not installed or assumed by this repository.

## Smoke Suite Diagnostics

`scripts/__tests__/run-all.sh` is the offline Bash 3.2 suite runner for the source checkout. It is a maintainer verification asset and is not installed into a target PRODUCT_HOME. Its failure output is the operator's primary diagnostic, so:

- **A failing smoke prints its diagnostic**, framed by `--- begin <name> diagnostic ---` / `--- end <name> diagnostic ---`, so the inner assertion reaches the CI log instead of only a name and an exit code. The emitted capture is **retained** (not deleted on exit) and its path is printed as `diagnostic retained: <path>`, with the run's directory repeated on stderr as `diagnostics retained under: <dir>`. A green run still cleans up and keeps its existing `ok - <name>` / `--- N/N passed` output unchanged.
- **Redaction is explicit, not inferred.** When a smoke can print credentials, invoke the runner with `--redact-values-file <path>`. Each non-empty line in that private file is one literal value to replace with `[REDACTED]` in both the CI diagnostic block and the retained capture. The runner uses private transient storage, removes the raw failing capture after producing the sanitized one, and retains only the sanitized file. It does not inspect environment names or claim to identify arbitrary secrets; the caller owns a complete values file for the invoked suite. Do not put secret values directly in command-line arguments.
- **`--list` is a read-only inventory query** and answers before any temporary storage is allocated, so it still works when `TMPDIR` is unavailable. Treat `bash scripts/__tests__/run-all.sh --list` as the authority on the live inventory; never hand-type a count.
- **The runner's own contract test is `scripts/__tests__/run-all-contract.test.sh`**, deliberately named `*.test.sh`, not `*.smoke.sh`. The runner discovers work by the `*.smoke.sh` suffix, so a smoke-named runner test would make the suite re-enter itself. It drives a copied runner against deliberate pass/fail fixtures in a throwaway directory and is run directly: `bash scripts/__tests__/run-all-contract.test.sh`.
- **Asynchronous smoke fixtures wait on conditions, not clocks.** `cmux-dispatch.smoke.sh` exposes `wait_for_condition <name> <deadline-seconds> <command...>`, which polls until the condition holds and, on deadline expiry, fails with `condition not met within <N>s: <name>`. A missing asynchronous event is therefore reported by name rather than surfacing as an unrelated downstream failure. Do not reintroduce fixed sleeps for fixture coordination.

## Worktree Prep

A fresh `git worktree` is **NOT dispatch-ready**: it has no `node_modules` and no gitignored `.env`. Because the codex sandbox blocks network, deps and env cannot self-provision inside it — provisioning MUST happen host-side, **outside the sandbox**, before dispatch.

Run `"$PRODUCT_HOME/scripts/prepare-worktree.sh" <wt>` on the host, where PRODUCT_HOME is the absolute `.agent-workflow` directory in the installed checkout, not the fresh worktree. It installs deps from the frozen lockfile (`pnpm install --frozen-lockfile`) and copies env files (`.env`, `apps/backend/.env`), printing every copied key (values redacted) and loudly flagging high-risk keys (DATABASE_URL, WORKSPACE_ID, PORT, anything with STORAGE/BUCKET/S3/SECRET/TOKEN/KEY/PASSWORD/CREDENTIAL).

`scripts/cmux-cluster.sh` **refuses to launch** if `<wt>/node_modules` or `<wt>/.env` is missing, naming what's missing and pointing at prepare-worktree.sh.

**Env is shared-state coupling.** Copying one `.env` into multiple worktrees points them all at the same mutable DATABASE_URL / WORKSPACE_ID / storage bucket — parallel clusters corrupt each other. When ANY other prepared worktree already exists (>=1 other), prepare-worktree.sh refuses to copy env unless you pass `--env-profile <path>` (per-worktree env file, recommended) or `--allow-shared-env` (explicitly accept the risk). So the first worktree prepares without a flag; the second and beyond require one. Profile mode writes the same profile to both `<wt>/.env` and `<wt>/apps/backend/.env` so a stale backend env cannot override the profile later; the profile must therefore be self-contained for the target's verification needs.

**Rebasing in-flight worktrees when the integration branch advances.** When a merge lands on the integration branch (commonly `develop`), in-flight `feature/*` worktrees drift behind it. From the branch that just advanced, run `scripts/rebase-inflight.sh --onto <branch>` (default onto = current branch) to rebase every sibling feature worktree. It is **dirty-safe** — it REFUSES to rebase a worktree with uncommitted changes (loud SKIP, never clobbers work) — and **conflict-aborting** — on a rebase conflict it runs `git rebase --abort` so a worktree is never left mid-rebase; that worktree is flagged for a manual rebase and the others continue. A single failure never hard-fails the command (exit 0; exit 1/2 only on lock contention or bad args). After a successful rebase it prints a generic suggestion to run `scripts/verify.sh <test-name-filter>` for the affected area — it never auto-runs tests, and it deliberately does NOT emit a package name (the arg is a vitest name/path filter, not a package selector). A `mkdir`-based lock under `.review/.rebase-inflight.lock` serializes concurrent invocations. A host repository may add a warn-only post-merge hook that points at this script, but automatic rebasing inside a hook is too risky; rebasing remains an explicit operator/CONDUCTOR action.

**Parallel-cluster DB isolation (Trial 3).** Running two clusters in parallel requires **one throwaway database per cluster** — NOT a shared DB with distinct schema or `WORKSPACE_ID`. The backend hardcodes Postgres schemas `core`/`permission` (drizzle `schemaFilter`), and instance-global state (`pg_locks`, sequences) plus shared schema objects mean schema/workspace isolation only separates workspace-scoped *rows*, not the tables/locks two suites contend on. Procedure: `createdb -O fops_migrate feedbackops_<cluster>` (needs a superuser — `fops_migrate` lacks `CREATEDB`), `drizzle-kit migrate` with `DATABASE_URL_MIGRATE` → the new DB, then **seed with BOTH `DATABASE_URL` and `DATABASE_URL_MIGRATE` targeted at it** (the seed's VOC owner team is created via the migrate role). Point each worktree at its DB via `prepare-worktree.sh --env-profile`. Validated: `create-voc` 31/31 in two DBs concurrently, zero cross-contamination. See `docs/agents/workflow-trial-log.md` Trial 3.

## Artifact Lifecycle

Every `.review/ISSUE-*.json` carries `lifecycle: draft | active | superseded | final`. Superseded files MUST be ignored by readers. See `docs/agents/artifact-lifecycle.md`.

### Canonical ROUND-STATE

For Standard/Full Cluster work, CONDUCTOR maintains one `.review/ISSUE-<n>-ROUND-STATE.json` as the normative contract state from dispatch 0. Trivial initial work remains pr_draft-only. ROUND-STATE replaces amendment prose; reviewers never reconstruct an effective contract by merging prompt fragments. The artifact contains the current contract, acceptance criteria, decisions, prior findings, commit scope, live-probe results, and artifact pointers. `contract.prohibitions[]` is the canonical structured prohibition source; CONDUCTOR records each prohibition explicitly and consumers render the array verbatim instead of scraping natural-language prompt lines. Its schema is `schemas/round_state.schema.json`.

For Standard tier, “minimal” means generating this complete schema before the first write while omitting optional Full Cluster structures and using empty arrays only where the Standard contract permits them. `artifact_pointers` still declares `pr_draft` and `review`. It never means a reduced schema or parallel manifest. `cmux-dispatch.sh` enforces the canonical artifact and revision at initial admission and redispatch, and escalation revises the same file. Trivial retains the table's `pr_draft`-only contract.

CONDUCTOR is the sole writer. `revision` increments whenever the normative contract or acceptance criteria change, with the reason recorded in `decisions`. CODEX, REVIEWER, and VERIFIER consume but do not edit it. The acceptance manifest is not a separate file: it is the `acceptance.criteria[]` view at the ROUND-STATE `revision`. A task narrative is at most 2 KB and carries only current intent/delta, failing AC ids, and evidence pointers; it must not restate normative criteria or allowlists.

### Dispatch prompt AC gate

Before any Standard/Full initial write and every canonical write redispatch, CONDUCTOR follows the three-step authoring procedure in `conductor-persona.md`: unedited context dump, one user-facing reverse-question batch (or explicit `skipped: no open questions`), then compressed worker prompt. The dump and prompt are uncommitted non-archival scratch inputs. `ISSUE-N-PROMPT.md` must have exactly one `agent-workflow:ac-block` fenced JSON array that exactly copies the ordered `acceptance.criteria[]` IDs and statements from canonical ROUND-STATE. `scripts/prompt-ac-check.sh` is the deterministic seam; `cmux-dispatch.sh` invokes it after canonical admission and before attempt markers, runners, or cmux effects. Trivial initial writes and read-only/review seats remain outside this prompt-AC admission.

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

The gate first validates the complete artifact against the canonical schema and runs `artifact-fresh.sh`; partial, superseded, wrong-writer, or base-stale state is rejected. `--manifest-revision` must then equal the artifact's top-level `revision`; a mismatch is stale and fails before AC mapping. `contract.touch_allowlist` and chunk paths are safe target-relative globs only: absolute, drive-qualified, empty-segment, backslash, or traversal patterns are input errors, never match-all shortcuts. AC ids come from `acceptance.criteria[].id`. The tests file contains actually discovered test names or paths. Duplicate or undiscovered ids fail the gate; ID matching is boundary-aware, so `AC-10` cannot satisfy `AC-1`. This proves only that every declared id is represented in discovery output—it does not prove behavior, so REVIEWER and VERIFIER still run.

### CONDUCTOR completion calculation gate

Before REVIEWER consumes a worker handoff, CONDUCTOR runs:

```bash
scripts/completion-check.sh \
  --round-state <ISSUE-N-ROUND-STATE.json> \
  --manifest-revision <revision>
```

The command validates the canonical ROUND-STATE and freshness, calculates `base_sha..HEAD` in its declared live worktree, and compares that independent diff against `contract.touch_allowlist`. It directly executes the target profile's `contract.test_discovery_command` in that worktree, compares `acceptance.criteria[].id` against its output, and compares its non-empty record count exactly against canonical `acceptance.expected_test_count`. When `contract.chunk_boundary` is present it also rejects compile consumers outside the touch allowlist, runs the target-native full typecheck, and emits only the current chunk's triggered `review_obligations[]` in declaration order. It does not consume RUN.json, PR-DRAFT claims, diffstat prose, a supplied discovery file, or a worker's reported test count. Exit 1 emits a machine-readable JSON `mismatches` list and hard-stops review; exit 2 emits a stable machine-readable error code for invalid input, an uncheckable state, failed discovery, or an invalid chunk boundary and also fails closed. The target profile owns both commands and must emit one record per discovered test; the reusable core does not hard-code Vitest. This gate establishes completion-contract coverage and review scope only; the REVIEWER closes each emitted watch through its declared checklist selector, and independent verification remains required for behavioral correctness.

`contract.new_file_allowlist[]` is the narrowly scoped new-file exception for completion checking. Every entry is an exact safe target-relative file path (never a glob); a changed path absent at `base_sha` must appear in it as well as matching `touch_allowlist`. This preserves typo detection for intended existing-file edits.

### Deterministic parallel plan and integrated-candidate closure

Parallel is an evidence-backed optimization, never a default inferred from branch names, agent claims, cmux state, or task state. CONDUCTOR writes canonical `.review/ISSUE-<N>-EXECUTION-PLAN.json` (schema `schemas/execution_plan.schema.json`) with issue/round/manifest/plan revision, base HEAD, sorted seat IDs and normalized target-relative write sets, dependencies, topological integration order, shared mutation surfaces, DB/environment isolation, rate-limit budget, required evidence, and the complete-fresh-same-HEAD retry policy. `scripts/parallel-plan.sh decide --plan <plan> --target <repo>` rejects traversal, symlink escape, duplicate ownership, malformed/cyclic DAGs, and non-topological integration order. It emits byte-stable pair decisions. Only disjoint exact write sets without dependency, shared-surface, isolation, or budget conflicts are `parallel_eligible`; unknown, dynamic, broad, overlapping, or unproven pairs serialize. A one-seat plan is valid and produces no pair decisions.

Each planned write dispatch adds `--execution-plan <canonical-plan> --seat <id>` to the existing Standard/Full arguments. The shared dispatch core calls the plan gate before launch, compares the seat's exact write set with ROUND-STATE `touch_allowlist`, binds issue/revision/base HEAD/real worktree, and atomically consumes an immutable plan/round/seat/hash admission in the Git common dir only after prompt and redispatch checks pass. Existing per-worktree initial markers, issue/ordinal redispatch admission, and integrated-fix singleton remain in force. A no-plan dispatch is the conservative legacy sequential path.

After required seat outcomes, use a dedicated clean candidate at the plan base and run `scripts/candidate-integrate.sh --plan <plan> --target <target> --candidate-worktree <candidate> --source <seat>=<source-worktree>@<full-head> ... --output <ISSUE-N-INTEGRATION.json>`. It preflights every live source HEAD, base ancestry/rebase, clean source, and actual `base..source` paths before mutation, applies each full delta in declared order, commits each step, and records source/resulting heads. Closure requires the integration steps to be an exact ordered, unique, one-for-one correspondence with `integration_order`; duplicate, missing, or reordered seats return stable `integration_step_order_mismatch` rather than being inferred or dereferenced. Unexpected paths, stale heads, missing rebase, dirty state, failed patch application, or conflict publish a machine-readable blocked result. It never resets, checks out, aborts, or discards candidate changes.

Finally create one canonical `ISSUE-N-CANDIDATE-EVIDENCE.json` attempt containing hash-bound REVIEW, VERIFY, PR-DRAFT, completion, and every seat outcome at the integrated candidate HEAD. Every underlying artifact, not only the wrapper entry, carries `closure_binding` with issue/round/manifest/plan revision, candidate HEAD, attempt ID, and generation time. Therefore relabeling an old same-HEAD artifact set with a new wrapper attempt ID is not a fresh retry. `scripts/candidate-close.sh evaluate` validates those direct bindings, the plan, passing integration record, clean live candidate, canonical evidence paths and hashes, a `lifecycle:"final"` REVIEW checklist, the complete VERIFY aggregate (any failed run remains red), a `lifecycle:"active"` ready PR-DRAFT, completion identity, seat/source outcomes, and absence of an active/final BLOCKER. Draft/superseded REVIEW or PR-DRAFT artifacts remain history and cannot close. Candidate/integration/closure/completion/seat timestamps must match RFC3339 and also parse to a finite, calendar-valid instant. It writes `ISSUE-N-CLOSURE.json`; worker-head green artifacts cannot substitute. A newly generated complete same-HEAD attempt may replace a failed attempt, but wrapper-only relabels and mixed attempts are rejected. `candidate-close.sh inspect --closure <closure> --worktree <candidate>` returns `candidate_head_advanced` after any later commit, so closure is never durable across HEAD changes.

### Test-matrix row contract

The authoritative acceptance contract is also the test-matrix template: every test-matrix row is a canonical `acceptance.criteria[]` entry; its `id` is the sole AC-ID authority, and its `statement` contains an explicit precondition and observable checkpoint. Do not use cited authoritative detail as a substitute for required inline content: the canonical `statement` is the complete row authority. An expected status alone is not a checkpoint: the precondition must make the target behavior reachable, and the checkpoint must observe the state or output that proves it occurred.

When a row exercises a privacy boundary, its canonical `statement` also requires a **positive field allowlist assertion**—that the returned object contains only the permitted fields, not merely assertions that named sensitive fields are absent. Clarify privacy applicability explicitly only when it would otherwise be ambiguous; non-privacy rows need no non-applicability ceremony. `ac-check.sh` deliberately enforces only AC-ID discovery coverage; REVIEWER audits the precondition, checkpoint, and applicable allowlist for non-vacuousness, and this template never thins the independent verifier or final review.

Use this compact inline statement shape: `precondition | observable checkpoint | positive field allowlist (when privacy-relevant)`. It is a contract template inside the existing `statement`, not an analyzer input or a new schema field.

## Deterministic re-review capsule

Before a second `--produce-review` dispatch, CONDUCTOR runs:

```bash
scripts/review-capsule.sh --issue 17 --worktree "$WT" \
  --round-state .review/ISSUE-17-ROUND-STATE.json \
  --prompt .review/ISSUE-17-PROMPT.md \
  --pr-draft .review/ISSUE-17-PR-DRAFT.json \
  --review .review/ISSUE-17-REVIEW.json \
  --manifest-revision 3
```

The renderer validates issue/revision/worktree/live HEAD, clean tracked state, exact AC block, final published review, schemas, safe target-relative source paths, and `model-alloc.json`'s `prompt_authoring.target_tokens`. PR-DRAFT must identify that exact real worktree and copy ROUND-STATE `base_sha`. It writes deterministic `ISSUE-N-REVIEW-CAPSULE.{json,md}` with per-input SHA-256 and an aggregate digest. The target is an upper bound for the complete reviewer Markdown, not a per-item allowance: objective, diff files, prior findings, verification, and risks receive cumulative section budgets. Array overflow records typed `budget.omitted_counts`, renders an explicit count marker, and appears in `truncated_sections`. Full canonical AC text and ROUND-STATE `contract.prohibitions[]` are never truncated; an undersized budget fails with the calculated minimum. Source text is untrusted data: it is never evaluated, `.env` sources/path escapes are rejected, and secret-shaped assignments are redacted.

Dispatch the re-review with explicit `--re-review` and canonical `--review-capsule .review/ISSUE-N-REVIEW-CAPSULE.json`. `cmux-dispatch.sh --produce-review --re-review` checks the generated Markdown bytes through the capsule freshness gate, automatically selects `.review/ISSUE-N-REVIEW-CAPSULE.md` when `--prompt-file` is omitted, and rejects any different prompt/capsule file even in dry-run. Ordinary `--produce-review` remains the initial-review/publication-retry interface. The capsule guides the reviewer only. ROUND-STATE owns objective/touch/prohibitions/AC, REVIEW and VERIFY own their verdicts, and PR-DRAFT owns the implementation handoff.

## VERIFIER protocol

For generic targets, run `scripts/target-verify.sh <profile.json> <issue>`. The closed draft-07 profile contains only identity, runtime/setup/environment facts and required verification command groups. Commands are structured argv plus optional repository-relative cwd and env allowlist; no shell evaluation or plugin registry exists. The verifier checks runtime/environment requirements, executes every required command, records exit/duration/output, and applies `output_bytes` as a UTF-8 byte ceiling without publishing a partial code point. `output_truncated` is true exactly when the original combined output exceeded that byte ceiling. A declared test-count extractor must prove a count above zero; an extractor miss is published as schema-valid canonical FAIL evidence with `test_count:null`, not discarded and not represented as a known zero. The bundled Node profile recognizes actual `node --test` TAP summaries including `ℹ tests N` (and the older `# tests N` form). Evidence is bound to the live Git HEAD and atomically published.

Canonical VERIFY has exactly one evidence family: the FeedbackOps compatibility adapter supplies `db_target + clean_state`, while a generic profile supplies `target_profile + groups`. The schema rejects neither/both shapes and rejects PASS with zero passed checks or non-empty failures. For generic PASS evidence, every command in every required group has `exit_code:0`; when a group carries the profile-declared `test_count`, it is an integer greater than zero. Both the schema PASS branch and the independent semantic validator enforce these predicates. Before appending at the same HEAD, `target-verify.sh` validates the existing artifact against the same schema and independently validates run semantics plus the derived aggregate; an invalid identity or damaged red aggregate is left untouched and fails closed. A valid failed run remains red for the same HEAD; a different HEAD starts a fresh aggregate.

`schemas/profiles/` contains Node/node:test, Go, Python/pytest, and FeedbackOps compatibility examples. The generic verifier does not know pnpm, Vitest, PostgreSQL, package layout, or service topology. Profile unknown keys/version and cwd traversal fail closed.

For the FeedbackOps compatibility profile, VERIFIER MUST confirm green by running `scripts/verify.sh` for the full backend module by default, or `scripts/verify.sh <filter>` only when the narrower name/path filter demonstrably covers the touched behavior — never by eyeballing test output and never by running a bare `pnpm test`.

VERIFIER and REVIEWER must be different agents/sessions from the implementer. A worker's own "I ran tests" claim is not verification evidence; the canonical evidence is the VERIFIER-owned `ISSUE-<n>-VERIFY.json` plus the review artifact where applicable.

The verify oracle currently assumes a pnpm workspace package named `backend` tested with Vitest. With no filter it runs that full module. An optional `<filter>` is a **Vitest test name/path filter scoped to the backend package**, **not** a package selector — e.g. `scripts/verify.sh create-voc` runs backend tests whose path/name matches "create-voc"; passing a package name like `backend` would be treated as a name filter and likely match nothing. `scripts/verify.sh --typecheck` likewise assumes the target has `pnpm --filter backend run typecheck`. Generalizing these commands is deferred until there is a second real target and fixture.

`scripts/verify.sh` is the stable verifier CLI seam: it loads env (`.env` and `apps/backend/.env` if present), runs the scoped vitest filter via the JSON reporter, and delegates result classification plus canonical VERIFY payload construction to the internal `scripts/lib/verify-result.cjs` module. Callers and tests use `verify.sh`; the internal module is not a second operator interface. The verifier treats as a **FAIL**:

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
- **Least-privilege role (fail closed).** Set `VERIFY_DATABASE_URL` (and optionally `VERIFY_DATABASE_URL_MIGRATE`) to point the run at a low-privilege role; it overrides `DATABASE_URL` for the run only. The superuser role `postgres` is rejected with exit 3 and typed failure code `privileged_database_role`. Pair with an isolated per-issue or clean persistent DB so a verifier run cannot mutate shared state.
- **No silent `.env` fallback in issue mode (fail closed, `exit 4`).** When `VERIFY_ISSUE` is set but `VERIFY_DATABASE_URL` is unset or empty, `verify.sh` **refuses with `exit 4`** ("refusing to fall back to .env DATABASE_URL") instead of inheriting the worktree `.env`'s `DATABASE_URL`. Incident (2026-07-13): an upstream `eval $(prepare-verify-db.sh ... | tail -1)` of empty stdout left `VERIFY_DATABASE_URL` unset, the suite ran against the shared dev DB `feedbackops`, and produced a garbage FAIL artifact. Run `prepare-verify-db.sh` and export its printed `VERIFY_DATABASE_URL` first.
- **Effective DB assertion.** Before running Vitest, `verify.sh` prints the effective database host/name/role injected into the child process, using the same redacted parser that writes `db_target` into the VERIFY artifact. Passwords are never printed or recorded.
- **Env scrub (default-deny allowlist).** The vitest child runs under `env -i` with only an allowlist passed through (`PATH HOME SHELL TERM LANG LC_ALL TMPDIR TMP USER LOGNAME PWD NODE_OPTIONS NODE_ENV DATABASE_URL DATABASE_URL_MIGRATE WORKSPACE_ID CI`, plus `PNPM_*`/`npm_config_*`, plus any names in `VERIFY_ENV_ALLOW`). Arbitrary host secrets (tokens/keys) do **not** leak into test/app code.
- **Clean-state and privilege preflight.** Canonical `VERIFY_ISSUE` runs require `VERIFY_CLEAN_COMMAND`. This target-owned command prints one sanitized JSON object with exactly two checks—`sentinel` and `migration_hash`, each carrying string `expected` and `actual`—plus `role:{name,superuser}` measured from the actual connection. The bundled reference adapter passes PostgreSQL connection details through `PGHOST`/`PGPORT`/`PGDATABASE`/`PGUSER`/`PGPASSWORD` environment variables to `psql`, never as a connection URL argument. It maps supported libpq TLS URL options (mode, CA/client cert/key, CRL/CRL directory, password, protocol bounds, negotiation, compression, and SNI) to the corresponding `PG*` variables; an unrecognized or empty URL query option fails closed before `psql` starts. Targets must preserve that no-URL/no-credential-argv contract. Any mismatch, URL-role identity mismatch, superuser evidence, undeclared field, missing/duplicate check, invalid JSON, or probe exit aborts before Vitest. `verify.sh --verify-clean` runs only this preflight. A successful canonical run projects only the declared fields into `clean_state.{sentinel,migration_hash,role}` in the existing VERIFY artifact; no second clean-state artifact is created. `--fresh` is reserved for migration chunks or crash recovery and refuses with `fresh_requires_adapter` until the target owns a DB lifecycle adapter; `verify.sh` never creates or drops databases.
- **Machine-readable failures.** Verifier failures retain human `FAIL:` diagnostics and also emit one or more cause-specific `VERIFY_FAILURE_JSON=` lines containing typed `code`/`expected`/`actual` records. The same classifier records appear in a failed canonical artifact's `failures[]`; values must be sanitized and must never contain URLs, credentials, or customer data.
- **Canonical provenance artifact.** When `VERIFY_ISSUE=<n>` is set, `verify.sh` writes `.review/ISSUE-<n>-VERIFY.json` (schema `schemas/verify.schema.json`, `artifact_type: "verify_result"`, `producer_role: "VERIFIER"`): branch, `head_sha`, cwd, `verify_cmd`, `env_profile`, `db_target` (host/database/role — **never a password**), `clean_state`, `verdict` (passed/failed/pending/exit_code), `classifier` (PASS/FAIL), `failures`, and `created_at`. This makes verifier output the canonical readiness signal, not worker prose. If a green run cannot write and re-read a valid artifact, the run fails closed with exit 5; evidence is the product. If the test run is already failing, an artifact-write failure preserves that failing classifier exit and never turns it green. With `VERIFY_ISSUE` unset, behavior is unchanged (no artifact).

### Per-issue verify DB provisioning (`prepare-verify-db.sh`)

`scripts/prepare-verify-db.sh --issue <N>` provisions the ephemeral `verify_issue_<N>` database and prints `VERIFY_DATABASE_URL=<url>` as its **last stdout line** — that line is the contract; consumers capture it with `eval $(... | tail -1)`. Two hardening rules (both from the 2026-07-13 incident):

- **Fail closed on any mandatory step.** If the base-url connection, `CREATE DATABASE`, or a supplied `--migrate-cmd`/`--seed-cmd` fails, the script exits non-zero and the `VERIFY_DATABASE_URL` line is **never printed** — printing it for a DB that doesn't exist poisons every downstream eval pipeline. (Previously a failed create was warned past and the line still printed.)
- **All DDL goes through `psql`, never the `createdb`/`dropdb` clients.** Those clients do not accept `-d <url>` (their `-d`-shaped option is `--maintenance-db`); on modern pg clients the old `createdb -d "$BASE_URL"` invocation failed with `invalid option -- d`. `psql` accepts the connection URI directly.
- **The admin URL's role must have the `CREATEDB` privilege.** On a stock `docker-compose.dev.yml` box only `postgres` (port 5434) can create databases — `fops_migrate` cannot. Use e.g. `PGADMIN_URL=postgres://postgres:...@localhost:5434/postgres` for provisioning, then hand the tests a low-privilege role via `VERIFY_DB_ROLE`/`VERIFY_DATABASE_URL`.

### Baseline-aware typecheck

Typecheck is **baseline-aware**: VERIFIER runs `scripts/verify.sh --typecheck`. It runs `pnpm --filter backend run typecheck`, extracts `error TS…` lines, and diffs them against `.review/typecheck-baseline.txt`. It fails **only** on errors absent from that baseline — i.e. NEW compile errors the change introduced. A pre-existing baseline error is never permission to merge a NEW compile error. If the typecheck command itself fails without any parseable `error TS...` lines, the oracle fails closed; an empty parsed result from a crashed command is not a pass.

Refresh `.review/typecheck-baseline.txt` (noting it in the commit) **only** when a pre-existing error is independently fixed — never to silence a new error.

### Dispatch scope and REVIEW byte identity

Before a write admission, every `contract.new_file_allowlist[]` path must be exact and safe, absent from `base_sha`, and matched by a declared `contract.touch_allowlist` pattern. REVIEW publication creates its immutable snapshot from the exact already-parsed and validated byte buffer used for canonical publication; it never re-reads mutable runner output between validation and snapshot creation.
