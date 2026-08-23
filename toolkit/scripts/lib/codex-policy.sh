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

# Codex's own first-run per-directory trust store pre-seed (#215). Codex
# prompts "Do you trust the contents of this directory?" for a cwd that is
# not an exact-path entry in $CODEX_HOME/config.toml (default ~/.codex),
# and screen-scraping transports cannot classify that prompt (#212), so a
# live launch against a fresh worktree would hang. The runtime's
# launch-spec emission calls this before any transport launches codex, so
# the trust screen never renders. TOML-safe: existing tables are matched
# with whitespace-normalized headers, only the matched table's
# trust_level line is inserted/updated in place, and all other config is
# preserved verbatim.
codex_trust_preseed() {
  preseed_cwd="$1"
  preseed_config_dir="${CODEX_HOME:-$HOME/.codex}"
  mkdir -p "$preseed_config_dir" || return 1
  # Concurrent codex live launches can share CODEX_HOME; serialize the
  # whole read-modify-rename through a mkdir lock (atomic, no flock
  # dependency) and write through a unique temp file so parallel launches
  # never fight over one temp path or clobber each other's entries (#218
  # review).
  preseed_config="$preseed_config_dir/config.toml"
  preseed_lock="$preseed_config_dir/.config.toml.preseed.lock"
  preseed_acquired=""
  preseed_tries=0
  while [ "$preseed_tries" -lt 50 ]; do
    if mkdir "$preseed_lock" 2>/dev/null; then
      preseed_acquired=1
      break
    fi
    # Stale-lock reclaim: the holder records its PID inside the lock. If
    # that PID is gone (killed process, reboot), the lock is abandoned and
    # safe to reclaim; a live holder is always respected.
    if [ -f "$preseed_lock/owner.pid" ]; then
      preseed_owner="$(cat "$preseed_lock/owner.pid" 2>/dev/null)"
      case "$preseed_owner" in
        *[!0-9]*|'') ;;
        *)
          if ! kill -0 "$preseed_owner" 2>/dev/null; then
            rm -rf "$preseed_lock"
          fi
          ;;
      esac
    fi
    preseed_tries=$((preseed_tries + 1))
    sleep 0.1
  done
  [ -n "$preseed_acquired" ] || return 1
  printf '%s\n' "$$" > "$preseed_lock/owner.pid"
  # Signal-trap release so a killed holder frees the lock when it can;
  # SIGKILL (where no trap runs) is covered by the PID reclaim above.
  # The caller's prior EXIT trap (if any) is saved and restored.
  preseed_prev_exit_trap="$(trap -p EXIT)"
  trap 'rm -rf "$preseed_lock" 2>/dev/null' EXIT INT TERM HUP
  preseed_tmp="$preseed_config_dir/.config.toml.preseed.$$.$RANDOM"
  node - "$preseed_config" "$preseed_cwd" "$preseed_tmp" <<'NODE'
const fs = require("fs");
const [configFile, cwd, tmpFile] = process.argv.slice(2);
const tomlString = value => "\"" + value.replace(/\\/g, "\\\\").replace(/"/g, "\\\"") + "\"";
const tableHeader = `[projects.${tomlString(cwd)}]`;
// Whitespace-normalized comparison: an equivalent valid spelling of the
// same table header (e.g. `[ projects . "x" ]`) must match instead of
// producing a duplicate table TOML would reject (#218 review).
const normalizeHeader = line => line.replace(/\s+/g, "");
const targetHeader = normalizeHeader(tableHeader);
let text = "";
let existingMode = null;
try {
  const stats = fs.statSync(configFile);
  text = fs.readFileSync(configFile, "utf8");
  existingMode = stats.mode & 0o777;
} catch (error) {
  // Only a genuinely absent config starts fresh. An unreadable-but-present
  // config (EACCES, EISDIR, transient I/O) must fail closed, never be
  // clobbered by a fresh rewrite (#218 review).
  if (error.code !== "ENOENT") process.exit(3);
}
const lines = text.split("\n");
let inTable = false;
let tableFound = false;
let trustSeen = false;
const rewritten = [];
for (const line of lines) {
  const isHeader = /^\s*\[/.test(line);
  if (isHeader && inTable && !trustSeen) {
    rewritten.push("trust_level = \"trusted\"");
    trustSeen = true;
  }
  if (isHeader) {
    inTable = normalizeHeader(line) === targetHeader;
    if (inTable) tableFound = true;
  }
  if (inTable && /^\s*trust_level\s*=/.test(line)) {
    rewritten.push("trust_level = \"trusted\"");
    trustSeen = true;
    continue;
  }
  rewritten.push(line);
}
let out = rewritten.join("\n");
if (text !== "" && !out.endsWith("\n")) out += "\n";
if (!tableFound) out += tableHeader + "\n";
if (!trustSeen) out += "trust_level = \"trusted\"\n";
// Restrictive 0600 for a fresh config; an existing config's mode is
// transferred to the replacement so 0600 never widens to the umask
// default (#218 review).
fs.writeFileSync(tmpFile, out, { mode: 0o600 });
if (existingMode !== null) fs.chmodSync(tmpFile, existingMode);
fs.renameSync(tmpFile, configFile);
NODE
  preseed_status=$?
  rm -f "$preseed_tmp" 2>/dev/null || true
  rm -rf "$preseed_lock" 2>/dev/null || true
  if [ -n "$preseed_prev_exit_trap" ]; then
    eval "$preseed_prev_exit_trap"
  else
    trap - EXIT
  fi
  trap - INT TERM HUP
  return "$preseed_status"
}
