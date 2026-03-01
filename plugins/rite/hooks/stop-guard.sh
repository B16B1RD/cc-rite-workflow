#!/bin/bash
# rite workflow - Stop Guard Hook
# Prevents Claude from stopping during an active rite workflow
set -euo pipefail

# jq is a hard dependency: .rite-flow-state is created by jq, so if jq is
# missing the state file won't exist and the hook exits at the -f check below.
# (Under set -e, a missing jq would exit 127 at the first jq call, before
# reaching -f; the comment describes the logical invariant, not the exit path.)
INPUT=$(cat)

CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
if [ -z "$CWD" ] || [ ! -d "$CWD" ]; then
  exit 0
fi

# Resolve state root (git root or CWD) — consistent with pre-compact.sh / session-end.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$CWD" 2>/dev/null) || STATE_ROOT="$CWD"

# Debug logging (enabled by RITE_DEBUG env var, zero overhead when disabled)
log_debug() {
  [ -n "${RITE_DEBUG:-}" ] && echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] stop-guard: $1" >> "$STATE_ROOT/.rite-flow-debug.log" 2>/dev/null || true
}

# Check for active workflow
STATE_FILE="$STATE_ROOT/.rite-flow-state"
if [ ! -f "$STATE_FILE" ]; then
  log_debug "no state file"
  exit 0
fi

# Fail-closed helper: block stop when state file is corrupt/unreadable
# (fail-open was a source of intermittent flow interruptions)
fail_closed() {
  log_debug "$1"
  cat >&2 <<'STOP_MSG'
[rite] Normal operation — stop prevented (state unreadable).
ACTION: Read .rite-flow-state and continue the active workflow. Do NOT stop.
STOP_MSG
  exit 2
}

ACTIVE=$(jq -r '.active // false' "$STATE_FILE" 2>/dev/null) || \
  fail_closed "state parse error on .active"
if [ "$ACTIVE" != "true" ]; then
  log_debug "workflow not active"
  exit 0
fi

# Allow stop when compact has occurred — the LLM should stop and advise user to /clear → /rite:resume
# This check must come after active=true (non-active workflows always allow stop above)
# and before staleness (compact takes priority over age-based expiry).
COMPACT_STATE="$STATE_ROOT/.rite-compact-state"
if [ -f "$COMPACT_STATE" ]; then
  COMPACT_VAL=$(jq -r '.compact_state // "normal"' "$COMPACT_STATE" 2>/dev/null) || COMPACT_VAL="unknown"
  if [ "$COMPACT_VAL" = "blocked" ] || [ "$COMPACT_VAL" = "resuming" ]; then
    log_debug "compact detected (compact_state=$COMPACT_VAL), allowing stop"
    COMPACT_PHASE=$(jq -r '.phase // "unknown"' "$STATE_FILE" 2>/dev/null) || COMPACT_PHASE="unknown"
    COMPACT_ISSUE=$(jq -r '.issue_number // 0' "$STATE_FILE" 2>/dev/null) || COMPACT_ISSUE="0"
    cat >&2 <<STOP_MSG
[rite] Compact detected — stop allowed.
Phase: $COMPACT_PHASE | Issue: #$COMPACT_ISSUE
ACTION: Tell the user to run /clear then /rite:resume to safely resume the workflow.
STOP_MSG
    exit 0
  fi
fi

# Parse ISO 8601 timestamp to epoch seconds (GNU/macOS compatible)
# NOTE: jq's fromdate only supports Z suffix (UTC), not timezone offsets (+HH:MM).
# Since .rite-flow-state uses +00:00 offset (set by pre-compact.sh), we must use date(1)
# to parse the timestamp correctly on both GNU (Linux) and BSD (macOS) systems.
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
  ts_nocolon=$(echo "$ts" | sed 's/\([+-][0-9][0-9]\):\([0-9][0-9]\)$/\1\2/')
  if epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$ts_nocolon" +%s 2>/dev/null); then
    echo "$epoch"
    return 0
  fi
  # Fallback: return 0 (will be treated as stale)
  echo 0
}

# Check staleness (over 2 hours = likely abandoned; extended from 1h to accommodate
# multi-reviewer reviews which can take 60-90 minutes, fixes #719)
UPDATED_AT=$(jq -r '.updated_at // empty' "$STATE_FILE" 2>/dev/null) || \
  fail_closed "state parse error on .updated_at"
if [ -z "$UPDATED_AT" ]; then
  log_debug "no updated_at"
  exit 0
fi

CURRENT=$(date +%s)
STATE_TS=$(parse_iso8601_to_epoch "$UPDATED_AT")
AGE=$(( CURRENT - STATE_TS ))
if [ "$AGE" -gt 7200 ]; then
  log_debug "stale workflow (age=${AGE}s)"
  exit 0
fi

# Extract all fields in a single jq call for efficiency.
# Fail-closed: if jq/read fails, use safe defaults so the stop is still blocked.
# error_count is incremented on each blocked stop; it resets to 0 at the start of the
# next workflow (when /rite:issue:start regenerates .rite-flow-state without error_count)
# or when the user manually resets .rite-flow-state.
IFS=$'\t' read -r PHASE NEXT ISSUE PR ERROR_COUNT < <(jq -r '[(.phase // "unknown"), (.next_action // "unknown"), (.issue_number // 0 | tostring), (.pr_number // 0 | tostring), (.error_count // 0 | tostring)] | @tsv' "$STATE_FILE" 2>/dev/null) || {
  PHASE="unknown"
  NEXT="Read .rite-flow-state and continue the active workflow. Do NOT stop."
  ISSUE="0"
  PR="0"
  ERROR_COUNT="0"
}

# Read error threshold from rite-config.yml (safety.repeated_failure_threshold, default: 3)
THRESHOLD=3
RITE_CONFIG="$STATE_ROOT/rite-config.yml"
if [ -f "$RITE_CONFIG" ]; then
  cfg_val=$(grep -A20 '^safety:' "$RITE_CONFIG" 2>/dev/null | grep 'repeated_failure_threshold' | head -1 | sed 's/.*:[[:space:]]*//' | tr -d '[:space:]' 2>/dev/null || echo "")
  if [[ "$cfg_val" =~ ^[0-9]+$ ]]; then
    THRESHOLD="$cfg_val"
  fi
fi
# Enforce minimum threshold of 1 to prevent accidental always-allow
# (threshold=0 would fire immediately and never block any stops).
[ "$THRESHOLD" -lt 1 ] && THRESHOLD=3

# Allow stop when error_count has reached the threshold — the workflow is stuck in an error loop
if [ "$ERROR_COUNT" -ge "$THRESHOLD" ]; then
  log_debug "error_count=$ERROR_COUNT >= threshold=$THRESHOLD, allowing stop"
  cat >&2 <<STOP_MSG
[rite] Error threshold reached (${ERROR_COUNT} consecutive blocked stops, threshold: ${THRESHOLD}) — stop allowed.
Phase: $PHASE | Issue: #$ISSUE | PR: #$PR
The workflow appears stuck in an error loop. Stopping to prevent infinite repetition.
Reset .rite-flow-state error_count to 0 or set active to false to restore normal stop-guard behavior.
STOP_MSG
  exit 0
fi

# Atomically increment error_count before blocking.
# If the write fails (disk full, permissions), skip silently — the primary goal is protection.
TMP_STATE=$(mktemp "${STATE_FILE}.XXXXXX" 2>/dev/null) || TMP_STATE="${STATE_FILE}.tmp.$$"
trap 'rm -f "$TMP_STATE" 2>/dev/null' TERM INT
if jq --argjson cnt "$((ERROR_COUNT + 1))" '.error_count = $cnt' "$STATE_FILE" > "$TMP_STATE" 2>/dev/null; then
  mv "$TMP_STATE" "$STATE_FILE" 2>/dev/null || rm -f "$TMP_STATE"
else
  rm -f "$TMP_STATE"
fi

# Block the stop (exit 2 + stderr = Claude Code stops the end_turn and feeds stderr to assistant)
log_debug "blocking stop (phase=$PHASE, next=$NEXT, error_count=$((ERROR_COUNT + 1))/$THRESHOLD)"
cat >&2 <<STOP_MSG
[rite] Normal operation — stop prevented.
Phase: $PHASE | Issue: #$ISSUE | PR: #$PR
ACTION: $NEXT
Do NOT re-invoke any completed skill. Do NOT stop.
STOP_MSG
exit 2
