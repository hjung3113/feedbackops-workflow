#!/usr/bin/env node
"use strict";

// Shared emit side for adapter JSON payloads. The accepted capability
// field set is owned by capability-result.cjs (the validation side) and
// is imported here so the emitter and the acceptance gate cannot drift
// apart. CLI:
//   node adapter-json.cjs capabilities <adapter> <true|false> <reason_code> <version> <cap,cap,...>
//   node adapter-json.cjs lifecycle <lifecycle> <reason>
const { CAPABILITY_RESULT_FIELDS } = require("./capability-result.cjs");

function emitCapabilities(adapter, available, reasonCode, version, capabilities) {
  const source = {
    adapter,
    available: available === "true",
    reason_code: reasonCode,
    version,
    capabilities
  };
  const payload = {};
  for (const field of CAPABILITY_RESULT_FIELDS) payload[field] = source[field];
  return JSON.stringify(payload) + "\n";
}

function emitLifecycle(lifecycle, reason) {
  return JSON.stringify({ lifecycle, reason }) + "\n";
}

if (require.main === module) {
  const [command, adapter, available, reasonCode, version, capabilitiesCsv] = process.argv.slice(2);
  if (command === "capabilities" && adapter && (available === "true" || available === "false") && reasonCode && version !== undefined) {
    const capabilities = capabilitiesCsv ? capabilitiesCsv.split(",") : [];
    process.stdout.write(emitCapabilities(adapter, available, reasonCode, version, capabilities));
  } else if (command === "lifecycle" && adapter && available) {
    const [lifecycle, reason] = [adapter, available];
    process.stdout.write(emitLifecycle(lifecycle, reason));
  } else {
    process.exit(2);
  }
}

module.exports = { emitCapabilities, emitLifecycle };
