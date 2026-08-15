#!/usr/bin/env node
"use strict";

// Shared semver authority for transport adapters, ported from herdr's
// prerelease-aware parse_version. Extraction (`parse`) accepts a version
// embedded in free command output; `exact` requires the whole input to be
// one version (Orca's runtime appVersion contract). Both floor variants
// reject a version below the floor and an exactly-floor prerelease.
// CLI: node semver.cjs <parse|parse-floor|exact|exact-floor> <raw> [floor]
//   Prints the normalized version on success; exits 2 on any rejection.
const SEMVER_SOURCE = "(\\d+\\.\\d+\\.\\d+(?:-[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?(?:\\+[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?)";

function fromMatch(normalized) {
  return {
    normalized,
    main: normalized.split(/[+-]/, 1)[0].split(".").map(Number),
    prerelease: normalized.indexOf("-") >= 0 ? normalized.split("-")[1].split("+")[0] : ""
  };
}

function parseSemver(raw) {
  const match = new RegExp(`(?:^|\\s)v?${SEMVER_SOURCE}(?=$|\\s)`).exec(typeof raw === "string" ? raw : "");
  return match ? fromMatch(match[1]) : null;
}

function parseExactSemver(raw) {
  const value = typeof raw === "string" ? raw : "";
  if (!value || value !== value.trim()) return null;
  const match = new RegExp(`^v?${SEMVER_SOURCE}$`).exec(value);
  return match ? fromMatch(match[1]) : null;
}

function parseFloor(floor) {
  const parts = String(floor || "").split(".").map(Number);
  if (parts.length !== 3 || parts.some(part => !Number.isInteger(part) || part < 0)) return null;
  return parts;
}

function meetsFloor(parsed, floor) {
  for (let i = 0; i < 3; i++) {
    if (parsed.main[i] > floor[i]) return true;
    if (parsed.main[i] < floor[i]) return false;
    if (i === 2 && parsed.prerelease) return false;
  }
  return true;
}

if (require.main === module) {
  const [mode, raw, floorArg] = process.argv.slice(2);
  let parsed = null;
  if (mode === "parse" || mode === "parse-floor") parsed = parseSemver(raw);
  else if (mode === "exact" || mode === "exact-floor") parsed = parseExactSemver(raw);
  if (!parsed) process.exit(2);
  if (mode === "parse-floor" || mode === "exact-floor") {
    const floor = parseFloor(floorArg);
    if (!floor || !meetsFloor(parsed, floor)) process.exit(2);
  }
  process.stdout.write(parsed.normalized);
}

module.exports = { parseSemver, parseExactSemver, parseFloor, meetsFloor };
