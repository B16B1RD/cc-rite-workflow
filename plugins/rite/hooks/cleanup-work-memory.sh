#!/bin/bash
# rite workflow - Cleanup Work Memory
# Deterministic script for deleting local work memory files after cleanup/close.
# Does NOT depend on LLM placeholder substitution.
#
# Usage:
#   bash plugins/rite/hooks/cleanup-work-memory.sh [--issue <number>]
#
# Without --issue: resolves the current session's flow-state file via the
#   canonical resolver (flow-state.sh path — schema_v2/v3 per-session file
#   under .rite/sessions/, falling back to the legacy shared .rite-flow-state
#   only when session resolution itself fails), resets it to active:false,
#   deletes ALL issue-*.md files and lockdirs (full cleanup).
# With --issue <number>: deletes only the specified issue's files (close mode).
#   Does NOT reset the flow-state file (close.md handles its own state).
#
# Exit codes:
#   0: Success (files deleted or nothing to delete)
#   1: Argument error (missing or non-numeric --issue value)
#   Other non-zero: Unexpected error (forced exit by set -euo pipefail)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=control-char-neutralize.sh
source "$SCRIPT_DIR/control-char-neutralize.sh"

# Resolve repository root
STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$(pwd)" 2>/dev/null) || STATE_ROOT="$(pwd)"

WM_DIR_NEW="$STATE_ROOT/.rite/work-memory"
WM_DIR_OLD="$STATE_ROOT/.rite-work-memory"

# Parse arguments
ISSUE_NUMBER=""
CLOSE_MODE=false

while [ $# -gt 0 ]; do
  case "$1" in
    --issue)
      [ -n "${2:-}" ] || { echo "ERROR: --issue requires a number" >&2; exit 1; }
      [[ "$2" =~ ^[0-9]+$ ]] || { echo "ERROR: --issue must be a positive integer, got: '$2'" >&2; exit 1; }
      ISSUE_NUMBER="$2"
      CLOSE_MODE=true
      shift 2
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

deleted_count=0
failed_count=0

# --- Full cleanup mode (no --issue) ---
if [ "$CLOSE_MODE" = false ]; then
  # Resolve the current session's flow-state path via the canonical resolver
  # (flow-state.sh path — schema_v2/v3 per-session file under .rite/sessions/).
  # Resetting the legacy shared file directly (as this script previously did)
  # left the real per-session file behind with stale active:true/phase:cleanup
  # state after /rite:cleanup completed (#695). Fall back to the legacy shared
  # file only when session resolution itself fails (no .rite-session-id /
  # session env var available) — surface that fallback with a WARNING so a
  # corrupt/invalid session_id doesn't silently reproduce the same stale-state
  # bug via a different trigger (schema_v2 environments have no legacy file,
  # so a silent fallback here would make Step 1 a silent no-op).
  _fs_err=$(mktemp 2>/dev/null) || _fs_err=""
  if RESOLVED_FLOW_STATE=$(RITE_STATE_ROOT="$STATE_ROOT" "$SCRIPT_DIR/flow-state.sh" path 2>"${_fs_err:-/dev/null}"); then
    :
  else
    echo "WARNING: cleanup-work-memory: flow-state.sh path resolution failed — falling back to legacy $(basename "$STATE_ROOT/.rite-flow-state") (session_id may be missing or invalid)" >&2
    [ -n "$_fs_err" ] && [ -s "$_fs_err" ] && head -3 "$_fs_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    RESOLVED_FLOW_STATE=""
  fi
  [ -n "$_fs_err" ] && rm -f "$_fs_err"
  # This fallback is one of the two paths that can still write `.rite-flow-state`;
  # see the LEGACY_STATE comment in flow-state.sh for the full picture.
  FLOW_STATE="${RESOLVED_FLOW_STATE:-$STATE_ROOT/.rite-flow-state}"

  # Step 1: Reset flow-state to active:false BEFORE deleting files
  # This prevents post-tool-wm-sync.sh from recreating files
  if [ -f "$FLOW_STATE" ]; then
    # Read issue number from flow state for logging. Capture jq stderr so a
    # corrupt FLOW_STATE surfaces as a WARNING — otherwise the silent fallback
    # to ISSUE_NUMBER="" routes the cleanup audit log to `issue: 0` with no
    # hint that the operator's actual issue number was discarded.
    _isn_err=$(mktemp 2>/dev/null) || _isn_err=""
    _isn_rc=0
    ISSUE_NUMBER=$(jq -r '.issue_number // empty' "$FLOW_STATE" 2>"${_isn_err:-/dev/null}") || _isn_rc=$?
    if [ "$_isn_rc" -ne 0 ]; then
      _isn_tag=""
      [ -z "$_isn_err" ] && _isn_tag=" stderr_capture=disabled"
      echo "[rite] WARNING: cleanup-work-memory: $(basename "$FLOW_STATE") の .issue_number 取得失敗 (rc=$_isn_rc — FLOW_STATE may be corrupt${_isn_tag})" >&2
      [ -n "$_isn_err" ] && [ -s "$_isn_err" ] && head -3 "$_isn_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
      ISSUE_NUMBER=""
    fi
    [ -n "$_isn_err" ] && rm -f "$_isn_err"
    # Validate issue number from flow state (non-numeric values would break --argjson)
    if [ -n "$ISSUE_NUMBER" ] && ! [[ "$ISSUE_NUMBER" =~ ^[0-9]+$ ]]; then
      echo "WARNING: $(basename "$FLOW_STATE") の issue_number が数値でない: '$ISSUE_NUMBER'. 0 にフォールバック" >&2
      ISSUE_NUMBER=""
    fi

    # `set -euo pipefail` would abort the entire cleanup if mktemp fails before
    # the trap is installed — leaving compact-state, lockdir, and per-issue
    # work memory files un-removed. Guard explicitly so the remaining cleanup
    # steps still run on temp-file failure.
    if TMP_STATE=$(mktemp "$FLOW_STATE.tmp.XXXXXX" 2>/dev/null); then
      trap 'rm -f "$TMP_STATE" 2>/dev/null' EXIT TERM INT
      _jq_err=$(mktemp 2>/dev/null) || _jq_err=""
      if jq -n \
        --argjson active false \
        --argjson issue "${ISSUE_NUMBER:-0}" \
        --arg branch "" \
        --arg phase "completed" \
        --argjson pr 0 \
        --arg next "none" \
        --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")" \
        '{active: $active, issue_number: $issue, branch: $branch, phase: $phase, pr_number: $pr, next_action: $next, updated_at: $ts}' \
        > "$TMP_STATE" 2>"${_jq_err:-/dev/null}"; then
        _mv_err=$(mktemp 2>/dev/null) || _mv_err=""
        # if/else over `if !` preserves the real mv rc (EXDEV=18, EACCES=13,
        # ENOSPC=28), which is the diagnostic the WARNING is meant to carry.
        if mv "$TMP_STATE" "$FLOW_STATE" 2>"${_mv_err:-/dev/null}"; then
          :
        else
          _mv_rc=$?
          echo "WARNING: $(basename "$FLOW_STATE") の更新に失敗しました (mv rc=$_mv_rc)" >&2
          [ -n "$_mv_err" ] && [ -s "$_mv_err" ] && head -3 "$_mv_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
        fi
        [ -n "$_mv_err" ] && rm -f "$_mv_err"
      else
        _jq_rc=$?
        echo "WARNING: $(basename "$FLOW_STATE") のリセットに失敗しました (jq rc=$_jq_rc — missing in PATH / locale / parse error を区別)" >&2
        [ -n "$_jq_err" ] && [ -s "$_jq_err" ] && head -3 "$_jq_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
      fi
      [ -n "$_jq_err" ] && rm -f "$_jq_err"
    else
      echo "WARNING: $(basename "$FLOW_STATE") TMP_STATE mktemp failed — flow-state reset skipped (subsequent cleanup steps will still run)" >&2
      echo "  hint: $(dirname "$FLOW_STATE") の permission / disk full / read-only を確認" >&2
    fi
  fi

  # Step 2: Clean up compact-state (legacy shared + this session's per-session file)
  # Legacy shared path removal is retained for legacy migration residue.
  rm -f "$STATE_ROOT/.rite-compact-state" 2>/dev/null || true
  rm -rf "$STATE_ROOT/.rite-compact-state.lockdir" 2>/dev/null || echo "[CONTEXT] LOCKDIR_CLEANUP_FAILED=1; from=cleanup_work_memory" >&2
  # Per-session compact-state: derive from the already-resolved flow-state
  # path (RESOLVED_FLOW_STATE, set above) so full cleanup also reaps the
  # current session's snapshot. Empty when session resolution failed above —
  # no per-session compact-state to derive in that case.
  if [ -n "$RESOLVED_FLOW_STATE" ]; then
    _cwm_compact="${RESOLVED_FLOW_STATE%.flow-state}.compact-state"
    rm -f "$_cwm_compact" 2>/dev/null || true
    rm -rf "$_cwm_compact.lockdir" 2>/dev/null || echo "[CONTEXT] LOCKDIR_CLEANUP_FAILED=1; from=cleanup_work_memory_per_session" >&2
  fi

  # Step 3: Delete ALL work memory files (new path plus leftover legacy dir)
  for WM_DIR in "$WM_DIR_NEW" "$WM_DIR_OLD"; do
    if [ -d "$WM_DIR" ]; then
      for f in "$WM_DIR"/issue-*.md; do
        [ -f "$f" ] || continue
        if rm -f "$f" 2>/dev/null; then
          deleted_count=$((deleted_count + 1))
        else
          echo "WARNING: 削除失敗: $f" >&2
          failed_count=$((failed_count + 1))
        fi
        rm -rf "${f}.lockdir" 2>/dev/null || echo "[CONTEXT] LOCKDIR_CLEANUP_FAILED=1; from=cleanup_work_memory_wm_dir" >&2
      done
    fi
  done

# --- Close mode (--issue specified) ---
else
  # Delete only the specified issue's files (new path plus leftover legacy dir)
  for WM_DIR in "$WM_DIR_NEW" "$WM_DIR_OLD"; do
    target_file="$WM_DIR/issue-${ISSUE_NUMBER}.md"
    if [ -f "$target_file" ]; then
      if rm -f "$target_file" 2>/dev/null; then
        deleted_count=$((deleted_count + 1))
      else
        echo "WARNING: 削除失敗: $target_file" >&2
        failed_count=$((failed_count + 1))
      fi
    fi
    rm -rf "$WM_DIR/issue-${ISSUE_NUMBER}.md.lockdir" 2>/dev/null || echo "[CONTEXT] LOCKDIR_CLEANUP_FAILED=1; from=cleanup_work_memory_issue" >&2
  done
fi

# Step 4: Verify and report
remaining=0
for WM_DIR in "$WM_DIR_NEW" "$WM_DIR_OLD"; do
  if [ -d "$WM_DIR" ]; then
    # find の stderr を捨てると permission denied で 1 件も走査できなかった場合に「残存: 0 件」
    # と誤報告される。stderr は tempfile に capture し、非空なら WARNING を出して残存件数を
    # 「unknown」扱いにすることで silent corruption を防ぐ。
    _find_err=$(mktemp 2>/dev/null) || _find_err=""
    _find_out=$(find "$WM_DIR" -name 'issue-*.md' -type f 2>"${_find_err:-/dev/null}" | wc -l | tr -d ' ') || _find_out=""
    if [ -n "$_find_err" ] && [ -s "$_find_err" ]; then
      echo "WARNING: cleanup-work-memory: find $WM_DIR で stderr を観測 (permission denied / IO error 等)。残存件数は信頼できません。" >&2
      head -3 "$_find_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
      remaining="unknown"
      [ -n "$_find_err" ] && rm -f "$_find_err"
      break
    else
      remaining=$((remaining + ${_find_out:-0}))
    fi
    [ -n "$_find_err" ] && rm -f "$_find_err"
  fi
done

echo "削除: ${deleted_count} 件, 失敗: ${failed_count} 件, 残存: ${remaining} 件"
exit 0
