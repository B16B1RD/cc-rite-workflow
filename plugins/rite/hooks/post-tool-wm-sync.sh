#!/bin/bash
# rite workflow - PostToolUse Work Memory Sync Hook
# Auto-creates local work memory when missing during an active workflow.
# Fires after every Bash tool use; quick-exits in most cases.
set -euo pipefail

# Recursion guard
[ -z "${RITE_WM_HOOK_ACTIVE:-}" ] || exit 0
export RITE_WM_HOOK_ACTIVE=1

INPUT=$(cat)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$CWD" ] && [ -d "$CWD" ] || exit 0

# Resolve state root (git root or CWD)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$CWD" 2>/dev/null) || STATE_ROOT="$CWD"

FLOW_STATE="$STATE_ROOT/.rite-flow-state"
[ -f "$FLOW_STATE" ] || exit 0

_flow_data=$(jq -r '[(.active // false | tostring), (.issue_number // "" | tostring), (.phase // "" | tostring)] | @tsv' "$FLOW_STATE" 2>/dev/null) || exit 0
IFS=$'\t' read -r _active issue_number _phase <<< "$_flow_data"
[ "$_active" = "true" ] || exit 0
[ -n "$issue_number" ] || exit 0
# Defense-in-depth: don't recreate WM for completed workflows (#776)
[ "$_phase" != "completed" ] || exit 0
[ "$_phase" != "cleanup" ] || exit 0

LOCAL_WM="$STATE_ROOT/.rite-work-memory/issue-${issue_number}.md"
[ ! -f "$LOCAL_WM" ] || exit 0

# Debug logging (same pattern as stop-guard.sh)
log_debug() {
  [ -n "${RITE_DEBUG:-}" ] && echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] post-tool-wm-sync: $1" \
    >> "$STATE_ROOT/.rite-flow-debug.log" 2>/dev/null || true
}

log_debug "local WM missing for issue #${issue_number}, auto-creating"

cd "$STATE_ROOT" || exit 0
source "$SCRIPT_DIR/work-memory-update.sh" || { log_debug "failed to source work-memory-update.sh"; exit 0; }
export WM_PLUGIN_ROOT="${WM_PLUGIN_ROOT:-$(dirname "$SCRIPT_DIR")}"

_wm_data=$(jq -r '[(.phase // "unknown"), (.next_action // "")] | @tsv' "$FLOW_STATE" 2>/dev/null) || _wm_data=$'unknown\t'
IFS=$'\t' read -r phase next_action <<< "$_wm_data"

export WM_SOURCE="auto_hook"
export WM_PHASE="$phase"
export WM_PHASE_DETAIL="Auto-created by PostToolUse hook"
export WM_NEXT_ACTION="$next_action"
export WM_BODY_TEXT="Local work memory auto-created by PostToolUse hook."
export WM_ISSUE_NUMBER="$issue_number"

if update_local_work_memory; then
  log_debug "local WM created successfully"
else
  log_debug "update_local_work_memory failed (exit $?)"
fi
exit 0
