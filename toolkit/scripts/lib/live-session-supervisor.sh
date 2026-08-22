#!/usr/bin/env bash
# Adapter-agnostic live session state machine.
#
# This file is sourced by dispatch-core.sh. It owns only the normalized
# sequence and timeout policy; adapter files own vendor commands and runtime
# launch-spec files remain opaque. The initial function stops after
# ready -> send -> observed activity, because LIVE.json is a launch/liveness
# acknowledgement rather than workflow completion. The settled and artifact
# gate functions are exposed for the completion owner to call later.
# bash-3.2-compatible: no associative arrays, mapfile, or lowercase expansion.

LIVE_SESSION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LIVE_SESSION_HANDLE_RESULT="$LIVE_SESSION_LIB_DIR/handle-result.cjs"
LIVE_SESSION_TRANSPORT_REGISTRY="$LIVE_SESSION_LIB_DIR/transport-registry.cjs"

LIVE_WAIT_READY_TIMEOUT_MS="${LIVE_WAIT_READY_TIMEOUT_MS:-240000}"
LIVE_SEND_ACTIVITY_TIMEOUT_MS="${LIVE_SEND_ACTIVITY_TIMEOUT_MS:-180000}"
LIVE_WAIT_SETTLED_TIMEOUT_MS="${LIVE_WAIT_SETTLED_TIMEOUT_MS:-180000}"
LIVE_SESSION_TIMEOUT_MS="${LIVE_SESSION_TIMEOUT_MS:-3600000}"
LIVE_POLL_INTERVAL_MS="${LIVE_POLL_INTERVAL_MS:-100}"

LIVE_SESSION_JSON=""
LIVE_LIVE_JSON=""
LIVE_HANDLES_JSON=""
LIVE_EXTERNAL_HANDLE=""
LIVE_LIFECYCLE=""
LIVE_FAILURE_CODE=""
LIVE_FAILURE_DETAIL=""
LIVE_ACTIVITY_OBSERVED=0
LIVE_CANONICAL_ARTIFACT_FRESH=0
LIVE_SETTLED_STATE=""
LIVE_TMP_DIR=""

live_session_is_integer() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

live_session_validate_timeouts() {
  live_session_is_integer "$LIVE_WAIT_READY_TIMEOUT_MS" || return 1
  live_session_is_integer "$LIVE_SEND_ACTIVITY_TIMEOUT_MS" || return 1
  live_session_is_integer "$LIVE_WAIT_SETTLED_TIMEOUT_MS" || return 1
  live_session_is_integer "$LIVE_SESSION_TIMEOUT_MS" || return 1
  live_session_is_integer "$LIVE_POLL_INTERVAL_MS" || return 1
  [ "$LIVE_WAIT_READY_TIMEOUT_MS" -gt 0 ] || return 1
  [ "$LIVE_SEND_ACTIVITY_TIMEOUT_MS" -gt 0 ] || return 1
  [ "$LIVE_WAIT_SETTLED_TIMEOUT_MS" -gt 0 ] || return 1
  [ "$LIVE_SESSION_TIMEOUT_MS" -gt 0 ] || return 1
  return 0
}

live_session_now_ms() {
  node -e 'process.stdout.write(String(Date.now()))'
}

live_session_sleep_ms() {
  live_sleep_ms="$1"
  [ "$live_sleep_ms" -gt 0 ] || return 0
  live_sleep_seconds="$(node -e 'process.stdout.write(String(Number(process.argv[1]) / 1000))' "$live_sleep_ms")"
  sleep "$live_sleep_seconds"
}

live_session_cleanup_tmp() {
  if [ -n "$LIVE_TMP_DIR" ] && [ -d "$LIVE_TMP_DIR" ]; then
    rm -rf "$LIVE_TMP_DIR"
  fi
  LIVE_TMP_DIR=""
}

live_session_fail() {
  LIVE_FAILURE_CODE="$1"
  LIVE_FAILURE_DETAIL="${2:-}"
  live_session_cleanup_tmp
  return 1
}

live_session_write_session() {
  node - "$LIVE_SESSION_JSON" "$1" "$2" "$3" "$4" "$5" <<'NODE'
const fs = require("fs");
const [file, adapter, name, worktree, normalized, launchedAt] = process.argv.slice(2);
try {
  const result = JSON.parse(normalized);
  const value = {
    schema_version: "1",
    execution_mode: "live-tui",
    adapter,
    name,
    worktree_path: worktree,
    lifecycle: result.lifecycle,
    handles: result.handles,
    launched_at: launchedAt,
  };
  if (result.external_handle !== undefined) value.external_handle = result.external_handle;
  const temp = `${file}.tmp-${process.pid}`;
  fs.writeFileSync(temp, JSON.stringify(value, null, 2) + "\n", { mode: 0o600 });
  fs.renameSync(temp, file);
} catch (_) { process.exit(2); }
NODE
}

live_session_write_ack() {
  node - "$LIVE_LIVE_JSON" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" <<'NODE'
const fs = require("fs");
const [file, issue, adapter, worktree, lifecycle, handlesJson, externalHandle, readyAt, promptStartedAt] = process.argv.slice(2);
try {
  const handles = JSON.parse(handlesJson);
  const value = {
    schema_version: "1",
    artifact_type: "live_session",
    authoritative: false,
    issue: Number(issue),
    execution_mode: "live-tui",
    adapter,
    worktree_path: worktree,
    lifecycle,
    handles,
    prompt_delivery: "transport",
    ready_at: readyAt,
    prompt_started_at: promptStartedAt,
    activity_observed: true,
    state: "prompt_started",
  };
  if (externalHandle) value.external_handle = externalHandle;
  const temp = `${file}.tmp-${process.pid}`;
  fs.writeFileSync(temp, JSON.stringify(value, null, 2) + "\n", { mode: 0o600 });
  fs.renameSync(temp, file);
} catch (_) { process.exit(2); }
NODE
}

live_session_output_is_abnormal() {
  node - "$1" <<'NODE'
const fs = require("fs");
const file = process.argv[2];
try {
  const raw = fs.readFileSync(file, "utf8").trim();
  let value;
  try { value = JSON.parse(raw); } catch (_) { value = raw; }
  const candidates = typeof value === "string" ? [value]
    : [value && value.state, value && value.status, value && value.lifecycle];
  const abnormal = ["terminal", "exited", "abnormal_termination", "session_closed"];
  process.exit(candidates.some(entry => abnormal.indexOf(entry) !== -1) ? 0 : 1);
} catch (_) { process.exit(1); }
NODE
}

# live_session_start <adapter-script> <adapter> <name> <worktree>
#   <launch-spec> <prompt-file> <live-dir> <issue>
live_session_start() {
  [ "$#" -eq 8 ] || { LIVE_FAILURE_CODE="live_session_arguments_invalid"; return 1; }
  live_adapter_script="$1"
  live_adapter="$2"
  live_name="$3"
  live_worktree="$4"
  live_launch_spec="$5"
  live_prompt_file="$6"
  live_dir="$7"
  live_issue="$8"
  LIVE_FAILURE_CODE=""
  LIVE_FAILURE_DETAIL=""
  LIVE_ACTIVITY_OBSERVED=0
  LIVE_CANONICAL_ARTIFACT_FRESH=0
  LIVE_HANDLES_JSON=""
  LIVE_EXTERNAL_HANDLE=""
  LIVE_LIFECYCLE=""
  LIVE_SETTLED_STATE=""
  LIVE_SESSION_JSON="$live_dir/session.json"
  LIVE_LIVE_JSON="$live_dir/LIVE.json"

  live_session_validate_timeouts || {
    LIVE_FAILURE_CODE="live_timeout_config_invalid"
    return 1
  }
  [ -x "$live_adapter_script" ] || { LIVE_FAILURE_CODE="live_adapter_missing"; return 1; }
  [ -f "$live_launch_spec" ] || { LIVE_FAILURE_CODE="live_launch_spec_missing"; return 1; }
  [ -f "$live_prompt_file" ] || { LIVE_FAILURE_CODE="live_prompt_missing"; return 1; }
  [ -d "$live_dir" ] || { LIVE_FAILURE_CODE="live_evidence_dir_missing"; return 1; }
  LIVE_TMP_DIR="$(mktemp -d "$live_dir/.supervisor.XXXXXX")" || {
    LIVE_FAILURE_CODE="live_supervisor_temp_unavailable"
    return 1
  }

  live_started_at="$(live_session_now_ms)"
  if live_launch_raw="$(bash "$live_adapter_script" launch-live --name "$live_name" --worktree "$live_worktree" --launch-spec "$live_launch_spec" 2>"$LIVE_TMP_DIR/launch.stderr")"; then
    :
  else
    live_status=$?
    live_session_fail live_launch_failed "adapter_exit=$live_status"
    return 1
  fi
  live_normalized="$(node "$LIVE_SESSION_HANDLE_RESULT" normalize "$live_launch_raw")" || {
    live_session_fail live_launch_result_invalid
    return 1
  }
  LIVE_HANDLES_JSON="$(node -e 'const v=JSON.parse(process.argv[1]); process.stdout.write(JSON.stringify(v.handles));' "$live_normalized")" || {
    live_session_fail live_handles_invalid
    return 1
  }
  LIVE_LIFECYCLE="$(node -e 'const v=JSON.parse(process.argv[1]); process.stdout.write(v.lifecycle);' "$live_normalized")" || {
    live_session_fail live_lifecycle_invalid
    return 1
  }
  LIVE_EXTERNAL_HANDLE="$(node -e 'const v=JSON.parse(process.argv[1]); if (v.external_handle) process.stdout.write(v.external_handle);' "$live_normalized")"
  live_session_write_session "$live_adapter" "$live_name" "$live_worktree" "$live_normalized" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" || {
    live_session_fail live_session_json_write_failed
    return 1
  }

  if bash "$live_adapter_script" wait-ready --session-json "$LIVE_SESSION_JSON" --timeout-ms "$LIVE_WAIT_READY_TIMEOUT_MS" >"$LIVE_TMP_DIR/ready.out" 2>"$LIVE_TMP_DIR/ready.err"; then
    :
  else
    live_status=$?
    live_session_fail live_ready_timeout "adapter_exit=$live_status"
    return 1
  fi
  live_ready_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  if bash "$live_adapter_script" read --session-json "$LIVE_SESSION_JSON" >"$LIVE_TMP_DIR/baseline.out" 2>"$LIVE_TMP_DIR/baseline.err"; then
    :
  else
    live_status=$?
    live_session_fail live_baseline_read_failed "adapter_exit=$live_status"
    return 1
  fi

  if bash "$live_adapter_script" send --session-json "$LIVE_SESSION_JSON" --input-file "$live_prompt_file" >"$LIVE_TMP_DIR/send.out" 2>"$LIVE_TMP_DIR/send.err"; then
    :
  else
    live_status=$?
    live_session_fail live_send_failed "adapter_exit=$live_status"
    return 1
  fi

  live_activity_started="$(live_session_now_ms)"
  while :; do
    live_now="$(live_session_now_ms)"
    live_activity_elapsed=$((live_now - live_activity_started))
    live_session_elapsed=$((live_now - live_started_at))
    if [ "$live_activity_elapsed" -ge "$LIVE_SEND_ACTIVITY_TIMEOUT_MS" ]; then
      live_session_fail live_session_stale
      return 1
    fi
    if [ "$live_session_elapsed" -ge "$LIVE_SESSION_TIMEOUT_MS" ]; then
      live_session_fail live_session_timeout
      return 1
    fi
    if bash "$live_adapter_script" read --session-json "$LIVE_SESSION_JSON" >"$LIVE_TMP_DIR/current.out" 2>"$LIVE_TMP_DIR/current.err"; then
      if live_session_output_is_abnormal "$LIVE_TMP_DIR/current.out"; then
        live_session_fail adapter_abnormal_termination
        return 1
      fi
      if ! cmp -s "$LIVE_TMP_DIR/baseline.out" "$LIVE_TMP_DIR/current.out"; then
        LIVE_ACTIVITY_OBSERVED=1
        live_prompt_started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        live_session_write_ack "$live_issue" "$live_adapter" "$live_worktree" "$LIVE_LIFECYCLE" "$LIVE_HANDLES_JSON" "$LIVE_EXTERNAL_HANDLE" "$live_ready_at" "$live_prompt_started_at" || {
          live_session_fail live_ack_write_failed
          return 1
        }
        live_session_cleanup_tmp
        return 0
      fi
    else
      live_status=$?
      if [ "$LIVE_ACTIVITY_OBSERVED" -eq 1 ]; then
        live_session_fail transport_disconnect_after_activity "adapter_exit=$live_status"
      else
        live_session_fail live_activity_read_failed "adapter_exit=$live_status"
      fi
      return 1
    fi
    live_session_sleep_ms "$LIVE_POLL_INTERVAL_MS"
  done
}

# live_session_wait_settled <adapter-script> <session-json> <timeout-ms>
# Maps adapter output to the shared enum. A non-settled state is returned as a
# nonzero status and is never interpreted as success by this helper.
live_session_wait_settled() {
  [ "$#" -eq 3 ] || { LIVE_FAILURE_CODE="live_settled_arguments_invalid"; return 1; }
  live_settled_adapter="$1"
  live_settled_session="$2"
  live_settled_timeout="$3"
  live_settled_raw="$(bash "$live_settled_adapter" wait-settled --session-json "$live_settled_session" --timeout-ms "$live_settled_timeout")" || {
    LIVE_FAILURE_CODE="live_settled_query_failed"
    return 1
  }
  LIVE_SETTLED_STATE="$(node - "$live_settled_raw" "$LIVE_SESSION_TRANSPORT_REGISTRY" <<'NODE'
const [raw, registry] = process.argv.slice(2);
try {
  const allowed = require(registry).LIVE_SETTLED_STATES;
  let value;
  try { value = JSON.parse(raw); } catch (_) { value = raw.trim(); }
  const candidates = typeof value === "string" ? [value]
    : [value && value.state, value && value.status, value && value.lifecycle];
  const state = candidates.find(entry => allowed.indexOf(entry) !== -1);
  if (!state) process.exit(2);
  process.stdout.write(state);
} catch (_) { process.exit(2); }
NODE
)" || {
    LIVE_FAILURE_CODE="live_settled_state_invalid"
    return 1
  }
  case "$LIVE_SETTLED_STATE" in
    settled) return 0 ;;
    working) LIVE_FAILURE_CODE="live_settled_working"; return 1 ;;
    blocked) LIVE_FAILURE_CODE="live_settled_blocked"; return 1 ;;
    stale) LIVE_FAILURE_CODE="live_settled_stale"; return 1 ;;
    terminal) LIVE_FAILURE_CODE="live_settled_terminal"; return 1 ;;
  esac
}

live_session_artifact_signature() {
  node - "$1" <<'NODE'
const fs = require("fs");
const file = process.argv[2];
try {
  const stat = fs.statSync(file, { bigint: true });
  let started = "";
  try { started = String(JSON.parse(fs.readFileSync(file, "utf8")).started_at || ""); } catch (_) {}
  process.stdout.write(`${stat.mtimeNs}|${started}`);
} catch (_) { process.stdout.write("0|"); }
NODE
}

# live_session_artifact_gate <issue> <worktree> <run-before-sig>
#   <blocker-before-sig> <timeout-ms> [poll-ms]
# This is deliberately an artifact freshness gate, not a screen/idle gate.
# The caller still applies the canonical RUN/BLOCKER schema checks.
live_session_artifact_gate() {
  [ "$#" -ge 5 ] || { LIVE_FAILURE_CODE="live_artifact_gate_arguments_invalid"; return 1; }
  live_gate_issue="$1"
  live_gate_worktree="$2"
  live_gate_run_before="$3"
  live_gate_blocker_before="$4"
  live_gate_timeout="$5"
  live_gate_poll="${6:-$LIVE_POLL_INTERVAL_MS}"
  live_gate_run="$live_gate_worktree/.review/ISSUE-${live_gate_issue}-RUN.json"
  live_gate_blocker="$live_gate_worktree/.review/ISSUE-${live_gate_issue}-BLOCKER.json"
  live_gate_started="$(live_session_now_ms)"
  LIVE_CANONICAL_ARTIFACT_FRESH=0
  while :; do
    if [ -f "$live_gate_blocker" ] && [ "$(live_session_artifact_signature "$live_gate_blocker")" != "$live_gate_blocker_before" ]; then
      LIVE_CANONICAL_ARTIFACT_FRESH=1
      return 0
    fi
    if [ -f "$live_gate_run" ] && [ "$(live_session_artifact_signature "$live_gate_run")" != "$live_gate_run_before" ]; then
      LIVE_CANONICAL_ARTIFACT_FRESH=1
      return 0
    fi
    live_gate_now="$(live_session_now_ms)"
    if [ $((live_gate_now - live_gate_started)) -ge "$live_gate_timeout" ]; then
      LIVE_FAILURE_CODE="live_settled_without_artifact"
      return 1
    fi
    live_session_sleep_ms "$live_gate_poll"
  done
}

live_session_should_stash() {
  case "${1:-$LIVE_FAILURE_CODE}" in
    adapter_abnormal_termination|transport_disconnect_after_activity) return 0 ;;
    *) return 1 ;;
  esac
}
