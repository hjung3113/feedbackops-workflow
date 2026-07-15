# Skill Sync Spec: `/Users/hyojung/.claude/skills/agent-workflow/SKILL.md`

Do not edit the external file from this repo commit. Apply these exact old-to-new replacements manually after the repo batches are accepted.

## 1. Non-negotiable Rules

Replace the current rules 3 and 7 block:

```md
3. **Evidence or it didn't happen.** A task is complete only when a verify artifact (`.review/ISSUE-<N>-VERIFY.json`, `classifier: "PASS"`, `verdict.failed: 0`, `passed >= 1`) exists for the CURRENT head sha. "Tests pass" in prose ≠ done.
4. **Doc-sync discipline.** Any script/schema/contract change updates the relevant doc (playbook / README / STATUS) in the SAME commit.
5. **Don't merge to main/develop or push without explicit user approval.** You are the orchestrator, the human is Release Captain.
6. **CONDUCTOR is READ-ONLY on product code.** You (the main session) NEVER edit source files — not a typo, not a one-line patch, not "just this once." Any source edit by the conductor is **role bleed — a defect** (`conductor-persona.md` §2). You dispatch; the workers touch code. If a fix is needed, re-dispatch CODEX with a scoped follow-up prompt.
7. **Worker roles run IN their cmux panes — never inline in the conductor.** This is a **cmux 4-pane** workflow (ARCHITECT / CODEX / REVIEWER / VERIFIER, +VISUAL in its own pane) so the human can WATCH each role work. The conductor dispatches a command into the role's pane (e.g. send `verify.sh ...` to the VERIFIER pane, a review task to the REVIEWER pane) — it does NOT run review/verify in its own session. The conductor stays lean by reading **`.review/*.json` artifacts** (via `conductor-rebuild.sh`), **never pane scrollback, never raw diffs/test logs** (persona §3/§4). That artifact-only read — not moving work out of the panes — is what keeps the conductor's context small. Do NOT replace panes with invisible `Agent` subagents: that defeats the watch-the-work purpose of cmux.
```

with:

```md
3. **Evidence or it didn't happen.** A task is complete only when the canonical verifier artifact (`.review/ISSUE-<N>-VERIFY.json`, `producer_role: "VERIFIER"`, `classifier: "PASS"`, `verdict.exit_code: 0`, `verdict.failed: 0`, `verdict.passed >= 1`, matching issue/branch, and `head_sha` equal to the live worktree HEAD) exists for the current head. `pr_draft.verify_result` is deprecated and ignored. In `VERIFY_ISSUE` mode, a green run that cannot write a valid VERIFY artifact is not done (`verify.sh` exits 5). "Tests pass" in prose ≠ done.
4. **Implementation, review, and verification are separate.** The same agent/session must not implement and then approve or verify its own work. Re-review uses a new clean context.
5. **Doc-sync discipline.** Any script/schema/contract change updates the relevant doc (playbook / README / STATUS) in the SAME commit.
6. **Don't merge to main/develop or push without explicit user approval.** You are the orchestrator, the human is Release Captain.
7. **CONDUCTOR is READ-ONLY on product code.** You (the main session) NEVER edit source files — not a typo, not a one-line patch, not "just this once." Any source edit by the conductor is **role bleed — a defect** (`conductor-persona.md` §2). You dispatch; the workers touch code. If a fix is needed, re-dispatch CODEX with a scoped follow-up prompt.
8. **Worker roles run IN their cmux panes — never inline in the conductor.** This is a **cmux 4-pane** workflow (ARCHITECT / CODEX / REVIEWER / VERIFIER, +VISUAL in its own pane) so the human can WATCH each role work. The conductor dispatches a command into the role's pane (e.g. send `verify.sh ...` to the VERIFIER pane, a review task to the REVIEWER pane) — it does NOT run review/verify in its own session. The conductor stays lean by reading **`.review/*.json` artifacts** (via `conductor-rebuild.sh`), **never pane scrollback, never raw diffs/test logs** (persona §3/§4). That artifact-only read — not moving work out of the panes — is what keeps the conductor's context small. Do NOT replace panes with invisible `Agent` subagents: that defeats the watch-the-work purpose of cmux.
9. **Do not run two workspace-write Codex jobs in the same repo at the same time.** `codex-safe.sh` stashes partial work on failure; concurrent jobs in one checkout can race on stash state. Parallel implementation requires separate prepared worktrees.
10. **Clear `NODE_OPTIONS=` before codex/node dispatch and verification.** cmux or shell preloads can leak `--require` instrumentation into codex/vitest children.
```

## 2. Insert Model Allocation

After the paragraph ending:

```md
The authoritative playbook is `$WF/docs/agents/multi-agent-workflow.md`. Read it if any step here is ambiguous. Role prompts: `$WF/docs/agents/conductor-persona.md`, `visual-reviewer-persona.md`.
```

insert:

```md
## Model allocation

| Work type | Model |
|---|---|
| Design | Opus + gpt-5.5 adversarial co-design |
| Simple tasks | Haiku / Sonnet subagents |
| Large analysis or implementation | Codex = gpt-5.5. gpt-5.6 is not supported on the ChatGPT account; if used elsewhere, keep reasoning at medium or below. |
| Final review | Fable in a clean context, separate from the implementation session |
```

## 3. Step 4 Dispatch

Replace:

```md
$WF/scripts/codex-safe.sh --issue <N> --prompt-file .review/ISSUE-<N>-PROMPT.txt --cwd <worktree-path>
```

with:

```md
NODE_OPTIONS= $WF/scripts/codex-watchdog.sh --issue <N> --prompt-file .review/ISSUE-<N>-PROMPT.txt --cwd <worktree-path>
```

Then replace the three bullets below it:

```md
- gpt-5.5 medium reasoning is slow; allow a generous timeout (≥900s) and run it backgrounded if your harness supports it. If it times out before writing, RETRY with a longer budget — a killed run leaves no files.
- Codex stdout may not capture cleanly when backgrounded; rely on the FILES it wrote + git diff, not its narration. Have it write results to a file when you need a deterministic signal.
- On non-zero exit, the wrapper stashes partial work via `workflow-stash.sh`.
```

with:

```md
- The watchdog calls `codex-safe.sh` by absolute path, preserving the sandbox and stash contract.
- Liveness is process + filesystem progress, never stdout first-token output. It writes `<worktree>/.review/ISSUE-<N>-RUN.json`.
- 4xx/model refusal exits fail-fast; stalls are killed and retried. On non-zero `codex-safe.sh` exit, partial work is still preserved via `workflow-stash.sh`.
```

## 4. Step 5/6 Separation

In Step 5, after:

```md
Do NOT review inline in the conductor (that loads the diff into the conductor's context = the thing we're avoiding).
```

insert:

```md
The REVIEWER must be a different agent/session from the implementer. Re-review uses a clean context.
```

In Step 6, after:

```md
This is the evidence gate.
```

insert:

```md
The VERIFIER must be a different agent/session from the implementer. The implementer's own test claim is not verification.
```

## 5. Step 7 Conductor Predicate

Replace:

```md
A draft is **verified** only when `status: ready_for_review`, `verify_result.failed == 0`, `passed > 0`, and `verified_head_sha` equals the worktree's live HEAD. Stale verify (work landed after) or unresolved HEAD → NOT verified. Present the evidence to the user (Release Captain) for the merge decision. Do not merge/push without approval.
```

with:

```md
A draft is **verified** only when `status: ready_for_review` and the deterministic `.review/ISSUE-<N>-VERIFY.json` satisfies: `producer_role: "VERIFIER"`, `classifier: "PASS"`, `verdict.failed == 0`, `verdict.passed >= 1`, `verdict.exit_code == 0`, internal issue matches the draft issue, branch matches the draft branch, and `head_sha` equals the worktree's live HEAD. `pr_draft.verify_result` is deprecated and ignored. Stale verify (work landed after), missing VERIFY artifact, identity mismatch, or unresolved HEAD → NOT verified. Present the evidence to the user (Release Captain) for the merge decision. Do not merge/push without approval.
```
