# Workflow diagnosis — issue #187 session (2026-07-19)

Context: FeedbackOps multi-agent dev workflow (conductor Fable session; ARCHITECT/REVIEWER = codex gpt-5.6-sol read-only; implementer = gpt-5.6-terra, mechanical = luna; VERIFIER = verify.sh panes vs throwaway DB; final gate = clean-context Fable agent). Full Cluster issue, 5 chunks C1-C5. All quality gates ultimately caught real defects — the question is cycle count, wall clock, and token spend, NOT whether the gates are useful.

## Round ledger

- C1 (shared contracts): 4 codex rounds + sol r1/r2/r3 + Fable gate r4 fix. r1 blockers: shared change broke backend exhaustive Record + FE consumers (consumer-sync NOT in the dispatch scope — conductor prompt design gap); r2b scoped-abort for 1 more FE file; Fable gate caught structural source.id leak path (real).
- C2 (migration 0039): 7 dispatch rounds. Defects: drizzle journal entry omitted (codex did not know the repo migration convention; prompt did not mention it); ARCH-specified FOR KEY SHARE impossible under SELECT-only owner (ARCH did not validate privilege reality); ARCH-specified in-migration CREATE ROLE impossible for fops_migrate (same); ACL array parse bug; expectation-not-extended spin (1 extra round).
- C3 (evidence routes): 5 rounds. r1: 5 majors incl. missing matrix rows + no runtime DTO parse DESPITE both being explicit in the dispatch prompt; r3 luna over-applied unconditional teardown (>0 asserted for tables intentionally empty) → 5 new fails; r5 wrong expected constant.
- C4 (create-finding): 6+ rounds (ongoing r6). False blocker (claimed fops_app lacks approvals SELECT — live catalog disproved in 1 psql). r1 review: entity_link.created audit detail variant missing (a C1-era consumer-sync gap resurfacing), TOCTOU, ZERO tests committed. r2 commit subject claimed "full route matrix" with zero tests added (false claim). r4: uuid cast + audit-cleanup convention NOT mirrored from C3 despite instruction. r5: 3 expectation bugs (nondeterministic ORDER, byte-vs-parsed compare, duplicate-id semantics undecided in prompt). r6: sol caught raw-text audit bypass + revocation identity flaw (real, deep).
- C5 (parallel worktree): 2 rounds only. r1 blocker: fixtures via app handle; 429 rate-limit collision.

## Transient incidents (fixed, non-recurring)
- Reviewer codex blocked 30 min on stdin (heredoc+background); fixed with </dev/null; memorized.
- Verify DB pollution across crashed runs → 246 phantom fails → rebuild.
- Conductor one-liner quoting bug made verify.sh print usage 4×; watcher waited on artifacts that never came (~4 min lost); fixed by script-file pattern.
- 33 cmux workspaces accumulated (cleanup rule not followed mid-session).

## Structural hypotheses (to debate)
S1. ARCH output not validated against privilege/convention reality (lock privileges, migrate-role capabilities, drizzle journal) → C2 burned 5 rounds on ARCH-spec-vs-reality gaps.
S2. Shared-contract chunks repeatedly miss consumers (C1 r1: entity-links Record + FE; C4 r1: audit detail variant). No mechanical consumer enumeration step exists before dispatch.
S3. Test matrices are pinned in dispatch prompts but implementers under-deliver them in r1 (C3 r1, C4 r1/r2). No machine-checkable matrix→test mapping is demanded, so omission is discovered only by reviewer, one round later.
S4. terra failure modes: plan-then-exit; false claims in commit subjects. Conductor has no automatic post-run sanity check (diff-stat vs promised deliverables).
S5. Fix-round granularity: expectation-level bugs (constants, ordering, casts) each cost a full dispatch+verify cycle (~10 min each). Multiple could be batched if the verifier reported ALL failures with ground truth in one artifact the fixer consumes.
S6. Token spend: sol reviews at medium effort each read the full diff + files (~60-200k tokens each; 10+ reviews so far). Confirm-rounds already downgraded to low. ARCH stderr alone 1.3MB. Fable gates are thorough but each re-reads the chunk.
S7. Verify DB lifecycle manual (migrate/seed/rebuild by conductor each round; new migration = manual re-apply). verify.sh has no auto-provision mode.

## Constraint
Review/verification quality MUST NOT drop: sol+Fable gates caught source.id leak, raw-text bypass, revocation flaw, TOCTOU — all real privacy defects. Any proposal must preserve or increase catch probability.
