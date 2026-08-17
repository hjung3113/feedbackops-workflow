#!/usr/bin/env node
"use strict";

// Single acceptance authority for adapter capability-result payloads.
// `dispatch` mode is the dispatch admission gate: the payload must claim
// available with a provable non-blank version and a non-empty,
// duplicate-free list of non-blank capability strings, and the accepted
// fields are printed as `version<TAB>capabilities-json`. `aggregate`
// mode is the capabilities survey: it applies the same strictness to
// every available claim but still accepts a well-shaped unavailable
// entry so the survey can report it as-is. Any other shape exits
// non-zero in both modes.
const CAPABILITY_RESULT_FIELDS = ["adapter", "available", "reason_code", "version", "capabilities", "ambiguous_lifecycles"];

function validateCapabilityResult(value, expectedAdapter) {
  if (value.adapter !== expectedAdapter || typeof value.available !== "boolean"
      || typeof value.version !== "string" || !Array.isArray(value.capabilities)
      || value.capabilities.some(entry => typeof entry !== "string")) return false;
  // ambiguous_lifecycles is optional (older adapters/fixtures may omit it);
  // when present it must be an array of non-blank strings.
  if (value.ambiguous_lifecycles !== undefined) {
    if (!Array.isArray(value.ambiguous_lifecycles)
        || value.ambiguous_lifecycles.some(entry => typeof entry !== "string" || !entry.trim())) return false;
  }
  if (value.available) {
    if (!value.version.trim()) return false;
    if (!value.capabilities.length) return false;
    const seen = new Set();
    for (const entry of value.capabilities) {
      if (!entry.trim() || seen.has(entry)) return false;
      seen.add(entry);
    }
  }
  return true;
}

if (require.main === module) {
  const [mode, raw, expected] = process.argv.slice(2);

  try {
    const value = JSON.parse(raw);
    if (!validateCapabilityResult(value, expected)) process.exit(2);
    if (value.available) {
      if (mode === "dispatch") {
        process.stdout.write(value.version + "\t" + JSON.stringify(value.capabilities)
          + "\t" + JSON.stringify(value.ambiguous_lifecycles || []));
      }
    } else if (mode === "dispatch") {
      process.exit(2);
    }
  } catch (error) { process.exit(2); }
}

module.exports = { CAPABILITY_RESULT_FIELDS, validateCapabilityResult };
