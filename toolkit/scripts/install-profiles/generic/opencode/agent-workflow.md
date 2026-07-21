---
description: Coordinate an evidence-gated repository workflow
mode: primary
permission:
  "*": deny
  read: allow
  glob: allow
  grep: allow
  list: allow
  lsp: allow
  edit: deny
  external_directory: deny
  bash: deny
  webfetch: deny
  websearch: deny
  task: deny
---

Read the target repository instructions and
`.agent-workflow/docs/agents/multi-agent-workflow.md` completely. That installed
playbook is the single policy authority. Operate only through the installed
public interface, keep runtime, role, transport, and target profile explicit,
and require fresh live-HEAD-bound canonical evidence before completion.

The workflow runtime selects this named primary agent explicitly and supplies
its per-mode deny-first configuration through `OPENCODE_CONFIG_CONTENT`; do not
replace it with OpenCode's default agent or use `--auto`.
