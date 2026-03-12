#!/bin/bash
# rite workflow - Hook Preamble (Version Resolution)
# Sourced by all registered hook scripts.
# When running from an outdated marketplace cache version, exec-redirects
# to the current version so that `claude plugin update rite` takes effect
# without requiring `/rite:init` re-registration.
#
# Requirements:
#   - MUST be sourced AFTER `set -euo pipefail` and BEFORE `INPUT=$(cat)`
#   - MUST NOT consume stdin (exec transfers it to the new script)
#   - MUST use `return` (not `exit`) since this file is sourced
#
# Caller contract:
#   SCRIPT_DIR must be set before sourcing this file.
#   Example: SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_rite_resolve_hook_path() {
  # Skip if already redirected (prevent recursive exec loop)
  [ -z "${_RITE_HOOK_REDIRECTED:-}" ] || return 0

  # Skip for local development (not marketplace cache)
  local caller_path="${BASH_SOURCE[1]}"
  [[ "$caller_path" == *"/.claude/plugins/cache/"* ]] || return 0

  # Require jq for JSON parsing
  command -v jq &>/dev/null || return 0

  # Read current installPath from installed_plugins.json
  local plugins_file="$HOME/.claude/plugins/installed_plugins.json"
  [ -f "$plugins_file" ] || return 0

  local current_install_path
  current_install_path=$(jq -r '
    limit(1; .plugins | to_entries[] | select(.key | startswith("rite@"))) |
    .value[0].installPath // empty
  ' "$plugins_file" 2>/dev/null) || return 0

  [ -n "$current_install_path" ] || return 0

  # Compare: is SCRIPT_DIR different from the current version's hooks dir?
  local current_hooks_dir="$current_install_path/plugins/rite/hooks"
  [ "$SCRIPT_DIR" != "$current_hooks_dir" ] || return 0

  # Validate resolved path stays within expected prefix (defense-in-depth)
  local resolved_hooks_dir
  resolved_hooks_dir=$(realpath "$current_hooks_dir" 2>/dev/null) || return 0
  [[ "$resolved_hooks_dir" == "$HOME/.claude/plugins/cache/"* ]] || return 0

  # Verify target script exists
  local script_name
  script_name=$(basename "$caller_path")
  local target_script="$resolved_hooks_dir/$script_name"
  [ -f "$target_script" ] || return 0

  # Redirect to new version (stdin is preserved across exec)
  export _RITE_HOOK_REDIRECTED=1
  exec bash "$target_script"
}

_rite_resolve_hook_path
