# feedbackops-workflow

The vocabulary for this repo's multi-agent dispatch/review/verify toolkit. Repo
operating rules live in `AGENTS.md`, durable decisions in `docs/adr/`.

This file (the root glossary) is unrelated to `.review/ISSUE-<n>-CONTEXT.md`, a
gitignored, non-canonical scratch file CONDUCTOR writes as authoring notes before
compressing a prompt — same filename stem, different concept, both real. Renaming
that per-dispatch artifact is tracked separately, not done here.

## Core Roles

**CONDUCTOR**:
The orchestrator role, executed by the explicitly selected Codex, Claude Code, or OpenCode runtime in a dedicated pane outside all clusters, overseeing every in-flight cluster and dispatching to worker roles. Read-only on product code; reads worker state exclusively from `.review/*.json`.
_Avoid_: coordinator, orchestrator (as a standalone term — CONDUCTOR is the canonical name)

**CODEX**:
The implementation worker seat name (e.g. "CODEX + VERIFIER" per tier), fillable by any explicitly selected runtime — codex, claude, or opencode — same as every other role. Receives only the compressed prompt file; write-capable execution must delegate to `scripts/codex-safe.sh`.
_Avoid_: implementer, worker (too generic); do not conflate with the `codex` runtime (see Runtime) — CODEX the seat and codex the runtime are independent, a claude or opencode runtime can fill the CODEX seat

**REVIEWER**:
The worker role that checks design fit, owns the checklist and live smoke, and must be a fresh external clean-context seat, different agent/session from the implementer.
_Avoid_: none

**VERIFIER**:
The worker role that checks commands and runs tests outside the sandbox. Must confirm green by running `scripts/verify.sh`; the canonical evidence is the VERIFIER-owned `ISSUE-<n>-VERIFY.json`.
_Avoid_: none

**Release Captain**:
The role every issue has exactly one of, owning merge readiness with override authority. Defaults to the user in interactive mode, or CONDUCTOR in orchestrated mode.
_Avoid_: merger, approver

**ARCHITECT**:
The Full Cluster-tier role that locks design decisions before implementation; may make routine intra-chunk choices without waiting on CONDUCTOR, but is consulted for cross-chunk/contract/tier decisions. For migrations, authorization, persistence, or other repository-dependent capability changes, must attach a feasibility appendix to the authoritative contract before locking a decision.
_Avoid_: designer, lead

**VISUAL-REVIEWER**:
A sub-role run under the REVIEWER umbrella, only on the Full Cluster tier and only when the change touches UI (layout, copy placement, interaction states, design tokens, shells, reusable UI). Must pair with an interaction script covering create/edit/error/empty/permission states; feeds the existing `review` artifact, does not invent a new type.
_Avoid_: VISUAL (the tier table's shorthand `+ VISUAL` means this sub-role, not a standalone role)

**Watchdog**:
The runtime-neutral stall/liveness authority (`agent-watchdog.sh`) that all dispatches run through. Applies first-progress and stall budgets, must not learn per-runtime output schemas, and schema-validates a runtime's PR-DRAFT/BLOCKER before recording `RUN.status: exited`. `agent-watchdog.sh` is the sole watchdog authority; `codex-watchdog.sh` was removed.
_Avoid_: monitor, poller (watchdog is the specific liveness-authority component, not a generic term)

## Dispatch & Admission

**Dispatch**:
The public `agent-workflow.sh` subcommand that launches work along independent tier, runtime, role, and transport axes.
_Avoid_: launch, invoke

**Tier**:
The work-scale axis of a dispatch: `Trivial | Standard | Full Cluster`, set via `--tier` and recorded as `ROUND-STATE.tier.name`. Trivial initial writes stay `pr_draft`-only; Standard/Full Cluster initial writes require the complete canonical ROUND-STATE.
_Avoid_: distribution-profile (a stale CONTEXT.md phrasing with no code counterpart — the real axis is tier)

**Admission**:
The pre-launch gate where missing capability, unsupported isolation, or invalid configuration fails before admission with a machine-readable reason. Write launches validate prompt, ROUND-STATE, and contract bindings before consuming admission.
_Avoid_: launch check, preflight (preflight is used for a narrower sub-check inside admission, not the gate itself)

**Capability probe**:
The pre-admission check proving the selected runtime/role/mode and selected transport are actually available, before admission runs. Each runtime may conduct or perform any role only after its own capability probe passes.
_Avoid_: capability check

**Capability result**:
The `capability-result.cjs` payload — adapter, `available`, version, and a duplicate-free list of non-blank capability strings — consumed by dispatch admission on the transport axis, never by routing. Distinct from Runner offer (see Routing Subsystem below), which is the routing-axis equivalent.
_Avoid_: capability offer, offer, runner

**Capability survey**:
The `agent-workflow.sh capabilities` output — every Transport adapter and Runtime probed and aggregated into one JSON, before any one runtime/role/transport is chosen. Answers "what's available at all right now"; distinct from Capability probe, which answers "is this one already-chosen combination available."
_Avoid_: capabilities check (too easily confused with Capability probe)

**Transport**:
The axis of WHERE the worker process runs: cmux / orca / herdr / (proposed) native.
_Avoid_: none

**Runtime**:
The axis of WHICH model publisher executes inside a transport: codex / claude / opencode.
_Avoid_: none

**Adapter**:
The per-axis-member implementation that normalizes one Transport or Runtime member's differing shape (session model, CLI flags) behind that axis's uniform interface. One file per member — `scripts/adapters/<transport>.sh` for Transport. `agent-runtime.sh` does the equivalent job for Runtime but still inlines all three runtimes in one file rather than splitting; this is known debt, not the intended shape (see [ADR-0006](docs/adr/0006-adapters-are-one-file-per-axis-member.md)).
_Avoid_: wrapper, integration

**Axis registry**:
The declarative single-source-of-truth pattern for one axis's member set and per-member facts (pinned-binary resolution, capability-probe tokens, ownership) consumed by both bash and Node call sites, so no call site re-hardcodes axis membership. Instantiated as `runtime-registry.cjs` (Runtime axis) and `transport-registry.cjs` (Transport axis) — declared twins of each other.
_Avoid_: config, lookup table

**Seat**:
The identifier (`seat_id`, set via `--seat`) distinguishing one concurrent write attempt within a multi-seat EXECUTION-PLAN. Not a Role instance and not a model/effort choice — those are Role and Route respectively; a seat is a plan-scoped write slot, closing as a `seat_outcome` artifact (`source_head`, `changed_paths`, `status`) consumed at merge/integration.
_Avoid_: worker instance, agent instance

## Artifacts

Every worker artifact is a `.review/ISSUE-<n>-<TYPE>.json` file carrying its own `artifact_type` const; each type below is an independent glossary entry — "artifact" is used only as a loose umbrella word, not a parent concept, because the schema layer itself is flat (`toolkit/schemas/*.schema.json` pins each type separately, no shared parent schema).

**Lifecycle**:
The four-valued state field every artifact carries: `draft | active | superseded | final`. Superseded files must be ignored by readers.
_Avoid_: status, state (too generic)

**ROUND-STATE**:
The single canonical `.review/ISSUE-<n>-ROUND-STATE.json` that CONDUCTOR maintains as the normative contract state from dispatch 0, for Standard/Full Cluster work. CONDUCTOR is its semantic owner.
_Avoid_: none

**RUN state**:
The status field of `ISSUE-<n>-RUN.json` (`artifact_type: agent_run`): `running | exited | killed_stall | refused | exhausted`. `exited` proves termination, not completion — no RUN shape has `completed` or `failed` status.
_Avoid_: completion status, result (RUN state is about termination, not outcome)

**BLOCKER**:
The scoped-abort artifact CODEX must produce to abort, recording the abort-time Git `HEAD` in `head_sha` and a `reason_code` from a fixed enum. Recognized as the sole failed-round evidence by the redispatch gate only when `primary_origin: dispatch_contract` and `next_action.kind: contract_fix`.
_Avoid_: error, failure (BLOCKER is a specific typed artifact, not a generic error)

**Redispatch gate**:
The `redispatch-check.sh` policy that derives whether a failed round is allowed to redispatch, from the canonical ROUND-STATE failure history. Correctness policy, not liveness policy — distinct from Watchdog, which governs stall/liveness, not whether a redispatch is warranted.
_Avoid_: retry policy, retry gate (retry implies liveness, which is Watchdog's job)

**Receipt**:
The atomically published, schema-versioned `.review/ISSUE-<n>-TRANSPORT.json` (`artifact_type: transport_receipt`) recording selected runtime, role, observed runtime version, adapter capability evidence, external handle, worktree/runner identity, and timestamps. Explicitly non-authoritative launch intent/provenance, not confirmed command delivery or completion.
_Avoid_: transport record, confirmation

## Candidate Lifecycle

**Integration branch**:
The single clean branch `candidate-integrate.sh` produces by applying every planned seat's delta, in declared order, onto one worktree — never resetting, checking out, or discarding prior seat changes. Evaluated by `candidate-close.sh` against its bound evidence (review, verify, PR draft) before closure.
_Avoid_: candidate (ambiguous — collides with Routing policy's unrelated route-option-candidate sense; always say Integration branch), merge result

## Routing Subsystem

The vocabulary for `lib/route.cjs` and `model-alloc.*` — the fail-closed model+effort
selection that runs inside an already-admitted runtime and role.

## Language

**Route**:
A fail-closed, deterministic decision of one exact `model + effort` tuple inside an already-admitted runtime and role.
_Avoid_: selection, allocation (those are broader — see model-alloc's role-default table in the playbook)

**Demand**:
Normalized, already-validated facts the workflow owns going into a Route decision.
_Avoid_: request, input

**Runner offer**:
A host-observed, expiry-bound statement of one pinned runtime executable and its resolved permission/configuration identity.
_Avoid_: capability, availability (see Capability result above for the distinct transport-axis concept)

**Routing policy**:
A host-pinned immutable project policy snapshot — an allowlist and deterministic route option order.
_Avoid_: config, score model, ruleset, candidate (candidate is the unrelated workflow-lifecycle term — see Integration branch)

**Route digest**:
The digest binding one admitted demand, offer, policy, and selected decision together.
_Avoid_: hash, checksum

**Refusal**:
A typed, stdout-only routing outcome that consumes and publishes nothing (no admission, marker, runner, receipt, or fallback).
_Avoid_: rejection, error, failure

**Routing outcome**:
An immutable, advisory-only join of a validated Route binding with attempt telemetry and closure evidence.
_Avoid_: result, record

## Installation

**Install profile**:
The `profile` field `install-into.sh` writes into a target repo's `install-profile.json`. Previously a choice of `feedbackops | generic`; the `feedbackops` compatibility path (DB-verify scripts, its own `install-into.sh` copy, and related fixtures) was removed, so the field is now a fixed `generic`.
_Avoid_: distribution-profile, profile (unqualified — collides with the Tier axis and with Target profile, see Verification below)

## Verification

**Target profile**:
A target repo's own `target-profile.schema.json`-shaped config (`id`, `runtime.executables`, `environment`, `setup`, `verification`) telling `target-verify.sh`/`lib/target-verify.mjs` how to run that repo's verification. Its `id` is written verbatim into the `target_profile` field of the `verify_result` artifact.
_Avoid_: profile (unqualified — collides with Install profile and the Tier axis), verify config
