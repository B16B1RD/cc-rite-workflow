#!/bin/bash
# rite workflow - Cross-Session Incident Emit Helper
#
# Purpose: state-read.sh と flow-state-update.sh で 6 箇所重複していた
#   `case "$classification"` 配下の foreign:* / corrupt:* / invalid_uuid:* arm の
#   workflow-incident-emit.sh 呼び出しブロック (~84 行) を 1 行呼び出しに圧縮する。
#
# Usage:
#   bash _emit-cross-session-incident.sh <classification> <layer> <current_sid> <legacy_sid_or_path> [extra_arg]
#
# Arguments:
#   $1 classification     "foreign" / "corrupt" / "invalid_uuid"
#   $2 layer              "reader" / "writer"
#   $3 current_sid        現セッションの UUID
#   $4 legacy_sid_or_path foreign: legacy session_id / corrupt|invalid_uuid: legacy file path
#   $5 extra_arg          (optional)
#                          corrupt: jq_rc / invalid_uuid: invalid_uuid_rc
#
# Behavior:
#   - workflow-incident-emit.sh の場所を SCRIPT_DIR から自動解決
#   - 不在 / 非実行可能の場合は WARNING を stderr に出して exit 0 (sentinel emit 失敗を silent suppress しない)
#   - 呼び出し成功 / 失敗いずれの場合も stderr に診断を出し exit 0 で復帰 (caller が後段の DEFAULT 降格を続行できるように)
#
# Why this exists (PR #688 follow-up F-01 MEDIUM / cycle 38 F-03 MEDIUM):
#   reader (state-read.sh の per-session resolver の `case "$classification"` 配下) と
#   writer (flow-state-update.sh `_resolve_session_state_path` 内の `case "$classification"` 配下) で
#   3 arm × 2 layer = 6 ブロックが semantically identical (差分は layer と current_sid 変数名のみ)。
#   将来 sentinel 仕様変更時に 6 箇所同期更新が必要で drift リスクを抱えていた。本 helper で 1 箇所に
#   集約する。cycle 38 F-03: 旧コメントは `:140-205` / `:172-230` のハードコード行番号で参照していたが、
#   実際は cycle 重ね分の挿入で drift 済み (Wiki 経験則 .rite/wiki/index.md の「DRIFT-CHECK ANCHOR は
#   semantic name 参照」原則違反)。関数名 / case 構造名による semantic anchor に置換した。
#
# Exit codes:
#   0 — sentinel emit 試行完了 (caller は exit code に関係なく後段 DEFAULT 降格を実行する設計)
#   1 — argument error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$#" -lt 4 ]; then
  echo "ERROR: _emit-cross-session-incident.sh: 4 arguments required (classification layer current_sid legacy_sid_or_path [extra_arg])" >&2
  echo "  received: $#" >&2
  exit 1
fi
# upper bound check (caller のタイプミス検出)。
# 旧実装は `<4` のみだったため、6+ args を渡された場合 silently 受理されて余分な引数が drop されていた。
if [ "$#" -gt 5 ]; then
  echo "ERROR: _emit-cross-session-incident.sh: too many arguments (max 5: classification layer current_sid legacy_sid_or_path [extra_arg])" >&2
  echo "  received: $#" >&2
  exit 1
fi

classification="$1"
layer="$2"
current_sid="$3"
legacy_sid_or_path="$4"
extra_arg="${5:-}"

case "$layer" in
  reader|writer) ;;
  *)
    echo "ERROR: _emit-cross-session-incident.sh: invalid layer: '$layer' (expected: reader / writer)" >&2
    exit 1
    ;;
esac

# classification ごとに type / details / root-cause-hint を組み立てる
case "$classification" in
  foreign)
    incident_type="cross_session_takeover_refused"
    details="layer=${layer},current_sid=${current_sid},legacy_sid=${legacy_sid_or_path}"
    root_cause_hint="legacy_belongs_to_another_session_use_create_mode"
    ;;
  corrupt)
    incident_type="legacy_state_corrupt"
    details="layer=${layer},current_sid=${current_sid},path=${legacy_sid_or_path},jq_rc=${extra_arg}"
    root_cause_hint="legacy_jq_parse_failed_cannot_verify_session_ownership"
    ;;
  invalid_uuid)
    incident_type="legacy_state_corrupt"
    details="layer=${layer},current_sid=${current_sid},path=${legacy_sid_or_path},reason=invalid_uuid_format,rc=${extra_arg}"
    root_cause_hint="legacy_session_id_failed_uuid_validation_tampered_or_legacy_schema"
    ;;
  *)
    echo "ERROR: _emit-cross-session-incident.sh: unknown classification: '$classification' (expected: foreign / corrupt / invalid_uuid)" >&2
    exit 1
    ;;
esac

# workflow-incident-emit.sh 不在 / 非実行可能チェック (silent suppression 防止)
# verified-review cycle 38 F-08 MEDIUM: 不在時に canonical sentinel pattern を helper 自身が emit する。
# 旧実装は WARNING のみ stderr に出して exit 0 だったため、orchestrator (start.md Phase 5.4.4.1) の
# `[CONTEXT] WORKFLOW_INCIDENT=1` grep は WARNING line にマッチせず、cross_session_takeover_refused /
# legacy_state_corrupt / invalid_uuid 経路を Issue 自動登録できなかった (helper 上部のコメント
# 「sentinel emit 失敗を silent suppress しない」主張との乖離)。fallback sentinel を直接 emit して
# detection を保証する。pr/review.md / pr/fix.md / issue/close.md の Wiki Ingest 系 fallback emit と
# 同型 (workflow-incident-emit-protocol.md「Extended Pattern」セクション参照)。
# pr_number は本 helper の引数にないため fallback は `0-<epoch>`。caller chain でより精度の高い
# iteration_id を渡したい場合は workflow-incident-emit.sh が install されている前提で運用する。
emit_script="$SCRIPT_DIR/workflow-incident-emit.sh"
if [ ! -x "$emit_script" ]; then
  echo "WARNING: workflow-incident-emit.sh missing — emitting canonical fallback sentinel directly to keep Phase 5.4.4.1 detection intact: type=${incident_type}" >&2
  fallback_iter="0-$(date +%s)"
  if [ -n "$root_cause_hint" ]; then
    fallback_sentinel="[CONTEXT] WORKFLOW_INCIDENT=1; type=${incident_type}; details=${details}; root_cause_hint=${root_cause_hint}; iteration_id=${fallback_iter}"
  else
    fallback_sentinel="[CONTEXT] WORKFLOW_INCIDENT=1; type=${incident_type}; details=${details}; iteration_id=${fallback_iter}"
  fi
  # caller chain は stderr 経由 (state-read.sh / flow-state-update.sh の `2>/dev/null` 経路) を期待するため、
  # 本 fallback も stderr に出す (workflow-incident-emit.sh ヘッダ「Caller-side stderr redirect is permitted」
  # と整合)。
  echo "$fallback_sentinel" >&2
  exit 0
fi

# verified-review cycle 36/37 fix (F-01 HIGH) と同型: if/else pattern で emit 失敗時の rc を捕捉する。
# 変数 capture 文脈 (`if cmd; then ...; else rc=$?; fi`) では `if ! var=$(cmd); then rc=$?` 形式は `!` 演算子の
# 結果 (= 0) が `$?` に流入し、cmd 自身の exit code が取得できない (cycle 35 F-04 で empirical 検証済み:
# `bash -c 'if ! v=$(exit 42); then echo $?; fi'` → `0`)。本実装は `if cmd; then :; else rc=$?; fi` の
# canonical form を使う。なお `if ! cmd; then ...; fi` (キャプチャ無し) は `!` の挙動が異なるため本ガードの
# 適用範囲外 — `if !` 全般を avoid するのではなく **capture 文脈に限定して避ける** という限定的な制約である
# 点に注意 (cycle 38 F-16 LOW: 旧コメントが `if !` 全般を一律避けるかのような誤解を招く一般化表現だったため修正)。
if bash "$emit_script" \
    --type "$incident_type" \
    --details "$details" \
    --root-cause-hint "$root_cause_hint" >&2; then
  :
else
  emit_rc=$?
  if [ "$classification" = "invalid_uuid" ]; then
    echo "WARNING: workflow-incident-emit.sh exited non-zero (rc=$emit_rc) — sentinel may not have been emitted: type=${incident_type} (invalid_uuid)" >&2
  else
    echo "WARNING: workflow-incident-emit.sh exited non-zero (rc=$emit_rc) — sentinel may not have been emitted: type=${incident_type}" >&2
  fi
fi
exit 0
