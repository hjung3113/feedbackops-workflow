#!/usr/bin/env node
"use strict";
const ADAPTERS = ["cmux", "orca", "herdr"];
module.exports = { ADAPTERS };
if (require.main === module) {
  const format = process.argv[2] || "lines";
  if (format === "pipe") process.stdout.write(ADAPTERS.join("|") + "\n");
  else process.stdout.write(ADAPTERS.join("\n") + "\n");
}
