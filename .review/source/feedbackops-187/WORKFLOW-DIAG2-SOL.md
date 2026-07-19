# Workflow diagnosis round 2 — SOL verdict

Estimates use the round-1 convention of approximately 10 minutes per dispatch/verify round. The full first Sol review and the clean-context Fable gate remain unchanged.

## T1 verdict

### Position 1 — terra deviations are protocol gaps: **agree, with an evidence limit**

The two named deviations do not justify a blanket tier upgrade. Plan-then-exit and “full route matrix” with zero tests are observable completion mismatches, and the conductor-computed gate checks exactly those facts without trusting terra. More importantly, the ledger contains no controlled evidence of terra repeating either deviation **after** that gate existed. Therefore the answer to (a) is: **protocol-not-tier is the right diagnosis on current evidence; there is no evidence that a tier problem remains after the gate.**

That conclusion is narrower than “terra quality is sufficient for every implementation.” C3 r1 still missed five majors, including two explicit requirements, and C4 r1 contained TOCTOU plus no tests. The completion gate catches omitted deliverables; it does not catch plausible but wrong implementation. Those defects justify the unchanged Sol and Fable reviews, not a model promotion: there is no terra-versus-higher-tier comparison showing that a higher implementer would remove enough rounds to repay a 2–3x per-round cost, and impl=sol also removes the OpenAI-side one-tier-above reviewer.

Keep terra medium as the default. Add a model-routing telemetry field before revisiting the choice: task class, model, prompt/manifest revision, wall time, token cost, completion-gate result, first-review defect count/severity, and induced rework rounds. A tier claim should require post-gate data, not pre-gate anecdotes.

### Position 2 — dispatch-type-sensitive mapping: **reframe**

“First implementation = terra; mechanical fix = luna” still assigns a model before proving that the work is mechanical. The C3 r3 failure was not merely an omitted exception in a classifier; it demonstrated that teardown, fixtures, and assertions encode domain preconditions even when the requested diff is tiny. The same is true of C3 r5's one-line expected constant and C4 r5's ordering, parsed-byte comparison, and duplicate-ID behavior. Line count and expected/actual evidence do not remove semantic judgment.

Use task sensitivity only to route **away from** luna:

- Product-code implementation and every fix that changes behavior, SQL, fixtures, setup/teardown, schemas, security/privacy logic, or assertions: terra medium.
- Luna low: scoping/utility work and non-product-code transformations only.
- Exact product-code transforms may use automation or a worker only when the dispatch supplies a complete patch, preimage hash, allowed paths, and deterministic oracle. At that point the model is a patch carrier, not a fixer; terra's marginal cost is cheap insurance.

This preserves the reviewer-tier invariant and eliminates the conductor's need to infer whether a deceptively small change is semantic.

### Position 3 — proposed luna classifier: **disagree; drop luna from product-code fix rounds**

The proposed three clauses are not machine-checkable. “Fully specified,” “zero judgment,” and “expectation values” are semantic labels, and C3 r3 passed them in the conductor's judgment while still creating five failures. Test expectations are particularly unsafe: changing one literal can bless incorrect behavior.

A genuinely machine-checkable classifier would have to require all of the following: exact file paths; preimage hashes; exact before/after hunks; no generated hunk outside that patch; no control-flow, operator, assertion, fixture, teardown, SQL, schema, migration, route, repository, or security/privacy files; and a deterministic compiler/test oracle. That leaves renames and literal substitutions whose patch is already known. There is no meaningful reasoning left for luna to contribute.

The net-cost case favors removal. Every luna fix still consumes the same dispatch/verify coordination round (~10 minutes) and the same quality gates. The ledger quantifies one luna mistake as one extra round (~10 minutes) but does not quantify any luna wall-clock saving; it only claims cheaper model usage on some true renames/constants. Even if terra costs 2–3x in model spend for three to five tiny fixes, avoiding one induced round plus classifier/triage overhead is the better quality-preserving trade. Reconsider only after telemetry shows a positive end-to-end saving, including rework and review—not token price alone.

## T2 verdict

### Position 1 — compile-atomic chunk boundaries: **agree for compile consumers; modify convention-watch handling**

A chunk that knowingly leaves the repository uncompilable is not a smaller complete chunk. Compile consumers belong to the same correctness module as the exported contract even when they cross package directories. C1 confirms this: its first commit was 9 files with 465 lines of churn; the finished chunk was 14 files with 1,114 lines of churn, and the consumer-sync fix alone touched 7 files with 466 lines of churn. Deferring those consumers did not make the work disappear; it added a dispatch/review transition.

The larger review is acceptable here. C1 already touched `packages/shared`, so the playbook already required the >8-files/shared-contract two-review workload. Including compile consumers would not have promoted it into a new review category. Estimated C1 effect: save one dispatch/verify round (~10 minutes), while adding roughly 5–10 minutes to the initial implementation/review pass; net wall-clock saving is modest (0–10 minutes), but it removes an invalid intermediate state and one handoff. Across repeated shared-contract chunks, expect ~1 round per occurrence.

Do not generalize this into feature-sized mega-chunks. Behavioral slices remain separate when each typechecks and has an independently meaningful oracle. Compile atomicity is an admission criterion, not permission to absorb unrelated behavior.

The convention-coupled residual needs more discipline than “carry it into every later review.” That recreates prompt density. Each watch item should contain `surface`, `trigger`, `expected invariant`, `owner`, `review_by_chunk`, and `closed_by` evidence. ARCHITECT creates it during impact analysis; CONDUCTOR carries only triggered items into the affected chunk; REVIEWER closes it with cited evidence. Untriggered items stay in ROUND-STATE but not in every narrative. The C1 audit-detail variant should have been a named finding/audit consumer triggered when C4 added the corresponding event—not ambient text for C2 and C3.

### Position 2 — acceptance manifest plus short narrative: **modify; adopt only with one normative source and hash pinning**

The split addresses salience collapse, but two editable artifacts create a new seam with two failure modes: the narrative silently restates stale requirements, or the manifest drifts after a ROUND-STATE decision. “Stable across fix rounds, updated only via ROUND-STATE decisions” does not identify who performs the update or which copy wins.

Adopt these rules:

1. The acceptance manifest is the only normative requirement interface. The narrative may explain intent and current work but must not restate normative ACs, allowlists, or commit gates.
2. Every dispatch pins `manifest_revision` and `manifest_sha256`; the completion gate rejects a stale or mismatched revision.
3. ROUND-STATE references the current manifest revision and records the decision that changed it; it does not duplicate AC rows.
4. ARCHITECT owns intra-chunk AC clarification within its autonomy. CONDUCTOR owns cross-chunk, contract, and tier changes. Either change increments the manifest revision with provenance; CODEX cannot edit acceptance.
5. A fix narrative contains only the delta, failing AC-IDs, evidence pointers, and exact fix range. Any newly discovered ambiguity becomes a blocker/decision, not an informal prompt amendment.

With those controls, the split plausibly prevents one first-round omission in each of C3 and C4: ~2 rounds/~20 minutes in this ledger. Without them, manifest drift can create a false mechanical green and cost at least the same round it seeks to save.

### Position 3 — Standard-tier diet: **disagree as written; keep a minimal state journal from round 0**

No ARCH document is appropriate for Standard unless a Full Cluster trigger appears. Delaying ROUND-STATE until “>2 rounds,” however, creates the record only after roughly 20 minutes of churn and requires reconstructing the first two rounds retrospectively. That is exactly the fragmented-authority failure the settled canonical state fixed. Artifact count is also the wrong cost proxy: a generated 1 KB state file is cheaper than a special branch in every conductor/reviewer procedure.

Standard must also retain the playbook's mandatory `pr_draft + review` artifacts; “manifest+narrative and verify artifact ONLY” must not be read as deleting them.

Use a minimal ROUND-STATE from dispatch 0 containing tier basis, manifest revision/hash, touch allowlist, verify filter, current HEAD, open decisions, and artifact pointers. Omit ARCH and Full-Cluster-only sections. If the touch set or risk escalates, extend the same artifact rather than starting a paper trail mid-issue. Cost: ~1–2 conductor minutes if generated; expected saving on an escalated Standard issue: one reconstruction/misdirected round (~10 minutes), with lower rather than higher review risk.

## T3

### CONDUCTOR seeds

- **N1 — modify.** Generate the re-review capsule from authoritative artifacts: prior verdict, exact fix range, failing→fixed AC-IDs, current verify pointer/HEAD, touch-set delta, and dependency hashes; reopen full scope on any risk-boundary/hash change. Expected saving: ~2–5 minutes and 40–70% reconstruction tokens per re-review, with no change to first review or Fable gate.
- **N2 — keep.** Store stderr on disk with hash/path/byte count and structured warning/error summary; inline only a bounded tail on non-zero/refused/stall diagnosis. The 1.3 MB ARCH stderr proves the token waste; risk is hidden warnings, mitigated by retaining the full file and warning counts.
- **N3 — modify.** Close a cmux workspace only after a fresh terminal RUN/BLOCKER artifact is persisted, the process is dead, and log pointers are recorded; run a sweep for terminal orphan workspaces. “Read RUN then close” alone can accept stale same-issue artifacts. Saving: roughly 3–8 operator minutes per loaded session; quality risk is loss of last-mile diagnostics, mitigated by disk logs.
- **N4 — modify.** Default to parallel only when DAG dependencies are clear, declared write-intent sets are disjoint after canonical path resolution, no shared generated file/lockfile/migration journal is touched, each cluster has an isolated DB/env, and rate-limit capacity is reserved. Tier-probe plus touch-set disjointness is insufficient because it detects risk tier, not transitive resource collisions. Rebase onto the current integration head and re-verify before consuming the result. Expected critical-path saving: ~1–2 rounds/~10–20 minutes per independent pair; risk is stale or conflicting integration, controlled by the final integrated-head verify.
- **N5 — modify.** Make the session-start checklist an executable preflight that records results, not another prose artifact: model probe, auth/automerge capability, DB cleanliness/profile, worktree readiness, stale artifact check, workspace sweep, and rate-limit budget. Expected saving: ~5–15 minutes/session and fewer false starts; risk is checklist staleness, so checks must fail closed and print their version.

### Additional candidates

#### N6 — repeated-round circuit breaker: **keep**

- **Problem evidence:** C2 reached 7 dispatches and C4 reached 9; later rounds included one-dimensional ACL parsing, expectation spins, and repeated matrix cleanup. Incremental patching continued after the defect pattern showed the current contract/oracle was unstable.
- **Proposed fix:** after either two consecutive failures in the same defect family or the third re-dispatch in a chunk, block another implementation dispatch. CONDUCTOR runs a diagnosis gate: classify all open failures, reopen any ambiguous decision, refresh the manifest once, and issue one consolidated fix batch. Security/privacy findings may always stop earlier.
- **Expected saving:** 2–4 rounds/~20–40 minutes on a C2/C4-shaped pathological chunk; near-zero cost on chunks closing in ≤2 rounds.
- **Quality risk:** batching unrelated fixes can obscure causality; preserve separate AC-IDs and require verifier evidence per failure before review.

#### N7 — model/task outcome telemetry: **keep**

- **Problem evidence:** this round cannot distinguish a post-gate terra tier problem from a protocol problem, and “luna saved money” has no quantified end-to-end ledger.
- **Proposed fix:** extend run accounting with model/effort, task class, prompt+manifest hashes, tokens, wall time, completion-gate result, first-review defect class/severity, and induced rework rounds. Review routing changes require a minimum sample and compare total cost through gate closure.
- **Expected saving:** no immediate round saving; prevents unsupported model changes and should recover ≥1 avoidable round per several issues once enough samples exist.
- **Quality risk:** optimizing to counts can reward shallow tasks; severity and gate escapes must outweigh raw defect count, and gates remain fixed.

#### N8 — defect-origin classification before redispatch: **keep**

- **Problem evidence:** the session contained behavioral plan-then-exit, an environmental sandbox-denial precedent, ARCH feasibility errors, a false live-privilege blocker, verifier pollution, and wrong expectations. Treating all as “implementer failed” sends work to the wrong seat.
- **Proposed fix:** every failed round gets exactly one primary origin code—`environment`, `dispatch_contract`, `implementation`, `test_oracle`, `verification_harness`, or `integration_drift`—with evidence and an owning seat. The next dispatch is forbidden until the owner/action pair is selected.
- **Expected saving:** one misdirected dispatch (~10 minutes) whenever attribution would otherwise be wrong; C2/C4 show several opportunities.
- **Quality risk:** premature single-cause labeling; allow secondary codes, but require one primary owner to prevent diffusion.

#### N9 — integrated-head closure for parallel/dependent chunks: **keep**

- **Problem evidence:** C5 ran in a parallel worktree while C2/C3 advanced the integration branch; artifact HEAD checks prove a branch was verified, not that the combined dependency closure remains green. Convention consumers also resurfaced only in later chunks.
- **Proposed fix:** after upstream merges/rebases and before final gate, create one canonical integrated candidate HEAD, run typecheck plus the union of touched-module verify filters, and bind the resulting artifact to that HEAD. Per-chunk verification remains unchanged.
- **Expected saving:** costs one 5–10 minute verification pass but avoids a late integration defect costing 1–2 rounds/~10–20 minutes; expected net is positive when two or more dependent chunks ran concurrently.
- **Quality risk:** added common-path time; trigger only for parallel or dependency-linked chunks, never independent serial work.

## Priority

1. **N6 repeated-round circuit breaker** — expected **2–4 rounds / 20–40 minutes** saved on a C2/C4-shaped chunk by replacing serial patch churn with one diagnosis and consolidated fix.
2. **T2 manifest/narrative split with revision/hash ownership** — expected **2 rounds / ~20 minutes** saved across C3+C4-like first-round omission patterns; prevents prompt density without creating dual authority.
3. **N4 guarded parallel-by-default execution** — expected **1–2 rounds / 10–20 minutes of critical path** saved per independent chunk pair; resource locks and integrated-head verification are mandatory.
4. **T2 compile-atomic contract chunks with triggered convention watch items** — expected **~1 round / ~10 minutes** saved per shared-contract chunk, with no additional review tier for an already-`packages/shared` change.
5. **T1 remove luna from product-code fix rounds** — observed saving opportunity **1 induced round / ~10 minutes** in this ledger; trades higher terra token cost on tiny fixes for lower misclassification and quality risk.

N1's generated review capsule is the next operational win: it saves roughly 2–5 minutes per re-review and substantial tokens, but primarily reduces review effort rather than dispatch count.
