#!/usr/bin/env bash
# Regression smoke for schema-derived prompt contracts and BLOCKER validation.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONTRACT="$SCRIPT_DIR/../output-contract.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
failures=0
ok() { echo "ok   - $1"; }
bad() { echo "NOT OK - $1"; failures=$((failures + 1)); }

"$CONTRACT" render --role reviewer > "$TMP/reviewer.md"
if "$CONTRACT" check --role reviewer --prompt-file "$TMP/reviewer.md" >/dev/null; then ok "reviewer contract renders and validates"; else bad "reviewer contract renders and validates"; fi
"$CONTRACT" render --role implementation > "$TMP/implementation.md"
if grep -F -q 'Name each test so it contains the canonical AC id it satisfies' "$TMP/implementation.md" \
  && grep -F -q 'pre-review gate matches discovered test names against those ids' "$TMP/implementation.md"; then
  ok "implementation contract requires canonical AC ids in test names"
else
  bad "implementation contract requires canonical AC ids in test names"
fi
if ! grep -F -q 'Name each test so it contains the canonical AC id it satisfies' "$TMP/reviewer.md"; then
  ok "reviewer contract does not receive implementation test-name guidance"
else
  bad "reviewer contract does not receive implementation test-name guidance"
fi
if node - "$TMP/implementation.md" "$ROOT/schemas/pr_draft.schema.json" "$ROOT/schemas/blocker.schema.json" <<'NODE'
const fs = require("fs");
const body = fs.readFileSync(process.argv[2], "utf8").match(/```json\n([\s\S]*?)\n```/)[1];
const artifacts = JSON.parse(body).artifacts;
const prDraft = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
const blocker = JSON.parse(fs.readFileSync(process.argv[4], "utf8"));
// The writer receives the entire canonical schema, including constraints a
// lossy shape projection previously omitted (bounds, patterns, and branches).
process.exit(artifacts.length === 2
  && artifacts[0].name === "pr_draft"
  && JSON.stringify(artifacts[0].schema) === JSON.stringify(prDraft)
  && artifacts[0].schema.required.includes("worktree_path")
  && artifacts[1].name === "blocker"
  && JSON.stringify(artifacts[1].schema) === JSON.stringify(blocker)
  && artifacts[1].schema.allOf && artifacts[1].schema.allOf[0].oneOf ? 0 : 1);
NODE
then ok "implementation contract embeds complete canonical PR-DRAFT and BLOCKER schemas"; else bad "implementation contract embeds complete canonical PR-DRAFT and BLOCKER schemas"; fi
usage_out="$TMP/usage.out"
if ! "$CONTRACT" >"$usage_out" 2>&1 && grep -F -q 'valid roles: implementation|reviewer|architect|conductor|release' "$usage_out"; then ok "usage lists valid output-contract roles"; else bad "usage lists valid output-contract roles"; fi
if ! "$CONTRACT" render --role visual >"$usage_out" 2>&1 && grep -F -q 'invalid output-contract role: visual' "$usage_out"; then ok "unsupported output-contract role is rejected with usage"; else bad "unsupported output-contract role is rejected with usage"; fi
sed 's#schemas/review.schema.json#schemas/blocker.schema.json#' "$TMP/reviewer.md" > "$TMP/drift.md"
if ! "$CONTRACT" check --role reviewer --prompt-file "$TMP/drift.md" >/dev/null 2>&1; then ok "contract drift is rejected"; else bad "contract drift is rejected"; fi

BIN="$TMP/bin"; WT="$TMP/wt"; mkdir -p "$BIN" "$WT/.review"
cat > "$BIN/codex" <<'EOF'
#!/usr/bin/env bash
if [ -n "${CODEX_BLOCKER:-}" ]; then
  if [ -n "${CODEX_BLOCKER_MODE:-}" ]; then
    head_sha="$(git rev-parse HEAD)"
    node - "$CODEX_BLOCKER" "$CODEX_BLOCKER_MODE" "$head_sha" <<'NODE'
const fs=require("fs"); const [file,mode,head]=process.argv.slice(2);
const value={schema_version:"1",artifact_type:"blocker",lifecycle:mode==="superseded"?"superseded":"active",producer_role:"CODEX",producer_version:"0.2.0",issue:{number:9,title:"smoke"},head_sha:mode==="stale_head"?"0".repeat(40):head,reason_code:"tier_escalation_required",blocking_fact:"incomplete",attempted_commands:["smoke"],needed_decision:"decide",files_touched_before_abort:[],partial_diff_path:".review/partial.diff"};
if(mode==="wrong_issue") value.issue.number=99;
fs.writeFileSync(file,JSON.stringify(value));
NODE
  else
    printf '%s\n' '{"reason_code":"ambiguous_requirement","blocking_fact":"incomplete"}' > "$CODEX_BLOCKER"
  fi
fi
exit 0
EOF
chmod +x "$BIN/codex"
CODEX_BLOCKER="$WT/.review/ISSUE-9-BLOCKER.json" PATH="$BIN:$PATH" bash "$SCRIPT_DIR/../codex-safe.sh" --issue 9 --prompt hello --cwd "$WT" >/dev/null 2>&1
if [ "$?" -ne 0 ]; then ok "nonconforming BLOCKER is rejected by codex-safe"; else bad "nonconforming BLOCKER is rejected by codex-safe"; fi
PREEXISTING="$TMP/preexisting"
mkdir -p "$PREEXISTING/.review"
printf '%s\n' '{"reason_code":"ambiguous_requirement"}' > "$PREEXISTING/.review/ISSUE-11-BLOCKER.json"
if PATH="$BIN:$PATH" bash "$SCRIPT_DIR/../codex-safe.sh" --issue 11 --prompt hello --cwd "$PREEXISTING" >/dev/null 2>&1; then ok "unrelated pre-existing malformed BLOCKER is ignored"; else bad "unrelated pre-existing malformed BLOCKER is ignored"; fi
for blocker_mode in wrong_issue stale_head superseded; do
  blocker_wt="$TMP/blocker-$blocker_mode"
  mkdir -p "$blocker_wt/.review"
  git init -q "$blocker_wt"
  git -C "$blocker_wt" -c user.name=Smoke -c user.email=smoke@example.test commit --allow-empty -q -m init
  if CODEX_BLOCKER="$blocker_wt/.review/ISSUE-9-BLOCKER.json" CODEX_BLOCKER_MODE="$blocker_mode" PATH="$BIN:$PATH" bash "$SCRIPT_DIR/../codex-safe.sh" --issue 9 --prompt hello --cwd "$blocker_wt" >/dev/null 2>&1; then
    bad "$blocker_mode BLOCKER is rejected by codex-safe"
  else
    ok "$blocker_mode BLOCKER is rejected by codex-safe"
  fi
done

# Admission integration: new Markdown implementation prompts must carry the
# exact contract before even a dry-run can reach the transport adapter.
git init -q "$WT"
git -C "$WT" -c user.name=Smoke -c user.email=smoke@example.test commit --allow-empty -q -m init
RUNTIME="$TMP/runtime"
cat > "$RUNTIME" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo 'codex output-contract smoke'; exit 0 ;;
  --help) echo 'Commands: exec'; exit 0 ;;
  exec) [ "${2:-}" = "--help" ] && { echo 'exec --sandbox --cd --model --config --output-last-message --json'; exit 0; }; exit 0 ;;
esac
exit 0
EOF
chmod +x "$RUNTIME"
printf '%s\n' 'worker instructions' > "$WT/.review/ISSUE-10-PROMPT.md"
missing_contract_out="$TMP/missing-contract.out"
AGENT_WORKFLOW_CODEX_BIN="$RUNTIME" bash "$SCRIPT_DIR/../cmux-dispatch.sh" --issue 10 --worktree "$WT" --tier trivial --dry-run >"$missing_contract_out" 2>&1
missing_contract_status=$?
if [ "$missing_contract_status" -ne 0 ] \
  && grep -F -q "contract for role 'implementation'" "$missing_contract_out" \
  && grep -F -q "Fix: bash $ROOT/scripts/output-contract.sh render --role implementation >> $WT/.review/ISSUE-10-PROMPT.md" "$missing_contract_out" \
  && grep -F -q "Then verify: bash $ROOT/scripts/output-contract.sh check --role implementation --prompt-file $WT/.review/ISSUE-10-PROMPT.md" "$missing_contract_out"; then
  ok "Markdown implementation prompt rejection gives product-home recovery commands"
else
  bad "Markdown implementation prompt rejection gives product-home recovery commands"
fi
"$CONTRACT" render --role implementation >> "$WT/.review/ISSUE-10-PROMPT.md"
if AGENT_WORKFLOW_CODEX_BIN="$RUNTIME" bash "$SCRIPT_DIR/../cmux-dispatch.sh" --issue 10 --worktree "$WT" --tier trivial --dry-run >/dev/null 2>&1; then ok "schema-derived implementation contract reaches admission"; else bad "schema-derived implementation contract reaches admission"; fi
printf '%s\n' 'extensionless instructions' > "$WT/.review/ISSUE-13-PROMPT"
if AGENT_WORKFLOW_CODEX_BIN="$RUNTIME" bash "$SCRIPT_DIR/../cmux-dispatch.sh" --issue 13 --worktree "$WT" --prompt-file .review/ISSUE-13-PROMPT --tier trivial --dry-run >/dev/null 2>&1; then bad "extensionless prompt without contract is rejected"; else ok "extensionless prompt without contract is rejected"; fi
"$CONTRACT" render --role implementation >> "$WT/.review/ISSUE-13-PROMPT"
if AGENT_WORKFLOW_CODEX_BIN="$RUNTIME" bash "$SCRIPT_DIR/../cmux-dispatch.sh" --issue 13 --worktree "$WT" --prompt-file .review/ISSUE-13-PROMPT --tier trivial --dry-run >/dev/null 2>&1; then ok "extensionless prompt contract reaches admission"; else bad "extensionless prompt contract reaches admission"; fi
printf '%s\n' 'review instructions' > "$WT/.review/ISSUE-12-REVIEW-PROMPT.md"
missing_reviewer_contract_out="$TMP/missing-reviewer-contract.out"
AGENT_WORKFLOW_CODEX_BIN="$RUNTIME" bash "$SCRIPT_DIR/../cmux-dispatch.sh" --issue 12 --worktree "$WT" --prompt-file "$WT/.review/ISSUE-12-REVIEW-PROMPT.md" --produce-review --model gpt-5.6-sol --effort medium --dry-run >"$missing_reviewer_contract_out" 2>&1
missing_reviewer_contract_status=$?
if [ "$missing_reviewer_contract_status" -ne 0 ] \
  && grep -F -q "contract for role 'reviewer'" "$missing_reviewer_contract_out" \
  && grep -F -q "Fix: bash $ROOT/scripts/output-contract.sh render --role reviewer >> $WT/.review/ISSUE-12-REVIEW-PROMPT.md" "$missing_reviewer_contract_out" \
  && grep -F -q "Then verify: bash $ROOT/scripts/output-contract.sh check --role reviewer --prompt-file $WT/.review/ISSUE-12-REVIEW-PROMPT.md" "$missing_reviewer_contract_out"; then
  ok "Markdown reviewer prompt rejection gives selected-role recovery commands"
else
  bad "Markdown reviewer prompt rejection gives selected-role recovery commands"
fi
"$CONTRACT" render --role reviewer >> "$WT/.review/ISSUE-12-REVIEW-PROMPT.md"
if AGENT_WORKFLOW_CODEX_BIN="$RUNTIME" bash "$SCRIPT_DIR/../cmux-dispatch.sh" --issue 12 --worktree "$WT" --prompt-file "$WT/.review/ISSUE-12-REVIEW-PROMPT.md" --produce-review --model gpt-5.6-sol --effort medium --dry-run >/dev/null 2>&1; then ok "schema-derived reviewer contract reaches admission"; else bad "schema-derived reviewer contract reaches admission"; fi

if [ "$failures" -eq 0 ]; then echo "ALL TESTS PASS"; exit 0; fi
exit 1
