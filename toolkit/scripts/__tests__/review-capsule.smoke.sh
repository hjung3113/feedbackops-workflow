#!/usr/bin/env bash
# Offline deterministic re-review capsule contract. Bash 3.2 compatible.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"; RENDER="$SCRIPT_DIR/../review-capsule.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT; FAILURES=0
if [ -z "${AGENT_WORKFLOW_CODEX_BIN:-}" ]; then
  RUNTIME_FAKE="$TMP/codex-runtime-fake"
  cat > "$RUNTIME_FAKE" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo 'codex capsule smoke 1.0'; exit 0 ;;
  --help) echo 'Commands: exec'; exit 0 ;;
  exec) [ "${2:-}" = "--help" ] && { echo 'exec --sandbox --cd --model --config --output-last-message'; exit 0; } ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$RUNTIME_FAKE"
  export AGENT_WORKFLOW_CODEX_BIN="$RUNTIME_FAKE"
fi
ok(){ echo "ok   - $1"; }; bad(){ echo "NOT OK - $1"; FAILURES=$((FAILURES+1)); }
run(){ (cd "$REPO" && bash "$RENDER" --issue 17 --worktree "$REPO" --round-state .review/ISSUE-17-ROUND-STATE.json --prompt .review/ISSUE-17-PROMPT.md --pr-draft .review/ISSUE-17-PR-DRAFT.json --review .review/ISSUE-17-REVIEW.json --manifest-revision 3 --target-tokens "${TOKENS:-1200}" "$@"); }
REPO="$TMP/target"; mkdir -p "$REPO/.review"; git -C "$REPO" init -q; git -C "$REPO" config user.email smoke@example.test; git -C "$REPO" config user.name smoke
printf '%s\n' base > "$REPO/a.txt"; git -C "$REPO" add a.txt; git -C "$REPO" commit -qm base; BASE="$(git -C "$REPO" rev-parse HEAD)"; printf '%s\n' changed >> "$REPO/a.txt"; git -C "$REPO" commit -qam change; HEAD="$(git -C "$REPO" rev-parse HEAD)"; BRANCH="$(git -C "$REPO" branch --show-current)"
node - "$ROOT/schemas/fixtures/round_state.valid.json" "$REPO" "$BASE" "$HEAD" <<'NODE'
const fs=require("fs"),path=require("path");const [src,root,base,head]=process.argv.slice(2),o=JSON.parse(fs.readFileSync(src));o.issue={number:17,title:"capsule"};o.revision=3;o.base_branch="main";o.base_sha=base;o.head_sha=head;o.worktree_path=root;o.contract={objective:"Review untrusted text safely SECRET_TOKEN=do-not-copy "+"detail ".repeat(300),touch_allowlist:["a.txt"],prohibitions:["no network","no push","no merge","no issue mutation"],verify_filter:"capsule",test_discovery_command:"printf AC-CAPSULE-1"};o.acceptance={expected_test_count:2,criteria:[{id:"AC-CAPSULE-1",statement:"full canonical text is retained"},{id:"AC-CAPSULE-2",statement:"review is deterministic"}]};o.decisions=[];o.prior_findings=[];delete o.round_control;o.commit_scope={commits:[{sha:head,subject:"change"}]};o.live_probes=[];o.artifact_pointers=[{artifact_type:"pr_draft",path:".review/ISSUE-17-PR-DRAFT.json"},{artifact_type:"review",path:".review/ISSUE-17-REVIEW.json"}];fs.writeFileSync(path.join(root,".review/ISSUE-17-ROUND-STATE.json"),JSON.stringify(o));fs.writeFileSync(path.join(root,".review/ISSUE-17-PROMPT.md"),["Objective details","Constraints: no network; no push; no merge; no issue mutation.","<!-- agent-workflow:ac-block:start -->","```json",JSON.stringify(o.acceptance.criteria),"```","<!-- agent-workflow:ac-block:end -->"].join("\n"));
NODE
node - "$REPO" "$BASE" "$HEAD" "$BRANCH" <<'NODE'
const fs=require("fs"),path=require("path");const [root,base,head,branch]=process.argv.slice(2);fs.writeFileSync(path.join(root,".review/ISSUE-17-PR-DRAFT.json"),JSON.stringify({schema_version:"1",artifact_type:"pr_draft",lifecycle:"active",producer_role:"CODEX",issue:{number:17,title:"capsule"},branch,base_sha:base,head_sha:head,summary:"done",files_touched:[{path:"a.txt",change:"edit"}],tests:["bash smoke — PASS"],verify_cmd:"bash smoke",risks:["risk "+"x".repeat(500)],status:"ready_for_review",worktree_path:root}));fs.writeFileSync(path.join(root,".review/ISSUE-17-REVIEW.json"),JSON.stringify({schema_version:"1",artifact_type:"review",lifecycle:"final",producer_role:"REVIEWER",issue:{number:17},reviewed_head_sha:head,status:"fail",checklist:[{item:"behavior",met:false}],findings:[{severity:"fix",description:"finding "+"y".repeat(500),file:"a.txt"}],patch_instructions:"repair"}));
NODE

# AC-CAPSULE-1/2/3: render, schema, digest, deterministic bytes and roundtrip check.
TOKENS=1200 run >"$TMP/render" 2>&1; ec=$?; cp "$REPO/.review/ISSUE-17-REVIEW-CAPSULE.json" "$TMP/first.json"; cp "$REPO/.review/ISSUE-17-REVIEW-CAPSULE.md" "$TMP/first.md"
TOKENS=1200 run >"$TMP/render2" 2>&1; if [ "$ec" -eq 0 ] && cmp -s "$TMP/first.json" "$REPO/.review/ISSUE-17-REVIEW-CAPSULE.json" && cmp -s "$TMP/first.md" "$REPO/.review/ISSUE-17-REVIEW-CAPSULE.md" && TOKENS=1200 run --check >/dev/null 2>&1; then ok "AC-CAPSULE-3 deterministic render and fresh roundtrip"; else bad "AC-CAPSULE-3 deterministic render"; fi
if node - "$ROOT/scripts/lib/json-schema-subset.cjs" "$ROOT/schemas/review_capsule.schema.json" "$REPO/.review/ISSUE-17-REVIEW-CAPSULE.json" <<'NODE'
const fs=require("fs"),{validate}=require(process.argv[2]);process.exit(validate(JSON.parse(fs.readFileSync(process.argv[3])),JSON.parse(fs.readFileSync(process.argv[4]))).length?1:0)
NODE
then ok "AC-CAPSULE-2 generated capsule is schema-valid"; else bad "AC-CAPSULE-2 schema"; fi
if node - "$ROOT/scripts/lib/json-schema-subset.cjs" "$ROOT/schemas/review_capsule.schema.json" "$ROOT/schemas/fixtures/review_capsule.valid.json" "$ROOT/schemas/fixtures/review_capsule.invalid.json" <<'NODE'
const fs=require("fs"),{validate}=require(process.argv[2]),schema=JSON.parse(fs.readFileSync(process.argv[3])),valid=JSON.parse(fs.readFileSync(process.argv[4])),invalid=JSON.parse(fs.readFileSync(process.argv[5]));process.exit(!validate(schema,valid).length&&validate(schema,invalid).length?0:1)
NODE
then ok "AC-CAPSULE-8 schema fixtures accept valid and reject invalid"; else bad "AC-CAPSULE-8 schema fixtures"; fi
if grep -q 'AC-CAPSULE-1' "$REPO/.review/ISSUE-17-REVIEW-CAPSULE.md" && grep -q 'full canonical text is retained' "$REPO/.review/ISSUE-17-REVIEW-CAPSULE.md" && grep -q 'Reviewer output contract' "$REPO/.review/ISSUE-17-REVIEW-CAPSULE.md"; then ok "AC-CAPSULE-2 reviewer markdown carries canonical sections"; else bad "AC-CAPSULE-2 markdown sections"; fi
if node -e 'const c=require(process.argv[1]);process.exit(JSON.stringify(c.prohibitions)===JSON.stringify(["no network","no push","no merge","no issue mutation"])?0:1)' "$REPO/.review/ISSUE-17-REVIEW-CAPSULE.json"; then ok "AC-CAPSULE-2 structured canonical prohibitions survive Constraints prose"; else bad "AC-CAPSULE-2 structured prohibition authority"; fi

# AC-CAPSULE-4/5: truncation visible, immutable sections retained, secrets excluded.
if node -e 'const o=require(process.argv[1]);process.exit(o.budget.truncated_sections.length&&o.acceptance.length===2&&o.prohibitions.length?0:1)' "$REPO/.review/ISSUE-17-REVIEW-CAPSULE.json" && ! grep -q 'hunter2\|do-not-copy' "$REPO/.review/ISSUE-17-REVIEW-CAPSULE."{json,md}; then ok "AC-CAPSULE-4 bounded sections truncate visibly and secrets are excluded"; else bad "AC-CAPSULE-4/5 budget or secret hygiene"; fi
TOKENS=10 run >"$TMP/small" 2>&1; if [ "$?" -ne 0 ] && grep -q 'minimum is' "$TMP/small"; then ok "AC-CAPSULE-4 too-small budget fails with minimum"; else bad "AC-CAPSULE-4 minimum budget"; fi
cp "$REPO/.review/ISSUE-17-REVIEW.json" "$TMP/review-before-volume"
node - "$REPO/.review/ISSUE-17-REVIEW.json" <<'NODE'
const fs=require("fs"),file=process.argv[2],review=JSON.parse(fs.readFileSync(file));
review.findings=Array.from({length:100},(_,i)=>({severity:"fix",description:`finding-${i} ${"detail ".repeat(80)}`,file:"a.txt"}));
fs.writeFileSync(file,JSON.stringify(review));
NODE
TOKENS=1200 run >"$TMP/volume" 2>&1
if [ "$?" -eq 0 ] && node - "$REPO/.review/ISSUE-17-REVIEW-CAPSULE.json" "$REPO/.review/ISSUE-17-REVIEW-CAPSULE.md" <<'NODE'
const fs=require("fs"),capsule=JSON.parse(fs.readFileSync(process.argv[2])),markdown=fs.readFileSync(process.argv[3],"utf8");
const preserved=capsule.acceptance.length===2&&JSON.stringify(capsule.prohibitions)===JSON.stringify(["no network","no push","no merge","no issue mutation"]);
const omitted=capsule.budget.omitted_counts?.prior_findings>0&&markdown.includes(`[TRUNCATED ${capsule.budget.omitted_counts.prior_findings} prior findings]`);
process.exit(markdown.length<=1200*4&&preserved&&omitted?0:1);
NODE
then ok "AC-CAPSULE-4 100 findings share one cumulative 1200-token budget with omissions visible"; else bad "AC-CAPSULE-4 cumulative array budget"; fi
cp "$TMP/review-before-volume" "$REPO/.review/ISSUE-17-REVIEW.json"; TOKENS=1200 run >/dev/null 2>&1

# Full-prompt tamper beyond AC changes digest and invalidates --check.
cp "$REPO/.review/ISSUE-17-PROMPT.md" "$TMP/prompt"; printf '\nchanged outside AC\n' >> "$REPO/.review/ISSUE-17-PROMPT.md"; TOKENS=1200 run --check >"$TMP/tamper" 2>&1; if [ "$?" -ne 0 ] && grep -q 'stale' "$TMP/tamper"; then ok "AC-CAPSULE-3 full-prompt tamper invalidates reuse"; else bad "AC-CAPSULE-3 prompt tamper"; fi; cp "$TMP/prompt" "$REPO/.review/ISSUE-17-PROMPT.md"

# AC-CAPSULE-6: an existing canonical review turns the next review into a gated re-review.
bash "$SCRIPT_DIR/../cmux-dispatch.sh" --issue 17 --worktree "$REPO" --produce-review --re-review --model gpt-5.6-sol --effort medium --prompt-file .review/ISSUE-17-REVIEW-CAPSULE.md --review-capsule .review/ISSUE-17-REVIEW-CAPSULE.json --dry-run >"$TMP/dispatch" 2>&1
if [ "$?" -eq 0 ]; then ok "AC-CAPSULE-6 fresh capsule admits re-review dispatch"; else bad "AC-CAPSULE-6 fresh dispatch ($(cat "$TMP/dispatch"))"; fi
bash "$SCRIPT_DIR/../cmux-dispatch.sh" --issue 17 --worktree "$REPO" --produce-review --re-review --model gpt-5.6-sol --effort medium --review-capsule .review/ISSUE-17-REVIEW-CAPSULE.json --dry-run >"$TMP/auto-prompt" 2>&1
if [ "$?" -eq 0 ] && grep -q 'ISSUE-17-REVIEW-CAPSULE.md' "$TMP/auto-prompt"; then ok "AC-CAPSULE-6 omitted prompt auto-selects canonical capsule Markdown"; else bad "AC-CAPSULE-6 canonical prompt auto-selection"; fi
printf '%s\n' 'unrelated reviewer prompt' > "$REPO/.review/unrelated.md"
bash "$SCRIPT_DIR/../cmux-dispatch.sh" --issue 17 --worktree "$REPO" --produce-review --re-review --model gpt-5.6-sol --effort medium --prompt-file .review/unrelated.md --review-capsule .review/ISSUE-17-REVIEW-CAPSULE.json --dry-run >"$TMP/unrelated-prompt" 2>&1
if [ "$?" -ne 0 ] && grep -q 'canonical capsule Markdown' "$TMP/unrelated-prompt"; then ok "AC-CAPSULE-6 unrelated re-review prompt is rejected"; else bad "AC-CAPSULE-6 unrelated prompt gate"; fi
bash "$SCRIPT_DIR/../cmux-dispatch.sh" --issue 17 --worktree "$REPO" --produce-review --re-review --model gpt-5.6-sol --effort medium --prompt-file .review/ISSUE-17-REVIEW-CAPSULE.md --dry-run >"$TMP/no-capsule" 2>&1
if [ "$?" -ne 0 ] && grep -q 're-review requires' "$TMP/no-capsule"; then ok "AC-CAPSULE-6 re-review without capsule is rejected"; else bad "AC-CAPSULE-6 missing capsule gate"; fi

# AC-CAPSULE-1/5/8 failure matrix: stale/mismatch, dirty tracked source, traversal.
cp "$REPO/.review/ISSUE-17-ROUND-STATE.json" "$TMP/state"; node -e 'const fs=require("fs"),f=process.argv[1],o=require(f);o.revision=4;fs.writeFileSync(f,JSON.stringify(o))' "$REPO/.review/ISSUE-17-ROUND-STATE.json"; TOKENS=1200 run >/dev/null 2>&1; [ "$?" -ne 0 ] && ok "AC-CAPSULE-1 revision mismatch rejected" || bad "AC-CAPSULE-1 revision mismatch"; cp "$TMP/state" "$REPO/.review/ISSUE-17-ROUND-STATE.json"
for field in issue worktree head; do
  cp "$TMP/state" "$REPO/.review/ISSUE-17-ROUND-STATE.json"
  node - "$REPO/.review/ISSUE-17-ROUND-STATE.json" "$field" <<'NODE'
const fs=require("fs"),[f,field]=process.argv.slice(2),o=JSON.parse(fs.readFileSync(f));if(field==="issue")o.issue.number=18;if(field==="worktree")o.worktree_path="/tmp";if(field==="head")o.head_sha="0000000000000000000000000000000000000000";fs.writeFileSync(f,JSON.stringify(o));
NODE
  TOKENS=1200 run >/dev/null 2>&1; [ "$?" -ne 0 ] && ok "AC-CAPSULE-8 ROUND-STATE $field mismatch rejected" || bad "AC-CAPSULE-8 ROUND-STATE $field mismatch"
done
cp "$TMP/state" "$REPO/.review/ISSUE-17-ROUND-STATE.json"
cp "$REPO/.review/ISSUE-17-REVIEW.json" "$TMP/review"; node -e 'const fs=require("fs"),f=process.argv[1],o=require(f);o.lifecycle="draft";fs.writeFileSync(f,JSON.stringify(o))' "$REPO/.review/ISSUE-17-REVIEW.json"; TOKENS=1200 run >/dev/null 2>&1; [ "$?" -ne 0 ] && ok "AC-CAPSULE-1 unpublished review rejected" || bad "AC-CAPSULE-1 unpublished review"; cp "$TMP/review" "$REPO/.review/ISSUE-17-REVIEW.json"
printf '%s\n' '{bad' > "$REPO/.review/ISSUE-17-REVIEW.json"; TOKENS=1200 run >/dev/null 2>&1; [ "$?" -ne 0 ] && ok "AC-CAPSULE-8 malformed review rejected" || bad "AC-CAPSULE-8 malformed review"; cp "$TMP/review" "$REPO/.review/ISSUE-17-REVIEW.json"
cp "$REPO/.review/ISSUE-17-PR-DRAFT.json" "$TMP/pr"; node -e 'const fs=require("fs"),f=process.argv[1],o=require(f);o.head_sha="0000000000000000000000000000000000000000";fs.writeFileSync(f,JSON.stringify(o))' "$REPO/.review/ISSUE-17-PR-DRAFT.json"; TOKENS=1200 run >/dev/null 2>&1; [ "$?" -ne 0 ] && ok "AC-CAPSULE-1 stale PR-DRAFT rejected" || bad "AC-CAPSULE-1 stale PR-DRAFT"; cp "$TMP/pr" "$REPO/.review/ISSUE-17-PR-DRAFT.json"
for field in worktree base; do
  cp "$TMP/pr" "$REPO/.review/ISSUE-17-PR-DRAFT.json"
  node - "$REPO/.review/ISSUE-17-PR-DRAFT.json" "$field" <<'NODE'
const fs=require("fs"),[file,field]=process.argv.slice(2),value=JSON.parse(fs.readFileSync(file));
if(field==="worktree") value.worktree_path="/tmp";
if(field==="base") value.base_sha="0000000000000000000000000000000000000000";
fs.writeFileSync(file,JSON.stringify(value));
NODE
  TOKENS=1200 run >/dev/null 2>&1; [ "$?" -ne 0 ] && ok "AC-CAPSULE-1 PR-DRAFT $field mismatch rejected" || bad "AC-CAPSULE-1 PR-DRAFT $field mismatch"
done
cp "$TMP/pr" "$REPO/.review/ISSUE-17-PR-DRAFT.json"
mv "$REPO/.review/ISSUE-17-REVIEW.json" "$TMP/review-missing"; TOKENS=1200 run >/dev/null 2>&1; [ "$?" -ne 0 ] && ok "AC-CAPSULE-8 missing canonical input rejected" || bad "AC-CAPSULE-8 missing input"; mv "$TMP/review-missing" "$REPO/.review/ISSUE-17-REVIEW.json"
printf '%s\n' dirty >> "$REPO/a.txt"; TOKENS=1200 run >/dev/null 2>&1; [ "$?" -ne 0 ] && ok "AC-CAPSULE-1 dirty worktree rejected" || bad "AC-CAPSULE-1 dirty worktree"; git -C "$REPO" restore a.txt
(cd "$REPO" && bash "$RENDER" --issue 17 --worktree "$REPO" --round-state ../outside.json --prompt .review/ISSUE-17-PROMPT.md --pr-draft .review/ISSUE-17-PR-DRAFT.json --review .review/ISSUE-17-REVIEW.json --manifest-revision 3 --target-tokens 1200) >/dev/null 2>&1; [ "$?" -ne 0 ] && ok "AC-CAPSULE-5 traversal source rejected" || bad "AC-CAPSULE-5 traversal"

# AC-CAPSULE-6 canonical sources remain authority; AC-CAPSULE-7 scratch is ignored; AC-CAPSULE-9 docs synced.
if git -C "$ROOT/.." check-ignore -q .review/ISSUE-999-PROMPT.md && git -C "$ROOT/.." check-ignore -q .review/ISSUE-999-CONTEXT.md && git -C "$ROOT/.." check-ignore -q .review/ISSUE-999-REVIEW-CAPSULE.md; then ok "AC-CAPSULE-7 canonical runtime scratch patterns are ignored"; else bad "AC-CAPSULE-7 runtime scratch ignore"; fi
echo "---"; if [ "$FAILURES" -eq 0 ]; then echo "ALL CASES PASS"; exit 0; fi; echo "$FAILURES CASE(S) FAILED"; exit 1
