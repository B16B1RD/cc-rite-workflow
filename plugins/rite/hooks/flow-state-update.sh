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

# Helper script existence check (verified-review cycle 34 F-09 / cycle 38 F-01 HIGH + F-09 MEDIUM):
# 旧実装は state-path-resolve.sh のみ fail-fast 検査していたが、本 helper は以下の helper を `bash <missing>`
# invocation 経路で間接的に依存する:
#   - `_resolve-session-id.sh` (`_resolve_session_id` 関数内の `bash $SCRIPT_DIR/_resolve-session-id.sh ...`)
#   - `_resolve-schema-version.sh` (`_resolve_schema_version` 関数の helper 委譲)
#   - `_resolve-cross-session-guard.sh` (`_resolve_session_state_path` 内 cross-session classification)
#   - `_emit-cross-session-incident.sh` (`_resolve_session_state_path` の foreign:* / corrupt:* / invalid_uuid:* 各 arm)
# それらが install 不整合 / deploy regression で missing の場合、`set -euo pipefail` の中でも
# `if`/`else`/`||` 文脈では非ブロッキング扱いとなり、silent fall-through 経路が散在する。Issue #687
# (writer/reader 片肺更新型 silent regression) と同型の deploy regression を構造的に塞ぐため、依存する
# 5 helper を upfront で fail-fast 検査する (state-path-resolve.sh は STATE_ROOT 解決経路で `||` fallback
# により silent suppression する独自経路があるため特に重要)。state-read.sh の同型ブロックと writer/reader
# 対称化。コメント内の helper 参照は semantic anchor (関数名 / case 構造名) で記述し、行番号を入れない
# (Wiki 経験則 .rite/wiki/index.md の DRIFT-CHECK ANCHOR 原則 + 本 PR cycle 38 F-03/F-04/F-15 系統と整合)。
for _helper in state-path-resolve.sh _resolve-session-id.sh _resolve-schema-version.sh \
               _resolve-cross-session-guard.sh _emit-cross-session-incident.sh; do
  if [ ! -x "$SCRIPT_DIR/$_helper" ]; then
    echo "ERROR: $_helper not found or not executable: $SCRIPT_DIR/$_helper" >&2
    echo "  対処: rite plugin が正しくセットアップされているか確認してください" >&2
    exit 1
  fi
done
unset _helper

# Resolve repository root
# verified-review cycle 34 fix (F-07 MEDIUM): `2>/dev/null` を削除して stderr を pass-through し、
# state-read.sh と writer/reader 対称化する (cycle 33 で reader 側のみ stderr 観測性優先方針に
# 移行していた非対称を解消)。
STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$(pwd)") || STATE_ROOT="$(pwd)"
LEGACY_FLOW_STATE="$STATE_ROOT/.rite-flow-state"

# --- Multi-state helpers (#672 / #678) ---
# Issue #672 design (Option A: per-session file) routes flow-state writes to
# .rite/sessions/{session_id}.flow-state when schema_version=2. Migration to
# call sites is staged across #3-#5; this script is the single API surface.

# Resolve session_id from --session arg, or fall back to .rite-session-id file.
# Validates UUID format (rejects tampered or corrupt content) on **both** paths:
# the file-read path AND the --session arg path. Validation parity prevents
# path traversal via `--session "../foo"` (review #686 F-01).
_resolve_session_id() {
  # verified-review cycle 34 fix (F-01 CRITICAL): UUID validation を `_resolve-session-id.sh` 共通 helper
  # に抽出。state-read.sh / flow-state-update.sh / resume-active-flag-restore.sh の 5 site で重複していた
  # RFC 4122 strict pattern を 1 箇所に集約し、将来の pattern tightening (variant bit check 等) を
  # 片肺更新 drift から守る。
  local provided_sid="${1:-}"
  if [[ -n "$provided_sid" ]]; then
    local validated
    if validated=$(bash "$SCRIPT_DIR/_resolve-session-id.sh" "$provided_sid" 2>/dev/null); then
      echo "$validated"
      return 0
    fi
    # Reject malformed --session arg (non-UUID input could escape .rite/sessions/).
    # Fail-fast rather than legacy fallback: silent fallback would hide the spec
    # drift and let the caller think a per-session file was created.
    echo "ERROR: invalid session_id format: '$provided_sid' (expected UUID ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\$)" >&2
    return 1
  fi
  local sid_file="$STATE_ROOT/.rite-session-id"
  local sid
  sid=$(tr -d '[:space:]' < "$sid_file" 2>/dev/null) || sid=""
  if [[ -n "$sid" ]]; then
    local validated
    if validated=$(bash "$SCRIPT_DIR/_resolve-session-id.sh" "$sid" 2>/dev/null); then
      sid="$validated"
    else
      sid=""
    fi
  fi
  echo "$sid"
}

# Resolve flow_state.schema_version from rite-config.yml.
# Returns "1" (legacy single-file) or "2" (per-session file).
# Defaults to "1" on parse failure / absent / unrecognized value (safe fallback).
#
# PR #688 cycle 5 review (code-quality + error-handling 推奨): writer/reader で同一の
# inline schema_version 解決 logic (cfg → section → grep → case) を持っていた drift リスクを
# 排除するため、共通 helper `_resolve-schema-version.sh` に抽出済。Issue #687 AC-4 / cycle 3 で
# 確立した pipefail silent failure 対策 (`|| v=""`) も helper 内で吸収される。
# 旧 inline 実装 (cfg / section / v 変数 + case 分岐) は helper 内に移動済み。
_resolve_schema_version() {
  bash "$(dirname "${BASH_SOURCE[0]}")/_resolve-schema-version.sh" "$STATE_ROOT"
}

# Resolve flow-state file path based on (effective_schema_version, legacy_mode, session_id).
# - When legacy_mode is "true", schema_version != "2", or session_id is empty -> legacy path
# - Otherwise -> per-session new path
# - Reader-symmetric legacy fallback with cross-session guard (PR #688 cycle 32 F-01/F-02 fix):
#   When schema_v=2 + valid sid + per-session ABSENT + legacy EXISTS (size > 0), fall back to legacy
#   ONLY IF legacy.session_id matches the current sid OR legacy.session_id is empty/null.
#   When legacy.session_id != current sid (cross-session residue), refuse to fall back to legacy
#   (cycle 31 F-01 CRITICAL: cycle 30 simple fallback caused silent metadata corruption — issue_number
#   / branch / pr_number from another session would silently leak into current session via jq per-field
#   merge). Emit WORKFLOW_INCIDENT sentinel so caller can surface and let create-mode handle init.
#   Size check (cycle 31 F-02 HIGH): writer must mirror reader-side state-read.sh's per-session resolver
#   `[ ! -s ]` guard so size-0 legacy (e.g., from `touch .rite-flow-state`) doesn't silently consume
#   patch updates. (verified-review cycle 34 fix F-04 HIGH: hardcoded line-number 参照を semantic anchor に置換)
_resolve_session_state_path() {
  local sv="$1"
  local lm="$2"
  local sid="$3"
  if [[ "$lm" == "true" ]] || [[ "$sv" != "2" ]] || [[ -z "$sid" ]]; then
    echo "$LEGACY_FLOW_STATE"
    return 0
  fi
  local per_session_path="$STATE_ROOT/.rite/sessions/${sid}.flow-state"
  # Reader-symmetric fallback with cross-session guard + size check.
  # `[ -s ]` ensures legacy is non-empty (cycle 31 F-02). Cross-session check below
  # ensures we only adopt legacy if it belongs to current session or is sessionless legacy.
  if [ ! -f "$per_session_path" ] && [ -f "$LEGACY_FLOW_STATE" ] && [ -s "$LEGACY_FLOW_STATE" ]; then
    # verified-review cycle 34 fix (F-02 HIGH): cross-session guard を `_resolve-cross-session-guard.sh`
    # 共通 helper に抽出。reader 側 (state-read.sh) と重複していた legacy.session_id 抽出 + 比較 +
    # corrupt 判定ロジックを 1 箇所に集約し、片肺更新 drift を構造的に防ぐ。
    local classification
    # verified-review cycle 35 fix (F-02 CRITICAL): use 2>/dev/null instead of 2>&1.
    # The 2>&1 was merging helper's stderr (jq parse error text) into the classification
    # string, breaking `case "$classification" in corrupt:*) ...` matching and silently
    # routing to the defensive `*)` arm — suppressing the `legacy_state_corrupt` sentinel
    # emit on the writer side. Helper now keeps stderr clean (cycle 35 fix in
    # _resolve-cross-session-guard.sh), so 2>/dev/null is safe. Symmetric with state-read.sh's
    # per-session resolver `case "$classification"` block (cycle 35 F-01 fix; cycle 38 propagation
    # scan replaced hardcoded `state-read.sh:119` line reference with semantic anchor).
    classification=$(bash "$SCRIPT_DIR/_resolve-cross-session-guard.sh" "$LEGACY_FLOW_STATE" "$sid" 2>/dev/null) || true
    # PR #688 followup F-01 MEDIUM: foreign:* / corrupt:* / invalid_uuid:* arm の workflow-incident-emit.sh
    # 呼び出しブロックを `_emit-cross-session-incident.sh` helper に集約 (state-read.sh と writer/reader 対称)。
    case "$classification" in
      same|empty)
        # Same session or sessionless legacy: safe to take over
        echo "$LEGACY_FLOW_STATE"
        return 0
        ;;
      foreign:*)
        # Cross-session residue: refuse takeover, emit canonical incident sentinel via helper
        # (caller will see --if-exists silent skip on per-session path or non-existence error,
        #  prompting create-mode init which is the correct behavior for fresh sessions)
        local legacy_sid="${classification#foreign:}"
        bash "$SCRIPT_DIR/_emit-cross-session-incident.sh" foreign writer "$sid" "$legacy_sid"
        echo "WARNING: refusing to write to legacy flow-state (session_id=${legacy_sid}) from current session (sid=${sid}). Routing to per-session path (--if-exists will silent skip, create-mode will init)." >&2
        ;;
      corrupt:*)
        # jq 失敗 (corrupt JSON / IO error) → take over は不安全 (cross-session の可能性を否定できない)
        local jq_rc="${classification#corrupt:}"
        bash "$SCRIPT_DIR/_emit-cross-session-incident.sh" corrupt writer "$sid" "$LEGACY_FLOW_STATE" "$jq_rc"
        echo "WARNING: legacy flow-state ${LEGACY_FLOW_STATE} jq parse failed; routing to per-session path (create-mode will init)." >&2
        ;;
      invalid_uuid:*)
        # legacy.session_id が JSON-parseable だが UUID validation 失敗 (tampered / legacy schema)。
        local invalid_uuid_rc="${classification#invalid_uuid:}"
        bash "$SCRIPT_DIR/_emit-cross-session-incident.sh" invalid_uuid writer "$sid" "$LEGACY_FLOW_STATE" "$invalid_uuid_rc"
        echo "WARNING: legacy flow-state ${LEGACY_FLOW_STATE} session_id failed UUID validation (tampered / legacy schema); routing to per-session path." >&2
        ;;
      *)
        # 想定外の classification (defensive)
        echo "WARNING: unexpected classification from _resolve-cross-session-guard.sh: $classification" >&2
        ;;
    esac
  fi
  echo "$per_session_path"
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
if ! SESSION=$(_resolve_session_id "$SESSION"); then
  exit 1
fi
SCHEMA_VERSION=$(_resolve_schema_version)
if [[ "$LEGACY_MODE" == "true" ]]; then
  EFFECTIVE_SCHEMA_VERSION="1"
else
  EFFECTIVE_SCHEMA_VERSION="$SCHEMA_VERSION"
fi
FLOW_STATE=$(_resolve_session_state_path "$EFFECTIVE_SCHEMA_VERSION" "$LEGACY_MODE" "$SESSION")

# Ensure parent directory exists for the new format. The path-based check below
# is the single source of truth — `_resolve_session_state_path` already encodes
# the (schema_version, legacy_mode, session_id) decision, so we just compare the
# resolved path to the legacy fallback (review #686 F-04). Failures surface via
# `_log_flow_diag` (symmetric with mv-failure path) rather than being silently
# suppressed (review #686 F-05).
if [[ "$FLOW_STATE" != "$LEGACY_FLOW_STATE" ]]; then
  _flow_state_dir=$(dirname "$FLOW_STATE")
  # Capture mkdir stderr so the kernel's specific failure reason
  # (`mkdir: cannot create directory '...': Not a directory` / `Permission denied` /
  # `No space left on device` 等) reaches the user instead of being suppressed
  # to /dev/null (review #686 cycle 2 LOW). Symmetric with the create-mode
  # `_jq_err` capture pattern.
  _mkdir_err=$(mktemp 2>/dev/null) || _mkdir_err=""
  if ! mkdir -p "$_flow_state_dir" 2>"${_mkdir_err:-/dev/null}"; then
    # _log_flow_diag is defined later in the file; inline the diag write here
    # because we exit before reaching that definition's call sites.
    _diag_file="$STATE_ROOT/.rite-stop-guard-diag.log"
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] flow_state_mkdir_failed path=$_flow_state_dir" >> "$_diag_file" 2>/dev/null || true
    echo "ERROR: failed to create $_flow_state_dir (permission denied / disk full / parent is a regular file?)" >&2
    if [ -n "$_mkdir_err" ] && [ -s "$_mkdir_err" ]; then
      head -3 "$_mkdir_err" | sed 's/^/  /' >&2
    fi
    [ -n "$_mkdir_err" ] && rm -f "$_mkdir_err"
    exit 1
  fi
  [ -n "$_mkdir_err" ] && rm -f "$_mkdir_err"
  unset _flow_state_dir _mkdir_err
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
# F-01 / F-04 (#636 cycle 6): repo-wide convention (stop-guard.sh atomic-write block / session-end.sh /
# post-tool-wm-sync.sh 等の mktemp-first + PID fallback pattern を踏襲)。trap で signal 別 cleanup を保護し、
# (cycle 38 propagation scan: 旧 `stop-guard.sh:240` 行番号参照を semantic anchor に置換)
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
    # Error messages reference $FLOW_STATE (the resolved path) rather than the
    # legacy literal `.rite-flow-state` so users running on schema_version=2
    # see the actual per-session path (review #686 F-06).
    PREV_PHASE=""
    if [[ -f "$FLOW_STATE" ]]; then
      if [[ ! -s "$FLOW_STATE" ]]; then
        echo "ERROR: flow-state file exists but is empty: $FLOW_STATE" >&2
        echo "  previous_phase cannot be preserved; failing fast to avoid silent cold-start." >&2
        echo "  対処: $FLOW_STATE を /rite:resume で復旧するか、既存ファイルを削除してから再度 /rite:issue:start を実行" >&2
        exit 1
      fi
      # Validate JSON parse; distinguish "missing .phase" (acceptable → "") from
      # "jq parse error" (corrupt state, must not silently fall back).
      _jq_err=$(mktemp 2>/dev/null) || _jq_err=""
      if PREV_PHASE=$(jq -r '.phase // ""' "$FLOW_STATE" 2>"${_jq_err:-/dev/null}"); then
        : # jq ok
      else
        echo "ERROR: flow-state file parse failed: $FLOW_STATE" >&2
        [ -n "$_jq_err" ] && [ -s "$_jq_err" ] && head -3 "$_jq_err" | sed 's/^/  /' >&2
        echo "  previous_phase cannot be preserved; failing fast to avoid silent cold-start." >&2
        echo "  対処: $FLOW_STATE を確認し、必要なら /rite:resume で復旧してください" >&2
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
    #
    # DRY (review #686 F-02): 旧実装は 11 フィールドの object literal を if/else で全コピーしており、
    # 将来の field 追加で片方を更新し忘れる drift リスクがあった。共通 base を 1 か所に定義し、
    # 新形式は jq の object merge `+` で `schema_version: 2` を prepend する。
    _create_base='{active: $active, issue_number: $issue, branch: $branch, phase: $phase, previous_phase: $prev_phase, pr_number: $pr, parent_issue_number: $parent_issue, next_action: $next, updated_at: $ts, session_id: $sid, last_synced_phase: ""}'
    if [[ "$EFFECTIVE_SCHEMA_VERSION" == "2" ]]; then
      _create_filter="{schema_version: 2} + $_create_base"
    else
      _create_filter="$_create_base"
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
    # PR #688 cycle 6 (F-03 fix): patch mode で session_id を書き戻す経路を追加。
    # 旧 resume.md は legacy direct jq write で `.session_id = $sid` を atomic 更新していた
    # (resume 時の所有権移転 semantics) が、cycle 5 で patch 経由化した際に session_id 書き戻しが
    # drop されていた。SESSION 変数は _resolve_session_id で resolve 済みなので、非空時に
    # patch filter に追加する (caller は自身の session が所有する flow-state を patch する設計のため安全)。
    if [[ -n "$SESSION" ]]; then
      JQ_FILTER="$JQ_FILTER | .session_id = \$session"
      JQ_ARGS+=(--arg session "$SESSION")
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
      echo "ERROR: flow-state file parse failed (patch mode): $FLOW_STATE" >&2
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
      echo "ERROR: flow-state file parse failed (increment mode): $FLOW_STATE" >&2
      exit 1
    fi
    ;;
esac
