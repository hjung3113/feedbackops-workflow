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

GitHub is the live roadmap. `STATUS.md` may summarize it, but must not become a second issue tracker.

## Issues reported from target repositories

When another repository uses this toolkit and exposes a toolkit problem, report it to this
repository rather than turning the target-specific workaround into an undocumented fork.

1. Reproduce against the target's current toolkit installation and record whether it is a
   symlink or copy install. For a copy install, include the toolkit revision or snapshot date.
2. Classify the boundary as one of: coordination-core defect, bundled target-adapter mismatch,
   or adoption/documentation gap. If the evidence is ambiguous, say so instead of guessing.
3. Search this repository's open and closed issues for the same symptom.
4. With authorization for the external write, open an issue in this repository. Include:
   - target repository shape and relevant tool versions, without secrets or product data;
   - the smallest reproducing command or workflow step;
   - expected and actual behavior, including exit code and sanitized evidence paths/output;
   - toolkit revision/install mode and the target-owned adapter configuration;
   - impact, frequency, and any safe temporary workaround;
   - a link back to the target issue or handoff when it is accessible.
5. Record the upstream issue URL in the target's issue, handoff, or completion report. Keep any
   workaround target-owned until the shared contract is changed and released; do not silently
   broaden the toolkit from one target's assumptions.

Opening, commenting on, or closing the upstream issue remains an external write and requires
user authorization. A target failure is evidence for triage, not automatic proof that the
portable coordination core is defective.
