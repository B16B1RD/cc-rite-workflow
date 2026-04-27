#!/bin/bash
# rite workflow - State Read Helper
# Reads a single field from the active session's flow-state file (per-session
# or legacy). Mirrors flow-state-update.sh's path-resolution rules so reader
# bash patterns scattered across command files (e.g. start.md Phase 3 / 5.5.1 /
# 5.6 pre-condition checks) cannot accidentally read another session's stale
# residue from .rite-flow-state.
#
# Usage:
#   bash plugins/rite/hooks/state-read.sh --field <name> [--default <val>]
#
# Examples:
#   curr=$(bash plugins/rite/hooks/state-read.sh --field phase --default "")
#   parent=$(bash plugins/rite/hooks/state-read.sh --field parent_issue_number --default 0)
#   loop=$(bash plugins/rite/hooks/state-read.sh --field loop_count --default 0)
#   pr=$(bash plugins/rite/hooks/state-read.sh --field pr_number --default "null")
#
# Resolution order (matches flow-state-update.sh semantics):
#   1. schema_version=2 + valid .rite-session-id UUID + per-session file exists
#      -> per-session file (.rite/sessions/{sid}.flow-state)
#   2. legacy file exists (.rite-flow-state)
#      -> legacy
#   3. neither
#      -> $DEFAULT
#
# Why this exists (Issue #687 AC-4):
#   When schema_version=2 routes flow-state writes to per-session files,
#   inline `jq -r '.<field>' .rite-flow-state` patterns read stale residue
#   left by a prior session — observed in #687 reproduction where Phase 3
#   pre-condition fetched phase5_post_stop_hook from another session's legacy
#   file instead of phase2_post_work_memory from the active per-session file.
#
# Exit codes:
#   0 — success (value or default printed to stdout)
#   1 — argument error / invalid field name
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Helper script existence check (verified-review cycle 34 fix F-09 MEDIUM):
# state-path-resolve.sh が unset / not executable の場合、`||` fallback で silent に cwd を採用する
# 経路があった (deploy regression / install 不整合の silent suppression)。fail-fast に格上げする。
if [ ! -x "$SCRIPT_DIR/state-path-resolve.sh" ]; then
  echo "ERROR: state-path-resolve.sh not found or not executable: $SCRIPT_DIR/state-path-resolve.sh" >&2
  echo "  対処: rite plugin が正しくセットアップされているか確認してください" >&2
  exit 1
fi

# Resolve repository root via the existing helper (single SoT).
# state-path-resolve.sh は現状 `return 0` 固定のため `||` fallback は dead code だが、
# 将来 git not found / cwd 不在等で non-zero を返す変更が入った際の defensive guard として
# 維持する。`set -euo pipefail` 下で fail-safe に cwd へ落とす契約を明示する。
#
# verified-review cycle 33 fix (F-04 MEDIUM): `2>/dev/null` を削除して stderr を pass-through する。
# defensive guard の本来の目的は「将来 non-zero return path で何が失敗したか観測可能にする」こと。
# 現状の return 0 固定では stderr 出力なし = 非 regression。将来 stderr を出すようになった際に
# 呼び出し側でも観測可能となる (本 PR cycle 5 以降の stderr 観測性優先方針と整合)。
STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$(pwd)") || STATE_ROOT="$(pwd)"
LEGACY_FLOW_STATE="$STATE_ROOT/.rite-flow-state"

# --- Argument parsing ---
FIELD=""
DEFAULT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --field)   FIELD="${2:-}"; shift 2 ;;
    --default) DEFAULT="${2:-}"; shift 2 ;;
    --)        shift; break ;;
    *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$FIELD" ]; then
  echo "ERROR: --field is required" >&2
  exit 1
fi

# Validate field name to keep the jq filter free of injection risk
# (we substitute FIELD as a literal accessor below).
if ! [[ "$FIELD" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
  echo "ERROR: invalid field name: $FIELD" >&2
  exit 1
fi

# --- Resolve session_id (matches flow-state-update.sh _resolve_session_id) ---
# UUID-format validation prevents path traversal via tampered .rite-session-id.
# PR #688 cycle 34 fix (F-01 CRITICAL): UUID validation を `_resolve-session-id.sh` 共通 helper に抽出。
# state-read.sh / flow-state-update.sh / resume-active-flag-restore.sh の 5 site で重複していた
# RFC 4122 strict pattern を 1 箇所に集約し、将来の pattern tightening (variant bit check 等) を
# 片肺更新 drift から守る。
SESSION_ID=""
if [ -f "$STATE_ROOT/.rite-session-id" ]; then
  raw=$(tr -d '[:space:]' < "$STATE_ROOT/.rite-session-id" 2>/dev/null) || raw=""
  if validated=$(bash "$SCRIPT_DIR/_resolve-session-id.sh" "$raw" 2>/dev/null); then
    SESSION_ID="$validated"
  fi
fi

# --- Resolve schema_version (DRY: shared helper with flow-state-update.sh) ---
# PR #688 cycle 5 review (code-quality + error-handling 推奨): writer/reader で同一の inline
# schema_version 解決 logic を持っていた drift リスクを排除するため、共通 helper に抽出済。
# pipefail silent failure 対策 (Issue #687 AC-4 follow-up) も helper 内で吸収する。
SCHEMA_VERSION=$(bash "$SCRIPT_DIR/_resolve-schema-version.sh" "$STATE_ROOT")

# --- Resolve target file ---
# Mirror flow-state-update.sh _resolve_session_state_path. Additional fallback:
# when schema_version=2 routes to per-session but that file is absent, fall back
# to legacy if present. This tolerates fresh sessions that have not yet written
# their per-session file but inherit a legacy snapshot from a prior session
# (the read-side counterpart to the writer-side migration path).
if [[ "$SCHEMA_VERSION" == "2" ]] && [[ -n "$SESSION_ID" ]]; then
  STATE_FILE="$STATE_ROOT/.rite/sessions/${SESSION_ID}.flow-state"
  if [ ! -f "$STATE_FILE" ] && [ -f "$LEGACY_FLOW_STATE" ]; then
    # verified-review cycle 34 fix (F-02 HIGH): cross-session guard を `_resolve-cross-session-guard.sh`
    # 共通 helper に抽出。writer 側 (flow-state-update.sh `_resolve_session_state_path`) と reader 側
    # (state-read.sh) で重複していた legacy.session_id 抽出 + 比較 + corrupt 判定ロジックを 1 箇所に
    # 集約し、Issue #687 root cause 「writer-side guard を cycle 32 で追加、reader-side guard を
    # cycle 33 で後追い」型の片肺更新 drift を構造的に防ぐ。
    classification=$(bash "$SCRIPT_DIR/_resolve-cross-session-guard.sh" "$LEGACY_FLOW_STATE" "$SESSION_ID" 2>&1) || true
    case "$classification" in
      same|empty)
        STATE_FILE="$LEGACY_FLOW_STATE"
        ;;
      foreign:*)
        # 別 session の legacy file → foreign session の stale data を silent return しないよう DEFAULT に降格。
        # canonical workflow-incident-emit.sh 経由で protocol-compliant sentinel を emit。
        legacy_sid="${classification#foreign:}"
        bash "$SCRIPT_DIR/workflow-incident-emit.sh" \
          --type cross_session_takeover_refused \
          --details "layer=reader,current_sid=${SESSION_ID},legacy_sid=${legacy_sid}" \
          --root-cause-hint "legacy_belongs_to_another_session_use_create_mode" >&2 || true
        echo "$DEFAULT"
        exit 0
        ;;
      corrupt:*)
        # jq 失敗 (corrupt JSON / IO error) → take over は不安全 (cross-session の可能性を否定できない)
        jq_rc="${classification#corrupt:}"
        bash "$SCRIPT_DIR/workflow-incident-emit.sh" \
          --type legacy_state_corrupt \
          --details "layer=reader,current_sid=${SESSION_ID},path=${LEGACY_FLOW_STATE},jq_rc=${jq_rc}" \
          --root-cause-hint "legacy_jq_parse_failed_cannot_verify_session_ownership" >&2 || true
        echo "$DEFAULT"
        exit 0
        ;;
      *)
        # Helper の出力が想定外 (defensive) — fail-safe に DEFAULT 降格
        echo "WARNING: unexpected classification from _resolve-cross-session-guard.sh: $classification" >&2
        echo "$DEFAULT"
        exit 0
        ;;
    esac
  fi
else
  STATE_FILE="$LEGACY_FLOW_STATE"
fi

# --- Read field ---
# F-C MEDIUM (PR #688 cycle 5 review test reviewer 推奨): 空ファイル / 非 JSON ファイルの edge case
# 旧実装は file 存在チェックのみで、空ファイル (`touch .rite-flow-state` 等) や非 JSON ファイル
# (例: 別プロセスが書き込み中) の場合に jq が exit 0 + 空出力を返す → caller default が
# 効かず空文字列を silent return する経路があった。`[ -s "$STATE_FILE" ]` (size > 0) を追加して
# 空ファイル時も DEFAULT に落とす (corrupt JSON 経路と挙動を一致させる)。
if [ ! -f "$STATE_FILE" ] || [ ! -s "$STATE_FILE" ]; then
  echo "$DEFAULT"
  exit 0
fi

# Pass DEFAULT through jq's --arg so quoting/escaping is handled by jq.
# FIELD has been validated as [a-zA-Z_][a-zA-Z0-9_]* so direct interpolation
# into the filter is safe. This helper is read-only — no object construction
# (the silent-reset failure mode of writer-side jq is not applicable here).
#
# JSON null handling: jq's `// $default` operator returns $default when the
# left-hand side is null or false. So `.field // $default` evaluates to
# $default when:
#   - field is missing (jq returns null)
#   - field exists but holds JSON null
#   - field exists but holds JSON false
# This matches the caller-supplied default semantics natively — no
# post-processing is needed. (PR #688 cycle 3 review: previous post-processing
# `if [ "$value" = "null" ]` was demonstrated to be dead code via mutation
# testing; jq's `//` already handles null normalization.)
#
# ⚠️ Boolean field caveat (PR #688 cycle 5 review): jq の `// $default` は **null と
# false の両方** を $default に置換するため、本 helper は boolean field の読み取りには
# **使ってはいけない**。例: `{"active": false}` を `--default true` で読むと結果は "true"
# となり、stored false が silent に default に置換される。現状の caller (`parent_issue_number`
# / `phase` / `loop_count` / `implementation_round` / `pr_number`) はすべて非 boolean のため影響なし。
# 将来 boolean field を読む caller を追加する場合は `--default empty` で明示的に取得して
# 別途分岐するか、inline jq を使うこと。
#
# verified-review cycle 34 fix (F-11 MEDIUM): mechanical guard を追加。`--default true` / `--default false`
# が指定された場合、boolean field 読み取り意図の可能性が高いので WARNING を emit する (誤呼出経路の
# silent regression を防ぐ defense-in-depth)。
case "$DEFAULT" in
  true|false)
    echo "WARNING: state-read.sh: --default '$DEFAULT' は boolean リテラル値です。boolean field の読み取りには本 helper を使わないでください (jq の \`// \$default\` 演算子が JSON null と false の両方を default に置換するため、stored false が silent に true に置換される regression を起こします)。non-boolean field (parent_issue_number / phase / loop_count / pr_number 等) のみが現状サポート対象です。boolean field が必要な場合は \`--default empty\` を使い caller 側で明示分岐するか、inline jq を使ってください。" >&2
    ;;
esac
#
# Source: jq Manual — Alternative operator `//`
# https://jqlang.org/manual/#alternative-operator
value=$(jq -r --arg default "$DEFAULT" ".${FIELD} // \$default" "$STATE_FILE" 2>/dev/null) \
  || value="$DEFAULT"

echo "$value"
