# Generic distribution and multi-runtime gap matrix

Date: 2026-07-22

This audit is the implementation baseline for the next toolkit release. A cell is complete only when the public `agent-workflow.sh` interface can prove it; prose or a locally installed binary is not sufficient.

## Invariants

- Distribution profile, target verification profile, agent runtime, workflow role, and transport are independent choices.
- Transport adapters launch an already-recorded runner. They never choose or implement an agent runtime.
- Runtime adapters execute one typed role. They never own admission, artifact freshness, or completion.
- Missing capabilities fail before write admission and never trigger runtime or transport fallback.
- RUN and transport artifacts are lifecycle evidence only. Fresh REVIEW and VERIFY bound to live HEAD remain completion authority.
- Existing installs remain the `feedbackops` compatibility profile; generic adoption is explicit.

## Evidence matrix

| Axis | FeedbackOps compatibility | Generic | Gap |
|---|---|---|---|
| Installation | `install-into.sh` transactionally manages scripts, schemas, docs, Claude skill, and model allocation | No selectable distribution profile | Add `--profile feedbackops|generic`; preserve the current default for compatibility; install runtime-neutral skills/personas in generic mode |
| Verification | `verify.sh` and `prepare-verify-db.sh` retain pnpm/Vitest/Postgres behavior | `target-verify.sh` plus Node, Python, and Go examples are shipped | Generic install still ships FeedbackOps-named documentation and compatibility scripts; define profile-owned installed inventory |
| Product identity | README title and clone URL are `feedbackops-workflow` | Coordination core is mostly target-neutral | Add a generic product-facing entrypoint and keep FeedbackOps guidance as an explicit compatibility profile |

| Runtime | Conductor | Worker/write | Reviewer/read-only | Verifier/release roles | Current evidence |
|---|---|---|---|---|---|
| Codex | Persona is usable manually, but conductor launch/capability is not typed | Supported through `codex-watchdog.sh` -> `codex-safe.sh` | Canonical review publication supported | Mostly manual/persona-driven | Runtime is hard-coded throughout dispatch; RUN type is `codex_run` |
| Claude Code | Historically assumed as the human-facing conductor | Not reachable through public dispatch | Not reachable through canonical review publication | Manual only | Docs mention Claude, but no executable runtime adapter or capability proof exists |
| OpenCode | Unsupported | Unsupported | Unsupported | Unsupported | Local CLI 1.17.13 exposes `run --dir --model --variant --agent`; official permissions support per-agent deny/allow rules |

| Transport/lifecycle phase | cmux | Orca | Runtime coupling gap |
|---|---|---|---|
| Capability probe | Typed and fail-closed | Typed and fail-closed | `capabilities` reports transports only, not runtimes or roles |
| Admission | Shared core | Shared core | Core resolves and pins `codex` before admission regardless of selected role/runtime |
| Launch | Launches recorded runner | Launches recorded runner | Runner always invokes `codex-watchdog.sh` |
| Inspect/rebuild | Transport-neutral receipt and disk-only rebuild | Same | Runtime and role are absent from receipt/RUN identity |
| Completion | REVIEW/VERIFY, live HEAD | Same | Correct already; must remain unchanged |

## Smallest implementation order

1. Add a runtime adapter interface with `capabilities` and typed `run`; implement Codex, Claude Code, and OpenCode adapters plus deterministic fakes.
2. Add `--runtime` and `--role` selection to the public interface/config with `CLI > env > config`, independent from `--orchestrator`.
3. Generalize watchdog/RUN identity and canonical review publication while retaining Codex compatibility facades and legacy schema fixtures.
4. Add distribution profiles and managed skill/persona leaves for Claude Code, Codex, and OpenCode; keep upgrade transactional and legacy installs recognized.
5. Update the playbook/personas so any runtime may conduct and all roles share the disk-authoritative lifecycle.
6. Prove the matrix through offline smokes, clean generic and FeedbackOps install fixtures, restart/rebuild tests, then safe live probes for all locally available CLIs.

## Explicit non-solutions

- Runtime inferred from model name.
- Claude Code or OpenCode launched through a Codex-named wrapper.
- OpenCode `--auto` without an installed, validated deny-first role profile.
- A generic install that merely documents away shipped FeedbackOps files.
- Treating a conductor prompt as proof that the conductor runtime is supported.
