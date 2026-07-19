# Workflow diagnosis — FABLE-GATE seat debate (issue #187)

Seat: clean-context final pre-merge gate. In this session that seat re-verified privilege
reality against live catalogs, caught the `source.id` structural leak, the raw-text audit
bypass, the revocation-identity flaw, and judged the excerpt trust model. This document
challenges sol's proposals, adds what the gate seat sees that the reviewer seat doesn't,
and synthesizes a joint list.

---

## A. Challenging sol's five proposals

### (1) impact-manifest tooling vs conductor running codegraph/typecheck before scope lock
**Verdict: sol over-engineers. Don't build the script.**

This project already has codegraph — a full AST knowledge graph with `codegraph_impact` /
`codegraph_callers`. A bespoke `impact-manifest <base> <symbols>` reimplements most of it and
adds a maintenance surface. The S2 failures were not caused by *missing tooling*; they were
caused by the conductor **not running any enumeration at all** before scope lock. The C1
exhaustive-Record + FE-narrowing consumers are exactly what `codegraph_impact` on the changed
exported symbol returns, and a monorepo `tsc --noEmit` returns the compile consumers
*exhaustively and deterministically* — a superset of what a hand-rolled script would find.

Where sol also **under-shoots**: a manifest implies false sufficiency. The C4 audit-detail
variant resurfaced precisely because it is coupled by *convention*, not by a typed edge —
neither a script nor codegraph nor typecheck sees it. So the manifest cannot be trusted to
close S2; the residual (dynamic/registry/convention consumers) must stay with adversarial
review. Correct fix: [immediate] conductor runs `tsc --noEmit` + `codegraph_impact` on each
changed export before scope lock and pastes the result into ROUND-STATE. The load-bearing
control is the **typecheck-as-gate**, not a new toolkit artifact.

### (2) RUN.json completion protocol — will terra fill it honestly?
**Verdict: agree with the goal, but the JSON terra writes is NOT the control.**

terra already wrote a false commit subject ("full route matrix", zero tests). A
self-reported JSON from that same agent is another field to lie in. It becomes *mechanical*
only when the conductor **independently derives** the same facts and diffs them: diffstat
from `git diff --stat`, test count/names from the test-runner's own discovery output (never
from terra's claim), AC coverage from the AC-ID→test-name mapping run against actual
collected tests. terra's RUN.json is then merely a *claim*; any mismatch with conductor-
derived ground truth is a hard stop. Sharpen sol: demote RUN.json to redundant and make the
conductor's git+discovery recomputation the primary gate. That is what makes it trust-free.

### (3) AC-ID matrix mapping — Goodhart risk; script vs reviewer row-audit
**Verdict: cheap script for the mechanical half is worth it; it must NOT shrink the reviewer's semantic half.**

A pre-review script can verify existence (every AC-ID maps to ≥1 collected test, no dupes,
no zero-match) in seconds, catching a missing-row defect a full ~10-min dispatch+review round
earlier. That marginal saving is real and cheap — keep it. But the script's *guarantee* is
existence-only. The gate seat saw the vacuous failures sol names in point 7: "wrong-question
with unauthorized actor", "rollback after an insert that failed before the insert". Those
PASS and map to an ID while asserting nothing. Non-vacuousness is semantic and stays with the
reviewer regardless. Goodhart is managed not by the script but by **specifying precondition +
observable checkpoint in the matrix row itself** (see C-item 3), so a vacuous test is visible
as a spec violation. Rule: the green matrix never substitutes for the reviewer's row audit.

### (4) ROUND-STATE.json — reviewer token saving vs conductor maintenance cost
**Verdict: adopt, but only as the SINGLE source that REPLACES fragmented amendments.**

The gate seat's clean-context re-read is by design and must not change. The waste was in
sol's *re-reviews* reconstructing the effective contract from ARCH + dispatch + C4 + C4B +
C4R2..R5 fragments (sol's missed-point 2: fragmented authority). One canonical
ROUND-STATE.json read once per re-review removes that reconstruction and, more importantly,
removes contradictions between fragments. The maintenance objection dissolves **iff** it
*replaces* the scattered amendment prose the conductor already writes each round rather than
being layered on top. A JSON with a decision log is also less drift-prone than prose
amendments (progress-tracking prose is the highest-drift shape). The real win is fewer
contradictory scope fragments, not raw token count.

### (5) verify.sh --fresh — per-round DB cost vs pollution-only-after-crash
**Verdict: sol over-reaches. Fresh-every-invocation is too expensive as default and misses the bigger false-signal.**

The 246-phantom-fail pollution occurred *only after crashes*. Paying a unique-DB
migrate+seed on every verify — including the ~95% of assertion-fix rounds that never crash,
on a monotonically growing migration set — taxes the common path to insure the rare one. The
gate cares about *signal correctness*, and a polluted DB threatens both false-fail (the 246)
and false-pass (stale rows silently satisfying an assertion). You get that safety far cheaper
with an idempotent precheck than with a rebuild: default to a persistent DB plus a mandatory
`--verify-clean` sentinel / migration-hash check that ABORTS on dirty state, and reserve
`--fresh` for migration chunks (where the migration itself is under test) and post-crash runs.
Also — `--fresh` is orthogonal to this session's biggest false-signal risk: a **narrow test
filter yields false PASS**, and a **superuser app handle yields false FAIL**. Whole-module
filter + a low-priv app handle matters more than DB freshness and sol omits it.

---

## B. What the GATE seat knows that the reviewer seat missed

The reviewer reads the diff; the gate re-verifies against **live reality** with the **whole
chunk in one clean context**. That difference produced three distinct catch classes:

**Catchable earlier by a cheaper mechanism:**
- **Privilege reality.** The C4 false blocker (fops_app "lacks" approvals SELECT — disproved
  by one psql) and the C2 `FOR KEY SHARE` / in-migration `CREATE ROLE` impossibilities are
  all ARCH-claim-vs-live-grant gaps. The gate probed live catalogs; that is expensive and
  should move upstream: put the catalog probe in ARCH's feasibility pass **and** have
  verify.sh assert that the test DB's actual grants match the migration's intent. Then the
  gate *confirms* instead of *discovers*.
- **The `source.id` structural leak.** A field rode a nested object onto an anonymized
  surface. This is a data-flow property catchable a round earlier by a **positive field-
  allowlist assertion** ("response contains ONLY these fields"), not the presence-only
  assertions the matrix demanded. That is a matrix-row-spec change, not a new gate.

**Only catchable at the gate — trust nothing upstream to replace it:**
- **Raw-text audit bypass** (audit written from unparsed text, bypassing the sanitized path)
  and **revocation-identity flaw** (revocation keyed on the wrong principal). These are
  semantic security properties. No typecheck, script, manifest, or RUN.json can see them;
  they need adversarial reasoning about the security model against live behavior, whole-chunk.
  They were also the *deepest* defects (C4 r6). The excerpt trust-model judgment is the same
  class — it only makes sense with the full chunk in view.

**The load-bearing meta-lesson:** the gate's marginal catches were the most severe, so no
green upstream signal (manifest, matrix, RUN.json, --verify-clean) may be allowed to
authorize thinning or skipping the Fable gate. Every efficiency change below is structured to
clean the gate's *input* (canonical state, live-grant evidence) so it confirms faster — never
to shrink what it examines. The gate stays clean-context and full.

---

## C. Joint recommendation (7 items)

Each tagged `[immediate]` (conductor procedure this session) / `[template]` (prompt/brief
text) / `[toolkit]` (script work, separate toolkit repo).

1. **[immediate] Pre-scope-lock impact pass = `tsc --noEmit` + `codegraph_impact` on each
   changed export**, pasted into ROUND-STATE. *Replaces sol's impact-manifest script.*
   Saving: 1–2 rounds per shared-contract chunk (S2). Quality holds: typecheck is an
   exhaustive superset of a hand-rolled consumer scan; dynamic/convention consumers still go
   to review — nothing is removed from review, one deterministic layer is added.

2. **[immediate] ARCH feasibility pass probes live catalogs** — actual grants, migration-
   principal capability, preceding migration/journal convention, relevant uniqueness
   constraints — with command evidence in ARCH output. (Agree with sol S1.) Saving: C2 3–5
   rounds. Quality holds: pure addition; also front-loads the gate's live-catalog probe so
   the gate confirms rather than re-derives.

3. **[template] Every matrix row carries an AC-ID + explicit precondition + observable
   checkpoint + (where privacy-relevant) a positive field-allowlist assertion** — not just an
   expected status. Saving: catches vacuous tests and `source.id`-class leaks one round
   earlier. Quality holds: this is the single change that would have surfaced the leak
   upstream and raises the non-vacuousness floor; the reviewer's audit is unchanged.

4. **[toolkit] Pre-review script: AC-ID coverage check** — every ID maps to ≥1 collected
   test, no dupes, no zero-match; mechanical existence only. Saving: missing-row rounds
   (C3/C4). Quality holds: script explicitly certifies existence, NOT semantics; reviewer
   still audits non-vacuousness against the row's checkpoint (item 3). Goodhart contained.

5. **[immediate] Completion gate is conductor-COMPUTED, not terra-reported.** Conductor
   derives diffstat, test count/names, and AC coverage from `git` + test-runner discovery and
   hard-stops on any mismatch with terra's claim. *Sharpens sol's RUN.json — the JSON is a
   claim, the git/discovery recomputation is the control.* Saving: eliminates false-claim
   rounds (S4). Quality holds: mechanical because ground truth is git/the test runner, not
   self-report — directly answers "terra already lied once."

6. **[immediate] One canonical ROUND-STATE.json that REPLACES fragmented amendments** —
   current contract, locked decisions, prior findings, commit range, live-probe results.
   Re-reviews consume it; the Fable final gate stays clean-context and full. Saving: 40–70%
   of re-review reconstruction tokens (S6). Quality holds: gate scope untouched; reviewers
   stop re-deriving contradictory scope, fixing the fragmented-authority root cause.

7. **[toolkit] verify.sh gains `--verify-clean` as the default precheck** (sentinel /
   migration-hash abort on dirty state), with `--fresh` (unique DB) reserved for migration
   chunks and post-crash runs; **default to a whole-module test filter and a low-priv app
   handle**. *Scopes sol's fresh-every-invocation.* Saving: eliminates pollution
   investigations without paying a DB rebuild every round. Quality holds: prevents both
   false-fail (the 246) and false-pass (stale rows), and the whole-module/low-priv defaults
   close the larger false-signal holes (narrow filter → false PASS; superuser handle → false
   FAIL) that `--fresh` alone does not.

### Where sol and I disagree, and my call
- **impact-manifest script (sol #2 ROI):** I reject building it — codegraph + typecheck
  already cover the deterministic half, and the residual is un-scriptable. Reason: the S2 gap
  was *not running* enumeration, not a missing tool; a new script adds maintenance for no
  marginal catch. → item 1.
- **verify.sh `--fresh` every invocation (sol #5 ROI):** I scope it to migration/post-crash
  and prefer `--verify-clean` as default. Reason: rebuild taxes the common path for a
  crash-only risk, and it ignores the filter-scoping false-signal that hurt more. → item 7.
- **RUN.json as the control (sol #3 ROI / S4):** agree in spirit, disagree on mechanism — the
  self-written JSON is not the control; conductor-derived ground truth is. → item 5.
- **Agreements:** ARCH feasibility appendix (item 2), canonical round-state (item 6), AC-ID
  mechanical-check-plus-reviewer-keeps-semantics split (items 3–4).

**Net:** comparable to sol's estimate — roughly 8–14 fewer dispatch rounds and 40–60% fewer
repeated-review tokens on a five-chunk issue — while every security/privacy gate is preserved
and the clean-context Fable gate is explicitly protected from being thinned by any upstream
green signal.
