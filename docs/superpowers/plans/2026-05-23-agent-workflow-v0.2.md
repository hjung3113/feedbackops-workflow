# Multi-Agent Workflow v0.2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden the cmux multi-agent dev workflow with trial-proven friction fixes, add a read-only CONDUCTOR orchestrator whose state is fully reconstructable from disk, and close the deferred stability + visual-review risks.

**Architecture:** Bash scripts + strict JSON artifacts (ajv-validated) + operating-playbook prose. v0.1 established `.review/` artifacts, `codex-safe.sh` sandbox wrapper, and a 4-pane cmux cluster. v0.2 adds: (1) a verification layer that cannot false-green, (2) explicit host-side worktree prep that preserves the sandbox boundary, (3) a tier blast-radius probe that errs toward *disallowing* Trivial, (4) a CONDUCTOR role + `PHASE-SUMMARY`/`HEARTBEAT` schemas where summaries are *derived artifacts, never source of truth*, and (5) artifact-expiry / archival / parallel-cluster / visual-review hardening.

**Tech Stack:** bash (3.2-compatible — macOS default), git worktrees, cmux CLI, `codex exec`, vitest (JSON reporter), ajv-cli (schema validation), pnpm workspaces, playwright MCP + `impeccable` plugin (visual review).

**Branch:** continue `feature/agent-workflow-trial`. Do NOT merge to develop. Do NOT push/PR without explicit user approval.

**Doc-sync rule (memory `feedback_doc_sync`):** every script/schema change updates `docs/agents/multi-agent-workflow.md` (+ this plan + `.review/README.md`) in the SAME commit. DEVIATIONS files alone are insufficient for contract changes.

---

## Design decisions locked from codex adversarial co-design (2026-05-23, workspace:21)

These are the sharpened decisions; tasks below implement them. Do not relitigate without re-running the co-design pane.

- **A1:** `verify.sh` must parse vitest **JSON output** and classify by explicit counters. Fail when `passed + failed == 0` (NOT merely `total == 0`) — a discovered-but-fully-skipped suite (missing `DATABASE_URL`) is a FAIL. Be filter-aware: an integration filter requires ≥1 *executable* test. Never scrape human reporter text — it differs across versions.
- **A2:** Worktree prep is an **explicit host-side command** (`scripts/prepare-worktree.sh`), loud + idempotent. NOT silent auto-prep inside `cmux-cluster.sh` — that hides the sandbox boundary. `cmux-cluster.sh` instead **refuses to launch** if a worktree lacks `node_modules`/`.env`. Install happens OUTSIDE the codex sandbox (network-blocked) before dispatch.
- **A3:** Verification is **baseline-aware**, not purely scoped. Capture the known pre-existing typecheck failure signature into `.review/typecheck-baseline.txt`; fail on any NEW error. "Pre-existing TS error" must never become permission to merge new compile errors.
- **A4:** The tier blast-radius probe answers **"is Trivial *disallowed*?"** — not "is this safe?". False positives are acceptable; false negatives are the harm. Trigger on exported-contract changes (exported type/interface/class/function signatures, constructor params, route schemas, DTOs, Zod schemas, barrel exports). Use `tsc` as the impact oracle; `rg` caller-grep is advisory fallback only.
- **A5:** Generic prose still leaks. Replace the blocker's free-prose `recommended_actions` template with an **enum + structured evidence**: `reason_code`, `blocking_fact`, `attempted_commands`, `needed_decision`. A schema that invites prose will be parroted.
- **B:** CONDUCTOR summaries are **derived artifacts, never source of truth**. Source of truth = per-worker artifact + full commit SHA + worktree path + verify command + exit code + timestamp + schema version. Every CONDUCTOR claim must be reconstructable from lower-level artifacts. Heartbeats prove **liveness, not correctness**. A worker "done" claim is invalid unless it cites a verify artifact whose `head_sha` equals the branch HEAD.

---

## Round-2 revisions (codex plan review 2026-05-23, workspace:21) — MANDATORY

Apply these deltas *within* the referenced tasks below. They override the original task text where they conflict. A fresh implementer MUST read this section before starting any task.

- **R1 → Task A1 (verify.sh classifier).** `passed+failed>0 && failed==0` is necessary but NOT sufficient. The classifier must ALSO fail on: `numFailedTestSuites > 0`, any `testResults[].status === "failed"`, a top-level `success === false`, and an unhandled-error/runtime-error array if present. It must NOT silently trust the JSON: fail closed on missing / empty / malformed report files (parse error → exit non-zero), and capture vitest's own exit code (pass it into the classifier; a non-zero vitest exit with a "clean" JSON is still a FAIL). Smoke-test cases to add: malformed JSON, missing report, `numFailedTestSuites:1` with `numFailedTests:0`, and a mixed `passed>0 + success:false`.
- **R2 → Task A4 (tier-probe).** Reframe the posture: the probe detects *obvious disqualifiers*; it must NEVER be the sole gate that *allows* Trivial. Rule: if a touched `.ts/.tsx` file contains ANY exported symbol and the diff is not provably comment/whitespace-only, default to **Trivial-disallowed** unless `verify.sh --typecheck` (the precise oracle) is also run and clean over importers. Broaden `CONTRACT_RE` to also flag: `export default`, `export ... from` re-exports, `as const`, enum member lines, generic constraint (`<... extends ...>`) changes, and method-signature lines inside an exported class. Multiline constructor params: treat any diff hunk touching a file that declares `constructor(` as suspect. Document that the grep is advisory and tsc is authoritative.
- **R3 → Task A2 (prepare-worktree env).** Do NOT copy `.env` by default for parallel use. `prepare-worktree.sh` must (a) print every env KEY it copies (values redacted) and loudly flag high-risk keys (`DATABASE_URL`, `WORKSPACE_ID`, storage/bucket, ports, external creds), and (b) require an explicit `--allow-shared-env` flag (or `--env-profile <name>` selecting a per-worktree env file) before copying when more than one prepared worktree exists. Single-cluster default may copy with a printed warning.
- **R4 → Task A3 (baseline capture).** MUST run FIRST, before any other v0.2 edit, on a CLEAN tree. Add a precondition step: `git status --porcelain` must be empty; record baseline metadata into `.review/typecheck-baseline.meta.json` (`command`, `branch`, `head_sha`, `captured_at`, `tree_clean:true`). Capture from the intended integration base, not a mid-work checkout. If the tree is dirty, ABORT with a message — never bless dirty-tree errors as pre-existing.
- **R5 → Task B2 (pr_draft.verify_result).** Make it conditionally required via JSON-Schema `if/then`: when `status == "ready_for_review"`, `verify_result` is REQUIRED and must satisfy `exit_code == 0`, `failed == 0`, `passed >= 1`. Do not leave enforcement to prose. Also add `worktree_path` and keep `branch` so per-artifact HEAD resolution (R6) is possible.
- **R6 → Task B3 (conductor-rebuild).** A single global HEAD arg is wrong across branches. Resolve each artifact's verified-state against ITS OWN branch HEAD: read `worktree_path` from the artifact and run `git -C "$worktree_path" rev-parse HEAD`; mark `verified` only if that equals `verify_result.verified_head_sha` (and failed==0, passed>0, not superseded). If `worktree_path` is absent, state is `unknown`, never `verified`. The `<branch-head-sha>` positional becomes an optional fallback only.
- **R7 → Task B1 (phase_summary provenance).** Enrich `derived_from[]` so staleness is machine-detectable: add per-source `content_sha256`, `generated_at`, `lifecycle`, and `base_fresh` (bool, result of `artifact-fresh.sh`). Add top-level `branch`/`worktree_path` to each `chunks[]` entry. A summary whose `derived_from[].content_sha256` no longer matches the on-disk artifact is STALE and must be regenerated.
- **R8 → Task C1 (artifact-fresh base branch).** Do not default to `develop`. Each artifact MUST carry `base_branch` (add to pr_draft + blocker + touch schemas as required when used in multi-branch flow). `artifact-fresh.sh` reads `base_branch` from the artifact and compares `base_sha` to `git merge-base HEAD <base_branch>`. The CLI `<integration-branch>` arg is an override only; absent a declared base_branch AND no override, FAIL (do not silently assume develop).
- **R9 → Task C3 (auto-rebase).** Downgrade for v0.2: ship as an EXPLICIT command `scripts/rebase-inflight.sh` (not hook auto-act). Define: `<affected>` = the touched packages from each sibling's latest pr_draft `files_touched`; sibling discovery via `git worktree list --porcelain`; REFUSE any worktree with a dirty tree (`git status --porcelain` non-empty) — never rebase over uncommitted work; guard against concurrent runs with a lockfile in `.review/`. The `post-merge` hook stays warn-only and additionally prints "run scripts/rebase-inflight.sh".
- **R10 → Task D1 (impeccable enable).** Split durable from fragile. COMMIT: `docs/agents/visual-reviewer-persona.md` + the playwright interaction-script requirement (repo-verifiable, machine-independent). Do NOT commit a project `.claude/settings.json` plugin-enable that breaks teammates lacking the plugin — instead document the project-level enable as an OPTIONAL local step in the persona doc (and, if enabling, prefer `.claude/settings.local.json` which is gitignored). Confirm the exact `name@marketplace` ref at enable time; the persona works with playwright alone if impeccable is absent.

---

## File Structure

**New scripts**
- `scripts/verify.sh` — env-loading, baseline-aware, false-green-proof verification. Used by VERIFIER.
- `scripts/prepare-worktree.sh` — explicit host-side worktree prep (deps + env), idempotent, loud.
- `scripts/tier-probe.sh` — pre-dispatch "is Trivial disallowed?" probe over a touch set.
- `scripts/review-archive.sh` — move merged `.review/ISSUE-N-*.json` to `.review/archive/YYYY-MM/`.
- `scripts/conductor-rebuild.sh` — reconstruct CONDUCTOR state index from `.review/*.json` on disk.

**New schemas (`.review/schemas/`)**
- `phase_summary.schema.json` — CONDUCTOR per-phase summary (derived; carries provenance back-pointers).
- `heartbeat.schema.json` — per-pane liveness record.

**Modified**
- `.review/schemas/blocker.schema.json` — add `reason_code` enum + `blocking_fact` + `attempted_commands` + `needed_decision`; deprecate prose-only `recommended_actions`.
- `.review/schemas/pr_draft.schema.json` — add `verify_result` block (counts + exit code) so "done" is evidence-backed.
- `scripts/cmux-cluster.sh` — refuse launch on unprepared worktree; add CONDUCTOR-independence note; spawn nothing auto-prep.
- `.githooks/post-merge` — upgrade from warn-only to optional auto-rebase + affected-test run (opt-in via env flag).
- `docs/agents/multi-agent-workflow.md` — CONDUCTOR role, tier-probe rule, verify protocol, prep protocol, artifact-expiry/archival, visual-review trigger.
- `.review/README.md` — new artifact types + expiry-by-base_sha rule.
- `AGENTS.md` — pointer updates if any new mandatory protocol.

**New docs**
- `docs/agents/conductor-persona.md` — CONDUCTOR operating prompt (like the playbook).
- `docs/agents/visual-reviewer-persona.md` — VISUAL-REVIEWER operating prompt (impeccable + playwright).

**Test fixtures (`.review/schemas/fixtures/`)** — valid + invalid JSON per schema, for ajv round-trip tests.

---

## Verification approach for this plan

This subsystem is bash + JSON, not a JS app. "Tests" mean:
- **Schema tasks:** write a *valid* fixture and an *invalid* fixture; assert ajv passes the valid and rejects the invalid.
- **Script tasks:** a shell smoke test in a throwaway temp git repo (`mktemp -d`), asserting exit code + key stdout/artifact. Use `set -e` guards; print `PASS`/`FAIL`.
- **Doc tasks:** grep the doc for the required new section heading after writing.

ajv is run via `pnpm dlx ajv-cli` (already the README convention). All scripts must be bash-3.2-compatible (no `declare -A`, no `${var,,}`).

---

# PRIORITY A — trial-proven friction fixes (do FIRST)

### Task A1: `scripts/verify.sh` — false-green-proof verification

**Files:**
- Create: `scripts/verify.sh`
- Test: inline shell smoke test (temp dir)

- [ ] **Step 1: Write the failing smoke test**

Create `scripts/__tests__/verify.smoke.sh` (temporary; delete after if you prefer, but committing it is fine):

```bash
#!/usr/bin/env bash
# Smoke test: verify.sh must FAIL when a suite is discovered but fully skipped.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Fake a vitest JSON report with all tests skipped (numPassedTests=0, numFailedTests=0, numPendingTests=31)
cat > "$TMP/report.json" <<'JSON'
{ "numTotalTests": 31, "numPassedTests": 0, "numFailedTests": 0, "numPendingTests": 31, "numTotalTestSuites": 1 }
JSON

# verify.sh exposes a pure classifier we can call directly:
set +e
"$ROOT/scripts/verify.sh" --classify-json "$TMP/report.json"
RC=$?
set -e
if [[ $RC -ne 0 ]]; then echo "PASS: all-skipped classified as FAIL"; else echo "FAIL: all-skipped passed"; exit 1; fi

# And a real-green report passes:
cat > "$TMP/green.json" <<'JSON'
{ "numTotalTests": 31, "numPassedTests": 31, "numFailedTests": 0, "numPendingTests": 0, "numTotalTestSuites": 1 }
JSON
set +e; "$ROOT/scripts/verify.sh" --classify-json "$TMP/green.json"; RC=$?; set -e
if [[ $RC -eq 0 ]]; then echo "PASS: green classified as pass"; else echo "FAIL: green rejected"; exit 1; fi
```

- [ ] **Step 2: Run it, expect failure (script not yet present)**

Run: `bash scripts/__tests__/verify.smoke.sh`
Expected: FAIL — `verify.sh: No such file or directory`.

- [ ] **Step 3: Write `scripts/verify.sh`**

```bash
#!/usr/bin/env bash
# VERIFIER protocol entry point. Loads env, runs a scoped vitest filter via the
# JSON reporter, and classifies by explicit counters so a fully-skipped suite
# (missing DATABASE_URL/WORKSPACE_ID) is a FAIL, not a silent false-green.
#
# Usage:
#   scripts/verify.sh <vitest-filter>        # e.g. create-voc  (runs backend filter)
#   scripts/verify.sh --classify-json <file> # pure classifier (for tests)
#
# Exit: 0 = real green (>=1 executable test, 0 failures). Non-zero otherwise.
set -uo pipefail

classify() {
  # Reads a vitest JSON report path; returns 0 only if passed+failed > 0 AND failed == 0.
  local f="$1"
  [[ -f "$f" ]] || { echo "verify: report not found: $f" >&2; return 3; }
  # Parse counters with node (always available in this repo) — robust across vitest versions.
  node -e '
    const r = require(process.argv[1]);
    const passed = r.numPassedTests ?? 0;
    const failed = r.numFailedTests ?? 0;
    const pending = r.numPendingTests ?? 0;
    const executable = passed + failed;
    if (executable === 0) { console.error(`verify: FAIL — 0 executable tests (pending=${pending}). Suite discovered but skipped? Check env (DATABASE_URL/WORKSPACE_ID).`); process.exit(1); }
    if (failed > 0) { console.error(`verify: FAIL — ${failed} failing test(s).`); process.exit(2); }
    console.log(`verify: PASS — ${passed} passed, ${pending} pending, 0 failed.`);
  ' "$f"
}

if [[ "${1:-}" == "--classify-json" ]]; then
  classify "${2:?need report path}"
  exit $?
fi

FILTER="${1:?usage: verify.sh <vitest-filter>}"
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# Load env so integration suites don't silently skip. Both root and backend envs.
for envf in .env apps/backend/.env; do
  if [[ -f "$envf" ]]; then set -a; . "./$envf"; set +a; fi
done

REPORT="$(mktemp)"
trap 'rm -f "$REPORT"' EXIT

# Run scoped filter with JSON reporter to a file. Do not fail-fast on non-zero;
# we classify from the JSON, which is the authoritative signal.
set +e
pnpm --filter backend exec vitest run "$FILTER" --reporter=json --outputFile="$REPORT" >/dev/null 2>&1
set -e

classify "$REPORT"
```

- [ ] **Step 4: Run the smoke test, expect PASS**

Run: `bash scripts/__tests__/verify.smoke.sh`
Expected: `PASS: all-skipped classified as FAIL` then `PASS: green classified as pass`.

- [ ] **Step 5: chmod + doc-sync + commit**

Update `docs/agents/multi-agent-workflow.md` — add a "VERIFIER protocol" section: *VERIFIER MUST run `scripts/verify.sh <filter>`; it loads env and treats a fully-skipped suite as FAIL. A bare `pnpm test` is forbidden as a green signal.*

```bash
chmod +x scripts/verify.sh scripts/__tests__/verify.smoke.sh
git add scripts/verify.sh scripts/__tests__/verify.smoke.sh docs/agents/multi-agent-workflow.md
git commit -m "feat(workflow): verify.sh — env-load + false-green-proof vitest classifier"
```

---

### Task A2: `scripts/prepare-worktree.sh` + cmux-cluster refuse-to-launch guard

**Files:**
- Create: `scripts/prepare-worktree.sh`
- Modify: `scripts/cmux-cluster.sh` (add pre-launch readiness check)

- [ ] **Step 1: Write `scripts/prepare-worktree.sh`**

```bash
#!/usr/bin/env bash
# Host-side worktree prep — runs OUTSIDE the codex sandbox (which is network-blocked).
# Idempotent + loud. Installs deps and copies gitignored env into a fresh worktree.
#
# Usage: scripts/prepare-worktree.sh <worktree-path> [--source-env <repo-root>]
set -euo pipefail

WT="${1:?usage: prepare-worktree.sh <worktree-path> [--source-env <repo-root>]}"
shift || true
SRC_ROOT="$(git rev-parse --show-toplevel)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-env) SRC_ROOT="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -d "$WT" ]] || { echo "ERROR: worktree not found: $WT" >&2; exit 1; }

echo "=== prepare-worktree: $WT ==="
echo "    source repo (for env): $SRC_ROOT"

# 1. Copy gitignored env files (idempotent — overwrite to keep in sync with source).
for envf in .env apps/backend/.env; do
  if [[ -f "$SRC_ROOT/$envf" ]]; then
    mkdir -p "$WT/$(dirname "$envf")"
    cp "$SRC_ROOT/$envf" "$WT/$envf"
    echo "    copied $envf"
  else
    echo "    (no $envf in source — skipped)"
  fi
done

# 2. Install deps inside the worktree (network available on host, not in sandbox).
#    Use frozen lockfile so the worktree matches the branch's committed lock state.
if [[ -d "$WT/node_modules" ]]; then
  echo "    node_modules present — running install to reconcile (frozen lockfile)"
else
  echo "    node_modules absent — installing (frozen lockfile)"
fi
( cd "$WT" && pnpm install --frozen-lockfile )

echo "=== prepare-worktree: DONE — $WT is dispatch-ready ==="
```

- [ ] **Step 2: Add the refuse-to-launch guard to `cmux-cluster.sh`**

In `scripts/cmux-cluster.sh`, AFTER the worktree exists block (after line ~31, before "Spawn cmux workspace" at line 33), insert:

```bash
# Refuse to launch a cluster on an unprepared worktree. Prep is an explicit
# host-side step (scripts/prepare-worktree.sh) — never silent auto-prep, so the
# sandbox boundary stays visible. (codex sandbox is network-blocked; deps MUST
# already be present before dispatch.)
MISSING=()
[[ -d "$WT_PATH/node_modules" ]] || MISSING+=("node_modules")
[[ -f "$WT_PATH/.env" ]] || MISSING+=(".env")
if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "ERROR: worktree $WT_PATH is not dispatch-ready (missing: ${MISSING[*]})." >&2
  echo "       Run host-side prep first (outside the codex sandbox):" >&2
  echo "         scripts/prepare-worktree.sh $WT_PATH" >&2
  exit 1
fi
```

- [ ] **Step 3: Smoke test the guard**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
T=$(mktemp -d); ( cd "$T" && git init -q && git commit -q --allow-empty -m init )
# cmux-cluster needs cmux; we only test the guard path by sourcing the readiness logic.
# Manual check: confirm the new block exits 1 when node_modules/.env absent.
grep -q "not dispatch-ready" scripts/cmux-cluster.sh && echo "PASS: guard present" || { echo "FAIL"; exit 1; }
```
Expected: `PASS: guard present`.

- [ ] **Step 4: Doc-sync + commit**

Update `docs/agents/multi-agent-workflow.md` — add "Worktree Prep" section: *Fresh worktrees are NOT dispatch-ready. Run `scripts/prepare-worktree.sh <wt>` on the host (outside sandbox) to install deps + copy env. `cmux-cluster.sh` refuses to launch otherwise. Beware: `.env` is copied from the source repo — confirm it does not point multiple worktrees at the same mutable DB if running parallel clusters (see Task C4).*

```bash
chmod +x scripts/prepare-worktree.sh
git add scripts/prepare-worktree.sh scripts/cmux-cluster.sh docs/agents/multi-agent-workflow.md
git commit -m "feat(workflow): explicit host-side prepare-worktree.sh + cluster refuse-to-launch guard"
```

---

### Task A3: baseline-aware typecheck in `verify.sh`

**Files:**
- Modify: `scripts/verify.sh` (add `--typecheck` mode)
- Create: `.review/typecheck-baseline.txt` (captured known-failures snapshot)

- [ ] **Step 1: Capture the current baseline**

Run and save the known pre-existing failures (e.g. `src/cli/storage-bootstrap.ts(54,31) TS2559`):
```bash
cd "$(git rev-parse --show-toplevel)"
pnpm --filter backend run typecheck 2>&1 | grep -E "error TS[0-9]+" | sort -u > .review/typecheck-baseline.txt || true
cat .review/typecheck-baseline.txt
```

- [ ] **Step 2: Write the failing smoke test**

Append to `scripts/__tests__/verify.smoke.sh`:
```bash
# --- typecheck baseline diff ---
BASE="$TMP/baseline.txt"; CUR="$TMP/current.txt"
printf '%s\n' "a.ts(1,1): error TS1 known" > "$BASE"
printf '%s\n' "a.ts(1,1): error TS1 known" "b.ts(2,2): error TS2 NEW" > "$CUR"
set +e; "$ROOT/scripts/verify.sh" --typecheck-diff "$BASE" "$CUR"; RC=$?; set -e
if [[ $RC -ne 0 ]]; then echo "PASS: new error detected"; else echo "FAIL: new error missed"; exit 1; fi
# No new errors -> pass
set +e; "$ROOT/scripts/verify.sh" --typecheck-diff "$BASE" "$BASE"; RC=$?; set -e
if [[ $RC -eq 0 ]]; then echo "PASS: baseline-only passes"; else echo "FAIL"; exit 1; fi
```

- [ ] **Step 3: Run, expect failure**

Run: `bash scripts/__tests__/verify.smoke.sh`
Expected: FAIL on the new `--typecheck-diff` arg (unknown mode).

- [ ] **Step 4: Add `--typecheck-diff` + `--typecheck` to `verify.sh`**

Insert into `verify.sh` before the `FILTER=` handling:
```bash
if [[ "${1:-}" == "--typecheck-diff" ]]; then
  BASE="${2:?baseline}"; CUR="${3:?current}"
  # Any error line in CUR not present in BASE is a NEW error -> FAIL.
  NEW=$(comm -13 <(sort -u "$BASE") <(sort -u "$CUR"))
  if [[ -n "$NEW" ]]; then echo "verify: FAIL — new typecheck error(s):" >&2; echo "$NEW" >&2; exit 1; fi
  echo "verify: PASS — no new typecheck errors vs baseline."; exit 0
fi

if [[ "${1:-}" == "--typecheck" ]]; then
  REPO_ROOT="$(git rev-parse --show-toplevel)"; cd "$REPO_ROOT"
  BASE=".review/typecheck-baseline.txt"; [[ -f "$BASE" ]] || : > "$BASE"
  CUR="$(mktemp)"; trap 'rm -f "$CUR"' EXIT
  pnpm --filter backend run typecheck 2>&1 | grep -E "error TS[0-9]+" | sort -u > "$CUR" || true
  exec "$0" --typecheck-diff "$BASE" "$CUR"
fi
```

- [ ] **Step 5: Run smoke test, expect PASS; doc-sync; commit**

Run: `bash scripts/__tests__/verify.smoke.sh` → all `PASS`.

Update `docs/agents/multi-agent-workflow.md` VERIFIER section: *Typecheck is baseline-aware. VERIFIER runs `scripts/verify.sh --typecheck`; it fails ONLY on errors absent from `.review/typecheck-baseline.txt`. A pre-existing error is never permission to merge a NEW compile error. Refresh the baseline (and note it in the commit) only when a pre-existing error is independently fixed.*

```bash
git add scripts/verify.sh scripts/__tests__/verify.smoke.sh .review/typecheck-baseline.txt docs/agents/multi-agent-workflow.md
git commit -m "feat(workflow): baseline-aware typecheck — fail on new errors only"
```

---

### Task A4: `scripts/tier-probe.sh` — "is Trivial disallowed?" probe

**Files:**
- Create: `scripts/tier-probe.sh`

- [ ] **Step 1: Write the failing smoke test**

Create `scripts/__tests__/tier-probe.smoke.sh`:
```bash
#!/usr/bin/env bash
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cd "$TMP" && git init -q

# Case 1: a file changing an exported type signature -> Trivial DISALLOWED (exit 1)
mkdir -p src
cat > src/types.ts <<'TS'
export interface HttpErrorDetail { code: string }
TS
git add -A && git commit -q -m base
cat > src/types.ts <<'TS'
export interface HttpErrorDetail { code: string; severity: "low" | "high" }
TS
set +e; "$ROOT/scripts/tier-probe.sh" src/types.ts; RC=$?; set -e
if [[ $RC -eq 1 ]]; then echo "PASS: exported-contract change disallows Trivial"; else echo "FAIL (rc=$RC)"; exit 1; fi

# Case 2: a comment-only change to a non-exported file -> Trivial ALLOWED (exit 0)
echo "// note" >> src/types.ts  # still touches exported file -> still flagged; use a fresh non-exported file
cat > src/internal.ts <<'TS'
const x = 1; // internal
TS
git add -A && git commit -q -m c2
echo "// just a comment" >> src/internal.ts
set +e; "$ROOT/scripts/tier-probe.sh" src/internal.ts; RC=$?; set -e
if [[ $RC -eq 0 ]]; then echo "PASS: internal comment change allows Trivial"; else echo "FAIL (rc=$RC)"; exit 1; fi
```

- [ ] **Step 2: Run, expect failure (script absent)**

Run: `bash scripts/__tests__/tier-probe.smoke.sh`
Expected: FAIL — script not found.

- [ ] **Step 3: Write `scripts/tier-probe.sh`**

```bash
#!/usr/bin/env bash
# Pre-dispatch tier probe. Answers ONE question: is the Trivial tier DISALLOWED
# for this touch set? Errs toward disallowing (false positives OK; false
# negatives are the harm). Exit 1 = Trivial disallowed (escalate). Exit 0 = ok.
#
# Heuristic (advisory grep oracle): if any touched file's git diff adds/removes
# an EXPORTED contract — exported type/interface/class/function signature,
# constructor params, route/zod schema, or a barrel re-export — disallow Trivial.
# For a precise oracle, follow with `scripts/verify.sh --typecheck`.
set -uo pipefail

[[ $# -ge 1 ]] || { echo "usage: tier-probe.sh <file> [<file>...]" >&2; exit 2; }

DISALLOW=0
REASONS=()

# Patterns that indicate an exported contract surface in an added/removed diff line.
CONTRACT_RE='^[+-].*\b(export\s+(interface|type|class|abstract\s+class|enum|function|const\s+\w+\s*=\s*z\.)|constructor\s*\(|export\s+\{|export\s+\*)'

for f in "$@"; do
  case "$f" in
    *.ts|*.tsx) ;;
    *) continue ;;  # non-TS files cannot change a TS contract
  esac
  # Diff vs HEAD (committed change) — covers the staged/committed touch set.
  DIFF=$(git diff HEAD -- "$f" 2>/dev/null; git diff --cached -- "$f" 2>/dev/null)
  [[ -z "$DIFF" ]] && DIFF=$(git show HEAD -- "$f" 2>/dev/null)
  if echo "$DIFF" | grep -Eq "$CONTRACT_RE"; then
    DISALLOW=1
    REASONS+=("$f: exported-contract change")
  fi
  # Barrel files are contract surfaces by nature.
  case "$f" in */index.ts|*/index.tsx) DISALLOW=1; REASONS+=("$f: barrel/index export surface") ;; esac
done

if [[ $DISALLOW -eq 1 ]]; then
  echo "TIER-PROBE: Trivial DISALLOWED — exported contract change detected:" >&2
  for r in "${REASONS[@]}"; do echo "  - $r" >&2; done
  echo "  Action: assign Standard/Full Cluster; run scripts/verify.sh --typecheck for precise blast radius." >&2
  exit 1
fi
echo "TIER-PROBE: no exported-contract change in touch set — Trivial permissible (still verify importers)."
exit 0
```

- [ ] **Step 4: Run smoke test, expect PASS**

Run: `bash scripts/__tests__/tier-probe.smoke.sh`
Expected: `PASS: exported-contract change disallows Trivial` and `PASS: internal comment change allows Trivial`.

- [ ] **Step 5: chmod + doc-sync + commit**

Update `docs/agents/multi-agent-workflow.md` "Risk Tier Routing": add a **Pre-dispatch tier probe** subsection — *Before assigning Trivial, run `scripts/tier-probe.sh <touched-files>`. If it exits non-zero (exported-contract change), Trivial is forbidden — escalate. The probe answers "is Trivial disallowed?", not "is this safe?"; false positives are acceptable. `tsc` (`verify.sh --typecheck`) is the precise oracle; the grep probe is the cheap advisory gate. (Trial 1 / #33: a single-file type narrowing broke 5 modules — file count is not tier.)*

```bash
chmod +x scripts/tier-probe.sh scripts/__tests__/tier-probe.smoke.sh
git add scripts/tier-probe.sh scripts/__tests__/tier-probe.smoke.sh docs/agents/multi-agent-workflow.md
git commit -m "feat(workflow): tier-probe.sh — disallow Trivial on exported-contract changes"
```

---

### Task A5: structured blocker schema (kill prompt-template leakage)

**Files:**
- Modify: `.review/schemas/blocker.schema.json`
- Create: `.review/schemas/fixtures/blocker.valid.json`, `.review/schemas/fixtures/blocker.invalid.json`

- [ ] **Step 1: Write the new schema**

Replace `.review/schemas/blocker.schema.json` with (adds `reason_code` enum + structured evidence; `recommended_actions` kept optional, no longer the leak vector):

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "Blocker Artifact",
  "type": "object",
  "additionalProperties": false,
  "required": ["schema_version", "artifact_type", "lifecycle", "producer_role", "issue", "reason_code", "blocking_fact", "attempted_commands", "needed_decision"],
  "properties": {
    "schema_version": { "const": "1" },
    "artifact_type": { "const": "blocker" },
    "lifecycle": { "enum": ["active", "superseded", "final"] },
    "producer_role": { "const": "CODEX" },
    "producer_version": { "type": "string" },
    "issue": {
      "type": "object",
      "additionalProperties": false,
      "required": ["number", "title"],
      "properties": {
        "number": { "type": "integer" },
        "title": { "type": "string" }
      }
    },
    "reason_code": {
      "enum": ["scope_violation", "missing_dependency", "ambiguous_requirement", "failing_precondition", "sandbox_limitation", "tier_escalation_required"],
      "description": "Pick the closest cause. Do NOT free-write the cause as prose elsewhere."
    },
    "blocking_fact": {
      "type": "string",
      "description": "The CONCRETE observed fact, naming ACTUAL files/symbols hit (e.g. 'tightening HttpError.detail broke src/voc/*.ts, src/permissions/*.ts'). Never copy phrasing from the dispatch prompt."
    },
    "attempted_commands": {
      "type": "array",
      "minItems": 1,
      "items": { "type": "string" },
      "description": "Exact commands run before aborting (e.g. 'pnpm --filter backend run typecheck')."
    },
    "needed_decision": {
      "type": "string",
      "description": "The specific human/ARCHITECT decision required to unblock."
    },
    "files_touched_before_abort": { "type": "array", "items": { "type": "string" } },
    "partial_diff_path": { "type": "string" },
    "recommended_actions": { "type": "array", "items": { "type": "string" } }
  }
}
```

- [ ] **Step 2: Write valid + invalid fixtures**

`.review/schemas/fixtures/blocker.valid.json`:
```json
{
  "schema_version": "1",
  "artifact_type": "blocker",
  "lifecycle": "active",
  "producer_role": "CODEX",
  "issue": { "number": 33, "title": "Tighten HttpError.detail to DetailShape union" },
  "reason_code": "tier_escalation_required",
  "blocking_fact": "Narrowing HttpError.detail from Record<string,unknown> to DetailShape broke call sites in src/analytics-areas/*.ts, src/attachments/*.ts, src/managed-systems/*.ts, src/permissions/*.ts, src/voc/*.ts.",
  "attempted_commands": ["pnpm --filter backend run typecheck"],
  "needed_decision": "Re-tier #33 to Full Cluster and plan a module-by-module migration, OR introduce DetailShape as an optional alias first."
}
```

`.review/schemas/fixtures/blocker.invalid.json` (missing `reason_code` + `blocking_fact`; should be rejected):
```json
{
  "schema_version": "1",
  "artifact_type": "blocker",
  "lifecycle": "active",
  "producer_role": "CODEX",
  "issue": { "number": 33, "title": "x" },
  "recommended_actions": ["escalate to Full Cluster tier (touches packages/shared)"]
}
```

- [ ] **Step 3: Validate both with ajv**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
pnpm dlx ajv-cli validate -s .review/schemas/blocker.schema.json -d .review/schemas/fixtures/blocker.valid.json
echo "valid-rc=$?"
pnpm dlx ajv-cli validate -s .review/schemas/blocker.schema.json -d .review/schemas/fixtures/blocker.invalid.json; echo "invalid-rc=$?"
```
Expected: valid passes (rc 0); invalid fails (rc non-zero, ajv prints missing-required errors).

- [ ] **Step 4: Update the dispatch prompt template + escalation rule (doc-sync)**

In `docs/agents/multi-agent-workflow.md` "Escalation rule": replace the canned-reason instruction. New text: *On abort, CODEX writes a blocker artifact. Set `reason_code` from the enum and put the ACTUAL out-of-scope files/symbols you hit into `blocking_fact` — never copy the dispatch prompt's example phrasing. (Trial 1: CODEX parroted "touches packages/shared" though the real cause was backend modules.)* Also update `.review/README.md` blocker description.

```bash
git add .review/schemas/blocker.schema.json .review/schemas/fixtures/blocker.valid.json .review/schemas/fixtures/blocker.invalid.json docs/agents/multi-agent-workflow.md .review/README.md
git commit -m "feat(workflow): structured blocker schema (reason_code+evidence) to kill prompt-template leakage"
```

---

# PRIORITY B — CONDUCTOR (headline feature)

### Task B1: `phase_summary` + `heartbeat` schemas (derived-not-truth provenance)

**Files:**
- Create: `.review/schemas/phase_summary.schema.json`, `.review/schemas/heartbeat.schema.json`
- Create: fixtures for each (valid + invalid)

- [ ] **Step 1: Write `phase_summary.schema.json`**

Every claim carries a back-pointer to the lower-level artifact + SHA it derives from, so the summary is provably reconstructable and never trusted as source of truth.

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "Phase Summary Artifact",
  "type": "object",
  "additionalProperties": false,
  "required": ["schema_version", "artifact_type", "lifecycle", "producer_role", "phase", "generated_at", "derived_from", "chunks"],
  "properties": {
    "schema_version": { "const": "1" },
    "artifact_type": { "const": "phase_summary" },
    "lifecycle": { "enum": ["active", "superseded", "final"] },
    "producer_role": { "const": "CONDUCTOR" },
    "phase": { "type": "integer" },
    "generated_at": { "type": "string", "format": "date-time" },
    "derived_from": {
      "type": "array",
      "minItems": 1,
      "description": "Every lower-level artifact this summary was reconstructed from. The summary is a CACHE of these — never authority.",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["artifact_path", "head_sha"],
        "properties": {
          "artifact_path": { "type": "string" },
          "head_sha": { "type": "string", "pattern": "^[0-9a-f]{40}$" }
        }
      }
    },
    "chunks": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["issue", "state", "evidence_artifact", "evidence_head_sha"],
        "properties": {
          "issue": { "type": "integer" },
          "state": { "enum": ["dispatched", "in_progress", "blocked", "verified", "merged"] },
          "evidence_artifact": { "type": "string", "description": "Path to the pr_draft/blocker/review/verify artifact backing this state." },
          "evidence_head_sha": { "type": "string", "pattern": "^[0-9a-f]{40}$", "description": "MUST equal the branch HEAD for a 'verified' claim to be valid." },
          "note": { "type": "string" }
        }
      }
    }
  }
}
```

- [ ] **Step 2: Write `heartbeat.schema.json`**

Heartbeats prove liveness, NOT correctness — schema enforces both a freshness timestamp and a pointer to the last verify evidence.

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "Pane Heartbeat Artifact",
  "type": "object",
  "additionalProperties": false,
  "required": ["schema_version", "artifact_type", "pane", "branch", "head_sha", "task", "blocked", "dirty", "updated_at"],
  "properties": {
    "schema_version": { "const": "1" },
    "artifact_type": { "const": "heartbeat" },
    "pane": { "type": "string", "description": "cmux surface ref, e.g. surface:75" },
    "branch": { "type": "string" },
    "head_sha": { "type": "string", "pattern": "^[0-9a-f]{40}$" },
    "task": { "type": "string", "description": "current issue/task the pane is on" },
    "blocked": { "type": "boolean" },
    "dirty": { "type": "boolean", "description": "uncommitted changes present" },
    "updated_at": { "type": "string", "format": "date-time" },
    "last_verify_at": { "type": "string", "format": "date-time" },
    "last_verify_artifact": { "type": "string" }
  }
}
```

- [ ] **Step 3: Fixtures + ajv validation**

Create valid + invalid fixtures for both (mirror Task A5 structure: invalid omits a required field). Validate:
```bash
cd "$(git rev-parse --show-toplevel)"
for s in phase_summary heartbeat; do
  pnpm dlx ajv-cli validate --all-errors -c ajv-formats -s .review/schemas/$s.schema.json -d .review/schemas/fixtures/$s.valid.json; echo "$s valid-rc=$?"
  pnpm dlx ajv-cli validate --all-errors -c ajv-formats -s .review/schemas/$s.schema.json -d .review/schemas/fixtures/$s.invalid.json; echo "$s invalid-rc=$?"
done
```
Expected: valids pass, invalids fail. (Note: `format: date-time` requires `ajv-formats`; if `-c ajv-formats` is unavailable, drop the `format` keyword and validate the string as plain — document the choice in README.)

- [ ] **Step 4: Doc-sync + commit**

Update `.review/README.md`: add `phase_summary` and `heartbeat` artifact types; state the **derived-not-truth rule** verbatim: *PHASE-SUMMARY is a cache of lower-level artifacts. Readers MUST treat `derived_from` as authority; a `chunks[].state == "verified"` claim is INVALID unless `evidence_head_sha` equals the branch HEAD.*

```bash
git add .review/schemas/phase_summary.schema.json .review/schemas/heartbeat.schema.json .review/schemas/fixtures/phase_summary.* .review/schemas/fixtures/heartbeat.* .review/README.md
git commit -m "feat(workflow): phase_summary + heartbeat schemas with derived-not-truth provenance"
```

---

### Task B2: `verify_result` evidence block on pr_draft (done = evidence-backed)

**Files:**
- Modify: `.review/schemas/pr_draft.schema.json`
- Update: fixtures

- [ ] **Step 1: Add `verify_result` to pr_draft schema**

Add this property (and DO NOT make it required yet — Trivial-tier may write it post-verify; but the CONDUCTOR ignores any "ready_for_review" lacking it). Insert into `properties`:
```json
    "verify_result": {
      "type": "object",
      "additionalProperties": false,
      "required": ["verified_head_sha", "passed", "failed", "exit_code"],
      "properties": {
        "verified_head_sha": { "type": "string", "pattern": "^[0-9a-f]{40}$" },
        "passed": { "type": "integer", "minimum": 0 },
        "failed": { "type": "integer", "minimum": 0 },
        "pending": { "type": "integer", "minimum": 0 },
        "exit_code": { "type": "integer" }
      }
    },
```

- [ ] **Step 2: Validate updated fixtures with ajv**

Create `.review/schemas/fixtures/pr_draft.valid.json` carrying a `verify_result` with `passed:31, failed:0, exit_code:0` and `verified_head_sha` = a 40-char hex. Validate it passes; create an invalid one (`verified_head_sha` short) and confirm it fails.

- [ ] **Step 3: Doc-sync + commit**

`docs/agents/multi-agent-workflow.md` Release Captain section: *A pr_draft with `status:"ready_for_review"` but no `verify_result` (or whose `verified_head_sha` ≠ branch HEAD) is NOT done — CONDUCTOR/Captain treats it as `in_progress`.*

```bash
git add .review/schemas/pr_draft.schema.json .review/schemas/fixtures/pr_draft.* docs/agents/multi-agent-workflow.md
git commit -m "feat(workflow): pr_draft.verify_result — 'done' must be evidence-backed at current HEAD"
```

---

### Task B3: `scripts/conductor-rebuild.sh` — reconstruct state from disk

**Files:**
- Create: `scripts/conductor-rebuild.sh`

- [ ] **Step 1: Write the failing smoke test**

`scripts/__tests__/conductor-rebuild.smoke.sh`: seed a temp `.review/` with two `ISSUE-N-PR-DRAFT.json` (one with valid `verify_result` at a SHA, one without), run the script, assert it lists chunk states and flags the unverified one as `in_progress`.

```bash
#!/usr/bin/env bash
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.review"
SHA=$(printf '%040d' 1)
cat > "$TMP/.review/ISSUE-31-PR-DRAFT.json" <<JSON
{"schema_version":"1","artifact_type":"pr_draft","lifecycle":"active","producer_role":"CODEX","issue":{"number":31,"title":"x"},"branch":"feature/31","base_sha":"$SHA","head_sha":"$SHA","files_touched":[{"path":"a","change":"edit"}],"verify_cmd":"x","status":"ready_for_review","verify_result":{"verified_head_sha":"$SHA","passed":31,"failed":0,"exit_code":0}}
JSON
cat > "$TMP/.review/ISSUE-32-PR-DRAFT.json" <<JSON
{"schema_version":"1","artifact_type":"pr_draft","lifecycle":"active","producer_role":"CODEX","issue":{"number":32,"title":"y"},"branch":"feature/32","base_sha":"$SHA","head_sha":"$SHA","files_touched":[{"path":"b","change":"edit"}],"verify_cmd":"x","status":"ready_for_review"}
JSON
OUT=$("$ROOT/scripts/conductor-rebuild.sh" "$TMP/.review" "$SHA")
echo "$OUT" | grep -q "31.*verified" && echo "PASS: verified chunk recognized" || { echo "FAIL"; exit 1; }
echo "$OUT" | grep -q "32.*in_progress" && echo "PASS: unverified chunk downgraded" || { echo "FAIL"; exit 1; }
```

- [ ] **Step 2: Run, expect failure (script absent)**

Run: `bash scripts/__tests__/conductor-rebuild.smoke.sh` → FAIL.

- [ ] **Step 3: Write `scripts/conductor-rebuild.sh`**

```bash
#!/usr/bin/env bash
# Reconstruct CONDUCTOR chunk-state index purely from .review/*.json on disk.
# CONDUCTOR holds NO in-memory-only state; a rotated/rebuilt session calls this.
# A 'ready_for_review' pr_draft counts as 'verified' ONLY if verify_result exists
# AND verified_head_sha == the current branch HEAD passed as arg 2.
#
# Usage: scripts/conductor-rebuild.sh <review-dir> <branch-head-sha>
set -uo pipefail
DIR="${1:?usage: conductor-rebuild.sh <review-dir> <branch-head-sha>}"
HEAD_SHA="${2:?need branch head sha}"

shopt -s nullglob 2>/dev/null || true
for f in "$DIR"/ISSUE-*-PR-DRAFT.json "$DIR"/ISSUE-*-BLOCKER.json; do
  [[ -f "$f" ]] || continue
  node -e '
    const fs=require("fs");
    const head=process.argv[2];
    const a=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
    if (a.lifecycle==="superseded") process.exit(0);  // readers ignore superseded
    const n=a.issue&&a.issue.number;
    if (a.artifact_type==="blocker") { console.log(`${n}\tblocked\t${a.reason_code||"?"}`); process.exit(0); }
    const vr=a.verify_result;
    let state="in_progress";
    if (a.status==="ready_for_review" && vr && vr.verified_head_sha===head && vr.failed===0 && (vr.passed||0)>0) state="verified";
    console.log(`${n}\t${state}\t${a.branch||""}`);
  ' "$f" "$HEAD_SHA"
done
```

- [ ] **Step 4: Run smoke test, expect PASS**

Run: `bash scripts/__tests__/conductor-rebuild.smoke.sh` → both `PASS`.

- [ ] **Step 5: chmod + commit**

```bash
chmod +x scripts/conductor-rebuild.sh scripts/__tests__/conductor-rebuild.smoke.sh
git add scripts/conductor-rebuild.sh scripts/__tests__/conductor-rebuild.smoke.sh
git commit -m "feat(workflow): conductor-rebuild.sh — reconstruct chunk state from disk, downgrade unverified"
```

---

### Task B4: CONDUCTOR persona/operating prompt

**Files:**
- Create: `docs/agents/conductor-persona.md`
- Modify: `docs/agents/multi-agent-workflow.md` (add CONDUCTOR to roles)

- [ ] **Step 1: Write `docs/agents/conductor-persona.md`**

Write the operating prompt covering, at minimum (full prose, no placeholders):
  - **Role:** Claude Opus, dedicated pane OUTSIDE all clusters (decided 2026-05-23). Oversees all in-flight clusters.
  - **Hard rule — READ-ONLY on product code.** CONDUCTOR never edits source. It reads `.review/*.json` + dispatches. Any edit is role bleed and a defect.
  - **State source of truth:** disk only. CONDUCTOR reads worker state EXCLUSIVELY from `.review/*.json` via `scripts/conductor-rebuild.sh` — never infers from prose, never from pane scrollback. Summaries (`PHASE-SUMMARY-N.json`) are a CACHE; on any material event the summary is regenerated, and every claim cites `derived_from` + `evidence_head_sha`.
  - **Recovery:** CONDUCTOR is reconstructable. Session may rotate every N days / N clusters; rebuild via `conductor-rebuild.sh`. No in-memory-only state.
  - **Liveness vs correctness:** reads `HEARTBEAT.json` for liveness; a fresh heartbeat does NOT mean progress is correct — correctness comes only from a verify artifact at current HEAD. Stale heartbeat (> threshold) → alert, do not assume progress.
  - **Decisions it owns:** serial vs parallel, task split, role/model/persona assignment, tier (via `tier-probe.sh`).
  - **ARCHITECT autonomy list** (avoid over-centralized bottleneck): enumerate decisions ARCHITECT may make WITHOUT CONDUCTOR (e.g. within-module refactors, test additions, doc fixes) so CONDUCTOR is not a serial chokepoint.
  - **Failure modes to self-guard:** stale summaries (regenerate every material event), over-centralization (honor ARCHITECT autonomy), hallucinated worker state (read only from JSON), role bleed (read-only enforcement).

- [ ] **Step 2: Add CONDUCTOR to the playbook roles + Release Captain default**

Update `docs/agents/multi-agent-workflow.md`: add CONDUCTOR as the 5th role; update Release Captain "Default Captain" to note CONDUCTOR (v0.2) with the read-only + evidence-backed-merge constraints.

- [ ] **Step 3: Grep-verify the doc has the required sections; commit**

Run: `grep -E "READ-ONLY|derived_from|conductor-rebuild" docs/agents/conductor-persona.md`
Expected: matches present.

```bash
git add docs/agents/conductor-persona.md docs/agents/multi-agent-workflow.md
git commit -m "docs(workflow): CONDUCTOR persona — read-only, disk-truth, reconstructable"
```

---

# PRIORITY C — remaining HIGH/MED risks

### Task C1: artifact expiry by `base_sha` (readers reject stale)

**Files:**
- Create: `scripts/artifact-fresh.sh`
- Modify: `.review/README.md`

- [ ] **Step 1: Smoke test** — `scripts/__tests__/artifact-fresh.smoke.sh`: an artifact whose `base_sha` ≠ the branch's actual merge-base with develop must be reported STALE (exit non-zero).

- [ ] **Step 2: Write `scripts/artifact-fresh.sh`**

```bash
#!/usr/bin/env bash
# Exit 0 if the artifact's base_sha matches the branch's current merge-base with
# the integration branch; non-zero (STALE) otherwise. Readers MUST treat stale
# artifacts as invalid, not merely log them.
# Usage: scripts/artifact-fresh.sh <artifact.json> [<integration-branch=develop>]
set -uo pipefail
ART="${1:?usage: artifact-fresh.sh <artifact.json> [integration-branch]}"
INT="${2:-develop}"
BASE=$(node -e 'const a=require(process.argv[1]); process.stdout.write(a.base_sha||"")' "$ART")
[[ -n "$BASE" ]] || { echo "artifact-fresh: no base_sha in $ART" >&2; exit 2; }
MB=$(git merge-base HEAD "$INT" 2>/dev/null || echo "")
if [[ "$BASE" != "$MB" ]]; then
  echo "artifact-fresh: STALE — $ART base_sha=$BASE but merge-base($INT)=$MB" >&2
  exit 1
fi
echo "artifact-fresh: OK — $ART is current."
```

- [ ] **Step 3: Run smoke test, expect PASS. Doc-sync README (expiry rule). Commit.**

```bash
chmod +x scripts/artifact-fresh.sh scripts/__tests__/artifact-fresh.smoke.sh
git add scripts/artifact-fresh.sh scripts/__tests__/artifact-fresh.smoke.sh .review/README.md
git commit -m "feat(workflow): artifact-fresh.sh — readers reject artifacts whose base_sha drifted"
```

### Task C2: `scripts/review-archive.sh` + lifecycle enforcement

**Files:**
- Create: `scripts/review-archive.sh`

- [ ] **Step 1: Smoke test** — seed `.review/ISSUE-9-*.json`, run `review-archive.sh 9`, assert files moved to `.review/archive/YYYY-MM/` and originals gone.

- [ ] **Step 2: Write the script**

```bash
#!/usr/bin/env bash
# On PR merge, archive an issue's .review artifacts to .review/archive/YYYY-MM/.
# Usage: scripts/review-archive.sh <issue-number>
set -euo pipefail
N="${1:?usage: review-archive.sh <issue-number>}"
ROOT="$(git rev-parse --show-toplevel)"
DEST="$ROOT/.review/archive/$(date +%Y-%m)"
mkdir -p "$DEST"
shopt -s nullglob
MOVED=0
for f in "$ROOT"/.review/ISSUE-"$N"-*; do
  [[ -e "$f" ]] || continue
  mv "$f" "$DEST/"; MOVED=$((MOVED+1))
done
echo "review-archive: moved $MOVED artifact(s) for issue #$N to $DEST"
```

- [ ] **Step 3: Run smoke test, expect PASS; commit**

```bash
chmod +x scripts/review-archive.sh scripts/__tests__/review-archive.smoke.sh
git add scripts/review-archive.sh scripts/__tests__/review-archive.smoke.sh
git commit -m "feat(workflow): review-archive.sh — move merged issue artifacts to archive/YYYY-MM"
```

### Task C3: post-merge auto-rebase (warn → opt-in act)

**Files:**
- Modify: `.githooks/post-merge`

- [ ] **Step 1:** Add an opt-in `WORKFLOW_AUTOREBASE=1` env gate. When set, instead of only printing the suggestion, the hook runs `(cd "$WT" && git fetch -q && git rebase develop && scripts/verify.sh <affected>)` per sibling, capturing failures and STILL warning (never hard-fails the merge). When unset, behavior is unchanged (warn only). Keep bash-3.2-compatible. Rebase conflicts must abort the rebase (`git rebase --abort`) and warn loudly — never leave a worktree mid-rebase.

- [ ] **Step 2: Smoke test** the gate: with `WORKFLOW_AUTOREBASE` unset, output contains "suggest:"; the act-path is documented as manually verified (cmux/worktree side effects make it hard to unit test — note this explicitly).

- [ ] **Step 3: Doc-sync + commit**

```bash
git add .githooks/post-merge docs/agents/multi-agent-workflow.md
git commit -m "feat(workflow): post-merge opt-in auto-rebase (WORKFLOW_AUTOREBASE), conflict-safe"
```

### Task C4: parallel cluster dry-run (2 independent P3s)

**Files:**
- Create: `docs/agents/workflow-trial-log.md` entry (Trial 3)

- [ ] **Step 1:** Pick 2 genuinely-independent P3 issues (no shared files/contracts). Confirm independence by running `tier-probe.sh` on each declared touch set AND checking the two touch sets don't intersect.
- [ ] **Step 2:** Prep BOTH worktrees with `prepare-worktree.sh` — and confirm the `.env` copies do NOT point both at the same mutable DB (codex's A2 warning). If they do, give each a distinct `WORKSPACE_ID`/schema. Document the resolution.
- [ ] **Step 3:** Run both clusters; ARCHITECT serializes any shared-contract overlap (there should be none by construction). VERIFIER uses `verify.sh` in each.
- [ ] **Step 4:** Write Trial 3 to `docs/agents/workflow-trial-log.md`: what worked, what friction (esp. DB isolation, install locks), and whether parallel is safe to recommend. Commit.

---

# PRIORITY D — visual review

### Task D1: enable `impeccable` at project level + VISUAL-REVIEWER persona

**Files:**
- Modify: `.claude/settings.json` (project-level plugin enable)
- Create: `docs/agents/visual-reviewer-persona.md`

> **Correction to handoff:** `impeccable` is NOT a browser visual-diff tool. It is a plugin (v3.1.1) providing 1 skill + 23 commands (`/impeccable polish|audit|critique|…`) — a design-vocabulary + anti-pattern critique skill that reads code/markup. No browser automation. Live interaction/screenshots come from the **playwright MCP** (already available). Plugin enable is global per `enabledPlugins`; there is NO per-subagent toggle — enable at PROJECT level here and restrict USAGE to the VISUAL-REVIEWER role via persona discipline.

- [ ] **Step 1:** Add to project `.claude/settings.json` `enabledPlugins`: `"impeccable@impeccable": true`. (Confirm marketplace ref name with `cat ~/.claude/plugins/config.json` — use the exact `name@marketplace` form.)
- [ ] **Step 2:** Write `docs/agents/visual-reviewer-persona.md`:
  - **Trigger:** layout / copy-placement / interaction-states / design-tokens / shells / reusable-UI changes. SKIP pure API-hook wiring.
  - **Two tools, two jobs:** `/impeccable critique|audit` for design-quality/anti-pattern judgment on the markup; **playwright MCP** for live interaction script (navigate, screenshot, assert states).
  - **Hard rule:** a visual pass ALONE cannot close a chunk. It MUST pair with an interaction script covering create / edit / error / empty / permission states. REVIEWER = checklist + smoke; VERIFIER owns durable Playwright specs.
- [ ] **Step 3:** Doc-sync `multi-agent-workflow.md` (VISUAL row in tier table already references VISUAL; expand trigger + the "cannot close alone" rule). Commit.

```bash
git add .claude/settings.json docs/agents/visual-reviewer-persona.md docs/agents/multi-agent-workflow.md
git commit -m "feat(workflow): enable impeccable (project-level) + VISUAL-REVIEWER persona"
```

---

## Self-Review checklist (run before handing to execution)

- **Spec coverage:** A1–A5 (5 friction findings 1,3,4,5,6,7 + tier) ✓; B1–B4 (CONDUCTOR + schemas + rebuild + persona) ✓; C1–C4 (expiry, archival, auto-rebase, parallel) ✓; D1 (impeccable + visual persona) ✓. Friction #2 (sandbox network) addressed via A2 host-side prep. Friction #8 (trial branch base) is a noted artifact, no task needed.
- **Open threads carried:** `feature/31-idem-audit-assertion` cherry-pick, AGENTS.md dangling `workflow.md` refs, `docs/wiki/` untracked — all remain user-decisions, flagged in handoff; NOT in v0.2 scope.
- **Type consistency:** schema field names reused consistently (`head_sha`, `base_sha`, `verified_head_sha`, `reason_code`, `evidence_head_sha`). `verify.sh` modes: `--classify-json`, `--typecheck`, `--typecheck-diff`, `<filter>`.
- **bash-3.2:** no `declare -A`, no `${var,,}` used in any script.

## Execution note

Per handoff METHOD: execute via **superpowers:subagent-driven-development** — fresh implementer subagent per task + spec review + code-quality review; the human is Release Captain. Keep the codex co-design pane (workspace:21) alive for adversarial review of any task that deviates. Do NOT merge to develop or push without explicit user approval.
