#!/usr/bin/env bash
# Install or upgrade a portable, self-contained workflow toolkit copy.
# Bash 3.2 compatible.
set -euo pipefail

usage() {
  echo "usage: install-into.sh <target-repo-path> [--upgrade]" >&2
}

TARGET_REPO=""
UPGRADE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --upgrade)
      UPGRADE=1
      shift
      ;;
    --mode)
      [[ $# -lt 2 ]] && { echo "missing value for --mode" >&2; usage; exit 2; }
      echo "install-into: --mode $2 was removed; installs are always portable copies." >&2
      echo "Use: $0 <target-repo-path> [--upgrade]" >&2
      exit 2
      ;;
    --force|--migrate-legacy)
      echo "install-into: $1 was replaced by --upgrade." >&2
      echo "Use: $0 <target-repo-path> --upgrade" >&2
      exit 2
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

[[ -n "$TARGET_REPO" ]] || { echo "missing <target-repo-path>" >&2; usage; exit 2; }

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
CLAUDE_DIR="$TARGET_ROOT/.claude"
CLAUDE_SKILLS_DIR="$CLAUDE_DIR/skills"
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

require_source_tree() {
  local source_dir="$1"
  if [[ ! -d "$source_dir" ]]; then
    echo "required product directory is missing: $source_dir" >&2
    exit 2
  fi
  if find "$source_dir" -type l -print -quit | grep -q .; then
    echo "product directory contains a symlink and is not portable: $source_dir" >&2
    exit 2
  fi
}

reject_symlinked_managed_parent() {
  local managed_parent=""
  for managed_parent in \
    "$AGENT_DIR" \
    "$AGENT_DIR/docs" \
    "$CLAUDE_DIR" \
    "$CLAUDE_SKILLS_DIR" \
    "$REVIEW_DIR" \
    "$REVIEW_DIR/agent-workflow-install-backups"; do
    if [[ -L "$managed_parent" ]]; then
      echo "install-into: managed parent must not be a symlink: $managed_parent" >&2
      echo "No changes made. Replace it with a real directory inside the target." >&2
      exit 2
    fi
  done
}

require_source_tree "$SCRIPTS_SRC"
require_source_tree "$SCHEMAS_SRC"
require_source_tree "$DOCS_SRC"
require_source_tree "$SKILL_SRC"
reject_symlinked_managed_parent

exists_node() {
  [[ -e "$1" || -L "$1" ]]
}

# release-contract: legacy-link-detection-begin
managed_link_root() {
  local dest="$1"
  local kind="$2"
  local raw_target=""
  local legacy_schema_parent=""
  [[ -L "$dest" ]] || return 1
  raw_target="$(readlink "$dest")"
  case "$raw_target" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$kind:$raw_target" in
    scripts:*'/scripts') printf '%s\n' "${raw_target%/scripts}" ;;
    schemas:*'/.review/schemas')
      legacy_schema_parent="${raw_target%/schemas}"
      printf '%s\n' "${legacy_schema_parent%/.review}"
      ;;
    schemas:*'/schemas') printf '%s\n' "${raw_target%/schemas}" ;;
    docs:*'/docs/agents') printf '%s\n' "${raw_target%/docs/agents}" ;;
    skill:*'/.claude/skills/agent-workflow') printf '%s\n' "${raw_target%/.claude/skills/agent-workflow}" ;;
    *) return 1 ;;
  esac
}
# release-contract: legacy-link-detection-end

is_recognized_tree() {
  local dest="$1"
  local sentinel="$2"
  [[ -d "$dest" && ! -L "$dest" && -e "$dest/$sentinel" ]]
}

RECOGNIZED_LINK_ROOT=""
RECOGNIZED_LINK_ROOT_SET=0
RECOGNIZED_TOPOLOGY=""
recognized_node() {
  local dest="$1"
  local kind="$2"
  local sentinel="$3"
  local link_root=""
  if [[ -L "$dest" ]]; then
    if [[ -n "$RECOGNIZED_TOPOLOGY" && "$RECOGNIZED_TOPOLOGY" != "link" ]]; then
      return 1
    fi
    link_root="$(managed_link_root "$dest" "$kind")" || return 1
    if [[ "$RECOGNIZED_LINK_ROOT_SET" -eq 1 && "$link_root" != "$RECOGNIZED_LINK_ROOT" ]]; then
      return 1
    fi
    RECOGNIZED_TOPOLOGY="link"
    RECOGNIZED_LINK_ROOT="$link_root"
    RECOGNIZED_LINK_ROOT_SET=1
    return 0
  fi
  if [[ -n "$RECOGNIZED_TOPOLOGY" && "$RECOGNIZED_TOPOLOGY" != "tree" ]]; then
    return 1
  fi
  if is_recognized_tree "$dest" "$sentinel"; then
    RECOGNIZED_TOPOLOGY="tree"
    return 0
  fi
  return 1
}

recognized_installation() {
  if ! exists_node "$SCRIPTS_DEST" || ! exists_node "$SCHEMAS_DEST" || \
     ! exists_node "$DOCS_DEST" || ! exists_node "$SKILL_DEST"; then
    return 1
  fi
  RECOGNIZED_LINK_ROOT=""
  RECOGNIZED_LINK_ROOT_SET=0
  RECOGNIZED_TOPOLOGY=""
  recognized_node "$SCRIPTS_DEST" scripts "install-into.sh" && \
  recognized_node "$SCHEMAS_DEST" schemas "round_state.schema.json" && \
  recognized_node "$DOCS_DEST" docs "multi-agent-workflow.md" && \
  recognized_node "$SKILL_DEST" skill "SKILL.md"
}

MANAGED_COUNT=0
for managed_dest in "$SCRIPTS_DEST" "$SCHEMAS_DEST" "$DOCS_DEST" "$SKILL_DEST"; do
  if exists_node "$managed_dest"; then
    MANAGED_COUNT=$((MANAGED_COUNT + 1))
  fi
done

if [[ "$UPGRADE" -eq 0 && "$MANAGED_COUNT" -gt 0 ]]; then
  echo "install-into: an existing or partial installation was found; no changes made." >&2
  printf 'Upgrade a recognized installation with:\n  %q %q --upgrade\n' "$0" "$TARGET_ROOT" >&2
  exit 2
fi
if [[ "$UPGRADE" -eq 1 && "$MANAGED_COUNT" -eq 0 ]]; then
  echo "install-into: --upgrade requires an existing installation; use the default command for a fresh install." >&2
  exit 2
fi
if [[ "$UPGRADE" -eq 1 ]] && ! recognized_installation; then
  echo "install-into: existing managed paths are not a complete recognized toolkit installation; no changes made." >&2
  echo "Custom, partial, and unrecognized link layouts must be resolved manually." >&2
  exit 2
fi

mkdir -p "$AGENT_DIR" "$AGENT_DIR/docs" "$REVIEW_DIR" "$CLAUDE_SKILLS_DIR"
STAGE_ROOT="$(mktemp -d "$TARGET_ROOT/.agent-workflow-install.XXXXXX")"
STAGE_SCRIPTS="$STAGE_ROOT/scripts"
STAGE_SCHEMAS="$STAGE_ROOT/schemas"
STAGE_DOCS="$STAGE_ROOT/docs"
STAGE_SKILL="$STAGE_ROOT/skill"

cleanup_stage() {
  if [[ -n "${STAGE_ROOT:-}" && -d "$STAGE_ROOT" ]]; then
    rm -rf "$STAGE_ROOT"
  fi
}
trap cleanup_stage EXIT INT TERM

stage_tree() {
  local src="$1"
  local dest="$2"
  cp -R "$src" "$dest"
  [[ -d "$dest" && ! -L "$dest" ]]
}

if ! stage_tree "$SCRIPTS_SRC" "$STAGE_SCRIPTS" || \
   ! stage_tree "$SCHEMAS_SRC" "$STAGE_SCHEMAS" || \
   ! stage_tree "$DOCS_SRC" "$STAGE_DOCS" || \
   ! stage_tree "$SKILL_SRC" "$STAGE_SKILL"; then
  echo "install-into: staging failed; target installation was not changed." >&2
  exit 1
fi

BACKUP_ROOT=""
if [[ "$UPGRADE" -eq 1 ]]; then
  backup_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  BACKUP_ROOT="$REVIEW_DIR/agent-workflow-install-backups/$backup_id"
  mkdir -p "$BACKUP_ROOT"
fi

restore_previous() {
  local name=""
  local dest=""
  local restore_status=0
  echo "install-into: installation failed; restoring the previous installation." >&2
  for name in scripts schemas docs skill; do
    case "$name" in
      scripts) dest="$SCRIPTS_DEST" ;;
      schemas) dest="$SCHEMAS_DEST" ;;
      docs) dest="$DOCS_DEST" ;;
      skill) dest="$SKILL_DEST" ;;
    esac
    if [[ -n "$BACKUP_ROOT" ]] && exists_node "$BACKUP_ROOT/$name"; then
      if exists_node "$dest"; then
        if ! rm -rf "$dest" || exists_node "$dest"; then
          echo "install-into: rollback incomplete; could not remove replacement: $dest" >&2
          restore_status=1
          continue
        fi
      fi
      if ! mv "$BACKUP_ROOT/$name" "$dest"; then
        echo "install-into: rollback incomplete for $dest; retained backup: $BACKUP_ROOT/$name" >&2
        restore_status=1
      fi
    elif [[ "$UPGRADE" -eq 0 ]] && exists_node "$dest"; then
      if ! rm -rf "$dest" || exists_node "$dest"; then
        echo "install-into: rollback incomplete; could not remove fresh-install leaf: $dest" >&2
        restore_status=1
      fi
    fi
  done
  return "$restore_status"
}

commit_installation() {
  local name=""
  local dest=""
  local staged=""
  if [[ "$UPGRADE" -eq 1 ]]; then
    for name in scripts schemas docs skill; do
      case "$name" in
        scripts) dest="$SCRIPTS_DEST" ;;
        schemas) dest="$SCHEMAS_DEST" ;;
        docs) dest="$DOCS_DEST" ;;
        skill) dest="$SKILL_DEST" ;;
      esac
      mv "$dest" "$BACKUP_ROOT/$name" || return $?
    done
  fi
  for name in scripts schemas docs skill; do
    case "$name" in
      scripts) dest="$SCRIPTS_DEST"; staged="$STAGE_SCRIPTS" ;;
      schemas) dest="$SCHEMAS_DEST"; staged="$STAGE_SCHEMAS" ;;
      docs) dest="$DOCS_DEST"; staged="$STAGE_DOCS" ;;
      skill) dest="$SKILL_DEST"; staged="$STAGE_SKILL" ;;
    esac
    mv "$staged" "$dest" || return $?
    echo "installed: $dest"
  done
}

set +e
commit_installation
install_status=$?
set -e
if [[ "$install_status" -ne 0 ]]; then
  set +e
  restore_previous
  restore_status=$?
  set -e
  if [[ "$restore_status" -ne 0 ]]; then
    if [[ -n "$BACKUP_ROOT" ]]; then
      echo "install-into: manual recovery required from: $BACKUP_ROOT" >&2
    else
      echo "install-into: manual cleanup required inside target: $TARGET_ROOT" >&2
    fi
    exit 70
  fi
  exit "$install_status"
fi

trap - EXIT INT TERM
cleanup_stage

if [[ "$UPGRADE" -eq 1 ]]; then
  echo "upgrade backup: $BACKUP_ROOT"
fi

cat <<EOF

Next steps:
  - Invoke the project skill: /agent-workflow
  - Read the playbook:        $TARGET_ROOT/.agent-workflow/docs/agents/multi-agent-workflow.md
  - Dispatch through:         $TARGET_ROOT/.agent-workflow/scripts/cmux-dispatch.sh
  - Verify target fit before using the bundled backend/Vitest verify.sh adapter.
  - Copy .env.example from the distributable toolkit package when needed.
EOF
