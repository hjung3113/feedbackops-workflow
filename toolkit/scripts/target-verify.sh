#!/usr/bin/env bash
# Target-neutral verifier. Profile commands are structured argv consumed by Node.
# Bash 3.2 compatible.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ "$#" -ne 2 ]; then
  echo "usage: target-verify.sh <target-profile.json> <issue>" >&2
  exit 2
fi
exec node "$SCRIPT_DIR/lib/target-verify.mjs" "$1" "$2"
