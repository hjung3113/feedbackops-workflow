#!/usr/bin/env bash
# Smoke test for scripts/completion-check.sh.
# bash-3.2-compatible. Run: bash scripts/__tests__/completion-check.smoke.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK="$SCRIPT_DIR/../completion-check.sh"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURE="$ROOT/schemas/fixtures/round_state.valid.json"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAILURES=0

assert_case() {
  name="$1"; expected="$2"; state="$3"; expected_code="$4"
  output="$TMP_DIR/output.json"
  ( bash "$CHECK" --round-state "$state" --manifest-revision 3 ) >"$output" 2>/dev/null
  actual=$?
  if [ "$actual" -ne "$expected" ]; then
    echo "NOT OK - $name (expected exit $expected, got $actual)"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if node -e 'const v=require(process.argv[1]); process.exit(v.mismatches.some((m) => m.code === process.argv[2]) ? 0 : 1)' "$output" "$expected_code"; then
    echo "ok   - $name"
  else
    echo "NOT OK - $name (missing mismatch $expected_code)"
    FAILURES=$((FAILURES + 1))
  fi
}

WORKTREE="$TMP_DIR/worktree"
git init -q "$WORKTREE"
git -C "$WORKTREE" config user.email smoke@example.test
git -C "$WORKTREE" config user.name smoke
mkdir -p "$WORKTREE/allowed"
printf 'base\n' > "$WORKTREE/allowed/file.txt"
git -C "$WORKTREE" add allowed/file.txt
git -C "$WORKTREE" commit -qm base
git -C "$WORKTREE" branch -M main
BASE_SHA="$(git -C "$WORKTREE" rev-parse HEAD)"
git -C "$WORKTREE" switch -q -c feat/completion-smoke
printf 'changed\n' >> "$WORKTREE/allowed/file.txt"
git -C "$WORKTREE" commit -am allowed-change -q

cp "$FIXTURE" "$TMP_DIR/state.json"
node -e '
  const fs = require("fs");
  const [file, worktree, base] = process.argv.slice(1);
  const v = JSON.parse(fs.readFileSync(file, "utf8"));
  v.revision = 3; v.base_branch = "main"; v.base_sha = base;
  v.worktree_path = worktree; v.contract.touch_allowlist = ["allowed/**"];
  delete v.contract.chunk_boundary; delete v.contract.test_count;
  v.acceptance.criteria = [{id: "AC-1", statement: "the test discovery exposes AC-1"}]; v.acceptance.expected_test_count = 1;
  v.contract.test_discovery_command = "printf '\''AC-1\\n'\''";
  v.decisions = []; v.commit_scope.commits = [];
  fs.writeFileSync(file, JSON.stringify(v));
' "$TMP_DIR/state.json" "$WORKTREE" "$BASE_SHA"
( bash "$CHECK" --round-state "$TMP_DIR/state.json" --manifest-revision 3 ) > "$TMP_DIR/pass.json" 2>/dev/null
if [ "$?" -eq 0 ] && node -e 'const v=require(process.argv[1]); process.exit(v.status === "pass" && v.mismatches.length === 0 ? 0 : 1)' "$TMP_DIR/pass.json"; then
  echo "ok   - completion passes for allowed diff and discovered AC"
else
  echo "NOT OK - completion happy path"
  FAILURES=$((FAILURES + 1))
fi

cp "$TMP_DIR/state.json" "$TMP_DIR/chunk-state.json"
node -e '
  const fs = require("fs");
  const file = process.argv[1];
  const v = JSON.parse(fs.readFileSync(file, "utf8"));
  v.contract.chunk_boundary = {
    chunk_id: "C1",
    typecheck_command: "true",
    compile_consumers: ["allowed/file.txt"],
    convention_watch: [
      {
        surface: "allowed-file convention",
        trigger: ["allowed/**"],
        expected_invariant: "the allowed file remains convention-complete",
        owner: "REVIEWER",
        review_by_chunk: "C1",
        closed_by: { artifact_type: "review", checklist_item: "convention-watch:allowed-file" }
      },
      {
        surface: "dormant convention",
        trigger: ["dormant/**"],
        expected_invariant: "dormant files remain unchanged",
        owner: "REVIEWER",
        review_by_chunk: "C1",
        closed_by: { artifact_type: "review", checklist_item: "convention-watch:dormant" }
      },
      {
        surface: "later-chunk convention",
        trigger: ["allowed/**"],
        expected_invariant: "a later chunk owns this review",
        owner: "REVIEWER",
        review_by_chunk: "C2",
        closed_by: { artifact_type: "review", checklist_item: "convention-watch:later-chunk" }
      }
    ]
  };
  fs.writeFileSync(file, JSON.stringify(v));
' "$TMP_DIR/chunk-state.json"
( bash "$CHECK" --round-state "$TMP_DIR/chunk-state.json" --manifest-revision 3 ) > "$TMP_DIR/chunk-pass.json" 2>/dev/null
if [ "$?" -eq 0 ] && node -e '
  const v = require(process.argv[1]);
  const ok = v.status === "pass"
    && v.typecheck.command === "true"
    && v.typecheck.exit_code === 0
    && v.compile_consumers.length === 1
    && v.review_obligations.length === 1
    && v.review_obligations[0].surface === "allowed-file convention";
  process.exit(ok ? 0 : 1);
' "$TMP_DIR/chunk-pass.json"; then
  echo "ok   - chunk boundary runs typecheck and emits fired review obligations only"
else
  echo "NOT OK - chunk boundary happy path"
  FAILURES=$((FAILURES + 1))
fi

cp "$TMP_DIR/chunk-state.json" "$TMP_DIR/consumer-outside.json"
node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.contract.chunk_boundary.compile_consumers=["outside/file.txt"]; fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/consumer-outside.json"
assert_case "rejects compile consumer outside chunk allowlist" 1 "$TMP_DIR/consumer-outside.json" "compile_consumer_outside_chunk"

cp "$TMP_DIR/chunk-state.json" "$TMP_DIR/typecheck-fail.json"
node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.contract.chunk_boundary.typecheck_command="false"; fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/typecheck-fail.json"
assert_case "rejects failed full typecheck" 1 "$TMP_DIR/typecheck-fail.json" "typecheck_failed"

cp "$TMP_DIR/chunk-state.json" "$TMP_DIR/malformed-watch.json"
node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); delete v.contract.chunk_boundary.convention_watch[0].closed_by; fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/malformed-watch.json"
( bash "$CHECK" --round-state "$TMP_DIR/malformed-watch.json" --manifest-revision 3 ) > "$TMP_DIR/malformed-watch-output.json" 2>/dev/null
if [ "$?" -eq 2 ] && node -e 'const v=require(process.argv[1]); process.exit(v.mismatches[0].code === "invalid_round_state" ? 0 : 1)' "$TMP_DIR/malformed-watch-output.json"; then
  echo "ok   - malformed convention watch fails schema validation"
else
  echo "NOT OK - malformed convention watch validation"
  FAILURES=$((FAILURES + 1))
fi

cp "$TMP_DIR/chunk-state.json" "$TMP_DIR/duplicate-watch.json"
node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.contract.chunk_boundary.convention_watch[1].surface=v.contract.chunk_boundary.convention_watch[0].surface; fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/duplicate-watch.json"
( bash "$CHECK" --round-state "$TMP_DIR/duplicate-watch.json" --manifest-revision 3 ) > "$TMP_DIR/duplicate-watch-output.json" 2>/dev/null
if [ "$?" -eq 2 ] && node -e 'const v=require(process.argv[1]); process.exit(v.mismatches[0].code === "invalid_chunk_boundary" ? 0 : 1)' "$TMP_DIR/duplicate-watch-output.json"; then
  echo "ok   - duplicate convention watch surfaces fail closed"
else
  echo "NOT OK - duplicate convention watch surface validation"
  FAILURES=$((FAILURES + 1))
fi

cp "$TMP_DIR/chunk-state.json" "$TMP_DIR/escaping-trigger.json"
node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.contract.chunk_boundary.convention_watch[0].trigger=["../outside/**"]; fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/escaping-trigger.json"
( bash "$CHECK" --round-state "$TMP_DIR/escaping-trigger.json" --manifest-revision 3 ) > "$TMP_DIR/escaping-trigger-output.json" 2>/dev/null
if [ "$?" -eq 2 ] && node -e 'const v=require(process.argv[1]); process.exit(v.mismatches[0].code === "invalid_chunk_boundary" ? 0 : 1)' "$TMP_DIR/escaping-trigger-output.json"; then
  echo "ok   - convention watch trigger cannot escape the repository"
else
  echo "NOT OK - escaping convention watch trigger validation"
  FAILURES=$((FAILURES + 1))
fi

cp "$TMP_DIR/chunk-state.json" "$TMP_DIR/escaping-allowlist.json"
node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.contract.touch_allowlist=["../outside/**"]; fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/escaping-allowlist.json"
( bash "$CHECK" --round-state "$TMP_DIR/escaping-allowlist.json" --manifest-revision 3 ) > "$TMP_DIR/escaping-allowlist-output.json" 2>/dev/null
if [ "$?" -eq 2 ] && node -e 'const v=require(process.argv[1]); process.exit(v.mismatches[0].code === "invalid_touch_allowlist" ? 0 : 1)' "$TMP_DIR/escaping-allowlist-output.json"; then
  echo "ok   - touch allowlist cannot escape the repository"
else
  echo "NOT OK - touch allowlist escape validation"
  FAILURES=$((FAILURES + 1))
fi

printf 'new file\n' > "$WORKTREE/allowed/new-file.txt"
git -C "$WORKTREE" add allowed/new-file.txt
git -C "$WORKTREE" commit -qm unlisted-new-file
assert_case "rejects a new path unless it is explicitly listed" 1 "$TMP_DIR/state.json" "new_path_not_explicitly_allowed"
node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.contract.new_file_allowlist=["allowed/new-file.txt"]; fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/state.json"
( bash "$CHECK" --round-state "$TMP_DIR/state.json" --manifest-revision 3 ) > "$TMP_DIR/explicit-new-file.json" 2>/dev/null
if [ "$?" -eq 0 ]; then
  echo "ok   - explicit new-file allowlist permits only the named path"
else
  echo "NOT OK - explicit new-file allowlist permits only the named path"
  FAILURES=$((FAILURES + 1))
fi

mkdir -p "$WORKTREE/unpromised"
printf 'surprise\n' > "$WORKTREE/unpromised/file.txt"
git -C "$WORKTREE" add unpromised/file.txt
git -C "$WORKTREE" commit -qm unpromised-change
assert_case "rejects changed path outside allowlist" 1 "$TMP_DIR/state.json" "changed_path_outside_allowlist"

node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.contract.test_discovery_command="printf '\''different test\\n'\''"; fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/state.json"
assert_case "rejects undiscovered acceptance criterion" 1 "$TMP_DIR/state.json" "acceptance_not_discovered"

node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.contract.test_discovery_command="printf '\''AC-1\\n'\''"; v.acceptance.expected_test_count=2; fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/state.json"
assert_case "rejects unexpected discovered test count" 1 "$TMP_DIR/state.json" "unexpected_discovered_test_count"

node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.contract.touch_allowlist=["allowed/**","unpromised/**"]; v.contract.new_file_allowlist=["allowed/new-file.txt","unpromised/file.txt"]; v.contract.test_discovery_command="printf '\''TAP version 13\\n# AC-1\\n# tests 3\\n\\n'\''"; v.contract.test_count={pattern:"(?:ℹ |# )?tests ([0-9]+)",group:1}; v.acceptance.expected_test_count=3; fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/state.json"
( bash "$CHECK" --round-state "$TMP_DIR/state.json" --manifest-revision 3 ) > "$TMP_DIR/extractor-pass.json" 2>/dev/null
if [ "$?" -eq 0 ] && node -e 'const v=require(process.argv[1]); process.exit(v.status === "pass" && v.discovered_test_count === 3 ? 0 : 1)' "$TMP_DIR/extractor-pass.json"; then
  echo "ok   - extractor counts native-style discovery output"
else
  echo "NOT OK - extractor counts native-style discovery output"
  FAILURES=$((FAILURES + 1))
fi

node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.contract.test_discovery_command="printf '\''# tests 3\\n'\''"; fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/state.json"
assert_case "extractor keeps raw output for acceptance IDs" 1 "$TMP_DIR/state.json" "acceptance_not_discovered"

node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.contract.test_discovery_command="printf '\''# AC-1\\n# tests 2\\n'\''"; fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/state.json"
assert_case "extractor reports an integer count mismatch" 1 "$TMP_DIR/state.json" "unexpected_discovered_test_count"

for extractor_case in invalid_regex no_match missing_capture non_integer non_positive; do
  cp "$TMP_DIR/state.json" "$TMP_DIR/extractor-$extractor_case.json"
  node -e '
    const fs=require("fs"); const [file,kind]=process.argv.slice(1); const v=JSON.parse(fs.readFileSync(file,"utf8"));
    const values={invalid_regex:{pattern:"(",group:1},no_match:{pattern:"tests ([0-9]+)",group:1},missing_capture:{pattern:"tests",group:1},non_integer:{pattern:"tests ([^ ]+)",group:1},non_positive:{pattern:"tests ([0-9]+)",group:1}};
    const output={invalid_regex:"# AC-1\\n# tests 3\\n",no_match:"# AC-1\\n# cases 3\\n",missing_capture:"# AC-1\\n# tests\\n",non_integer:"# AC-1\\n# tests three\\n",non_positive:"# AC-1\\n# tests 0\\n"};
    v.contract.test_count=values[kind]; v.contract.test_discovery_command="printf '\''" + output[kind] + "'\''"; fs.writeFileSync(file,JSON.stringify(v));
  ' "$TMP_DIR/extractor-$extractor_case.json" "$extractor_case"
  assert_case "extractor fails closed for $extractor_case" 2 "$TMP_DIR/extractor-$extractor_case.json" "test_count_extractor_$extractor_case"
done

cp "$TMP_DIR/state.json" "$TMP_DIR/invalid-extractor-state.json"
node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.contract.test_count={pattern:"tests ([0-9]+)",group:-1,extra:true}; fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/invalid-extractor-state.json"
( bash "$CHECK" --round-state "$TMP_DIR/invalid-extractor-state.json" --manifest-revision 3 ) > "$TMP_DIR/invalid-extractor-output.json" 2>/dev/null
if [ "$?" -eq 2 ] && node -e 'const v=require(process.argv[1]); process.exit(v.mismatches[0].code === "invalid_round_state" && Array.isArray(v.mismatches[0].details) && v.mismatches[0].details.length > 0 ? 0 : 1)' "$TMP_DIR/invalid-extractor-output.json"; then
  echo "ok   - malformed extractor shape fails schema validation"
else
  echo "NOT OK - malformed extractor shape validation"
  FAILURES=$((FAILURES + 1))
fi

node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); delete v.acceptance.expected_test_count; fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/state.json"
( bash "$CHECK" --round-state "$TMP_DIR/state.json" --manifest-revision 3 ) > "$TMP_DIR/error.json" 2>/dev/null
if [ "$?" -eq 2 ] && node -e 'const v=require(process.argv[1]); process.exit(v.status === "error" && v.mismatches[0].code === "invalid_round_state" && Array.isArray(v.mismatches[0].details) && v.mismatches[0].details.length > 0 ? 0 : 1)' "$TMP_DIR/error.json"; then
  echo "ok   - invalid ROUND-STATE has machine-readable error"
else
  echo "NOT OK - invalid ROUND-STATE machine-readable error"
  FAILURES=$((FAILURES + 1))
fi

node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); delete v.contract.test_count; v.acceptance.expected_test_count=1; v.contract.test_discovery_command="printf '\''out\\n'\''; printf '\''err\\n'\'' >&2; exit 7"; fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/state.json"
( bash "$CHECK" --round-state "$TMP_DIR/state.json" --manifest-revision 3 ) > "$TMP_DIR/discovery-error.json" 2>/dev/null
if [ "$?" -eq 2 ] && node -e 'const v=require(process.argv[1]); process.exit(v.status === "error" && v.mismatches[0].code === "test_discovery_failed" && v.exit_code === 7 && v.output.includes("out") && v.output.includes("err") && v.output_truncated === false ? 0 : 1)' "$TMP_DIR/discovery-error.json"; then
  echo "ok   - failed discovery includes bounded diagnostics"
else
  echo "NOT OK - failed discovery diagnostics"
  FAILURES=$((FAILURES + 1))
fi

node -e 'const fs=require("fs"); const f=process.argv[1]; const v=JSON.parse(fs.readFileSync(f,"utf8")); v.contract.test_discovery_command="node -e \"process.stdout.write('\''가'\''.repeat(2000)); process.exit(9)\""; fs.writeFileSync(f,JSON.stringify(v));' "$TMP_DIR/state.json"
( bash "$CHECK" --round-state "$TMP_DIR/state.json" --manifest-revision 3 ) > "$TMP_DIR/discovery-truncated.json" 2>/dev/null
if [ "$?" -eq 2 ] && node -e 'const v=require(process.argv[1]); process.exit(v.exit_code === 9 && v.output_truncated === true && !v.output.includes("�") ? 0 : 1)' "$TMP_DIR/discovery-truncated.json"; then
  echo "ok   - failed discovery truncates UTF-8 safely"
else
  echo "NOT OK - failed discovery UTF-8 truncation"
  FAILURES=$((FAILURES + 1))
fi

echo "---"
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CASES PASS"
  exit 0
fi
echo "$FAILURES CASE(S) FAILED"
exit 1
