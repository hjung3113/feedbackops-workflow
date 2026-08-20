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

// Workspace naming: whether the runtime keeps the historical short
// workspace name (`<runtime>-<issue>`) for implementation dispatches
// instead of the general `<runtime>-<role>-<issue>` shape (#174).
const WS_SHORT_IMPL = {
  codex: true,
  claude: false,
  opencode: false,
};

// Default effort for a model-specific preflight when the caller supplies a
// model but omits an effort. This is runtime-axis data, not a core branch.
const EFFORT_DEFAULT = {
  codex: "low",
  claude: "medium",
  opencode: "medium",
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
    subcommand_help_tokens: ["--sandbox", "--cd", "--model", "--config", "--output-last-message", "--json"],
  },
  claude: {
    help_tokens: ["--print", "--permission-mode", "--output-format", "--model", "--effort", "--include-partial-messages"],
    subcommand: "",
    subcommand_help_tokens: [],
  },
  opencode: {
    help_tokens: [],
    subcommand: "run",
    subcommand_help_tokens: ["--dir", "--format", "--agent", "--model", "--variant", "json"],
  },
};

// Progress-event contract: flags switch the runtime into NDJSON event output
// on the named stream; final.match (every [dotted-path, equals-value] pair
// must hold) locates the terminal event and final.text_path extracts its
// text. Consumers resolve dotted paths by splitting on ".". `streams` is the
// explicit, separately-tracked fact that agent-runtime.sh's launch for this
// runtime actually applies `flags` right now — a populated flags/final shape
// alone does not mean the runtime is currently launched streaming (codex
// keeps this false: its launch argv is unwired follow-up scope; opencode is
// wired since #155).
// Consumers that decide whether to parse $OUTPUT as NDJSON must gate on
// `streams`, never on `event_format` alone.
const PROGRESS = {
  claude: {
    flags: ["--output-format", "stream-json", "--verbose", "--include-partial-messages"],
    event_format: "ndjson",
    stream: "stdout",
    streams: true,
    final: { match: [["type", "result"], ["subtype", "success"]], text_path: "result" },
  },
  codex: {
    flags: ["--json"],
    event_format: "ndjson",
    stream: "stdout",
    streams: false,
    final: { match: [["type", "item.completed"], ["item.type", "agent_message"]], text_path: "item.text" },
  },
  opencode: {
    flags: ["--format", "json"],
    event_format: "ndjson",
    stream: "stdout",
    streams: true,
    final: { match: [["type", "text"]], text_path: "part.text" },
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

module.exports = { RUNTIMES, STASH_BY, WS_SHORT_IMPL, EFFORT_DEFAULT, BIN, PROBE, PROGRESS, MODEL_FAMILY_REGEX, EFFORT_ENUMS, effortValid };

if (require.main === module) {
  const command = process.argv[2] || "lines";
  const write = value => process.stdout.write(`${value}\n`);
  const registered = name => {
    if (!RUNTIMES.includes(name)) process.exit(1);
    return name;
  };
  const pathGet = (value, dotted) =>
    dotted.split(".").reduce((node, key) => (node && typeof node === "object" ? node[key] : undefined), value);
  switch (command) {
    case "lines": RUNTIMES.forEach(write); break;
    case "default-runtime": write(RUNTIMES[0]); break;
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
    case "ws-short-impl": write(WS_SHORT_IMPL[registered(process.argv[3])] ? "true" : "false"); break;
    case "effort-default": write(EFFORT_DEFAULT[registered(process.argv[3])]); break;
    case "effort-valid": process.exit(effortValid(process.argv[3], process.argv[4]) ? 0 : 1); break;
    case "progress-flags": PROGRESS[registered(process.argv[3])].flags.forEach(write); break;
    case "progress-stream": write(PROGRESS[registered(process.argv[3])].stream); break;
    case "extract-final": {
      const name = registered(process.argv[3]);
      const filePath = process.argv[4];
      if (!filePath) { process.stderr.write("usage: runtime-registry.cjs extract-final <runtime> <ndjson-file>\n"); process.exit(2); }
      const spec = PROGRESS[name].final;
      let raw = null;
      try { raw = require("fs").readFileSync(filePath, "utf8"); } catch (err) { process.stderr.write(`extract-final: cannot read ${filePath}: ${err.code || err.message}\n`); process.exit(3); }
      const lines = raw.split("\n");
      let finalText;
      for (const line of lines) {
        const trimmed = line.trim();
        if (!trimmed) continue;
        let event = null;
        try { event = JSON.parse(trimmed); } catch (err) { event = null; }
        if (event && spec.match.every(([dotted, expected]) => pathGet(event, dotted) === expected)) {
          const text = pathGet(event, spec.text_path);
          if (typeof text === "string") finalText = text;
        }
      }
      if (finalText !== undefined) { write(finalText); }
      process.exit(finalText !== undefined ? 0 : 1);
      break;
    }
    default:
      process.stderr.write("usage: runtime-registry.cjs [lines|default-runtime|pipe] | is-registered <runtime> | bin <runtime> | probe-help-tokens <runtime> | probe-subcommand <runtime> | probe-subcommand-help-tokens <runtime> | stash-by <runtime> | ws-short-impl <runtime> | effort-default <runtime> | effort-valid <model> <effort> | progress-flags <runtime> | progress-stream <runtime> | extract-final <runtime> <ndjson-file>\n");
      process.exit(2);
  }
}
