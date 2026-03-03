#!/bin/bash
# rite workflow - Session Start Hook
# Re-injects flow state after compact or resume
set -euo pipefail

# jq is a hard dependency: .rite-flow-state is created by jq, so if jq is
# missing the state file won't exist and the hook exits at the -f check below.
# (Under set -e, a missing jq would exit 127 at the first jq call, before
# reaching -f; the comment describes the logical invariant, not the exit path.)
INPUT=$(cat)

# Plugin dual-load collision guard (#591)
# Only warn when this script is running from a local plugin-dir (not from
# the marketplace cache). Normal marketplace users should have it enabled.
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$SCRIPT_PATH" != *"/.claude/plugins/cache/"* ]] && command -v jq &>/dev/null; then
  settings_file="$HOME/.claude/settings.json"
  if [ -f "$settings_file" ]; then
    rite_marketplace=$(jq -r '.enabledPlugins["rite@rite-marketplace"] // false' "$settings_file" 2>/dev/null)
    if [ "$rite_marketplace" = "true" ]; then
      echo "[rite] WARNING: rite@rite-marketplace が有効です。ローカル開発版が無視されます。" >&2
      echo "[rite] ~/.claude/settings.json で rite@rite-marketplace を false に設定してください。" >&2
    fi
  fi
fi

CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
SOURCE=$(echo "$INPUT" | jq -r '.source // "startup"')
if [ -z "$CWD" ] || [ ! -d "$CWD" ]; then
  exit 0
fi

# Resolve state root (git root or CWD) — consistent with pre-compact.sh / session-end.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$CWD" 2>/dev/null) || STATE_ROOT="$CWD"

# Helper: remove stale .rite-compact-state when no active flow (#756)
# Called on startup when .rite-flow-state is absent or inactive, to prevent
# post-compact-guard from blocking all tool calls in the new session.
_cleanup_stale_compact() {
  if [ -f "$STATE_ROOT/.rite-compact-state" ]; then
    rm -f "$STATE_ROOT/.rite-compact-state" 2>/dev/null || true
    rm -rf "$STATE_ROOT/.rite-compact-state.lockdir" 2>/dev/null || true
  fi
}

# Reset context pressure counter on startup/clear (#889)
if [ "$SOURCE" = "startup" ] || [ "$SOURCE" = "clear" ]; then
  rm -f "$STATE_ROOT/.rite-context-counter" 2>/dev/null || true
fi

# --- Context budget estimation on startup (#889) ---
# System prompt can approach 200K token API limit when many plugins/MCP servers are loaded.
# Warn early so users can reduce loaded components before hitting the limit mid-session.
if [ "$SOURCE" = "startup" ]; then
  _budget_warnings=0

  # Check MEMORY.md size (auto-memory contributes to system prompt)
  _memory_dir="$HOME/.claude/projects"
  # Find the project-specific memory file by matching the CWD path
  _cwd_encoded=$(echo "$CWD" | sed 's|/|-|g')
  _memory_file="${_memory_dir}/${_cwd_encoded}/memory/MEMORY.md"
  if [ -f "$_memory_file" ]; then
    _mem_size=$(wc -c < "$_memory_file" 2>/dev/null) || _mem_size=0
    if [ "$_mem_size" -gt 8000 ]; then
      _budget_warnings=$((_budget_warnings + 1))
    fi
  fi

  # Check number of enabled plugins (each adds skill descriptions to system prompt)
  _settings_file="$HOME/.claude/settings.json"
  if [ -f "$_settings_file" ]; then
    _plugin_count=$(jq '[.enabledPlugins // {} | to_entries[] | select(.value == true)] | length' "$_settings_file" 2>/dev/null) || _plugin_count=0
    if [ "$_plugin_count" -gt 3 ]; then
      _budget_warnings=$((_budget_warnings + 1))
    fi
  fi

  # Check for MCP servers (each adds tool definitions to system prompt)
  _mcp_count=0
  if [ -f "$_settings_file" ]; then
    _mcp_count=$(jq '.mcpServers // {} | length' "$_settings_file" 2>/dev/null) || _mcp_count=0
  fi
  # Also check project-level MCP config
  for _mcp_file in "$CWD/.mcp.json" "$CWD/.mcp/config.json"; do
    if [ -f "$_mcp_file" ]; then
      _proj_mcp=$(jq '.mcpServers // {} | length' "$_mcp_file" 2>/dev/null) || _proj_mcp=0
      _mcp_count=$((_mcp_count + _proj_mcp))
    fi
  done
  if [ "$_mcp_count" -gt 0 ]; then
    _budget_warnings=$((_budget_warnings + 1))
  fi

  # Warn if multiple risk factors detected
  if [ "$_budget_warnings" -ge 2 ]; then
    echo "[rite] ⚠️ コンテキストバジェット警告: プラグイン${_plugin_count}個 + MCP${_mcp_count}個が検出されました。" >&2
    echo "[rite] 長時間ワークフローでは auto-compact 後に API 上限 (200K tokens) を超える可能性があります。" >&2
    echo "[rite] 対策: 不要なプラグイン/MCP サーバーを無効化するか、定期的に /compact を実行してください。" >&2
  fi
fi

STATE_FILE="$STATE_ROOT/.rite-flow-state"

if [ ! -f "$STATE_FILE" ]; then
  # Clean stale compact state on startup/clear when no flow state exists (#756, #800)
  [ "$SOURCE" != "compact" ] && _cleanup_stale_compact
  exit 0
fi

ACTIVE=$(jq -r '.active // false' "$STATE_FILE" 2>/dev/null) || ACTIVE=false
if [ "$ACTIVE" != "true" ]; then
  # Clean stale compact state on startup/clear when flow is inactive (#756, #800)
  [ "$SOURCE" != "compact" ] && _cleanup_stale_compact
  exit 0
fi

# --- Defensive reset on new session startup (#761) ---
# If active=true on startup, session-end.sh likely did not fire (e.g., SessionEnd
# hook not registered). Reset to active=false and show a soft message instead of
# the alarming "CRITICAL: Active rite workflow detected" message.
if [ "$SOURCE" = "startup" ]; then
  PHASE=$(jq -r '.phase // ""' "$STATE_FILE" 2>/dev/null) || PHASE=""
  ISSUE=$(jq -r '.issue_number // "" | tostring' "$STATE_FILE" 2>/dev/null) || ISSUE=""
  BRANCH=$(jq -r '.branch // ""' "$STATE_FILE" 2>/dev/null) || BRANCH=""
  TMP_FILE="${STATE_FILE}.tmp.$$"
  trap 'rm -f "$TMP_FILE" 2>/dev/null' EXIT TERM INT
  if jq --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")" \
     '.active = false | .updated_at = $ts' "$STATE_FILE" > "$TMP_FILE" 2>/dev/null; then
    mv "$TMP_FILE" "$STATE_FILE"
  else
    rm -f "$TMP_FILE"
  fi
  _cleanup_stale_compact
  # Silent reset for completed workflows (#772): no message, no /rite:resume suggestion
  if [ "$PHASE" = "completed" ]; then
    exit 0
  fi
  if [ -n "$ISSUE" ]; then
    echo "rite: 前回のセッション状態が残っていたためリセットしました (Issue #${ISSUE}, branch: ${BRANCH})。再開するには /rite:resume を使用してください。"
  fi
  exit 0
fi

# --- Post-compact / post-clear state handling ---
if [ "$SOURCE" = "compact" ] || [ "$SOURCE" = "clear" ]; then
  COMPACT_STATE="$STATE_ROOT/.rite-compact-state"
  COMPACT_TRANSITIONED=false

  # Post-compact: compact_state=blocked → force STOP message
  if [ "$SOURCE" = "compact" ] && [ -f "$COMPACT_STATE" ]; then
    COMPACT_VAL=$(jq -r '.compact_state // "normal"' "$COMPACT_STATE" 2>/dev/null) || COMPACT_VAL="unknown"
    if [ "$COMPACT_VAL" = "blocked" ]; then
      ACTIVE_ISSUE=$(jq -r '.active_issue // "unknown"' "$COMPACT_STATE" 2>/dev/null) || ACTIVE_ISSUE="unknown"
      # Minimal message to reduce post-compaction token overhead (#889)
      echo "STOP. Compact occurred. Issue #${ACTIVE_ISSUE}. Say: /clear then /rite:resume. STOP."
      exit 0
    fi
  fi

  # After /clear: transition compact_state from blocked → resuming
  if [ "$SOURCE" = "clear" ] && [ -f "$COMPACT_STATE" ]; then
    COMPACT_VAL=$(jq -r '.compact_state // "normal"' "$COMPACT_STATE" 2>/dev/null) || COMPACT_VAL="unknown"
    if [ "$COMPACT_VAL" = "blocked" ]; then
      COMPACT_TRANSITIONED=true
      TMP_COMPACT="${COMPACT_STATE}.tmp.$$"
      if jq --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '.compact_state = "resuming" | .compact_state_set_at = $ts' \
        "$COMPACT_STATE" > "$TMP_COMPACT" 2>/dev/null; then
        mv "$TMP_COMPACT" "$COMPACT_STATE"
      else
        rm -f "$TMP_COMPACT"
      fi
    fi
  fi

  # --- Defensive reset on /clear without active compact flow (#781) ---
  # If compact_state was "blocked", we transitioned it to "resuming" above and
  # fall through to the CRITICAL message for the compact → clear → resume flow.
  # Otherwise (no compact-state file, or non-blocked state), apply the same
  # defensive reset as startup to avoid false "interrupted workflow" detection.
  if [ "$SOURCE" = "clear" ] && [ "$COMPACT_TRANSITIONED" = "false" ]; then
    PHASE=$(jq -r '.phase // ""' "$STATE_FILE" 2>/dev/null) || PHASE=""
    ISSUE=$(jq -r '.issue_number // "" | tostring' "$STATE_FILE" 2>/dev/null) || ISSUE=""
    BRANCH=$(jq -r '.branch // ""' "$STATE_FILE" 2>/dev/null) || BRANCH=""
    TMP_CLEAR_FILE="${STATE_FILE}.tmp.$$"
    trap 'rm -f "$TMP_CLEAR_FILE" 2>/dev/null' EXIT TERM INT
    if jq --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")" \
       '.active = false | .updated_at = $ts' "$STATE_FILE" > "$TMP_CLEAR_FILE" 2>/dev/null; then
      mv "$TMP_CLEAR_FILE" "$STATE_FILE"
    else
      rm -f "$TMP_CLEAR_FILE"
    fi
    _cleanup_stale_compact
    # Silent reset for completed workflows (#772): no message, no /rite:resume suggestion
    if [ "$PHASE" = "completed" ]; then
      exit 0
    fi
    if [ -n "$ISSUE" ]; then
      echo "rite: 前回のセッション状態が残っていたためリセットしました (Issue #${ISSUE}, branch: ${BRANCH})。再開するには /rite:resume を使用してください。"
    fi
    exit 0
  fi
  # fall through to normal CRITICAL message handling (compact → clear → resume flow)
fi

# Clean up stale temporary files (older than 1 minute to avoid deleting in-progress writes)
find "$STATE_ROOT" -maxdepth 1 -name ".rite-flow-state.tmp.*" -type f -mmin +1 -delete 2>/dev/null || true

# Extract all fields in a single jq call for efficiency
# Use IFS=$'\t' because @tsv outputs tab-delimited fields; default IFS includes
# spaces which would break values like "After rite:lint, execute Phase 5.2.1...".
# Note: If the process substitution (jq) fails, read returns non-zero but under
# set -e the subshell exit status is not propagated. The subsequent -z "$ISSUE"
# check catches this case by detecting empty/missing fields.
IFS=$'\t' read -r ISSUE PHASE NEXT LOOP < <(jq -r '[
  (.issue_number // "" | tostring),
  (.phase // "unknown"),
  (.next_action // "unknown"),
  (.loop_count // 0 | tostring)
] | @tsv' "$STATE_FILE")

# Validate that critical fields are not null/empty
if [ -z "$ISSUE" ]; then
  echo "rite: Warning - state file exists but issue_number is missing. Use /rite:resume to recover."
  exit 0
fi

cat <<EOF
CRITICAL: Active rite workflow detected (possibly interrupted by context limit).
Issue: #$ISSUE | Phase: $PHASE | Loop: $LOOP
Next action: $NEXT

IMPORTANT: First inform the user that an interrupted workflow was detected.
Display the Issue number, phase, and next action.
Then suggest running /rite:resume to continue from where it left off.
If the user provides a different instruction, respect it but mention the pending workflow.
Read .rite-flow-state for full state details.
EOF
