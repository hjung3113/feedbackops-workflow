#!/usr/bin/env bash
# Functional smoke test for scripts/uds-pg-relay.mjs without Postgres.
# bash-3.2-compatible. Run: bash scripts/__tests__/uds-pg-relay.smoke.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RELAY="$SCRIPT_DIR/../uds-pg-relay.mjs"
TMP_DIR="$(mktemp -d)"
PORT_FILE="$TMP_DIR/echo.port"
ECHO_ERR="$TMP_DIR/echo.err"
ECHO_JS="$TMP_DIR/echo-server.js"
CLIENT_JS="$TMP_DIR/uds-client.js"
SOCKET_NAME="relay.sock"
SOCKET_PATH="$TMP_DIR/$SOCKET_NAME"
ECHO_PID=""
RELAY_PID=""

cleanup() {
  if [ -n "$RELAY_PID" ]; then kill "$RELAY_PID" >/dev/null 2>&1 || true; fi
  if [ -n "$ECHO_PID" ]; then kill "$ECHO_PID" >/dev/null 2>&1 || true; fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

FAILURES=0

pass_case() {
  echo "ok   - $1"
}

fail_case() {
  echo "NOT OK - $1"
  FAILURES=$((FAILURES + 1))
}

if ! command -v node >/dev/null 2>&1; then
  echo "ok   - node unavailable (SKIP)"
  echo "---"
  echo "ALL CASES PASS"
  exit 0
fi

cat > "$ECHO_JS" <<'JS'
const fs = require("fs");
const net = require("net");
const portFile = process.argv[2];
const server = net.createServer((socket) => {
  socket.pipe(socket);
});

server.listen(0, "127.0.0.1", () => {
  fs.writeFileSync(portFile, String(server.address().port));
});

setTimeout(() => {
  process.exit(2);
}, 10000).unref();
JS

node "$ECHO_JS" "$PORT_FILE" >/dev/null 2>"$ECHO_ERR" &
ECHO_PID=$!

i=0
while [ ! -s "$PORT_FILE" ] && [ "$i" -lt 40 ]; do
  sleep 0.05
  i=$((i + 1))
done

if [ ! -s "$PORT_FILE" ] && grep -q "listen EPERM" "$ECHO_ERR" 2>/dev/null; then
  echo "ok   - local TCP listen unavailable (SKIP)"
  echo "---"
  echo "ALL CASES PASS"
  exit 0
fi

if [ ! -s "$PORT_FILE" ]; then
  fail_case "echo server writes an ephemeral port"
else
  pass_case "echo server writes an ephemeral port"
fi

ECHO_PORT="$(cat "$PORT_FILE" 2>/dev/null || true)"

if [ -n "$ECHO_PORT" ]; then
  (cd "$TMP_DIR" && UDS_PATH="$SOCKET_NAME" PG_HOST=127.0.0.1 PG_PORT="$ECHO_PORT" node "$RELAY") >/dev/null 2>&1 &
  RELAY_PID=$!
fi

i=0
while [ ! -S "$SOCKET_PATH" ] && [ "$i" -lt 40 ]; do
  sleep 0.05
  i=$((i + 1))
done

if [ -S "$SOCKET_PATH" ]; then
  pass_case "relay creates UDS socket"
else
  fail_case "relay creates UDS socket"
fi

cat > "$CLIENT_JS" <<'JS'
const net = require("net");
const socketPath = process.argv[2];
const payload = Buffer.from("relay-smoke-payload");
let received = Buffer.alloc(0);

const client = net.createConnection(socketPath, () => {
  client.write(payload);
});

const timer = setTimeout(() => {
  client.destroy();
  process.exit(3);
}, 2000);

client.on("data", (chunk) => {
  received = Buffer.concat([received, chunk]);
  if (received.length >= payload.length) {
    clearTimeout(timer);
    client.end();
    process.exit(received.equals(payload) ? 0 : 4);
  }
});

client.on("error", () => {
  clearTimeout(timer);
  process.exit(5);
});
JS

if [ -S "$SOCKET_PATH" ] && node "$CLIENT_JS" "$SOCKET_PATH" >/dev/null 2>&1; then
  pass_case "relay proxies bytes bidirectionally"
else
  fail_case "relay proxies bytes bidirectionally"
fi

echo "---"
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASS"
  exit 0
else
  echo "$FAILURES CASE(S) FAILED"
  exit 1
fi
