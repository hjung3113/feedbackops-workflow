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
const { effortValid, headMatches, sameJson, loadSchema, VERIFY_ENV_BASE, TARGET_VERIFY_ENV_BASE, verifyEnvAssignments } = require(process.argv[2]);
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
check("sameJson accepts equal values", sameJson({ a: [1, 2] }, { a: [1, 2] }), true);
check("sameJson rejects differing values", sameJson({ a: 1 }, { a: 2 }), false);
check("sameJson is insertion-order sensitive", sameJson([{ x: 1, y: 2 }], [{ y: 2, x: 1 }]), false);
check("sameJson drops undefined like JSON.stringify", sameJson({ a: undefined, b: 1 }, { b: 1 }), true);
const loaded = loadSchema("round_state.schema.json");
check("loadSchema resolves and parses a product schema", loaded.schema && loaded.schema.properties && loaded.schema.properties.artifact_type && typeof loaded.validate === "function", true);
check("loadSchema validator rejects an invalid document", loaded.validate(loaded.schema, {}).length > 0, true);
let threw = false;
try { loadSchema("no-such.schema.json"); } catch (_) { threw = true; }
check("loadSchema fails closed on a missing schema", threw, true);
check("verify.sh env base whitelist is unchanged", sameJson(VERIFY_ENV_BASE, ["PATH", "HOME", "SHELL", "TERM", "LANG", "LC_ALL", "TMPDIR", "TMP", "USER", "LOGNAME", "PWD", "NODE_OPTIONS", "NODE_ENV", "DATABASE_URL", "DATABASE_URL_MIGRATE", "WORKSPACE_ID", "CI"]), true);
check("target-verify env base whitelist is unchanged", sameJson(TARGET_VERIFY_ENV_BASE, ["PATH", "HOME", "TMPDIR", "LANG"]), true);
check("env scrub keeps base order, sorted pnpm pass-throughs, shape-checked extras",
  JSON.stringify(verifyEnvAssignments({ PATH: "/bin", HOME: "", PNPM_B: "2", npm_config_x: "1", PNPM_A: "1", OK1: "x", OK2: "y" }, "OK1 1BAD X OK2")),
  JSON.stringify(["PATH=/bin", "HOME=", "PNPM_A=1", "PNPM_B=2", "npm_config_x=1", "OK1=x", "OK2=y"]));
check("env scrub drops unset names and empty extra lists", JSON.stringify(verifyEnvAssignments({ PATH: "/bin" }, "")), JSON.stringify(["PATH=/bin"]));

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
