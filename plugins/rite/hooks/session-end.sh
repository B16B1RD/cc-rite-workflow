#!/bin/bash
# rite workflow - Session End Hook
# Saves final state when session ends
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

# Resolve state file path using state-path-resolve.sh (consistent with other hooks)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
    # PID-based temp file: simpler than mktemp, sufficient for single-process hook
    # execution.  The file is created in the project CWD (owned by the developer),
    # so symlink-based attacks against /tmp do not apply.
    TMP_FILE="${STATE_FILE}.tmp.$$"
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
    find "$CWD" -maxdepth 1 -name ".rite-flow-state.tmp.*" -type f -mmin +1 -delete 2>/dev/null || true
fi
