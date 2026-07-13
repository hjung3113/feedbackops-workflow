# Agent Workflow

A **multi-agent development workflow toolkit** for shipping code with cmux × Claude × Codex clusters: host-side orchestration scripts, false-green-proof verification, JSON artifact schemas, role personas, and an operating playbook.

Originally built inside the FeedbackOps project; extracted here (with full git history of the workflow files) so it can evolve on its own and be reused against a target codebase whose backend is a pnpm workspace tested with Vitest. The verification oracle is backend-Vitest-specific today; parameterization waits for a second real target.

## Why

Running multiple AI coding agents in parallel breaks in non-obvious ways: a silently-skipped test suite looks like a pass (false green); parallel clusters corrupt each other's database; a sandboxed agent can't reach the DB to self-verify; "tests pass" prose claims can't be trusted. This toolkit encodes the hard-won fixes as **executable scripts + machine-checkable artifacts**, so orchestration is reproducible instead of vibes.

## The model

- **CONDUCTOR** — read-only orchestrator (a dedicated pane outside all clusters). Holds no in-memory state; rebuilds chunk state purely from `.review/*.json`.
- **CODEX** — implementer, run inside a `workspace-write` sandbox via `scripts/codex-safe.sh`.
- **REVIEWER / VISUAL-REVIEWER** — design-fit + live UI review.
- **VERIFIER** — runs the verification oracle (`scripts/verify.sh`) **outside** the sandbox (the sandbox blocks all network, incl. the local DB).
- **Release Captain** — owns merge readiness; merges only on canonical VERIFIER evidence (`ISSUE-<N>-VERIFY.json`), never on prose or embedded CODEX fields.

Risk tiers (Trivial / Standard / Full Cluster) pick the agent set. See `docs/agents/multi-agent-workflow.md` for the full playbook and `docs/agents/conductor-persona.md` / `visual-reviewer-persona.md` for role prompts.

Policy defaults: implementation is separate from review/verification, parallel Codex work uses separate prepared worktrees, and dispatch/verify runs clear `NODE_OPTIONS=` to avoid inherited preload state.

## Core scripts

| Script | Role |
|---|---|
| `codex-safe.sh` | the only sanctioned way to dispatch `codex exec` — pins `--sandbox workspace-write` + `--cd`, stashes partial work on failure, and pins omitted gpt-5.6 effort to medium |
| `codex-watchdog.sh` | wraps `codex-safe.sh` with process + filesystem liveness, stall retries, 4xx fail-fast, and `ISSUE-<N>-RUN.json` markers |
| `cmux-dispatch.sh` | **the mandated way** to dispatch codex into a visible cmux workspace — validates worktree/prompt-file/cmux binary up front, always passes `--cwd` to both cmux and the watchdog, polls for a **fresh** `RUN.json`/`BLOCKER.json` (a stale artifact from a previous same-issue run is never accepted), has a `--dry-run` seam |
| `verify.sh` | false-green-proof vitest classifier + baseline-aware `--typecheck`; emits a `verify_result` provenance artifact; with `VERIFY_ISSUE` set it refuses (exit 4) to fall back to the `.env` `DATABASE_URL` |
| `prepare-verify-db.sh` | provisions the per-issue `verify_issue_<N>` DB via `psql` (admin role needs CREATEDB); prints `VERIFY_DATABASE_URL=` as its last line ONLY when every step succeeded (fail closed) |
| `prepare-worktree.sh` | host-side deps+env prep; refuses unsafe shared-env across worktrees; env profiles are written to both root and backend env files |
| `cmux-cluster.sh` | launch a cluster against a prepared worktree |
| `conductor-rebuild.sh` | reconstruct CONDUCTOR state from `.review/*.json` |
| `tier-probe.sh` | disallow Trivial tier on exported-contract changes |
| `artifact-fresh.sh` / `review-archive.sh` | staleness check + archival of merged-issue artifacts |
| `rebase-inflight.sh` | dirty-safe, conflict-aborting rebase of in-flight worktrees |

The smoke suite has 16 offline bash-3.2-compatible tests under `scripts/__tests__/`, including direct coverage for `cmux-cluster.sh`, `cmux-dispatch.sh`, `codex-safe.sh`, `codex-watchdog.sh`, `workflow-stash.sh`, and `uds-pg-relay.mjs`. Artifact shapes are pinned by `.review/schemas/*.schema.json`.

## Usage sketch

```
# 1. prepare an isolated worktree on the host (deps + env)
scripts/prepare-worktree.sh <worktree> [--env-profile <env>]

# 2. dispatch the implementer into a VISIBLE cmux workspace (mandated path —
#    do not hand-roll `cmux new-workspace --command`, see incident note below)
scripts/cmux-dispatch.sh --issue <N> --worktree <worktree>

# 3. provision the per-issue verify DB (admin URL role needs CREATEDB), then
#    verify OUTSIDE the sandbox (emits .review/ISSUE-<N>-VERIFY.json).
#    VERIFY_DATABASE_URL is REQUIRED with VERIFY_ISSUE — verify.sh refuses
#    (exit 4) to fall back to the worktree .env's DATABASE_URL.
eval $(scripts/prepare-verify-db.sh --issue <N> --base-url <admin-pg-url> | tail -1)
VERIFY_DATABASE_URL=$VERIFY_DATABASE_URL VERIFY_ISSUE=<N> scripts/verify.sh <vitest-filter>

# 4. CONDUCTOR rebuilds state from artifacts; Release Captain merges on evidence
scripts/conductor-rebuild.sh .review
```

**Why `cmux-dispatch.sh` and not a hand-rolled `cmux new-workspace --command "codex-watchdog.sh ..."`?** Because that failed silently in production: a dispatch forgot `--cwd <worktree>` on the cmux workspace itself, the workspace opened in cmux's default project dir, and `codex-watchdog.sh` validated its `--prompt-file` relative to *that* dir instead of the intended worktree — exit 2, no `RUN.json`, nothing but pane scrollback. `cmux-dispatch.sh` always passes `--cwd` to both cmux and the watchdog, absolutizes the prompt path first, and polls for a **fresh** `RUN.json`/`BLOCKER.json` — ignoring stale artifacts left by a previous run of the same issue — so a dead-on-arrival dispatch is caught instead of silent. See `docs/agents/multi-agent-workflow.md` for the full RUN.json terminal-state contract.

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
