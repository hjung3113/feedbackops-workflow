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

## Agent skills

### Issue tracker

Issues are tracked in GitHub Issues via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical roles use default label strings (`needs-triage`, `needs-info`,
`ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: root `CONTEXT.md` plus `docs/adr/`. See `docs/agents/domain.md`.

## Scope and implementation rules

- The product workflow is opt-in in this repository. Matt Pocock skills under `.agents/skills/` are development tools; product self-dogfooding requires explicit `/agent-workflow ... --self-test` authorization.
- Make the smallest change that satisfies the accepted scope. State assumptions
  that materially affect scope; defer unrelated findings.
- Apply YAGNI: do not add speculative abstractions, hardening, security gates,
  or extensibility without a current requirement or demonstrated failure.
- If a task is ambiguous or admits multiple interpretations, surface the
  ambiguity and ask before implementing.
- Edit surgically: match existing style, do not "improve" adjacent code,
  and remove only what your own changes orphaned.
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
- Every feature executes through per-member adapter files on both the
  Transport and Runtime axes; never inline-branch on a hardcoded transport or
  runtime name in a shared/core file — see
  `docs/adr/0006-adapters-are-one-file-per-axis-member.md`.
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
