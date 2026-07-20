---
name: agent-workflow
description: Run or adapt an evidence-gated multi-agent coding workflow with cmux, Claude, Codex, isolated worktrees, independent review, and host-side verification. Invoke only when the user explicitly asks for /agent-workflow or explicitly requests this workflow; never auto-apply it while developing the toolkit itself.
trigger: /agent-workflow
---

# Agent Workflow

Use this skill as the **router and completion gate** for a coding run. Keep detailed policy in the versioned toolkit docs; do not copy model names, incident histories, schema fields, or target-specific commands into this file.

## Invocation

```text
/agent-workflow <task or issue>
/agent-workflow #<issue-number>
/agent-workflow <task> --target <repo-path>
/agent-workflow <task> --tier trivial|standard|full
/agent-workflow <task> --self-test
```

## Resolve target and toolkit

1. Resolve `TARGET` from `--target`, otherwise the current Git repository root.
2. Resolve `WF` in this order:
   - `$AGENT_WORKFLOW_HOME`, when explicitly set;
   - `$TARGET/.agent-workflow`, when installed into the target;
   - the toolkit product root (`../../..` from this skill) when working in the toolkit source tree.
3. Require `$WF/scripts/codex-safe.sh` and `$WF/docs/agents/multi-agent-workflow.md`. If either is missing, stop and run the toolkit's `scripts/install-into.sh <target>` or ask for the correct home.
4. Resolve both paths physically. `$TARGET/.agent-workflow` is a normal target installation. Otherwise, if `git -C "$WF" rev-parse --show-toplevel` resolves to `TARGET`, stop unless the user explicitly passed `--self-test`. The source product belongs to that repository but is not its default development workflow. `--self-test` is narrow authorization for intentional dogfooding; it does not weaken any other gate.

Never assume a machine-specific absolute path. `TARGET` is the repository being changed; `WF` is the workflow implementation.

## Load authority before dispatch

Read completely:

- the target's applicable `AGENTS.md`/`CLAUDE.md`;
- `$WF/docs/agents/multi-agent-workflow.md`;
- `$WF/docs/agents/conductor-persona.md` when acting as CONDUCTOR;
- `$WF/docs/agents/visual-reviewer-persona.md` only for a visual review.

For installation or adaptation to a new repository, also read `references/adoption.md` next to this file.

The target instructions own product conventions. The workflow playbook owns role separation, model allocation, dispatch, artifacts, and verification gates. If they conflict, stop and surface the conflict.

## Hard gates

- All **write-capable Codex implementation** runs through `$WF/scripts/cmux-dispatch.sh`, which reaches `codex-safe.sh`. Do not hand-build a cmux command or call `codex exec` directly for writes.
- Separate implementation, review, and verification contexts. No agent approves its own change.
- Parallel write jobs require separate prepared worktrees. Never run two workspace-write jobs in one checkout.
- CONDUCTOR orchestrates and reads artifacts; workers edit and test in their assigned workspaces.
- Process exit and prose are not completion evidence. Compare the live HEAD, actual diff, review result, and verifier evidence.
- Script, schema, or workflow-contract changes update the relevant docs in the same commit.
- Merge, push, issue closure, and other external writes require the user's authority.

## Run loop

1. **Scope** — resolve the issue/task, target repository, acceptance criteria, allowed touch set, and integration branch. Before locking scope for an exported-contract change, follow the playbook's pre-scope-lock impact pass and record its compile-atomic boundary plus convention watches in ROUND-STATE; for repository-dependent Full Cluster ARCH decisions and test-matrix rows, apply the feasibility-evidence and test-matrix contracts. Before the first Standard/Full Cluster write, CONDUCTOR generates the complete canonical `ISSUE-<n>-ROUND-STATE.json`. Standard omits optional Full Cluster structures but never uses a reduced schema or parallel mini-state; escalation revises the same artifact. Trivial remains pr_draft-only. Prompt amendments cannot override canonical state.
2. **Route risk** — select Trivial, Standard, or Full from the playbook. Before Trivial, run `tier-probe.sh` when the target is compatible; otherwise conservatively escalate.
3. **Prepare** — create one worktree per write chunk. Use `prepare-worktree.sh` only when the target matches its pnpm/env contract; otherwise run the target's documented host-side setup.
4. **Dispatch** — write `.review/ISSUE-<N>-PROMPT.txt`, explicitly pin the playbook-selected model/effort and `--tier`, then call `cmux-dispatch.sh`. Standard/Full Cluster initial writes and every redispatch pass `--round-state <state> --manifest-revision <revision>`; initial admission validates schema, active lifecycle, issue, tier, revision, worktree, live HEAD, and base freshness before cmux starts. Standard state keeps `pr_draft` and `review` pointers. Trivial initial writes pass `--tier trivial` without ROUND-STATE, preserving the `pr_draft`-only tax boundary. Use `--read-only` for thinking/review seats and tune liveness budgets only when needed.
5. **Gate implementation** — run `$WF/scripts/completion-check.sh --round-state <state> --manifest-revision <revision>` before review. It executes the target-native `contract.test_discovery_command`, then independently compares live `base..HEAD` changed paths, discovered AC IDs, and the discovery record count with the canonical contract (`acceptance.expected_test_count`). For `contract.chunk_boundary`, it also checks enumerated consumers against the chunk, runs the full typecheck, and derives fired-only `review_obligations[]`; a non-zero result hard-stops review. Do not trust the worker summary, RUN.json, PR-DRAFT claims, or a worker-provided discovery file alone.
6. **Control redispatch** — after every failed round, preserve coherent schema/issue/HEAD-bound VERIFY/REVIEW evidence and classify one primary origin with its compatible action. Closure binds exact failed ACs to the canonical verify filter or a met REVIEW checklist item and requires a lineage-valid PASS. A write redispatch passes canonical state/revision to `cmux-dispatch.sh`, which atomically records intent, binds CLI issue/worktree, and consumes immutable issue/ordinal plus issue-wide integrated admission. Dispatch only that mode. Diagnosis rechecks oracle/contract before one integrated fix batch; watchdog retries and model escalation do not clear it.
7. **Review** — Standard/Full changes get an independent clean-context review of the actual integrated diff. UI changes also follow the visual-reviewer persona.
8. **Verify** — run the target's verifier outside the Codex sandbox. If the target matches the bundled backend-pnpm/Vitest adapter, use `verify.sh` and require a current `ISSUE-<N>-VERIFY.json`. Otherwise use the target-native test gate and clearly report that the bundled canonical verifier adapter is not applicable; never fabricate its artifact.
9. **Close** — reconstruct state, re-review after fixes, present evidence to the user, and only then perform authorized merge/push/issue closure. Archive artifacts and close finished cmux workspaces.

## Completion report

Report only evidence that was independently observed:

- branch and final commit;
- files/scope actually changed;
- review verdict and resolution of findings;
- exact verification command and result;
- whether canonical VERIFY evidence applies and matches HEAD;
- remaining blockers or target-adapter gaps;
- toolkit issues discovered in the target, including the authorized upstream issue URL or a note that filing still needs authorization;
- whether merge, push, and issue closure were performed.

Do not restate the entire playbook in the final response. Link the relevant artifact or document.
