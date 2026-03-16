#!/bin/bash
# rite workflow - Session Ownership Helper Library
# Common functions for session_id extraction and ownership checks.
# Sourced by hooks that need to verify flow state ownership.
#
# Functions:
#   extract_session_id <hook_json>  - Extract session_id from hook JSON payload
#   get_state_session_id <file>     - Get session_id from .rite-flow-state
#   check_session_ownership <hook_json> <state_file> - Check if state belongs to current session
#   parse_iso8601_to_epoch <timestamp> - Convert ISO 8601 timestamp to epoch seconds
#
# Usage:
#   source "$SCRIPT_DIR/session-ownership.sh"
#   ownership=$(check_session_ownership "$INPUT" "$STATE_FILE")
#   # ownership: "own" | "legacy" | "other" | "stale"

# Extract session_id from hook JSON payload
# Args: $1 = hook JSON string (from stdin of the hook)
# Output: session_id string, or empty string if not found
extract_session_id() {
  local hook_json="$1"
  local sid
  sid=$(echo "$hook_json" | jq -r '.session_id // empty' 2>/dev/null) || sid=""
  echo "$sid"
}

# Get session_id from .rite-flow-state file
# Args: $1 = path to .rite-flow-state
# Output: session_id string, or empty string if not found/file missing
get_state_session_id() {
  local state_file="$1"
  local sid
  if [ ! -f "$state_file" ]; then
    echo ""
    return 0
  fi
  sid=$(jq -r '.session_id // empty' "$state_file" 2>/dev/null) || sid=""
  echo "$sid"
}

# Check session ownership of .rite-flow-state
# Args: $1 = hook JSON string, $2 = path to .rite-flow-state
# Output: "own" (same session), "legacy" (no session_id in state),
#         "other" (different session, within stale threshold),
#         "stale" (different session, beyond stale threshold)
# Exit code: always 0
#
# Decision matrix:
#   hook session_id empty  → "own" (backward compat: can't determine, assume own)
#   state session_id empty → "legacy" (pre-session-ownership state, treat as own)
#   hook == state          → "own"
#   hook != state:
#     updated_at > 2h ago  → "stale" (safe to overwrite)
#     updated_at <= 2h ago → "other" (active session, do not overwrite)
check_session_ownership() {
  local hook_json="$1"
  local state_file="$2"

  local hook_sid
  hook_sid=$(extract_session_id "$hook_json")

  # If we can't determine our own session_id, assume ownership (backward compat)
  if [ -z "$hook_sid" ]; then
    echo "own"
    return 0
  fi

  local state_sid
  state_sid=$(get_state_session_id "$state_file")

  # No session_id in state = legacy state (pre-session-ownership)
  if [ -z "$state_sid" ]; then
    echo "legacy"
    return 0
  fi

  # Same session
  if [ "$hook_sid" = "$state_sid" ]; then
    echo "own"
    return 0
  fi

  # Different session — check staleness via updated_at
  local updated_at
  updated_at=$(jq -r '.updated_at // empty' "$state_file" 2>/dev/null) || updated_at=""

  if [ -z "$updated_at" ]; then
    # No timestamp = treat as stale (safe to overwrite)
    echo "stale"
    return 0
  fi

  local state_epoch now_epoch diff_seconds
  state_epoch=$(parse_iso8601_to_epoch "$updated_at")
  now_epoch=$(date +%s)
  diff_seconds=$((now_epoch - state_epoch))

  # Stale threshold: 2 hours (7200 seconds)
  if [ "$diff_seconds" -gt 7200 ]; then
    echo "stale"
  else
    echo "other"
  fi
  return 0
}

# Parse ISO 8601 timestamp to epoch seconds
# Moved from stop-guard.sh L83-114 to share across hooks.
# Args: $1 = ISO 8601 timestamp (e.g., "2026-03-16T05:00:00+00:00")
# Output: epoch seconds, or 0 on parse failure
parse_iso8601_to_epoch() {
  local ts="$1"
  local epoch
  # Validate ISO 8601 format before passing to date
  # Supports both +HH:MM/-HH:MM offsets and Z suffix (UTC)
  if ! [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{2}:[0-9]{2})$ ]]; then
    echo 0
    return 0
  fi
  # Normalize Z suffix to +00:00 for consistent parsing
  ts="${ts/%Z/+00:00}"
  # Try GNU date -d first (Linux)
  if epoch=$(date -d "$ts" +%s 2>/dev/null); then
    echo "$epoch"
    return 0
  fi
  # Try macOS date -j -f (strip colon from timezone offset: +09:00 -> +0900)
  local ts_nocolon
  ts_nocolon="${ts%:*}${ts##*:}"
  if epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$ts_nocolon" +%s 2>/dev/null); then
    echo "$epoch"
    return 0
  fi
  # Fallback: return 0 (will be treated as stale)
  echo 0
}
