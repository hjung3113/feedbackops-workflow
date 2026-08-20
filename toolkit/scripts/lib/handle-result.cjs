"use strict";

// Shared live-launch result contract. A live adapter may have several
// identities for one session (workspace/surface, terminal, or pane/agent), so
// a single external_handle is optional and never substitutes for this tuple.
const DEFAULT_LIVE_LIFECYCLES = ["launched", "command_unconfirmed"];
const HANDLE_KEYS = ["lifecycle", "io", "agent"];

function normalizeHandles(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  if (Object.keys(value).some(key => !HANDLE_KEYS.includes(key))) return null;
  if (HANDLE_KEYS.some(key => typeof value[key] !== "string" || !value[key].trim())) return null;
  return {
    lifecycle: value.lifecycle,
    io: value.io,
    agent: value.agent,
  };
}

function normalizeLiveLaunchResult(value, acceptedLifecycles) {
  const lifecycles = Array.isArray(acceptedLifecycles) && acceptedLifecycles.length
    ? acceptedLifecycles : DEFAULT_LIVE_LIFECYCLES;
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  if (typeof value.lifecycle !== "string" || !lifecycles.includes(value.lifecycle)) return null;
  const handles = normalizeHandles(value.handles);
  if (!handles) return null;
  const result = { lifecycle: value.lifecycle, handles };
  if (value.external_handle !== undefined) {
    if (typeof value.external_handle !== "string" || !value.external_handle.trim()) return null;
    result.external_handle = value.external_handle;
  }
  return result;
}

if (require.main === module) {
  const [command, raw, acceptedRaw] = process.argv.slice(2);
  if (command !== "normalize" || raw === undefined) process.exit(2);
  try {
    const accepted = acceptedRaw ? JSON.parse(acceptedRaw) : undefined;
    const result = normalizeLiveLaunchResult(JSON.parse(raw), accepted);
    if (!result) process.exit(2);
    process.stdout.write(`${JSON.stringify(result)}\n`);
  } catch (_) { process.exit(2); }
}

module.exports = { DEFAULT_LIVE_LIFECYCLES, HANDLE_KEYS, normalizeHandles, normalizeLiveLaunchResult };
