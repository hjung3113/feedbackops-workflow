#!/usr/bin/env bash
# artifact-fresh.sh — is a .review artifact still current against its base?
#
# Usage: scripts/artifact-fresh.sh <artifact.json> [<integration-branch-override>]
#
# Exit 0 = fresh (current). Non-zero = stale/error. Callers (readers) MUST
# treat any non-zero result as "artifact invalid", not merely log it.
#
# Freshness is computed against the artifact's OWN declared base_branch (or a
# CLI override), NOT a hardcoded integration branch. If neither exists the
# check REFUSES rather than assuming develop (Codex R8 anti-assumption rule).
#
# bash-3.2-compatible: no associative arrays, no ${var,,}.
set -u

PROG="artifact-fresh"

if [ "$#" -lt 1 ]; then
  echo "$PROG: usage: $0 <artifact.json> [<integration-branch-override>]" >&2
  exit 2
fi

artifact="$1"
override="${2:-}"

if [ ! -f "$artifact" ]; then
  echo "$PROG: ERROR — artifact not found: $artifact" >&2
  exit 2
fi

# Read a top-level string field from the artifact via node. Prints the value
# (empty if absent/null). A non-zero return means the JSON failed to parse.
read_field() {
  node -e '
    const fs = require("fs");
    const f = process.argv[1];
    const key = process.argv[2];
    let v;
    try { v = JSON.parse(fs.readFileSync(f, "utf8")); }
    catch (e) { console.error("parse error: " + e.message); process.exit(1); }
    const val = v[key];
    process.stdout.write(val == null ? "" : String(val));
  ' "$artifact" "$1"
}

# 1. base_sha must exist.
base_sha="$(read_field base_sha)" || {
  echo "$PROG: ERROR — could not parse $artifact" >&2
  exit 2
}
if [ -z "$base_sha" ]; then
  echo "$PROG: ERROR — no base_sha in $artifact" >&2
  exit 2
fi

# 2. Resolve integration branch: override > artifact base_branch > refuse.
if [ -n "$override" ]; then
  branch="$override"
else
  branch="$(read_field base_branch)" || {
    echo "$PROG: ERROR — could not parse $artifact" >&2
    exit 2
  }
fi
if [ -z "$branch" ]; then
  echo "$PROG: ERROR — no base_branch in artifact and no override given — refusing to assume develop" >&2
  exit 2
fi

# 3. Compute merge-base against the resolved branch.
merge_base="$(git merge-base HEAD "$branch" 2>"$artifact.giterr.$$")"
git_status=$?
git_err="$(cat "$artifact.giterr.$$" 2>/dev/null)"
rm -f "$artifact.giterr.$$"
if [ "$git_status" -ne 0 ] || [ -z "$merge_base" ]; then
  echo "$PROG: ERROR — git merge-base HEAD $branch failed: $git_err" >&2
  exit 2
fi

# 4. Compare.
if [ "$base_sha" != "$merge_base" ]; then
  echo "$PROG: STALE — $artifact base_sha=$base_sha but merge-base($branch)=$merge_base" >&2
  exit 1
fi

# 5. Fresh.
echo "$PROG: OK — $artifact is current (base $branch)."
exit 0
