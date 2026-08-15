// Shared atomic-filesystem primitives. Every helper is copied from the call
// sites it replaces (admission-recover.cjs, admission-advance.cjs,
// blocker-recovery.cjs, review-publish.cjs); the temp filename convention,
// permission bits, and rename atomicity are byte-level compatible with the
// previous inline implementations.
"use strict";

const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const ownerFileName = ".agent-workflow-owner.json";

// Atomic-write temp path convention shared by every writer: a per-process
// suffix makes concurrent writers independent and leaves a crash-interrupted
// attempt's leftovers distinguishable from a live one.
function atomicTempPath(file) {
  return `${file}.tmp.${process.pid}`;
}

// Atomic write via exclusive-create temp file + rename. `wx` refuses to
// clobber another live writer's temp; rename is the visibility point.
// `beforeRename`, when provided, runs between the write and the rename so a
// caller can keep its final preconditions adjacent to the linearization
// point; an error thrown there propagates without renaming.
function writeAtomic(file, content, beforeRename) {
  const temp = atomicTempPath(file);
  fs.writeFileSync(temp, content, { flag: "wx", mode: 0o600 });
  if (beforeRename) beforeRename();
  fs.renameSync(temp, file);
}

// Atomic JSON write with newline-terminated serialization. Without `indent`
// the bytes match the compact `JSON.stringify(value) + "\n"` form; with 2
// they match the pretty-printed round-state form.
function writeAtomicJson(file, value, indent) {
  writeAtomic(file, JSON.stringify(value, null, indent) + "\n");
}

// Publish a directory by preparing a private pending sibling (mode 0o700),
// populating it via `prepare(pending)`, then atomically renaming it into the
// well-known `dir` name. rename is the visibility point, so SIGKILL can leave
// only an unobservable pending directory, never a half-written visible one.
// On failure the pending directory is removed and the error is rethrown.
function publishViaPendingDir(dir, prepare) {
  const pending = `${dir}.pending.${process.pid}.${Date.now()}`;
  try {
    fs.mkdirSync(pending, { mode: 0o700 });
    if (prepare) prepare(pending);
    fs.renameSync(pending, dir);
  } catch (error) {
    try { fs.rmSync(pending, { recursive: true, force: true }); } catch (_) {}
    throw error;
  }
}

// Claim a stale owned directory by rename before deleting it. A delete
// followed by mkdir lets another publisher acquire the same name between the
// two operations; rename is the linearization point. Never modify a regular
// file (e.g. a Git lock, which Git may own) and never reclaim a directory
// whose recorded owner is still alive. A missing directory returns true
// (nothing to reclaim); any live-or-unknown claim returns false.
function quarantineThenDelete(dir) {
  let stat;
  try { stat = fs.lstatSync(dir); } catch (_) { return true; }
  if (!stat.isDirectory()) return false;
  const owner = readJsonOrNull(path.join(dir, ownerFileName));
  if (owner && processAlive(owner.pid)) return false;
  const claimed = `${dir}.reclaim.${process.pid}.${Date.now()}`;
  try { fs.renameSync(dir, claimed); } catch (_) { return false; }
  try { fs.rmSync(claimed, { recursive: true, force: true }); return true; } catch (_) { return false; }
}

// Liveness is kill-0 plus a zombie exclusion: a reaped-but-not-yet-waited
// process still answers kill-0 while `ps -o stat` reports Z.
function processAlive(pid) {
  if (!pid) return false;
  try {
    process.kill(Number(pid), 0);
    const stat = execFileSync("ps", ["-p", String(pid), "-o", "stat="], { encoding: "utf8" }).trim();
    return stat.length > 0 && stat.indexOf("Z") === -1;
  } catch (_) { return false; }
}

// JSON read with null fallback: a missing or malformed file is null, never a
// crash, so callers can treat "no readable record" as one code path.
function readJsonOrNull(file) {
  try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch (_) { return null; }
}

module.exports = {
  atomicTempPath,
  writeAtomic,
  writeAtomicJson,
  publishViaPendingDir,
  quarantineThenDelete,
  processAlive,
  readJsonOrNull
};
