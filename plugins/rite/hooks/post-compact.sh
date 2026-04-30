#!/bin/bash
# rite workflow - Post-Compact Hook
# Restores workflow context after compaction by outputting state to stdout.
# stdout is injected into the model's context, enabling automatic workflow continuation.
set -euo pipefail

# Double-execution guard (hooks.json + settings.local.json migration)
[ -z "${_RITE_HOOK_RUNNING_POSTCOMPACT:-}" ] || exit 0
export _RITE_HOOK_RUNNING_POSTCOMPACT=1

# Hook version resolution preamble (must be before INPUT=$(cat) to preserve stdin)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/hook-preamble.sh" 2>/dev/null || true

# cat failure does not abort under set -e; || guard is defensive
INPUT=$(cat) || INPUT=""
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || CWD=""
SOURCE=$(echo "$INPUT" | jq -r '.source // "auto"' 2>/dev/null) || SOURCE="auto"
if [ -z "$CWD" ] || [ ! -d "$CWD" ]; then
  exit 0
fi

# Resolve state root (git root or CWD)
STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$CWD" 2>/dev/null) || STATE_ROOT="$CWD"

COMPACT_STATE="$STATE_ROOT/.rite-compact-state"
# Resolve active flow-state file path (Issue #680).
# Returns the per-session file when schema_version=2 with a valid SID; otherwise legacy.
#
# Issue #749: stderr pass-through for diagnostic visibility, via canonical helper
# `_mktemp-stderr-guard.sh` (PR #688 cycle 9 F-02 で抽出済み)。詳細は session-start.sh
# の同パターンを参照。filter は state-read.sh:148 と同型 (4-pattern 包括)。
# success arm でも tempfile を inspect して helper graceful-degrade 経路の WARNING
# を silent drop しないようにする。
_resolve_err=$(bash "$SCRIPT_DIR/_mktemp-stderr-guard.sh" \
  "post-compact" \
  "resolve-flow-state-err" \
  "_resolve-flow-state-path.sh の WARNING/ERROR / jq parse error / indented 補助行が pass-through されません")
if FLOW_STATE=$("$SCRIPT_DIR/_resolve-flow-state-path.sh" "$STATE_ROOT" 2>"${_resolve_err:-/dev/null}"); then
  if [ -n "$_resolve_err" ] && [ -s "$_resolve_err" ]; then
    grep -E '^WARNING:|^ERROR:|^  |^jq: ' "$_resolve_err" >&2 || true
  fi
else
  if [ -n "$_resolve_err" ] && [ -s "$_resolve_err" ]; then
    grep -E '^WARNING:|^ERROR:|^  |^jq: ' "$_resolve_err" >&2 || true
  fi
  FLOW_STATE="$STATE_ROOT/.rite-flow-state"
  echo "[rite] WARNING: flow-state path resolution failed, falling back to legacy ($FLOW_STATE)" >&2
fi
[ -n "$_resolve_err" ] && rm -f "$_resolve_err"
LOCKDIR="$COMPACT_STATE.lockdir"

# --- Cleanup helper ---
_cleanup_compact_state() {
  rm -f "$COMPACT_STATE" 2>/dev/null || true
  rm -rf "$LOCKDIR" 2>/dev/null || true
}

# --- No flow state: clean up and exit ---
if [ ! -f "$FLOW_STATE" ]; then
  _cleanup_compact_state
  exit 0
fi

# --- Flow not active: clean up and exit ---
FLOW_ACTIVE=$(jq -r '.active // false' "$FLOW_STATE" 2>/dev/null) || FLOW_ACTIVE="false"
if [ "$FLOW_ACTIVE" != "true" ]; then
  _cleanup_compact_state
  exit 0
fi

# --- No compact state or not recovering: nothing to do ---
if [ ! -f "$COMPACT_STATE" ]; then
  exit 0
fi
COMPACT_VAL=$(jq -r '.compact_state // "normal"' "$COMPACT_STATE" 2>/dev/null) || COMPACT_VAL="unknown"
if [ "$COMPACT_VAL" != "recovering" ]; then
  exit 0
fi

# --- Source work-memory-lock for acquire/release helpers ---
source "$SCRIPT_DIR/work-memory-lock.sh"

# --- Read flow state ---
# cycle 11 CRITICAL F-01: IFS=$'\t' + @tsv は POSIX whitespace collapse により next_action=""
# のとき全フィールドが左 shift し、PR 欄に branch 名が混入する silent データ汚染を起こす。
# stop-guard.sh cycle 10 F-01 と同じ修正を適用 — unit separator \x1f で empty field を preserve。
FLOW_DATA=$(jq -r '[
  (.issue_number // "unknown" | tostring),
  (.phase // "unknown"),
  (.next_action // ""),
  (.loop_count // 0 | tostring),
  (.pr_number // 0 | tostring),
  (.branch // "")
] | join("\u001f")' "$FLOW_STATE" 2>/dev/null) || FLOW_DATA=""

if [ -z "$FLOW_DATA" ]; then
  # Cannot read flow state — clean up and exit silently
  _cleanup_compact_state
  exit 0
fi

IFS=$'\x1f' read -r ISSUE PHASE NEXT_ACTION LOOP PR BRANCH <<< "$FLOW_DATA"

# --- Transition compact_state to normal (inside lock) ---
TMP_COMPACT=""
cleanup() {
  rm -f "$TMP_COMPACT" 2>/dev/null
  release_wm_lock "$LOCKDIR"
}
trap cleanup EXIT TERM INT

if acquire_wm_lock "$LOCKDIR"; then
  TMP_COMPACT=$(mktemp "${COMPACT_STATE}.XXXXXX" 2>/dev/null) || TMP_COMPACT="${COMPACT_STATE}.tmp.$$"
  if jq -n \
    --arg state "normal" \
    --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '{compact_state: $state, compact_state_set_at: $ts}' \
    > "$TMP_COMPACT" 2>/dev/null; then
    mv "$TMP_COMPACT" "$COMPACT_STATE"
    TMP_COMPACT=""
  else
    rm -f "$TMP_COMPACT"
    TMP_COMPACT=""
  fi
  release_wm_lock "$LOCKDIR"
fi

# --- stderr: user-facing notification ---
echo "[rite] compact 後の自動復帰を実行中 (Issue #${ISSUE}, Phase: ${PHASE})" >&2

# --- stdout: injected into model context ---
if [ "$SOURCE" = "auto" ]; then
  cat <<EOF
[rite] Auto-compact recovery: Issue #${ISSUE}, Phase: ${PHASE}, Branch: ${BRANCH}
Next action: ${NEXT_ACTION}
Loop: ${LOOP} | PR: #${PR}
Read .rite-flow-state and .rite-work-memory/issue-${ISSUE}.md for full context, then continue.
EOF
else
  # Manual compact: state re-injection only, no auto-continue instruction
  cat <<EOF
[rite] Compact recovery: Issue #${ISSUE}, Phase: ${PHASE}, Branch: ${BRANCH}
Next action: ${NEXT_ACTION}
Loop: ${LOOP} | PR: #${PR}
EOF
fi
