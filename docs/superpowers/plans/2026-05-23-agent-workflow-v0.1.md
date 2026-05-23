# Agent Workflow v0.1 Trial Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up minimum infrastructure to run ONE single-issue trial of the multi-agent workflow (CODEX + REVIEWER + VERIFIER pattern) on issue #33, with all 5 CRIT guardrails in place. Defer CONDUCTOR and parallel-cluster support to v0.2.

**Architecture:** Three layers — (1) bash wrappers around `codex` to enforce sandbox + partial-stash, (2) a `cmux` 4-pane setup script for one issue cluster, (3) `.review/` directory + minimal JSON schemas + AGENTS.md patches encoding the workflow rules. No new package dependencies. Trial run validates end-to-end before scaling to parallel clusters.

**Tech Stack:** bash 4+, `cmux` CLI, `codex` CLI, `gh` CLI, `git` 2.30+ worktrees, jsonschema (npm `ajv-cli` for validation), existing pnpm/turbo monorepo tooling.

**Scope boundary:** This plan delivers infrastructure + one validated trial. Out of scope: CONDUCTOR persona, multi-cluster parallel, impeccable integration, Playwright smoke automation, full JSON schema enforcement. Those are v0.2.

**Trial target:** Issue #33 — `[P3] HttpError.detail discriminated union typing (SEC2-4-6)`. Single file (`apps/backend/src/lib/errors.ts`) + types + spec. Safest P3 to validate flow without semantic risk.

**Scope clarification for #33:** Issue text explicitly references `apps/backend/src/lib/errors.ts:33`. The trial **does not** tighten `packages/shared/src/errors/codes.ts:80` (`ErrorEnvelope.detail?: Record<string, unknown>`). That public-envelope tightening is a separate concern — file a follow-up issue if desired. Without this clarification, the workflow's escalation rule (any `packages/shared/*` touch = Full Cluster) would force CODEX to abort. Backend-only keeps it Trivial tier as intended.

**Branch model:** All infrastructure (T1-T5) lives on `feature/agent-workflow-trial`. The trial worktree (T6) branches FROM `feature/agent-workflow-trial`, not `develop` — otherwise the worktree cannot see the new scripts/schemas.

---

## File Structure

```
scripts/
  codex-safe.sh           # codex exec wrapper — sandbox + cwd lock + abort hook
  cmux-cluster.sh         # 1-issue 4-pane setup (ARCH + CODEX + REVIEWER + VERIFIER)
  workflow-stash.sh       # called by codex-safe on abort — save partial diff
.review/
  schemas/
    pr_draft.schema.json  # minimal: issue, branch, base_sha, head_sha, files, verify_cmd, status
    blocker.schema.json   # minimal: issue, attempted_cmd, blocker, recommended_actions[]
    review.schema.json    # minimal: issue, status, findings[], patch_instructions
    touch.schema.json     # minimal: issue, files[], escalation_required
  .gitkeep
  README.md               # lifecycle rules: draft|active|superseded|final
.githooks/
  post-merge              # rebase in-flight worktrees + run affected tests
docs/agents/
  workflow.md             # NEW: extracted operating playbook, risk tiers, Release Captain
AGENTS.md                 # PATCHED: pointer to workflow.md + sandbox rule
```

---

## Task 1: `.review/` Directory + Schemas + README

**Files:**
- Create: `.review/.gitkeep`
- Create: `.review/README.md`
- Create: `.review/schemas/pr_draft.schema.json`
- Create: `.review/schemas/blocker.schema.json`
- Create: `.review/schemas/review.schema.json`
- Create: `.review/schemas/touch.schema.json`
- Modify: `.gitignore` — ensure `.review/*.json` excluded but schemas + README tracked

- [ ] **Step 1: Create `.review/.gitkeep`**

```bash
mkdir -p .review/schemas
touch .review/.gitkeep
```

- [ ] **Step 2: Write `.review/README.md`**

```markdown
# .review/

Per-issue agent handoff artifacts. JSON canonical, lifecycle-tracked.

## Files

- `ISSUE-N-PR-DRAFT.json` — CODEX → REVIEWER handoff (commit SHA, files, verify)
- `ISSUE-N-BLOCKER.json` — CODEX abort report (no commit, why stopped)
- `ISSUE-N-REVIEW.json` — REVIEWER findings + patch_instructions for ARCHITECT
- `ISSUE-N-TOUCH.json` — declared files (parallel coordination, v0.2+)
- `ISSUE-N-PARTIAL.diff` — stashed partial work on abort (v0.1: optional)

## Lifecycle

Every JSON includes `lifecycle: "draft" | "active" | "superseded" | "final"`.
Superseded files MUST be ignored by readers. Cleanup: archived under
`.review/archive/YYYY-MM/` on PR merge.

## Schema versioning

`schema_version: "1"` mandatory. Cross-version reads refused.

## Validation

```bash
pnpm dlx ajv-cli validate \
  -s .review/schemas/pr_draft.schema.json \
  -d .review/ISSUE-33-PR-DRAFT.json
```
```

- [ ] **Step 3: Write `.review/schemas/pr_draft.schema.json`**

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "PR Draft Artifact",
  "type": "object",
  "additionalProperties": false,
  "required": ["schema_version", "artifact_type", "lifecycle", "producer_role", "issue", "branch", "base_sha", "head_sha", "files_touched", "verify_cmd", "status"],
  "properties": {
    "schema_version": { "const": "1" },
    "artifact_type": { "const": "pr_draft" },
    "lifecycle": { "enum": ["draft", "active", "superseded", "final"] },
    "producer_role": { "const": "CODEX" },
    "producer_version": { "type": "string", "description": "optional: agent CLI version (e.g. 'codex/0.133.0') for debugging provenance" },
    "issue": {
      "type": "object",
      "additionalProperties": false,
      "required": ["number", "title"],
      "properties": {
        "number": { "type": "integer" },
        "title": { "type": "string" },
        "labels": { "type": "array", "items": { "type": "string" } }
      }
    },
    "branch": { "type": "string" },
    "base_sha": { "type": "string", "pattern": "^[0-9a-f]{40}$" },
    "head_sha": { "type": "string", "pattern": "^[0-9a-f]{40}$" },
    "summary": { "type": "string" },
    "files_touched": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["path", "change"],
        "properties": {
          "path": { "type": "string" },
          "change": { "enum": ["add", "edit", "delete"] }
        }
      }
    },
    "tests": { "type": "array", "items": { "type": "string" } },
    "verify_cmd": { "type": "string" },
    "verify_output_path": { "type": "string" },
    "risks": { "type": "array", "items": { "type": "string" } },
    "deviations": { "type": "array", "items": { "type": "string" } },
    "status": { "enum": ["ready_for_review", "needs_amendment", "abandoned"] }
  }
}
```

- [ ] **Step 4: Write `.review/schemas/blocker.schema.json`**

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "Blocker Artifact",
  "type": "object",
  "additionalProperties": false,
  "required": ["schema_version", "artifact_type", "lifecycle", "producer_role", "issue", "attempted_command", "blocker", "recommended_actions"],
  "properties": {
    "schema_version": { "const": "1" },
    "artifact_type": { "const": "blocker" },
    "lifecycle": { "enum": ["active", "superseded", "final"] },
    "producer_role": { "const": "CODEX" },
    "producer_version": { "type": "string" },
    "issue": {
      "type": "object",
      "additionalProperties": false,
      "required": ["number"],
      "properties": { "number": { "type": "integer" } }
    },
    "attempted_command": { "type": "string" },
    "blocker": { "type": "string" },
    "files_touched_before_abort": { "type": "array", "items": { "type": "string" } },
    "partial_diff_path": { "type": "string" },
    "recommended_actions": {
      "type": "array",
      "minItems": 1,
      "items": { "type": "string" }
    }
  }
}
```

- [ ] **Step 5: Write `.review/schemas/review.schema.json`**

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "Review Artifact",
  "type": "object",
  "additionalProperties": false,
  "required": ["schema_version", "artifact_type", "lifecycle", "producer_role", "issue", "reviewed_head_sha", "status", "checklist"],
  "properties": {
    "schema_version": { "const": "1" },
    "artifact_type": { "const": "review" },
    "lifecycle": { "enum": ["draft", "active", "superseded", "final"] },
    "producer_role": { "const": "REVIEWER" },
    "producer_version": { "type": "string" },
    "issue": {
      "type": "object",
      "additionalProperties": false,
      "required": ["number"],
      "properties": { "number": { "type": "integer" } }
    },
    "reviewed_head_sha": { "type": "string", "pattern": "^[0-9a-f]{40}$" },
    "status": { "enum": ["pass", "fail", "blocked"] },
    "checklist": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["item", "met"],
        "properties": {
          "item": { "type": "string" },
          "met": { "type": "boolean" },
          "note": { "type": "string" }
        }
      }
    },
    "findings": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["severity", "description"],
        "properties": {
          "severity": { "enum": ["block", "fix", "nit"] },
          "description": { "type": "string" },
          "file": { "type": "string" }
        }
      }
    },
    "patch_instructions": { "type": "string" }
  }
}
```

- [ ] **Step 6: Write `.review/schemas/touch.schema.json`**

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "Touch Declaration Artifact",
  "type": "object",
  "additionalProperties": false,
  "required": ["schema_version", "artifact_type", "lifecycle", "producer_role", "issue", "files", "escalation_required"],
  "properties": {
    "schema_version": { "const": "1" },
    "artifact_type": { "const": "touch" },
    "lifecycle": { "enum": ["active", "superseded", "final"] },
    "producer_role": { "const": "CODEX" },
    "producer_version": { "type": "string" },
    "issue": {
      "type": "object",
      "additionalProperties": false,
      "required": ["number"],
      "properties": { "number": { "type": "integer" } }
    },
    "files": { "type": "array", "items": { "type": "string" } },
    "escalation_required": { "type": "boolean", "description": "true if touches packages/shared, migrations, shared UI, permissions, or auth" }
  }
}
```

- [ ] **Step 7: Update `.gitignore`**

Append:
```
# .review/ — schemas + README tracked, per-issue JSON artifacts ephemeral
.review/ISSUE-*.json
.review/ISSUE-*.diff
.review/archive/
```

- [ ] **Step 8: Verify schemas parse**

```bash
for f in .review/schemas/*.schema.json; do
  node -e "JSON.parse(require('fs').readFileSync('$f','utf8')); console.log('OK $f')"
done
```
Expected: 4 `OK` lines, no errors.

- [ ] **Step 9: Commit**

```bash
git add .review/ .gitignore
git commit -m "feat(workflow): scaffold .review/ artifacts directory + JSON schemas (v0.1)"
```

---

## Task 2: `scripts/codex-safe.sh` — Sandbox + Partial-Stash Wrapper

**Files:**
- Create: `scripts/codex-safe.sh`
- Create: `scripts/workflow-stash.sh`

- [ ] **Step 1: Write `scripts/workflow-stash.sh`**

```bash
#!/usr/bin/env bash
# Called when codex aborts mid-work. Saves uncommitted diff AND copies
# untracked files (gitignored excluded). Caps untracked file count to
# avoid pathological recursive copies. NUL-safe path handling.
set -euo pipefail

ISSUE_N="${1:?usage: workflow-stash.sh <issue-number>}"
WORKTREE="${2:-$(pwd)}"
MAX_UNTRACKED="${MAX_UNTRACKED:-200}"      # hard cap; abort copy if exceeded
MAX_UNTRACKED_BYTES="${MAX_UNTRACKED_BYTES:-10485760}"   # 10 MB total

cd "$WORKTREE"

HAS_TRACKED=1
HAS_UNTRACKED=1
git diff --quiet && git diff --cached --quiet && HAS_TRACKED=0

# NUL-separated for safety against weird filenames
UNTRACKED_COUNT=$(git ls-files --others --exclude-standard -z | tr -cd '\0' | wc -c | tr -d ' ')
[[ "$UNTRACKED_COUNT" -eq 0 ]] && HAS_UNTRACKED=0

if [[ $HAS_TRACKED -eq 0 && $HAS_UNTRACKED -eq 0 ]]; then
  echo "no partial work to stash"
  exit 0
fi

mkdir -p .review
DIFF_OUT=".review/ISSUE-${ISSUE_N}-PARTIAL.diff"
UNTRACKED_LIST=".review/ISSUE-${ISSUE_N}-PARTIAL-UNTRACKED.txt"
UNTRACKED_DIR=".review/ISSUE-${ISSUE_N}-PARTIAL-UNTRACKED"

if [[ $HAS_TRACKED -eq 1 ]]; then
  git diff HEAD > "$DIFF_OUT"
  echo "stashed tracked diff to $DIFF_OUT ($(wc -l < "$DIFF_OUT" | tr -d ' ') lines)"
fi

if [[ $HAS_UNTRACKED -eq 1 ]]; then
  if [[ "$UNTRACKED_COUNT" -gt "$MAX_UNTRACKED" ]]; then
    echo "WARN: $UNTRACKED_COUNT untracked files exceeds MAX_UNTRACKED=$MAX_UNTRACKED — listing only, not copying" >&2
    git ls-files --others --exclude-standard > "$UNTRACKED_LIST"
    echo "untracked file list saved to $UNTRACKED_LIST (no copy)"
  else
    git ls-files --others --exclude-standard > "$UNTRACKED_LIST"
    rm -rf "$UNTRACKED_DIR"
    TOTAL_BYTES=0
    OVER_LIMIT=0
    while IFS= read -r -d '' f; do
      [[ -z "$f" ]] && continue
      SZ=$(wc -c < "$f" 2>/dev/null || echo 0)
      TOTAL_BYTES=$((TOTAL_BYTES + SZ))
      if [[ $TOTAL_BYTES -gt $MAX_UNTRACKED_BYTES ]]; then
        OVER_LIMIT=1
        break
      fi
      mkdir -p "$UNTRACKED_DIR/$(dirname "$f")"
      cp "$f" "$UNTRACKED_DIR/$f" 2>/dev/null || { echo "WARN: skipping unreadable $f" >&2; continue; }
    done < <(git ls-files --others --exclude-standard -z)
    if [[ $OVER_LIMIT -eq 1 ]]; then
      echo "WARN: total untracked size exceeded MAX_UNTRACKED_BYTES=$MAX_UNTRACKED_BYTES — partial copy in $UNTRACKED_DIR/" >&2
    else
      echo "stashed $UNTRACKED_COUNT untracked file(s) to $UNTRACKED_DIR/ ($TOTAL_BYTES bytes)"
    fi
  fi
fi
```

- [ ] **Step 2: Write `scripts/codex-safe.sh`**

```bash
#!/usr/bin/env bash
# codex exec wrapper. Enforces: workspace-write sandbox, --cd working-dir lock,
# optional abort-stash for partial work preservation.
#
# Usage:
#   scripts/codex-safe.sh --issue 33 --prompt-file /path/to/prompt.txt
#   scripts/codex-safe.sh --issue 33 --prompt "inline prompt"
set -euo pipefail

ISSUE_N=""
PROMPT=""
PROMPT_FILE=""
CWD="$(pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue) ISSUE_N="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
    --cwd) CWD="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -z "$ISSUE_N" ]] && { echo "missing --issue" >&2; exit 2; }
[[ -z "$PROMPT" && -z "$PROMPT_FILE" ]] && { echo "missing --prompt or --prompt-file" >&2; exit 2; }
[[ -n "$PROMPT_FILE" ]] && PROMPT="$(cat "$PROMPT_FILE")"
[[ -z "$PROMPT" ]] && { echo "prompt is empty (check --prompt-file content)" >&2; exit 2; }

# Trap to stash ONLY on non-zero exit (codex failure or abort).
# On success, leave artifacts alone — agent already wrote its handoff files.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
trap 's=$?; if [[ $s -ne 0 ]]; then "$SCRIPT_DIR/workflow-stash.sh" "$ISSUE_N" "$CWD" || true; fi; exit $s' EXIT

cd "$CWD"

codex exec \
  --sandbox workspace-write \
  --cd "$CWD" \
  "$PROMPT"
```

- [ ] **Step 3: Make executable**

```bash
chmod +x scripts/codex-safe.sh scripts/workflow-stash.sh
```

- [ ] **Step 4: Test stash script — no diff case**

```bash
git stash push -u 2>/dev/null || true   # ensure clean
bash scripts/workflow-stash.sh 999
```
Expected stdout: `no partial work to stash`. Exit 0.

- [ ] **Step 5: Test stash script — with diff**

```bash
echo "// scratch" >> apps/backend/src/lib/errors.ts
bash scripts/workflow-stash.sh 999
ls -la .review/ISSUE-999-PARTIAL.diff
git checkout apps/backend/src/lib/errors.ts
rm .review/ISSUE-999-PARTIAL.diff
```
Expected stdout includes: `stashed tracked diff to .review/ISSUE-999-PARTIAL.diff (N lines)`. File exists.

- [ ] **Step 6: Test codex-safe with trivial prompt (dry-ish)**

```bash
echo "Print the word READY and nothing else." > /tmp/safe-test.txt
bash scripts/codex-safe.sh --issue 999 --prompt-file /tmp/safe-test.txt --cwd "$(pwd)" 2>&1 | tail -20
```
Expected: codex banner shows `sandbox: workspace-write`. Output contains `READY`. No partial diff (no edits). Exit 0.

- [ ] **Step 7: Commit**

```bash
git add scripts/codex-safe.sh scripts/workflow-stash.sh
git commit -m "feat(workflow): codex-safe wrapper enforces workspace-write sandbox + partial-stash"
```

---

## Task 3: `scripts/cmux-cluster.sh` — 4-Pane Setup for One Issue

**Files:**
- Create: `scripts/cmux-cluster.sh`

- [ ] **Step 1: Write `scripts/cmux-cluster.sh`**

```bash
#!/usr/bin/env bash
# Set up 4-pane cmux workspace for a single-issue trial.
# Layout:
#   ARCHITECT (top-left)   |  CODEX (top-right)
#   REVIEWER  (bottom-left)|  VERIFIER (bottom-right)
#
# Usage: scripts/cmux-cluster.sh <issue-N> <slug>
set -euo pipefail

ISSUE_N="${1:?usage: cmux-cluster.sh <issue-N> <slug>}"
SLUG="${2:?usage: cmux-cluster.sh <issue-N> <slug>}"
REPO_ROOT="$(git rev-parse --show-toplevel)"

# Create worktree
WT_PATH="${REPO_ROOT}/../wt-${ISSUE_N}-${SLUG}"
BRANCH="feature/${ISSUE_N}-${SLUG}"
TRIAL_BASE="${TRIAL_BASE:-develop}"   # override for trial runs where infra lives on a non-develop branch

if [[ ! -d "$WT_PATH" ]]; then
  git worktree add "$WT_PATH" -b "$BRANCH" "$TRIAL_BASE"
else
  # Worktree already exists. Validate it has workflow infra; refuse silent reuse
  # of a stale worktree branched from the wrong base.
  if [[ ! -f "$WT_PATH/scripts/codex-safe.sh" || ! -d "$WT_PATH/.review/schemas" ]]; then
    echo "ERROR: worktree at $WT_PATH exists but is missing workflow infra." >&2
    echo "       (no scripts/codex-safe.sh or .review/schemas/). Likely branched from" >&2
    echo "       a base that predates T1-T5. Remove it explicitly before re-running:" >&2
    echo "         git worktree remove --force $WT_PATH && git branch -D $BRANCH" >&2
    exit 1
  fi
fi

# Spawn cmux workspace
WS=$(cmux new-workspace --name "issue-${ISSUE_N}-${SLUG}" --cwd "$WT_PATH" | awk 'NR==1{print $2; exit}')
LEFT=$(cmux list-pane-surfaces --workspace "$WS" | awk 'NR==1{print $2; exit}')

RIGHT=$(cmux new-split right --workspace "$WS" --surface "$LEFT" | awk 'NR==1{print $2; exit}')
BL=$(cmux new-split down --workspace "$WS" --surface "$LEFT" | awk 'NR==1{print $2; exit}')
BR=$(cmux new-split down --workspace "$WS" --surface "$RIGHT" | awk 'NR==1{print $2; exit}')

# Guard: any empty ID means a cmux call produced no output — abort before half-building.
for v in WS LEFT RIGHT BL BR; do
  if [[ -z "${!v}" ]]; then
    echo "ERROR: cmux produced no ID for $v — aborting (workspace may be half-built)." >&2
    exit 1
  fi
done

cmux rename-tab --workspace "$WS" --surface "$LEFT"  "ARCHITECT-${ISSUE_N}"
cmux rename-tab --workspace "$WS" --surface "$RIGHT" "CODEX-${ISSUE_N}"
cmux rename-tab --workspace "$WS" --surface "$BL"    "REVIEWER-${ISSUE_N}"
cmux rename-tab --workspace "$WS" --surface "$BR"    "VERIFIER-${ISSUE_N}"

# Banners
for pair in "$LEFT|ARCHITECT — plan + dispatch" \
            "$RIGHT|CODEX — codex-safe wrapper" \
            "$BL|REVIEWER — checklist + review.json" \
            "$BR|VERIFIER — pnpm test + typecheck"; do
  SURF="${pair%%|*}"
  MSG="${pair##*|}"
  cmux send --workspace "$WS" --surface "$SURF" "clear && echo '=== $MSG ==='"
  cmux send-key --workspace "$WS" --surface "$SURF" Enter
done

echo "workspace=$WS worktree=$WT_PATH branch=$BRANCH"
echo "panes: ARCH=$LEFT CODEX=$RIGHT REV=$BL VER=$BR"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/cmux-cluster.sh
```

- [ ] **Step 3: Dry-run validate (no actual spawn)**

```bash
bash -n scripts/cmux-cluster.sh
```
Expected: no output, exit 0 (syntax valid).

- [ ] **Step 4: Live test with throwaway issue number 9999 + slug `dry`**

```bash
bash scripts/cmux-cluster.sh 9999 dry
```
Expected stdout: `workspace=workspace:N worktree=.../wt-9999-dry branch=feature/9999-dry` + pane IDs.
Visual check: open cmux, see 4 panes labeled `ARCHITECT-9999` etc.

- [ ] **Step 5: Cleanup test workspace + worktree**

```bash
# Extract the workspace:N handle regardless of column position (a selected
# workspace is prefixed with '*', shifting fields). Match the token by pattern.
WS_ID=$(cmux list-workspaces | awk '/issue-9999-dry/{for(i=1;i<=NF;i++) if($i ~ /^workspace:/){print $i; exit}}')
[[ -n "$WS_ID" ]] && cmux close-workspace --workspace "$WS_ID"
git worktree remove ../wt-9999-dry --force 2>/dev/null || true
git branch -D feature/9999-dry 2>/dev/null || true
```

- [ ] **Step 6: Commit**

```bash
git add scripts/cmux-cluster.sh
git commit -m "feat(workflow): cmux-cluster.sh — 4-pane setup for single-issue trial"
```

---

## Task 4: `.githooks/post-merge` — Rebase + Affected-Test Hook

**Files:**
- Create: `.githooks/post-merge`
- Modify: `AGENTS.md` (one-line note about enabling)

- [ ] **Step 1: Write `.githooks/post-merge`**

```bash
#!/usr/bin/env bash
# After a merge on develop, find sibling worktrees pointing at feature/* branches
# and warn that they should rebase. Non-blocking.
set -euo pipefail

CUR_BRANCH=$(git rev-parse --abbrev-ref HEAD)
[[ "$CUR_BRANCH" != "develop" ]] && exit 0

REPO_ROOT=$(git rev-parse --show-toplevel)
PARENT=$(dirname "$REPO_ROOT")

# List all worktrees
mapfile -t WORKTREES < <(git worktree list --porcelain | awk '/^worktree /{print $2}')

SIBLINGS=()
for wt in "${WORKTREES[@]}"; do
  [[ "$wt" == "$REPO_ROOT" ]] && continue
  if [[ -d "$wt" ]]; then
    BRANCH=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [[ "$BRANCH" == feature/* ]]; then
      SIBLINGS+=("$wt|$BRANCH")
    fi
  fi
done

if [[ ${#SIBLINGS[@]} -eq 0 ]]; then
  exit 0
fi

echo ""
echo "=== post-merge: $(echo "${#SIBLINGS[@]}") in-flight feature worktree(s) ==="
for entry in "${SIBLINGS[@]}"; do
  WT="${entry%%|*}"
  BR="${entry##*|}"
  echo "  • $BR at $WT"
  echo "    suggest: (cd $WT && git fetch && git rebase develop && pnpm test:affected)"
done
echo ""
```

- [ ] **Step 2: Make executable**

```bash
chmod +x .githooks/post-merge
```

- [ ] **Step 3: Document hook enable (one-time per clone)**

Append to `AGENTS.md` under `## Git Workflow` after the Pre-push hook line:

```markdown
- **Post-merge hook.** `.githooks/post-merge` warns about in-flight sibling worktrees needing rebase after a `develop` merge. Enabled by the same `git config core.hooksPath .githooks` as pre-push.
```

- [ ] **Step 4: Verify hook runs (simulate)**

```bash
git config core.hooksPath .githooks
git merge --no-commit --no-ff HEAD --allow-empty -m "test"  # no actual merge
git reset --hard HEAD~0
# direct invocation:
bash .githooks/post-merge
```
Expected: no error. If no sibling worktrees, no output.

- [ ] **Step 5: Commit**

```bash
git add .githooks/post-merge AGENTS.md
git commit -m "feat(workflow): post-merge hook warns about in-flight worktrees needing rebase"
```

---

## Task 5: AGENTS.md Patch — Risk-Tier Routing + Release Captain + Sandbox Rule

**Files:**
- Create: `docs/agents/workflow.md`
- Modify: `AGENTS.md` (add pointer + sandbox rule)

- [ ] **Step 1: Write `docs/agents/workflow.md`**

```markdown
# Multi-Agent Workflow — Operating Playbook v0.1

This file holds the *operating* rules for the multi-agent workflow (cmux 4-pane × Claude × Codex). For higher-level design discussion see `docs/agents/multi-agent-workflow-draft.md` and `docs/agents/workflow-*.html`.

## Risk Tier Routing

Every issue is one of three tiers. The tier picks the agent set.

| Tier | When | Agents | Artifacts |
|---|---|---|---|
| **Trivial** | P3 cleanup, single file, no API/domain/UI change | CODEX + VERIFIER | pr_draft only |
| **Standard** | P2 / single-module behavior change | CODEX + REVIEWER + VERIFIER | pr_draft + review |
| **Full Cluster** | Any of: migration, auth, permissions, shared UI shells, `packages/shared`, cross-module contract, prod data path | ARCHITECT + CODEX + REVIEWER + VERIFIER (+ VISUAL if UI) | all of pr_draft, touch, review, verify |

**Escalation rule:** if a Trivial or Standard issue's actual touch set hits any Full Cluster trigger (e.g. `packages/shared/*`, migrations), CODEX MUST abort with a `blocker` artifact whose `recommended_actions[0]` is `"escalate to Full Cluster tier"`.

## Release Captain

Every issue has one **Release Captain**. The Captain owns merge readiness with override authority.

- **Default Captain:** the user (interactive mode) or CONDUCTOR (v0.2+).
- **Authority:** may reject merge despite all-green artifacts.
- **Mandate:** verify *integrated behavior* — does the change work end-to-end, not just pass local tests?
- **Why:** REVIEWER checks design fit and VERIFIER checks commands, but neither owns "does this actually ship safely."

## Codex Sandbox Rule

All `codex exec` invocations MUST go through `scripts/codex-safe.sh`, which enforces:

- `--sandbox workspace-write` (no read/write outside cwd)
- `--cwd <worktree>` (lock to single worktree)
- abort-time `workflow-stash.sh` (preserve partial diff)

Direct `codex exec` invocations are forbidden in this workflow.

## Artifact Lifecycle

Every `.review/ISSUE-*.json` carries `lifecycle: draft | active | superseded | final`. Superseded files MUST be ignored by readers. See `.review/README.md`.

## Workflow Tax Brake

If a Trivial issue routes through more than CODEX + VERIFIER, the workflow has failed and must be re-evaluated. The workflow exists to ship faster, not slower.
```

- [ ] **Step 2: Patch `AGENTS.md` — append under `## Agent Skills`**

Add new bullet at the end of the `## Agent Skills` block:

```markdown
- **Multi-agent workflow (v0.1 trial).** Operating playbook in `docs/agents/workflow.md`. Risk tiers, Release Captain, codex sandbox rule. All `codex exec` MUST go through `scripts/codex-safe.sh`.
```

- [ ] **Step 3: Verify links resolve**

```bash
test -f docs/agents/workflow.md && echo "workflow.md OK"
grep -q "docs/agents/workflow.md" AGENTS.md && echo "AGENTS.md pointer OK"
```
Expected: both `OK` lines.

- [ ] **Step 4: Commit**

```bash
git add docs/agents/workflow.md AGENTS.md
git commit -m "docs(workflow): operating playbook v0.1 — risk tiers + Release Captain + sandbox rule"
```

---

## Task 6: Trial Dispatch on Issue #33

**Files:**
- Create: `.review/ISSUE-33-PROMPT.txt` (input to codex-safe)
- Create: `.review/ISSUE-33-PR-DRAFT.json` (CODEX output)
- Create: `.review/ISSUE-33-REVIEW.json` (REVIEWER output)
- Modify: `apps/backend/src/lib/errors.ts`
- Create or modify: `apps/backend/src/lib/errors.spec.ts`

This task is the **trial itself** — the workflow drives the implementation. Steps below describe the human/architect orchestration.

- [ ] **Step 1: Set up cluster — branch FROM feature/agent-workflow-trial (NOT develop)**

```bash
# IMPORTANT: cmux-cluster.sh by default branches from develop. Override here so
# the worktree inherits the workflow scripts/schemas committed in T1-T5.
TRIAL_BASE=feature/agent-workflow-trial bash scripts/cmux-cluster.sh 33 httperror-detail-union
```

The base override must be implemented as a TRIAL_BASE env var in `scripts/cmux-cluster.sh` — add this as a fix to Task 3 Step 1 BEFORE running this step:

```bash
# In scripts/cmux-cluster.sh, replace:
#   git worktree add "$WT_PATH" -b "$BRANCH" develop
# with:
TRIAL_BASE="${TRIAL_BASE:-develop}"
git worktree add "$WT_PATH" -b "$BRANCH" "$TRIAL_BASE"
```

Note the workspace ID and pane IDs printed. Cluster tier: **Trivial** (P3, single file, type-only change). The new worktree will contain `scripts/codex-safe.sh`, `.review/schemas/*`, `docs/agents/workflow.md`.

- [ ] **Step 2: ARCHITECT writes prompt (Trivial template — MINIMAL)**

Write to `../wt-33-httperror-detail-union/.review/ISSUE-33-PROMPT.txt`:

```text
Issue: #33 [P3] HttpError.detail discriminated union typing (SEC2-4-6)
Task: Replace HttpError.detail's Record<string, unknown> with discriminated union DetailShape covering 422/409 field errors, 429 retry, 404/409 resource refs, plus undefined. Tighten constructor signature.
Scope: apps/backend/src/lib/errors.ts and apps/backend/src/lib/__tests__/errors.test.ts ONLY. Forbidden: any other file, including packages/shared/src/errors/codes.ts (separate follow-up issue).
Accept:
  - DetailShape union type defined in errors.ts
  - HttpError constructor's detail param typed as DetailShape
  - tsc --noEmit passes
  - errors.test.ts contains at minimum: (a) positive instantiation for each DetailShape variant, (b) compile-time negative test using `// @ts-expect-error` for the legacy `{ field: "..." }` singular shape, (c) compile-time negative test for an unknown shape like `{ random: 1 }`
  - Negative tests MUST be plain expressions. FORBIDDEN: `as any`, `as never`, `as unknown`, `// @ts-ignore`, or any type assertion that bypasses the union check. The `@ts-expect-error` directive must apply to the unmodified value, otherwise the test proves nothing.
  - All existing tests in errors.test.ts still pass (statusForCode coverage preserved)
Verify (run BOTH, both must pass):
  pnpm --filter backend run typecheck
  pnpm --filter backend test errors
Handoff: write .review/ISSUE-33-PR-DRAFT.json conforming to .review/schemas/pr_draft.schema.json with status="ready_for_review". On any ambiguity abort + write .review/ISSUE-33-BLOCKER.json. Do NOT touch packages/shared — if you believe you must, abort with blocker.recommended_actions including "escalate to Standard tier (touches packages/shared)".
```

- [ ] **Step 3: Dispatch via codex-safe in CODEX pane**

In CODEX pane:

```bash
cd ../wt-33-httperror-detail-union
bash scripts/codex-safe.sh --issue 33 --prompt-file .review/ISSUE-33-PROMPT.txt
```

Expected: codex banner shows `sandbox: workspace-write`, runs implementation, writes JSON artifact, exits 0.

- [ ] **Step 4: Validate CODEX output JSON**

```bash
pnpm dlx ajv-cli validate \
  -s .review/schemas/pr_draft.schema.json \
  -d .review/ISSUE-33-PR-DRAFT.json
```
Expected: `valid`.

- [ ] **Step 5: REVIEWER reads diff + writes checklist + review.json**

In REVIEWER pane, launch fresh `claude --model sonnet` session. Hand it:
- `git diff develop...HEAD` of the worktree
- `.review/ISSUE-33-PR-DRAFT.json`
- `docs/agents/workflow.md` (for checklist template)

REVIEWER produces `.review/ISSUE-33-REVIEW.json` with status `pass` or `fail`. Validate:

```bash
pnpm dlx ajv-cli validate \
  -s .review/schemas/review.schema.json \
  -d .review/ISSUE-33-REVIEW.json
```

- [ ] **Step 6: VERIFIER runs full verification**

In VERIFIER pane:

```bash
cd ../wt-33-httperror-detail-union
pnpm --filter backend run typecheck
pnpm --filter backend test errors
```
Expected: both green. The typecheck step is the PRIMARY guard for this type-only change — the `// @ts-expect-error` directives in the spec prove the union rejects bad shapes. Vitest run validates positive cases + preserves existing `statusForCode` coverage. If red → REVIEWER status `fail` → loop to ARCHITECT re-prompt.

- [ ] **Step 7: Release Captain (user) sign-off**

User reviews artifacts + diff. If approved:

```bash
cd ../wt-33-httperror-detail-union
gh pr create --base develop --head feature/33-httperror-detail-union \
  --title "fix(backend #33): HttpError.detail discriminated union typing (SEC2-4-6)" \
  --body-file .review/ISSUE-33-PR-DRAFT.json
```

(PR body initially JSON; ARCHITECT/Captain may render to MD prose if desired.)

- [ ] **Step 8: Friction log**

After PR merge (or abandonment), append observations to `docs/agents/workflow-trial-log.md`:
- What worked
- What broke (which CRIT guardrail caught it, which missed)
- HIGH/MED risks observed → candidates for v0.2 plan

- [ ] **Step 9: Final commit (close trial)**

If trial succeeded and PR merged:

```bash
git checkout develop
git pull
bash .githooks/post-merge   # verify no sibling-worktree warnings (none expected; only one cluster)
```

Trial complete. Capture lessons → v0.2 plan input.

---

## Self-Review Checklist

- [x] **Spec coverage:** All 5 CRIT guardrails covered — risk tier (T5), Release Captain (T5), sandbox (T2), partial stash (T2), post-merge rebase (T4). JSON schema infra (T1) for HIGH-7. Trial validates end-to-end (T6).
- [x] **Placeholder scan:** No TBD/TODO. All schemas have concrete fields. All test steps have exact commands.
- [x] **Type consistency:** Schema field names (`schema_version`, `lifecycle`, `producer_role`, `head_sha`) consistent across all 4 schemas. Script flags (`--issue`, `--prompt-file`, `--cwd`) consistent. `producer_role` is REQUIRED in all 4 schemas (was optional in v0 draft — codex review caught it).
- [x] **Out of scope acknowledged:** CONDUCTOR, parallel clusters, impeccable, Playwright smoke, full visual review — explicitly deferred to v0.2. Tightening `packages/shared/src/errors/codes.ts` ErrorEnvelope — separate follow-up issue, NOT in #33 trial.

## Round-2 Codex Review Fixes Applied

Per round-2 adversarial review (GO-WITH-FIXES):

1. **cmux-cluster.sh existing-worktree validation** — added explicit check that existing worktree contains `scripts/codex-safe.sh` + `.review/schemas/`, else fail with cleanup instructions. Prevents silent reuse of stale develop-based worktree.
2. **workflow-stash.sh hardening** — NUL-safe (`git ls-files -z`), file-count cap (`MAX_UNTRACKED=200`), byte cap (`MAX_UNTRACKED_BYTES=10MB`). Pathological recursive copies prevented.
3. **@ts-expect-error wording tightened** — explicit forbid list: `as any/never/unknown`, `// @ts-ignore`, any type assertion that bypasses union check. Directive must apply to unmodified value.
4. **Optional `producer_version` field** added to all 4 schemas — agent CLI version for debugging provenance. Forward-compat without loosening.
5. **Task 2 Step 5 expected text** — synced to actual script output (`stashed tracked diff` not `stashed partial diff`).

## Round-1 Codex Review Fixes Applied

Per adversarial review by codex (GO-WITH-FIXES verdict):

1. **T6 branch-base bug** — Worktree now branches from `feature/agent-workflow-trial` (via `TRIAL_BASE` env var added in T3 script), not `develop`. Without this fix the trial worktree could not see the workflow scripts/schemas committed in T1-T5.
2. **codex-safe trap** — Now conditional on non-zero exit; success path leaves artifacts intact. Was unconditionally stashing on every exit.
3. **workflow-stash untracked-file blindness** — Now also lists + copies untracked files into `.review/ISSUE-N-PARTIAL-UNTRACKED/`. Was only capturing tracked-file diff via `git diff HEAD`.
4. **T6 verification strength** — Acceptance now requires `// @ts-expect-error` compile-time negative tests for legacy `{ field: "..." }` shape + unknown shapes. Vitest alone cannot prove type rejection — tsc does.
5. **Test command** — Uses `pnpm --filter backend run typecheck` (vitest project's actual script) not bare `tsc --noEmit`.
6. **Schema strictness** — All 4 schemas now have `additionalProperties: false` at root + nested objects. `producer_role` moved to required.
7. **Scope clarification** — Trial scope explicitly excludes `packages/shared/src/errors/codes.ts`. Workflow escalation rule still active: if CODEX would need to touch shared, it must abort with blocker.

---

## Estimated Wall-Clock

- T1: 30 min (schemas + README)
- T2: 30 min (scripts + tests)
- T3: 20 min (cmux script + dry run)
- T4: 15 min (post-merge hook)
- T5: 20 min (docs + AGENTS.md patch)
- T6: 1-2h (actual trial — variable, friction-dependent)

**Total infra: ~2h. Trial: ~1-2h. Grand total: 3-4h for first end-to-end validation.**
