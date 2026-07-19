# feedbackops-workflow

This repository develops and releases the reusable `agent-workflow` toolkit.

- [`toolkit/`](toolkit/) is the only distributable product root. Start with [`toolkit/README.md`](toolkit/README.md) for installation and operation.
- [`.agents/skills/`](.agents/skills/) and [`skills-lock.json`](skills-lock.json) are the Matt Pocock engineering environment used to develop the toolkit; they are not shipped to targets.
- [`docs/agents/`](docs/agents/) contains maintainer tracker, domain, and triage configuration.
- [`docs/plans/`](docs/plans/) and [`.review/`](.review/) contain repository-owned plans and runtime evidence.
- [`.github/`](.github/) and [`.githooks/`](.githooks/) integrate the product with this repository.

Repository contribution rules live in [`AGENTS.md`](AGENTS.md). Product-scoped rules live in [`toolkit/AGENTS.md`](toolkit/AGENTS.md).

Run the repository-owned release contract and the full product smoke suite from the repository root:

```bash
bash .github/tests/release-contract.smoke.sh
NODE_OPTIONS= bash toolkit/scripts/__tests__/run-all.sh
```

The release contract checks that product authority remains contained in `toolkit/`, current references and local Markdown links resolve in source and copy-installed contexts, and maintainer-only files do not leak into target installations.
