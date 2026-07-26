# Objective model-routing extension design

## Outcome

Add a deterministic, provider-aware **model/effort selector** that extends the current workflow without taking ownership from existing seams. It selects one exact tuple only after runtime, role, tier, scope, sandbox, and verification requirements have already been admitted by their current owners.

The outcome is deliberately narrower than “dynamic routing”:

- v1 does not auto-select a provider/runtime, transport, sandbox profile, permission mode, verification path, or external final gate.
- v1 does not use live benchmark scores, price estimates, LLM judgement, aliases, or telemetry to choose a model.
- v1 applies only to a policy-opted-in, allocator-owned **canonical redispatch** whose existing Git-common-dir admission transaction can bind a digest. Both explicit `--allocate` and the implicit implementation allocation when neither manual tuple flag is supplied are allocator-owned. A policy-opted initial write is refused as `route_mode_unbound`; no-policy, any non-empty CLI `--model` **or** `--effort`, and dry-run paths bypass routing byte-for-byte as they do today.
- v1 either emits an immutable, reproducible decision or a typed refusal before any dispatch side effect.
- The router itself must cost less than the work it classifies: its normal path has no LLM call, LSP call, repository walk, git command, or diff analysis.
- Outcome collection is a separate, advisory plane over existing local telemetry. It supplies evidence for a later human-reviewed policy revision; it never learns or changes a route at dispatch time.

The source research is [2026-07-25-model-routing-design.md](../research/2026-07-25-model-routing-design.md). This design incorporates an independent Opus 5 medium proposal and a Sol medium adversarial review. Their decisive correction: a route digest belongs in the existing atomic admission identity, not merely in a post-admission transport receipt.

## Existing authority that must remain unchanged

| Existing owner | It continues to own | Routing rule |
| --- | --- | --- |
| CONDUCTOR / ROUND-STATE | issue scope, acceptance criteria, revision, failure/diagnosis state | Router reads validated facts only; it never writes ROUND-STATE except the existing admission path may record the admitted digest. |
| `agent-workflow.sh` / `dispatch-core.sh` | runtime, role, transport selection; prompt and admission validation; atomic consumption | It classifies mode before allocation/remote compatibility preflight. For an eligible policy route, it calls the router after canonical validation and allocation but before compatibility preflight, marker, runner, transport, or admission consumption. |
| `model-alloc.sh` | current default tuple, evidence adaptation, `available_via`, reviewer preference | Keep its exact interface and checks. Routing may consume its output as candidate order; it must not reimplement or override it. |
| Runtime adapters and `codex-safe.sh` | executable invocation, runtime-native flags, sandbox/permissions, and the existing launch-time compatibility check | Router checks only static identity/configuration. It never claims remote model availability, manufactures another runtime's CLI syntax, or alters sandbox arguments. |
| REVIEW / VERIFY / candidate closure | completion authority | Route data is non-authoritative provenance and can never make a task complete or green. |
| Existing local telemetry | append-only attempt, usage, retry, and canonical-closure reporting | It may copy immutable routing provenance for admitted attempts. It is structurally excluded from selection and cannot edit policy. |

This is an extension at the preflight seam. It does not add a second workflow engine, artifact authority, or admission path.

## Canonical terms

Use the terms in [CONTEXT.md](../../CONTEXT.md): Route, Demand, Runner offer, Routing policy, Route digest, and Refusal. In particular, **Demand is not a new CONDUCTOR-authored document** and a Runner offer is not a claim about scope or review authority.

## Deep module and interface seam

Create one deep module, with one public interface:

```text
toolkit/scripts/lib/route.cjs
  decide({ demand, offer, policy, modelAlloc, now })
    -> { status: "admitted", selected, route_digest, reasons }
     | { status: "refused", code, reasons }

toolkit/scripts/route.sh
  decide --demand <json> --offer <json> --policy <json> [--model-alloc <json>] --now <rfc3339>
  probe --runtime <runtime> --depth static [--ttl-seconds <n>]
```

`decide` is pure: no filesystem, subprocess, clock, mutation, telemetry, or network access. `route.sh` handles parsing and a cached static identity/configuration read. `dispatch-core.sh` is the sole production caller. Adapters never call it.

This gives callers a small interface and keeps ordering, parsing, eligibility, digesting, and refusal classification local. It follows the existing `verify.sh + lib/verify-result.cjs`, review-capsule, and parallel-plan pattern.

## Cost ladder and static-analysis boundary

Routing is a selector, not a task-analysis engine. Its resource bounds are part of its interface:

| Level | Permitted work | Hard bound | Prohibited work |
| --- | --- | --- | --- |
| L0: decide | Parse a bounded policy and already-resolved canonical facts; run the pure selector | one local Node process; at most five bounded input files / 256 KiB; 150 ms; zero `git` subprocesses and zero directory walks | LLM invocation, LSP, git, `rg`, file-content or repository-wide analysis |
| Static identity/configuration | Read the pinned executable version and one already-resolved permission file, then cache the result | at most two subprocesses; 50 ms; default TTL 1800 seconds, ceiling 3600 seconds | model prompt/probe, network, repository access, model-availability assertion |

Any bound breach produces `route_demand_unavailable`; it never uses partial evidence, retries, or silently increases analysis depth.

The policy schema caps the policy at 64 rules and each rule at 16 candidates; over-cap input is `route_policy_invalid`, not an invitation to scan more configuration.

L0 is the only legal route path for an eligible v1 redispatch. `route.sh decide` must also succeed with `git` absent from `PATH`. Routing never generates diff evidence: the existing `model-alloc.sh --evidence` input remains the sole producer for changed-lines/file-count/touch-set adaptation, and the router consumes only its emitted tuple. The existing pre-scope-lock consumer pass, target-native indexes/LSP, and `completion-check.sh` typecheck remain CONDUCTOR/verification work: routing may read their recorded `live_probes[]` result but never invoke them. A separate toolkit impact-analysis module is explicitly out of scope unless a concrete target proves that `live_probes[]`, `compile_consumers[]`, and the current contract cannot express the needed fact.

## Objective evaluation pipeline

Every stage is a gate. A failed gate stops evaluation and emits its stable refusal code; later stages never compensate with a score.

| Stage | Objective input (owner) | Pass criterion | On failure |
| --- | --- | --- | --- |
| 0. Mode classification | parsed command plus existing RUN/BLOCKER/ROUND-STATE marker facts | classify initial write versus canonical redispatch before allocation or remote compatibility preflight | existing malformed-command failure; routing is not invoked |
| 0a. Mode binding eligibility | policy opt-in plus existing dispatch classification and Git-common-dir admission store | write is a canonical redispatch with a pre-consumption admission key and an existing atomic host binding transaction | `route_mode_unbound`; no selector, allocator change, **model compatibility preflight probe**, marker, runner, transport, receipt, telemetry, or ordinal advance |
| 0b. Canonical preconditions | existing prompt, ROUND-STATE, role/runtime/tier, worktree/HEAD checks | current admission preconditions already pass | existing failure; router is not invoked |
| 1. Demand construction | validated role/runtime/write mode; ROUND-STATE tier/revision/failure facts; pre-consumption admission key; existing `model-alloc` result | schema-valid, each field is on the Demand allowlist and has a canonical source | `route_demand_invalid` |
| 2. Policy validity | host-pinned immutable policy snapshot + current `model-alloc` output | unknown fields, duplicate candidates, unknown conditions, dirty/unpinned policy rejected | `route_policy_invalid` |
| 3. Static identity/configuration validity | absolute executable pin, version, observed timestamp/expiry, permission-file digest | fresh static identity only; no alias or remote-availability assertion | `runner_offer_invalid` or `runner_offer_expired` |
| 4. Hard eligibility | selected runtime/role/write mode plus policy and static identity/configuration | candidate is exactly the existing `model-alloc` tuple and respects existing adapter/sandbox gates | `candidate_ineligible` or `sandbox_profile_mismatch` |
| 5. Deterministic selection | eligible policy candidate order | first eligible candidate wins; no score or hidden fallback | `no_route_candidate` |
| 6. Atomic binding | host-owned pre-consumption admission record | digest of demand+offer+policy+decision is bound atomically before launch | `route_digest_unbound` or `route_digest_mismatch` |
| 7. Derivative recording | RUN/transport provenance and telemetry | receipt copies the bound digest; telemetry only observes it | receipt validation failure; never re-route |

The evaluation result is reproducible from stored inputs. It asserts only that a policy-approved tuple passed hard gates and won a fixed order; it does not assert a universally “better model.”

## Where current model choices come from

Until a project opts into a routing policy, behavior must be byte-identical to today. The existing `model-alloc.json` and `model-alloc.sh` remain the source of default model/effort adaptation:

| Existing evidence path | Existing resulting allocation |
| --- | --- |
| normal implementation | `implementation` allocation (currently `gpt-5.6-terra` low) |
| small touch set | `trivial_implementation` allocation (currently `gpt-5.6-luna` low) |
| exported-contract touch | current implementation model at least medium; current contract gate remains `gpt-5.6-sol` medium |
| large touch set | current implementation model at high effort |
| blocker or two consecutive finding rounds | one current evidence-defined effort promotion; no implicit model switch |
| reviewer | current `reviewer` allocation (currently `gpt-5.6-sol` medium, with existing rereview behavior) |
| external clean-context Opus/Fable gate | remains manual and outside v1 automatic routing |

A policy is an **ordered allowlist**, not a scorecard:

```json
{
  "rules": [{
    "when": {"runtime": "codex", "role": "implementation"},
    "candidates": {"from": "model_alloc"},
    "fallback": "deny"
  }]
}
```

`model_alloc` means the exact tuple already returned by `model-alloc.sh`; it does not re-run selection. In v1 this is the **only** permitted candidate form. Literal candidates and cross-provider alternatives are deferred: they could bypass `model-alloc.sh`'s existing reviewer-capability gate. No v1 route crosses from Codex to Claude/OpenCode or vice versa.

## Demand and offer boundaries

Demand may include only already-authoritative facts:

- role, runtime, write mode, and tier from existing admitted command/ROUND-STATE inputs;
- issue, worktree realpath, live/base HEAD, ROUND-STATE revision, and the **pre-consumption admission key** from current admission;
- `contract.touch_allowlist`, `contract.chunk_boundary.compile_consumers[]`, and `live_probes[]` only as already-recorded facts; and
- the exact tuple and rationale already emitted by `model-alloc.sh`.

Consumed ordinal, attempt marker, and transport identifier are not Demand fields: including them would make the digest depend on the record it must bind. `changed_lines`, `file_count`, and `touch_set` are not router Demand fields at all. The existing allocator evidence path owns them; absent evidence remains absent and is never coerced to `0`.

A Runner offer is host-owned and narrow:

```json
{
  "runtime": "codex",
  "executable": "/absolute/pinned/executable",
  "version": "observed-version",
  "observed_at": "RFC3339",
  "expires_at": "RFC3339",
  "permission_profile_digest": "sha256-of-the-one-already-resolved-permission-file"
}
```

`probe --depth static` means no model call, network call, or repository access. It establishes only pinned executable/configuration identity; it does **not** prove a remote model is currently available or resolve an alias. Existing launch-time compatibility preflight retains that responsibility and its pre-marker failure behavior. The offer must not claim that a model satisfies scope, sandbox equivalence, or verification. The runtime's own adapter remains the owner of those facts.

## Route digest and admission binding

`route_digest = sha256(canonical(demand, stable_offer_identity, policy, decision))` is created before side effects. `stable_offer_identity` contains only `runtime`, `executable`, `version`, and `permission_profile_digest`; `observed_at` and `expires_at` prove freshness at selection time but are deliberately excluded so a cache refresh cannot change the same route's digest. Its sole authority is a host-owned, Git-common-dir admission binding record published by the existing atomic prepare→rename/recovery protocol. A worker-writable worktree marker may contain only a diagnostic copy; `mkdir` followed by a digest write is never an atomic binding.

V1 has one eligible dispatch mode: a canonical redispatch with its existing Git-common-dir admission transaction and pre-consumption key. `dispatch-core.sh` must classify that mode before its current allocator sites and before the remote model-compatibility probe. An opted-in initial write (Trivial, Standard, or Full Cluster) is rejected as `route_mode_unbound` before selector execution or compatibility probing; it must not fall back to the worktree `mkdir` marker or silently bypass the opted-in policy. Adding initial-write routing requires a later generic host admission transaction, not a parallel route-marker protocol. V1 deliberately does not add route state to ROUND-STATE. `transport_receipt` v3 is derivative, non-authoritative data. A receipt can never recreate or replace route identity.

For a normal canonical redispatch, `$ADMISSION_ROOT/$ADMISSION_KEY` is the sole route-binding authority. `integrated_fix` retains its singleton plus ordinal transaction shape, but its ordinal record is still authoritative and the singleton is only a recovery companion. A policy-routed prepared record must contain the exact digest; a policy-routed integrated pair must contain byte-identical digest fields.

Recovery receives the newly computed expected digest for the **current** admission key only. `recover` may commit a prepared normal record only when that record's key is current and its authoritative ordinal digest matches; for an integrated pair, the current ordinal must exist and match its companion. A key-mismatched existing singleton is neither adopted nor reclaimed: it retains its current ordinal-based sentinel behavior. A current integrated singleton with no paired ordinal is `route_digest_unbound` and never adoptable, even if the ROUND-STATE ordinal advanced. Non-adoptability does not disable reclaim: when the ordinal has not advanced, `recover` still removes an interrupted current-key prepared singleton and its paired ordinal exactly as today, so retry remains possible. `recover-lock` has no adoption path: its current key is the dead lock owner's recorded `admission_key`, and it preserves the existing stale-lock/unadvanced-prepared reclaim regardless of an absent or mismatched digest. A missing or mismatched current-key digest therefore blocks adoption in `recover`, not reclaim in `recover-lock`. This requires changing the adoption predicates in `admission-recover.cjs`, not merely adding a schema field.

Refusal is pure selector stdout: it publishes no `.review` receipt, admission record, marker, runner, transport, or telemetry sample.

## Explicit v1 exclusions and v2 evidence gate

### v1

- one-host static identity/configuration cache only; it has a 1800-second default TTL and 3600-second ceiling but is not a remote-availability cache;
- policy schema/fixtures and optional project opt-in, but no default installed policy file—absence preserves current behavior;
- exact allocator-owned model/effort routing only within an already selected runtime and canonical redispatch; any manually supplied `--model` or `--effort` flag and dry-runs bypass v1 routing;
- typed refusal, atomic digest binding, and one advisory routing-provenance copy on an admitted local telemetry sample.

### Not before v2

- cross-provider automatic routing;
- dynamic pricing or latency optimization;
- predictive ranking, aliases without resolved identity, or automatic remediation/fallback;
- telemetry-driven policy mutation;
- multi-host offers.

## Observational foundation and later policy improvement

The existing opt-in local telemetry is the only collection foundation. The data-foundation slice adds one small immutable `routing` object to an admitted telemetry sample only after the collector validates the canonical receipt against the host binding and derives fields from that validated source:

```json
{
  "selection_basis": "legacy_model_alloc | ordered_policy",
  "route_pseudonym": "HMAC(local-telemetry-salt, route_digest)",
  "policy_digest": "sha256:... | null",
  "runtime": "codex",
  "decision_reason_codes": ["model_alloc"]
}
```

It stores no raw route digest, prompt, source text, raw task prose, LSP result, pricing lookup, or model self-rating. Runtime/model/effort and routing provenance are derived, not supplied by telemetry CLI flags; missing canonical binding/receipt is rejected. Existing telemetry already supplies the result side: duration, retry chain, terminal state, usage provenance, and canonical green closure. Refusals are not execution samples; no new durable learning artifact or background collector is introduced in this phase.

Schema evolution is explicit: legacy telemetry samples and reports remain schema v1 and retain current parsing. A policy-opted sample is `telemetry_sample` v2 with the bounded `routing` object required; its collector derives and cross-checks runtime/model/effort against the validated receipt+binding instead of trusting CLI values. The reporter accepts v1 and v2 but forms routing cohorts only from schema-v2 policy samples. `transport_receipt` v3 is required only for policy-opted launches; v2 remains the no-policy/manual compatibility form.

Reports compare only homogeneous cohorts: `selection_basis`, policy digest, runtime, role, task class, tier, and model/effort. Their descriptive measures are complete-green rate, retries-to-green, wall time, and separately reported observed/estimated/unavailable usage. A report must suppress cohorts below declared **complete independent-chain** count or completeness thresholds and must say "insufficient evidence", not "no improvement".

This is observational, not a causal universal model ranking. Reports must not claim a model *caused*, *saved*, or was *better*; they show descriptive associations and an explicit confounder warning. An optional later human annotation keyed by the route pseudonym may classify a route as `under`, `appropriate`, or `over`; it is never generated by the selected model and never consumed by the router. A new policy revision is the only permitted response: it is reviewed, versioned, and compared against its prior cohort. Reports may describe; they never write policy or recommend an automatic change.

## Required schema and implementation slices

1. Add static-identity/configuration and admitted-only `route_receipt` schemas with valid/invalid fixtures; a refusal remains stdout only.
2. Add the pure selector and its Bash 3.2-compatible CLI wrapper, with offline tests and an injected `now`.
3. Add a cached static identity/configuration read; do not invent a capability inventory, generic permission probe, or availability probe.
4. Classify write mode before both allocator sites and the remote compatibility preflight. Add dispatch-core routing only for policy-opted-in allocator-owned canonical redispatches, after canonical validation/allocation and before the compatibility probe, marker, runner, or adapter launch. An opted-in initial write returns `route_mode_unbound`.
5. Extend the existing host-owned canonical-redispatch admission record with a digest over time-independent stable offer identity. Make `recover` verify the expected digest for its invoking key before adoption; require a present authoritative ordinal and ordinal/singleton equality before it adopts an `integrated_fix` pair. `recover-lock` has no adoption path and must preserve its existing stale-lock/unadvanced-prepared reclaim regardless of digest. Absent/unequal fields refuse adoption but retain that reclaim. Initial-write support is deferred until it has a generic host transaction.
6. Extend transport receipt as a derivative copy and make telemetry derive a salted routing pseudonym only from validated receipt+binding; do not add a second collector, learner, or background service.
7. Cover installation/release containment (`install-into.sh`, installation smoke, release-contract smoke) as well as route/preflight smoke cases; update the playbook, README, and STATUS in the same change.

## Implementation-planning: first two code slices

The first implementation change is deliberately limited to admission identity.
It does not add telemetry, a receipt field, an installed policy, or an initial
write route. Those remain later slices because they depend on a successfully
bound canonical redispatch record.

### Slice 1 — classify write mode before allocation or compatibility probing

| File | Change | Verification responsibility |
| --- | --- | --- |
| `toolkit/scripts/dispatch-core.sh` | Immediately after resolving and validating `ABS_WORKTREE`, derive `RUN_FILE`, `BLOCKER_FILE`, `DEFAULT_ROUND_STATE`, `WRITE_ATTEMPT_DIR`, `REDISPATCH_REQUIRED`, and `INITIAL_WRITE`. Move the existing initial-tier contract check to this early classification block. Do not perform model allocation, synthesize a default effort, or run the remote model-compatibility probe before it. | Existing no-policy command paths retain their current allocation and launch order after this block. |
| `toolkit/scripts/dispatch-core.sh` | Add one private routing-eligibility helper at the preflight seam. It reads only an explicitly opt-in, host-pinned policy snapshot and the parsed CLI flags; it is not a router and does not inspect repository content. A policy-opted write with a non-empty CLI `--model` or `--effort`, a dry run, or no policy exits through the existing bypass path. A policy-opted `INITIAL_WRITE=1` exits `route_mode_unbound` before either allocator site or the remote compatibility probe. | The refusal performs no selector call, marker/runner/adapter/receipt/telemetry write, or ordinal advance. No-policy trivial, standard, and full-cluster initial writes remain byte-for-byte compatible. |
| `toolkit/scripts/dispatch-core.sh` | Keep canonical ROUND-STATE, prompt, and redispatch checks as the source of Demand facts. Invoke later selector/binding work only after those checks produce the current `ADMISSION_KEY`; do not create a second mode detector or calculate router facts from a worktree diff. | A malformed canonical redispatch remains an existing admission error, not a route refusal. |
| `toolkit/scripts/__tests__/cmux-dispatch.smoke.sh` | Extend the fixture dispatcher to prove ordering using a failing allocator stub and a model-probe sentinel. Cover an opted-in initial write for each `trivial`, `standard`, and `full_cluster` tier, plus manual tuple, dry-run, and absent-policy bypasses. | `route_mode_unbound` must occur before the allocator and probe sentinels, and the Git-common-dir admission directory must remain absent. |
| `toolkit/scripts/__tests__/runtime-model-preflight.smoke.sh` | Add the narrow preflight assertion that an unavailable model remains the existing `model_compatibility_unavailable` refusal after eligible mode classification. | Routing never asserts availability and does not replace the current pre-marker failure. |

The resulting module interface is intentionally small: `dispatch-core.sh`
hands later routing code one already-classified mode plus a validated current
admission key.  The selector does not need to learn about RUN/BLOCKER layout,
tiers, or the legacy initial-write contract.

### Slice 2 — extend canonical redispatch recovery with a route digest

| File | Change | Verification responsibility |
| --- | --- | --- |
| `toolkit/scripts/lib/admission-recover.cjs` | Extend transaction metadata with an optional `route_digest` for policy-routed records. Thread the expected digest only through `publish`, `recover`, `commit`, and the paired integrated record checks. Legacy/no-policy records preserve their current metadata and recovery behavior. | An admitted policy record has the same digest in its authoritative ordinal transaction and, for `integrated_fix`, its singleton companion. |
| `toolkit/scripts/lib/admission-recover.cjs` | Make `recover` accept the newly computed expected digest for the current key. A policy-routed normal record is adoptable only when its current-key ordinal record has that exact digest. For `integrated_fix`, adopt only when the current-key ordinal exists and its digest equals both the expected digest and the singleton companion digest. Report `route_digest_unbound` for an absent required current-key binding and `route_digest_mismatch` for unequal values. | A stale/foreign key is neither adopted nor reclaimed; it keeps the existing sentinel behavior. A policy record cannot become committed merely because the ROUND-STATE ordinal advanced. |
| `toolkit/scripts/lib/admission-recover.cjs` | Leave `recover-lock` as reclaim-only. It must neither accept nor reject adoption based on a digest, and must keep the existing dead-lock, unadvanced-prepared-pair reclaim behavior. | An interrupted current-key integrated prepare with no ordinal advance still clears both prepared entries and permits a retry, even when its digest is absent or malformed. |
| `toolkit/scripts/dispatch-core.sh` | Once the later pure selector returns an admitted digest, pass it as the expected digest to the existing recovery and publication calls while the issue lock is held. Map typed recovery refusal output to the stable dispatch error without writing a transport receipt. Do not pass a digest to no-policy/manual/dry-run paths. | The Git-common-dir ordinal record remains the sole authority; any worktree copy is diagnostic only. |
| `toolkit/scripts/__tests__/cmux-dispatch.smoke.sh` | Reuse the existing real-Git admission fixture and kill-window seams for normal and integrated cases: matching prepared recovery, digest-less prepared record, mismatched ordinal, mismatched singleton, missing ordinal, prior-key singleton, and reclaim before advance. | Test actual on-disk transaction files and ordinal progression, not only process exit text. |
| `toolkit/scripts/__tests__/redispatch-check.smoke.sh` | Retain its responsibility for producing the exact next `ADMISSION_KEY`; add only a regression that revision/failure mutations cannot mint a key usable to adopt a foreign digest. | `redispatch-check.sh` remains a key producer, never a route-digest authority. |

Slice 2 is complete only when recovery uses the same deep admission module for
normal and integrated records.  Do not introduce a separate route-marker
protocol or a worker-writable source of truth; deleting the recovery extension
must make the digest-binding safety disappear from one place, not reappear in
every transport adapter.

## Acceptance and negative-test matrix

| Case | Required result |
| --- | --- |
| identical demand/stable-offer-identity/policy/now | byte-identical decision and digest |
| identical stable offer after cache timestamp refresh | same digest; freshness is checked independently of digesting |
| no policy, any manually supplied `--model` or `--effort`, or dry-run | complete routing bypass; current allocation/launch/telemetry behavior byte-identical |
| policy schema error, duplicate candidate, unknown key | typed refusal; no admission effect |
| dirty/unpinned policy, malformed static identity, relative executable | typed refusal; no fallback/re-probe |
| remote model becomes unavailable after selection | existing launch-time compatibility preflight refuses before marker; router never claimed availability |
| wrong runtime/provider, unsupported effort, altered permission profile | typed refusal even for the highest-ranked candidate |
| literal candidate or candidate not equal to `model-alloc` tuple | `route_policy_invalid`; v1 cannot bypass reviewer capability gates |
| policy-opted initial write (Trivial, Standard, or Full Cluster) | `route_mode_unbound`; no selector, allocator change, model-compatibility probe, marker, admission record, runner, transport, receipt, telemetry, or ordinal advance |
| refusal or selector crash | no marker, admission record, runner, transport, or ordinal advance |
| replay under different issue/worktree/HEAD/revision/pre-consumption key | `route_digest_mismatch`, no recovery theft |
| interrupted, digest-less, foreign, or mismatched prepared binding for the current key | cannot be adopted, including after the ROUND-STATE ordinal advanced |
| prior-key `integrated_fix` singleton | neither adopted nor reclaimed; preserves existing integrated-fix sentinel behavior |
| incomplete current-key `integrated_fix` singleton | `route_digest_unbound`; never adopted even after ordinal advance |
| interrupted current-key `integrated_fix` prepare with no ordinal and no ordinal advance | existing reclaim clears the singleton; retry may admit |
| `integrated_fix` prepared pair | ordinal is authoritative; `recover` refuses adoption on absent or unequal ordinal/singleton digest fields, while `recover-lock` has no adoption path and keeps existing reclaim unchanged |
| adapter invocation | receives its native exact tuple only; routing cannot alter sandbox/transport args |
| receipt | host binding is authoritative; every opted-in mode requires host-binding == receipt; receipt alone cannot authorize anything |
| circuit-breaker diagnosis active | no “try harder” escalation beyond existing bounded policy |
| no-policy Trivial initial write | complete routing bypass; existing behavior stays byte-identical |
| L0 decision with `git` unavailable | succeeds with the existing default/all-authoritative input path; no hidden git or analysis dependency |
| L0 process accounting | one selector process only; policy size over 64 rules or 16 candidates/rule is rejected |
| telemetry routing provenance | collector rejects raw/CLI-supplied routing fields or an unvalidated receipt/binding; stored route identifier is salted |
| telemetry report | policy/config unchanged byte-for-byte; routing library has no telemetry dependency; report suppresses cohorts below complete independent-chain thresholds and contains a confounder warning |

## Confirmed design decisions before implementation

1. V1 is single-host and uses a static identity/configuration cache only: default `1800s`, ceiling `3600s`; it does not attest remote model availability.
2. There is no default policy file. No-policy, a manually supplied `--model` or `--effort`, and dry-run dispatches bypass the selector and preserve current behavior. Both explicit and implicit `model-alloc` sites are allocator-owned when no manual tuple flag is supplied.
3. V1 routing is canonical-redispatch-only. A policy-opted initial write is a `route_mode_unbound` refusal until a generic host admission transaction is designed; it never uses the worktree marker as route authority.
4. V1 policy candidates must be exactly `{ "from": "model_alloc" }`; policy bytes are host-pinned immutable snapshots, never mutable worktree configuration.
5. Refusals are stdout-only and leave no routing/admission/telemetry artifact. Admitted telemetry stores only a locally salted routing pseudonym after receipt+binding validation.
6. Automatic cross-provider routing, availability probing, predictive ranking, background learning, and telemetry-driven policy mutation remain out of scope.
