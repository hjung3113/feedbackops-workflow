# Status

_Last updated: 2026-05-24._

## Provenance

Extracted from the FeedbackOps repo on **2026-05-24** via `git filter-repo` (history-preserving, path-scoped): 45 commits, the exact workflow file set only — no product code. This repo is now the canonical home for the workflow; FeedbackOps keeps its own copy in open PRs (see below) pending a merge decision.

## Shipped

### v0.1 — scaffold + schemas + baseline verify
`.review/` artifact directory and JSON schemas (`pr_draft`, `review`, `touch`, `blocker`); the first false-green-proof `verify.sh` classifier; v0.1 implementation plan. Reviewed + GO.

### v0.2 — host-side prep + reconstructable state (~32 commits)
- `verify.sh`: env-load + false-green-proof vitest JSON classifier + baseline-aware `--typecheck` (fails only on NEW errors vs `.review/typecheck-baseline.txt`).
- `prepare-worktree.sh`: host-side deps+env prep; refuses shared env when ≥1 other worktree prepared unless `--env-profile`/`--allow-shared-env`.
- `tier-probe.sh`: disallows Trivial on exported-contract / ambiguous-exported-TS changes (advisory; `verify.sh --typecheck` is the oracle).
- `conductor-rebuild.sh`: reconstructs CONDUCTOR state from `.review/*.json`; per-worktree HEAD + branch-identity check; fallback can only demote, never `verified`.
- `artifact-fresh.sh`: base_branch-aware staleness, resolves in the artifact's OWN worktree.
- `review-archive.sh`, `rebase-inflight.sh` (dirty-safe, conflict-aborting; post-merge hook stays warn-only).
- Schemas: structured `blocker` (reason_code+evidence, no prose), conditional-required `verify_result` in `pr_draft`, new `phase_summary` + `heartbeat`.
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
  - Provenance: `VERIFY_ISSUE=<n>` emits `.review/ISSUE-<n>-VERIFY.json` (schema `verify.schema.json`; `db_target` carries host/db/role, never a password). Non-fatal; never flips the run's exit code.
  - `sandbox-network-deny.smoke.sh`: L1 (offline) asserts `codex-safe.sh` pins `--sandbox workspace-write` and grants no `danger-full-access`/`network_access`; L2 (opt-in `RUN_LIVE_SANDBOX_PROBE=1`) runs the in-sandbox probe and asserts loopback `BLOCKED`.
  - Repro scripts: `uds-pg-relay.mjs`, `uds-sandbox-probe.mjs`, `net-deny-probe.mjs`.
  - **Out-of-repo (operator machine):** global `~/.codex/config.toml` default lowered `danger-full-access` → `workspace-write` (defense-in-depth for bare `codex`).

## Trials (see `docs/agents/workflow-trial-log.md`)
- **T1 #33** — failure/escalation discipline (tier escalation via blocker artifact).
- **T2 #31** — happy path (narrow audit-log assertion).
- **T3 #30 ‖ #32** — parallel two-cluster run, GREEN, with per-cluster DB isolation.

## Key operating facts (don't relearn)
- Parallel clusters need **one throwaway DB each** — schema/workspace isolation is insufficient (fixed `core`/`permission` schemas + instance-global `pg_locks`). Seed with BOTH `DATABASE_URL` and `DATABASE_URL_MIGRATE` at the new DB.
- codex `workspace-write` blocks the DB → VERIFIER verifies outside the sandbox; `pr_draft`'s conditional `verify_result` blocks false `ready` claims.
- All `codex exec` MUST go through `scripts/codex-safe.sh`. Bare `codex exec` is forbidden.

## Remaining work / next

1. **FeedbackOps PR cleanup — DONE (2026-05-24).** Product fixes `#80`/`#81`/`#82` (#30/#31/#32) squash-merged to FeedbackOps `develop`. Workflow PRs `#83`/`#84` closed and their remote branches deleted — this repo is now canonical for the workflow; FeedbackOps is product-only.

2. **Usage ergonomics — how to point this toolkit at a target project.** Because the workflow was extracted OUT of FeedbackOps, the scripts no longer live inside any target repo. Running them means invoking by absolute path with cwd = the target worktree (see README "Usage"), and the target needs a `.review/` dir for artifacts. There is no install/vendor step yet. Candidate: an `install-into.sh <target-repo>` that symlinks or copies `scripts/` + `.review/schemas/` into a target, or a documented submodule pattern. Until then, invoke scripts by absolute path.
3. **VERIFIER ephemeral-DB automation.** Per-issue throwaway DB is currently a manual `createdb` + double-seed. Codex recommended automating: dedicated low-priv role, ephemeral DB/schema per issue, prod-cred block (partly done via the local-DB guard). Build a `prepare-verify-db.sh` helper.
4. **v0.4 — loopback revisit.** Watch codex issue #6737 (allow binding to local addresses). If it ships a loopback-only allowance, re-evaluate in-sandbox self-verify (would remove the VERIFIER-outside-sandbox split).
5. **Smoke runner + CI + coverage gaps.** Add a `run-all` that executes every `scripts/__tests__/*.smoke.sh` with a TAP summary; optionally wire a GitHub Action. Close coverage gaps: no direct smoke for `cmux-cluster.sh`, `codex-safe.sh`, `workflow-stash.sh`, `uds-pg-relay.mjs`; no schema fixtures for `review`, `touch`, `verify`.
6. **`.env.example`** documenting the env contract the scripts expect (`DATABASE_URL`, `DATABASE_URL_MIGRATE`, `WORKSPACE_ID`, `VERIFY_DATABASE_URL`, `VERIFY_ENV_ALLOW`).
7. **Reviewer follow-up from v0.3:** confirm the `env -i` scrub doesn't starve a DB-backed suite other than `create-voc` (only that one was validated end-to-end).

## Method (how this was built — continue the same)
- Co-design + adversarially review with a long-lived `codex exec` pane before/after implementing.
- Claude = design/review/Conductor; Codex = implementer (in sandbox). Human = Release Captain.
- Doc-sync discipline: every script/schema change syncs the playbook + README/STATUS in the same commit.
- Don't merge to `main` or push without explicit user approval.
