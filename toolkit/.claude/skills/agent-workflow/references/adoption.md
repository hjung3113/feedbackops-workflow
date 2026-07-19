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
| `verify.sh` | FeedbackOps-style adapter | Assumes a pnpm `backend` package tested by Vitest. |
| `prepare-verify-db.sh` | PostgreSQL adapter | Assumes local PostgreSQL and per-issue databases. |
| `cmux-cluster.sh` / `rebase-inflight.sh` | Convention adapter | Carry branch, pane-label, and `feature/*` assumptions. |

The workflow's **coordination model is reusable**, but every script is not yet target-neutral. Installation must not be described as full compatibility until the target adapters are checked.

## Install

From the toolkit repository:

```bash
scripts/install-into.sh <target-repo> [--mode symlink|copy] [--migrate-legacy|--force]
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

Symlink mode follows toolkit updates immediately but uses machine-local absolute links; do not commit those links as a portable installation. A sibling worktree sees the installation only if the copied files/links are part of its Git tree or the installer is run for that worktree too.

Pre-`toolkit/` installations used four absolute links from the target into the old repository root. The installer detects recognized live or dangling legacy links, makes no changes, and prints the exact `--migrate-legacy` command. That option replaces only recognized legacy links in the requested symlink/copy mode; it preserves files, directories, copy installs, and unrecognized links, and cannot be combined with `--force`.

Copy mode is a point-in-time snapshot and never updates automatically. Rerunning without force preserves the snapshot and target customization. To update, back up and review changes, then explicitly run `--mode copy --force`. Force replacement is limited to these managed destinations:

```text
.agent-workflow/scripts
.agent-workflow/schemas
.agent-workflow/docs/agents
.claude/skills/agent-workflow
```

It does not remove target `.review`, unrelated files, or the repository itself.

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
   toolkit revision plus symlink/copy mode.
2. Decide whether the evidence points to the coordination core, a bundled target adapter, or an
   adoption/documentation gap. Leave the classification open when the boundary is not yet proven.
3. Search the toolkit repository's open and closed GitHub issues for an existing report.
4. After obtaining authorization for the external write, file or update the toolkit issue using
   the inbound-report contract and copyable body template in `docs/agents/issue-reporting.md`.
5. Put the toolkit issue URL and the target-owned temporary workaround in the target's handoff or
   completion report. Remove or revise the workaround only after the upstream change is adopted.

Never attach secrets, customer data, raw environment files, or unredacted workflow artifacts.
The toolkit issue should contain the smallest evidence needed to reproduce and route the problem.
