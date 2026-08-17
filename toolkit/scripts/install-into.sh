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
    --profile)
      [[ $# -lt 2 ]] && { echo "missing value for --profile" >&2; usage; exit 2; }
      echo "install-into: --profile $2 was removed; installs are generic-only." >&2
      echo "Use: $0 <target-repo-path> [--upgrade]" >&2
      exit 2
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
CODEX_DIR="$TARGET_ROOT/.agents"
CODEX_SKILLS_DIR="$CODEX_DIR/skills"
OPENCODE_DIR="$TARGET_ROOT/.opencode"
OPENCODE_AGENTS_DIR="$OPENCODE_DIR/agents"
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
CODEX_SKILL_DEST="$CODEX_SKILLS_DIR/agent-workflow"
OPENCODE_AGENT_DEST="$OPENCODE_AGENTS_DIR/agent-workflow.md"
OPENCODE_CONFIG_DEST="$TARGET_ROOT/opencode.json"
MODEL_ALLOC_SRC="$PRODUCT_ROOT/model-alloc.json"
MODEL_ALLOC_DEST="$AGENT_DIR/model-alloc.json"
PROFILE_DEST="$AGENT_DIR/install-profile.json"
AGENTS_DEST="$TARGET_ROOT/AGENTS.md"
GENERIC_PROFILE_SRC="$SCRIPTS_SRC/install-profiles/generic"

DOCS_SRC="$GENERIC_PROFILE_SRC/docs/agents"
SKILL_SRC="$GENERIC_PROFILE_SRC/skill"

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
  for managed_parent in "$CODEX_DIR" "$CODEX_SKILLS_DIR" "$OPENCODE_DIR" "$OPENCODE_AGENTS_DIR"; do
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
require_source_tree "$GENERIC_PROFILE_SRC"
[[ -r "$MODEL_ALLOC_SRC" ]] || { echo "default model allocation config is missing: $MODEL_ALLOC_SRC" >&2; exit 2; }
reject_symlinked_managed_parent

exists_node() {
  [[ -e "$1" || -L "$1" ]]
}

AGENTS_POINTER_STATE="absent"
if exists_node "$AGENTS_DEST"; then
  if [[ -L "$AGENTS_DEST" || ! -f "$AGENTS_DEST" || ! -r "$AGENTS_DEST" ]]; then
    echo "install-into: target AGENTS.md must be a readable regular file: $AGENTS_DEST" >&2
    echo "No changes made. Resolve the target-owned instruction file before installing." >&2
    exit 2
  fi
  AGENTS_POINTER_STATE="$(node - "$AGENTS_DEST" <<'NODE'
const fs = require("fs");
const file = process.argv[2];
const begin = "<!-- agent-workflow:begin (managed by install-into.sh — do not edit) -->";
const end = "<!-- agent-workflow:end -->";
const content = fs.readFileSync(file, "utf8");
const lines = content.match(/[^\r\n]*(?:\r\n|\n|\r|$)/g) || [];
let state = 0;
let blocks = 0;
for (const raw of lines) {
  if (raw === "") continue;
  const line = raw.replace(/\r\n$|\n$|\r$/, "");
  if (line.includes("<!-- agent-workflow:begin") || line.includes("<!-- agent-workflow:end")) {
    if (line === begin) {
      if (state !== 0) process.exit(2);
      state = 1;
    } else if (line === end) {
      if (state !== 1) process.exit(2);
      state = 0;
      blocks += 1;
    } else {
      process.exit(2);
    }
  }
}
if (state !== 0 || blocks > 1) process.exit(2);
process.stdout.write(blocks === 1 ? "managed" : "unmanaged");
NODE
)" || {
    echo "install-into: target AGENTS.md has malformed or duplicate agent-workflow pointer markers; no changes made." >&2
    exit 2
  }
else
  echo "warning: target has no AGENTS.md; skipping the managed agent-workflow pointer." >&2
fi

installed_profile() {
  local profile_file="$1"
  [[ -f "$profile_file" ]] || return 1
  node -e 'try { const v=JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); process.exit(v.schema_version === "1" && typeof v.profile === "string" && v.profile.length > 0 ? 0 : 1); } catch (e) { process.exit(1); }' "$profile_file" || return 1
  node -e 'const v=JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); process.stdout.write(v.profile)' "$profile_file"
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
  recognized_node "$SCRIPTS_DEST" scripts "agent-workflow.sh" && \
  recognized_node "$SCHEMAS_DEST" schemas "round_state.schema.json" && \
  recognized_node "$DOCS_DEST" docs "multi-agent-workflow.md" && \
  recognized_node "$SKILL_DEST" skill "SKILL.md" || return 1
  is_recognized_tree "$CODEX_SKILL_DEST" "SKILL.md" && \
    [[ -f "$OPENCODE_AGENT_DEST" && ! -L "$OPENCODE_AGENT_DEST" ]] && \
    [[ -f "$OPENCODE_CONFIG_DEST" && ! -L "$OPENCODE_CONFIG_DEST" ]] || return 1
  return 0
}

MANAGED_COUNT=0
for managed_dest in "$SCRIPTS_DEST" "$SCHEMAS_DEST" "$DOCS_DEST" "$SKILL_DEST" \
  "$CODEX_SKILL_DEST" "$OPENCODE_AGENT_DEST" "$OPENCODE_CONFIG_DEST"; do
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
if [[ "$UPGRADE" -eq 1 && -e "$PROFILE_DEST" ]]; then
  existing_profile="$(installed_profile "$PROFILE_DEST")" || {
    echo "install-into: install profile marker is invalid; no changes made." >&2
    exit 2
  }
  if [[ "$existing_profile" != "generic" ]]; then
    echo "install-into: refusing to upgrade a legacy '$existing_profile' installation; the compatibility profile was removed. Remove the installation explicitly and reinstall." >&2
    exit 2
  fi
fi
if [[ "$UPGRADE" -eq 1 ]] && ! recognized_installation; then
  echo "install-into: existing managed paths are not a complete recognized toolkit installation; no changes made." >&2
  echo "Custom, partial, and unrecognized link layouts must be resolved manually." >&2
  exit 2
fi

mkdir -p "$AGENT_DIR" "$AGENT_DIR/docs" "$REVIEW_DIR" "$CLAUDE_SKILLS_DIR" \
  "$CODEX_SKILLS_DIR" "$OPENCODE_AGENTS_DIR"
STAGE_ROOT="$(mktemp -d "$TARGET_ROOT/.agent-workflow-install.XXXXXX")"
STAGE_SCRIPTS="$STAGE_ROOT/scripts"
STAGE_SCHEMAS="$STAGE_ROOT/schemas"
STAGE_DOCS="$STAGE_ROOT/docs"
STAGE_SKILL="$STAGE_ROOT/skill"
STAGE_MODEL_ALLOC="$STAGE_ROOT/model-alloc.json"
STAGE_PROFILE="$STAGE_ROOT/install-profile.json"
STAGE_CODEX_SKILL="$STAGE_ROOT/codex-skill"
STAGE_OPENCODE_AGENT="$STAGE_ROOT/opencode-agent.md"
STAGE_OPENCODE_CONFIG="$STAGE_ROOT/opencode.json"
STAGE_AGENTS="$STAGE_ROOT/AGENTS.md"

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
if ! stage_tree "$SKILL_SRC" "$STAGE_CODEX_SKILL" || \
   ! cp "$GENERIC_PROFILE_SRC/opencode/agent-workflow.md" "$STAGE_OPENCODE_AGENT" || \
   ! cp "$GENERIC_PROFILE_SRC/opencode/opencode.json" "$STAGE_OPENCODE_CONFIG"; then
  echo "install-into: generic client staging failed; target installation was not changed." >&2
  exit 1
fi
if ! cp "$MODEL_ALLOC_SRC" "$STAGE_MODEL_ALLOC"; then
  echo "install-into: could not stage default model allocation config; target installation was not changed." >&2
  exit 1
fi
if [[ "$AGENTS_POINTER_STATE" != "absent" ]]; then
  if ! node - "$AGENTS_DEST" "$STAGE_AGENTS" <<'NODE'
const fs = require("fs");
const source = process.argv[2];
const destination = process.argv[3];
const begin = "<!-- agent-workflow:begin (managed by install-into.sh — do not edit) -->";
const end = "<!-- agent-workflow:end -->";
const block = `${begin}\n### Model routing (installed by the agent-workflow toolkit)\n\nRead before any dispatch:\n- .agent-workflow/model-alloc.json — project-owned allocation contract\n- .agent-workflow/docs/agents/multi-agent-workflow.md — Model Allocation\n- .agent-workflow/docs/agents/conductor-persona.md — section 2: CONDUCTOR is read-only on product code\n\nThe allocation file is authoritative. CONDUCTOR dispatches artifact-producing work; workers produce code, docs, plans, and recon.\n${end}\n`;
const content = fs.readFileSync(source, "utf8");
const lines = content.match(/[^\r\n]*(?:\r\n|\n|\r|$)/g) || [];
let offset = 0;
let state = 0;
let blocks = 0;
let beginStart = -1;
let endOffset = -1;
for (const raw of lines) {
  if (raw === "") continue;
  const line = raw.replace(/\r\n$|\n$|\r$/, "");
  if (line.includes("<!-- agent-workflow:begin") || line.includes("<!-- agent-workflow:end")) {
    if (line === begin) {
      if (state !== 0) process.exit(2);
      state = 1;
      beginStart = offset;
    } else if (line === end) {
      if (state !== 1) process.exit(2);
      state = 0;
      blocks += 1;
      endOffset = offset + raw.length;
    } else {
      process.exit(2);
    }
  }
  offset += raw.length;
}
if (state !== 0 || blocks > 1) process.exit(2);
const next = blocks === 1
  ? content.slice(0, beginStart) + block + content.slice(endOffset)
  : content + (content.length === 0 ? "" : /(?:\r\n|\n|\r)$/.test(content) ? "\n" : "\n\n") + block;
fs.writeFileSync(destination, next);
fs.chmodSync(destination, fs.statSync(source).mode & 0o7777);
NODE
  then
    echo "install-into: could not stage the managed AGENTS.md pointer; target installation was not changed." >&2
    exit 1
  fi
fi
# Smoke suites exercise the source product layout and may create temporary
# installations.  They are maintainer verification assets, not target runtime
# commands, so never copy them into an installed PRODUCT_HOME.  The installer
# itself and the staged generic-profile source assets are also maintainer-only.
rm -rf "$STAGE_SCRIPTS/__tests__" "$STAGE_SCRIPTS/install-profiles"
rm -f "$STAGE_SCRIPTS/install-into.sh"
rm -rf "$STAGE_SCHEMAS/fixtures"
printf '{"schema_version":"1","profile":"generic"}\n' > "$STAGE_PROFILE"

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
  for name in codex-skill opencode-agent opencode-config; do
    case "$name" in
      codex-skill) dest="$CODEX_SKILL_DEST" ;;
      opencode-agent) dest="$OPENCODE_AGENT_DEST" ;;
      opencode-config) dest="$OPENCODE_CONFIG_DEST" ;;
    esac
    if [[ -n "$BACKUP_ROOT" ]] && exists_node "$BACKUP_ROOT/$name"; then
      if exists_node "$dest"; then rm -rf "$dest" || restore_status=1; fi
      mv "$BACKUP_ROOT/$name" "$dest" || restore_status=1
    elif [[ "$UPGRADE" -eq 0 ]] && exists_node "$dest"; then
      rm -rf "$dest" || restore_status=1
    fi
  done
  if [[ -n "$BACKUP_ROOT" ]] && exists_node "$BACKUP_ROOT/profile"; then
    if exists_node "$PROFILE_DEST"; then
      if ! rm -f "$PROFILE_DEST" || exists_node "$PROFILE_DEST"; then
        echo "install-into: rollback incomplete; could not remove replacement: $PROFILE_DEST" >&2
        restore_status=1
      fi
    fi
    if ! mv "$BACKUP_ROOT/profile" "$PROFILE_DEST"; then
      echo "install-into: rollback incomplete for $PROFILE_DEST; retained backup: $BACKUP_ROOT/profile" >&2
      restore_status=1
    fi
  fi
  if [[ -n "$BACKUP_ROOT" ]] && exists_node "$BACKUP_ROOT/agents"; then
    if exists_node "$AGENTS_DEST"; then
      if ! rm -f "$AGENTS_DEST" || exists_node "$AGENTS_DEST"; then
        echo "install-into: rollback incomplete; could not remove replacement: $AGENTS_DEST" >&2
        restore_status=1
      elif ! mv "$BACKUP_ROOT/agents" "$AGENTS_DEST"; then
        echo "install-into: rollback incomplete for $AGENTS_DEST; retained backup: $BACKUP_ROOT/agents" >&2
        restore_status=1
      fi
    elif ! mv "$BACKUP_ROOT/agents" "$AGENTS_DEST"; then
      echo "install-into: rollback incomplete for $AGENTS_DEST; retained backup: $BACKUP_ROOT/agents" >&2
      restore_status=1
    fi
  fi
  if [[ "$UPGRADE" -eq 0 ]] && exists_node "$MODEL_ALLOC_DEST"; then
    rm -f "$MODEL_ALLOC_DEST" || restore_status=1
  fi
  if [[ "$UPGRADE" -eq 0 ]] && exists_node "$PROFILE_DEST"; then
    rm -f "$PROFILE_DEST" || restore_status=1
  fi
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
    if exists_node "$PROFILE_DEST"; then
      mv "$PROFILE_DEST" "$BACKUP_ROOT/profile" || return $?
    fi
    if [[ "$AGENTS_POINTER_STATE" != "absent" ]]; then
      mv "$AGENTS_DEST" "$BACKUP_ROOT/agents" || return $?
    fi
    mv "$CODEX_SKILL_DEST" "$BACKUP_ROOT/codex-skill" || return $?
    mv "$OPENCODE_AGENT_DEST" "$BACKUP_ROOT/opencode-agent" || return $?
    mv "$OPENCODE_CONFIG_DEST" "$BACKUP_ROOT/opencode-config" || return $?
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
  mv "$STAGE_CODEX_SKILL" "$CODEX_SKILL_DEST" || return $?
  echo "installed: $CODEX_SKILL_DEST"
  mv "$STAGE_OPENCODE_AGENT" "$OPENCODE_AGENT_DEST" || return $?
  echo "installed: $OPENCODE_AGENT_DEST"
  mv "$STAGE_OPENCODE_CONFIG" "$OPENCODE_CONFIG_DEST" || return $?
  echo "installed: $OPENCODE_CONFIG_DEST"
  # Project-owned configuration is seeded only on first install. Upgrades never
  # overwrite it, including when its schema is older; operators get a warning.
  if [[ "$UPGRADE" -eq 0 ]]; then
    mv "$STAGE_MODEL_ALLOC" "$MODEL_ALLOC_DEST" || return $?
    echo "installed: $MODEL_ALLOC_DEST"
  elif [[ -f "$MODEL_ALLOC_DEST" ]]; then
    echo "warning: preserving project-owned model allocation config: $MODEL_ALLOC_DEST" >&2
    if ! node -e 'try { const v=JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); const missing=v.roles && v.capabilities && Object.keys(v.capabilities).some(k => !Array.isArray(v.capabilities[k].available_via)); process.exit(missing ? 1 : 0); } catch (e) { process.exit(0); }' "$MODEL_ALLOC_DEST"; then
      # Schema-v1 configurations shipped before available_via existed. Keep
      # them project-owned on upgrade; model-alloc.sh infers only known model
      # families at use time and fails closed for an unknown family.
      echo "warning: existing model allocation config lacks capabilities.*.available_via; preserving legacy schema-v1 config (known provider families are inferred at dispatch; unknown models require migration)." >&2
    fi
    if ! node -e 'try { process.exit(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).schema_version === "1" ? 0 : 1); } catch (e) { process.exit(1); }' "$MODEL_ALLOC_DEST"; then
      echo "warning: model allocation config needs an explicit schema migration; it was not overwritten" >&2
    fi
  else
    mv "$STAGE_MODEL_ALLOC" "$MODEL_ALLOC_DEST" || return $?
    echo "installed: $MODEL_ALLOC_DEST"
  fi
  mv "$STAGE_PROFILE" "$PROFILE_DEST" || return $?
  echo "installed: $PROFILE_DEST"
  if [[ "$AGENTS_POINTER_STATE" != "absent" ]]; then
    mv "$STAGE_AGENTS" "$AGENTS_DEST" || return $?
    echo "installed: $AGENTS_DEST"
  fi
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
  - Product home:             $TARGET_ROOT/.agent-workflow
  - Invoke the project skill: /agent-workflow
  - Read the playbook:        $TARGET_ROOT/.agent-workflow/docs/agents/multi-agent-workflow.md
  - Configure product home:   copy $TARGET_ROOT/.agent-workflow/docs/agents/workflow-config.example.json $TARGET_ROOT/.agent-workflow/workflow-config.json
  - From any worktree, invoke $TARGET_ROOT/.agent-workflow/scripts/<command> with --worktree <worktree>
  - Verify with target-verify.sh and a target-owned profile.
EOF
