#!/usr/bin/env node
"use strict";
// Runtime-axis registry — the declarative twin of transport-registry.cjs.
// Single source of truth for the admitted runtime set and the per-runtime
// facts call sites used to re-hardcode: pinned-binary resolution, the
// capability-probe help-token contract, stash ownership (stash_by), and the
// model-family effort-enum sub-dimension of the runtime axis. Bash consumers
// read it through the CLI below; Node consumers require() the exports.
const RUNTIMES = ["codex", "claude", "opencode"];

// Who stashes partial write work on a stall or crash: "runtime" means the
// runtime's own wrapper (codex-safe.sh) already stashes; "watchdog" means
// agent-watchdog.sh must call workflow-stash.sh itself.
const STASH_BY = {
  codex: "runtime",
  claude: "watchdog",
  opencode: "watchdog",
};

// Pinned-binary resolution: dispatch-core may pin one absolute,
// capability-proved executable through the env var; otherwise the runtime's
// default command name resolves from PATH.
const BIN = {
  codex: { env: "AGENT_WORKFLOW_CODEX_BIN", default: "codex" },
  claude: { env: "AGENT_WORKFLOW_CLAUDE_BIN", default: "claude" },
  opencode: { env: "AGENT_WORKFLOW_OPENCODE_BIN", default: "opencode" },
};

// Capability-probe contract: the top-level --help output must contain every
// help_tokens entry; when subcommand is non-empty, `<bin> <subcommand> --help`
// must contain every subcommand_help_tokens entry. Entries are checked in
// array order and the first missing token fails the probe.
const PROBE = {
  codex: {
    help_tokens: ["exec"],
    subcommand: "exec",
    subcommand_help_tokens: ["--sandbox", "--cd", "--model", "--config", "--output-last-message"],
  },
  claude: {
    help_tokens: ["--print", "--permission-mode", "--output-format", "--model", "--effort"],
    subcommand: "",
    subcommand_help_tokens: [],
  },
  opencode: {
    help_tokens: [],
    subcommand: "run",
    subcommand_help_tokens: ["--dir", "--format", "--agent", "--model", "--variant"],
  },
};

// Model-family sub-dimension of the runtime axis (not a fourth axis): the
// gpt-5[.-]6 family selects the extended effort enum; every other model
// selects the base enum. The regex and both enums are unchanged from their
// earlier inline owners in dispatch-core.sh.
const MODEL_FAMILY_REGEX = /^gpt-5[.-]6(?:-|$)/;
const EFFORT_ENUMS = {
  extended: ["none", "low", "medium", "high", "xhigh", "max"],
  base: ["low", "medium", "high"],
};
const effortPattern = enumValues => new RegExp(`^(?:${enumValues.join("|")})$`);
function effortValid(model, effort) {
  const family = MODEL_FAMILY_REGEX.test(model) ? EFFORT_ENUMS.extended : EFFORT_ENUMS.base;
  return effortPattern(family).test(effort);
}

module.exports = { RUNTIMES, STASH_BY, BIN, PROBE, MODEL_FAMILY_REGEX, EFFORT_ENUMS, effortValid };

if (require.main === module) {
  const command = process.argv[2] || "lines";
  const write = value => process.stdout.write(`${value}\n`);
  const registered = name => {
    if (!RUNTIMES.includes(name)) process.exit(1);
    return name;
  };
  switch (command) {
    case "lines": RUNTIMES.forEach(write); break;
    case "pipe": write(RUNTIMES.join("|")); break;
    case "is-registered": process.exit(registered(process.argv[3]) ? 0 : 1); break;
    case "bin": {
      const name = registered(process.argv[3]);
      write(process.env[BIN[name].env] || BIN[name].default);
      break;
    }
    case "probe-help-tokens": PROBE[registered(process.argv[3])].help_tokens.forEach(write); break;
    case "probe-subcommand": write(PROBE[registered(process.argv[3])].subcommand); break;
    case "probe-subcommand-help-tokens": PROBE[registered(process.argv[3])].subcommand_help_tokens.forEach(write); break;
    case "stash-by": write(STASH_BY[registered(process.argv[3])]); break;
    case "effort-valid": process.exit(effortValid(process.argv[3], process.argv[4]) ? 0 : 1); break;
    default:
      process.stderr.write("usage: runtime-registry.cjs [lines|pipe] | is-registered <runtime> | bin <runtime> | probe-help-tokens <runtime> | probe-subcommand <runtime> | probe-subcommand-help-tokens <runtime> | stash-by <runtime> | effort-valid <model> <effort>\n");
      process.exit(2);
  }
}
