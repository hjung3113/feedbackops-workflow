#!/usr/bin/env bash
# Typed, fail-closed runtime boundary. It intentionally never selects a fallback.
# bash-3.2 compatible.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_REGISTRY="$SCRIPT_DIR/lib/runtime-registry.cjs"
RUNTIME=""; ROLE=""; MODE=""; CWD=""; PROMPT_FILE=""; MODEL=""; EFFORT=""; OPENCODE_PERMISSION_FILE=""; ISSUE_N=""; PRODUCE_REVIEW=0; BIN=""; PROMPT=""
registry_runtime_pipe() { node "$RUNTIME_REGISTRY" pipe; }
usage() { echo "usage: agent-runtime.sh capabilities --runtime $(registry_runtime_pipe)" >&2; echo "       agent-runtime.sh run --runtime R --role conductor|architect|implementation|reviewer|verifier|visual|release --mode read|write --cwd DIR --prompt-file FILE [--issue N] [--model M] [--effort E] [--opencode-permission-file FILE] [--produce-review]" >&2; echo "       agent-runtime.sh probe --runtime R --model M --effort E" >&2; }
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
[ "$#" -ge 1 ] || { usage; exit 2; }; COMMAND="$1"; shift
while [ "$#" -gt 0 ]; do case "$1" in --runtime) RUNTIME="$2"; shift 2;; --role) ROLE="$2"; shift 2;; --mode) MODE="$2"; shift 2;; --cwd) CWD="$2"; shift 2;; --prompt-file) PROMPT_FILE="$2"; shift 2;; --issue) ISSUE_N="$2"; shift 2;; --model) MODEL="$2"; shift 2;; --effort) EFFORT="$2"; shift 2;; --opencode-permission-file) OPENCODE_PERMISSION_FILE="$2"; shift 2;; --produce-review) PRODUCE_REVIEW=1; shift;; *) usage; machine_error unknown_argument "$1";; esac; done
[ -n "$RUNTIME" ] || machine_error runtime_required 'pass --runtime'
case "$COMMAND" in
  capabilities)
    probe_runtime "$RUNTIME"
    exit $?
    ;;
  permission-file)
    [ -n "$ROLE" ] || machine_error role_required 'pass --role'
    [ -d "$CWD" ] || machine_error worktree_invalid 'worktree must exist'
    ;;
  probe)
    [ -n "$MODEL" ] || machine_error model_required 'pass --model'
    [ -n "$EFFORT" ] || machine_error effort_required 'pass --effort'
    CWD="${AGENT_WORKFLOW_RUNTIME_PROBE_CWD:-$PWD}"
    OPENCODE_PERMISSION_FILE="${AGENT_WORKFLOW_RUNTIME_PROBE_PERMISSION_FILE:-$OPENCODE_PERMISSION_FILE}"
    [ -d "$CWD" ] || machine_error cwd_invalid 'probe cwd must exist'
    BIN="$(runtime_bin "$RUNTIME")"
    ;;
  run)
    case "$ROLE" in conductor|architect|implementation|reviewer|verifier|visual|release) ;; *) machine_error unsupported_role 'role must be explicit';; esac
    case "$MODE" in read|write) ;; *) machine_error unsupported_mode 'mode must be read or write';; esac
    [ -d "$CWD" ] || machine_error cwd_invalid 'cwd must exist'; [ -f "$PROMPT_FILE" ] || machine_error prompt_missing 'prompt file must exist'
    probe_runtime "$RUNTIME" >/dev/null || machine_error runtime_capability_unavailable 'probe runtime with capabilities for details'
    BIN="$(runtime_bin "$RUNTIME")"; PROMPT="$(cat "$PROMPT_FILE")"; [ -n "$PROMPT" ] || machine_error prompt_empty 'prompt file must not be empty'
    ;;
  *)
    usage
    machine_error unknown_command "$COMMAND"
    ;;
esac

node "$RUNTIME_REGISTRY" is-registered "$RUNTIME" >/dev/null || machine_error unknown_runtime 'runtime must be codex, claude, or opencode'
export RUNTIME ROLE MODE CWD PROMPT_FILE MODEL EFFORT OPENCODE_PERMISSION_FILE ISSUE_N PRODUCE_REVIEW BIN PROMPT
exec "$SCRIPT_DIR/runtimes/$RUNTIME.sh" "$COMMAND"
