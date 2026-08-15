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

function parseJson(raw) {
  return JSON.parse(raw);
}

function isPlainObject(value) {
  return !!value && typeof value === "object" && !Array.isArray(value);
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

if (require.main === module) {
  const [command, raw, expectedHandle] = process.argv.slice(2);
  try {
    if (command === "create") process.stdout.write(`${JSON.stringify(normalizeCreateResult(raw))}\n`);
    else if (command === "inspect" && expectedHandle) process.stdout.write(`${JSON.stringify(inspectWorkspaceHandle(raw, expectedHandle))}\n`);
    else process.exitCode = 2;
  } catch (_) {
    if (command === "inspect") {
      process.stdout.write(`${JSON.stringify({ lifecycle: "handle_unverifiable", reason: "cmux workspace list returned invalid JSON" })}\n`);
    } else process.exitCode = 2;
  }
}

module.exports = { collectWorkspaceHandles, inspectWorkspaceHandle, normalizeCreateResult };
