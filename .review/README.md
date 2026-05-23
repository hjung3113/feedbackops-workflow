# .review/

Per-issue agent handoff artifacts. JSON canonical, lifecycle-tracked.

## Files

- `ISSUE-N-PR-DRAFT.json` — CODEX → REVIEWER handoff (commit SHA, files, verify)
- `ISSUE-N-BLOCKER.json` — CODEX abort report (no commit, why stopped)
- `ISSUE-N-REVIEW.json` — REVIEWER findings + patch_instructions for ARCHITECT
- `ISSUE-N-TOUCH.json` — declared files (parallel coordination, v0.2+)
- `ISSUE-N-PARTIAL.diff` — stashed partial work on abort (v0.1: optional)

## Lifecycle

Every JSON includes `lifecycle: "draft" | "active" | "superseded" | "final"`.
Superseded files MUST be ignored by readers. Cleanup: archived under
`.review/archive/YYYY-MM/` on PR merge.

## Schema versioning

`schema_version: "1"` mandatory. Cross-version reads refused.

## Validation

```bash
pnpm dlx ajv-cli validate -s .review/schemas/pr_draft.schema.json -d .review/ISSUE-33-PR-DRAFT.json
```
