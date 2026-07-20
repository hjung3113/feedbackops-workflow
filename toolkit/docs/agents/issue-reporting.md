# Reporting toolkit problems from a target repository

Do not leave a reusable toolkit failure recorded only as a target-local workaround.

1. Reproduce against the target's current portable-copy installation and record the toolkit revision or snapshot date.
2. Classify the boundary as `coordination-core`, `target-adapter`, `adoption/docs`, or `unknown`. Keep it unknown when the evidence is ambiguous.
3. Search open and closed issues in `hjung3113/feedbackops-workflow` for the same symptom.
4. Obtain explicit authorization before any external write, then open an issue in that repository.
5. Link the upstream issue from the target issue, handoff, or completion report. Keep workarounds target-owned until the shared contract changes.

Include the target shape and relevant tool versions, the smallest reproducing command, expected and actual behavior, exit code, sanitized evidence, toolkit revision/install mode, impact, frequency, and any safe workaround. Never include credentials, customer data, raw environment files, private repository URLs, or unredacted workflow artifacts.

## Issue body template

```markdown
## Classification

<!-- coordination-core | target-adapter | adoption/docs | unknown -->

## Target context

- Target repository shape:
- Toolkit revision or snapshot date:
- Install layout: portable copy
- Relevant tool versions:
- Target-owned adapter/configuration:

## Reproduction

1.
2.
3.

Smallest reproducing command or workflow step:

## Expected behavior

## Actual behavior

- Exit code:
- Sanitized evidence:
- Frequency/impact:

## Temporary workaround

## Target tracking

<!-- Link the target issue or handoff only when accessible and safe to share. -->
```
