#!/usr/bin/env bash
# tier-probe.sh — advisory probe: is the Trivial tier DISALLOWED for a touch set?
#
# Usage: scripts/tier-probe.sh <file> [<file>...]
#
# Exit codes:
#   1 = Trivial DISALLOWED (escalate)
#   0 = Trivial permissible
#   2 = usage error
#
# CRITICAL framing (codex review R2): this answers ONE question —
# "is the Trivial tier DISALLOWED?" — NOT "is this change safe?".
# False positives (disallowing Trivial when it might've been fine) are
# ACCEPTABLE. False negatives (allowing Trivial when a contract changed)
# are the HARM. The probe is biased to DISALLOW. It is ADVISORY only:
# the authoritative blast-radius oracle is `scripts/verify.sh --typecheck`,
# which must still cover importers.
#
# Trial #33: narrowing one exported TS type in a "single file" broke 5
# importing modules. File count is NOT the tier. An exported-contract
# change — or any ambiguous exported-TS change — forbids Trivial.
#
# bash-3.2-compatible: no `declare -A`, no `${var,,}`.
set -u

if [ "$#" -lt 1 ]; then
  echo "usage: $(basename "$0") <file> [<file>...]" >&2
  exit 2
fi

DISALLOW=0
REASONS=""

note_reason() {
  REASONS="$REASONS
  - $1"
}

# diff_for_file <file> — concatenate the best-available diff source.
# Try git diff HEAD, then --cached, then fall back to git show HEAD
# (covers a just-committed change).
diff_for_file() {
  f="$1"
  out="$(git diff HEAD -- "$f" 2>/dev/null)"
  if [ -z "$out" ]; then
    out="$(git diff --cached -- "$f" 2>/dev/null)"
  fi
  if [ -z "$out" ]; then
    out="$(git show HEAD -- "$f" 2>/dev/null)"
  fi
  printf '%s' "$out"
}

# changed_content_lines <diff> — emit only added/removed *content* lines
# (strip the diff markers), excluding the +++/--- file headers.
changed_content_lines() {
  printf '%s\n' "$1" | grep -E '^[+-]' | grep -Ev '^(\+\+\+|---)' | sed -E 's/^[+-]//'
}

for f in "$@"; do
  case "$f" in
    *.ts|*.tsx) : ;;  # TS file: can change a TS contract
    *) continue ;;    # non-TS: cannot disallow Trivial on its own
  esac

  # Rule 1: barrel / re-export surface — contract by nature.
  case "$f" in
    */index.ts|*/index.tsx|index.ts|index.tsx)
      DISALLOW=1
      note_reason "$f: barrel/re-export surface (index.ts/tsx) — contract by nature"
      continue
      ;;
  esac

  diff="$(diff_for_file "$f")"
  [ -z "$diff" ] && continue

  changed="$(changed_content_lines "$diff")"
  [ -z "$changed" ] && continue

  # Rule 2: exported-contract patterns among changed (+/-) content lines.
  if printf '%s\n' "$changed" | grep -Eq \
      'export (interface|type|class|abstract class|enum|function|const)|export default|export \{|export \*|export .* from'; then
    DISALLOW=1
    note_reason "$f: exported declaration / re-export changed (export interface|type|class|enum|function|const|default|{|*|... from)"
    continue
  fi

  # constructor signature: flag if the file declares a constructor anywhere
  # and the diff touches that file at all.
  if grep -q 'constructor(' "$f" 2>/dev/null; then
    DISALLOW=1
    note_reason "$f: file declares a constructor( and was touched — constructor signature is suspect"
    continue
  fi

  # `as const` literal-type assertion.
  if printf '%s\n' "$changed" | grep -q 'as const'; then
    DISALLOW=1
    note_reason "$f: 'as const' literal-type assertion changed"
    continue
  fi

  # generic constraint change: a +/- line containing both '<' and 'extends'.
  if printf '%s\n' "$changed" | grep -q '<' && \
     printf '%s\n' "$changed" | grep -E '<' | grep -q 'extends'; then
    DISALLOW=1
    note_reason "$f: generic constraint change (line with '<' and 'extends')"
    continue
  fi

  # Rule 3: catch-all anti-false-negative bias.
  # If the file contains ANY `export` keyword AND the diff is not provably
  # comment/whitespace-only, DISALLOW. "Provably comment/whitespace-only" =
  # every changed content line, after stripping leading whitespace, starts
  # with //, /*, *, */, or is blank.
  if grep -q 'export' "$f" 2>/dev/null; then
    non_comment="$(printf '%s\n' "$changed" \
      | sed -E 's/^[[:space:]]+//' \
      | grep -Ev '^(//|/\*|\*/|\*|$)')"
    if [ -n "$non_comment" ]; then
      DISALLOW=1
      note_reason "$f: exported-TS file with non-comment/whitespace diff (ambiguous — non-Trivial unless proven otherwise)"
      continue
    fi
  fi
done

if [ "$DISALLOW" -eq 1 ]; then
  echo "TRIVIAL DISALLOWED — escalate beyond Trivial tier."
  echo "Tripped by:$REASONS"
  echo ""
  echo "Next: escalate the tier and run 'scripts/verify.sh --typecheck' —"
  echo "the authoritative blast-radius oracle — to confirm importers are covered."
  exit 1
fi

echo "Trivial permissible by this probe."
echo "REMINDER: the probe is advisory and only answers 'is Trivial disallowed?'."
echo "Still run 'scripts/verify.sh --typecheck' — the authoritative blast-radius"
echo "oracle — which must cover importing modules before you ship as Trivial."
exit 0
