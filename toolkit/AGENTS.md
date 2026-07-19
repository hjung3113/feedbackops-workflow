# Toolkit Product Instructions

This directory is the complete distributable `agent-workflow` product root. Root `AGENTS.md` still applies; this file adds product-scoped rules.

- `scripts/`, `schemas/`, `docs/`, `.claude/skills/agent-workflow/`, `README.md`, `STATUS.md`, and `.env.example` are product authorities.
- Keep scripts compatible with macOS Bash 3.2. Do not use `declare -A`, `mapfile`, or `${var,,}`.
- Test behavior through source commands and temporary symlink/copy installations. Run the affected smoke and `NODE_OPTIONS= bash scripts/__tests__/run-all.sh` before completion.
- A script, schema, or workflow-contract change must update the affected product playbook, README, STATUS, installer coverage, and skill references in the same commit.
- Product schemas live in `schemas/`; target runtime evidence lives in `<target>/.review/`. Never treat target runtime state as product resources.
- Product documents must be self-contained and must not depend on the repository-only tracker, domain, triage, Matt skills, plans, CI, hooks, or runtime evidence.
- Keep local Markdown links valid both in this source tree and after a copy installation; source-only repository paths are not available in targets.
- `docs/agents/workflow-trial-log.md` is dated historical evidence. Update its current-authority pointer when paths change, but do not rewrite commands that record what a trial actually used.
- Do not recreate an `agent-workflow` authority outside this product root.
