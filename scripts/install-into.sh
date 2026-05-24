#!/usr/bin/env bash
# Wire a target repo to this workflow toolkit without copying by default.
#
# Usage:
#   scripts/install-into.sh <target-repo-path> [--mode symlink|copy] [--force]
set -euo pipefail

usage() {
  echo "usage: install-into.sh <target-repo-path> [--mode symlink|copy] [--force]" >&2
}

TARGET_REPO=""
MODE="symlink"
FORCE=0

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TOOLKIT_ROOT="$(cd "$SCRIPT_DIR/.." && git rev-parse --show-toplevel)"
TOOLKIT_ROOT="$(cd "$TOOLKIT_ROOT" && pwd -P)"

if [[ ! -d "$TARGET_REPO" ]]; then
  echo "target does not exist or is not a directory: $TARGET_REPO" >&2
  exit 2
fi

TARGET_ROOT="$(cd "$TARGET_REPO" && pwd -P)"

if [[ "$TARGET_ROOT" == "$TOOLKIT_ROOT" ]]; then
  echo "refusing to install into the toolkit repo itself: $TARGET_ROOT" >&2
  exit 2
fi

if ! git -C "$TARGET_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "warning: target is not a git repo: $TARGET_ROOT" >&2
fi

AGENT_DIR="$TARGET_ROOT/.agent-workflow"
REVIEW_DIR="$TARGET_ROOT/.review"
SCRIPTS_SRC="$TOOLKIT_ROOT/scripts"
SCHEMAS_SRC="$TOOLKIT_ROOT/.review/schemas"
SCRIPTS_DEST="$AGENT_DIR/scripts"
SCHEMAS_DEST="$AGENT_DIR/schemas"

mkdir -p "$AGENT_DIR"
mkdir -p "$REVIEW_DIR"

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

  ln -s "$src" "$dest"
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

  cp -R "$src" "$dest"
  echo "copied: $dest"
}

if [[ "$MODE" == "symlink" ]]; then
  install_link "$SCRIPTS_SRC" "$SCRIPTS_DEST"
  install_link "$SCHEMAS_SRC" "$SCHEMAS_DEST"
else
  install_copy "$SCRIPTS_SRC" "$SCRIPTS_DEST"
  install_copy "$SCHEMAS_SRC" "$SCHEMAS_DEST"
fi

cat <<EOF

Next steps:
  - Run verification via: $TARGET_ROOT/.agent-workflow/scripts/verify.sh
  - Dispatch Codex via:   $TARGET_ROOT/.agent-workflow/scripts/codex-safe.sh
  - Copy toolkit env defaults into the target when needed: $TOOLKIT_ROOT/.env.example
EOF
