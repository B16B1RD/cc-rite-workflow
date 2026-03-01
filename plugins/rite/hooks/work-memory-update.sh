#!/bin/bash
# rite workflow - Work Memory Update (shared helper)
# Provides a function to update local work memory files (.rite-work-memory/issue-{n}.md).
# Handles: lock acquisition, YAML frontmatter parsing, atomic file write, lock release.
#
# Usage (source from another script or inline):
#   source {plugin_root}/hooks/work-memory-update.sh
#   WM_SOURCE="implement" WM_PHASE="phase5_lint" WM_PHASE_DETAIL="品質チェック準備" \
#     WM_NEXT_ACTION="rite:lint を実行" WM_BODY_TEXT="Post-implementation." \
#     WM_PLUGIN_ROOT="/path/to/plugin" \
#     update_local_work_memory
#
# Required environment variables:
#   WM_SOURCE       - Source identifier (e.g., "implement", "lint", "fix")
#   WM_PHASE        - Phase value (e.g., "phase5_lint")
#   WM_PHASE_DETAIL - Phase detail description
#   WM_NEXT_ACTION  - Next action description
#   WM_BODY_TEXT    - Body text after YAML frontmatter closing ---
#   WM_PLUGIN_ROOT  - Absolute path to the plugin root directory
#
# Optional environment variables:
#   WM_ISSUE_NUMBER         - Override issue number detection (skip branch-based parsing).
#                             Use when the caller already knows the issue number (e.g., pre-compact).
#                             (default: extracted from branch name)
#   WM_SKIP_LOCK            - If "true", skip lock acquisition/release. Use when the caller
#                             already holds an outer lock protecting the work memory file.
#                             (default: "false")
#   WM_PR_NUMBER            - PR number override. Effective only when WM_LOOP_INCREMENT != "true"
#                             and WM_READ_FROM_FLOW_STATE != "true". Otherwise, the value is read
#                             from existing WM (fix pattern) or .rite-flow-state (lint pattern).
#                             (default: read from existing WM or "null")
#   WM_LOOP_COUNT           - Loop count override. Same effective conditions as WM_PR_NUMBER.
#                             (default: read from existing WM or 0)
#   WM_LOOP_INCREMENT       - If "true", increment loop_count from existing WM (fix pattern).
#                             When set, WM_PR_NUMBER/WM_LOOP_COUNT overrides are ignored;
#                             values are parsed from the existing work memory file instead.
#                             (default: "false")
#   WM_REQUIRE_FLOW_STATE   - If "true", skip if .rite-flow-state doesn't exist (default: "false")
#   WM_READ_FROM_FLOW_STATE - If "true", read pr_number/loop_count from .rite-flow-state (lint pattern).
#                             When set, overrides WM_PR_NUMBER/WM_LOOP_COUNT and values from existing WM.
#                             (default: "false")
#
# Security note:
#   All WM_* environment variables are written to YAML frontmatter without sanitization.
#   Callers must ensure values do not contain YAML special characters (e.g., newlines,
#   colons followed by spaces, or leading dashes) that could break frontmatter parsing.
#
# Exit codes:
#   0: Success (work memory updated)
#   1: Skipped (no issue number in branch or flow state required but missing)
#   2: Lock acquisition failed (non-fatal, logged as warning)

# Source lock helper at file load time (not inside the function)
# This avoids re-sourcing on every function call and prevents BASH_SOURCE issues.
source "$(dirname "${BASH_SOURCE[0]}")/work-memory-lock.sh"

update_local_work_memory() {
  local issue_number current_branch
  current_branch=$(git branch --show-current 2>/dev/null || echo "")
  issue_number="${WM_ISSUE_NUMBER:-}"
  if [ -n "$issue_number" ] && ! [[ "$issue_number" =~ ^[0-9]+$ ]]; then
    echo "rite: ${WM_SOURCE:-work-memory-update}: invalid WM_ISSUE_NUMBER: $issue_number" >&2
    issue_number=""
  fi
  if [ -z "$issue_number" ]; then
    issue_number=$(echo "$current_branch" | grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+')
  fi
  if [ -z "$issue_number" ]; then
    return 1
  fi

  if [ "${WM_REQUIRE_FLOW_STATE:-false}" = "true" ] && [ ! -f ".rite-flow-state" ]; then
    return 1
  fi

  local local_wm=".rite-work-memory/issue-${issue_number}.md"
  local lockdir="${local_wm}.lockdir"

  # Defensive: ensure parent directory exists before lock acquisition
  mkdir -p .rite-work-memory 2>/dev/null || { echo "rite: ${WM_SOURCE}: failed to create .rite-work-memory directory" >&2; return 2; }
  chmod 700 .rite-work-memory 2>/dev/null || true

  if [ "${WM_SKIP_LOCK:-false}" = "true" ]; then
    :  # Lock skipping; RETURN trap set after mktemp (L132)
  else
    WM_LOCK_STALE_THRESHOLD="${WM_LOCK_STALE_THRESHOLD:-300}"

    if ! acquire_wm_lock "$lockdir"; then
      echo "rite: ${WM_SOURCE}: local work memory lock failed" >&2
      return 2
    fi

    # Ensure lock is released on function return (normal or abnormal exit)
    trap 'release_wm_lock "$lockdir"' RETURN
  fi

  local sync_rev=1
  local loop_cnt="${WM_LOOP_COUNT:-0}"
  local pr_num="${WM_PR_NUMBER:-null}"
  local parse_script="${WM_PLUGIN_ROOT}/hooks/work-memory-parse.py"

  if [ -f "$local_wm" ]; then
    if [ "${WM_LOOP_INCREMENT:-false}" = "true" ]; then
      # fix pattern: parse full output, increment loop_count and sync_revision
      local parse_out=""
      if [ -f "$parse_script" ]; then
        parse_out=$(python3 "$parse_script" "$local_wm" 2>/dev/null) || parse_out=""
      fi
      if [ -n "$parse_out" ]; then
        local parsed
        parsed=$(echo "$parse_out" | jq -r '[(.data.sync_revision // 0) + 1, (.data.loop_count // 0) + 1, (.data.pr_number // "null")] | @tsv' 2>/dev/null) || parsed=""
        if [ -n "$parsed" ]; then
          read -r sync_rev loop_cnt pr_num <<< "$parsed"
        else
          sync_rev=1; loop_cnt=1; pr_num="null"
        fi
      fi
    else
      # implement/lint pattern: just increment sync_revision
      local existing_rev="0"
      if [ -f "$parse_script" ]; then
        existing_rev=$(python3 "$parse_script" "$local_wm" 2>/dev/null | jq -r '.data.sync_revision // 0' 2>/dev/null) || existing_rev="0"
      fi
      if [[ "$existing_rev" =~ ^[0-9]+$ ]]; then sync_rev=$((existing_rev + 1)); fi
    fi
  fi

  # Read from .rite-flow-state if requested (lint pattern)
  if [ "${WM_READ_FROM_FLOW_STATE:-false}" = "true" ] && [ -f ".rite-flow-state" ]; then
    pr_num=$(jq -r '.pr_number // "null"' .rite-flow-state 2>/dev/null) || pr_num="null"
    loop_cnt=$(jq -r '.loop_count // 0' .rite-flow-state 2>/dev/null) || loop_cnt="0"
  fi

  local last_commit tmp_wm
  local branch="$current_branch"
  last_commit=$(git rev-parse --short HEAD 2>/dev/null || echo "")
  tmp_wm=$(mktemp "${local_wm}.tmp.XXXXXX") || { echo "rite: ${WM_SOURCE}: mktemp failed" >&2; return 2; }
  # Extend RETURN trap to also clean up temp file (rm -f is safe even after successful mv)
  if [ "${WM_SKIP_LOCK:-false}" = "true" ]; then
    trap 'rm -f "$tmp_wm"' RETURN
  else
    trap 'rm -f "$tmp_wm"; release_wm_lock "$lockdir"' RETURN
  fi

  {
    printf '# 📜 rite 作業メモリ\n\n'
    printf '## Summary\n'
    printf -- '---\n'
    printf 'schema_version: 1\n'
    printf 'issue_number: %s\n' "$issue_number"
    printf 'sync_revision: %s\n' "$sync_rev"
    printf 'sync_status: pending\n'
    printf 'source: %s\n' "$WM_SOURCE"
    printf 'last_modified_at: "%s"\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    printf 'phase: "%s"\n' "$WM_PHASE"
    printf 'phase_detail: "%s"\n' "$WM_PHASE_DETAIL"
    printf 'next_action: "%s"\n' "$WM_NEXT_ACTION"
    printf 'branch: "%s"\n' "$branch"
    printf 'pr_number: %s\n' "$pr_num"
    printf 'last_commit: "%s"\n' "$last_commit"
    printf 'loop_count: %s\n' "$loop_cnt"
    printf -- '---\n'
    printf '\n%s\n' "$WM_BODY_TEXT"
    printf '\n## Detail\nPhase: %s\nBranch: %s\n' "$WM_PHASE" "$branch"
  } > "$tmp_wm"

  chmod 600 "$tmp_wm" 2>/dev/null || true
  mv "$tmp_wm" "$local_wm"
  return 0
}
