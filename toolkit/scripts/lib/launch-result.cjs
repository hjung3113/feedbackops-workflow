"use strict";

// Shared launch-result contract. Adapters emit {external_handle, lifecycle};
// dispatch-core.sh consumes it via this validator instead of an inline copy.
// normalizeLaunchResult(value) returns {external_handle, lifecycle} when the
// value is acceptable, otherwise null. acceptedLifecycles is parameterizable
// (adapter-declared); the default matches today's two legitimate lifecycles.
const DEFAULT_LIFECYCLES = ["launched", "command_unconfirmed"];

function normalizeLaunchResult(value, acceptedLifecycles) {
  const lifecycles = Array.isArray(acceptedLifecycles) && acceptedLifecycles.length
    ? acceptedLifecycles
    : DEFAULT_LIFECYCLES;
  if (!value || typeof value !== "object") return null;
  if (typeof value.external_handle !== "string" || !value.external_handle.trim()) return null;
  if (typeof value.lifecycle !== "string" || lifecycles.indexOf(value.lifecycle) === -1) return null;
  return { external_handle: value.external_handle, lifecycle: value.lifecycle };
}

module.exports = { normalizeLaunchResult, DEFAULT_LIFECYCLES };
