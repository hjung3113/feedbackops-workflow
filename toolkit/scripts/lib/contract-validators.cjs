#!/usr/bin/env node
"use strict";
// Shared contract-validation predicates — the single import surface for
// checks that were previously copy-pasted across toolkit scripts.
// The model-family regex and effort enums are owned by runtime-registry.cjs;
// this module re-exports effortValid for a uniform import surface and must
// never redefine them.
const fs = require("fs");
const path = require("path");
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

// Plain JSON.stringify equality: insertion-order sensitive, drops undefined.
// This is NOT lib/route.cjs's canonical() key-sorting serializer — that
// predicate feeds sha256 route_digest/policy_digest and stays separate.
function sameJson(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

// Schema bootstrap shared by the gate scripts: resolve
// <product-home>/schemas/<name> (module-relative ../.. — the Node-side
// equivalent of lib/product-home.sh's physical scripts-parent rule, so
// source and installed layouts resolve identically), read + parse it, and
// return it together with the subset validator. Throws on any failure;
// call sites treat a failed bootstrap as fail-closed.
function loadSchema(name) {
  const schemaPath = path.join(__dirname, "..", "..", "schemas", name);
  const schema = JSON.parse(fs.readFileSync(schemaPath, "utf8"));
  // Lazy require: json-schema-subset.cjs imports this module's sameJson.
  const { validate } = require("./json-schema-subset.cjs");
  return { schema, validate, schemaPath };
}

module.exports = { effortValid, headMatches, sameJson, loadSchema };
