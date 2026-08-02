#!/usr/bin/env bash
# Offline contract for target profiles and target-neutral verification.
# Bash 3.2 compatible.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VERIFY="$SCRIPT_DIR/../target-verify.sh"
VALIDATOR="$SCRIPT_DIR/../lib/json-schema-subset.cjs"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAILURES=0
ok() { echo "ok   - $1"; }
bad() { echo "NOT OK - $1"; FAILURES=$((FAILURES + 1)); }
expect() { label="$1"; wanted="$2"; shift 2; "$@" >"$TMP/out" 2>&1; got=$?; if [ "$got" -eq "$wanted" ]; then ok "$label"; else bad "$label (wanted=$wanted got=$got: $(cat "$TMP/out"))"; fi; }

# AC-PROFILE-1 / AC-PROFILE-6: one closed schema represents all target families.
for profile in node go python feedbackops; do
  if node - "$VALIDATOR" "$ROOT/schemas/target-profile.schema.json" "$ROOT/schemas/profiles/$profile.example.json" <<'NODE'
const fs=require("fs"); const {validate}=require(process.argv[2]);
process.exit(validate(JSON.parse(fs.readFileSync(process.argv[3])),JSON.parse(fs.readFileSync(process.argv[4]))).length?1:0);
NODE
  then ok "AC-PROFILE-1 $profile example uses the target-neutral schema"; else bad "AC-PROFILE-1 $profile example validates"; fi
done

for fixture in verify.valid.json verify.generic.valid.json; do
  if node - "$VALIDATOR" "$ROOT/schemas/verify.schema.json" "$ROOT/schemas/fixtures/$fixture" <<'NODE'
const fs=require("fs"); const {validate}=require(process.argv[2]);
process.exit(validate(JSON.parse(fs.readFileSync(process.argv[3])),JSON.parse(fs.readFileSync(process.argv[4]))).length?1:0);
NODE
  then ok "AC-PROFILE-2 $fixture has exactly one valid evidence shape"; else bad "AC-PROFILE-2 $fixture validates"; fi
done
for fixture in verify.empty_pass.invalid.json verify.no_evidence.invalid.json verify.both_evidence.invalid.json verify.generic_exit_nonzero.invalid.json verify.generic_zero_count.invalid.json; do
  if node - "$VALIDATOR" "$ROOT/schemas/verify.schema.json" "$ROOT/schemas/fixtures/$fixture" <<'NODE'
const fs=require("fs"); const {validate}=require(process.argv[2]);
process.exit(validate(JSON.parse(fs.readFileSync(process.argv[3])),JSON.parse(fs.readFileSync(process.argv[4]))).length?0:1);
NODE
  then ok "AC-PROFILE-2 $fixture is schema-rejected"; else bad "AC-PROFILE-2 $fixture rejection"; fi
done

for fixture in verify.generic_exit_nonzero.invalid.json verify.generic_zero_count.invalid.json; do
  if node - "$ROOT/scripts/lib/verify-artifact.cjs" "$ROOT/schemas/fixtures/$fixture" <<'NODE'
const {validArtifact}=require(process.argv[2]); const artifact=require(process.argv[3]);
process.exit(validArtifact(artifact)?1:0);
NODE
  then ok "AC-PROFILE-2 semantic validator rejects $fixture"; else bad "AC-PROFILE-2 semantic rejection for $fixture"; fi
done

make_repo() {
  repo="$1"; mkdir -p "$repo/bin" "$repo/.review"; git -C "$repo" init -q
  git -C "$repo" config user.email smoke@example.test; git -C "$repo" config user.name smoke
  printf '%s\n' seed > "$repo/README.md"; git -C "$repo" add README.md; git -C "$repo" commit -qm seed
  cat > "$repo/bin/fake-test" <<'EOF'
#!/usr/bin/env bash
case "${FAKE_MODE:-green}" in
  green) echo "3 tests"; exit 0;;
  zero) echo "0 tests"; exit 0;;
  fail) echo "3 tests"; exit 7;;
esac
EOF
  chmod +x "$repo/bin/fake-test"
  cat > "$repo/profile.json" <<'EOF'
{"schema_version":"1","id":"fake-portable","runtime":{"executables":["fake-test"]},"environment":{"allow":["FAKE_MODE"]},"setup":[],"verification":{"output_bytes":256,"groups":[{"id":"test","required":true,"commands":[{"argv":["fake-test"],"env_allow":["FAKE_MODE"]}],"test_count":{"pattern":"([0-9]+) tests","group":1}}]}}
EOF
}

REPO="$TMP/repo"; make_repo "$REPO"
# Representative profiles execute offline; Node uses the real runtime/TAP output,
# while Go and Python use deterministic executable doubles.
cat > "$REPO/bin/npm" <<'EOF'
#!/usr/bin/env bash
echo "lint ok"
EOF
cat > "$REPO/bin/go" <<'EOF'
#!/usr/bin/env bash
echo "PASS 3"
EOF
cat > "$REPO/bin/uv" <<'EOF'
#!/usr/bin/env bash
echo "3 passed"
EOF
chmod +x "$REPO/bin/npm" "$REPO/bin/go" "$REPO/bin/uv"
cat > "$REPO/real-node.test.js" <<'EOF'
const test = require("node:test");
const assert = require("node:assert/strict");
test("real node TAP fixture", () => assert.equal(2 + 2, 4));
EOF
for family in node go python; do
  cp "$ROOT/schemas/profiles/$family.example.json" "$REPO/$family.json"
  (cd "$REPO" && PATH="$REPO/bin:$PATH" bash "$VERIFY" "$family.json" "6${#family}") >"$TMP/$family-run" 2>&1
  family_ec=$?
  if [ "$family" = node ]; then
    if [ "$family_ec" -eq 0 ] && node -e 'const o=require(process.argv[1]); const test=o.groups.find(g=>g.id==="test"); process.exit(test&&test.test_count===1&&test.commands.some(c=>c.exit_code===0)?0:1)' "$REPO/.review/ISSUE-64-VERIFY.json"; then
      ok "AC-PROFILE-7 actual node --test TAP summary is extracted"
    else
      bad "AC-PROFILE-7 actual node --test target ($(cat "$TMP/$family-run"))"
    fi
  elif [ "$family_ec" -eq 0 ]; then ok "AC-PROFILE-7 fake $family target verifies offline"; else bad "AC-PROFILE-7 fake $family target ($(cat "$TMP/$family-run"))"; fi
done
# AC-PROFILE-2 / AC-PROFILE-3: required commands and same-HEAD aggregate.
(cd "$REPO" && PATH="$REPO/bin:$PATH" FAKE_MODE=green bash "$VERIFY" profile.json 71) >"$TMP/green" 2>&1; green_ec=$?
if [ "$green_ec" -eq 0 ] && node - "$VALIDATOR" "$ROOT/schemas/verify.schema.json" "$REPO/.review/ISSUE-71-VERIFY.json" <<'NODE'
const fs=require("fs"); const {validate}=require(process.argv[2]); const schema=JSON.parse(fs.readFileSync(process.argv[3])); const o=JSON.parse(fs.readFileSync(process.argv[4]));
process.exit(validate(schema,o).length===0&&o.classifier==="PASS"&&o.groups[0].test_count===3&&o.head_sha.length===40?0:1);
NODE
then ok "AC-PROFILE-2 generic green run publishes bounded structured evidence"; else bad "AC-PROFILE-2 generic green artifact"; fi

for mode in fail zero; do
  issue=72; [ "$mode" = zero ] && issue=73
  (cd "$REPO" && PATH="$REPO/bin:$PATH" FAKE_MODE="$mode" bash "$VERIFY" profile.json "$issue") >"$TMP/$mode" 2>&1
  if [ "$?" -ne 0 ]; then ok "AC-PROFILE-7 $mode injection fails closed"; else bad "AC-PROFILE-7 $mode injection"; fi
done

(cd "$REPO" && PATH="$REPO/bin:$PATH" FAKE_MODE=fail bash "$VERIFY" profile.json 74) >/dev/null 2>&1
first=$?; printf '%s\n' 'corrected uncommitted tree' >> "$REPO/README.md"
(cd "$REPO" && PATH="$REPO/bin:$PATH" FAKE_MODE=green bash "$VERIFY" profile.json 74) >/dev/null 2>&1
second=$?
if [ "$first" -ne 0 ] && [ "$second" -eq 0 ] && node -e 'const o=require(process.argv[1]);process.exit(o.classifier==="PASS"&&o.runs.length===1&&/^[0-9a-f]{64}$/.test(o.content_sha256||"")?0:1)' "$REPO/.review/ISSUE-74-VERIFY.json"; then ok "AC-PROFILE-3 corrected uncommitted content starts a fresh aggregate"; else bad "AC-PROFILE-3 content identity aggregate reset"; fi

# An extractor miss is durable canonical FAIL evidence with an honest unknown count.
node -e 'const fs=require("fs");const p=require(process.argv[1]);p.id="extractor-miss";p.verification.groups[0].test_count.pattern="NEVER MATCH ([0-9]+)";fs.writeFileSync(process.argv[2],JSON.stringify(p))' "$REPO/profile.json" "$REPO/extractor-miss.json"
(cd "$REPO" && PATH="$REPO/bin:$PATH" FAKE_MODE=green bash "$VERIFY" extractor-miss.json 75) >"$TMP/extractor-miss" 2>&1
miss_ec=$?
if [ "$miss_ec" -ne 0 ] && node - "$VALIDATOR" "$ROOT/schemas/verify.schema.json" "$REPO/.review/ISSUE-75-VERIFY.json" <<'NODE'
const fs=require("fs"); const {validate}=require(process.argv[2]); const schema=JSON.parse(fs.readFileSync(process.argv[3])); const o=JSON.parse(fs.readFileSync(process.argv[4]));
process.exit(validate(schema,o).length===0&&o.classifier==="FAIL"&&o.groups[0].test_count===null&&o.failures.some(f=>f.code==="zero_or_unproven_tests"&&f.actual==="null")?0:1);
NODE
then ok "AC-PROFILE-7 extractor miss publishes schema-valid unknown-count FAIL evidence"; else bad "AC-PROFILE-7 extractor miss canonical evidence ($(cat "$TMP/extractor-miss"))"; fi

# A damaged same-HEAD aggregate cannot discard the prior red run on append.
(cd "$REPO" && PATH="$REPO/bin:$PATH" FAKE_MODE=fail bash "$VERIFY" profile.json 76) >/dev/null 2>&1
node -e 'const fs=require("fs");const f=process.argv[1];const o=JSON.parse(fs.readFileSync(f));o.classifier="PASS";o.verdict={passed:3,failed:0,pending:0,exit_code:0};o.failures=[];fs.writeFileSync(f,JSON.stringify(o));' "$REPO/.review/ISSUE-76-VERIFY.json"
cp "$REPO/.review/ISSUE-76-VERIFY.json" "$TMP/corrupt-same-head.json"
(cd "$REPO" && PATH="$REPO/bin:$PATH" FAKE_MODE=green bash "$VERIFY" profile.json 76) >"$TMP/corrupt-run" 2>&1
corrupt_ec=$?
if [ "$corrupt_ec" -ne 0 ] && cmp -s "$TMP/corrupt-same-head.json" "$REPO/.review/ISSUE-76-VERIFY.json" \
  && grep -F -q 'existing same-HEAD canonical artifact failed schema or aggregate validation' "$TMP/corrupt-run"; then
  ok "AC-PROFILE-3 damaged same-HEAD red latch is rejected without replacement"
else
  bad "AC-PROFILE-3 damaged same-HEAD red latch rejection (ec=$corrupt_ec: $(cat "$TMP/corrupt-run"))"
fi

# output_bytes is a UTF-8 byte ceiling and never publishes a partial code point.
cat > "$REPO/utf8.json" <<'EOF'
{"schema_version":"1","id":"utf8-bytes","runtime":{"executables":["node"]},"setup":[],"verification":{"output_bytes":256,"groups":[{"id":"diagnostic","required":true,"commands":[{"argv":["node","-e","process.stdout.write('한'.repeat(200))"]}]}]}}
EOF
(cd "$REPO" && PATH="$REPO/bin:$PATH" bash "$VERIFY" utf8.json 77) >"$TMP/utf8-run" 2>&1
utf8_ec=$?
if [ "$utf8_ec" -eq 0 ] && node -e 'const o=require(process.argv[1]);const c=o.groups[0].commands[0];process.exit(c.output_truncated===true&&Buffer.byteLength(c.output,"utf8")===255&&c.output.length===85&&!c.output.includes("�")?0:1)' "$REPO/.review/ISSUE-77-VERIFY.json"; then
  ok "AC-PROFILE-2 output_bytes uses a valid UTF-8 byte prefix and exact truncation flag"
else
  bad "AC-PROFILE-2 UTF-8 byte truncation ($(cat "$TMP/utf8-run"))"
fi

# A new HEAD cannot append stale evidence and can truthfully become green.
printf '%s\n' next >> "$REPO/README.md"; git -C "$REPO" commit -qam next
(cd "$REPO" && PATH="$REPO/bin:$PATH" FAKE_MODE=green bash "$VERIFY" profile.json 74) >/dev/null 2>&1
if [ "$?" -eq 0 ] && node -e 'const o=require(process.argv[1]);process.exit(o.classifier==="PASS"&&o.runs.length===1?0:1)' "$REPO/.review/ISSUE-74-VERIFY.json"; then ok "AC-PROFILE-3 later HEAD starts fresh evidence"; else bad "AC-PROFILE-3 stale evidence isolation"; fi

# AC-PROFILE-6 / AC-PROFILE-7: malformed, unknown, unsafe and missing command.
node -e 'const fs=require("fs");const p=require(process.argv[1]);p.extra=true;fs.writeFileSync(process.argv[2],JSON.stringify(p))' "$REPO/profile.json" "$REPO/bad.json"
expect "AC-PROFILE-6 unknown profile keys rejected" 2 sh -c "cd '$REPO' && PATH='$REPO/bin:$PATH' bash '$VERIFY' bad.json 80"
node -e 'const fs=require("fs");const p=require(process.argv[1]);p.verification.groups[0].commands[0].cwd="../";fs.writeFileSync(process.argv[2],JSON.stringify(p))' "$REPO/profile.json" "$REPO/unsafe.json"
expect "AC-PROFILE-7 unsafe cwd rejected" 2 sh -c "cd '$REPO' && PATH='$REPO/bin:$PATH' bash '$VERIFY' unsafe.json 81"
node -e 'const fs=require("fs");const p=require(process.argv[1]);p.runtime.executables=["definitely-missing-command"];fs.writeFileSync(process.argv[2],JSON.stringify(p))' "$REPO/profile.json" "$REPO/missing.json"
expect "AC-PROFILE-7 missing command rejected" 1 sh -c "cd '$REPO' && PATH='$REPO/bin:$PATH' bash '$VERIFY' missing.json 82"

# AC-PROFILE-4: generic implementation contains no FeedbackOps tool assumptions.
if ! grep -E 'pnpm|vitest|postgres|backend' "$SCRIPT_DIR/../lib/target-verify.mjs" >/dev/null; then ok "AC-PROFILE-4 generic verifier has no legacy target assumptions"; else bad "AC-PROFILE-4 generic verifier isolation"; fi
# AC-PROFILE-5: setup/tier migration is explicitly deferred to the single profile parser wave.
# AC-PROFILE-8: documentation assertions live in release/install gates.

echo "---"
if [ "$FAILURES" -eq 0 ]; then echo "ALL CASES PASS"; exit 0; fi
echo "$FAILURES CASE(S) FAILED"; exit 1
