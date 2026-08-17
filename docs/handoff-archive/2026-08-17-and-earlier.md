# Historical continuation — #142 Phase A1/A2a/A2b-part1 merged, A2b-part2 NOT started; 2 process-hygiene fixes landed; 2 new design issues filed (2026-08-17)

This supersedes every entry below it. Re-check `git status --short --branch`,
`git log -5 --oneline --decorate`, `git fetch --prune`, `gh issue list --state
open --limit 100`, `git worktree list` before trusting anything below — this
entry is a snapshot as of `main` at `62f45cb`.

## What happened this session

Continuing directly from the prior entry's "#142 root cause found, design
confirmed, not yet implemented" state. User asked to get the execution plan
re-reviewed by an Opus subagent once more, then implement via glm-5.3.

1. **Opus re-review of the #142 execution plan found 4 blocking corrections**
   before any dispatch: (a) `agent-watchdog.sh:91`'s launch line number was
   stale in the plan (actual line was different post-#135), (b) the planned
   fix wrongly targeted `conductor-control-publish.sh` for NDJSON extraction
   — that file is a host-side security boundary and must not learn
   per-runtime schemas; extraction belongs in `agent-watchdog.sh` before its
   existing `--proposal` handoff, (c) `codex-safe.sh` (the actual
   `--produce-review` codex path) was missing from the touched-file set
   entirely, (d) the `PROBE` table needed lockstep extension alongside the
   new `PROGRESS` table or a runtime lacking the new flag would fail open at
   dispatch instead of at the capability probe. Also should-fix: replace an
   opencode-only wall-clock backstop idea with one global cap (a
   livelocked-but-chatty process on ANY runtime, not just opencode, would
   otherwise never trip stall detection once `$OUTPUT` mtime becomes a
   progress signal).
2. **#142 was split into phases, each its own PR, after repeated dispatch
   failures on unsplit scope** — same failure class as the historical #128
   "revision 1 exhausted 3 attempts reading files, wrote nothing" pattern,
   which recurred here even after already being documented once:
   - **Phase A1 (PR #146, merged)**: `lib/runtime-registry.cjs` gains a
     declarative `PROGRESS` table (flags/event_format/stream/final.match/
     text_path per runtime) + `PROBE` extension + 3 new CLI accessors
     (`progress-flags`/`progress-stream`/`extract-final`), plus the
     independent `agent-watchdog.sh` `</dev/null` stdin fix. Took 2 failed
     10-AC dispatch attempts before narrowing to a 3-AC mechanical slice
     that succeeded. **A CONDUCTOR follow-up commit was needed inside the
     same PR**: extending `PROBE`'s fail-closed token lists broke 13 stub
     fixtures across the smoke suite whose hardcoded fake `--help` text
     predated the new tokens (real installed binaries do have all 3 flags,
     verified directly) — fixed as pure fixture-text sync, zero
     assertion-logic change. Opus scoped review: PASS, 2 non-blocking
     fix-level findings (`extract-final` returns first match not last;
     crashes with a raw stack trace on unreadable input) deferred to A2a.
   - **Phase A2a (PR #148, merged)**: closed those 2 A1 findings in
     `extract-final`, added a (per-attempt, later found buggy) wall-clock
     cap and `progressed()`'s `$OUTPUT`-mtime-OR clause. Opus review: PASS,
     2 new fix-level findings — the wall-clock cap's `launched_at` was
     captured inside the retry loop (so the real budget was
     `(MAX_RETRIES+1)×` the configured value, not the value itself), and its
     smoke test had no external time bound (a regression would hang CI
     forever instead of failing red).
   - **Phase A2b-part1 (PR #151, merged)**: closed both A2a findings
     (`launched_at` hoisted above the retry loop; wall-clock smoke case
     wrapped in `timeout 20`). Originally ALSO included switching
     `agent-runtime.sh`'s claude branch to stream NDJSON
     (`--output-format stream-json`) — **this was reverted mid-PR** after
     this PR's own Opus review found it would silently break every claude
     `--produce-review` dispatch on merge: `transcribe_review()`'s parse
     chain and the conductor-proposal handoff were never updated to consume
     NDJSON, and no smoke case exercises claude's reviewer path, so nothing
     would have caught the regression before merge. The streaming-argv
     change moves to **Phase A2b-part2, NOT YET STARTED** (see below).
     After 2 glm-5.3 dispatch attempts for this phase failed before
     producing a commit (one hit the redispatch-circuit-breaker gate on a
     stale `.write-dispatch-issue-142-started` marker, one exhausted its
     budget reading files), this phase was implemented directly by
     CONDUCTOR — small/mechanical enough per this session's new
     trivial-work-direct-execution guidance (see below).
3. **A real ~77-minute operational failure happened mid-session**: a
   background watcher polled `RUN.json` for `"status":
   "exited"/"exhausted"` only, which can never become true when
   `agent-workflow.sh dispatch` fails at the ADMISSION stage (before the
   runtime process ever launches) — the dispatch log had already shown the
   failure within seconds, but the watcher structurally could never notice.
   User caught this, then separately caught a duplicated-verification
   habit (running the local full suite AND watching CI for the identical
   pushed commit — CI-watching had become the real gate partway through the
   session and the now-redundant local step never got dropped). Both are
   now documented as concrete root-caused corrections in
   `feedback_no_hand_rolled_polling.md` and `feedback_trivial_no_full_suite.md`
   memory (not just vibes — exact incident, exact fix, exact "how to apply").
4. **2 new design issues filed** (both are genuine toolkit-scope gaps, not
   personal-practice notes — see each issue for the "why this belongs in
   the toolkit, not just memory" reasoning):
   - **#149** — tiered dispatch strategy: trivial-tier work (≤5 lines / zero
     regression risk / pure docs) should bypass the full
     `agent-workflow.sh dispatch` pipeline overhead entirely, not just use
     the existing `trivial` ROUND-STATE tier (which still dispatches).
     Working criteria drafted, exact thresholds and automation-vs-judgment
     call explicitly left open for follow-up design.
   - **#150** — adapter-axis abstraction work (like #135's runtime-registry)
     should wire EXISTING platform primitives where they already solve the
     problem (e.g. `orca-cli`'s `terminal read`/`terminal show` for
     orca-transport liveness observation) rather than just splitting axes
     and hand-rolling everything uniformly across all transports. Explicitly
     does NOT propose breaking `agent-workflow.sh`'s transport-neutral
     design (hard dependency on Orca's orchestration message protocol would
     break cmux/herdr support) — scoped as an orca-transport-specific
     supplementary signal only.
5. **`AGENTS.md` gained a new "Karpathy coding guidelines" section** (PR
   #152, merged) — the full 4-principle set (Think Before Coding, Simplicity
   First, Surgical Changes, Goal-Driven Execution) from
   `multica-ai/andrej-karpathy-skills`, installed per that project's own
   documented per-project install method, not paraphrased/summarized. File
   is still under its own 150-line cap (142 lines). Directly prompted by a
   live incident: an unfamiliar term in a user instruction ("카파시 스킬")
   was checked only against the local skill listing, then escalated straight
   to a clarifying question instead of a web search (which resolved it in
   one query to "Karpathy").
6. **A second `multi-agent-workflow.md` doc gap closed** (PR #153, merged):
   the "Verification cadence" section (from #144/#147, prior entry) said the
   full suite runs exactly once before PR/merge, but not WHERE that run
   belongs relative to CI. Added: once a push's CI run is being watched as
   the merge gate, do not also run the full suite locally against the same
   commit — stated generically (not tied to this repo's specific CI system)
   so it survives if this playbook is installed elsewhere.
7. **A real regression slipped through #144/#147's own merge**: PR #145 (the
   original #144 docs PR) was merged by the user at a commit whose CI was
   still failing (`toolkit/docs/agents/multi-agent-workflow.md` referenced
   the literal repo-only path `.github/tests/release-contract.smoke.sh`,
   which `release-contract.smoke.sh`'s own "product documents do not depend
   on repository infrastructure" check correctly rejects) — the CONDUCTOR
   fix commit for this had been pushed to the PR branch AFTER the merge
   already happened, so it was never actually included. Caught by checking
   `main`'s live content directly, fixed via a small follow-up PR (#147,
   merged) reusing the orphaned fix commit via cherry-pick.

## Still open / not done this session

- **Phase A2b-part2 is the actual remaining #142 work, not started**: claude's
  `agent-runtime.sh` exec branch needs to (re-)switch to
  `--output-format stream-json --verbose --include-partial-messages` (this
  exact 1-line change was already written and verified once, then reverted
  — the diff is known-good, just needs to land together with its consumers
  this time, not alone). Alongside it, same PR: `transcribe_review()` needs
  an NDJSON-final-event-extraction step as the NEW FIRST link in its
  fallback chain (NDJSON extraction → whole-file `JSON.parse` → fenced-regex,
  in that order, preserving existing stub fixtures); the conductor-proposal
  handoff (`agent-watchdog.sh` before its `--proposal "$OUTPUT"` call,
  currently near line 165) needs the same extraction into a clean temp file
  before handing off to `conductor-control-publish.sh` (which itself stays
  untouched); a smoke case exercising claude's `--produce-review` path with
  real stream-json-shaped fixture content (the current watchdog smoke only
  exercises opencode/codex reviewer paths — this gap is exactly what let the
  A2b-part1 regression almost merge silently); and the doc update to
  `multi-agent-workflow.md`'s "Runtime-neutral stall watchdog" section
  (~line 296-ish, re-check current line) describing the finished design,
  including why `progressed()` still prunes `.review/` (write_marker()
  writes there every attempt; un-pruning would be self-satisfying — settled,
  do not re-litigate).
- **Phase B (opencode/codex streaming wiring) still entirely unstarted** —
  same as every prior entry. Codex specifically is still blocked until the
  **2026-08-20** quota reset for a real (non-quota-exhausted) incremental-vs-
  batch-output verification; until then a global wall-clock cap (already
  landed, Phase A2a) is the acceptable temporary backstop for codex
  specifically, not a permanent design.
- **`codex-safe.sh`'s reviewer-path flag threading** (`agent-runtime.sh:94-101`
  execs `codex-safe.sh` for both write AND `--produce-review`, which builds
  its own separate `$CODEX_BIN exec` argv independently — adding codex's
  `--json` flag there is required for codex's reviewer path specifically,
  not covered by anything landed so far) is Phase B scope, not yet touched.
- **The `.review`-prune-blindness side issue** (codex's own
  `--output-last-message` tmp file lives inside `$CWD/.review/`, which
  `progressed()` prunes) is **settled as correct-by-construction, not an
  open question** — do not re-open it. A short paragraph explaining why
  belongs in the A2b-part2 doc update (see above), not a re-investigation.
- **#149 and #150 are both filed but undesigned** — next session should not
  treat them as ready-for-dispatch; they need the same kind of
  design-then-review pass #135/#136 got before implementation starts.
- Every issue from the entry below (#129, #131, #132, #133, #134, #136,
  #137) remains open and untouched, still gated behind #142 landing fully
  (Phase B, not just A) per this project's own established gating rule.
- Scratch worktrees safe to remove once confirmed no longer needed:
  `/tmp/hotfix-144` (PR #147, merged), `/tmp/hotfix-cadence2` (PR #153,
  merged) — both are throwaway single-commit worktrees for already-merged
  PRs.
- `/Users/hyojung/orca/workspaces/feedbackops-workflow/issue-142-watchdog-progress-phaseA`
  is the live worktree to REUSE for Phase A2b-part2 (currently on merged
  branch `fix/issue-142-watchdog-progress-phaseA2b` — create a new
  `fix/issue-142-watchdog-progress-phaseA2b2`-style branch from fresh `main`
  in this same worktree rather than creating a new one, per this session's
  own established redispatch-into-same-worktree pattern).

## Next session

1. `git fetch --prune` + `git pull`/rebase onto current `origin/main`
   FIRST — confirm `main` is past `62f45cb` (PRs #146/#148/#151/#147/#152/#153
   all merged) before trusting anything above.
2. Read the full #142 issue (both long research comments, still the
   authoritative root-cause/design record) plus this HANDOFF entry's "Phase
   A2b-part2" scope above before dispatching or implementing anything.
3. Implement Phase A2b-part2 as ONE PR (not further split unless a dispatch
   attempt actually exhausts on it) — the claude streaming-argv change is
   already known-good (write it back exactly as it was: `agent-runtime.sh`'s
   claude branch reads `progress-flags claude` from the registry instead of
   hardcoding `--output-format text`), the new work is
   `transcribe_review()`'s extraction step, the conductor-proposal handoff,
   the claude-reviewer smoke case, and the doc update. Get an Opus scoped
   review before merge — same rule applied to every #142 phase so far.
4. Only after Phase A2b-part2 merges does Phase B (opencode/codex wiring,
   codex blocked until 2026-08-20) become the next #142 step.
5. Do NOT re-litigate: the `.review`-prune design (settled correct), the
   `PROGRESS`/`PROBE` table shape (settled, Opus-verified in A1's review),
   the global-not-per-runtime wall-clock cap design (settled, Opus-verified
   in A1's review response to the original plan).
6. Apply this session's process corrections without re-deriving them:
   research (grep → local listings → web search) before asking or guessing
   on an unfamiliar term (`AGENTS.md`, new "Karpathy coding guidelines"
   section); never poll `RUN.json` alone for dispatch completion — check the
   dispatch wrapper's own log/exit immediately (`feedback_no_hand_rolled_polling.md`);
   don't run the local full suite once CI-watching is the actual merge gate
   for that push (`feedback_trivial_no_full_suite.md`,
   `multi-agent-workflow.md`'s "Verification cadence" section); trivial/
   mechanical/zero-regression work executes directly, no dispatch overhead
   (`feedback_trivial_work_direct_execution.md`, #149).
7. Preserve the same protected untracked paths listed in every prior entry
   below (unchanged this session): `.agents/skills/meta-prompt`,
   `.claude/`, `.opencode/`, `.review/ISSUE-70-launch.*`,
   `.review/ISSUE-71-launch.*`, `.review/open-issues-dag-2026-08-02.md`,
   `.review/open-issues-dag-2026-08-14.md`, `.review/open-issues-dag-2026-08-15.md`,
   `HANDOFF.md`, `docs/research/2026-07-27-external-model-scorecard-sources.md`,
   `docs/research/2026-08-15-full-feature-catalog.md`,
   `docs/plans/2026-08-15-feature-abstraction-two-axis-design.md`,
   `.review/DESIGN-REVIEW-two-axis-PROMPT*.md`.

---

# Current continuation — #142 design corrected + confirmed (streaming-output fix), NOT implemented, local checkout is STALE vs origin/main (2026-08-16, latest)

This supersedes the entry below it (same date, same topic — the entry
below already covers the session's first round of research; this entry
covers a second round that corrected one of that round's conclusions after
the user pushed back on trusting local empirical tests over official
docs/issue trackers). Re-check `git status --short --branch`, `git log -5
--oneline --decorate`, `git fetch --prune`, `gh issue list --state open
--limit 100`, `git worktree list` before trusting anything below.

## READ THIS FIRST

**Everything from the entry below still applies (stale local checkout
warning, #144 pure-docs task, implementation ordering) — this entry only
corrects and extends the runtime-evidence table.** Full detail, as always,
is posted to the GitHub issue, now in TWO comments:
- Round 1 (original candidates, rejections, first evidence table):
  https://github.com/hjung3113/feedbackops-workflow/issues/142#issuecomment-5305829890
- Round 2 (this entry's corrections — READ THIS ONE MOST RECENTLY, it
  supersedes round 1's codex/opencode rows):
  https://github.com/hjung3113/feedbackops-workflow/issues/142#issuecomment-5305852839

## What changed in round 2

User pushed on two things this round: (1) don't stop checking runtimes at
codex/claude/opencode — check other well-known agent CLIs too (specifically
named `omp` and `grok`, which turned out to include a real, currently
locally-installed CLI, `omp`/oh-my-pi, not a typo); (2) don't trust a single
quick local empirical test over official docs/issue trackers — go check
those first.

1. **`omp` (oh-my-pi, `@oh-my-pi/pi-coding-agent`) confirmed as a 7th
   real CLI with the same event-stream pattern** — installed locally at
   `~/.bun/bin/omp`, official docs at `omp.sh/docs` and `pi.dev/docs/latest/rpc`.
   `--mode json` streams NDJSON events to **stderr** (not stdout, unlike
   every other runtime checked — worth remembering if `omp` is ever wired
   in, since `agent-watchdog.sh` already captures stderr separately via
   `$STDERR`). `--mode rpc` is a full bidirectional JSONL protocol. Official
   description explicitly mentions the CLI "spawn[s] subagents that
   coordinate over an in-process IRC bus" — directly confirms the user's
   original instinct that mainstream agent CLIs already have this kind of
   capability and treating it as unconventional was wrong.
2. **codex's event schema is now confirmed from official docs** (not just
   this session's quota-invalidated local test): `item.completed` where
   `item.item.type === "agent_message"` carries the final answer text.
   This matches the event *names* seen in this session's own (quota-invalid)
   test exactly, so schema confidence is now real even though incremental-
   ness during actual work still needs the post-2026-08-20 re-test.
   `PROGRESS.codex` can now be written as `final_event_type:
   "item.completed"` (guarded on `item.item.type === "agent_message"`),
   `final_field: "item.text"` — no longer an unknown.
3. **opencode's status is DOWNGRADED — this corrects round 1's conclusion,
   which was wrong.** Round 1 called opencode's signal "confirmed but
   coarse" based on one short local test where all 3 events arrived
   cleanly. Checking the *actual* GitHub issue tracker (not just this
   session's own test) found:
   - `#26855` ("run --format json can exit before emitting final
     step_finish event") — real, but **already fixed**, merged PR #31389,
     2026-06-08.
   - `#31435` ("run --format json drops text and step-finish events in
     containerized environments") — **still open, unfixed, as of this
     session.** Three separate fix attempts (PRs #31434, #31446, #33146)
     were each auto-closed by a stale-PR bot without ever merging — the
     bug has had working-looking patches proposed three times and none
     landed. The failure mode described is specifically **containerized/
     sandboxed environments** — which is exactly this project's dispatch
     architecture (isolated git worktree + `opencode-read.json`
     permission sandbox). A short local (non-sandboxed) test, like the one
     this session ran, **cannot rule this bug in or out** — it needs to be
     re-tested through the actual dispatch path this project uses.
   - **New rule for opencode specifically**: do not trust the event stream
     alone as a sufficient progress signal until it's been re-tested through this
     repo's real worktree+permission-file dispatch path with a
     multi-step prompt. If the drop bug reproduces there, opencode's design
     must pair the event-stream check with a wall-clock cap as a safety
     net — not the event stream alone, and not wall-clock alone (round 1's
     rejected "Option D") — a genuine both/and for this one runtime, for a
     documented reason, not a fallback-because-we-gave-up.

## Next session

Same ordering as the entry below, with these amendments:
1. Still fetch/pull `origin/main` first, still do #144 first (unaffected
   by any of this).
2. When implementing the `PROGRESS` table in `lib/runtime-registry.cjs`:
   claude and codex entries can now be written with real confidence (codex
   schema confirmed via docs, pending only the incremental-timing re-test
   after 2026-08-20). **Do not write opencode's entry as a simple
   `flag + final_event_type` pair like the other two** — before trusting
   it, reproduce (or rule out) issue #31435 through this repo's actual
   `--opencode-permission-file toolkit/scripts/runtime-permissions/opencode-read.json`
   dispatch path, inside a real worktree, with a prompt long/complex enough
   to involve multiple tool calls (not a single-shot "count to 20" prompt —
   that's what this session's test used and it wasn't enough to catch a
   containerization-specific bug). If it reproduces, opencode's `PROGRESS`
   entry needs a `requires_wallclock_backstop: true`-style field (exact
   shape not decided) so the implementation knows to pair both signals for
   this runtime only.
3. `omp` is confirmed real and documented but still explicitly out of scope
   to register as a runtime in this repo — same "don't do it now, just
   don't design as if only 3 runtimes will ever exist" stance as round 1.
4. Everything else (the `</dev/null` fix, `conductor-control-publish.sh`
   wiring, claude-first implementation order, codex blocked until
   2026-08-20) is unchanged from the entry below.

---

# Historical continuation — #142 root-cause found (streaming-output fix), NOT implemented, local checkout is STALE vs origin/main (2026-08-16)

This is the authoritative continuation entry, superseding the one below it
(the "Tier 0+1 merged" entry — now historical, its content is still
accurate background but #142 has moved from "filed, unscoped" to "root
cause found, design confirmed, not yet coded"). Re-check `git status --short
--branch`, `git log -5 --oneline --decorate`, `git fetch --prune`, `gh issue
list --state open --limit 100`, `git worktree list` before trusting anything
below — this entry is a snapshot.

## READ THIS FIRST — local checkout is stale, and #142 is not a quick patch

1. **This session's local working tree was on branch
   `docs/conductor-native-subagent-dispatch-design`, based on an OLD `main`
   — `git fetch --prune` this session found `origin/main` had moved
   `41650a4..624913d`**, i.e. PRs #138-#143 (Tier 0 + Tier 1, described as
   "merged" in the entry below) really are merged on the remote, just not
   visible in this local checkout until a fetch/pull. `lib/runtime-registry.cjs`
   (from #135/PR #143) already exists on `origin/main` — confirmed by reading
   it directly via `git show origin/main:toolkit/scripts/lib/runtime-registry.cjs`.
   **Do a real `git pull`/rebase onto current `origin/main` before touching
   anything** — do not assume the entry below's "not merged" file states are
   still true.
2. **All the full research/evidence for #142 is now posted as a comment on
   the GitHub issue itself, not just in this file**:
   https://github.com/hjung3113/feedbackops-workflow/issues/142#issuecomment-5305829890
   — read that comment in full before resuming. This HANDOFF entry is a
   short pointer/summary; the issue comment has the complete evidence table,
   rejected-candidates list with reasons, and exact next-session repro
   commands. The user explicitly asked for this ("이슈로 맥락 잃지않게 모든
   정보 넣고") specifically so context survives even if this session's
   memory/HANDOFF chain breaks.

## What happened this session

User asked to design fixes for the top 2 priority issues from the entry
below (#142 watchdog progress-detection bug, #144 doc-cadence-rule gap),
using Haiku subagents for research/reconnaissance and doing the synthesis
personally, with an explicit architectural bar: no ad-hoc/one-off patch,
must generalize across adapters/runtimes per this project's existing
axis-registry pattern (`lib/runtime-registry.cjs`, `lib/transport-registry.cjs`).

1. **#144 (doc-cadence-rule) is fully scoped, not yet written**: insert a
   new "Verification cadence" subsection into
   `toolkit/docs/agents/multi-agent-workflow.md` right after the existing
   "Smoke Suite Diagnostics" section (line ~388), stating the rule from the
   issue body verbatim (focused smoke only mid-fix, full `run-all.sh` +
   `release-contract.smoke.sh` exactly once at the PR/merge gate, no tier
   exception); add a one-line cross-reference pointer in `AGENTS.md` near
   its existing "Run affected smoke tests after a change" line (~line 46),
   matching that file's existing pointer style (see lines 7/72 for the
   format precedent). Pure docs, zero code diff, zero risk — this can be
   done first, in 5 minutes, at the start of next session, before anything
   else.
2. **#142 went through 3 rounds of design + adversarial review**, each
   round finding the prior round's favorite candidate was wrong or
   insufficient:
   - Round 1 (own analysis): proposed switching `MODE=read` dispatches to a
     CPU-time-delta progress check ("Candidate A"). **User rejected as
     unconventional** ("통상적이지않은 방법") before any subagent review —
     correctly, per round 3's findings.
   - Round 2 (own analysis after user's counter-suggestion): proposed
     watching the existing `$OUTPUT` stdout-capture file's mtime as an
     additional signal ("Candidate B", uniform across modes, no branching).
     Dispatched an **Opus subagent adversarial review** — empirically
     killed it: measured `claude --print --output-format text` writing
     **zero bytes for 12 of 14 seconds**, then the entire response at once
     at exit. Text-format output is architecturally batch, not streaming;
     no file-location change fixes that.
   - Round 2.5 (own analysis): proposed "Option D" — abandon stall
     detection for `MODE=read` entirely, use only an absolute wall-clock
     cap. **User explicitly rejected this as not a root-cause fix**
     ("애초에 실행됬는데도 잘못판단하지 않도록하는 근본적인 해결책 없어?").
   - Round 3 (the actual finding): user pushed to check whether the
     underlying CLIs have a genuine incremental-output mode at all, and
     — separately — pushed hard that this must generalize beyond just
     codex/claude/opencode ("어뎁터들 에이전트들... 옴프나 grok처럼 좀
     유명한거 다확인해... 인터페이스를 뚫고 각 에이전트 어뎁터에 맞는
     코드를 작성"). Dispatched **both an Opus subagent AND a real
     `zai-coding-plan/glm-5.3`/max review** (the latter via a direct
     `agent-runtime.sh run --runtime opencode` invocation, bypassing the
     buggy watchdog on purpose — same workaround pattern as the prior
     session's #135 review). Both independently converged on: **the
     runtimes' own NDJSON event-stream output flags** (`claude
     --output-format stream-json`, `codex --json`, `opencode --format
     json`) are the real progress signal — architecturally independent of
     model cooperation, unlike every previously-considered option.
     Empirically verified this session (see the GitHub issue comment for
     the full table): **claude confirmed incremental at token-level
     resolution** (Opus5 measured 5 growing samples over 10s); **opencode
     confirmed incremental but coarse** (grew in 2 discrete steps, the
     `text` event contains the whole final response already assembled, not
     token deltas — untested whether multi-step work produces more
     `step_start` events); **codex's own test this session is INVALID** —
     account quota was exhausted mid-test, so the "growth" observed was
     just 5 quota-exhaustion error events, not real work; needs re-test
     after the quota resets (**2026-08-20** per the error message).
     Checking `gemini --help` (installed locally) and web docs for `amp`
     (Sourcegraph) and `grok` (xAI Grok Build) confirmed **all 5 CLIs
     checked have some form of this flag** — this is an industry-standard
     pattern, not a 3-runtime coincidence, validating the user's
     instinct/pushback completely.
3. **2 more real bugs found as a side effect of empirical testing, unrelated
   to the progress-detection root cause but must be fixed alongside it**:
   - `agent-watchdog.sh:83` launches the child with **no `</dev/null`** —
     confirmed live twice this session (once by the Opus subagent, once
     directly in this session's own codex test) that a runtime can hang
     forever reading for stdin input it will never receive, even when the
     prompt is passed as a CLI argument. `dispatch-core.sh`'s own preflight
     probe already redirects `</dev/null` on the same binaries — the
     watchdog is the sole inconsistent caller. Independent, zero-risk,
     zero-ambiguity fix — do this FIRST regardless of anything else.
   - `codex-safe.sh` already has a fully-built `--heartbeat-file` mechanism
     (lines ~155-180) that `agent-runtime.sh` never wires up — flagged as
     tempting-but-wrong: turning it on unconditionally makes `progressed()`
     always-true, which disables stall detection entirely (this is the
     exact mistake the legacy `codex-watchdog.sh:141` made). Do not revive
     this.

## Still open / not done this session

- **Neither #142 nor #144 has a single line of code or docs written yet.**
  This entire session was research + design + adversarial review + issue
  documentation. Next session starts at implementation.
- **The design's exact shape is sketched, not finalized**: extend
  `lib/runtime-registry.cjs` (already merged, already has the
  `RUNTIMES`/`BIN`/`PROBE`/`STASH_BY`/`MODEL_FAMILY_REGEX`/`EFFORT_ENUMS`
  declarative-table pattern) with a new `PROGRESS` table, one entry per
  runtime, holding the streaming flag(s), event format, and how to extract
  the final result text from the event stream — so `agent-watchdog.sh`/
  `agent-runtime.sh` query the registry instead of hardcoding a per-runtime
  case branch, matching this file's existing extensibility precedent. Exact
  field names/shape not committed to code, and codex's/opencode's precise
  event-schema fields for "this is the final result" are only half-verified
  (opencode: `text` event's `part.text` field, verified; codex: unknown,
  blocked on quota reset).
- `conductor-control-publish.sh:52`'s `JSON.parse($OUTPUT)` will break if
  claude's conductor role switches to `stream-json` output without also
  routing through the same final-event-extraction step — flagged by the
  glm-5.3 review, not yet addressed in any code.
- codex's own `.review/`-prune blindness to its own `--output-last-message`
  output path (a `.review`-internal file) was flagged by the glm-5.3 review
  as a possible additional codex-specific wrinkle on top of the general
  fix — not verified, not scoped.
- Whether to actually register `gemini`/`amp`/`grok` as 4th/5th/6th runtimes
  in `RUNTIMES` is **explicitly out of scope** — this session's
  multi-runtime check was to prove the design must generalize, not a
  decision to add them now.
- **Tier 2/3 work (#129, #136, #137, #131, #134, #133, #128-Phase-B, #132)
  is still completely blocked behind #142**, per the entry below's own
  gating rule — unchanged, still true, still the reason #142 must land
  first.

## Next session

1. `git fetch --prune` + `git pull`/rebase onto current `origin/main` FIRST
   — this local checkout was confirmed stale this session (missing
   `41650a4..624913d`, i.e. PRs #138-#143). Do not trust any "not merged"
   claim in the historical entries below without re-verifying against
   fetched `origin/main`.
2. Read the full #142 issue comment (link above) — it has the evidence
   table, the exact rejected-candidate reasoning, and ready-to-run repro
   commands for the still-unverified runtimes (codex post-quota-reset,
   opencode with a genuine multi-step prompt).
3. Do **#144 first** (5-minute pure-docs change, zero risk, exact insertion
   points already identified above) — good warm-up, unblocks nothing but
   costs nothing either.
4. Implement #142 in this order, per the issue comment's own sequencing:
   a. `agent-watchdog.sh:83` — add `</dev/null`. Independent, do this even
      if nothing else lands this session.
   b. `lib/runtime-registry.cjs` — add the `PROGRESS` table + a new CLI
      accessor (matching the existing `bin`/`probe-help-tokens`/etc.
      subcommand pattern).
   c. claude only, first (the only runtime with high-resolution empirical
      confirmation): `agent-runtime.sh`'s claude branch gets the streaming
      flags, `agent-watchdog.sh`'s `progressed()` gets an `$OUTPUT`
      mtime-OR clause, `transcribe_review()` gets an NDJSON
      final-result-event extraction step (feeding into the existing
      fenced-```json fallback unchanged), `conductor-control-publish.sh`
      gets the same extraction wired in front of its `JSON.parse`.
   d. opencode next — re-verify with a genuine multi-step/multi-tool-call
      prompt (not the single-shot "count to 20" test used this session)
      before trusting its coarse-grained signal is sufficient in practice.
   e. codex — **blocked until 2026-08-20 quota reset**; use Option D
      (wall-clock cap only) as a temporary codex-specific fallback if #142
      needs to land before that date, but do not generalize Option D to
      the other two runtimes now that they have real fixes.
5. Add smoke coverage: a fixture proving a genuinely-hung read-mode process
   still gets killed (event stream never advances) alongside one proving a
   genuinely-working one doesn't (event stream keeps advancing, no file
   writes needed).
6. Only after #142 is merged, resume Tier 2 per the entry below's own
   "Next session" section (dispatch #129/#137/#131, write #136 inline).
7. Preserve the same protected untracked paths listed in every prior entry
   below (unchanged this session): `.agents/skills/meta-prompt`,
   `.claude/`, `.opencode/`, `.review/ISSUE-70-launch.*`,
   `.review/ISSUE-71-launch.*`, `.review/open-issues-dag-2026-08-02.md`,
   `.review/open-issues-dag-2026-08-14.md`, `.review/open-issues-dag-2026-08-15.md`,
   `HANDOFF.md`, `docs/research/2026-07-27-external-model-scorecard-sources.md`,
   `docs/research/2026-08-15-full-feature-catalog.md`,
   `docs/plans/2026-08-15-feature-abstraction-two-axis-design.md`,
   `.review/DESIGN-REVIEW-two-axis-PROMPT*.md`.

---

# Historical continuation — Tier 0+1 merged, MUST fix #142 (broken review-dispatch mechanism) before resuming Tier 2 (2026-08-16)

This entry is now historical, superseded by the entry above (#142 root
cause found, design confirmed via 2 adversarial subagent reviews, not yet
implemented). Its background/context (Tier 0+1 merge details, #144's origin
story) is still accurate — re-check `git status --short --branch`, `git log
-5 --oneline --decorate`, `git fetch --prune`, `gh issue list --state open
--limit 100`, `git worktree list` before trusting anything below — this
entry is a snapshot.

This is the authoritative continuation entry, superseding the one below it
(the "DAG execution started" entry — now historical, its Tier 0/1 work is
merged). Re-check `git status --short --branch`, `git log -5 --oneline
--decorate`, `git fetch --prune`, `gh issue list --state open --limit 100`,
`git worktree list` before trusting anything below — this entry is a
snapshot.

## READ THIS FIRST — do not resume the DAG (Tier 2) before doing this

The user was genuinely angry by the end of this session about two things,
both now written to memory — **read [[feedback-toolkit-defect-not-my-mistake]]
and [[feedback-trivial-no-full-suite]] before touching anything**:

1. This session (and at least 2-3 prior sessions per HANDOFF history) hit
   the exact same Opus/reviewer-dispatch failure shape (stall or fast
   nonzero-exit refusal) repeatedly, and every time it was diagnosed as
   "my own prompt/flag mistake, let me retry with bigger timeouts" instead
   of reading the actual watchdog source. **The real root cause was finally
   found this session**: `agent-watchdog.sh:19`'s `progressed()` explicitly
   `-prune`s `.review/` from its file-mtime progress check, but a
   `--produce-review` reviewer role by contract never writes outside
   `.review/` — so a read-only reviewer dispatch is **structurally
   guaranteed** to hit `--stall-timeout` no matter how high it's set. Filed
   as **issue #142** with full repro, root cause, and 3 candidate fix
   directions (not chosen — needs real design work, not a quick patch).
   **User explicitly said: don't quick-patch this in place, don't apply an
   ad-hoc fix without thinking through scope/architecture — the next
   session should properly review #142 (and re-check whether any other
   issue filed this session needs the same rigor) before resuming DAG
   work.**
2. This session ran the full `run-all.sh` (37-smoke suite, several
   minutes) as a verification step for a single-line intermediate fix
   commit, not just at PR time — despite an existing memory
   (`feedback_trivial_no_full_suite`) already saying not to do this for
   trivial-tier work. The user had to correct this a second time, angrily.
   The memory has been rewritten to remove the tier-exception hedge:
   **full suite is ONLY for the one pre-PR/pre-merge gate, full stop, no
   tier exception, ever.**

**Next session's actual first task, before Tier 2**: read issue #142 in
full, think through the fix's correct scope (does it change
`agent-watchdog.sh` generically for all runtimes/roles, or something more
targeted?), get it right, then land it with its own smoke coverage. Only
after that's merged should Tier 2 dispatch begin — and if #142's own fix
touches `dispatch-core.sh`/`agent-watchdog.sh` again, that's more reason
to land it before parallel Tier 2 dispatches start touching the same
admission-path files.

## What happened this session

Continuing from the entry below: Tier 0 (#126, #128 Phase A, #130) was
still un-merged at session start. This session:

1. **Merged Tier 0** — 3 PRs, one per issue (#126→PR #138, #130→PR #139,
   #128 Phase A→PR #140), following the user's explicit choice ("이슈당
   PR 3개") over a single bundled PR. PR #140 (#128) hit a real merge
   conflict against `main` after #126/#130 landed first (both touched
   `admission-recover.cjs`'s now-removed `lock-prepare` dead-code block) —
   resolved by taking `main`'s deletion side, re-verified 37/37, re-pushed,
   merged. All 3 CI-green, merged via `gh pr merge --merge` (plain merge,
   repo convention).
2. **Dispatched Tier 1 in parallel via 2 forks** (per the user's explicit
   ask to "묶어서" / bundle work instead of doing every issue one at a
   time) — #127 (legacy script removal, glm-5.3/low) and #135
   (`lib/runtime-registry.cjs`, glm-5.3/high). Both worktrees pre-created
   and `prepare-worktree.sh`'d before dispatch.
   - **#127**: dispatch itself hit `status: exhausted` after 3 attempts,
     but both real commits (cmux-cluster.sh removal, codex-watchdog.sh
     removal) had already landed cleanly before the exhaustion — the
     3rd attempt was apparently just self-verification/PR-DRAFT-writing
     that ran out of budget, not a real implementation failure. Self-
     verified: `run-all.sh` clean modulo the pre-existing `AC-119-1` flake
     (which cascades into `AC-130-5`'s aggregate check in the same smoke
     file — same flake, not 2 new failures), but
     `release-contract.smoke.sh` found one **real** new failure: a stale
     `compatibilityReferences` exception in
     `.github/tests/release-contract-exceptions.json` pointing at the
     now-deleted `cmux-cluster.smoke.sh`. Fixed directly (removed the
     stale exception entry), re-verified ALL CASES PASS, pushed, PR #141,
     CI green, merged.
   - **#135**: dispatch completed cleanly (7 commits, real PR-DRAFT written,
     `run-all.sh` 37/38 with only the known flake, `release-contract.smoke.sh`
     ALL CASES PASS). This is where the review-dispatch mechanism problem
     (see "READ THIS FIRST" above) ate most of the session's remaining
     time: the `--produce-review`/opus/orca dispatch stalled, was retried
     with bumped timeouts, stalled/refused again with a fast nonzero exit
     (root cause for THAT specific fast-exit variant still not fully
     diagnosed — may or may not be the same root cause as the `progressed()`
     bug, needs re-checking next time it's hit). Per the user's direction,
     **stopped retrying the broken dispatch mechanism and instead spawned
     an independent Opus review directly via the `Agent` tool** (bypassing
     `agent-watchdog.sh`/`dispatch-core.sh` entirely — `subagent_type:
     "general-purpose"`, `model: "opus"`). This worked and found a real
     bug the orchestrator's own manual self-review had missed: removing
     `case`'s `*) false ;;` catch-all in `dispatch-core.sh`'s
     `model_compatibility_preflight` made it fail-**open** for a future
     registered runtime with no matching argv branch (the new
     `is_registered_runtime` guard added in front of it was dead code,
     already refused earlier — it was guarding the wrong direction).
     Fixed directly (restored the catch-all with a comment explaining why),
     re-verified focused smokes clean, then — correctly this time — ran
     the full suite exactly once right before pushing (`run-all.sh` 37/38,
     `release-contract.smoke.sh` ALL CASES PASS), pushed, PR #143, CI
     green, merged.
   - **Note on how the Opus subagent's review was actually retrieved**:
     the spawned Agent-tool subagent (not a fork) reported only repeated
     `idle_notification` teammate messages with no visible reply content,
     even after several `SendMessage` nudges (which the user told me to
     stop sending). The actual completed review was sitting in its full
     transcript file the whole time:
     `~/.claude/projects/<slug>/<session>/subagents/agent-a<name>-<hash>.jsonl`.
     Written to memory as `project_runtime_registry_review_workaround` —
     read that transcript directly next time instead of re-nudging.

## Still open / not done this session

- **Issue #142 is filed but not fixed or even scoped.** This is the
  mandatory first task next session, see "READ THIS FIRST" above.
- **Issue #144 filed** (2026-08-16, right after this entry was first
  written) — the verification-cadence rule (full `run-all.sh` only at the
  PR gate, focused tests otherwise, no tier exception) exists only in
  CONDUCTOR's own session memory right now, not in
  `toolkit/docs/agents/multi-agent-workflow.md` or `AGENTS.md`. The user
  explicitly pushed back on memory-only fixes for anything that's really
  toolkit/process scope ("메모리가 아니라 툴킷에서 보강되도록 이슈로
  올리라니까? 툴킷범위인건") — memory only helps this one Claude session;
  it doesn't help another CONDUCTOR implementation (e.g. opencode) or a
  future session that hasn't accumulated the same memory. **General
  principle for future sessions: when a correction is about repo-wide
  process/convention (not this-session-only tool quirks), file it as a
  toolkit issue to get documented in the actual playbook, not just saved
  to personal memory.** #144 is a small, low-risk pure-docs issue — good
  candidate to pick up early next session, possibly bundled with #142.
- **Tier 2 (#129, #136, #137, #131) not started.** Per the DAG file, these
  4 have no file overlap with each other (all only depend on #135, which
  is now merged) — genuinely parallelizable. #136 is design-only (no code
  diff, per the DAG's own note "not a glm dispatch target; do inline") —
  do NOT dispatch it as a worker task, write it directly. #129/#137/#131
  are real dispatch targets.
- **Tier 3 (#134, #133, #128-Phase-B, #132) entirely unstarted.**
- The #135 Opus review's 1 deferred `fix` (no parity gate between the
  registry's effort enums and 3 non-canonical inline owners:
  `dispatch-core.sh` route-binding heredoc ~line 1012, `lib/route.cjs:59`,
  `lib/admission-recover.cjs:42`) and 3 `nit`s (2 more hardcoded
  "codex, claude, or opencode" human-facing strings in
  `agent-workflow.sh`/`agent-runtime.sh` that slip the containment
  detector's pattern; containment detector is line-based so a hand-split
  multi-line case would bypass it, accepted as designed; `agent-runtime.sh
  capabilities` now hard-requires `node` on PATH) are documented in PR
  #143's body but not filed as follow-up issues or fixed. Consider whether
  any of these are worth a small follow-up issue before Tier 2, or fold
  into Tier 2/3 scope if a touched file overlaps.
- Worktrees left in place, not cleaned up (all have real landed work,
  now merged — safe to remove if disk space matters, not done this
  session):
  `/Users/hyojung/orca/workspaces/feedbackops-workflow/issue-126-dead-code-removal`,
  `/Users/hyojung/orca/workspaces/feedbackops-workflow/issue-127-legacy-executable-removal`,
  `/Users/hyojung/orca/workspaces/feedbackops-workflow/issue-128-atomic-fs`,
  `/Users/hyojung/orca/workspaces/feedbackops-workflow/issue-130-adapter-shared-helpers`,
  `/Users/hyojung/orca/workspaces/feedbackops-workflow/issue-135-runtime-registry`.
  `/Users/hyojung/orca/workspaces/feedbackops-workflow/issue-132-verify-pipeline-unify`
  (still on old `main` HEAD, untouched, safe to reuse when Tier 3 starts —
  should be rebased/recreated against current `main` first since several
  merges have landed since it was created).

## Next session

1. `git status --short --branch`, `git log -5 --oneline --decorate`,
   `git fetch --prune`, `gh issue list --state open --limit 100`,
   `git worktree list` — confirm current state before trusting anything
   above. Expect: `main` past PR #143, issues #126/#127/#128(partial)/#130/
   #135 all merged-and-closeable (check if auto-closed via PR body
   `Closes #N`; #128 was NOT auto-closed since only Phase A landed —
   leave #128 open), #142 open and unfixed, #129/#131/#132/#133/#134/#136/
   #137 open and unstarted.
2. **Fix #142 first** — read it in full, think through the correct scope
   (this touches the shared `agent-watchdog.sh`, used by every
   runtime/adapter/role — a single well-designed fix there is the general
   fix, not a per-adapter patch), get user sign-off on the approach before
   implementing, land it with its own smoke coverage.
3. Only after #142 is merged, resume Tier 2: dispatch #129, #137, #131 in
   parallel (3 forks or equivalent — they don't overlap files with each
   other per the DAG), write #136 (capability-matrix design doc) directly
   inline, not as a dispatch.
4. Then Tier 3 (#134, #133, #128-Phase-B, #132) per the DAG file's tier
   structure.
5. Apply the corrected verification discipline from
   `feedback_trivial_no_full_suite` (now tier-unconditional): focused
   tests for every intermediate commit, full `run-all.sh` +
   `release-contract.smoke.sh` exactly once, right before push/PR, no
   exceptions.
6. If an Opus/reviewer dispatch via `agent-workflow.sh dispatch
   --produce-review` stalls or fails again before #142 is fixed, do NOT
   retry it — go straight to spawning an independent review via the
   `Agent` tool directly (`model: "opus"`), per this session's precedent
   in `project_runtime_registry_review_workaround`.
7. Preserve the same protected untracked paths listed in every prior entry
   below (unchanged this session): `.agents/skills/meta-prompt`,
   `.claude/`, `.opencode/`, `.review/ISSUE-70-launch.*`,
   `.review/ISSUE-71-launch.*`, `.review/open-issues-dag-2026-08-02.md`,
   `.review/open-issues-dag-2026-08-14.md`, `.review/open-issues-dag-2026-08-15.md`,
   `HANDOFF.md`, `docs/research/2026-07-27-external-model-scorecard-sources.md`,
   `docs/research/2026-08-15-full-feature-catalog.md`,
   `docs/plans/2026-08-15-feature-abstraction-two-axis-design.md`,
   `.review/DESIGN-REVIEW-two-axis-PROMPT*.md`.

---

# Historical continuation — DAG execution started, Tier 0 (#126/#128/#130) done not merged, Tier 1 next (2026-08-16)

This entry is now historical, superseded by the entry above (Tier 0+1
merged, #142 filed). Re-check `git status --short --branch`, `git log -5
--oneline --decorate`, `git fetch --prune`, `gh issue list --state open
--limit 100`, and `git worktree list` before trusting anything below —
this entry is a snapshot.

This is the authoritative continuation entry, superseding the one below it.
Re-check `git status --short --branch`, `git log -5 --oneline --decorate`,
`git fetch --prune`, `gh issue list --state open --limit 100`, and
`git worktree list` before trusting anything below — this entry is a
snapshot.

## What happened this session

User asked to read HANDOFF, build a dependency DAG over all open issues
(#126-#137), and self-execute it in an orchestration role: implementation
dispatched to opencode `zai-coding-plan/glm-5.3` (`/low` default, `/high`
for higher-blast-radius nodes), DAG nodes sized to fit one dispatch session
(split internally into phases when too large), diffs >500 lines get a
scoped Opus review (diff + goal only, not full-repo read), and the
orchestrator itself filters out low-difficulty/low-risk diffs from needing
Opus at all.

1. **Wrote `.review/open-issues-dag-2026-08-15.md`** — the DAG for all 12
   open issues (#126-#137), built from file-overlap analysis (grepped every
   issue body for backtick-quoted file paths) plus explicit `blocked-by`
   text in issue bodies. Corrected one misclassification mid-session:
   **#132 was initially placed in Tier 0 as file-isolated — wrong.** Its own
   issue body states an explicit `blocked-by`: #128 (atomic-fs) and #129
   (sameJson) must land first. Moved to Tier 3 before any dispatch touched
   it. Read the DAG file itself for the full tier structure; summary:
   - Tier 0 (no deps): #126, #128, #130, #132 (#132 later corrected out)
   - Tier 1: #127 (needs #126), #135 (needs #126)
   - Tier 2: #129, #136, #137, #131 (all need #135)
   - Tier 3: #134 (needs #137), #133 (needs #131,#127), #132 (needs #128,#129)
2. **Resolved #127's decision gate via AskUserQuestion**: both
   `cmux-cluster.sh` and `codex-watchdog.sh` → **deprecate/remove** (not
   migrate/keep). This simplifies #133's later watchdog-consolidation scope
   (no legacy codex-watchdog compat path to preserve) and turns #127 from a
   decision-only node into a normal implementation dispatch.
3. **Executed Tier 0** (#126, #128, #130 — #132 excluded per the correction
   above), each in its own `git worktree` under
   `/Users/hyojung/orca/workspaces/feedbackops-workflow/issue-<N>-<slug>/`,
   dispatched via `toolkit/scripts/agent-workflow.sh dispatch --orchestrator
   orca --runtime opencode --role implementation`. All three needed
   iteration before a clean run — see each item below. **None of the three
   are pushed, PR'd, or merged** — all work is local-only in worktree
   branches, one commit-chain each.

   - **#126** (glm-5.3/low, dead-code removal, 85-line diff) — clean 1-shot
     dispatch, 5 commits. Orchestrator self-reviewed directly (no Opus
     dispatch — low-risk, low-diff per the DAG's own filter rule): clean,
     no findings. Worktree `issue-126-dead-code-removal`, branch
     `fix/issue-126-dead-code-removal`, HEAD `9a0c16d`. `run-all.sh` clean.
   - **#130** (glm-5.3/low, shared adapter helpers, ~439-line diff) —
     dispatch admission itself needed 3 fix cycles first (missing
     `--round-state`/`--manifest-revision` for `standard` tier; missing
     `pr_draft`+`review` artifact pointers; `new_file_allowlist` needed for
     genuinely-new files under a glob `touch_allowlist`) — these are
     dispatch-mechanics gaps in how the orchestrator authored the
     ROUND-STATE, not product bugs; worth remembering the exact fix shapes
     if dispatching `standard`-tier work again. The dispatch itself then
     ran clean but its own self-verification found a real regression:
     `cmux-dispatch.smoke.sh` went 63 failures — new shared libs
     (`semver.cjs`/`adapter-json.cjs`/`adapter-helpers.sh`) were not copied
     into the smoke's isolated fixture tree, same defect class as the
     historical #115 `transport-registry.cjs` fixture-copy bug. Orchestrator
     fixed the fixture directly (added the 3 missing `cp` lines), confirmed
     0 failures, committed. Then dispatched an **Opus scoped review**
     (diff was under the 500-line auto-gate but escalated anyway per the
     DAG's own "escalate if uncertain" clause, since the diff touches
     `capability-result.cjs`, the dispatch-admission validator) — returned
     **status: fail**: 1 `block` (`help_has` called with a stray `--` as
     its own second argument in `cmux.sh`, so the launch-flag capability
     probe matched the literal string `--` instead of `--cwd`/`--command`
     — **any `workspace create --help` output with any flag at all now
     passed capability admission**, a #112-class false-green risk that
     would let a cmux binary lacking `--cwd`/`--command` reach real
     dispatch and fail after marker consumption), 1 `fix` (cmux's emitted
     provenance `version` field silently changed from the raw
     `cmux --version` string to a normalized semver, breaking the issue's
     own byte-compatible-behavior requirement), 3 `nit`s. Orchestrator
     applied the block+fix patch instructions directly (mechanical, fully
     specified by the review), added a regression fixture (AC-130-6, a
     flagless-help negative case) proving the fix, closed 1 of 3 nits
     (destructured a CLI arg-reuse footgun in `adapter-json.cjs`), left 2
     nits (semver accept-set widening doc, herdr's dead unavailable-branch
     version param) — both cosmetic/documentation-only, deliberately
     deferred. Worktree `issue-130-adapter-shared-helpers`, branch
     `refactor/issue-130-adapter-shared-helpers`, HEAD `0795f51`.
     `run-all.sh` 36/36.
   - **#128** (glm-5.3/high, `lib/atomic-fs.cjs` extraction) — **revision 1
     (full unsplit scope) exhausted 3 attempts with zero code written** —
     each attempt spent its entire time budget reading the 6 target files
     before writing anything, never reached a PR-DRAFT. Orchestrator split
     it into **Phase A** (lib creation + the 4 admission-side call sites:
     `admission-recover.cjs`/`admission-advance.cjs`/`blocker-recovery.cjs`/
     `review-publish.cjs`) and **Phase B** (the 4 verify-side call sites:
     `verify-result.cjs`/`target-verify.mjs`/`review-capsule.mjs`/
     `review-snapshot.cjs` — **not started, still open**, see Tier 3 below),
     bumped dispatch timeouts to 900s, and re-dispatched Phase A as
     ROUND-STATE revision 2 (had to also clear a stale
     `.write-dispatch-issue-128-started` marker dir left by the exhausted
     revision-1 attempts, which was tripping the redispatch-circuit-breaker
     gate on the fresh revision). Phase A then succeeded cleanly, 3 commits.
     Opus scoped review (410-line diff, high-risk primitive-extraction
     touching on-disk write/lock semantics) returned **status: pass**, 3
     `nit`s (temp-file-cleanup-ownership doc gap, one racy pid-reuse test
     assertion, alphabetical manifest ordering) — orchestrator closed all 3
     directly. Worktree `issue-128-atomic-fs`, branch
     `refactor/issue-128-atomic-fs`, HEAD `5e828bc`. `run-all.sh` 36/37 (see
     flake note below).
4. **Confirmed a recurring pre-existing flake, not a regression**: both
   #130's and #128's `run-all.sh` runs showed exactly one failure,
   `AC-119-1 AGENT_WORKFLOW_POLL_INTERVAL alone sets the poll interval`,
   inside `orchestrator-interface.smoke.sh` — this is the same hardcoded-2s-
   timeout flake already documented in the historical HANDOFF entry below
   (PR #124 era). Standalone reruns of just that file passed 2/2 in both
   worktrees. Not fixed here (pre-existing, unrelated to any file either
   diff touches, out of scope for both issues).

## Operational finding worth flagging for future dispatch sessions

**The `agent-workflow.sh dispatch` wrapper's own bash process repeatedly
returned/exited (visible to the orchestrator's `run_in_background` tool as
"completed") only seconds after a successful launch, while the actual
worker process was still alive and running** (confirmed via `ps` showing a
live `opencode`/`claude` process, plus the worktree's `ISSUE-<N>-RUN.json`
still reading `"status": "running"` with a real PID) — inconsistent with
earlier sessions in this same HANDOFF history where the identical dispatch
command blocked in-process until real completion (`status: "exited"` with
an `exit_code`). This happened on at least 4 separate dispatch calls this
session (once for #128 Phase A's implementation dispatch, once for #128's
review dispatch, once for #130's review dispatch, and implicitly on early
#128/#130 attempts before the ROUND-STATE fixes). **Workaround used every
time**: after a dispatch call's background notification fires, do not trust
it — follow up with a second `run_in_background` command that does
`until grep -q '"status": "exited"\|"status": "exhausted"'
".../ISSUE-<N>-RUN.json"; do sleep 15; done` and wait for THAT
notification instead. Root cause not diagnosed this session (candidate
causes not investigated: orca terminal detach behavior, a change in
`agent-watchdog.sh`'s own polling model, or a harness-side quirk in how
this session's `run_in_background` handles a long-blocking foreground
child) — worth filing as an issue if it keeps recurring, since it silently
breaks the "trust the completion notification" assumption most of this
project's own dispatch tooling and prior HANDOFF entries relied on.

## Still open / not done this session

- **None of #126/#128(Phase A)/#130 are pushed, PR'd, or merged.** All three
  are local-only worktree branches with clean commit chains and passing
  `run-all.sh`. Next session must decide push/PR/merge strategy (one PR
  each, matching the #111-#120 per-issue-branch convention, or bundle —
  not decided this session).
- **#128 Phase B is unstarted** — verify-side migration
  (`verify-result.cjs`/`target-verify.mjs`/`review-capsule.mjs`/
  `review-snapshot.cjs`) into the now-landed `lib/atomic-fs.cjs`. This was
  explicitly deferred to Tier 3 by the DAG (after #129 lands, since #132
  also depends on both #128 and #129).
- **Tier 1 (#127, #135) not started.** Both are unblocked (only need #126,
  which is done in its own worktree — but since #126 isn't merged to
  `main` yet, Tier 1 dispatches should probably branch from #126's worktree
  HEAD `9a0c16d` or wait for a merge decision; not resolved this session).
- **Tiers 2 and 3 (#129, #131, #133, #134, #136, #137, #132) entirely
  unstarted.**
- The DAG file itself (`.review/open-issues-dag-2026-08-15.md`) is
  up to date through the end of Tier 0 — re-read it before resuming, it has
  the full edge rationale and the corrected #132 placement.
- Worktrees left in place, not cleaned up (all have real uncommitted
  progress, do not remove):
  `/Users/hyojung/orca/workspaces/feedbackops-workflow/issue-126-dead-code-removal`,
  `/Users/hyojung/orca/workspaces/feedbackops-workflow/issue-128-atomic-fs`,
  `/Users/hyojung/orca/workspaces/feedbackops-workflow/issue-130-adapter-shared-helpers`,
  `/Users/hyojung/orca/workspaces/feedbackops-workflow/issue-132-verify-pipeline-unify`
  (this last one was pre-created for Tier 0 before the #132 correction —
  still on `main` HEAD `1fa4405`, no work done in it yet, safe to reuse when
  Tier 3 starts).

## Next session

1. `git status --short --branch`, `git log -5 --oneline --decorate`,
   `git fetch --prune`, `gh issue list --state open --limit 100`,
   `git worktree list` — confirm current state before trusting anything
   above.
2. Decide push/PR/merge strategy for #126, #128 (Phase A only — do not
   merge Phase B doesn't exist yet), #130 — likely one PR per issue,
   matching the #111-#120 convention, each independently reviewable since
   their diffs don't overlap.
3. Resume the DAG at Tier 1: dispatch #127 (cmux-cluster.sh +
   codex-watchdog.sh removal — decision already made this session, both
   deprecate/remove) and #135 (`lib/runtime-registry.cjs`, the
   capability-matrix prerequisite) — both only need #126.
4. Then Tier 2 (#129, #136, #137, #131 — all need #135), then Tier 3
   (#134, #133, #128-Phase-B, #132) per the DAG file's tier structure.
5. Keep using the model-routing and review-gate rules from this session:
   glm-5.3/low default, /high for high-blast-radius nodes (see the DAG
   file's own routing table), Opus scoped review for >500-line diffs or
   any diff touching dispatch-admission-path files regardless of size,
   orchestrator self-review for small/low-risk diffs.
6. Apply the RUN.json-watch workaround from this session's "Operational
   finding" section above for every dispatch call — do not trust a bare
   "completed" notification on the dispatch command itself.
7. Preserve the same protected untracked paths listed in every prior entry
   below (unchanged this session): `.agents/skills/meta-prompt`,
   `.claude/`, `.opencode/`, `.review/ISSUE-70-launch.*`,
   `.review/ISSUE-71-launch.*`, `.review/open-issues-dag-2026-08-02.md`,
   `.review/open-issues-dag-2026-08-14.md`, `HANDOFF.md`,
   `docs/research/2026-07-27-external-model-scorecard-sources.md`,
   `docs/research/2026-08-15-full-feature-catalog.md`,
   `docs/plans/2026-08-15-feature-abstraction-two-axis-design.md`,
   `.review/DESIGN-REVIEW-two-axis-PROMPT*.md`. **New this session, also
   untracked/not yet committed**: `.review/open-issues-dag-2026-08-15.md`.

---

# Historical continuation — #135/#136/#137 filed, two-axis design reviewed, matrix design is next (2026-08-15)

This entry is now historical, superseded by the entry above (DAG execution
started). Re-check `git status --short --branch`, `git log -5 --oneline
--decorate`, `git fetch --prune`, `gh issue list --state open --limit 100`
before trusting anything below — this entry is a snapshot.

## What happened this session

User asked for a judgment pass over the newly-filed refactor issues
(#126-#134, filed same-day but not in the prior HANDOFF entry) against their
actual goal: feature-first abstraction (per-function capability matrix
across adapters), not just code dedup. Then asked to design the missing
scope and get it independently reviewed.

1. **Judged #126-#134**: all are transport-axis (cmux/orca/herdr) DRY
   refactors, not the feature-capability-matrix deliverable the user
   actually wants (recorded prior session as
   `project_adapter_capability_layering_idea` in memory, still the real
   next-session objective per every HANDOFF entry below this one).
2. **Found an unowned gap**: #131 §4 and #133 §2/§4 each independently
   flagged the same defect (runtime name `codex|claude|opencode`
   hardcoded 3x+, `agent-runtime.sh` double-encoding probe/exec) and both
   said "coordinate, don't duplicate" — but neither issue actually owns it.
   Named this the **runtime axis** (which model publisher runs), distinct
   from the **transport axis** (cmux/orca/herdr/native — where it runs) that
   #130/#131 already address. This distinction is the real missing scope.
3. **Wrote `docs/plans/2026-08-15-feature-abstraction-two-axis-design.md`**
   (not yet committed) proposing: extract `lib/runtime-registry.cjs` as the
   runtime-axis twin of `transport-registry.cjs`, closing the orphan;
   sequence it before the still-undesigned capability matrix (which needs
   both registries as its data source); re-scope #131 item 4 and part of
   #133 into the new extraction rather than fixing them in place (matches
   the project's own precedent lesson that pre-matrix work risks rework).
4. **Got it independently reviewed** — `zai-coding-plan/glm-5.3`/`high` via
   `agent-workflow.sh dispatch --orchestrator orca --runtime opencode`, in a
   fresh worktree (`/Users/hyojung/orca/workspaces/feedbackops-workflow/design-review-two-axis`,
   branch `docs/feature-abstraction-two-axis-design`, HEAD `0265fcc`).
   **Two dispatch attempts failed before a usable review was obtained** —
   both are this session's own operator error, not project defects, and are
   the direct ancestor of issue #137 below:
   - Attempt 1 (`--role architect --read-only`) exited 0 but the response
     was never persisted anywhere retrievable — `agent-watchdog.sh` only
     copies output to disk on the `--produce-review` or
     `--conductor-control` paths; plain read-only roles (architect/
     verifier/visual/release) have no output-persistence path at all when
     dispatched externally. Wasted, but harmless (no data lost, just a
     dispatch cycle).
   - Attempt 2 (`--role reviewer --produce-review`) got a real, substantive
     review back (`.review/ISSUE-9998-review-attempt1-output.log`) but
     **canonical publish was refused** (`refusal_reason: head_mismatch`) —
     `schemas/review.schema.json` requires an exact `reviewed_head_sha`
     match, but the opencode read-permission file
     (`toolkit/scripts/runtime-permissions/opencode-read.json`) sets
     `"bash": "deny"`, so the reviewer had no way to compute the real HEAD
     itself and returned a placeholder. This is filed as **issue #137** —
     a real, reproducible host-side gap (nothing in dispatch-core/
     agent-watchdog injects the launch-time-known HEAD sha into the
     prompt for bash-denied review dispatches), not a one-off mistake.
   - The review content itself survived in the transcript log regardless of
     the publish refusal, and was fully usable — 4 `fix` findings, all
     confirmed against actual source (`agent-watchdog.sh` genuinely branches
     on `RUNTIME=codex` with zero adapter references, confirming the
     runtime-axis-leakage claim), 2 `nit`s, and direct answers to the
     design doc's own §5 open questions.
5. **Incorporated all 4 fix findings + 2 nits into the design doc**
   (`docs/plans/2026-08-15-feature-abstraction-two-axis-design.md`, now has
   a new §3.1 "Review disposition" section and edited §3 sequencing): widen
   the runtime-registry issue's scope (review found 2 more enforcement sites
   the original write-up missed: `dispatch-core.sh:344`, `route.sh:28`,
   `dispatch-core.sh:694-698`), add a containment smoke-test requirement
   (false-green prevention, same class PR #124's review found once already),
   record model-family (`gpt-5.6`-style effort-enum branching,
   `dispatch-core.sh:603,625`) as a declared sub-dimension of the runtime
   axis rather than a missed 3rd axis, and correct #129's "fully orthogonal"
   claim (`agent-runtime.sh:36-55` is runtime-axis code in a file the
   registry migration rewrites).
6. **Filed 3 new issues + 3 cross-reference comments**, all with full
   background/reasoning/verification sections in this repo's established
   issue style (matching #126-#134's own format), per the user's explicit
   request not to lose context:
   - **#135** — `lib/runtime-registry.cjs` extraction, widened scope, the
     actual orphan-closing issue. Owns #131 item 4 and #133 §2/§4.
   - **#136** — the capability matrix design itself (functional unit ×
     transport × runtime), the real still-undesigned next-session
     deliverable. Explicitly depends on #135.
   - **#137** — the head_mismatch/bash-deny host gap found this session
     (see point 4 above), with two concrete fix options (auto-inject the
     known HEAD into the prompt, or host-side overwrite-then-validate
     instead of trusting the model's self-reported value).
   - Comments on **#131** (item 4 moved to #135), **#133** (§2 moved to
     #135, §1 deferred until #136's matrix defines the completion-signal/
     liveness row), **#129** (the `agent-runtime.sh`-touching part deferred
     until #135 lands, rest unaffected).

## Still open / not done this session

- **The capability matrix itself (#136) is still not designed** — this
  session produced its prerequisite (#135) and filed the matrix as an
  explicit issue, but did not draw it. This is unchanged from every prior
  HANDOFF entry's "next session" objective — still not done.
- `docs/plans/2026-08-15-feature-abstraction-two-axis-design.md` is
  **not committed** (untracked in the main repo working tree; a copy was
  committed at `0265fcc` in the throwaway review worktree only, for the
  reviewer's benefit).
- The review worktree (`/Users/hyojung/orca/workspaces/feedbackops-workflow/design-review-two-axis`,
  branch `docs/feature-abstraction-two-axis-design`) still exists, not
  cleaned up. Its branch/commit are not pushed or PR'd — it was purely a
  review-dispatch scratch worktree. Safe to remove once the design doc is
  committed to the main repo through normal means (it doesn't need to be
  merged from there — the content is identical to the main repo's untracked
  copy, now further edited past what's in the worktree).
- `.review/ISSUE-9998-*` (RUN.json, TRANSPORT.json, launch dir,
  review-attempt1-output.log, DESIGN-REVIEW-two-axis-PROMPT*.md) are
  scratch dispatch artifacts from this session's review dispatch, both in
  the main repo (`.review/DESIGN-REVIEW-two-axis-PROMPT*.md`, untracked) and
  in the review worktree. Not cleaned up. Harmless to leave or remove.
- Issue #123-adjacent worktrees and other older worktrees listed by
  `git worktree list` (issue-77, issue-78, issue-80, issue-81, issue-82,
  issue-83, issue-123, generic-conductor-persona, feedbackops-workflow-issue-76)
  are untouched leftovers from prior sessions, not touched this session,
  not evaluated for cleanup-safety here.
- `docs/plans/2026-08-15-conductor-native-subagent-dispatch-design.md`
  (drafted 2026-08-15, committed at `a21d2cd` on the current branch
  `docs/conductor-native-subagent-dispatch-design`) is **still unreviewed
  and unimplemented** — unchanged from every prior entry. #136's matrix is
  explicitly supposed to inform a revision of this doc once drawn (native
  dispatch as a 4th transport row with a runtime-eligibility constraint,
  per this session's review finding).

## Next session

1. `git status --short --branch`, `git log -5 --oneline --decorate`,
   `git fetch --prune`, `gh issue list --state open --limit 100` — confirm
   current state before trusting anything above. Expect: 3 new open issues
   (#135, #136, #137) plus #126-#134 all still open, comments on #131/#133/
   #129 referencing #135/#136.
2. Decide whether/how to commit `docs/plans/2026-08-15-feature-abstraction-two-axis-design.md`
   to the main repo (currently untracked there) — likely alongside whichever
   PR eventually implements #135, or standalone now. Not decided this
   session.
3. **Start with #135** (`lib/runtime-registry.cjs`) — it's the prerequisite
   for #136 (the matrix) and for re-closing #131/#133's deferred items.
   Read the issue body in full; it has the widened scope (4 enforcement
   sites, not the original 1) and the containment-smoke-test requirement
   from the review baked in.
4. After #135 lands, **do #136** (capability matrix design) — this is the
   actual multi-session-deferred deliverable. Only after the matrix exists
   should #133 §1 and #132 be implemented, per #135/#136's own stated
   sequencing.
5. #137 (head_mismatch/produce-review host gap) is independent of the
   #135→#136 chain and can be picked up whenever convenient — it will keep
   recurring on any future bash-denied `--produce-review` dispatch (e.g. any
   future opencode reviewer role) until fixed.
6. Clean up the review scratch worktree
   (`/Users/hyojung/orca/workspaces/feedbackops-workflow/design-review-two-axis`)
   once its content is confirmed no longer needed (design doc content now
   lives, edited further, in the main repo's untracked copy).
7. Preserve the same protected untracked paths listed in every prior entry
   below (unchanged this session, with 3 additions): `.agents/skills/meta-prompt`,
   `.claude/`, `.opencode/`, `.review/ISSUE-70-launch.*`,
   `.review/ISSUE-71-launch.*`, `.review/open-issues-dag-2026-08-02.md`,
   `.review/open-issues-dag-2026-08-14.md`, `HANDOFF.md`,
   `docs/research/2026-07-27-external-model-scorecard-sources.md`,
   `docs/research/2026-08-15-full-feature-catalog.md` (tracked-eligible,
   still not committed). **New this session, also untracked/not yet
   committed**: `docs/plans/2026-08-15-feature-abstraction-two-axis-design.md`,
   `.review/DESIGN-REVIEW-two-axis-PROMPT.md`,
   `.review/DESIGN-REVIEW-two-axis-PROMPT-v2.md`,
   `.review/DESIGN-REVIEW-two-axis-PROMPT-final.md`.

---

# Historical continuation — full feature catalog written, adapter-capability-layering design still next (2026-08-15)

This entry is now historical: the "next session" objective below (design the
adapter-capability-layering matrix) is now tracked as filed issue #136, with
its prerequisite (#135) also filed. See the entry above for current state.

## What happened this session

User asked for a full feature inventory of the repo before continuing the
adapter-capability-layering design work: "핸드오프읽고 먼저 전체 기능들을
탐색해서 나열하자... 클러스터 별로 glm 5.3 low를 보내 내가 말한 리스트
작성해서 보고하자." Confirmed via AskUserQuestion that "GLM" here meant a
cheap/low-effort dispatch mechanism in spirit, not a literal opencode/GLM
API call — user picked the lightweight-subagent option over a real
`agent-workflow.sh dispatch` (which would have created worktrees).

1. Read this HANDOFF.md and did a structural (not full-content) survey of
   `toolkit/scripts/`, `toolkit/schemas/`, `toolkit/docs/agents/`,
   `docs/plans/`, `docs/research/` to cluster the repo into 13 purpose-based
   groups (adapters, dispatch/orchestration, admission/blocker, review
   pipeline, verify/testing, telemetry/watchdog, worktree mgmt,
   output-contract infra, schemas, docs/personas, design plans, research
   docs, test suite).
2. Launched 13 parallel Haiku subagents (Agent tool, `model: "haiku"`),
   one per cluster, each told to read its assigned files in full and
   produce an exhaustive Korean-language feature inventory (every
   subcommand/exported function, validation logic, schema fields).
3. Synthesized all 13 results into one consolidated document and wrote it
   to **`docs/research/2026-08-15-full-feature-catalog.md`** (moved from a
   session scratchpad per the user's explicit request — "repo안으로 옮기고
   위 내관점들도 핸드오프에적어둬 다음세션에 이어하자"). This is now a
   tracked, committable file (not yet committed — no commit was requested
   this session).

## What this catalog covers (quick pointer, full detail in the file itself)

- §1 Adapters: cmux/orca/herdr — capabilities/launch/inspect contracts
- §2 Dispatch/orchestration core: dispatch-core.sh (~1350 lines, 60+ flags),
  agent-workflow.sh, route.cjs/route-policy.cjs, model-alloc.sh,
  parallel-plan.cjs/.sh, cmux-dispatch.sh, cmux-cluster.sh
- §3 Admission/blocker/recovery: admission-advance.cjs, admission-recover.cjs
  (lock/journal/recover), blocker-check.cjs, blocker-recovery.cjs,
  redispatch-check.sh (the most complex single gate — 3-redispatch circuit
  breaker), rebase-inflight.sh
- §4 Review pipeline: review-archive/capsule/publish/snapshot,
  pr-draft-check.cjs, candidate-close/integrate (parallel candidate
  closure)
- §5 Verify/testing: verify.sh, target-verify.mjs, prepare-verify-db.sh,
  ac-check.sh, prompt-ac-check.sh, tier-probe.sh, completion-check.sh,
  verify-artifact.cjs/verify-result.cjs
- §6 Telemetry/watchdog: telemetry.mjs (collect/report/delete),
  agent-watchdog.sh, codex-watchdog.sh, agent-runtime.sh, codex-safe.sh
- §7 Worktree/workflow mgmt: prepare-worktree.sh, workflow-stash.sh,
  install-into.sh, conductor-rebuild.sh, conductor-control-publish.sh
- §8 Output-contract/schema infra: output-contract.mjs,
  json-schema-subset.cjs, touch-allowlist-preflight.cjs,
  worktree-content-id.cjs, cmux-handles.cjs, transport-registry.cjs,
  capability-result.cjs, rfc3339.cjs
- §9 Schemas: all 22 `toolkit/schemas/*.json` files, one-line purpose +
  required fields each
- §10 Docs/personas: conductor-persona.md, multi-agent-workflow.md,
  artifact-lifecycle.md, issue-reporting.md, visual-reviewer-persona.md,
  AGENTS.md — rule-by-rule
- §11 Design plans: all 7 `docs/plans/*.md`, each with status + key
  decisions (all still Draft; native-subagent-dispatch design confirmed
  still unreviewed/unimplemented, matching the entry below)
- §12 Research docs: the 3 `docs/research/*.md` + 3 `docs/agents/*.md`
- §13 Test suite: all 36 `toolkit/scripts/__tests__/*.smoke.sh`, one line
  each on what it verifies, plus run-all.sh's own discovery/aggregation
  mechanics
- Closing section: 7 cross-cutting design principles observed across the
  whole codebase (Bash 3.2 compat, disk-is-truth, atomic state transitions,
  deterministic selection, freshness tracking via mtime+head_sha, fail-closed,
  strict role separation)

## Still open / not done this session

- The catalog is informational/reference only — no code was written or
  changed toward the adapter-capability-layering design itself.
- The catalog file is **not committed**. `git status` will show it as an
  untracked-but-now-in-repo new file under `docs/research/`. Decide at
  start of next session whether to commit it standalone or fold it into
  whatever commit eventually lands the capability-layering design work.
- The catalog was generated by Haiku subagents reading files once on
  2026-08-15 — it will drift as the repo changes. Treat it as a snapshot,
  not a live index; re-verify specifics (exact flag names, function
  signatures) against current source before relying on it for
  implementation decisions, per this project's own "memory before
  recommending" discipline.

## Next session

**The actual next objective is unchanged from the entry below**: design the
adapter-capability-layering matrix per the user's explicit sequencing
request from the prior session (`project_adapter_capability_layering_idea`
in memory). This session's feature catalog is prep/context for that work,
not a replacement for it — in particular §1 (Adapters) and §2 (Dispatch
core) of the new catalog file are the most directly relevant sections to
re-read before starting the matrix design, since the matrix's whole point
is mapping adapter-native capabilities (launch/inspect/completion-signal/
terminal-read/blocking-wait/artifact-retrieval/teardown) across
cmux/orca/herdr and deciding where native CONDUCTOR-side `Agent`-tool
dispatch fits as a 4th row.

1. `git status --short --branch`, `git log -5 --oneline --decorate`,
   `git fetch --prune`, `gh issue list --state open --limit 100` — confirm
   current state before trusting anything above.
2. Decide whether to commit `docs/research/2026-08-15-full-feature-catalog.md`
   now or hold it for the capability-layering design's eventual commit.
3. Proceed with the adapter-capability-layering matrix design exactly as
   specified in the "Next session" section of the entry immediately below
   (item 2 there) — that guidance is still current and unexecuted.
4. Preserve the same protected untracked paths listed in every prior entry
   below (unchanged this session): `.agents/skills/meta-prompt`,
   `.claude/`, `.opencode/`, `.review/ISSUE-70-launch.*`,
   `.review/ISSUE-71-launch.*`, `.review/open-issues-dag-2026-08-02.md`,
   `.review/open-issues-dag-2026-08-14.md`, `HANDOFF.md`,
   `docs/research/2026-07-27-external-model-scorecard-sources.md`. Note:
   `docs/research/2026-08-15-full-feature-catalog.md` is a NEW tracked-eligible
   file under `docs/research/` (not in the protected-untracked list — it's
   meant to become a normal repo file, just not yet committed).

---

# Historical continuation — #111-#123 all closed, adapter-capability-layering design is next (2026-08-15)

This is the authoritative continuation entry, superseding the one below it.

## What happened this session

1. **Closed out #111-#120** (already merged via PR #124 per the entry below)
   with a completion comment on each pointing at merge commit `1fa4405` and
   the individual per-issue commits.
2. **Implemented, merged, and closed issue #123** (`run-all.sh` not isolating
   child smoke stdin from its own process-substitution inventory pipe — see
   the historical entry below for the original defect writeup). Dispatched
   to opencode `zai-coding-plan/glm-5.3`/`low`/trivial in worktree
   `/Users/hyojung/orca/workspaces/feedbackops-workflow/issue-123-runall-stdin-isolation`
   (branch `fix/issue-123-runall-stdin-isolation`). The dispatch itself
   never reached a clean exit — it retried 3x and ended `status: exhausted`,
   almost certainly because running the full 36-smoke `run-all.sh` as its
   own self-verification step exceeded the dispatch's internal
   `poll-timeout` each attempt — but its `PARTIAL.diff`/`PARTIAL-UNTRACKED`
   recovery capture had the correct, complete fix + a regression fixture
   (`AC-STDIN-1` in `run-all-contract.test.sh`) already written. Verified
   independently (`bash -n`, the contract test, and the full offline suite
   36/36 twice) and committed directly rather than re-dispatching. Pushed,
   opened PR #125, both `smoke` CI jobs passed, merged
   (`22cd3915cd3921e7d54c3e79be15e1f3597fce59`) — issue #123 auto-closed via
   the PR body's `Closes #123`.
3. **A real process failure occurred monitoring that dispatch** and the user
   caught it, not this session: ~20+ minutes were spent in a foreground
   `sleep 15/20` shell loop grepping `RUN.json`'s status field, including
   one run that hit a 10-minute Bash tool timeout, before switching to
   proper `run_in_background` + notification. Root cause and correction
   written to memory as `feedback_no_hand_rolled_polling` (this repo's own
   docs already say `orca terminal wait --for exit` doesn't signal for this
   dispatch architecture, so RUN.json polling is the *documented* right
   data source — the bug was polling it via a manual sleep loop instead of
   backgrounding the wait, and not stopping to re-diagnose after the first
   couple of unchanged polls). Separately, the user flagged that running
   the full 36-smoke offline suite twice to verify one trivial single-file
   fix was excessive — written to memory as
   `feedback_trivial_no_full_suite`: trivial-tier verification should use
   focused tests only, full `run-all.sh` reserved for PR time.
4. **User raised a design idea, not yet scoped or written up**: instead of
   (or before) continuing the CONDUCTOR-native-subagent-dispatch design
   (below), decompose the dispatch/monitoring workflow into functional
   layers and build an explicit per-adapter (cmux/orca/herdr/future)
   capability matrix — e.g. "does this adapter have a native
   completion-notification signal? a terminal-read capability? a real
   blocking wait?" — using the adapter's native mechanism where available
   and a generic fallback (like RUN.json polling) only where it's absent.
   The user's stated reasoning: this session's actual friction was in the
   orchestration/monitoring layer (this session's own sleep-loop mistake,
   not a subagent-capability problem), and **the outcome of this capability
   matrix will likely change the shape of the native-subagent-dispatch
   design itself** — e.g. it may reveal that "native CONDUCTOR-side
   dispatch via `Agent`" is properly one more row in this same capability
   matrix (a 4th "adapter" whose completion signal is the tool-call return
   itself) rather than a separate special-cased routing decision as
   currently drafted in §2 of that design doc. Written to memory as
   `project_adapter_capability_layering_idea`. **Not scoped, not designed,
   no doc written this session** — this is the explicit next-session
   objective per the user's own words ("일단 pr merge하고 내가 말한거
   다음세션에 설계해보자").

## Next session

1. `git status --short --branch`, `git log -5 --oneline --decorate`,
   `git fetch --prune`, `gh issue list --state open --limit 100` — confirm
   current state before trusting anything above. Expect: `main` at or past
   `22cd391`, issues #111-#120 and #123 all closed, no other open issues
   from this thread.
2. **Design the adapter-capability-layering matrix first**, per the user's
   explicit sequencing request. Suggested shape (not prescriptive — reopen
   with the user before committing): for each dispatch-workflow functional
   unit (launch, completion-signal/liveness, terminal-read,
   blocking-wait, artifact-retrieval, teardown), and each current adapter
   (cmux, orca, herdr), determine from actual adapter source/docs (not
   assumption) whether a native mechanism exists, and if so what it is; if
   not, what the current generic fallback is (e.g. RUN.json polling) and
   whether that fallback itself needs hardening (see
   `feedback_no_hand_rolled_polling` for the specific polling-discipline
   gap found this session — background + notify, multi-signal liveness
   per `multi-agent-workflow.md`'s "Dispatch liveness operator rules", not
   raw sleep loops). Read `toolkit/scripts/adapters/{cmux,orca,herdr}.sh`
   and each adapter's own CLI docs directly.
   `docs/plans/2026-08-15-conductor-native-subagent-dispatch-design.md`
   (drafted last session, not yet reviewed or implemented, see the
   historical entry below) is explicitly in scope for revision once this
   matrix exists — check whether native `Agent`-tool dispatch is better
   modeled as a row in this matrix rather than the separate
   pre-dispatch-routing-decision framing it currently has.
3. Preserve the same protected untracked paths listed in every prior entry
   below (unchanged this session): `.agents/skills/meta-prompt`,
   `.claude/`, `.opencode/`, `.review/ISSUE-70-launch.*`,
   `.review/ISSUE-71-launch.*`, `.review/open-issues-dag-2026-08-02.md`,
   `.review/open-issues-dag-2026-08-14.md`, `HANDOFF.md`,
   `docs/research/2026-07-27-external-model-scorecard-sources.md`.

---

# Historical continuation — PR #124 merged, native-subagent-dispatch design drafted (2026-08-15)

This is the authoritative continuation entry. Everything below it (starting
with "#111-#120 implemented, PR #124 open") is now historical: PR #124 is
merged and the Opus-review question that entry left open is resolved (see
below — scoped review, not full-diff). Re-check GitHub, Git, Orca, scripts,
schemas, and installed tool versions before trusting anything below — this
entry is a snapshot.

## What happened this session

Two independent threads, in order:

### Thread 1 — PR #124 (#111-#120) closed out and merged

The user pushed back hard on the previous session's plan to send Opus the
full 32-file/~1191-line diff for review ("병신도 아니고" — don't make Opus
read the whole thing). Re-scoped instead: identified the 8 files in the diff
that carry actual runtime/behavioral logic (`dispatch-core.sh`,
`adapters/cmux.sh`, `lib/cmux-handles.cjs`, `lib/transport-registry.cjs`,
`agent-workflow.sh`, `lib/admission-recover.cjs`,
`lib/json-schema-subset.cjs`, `transport_receipt.schema.json` — 133
insertions/49 deletions of the PR's 1191/142) and excluded the other ~24
files (tests/fixtures/manifest/docs — no runtime behavior, only coverage of
it) from the dispatched review's scope, with that scoping decision stated
explicitly in the review artifact itself.

- Dispatched via `toolkit/scripts/agent-workflow.sh dispatch --orchestrator
  orca --runtime claude --role reviewer --produce-review --model opus
  --effort high`, prompt `.review/ISSUE-120-REVIEW-PROMPT-HIGHRISK.md` (still
  present in the worktree, reusable as a template for future scoped
  reviews). Returned `status: pass` with 3 `fix`-severity findings and 5
  non-blocking `nit`s; full text preserved at
  `.review/ISSUE-120-review-attempt1-output.log`.
- **Canonical publication of that review failed** with `refusal_reason:
  publication_failed` / root cause `conflicting snapshot` —
  `review-publish.cjs` refuses two different reviews' bytes at the same
  `(issue, HEAD)` snapshot key, and a prior full-diff Opus review from an
  earlier session already occupied `ISSUE-120-REVIEW-052f607...json` at
  this HEAD. This is correct behavior per the immutable-evidence design, not
  a bug — flagging here because canonical `.review/ISSUE-120-REVIEW.json`
  therefore still reflects the **earlier full-diff** review, not this
  scoped one; the scoped one's findings live only in the `-output.log` file
  and this HANDOFF entry. If a future session wants both reviews queryable
  as canonical artifacts, `review-publish.cjs`'s one-snapshot-per-head
  design would need a scope/label dimension added to the snapshot key —
  not attempted here, out of scope for this session.
- The 3 `fix` findings were dispatched to `opencode`/`glm-5.3`/`high`
  (`--role implementation --tier trivial`, prompt
  `.review/ISSUE-120-FIX-PROMPT.md`) and closed in one commit, `178454a`:
  1. `adapters/cmux.sh` delegation branch admitted cmux as available with no
     evidence `--cwd`/`--command` exist (relocated version of the exact
     false-green #112 was written to prevent) — fixed by still requiring
     `cmux new-workspace --help` to list both flags on the delegation path.
  2. `agent-workflow.sh capabilities` aggregate's per-child validator was
     laxer than `dispatch-core.sh`'s admission validator, so it could
     advertise an adapter as available that dispatch would then refuse —
     fixed by factoring both into one shared `scripts/lib/
     capability-result.cjs` validator.
  3. `lib/cmux-handles.cjs` — `inspectWorkspaceHandle` matched only
     `workspaces[].ref` while `normalizeCreateResult` accepted several id
     key shapes on create, so an id-shaped create handle could report false
     `stale` — fixed by matching the same key set on both sides.
- Verified at `178454a`: `.github/tests/release-contract.smoke.sh` ALL
  CASES PASS every time. `run-all.sh` was **35/36 across three separate
  full-suite runs**, always the same single case: `AC-119-1
  AGENT_WORKFLOW_POLL_INTERVAL alone sets the poll interval`, which uses a
  hardcoded 2-second poll-timeout in its own fixture. Isolated reruns of
  just that case passed 2/2. This is pre-existing load-dependent timing
  flakiness in the test's own 2s budget, unrelated to any file the 3 fixes
  touched — treated as a known flake, not a regression, and not fixed here
  (out of scope for this dispatch; a real fix would be widening that
  fixture's timeout or making it deterministic, a small separate task).
- Pushed, PR #124's `smoke` CI ran twice (both jobs) and both came back
  SUCCESS. Merged via `gh pr merge 124 --merge` (repo's actual convention —
  confirmed by checking `git log --merges`, plain merge commits, not
  squash) → merge commit `1fa4405`, `origin/main` now equals it.
- **Issue #123** (filed previous session, the `run-all.sh` stdin-isolation
  gap) remains filed but unimplemented — not touched this session, not
  blocking anything.

### Thread 2 — CONDUCTOR-native-subagent-dispatch design (exploratory → drafted)

Mid-wait on the fix dispatch, the user asked a design question: when the
CONDUCTOR's own harness can address the requested runtime/model directly
(same publisher — e.g. a Claude subagent via the `Agent` tool), what would
it take to skip the `cmux`/`orca`/`herdr` adapter path (external terminal +
watchdog poll + transport receipt) entirely for that case? Discussion
covered: what each path is good/bad at (adapter path's terminal/watchdog/
receipt machinery is exactly what produced 4 of this session's own
non-task-related failures — broken Homebrew node, a watchdog false-stall
kill, a dispatched account's own usage-limit exhaustion, and the
`conflicting snapshot` publish-lock collision above); why "subagent" isn't
a 4th adapter (dispatch-core.sh is an external OS subprocess with no way to
call back into the CONDUCTOR's own tool-use loop — only the CONDUCTOR model
itself can invoke `Agent`, so this has to be a CONDUCTOR-side pre-dispatch
routing decision, not new code inside dispatch-core.sh); and the real
security tradeoff (native dispatch structurally eliminates the #107-class
startup-hook-hijack risk since there's no separate process/dotfile surface
to carry it, but makes CONDUCTOR §2 role-bleed easier to commit by accident
since there's no process boundary forcing the CONDUCTOR-vs-worker
separation anymore, and shares the CONDUCTOR's own session quota instead of
a dispatched account's independent one).

User asked to turn this into a design doc. Written, then concretized on a
second pass at the user's explicit request ("설계문서부터 구체화하자"):

**`docs/plans/2026-08-15-conductor-native-subagent-dispatch-design.md`**
(status: draft, concretized, not reviewed, not implemented)

Verified against actual code before writing, not assumed: read
`toolkit/scripts/conductor-rebuild.sh` directly and confirmed it has **no
dependency on `RUN.json` or `transport_receipt`** — CONDUCTOR's disk-truth
state reconstruction runs entirely off `PR-DRAFT`/`BLOCKER`/`VERIFY`
artifacts, which a native subagent (given the same Write/Edit tool grant an
external worker has, in the same worktree) can produce identically. This is
the load-bearing fact that makes native dispatch's scope small: it doesn't
need to touch `dispatch-core.sh`, any adapter script, or
`transport-registry.cjs` at all.

Content, as it currently stands:

- §1-2: motivation (this session's own adapter-path failures) and the core
  architectural point above (routing decision, not a 4th adapter).
- §3: eligibility check — static identity comparison only (no LLM/network
  probe, matching `route.cjs`'s L0 cost invariant), fail-closed to the
  adapter path on any ambiguity.
- §4-5: what's reused unchanged (prompt authoring, output-contract,
  PR-DRAFT/BLOCKER/REVIEW schemas, scope-lock, tier/ROUND-STATE) vs. what's
  skipped/replaced (launch runner, terminal, watchdog poll/stall-timeout,
  transport_receipt publication) — as a table.
- §6 + 6.1-6.3: a **draft** `native_dispatch.schema.json` (CONDUCTOR-stamped,
  not self-reported by the subagent — records `head_sha_before`/`_after`
  observed by CONDUCTOR itself), a **draft**
  `native-dispatch-eligibility.cjs` pure function sketch, and **draft**
  concrete wording for a `conductor-persona.md` §2 addition. All three are
  illustrative sketches for the next implementer, not final/validated code.
- §7: security posture — the three real new risks (role-bleed-by-
  proximity, recursive sub-agent fan-out if a native subagent were ever
  granted its own `Agent` tool, shared session quota) plus the one
  structural win (#107-class hijack is architecturally absent, not just
  prohibited).
- §8: scope-of-changes table — estimated small/medium, all-additive, **no
  changes anticipated to `dispatch-core.sh`, any adapter script, or
  `transport-registry.cjs`**.
- §9: 4 open questions. Two were resolved this session by decision
  (expose both a CONDUCTOR-auto and a user-forceable
  `--prefer-native`/`--force-adapter` flag; implement the §6 marker). Two
  remain genuinely open and need empirical harness verification, not more
  inference — see below.
- §10-11: non-goals (does not touch the adapter path's eligibility window,
  no cross-provider native, no default-on) and the recommendation that this
  get an independent adversarial review (Opus 5 high or equivalent) before
  implementation, specifically on §7 and the remaining §9 items — same
  precedent as the model-routing and Herdr adapter designs, both of which
  went through exactly this review-before-implementation step in this repo.
  **Not requested or performed this session.**

## Still open / not done this session

- **The native-subagent-dispatch design has not been independently
  reviewed.** Per its own §11 and this repo's established precedent
  (`docs/plans/2026-07-26-objective-model-routing-design.md`,
  `docs/plans/2026-08-12-herdr-adapter-design.md` — both got an independent
  Opus/gpt-5.6-sol pass before implementation started), do this before
  writing any code against it. Given this session's own experience getting
  a scoped-not-full-diff Opus review right (Thread 1 above), the same
  scoping discipline applies here too: the review target is one ~450-line
  design document, not a diff, so full-document review is appropriate
  (unlike the PR #124 case) — no scoping decision needed this time.
- Two of the design's own open questions (§9.1-9.2: whether a hung native
  `Agent` call can actually be bounded via `TaskStop`, and whether a native
  subagent's artifacts survive a full CONDUCTOR *session* crash, not just a
  turn ending) are inference from tool-description text, not a real test.
  Whoever reviews or implements this should deliberately test both — spawn
  a long-running/hanging native-style subagent and call `TaskStop` on it;
  separately, confirm whether a `.review/*.json` artifact a subagent wrote
  is still on disk and correct after the parent session that spawned it is
  killed — before the design leans on either answer for real workflow use.
- No code, schema, or persona-doc change has been made toward this design.
  §6.1/§6.2/§6.3's schema/code/wording are drafts for reference only.
- Issue #123 (filed, unimplemented, unrelated) still sits open from a prior
  session — not picked up here, not blocking.

## Next session

1. `git status --short --branch`, `git log -5 --oneline --decorate`,
   `git fetch --prune`, `gh pr view 124` (confirm still merged, nothing
   force-changed), `gh issue list --state open --limit 100` — confirm
   current state before trusting anything above.
2. Decide how to get the native-subagent-dispatch design reviewed —
   likely the same Orca-dispatched Opus-reviewer pattern used successfully
   (once scoped correctly) in Thread 1 above, this time pointed at the
   whole design doc rather than a code diff. Ask the user for the review
   target/effort if unclear; do not assume full-document review is
   appropriate for every future revision of this doc without re-checking
   its length.
3. Resolve the two remaining open questions (§9.1-9.2 in the design doc)
   empirically before or alongside that review — they're cheap to test and
   the review will be stronger with real answers instead of inference from
   tool descriptions.
4. Only after review + the two open questions are resolved, turn §6.1-6.3's
   drafts into real, validated `toolkit/schemas/native_dispatch.schema.json`
   + `toolkit/scripts/lib/native-dispatch-eligibility.cjs` +
   `conductor-persona.md` edit, each with its own smoke coverage per
   `AGENTS.md`'s "add coverage for new behavior" rule — this is a genuine
   architecture change to how CONDUCTOR routes work and should go through
   the same scope-lock/tier discipline as any other Standard-tier chunk,
   not be rushed in ad hoc.
5. Preserve the same protected untracked paths listed in every prior entry
   below (unchanged this session): `.agents/skills/meta-prompt`,
   `.claude/`, `.opencode/`, `.review/ISSUE-70-launch.*`,
   `.review/ISSUE-71-launch.*`, `.review/open-issues-dag-2026-08-02.md`,
   `.review/open-issues-dag-2026-08-14.md`, `HANDOFF.md`,
   `docs/research/2026-07-27-external-model-scorecard-sources.md`. The new
   `docs/plans/2026-08-15-conductor-native-subagent-dispatch-design.md` is
   tracked (created under `docs/plans/`, which per `AGENTS.md` is
   maintainer planning material) — confirm whether the user wants it
   committed or left untracked like other same-day working docs; not
   decided this session.

---

# Historical continuation — #111-#120 implemented, PR #124 open, Opus review pending (2026-08-15)

This entry is now historical: PR #124 is merged (see the entry above) and
the Opus-review gap it left open was resolved by scoping the review to the
8 runtime-behavioral files rather than the full diff. Re-check GitHub, Git,
Orca, scripts, schemas, and installed tool versions before trusting
anything below — this entry is a snapshot from before the merge.

## What happened this session

Implemented all 10 issues from the adapter/test architecture review batch,
#111 through #120, in the dependency order documented in
`.review/open-issues-dag-2026-08-14.md` (a straight chain — file-overlap
analysis showed no safe parallelization). Self-dogfooded per the user's
explicit instruction: every issue implemented by opencode dispatch
(`zai-coding-plan/glm-5.2` for #111/#112, `zai-coding-plan/glm-5.3` for
#113-#120, effort `low` by default, `high` for the larger/riskier ones —
#115/#116/#117/#118/#119/#120 — per the user's later "use your judgment on
effort" correction), each independently reviewed by this session (Claude
Sonnet 5) against the issue's own acceptance matrix, then committed. One
commit per issue, stacked linearly:

```
main (9524467)
  → 52aedb9 #111 strict adapter output contract
  → aad8417 #112 cmux launch-parity proof seam
  → 4ff2ec4 #113 run-all-contract test in CI
  → fe67b48 #114 smoke-inventory closed-set guard
  → 8e2c9eb #115 transport registry + parity gate
  → b539cbc #116 adapter conformance registry loop
  → acc560e #117 one-fault-per-fixture
  → e89d155 #118 replace string-pin smoke assertions with behavior checks
  → d06d514 #119 neutralize cmux-only env var names
  → 052f607 #120 exact-token cmux-dispatch dry-run verification  (branch HEAD)
```

Branch `hjung3113/issue-120-cmux-dispatch-split`, pushed, **PR #124 open**:
https://github.com/hjung3113/feedbackops-workflow/pull/124 (base `main`).

Two regressions were found and fixed mid-chain during this session's own
verification (not part of any single issue's original scope — each
documented in its containing commit message):
- A `paste -s -d ' ' -` typo in #112's own new test code was reading stdin
  and silently truncating `run-all.sh`'s smoke inventory mid-run while
  `run-all.sh` still exited 0 (false-green). Fixed the immediate instance in
  #112's commit; filed **issue #123** for the systemic gap (`run-all.sh`
  doesn't isolate child smokes' stdin from its own process-substitution
  pipe) — #123 is NOT implemented, it's a filed-but-unscheduled issue.
- #111's legitimate `cmux-handles.cjs` refactor broke a
  `release-contract.smoke.sh` string-pin assertion (exactly the brittle-pin
  disease #118 targets generally). Minimally fixed as part of #113's commit
  to keep the release gate green in the meantime; #118 later replaced it
  properly along with the other five named pins.

Verified repeatedly through the chain, not just trusted from worker
reports: `run-all.sh` 36/36 and `.github/tests/release-contract.smoke.sh`
(which is **not** part of `run-all.sh`'s own discovery — must be run
separately) both green at every commit. This surfaced two more issues
worth remembering:
- `release-contract.smoke.sh` is easy to forget since a green `run-all.sh`
  doesn't cover it — this bit the session once (the cmux-handles regression
  above went unnoticed until #113's dispatch happened to run it).
- Individual smoke files can fail when run standalone even when
  `run-all.sh`'s aggregate is green, if a fixture setup has a latent bug
  that only a specific file order exposes (the `cmux-dispatch.smoke.sh`
  fixture-copy bug in #115, missing the new `transport-registry.cjs` copy).
  Lesson applied for the rest of the chain: run every touched file directly,
  not just via `run-all.sh`.

Also root-caused, per the user's explicit "if it recurs 3+ times, file an
issue" instruction: a broken Homebrew `node` (unversioned formula symlinked
to a keg missing its linked `llhttp` dylib version) crashed every
opencode-dispatched terminal's runtime probes. Fixed locally with
`brew reinstall node` (25.9.0_2 → 26.7.0) — this is a host/Homebrew issue,
not a toolkit bug, so no GitHub issue was filed for it, just noted here in
case it recurs on this machine.

GLM version note: `zai-coding-plan/glm-5.3` released 2026-08-14, mid-session
(variants: `low`, `high`, `max`; no named `medium` — omitting `--effort`
gives the implicit baseline). Switched to it partway through the chain.

## Still open / not done this session

- **Opus 5 independent review of the full PR stack — NOT completed.**
  Attempted 3 times via `toolkit/scripts/agent-workflow.sh dispatch
  --orchestrator orca --runtime claude --role reviewer --produce-review
  --model opus --effort high` (worktree
  `/Users/hyojung/orca/workspaces/feedbackops-workflow/issue-120-cmux-dispatch-split`,
  prompt `.review/ISSUE-120-REVIEW-PROMPT.md`, still present in that
  worktree — reusable as-is for a retry):
  1. First attempt: watchdog killed it as "stalled" after ~12 min — the
     reviewer role does heavy reading + full-suite verification without
     writing any files, and the watchdog's `progressed()` check is
     file-mtime-based only, so a pure-read/verify reviewer workload can
     look stalled even while actively working. Retried with
     `--first-progress-timeout 1800 --stall-timeout 1800`.
  2. Second attempt: exited immediately (`runtime_exit_nonzero`) —
     `.review/ISSUE-120-review-attempt1-output.log` showed
     `"You've hit your session limit · resets 7:50am (Asia/Seoul)"`. This
     is the dispatched Claude account's own usage limit, unrelated to this
     session's (the orchestrator's) limit.
  3. Third attempt: launched clean (fresh RUN.json, real PID, no stale
     markers) and was running normally when the user asked to stop it
     partway through, citing concern about how much of the account's usage
     limit a single Opus+high review of a ~1200-line/32-file diff was
     consuming. Stopped via `orca terminal stop --worktree
     path:.../issue-120-cmux-dispatch-split` before it produced a REVIEW
     artifact. **No `.review/ISSUE-120-REVIEW.json` exists.**
- PR #124 is therefore **not yet independently reviewed by Opus and not
  merged**. This is the literal next step the user asked for
  ("pr 올리고 opus 5 독립 리뷰 보강 후 merge") and it is the one piece not
  finished.
- Issue #123 (filed, not implemented) — a real, separate, small toolkit
  fix. Could be picked up as an #121-equivalent follow-on whenever
  convenient; not blocking the #111-#120 PR.

## Next session

1. `git status --short --branch`, `git log -5 --oneline --decorate`,
   `git fetch --prune`, `gh pr view 124` — confirm current state before
   trusting anything above (in particular: has the user or anyone else
   already reviewed/merged PR #124 since this was written?).
2. Decide how to get the Opus review done without repeating this session's
   cost/reliability problems. Options actually discussed with the user
   (no decision was reached — this was cut off by the user's frustration,
   not a deliberate choice among these):
   - Retry the same dispatch (worktree still exists with everything set
     up) once the dispatched account's usage window has reset — check
     current time against whatever limit-reset message a future attempt
     reports.
   - Have Claude Sonnet 5 (whichever session is running) do the review
     directly inline instead of dispatching a separate Opus subagent — the
     user did not reject this option, just got frustrated before it was
     tried. It trades "Opus-specifically" for "no separate dispatch/account
     cost and no risk of another mid-review stall/limit failure." Ask the
     user which they'd prefer before picking silently, since "Opus 5" was
     their explicit original instruction.
   - Ask the user directly what they want, given the session-limit
     friction observed twice this session.
3. Once a review is obtained (however produced) and any findings are
   addressed, merge PR #124 per the user's original instruction.
4. Local worktrees for #111-#119 (and the older #107/#108 ones) were all
   removed this session via `orca worktree rm` after their branches were
   confirmed merged into the #120 stack; their local branches were then
   force-deleted (`git branch -D`) at the user's explicit request since
   every commit is already reachable from
   `hjung3113/issue-120-cmux-dispatch-split`. Only that branch's worktree
   (`/Users/hyojung/orca/workspaces/feedbackops-workflow/issue-120-cmux-dispatch-split`)
   remains, plus `.review/ISSUE-120-REVIEW-PROMPT.md` in it for reuse.
5. Preserve the same protected untracked paths listed below (unchanged
   this session): `.agents/skills/meta-prompt`, `.claude/`, `.opencode/`,
   `.review/ISSUE-70-launch.*`, `.review/ISSUE-71-launch.*`,
   `.review/open-issues-dag-2026-08-02.md`,
   `.review/open-issues-dag-2026-08-14.md`, `HANDOFF.md`,
   `docs/research/2026-07-27-external-model-scorecard-sources.md`.

---

# Historical continuation — #104-109 triage resolved, next legacy issues (2026-08-14)

This entry is now fully historical: its "next open legacy issues" objective
(#111-#120) is complete, per the entry above. Re-check GitHub, Git, Orca,
scripts, schemas, and installed tool versions
before relying on any dated state.

## What happened this session

Re-triaged #104-#109 per the prior entry's objective, using actual code
reads (not the issue text alone) to determine toolkit ownership:

- **#104, #105, #106, #109 — closed as out-of-scope.** Confirmed by reading
  `toolkit/scripts/adapters/orca.sh` and grepping the whole repo: the
  toolkit's Orca adapter only calls `terminal create`/`terminal list`, never
  `terminal send`/`screenshot`/`snapshot`; and the toolkit owns zero
  black-box-round/actor/UI-testing guidance surface anywhere. All four were
  either raw manual Orca CLI use during FeedbackOps black-box rounds or
  FeedbackOps-target-only practice, not toolkit code paths. Closed via `gh
  issue close --reason "not planned"` with a comment explaining the
  ownership finding on each.
- **#107 — fixed, merged.** A worker's runtime (any transport, any of
  Codex/Claude Code/OpenCode) can carry a startup hook/plugin that makes it
  believe it's CONDUCTOR and delegate to sub-agents, producing zero file
  changes. Fix: `toolkit/docs/agents/conductor-persona.md` §7 now makes a
  standing solo-implementer / no-injected-policy line a permanent part of
  `contract.prohibitions[]` for every dispatch prompt. Doc-only, 1 file.
  PR #121, merge commit `5657a5b`.
- **#108 — fixed, merged.** A CONDUCTOR ran a target's full integration
  suite by hand during a live FeedbackOps black-box round; its setup reset
  37 tables and destroyed round data and seeded actor rows, twice across
  sessions. Fix: added optional `stateful: boolean` to
  `target-profile.schema.json`'s verification `group` definition (additive,
  no runtime enforcement — `target-verify.mjs`/`verify.schema.json`
  untouched on purpose) plus a `conductor-persona.md` §7 paragraph
  instructing CONDUCTOR to consult it before ANY verification run —
  scripted or hand-typed — since no toolkit script can intercept a
  hand-typed command anyway. 3 files (schema, persona doc, README).
  PR #122 (stacked on #121, retargeted to `main` after #121 merged), merge
  commit `9524467`.

## How it was implemented — self-dogfooded, worth repeating the pattern

Both fixes were implemented by dispatching to **opencode with model
`zai-coding-plan/glm-5.2`** through this repo's own
`toolkit/scripts/agent-workflow.sh dispatch --orchestrator orca --runtime
opencode --role implementation --tier trivial`, each in its own `git
worktree add` under `/Users/hyojung/orca/workspaces/feedbackops-workflow/`,
with a hand-authored `.review/ISSUE-<N>-CONTEXT.md` +
`.review/ISSUE-<N>-PROMPT.md` (output-contract block appended via
`toolkit/scripts/output-contract.sh render --role implementation`) — same
authoring discipline as `conductor-persona.md` §7 prescribes. Both runs
exited 0 with a schema-valid PR-DRAFT and an exact-match diff to spec on the
first attempt; no redispatch was needed.

Both PRs then got an **independent Claude Opus review** via `--orchestrator
orca --runtime claude --role reviewer --produce-review --model opus --effort
high` in read mode, against a hand-authored `.review/ISSUE-<N>-REVIEW-PROMPT.md`
scoping the reviewer to the issue's own acceptance matrix and explicitly
excluding sibling issues. Both returned `status: "pass"` with one `nit`
finding each (recorded in the PR comments, not blocking) — real reviews
against `schemas/review.schema.json`, not rubber-stamps: the reviewer read
`agent-watchdog.sh`'s actual `progressed()` implementation, ran the schema
validator against synthetic inputs, and diffed against the correct base
branch for the stacked PR.

This full loop (worktree → CONTEXT → PROMPT → opencode/glm-5.2 dispatch →
commit → push → PR → Opus reviewer dispatch → PR comment → merge) worked
cleanly end to end and is the template for the next issues.

## Still open in the mandatory classification matrix

None — #104-#109 are fully disposed (4 closed, 2 fixed and merged). The
prior entry's B0-E0 DAG (below) is superseded; do not resume it — its
premise (unresolved #104-#109 rows) no longer holds.

## Live state at this handoff

- Branch: `main`, HEAD `9524467a0c12c9d8ba917cc7cc26437261c131d6`, equal to
  `origin/main`.
- Merged PRs this session: #121 (`5657a5b`), #122 (`9524467`).
- Closed issues this session: #104, #105, #106, #109.
- Leftover local worktrees/branches, intentionally not cleaned up yet (their
  branches are already merged into `main`, so cleanup is safe whenever
  convenient, just not done this session):
  - `/Users/hyojung/orca/workspaces/feedbackops-workflow/issue-107-anti-hijack-preamble`
    (branch `fix/issue-107-anti-hijack-preamble`)
  - `/Users/hyojung/orca/workspaces/feedbackops-workflow/issue-108-verify-scope`
    (branch `fix/issue-108-verify-scope`)
- No tracked file outside the two merged PRs' diffs changed. Preserve all
  the same protected untracked paths listed below (unchanged this session):
  `.agents/skills/meta-prompt`, `.claude/`, `.opencode/`,
  `.review/ISSUE-70-launch.*`, `.review/ISSUE-71-launch.*`,
  `.review/open-issues-dag-2026-08-02.md`, `HANDOFF.md`,
  `docs/research/2026-07-27-external-model-scorecard-sources.md`.

## Next session

1. `git status --short --branch`, `git log -5 --oneline --decorate`,
   `git fetch --prune`, `gh issue list --state open --limit 100` — confirm
   current state before trusting anything above.
2. Optionally `git worktree remove` the two leftover worktrees above (both
   branches are merged; safe whenever convenient).
3. Next open legacy issues to triage/resolve are **#111-#120** (adapter
   output-contract validation, cmux capability-vs-launch parity, CI
   runner-contract execution, smoke-inventory shrink guard, transport
   allowlist dedup, cross-adapter conformance registry, one-fault-per-fixture,
   behavior-verification replacing string pins, cmux-only env-var
   neutralization, cmux-dispatch smoke reduction by contract owner). Confirmed
   this session: none of them overlap #107/#108's changes. Read each issue
   body fresh — do not assume the summaries above are current — and use the
   same self-dogfooded pattern (opencode/glm-5.2 implementation dispatch +
   Opus reviewer dispatch) unless a specific issue's risk profile calls for
   something else.

---

# Historical continuation — legacy issue scope audit and self-dogfooded resolution DAG (2026-08-14)

This is the authoritative continuation entry. Older entries below are historical
evidence only. Re-check GitHub, Git, Orca, scripts, schemas, and installed tool
versions before relying on any dated state.

## Exact live state at handoff

- Repository: `/Users/hyojung/Desktop/2026/feedbackops-workflow`.
- Branch: `main`, HEAD `bd829917ebeb31af57e711796e1b47bf2e902f6d`,
  equal to `origin/main` when checked on 2026-08-14.
- Latest merged delivery is PR #110, the Herdr adapter design/implementation.
- No tracked source file was changed in the review/issue-authoring session. This
  `HANDOFF.md` is an existing user-owned untracked file and remains untracked.
- Open issues created from the adapter/test architecture review are #111-#120.
  Each contains live code lines, a false-green or failure scenario, a smallest
  boundary, acceptance criteria, test changes, compatibility risks, and explicit
  exclusions. Do not reopen their research from scratch.
- The earlier reports that require a fresh ownership/scope audit are #104-#109:
  - #104 Orca `terminal send` prefix truncation.
  - #105 Orca screenshot/CDP timeout.
  - #106 Orca snapshot visibility for portal-rendered controls.
  - #107 SessionStart/plugin policy hijacking dispatched workers.
  - #108 destructive target integration tests during a black-box round.
  - #109 missing proof of actor switching in multi-actor black-box missions.
- Existing protected untracked paths must not be reset, stashed, cleaned,
  overwritten, committed, or deleted:
  `.agents/skills/meta-prompt`, `.claude/`, `.opencode/`,
  `.review/ISSUE-70-launch.hO9FjC/`, `.review/ISSUE-70-launch.uKlXGj/`,
  `.review/ISSUE-71-launch.1SFunu/`, `.review/ISSUE-71-launch.axwL4p/`,
  `.review/open-issues-dag-2026-08-02.md`, `HANDOFF.md`, and
  `docs/research/2026-07-27-external-model-scorecard-sources.md`.

## User-authorized next-session objective

Do not begin by implementing #111-#120. First adversarially re-triage #104-#109
against the current toolkit boundary. For every issue, determine from current
code and reproducible evidence:

1. Is this a real defect now, or a stale/version-specific observation,
   unsupported inference, documentation preference, or target-environment
   incident?
2. Is the owning product this distributable toolkit, Orca itself, an agent TUI,
   a local plugin/configuration, or the FeedbackOps target application/test
   harness?
3. If the toolkit owns any part, what is the transport- and target-neutral
   invariant? The remedy must work for cmux, Orca, Herdr, and future adapters
   unless the contract is explicitly adapter-private.
4. Which observations must be discarded because they hard-code FeedbackOps
   personas, table resets, Radix, localhost ports, Ponytail, Orca command quirks,
   macOS paths, fixed prefix lengths, or one adapter's handle/output shape?
5. What is the smallest generic behavior that remains after those details are
   removed? Prefer fail-closed evidence contracts and typed adapter boundaries;
   do not add speculative framework machinery.
6. Is the proposed behavior already covered by #111-#120 or an existing closed
   issue? If so, cross-link/close as duplicate or narrow the older issue instead
   of implementing two versions of the same contract.

The user explicitly authorized intentional product self-dogfooding for this
next-session work. Invoke the repository's product workflow as
`/agent-workflow ... --self-test`; all write-capable seats must reach
`toolkit/scripts/agent-workflow.sh dispatch` with an explicit
`--orchestrator cmux|orca|herdr`, runtime, and role. This authorization does not
relax admission, execution-plan, receipt, evidence, review, verification, or
Git safety gates.

## Mandatory classification matrix for #104-#109

Produce a current evidence table before writing code. Each row must have one
terminal disposition: `toolkit defect`, `adapter-private toolkit defect`,
`external Orca defect`, `target-project policy`, `environment/configuration`,
`duplicate`, `stale/not reproduced`, or `insufficient evidence`.

- #104: distinguish a live Orca/TUI input-delivery defect from a generic
  transport acknowledgement problem. Never ship fixed padding or a guessed
  13-15 character constant. Toolkit scope exists only if a transport-neutral
  delivery-integrity contract can be proven without replaying ambiguous writes.
- #105: screenshot capture belongs to Orca unless the toolkit itself promises
  visual evidence collection. A toolkit fallback must preserve the distinction
  between visual evidence and accessibility-tree evidence; snapshot text cannot
  silently satisfy layout/color acceptance criteria.
- #106: Radix/portal behavior and Orca snapshot traversal are external/product
  specifics. Retain only a generic interaction-confirmation rule if the toolkit
  actually owns black-box executor guidance; do not encode Radix or keyboard
  sequences as a universal adapter contract.
- #107: Ponytail and user dotfiles are environmental details. Test whether the
  real generic defect is untrusted startup instruction precedence, recursive
  delegation, or lack of work evidence. Do not inspect or mutate user-global
  config as a normal fix, hard-code plugin names, or equate elapsed time with
  failure. Any admission/preflight must apply across runtimes and transports.
- #108: FeedbackOps table/persona reseeding is target-specific. Keep only a
  generic declared-destructive-verification/round-state isolation contract if
  it can be expressed by target-owned metadata and verified without teaching
  the toolkit database semantics.
- #109: FeedbackOps actor names and mission steps are target-specific. Keep only
  a generic identity/provenance requirement if multi-actor black-box execution
  is truly a toolkit feature. UI display text alone may be weak evidence; define
  what an adapter-independent actor-change receipt would prove and fail invalid
  missions closed.

For external-only or target-only findings, do not add toolkit code merely to
work around them. Correct the issue scope/title/body or close with evidence only
when GitHub mutation is explicitly authorized in the live session.

## Required orchestration DAG

Use this project's own orchestration workflow, not ad-hoc background agents.
Keep one CONDUCTOR read-only on product code and make dependencies explicit in a
canonical execution plan. Recommended graph:

```text
A0 live preflight and issue/duplicate inventory
 |
 +--> A1 #104 delivery-integrity ownership research
 +--> A2 #105/#106 evidence-surface ownership research
 +--> A3 #107 startup-policy contamination research
 +--> A4 #108/#109 black-box state and identity research
             |
             v
B0 adversarial scope synthesis and classification gate
 |
 +--> B1 reconcile retained contracts with #111/#112/#115/#116/#119
 +--> B2 reconcile test/evidence work with #113/#114/#117/#118/#120
             |
             v
C0 canonical DAG and exact write-set decision
 |
 +--> C1..Cn bounded implementation seats (parallel only when
 |        `parallel-plan.sh decide` proves disjointness and isolation)
             |
             v
D0 serial integration -> focused VERIFY -> independent REVIEW
 |
 +--> D1 adversarial cross-adapter matrix: cmux / Orca / Herdr
             |
             v
E0 issue disposition and delivery report
```

Research seats are read-only and must cite current code, tests, Git history,
live versions, and a reproducible public-seam scenario. B0 is a decision gate:
no implementation task may become ready until every #104-#109 row has an owner,
generic invariant, retained/discarded details, duplicate links, and a concrete
test seam. If the surviving changes overlap #111-#120, update the execution DAG
so the shared root cause is implemented once and dependent issue acceptance is
verified against that single change.

## Implementation and review constraints

- Start from a fresh feature branch/worktree after re-checking live state; never
  write or commit directly on `main`.
- Generate canonical ROUND-STATE/prompt/execution-plan artifacts required by the
  product workflow. Exact write sets and dependency order must be decided before
  parallel write dispatch; uncertainty serializes.
- Use adapters only for transport-private probing/launch/inspection. After the
  adapter boundary, admission, runner, receipt, recovery, telemetry, review, and
  completion logic must not branch on cmux/Orca/Herdr unless a documented
  transport semantic requires it.
- Preserve macOS Bash 3.2 compatibility. Keep schemas, semantic validators,
  fixtures, docs, installed-copy behavior, and smoke coverage aligned when a
  contract changes.
- Replace duplicated or implementation-pinned tests instead of layering more
  assertions. Every new test must fail under the demonstrated defect and cover
  a public seam; do not count always-success tests or duplicate unit coverage.
- Each retained generic defect needs cross-adapter reasoning. Run all applicable
  cmux, Orca, and Herdr fakes/conformance cases; live validation limitations must
  be reported separately and cannot be represented as green.
- Independent REVIEW must inspect the integrated diff and objective, including
  an adversarial check that target-specific and Orca-specific policy has not
  leaked into shared toolkit code.
- Do not claim completion while any required gate is red. Distinguish focused
  green, full-suite green, environment-blocked live checks, and unrun checks.
- Implementation is authorized by the objective, but commit, push, PR creation,
  issue mutation/closure, and merge must be re-confirmed from the live session
  before those external or durable actions.

## First commands next session

```bash
cd /Users/hyojung/Desktop/2026/feedbackops-workflow
git status --short --branch
git log -5 --oneline --decorate
git fetch --prune
gh issue list --state open --limit 100
orca status --json
orca worktree current --json
toolkit/scripts/agent-workflow.sh capabilities
```

Then read current bodies/history for #104-#120, create the canonical
self-test research plan, and run A0-A4 through the product dispatch path. Do not
reuse the completed temporary Orca Run `run_0936d8db227d` as current authority;
it only records the #111-#120 research/publication session.

---

# Historical continuation — Herdr adapter implementation (2026-08-12)

Repository: `/Users/hyojung/Desktop/2026/feedbackops-workflow`

## Exact live state at pause

- Branch: `docs/herdr-adapter-design`, based on current `origin/main`.
- `HEAD` and `origin/main`: `19ec1e4b776cc43885803ff363b508e260166b41`
  (merge commit for PR #103).
- The Herdr design is uncommitted at
  `docs/plans/2026-08-12-herdr-adapter-design.md`.
- No Herdr adapter implementation, test, commit, push, issue, or PR was created.
- The design was checked against Herdr stable `v0.8.0`, tag commit
  `346411fa21afd297f5ed3b3fa56f9e3fbf7654b7`, and upstream `master` snapshot
  `06ca0baa12f4203c5bbad9ecadf53f9a475a52b2`.
- The source-review clone was moved to
  `/Users/hyojung/.Trash/herdr-adapter-design.q5Bl9Y`; re-clone the exact tag if
  source evidence is needed again.

## Approved design outcome

Herdr can be added without an upstream change as the third adapter at the
existing `capabilities | launch | inspect` seam. Do not create a second dispatch
path, a Herdr-specific compatibility facade, a socket client, or a direct
`herdr agent start` path. The public selection remains explicit and fail-closed:

```text
agent-workflow.sh dispatch --orchestrator herdr ...
  -> dispatch-core.sh --adapter herdr ...
  -> scripts/adapters/herdr.sh capabilities|launch|inspect
```

The design received an independent `gpt-5.6-sol` / `high` review. The first
review returned `REVISE` with six findings; all were incorporated. The same
reviewer re-reviewed the final document and returned `ACCEPT`.

## Contracts that implementation must preserve

1. `capabilities` requires the `herdr` binary, semver `>=0.8.0`,
   `HERDR_ENV=1`, non-empty `HERDR_SOCKET_PATH`, required workspace/pane help
   commands, and a schema-shaped read-only `workspace list` response. Missing
   current-session context is `session_context_missing`; there is no fallback.
2. `launch` creates exactly one non-focused workspace with the exact worktree
   and label, validates `result.type == "workspace_created"`, and requires
   `root_pane.workspace_id == workspace.workspace_id` before targeting the root
   pane.
3. Herdr `v0.8.0` `pane run` success is **exit 0 with empty stdout**, not JSON.
   The adapter owns the normalized success JSON and returns the created
   `workspace_id` as `external_handle`; requested labels and request IDs are
   never identity.
4. After workspace creation, schema-valid `pane_not_found`, `invalid_key`, or
   `pane_send_failed` stderr is a definite pre-delivery rejection. It may close
   only that newly created workspace, returns non-zero without a handle, and
   publishes no receipt.
5. Any other post-create non-zero result is an ambiguous acknowledgement. Do
   not close the workspace. Emit the created handle as valid stdout JSON while
   preserving the non-zero exit; `dispatch-core.sh` parses the handle before
   `launch_status` and needs it to publish inspectable provenance and enter the
   existing fresh RUN/BLOCKER path.
6. `inspect` returns `live` only for exit 0, `result.type == "workspace_info"`,
   and an exact workspace-ID match. Only one schema-valid stderr JSON with exit
   1 and `error.code == "workspace_not_found"` is `stale`; all other malformed,
   mismatched, server, protocol, or I/O results are `handle_unverifiable`.
7. Workspace existence is never completion authority. RUN, BLOCKER, REVIEW,
   VERIFY, admission, runtime/model, and watchdog ownership remain unchanged.

## Next-session implementation order

1. Read `AGENTS.md`, `toolkit/STATUS.md`, this top handoff, and the complete
   design document. Verify live branch/HEAD/origin and protected untracked state
   before editing.
2. Start RED at the public seam in
   `toolkit/scripts/__tests__/orchestrator-interface.smoke.sh`. Add a fake Herdr
   whose request ID, label, workspace ID, and pane ID are all distinct. Cover
   capability refusal, exact create identity/coherence, empty-stdout run
   success, definite versus ambiguous failure, and inspect classification.
3. Add the Bash 3.2-compatible `toolkit/scripts/adapters/herdr.sh`, then make the
   minimal closed-set changes in `agent-workflow.sh` and `dispatch-core.sh`.
4. Extend the transport allowlists in
   `toolkit/schemas/transport_receipt.schema.json`,
   `toolkit/schemas/telemetry_sample.schema.json`, and
   `toolkit/scripts/lib/admission-recover.cjs`; add Herdr fixtures and routed
   receipt/telemetry regression coverage while retaining legacy cmux/Orca.
5. Update installation and guidance in the same implementation change:
   `toolkit/README.md`, both product playbook copies, workflow-config examples,
   `toolkit/.claude/skills/agent-workflow/SKILL.md`, its
   `references/adoption.md`, `toolkit/docs/agents/conductor-persona.md`, and
   `toolkit/STATUS.md`. Add an installed-output closed-set check so no guidance
   still presents `cmux|orca` as exhaustive.
6. Run the focused orchestrator smoke first, then affected telemetry,
   installation, and `.github/tests/release-contract.smoke.sh` gates. Run
   `bash -n` for changed shell scripts and `git diff --check`. Any red gate means
   the adapter is not complete.

## Live-validation limitation

This design session had `HERDR_ENV=0`, so it did not control a live Herdr pane.
The source and contract evidence are sufficient for implementation, but a final
manual live launch/inspect check should run only from a Herdr-managed pane after
the fake/public-seam tests are green. Do not weaken the session-context gate to
make a non-Herdr development shell pass.

## Protected root state

Preserve the existing unrelated untracked files and directories:

- `.agents/skills/meta-prompt`
- `.claude/`
- `.opencode/`
- `.review/ISSUE-70-launch.*`
- `.review/ISSUE-71-launch.*`
- `.review/open-issues-dag-2026-08-02.md`
- `docs/research/2026-07-27-external-model-scorecard-sources.md`
- this untracked `HANDOFF.md`

Do not commit or push in the next session without fresh user authorization.

---

# Historical continuation — 2026-08-01

Repository: `/Users/hyojung/Desktop/2026/feedbackops-workflow`

## Completed publication

- PR [#89](https://github.com/hjung3113/feedbackops-workflow/pull/89) merged as
  `cbe84751215ab2775b1e2bf7f9277dc4c14cbd43`; issue #79 is closed.
- The following PRs are merged to `main`; their linked issues closed
  automatically through the PR bodies:

| Issue | Merge commit | Merged PR |
| --- | --- | --- |
| #80 | `f50d3f6` | [#92](https://github.com/hjung3113/feedbackops-workflow/pull/92) |
| #81 | `312c1c0` | [#93](https://github.com/hjung3113/feedbackops-workflow/pull/93) |
| #82 | `82a515d` | [#94](https://github.com/hjung3113/feedbackops-workflow/pull/94) |

- `origin/main` is now `82a515d124aab483f379565fd26ace0d71275a4a`.
- #80 fixes the missing implementation-prompt AC-ID guidance; #81 provides
  runtime-specific reviewer allocation and fails closed without one; #82 makes
  the generic Quickstart use Git worktrees plus `target-verify.sh`, retaining
  FeedbackOps adapters only as an explicit compatibility alternative.

## Verification record

- #80 and #81: focused relevant smokes, installer smoke, release contract, and
  the full offline suite passed.
- #82: `install-into.smoke.sh`, `release-contract.smoke.sh`, and the full
  offline suite passed: `NODE_OPTIONS= bash toolkit/scripts/__tests__/run-all.sh`
  reported `36/36 passed`.
- No Orca app session, tab, configuration, or Orca CLI state was changed. The
  issue worktrees below were created using `git worktree add`; test transports
  used temporary fake cmux executables only.

## Current implementation start: #83

- Worktree: `/Users/hyojung/orca/workspaces/feedbackops-workflow/issue-83-launch-runner-cleanup`
- Branch: `fix/issue-83-launch-runner-cleanup`, currently clean at `cbe8475`.
- Issue #83 concerns unbounded `.review/ISSUE-N-launch.*/` runner directories.
  `dispatch-core.sh` creates the runner and the current transport receipt hashes
  it; `agent-workflow.sh inspect` marks a receipt stale when that runner is
  missing or changed. Decide and test a retention rule before editing: deleting
  a completed runner immediately would invalidate the receipt, while retaining
  only the latest receipt-bound runner and removing superseded same-issue
  runners after a new receipt is atomically published preserves the present
  receipt contract. Keep cleanup scoped to the exact issue/runner pattern and
  document the resulting lifetime in `toolkit/docs/agents/artifact-lifecycle.md`.

## Protected root state

- Root `main` is currently `1efe3e5`; do not reset or fast-forward it as part
  of this work.
- Preserve existing root untracked state, including `.agents/skills/meta-prompt`,
  `.claude/`, `.opencode/`, `.review/ISSUE-70-launch.*`,
  `.review/ISSUE-71-launch.*`, `docs/research/2026-07-27-external-model-scorecard-sources.md`,
  and this untracked `HANDOFF.md`.

---

# Historical handoff — 2026-07-22

Repository: `/Users/hyojung/Desktop/2026/feedbackops-workflow`

## Current state

- Branch: `main`
- Local merge completed: `c0223f7 merge(workflow): resolve issues 47 and 55-57`
- Implementation commit: `17ea699 fix(workflow): harden issue contract recovery`
- `origin/main` has **not** been pushed with this merge.
- No GitHub issue was closed.
- Keep this `HANDOFF.md` intentionally untracked.

## Delivered issue scope

| Issue | Delivered boundary |
| --- | --- |
| #47 | Schema-derived output contracts, role-specific artifact paths, immutable review snapshots, and redispatch ordinal/supersession evidence. |
| #55 | Canonical `BLOCKER` schema validation, required prompt fields/reason codes, and recoverable nonconforming-blocker handling. |
| #56 | Runner-capability allocation/preflight, Codex-valid reviewer defaults, and fail-fast handling for unavailable/refused models. |
| #57 | Clean-probe reference and installer warning, documented migration/sentinel semantics, and fail-closed PG environment/TLS mapping without database URLs in argv. |

## Conductor policy corrected

The prior run over-expanded because the reviewer prompt authorized whole-diff adversarial P1/P2 exploration after each change. The committed conductor persona and agent-workflow skill now require:

1. Make an issue acceptance matrix from the issue body and explicitly requested comments.
2. Treat only that matrix as authority for the task.
3. Defer newly found non-blocking concerns; do not edit, redispatch, or block completion for them without user scope expansion.
4. Re-review matrix checks and changed files only. Hardening is a separate, explicitly authorized task.

No separate archival commit was created: the merged implementation was retained only where it mapped to the four issue boundaries above.

## Verification record

- Focused smoke coverage reported green for `output-contract`, `model-alloc`, `redispatch-check`, `cmux-dispatch`, and `parallel-safety`.
- Earlier full smoke run recorded `ALL CASES PASS` with `WHOLE_GATE_CLEAN=0`; do not describe this as a clean release gate.
- The final narrow edits were committed and merged after the long review loop. Before any push, re-run the relevant smoke suite against current `main` and inspect failures locally; do not restart whole-diff adversarial review.

## Next safe action

```bash
cd /Users/hyojung/Desktop/2026/feedbackops-workflow
git status --short
git log -3 --oneline
git diff origin/main...main --stat
```

If the user authorizes publication, validate current `main`, then push `main`; close issues only after confirming the live issue acceptance matrix.

## Constraints to preserve

- Bash 3.2 compatibility.
- Product workflow is opt-in in this repository; self-dogfooding needs explicit `--self-test`.
- Script/schema changes require matching playbook, README/STATUS, and smoke coverage.
- Do not push or close issues without explicit authorization.
- Keep `HANDOFF.md` untracked.

---

## Model-routing design handoff — 2026-07-26

### Delivered in this session

Design-only work; no product script, schema, runtime configuration, commit,
push, or GitHub state changed.

- `CONTEXT.md` now defines Route, Demand, Runner offer, Routing policy, Route
  digest, Refusal, and Routing outcome with their final authority boundaries.
- `docs/plans/2026-07-26-objective-model-routing-design.md` is the current
  implementation design.
- `docs/research/2026-07-25-model-routing-design.md` was reconciled with the
  plan so historical research does not contradict the final v1 boundary.

Both documents were independently reviewed through Orca orchestration by Opus
5 high and gpt-5.6-sol medium. Both initially returned `REQUEST_CHANGES`; the
material findings below were incorporated by narrowing v1 rather than adding
new subsystems.

### Confirmed v1 boundary

1. **Opt-in only.** Routing runs only for policy-opted-in, allocator-owned
   writes. No-policy, explicit `--model`/`--effort`, and dry-run paths are
   complete routing bypasses and retain current behavior byte-for-byte.
   V1 applies only to canonical redispatch: a policy-opted initial write
   (Trivial, Standard, or Full Cluster) refuses as `route_mode_unbound` until
   a generic host admission transaction is deliberately designed. Mode
   classification must precede both allocator sites and the remote
   model-compatibility probe; any manually supplied `--model` or `--effort`
   bypasses routing, while explicit and implicit allocator paths are eligible.
2. **Router cost invariant.** L0 has no LLM, LSP, git, diff, repository walk,
   or file-content analysis. The earlier L1/`numstat` idea was removed.
   Existing `model-alloc.sh --evidence`, pre-scope consumer discovery, and
   typecheck retain their current owners.
3. **Static identity is not availability.** The cached Runner offer establishes
   executable/version/permission-configuration identity only. It does not
   assert remote model availability or resolve aliases. The current
   launch-time compatibility preflight remains responsible for availability and
   must still fail before admission markers.
4. **Do not bypass model allocation.** V1 policy candidates may only be
   `{ "from": "model_alloc" }`. Literal candidates, automatic cross-provider
   routing, and policy-based reviewer-capability bypasses are out of scope.
5. **Host-owned atomic binding.** An admitted `route_digest` is authoritative
   only in a Git-common-dir host admission record published through the existing
   atomic recovery protocol. A worker-writable marker is diagnostic only. If a
   dispatch mode cannot compose the binding atomically, routing is deferred for
   that mode. The canonical ordinal record is the binding authority; an
   `integrated_fix` singleton is only a recovery companion and must match its
   digest. The digest excludes ephemeral offer timestamps. `recover` verifies
   the newly computed expected digest before adoption; `recover-lock` has no
   adoption path and preserves existing reclaim. A prior-key singleton remains
   its sentinel, while a current singleton without its matching ordinal is
   `route_digest_unbound`. That blocks adoption only and leaves the existing
   interrupted-prepare reclaim intact. Refusal is stdout-only and creates no
   receipt/marker/telemetry.
6. **Observational data foundation only.** Existing local telemetry may gain a
   schema-v2 routing object for policy-opted samples after validating binding
   plus receipt. It stores a local-salt HMAC route pseudonym, not a raw digest,
   prompt, source text, LSP result, pricing lookup, or model self-rating.
   Reports are descriptive, use complete independent-chain thresholds, disclose
   confounding, and never mutate policy.

### Explicit non-goals

- No automatic provider/runtime selection, availability probe, predictive
  ranking, dynamic pricing/latency optimization, background learner, or
  telemetry-driven policy mutation.
- No toolkit-level impact-analysis module; use existing target-native discovery
  and `live_probes[]` unless a concrete target proves those are insufficient.
- No route state added to ROUND-STATE in v1; host binding plus derivative
  transport receipt is the provenance seam.

### Required implementation order when authorized

1. Prove/implement the host-owned atomic binding for one eligible opt-in mode;
   defer every mode that cannot satisfy it.
2. Add pure `route.cjs` and Bash 3.2 wrapper with the L0 cost invariant.
3. Add host-pinned immutable policy snapshot and static identity/configuration
   read. Do not add a model availability inventory.
4. Add derivative `transport_receipt` v3 and telemetry sample v2 provenance
   validation only after the binding path is green.
5. Add schema fixtures and focused smoke coverage, including no-policy bypass,
   no-git L0, policy immutability, interrupted binding recovery, receipt/binding
   equality, salted telemetry provenance, and report suppression.
6. In the same implementation commit, synchronize the workflow playbook,
   README, STATUS, installation inventory/smoke, and release-contract coverage.

### Verification completed for the design documents

- Local Markdown-link and final-newline check passed for the three design
  documents.
- `git diff --check` passed for tracked changes; all model-routing documents
  remain intentionally untracked pending an explicit commit request.

### Grill closure — 2026-07-26

The document grill is complete. Opus 5 high independently reviewed the final
scope and returned `ACCEPT`: the scoped v1 design is ready for implementation
planning. Its review forced three material corrections that are now part of the
design, not implementation suggestions:

1. Classify write mode before either allocator site and before the remote model
   compatibility probe. Policy-opted initial writes fail `route_mode_unbound`
   without a probe or durable side effect.
2. The route-binding authority is the canonical redispatch ordinal record. Its
   digest excludes `observed_at` and `expires_at`; recovery compares only the
   current-key record, so a static-identity cache refresh does not strand a
   retry.
3. `integrated_fix` has an authoritative ordinal plus a recovery-companion
   singleton. A missing/mismatched current-key pair is never adopted, but an
   unadvanced interrupted prepare remains reclaimable. `recover-lock` performs
   reclaim only; it is not an adoption gate and must not digest-gate reclaim.

The last wording-only P2 from Opus was applied after the `ACCEPT` verdict: it
states the existing `recover-lock` reclaim role explicitly. No product code,
schema, runtime configuration, commit, push, or GitHub state changed.

### Next session: implementation-planning entry point

1. Re-read this handoff, `CONTEXT.md`, the final plan, and the research file.
2. Treat the plan's required implementation slices and negative-test matrix as
   the acceptance matrix. Do not widen v1 to initial writes, alternate
   providers, dynamic ranking, or policy mutation.
3. Before implementation, turn the first two slices into a concrete
   file-by-file plan: early mode classification; then canonical-redispatch
   binding/recovery extension plus focused smoke cases. Re-consult Opus 5 for
   any new design decision, per user direction.
4. Keep the design documents untracked until the user explicitly authorizes an
   implementation/commit. When implementation is authorized, update playbook,
   README, STATUS, schemas/fixtures, installation coverage, and release
   contract coverage in the same commit.

### Current worktree status

Keep these untracked files unless the user asks otherwise:

- `CONTEXT.md`
- `HANDOFF.md`
- `docs/plans/2026-07-26-objective-model-routing-design.md`
- `docs/research/2026-07-25-model-routing-design.md`

---

## Model-routing implementation WIP + Opus 5 audit — 2026-07-26

### Exact current state

- Branch: `feat/model-routing-admission` at `dbea700` with no commit made for
  this WIP. Do not reset, discard, stage, commit, push, or merge it until the
  correction order below and doc-sync gate are complete.
- Modified tracked files:
  - `toolkit/scripts/dispatch-core.sh` — write-mode classification was moved
    before both allocator sites. The legacy initial-tier validation intentionally
    remains at its former later point so no-policy error ordering is unchanged.
  - `toolkit/scripts/lib/admission-recover.cjs` — exploratory optional route
    digest transaction/recovery support.
- New untracked test:
  `toolkit/scripts/__tests__/admission-recover.smoke.sh`.
- Preserve the pre-existing untracked design files listed above, including this
  `HANDOFF.md`.

### Verification already run

- Local: `bash toolkit/scripts/__tests__/admission-recover.smoke.sh` passed (7
  cases) and `bash toolkit/scripts/__tests__/redispatch-check.smoke.sh` passed.
- Independent Opus 5 high read-only audit completed through Orca task
  `task_b8bf894070c8` / dispatch `ctx_73b2f9c9d6b6`. It reported that
  `admission-recover.smoke.sh` and `cmux-dispatch.smoke.sh` both passed at the
  audited WIP. The Opus audit wrote only its private scratchpad; it did not
  modify the repository.
- `git diff --check` is clean. Do not call the WIP complete from these focused
  tests: selector, policy snapshot, dispatch wiring, receipt/telemetry, schema,
  installation/release coverage, and doc-sync are still absent.

### Opus 5 authority decision — required before continuing

The routing policy must **not** live in the worktree or Git common dir. The
current write sandbox grants `$GIT_COMMON_DIR` as a Codex writable root, so it
does not meet the design's location-based "host-owned" claim.

Use a per-repository host-state root outside every routine sandbox writable
root:

```text
${AGENT_WORKFLOW_HOST_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-workflow}/
  repos/<sha256(realpath(GIT_COMMON_DIR))>/routing-policy/
    active.json                 # pointer; absence is complete no-policy bypass
    snapshots/<hex>.json        # exact-byte SHA-256 name, immutable mode 0444
```

- Add a host-only explicit install/deactivate verb. It validates the bounded
  policy, content-addresses it, writes a snapshot through temp+rename, then
  atomically publishes/removes the pointer. Never auto-installs a policy.
- Eligibility reads the pointer and snapshot before either allocator site and
  before the remote compatibility probe. It rejects symlinks, non-regular or
  group/other-writable files, oversize input, and a pointer/filename/content
  digest mismatch as `route_policy_invalid`.
- Reject `AGENT_WORKFLOW_HOST_STATE` when it resolves inside the worktree or
  Git common dir, and never forward it into the worker environment.
- The policy digest joins `route_digest`; content binding and host-side
  verification are the actual v1 integrity claim. Explicitly document that the
  current Git-common-dir admission data is also worker-reachable and defer
  moving/narrowing that existing writable root to a non-v1 hardening task.

### Mandatory corrections to the current WIP

1. **P1 reclaim bug:** `admission-recover.cjs` currently removes an unadvanced
   prepared binding, then emits `route_digest_unbound`/`route_digest_mismatch`
   and exits 3. Its caller treats that as fatal, so the same invocation cannot
   republish and launch. For `!advanced && status:"prepared"`, reclaim and exit
   0; report a typed refusal only when the record remains (advanced or
   committed). Change the matching smoke expectation from exit 3 to exit 0.
2. Replace overloaded positional digest arguments with trailing named
   `--route-digest <64-hex>` parsing. Capture recovery stdout in
   `dispatch-core.sh` and map a typed code rather than discarding it through
   `>/dev/null 2>&1`.
3. Gate the new prior-key guard on an expected route digest, so no-policy
   recovery remains byte-compatible. Add a digest-absent legacy regression.
   Remove the dead digest-less `prepare` mode or make it digest-aware only with
   a real caller.
4. Correct the plan: early classification is required, but the legacy
   initial-tier contract check must stay late on the no-policy path to preserve
   existing error ordering.
5. Implement host-state policy install/read/eligibility and the pure
   `route.cjs` + Bash 3.2 wrapper. Only then wire the selected digest through
   recovery/publish/commit while the existing issue lock is held.
6. Add the planned ordering/bypass smoke cases (failing allocator and model
   probe sentinels; opted-in initial write for all three tiers; manual tuple,
   dry-run, and absent-policy bypass), then receipt/telemetry/schema slices.
7. Before any commit, synchronize the playbook, `toolkit/README.md`,
   `toolkit/STATUS.md`, installation smoke, release-contract smoke, schemas and
   fixtures. Run the affected smokes and one final Opus 5 read-only review.

### Scope lock

Do not widen v1 to initial-write routing, provider/runtime switching, model
availability probing, dynamic ranking, fallback, telemetry-driven policy
mutation, or a redesign of the existing sandbox writable roots. The latter is
an explicit follow-up, not a v1 fix.

---

## Model-routing WIP progress — 2026-07-26

### Changes made, not committed

- `toolkit/scripts/lib/admission-recover.cjs`
  - Reclaimed, unadvanced `prepared` route transactions now exit 0 so the same
    invocation can republish and launch; typed route refusals remain only for
    bindings that remain durable.
  - Route digest input is now the trailing named option
    `--route-digest <64-hex>` for `publish` and `recover`.
  - The prior-key guard runs only for a route-digest recovery, preserving
    digest-absent legacy recovery. The dead digest-less `prepare` mode was
    removed.
- `toolkit/scripts/__tests__/admission-recover.smoke.sh` is new and covers
  matching/mismatched normal and integrated bindings, unbound current
  singleton, reclaim-before-advance, prior-key legacy recovery, and
  digest-independent `recover-lock` reclaim.
- `toolkit/scripts/lib/route.cjs` and `toolkit/scripts/route.sh` are new,
  untracked pure-selector scaffolding. `decide` has no filesystem, subprocess,
  Git, clock, telemetry, or network dependency. It admits only the exact
  existing allocator tuple through a bounded v1 `{ "from": "model_alloc" }`
  policy and returns a deterministic digest over canonical demand, stable offer
  identity, policy, and decision.
- `toolkit/scripts/__tests__/route.smoke.sh` is new and covers deterministic
  admission, expired offers, and literal-candidate refusal.
- Root `AGENTS.md` was condensed to 72 lines. It retains product/dispatch/test
  contracts and adds scoped-read/context-hygiene rules. The release-contract
  literal for Matt development skills remains present.

### Verification completed after these changes

- `bash toolkit/scripts/__tests__/route.smoke.sh` — passed.
- `bash toolkit/scripts/__tests__/admission-recover.smoke.sh` — passed.
- `bash toolkit/scripts/__tests__/redispatch-check.smoke.sh` — passed.
- `bash .github/tests/release-contract.smoke.sh` — passed.
- `git diff --check` — passed.

### Still incomplete — do not call routing implemented

The selector is not wired into dispatch. No host-state policy
install/deactivate/read path exists yet, no policy eligibility runs before the
allocator/probe, and no selected digest is passed through `dispatch-core.sh`
to `recover`/`publish`/`commit`. Receipt, telemetry, schemas/fixtures,
installation coverage, playbook/README/STATUS sync, and the required final
Opus review remain outstanding. Do not commit, push, merge, or discard the WIP
without completing those items and re-running the applicable gates.

---

## Model-routing WIP continuation — 2026-07-26 (latest)

### State to preserve

- Branch is still `feat/model-routing-admission` at `dbea700`; **nothing in
  this WIP has been staged, committed, pushed, or merged**.
- Keep all pre-existing untracked design/handoff files plus the new untracked
  routing files. Do not reset or discard the worktree.
- Current modified tracked files are `AGENTS.md`,
  `toolkit/scripts/dispatch-core.sh`,
  `toolkit/scripts/lib/admission-recover.cjs`, and
  `toolkit/scripts/__tests__/cmux-dispatch.smoke.sh`.

### Implemented since the previous entry

1. `toolkit/scripts/lib/route-policy.cjs` is a new host-only policy lifecycle
   module. `route.sh policy install|read|deactivate` stores policy snapshots in
   `${AGENT_WORKFLOW_HOST_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-workflow}/repos/<sha256(realpath(GIT_COMMON_DIR))>/routing-policy`.
   Installation validates the bounded v1 policy, content-addresses exact
   bytes, writes the snapshot through temp+rename (`0444`), and atomically
   publishes/removes `active.json`. Read rejects symlinks, non-regular,
   group/other-writable, oversized, and digest-mismatched files as
   `route_policy_invalid`; a missing pointer is `{"status":"bypass"}`.
2. `dispatch-core.sh` now derives Git-common-dir and reads host policy only for
   non-dry-run, allocator-owned implementation writes. No policy, a manually
   supplied `--model` or `--effort`, and dry-run skip policy inspection.
   An active policy rejects each initial-write tier as stdout-only
   `route_mode_unbound` before either allocator or remote compatibility probe.
3. For an active canonical redispatch, `dispatch-core.sh` constructs the
   canonical demand after existing redispatch/prompt admission, derives a
   static runtime offer, calls pure `route.sh decide`, runs the existing model
   compatibility preflight only after an admitted decision, and passes the
   resulting route digest to recovery/publication while holding the issue lock.
   Typed recovery refusal stdout is retained rather than discarded.
4. Worker launch scripts now `unset AGENT_WORKFLOW_HOST_STATE`; host policy
   location is not forwarded to workers.
5. `route.cjs` accepts an optional exact-byte policy digest for binding; the
   host snapshot digest now participates in the selected route digest.

### Tests added and observed results

- `route.smoke.sh` now covers install/read and exact-byte host snapshot digest,
  as well as the existing selector cases. It passed.
- `admission-recover.smoke.sh` passed (eight binding/reclaim/legacy cases).
- `cmux-dispatch.smoke.sh` now exercises active-policy initial writes for
  `trivial`, `standard`, and `full_cluster`, plus manual-tuple and dry-run
  bypass. All new cases printed `ok` in the run. A later full-suite invocation
  did not reach its final summary in the captured terminal session; rerun it
  once from the beginning and require `ALL CASES PASS` before treating the
  suite as green.
- `redispatch-check.smoke.sh`, `.github/tests/release-contract.smoke.sh`,
  `git diff --check`, `bash -n toolkit/scripts/dispatch-core.sh`, and Node
  syntax checks for `route.cjs`/`route-policy.cjs` passed.

### Resume order

1. Re-read this handoff and inspect `git status --short`, then rerun the full
   `cmux-dispatch.smoke.sh` until its terminal `ALL CASES PASS` is captured.
2. Add one focused canonical-redispatch integration case proving an active
   policy writes the same route digest to its authoritative ordinal admission
   record (and paired integrated singleton), while no-policy/manual/dry-run
   records remain digest-free.
3. Audit the route-policy filesystem seam for all required refusal cases:
   host root inside worktree/common-dir, active/snapshot symlink, unsafe mode,
   oversize file, and pointer/name/content digest disagreement.
4. Implement the still-deferred receipt v3, telemetry v2, schemas/fixtures,
   install/release coverage, and playbook/README/STATUS sync. Do not add
   initial-write routing, provider switching, availability inventory,
   fallback, ranking, or policy mutation.
5. Run all affected gates and obtain the required final independent Opus
   read-only review. Only then consider staging/commit; no push/merge without
   separate explicit authorization.

---

## Model-routing WIP resumed — 2026-07-26

### Completed in this continuation

1. Re-ran `cmux-dispatch.smoke.sh` from the beginning and captured its terminal
   `ALL CASES PASS` result.
2. Added a focused canonical-redispatch integration fixture. With an active
   host policy, it proves the same 64-hex `route_digest` is written to the
   authoritative ordinal transaction and the paired `integrated_fix` recovery
   companion. The ordinary no-policy fixture now explicitly proves its durable
   admission record remains digest-free.
3. Expanded `route.smoke.sh` to cover the host-policy filesystem seam:
   configured host roots inside the worktree or Git common dir, oversize input
   and active pointer, active/snapshot symlinks, group-writable pointer or
   snapshot, and pointer/name/content digest disagreement all refuse as
   `route_policy_invalid`.

### Fresh verification

- `bash toolkit/scripts/__tests__/route.smoke.sh` — `ALL CASES PASS`.
- `bash toolkit/scripts/__tests__/admission-recover.smoke.sh` — `ALL CASES PASS`.
- `bash toolkit/scripts/__tests__/redispatch-check.smoke.sh` — `ALL CASES PASS`.
- `bash toolkit/scripts/__tests__/cmux-dispatch.smoke.sh` — `ALL CASES PASS`.
- `bash .github/tests/release-contract.smoke.sh` — `ALL CASES PASS`.

### Commits made after explicit authorization

- `0b2b6d8 feat(workflow): bind opt-in routing admission` — design authority,
  host-only policy lifecycle, pure selector, early mode classification, and
  atomic route-digest admission binding.
- `d3f9f4f feat(workflow): record routed receipt provenance` — schema v3
  transport receipts for policy-routed canonical redispatches only; receipt
  publication cross-checks the host ordinal binding and integrated companion,
  with fixtures, install/release coverage, and product-doc sync.

### Exact pause state

- Branch: `feat/model-routing-admission` at `d3f9f4f`.
- Tracked worktree: clean. `HANDOFF.md` is intentionally the only untracked
  file; do not add it to a commit.
- Receipt-slice checks passed: `cmux-dispatch.smoke.sh`,
  `runtime-provenance-schema.smoke.sh`, `orchestrator-interface.smoke.sh`,
  `install-into.smoke.sh`, and `release-contract.smoke.sh`.

### Next implementation slice

Telemetry v2 provenance remains: collector validation must derive the salted
route pseudonym and runtime/model/effort from a valid v3 receipt plus matching
host binding, not telemetry CLI values; the reporter must accept v1/v2 but
form policy cohorts from v2 only. Add the corresponding schemas/fixtures,
installation/release coverage, and docs. Keep the existing scope lock:
receipts and telemetry are derivative only, and do not add initial-write
routing, availability inventory, fallback, ranking, or policy mutation. Run
one final independent Opus read-only review only after that slice and its gates
are complete; no push or merge without separate explicit authorization.

---

## New-issue Sol review + external scorecard research — 2026-07-27

### Current repository state

- Checked current `main` at `d2dae78`; do not treat the earlier
  `feat/model-routing-admission` pause state above as current branch state.
- `HANDOFF.md` remains intentionally untracked and must not be committed.
- The only additional untracked file from this investigation is
  `docs/research/2026-07-27-external-model-scorecard-sources.md`.
- No issue implementation, schema change, policy change, commit, push, or
  GitHub comment was made in this pass.

### Sol medium review of newly opened issues

The review was read-only against the current code, issue bodies, and narrow
smokes. Its recommended order is two independent dependency chains:

1. **#61 — P1, confirmed.** `cmux workspace create` emits plain
   `OK workspace:<id>` while `cmux-handles.cjs` expects JSON. The dispatcher
   can falsely exit after creating a live worker. Parse the returned stable
   handle/ref directly and add a fixture with real plain create output; do not
   resolve identity by workspace name after creation because duplicate names
   and races break the proof contract.
2. **#63 — diagnostic gate after #61.** The observed stale `RUN.json` is real,
   but the normal watchdog path writes `exited` after a successful child exit.
   After #61, run one isolated real launch and retain child/watchdog PID and
   exit timing plus RUN mtime/attempt/role for at least one poll interval. Only
   fix a confirmed cause. Do not promote RUN state to completion authority or
   change schemas pre-emptively.
3. **#62 — P1 policy decision required.** An ignored target installation is
   absent from a new linked worktree. Current adoption guidance (reinstall in
   each sibling) conflicts with the README's worktree-local relative-path
   workflow. Choose one authority before implementation: self-contained
   per-worktree installation, or one host-owned product home. The acceptance
   fixture must prove the official procedure can render/check and dry-run in a
   fresh linked worktree, preserves worktree-local `.review`, states config
   precedence, and fails closed for missing/moved/tampered product home.
4. **#64 — P2 after #62.** Missing output-contract guidance is a confirmed UX
   defect. Once the product-home rule is fixed, error output must give the
   effective role, usable script/prompt paths, render/check commands, valid
   roles, and separate missing from duplicate/drift recovery. Add stderr
   assertions; do not advise blind append for duplicate/drift.

The narrow existing smokes passed (`orchestrator-interface`, `codex-watchdog`,
`prepare-worktree`, and `output-contract`), but they do not prove actual plain
cmux create output, an actual cmux terminal lifecycle, sibling-worktree
installation, or actionable stderr. Those are the required new checks.

### External-source scorecard and routing enhancement

Research note: `docs/research/2026-07-27-external-model-scorecard-sources.md`.

It is feasible to add missing models and make routing evidence more useful,
but not by blending all sources into one timeless score or calling external
APIs from dispatch. Build an offline, maintainer-reviewed, versioned scorecard
whose observations retain:

`provider_model_id`, optional verified `runtime_model_id`, provider, observed
date, source and release, benchmark/domain/metric/value/unit, effort,
prompt-or-agent-scaffold, price/latency basis, verification status, terms URL,
evidence URL, and import digest.

- Artificial Analysis can expand the commercial/open model catalog with
  authenticated API metadata, benchmark, price, and latency data; verify plan
  and redistribution terms before committing a snapshot.
- LiveBench is the static coding/reasoning lane; preserve its release,
  category, prompt, and harness rather than mixing releases.
- SWE-bench and any FrontierCode-style result are agent-system observations,
  not bare-model capability scores; retain scaffold and evaluator version.
- ARC is an auxiliary reasoning lane, LMArena is a dated preference/UX
  tie-breaker, and Vellum-style evaluations are for local canary/AC outcomes.
  Keep source-native scales separate and preserve unknown values explicitly.
- First-party provider docs are authoritative for model IDs, effort/tool
  support, and provider pricing, but local runner availability remains owned
  by runtime compatibility preflight.

Recommended evolution:

1. Offline immutable source snapshot and normalized catalog.
2. Offline scorecard view with separate coding, reasoning, agentic coding,
   preference, price, latency, tool/context, and local-outcome lanes.
3. Human-reviewed project allowlist and `model-alloc.json` refresh.
4. Existing opt-in telemetry cohorts as advisory validation of already eligible
   tuples: complete-green rate, retries, wall time, and observed/estimated cost.

Do not change v1 dispatch boundaries: no live benchmark/price lookup, alias
discovery, automatic cross-provider routing, automatic fallback, predictive
ranking, or telemetry-driven policy mutation. `model-alloc.sh` remains the
authoritative selected tuple; host-pinned policy and runner compatibility
remain the admission authorities.

### Orca cleanup

- The read-only Sol terminal tab `review-new-issues-sol-medium` was closed.
- No child worktree was created, so no filesystem worktree was removed.
- The main checkout and unrelated Orca sessions were preserved.

---

## Open-issue Orca coordination pause — 2026-07-27

### Exact pause state

- Branch remains `main` at `d2dae78`; no commit, push, merge, issue close, or
  GitHub comment was made. `HANDOFF.md` and the prior untracked skill/research
  files remain intentionally untracked.
- Orca is the coordination record. The coordinator terminal is
  `term_2f745bd8-6458-472e-a2c7-3fcefdd4f0f1`; all dispatched tasks recorded
  completion except later required Sonnet/Opus verification cycles for #62,
  #63, and #64.
- `git diff --check` was clean at the last coordinator check. Do not reset,
  stash, checkout, or clean this shared dirty checkout. An initial Sonnet
  verifier attempted `git stash`; it was stopped and the immediately-created
  stash was popped successfully. The replacement review was read-only.

### #61 — complete locally, not GitHub-closed

- `cmux-handles.cjs` now accepts actual `OK workspace:11` create output and
  preserves the full external ref `workspace:11`; JSON id/ref compatibility
  and missing/ambiguous/invalid/name-only rejection remain covered.
- `orchestrator-interface.smoke.sh` passed and two scoped Opus 5 reviews
  accepted the final diff. The prevention constraint is: fixture the real
  plain-text output and preserve the exact externally returned ref, never a
  display name or stripped fragment.

### #62 — implementation plus integration correction complete; review pending

- Chosen convention: the installed checkout's absolute
  `.agent-workflow` directory is `PRODUCT_HOME`. Invoke its scripts from any
  linked worktree and pass the linked checkout only with `--worktree`;
  `workflow-config.json` and `model-alloc.json` live in PRODUCT_HOME while
  prompt and `.review` paths stay worktree-local.
- Installer/worktree coverage proves a fresh ignored linked worktree lacks
  `.agent-workflow` yet PRODUCT_HOME render/check/config-driven dry-run works.
  A real #62-caused `cmux-dispatch.smoke.sh` mismatch was repaired by making
  its fixture use a copied PRODUCT_HOME allocation, not a worktree-local one.
- The last implementation task reported that `cmux-dispatch.smoke.sh` and
  `orchestrator-interface.smoke.sh` were green; `install-into.smoke.sh` had a
  retained-runner assertion failure requiring a fresh scoped rerun before
  claiming #62 complete. Next prevention constraint: never reintroduce a
  worktree-relative `.agent-workflow` script/config/allocation path.

### #63 — no implementation justified yet

- After #61, isolated `codex-watchdog.smoke.sh` and
  `agent-watchdog.smoke.sh` success paths passed and wrote terminal markers;
  the observed stale `RUN.json.status:"running"` was not independently
  reproduced. RUN remains liveness/termination evidence, never completion
  authority.
- Before closing this cycle, run one controlled real cmux worker after the
  #61 handle proof, retain child/watchdog PID and exit timing plus fresh RUN
  bytes/mtime/attempt/role, and only change `agent-watchdog.sh` if that
  reproduction leaves `running` after the PID is absent. Do not change schema,
  retry, stall, dispatch polling, or completion semantics speculatively.

### #64 — implementation complete; review pending

- Output-contract admission now names the required role and emits shell-safe,
  absolute PRODUCT_HOME `render` and `check` recovery commands pointing at the
  worktree prompt. `output-contract.sh` usage lists and enforces
  `implementation|reviewer|architect|conductor|release`.
- `output-contract.smoke.sh`, Bash syntax checks, and diff check passed. The
  prior cmux-dispatch failure was #62's allocation-fixture mismatch, not #64.
  Prevention constraint: recovery commands must be PRODUCT_HOME-absolute while
  prompt files remain worktree-owned.

### Resume order

1. Re-run `bash toolkit/scripts/__tests__/install-into.smoke.sh` and capture
   the exact retained-runner result; do not mask an intermittent failure.
2. Complete Sonnet independent verification and scoped Opus 5 review for #62
   with only its attributable diff and focused evidence. Correct only an
   acceptance-mapped or #62 changed-surface regression.
3. Execute the bounded #63 real cmux lifecycle reproduction above; if it does
   not reproduce, record no implementation and obtain Sonnet + scoped Opus
   confirmation of that closure.
4. Complete Sonnet independent verification and scoped Opus 5 review for #64
   using only its stated diagnostic/usage acceptance criteria and focused
   evidence.
5. Run final `git diff --check`, preserve all untracked files, report
   per-issue evidence and deferred follow-ups. Do not commit, push, merge, or
   close any GitHub issue without fresh explicit authorization.

## Open-issue cycle update — 2026-07-27 (resumed)

- User approved resumption and commits. Work now continues on
  `fix/open-issues-61-64`; no commit, push, merge, GitHub comment, or issue
  closure has occurred. Preserve the existing untracked files.
- #62: `install-into.smoke.sh`, `cmux-dispatch.smoke.sh`, and
  `orchestrator-interface.smoke.sh` now pass after the fixture was narrowed to
  the one PRODUCT_HOME allocation assertion. Sonnet independently confirmed
  those commands and `git diff --check`. An Opus review found two stale README
  worktree-relative examples; Terra corrected only those hunks. Sonnet's
  follow-up is green. A follow-up scoped Opus review remains required because
  the attributable diff changed.
- #63: a real controlled cmux attempt was made after #61 using a temporary
  Git worktree and a zero-exit Codex-shaped runtime. cmux 0.64.20 is installed,
  but this Orca worker is not cmux-hosted, so create/list fail before runner or
  RUN creation with `Access denied - only processes started inside cmux can
  connect`. The retained evidence is `/tmp/issue63-cmux.tviCkm`.
  `codex-watchdog.smoke.sh` independently passed normal-exit terminal-marker
  cases. No #63 code change is justified; the scoped Opus review agrees but
  requires this durable record and explicitly leaves the detached-in-cmux
  path unexercised. Prevention constraint: do not claim RUN completion from
  status alone; reproduce from a cmux-hosted process before changing liveness
  or terminal-state behavior.
- #64: Sonnet independently confirmed `output-contract.smoke.sh` and
  `git diff --check`, including named-role recovery commands and role usage.
  It awaits final scoped Opus review only after #62's follow-up review.

### Final cycle handoff — 2026-07-27

- #61 complete locally in `49b7da8` (`(workflow) fix cmux create handle proof
  (#61)`). Evidence: `orchestrator-interface.smoke.sh` passed; Sol scope,
  Sonnet verification, and two scoped Opus reviews accepted. Prevention:
  preserve a real plain-text create ref exactly, never a stripped id/name.
- #62 complete locally in `c7c9565` (`(workflow) fix installed product-home
  worktree paths (#62)`). PRODUCT_HOME is the installed `.agent-workflow`;
  linked worktrees supply only target/review paths. Evidence: install, cmux
  dispatch, and orchestrator smokes passed; Sonnet reran them after the README
  correction; final scoped Opus accepted. Prevention: no user-facing command
  may assume `.agent-workflow` exists in a fresh ignored worktree.
- #63 complete as a constrained no-change cycle. A real cmux attempt after
  #61 could not reach a worker because this Orca terminal is not cmux-hosted
  (`Access denied - only processes started inside cmux can connect`); no RUN
  artifact was created. `codex-watchdog.smoke.sh` passed normal-exit terminal
  markers, Sonnet independently confirmed, and scoped Opus accepted the
  no-change decision. Limitation/deferred follow-up: perform the detached
  lifecycle reproduction from a cmux-hosted process before asserting field
  parity; do not infer completion from RUN state alone.
- #64 complete locally in `ff113be` (`(workflow) make output-contract recovery
  actionable (#64)`). Evidence: output-contract smoke passed; Sonnet and
  scoped Opus accepted named-role, PRODUCT_HOME recovery commands, and valid
  role usage. Prevention: recovery guidance must keep tool paths in
  PRODUCT_HOME and prompt paths in the worktree.
- No push, merge, GitHub comment, or GitHub issue closure occurred. All prior
  untracked skill/research/handoff files remain untracked.

---

## Open issues #70/#71 completion and Orca receipt follow-up — 2026-07-29

### Current branch and delivery evidence

- Branch: `feat/dispatch-evidence-test-shape`, based on `main` at `037be30`.
- #70 is committed locally as `f7b71b2` (`(workflow) document redispatch
  evidence collection (#70)`). The commit adds host-side, failure-class-specific
  evidence collection after failed VERIFY/REVIEW and requires verbatim evidence
  in the next implementation prompt. `completion-check.sh` passed and a fresh
  Orca/Codex reviewer published final PASS at
  `.review/ISSUE-70-REVIEW-f7b71b20c53a5ed74df6b453f1e0e2e199bacc84.json`.
- #71 is committed locally as `9aee479` (`(workflow) document dispatch test
  shape (#71)`). The two authoritative documents now require the applicable
  highest-privilege happy path first, seed-relative assertions for shared state,
  distinct expected values for independently wired keys, and rejection of tests
  that do not execute the code under review. `completion-check.sh` passed and a
  fresh Orca/Codex reviewer published final PASS at
  `.review/ISSUE-71-REVIEW-9aee47980da4d54b8b81eb3053d587f724280df8.json`.
- `git diff --check` passed before each commit. Do not claim canonical VERIFY:
  these are documentation-only workflow changes, and only completion +
  independent REVIEW were run.
- No push, merge, GitHub comment, or GitHub issue closure has occurred. #70 and
  #71 remain open on GitHub pending explicit publication/closure authority.

### New spec ticket: #72

- GitHub issue #72, `Orca transport receipt must store the terminal handle, not
  the create request ID`, was created from a live Orca reproduction.
- The actual `orca terminal create --json` response has top-level request `id`
  and the re-queryable terminal identity at `result.terminal.handle`.
  `toolkit/scripts/adapters/orca.sh` currently accepts top-level `id`, so the
  transport receipt stores an unqueryable identifier and
  `agent-workflow.sh inspect` immediately returns `lifecycle:"stale"` for a
  live Orca terminal.
- `orchestrator-interface.smoke.sh` passes but its fake create/list responses
  reuse a synthetic field/value, so it does not cover the real nested response
  shape. #72 acceptance requires the actual nesting, strict missing/ambiguous
  refusal, and no cmux/shared-core behavior change.

### Next safe action

1. With explicit publication authority, inspect `main...feat/dispatch-evidence-test-shape`,
   push the two commits, and open a PR; do not close #70/#71 without explicit
   confirmation.
2. Start #72 as a separate Standard issue: scope `orca.sh` normalization and
   `orchestrator-interface.smoke.sh` only, preserve cmux behavior, and use a
   real create-response fixture with `id` plus `result.terminal.handle`.
3. Preserve all existing untracked files and `.review/ISSUE-*-launch.*`
   runners; do not reset, clean, stash, or delete them.

---

## #76 merged; #77 is next P0 — 2026-07-31

### Delivery record

- #76 (`generic install ships target-verify.sh without its lib dependency`) is
  closed through PR #85. The local implementation commit was
  `07432e1 fix(workflow): ship generic verify artifact validator`; GitHub
  merged it as `e4264e6cc2c5bfdcae3bf29a8fe285ae027c567a`.
- The fix extracts the target-neutral VERIFY semantic validator into
  `toolkit/scripts/lib/verify-artifact.cjs`, ships it in the generic profile,
  keeps the FeedbackOps Vitest classifier excluded, and updates target verify,
  candidate closure, and telemetry consumers. It adds an installed-generic
  execution regression case plus release-contract coverage.
- Local gates passed before publication:
  `bash toolkit/scripts/__tests__/target-verify.smoke.sh`,
  `bash toolkit/scripts/__tests__/install-into.smoke.sh`, and
  `bash .github/tests/release-contract.smoke.sh`. Both GitHub Actions `smoke`
  runs for PR #85 passed.
- The independent Sol canonical review was final PASS at
  `/Users/hyojung/Desktop/2026/feedbackops-workflow-issue-76/.review/ISSUE-76-REVIEW.json`.
  The temporary #76 worktree and its launch runners remain; do not delete them
  merely for cleanup.

### Model-routing evidence and next issue

- The requested final Claude review was dispatched through the public Orca
  path with the literal alias `--model opus`; admission succeeded without
  rewriting it to a version-specific model. The Claude reviewer then ended
  `status:"refused"` while publishing canonical REVIEW evidence, reproducing
  #77's runtime publication defect. No Opus result was treated as evidence.
- #77 is now open and labeled `P0`, `ready-for-agent`:
  `claude runtime --produce-review always refuses: text output vs whole-stdout
  JSON.parse, and the output is discarded`.
- Next session must start #77 from its GitHub acceptance matrix. Keep the
  user-approved sequence: Terra implementation, Sol independent review, then
  one final Opus review via the `opus` alias. Scope the repair to non-Codex
  review-output transcription/diagnostics and its smoke coverage; do not
  broaden into model allocation or general routing work.

### Checkout safety

- Root `main` is currently behind `origin/main` by two commits and retains
  user-owned untracked files (`HANDOFF.md`, skills/config directories,
  research, and historical `.review/ISSUE-70/71-launch.*` runners). First
  re-check status, fetch, and fast-forward only after confirming those paths
  cannot conflict. Never reset, stash, clean, or delete them.
- #76 push, PR merge, and closure are complete. No push, PR, merge, or issue
  closure is authorized for #77 until freshly requested.

---

## #77 implemented, reviewed, published, and closed — 2026-07-31

### Delivery record

- Implementation lives in the isolated Orca worktree
  `/Users/hyojung/orca/workspaces/feedbackops-workflow/issue-77-review-transcription`
  on `fix/issue-77-review-transcription`, based on `origin/main` at
  `e4264e6cc2c5bfdcae3bf29a8fe285ae027c567a`.
- Commit `d38b227 (workflow) fix non-codex review transcription` is pushed to
  `origin/fix/issue-77-review-transcription`.
- Draft PR #86 is open against `main`:
  `https://github.com/hjung3113/feedbackops-workflow/pull/86`.
  It is not merged; live GitHub state showed `isDraft:true`, `state:OPEN`, and
  `mergeStateStatus:UNSTABLE` at this handoff.
- Issue #77 was commented with delivery evidence and closed as `completed`:
  `https://github.com/hjung3113/feedbackops-workflow/issues/77`.

### Delivered scope

- Non-Codex `--produce-review` accepts either whole-buffer JSON or the last
  parseable fenced `json` block, then sends that unchanged candidate through
  the existing schema, producer, issue, live-HEAD, and atomic-publication
  gates.
- Every non-Codex REVIEW refusal retains raw stdout only as the
  non-authoritative `ISSUE-N-review-attempt<K>-output.log` diagnostic and
  records a typed `refusal_reason` in RUN.
- Codex REVIEW-marker behavior remains unchanged. Regression coverage proves
  the later-invalid-fence fallback, publication-conflict diagnostics, and
  absence of a Codex refusal reason.
- Changed paths are limited to `agent-watchdog.sh`, its two focused smoke
  suites, `run.schema.json`, and synchronized product documentation.

### Review and verification

- Terra implemented the scoped fix. Sol's diff-and-purpose-only review found
  three in-scope defects (publication-failure diagnostics, last-parseable
  fenced-block selection, and Codex-marker drift); Terra remediated all three.
- Final Claude Code review using the literal `opus` alias was `ACCEPT` with no
  purpose violations. Its only note was a non-blocking, out-of-scope wording
  omission about non-Codex implementation BLOCKER watchers; do not reopen #77
  for it without explicit scope.
- Passed locally after the remediation:
  `bash toolkit/scripts/__tests__/agent-watchdog.smoke.sh`,
  `bash toolkit/scripts/__tests__/review-publish.smoke.sh`,
  `bash toolkit/scripts/__tests__/runtime-provenance-schema.smoke.sh`, and
  `git diff --check`.

### Next safe action

1. Review PR #86 and its GitHub checks. If publication is accepted, explicitly
   mark it ready and merge; do not assume the closed issue implies a merged PR.
2. Keep root `main` and its user-owned untracked files untouched until a
   deliberate fast-forward is authorized. Do not delete the #77 or #76 Orca
   worktrees/runners merely as cleanup.

---

## #79 implemented, independently accepted, and published as Draft PR — 2026-08-01

### Delivery record

- Issue #79 fixes target-native test discovery counts in `completion-check.sh`.
  Implementation was completed in the now-removed isolated #79 Orca worktree;
  its branch remains available remotely as `hjung3113/issue-79-test-discovery`.
- Commit `0d01010 (workflow) fix target-native test discovery count (#79)` is
  pushed. Draft PR [#89](https://github.com/hjung3113/feedbackops-workflow/pull/89)
  targets `main`; its live state at this handoff is `OPEN`, `isDraft:true`,
  `mergeStateStatus:CLEAN`, with both GitHub `smoke` checks successful.
- Issue #79 remains open. Its PR body contains `Closes #79`, so it should close
  automatically only after the PR is merged.

### Delivered scope

- `contract.test_count` is an optional `pattern`/`group` extractor in the
  ROUND-STATE schema. When it is omitted, the existing non-empty-line count
  remains unchanged; when present, it supplies the count while AC-ID matching
  continues to inspect raw discovery output.
- Invalid regex, no match/capture, non-integer, and non-positive extracted
  values fail closed. Failed discovery now exposes bounded UTF-8-safe combined
  output, exit code, and truncation status.
- Source and portable generic-install smoke coverage exercise both the legacy
  fallback and TAP-style extractor paths. Documentation and the product skill
  describe the contract consistently.
- Explicit exclusions: target-profile integration, runner-specific parsers,
  routing/dispatch changes, installer behavior, dependencies, and schema-version
  changes.

### Review and verification

- Terra implemented the scoped change and a follow-up generic-install coverage
  repair. Independent Sol review requested that repair, then returned `ACCEPT`.
- Final Claude review via the literal `opus` alias returned `ACCEPT`. It noted
  only a non-blocking fixture wording mismatch; do not reopen #79 for it without
  explicit scope authorization.
- Passed: `completion-check.smoke.sh`, `install-into.smoke.sh`,
  `run-all.sh` (36/36), `run-all-contract.test.sh`,
  `.github/tests/release-contract.smoke.sh`, and `git diff --check`.

### Cleanup and next safe action

- The #79 Orca worktree and the tabs opened for its Terra, Sol, and Opus work
  were removed at the user's request after PR publication. Do not recreate or
  delete other worktrees as cleanup.
- Before any next action, live-check PR #89, issue #79, and root Git status.
  Marking the PR ready, merging it, closing the issue manually, or
  fast-forwarding the root checkout requires explicit authorization. Preserve
  root user-owned untracked files (`HANDOFF.md`, skills/config directories,
  historical launch runners, and research) unchanged.
