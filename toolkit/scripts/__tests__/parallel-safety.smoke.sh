#!/usr/bin/env bash
# AC-PAR-1 AC-PAR-2 AC-PAR-3 AC-PAR-4 AC-PAR-5 AC-PAR-6 AC-PAR-7 AC-PAR-8
# Offline deterministic parallel-plan and integrated-candidate closure contract.
# bash-3.2-compatible.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLAN="$ROOT/scripts/parallel-plan.sh"
INTEGRATE="$ROOT/scripts/candidate-integrate.sh"
CLOSE="$ROOT/scripts/candidate-close.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
if [ -z "${AGENT_WORKFLOW_CODEX_BIN:-}" ]; then
  RUNTIME_FAKE="$TMP/codex-runtime-fake"
  cat > "$RUNTIME_FAKE" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo 'codex parallel smoke 1.0'; exit 0 ;;
  --help) echo 'Commands: exec'; exit 0 ;;
  exec) [ "${2:-}" = "--help" ] && { echo 'exec --sandbox --cd --model --config --output-last-message'; exit 0; } ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$RUNTIME_FAKE"
  export AGENT_WORKFLOW_CODEX_BIN="$RUNTIME_FAKE"
fi
FAILURES=0
pass(){ echo "ok   - $1"; }
fail(){ echo "NOT OK - $1"; FAILURES=$((FAILURES + 1)); }

write_plan() {
  file="$1"; base="$2"; mode_a="$3"; path_a="$4"; mode_b="$5"; path_b="$6"; deps_b="$7"
  node - "$file" "$base" "$mode_a" "$path_a" "$mode_b" "$path_b" "$deps_b" <<'NODE'
const fs=require("fs"); const [file,base,ma,pa,mb,pb,deps]=process.argv.slice(2);
const paths = (mode,p) => mode === "exact" ? [p] : [];
const v={schema_version:"1",artifact_type:"execution_plan",lifecycle:"active",producer_role:"CONDUCTOR",issue:14,round:1,manifest_revision:1,plan_revision:1,base_head:base,
 seats:[{id:"api",write_set:{mode:ma,paths:paths(ma,pa)},depends_on:[]},{id:"ui",write_set:{mode:mb,paths:paths(mb,pb)},depends_on:deps?deps.split(",").filter(Boolean):[]}],
 integration_order:["api","ui"],parallel_policy:{shared_mutation_paths:["package-lock.json"],database_isolation:"not_required",environment_isolation:"isolated_per_seat",rate_limit_budget:"not_required"},required_evidence:["review","verification","pr_draft","completion","seat_outcome"],candidate_closure:{retry_policy:"complete_fresh_same_head_set",require_clean_candidate:true,unresolved_blockers:"deny"}};
fs.writeFileSync(file,JSON.stringify(v,null,2)+"\n");
NODE
}

BASE="$TMP/base"
mkdir -p "$BASE/src/api" "$BASE/src/ui" "$BASE/src/shared/a"
git init -q "$BASE"
printf '%s\n' base > "$BASE/src/api/base.txt"
printf '%s\n' base > "$BASE/src/ui/base.txt"
printf '%s\n' base > "$BASE/src/shared/a/file.txt"
git -C "$BASE" add . && git -C "$BASE" -c user.name=smoke -c user.email=smoke@example.test commit -qm base
BASE_HEAD="$(git -C "$BASE" rev-parse HEAD)"
GOOD_PLAN="$TMP/good-plan.json"
write_plan "$GOOD_PLAN" "$BASE_HEAD" exact src/api exact src/ui ""

out1="$TMP/decision-1.json"; out2="$TMP/decision-2.json"
bash "$PLAN" decide --plan "$GOOD_PLAN" --target "$BASE" > "$out1"
bash "$PLAN" decide --plan "$GOOD_PLAN" --target "$BASE" > "$out2"
if cmp -s "$out1" "$out2" && grep -q 'parallel_eligible' "$out1" && grep -q 'disjoint_exact_write_sets' "$out1"; then pass "deterministic disjoint plan is byte-equivalent and parallel eligible"; else fail "deterministic disjoint decision"; fi

OVERLAP="$TMP/overlap.json"; write_plan "$OVERLAP" "$BASE_HEAD" exact src/shared/a exact src/shared ""
UNKNOWN="$TMP/unknown.json"; write_plan "$UNKNOWN" "$BASE_HEAD" unknown ignored exact src/ui ""
DEPEND="$TMP/depend.json"; write_plan "$DEPEND" "$BASE_HEAD" exact src/api exact src/ui api
if bash "$PLAN" decide --plan "$OVERLAP" --target "$BASE" | grep -q 'write_set_overlap' \
  && bash "$PLAN" decide --plan "$UNKNOWN" --target "$BASE" | grep -q 'unproven_write_set' \
  && bash "$PLAN" decide --plan "$DEPEND" --target "$BASE" | grep -q 'dependency_order'; then
  pass "overlap, unknown, and dependency constraints serialize conservatively"
else fail "conservative serialization reasons"; fi
ISOLATION="$TMP/isolation.json"; cp "$GOOD_PLAN" "$ISOLATION"
node -e 'const fs=require("fs"),f=process.argv[1],v=JSON.parse(fs.readFileSync(f));v.parallel_policy.environment_isolation="unproven";fs.writeFileSync(f,JSON.stringify(v));' "$ISOLATION"
ONE="$TMP/one-seat.json"; cp "$GOOD_PLAN" "$ONE"
node -e 'const fs=require("fs"),f=process.argv[1],v=JSON.parse(fs.readFileSync(f));v.seats=[v.seats[0]];v.integration_order=["api"];fs.writeFileSync(f,JSON.stringify(v));' "$ONE"
if bash "$PLAN" decide --plan "$ISOLATION" --target "$BASE" | grep -q isolation_or_budget_unproven \
  && bash "$PLAN" decide --plan "$ONE" --target "$BASE" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.exit(JSON.parse(s).pairs.length===0?0:1));'; then
  pass "unproven isolation serializes and a sequential one-seat plan remains valid"
else fail "isolation and one-seat compatibility"; fi

CYCLE="$TMP/cycle.json"; cp "$DEPEND" "$CYCLE"
node -e 'const fs=require("fs"),f=process.argv[1],v=JSON.parse(fs.readFileSync(f));v.seats[0].depends_on=["ui"];fs.writeFileSync(f,JSON.stringify(v));' "$CYCLE"
cycle_out="$TMP/cycle.out"; bash "$PLAN" decide --plan "$CYCLE" --target "$BASE" > "$cycle_out"; ec=$?
if [ "$ec" -eq 2 ] && grep -Eq 'dependency_cycle|dependency_cycle_or_order' "$cycle_out"; then pass "dependency cycle is rejected"; else fail "dependency cycle rejection"; fi

TRAVERSAL="$TMP/traversal.json"; cp "$GOOD_PLAN" "$TRAVERSAL"
node -e 'const fs=require("fs"),f=process.argv[1],v=JSON.parse(fs.readFileSync(f));v.seats[0].write_set.paths=["../escape"];fs.writeFileSync(f,JSON.stringify(v));' "$TRAVERSAL"
mkdir -p "$TMP/outside"; ln -s "$TMP/outside" "$BASE/escape-link"
SYMLINK="$TMP/symlink.json"; cp "$GOOD_PLAN" "$SYMLINK"
node -e 'const fs=require("fs"),f=process.argv[1],v=JSON.parse(fs.readFileSync(f));v.seats[0].write_set.paths=["escape-link/file"];fs.writeFileSync(f,JSON.stringify(v));' "$SYMLINK"
if ! bash "$PLAN" decide --plan "$TRAVERSAL" --target "$BASE" > "$TMP/traversal.out" \
  && grep -q invalid_write_path "$TMP/traversal.out" \
  && ! bash "$PLAN" decide --plan "$SYMLINK" --target "$BASE" > "$TMP/symlink.out" \
  && grep -q symlink_escape "$TMP/symlink.out"; then pass "traversal and symlink escape are rejected"; else fail "path containment"; fi

# Real source repos and candidate for integration.
API="$TMP/api"; UI="$TMP/ui"; CAND="$TMP/candidate"
git clone -q "$BASE" "$API"; git clone -q "$BASE" "$UI"; git clone -q "$BASE" "$CAND"
printf '%s\n' api > "$API/src/api/feature.txt"; git -C "$API" add . && git -C "$API" -c user.name=smoke -c user.email=smoke@example.test commit -qm api
printf '%s\n' ui > "$UI/src/ui/feature.txt"; git -C "$UI" add . && git -C "$UI" -c user.name=smoke -c user.email=smoke@example.test commit -qm ui
API_HEAD="$(git -C "$API" rev-parse HEAD)"; UI_HEAD="$(git -C "$UI" rev-parse HEAD)"
mkdir -p "$CAND/.review"
INTEGRATION="$CAND/.review/ISSUE-14-INTEGRATION.json"
bash "$INTEGRATE" --plan "$GOOD_PLAN" --target "$CAND" --candidate-worktree "$CAND" \
  --source "api=$API@$API_HEAD" --source "ui=$UI@$UI_HEAD" --output "$INTEGRATION" > "$TMP/integrate.out"; ec=$?
if [ "$ec" -eq 0 ] && [ -f "$CAND/src/api/feature.txt" ] && [ -f "$CAND/src/ui/feature.txt" ] \
  && node -e 'const v=require(process.argv[1]);process.exit(v.status==="pass"&&v.steps.length===2&&v.steps.every(x=>x.status==="integrated")?0:1)' "$INTEGRATION"; then
  pass "declared topological order records source and resulting candidate heads"
else fail "successful candidate integration ($(cat "$TMP/integrate.out"))"; fi
CAND_HEAD="$(git -C "$CAND" rev-parse HEAD)"

# Unexpected paths and stale source heads fail before candidate mutation.
BAD_SRC="$TMP/bad-src"; BAD_CAND="$TMP/bad-candidate"; git clone -q "$BASE" "$BAD_SRC"; git clone -q "$BASE" "$BAD_CAND"; mkdir -p "$BAD_CAND/.review"
printf '%s\n' bad > "$BAD_SRC/outside.txt"; git -C "$BAD_SRC" add . && git -C "$BAD_SRC" -c user.name=smoke -c user.email=smoke@example.test commit -qm bad
BAD_HEAD="$(git -C "$BAD_SRC" rev-parse HEAD)"
bash "$INTEGRATE" --plan "$GOOD_PLAN" --target "$BAD_CAND" --candidate-worktree "$BAD_CAND" --source "api=$BAD_SRC@$BAD_HEAD" --source "ui=$UI@$UI_HEAD" --output "$BAD_CAND/.review/result.json" > "$TMP/unexpected.out"; ec=$?
if [ "$ec" -eq 1 ] && grep -q unexpected_changed_path "$TMP/unexpected.out" && [ "$(git -C "$BAD_CAND" rev-parse HEAD)" = "$BASE_HEAD" ]; then pass "unexpected path blocks before candidate mutation"; else fail "unexpected path gate"; fi
bash "$INTEGRATE" --plan "$GOOD_PLAN" --target "$BAD_CAND" --candidate-worktree "$BAD_CAND" --source "api=$API@$BASE_HEAD" --source "ui=$UI@$UI_HEAD" --output "$BAD_CAND/.review/stale.json" > "$TMP/stale-source.out"; ec=$?
if [ "$ec" -eq 1 ] && grep -q stale_source_head "$TMP/stale-source.out"; then pass "stale source head blocks integration"; else fail "stale source head gate"; fi
UNREBASED="$TMP/unrebased"; git init -q "$UNREBASED"; mkdir -p "$UNREBASED/src/api"; printf '%s\n' unrelated > "$UNREBASED/src/api/file.txt"; git -C "$UNREBASED" add . && git -C "$UNREBASED" -c user.name=smoke -c user.email=smoke@example.test commit -qm unrelated
git -C "$UNREBASED" fetch -q "$BASE" "$(git -C "$BASE" branch --show-current)"
bash "$INTEGRATE" --plan "$GOOD_PLAN" --target "$BAD_CAND" --candidate-worktree "$BAD_CAND" --source "api=$UNREBASED@$(git -C "$UNREBASED" rev-parse HEAD)" --source "ui=$UI@$UI_HEAD" --output "$BAD_CAND/.review/unrebased.json" > "$TMP/unrebased.out"; ec=$?
if [ "$ec" -eq 1 ] && grep -q source_not_rebased "$TMP/unrebased.out"; then pass "missing source rebase blocks integration"; else fail "source rebase gate ($(cat "$TMP/unrebased.out"))"; fi

# Serialized overlapping seats can still integrate in order, but conflicting
# deltas block and are never auto-reset/aborted.
LEFT="$TMP/left"; RIGHT="$TMP/right"; CONFLICT="$TMP/conflict"; git clone -q "$BASE" "$LEFT"; git clone -q "$BASE" "$RIGHT"; git clone -q "$BASE" "$CONFLICT"; mkdir -p "$CONFLICT/.review"
printf '%s\n' left > "$LEFT/src/shared/a/file.txt"; git -C "$LEFT" add . && git -C "$LEFT" -c user.name=smoke -c user.email=smoke@example.test commit -qm left
printf '%s\n' right > "$RIGHT/src/shared/a/file.txt"; git -C "$RIGHT" add . && git -C "$RIGHT" -c user.name=smoke -c user.email=smoke@example.test commit -qm right
bash "$INTEGRATE" --plan "$OVERLAP" --target "$CONFLICT" --candidate-worktree "$CONFLICT" --source "api=$LEFT@$(git -C "$LEFT" rev-parse HEAD)" --source "ui=$RIGHT@$(git -C "$RIGHT" rev-parse HEAD)" --output "$CONFLICT/.review/result.json" > "$TMP/conflict.out"; ec=$?
if [ "$ec" -eq 1 ] && grep -q integration_conflict "$TMP/conflict.out"; then pass "integration conflict blocks without destructive cleanup"; else fail "integration conflict gate ($(cat "$TMP/conflict.out"))"; fi

# Admission identity/write-set and immutable same-seat consumption.
ADMIT="$TMP/admit"; git clone -q "$BASE" "$ADMIT"; mkdir -p "$ADMIT/.review"
cp "$GOOD_PLAN" "$ADMIT/.review/ISSUE-14-EXECUTION-PLAN.json"
cp "$ROOT/schemas/fixtures/round_state.valid.json" "$ADMIT/.review/ISSUE-14-ROUND-STATE.json"
node - "$ADMIT/.review/ISSUE-14-ROUND-STATE.json" "$ADMIT" "$BASE_HEAD" "$(git -C "$ADMIT" branch --show-current)" <<'NODE'
const fs=require("fs"),[f,wt,head,branch]=process.argv.slice(2),v=JSON.parse(fs.readFileSync(f));v.issue={number:14,title:"parallel"};v.revision=1;v.base_sha=head;v.head_sha=head;v.base_branch=branch;v.worktree_path=fs.realpathSync(wt);v.contract.touch_allowlist=["src/api"];delete v.round_control;fs.writeFileSync(f,JSON.stringify(v));
NODE
node - "$ADMIT/.review/ISSUE-14-ROUND-STATE.json" "$ADMIT/.review/ISSUE-14-PROMPT.md" <<'NODE'
const fs=require("fs"),[stateFile,promptFile]=process.argv.slice(2),v=JSON.parse(fs.readFileSync(stateFile));fs.writeFileSync(promptFile,["worker","<!-- agent-workflow:ac-block:start -->","```json",JSON.stringify(v.acceptance.criteria),"```","<!-- agent-workflow:ac-block:end -->",""] .join("\n"));
NODE
ADMIT_TIER="$(node -e 'process.stdout.write(require(process.argv[1]).tier.name)' "$ADMIT/.review/ISSUE-14-ROUND-STATE.json")"
planned_dry="$TMP/planned-dry.out"
bash "$ROOT/scripts/cmux-dispatch.sh" --issue 14 --worktree "$ADMIT" --tier "$ADMIT_TIER" \
  --round-state "$ADMIT/.review/ISSUE-14-ROUND-STATE.json" --manifest-revision 1 \
  --execution-plan "$ADMIT/.review/ISSUE-14-EXECUTION-PLAN.json" --seat api --dry-run > "$planned_dry" 2>&1; ec=$?
if [ "$ec" -eq 0 ] && grep -q 'cmux workspace create' "$planned_dry"; then pass "dispatch consumes a validated canonical plan binding before launch"; else fail "planned dispatch admission ($(cat "$planned_dry"))"; fi
bash "$PLAN" admit --plan "$ADMIT/.review/ISSUE-14-EXECUTION-PLAN.json" --target "$ADMIT" --round-state "$ADMIT/.review/ISSUE-14-ROUND-STATE.json" --issue 14 --revision 1 --seat api --consume true > "$TMP/admit-one.out" & p1=$!
bash "$PLAN" admit --plan "$ADMIT/.review/ISSUE-14-EXECUTION-PLAN.json" --target "$ADMIT" --round-state "$ADMIT/.review/ISSUE-14-ROUND-STATE.json" --issue 14 --revision 1 --seat api --consume true > "$TMP/admit-two.out" & p2=$!
wait "$p1"; e1=$?; wait "$p2"; e2=$?; successes=0; [ "$e1" -eq 0 ] && successes=$((successes+1)); [ "$e2" -eq 0 ] && successes=$((successes+1))
if [ "$successes" -eq 1 ] && { grep -q parallel_admission_already_consumed "$TMP/admit-one.out" || grep -q parallel_admission_already_consumed "$TMP/admit-two.out"; }; then pass "concurrent same-seat plan admission is single-use"; else fail "concurrent plan admission"; fi
node -e 'const fs=require("fs"),f=process.argv[1],v=JSON.parse(fs.readFileSync(f));v.contract.touch_allowlist=["src/ui"];fs.writeFileSync(f,JSON.stringify(v));' "$ADMIT/.review/ISSUE-14-ROUND-STATE.json"
if ! bash "$PLAN" admit --plan "$ADMIT/.review/ISSUE-14-EXECUTION-PLAN.json" --target "$ADMIT" --round-state "$ADMIT/.review/ISSUE-14-ROUND-STATE.json" --issue 14 --revision 1 --seat api --consume false > "$TMP/write-mismatch.out" \
  && grep -q plan_write_set_mismatch "$TMP/write-mismatch.out"; then pass "plan admission binds seat write set before launch"; else fail "write-set admission mismatch"; fi

# Build canonical candidate evidence at the integrated HEAD.
make_evidence() {
  attempt="$1"; review_head="$2"; verify_status="$3"; mixed="$4"
  node - "$ROOT" "$CAND" "$CAND_HEAD" "$BASE_HEAD" "$attempt" "$review_head" "$verify_status" "$mixed" "$INTEGRATION" <<'NODE'
const fs=require("fs"),path=require("path"),crypto=require("crypto");
const [root,wt,head,base,attempt,reviewHead,verifyStatus,mixed,integration]=process.argv.slice(2),issue=14,reviewDir=path.join(wt,".review");
const read=p=>JSON.parse(fs.readFileSync(p)),write=(p,v)=>fs.writeFileSync(p,JSON.stringify(v,null,2)+"\n"),hash=p=>crypto.createHash("sha256").update(fs.readFileSync(p)).digest("hex");
const identity={issue,round:1,manifest_revision:1,plan_revision:1};
const binding={...identity,candidate_head:head,attempt_id:attempt,generated_at:"2099-01-01T00:00:00Z"};
const review=read(path.join(root,"schemas/fixtures/review.valid.json"));review.issue.number=issue;review.reviewed_head_sha=reviewHead;review.closure_binding=binding;write(path.join(reviewDir,`ISSUE-${issue}-REVIEW.json`),review);
const verify=read(path.join(root,"schemas/fixtures/verify.valid.json"));verify.issue=issue;verify.head_sha=head;verify.branch="candidate";
if(verifyStatus==="fail"){verify.classifier="FAIL";verify.verdict={passed:0,failed:1,pending:0,exit_code:1};verify.failures=["failed"];verify.runs[0].classifier="FAIL";verify.runs[0].verdict={passed:0,failed:1,pending:0,exit_code:1};verify.runs[0].failures=["failed"];}
verify.closure_binding=binding;
write(path.join(reviewDir,`ISSUE-${issue}-VERIFY.json`),verify);
const pr=read(path.join(root,"schemas/fixtures/pr_draft.valid.json"));pr.issue.number=issue;pr.base_sha=base;pr.head_sha=head;pr.branch="candidate";pr.status="ready_for_review";pr.closure_binding=binding;if(pr.verify_result)pr.verify_result.verified_head_sha=head;write(path.join(reviewDir,`ISSUE-${issue}-PR-DRAFT.json`),pr);
write(path.join(reviewDir,`ISSUE-${issue}-COMPLETION.json`),{schema_version:"1",artifact_type:"completion_evidence",producer_role:"CONDUCTOR",...identity,head_sha:head,status:"pass",created_at:"2099-01-01T00:00:00Z",closure_binding:binding});
const ir=read(integration);for(const step of ir.steps)write(path.join(reviewDir,`ISSUE-${issue}-SEAT-${step.seat_id}.json`),{schema_version:"1",artifact_type:"seat_outcome",producer_role:"CONDUCTOR",...identity,seat_id:step.seat_id,source_head:step.source_head,changed_paths:step.changed_paths,status:"pass",created_at:"2099-01-01T00:00:00Z",closure_binding:binding});
const evidence=[];for(const kind of ["review","verification","pr_draft","completion"]){const names={review:"REVIEW",verification:"VERIFY",pr_draft:"PR-DRAFT",completion:"COMPLETION"},p=`.review/ISSUE-${issue}-${names[kind]}.json`,abs=path.join(wt,p);evidence.push({kind,path:p,sha256:hash(abs),status:kind==="verification"&&verifyStatus==="fail"?"fail":"pass",attempt_id:attempt});}
for(const step of ir.steps){const p=`.review/ISSUE-${issue}-SEAT-${step.seat_id}.json`,abs=path.join(wt,p);evidence.push({kind:"seat_outcome",seat_id:step.seat_id,path:p,sha256:hash(abs),status:"pass",attempt_id:mixed==="yes"&&step.seat_id==="ui"?"other-attempt":attempt});}
write(path.join(reviewDir,`ISSUE-${issue}-CANDIDATE-EVIDENCE.json`),{schema_version:"1",artifact_type:"candidate_evidence_set",producer_role:"CONDUCTOR",...identity,candidate_head:head,attempt_id:attempt,created_at:"2099-01-01T00:00:00Z",evidence});
NODE
}

EVIDENCE="$CAND/.review/ISSUE-14-CANDIDATE-EVIDENCE.json"; CLOSURE="$CAND/.review/ISSUE-14-CLOSURE.json"
make_evidence attempt-1 "$API_HEAD" pass no
bash "$CLOSE" evaluate --plan "$GOOD_PLAN" --target "$CAND" --candidate-worktree "$CAND" --integration "$INTEGRATION" --evidence-set "$EVIDENCE" --output "$CLOSURE" > "$TMP/worker-green.out"; ec=$?
if [ "$ec" -eq 1 ] && grep -q candidate_review_not_green "$TMP/worker-green.out"; then pass "worker-head green review cannot close candidate HEAD"; else fail "worker-green candidate-red closure"; fi
make_evidence attempt-2 "$CAND_HEAD" fail no
bash "$CLOSE" evaluate --plan "$GOOD_PLAN" --target "$CAND" --candidate-worktree "$CAND" --integration "$INTEGRATION" --evidence-set "$EVIDENCE" --output "$CLOSURE" > "$TMP/verify-red.out"; ec=$?
if [ "$ec" -eq 1 ] && grep -q failed_verification "$TMP/verify-red.out"; then pass "failed same-HEAD verification keeps closure red"; else fail "failed verification closure"; fi
make_evidence attempt-3 "$CAND_HEAD" pass yes
bash "$CLOSE" evaluate --plan "$GOOD_PLAN" --target "$CAND" --candidate-worktree "$CAND" --integration "$INTEGRATION" --evidence-set "$EVIDENCE" --output "$CLOSURE" > "$TMP/mixed.out"; ec=$?
if [ "$ec" -eq 1 ] && grep -q mixed_attempt_evidence "$TMP/mixed.out"; then pass "mixed-attempt aggregation is rejected"; else fail "mixed attempt closure"; fi
make_evidence attempt-4 "$CAND_HEAD" pass no
printf '%s\n' changed >> "$CAND/.review/ISSUE-14-REVIEW.json"
bash "$CLOSE" evaluate --plan "$GOOD_PLAN" --target "$CAND" --candidate-worktree "$CAND" --integration "$INTEGRATION" --evidence-set "$EVIDENCE" --output "$CLOSURE" > "$TMP/hash-stale.out"; ec=$?
if [ "$ec" -eq 1 ] && grep -q evidence_hash_mismatch "$TMP/hash-stale.out"; then pass "stale mutated artifact is rejected"; else fail "stale artifact closure"; fi

# A wrapper cannot make old same-HEAD artifacts fresh by relabeling only its
# own attempt identifiers; every artifact carries the direct attempt binding.
make_evidence old-attempt "$CAND_HEAD" pass no
node - "$EVIDENCE" <<'NODE'
const fs=require("fs"),f=process.argv[2],v=JSON.parse(fs.readFileSync(f));v.attempt_id="relabeled-attempt";for(const entry of v.evidence)entry.attempt_id=v.attempt_id;fs.writeFileSync(f,JSON.stringify(v,null,2)+"\n");
NODE
bash "$CLOSE" evaluate --plan "$GOOD_PLAN" --target "$CAND" --candidate-worktree "$CAND" --integration "$INTEGRATION" --evidence-set "$EVIDENCE" --output "$CLOSURE" > "$TMP/relabel.out"; ec=$?
if [ "$ec" -eq 1 ] && grep -Eq 'candidate_review_not_green|candidate_verification_not_green' "$TMP/relabel.out"; then pass "wrapper-only attempt relabel cannot reuse old same-HEAD artifacts"; else fail "self-asserted retry freshness"; fi

# Schema-valid but inactive lifecycle states are historical artifacts, not
# current closure evidence.
make_evidence lifecycle-review "$CAND_HEAD" pass no
node - "$CAND/.review/ISSUE-14-REVIEW.json" "$EVIDENCE" <<'NODE'
const fs=require("fs"),crypto=require("crypto"),[artifact,setFile]=process.argv.slice(2);const v=JSON.parse(fs.readFileSync(artifact));v.lifecycle="superseded";fs.writeFileSync(artifact,JSON.stringify(v,null,2)+"\n");const set=JSON.parse(fs.readFileSync(setFile));set.evidence.find(x=>x.kind==="review").sha256=crypto.createHash("sha256").update(fs.readFileSync(artifact)).digest("hex");fs.writeFileSync(setFile,JSON.stringify(set,null,2)+"\n");
NODE
bash "$CLOSE" evaluate --plan "$GOOD_PLAN" --target "$CAND" --candidate-worktree "$CAND" --integration "$INTEGRATION" --evidence-set "$EVIDENCE" --output "$CLOSURE" > "$TMP/superseded-review.out"; ec=$?
review_inactive=false; [ "$ec" -eq 1 ] && grep -q candidate_review_not_green "$TMP/superseded-review.out" && review_inactive=true
make_evidence lifecycle-pr "$CAND_HEAD" pass no
node - "$CAND/.review/ISSUE-14-PR-DRAFT.json" "$EVIDENCE" <<'NODE'
const fs=require("fs"),crypto=require("crypto"),[artifact,setFile]=process.argv.slice(2);const v=JSON.parse(fs.readFileSync(artifact));v.lifecycle="draft";fs.writeFileSync(artifact,JSON.stringify(v,null,2)+"\n");const set=JSON.parse(fs.readFileSync(setFile));set.evidence.find(x=>x.kind==="pr_draft").sha256=crypto.createHash("sha256").update(fs.readFileSync(artifact)).digest("hex");fs.writeFileSync(setFile,JSON.stringify(set,null,2)+"\n");
NODE
bash "$CLOSE" evaluate --plan "$GOOD_PLAN" --target "$CAND" --candidate-worktree "$CAND" --integration "$INTEGRATION" --evidence-set "$EVIDENCE" --output "$CLOSURE" > "$TMP/draft-pr.out"; ec=$?
draft_inactive=false; [ "$ec" -eq 1 ] && grep -q candidate_pr_draft_not_ready "$TMP/draft-pr.out" && draft_inactive=true
make_evidence lifecycle-pr-2 "$CAND_HEAD" pass no
node - "$CAND/.review/ISSUE-14-PR-DRAFT.json" "$EVIDENCE" <<'NODE'
const fs=require("fs"),crypto=require("crypto"),[artifact,setFile]=process.argv.slice(2);const v=JSON.parse(fs.readFileSync(artifact));v.lifecycle="superseded";fs.writeFileSync(artifact,JSON.stringify(v,null,2)+"\n");const set=JSON.parse(fs.readFileSync(setFile));set.evidence.find(x=>x.kind==="pr_draft").sha256=crypto.createHash("sha256").update(fs.readFileSync(artifact)).digest("hex");fs.writeFileSync(setFile,JSON.stringify(set,null,2)+"\n");
NODE
bash "$CLOSE" evaluate --plan "$GOOD_PLAN" --target "$CAND" --candidate-worktree "$CAND" --integration "$INTEGRATION" --evidence-set "$EVIDENCE" --output "$CLOSURE" > "$TMP/superseded-pr.out"; ec=$?
if [ "$review_inactive" = true ] && [ "$draft_inactive" = true ] && [ "$ec" -eq 1 ] && grep -q candidate_pr_draft_not_ready "$TMP/superseded-pr.out"; then pass "only final REVIEW and active PR-DRAFT lifecycles can close"; else fail "closure lifecycle freshness"; fi

# Pattern-valid but impossible calendar dates are rejected semantically.
make_evidence timestamp-attempt "$CAND_HEAD" pass no
node -e 'const fs=require("fs"),f=process.argv[1],v=JSON.parse(fs.readFileSync(f));v.created_at="2026-02-30T00:00:00Z";fs.writeFileSync(f,JSON.stringify(v,null,2)+"\n");' "$EVIDENCE"
bash "$CLOSE" evaluate --plan "$GOOD_PLAN" --target "$CAND" --candidate-worktree "$CAND" --integration "$INTEGRATION" --evidence-set "$EVIDENCE" --output "$CLOSURE" > "$TMP/bad-time.out"; ec=$?
if [ "$ec" -eq 1 ] && grep -q invalid_candidate_timestamp "$TMP/bad-time.out"; then pass "RFC3339 calendar validity is enforced semantically"; else fail "timestamp semantic validation"; fi

# Integration evidence must correspond one-for-one, uniquely, and in the
# plan-declared order; malformed evidence blocks instead of dereferencing null.
cp "$INTEGRATION" "$TMP/integration-good.json"
make_evidence step-attempt "$CAND_HEAD" pass no
node -e 'const fs=require("fs"),f=process.argv[1],v=JSON.parse(fs.readFileSync(f));v.steps=[v.steps[0],v.steps[0]];fs.writeFileSync(f,JSON.stringify(v,null,2)+"\n");' "$INTEGRATION"
bash "$CLOSE" evaluate --plan "$GOOD_PLAN" --target "$CAND" --candidate-worktree "$CAND" --integration "$INTEGRATION" --evidence-set "$EVIDENCE" --output "$CLOSURE" > "$TMP/duplicate-step.out"; ec=$?
duplicate_blocked=false; [ "$ec" -eq 1 ] && grep -q integration_step_order_mismatch "$TMP/duplicate-step.out" && duplicate_blocked=true
cp "$TMP/integration-good.json" "$INTEGRATION"
node -e 'const fs=require("fs"),f=process.argv[1],v=JSON.parse(fs.readFileSync(f));v.steps.reverse();fs.writeFileSync(f,JSON.stringify(v,null,2)+"\n");' "$INTEGRATION"
bash "$CLOSE" evaluate --plan "$GOOD_PLAN" --target "$CAND" --candidate-worktree "$CAND" --integration "$INTEGRATION" --evidence-set "$EVIDENCE" --output "$CLOSURE" > "$TMP/reordered-step.out"; ec=$?
if [ "$duplicate_blocked" = true ] && [ "$ec" -eq 1 ] && grep -q integration_step_order_mismatch "$TMP/reordered-step.out"; then pass "duplicate, missing, and reordered integration steps block stably"; else fail "integration step correspondence"; fi
cp "$TMP/integration-good.json" "$INTEGRATION"

make_evidence attempt-5 "$CAND_HEAD" pass no
node - "$ROOT/schemas/fixtures/blocker.valid.json" "$CAND/.review/ISSUE-14-BLOCKER.json" "$CAND_HEAD" <<'NODE'
const fs=require("fs"),[src,out,head]=process.argv.slice(2),v=JSON.parse(fs.readFileSync(src));v.issue.number=14;v.head_sha=head;fs.writeFileSync(out,JSON.stringify(v));
NODE
bash "$CLOSE" evaluate --plan "$GOOD_PLAN" --target "$CAND" --candidate-worktree "$CAND" --integration "$INTEGRATION" --evidence-set "$EVIDENCE" --output "$CLOSURE" > "$TMP/blocker.out"; ec=$?
if [ "$ec" -eq 1 ] && grep -q unresolved_blocker "$TMP/blocker.out"; then pass "unresolved canonical blocker prevents closure"; else fail "unresolved blocker gate"; fi
rm "$CAND/.review/ISSUE-14-BLOCKER.json"
bash "$CLOSE" evaluate --plan "$GOOD_PLAN" --target "$CAND" --candidate-worktree "$CAND" --integration "$INTEGRATION" --evidence-set "$EVIDENCE" --output "$CLOSURE" > "$TMP/success.out"; ec=$?
if [ "$ec" -eq 0 ] && grep -q '"status":"closed"' "$TMP/success.out"; then pass "complete fresh same-candidate evidence set closes once"; else fail "successful integrated closure ($(cat "$TMP/success.out"))"; fi
printf '\n' >> "$EVIDENCE"
bash "$CLOSE" inspect --closure "$CLOSURE" --worktree "$CAND" > "$TMP/evidence-changed.out"; ec=$?
if [ "$ec" -eq 1 ] && grep -q closure_evidence_changed "$TMP/evidence-changed.out"; then pass "closure detects later evidence-set mutation"; else fail "closure evidence identity"; fi
make_evidence attempt-5 "$CAND_HEAD" pass no
printf '%s\n' later > "$CAND/later.txt"; git -C "$CAND" add later.txt && git -C "$CAND" -c user.name=smoke -c user.email=smoke@example.test commit -qm later
bash "$CLOSE" inspect --closure "$CLOSURE" --worktree "$CAND" > "$TMP/later.out"; ec=$?
if [ "$ec" -eq 1 ] && grep -q candidate_head_advanced "$TMP/later.out"; then pass "later candidate commit makes closure stale"; else fail "later candidate HEAD staleness"; fi

# Schema fixtures enforce each new artifact family.
node - "$ROOT/scripts/lib/json-schema-subset.cjs" "$ROOT/schemas" <<'NODE'
const fs=require("fs"),path=require("path"),{validate}=require(process.argv[2]),root=process.argv[3];
for(const name of ["execution_plan","integration_result","candidate_evidence_set","candidate_closure","completion_evidence","seat_outcome"]){const s=JSON.parse(fs.readFileSync(path.join(root,`${name}.schema.json`))),v=JSON.parse(fs.readFileSync(path.join(root,"fixtures",`${name}.valid.json`))),i=JSON.parse(fs.readFileSync(path.join(root,"fixtures",`${name}.invalid.json`)));if(validate(s,v).length||!validate(s,i).length)process.exit(1);if(name!=="execution_plan"){const t=JSON.parse(fs.readFileSync(path.join(root,"fixtures",`${name}.timestamp.invalid.json`)));if(!validate(s,t).length)process.exit(2);}}
NODE
if [ "$?" -eq 0 ]; then pass "new schemas reject dedicated not-a-time fixtures"; else fail "parallel schema fixtures"; fi

echo "---"
if [ "$FAILURES" -eq 0 ]; then echo "ALL CASES PASS"; exit 0; fi
echo "$FAILURES CASE(S) FAILED"; exit 1
