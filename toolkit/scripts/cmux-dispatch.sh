#!/usr/bin/env bash
# Compatibility facade: historical callers explicitly chose cmux by invoking
# this command. All correctness and transport-neutral dispatch logic lives in
# dispatch-core.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/dispatch-core.sh" --adapter cmux "$@"
