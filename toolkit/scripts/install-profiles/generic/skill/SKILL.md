---
name: agent-workflow
description: Run an evidence-gated multi-agent workflow in a target repository.
trigger: /agent-workflow
---

# Agent Workflow

Resolve PRODUCT_HOME as the installed checkout's absolute `.agent-workflow`
directory. A fresh linked worktree has no ignored PRODUCT_HOME, so invoke
`"$PRODUCT_HOME/scripts/agent-workflow.sh"` and pass it with `--worktree`;
do not use worktree-relative `.agent-workflow/scripts` paths.
Read the target instructions and the installed generic playbook before work.
Use `"$PRODUCT_HOME/scripts/agent-workflow.sh" dispatch` with explicit, independently selected
runtime (`codex|claude|opencode|omp`), role (including conductor), and one
available orchestrator (`cmux|orca|herdr`). Run `"$PRODUCT_HOME/scripts/agent-workflow.sh" capabilities` before admission;
missing capability fails closed and never falls back. OpenCode requires
top-level and named-primary-agent deny-first permissions delivered through
`OPENCODE_CONFIG_CONTENT`; the adapter explicitly selects `agent-workflow` and
does not use a default agent. Keep implementation, independent review, and host
verification separate. Verify through `"$PRODUCT_HOME/scripts/target-verify.sh"` with a
target-owned profile. Never infer completion from agent prose or RUN state;
require fresh, live-HEAD-bound REVIEW and VERIFY evidence. Push, merge, and
issue closure need explicit user authority.
