# .review/

Per-issue agent handoff artifacts. JSON canonical, lifecycle-tracked.

## Files

- `ISSUE-N-PR-DRAFT.json` — CODEX → REVIEWER handoff (commit SHA, files, verify). A `status: "ready_for_review"` draft MUST carry `verify_result` (`verified_head_sha` + `passed`/`failed`/`exit_code`; schema requires `exit_code: 0`, `failed: 0`, `passed >= 1` when ready) — machine-checkable evidence, not prose. Also carries optional `worktree_path` (absolute path to the branch's worktree, for conductor-rebuild to resolve real HEAD) and `base_branch` (the integration branch it forked from, for artifact-fresh merge-base instead of assuming develop).
- `ISSUE-N-BLOCKER.json` — CODEX abort report (no commit, why stopped). Cause is structured, not prose: `reason_code` (enum) + `blocking_fact` (concrete observed fact naming the ACTUAL files/symbols hit — never copied from the dispatch prompt) + `attempted_commands` (exact commands run before aborting) + `needed_decision` (the specific human/ARCHITECT call needed to unblock). `recommended_actions` is now optional/demoted.
- `ISSUE-N-REVIEW.json` — REVIEWER findings + patch_instructions for ARCHITECT
- `ISSUE-N-TOUCH.json` — declared files (parallel coordination, v0.2+)
- `ISSUE-N-PARTIAL.diff` — stashed partial work on abort (v0.1: optional)
- `PHASE-N-SUMMARY.json` — CONDUCTOR roll-up of a phase's worker clusters. A DERIVED artifact (a cache of lower-level artifacts), never source of truth. Carries `derived_from[]` (each with `content_sha256` of the on-disk artifact + `head_sha`) and `chunks[]` (per-issue `state` + `evidence_artifact` + `evidence_head_sha`).
- `HEARTBEAT-<pane>.json` — per-pane liveness proof (pane, branch, head_sha, task, blocked, dirty, updated_at). Proves LIVENESS, not correctness.

## Derived-not-truth (PHASE-SUMMARY)

PHASE-SUMMARY is a cache of lower-level artifacts. Readers MUST treat `derived_from` as authority; a `chunks[].state == "verified"` claim is INVALID unless `evidence_head_sha` equals the branch HEAD, and a `derived_from[].content_sha256` that no longer matches the on-disk artifact means the summary is STALE and must be regenerated.

## Artifact expiry

An artifact carries a `base_sha` (the merge-base it was created against). As a
branch's base drifts, that artifact goes STALE. Before trusting any artifact, a
reader MUST run:

```bash
scripts/artifact-fresh.sh <artifact.json> [<integration-branch-override>]
```

Exit 0 = fresh; **any non-zero exit means the artifact is INVALID** and must be
rejected, not merely logged. Freshness is computed against the artifact's own
declared `base_branch` (NOT a hardcoded `develop`) — worker branches may fork
from an infra branch like `feature/agent-workflow-trial`. A CLI override lets a
caller force the integration branch. If **both** the override is absent and the
artifact has no `base_branch`, the check **refuses (fails with exit 2) rather
than assuming develop**.

## Lifecycle

Every JSON includes `lifecycle: "draft" | "active" | "superseded" | "final"`.
Superseded files MUST be ignored by readers. Cleanup: archived under
`.review/archive/YYYY-MM/` on PR merge.

## Schema versioning

`schema_version: "1"` mandatory. Cross-version reads refused.

## Conventions

- SHA fields (`base_sha`, `head_sha`, `reviewed_head_sha`) require the **full 40-char lowercase hex SHA**. Never use `git rev-parse --short`.
- `schema_version` is the **string** `"1"`, not the integer `1`. Writers MUST quote it.

## Validation

```bash
pnpm dlx ajv-cli validate -s .review/schemas/pr_draft.schema.json -d .review/ISSUE-33-PR-DRAFT.json
```

Note: `phase_summary` and `heartbeat` carry date-time string fields (`generated_at`, `updated_at`, `last_verify_at`). They are validated as plain `type: "string"` (no JSON Schema `format: "date-time"` keyword) because the `ajv-formats` plugin is not installable via `pnpm dlx` in this environment. If `ajv-formats` becomes available, re-add `"format": "date-time"` to those fields and validate with `-c ajv-formats`.
