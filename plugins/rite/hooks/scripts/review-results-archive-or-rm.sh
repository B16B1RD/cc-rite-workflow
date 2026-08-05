#!/bin/bash
# review-results-archive-or-rm.sh — /rite:cleanup ステップ 6 の review-results 処理
#
# マージ済み PR のレビュー結果 JSON を、**非実測指摘 (non_blocking_findings[]) を持つものだけ
# 退避し、それ以外を削除する**。
#
# なぜ一律削除ではないか (Issue #2039):
#   ステップ 6.1.d の PR 記録コメントは reviewer / severity / file:line のポインタしか載せない。
#   したがって `description` / `suggestion` の全文を持つのは本 JSON だけで、無条件削除すると
#   非実測 CRITICAL の詳細が merge 直後にどこにも残らなくなり、Issue #2024 D-01
#   「マージ後に人間が拾い直せる」が偽になる (ポインタ化する前より後退する)。
#
# 判定不能はすべて退避側 (安全側) へ倒す:
#   jq 不在 / parse 失敗 / query error / 空ファイル のいずれも「中身を判定できない」状態であり、
#   消してしまうと消えたことにも気付けない。jq の rc は捨てず値域で分岐する
#   (`if jq -e ...; then` 形は rc=0 以外を全部「非空でない」へ丸め、top-level が object でない
#   JSON = query rc=5 を無警告で削除側へ落とす)。
#
# Usage:
#   review-results-archive-or-rm.sh --state-root <dir> --pr <number> [--label <label>]
#
# Options:
#   --state-root  state root (state-path-resolve.sh の解決結果)。必須
#   --pr          PR 番号 (数値)。必須。glob `{pr}-*.json` の prefix になる
#   --label       WARNING / marker に使うラベル (既定: review_results)
#
# 対象 glob: <state-root>/.rite/review-results/<pr>-*.json
# 退避先:    <state-root>/.rite/review-results/archive/
#
# Exit codes:
#   0: 正常終了 (処理対象 0 件を含む)。個々のファイルの失敗は非ブロッキングで WARNING + marker
#   1: 引数不正 (caller 契約違反)
#
# Emitted markers (stderr):
#   [CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1; reason=<r>; pr=<n>
#     reason ∈ { <label>_rm_failure
#              , <label>_archive_mkdir_failure    退避先ディレクトリを作れない
#              , <label>_archive_mv_failure       mv 自体が失敗
#              , <label>_archive_name_collision   退避先に同名既存 (上書きせず元の場所に残す)
#              }
#   いずれの失敗でも **ファイルは削除しない** (退避できないなら元の場所に残す)。
#
# Emitted summary (stdout, 1 行):
#   [review-results-archive-or-rm] archived=<n>; removed=<n>; failed=<n>; pr=<n>
set -uo pipefail

STATE_ROOT=""
PR_NUMBER=""
LABEL="review_results"

while [ $# -gt 0 ]; do
  case "$1" in
    --state-root) STATE_ROOT="${2:-}"; shift 2 ;;
    --pr)         PR_NUMBER="${2:-}"; shift 2 ;;
    --label)      LABEL="${2:-}"; shift 2 ;;
    *)
      echo "ERROR: review-results-archive-or-rm: unknown option: $1" >&2
      exit 1 ;;
  esac
done

case "$PR_NUMBER" in
  ''|*[!0-9]*)
    echo "ERROR: review-results-archive-or-rm: --pr must be numeric (got: '${PR_NUMBER}')" >&2
    exit 1 ;;
esac
if [ -z "$STATE_ROOT" ]; then
  echo "ERROR: review-results-archive-or-rm: --state-root is required" >&2
  exit 1
fi
case "$LABEL" in
  ''|*[!a-z_]*)
    echo "ERROR: review-results-archive-or-rm: --label must match [a-z_]+ (got: '${LABEL}')" >&2
    exit 1 ;;
esac

results_dir="$STATE_ROOT/.rite/review-results"
archive_dir="$results_dir/archive"
archived=0
removed=0
failed=0

for f in "$results_dir/${PR_NUMBER}"-*.json; do
  # glob がマッチしないと pattern 文字列そのものが入るので実在検査で弾く
  { [ -e "$f" ] || [ -L "$f" ]; } || continue

  keep=no
  if command -v jq >/dev/null 2>&1; then
    # rc=0 非空 → 退避 / rc=1 空・キー欠落・null → 削除 / それ以外 (2=parse 失敗, 4, 5=query
    # error 等) → 判定不能として退避。`// []` を使うのは書式の読みやすさのためで、キー欠落と
    # 空配列はどちらも rc=1 に落ちて帰結が同じ (`// empty` でも rc が変わるだけで結論は同じ)。
    jq -e '(.non_blocking_findings // []) | length > 0' "$f" >/dev/null 2>&1
    jq_rc=$?
    case "$jq_rc" in
      0) keep=yes ;;
      1) ;;
      *) keep=yes ;;
    esac
  else
    keep=yes   # jq 不在 = 判定不能 → 消さない
  fi

  if [ "$keep" != yes ]; then
    if rm -f "$f"; then
      echo "✅ ${LABEL} を削除: $f" >&2
      removed=$((removed + 1))
    else
      echo "WARNING: ${LABEL} 削除失敗 (PR #${PR_NUMBER}): $f" >&2
      echo "[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1; reason=${LABEL}_rm_failure; pr=${PR_NUMBER}" >&2
      failed=$((failed + 1))
    fi
    continue
  fi

  # 退避経路。mkdir と mv を分離し、それぞれの stderr を捨てない — 守っている対象が「全文の
  # 唯一の保存先」である以上、守れなかったときに原因 (既存衝突 / 権限 / ENOSPC / EXDEV) が
  # 残らないのは silent failure。reason も分けて切り分け可能にする。
  arch_err=$(mktemp "${TMPDIR:-/tmp}/rite-cleanup-archive-err-XXXXXX" 2>/dev/null) || arch_err=""
  if ! mkdir -p "$archive_dir" 2>"${arch_err:-/dev/null}"; then
    echo "WARNING: ${LABEL} の退避先ディレクトリを作成できません (PR #${PR_NUMBER}): $archive_dir — $f は削除もせずそのまま残します" >&2
    [ -n "$arch_err" ] && [ -s "$arch_err" ] && sed 's/^/  /' "$arch_err" >&2
    echo "[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1; reason=${LABEL}_archive_mkdir_failure; pr=${PR_NUMBER}" >&2
    failed=$((failed + 1))
  elif ! mv -n "$f" "$archive_dir/" 2>"${arch_err:-/dev/null}"; then
    # `mv -n` で同名既存の無警告上書きを防ぐ (上書きすると前 cycle の全文が消える)
    echo "WARNING: ${LABEL} の退避に失敗 (PR #${PR_NUMBER}): $f -> $archive_dir/ — 削除もせずそのまま残します" >&2
    [ -n "$arch_err" ] && [ -s "$arch_err" ] && sed 's/^/  /' "$arch_err" >&2
    echo "[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1; reason=${LABEL}_archive_mv_failure; pr=${PR_NUMBER}" >&2
    failed=$((failed + 1))
  elif [ -e "$f" ]; then
    # `mv -n` の同名既存時の rc は実装差がある (GNU coreutils は非ゼロを返すので直上の分岐が
    # 拾うが、rc=0 のまま何もしない実装もある)。source が残っていることを見て「上書きを避けて
    # 退避しなかった」を rc に依らず検出する (成功と誤報告しない)。
    echo "WARNING: 退避先に同名ファイルが既存のため ${LABEL} の退避を見送りました (PR #${PR_NUMBER}): $f — 上書きせず元の場所に残します" >&2
    echo "[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1; reason=${LABEL}_archive_name_collision; pr=${PR_NUMBER}" >&2
    failed=$((failed + 1))
  else
    echo "✅ ${LABEL} を退避 (非実測指摘あり / 判定不能): $f -> $archive_dir/" >&2
    archived=$((archived + 1))
  fi
  [ -n "$arch_err" ] && rm -f "$arch_err"
done

echo "[review-results-archive-or-rm] archived=${archived}; removed=${removed}; failed=${failed}; pr=${PR_NUMBER}"
exit 0
