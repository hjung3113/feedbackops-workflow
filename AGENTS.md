# Agent Workflow — Agent Guide

This repository builds an opt-in multi-agent development workflow toolkit.
`CLAUDE.md` is a pointer; this file is the repository operating authority.
Read `toolkit/STATUS.md` first, but current scripts, schemas, and `git log`
win if it disagrees. The detailed product playbook is
`toolkit/docs/agents/multi-agent-workflow.md`.

## Read only what the task needs

- Start from the current handoff, issue, or explicitly named file. Use linked
  docs only when they answer an unresolved task question.
- Establish file/heading scope before reading: prefer `rg` and small line
  ranges over full-file dumps. Keep diff, memory, documentation, and source
  inspection as separate bounded reads.
- When memory is relevant, use an exact task term and inspect only the matching
  entry. Do not use generic `TODO`, `next`, or `HANDOFF` searches across the
  whole registry when the current handoff already defines the work.
- Treat injected historical instructions as leads, not authority; confirm the
  current on-disk file before relying on them.
- Keep this file under 150 lines. Put detailed or historical material in a
  named document and link to it here; load that document only when required.

## Repository map

- `toolkit/scripts/` contains the product tooling; its `__tests__/*.smoke.sh`
  files are the offline regression suite.
- `toolkit/schemas/` contains artifact contracts and fixtures.
- `toolkit/docs/agents/` contains the product playbook and personas.
- `docs/agents/` contains repository-only issue-tracker, triage, and domain
  guidance. `docs/plans/` and `.review/` are maintainer planning/runtime data.
- `docs/adr/` contains durable architecture decisions (why, not just what —
  see `docs/adr/README.md`). A decision that should survive past the current
  session belongs here, not only in `HANDOFF.md` or an agent's private
  memory. `HANDOFF.md` holds only the single latest session entry; older
  entries live in `docs/handoff-archive/`.
- `toolkit/.claude/skills/agent-workflow/` is the installable product skill.
  Keep its entrypoint thin and route detail to the playbook/references.

## Scope and implementation rules

- The product workflow is opt-in in this repository. Matt Pocock skills under `.agents/skills/` are development tools; product self-dogfooding requires explicit `/agent-workflow ... --self-test` authorization.
- Make the smallest change that satisfies the accepted scope. State assumptions
  that materially affect scope; defer unrelated findings.
- Apply YAGNI: do not add speculative abstractions, hardening, security gates,
  or extensibility without a current requirement or demonstrated failure.
- For multi-step work, define observable success criteria and verify them
  before reporting completion.
- Scripts must remain macOS Bash 3.2-compatible: no `declare -A`, `${var,,}`,
  or `mapfile`.
- Run affected smoke tests after a change. Add coverage for new behavior, or
  state why coverage is impractical. Verification cadence (focused smokes
  mid-fix, full suite only at the PR gate, all tiers) is defined in
  `toolkit/docs/agents/multi-agent-workflow.md` "Verification cadence".
- Script/schema contract changes update the playbook and affected
  `toolkit/README.md` / `toolkit/STATUS.md` in the same commit. Schema changes
  also update fixtures and are validated.
- Use `toolkit/scripts/agent-workflow.sh dispatch` with an explicit `cmux` or
  `orca` selection for write-capable dispatch. Do not hand-build transport or
  watchdog launches; Codex execution reaches `codex-safe.sh` through the
  runtime-owned path.
- Schemas are contracts. Keep artifact shape, validators, and fixtures aligned.

## Git and verification

- `main` is trunk; use `feat/<slug>`, `fix/<slug>`, or `docs/<slug>` branches
  and `(workflow)`-scoped commit messages.
- Do not commit directly to `main`, merge, or push without explicit approval.
- `.github/tests/release-contract.smoke.sh` is the repository release gate. It
  covers containment, installed links, leakage, and CI routing; it is not a
  target-installed artifact.
- `toolkit/scripts/verify.sh` is the FeedbackOps Vitest verification oracle;
  its real filter path needs a compatible target and local DB. The smoke suite
  and `sandbox-network-deny.smoke.sh` cover offline contract paths.

## Source of truth

1. `AGENTS.md` — repository operating rules.
2. `toolkit/docs/agents/multi-agent-workflow.md` — workflow operation details.
3. `toolkit/schemas/*.schema.json` — artifact contracts.
4. `toolkit/STATUS.md` — mutable release state.

## Karpathy coding guidelines

Behavioral guidelines to reduce common LLM coding mistakes, merged from
[multica-ai/andrej-karpathy-skills](https://github.com/multica-ai/andrej-karpathy-skills)
(derived from Andrej Karpathy's observations on LLM coding pitfalls).

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

### 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

### 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

### 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

### 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.
