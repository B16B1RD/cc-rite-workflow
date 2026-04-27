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
# Why this exists (PR #688 follow-up F-01 MEDIUM):
#   reader (state-read.sh:140-205) と writer (flow-state-update.sh:172-230) で 3 arm × 2 layer = 6 ブロック
#   が semantically identical (差分は layer と current_sid 変数名のみ)。将来 sentinel 仕様変更時に
#   6 箇所同期更新が必要で drift リスクを抱えていた。本 helper で 1 箇所に集約する。
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
emit_script="$SCRIPT_DIR/workflow-incident-emit.sh"
if [ ! -x "$emit_script" ]; then
  echo "WARNING: workflow-incident-emit.sh missing — sentinel could not be emitted: type=${incident_type} details=${details}" >&2
  exit 0
fi

# verified-review cycle 36/37 fix (F-01 HIGH) と同型: if/else pattern で emit 失敗時の rc を捕捉する。
# `if !` パターンは `$?` が常に 0 を返す bash spec のため使わない。
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
