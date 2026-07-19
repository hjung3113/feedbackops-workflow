#!/usr/bin/env node
// Probe whether a sandboxed worker can open a TCP connection.
import fs from 'fs';
import net from 'net';
import process from 'process';

const host = process.argv[2];
const port = Number(process.argv[3]);
const outPath = process.argv[4];
let wrote = false;

function ensureParentDir(filePath) {
  const index = filePath.lastIndexOf('/');
  if (index === -1) return;
  const dir = index === 0 ? '/' : filePath.slice(0, index);
  fs.mkdirSync(dir, { recursive: true });
}

function finish(verdict, code) {
  if (wrote) return;
  wrote = true;
  ensureParentDir(outPath);
  fs.writeFileSync(outPath, verdict);
  process.exit(code);
}

const socket = net.connect(port, host);
socket.setTimeout(3000);

socket.on('connect', () => {
  socket.destroy();
  finish('CONNECTED\n', 0);
});

socket.on('error', (err) => {
  finish(`BLOCKED code=${err.code}\n`, 1);
});

socket.on('timeout', () => {
  socket.destroy();
  finish('BLOCKED timeout\n', 1);
});
