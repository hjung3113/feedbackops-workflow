#!/usr/bin/env bash
# Shared Codex policy helpers. Runtime-axis members source this file so the
# interactive launch-spec and the headless codex-safe wrapper resolve the same
# model/effort and Git metadata policy.
# bash-3.2-compatible: no associative arrays, mapfile, or lowercase expansion.

codex_pin_effort() {
  codex_model="$1"
  codex_effort="$2"
  case "$codex_model" in
    *5.6*|*5-6*)
      [ -n "$codex_effort" ] && printf '%s\n' "$codex_effort" || printf '%s\n' "medium"
      ;;
    *) printf '%s\n' "$codex_effort" ;;
  esac
}

codex_git_common_dir() {
  codex_cwd="$1"
  codex_raw="$(git -C "$codex_cwd" rev-parse --git-common-dir 2>/dev/null || true)"
  [ -n "$codex_raw" ] || return 1
  case "$codex_raw" in
    /*) (cd "$codex_raw" 2>/dev/null && pwd) ;;
    *) (cd "$codex_cwd" 2>/dev/null && cd "$codex_raw" 2>/dev/null && pwd) ;;
  esac
}

codex_stash_partial_work() {
  codex_stash_script="$1"
  codex_issue="$2"
  codex_cwd="$3"
  "$codex_stash_script" "$codex_issue" "$codex_cwd"
}
