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
  echo "usage: $SELF [--list] [--redact-values-file <path>]" >&2
  exit 2
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
while [ $# -gt 0 ]; do
  case "$1" in
    --redact-values-file)
      [ -z "$REDACT_VALUES_FILE" ] || usage
      [ $# -ge 2 ] || usage
      REDACT_VALUES_FILE="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

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

while IFS= read -r smoke; do
  [ -n "$smoke" ] || continue
  name="$(basename "$smoke")"
  TOTAL=$((TOTAL + 1))
  raw_diagnostic="$LOG_DIR/$name.raw"
  safe_diagnostic="$LOG_DIR/$name.out"
  bash "$smoke" > "$raw_diagnostic" 2>&1
  ec=$?
  if [ "$ec" -eq 0 ]; then
    rm -f "$raw_diagnostic"
    echo "ok - $name"
    PASSED=$((PASSED + 1))
  else
    echo "NOT OK - $name (exit $ec)"
    RETAIN_LOGS=1
    if ! redact_diagnostic "$raw_diagnostic" "$safe_diagnostic"; then
      rm -f "$raw_diagnostic" "$safe_diagnostic"
      echo "diagnostic redaction failed; raw output removed" > "$safe_diagnostic"
    fi
    echo "--- begin $name diagnostic ---"
    cat "$safe_diagnostic"
    echo "--- end $name diagnostic ---"
    echo "diagnostic retained: $safe_diagnostic"
  fi
done < <(list_smokes)

echo "--- $PASSED/$TOTAL passed"

if [ "$PASSED" -eq "$TOTAL" ]; then
  exit 0
fi

echo "diagnostics retained under: $LOG_DIR" >&2
exit 1
