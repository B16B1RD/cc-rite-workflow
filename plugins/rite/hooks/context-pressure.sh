#!/bin/bash
# rite workflow - Context Pressure Monitor (PostToolUse hook)
# Tracks tool call count and warns when context is growing large.
# Proactive compaction recommendation helps avoid auto-compact triggering
# when system prompt is close to the 200K API token limit (#889).
#
# Phase-aware graduated response (#80):
# - YELLOW: Warning + output minimization hint
# - ORANGE: Strong warning + optimization mode activation
# - RED: Critical warning + flow split recommendation
set -euo pipefail

# Double-execution guard (hooks.json + settings.local.json migration)
[ -z "${_RITE_HOOK_RUNNING_CTXPRESSURE:-}" ] || exit 0
export _RITE_HOOK_RUNNING_CTXPRESSURE=1

# Hook version resolution preamble (must be before INPUT=$(cat) to preserve stdin)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/hook-preamble.sh" 2>/dev/null || true
source "$SCRIPT_DIR/session-ownership.sh" 2>/dev/null || true

# cat failure does not abort under set -e; || guard is defensive
INPUT=$(cat) || INPUT=""
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$CWD" ] && [ -d "$CWD" ] || exit 0

# Resolve state root (git root or CWD)
# SCRIPT_DIR already set in preamble block above
STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$CWD" 2>/dev/null) || STATE_ROOT="$CWD"

FLOW_STATE="$STATE_ROOT/.rite-flow-state"
[ -f "$FLOW_STATE" ] || exit 0

# Read active state and phase in a single jq call
FLOW_DATA=$(jq -r '[.active // false, .phase // "unknown"] | @tsv' "$FLOW_STATE" 2>/dev/null) || FLOW_DATA=""
if [ -n "$FLOW_DATA" ]; then
  IFS=$'\t' read -r FLOW_ACTIVE PHASE <<< "$FLOW_DATA"
else
  FLOW_ACTIVE="false"
  PHASE="unknown"
fi

# Only track during active workflows
[ "$FLOW_ACTIVE" = "true" ] || exit 0

# Session ownership check (#173): skip counter operations for other session's state
# to prevent non-atomic read-modify-write counter corruption across concurrent sessions
_ownership=$(check_session_ownership "$INPUT" "$FLOW_STATE" 2>/dev/null) || _ownership="own"
[ "$_ownership" != "other" ] || exit 0

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

# PHASE is already set from the single jq call above (line 26)

# Default thresholds (used for early return check before config read)
BASE_YELLOW=60
BASE_ORANGE=90
BASE_RED=120

# Early return: skip config read and phase adjustment when count is below thresholds
# This avoids python3 startup cost on every tool call (#80 performance review)
# Note: Only lower bound check. Upper bound removed to ensure RED warning always fires (#80 review fix)
if [ "$count" -lt "$((BASE_YELLOW - 10))" ]; then
  exit 0
fi

# Read configurable thresholds from rite-config.yml (fallback to defaults)
# Pre-check: skip python3 startup (~50-100ms) when config has no pressure_thresholds key (#86)
CONFIG_FILE="$STATE_ROOT/rite-config.yml"
if [ -f "$CONFIG_FILE" ] && grep -q 'pressure_thresholds' "$CONFIG_FILE" && command -v python3 >/dev/null 2>&1; then
  THRESHOLDS=$(python3 -c '
import yaml, sys
try:
    with open(sys.argv[1]) as f:
        cfg = yaml.safe_load(f) or {}
    co = cfg.get("context_optimization", {}).get("pressure_thresholds", {})
    print(co.get("yellow", 60), co.get("orange", 90), co.get("red", 120))
except Exception:
    print("60 90 120")
' "$CONFIG_FILE" 2>/dev/null) || THRESHOLDS=""
  if [ -n "$THRESHOLDS" ]; then
    read -r BASE_YELLOW BASE_ORANGE BASE_RED <<< "$THRESHOLDS"
    # Validate all values are positive integers (security: prevent arithmetic injection)
    [[ "$BASE_YELLOW" =~ ^[0-9]+$ ]] || BASE_YELLOW=60
    [[ "$BASE_ORANGE" =~ ^[0-9]+$ ]] || BASE_ORANGE=90
    [[ "$BASE_RED" =~ ^[0-9]+$ ]]    || BASE_RED=120
  fi
fi

# Phase-aware threshold adjustment:
# - Implementation phase (phase5_implementation): Higher thresholds (+10, more tool calls expected)
# - Review/fix phase (phase5_review, phase5_fix): Lower thresholds (-10, already deep in context)
# - Other phases: Default thresholds
case "$PHASE" in
  phase5_implementation|phase5_lint)
    YELLOW=$((BASE_YELLOW + 10))
    ORANGE=$((BASE_ORANGE + 10))
    RED=$((BASE_RED + 10))
    ;;
  phase5_review|phase5_fix|phase5_post_review|phase5_post_fix)
    YELLOW=$((BASE_YELLOW - 10))
    ORANGE=$((BASE_ORANGE - 10))
    RED=$((BASE_RED - 10))
    ;;
  *)
    YELLOW=$BASE_YELLOW
    ORANGE=$BASE_ORANGE
    RED=$BASE_RED
    ;;
esac

# Graduated response (each threshold triggers exactly once)
if [ "$count" -eq "$YELLOW" ]; then
  echo "[rite] ⚠️ Context pressure: ${count} tool calls (phase: ${PHASE}). 出力を簡潔にしてください。" >&2
elif [ "$count" -eq "$ORANGE" ]; then
  # stdout: hint to model for output optimization
  echo "[rite] Context optimization mode activated. Minimize all output. Skip optional displays. Use result patterns only."
  echo "[rite] 🟠 High context pressure: ${count} tool calls. 出力最小化モードに切り替えてください。" >&2
elif [ "$count" -eq "$RED" ]; then
  echo "[rite] CRITICAL: Context limit approaching. Complete current phase and prepare for /compact. Save state to work memory NOW."
  echo "[rite] 🔴 Critical context pressure: ${count} tool calls. /compact を強く推奨します。" >&2
fi
