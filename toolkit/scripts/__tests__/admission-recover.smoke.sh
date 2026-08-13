#!/usr/bin/env bash
# Host-owned route-digest admission recovery. bash-3.2-compatible.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RECOVER="$SCRIPT_DIR/../lib/admission-recover.cjs"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0
DIGEST_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
DIGEST_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
HERDR_BINDING='{"route_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","policy_digest":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","runtime":"codex","role":"implementation","tier":"standard","transport":"herdr","selection_basis":"ordered_policy","decision_reason_codes":["model_alloc","ordered_policy"],"selected":{"model":"gpt-5.6-terra","effort":"low"}}'

pass() { echo "ok   - $1"; }
fail() { echo "NOT OK - $1"; FAIL=$((FAIL + 1)); }

state_file() {
  file="$1"
  key="$2"
  advanced="$3"
  node - "$file" "$key" "$advanced" <<'NODE'
const fs = require("fs");
const [file, key, advanced] = process.argv.slice(2);
const ordinal = Number(/-dispatch-([0-9]+)$/.exec(key)[1]);
fs.writeFileSync(file, JSON.stringify({
  round_control: advanced === "yes"
    ? { last_admission_key: key, next_dispatch_ordinal: ordinal + 1 }
    : { next_dispatch_ordinal: ordinal }
}) + "\n");
NODE
}

tx_status() {
  expected="$2"
  node - "$1" "$expected" <<'NODE'
const fs = require("fs");
const [file, expected] = process.argv.slice(2);
try { process.exit(JSON.parse(fs.readFileSync(file, "utf8")).status === expected ? 0 : 1); }
catch (_) { process.exit(1); }
NODE
}

# Herdr is an admitted routed transport, while unknown transports remain
# fail-closed before a transaction directory becomes visible.
ROOT="$TMP/herdr-binding"
KEY="issue-70-dispatch-2"
STATE="$ROOT/state.json"
mkdir -p "$ROOT"
state_file "$STATE" "$KEY" yes
node "$RECOVER" publish "$ROOT" "$ROOT/$KEY" "$STATE" 70 "$KEY" "$$" normal --route-digest "$DIGEST_A" --route-binding "$HERDR_BINDING" >/dev/null
node "$RECOVER" commit-admission "$ROOT/$KEY" "" "" 70 "$KEY" >/dev/null
if node - "$ROOT/$KEY/.admission-transaction.json" <<'NODE'
const fs = require("fs");
const tx = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
process.exit(tx.routing && tx.routing.transport === "herdr" && tx.status === "committed" ? 0 : 1);
NODE
then
  pass "Herdr route binding is admitted and committed"
else
  fail "Herdr route binding was not admitted"
fi

ROOT="$TMP/unknown-binding"
KEY="issue-70-dispatch-3"
STATE="$ROOT/state.json"
UNKNOWN_BINDING='{"route_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","policy_digest":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","runtime":"codex","role":"implementation","tier":"standard","transport":"unknown","selection_basis":"ordered_policy","decision_reason_codes":["model_alloc","ordered_policy"],"selected":{"model":"gpt-5.6-terra","effort":"low"}}'
mkdir -p "$ROOT"
state_file "$STATE" "$KEY" yes
node "$RECOVER" publish "$ROOT" "$ROOT/$KEY" "$STATE" 70 "$KEY" "$$" normal --route-digest "$DIGEST_A" --route-binding "$UNKNOWN_BINDING" >/dev/null 2>&1
unknown_status=$?
if [ "$unknown_status" -ne 0 ] && [ ! -e "$ROOT/$KEY" ]; then
  pass "unknown route transport remains rejected"
else
  fail "unknown route transport was admitted"
fi

# A matching normal route transaction can be adopted only for the current key.
ROOT="$TMP/normal-match"
KEY="issue-71-dispatch-2"
STATE="$ROOT/state.json"
mkdir -p "$ROOT"
state_file "$STATE" "$KEY" yes
node "$RECOVER" publish "$ROOT" "$ROOT/$KEY" "$STATE" 71 "$KEY" "$$" normal --route-digest "$DIGEST_A" >/dev/null
node "$RECOVER" recover "$ROOT/issue-71-integrated-fix" "$ROOT/$KEY" "$STATE" 71 "$KEY" --route-digest "$DIGEST_A" >"$TMP/normal-match.out"
if [ "$?" -eq 0 ] && tx_status "$ROOT/$KEY/.admission-transaction.json" committed; then
  pass "matching current-key normal digest is adopted after ordinal advance"
else
  fail "matching current-key normal digest was not adopted"
fi

# A mismatched normal digest cannot be converted into a committed admission.
ROOT="$TMP/normal-mismatch"
KEY="issue-72-dispatch-2"
STATE="$ROOT/state.json"
mkdir -p "$ROOT"
state_file "$STATE" "$KEY" yes
node "$RECOVER" publish "$ROOT" "$ROOT/$KEY" "$STATE" 72 "$KEY" "$$" normal --route-digest "$DIGEST_A" >/dev/null
node "$RECOVER" recover "$ROOT/issue-72-integrated-fix" "$ROOT/$KEY" "$STATE" 72 "$KEY" --route-digest "$DIGEST_B" >"$TMP/normal-mismatch.out"
ec=$?
if [ "$ec" -eq 3 ] && grep -qx 'route_digest_mismatch' "$TMP/normal-mismatch.out" && tx_status "$ROOT/$KEY/.admission-transaction.json" prepared; then
  pass "mismatched normal digest is never adopted after ordinal advance"
else
  fail "mismatched normal digest was adopted or unclassified"
fi

# An integrated route transaction needs both a matching singleton and its
# authoritative current-key ordinal record.
ROOT="$TMP/integrated-match"
KEY="issue-73-dispatch-3"
STATE="$ROOT/state.json"
SINGLETON="$ROOT/issue-73-integrated-fix"
ORDINAL="$ROOT/$KEY"
mkdir -p "$ROOT"
state_file "$STATE" "$KEY" yes
node "$RECOVER" publish "$ROOT" "$SINGLETON" "$STATE" 73 "$KEY" "$$" integrated --route-digest "$DIGEST_A" >/dev/null
node "$RECOVER" publish "$ROOT" "$ORDINAL" "$STATE" 73 "$KEY" "$$" integrated --route-digest "$DIGEST_A" >/dev/null
node "$RECOVER" recover "$SINGLETON" "$ORDINAL" "$STATE" 73 "$KEY" --route-digest "$DIGEST_A" >"$TMP/integrated-match.out"
if [ "$?" -eq 0 ] && tx_status "$SINGLETON/.admission-transaction.json" committed && tx_status "$ORDINAL/.admission-transaction.json" committed; then
  pass "matching integrated singleton and ordinal are adopted together"
else
  fail "matching integrated pair was not adopted together"
fi

# A current-key integrated pair cannot cross-bind a singleton and ordinal from
# different route decisions, even when both files are individually well-formed.
ROOT="$TMP/integrated-mismatch"
KEY="issue-730-dispatch-3"
STATE="$ROOT/state.json"
SINGLETON="$ROOT/issue-730-integrated-fix"
ORDINAL="$ROOT/$KEY"
mkdir -p "$ROOT"
state_file "$STATE" "$KEY" yes
node "$RECOVER" publish "$ROOT" "$SINGLETON" "$STATE" 730 "$KEY" "$$" integrated --route-digest "$DIGEST_A" >/dev/null
node "$RECOVER" publish "$ROOT" "$ORDINAL" "$STATE" 730 "$KEY" "$$" integrated --route-digest "$DIGEST_A" >/dev/null
node - "$ORDINAL/.admission-transaction.json" "$DIGEST_B" <<'NODE'
const fs = require("fs");
const [file, digest] = process.argv.slice(2);
const tx = JSON.parse(fs.readFileSync(file, "utf8"));
tx.route_digest = digest;
fs.writeFileSync(file, JSON.stringify(tx) + "\n");
NODE
node "$RECOVER" recover "$SINGLETON" "$ORDINAL" "$STATE" 730 "$KEY" --route-digest "$DIGEST_A" >"$TMP/integrated-mismatch.out"
ec=$?
if [ "$ec" -eq 3 ] && grep -qx 'route_digest_mismatch' "$TMP/integrated-mismatch.out" && tx_status "$SINGLETON/.admission-transaction.json" prepared && tx_status "$ORDINAL/.admission-transaction.json" prepared; then
  pass "mismatched integrated companion digest is never adopted"
else
  fail "mismatched integrated companion digest was adopted or unclassified"
fi

# A singleton without its ordinal cannot be adopted, even after the host
# ordinal advanced. It remains present as a fail-closed current-key record.
ROOT="$TMP/integrated-unbound"
KEY="issue-74-dispatch-3"
STATE="$ROOT/state.json"
SINGLETON="$ROOT/issue-74-integrated-fix"
ORDINAL="$ROOT/$KEY"
mkdir -p "$ROOT"
state_file "$STATE" "$KEY" yes
node "$RECOVER" publish "$ROOT" "$SINGLETON" "$STATE" 74 "$KEY" "$$" integrated --route-digest "$DIGEST_A" >/dev/null
node "$RECOVER" recover "$SINGLETON" "$ORDINAL" "$STATE" 74 "$KEY" --route-digest "$DIGEST_A" >"$TMP/integrated-unbound.out"
ec=$?
if [ "$ec" -eq 3 ] && grep -qx 'route_digest_unbound' "$TMP/integrated-unbound.out" && [ -d "$SINGLETON" ] && [ ! -e "$ORDINAL" ]; then
  pass "advanced singleton without ordinal is route-digest-unbound"
else
  fail "advanced singleton without ordinal was adopted or reclaimed"
fi

# Before an ordinal advance, an interrupted current-key singleton remains
# reclaimable. A digest requirement cannot turn a retryable crash into a leak.
ROOT="$TMP/integrated-reclaim"
KEY="issue-75-dispatch-3"
STATE="$ROOT/state.json"
SINGLETON="$ROOT/issue-75-integrated-fix"
ORDINAL="$ROOT/$KEY"
mkdir -p "$ROOT"
state_file "$STATE" "$KEY" no
node "$RECOVER" publish "$ROOT" "$SINGLETON" "$STATE" 75 "$KEY" "$$" integrated --route-digest "$DIGEST_A" >/dev/null
node "$RECOVER" recover "$SINGLETON" "$ORDINAL" "$STATE" 75 "$KEY" --route-digest "$DIGEST_A" >"$TMP/integrated-reclaim.out"
ec=$?
if [ "$ec" -eq 0 ] && [ ! -s "$TMP/integrated-reclaim.out" ] && [ ! -e "$SINGLETON" ] && [ ! -e "$ORDINAL" ]; then
  pass "unadvanced singleton-only route transaction is reclaimed for retry"
else
  fail "unadvanced singleton-only route transaction was not reclaimed"
fi

# No-policy recovery keeps legacy reclaim behavior even when the caller passes
# a newer current key. Route-only prior-key protection must not change it.
ROOT="$TMP/legacy-prior-key"
OLD_KEY="issue-77-dispatch-2"
KEY="issue-77-dispatch-3"
STATE="$ROOT/state.json"
SINGLETON="$ROOT/issue-77-integrated-fix"
OLD_ORDINAL="$ROOT/$OLD_KEY"
ORDINAL="$ROOT/$KEY"
mkdir -p "$ROOT"
state_file "$STATE" "$OLD_KEY" no
node "$RECOVER" publish "$ROOT" "$SINGLETON" "$STATE" 77 "$OLD_KEY" "$$" integrated >/dev/null
node "$RECOVER" publish "$ROOT" "$OLD_ORDINAL" "$STATE" 77 "$OLD_KEY" "$$" integrated >/dev/null
node "$RECOVER" recover "$SINGLETON" "$ORDINAL" "$STATE" 77 "$KEY" >"$TMP/legacy-prior-key.out"
if [ "$?" -eq 0 ] && [ ! -s "$TMP/legacy-prior-key.out" ] && [ ! -e "$SINGLETON" ] && [ ! -e "$OLD_ORDINAL" ]; then
  pass "no-policy recovery retains legacy prior-key reclaim"
else
  fail "no-policy recovery changed legacy prior-key reclaim"
fi

# recover-lock remains reclaim-only: it does not receive an expected digest and
# must keep clearing an unadvanced prepared pair, including legacy metadata.
ROOT="$TMP/lock-reclaim"
KEY="issue-76-dispatch-3"
STATE="$ROOT/state.json"
SINGLETON="$ROOT/issue-76-integrated-fix"
ORDINAL="$ROOT/$KEY"
LOCK="$ROOT/.issue-76-lock/.admission-lock.json"
mkdir -p "$ROOT"
state_file "$STATE" "$KEY" no
node "$RECOVER" publish "$ROOT" "$SINGLETON" "$STATE" 76 "$KEY" "$$" integrated >/dev/null
node "$RECOVER" publish "$ROOT" "$ORDINAL" "$STATE" 76 "$KEY" "$$" integrated >/dev/null
node "$RECOVER" acquire-lock "$LOCK" "$SINGLETON" "$STATE" 76 "$KEY" 999999 >/dev/null
node "$RECOVER" recover-lock "$LOCK" "$SINGLETON" "$STATE" 76 >/dev/null
if [ "$?" -eq 0 ] && [ ! -e "$SINGLETON" ] && [ ! -e "$ORDINAL" ] && [ ! -e "${LOCK%/.admission-lock.json}" ]; then
  pass "recover-lock preserves digest-independent interrupted-pair reclaim"
else
  fail "recover-lock changed its reclaim behavior"
fi

if [ "$FAIL" -eq 0 ]; then
  echo 'ALL CASES PASS'
  exit 0
fi
echo "$FAIL CASE(S) FAILED"
exit 1
