#!/bin/bash
# cleanup-follow-up-issue.sh — /rite:cleanup ステップ 6.0
#
# マージ済み PR の残存 non-blocking 指摘 (review-results JSON の non_blocking_findings[] と、guardrail が
# 除外した guardrail_audit_log[] の行) と、元 Issue の
# Decision Log (Section 9) で本 PR のレビューが先送りした欠陥 (行末が `<!-- rite:deferred-defect pr=<PR> -->`
# の行。pr-review 7.4.3 が付ける。旧い基準で書かれた行も区別せず候補にし、終端として扱わない) を候補にする。
# 起票するかどうかは採否ゲート (review-adoption-gate.sh --kind followup) の出口だけで決め、verdict=file の
# 判定記録ごとに follow-up Issue を 1 件起票する (1 根因 = 1 Issue)。cleanup 全体は止めない (引数不正のみ exit 1)。
# json_undecidable は先送り欠陥があっても failed のまま止める。
#
# 候補の集合は**同一 PR の全 JSON の `non_blocking_findings[]` と `guardrail_audit_log[]` の和集合**。各 JSON はその cycle の
# 観測にすぎず、最新 1 本は残存集合ではない (先行 cycle にのみ載る指摘を取りこぼす)。解消済みかどうかは
# 分類役が判定記録の present で判定する。処分済みの候補は判定し直さない: iterate の NB sweep と前回の
# follow-up が採否の出口で処分した指摘 (関連 Issue 記録コメントの却下台帳で判定=issued / REJECT /
# RESOLVED / LINK) は本 helper が台帳を読み、行の出典 JSON と照合して除外する。ただし REJECT / RESOLVED は
# 前提が変わっていないときだけ除外する (下記「処分の再利用」)。起票した指摘と再掲マーカーで結ばれる前後の
# cycle の指摘、出典と id だけが違う完全一致の指摘も同じ指摘として除外する。
#
# 処分の再利用 (--list-candidates の reuse / judge):
#   - 台帳の REJECT / RESOLVED 行は、前提の起点 (判定文末尾の `@<commit>`、無ければ行の出典 JSON — 出典の
#     無い行は最新 JSON — の commit_sha) から対象 commit までに指摘のファイルが変わっていなければ除外する。変わった・commit を git で解決できない行は除外せず候補に戻す (判定し直す)。
#     issued / LINK 行は追跡先があるので前提によらず除外する (追跡の冪等性)。出典 <pr>-deferred の行は
#     対象 commit で処分したものなので常に除外する
#   - 前回の実行の判定記録 (--adoption の既定の置き場) は、head が今回の対象 commit と同じで、ids がすべて
#     今回の候補にあり、採否ゲートが保留した候補 (hold ファイルの held_ids) を含まない記録を reuse に写す。
#     それ以外の候補の id を judge に並べる。分類役は judge の候補だけ記録を書く
#
# 転記元は直下と archive/ の JSON。cleanup の archive helper は本スクリプトの後に走る (D-04) が、
# pr-cycle-cleanup.sh の orphan 回収が cleanup より先に archive/ へ移した JSON もここで読む。
#
# 候補の id: 指摘は `<出典 JSON の basename>#<finding id>` (id の [A-Za-z0-9._-] 以外は `_`)、先送り行は
#   行の `D-NN` (無ければ `deferred-<出現順>`)。同じ id が複数あれば 2 件目から `~2`, `~3` を付ける。
# 対象 commit (head): 直下と archive/ の `<pr>-*.json` を basename の降順に見て、最初に読めた文字列の
#   commit_sha。無ければマージ済み PR の head (headRefOid) を <state-root> の git で解決できたときに使い、
#   ゲートへはその head を commit_sha に持つ review-result を渡す。どちらも決まらなければ head_unresolved で止める。
#
# Usage:
#   cleanup-follow-up-issue.sh --state-root <dir> --pr <n> --owner <owner> --repo <repo> \
#     --list-candidates <file> [--source-issue <n>]
#   cleanup-follow-up-issue.sh --state-root <dir> --pr <n> --owner <owner> --repo <repo> \
#     --base <ref> [--adoption <file>] [options]
#
# Options:
#   --state-root         state-path-resolve.sh の解決結果。必須。ゲートの --repo-root にも渡す
#   --pr                 PR 番号 (数値)。必須
#   --owner              repo owner (-R 用)。必須
#   --repo               repo name。必須
#   --list-candidates    候補を列挙してこのパスへ書き、起票せずに終える。書く JSON は
#                        {"candidates": [{"id", "kind": "finding"|"deferred", "source", "finding"|"text"}],
#                         "head", "review_result", "adoption", "ledger", "reuse", "judge"}。review_result は head が PR の head のとき空。
#                        reuse は再利用する前回の判定記録、judge は記録を書く候補の id (上記「処分の再利用」)。
#                        ledger は関連 Issue の台帳の issued / LINK / REJECT 行 ({id, loc, disposition, premise, source})。
#                        関連 Issue があれば指摘の有無にかかわらず読む。読めないときは空で、その旨は
#                        FOLLOW_UP_SWEEP_ISSUED=unavailable で出る (関連 Issue が無いときも空)。
#                        0 件で終えるときは candidates が空で reason を持つ。
#                        判定済み記録は書かない。同じ --source-issue の起票実行と同じ候補になる
#   --base               PR の base ref。ゲートの --base (origin=pr の差分位置の照合) に渡す。起票実行では必須
#   --adoption           判定記録 ({"adoption": {"head", "records"}})。省略時はゲートの既定
#                        (<state-root>/.rite/state/adoption-<pr>-followup.json)
#   --source-issue       元 Issue 番号。空 / 省略可。本文の Decision Log から先送り欠陥を読み、ゲートへ
#                        --issue と取得した本文を渡す (空なら読まない)。
#                        空なら却下台帳 (sweep 起票済み判定) を読まず、
#                        除外不能として FOLLOW_UP_SWEEP_ISSUED=unavailable (no_source_issue) を出す。
#                        台帳を読む記録コメントは review-nonblocking-record.sh --print-record-body が
#                        PR から解決する関連 Issue 上の 1 件 (書き込み経路が PATCH するもの)
#   --project-number     Projects 番号。projects-enabled=true のとき必須。
#                        非数値なら WARNING のうえ Projects を無効化して起票する
#   --project-owner      Projects owner。省略時は --owner
#   --projects-enabled   true|false。省略時 false
#   --create-script      create-issue-with-projects.sh のパス。テスト注入用。省略時は plugin 内の実体
#   --preview-body       起票せずに本文を書き出すパス。ゲートと既存 follow-up の確認までは通常と同じに行い、
#                        起票する根因ごとの本文を `---` 行で区切ってこのパスへ書いて終える（label 作成・起票・
#                        元 Issue へのコメントはしない）。0 件・既存あり・保留は通常と同じ結果で終える
#
# 機械同定 marker: 起票本文の先頭行 `<!-- [rite-follow-up-from-pr:<pr>:<根因 key>] -->`。根因 key は判定記録の
#   ids を整列して `,` で連結した値。follow-up ラベルの Issue を先頭行で照合し、根因 key の ids が今回の記録の
#   ids と 1 つでも重なる Issue があればその根因は起票済みとする (再実行で ids が増減しても二重に起票しない)。
#   旧形式の PR 単位の marker (`<!-- [rite-follow-up-from-pr:<pr>] -->`) を先頭行に持つ Issue がある PR は、
#   その PR の follow-up を起票済みとして扱い、根因ごとの起票をしない (already_exists)。
#
# Exit codes:
#   0: 正常終了 (起票 / skip / 保留 / 非ブロッキング失敗を含む)
#   1: 引数不正
#
# Emitted markers (stderr):
#   [CONTEXT] FOLLOW_UP_CANDIDATES=listed; count=<n>; deferred=<k>; judge=<j>; head=<sha>; file=<path>; pr=<n>
#     (--list-candidates のとき。0 件で終えたときは count=0 の後に reason=<下記 skipped / failed の reason>)
#   [CONTEXT] FOLLOW_UP_CANDIDATES=failed; reason=list_write; pr=<n>   (一覧を --list-candidates のパスへ書けない)
#   [CONTEXT] FOLLOW_UP_CANDIDATES=failed; reason=head_unresolved; pr=<n>   (対象 commit を決められない。一覧を書かない)
#   [CONTEXT] FOLLOW_UP_CANDIDATES=failed; reason=guardrail_row_invalid|guardrail_source_missing; pr=<n>   (判定できない guardrail 行がある。一覧を書かない)
#   [CONTEXT] FOLLOW_UP_CANDIDATES=failed; reason=hold_unreadable; pr=<n>   (採否ゲートの hold ファイルがあるのに読めず、
#     前回の判定記録を再利用する候補を決められない。一覧を書かない。起票実行ではゲートが同じ hold を読めず
#     FOLLOW_UP_ISSUE=held; reason=gate_failed_rc1; hold_file=none で止まる)
#   [CONTEXT] FOLLOW_UP_ISSUE=held; reason=<r>; hold_file=<path>; pr=<n>
#     採否の出口が出ていない候補がある (判定記録なし / ゲートの ERROR / 未処分の出口)。何も起票せず、
#     判定済み記録も書かない。declined でも skipped でもない。reason はゲートの reason (no_records /
#     context_unavailable / adoption_error / undecided)。ゲート自体が失敗したら reason=gate_failed_rc<n>、
#     ゲートの出力を読めなければ reason=gate_output_invalid で、どちらも hold_file=none
#   [CONTEXT] FOLLOW_UP_LEDGER=recorded; rows=<n>; pr=<n>   (record の出口の候補を関連 Issue の却下台帳へ書いた。
#     指摘は出典 JSON の basename、先送り欠陥は <pr>-deferred を出典にする。再実行はこの行で候補から除く。
#     LINK は追跡先 #N を判定文に持つ。--preview-body の実行は起票せずに終わる all_recorded / already_exists でだけ書く)
#   [CONTEXT] FOLLOW_UP_LEDGER=failed; pr=<n>   (台帳へ書けなかった。起票の判断は変えない)
#   [CONTEXT] FOLLOW_UP_ISSUE=created; issue=<起票した番号の CSV>; existing=<起票済みだった根因数>; recorded=<k>; pr=<n>
#   [CONTEXT] FOLLOW_UP_ISSUE=preview; count=<n>; deferred=<k>; issues=<m>; body=<path>; pr=<n>   (--preview-body のとき。
#     count は起票する根因に束ねた候補の件数、deferred はそのうち先送り欠陥の件数、issues は起票する Issue の数)
#   [CONTEXT] FOLLOW_UP_ISSUE=skipped; reason=no_findings|all_issued|no_json|already_processed|jq_missing; pr=<n>
#   [CONTEXT] FOLLOW_UP_ISSUE=skipped; reason=already_exists; issue=<n の CSV>; pr=<n>
#   [CONTEXT] FOLLOW_UP_ISSUE=skipped; reason=all_recorded; recorded=<k>; pr=<n>
#     no_findings  : parse できた JSON の和集合が 0 件 (先送り欠陥も 0 件)
#     all_issued   : sweep 起票済みの除外**後**に 0 件になった (残りが全件 sweep で Issue 化済み。先送り欠陥も 0 件)
#     no_json      : レビュー結果 JSON が無い (先送り欠陥も 0 件。判定済み記録も無いか、読めない・内容が一致しない)
#     already_processed : JSON が無く先送り欠陥も 0 件で、前回の本 helper が判定を終えた記録
#                    (.rite/state/follow-up-judged-<pr>.txt の内容が `pr=<pr>`) がある
#     already_exists : 起票する根因がすべて起票済み、または旧形式の PR 単位の follow-up がある
#     all_recorded : 出口がすべて record (REJECT / RESOLVED / LINK) で、起票するものが無い
#
# 判定済み記録: created / no_findings / all_issued / already_exists / all_recorded で終えるとき、
#   `.rite/state/follow-up-judged-<pr>.txt` に `pr=<pr>` の 1 行を書く。cleanup の後段が JSON を
#   片付けた後の再実行で、JSON 不在を no_json と区別するため。
#   --preview-body 指定時も上記の skip 系 (no_findings / all_issued / already_exists / all_recorded) では書く。
#   result=held・preview・failed・skipped の他の reason では書かない (held の再実行を already_processed にしない)。
#   書けなくても結果は変えず WARNING を出す。影響は再実行の報告が no_json に戻ることだけ。
#   [CONTEXT] FOLLOW_UP_DEFERRED=unavailable; reason=issue_body_api; pr=<n>
#     元 Issue の本文を取得できず先送り欠陥を読めなかった (ゲートが本文を読み直し、読めなければ保留する)
#   [CONTEXT] FOLLOW_UP_ISSUE=failed; reason=lookup_api|create_api|create_script_missing|json_undecidable|head_unresolved|guardrail_row_invalid|guardrail_source_missing|preview_write; pr=<n>
#     head_unresolved: commit_sha を持つレビュー結果 JSON が無く、PR の head も取得できないか <state-root> の git で解決できない
#     guardrail_row_invalid: guardrail_audit_log の行が reviewer か description を欠き、判定できない
#     guardrail_source_missing: 却下台帳の recorded / rejected 行 (guardrail 行を原文なしで転記した旧形式) のうち、
#       この PR のレビュー結果を出典に持ち、読んだ JSON に同じ位置の指摘が無い行の出典 JSON がレビュー結果
#       (直下と archive/) に無く、原文を判定できない (この PR の JSON が 1 本も無いときは問わない)
#   [CONTEXT] FOLLOW_UP_ISSUE=failed; reason=create_api; issue=<起票できた番号の CSV>; pr=<n>
#     根因の一部だけ起票できた。再実行すると起票済みの根因は増やさず残りだけを起票する
#   [CONTEXT] FOLLOW_UP_SWEEP_ISSUED=unavailable; reason=<r>; pr=<n>
#     sweep 起票済みの除外を適用できなかった。指摘があれば sweep 起票済みの指摘を除外せず候補に残す。reason が no_source_issue / comments_api / ledger_invalid の
#     ときは関連 Issue の却下台帳を読めておらず、一覧の ledger も空になる。apply_failed のときは台帳を
#     読めており、一覧の ledger は台帳の行を運ぶ。成功経路では出さない。
#       reason=no_source_issue : --source-issue が空
#       reason=comments_api    : 記録コメントを取得できない (review-nonblocking-record.sh --print-record-body の失敗。
#                                関連 Issue の解決・記録コメントの同定は同 helper の書き込み経路と同じ)
#       reason=ledger_invalid  : 取得した記録コメントから却下台帳を解析できない
#       reason=apply_failed    : 最新のレビュー結果 JSON を選べない / 照合できない、または除外適用の jq が失敗
#
# Emitted summary (stdout, 1 行):
#   [cleanup-follow-up-issue] result=<created|preview|skipped|failed|held>; ...
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=lib/tempfile.sh
source "$SCRIPT_DIR/lib/tempfile.sh"
# 診断スニペットの制御文字を潰す canonical helper (SoT: control-char-neutralize.sh header)
# shellcheck source=../control-char-neutralize.sh
source "$SCRIPT_DIR/../control-char-neutralize.sh"
# shellcheck source=lib/review-results-sources.sh
source "$SCRIPT_DIR/lib/review-results-sources.sh"

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
PREVIEW_BODY=""
LIST_OUT=""
BASE_REF=""
ADOPTION=""

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
    --preview-body)     _require_option_value "$1" "${2:-}"; PREVIEW_BODY="$2"; shift 2 ;;
    --list-candidates)  _require_option_value "$1" "${2:-}"; LIST_OUT="$2"; shift 2 ;;
    --base)             _require_option_value "$1" "${2:-}"; BASE_REF="$2"; shift 2 ;;
    --adoption)         _require_option_value "$1" "${2:-}"; ADOPTION="$2"; shift 2 ;;
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
if [ -z "$LIST_OUT" ] && [ -z "$BASE_REF" ]; then
  echo "ERROR: cleanup-follow-up-issue: --base is required unless --list-candidates is given" >&2
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

# --list-candidates では 0 件で終える経路も起票結果の marker を出さず、空の候補一覧と理由を書く
emit_list_empty() {
  # reason は本 helper の固定語彙なのでそのまま埋める (jq_missing でも書けるよう jq を使わない)
  if ! printf '{"candidates": [], "reason": "%s"}\n' "$1" > "$LIST_OUT"; then
    echo "WARNING: 候補一覧を ${LIST_OUT} に書けません (PR #${PR_NUMBER})" >&2
  fi
  echo "[CONTEXT] FOLLOW_UP_CANDIDATES=listed; count=0; reason=$1; file=${LIST_OUT}; pr=${PR_NUMBER}" >&2
}

emit_skip() {
  local reason="$1"
  if [ -n "$LIST_OUT" ]; then emit_list_empty "$reason"; return; fi
  echo "[CONTEXT] FOLLOW_UP_ISSUE=skipped; reason=${reason}; pr=${PR_NUMBER}" >&2
  echo "[cleanup-follow-up-issue] result=skipped; reason=${reason}; pr=${PR_NUMBER}"
}

emit_failed() {
  local reason="$1"
  if [ -n "$LIST_OUT" ]; then emit_list_empty "$reason"; return; fi
  echo "[CONTEXT] FOLLOW_UP_ISSUE=failed; reason=${reason}; pr=${PR_NUMBER}" >&2
  echo "[cleanup-follow-up-issue] result=failed; reason=${reason}; pr=${PR_NUMBER}"
}

JUDGED_RECORD="$STATE_ROOT/.rite/state/follow-up-judged-${PR_NUMBER}.txt"

record_judged() {
  local err
  [ -z "$LIST_OUT" ] || return 0
  if ! err=$({ mkdir -p "$STATE_ROOT/.rite/state" && printf 'pr=%s\n' "$PR_NUMBER" > "$JUDGED_RECORD"; } 2>&1); then
    echo "WARNING: follow-up の判定済み記録を書けません (PR #${PR_NUMBER}): $JUDGED_RECORD" >&2
    [ -n "$err" ] && printf '%s\n' "$err" | head -3 | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    echo "  影響: レビュー結果 JSON を片付けた後に cleanup を再実行すると no_json (未完了) と報告します" >&2
  fi
}

MARKER="${MARKER_PREFIX}${PR_NUMBER}]"
results_dir="$STATE_ROOT/.rite/review-results"

rite_tempfile_init || exit 1
rite_tempfile_new list_err "fu-list" || exit 1
rite_tempfile_new create_err_file "fu-create" || exit 1

if ! command -v jq >/dev/null 2>&1; then
  echo "WARNING: jq が見つからないため残存 non-blocking 指摘を判定できません。follow-up 起票を skip します (PR #${PR_NUMBER})" >&2
  echo "  対処: jq を導入してください" >&2
  emit_skip jq_missing
  exit 0
fi

# 元 Issue の Decision Log (Section 9) から、本 PR のレビューが先送りした欠陥を読む。pr-review 7.4.3 は
# 先送りする欠陥の行末に DEFERRED_TOKEN を付ける。Section 9 の境界は 7.4.3 の awk と同じ 3 種。
# 行末が本 PR のトークンと一致する行だけを採り (別 PR の cleanup が拾わない)、トークンを除いて転記する。
# 取得の rc≠0 だけを失敗とし、空本文・Section 9 なしは 0 件。取得した本文はゲートへ渡す
# (失敗したらゲートが読み直し、読めなければ保留する)。
DEFERRED_TOKEN="<!-- rite:deferred-defect pr=${PR_NUMBER} -->"
deferred_md=""
deferred_n=0
issue_body_file=""
if [ -n "$SOURCE_ISSUE" ]; then
  rite_tempfile_new deferred_err "fu-deferred" || exit 1
  if source_body=$(gh issue view "$SOURCE_ISSUE" -R "${OWNER}/${REPO}" --json body --jq .body 2>"$deferred_err"); then
    rite_tempfile_new issue_body_file "fu-issue-body" || exit 1
    printf '%s\n' "$source_body" > "$issue_body_file" || exit 1
    deferred_md=$(printf '%s\n' "$source_body" | tr -d '\r' | TOKEN="$DEFERRED_TOKEN" awk '
      /^## 9\. Decision Log/ { in_section = 1; next }
      in_section && (/^## / || /^---[[:space:]]*$/ || /^<\/details>/) { in_section = 0 }
      in_section {
        t = ENVIRON["TOKEN"]; line = $0
        sub(/[[:space:]]+$/, "", line)
        if (length(line) > length(t) && substr(line, length(line) - length(t) + 1) == t) {
          line = substr(line, 1, length(line) - length(t))
          sub(/[[:space:]]+$/, "", line)
          print line
        }
      }')
    deferred_n=$(printf '%s' "$deferred_md" | awk 'END { print NR }')
  else
    echo "WARNING: 元 Issue #${SOURCE_ISSUE} の本文を取得できないため、Decision Log で先送りした欠陥を転記しません (PR #${PR_NUMBER})" >&2
    [ -s "$deferred_err" ] && head -3 "$deferred_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    echo "[CONTEXT] FOLLOW_UP_DEFERRED=unavailable; reason=issue_body_api; pr=${PR_NUMBER}" >&2
  fi
fi

# 指摘側が 0 件でも先送り欠陥があれば候補の判定へ進む
skip_unless_deferred() {
  [ "$deferred_n" -gt 0 ] && return 0
  record_judged
  emit_skip "$1"
  exit 0
}

# 同一 PR の全 JSON の `non_blocking_findings[]` を和集合して転記対象にする。
# `non_blocking_findings[]` は**その cycle の観測**であり、最終 cycle の JSON は「その PR の
# 残存集合」ではない。最新 1 本だけを読むと、先行 cycle にのみ載る指摘が HEAD に残存していても
# follow-up に載らず機械経路から黙って消える。残存判定 (解消済みの除外) は cleanup ステップ
# 判定記録の present (分類役) が担い、本 helper は「全 cycle で記録された集合」を作る。
#
# **id では畳まない**。`id` は各 JSON 内で振り直される連番であり cycle を跨いだ identity を持たない
# (cycle 間の同一性判断は pr-review の semantic 判断が担い、本配列に機械的 identity キーは無い。
# sweep 起票済みの除外だけは、再掲マーカーと `_src`・id 以外の完全一致を手がかりに結ぶ。詳細は下の sweep 節)。同じ `F-07` が cycle ごとに
# 別の指摘を指すため、id を key に畳むと別々の指摘が黙って 1 件に潰れる — 本 helper が防ごうとしている
# 取りこぼしそのものになる。よってここでは全 cycle 分をそのまま連結し、出典別の除外を終えた後で
# `_src` 以外が完全一致する再報告だけをまとめる。同一 id でも内容が異なる指摘は独立して残る。
# 走査順は basename 昇順 (= cycle 昇順) に固定する。
# 読み元は直下と archive/ の両方。cleanup より先に pr-cycle-cleanup.sh の orphan 回収が走ると、
# マージ済み PR の JSON は archive/ へ移っている。列挙と同名の扱いは lib/review-results-sources.sh。
findings_json="[]"
matched=0
parsed=0
unparsed=0
rite_tempfile_new union_tmp "fu-union" || exit 1
printf '[]\n' > "$union_tmp"
# jq の原因行を捨てない。除外の理由 (どの key が壊れているか) は stderr にしか出ない。
rite_tempfile_new union_err "fu-union-err" || exit 1
# 列挙は basename 昇順で確定するため、このループがそのまま cycle 昇順の連結になる。
sources=$(rite_review_results_sources "$results_dir" "$PR_NUMBER" '.json*')
while IFS= read -r f; do
  [ -n "$f" ] || continue
  matched=$((matched + 1))
  : > "$union_err"
  # guardrail が除外した行 (guardrail_audit_log) も候補にする。除外理由は採否の出口ではない。
  # 本文を判定できない行 (reviewer・description が空) は
  # 黙って落とさず、対象 commit を決められないときと同じく一覧を書かずに失敗する。
  if bad_guardrails=$(jq -c '[(.guardrail_audit_log // [])[]
      | select(((.reviewer // "") | tostring) == "" or ((.description // "") | tostring) == "")]' "$f" 2>/dev/null) \
     && [ -n "$bad_guardrails" ] && [ "$bad_guardrails" != "[]" ]; then
    echo "ERROR: guardrail_audit_log に、判定に要る reviewer・description を欠く行があります。follow-up を判定しません (PR #${PR_NUMBER}): $f" >&2
    printf '%s' "$bad_guardrails" | jq -r '.[] | "  reviewer=\(.reviewer // "") file_line=\(.file_line // "")"' | neutralize_ctrl --keep-newline >&2
    if [ -n "$LIST_OUT" ]; then
      echo "[CONTEXT] FOLLOW_UP_CANDIDATES=failed; reason=guardrail_row_invalid; pr=${PR_NUMBER}" >&2
    else
      emit_failed guardrail_row_invalid
    fi
    exit 0
  fi
  # 各 finding に出典 JSON のパス (`_src`) を持たせる。候補の id (basename + id) と、
  # sweep 起票済みの除外 (台帳行の出典 basename との一致、出典の無い行は最新 JSON とのフルパス一致) の両方が使う。
  # 本文の生成は明示したフィールドだけを読むので転記には出ない。
  # guardrail 行の id と loc は nb-sweep-collect.sh の key と loc と同じ式にし (同じ reviewer・file_line の
  # n 行目 (n >= 2) は #n を付ける。loc は file_line そのもの)、sweep が台帳に書いた行と
  # [finding_id, file:line] で照合できるようにする。
  if ! part=$(jq -c --arg src "$f" '
      def guardrail($n):
        ((.file_line // "") | tostring) as $fl
        | ($fl | capture("^(?<file>.+):(?<line>[^:]+)$") // {file: $fl, line: null}) as $at
        | {id: ("guardrail:" + (.reviewer | tostring) + ":" + $fl + (if $n > 0 then "#\($n + 1)" else "" end)),
           reviewer: (.reviewer | tostring),
           severity: (.original_severity // "UNKNOWN"),
           loc: $fl,
           file: $at.file,
           line: $at.line,
           description: (.description | tostring),
           verification: {measured: false},
           filter_reason: (.filter_reason // "")};
      if (.non_blocking_findings | type) == "array"
      then (.non_blocking_findings | map(if type == "object" then . + {_src: $src} else . end))
        + ((.guardrail_audit_log // []) as $g
           | [range(0; $g | length) as $i
               | $g[$i] | guardrail([$g[0:$i][] | select(.reviewer == $g[$i].reviewer and .file_line == $g[$i].file_line)] | length)
                 + {_src: $src}])
      else error("non_blocking_findings is not an array") end' "$f" 2>"$union_err"); then
    # 部分的な parse 失敗で全滅させない。健全な側の和集合で続行し、全滅時だけ json_undecidable。
    echo "WARNING: レビュー結果 JSON を読めないため和集合から除外します (PR #${PR_NUMBER}): $f" >&2
    [ -s "$union_err" ] && head -3 "$union_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    unparsed=$((unparsed + 1))
    continue
  fi
  # 出典別の除外より前なので、ここでは id / 内容による畳み込みをしない。
  : > "$union_err"
  if ! merged=$(jq -c --argjson add "$part" '. + $add' "$union_tmp" 2>"$union_err"); then
    echo "WARNING: 和集合の統合に失敗したため当該 JSON を除外します (PR #${PR_NUMBER}): $f" >&2
    [ -s "$union_err" ] && head -3 "$union_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    unparsed=$((unparsed + 1))
    continue
  fi
  printf '%s\n' "$merged" > "$union_tmp"
  parsed=$((parsed + 1))
done <<< "$sources"

if [ "$matched" -eq 0 ]; then
  if [ "$deferred_n" -eq 0 ]; then
    # 前回の判定後に JSON が片付けられた PR は、判定済み記録で「最初から無い」と区別する。
    # 読めない・内容が一致しない記録は判定済みの証拠にしない。
    if [ -e "$JUDGED_RECORD" ] || [ -L "$JUDGED_RECORD" ]; then
      if judged_content=$(cat -- "$JUDGED_RECORD" 2>/dev/null) && [ "$judged_content" = "pr=${PR_NUMBER}" ]; then
        echo "INFO: PR #${PR_NUMBER} の follow-up は前回の cleanup で判定済みです (レビュー結果 JSON はその後に片付け済み)" >&2
        emit_skip already_processed
        exit 0
      fi
      echo "WARNING: 判定済み記録を読めないか内容が一致しないため、前回判定済みとは扱いません: $JUDGED_RECORD" >&2
    fi
    echo "WARNING: PR #${PR_NUMBER} のレビュー結果 JSON が見つかりません。follow-up 起票を skip します (別環境での cleanup の可能性。cycle 中記録は関連 Issue コメントを参照)" >&2
    emit_skip no_json
    exit 0
  fi
  echo "WARNING: PR #${PR_NUMBER} のレビュー結果 JSON が見つかりません。Decision Log で先送りした欠陥だけを転記します (別環境での cleanup の可能性。cycle 中記録は関連 Issue コメントを参照)" >&2
elif [ "$parsed" -eq 0 ]; then
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
  skip_unless_deferred no_findings
fi

# 対象 commit: basename の降順で最初に読める commit_sha。判定記録の head はこの値と一致しなければならない。
review_result=""
head_sha=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if h=$(jq -er '.commit_sha | select(type == "string" and . != "")' "$f" 2>/dev/null); then
    review_result="$f"; head_sha="$h"; break
  fi
done < <(rite_review_results_sources "$results_dir" "$PR_NUMBER" '.json' | awk '{ l[NR] = $0 } END { for (i = NR; i > 0; i--) print l[i] }')

# commit_sha を持つ JSON が無い (orphan 回収が指摘 0 件の JSON を消した後など) ときは、マージ済み PR の head を
# 対象 commit にする。採否判定 helper はこの commit を git で読むので、ブランチ削除後も <state-root> の git で
# 解決できることを確かめる。決まらない head で保留すると判定記録をどう書いても解けないので、失敗で止める。
if [ -z "$head_sha" ]; then
  rite_tempfile_new head_err "fu-head" || exit 1
  head_cause=""
  if ! pr_head=$(gh pr view "$PR_NUMBER" -R "${OWNER}/${REPO}" --json headRefOid --jq .headRefOid 2>"$head_err"); then
    head_cause="PR の head を取得できません"
  elif ! [[ "$pr_head" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]; then
    head_cause="PR の head が commit id の形ではありません ('$(printf '%s' "$pr_head" | neutralize_ctrl)')"
  elif ! git -C "$STATE_ROOT" cat-file -e "${pr_head}^{commit}" 2>"$head_err"; then
    head_cause="PR の head ${pr_head} を ${STATE_ROOT} の git で解決できません"
  fi
  if [ -n "$head_cause" ]; then
    echo "WARNING: commit_sha を持つレビュー結果 JSON が無く、${head_cause}。対象 commit を決められないため follow-up を判定しません (PR #${PR_NUMBER})" >&2
    [ -s "$head_err" ] && head -3 "$head_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    if [ -n "$LIST_OUT" ]; then
      echo "[CONTEXT] FOLLOW_UP_CANDIDATES=failed; reason=head_unresolved; pr=${PR_NUMBER}" >&2
    else
      emit_failed head_unresolved
    fi
    exit 0
  fi
  head_sha="$pr_head"
  echo "INFO: commit_sha を持つレビュー結果 JSON が無いため、PR #${PR_NUMBER} の head ${head_sha} を対象 commit にします" >&2
fi

# iterate の NB sweep が既に Issue 化した指摘 (関連 Issue 記録コメントの却下台帳で判定=issued) を
# 転記から除く。sweep の起票には follow-up ラベルも先頭行 marker も付かないため、下の既存判定では
# 見分けられず同じ指摘が二重に Issue 化される。sweep が採否ゲートの出口で処分した REJECT / RESOLVED / LINK 行も
# 同じ照合で除く (処分済みの候補を再判定に戻さない)。旧形式の recorded / rejected 行は終端ではないので転記する。
# 除外するのは、台帳の issued 行と [finding_id, file:line] の組が一致し、かつ出典も一致する finding だけ。
# issued 行の最終列 (出典) は sweep が読んだレビュー結果 JSON の basename で、finding の出典 JSON
# (`_src`、archive/ へ移っていても basename は同じ) の basename と比べる。sweep 後に別の cycle が
# 走って最新 JSON が変わっても、起票した cycle の finding を除外できる。basename は PR 番号で始まるため
# 同じ関連 Issue に並ぶ別 PR の台帳行とは一致しない。出典の無い (空・形の合わない) issued 行は、sweep が
# 読んだ最新 JSON (nb-sweep-collect.sh と同じ basename 最大の 1 本) 由来の finding とだけ照合する。
# 起票した指摘と同じ指摘だと言える finding も除外する。後の cycle は未解消の指摘を id を振り直し、
# description を書き直して再報告するため、組も本文も一致しない。そこで次の 2 種の結びつきを辿り、
# 起票した finding と繋がる finding をまとめて除外する:
#   - `_src` と id 以外が完全一致する (同じ指摘の写し。id は cycle ごとに振り直されるので比べない)
#   - description の括弧内に NOT_FIXED か 再掲 を含む再掲マーカーがあり、その F-NN が、直前の cycle の
#     JSON にある同じ id・同じ file:line の finding を指す。結びつきはマーカーを持つ側から直前の cycle へ
#     張るので、マーカーの無い初出も、後の cycle のマーカーが指せば除外される。reviewer は cycle ごとに
#     帰属が変わるため比べない。直前の cycle は `.json` の列挙順で決め (指摘 0 件・parse 不能の JSON も
#     1 cycle と数える)、2 つ前へは遡らない。PARTIAL / REGRESSION を含むマーカーは残りの問題を
#     書き直した新しい本文なので結ばない
# それ以外の出典が一致しない finding は id や位置が同じでも転記する。台帳は指摘の内容を持たず、
# マーカーの無い別 cycle の同じ位置の指摘が再報告か別の指摘かを判定できないため、除外すると
# sweep 未実施の指摘がどの Issue にも残らなくなる (欠落より重複を選ぶ)。台帳の行と直接一致して除外した
# 最新 JSON 由来の指摘と同じ file:line に残る先行 cycle の指摘だけを重複候補として WARNING に出す。
# マーカーの無い行ずれした再報告と、それ以外の除外 (最新 JSON 以外を出典とする除外、結びつきによる
# 除外) と同じ位置に残る指摘は、WARNING なしで sweep の Issue と重複しうる。
# 台帳や最新 JSON を読めないときは sweep 起票済みの除外を適用せずに転記し、WARNING と marker で surface する (sweep 起票済みを黙って全件除外にも全件転記にも倒さない)。
# 処分の前提: REJECT / RESOLVED 行は、前提の起点から対象 commit までに指摘のファイルが変わっていないときだけ
# 除外に使う。起点は判定文の末尾の `@<commit>` (follow-up が判定した commit。write_ledger が付ける)、無ければ
# 行の出典 JSON (出典の無い行は最新 JSON) の commit_sha。変わった・commit を解決できない行は外し (候補に戻して
# 判定し直す)、外した件数を出す。issued / LINK 行は追跡先があるので前提によらず残す。
# $1 は [id, loc, 出典, 判定, 判定 commit] の配列。対象 commit と sources / latest_json は呼び出し前に決まっている。
drop_stale_dispositions() {
  local keys="$1" stale='[]' k_id k_loc k_src k_at src sha
  # 出典と判定 commit はどちらも空になりうる。タブは IFS 空白で連続が 1 つに潰れるので、空欄を保つ \x1f で区切る
  while IFS=$'\x1f' read -r k_id k_loc k_src k_at; do
    src="$latest_json"
    [ -z "$k_src" ] || src=$(printf '%s\n' "$sources" | awk -v b="$k_src" '{ n = split($0, p, "/") } p[n] == b { print; exit }')
    sha="$k_at"
    [ -z "$sha" ] && [ -n "$src" ] && sha=$(jq -r '.commit_sha // empty' "$src" 2>/dev/null)
    if [ -n "$sha" ] && { [ "$sha" = "$head_sha" ] || git -C "$STATE_ROOT" diff --quiet --end-of-options "$sha" "$head_sha" -- "${k_loc%:*}" 2>/dev/null; }; then
      continue
    fi
    stale=$(jq -c --arg i "$k_id" --arg l "$k_loc" --arg s "$k_src" --arg a "$k_at" '. + [[$i, $l, $s, $a]]' <<< "$stale") || return 1
  done < <(jq -r '.[] | select(.[3] == "REJECT" or .[3] == "RESOLVED") | [.[0], .[1], .[2], .[4]] | join("\u001f")' <<< "$keys")
  if [ "$stale" != '[]' ]; then
    echo "[cleanup-follow-up-issue] disposition_stale: pr=${PR_NUMBER}; count=$(jq 'length' <<< "$stale")" >&2
  fi
  jq -c --argjson stale "$stale" '[.[] | select([.[0], .[1], .[2], .[4]] as $k | $stale | index([$k]) | not)]' <<< "$keys"
}
sweep_issued_unavailable() {
  echo "WARNING: $2。sweep 起票済みの指摘を除外せず転記します (PR #${PR_NUMBER})" >&2
  echo "[CONTEXT] FOLLOW_UP_SWEEP_ISSUED=unavailable; reason=$1; pr=${PR_NUMBER}" >&2
}
# 一覧の ledger (分類役が id・文面・位置の変わった候補を既存 Issue / REJECT へ紐づける材料) は、指摘の有無に
# かかわらず関連 Issue があれば読む。記録コメントは書き込み経路 (review-nonblocking-record.sh) が PATCH する
# 1 件だけを読み、関連 Issue の解決・記録コメントの同定・CRLF の正規化と診断は helper が行う。
# 台帳行の分解は nb-sweep-collect.sh と同じ式 (セル内のエスケープ済みパイプを区切りにしない)。
ledger_hint='[]'
ledger_unread=""
deferred_done='[]'
if [ -n "$SOURCE_ISSUE" ] && { [ -n "$LIST_OUT" ] || [ "$deferred_n" -gt 0 ] || printf '%s' "$findings_json" | jq -e 'length > 0' >/dev/null; }; then
  rite_tempfile_new comments_err "fu-comments" || exit 1
  if ! record_body=$(bash "$SCRIPT_DIR/../review-nonblocking-record.sh" --print-record-body \
      --pr "$PR_NUMBER" --owner-repo "${OWNER}/${REPO}"); then
    ledger_unread=comments_api
  elif ! ledger_hint=$(printf '%s' "$record_body" | jq -Rsce '
    def trim: gsub("^\\s+|\\s+$"; "");
    [ split("### 却下台帳\n")[1:][]
        | split("📎 non_blocking_count:")[0] | split("\n### ")[0]
        | split("\n")[] | select(startswith("|"))
        | gsub("\\\\\\|"; "\ue000") | split("|") | map(gsub("\ue000"; "\\|") | trim)
        | select(length >= 6)
        | {id: .[1], loc: .[2], disposition: .[3], premise: .[4], source: (if length >= 7 then .[5] else "" end)}
        | select(.disposition == "issued" or .disposition == "LINK" or .disposition == "REJECT" or .disposition == "RESOLVED") ]' 2>"$comments_err"); then
    ledger_hint='[]'
    ledger_unread=ledger_invalid
  fi
  # 旧形式の recorded / rejected 行は guardrail 行を原文なしで転記したものを含む。この PR のレビュー結果を
  # 出典に持ち、読んだ JSON に同じ [finding_id, file:line] の指摘 (guardrail 行は reviewer と file_line) が
  # 無い行の原文は出典 JSON にしかないので、出典がこの PR のレビュー結果 JSON (直下と archive/) に無ければ、
  # その行は判定できないまま消える (台帳は Issue 単位なので、別の PR の行はこの PR の候補ではない)。
  # JSON が 1 本も無いときは上の WARNING (別環境での cleanup) が全指摘について同じことを告げているので問わない
  if [ -z "$ledger_unread" ] && [ "$matched" -gt 0 ]; then
    if ! unmatched_rows=$(printf '%s' "$record_body" | jq -Rsre --argjson cur "$findings_json" --arg pfx "${PR_NUMBER}-" '
      def trim: gsub("^\\s+|\\s+$"; "");
      ([$cur[] | objects | [((.id // "") | tostring), (.loc // ((.file // "") + ":" + (.line | tostring)))]]
       + [$cur[] | objects | select(.reviewer != null) | [(.reviewer | tostring), .loc]]) as $here
      | [split("### 却下台帳\n")[1:][]
        | split("📎 non_blocking_count:")[0] | split("\n### ")[0]
        | split("\n")[] | select(startswith("|"))
        | gsub("\\\\\\|"; "\ue000") | split("|") | map(gsub("\ue000"; "\\|") | trim)
        | select(length >= 7 and (.[3] == "recorded" or .[3] == "rejected") and (.[5] | startswith($pfx)))
        | select([.[1], .[2]] as $k | $here | index([$k]) | not)
        | [.[1], .[2], .[5]] | @tsv] | join("\n")' 2>"$comments_err"); then
      # 台帳は上で解析できている。ここで失敗するのは想定外なので、読めない台帳と同じ扱いで WARNING を出す
      [ -s "$comments_err" ] && head -3 "$comments_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
      ledger_hint='[]'
      ledger_unread=ledger_invalid
      unmatched_rows=""
    fi
    source_bases=$(printf '%s\n' "$sources" | awk '{ n = split($0, p, "/"); print p[n] }')
    lost_rows=""
    while IFS=$'\t' read -r l_id l_loc l_src; do
      [ -n "$l_src" ] || continue
      grep -Fxq -- "$l_src" <<< "$source_bases" \
        || lost_rows="${lost_rows}  reviewer=${l_id} file_line=${l_loc} source=${l_src}"$'\n'
    done <<< "$unmatched_rows"
    if [ -n "$lost_rows" ]; then
      echo "ERROR: 却下台帳の recorded / rejected 行が指す出典 JSON が PR #${PR_NUMBER} のレビュー結果 (直下と archive/) にありません。この guardrail 行の原文を判定できないため follow-up を判定しません:" >&2
      printf '%s' "$lost_rows" | neutralize_ctrl --keep-newline >&2
      if [ -n "$LIST_OUT" ]; then
        echo "[CONTEXT] FOLLOW_UP_CANDIDATES=failed; reason=guardrail_source_missing; pr=${PR_NUMBER}" >&2
      else
        emit_failed guardrail_source_missing
      fi
      exit 0
    fi
  fi
  # 前回の follow-up が record の出口で処分した先送り欠陥 (出典 <pr>-deferred の行) は候補に戻さない
  deferred_done=$(jq -c --arg src "${PR_NUMBER}-deferred" '[.[] | select(.source == $src and .disposition != "issued") | .id]' <<< "$ledger_hint")
  ledger_hint=$(jq -c '[.[] | select(.disposition != "RESOLVED")]' <<< "$ledger_hint")
fi
if ! printf '%s' "$findings_json" | jq -e 'length > 0' >/dev/null; then
  # 先送り欠陥だけで起票する経路。台帳と照合する指摘は無いが、読めなかった ledger は分類役に空と区別させる
  if [ -n "$ledger_unread" ]; then
    echo "WARNING: 関連 Issue の却下台帳を読めないため、既存 Issue / REJECT への紐づけの材料 (ledger) がありません (PR #${PR_NUMBER})" >&2
    echo "[CONTEXT] FOLLOW_UP_SWEEP_ISSUED=unavailable; reason=${ledger_unread}; pr=${PR_NUMBER}" >&2
  fi
elif [ -z "$SOURCE_ISSUE" ]; then
  sweep_issued_unavailable no_source_issue "関連 Issue が無いため却下台帳を読めません"
else
  if [ "$ledger_unread" = comments_api ]; then
    sweep_issued_unavailable comments_api "関連 Issue の記録コメントを取得できませんでした"
  elif ! issued_keys=$(printf '%s' "$record_body" | jq -Rsce '
    def trim: gsub("^\\s+|\\s+$"; "");
    [ split("### 却下台帳\n")[1:][]
        | split("📎 non_blocking_count:")[0] | split("\n### ")[0]
        | split("\n")[] | select(startswith("|"))
        | split("|") | map(trim)
        | select(.[3] == "issued" or .[3] == "REJECT" or .[3] == "RESOLVED" or .[3] == "LINK")
        | [.[1], .[2],
           (.[-2] as $s
            | if length >= 7 and ($s | test("^[0-9]+-[0-9]{14}(~[0-9a-f]{4})?\\.json(\\.corrupt-[0-9]+)?$")) then $s else "" end),
           .[3],
           (if length >= 7 then (.[-3] | capture("@(?<c>[0-9a-f]{7,64})$").c // "") else "" end)] ]
    | unique' 2>"$comments_err"); then
    sweep_issued_unavailable ledger_invalid "関連 Issue の却下台帳を解析できません"
    [ -s "$comments_err" ] && head -3 "$comments_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  elif [ "$ledger_unread" = ledger_invalid ]; then
    sweep_issued_unavailable ledger_invalid "関連 Issue の却下台帳を解析できません"
    [ -s "$comments_err" ] && head -3 "$comments_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  elif ! cycle_sources=$(rite_review_results_sources "$results_dir" "$PR_NUMBER" '.json') \
    || ! latest_json=$(printf '%s\n' "$cycle_sources" | tail -1) \
    || [ -z "$latest_json" ] || [ ! -f "$latest_json" ] \
    || ! cycles_json=$(printf '%s\n' "$cycle_sources" | jq -Rsc 'split("\n") | map(select(length > 0) | split("/") | last)') \
    || ! jq -e 'if (.non_blocking_findings | type) != "array" then error("non_blocking_findings is not an array") else true end' \
      "$latest_json" >/dev/null 2>"$comments_err"; then
    sweep_issued_unavailable apply_failed "sweep 起票済みの指摘を最新のレビュー結果 JSON と照合できません"
    [ -s "$comments_err" ] && head -3 "$comments_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  elif ! issued_keys=$(drop_stale_dispositions "$issued_keys"); then
    sweep_issued_unavailable apply_failed "処分の前提を照合できません"
  elif ! issued_split=$(printf '%s' "$findings_json" | jq -c --arg latest "$latest_json" --argjson keys "$issued_keys" \
      --argjson cycles "$cycles_json" '
    def loc: .loc // ((.file // "") + ":" + (.line | tostring));
    def base: (._src // "") | split("/") | last;
    def issued: ._src as $s | base as $b | [(.id // ""), loc] as $k
      | any($keys[]; .[0:2] == $k and (if .[2] == "" then $s == $latest else .[2] == $b end));
    # 再掲マーカー: 括弧で囲んだ区間に NOT_FIXED か 再掲 があり、PARTIAL / REGRESSION が無いもの。
    # その区間の F-NN が直前の cycle で振られていた id
    def reported_ids: [(.description // "") | strings
      | scan("【[^】]*】|\\[[^\\]]*\\]|（[^）]*）|\\([^)]*\\)")
      | select(test("NOT_FIXED|再掲") and (test("PARTIAL|REGRESSION") | not))
      | scan("F-[0-9]{2,}")] | unique;
    [to_entries[] | .value + {_i: .key}] as $all
    | [ $all[] as $x
        | ( $all[] | select(._i > $x._i and del(._src, ._i, .id) == ($x | del(._src, ._i, .id))) | [$x._i, ._i] ),
          ( ($x | base) as $xb
            | select($cycles | index($xb))
            | ([$cycles[] | select(. < $xb)] | last) as $prev
            | select($prev != null)
            | ($x | reported_ids)[] as $rid
            | $all[]
            | select(base == $prev and .id == $rid and loc == ($x | loc))
            | [$x._i, ._i] ) ] as $edges
    | ([range(0; $all | length)]
       | until(. as $l | all($edges[]; $l[.[0]] == $l[.[1]]);
           reduce $edges[] as $e (.; ([.[$e[0]], .[$e[1]]] | min) as $m | .[$e[0]] = $m | .[$e[1]] = $m))) as $label
    | ([$all[] | select(issued) | $label[._i]] | unique) as $hit
    | ([$all[] | select(issued)] | length) as $direct
    | [$all[] | select($label[._i] as $c | $hit | index($c) | not)] as $kept
    | ([$all[] | select(issued and ._src == $latest) | loc] | unique) as $locs
    | [$kept[] | select(._src != $latest and (loc as $l | any($locs[]; . == $l))) | loc] as $dups
    | {kept: [$kept[] | del(._i)],
       excluded: (($all | length) - ($kept | length)),
       relinked: (($all | length) - ($kept | length) - $direct),
       duplicates: ($dups | length),
       duplicate_locations: ($dups | unique | join(", "))}') \
    || ! issued_filtered=$(printf '%s' "$issued_split" | jq -c '.kept') \
    || ! _issued_excluded=$(printf '%s' "$issued_split" | jq -r '.excluded') \
    || ! _issued_relinked=$(printf '%s' "$issued_split" | jq -r '.relinked') \
    || ! _issued_dups=$(printf '%s' "$issued_split" | jq -r '.duplicates') \
    || ! _issued_dup_locs=$(printf '%s' "$issued_split" | jq -r '.duplicate_locations'); then
    sweep_issued_unavailable apply_failed "sweep 起票済みの除外適用に失敗しました"
  else
    _issued_after=$(printf '%s' "$issued_filtered" | jq 'length')
    findings_json="$issued_filtered"
    echo "[cleanup-follow-up-issue] sweep_issued: pr=${PR_NUMBER}; excluded=${_issued_excluded}; possible_duplicates=${_issued_dups}" >&2
    if [ "$_issued_relinked" -gt 0 ]; then
      echo "[cleanup-follow-up-issue] sweep_issued_relinked: pr=${PR_NUMBER}; relinked=${_issued_relinked}" >&2
    fi
    if [ "$_issued_dups" -gt 0 ]; then
      # file:line はレビュアーが書く値なので制御文字を潰す (パスは ASCII 前提。WARNING 本文には通さない)
      _issued_dup_locs=$(printf '%s' "$_issued_dup_locs" | neutralize_ctrl)
      echo "WARNING: sweep 起票済みの指摘と同じ位置に先行 cycle の指摘が ${_issued_dups} 件あります (${_issued_dup_locs})。同じ指摘の再報告か別の指摘かを台帳から判定できないため、欠落させずに転記します。sweep の Issue と重複していないか確認してください (PR #${PR_NUMBER})" >&2
    fi
    if [ "$_issued_after" -eq 0 ]; then
      skip_unless_deferred all_issued
    fi
  fi
fi

# 出典別の除外を先に適用しないと、残すはずのコピーが除外対象だった場合に指摘を失う。
# 比較から `_src` だけを外し、最初に現れた要素と順序を維持する。
if dedupe_result=$(printf '%s' "$findings_json" | jq -r '
  length as $before
  | reduce .[] as $finding (
    {kept: [], seen: []};
    ($finding | del(._src)) as $key
    | if (.seen | index($key)) == null
      then .kept += [$finding] | .seen += [$key]
      else .
      end
  )
  | (($before - (.kept | length)) | tostring) + "\n" + (.kept | tojson)
'); then
  _dedupe_removed=${dedupe_result%%$'\n'*}
  deduplicated_json=${dedupe_result#*$'\n'}
  findings_json="$deduplicated_json"
  if [ "$_dedupe_removed" -gt 0 ]; then
    echo "[cleanup-follow-up-issue] deduplicated: pr=${PR_NUMBER}; removed=${_dedupe_removed}" >&2
  fi
else
  echo "WARNING: 完全一致する指摘の集約に失敗したため全件を転記します (PR #${PR_NUMBER})" >&2
fi

# 候補の一覧。--list-candidates と起票実行が同じ式で作るので、判定記録の ids はどちらでも同じ候補を指す。
# 指摘の id は出典 JSON の basename と finding id (マーカーに載せられない文字は `_`)、先送り行は行の D-NN。
# 同じ id が重なれば 2 件目から `~2` を付ける (`~` は元の id に残らないので付けた id と衝突しない)。
rite_tempfile_new cands_file "fu-cands" || exit 1
deferred_source=""
[ -n "$SOURCE_ISSUE" ] && deferred_source="Issue #${SOURCE_ISSUE} Decision Log (Section 9)"
if ! printf '%s' "$findings_json" | jq -c --arg dmd "$deferred_md" --arg dsrc "$deferred_source" --argjson ddone "$deferred_done" '
  def safe: tostring | gsub("[^A-Za-z0-9._-]"; "_");
  [ .[] | ((._src // "") | split("/") | last) as $b
      | {id: ($b + "#" + ((.id // "") | safe)), kind: "finding", source: $b, finding: del(._src)} ]
  + [ $dmd | split("\n") | map(select(length > 0)) | to_entries[]
      | {id: (([.value | match("(^|[^A-Za-z])(D-[0-9]+)") | .captures[1].string] | first) // "deferred-\(.key + 1)"),
         kind: "deferred", source: $dsrc, text: .value} ]
  | reduce .[] as $c ({out: [], seen: {}};
      (.seen[$c.id] // 0) as $n | .seen[$c.id] = $n + 1
      | .out += [if $n == 0 then $c else $c + {id: "\($c.id)~\($n + 1)"} end])
  | {candidates: [.out[] | select(.kind == "finding" or (.id as $i | $ddone | index($i) | not))]}' > "$cands_file"; then
  echo "WARNING: 候補の一覧を作れません (non_blocking_findings[] に object でない要素がある可能性)。follow-up を起票しません (PR #${PR_NUMBER})" >&2
  emit_failed json_undecidable
  exit 0
fi

adoption_path="${ADOPTION:-$STATE_ROOT/.rite/state/adoption-${PR_NUMBER}-followup.json}"
if [ -n "$LIST_OUT" ]; then
  # 前回の判定記録の再利用: head が同じで、ids がすべて今回の候補にあり、ゲートが保留した候補を含まない記録。
  # 保留した候補 (hold ファイルの held_ids) は未処分なので判定し直す。hold ファイルを読めなければ一覧を書かない。
  held_ids='[]'
  hold_file="$STATE_ROOT/.rite/state/adoption-hold-${PR_NUMBER}-followup.json"
  if [ -e "$hold_file" ] && ! held_ids=$(jq -ce 'if (.held_ids | type) == "array" then .held_ids else error("held_ids") end' "$hold_file" 2>/dev/null); then
    echo "WARNING: 採否ゲートの hold ファイルを読めないため、前回の判定記録を再利用できる候補を決められません (PR #${PR_NUMBER}): $hold_file" >&2
    echo "[CONTEXT] FOLLOW_UP_CANDIDATES=failed; reason=hold_unreadable; pr=${PR_NUMBER}" >&2
    exit 0
  fi
  reuse='[]'
  if [ -e "$adoption_path" ] && ! reuse=$(jq -c --arg head "$head_sha" --argjson held "$held_ids" --slurpfile c "$cands_file" '
      [$c[0].candidates[].id] as $ids
      | if .adoption.head == $head
        then [.adoption.records[] | select(all(.ids[]; . as $i | $ids | index($i)) and (any(.ids[]; . as $i | $held | index($i)) | not))]
        else [] end' "$adoption_path" 2>/dev/null); then
    echo "WARNING: 前回の判定記録を読めないため再利用しません。全候補を判定し直します (PR #${PR_NUMBER}): $adoption_path" >&2
    reuse='[]'
  fi
  if ! jq --arg head "$head_sha" --arg rr "$review_result" --arg adoption "$adoption_path" --argjson ledger "$ledger_hint" \
      --argjson reuse "$reuse" \
      '. + {head: $head, review_result: $rr, adoption: $adoption, ledger: $ledger, reuse: $reuse,
            judge: [.candidates[].id | select(. as $i | [$reuse[].ids[]] | index($i) | not)]}' "$cands_file" > "$LIST_OUT"; then
    echo "WARNING: 候補一覧を ${LIST_OUT} に書けません (PR #${PR_NUMBER})" >&2
    echo "[CONTEXT] FOLLOW_UP_CANDIDATES=failed; reason=list_write; pr=${PR_NUMBER}" >&2
    exit 0
  fi
  echo "[CONTEXT] FOLLOW_UP_CANDIDATES=listed; count=$(jq '.candidates | length' "$cands_file"); deferred=$(jq '[.candidates[] | select(.kind == "deferred")] | length' "$cands_file"); judge=$(jq '.judge | length' "$LIST_OUT"); head=${head_sha}; file=${LIST_OUT}; pr=${PR_NUMBER}" >&2
  exit 0
fi

# 採否ゲート: 書く直前に出口を読む。出口が出ていない候補が 1 件でもあれば何も書かずに保留する。
# 保留は declined でも skipped でもなく、判定済み記録も書かない (再実行で保留した判定から続ける)。
emit_held() {
  if [ "$2" = none ]; then
    case "$1" in
      gate_output_invalid) held_cause="採否ゲートの出力を読めません。hold ファイルが保存されたかを確認できません" ;;
      *) held_cause="採否ゲートが rc=${1#gate_failed_rc} で失敗しました (上に出たゲートの ERROR を参照)。hold ファイルは保存されていません" ;;
    esac
    echo "WARNING: ${held_cause}。follow-up を起票せず保留しました (PR #${PR_NUMBER})。ゲートの失敗の原因を解消してから /rite:cleanup ${PR_NUMBER} を再実行してください" >&2
  else
    echo "WARNING: 採否の出口が出ていない候補があるため follow-up を起票せず保留しました (PR #${PR_NUMBER})。hold ファイル (hold_file=$2) の resume (ゲートの WARNING にも出る) に従って再開してください" >&2
  fi
  echo "[CONTEXT] FOLLOW_UP_ISSUE=held; reason=$1; hold_file=$2; pr=${PR_NUMBER}" >&2
  echo "[cleanup-follow-up-issue] result=held; reason=$1; hold_file=$2; pr=${PR_NUMBER}"
  exit 0
}
if [ -z "$review_result" ]; then
  # 対象 commit が PR の head のときは、それを commit_sha に持つ review-result をゲートへ渡す
  rite_tempfile_new review_result "fu-pr-head" || exit 1
  jq -n --arg h "$head_sha" '{commit_sha: $h}' > "$review_result" || exit 1
fi
gate_args=(--pr "$PR_NUMBER" --kind followup --state-root "$STATE_ROOT" --candidates "$cands_file"
  --review-result "$review_result" --base "$BASE_REF" --owner-repo "${OWNER}/${REPO}" --repo-root "$STATE_ROOT"
  --adoption "$adoption_path")
if [ -n "$SOURCE_ISSUE" ]; then
  gate_args+=(--issue "$SOURCE_ISSUE")
  [ -n "$issue_body_file" ] && gate_args+=(--issue-body "$issue_body_file")
fi
gate_out=$(bash "$SCRIPT_DIR/review-adoption-gate.sh" "${gate_args[@]}")
gate_rc=$?
case "$gate_rc" in
  0) jq -e '.held == false and (.verdicts | type) == "array"' >/dev/null 2>&1 <<< "$gate_out" \
       || emit_held gate_output_invalid none ;;
  3) held_reason=$(jq -er '.reason' <<< "$gate_out" 2>/dev/null) && held_file=$(jq -er '.hold_file' <<< "$gate_out" 2>/dev/null) \
       || emit_held gate_output_invalid none
     emit_held "$held_reason" "$held_file" ;;
  *) emit_held "gate_failed_rc${gate_rc}" none ;;
esac

n_record=$(jq '[.verdicts[] | select(.verdict == "record")] | length' <<< "$gate_out")

# record の出口 (REJECT / RESOLVED / LINK) を関連 Issue の却下台帳へ書く。再実行ではこの行が候補を除くので、
# 同じ候補を判定し直さず保留もしない。REJECT / RESOLVED の判定文の末尾には判定した commit (`@<head>`) を付け、
# 再実行の前提の起点にする (出典 JSON の commit では、判定前の fix cycle の変更だけで自分の行が失効する)。
# 書き込みは sweep の台帳 persist と同じ経路 (extract → append → merge-into → 記録 helper)。先送り欠陥の行は
# 出典を <pr>-deferred とする。失敗しても起票は止めない
# (再実行は判定記録を再利用して同じ出口に至り、行を書き直す)。
# プレビュー付きの実行は、起票せずに終わる分岐 (all_recorded / already_exists) でだけ書く。プレビューを作る実行で
# 書くと、「起票する」の再実行で候補が減り、判定記録の ids が候補に無い (unknown_candidate) で保留する。
# 確認で「起票しない」を選んだ run は書かない (記録は残るので、次の cleanup が再利用して同じ出口に至る)。
write_ledger() {
  local entries body ledger rec_err rc outcome count
  rite_tempfile_new entries "fu-ledger-entries" || return 1
  jq -r --argjson cands "$(jq -c '.candidates' "$cands_file")" --arg pr "$PR_NUMBER" --arg head "$head_sha" '
    def cell: tostring | gsub("\r?\n"; " ") | gsub("\\|"; "\\|");
    .verdicts[] | select(.verdict == "record") as $v
    | ($v.record.reason // "") as $reason
    | ((if $v.exit == "LINK" then "追跡先 #\($v.tracker)" + (if $reason != "" then " / " + $reason else "" end)
        elif $v.exit == "RESOLVED" and $reason == "" then ($v.record.evidence // "")
        else $reason end)
       + (if $v.exit == "REJECT" or $v.exit == "RESOLVED" then " @\($head)" else "" end)) as $premise
    | $v.ids[] as $i | $cands[] | select(.id == $i)
    | if .kind == "finding"
      then "| \(.finding.id // $i | cell) | \(.finding.loc // ((.finding.file // "" | tostring) + ":" + (.finding.line | tostring)) | cell) | \($v.exit) | \($premise | cell) | \(.source) |"
      else "| \(.id | cell) | - | \($v.exit) | \($premise | cell) | \($pr)-deferred |" end' <<< "$gate_out" > "$entries" || return 1
  [ -s "$entries" ] || return 0
  # 本文は上で台帳を読んだときの記録コメント (同じ run の中なので読み直さない)
  if [ -z "$SOURCE_ISSUE" ] || [ "$ledger_unread" = comments_api ]; then
    echo "WARNING: 記録コメントを読めていないため却下台帳へ書けません" >&2
    return 1
  fi
  rite_tempfile_new body "fu-ledger-body" || return 1
  rite_tempfile_new ledger "fu-ledger" || return 1
  rite_tempfile_new rec_err "fu-ledger-err" || return 1
  printf '%s' "$record_body" > "$body" || return 1
  if [ ! -s "$body" ]; then
    printf '%s\n\n%s\n\n%s\n%s\n\n%s\n' \
      '## 📜 rite 非実測指摘の記録 (non-blocking)' \
      '本 cycle の非実測指摘: 0 件 (前 cycle の記録内容は本 cycle では再報告されていません)' \
      '📎 non_blocking_count: 0' \
      '📎 reviewed_commit: unknown' \
      '<!-- rite:nbr:v1 -->' > "$body"
  fi
  bash "$SCRIPT_DIR/nb-sweep-ledger.sh" extract --body-file "$body" > "$ledger" \
    && bash "$SCRIPT_DIR/nb-sweep-ledger.sh" append --ledger-file "$ledger" --entries-file "$entries" \
    && bash "$SCRIPT_DIR/nb-sweep-ledger.sh" merge-into --body-file "$body" --ledger-file "$ledger" || return 1
  count=$(grep -E '^📎 non_blocking_count:[[:space:]]*[0-9]+[[:space:]]*$' "$body" | tail -1 | grep -oE '[0-9]+')
  [ -n "$count" ] || return 1
  bash "$SCRIPT_DIR/../review-nonblocking-record.sh" --pr "$PR_NUMBER" --owner-repo "${OWNER}/${REPO}" \
    --count "$count" --iteration-id "follow-up-${PR_NUMBER}" --content-file "$body" 2>"$rec_err"
  rc=$?
  outcome=$(sed -n 's/^\[CONTEXT\] NONBLOCKING_RECORD_DONE=1; .*outcome=\([^;]*\);.*/\1/p' "$rec_err" | tail -1)
  case "$rc:$outcome" in
    0:created|0:updated) ledger_rows=$(grep -c '^| ' "$entries") ;;
    *) neutralize_ctrl --keep-newline < "$rec_err" | sed 's/^/  /' >&2; return 1 ;;
  esac
}
record_ledger() {
  [ "$n_record" -gt 0 ] || return 0
  ledger_rows=0
  if write_ledger; then
    echo "[CONTEXT] FOLLOW_UP_LEDGER=recorded; rows=${ledger_rows}; pr=${PR_NUMBER}" >&2
  else
    echo "WARNING: record の出口を却下台帳へ書けませんでした (PR #${PR_NUMBER})。起票は続けます。/rite:cleanup ${PR_NUMBER} を再実行すると判定記録を再利用して書き直します" >&2
    echo "[CONTEXT] FOLLOW_UP_LEDGER=failed; pr=${PR_NUMBER}" >&2
  fi
}
[ -n "$PREVIEW_BODY" ] || record_ledger

file_json=$(jq -c --arg p "${MARKER_PREFIX}${PR_NUMBER}:" '
  [.verdicts[] | select(.verdict == "file") | . + {key: (.ids | sort | join(","))} | . + {marker: ($p + .key + "]")}]' <<< "$gate_out")
if [ "$(jq 'length' <<< "$file_json")" -eq 0 ]; then
  [ -z "$PREVIEW_BODY" ] || record_ledger
  record_judged
  echo "INFO: 採否の出口がすべて record (REJECT / RESOLVED / LINK) のため follow-up を起票しません (PR #${PR_NUMBER}, ${n_record} 件)" >&2
  echo "[CONTEXT] FOLLOW_UP_ISSUE=skipped; reason=all_recorded; recorded=${n_record}; pr=${PR_NUMBER}" >&2
  echo "[cleanup-follow-up-issue] result=skipped; reason=all_recorded; recorded=${n_record}; pr=${PR_NUMBER}"
  exit 0
fi

# 同定不能は重複起票より起票失敗に倒す (D-03)。Search API は hyphen をトークン分割するため使わない。
# follow-up ラベルの Issue を REST の全ページで取得し、先頭行の HTML コメント marker で根因ごとに
# 確定する。件数の上限を置くと、上限を超えた後の既存を確定できず起票が止まり続けるため全件を読む。
# この endpoint は PR も返すため除外し、Issue だけを照合する。ページ配列 ([[...], ...]) でない応答は
# 空応答や複数ドキュメントも含めて 0 件と区別できないので解析失敗に倒す (-s で集めた応答が 1 つであることを要求する)。finding 本文の同一文字列は identity ではない。
list_json=$(gh api --paginate --slurp \
  "repos/${OWNER}/${REPO}/issues?labels=follow-up&state=all&per_page=100" 2>"$list_err")
list_rc=$?
if [ "$list_rc" -ne 0 ]; then
  echo "WARNING: 既存 follow-up の検索に失敗したため起票しません (重複起票を避ける)。手動確認: gh api --paginate \"repos/${OWNER}/${REPO}/issues?labels=follow-up&state=all&per_page=100\" --jq '.[].body' | grep -F '<!-- ${MARKER_PREFIX}${PR_NUMBER}'" >&2
  [ -s "$list_err" ] && tr -d '\r' < "$list_err" | sed 's/^/  /' >&2
  emit_failed lookup_api
  exit 0
fi

existing_json=$(printf '%s' "$list_json" | jq -cs '
  if length == 1 and (.[0] | type == "array" and length > 0 and all(.[]; type == "array")) then .[0]
  else error("non-page response") end
  | [.[][] | select(.pull_request == null) | {number, first: ((.body // "") | split("\n")[0])}]') || {
  echo "WARNING: 既存 follow-up の検索結果を解析できません。起票しません (PR #${PR_NUMBER})" >&2
  emit_failed lookup_api
  exit 0
}

# 旧形式 (PR 単位) の follow-up がある PR は、その PR の候補を起票済みとして扱い根因ごとに起票し直さない
legacy_n=$(jq -r --arg m "<!-- ${MARKER} -->" '[.[] | select(.first == $m) | .number] | first // empty' <<< "$existing_json")
if [ -n "$legacy_n" ]; then
  [ -z "$PREVIEW_BODY" ] || record_ledger
  record_judged
  echo "INFO: PR #${PR_NUMBER} には旧形式 (PR 単位) の follow-up #${legacy_n} があるため、根因ごとの起票をしません" >&2
  echo "[CONTEXT] FOLLOW_UP_ISSUE=skipped; reason=already_exists; issue=${legacy_n}; pr=${PR_NUMBER}" >&2
  echo "[cleanup-follow-up-issue] result=skipped; reason=already_exists; issue=${legacy_n}; pr=${PR_NUMBER}"
  exit 0
fi

# 起票済みの根因は、先頭行 marker の根因 key の ids が今回の記録の ids と 1 つでも重なるもの。1 つの候補は
# 1 つの記録にしか入らない (ゲートが RECONCILE にする) ので、重なる記録は同じ根因である。再実行で記録の ids が
# 減った (解消済みになった候補を除いた) ときも、同じ根因を別の key で二重に起票しない。
roots_json=$(jq -c --argjson ex "$existing_json" --arg p "<!-- ${MARKER_PREFIX}${PR_NUMBER}:" '
  [$ex[] | select((.first | startswith($p)) and (.first | endswith("] -->")))
     | {number, ids: (.first | ltrimstr($p) | rtrimstr("] -->") | split(","))}] as $filed
  | map(. as $r | . + {existing: ([$filed[] | select(any(.ids[]; . as $i | $r.ids | index($i))) | .number] | first)})' <<< "$file_json")
existing_csv=$(jq -r '[.[] | select(.existing != null) | .existing | tostring] | join(",")' <<< "$roots_json")
n_existing=$(jq '[.[] | select(.existing != null)] | length' <<< "$roots_json")
to_create=$(jq -c '[.[] | select(.existing == null)]' <<< "$roots_json")
if [ "$(jq 'length' <<< "$to_create")" -eq 0 ]; then
  [ -z "$PREVIEW_BODY" ] || record_ledger
  record_judged
  echo "[CONTEXT] FOLLOW_UP_ISSUE=skipped; reason=already_exists; issue=${existing_csv}; pr=${PR_NUMBER}" >&2
  echo "[cleanup-follow-up-issue] result=skipped; reason=already_exists; issue=${existing_csv}; pr=${PR_NUMBER}"
  exit 0
fi

if [ ! -x "$CREATE_SCRIPT" ] && [ ! -f "$CREATE_SCRIPT" ]; then
  echo "WARNING: create-issue-with-projects.sh が見つかりません (${CREATE_SCRIPT})。follow-up 起票を skip します" >&2
  emit_failed create_script_missing
  exit 0
fi

source_issue_line=""
[ -n "$SOURCE_ISSUE" ] && source_issue_line="- 元 Issue: #${SOURCE_ISSUE}"

# body Meta と Projects 引数で同一値を使う（二重定義しない）
_fu_type="fix"
_fu_complexity="S"
_fu_priority="Medium"

# 根因 1 件の本文。契約の引用・根拠・受入条件は判定記録から、束ねた候補は候補一覧から取る。
# 調査 (action=investigate) は命題・到達条件とその出所・完了条件も載せる。
# shellcheck disable=SC2016  # jq のプログラム中の `$` と backtick はシェル展開しない
_fu_body_jq='
  def dash: if . == null or . == "" then "—" else tostring end;
  def quote: tostring | split("\n") | map("> " + .) | join("\n");
  . as $v | $v.record as $r | ($v.action == "investigate") as $inv
  | [$cands[] | select(.id as $i | $v.ids | index($i))] as $mine
  | ($mine | map(select(.kind == "finding"))) as $f
  | ($mine | map(select(.kind == "deferred"))) as $d
  | [ "<!-- \($v.marker) -->", "**Type**: \($type)", "**Complexity**: \($complexity)", "",
      "## 概要", "",
      (if $inv then "PR #\($pr) のレビュー候補のうち、採否判定で調査として引き受けた疑義を切り出す。"
       else "PR #\($pr) のレビュー候補のうち、採否判定で起票と決まった既存の欠陥を follow-up として切り出す。" end),
      "", "## 契約", "",
      (if ($r.contract | type) == "object"
       then "- 引用元: `\($r.contract.ref)`" + (if ($r.contract.text // "") != "" then "\n\n" + ($r.contract.text | quote) else "" end)
       else "- 引用なし（契約が未確定の疑義）" end),
      "", "## 根拠", "",
      (if ($r.evidence // "") != "" then $r.evidence else "未確定: \($r.reason | dash)" end),
      "", "## 受入条件", "", "- [ ] \($r.acceptance)" ]
    + (if $inv then
        [ "", "## 調査", "",
          "- 命題: \($r.proposition.claim | dash)",
          "- 到達条件: \($r.proposition.reach | dash)（出所: \($r.proposition.reach_source | dash)）",
          "- 完了条件: \($r.proposition.done | dash)" ]
       else [] end)
    + [ "", "## 出典", "", "- 元 PR: #\($pr)" ] + (if $issue_line != "" then [$issue_line] else [] end)
    + [ "- 対象 commit: `\($head)`", "- 採否: \($v.exit) / \($v.action)（origin=\($v.origin)）",
        "- 候補: " + ($v.ids | map("`" + . + "`") | join(", ")), "- 機械同定: `\($v.marker)`" ]
    + (if ($f | length) > 0 then
        [ "", "## 残存 non-blocking 指摘", "" ]
        + [ $f[] | .finding
            | "### \(.id | dash) (\(.severity | dash)) — \(.reviewer | dash)\n\n"
              + "- 場所: `\(.file | dash):\(.line | dash)`\n"
              + "- 説明: \(.description // "")\n"
              + "- 提案: \(.suggestion // "")\n" ]
       else [] end)
    + (if ($d | length) > 0 then
        [ "", "## Decision Log で先送りした欠陥", "",
          "元 Issue の Decision Log（Section 9）に、本 PR のレビューが先送りした欠陥として記録された行:", "" ]
        + [ $d[] | .text ]
       else [] end)
  | join("\n")'
# タイトルは根因の先頭候補の説明 (先頭行の 40 文字)
_fu_title_jq='
  . as $v | [$cands[] | select(.id as $i | $v.ids | index($i))][0] as $c
  | (if $c.kind == "finding" then ($c.finding.description // "") else ($c.text // "") end)
    | tostring | split("\n")[0] | .[0:40] as $s
  | "follow-up: PR #\($pr) の" + (if $v.action == "investigate" then "調査" else "残存指摘" end)
    + (if $s != "" then "（\($s)）" else "" end)'
cands_list=$(jq -c '.candidates' "$cands_file")

if [ -z "$PREVIEW_BODY" ]; then
  gh label create follow-up -R "${OWNER}/${REPO}" \
    --description "マージ時の残存指摘と先送りした欠陥" --color "c5def5" >/dev/null 2>&1 || true
else
  rite_tempfile_new preview_tmp "fu-preview" || exit 1
fi

created=()
created_urls=()
n_failed=0
while IFS= read -r root; do
  [ -n "$root" ] || continue
  rite_tempfile_new body_file "fu-body" || exit 1
  if ! jq -r --argjson cands "$cands_list" --arg pr "$PR_NUMBER" --arg issue_line "$source_issue_line" \
      --arg head "$head_sha" --arg type "$_fu_type" --arg complexity "$_fu_complexity" "$_fu_body_jq" \
      <<< "$root" > "$body_file" || [ ! -s "$body_file" ]; then
    echo "WARNING: follow-up Issue body の生成に失敗しました ($(jq -r '.key' <<< "$root"))。この根因は起票しません" >&2
    n_failed=$((n_failed + 1))
    continue
  fi
  if [ -n "$PREVIEW_BODY" ]; then
    { [ -s "$preview_tmp" ] && printf '\n---\n\n'; cat "$body_file"; } >> "$preview_tmp"
    continue
  fi
  if ! title=$(jq -r --argjson cands "$cands_list" --arg pr "$PR_NUMBER" "$_fu_title_jq" <<< "$root"); then
    echo "WARNING: follow-up Issue のタイトルを作れません ($(jq -r '.key' <<< "$root"))。この根因は起票しません" >&2
    n_failed=$((n_failed + 1))
    continue
  fi
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
        status: "todo",
        priority: $priority,
        complexity: $complexity,
        iteration: { mode: $iter_mode }
      },
      options: { source: "cleanup", non_blocking_projects: true }
    }') || {
    echo "WARNING: follow-up args_json の jq 構築に失敗しました。この根因は起票しません" >&2
    n_failed=$((n_failed + 1))
    continue
  }
  result=$(bash "$CREATE_SCRIPT" "$args_json" 2>"$create_err_file")
  create_rc=$?
  if [ "$create_rc" -ne 0 ]; then
    echo "WARNING: follow-up Issue の起票に失敗しました (PR #${PR_NUMBER}, rc=${create_rc})。cleanup は続行します" >&2
    echo "  再実行: 起票済みの根因は増やさず、残りだけを起票します (/rite:cleanup ${PR_NUMBER})" >&2
    [ -s "$create_err_file" ] && tr -d '\r' < "$create_err_file" | sed 's/^/  /' >&2
    n_failed=$((n_failed + 1))
    continue
  fi
  new_n=$(printf '%s' "$result" | jq -r '.issue_number // empty')
  new_url=$(printf '%s' "$result" | jq -r '.issue_url // empty')
  project_reg=$(printf '%s' "$result" | jq -r '.project_registration // empty')
  if [ -z "$new_n" ] || [ "$new_n" = "0" ]; then
    echo "WARNING: follow-up 起票 helper が issue_number を返しませんでした。cleanup は続行します" >&2
    printf '%s' "$result" | jq -r '.warnings[]?' 2>/dev/null | sed 's/^/  /' >&2
    n_failed=$((n_failed + 1))
    continue
  fi
  created+=("$new_n")
  created_urls+=("$new_url")
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
done < <(jq -c '.[]' <<< "$to_create")

if [ -n "$PREVIEW_BODY" ]; then
  if [ "$n_failed" -gt 0 ]; then
    emit_failed create_api
    exit 0
  fi
  if ! cp "$preview_tmp" "$PREVIEW_BODY"; then
    echo "WARNING: follow-up 本文を ${PREVIEW_BODY} に書き出せませんでした。起票前の確認ができないため起票しません" >&2
    emit_failed preview_write
    exit 0
  fi
  # count は起票する根因に束ねた候補の件数。deferred はそのうちの先送り欠陥の件数
  preview_n=$(jq '[.[].ids[]] | length' <<< "$to_create")
  preview_deferred=$(jq --argjson cands "$cands_list" '[.[].ids[] as $i | $cands[] | select(.id == $i and .kind == "deferred")] | length' <<< "$to_create")
  preview_issues=$(jq 'length' <<< "$to_create")
  echo "[CONTEXT] FOLLOW_UP_ISSUE=preview; count=${preview_n}; deferred=${preview_deferred}; issues=${preview_issues}; body=${PREVIEW_BODY}; pr=${PR_NUMBER}" >&2
  echo "[cleanup-follow-up-issue] result=preview; count=${preview_n}; issues=${preview_issues}; pr=${PR_NUMBER}"
  exit 0
fi

created_csv=$(IFS=,; printf '%s' "${created[*]}")
if [ "${#created[@]}" -gt 0 ] && [ -n "$SOURCE_ISSUE" ]; then
  rite_tempfile_new comment_file "fu-comment" || exit 1
  {
    printf '%s\n' "PR #${PR_NUMBER} の follow-up（採否判定で起票と決まった根因ごと）:"
    printf '%s\n' ""
    for i in "${!created[@]}"; do
      printf '%s\n' "- #${created[$i]} ${created_urls[$i]}"
    done
  } > "$comment_file"
  if ! gh issue comment "$SOURCE_ISSUE" -R "${OWNER}/${REPO}" --body-file "$comment_file" >/dev/null; then
    echo "WARNING: 元 Issue #${SOURCE_ISSUE} への follow-up 参照コメントに失敗しました。follow-up #${created_csv} 自体は作成済みです" >&2
  fi
fi

if [ "$n_failed" -gt 0 ]; then
  echo "[CONTEXT] FOLLOW_UP_ISSUE=failed; reason=create_api${created_csv:+; issue=${created_csv}}; pr=${PR_NUMBER}" >&2
  echo "[cleanup-follow-up-issue] result=failed; reason=create_api${created_csv:+; issue=${created_csv}}; pr=${PR_NUMBER}"
  exit 0
fi

record_judged
echo "[CONTEXT] FOLLOW_UP_ISSUE=created; issue=${created_csv}; existing=${n_existing}; recorded=${n_record}; pr=${PR_NUMBER}" >&2
echo "[cleanup-follow-up-issue] result=created; issue=${created_csv}; existing=${n_existing}; recorded=${n_record}; pr=${PR_NUMBER}"
exit 0
