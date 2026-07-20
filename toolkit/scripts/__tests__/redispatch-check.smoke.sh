#!/usr/bin/env bash
# Smoke test for scripts/redispatch-check.sh.
# bash-3.2-compatible. Run: bash scripts/__tests__/redispatch-check.smoke.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK="$SCRIPT_DIR/../redispatch-check.sh"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURE="$ROOT/schemas/fixtures/round_state.valid.json"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAILURES=0

assert_case() {
  name="$1"; expected_exit="$2"; state="$3"; expected_decision="$4"; expected_trigger="$5"
  output="$TMP_DIR/output.json"
  ( bash "$CHECK" --round-state "$state" --manifest-revision 5 ) >"$output" 2>/dev/null
  actual_exit=$?
  if [ "$actual_exit" -ne "$expected_exit" ]; then
    echo "NOT OK - $name (expected exit $expected_exit, got $actual_exit: $(cat "$output"))"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if node -e '
    const value = require(process.argv[1]);
    const trigger = process.argv[3] === "null" ? null : process.argv[3];
    process.exit(value.decision === process.argv[2] && value.trigger === trigger ? 0 : 1);
  ' "$output" "$expected_decision" "$expected_trigger"; then
    echo "ok   - $name"
  else
    echo "NOT OK - $name (unexpected decision payload)"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_error_case() {
  name="$1"; state="$2"; expected_code="$3"; expected_detail="$4"
  output="$TMP_DIR/output.json"
  ( bash "$CHECK" --round-state "$state" --manifest-revision 5 ) >"$output" 2>/dev/null
  actual_exit=$?
  if [ "$actual_exit" -ne 2 ]; then
    echo "NOT OK - $name (expected exit 2, got $actual_exit: $(cat "$output"))"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if node -e '
    const value = require(process.argv[1]);
    const error = value.errors && value.errors[0];
    process.exit(value.decision === "error" && error
      && error.code === process.argv[2] && error.detail === process.argv[3] ? 0 : 1);
  ' "$output" "$expected_code" "$expected_detail"; then
    echo "ok   - $name"
  else
    echo "NOT OK - $name (unexpected error payload: $(cat "$output"))"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_error_code() {
  name="$1"; state="$2"; expected_code="$3"
  output="$TMP_DIR/output-error.json"
  ( bash "$CHECK" --round-state "$state" --manifest-revision 5 ) >"$output" 2>/dev/null
  actual_exit=$?
  if [ "$actual_exit" -eq 2 ] && node -e '
    const value=require(process.argv[1]);
    process.exit(value.decision === "error" && value.errors[0] && value.errors[0].code === process.argv[2] ? 0 : 1);
  ' "$output" "$expected_code"; then
    echo "ok   - $name"
  else
    echo "NOT OK - $name (expected exit 2/$expected_code, got $actual_exit: $(cat "$output"))"
    FAILURES=$((FAILURES + 1))
  fi
}

WORKTREE="$TMP_DIR/worktree"
mkdir -p "$WORKTREE/.review/evidence"
git init -q "$WORKTREE"
git -C "$WORKTREE" config user.email smoke@example.test
git -C "$WORKTREE" config user.name smoke
git -C "$WORKTREE" commit --allow-empty -qm baseline
EVIDENCE_HEAD="$(git -C "$WORKTREE" rev-parse HEAD)"
node - "$WORKTREE" "$EVIDENCE_HEAD" <<'NODE'
const fs=require("fs"); const path=require("path");
const [worktree,head]=process.argv.slice(2); const root=path.join(worktree,".review/evidence");
const clean_state={sentinel:{expected:"clean",actual:"clean"},migration_hash:{expected:"same",actual:"same"},role:{name:"verifier",superuser:false}};
const verifyPass={schema_version:"1",artifact_type:"verify_result",producer_role:"VERIFIER",issue:188,branch:"main",head_sha:head,cwd:worktree,verify_cmd:"smoke verify --filter shared-contract",db_target:{host:"localhost",database:"smoke",role:"verifier"},clean_state,verdict:{passed:1,failed:0,pending:0,exit_code:0},classifier:"PASS",failures:[],created_at:"2026-07-20T00:00:00Z"};
const verifyFail={...verifyPass,verdict:{passed:0,failed:1,pending:0,exit_code:1},classifier:"FAIL",failures:[{code:"failed_tests",expected:"0",actual:"1"}]};
for (const name of ["F-1","F-2","F-3"]) fs.writeFileSync(path.join(root,name+".json"),JSON.stringify(verifyFail));
fs.writeFileSync(path.join(root,"hard-fact.json"),JSON.stringify(verifyPass));
fs.writeFileSync(path.join(root,"old-pass.json"),JSON.stringify(verifyPass));
fs.writeFileSync(path.join(root,"wrong-issue.json"),JSON.stringify({...verifyFail,issue:999}));
fs.writeFileSync(path.join(root,"contradictory-fail.json"),JSON.stringify({...verifyFail,verdict:{passed:0,failed:0,pending:0,exit_code:0}}));
const review={schema_version:"1",artifact_type:"review",lifecycle:"final",producer_role:"REVIEWER",issue:{number:188},reviewed_head_sha:head,status:"pass",checklist:[{item:"security review",met:true}]};
fs.writeFileSync(path.join(root,"security.json"),JSON.stringify(review));
const blocker={schema_version:"1",artifact_type:"blocker",lifecycle:"active",producer_role:"CODEX",issue:{number:188,title:"dispatch contract failure"},head_sha:head,reason_code:"failing_precondition",blocking_fact:"cmux command was truncated before codex-safe started",attempted_commands:["cmux workspace create --command ..."],needed_decision:"repair the dispatch wrapper"};
fs.writeFileSync(path.join(root,"dispatch-contract-blocker.json"),JSON.stringify(blocker));
fs.writeFileSync(path.join(root,"superseded-blocker.json"),JSON.stringify({...blocker,lifecycle:"superseded"}));
const {head_sha,...legacyBlocker}=blocker;
fs.writeFileSync(path.join(root,"legacy-blocker-without-head.json"),JSON.stringify(legacyBlocker));
fs.writeFileSync(path.join(root,"malformed-blocker.json"),JSON.stringify({artifact_type:"blocker",issue:{number:188}}));
fs.writeFileSync(path.join(root,"wrong-issue-blocker.json"),JSON.stringify({...blocker,issue:{number:999,title:"wrong issue"}}));
fs.writeFileSync(path.join(root,"oracle.json"),"oracle evidence\n");
fs.writeFileSync(path.join(root,"passing-analog.json"),"passing analog evidence\n");
fs.writeFileSync(path.join(root,"plain.json"),"not a verifier artifact\n");
NODE
git -C "$WORKTREE" add .review/evidence
git -C "$WORKTREE" commit -qm failure-evidence
CLOSURE_HEAD="$(git -C "$WORKTREE" rev-parse HEAD)"
node - "$WORKTREE" "$CLOSURE_HEAD" <<'NODE'
const fs=require("fs"); const path=require("path");
const [worktree,head]=process.argv.slice(2); const root=path.join(worktree,".review/evidence");
const verifyPass={schema_version:"1",artifact_type:"verify_result",producer_role:"VERIFIER",issue:188,branch:"main",head_sha:head,cwd:worktree,verify_cmd:"smoke verify --filter shared-contract",db_target:{host:"localhost",database:"smoke",role:"verifier"},clean_state:{sentinel:{expected:"clean",actual:"clean"},migration_hash:{expected:"same",actual:"same"},role:{name:"verifier",superuser:false}},verdict:{passed:1,failed:0,pending:0,exit_code:0},classifier:"PASS",failures:[],created_at:"2026-07-20T00:01:00Z"};
for (const name of ["F-1-closed","F-2-closed"]) fs.writeFileSync(path.join(root,name+".json"),JSON.stringify(verifyPass));
fs.writeFileSync(path.join(root,"wrong-branch.json"),JSON.stringify({...verifyPass,branch:"other"}));
fs.writeFileSync(path.join(root,"unrelated-pass.json"),JSON.stringify({...verifyPass,verify_cmd:"smoke verify --filter unrelated"}));
fs.writeFileSync(path.join(root,"zero-pass.json"),JSON.stringify({...verifyPass,verdict:{passed:0,failed:0,pending:0,exit_code:0}}));
const reviewBase={schema_version:"1",artifact_type:"review",producer_role:"REVIEWER",issue:{number:188},reviewed_head_sha:head};
const closureItem="failure:F-1:AC-1";
fs.writeFileSync(path.join(root,"review-final-pass.json"),JSON.stringify({...reviewBase,lifecycle:"final",status:"pass",checklist:[{item:closureItem,met:true}]}));
fs.writeFileSync(path.join(root,"review-active-pass.json"),JSON.stringify({...reviewBase,lifecycle:"active",status:"pass",checklist:[{item:closureItem,met:true}]}));
fs.writeFileSync(path.join(root,"review-final-blocked.json"),JSON.stringify({...reviewBase,lifecycle:"final",status:"blocked",checklist:[{item:closureItem,met:true}]}));
fs.writeFileSync(path.join(root,"review-final-unmet.json"),JSON.stringify({...reviewBase,lifecycle:"final",status:"pass",checklist:[{item:closureItem,met:false}]}));
NODE
git -C "$WORKTREE" add .review/evidence
git -C "$WORKTREE" commit -qm closure-evidence
git -C "$WORKTREE" branch -M main
BRANCH="main"
HEAD_SHA="$(git -C "$WORKTREE" rev-parse HEAD)"
BASE_SHA="$HEAD_SHA"

cp "$FIXTURE" "$TMP_DIR/base.json"
node -e '
  const fs = require("fs");
  const [file, root, branch, base, head] = process.argv.slice(1);
  const value = JSON.parse(fs.readFileSync(file, "utf8"));
  value.revision = 5;
  value.base_branch = branch;
  value.base_sha = base;
  value.head_sha = head;
  value.worktree_path = root;
  value.decisions = [];
  value.commit_scope.commits = [];
  delete value.round_control;
  fs.writeFileSync(file, JSON.stringify(value));
' "$TMP_DIR/base.json" "$WORKTREE" "$BRANCH" "$BASE_SHA" "$HEAD_SHA"

assert_case "allows a normal initial dispatch without failure history" 0 "$TMP_DIR/base.json" "allow_normal" "null"

make_failure_state() {
  destination="$1"; origins="$2"
  cp "$TMP_DIR/base.json" "$destination"
  node -e '
    const fs = require("fs");
    const crypto = require("crypto");
    const path = require("path");
    const [file, origins, worktree, head] = process.argv.slice(1);
    const value = JSON.parse(fs.readFileSync(file, "utf8"));
    const actionFor={environment:"environment_fix",dispatch_contract:"contract_fix",implementation:"implementation_fix",test_oracle:"oracle_fix",verification_harness:"harness_fix",integration_drift:"integration_fix"};
    const evidence = (index) => {
      const relative = ".review/evidence/F-" + (index + 1) + ".json";
      const content = fs.readFileSync(path.join(worktree, relative));
      return {kind: "verify", path: relative, content_sha256: crypto.createHash("sha256").update(content).digest("hex"), head_sha: head};
    };
    value.round_control = {
      failures: origins.split(",").map((origin, index) => ({
        id: "F-" + (index + 1),
        dispatch_ordinal: index + 1,
        status: "open",
        primary_origin: origin,
        secondary_origins: [],
        failed_ac_ids: ["AC-" + (index + 1)],
        owner: "CONDUCTOR",
        next_action: {kind: actionFor[origin], summary: "apply the origin-compatible remedy"},
        evidence: [evidence(index)]
      }))
    };
    fs.writeFileSync(file, JSON.stringify(value));
  ' "$destination" "$origins" "$WORKTREE" "$EVIDENCE_HEAD"
}

make_failure_state "$TMP_DIR/different.json" "implementation,test_oracle"
assert_case "different origins allow the second normal redispatch" 0 "$TMP_DIR/different.json" "allow_normal" "null"

make_blocker_failure_state() {
  destination="$1"
  cp "$TMP_DIR/base.json" "$destination"
  node -e '
    const fs=require("fs"); const crypto=require("crypto"); const path=require("path");
    const [file,worktree,head,name,origin]=process.argv.slice(1); const value=JSON.parse(fs.readFileSync(file,"utf8"));
    const relative=".review/evidence/"+name+".json"; const content=fs.readFileSync(path.join(worktree,relative));
    value.round_control={failures:[{id:"F-1",dispatch_ordinal:1,status:"open",primary_origin:origin,secondary_origins:[],failed_ac_ids:["AC-1"],owner:"CONDUCTOR",next_action:{kind:origin==="dispatch_contract"?"contract_fix":"implementation_fix",summary:"route the scoped abort"},evidence:[{kind:"blocker",path:relative,content_sha256:crypto.createHash("sha256").update(content).digest("hex"),head_sha:head}]}]};
    fs.writeFileSync(file,JSON.stringify(value));
  ' "$destination" "$WORKTREE" "$EVIDENCE_HEAD" "$2" "$3"
}

make_blocker_failure_state "$TMP_DIR/dispatch-contract-blocker.json" "dispatch-contract-blocker" "dispatch_contract"
assert_case "dispatch-contract scoped abort admits canonical BLOCKER without REVIEW wrapper" 0 "$TMP_DIR/dispatch-contract-blocker.json" "allow_normal" "null"

make_blocker_failure_state "$TMP_DIR/superseded-blocker.json" "superseded-blocker" "dispatch_contract"
assert_error_code "superseded blocker is ignored before redispatch admission" "$TMP_DIR/superseded-blocker.json" "superseded_evidence_artifact"

cp "$TMP_DIR/dispatch-contract-blocker.json" "$TMP_DIR/blocker-resolvable-wrong-head.json"
node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.round_control.failures[0].evidence[0].head_sha=process.argv[2]; fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/blocker-resolvable-wrong-head.json" "$CLOSURE_HEAD"
assert_case "blocker evidence rejects a resolvable commit different from the producer-observed HEAD" 2 "$TMP_DIR/blocker-resolvable-wrong-head.json" "error" "null"

make_blocker_failure_state "$TMP_DIR/malformed-blocker.json" "malformed-blocker" "dispatch_contract"
assert_case "malformed blocker is rejected before redispatch admission" 2 "$TMP_DIR/malformed-blocker.json" "error" "null"

make_blocker_failure_state "$TMP_DIR/legacy-blocker.json" "legacy-blocker-without-head" "dispatch_contract"
assert_case "legacy blocker without producer-observed HEAD is not redispatch-admissible" 2 "$TMP_DIR/legacy-blocker.json" "error" "null"

make_blocker_failure_state "$TMP_DIR/wrong-issue-blocker.json" "wrong-issue-blocker" "dispatch_contract"
assert_case "blocker evidence is bound to the ROUND-STATE issue" 2 "$TMP_DIR/wrong-issue-blocker.json" "error" "null"

cp "$TMP_DIR/dispatch-contract-blocker.json" "$TMP_DIR/blocker-wrong-hash.json"
node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.round_control.failures[0].evidence[0].content_sha256="0000000000000000000000000000000000000000000000000000000000000000"; fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/blocker-wrong-hash.json"
assert_case "blocker evidence content hash is verified before admission" 2 "$TMP_DIR/blocker-wrong-hash.json" "error" "null"

cp "$TMP_DIR/dispatch-contract-blocker.json" "$TMP_DIR/blocker-wrong-head.json"
node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.round_control.failures[0].evidence[0].head_sha="0000000000000000000000000000000000000000"; fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/blocker-wrong-head.json"
assert_case "blocker evidence HEAD must resolve in the declared worktree" 2 "$TMP_DIR/blocker-wrong-head.json" "error" "null"

make_blocker_failure_state "$TMP_DIR/non-dispatch-blocker.json" "dispatch-contract-blocker" "implementation"
assert_case "BLOCKER-only evidence cannot admit a non-dispatch-contract round" 2 "$TMP_DIR/non-dispatch-blocker.json" "error" "null"

cp "$TMP_DIR/dispatch-contract-blocker.json" "$TMP_DIR/blocker-diagnosis-route.json"
node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.round_control.failures[0].next_action.kind="diagnosis"; fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/blocker-diagnosis-route.json"
assert_case "BLOCKER-only evidence requires the dispatch-contract fix route" 2 "$TMP_DIR/blocker-diagnosis-route.json" "error" "null"

cp "$TMP_DIR/different.json" "$TMP_DIR/unrouted.json"
node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.round_control.failures[0].next_action.kind="diagnosis"; fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/unrouted.json"
assert_case "normal write redispatch waits for origin-compatible action routing" 1 "$TMP_DIR/unrouted.json" "routing_required" "null"

make_failure_state "$TMP_DIR/same.json" "test_oracle,test_oracle"
assert_case "two consecutive equal primary origins trip the circuit" 1 "$TMP_DIR/same.json" "diagnosis_required" "same_origin"

cp "$TMP_DIR/same.json" "$TMP_DIR/closed-history.json"
node -e '
  const fs=require("fs"); const crypto=require("crypto"); const path=require("path");
  const [file,worktree,head]=process.argv.slice(1); const value=JSON.parse(fs.readFileSync(file,"utf8"));
  value.round_control.failures.forEach((failure,index)=>{
    const relative=".review/evidence/F-"+(index+1)+"-closed.json";
    const content=fs.readFileSync(path.join(worktree,relative));
    failure.status="closed";
    failure.closed_by={kind:"verify",path:relative,content_sha256:crypto.createHash("sha256").update(content).digest("hex"),head_sha:head,closes_ac_ids:failure.failed_ac_ids};
  });
  fs.writeFileSync(file,JSON.stringify(value));
' "$TMP_DIR/closed-history.json" "$WORKTREE" "$CLOSURE_HEAD"
assert_case "closed historical failures do not retrip the active circuit" 0 "$TMP_DIR/closed-history.json" "allow_normal" "null"

cp "$TMP_DIR/closed-history.json" "$TMP_DIR/unverified-closure.json"
node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); delete v.round_control.failures[0].closed_by; fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/unverified-closure.json"
assert_case "closed failures require closure evidence" 2 "$TMP_DIR/unverified-closure.json" "error" "null"

cp "$TMP_DIR/closed-history.json" "$TMP_DIR/plain-closure.json"
node -e '
  const fs=require("fs"); const crypto=require("crypto"); const path=require("path");
  const [file,worktree,head]=process.argv.slice(1); const value=JSON.parse(fs.readFileSync(file,"utf8"));
  const relative=".review/evidence/plain.json"; const content=fs.readFileSync(path.join(worktree,relative));
  value.round_control.failures[0].closed_by={kind:"verify",path:relative,content_sha256:crypto.createHash("sha256").update(content).digest("hex"),head_sha:head,closes_ac_ids:value.round_control.failures[0].failed_ac_ids};
  fs.writeFileSync(file,JSON.stringify(value));
' "$TMP_DIR/plain-closure.json" "$WORKTREE" "$EVIDENCE_HEAD"
assert_case "closure labels cannot turn plain text into verifier evidence" 2 "$TMP_DIR/plain-closure.json" "error" "null"

for closure_case in zero-pass; do
  cp "$TMP_DIR/closed-history.json" "$TMP_DIR/$closure_case-closure.json"
  node -e '
    const fs=require("fs"); const crypto=require("crypto"); const path=require("path");
    const [file,worktree,head,name]=process.argv.slice(1); const value=JSON.parse(fs.readFileSync(file,"utf8"));
    const relative=".review/evidence/"+name+".json"; const content=fs.readFileSync(path.join(worktree,relative));
    value.round_control.failures[0].closed_by={kind:"verify",path:relative,content_sha256:crypto.createHash("sha256").update(content).digest("hex"),head_sha:head,closes_ac_ids:value.round_control.failures[0].failed_ac_ids};
    fs.writeFileSync(file,JSON.stringify(value));
  ' "$TMP_DIR/$closure_case-closure.json" "$WORKTREE" "$CLOSURE_HEAD" "$closure_case"
done
assert_case "zero-test PASS cannot close a failed round" 2 "$TMP_DIR/zero-pass-closure.json" "error" "null"

make_review_closure_state() {
  destination="$1"; artifact="$2"
  cp "$TMP_DIR/closed-history.json" "$destination"
  node -e '
    const fs=require("fs"); const crypto=require("crypto"); const path=require("path");
    const [file,worktree,head,artifact]=process.argv.slice(1); const value=JSON.parse(fs.readFileSync(file,"utf8"));
    const relative=".review/evidence/"+artifact+".json"; const content=fs.readFileSync(path.join(worktree,relative));
    const failure=value.round_control.failures[0];
    failure.closed_by={kind:"review",path:relative,content_sha256:crypto.createHash("sha256").update(content).digest("hex"),head_sha:head,closes_ac_ids:failure.failed_ac_ids,checklist_item:"failure:"+failure.id+":"+failure.failed_ac_ids.join(",")};
    fs.writeFileSync(file,JSON.stringify(value));
  ' "$destination" "$WORKTREE" "$CLOSURE_HEAD" "$artifact"
}

make_review_closure_state "$TMP_DIR/review-final-pass-closure.json" "review-final-pass"
assert_case "final passing review with the exact checklist closure admits history" 0 "$TMP_DIR/review-final-pass-closure.json" "allow_normal" "null"

make_review_closure_state "$TMP_DIR/review-active-pass-closure.json" "review-active-pass"
assert_error_case "active passing review reports its lifecycle predicate" "$TMP_DIR/review-active-pass-closure.json" "failure_closure_not_verified" "review_lifecycle_not_final"

make_review_closure_state "$TMP_DIR/review-final-blocked-closure.json" "review-final-blocked"
assert_error_case "final blocked review reports its status predicate" "$TMP_DIR/review-final-blocked-closure.json" "failure_closure_not_verified" "review_status_not_pass"

make_review_closure_state "$TMP_DIR/review-final-unmet-closure.json" "review-final-unmet"
assert_error_case "final passing review reports an unmet checklist predicate" "$TMP_DIR/review-final-unmet-closure.json" "failure_closure_not_verified" "review_checklist_unmet"

for closure_case in old-pass wrong-branch unrelated-pass; do
  cp "$TMP_DIR/closed-history.json" "$TMP_DIR/$closure_case-lineage.json"
  node -e '
    const fs=require("fs"); const crypto=require("crypto"); const path=require("path");
    const [file,worktree,name,head]=process.argv.slice(1); const value=JSON.parse(fs.readFileSync(file,"utf8"));
    const relative=".review/evidence/"+name+".json"; const content=fs.readFileSync(path.join(worktree,relative));
    value.round_control.failures[0].closed_by={kind:"verify",path:relative,content_sha256:crypto.createHash("sha256").update(content).digest("hex"),head_sha:head,closes_ac_ids:value.round_control.failures[0].failed_ac_ids};
    fs.writeFileSync(file,JSON.stringify(value));
  ' "$TMP_DIR/$closure_case-lineage.json" "$WORKTREE" "$closure_case" "$([ "$closure_case" = "old-pass" ] && printf '%s' "$EVIDENCE_HEAD" || printf '%s' "$CLOSURE_HEAD")"
done
assert_case "closure evidence must be newer than the failed-round evidence" 2 "$TMP_DIR/old-pass-lineage.json" "error" "null"
assert_case "closure verifier must match the live worktree branch" 2 "$TMP_DIR/wrong-branch-lineage.json" "error" "null"
assert_case "closure verifier must run the canonical verification scope" 2 "$TMP_DIR/unrelated-pass-lineage.json" "error" "null"

cp "$TMP_DIR/same.json" "$TMP_DIR/interleaved-cycle.json"
node -e '
  const fs=require("fs"); const source=require(process.argv[2]); const file=process.argv[1]; const value=JSON.parse(fs.readFileSync(file,"utf8"));
  value.round_control.failures[1].status="closed"; value.round_control.failures[1].closed_by=source.round_control.failures[1].closed_by;
  fs.writeFileSync(file,JSON.stringify(value));
' "$TMP_DIR/interleaved-cycle.json" "$TMP_DIR/closed-history.json"
assert_case "closed history must precede the active open cycle" 2 "$TMP_DIR/interleaved-cycle.json" "error" "null"

make_failure_state "$TMP_DIR/third.json" "environment,implementation,integration_drift"
assert_case "two completed redispatches block a third redispatch" 1 "$TMP_DIR/third.json" "diagnosis_required" "third_redispatch"

cp "$TMP_DIR/different.json" "$TMP_DIR/security.json"
node -e '
  const fs=require("fs"); const crypto=require("crypto"); const path=require("path"); const f=process.argv[1]; const worktree=process.argv[2]; const v=JSON.parse(fs.readFileSync(f,"utf8"));
  const relative=".review/evidence/security.json"; const content=fs.readFileSync(path.join(worktree,relative));
  v.round_control.security_stop={active:true,finding_id:"SEC-1",evidence:{kind:"review",path:relative,content_sha256:crypto.createHash("sha256").update(content).digest("hex"),head_sha:process.argv[3]}};
  fs.writeFileSync(f,JSON.stringify(v));
' "$TMP_DIR/security.json" "$WORKTREE" "$EVIDENCE_HEAD"
assert_case "security finding stops before numeric thresholds" 1 "$TMP_DIR/security.json" "security_stop" "security"

cp "$TMP_DIR/same.json" "$TMP_DIR/diagnosis-incomplete.json"
node -e '
  const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8"));
  v.round_control.diagnosis={trigger:"same_origin",failure_ids:["F-1","F-2"],records:[]};
  fs.writeFileSync(f,JSON.stringify(v));
' "$TMP_DIR/diagnosis-incomplete.json"
assert_case "incomplete diagnosis keeps implementation redispatch blocked" 1 "$TMP_DIR/diagnosis-incomplete.json" "diagnosis_required" "same_origin"

cp "$TMP_DIR/same.json" "$TMP_DIR/integrated-ready.json"
node -e '
  const fs=require("fs"); const crypto=require("crypto"); const path=require("path"); const f=process.argv[1]; const worktree=process.argv[2]; const v=JSON.parse(fs.readFileSync(f,"utf8")); const head=process.argv[3];
  const evidence=(kind,name)=>{const relative=".review/evidence/"+name+".json"; const content=fs.readFileSync(path.join(worktree,relative)); return {kind,path:relative,content_sha256:crypto.createHash("sha256").update(content).digest("hex"),head_sha:head};};
  v.round_control.diagnosis={
    trigger:"same_origin",
    failure_ids:["F-1","F-2"],
    records:[
      {kind:"oracle_contract_recheck",summary:"oracle and contract compared first",evidence:evidence("live_probe","oracle")},
      {kind:"hard_fact",summary:"passing fixture uses the canonical helper",evidence:evidence("verify","hard-fact")},
      {kind:"passing_analog",summary:"copy the known-green wiring to parity",instruction:"guess_forbidden_copy_passing_analog_to_parity",evidence:evidence("diff","passing-analog")}
    ],
    integrated_fix_batch:{dispatch_ordinal:3,failure_ids:["F-1","F-2"],status:"ready"}
  };
  fs.writeFileSync(f,JSON.stringify(v));
' "$TMP_DIR/integrated-ready.json" "$WORKTREE" "$EVIDENCE_HEAD"
assert_case "ordered diagnosis authorizes one integrated fix batch" 0 "$TMP_DIR/integrated-ready.json" "allow_integrated_fix" "same_origin"

cp "$TMP_DIR/integrated-ready.json" "$TMP_DIR/integrated-revision-bump.json"
node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.revision=6; fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/integrated-revision-bump.json"
bash "$CHECK" --round-state "$TMP_DIR/integrated-ready.json" --manifest-revision 5 > "$TMP_DIR/key-before.json" 2>/dev/null
bash "$CHECK" --round-state "$TMP_DIR/integrated-revision-bump.json" --manifest-revision 6 > "$TMP_DIR/key-after.json" 2>/dev/null
if node -e 'const before=require(process.argv[1]); const after=require(process.argv[2]); process.exit(before.admission_key && before.admission_key === after.admission_key ? 0 : 1)' "$TMP_DIR/key-before.json" "$TMP_DIR/key-after.json"; then
  echo "ok   - manifest revision changes cannot mint a second integrated-batch admission"
else
  echo "NOT OK - integrated-batch admission identity changed across manifest revision"
  FAILURES=$((FAILURES + 1))
fi

cp "$TMP_DIR/integrated-ready.json" "$TMP_DIR/integrated-renamed.json"
node -e '
  const fs=require("fs"); const file=process.argv[1]; const value=JSON.parse(fs.readFileSync(file,"utf8"));
  value.round_control.failures.forEach((failure,index)=>{failure.id="RENAMED-"+(index+1);});
  value.round_control.diagnosis.failure_ids=["RENAMED-1","RENAMED-2"];
  value.round_control.diagnosis.integrated_fix_batch.failure_ids=["RENAMED-1","RENAMED-2"];
  fs.writeFileSync(file,JSON.stringify(value));
' "$TMP_DIR/integrated-renamed.json"
bash "$CHECK" --round-state "$TMP_DIR/integrated-renamed.json" --manifest-revision 5 > "$TMP_DIR/key-renamed.json" 2>/dev/null
if node -e 'const before=require(process.argv[1]); const renamed=require(process.argv[2]); process.exit(before.admission_key && before.admission_key === renamed.admission_key ? 0 : 1)' "$TMP_DIR/key-before.json" "$TMP_DIR/key-renamed.json"; then
  echo "ok   - renaming mutable failure ids cannot mint another batch admission"
else
  echo "NOT OK - batch admission identity changed after failure-id rename"
  FAILURES=$((FAILURES + 1))
fi

bash "$CHECK" --round-state "$TMP_DIR/different.json" --manifest-revision 5 > "$TMP_DIR/key-normal-same-ordinal.json" 2>/dev/null
if node -e 'const integrated=require(process.argv[1]); const normal=require(process.argv[2]); process.exit(integrated.admission_key && integrated.admission_key === normal.admission_key ? 0 : 1)' "$TMP_DIR/key-before.json" "$TMP_DIR/key-normal-same-ordinal.json"; then
  echo "ok   - dispatch ordinal has one admission identity across modes"
else
  echo "NOT OK - same dispatch ordinal changed admission identity across modes"
  FAILURES=$((FAILURES + 1))
fi

cp "$TMP_DIR/integrated-ready.json" "$TMP_DIR/integrated-used.json"
node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.round_control.diagnosis.integrated_fix_batch.status="used"; fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/integrated-used.json"
assert_case "a consumed integrated fix batch cannot redispatch again" 1 "$TMP_DIR/integrated-used.json" "diagnosis_exhausted" "same_origin"

cp "$TMP_DIR/same.json" "$TMP_DIR/secondary-conflict.json"
node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.round_control.failures[0].secondary_origins=[v.round_control.failures[0].primary_origin]; fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/secondary-conflict.json"
assert_case "primary origin cannot repeat as a secondary origin" 2 "$TMP_DIR/secondary-conflict.json" "error" "null"

cp "$TMP_DIR/same.json" "$TMP_DIR/unknown-origin.json"
node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.round_control.failures[0].primary_origin="model"; fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/unknown-origin.json"
assert_case "unknown primary origin fails schema validation" 2 "$TMP_DIR/unknown-origin.json" "error" "null"

cp "$TMP_DIR/same.json" "$TMP_DIR/missing-evidence.json"
node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.round_control.failures[0].evidence=[]; fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/missing-evidence.json"
assert_case "every failed round preserves evidence" 2 "$TMP_DIR/missing-evidence.json" "error" "null"

cp "$TMP_DIR/integrated-ready.json" "$TMP_DIR/wrong-order.json"
node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.round_control.diagnosis.records.reverse(); fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/wrong-order.json"
assert_case "diagnosis must recheck oracle and contract first" 2 "$TMP_DIR/wrong-order.json" "error" "null"

cp "$TMP_DIR/integrated-ready.json" "$TMP_DIR/manifest-jump.json"
node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.round_control.diagnosis.manifest_update={from_revision:3,to_revision:5,decision_id:"D-2"}; fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/manifest-jump.json"
assert_case "diagnosis permits at most one manifest revision increment" 2 "$TMP_DIR/manifest-jump.json" "error" "null"

cp "$TMP_DIR/integrated-ready.json" "$TMP_DIR/unbound-manifest.json"
node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.round_control.diagnosis.manifest_update={from_revision:1,to_revision:2,decision_id:"D-old"}; fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/unbound-manifest.json"
assert_case "manifest update must end at the current ROUND-STATE revision" 2 "$TMP_DIR/unbound-manifest.json" "error" "null"

cp "$TMP_DIR/same.json" "$TMP_DIR/no-verifier-evidence.json"
node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.round_control.failures[0].evidence[0].kind="dispatch_log"; fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/no-verifier-evidence.json"
assert_case "failed ACs require verifier or review evidence" 2 "$TMP_DIR/no-verifier-evidence.json" "error" "null"

cp "$TMP_DIR/same.json" "$TMP_DIR/contradictory-failure.json"
node -e '
  const fs=require("fs"); const crypto=require("crypto"); const path=require("path"); const [file,worktree]=process.argv.slice(1); const value=JSON.parse(fs.readFileSync(file,"utf8"));
  const relative=".review/evidence/contradictory-fail.json"; const content=fs.readFileSync(path.join(worktree,relative)); value.round_control.failures[0].evidence[0].path=relative; value.round_control.failures[0].evidence[0].content_sha256=crypto.createHash("sha256").update(content).digest("hex");
  fs.writeFileSync(file,JSON.stringify(value));
' "$TMP_DIR/contradictory-failure.json" "$WORKTREE"
assert_case "zero-failure contradictory FAIL cannot authorize redispatch" 2 "$TMP_DIR/contradictory-failure.json" "error" "null"

cp "$TMP_DIR/different.json" "$TMP_DIR/origin-action-mismatch.json"
node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.round_control.failures[0].primary_origin="environment"; v.round_control.failures[0].next_action.kind="implementation_fix"; fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/origin-action-mismatch.json"
assert_case "primary origin constrains the routed next action" 2 "$TMP_DIR/origin-action-mismatch.json" "error" "null"

cp "$TMP_DIR/same.json" "$TMP_DIR/wrong-evidence-issue.json"
node -e '
  const fs=require("fs"); const crypto=require("crypto"); const path=require("path"); const [file,worktree]=process.argv.slice(1); const value=JSON.parse(fs.readFileSync(file,"utf8"));
  const relative=".review/evidence/wrong-issue.json"; const content=fs.readFileSync(path.join(worktree,relative)); value.round_control.failures[0].evidence[0].path=relative; value.round_control.failures[0].evidence[0].content_sha256=crypto.createHash("sha256").update(content).digest("hex");
  fs.writeFileSync(file,JSON.stringify(value));
' "$TMP_DIR/wrong-evidence-issue.json" "$WORKTREE"
assert_case "verifier evidence is bound to the ROUND-STATE issue" 2 "$TMP_DIR/wrong-evidence-issue.json" "error" "null"

cp "$TMP_DIR/same.json" "$TMP_DIR/stale-head.json"
node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.head_sha="0000000000000000000000000000000000000000"; fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/stale-head.json"
assert_case "ROUND-STATE head must match the live worktree" 2 "$TMP_DIR/stale-head.json" "error" "null"

printf '%s\n' 'tampered evidence' > "$WORKTREE/.review/evidence/F-1.json"
assert_case "evidence content hash is verified before admission" 2 "$TMP_DIR/same.json" "error" "null"
git -C "$WORKTREE" show HEAD:.review/evidence/F-1.json > "$WORKTREE/.review/evidence/F-1.json"

( bash "$CHECK" --round-state "$TMP_DIR/base.json" --manifest-revision 4 ) > "$TMP_DIR/stale-revision.json" 2>/dev/null
if [ "$?" -eq 2 ] && node -e 'const value=require(process.argv[1]); process.exit(value.decision === "error" && value.errors[0].code === "stale_manifest_revision" ? 0 : 1)' "$TMP_DIR/stale-revision.json"; then
  echo "ok   - stale manifest revision is an input error"
else
  echo "NOT OK - stale manifest revision exit contract"
  FAILURES=$((FAILURES + 1))
fi

cp "$TMP_DIR/same.json" "$TMP_DIR/model-remedy.json"
node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.round_control.failures[0].next_action.kind="model_escalation"; fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/model-remedy.json"
assert_case "model escalation is not a valid failure remedy" 2 "$TMP_DIR/model-remedy.json" "error" "null"

echo "---"
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASS"
  exit 0
fi
echo "$FAILURES CASE(S) FAILED"
exit 1
