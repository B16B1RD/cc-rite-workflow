#!/bin/bash
# rite workflow - Session Start Hook
# Re-injects flow state after compact or resume
set -euo pipefail

# Double-execution guard (hooks.json + settings.local.json migration)
[ -z "${_RITE_HOOK_RUNNING_SESSIONSTART:-}" ] || exit 0
export _RITE_HOOK_RUNNING_SESSIONSTART=1

# Hook version resolution preamble (must be before INPUT=$(cat) to preserve stdin)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "${RITE_DEBUG:-}" ]; then
  source "$SCRIPT_DIR/hook-preamble.sh" || true
else
  source "$SCRIPT_DIR/hook-preamble.sh" 2>/dev/null || true
fi

# Source session ownership helper for session_id extraction and ownership checks
source "$SCRIPT_DIR/session-ownership.sh" 2>/dev/null || true

# jq is a hard dependency: .rite-flow-state is created by jq, so if jq is
# missing the state file won't exist and the hook exits at the -f check below.
# (Under set -e, a missing jq would exit 127 at the first jq call, before
# reaching -f; the comment describes the logical invariant, not the exit path.)
# cat failure does not abort under set -e; || guard is defensive
INPUT=$(cat) || INPUT=""

# Plugin dual-load collision guard (#591)
# Only warn when this script is running from a local plugin-dir (not from
# the marketplace cache). Normal marketplace users should have it enabled.
# SCRIPT_DIR already set in preamble block above (replaces SCRIPT_PATH)
if [[ "$SCRIPT_DIR" != *"/.claude/plugins/cache/"* ]] && command -v jq &>/dev/null; then
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

# Extract session_id from hook JSON payload (#173)
SESSION_ID=$(extract_session_id "$INPUT" 2>/dev/null) || SESSION_ID=""
if [ -z "$CWD" ] || [ ! -d "$CWD" ]; then
  exit 0
fi

# Resolve state root (git root or CWD) — consistent with pre-compact.sh / session-end.sh
# SCRIPT_DIR already set in preamble block above
STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$CWD" 2>/dev/null) || STATE_ROOT="$CWD"

# Save session_id to .rite-session-id for flow-state-update.sh auto-read (#216)
if [ -n "$SESSION_ID" ]; then
  (umask 077; printf '%s' "$SESSION_ID" > "$STATE_ROOT/.rite-session-id") 2>/dev/null || {
    [ -n "${RITE_DEBUG:-}" ] && echo "[rite] WARNING: Failed to write .rite-session-id" >&2
    true
  }
fi

# Helper: remove stale .rite-compact-state when no active flow (#756)
# Called on startup when .rite-flow-state is absent or inactive, to prevent
# stale recovering state from persisting across sessions.
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

# --- Plugin version check + auto-repair on startup ---
if [ "$SOURCE" = "startup" ]; then
  _version_file="$STATE_ROOT/.rite-initialized-version"
  if [ -f "$_version_file" ]; then
    _installed_ver=$(tr -d '[:space:]' < "$_version_file" 2>/dev/null)
    _plugin_json="$SCRIPT_DIR/../.claude-plugin/plugin.json"
    _current_ver=$(jq -r '.version // empty' "$_plugin_json" 2>/dev/null)
    if [ -n "$_installed_ver" ] && [ -n "$_current_ver" ] && [ "$_installed_ver" != "$_current_ver" ]; then
      # i18n: read language from rite-config.yml (same awk pattern as stop-guard.sh)
      _lang="en"
      _rite_config="$STATE_ROOT/rite-config.yml"
      if [ -f "$_rite_config" ]; then
        _cfg_lang=$(awk '/^language:/{print $2}' "$_rite_config" 2>/dev/null | tr -d '[:space:]')
        [ -n "$_cfg_lang" ] && _lang="$_cfg_lang"
      fi

      # Auto-repair settings.local.json hook paths for marketplace installations
      _auto_repaired=false
      if [[ "$SCRIPT_DIR" == *"/.claude/plugins/cache/"* ]]; then
        _settings_local="$STATE_ROOT/.claude/settings.local.json"
        if [ -f "$_settings_local" ] && command -v python3 &>/dev/null; then
          # Find old hooks dir from settings.local.json and replace with current SCRIPT_DIR
          _repair_tmp=$(mktemp "${_settings_local}.XXXXXX" 2>/dev/null) || _repair_tmp=""
          if [ -n "$_repair_tmp" ] && python3 -c '
import json, sys, re, os

settings_path = sys.argv[1]
new_hooks_dir = sys.argv[2]
out_path = sys.argv[3]

with open(settings_path, "r") as f:
    data = json.load(f)

hooks = data.get("hooks", {})
if not hooks:
    sys.exit(1)

# Pattern: bash /path/to/hooks/script.sh
hook_path_re = re.compile(r"(bash\s+)(/[^\s]+/plugins/rite/hooks/)(\S+)")
changed = False

for event_name, entries in hooks.items():
    if not isinstance(entries, list):
        continue
    for entry in entries:
        hook_list = entry.get("hooks", [])
        for hook in hook_list:
            cmd = hook.get("command", "")
            m = hook_path_re.search(cmd)
            if m and m.group(2) != new_hooks_dir + "/":
                old_path = m.group(2)
                new_cmd = cmd.replace(old_path, new_hooks_dir + "/")
                hook["command"] = new_cmd
                changed = True

if not changed:
    sys.exit(1)

with open(out_path, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
' "$_settings_local" "$SCRIPT_DIR" "$_repair_tmp" 2>/dev/null; then
            mv "$_repair_tmp" "$_settings_local" 2>/dev/null && _auto_repaired=true
          else
            rm -f "$_repair_tmp" 2>/dev/null
          fi
        fi
      fi

      if [ "$_auto_repaired" = "true" ]; then
        # Update version marker after successful auto-repair
        echo "$_current_ver" > "$_version_file" 2>/dev/null || true
        case "$_lang" in
          ja)
            echo "[rite] フックパスを自動修復しました (v${_installed_ver} -> v${_current_ver})。" >&2
            ;;
          *)
            echo "[rite] Hook paths auto-repaired (v${_installed_ver} -> v${_current_ver})." >&2
            ;;
        esac
      else
        case "$_lang" in
          ja)
            echo "[rite] プラグインが更新されました (v${_installed_ver} -> v${_current_ver})。/rite:init を実行して hooks を再登録してください。" >&2
            ;;
          *)
            echo "[rite] Plugin updated (v${_installed_ver} -> v${_current_ver}). Run /rite:init to re-register hooks." >&2
            ;;
        esac
      fi
    fi
  fi
fi

STATE_FILE="$STATE_ROOT/.rite-flow-state"

if [ ! -f "$STATE_FILE" ]; then
  # Clean stale compact state on startup/clear when no flow state exists (#756, #800)
  _cleanup_stale_compact
  exit 0
fi

ACTIVE=$(jq -r '.active // false' "$STATE_FILE" 2>/dev/null) || ACTIVE=false
if [ "$ACTIVE" != "true" ]; then
  # Clean stale compact state on startup/clear when flow is inactive (#756, #800)
  _cleanup_stale_compact
  exit 0
fi

# --- Defensive reset helper (#761, #173, #206) ---
# Shared by startup and clear blocks. Resets active=false and shows a soft message.
# Always proceeds with reset regardless of session ownership (#206).
# Note: This function always terminates via exit 0 — it never returns to the caller.
# When issue_number is empty (e.g., state file has no issue), exits silently without message.
_reset_active_state() {
  local _phase _issue _branch
  _phase=$(jq -r '.phase // ""' "$STATE_FILE" 2>/dev/null) || _phase=""
  _issue=$(jq -r '.issue_number // "" | tostring' "$STATE_FILE" 2>/dev/null) || _issue=""
  _branch=$(jq -r '.branch // ""' "$STATE_FILE" 2>/dev/null) || _branch=""

  # Debug log for session ownership diagnostics (#206)
  if [ -n "${RITE_DEBUG:-}" ]; then
    local _ownership
    _ownership=$(check_session_ownership "$INPUT" "$STATE_FILE" 2>/dev/null) || _ownership="unknown"
    echo "[rite] Resetting active state (ownership: $_ownership)" >&2
  fi

  # Atomic write: jq to temp file, then mv. No trap — explicit cleanup on failure.
  local _tmp
  _tmp=$(mktemp "${STATE_FILE}.XXXXXX" 2>/dev/null) || _tmp="${STATE_FILE}.tmp.$$"
  if jq --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")" \
     '.active = false | .updated_at = $ts' "$STATE_FILE" > "$_tmp" 2>/dev/null; then
    mv "$_tmp" "$STATE_FILE"
  else
    rm -f "$_tmp" 2>/dev/null
  fi
  _cleanup_stale_compact
  # Silent reset for completed workflows (#772): no message, no /rite:resume suggestion
  if [ "$_phase" = "completed" ]; then
    exit 0
  fi
  if [ -n "$_issue" ]; then
    echo "rite: 前回のセッション状態が残っていたためリセットしました (Issue #${_issue}, branch: ${_branch})。再開するには /rite:resume を使用してください。"
  fi
  exit 0
}

# --- Defensive reset on new session startup (#761, #173) ---
if [ "$SOURCE" = "startup" ]; then
  _reset_active_state
fi

# --- Defensive reset on /clear (#781, #133, #173) ---
if [ "$SOURCE" = "clear" ]; then
  _reset_active_state
fi

# Clean up stale temporary files (older than 1 minute to avoid deleting in-progress writes)
find "$STATE_ROOT" -maxdepth 1 \( -name ".rite-flow-state.tmp.*" -o -name ".rite-flow-state.??????*" \) -type f -mmin +1 -delete 2>/dev/null || true

# Extract all fields in a single jq call for efficiency
# Use IFS=$'\t' because @tsv outputs tab-delimited fields; default IFS includes
# spaces which would break values like "After rite:lint, execute Phase 5.2.1...".
# Defense-in-depth: Line 111's ACTIVE check already catches invalid JSON (jq
# fails → ACTIVE=false → exit 0). This fallback handles the unlikely case where
# the file becomes corrupt between the two jq reads (e.g., race condition,
# partial write). It is not reachable by normal unit tests.
_tsv_output=$(jq -r '[
  (.issue_number // "" | tostring),
  (.phase // "unknown"),
  (.next_action // "unknown"),
  (.loop_count // 0 | tostring)
] | @tsv' "$STATE_FILE" 2>/dev/null) || {
  echo "rite: Warning - state file contains invalid JSON. Use /rite:resume to recover." >&2
  exit 0
}
IFS=$'\t' read -r ISSUE PHASE NEXT LOOP <<< "$_tsv_output"

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

# --- Session ID notification (#173, #221) ---
# session_id is now auto-read from .rite-session-id by flow-state-update.sh.
# stdout output removed to prevent Claude from fabricating inconsistent values
# via the {session_id} placeholder. See Issue #221.
