# Workflow artifact lifecycle

Per-issue agent handoff artifacts. JSON canonical, lifecycle-tracked.

Immutable derivation evidence belongs to a consuming repository's own evidence area; it is never runtime state or a distributable toolkit dependency.

## Files

- `ISSUE-N-PR-DRAFT.json` — CODEX → REVIEWER implementation handoff (commit SHA, files, claimed tests, risks). Its optional `verify_result` field is deprecated and ignored; CODEX cannot verify its own work. `worktree_path` lets conductor-rebuild resolve the live HEAD and `base_branch` identifies the integration base for freshness checks.
- `ISSUE-N-BLOCKER.json` — CODEX abort report (no commit, why stopped). Cause is structured, not prose: `reason_code` (enum) + `blocking_fact` (concrete observed fact naming the ACTUAL files/symbols hit — never copied from the dispatch prompt) + `attempted_commands` (exact commands run before aborting) + `needed_decision` (the specific human/ARCHITECT call needed to unblock). `recommended_actions` has been REMOVED — free prose was the affordance that caused prompt-template leakage; with `additionalProperties:false`, any artifact still carrying it is now REJECTED.
- `ISSUE-N-REVIEW.json` — REVIEWER findings + patch_instructions for ARCHITECT. The sanctioned `cmux-dispatch.sh --produce-review` path runs the reviewer in an actual read-only Codex sandbox, captures its final JSON outside that sandbox, validates schema/producer/issue/live HEAD, and atomically publishes this canonical file. Invalid output, a non-zero reviewer exit, pane prose, and CONDUCTOR transcription never replace it.
- `ISSUE-N-TOUCH.json` — declared files (parallel coordination, v0.2+)
- `ISSUE-N-RUN.json` — issue-scoped liveness snapshot (`running | exited | killed_stall | refused | exhausted`) shared by seats for that issue. It is not launch identity or task-completion evidence: preserve the dispatch exit code and accept the file only when `mtime + started_at` is fresh for the current launch. `exited/0` means the process terminated cleanly, not that the task completed. Ordinary non-zero retries rewrite `running`; stall retries may move `killed_stall -> running`.
- `ISSUE-N-ROUND-STATE.json` — CONDUCTOR-owned canonical contract state for Standard/Full Cluster work and any redispatch. It replaces prose amendments and carries the current contract, AC manifest view (including `acceptance.expected_test_count`), optional compile-atomic `contract.chunk_boundary`, optional repeated-failure `round_control`, locked/open decisions, commit range, freshness provenance, live probes, and artifact pointers. Failure entries bind coherent failed evidence to content hash/HEAD and route origin-compatible actions. Closing one binds the exact failed AC set and canonical verify filter or REVIEW checklist item to lineage-valid PASS evidence. A REVIEW closure is PASS only when `lifecycle:"final"`, `status:"pass"`, and every checklist entry is `met:true`; it also names the exact `failure:<id>:<comma-separated-ac-ids>` checklist item. On a failed REVIEW predicate, `redispatch-check.sh` preserves `failure_closure_not_verified` and returns one stable detail: `review_lifecycle_not_final`, `review_status_not_pass`, or `review_checklist_unmet`. Watchdog attempts are not failure rounds. Its top-level `revision` is the `manifest_revision` pinned whenever the artifact is dispatched; CODEX never edits it. Trivial initial work retains its separate pr_draft-only contract.
- `.review/.write-dispatch-issue-N-started` — pre-cmux durable intent marker for write dispatch. It keeps an attempt visible even if the process dies before RUN/BLOCKER creation; a later write must classify that failed round first.
- `<git-common-dir>/agent-workflow/redispatch-admissions/issue-N-dispatch-O` — atomic per-ordinal runtime consumption marker created by `cmux-dispatch.sh`; mode changes cannot replay it. Integrated fix also creates `issue-N-integrated-fix`, an issue-wide singleton. These survive state edits and worktree recreation but are not contract authority and must not replace ROUND-STATE evidence.
- `ISSUE-N-VERIFY.json` — canonical VERIFIER evidence for the current branch/head. It carries the clean preflight's sanitized `sentinel`/`migration_hash` checks, test verdict, and typed failure records. This, not PR-DRAFT prose or a parallel clean-state file, drives verified state.
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

Freshness is a property of the artifact's OWN branch HEAD, not the caller's.
`artifact-fresh.sh` now resolves the merge-base in the artifact's own
`worktree_path` when that field is present and points at a real directory (it
runs `git -C "$worktree_path"`), so a reader running from infra/main gets the
right answer. When `worktree_path` is absent or missing, it falls back to the
caller's HEAD and prints a stderr **warning** that the result is only valid if
run from the artifact's checkout.

## Lifecycle

Every JSON includes `lifecycle: "draft" | "active" | "superseded" | "final"`.
Superseded files MUST be ignored by readers. Cleanup: on PR merge, run
`scripts/review-archive.sh <issue>` to move that issue's artifacts to
`.review/archive/YYYY-MM/`.

## Schema versioning

`schema_version: "1"` mandatory. Cross-version reads refused.

## Conventions

- SHA fields (`base_sha`, `head_sha`, `reviewed_head_sha`) require the **full 40-char lowercase hex SHA**. Never use `git rev-parse --short`.
- `schema_version` is the **string** `"1"`, not the integer `1`. Writers MUST quote it.

## Validation

```bash
pnpm dlx ajv-cli validate -s schemas/pr_draft.schema.json -d .review/ISSUE-33-PR-DRAFT.json
```

List schemas and fixtures from disk rather than relying on a hand-maintained inventory:

```bash
ls schemas/*.schema.json
ls schemas/fixtures/
```

Note: `phase_summary` and `heartbeat` carry date-time string fields (`generated_at`, `updated_at`, `last_verify_at`). They are validated as plain `type: "string"` (no JSON Schema `format: "date-time"` keyword) because the `ajv-formats` plugin is not installable via `pnpm dlx` in this environment. If `ajv-formats` becomes available, re-add `"format": "date-time"` to those fields and validate with `-c ajv-formats`.
