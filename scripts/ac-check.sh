#!/usr/bin/env bash
# ac-check.sh — verify that ROUND-STATE AC ids exist in discovered test names.
#
# Usage: scripts/ac-check.sh --round-state <json-file> --manifest-revision <n> --tests <text-file>
#
# Exit 0 = all ACs mapped; 1 = one or more findings; 2 = usage/input error.
# bash-3.2-compatible: no associative arrays, no ${var,,}, no mapfile.
set -u

PROG="ac-check"
round_state=""
expected_revision=""
tests=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --round-state)
      if [ "$#" -lt 2 ]; then
        echo "$PROG: ERROR — --round-state requires a file" >&2
        exit 2
      fi
      round_state="$2"
      shift 2
      ;;
    --manifest-revision)
      if [ "$#" -lt 2 ]; then
        echo "$PROG: ERROR — --manifest-revision requires a positive integer" >&2
        exit 2
      fi
      expected_revision="$2"
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
      echo "$PROG: usage: $0 --round-state <json-file> --manifest-revision <n> --tests <text-file>" >&2
      exit 2
      ;;
  esac
done

if [ -z "$round_state" ] || [ -z "$expected_revision" ] || [ -z "$tests" ]; then
  echo "$PROG: usage: $0 --round-state <json-file> --manifest-revision <n> --tests <text-file>" >&2
  exit 2
fi

case "$expected_revision" in
  ''|*[!0-9]*|0)
    echo "$PROG: ERROR — --manifest-revision requires a positive integer" >&2
    exit 2
    ;;
esac

if [ ! -f "$round_state" ] || [ ! -r "$round_state" ]; then
  echo "$PROG: ERROR — ROUND-STATE not found or unreadable: $round_state" >&2
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

# Validate the acceptance section and emit its revision followed by one id per line.
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
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    console.error("ROUND-STATE must be an object");
    process.exit(1);
  }
  if (value.schema_version !== "1" || value.artifact_type !== "round_state") {
    console.error("input must be a schema_version 1 round_state artifact");
    process.exit(1);
  }
  if (value.producer_role !== "CONDUCTOR") {
    console.error("ROUND-STATE producer_role must be CONDUCTOR");
    process.exit(1);
  }
  if (value.lifecycle !== "active" && value.lifecycle !== "final") {
    console.error("ROUND-STATE lifecycle must be active or final");
    process.exit(1);
  }
  if (!value.acceptance || typeof value.acceptance !== "object" || Array.isArray(value.acceptance)) {
    console.error("ROUND-STATE must contain an acceptance object");
    process.exit(1);
  }
  if (!Number.isInteger(value.revision) || value.revision < 1) {
    console.error("ROUND-STATE revision must be a positive integer");
    process.exit(1);
  }
  const acceptance = value.acceptance;
  if (!Array.isArray(acceptance.criteria) || acceptance.criteria.length === 0) {
    console.error("acceptance.criteria must be a non-empty array");
    process.exit(1);
  }
  process.stdout.write(String(value.revision) + "\n");
  for (const ac of acceptance.criteria) {
    if (!ac || Array.isArray(ac) || typeof ac.id !== "string" || ac.id.length === 0 || /[\r\n]/.test(ac.id)) {
      console.error("each ac must contain a non-empty single-line string id");
      process.exit(1);
    }
    process.stdout.write(ac.id + "\n");
  }
' "$round_state" > "$ids_file"
node_status=$?
if [ "$node_status" -ne 0 ]; then
  echo "$PROG: ERROR — invalid ROUND-STATE acceptance section: $round_state" >&2
  exit 2
fi

actual_revision="$(sed -n '1p' "$ids_file")"
if [ "$actual_revision" != "$expected_revision" ]; then
  printf 'STALE expected revision %s, found %s\n' "$expected_revision" "$actual_revision"
  exit 1
fi

sed '1d' "$ids_file" > "${ids_file}.criteria"
mv "${ids_file}.criteria" "$ids_file"
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
  printf 'OK revision %s: %s acs mapped\n' "$actual_revision" "$ac_count"
  exit 0
fi
exit 1
