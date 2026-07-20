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
    echo "NOT OK - $name (expected exit $expected_exit, got $actual_exit)"
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

WORKTREE="$TMP_DIR/worktree"
mkdir -p "$WORKTREE/.review/evidence"
git init -q "$WORKTREE"
git -C "$WORKTREE" config user.email smoke@example.test
git -C "$WORKTREE" config user.name smoke
for evidence_name in F-1 F-2 F-3 F-1-closed F-2-closed security oracle hard-fact passing-analog; do
  printf '%s\n' "$evidence_name evidence" > "$WORKTREE/.review/evidence/$evidence_name.json"
done
git -C "$WORKTREE" add .review/evidence
git -C "$WORKTREE" commit -qm evidence
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
        next_action: {kind: "diagnosis", summary: "classify and route the failure"},
        evidence: [evidence(index)]
      }))
    };
    fs.writeFileSync(file, JSON.stringify(value));
  ' "$destination" "$origins" "$WORKTREE" "$HEAD_SHA"
}

make_failure_state "$TMP_DIR/different.json" "implementation,test_oracle"
assert_case "different origins allow the second normal redispatch" 0 "$TMP_DIR/different.json" "allow_normal" "null"

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
    failure.closed_by={kind:"verify",path:relative,content_sha256:crypto.createHash("sha256").update(content).digest("hex"),head_sha:head};
  });
  fs.writeFileSync(file,JSON.stringify(value));
' "$TMP_DIR/closed-history.json" "$WORKTREE" "$HEAD_SHA"
assert_case "closed historical failures do not retrip the active circuit" 0 "$TMP_DIR/closed-history.json" "allow_normal" "null"

cp "$TMP_DIR/closed-history.json" "$TMP_DIR/unverified-closure.json"
node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); delete v.round_control.failures[0].closed_by; fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/unverified-closure.json"
assert_case "closed failures require closure evidence" 2 "$TMP_DIR/unverified-closure.json" "error" "null"

make_failure_state "$TMP_DIR/third.json" "environment,implementation,integration_drift"
assert_case "two completed redispatches block a third redispatch" 1 "$TMP_DIR/third.json" "diagnosis_required" "third_redispatch"

cp "$TMP_DIR/different.json" "$TMP_DIR/security.json"
node -e '
  const fs=require("fs"); const crypto=require("crypto"); const path=require("path"); const f=process.argv[1]; const worktree=process.argv[2]; const v=JSON.parse(fs.readFileSync(f,"utf8"));
  const relative=".review/evidence/security.json"; const content=fs.readFileSync(path.join(worktree,relative));
  v.round_control.security_stop={active:true,finding_id:"SEC-1",evidence:{kind:"review",path:relative,content_sha256:crypto.createHash("sha256").update(content).digest("hex"),head_sha:process.argv[3]}};
  fs.writeFileSync(f,JSON.stringify(v));
' "$TMP_DIR/security.json" "$WORKTREE" "$HEAD_SHA"
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
' "$TMP_DIR/integrated-ready.json" "$WORKTREE" "$HEAD_SHA"
assert_case "ordered diagnosis authorizes one integrated fix batch" 0 "$TMP_DIR/integrated-ready.json" "allow_integrated_fix" "same_origin"

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
