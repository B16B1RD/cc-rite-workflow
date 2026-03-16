#!/bin/bash
# rite workflow - PostToolUse Work Memory Sync Hook
# Auto-creates local work memory when missing during an active workflow.
# Also auto-syncs Issue comment work memory when phase changes (Issue #167).
# Fires after every Bash tool use; quick-exits in most cases.
set -euo pipefail

# Hook version resolution preamble (must be before INPUT=$(cat) to preserve stdin)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/hook-preamble.sh" 2>/dev/null || true

# Recursion guard
[ -z "${RITE_WM_HOOK_ACTIVE:-}" ] || exit 0
export RITE_WM_HOOK_ACTIVE=1

# cat failure does not abort under set -e; || guard is defensive
INPUT=$(cat) || INPUT=""
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$CWD" ] && [ -d "$CWD" ] || exit 0

# Resolve state root (git root or CWD)
# SCRIPT_DIR already set in preamble block above
STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$CWD" 2>/dev/null) || STATE_ROOT="$CWD"

FLOW_STATE="$STATE_ROOT/.rite-flow-state"
[ -f "$FLOW_STATE" ] || exit 0

_flow_data=$(jq -r '[(.active // false | tostring), (.issue_number // "" | tostring), (.phase // "" | tostring), (.last_synced_phase // "" | tostring)] | @tsv' "$FLOW_STATE" 2>/dev/null) || exit 0
IFS=$'\t' read -r _active issue_number _phase _last_synced_phase <<< "$_flow_data"
[ "$_active" = "true" ] || exit 0
[ -n "$issue_number" ] || exit 0
# Defense-in-depth: don't recreate WM for completed workflows (#776)
[ "$_phase" != "completed" ] || exit 0
[ "$_phase" != "cleanup" ] || exit 0

LOCAL_WM="$STATE_ROOT/.rite-work-memory/issue-${issue_number}.md"

# Debug logging (moved before LOCAL_WM check for use in both code paths)
log_debug() {
  [ -n "${RITE_DEBUG:-}" ] && echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] post-tool-wm-sync: $1" \
    >> "$STATE_ROOT/.rite-flow-debug.log" 2>/dev/null || true
}

if [ ! -f "$LOCAL_WM" ]; then
  # --- Existing logic: auto-create local WM when missing ---
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
fi

# === Phase diff detection & Issue comment auto-sync (Issue #167) ===
# Scope: phase changes only. next_action and loop_count changes are
# handled by explicit calls in command files (Phase 2 follow-up).
[ "$_phase" != "$_last_synced_phase" ] || exit 0
[ -n "$_phase" ] || exit 0

log_debug "phase changed: $_last_synced_phase -> $_phase, syncing to issue comment"

# --- 1. Phase update ---
_phase_detail=""
_phase_detail=$(python3 "$SCRIPT_DIR/work-memory-parse.py" "$LOCAL_WM" 2>/dev/null \
  | jq -r '.data.phase_detail // ""' 2>/dev/null) || _phase_detail=""
[ -n "$_phase_detail" ] || _phase_detail="$_phase"

"$SCRIPT_DIR/issue-comment-wm-sync.sh" update \
  --issue "$issue_number" \
  --transform update-phase \
  --phase "$_phase" \
  --phase-detail "$_phase_detail" 2>/dev/null || log_debug "update-phase failed"

# --- 2. Progress table + changed files update (post-implementation phases) ---
# Automatically run update-progress and update-plan-status when phase transitions
# to a post-implementation phase (phase5_lint and beyond).
case "$_phase" in
  phase5_lint|phase5_post_lint|phase5_pr*|phase5_post_review|phase5_post_ready)
    cd "$STATE_ROOT" || true

    # Determine base branch from rite-config.yml
    _base_branch=$(grep -E '^  base:' rite-config.yml 2>/dev/null | sed 's/.*base:[[:space:]]*"\?\([^"]*\)"\?.*/\1/' || echo "develop")
    [ -n "$_base_branch" ] || _base_branch="develop"

    # Generate changed files list
    _changed_files_tmp=$(mktemp 2>/dev/null) || _changed_files_tmp="/tmp/rite-wm-sync-files.$$"
    git diff --name-status "origin/${_base_branch}...HEAD" 2>/dev/null | while IFS=$'\t' read -r status file; do
      case "$status" in
        A) echo "- \`$file\` - 追加" ;;
        M) echo "- \`$file\` - 変更" ;;
        D) echo "- \`$file\` - 削除" ;;
        R*) echo "- \`$file\` - 名前変更" ;;
      esac
    done > "$_changed_files_tmp" 2>/dev/null || true

    # Determine statuses based on git diff
    _diff_files=$(git diff --name-only "origin/${_base_branch}...HEAD" 2>/dev/null || echo "")
    _impl_status="✅ 完了"
    _test_status="⬜ 未着手"
    _doc_status="⬜ 未着手"
    echo "$_diff_files" | grep -qE '\.(test|spec)\.|test_|tests/' 2>/dev/null && _test_status="✅ 完了"
    echo "$_diff_files" | grep -qE '(docs/.*\.md|README\.md|CHANGELOG\.md|API\.md)' 2>/dev/null && _doc_status="✅ 完了"

    "$SCRIPT_DIR/issue-comment-wm-sync.sh" update \
      --issue "$issue_number" \
      --transform update-progress \
      --impl-status "$_impl_status" \
      --test-status "$_test_status" \
      --doc-status "$_doc_status" \
      --changed-files-file "$_changed_files_tmp" 2>/dev/null || log_debug "update-progress failed"

    rm -f "$_changed_files_tmp"

    # Bulk update implementation plan steps ⬜ → ✅
    "$SCRIPT_DIR/issue-comment-wm-sync.sh" update \
      --issue "$issue_number" \
      --transform update-plan-status 2>/dev/null || log_debug "update-plan-status failed"

    log_debug "progress sync completed"
    ;;
esac

# --- 3. Update last_synced_phase (atomic write) ---
# Note: issue-comment-wm-sync.sh's cache_comment_id() may write wm_comment_id
# to FLOW_STATE. We re-read FLOW_STATE after sync completes, so wm_comment_id
# is preserved (sequential execution, no race condition).
_tmp_fs=$(mktemp "${FLOW_STATE}.tmp.XXXXXX" 2>/dev/null) || _tmp_fs="${FLOW_STATE}.tmp.$$"
if jq --arg p "$_phase" '.last_synced_phase = $p' "$FLOW_STATE" > "$_tmp_fs" 2>/dev/null; then
  mv "$_tmp_fs" "$FLOW_STATE"
else
  rm -f "$_tmp_fs"
fi

log_debug "phase sync completed ($_last_synced_phase -> $_phase)"
exit 0
