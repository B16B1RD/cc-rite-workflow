#!/bin/bash
# rite workflow - Flow State Atomic Update
# Deterministic script for atomic .rite-flow-state writes.
# Replaces inline jq + atomic write patterns scattered across command files.
#
# Usage:
#   Create mode (full object with jq -n):
#     bash plugins/rite/hooks/flow-state-update.sh create \
#       --phase phase5_lint --issue 42 --branch "feat/issue-42-test" \
#       --pr 0 --next "Proceed to Phase 5.2.1." [--active true]
#
#   Patch mode (update fields in existing file):
#     bash plugins/rite/hooks/flow-state-update.sh patch \
#       --phase phase5_post_lint --next "Proceed to next phase." [--active true] [--if-exists] [--preserve-error-count]
#
#   Increment mode (increment a numeric field):
#     bash plugins/rite/hooks/flow-state-update.sh increment \
#       --field implementation_round [--if-exists]
#
# Options:
#   --phase                  Phase value (required for create/patch)
#   --issue                  Issue number (create mode, default: 0)
#   --branch                 Branch name (create mode, default: "")
#   --pr                     PR number (create mode, default: 0)
#   --parent-issue           Parent Issue number (create mode, default: 0; patch mode: update only if specified)
#   --next                   next_action text (required for create/patch)
#   --active                 Active flag (create mode: default true; patch mode: update only if specified)
#   --field                  Field name to increment (increment mode)
#   --if-exists              Only execute if .rite-flow-state exists (patch/increment mode)
#   --session                Session UUID override (create mode; defaults to .rite-session-id)
#   --preserve-error-count   Preserve existing .error_count during patch (same-phase self-patch; patch mode only;
#                            silently ignored in create/increment modes for drift-symmetry with caller-side consistency)
#   --legacy-mode            Force legacy single-file path (`.rite-flow-state`) regardless of
#                            rite-config.yml `flow_state.schema_version`. Used by migration script
#                            (#2) and tooling that must read/write the pre-migration source. Without
#                            this flag, schema_version=2 (default) writes to `.rite/sessions/{session_id}.flow-state`.
#
# Exit codes:
#   0: Success
#   0: Skipped (--if-exists and file does not exist)
#   1: Argument error or jq failure
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source session ownership helper for stale detection in create mode
source "$SCRIPT_DIR/session-ownership.sh" 2>/dev/null || true

# Resolve repository root
STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$(pwd)" 2>/dev/null) || STATE_ROOT="$(pwd)"
LEGACY_FLOW_STATE="$STATE_ROOT/.rite-flow-state"

# --- Multi-state helpers (#672 / #678) ---
# Issue #672 design (Option A: per-session file) routes flow-state writes to
# .rite/sessions/{session_id}.flow-state when schema_version=2. Migration to
# call sites is staged across #3-#5; this script is the single API surface.

# Resolve session_id from --session arg, or fall back to .rite-session-id file.
# Validates UUID format (rejects tampered or corrupt content).
_resolve_session_id() {
  local provided_sid="${1:-}"
  if [[ -n "$provided_sid" ]]; then
    echo "$provided_sid"
    return 0
  fi
  local sid_file="$STATE_ROOT/.rite-session-id"
  local sid
  sid=$(cat "$sid_file" 2>/dev/null | tr -d '[:space:]') || sid=""
  if [[ -n "$sid" && ! "$sid" =~ ^[0-9a-f-]{36}$ ]]; then
    sid=""
  fi
  echo "$sid"
}

# Resolve flow_state.schema_version from rite-config.yml.
# Returns "1" (legacy single-file) or "2" (per-session file).
# Defaults to "1" on parse failure / absent / unrecognized value (safe fallback).
_resolve_schema_version() {
  local cfg="$STATE_ROOT/rite-config.yml"
  if [[ ! -f "$cfg" ]]; then
    echo "1"
    return 0
  fi
  # Section-range extract guards against `enabled:` 行が enclosing section の外側にある regression
  # (cf. start.md Phase 5.0 workflow_incident_enabled parser).
  local section
  section=$(sed -n '/^flow_state:/,/^[a-zA-Z]/p' "$cfg" 2>/dev/null) || section=""
  if [[ -z "$section" ]]; then
    echo "1"
    return 0
  fi
  local v
  v=$(printf '%s\n' "$section" | grep -E '^[[:space:]]+schema_version:' | head -1 \
    | sed 's/#.*//' | sed 's/.*schema_version:[[:space:]]*//' \
    | tr -d '[:space:]"'"'"'')
  case "$v" in
    1|2) echo "$v" ;;
    *) echo "1" ;;
  esac
}

# Resolve flow-state file path based on (effective_schema_version, legacy_mode, session_id).
# - When legacy_mode is "true", schema_version != "2", or session_id is empty -> legacy path
# - Otherwise -> per-session new path
_resolve_session_state_path() {
  local sv="$1"
  local lm="$2"
  local sid="$3"
  if [[ "$lm" == "true" ]] || [[ "$sv" != "2" ]] || [[ -z "$sid" ]]; then
    echo "$LEGACY_FLOW_STATE"
    return 0
  fi
  echo "$STATE_ROOT/.rite/sessions/${sid}.flow-state"
}

# --- Argument parsing ---
MODE="${1:-}"
shift 2>/dev/null || true

PHASE=""
ISSUE=0
BRANCH=""
PR=0
PARENT_ISSUE=0
NEXT=""
ACTIVE=""
IF_EXISTS=false
FIELD=""
SESSION=""
PRESERVE_ERROR_COUNT=false
LEGACY_MODE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase)    PHASE="$2"; shift 2 ;;
    --issue)    ISSUE="$2"; shift 2 ;;
    --branch)   BRANCH="$2"; shift 2 ;;
    --pr)       PR="$2"; shift 2 ;;
    --parent-issue) PARENT_ISSUE="$2"; shift 2 ;;
    --next)     NEXT="$2"; shift 2 ;;
    --active)   ACTIVE="$2"; shift 2 ;;
    --if-exists) IF_EXISTS=true; shift ;;
    --preserve-error-count) PRESERVE_ERROR_COUNT=true; shift ;;
    --legacy-mode) LEGACY_MODE=true; shift ;;
    --field)    FIELD="$2"; shift 2 ;;
    --session)  SESSION="$2"; shift 2 ;;
    *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
  esac
done

# --- Resolve effective schema version and target flow-state path ---
# session_id is needed for both create/patch/increment to route writes to the
# session-owned file when schema_version=2. patch/increment auto-read from
# .rite-session-id when --session is not provided (caller-side simplification).
SESSION=$(_resolve_session_id "$SESSION")
SCHEMA_VERSION=$(_resolve_schema_version)
if [[ "$LEGACY_MODE" == "true" ]]; then
  EFFECTIVE_SCHEMA_VERSION="1"
else
  EFFECTIVE_SCHEMA_VERSION="$SCHEMA_VERSION"
fi
FLOW_STATE=$(_resolve_session_state_path "$EFFECTIVE_SCHEMA_VERSION" "$LEGACY_MODE" "$SESSION")

# Ensure parent directory exists for the new format. mkdir -p is idempotent and
# silently succeeds if already present. Failure (e.g., permission denied) is
# surfaced by the subsequent mktemp/mv path.
if [[ "$EFFECTIVE_SCHEMA_VERSION" == "2" ]] && [[ -n "$SESSION" ]] && [[ "$LEGACY_MODE" != "true" ]]; then
  mkdir -p "$STATE_ROOT/.rite/sessions" 2>/dev/null || true
fi

# --- Validation ---
case "$MODE" in
  create)
    if [[ -z "$PHASE" || -z "$NEXT" ]]; then
      echo "ERROR: create mode requires --phase and --next" >&2
      exit 1
    fi
    ;;
  patch)
    if [[ -z "$PHASE" || -z "$NEXT" ]]; then
      echo "ERROR: patch mode requires --phase and --next" >&2
      exit 1
    fi
    if [[ "$IF_EXISTS" == true && ! -f "$FLOW_STATE" ]]; then
      exit 0
    fi
    ;;
  increment)
    if [[ -z "$FIELD" ]]; then
      echo "ERROR: increment mode requires --field" >&2
      exit 1
    fi
    if [[ "$IF_EXISTS" == true && ! -f "$FLOW_STATE" ]]; then
      exit 0
    fi
    ;;
  *)
    echo "ERROR: Unknown mode: $MODE (expected: create, patch, increment)" >&2
    exit 1
    ;;
esac

# --- Atomic write ---
# F-01 / F-04 (#636 cycle 6): repo-wide convention (stop-guard.sh:240 / session-end.sh / post-tool-wm-sync.sh 等)
# と整合する mktemp-first + PID fallback pattern。trap で signal 別 cleanup を保護し、
# jq stdout redirect 中の SIGTERM/SIGINT/SIGHUP で orphan が残る経路を塞ぐ。
TMP_STATE=$(mktemp "${FLOW_STATE}.XXXXXX" 2>/dev/null) || TMP_STATE="${FLOW_STATE}.tmp.$$"
trap 'rm -f "$TMP_STATE" 2>/dev/null' EXIT TERM INT HUP

# F-05 (#636 cycle 6): mv 失敗 diag を stop-guard.sh 側の log_diag 経路と対称化。
# stderr だけだと caller が stderr を suppress した場合に永続痕跡が消える。
# 既存の .rite-stop-guard-diag.log を re-use (日付形式のみ揃える。ring buffer truncation は
# stop-guard.sh 側 log_diag() の mapfile + ${_lines[@]: -50} に委譲する — 本関数は append only)。
# (#636 cycle 12 F-01 対応: 旧 comment「ring buffer と日付形式を揃える」は mapfile truncation
# を含まない実装と drift していたため修正。truncation は stop-guard.sh 次回起動時に発火する)
_log_flow_diag() {
  local diag_file="$STATE_ROOT/.rite-stop-guard-diag.log"
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $1" >> "$diag_file" 2>/dev/null || true
}

case "$MODE" in
  create)
    # Default active to true if not explicitly specified
    if [[ -z "$ACTIVE" ]]; then
      ACTIVE="true"
    fi
    # session_id is now resolved upfront via _resolve_session_id() (see top-level
    # block after arg parsing). The previous in-mode auto-read (#216) is folded
    # into the helper so patch/increment also benefit.
    # Session ownership: overwrite protection for active state owned by another session
    if [[ -n "$SESSION" && -f "$FLOW_STATE" ]]; then
      _existing_active=$(jq -r '.active // false' "$FLOW_STATE" 2>/dev/null) || _existing_active="false"
      if [[ "$_existing_active" == "true" ]]; then
        _existing_sid=$(get_state_session_id "$FLOW_STATE" 2>/dev/null) || _existing_sid=""
        if [[ -n "$_existing_sid" && "$_existing_sid" != "$SESSION" ]]; then
          # Different session owns the state — check staleness
          _updated_at=$(jq -r '.updated_at // empty' "$FLOW_STATE" 2>/dev/null) || _updated_at=""
          if [[ -n "$_updated_at" ]]; then
            _state_epoch=$(parse_iso8601_to_epoch "$_updated_at" 2>/dev/null) || _state_epoch=0
            _now_epoch=$(date +%s)
            _diff=$((_now_epoch - _state_epoch))
            if [[ "$_diff" -le 7200 ]]; then
              echo "ERROR: 別のワークフローが進行中です（2時間以内に更新）。" >&2
              echo "INFO: 上書きするには先に /rite:resume で所有権を移転するか、2時間待ってください。" >&2
              exit 1
            fi
          fi
        fi
      fi
    fi
    # Capture previous phase for whitelist-based transition verification (#490).
    # When the state file is absent, previous_phase is "" (legitimate cold start).
    # When the file exists but is corrupt, fail-fast — silently treating corruption
    # as a cold start would erase the prior phase and effectively bypass the
    # whitelist for the next transition (error-handling CRITICAL #2).
    PREV_PHASE=""
    if [[ -f "$FLOW_STATE" ]]; then
      if [[ ! -s "$FLOW_STATE" ]]; then
        echo "ERROR: .rite-flow-state exists but is empty ($FLOW_STATE)" >&2
        echo "  previous_phase cannot be preserved; failing fast to avoid silent cold-start." >&2
        echo "  対処: .rite-flow-state を /rite:resume で復旧するか、既存ファイルを削除してから再度 /rite:issue:start を実行" >&2
        exit 1
      fi
      # Validate JSON parse; distinguish "missing .phase" (acceptable → "") from
      # "jq parse error" (corrupt state, must not silently fall back).
      _jq_err=$(mktemp 2>/dev/null) || _jq_err=""
      if PREV_PHASE=$(jq -r '.phase // ""' "$FLOW_STATE" 2>"${_jq_err:-/dev/null}"); then
        : # jq ok
      else
        echo "ERROR: .rite-flow-state parse failed ($FLOW_STATE)" >&2
        [ -n "$_jq_err" ] && [ -s "$_jq_err" ] && head -3 "$_jq_err" | sed 's/^/  /' >&2
        echo "  previous_phase cannot be preserved; failing fast to avoid silent cold-start." >&2
        echo "  対処: 既存の .rite-flow-state を確認し、必要なら /rite:resume で復旧してください" >&2
        [ -n "$_jq_err" ] && rm -f "$_jq_err"
        exit 1
      fi
      [ -n "$_jq_err" ] && rm -f "$_jq_err"
      # Preserve parent_issue_number from existing state when --parent-issue is not
      # explicitly specified (#497). Without this, every create call that omits
      # --parent-issue would reset parent_issue_number to 0, erasing the value
      # persisted by Phase 2.4 Mandatory After.
      if [[ "$PARENT_ISSUE" -eq 0 ]]; then
        _existing_parent=$(jq -r '.parent_issue_number // 0' "$FLOW_STATE" 2>/dev/null) || _existing_parent=0
        if [[ "$_existing_parent" =~ ^[0-9]+$ ]] && [[ "$_existing_parent" -ne 0 ]]; then
          PARENT_ISSUE="$_existing_parent"
        fi
      fi
    fi
    # verified-review cycle 4 F-05 / #636: mv 失敗 path も stop-guard.sh の error_count atomic write 後 mv 失敗 path と対称に (line-number 参照を避ける理由は cycle 8 F-05 参照)
    # 診断メッセージを出す。`set -euo pipefail` 下で mv 失敗は script を非 0 exit させるが、
    # else branch は jq 失敗のみを surface するため、disk full / permission denied / EXDEV 等の
    # mv 失敗要因が silent に握りつぶされる (silent failure-hunter 指摘)。patch / increment mode と対称化。
    #
    # #678: schema_version=2 (Option A per-session file) では create object に schema_version: 2 を含め、
    # Migration 検出条件「schema_version キー無 or < 2」(design doc Migration 戦略) と整合させる。
    # legacy mode では schema_version field を含めず、旧形式 reader (#3-#5 移行前の hook 群) との
    # bytewise 互換を保つ。
    if [[ "$EFFECTIVE_SCHEMA_VERSION" == "2" ]]; then
      _create_filter='{schema_version: 2, active: $active, issue_number: $issue, branch: $branch, phase: $phase, previous_phase: $prev_phase, pr_number: $pr, parent_issue_number: $parent_issue, next_action: $next, updated_at: $ts, session_id: $sid, last_synced_phase: ""}'
    else
      _create_filter='{active: $active, issue_number: $issue, branch: $branch, phase: $phase, previous_phase: $prev_phase, pr_number: $pr, parent_issue_number: $parent_issue, next_action: $next, updated_at: $ts, session_id: $sid, last_synced_phase: ""}'
    fi
    if jq -n \
      --argjson active "$ACTIVE" \
      --argjson issue "$ISSUE" \
      --arg branch "$BRANCH" \
      --arg phase "$PHASE" \
      --arg prev_phase "$PREV_PHASE" \
      --argjson pr "$PR" \
      --argjson parent_issue "$PARENT_ISSUE" \
      --arg next "$NEXT" \
      --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")" \
      --arg sid "$SESSION" \
      "$_create_filter" \
      > "$TMP_STATE"; then
      if ! mv "$TMP_STATE" "$FLOW_STATE"; then
        _log_flow_diag "flow_state_mv_failed mode=create phase=$PHASE issue=$ISSUE"
        rm -f "$TMP_STATE"
        echo "ERROR: mv failed (create mode): $TMP_STATE -> $FLOW_STATE (disk full / permission denied / EXDEV?)" >&2
        exit 1
      fi
    else
      _log_flow_diag "flow_state_jq_failed mode=create phase=$PHASE issue=$ISSUE"
      rm -f "$TMP_STATE"
      echo "ERROR: jq create failed" >&2
      exit 1
    fi
    ;;
  patch)
    # Build jq filter: always update phase, timestamp, next_action; conditionally update active.
    # Also capture the outgoing phase into previous_phase so stop-guard can verify the
    # transition whitelist (#490). Use the pre-update .phase value as previous_phase.
    #
    # --preserve-error-count (verified-review cycle 3 F-01 / #636): patch mode のデフォルトは
    # `.error_count = 0` でリセットする (phase transition は「進捗した」signal なのでエスカレーション
    # counter をクリアするのが正しい)。ただし、create.md Step 0 / Step 1 のような **同一 phase への
    # self-patch** (create_post_interview → create_post_interview) では error_count を保持しないと
    # stop-guard.sh の RE-ENTRY DETECTED escalation + THRESHOLD=3 bail-out が永久に fire しない
    # silent regression になる (cycle 3 で実測確認済み)。--preserve-error-count flag 指定時は
    # `.error_count = 0` 条項を omit して既存値を保持する。
    if [[ "$PRESERVE_ERROR_COUNT" == "true" ]]; then
      JQ_FILTER='.previous_phase = (.phase // "") | .phase = $phase | .updated_at = $ts | .next_action = $next'
    else
      JQ_FILTER='.previous_phase = (.phase // "") | .phase = $phase | .updated_at = $ts | .next_action = $next | .error_count = 0'
    fi
    JQ_ARGS=(--arg phase "$PHASE" --arg ts "$(date -u +'%Y-%m-%dT%H:%M:%S+00:00')" --arg next "$NEXT")
    if [[ -n "$ACTIVE" ]]; then
      JQ_FILTER="$JQ_FILTER | .active = (\$active_val == \"true\")"
      JQ_ARGS+=(--arg active_val "$ACTIVE")
    fi
    if [[ "$PARENT_ISSUE" -ne 0 ]]; then
      JQ_FILTER="$JQ_FILTER | .parent_issue_number = (\$parent_issue_val | tonumber)"
      JQ_ARGS+=(--arg parent_issue_val "$PARENT_ISSUE")
    fi
    # 同対称: create mode の mv 失敗 diag コメント (mv 失敗 path 対称診断) を参照
    if jq "${JQ_ARGS[@]}" -- "$JQ_FILTER" "$FLOW_STATE" > "$TMP_STATE"; then
      if ! mv "$TMP_STATE" "$FLOW_STATE"; then
        _log_flow_diag "flow_state_mv_failed mode=patch phase=$PHASE"
        rm -f "$TMP_STATE"
        echo "ERROR: mv failed (patch mode): $TMP_STATE -> $FLOW_STATE (disk full / permission denied / EXDEV?)" >&2
        exit 1
      fi
    else
      _log_flow_diag "flow_state_jq_failed mode=patch phase=$PHASE"
      rm -f "$TMP_STATE"
      echo "ERROR: jq patch failed" >&2
      exit 1
    fi
    ;;
  increment)
    # 同対称: create mode の mv 失敗 diag コメント (mv 失敗 path 対称診断) を参照
    if jq --arg field "$FIELD" \
       '.[$field] = ((.[$field] // 0) + 1)' \
       "$FLOW_STATE" > "$TMP_STATE"; then
      if ! mv "$TMP_STATE" "$FLOW_STATE"; then
        _log_flow_diag "flow_state_mv_failed mode=increment field=$FIELD"
        rm -f "$TMP_STATE"
        echo "ERROR: mv failed (increment mode): $TMP_STATE -> $FLOW_STATE (disk full / permission denied / EXDEV?)" >&2
        exit 1
      fi
    else
      _log_flow_diag "flow_state_jq_failed mode=increment field=$FIELD"
      rm -f "$TMP_STATE"
      echo "ERROR: jq increment failed" >&2
      exit 1
    fi
    ;;
esac
