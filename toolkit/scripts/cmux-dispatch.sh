#!/usr/bin/env bash
# Compatibility facade: historical callers explicitly chose cmux by invoking
# this command. All correctness and transport-neutral dispatch logic lives in
# dispatch-core.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPAT_ROLE="implementation"
for arg in "$@"; do
  case "$arg" in
    --produce-review) COMPAT_ROLE="reviewer" ;;
    --read-only) [ "$COMPAT_ROLE" = "implementation" ] && COMPAT_ROLE="architect" ;;
  esac
done
exec bash "$SCRIPT_DIR/dispatch-core.sh" --adapter cmux --runtime codex --role "$COMPAT_ROLE" "$@"
