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
