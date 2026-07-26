#!/usr/bin/env bash
# Deterministic routing CLI. `decide` is a single pure Node process and works
# without git on PATH. `probe` is a bounded host-side identity/configuration
# cache; it never contacts a model or asserts remote availability.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMAND="${1:-}"
[ -n "$COMMAND" ] || { echo "usage: route.sh decide|probe|policy ..." >&2; exit 2; }
shift

if [ "$COMMAND" = "policy" ]; then
  exec node "$SCRIPT_DIR/lib/route-policy.cjs" "$@"
fi

if [ "$COMMAND" = "probe" ]; then
  PROBE_RUNTIME=""
  PROBE_DEPTH=""
  PROBE_TTL="1800"
  while [ $# -gt 0 ]; do
    case "$1" in
      --runtime) PROBE_RUNTIME="$2"; shift 2 ;;
      --depth) PROBE_DEPTH="$2"; shift 2 ;;
      --ttl-seconds) PROBE_TTL="$2"; shift 2 ;;
      *) echo "ERROR: unknown route probe argument: $1" >&2; exit 2 ;;
    esac
  done
  case "$PROBE_RUNTIME" in codex|claude|opencode) ;; *) exit 2 ;; esac
  [ "$PROBE_DEPTH" = "static" ] || exit 2
  case "$PROBE_TTL" in ''|*[!0-9]*) exit 2 ;; esac
  [ "$PROBE_TTL" -ge 1 ] && [ "$PROBE_TTL" -le 3600 ] || exit 2
  PROBE_EXECUTABLE="${AGENT_WORKFLOW_ROUTE_EXECUTABLE:-}"
  if [ -z "$PROBE_EXECUTABLE" ]; then
    PROBE_EXECUTABLE="$(command -v "$PROBE_RUNTIME" 2>/dev/null || true)"
  fi
  case "$PROBE_EXECUTABLE" in /*) ;; *) exit 3 ;; esac
  [ -x "$PROBE_EXECUTABLE" ] || exit 3
  export PROBE_RUNTIME PROBE_TTL PROBE_EXECUTABLE
  exec node - <<'NODE'
const crypto = require("crypto");
const { execFileSync } = require("child_process");
const fs = require("fs");
const path = require("path");
const runtime = process.env.PROBE_RUNTIME;
const ttl = Number(process.env.PROBE_TTL);
const executable = process.env.PROBE_EXECUTABLE;
const hostRoot = path.resolve(process.env.AGENT_WORKFLOW_HOST_STATE
  || (process.env.XDG_STATE_HOME ? path.join(process.env.XDG_STATE_HOME, "agent-workflow")
    : path.join(process.env.HOME || "/tmp", ".local", "state", "agent-workflow")));
const sha256 = value => crypto.createHash("sha256").update(value).digest("hex");
const refuse = code => { process.stdout.write(JSON.stringify({ status: "refused", code }) + "\n"); process.exit(3); };
const safeFile = file => {
  try { const stat = fs.lstatSync(file); return stat.isFile() && !stat.isSymbolicLink() && (stat.mode & 0o022) === 0 && stat.size <= 16 * 1024; }
  catch (_) { return false; }
};
try {
  const capability = process.env.AGENT_WORKFLOW_ROUTE_CAPABILITY_JSON ? JSON.parse(process.env.AGENT_WORKFLOW_ROUTE_CAPABILITY_JSON) : {};
  if (capability.runtime && capability.runtime !== runtime) refuse("runner_offer_invalid");
  if (capability.executable && path.resolve(capability.executable) !== executable) refuse("runner_offer_invalid");
  const profile = {
    modes: capability.modes || [], write_isolation: capability.write_isolation || null,
    config_application: capability.config_application || null, requires: capability.requires || []
  };
  const permissionFile = process.env.AGENT_WORKFLOW_ROUTE_PERMISSION_FILE || "";
  if (permissionFile) {
    if (!safeFile(permissionFile)) refuse("runner_offer_invalid");
    profile.permission_file_sha256 = sha256(fs.readFileSync(permissionFile));
  }
  const permission_profile_digest = sha256(JSON.stringify(profile));
  const cacheDir = path.join(hostRoot, "route-offers");
  const cacheFile = path.join(cacheDir, `${sha256(JSON.stringify({ runtime, executable, permission_profile_digest }))}.json`);
  const now = Date.now();
  if (fs.existsSync(cacheFile) && !safeFile(cacheFile)) refuse("runner_offer_invalid");
  if (safeFile(cacheFile)) {
    const cached = JSON.parse(fs.readFileSync(cacheFile, "utf8"));
    if (cached.runtime === runtime && cached.executable === executable && cached.permission_profile_digest === permission_profile_digest
        && Date.parse(cached.expires_at) > now) {
      process.stdout.write(JSON.stringify({ status: "admitted", offer: cached }) + "\n");
      process.exit(0);
    }
  }
  // Dispatch capability admission may already have observed this exact pinned
  // executable. Reuse that host observation; otherwise run one bounded local
  // version command. Neither path contacts a model or the network.
  const version = String(capability.version || process.env.AGENT_WORKFLOW_ROUTE_VERSION ||
    execFileSync(executable, ["--version"], { encoding: "utf8", timeout: 50, maxBuffer: 4096 })).trim();
  if (!version || Buffer.byteLength(version, "utf8") > 1024) refuse("runner_offer_invalid");
  const observed = new Date(now);
  const offer = { runtime, executable, version, observed_at: observed.toISOString(), expires_at: new Date(now + ttl * 1000).toISOString(), permission_profile_digest };
  fs.mkdirSync(cacheDir, { recursive: true, mode: 0o700 });
  const pending = `${cacheFile}.tmp.${process.pid}`;
  fs.writeFileSync(pending, `${JSON.stringify(offer)}\n`, { mode: 0o600, flag: "w" });
  fs.chmodSync(pending, 0o600);
  fs.renameSync(pending, cacheFile);
  process.stdout.write(JSON.stringify({ status: "admitted", offer }) + "\n");
} catch (_) { refuse("runner_offer_invalid"); }
NODE
fi

[ "$COMMAND" = "decide" ] || { echo "ERROR: unsupported route command: $COMMAND" >&2; exit 2; }

DEMAND=""
OFFER=""
POLICY=""
POLICY_DIGEST=""
MODEL_ALLOC=""
NOW=""
while [ $# -gt 0 ]; do
  case "$1" in
    --demand) DEMAND="$2"; shift 2 ;;
    --offer) OFFER="$2"; shift 2 ;;
    --policy) POLICY="$2"; shift 2 ;;
    --policy-digest) POLICY_DIGEST="$2"; shift 2 ;;
    --model-alloc) MODEL_ALLOC="$2"; shift 2 ;;
    --now) NOW="$2"; shift 2 ;;
    *) echo "ERROR: unknown route argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$DEMAND" ] && [ -n "$OFFER" ] && [ -n "$POLICY" ] && [ -n "$MODEL_ALLOC" ] && [ -n "$NOW" ] || { echo "ERROR: route decide requires demand, offer, policy, model-alloc, and now" >&2; exit 2; }

node - "$SCRIPT_DIR/lib/route.cjs" "$DEMAND" "$OFFER" "$POLICY" "$MODEL_ALLOC" "$NOW" "$POLICY_DIGEST" <<'NODE'
const { decide } = require(process.argv[2]);
try {
  const [demand, offer, policy, modelAlloc] = process.argv.slice(3, 7).map(JSON.parse);
  const outcome = decide({ demand, offer, policy, modelAlloc, now: process.argv[7], policyDigest: process.argv[8] || undefined });
  process.stdout.write(JSON.stringify(outcome) + "\n");
  process.exit(outcome.status === "admitted" ? 0 : 3);
} catch (_) {
  process.exit(2);
}
NODE
