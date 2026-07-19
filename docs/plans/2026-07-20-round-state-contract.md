# ROUND-STATE contract plan (#7 + #8)

## Outcome

Introduce one canonical per-issue `ISSUE-<n>-ROUND-STATE.json` artifact owned by CONDUCTOR. Its versioned acceptance section replaces the standalone AC manifest consumed by the pre-review gate.

## Interface seams

1. **Artifact seam:** `.review/schemas/round_state.schema.json` defines the durable interface. Writers are CONDUCTOR; workers and reviewers are readers.
2. **Pre-review seam:** `scripts/ac-check.sh --round-state <file> --manifest-revision <n> --tests <file>` reads only `revision` plus `acceptance.criteria[].id` and refuses a stale revision.
3. **Documentation seam:** the playbook owns procedure. README and STATUS expose only the operator-facing synopsis.

The schema is the module interface. Narrative prompt generation, round-state mutation, completion calculation, circuit breaking, and impact-pass collection remain separate follow-up issues.

## Source evidence

The contract is derived from the imported FeedbackOps issue #187 artifacts:

- `.review/source/feedbackops-187/WORKFLOW-DIAG-FABLE.md` — canonical ROUND-STATE replaces amendments and contains current contract, locked decisions, prior findings, commit range, and live-probe results.
- `.review/source/feedbackops-187/WORKFLOW-DIAG2-FABLE.md` — the acceptance manifest is the ROUND-STATE AC view; `manifest_revision` is the ROUND-STATE revision; CONDUCTOR is the sole AC writer.
- `.review/source/feedbackops-187/WORKFLOW-DIAG2-SOL.md` — rejected alternative with a separate manifest and hash, retained as design-decision context.

## Vertical slices

1. Add failing smoke cases for a valid ROUND-STATE, a stale AC revision, malformed acceptance data, duplicate AC ids, and missing discovered-test coverage.
2. Change `ac-check.sh` from the standalone `--manifest` input to the ROUND-STATE plus explicit revision interface.
3. Add the ROUND-STATE schema and valid/invalid fixtures.
4. Synchronize `.review/README.md`, the operating playbook, README, STATUS, and both project-local agent-workflow skill copies.
5. Run the focused smoke, parse every schema/fixture as JSON, then run the full smoke suite.

## Success criteria

- A matching AC revision with every declared AC id present in test discovery exits 0.
- A stale revision exits 1 and never emits `OK`.
- Invalid JSON or invalid ROUND-STATE acceptance shape exits 2.
- Duplicate or undiscovered AC ids exit 1 with deterministic findings.
- The new artifact schema is CONDUCTOR-owned, lifecycle-aware, and rejects unknown fields.
- All affected documentation describes ROUND-STATE as the sole AC manifest authority.
- Focused and full smoke suites pass under Bash 3.2-compatible syntax.
