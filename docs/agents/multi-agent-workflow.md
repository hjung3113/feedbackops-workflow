# Multi-Agent Workflow — Operating Playbook v0.1

This file holds the *operating* rules for the multi-agent workflow (cmux 4-pane × Claude × Codex). For higher-level design discussion see `docs/agents/multi-agent-workflow-draft.md` and `docs/agents/workflow-*.html`.

## Risk Tier Routing

Every issue is one of three tiers. The tier picks the agent set.

| Tier | When | Agents | Artifacts |
|---|---|---|---|
| **Trivial** | P3 cleanup, single file, no API/domain/UI change | CODEX + VERIFIER | pr_draft only |
| **Standard** | P2 / single-module behavior change | CODEX + REVIEWER + VERIFIER | pr_draft + review |
| **Full Cluster** | Any of: migration, auth, permissions, shared UI shells, `packages/shared`, cross-module contract, prod data path | ARCHITECT + CODEX + REVIEWER + VERIFIER (+ VISUAL if UI) | all of pr_draft, touch, review, verify |

**Escalation rule:** if a Trivial or Standard issue's actual touch set hits any Full Cluster trigger (e.g. `packages/shared/*`, migrations), CODEX MUST abort with a `blocker` artifact. Set `reason_code` from the enum (`tier_escalation_required` for this case) and put the ACTUAL out-of-scope files/symbols you hit into `blocking_fact` — never copy the dispatch prompt's example phrasing. In trial #1 CODEX parroted the canned phrase `"touches packages/shared"` straight from the prompt even though the real cause was backend modules (`src/voc`, `src/permissions`); the structured `reason_code` + `blocking_fact` fields exist to kill that leak.

### Pre-dispatch tier probe

Before assigning the **Trivial** tier, run the probe over the touched files:

```
scripts/tier-probe.sh <touched-file> [<touched-file>...]
```

A non-zero exit **forbids Trivial — escalate.** The probe disallows Trivial when the diff changes an exported contract (`export interface|type|class|enum|function|const`, `export default`, named/star re-exports, `... from` re-exports, `constructor(`, `as const`, generic-constraint changes), when an `index.ts`/`index.tsx` barrel is touched at all, or — the catch-all anti-false-negative bias — when an exported-TS file's diff is not provably comment/whitespace-only.

The probe answers exactly one question: **"is Trivial disallowed?"** — NOT "is this change safe?". It is biased to disallow: **false positives (disallowing Trivial when it might've been fine) are acceptable; false negatives (allowing Trivial when a contract changed) are the harm.** The probe is advisory; `scripts/verify.sh --typecheck` is the precise blast-radius oracle and must still cover importing modules.

This exists because of trial **#33**: narrowing one exported TS type in a "single file" broke 5 importing modules. **File count is not the tier** — an exported-contract or ambiguous exported-TS change is non-Trivial regardless of how few files it touches.

## Release Captain

Every issue has one **Release Captain**. The Captain owns merge readiness with override authority.

- **Default Captain:** the user (interactive mode) or CONDUCTOR (v0.2+).
- **Authority:** may reject merge despite all-green artifacts.
- **Mandate:** verify *integrated behavior* — does the change work end-to-end, not just pass local tests?
- **Why:** REVIEWER checks design fit and VERIFIER checks commands, but neither owns "does this actually ship safely."

**Machine-checkable readiness (R5).** A `pr_draft` with `status: "ready_for_review"` is NOT done unless it carries a `verify_result` (`exit_code: 0`, `failed: 0`, `passed >= 1`) whose `verified_head_sha` equals the branch HEAD. A draft that claims ready but has no `verify_result`, or whose `verified_head_sha` no longer matches HEAD (work landed after verification), is treated by CONDUCTOR/Captain as **in_progress** — prose claims of "tests pass" do not count. The pr_draft schema enforces the `verify_result` requirement conditionally (it only fires for `ready_for_review`); `needs_amendment`/`abandoned` drafts need no evidence.

**State reconstruction (R6).** CONDUCTOR holds no in-memory state; it rebuilds chunk states purely from `.review/*.json` artifacts via `scripts/conductor-rebuild.sh <review-dir> [<fallback-head-sha>]`. Because CONDUCTOR spans MULTIPLE branches/worktrees, there is no single global branch HEAD — each `pr_draft` is resolved against ITS OWN worktree: if the artifact carries a `worktree_path`, the script runs `git -C <worktree_path> rev-parse HEAD` to get that branch's real HEAD. A draft is reported **verified** only when `status: ready_for_review`, `verify_result.failed == 0`, `passed > 0`, and `verified_head_sha` equals that worktree's current HEAD. If `verified_head_sha` no longer matches (work landed after verify) the state is **stale_verify**; if no `worktree_path` (and no fallback) can resolve a live HEAD the state is **unknown** — NEVER `verified`. Superseded artifacts are skipped; blockers report `blocked` with their `reason_code`.

## Codex Sandbox Rule

All `codex exec` invocations MUST go through `scripts/codex-safe.sh`, which enforces:

- `--sandbox workspace-write` (no read/write outside the working root)
- `--cd <worktree>` on the codex call (locks codex's writable root to one worktree). The wrapper's own CLI flag is `--cwd`; it maps that to codex's `-C/--cd`.
- abort-time `workflow-stash.sh` (preserve partial diff on non-zero exit)

Direct `codex exec` invocations are forbidden in this workflow.

## Worktree Prep

A fresh `git worktree` is **NOT dispatch-ready**: it has no `node_modules` and no gitignored `.env`. Because the codex sandbox blocks network, deps and env cannot self-provision inside it — provisioning MUST happen host-side, **outside the sandbox**, before dispatch.

Run `scripts/prepare-worktree.sh <wt>` on the host. It installs deps from the frozen lockfile (`pnpm install --frozen-lockfile`) and copies env files (`.env`, `apps/backend/.env`), printing every copied key (values redacted) and loudly flagging high-risk keys (DATABASE_URL, WORKSPACE_ID, PORT, anything with STORAGE/BUCKET/S3/SECRET/TOKEN/KEY/PASSWORD/CREDENTIAL).

`scripts/cmux-cluster.sh` **refuses to launch** if `<wt>/node_modules` or `<wt>/.env` is missing, naming what's missing and pointing at prepare-worktree.sh.

**Env is shared-state coupling.** Copying one `.env` into multiple worktrees points them all at the same mutable DATABASE_URL / WORKSPACE_ID / storage bucket — parallel clusters corrupt each other. When more than one prepared worktree already exists, prepare-worktree.sh refuses to copy env unless you pass `--env-profile <path>` (per-worktree env file, recommended) or `--allow-shared-env` (explicitly accept the risk).

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

### Baseline-aware typecheck

Typecheck is **baseline-aware**: VERIFIER runs `scripts/verify.sh --typecheck`. It runs `pnpm --filter backend run typecheck`, extracts `error TS…` lines, and diffs them against `.review/typecheck-baseline.txt`. It fails **only** on errors absent from that baseline — i.e. NEW compile errors the change introduced. A pre-existing baseline error is never permission to merge a NEW compile error.

Refresh `.review/typecheck-baseline.txt` (noting it in the commit) **only** when a pre-existing error is independently fixed — never to silence a new error.
