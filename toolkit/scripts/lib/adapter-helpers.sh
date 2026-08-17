#!/usr/bin/env bash
# Shared cross-adapter helpers for cmux/orca/herdr transport adapters.
# Source from an adapter with:
#   . "$(cd "$(dirname "$0")" && pwd)/../lib/adapter-helpers.sh"
# bash-3.2-compatible: no associative arrays, mapfile, or lowercase expansion.

ADAPTER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ADAPTER_SEMVER="$ADAPTER_LIB_DIR/semver.cjs"
ADAPTER_JSON="$ADAPTER_LIB_DIR/adapter-json.cjs"

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
