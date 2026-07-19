#!/usr/bin/env bash
# Shared product-home discovery for source and installed workflow commands.
# bash-3.2-compatible: callers provide the physical scripts directory.

agent_workflow_product_root() {
  local scripts_dir="$1"
  (cd "$scripts_dir/.." && pwd -P)
}

agent_workflow_schema_dir() {
  local product_root="$1"

  if [ -d "$product_root/schemas" ]; then
    printf '%s\n' "$product_root/schemas"
    return 0
  fi

  return 1
}
