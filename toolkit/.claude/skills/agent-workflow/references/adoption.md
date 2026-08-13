# Adopting agent-workflow in another repository

Read this reference only when installing or adapting the workflow to a new target.

## What is portable today

| Layer | Portability | Notes |
|---|---|---|
| Artifact schemas and lifecycle | General | JSON contracts do not depend on FeedbackOps product code. |
| `agent-workflow.sh`, dispatch core, runtime/transport adapters, watchdog | General | Require Git, an explicitly selected capability-probed Codex, Claude Code, or OpenCode runtime, and an explicitly selected available cmux (minimum 0.64.0 with workspace create cwd/command), Orca CLI (create worktree/title/command/JSON plus read-only list), or Herdr CLI from an inherited Herdr session. |
| Review/archive/state reconstruction | General with conventions | The target must use the documented `.review/` names and full SHAs. |
| Target profile + `target-verify.sh` | General | One closed profile owns target facts; commands are structured argv/cwd/env data. |
| Parallel plan and candidate closure | General | Requires Git worktrees/commits; write paths and evidence paths stay target-relative. Target policy declares shared mutation paths, per-seat DB/env isolation, and rate-limit budget proof. |
| `prepare-worktree.sh` | FeedbackOps compatibility adapter | Profile-driven setup is deliberately deferred; do not parse the profile independently here. |
| `tier-probe.sh` | TypeScript compatibility adapter | Profile-driven tier triggers are deliberately deferred; do not create a second precedence path. |
| `verify.sh` | FeedbackOps compatibility adapter | Retains pnpm/Vitest/Postgres clean-state behavior. |
| `prepare-verify-db.sh` | PostgreSQL adapter | Assumes local PostgreSQL and per-issue databases. |
| `cmux-cluster.sh` / `rebase-inflight.sh` | Convention adapter | Carry branch, pane-label, and `feature/*` assumptions. |

The workflow's coordination model and generic verifier are reusable. Target facts have one authority: a target-owned JSON profile validated by `schemas/target-profile.schema.json`; examples for Node, Go, Python, and FeedbackOps live under `schemas/profiles/`.

Every target must explicitly tier its initial write. Standard/Full Cluster work generates the complete canonical `ISSUE-<n>-ROUND-STATE.json`, including explicit `contract.prohibitions[]` rather than prompt-regex reconstruction; Standard may omit optional Full Cluster structures but retains `pr_draft` and `review` pointers and must not introduce a reduced target-specific schema. Pass that artifact and its revision to `agent-workflow.sh dispatch` with an explicit orchestrator; initial admission binds it to the target issue, tier, real worktree, live HEAD, and integration-branch merge-base. Trivial initial work retains the documented `pr_draft`-only contract.

Choose distribution profile at installation, then transport, runtime, and role before the first run. Use `install-into.sh <target> --profile generic` for unrelated targets; it installs target-neutral docs/skill only. `--profile feedbackops` retains the FeedbackOps adapters. The installed checkout's absolute `.agent-workflow` directory is PRODUCT_HOME: copy `$PRODUCT_HOME/docs/agents/workflow-config.example.json` to `$PRODUCT_HOME/workflow-config.json`, set `AGENT_WORKFLOW_ORCHESTRATOR`, `AGENT_WORKFLOW_RUNTIME`, `AGENT_WORKFLOW_ROLE`, or pass `--orchestrator cmux|orca|herdr --runtime codex|claude|opencode --role <role>`; CLI overrides environment, which overrides PRODUCT_HOME config independently for each axis. Missing/unknown transport or runtime capability fails closed and never falls back. PRODUCT_HOME config contains only `orchestrator`, `runtime`, and `role`; it cannot inject an executable or command.

Herdr selection requires an inherited Herdr session (`HERDR_ENV=1` and a
non-empty `HERDR_SOCKET_PATH`); missing session context fails closed without
falling back to another transport. Herdr's receipt `external_handle` is the
returned workspace ID, not a requested label or pane ID. Workspace liveness is
transport liveness, not workflow completion, and a receipt records launch
intent/provenance rather than confirmed command delivery.

The host probes the selected runtime and records its observed version through the retained runner. `AGENT_WORKFLOW_CODEX_BIN`, `AGENT_WORKFLOW_CLAUDE_BIN`, and `AGENT_WORKFLOW_OPENCODE_BIN` are host/operator seams only; never add an executable field to target workflow config. OpenCode has an additional non-negotiable deny-first permission file: `permission["*"]` is `deny`, write mode explicitly adds `permission.edit:"allow"`, and read mode must not allow edit. A documented runtime or model is not an available runtime; inspect `agent-workflow.sh capabilities` before dispatch.

For multiple write seats, adopt the portable execution-plan contract instead of target-specific orchestration guesses. Declare normalized target-relative write sets, dependencies, topological integration order, shared generated/lockfile/migration surfaces, DB/environment isolation, and rate-limit reservation. Run `parallel-plan.sh decide`; only `parallel_eligible` pairs may overlap. Dispatch each planned seat with `--execution-plan` and `--seat`. Integrate source deltas into a dedicated clean candidate with `candidate-integrate.sh`, then close only through `candidate-close.sh evaluate`, exact unique integration-step order, a final REVIEW, an active PR-DRAFT, and a complete evidence set whose artifacts directly bind the same issue/round/revisions/candidate HEAD/attempt/generation timestamp. Wrapper relabeling and draft/superseded evidence do not establish freshness. The integrator never resets, checks out, aborts, or discards user changes.

Render the schema-derived output contract with `output-contract.sh render --role reviewer` (or `--role implementation` for a BLOCKER-capable write seat) and include the exact block in the prompt; `check` rejects drift from installed schema bytes. Dispatch REVIEWER with `agent-workflow.sh dispatch --produce-review`, not the legacy liveness-only `--read-only` flag. The installed wrapper keeps reviewer commands filesystem-read-only, captures the final JSON host-side, and publishes the canonical REVIEW only after schema, issue, and live-HEAD validation. A target must not replace this with pane transcription or a second review manifest.

For a re-review, first render `ISSUE-N-REVIEW-CAPSULE.{json,md}` with `review-capsule.sh` from the target's canonical ROUND-STATE, full prompt, final REVIEW, and PR-DRAFT. Pass the canonical JSON to the next review dispatch and omit `--prompt-file` to use the automatically bound canonical Markdown; unrelated prompts are rejected. Treat `target_tokens` as a whole-Markdown cap and retain the generated omission counts. Generated capsule files are ignored runtime scratch and never replace those source authorities.

Adopt the playbook's dispatch liveness operator rules unchanged: preserve the public dispatch command's direct exit code, accept only current-launch RUN/BLOCKER identity (`mtime + started_at`), and never derive completion from RUN status or artifact absence. Target-specific orchestration may display these signals but must still bind canonical REVIEW/VERIFY to live HEAD.

## Install

From the toolkit repository:

```bash
scripts/install-into.sh <target-repo>
scripts/install-into.sh <target-repo> --upgrade
```

The installer derives `PRODUCT_ROOT` from its own physical `scripts/` location. Git metadata is optional: when present, the enclosing repository is used only for repository-specific safety checks and is not the product identity. Source and installed commands use the same sibling `scripts/`, `schemas/`, and `docs/` layout; installed commands do not need repository metadata.

This installs:

```text
<target>/.agent-workflow/scripts
<target>/.agent-workflow/schemas
<target>/.agent-workflow/docs/agents
<target>/.claude/skills/agent-workflow
<target>/.review
```

Every installation is a self-contained directory copy. No managed destination is a symlink to the toolkit checkout, so the result remains usable after moving it to another machine or deleting the source checkout. When `.agent-workflow` is ignored, a sibling worktree deliberately does not contain it: retain the installed checkout's absolute PRODUCT_HOME and invoke `$PRODUCT_HOME/scripts/<command>` with `--worktree <sibling>`. Do not reinstall into every sibling or use a worktree-relative `.agent-workflow/scripts` path; `.review` and relative prompt-file paths remain owned by that sibling worktree.

The default command is fresh-install only and refuses any existing managed leaf. Use `--upgrade` for an existing complete installation. Upgrade accepts recognized copies and complete correlated current or pre-`toolkit/` absolute-link layouts, including dangling links, then converts all four leaves to portable copies. Changed content inside a recognized complete copy is retained in the backup; partial, mixed, structurally unrecognized, or uncorrelated layouts fail closed for manual resolution.

Upgrade stages all four source trees inside the target before mutation, moves the previous leaves to `.review/agent-workflow-install-backups/<timestamp>-pid/`, and swaps the staged copies as one operation with verified rollback on failure. The backup parent must be a real directory inside the target. If the filesystem also refuses a rollback move, the installer exits `70`, names the retained backup, and requires manual recovery. Replacement is limited to these managed destinations:

```text
.agent-workflow/scripts
.agent-workflow/schemas
.agent-workflow/docs/agents
.claude/skills/agent-workflow
```

It does not remove target `.review`, unrelated files, or the repository itself. The old `--mode`, `--force`, and `--migrate-legacy` flags are rejected with guidance to use the new interface.

## Compatibility interview

Before the first run, answer these from the target's real files:

1. What is the repository root and integration branch?
2. Which package manager and install command prepare a new worktree?
3. Which env files are required, and which values represent shared mutable state?
4. What command discovers and runs the relevant tests?
5. How are typecheck, lint, build, and UI tests invoked?
6. Does verification require a DB or other service? Can each parallel chunk get an isolated instance?
7. Which paths or exported contracts force a higher risk tier?
8. Which repository-native commands enumerate compile-time consumers, and what full typecheck command gates the proposed scope?
9. What artifact or captured result proves verification at the current HEAD?

Record executable answers in one target profile. Do not duplicate profile precedence or add target assumptions back to the shared skill. Run `$PRODUCT_HOME/scripts/target-verify.sh <profile> <issue>` for generic targets. Every required command must exit zero for PASS. A test-count extractor must match real target output and prove a positive integer; a miss is durable `test_count:null` FAIL evidence. Treat `verification.output_bytes` as a UTF-8 byte ceiling. Same-HEAD canonical evidence is appendable only after schema and aggregate validation, so repair or archive an invalid artifact rather than replacing its red history with a new PASS.

For the bundled verifier, the target-owned adapter document must define `VERIFY_CLEAN_COMMAND`. The installed `docs/agents/verify-clean-probe.example.mjs` is an executable, product-neutral reference: provide separate app and migration URLs plus target-owned read-only sentinel and migration-hash queries. Its `sentinel` proves attachment to the intended throwaway target; `migration_hash` proves migration state matches the target's declared expectation. The command maps URL components to `PGHOST`/`PGPORT`/`PGDATABASE`/`PGUSER`/`PGPASSWORD` and supported libpq TLS settings (mode, CA/client cert/key, CRL, protocol bounds, negotiation, compression, SNI) to `PG*` variables for `psql` rather than passing a URL in argv; an unrecognized or empty query option fails closed before `psql` runs. It then prints exactly one JSON object containing those checks with sanitized string `expected`/`actual` values plus `role:{name,superuser}` measured from the actual connection. It owns how domain facts are measured; the toolkit rejects undeclared fields, role mismatch, and superuser evidence, then stores only the declared projection inside canonical VERIFY. Do not put a database URL, credential, or customer value in any field or command argv. Canonical issue verification refuses an absent probe. `--fresh` remains unavailable until that same target owns explicit rebuild/drop lifecycle behavior.

Optional analysis services such as CodeGraph also belong to the **target repository or operator environment**, because their index must describe the code being changed. The toolkit repository itself is mostly Bash/Markdown/JSON and does not ship a project MCP config for target-only analyzers.

## Target profile boundary

Keep the repository split into two layers:

- **Core:** dispatch, sandbox, liveness, artifact lifecycle, independent review, completion calculation.
- **Target profile:** install command, env destinations, branch patterns, tier triggers, verifier command, service isolation.

The v1 profile owns runtime executables, setup commands, required environment names, env allowlists, and required verification groups. Commands are argv arrays with optional repository-relative cwd; arbitrary shell strings, plugin registries, absolute cwd, and traversal are rejected. `prepare-worktree.sh` and `tier-probe.sh` remain explicit compatibility adapters until their migrations can consume the same parsed profile without divergent precedence.

Use `target-verify.sh` for generic verification and `verify.sh` only for the documented FeedbackOps compatibility profile.

## Feed problems back to the toolkit

Do not let a target-only workaround become the only record of a reusable failure. When adoption
or a later run exposes a problem:

1. Preserve a minimal, sanitized reproduction in the target repository and identify the installed
   toolkit revision plus whether it was a fresh install or `--upgrade`.
2. Decide whether the evidence points to the coordination core, a bundled target adapter, or an
   adoption/documentation gap. Leave the classification open when the boundary is not yet proven.
3. Search the toolkit repository's open and closed GitHub issues for an existing report.
4. After obtaining authorization for the external write, file or update the toolkit issue using
   the inbound-report contract and copyable body template at
   `<target>/.agent-workflow/docs/agents/issue-reporting.md`.
5. Put the toolkit issue URL and the target-owned temporary workaround in the target's handoff or
   completion report. Remove or revise the workaround only after the upstream change is adopted.

Never attach secrets, customer data, raw environment files, or unredacted workflow artifacts.
The toolkit issue should contain the smallest evidence needed to reproduce and route the problem.

## Telemetry adoption

Telemetry is disabled until the target creates a private local salt and explicitly runs `telemetry.sh collect`. Samples remain beneath the target installation; no data is uploaded. Green collection requires the parallel-candidate producer's matching canonical CLOSURE, INTEGRATION, and CANDIDATE-EVIDENCE files; their actual digests and identities must match, and closure evaluation must follow dependency generation and the admitted RUN end. REVIEW/VERIFY pass alone is diagnostic input, not closure. A policy-routed v2 sample additionally requires canonical v3 transport receipt plus the matching current Git-common-dir admission binding; every receipt routing field must match the binding, and runtime/model/effort/transport are derived from that host-bound tuple, never telemetry CLI values. It stores only a salt-HMAC route pseudonym. Salt/store paths may use benign target-internal symlinks but any external realpath is rejected. Before using a report for tier discussion, declare the observation window and minimum cohort/completeness thresholds, retain no-green and incomplete chains, inspect per-attempt allocations, and keep observed/estimated/unavailable costs separate. Routing cohorts require homogeneous v2 policy chains and use complete independent-chain thresholds; they are descriptive with confounders, never a causal ranking. Cross-lineage or non-contiguous retries stay incomplete, while mixed-model chains are excluded from single-model comparisons. Export is stdout redirection; retention and exact-ID deletion are operator actions. A report can propose a human-reviewed policy change but cannot edit `model-alloc.json` or tier rules.
