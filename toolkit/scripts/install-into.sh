#!/usr/bin/env bash
# Wire a target repo to this workflow toolkit without copying by default.
#
# Usage:
#   scripts/install-into.sh <target-repo-path> [--mode symlink|copy] [--migrate-legacy|--force]
set -euo pipefail

usage() {
  echo "usage: install-into.sh <target-repo-path> [--mode symlink|copy] [--migrate-legacy|--force]" >&2
}

TARGET_REPO=""
MODE="symlink"
FORCE=0
MIGRATE_LEGACY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      [[ $# -lt 2 ]] && { echo "missing value for --mode" >&2; usage; exit 2; }
      MODE="$2"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --migrate-legacy)
      MIGRATE_LEGACY=1
      shift
      ;;
    -*)
      echo "unknown arg: $1" >&2
      usage
      exit 2
      ;;
    *)
      if [[ -n "$TARGET_REPO" ]]; then
        echo "unexpected arg: $1" >&2
        usage
        exit 2
      fi
      TARGET_REPO="$1"
      shift
      ;;
  esac
done

[[ -z "$TARGET_REPO" ]] && { echo "missing <target-repo-path>" >&2; usage; exit 2; }
[[ "$MODE" != "symlink" && "$MODE" != "copy" ]] && { echo "invalid --mode: $MODE" >&2; usage; exit 2; }
if [[ "$FORCE" -eq 1 && "$MIGRATE_LEGACY" -eq 1 ]]; then
  echo "install-into: --migrate-legacy cannot be combined with --force" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PRODUCT_HOME_LIB="$SCRIPT_DIR/lib/product-home.sh"
if [[ ! -r "$PRODUCT_HOME_LIB" ]]; then
  echo "product-home resolver is missing: $PRODUCT_HOME_LIB" >&2
  exit 2
fi
. "$PRODUCT_HOME_LIB"
PRODUCT_ROOT="$(agent_workflow_product_root "$SCRIPT_DIR")"
REPOSITORY_ROOT=""
repository_candidate="$(git -C "$PRODUCT_ROOT" rev-parse --show-toplevel 2>/dev/null)" && \
  REPOSITORY_ROOT="$(cd "$repository_candidate" && pwd -P)"

if [[ ! -d "$TARGET_REPO" ]]; then
  echo "target does not exist or is not a directory: $TARGET_REPO" >&2
  exit 2
fi

TARGET_ROOT="$(cd "$TARGET_REPO" && pwd -P)"

if [[ "$TARGET_ROOT" == "$PRODUCT_ROOT" ]] || \
   [[ -n "$REPOSITORY_ROOT" && "$TARGET_ROOT" == "$REPOSITORY_ROOT" ]]; then
  echo "refusing to install into the toolkit source itself: $TARGET_ROOT" >&2
  exit 2
fi

if ! git -C "$TARGET_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "warning: target is not a git repo: $TARGET_ROOT" >&2
fi

AGENT_DIR="$TARGET_ROOT/.agent-workflow"
REVIEW_DIR="$TARGET_ROOT/.review"
CLAUDE_SKILLS_DIR="$TARGET_ROOT/.claude/skills"
SCRIPTS_SRC="$PRODUCT_ROOT/scripts"
SCHEMAS_SRC="$(agent_workflow_schema_dir "$PRODUCT_ROOT")" || {
  echo "product schemas are missing beneath: $PRODUCT_ROOT" >&2
  exit 2
}
DOCS_SRC="$PRODUCT_ROOT/docs/agents"
SKILL_SRC="$PRODUCT_ROOT/.claude/skills/agent-workflow"
SCRIPTS_DEST="$AGENT_DIR/scripts"
SCHEMAS_DEST="$AGENT_DIR/schemas"
DOCS_DEST="$AGENT_DIR/docs/agents"
SKILL_DEST="$CLAUDE_SKILLS_DIR/agent-workflow"

reject_symlinked_managed_parent() {
  local managed_parent=""
  for managed_parent in \
    "$AGENT_DIR" \
    "$AGENT_DIR/docs" \
    "$TARGET_ROOT/.claude" \
    "$CLAUDE_SKILLS_DIR" \
    "$REVIEW_DIR"; do
    if [[ -L "$managed_parent" ]]; then
      echo "install-into: managed parent must not be a symlink: $managed_parent" >&2
      echo "No changes made. Replace it with a real directory inside the target before installing." >&2
      exit 2
    fi
  done
}

require_source_dir() {
  local source_dir="$1"
  if [[ ! -d "$source_dir" ]]; then
    echo "required product directory is missing: $source_dir" >&2
    exit 2
  fi
}

require_source_dir "$SCRIPTS_SRC"
require_source_dir "$SCHEMAS_SRC"
require_source_dir "$DOCS_SRC"
require_source_dir "$SKILL_SRC"
reject_symlinked_managed_parent

# release-contract: legacy-link-detection-begin
legacy_root_for() {
  local raw_target="$1"
  local legacy_suffix="$2"
  local inferred_root=""

  case "$raw_target" in
    "$legacy_suffix")
      printf '/\n'
      ;;
    /*"$legacy_suffix")
      inferred_root="${raw_target%"$legacy_suffix"}"
      [[ -n "$inferred_root" ]] || return 1
      printf '%s\n' "$inferred_root"
      ;;
    *) return 1 ;;
  esac
}

SCRIPTS_LINK=""
SCHEMAS_LINK=""
DOCS_LINK=""
SKILL_LINK=""
SCRIPTS_LEGACY_ROOT=""
SCHEMAS_LEGACY_ROOT=""
SCHEMAS_CURRENT_ROOT=""
DOCS_LEGACY_ROOT=""
SKILL_LEGACY_ROOT=""

if [[ -L "$SCRIPTS_DEST" ]]; then
  SCRIPTS_LINK="$(readlink "$SCRIPTS_DEST")"
  SCRIPTS_LEGACY_ROOT="$(legacy_root_for "$SCRIPTS_LINK" "/scripts")" || SCRIPTS_LEGACY_ROOT=""
fi
if [[ -L "$SCHEMAS_DEST" ]]; then
  SCHEMAS_LINK="$(readlink "$SCHEMAS_DEST")"
  SCHEMAS_LEGACY_ROOT="$(legacy_root_for "$SCHEMAS_LINK" "/.review/schemas")" || SCHEMAS_LEGACY_ROOT=""
  if [[ -z "$SCHEMAS_LEGACY_ROOT" ]]; then
    SCHEMAS_CURRENT_ROOT="$(legacy_root_for "$SCHEMAS_LINK" "/schemas")" || SCHEMAS_CURRENT_ROOT=""
  fi
fi
if [[ -L "$DOCS_DEST" ]]; then
  DOCS_LINK="$(readlink "$DOCS_DEST")"
  DOCS_LEGACY_ROOT="$(legacy_root_for "$DOCS_LINK" "/docs/agents")" || DOCS_LEGACY_ROOT=""
fi
if [[ -L "$SKILL_DEST" ]]; then
  SKILL_LINK="$(readlink "$SKILL_DEST")"
  SKILL_LEGACY_ROOT="$(legacy_root_for "$SKILL_LINK" "/.claude/skills/agent-workflow")" || SKILL_LEGACY_ROOT=""
fi
# release-contract: legacy-link-detection-end

LEGACY_SCRIPTS=0
LEGACY_SCHEMAS=0
LEGACY_DOCS=0
LEGACY_SKILL=0
LEGACY_COUNT=0

if [[ -n "$SCRIPTS_LEGACY_ROOT" && "$SCRIPTS_LINK" != "$SCRIPTS_SRC" ]]; then
  LEGACY_SCRIPTS=1
fi
if [[ -n "$SCHEMAS_LEGACY_ROOT" && "$SCHEMAS_LINK" != "$SCHEMAS_SRC" ]]; then
  LEGACY_SCHEMAS=1
elif [[ -n "$SCHEMAS_CURRENT_ROOT" && "$SCHEMAS_LINK" != "$SCHEMAS_SRC" ]]; then
  if [[ "$SCHEMAS_CURRENT_ROOT" == "$SCRIPTS_LEGACY_ROOT" || \
        "$SCHEMAS_CURRENT_ROOT" == "$DOCS_LEGACY_ROOT" || \
        "$SCHEMAS_CURRENT_ROOT" == "$SKILL_LEGACY_ROOT" ]]; then
    LEGACY_SCHEMAS=1
  fi
fi
if [[ -n "$DOCS_LEGACY_ROOT" && "$DOCS_LINK" != "$DOCS_SRC" ]]; then
  LEGACY_DOCS=1
fi
if [[ -n "$SKILL_LEGACY_ROOT" && "$SKILL_LINK" != "$SKILL_SRC" ]]; then
  LEGACY_SKILL=1
fi
LEGACY_COUNT=$((LEGACY_SCRIPTS + LEGACY_SCHEMAS + LEGACY_DOCS + LEGACY_SKILL))

print_legacy_link() {
  local recognized="$1"
  local dest="$2"
  local raw_target="$3"
  if [[ "$recognized" -eq 1 ]]; then
    echo "  $dest -> $raw_target" >&2
  fi
}

if [[ "$LEGACY_COUNT" -gt 0 && "$MIGRATE_LEGACY" -eq 0 ]]; then
  echo "install-into: legacy absolute-symlink installation detected; no changes made." >&2
  print_legacy_link "$LEGACY_SCRIPTS" "$SCRIPTS_DEST" "$SCRIPTS_LINK"
  print_legacy_link "$LEGACY_SCHEMAS" "$SCHEMAS_DEST" "$SCHEMAS_LINK"
  print_legacy_link "$LEGACY_DOCS" "$DOCS_DEST" "$DOCS_LINK"
  print_legacy_link "$LEGACY_SKILL" "$SKILL_DEST" "$SKILL_LINK"
  echo "Migrate only the recognized legacy links with:" >&2
  printf '  %q %q --mode %q --migrate-legacy\n' "$0" "$TARGET_ROOT" "$MODE" >&2
  echo "Existing files, directories, copy installs, and unrecognized symlinks will be preserved." >&2
  exit 2
fi

if [[ "$MIGRATE_LEGACY" -eq 1 && "$LEGACY_COUNT" -eq 0 ]]; then
  echo "install-into: --migrate-legacy found no recognized legacy absolute symlinks; no changes made." >&2
  echo "Existing files, directories, copy installs, and unrecognized symlinks require no migration." >&2
  exit 2
fi

mkdir -p "$AGENT_DIR"
mkdir -p "$AGENT_DIR/docs"
mkdir -p "$REVIEW_DIR"
mkdir -p "$CLAUDE_SKILLS_DIR"

SCRIPTS_ABSENT=0
SCHEMAS_ABSENT=0
DOCS_ABSENT=0
SKILL_ABSENT=0
[[ ! -e "$SCRIPTS_DEST" && ! -L "$SCRIPTS_DEST" ]] && SCRIPTS_ABSENT=1
[[ ! -e "$SCHEMAS_DEST" && ! -L "$SCHEMAS_DEST" ]] && SCHEMAS_ABSENT=1
[[ ! -e "$DOCS_DEST" && ! -L "$DOCS_DEST" ]] && DOCS_ABSENT=1
[[ ! -e "$SKILL_DEST" && ! -L "$SKILL_DEST" ]] && SKILL_ABSENT=1

remove_legacy_link() {
  local recognized="$1"
  local dest="$2"
  local raw_target="$3"
  if [[ "$recognized" -eq 1 ]]; then
    rm "$dest" || return $?
    echo "removed legacy link: $dest -> $raw_target"
  fi
}

install_link() {
  src="$1"
  dest="$2"

  if [[ -e "$dest" || -L "$dest" ]]; then
    if [[ "$FORCE" -eq 1 ]]; then
      rm -rf "$dest"
    else
      echo "skip existing: $dest"
      return 0
    fi
  fi

  ln -s "$src" "$dest" || return $?
  echo "linked: $dest -> $src"
}

install_copy() {
  src="$1"
  dest="$2"

  if [[ -e "$dest" || -L "$dest" ]]; then
    if [[ "$FORCE" -eq 1 ]]; then
      rm -rf "$dest"
    else
      echo "skip existing: $dest"
      return 0
    fi
  fi

  cp -R "$src" "$dest" || return $?
  echo "copied: $dest"
}

perform_install() {
  if [[ "$MODE" == "symlink" ]]; then
    install_link "$SCRIPTS_SRC" "$SCRIPTS_DEST" || return $?
    install_link "$SCHEMAS_SRC" "$SCHEMAS_DEST" || return $?
    install_link "$DOCS_SRC" "$DOCS_DEST" || return $?
    install_link "$SKILL_SRC" "$SKILL_DEST" || return $?
  else
    install_copy "$SCRIPTS_SRC" "$SCRIPTS_DEST" || return $?
    install_copy "$SCHEMAS_SRC" "$SCHEMAS_DEST" || return $?
    install_copy "$DOCS_SRC" "$DOCS_DEST" || return $?
    install_copy "$SKILL_SRC" "$SKILL_DEST" || return $?
  fi
}

restore_destination() {
  local recognized="$1"
  local initially_absent="$2"
  local dest="$3"
  local raw_target="$4"

  if [[ "$recognized" -eq 1 ]]; then
    rm -rf "$dest"
    ln -s "$raw_target" "$dest"
  elif [[ "$initially_absent" -eq 1 ]]; then
    rm -rf "$dest"
  fi
}

rollback_migration() {
  echo "install-into: migration failed; restoring the previous installation." >&2
  restore_destination "$LEGACY_SCRIPTS" "$SCRIPTS_ABSENT" "$SCRIPTS_DEST" "$SCRIPTS_LINK"
  restore_destination "$LEGACY_SCHEMAS" "$SCHEMAS_ABSENT" "$SCHEMAS_DEST" "$SCHEMAS_LINK"
  restore_destination "$LEGACY_DOCS" "$DOCS_ABSENT" "$DOCS_DEST" "$DOCS_LINK"
  restore_destination "$LEGACY_SKILL" "$SKILL_ABSENT" "$SKILL_DEST" "$SKILL_LINK"
}

if [[ "$MIGRATE_LEGACY" -eq 1 ]]; then
  set +e
  remove_legacy_link "$LEGACY_SCRIPTS" "$SCRIPTS_DEST" "$SCRIPTS_LINK" && \
    remove_legacy_link "$LEGACY_SCHEMAS" "$SCHEMAS_DEST" "$SCHEMAS_LINK" && \
    remove_legacy_link "$LEGACY_DOCS" "$DOCS_DEST" "$DOCS_LINK" && \
    remove_legacy_link "$LEGACY_SKILL" "$SKILL_DEST" "$SKILL_LINK" && \
    perform_install
  migration_status=$?
  set -e
  if [[ "$migration_status" -ne 0 ]]; then
    rollback_migration
    exit "$migration_status"
  fi
else
  perform_install
fi

if [[ "$MODE" == "copy" ]]; then
  ENV_NEXT_STEP="Copy .env.example from the distributable toolkit package before sharing this snapshot."
else
  ENV_NEXT_STEP="Copy toolkit env defaults into the target when needed: $PRODUCT_ROOT/.env.example"
fi

cat <<EOF

Next steps:
  - Invoke the project skill: /agent-workflow
  - Read the playbook:        $TARGET_ROOT/.agent-workflow/docs/agents/multi-agent-workflow.md
  - Dispatch through:         $TARGET_ROOT/.agent-workflow/scripts/cmux-dispatch.sh
  - Verify target fit before using the bundled backend/Vitest verify.sh adapter.
  - $ENV_NEXT_STEP
EOF
