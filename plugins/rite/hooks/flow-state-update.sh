#!/bin/bash
# rite workflow - Flow State Atomic Update
# Deterministic script for atomic .rite-flow-state writes.
# Replaces inline jq + atomic write patterns scattered across command files.
#
# Usage:
#   Create mode (full object with jq -n):
#     bash plugins/rite/hooks/flow-state-update.sh create \
#       --phase phase5_lint --issue 42 --branch "feat/issue-42-test" \
#       --pr 0 --next "Proceed to Phase 5.2.1." [--active true]
#
#   Patch mode (update fields in existing file):
#     bash plugins/rite/hooks/flow-state-update.sh patch \
#       --phase phase5_post_lint --next "Proceed to next phase." [--active true] [--if-exists]
#
#   Increment mode (increment a numeric field):
#     bash plugins/rite/hooks/flow-state-update.sh increment \
#       --field implementation_round [--if-exists]
#
# Options:
#   --phase          Phase value (required for create/patch)
#   --issue          Issue number (create mode, default: 0)
#   --branch         Branch name (create mode, default: "")
#   --pr             PR number (create mode, default: 0)
#   --next           next_action text (required for create/patch)
#   --active         Active flag (create mode: default true; patch mode: update only if specified)
#   --field          Field name to increment (increment mode)
#   --if-exists      Only execute if .rite-flow-state exists (patch/increment mode)
#
# Exit codes:
#   0: Success
#   0: Skipped (--if-exists and file does not exist)
#   1: Argument error or jq failure
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source session ownership helper for stale detection in create mode
source "$SCRIPT_DIR/session-ownership.sh" 2>/dev/null || true

# Resolve repository root
STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$(pwd)" 2>/dev/null) || STATE_ROOT="$(pwd)"
FLOW_STATE="$STATE_ROOT/.rite-flow-state"

# --- Argument parsing ---
MODE="${1:-}"
shift 2>/dev/null || true

PHASE=""
ISSUE=0
BRANCH=""
PR=0
NEXT=""
ACTIVE=""
IF_EXISTS=false
FIELD=""
SESSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase)    PHASE="$2"; shift 2 ;;
    --issue)    ISSUE="$2"; shift 2 ;;
    --branch)   BRANCH="$2"; shift 2 ;;
    --pr)       PR="$2"; shift 2 ;;
    --next)     NEXT="$2"; shift 2 ;;
    --active)   ACTIVE="$2"; shift 2 ;;
    --if-exists) IF_EXISTS=true; shift ;;
    --field)    FIELD="$2"; shift 2 ;;
    --session)  SESSION="$2"; shift 2 ;;
    *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
  esac
done

# --- Validation ---
case "$MODE" in
  create)
    if [[ -z "$PHASE" || -z "$NEXT" ]]; then
      echo "ERROR: create mode requires --phase and --next" >&2
      exit 1
    fi
    ;;
  patch)
    if [[ -z "$PHASE" || -z "$NEXT" ]]; then
      echo "ERROR: patch mode requires --phase and --next" >&2
      exit 1
    fi
    if [[ "$IF_EXISTS" == true && ! -f "$FLOW_STATE" ]]; then
      exit 0
    fi
    ;;
  increment)
    if [[ -z "$FIELD" ]]; then
      echo "ERROR: increment mode requires --field" >&2
      exit 1
    fi
    if [[ "$IF_EXISTS" == true && ! -f "$FLOW_STATE" ]]; then
      exit 0
    fi
    ;;
  *)
    echo "ERROR: Unknown mode: $MODE (expected: create, patch, increment)" >&2
    exit 1
    ;;
esac

# --- Atomic write ---
TMP_STATE="${FLOW_STATE}.tmp.$$"

case "$MODE" in
  create)
    # Default active to true if not explicitly specified
    if [[ -z "$ACTIVE" ]]; then
      ACTIVE="true"
    fi
    # Auto-read session_id from .rite-session-id if --session was not provided or is empty (#216)
    if [[ -z "$SESSION" ]]; then
      _session_id_file="$STATE_ROOT/.rite-session-id"
      SESSION=$(cat "$_session_id_file" 2>/dev/null | tr -d '[:space:]') || SESSION=""
      # Validate UUID format (reject tampered or corrupt content)
      if [[ -n "$SESSION" && ! "$SESSION" =~ ^[0-9a-f-]{36}$ ]]; then
        SESSION=""
      fi
    fi
    # Session ownership: overwrite protection for active state owned by another session
    if [[ -n "$SESSION" && -f "$FLOW_STATE" ]]; then
      _existing_active=$(jq -r '.active // false' "$FLOW_STATE" 2>/dev/null) || _existing_active="false"
      if [[ "$_existing_active" == "true" ]]; then
        _existing_sid=$(get_state_session_id "$FLOW_STATE" 2>/dev/null) || _existing_sid=""
        if [[ -n "$_existing_sid" && "$_existing_sid" != "$SESSION" ]]; then
          # Different session owns the state — check staleness
          _updated_at=$(jq -r '.updated_at // empty' "$FLOW_STATE" 2>/dev/null) || _updated_at=""
          if [[ -n "$_updated_at" ]]; then
            _state_epoch=$(parse_iso8601_to_epoch "$_updated_at" 2>/dev/null) || _state_epoch=0
            _now_epoch=$(date +%s)
            _diff=$((_now_epoch - _state_epoch))
            if [[ "$_diff" -le 7200 ]]; then
              echo "ERROR: 別のワークフローが進行中です（2時間以内に更新）。" >&2
              echo "INFO: 上書きするには先に /rite:resume で所有権を移転するか、2時間待ってください。" >&2
              exit 1
            fi
          fi
        fi
      fi
    fi
    # Capture previous phase for whitelist-based transition verification (#490).
    # When the existing state file is absent or malformed, previous_phase is "" —
    # stop-guard treats empty previous_phase as "workflow start" (always valid).
    PREV_PHASE=""
    if [[ -f "$FLOW_STATE" ]]; then
      PREV_PHASE=$(jq -r '.phase // ""' "$FLOW_STATE" 2>/dev/null) || PREV_PHASE=""
    fi
    if jq -n \
      --argjson active "$ACTIVE" \
      --argjson issue "$ISSUE" \
      --arg branch "$BRANCH" \
      --arg phase "$PHASE" \
      --arg prev_phase "$PREV_PHASE" \
      --argjson pr "$PR" \
      --arg next "$NEXT" \
      --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")" \
      --arg sid "$SESSION" \
      '{active: $active, issue_number: $issue, branch: $branch, phase: $phase, previous_phase: $prev_phase, pr_number: $pr, next_action: $next, updated_at: $ts, session_id: $sid, last_synced_phase: ""}' \
      > "$TMP_STATE"; then
      mv "$TMP_STATE" "$FLOW_STATE"
    else
      rm -f "$TMP_STATE"
      echo "ERROR: jq create failed" >&2
      exit 1
    fi
    ;;
  patch)
    # Build jq filter: always update phase, timestamp, next_action; conditionally update active.
    # Also capture the outgoing phase into previous_phase so stop-guard can verify the
    # transition whitelist (#490). Use the pre-update .phase value as previous_phase.
    JQ_FILTER='.previous_phase = (.phase // "") | .phase = $phase | .updated_at = $ts | .next_action = $next | .error_count = 0'
    JQ_ARGS=(--arg phase "$PHASE" --arg ts "$(date -u +'%Y-%m-%dT%H:%M:%S+00:00')" --arg next "$NEXT")
    if [[ -n "$ACTIVE" ]]; then
      JQ_FILTER="$JQ_FILTER | .active = (\$active_val == \"true\")"
      JQ_ARGS+=(--arg active_val "$ACTIVE")
    fi
    if jq "${JQ_ARGS[@]}" -- "$JQ_FILTER" "$FLOW_STATE" > "$TMP_STATE"; then
      mv "$TMP_STATE" "$FLOW_STATE"
    else
      rm -f "$TMP_STATE"
      echo "ERROR: jq patch failed" >&2
      exit 1
    fi
    ;;
  increment)
    if jq --arg field "$FIELD" \
       '.[$field] = ((.[$field] // 0) + 1)' \
       "$FLOW_STATE" > "$TMP_STATE"; then
      mv "$TMP_STATE" "$FLOW_STATE"
    else
      rm -f "$TMP_STATE"
      echo "ERROR: jq increment failed" >&2
      exit 1
    fi
    ;;
esac
