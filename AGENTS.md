# Agent Workflow — Agent Guide

This repo is a **multi-agent development workflow toolkit**: shell scripts, JSON artifact schemas, agent personas, and an operating playbook for running cmux × Claude × Codex clusters against a target codebase. It was built inside the FeedbackOps project and extracted here (history-preserving) so it can evolve independently and be reused on other projects.

This file is the single source of truth for working in **this** repo. `CLAUDE.md` is a pointer stub. The operating playbook for the workflow itself is `docs/agents/multi-agent-workflow.md`.

## What's here

- `scripts/` — the workflow tooling. Host-side orchestration (`prepare-worktree.sh`, `cmux-cluster.sh`, `rebase-inflight.sh`), the codex dispatch wrapper (`codex-safe.sh`), its stall watchdog (`codex-watchdog.sh`), the mandated cmux-workspace dispatch entry point (`cmux-dispatch.sh`), pre-review AC coverage (`ac-check.sh`), the verification oracle (`verify.sh`), state reconstruction (`conductor-rebuild.sh`), staleness/archival (`artifact-fresh.sh`, `review-archive.sh`), tier routing (`tier-probe.sh`), and stash safety (`workflow-stash.sh`). Plus the v0.3 sandbox-network spike (`uds-pg-relay.mjs`).
- `scripts/__tests__/*.smoke.sh` — the regression suite, run via `run-all.sh`. **Do not state a count or a coverage gap here** — an inventory typed by hand rots the moment a file lands, and this list has been wrong before. List it: `ls scripts/__tests__/*.smoke.sh`.
- `.review/schemas/` — JSON Schemas (draft-07) for every workflow artifact (`pr_draft`, `review`, `touch`, `blocker`, `heartbeat`, `phase_summary`, `run`, `verify`), with valid/invalid fixtures under `schemas/fixtures/`. Same rule: `ls .review/schemas/fixtures/` beats any list written here.
- `docs/agents/` — the playbook (`multi-agent-workflow.md`) and role personas (`conductor-persona.md`, `visual-reviewer-persona.md`). Dated history lives in `workflow-trial-log.md` and nowhere else.
- `.claude/skills/agent-workflow/` — the project-local Claude skill entrypoint. Keep `SKILL.md` thin; route detailed policy to the playbook and load target-adoption guidance from `references/` only when needed. `scripts/install-into.sh` installs this skill and the playbook into targets.
- `STATUS.md` — current state and shipped versions. Read it first, but `git log` wins any disagreement.

## Operating Rules

- Think before editing. State assumptions when a request can be read more than one way.
- Prefer the smallest change that satisfies the request. No speculative flexibility.
- Touch only files the task requires. Mention unrelated issues instead of fixing them.
- Match existing patterns before inventing structure.
- For multi-step work, define success criteria and verify them before claiming completion.
- Don't merge to `main` or push without explicit user approval.

## Dev Rules (this repo)

- **bash-3.2 compatible.** Scripts must run on macOS's stock bash 3.2: no `declare -A`, no `${var,,}`, no `mapfile`. Match the style already in `scripts/`.
- **Smoke tests are the gate.** Most scripts have a `scripts/__tests__/<name>.smoke.sh`. Run the relevant smoke after any change and add cases for new behavior. If you change a script that has no smoke yet (`cmux-cluster.sh`, `codex-safe.sh`, `workflow-stash.sh`, `uds-pg-relay.mjs`), add coverage or state why it's impractical. A change to a smoke-covered script without a passing smoke is not done.
- **Doc-sync discipline.** Every script/schema change syncs the playbook (`docs/agents/multi-agent-workflow.md`) and any affected README/STATUS **in the same commit**. A DEVIATIONS note alone is insufficient for a contract change.
- **Write-capable task dispatch only via `scripts/codex-safe.sh`.** It pins `--sandbox workspace-write` and `--cd <worktree>`. Direct `codex exec` is forbidden for implementation/review tasks; the playbook's cheap model-availability preflight is the narrow non-task exception. The sandbox blocks all network (incl. loopback) — see the Sandbox Rule in the playbook; never weaken this without recording the decision.
- **Dispatching into a visible cmux workspace only via `scripts/cmux-dispatch.sh`.** Never hand-roll `cmux new-workspace`/`cmux workspace create --command "codex-watchdog.sh ..."` — a missing `--cwd` on the cmux workspace plus a relative `--prompt-file` silently exits 2 with no artifact (2026-07-13 incident). RUN.json's terminal state is `status:"exited"` + `exit_code`, never `"completed"`/`"failed"`.
- **Schemas are contracts.** When changing an artifact shape, update the schema + its fixtures together, and validate (`ajv-cli` or `node -e JSON.parse`).

## Git Workflow

- `main` is the trunk. Per-change branches `feat/<slug>`, `fix/<slug>`, `docs/<slug>`; PR into `main`.
- Never commit directly to `main` or push without explicit user approval.
- Commit messages use a `(workflow)` scope to match existing history, e.g. `feat(workflow): ...`, `fix(workflow): ...`, `docs(workflow): ...`.
- `.githooks/post-merge` warns about in-flight sibling worktrees needing rebase. Enable once per clone: `git config core.hooksPath .githooks`.

## Verification

- Run the affected `scripts/__tests__/*.smoke.sh`. They are offline and bash-3.2 safe.
- `scripts/verify.sh` is the **vitest verification oracle** for a compatible target project (it loads env, runs a scoped Vitest filter via the JSON reporter, and is false-green-proof). `verify.smoke.sh` covers classification, typecheck, and stubbed filter/artifact paths without a live DB; a real filter run still needs a target with the expected backend package and local DB.
- The network-deny regression guard is `scripts/__tests__/sandbox-network-deny.smoke.sh` (Layer 1 offline always; Layer 2 live in-sandbox probe with `RUN_LIVE_SANDBOX_PROBE=1` + `codex` on PATH).

## Source Of Truth

1. `AGENTS.md` (this file) — repo operating rules.
2. `docs/agents/multi-agent-workflow.md` — the workflow operating playbook (risk tiers, roles, Release Captain, sandbox rule, VERIFIER protocol).
3. `.review/schemas/*.schema.json` — artifact contracts.
4. `STATUS.md` — current state + remaining work (mutable; reflects reality, not aspiration).
