#!/usr/bin/env node
// Sandbox-side UDS Postgres reachability probe.
import net from "net";
import process from "process";

const socketPath = process.argv[2] || process.env.UDS_PATH || ".review/pg.sock";
const timeoutMs = 4000;
let done = false;

const failReason = (error) => {
  if (error === "timeout") return "ETIMEDOUT no response";
  if (error === "no-data") return "no data";
  if (error?.code === "ENOENT") return "ENOENT socket missing";
  if (error?.code === "EACCES" || error?.code === "EPERM") return `${error.code} sandbox blocked connect`;
  if (error?.code === "ECONNREFUSED") return "ECONNREFUSED relay down";
  if (error?.code === "ETIMEDOUT") return "ETIMEDOUT no response";
  return error?.message || String(error);
};

const finish = (ok, text) => {
  if (done) return;
  done = true;
  clearTimeout(timer);
  socket.destroy();
  console.log(ok ? `UDS-PROBE-OK byte=${text}` : `UDS-PROBE-FAIL reason=${text}`);
  process.exit(ok ? 0 : 1);
};

const packet = Buffer.alloc(8);
packet.writeInt32BE(8, 0);
packet.writeInt32BE(80877103, 4);

const socket = net.connect(socketPath, () => {
  socket.write(packet);
});

const timer = setTimeout(() => finish(false, failReason("timeout")), timeoutMs);

socket.once("data", (chunk) => {
  if (!chunk.length) finish(false, failReason("no-data"));
  else finish(true, String.fromCharCode(chunk[0]));
});

socket.once("error", (error) => finish(false, failReason(error)));
socket.once("close", () => finish(false, failReason("no-data")));
