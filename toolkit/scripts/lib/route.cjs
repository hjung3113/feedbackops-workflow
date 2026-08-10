"use strict";

// Pure deterministic v1 route selector. This module deliberately has no
// filesystem, subprocess, clock, telemetry, or network dependency.
const crypto = require("crypto");

const isObject = value => Boolean(value) && typeof value === "object" && !Array.isArray(value);
const hasOnly = (value, keys) => isObject(value) && Object.keys(value).every(key => keys.includes(key));
const sha256 = value => crypto.createHash("sha256").update(value).digest("hex");
const canonical = value => {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (isObject(value)) return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonical(value[key])}`).join(",")}}`;
  return JSON.stringify(value);
};
const isSha = value => typeof value === "string" && /^[a-f0-9]{64}$/.test(value);
const isRfc3339 = value => typeof value === "string" && !Number.isNaN(Date.parse(value));
const refusal = (code, reasons) => ({ status: "refused", code, reasons });

function validDemand(value) {
  const required = ["runtime", "role", "write_mode", "tier", "issue", "worktree_path", "head_sha", "base_sha", "round_state_revision", "admission_key"];
  const allowed = required.concat(["contract", "live_probes"]);
  if (!hasOnly(value, allowed) || required.some(key => !Object.prototype.hasOwnProperty.call(value, key))) return false;
  if (typeof value.runtime !== "string" || typeof value.role !== "string" || value.write_mode !== "canonical_redispatch"
      || typeof value.tier !== "string" || !Number.isInteger(value.issue) || value.issue < 1
      || typeof value.worktree_path !== "string" || !value.worktree_path.startsWith("/")
      || !/^[a-f0-9]{40}$/.test(value.head_sha) || !/^[a-f0-9]{40}$/.test(value.base_sha)
      || !Number.isInteger(value.round_state_revision) || value.round_state_revision < 1
      || !/^issue-[1-9][0-9]*-dispatch-[1-9][0-9]*$/.test(value.admission_key)) return false;
  if (Object.prototype.hasOwnProperty.call(value, "contract") && !isObject(value.contract)) return false;
  return !Object.prototype.hasOwnProperty.call(value, "live_probes") || Array.isArray(value.live_probes);
}

function validOffer(value) {
  const required = ["runtime", "executable", "version", "observed_at", "expires_at", "permission_profile_digest"];
  if (!hasOnly(value, required) || required.some(key => !Object.prototype.hasOwnProperty.call(value, key))) return false;
  return typeof value.runtime === "string" && typeof value.executable === "string" && value.executable.startsWith("/")
    && typeof value.version === "string" && value.version.length > 0 && isRfc3339(value.observed_at)
    && isRfc3339(value.expires_at) && isSha(value.permission_profile_digest);
}

function validPolicy(value) {
  if (!hasOnly(value, ["version", "rules"]) || value.version !== 1 || !Array.isArray(value.rules)
      || value.rules.length < 1 || value.rules.length > 64) return false;
  const seen = new Set();
  return value.rules.every(rule => {
    if (!hasOnly(rule, ["when", "candidates", "fallback"]) || rule.fallback !== "deny"
        || !hasOnly(rule.when, ["runtime", "role"]) || typeof rule.when.runtime !== "string"
        || typeof rule.when.role !== "string" || !hasOnly(rule.candidates, ["from"])
        || rule.candidates.from !== "model_alloc") return false;
    const signature = canonical(rule.when);
    if (seen.has(signature)) return false;
    seen.add(signature);
    return true;
  });
}

function validModelAlloc(value) {
  return hasOnly(value, ["model", "effort"]) && typeof value.model === "string" && value.model.length > 0
    && /^(none|low|medium|high|xhigh|max)$/.test(value.effort);
}

function decide({ demand, offer, policy, modelAlloc, now, policyDigest }) {
  if (!validDemand(demand)) return refusal("route_demand_invalid", ["demand_not_canonical"]);
  if (!validPolicy(policy)) return refusal("route_policy_invalid", ["policy_not_bounded_v1"]);
  if (!validOffer(offer) || offer.runtime !== demand.runtime) return refusal("runner_offer_invalid", ["static_offer_invalid"]);
  if (!isRfc3339(now)) return refusal("route_demand_invalid", ["now_invalid"]);
  if (Date.parse(offer.expires_at) <= Date.parse(now)) return refusal("runner_offer_expired", ["static_offer_expired"]);
  if (!validModelAlloc(modelAlloc)) return refusal("route_demand_invalid", ["model_alloc_tuple_invalid"]);
  const rule = policy.rules.find(candidate => candidate.when.runtime === demand.runtime && candidate.when.role === demand.role);
  if (!rule) return refusal("no_route_candidate", ["no_matching_policy_rule"]);
  const selected = { model: modelAlloc.model, effort: modelAlloc.effort };
  const stableOffer = {
    runtime: offer.runtime,
    executable: offer.executable,
    version: offer.version,
    permission_profile_digest: offer.permission_profile_digest
  };
  if (policyDigest !== undefined && !isSha(policyDigest)) return refusal("route_policy_invalid", ["policy_digest_invalid"]);
  const resolvedPolicyDigest = policyDigest || sha256(canonical(policy));
  const routeDigest = sha256(canonical({ demand, stable_offer_identity: stableOffer, policy_digest: resolvedPolicyDigest, selected }));
  return {
    status: "admitted",
    selected,
    route_digest: routeDigest,
    policy_digest: resolvedPolicyDigest,
    reasons: ["model_alloc", "ordered_policy"]
  };
}

module.exports = { canonical, decide, validPolicy };
