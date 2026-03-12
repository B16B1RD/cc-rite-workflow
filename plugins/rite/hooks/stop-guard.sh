#!/bin/bash
# rite workflow - Stop Guard Hook
# Prevents Claude from stopping during an active rite workflow
set -euo pipefail

# Hook version resolution preamble (must be before INPUT=$(cat) to preserve stdin)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/hook-preamble.sh" 2>/dev/null || true

# jq is a hard dependency: .rite-flow-state is created by jq, so if jq is
# missing the state file won't exist and the hook exits at the -f check below.
# (Under set -e, a missing jq would exit 127 at the first jq call, before
# reaching -f; the comment describes the logical invariant, not the exit path.)
# cat failure does not abort under set -e; || guard is defensive
INPUT=$(cat) || INPUT=""

CWD=$(jq -r '.cwd // empty' <<< "$INPUT")
if [ -z "$CWD" ] || [ ! -d "$CWD" ]; then
  exit 0
fi

# Resolve state root (git root or CWD) — consistent with pre-compact.sh / session-end.sh
# SCRIPT_DIR already set in preamble block above
STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$CWD" 2>/dev/null) || STATE_ROOT="$CWD"

# Debug logging (enabled by RITE_DEBUG env var, zero overhead when disabled)
log_debug() {
  [ -n "${RITE_DEBUG:-}" ] && echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] stop-guard: $1" >> "$STATE_ROOT/.rite-flow-debug.log" 2>/dev/null || true
}

# Diagnostic logging (always enabled, exit points only, ~100 bytes per entry)
# Output: $STATE_ROOT/.rite-stop-guard-diag.log (ring buffer: 50 lines max)
# .gitignore の *.log で自動除外済み
log_diag() {
  local diag_file="$STATE_ROOT/.rite-stop-guard-diag.log"
  local _tmp_diag=""
  trap '[ -n "$_tmp_diag" ] && rm -f "$_tmp_diag" 2>/dev/null; true' RETURN
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $1" >> "$diag_file" 2>/dev/null || true
  # Ring buffer: truncate to last 50 lines (mapfile avoids wc -l subshell)
  if [ -f "$diag_file" ]; then
    local -a _lines
    mapfile -t _lines < "$diag_file" 2>/dev/null || true
    if [ "${#_lines[@]}" -gt 50 ]; then
      # fallback to PID-based name if mktemp fails (e.g., disk full, permission denied)
      _tmp_diag=$(mktemp "${diag_file}.XXXXXX" 2>/dev/null) || _tmp_diag="${diag_file}.tmp.$$"
      printf '%s\n' "${_lines[@]: -50}" > "$_tmp_diag" 2>/dev/null && mv "$_tmp_diag" "$diag_file" 2>/dev/null || { rm -f "$_tmp_diag" 2>/dev/null; true; }
    fi
  fi
}

# Check for active workflow
STATE_FILE="$STATE_ROOT/.rite-flow-state"
if [ ! -f "$STATE_FILE" ]; then
  log_debug "no state file"
  log_diag "EXIT:0 reason=no_state_file"
  exit 0
fi

# Fail-closed helper: block stop when state file is corrupt/unreadable
# (fail-open was a source of intermittent flow interruptions)
fail_closed() {
  log_debug "$1"
  log_diag "EXIT:2 reason=fail_closed detail=$1"
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
  log_diag "EXIT:0 reason=not_active"
  exit 0
fi

# compact_state check: allow stop immediately when blocked to prevent deadlock (#30).
# Supersedes AC-6 behavior (previously: block stop even when compact_state=blocked).
# When compact_state is "blocked", post-compact-guard denies ALL tool uses.
# If stop-guard also blocks stop, the workflow enters a deadlock until error_count
# threshold is reached (multiple wasted rounds, 11+ minutes stuck).
# Fix: allow stop immediately when "blocked" so the user can /clear → /rite:resume.
# "resuming" state: keep blocking stop (normal workflow recovery in progress).
COMPACT_STATE="$STATE_ROOT/.rite-compact-state"
if [ -f "$COMPACT_STATE" ]; then
  COMPACT_VAL=$(jq -r '.compact_state // "normal"' "$COMPACT_STATE" 2>/dev/null) || COMPACT_VAL="unknown"
  if [ "$COMPACT_VAL" = "blocked" ]; then
    log_debug "compact_state=blocked, allowing stop to prevent deadlock (#30)"
    log_diag "EXIT:0 reason=compact_blocked"
    cat >&2 <<'STOP_MSG'
[rite] compact 検出 — stop を許可します。
/clear → /rite:resume で作業を再開してください。
STOP_MSG
    exit 0
  elif [ "$COMPACT_VAL" = "resuming" ]; then
    log_debug "compact detected (compact_state=resuming), stop still blocked"
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
  # Strip colon from timezone offset: +09:00 -> +0900 (bash parameter expansion avoids sed subshell)
  # e.g. ts="2026-03-04T00:04:17+09:00"
  #   ${ts%:*}  -> "2026-03-04T00:04:17+09"  (remove shortest suffix matching :*)
  #   ${ts##*:} -> "00"                       (remove longest prefix matching *:)
  #   result    -> "2026-03-04T00:04:17+0900"
  # Requires: ts has already passed the regex validation above (line 102)
  ts_nocolon="${ts%:*}${ts##*:}"
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
  log_diag "EXIT:0 reason=no_updated_at"
  exit 0
fi

CURRENT=$(date +%s)
STATE_TS=$(parse_iso8601_to_epoch "$UPDATED_AT")
AGE=$(( CURRENT - STATE_TS ))
if [ "$AGE" -gt 7200 ]; then
  log_debug "stale workflow (age=${AGE}s)"
  log_diag "EXIT:0 reason=stale age=${AGE}s"
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
  # awk: ^safety: セクション内を動的に抽出（次のトップレベルキーまで）
  cfg_val=$(awk '/^safety:/{f=1;next} f && /^[^[:space:]]/{exit} f && /repeated_failure_threshold/' "$RITE_CONFIG" 2>/dev/null | head -1 | sed 's/.*:[[:space:]]*//' | tr -d '[:space:]' 2>/dev/null || echo "")
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
  log_diag "EXIT:0 reason=error_threshold error_count=$ERROR_COUNT threshold=$THRESHOLD"
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
trap 'rm -f "$TMP_STATE" 2>/dev/null' EXIT TERM INT
if jq --argjson cnt "$((ERROR_COUNT + 1))" '.error_count = $cnt' "$STATE_FILE" > "$TMP_STATE" 2>/dev/null; then
  mv "$TMP_STATE" "$STATE_FILE" 2>/dev/null || rm -f "$TMP_STATE"
else
  rm -f "$TMP_STATE"
fi

# Block the stop (exit 2 + stderr = Claude Code stops the end_turn and feeds stderr to assistant)
log_debug "blocking stop (phase=$PHASE, next=$NEXT, error_count=$((ERROR_COUNT + 1))/$THRESHOLD)"
log_diag "EXIT:2 reason=blocking phase=$PHASE issue=#$ISSUE error_count=$((ERROR_COUNT + 1))/$THRESHOLD"
cat >&2 <<STOP_MSG
[rite] Normal operation — stop prevented.
Phase: $PHASE | Issue: #$ISSUE | PR: #$PR
ACTION: $NEXT
Do NOT re-invoke any completed skill. Do NOT stop.
STOP_MSG
exit 2
