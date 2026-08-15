#!/usr/bin/env bash
# AC-128A-4 coverage for lib/atomic-fs.cjs: normal write, resume after an
# interrupted attempt, and concurrent writers. bash-3.2-compatible.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$SCRIPT_DIR/../lib/atomic-fs.cjs"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0

pass() { echo "ok   - $1"; }
fail() { echo "NOT OK - $1"; FAIL=$((FAIL + 1)); }

# AC-128A-1: normal write lands exact bytes with 0o600 and no temp leftover.
if node - "$LIB" "$TMP/normal" <<'NODE'
const fs = require("fs");
const [lib, out] = process.argv.slice(2);
const atomic = require(lib);
atomic.writeAtomic(out, "payload\n");
process.exit(fs.readFileSync(out, "utf8") === "payload\n"
  && (fs.statSync(out).mode & 0o777) === 0o600
  && !fs.existsSync(atomic.atomicTempPath(out)) ? 0 : 1);
NODE
then
  pass "AC-128A-1 writeAtomic normal write: bytes, 0o600, no temp leftover"
else
  fail "AC-128A-1 writeAtomic normal write mismatch"
fi

# AC-128A-1: JSON serialization keeps both historical byte forms.
if node - "$LIB" "$TMP/state.json" <<'NODE'
const fs = require("fs");
const [lib, out] = process.argv.slice(2);
const atomic = require(lib);
atomic.writeAtomicJson(out, { b: 1, a: "x" });
const compact = fs.readFileSync(out, "utf8");
atomic.writeAtomicJson(out, { b: 1, a: "x" }, 2);
const pretty = fs.readFileSync(out, "utf8");
process.exit(compact === '{"b":1,"a":"x"}\n' && pretty === '{\n  "b": 1,\n  "a": "x"\n}\n' ? 0 : 1);
NODE
then
  pass "AC-128A-1 writeAtomicJson compact and indented byte forms"
else
  fail "AC-128A-1 writeAtomicJson serialization mismatch"
fi

# AC-128A-4: resume after an interrupted attempt — a dead writer's temp file
# must not block a new writer, a failed pending publish must leave nothing
# visible, and a dead-owned directory must be reclaimable and re-publishable.
if node - "$LIB" "$TMP/resume" <<'NODE'
const fs = require("fs");
const path = require("path");
const [lib, root] = process.argv.slice(2);
const atomic = require(lib);
fs.mkdirSync(root);
const target = path.join(root, "state.json");
// A crashed writer (pid 999999) left its temp behind.
fs.writeFileSync(`${target}.tmp.999999`, "garbage", { flag: "wx", mode: 0o600 });
atomic.writeAtomicJson(target, { resumed: true }, 2);
if (JSON.parse(fs.readFileSync(target, "utf8")).resumed !== true) process.exit(1);
if (!fs.existsSync(`${target}.tmp.999999`)) process.exit(2); // stale temp is not ours to touch
// An interrupted publish: prepare fails, so nothing becomes visible.
const dir = path.join(root, "issue-9-dispatch-1");
let threw = false;
try { atomic.publishViaPendingDir(dir, () => { throw new Error("interrupted"); }); }
catch (_) { threw = true; }
if (!threw || fs.existsSync(dir)) process.exit(3);
const leftovers = fs.readdirSync(root).filter(name => name.indexOf(".pending.") !== -1);
if (leftovers.length !== 0) process.exit(4);
// The stale owner is dead; reclaim its directory, then publish over the name.
const deadDir = path.join(root, "issue-9-dispatch-2");
fs.mkdirSync(deadDir, { mode: 0o700 });
fs.writeFileSync(path.join(deadDir, ".agent-workflow-owner.json"),
  JSON.stringify({ version: 1, pid: 999999, status: "locked" }) + "\n", { flag: "wx", mode: 0o600 });
if (!atomic.quarantineThenDelete(deadDir)) process.exit(5);
atomic.publishViaPendingDir(deadDir, pending => {
  fs.writeFileSync(path.join(pending, "tx.json"), "{}\n", { flag: "wx", mode: 0o600 });
});
if (!fs.existsSync(path.join(deadDir, "tx.json"))) process.exit(6);
process.exit(0);
NODE
then
  pass "AC-128A-4 resume after interrupt: stale temp, aborted publish, dead-owner reclaim"
else
  fail "AC-128A-4 resume-after-interrupt behavior mismatch"
fi

# AC-128A-4: concurrent writers — per-pid temps make both writers succeed and
# the last rename wins with a fully-written file.
mkdir -p "$TMP/concurrent"
DRIVER="$TMP/concurrent-writer.js"
cat > "$DRIVER" <<'NODE'
const atomic = require(process.argv[2]);
atomic.writeAtomicJson(process.argv[3], { w: process.argv[4] === "a" ? 1 : 2 });
NODE
node "$DRIVER" "$LIB" "$TMP/concurrent/state.json" a > /dev/null 2>&1 &
A_PID=$!
node "$DRIVER" "$LIB" "$TMP/concurrent/state.json" b > /dev/null 2>&1 &
B_PID=$!
CONCURRENT_EC=0
wait "$A_PID" || CONCURRENT_EC=1
wait "$B_PID" || CONCURRENT_EC=1
if [ "$CONCURRENT_EC" -ne 0 ]; then
  fail "AC-128A-4 concurrent writers did not both succeed"
else
  if node - "$LIB" "$TMP/concurrent/state.json" <<'NODE'
const fs = require("fs");
const [lib, out] = process.argv.slice(2);
const atomic = require(lib);
const raw = fs.readFileSync(out, "utf8");
const value = JSON.parse(raw);
const temps = fs.readdirSync(require("path").dirname(out))
  .filter(name => name.indexOf(".tmp.") !== -1);
process.exit((value.w === 1 || value.w === 2) && (fs.statSync(out).mode & 0o777) === 0o600
  && temps.length === 0 ? 0 : 1);
NODE
  then
    pass "AC-128A-4 concurrent writers: both succeed, last rename wins, no temp leftovers"
  else
    fail "AC-128A-4 concurrent-write outcome invalid"
  fi
fi

# AC-128A-1: liveness and read fallbacks.
if node - "$LIB" <<'NODE'
const fs = require("fs");
const path = require("path");
const [lib] = process.argv.slice(2);
const atomic = require(lib);
const os = require("os");
if (!atomic.processAlive(process.pid)) process.exit(1);
if (atomic.processAlive(0)) process.exit(2);
if (atomic.processAlive(999999999)) process.exit(3);
const dir = fs.mkdtempSync(path.join(os.tmpdir(), "atomic-fs-smoke-"));
const file = path.join(dir, "x.json");
fs.writeFileSync(file, "{ not json", { mode: 0o600 });
if (atomic.readJsonOrNull(file) !== null) process.exit(5);
if (atomic.readJsonOrNull(path.join(dir, "missing.json")) !== null) process.exit(6);
if (atomic.readJsonOrNull(file) !== null) process.exit(7);
fs.rmSync(dir, { recursive: true, force: true });
process.exit(0);
NODE
then
  pass "AC-128A-1 processAlive and readJsonOrNull behavior"
else
  fail "AC-128A-1 processAlive/readJsonOrNull mismatch"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "all atomic-fs smoke cases passed"
  exit 0
fi
echo "$FAIL atomic-fs smoke case(s) failed" >&2
exit 1
