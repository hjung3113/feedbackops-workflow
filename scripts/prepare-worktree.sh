#!/usr/bin/env bash
# Host-side, idempotent worktree prep. A fresh git worktree has no node_modules
# and no gitignored .env, so it is NOT dispatch-ready. Because the codex sandbox
# blocks network, deps + env MUST be provisioned on the HOST before dispatch —
# never silently inside cluster spawn. This script does that, loudly.
#
# Usage:
#   scripts/prepare-worktree.sh <worktree-path> [--source-env <repo-root>]
#                                               [--allow-shared-env]
#                                               [--env-profile <path>]
#   scripts/prepare-worktree.sh --report-env-only <env-file>   (hidden test mode)
#
# Env is shared-state coupling (codex review R3): copying the same .env into
# multiple worktrees points them all at the same mutable DATABASE_URL /
# WORKSPACE_ID / storage bucket. With >1 prepared worktree, this script REFUSES
# to copy unless you pass --allow-shared-env (accept the risk) or
# --env-profile <path> (use a per-worktree env file).
set -euo pipefail

# --- high-risk env key classifier (keys only; values are NEVER printed) ---
# Returns 0 if KEY is high-risk. bash-3.2-compatible (no associative arrays).
is_high_risk_key() {
  key="$1"
  # Upcase before matching so lowercase/mixed-case keys (database_url, secret_key,
  # aws_s3_bucket) are caught too. bash-3.2-safe (no ${var,,}).
  ukey=$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')
  case "$ukey" in
    DATABASE_URL|WORKSPACE_ID|PORT) return 0 ;;
  esac
  case "$ukey" in
    *STORAGE*|*BUCKET*|*S3*) return 0 ;;
    *SECRET*|*TOKEN*|*KEY*|*PASSWORD*|*CREDENTIAL*) return 0 ;;
  esac
  return 1
}

# Print every env KEY in <file> (values REDACTED) and loudly flag high-risk keys.
report_env_keys() {
  file="$1"
  if [[ ! -f "$file" ]]; then
    echo "ERROR: env file not found: $file" >&2
    return 1
  fi
  echo "  env keys in $file (values redacted):"
  # Match only real assignment lines: ^KEY=...  (KEY = [A-Za-z_][A-Za-z0-9_]*)
  while IFS= read -r line; do
    case "$line" in
      [A-Za-z_]*=*) ;;          # candidate assignment
      *) continue ;;             # comments, blanks, exports-with-space, junk
    esac
    key="${line%%=*}"
    # Validate key charset strictly (reject e.g. "a comment=...").
    case "$key" in
      *[!A-Za-z0-9_]*) continue ;;
    esac
    if is_high_risk_key "$key"; then
      echo "  ⚠ high-risk env key copied: $key"
    else
      echo "    env key copied: $key"
    fi
  done < "$file"
}

# --- hidden test mode: just report keys for one file and exit ---
if [[ "${1:-}" == "--report-env-only" ]]; then
  report_env_keys "${2:?usage: --report-env-only <env-file>}"
  exit $?
fi

# --- arg parsing ---
WT_PATH=""
SOURCE_ENV=""
ALLOW_SHARED_ENV=0
ENV_PROFILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-env) SOURCE_ENV="$2"; shift 2 ;;
    --allow-shared-env) ALLOW_SHARED_ENV=1; shift ;;
    --env-profile) ENV_PROFILE="$2"; shift 2 ;;
    --*) echo "unknown arg: $1" >&2; exit 2 ;;
    *)
      if [[ -z "$WT_PATH" ]]; then WT_PATH="$1"; shift
      else echo "unexpected arg: $1" >&2; exit 2; fi
      ;;
  esac
done

[[ -z "$WT_PATH" ]] && { echo "usage: prepare-worktree.sh <worktree-path> [--source-env <repo-root>] [--allow-shared-env] [--env-profile <path>]" >&2; exit 2; }

# 1. Validate worktree exists and is a dir.
if [[ ! -d "$WT_PATH" ]]; then
  echo "ERROR: worktree path is not an existing directory: $WT_PATH" >&2
  exit 1
fi
WT_PATH="$(cd "$WT_PATH" && pwd)"   # normalize to absolute

# 2. --source-env defaults to repo toplevel.
if [[ -z "$SOURCE_ENV" ]]; then
  SOURCE_ENV="$(git rev-parse --show-toplevel)"
fi
if [[ ! -d "$SOURCE_ENV" ]]; then
  echo "ERROR: --source-env is not a directory: $SOURCE_ENV" >&2
  exit 1
fi
SOURCE_ENV="$(cd "$SOURCE_ENV" && pwd)"

echo "=== prepare-worktree: $WT_PATH ==="
echo "  source-env root: $SOURCE_ENV"

# 3. Env handling (codex review R3 — shared-state coupling).
# Count sibling prepared worktrees (have node_modules), excluding the main repo
# root and the target worktree itself.
MAIN_ROOT="$(cd "$SOURCE_ENV" && git rev-parse --show-toplevel 2>/dev/null || echo "$SOURCE_ENV")"
PREPARED_COUNT=0
while IFS= read -r line; do
  case "$line" in
    "worktree "*) ;;
    *) continue ;;
  esac
  wt="${line#worktree }"
  [[ "$wt" == "$MAIN_ROOT" ]] && continue
  [[ "$wt" == "$WT_PATH" ]] && continue
  if [[ -d "$wt/node_modules" ]]; then
    PREPARED_COUNT=$((PREPARED_COUNT + 1))
  fi
done < <(git -C "$SOURCE_ENV" worktree list --porcelain 2>/dev/null || true)

echo "  other prepared worktrees (have node_modules): $PREPARED_COUNT"

# Refuse shared env when >1 prepared worktree already exists and no override.
if [[ "$PREPARED_COUNT" -gt 1 && "$ALLOW_SHARED_ENV" -eq 0 && -z "$ENV_PROFILE" ]]; then
  echo "ERROR: refusing to copy env — $PREPARED_COUNT prepared worktrees already exist." >&2
  echo "       Copying the same .env into multiple worktrees points them ALL at the" >&2
  echo "       same mutable DATABASE_URL / WORKSPACE_ID / storage bucket — parallel" >&2
  echo "       clusters will corrupt each other's shared state." >&2
  echo "       Re-run with ONE of:" >&2
  echo "         --env-profile <path>   use a per-worktree env file (recommended)" >&2
  echo "         --allow-shared-env     explicitly accept the shared-state risk" >&2
  exit 1
fi

# Resolve which env files to copy.
# Default pair: <root>/.env and <root>/apps/backend/.env.
copy_env() {
  src="$1"; dst="$2"
  if [[ ! -f "$src" ]]; then
    echo "  (no env file at $src — skipping)"
    return 0
  fi
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
  echo "  copied env: $src -> $dst"
  report_env_keys "$dst"
}

if [[ -n "$ENV_PROFILE" ]]; then
  if [[ ! -f "$ENV_PROFILE" ]]; then
    echo "ERROR: --env-profile file not found: $ENV_PROFILE" >&2
    exit 1
  fi
  copy_env "$ENV_PROFILE" "$WT_PATH/.env"
else
  copy_env "$SOURCE_ENV/.env" "$WT_PATH/.env"
  copy_env "$SOURCE_ENV/apps/backend/.env" "$WT_PATH/apps/backend/.env"
fi

# 4. Deps — match the branch's committed lockfile.
if [[ -d "$WT_PATH/node_modules" ]]; then
  echo "  node_modules pre-existed — reconciling against frozen lockfile"
else
  echo "  node_modules absent — fresh install from frozen lockfile"
fi
( cd "$WT_PATH" && pnpm install --frozen-lockfile )

# 5. Done.
echo "=== prepare-worktree: DONE — $WT_PATH is dispatch-ready ==="
