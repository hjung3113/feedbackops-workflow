#!/usr/bin/env bash
# Run all smoke tests in this directory.
# bash-3.2-compatible. Run: bash scripts/__tests__/run-all.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SELF="$(basename "$0")"

list_smokes() {
  find "$SCRIPT_DIR" -maxdepth 1 -type f -name '*.smoke.sh' ! -name "$SELF" -print | sort
}

usage() {
  echo "usage: $SELF [--list] [--redact-values-file <path>] [--for-paths \"<paths>\"]" >&2
  exit 2
}

# look up known-flake registration for a smoke basename. Returns 0 (and sets
# FLAKE_OWNER/FLAKE_EXPIRY/FLAKE_REASON) only for a matching, well-formed,
# registry line. Malformed lines warn on stderr and are treated as absent so a
# bad registry line can never crash the run.
FLAKE_REGISTRY="$SCRIPT_DIR/flake-registry.manifest"
flake_lookup() {
  FLAKE_OWNER=""
  FLAKE_EXPIRY=""
  FLAKE_REASON=""
  [ -f "$FLAKE_REGISTRY" ] || return 1
  while IFS= read -r flake_line; do
    case "$flake_line" in ''|'#'*) continue ;; esac
    flake_smoke="${flake_line%% *}"
    [ "$flake_smoke" = "$1" ] || continue
    flake_rest="${flake_line#* }"
    FLAKE_OWNER="${flake_rest%% *}"
    flake_rest="${flake_rest#* }"
    FLAKE_EXPIRY="${flake_rest%% *}"
    FLAKE_REASON="${flake_rest#* }"
    flake_field_count=0
    for flake_field in $flake_line; do
      flake_field_count=$((flake_field_count + 1))
    done
    case "$FLAKE_EXPIRY" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
      *) FLAKE_EXPIRY="" ;;
    esac
    if [ "$flake_field_count" -ne 4 ] || [ -z "$FLAKE_EXPIRY" ] || [ -z "$FLAKE_REASON" ]; then
      echo "WARNING: malformed flake-registry.manifest line for $1: $flake_line" >&2
      return 1
    fi
    return 0
  done < "$FLAKE_REGISTRY"
  return 1
}

# --list is a read-only inventory query, so it answers before any temporary
# storage is allocated and stays usable when allocation is impossible.
if [ "${1:-}" = "--list" ]; then
  [ $# -eq 1 ] || usage
  list_smokes | while IFS= read -r smoke; do
    [ -n "$smoke" ] || continue
    basename "$smoke"
  done
  exit 0
fi

REDACT_VALUES_FILE=""
FOR_PATHS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --redact-values-file)
      [ -z "$REDACT_VALUES_FILE" ] || usage
      [ $# -ge 2 ] || usage
      REDACT_VALUES_FILE="$2"
      shift 2
      ;;
    --for-paths)
      [ -z "$FOR_PATHS" ] || usage
      [ $# -ge 2 ] || usage
      FOR_PATHS="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

# --for-paths narrows the inventory to smokes whose covering sources match the
# given paths. The manifest maps repo-relative source paths to smoke basenames
# (see smoke-coverage.manifest). Any path with unknown coverage fails open to
# the full suite: an incomplete mapping must never silently skip a real smoke.
SELECTED_SMOKES=""
if [ -n "$FOR_PATHS" ]; then
  case "$FOR_PATHS" in
    *[![:space:]]*) ;;
    *) usage ;;
  esac
  COVERAGE_MANIFEST="$SCRIPT_DIR/smoke-coverage.manifest"
  for given_path in $FOR_PATHS; do
    path_matched=0
    if [ -f "$COVERAGE_MANIFEST" ]; then
      while IFS= read -r manifest_line; do
        case "$manifest_line" in ''|'#'*) continue ;; esac
        manifest_source="${manifest_line%% *}"
        manifest_smoke="${manifest_line#* }"
        case "$manifest_source" in
          "$given_path"|"$given_path"*)
            path_matched=1
            case "$SELECTED_SMOKES" in
              *" $manifest_smoke "*) ;;
              *) SELECTED_SMOKES="$SELECTED_SMOKES $manifest_smoke " ;;
            esac
            ;;
        esac
      done < "$COVERAGE_MANIFEST"
    fi
    if [ "$path_matched" -eq 0 ]; then
      echo "WARNING: $given_path has no known smoke coverage in smoke-coverage.manifest — falling back to the full suite" >&2
      SELECTED_SMOKES=""
      break
    fi
  done
fi

if [ -n "$REDACT_VALUES_FILE" ] && [ ! -f "$REDACT_VALUES_FILE" ]; then
  echo "$SELF: redaction values file is not a readable regular file: $REDACT_VALUES_FILE" >&2
  exit 2
fi
if [ -n "$REDACT_VALUES_FILE" ] && [ ! -r "$REDACT_VALUES_FILE" ]; then
  echo "$SELF: redaction values file is not a readable regular file: $REDACT_VALUES_FILE" >&2
  exit 2
fi

# Captures can briefly contain arbitrary smoke output before redaction. Keep
# their enclosing storage private without changing the smoke child's umask.
ORIGINAL_UMASK="$(umask)"
umask 077
LOG_DIR="$(mktemp -d)" || {
  umask "$ORIGINAL_UMASK"
  echo "$SELF: cannot allocate diagnostic storage" >&2
  exit 2
}
umask "$ORIGINAL_UMASK"
RETAIN_LOGS=0
trap '[ "$RETAIN_LOGS" -eq 1 ] || rm -rf "$LOG_DIR"' EXIT

redact_diagnostic() {
  raw_file="$1"
  safe_file="$2"

  if [ -z "$REDACT_VALUES_FILE" ]; then
    mv "$raw_file" "$safe_file"
    return $?
  fi

  # The values file is an explicit, line-oriented contract: every non-empty
  # line is replaced literally. This deliberately does not claim to discover
  # arbitrary secrets. index()/substr() avoid regex and replacement escaping.
  SMOKE_REDACT_VALUES_FILE="$REDACT_VALUES_FILE" awk '
    function redact_line(line, position, result, best_position, best_length, i) {
      result = ""
      while (length(line) > 0) {
        best_position = 0
        best_length = 0
        for (i = 1; i <= value_count; i++) {
          position = index(line, values[i])
          if (position > 0 && (best_position == 0 || position < best_position || \
              (position == best_position && length(values[i]) > best_length))) {
            best_position = position
            best_length = length(values[i])
          }
        }
        if (best_position == 0) return result line
        result = result substr(line, 1, best_position - 1) "[REDACTED]"
        line = substr(line, best_position + best_length)
      }
      return result
    }
    BEGIN {
      values_file = ENVIRON["SMOKE_REDACT_VALUES_FILE"]
      while ((getline value < values_file) > 0) {
        if (length(value) > 0) values[++value_count] = value
      }
      close(values_file)
    }
    {
      print redact_line($0)
    }
  ' "$raw_file" > "$safe_file"
  redact_ec=$?
  rm -f "$raw_file"
  return "$redact_ec"
}

TOTAL=0
PASSED=0
FLAKY=0
TODAY_UTC="$(date -u +%Y-%m-%d)"

while IFS= read -r smoke; do
  [ -n "$smoke" ] || continue
  name="$(basename "$smoke")"
  if [ -n "$SELECTED_SMOKES" ]; then
    case "$SELECTED_SMOKES" in
      *" $name "*) ;;
      *) continue ;;
    esac
  fi
  TOTAL=$((TOTAL + 1))
  raw_diagnostic="$LOG_DIR/$name.raw"
  safe_diagnostic="$LOG_DIR/$name.out"
  bash "$smoke" < /dev/null > "$raw_diagnostic" 2>&1
  ec=$?
  if [ "$ec" -eq 0 ]; then
    rm -f "$raw_diagnostic"
    echo "ok - $name"
    PASSED=$((PASSED + 1))
  else
    is_known_flake=0
    if flake_lookup "$name" && { [[ "$TODAY_UTC" < "$FLAKE_EXPIRY" ]] || [ "$TODAY_UTC" = "$FLAKE_EXPIRY" ]; }; then
      is_known_flake=1
    fi
    if [ "$is_known_flake" -eq 1 ]; then
      echo "FLAKY - $name (exit $ec, known flake: owner=$FLAKE_OWNER expires=$FLAKE_EXPIRY reason=$FLAKE_REASON)"
    else
      echo "NOT OK - $name (exit $ec)"
    fi
    RETAIN_LOGS=1
    if ! redact_diagnostic "$raw_diagnostic" "$safe_diagnostic"; then
      rm -f "$raw_diagnostic" "$safe_diagnostic"
      echo "diagnostic redaction failed; raw output removed" > "$safe_diagnostic"
    fi
    echo "--- begin $name diagnostic ---"
    cat "$safe_diagnostic"
    echo "--- end $name diagnostic ---"
    echo "diagnostic retained: $safe_diagnostic"
    if [ "$is_known_flake" -eq 1 ]; then
      FLAKY=$((FLAKY + 1))
    fi
  fi
done < <(list_smokes)

if [ "$FLAKY" -gt 0 ]; then
  echo "--- $PASSED/$TOTAL passed ($FLAKY known-flake)"
else
  echo "--- $PASSED/$TOTAL passed"
fi

if [ $((PASSED + FLAKY)) -eq "$TOTAL" ]; then
  exit 0
fi

echo "diagnostics retained under: $LOG_DIR" >&2
exit 1
