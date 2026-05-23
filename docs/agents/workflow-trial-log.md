# Multi-Agent Workflow — Trial Log

## Trial 1 — Issue #33 (HttpError.detail discriminated union) — 2026-05-23

**Tier:** Trivial (CODEX + VERIFIER). ARCHITECT + Release Captain = human/Claude.
**Outcome:** CODEX aborted per ambiguity rule. No commit. Clean tree. Conforming `BLOCKER.json`.
**Verdict:** SUCCESSFUL trial of the **failure path** — the guardrails worked exactly as designed. Happy path NOT exercised (issue turned out mis-scoped).

### What the workflow caught

Tightening `HttpError.detail` from `Record<string, unknown>` to the narrow `DetailShape` union breaks **every existing call site** that passes a non-conforming detail — across `analytics-areas`, `attachments`, `managed-systems`, `permissions`, `voc`. So issue #33, labeled P3 / "single file," is actually a **cross-module type change** (Full-Cluster-tier blast radius), not a Trivial one.

CODEX correctly:
- Detected the scope violation (typecheck fails on out-of-scope files).
- Aborted with **no commit**, restored files to clean.
- Wrote a schema-valid `.review/ISSUE-33-BLOCKER.json` with `recommended_actions`.
- Ran inside `--sandbox workspace-write` (confirmed in banner).

### Validations that passed

| Check | Result |
|---|---|
| codex-safe drives codex with `--cd` + `--sandbox workspace-write` | ✓ banner confirmed |
| BLOCKER.json conforms to `blocker.schema.json` (ajv) | ✓ valid |
| Clean abort: 0 commits, no partial stash, tree clean | ✓ |
| Escalation rule produced actionable `recommended_actions` | ✓ |
| cmux-cluster.sh spawned 4-pane workspace from feature branch | ✓ (workspace:19) |

### Friction / findings → v0.2 candidates

1. **Issue mis-scoping is invisible until typecheck.** The P3 label + "single file" issue text masked a cross-module blast radius. **Lesson:** tier assignment must consider *type-tightening blast radius*, not just file count. A constructor/shared-type narrowing is never Trivial. Consider a pre-dispatch `tsc` impact probe before assigning Trivial tier.

2. **Sandbox blocks network → `pnpm install` fails.** `workspace-write` sandbox cannot reach `registry.npmjs.org`. CODEX worked around it using the sibling repo's already-installed `node_modules`, but a task needing fresh deps would hard-fail. **v0.2:** either pre-install deps in the worktree before dispatch, or grant codex an explicit network allowance for install steps, or document "deps must be present before dispatch."

3. **Prompt template leaked into output.** `recommended_actions[0]` = "escalate to Full Cluster tier (touches packages/shared)" — but the real blocker was backend *modules*, not `packages/shared`. CODEX parroted the escalation phrasing from the dispatch prompt's ambiguity rule. **Lesson:** the ambiguity-rule example string in the prompt biases the output. Make the escalation instruction generic ("name the actual out-of-scope files") rather than providing a canned reason.

4. **Happy path still unvalidated.** This trial only exercised the abort/escalation path. A second trial on a *genuinely* trivial issue (e.g. a test-only addition, a string constant, a doc fix) is needed to validate the green flow: CODEX commit → PR-DRAFT.json → REVIEWER review.json → VERIFIER green → Release Captain → PR.

### Decision on issue #33

Re-scope. #33 is not Trivial. Options:
- Re-label as a Full-Cluster task and run the full agent set (ARCHITECT plans the cross-module migration).
- Or split: introduce `DetailShape` as an *optional* alias first, migrate call sites module-by-module, then tighten the constructor last.

Recommend commenting this finding on the GitHub issue so the mis-scope is recorded.

---

## Trial 2 — Issue #31 (idempotency replay audit assertion) — 2026-05-23

**Tier:** Trivial (CODEX + VERIFIER). REVIEWER also run. ARCHITECT + Release Captain = human/Claude.
**Outcome:** GREEN. Full happy path validated end-to-end.
**Verdict:** SUCCESSFUL trial of the **happy path** — complements Trial 1's failure-path validation.

### Flow exercised

| Step | Result |
|---|---|
| cmux-cluster.sh spawned 4-pane workspace from feature branch | ✓ workspace:20 |
| codex-safe drove codex (`--cd`, `--sandbox workspace-write`) | ✓ |
| CODEX edited test only (+7 lines), committed `655756a`, no production change | ✓ |
| PR-DRAFT.json conforms to schema (ajv) | ✓ valid |
| VERIFIER ran `pnpm --filter backend test create-voc` against live DB | ✓ 31/31 pass |
| REVIEWER produced schema-valid `ISSUE-31-REVIEW.json`, status=pass | ✓ |
| Assertion correctness (before-after audit delta isolates replay) | ✓ confirmed by REVIEWER + green run |

### Friction / findings → v0.2 candidates

5. **vitest does not auto-load `.env`.** Integration suites gate on `runIntegration = DATABASE_URL && WORKSPACE_ID`. VERIFIER's first run SKIPPED all 31 tests silently because env wasn't exported. Had to `set -a; source .env; set +a` before the run. **Lesson:** VERIFIER step must source env first, or the suite's skip is a silent false-green. Add an explicit env-load to the VERIFIER protocol, and treat "all skipped" as NOT a pass.

6. **Worktree needs its own `node_modules` + `.env`.** A fresh git worktree (sibling dir) is outside the pnpm workspace root, so it has no deps and no gitignored `.env`. The Release Captain (outside sandbox) had to `pnpm install` + copy `.env` into the worktree before VERIFIER could run. **v0.2:** cmux-cluster.sh should optionally run `pnpm install` + copy env into the new worktree, or the protocol must document this prep step.

7. **Pre-existing unrelated typecheck error.** `pnpm --filter backend run typecheck` fails on `src/cli/storage-bootstrap.ts(54,31) TS2559` — unrelated to #31, pre-existing on the branch. CODEX correctly noted it as a deviation rather than trying to fix out-of-scope. **Lesson:** VERIFIER should scope verification to the touched area (run the specific test) rather than a repo-wide typecheck that trips on pre-existing breakage — or the pre-existing error should be fixed separately.

8. **Trial branch based on workflow infra branch.** Per the plan's branch model, the trial worktree branched from `feature/agent-workflow-trial` (so it could see the scripts/schemas), NOT from `develop`. Consequence: `feature/31-idem-audit-assertion` carries all the infra commits + the test commit. For the *real* #31 fix to land on `develop` cleanly, cherry-pick the single test commit (`655756a`) onto a develop-based branch, OR merge the infra to develop first. This is an artifact of trialing before the infra is merged — not a workflow defect.

### Net assessment after 2 trials

Both paths validated: **failure/escalation** (Trial 1) and **happy/green** (Trial 2). The core plumbing — codex-safe sandbox, JSON artifacts + schema validation, role separation (CODEX writes / VERIFIER verifies outside sandbox / REVIEWER judges), clean abort, escalation — all work. The friction items (env loading, worktree prep, tier blast-radius assessment, sandbox network) are v0.2 hardening, not blockers.

---

## Trial 3 — Parallel clusters (#30 + #32) — 2026-05-23

**Tier:** Standard each (CODEX + REVIEWER + VERIFIER). **Goal:** exercise v0.2 hardening + the never-run **parallel two-cluster** path with a hard DB-isolation contract. ARCHITECT/CONDUCTOR/VERIFIER = Claude; both workers = `codex exec` via `codex-safe.sh`.
**Pair (genuinely independent touch-sets):** #30 (extract `runIdempotent` helper — idempotency/voc/AA) ‖ #32 (rate-limit keyGenerator includes `workspace_id` — session-service/server). No shared edited file.
**Outcome:** GREEN end-to-end, **both clusters in parallel**. Both fixes implemented, committed, schema-valid pr_drafts, VERIFIER green against isolated DBs, CONDUCTOR reports both `verified`.

### Isolation contract (the headline finding)

Distinct-*schema* isolation is **NOT feasible** on this stack: the app hardcodes Postgres schemas `core`/`permission` (drizzle `schemaFilter`), and instance-global state (`pg_locks`, sequences) + shared schema objects mean a distinct `WORKSPACE_ID` alone only isolates workspace-scoped *rows*. **Sound isolation = one throwaway database per cluster.** Used `feedbackops_c30` + `feedbackops_c32`, each migrated (`drizzle-kit migrate`) and seeded, with `prepare-worktree.sh --env-profile` pointing each worktree's `DATABASE_URL`/`DATABASE_URL_MIGRATE` at its own DB. **Result: `create-voc` passed 31/31 in BOTH DBs concurrently, zero cross-contamination.**

### Flow exercised

| Step | Result |
|---|---|
| 2 worktrees off `feature/agent-workflow-trial`, prepped via `prepare-worktree.sh --env-profile` | ✓ RF4 guard *required* `--env-profile` (3+ other prepared worktrees present) |
| 2× `cmux-cluster.sh` (refuse-to-launch guard passed once prepped) | ✓ workspace:22 (#30), workspace:23 (#32) |
| 2× `codex-safe.sh` workers implementing in parallel | ✓ #30 `9738f15`, #32 `69dd8ee` |
| Workers wrote schema-valid pr_drafts with `worktree_path`+`base_branch`, `status:needs_amendment` (no `verify_result`) | ✓ B2 conditional respected — workers did NOT false-claim `ready` |
| VERIFIER (outside sandbox) ran `verify.sh` per isolated DB | ✓ #30: create-voc 31/31, run-idempotent 2/2, analytics-area 19/19 · #32: create-voc 31/31, session 11/11, rate-limits-purge 3/3 |
| Promote artifacts → `ready_for_review` + `verify_result` (ajv re-valid) | ✓ both valid |
| `conductor-rebuild.sh` over both clusters | ✓ both `verified` (per-worktree HEAD + RF2 branch-identity) |
| `artifact-fresh.sh` from the main checkout | ✓ both `current` (RF1 worktree-aware — resolved in each artifact's own worktree, not caller HEAD) |

### Friction / findings

9. **Schema-isolation insufficient → per-cluster DATABASE required** (headline; see above). Document this as the standard parallel-cluster isolation contract.
10. **Seed needs BOTH `DATABASE_URL` and `DATABASE_URL_MIGRATE` targeted** at the new DB — the `[seed]` VOC owner team is created via the migrate role; targeting only `DATABASE_URL` writes the team into the wrong DB and the seed fails.
11. **codex `workspace-write` sandbox cannot reach the DB** — both workers' integration suites skipped ("DB env unavailable"); they correctly deferred verification to VERIFIER. The B2 conditional `verify_result` was the load-bearing guard: it *forced* `status:needs_amendment` instead of a false `ready_for_review`. This is the right division and should stay.
12. **Pre-existing `src/cli/storage-bootstrap.ts(54,31) TS2559`** surfaced again; both workers correctly flagged it out-of-scope rather than touching it (the baseline-aware `verify.sh --typecheck` would gate it — see Trial 2 #7 / baseline `a5cd2f6`).
13. **Both issues escalate past Trivial** — #32 changes an exported return shape (`lookupActorIdByToken`), #30 is a cross-module shared-idempotency refactor; `tier-probe.sh` would disallow Trivial for both (assigned Standard). File count is not the tier.
14. **DB creation needs a superuser** — `fops_migrate` lacks `CREATEDB`; `createdb`/`dropdb` require an operator step. A background `!` `createdb` without `PGPASSWORD` hangs on the interactive `Password:` prompt (no TTY) — supply `PGPASSWORD=...` inline.

### v0.2 hardening exercised live (all held)

- **RF1** artifact-fresh worktree-aware — correct even run from the main checkout.
- **RF2** conductor-rebuild branch-identity + per-worktree HEAD — both `verified` legitimately.
- **RF4** prepare-worktree shared-env guard — *required* `--env-profile` (would have refused silent shared env).
- **A1/A3** verify.sh false-green classifier — reported real PASS counts; no skipped suite counted as green.
- **B2** pr_draft conditional `verify_result` — blocked false `ready` claims under sandbox DB-unavailability.

### Net assessment after 3 trials

Failure/escalation (T1), happy/green (T2), and **parallel two-cluster with DB isolation (T3)** all validated. The v0.2 reinforcements (RF1–RF7) held under a live parallel run. The one durable operational requirement surfaced: **parallel clusters need one throwaway database per cluster** (schema/workspace isolation is insufficient given fixed `core`/`permission` schemas + instance-global state), with seed targeting both app+migrate URLs.

### Trial output / cleanup

- Real fixes produced as trial output (NOT merged): `9738f15` on `feature/30-runidempotent-helper`, `69dd8ee` on `feature/32-ratelimit-ws-key`. Cherry-pick onto develop-based branches later (same pattern as #31's `655756a`).
- Throwaway DBs `feedbackops_c30`/`feedbackops_c32` to be dropped (needs superuser). Worktrees `wt-30-*`/`wt-32-*` removable once fixes are cherry-picked.
