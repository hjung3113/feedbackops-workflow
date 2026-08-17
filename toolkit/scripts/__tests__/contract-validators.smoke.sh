#!/usr/bin/env bash
# Unit smoke for lib/contract-validators.cjs shared predicates.
# bash-3.2-compatible.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VALIDATORS="$SCRIPT_DIR/../lib/contract-validators.cjs"
FAIL=0

pass() { echo "ok   - $1"; }
fail() { echo "NOT OK - $1"; FAIL=$((FAIL + 1)); }

node - "$VALIDATORS" <<'NODE'
const { effortValid, headMatches } = require(process.argv[2]);
const checks = [];
const check = (name, actual, expected) => checks.push([name, actual === expected, actual, expected]);

check("effortValid re-export accepts gpt-5.6-terra/high", effortValid("gpt-5.6-terra", "high"), true);
check("effortValid re-export rejects unknown effort", effortValid("gpt-5.6-terra", "sideways"), false);
check("headMatches accepts equal non-empty heads", headMatches("a".repeat(40), "a".repeat(40)), true);
check("headMatches rejects differing heads", headMatches("a".repeat(40), "b".repeat(40)), false);
check("headMatches fail-closed on empty live head", headMatches("", "a".repeat(40)), false);
check("headMatches fail-closed on empty recorded head", headMatches("a".repeat(40), ""), false);
check("headMatches fail-closed on missing recorded head", headMatches("a".repeat(40), undefined), false);
check("headMatches fail-closed on non-string recorded head", headMatches("a".repeat(40), 123), false);
check("headMatches fail-closed on both empty", headMatches("", ""), false);

let failed = 0;
for (const [name, ok, actual, expected] of checks) {
  if (ok) console.log(`ok   - ${name}`);
  else { console.log(`NOT OK - ${name} (expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)})`); failed += 1; }
}
process.exit(failed ? 1 : 0);
NODE
if [ $? -eq 0 ]; then pass "contract-validators predicates"; else fail "contract-validators predicates"; fi

if [ "$FAIL" -eq 0 ]; then echo "PASS: contract-validators.smoke"; exit 0; fi
echo "FAIL: contract-validators.smoke ($FAIL failed)"; exit 1
