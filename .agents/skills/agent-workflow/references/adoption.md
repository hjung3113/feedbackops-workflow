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
scripts/install-into.sh <target-repo> [--mode symlink|copy] [--force]
```

The installer derives `PRODUCT_ROOT` from its own physical `scripts/` location. Git metadata is optional: when present, the enclosing repository is used only for repository-specific safety checks and is not the product identity. Product commands derive the same home from their script location and resolve schemas from its sibling `schemas/` directory. The current source checkout's `.review/schemas` path is a transition adapter until the product authorities move under `toolkit/`; installed commands do not need repository metadata.

This installs:

```text
<target>/.agent-workflow/scripts
<target>/.agent-workflow/schemas
<target>/.agent-workflow/docs/agents
<target>/.claude/skills/agent-workflow
<target>/.review
```

Symlink mode follows toolkit updates immediately but uses machine-local absolute links; do not commit those links as a portable installation. Copy mode is an intentional, commit-friendly snapshot and must be updated manually. A sibling worktree sees the installation only if the copied files/links are part of its Git tree or the installer is run for that worktree too.

## Compatibility interview

Before the first run, answer these from the target's real files:

1. What is the repository root and integration branch?
2. Which package manager and install command prepare a new worktree?
3. Which env files are required, and which values represent shared mutable state?
4. What command discovers and runs the relevant tests?
5. How are typecheck, lint, build, and UI tests invoked?
6. Does verification require a DB or other service? Can each parallel chunk get an isolated instance?
7. Which paths or exported contracts force a higher risk tier?
8. What artifact or captured result proves verification at the current HEAD?

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
service_isolation_strategy
```

Until that profile contract exists, use target-native setup and verification where the bundled adapters do not fit, and state the limitation in the completion report.
