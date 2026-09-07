#!/bin/bash
# cleanup-follow-up-issue.sh — /rite:cleanup ステップ 6.0
#
# マージ済み PR の review-results JSON から残存非実測指摘 (non_blocking_findings[]) を読み、
# follow-up Issue を 1 件起票する。0 件なら起票しない。同一 PR 由来の既存 follow-up があれば
# 重複起票しない。cleanup 全体は止めない (引数不正のみ exit 1)。
#
# 転記対象は**同一 PR の全 JSON の `non_blocking_findings[]` の和集合**。各 JSON はその cycle の
# 観測にすぎず、最新 1 本は残存集合ではない (先行 cycle にのみ載る指摘を取りこぼす)。解消済みの
# 除外は cleanup ステップ 6.0.V の再検証が `--exclude-ids` で担う。
#
# 転記元は archive 前の JSON。archive helper は本スクリプトの後に走る (D-04)。
#
# Usage:
#   cleanup-follow-up-issue.sh --state-root <dir> --pr <n> \
#     --owner <owner> --repo <repo> [options]
#
# Options:
#   --state-root         state-path-resolve.sh の解決結果。必須
#   --pr                 PR 番号 (数値)。必須
#   --owner              repo owner (-R 用)。必須
#   --repo               repo name。必須
#   --source-issue       元 Issue 番号。空 / 省略可
#   --project-number     Projects 番号。projects-enabled=true のとき必須。
#                        非数値なら WARNING のうえ Projects を無効化して起票する
#   --project-owner      Projects owner。省略時は --owner
#   --projects-enabled   true|false。省略時 false
#   --create-script      create-issue-with-projects.sh のパス。テスト注入用。省略時は plugin 内の実体
#   --exclude-ids        転記から除外する finding id の CSV (例: "F-01,F-05")。cleanup ステップ 6.0 が
#                        マージ後 HEAD で再検証し `resolved` と判定した id だけを渡す。空文字列 /
#                        省略は「除外なし」であり引数不正ではない (後方互換)。既知 id と一致しない
#                        値は WARNING のうえ無視し、残りの除外を適用して続行する。
#                        和集合内で同一 id が複数 finding に付いている場合、その id は identity として
#                        曖昧なため除外せずその id の finding を全件転記する (他の id の除外は継続する)。
#                        WARNING と marker で surface し過剰転記側へ倒す。
#                        **除外が要求より少なく適用された経路はすべて FOLLOW_UP_EXCLUDE_AMBIGUOUS を
#                        出す**（reason= で区別する。下記 Emitted markers 参照）
#
# Exit codes:
#   0: 正常終了 (起票 / skip / 非ブロッキング失敗を含む)
#   1: 引数不正
#
# Emitted markers (stderr):
#   [CONTEXT] FOLLOW_UP_ISSUE=created; issue=<n>; pr=<n>
#   [CONTEXT] FOLLOW_UP_ISSUE=skipped; reason=no_findings|all_resolved|no_json|already_exists|jq_missing; pr=<n>
#     no_findings  : parse できた JSON の和集合が、除外を適用する前から 0 件
#     all_resolved : 除外**後**に 0 件になった (再検証で全件が解消済みと判定された)
#   [CONTEXT] FOLLOW_UP_ISSUE=failed; reason=lookup_api|create_api|create_script_missing|json_undecidable; pr=<n>
#   [CONTEXT] FOLLOW_UP_EXCLUDE_AMBIGUOUS=1; reason=<r>; count=<n|unknown>; pr=<n>
#     除外要求どおりに除外できなかったことを cleanup ステップ 12 へ通知する。
#     marker 不在から除外適用・起票の成功を推定しない。起票結果は FOLLOW_UP_ISSUE で判定する。
#       reason=ambiguous    : 和集合内で複数 finding に一致した id だけを除外拒否した。
#                             count = 拒否した id の異なり数 (他の id の除外は適用済み)
#       reason=undecidable  : 曖昧判定 / 除外解除の jq が失敗し除外を全破棄した。
#                             count = 除外要求 id の総数 (適用された除外は 0 件)
#       reason=parse_failed : --exclude-ids を解析できず除外を全破棄した。count=unknown
#       reason=apply_failed : 除外適用の jq が失敗し除外を全破棄した。count = 要求 id 総数
#
# Emitted summary (stdout, 1 行):
#   [cleanup-follow-up-issue] result=<created|skipped|failed>; ...
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=lib/tempfile.sh
source "$SCRIPT_DIR/lib/tempfile.sh"
# 診断スニペットの制御文字を潰す canonical helper (SoT: control-char-neutralize.sh header)
# shellcheck source=../control-char-neutralize.sh
source "$SCRIPT_DIR/../control-char-neutralize.sh"

MARKER_PREFIX='[rite-follow-up-from-pr:'

STATE_ROOT=""
PR_NUMBER=""
OWNER=""
REPO=""
SOURCE_ISSUE=""
PROJECT_NUMBER=""
PROJECT_OWNER=""
PROJECTS_ENABLED="false"
CREATE_SCRIPT=""
EXCLUDE_IDS=""

_require_option_value() {
  if [ -z "${2:-}" ]; then
    echo "ERROR: cleanup-follow-up-issue: $1 requires a value" >&2
    exit 1
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --state-root)       _require_option_value "$1" "${2:-}"; STATE_ROOT="$2"; shift 2 ;;
    --pr)               _require_option_value "$1" "${2:-}"; PR_NUMBER="$2"; shift 2 ;;
    --owner)            _require_option_value "$1" "${2:-}"; OWNER="$2"; shift 2 ;;
    --repo)             _require_option_value "$1" "${2:-}"; REPO="$2"; shift 2 ;;
    --source-issue)     SOURCE_ISSUE="${2:-}"; shift 2 ;;
    --project-number)   PROJECT_NUMBER="${2:-}"; shift 2 ;;
    --project-owner)    PROJECT_OWNER="${2:-}"; shift 2 ;;
    --projects-enabled) PROJECTS_ENABLED="${2:-false}"; shift 2 ;;
    --create-script)    CREATE_SCRIPT="${2:-}"; shift 2 ;;
    # 空値許容 option。`_require_option_value` を使わないのは、空文字列が「除外なし」という
    # 正当な入力であり引数不正ではないため (再検証が undecidable / skip の呼び出し側は空で渡す)。
    # ここを exit 1 にすると呼び出し側が helper_rc 失敗に落ち、完了報告で「未完了」に倒れる。
    --exclude-ids)      EXCLUDE_IDS="${2:-}"; shift 2 ;;
    *)
      echo "ERROR: cleanup-follow-up-issue: unknown option: $1" >&2
      exit 1 ;;
  esac
done

case "$PR_NUMBER" in
  ''|*[!0-9]*)
    echo "ERROR: cleanup-follow-up-issue: --pr must be numeric (got: '${PR_NUMBER}')" >&2
    exit 1 ;;
esac
if [ -z "$STATE_ROOT" ]; then
  echo "ERROR: cleanup-follow-up-issue: --state-root is required" >&2
  exit 1
fi
if [ -z "$OWNER" ] || [ -z "$REPO" ]; then
  echo "ERROR: cleanup-follow-up-issue: --owner and --repo are required" >&2
  exit 1
fi
case "$SOURCE_ISSUE" in
  ''|0) SOURCE_ISSUE="" ;;
  *[!0-9]*)
    echo "ERROR: cleanup-follow-up-issue: --source-issue must be numeric (got: '${SOURCE_ISSUE}')" >&2
    exit 1 ;;
esac
case "$PROJECTS_ENABLED" in
  true|yes|1) PROJECTS_JSON=true ;;
  *) PROJECTS_JSON=false ;;
esac
[ -n "$PROJECT_OWNER" ] || PROJECT_OWNER="$OWNER"
case "$PROJECT_NUMBER" in
  ''|*[!0-9]*)
    if [ "$PROJECTS_JSON" = true ]; then
      echo "WARNING: --project-number が数値ではないため Projects 登録を skip します (got: '${PROJECT_NUMBER}')。follow-up Issue 自体は起票します" >&2
      PROJECTS_JSON=false
    fi
    PROJECT_NUMBER=0
    ;;
esac
[ -n "$CREATE_SCRIPT" ] || CREATE_SCRIPT="$PLUGIN_ROOT/scripts/create-issue-with-projects.sh"

emit_skip() {
  local reason="$1"
  echo "[CONTEXT] FOLLOW_UP_ISSUE=skipped; reason=${reason}; pr=${PR_NUMBER}" >&2
  echo "[cleanup-follow-up-issue] result=skipped; reason=${reason}; pr=${PR_NUMBER}"
}

emit_failed() {
  local reason="$1"
  echo "[CONTEXT] FOLLOW_UP_ISSUE=failed; reason=${reason}; pr=${PR_NUMBER}" >&2
  echo "[cleanup-follow-up-issue] result=failed; reason=${reason}; pr=${PR_NUMBER}"
}

MARKER="${MARKER_PREFIX}${PR_NUMBER}]"
LOOKUP_LIMIT=100
results_dir="$STATE_ROOT/.rite/review-results"

rite_tempfile_init || exit 1
rite_tempfile_new list_err "fu-list" || exit 1
rite_tempfile_new create_err_file "fu-create" || exit 1

if ! command -v jq >/dev/null 2>&1; then
  echo "WARNING: jq が見つからないため残存非実測指摘を判定できません。follow-up 起票を skip します (PR #${PR_NUMBER})" >&2
  echo "  対処: jq を導入してください" >&2
  emit_skip jq_missing
  exit 0
fi

# 同一 PR の全 JSON の `non_blocking_findings[]` を和集合して転記対象にする。
# `non_blocking_findings[]` は**その cycle の観測**であり、最終 cycle の JSON は「その PR の
# 残存集合」ではない。最新 1 本だけを読むと、先行 cycle にのみ載る指摘が HEAD に残存していても
# follow-up に載らず機械経路から黙って消える。残存判定 (解消済みの除外) は cleanup ステップ
# 6.0.V の再検証が `--exclude-ids` で担い、本 helper は「全 cycle で記録された集合」を作る。
#
# **id では畳まない**。`id` は各 JSON 内で振り直される連番であり cycle を跨いだ identity を持たない
# (cycle 間の同一性判断は pr-review の semantic 判断が担い、本配列に機械的 identity キーは無い)。同じ `F-07` が cycle ごとに
# 別の指摘を指すため、id を key に畳むと別々の指摘が黙って 1 件に潰れる — 本 helper が防ごうとしている
# 取りこぼしそのものになる。よって全 cycle 分を**そのまま連結**する。同一 id の見出しが body に複数出るが、
# それらは実際に別の指摘なので正しい。
# 走査順は basename 昇順 (= cycle 昇順) に固定する。
# glob 未展開の pattern 文字列は実在検査で弾く (archive-or-rm と同型)。
findings_json="[]"
matched=0
parsed=0
unparsed=0
rite_tempfile_new union_tmp "fu-union" || exit 1
printf '[]\n' > "$union_tmp"
# jq の原因行を捨てない。除外の理由 (どの key が壊れているか) は stderr にしか出ない。
rite_tempfile_new union_err "fu-union-err" || exit 1
# bash の glob 展開は basename 昇順で確定するため、この for がそのまま cycle 昇順の連結になる。
for f in "$results_dir/${PR_NUMBER}"-*.json*; do
  { [ -e "$f" ] || [ -L "$f" ]; } || continue
  matched=$((matched + 1))
  : > "$union_err"
  if ! part=$(jq -c 'if (.non_blocking_findings | type) == "array" then .non_blocking_findings else error("non_blocking_findings is not an array") end' "$f" 2>"$union_err"); then
    # 部分的な parse 失敗で全滅させない。健全な側の和集合で続行し、全滅時だけ json_undecidable。
    echo "WARNING: レビュー結果 JSON を読めないため和集合から除外します (PR #${PR_NUMBER}): $f" >&2
    [ -s "$union_err" ] && head -3 "$union_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    unparsed=$((unparsed + 1))
    continue
  fi
  # 連結のみ。id / 内容による畳み込みはしない (上のコメント参照)。
  : > "$union_err"
  if ! merged=$(jq -c --argjson add "$part" '. + $add' "$union_tmp" 2>"$union_err"); then
    echo "WARNING: 和集合の統合に失敗したため当該 JSON を除外します (PR #${PR_NUMBER}): $f" >&2
    [ -s "$union_err" ] && head -3 "$union_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    unparsed=$((unparsed + 1))
    continue
  fi
  printf '%s\n' "$merged" > "$union_tmp"
  parsed=$((parsed + 1))
done

if [ "$matched" -eq 0 ]; then
  echo "WARNING: PR #${PR_NUMBER} のレビュー結果 JSON が見つかりません。follow-up 起票を skip します (別環境での cleanup の可能性。cycle 中記録は関連 Issue コメントを参照)" >&2
  emit_skip no_json
  exit 0
fi

if [ "$parsed" -eq 0 ]; then
  echo "WARNING: PR #${PR_NUMBER} のレビュー結果 JSON ${matched} 本すべてを判定できません。follow-up 起票を skip します" >&2
  emit_failed json_undecidable
  exit 0
fi

# どの範囲から転記したかを完了報告から追えるようにする (本数 + 除外された本数)
echo "[cleanup-follow-up-issue] union: pr=${PR_NUMBER}; json_total=${matched}; json_parsed=${parsed}; json_unparsed=${unparsed}" >&2
if [ "$unparsed" -gt 0 ]; then
  echo "WARNING: 和集合から除外された JSON が ${unparsed} 本あります。転記対象の欠落を確認してください (PR #${PR_NUMBER})" >&2
fi

findings_json=$(cat "$union_tmp")
if ! printf '%s' "$findings_json" | jq -e 'length > 0' >/dev/null; then
  emit_skip no_findings
  exit 0
fi

# 再検証による除外は上の JSON 判定層とは独立の層なので `case` の arm 内に入れない
# (arm 内へ入れると JSON 判定が degraded に降りた経路で一度も走らない)。
# 0 件判定は 2 段に分ける: 除外**前** 0 件は従来どおり no_findings (記録時点で指摘が無い)、
# 除外**後** 0 件だけが all_resolved (再検証で全件が解消済みと判定された)。両者を潰すと
# 既存の no_findings 契約が回帰する。どちらも gh issue list より前に exit する。
if [ -n "$EXCLUDE_IDS" ]; then
  # `-s` で入力全体を 1 文字列として読む。行単位 (`jq -R` 単体) だと改行入りの入力が
  # JSON 配列の複数連結になり、非空判定を通過した後で `--argjson` が rc=2 で落ちて
  # unknown id の WARNING が無言で消える。改行も区切りとして畳めばその経路自体が無くなる。
  exclude_json=$(printf '%s' "$EXCLUDE_IDS" | jq -Rsc '
    split("\n") | join(",") | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)) | unique') || exclude_json=""
  if [ -z "$exclude_json" ]; then
    echo "WARNING: --exclude-ids を解析できませんでした ('${EXCLUDE_IDS}')。除外を適用せず全件を転記します (PR #${PR_NUMBER})" >&2
    # 除外を 1 件も適用していないので marker を出す (下記「除外ゼロなら必ず marker」参照)。
    # 要求件数は数えられない (解析に失敗した入力しか無い) ので count=unknown。
    echo "[CONTEXT] FOLLOW_UP_EXCLUDE_AMBIGUOUS=1; reason=parse_failed; count=unknown; pr=${PR_NUMBER}" >&2
  else
    unknown_ids=$(printf '%s' "$findings_json" | jq -r --argjson ex "$exclude_json" '
      ([.[] | .id // empty]) as $known | $ex - $known | join(", ")')
    if [ -n "$unknown_ids" ]; then
      # fail-loud: 一致しない id を silent に無視しない。転記自体は続行する (非ブロッキング)
      echo "WARNING: --exclude-ids に non_blocking_findings[] と一致しない id が含まれます: ${unknown_ids} (PR #${PR_NUMBER})。一致した id のみ除外して続行します" >&2
    fi
    # 和集合内で**同じ id が複数の finding に付いている**場合、その id は除外 key として曖昧になる
    # (`id` は各 cycle 内の連番であり cycle 跨ぎの identity ではない)。6.0.V が片方だけを resolved と
    # 判定しても `--exclude-ids` は id 一致で両方を落とすため、残存している側が黙って消える。
    # よって曖昧な id は**除外せず全件を残し**、WARNING で surface する (過剰転記側へ倒す。
    # `undecidable` は転記する / `id: null` は必ず `undecidable` と同じ方針)。
    # 判定 jq が失敗したら、除外をそのまま適用する側 (未解消の指摘が落ちうる危険側) ではなく
    # 除外なしで全件転記する側へ倒す。下の除外解除 jq の失敗ハンドラと同じ向きに揃えてある。
    ambiguous_json=$(printf '%s' "$findings_json" | jq -c --argjson ex "$exclude_json" '
      [ .[] | .id // empty ] | group_by(.) | map(select(length > 1) | .[0])
      | map(select(. as $i | $ex | index($i))) | unique') \
      || {
        # 除外要求を全件拒否したので marker を出す。ここで落とすと「除外が 1 件も効いていないのに
        # 完了報告は解消済み N と出す」報告乖離になる。
        # count は**除外要求 id の総数**で、成功経路の「曖昧 id の異なり数」とは母集団が違う。
        # reason= で区別し、消費側 (cleanup ステップ 12) が文面を出し分ける。
        # ここへ到達している時点で上流の jq -Rsc は成功しており exclude_json は妥当な JSON 配列
        # なので、length が入力理由で落ちることはない (到達不能な fallback を置かない)。
        _amb_req=$(printf '%s' "$exclude_json" | jq -r 'length')
        echo "WARNING: 曖昧 id の判定に失敗しました。除外なしで全件を転記します (PR #${PR_NUMBER})" >&2
        echo "[CONTEXT] FOLLOW_UP_EXCLUDE_AMBIGUOUS=1; reason=undecidable; count=${_amb_req}; pr=${PR_NUMBER}" >&2
        ambiguous_json="[]"; exclude_json='[]'
      }
    if printf '%s' "$ambiguous_json" | jq -e 'length > 0' >/dev/null 2>&1; then
      # id は信頼できない入力 (レビュアーが書く JSON) なので、素の値は neutralize_ctrl を通す。
      # 件数サフィックスは bash 側で付ける。default 範囲は C0 + DEL + 0x80-0x9F を**バイト単位**で
      # 潰すため、文字列全体を通すと WARNING 本文の日本語 (例 `和` = E5 92 8C) が巻き込まれる。
      ambiguous_detail=""
      while IFS=$'\t' read -r _amb_id _amb_n; do
        [ -n "$_amb_id" ] || continue
        _amb_safe=$(printf '%s' "$_amb_id" | neutralize_ctrl)
        ambiguous_detail="${ambiguous_detail:+${ambiguous_detail}, }${_amb_safe} (${_amb_n} 件)"
      done < <(printf '%s' "$findings_json" | jq -r --argjson amb "$ambiguous_json" '
        [ .[] | .id // empty ] | group_by(.)
        | .[] | select(.[0] as $i | $amb | index($i)) | [.[0], (length | tostring)] | @tsv')
      ambiguous_count=$(printf '%s' "$ambiguous_json" | jq -r 'length')
      echo "WARNING: --exclude-ids の id が和集合内で複数の finding に一致するため除外しません: ${ambiguous_detail} (PR #${PR_NUMBER})。id は cycle ごとの連番で cycle 跨ぎの identity を持たないため、片方だけが解消済みでも両方を落とすと残存指摘が消えます。全件を転記します" >&2
      # 起票結果とは独立に、除外を拒否したことを完了報告へ渡す。
      # count は除外を拒否した id の異なり数 (転記された finding 件数ではない)。
      echo "[CONTEXT] FOLLOW_UP_EXCLUDE_AMBIGUOUS=1; reason=ambiguous; count=${ambiguous_count}; pr=${PR_NUMBER}" >&2
      if remaining_excludes=$(printf '%s' "$exclude_json" | jq -c --argjson amb "$ambiguous_json" '. - $amb'); then
        exclude_json="$remaining_excludes"
      else
          # 直前に reason=ambiguous の marker を出しているが、そちらは「一部の id を除外できない」
          # 意味で、こちらは「除外を全破棄した」意味。件数も母集団が違うので改めて出す。
          _amb_req=$(printf '%s' "$exclude_json" | jq -r 'length')
          echo "WARNING: 曖昧 id の除外解除に失敗しました。除外なしで全件を転記します (PR #${PR_NUMBER})" >&2
          echo "[CONTEXT] FOLLOW_UP_EXCLUDE_AMBIGUOUS=1; reason=undecidable; count=${_amb_req}; pr=${PR_NUMBER}" >&2
          exclude_json='[]'
      fi
    fi
    if filtered_json=$(printf '%s' "$findings_json" | jq -c --argjson ex "$exclude_json" '
      [.[] | select((.id // "") as $i | ($ex | index($i)) | not)]'); then
      findings_json="$filtered_json"
    else
      # 除外を 1 件も適用できていないので marker を出す (「除外ゼロなら必ず marker」)。
      _amb_req=$(printf '%s' "$exclude_json" | jq -r 'length' 2>/dev/null) || _amb_req=unknown
      echo "WARNING: 除外適用に失敗しました。除外なしで全件を転記します (PR #${PR_NUMBER})" >&2
      echo "[CONTEXT] FOLLOW_UP_EXCLUDE_AMBIGUOUS=1; reason=apply_failed; count=${_amb_req}; pr=${PR_NUMBER}" >&2
    fi
  fi
  if ! printf '%s' "$findings_json" | jq -e 'length > 0' >/dev/null; then
    emit_skip all_resolved
    exit 0
  fi
fi

# 同定不能は重複起票より起票失敗に倒す (D-03)。Search API は hyphen をトークン分割するため使わない。
# follow-up ラベルの List API + 先頭行の HTML コメント (<!-- ${MARKER} -->) で確定する。
# finding 本文の同一文字列は identity ではない。件数が --limit に達して marker 不在なら lookup_api。
list_json=$(gh issue list -R "${OWNER}/${REPO}" --state all \
  --label follow-up --limit "$LOOKUP_LIMIT" \
  --json number,body 2>"$list_err")
list_rc=$?
if [ "$list_rc" -ne 0 ]; then
  echo "WARNING: 既存 follow-up の検索に失敗したため起票しません (重複起票を避ける)。手動確認: gh issue list -R ${OWNER}/${REPO} --label follow-up --state all" >&2
  [ -s "$list_err" ] && tr -d '\r' < "$list_err" | sed 's/^/  /' >&2
  emit_failed lookup_api
  exit 0
fi

existing_n=$(printf '%s' "$list_json" | jq -r --arg m "$MARKER" \
  '[.[] | select(((.body // "") | split("\n")[0]) == ("<!-- " + $m + " -->")) | .number] | first // empty') || {
  echo "WARNING: 既存 follow-up の検索結果を解析できません。起票しません (PR #${PR_NUMBER})" >&2
  emit_failed lookup_api
  exit 0
}
if [ -n "$existing_n" ]; then
  echo "[CONTEXT] FOLLOW_UP_ISSUE=skipped; reason=already_exists; issue=${existing_n}; pr=${PR_NUMBER}" >&2
  echo "[cleanup-follow-up-issue] result=skipped; reason=already_exists; issue=${existing_n}; pr=${PR_NUMBER}"
  exit 0
fi

list_n=$(printf '%s' "$list_json" | jq 'length') || list_n=""
case "$list_n" in
  ''|*[!0-9]*)
    echo "WARNING: 既存 follow-up の件数を確定できません。起票しません (PR #${PR_NUMBER})" >&2
    emit_failed lookup_api
    exit 0
    ;;
esac
if [ "$list_n" -ge "$LOOKUP_LIMIT" ]; then
  echo "WARNING: follow-up ラベルの Issue が --limit ${LOOKUP_LIMIT} に達したため既存の有無を確定できません。重複起票を避けるため起票しません (PR #${PR_NUMBER})" >&2
  echo "  手動確認: gh issue list -R ${OWNER}/${REPO} --label follow-up --state all" >&2
  emit_failed lookup_api
  exit 0
fi

if [ ! -x "$CREATE_SCRIPT" ] && [ ! -f "$CREATE_SCRIPT" ]; then
  echo "WARNING: create-issue-with-projects.sh が見つかりません (${CREATE_SCRIPT})。follow-up 起票を skip します" >&2
  emit_failed create_script_missing
  exit 0
fi

rite_tempfile_new body_file "fu-body" || exit 1
rite_tempfile_new comment_file "fu-comment" || exit 1

source_issue_line=""
[ -n "$SOURCE_ISSUE" ] && source_issue_line="- 元 Issue: #${SOURCE_ISSUE}"

# body Meta と Projects 引数で同一値を使う（二重定義しない）
_fu_type="fix"
_fu_complexity="S"
_fu_priority="Medium"

if ! findings_md=$(printf '%s' "$findings_json" | jq -r --arg dash "—" --arg empty "" '
  .[] |
  "### \(.id // $dash) (\(.severity // $dash)) — \(.reviewer // $dash)\n\n" +
  "- 場所: `\(.file // $dash):\((.line | if . == null then $dash else tostring end))`\n" +
  "- 説明: \(.description // $empty)\n" +
  "- 提案: \(.suggestion // $empty)\n"
') || [ -z "$findings_md" ]; then
  echo "WARNING: follow-up finding 本文の生成に失敗しました。起票しません" >&2
  emit_failed create_api
  exit 0
fi

{
  printf '%s\n' "<!-- ${MARKER} -->"
  printf '%s\n' "**Type**: ${_fu_type}"
  printf '%s\n' "**Complexity**: ${_fu_complexity}"
  printf '%s\n' ""
  printf '%s\n' "## 概要"
  printf '%s\n' ""
  printf '%s\n' "PR #${PR_NUMBER} のマージ時点で残った非実測指摘を follow-up として切り出す。"
  printf '%s\n' ""
  printf '%s\n' "## 出典"
  printf '%s\n' ""
  printf '%s\n' "- 元 PR: #${PR_NUMBER}"
  [ -n "$source_issue_line" ] && printf '%s\n' "$source_issue_line"
  printf '%s\n' "- 機械同定: \`${MARKER}\`"
  printf '%s\n' ""
  printf '%s\n' "## 残存非実測指摘"
  printf '%s\n' ""
  printf '%s\n' "$findings_md"
} > "$body_file"

if [ ! -s "$body_file" ]; then
  echo "WARNING: follow-up Issue body の生成に失敗しました (tmpfile が空)。起票しません" >&2
  emit_failed create_api
  exit 0
fi

gh label create follow-up -R "${OWNER}/${REPO}" \
  --description "マージ時の残存非実測指摘" --color "c5def5" >/dev/null 2>&1 || true

title="follow-up: PR #${PR_NUMBER} の残存非実測指摘"
args_json=$(jq -n \
  --arg title "$title" \
  --arg body_file "$body_file" \
  --argjson projects_enabled "$PROJECTS_JSON" \
  --argjson project_number "$PROJECT_NUMBER" \
  --arg owner "$PROJECT_OWNER" \
  --arg priority "$_fu_priority" \
  --arg complexity "$_fu_complexity" \
  --arg iter_mode "none" \
  '{
    issue: { title: $title, body_file: $body_file, labels: ["follow-up"] },
    projects: {
      enabled: $projects_enabled,
      project_number: $project_number,
      owner: $owner,
      status: "Todo",
      priority: $priority,
      complexity: $complexity,
      iteration: { mode: $iter_mode }
    },
    options: { source: "cleanup", non_blocking_projects: true }
  }') || {
  echo "WARNING: follow-up args_json の jq 構築に失敗しました。起票しません" >&2
  emit_failed create_api
  exit 0
}

result=$(bash "$CREATE_SCRIPT" "$args_json" 2>"$create_err_file")
create_rc=$?
if [ "$create_rc" -ne 0 ]; then
  echo "WARNING: follow-up Issue の起票に失敗しました (PR #${PR_NUMBER}, rc=${create_rc})。cleanup は続行します" >&2
  echo "  手動起票: review-results JSON の non_blocking_findings[] を元に follow-up ラベル付き Issue を作成してください" >&2
  [ -s "$create_err_file" ] && tr -d '\r' < "$create_err_file" | sed 's/^/  /' >&2
  emit_failed create_api
  exit 0
fi

new_n=$(printf '%s' "$result" | jq -r '.issue_number // empty')
new_url=$(printf '%s' "$result" | jq -r '.issue_url // empty')
project_reg=$(printf '%s' "$result" | jq -r '.project_registration // empty')

if [ -z "$new_n" ] || [ "$new_n" = "0" ]; then
  echo "WARNING: follow-up 起票 helper が issue_number を返しませんでした。cleanup は続行します" >&2
  printf '%s' "$result" | jq -r '.warnings[]?' 2>/dev/null | sed 's/^/  /' >&2
  emit_failed create_api
  exit 0
fi

printf '✅ follow-up Issue 作成: #%s %s\n' "$new_n" "$new_url" >&2
printf '%s' "$result" | jq -r '.warnings[]?' 2>/dev/null | while IFS= read -r w; do
  [ -n "$w" ] && echo "  ⚠️ $w" >&2
done
case "$project_reg" in
  partial|failed)
    echo "  ⚠️ Projects 登録: $project_reg (手動登録: gh project item-add ${PROJECT_NUMBER} --owner ${PROJECT_OWNER} --url ${new_url})" >&2
    ;;
  skipped)
    echo "  ⚠️ Projects 登録: skipped (Projects Todo に載っていません。手動で Project に追加してください: ${new_url})" >&2
    ;;
esac

if [ -n "$SOURCE_ISSUE" ]; then
  {
    printf '%s\n' "マージ時の残存非実測指摘の follow-up: #${new_n}"
    printf '%s\n' ""
    printf '%s\n' "${new_url}"
  } > "$comment_file"
  if ! gh issue comment "$SOURCE_ISSUE" -R "${OWNER}/${REPO}" --body-file "$comment_file" >/dev/null; then
    echo "WARNING: 元 Issue #${SOURCE_ISSUE} への follow-up 参照コメントに失敗しました。follow-up #${new_n} 自体は作成済みです" >&2
  fi
fi

echo "[CONTEXT] FOLLOW_UP_ISSUE=created; issue=${new_n}; pr=${PR_NUMBER}" >&2
echo "[cleanup-follow-up-issue] result=created; issue=${new_n}; pr=${PR_NUMBER}"
exit 0
