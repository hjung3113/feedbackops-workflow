#!/usr/bin/env node
"use strict";

// Runtime-owned launch-spec contract. The argv array is deliberately carried
// as JSON rather than a shell command so transports can choose their own
// session launcher without re-parsing runtime policy.
const PROMPT_DELIVERIES = ["transport", "initial-argv"];
const LAUNCH_SPEC_KEYS = ["runtime", "cwd", "argv", "env", "prompt_delivery"];
const SHA256 = /^[a-f0-9]{64}$/;

function isPlainObject(value) {
  return !!value && typeof value === "object" && !Array.isArray(value);
}

function normalizeLaunchSpec(value, expectedRuntime) {
  if (!isPlainObject(value)
      || Object.keys(value).some((key) => !LAUNCH_SPEC_KEYS.includes(key))
      || (expectedRuntime && value.runtime !== expectedRuntime)
      || typeof value.runtime !== "string"
      || typeof value.cwd !== "string" || !value.cwd
      || !Array.isArray(value.argv) || value.argv.length < 1
      || value.argv.some((entry) => typeof entry !== "string")
      || !isPlainObject(value.env)
      || Object.keys(value.env).some((key) => !/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)
        || typeof value.env[key] !== "string")
      || !PROMPT_DELIVERIES.includes(value.prompt_delivery)) return null;
  return {
    runtime: value.runtime,
    cwd: value.cwd,
    argv: value.argv.slice(),
    env: { ...value.env },
    prompt_delivery: value.prompt_delivery,
  };
}

function emitLaunchSpec(runtime, cwd, promptDelivery, envJson, argv) {
  let env;
  try { env = JSON.parse(envJson); } catch (_) { return null; }
  return normalizeLaunchSpec({
    runtime,
    cwd,
    argv,
    env,
    prompt_delivery: promptDelivery,
  }, runtime);
}

if (require.main === module) {
  const [command, ...args] = process.argv.slice(2);
  if (command === "emit" && args.length >= 5) {
    const value = emitLaunchSpec(args[0], args[1], args[2], args[3], args.slice(4));
    if (!value) process.exit(2);
    process.stdout.write(`${JSON.stringify(value)}\n`);
  } else if (command === "validate" && (args.length === 1 || args.length === 2)) {
    const fs = require("fs");
    try {
      const value = JSON.parse(fs.readFileSync(args[0], "utf8"));
      const normalized = normalizeLaunchSpec(value, args[1]);
      if (!normalized) process.exit(2);
      process.stdout.write(`${JSON.stringify(normalized)}\n`);
    } catch (_) { process.exit(2); }
  } else {
    process.stderr.write("usage: launch-spec.cjs emit <runtime> <cwd> <prompt-delivery> <env-json> <argv...> | validate <file> [runtime]\n");
    process.exit(2);
  }
}

module.exports = { PROMPT_DELIVERIES, LAUNCH_SPEC_KEYS, normalizeLaunchSpec, emitLaunchSpec, SHA256 };
