# Current state — #212, #155, #150, #149 closed; main clean, pushed (2026-08-28)

Prior entry archived to `docs/handoff-archive/2026-08-27-issue212-149-150-155-closed.md`.
Full history lives in `docs/handoff-archive/`. This file only ever holds the single most
recent entry — do not append; move THIS entry's content to a new dated archive file when
the session ends, then replace this file with only the new entry. Re-check `git status
--short --branch`, `git log -5 --oneline --decorate`, `gh issue list --state open --limit
50`, `gh pr list --state open`, `git worktree list` before trusting anything below — this
entry is a snapshot, not a plan.

## What happened this session

User asked to clear the remaining priority-list backlog in one session, running as many
issues in parallel as the file/scope boundaries allowed, with each issue going through an
explicit 4-stage pipeline: **design → independent review → implementation → verification**,
orchestrated by CONDUCTOR rather than raw ad hoc dispatch.

Split the 4 remaining open issues into 3 independent herdr worktrees by file/scope overlap:

- **Track A — #212** (herdr trust-prompt-blocked launch has no working detection path)
- **Track B — #155** (wire codex/opencode progress-event streaming, phase B of #142) —
  largest scope, kept alone
- **Track C — #149 + #150** (both design proposals land in
  `toolkit/docs/agents/multi-agent-workflow.md`, so sequenced in one worktree/branch to
  avoid a same-file merge conflict rather than run fully parallel)

Each track ran: **design** (`gpt-5.6-sol high` via herdr/codex, design-only, no code edits,
writes `DESIGN-NOTES-*.md`) → **independent review** (Opus, via `Agent` tool,
`general-purpose` subagent — a judgement role kept off codex per this repo's own
model-routing rule "never let the writer grade its own output") → **implementation**
(`gpt-5.6-luna max` via herdr/codex, applying the design plus every reviewer-required fix)
→ **verification** (Opus again, independently re-running the actual diff's smoke commands,
not trusting the implementer's self-report) → commit → rebase-and-merge to `main` → push →
`gh issue close` with a summary comment → worktree cleanup.

All 3 reviews came back **APPROVE WITH CHANGES** (not clean first-pass), and all
reviewer-required fixes were folded into the implementation briefs before dispatch:

- **#212**: root-caused as Herdr 0.8.0 (installed version) simply not implementing the
  fixed `agent start` trust-prompt lifecycle yet (confirmed against real upstream
  herdrdev/herdr#2410 and its fix PR #2537 — not a regression worth a new upstream report).
  `herdr_trust_race_proven` now launches its sentinel through `agent start` (the actual
  `launch_live` production path) instead of `pane run`, whose shell command-echo defeated
  herdr's own `\A`-anchored `codex` trust-directory detection rule. Every classification
  branch returns false, so herdr's live capability stays unavailable per ADR 0007's T5 gate
  — a root-cause characterization, not a capability change. Reviewer-required fixes folded
  in: accepted-cost comment for the now-constant-false predicate, reused
  `parse_adapter_error` for stdout-then-stderr parsing, sentinel cleanup on the
  retained-agent branch, runtime-emitted sentinel first line via `printf` (not
  heredoc-interpolated), deterministic probe-name prefix to avoid smoke-harness collisions.
  Merged `c19d1fb`. Full suite 39/39 green.
- **#155**: live-verified real incremental Codex NDJSON delivery (codex-cli 0.150.1, real
  timestamped transcript, ~3-4s between `item.completed` events, before the terminal
  `agent_message`) — flipped `PROGRESS.codex.streams` to `true` and threaded `--json`
  through both independent Codex argv owners (`runtimes/codex.sh` direct read path, and all
  three `runtimes/codex-safe.sh` exec builders: review/write/write-with-extra), preserving
  `--output-last-message` as the canonical review authority. Also discovered mid-design that
  the issue's own file paths were stale — `agent-runtime.sh` is now (per ADR 0006) a
  runtime-neutral router with no Codex branch, not the file to touch. OpenCode's known
  upstream container-only event-drop bug (opencode#31435) did **not** reproduce on this
  host shape across 3 live multi-tool runs through the real dispatch path, so
  `PROGRESS.opencode.streams` stays `true` with no wall-clock-exception design added — but a
  new truncated-NDJSON smoke was added so OpenCode still fails closed if the terminal event
  is ever missing. Reviewer-required fixes folded in: added missing
  `smoke-coverage.manifest` rows (the design's own claim that "no manifest edit is needed"
  was wrong — none of the changed files selected `agent-watchdog.smoke.sh` or
  `conductor-control.smoke.sh`, the very smokes the design depends on), and a real combined
  `--json` + `--output-last-message` probe (verified they compose cleanly) before wiring the
  review builder. Merged `be577a8`.
- **#149 + #150**: formalized as docs. #149 — dispatch ownership (delegated Implementation
  vs. CONDUCTOR direct-edit) is documented as an axis independent of Risk Tier, with a
  narrow explicit-eligibility exception (small/mechanical/no-regression-surface changes)
  that preserves branch/PR/verification cadence unchanged and leaves the existing
  Trivial/Standard/Full-Cluster ROUND-STATE tier system untouched. #150 — documents that
  under the Orca transport, the runtime-issued terminal handle already recorded in the
  transport receipt may be inspected via `orca terminal show`/`orca terminal read` as an
  *auxiliary* liveness diagnostic alongside RUN/BLOCKER freshness, never replacing it as
  completion authority; also states the general adapter principle (check for a native
  platform primitive before re-implementing behavior across a split axis). Reviewer caught
  that the design's own new dispatch-ownership exception left the playbook
  self-contradicting two other spots that still said an absolute "READ-ONLY on product
  code" / "never edit source files" (`multi-agent-workflow.md`'s CONDUCTOR non-negotiable
  rules and Release Captain section) — both qualified, plus a stale pointer string in
  `toolkit/scripts/install-into.sh` (baked into every installed CLAUDE.md) was updated to
  match the new §2 framing rather than left to rot. Merged `1e0e639`.

Operational hiccups worth knowing about, not toolkit defects: codex's own auto-update
prompt (`npm install -g @openai/codex` via oh-my-zsh's update nag racing the first
keystroke) killed 2 of the first 3 design-stage dispatches and required a restart per
track; separately, `herdr pane run wX:p1 "exit"` typed into a *live codex TUI* (not a bare
shell) closed the entire root pane/workspace for all 3 tracks when switching from
design-tier (`sol high`) to implementation-tier (`luna max`) models — recovered via `herdr
worktree open --path <path>` to reopen each worktree in a fresh pane, no data lost since
nothing had been committed yet. Lesson for next time: exit a live codex TUI with `/exit` or
`ctrl+c` then a genuine idle-shell check, not a blind `pane run "exit"`.

Merge ordering caveat: because the 3 tracks were built as sibling worktrees off the same
base commit and landed sequentially (`#155` → `#149/#150` → `#212`), each later branch had
to be `git fetch`+`git rebase` onto the just-updated `main` before its `--ff-only` merge
would succeed — none produced a real conflict (different files/hunks by design), but don't
assume `--ff-only` will just work when merging multiple sibling branches back-to-back.

All 4 issues closed with comments citing their commit + review verdicts. 4 commits landed
on `main` this session: `be577a8` (#155), `1e0e639` (#149, #150), `c19d1fb` (#212).

## 2026-08-29 addendum — herdr live usage clarified (not a code change)

User asked whether herdr TUI is still unusable. Re-ran `herdr --version` (now 0.8.2,
installed via `/Users/hyojung/.local/bin/herdr`, was 0.8.0 when ADR 0007's T5 gate was last
written) and re-ran `herdr_trust_race_proven`'s exact probe manually against the real 0.8.2
binary: `agent start --kind codex` on a synthetic trust-prompt sentinel still returns
`timeout`, and the agent is still lost as `agent_not_found` on the follow-up `agent get` —
same old-contract shape as 0.8.0, upstream herdrdev/herdr#2537 fix still not in 0.8.2. So
`herdr.sh`'s `capabilities --probe-live` still reports no live capabilities, unchanged.

**But this formal gate is not what the user's real herdr usage goes through.** The user's
actual workflow — telling an agent to make a herdr worktree, work hands-off, close it when
done — works fine and always has, because real codex launches never hit the trust prompt in
the first place: `launch_live` pre-seeds codex's own `config.toml` trust store before
`agent start` (#215/#218, real-binary verified 2026-08-24), so the trust-race condition this
probe exists to catch doesn't occur on the actual dispatch path. The probe is a narrow,
deliberately-conservative formal admission check for a different edge case (some *other*
blocking UI mid-launch, not the codex trust prompt) — its `false` result does not mean
day-to-day herdr TUI dispatch is broken.

Net: no code or ADR-decision change from this — `execution_mode=live-tui` for herdr stays
gated per ADR 0007 T5 (correct, since the narrow contract genuinely isn't proven yet). What
was wrong was answering "can I still use herdr TUI" by quoting that gate's `false` value
without checking it against the actual usage path first. Corrected in ADR 0007's herdr
section (see inline 2026-08-29 note there) so this doesn't get mis-read the same way again.

## Next session

Open issues remaining: only **#208** (cmux live-tui adapter's `cmux run` primitive doesn't
exist on real cmux 0.64.x) — **ON HOLD**, do not pick up opportunistically, per prior
archived entries' explicit instruction.

**Unresolved from prior sessions, still not investigated:** dispatching to a fresh `codex`
TUI terminal via `orca terminal create` hit codex's own "Update available" prompt on
launch; `orca terminal send` refused all input (`agent_prompt_blocked` /
`blockedReason: "codex-update-prompt"`). No documented orca-cli workaround found yet.
(This session used herdr exclusively per #217's own rule, and hit a *different* codex
auto-update interaction there — see above — so this orca-specific failure mode is still
unconfirmed either way this session.) Worth filing against orca if it recurs.

**`generic-conductor-persona` worktree still has uncommitted, unmerged work**
(`/Users/hyojung/orca/workspaces/feedbackops-workflow/generic-conductor-persona`, branch
`fix/generic-conductor-persona`, `bd82991`) — this session actually checked it (prior
sessions only flagged it): `git diff main --stat` from that worktree shows **211 files
changed, +5556/-17878 lines** against current `main` — this branch is old enough to predate
the toolkit reorg (it still has since-removed files like `round-state-init.sh`,
`round-state-render-ac.sh`, and pre-split `runtimes/{claude,codex,omp,opencode}.sh` shapes
that don't match current `agent-runtime.sh`'s runtime-neutral-router design from ADR 0006).
It also has 2 uncommitted changes on top: `toolkit/scripts/__tests__/install-into.smoke.sh`
(modified) and a new untracked
`toolkit/scripts/install-profiles/generic/docs/agents/conductor-persona.md`. Asked the user
this session whether to investigate, merge, or discard it — **user chose to defer again**
("이번엔 보류, 핸드오프에만 기록"). Do not silently rebase or merge this — the diff is large
enough that a naive rebase risks reintroducing removed files or reverting since-landed
design decisions (#149/#150/#155/#212 all touch files this branch also touches in older
shapes). Ask the user again before doing anything with it.

With the priority backlog now fully cleared and only an on-hold issue open, the natural
next step is either picking up `generic-conductor-persona` (pending user direction) or
waiting for new issues to be filed.
