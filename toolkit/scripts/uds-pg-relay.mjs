#!/usr/bin/env node
// Host-side UDS-to-TCP Postgres relay.
import fs from "fs";
import net from "net";
import process from "process";

const socketPath = process.argv[2] || process.env.UDS_PATH || ".review/pg.sock";
const host = process.env.PG_HOST || "127.0.0.1";
const port = Number(process.env.PG_PORT || "5434");
const absPath = fs.realpathSync(process.cwd()) + "/" + socketPath;

try {
  fs.unlinkSync(socketPath);
} catch (error) {
  if (error?.code !== "ENOENT") throw error;
}

const server = net.createServer((client) => {
  console.log("relay: conn open");
  const upstream = net.connect({ host, port });
  let closed = false;

  const closeBoth = () => {
    if (!closed) {
      closed = true;
      console.log("relay: conn close");
    }
    client.destroy();
    upstream.destroy();
  };

  client.pipe(upstream);
  upstream.pipe(client);
  client.on("error", closeBoth);
  upstream.on("error", closeBoth);
  client.on("close", closeBoth);
  upstream.on("close", closeBoth);
});

const shutdown = () => {
  server.close(() => {
    try {
      fs.unlinkSync(socketPath);
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
    process.exit(0);
  });
};

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);

server.listen(socketPath, () => {
  console.log(`relay: listening on ${absPath} -> ${host}:${port}`);
});
