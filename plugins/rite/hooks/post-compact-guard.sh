#!/bin/bash
# rite workflow - Post-Compact Tool Guard (PreToolUse hook)
# Blocks ALL tool uses after compaction until user runs /clear → /rite:resume.
set -euo pipefail

# cat failure does not abort under set -e; || guard is defensive
INPUT=$(cat) || INPUT=""
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
if [ -z "$CWD" ] || [ ! -d "$CWD" ]; then
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$CWD" 2>/dev/null) || STATE_ROOT="$CWD"
COMPACT_STATE="$STATE_ROOT/.rite-compact-state"

if [ ! -f "$COMPACT_STATE" ]; then
  exit 0
fi

# Self-healing: if flow is not active (or absent), compact state is stale → clean up and allow (#800)
FLOW_STATE="$STATE_ROOT/.rite-flow-state"
if [ ! -f "$FLOW_STATE" ]; then
  rm -f "$COMPACT_STATE" 2>/dev/null || true
  exit 0
fi
# Fail-open: if jq cannot parse .rite-flow-state (corrupt/truncated file), default to
# "false" so compact state is treated as stale and cleaned up below. This is intentional:
# a corrupt flow-state means the workflow likely isn't running properly, so allowing tool
# use (fail-open) is safer than blocking the user indefinitely (fail-closed).
# (Contrast with stop-guard.sh which uses fail-closed — blocking a stop is less disruptive
# than blocking all tool use.)
FLOW_ACTIVE=$(jq -r '.active // false' "$FLOW_STATE" 2>/dev/null) || FLOW_ACTIVE="false"
if [ "$FLOW_ACTIVE" != "true" ]; then
  rm -f "$COMPACT_STATE" 2>/dev/null || true
  exit 0
fi

COMPACT_VAL=$(jq -r '.compact_state // "normal"' "$COMPACT_STATE" 2>/dev/null) || COMPACT_VAL="unknown"
GUIDANCE_FLAG="$STATE_ROOT/.rite-guidance-shown"

# normal or resuming → allow (clean up guidance flag)
if [ "$COMPACT_VAL" = "normal" ] || [ "$COMPACT_VAL" = "resuming" ]; then
  rm -f "$GUIDANCE_FLAG" 2>/dev/null || true
  exit 0
fi

# blocked or unknown (fail-closed) → deny ALL tool calls, stay blocked (#854)
# Do NOT transition to "resuming" here. Only /clear (via session-start.sh) should
# transition to "resuming". This prevents the LLM from generating massive text output
# after a one-shot denial, which can trigger a second auto-compact where all guards
# see "resuming" and allow tool use — causing the re-compact loop.
PHASE=$(jq -r '.phase // "unknown"' "$FLOW_STATE" 2>/dev/null) || PHASE="unknown"
ISSUE=$(jq -r '.issue_number // 0 | tostring' "$FLOW_STATE" 2>/dev/null) || ISSUE="0"

# stderr: displayed directly to user's terminal (show only once per compact event)
if [ ! -f "$GUIDANCE_FLAG" ]; then
  echo "[rite] ⚠️ compact 後ブロック中。Phase: $PHASE | Issue: #$ISSUE" >&2
  echo "[rite] /clear → /rite:resume で再開してください。" >&2
  touch "$GUIDANCE_FLAG" 2>/dev/null || true
fi

# Deny this tool use and instruct LLM to stop.
# compact_state stays "blocked" so ALL subsequent tool calls are also denied.
# When compact_state is blocked, stop-guard.sh allows stop to prevent deadlock (#30).
# Minimal deny reason to reduce token overhead (#889).
jq -n \
  --arg issue "$ISSUE" \
  '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: ("COMPACT BLOCK #" + $issue + ". Say: /clear then /rite:resume. STOP.")
    }
  }'
