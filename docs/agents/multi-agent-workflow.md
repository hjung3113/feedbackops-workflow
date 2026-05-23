# Multi-Agent Workflow — Operating Playbook v0.1

This file holds the *operating* rules for the multi-agent workflow (cmux 4-pane × Claude × Codex). For higher-level design discussion see `docs/agents/multi-agent-workflow-draft.md` and `docs/agents/workflow-*.html`.

## Risk Tier Routing

Every issue is one of three tiers. The tier picks the agent set.

| Tier | When | Agents | Artifacts |
|---|---|---|---|
| **Trivial** | P3 cleanup, single file, no API/domain/UI change | CODEX + VERIFIER | pr_draft only |
| **Standard** | P2 / single-module behavior change | CODEX + REVIEWER + VERIFIER | pr_draft + review |
| **Full Cluster** | Any of: migration, auth, permissions, shared UI shells, `packages/shared`, cross-module contract, prod data path | ARCHITECT + CODEX + REVIEWER + VERIFIER (+ VISUAL if UI) | all of pr_draft, touch, review, verify |

**Escalation rule:** if a Trivial or Standard issue's actual touch set hits any Full Cluster trigger (e.g. `packages/shared/*`, migrations), CODEX MUST abort with a `blocker` artifact whose `recommended_actions[0]` is `"escalate to Full Cluster tier"`.

## Release Captain

Every issue has one **Release Captain**. The Captain owns merge readiness with override authority.

- **Default Captain:** the user (interactive mode) or CONDUCTOR (v0.2+).
- **Authority:** may reject merge despite all-green artifacts.
- **Mandate:** verify *integrated behavior* — does the change work end-to-end, not just pass local tests?
- **Why:** REVIEWER checks design fit and VERIFIER checks commands, but neither owns "does this actually ship safely."

## Codex Sandbox Rule

All `codex exec` invocations MUST go through `scripts/codex-safe.sh`, which enforces:

- `--sandbox workspace-write` (no read/write outside the working root)
- `--cd <worktree>` on the codex call (locks codex's writable root to one worktree). The wrapper's own CLI flag is `--cwd`; it maps that to codex's `-C/--cd`.
- abort-time `workflow-stash.sh` (preserve partial diff on non-zero exit)

Direct `codex exec` invocations are forbidden in this workflow.

## Artifact Lifecycle

Every `.review/ISSUE-*.json` carries `lifecycle: draft | active | superseded | final`. Superseded files MUST be ignored by readers. See `.review/README.md`.

## Workflow Tax Brake

If a Trivial issue routes through more than CODEX + VERIFIER, the workflow has failed and must be re-evaluated. The workflow exists to ship faster, not slower.

## VERIFIER protocol

VERIFIER MUST confirm green by running `scripts/verify.sh <filter>` — never by eyeballing test output and never by running a bare `pnpm test`. A bare `pnpm test` is forbidden as a green signal: in a trial it silently skipped all 31 integration tests (missing `DATABASE_URL`/`WORKSPACE_ID`) and a fully-skipped suite looked like a pass — a false green.

`scripts/verify.sh` loads env (`.env` and `apps/backend/.env` if present), runs the scoped vitest filter via the JSON reporter, and classifies the result. It treats as a **FAIL**:

- a fully-skipped suite (`numPassedTests + numFailedTests == 0` — discovered but pending),
- any failed test (`numFailedTests > 0`),
- a failed suite (`numFailedTestSuites > 0` — setup/import failure even with 0 failed tests),
- a top-level `success === false`,
- any `testResults[]` entry with `status === "failed"`,
- a non-zero vitest exit code (the run crashed; JSON may be stale/partial),
- a missing, empty, or unparseable report (fail closed).

A PASS is reported only when none of the above trip.
