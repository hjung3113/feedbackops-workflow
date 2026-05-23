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
