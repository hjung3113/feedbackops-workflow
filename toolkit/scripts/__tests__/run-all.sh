#!/usr/bin/env bash
# Run all smoke tests in this directory.
# bash-3.2-compatible. Run: bash scripts/__tests__/run-all.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SELF="$(basename "$0")"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

LIST_FILE="$TMP_DIR/smokes.txt"
find "$SCRIPT_DIR" -maxdepth 1 -type f -name '*.smoke.sh' ! -name "$SELF" -print | sort > "$LIST_FILE"

if [ "${1:-}" = "--list" ]; then
  while IFS= read -r smoke; do
    [ -n "$smoke" ] || continue
    basename "$smoke"
  done < "$LIST_FILE"
  exit 0
fi

if [ $# -gt 0 ]; then
  echo "usage: $SELF [--list]" >&2
  exit 2
fi

TOTAL=0
PASSED=0

while IFS= read -r smoke; do
  [ -n "$smoke" ] || continue
  name="$(basename "$smoke")"
  TOTAL=$((TOTAL + 1))
  bash "$smoke" > "$TMP_DIR/$name.out" 2>&1
  ec=$?
  if [ "$ec" -eq 0 ]; then
    echo "ok - $name"
    PASSED=$((PASSED + 1))
  else
    echo "NOT OK - $name (exit $ec)"
  fi
done < "$LIST_FILE"

echo "--- $PASSED/$TOTAL passed"

if [ "$PASSED" -eq "$TOTAL" ]; then
  exit 0
fi

exit 1
