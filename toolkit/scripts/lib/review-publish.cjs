#!/usr/bin/env node
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");
const { publishSnapshot } = require("./review-snapshot.cjs");

const [source, reviewDir, issue, worktree, expectedHead] = process.argv.slice(2);
if (!source || !reviewDir || !issue || !worktree || !expectedHead) process.exit(2);
const canonical = path.join(reviewDir, `ISSUE-${issue}-REVIEW.json`);
const lock = path.join(reviewDir, `.ISSUE-${issue}-REVIEW-publish.lock`);
let canonicalTemp;
let canonicalPublished = false;
let priorCanonical;
let hadPriorCanonical = false;
let lockHeld = false;
const gitLocks = [];
const ownerName = ".agent-workflow-owner.json";
function processAlive(pid) {
  if (!pid) return false;
  try {
    process.kill(Number(pid), 0);
    const stat = execFileSync("ps", ["-p", String(pid), "-o", "stat="], { encoding: "utf8" }).trim();
    return stat.length > 0 && stat.indexOf("Z") === -1;
  } catch (_) { return false; }
}
function readOwner(dir) {
  try { return JSON.parse(fs.readFileSync(path.join(dir, ownerName), "utf8")); } catch (_) { return null; }
}
function removeOwnedDir(dir) {
  try { fs.rmSync(dir, { recursive: true, force: true }); return true; } catch (_) { return false; }
}
// Write ownership in an unobservable private directory, then atomically
// publish that directory as the lock. SIGKILL can leave only a non-blocking
// pending directory, never a visible ownerless lock from this protocol.
function acquireOwnedDir(dir, kind) {
  const pending = `${dir}.pending.${process.pid}.${Date.now()}`;
  try {
    fs.mkdirSync(pending, { mode: 0o700 });
    fs.writeFileSync(path.join(pending, ownerName), JSON.stringify({ version: 1, pid: process.pid, kind }) + "\n", { flag: "wx", mode: 0o600 });
    fs.renameSync(pending, dir);
    return true;
  } catch (error) {
    try { fs.rmSync(pending, { recursive: true, force: true }); } catch (_) {}
    // macOS reports a directory-over-directory rename collision as ENOTEMPTY
    // on some filesystems (Linux reports EEXIST). The target's existence is
    // the invariant that matters here.
    if (fs.existsSync(dir)) return false;
    throw error;
  }
}
function reclaimDeadOwnedDir(dir) {
  let stat;
  try { stat = fs.lstatSync(dir); } catch (_) { return true; }
  // Never modify a regular Git lock; it can be owned by Git. Workflow locks
  // are directories and all current writers put a pid in the owner record.
  if (!stat.isDirectory()) return false;
  const owner = readOwner(dir);
  if (owner && processAlive(owner.pid)) return false;
  // Atomically move the stale owner out of the contested name before removal.
  // A remove-then-create sequence admits a competing publisher in between.
  const claimed = `${dir}.reclaim.${process.pid}.${Date.now()}`;
  try { fs.renameSync(dir, claimed); } catch (_) { return false; }
  return removeOwnedDir(claimed);
}
function head() {
  return execFileSync("git", ["-C", worktree, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
}
function gitPath(name) {
  const raw = execFileSync("git", ["-C", worktree, "rev-parse", "--git-path", name], { encoding: "utf8" }).trim();
  return path.resolve(worktree, raw);
}
function acquireGitLocks() {
  const names = ["HEAD"];
  try { names.push(execFileSync("git", ["-C", worktree, "symbolic-ref", "-q", "HEAD"], { encoding: "utf8" }).trim()); } catch (_) {}
  const seen = {};
  for (const name of names) {
    if (!name || seen[name]) continue;
    seen[name] = true;
    const lockPath = `${gitPath(name)}.lock`;
    if (!acquireOwnedDir(lockPath, "git")) {
      if (!reclaimDeadOwnedDir(lockPath) || !acquireOwnedDir(lockPath, "git")) throw new Error("Git publication lock remained held");
    }
    gitLocks.push(lockPath);
  }
}
function releaseGitLocks() {
  while (gitLocks.length) removeOwnedDir(gitLocks.pop());
}
function acquirePublishLock() {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    if (acquireOwnedDir(lock, "review-publication")) return;
    // A dead publisher can leave its locks after SIGKILL. Reclaim only our
    // owner-bearing directory (or a legacy ownerless directory which current
    // writers cannot create), never a live owner's lock.
    if (reclaimDeadOwnedDir(lock) && acquireOwnedDir(lock, "review-publication")) return;
    try {
      // A codex-safe runner and its outer watchdog can both reach this seam.
      // Serialize those writers instead of turning a normal overlap into a
      // publication failure; the bounded wait still fails closed on a stale
      // lock rather than spinning forever.
      execFileSync("sleep", ["0.025"]);
    } catch (_) {}
  }
  throw new Error("review publication lock remained held");
}
try {
  fs.mkdirSync(reviewDir, { recursive: true });
  acquirePublishLock();
  lockHeld = true;
  // Git has no public long-lived lock API. Occupy the exact per-worktree
  // HEAD lock and the selected branch ref lock, which Git itself honors for
  // commits. This is linked-worktree-safe because --git-path HEAD resolves to
  // the worktree admin directory while branch refs resolve in the common dir.
  acquireGitLocks();
  if (head() !== expectedHead) throw new Error("review HEAD changed before publication");
  const content = fs.readFileSync(source);
  const artifact = JSON.parse(content.toString("utf8"));
  if (artifact.reviewed_head_sha !== expectedHead) throw new Error("review artifact HEAD mismatch");
  // Test-only synchronization seam: publication must continue using `content`
  // even if an untrusted runner rewrites its output path after validation.
  const readSentinel = process.env.REVIEW_PUBLISH_POST_READ_SENTINEL;
  if (readSentinel) fs.writeFileSync(readSentinel, "read\n", { flag: "wx", mode: 0o600 });
  const postReadDelay = Number(process.env.REVIEW_PUBLISH_POST_READ_DELAY || 0);
  if (Number.isFinite(postReadDelay) && postReadDelay > 0) execFileSync("sleep", [String(postReadDelay)]);
  hadPriorCanonical = fs.existsSync(canonical);
  if (hadPriorCanonical) priorCanonical = fs.readFileSync(canonical);
  const snapshot = path.join(reviewDir, `ISSUE-${issue}-REVIEW-${expectedHead}.json`);
  // Publish the snapshot from the exact bytes already parsed above. Do not
  // re-read the mutable runner output path between validation and publication.
  publishSnapshot(content, reviewDir, issue);
  canonicalTemp = `${canonical}.tmp.${process.pid}`;
  fs.writeFileSync(canonicalTemp, content, { flag: "wx", mode: 0o600 });
  // Keep the final check immediately adjacent to the linearization point.
  // Tests may widen this window to prove a concurrent commit is refused.
  const delay = Number(process.env.REVIEW_PUBLISH_PRE_RENAME_DELAY || 0);
  if (Number.isFinite(delay) && delay > 0) execFileSync("sleep", [String(delay)]);
  if (head() !== expectedHead) throw new Error("review HEAD changed during publication");
  fs.renameSync(canonicalTemp, canonical);
  canonicalTemp = undefined;
  canonicalPublished = true;
  // A commit can land in the tiny post-rename window. Restore the prior
  // canonical bytes atomically if that happens; never leave an artifact whose
  // reviewed HEAD is no longer the HEAD selected for this publication.
  if (head() !== expectedHead) throw new Error("review HEAD changed at publication linearization");
} catch (_) {
  try { if (canonicalTemp) fs.unlinkSync(canonicalTemp); } catch (_) {}
  if (canonicalPublished) {
    try {
      if (hadPriorCanonical) {
        const restore = `${canonical}.restore.${process.pid}`;
        fs.writeFileSync(restore, priorCanonical, { flag: "wx", mode: 0o600 });
        fs.renameSync(restore, canonical);
      } else {
        fs.unlinkSync(canonical);
      }
    } catch (_) {}
  }
  process.exitCode = 2;
} finally {
  releaseGitLocks();
  if (lockHeld) removeOwnedDir(lock);
}
