# Agent Workflow — Agent Guide

This repo is a **multi-agent development workflow toolkit**: shell scripts, JSON artifact schemas, agent personas, and an operating playbook for running cmux × Claude × Codex clusters against a target codebase. It was built inside the FeedbackOps project and extracted here (history-preserving) so it can evolve independently and be reused on other projects.

This file is the single source of truth for working in **this** repo. `CLAUDE.md` is a pointer stub. The operating playbook for the workflow itself is `toolkit/docs/agents/multi-agent-workflow.md`.

## What's here

- `toolkit/scripts/` — the workflow tooling. Host-side orchestration (`prepare-worktree.sh`, `cmux-cluster.sh`, `rebase-inflight.sh`), the codex dispatch wrapper (`codex-safe.sh`), its stall watchdog (`codex-watchdog.sh`), the mandated cmux-workspace dispatch entry point (`cmux-dispatch.sh`), pre-review AC/completion/redispatch gates (`ac-check.sh`, `completion-check.sh`, `redispatch-check.sh`), the verification oracle (`verify.sh`), state reconstruction (`conductor-rebuild.sh`), staleness/archival (`artifact-fresh.sh`, `review-archive.sh`), tier routing (`tier-probe.sh`), and stash safety (`workflow-stash.sh`). Plus the v0.3 sandbox-network spike (`uds-pg-relay.mjs`).
- `toolkit/scripts/__tests__/*.smoke.sh` — the regression suite, run via `run-all.sh`. **Do not state a count or a coverage gap here** — an inventory typed by hand rots the moment a file lands, and this list has been wrong before. List it: `ls toolkit/scripts/__tests__/*.smoke.sh`.
- `toolkit/schemas/` — JSON Schemas (draft-07) for workflow artifacts, including canonical ROUND-STATE and worker/review/verification evidence, with valid/invalid fixtures under `schemas/fixtures/`. List the live inventory with `ls toolkit/schemas/*.schema.json` and `ls toolkit/schemas/fixtures/`.
- `toolkit/docs/agents/` — product playbook, role personas, artifact lifecycle, downstream issue reporting, and the dated workflow trial history.
- `docs/agents/` — repository-only Matt tracker, domain, and triage configuration. `docs/plans/` and `.review/` remain maintainer planning/runtime evidence.
- `toolkit/.claude/skills/agent-workflow/` — the project-local Claude skill entrypoint. Keep `SKILL.md` thin; route detailed policy to the playbook and load target-adoption guidance from `references/` only when needed. `toolkit/scripts/install-into.sh` installs this skill and the playbook into targets.
- `toolkit/STATUS.md` — current state and shipped versions. Read it first, but `git log` wins any disagreement.

## Operating Rules

- Think before editing. State assumptions when a request can be read more than one way.
- **The product workflow is opt-in here.** Matt Pocock skills under `.agents/skills/` are development tools for this repository. The `agent-workflow` skill is the product being built and must not orchestrate this repository implicitly; intentional dogfooding requires an explicit `/agent-workflow ... --self-test` invocation.
- Prefer the smallest change that satisfies the request. No speculative flexibility.
- Touch only files the task requires. Mention unrelated issues instead of fixing them.
- Match existing patterns before inventing structure.
- For multi-step work, define success criteria and verify them before claiming completion.
- Don't merge to `main` or push without explicit user approval.

## Dev Rules (this repo)

- **bash-3.2 compatible.** Scripts must run on macOS's stock bash 3.2: no `declare -A`, no `${var,,}`, no `mapfile`. Match the style already in `toolkit/scripts/`.
- **Smoke tests are the gate.** Run the relevant smoke after any change and add cases for new behavior. Check the live inventory with `ls toolkit/scripts/__tests__/*.smoke.sh`; if a changed script has no matching smoke, add coverage or state why it is impractical. A change to a smoke-covered script without a passing smoke is not done.
- **Doc-sync discipline.** Every script/schema change syncs the playbook (`toolkit/docs/agents/multi-agent-workflow.md`) and affected `toolkit/README.md` / `toolkit/STATUS.md` **in the same commit**. A DEVIATIONS note alone is insufficient for a contract change.
- **Write-capable task dispatch only via `toolkit/scripts/codex-safe.sh`.** It pins `--sandbox workspace-write` and `--cd <worktree>`. Direct `codex exec` is forbidden for implementation/review tasks; the playbook's cheap model-availability preflight is the narrow non-task exception. The sandbox blocks all network (incl. loopback) — see the Sandbox Rule in the playbook; never weaken this without recording the decision.
- **Dispatching into a visible cmux workspace only via `toolkit/scripts/cmux-dispatch.sh`.** Never hand-roll `cmux new-workspace`/`cmux workspace create --command "codex-watchdog.sh ..."` — a missing `--cwd` on the cmux workspace plus a relative `--prompt-file` silently exits 2 with no artifact (2026-07-13 incident). Every write launch atomically acquires a pre-cmux attempt marker. A same-issue write redispatch must pass canonical `--round-state`/`--manifest-revision`; the gate binds issue/worktree identity and atomically consumes the immutable issue/ordinal admission in the Git common dir before cmux starts. Integrated fix additionally consumes an issue-wide singleton. RUN.json's terminal state is `status:"exited"` + `exit_code`, never `"completed"`/`"failed"`.
- **Schemas are contracts.** When changing an artifact shape, update the schema + its fixtures together, and validate (`ajv-cli` or `node -e JSON.parse`).

## Git Workflow

- `main` is the trunk. Per-change branches `feat/<slug>`, `fix/<slug>`, `docs/<slug>`; PR into `main`.
- Never commit directly to `main` or push without explicit user approval.
- Commit messages use a `(workflow)` scope to match existing history, e.g. `feat(workflow): ...`, `fix(workflow): ...`, `docs(workflow): ...`.
- `.githooks/post-merge` warns about in-flight sibling worktrees needing rebase. Enable once per clone: `git config core.hooksPath .githooks`.

## Verification

- The repository release gate is `.github/tests/release-contract.smoke.sh`. It owns product-containment, legacy-reference exceptions, source/installed Markdown-link validity, installation non-leakage, and CI-routing checks; it is not installed into targets.
- Run the affected `toolkit/scripts/__tests__/*.smoke.sh`. They are offline and bash-3.2 safe.
- `toolkit/scripts/verify.sh` is the **vitest verification oracle** for a compatible target project (it loads env, runs a scoped Vitest filter via the JSON reporter, and is false-green-proof). `verify.smoke.sh` covers classification, typecheck, and stubbed filter/artifact paths without a live DB; a real filter run still needs a target with the expected backend package and local DB.
- The network-deny regression guard is `toolkit/scripts/__tests__/sandbox-network-deny.smoke.sh` (Layer 1 offline always; Layer 2 live in-sandbox probe with `RUN_LIVE_SANDBOX_PROBE=1` + `codex` on PATH).

## Agent skills

### Issue tracker

Work items and specifications live in this repository's GitHub Issues. See `docs/agents/issue-tracker.md`.

### Triage labels

Matt Pocock workflow skills use the repository's five canonical triage labels. See `docs/agents/triage-labels.md`.

### Domain docs

This is a single-context repository; domain vocabulary and architectural decisions are read from root-level context and ADR files when they exist. See `docs/agents/domain.md`.

## Source Of Truth

1. `AGENTS.md` (this file) — repo operating rules.
2. `toolkit/docs/agents/multi-agent-workflow.md` — the workflow operating playbook (risk tiers, roles, Release Captain, sandbox rule, VERIFIER protocol).
3. `toolkit/schemas/*.schema.json` — artifact contracts.
4. `toolkit/STATUS.md` — current state + remaining work (mutable; reflects reality, not aspiration).
