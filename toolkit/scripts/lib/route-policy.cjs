"use strict";

// Host-side policy lifecycle. This module is intentionally separate from the
// pure selector: it owns bounded filesystem validation and never decides a
// route or probes a runtime.
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const { canonical, validPolicy } = require("./route.cjs");

const MAX_BYTES = 256 * 1024;
const sha256 = value => crypto.createHash("sha256").update(value).digest("hex");
const routeFailure = code => {
  process.stdout.write(JSON.stringify({ status: "refused", code }) + "\n");
  process.exit(3);
};
const usage = () => process.exit(2);
const isRegularSafeFile = file => {
  try {
    const stat = fs.lstatSync(file);
    return stat.isFile() && !stat.isSymbolicLink() && (stat.mode & 0o022) === 0 && stat.size <= MAX_BYTES;
  } catch (_) {
    return false;
  }
};
const writeAtomic = (file, content, mode) => {
  const temp = `${file}.tmp-${process.pid}-${Date.now()}`;
  fs.writeFileSync(temp, content, { mode });
  fs.chmodSync(temp, mode);
  fs.renameSync(temp, file);
};
const contained = (parent, child) => {
  const root = path.resolve(parent);
  const target = path.resolve(child);
  return target === root || target.startsWith(`${root}${path.sep}`);
};

function resolveHostRoot(worktree, gitCommonDir) {
  const configured = process.env.AGENT_WORKFLOW_HOST_STATE
    || (process.env.XDG_STATE_HOME ? path.join(process.env.XDG_STATE_HOME, "agent-workflow")
      : path.join(process.env.HOME || "/tmp", ".local", "state", "agent-workflow"));
  const root = path.resolve(configured);
  const worktreeRoot = path.resolve(worktree);
  const commonRoot = path.resolve(gitCommonDir);
  if (contained(worktreeRoot, root) || contained(commonRoot, root)) routeFailure("route_policy_invalid");
  return root;
}

function policyDirectory(worktree, gitCommonDir) {
  const hostRoot = resolveHostRoot(worktree, gitCommonDir);
  let commonReal;
  try { commonReal = fs.realpathSync(gitCommonDir); } catch (_) { routeFailure("route_policy_invalid"); }
  const repositoryId = sha256(commonReal);
  return path.join(hostRoot, "repos", repositoryId, "routing-policy");
}

function parsePolicy(bytes) {
  try {
    const value = JSON.parse(bytes);
    if (!validPolicy(value)) routeFailure("route_policy_invalid");
    return value;
  } catch (_) {
    routeFailure("route_policy_invalid");
  }
}

function install({ worktree, gitCommonDir, policyFile }) {
  if (!worktree || !gitCommonDir || !policyFile || !isRegularSafeFile(policyFile)) routeFailure("route_policy_invalid");
  const bytes = fs.readFileSync(policyFile, "utf8");
  if (Buffer.byteLength(bytes, "utf8") > MAX_BYTES) routeFailure("route_policy_invalid");
  parsePolicy(bytes);
  const directory = policyDirectory(worktree, gitCommonDir);
  const snapshots = path.join(directory, "snapshots");
  try {
    fs.mkdirSync(snapshots, { recursive: true, mode: 0o700 });
    const digest = sha256(bytes);
    const snapshot = path.join(snapshots, `${digest}.json`);
    if (fs.existsSync(snapshot)) {
      if (!isRegularSafeFile(snapshot) || fs.readFileSync(snapshot, "utf8") !== bytes) routeFailure("route_policy_invalid");
    } else {
      writeAtomic(snapshot, bytes, 0o444);
    }
    const pointer = { version: 1, snapshot: `${digest}.json`, policy_digest: digest };
    writeAtomic(path.join(directory, "active.json"), `${canonical(pointer)}\n`, 0o600);
    process.stdout.write(JSON.stringify({ status: "installed", policy_digest: digest }) + "\n");
  } catch (_) {
    routeFailure("route_policy_invalid");
  }
}

function read({ worktree, gitCommonDir }) {
  if (!worktree || !gitCommonDir) usage();
  const directory = policyDirectory(worktree, gitCommonDir);
  const active = path.join(directory, "active.json");
  if (!fs.existsSync(active)) {
    process.stdout.write('{"status":"bypass"}\n');
    return;
  }
  if (!isRegularSafeFile(active)) routeFailure("route_policy_invalid");
  let pointer;
  try { pointer = JSON.parse(fs.readFileSync(active, "utf8")); } catch (_) { routeFailure("route_policy_invalid"); }
  if (!pointer || pointer.version !== 1 || typeof pointer.snapshot !== "string" || typeof pointer.policy_digest !== "string"
      || !/^[a-f0-9]{64}\.json$/.test(pointer.snapshot) || !/^[a-f0-9]{64}$/.test(pointer.policy_digest)
      || pointer.snapshot !== `${pointer.policy_digest}.json`) routeFailure("route_policy_invalid");
  const snapshot = path.join(directory, "snapshots", pointer.snapshot);
  if (!contained(path.join(directory, "snapshots"), snapshot) || !isRegularSafeFile(snapshot)) routeFailure("route_policy_invalid");
  const bytes = fs.readFileSync(snapshot, "utf8");
  if (sha256(bytes) !== pointer.policy_digest) routeFailure("route_policy_invalid");
  const policy = parsePolicy(bytes);
  process.stdout.write(JSON.stringify({ status: "active", policy, policy_digest: pointer.policy_digest }) + "\n");
}

function deactivate({ worktree, gitCommonDir }) {
  if (!worktree || !gitCommonDir) usage();
  const active = path.join(policyDirectory(worktree, gitCommonDir), "active.json");
  try {
    if (fs.existsSync(active)) {
      if (!isRegularSafeFile(active)) routeFailure("route_policy_invalid");
      fs.unlinkSync(active);
    }
    process.stdout.write('{"status":"deactivated"}\n');
  } catch (_) {
    routeFailure("route_policy_invalid");
  }
}

const [verb, ...args] = process.argv.slice(2);
const values = {};
for (let index = 0; index < args.length; index += 2) {
  const flag = args[index];
  const value = args[index + 1];
  if (!/^--(worktree|git-common-dir|policy-file)$/.test(flag || "") || value === undefined || Object.prototype.hasOwnProperty.call(values, flag)) usage();
  values[flag] = value;
}
const input = { worktree: values["--worktree"], gitCommonDir: values["--git-common-dir"], policyFile: values["--policy-file"] };
if (verb === "install") install(input);
else if (verb === "read") read(input);
else if (verb === "deactivate") deactivate(input);
else usage();
