#!/bin/bash
# rite workflow - State Path Resolver
# Resolves the root directory for rite state files (.rite-compact-state, .rite-work-memory/)
# Usage: source this script or call resolve_state_root [cwd]
# Output: Prints the resolved root path to stdout
set -euo pipefail

resolve_state_root() {
  local cwd="${1:-$(pwd)}"

  # Walk up to find git root (rite state files live at repository root)
  local root
  root=$(cd "$cwd" && git rev-parse --show-toplevel 2>/dev/null) || true

  if [ -n "$root" ] && [ -d "$root" ]; then
    echo "$root"
    return 0
  fi

  # Fallback: use cwd if not in a git repo
  echo "$cwd"
  return 0
}

# When invoked directly (not sourced), resolve and print
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  resolve_state_root "${1:-$(pwd)}"
fi
