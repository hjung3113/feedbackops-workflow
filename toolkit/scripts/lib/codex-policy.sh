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
// TOML basic-string encoder: escape backslash, double quote, and control
// characters per the TOML spec so any cwd round-trips through a valid
// one-line key (#218 review).
const tomlEncode = value => "\"" + [...value].map(ch => {
  const cp = ch.codePointAt(0);
  if (ch === "\"") return "\\\"";
  if (ch === "\\") return "\\\\";
  if (ch === "\n") return "\\n";
  if (ch === "\r") return "\\r";
  if (ch === "\t") return "\\t";
  if (cp < 0x20 || cp === 0x7f) return "\\u" + cp.toString(16).padStart(4, "0");
  return ch;
}).join("") + "\"";
const tableHeader = `[projects.${tomlEncode(cwd)}]`;
// Header matching parses the quoted key and compares DECODED path strings,
// never raw or whitespace-stripped lines: whitespace inside the quoted path
// is significant (`/x/a b` must never match `/x/ab`), while whitespace in
// the TOML syntax around `[`, `projects`, `.`, `]` is tolerated. Both basic
// and literal strings are accepted; a trailing comment is ignored.
const decodeTomlString = raw => {
  const body = raw.slice(1, -1);
  if (raw.startsWith("'")) return body;
  return body.replace(/\\(u[0-9a-fA-F]{4}|U[0-9a-fA-F]{8}|["\\nrtbf])/g, (match, esc) => {
    if (esc[0] === "u" || esc[0] === "U") return String.fromCodePoint(parseInt(esc.slice(1), 16));
    const escapes = { '"': '"', "\\": "\\", n: "\n", r: "\r", t: "\t", b: "\b", f: "\f" };
    return escapes[esc];
  });
};
const headerRe = /^\s*\[\s*projects\s*\.\s*("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')\s*\]\s*(?:#.*)?$/;
const headerCwd = line => {
  const match = headerRe.exec(line);
  return match ? decodeTomlString(match[1]) : null;
};
const matchesTarget = line => headerCwd(line) === cwd;
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
    inTable = matchesTarget(line);
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
