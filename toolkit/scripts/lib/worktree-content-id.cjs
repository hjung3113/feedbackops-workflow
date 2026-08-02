"use strict";

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

function git(root, args) {
  return execFileSync("git", ["-C", root].concat(args), { encoding: "utf8" });
}

function contentSha256(root) {
  const worktree = fs.realpathSync(root);
  const paths = git(worktree, ["ls-files", "--cached", "--others", "--exclude-standard", "-z"])
    .split("\0").filter(Boolean).filter((relative) => relative !== ".review" && !relative.startsWith(".review/"))
    .sort();
  const digest = crypto.createHash("sha256");
  for (const relative of paths) {
    if (path.isAbsolute(relative) || relative === ".." || relative.startsWith(`..${path.sep}`)) {
      throw new Error(`unsafe worktree path: ${relative}`);
    }
    const file = path.resolve(worktree, relative);
    if (file !== worktree && !file.startsWith(`${worktree}${path.sep}`)) throw new Error(`worktree path escapes root: ${relative}`);
    let stat;
    try { stat = fs.lstatSync(file); }
    catch (error) {
      if (error.code === "ENOENT") {
        continue;
      }
      throw error;
    }
    const mode = (stat.mode & 0o7777).toString(8);
    if (stat.isSymbolicLink()) {
      digest.update(`symlink\0${relative}\0${mode}\0${fs.readlinkSync(file)}\0`);
    } else if (stat.isFile()) {
      digest.update(`file\0${relative}\0${mode}\0`);
      digest.update(fs.readFileSync(file));
      digest.update("\0");
    } else {
      throw new Error(`unsupported worktree entry: ${relative}`);
    }
  }
  return digest.digest("hex");
}

module.exports = { contentSha256 };

if (require.main === module) {
  try { process.stdout.write(`${contentSha256(process.argv[2] || ".")}\n`); }
  catch (error) { console.error(`worktree-content-id: ${error.message}`); process.exitCode = 1; }
}
