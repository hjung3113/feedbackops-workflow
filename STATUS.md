# Status

_Last updated: 2026-07-13._

## Provenance

Extracted from the FeedbackOps repo on **2026-05-24** via `git filter-repo` (history-preserving, path-scoped): 45 commits, the exact workflow file set only — no product code. This repo is now the canonical home for the workflow; FeedbackOps keeps its own copy in open PRs (see below) pending a merge decision.

## Shipped

### v0.1 — scaffold + schemas + baseline verify
`.review/` artifact directory and JSON schemas (`pr_draft`, `review`, `touch`, `blocker`); the first false-green-proof `verify.sh` classifier; v0.1 implementation plan. Reviewed + GO.

### v0.2 — host-side prep + reconstructable state (~32 commits)
- `verify.sh`: env-load + false-green-proof vitest JSON classifier + baseline-aware `--typecheck` (fails only on NEW errors vs `.review/typecheck-baseline.txt`; command crashes with no parseable TS errors fail closed).
- `prepare-worktree.sh`: host-side deps+env prep; refuses shared env when ≥1 other worktree prepared unless `--env-profile`/`--allow-shared-env`.
- `tier-probe.sh`: disallows Trivial on exported-contract / ambiguous-exported-TS changes (advisory; `verify.sh --typecheck` is the oracle).
- `conductor-rebuild.sh`: reconstructs CONDUCTOR state from `.review/*.json`; per-worktree HEAD + branch-identity check; fallback can only demote, never `verified`.
- `artifact-fresh.sh`: base_branch-aware staleness, resolves in the artifact's OWN worktree.
- `review-archive.sh`, `rebase-inflight.sh` (dirty-safe, conflict-aborting; post-merge hook stays warn-only).
- `codex-watchdog.sh`: wraps `codex-safe.sh` with process+filesystem liveness, stall kill/retry, 4xx fail-fast, and `.review/ISSUE-<n>-RUN.json` markers.
- Schemas: structured `blocker` (reason_code+evidence, no prose), deprecated-optional `pr_draft.verify_result` kept only for backward compatibility, new `phase_summary` + `heartbeat` + `codex_run`.
- Personas + expanded playbook.
- Reviewed: every task spec+quality reviewed; 2 codex adversarial rounds; 3 build-time bugs + 7 integration-seam holes fixed.

### v0.3 — sandbox containment finding + VERIFIER hardening
- **The finding (spike):** codex `workspace-write` (Seatbelt, codex-cli 0.133.0) blocks **all** network egress including **loopback** — an in-sandbox probe cannot `connect()` to `127.0.0.1` (TCP) **nor** to an AF_UNIX socket in a writable root; both fail `EPERM`. So there is **no containment-preserving way** to give a sandboxed worker DB access.
  - loopback-only allowance is unshipped (codex issue #6737 open; #6807 closed-folded).
  - the "UDS proxy" idea is **dead** (Seatbelt denies AF_UNIX connect too).
  - a full-egress `dbtest` profile was **rejected** as a standing workflow (pure risk-trade; VERIFIER already runs the same tests cleanly outside the sandbox). Codex co-design concurred.
- **Decision: status-quo** — worker stays network-denied; VERIFIER runs DB tests outside the sandbox. Revisit only when (a) codex ships loopback-only network, or (b) data shows DB-test verifier churn is a real bottleneck.
- **Hardening shipped:**
  - `verify.sh` filter mode: local-DB guard (`exit 3` on non-local `DATABASE_URL` host); `VERIFY_DATABASE_URL` least-privilege override + superuser-role WARN; `env -i` default-deny allowlist scrub (`VERIFY_ENV_ALLOW` for extras) so host secrets don't leak into tests.
  - Provenance: `VERIFY_ISSUE=<n>` emits `.review/ISSUE-<n>-VERIFY.json` (schema `verify.schema.json`; `db_target` carries host/db/role, never a password). A green run that cannot write a valid artifact fails closed with exit 5; failing test runs keep their failing classifier exit.
  - `sandbox-network-deny.smoke.sh`: L1 (offline) asserts `codex-safe.sh` pins `--sandbox workspace-write` and grants no `danger-full-access`/`network_access`; L2 (opt-in `RUN_LIVE_SANDBOX_PROBE=1`) runs the in-sandbox probe and asserts loopback `BLOCKED`.
  - Repro scripts: `uds-pg-relay.mjs`, `uds-sandbox-probe.mjs`, `net-deny-probe.mjs`.
  - **Out-of-repo (operator machine):** global `~/.codex/config.toml` default lowered `danger-full-access` → `workspace-write` (defense-in-depth for bare `codex`).

### v0.4 — `cmux-dispatch.sh` hardening (2026-07-13 incident fix)
- **Incident:** a hand-rolled `cmux new-workspace --command "codex-watchdog.sh ..."` dispatch forgot `--cwd <worktree>` on the cmux workspace itself; the workspace opened in cmux's default project dir and `codex-watchdog.sh` validated its relative `--prompt-file` against that dir instead of the intended worktree — silent `exit 2`, no `RUN.json`. Separately, CONDUCTOR polling assumed terminal `status` values of `"completed"`/`"failed"` that don't exist in the schema (actual terminal state is `status:"exited"` + `exit_code`), so the poll never caught it.
- `codex-watchdog.sh`: a relative `--prompt-file` now resolves against `--cwd` (not the calling shell's cwd) before the existence check; startup echoes the resolved `issue`/`prompt-file`/`cwd` so pane scrollback always shows what it tried; missing-file error names the resolved path + hints at the `--cwd`-relative resolution.
- New `scripts/cmux-dispatch.sh` — the mandated dispatch path. Validates worktree/prompt-file/`cmux` binary up front, absolutizes both paths, always passes `--cwd` to both `cmux workspace create` and the watchdog, then polls for `ISSUE-<N>-RUN.json`/`-BLOCKER.json` up to `--poll-timeout` so a dead-on-arrival dispatch is caught instead of silent. `--dry-run` prints the exact invocation without touching cmux (test seam).
- Smoke: `cmux-dispatch.smoke.sh` (11 cases: missing worktree, non-git worktree, missing prompt file, dry-run happy path asserting `--cwd`/absolute-prompt/`NODE_OPTIONS=`, dry-run never calls `cmux`, watchdog relative-prompt-file resolution).
- Docs: `docs/agents/multi-agent-workflow.md` now documents the RUN.json terminal-state contract explicitly (no `"completed"`/`"failed"` strings exist) and the incident; README points at `cmux-dispatch.sh` as the mandated usage-sketch step.

### v0.4b — verify-DB fail-open fixes (two more 2026-07-13 incidents)
- **`prepare-verify-db.sh` createdb flag bug + fail-open.** The old `createdb -d "$BASE_URL"` invocation is invalid on modern pg clients (`invalid option -- d`; createdb/dropdb's `-d`-shaped flag is `--maintenance-db`), so CREATE DATABASE failed — yet the script warned past it and STILL printed the final `VERIFY_DATABASE_URL=...` line pointing at a nonexistent DB, poisoning downstream `eval $(... | tail -1)` pipelines. Fixed: all DDL now goes through `psql` (accepts a URI directly); any mandatory-step failure (connection probe, CREATE, `--migrate-cmd`, `--seed-cmd`) exits non-zero WITHOUT printing the URL line. Docs/examples now state the admin URL's role must have CREATEDB — on a stock docker-compose.dev.yml box that is `postgres` on 5434; `fops_migrate` cannot create DBs.
- **`verify.sh` silent `.env` fallback.** With `VERIFY_ISSUE` set but `VERIFY_DATABASE_URL` unset/empty (upstream eval of empty stdout), verify.sh inherited the worktree `.env`'s `DATABASE_URL` (shared dev DB `feedbackops`) and produced a garbage FAIL artifact. Fixed fail-closed: distinct `exit 4` + "refusing to fall back to .env DATABASE_URL"; the non-local-host `exit 3` refusal is unchanged.
- Smokes extended: `prepare-verify-db.smoke.sh` (+8 asserts: createdb-never-invoked; failed create / migrate / connection each → non-zero with no `VERIFY_DATABASE_URL` line), `verify.smoke.sh` (+3 asserts: unset and empty `VERIFY_DATABASE_URL` in issue mode → exit 4 with message). Full suite 16/16.

### v0.4c — stale-artifact guard in `cmux-dispatch.sh` (first-production-use bug, 2026-07-14)
- **Bug:** on `cmux-dispatch.sh`'s FIRST production use (re-dispatch of issue 147 with a second prompt file), the previous watchdog run's `RUN.json` (`status:"exited"`) was still present and the poll accepted it IMMEDIATELY — reporting success before the new watchdog had even started. Had the new watchdog died pre-start, the dispatch would still have claimed success on the stale artifact.
- **Fix:** before creating the workspace the script records the identity (mtime + `started_at`) of any pre-existing `RUN.json`/`BLOCKER.json`, prints `waiting for fresh RUN.json (stale one from <started_at> present)`, and the poll only accepts an artifact whose identity changed (every watchdog attempt rewrites `started_at`) or that newly appeared. A stale artifact alone times out non-zero. Same-issue re-dispatch is documented as a supported pattern. Poll interval overridable via `CMUX_DISPATCH_POLL_INTERVAL` (test seam).
- Smoke: `cmux-dispatch.smoke.sh` +5 asserts via a stubbed `cmux` on PATH (stale RUN.json → timeout non-zero + waiting notice; fresh RUN.json after stale → accepted; stale BLOCKER.json → not accepted; first dispatch with no pre-existing artifact still accepts a new RUN.json). 16/16 suite green.
- **Bonus root-cause fix — watchdog 4xx misclassification (was the "stall smoke flake").** `codex-watchdog.sh`'s refusal classifier used a bare `4[0-9][0-9]` grep; a stall-killed child leaves bash's job line (`line NN: 74123 Terminated: 15 ...`) in the codex-safe stderr log, so any PID containing `4dd` misclassified a stall as a refusal — exit 4, retries skipped (production-affecting, and PIDs allocate sequentially so it failed in bursts). The pattern now requires a standalone 3-digit number. Regression case `pid_noise` added to `codex-watchdog.smoke.sh`; the intermittent stall-case failure is gone.

## Trials (see `docs/agents/workflow-trial-log.md`)
- **T1 #33** — failure/escalation discipline (tier escalation via blocker artifact).
- **T2 #31** — happy path (narrow audit-log assertion).
- **T3 #30 ‖ #32** — parallel two-cluster run, GREEN, with per-cluster DB isolation.

## Key operating facts (don't relearn)
- Parallel clusters need **one throwaway DB each** — schema/workspace isolation is insufficient (fixed `core`/`permission` schemas + instance-global `pg_locks`). Seed with BOTH `DATABASE_URL` and `DATABASE_URL_MIGRATE` at the new DB.
- codex `workspace-write` blocks the DB → VERIFIER verifies outside the sandbox; CONDUCTOR ignores deprecated `pr_draft.verify_result` and trusts only canonical `ISSUE-<n>-VERIFY.json` from VERIFIER.
- All `codex exec` MUST go through `scripts/codex-safe.sh`. Bare `codex exec` is forbidden.
- Dispatching codex into a visible cmux workspace MUST go through `scripts/cmux-dispatch.sh`, never a hand-rolled `cmux new-workspace --command`. RUN.json terminal state is `status:"exited"` + `exit_code` (no `"completed"`/`"failed"` strings) — poll for that, not those strings.
- `scripts/codex-safe.sh` pins omitted gpt-5.6 reasoning effort to `medium` before dispatch and refuses high/xhigh/max.

## Remaining work / next

1. **FeedbackOps PR cleanup — DONE (2026-05-24).** Product fixes `#80`/`#81`/`#82` (#30/#31/#32) squash-merged to FeedbackOps `develop`. Workflow PRs `#83`/`#84` closed and their remote branches deleted — this repo is now canonical for the workflow; FeedbackOps is product-only.

2. **Usage ergonomics — DONE (2026-05-24).** `scripts/install-into.sh <target-repo> [--mode symlink|copy] [--force]` wires a target to the toolkit (`<target>/.agent-workflow/{scripts,schemas}` + ensures `.review/`), refuses to install into the toolkit itself, idempotent. Smoke: `install-into.smoke.sh` (15 cases).
3. **VERIFIER ephemeral-DB automation — DONE (2026-05-24; hardened 2026-07-14, see v0.4b).** `scripts/prepare-verify-db.sh --issue <N> [--target <repo>] [--base-url <admin-url>] [--migrate-cmd] [--seed-cmd] [--drop]` provisions a per-issue `verify_issue_<N>` DB: numeric-issue guard, local-host fail-closed (`exit 3`), superuser-role WARN / `VERIFY_DB_ROLE` low-priv override, idempotent create via `psql` (never the createdb/dropdb clients), redacted logging, and prints `VERIFY_DATABASE_URL=<url>` as the last line for capture — ONLY when every mandatory step succeeded (fail closed otherwise, no URL line). Admin URL role needs CREATEDB. Smoke: `prepare-verify-db.smoke.sh` (19 asserts, no live Postgres needed).
4. **v0.4 — loopback revisit (blocked upstream).** Watch codex issue #6737 (allow binding to local addresses). _Checked 2026-05-24: still OPEN, unimplemented, no linked PR — status-quo holds._ If it ships a loopback-only allowance, re-evaluate in-sandbox self-verify (would remove the VERIFIER-outside-sandbox split).
5. **Smoke runner + CI + coverage gaps — DONE (2026-05-24; refreshed 2026-07-13).** `scripts/__tests__/run-all.sh` (TAP summary, `--list`, self-skips live layers). Schema fixtures `review`/`touch`/`verify`/`run`. Direct smokes cover `codex-safe.sh`, `codex-watchdog.sh`, `cmux-dispatch.sh`, `workflow-stash.sh`, `cmux-cluster.sh`, and `uds-pg-relay.mjs`. CI: `.github/workflows/smoke.yml` runs `run-all.sh` on push/PR (Node 22, ubuntu). **16/16 smokes pass locally** (with `NODE_OPTIONS` unset — an inherited `cmux-claude-node-options` preload otherwise breaks unrelated `node -e` calls in several smokes; pre-existing environment gotcha, not a workflow bug).
6. **`.env.example`** documenting the env contract — **DONE (2026-05-24; refreshed 2026-07-14)** (`DATABASE_URL`, `DATABASE_URL_MIGRATE`, `WORKSPACE_ID`, `VERIFY_DATABASE_URL` — required with `VERIFY_ISSUE`, `VERIFY_ENV_ALLOW`, `VERIFY_ISSUE`, `PGADMIN_URL` — role needs CREATEDB).
7. **Reviewer follow-up from v0.3 — DONE (2026-05-24).** Validated against FeedbackOps (via `install-into.sh` symlink, scripts run from `.agent-workflow/`): under the `env -i` scrub, `list-actors` (PASS 5) and `analytics-area` (PASS 19) DB-backed suites pass in addition to `create-voc` (PASS 31). `role-grants` fails — but fails identically WITH and WITHOUT the scrub, i.e. a pre-existing failure on local `develop`, not starved by the scrub. Conclusion: the scrub does not starve otherwise-passing suites. (Flag: `role-grants` integration failure on local develop is a separate, unrelated issue.)
8. **verify.sh target parameterization — WAIT.** The oracle is intentionally backend-Vitest-specific (`pnpm --filter backend ...`) until a second real target and fixtures justify a parameterized contract.

## Method (how this was built — continue the same)
- Co-design + adversarially review with a long-lived `codex exec` pane before/after implementing.
- Claude = design/review/Conductor; Codex = implementer (in sandbox). Human = Release Captain.
- Implementation, review, and verification are separate contexts; final review uses a clean context.
- Parallel Codex implementation uses separate prepared worktrees, never two workspace-write jobs in one checkout; clear `NODE_OPTIONS=` before dispatch/verify.
- Doc-sync discipline: every script/schema change syncs the playbook + README/STATUS in the same commit.
- Don't merge to `main` or push without explicit user approval.
