# Agent Workflow (generic distribution)

This installation is target-neutral. Its coordination scripts, schemas, and
transport adapters make no assumptions about the target's stack, conventions,
domain model, or repository layout.

Select four independent axes at dispatch: this generic distribution profile,
runtime (`codex`, `claude`, or `opencode`), role (including `conductor`), and
transport (`cmux` or `orca`). Run `scripts/agent-workflow.sh capabilities`
before admission. An unavailable runtime/role/mode or transport fails closed
with a machine-readable reason and is never substituted. OpenCode additionally
needs deny-first permissions at the top level and in the named primary
`agent-workflow` agent; both deny `*`, external directories, shell, and web.
The adapter injects the validated JSON through `OPENCODE_CONFIG_CONTENT` and
invokes `--agent agent-workflow`, never a default agent.

Before dispatch, create a target-owned profile using
`.agent-workflow/schemas/target-profile.schema.json` and run
`scripts/target-verify.sh <profile> <issue>` for canonical verification.
Select the orchestrator explicitly in `workflow-config.json` (copy the
installed example) or on the public `scripts/agent-workflow.sh dispatch`
command. An unavailable selection fails closed; it is never substituted.
Runtime and role use the same CLI/environment/config precedence. Target config
may name only those axes; it cannot supply executable paths or commands.

Use the target's own instructions for setup, worktrees, tests, review scope,
and release authority. RUN files and agent prose are not completion evidence;
only fresh HEAD-bound REVIEW and VERIFY artifacts are authoritative.

New launches use the runtime-neutral `agent-watchdog.sh`, publish
runtime/role/version-bound `agent_run` liveness, and write schema-v2 transport
receipts. `codex-watchdog.sh`, `codex_run`, and receipt v1 are legacy-readable
only. A watchdog attempt is not a redispatch ordinal. Read-only conductor
control may publish only a host-validated, live-HEAD-bound ROUND-STATE update;
it grants no product-code write permission.
