# README reference research — workflow toolkit

Date: 2026-07-21  
Scope: structure and information architecture for `toolkit/README.md`; this is
not source text to copy.

## Primary-source patterns

### GitHub Actions Toolkit

The [official Actions Toolkit README](https://github.com/actions/toolkit/blob/main/README.md)
opens with CI/security status and one sentence defining the product, then gives
the first productive link before enumerating its packages.  Each package entry
has the same compact unit: name, purpose, and installation command.  The
second half routes readers by job (create an action, version it, use a proxy,
report a security concern) instead of narrating implementation internals.

**Pattern to retain:** make the top of the page answer *what this is*, *whether
it is healthy*, and *where a new adopter starts*; use a short capability map
that links to the authoritative detailed documents.

### mise

The [official mise README](https://github.com/jdx/mise/blob/main/README.md)
states the value proposition in one sentence, names its three mental-model
objects (tools, environment variables, tasks), and then gives a runnable
quickstart.  Its examples move from one small command to a combined project
configuration; deeper reference material is deliberately delegated to the
documentation site.  It also labels the community/support route directly.

**Pattern to retain:** explain the product through a small set of durable
concepts, then give a copyable "install → first useful action" route.  Put
advanced configuration and exhaustive reference material behind links.

### pre-commit

The [official pre-commit README](https://github.com/pre-commit/pre-commit/blob/main/README.md)
keeps the repository landing page deliberately narrow: status badges, one
line of purpose, and a single authoritative documentation destination.  This
works because the README is a router, not a second, drift-prone manual.

**Pattern to retain:** when a contract is complex and versioned elsewhere,
make the README a trustworthy orientation and command surface, not a duplicate
of the playbook or schema commentary.

### Renovate

The [official Renovate README](https://github.com/renovatebot/renovate)
follows the promise with features and supported surfaces, then separates the
operator's primary choice into Cloud-hosted, self-hosted, pipeline, and CLI
routes.  Its later sections route to documentation, contribution channels, and
security disclosure rather than embedding each operating procedure.

**Pattern to retain:** resolve the adoption choice before presenting detailed
commands.  This toolkit needs an explicit distinction between adopting it into
a compatible target and intentional `--self-test` dogfooding; the README can
route both paths to their authoritative procedure.

## Implications for this toolkit

`toolkit/README.md` already has strong operational facts, but its first
screen presents nine dense feature bullets before the adoption command and
then repeats much of the playbook's procedure.  The product has a clearer
adoption story than the current order exposes: a self-contained copy install,
one mandatory write-dispatch path, and evidence—not agent prose—as the merge
authority.  The README should surface those claims early and move detailed
dispatch/admission/verification rules to the playbook.

Current facts that the rewrite must preserve:

- v0.18 is the current toolkit release (`STATUS.md`), and `git log` wins over
  mutable status prose.
- Fresh installs and `--upgrade` manage exactly four self-contained leaf
  trees; upgrades are transactional and fail closed for unrecognised layouts.
- `cmux-dispatch.sh` is the sole visible write-dispatch entry point and
  `codex-safe.sh` is the mandatory write wrapper.
- A worker message or `RUN.json` exit is not completion; merge evidence is a
  live-HEAD-bound canonical REVIEW plus VERIFY artifact.
- The reusable coordination core has explicit target-specific compatibility
  boundaries (currently pnpm/TypeScript/Vitest/PostgreSQL for preparation and
  verification).

## Proposed `toolkit/README.md` outline

1. **Title, one-sentence promise, and concise status line** — describe the
   toolkit as an opt-in, evidence-driven multi-agent workflow for isolated
   worktrees; link `STATUS.md`, release history, and CI only where live badge
   URLs are verified.
2. **Why it exists / merge rule** — three short bullets: isolated writers,
   canonical disk evidence, host-side independent verification.  State the
   key non-goal: worker prose and process exit are not completion.
3. **Choose an adoption path, then start** — distinguish target adoption from
   explicit `--self-test` dogfooding.  For a target, give a minimal, copyable
   path: clone/test toolkit; install into target; link to the compatibility
   interview before running it on a non-FeedbackOps target.  Keep upgrade as a
   short adjacent subsection.
4. **Mental model** — small diagram of `issue contract → isolated worktree →
   guarded dispatch → REVIEW/VERIFY → merge decision`, with one sentence
   defining CONDUCTOR, implementer, REVIEWER, and VERIFIER.
5. **First controlled dispatch** — one complete standard-tier command, clearly
   marked as an operator example; put ROUND-STATE construction and all flags
   in the playbook.
6. **Trust and safety boundary** — six compact, actionable rules: mandatory
   wrapper/dispatcher, one writer per checkout, no remote DB verification,
   sandbox/host separation, canonical artifacts, no destructive auto-rebase.
7. **Capability map** — grouped table: install/adopt; dispatch/liveness;
   contract/gates; verification/state reconstruction.  Link each group to the
   playbook or script help rather than adding per-script internals here.
8. **Compatibility and adoption** — retain the current explicit matrix;
   position it before advanced use so adopters see target assumptions early.
9. **Architecture and artifact contracts** — keep a shortened artifact table
   and link schema/lifecycle documentation; avoid restating every validation
   rule.
10. **Documentation, contribution, and support** — link the playbook,
    adoption guide, artifact lifecycle, issue-reporting contract, trial log,
    `STATUS.md`, and `AGENTS.md`.  Preserve Bash 3.2 and smoke-suite
    contribution gates.

## Rewrite constraints

- Keep Korean as the main operator language and preserve exact commands that
  are part of the installed-product contract.
- Do not invent badges, support channels, feature claims, compatibility, or a
  package-manager install route.
- Avoid copying a hand-maintained smoke count or duplicating mutable roadmap
  status; route readers to `run-all.sh --list`, `STATUS.md`, and GitHub Issues.
- A README rewrite alone must not change product behavior.  Validate source and
  portable-install Markdown links with the release contract before merge.
