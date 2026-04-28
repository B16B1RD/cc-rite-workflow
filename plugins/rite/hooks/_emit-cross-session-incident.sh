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
# 第 6 引数 pr_number はかつて cycle 44 F-09 で追加されたが、caller 6 site すべてが渡しておらず
# dead code 化していたため verified-review F-02 で撤去した (max 5 に restore、fallback_iter は "0-<epoch>" 固定)。
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

# verified-review F11-09 (MEDIUM): classification ごとの正しい argument count validation。
# foreign arm では extra_arg を参照しないため、5 番目の引数が渡されたら caller のタイプミスとして
# 検出する (corrupt / invalid_uuid arm と対称的に「classification ごとに正しい argument count」を
# validate)。旧実装は upper-bound のみで「foreign に 5 番目の引数を渡すと silent drop」していた。
case "$classification" in
  foreign)
    if [ -n "$extra_arg" ]; then
      echo "ERROR: _emit-cross-session-incident.sh: foreign arm does not accept 5th arg (extra_arg)." >&2
      echo "  received extra_arg: '$extra_arg'" >&2
      echo "  対処: foreign arm では classification / layer / current_sid / legacy_sid (4 args) のみ渡してください" >&2
      exit 1
    fi
    ;;
  corrupt|invalid_uuid)
    : # extra_arg (jq_rc / invalid_uuid_rc) を期待する arm
    ;;
  *)
    : # 不明 classification は下流の case 文で reject される
    ;;
esac

# F-07 (MEDIUM) 対応: session_id を redact してから details に埋め込む。
# 旧実装は full UUID を平文で埋め込み、`workflow-incident-emit.sh` 経由で
# `[CONTEXT] WORKFLOW_INCIDENT=1; details=...,current_sid=11111111-...,legacy_sid=22222222-...` として
# stderr/stdout に emit され、orchestrator (`start.md` Phase 5.4.4.1) が `AskUserQuestion` 経由で
# `create-issue-with-projects.sh` に渡し、ソース文字列のまま `Details: {details}` の Issue body 行として
# GitHub に publish していた。session_id は同一マシン上の他 LLM session を識別する内部 token であり、
# public repo / multi-tenant repo の Issue search で漏洩すると session 取得への足がかりになる
# (cycle 41 F-12 で sanitize は導入済みだが「機密値そのものの埋込」は未対応だった)。
# 先頭 8 文字 + `***` の redacted form に変換することで、debug 可能性 (異なる session の判別) を維持
# しつつ機密値漏洩を防ぐ。元の full UUID は本 helper の caller (state-read.sh / flow-state-update.sh)
# が独自の local diag log に記録する責務を持つ (リポ外、reposearch 不可)。
# redaction helper: 先頭 8 文字を保持 + `***` を append (UUID v4 想定: 36 chars)。
# 8 文字未満の文字列 (空文字 / 短い path 等) は変換せずそのまま使う (defense-in-depth)。
_redact_sid() {
  local v="$1"
  if [ ${#v} -ge 8 ]; then
    printf '%s***' "${v:0:8}"
  else
    printf '%s' "$v"
  fi
}
# verified-review F-13 (LOW、cross-validation: error-handling + security): foreign arm では
# legacy_sid_or_path は実際の session_id (UUID) のため redact が正しい。corrupt:* / invalid_uuid:* arm
# では同引数に absolute path (例: /home/user/project/.rite-flow-state) が渡されるため、redact すると
# `path=/home/us***` となり incident response 時に「どの project の flow-state file が corrupt か」が
# 特定不能になる (basename / repo 名の機密度を維持しつつ debug 可能性を確保するため `basename` のみ
# 抽出する形に降格する)。
current_sid_redacted=$(_redact_sid "$current_sid")
legacy_sid_redacted=$(_redact_sid "$legacy_sid_or_path")
# corrupt / invalid_uuid arm の path 表示用: basename を `.../` prefix 付きで emit する。
# 旧 _redact_sid (UUID 想定 8 chars + `***`) を path 値に適用すると `path=/home/us***` のように
# 「どの project 配下か」が完全に消失して incident response 不能になる (verified-review F-13 LOW)。
# basename + `.../` prefix で機密度の高い parent dir 構造 (社員 home / company name) を隠蔽
# しつつ、`.rite-flow-state` 等の固定名で「どの flow-state file が corrupt か」識別可能にする。
# 空文字は as-is (空のまま emit)。
_path_basename() {
  local v="$1"
  # verified-review F11-12 (LOW): edge case の semantic 整合性。`/` / `.` のような root-level path を
  # 渡されたとき basename は `/` / `.` を返し、前置 `.../` を付けると `...//` / `.../.` になり意味的に
  # 不自然。これらは「parent dir なし」の sentinel として as-is で返す (corrupt:* / invalid_uuid:* arm の
  # caller は通常 `<repo>/.rite-flow-state` 形式を渡すため到達しないが、helper API 単体としての
  # defense-in-depth)。基本方針は `_redact_sid` の「8 文字未満は as-is」と同型 (degenerate case 降格)。
  case "$v" in
    ""|/|.) printf '%s' "$v" ;;
    *)
      local b
      b=$(basename -- "$v")  # F11 security 推奨: `--` で end-of-options sentinel (例: `-rfoo` を path とした場合の basename option 誤認防止)
      printf '.../%s' "$b"
      ;;
  esac
}
legacy_path_basename=$(_path_basename "$legacy_sid_or_path")

# classification ごとに type / details / root-cause-hint を組み立てる
case "$classification" in
  foreign)
    incident_type="cross_session_takeover_refused"
    details="layer=${layer},current_sid=${current_sid_redacted},legacy_sid=${legacy_sid_redacted}"
    root_cause_hint="legacy_belongs_to_another_session_use_create_mode"
    ;;
  corrupt)
    incident_type="legacy_state_corrupt"
    details="layer=${layer},current_sid=${current_sid_redacted},path=${legacy_path_basename},jq_rc=${extra_arg}"
    root_cause_hint="legacy_jq_parse_failed_cannot_verify_session_ownership"
    ;;
  invalid_uuid)
    incident_type="legacy_state_corrupt"
    details="layer=${layer},current_sid=${current_sid_redacted},path=${legacy_path_basename},reason=invalid_uuid_format,rc=${extra_arg}"
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
  # fallback_iter prefix は "0" 固定 (caller 6 site のいずれも PR 番号を渡していないため、cycle 44 F-09
  # で導入した第 6 引数は dead code 化していた。verified-review F-02 で撤去し旧挙動に restore)。
  fallback_iter="0-$(date +%s)"
  # PR #688 followup: cycle 41 review F-12 MEDIUM (security Hypothetical exception) — fallback
  # sentinel が sanitize() を経由していなかった defense-in-depth gap を修正。details / root_cause_hint
  # に改行 / `;` が混入すると sentinel format `[CONTEXT] WORKFLOW_INCIDENT=1; type=...; details=...;`
  # が parse 不能になり Phase 5.4.4.1 grep 検出が break する経路を遮断 (workflow-incident-emit.sh
  # の sanitize() と writer/fallback 完全対称化)。
  details_sanitized=$(printf '%s' "$details" | tr -d '\n\r' | tr ';' ',')
  if [ -n "$root_cause_hint" ]; then
    hint_sanitized=$(printf '%s' "$root_cause_hint" | tr -d '\n\r' | tr ';' ',')
    fallback_sentinel="[CONTEXT] WORKFLOW_INCIDENT=1; type=${incident_type}; details=${details_sanitized}; root_cause_hint=${hint_sanitized}; iteration_id=${fallback_iter}"
  else
    fallback_sentinel="[CONTEXT] WORKFLOW_INCIDENT=1; type=${incident_type}; details=${details_sanitized}; iteration_id=${fallback_iter}"
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
  # verified-review cycle 38 F-13 LOW: corrupt と invalid_uuid は同一 incident_type (legacy_state_corrupt)
  # を共有するため、WARNING で両者を区別する suffix `(invalid_uuid)` を付加する 1 箇所だけが分岐していた。
  # 旧実装は if/else の特殊化で完全な 2 行 echo を保持していたが、suffix 変数 1 行で表現する方が DRY。
  invalid_uuid_suffix=""
  [ "$classification" = "invalid_uuid" ] && invalid_uuid_suffix=" (invalid_uuid)"
  echo "WARNING: workflow-incident-emit.sh exited non-zero (rc=$emit_rc) — sentinel may not have been emitted: type=${incident_type}${invalid_uuid_suffix}" >&2
fi
exit 0
