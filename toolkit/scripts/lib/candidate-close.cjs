#!/usr/bin/env node
"use strict";
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { execFileSync, spawnSync } = require("child_process");
const { parseRfc3339 } = require("./rfc3339.cjs");
const { headMatches, sameJson } = require("./contract-validators.cjs");

function args(argv) { const out = {}; for (let i = 0; i < argv.length; i += 2) { if (!argv[i] || !argv[i].startsWith("--") || i + 1 >= argv.length) fatal("invalid_arguments"); out[argv[i].slice(2)] = argv[i + 1]; } return out; }
function fatal(code, message = code) { process.stdout.write(JSON.stringify({ status: "error", reason_codes: [code], error: message }) + "\n"); process.exit(2); }
function json(file, code) { try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch (error) { fatal(code, error.message); } }
function digest(file) { return crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex"); }
function git(cwd, a) { return execFileSync("git", ["-C", cwd, ...a], { encoding: "utf8" }).trim(); }
function clean(cwd) { return git(cwd, ["status", "--porcelain"]).split(/\r?\n/).filter(Boolean).filter(line => !/^\?\? \.review\//.test(line)).length === 0; }
function inside(root, candidate) { const rel = path.relative(root, candidate); return rel === "" || (!rel.startsWith(".." + path.sep) && rel !== ".." && !path.isAbsolute(rel)); }
function schemaValidate(value, schemaFile, validate, code) { const errors = validate(json(schemaFile, code), value); if (errors.length) fatal(code, errors.join("; ")); }
const validRfc3339 = value => parseRfc3339(value) !== null;

const command = process.argv[2];
const a = args(process.argv.slice(3));
if (command === "inspect") {
  if (!a.closure || !a.worktree || !a.schema || !a.validator) fatal("invalid_arguments");
  const value = json(a.closure, "invalid_closure"); const { validate } = require(a.validator);
  schemaValidate(value, a.schema, validate, "invalid_closure");
  if (!validRfc3339(value.evaluated_at)) fatal("invalid_closure_timestamp");
  let live; try { live = git(fs.realpathSync(a.worktree), ["rev-parse", "HEAD"]); } catch (error) { fatal("uncheckable_candidate"); }
  let evidenceChanged = false;
  try {
    const reviewDir = path.join(fs.realpathSync(a.worktree), ".review");
    evidenceChanged = digest(path.join(reviewDir, `ISSUE-${value.issue}-INTEGRATION.json`)) !== value.integration_sha256
      || digest(path.join(reviewDir, `ISSUE-${value.issue}-CANDIDATE-EVIDENCE.json`)) !== value.evidence_set_sha256;
  } catch (_) { evidenceChanged = true; }
  const stale = !headMatches(live, value.candidate_head) || evidenceChanged;
  const staleReasons = [!headMatches(live, value.candidate_head) ? "candidate_head_advanced" : null, evidenceChanged ? "closure_evidence_changed" : null].filter(Boolean);
  process.stdout.write(JSON.stringify({ status: stale ? "stale" : value.status, candidate_head: value.candidate_head, live_head: live, reason_codes: stale ? staleReasons : value.reason_codes }) + "\n");
  process.exit(stale ? 1 : value.status === "closed" ? 0 : 1);
}
if (command !== "evaluate") fatal("invalid_arguments");
for (const key of ["plan", "target", "candidate-worktree", "integration", "evidence-set", "output", "plan-schema", "integration-schema", "evidence-schema", "closure-schema", "validator", "planner", "review-schema", "verify-schema", "verify-result", "pr-schema", "completion-schema", "seat-schema", "blocker-schema"]) if (!a[key]) fatal("invalid_arguments", `missing --${key}`);
const planner = spawnSync(process.execPath, [a.planner, "decide", "--plan", a.plan, "--target", a.target], { encoding: "utf8" });
if (planner.status !== 0) { process.stdout.write(planner.stdout || planner.stderr); process.exit(planner.status || 2); }
const { validate } = require(a.validator);
const plan = json(a.plan, "invalid_execution_plan"), integration = json(a.integration, "invalid_integration_result"), set = json(a["evidence-set"], "invalid_evidence_set");
schemaValidate(plan, a["plan-schema"], validate, "invalid_execution_plan");
schemaValidate(integration, a["integration-schema"], validate, "invalid_integration_result");
schemaValidate(set, a["evidence-schema"], validate, "invalid_evidence_set");
let candidate;
try { candidate = fs.realpathSync(a["candidate-worktree"]); } catch (error) { fatal("uncheckable_candidate"); }
try {
  if (fs.realpathSync(a.integration) !== fs.realpathSync(path.join(candidate, `.review/ISSUE-${plan.issue}-INTEGRATION.json`))) fatal("noncanonical_integration_result");
  if (fs.realpathSync(a["evidence-set"]) !== fs.realpathSync(path.join(candidate, `.review/ISSUE-${plan.issue}-CANDIDATE-EVIDENCE.json`))) fatal("noncanonical_evidence_set");
} catch (error) {
  if (error && error.code) fatal("missing_canonical_candidate_artifact", error.message);
  throw error;
}
const reasons = [];
let liveHead;
try { liveHead = git(candidate, ["rev-parse", "HEAD"]); } catch (error) { fatal("uncheckable_candidate"); }
const identity = value => value.issue === plan.issue && value.round === plan.round && value.manifest_revision === plan.manifest_revision && value.plan_revision === plan.plan_revision;
const bindingMatches = (value, entry) => {
  const binding = value && value.closure_binding;
  return binding && identity(binding) && headMatches(liveHead, binding.candidate_head)
    && binding.attempt_id === set.attempt_id && binding.attempt_id === entry.attempt_id
    && validRfc3339(binding.generated_at)
    && Date.parse(binding.generated_at) >= Date.parse(integration.created_at);
};
if (!identity(integration) || integration.plan_sha256 !== digest(a.plan)) reasons.push("integration_plan_mismatch");
if (!validRfc3339(integration.created_at) || !validRfc3339(set.created_at)) reasons.push("invalid_candidate_timestamp");
const actualStepOrder = integration.steps.map(step => step.seat_id);
const stepOrderValid = actualStepOrder.length === plan.integration_order.length
  && new Set(actualStepOrder).size === actualStepOrder.length
  && sameJson(actualStepOrder, plan.integration_order);
if (!stepOrderValid) reasons.push("integration_step_order_mismatch");
if (integration.status !== "pass" || !integration.candidate_clean || integration.steps.some(step => step.status !== "integrated")) reasons.push("integration_incomplete");
if (!headMatches(liveHead, integration.candidate_head)) reasons.push("candidate_head_advanced");
  if (!clean(candidate)) reasons.push("dirty_candidate");
  if (!identity(set) || !headMatches(liveHead, set.candidate_head)) reasons.push("evidence_identity_mismatch");
if (Date.parse(set.created_at) < Date.parse(integration.created_at)) reasons.push("stale_evidence_set");
const entries = new Map();
for (const entry of set.evidence) {
  const key = entry.kind === "seat_outcome" ? `${entry.kind}:${entry.seat_id || ""}` : entry.kind;
  if (entries.has(key)) reasons.push("duplicate_evidence_kind");
  entries.set(key, entry);
  if (entry.attempt_id !== set.attempt_id) reasons.push("mixed_attempt_evidence");
  if (entry.status !== "pass") reasons.push(`failed_${entry.kind}`);
}
for (const kind of plan.required_evidence.filter(k => k !== "seat_outcome")) if (!entries.has(kind)) reasons.push(`missing_${kind}`);
for (const seat of plan.seats) if (!entries.has(`seat_outcome:${seat.id}`)) reasons.push("missing_seat_outcome");
const canonical = {
  review: `.review/ISSUE-${plan.issue}-REVIEW.json`,
  verification: `.review/ISSUE-${plan.issue}-VERIFY.json`,
  pr_draft: `.review/ISSUE-${plan.issue}-PR-DRAFT.json`,
  completion: `.review/ISSUE-${plan.issue}-COMPLETION.json`
};
function loadEntry(entry, expectedPath) {
  if (entry.path !== expectedPath) { reasons.push("noncanonical_evidence_path"); return null; }
  const absolute = path.resolve(candidate, entry.path);
  let real;
  try { real = fs.realpathSync(absolute); } catch (_) { reasons.push("missing_evidence_artifact"); return null; }
  if (!inside(candidate, real)) { reasons.push("evidence_symlink_escape"); return null; }
  if (digest(real) !== entry.sha256) { reasons.push("evidence_hash_mismatch"); return null; }
  return json(real, "invalid_evidence_artifact");
}
const reviewEntry = entries.get("review"), verifyEntry = entries.get("verification"), prEntry = entries.get("pr_draft"), completionEntry = entries.get("completion");
if (reviewEntry) {
  const value = loadEntry(reviewEntry, canonical.review);
  if (value) {
    const reviewSchema = json(a["review-schema"], "invalid_review_schema");
    delete reviewSchema.if; delete reviewSchema.then;
    if (validate(reviewSchema, value).length || !bindingMatches(value, reviewEntry) || value.issue.number !== plan.issue || !headMatches(liveHead, value.reviewed_head_sha) || value.lifecycle !== "final" || value.status !== "pass" || value.checklist.some(x => !x.met)) reasons.push("candidate_review_not_green");
  }
}
if (verifyEntry) {
  const value = loadEntry(verifyEntry, canonical.verification);
  if (value) {
    const runs = Array.isArray(value.runs) ? value.runs : [value];
    const semantic = spawnSync("node", [a["verify-result"], "validate-artifact", path.join(candidate, canonical.verification), a["verify-schema"], a.validator], { encoding: "utf8" });
    if (semantic.status !== 0 || validate(json(a["verify-schema"], "invalid_verify_schema"), value).length || !bindingMatches(value, verifyEntry) || value.issue !== plan.issue || !headMatches(liveHead, value.head_sha) || value.classifier !== "PASS" || value.verdict.exit_code !== 0 || value.verdict.failed !== 0 || value.verdict.passed < 1 || runs.some(run => run.classifier !== "PASS" || run.verdict.exit_code !== 0 || run.verdict.failed !== 0 || run.failures.length !== 0)) reasons.push("candidate_verification_not_green");
  }
}
if (prEntry) {
  const value = loadEntry(prEntry, canonical.pr_draft);
  if (value) {
    if (validate(json(a["pr-schema"], "invalid_pr_schema"), value).length || !bindingMatches(value, prEntry) || value.issue.number !== plan.issue || !headMatches(liveHead, value.head_sha) || value.lifecycle !== "active" || value.status !== "ready_for_review") reasons.push("candidate_pr_draft_not_ready");
  }
}
if (completionEntry) {
  const value = loadEntry(completionEntry, canonical.completion);
  if (value && (validate(json(a["completion-schema"], "invalid_completion_schema"), value).length || !validRfc3339(value.created_at) || !bindingMatches(value, completionEntry) || !(identity(value) && headMatches(liveHead, value.head_sha) && value.status === "pass"))) reasons.push("candidate_completion_not_green");
}
for (const seat of plan.seats) {
  const entry = entries.get(`seat_outcome:${seat.id}`);
  if (!entry) continue;
  const value = loadEntry(entry, `.review/ISSUE-${plan.issue}-SEAT-${seat.id}.json`);
  const step = integration.steps.find(item => item.seat_id === seat.id);
  if (value && (!step || validate(json(a["seat-schema"], "invalid_seat_schema"), value).length || !validRfc3339(value.created_at) || !bindingMatches(value, entry) || !(identity(value) && value.seat_id === seat.id && value.source_head === step.source_head && sameJson(value.changed_paths, step.changed_paths) && value.status === "pass"))) reasons.push("seat_outcome_not_green");
}
const blockerPath = path.join(candidate, `.review/ISSUE-${plan.issue}-BLOCKER.json`);
if (fs.existsSync(blockerPath)) {
  const blocker = json(blockerPath, "invalid_blocker");
  if (validate(json(a["blocker-schema"], "invalid_blocker_schema"), blocker).length) reasons.push("invalid_blocker");
  else if (blocker.lifecycle === "active" || blocker.lifecycle === "final") reasons.push("unresolved_blocker");
}
const uniqueReasons = [...new Set(reasons)].sort();
const closure = {
  schema_version: "1", artifact_type: "candidate_closure", producer_role: "CONDUCTOR",
  issue: plan.issue, round: plan.round, manifest_revision: plan.manifest_revision, plan_revision: plan.plan_revision,
  candidate_head: liveHead, attempt_id: set.attempt_id, integration_sha256: digest(a.integration), evidence_set_sha256: digest(a["evidence-set"]), status: uniqueReasons.length ? "blocked" : "closed",
  reason_codes: uniqueReasons, evaluated_at: new Date().toISOString()
};
schemaValidate(closure, a["closure-schema"], validate, "invalid_closure");
fs.mkdirSync(path.dirname(a.output), { recursive: true }); const tmp = `${a.output}.tmp-${process.pid}`;
fs.writeFileSync(tmp, JSON.stringify(closure, null, 2) + "\n"); fs.renameSync(tmp, a.output);
process.stdout.write(JSON.stringify({ status: closure.status, candidate_head: liveHead, reason_codes: uniqueReasons, artifact: a.output }) + "\n");
process.exit(uniqueReasons.length ? 1 : 0);
