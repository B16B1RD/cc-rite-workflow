#!/bin/bash
# rite workflow - Pre-Compact Hook
# Sets recovering compact-state and saves work memory snapshot before context
# compaction. compact itself cannot be prevented; this hook records state for
# SessionStart(compact) resumption. PreCompact stdout is not injected into
# model context (Claude Code docs: only SessionStart / UserPromptSubmit /
# UserPromptExpansion / PostModelSwitch plain stdout is).
set -euo pipefail

# Double-execution guard (hooks.json + settings.local.json migration)
[ -z "${_RITE_HOOK_RUNNING_PRECOMPACT:-}" ] || exit 0
export _RITE_HOOK_RUNNING_PRECOMPACT=1

# Hook version resolution preamble (must be before INPUT=$(cat) to preserve stdin)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/hook-preamble.sh" 2>/dev/null || true
source "$SCRIPT_DIR/session-ownership.sh" 2>/dev/null || true
# shellcheck source=control-char-neutralize.sh
source "$SCRIPT_DIR/control-char-neutralize.sh"

# jq is a hard dependency: .rite-flow-state is created by jq, so if jq is
# missing the state file won't exist and the hook exits at the -f check below.
# cat failure does not abort under set -e; || guard is defensive
INPUT=$(cat) || INPUT=""
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || CWD=""
# PreCompact payload uses `trigger` (auto|manual). `.source` is a fallback for
# harnesses that reuse the PostCompact field name. Missing/unknown → auto
# (expected absence; SessionStart treats the same default).
TRIGGER=$(echo "$INPUT" | jq -r '.trigger // .source // "auto"' 2>/dev/null) || TRIGGER="auto"
case "$TRIGGER" in
  manual) ;;
  *) TRIGGER="auto" ;;
esac
if [ -z "$CWD" ] || [ ! -d "$CWD" ]; then
  exit 0
fi

# Resolve state root (git root or CWD)
# SCRIPT_DIR already set in preamble block above
STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$CWD" 2>/dev/null) || STATE_ROOT="$CWD"

# Resolve active flow-state file path.
# Always returns the per-session file (the legacy single-file selection path was
# removed).
#
# Stderr pass-through for diagnostic visibility, via canonical helper
# `_mktemp-stderr-guard.sh`. 詳細は session-start.sh の同パターンを参照。
# filter は flow-state.sh cross-session guard の 3-pattern を `^ERROR:` で
# superset 化した 4-pattern 拡張版 (resolver self-validation の ERROR: を捕捉)。
# success arm でも tempfile を inspect して helper graceful-degrade 経路の WARNING
# を silent drop しないようにする。
_resolve_err=$(bash "$SCRIPT_DIR/_mktemp-stderr-guard.sh" \
  "pre-compact" \
  "resolve-flow-state-err" \
  "flow-state.sh path の WARNING/ERROR / jq parse error / indented 補助行が pass-through されません")
# Single-pass branch (filter runs once regardless of resolver exit status).
_resolve_failed=0
FLOW_STATE=$(RITE_STATE_ROOT="$STATE_ROOT" "$SCRIPT_DIR/flow-state.sh" path 2>"${_resolve_err:-/dev/null}") || _resolve_failed=1
if [ -n "$_resolve_err" ] && [ -s "$_resolve_err" ]; then
  grep -E '^WARNING:|^ERROR:|^  |^jq: ' "$_resolve_err" >&2 || true
fi
if [ "$_resolve_failed" -eq 1 ]; then
  FLOW_STATE=""
  echo "[rite] WARNING: flow-state.sh path resolution failed — skip" >&2
fi
[ -n "$_resolve_err" ] && rm -f "$_resolve_err"

# Derive the per-session compact-state path from the resolved flow-state path
# .rite/sessions/{sid}.flow-state → .rite/sessions/{sid}.compact-state.
# This makes each session's compact snapshot independent, avoiding a
# last-writer-wins race that a single shared file would otherwise cause. Falls
# back to the legacy shared path only when the session id is unresolvable, so
# sessions without a session id still have a working compact-state location.
if [ -n "$FLOW_STATE" ]; then
  COMPACT_STATE="${FLOW_STATE%.flow-state}.compact-state"
else
  COMPACT_STATE="$STATE_ROOT/.rite-compact-state"
fi
LOCKDIR="$COMPACT_STATE.lockdir"

# --- Cleanup function (covers all temp files) ---
TMP_FILE=""
TMP_COMPACT=""
cleanup() {
  # `_resolve_err` の synchronous rm は trap install より前で実行される (resolver 直後)
  # ため、ここで cleanup() に含める必要はない (dead code)。trap が発火する時点では既に
  # 削除済みで no-op となる。trap install 前の race window は同期 rm 自身でカバーされる。
  rm -f "$TMP_FILE" "$TMP_COMPACT" 2>/dev/null
  release_wm_lock "$LOCKDIR"
}

# --- Work memory update helper (reuses YAML frontmatter writing logic; also sources work-memory-lock.sh) ---
source "$SCRIPT_DIR/work-memory-update.sh"

trap cleanup EXIT TERM INT

# Session ownership check: skip state updates for other session's state.
# Must run before lock to avoid holding the lock while doing nothing.
if [ -f "$FLOW_STATE" ]; then
  # Pass-through helper stderr so corrupt-state WARNINGs reach triage; the
  # helper's WARNING messages exist specifically to flag state-overwrite risk
  # against another active session, and a caller-side `2>/dev/null` would
  # silently negate them.
  _ownership=$(check_session_ownership "$INPUT" "$FLOW_STATE") || _ownership="own"
  if [ "$_ownership" = "other" ]; then
    exit 0
  fi
fi

# --- All state updates inside lock ---
if acquire_wm_lock "$LOCKDIR"; then
  # Update .rite-flow-state timestamp (inside lock for atomicity)
  if [ -f "$FLOW_STATE" ]; then
    TMP_FILE=$(mktemp "${FLOW_STATE}.XXXXXX" 2>/dev/null) || TMP_FILE="${FLOW_STATE}.tmp.$$"
    # heartbeat (.updated_at) を silent に失敗させると session-ownership の staleness 検出
    # (2h threshold) が peer session に上書き許可を出す経路を作るため、jq の stderr を capture
    # して WARNING を出す。silent fallback は同居 session 上書きと作業ロストに直結する。
    _heartbeat_err=$(mktemp 2>/dev/null) || _heartbeat_err=""
    if jq --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")" '.updated_at = $ts' "$FLOW_STATE" > "$TMP_FILE" 2>"${_heartbeat_err:-/dev/null}"; then
      # Bare mv would silently orphan TMP_FILE and leave the heartbeat unbumped,
      # which lets session-ownership staleness gate misclassify this session as
      # stale and authorize a peer overwrite. Capture stderr so errno detail
      # (EXDEV / EACCES / ENOSPC / EROFS / SELinux deny) surfaces in WARNING.
      _hb_mv_err=$(mktemp 2>/dev/null) || _hb_mv_err=""
      if mv "$TMP_FILE" "$FLOW_STATE" 2>"${_hb_mv_err:-/dev/null}"; then
        :
      else
        _mv_rc=$?
        rm -f "$TMP_FILE"
        echo "rite: pre-compact: mv flow-state updated_at failed (rc=$_mv_rc)" >&2
        [ -n "$_hb_mv_err" ] && [ -s "$_hb_mv_err" ] && head -3 "$_hb_mv_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
      fi
      [ -n "$_hb_mv_err" ] && rm -f "$_hb_mv_err"
    else
      _heartbeat_rc=$?
      rm -f "$TMP_FILE"
      echo "rite: pre-compact: WARNING: heartbeat jq failed (rc=$_heartbeat_rc) — session-ownership staleness check may misclassify this session as stale" >&2
      [ -n "$_heartbeat_err" ] && [ -s "$_heartbeat_err" ] && head -3 "$_heartbeat_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    fi
    [ -n "$_heartbeat_err" ] && rm -f "$_heartbeat_err"
    TMP_FILE=""
  fi

  # Determine active issue from flow state. jq stderr を完全抑止していると corrupt JSON が
  # silent に branch name fallback (下の if) に降格して snapshot が誤った issue 番号で保存される。
  # RITE_DEBUG 時に詳細を log してトリアージ可能にする。
  ACTIVE_ISSUE="null"
  if [ -f "$FLOW_STATE" ]; then
    _ai_err=$(mktemp 2>/dev/null) || _ai_err=""
    _ai_rc=0
    ACTIVE_ISSUE=$(jq -r '.issue_number // "null"' "$FLOW_STATE" 2>"${_ai_err:-/dev/null}") || _ai_rc=$?
    if [ "$_ai_rc" -ne 0 ] || [ -z "$ACTIVE_ISSUE" ]; then
      [ -n "${RITE_DEBUG:-}" ] && echo "[rite] DEBUG: pre-compact: .issue_number jq 失敗 (rc=$_ai_rc) — branch name fallback へ降格" >&2
      [ -n "${RITE_DEBUG:-}" ] && [ -n "$_ai_err" ] && [ -s "$_ai_err" ] && head -3 "$_ai_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
      ACTIVE_ISSUE="null"
    fi
    [ -n "$_ai_err" ] && rm -f "$_ai_err"
  fi

  # Validate ACTIVE_ISSUE is numeric before --argjson
  if [ "$ACTIVE_ISSUE" != "null" ] && ! [[ "$ACTIVE_ISSUE" =~ ^[0-9]+$ ]]; then
    ACTIVE_ISSUE="null"
  fi

  # If no active issue in flow state, try branch name. Capture git stderr so
  # corrupt .git / permission denied / missing git binary surface a WARNING
  # instead of leaving the pre-compact snapshot without branch information.
  if [ "$ACTIVE_ISSUE" = "null" ]; then
    _pc_br_err=$(mktemp 2>/dev/null) || _pc_br_err=""
    _pc_br_rc=0
    BRANCH=$(cd "$CWD" && git branch --show-current 2>"${_pc_br_err:-/dev/null}") || _pc_br_rc=$?
    if [ "$_pc_br_rc" -ne 0 ]; then
      echo "[rite] WARNING: pre-compact: git branch --show-current 失敗 (rc=$_pc_br_rc)" >&2
      [ -n "$_pc_br_err" ] && [ -s "$_pc_br_err" ] && head -3 "$_pc_br_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
      BRANCH=""
    fi
    [ -n "$_pc_br_err" ] && rm -f "$_pc_br_err"
    if [[ "$BRANCH" =~ issue-([0-9]+) ]]; then
      ACTIVE_ISSUE="${BASH_REMATCH[1]}"
    fi
  fi

  # Write compact state — always set to "recovering" regardless of current state
  # The previous "skip if resuming" guard was insufficient: when
  # post-compact-guard transitioned blocked→resuming on first denial, a second
  # compact would see "resuming" and skip, leaving all guards permissive.
  # PostCompact still normalizes recovering→normal (side effects); SessionStart
  # (source=compact) emits the recovery text. pre-compact always sets
  # "recovering" so every compact still triggers PostCompact processing.
  # `trigger` is read by SessionStart to distinguish auto (continue) vs manual
  # (state only). SessionStart input has only source=compact.
  TMP_COMPACT=$(mktemp "${COMPACT_STATE}.XXXXXX" 2>/dev/null) || TMP_COMPACT="${COMPACT_STATE}.tmp.$$"
  # Capture jq stderr so a write failure (broken ACTIVE_ISSUE value, locale,
  # disk full) is diagnosable instead of being collapsed to the generic
  # "failed to write compact state" WARNING that loses the root cause.
  _jq_compact_err=$(mktemp 2>/dev/null) || _jq_compact_err=""
  if jq -n \
    --arg state "recovering" \
    --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --argjson issue "$ACTIVE_ISSUE" \
    --arg trigger "$TRIGGER" \
    '{compact_state: $state, compact_state_set_at: $ts, active_issue: $issue, trigger: $trigger}' \
    > "$TMP_COMPACT" 2>"${_jq_compact_err:-/dev/null}"; then
    _cs_mv_err=$(mktemp 2>/dev/null) || _cs_mv_err=""
    if mv "$TMP_COMPACT" "$COMPACT_STATE" 2>"${_cs_mv_err:-/dev/null}"; then
      TMP_COMPACT=""
      # chmod failure here would leave compact_state world-readable; capture
      # both rc and stderr so EPERM (read-only fs) is distinguishable from
      # EACCES (foreign-owned file) and SELinux deny.
      _chmod_err=$(mktemp 2>/dev/null) || _chmod_err=""
      if chmod 600 "$COMPACT_STATE" 2>"${_chmod_err:-/dev/null}"; then
        :
      else
        _chmod_rc=$?
        echo "rite: pre-compact: chmod 600 $COMPACT_STATE failed (rc=$_chmod_rc)" >&2
        [ -n "$_chmod_err" ] && [ -s "$_chmod_err" ] && head -3 "$_chmod_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
      fi
      [ -n "$_chmod_err" ] && rm -f "$_chmod_err"
    else
      _mv_rc=$?
      rm -f "$TMP_COMPACT"
      TMP_COMPACT=""
      echo "rite: pre-compact: mv compact state failed (rc=$_mv_rc)" >&2
      [ -n "$_cs_mv_err" ] && [ -s "$_cs_mv_err" ] && head -3 "$_cs_mv_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    fi
    [ -n "$_cs_mv_err" ] && rm -f "$_cs_mv_err"
  else
    _jq_compact_rc=$?
    rm -f "$TMP_COMPACT"
    TMP_COMPACT=""
    echo "rite: pre-compact: failed to write compact state (jq rc=$_jq_compact_rc)" >&2
    [ -n "$_jq_compact_err" ] && [ -s "$_jq_compact_err" ] && head -3 "$_jq_compact_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  fi
  [ -n "$_jq_compact_err" ] && rm -f "$_jq_compact_err"

  # --- Save local work memory snapshot ---
  # Only save snapshot when workflow is actively running (active: true).
  # Without this check, completed workflows would get their work memory files
  # recreated on compaction, causing stale file persistence. A jq parse
  # failure here (corrupt flow-state JSON) silently degrades to "skip
  # snapshot" — surface a WARNING so a corrupt state file doesn't quietly
  # cause snapshot loss in the middle of an active workflow.
  _flow_active_err=$(mktemp 2>/dev/null) || _flow_active_err=""
  if FLOW_ACTIVE=$(jq -r '.active // false' "$FLOW_STATE" 2>"${_flow_active_err:-/dev/null}"); then
    :
  else
    _flow_active_rc=$?
    echo "rite: pre-compact: WARNING: failed to parse .active from $FLOW_STATE (jq rc=$_flow_active_rc) — workflow snapshot will be skipped, recovery may lose context" >&2
    [ -n "$_flow_active_err" ] && [ -s "$_flow_active_err" ] && head -3 "$_flow_active_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    FLOW_ACTIVE="false"
  fi
  [ -n "$_flow_active_err" ] && rm -f "$_flow_active_err"
  if [ "$FLOW_ACTIVE" = "true" ] && [ "$ACTIVE_ISSUE" != "null" ] && [ -f "$FLOW_STATE" ]; then
    # Read phase and next_action from flow state for env vars
    # Use unit separator () instead of tab so a future field containing
    # whitespace cannot shift later columns silently. next_action is trailing
    # today so the bug would not bite yet, but adding fields between them later
    # would corrupt downstream parsing without an obvious diff signal.
    # snapshot 用 jq に stderr capture を加える: 失敗時に PHASE="unknown" の stub で続行すると
    # post-compact が誤った phase で resume するため、root cause を WARNING で expose する。
    _flow_data_snap_err=$(mktemp 2>/dev/null) || _flow_data_snap_err=""
    FLOW_DATA=$(jq -r '[.phase // "unknown", .pr_number // "null", .loop_count // 0, .next_action // ""] | join("\u001f")' "$FLOW_STATE" 2>"${_flow_data_snap_err:-/dev/null}") || FLOW_DATA=""
    if [ -n "$_flow_data_snap_err" ] && [ -s "$_flow_data_snap_err" ]; then
      echo "rite: pre-compact: WARNING: snapshot jq failed — post-compact recovery may resume with phase=unknown" >&2
      head -3 "$_flow_data_snap_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    fi
    [ -n "$_flow_data_snap_err" ] && rm -f "$_flow_data_snap_err"
    if [ -n "$FLOW_DATA" ]; then
      IFS=$'\x1f' read -r PHASE PR_NUM LOOP_CNT NEXT_ACT <<< "$FLOW_DATA"
    else
      PHASE="unknown"
      PR_NUM="null"
      LOOP_CNT="0"
      NEXT_ACT=""
    fi

    # Delegate to shared helper (runs in subshell to isolate cd)
    # observability: emit snapshot diag log so analysts can correlate
    # pre-compact write timing with subsequent post-compact phase. Without this, the
    # `create_delegation` snapshot fixation hypothesis is unverifiable (no record of which
    # phase value was captured at compact time).
    if (
      cd "$STATE_ROOT" || exit 1
      WM_ISSUE_NUMBER="$ACTIVE_ISSUE" \
      WM_SKIP_LOCK="true" \
      WM_SOURCE="pre_compact" \
      WM_PHASE="$PHASE" \
      WM_PHASE_DETAIL="compact 前 snapshot" \
      WM_NEXT_ACTION="$NEXT_ACT" \
      WM_BODY_TEXT="Pre-compact snapshot. SessionStart(compact) will auto-recover." \
      WM_PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")" \
      WM_PR_NUMBER="$PR_NUM" \
      WM_LOOP_COUNT="$LOOP_CNT" \
        update_local_work_memory
    ); then
      echo "[CONTEXT] PRE_COMPACT_SNAPSHOT_RECORDED=1; issue=$ACTIVE_ISSUE; phase=$PHASE; pr=$PR_NUM; ts=$(date -u +'%Y-%m-%dT%H:%M:%SZ')" >&2
    else
      _wm_rc=$?
      echo "rite: pre-compact: work memory update failed (exit $_wm_rc)" >&2
      echo "[CONTEXT] PRE_COMPACT_SNAPSHOT_FAILED=1; issue=$ACTIVE_ISSUE; phase=$PHASE; pr=$PR_NUM; rc=$_wm_rc; reason=update_local_work_memory_failed" >&2
    fi
  fi

  release_wm_lock "$LOCKDIR"
fi

# stderr advisory only when workflow is active. PreCompact stdout is not
# injected into model context — SessionStart(source=compact) emits recovery.
# FLOW_ACTIVE is set inside the lock block; defaults to "false" if lock was not acquired.
if [ "${FLOW_ACTIVE:-false}" = "true" ]; then
  # Provide defaults: PHASE may be unset when ACTIVE_ISSUE is null (line 96 guard)
  _ISSUE="${ACTIVE_ISSUE:-unknown}"
  _PHASE="${PHASE:-unknown}"

  echo "[rite] ⚠️ compact detected (Issue #${_ISSUE}, Phase: ${_PHASE}). Auto-recovery will proceed via SessionStart." >&2
fi
