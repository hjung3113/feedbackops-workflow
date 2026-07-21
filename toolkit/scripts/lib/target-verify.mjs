#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { spawnSync, execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
const require = createRequire(import.meta.url);
const { validate } = require("./json-schema-subset.cjs");
const { validArtifact } = require("./verify-result.cjs");

const [profileArg, issueArg] = process.argv.slice(2);
const fail = (message, code = 2) => { console.error(`target-verify: ${message}`); process.exit(code); };
if (!/^\d+$/.test(issueArg || "")) fail("issue must be an integer");
let root;
try { root = execFileSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf8" }).trim(); }
catch { fail("current directory is not a git repository"); }
const product = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const schemaPath = path.join(product, "schemas/target-profile.schema.json");
const verifySchemaPath = path.join(product, "schemas/verify.schema.json");
let profile;
try { profile = JSON.parse(fs.readFileSync(path.resolve(profileArg), "utf8")); }
catch (error) { fail(`profile is unreadable or malformed: ${error.message}`); }
const profileErrors = validate(JSON.parse(fs.readFileSync(schemaPath)), profile);
if (profileErrors.length) fail(`profile schema rejected: ${profileErrors.join("; ")}`);
const resolveCwd = (relative = ".") => {
  const resolved = fs.realpathSync(path.resolve(root, relative));
  const prefix = `${fs.realpathSync(root)}${path.sep}`;
  if (resolved !== fs.realpathSync(root) && !resolved.startsWith(prefix)) fail(`unsafe cwd traversal: ${relative}`);
  return resolved;
};
const executableExists = (exe) => (process.env.PATH || "").split(path.delimiter).some((directory) => {
  try { fs.accessSync(path.join(directory, exe), fs.constants.X_OK); return true; } catch { return false; }
});
for (const exe of profile.runtime.executables) if (!executableExists(exe)) fail(`required executable missing: ${exe}`, 1);
for (const name of profile.environment?.required || []) if (!process.env[name]) fail(`required environment missing: ${name}`, 1);
const limit = profile.verification.output_bytes || 16384;
const allowedBase = new Set(profile.environment?.allow || []);
const cleanEnv = (extra = []) => {
  const out = {};
  for (const name of ["PATH", "HOME", "TMPDIR", "LANG", ...allowedBase, ...extra]) if (process.env[name] !== undefined) out[name] = process.env[name];
  return out;
};
const runCommand = (command) => {
  const started = Date.now();
  let result;
  try { result = spawnSync(command.argv[0], command.argv.slice(1), { cwd: resolveCwd(command.cwd), env: cleanEnv(command.env_allow), encoding: "utf8", maxBuffer: Math.max(limit * 4, 65536) }); }
  catch (error) { result = { status: null, stdout: "", stderr: error.message, error }; }
  const combined = `${result.stdout || ""}${result.stderr || ""}`;
  const bytes = Buffer.from(combined, "utf8");
  const outputTruncated = bytes.length > limit;
  let end = Math.min(bytes.length, limit);
  if (outputTruncated) {
    const decoder = new TextDecoder("utf-8", { fatal: true });
    while (end > 0) {
      try { decoder.decode(bytes.subarray(0, end)); break; }
      catch { end -= 1; }
    }
  }
  return { argv: command.argv, cwd: command.cwd || ".", exit_code: Number.isInteger(result.status) ? result.status : 127, duration_ms: Date.now() - started, output: bytes.subarray(0, end).toString("utf8"), output_truncated: outputTruncated };
};
const groups = [];
const failures = [];
for (const group of profile.verification.groups) {
  const commands = group.commands.map(runCommand);
  let testCount;
  if (group.test_count) {
    let regex;
    try { regex = new RegExp(group.test_count.pattern, "m"); } catch { fail(`invalid test count pattern for ${group.id}`); }
    const match = regex.exec(commands.map((c) => c.output).join("\n"));
    testCount = match ? Number(match[group.test_count.group]) : null;
    if (!Number.isInteger(testCount) || testCount <= 0) failures.push({ code: "zero_or_unproven_tests", expected: ">0", actual: String(testCount) });
  }
  for (const command of commands) if (command.exit_code !== 0) failures.push({ code: "required_command_failed", expected: "0", actual: String(command.exit_code) });
  groups.push({ id: group.id, required: true, commands, ...(group.test_count ? { test_count: testCount } : {}) });
}
const branch = execFileSync("git", ["rev-parse", "--abbrev-ref", "HEAD"], { encoding: "utf8" }).trim();
const head = execFileSync("git", ["rev-parse", "HEAD"], { encoding: "utf8" }).trim();
const now = new Date().toISOString();
const currentRun = { verify_cmd: `target-verify.sh ${profile.id}`, verdict: { passed: failures.length ? 0 : groups.length, failed: failures.length, pending: 0, exit_code: failures.length ? 1 : 0 }, classifier: failures.length ? "FAIL" : "PASS", failures, groups, created_at: now };
const artifactPath = path.join(root, ".review", `ISSUE-${issueArg}-VERIFY.json`);
let runs = [currentRun];
if (fs.existsSync(artifactPath)) {
  let old;
  try { old = JSON.parse(fs.readFileSync(artifactPath, "utf8")); } catch { fail("existing canonical artifact is malformed", 1); }
  if (old.head_sha === head) {
    const oldSchemaErrors = validate(JSON.parse(fs.readFileSync(verifySchemaPath)), old);
    if (oldSchemaErrors.length || !validArtifact(old)) fail("existing same-HEAD canonical artifact failed schema or aggregate validation", 1);
    if (old.issue !== Number(issueArg) || old.branch !== branch || old.cwd !== root || old.target_profile !== profile.id) {
      fail("existing same-HEAD canonical artifact has a different verification identity", 1);
    }
    const oldRun = { verify_cmd: old.verify_cmd, verdict: old.verdict, classifier: old.classifier, failures: old.failures, groups: old.groups, created_at: old.created_at };
    runs = (Array.isArray(old.runs) ? old.runs : [oldRun]).concat(currentRun);
  }
}
const allPass = runs.every((run) => run.classifier === "PASS");
const latest = runs[runs.length - 1];
const artifact = { schema_version: "1", artifact_type: "verify_result", producer_role: "VERIFIER", issue: Number(issueArg), branch, head_sha: head, cwd: root, verify_cmd: latest.verify_cmd, target_profile: profile.id, verdict: { passed: runs.reduce((n,r)=>n+r.verdict.passed,0), failed: runs.reduce((n,r)=>n+r.verdict.failed,0), pending: 0, exit_code: allPass ? 0 : 1 }, classifier: allPass ? "PASS" : "FAIL", failures: runs.flatMap((r)=>r.failures), groups: latest.groups, runs, created_at: latest.created_at };
const schemaErrors = validate(JSON.parse(fs.readFileSync(verifySchemaPath)), artifact);
if (schemaErrors.length || !validArtifact(artifact)) fail(`verification artifact schema or aggregate rejected: ${schemaErrors.join("; ")}`, 1);
fs.mkdirSync(path.dirname(artifactPath), { recursive: true });
const temp = `${artifactPath}.tmp-${process.pid}`;
fs.writeFileSync(temp, `${JSON.stringify(artifact, null, 2)}\n`, { mode: 0o600 });
if (execFileSync("git", ["rev-parse", "HEAD"], { encoding: "utf8" }).trim() !== head) { fs.unlinkSync(temp); fail("HEAD changed during verification", 1); }
fs.renameSync(temp, artifactPath);
console.log(`${artifact.classifier}: ${groups.length} required groups at ${head}`);
process.exit(artifact.classifier === "PASS" ? 0 : 1);
