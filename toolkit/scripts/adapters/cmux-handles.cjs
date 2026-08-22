#!/usr/bin/env node
"use strict";

// cmux documents workspace identity at exactly these response locations:
// the create-result envelope's own id/ref fields, the created `workspace`
// object's id fields, a `result` envelope's ref, and each `workspaces[]`
// entry's id/ref fields in `workspace list --json` output. A generic
// recursive walk over id-like keys is deliberately NOT performed: a nested
// request id or any other id-looking field elsewhere in the response must
// never be adopted as the workspace handle.
const WORKSPACE_ID_KEYS = ["id", "workspace_id", "workspaceId"];
const WORKSPACE_REF_KEYS = ["ref"];
const WORKSPACE_HANDLE_KEYS = WORKSPACE_ID_KEYS.concat(WORKSPACE_REF_KEYS);

// The low-level `cmux run --new-workspace ... --json -- <argv...>` envelope
// documents exactly three top-level live-session identities: `surface` (the
// PTY I/O surface), `workspace` (the lifecycle container), and `terminal_id`
// (the durable terminal/agent identity), plus `lifecycle:"running"|"exited"`.
// The same never-adopt-nested-ids discipline applies: only these documented
// top-level fields may become handles, never any other id-looking key.
const LIVE_RUN_KEYS = ["surface", "workspace", "terminal_id", "lifecycle"];

const fs = require("fs");
const path = require("path");
const { normalizeLaunchSpec } = require(path.join(__dirname, "..", "lib", "launch-spec.cjs"));

function parseJson(raw) {
  return JSON.parse(raw);
}

function isPlainObject(value) {
  return !!value && typeof value === "object" && !Array.isArray(value);
}

function isNonEmptyString(value) {
  return typeof value === "string" && value.length > 0;
}

function addObjectFields(handles, object, keys) {
  if (!isPlainObject(object)) return;
  for (const key of keys) {
    if (typeof object[key] === "string" && object[key]) handles.add(object[key]);
  }
}

function collectWorkspaceHandles(value) {
  const handles = new Set();
  if (!isPlainObject(value)) return handles;
  addObjectFields(handles, value, WORKSPACE_HANDLE_KEYS);
  addObjectFields(handles, value.workspace, WORKSPACE_ID_KEYS);
  addObjectFields(handles, value.result, WORKSPACE_REF_KEYS);
  return handles;
}

function normalizeCreateResult(raw) {
  const plainTextMatch = /^OK (workspace:[^\s]+)\s*$/.exec(raw);
  const handles = plainTextMatch
    ? new Set([plainTextMatch[1]])
    : collectWorkspaceHandles(parseJson(raw));
  if (handles.size !== 1) throw new Error("cmux create result must contain one unique workspace id/ref");
  return { external_handle: [...handles][0], lifecycle: "launched" };
}

function inspectWorkspaceHandle(raw, expectedHandle) {
  const value = parseJson(raw);
  // Match the same id-key set on each workspaces[] entry that create
  // normalization accepts, so a handle produced from any documented create
  // shape is found regardless of which key the list entry exposes.
  const present = isPlainObject(value) && Array.isArray(value.workspaces)
    && value.workspaces.some(workspace =>
      isPlainObject(workspace)
      && WORKSPACE_HANDLE_KEYS.some(key => workspace[key] === expectedHandle));
  return present
    ? { lifecycle: "live", reason: "external workspace handle is present" }
    : { lifecycle: "stale", reason: "external workspace handle is absent" };
}

// Live `run` envelope -> structured handles. workspace and surface are two
// different identities (lifecycle container vs PTY I/O surface) and must
// never be collapsed into one external_handle alias: downstream confusion
// between them is exactly what the structured tuple exists to prevent.
function normalizeLiveRunResult(raw) {
  const value = parseJson(raw);
  if (!isPlainObject(value)) throw new Error("cmux run envelope must be a JSON object");
  for (const key of LIVE_RUN_KEYS) {
    if (!Object.prototype.hasOwnProperty.call(value, key)) {
      throw new Error(`cmux run envelope is missing documented field ${key}`);
    }
  }
  if (value.lifecycle !== "running") {
    throw new Error(`cmux run child is not running (lifecycle=${String(value.lifecycle)})`);
  }
  for (const key of ["surface", "workspace", "terminal_id"]) {
    if (!isNonEmptyString(value[key])) {
      throw new Error(`cmux run envelope field ${key} is not a live handle string`);
    }
  }
  return {
    lifecycle: "launched",
    handles: {
      lifecycle: value.workspace,
      io: value.surface,
      agent: value.terminal_id,
    },
  };
}

// Read the supervisor-written session.json and expose the cmux-domain
// identities for adapter subcommands. The file is only trusted when it
// declares execution_mode live-tui and carries the full structured tuple.
function liveSessionHandles(sessionFile) {
  const value = parseJson(fs.readFileSync(sessionFile, "utf8"));
  if (!isPlainObject(value) || value.execution_mode !== "live-tui") {
    throw new Error("session json is not a live-tui session");
  }
  const handles = value.handles;
  if (!isPlainObject(handles)
    || !isNonEmptyString(handles.lifecycle)
    || !isNonEmptyString(handles.io)
    || !isNonEmptyString(handles.agent)) {
    throw new Error("session json lacks the structured live handles tuple");
  }
  return { workspace: handles.lifecycle, surface: handles.io, agent: handles.agent };
}

// POSIX single-quoting for the one place a JSON argv array must cross into
// a shell command line: every token is emitted fully single-quoted (the
// only special sequence `'` becomes `'\''`), so spaces, quotes, newlines,
// and shell metacharacters survive byte-exactly. The adapter evals only
// this generated string; spec-derived values never undergo unquoted
// expansion.
function shellQuote(token) {
  return `'${String(token).replace(/'/g, "'\\''")}'`;
}

// Build the `cmux run` argument tail from a launch-spec. Refuses specs the
// documented run contract cannot deliver faithfully: prompt_delivery must
// be transport (an initial-argv prompt plus a later send would duplicate
// the turn), and env must be empty (the run envelope documents no env
// delivery, so a non-empty env must fail closed rather than drop silently).
function runLaunchArgs(specFile, name) {
  const spec = normalizeLaunchSpec(parseJson(fs.readFileSync(specFile, "utf8")), null);
  if (!spec) throw new Error("launch spec is invalid");
  if (spec.prompt_delivery !== "transport") {
    throw new Error("cmux live requires prompt_delivery transport");
  }
  if (Object.keys(spec.env).length > 0) {
    throw new Error("cmux run envelope documents no env delivery; refusing spec with env");
  }
  if (!isNonEmptyString(name)) throw new Error("session name is required");
  const tail = ["--cwd", shellQuote(spec.cwd), "--name", shellQuote(name), "--json", "--"]
    .concat(spec.argv.map(shellQuote));
  return tail.join(" ");
}

function fileBase64(file) {
  return fs.readFileSync(file).toString("base64");
}

if (require.main === module) {
  const [command, raw, expectedHandle] = process.argv.slice(2);
  try {
    if (command === "create") process.stdout.write(`${JSON.stringify(normalizeCreateResult(raw))}\n`);
    else if (command === "inspect" && expectedHandle) process.stdout.write(`${JSON.stringify(inspectWorkspaceHandle(raw, expectedHandle))}\n`);
    else if (command === "live-run") process.stdout.write(`${JSON.stringify(normalizeLiveRunResult(raw))}\n`);
    else if (command === "live-session" && raw) process.stdout.write(`${JSON.stringify(liveSessionHandles(raw))}\n`);
    else if (command === "run-argv" && raw && expectedHandle) process.stdout.write(`${runLaunchArgs(raw, expectedHandle)}\n`);
    else if (command === "base64" && raw) process.stdout.write(`${fileBase64(raw)}\n`);
    else process.exitCode = 2;
  } catch (error) {
    if (command === "inspect") {
      process.stdout.write(`${JSON.stringify({ lifecycle: "handle_unverifiable", reason: "cmux workspace list returned invalid JSON" })}\n`);
    } else if (command === "live-run" || command === "live-session" || command === "run-argv") {
      process.stderr.write(`ERROR: cmux live handles: ${error.message}\n`);
      process.exitCode = 3;
    } else process.exitCode = 2;
  }
}

module.exports = {
  collectWorkspaceHandles,
  inspectWorkspaceHandle,
  normalizeCreateResult,
  normalizeLiveRunResult,
  liveSessionHandles,
  runLaunchArgs,
  shellQuote,
  fileBase64,
};
