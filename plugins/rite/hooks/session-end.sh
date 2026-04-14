#!/bin/bash
# rite workflow - Session End Hook
# Saves final state when session ends
set -euo pipefail

# Double-execution guard (hooks.json + settings.local.json migration)
[ -z "${_RITE_HOOK_RUNNING_SESSIONEND:-}" ] || exit 0
export _RITE_HOOK_RUNNING_SESSIONEND=1

# Hook version resolution preamble (must be before INPUT=$(cat) to preserve stdin)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/hook-preamble.sh" 2>/dev/null || true
source "$SCRIPT_DIR/session-ownership.sh" 2>/dev/null || true

# jq is a hard dependency: .rite-flow-state is created by jq, so if jq is
# missing the state file won't exist and the hook exits at the -f check below.
# (Under set -e, a missing jq would exit 127 at the first jq call, before
# reaching -f; the comment describes the logical invariant, not the exit path.)
# cat failure does not abort under set -e; || guard is defensive
INPUT=$(cat) || INPUT=""
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || CWD=""
if [ -z "$CWD" ] || [ ! -d "$CWD" ]; then
  exit 0
fi

# Resolve state file path using state-path-resolve.sh (consistent with other hooks)
# SCRIPT_DIR already set in preamble block above
STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$CWD" 2>/dev/null) || STATE_ROOT="$CWD"
STATE_FILE="$STATE_ROOT/.rite-flow-state"

# Get current branch
BRANCH=$(cd "$CWD" && git branch --show-current 2>/dev/null || echo "")

# Check if on a feature branch with Issue number
if [[ "$BRANCH" =~ issue-([0-9]+) ]]; then
    ISSUE_NUMBER="${BASH_REMATCH[1]}"
    echo "rite: Saving final state for Issue #$ISSUE_NUMBER"
fi

# Deactivate flow state if it exists
if [ -f "$STATE_FILE" ]; then
    # Session ownership check (#173): only deactivate own/legacy/stale state.
    # Other session's fresh state (within 2h) must not be modified.
    _ownership=$(check_session_ownership "$INPUT" "$STATE_FILE" 2>/dev/null) || _ownership="own"
    if [ "$_ownership" = "other" ]; then
        # Another session's active state — do not modify
        echo "rite: skipping deactivation (state belongs to another session)" >&2
        exit 0
    fi

    # /rite:issue:create lifecycle unfinished warning (#475 AC-9).
    # If the session is ending while the create flow is mid-delegation (phase=create_*
    # but not create_completed), emit a warning so the user knows the Issue was NOT
    # created and can re-run /rite:issue:create or use /rite:resume. This is
    # informational only — session-end always proceeds with deactivation.
    _state_phase=$(jq -r '.phase // empty' "$STATE_FILE" 2>/dev/null) || _state_phase=""
    _state_active=$(jq -r '.active // false' "$STATE_FILE" 2>/dev/null) || _state_active="false"
    if [ "$_state_active" = "true" ] && [[ "$_state_phase" == create_* ]] && [ "$_state_phase" != "create_completed" ]; then
        cat >&2 <<WARN_MSG
⚠️  rite: /rite:issue:create lifecycle was not completed (phase=$_state_phase).
    No GitHub Issue was created. The sub-skill delegation flow
    (create-interview → 0.6 → create-register/create-decompose) did not reach completion.
    Re-run /rite:issue:create or use /rite:resume to recover.
WARN_MSG
    fi

    # mktemp with PID-based fallback (consistent with stop-guard.sh)
    TMP_FILE=$(mktemp "${STATE_FILE}.XXXXXX" 2>/dev/null) || TMP_FILE="${STATE_FILE}.tmp.$$"
    # trap is inside this block: only active when STATE_FILE exists and TMP_FILE is created
    trap 'rm -f "$TMP_FILE" 2>/dev/null' EXIT TERM INT
    if jq --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")" \
       '.active = false | .updated_at = $ts' "$STATE_FILE" > "$TMP_FILE"; then
        mv "$TMP_FILE" "$STATE_FILE"
    else
        # Intentionally not exit 1 here (unlike pre-compact.sh) — session-end
        # prioritizes cleanup over strict error propagation
        rm -f "$TMP_FILE"
    fi
fi

# Clean up stale temporary files (older than 1 minute to avoid deleting in-progress writes)
if [ -d "$CWD" ]; then
    find "$CWD" -maxdepth 1 \( -name ".rite-flow-state.tmp.*" -o -name ".rite-flow-state.??????*" \) -type f -mmin +1 -delete 2>/dev/null || true
fi
