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

// Environment scrub whitelists. verify.sh and target-verify.mjs keep
// intentionally DIFFERENT base lists (the target verifier scopes extra
// allows per profile); they are co-located for deduplication, never unioned.
const VERIFY_ENV_BASE = [
  "PATH", "HOME", "SHELL", "TERM", "LANG", "LC_ALL", "TMPDIR", "TMP",
  "USER", "LOGNAME", "PWD", "NODE_OPTIONS", "NODE_ENV", "DATABASE_URL",
  "DATABASE_URL_MIGRATE", "WORKSPACE_ID", "CI",
];
const TARGET_VERIFY_ENV_BASE = ["PATH", "HOME", "TMPDIR", "LANG"];

// Shape rule faithful to verify.sh's historical `[A-Za-z_][A-Za-z0-9_]*`
// shell case pattern: first char letter/underscore, second char
// letter/digit/underscore, remainder unconstrained.
function verifyEnvNameShapeValid(name) {
  return /^[A-Za-z_][A-Za-z0-9_]/.test(name);
}

function pnpmEnvPassThrough(name) {
  return /^PNPM_[A-Za-z0-9_]*$/.test(name) || /^npm_config_[A-Za-z0-9_]*$/.test(name);
}

// Ordered NAME=VALUE assignments for verify.sh's `env -i` child, matching
// the historical shell staging exactly: base whitelist in order, then
// sorted PNPM_*/npm_config_* pass-throughs, then whitespace-split
// VERIFY_ENV_ALLOW extras that pass the shape rule. Set-but-empty values
// are emitted ("NAME="); unset names are dropped.
function verifyEnvAssignments(env, extraAllow) {
  const assignments = [];
  const emit = (name) => { if (name in env) assignments.push(`${name}=${env[name]}`); };
  for (const name of VERIFY_ENV_BASE) emit(name);
  for (const name of Object.keys(env).filter(pnpmEnvPassThrough).sort()) emit(name);
  for (const name of String(extraAllow || "").split(/[ \t\n]+/)) if (verifyEnvNameShapeValid(name)) emit(name);
  return assignments;
}

module.exports = { effortValid, headMatches, sameJson, loadSchema, VERIFY_ENV_BASE, TARGET_VERIFY_ENV_BASE, verifyEnvAssignments };
