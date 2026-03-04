#!/bin/bash
# rite workflow - Context Pressure Monitor (PostToolUse hook)
# Tracks tool call count and warns when context is growing large.
# Proactive compaction recommendation helps avoid auto-compact triggering
# when system prompt is close to the 200K API token limit (#889).
set -euo pipefail

INPUT=$(cat) || INPUT=""
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$CWD" ] && [ -d "$CWD" ] || exit 0

# Resolve state root (git root or CWD)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$CWD" 2>/dev/null) || STATE_ROOT="$CWD"

FLOW_STATE="$STATE_ROOT/.rite-flow-state"
[ -f "$FLOW_STATE" ] || exit 0

# Only track during active workflows
FLOW_ACTIVE=$(jq -r '.active // false' "$FLOW_STATE" 2>/dev/null) || FLOW_ACTIVE="false"
[ "$FLOW_ACTIVE" = "true" ] || exit 0

COUNTER_FILE="$STATE_ROOT/.rite-context-counter"

# Read current count (0 if file doesn't exist or is unreadable)
count=0
if [ -f "$COUNTER_FILE" ]; then
  count=$(cat "$COUNTER_FILE" 2>/dev/null) || count=0
  # Validate: must be numeric
  if ! [[ "$count" =~ ^[0-9]+$ ]]; then
    count=0
  fi
fi

# Increment
count=$((count + 1))
echo "$count" > "$COUNTER_FILE" 2>/dev/null || true
chmod 600 "$COUNTER_FILE" 2>/dev/null || true

# Warning thresholds
# These are heuristic; actual context size depends on tool result sizes.
# Tool calls are a rough but useful proxy for context growth rate.
YELLOW=60
RED=100

if [ "$count" -eq "$YELLOW" ]; then
  echo "[rite] ⚠️ Context pressure: ${count} tool calls. /compact の実行を検討してください。" >&2
elif [ "$count" -eq "$RED" ]; then
  echo "[rite] 🔴 High context pressure: ${count} tool calls. /compact を強く推奨します（auto-compact による API 上限超過を防止）。" >&2
fi
