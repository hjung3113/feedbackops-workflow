#!/usr/bin/env node
"use strict";

const HANDLE_KEYS = ["id", "workspace_id", "workspaceId", "ref"];

function parseJson(raw) {
  return JSON.parse(raw);
}

function collectWorkspaceHandles(value) {
  const handles = new Set();
  const visit = (item) => {
    if (!item || typeof item !== "object") return;
    if (Array.isArray(item)) {
      item.forEach(visit);
      return;
    }
    for (const key of HANDLE_KEYS) {
      if (typeof item[key] === "string" && item[key]) handles.add(item[key]);
    }
    Object.values(item).forEach(visit);
  };
  visit(value);
  return handles;
}

function normalizeCreateResult(raw) {
  const handles = collectWorkspaceHandles(parseJson(raw));
  if (handles.size !== 1) throw new Error("cmux create result must contain one unique workspace id/ref");
  return { external_handle: [...handles][0], lifecycle: "launched" };
}

function inspectWorkspaceHandle(raw, expectedHandle) {
  const handles = collectWorkspaceHandles(parseJson(raw));
  return handles.has(expectedHandle)
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
