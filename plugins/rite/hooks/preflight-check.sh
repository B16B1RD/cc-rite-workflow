#!/bin/bash
# rite workflow - Preflight Check
# Guards all /rite:* commands. Blocks execution when compact_state != normal.
# Only /rite:resume is allowed when blocked.
#
# Usage:
#   plugins/rite/hooks/preflight-check.sh --command-id "/rite:issue:start" --cwd "$PWD"
#
# Exit codes:
#   0: Allowed (proceed with command)
#   1: Blocked (do not execute command)
set -euo pipefail

# Parse arguments
COMMAND_ID=""
CWD=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --command-id) COMMAND_ID="$2"; shift 2 ;;
    --cwd) CWD="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [ -z "$CWD" ]; then
  CWD="$(pwd)"
fi

if [ ! -d "$CWD" ]; then
  # Invalid CWD — allow (fail-open for non-existent dirs)
  exit 0
fi

# Resolve state root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$CWD" 2>/dev/null) || STATE_ROOT="$CWD"

COMPACT_STATE="$STATE_ROOT/.rite-compact-state"

# File not present → normal (allow)
if [ ! -f "$COMPACT_STATE" ]; then
  exit 0
fi

# Read compact_state and compact_state_set_at in a single jq call
COMPACT_DATA=$(jq -r '[.compact_state // "unknown", .compact_state_set_at // ""] | @tsv' "$COMPACT_STATE" 2>/dev/null) || {
  # JSON parse error → blocked (fail-closed, safety-side)
  echo "⚠️ .rite-compact-state の読み取りに失敗しました。compact 後の状態が不明です。"
  echo "ACTION: /clear を実行してから /rite:resume で復帰してください。"
  exit 1
}
# IFS is command-scoped here (not global); only affects this read invocation
IFS=$'\t' read -r COMPACT_VAL SET_AT_TS <<< "$COMPACT_DATA"

GUIDANCE_FLAG="$STATE_ROOT/.rite-guidance-shown"

# normal → allow (clean up guidance flag)
if [ "$COMPACT_VAL" = "normal" ]; then
  rm -f "$GUIDANCE_FLAG" 2>/dev/null || true
  exit 0
fi

# resuming → always allow (clean up guidance flag)
# resume.md Phase 3.0 runs Steps 1-3 sequentially before Skill invocation,
# so "resuming" is only a transient intermediate state.
# Orphaned "resuming" (e.g., from a crash) is cleaned up by session-start.sh startup cleanup.
if [ "$COMPACT_VAL" = "resuming" ]; then
  rm -f "$GUIDANCE_FLAG" 2>/dev/null || true
  exit 0
fi

# Not normal → check if command is /rite:resume
if [ "$COMMAND_ID" = "/rite:resume" ]; then
  # /rite:resume is always allowed
  exit 0
fi

# Blocked: reject all other commands — read both fields in a single jq call
BLOCKED_INFO=$(jq -r '[.active_issue // "不明", .compact_state_set_at // "不明"] | @tsv' "$COMPACT_STATE" 2>/dev/null) || BLOCKED_INFO=""
if [ -n "$BLOCKED_INFO" ]; then
  IFS=$'\t' read -r ACTIVE_ISSUE SET_AT <<< "$BLOCKED_INFO"
else
  ACTIVE_ISSUE="不明"
  SET_AT="不明"
fi

if [ ! -f "$GUIDANCE_FLAG" ]; then
  cat <<EOF
⚠️ compact が検出されたため、コマンドの実行がブロックされました。

状態: ${COMPACT_VAL}
検出時刻: ${SET_AT}
Issue: #${ACTIVE_ISSUE}
ブロックされたコマンド: ${COMMAND_ID}

ACTION: /clear を実行してから /rite:resume で復帰してください。
EOF
  touch "$GUIDANCE_FLAG" 2>/dev/null || true
else
  echo "⚠️ compact ブロック中（Issue: #${ACTIVE_ISSUE}）。/clear → /rite:resume で再開してください。"
fi
exit 1
