# Status

_Current as of 2026-07-21. `git log -1` and the schemas/scripts win any disagreement._

## Current release: v0.19

## Next: unreleased canonical VERIFY aggregate

- Canonical `ISSUE-N-VERIFY.json` now optionally retains ordered `runs[]` for repeated same-identity verifier runs. Its top-level verdict is validated as the derived aggregate, so a prior FAIL cannot be overwritten into false readiness by a later narrow-filter PASS. Only an absent `runs` property is legacy; a present malformed value is rejected.
- A later locally-green run returns nonzero while that aggregate remains red; a new HEAD begins a new aggregate. Legacy flat v1 artifacts remain accepted as one synthetic run.
- CONDUCTOR reconstruction schema-validates the complete canonical VERIFY from its source/installed product home before aggregate checks, while redispatch closure validation rejects forged aggregate top-level claims. A VERIFY closure needs a matching passing run for `contract.verify_filter`, not merely a top-level command string. Canonical publication validates a same-directory temporary file before atomic replacement, preserving prior evidence on publication failure.

The toolkit is operational and dogfooded against FeedbackOps. The current release includes:

- isolated worktree preparation and visible cmux dispatch, with a retained atomic launch runner so cmux receives only a short relative command even when the watchdog argv contains deep paths;
- sandboxed Codex implementation with model/effort pinning;
- project-owned model allocation defaults, evidence-gated Codex-only auto-dispatch, and preserved install upgrades;
- process + filesystem liveness, read-only heartbeat support, and retry-aware refusal probes;
- JSON artifact schemas, freshness/archive rules, and disk-only CONDUCTOR reconstruction;
- independent REVIEWER and host-side VERIFIER gates;
- a stable `verify.sh` CLI seam whose Vitest classification and canonical VERIFY payload construction live in the internal `scripts/lib/verify-result.cjs` module;
- an explicit REVIEWER publication path that runs Codex filesystem-read-only and host-validates its final JSON before atomically publishing the sole canonical REVIEW artifact;
- pre-review AC-ID existence checking;
- CONDUCTOR-calculated completion checking against live diffs and target-native test discovery;
- CONDUCTOR-owned canonical ROUND-STATE with a revision-pinned AC manifest view;
- Standard/Full Cluster initial-write admission that requires the complete canonical ROUND-STATE from dispatch 0 and binds it to the issue, tier, revision, real worktree, live HEAD, and integration base while preserving Trivial's pr_draft-only contract;
- a repository-native pre-scope-lock consumer pass for exported contracts, followed by a full-typecheck gate with ROUND-STATE `live_probes[]` evidence;
- compile-atomic `contract.chunk_boundary` enforcement: enumerated consumers stay inside one chunk, `completion-check.sh` executes its target-native full typecheck, and only live-diff-triggered convention watches enter review;
- a dispatch-bound repeated-round circuit breaker keyed to canonical failure-origin codes, with live evidence validation, atomic single-use admission, oracle/contract-first diagnosis, one manifest update, one integrated fix batch, and security early stop;
- a narrow `dispatch_contract` scoped-abort admission: a canonical BLOCKER can supply the sole failed-round evidence only after schema, issue, hash, referenced-commit, and producer-observed `head_sha` equality validation, while every other origin remains VERIFY/REVIEW-bound;
- a reusable Full Cluster ARCH feasibility appendix and non-vacuous test-matrix template: existing `live_probes[]` records command evidence, while every matrix row is a canonical acceptance criterion whose `id` is the AC-ID authority and whose inline `statement` has a precondition and observable checkpoint, plus a positive privacy field allowlist when privacy-relevant;
- a project-local `agent-workflow` skill plus installer-managed playbook/skill deployment;
- a location-derived product-home interface shared by the installer and completion/acceptance gates, including Git-metadata-free exports and source/installed schema resolution;
- a single distributable `toolkit/` authority separated from the root Matt Pocock development environment;
- copy-only fresh installation plus transactional `--upgrade` for recognized copies and correlated current/legacy absolute-link installations;
- an opt-in self-application boundary: toolkit development uses its general development skills, while `agent-workflow` may target this repository only with explicit `--self-test` dogfooding authorization;
- a root-owned release contract that checks toolkit containment, exact compatibility exceptions, source/portable-installed links, and target-install non-leakage;
- an offline Bash 3.2 smoke suite; this source repository runs the release gate and full suite in CI.

Run the current inventory instead of copying a count into docs:

```bash
bash scripts/__tests__/run-all.sh --list
NODE_OPTIONS= bash scripts/__tests__/run-all.sh
```

## Shipped timeline

### v0.19 — cmux launch-runner transport

- `cmux-dispatch.sh` atomically records a launch-unique worktree-local executable runner before cmux creation. The runner preserves the fully quoted watchdog argv and clears `NODE_OPTIONS`, while cmux receives only `bash .review/ISSUE-N-launch.<unique>/launch.sh` under its mandatory workspace cwd. Concurrent same-issue seats cannot overwrite one another before asynchronous execution.
- Each runner remains available for asynchronous startup and pre-RUN failures, and dispatch output identifies its exact path. Operators diagnose silent panes with `cmux read-screen --workspace <name> --scrollback --lines <N>`; `dquote>` and `heredoc>` are shell-transport evidence, not completion or liveness evidence.

### v0.19 — dispatch-contract scoped abort evidence

- `redispatch-check.sh` validates canonical BLOCKER schema and issue identity in addition to content hash and referenced commit checks, then requires its embedded producer-observed `head_sha` to equal the evidence reference.
- BLOCKER lifecycle is fail-closed for admission: only `active` and `final` are consumable, while `superseded` returns the stable `superseded_evidence_artifact` machine error.
- Only a `dispatch_contract` failure routed to `contract_fix` may use that BLOCKER as its sole failed-round evidence; the artifact union remains available elsewhere but does not weaken other origins' VERIFY/REVIEW requirement.
- Migration: pre-v0.19 BLOCKER artifacts without `head_sha` remain historical display evidence but are not redispatch-admissible; regenerate them at the observed commit instead of copying or relabeling stale evidence.

### v0.18 — verifier clean-state and machine failures

- Canonical issue verification now requires a target-owned clean probe whose sanitized JSON carries exactly `sentinel` and `migration_hash` expected/actual checks plus actual role/superuser evidence; dirty, privileged, or invalid state aborts before Vitest, and passing evidence is embedded in the existing VERIFY artifact.
- Every classifier failure exposes typed machine data, and failed canonical artifacts retain the same `code`/`expected`/`actual` records. Existing human diagnostics remain available.
- REVIEW closure admission now documents and independently checks `lifecycle:"final"`, `status:"pass"`, and an all-met checklist; its existing `failure_closure_not_verified` machine code carries a stable predicate detail for lifecycle, status, or checklist failure.
- No-filter invocation runs the full backend module by default. A `postgres` verifier role fails closed instead of warning, and `--fresh` is a stable reserved refusal until a target DB lifecycle adapter owns rebuild/drop behavior.
- `verify.sh` remains the sole operator interface while `scripts/lib/verify-result.cjs` owns result classification, clean-probe validation, and VERIFY payload construction.

### v0.17 — dispatch liveness operator contract

- The playbook now requires operators to preserve the dispatch command's own exit code and accept issue-scoped RUN/BLOCKER files only when their `mtime + started_at` identity belongs to the current launch.
- `status:"exited"` is explicitly process termination rather than task completion. Current retry behavior is recorded accurately: ordinary non-zero attempts retry from `running`, stall retries may move `killed_stall -> running`, and only a zero exit writes `exited` before the watchdog returns.
- Ambiguous retry decisions combine process absence with filesystem or heartbeat progress. Missing artifacts alone are not death evidence, and completion remains bound to canonical REVIEW/VERIFY at live HEAD.
- Sol/medium runs receive at least an eight-minute operator budget absent an earlier hard terminal signal; attempt stderr growth is an additional liveness signal, while a frozen small stderr plus a live process prompts a stdin-redirection check.

### v0.16 — read-only REVIEW publication

- `cmux-dispatch.sh --produce-review` forwards one explicit REVIEWER mode through the existing watchdog and safe wrapper without entering write admission.
- Codex runs with `--sandbox read-only`; the host captures its final message to a hidden same-directory temporary file, grants no Git writable root or failure stash, validates the review schema plus producer/issue/live-HEAD identity and fail-verdict requirements, and atomically publishes `.review/ISSUE-N-REVIEW.json`.
- Invalid output and non-zero reviewer exits remove temporary output without replacing prior canonical evidence. Pane prose and CONDUCTOR transcription remain non-authoritative.
- The legacy `--read-only` name is documented as heartbeat/liveness only; it does not change the Codex filesystem sandbox.

### v0.1 — artifact and verifier foundation

Introduced `.review/` JSON schemas, CODEX/REVIEWER handoffs, and the first false-green-proof Vitest classifier.

### v0.2 — host preparation and reconstructable state

Added worktree/env preparation, tier probing, state reconstruction, freshness/archive handling, safe in-flight rebasing, structured blocker/heartbeat/run artifacts, and baseline-aware typecheck.

### v0.3 — sandbox containment and verifier hardening

Proved that Codex `workspace-write` blocks network egress including loopback TCP and AF_UNIX. Kept DB verification outside the sandbox and added local-DB refusal, least-privilege guidance, env scrubbing, per-issue VERIFY provenance, and network-deny regression probes.

### v0.4 — dispatch and DB fail-closed fixes

Made `cmux-dispatch.sh` the mandatory visible dispatch path; fixed cwd/prompt resolution, stale RUN/BLOCKER acceptance, per-issue DB creation fail-open behavior, and `verify.sh`'s unsafe `.env` DB fallback.

### v0.5 — wrapper contracts, acceptance gate, and portable skill entrypoint

- `cmux-dispatch.sh` forwards model/effort and optional liveness budgets.
- `codex-safe.sh` grants only a linked worktree's or plain checkout's resolved Git metadata dir and supports read-only heartbeats.
- `codex-watchdog.sh` classifies refusal from two failed probes rather than stderr text.
- `ac-check.sh` rejects duplicate or undiscovered manifest AC ids before review.
- The integrated wrapper changes passed clean-context review and a full smoke run at `main@5500d6a`.
- The versioned Claude skill is now a thin router; `install-into.sh` deploys scripts, schemas, playbook docs, and the project-local skill.
- Target adoption now has an explicit feedback loop: sanitize and classify a reproducible toolkit problem, search existing reports, obtain external-write authorization, file it in this repository, and link the upstream issue from the target handoff/completion report.

### v0.6 — canonical contract state

- `ISSUE-N-ROUND-STATE.json` replaces fragmented amendment prose with one CONDUCTOR-owned contract artifact.
- The acceptance manifest is the artifact's `acceptance.criteria[]` view; its revision is the ROUND-STATE top-level `revision`.
- `ac-check.sh` validates the canonical schema and base freshness, then rejects stale `--manifest-revision` values before checking duplicate or boundary-aware undiscovered AC ids.

### v0.7 — completion calculation gate

- `completion-check.sh` independently calculates the declared worktree's `base_sha..HEAD` changed paths and compares them to the ROUND-STATE touch allowlist.
- It verifies canonical AC-ID discovery and `acceptance.expected_test_count` without trusting worker prose, RUN.json, or PR-DRAFT claims, and returns machine-readable mismatch/error codes that block review.
- Test discovery remains a target-profile input; the coordination core does not assume Vitest.

### v0.8 — relocatable product-home interface

- `install-into.sh` distinguishes location-derived `PRODUCT_ROOT` from optional Git `REPOSITORY_ROOT` safety context, so a metadata-free export remains installable.
- `ac-check.sh` and `completion-check.sh` share one product-home schema resolver across source, symlink, and copy layouts.
- Installation smoke executes both gates from real temporary Git targets and covers a metadata-free export in a path containing spaces; source commands now require the canonical sibling `schemas/` directory.
- Physical authority migration into `toolkit/`, legacy-install migration, and release enforcement remain ordered follow-ups in #29–#31.

### v0.9 — distributable authority separation

- Product scripts, schemas, docs, canonical skill, tests, README, STATUS, environment example, and scoped instructions live beneath `toolkit/`.
- Root Matt skills, tracker/domain/triage configuration, plans, CI, hooks, and runtime evidence remain repository-owned and are excluded from target installs.
- Product issue reporting is self-contained, and the duplicate Matt-directory `agent-workflow` skill has been removed.
- `cmux-cluster.sh` now checks the target's installed `.agent-workflow/{scripts,schemas}` contract instead of source-checkout paths.

### v0.10 — safe legacy installation migration

- The installer recognizes each live or dangling pre-separation absolute link, including partial and moved-root installations, and refuses default mutation with an actionable migration command.
- Relocated or deleted post-separation product homes are recognized through the same fail-closed migration path, including the current `schemas/` layout.
- `--migrate-legacy` replaces only recognized legacy links in symlink or copy mode; real files, directories, snapshots, and unrecognized links remain target-owned.
- Symlinked managed parents are rejected before default, migration, or force-mode mutation, so installation cannot follow a parent link outside the target.
- Copy snapshot/update behavior and the exact destructive scope of `--force` are documented.
- Fresh, migrated, and Git-metadata-free installations execute installed acceptance and completion gates without maintainer-state leakage.

### v0.11 — separated-toolkit release contract

- The root-owned release gate enforces one product authority beneath `toolkit/`, exact historical/compatibility exceptions for legacy paths, and valid local Markdown links in source and copy-installed contexts.
- Copy-install release checks reject Matt skills, tracker/domain/triage configuration, plans, CI, hooks, and repository evidence in target trees.
- GitHub CI runs the release contract followed by the full product smoke suite with a clean `NODE_OPTIONS=` value.
- The pre-separation symlink recognizer remains only as the documented `--migrate-legacy` compatibility contract; product-home schema resolution has no root-layout fallback.

### v0.12 — compile-atomic chunks and triggered convention watches

- Exported-contract chunks record exact compile consumers and a target-native typecheck command in canonical ROUND-STATE rather than a parallel impact manifest.
- Completion calculation rejects consumers outside the chunk allowlist and a failed full typecheck.
- Convention-only watches remain durable in ROUND-STATE, while only path-triggered watches assigned to the current chunk are emitted as REVIEWER obligations with declared checklist closure evidence.

### v0.13 — repeated-round circuit breaker

- ROUND-STATE classifies every failed implementation round with one primary origin, optional secondary origins, failed AC ids, owner/action routing, and hash/HEAD-bound evidence references.
- `redispatch-check.sh` validates live worktree HEAD plus coherent VERIFY/REVIEW failure verdicts, origin/action routing, and closure lineage/scope (exact failed ACs plus canonical verify filter or checklist item) before it blocks on two consecutive failures with the same primary origin or before a third redispatch.
- `cmux-dispatch.sh` atomically records every write attempt before cmux, binds returned admission to the CLI issue/worktree, and consumes an immutable issue/ordinal key plus an issue-wide integrated-fix singleton in the Git common dir; dry-runs do not consume admission and read-only seats remain outside the circuit.
- A tripped circuit rechecks oracle/contract first, requires a hard fact plus passing-analog parity instruction, and permits at most one manifest increment and one integrated fix batch; security findings may stop earlier.

### v0.14 — portable copy installation and transactional upgrade

- Fresh installation always creates four self-contained directory copies; the installer no longer creates machine-bound absolute symlinks.
- `--upgrade` recognizes complete copy installations and correlated current or pre-separation absolute-link layouts, including dangling links, then converts all four managed leaves to current copies.
- Upgrade stages every source tree before mutation, retains the previous leaves under `.review/agent-workflow-install-backups/`, verifies rollback after a failed backup or swap, and reports exit `70` plus the retained backup if restoration itself is refused.
- Partial, mixed, structurally unrecognized, uncorrelated, and managed-parent or backup-parent symlink layouts fail closed. Removed `--mode`, `--force`, and `--migrate-legacy` flags only provide migration guidance.
- Product docs and the root release contract now describe and exercise the portable installed context.

### v0.15 — canonical state from initial write

- Standard-tier work generates the same complete canonical ROUND-STATE used by later tiers, omitting optional Full Cluster structures instead of creating a second mini-state authority.
- Standard/Full Cluster initial `cmux-dispatch.sh` launches and every redispatch require the canonical path plus revision; initial admission rejects malformed, inactive, wrong-issue/tier/revision/worktree/HEAD/base state and Standard state without `pr_draft` + `review` pointers before cmux starts. Trivial initial writes remain pr_draft-only.
- The source and portable installed contracts exercise the round-0 requirement while read-only seats remain outside write admission.

## Compatibility boundary

| Area | Current status |
|---|---|
| Dispatch, watchdog, artifact lifecycle | Reusable across Git repositories with cmux + Codex |
| `prepare-worktree.sh` | pnpm plus root/`apps/backend` env layout |
| `tier-probe.sh` | TypeScript/TSX exported-contract heuristics |
| `verify.sh` | pnpm workspace package `backend` + Vitest |
| `prepare-verify-db.sh` | local PostgreSQL per-issue DBs |
| branch/cluster helpers | retain `feature/*`, pane-label, and integration-branch conventions |

The next generalization must be based on a second real target. The intended split is a stable coordination core plus a small target profile for install commands, env paths, branch patterns, tier triggers, verification commands, and service isolation. See `.claude/skills/agent-workflow/references/adoption.md`.

## Key operating facts

- A process exit or worker prose is not completion evidence. Review and verification must match the live HEAD.
- Write-capable Codex dispatch goes through `cmux-dispatch.sh` → `codex-watchdog.sh` → `codex-safe.sh`.
- Read-only seats use `--read-only`; optional first-progress/stall budgets are forwarded only when supplied.
- Parallel write chunks require separate worktrees. FeedbackOps-style DB suites also require separate throwaway databases.
- The sandbox cannot reach a local DB, so VERIFIER runs outside it with a local, low-privilege URL.
- `VERIFY_ISSUE` without `VERIFY_DATABASE_URL` fails closed instead of using a shared `.env` DB.
- A failed refusal probe is inconclusive; only two failures separated by the configured gap produce `status:"refused"`.
- Write-capable Codex receives only the resolved Git metadata dir for either a linked worktree or plain checkout, never a broader checkout or parent root.

## Open roadmap

- **P0 toolkit separation:** #27–#31 are shipped: relocatable product home, single `toolkit/` authority, safe legacy migration, and release enforcement.
- **P1 procedure/templates:** #9, #10, and #11 are shipped (circuit breaker, compile-atomic chunks, and canonical Standard round-0 state).
- **P2 toolkit/procedure:** #13 verifier output/freshness is shipped; #14 and #17 remain evidence-gated integrated-head closure and re-review capsule work; #19 is shipped in `codex-safe.sh`.
- **P3 telemetry:** #18 — model-by-task measurements before revisiting tier allocation.
- **Upstream blocked:** [openai/codex#6737](https://github.com/openai/codex/issues/6737) remains open as of 2026-07-20; reconsider in-sandbox loopback verification only if a containment-preserving allowance ships.

GitHub issues are the live roadmap; this section is a readable index, not a second issue tracker.

## Provenance

The workflow was extracted from FeedbackOps on 2026-05-24 with path-scoped `git filter-repo` history. This repository is the canonical home for workflow scripts, schemas, playbooks, and the project skill. FeedbackOps remains product-only and consumes the toolkit through installation rather than carrying a second copy.

## Maintenance rule

Continue the same evidence loop: scoped implementation, clean-context review, independent verification, then doc synchronization. Any script/schema/contract change updates the playbook, README, STATUS, and affected installer/skill references in the same commit. Do not merge or push without explicit user approval.
