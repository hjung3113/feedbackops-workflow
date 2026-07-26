#!/usr/bin/env bash
# Pure model-routing selector smoke. bash-3.2-compatible and git-free.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROUTE="$SCRIPT_DIR/../route.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0

ok() { echo "ok   - $1"; }
bad() { echo "NOT OK - $1"; FAIL=$((FAIL + 1)); }
expect() {
  name="$1"; expected="$2"; shift 2
  "$@" >"$TMP/out" 2>/dev/null
  ec=$?
  if [ "$ec" -eq "$expected" ]; then ok "$name"; else bad "$name (exit $ec)"; fi
}

HEAD="1111111111111111111111111111111111111111"
BASE="2222222222222222222222222222222222222222"
PERMISSION="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
cat > "$TMP/demand.json" <<EOF
{"runtime":"codex","role":"implementation","write_mode":"canonical_redispatch","tier":"standard","issue":81,"worktree_path":"/tmp/route-smoke","head_sha":"$HEAD","base_sha":"$BASE","round_state_revision":2,"admission_key":"issue-81-dispatch-3"}
EOF
cat > "$TMP/offer.json" <<EOF
{"runtime":"codex","executable":"/opt/bin/codex","version":"1.2.3","observed_at":"2026-07-26T00:00:00Z","expires_at":"2026-07-26T01:00:00Z","permission_profile_digest":"$PERMISSION"}
EOF
cat > "$TMP/policy.json" <<'EOF'
{"version":1,"rules":[{"when":{"runtime":"codex","role":"implementation"},"candidates":{"from":"model_alloc"},"fallback":"deny"}]}
EOF
printf '%s\n' '{"model":"gpt-5.6-terra","effort":"medium"}' > "$TMP/alloc.json"

# Static identity/configuration is a host-side cached probe. It establishes
# only the pinned executable identity; it does not claim model availability.
PROBE_BIN="$TMP/probe-bin"
mkdir -p "$PROBE_BIN"
cat > "$PROBE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "--version" ] || exit 2
if [ -n "${PROBE_CALLS:-}" ]; then printf 'called\n' >> "$PROBE_CALLS"; fi
printf 'codex-smoke 1.2.3\n'
EOF
chmod +x "$PROBE_BIN/codex"

# A project opts in only through an explicit host-side install. The worktree
# never supplies routing policy bytes to dispatch.
HOST_STATE="$TMP/host-state"
GIT_COMMON="$TMP/git-common"
mkdir -p "$GIT_COMMON"
expect "static probe emits a cached bounded offer" 0 env PATH="$PROBE_BIN:$PATH" AGENT_WORKFLOW_HOST_STATE="$HOST_STATE" AGENT_WORKFLOW_ROUTE_VERSION="codex-smoke 1.2.3" bash "$ROUTE" probe --runtime codex --depth static --ttl-seconds 60
grep -q '"status":"admitted"' "$TMP/out" && grep -q '"version":"codex-smoke 1.2.3"' "$TMP/out" && ok "static probe records pinned executable identity" || bad "static probe offer shape"
PROBE_CALLS="$TMP/probe-calls"
expect "static probe reuses a fresh safe cache without rerunning version" 0 env PATH="$PROBE_BIN:$PATH" AGENT_WORKFLOW_HOST_STATE="$HOST_STATE" PROBE_CALLS="$PROBE_CALLS" bash "$ROUTE" probe --runtime codex --depth static --ttl-seconds 60
[ ! -e "$PROBE_CALLS" ] && grep -q '"version":"codex-smoke 1.2.3"' "$TMP/out" && ok "static probe cache hit preserves observed identity" || bad "static probe cache hit"
CACHE_FILE="$(printf '%s\n' "$HOST_STATE"/route-offers/*.json)"
node - "$CACHE_FILE" <<'NODE'
const fs=require("fs"),f=process.argv[2],o=JSON.parse(fs.readFileSync(f));o.expires_at="2026-07-01T00:00:00.000Z";fs.writeFileSync(f,JSON.stringify(o));fs.chmodSync(f,0o600);
NODE
expect "expired static probe cache refreshes from a new host observation" 0 env PATH="$PROBE_BIN:$PATH" AGENT_WORKFLOW_HOST_STATE="$HOST_STATE" AGENT_WORKFLOW_ROUTE_VERSION="codex-smoke 1.2.4" PROBE_CALLS="$PROBE_CALLS" bash "$ROUTE" probe --runtime codex --depth static --ttl-seconds 60
grep -q '"version":"codex-smoke 1.2.4"' "$TMP/out" && ok "expired static cache does not reuse an old observation" || bad "expired static cache refresh"
chmod 0664 "$CACHE_FILE"
expect "unsafe static probe cache is refused" 3 env PATH="$PROBE_BIN:$PATH" AGENT_WORKFLOW_HOST_STATE="$HOST_STATE" bash "$ROUTE" probe --runtime codex --depth static --ttl-seconds 60
expect "host root inside a worktree is refused" 3 env AGENT_WORKFLOW_HOST_STATE="$TMP/route-smoke/host-state" bash "$ROUTE" policy install --git-common-dir "$GIT_COMMON" --worktree "$TMP/route-smoke" --policy-file "$TMP/policy.json"
expect "host root inside Git common dir is refused" 3 env AGENT_WORKFLOW_HOST_STATE="$GIT_COMMON/host-state" bash "$ROUTE" policy install --git-common-dir "$GIT_COMMON" --worktree "$TMP/route-smoke" --policy-file "$TMP/policy.json"
dd if=/dev/zero of="$TMP/oversize-policy.json" bs=1 count=262145 2>/dev/null
expect "oversize policy input is refused" 3 env AGENT_WORKFLOW_HOST_STATE="$HOST_STATE" bash "$ROUTE" policy install --git-common-dir "$GIT_COMMON" --worktree "$TMP/route-smoke" --policy-file "$TMP/oversize-policy.json"
expect "host policy install publishes an immutable opt-in snapshot" 0 env AGENT_WORKFLOW_HOST_STATE="$HOST_STATE" bash "$ROUTE" policy install --git-common-dir "$GIT_COMMON" --worktree "$TMP/route-smoke" --policy-file "$TMP/policy.json"
expect "host policy read returns the installed policy" 0 env AGENT_WORKFLOW_HOST_STATE="$HOST_STATE" bash "$ROUTE" policy read --git-common-dir "$GIT_COMMON" --worktree "$TMP/route-smoke"
grep -q '"status":"active"' "$TMP/out" && ok "host policy read reports active opt-in" || bad "host policy read reports active opt-in"
HOST_POLICY_DIGEST="$(shasum -a 256 "$TMP/policy.json" | awk '{print $1}')"
grep -q "\"policy_digest\":\"$HOST_POLICY_DIGEST\"" "$TMP/out" && ok "host policy read preserves exact-byte digest" || bad "host policy read preserves exact-byte digest"
GIT_COMMON_REAL="$(node -e 'process.stdout.write(require("fs").realpathSync(process.argv[1]))' "$GIT_COMMON")"
POLICY_DIR="$HOST_STATE/repos/$(printf '%s' "$GIT_COMMON_REAL" | shasum -a 256 | awk '{print $1}')/routing-policy"
ACTIVE="$POLICY_DIR/active.json"
SNAPSHOT="$POLICY_DIR/snapshots/$HOST_POLICY_DIGEST.json"

mv "$ACTIVE" "$TMP/active.real"
ln -s "$TMP/active.real" "$ACTIVE"
expect "active policy symlink is refused" 3 env AGENT_WORKFLOW_HOST_STATE="$HOST_STATE" bash "$ROUTE" policy read --git-common-dir "$GIT_COMMON" --worktree "$TMP/route-smoke"
rm "$ACTIVE"
mv "$TMP/active.real" "$ACTIVE"

mv "$SNAPSHOT" "$TMP/snapshot.real"
ln -s "$TMP/snapshot.real" "$SNAPSHOT"
expect "policy snapshot symlink is refused" 3 env AGENT_WORKFLOW_HOST_STATE="$HOST_STATE" bash "$ROUTE" policy read --git-common-dir "$GIT_COMMON" --worktree "$TMP/route-smoke"
rm "$SNAPSHOT"
mv "$TMP/snapshot.real" "$SNAPSHOT"

chmod 0664 "$ACTIVE"
expect "group-writable active pointer is refused" 3 env AGENT_WORKFLOW_HOST_STATE="$HOST_STATE" bash "$ROUTE" policy read --git-common-dir "$GIT_COMMON" --worktree "$TMP/route-smoke"
chmod 0600 "$ACTIVE"
chmod 0664 "$SNAPSHOT"
expect "group-writable policy snapshot is refused" 3 env AGENT_WORKFLOW_HOST_STATE="$HOST_STATE" bash "$ROUTE" policy read --git-common-dir "$GIT_COMMON" --worktree "$TMP/route-smoke"
chmod 0444 "$SNAPSHOT"

cp "$ACTIVE" "$TMP/active.saved"
dd if=/dev/zero of="$ACTIVE" bs=1 count=262145 2>/dev/null
chmod 0600 "$ACTIVE"
expect "oversize active pointer is refused" 3 env AGENT_WORKFLOW_HOST_STATE="$HOST_STATE" bash "$ROUTE" policy read --git-common-dir "$GIT_COMMON" --worktree "$TMP/route-smoke"
mv "$TMP/active.saved" "$ACTIVE"
chmod 0600 "$ACTIVE"

cp "$ACTIVE" "$TMP/active.pointer.saved"
node - "$ACTIVE" <<'NODE'
const fs = require("fs");
const file = process.argv[2];
const pointer = JSON.parse(fs.readFileSync(file, "utf8"));
pointer.policy_digest = "b".repeat(64);
fs.writeFileSync(file, JSON.stringify(pointer));
NODE
expect "pointer name and digest disagreement is refused" 3 env AGENT_WORKFLOW_HOST_STATE="$HOST_STATE" bash "$ROUTE" policy read --git-common-dir "$GIT_COMMON" --worktree "$TMP/route-smoke"
mv "$TMP/active.pointer.saved" "$ACTIVE"
chmod 0600 "$ACTIVE"

cp "$SNAPSHOT" "$TMP/snapshot.content.saved"
chmod 0600 "$SNAPSHOT"
printf '\n' >> "$SNAPSHOT"
expect "snapshot content digest disagreement is refused" 3 env AGENT_WORKFLOW_HOST_STATE="$HOST_STATE" bash "$ROUTE" policy read --git-common-dir "$GIT_COMMON" --worktree "$TMP/route-smoke"
mv "$TMP/snapshot.content.saved" "$SNAPSHOT"
chmod 0444 "$SNAPSHOT"

expect "eligible policy admits exact model-alloc tuple" 0 bash "$ROUTE" decide --demand "$(cat "$TMP/demand.json")" --offer "$(cat "$TMP/offer.json")" --policy "$(cat "$TMP/policy.json")" --model-alloc "$(cat "$TMP/alloc.json")" --now 2026-07-26T00:30:00Z
first="$(cat "$TMP/out")"
expect "identical inputs yield byte-identical decision" 0 bash "$ROUTE" decide --demand "$(cat "$TMP/demand.json")" --offer "$(cat "$TMP/offer.json")" --policy "$(cat "$TMP/policy.json")" --model-alloc "$(cat "$TMP/alloc.json")" --now 2026-07-26T00:30:00Z
if [ "$first" = "$(cat "$TMP/out")" ]; then ok "decision is deterministic"; else bad "decision changed for identical inputs"; fi

expect "expired offer is refused" 3 bash "$ROUTE" decide --demand "$(cat "$TMP/demand.json")" --offer '{"runtime":"codex","executable":"/opt/bin/codex","version":"1.2.3","observed_at":"2026-07-26T00:00:00Z","expires_at":"2026-07-26T00:01:00Z","permission_profile_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' --policy "$(cat "$TMP/policy.json")" --model-alloc "$(cat "$TMP/alloc.json")" --now 2026-07-26T00:30:00Z
grep -q 'runner_offer_expired' "$TMP/out" && ok "expired offer has typed refusal" || bad "expired offer refusal code"

expect "literal model policy is rejected" 3 bash "$ROUTE" decide --demand "$(cat "$TMP/demand.json")" --offer "$(cat "$TMP/offer.json")" --policy '{"version":1,"rules":[{"when":{"runtime":"codex","role":"implementation"},"candidates":{"model":"other"},"fallback":"deny"}]}' --model-alloc "$(cat "$TMP/alloc.json")" --now 2026-07-26T00:30:00Z
grep -q 'route_policy_invalid' "$TMP/out" && ok "literal candidate has typed refusal" || bad "literal candidate refusal code"

if [ "$FAIL" -eq 0 ]; then echo 'ALL CASES PASS'; exit 0; fi
echo "$FAIL CASE(S) FAILED"
exit 1
