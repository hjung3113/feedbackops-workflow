---
name: agent-workflow
description: Run or adapt an evidence-gated multi-agent coding workflow with cmux or Orca, Codex/Claude Code/OpenCode, isolated worktrees, independent review, and host-side verification. Invoke only when the user explicitly asks for /agent-workflow or explicitly requests this workflow; never auto-apply it while developing the toolkit itself.
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

- All write-capable runtime work runs through `$WF/scripts/agent-workflow.sh dispatch`, after explicit runtime, role, and `cmux|orca` transport selection. It reaches the shared dispatch core and typed runtime adapter; do not hand-build a transport/runtime command. Probe the requested runtime/role before admission; unavailable capability has a machine-readable failure and never falls back. OpenCode additionally requires an explicit deny-first permission configuration (`permission["*"]:"deny"`; write only adds `permission.edit:"allow"`).
- Separate implementation, review, and verification contexts. No agent approves its own change.
- Parallel write jobs require separate prepared worktrees. Never run two workspace-write jobs in one checkout.
- Parallel eligibility requires a canonical execution plan and `parallel-plan.sh decide`; absent, broad, dynamic, overlapping, dependency-bound, shared-mutation, or isolation/budget-unproven seats serialize. Worker claims and transport state never establish independence.
- CONDUCTOR orchestrates and reads artifacts; workers edit and test in their assigned workspaces.
- Process exit and prose are not completion evidence. Compare the live HEAD, actual diff, review result, and verifier evidence.
- Script, schema, or workflow-contract changes update the relevant docs in the same commit.
- Merge, push, issue closure, and other external writes require the user's authority.

## Run loop

1. **Scope** — resolve the issue/task, target repository, acceptance criteria, allowed touch set, canonical structured prohibitions, and integration branch. First create the conductor persona's issue acceptance matrix from the issue body and explicit requested comments. It is the complete current-task authority: discoveries that do not fail one of its checks are deferred follow-ups, not reasons to edit, redispatch, re-review, or block completion without explicit user scope expansion. Before locking scope for an exported-contract change, follow the playbook's pre-scope-lock impact pass and record its compile-atomic boundary plus convention watches in ROUND-STATE; for repository-dependent Full Cluster ARCH decisions and test-matrix rows, apply the feasibility-evidence and test-matrix contracts. Before the first Standard/Full Cluster write, CONDUCTOR generates the complete canonical `ISSUE-<n>-ROUND-STATE.json`, including `contract.prohibitions[]`; prompt regexes are not authority. When more than one write seat is proposed, CONDUCTOR also creates canonical `ISSUE-<n>-EXECUTION-PLAN.json`; a one-seat plan is the sequential compatibility form. Escalation revises the same ROUND-STATE and plan binding. Trivial remains pr_draft-only. Prompt amendments cannot override canonical state.
2. **Route risk** — select Trivial, Standard, or Full from the playbook. Before Trivial, run `tier-probe.sh` when the target is compatible; otherwise conservatively escalate.
3. **Prepare** — create one worktree per write chunk. Use `prepare-worktree.sh` only when the target matches its pnpm/env contract; otherwise run the target's documented host-side setup.
4. **Dispatch** — for Standard/Full and redispatch, first create uncommitted `.review/ISSUE-<N>-CONTEXT.md`, ask one user-facing reverse-question batch when needed, then compress `.review/ISSUE-<N>-PROMPT.md`; keep authoring context out of the worker. Its delimited JSON AC block must exactly copy canonical ROUND-STATE criteria or the shared core rejects the launch before side effects. Explicitly select `--orchestrator cmux|orca`, `--runtime codex|claude|opencode`, and `--role <role>` (CLI > environment > target config). Codex/implementation defaults are legacy compatibility only; selected runtime or transport never falls back. Probe runtime/role/mode before admission and retain its observed version; target config cannot inject an executable. A planned write additionally passes canonical `--execution-plan <plan> --seat <id>`; admission binds issue, revision, base HEAD, worktree, seat, and exact ROUND-STATE allowlist before consuming an immutable same-seat admission. Preserve its direct exit code and accept RUN/BLOCKER only when their `mtime + started_at` identity is fresh for that launch. Standard/Full Cluster initial writes and every redispatch pass `--round-state <state> --manifest-revision <revision>`; Trivial initial writes remain `pr_draft`-only. Use `--read-only` for non-review thinking seats and `--produce-review` for canonical read-only REVIEW publication; valid REVIEW publication retains its immutable head-bound snapshot, while malformed pre-existing BLOCKER recovery quarantines raw bytes and consumes exactly one host-owned ordinal without making them canonical evidence.
5. **Gate implementation** — run `$WF/scripts/completion-check.sh --round-state <state> --manifest-revision <revision>` before review. It executes the target-native `contract.test_discovery_command`, then independently compares live `base..HEAD` changed paths, discovered AC IDs, and the discovery record count with the canonical contract (`acceptance.expected_test_count`). For `contract.chunk_boundary`, it also checks enumerated consumers against the chunk, runs the full typecheck, and derives fired-only `review_obligations[]`; a non-zero result hard-stops review. Do not trust the worker summary, RUN.json, PR-DRAFT claims, or a worker-provided discovery file alone.
6. **Control redispatch** — after every failed round, preserve coherent schema/issue/HEAD-bound VERIFY/REVIEW evidence and classify one primary origin with its compatible action. A schema-valid canonical BLOCKER may be the sole failed evidence only for `dispatch_contract` routed to `contract_fix`, only with `active` or `final` lifecycle, and its producer-observed `head_sha` must equal the evidence reference; `superseded` is ignored and it is not a general substitute for VERIFY/REVIEW. Legacy BLOCKER files without that field are display-only until regenerated at an observed commit. Closure binds exact failed ACs to the canonical verify filter or a met REVIEW checklist item and requires a lineage-valid PASS. A write redispatch passes canonical state/revision to `agent-workflow.sh dispatch` with the selected orchestrator; the shared core atomically records intent, binds CLI issue/worktree, and consumes immutable issue/ordinal plus issue-wide integrated admission. Dispatch only that mode. Diagnosis rechecks oracle/contract before one integrated fix batch; watchdog retries and model escalation do not clear it.
7. **Review** — Standard/Full changes get an independent clean-context review of the actual integrated diff. Before any re-review, generate the deterministic capsule with `$WF/scripts/review-capsule.sh`, then pass its canonical JSON as `--review-capsule` to `agent-workflow.sh dispatch --produce-review --re-review` with the selected orchestrator; the dispatch auto-selects canonical capsule Markdown and rejects any unrelated prompt. ROUND-STATE prohibitions and ACs remain untruncated. The capsule is derived guidance; canonical artifacts remain authoritative. UI changes also follow the visual-reviewer persona.
8. **Verify** — run `$WF/scripts/target-verify.sh <target-profile.json> <issue>` outside the Codex sandbox and require its current HEAD-bound canonical VERIFY. For the explicit FeedbackOps compatibility profile, configure `VERIFY_CLEAN_COMMAND` and use `verify.sh` instead. Same-identity reruns aggregate, so any failed run keeps readiness red until a new HEAD.
9. **Close** — for multiple seats, run `candidate-integrate.sh` in declared topological order against a clean candidate and then `candidate-close.sh evaluate` once with the complete fresh candidate evidence set. Require exact unique integration-step order, final REVIEW, active PR-DRAFT, and a direct issue/round/revision/candidate-HEAD/attempt/generation binding inside every closure artifact; a wrapper-only attempt relabel is not fresh. Worker-head or draft/superseded evidence, invalid timestamps, a partial/mixed attempt, active blocker, dirty candidate, or stale candidate HEAD cannot close. `candidate-close.sh inspect` makes any later commit visibly stale. Then reconstruct state, re-review after fixes, present evidence to the user, and only then perform authorized merge/push/issue closure. Archive artifacts and close finished cmux workspaces.

Optional telemetry is never implicit. Collect it only when the user/operator opts in, using `$WF/scripts/telemetry.sh` against canonical artifacts. A green sample requires matching canonical CLOSURE, INTEGRATION, and CANDIDATE-EVIDENCE sources with current byte digests and generation/RUN freshness, not REVIEW/VERIFY pass alone. A policy-routed sample also needs the canonical v3 transport receipt; the collector accepts it only when its complete routing tuple matches the host admission binding, then derives the tuple and salted route pseudonym from that host-bound record, never from telemetry CLI values. Salt and store paths must resolve inside the target. Treat reports as advisory evidence; never feed them directly into automatic model allocation or tier mutation, and never compare a mixed-model retry chain as if its first model owned every attempt.

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
