#!/usr/bin/env node
const fs = require("fs");
const path = require("path");

function publishSnapshot(content, reviewDir, issue) {
  if (!Buffer.isBuffer(content) || !reviewDir || !issue) throw new Error("invalid snapshot input");
  let temp;
  try {
  const artifact = JSON.parse(content.toString("utf8"));
  if (!artifact.reviewed_head_sha || !/^[0-9a-f]{40}$/.test(artifact.reviewed_head_sha)) throw new Error("invalid reviewed head");
  const destination = path.join(reviewDir, `ISSUE-${issue}-REVIEW-${artifact.reviewed_head_sha}.json`);
  if (fs.existsSync(destination)) {
    const existing = fs.readFileSync(destination);
    if (!existing.equals(content)) {
      const error = new Error("conflicting snapshot");
      error.code = "SNAPSHOT_CONFLICT";
      throw error;
    }
    return destination;
  }
  temp = `${destination}.tmp.${process.pid}`;
  fs.writeFileSync(temp, content, { flag: "wx", mode: 0o600 });
  try {
    fs.linkSync(temp, destination);
  } catch (error) {
    if (error.code !== "EEXIST") throw error;
    const existing = fs.readFileSync(destination);
    if (!existing.equals(content)) {
      fs.unlinkSync(temp);
      temp = undefined;
      const conflict = new Error("conflicting snapshot");
      conflict.code = "SNAPSHOT_CONFLICT";
      throw conflict;
    }
  }
  fs.unlinkSync(temp);
  return destination;
  } catch (error) {
    try { if (typeof temp === "string") fs.unlinkSync(temp); } catch (_) {}
    throw error;
  }
}

module.exports = { publishSnapshot };

if (require.main === module) {
  const [source, reviewDir, issue] = process.argv.slice(2);
  if (!source || !reviewDir || !issue) process.exit(2);
  try {
    process.stdout.write(publishSnapshot(fs.readFileSync(source), reviewDir, issue) + "\n");
  } catch (error) {
    process.exit(error && error.code === "SNAPSHOT_CONFLICT" ? 3 : 2);
  }
}
