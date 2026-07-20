# Adopting agent-workflow in another repository

Read this reference only when installing or adapting the workflow to a new target.

## What is portable today

| Layer | Portability | Notes |
|---|---|---|
| Artifact schemas and lifecycle | General | JSON contracts do not depend on FeedbackOps product code. |
| `codex-safe.sh`, `codex-watchdog.sh`, `cmux-dispatch.sh` | Mostly general | Require Git, cmux, Codex CLI, and the toolkit script layout. |
| Review/archive/state reconstruction | General with conventions | The target must use the documented `.review/` names and full SHAs. |
| `prepare-worktree.sh` | Target adapter | Assumes pnpm, `.env`, and `apps/backend/.env`. |
| `tier-probe.sh` | TypeScript adapter | Its exported-contract heuristics target TS/TSX code. |
| `verify.sh` | FeedbackOps-style adapter | Assumes a pnpm `backend` package tested by Vitest and a target-owned clean probe producing sentinel/migration-hash JSON. |
| `prepare-verify-db.sh` | PostgreSQL adapter | Assumes local PostgreSQL and per-issue databases. |
| `cmux-cluster.sh` / `rebase-inflight.sh` | Convention adapter | Carry branch, pane-label, and `feature/*` assumptions. |

The workflow's **coordination model is reusable**, but every script is not yet target-neutral. Installation must not be described as full compatibility until the target adapters are checked.

Every target must explicitly tier its initial write. Standard/Full Cluster work generates the complete canonical `ISSUE-<n>-ROUND-STATE.json`; Standard may omit optional Full Cluster structures but retains `pr_draft` and `review` pointers and must not introduce a reduced target-specific schema. Pass that artifact and its revision to `cmux-dispatch.sh`; initial admission binds it to the target issue, tier, real worktree, live HEAD, and integration-branch merge-base. Trivial initial work retains the documented `pr_draft`-only contract.

Dispatch REVIEWER with `cmux-dispatch.sh --produce-review`, not the legacy liveness-only `--read-only` flag. The installed wrapper keeps reviewer commands filesystem-read-only, captures the final JSON host-side, and publishes the canonical REVIEW only after schema, issue, and live-HEAD validation. A target must not replace this with pane transcription or a second review manifest.

Adopt the playbook's dispatch liveness operator rules unchanged: preserve `cmux-dispatch.sh`'s direct exit code, accept only current-launch RUN/BLOCKER identity (`mtime + started_at`), and never derive completion from RUN status or artifact absence. Target-specific orchestration may display these signals but must still bind canonical REVIEW/VERIFY to live HEAD.

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

Every installation is a self-contained directory copy. No managed destination is a symlink to the toolkit checkout, so the result remains usable after moving it to another machine or deleting the source checkout. A sibling worktree sees the installation only when those copied files are part of its Git tree or the installer is run for that worktree too.

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

Record target-specific answers in the target's `AGENTS.md` or a small target-owned adapter document. Do not add product assumptions back to the shared skill.

For the bundled verifier, the target-owned adapter document must define `VERIFY_CLEAN_COMMAND`. Its command prints exactly one JSON object containing `sentinel` and `migration_hash` checks with sanitized string `expected`/`actual` values. It owns how those facts are measured; the toolkit owns validation, fail-closed routing, machine failure output, and storage inside canonical VERIFY. Do not put a database URL, credential, or customer value in either field. Canonical issue verification refuses an absent probe. `--fresh` remains unavailable until that same target owns explicit rebuild/drop lifecycle behavior.

Optional analysis services such as CodeGraph also belong to the **target repository or operator environment**, because their index must describe the code being changed. The toolkit repository itself is mostly Bash/Markdown/JSON and does not ship a project MCP config for target-only analyzers.

## Recommended generalization boundary

Keep the repository split into two layers:

- **Core:** dispatch, sandbox, liveness, artifact lifecycle, independent review, completion calculation.
- **Target profile:** install command, env destinations, branch patterns, tier triggers, verifier command, service isolation.

The next generalization should be driven by a second real target, not hypothetical flags. Compare the second target with the current pnpm/Vitest/PostgreSQL contract, then parameterize only the differing seams. Likely profile fields are:

```text
install_command
env_destinations[]
feature_branch_globs[]
tier_trigger_paths[]
test_discovery_command
verify_command
typecheck_command
compile_consumer_commands[]
service_isolation_strategy
```

Until that profile contract exists, use target-native setup and verification where the bundled adapters do not fit, and state the limitation in the completion report.

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
