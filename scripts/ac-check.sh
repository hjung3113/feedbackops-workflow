#!/usr/bin/env bash
# ac-check.sh — verify that manifest AC ids exist in discovered test names.
#
# Usage: scripts/ac-check.sh --manifest <json-file> --tests <text-file>
#
# Exit 0 = all ACs mapped; 1 = one or more findings; 2 = usage/input error.
# bash-3.2-compatible: no associative arrays, no ${var,,}, no mapfile.
set -u

PROG="ac-check"
manifest=""
tests=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --manifest)
      if [ "$#" -lt 2 ]; then
        echo "$PROG: ERROR — --manifest requires a file" >&2
        exit 2
      fi
      manifest="$2"
      shift 2
      ;;
    --tests)
      if [ "$#" -lt 2 ]; then
        echo "$PROG: ERROR — --tests requires a file" >&2
        exit 2
      fi
      tests="$2"
      shift 2
      ;;
    *)
      echo "$PROG: usage: $0 --manifest <json-file> --tests <text-file>" >&2
      exit 2
      ;;
  esac
done

if [ -z "$manifest" ] || [ -z "$tests" ]; then
  echo "$PROG: usage: $0 --manifest <json-file> --tests <text-file>" >&2
  exit 2
fi

if [ ! -f "$manifest" ] || [ ! -r "$manifest" ]; then
  echo "$PROG: ERROR — manifest not found or unreadable: $manifest" >&2
  exit 2
fi
if [ ! -f "$tests" ] || [ ! -r "$tests" ]; then
  echo "$PROG: ERROR — tests file not found or unreadable: $tests" >&2
  exit 2
fi

ids_file="$(mktemp "${TMPDIR:-/tmp}/ac-check.XXXXXX")" || {
  echo "$PROG: ERROR — could not create temporary file" >&2
  exit 2
}
trap 'rm -f "$ids_file"' EXIT

# Validate the manifest shape and emit one id per line for bash processing.
node -e '
  const fs = require("fs");
  const file = process.argv[1];
  let value;
  try {
    value = JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (error) {
    console.error("parse error: " + error.message);
    process.exit(1);
  }
  if (!value || Array.isArray(value) || !Array.isArray(value.acs)) {
    console.error("manifest must contain an acs array");
    process.exit(1);
  }
  for (const ac of value.acs) {
    if (!ac || Array.isArray(ac) || typeof ac.id !== "string" || ac.id.length === 0 || /[\r\n]/.test(ac.id)) {
      console.error("each ac must contain a non-empty single-line string id");
      process.exit(1);
    }
    process.stdout.write(ac.id + "\n");
  }
' "$manifest" > "$ids_file"
node_status=$?
if [ "$node_status" -ne 0 ]; then
  echo "$PROG: ERROR — invalid manifest: $manifest" >&2
  exit 2
fi

ac_count="$(wc -l < "$ids_file" | tr -d ' ')"
seen_file="$(mktemp "${TMPDIR:-/tmp}/ac-check-seen.XXXXXX")" || {
  echo "$PROG: ERROR — could not create temporary file" >&2
  exit 2
}
trap 'rm -f "$ids_file" "$seen_file"' EXIT

violations=0
while IFS= read -r id || [ -n "$id" ]; do
  if grep -F -x -q -- "$id" "$seen_file"; then
    printf 'DUP %s\n' "$id"
    violations=1
    continue
  fi

  printf '%s\n' "$id" >> "$seen_file"
  grep -F -q -- "$id" "$tests"
  match_status=$?
  if [ "$match_status" -eq 0 ]; then
    continue
  elif [ "$match_status" -gt 1 ]; then
    echo "$PROG: ERROR — could not read tests file: $tests" >&2
    exit 2
  fi

  printf 'MISSING %s\n' "$id"
  violations=1
done < "$ids_file"

if [ "$violations" -eq 0 ]; then
  printf 'OK %s acs mapped\n' "$ac_count"
  exit 0
fi
exit 1
