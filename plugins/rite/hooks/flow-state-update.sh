#!/bin/bash
# rite workflow - Flow State Atomic Update
# Deterministic script for atomic .rite-flow-state writes.
# Replaces inline jq + atomic write patterns scattered across command files.
#
# Usage:
#   Create mode (full object with jq -n):
#     bash plugins/rite/hooks/flow-state-update.sh create \
#       --phase phase5_lint --issue 42 --branch "feat/issue-42-test" \
#       --loop 0 --pr 0 --next "Proceed to Phase 5.2.1." [--active true]
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
#   --loop           Loop count (create mode, default: 0)
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

# Resolve repository root
STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$(pwd)" 2>/dev/null) || STATE_ROOT="$(pwd)"
FLOW_STATE="$STATE_ROOT/.rite-flow-state"

# --- Argument parsing ---
MODE="${1:-}"
shift 2>/dev/null || true

PHASE=""
ISSUE=0
BRANCH=""
LOOP=0
PR=0
NEXT=""
ACTIVE=""
IF_EXISTS=false
FIELD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase)    PHASE="$2"; shift 2 ;;
    --issue)    ISSUE="$2"; shift 2 ;;
    --branch)   BRANCH="$2"; shift 2 ;;
    --loop)     LOOP="$2"; shift 2 ;;
    --pr)       PR="$2"; shift 2 ;;
    --next)     NEXT="$2"; shift 2 ;;
    --active)   ACTIVE="$2"; shift 2 ;;
    --if-exists) IF_EXISTS=true; shift ;;
    --field)    FIELD="$2"; shift 2 ;;
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
    if jq -n \
      --argjson active "$ACTIVE" \
      --argjson issue "$ISSUE" \
      --arg branch "$BRANCH" \
      --arg phase "$PHASE" \
      --argjson loop "$LOOP" \
      --argjson pr "$PR" \
      --arg next "$NEXT" \
      --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")" \
      '{active: $active, issue_number: $issue, branch: $branch, phase: $phase, loop_count: $loop, pr_number: $pr, next_action: $next, updated_at: $ts}' \
      > "$TMP_STATE"; then
      mv "$TMP_STATE" "$FLOW_STATE"
    else
      rm -f "$TMP_STATE"
      echo "ERROR: jq create failed" >&2
      exit 1
    fi
    ;;
  patch)
    # Build jq filter: always update phase, timestamp, next_action; conditionally update active
    JQ_FILTER='.phase = $phase | .updated_at = $ts | .next_action = $next'
    JQ_ARGS=(--arg phase "$PHASE" --arg ts "$(date -u +'%Y-%m-%dT%H:%M:%S+00:00')" --arg next "$NEXT")
    if [[ -n "$ACTIVE" ]]; then
      JQ_FILTER="$JQ_FILTER | .active = (\$active_val == \"true\")"
      JQ_ARGS+=(--arg active_val "$ACTIVE")
    fi
    if jq "${JQ_ARGS[@]}" "$JQ_FILTER" "$FLOW_STATE" > "$TMP_STATE"; then
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
