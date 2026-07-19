# Workflow diagnosis round 2 — FABLE-GATE seat (issue #187)

Seat: clean-context final pre-merge gate. Round-1's 7 joint items (impact pass, ARCH
feasibility appendix, matrix rows w/ precondition+checkpoint+allowlist, AC-ID existence
script, conductor-COMPUTED completion gate, canonical ROUND-STATE.json, verify.sh
--verify-clean/--fresh split) are SETTLED — not relitigated. This round covers T1/T2/T3
and the fresh watchdog/classifier incident. Estimates use the ~10 min/round convention.

---

## A. Challenging sol

**T1 pos1 (terra = protocol not tier): agree, sharpen the ceiling.** Sol is right that no
post-gate evidence shows a residual tier problem, and impl=sol breaks the reviewer-one-tier-
above invariant. But sol's own caveat is the load-bearing line: the completion gate catches
omitted deliverables, NOT plausible-but-wrong code (C3 r1's 5 majors, C4 r1 TOCTOU). That is
precisely why the sol+Fable reviews stay full — a promotion would buy nothing the gates don't
already provide. Keep terra medium. Gate to a tier change on N7 telemetry, not anecdote.

**T1 pos2/3 (luna): agree with sol's conclusion — drop luna from product-code fix rounds —
but REPLACE its justification.** Sol leads with net-cost (token savings vs one induced round),
the *weakest* leg — a close trade the ledger can't settle. The "luna frees terra/sol capacity"
counter doesn't rescue it either, and here is the structural reason sol only asserted: **in a
solo-operator API workflow there is no capacity pool to free.** terra is not a scarce parallel
worker; it is an API model gated only by the shared account rate limit that luna consumes
identically, and wall-clock is dominated by the model-independent coordination round. The one
place capacity is real (rate-limit budget under parallel dispatch, C5's collision) is helped by
FEWER dispatches (N6), not cheaper ones. So sol's "coordination cost dominates" holds and the
capacity counter collapses. The *robust* justification is the gate seat's: **luna's failure
mode is the highest-severity signal corruption in the stack** — C3 r3's unconditional-teardown /
test-expectation edit is the FALSE-GREEN vector (a blessed wrong expectation is a false PASS
defeating every downstream gate). Removal is justified on quality grounds independent of cost.
Conductor's 3-clause classifier is REJECTED — "fully specified / zero judgment / expectation
values" are semantic labels its own C3 r3 misjudgment falsified. Keep luna ONLY as a
patch-carrier (pre-computed patch + deterministic oracle) and non-product transforms tsc/tests
re-check; there safety comes from the oracle, not the tier.

**T2 pos1 (compile-atomic chunks): agree.** Both seats converge; C1's 9→14 file growth proves
deferral only added a handoff. Sol's triggered-watch-item schema (surface/trigger/invariant/
owner/review_by_chunk/closed_by) is the right fix for the convention residual and I adopt it —
it beats "carry into every review," which just rebuilds prompt density.

**T2 pos2 (manifest + narrative): agree on salience, REJECT the dual-artifact framing both
seats assume.** Round-1 ALREADY settled canonical ROUND-STATE.json AND structured AC rows.
The "acceptance manifest" is not a third file — it is the *versioned AC section of
ROUND-STATE given a name*. Creating a separate hashed artifact reintroduces the exact seam
sol then spends five rules patching. Collapse it: the manifest IS ROUND-STATE's AC view;
`manifest_revision` IS ROUND-STATE's revision; the narrative is the only new per-dispatch
artifact (short task delta). On sol's sha256 machinery — proportionate ONLY if
script-computed, never hand-maintained (a hash the conductor hand-copies is bloat and a new
error surface). One writer (conductor) means sol's ARCHITECT-vs-CONDUCTOR provenance lanes
are over-specified; collapse to: conductor is sole AC writer, every revision gets a one-line
reason in the existing decision log, CODEX cannot edit acceptance. That is the 80% at a
fraction of the ceremony.

**T2 pos3 (Standard-tier diet): agree with sol, REJECT conductor's cut.** Delaying
ROUND-STATE until >2 rounds rebuilds the fragmented-authority failure round-1 explicitly
fixed. The conductor is diagnosing a real problem (over-process on small issues) with the
wrong knife: **the tax is hand-maintained prose, not artifact count.** A generated ~1KB state
file is nearly free. Diet by GENERATION, not OMISSION — minimal ROUND-STATE from dispatch 0,
ARCH/Full-Cluster sections omitted, pr_draft+review retained.

**N1 agree; N6/N8 must be COUPLED (sol keeps them separate).** N6's "2 consecutive
same-family failures" is not mechanical unless "family" is keyed to N8's origin codes.
Bind them: the breaker trips on two consecutive rounds sharing an N8 primary origin. Also
REFRAME N6 — it is not a brake on the implementer; **repeated failure is evidence the
ORACLE/CONTRACT is the suspect** (C4's undecided duplicate-id semantics, byte-vs-parsed
compare surfaced as impl "failures"). The diagnosis gate's real job is to force a
manifest/oracle re-examination. The count trigger (3rd re-dispatch) is fine as a
tier-probe-style biased-to-trip heuristic: a false trip costs one cheap diagnosis pass;
the false negative is C4's 9 rounds.

**N9 is genuinely NEW, not redundant with R5/R6.** R5/R6 proves each branch's artifact
matches THAT branch's HEAD — and explicitly states "no single global HEAD." That IS the gap:
C5 was green on its own HEAD (R5/R6 satisfied) while the *merge* of C2+C3+C5 was never
verified as a unit; the audit-detail variant resurfacing in C4 is exactly that cross-chunk
class. N9 is the integration-closure verify R5/R6 deliberately scopes out. One correction: it
must run as a mechanical *precursor* to the Fable gate (gate confirms, not discovers), never
as a substitute — same front-loading pattern as round-1 items 1–2.

## B. What the gate seat adds — the watchdog/classifier incident

The dispatch that launched THIS seat was killed by the workflow's own infrastructure, and the
diagnosis is a gate-class finding: **the workflow's liveness and refusal signals were built
for the code-WRITING implementer and are structurally wrong for the read-only reasoning seats
(ARCH-read-only, REVIEWER, debate/gate).** Round 1 and 2 are ADDING such seats (feasibility
pass, diagnosis gate, integrated-head closure) — the blind spot gets more expensive, not less.

- **Liveness for read-only seats — heartbeat-file, not worktree mtime.** File-mtime progress
  is always-false for a think/read task by design, so the 240s first-progress timeout killed a
  healthy seat. The conductor layer ALREADY uses HEARTBEAT-<pane>.json for liveness (persona
  §6); the watchdog uses mtime — an unreconciled inconsistency. Fix: declared read-only
  dispatches emit a periodic heartbeat file (codex-safe writes one per N s of process-alive),
  which *is* filesystem progress, so it satisfies the existing "process+fs, never stdout"
  liveness rule without trusting stdout. Low risk. Saving: eliminates the ~10-min false-kill +
  wasted re-dispatch per read-only seat, and unblocks parallel read-only seats generally.

- **Refusal classifier — the "standalone 3-digit" patch (playbook L130) is treating the
  symptom.** The classifier broke a SECOND time (a literal 429 in file content codex echoed to
  stderr) because it greps a channel that commingles codex's control errors, bash job-control
  lines, AND content bytes. You cannot classify a control decision from a content-polluted
  stream. Fix, in preference order: (a) classify from **exit code + codex's structured error
  object**, not a stderr regex; (b) if a scan is unavoidable, prefix codex-safe's OWN
  diagnostics with a sentinel and grep only sentinel lines — never child stderr passthrough.
  Gate framing: a refusal-misclassification is a **false terminal state** ("retry futile" when
  retry would succeed) that silently dropped retries — the same false-signal family as the
  246-phantom-fail and the narrow-filter false-PASS. Saving: prevents silent retry-skips that
  abort recoverable dispatches; the cost is a bounded classifier rewrite.

- **Unifying principle both incidents share (folds in N2):** **raw stderr is a human
  diagnostic artifact, never a machine-decision channel.** The 1.3MB ARCH stderr (N2), the
  content-echo that fooled the classifier, and the PID that fooled it before are one lesson:
  keep stderr on disk, tail it only for human diagnosis, and derive NO machine signal
  (liveness, refusal, completion) from it.

- **cmux-dispatch.sh flag forwarding — commit it with a smoke test.** The unforwarded
  --first-progress-timeout/--stall-timeout is the identical defect shape as the 2026-07-15
  --model/--effort gap (L143): a wrapper silently swallowing a flag → wrong default. Commit the
  patch, add a dry-run smoke asserting pass-through (mirroring codex-safe.smoke.sh). This is the
  band-aid (operator can bump the timeout for read-only seats); the heartbeat above is the
  structural fix that lets the timeout stay short.

## C. Joint final list — round-2 outcome (postable to feedbackops-workflow#1)

Round 2 of the #187 post-mortem. The 7 SETTLED items in the issue body stand unchanged; the
items below are round-2 additions/modifications answering the three reserved topics (model
mapping, complexity diet, new items) plus the fresh dispatch-infrastructure incident. Tags:
`[immediate]` conductor procedure · `[template]` prompt/brief text · `[toolkit]` script. All
`[toolkit]` items carry one cross-cutting constraint from this session's incidents: **target
macOS bash 3.2 — no `declare -A` / associative arrays** (a round-2 dispatch hit this
incompatibility), route stdin from `</dev/null`, and ship as a script file rather than an
inline one-liner (both already-fixed dispatch-hygiene classes; the same discipline applies to
every new script here).

1. **[immediate] Manifest = versioned AC section of ROUND-STATE (NOT a new file) + short
   narrative delta per dispatch.** Saving: prevents ~1 first-round omission each on C3+C4
   (~2 rounds). Quality holds: one normative source, revision cited on dispatch, completion
   gate rejects stale revision — no dual-authority seam, no hand-maintained hash.
2. **[immediate] Repeated-round breaker keyed to N8 origin codes** — trip on 2 consecutive
   rounds of same origin OR 3rd re-dispatch; diagnosis gate re-examines the ORACLE/CONTRACT
   first. Saving: 2–4 rounds on a C2/C4-shape chunk. Quality holds: separate AC-IDs +
   per-failure verifier evidence preserved through the batch; security may stop earlier.
3. **[immediate/template] Compile-atomic chunks + triggered convention-watch items** (sol's
   surface/trigger/invariant/owner/review_by_chunk/closed_by schema). Saving: ~1 round/
   shared-contract chunk. Quality holds: no new review tier (C1 already `packages/shared`);
   untriggered watches stay in state, not every narrative.
4. **[immediate] N4 parallel-by-default + N9 integrated-head closure as ONE package.** Default
   to parallel only under disjoint resolved write-sets, no shared generated/lockfile/migration
   file, isolated DB/env, reserved rate-limit budget; then a mandatory integrated-head
   typecheck + union verify BEFORE the Fable gate. Saving: 1–2 critical-path rounds/
   independent pair. Quality holds: parallel is unsafe WITHOUT the closure verify — they ship
   together or not at all; closure feeds the gate, never replaces it.
5. **[toolkit] Read-only-seat heartbeat liveness** — codex-safe emits a periodic heartbeat
   file for declared read-only dispatches; watchdog treats it as fs progress. Saving:
   eliminates false-kill + re-dispatch per read-only seat. Quality holds: satisfies the
   existing process+fs liveness rule; no stdout trust introduced.
6. **[toolkit] Refusal classifier from exit-code/structured-error, not raw-stderr regex;
   stderr is diagnostic-only (folds N2).** Saving: stops silent retry-skips on recoverable
   dispatches; kills the 1.3MB inline waste. Quality holds: control decisions no longer read a
   content-polluted channel — retains the full file for human triage.
7. **[toolkit] Commit cmux-dispatch.sh timeout-flag forwarding + dry-run smoke.** Saving:
   prevents wrong-default silent stalls. Quality holds: same forwarding contract already
   proven for --model/--effort.

**These are not one-offs — dispatch hygiene is a recurring defect class.** The session's fixed
incidents (stdin-block, quoting ×2, 33 orphaned workspaces, macOS bash 3.2 `declare -A`) plus
the two classifier bugs and the watchdog false-kill share one root: **the wrapper/dispatch
layer is under-tested relative to the code it dispatches.** Recommendation: every wrapper flag
and terminal-state path gets a dry-run smoke (as codex-safe.sh already has), so these stop
surfacing in production under load — the same evidence-gated rigor the workflow imposes on
product code.
8. **[immediate] Minimal generated ROUND-STATE from dispatch 0 for Standard tier** (ARCH/
   Full-Cluster sections omitted; pr_draft+review retained). Saving: ~1 reconstruction round
   on an escalated Standard issue. Quality holds: diet by generation not omission — the
   fragmented-authority fix is preserved.
9. **[toolkit] N1 generated re-review capsule** + **[template] N8 origin classification before
   redispatch** + **[immediate] N7 model/task telemetry** — adopt sol's forms unchanged; N8 is
   the enum N6 depends on; N7 is the precondition for ever revisiting the tier map.

**REJECTED:** conductor's 3-clause luna classifier (semantic labels its own C3 r3 falsified);
conductor's Standard-tier ROUND-STATE deferral (rebuilds fragmented authority); sol's separate
hashed manifest artifact + multi-actor provenance (over-specified for one writer — collapse
into ROUND-STATE); the playbook's "standalone 3-digit" classifier patch as sufficient (treats
the symptom, not the polluted-channel cause).

## D. Model-mapping answer

| Role | Model | Note |
|---|---|---|
| ARCH / adversarial co-design | gpt-5.6-sol medium, read-only | unchanged; + live-catalog feasibility probe |
| First-impl (any product code) | gpt-5.6-terra medium | unchanged default |
| Fix — behavioral/SQL/fixtures/teardown/schema/security/assertions | gpt-5.6-terra medium | luna REMOVED here |
| Fix — pre-computed exact patch + deterministic oracle (rename/literal) | gpt-5.6-luna low | patch-carrier only, else terra |
| Non-product scoping/utility transform, output re-checked by tsc/tests | gpt-5.6-luna low | oracle-gated |
| REVIEWER | gpt-5.6-sol medium | one tier above terra — invariant intact |
| Final gate | clean-context Fable/Opus | untouchable, full, whole-chunk |

**terra/luna decision, plainly:** terra is the default implementer at every tier that touches
product code. luna is confined to patch-carrying (a deterministic oracle catches either
model, so it is pure token cost) and non-product transforms; it is REMOVED from product-code
fix rounds because its failure mode is false-green, the worst signal corruption in the stack.
No promotion to impl=sol: it breaks the reviewer-tier invariant and buys nothing the full
sol+Fable reviews don't already provide.

**Telemetry required before revisiting (N7):** model/effort, task class, prompt+manifest
revision, tokens, wall-time, completion-gate result, first-review defect count+severity,
induced rework rounds. A routing change requires a minimum sample and a comparison of TOTAL
cost through gate closure — never token price alone. Until that ledger exists, the map above
is frozen: current evidence is all pre-gate anecdote.
