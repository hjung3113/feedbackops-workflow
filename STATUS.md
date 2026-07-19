# Status

_Current as of 2026-07-20. `git log -1` and the schemas/scripts win any disagreement._

## Current release: v0.6

The toolkit is operational and dogfooded against FeedbackOps. The current release includes:

- isolated worktree preparation and visible cmux dispatch;
- sandboxed Codex implementation with model/effort pinning;
- process + filesystem liveness, read-only heartbeat support, and retry-aware refusal probes;
- JSON artifact schemas, freshness/archive rules, and disk-only CONDUCTOR reconstruction;
- independent REVIEWER and host-side VERIFIER gates;
- pre-review AC-ID existence checking;
- CONDUCTOR-owned canonical ROUND-STATE with a revision-pinned AC manifest view;
- a project-local `agent-workflow` skill plus installer-managed playbook/skill deployment;
- an opt-in self-application boundary: toolkit development uses its general development skills, while `agent-workflow` may target this repository only with explicit `--self-test` dogfooding authorization;
- an offline Bash 3.2 smoke suite and GitHub Actions gate.

Run the current inventory instead of copying a count into docs:

```bash
bash scripts/__tests__/run-all.sh --list
NODE_OPTIONS= bash scripts/__tests__/run-all.sh
```

## Shipped timeline

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
- `codex-safe.sh` grants a linked worktree's Git common dir and supports read-only heartbeats.
- `codex-watchdog.sh` classifies refusal from two failed probes rather than stderr text.
- `ac-check.sh` rejects duplicate or undiscovered manifest AC ids before review.
- The integrated wrapper changes passed clean-context review and a full smoke run at `main@5500d6a`.
- The versioned Claude skill is now a thin router; `install-into.sh` deploys scripts, schemas, playbook docs, and the project-local skill.

### v0.6 — canonical contract state

- `ISSUE-N-ROUND-STATE.json` replaces fragmented amendment prose with one CONDUCTOR-owned contract artifact.
- The acceptance manifest is the artifact's `acceptance.criteria[]` view; its revision is the ROUND-STATE top-level `revision`.
- `ac-check.sh` validates the canonical schema and base freshness, then rejects stale `--manifest-revision` values before checking duplicate or boundary-aware undiscovered AC ids.

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
- Plain-checkout Git metadata remains intentionally unwritable to Codex; linked worktrees receive only their Git common dir. Broader handling is tracked by issue #19.

## Open roadmap

- **P1 procedure/templates:** issues #3–#6 and #9–#11 — impact pass, ARCH feasibility, richer AC rows, completion calculation, circuit breaker, atomic chunks, and Standard-tier generation.
- **P2 toolkit/procedure:** #13, #14, #17, #19 — verifier output/freshness, integrated-head closure, re-review capsule, and plain-checkout Git handling.
- **P3 telemetry:** #18 — model-by-task measurements before revisiting tier allocation.
- **Upstream blocked:** [openai/codex#6737](https://github.com/openai/codex/issues/6737) remains open as of 2026-07-20; reconsider in-sandbox loopback verification only if a containment-preserving allowance ships.

GitHub issues are the live roadmap; this section is a readable index, not a second issue tracker.

## Provenance

The workflow was extracted from FeedbackOps on 2026-05-24 with path-scoped `git filter-repo` history. This repository is the canonical home for workflow scripts, schemas, playbooks, and the project skill. FeedbackOps remains product-only and consumes the toolkit through installation rather than carrying a second copy.

## Maintenance rule

Continue the same evidence loop: scoped implementation, clean-context review, independent verification, then doc synchronization. Any script/schema/contract change updates the playbook, README, STATUS, and affected installer/skill references in the same commit. Do not merge or push without explicit user approval.
