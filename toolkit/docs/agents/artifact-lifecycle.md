# Workflow artifact lifecycle

Per-issue agent handoff artifacts. JSON canonical, lifecycle-tracked. Artifact authority is runtime-neutral: selected `runtime` and `role` identify provenance/liveness only and never make a runtime's prose, RUN exit, or receipt authoritative.

Immutable derivation evidence belongs to a consuming repository's own evidence area; it is never runtime state or a distributable toolkit dependency.

## Files

- `ISSUE-N-PR-DRAFT.json` — implementation → REVIEWER handoff (commit SHA, files, claimed tests, risks). Runtime-neutral producers record `producer_runtime` and observed `producer_version`; legacy `CODEX` producers remain readable. It requires an absolute `worktree_path`, because independent consumers need that branch's live HEAD; the shared runtime boundary rejects a normal implementation exit without a fresh schema-valid issue/HEAD/worktree-bound draft. Its optional `verify_result` field is deprecated and ignored; an implementer cannot verify its own work.
- `ISSUE-N-BLOCKER.json` — runtime-neutral agent abort report (no commit, why stopped). It records producer runtime/version where required, the producer-observed `head_sha`, and structured cause. Only `active` and `final` BLOCKER artifacts are consumable; `superseded` is ignored. Runtime or role provenance never relaxes the normal schema/issue/HEAD freshness checks.
- `ISSUE-N-REVIEW.json` — independent REVIEWER findings + patch instructions. The sanctioned `agent-workflow.sh dispatch --produce-review` path uses the selected capability-probed runtime in its required read-only mode, pins the start HEAD, injects that exact value into the launch prompt (`reviewed_head_sha must be exactly <sha>`) because a bash-denied read-only reviewer cannot run `git rev-parse HEAD` itself, and overwrites the model-returned `reviewed_head_sha` with the same host-pinned value before validation (#137), validates schema/producer/issue/HEAD, and uses a repo-local temp plus atomic rename for canonical publication while holding the linked-worktree HEAD and selected ref locks Git itself uses for commits. For a non-Codex runtime, only the last parseable fenced `json` block (or a whole-buffer JSON object) may enter that unchanged validation; surrounding prose remains non-authoritative. Publication and Git lock directories publish an owner record before their visible name; a SIGKILL leaves only dead-owner locks that a later publisher can reclaim, while a live owner is never reclaimed. Each valid publication also retains the byte-identical immutable snapshot `ISSUE-N-REVIEW-<reviewed_head_sha>.json`; a differing snapshot is never overwritten. Round-state failure evidence should cite that snapshot so later canonical REVIEW publications cannot invalidate an earlier evidence hash. Invalid output, a non-zero reviewer exit, HEAD drift, pane prose, and CONDUCTOR transcription never replace it; a refused non-Codex attempt retains raw stdout only as `ISSUE-N-review-attempt<K>-output.log`. All publication locks are released on every failure path.
- `ISSUE-N-TOUCH.json` — declared files (parallel coordination, v0.2+)
- `ISSUE-N-RUN.json` — issue-scoped liveness snapshot (`running | exited | killed_stall | refused | exhausted`) shared by seats for that issue. New shared-watchdog records are `agent_run` and bind runtime, role, observed version, and per-watchdog `attempt`; the attempt counter is not a redispatch ordinal/failure round. `codex_run` remains legacy-readable. It is not launch identity or task-completion evidence: preserve the dispatch exit code and accept only fresh `mtime + started_at`. `exited/0` is emitted only after process and requested publication success, but still does not mean completion.
- `ISSUE-N-TRANSPORT.json` — non-authoritative transport receipt. New schema v2 receipts require selected runtime, role, and observed runtime version plus adapter/handle/runner provenance. Schema v1 remains readable for legacy transport inspection and may display Codex/implementation compatibility defaults, but cannot prove current runtime provenance. Neither version is REVIEW/VERIFY evidence. Same-issue receipt publication, marker repair, and cleanup are serialized. After publication, its runner receives a private receipt marker; the next successful receipt removes only prior marker-backed runners. If a publisher dies between receipt rename and marker creation, the next publisher repairs the current receipt runner's marker before superseding it. This retains the current receipt-bound runner and leaves unmarked legacy or in-flight runners untouched.
- `conductor_control_proposal` (transient runtime output shape, not a canonical file) — an untrusted read-only conductor may propose exactly one ROUND-STATE publication. The host publisher locks and validates schema, issue, live HEAD, worktree, base commit, exact target path, and monotonically increasing revision before atomically replacing the canonical ROUND-STATE. A denied proposal publishes nothing; runtimes never obtain product-code write permission through this seam.
- `ISSUE-N-ROUND-STATE.json` — CONDUCTOR-owned canonical contract state for Standard/Full Cluster work and any redispatch. In read-only conductor-control mode the runtime proposes and the locked host publisher alone writes validated bytes; workers never edit it. It replaces prose amendments and carries the current contract, AC manifest view (including `acceptance.expected_test_count`), optional compile-atomic `contract.chunk_boundary`, optional repeated-failure `round_control`, locked/open decisions, commit range, freshness provenance, live probes, and artifact pointers. Failure entries bind coherent evidence to content hash/HEAD and route origin-compatible actions. A schema-valid canonical BLOCKER may be sole failed-round evidence only for `dispatch_contract` routed to `contract_fix`; all other origins require failed VERIFY/REVIEW evidence. Closing a failure binds its exact AC set and canonical verify filter or REVIEW checklist item to lineage-valid PASS evidence. REVIEW closure requires `lifecycle:"final"`, `status:"pass"`, every checklist entry `met:true`, and exact `failure:<id>:<comma-separated-ac-ids>` identity; failure preserves `failure_closure_not_verified` with stable detail `review_lifecycle_not_final`, `review_status_not_pass`, or `review_checklist_unmet`. Watchdog attempts are not failure rounds. Top-level `revision` is the dispatched `manifest_revision`; workers never edit it, and Trivial initial work retains its separate pr_draft-only contract.
- `ISSUE-N-CONTEXT.md` and `ISSUE-N-PROMPT.md` — CONDUCTOR-owned uncommitted scratch inputs for prompt authoring. CONTEXT is the unedited source dump; PROMPT is the compressed worker input and carries the exact canonical AC block for Standard/Full writes and redispatches plus any schema-derived output contract rendered by `scripts/output-contract.sh`. Neither is canonical state, reconstructable evidence, or archival material; do not commit or move either into `.review/archive/`.
- `ISSUE-N-BLOCKER-QUARANTINED-<sha>.json` — host-owned raw recovery copy for a pre-existing malformed worker BLOCKER. Its bytes and digest are recorded in `round_control.blocker_recovery`; it is never canonical worker evidence, and recovery permits only one fresh redispatch admission whose host-owned ordinal is consumed independently of mutable failure ordering.
- `ISSUE-N-REVIEW-CAPSULE.json` and `.md` — deterministic, uncommitted re-review guidance derived from current canonical ROUND-STATE, the complete implementation prompt, final REVIEW, PR-DRAFT, and live HEAD. The JSON binds every source path/digest and the aggregate input digest; its budget records cumulative-section truncation and omitted counts. The Markdown is its bounded reviewer-facing rendering and the only prompt accepted by `--re-review`. They are never authority and are regenerated, not archived as evidence.
ROUND-STATE `contract.prohibitions[]` is required structured authority. Prompt prose may render it, but no consumer may reconstruct prohibitions with natural-language regex matching.

- `.review/.write-dispatch-issue-N-started` — pre-cmux durable intent marker for write dispatch. It keeps an attempt visible even if the process dies before RUN/BLOCKER creation; a later write must classify that failed round first.
- `<git-common-dir>/agent-workflow/redispatch-admissions/issue-N-dispatch-O` — atomic per-ordinal runtime consumption marker created by the shared dispatch core; mode changes cannot replay it. The host-owned `next_dispatch_ordinal` advances with that exact marker, and a crash leaves the marker durable rather than allowing mutable failure edits to reuse it. Integrated fix also creates `issue-N-integrated-fix`, an issue-wide singleton with a durable transaction identity; a dead lock or prepared pair is reclaimed under the issue lock only when ROUND-STATE has not advanced, while committed/advanced admissions are never cleared. These survive state edits and worktree recreation but are not contract authority and must not replace ROUND-STATE evidence.
- `ISSUE-N-VERIFY.json` — canonical VERIFIER evidence for the current branch/head and required `content_sha256`. The content identity is a stable digest of Git-visible working content (tracked plus non-ignored untracked paths, excluding `.review/`), so same-HEAD runs append only when they verified the same content. A corrected uncommitted tree starts a new aggregate; unchanged content remains red after any failed run. Publishers reject a worktree that changes during verification, and publication validates a same-directory temporary artifact before atomic replacement. This, not PR-DRAFT prose or a parallel clean-state file, drives verified state.
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
`artifact-fresh.sh` resolves a PR-DRAFT's merge-base in its required real
`worktree_path` (it runs `git -C "$worktree_path"`), so a reader running from
infra/main gets the right answer; a missing or invalid PR-DRAFT path is an
error. The caller-HEAD fallback remains only for other/legacy artifact shapes
that do not have the PR-DRAFT contract.

## Lifecycle

Every JSON includes `lifecycle: "draft" | "active" | "superseded" | "final"`.
Superseded files MUST be ignored by readers. Cleanup: on PR merge, run
`scripts/review-archive.sh <issue>` to move that issue's artifacts to
`.review/archive/YYYY-MM/`.

## Schema versioning

`schema_version: "1"` mandatory. Cross-version reads refused.

## Conventions

- Git SHA fields (`base_sha`, `head_sha`, `reviewed_head_sha`) require the **full 40-char lowercase hex SHA**. `VERIFY.content_sha256` is a full lowercase SHA-256 digest of the verified worktree content. Never use `git rev-parse --short`.
- `schema_version` is the **string** `"1"`, not the integer `1`. Writers MUST quote it.

## Validation

```bash
npx ajv-cli validate -s schemas/pr_draft.schema.json -d .review/ISSUE-33-PR-DRAFT.json
```

List schemas and fixtures from disk rather than relying on a hand-maintained inventory:

```bash
ls schemas/*.schema.json
ls schemas/fixtures/
```

Note: `phase_summary` and `heartbeat` carry date-time string fields (`generated_at`, `updated_at`, `last_verify_at`). They are validated as plain `type: "string"` (no JSON Schema `format: "date-time"` keyword) because the `ajv-formats` plugin was not available through the offline validator in this environment. If `ajv-formats` becomes available, re-add `"format": "date-time"` to those fields and validate with `-c ajv-formats`.
