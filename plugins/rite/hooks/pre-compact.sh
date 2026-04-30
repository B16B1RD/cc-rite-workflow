#!/bin/bash
# rite workflow - Pre-Compact Hook
# Sets blocked state and saves work memory snapshot before context compaction.
# compact itself cannot be prevented; this hook records state for safe resumption.
set -euo pipefail

# Double-execution guard (hooks.json + settings.local.json migration)
[ -z "${_RITE_HOOK_RUNNING_PRECOMPACT:-}" ] || exit 0
export _RITE_HOOK_RUNNING_PRECOMPACT=1

# Hook version resolution preamble (must be before INPUT=$(cat) to preserve stdin)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/hook-preamble.sh" 2>/dev/null || true
source "$SCRIPT_DIR/session-ownership.sh" 2>/dev/null || true

# jq is a hard dependency: .rite-flow-state is created by jq, so if jq is
# missing the state file won't exist and the hook exits at the -f check below.
# cat failure does not abort under set -e; || guard is defensive
INPUT=$(cat) || INPUT=""
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || CWD=""
if [ -z "$CWD" ] || [ ! -d "$CWD" ]; then
  exit 0
fi

# Resolve state root (git root or CWD)
# SCRIPT_DIR already set in preamble block above
STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$CWD" 2>/dev/null) || STATE_ROOT="$CWD"

COMPACT_STATE="$STATE_ROOT/.rite-compact-state"
# Resolve active flow-state file path (Issue #680).
# Returns the per-session file when schema_version=2 with a valid SID; otherwise legacy.
FLOW_STATE=$("$SCRIPT_DIR/_resolve-flow-state-path.sh" "$STATE_ROOT" 2>/dev/null) \
  || FLOW_STATE="$STATE_ROOT/.rite-flow-state"
LOCKDIR="$COMPACT_STATE.lockdir"

# --- Cleanup function (covers all temp files) ---
TMP_FILE=""
TMP_COMPACT=""
cleanup() {
  rm -f "$TMP_FILE" "$TMP_COMPACT" 2>/dev/null
  release_wm_lock "$LOCKDIR"
}

# --- Work memory update helper (reuses YAML frontmatter writing logic; also sources work-memory-lock.sh) ---
source "$SCRIPT_DIR/work-memory-update.sh"

trap cleanup EXIT TERM INT

# Session ownership check (#173): skip state updates for other session's state.
# Must run before lock to avoid holding the lock while doing nothing.
if [ -f "$FLOW_STATE" ]; then
  _ownership=$(check_session_ownership "$INPUT" "$FLOW_STATE" 2>/dev/null) || _ownership="own"
  if [ "$_ownership" = "other" ]; then
    exit 0
  fi
fi

# --- All state updates inside lock ---
if acquire_wm_lock "$LOCKDIR"; then
  # Update .rite-flow-state timestamp (inside lock for atomicity)
  if [ -f "$FLOW_STATE" ]; then
    TMP_FILE=$(mktemp "${FLOW_STATE}.XXXXXX" 2>/dev/null) || TMP_FILE="${FLOW_STATE}.tmp.$$"
    if jq --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")" '.updated_at = $ts' "$FLOW_STATE" > "$TMP_FILE"; then
      mv "$TMP_FILE" "$FLOW_STATE"
    else
      rm -f "$TMP_FILE"
    fi
    TMP_FILE=""
  fi

  # Determine active issue from flow state
  ACTIVE_ISSUE="null"
  if [ -f "$FLOW_STATE" ]; then
    ACTIVE_ISSUE=$(jq -r '.issue_number // "null"' "$FLOW_STATE" 2>/dev/null) || ACTIVE_ISSUE="null"
  fi

  # Validate ACTIVE_ISSUE is numeric before --argjson
  if [ "$ACTIVE_ISSUE" != "null" ] && ! [[ "$ACTIVE_ISSUE" =~ ^[0-9]+$ ]]; then
    ACTIVE_ISSUE="null"
  fi

  # If no active issue in flow state, try branch name
  if [ "$ACTIVE_ISSUE" = "null" ]; then
    BRANCH=$(cd "$CWD" && git branch --show-current 2>/dev/null || echo "")
    if [[ "$BRANCH" =~ issue-([0-9]+) ]]; then
      ACTIVE_ISSUE="${BASH_REMATCH[1]}"
    fi
  fi

  # Write compact state — always set to "recovering" regardless of current state (#854, #133)
  # The previous "skip if resuming" guard (#851) was insufficient: when
  # post-compact-guard transitioned blocked→resuming on first denial, a second
  # compact would see "resuming" and skip, leaving all guards permissive.
  # Now PostCompact hook handles auto-recovery (recovering→normal), and pre-compact
  # always sets "recovering" to ensure every compact triggers PostCompact processing.
  TMP_COMPACT=$(mktemp "${COMPACT_STATE}.XXXXXX" 2>/dev/null) || TMP_COMPACT="${COMPACT_STATE}.tmp.$$"
  if jq -n \
    --arg state "recovering" \
    --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --argjson issue "$ACTIVE_ISSUE" \
    '{compact_state: $state, compact_state_set_at: $ts, active_issue: $issue}' \
    > "$TMP_COMPACT" 2>/dev/null; then
    mv "$TMP_COMPACT" "$COMPACT_STATE"
    chmod 600 "$COMPACT_STATE" 2>/dev/null || true
    TMP_COMPACT=""
  else
    rm -f "$TMP_COMPACT"
    TMP_COMPACT=""
    echo "rite: pre-compact: failed to write compact state" >&2
  fi

  # --- Save local work memory snapshot ---
  # Only save snapshot when workflow is actively running (active: true).
  # Without this check, completed workflows (active: false) would get their
  # work memory files recreated on compaction, causing stale file persistence (#776).
  FLOW_ACTIVE=$(jq -r '.active // false' "$FLOW_STATE" 2>/dev/null) || FLOW_ACTIVE="false"
  if [ "$FLOW_ACTIVE" = "true" ] && [ "$ACTIVE_ISSUE" != "null" ] && [ -f "$FLOW_STATE" ]; then
    # Read phase and next_action from flow state for env vars
    # cycle 12 MEDIUM F-04: unit separator 統一 (stop-guard.sh cycle 10 F-01 と同型の原則準拠)。
    # next_action が trailing position のため現状 field shift は発生しないが、将来の field 追加で
    # fragile になるため cycle 11 で確立した「@tsv + IFS=$'\t' 禁止」原則に揃える。
    FLOW_DATA=$(jq -r '[.phase // "unknown", .pr_number // "null", .loop_count // 0, .next_action // ""] | join("\u001f")' "$FLOW_STATE" 2>/dev/null) || FLOW_DATA=""
    if [ -n "$FLOW_DATA" ]; then
      IFS=$'\x1f' read -r PHASE PR_NUM LOOP_CNT NEXT_ACT <<< "$FLOW_DATA"
    else
      PHASE="unknown"
      PR_NUM="null"
      LOOP_CNT="0"
      NEXT_ACT=""
    fi

    # Delegate to shared helper (runs in subshell to isolate cd)
    (
      cd "$STATE_ROOT" || exit 1
      WM_ISSUE_NUMBER="$ACTIVE_ISSUE" \
      WM_SKIP_LOCK="true" \
      WM_SOURCE="pre_compact" \
      WM_PHASE="$PHASE" \
      WM_PHASE_DETAIL="compact 前 snapshot" \
      WM_NEXT_ACTION="$NEXT_ACT" \
      WM_BODY_TEXT="Pre-compact snapshot. PostCompact will auto-recover." \
      WM_PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")" \
      WM_PR_NUMBER="$PR_NUM" \
      WM_LOOP_COUNT="$LOOP_CNT" \
        update_local_work_memory
    ) || echo "rite: pre-compact: work memory update failed (exit $?)" >&2
  fi

  release_wm_lock "$LOCKDIR"
fi

# Output advisory message only when workflow is active (#842, #776)
# FLOW_ACTIVE is set inside the lock block; defaults to "false" if lock was not acquired.
if [ "${FLOW_ACTIVE:-false}" = "true" ]; then
  # Provide defaults: PHASE may be unset when ACTIVE_ISSUE is null (line 96 guard)
  _ISSUE="${ACTIVE_ISSUE:-unknown}"
  _PHASE="${PHASE:-unknown}"

  # stderr: displayed directly to user's terminal (guaranteed visibility)
  echo "[rite] ⚠️ compact detected (Issue #${_ISSUE}, Phase: ${_PHASE}). Auto-recovery will proceed via PostCompact." >&2

  # stdout: fed to model as hook output (#887, #889)
  # Minimal message to reduce post-compaction token overhead.
  # System prompt alone is ~200K tokens; every token saved here helps stay under API limit.
  # PostCompact hook will restore full context after compaction completes.
  echo "STOP. Compact detected. Issue #${_ISSUE}. PostCompact will restore context. STOP."
fi
