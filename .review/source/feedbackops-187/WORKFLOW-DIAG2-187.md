# Workflow diagnosis round 2 — reserved topics (2026-07-19)

Context: continuation of the #187 post-mortem debate. Round 1 produced 7 agreed items
(feedbackops-workflow#1): pre-scope-lock tsc+codegraph impact pass, ARCH live-catalog
feasibility appendix, AC-ID matrix rows with precondition+checkpoint+allowlist, pre-review
AC-ID existence script, conductor-computed completion gate, canonical ROUND-STATE.json,
verify.sh --verify-clean/--fresh split. Those are settled; do not relitigate them.

This round covers the three topics the user reserved. CONDUCTOR (this file) states a
position per topic; sol debates it; Fable gate seat counters and synthesizes.

---

## T1. Model mapping per task type — is terra the problem or the protocol?

Evidence on the table:

- terra deviation A: plan-then-exit — a dispatch exited 0 having written a plan/analysis
  and no implementation commits. (Distinct from the 2026-07-16 sandbox-denial zero-commit
  incident, which was environmental, not behavioral.)
- terra deviation B: commit subject claimed "full route matrix" with zero tests added
  (C4 r2) — a false completion claim.
- luna deviation: C3 r3 — dispatched for a "mechanical" teardown fix, luna over-applied
  unconditional teardown (asserted >0 rows for intentionally-empty tables) → 5 new
  failures, +1 full round.
- sol as reviewer caught every deep defect; no sol-seat quality complaints.
- Cost ladder reality: sol ≈ 2 tiers above terra; reviewer-one-tier-above invariant means
  impl=sol leaves no compliant reviewer on the OpenAI side.

CONDUCTOR position:

1. terra's two deviations are PROTOCOL gaps, not tier gaps. Both are exactly what the
   round-1 item 5 completion gate (conductor-computed diffstat + test discovery vs
   promised deliverables, hard stop on mismatch) detects mechanically: plan-then-exit is
   diffstat≈0, false claim is claim-vs-discovery mismatch. The gate was applied late in
   the session and caught deviation B's class immediately. Upgrading impl to sol would
   cost ~2-3x per round across 21+ rounds, break the reviewer invariant, and buy
   protection we now get from a script. Keep impl=terra medium.
2. Tier-mapping refinement I DO want debated: dispatch-type sensitivity, not blanket
   upgrade. Candidate rule: first implementation round of a chunk = terra medium;
   mechanical fix rounds with verifier-supplied expected/actual ground truth = luna low;
   anything touching security/privacy semantics or fixture/teardown SEMANTICS = terra
   (never luna, per C3 r3 — teardown scope requires judging which tables SHOULD be
   empty, which is semantic, and we mislabeled it mechanical).
3. luna net-value question: luna saved money on true renames/constant fixes, but C3 r3's
   +1 round likely erased several rounds of savings. Proposed classifier: luna ONLY when
   the fix is (a) fully specified by expected/actual evidence, (b) zero judgment about
   which assertions/tables/fixtures apply, (c) diff confined to test expectation values
   or identifiers. Everything else terra. Is this classifier crisp enough to apply
   mechanically, or does the conductor's own misclassification (C3 r3 was conductor's
   labeling error) mean the classifier needs a machine-checkable definition?

## T2. Complexity diet — chunk boundaries and prompt density

Evidence: C1 "shared contracts only" chunk broke compile consumers (backend exhaustive
Record + FE) discovered r1; audit-detail variant (convention consumer) resurfaced in C4;
initial dispatch prompts ~6KB mixing architecture/steps/invariants/matrix/verification/
docs/commit policy → predictable r1 omissions (C3 r1, C4 r1). Amendment fragments
C4/C4B/R2..R9 already addressed by ROUND-STATE (settled).

CONDUCTOR position:

1. Chunk boundary redefinition: adopt "a chunk is complete only if the repo typechecks
   and all registry/exhaustiveness-driven surfaces remain valid" as the BOUNDARY
   DEFINITION (compile atomicity). Concretely: the pre-scope-lock impact pass output
   (round-1 item 1) is not advisory — enumerated compile consumers GO IN the chunk, or
   the chunk is re-split so each piece still compiles. Convention-coupled consumers
   (audit variants) can't be enumerated mechanically → listed in ROUND-STATE as named
   watch items carried into every subsequent chunk's review scope.
   Concern to debate: this makes contract chunks bigger (C1 would have included backend
   + FE consumer edits). Bigger chunk = longer implementation round + bigger review
   diff. Is one bigger honest chunk cheaper than N chunks + cross-chunk resurfacing?
   My claim: yes for compile consumers (C1 paid r1+r2b anyway — the work was done, just
   one round later and with review churn), no for genuinely independent behavior (keep
   behavioral chunks separate).
2. Prompt split: two artifacts per dispatch. (a) ACCEPTANCE-MANIFEST (machine-readable:
   AC-ID rows with precondition/checkpoint/allowlist, file gates, verify filter,
   commit policy — stable across fix rounds, updated only via ROUND-STATE decisions);
   (b) TASK-NARRATIVE ≤ ~2KB (what to build this round, referencing manifest IDs).
   Fix-round prompts then shrink to: narrative delta + failing AC-IDs + evidence. This
   also feeds the AC-ID existence script (round-1 item 4) from the manifest directly.
3. Broader diet — where I think process weight is NOT justified and want challenge:
   Standard-tier issues currently inherit near-Full-Cluster ceremony in practice
   (prompt size, artifact count). Diet proposal: Standard tier gets manifest+narrative
   and verify artifact ONLY (no ROUND-STATE unless >2 rounds, no ARCH doc); Full
   Cluster keeps everything. Risk: mid-issue tier escalations lose the paper trail —
   escalation rule already forces re-tiering, so start artifacts then.

## T3. New items — candidates to mine this round

CONDUCTOR seeds (debate value, feasibility, and add your own):

- N1. Review capsule format for re-reviews was agreed in spirit (round-1 item 6 covers
  state, S6 covers tokens) but the CONTENT of a re-review dispatch is still freeform.
  Standardize: prior verdict + fix commit range + failing→fixed AC-IDs + verify
  evidence pointer. Worth a template?
- N2. stderr hygiene: ARCH stderr alone was 1.3MB; nothing consumes it unless a run
  fails. Rule: keep stderr on disk, never inline into prompts/state; only tail it into
  a dispatch when diagnosing a failure.
- N3. cmux workspace hygiene: 33 workspaces accumulated. Close-on-terminal-artifact
  rule exists but wasn't followed under load. Candidate: conductor closes workspace in
  the same action that reads the terminal RUN.json (one atomic habit), or a sweep
  script.
- N4. Parallel worktrees under-used: C5 in a parallel worktree cost only 2 rounds and
  its API rate-limit collision was the only friction. (Spelled without the bare
  three-digit status code on purpose: the watchdog's refusal classifier greps
  stderr for standalone 4xx numbers, and codex echoes file content to stderr.) When the DAG allows, default to
  parallelizing independent chunks (with per-cluster DB isolation per Trial 3), rather
  than treating parallel as exceptional. What guardrail prevents shared-file collisions
  — is tier-probe + touch-set disjointness enough?
- N5. Session-start checklist codification: automerge re-authorization, verify DB state
  check, workspace sweep — currently prose in HANDOFF; make it a checklist artifact the
  conductor executes and records.

Constraint unchanged from round 1: no proposal may thin sol review or the clean-context
Fable gate. Efficiency changes clean inputs, never reduce examined scope.
