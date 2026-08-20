#!/usr/bin/env bash
# OpenCode runtime member: deny-first permission mapping and invocation.
# bash-3.2 compatible.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
machine_error() { printf '{"ok":false,"code":"%s","detail":"%s"}\n' "$1" "$2" >&2; exit 3; }
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

COMMAND="${1:-}"
case "$COMMAND" in
  permission-file)
    if [ -z "$OPENCODE_PERMISSION_FILE" ]; then
      if [ "$ROLE" = "implementation" ]; then
        OPENCODE_PERMISSION_FILE="$SCRIPT_DIR/opencode-write.json"
      else
        OPENCODE_PERMISSION_FILE="$SCRIPT_DIR/opencode-read.json"
      fi
    fi
    case "$OPENCODE_PERMISSION_FILE" in
      /*) ;;
      *) OPENCODE_PERMISSION_FILE="$CWD/$OPENCODE_PERMISSION_FILE" ;;
    esac
    [ -r "$OPENCODE_PERMISSION_FILE" ] || { echo "ERROR: opencode_permission_config_missing: $OPENCODE_PERMISSION_FILE" >&2; exit 2; }
    printf '%s\n' "$OPENCODE_PERMISSION_FILE"
    exit 0
    ;;
  probe)
    OPENCODE_CONFIG_CONTENT="$(cat "$OPENCODE_PERMISSION_FILE")"; export OPENCODE_CONFIG_CONTENT
    set -- "$BIN" run --dir "$CWD" --format default --agent agent-workflow --model "$MODEL" --variant "$EFFORT" "reply exactly OK"
    exec "$@"
    ;;
  run) ;;
  *) exit 2;;
esac

validate_opencode_permissions "$OPENCODE_PERMISSION_FILE" "$MODE"
# Inline content has higher precedence than target/global config. Passing
# the named primary agent is required: an unknown/default agent may fall
# back to OpenCode's built-in build agent, which is not an isolation path.
OPENCODE_CONFIG_CONTENT="$(cat "$OPENCODE_PERMISSION_FILE")"; export OPENCODE_CONFIG_CONTENT
set -- "$BIN" run --dir "$CWD" --format json --agent agent-workflow
[ -n "$MODEL" ] && set -- "$@" --model "$MODEL"; [ -n "$EFFORT" ] && set -- "$@" --variant "$EFFORT"; exec "$@" "$PROMPT"
