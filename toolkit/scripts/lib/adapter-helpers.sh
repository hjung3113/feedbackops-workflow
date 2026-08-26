#!/usr/bin/env bash
# Shared cross-adapter helpers for cmux/orca/herdr transport adapters.
# Source from an adapter with:
#   . "$(cd "$(dirname "$0")" && pwd)/../lib/adapter-helpers.sh"
# bash-3.2-compatible: no associative arrays, mapfile, or lowercase expansion.

ADAPTER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ADAPTER_SEMVER="$ADAPTER_LIB_DIR/semver.cjs"
ADAPTER_JSON="$ADAPTER_LIB_DIR/adapter-json.cjs"
ADAPTER_TRANSPORT_REGISTRY="$ADAPTER_LIB_DIR/transport-registry.cjs"
ADAPTER_HANDLE_RESULT="$ADAPTER_LIB_DIR/handle-result.cjs"

# Real Herdr's own `herdr --skill` contract only documents HERDR_ENV plus the
# workspace/tab/pane identity vars; HERDR_SOCKET_PATH is not part of it and is
# never set on a genuine Herdr-managed pane. Keep this predicate shared with
# transport detection and the Herdr adapter so the inherited-session contract
# has one source of truth.
session_context_available() {
  [ "${HERDR_ENV:-}" = "1" ] \
    && [ -n "${HERDR_WORKSPACE_ID:-}" ] \
    && [ -n "${HERDR_TAB_ID:-}" ] \
    && [ -n "${HERDR_PANE_ID:-}" ]
}

# detect_current_transport: identify a reliable ambient transport signal.
# Herdr is the only transport with one; Orca and cmux have no equivalent.
detect_current_transport() {
  if session_context_available; then
    printf '%s\n' 'herdr'
    return 0
  fi
  return 1
}

# help_has <help-text> <flag-or-word>: true when the captured --help
# output contains the needle as a whole token. Non-token characters are
# normalized to single spaces so `get` cannot match inside `forget`;
# `-` stays a token character so multi-dash flags like `--cwd` match intact.
help_has() {
  hay=" $(printf '%s' "$1" | tr -c 'A-Za-z0-9_-' ' ') "
  case "$hay" in
    *" $2 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# runner_path_allowed <path>: the only launch runner form every adapter
# accepts. Shared owner of the `.review/ISSUE-*-launch.*/launch.sh` guard.
runner_path_allowed() {
  case "$1" in
    .review/ISSUE-*-launch.*/launch.sh) return 0 ;;
    *) return 1 ;;
  esac
}

# adapter_lifecycle_json <lifecycle> <reason>: typed lifecycle JSON.
adapter_lifecycle_json() {
  node "$ADAPTER_JSON" lifecycle "$1" "$2"
}

# adapter_session_json <lifecycle> <handles-json> [external-handle]: emit the
# normalized live session result. The external handle is optional because
# composite identities (for example workspace + surface) have no safe alias.
adapter_session_json() {
  if [ "$#" -ge 3 ]; then
    node "$ADAPTER_JSON" session "$1" "$2" "$3"
  else
    node "$ADAPTER_JSON" session "$1" "$2"
  fi
}

# adapter_live_capabilities_json: canonical semantic capability vocabulary.
adapter_live_capabilities_json() {
  node "$ADAPTER_TRANSPORT_REGISTRY" live-capabilities | node -e '
const fs=require("fs");
const values=fs.readFileSync(0,"utf8").split(/\r?\n/).filter(Boolean);
process.stdout.write(JSON.stringify(values));
'
}

# adapter_has_live_capabilities <capabilities-json>: all phase-1 live session
# primitives must be proven before a caller may select live-tui.
adapter_has_live_capabilities() {
  node - "$1" "$ADAPTER_TRANSPORT_REGISTRY" <<'NODE'
const [raw, registry] = process.argv.slice(2);
try {
  const actual = JSON.parse(raw), required = require(registry).LIVE_CAPABILITIES;
  if (!Array.isArray(actual) || !required.every(value => actual.indexOf(value) !== -1)) process.exit(2);
} catch (_) { process.exit(2); }
NODE
}

# adapter_availability_split_json <adapter> <headless-json> <live-json>:
# preserve separate availability claims for capability survey/adapters.
adapter_availability_split_json() {
  node "$ADAPTER_JSON" availability "$1" "$2" "$3"
}

# adapter_handle_unverifiable <reason>: graceful exit-0 JSON fallback
# shared by every adapter inspect path.
adapter_handle_unverifiable() {
  adapter_lifecycle_json handle_unverifiable "$1"
  return 0
}

# adapter_provenance_version <version> <digest>: single owner of the
# `"<version>;binary-sha256:<digest>"` provenance format.
adapter_provenance_version() {
  printf '%s;binary-sha256:%s\n' "$1" "$2"
}
