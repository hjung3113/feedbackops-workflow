## Verdict

All S1–S7 are real, but S1, S4, and S5 need reframing. The biggest waste came from dispatching contracts that were not yet executable or internally consistent—not from excessive review.

Estimates assume ~10 minutes per dispatch/verify round.

| Hypothesis | Judgment | Fix without weakening gates | Expected saving | Quality risk |
|---|---|---|---|---|
| **S1 ARCH reality gap** | **Real, broader than stated.** Three distinct failures: privilege feasibility, migration convention, and execution-principal capability. | Before locking ARCH, run a repository-backed feasibility pass: inspect live/catalog privileges, preceding migration + journal convention, constraints, and actual migration principal. Record commands/results in the ARCH output. | C2: **3–5 rounds, 30–50 min**, substantial ARCH/review tokens. | Low. Main risk is testing only the dev DB; require both repo bootstrap reasoning and live probe. |
| **S2 missed consumers** | **Real.** C1 was not an independently landable “contracts-only” chunk. Exhaustive Records, mappers, FE narrowing, audit variants, and generic entity-link surfaces were coupled compile/runtime consumers. | Generate a consumer-impact manifest before scope lock: imports, exhaustive Records/switches, schema parsers, DTO property reads, registry-driven surfaces. Either include consumers atomically or add a compatibility stage. | **1–2 rounds per shared-contract change, 15–30 min, 50–150k tokens.** | Search can miss dynamic consumers; full typecheck and adversarial review remain mandatory. |
| **S3 matrix under-delivery** | **Real.** The prose matrix was explicit but too large to be operationally binding. | Give every required row an ID; require a checked-in mapping `ID → test name/file → latest result`. A pre-review script rejects missing IDs, duplicate mappings, or zero matching tests. Reviewer still audits non-vacuousness. | **1 round on C3, 2+ on C4; 20–40 min.** | Goodhart risk from token comments; mitigate by mapping IDs to discovered test names/results, not comments alone. |
| **S4 Terra plan/claim failures** | **Real, but not model-specific.** This is a missing completion protocol. Commit prose was accepted without comparing promised deliverables to the diff. | Require `RUN.json`: changed files, diffstat, added test count/names, commands/results, unresolved AC IDs. Conductor sanity-checks it against git/test discovery before review dispatch. | **1–2 rounds/chunk where it triggers, 10–25 min.** | False-positive stops on unusual tests; allow explicit, reviewed exceptions—not silent bypass. |
| **S5 expectation-fix granularity** | **Real conditionally.** Batching independent assertion defects is safe; batching semantic/security failures is not. | Verifier emits every failing test with expected/actual, seed identity, and relevant row snapshot. Fixer may batch only failures classified “expectation/mechanical”; contract ambiguity and security remain separate decision gates. | C3/C4: **2–3 rounds, 20–30 min.** | Shotgun expectation updates can bless bad behavior; require ground-truth provenance and reviewer inspection of assertion changes. |
| **S6 review token spend** | **Real.** Initial full reviews were justified; repeated context reconstruction and large stderr were not. Confirm prompts already narrowed diffs, but lacked a trusted semantic capsule. | First review remains full. Re-review consumes prior verdict, exact fix range, changed dependency hashes, AC status, and verification evidence; reopen full files only when dependency/risk boundaries changed. Keep the final Fable gate clean-context and full. Suppress routine stderr unless failed. | **40–70% re-review tokens**, roughly **2–5 min/review**; no necessary round reduction. | Capsule omission. Mitigate with mechanically generated ranges/hashes plus unchanged full final gate. |
| **S7 manual DB lifecycle** | **Real.** It caused both routine overhead and a 246-failure false signal. | Add `verify.sh --fresh`: unique DB per invocation, bootstrap + full migrations + fixtures, trap cleanup, retain-on-failure, serialized migration step, machine-readable results. | Migration chunks: **10–20 min**, often **0.5–1 round**; eliminates pollution investigations. | Harness may diverge from production bootstrap; make it call the canonical migration path rather than reproducing it. |

## What the diagnosis missed

1. **The dispatch contracts themselves contained contradictions.** C4 demanded an `evidence_of` link per excerpt although active tuple uniqueness collapses that to one; it required `repo-evidence.ts` behavior while excluding that file. Those are pre-dispatch contract defects, not implementer under-delivery.

2. **Scope amendments became fragmented authority.** `C4`, `C4B`, then `C4R2..R5` forced every participant to reconstruct the effective contract. Maintain one canonical round-state artifact; amendments replace/update it with a decision log.

3. **Chunking followed file ownership, not atomic correctness boundaries.** C1 changed public unions and registries without their exhaustive consumers; the audit-detail variant resurfaced only in C4. A contract chunk should be defined by “repository compiles and all registry-driven surfaces remain valid,” not “shared package only.”

4. **Prompt density caused salience collapse.** Initial prompts mixed architecture, implementation steps, privacy invariants, file gates, dozens of test rows, verification, docs, and commit policy in ~6 KB. R1 omissions were predictable. Keep all requirements, but separate them into an executable acceptance manifest and a shorter task narrative.

5. **Ambiguities lacked a pre-implementation decision gate.** Duplicate excerpt-ID semantics and link cardinality should have been locked before coding. Review should discover violations, not decide previously unspecified product behavior.

6. **Reviewer reconstruction was unnecessarily expensive.** There was no authoritative summary of scope amendments, intended persistence cardinalities, new privacy boundaries, and executed evidence. I repeatedly derived those from ARCH + dispatch + diff + prior verdicts.

7. **Some tests were structurally easy to make vacuous.** Wrong-question with an unauthorized actor and “rollback after insert” that failed before insert are examples. Matrix rows need explicit preconditions and an observable checkpoint, not only expected status.

## Top 5 changes by ROI

1. **ARCH brief template:** architect must attach a feasibility appendix covering live/repo privileges, migration principal, preceding convention, relevant uniqueness constraints, and command evidence before decisions lock.

2. **Toolkit script:** add `impact-manifest <base> <symbols/files>` to enumerate compile consumers, exhaustive registries/switches, property readers, migration inventories, and proposed scope additions.

3. **Dispatch prompt template + toolkit:** assign AC IDs and require `RUN.json` mapping every ID to test name/file/result; conductor blocks review when changed-file, test-count, or claim checks disagree with git.

4. **Conductor procedure:** maintain one canonical `ROUND-STATE.json` containing current contract, amendments, unresolved decisions, allowed files, commit range, prior findings, and risk ledger; never make reviewers merge multiple prompt fragments mentally.

5. **Toolkit verification:** implement hermetic `verify.sh --fresh --all-failures`, producing complete expected/actual evidence and classifying only mechanical failures as batchable; preserve full Sol review and clean-context Fable final gate.

Net expectation for a comparable five-chunk issue: **8–14 fewer dispatch rounds, roughly 1.5–2.5 hours wall-clock, and 40–60% fewer repeated-review tokens**, while retaining every existing security/privacy gate.

