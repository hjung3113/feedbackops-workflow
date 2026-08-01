#!/usr/bin/env bash
# ac-check.sh — verify that ROUND-STATE AC ids exist in discovered test names.
#
# Usage: scripts/ac-check.sh --round-state <json-file> --manifest-revision <n> --tests <text-file>
#
# Exit 0 = all ACs mapped; 1 = one or more findings; 2 = usage/input error.
# bash-3.2-compatible: no associative arrays, no ${var,,}, no mapfile.
set -u

PROG="ac-check"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PRODUCT_HOME_LIB="$SCRIPT_DIR/lib/product-home.sh"
SCHEMA_VALIDATOR="$SCRIPT_DIR/lib/json-schema-subset.cjs"
FRESH_CHECK="$SCRIPT_DIR/artifact-fresh.sh"
round_state=""
expected_revision=""
tests=""

if [ ! -r "$PRODUCT_HOME_LIB" ]; then
  echo "$PROG: ERROR — product-home resolver is missing: $PRODUCT_HOME_LIB" >&2
  exit 2
fi
. "$PRODUCT_HOME_LIB"
PRODUCT_ROOT="$(agent_workflow_product_root "$SCRIPT_DIR")"
SCHEMA_DIR="$(agent_workflow_schema_dir "$PRODUCT_ROOT")" || {
  echo "$PROG: ERROR — product schemas are missing beneath: $PRODUCT_ROOT" >&2
  exit 2
}
ROUND_STATE_SCHEMA="$SCHEMA_DIR/round_state.schema.json"

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
if [ ! -f "$SCHEMA_VALIDATOR" ] || [ ! -r "$SCHEMA_VALIDATOR" ]; then
  echo "$PROG: ERROR — schema validator is missing: $SCHEMA_VALIDATOR" >&2
  exit 2
fi
if [ ! -f "$ROUND_STATE_SCHEMA" ] || [ ! -r "$ROUND_STATE_SCHEMA" ]; then
  echo "$PROG: ERROR — ROUND-STATE schema is missing: $ROUND_STATE_SCHEMA" >&2
  exit 2
fi
if [ ! -x "$FRESH_CHECK" ]; then
  echo "$PROG: ERROR — artifact freshness checker is missing: $FRESH_CHECK" >&2
  exit 2
fi

ids_file="$(mktemp "${TMPDIR:-/tmp}/ac-check.XXXXXX")" || {
  echo "$PROG: ERROR — could not create temporary file" >&2
  exit 2
}
trap 'rm -f "$ids_file"' EXIT

# Validate against the canonical schema and emit its revision followed by one id per line.
node -e '
  const fs = require("fs");
  const file = process.argv[1];
  const schema = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  const { validate } = require(process.argv[3]);
  let value;
  try {
    value = JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (error) {
    console.error("parse error: " + error.message);
    process.exit(1);
  }
  const errors = validate(schema, value);
  if (errors.length > 0) {
    console.error("schema validation failed: " + JSON.stringify(errors));
    process.exit(1);
  }
  if (value.lifecycle !== "active" && value.lifecycle !== "final") {
    console.error("ROUND-STATE lifecycle must be active or final for a gate");
    process.exit(1);
  }
  const acceptance = value.acceptance;
  process.stdout.write(String(value.revision) + "\n");
  for (const ac of acceptance.criteria) {
    if (!ac || Array.isArray(ac) || typeof ac.id !== "string" || ac.id.length === 0 || /[\r\n]/.test(ac.id)) {
      console.error("each ac must contain a non-empty single-line string id");
      process.exit(1);
    }
    process.stdout.write(ac.id + "\n");
  }
' "$round_state" "$ROUND_STATE_SCHEMA" "$SCHEMA_VALIDATOR" > "$ids_file"
node_status=$?
if [ "$node_status" -ne 0 ]; then
  echo "$PROG: ERROR — invalid ROUND-STATE acceptance section: $round_state" >&2
  exit 2
fi

bash "$FRESH_CHECK" "$round_state" >/dev/null
fresh_status=$?
if [ "$fresh_status" -eq 1 ]; then
  printf 'STALE ROUND-STATE freshness check failed\n'
  exit 1
elif [ "$fresh_status" -ne 0 ]; then
  echo "$PROG: ERROR — ROUND-STATE freshness check failed" >&2
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
  node -e '
    const fs = require("fs");
    const id = process.argv[1];
    const file = process.argv[2];
    let text;
    try { text = fs.readFileSync(file, "utf8"); }
    catch (error) { console.error(error.message); process.exit(2); }
    const escaped = id.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const pattern = new RegExp("(^|[^A-Za-z0-9_.-])" + escaped + "([^A-Za-z0-9_.-]|$)", "m");
    process.exit(pattern.test(text) ? 0 : 1);
  ' "$id" "$tests"
  match_status=$?
  if [ "$match_status" -eq 1 ]; then
    printf 'MISSING %s: no discovered test name contains "%s"\n' "$id" "$id"
    violations=1
  elif [ "$match_status" -ne 0 ]; then
    echo "$PROG: ERROR — could not read tests file: $tests" >&2
    exit 2
  fi
done < "$ids_file"

if [ "$violations" -eq 0 ]; then
  printf 'OK revision %s: %s acs mapped\n' "$actual_revision" "$ac_count"
  exit 0
fi
exit 1
