#!/usr/bin/env node
const fs = require("fs");
const path = require("path");

const args = process.argv.slice(2);
let expectedRouteDigest = null;
let routeBinding = null;
for (let index = args.length - 2; index >= 1; index -= 1) {
  if (args[index] !== "--route-digest" && args[index] !== "--route-binding") continue;
  const option = args[index], value = args[index + 1];
  if (!value || (option === "--route-digest" && expectedRouteDigest !== null)
      || (option === "--route-binding" && routeBinding !== null)) process.exit(2);
  if (option === "--route-digest") expectedRouteDigest = value;
  else {
    try { routeBinding = JSON.parse(value); } catch (_) { process.exit(2); }
  }
  args.splice(index, 2);
}
if (routeBinding !== null && args[0] !== "publish") process.exit(2);
const [mode, integratedDir, admissionDir, roundState, issue, key, ownerPid] = args;
if (!mode || !integratedDir) process.exit(2);
const txName = ".admission-transaction.json";
const read = file => { try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch (_) { return null; } };
const remove = dir => { try { fs.rmSync(dir, { recursive: true, force: true }); } catch (_) { process.exitCode = 2; } };
const write = (file, value) => {
  const temp = `${file}.tmp.${process.pid}`;
  fs.writeFileSync(temp, JSON.stringify(value) + "\n", { flag: "wx", mode: 0o600 });
  fs.renameSync(temp, file);
};
const processAlive = pid => {
  if (!pid) return false;
  try {
    process.kill(pid, 0);
    const stat = require("child_process").execFileSync("ps", ["-p", String(pid), "-o", "stat="], { encoding: "utf8" }).trim();
    return stat.length > 0 && stat.indexOf("Z") === -1;
  } catch (_) { return false; }
};
const safeIssue = value => /^[1-9][0-9]*$/.test(String(value));
const safeKey = value => new RegExp("^issue-[1-9][0-9]*-dispatch-[1-9][0-9]*$").test(String(value));
const safeRouteDigest = value => /^[a-f0-9]{64}$/.test(String(value));
const safeRouteBinding = value => {
  if (!value || typeof value !== "object" || Array.isArray(value)
      || Object.keys(value).sort().join(",") !== "decision_reason_codes,policy_digest,role,route_digest,runtime,selected,selection_basis,tier,transport"
      || !safeRouteDigest(value.route_digest) || !safeRouteDigest(value.policy_digest)
      || !["codex", "claude", "opencode"].includes(value.runtime)
      || !["implementation", "reviewer", "verifier"].includes(value.role)
      || !["trivial", "standard", "full_cluster"].includes(value.tier)
      || !require("./transport-registry.cjs").ADAPTERS.includes(value.transport)
      || value.selection_basis !== "ordered_policy"
      || !Array.isArray(value.decision_reason_codes) || value.decision_reason_codes.length < 1
      || !value.decision_reason_codes.every(code => ["model_alloc", "ordered_policy"].includes(code))
      || !value.selected || typeof value.selected !== "object"
      || Object.keys(value.selected).sort().join(",") !== "effort,model"
      || !/^[A-Za-z0-9._-]{1,64}$/.test(value.selected.model || "")
      || !(/^(?:gpt-5[.-]6(?:-|$))/.test(value.selected.model)
        ? ["none", "low", "medium", "high", "xhigh", "max"].includes(value.selected.effort)
        : ["low", "medium", "high"].includes(value.selected.effort))) return false;
  return new Set(value.decision_reason_codes).size === value.decision_reason_codes.length;
};
if (expectedRouteDigest !== null && !safeRouteDigest(expectedRouteDigest)) process.exit(2);
if (routeBinding !== null && (!safeRouteBinding(routeBinding) || routeBinding.route_digest !== expectedRouteDigest)) process.exit(2);
const routeFailure = (transaction, expected = expectedRouteDigest) => {
  if (!expected) return null;
  if (!transaction || !Object.prototype.hasOwnProperty.call(transaction, "route_digest")) return "route_digest_unbound";
  return transaction.route_digest === expected ? null : "route_digest_mismatch";
};
const reportRouteFailure = code => {
  process.stdout.write(`${code}\n`);
  process.exit(process.exitCode || 3);
};
const contained = (parent, child) => {
  const root = path.resolve(parent);
  const target = path.resolve(child);
  return target !== root && target.indexOf(root + path.sep) === 0;
};
function validPair(root, singleton, admission, issue, key) {
  if (!safeIssue(issue) || !safeKey(key)) return false;
  const base = path.resolve(root);
  return path.resolve(singleton) === path.join(base, `issue-${issue}-integrated-fix`)
    && path.resolve(admission) === path.join(base, key)
    && contained(base, singleton) && contained(base, admission);
}
function validAdmission(root, admission, issue, key) {
  return safeIssue(issue) && safeKey(key)
    && path.resolve(admission) === path.join(path.resolve(root), key)
    && contained(root, admission);
}
function isAdvanced(state, key) {
  const match = /-dispatch-([0-9]+)$/.exec(key || "");
  return Boolean(state && state.round_control && (
    state.round_control.last_admission_key === key
    || (match && Number.isInteger(state.round_control.next_dispatch_ordinal)
      && state.round_control.next_dispatch_ordinal > Number(match[1]))));
}
function quarantineDeadDir(dir) {
  // Claim the stale directory by rename before deleting it.  A delete followed
  // by mkdir lets another publisher acquire the same name between the two
  // operations; rename is the linearization point.
  let stat;
  try { stat = fs.lstatSync(dir); } catch (_) { return true; }
  if (!stat.isDirectory()) return false;
  const owner = read(path.join(dir, ".agent-workflow-owner.json"));
  if (owner && processAlive(owner.pid)) return false;
  const claimed = `${dir}.reclaim.${process.pid}.${Date.now()}`;
  try { fs.renameSync(dir, claimed); } catch (_) { return false; }
  try { fs.rmSync(claimed, { recursive: true, force: true }); return true; } catch (_) { return false; }
}
// A lock is published only after its ownership record exists: prepare a
// private directory, write the record, then atomically rename it into the
// well-known lock name.  That removes the otherwise-unrecoverable interval
// between mkdir(.issue-N-lock) and writing its pid.
if (mode === "acquire-lock") {
  const lockFile = integratedDir;
  if (!lockFile || !key || !issue) process.exit(2);
  const lockDir = path.dirname(lockFile);
  const parent = path.dirname(lockDir);
  const pending = `${lockDir}.pending.${process.pid}.${Date.now()}`;
  try {
    fs.mkdirSync(pending, { mode: 0o700 });
    write(path.join(pending, path.basename(lockFile)), { version: 1, issue: String(issue), admission_key: key, pid: Number(ownerPid) || process.ppid, status: "locked" });
    fs.renameSync(pending, lockDir);
    process.exit(0);
  } catch (_) {
    try { fs.rmSync(pending, { recursive: true, force: true }); } catch (_) {}
    process.exit(1);
  }
}
// Publish every current admission only after its journal exists in a private
// sibling directory.  mkdir(target) followed by writing metadata has a fatal
// SIGKILL interval: a later conductor cannot distinguish a consumed legacy
// marker from a new, incomplete attempt.  rename is the visibility point.
if (mode === "publish") {
  const root = integratedDir;
  const target = admissionDir;
  const kind = args[7];
  if (!root || !target || !key || !issue || !roundState
      || (kind !== "normal" && kind !== "integrated")
      || (!(kind === "integrated" && path.resolve(target) === path.join(path.resolve(root), `issue-${issue}-integrated-fix`))
        && !validAdmission(root, target, issue, key))) process.exit(2);
  const pending = `${target}.pending.${process.pid}.${Date.now()}`;
  const tx = { version: 1, issue: String(issue), admission_key: key, round_state: path.resolve(roundState), status: "prepared", kind };
  if (expectedRouteDigest) tx.route_digest = expectedRouteDigest;
  if (routeBinding) tx.routing = routeBinding;
  try {
    // POSIX rename may replace an empty destination directory.  Admission
    // publication is serialized by the issue lock, so a target that already
    // exists is a durable sentinel/previous admission, never ours to replace.
    // In particular, preserve metadata-free legacy integrated singletons.
    let targetExists = false;
    try { fs.lstatSync(target); targetExists = true; }
    catch (error) { if (!error || error.code !== "ENOENT") throw error; }
    if (targetExists) throw new Error("admission_target_exists");
    fs.mkdirSync(pending, { mode: 0o700 });
    write(path.join(pending, txName), tx);
    targetExists = false;
    try { fs.lstatSync(target); targetExists = true; }
    catch (error) { if (!error || error.code !== "ENOENT") throw error; }
    if (targetExists) throw new Error("admission_target_exists");
    fs.renameSync(pending, target);
  } catch (_) {
    try { fs.rmSync(pending, { recursive: true, force: true }); } catch (_) {}
    process.exit(1);
  }
  process.exit(0);
}
if (mode === "commit-admission") {
  const root = path.dirname(integratedDir);
  const tx = read(path.join(integratedDir, txName));
  if (!tx || !safeIssue(issue) || !safeKey(key) || String(tx.issue) !== String(issue)
      || tx.admission_key !== key || !validAdmission(root, integratedDir, issue, key)) process.exit(2);
  try { tx.status = "committed"; write(path.join(integratedDir, txName), tx); } catch (_) { process.exit(2); }
  process.exit(0);
}
if (mode === "lock-prepare") {
  if (!key || !issue) process.exit(2);
  try { write(integratedDir, { version: 1, issue: String(issue), admission_key: key, pid: Number(ownerPid) || process.ppid, status: "locked" }); } catch (_) { process.exit(2); }
  process.exit(0);
}
if (mode === "recover-lock") {
  const lockFile = integratedDir;
  const singleton = admissionDir;
  const root = roundState;
  if (!lockFile || !singleton || !root || !issue || !safeIssue(issue)) process.exit(2);
  const owner = read(lockFile);
  // The issue lock belongs to its recorded live process, regardless of the
  // lock file's age. A busy process can legitimately hold it longer than the
  // stale-recovery threshold; reclaiming it would admit two writers.
  // Current writers publish this file before the lock directory is renamed
  // into place.  Therefore an empty lock can only be a pre-protocol orphan
  // (or a crash from an older binary), never a live current owner.
  if (!owner) {
    // Legacy ownerless locks are never created by the current protocol. Claim
    // the directory atomically before removal instead of racing a new owner.
    if (!quarantineDeadDir(path.dirname(lockFile))) process.exit(2);
    process.exit(0);
  }
  if (processAlive(owner.pid)) process.exit(1);
  const state = read(root);
  const match = /-dispatch-([0-9]+)$/.exec(owner.admission_key || "");
  const advanced = state && state.round_control && (state.round_control.last_admission_key === owner.admission_key || (match && Number.isInteger(state.round_control.next_dispatch_ordinal) && state.round_control.next_dispatch_ordinal > Number(match[1])));
  const singletonTx = read(path.join(singleton, txName));
  // Do not let stale issue-lock recovery reinterpret the historical
  // metadata-free singleton sentinel as a current interrupted pair.
  if (!advanced && singletonTx && singletonTx.status === "prepared"
      && String(singletonTx.issue) === String(issue)
      && singletonTx.admission_key === owner.admission_key
      && safeKey(owner.admission_key)
      && validPair(path.dirname(singleton), singleton, path.join(path.dirname(singleton), owner.admission_key), issue, owner.admission_key)) {
    remove(singleton);
    if (owner.admission_key) remove(path.join(path.dirname(path.dirname(lockFile)), owner.admission_key));
  }
  if (!quarantineDeadDir(path.dirname(lockFile))) process.exit(2);
  process.exit(process.exitCode || 0);
}
if (mode === "release-lock") {
  try { fs.unlinkSync(integratedDir); fs.rmdirSync(path.dirname(integratedDir)); } catch (_) { process.exit(2); }
  process.exit(0);
}
if (mode === "commit") {
  try {
    const file = path.join(integratedDir, txName); const tx = read(file);
    if (!tx) process.exit(2); tx.status = "committed"; write(file, tx);
    const marker = path.join(admissionDir, txName); if (fs.existsSync(marker)) write(marker, tx);
  } catch (_) { process.exit(2); }
  process.exit(0);
}
if (mode === "rollback") { remove(integratedDir); remove(admissionDir); process.exit(process.exitCode || 0); }
if (mode !== "recover" || !roundState || !issue) process.exit(2);
const admissionRoot = path.dirname(admissionDir);
const state = read(roundState);
// A normal ordinal is also journalled before it becomes visible.  Recover a
// current prepared record only while the host ordinal has not advanced.
// Metadata-free directories are historical consumed markers and stay
// fail-closed, just like the legacy integrated singleton below.
if (fs.existsSync(admissionDir)) {
  const normal = read(path.join(admissionDir, txName));
  if (normal && normal.kind === "normal" && safeIssue(issue) && safeKey(normal.admission_key)
      && String(normal.issue) === String(issue)
      && normal.admission_key === path.basename(admissionDir)
      && validAdmission(admissionRoot, admissionDir, issue, normal.admission_key)) {
    const advanced = isAdvanced(state, normal.admission_key);
    const normalRouteFailure = routeFailure(normal);
    if (normalRouteFailure) {
      if (!advanced && normal.status === "prepared") {
        remove(admissionDir);
        process.exit(process.exitCode || 0);
      }
      reportRouteFailure(normalRouteFailure);
    }
    if (advanced) {
      if (normal.status !== "committed") {
        try { normal.status = "committed"; write(path.join(admissionDir, txName), normal); } catch (_) { process.exit(2); }
      }
    } else if (normal.status === "prepared") {
      remove(admissionDir);
    }
  }
}
if (!fs.existsSync(integratedDir)) process.exit(process.exitCode || 0);
const tx = read(path.join(integratedDir, txName));
// Before transaction metadata existed, the singleton directory itself was the
// durable "integrated fix consumed" sentinel.  It has no way to prove that it
// belongs to an interrupted current transaction, so preserving it is the only
// safe migration behavior: deleting it could admit a second integrated fix.
if (!tx) process.exit(0);
if (!safeIssue(issue) || !safeKey(tx.admission_key) || String(tx.issue) !== String(issue) || !validPair(admissionRoot, integratedDir, path.join(admissionRoot, tx.admission_key), issue, tx.admission_key)) process.exit(2);
// A recovery invocation owns only its current admission key.  A prior-key
// singleton remains the existing durable sentinel; it is never adopted or
// reclaimed by a later route attempt.
if (expectedRouteDigest && key && tx.admission_key !== key) process.exit(0);
let advanced = Boolean(tx && tx.status === "committed");
advanced = advanced || isAdvanced(state, tx.admission_key);
if (expectedRouteDigest) {
  const ordinalFile = path.join(admissionRoot, tx.admission_key, txName);
  const ordinal = read(ordinalFile);
  const singletonFailure = routeFailure(tx);
  const ordinalFailure = routeFailure(ordinal);
  let integratedFailure = singletonFailure || ordinalFailure;
  if (!integratedFailure && (!ordinal || ordinal.kind !== "integrated"
      || String(ordinal.issue) !== String(tx.issue)
      || ordinal.admission_key !== tx.admission_key)) {
    integratedFailure = "route_digest_unbound";
  }
  if (!integratedFailure && ordinal.route_digest !== tx.route_digest) integratedFailure = "route_digest_mismatch";
  if (integratedFailure) {
    if (!advanced && tx.status === "prepared") {
      remove(integratedDir);
      remove(path.join(admissionRoot, tx.admission_key));
      process.exit(process.exitCode || 0);
    }
    reportRouteFailure(integratedFailure);
  }
}
if (advanced) {
  try { tx.status = "committed"; write(path.join(integratedDir, txName), tx); if (fs.existsSync(path.join(admissionDir, txName))) write(path.join(admissionDir, txName), tx); } catch (_) { process.exit(2); }
  process.exit(0);
}
// A current, identified integrated singleton without a state advance is a
// prepared transaction interrupted before launch. Remove only its paired
// ordinal; metadata-free legacy sentinels returned above are never reclaimed.
remove(integratedDir);
remove(path.join(admissionRoot, tx.admission_key));
process.exit(process.exitCode || 0);
