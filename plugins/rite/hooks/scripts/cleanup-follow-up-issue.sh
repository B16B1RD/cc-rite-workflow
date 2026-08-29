#!/bin/bash
# cleanup-follow-up-issue.sh — /rite:cleanup ステップ 6.0
#
# マージ済み PR の review-results JSON から残存非実測指摘 (non_blocking_findings[]) を読み、
# follow-up Issue を 1 件起票する。0 件なら起票しない。同一 PR 由来の既存 follow-up があれば
# 重複起票しない。cleanup 全体は止めない (引数不正のみ exit 1)。
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
#
# Exit codes:
#   0: 正常終了 (起票 / skip / 非ブロッキング失敗を含む)
#   1: 引数不正
#
# Emitted markers (stderr):
#   [CONTEXT] FOLLOW_UP_ISSUE=created; issue=<n>; pr=<n>
#   [CONTEXT] FOLLOW_UP_ISSUE=skipped; reason=no_findings|no_json|already_exists|jq_missing; pr=<n>
#   [CONTEXT] FOLLOW_UP_ISSUE=failed; reason=lookup_api|create_api|create_script_missing|json_undecidable; pr=<n>
#
# Emitted summary (stdout, 1 行):
#   [cleanup-follow-up-issue] result=<created|skipped|failed>; ...
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=lib/tempfile.sh
source "$SCRIPT_DIR/lib/tempfile.sh"

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

# 存在確認後の basename 辞書順最大を 1 本だけ判定する (timestamp 名は YYYYMMDDHHMMSS)。
# nonempty だけから最新を採ると、最終 cycle が 0 件でも古い指摘から起票する。
# glob 未展開の pattern 文字列は実在検査で弾く (archive-or-rm と同型)。
source_json=""
source_base=""
findings_json="[]"
matched=0
for f in "$results_dir/${PR_NUMBER}"-*.json*; do
  { [ -e "$f" ] || [ -L "$f" ]; } || continue
  matched=1
  base="${f##*/}"
  if [ -z "$source_base" ] || [ "$base" \> "$source_base" ]; then
    source_json="$f"
    source_base="$base"
  fi
done

if [ "$matched" -eq 0 ]; then
  echo "WARNING: PR #${PR_NUMBER} のレビュー結果 JSON が見つかりません。follow-up 起票を skip します (別環境での cleanup の可能性。cycle 中記録は関連 Issue コメントを参照)" >&2
  emit_skip no_json
  exit 0
fi

jq_err=$(jq -e '.non_blocking_findings | type == "array"' "$source_json" 2>&1 >/dev/null)
jq_rc=$?
case "$jq_rc" in
  0)
    if ! findings_json=$(jq -c '.non_blocking_findings' "$source_json"); then
      echo "WARNING: 最新レビュー結果 JSON から non_blocking_findings[] を抽出できません (PR #${PR_NUMBER}): $source_json" >&2
      emit_failed json_undecidable
      exit 0
    fi
    if ! printf '%s' "$findings_json" | jq -e 'length > 0' >/dev/null; then
      emit_skip no_findings
      exit 0
    fi
    ;;
  1)
    echo "WARNING: 最新レビュー結果 JSON の non_blocking_findings が配列ではありません (PR #${PR_NUMBER}): $source_json" >&2
    [ -n "$jq_err" ] && printf '%s\n' "$jq_err" | sed 's/^/  /' >&2
    emit_failed json_undecidable
    exit 0
    ;;
  *)
    echo "WARNING: 最新レビュー結果 JSON を判定できません (PR #${PR_NUMBER}): $source_json (jq rc=${jq_rc})" >&2
    [ -n "$jq_err" ] && printf '%s\n' "$jq_err" | sed 's/^/  /' >&2
    emit_failed json_undecidable
    exit 0
    ;;
esac

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

findings_md=$(printf '%s' "$findings_json" | jq -r --arg dash "—" --arg empty "" '
  .[] |
  "### \(.id // $dash) (\(.severity // $dash)) — \(.reviewer // $dash)\n\n" +
  "- 場所: `\(.file // $dash):\((.line | if . == null then $dash else tostring end))`\n" +
  "- 説明: \(.description // $empty)\n" +
  "- 提案: \(.suggestion // $empty)\n"
')
if [ -z "$findings_md" ]; then
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
