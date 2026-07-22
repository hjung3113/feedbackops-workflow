#!/usr/bin/env node
// Prove that a dispatch contract names real base-tree scope.  Completion
// checks changed paths afterwards; this preflight catches a typo before a
// write admission is consumed.  New paths are intentionally not inferred
// from globs: they require exact new_file_allowlist entries.
const fs = require("fs");
const { execFileSync } = require("child_process");

const [stateFile, worktree] = process.argv.slice(2);
function fail(code) { process.stderr.write(`touch-allowlist-preflight: ${code}\n`); process.exit(2); }
function safePath(value, allowGlob) {
  return typeof value === "string" && value.length > 0 && !value.startsWith("/")
    && value.indexOf("\\") === -1 && value.split("/").every(part => part && part !== "." && part !== "..")
    && (allowGlob || !/[?*\[]/.test(value));
}
function globMatches(pattern, value) {
  let regex = "^";
  for (let i = 0; i < pattern.length; i += 1) {
    const ch = pattern[i];
    if (ch === "*") {
      if (pattern[i + 1] === "*") { i += 1; if (pattern[i + 1] === "/") { i += 1; regex += "(?:.*/)?"; } else regex += ".*"; }
      else regex += "[^/]*";
    } else if (ch === "?") regex += "[^/]";
    else regex += ch.replace(/[|\\{}()[\]^$+?.]/g, "\\$&");
  }
  try { return new RegExp(regex + "$").test(value); } catch (_) { return false; }
}
let state;
try { state = JSON.parse(fs.readFileSync(stateFile, "utf8")); } catch (_) { fail("invalid_round_state"); }
const contract = state && state.contract;
if (!contract || !Array.isArray(contract.touch_allowlist) || !Array.isArray(contract.new_file_allowlist || [])) fail("invalid_touch_allowlist");
if (!contract.touch_allowlist.every(value => safePath(value, true)) || !(contract.new_file_allowlist || []).every(value => safePath(value, false))) fail("invalid_touch_allowlist");
let basePaths;
try {
  basePaths = execFileSync("git", ["-C", worktree, "ls-tree", "-r", "--name-only", state.base_sha], { encoding: "utf8" })
    .split("\n").filter(Boolean);
} catch (_) { fail("unreadable_base_tree"); }
for (const pattern of contract.touch_allowlist) {
  if (!basePaths.some(value => globMatches(pattern, value))) fail(`touch_allowlist_no_base_match:${pattern}`);
}
for (const value of contract.new_file_allowlist || []) {
  if (basePaths.indexOf(value) !== -1) fail(`new_file_allowlist_not_new:${value}`);
  // A new-file exception narrows creation authority; it must not expand the
  // declared modification scope. Completion-check enforces the same rule
  // against the eventual diff; this catches a contradictory contract before
  // dispatch can consume an admission.
  if (!contract.touch_allowlist.some(pattern => globMatches(pattern, value))) {
    fail(`new_file_allowlist_not_in_touch_allowlist:${value}`);
  }
}
process.exit(0);
