#!/usr/bin/env node
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const [blocker, roundState, issue] = process.argv.slice(2);
if (!blocker || !roundState || !issue) process.exit(2);
try {
  const content = fs.readFileSync(blocker);
  const sha = crypto.createHash("sha256").update(content).digest("hex");
  const reviewDir = path.dirname(blocker);
  const rawName = `ISSUE-${issue}-BLOCKER-QUARANTINED-${sha}.json`;
  const rawPath = path.join(reviewDir, rawName);
  if (fs.existsSync(rawPath) && !fs.readFileSync(rawPath).equals(content)) process.exit(3);
  if (!fs.existsSync(rawPath)) {
    const temp = `${rawPath}.tmp.${process.pid}`;
    fs.writeFileSync(temp, content, { flag: "wx", mode: 0o600 });
    fs.renameSync(temp, rawPath);
  }
  const state = JSON.parse(fs.readFileSync(roundState, "utf8"));
  state.round_control = state.round_control || { failures: [] };
  state.round_control.blocker_recovery = {
    kind: "malformed_preexisting_blocker_quarantined",
    raw_path: `.review/${rawName}`,
    raw_sha256: sha,
    reason: "pre-existing worker BLOCKER failed canonical schema/identity/lifecycle validation; bytes retained without treating them as evidence",
    status: "ready"
  };
  if (!Number.isInteger(state.round_control.next_dispatch_ordinal)) {
    const highest = (state.round_control.failures || []).reduce((value, failure) => Math.max(value, failure.dispatch_ordinal || 0), 0);
    state.round_control.next_dispatch_ordinal = highest + 1;
  }
  const tempState = `${roundState}.tmp.${process.pid}`;
  fs.writeFileSync(tempState, JSON.stringify(state, null, 2) + "\n", { flag: "wx", mode: 0o600 });
  fs.renameSync(tempState, roundState);
  if (process.env.AGENT_WORKFLOW_BLOCKER_RECOVERY_CRASH_AFTER_STATE === "1") process.exit(99);
  // Canonical removal is last: a crash before this point leaves the malformed
  // worker file present alongside durable raw bytes and recovery metadata.
  fs.unlinkSync(blocker);
  process.stdout.write(JSON.stringify({ raw_path: `.review/${rawName}`, raw_sha256: sha }) + "\n");
} catch (error) {
  process.exit(2);
}
