# Model routing: provider-aware policy design

Date: 2026-07-25
Scope: design research only. No runtime, schema, or policy has been changed.

## Executive recommendation

Keep routing as a deterministic *admission decision*, not a recommender. Split
the present `model-alloc.json` concern into three independently versioned
inputs, but only after the existing admission path has supplied canonical
facts:

1. **Task demand** — normalized, already-validated role/runtime/write mode,
   tier/revision identity, existing contract/live-probe facts, and the exact
   existing `model-alloc` tuple. It is not CONDUCTOR prose, a new task
   assessment, a risk score, or a price budget.
2. **Runner offer** — a locally read, short-lived record of pinned executable
   and permission/configuration identity; it is not a model-availability inventory.
3. **Policy** — ordered, auditable rules that select one eligible tuple or
   refuse the dispatch.  It must never silently substitute a model, runner,
   permission mode, or verification obligation.

The v1 goal is not predictive “best model” routing. It is a reproducible,
cheap selection record that rejects impossible dispatches and reuses the
existing local telemetry for later measured improvements. The normal router
path must not make an LLM call, an LSP call, a git call, or a repository walk.

## Observed current state

| Observation | Evidence | Consequence |
| --- | --- | --- |
| Configuration is schema-v1 and names roles, capability scores, prices, and `available_via`. | `toolkit/schemas/model_alloc.schema.json`, `toolkit/model-alloc.json` | Provider ownership is modeled, but runner features, model aliases, freshness, budgets, and verification capability are not. |
| Allocation validates configuration before output and rejects a selected model unavailable on the requested runner. | `toolkit/scripts/model-alloc.sh` | This is the correct fail-closed seam to retain. |
| Legacy configs infer only known OpenAI/Anthropic name families and otherwise fail closed. | `toolkit/scripts/model-alloc.sh` (`legacyAvailability`) | Heuristic compatibility must remain migration-only, never become general provider discovery. |
| Evidence can promote effort for contracts, large touch sets, blockers, and repeat findings. | `toolkit/scripts/model-alloc.sh` | Present adaptation is deterministic, but its input is narrow and cannot distinguish capability impossibility from a quality preference. |
| `dispatch-core.sh` calculates allocation before admission markers or transport side effects. | `toolkit/scripts/dispatch-core.sh` | Preserve this ordering: route denial must consume no attempt or workspace. |
| Canonical redispatch has a Git-common-dir atomic admission transaction, while initial writes use only a worktree-local `mkdir` marker. | `toolkit/scripts/dispatch-core.sh`; `toolkit/scripts/lib/admission-recover.cjs` | V1 can bind a route digest only for canonical redispatch; a policy-opted initial write must fail closed rather than invent a parallel binding protocol. |
| Dispatch currently invokes allocation and the remote model-compatibility probe before it classifies initial versus redispatch mode. | `toolkit/scripts/dispatch-core.sh` | V1 must move only pure mode classification ahead of those steps, so `route_mode_unbound` has no remote-model side effect and an eligible route selects the tuple before it is probed. |
| `integrated_fix` has a singleton-plus-ordinal admission pair, and recovery currently adopts prepared records from ordinal advancement alone. | `toolkit/scripts/dispatch-core.sh`; `toolkit/scripts/lib/admission-recover.cjs` | Digest binding requires an explicit expected-digest adoption predicate and ordinal/singleton equality; a schema-only extension is insufficient. |
| The current automatic implementation path is Codex-only; external Opus/Fable seats are intentionally manual clean-context gates. | `toolkit/scripts/dispatch-core.sh`; `toolkit/README.md` Model Allocation section | Do not accidentally turn an external model name into a Codex argument. |
| Runtime, role, and transport are separate admitted axes, with runtime provenance in RUN/transport evidence. | `toolkit/STATUS.md` v0.20 | The next contract should extend this established provenance model rather than add a parallel routing authority. |
| Telemetry is append-only, distinguishes observed/estimated/unavailable usage, and suppresses mixed-model chains from single-model cohorts. | `toolkit/scripts/lib/telemetry.mjs`; `toolkit/scripts/__tests__/telemetry.smoke.sh` | It already supplies duration, retry, terminal, usage, and green-closure outcomes. A later additive routing-provenance copy is enough; no learning pipeline is justified. |

## Non-negotiable invariants

- Select the exact existing allocator tuple inside an already selected runtime;
  record pinned executable/configuration identity but do not resolve aliases or
  claim remote model availability.
- Route only if every hard requirement is satisfied.  Otherwise return typed
  refusal with the failed predicate; never downgrade, fall back, or launch a
  default implicitly.
- Separate **eligibility** (hard safety/compatibility) from **preference**
  (quality/cost/latency ranking).  Score cannot compensate for a missing hard
  capability.
- Preserve the current immutable admission ordering: full validation and
  selection precede markers, runner scripts, transport creation, and side
  effects.
- Keep routing cheaper than the work it classifies: an eligible canonical
  redispatch uses only bounded in-memory parsing of already-resolved inputs. Diff, LSP,
  consumer enumeration, and whole-repo analysis remain existing
  CONDUCTOR/verification responsibilities.
- Verification is not a model trait; completion still depends on canonical
  evidence at live HEAD.
- Unknown fields and stale static identity must deny rather than become
  invented values. Pricing and alias resolution are not v1 routing inputs.

## Options considered

### A. Extend the current score table

Add more scores and thresholds to `model-alloc.json`.

Pros: smallest migration.  Cons: mixes benchmark claims, live availability,
operator policy, and task facts; cannot express permission/sandbox or probe
freshness; makes a static source look authoritative at execution time.

### B. A provider-neutral dynamic selector

Ask a model to choose another model from natural-language task context.

Pros: flexible.  Cons: nondeterministic, hard to test or audit, vulnerable to
prompt drift, and likely to hide fallbacks.  Reject for dispatch admission.

### C. Typed capability policy with a deterministic selector (recommended)

Keep a host-pinned immutable policy snapshot; join it with a static runner
identity/configuration record
and an admission-derived task demand. Filter hard requirements, rank an
explicit candidate order, emit a decision receipt, then pass only the
runner-native tuple to the chosen adapter.

Pros: explicit, testable, compatible with existing fail-closed dispatch and
provenance.  Cons: adds schema and probe maintenance.  Mitigate with a small
v1 vocabulary and expiry-bound probes.

## Recommended v1 contract

### 1. Eligible v1 dispatch mode

V1 is limited to a policy-opted-in, allocator-owned **canonical redispatch**:
the existing Git-common-dir admission transaction supplies the
pre-consumption admission key and can atomically publish the route digest.
When policy is opted in for an initial write (Trivial, Standard, or Full
Cluster), dispatch returns the stdout-only `route_mode_unbound` refusal before
the selector, either allocator path, remote model-compatibility probe,
worktree marker, runner, transport, receipt, telemetry, or ordinal advance.
No-policy, a manually supplied `--model` or `--effort`, and dry-run paths
remain unchanged. Both current allocator sites are allocator-owned only when
neither manual tuple flag was supplied at argument parse time.
Initial-write routing is deferred until a generic host admission transaction is
separately designed and accepted.

### 2. `route_request` (derived from existing authority, schema-validated)

```json
{
  "schema_version": "1",
  "role": "implementation",
  "runtime": "codex",
  "write_mode": "workspace_write",
  "tier": "standard",
  "round_state_revision": 4,
  "pre_consumption_admission_key": "sha256:...",
  "model_alloc": {"model": "gpt-5.6-terra", "effort": "low"}
}
```

The request is an allowlist of facts already owned by admission, ROUND-STATE,
and `model-alloc.sh`. Consumed ordinal, attempt marker, and transport ID are
excluded to avoid a digest/binding cycle. `changed_lines`, `file_count`, and
`touch_set` belong only to the existing allocator-evidence producer and must
never be invented as zero. `risk`, free-form task
class, required-capability claims, verification class, and price/wall-time
budgets are deliberately excluded: they duplicate existing authority or force
new analysis/pricing probes into routing.

### 3. `runner_identity` (host static read; short-lived; non-project-owned)

```json
{
  "observed_at": "2026-07-25T10:00:00Z",
  "expires_at": "2026-07-25T10:30:00Z",
  "runner": "claude",
  "executable": "/absolute/pinned/claude",
  "version": "2.1.220",
  "permission_profile_digest": "sha256:..."
}
```

The route requires a fresh static identity record and a real executable pin.
The read is executable-version plus one already-resolved permission-file read:
no model prompt, network, or repository access. Its default TTL is 1800
seconds and ceiling 3600 seconds. It does not prove remote model availability
or resolve aliases; the existing launch-time compatibility preflight retains
that responsibility and its pre-marker failure behavior. Freshness timestamps
are not route-digest inputs: only runtime, pinned executable, version, and
permission-profile digest identify the offer in a recoverable binding.

### 4. `routing_policy` (project-owned)

```json
{
  "schema_version": "1",
  "rules": [{
    "when": {"runtime": "codex", "role": "implementation"},
    "candidates": {"from": "model_alloc"},
    "fallback": "deny"
  }]
}
```

In v1 `model_alloc` is the only candidate form. It preserves the existing
reviewer-capability predicate and cannot create a literal or cross-provider
alternative. There is no pricing lookup, score, LLM judgement, or ambient
“best model” default.

### 5. `route_decision` receipt (canonical evidence, immutable)

Bind the decision to the host-owned pre-consumption **ordinal** admission
record, then copy it into derivative RUN/transport provenance. Its digest uses
only time-independent offer identity (`runtime`, `executable`, `version`, and
`permission_profile_digest`), not offer timestamps. For an `integrated_fix`,
the singleton is a recovery companion, not another binding authority: its
digest must equal the ordinal's. `recover` and `recover-lock` receive the
newly computed expected digest only for the current admission key. A prior-key
singleton remains its existing sentinel; a current-key singleton without its
ordinal is `route_digest_unbound` and is never adopted. This preserves the
existing unadvanced-prepared reclaim: `recover` removes an interrupted
current-key singleton when its ordinal has not advanced, so retry remains
possible. `recover-lock` has no adoption path: it uses the dead lock owner's
recorded key and preserves stale-lock/unadvanced-prepared reclaim regardless of
an absent or mismatched digest.

```json
{
  "policy_digest": "sha256:...",
  "demand_digest": "sha256:...",
  "identity_digest": "sha256:...",
  "selected": {"runner": "codex", "model": "gpt-5.6-terra", "effort": "medium"},
  "selection_reason": ["rule:implementation-standard", "candidate:0"],
  "status": "admitted"
}
```

For denial, emit stdout-only typed result such as
`runner_offer_expired`, `candidate_ineligible`, `route_demand_unavailable`, or
`no_policy_candidate`. It publishes no receipt,
marker, admission record, or telemetry sample. The operator can correct input;
the runtime must not improvise.

## v1 implementation sequence

1. Classify mode before either allocator site and the remote compatibility
   probe. Restrict v1 to policy-opted-in allocator-owned canonical
   redispatches; policy-opted initial writes fail closed as `route_mode_unbound`;
   no-policy, a manually supplied `--model` or `--effort`, and dry-run paths
   bypass routing unchanged.
2. Add schemas/fixtures for request, static identity, policy, and admitted
   receipt. Make
   unknown values fail closed.
3. Add a side-effect-free cached static identity/configuration read; it does
   not invent an availability inventory or invoke a model/network/repository.
4. Implement selector dry-run first: JSON input, JSON decision/refusal, no
   marker and no launch.
5. Bind an admitted digest in the existing host-owned ordinal admission record
   over stable offer identity, not cache timestamps. Make `recover` and
   `recover` verify the expected digest for its invoking key and require a
   present ordinal plus `integrated_fix` ordinal/singleton equality before
   adoption. `recover-lock` performs no adoption and retains unadvanced-
   prepared reclaim regardless of digest. Defer any mode that cannot compose
   that transaction.
   Derivative receipts do not authorize recovery.
6. Keep existing manual external final-gate invocation until a separate
   clean-context runner contract is accepted; do not broaden auto-dispatch as
   part of the selector migration.

## Observational foundation before any v2 proposal

Use the existing opt-in local telemetry rather than a new learning service. The
data-foundation slice adds a `routing` object on an admitted telemetry sample;
it derives only `selection_basis`, a locally salted route pseudonym, policy
digest, runtime, and stable reason codes from a validated receipt plus binding. It
does not store prompt/source text, LSP output, model self-rating, or a pricing
lookup. Existing duration, retries, terminal, usage provenance, and canonical
green closure remain the outcomes.

Reports compare only homogeneous cohorts: selection basis, policy digest,
runtime, role, task class, tier, and model/effort. They descriptively report
complete-green rate, retries-to-green, wall time, and
observed/estimated/unavailable usage separately. Below explicit complete
independent-chain/completeness thresholds they say `insufficient evidence`.

This is observational, not a claim of causal or universal model superiority.
Reports cannot mutate policy and must not claim causal superiority or savings;
they disclose confounding. A later optional human `under|appropriate|over`
annotation keyed by the salted pseudonym may inform a reviewed, versioned policy
change; the selected model never labels its own outcome.

## Required smoke matrix

| Case | Expected result |
| --- | --- |
| Eligible exact tuple | deterministic decision and receipt with all three digests |
| No policy, manually supplied `--model` or `--effort`, or dry-run | routing bypass; current behavior byte-identical |
| Dirty/unpinned policy or malformed static identity | typed denial |
| Remote unavailability after selection | existing launch-time compatibility preflight denies before marker |
| Missing required sandbox/permission | typed denial even if capability score is highest |
| Policy-opted initial write (Trivial, Standard, or Full Cluster) | `route_mode_unbound` before selector, allocator change, or remote compatibility probe; no worktree marker becomes route authority |
| Current-key prepared normal or integrated binding missing/mismatched digest | recovery refuses adoption even after ordinal advance |
| Prior-key integrated singleton | neither adopted nor reclaimed; keeps its sentinel behavior |
| Current-key integrated singleton without ordinal | `route_digest_unbound`; never adopted even after ordinal advance |
| Interrupted current-key integrated singleton without ordinal advance | existing reclaim removes it; retry remains possible |
| Literal candidate | typed policy denial; v1 cannot bypass model-alloc reviewer gates |
| Requested fallback after primary refusal | denied unless a specific policy rule lists it |
| Adapter boundary | Codex/Claude/OpenCode each receives only its own native model syntax |
| Missing/different host binding | recovery rejects it; receipt cannot authorize it |
| Legacy v1 model allocation | existing known-family compatibility remains, unknown family fails closed |
| Telemetry | derives only validated, salted routing provenance; policy/config remains unchanged |

## Measurable rollout criteria

- 100% of policy-opted-in allocator-owned writes have a schema-valid decision
  or typed refusal; no-policy/manual/dry-run paths remain complete bypasses.
- 100% of admitted decisions include host-pinned policy, request, static
  identity, selected allocator tuple, and host admission binding.
- Any future policy comparison has a predeclared minimum sample and
  completeness threshold; its report distinguishes insufficient evidence from
  “no improvement.”
- Adoption must not weaken the existing no-side-effect-on-admission-failure,
  canonical REVIEW/VERIFY, or network/sandbox contracts.

## Confirmed boundary decisions

1. V1 does not resolve aliases or assert remote availability; its static cache
   is identity/configuration only (1800-second default, 3600-second ceiling).
2. V1 policy is a host-pinned immutable snapshot and can select only the exact
   current `model-alloc` tuple; mutable worktree policy and literal candidates
   are invalid.
3. V1 is canonical-redispatch-only. A policy-opted initial write refuses as
   `route_mode_unbound` before allocation or remote compatibility probing until
   a generic host admission transaction exists.
4. The host ordinal admission record is the sole binding authority. Route
   digest excludes ephemeral offer timestamps. `recover` checks the expected
   digest for its invoking key; a prior-key singleton remains a sentinel, while
   a current `integrated_fix` singleton must have an authoritative matching
   ordinal companion before adoption. `recover-lock` has no adoption path and
   retains existing reclaim. Non-adoption retains the existing
   unadvanced-prepared reclaim.
5. Refusal is stdout-only. Admitted telemetry uses only a salted pseudonym
   derived after binding/receipt validation.
6. Cross-provider routing, automatic external clean-context seats, availability
   probing, background learning, and telemetry-driven mutation remain out of
   scope.

## External reference points

- [Claude Code CLI reference](https://code.claude.com/docs/en/cli-reference)
  documents explicit `--model` selection; record the runtime-resolved value
  where available instead of treating an alias as immutable identity.
- [Anthropic model deprecations](https://platform.claude.com/docs/en/docs/about-claude/model-deprecations)
  is the operational reason to version and observe model identity rather than
  hard-code a provider alias as eternal.
- [OpenAI Codex configuration reference](https://developers.openai.com/codex/config-reference/)
  documents model, reasoning, and sandbox configuration as runner-specific
  controls, supporting the adapter boundary above.
- [OpenAI reasoning guide](https://developers.openai.com/api/docs/guides/reasoning/)
  describes effort as a bounded reasoning control; it should be recorded as
  part of the exact selected tuple, not inferred later from a role name.
