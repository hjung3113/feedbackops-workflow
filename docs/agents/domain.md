# Domain docs

This is a single-context workflow-toolkit repository.

Before changing a workflow contract, read:

- root `CONTEXT.md`, when present, for canonical vocabulary;
- relevant ADRs under `docs/adr/`, when present;
- `AGENTS.md` for repository rules;
- `docs/agents/multi-agent-workflow.md` for the operating contract;
- affected schemas under `.review/schemas/` for machine-readable artifact contracts.

If `CONTEXT.md` or `docs/adr/` does not exist, continue without inventing placeholder documentation. Create or update domain documentation only when a real term or architectural decision is resolved.

Use established terms such as CONDUCTOR, CODEX, REVIEWER, VERIFIER, Release Captain, ROUND-STATE, artifact, lifecycle, and verification evidence consistently. Surface conflicts with an existing ADR or schema instead of silently overriding them.
