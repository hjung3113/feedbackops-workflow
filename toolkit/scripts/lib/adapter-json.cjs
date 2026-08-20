#!/usr/bin/env node
"use strict";

// Shared emit side for adapter JSON payloads. The accepted capability
// field set is owned by capability-result.cjs (the validation side) and
// is imported here so the emitter and the acceptance gate cannot drift
// apart. CLI:
//   node adapter-json.cjs capabilities <adapter> <true|false> <reason_code> <version> <cap,cap,...>
//   node adapter-json.cjs lifecycle <lifecycle> <reason>
const { CAPABILITY_RESULT_FIELDS } = require("./capability-result.cjs");
const { normalizeLiveLaunchResult } = require("./handle-result.cjs");

function emitCapabilities(adapter, available, reasonCode, version, capabilities, ambiguousLifecycles) {
  const source = {
    adapter,
    available: available === "true",
    reason_code: reasonCode,
    version,
    capabilities,
    ambiguous_lifecycles: ambiguousLifecycles || []
  };
  const payload = {};
  for (const field of CAPABILITY_RESULT_FIELDS) payload[field] = source[field];
  return JSON.stringify(payload) + "\n";
}

function emitLifecycle(lifecycle, reason) {
  return JSON.stringify({ lifecycle, reason }) + "\n";
}

function emitSession(lifecycle, handles, externalHandle) {
  const value = { lifecycle, handles };
  if (externalHandle !== undefined && externalHandle !== "") value.external_handle = externalHandle;
  const normalized = normalizeLiveLaunchResult(value, ["launched", "command_unconfirmed"]);
  if (!normalized) throw new Error("invalid live session handles or lifecycle");
  return JSON.stringify(normalized) + "\n";
}

// A transport can report a healthy headless contract while its installed
// version lacks the interactive primitives. Keep the two claims structurally
// separate so callers cannot silently fall back from live to headless.
function emitAvailabilitySplit(adapter, headless, live) {
  if (!adapter || !headless || !live || typeof headless !== "object" || typeof live !== "object") {
    throw new Error("availability split requires headless and live objects");
  }
  return JSON.stringify({ adapter, headless, live }) + "\n";
}

if (require.main === module) {
  const [command, adapter, available, reasonCode, version, capabilitiesCsv, ambiguousLifecyclesCsv] = process.argv.slice(2);
  if (command === "capabilities" && adapter && (available === "true" || available === "false") && reasonCode && version !== undefined) {
    const capabilities = capabilitiesCsv ? capabilitiesCsv.split(",") : [];
    const ambiguousLifecycles = ambiguousLifecyclesCsv ? ambiguousLifecyclesCsv.split(",") : [];
    process.stdout.write(emitCapabilities(adapter, available, reasonCode, version, capabilities, ambiguousLifecycles));
  } else if (command === "lifecycle" && adapter && available) {
    const [lifecycle, reason] = [adapter, available];
    process.stdout.write(emitLifecycle(lifecycle, reason));
  } else if (command === "session" && adapter && available) {
    try {
      const handles = JSON.parse(available);
      process.stdout.write(emitSession(adapter, handles, reasonCode));
    } catch (_) { process.exit(2); }
  } else if (command === "availability" && adapter && available && reasonCode) {
    try {
      process.stdout.write(emitAvailabilitySplit(adapter, JSON.parse(available), JSON.parse(reasonCode)));
    } catch (_) { process.exit(2); }
  } else {
    process.exit(2);
  }
}

module.exports = { emitCapabilities, emitLifecycle, emitSession, emitAvailabilitySplit };
