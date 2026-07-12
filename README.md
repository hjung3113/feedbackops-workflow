# Agent Workflow

A **multi-agent development workflow toolkit** for shipping code with cmux × Claude × Codex clusters: host-side orchestration scripts, false-green-proof verification, JSON artifact schemas, role personas, and an operating playbook.

Originally built inside the FeedbackOps project; extracted here (with full git history of the workflow files) so it can evolve on its own and be reused against any target codebase.

## Why

Running multiple AI coding agents in parallel breaks in non-obvious ways: a silently-skipped test suite looks like a pass (false green); parallel clusters corrupt each other's database; a sandboxed agent can't reach the DB to self-verify; "tests pass" prose claims can't be trusted. This toolkit encodes the hard-won fixes as **executable scripts + machine-checkable artifacts**, so orchestration is reproducible instead of vibes.

## The model

- **CONDUCTOR** — read-only orchestrator (a dedicated pane outside all clusters). Holds no in-memory state; rebuilds chunk state purely from `.review/*.json`.
- **CODEX** — implementer, run inside a `workspace-write` sandbox via `scripts/codex-safe.sh`.
- **REVIEWER / VISUAL-REVIEWER** — design-fit + live UI review.
- **VERIFIER** — runs the verification oracle (`scripts/verify.sh`) **outside** the sandbox (the sandbox blocks all network, incl. the local DB).
- **Release Captain** — owns merge readiness; merges only on canonical VERIFIER evidence (`ISSUE-<N>-VERIFY.json`), never on prose or embedded CODEX fields.

Risk tiers (Trivial / Standard / Full Cluster) pick the agent set. See `docs/agents/multi-agent-workflow.md` for the full playbook and `docs/agents/conductor-persona.md` / `visual-reviewer-persona.md` for role prompts.

## Core scripts

| Script | Role |
|---|---|
| `codex-safe.sh` | the only sanctioned way to dispatch `codex exec` — pins `--sandbox workspace-write` + `--cd`, stashes partial work on failure, and pins omitted gpt-5.6 effort to medium |
| `verify.sh` | false-green-proof vitest classifier + baseline-aware `--typecheck`; emits a `verify_result` provenance artifact |
| `prepare-worktree.sh` | host-side deps+env prep; refuses unsafe shared-env across worktrees |
| `cmux-cluster.sh` | launch a cluster against a prepared worktree |
| `conductor-rebuild.sh` | reconstruct CONDUCTOR state from `.review/*.json` |
| `tier-probe.sh` | disallow Trivial tier on exported-contract changes |
| `artifact-fresh.sh` / `review-archive.sh` | staleness check + archival of merged-issue artifacts |
| `rebase-inflight.sh` | dirty-safe, conflict-aborting rebase of in-flight worktrees |

Most scripts have a smoke test under `scripts/__tests__/` (8 in total; `cmux-cluster.sh`, `codex-safe.sh`, `workflow-stash.sh`, and `uds-pg-relay.mjs` lack a direct one — `codex-safe.sh` is partially covered by `sandbox-network-deny.smoke.sh`). Artifact shapes are pinned by `.review/schemas/*.schema.json`.

## Usage sketch

```
# 1. prepare an isolated worktree on the host (deps + env)
scripts/prepare-worktree.sh <worktree> [--env-profile <env>]

# 2. dispatch the implementer into the sandbox
scripts/codex-safe.sh --issue <N> --prompt-file .review/ISSUE-<N>-PROMPT.txt --cwd <worktree>

# 3. verify OUTSIDE the sandbox (emits .review/ISSUE-<N>-VERIFY.json)
VERIFY_ISSUE=<N> scripts/verify.sh <vitest-filter>

# 4. CONDUCTOR rebuilds state from artifacts; Release Captain merges on evidence
scripts/conductor-rebuild.sh .review
```

## Status

See `STATUS.md` for what's shipped (v0.1–v0.3), the trial results, the key findings, and remaining work.

## Install into a target project

The toolkit lives outside any target repo. Wire a target to it (default: symlink, so the target tracks toolkit updates):

```
scripts/install-into.sh <target-repo> [--mode symlink|copy] [--force]
```

This creates `<target>/.agent-workflow/{scripts,schemas}` (→ this toolkit) and ensures `<target>/.review/` exists for runtime artifacts. Then invoke e.g. `<target>/.agent-workflow/scripts/verify.sh` and copy `.env.example` into the target's `.env`.

## Setup

```
git config core.hooksPath .githooks   # enable post-merge rebase warning
```

The smoke suite is offline and bash-3.2 compatible. `verify.sh` filter mode and `cmux-cluster.sh` operate against a *target* project (backend package + local Postgres), not this repo.
