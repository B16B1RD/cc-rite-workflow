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
# invocation 経路で direct + transitive に依存する。検査対象 list の Single Source of Truth は
# `_validate-helpers.sh` 内の **DEFAULT_HELPERS 配列** (PR #688 cycle 13 F-01 で集約):
#   - `state-path-resolve.sh` (STATE_ROOT 解決経路で direct invoke)
#   - `_resolve-session-id.sh` (`_resolve_session_id` 関数内の direct invoke)
#   - `_resolve-session-id-from-file.sh` (transitive 経由で `_resolve_session_state_path` 解決経路)
#   - `_resolve-schema-version.sh` (`_resolve_schema_version` 関数の helper 委譲)
#   - `_resolve-cross-session-guard.sh` (`_resolve_session_state_path` 内 cross-session classification)
#   - `_emit-cross-session-incident.sh` (foreign:* / corrupt:* / invalid_uuid:* 各 arm)
#   - `_mktemp-stderr-guard.sh` (jq stderr 退避 / mkdir stderr 退避等で direct invoke)
# 上記 bullet list は人間向けの説明であり、実際の検査対象は DEFAULT_HELPERS 配列が決定する。
# helper を追加する際は `_validate-helpers.sh` 内 DEFAULT_HELPERS への 1 行追加のみで両 caller
# (state-read.sh / flow-state-update.sh) に反映される (writer/reader 対称化 doctrine の構造的実装)。
# それらが install 不整合 / deploy regression で missing の場合、`set -euo pipefail` の中でも
# `if`/`else`/`||` 文脈では非ブロッキング扱いとなり、silent fall-through 経路が散在する。Issue #687
# (writer/reader 片肺更新型 silent regression) と同型の deploy regression を構造的に塞ぐため、依存する
# 全 helper を upfront で fail-fast 検査する。state-read.sh の同型ブロックと writer/reader 対称化。
# verified-review F-06 (MEDIUM) / PR #688 cycle 12 F-04 (MEDIUM): helper existence check の
# **validation logic** を `_validate-helpers.sh` に集約。
# PR #688 cycle 13 F-01 (HIGH): helper 名 list 自体も `_validate-helpers.sh` 内の DEFAULT_HELPERS
# 配列に集約し、本 caller は引数 0 個 (script_dir のみ) で呼ぶ形に統一。state-read.sh と本ファイルの
# helper-list 重複が構造的に解消され、helper 追加時は 1 ファイル更新のみで済む。
if [ ! -x "$SCRIPT_DIR/_validate-helpers.sh" ]; then
  echo "ERROR: _validate-helpers.sh not found or not executable: $SCRIPT_DIR/_validate-helpers.sh" >&2
  echo "  対処: rite plugin が正しくセットアップされているか確認してください" >&2
  exit 1
fi
# DEFAULT_HELPERS を使用 (引数 0 個 = script_dir のみ)
bash "$SCRIPT_DIR/_validate-helpers.sh" "$SCRIPT_DIR"

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
  # verified-review cycle 38 F-05 MEDIUM: 引数指定なし経路 (sid_file 読込 + tr + validation + fallback) を
  # `_resolve-session-id-from-file.sh` 共通 helper に置換。state-read.sh / resume-active-flag-restore.sh と
  # writer/reader/resume 3 layer 対称化。--session arg 指定経路は writer 固有の fail-fast policy
  # (silent fallback で spec drift を隠さない) を維持する必要があるため、本関数内で明示処理を残す。
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
    echo "ERROR: invalid session_id format: '$provided_sid' (expected UUID, RFC 4122 §4: 8-4-4-4-12 hex with hyphens, case-insensitive — \`_resolve-session-id.sh\` accepts [0-9a-fA-F])" >&2
    return 1
  fi
  bash "$SCRIPT_DIR/_resolve-session-id-from-file.sh" "$STATE_ROOT"
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
    # PR #688 followup: cycle 41 review F-01 HIGH — helper の正当な WARNING (mktemp 失敗 WARNING) が
    # `2>/dev/null` で silent suppress される問題を修正 (state-read.sh と writer/reader 対称化)。
    #
    # cycle 43 F-09 (MEDIUM) 対応: state-read.sh:142 と writer/reader 対称化。canonical pattern
    # (`if ! ... then` + WARNING 3 行 + chmod 600) に統一。詳細は state-read.sh の cycle 43 F-09
    # コメントを参照 (drift 防止のため両層で同一の修正を適用)。
    # verified-review F-03 MEDIUM: _classify_err に signal-specific trap を追加 (state-read.sh と
    # writer/reader 対称化)。`_resolve_session_state_path` 関数内に閉じた scope で trap を install し、
    # mktemp 成功 〜 rm 完了の race window で SIGINT/SIGTERM/SIGHUP 中断時の orphan を防ぐ。
    # 関数 return 時に `trap - EXIT INT TERM HUP` で default に restore し、`_rite_flow_state_atomic_cleanup`
    # 関数定義の trap install ブロックと衝突しないようにする (canonical pattern)。
    # 注: 本関数は command substitution (`FLOW_STATE=$(_resolve_session_state_path ...)`) で呼ばれるため、
    # 内部の trap は subshell に閉じる。parent shell の `_rite_flow_state_atomic_cleanup` trap は影響を受けない。
    # この trap reset は parent への leak が発生した場合の defense-in-depth として残している。
    local _classify_err=""
    # verified-review F-06 (LOW): cleanup 本体は Form A (`rm -f` 単一行) のため、
    # bash-trap-patterns.md「cleanup 関数の契約」節 Form A 規範では `return 0` 不要 (rm -f の rc=0 で十分)。
    # `_resolve-cross-session-guard.sh` の Form A cleanup と統一し、Form A 最小性 doctrine を維持する。
    _rite_flow_state_classify_cleanup() {
      rm -f "${_classify_err:-}"
    }
    trap 'rc=$?; _rite_flow_state_classify_cleanup; exit $rc' EXIT
    trap '_rite_flow_state_classify_cleanup; exit 130' INT
    trap '_rite_flow_state_classify_cleanup; exit 143' TERM
    trap '_rite_flow_state_classify_cleanup; exit 129' HUP
    # verified-review (PR #688 cycle 15) F-05 (MEDIUM) 対応: writer/reader 対称化 doctrine 構造的破綻の解消。
    # 旧実装は `mktemp + WARNING 3 行 + chmod 600` を 6 行 inline で書き、`_mktemp-stderr-guard.sh` の
    # F-02 consolidation スコープから漏れていた。state-read.sh と byte-for-byte に重複していたため、
    # 将来 WARNING 文言や chmod 仕様を変更する際の片肺更新 drift リスクが残存していた。
    # state-read.sh の本 helper invocation と writer/reader 対称化を維持するため、同じ helper 経由に統一する。
    _classify_err=$(bash "$SCRIPT_DIR/_mktemp-stderr-guard.sh" \
      "flow-state-update" "classify-err-writer" \
      "cross-session guard helper の WARNING (mktemp 失敗 / jq stderr) が pass-through されません")
    # F-01 (HIGH) — writer/reader 対称化 doctrine 違反を解消。state-read.sh の同 doctrine
    # コメント (writer 側との対称化を維持する原則 — Cross-Reference: state-read.sh の本 helper
    # invocation 直前の F-11 / 対称化 note と同じ趣旨で記述) に従い、`|| true` で helper の
    # 想定外 exit を silent swallow せず、`if ... then : else _guard_rc=$?; fi` で rc を捕捉する。
    # helper の design contract (`exit 0 — always`) が将来 regression した場合、writer 側でも
    # 確実に WARNING emit + classification="" にして create-mode 経路への routing が壊れない
    # ようにする (Issue #687 同型の片肺更新 silent regression を新たに導入しない)。
    local _guard_rc=0
    if classification=$(bash "$SCRIPT_DIR/_resolve-cross-session-guard.sh" "$LEGACY_FLOW_STATE" "$sid" 2>"${_classify_err:-/dev/null}"); then
      :
    else
      _guard_rc=$?
      echo "WARNING: _resolve-cross-session-guard.sh exited non-zero (rc=$_guard_rc) — design contract violation (helper should always exit 0) [writer]" >&2
      classification=""
    fi
    if [ -n "$_classify_err" ] && [ -s "$_classify_err" ]; then
      # state-read.sh の `grep -E '^WARNING:|^  |^jq: ' "$_classify_err"` pass-through ブロック (reader)
      # と writer/reader 対称化。`_resolve-cross-session-guard.sh` の `head -3 "$_jq_err"` ブロックが
      # 出力する生 `jq:` parse error 行 (line/column 診断) を pass-through し cycle 15 F-03 の
      # dead-observability 解消 intent を回復する。
      # (cycle 48 F-03: hardcoded line refs `state-read.sh:140` / `_resolve-cross-session-guard.sh:173`
      # を semantic anchor に置換 — drift 防止 doctrine cycle 38 F-04 と整合)
      grep -E '^WARNING:|^  |^jq: ' "$_classify_err" >&2 2>/dev/null || true
    fi
    [ -n "$_classify_err" ] && rm -f "$_classify_err"
    _classify_err=""
    # restore default trap (`_rite_flow_state_atomic_cleanup` 関数定義の trap install ブロックと衝突しないように reset)
    trap - EXIT INT TERM HUP
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

# cycle 48 F-01 (HIGH): writer/reader 対称化 doctrine (state-read.sh L88-96 と同型) に従い、
# atomic-cleanup 関数を 3 変数 (TMP_STATE / _mkdir_err / _jq_err) に拡張し、`_mkdir_err`
# (line 337 mktemp) を含む全 tempfile の lifecycle を cover する位置に trap を前倒し配置する。
# 旧実装の trap (line 421-428) は TMP_STATE のみ cleanup で `_mkdir_err` (mktemp 〜 rm 区間) と
# `_jq_err` (create-mode mktemp 〜 rm 区間) の race window で SIGINT/SIGTERM/SIGHUP 到達時に
# orphan tempfile が leak する非対称があった (verified-review F-01 HIGH)。canonical pattern
# 「パス先行宣言 → trap 先行設定 → mktemp」を踏襲する。
TMP_STATE=""
_mkdir_err=""
_jq_err=""
_rite_flow_state_atomic_cleanup() {
  rm -f "${TMP_STATE:-}" "${_mkdir_err:-}" "${_jq_err:-}"
}
trap 'rc=$?; _rite_flow_state_atomic_cleanup; exit $rc' EXIT
trap '_rite_flow_state_atomic_cleanup; exit 130' INT
trap '_rite_flow_state_atomic_cleanup; exit 143' TERM
trap '_rite_flow_state_atomic_cleanup; exit 129' HUP

if [[ "$FLOW_STATE" != "$LEGACY_FLOW_STATE" ]]; then
  _flow_state_dir=$(dirname "$FLOW_STATE")
  # Capture mkdir stderr so the kernel's specific failure reason
  # (`mkdir: cannot create directory '...': Not a directory` / `Permission denied` /
  # `No space left on device` 等) reaches the user instead of being suppressed
  # to /dev/null (review #686 cycle 2 LOW). Symmetric with the create-mode
  # `_jq_err` capture pattern.
  # PR #688 followup: cycle 41 review F-03 MEDIUM — mktemp 失敗時に WARNING emit。
  # 旧実装 `2>/dev/null || _mkdir_err=""` は silent fallback で writer/reader 対称化
  # doctrine と矛盾していた (reader 側 state-read.sh:256-261 は cycle 38 F-06 で
  # 修正済み)。/tmp full / SELinux deny 環境で mkdir 失敗 line/column が失われる
  # 二重 silent failure を防ぐ。
  # F-02 (MEDIUM) consolidation: 共通 helper `_mktemp-stderr-guard.sh` 経由で
  # Stderr emit + chmod 600 + path return を集約 (PR #688 cycle 9 F-02)。
  _mkdir_err=$(bash "$SCRIPT_DIR/_mktemp-stderr-guard.sh" \
    "flow-state-update" "flow-state-mkdir-err" \
    "mkdir 失敗時の error 詳細が表示されません")
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
    _mkdir_err=""  # cycle 48 F-01: trap による double-rm 防止 (set -u 下で unbound 化しないよう "" を維持)
    exit 1
  fi
  [ -n "$_mkdir_err" ] && rm -f "$_mkdir_err"
  _mkdir_err=""  # cycle 48 F-01: trap による double-rm 防止 (set -u 下で unbound 化しないよう "" を維持)
  # F-09 (MEDIUM, security Hypothetical exception): .rite/sessions/ ディレクトリにも chmod 700 を
  # 適用 (.rite-work-memory dir と同型)。multi-user CI runner / shared dev host で session metadata が
  # group-readable になる経路を防ぐ。chmod 失敗は best-effort skip (filesystem が ACL 非対応 / SELinux
  # 制約等で chmod 不能な環境でも flow-state 機能は維持する)。
  chmod 700 "$_flow_state_dir" 2>/dev/null || true
  # cycle 48 F-01: 旧実装の `unset _mkdir_err` は trap cleanup の `${_mkdir_err:-}` で問題ないが、
  # writer/reader 対称化 doctrine に従い再代入で "" に戻す (state-read.sh L148 と同型)。
  unset _flow_state_dir
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
    # verified-review cycle 44 F-13 LOW (security Hypothetical exception):
    # FIELD allowlist validation — state-read.sh:94 と writer/reader 対称化。
    # 現 caller は commands/issue/start.md:748 で `implementation_round` をハードコードしているのみだが、
    # FIELD は `_log_flow_diag "flow_state_jq_failed mode=increment field=$FIELD"` で .rite-stop-guard-diag.log
    # に書き込まれるため、改行を含む FIELD で log 形式破壊が可能。helper API 単体としての defense-in-depth gap
    # を埋めるため、識別子 (英数字 + _) のみ受理する。
    if ! [[ "$FIELD" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
      echo "ERROR: invalid field name: $FIELD" >&2
      echo "  field name must match ^[a-zA-Z_][a-zA-Z0-9_]*\$ (state-read.sh と対称化)" >&2
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
# PR #688 followup: cycle 41 review F-02/F-04 (HIGH/MEDIUM) — 旧実装は (a) PID-suffix
# silent fallback で symlink race 攻撃面が増加し、(b) compound 単一行 trap が
# canonical bash-trap-patterns.md 4-line signal-specific pattern と乖離していた。
# 本 PR の writer/reader 対称化 doctrine と整合させるため、(1) mktemp 失敗時は
# fail-fast (atomic write 不能 = exit 1)、(2) 4-line signal-specific trap で
# SIGINT/SIGTERM/SIGHUP の POSIX exit code 130/143/129 を返す pattern に統一する。
# canonical trap pattern: references/bash-trap-patterns.md#signal-specific-trap-template
#
# cycle 48 F-01 (HIGH): trap setup を本ファイル冒頭 (L325 直下) に前倒し済み。
# `_rite_flow_state_atomic_cleanup` は TMP_STATE / _mkdir_err / _jq_err の 3 変数を cover する。
# 旧 cycle 43 F-02 (HIGH) で確立した「パス先行宣言 → trap 先行設定 → mktemp」順序の延長で、
# `_mkdir_err` (line 337 mktemp) と create-mode `_jq_err` (line 520 mktemp) の race window も
# 同 trap で構造的に保護する。本箇所では既に declared/installed 済みの TMP_STATE への mktemp のみ。

if ! TMP_STATE=$(mktemp "${FLOW_STATE}.XXXXXX" 2>/dev/null); then
  echo "ERROR: flow-state-update.sh: TMP_STATE の mktemp に失敗しました (atomic write 不能)" >&2
  echo "  対処: $(dirname "$FLOW_STATE") の容量 / permission / read-only filesystem を確認してください" >&2
  # _log_flow_diag 関数は本ブロックの後段 (この case 文の直後) で定義されるため、ここでは inline で
  # diag log を書き込む。関数名 anchor で定義位置を semantic に参照する (cycle 43 F-02 で hardcoded
  # 行番号 L332 から関数名 anchor に置換)。
  _diag_file="$STATE_ROOT/.rite-stop-guard-diag.log"
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] tmp_state_mktemp_failed path=${FLOW_STATE}" >> "$_diag_file" 2>/dev/null || true
  unset _diag_file
  exit 1
fi

# F-09 (MEDIUM, security Hypothetical exception) / PR #688 cycle 12 F-06 (LOW) 訂正:
# atomic-write tempfile に chmod 600 を **defense-in-depth として明示適用**。
# **重要 — factual correction (cycle 12 F-06)**: 旧コメント「mktemp `${FLOW_STATE}.XXXXXX` で multi-user
# umask 022 環境では 644 で作成され」は GNU coreutils mktemp の実装と矛盾する factual error だった
# (man mktemp coreutils:「The file is created with mode 0600」)。実機検証済み: `umask 022; mktemp
# /tmp/test-XXXXXX` → mode 0600。したがって本 chmod 600 は **mktemp の OS デフォルト (600)** を冗長
# に強制するもので、現行 GNU coreutils 環境では機能上の差はない。
# それでも保持する理由 — defense-in-depth:
#   (1) 将来 mktemp 実装が変更された場合の保険
#   (2) 非 GNU 環境 (一部の BSD / busybox 等) への移植性
#   (3) 同 PR で他 helper (state-read.sh _jq_err / _resolve-cross-session-guard.sh /
#       _resolve-session-id-from-file.sh) と対称化を維持し、コードレビュー時の認知負荷を均一化
# Source: man mktemp (coreutils): "The file is created with mode 0600"
# multi-user CI runner / shared dev host で session_id・issue_number・branch・phase 等の metadata と
# (将来) 機密値を含む可能性がある file が他ユーザーに読まれる経路を構造的に塞ぐ。chmod 失敗は
# best-effort skip (cycle 41 F-14 と対称)。
chmod 600 "$TMP_STATE" 2>/dev/null || true

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
      # PR #688 followup: cycle 41 review F-03 MEDIUM — mktemp 失敗時に WARNING emit
      # (writer/reader 対称化、reader 側 state-read.sh:256-261 と統一)。
      # F-02 (MEDIUM) consolidation: 共通 helper `_mktemp-stderr-guard.sh` 経由で
      # Stderr emit + chmod 600 + path return を集約 (PR #688 cycle 9 F-02)。
      _jq_err=$(bash "$SCRIPT_DIR/_mktemp-stderr-guard.sh" \
        "flow-state-update" "flow-state-jq-err" \
        "jq 失敗時の parse error 詳細が表示されません (caller は corrupt JSON を検知できますが原因 line/column が失われます)")
      if PREV_PHASE=$(jq -r '.phase // ""' "$FLOW_STATE" 2>"${_jq_err:-/dev/null}"); then
        : # jq ok
      else
        echo "ERROR: flow-state file parse failed: $FLOW_STATE" >&2
        [ -n "$_jq_err" ] && [ -s "$_jq_err" ] && head -3 "$_jq_err" | sed 's/^/  /' >&2
        echo "  previous_phase cannot be preserved; failing fast to avoid silent cold-start." >&2
        echo "  対処: $FLOW_STATE を確認し、必要なら /rite:resume で復旧してください" >&2
        [ -n "$_jq_err" ] && rm -f "$_jq_err"
        _jq_err=""  # cycle 48 F-01: trap による double-rm 防止
        exit 1
      fi
      [ -n "$_jq_err" ] && rm -f "$_jq_err"
      _jq_err=""  # cycle 48 F-01: trap による double-rm 防止 (state-read.sh L148 と同型)
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
