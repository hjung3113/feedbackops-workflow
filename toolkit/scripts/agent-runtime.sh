#!/usr/bin/env bash
# Typed, fail-closed runtime boundary. It intentionally never selects a fallback.
# bash-3.2 compatible.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_REGISTRY="$SCRIPT_DIR/lib/runtime-registry.cjs"
RUNTIME=""; ROLE=""; MODE=""; CWD=""; PROMPT_FILE=""; MODEL=""; EFFORT=""; OPENCODE_PERMISSION_FILE=""; ISSUE_N=""; PRODUCE_REVIEW=0
registry_runtime_pipe() { node "$RUNTIME_REGISTRY" pipe; }
usage() { echo "usage: agent-runtime.sh capabilities --runtime $(registry_runtime_pipe)" >&2; echo "       agent-runtime.sh run --runtime R --role conductor|architect|implementation|reviewer|verifier|visual|release --mode read|write --cwd DIR --prompt-file FILE [--issue N] [--model M] [--effort E] [--opencode-permission-file FILE] [--produce-review]" >&2; }
machine_error() { printf '{"ok":false,"code":"%s","detail":"%s"}\n' "$1" "$2" >&2; exit 3; }
runtime_bin() {
  # dispatch-core may pin one absolute, capability-proved executable. Never
  # substitute a PATH binary when that pin is present.
  if [ -n "${AGENT_WORKFLOW_RUNTIME_BIN:-}" ]; then
    case "$AGENT_WORKFLOW_RUNTIME_BIN" in /*) printf '%s\n' "$AGENT_WORKFLOW_RUNTIME_BIN";; *) machine_error runtime_pin_not_absolute 'AGENT_WORKFLOW_RUNTIME_BIN must be absolute';; esac
    return
  fi
  # The runtime set and each runtime's pinned-binary env/default are registry
  # data; this boundary never re-hardcodes the runtime names.
  bin="$(node "$RUNTIME_REGISTRY" bin "$1")" || machine_error unknown_runtime "runtime must be codex, claude, or opencode"
  printf '%s\n' "$bin"
}
runtime_path() { command -v "$1" 2>/dev/null || return 1; }
runtime_version() { "$1" --version 2>/dev/null | head -n 1 | tr '\n' ' '; }
has_help_token() { "$1" --help 2>&1 | grep -F -- "$2" >/dev/null 2>&1; }
subcommand_has_help_token() { bin="$1"; subcommand="$2"; token="$3"; "$bin" "$subcommand" --help 2>&1 | grep -F -- "$token" >/dev/null 2>&1; }
probe_runtime() {
  runtime="$1"; bin="$(runtime_bin "$runtime")"
  if ! command -v "$bin" >/dev/null 2>&1; then printf '{"runtime":"%s","available":false,"code":"runtime_unavailable"}\n' "$runtime"; return 1; fi
  path="$(runtime_path "$bin")"; version="$(runtime_version "$bin")"
  # Each runtime's required help-token contract is registry data. This stays
  # procedural: probe the documented help surfaces in order and fail closed
  # on the first missing token, exactly like the previous inline chain. A
  # registry that cannot answer fails closed too — an unchecked contract
  # must never read as a passed one.
  contract=1
  probe_tokens="$(node "$RUNTIME_REGISTRY" probe-help-tokens "$runtime")" || { printf '{"runtime":"%s","available":false,"code":"runtime_registry_unavailable"}\n' "$runtime"; return 1; }
  for token in $probe_tokens; do
    has_help_token "$bin" "$token" || { contract=0; break; }
  done
  if [ "$contract" -eq 1 ]; then
    probe_subcommand="$(node "$RUNTIME_REGISTRY" probe-subcommand "$runtime")" || { printf '{"runtime":"%s","available":false,"code":"runtime_registry_unavailable"}\n' "$runtime"; return 1; }
    if [ -n "$probe_subcommand" ]; then
      probe_subcommand_tokens="$(node "$RUNTIME_REGISTRY" probe-subcommand-help-tokens "$runtime")" || { printf '{"runtime":"%s","available":false,"code":"runtime_registry_unavailable"}\n' "$runtime"; return 1; }
      for token in $probe_subcommand_tokens; do
        subcommand_has_help_token "$bin" "$probe_subcommand" "$token" || { contract=0; break; }
      done
    fi
  fi
  case "$runtime" in
    codex) if [ "$contract" -eq 1 ]; then printf '{"runtime":"codex","available":true,"executable":"%s","version":"%s","roles":["conductor","architect","implementation","reviewer","verifier","visual","release"],"modes":["read","write"],"write_isolation":"codex_workspace_write","fallback":false}\n' "$path" "$version"; else printf '%s\n' '{"runtime":"codex","available":false,"code":"capability_missing_exec_contract"}'; return 1; fi;;
    claude) if [ "$contract" -eq 1 ]; then printf '{"runtime":"claude","available":true,"executable":"%s","version":"%s","roles":["conductor","architect","implementation","reviewer","verifier","visual","release"],"modes":["read","write"],"write_isolation":"runtime_permission_mode","fallback":false}\n' "$path" "$version"; else printf '%s\n' '{"runtime":"claude","available":false,"code":"capability_missing_print_permissions_output_model_or_effort"}'; return 1; fi;;
    # OpenCode documents OPENCODE_CONFIG_CONTENT as its inline runtime config
    # mechanism. --agent is the complementary CLI contract that makes the
    # configured, named primary agent explicit rather than accepting the CLI's
    # default-agent fallback behavior.
    opencode) if [ "$contract" -eq 1 ]; then printf '{"runtime":"opencode","available":true,"executable":"%s","version":"%s","roles":["conductor","architect","implementation","reviewer","verifier","visual","release"],"modes":["read","write"],"write_isolation":"inline_deny_first_config_plus_explicit_agent","config_application":"OPENCODE_CONFIG_CONTENT","fallback":false,"requires":["opencode_permission_file","opencode_config_content","opencode_run_agent"]}\n' "$path" "$version"; else printf '%s\n' '{"runtime":"opencode","available":false,"code":"capability_missing_run_contract"}'; return 1; fi;;
  esac
}
validate_opencode_permissions() {
  [ -n "$1" ] || machine_error opencode_permission_config_required "OpenCode requires explicit deny-first permission config"
  [ -f "$1" ] || machine_error opencode_permission_config_missing "permission file does not exist"
  set +e
  node - "$1" "$2" <<'NODE'
const fs = require("fs"); try {
  const c=JSON.parse(fs.readFileSync(process.argv[2],"utf8")), p=c.permission,
    m=process.argv[3], a=c.agent && c.agent["agent-workflow"], ap=a && a.permission;
  if (!p || p["*"] !== "deny") process.exit(10);
  if (p.external_directory !== "deny") process.exit(14);
  if (!a || a.mode !== "primary" || !ap || ap["*"] !== "deny") process.exit(15);
  if (ap.external_directory !== "deny") process.exit(14);
  // write (implementation) may fetch docs/packages; read (review/verify) stays fully deny-first.
  if (m === "write" && (p.edit !== "allow" || ap.edit !== "allow" || p.bash !== "allow" || ap.bash !== "allow" || p.webfetch !== "allow" || ap.webfetch !== "allow" || p.websearch !== "allow" || ap.websearch !== "allow")) process.exit(11);
  if (m === "read" && (p.edit === "allow" || ap.edit === "allow" || p.bash !== "deny" || ap.bash !== "deny" || p.webfetch !== "deny" || ap.webfetch !== "deny" || p.websearch !== "deny" || ap.websearch !== "deny")) process.exit(12);
} catch (_) { process.exit(13); }
NODE
  status=$?; set -e
  case "$status" in 0) ;; 10) machine_error opencode_permission_not_deny_first 'permission.* must be deny';; 11) machine_error opencode_write_not_explicitly_allowed 'write requires permission.edit=allow, permission.bash=allow, permission.webfetch=allow, and permission.websearch=allow';; 12) machine_error opencode_read_allows_write_tools 'read requires edit, webfetch, and websearch denied, and bash denied';; 14) machine_error opencode_dangerous_permissions_not_denied 'external_directory must be deny';; 15) machine_error opencode_explicit_agent_required 'config must define deny-first primary agent-workflow';; *) machine_error opencode_permission_config_invalid 'permission config must be JSON';; esac
}
[ "$#" -ge 1 ] || { usage; exit 2; }; COMMAND="$1"; shift
while [ "$#" -gt 0 ]; do case "$1" in --runtime) RUNTIME="$2"; shift 2;; --role) ROLE="$2"; shift 2;; --mode) MODE="$2"; shift 2;; --cwd) CWD="$2"; shift 2;; --prompt-file) PROMPT_FILE="$2"; shift 2;; --issue) ISSUE_N="$2"; shift 2;; --model) MODEL="$2"; shift 2;; --effort) EFFORT="$2"; shift 2;; --opencode-permission-file) OPENCODE_PERMISSION_FILE="$2"; shift 2;; --produce-review) PRODUCE_REVIEW=1; shift;; *) usage; machine_error unknown_argument "$1";; esac; done
[ -n "$RUNTIME" ] || machine_error runtime_required 'pass --runtime'
case "$COMMAND" in capabilities) probe_runtime "$RUNTIME"; exit $?;; run) ;; *) usage; machine_error unknown_command "$COMMAND";; esac
case "$ROLE" in conductor|architect|implementation|reviewer|verifier|visual|release) ;; *) machine_error unsupported_role 'role must be explicit';; esac
case "$MODE" in read|write) ;; *) machine_error unsupported_mode 'mode must be read or write';; esac
[ -d "$CWD" ] || machine_error cwd_invalid 'cwd must exist'; [ -f "$PROMPT_FILE" ] || machine_error prompt_missing 'prompt file must exist'
probe_runtime "$RUNTIME" >/dev/null || machine_error runtime_capability_unavailable 'probe runtime with capabilities for details'
BIN="$(runtime_bin "$RUNTIME")"; PROMPT="$(cat "$PROMPT_FILE")"; [ -n "$PROMPT" ] || machine_error prompt_empty 'prompt file must not be empty'
case "$RUNTIME" in
  codex)
    # Delegate write/review launches to the existing hardened wrapper. This
    # preserves writable Git metadata, effort forwarding, abort stash, heartbeat,
    # and atomic REVIEW publication rather than reimplementing the contract.
    if [ "$MODE" = write ] || [ "$PRODUCE_REVIEW" -eq 1 ]; then
      [ -n "$ISSUE_N" ] || machine_error issue_required 'Codex write/review requires --issue for codex-safe invariants'
      AGENT_WORKFLOW_CODEX_BIN="$BIN"
      export AGENT_WORKFLOW_CODEX_BIN
      set -- "$SCRIPT_DIR/codex-safe.sh" --issue "$ISSUE_N" --prompt-file "$PROMPT_FILE" --cwd "$CWD"
      [ -n "$MODEL" ] && set -- "$@" --model "$MODEL"; [ -n "$EFFORT" ] && set -- "$@" --effort "$EFFORT"
      [ "$PRODUCE_REVIEW" -eq 1 ] && set -- "$@" --produce-review
      exec "$@"
    fi
    set -- "$BIN" exec --sandbox read-only --cd "$CWD"; [ -n "$MODEL" ] && set -- "$@" -m "$MODEL"; [ -n "$EFFORT" ] && set -- "$@" -c "model_reasoning_effort=\"$EFFORT\""; exec "$@" "$PROMPT";;
  claude)
    [ "$MODE" = write ] && permission=acceptEdits || permission=plan
    set -- "$BIN" --print --permission-mode "$permission"
    # The progress event stream is registry data (PROGRESS.claude.flags), not
    # a hardcoded --output-format text argv — agent-watchdog.sh's progressed()
    # and transcribe_review() key off this same table to read the stream back.
    while IFS= read -r flag; do [ -n "$flag" ] && set -- "$@" "$flag"; done < <(node "$RUNTIME_REGISTRY" progress-flags claude)
    [ -n "$MODEL" ] && set -- "$@" --model "$MODEL"; [ -n "$EFFORT" ] && set -- "$@" --effort "$EFFORT"; cd "$CWD"; exec "$@" "$PROMPT";;
  opencode)
    validate_opencode_permissions "$OPENCODE_PERMISSION_FILE" "$MODE"
    # Inline content has higher precedence than target/global config. Passing
    # the named primary agent is required: an unknown/default agent may fall
    # back to OpenCode's built-in build agent, which is not an isolation path.
    OPENCODE_CONFIG_CONTENT="$(cat "$OPENCODE_PERMISSION_FILE")"; export OPENCODE_CONFIG_CONTENT
    set -- "$BIN" run --dir "$CWD" --format default --agent agent-workflow
    [ -n "$MODEL" ] && set -- "$@" --model "$MODEL"; [ -n "$EFFORT" ] && set -- "$@" --variant "$EFFORT"; exec "$@" "$PROMPT";;
esac
