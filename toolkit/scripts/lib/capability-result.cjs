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
const [mode, raw, expected] = process.argv.slice(2);

try {
  const value = JSON.parse(raw);
  if (value.adapter !== expected || typeof value.available !== "boolean"
      || typeof value.version !== "string" || !Array.isArray(value.capabilities)
      || value.capabilities.some(entry => typeof entry !== "string")) process.exit(2);
  if (value.available) {
    if (!value.version.trim()) process.exit(2);
    if (!value.capabilities.length) process.exit(2);
    const seen = new Set();
    for (const entry of value.capabilities) {
      if (!entry.trim() || seen.has(entry)) process.exit(2);
      seen.add(entry);
    }
    if (mode === "dispatch") {
      process.stdout.write(value.version + "\t" + JSON.stringify(value.capabilities));
    }
  } else if (mode === "dispatch") {
    process.exit(2);
  }
} catch (error) { process.exit(2); }
