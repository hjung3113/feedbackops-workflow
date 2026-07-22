#!/usr/bin/env node
// Deep output-contract module: schema-derived prompt material and validation.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const [command, role, promptFile, schemaDirArg] = process.argv.slice(2);
const schemaDir = schemaDirArg || path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../schemas");
const markerStart = "<!-- agent-workflow:output-contract:start -->";
const markerEnd = "<!-- agent-workflow:output-contract:end -->";
function fail(message) { console.error(`OUTPUT_CONTRACT_${message}`); process.exit(1); }
function schema(name) { try { return JSON.parse(fs.readFileSync(path.join(schemaDir, name), "utf8")); } catch (_) { fail(`SCHEMA_UNREADABLE:${name}`); } }
function resolve(root, value) {
  if (!value || typeof value !== "object" || !value.$ref) return value;
  if (!value.$ref.startsWith("#/")) return value;
  return value.$ref.slice(2).split("/").reduce((node, key) => node && node[key], root) || value;
}
function artifactsFor(selectedRole) {
  // A projection silently loses constraints (patterns, bounds, conditional
  // branches). The prompt therefore carries the canonical schema verbatim;
  // `check` below compares the complete deterministic contract byte-for-byte.
  if (selectedRole === "reviewer") { const value = schema("review.schema.json"); return [{ name: "review", path: "schemas/review.schema.json", schema: value }]; }
  if (["implementation", "architect", "conductor", "release"].includes(selectedRole)) { const value = schema("blocker.schema.json"); return [{ name: "blocker", path: "schemas/blocker.schema.json", schema: value }]; }
  return [];
}
function contract(selectedRole) {
  const artifacts = artifactsFor(selectedRole);
  return { schema_version: "1", role: selectedRole, artifact_paths_are_canonical: true,
    instructions: selectedRole === "reviewer"
      ? ["Read-only reviewer: do not write the artifact; return exactly one JSON object in the final message.", "The host publishes the canonical REVIEW only after validating this schema and the live HEAD.", "Populate every required field listed by the current review schema."]
      : ["If you must stop before implementation, write exactly one schema-valid BLOCKER at .review/ISSUE-<N>-BLOCKER.json.", "Do not invent fields or reason codes; preserve the original evidence and return non-zero when the contract cannot be met.", "Populate every required field listed by the current blocker schema."], artifacts };
}
// The contract travels inside bounded reviewer prompts and re-review capsules.
// Keep its byte representation compact, while retaining the complete nested
// schema projection (the checker compares this exact deterministic form).
function canonicalJson(value) { return JSON.stringify(value); }
if (command === "render") {
  if (!role) fail("ROLE_REQUIRED");
  process.stdout.write(markerStart + "\n```json\n" + canonicalJson(contract(role)) + "\n```\n" + markerEnd + "\n");
  process.exit(0);
}
if (command === "check") {
  if (!role || !promptFile) fail("INPUT_REQUIRED");
  let prompt; try { prompt = fs.readFileSync(promptFile, "utf8"); } catch (_) { fail("PROMPT_UNREADABLE"); }
  if (prompt.split(markerStart).length - 1 !== 1 || prompt.split(markerEnd).length - 1 !== 1) fail("MISSING_OR_DUPLICATE_BLOCK");
  const body = prompt.slice(prompt.indexOf(markerStart) + markerStart.length, prompt.indexOf(markerEnd)).trim();
  const match = body.match(/^```json\s*\n([\s\S]*?)\n```$/); if (!match) fail("MALFORMED_BLOCK");
  let supplied; try { supplied = JSON.parse(match[1]); } catch (_) { fail("INVALID_JSON"); }
  if (JSON.stringify(supplied) !== JSON.stringify(contract(role))) fail("SCHEMA_OR_INSTRUCTION_DRIFT");
  process.stdout.write(`OK output contract is schema-derived for ${role}\n`); process.exit(0);
}
fail("UNKNOWN_COMMAND");
