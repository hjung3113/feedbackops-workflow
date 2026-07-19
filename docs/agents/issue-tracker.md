# Issue tracker: GitHub

Issues and specifications for this repository live in GitHub Issues. Use the `gh` CLI from this checkout so the remote repository is inferred automatically.

## Conventions

- Read an issue with `gh issue view <number> --comments` and include labels when routing work.
- List open work with `gh issue list --state open` and request JSON fields needed for filtering.
- Create, edit, label, comment on, or close issues only when the user has authorized that external write.
- Pull requests are delivery artifacts, not an inbound triage surface.
- A bare `#<number>` means a GitHub issue unless the surrounding context explicitly says pull request.

## Skill routing

- When a skill says to publish to the issue tracker, create a GitHub issue.
- When a skill says to fetch the relevant ticket, read the issue body, labels, and comments.
- `to-spec` publishes one specification issue.
- `to-tickets` publishes tracer-bullet child issues and records their blocking edges.
- `wayfinder` uses one map issue and linked child issues; prefer native sub-issue and dependency relationships when the repository supports them.

GitHub is the live roadmap. `toolkit/STATUS.md` may summarize it, but must not become a second issue tracker.

Target adopters use the distributable reporting contract in `toolkit/docs/agents/issue-reporting.md`; it is not part of this maintainer tracker configuration.
