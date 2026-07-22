#!/usr/bin/env node
const fs = require("fs");
const { execFileSync } = require("child_process");
const [artifactFile, schemaFile, validatorFile, issueNumber, worktree] = process.argv.slice(2);
if (!artifactFile || !schemaFile || !validatorFile || !issueNumber || !worktree) process.exit(2);
try {
  const artifact = JSON.parse(fs.readFileSync(artifactFile, "utf8"));
  const schema = JSON.parse(fs.readFileSync(schemaFile, "utf8"));
  const { validate } = require(validatorFile);
  if (validate(schema, artifact).length) throw new Error("schema_invalid");
  if (!artifact.issue || Number(artifact.issue.number) !== Number(issueNumber)) throw new Error("issue_mismatch");
  const liveHead = execFileSync("git", ["-C", worktree, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
  if (artifact.head_sha !== liveHead) throw new Error("head_stale");
  if (artifact.lifecycle !== "active" && artifact.lifecycle !== "final") throw new Error("lifecycle_not_consumable");
  process.stdout.write("ok");
} catch (error) {
  process.stderr.write(`${error.message || "invalid_blocker"}\n`);
  process.exit(1);
}
