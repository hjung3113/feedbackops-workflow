#!/usr/bin/env node
"use strict";
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { execFileSync, spawnSync } = require("child_process");
const { headMatches } = require("./contract-validators.cjs");

function parse(argv) {
  const out = { source: [] };
  for (let i = 0; i < argv.length; i += 2) {
    const key = argv[i];
    if (!key || !key.startsWith("--") || i + 1 >= argv.length) failEarly("invalid_arguments", "malformed arguments");
    if (key === "--source") out.source.push(argv[i + 1]); else out[key.slice(2)] = argv[i + 1];
  }
  return out;
}
function failEarly(code, message) {
  process.stdout.write(JSON.stringify({ status: "error", errors: [{ code }], error: message }) + "\n");
  process.exit(2);
}
function sha(file) { return crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex"); }
function git(cwd, args, options = {}) { return execFileSync("git", ["-C", cwd, ...args], { encoding: "utf8", ...options }).trim(); }
function clean(cwd) {
  return git(cwd, ["status", "--porcelain"]).split(/\r?\n/).filter(Boolean)
    .filter(line => !/^\?\? \.review\//.test(line)).length === 0;
}
function covered(scopes, changed) { return scopes.some(scope => changed === scope || changed.startsWith(scope + "/")); }

const args = parse(process.argv.slice(2));
for (const key of ["plan", "target", "candidate-worktree", "output", "schema", "validator", "planner"]) {
  if (!args[key]) failEarly("invalid_arguments", `missing --${key}`);
}
const planner = spawnSync(process.execPath, [args.planner, "decide", "--plan", args.plan, "--target", args.target], { encoding: "utf8" });
if (planner.status !== 0) { process.stdout.write(planner.stdout || planner.stderr); process.exit(planner.status || 2); }
let plan, schema, validate;
try {
  plan = JSON.parse(fs.readFileSync(args.plan, "utf8"));
  schema = JSON.parse(fs.readFileSync(args.schema, "utf8"));
  ({ validate } = require(args.validator));
} catch (error) { failEarly("invalid_input", error.message); }
let candidate;
try { candidate = fs.realpathSync(args["candidate-worktree"]); }
catch (error) { failEarly("uncheckable_candidate", error.message); }
const steps = [];
const sourceMap = new Map();
for (const spec of args.source) {
  const equals = spec.indexOf("="); const at = spec.lastIndexOf("@");
  if (equals < 1 || at <= equals + 1 || at === spec.length - 1) failEarly("invalid_source_binding", spec);
  const id = spec.slice(0, equals), worktree = spec.slice(equals + 1, at), head = spec.slice(at + 1);
  if (sourceMap.has(id) || !/^[0-9a-f]{40}$/.test(head)) failEarly("invalid_source_binding", spec);
  sourceMap.set(id, { worktree, head });
}
const byId = new Map(plan.seats.map(seat => [seat.id, seat]));
let result = {
  schema_version: "1", artifact_type: "integration_result", producer_role: "CONDUCTOR",
  issue: plan.issue, round: plan.round, manifest_revision: plan.manifest_revision,
  plan_revision: plan.plan_revision, plan_sha256: sha(args.plan), base_head: plan.base_head,
  status: "blocked", steps, candidate_head: plan.base_head, candidate_clean: false,
  created_at: new Date().toISOString()
};
function publish(code, exitCode = 1) {
  result.status = "blocked"; result.failure_code = code;
  try { result.candidate_head = git(candidate, ["rev-parse", "HEAD"]); result.candidate_clean = clean(candidate); } catch (_) {}
  const errors = validate(schema, result);
  if (errors.length) failEarly("invalid_integration_result", errors.join("; "));
  fs.mkdirSync(path.dirname(args.output), { recursive: true });
  const temp = `${args.output}.tmp-${process.pid}`;
  fs.writeFileSync(temp, JSON.stringify(result, null, 2) + "\n"); fs.renameSync(temp, args.output);
  process.stdout.write(JSON.stringify({ status: "blocked", failure_code: code, artifact: args.output }) + "\n");
  process.exit(exitCode);
}
if (!clean(candidate)) publish("dirty_candidate");
let candidateHead;
try { candidateHead = git(candidate, ["rev-parse", "HEAD"]); }
catch (error) { publish("uncheckable_candidate", 2); }
if (!headMatches(candidateHead, plan.base_head)) publish("candidate_base_mismatch");

// Validate the complete source set before mutating the candidate.
const prepared = [];
for (const seatId of plan.integration_order) {
  const binding = sourceMap.get(seatId), seat = byId.get(seatId);
  if (!binding) publish("missing_source_binding", 2);
  let source;
  try { source = fs.realpathSync(binding.worktree); } catch (_) { publish("missing_source_worktree", 2); }
  let live, paths;
  try {
    live = git(source, ["rev-parse", "HEAD"]);
    if (!headMatches(live, binding.head)) publish("stale_source_head");
    if (!clean(source)) publish("dirty_source");
  } catch (_) { publish("uncheckable_source"); }
  const merge = spawnSync("git", ["-C", source, "merge-base", plan.base_head, binding.head], { encoding: "utf8" });
  if (merge.status !== 0 || merge.stdout.trim() !== plan.base_head) publish("source_not_rebased");
  try { paths = git(source, ["diff", "--name-only", plan.base_head, binding.head]).split(/\r?\n/).filter(Boolean).sort(); }
  catch (_) { publish("uncheckable_source"); }
  if (paths.some(p => !covered(seat.write_set.paths, p))) publish("unexpected_changed_path");
  prepared.push({ seatId, seat, source, head: binding.head, paths });
}
if (sourceMap.size !== plan.seats.length) publish("unexpected_source_binding", 2);

for (const source of prepared) {
  const patchFile = path.join(candidate, ".review", `.candidate-integrate-${process.pid}-${source.seatId}.patch`);
  fs.mkdirSync(path.dirname(patchFile), { recursive: true });
  const diff = spawnSync("git", ["-C", source.source, "diff", "--binary", plan.base_head, source.head], { encoding: null });
  if (diff.status !== 0) publish("source_diff_failed");
  fs.writeFileSync(patchFile, diff.stdout);
  const apply = spawnSync("git", ["-C", candidate, "apply", "--index", patchFile], { encoding: "utf8" });
  fs.unlinkSync(patchFile);
  if (apply.status !== 0) {
    steps.push({ seat_id: source.seatId, source_head: source.head, changed_paths: source.paths, status: "blocked", failure_code: "integration_conflict" });
    publish("integration_conflict");
  }
  const commit = spawnSync("git", ["-C", candidate, "-c", "user.name=Agent Workflow", "-c", "user.email=workflow@example.invalid", "commit", "-m", `integrate(workflow): seat ${source.seatId}`], { encoding: "utf8" });
  if (commit.status !== 0) {
    steps.push({ seat_id: source.seatId, source_head: source.head, changed_paths: source.paths, status: "blocked", failure_code: "integration_commit_failed" });
    publish("integration_commit_failed");
  }
  const resulting = git(candidate, ["rev-parse", "HEAD"]);
  steps.push({ seat_id: source.seatId, source_head: source.head, changed_paths: source.paths, status: "integrated", resulting_head: resulting });
}
result.status = "pass";
delete result.failure_code;
result.candidate_head = git(candidate, ["rev-parse", "HEAD"]);
result.candidate_clean = clean(candidate);
if (!result.candidate_clean) publish("dirty_candidate_after_integration");
const errors = validate(schema, result);
if (errors.length) failEarly("invalid_integration_result", errors.join("; "));
fs.mkdirSync(path.dirname(args.output), { recursive: true });
const temp = `${args.output}.tmp-${process.pid}`;
fs.writeFileSync(temp, JSON.stringify(result, null, 2) + "\n"); fs.renameSync(temp, args.output);
process.stdout.write(JSON.stringify({ status: "pass", candidate_head: result.candidate_head, artifact: args.output }) + "\n");
