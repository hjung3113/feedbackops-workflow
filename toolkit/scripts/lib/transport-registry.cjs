#!/usr/bin/env node
"use strict";
const ADAPTERS = ["cmux", "orca", "herdr"];
const LIVE_CAPABILITIES = [
  "session.live.launch",
  "session.ready.wait",
  "session.input.send",
  "session.output.read",
  "session.activity.observe",
  "session.state.wait",
  "session.interrupt",
  "session.close",
];
const LIVE_SUBCOMMANDS = [
  "launch-live",
  "wait-ready",
  "send",
  "read",
  "wait-settled",
  "interrupt",
  "close",
  "inspect",
];
const LIVE_SETTLED_STATES = ["settled", "working", "blocked", "stale", "terminal"];
const PROMPT_DELIVERIES = ["transport", "initial-argv"];

module.exports = { ADAPTERS, LIVE_CAPABILITIES, LIVE_SUBCOMMANDS, LIVE_SETTLED_STATES, PROMPT_DELIVERIES };
if (require.main === module) {
  const format = process.argv[2] || "lines";
  if (format === "pipe") process.stdout.write(ADAPTERS.join("|") + "\n");
  else if (format === "live-capabilities") process.stdout.write(LIVE_CAPABILITIES.join("\n") + "\n");
  else if (format === "live-subcommands") process.stdout.write(LIVE_SUBCOMMANDS.join("\n") + "\n");
  else if (format === "live-settled-states") process.stdout.write(LIVE_SETTLED_STATES.join("\n") + "\n");
  else if (format === "prompt-deliveries") process.stdout.write(PROMPT_DELIVERIES.join("\n") + "\n");
  else process.stdout.write(ADAPTERS.join("\n") + "\n");
}
