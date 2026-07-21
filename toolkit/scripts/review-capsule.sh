#!/usr/bin/env bash
# Render/check a deterministic re-review capsule. Bash 3.2 compatible.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec node "$SCRIPT_DIR/lib/review-capsule.mjs" "$@"
