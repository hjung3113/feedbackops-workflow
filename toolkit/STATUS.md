# Status

_Current as of 2026-08-21. `git log -1` and the schemas/scripts win any disagreement over this file's prose; see "Shipped timeline" below for release-by-release detail._

**cmux archived (2026-08-22):** only orca + herdr are actively worked. cmux (#208)
stays registered in `transport-registry.cjs` and its adapter/tests are untouched
(removing it would break ~170 cmux-premised test cases), but it is not next-priority
work — its live capability is already runtime fail-closed against real cmux 0.64.x.
Revisit once orca/herdr are confirmed stable against real binaries.

## In progress: v0.21 generic distribution and runtime symmetry

- T1 adds an additive `execution_mode=headless|live-tui` seam, shell-free
  runtime launch specs, structured live handles, semantic session capability
  vocabulary, and transport receipt schema v4. Headless remains the default
  and existing runner/watchdog behavior is preserved. Live phase 1 is
  implementation/write-only and fails closed until a transport proves the
  complete live contract; Orca, Herdr, and cmux adapter implementations land
  in the dependent follow-up tasks. `LIVE.json` is launch/liveness evidence,
  not completion authority.

- T2 makes Orca the first live-capable transport: its capability probe now
  help-proves every interactive primitive (`--terminal`, `--cursor`, `--for`,
  `tui-idle`, `--timeout-ms`, `--text`, `--enter` across `orca terminal
  read/send/wait/close --help`) before emitting the `session.*` vocabulary,
  keeping headless/live availability split when a token is missing.
  `launch-live` builds Orca's single `--command` string by `printf %q`-quoting
  each launch-spec env assignment and argv token, refuses a second terminal
  for one worktree + seat (duplicate-prompt prevention), and returns
  structured terminal handles. `wait-ready` gates on tui-idle only, `read`
  emits stable output+cursor bytes, `wait-settled` maps tui-idle→settled /
  unsatisfied→working / native blockedReason→blocked as hints, and stale
  handles are reacquired only on an exact single worktree + seat-title match.
  Covered by `scripts/__tests__/orca-live.smoke.sh` (fake orca CLI asserting
  received argv per ADR 0004).

- T3 lands the Herdr live adapter path: the agent facade
  (`start/prompt --wait/wait/read/send-keys`) behind the T1 session seam,
  `--kind` forwarded as launch-spec data, NUL-exact argv forwarding, and a
  per-capability-call fresh/untrusted-worktree trust-prompt race acceptance
  test (herdrdev/herdr#2410) that keeps live unavailable — headless intact —
  unless the installed herdr classifies the trust-prompt sentinel as
  `blocked`. Covered offline by `herdr-live.smoke.sh`, including native
  `agent_prompt_stalled`, settled-without-fresh-artifact refusal, and
  same-issue duplicate-prompt prevention through the full live dispatch E2E.

- T4 lands the cmux live adapter: direct-argv `run` launch with structured
  `{workspace, surface, terminal}` handles (no `external_handle` alias),
  byte-exact `--bytes` prompt delivery plus a separate `send-key enter`,
  readiness via `wait-for` as a sync-only gate, and `wait-settled` admitted
  only through the help-proven `list-agents` state query (otherwise cmux
  never reports `settled`; canonical artifacts stay the only completion
  authority). Live token proof runs under `capabilities --worktree <path>
  --probe-live` and at subcommand use time so headless dispatches make zero
  extra vendor calls; live dispatch admission for cmux additionally waits on
  a dispatch-core live-intent signal (T1 seam follow-up). Installed cmux
  0.64.x lacks the direct-argv surface, so its live capability correctly
  fails closed today. Covered by `scripts/__tests__/cmux-live.smoke.sh`.

- CONDUCTOR no longer hand-copies a prior issue's ROUND-STATE (#159):
  `scripts/round-state-init.sh <issue-number> --worktree <path>` scaffolds a
  schema-validated skeleton (issue identity and AC candidates from
  `gh issue view`, git base/head SHAs, worktree path; scaffold-once with
  `--force` opt-in), and `scripts/round-state-render-ac.sh --round-state
  <path>` renders the prompt AC block from canonical
  `acceptance.criteria[]`, eliminating the hand-duplicated copy that could
  drift past `prompt-ac-check.sh`. Author-owned contract fields remain
  explicit TODO placeholders seeded to satisfy the schema's minLength/minItems
  floors; the tool automates no CONDUCTOR judgment calls.

- Dispatch failures now leave a pollable terminal-status artifact even when
  admission refuses before the watchdog starts (#163): every watchdog
  `write_marker` appends a `run_status` line to the append-only
  `.review/ISSUE-N-EVENTS.jsonl`, admission refusals append an
  `admission_refused` line (`status:"refused"`, `attempt:0`, refusal code in
  `detail`), and a new `dispatch-core.sh await --issue N --cwd DIR
  [--timeout-seconds SECS]` subcommand blocks on that log's last terminal
  status. RUN.json's single-slot-overwrite contract is byte-identical and no
  existing caller's behavior changes without opting into `await`.

- The three transport adapters now share one implementation each of semver
  parsing and floor checks (`scripts/lib/semver.cjs`, prerelease-aware, with a
  strict whole-string mode for Orca's runtime appVersion), capability payload
  emission (`scripts/lib/adapter-json.cjs`, referencing the field set owned by
  the `capability-result.cjs` acceptance gate), and the shell-side help probe,
  runner-path glob guard, graceful `handle_unverifiable` fallback, and
  `"<version>;binary-sha256:<digest>"` provenance format
  (`scripts/lib/adapter-helpers.sh`). Per-adapter CLI arg loops and case
  dispatch are intentionally not framework-unified.
- Ignored installed `.agent-workflow` is an explicit absolute PRODUCT_HOME:
  fresh linked worktrees invoke its scripts with `--worktree`, while workflow
  selection and allocation config stay in PRODUCT_HOME and prompt paths remain
  worktree-relative.
- Output-producing prompts use one schema-derived output-contract module. Implementation prompts carry canonical PR-DRAFT plus BLOCKER schemas; the shared runtime boundary requires a fresh schema-valid PR-DRAFT bound to its issue, live HEAD, and real worktree before recording exit, while CODEX validates canonical BLOCKER output before returning. Dispatch rejects malformed fresh BLOCKER liveness, and selected-runtime model refusals are terminal. Model allocation records runner availability and fails before admission. Dispatch-core maps only the read-only/implementation roles (reviewer, implementation, architect) to output-contract admission; `conductor` and `release` are intentionally not dispatch-core-mapped and remain manual/CLI-only roles reachable via `output-contract.sh` / `prompt-ac-check.sh --output-contract-role`.
- REVIEW dispatch is host-authoritative for `reviewed_head_sha` (#137): the watchdog pins the worktree HEAD at launch, injects it literally into the reviewer launch prompt (bash-denied read-only reviewers cannot discover it themselves), and overwrites the model-returned field with the pinned value before schema validation. The exact-match fail-closed contract is unchanged.
- REVIEW publication now retains an immutable head-bound snapshot from the same already-validated bytes as its canonical evidence, preventing mutable-output rereads; a later failing REVIEW may explicitly supersede a subset of prior ACs through checked `closed_by.kind:"superseded_by"`. Malformed pre-existing BLOCKER bytes follow a host-owned quarantine/recovery path that records reason and permits one fresh monotonic-ordinal admission without canonicalizing worker evidence.
- Schema-derived prompts now embed the complete canonical requested schema rather than a lossy projection. Completion requires an exact `new_file_allowlist` entry for every base-absent changed path, and dispatch requires that entry to remain inside `touch_allowlist`; partial supersession must carry every remaining AC into later active failure evidence; host ordinals are exact-next and `last_admission_key` is failure-bound.

- Installation is a single target-neutral mode. The former `--profile
  feedbackops` compatibility distribution and its adapters (`verify.sh`,
  `prepare-verify-db.sh`, `prepare-worktree.sh`, `tier-probe.sh`,
  `uds-pg-relay.mjs`, `lib/verify-result.cjs`) were removed; installed assets
  carry no target-specific verification, tracker, labels, domain, layout, or
  maintainer assumptions.
- The source-only smoke suite is excluded from every installed PRODUCT_HOME;
  an installed target uses its workflow commands and target-owned verification,
  while maintainers run smoke from the source checkout.
- Runtime (`codex|claude|opencode|omp`), role (including conductor), and transport
  (`cmux|orca|herdr`) are independent admitted axes. Capability probe, observed
  runtime version, RUN/receipt provenance, and no-fallback failures are part
  of the contract; only fresh canonical REVIEW and VERIFY evidence at live HEAD
  retains completion authority. Herdr requires an inherited session
  (`HERDR_ENV=1` and non-empty `HERDR_WORKSPACE_ID`/`HERDR_TAB_ID`/`HERDR_PANE_ID`) and never falls back.
- The admitted transport set lives in one registry module
  (`scripts/lib/transport-registry.cjs`); CLI selection, the shared core, and
  routed admission consume it at runtime, and a release-gate parity check
  keeps the static receipt/telemetry schema enums exact (telemetry keeps its
  legacy `local` value, which is not a registered adapter).
- Reviewer allocation can be explicitly requested per runtime: the shipped
  Claude entry uses `sonnet`, while OpenCode remains target-provider-configured
  and refuses before admission when no `reviewer_by_runtime.opencode` tuple is
  supplied.
- Implementation allocation is runtime-aware: `implementation_by_runtime.<runtime>`
  is used when configured (skipping the `trivial_implementation` swap, adjusting
  effort only), otherwise the default `implementation` entry; a default model
  whose `available_via` excludes the selected runtime fails closed before
  admission.
- GPT-5.6 allocations accept the official `none`, `low`, `medium`, `high`,
  `xhigh`, and `max` efforts for Sol, Terra, and Luna and preserve them through
  routing, receipts, recovery, and telemetry. The scorecard retains its
  comparable LiveBench capability fields while refreshing official API prices.
- OpenCode is deny-first: a permission JSON denies `*`, write explicitly allows
  edit, and read does not. Missing/invalid configuration is admission failure,
  not permission to substitute another runtime.
- `agent-watchdog.sh` is the shared retry/liveness authority and publishes
  runtime/role/version-bound `agent_run` markers; watchdog attempts are not
  redispatch ordinals. `codex-watchdog.sh` was removed (#127); `codex_run` artifacts remain legacy-readable.
- Non-Codex REVIEWER stdout accepts a prose-wrapped final fenced JSON object
  only through host transcription, then retains the existing schema/producer/
  issue/live-HEAD publication gate. Refusals retain raw output as
  non-authoritative diagnostics and record a typed RUN refusal reason.
- OpenCode config is injected as `OPENCODE_CONFIG_CONTENT` and must define the
  deny-first named primary `agent-workflow`; invocation pins `--agent
  agent-workflow` to reject built-in/default-agent fallback.
- Transport receipt schema v2 requires runtime provenance. Policy-opted
  canonical redispatches use receipt v3 only after its entire routing tuple
  (runtime, tier, selected model/effort, transport, policy, and reasons)
  matches the host admission binding; the digest is derivative provenance,
  never admission or completion authority. Schema v1 remains legacy-readable but
  non-authoritative. The selected runtime executable is resolved to one
  absolute pin before admission and cannot come from target config.
- Read-only `--conductor-control` accepts one untrusted ROUND-STATE proposal and
  delegates the only write to a locked host publisher with schema, issue,
  live-HEAD, worktree, base, path, and revision checks.

## Current release: v0.20

## Current integrated capabilities

- Added one draft-07 target profile authority with structured argv/cwd/env commands, representative Node/Go/Python profiles, and a target-neutral verifier that executes every required group, records UTF-8 byte-bounded evidence, publishes extractor misses as `test_count:null` FAIL evidence, and red-latches same-HEAD failures only after schema plus semantic aggregate validation.
- Canonical VERIFY evidence has one exclusive shape: artifacts require `target_profile + groups`; empty PASS artifacts are schema-invalid. PASS command exits must all be zero and any recorded test count must be a positive integer, enforced independently by schema and the target-neutral `verify-artifact.cjs` semantic validator. The Node example and smoke use actual `node --test` TAP output (`ℹ tests N`). Worktree setup and tier routing are target-profile concerns.

- Re-review now uses a deterministic, schema-validated capsule derived from canonical ROUND-STATE, the full implementation prompt, final REVIEW, PR-DRAFT, and live HEAD. Canonical structured prohibitions, strict PR-DRAFT worktree/base binding, whole-prompt cumulative budgets with explicit omission counts, source digests, secret/path guards, and a capsule-Markdown-bound dispatch gate prevent freehand review drift without creating a second authority.

- Canonical execution plans now classify write-seat pairs deterministically. Only disjoint exact write sets with proven dependency/resource/isolation/budget safety are parallel-eligible; all uncertainty serializes, while a one-seat plan preserves sequential operation.
- Planned dispatch admission binds issue, round/revision, base HEAD, real worktree, seat, and exact ROUND-STATE allowlist before atomically consuming a same-seat plan hash. Existing initial/redispatch/integrated-fix protections remain layered underneath.
- Ordered candidate integration records every source/resulting HEAD and blocks stale/unrebased sources, unexpected paths, conflicts, dirt, and duplicate/missing/reordered integration steps. Candidate closure requires each underlying artifact to carry the same direct attempt binding, accepts only final REVIEW plus active PR-DRAFT lifecycle, rejects wrapper-only same-HEAD relabels and invalid RFC3339 instants, and becomes stale after any later commit.

- Added opt-in local append-only model/task telemetry with salted project pseudonyms, canonical artifact digests, truthful observed/estimated/unavailable usage, concurrency-safe idempotence, and explicit single-sample deletion. Green consumes the parallel-safety producer's canonical closure plus its canonical integration/evidence sources through byte-identical shared #14 schemas, actual byte digests, strict semantic RFC3339 dates, and generation/RUN freshness ordering; salt/store realpaths must remain target-local. Policy-routed telemetry v2 validates a v3 or v4 transport receipt against the current host admission binding and derives runtime/model/effort/transport only from the matching host tuple; raw digest and CLI tuple injection are refused. Route probing caches static pinned executable/configuration identity for at most 1800 seconds by default (3600 maximum), without asserting remote model availability. Retry reports enforce immutable project/issue/round/revision lineage, contiguous admitted attempts and valid edges, expose per-attempt allocation, and suppress mixed-model chains from single-model cohorts. v2 routing cohorts use homogeneous policy samples, complete independent-chain thresholds, complete-green rate, mean retries-to-green, mean wall time, and a confounder warning. Reports are advisory and cannot mutate allocation or tier policy.
- Candidate closure and telemetry now consume one strict calendar-valid RFC3339 parser. Telemetry sample semantics bind closure source/hash/value to unique canonical closure, integration, and candidate-evidence artifact paths and digests, with dedicated schema-valid semantic pass/fail fixtures.
- cmux create-result normalization and workspace-list inspection now consume one handle module with a single ID/ref allowlist, preventing launch and inspection identity rules from drifting.

- Standard/Full initial writes and canonical write redispatches now fail closed unless the worker prompt contains one delimited JSON AC block that exactly copies the ordered ROUND-STATE `acceptance.criteria[]` IDs and statements. CONDUCTOR performs an unedited context dump, one user-facing reverse-question batch (or explicit skip), then compression; CONTEXT/PROMPT Markdown files are uncommitted, non-archival scratch, and `model-alloc.json` owns an advisory-only prompt target budget.

- Canonical `ISSUE-N-VERIFY.json` carries a required `content_sha256`: a stable digest of Git-visible working content (tracked plus non-ignored untracked paths, excluding `.review/`). It optionally retains ordered `runs[]` for repeated same-HEAD-and-content verifier runs. Its top-level verdict is validated as the derived aggregate, so a prior FAIL cannot be overwritten into false readiness by a later narrow-filter PASS.
- A later locally-green run returns nonzero while that same-content aggregate remains red; corrected uncommitted content starts a new aggregate even when `HEAD` is unchanged. The verifier rejects a worktree that changes while verification is running, and CONDUCTOR requires both live HEAD and content identity before reporting verified. Legacy flat v1 artifacts remain accepted as one synthetic run.
- CONDUCTOR reconstruction schema-validates the complete canonical VERIFY from its source/installed product home before aggregate checks, while redispatch closure validation rejects forged aggregate top-level claims. A VERIFY closure needs a matching passing run for `contract.verify_filter`, not merely a top-level command string. Canonical publication validates a same-directory temporary file before atomic replacement, preserving prior evidence on publication failure.

The toolkit is operational. The current release includes:

- isolated worktree preparation and explicit cmux/Orca/Herdr dispatch through one shared correctness core, with a retained atomic launch runner so the selected adapter receives only a short relative command even when the watchdog argv contains deep paths;
- runtime-neutral dispatch with capability-probed Codex, Claude Code, or OpenCode execution; Codex write/review delegates to its hardened sandbox wrapper;
- project-owned model allocation defaults (including omitted-model dispatch), schema-validated evidence-gated Codex-only auto-dispatch, source-dated static-plus-reasoning review preference, and preserved install upgrades;
- shared process + filesystem liveness, per-runtime retry/refusal probes, and runtime-provenance RUN markers;
- JSON artifact schemas, freshness/archive rules, and disk-only CONDUCTOR reconstruction;
- independent REVIEWER and host-side VERIFIER gates;
- an explicit runtime-neutral REVIEWER publication path that requires read mode, holds linked-worktree Git HEAD/ref locks through publication, and host-validates final JSON before atomically publishing the sole canonical REVIEW artifact;
- pre-review AC-ID existence checking, with implementation prompts requiring each test name to carry its canonical AC-ID;
- CONDUCTOR-calculated completion checking against live diffs and target-native test discovery;
- CONDUCTOR-owned canonical ROUND-STATE with a revision-pinned AC manifest view;
- Standard/Full Cluster initial-write admission that requires the complete canonical ROUND-STATE from dispatch 0 and binds it to the issue, tier, revision, real worktree, live HEAD, and integration base while preserving Trivial's pr_draft-only contract;
- a repository-native pre-scope-lock consumer pass for exported contracts, followed by a full-typecheck gate with ROUND-STATE `live_probes[]` evidence;
- compile-atomic `contract.chunk_boundary` enforcement: enumerated consumers stay inside one chunk, `completion-check.sh` executes its target-native full typecheck, and only live-diff-triggered convention watches enter review;
- a dispatch-bound repeated-round circuit breaker keyed to canonical failure-origin codes, with live evidence validation, atomic single-use admission, oracle/contract-first diagnosis, one manifest update, one integrated fix batch, and security early stop;
- a narrow `dispatch_contract` scoped-abort admission: a canonical BLOCKER can supply the sole failed-round evidence only after schema, issue, hash, referenced-commit, and producer-observed `head_sha` equality validation, while every other origin remains VERIFY/REVIEW-bound;
- a reusable Full Cluster ARCH feasibility appendix and non-vacuous test-matrix template: existing `live_probes[]` records command evidence, while every matrix row is a canonical acceptance criterion whose `id` is the AC-ID authority and whose inline `statement` has a precondition and observable checkpoint, plus a positive privacy field allowlist when privacy-relevant;
- a project-local `agent-workflow` skill plus installer-managed playbook/skill deployment;
- an optional installer-managed pointer block in an existing target-root `AGENTS.md`, making the project-owned allocation contract and conductor boundary visible without creating or taking ownership of target instructions;
- a location-derived product-home interface shared by the installer and completion/acceptance gates, including Git-metadata-free exports and source/installed schema resolution;
- a single distributable `toolkit/` authority separated from the root Matt Pocock development environment;
- copy-only fresh installation plus transactional `--upgrade` for recognized copies and correlated current/legacy absolute-link installations;
- an opt-in self-application boundary: toolkit development uses its general development skills, while `agent-workflow` may target this repository only with explicit `--self-test` dogfooding authorization;
- a root-owned release contract that checks toolkit containment, exact compatibility exceptions, source/portable-installed links, and target-install non-leakage;
- an offline Bash 3.2 smoke suite; this source repository runs the release gate and full suite in CI;
- a self-diagnosing smoke runner: a failing smoke's inner diagnostic is emitted and retained by path, callers can supply a line-oriented `--redact-values-file` whose literal values are masked in both outputs while raw failure captures are discarded, `--list` answers without allocating temporary storage, and asynchronous fixtures wait on named conditions instead of fixed sleeps. Redaction is an explicit caller contract, not automatic secret discovery. `--for-paths "<paths>"` narrows the suite to the smokes mapped in `scripts/__tests__/smoke-coverage.manifest`, failing open to the full suite (with a stderr WARNING) whenever any given path lacks known coverage; `scripts/__tests__/flake-registry.manifest` records owner-dated known flakes that report `FLAKY -` with retained diagnostics but do not fail the run until their expiry auto-graduates them back to ordinary failures.

Run the current inventory instead of copying a count into docs:

```bash
bash scripts/__tests__/run-all.sh --list
NODE_OPTIONS= bash scripts/__tests__/run-all.sh
```

The runner's own contract test lives outside the live inventory (so the suite cannot re-enter itself) and is run directly:

```bash
bash scripts/__tests__/run-all-contract.test.sh
```

## Shipped timeline

### v0.20 — explicit cmux/Orca/Herdr transport interface

- `agent-workflow.sh` exposes `capabilities`, `dispatch`, and `inspect`. Dispatch selection is explicit and deterministic: CLI, then `AGENT_WORKFLOW_ORCHESTRATOR`, then target-local config; missing, unknown, or unavailable selections fail without a default or fallback.
- `dispatch-core.sh` is the sole owner of ROUND-STATE/prompt validation, HEAD/worktree binding, atomic admission, launch-unique runners, and RUN/BLOCKER freshness. Thin cmux, Orca, and Herdr adapters receive only a typed seat request; `cmux-dispatch.sh` remains an explicit cmux compatibility facade.
- Every launch publishes a schema-valid, non-authoritative `ISSUE-N-TRANSPORT.json`; policy-opted canonical redispatch uses v3 only after validating the immutable ordinal binding (and integrated companion when applicable). `inspect` queries the adapter's external handle read-only and normalizes live, missing/stale, and unverifiable probes while independently detecting a missing or changed runner. Orca launch accepts only `result.terminal.handle`, and inspect matches that handle only against `result.terminals[].handle`; the create response's top-level request `id` is never a terminal identity. cmux launch accepts exactly one create-result `id`/`workspace_id`/`workspaceId`/`ref`, never the requested display name, and inspect matches only that unique identity. Herdr uses the returned `workspace_id` as its external handle, never a requested label or pane ID. These receipts record launch intent/provenance, not confirmed command delivery, and none of this transport evidence replaces canonical REVIEW/VERIFY evidence.
- Before admission, cmux proves a `0.64.0` version floor plus side-effect-free help for the actual workspace-create cwd/command contract, Orca proves create worktree/title/command/JSON plus read-only list capabilities, and Herdr proves its required capabilities only from an inherited session (`HERDR_ENV=1` with non-empty `HERDR_WORKSPACE_ID`/`HERDR_TAB_ID`/`HERDR_PANE_ID`). Herdr session/probe failures do not consume admission and never fall back to another transport. Orca records only a plausible `result.runtime.appVersion` from `orca status --json`; unavailable, malformed, or implausible values are `unknown`. Probe failures do not consume admission. Orca opens a fresh bare-shell terminal at the exact existing worktree and refuses ambiguous handles. Offline fake-adapter smokes cover selection, no fallback, parity, receipts, and external-handle inspection; live GUI E2E remains a separately labeled gate. A live Herdr workspace is liveness evidence only, not workflow completion.
- The core resolves the caller's Codex binary to one absolute executable before admission and pins it through the runner, watchdog, and safe wrapper; the host-only override is fail-closed and target config cannot inject a binary. cmux receipts use one proven create-result id/ref rather than a display name, so duplicate names and removed workspaces inspect correctly.

### v0.19 — cmux launch-runner transport

- `cmux-dispatch.sh` atomically records a launch-unique worktree-local executable runner before cmux creation. The runner preserves the fully quoted watchdog argv and clears `NODE_OPTIONS`, while cmux receives only `bash .review/ISSUE-N-launch.<unique>/launch.sh` under its mandatory workspace cwd. Concurrent same-issue seats cannot overwrite one another before asynchronous execution.
- Each runner remains available for asynchronous startup, pre-RUN failures, and its receipt-bound diagnostic lifetime; a later same-issue receipt serially retires prior receipt-marked runners. Dispatch output identifies its exact path. Operators diagnose silent panes with `cmux read-screen --workspace <name> --scrollback --lines <N>`; `dquote>` and `heredoc>` are shell-transport evidence, not completion or liveness evidence.

### v0.19 — dispatch-contract scoped abort evidence

- `redispatch-check.sh` validates canonical BLOCKER schema and issue identity in addition to content hash and referenced commit checks, then requires its embedded producer-observed `head_sha` to equal the evidence reference.
- BLOCKER lifecycle is fail-closed for admission: only `active` and `final` are consumable, while `superseded` returns the stable `superseded_evidence_artifact` machine error.
- Only a `dispatch_contract` failure routed to `contract_fix` may use that BLOCKER as its sole failed-round evidence; the artifact union remains available elsewhere but does not weaken other origins' VERIFY/REVIEW requirement.
- Migration: pre-v0.19 BLOCKER artifacts without `head_sha` remain historical display evidence but are not redispatch-admissible; regenerate them at the observed commit instead of copying or relabeling stale evidence.

### v0.18 — verifier clean-state and machine failures

- (Historical v0.18, compatibility adapter since removed.) Canonical issue verification required a target-owned clean probe whose sanitized JSON carried exactly `sentinel` and `migration_hash` expected/actual checks plus actual role/superuser evidence; dirty, privileged, or invalid state aborted before the suite ran, and the reference adapter mapped supported libpq TLS URL options to `PG*` variables without placing credential-bearing URLs in `psql` argv.
- Every classifier failure exposes typed machine data, and failed canonical artifacts retain the same `code`/`expected`/`actual` records. Existing human diagnostics remain available.
- REVIEW closure admission now documents and independently checks `lifecycle:"final"`, `status:"pass"`, and an all-met checklist; its existing `failure_closure_not_verified` machine code carries a stable predicate detail for lifecycle, status, or checklist failure.
- (Historical v0.18, adapter since removed.) No-filter invocation ran the full backend module by default, a `postgres` verifier role failed closed instead of warning, and the verifier never created or dropped databases.
- (Historical v0.18, adapter since removed.) `verify.sh` was the sole operator interface while `scripts/lib/verify-result.cjs` owned result classification, clean-probe validation, and VERIFY payload construction.

### v0.17 — dispatch liveness operator contract

- The playbook now requires operators to preserve the dispatch command's own exit code and accept issue-scoped RUN/BLOCKER files only when their cross-platform nanosecond `mtime + started_at` identity belongs to the current launch.
- `status:"exited"` is explicitly process termination rather than task completion. Current retry behavior is recorded accurately: ordinary non-zero attempts retry from `running`, stall retries may move `killed_stall -> running`, and only a zero exit writes `exited` before the watchdog returns.
- Ambiguous retry decisions combine process absence with filesystem or heartbeat progress. Missing artifacts alone are not death evidence, and completion remains bound to canonical REVIEW/VERIFY at live HEAD.
- Sol/medium runs receive at least an eight-minute operator budget absent an earlier hard terminal signal; attempt stderr growth is an additional liveness signal, while a frozen small stderr plus a live process prompts a stdin-redirection check.

### v0.16 — read-only REVIEW publication

- `cmux-dispatch.sh --produce-review` forwards one explicit REVIEWER mode through the existing watchdog and safe wrapper without entering write admission.
- Codex runs with `--sandbox read-only`; the host captures its final message to a hidden same-directory temporary file, grants no Git writable root or failure stash, validates the review schema plus producer/issue/live-HEAD identity and fail-verdict requirements, and atomically publishes `.review/ISSUE-N-REVIEW.json`.
- Invalid output and non-zero reviewer exits remove temporary output without replacing prior canonical evidence. Pane prose and CONDUCTOR transcription remain non-authoritative.
- The legacy `--read-only` name is documented as heartbeat/liveness only; it does not change the Codex filesystem sandbox.

### v0.1 — artifact and verifier foundation

Introduced `.review/` JSON schemas, CODEX/REVIEWER handoffs, and the first false-green-proof test-result classifier (historically Vitest-based).

### v0.2 — host preparation and reconstructable state

Added worktree/env preparation, tier probing, state reconstruction, freshness/archive handling, safe in-flight rebasing, structured blocker/heartbeat/run artifacts, and baseline-aware typecheck.

### v0.3 — sandbox containment and verifier hardening

Proved that Codex `workspace-write` blocks network egress including loopback TCP and AF_UNIX. Kept DB verification outside the sandbox and added local-DB refusal, least-privilege guidance, env scrubbing, per-issue VERIFY provenance, and network-deny regression probes.

### v0.4 — dispatch and DB fail-closed fixes

Made `cmux-dispatch.sh` the mandatory visible dispatch path; fixed cwd/prompt resolution, stale RUN/BLOCKER acceptance, per-issue DB creation fail-open behavior, and the then-verifier's unsafe `.env` DB fallback.

### v0.5 — wrapper contracts, acceptance gate, and portable skill entrypoint

- `cmux-dispatch.sh` forwards model/effort and optional liveness budgets.
- `runtimes/codex-safe.sh` grants only a linked worktree's or plain checkout's resolved Git metadata dir and supports read-only heartbeats.
- `codex-watchdog.sh` classifies refusal from two failed probes rather than stderr text. (Historical: the script was later removed in #127.)
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
- It verifies canonical raw-output AC-ID discovery and `acceptance.expected_test_count` without trusting worker prose, RUN.json, or PR-DRAFT claims. Optional `contract.test_count` extracts a positive decimal count via `{pattern, group}`; omitted it preserves the one-non-empty-stdout-line fallback.
- Test discovery remains a target-profile input; the coordination core does not assume Vitest. Failed discovery retains `test_discovery_failed` and reports exit code plus bounded UTF-8-safe stdout/stderr diagnostics.

### v0.8 — relocatable product-home interface

- `install-into.sh` distinguishes location-derived `PRODUCT_ROOT` from optional Git `REPOSITORY_ROOT` safety context, so a metadata-free export remains installable.
- `ac-check.sh` and `completion-check.sh` share one product-home schema resolver across source, symlink, and copy layouts.
- Installation smoke executes both gates from real temporary Git targets and covers a metadata-free export in a path containing spaces; source commands now require the canonical sibling `schemas/` directory.
- Physical authority migration into `toolkit/`, legacy-install migration, and release enforcement remain ordered follow-ups in #29–#31.

### v0.9 — distributable authority separation

- Product scripts, schemas, docs, canonical skill, tests, README, STATUS, environment example, and scoped instructions live beneath `toolkit/`.
- Root Matt skills, tracker/domain/triage configuration, plans, CI, hooks, and runtime evidence remain repository-owned and are excluded from target installs.
- Product issue reporting is self-contained, and the duplicate Matt-directory `agent-workflow` skill has been removed.
- `cmux-cluster.sh` now checks the target's installed `.agent-workflow/{scripts,schemas}` contract instead of source-checkout paths. (Historical: `cmux-cluster.sh` was later removed in #127.)

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
- `cmux-dispatch.sh` proves `touch_allowlist` scope against the base tree before write admission, atomically records every write attempt before cmux, binds returned admission to the CLI issue/worktree, resolves a capability-checked model/effort tuple before write launch, and journals current normal/integrated markers before atomically exposing their immutable issue/ordinal key plus issue-wide integrated-fix singleton in the Git common dir. Prepared current records recover only before host ordinal advance; metadata-free integrated sentinels remain legacy consumed state. Stale recovery never steals a live owner merely for an old mtime, dry-runs neither consume nor recover admission, and read-only seats remain outside the circuit.
- A tripped circuit rechecks oracle/contract first, requires a hard fact plus passing-analog parity instruction, and permits at most one manifest increment and one integrated fix batch; committed/legacy singleton state is rejected by the selector before dispatch, and security findings may stop earlier.

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
| Dispatch, watchdog, artifact lifecycle | Reusable across Git repositories with cmux, Orca, or Herdr plus Codex, Claude Code, or OpenCode |
| target profile + `target-verify.sh` | Reusable structured setup/runtime/verification contract |
| branch/cluster helpers | retain `feature/*`, pane-label, and integration-branch conventions |

Worktree preparation and tier routing are target-profile concerns. See `.claude/skills/agent-workflow/references/adoption.md`.

## Key operating facts

- A process exit or worker prose is not completion evidence. Review and verification must match the live HEAD.
- Write-capable Codex dispatch goes through `agent-workflow.sh` → shared dispatch core → explicitly selected cmux/Orca/Herdr adapter → `agent-watchdog.sh` → `agent-runtime.sh` → `runtimes/codex-safe.sh`; `cmux-dispatch.sh` remains a compatibility path, and `codex-watchdog.sh` was removed (#127).
- Read-only seats use `--read-only`; optional first-progress/stall budgets are forwarded only when supplied.
- Parallel write chunks require separate worktrees. Suites sharing a stateful service require separate throwaway service instances.
- The sandbox cannot reach a local DB, so VERIFIER runs outside it with a local, low-privilege URL.
- Generic transient failures require two failed selected-runtime probes separated by the configured gap before `status:"refused"`. Reviewer non-zero output and explicit auth/model/permission/capability diagnostics are terminal refusals immediately; stalls retry up to the configured limit.
- Write-capable Codex receives only the resolved Git metadata dir for either a linked worktree or plain checkout, never a broader checkout or parent root.

## Open roadmap

- **P0 toolkit separation:** #27–#31 are shipped: relocatable product home, single `toolkit/` authority, safe legacy migration, and release enforcement.
- **P1 procedure/templates:** #9, #10, and #11 are shipped (circuit breaker, compile-atomic chunks, and canonical Standard round-0 state).
- **P2 toolkit/procedure:** #13, #14, #17, and #19 are shipped: verifier freshness, integrated-head closure, re-review capsules, and the `runtimes/codex-safe.sh` main-checkout grant.
- **P3 telemetry:** #18 is shipped. Any future tier-allocation revision still requires merged live evidence; no follow-up issue is currently open.
- **Upstream blocked:** [openai/codex#6737](https://github.com/openai/codex/issues/6737) remains open as of 2026-07-20; reconsider in-sandbox loopback verification only if a containment-preserving allowance ships.

GitHub issues are the live roadmap; this section is a readable index, not a second issue tracker.

## Provenance

The workflow was originally extracted from a prior product repository on 2026-05-24 with path-scoped `git filter-repo` history. This repository is the canonical home for workflow scripts, schemas, playbooks, and the project skill, and the product is target-neutral: no target-specific adapter ships in the distribution.

## Maintenance rule

Continue the same evidence loop: scoped implementation, clean-context review, independent verification, then doc synchronization. Any script/schema/contract change updates the playbook, README, STATUS, and affected installer/skill references in the same commit. Do not merge or push without explicit user approval.
