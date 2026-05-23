# Next-Session Prompt — Multi-Agent Workflow v0.2

> Paste the block below as the opening prompt of the next session. Everything needed to resume is self-contained. Do NOT merge anything to `develop` until v0.2 is built and the user approves.

---

## CONTEXT (read first)

We are building a cmux-based multi-agent dev workflow for the FeedbackOps monorepo. Claude designs/reviews, Codex (`codex exec`) implements, each in its own cmux pane. v0.1 is DONE and lives on branch **`feature/agent-workflow-trial`** (NOT merged to develop — intentional, hold until v0.2 complete + user approves).

**Read these before doing anything:**
- `docs/superpowers/plans/2026-05-23-agent-workflow-v0.1.md` — the v0.1 plan (6 tasks, all done)
- `docs/agents/multi-agent-workflow.md` — the operating playbook (risk tiers, Release Captain, sandbox rule, artifact lifecycle, tax brake)
- `docs/agents/workflow-trial-log.md` — 2 trial runs + 8 friction findings (THE most important input for v0.2)
- `docs/agents/workflow-adversarial.html` — the 13 critical risks + guardrails (open in browser)
- `docs/agents/workflow-decisions-v2.html` — round-4 design decisions (CONDUCTOR, JSON I/O, impeccable, checklist+smoke)
- `.review/README.md` + `.review/schemas/*.json` — the 4 artifact schemas

**What v0.1 delivered (on `feature/agent-workflow-trial`, ~24 commits ahead of develop):**
- `.review/` + 4 JSON schemas (pr_draft, blocker, review, touch) — strict, lifecycle + base_sha/head_sha/producer_role
- `scripts/codex-safe.sh` — codex wrapper enforcing `--sandbox workspace-write --cd <wt>` + abort-stash
- `scripts/workflow-stash.sh` — NUL-safe partial-work preservation on abort
- `scripts/cmux-cluster.sh` — 4-pane (ARCH/CODEX/REVIEWER/VERIFIER) cluster spawner, TRIAL_BASE override, infra-guard
- `.githooks/post-merge` — bash-3.2-compatible in-flight worktree rebase WARNING (warn only, not auto-rebase)
- `docs/agents/multi-agent-workflow.md` + AGENTS.md pointer

**Both workflow paths validated in trials:**
- Trial 1 (#33): failure/escalation path — CODEX correctly aborted on a mis-scoped issue, wrote schema-valid BLOCKER.json, clean tree.
- Trial 2 (#31): happy/green path — CODEX edited test-only, committed `655756a`, PR-DRAFT.json valid, VERIFIER 31/31 green, REVIEWER pass. Commit `655756a` lives on branch `feature/31-idem-audit-assertion` (NOT yet on develop — cherry-pick later).

## V0.2 SCOPE (what to build this session)

v0.1 covered the 5 CRIT "first-cluster-killers". v0.2 = the deferred long-term-stability risks + the friction the trials exposed. Build in this priority order:

### Priority A — friction fixes the trials proved real (do FIRST, cheap, high-value)
1. **VERIFIER env-load + skip-guard.** vitest does NOT auto-load `.env`; integration suites gate on `runIntegration = DATABASE_URL && WORKSPACE_ID` and SILENTLY skip (e.g. "31 skipped") when env is absent. A skipped suite must NOT count as green. Fix: the VERIFIER protocol/script must `set -a; source .env; set +a` before running, AND treat "all tests skipped" as FAIL, not pass. Consider a `scripts/verify.sh <test-filter>` that loads env + asserts non-zero test count.
2. **Worktree prep.** A fresh git worktree has no `node_modules` and no gitignored `.env`. `cmux-cluster.sh` (or a new `scripts/worktree-prep.sh`) should optionally `pnpm install` + copy `.env`/`apps/backend/.env` into the new worktree, or the playbook must document this as a mandatory pre-VERIFIER step.
3. **Scoped verification.** Repo-wide `pnpm --filter backend run typecheck` trips on a pre-existing unrelated error (`src/cli/storage-bootstrap.ts:54 TS2559`). VERIFIER should scope to the touched area (specific test + targeted typecheck) OR that pre-existing error should be fixed separately. Decide + document.
4. **Tier blast-radius probe.** #33 was labeled P3/"single file" but tightening a shared constructor type broke 5 modules. Tier assignment must weigh *type-tightening blast radius*, not file count. Add a pre-dispatch probe: for any change to a shared/exported type or constructor signature, run a quick `tsc` impact check (or grep callers) BEFORE assigning Trivial tier. Document the rule in `multi-agent-workflow.md`.
5. **Prompt-template leakage.** In Trial 1, CODEX parroted the dispatch prompt's canned escalation reason ("touches packages/shared") even though the real cause was backend modules. Make the ambiguity-rule instruction generic ("name the ACTUAL out-of-scope files you hit") instead of supplying a canned reason string.

### Priority B — CONDUCTOR agent (the headline v0.2 feature)
Build the 5th role: **CONDUCTOR** (Claude Opus 4.7, 1M context, dedicated pane).
- Holds entire-flow context via per-phase JSON summaries (`.review/PHASE-SUMMARY-N.json`).
- Decides serial vs parallel, task split, role/model/persona assignment.
- **READ-ONLY** on product code (hard rule — must not edit; only reads artifacts + dispatches).
- Failure modes to design against (from adversarial review): stale summaries (force update every material event), over-centralized bottleneck (define ARCHITECT autonomy list), hallucinated worker state (read state ONLY from `.review/*.json`, never infer), role bleed (read-only enforcement).
- **Context-overflow / recovery (risk #6):** CONDUCTOR must be reconstructable from disk. State lives 100% in `.review/*.json`; CONDUCTOR session may be rotated (N days / N clusters) and rebuilt from `PHASE-SUMMARY-*.json`. No in-memory-only state.
- Decide: own pane in a dedicated workspace vs a pane in each cluster. (Adversarial review leaned: dedicated pane outside clusters.)
- Write a CONDUCTOR persona/operating prompt (like the playbook) + a `PHASE-SUMMARY` schema.

### Priority C — remaining HIGH/MED risks
- **Pane heartbeat (risk #8):** `.review/PANE-<id>-HEARTBEAT.json` (branch, last commit, current task, blocked/unblocked, dirty, last-verify timestamp). CONDUCTOR reads these instead of assuming progress; stale heartbeat → alert. (In trials, the human manually `read-screen`'d — does not scale.)
- **Auto-rebase (risk #1, upgrade post-merge from warn→act):** optionally auto-rebase in-flight worktrees on the current `develop` + run affected tests after a merge. Currently only warns.
- **Artifact expiry (risk #7):** enforce that an artifact whose `base_sha` no longer matches the branch's base is treated as stale/invalid by readers (not just recorded).
- **Lifecycle enforcement + archival (risk #12):** readers must ignore `lifecycle:"superseded"`; on PR merge, move `.review/ISSUE-N-*.json` to `.review/archive/YYYY-MM/`. Add a small `scripts/review-archive.sh`.
- **Parallel cluster dry-run (risk #1):** actually run 2 independent clusters in parallel (declared touch-sets, ARCHITECT serializes shared-contract overlap) — never exercised in v0.1. Pick 2 genuinely-independent P3s.

### Priority D — visual review (risk #11)
- Integrate **impeccable** for FE/UI review under the REVIEWER role; separate VISUAL-REVIEWER pane when UI is complex.
- Trigger: layout/copy-placement/interaction-states/design-tokens/shells/reusable-UI changes. Skip pure API-hook wiring.
- Visual pass alone cannot close a chunk — must pair with an interaction script covering create/edit/error/empty/permission states (REVIEWER = checklist + smoke; VERIFIER owns durable Playwright specs).
- NOTE: confirm what "impeccable" actually is (a tool? MCP? skill?) before integrating — it was assumed to be a browser visual-diff/critic tool but never verified. Ask the user.

## METHOD
- Use the **superpowers:writing-plans** skill to write a v0.2 plan first (like v0.1), then **superpowers:subagent-driven-development** to execute (fresh implementer subagent per task + spec review + code-quality review; the human is Release Captain).
- **Co-design with codex** the same way v0.1 was built: a long-lived `codex exec` discussion pane for adversarial review of each design decision before implementing. (v0.1's discussion pane was `workspace:11 / surface:75` — may be gone; spawn a fresh one.)
- Keep doc-sync discipline: every script change syncs the plan doc + playbook in the same chunk (see memory `feedback_doc_sync`).
- Commit on `feature/agent-workflow-trial` (continue the branch) or a new `feature/agent-workflow-v0.2` branched from it — decide at start.
- Do NOT merge to develop. Do NOT push/PR without explicit user approval.

## FIRST STEPS THIS SESSION
1. Read the 6 context docs above (esp. `workflow-trial-log.md`).
2. Confirm with the user: what is "impeccable"? And CONDUCTOR pane placement (dedicated workspace vs per-cluster)?
3. Spawn a fresh codex discussion pane for adversarial co-design.
4. Write the v0.2 plan (writing-plans skill), Priorities A→B→C→D.
5. Execute via subagent-driven-development.

## OPEN THREADS / DEFERRED
- `feature/31-idem-audit-assertion` commit `655756a` (real #31 fix) needs cherry-picking onto a develop-based branch eventually → PR to develop.
- Pre-existing dangling refs in AGENTS.md (line ~120 prose + `**Workflow.**` bullet) point at `docs/agents/workflow.md` which never existed — separate cleanup, out of our scope, flag to user.
- `docs/wiki/` untracked (llmwiki scaffolding) — user to decide.
- v0.1 infra branch (~24 commits) + #31 fix both await develop merge after v0.2.
