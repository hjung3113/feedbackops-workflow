#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { execFileSync } = require("child_process");

function die(code, message, exitCode = 2) {
  process.stdout.write(JSON.stringify({ status: "error", errors: [{ code }], error: message }) + "\n");
  process.exit(exitCode);
}
function readJson(file, code) {
  try { return JSON.parse(fs.readFileSync(file, "utf8")); }
  catch (error) { die(code, error.message); }
}
function digest(file) {
  return crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
}
function inside(root, candidate) {
  const relative = path.relative(root, candidate);
  return relative === "" || (!relative.startsWith(".." + path.sep) && relative !== ".." && !path.isAbsolute(relative));
}
function validatePath(root, value) {
  if (typeof value !== "string" || !value || value.includes("\\") || value.startsWith("/")
      || value.endsWith("/") || path.posix.normalize(value) !== value
      || value.split("/").some(part => part === "" || part === "." || part === "..")) {
    die("invalid_write_path", `write path is not normalized target-relative: ${value}`);
  }
  let probe = root;
  for (const component of value.split("/")) {
    probe = path.join(probe, component);
    if (!fs.existsSync(probe)) break;
    let real;
    try { real = fs.realpathSync(probe); }
    catch (error) { die("uncheckable_write_path", value); }
    if (!inside(root, real)) die("symlink_escape", value);
  }
}
function overlaps(left, right) {
  return left === right || left.startsWith(right + "/") || right.startsWith(left + "/");
}
function semantic(plan, targetRoot) {
  const root = fs.realpathSync(targetRoot);
  if (plan.lifecycle !== "active") die("inactive_execution_plan", "execution plan must be active");
  const ids = new Set();
  const seats = new Map();
  const ownership = new Map();
  for (const seat of plan.seats) {
    if (ids.has(seat.id)) die("duplicate_seat", seat.id);
    ids.add(seat.id); seats.set(seat.id, seat);
    if (seat.write_set.mode === "exact" && seat.write_set.paths.length === 0) die("empty_exact_write_set", seat.id);
    if (seat.write_set.mode !== "exact" && seat.write_set.paths.length !== 0) die("unproven_write_set_has_paths", seat.id);
    const sorted = seat.write_set.paths.slice().sort();
    if (JSON.stringify(sorted) !== JSON.stringify(seat.write_set.paths)) die("unsorted_write_set", seat.id);
    for (const p of seat.write_set.paths) {
      validatePath(root, p);
      if (ownership.has(p)) die("duplicate_ownership", `${p}: ${ownership.get(p)},${seat.id}`);
      ownership.set(p, seat.id);
    }
  }
  for (const seat of plan.seats) {
    for (const dep of seat.depends_on) {
      if (!ids.has(dep)) die("unknown_dependency", `${seat.id}->${dep}`);
      if (dep === seat.id) die("dependency_cycle", seat.id);
    }
    const sortedDeps = seat.depends_on.slice().sort();
    if (JSON.stringify(sortedDeps) !== JSON.stringify(seat.depends_on)) die("unsorted_dependencies", seat.id);
  }
  if (plan.integration_order.length !== ids.size || !plan.integration_order.every(id => ids.has(id))) {
    die("invalid_integration_order", "integration_order must contain every seat exactly once");
  }
  const position = new Map(plan.integration_order.map((id, index) => [id, index]));
  for (const seat of plan.seats) {
    for (const dep of seat.depends_on) {
      if (position.get(dep) >= position.get(seat.id)) die("dependency_cycle_or_order", `${dep} must precede ${seat.id}`);
    }
  }
  const visiting = new Set(), visited = new Set();
  function visit(id) {
    if (visiting.has(id)) die("dependency_cycle", id);
    if (visited.has(id)) return;
    visiting.add(id);
    for (const dep of seats.get(id).depends_on) visit(dep);
    visiting.delete(id); visited.add(id);
  }
  for (const id of [...ids].sort()) visit(id);
  const required = ["review", "verification", "pr_draft", "completion", "seat_outcome"];
  if (required.some(kind => !plan.required_evidence.includes(kind)) || plan.required_evidence.length !== required.length) {
    die("incomplete_required_evidence", "all canonical candidate evidence kinds are required");
  }
  const shared = plan.parallel_policy.shared_mutation_paths.slice().sort();
  if (JSON.stringify(shared) !== JSON.stringify(plan.parallel_policy.shared_mutation_paths)) die("unsorted_shared_paths", "parallel_policy.shared_mutation_paths");
  for (const p of shared) validatePath(root, p);
  return { root, seats };
}
function dependsTransitively(seats, from, target, seen = new Set()) {
  if (seen.has(from)) return false;
  seen.add(from);
  for (const dep of seats.get(from).depends_on) {
    if (dep === target || dependsTransitively(seats, dep, target, seen)) return true;
  }
  return false;
}
function validateSchema(plan, schemaFile, validatorFile) {
  let validate, schema;
  try { ({ validate } = require(validatorFile)); schema = readJson(schemaFile, "invalid_plan_schema"); }
  catch (error) { die("invalid_plan_schema", error.message); }
  const errors = validate(schema, plan);
  if (errors.length) die("invalid_execution_plan", errors.join("; "));
}
function decisions(plan, seats) {
  const ids = [...seats.keys()].sort();
  const pairs = [];
  for (let i = 0; i < ids.length; i += 1) {
    for (let j = i + 1; j < ids.length; j += 1) {
      const left = seats.get(ids[i]), right = seats.get(ids[j]);
      let classification = "parallel_eligible", reason_code = "disjoint_exact_write_sets";
      if (left.write_set.mode !== "exact" || right.write_set.mode !== "exact") {
        classification = "serialized"; reason_code = "unproven_write_set";
      } else if (plan.parallel_policy.database_isolation === "unproven" || plan.parallel_policy.environment_isolation === "unproven" || plan.parallel_policy.rate_limit_budget === "unproven") {
        classification = "serialized"; reason_code = "isolation_or_budget_unproven";
      } else if (dependsTransitively(seats, left.id, right.id) || dependsTransitively(seats, right.id, left.id)) {
        classification = "serialized"; reason_code = "dependency_order";
      } else if (plan.parallel_policy.shared_mutation_paths.some(shared => left.write_set.paths.concat(right.write_set.paths).some(p => overlaps(p, shared)))) {
        classification = "serialized"; reason_code = "shared_mutable_surface";
      } else if (left.write_set.paths.some(a => right.write_set.paths.some(b => overlaps(a, b)))) {
        classification = "serialized"; reason_code = "write_set_overlap";
      }
      pairs.push({ seats: [left.id, right.id], classification, reason_code });
    }
  }
  return pairs;
}
function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 2) {
    if (!argv[i].startsWith("--") || i + 1 >= argv.length) die("invalid_arguments", argv[i] || "missing argument");
    out[argv[i].slice(2)] = argv[i + 1];
  }
  return out;
}

const DEFAULT_SCHEMA = path.join(__dirname, "..", "..", "schemas", "execution_plan.schema.json");
const DEFAULT_VALIDATOR = path.join(__dirname, "json-schema-subset.cjs");

const command = process.argv[2];
if (command !== "decide" && command !== "admit") die("invalid_arguments", `unknown command: ${command}`);
const args = parseArgs(process.argv.slice(3));
const planFile = args.plan;
const target = args.target || args.worktree;
const schemaFile = args.schema || DEFAULT_SCHEMA;
const validatorFile = args.validator || DEFAULT_VALIDATOR;
if (!planFile || !target) die("invalid_arguments", "missing required arguments");
const plan = readJson(planFile, "invalid_execution_plan");
validateSchema(plan, schemaFile, validatorFile);
const checked = semantic(plan, target);

if (command === "decide") {
  const result = {
    schema_version: "1", issue: plan.issue, round: plan.round,
    manifest_revision: plan.manifest_revision, plan_revision: plan.plan_revision,
    plan_sha256: digest(planFile), pairs: decisions(plan, checked.seats)
  };
  process.stdout.write(JSON.stringify(result, null, 2) + "\n");
  process.exit(0);
}
if (!args.issue || !args.revision || !args.seat || !args["round-state"]) die("invalid_arguments", "admit requires issue, revision, seat, and round-state");
if (String(plan.issue) !== args.issue) die("plan_issue_mismatch", "plan issue differs from dispatch");
if (String(plan.manifest_revision) !== args.revision) die("plan_revision_mismatch", "plan manifest revision differs from dispatch");
const seat = checked.seats.get(args.seat);
if (!seat) die("unknown_plan_seat", args.seat);
const roundState = readJson(args["round-state"], "invalid_round_state");
let liveHead, realWorktree;
try {
  realWorktree = fs.realpathSync(target);
  liveHead = execFileSync("git", ["-C", realWorktree, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
} catch (error) { die("uncheckable_worktree", error.message); }
if (liveHead !== plan.base_head) die("plan_base_head_mismatch", "worktree is not at the planned base HEAD");
if (roundState.issue.number !== plan.issue || roundState.revision !== plan.manifest_revision) die("round_state_plan_mismatch", "ROUND-STATE identity differs from plan");
if (fs.realpathSync(roundState.worktree_path) !== realWorktree) die("plan_worktree_mismatch", "ROUND-STATE worktree differs from dispatch");
if (seat.write_set.mode !== "exact") die("unproven_write_set", "non-exact seats may not enter write admission");
const actualWriteSet = roundState.contract.touch_allowlist.slice().sort();
if (JSON.stringify(actualWriteSet) !== JSON.stringify(seat.write_set.paths)) die("plan_write_set_mismatch", "ROUND-STATE allowlist differs from seat write set");
const planSha = digest(planFile);
const binding = `issue-${plan.issue}-round-${plan.round}-plan-${plan.plan_revision}-seat-${seat.id}-${planSha}`;
if (args.consume === "true") {
  let common;
  try {
    const raw = execFileSync("git", ["-C", realWorktree, "rev-parse", "--git-common-dir"], { encoding: "utf8" }).trim();
    common = path.isAbsolute(raw) ? raw : path.resolve(realWorktree, raw);
    const root = path.join(common, "agent-workflow", "parallel-admissions");
    fs.mkdirSync(root, { recursive: true });
    fs.mkdirSync(path.join(root, binding));
  } catch (error) {
    if (error.code === "EEXIST") die("parallel_admission_already_consumed", binding, 1);
    die("parallel_admission_store_failed", error.message);
  }
}
process.stdout.write(JSON.stringify({ status: "admitted", binding, issue: plan.issue, round: plan.round, plan_revision: plan.plan_revision, seat: seat.id, write_set: seat.write_set.paths }) + "\n");
