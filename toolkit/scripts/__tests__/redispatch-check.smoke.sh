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

BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD)"
BASE_SHA="$(git -C "$ROOT" merge-base HEAD "$BRANCH")"
HASH="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

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
' "$TMP_DIR/base.json" "$ROOT" "$BRANCH" "$BASE_SHA" "$HEAD_SHA"

assert_case "allows a normal initial dispatch without failure history" 0 "$TMP_DIR/base.json" "allow_normal" "null"

make_failure_state() {
  destination="$1"; origins="$2"
  cp "$TMP_DIR/base.json" "$destination"
  node -e '
    const fs = require("fs");
    const [file, origins, hash, head] = process.argv.slice(1);
    const value = JSON.parse(fs.readFileSync(file, "utf8"));
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
        evidence: [{kind: "verify", path: ".review/history/F-" + (index + 1) + ".json", content_sha256: hash, head_sha: head}]
      }))
    };
    fs.writeFileSync(file, JSON.stringify(value));
  ' "$destination" "$origins" "$HASH" "$HEAD_SHA"
}

make_failure_state "$TMP_DIR/different.json" "implementation,test_oracle"
assert_case "different origins allow the second normal redispatch" 0 "$TMP_DIR/different.json" "allow_normal" "null"

make_failure_state "$TMP_DIR/same.json" "test_oracle,test_oracle"
assert_case "two consecutive equal primary origins trip the circuit" 1 "$TMP_DIR/same.json" "diagnosis_required" "same_origin"

make_failure_state "$TMP_DIR/third.json" "environment,implementation,integration_drift"
assert_case "two completed redispatches block a third redispatch" 1 "$TMP_DIR/third.json" "diagnosis_required" "third_redispatch"

cp "$TMP_DIR/different.json" "$TMP_DIR/security.json"
node -e '
  const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8"));
  v.round_control.security_stop={active:true,finding_id:"SEC-1",evidence:{kind:"review",path:".review/SEC-1.json",content_sha256:process.argv[2],head_sha:process.argv[3]}};
  fs.writeFileSync(f,JSON.stringify(v));
' "$TMP_DIR/security.json" "$HASH" "$HEAD_SHA"
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
  const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); const hash=process.argv[2]; const head=process.argv[3];
  const evidence=(kind,path)=>({kind,path,content_sha256:hash,head_sha:head});
  v.round_control.diagnosis={
    trigger:"same_origin",
    failure_ids:["F-1","F-2"],
    records:[
      {kind:"oracle_contract_recheck",summary:"oracle and contract compared first",evidence:evidence("live_probe",".review/oracle-contract.json")},
      {kind:"hard_fact",summary:"passing fixture uses the canonical helper",evidence:evidence("verify",".review/hard-fact.json")},
      {kind:"passing_analog",summary:"copy the known-green wiring to parity",instruction:"guess_forbidden_copy_passing_analog_to_parity",evidence:evidence("diff",".review/passing-analog.diff")}
    ],
    integrated_fix_batch:{dispatch_ordinal:3,failure_ids:["F-1","F-2"],status:"ready"}
  };
  fs.writeFileSync(f,JSON.stringify(v));
' "$TMP_DIR/integrated-ready.json" "$HASH" "$HEAD_SHA"
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
