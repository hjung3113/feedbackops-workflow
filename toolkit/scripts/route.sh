#!/usr/bin/env bash
# Deterministic routing CLI. `decide` is a single pure Node process and works
# without git on PATH; host-policy installation and static probing are wired by
# later dispatch slices.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMAND="${1:-}"
[ -n "$COMMAND" ] || { echo "usage: route.sh decide|policy ..." >&2; exit 2; }
shift

if [ "$COMMAND" = "policy" ]; then
  exec node "$SCRIPT_DIR/lib/route-policy.cjs" "$@"
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
