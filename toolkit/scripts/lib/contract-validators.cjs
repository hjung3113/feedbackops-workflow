#!/usr/bin/env node
"use strict";
// Shared contract-validation predicates — the single import surface for
// checks that were previously copy-pasted across toolkit scripts.
// The model-family regex and effort enums are owned by runtime-registry.cjs;
// this module re-exports effortValid for a uniform import surface and must
// never redefine them.
const { effortValid } = require("./runtime-registry.cjs");

// Fail-closed HEAD/identity freshness predicate: a live HEAD (read via
// `git rev-parse HEAD` at the call site) matches a recorded head/content
// digest only when both sides are non-empty strings and exactly equal.
// Missing, empty, or non-string recorded values never match.
function headMatches(liveHead, recordedHead) {
  return typeof liveHead === "string" && typeof recordedHead === "string"
    && liveHead.length > 0 && recordedHead.length > 0
    && liveHead === recordedHead;
}

module.exports = { effortValid, headMatches };
