#!/bin/bash
# review-results-archive-or-rm.sh — /rite:cleanup ステップ 6 の review-results 処理
#
# マージ済み PR のレビュー結果 JSON を、**非実測指摘 (non_blocking_findings[]) を持つものだけ
# 退避し、それ以外を削除する**。
#
# なぜ一律削除ではないか:
#   ステップ 6.1.d の関連 Issue 記録コメントは reviewer / severity / file:line のポインタと降格理由 (判定文) しか載せない。
#   cycle 中の `description` / `suggestion` の全文を持つのは本 JSON だけである。マージ時は
#   cleanup-follow-up-issue.sh が本 JSON から follow-up Issue へ全文転記するが、転記は本 helper
#   の前に走る。無条件削除すると転記失敗時に非実測 CRITICAL の詳細が merge 直後にどこにも
#   残らなくなり、「マージ後に人間が拾い直せる」という担保が偽になる (ポインタ化する前より後退する)。
#
# 判定不能はすべて退避側 (安全側) へ倒し、かつ loud に報告する:
#   jq 不在 / parse 失敗 / query error / 空ファイル のいずれも「中身を判定できない」状態であり、
#   消してしまうと消えたことにも気付けない。jq の rc は捨てず値域で分岐する
#   (`if jq -e ...; then` 形は rc=0 以外を全部「非空でない」へ丸め、top-level が object でない
#   JSON = query rc=5 を無警告で削除側へ落とす)。ただし「退避した」だけでは判定不能が起きた
#   事実が残らないため、rc が 0/1 以外のときは jq の診断ごと WARNING + reason marker を出す
#   (退避 IO の失敗を loud にしておきながら、ファイルの運命を決める判定そのものを無音にすると
#   保存パイプラインの壊れが永久に観測されない)。
#
# 対象 glob が `.json` ではなく `.json*` なのも同じ理由:
#   `.json.corrupt-<epoch>` は `scripts/review-source-resolve.sh` が parse 不能 / 必須フィールド
#   欠落 / 型不正を検出して rename したファイルで、`non_blocking_findings[]` の全文をそのまま
#   保持しうる。これを別経路で無条件削除すると「判定不能は退避」の宣言と正面から矛盾する。
#   同じ glob に載せれば corrupt は jq 判定で自然に「判定不能 → 退避」へ落ちる (経路を増やさない)。
#
# Usage:
#   review-results-archive-or-rm.sh --state-root <dir> --pr <number>
#
# Options:
#   --state-root  state root (state-path-resolve.sh の解決結果)。必須
#   --pr          PR 番号 (数値)。必須。glob `{pr}-*.json*` の prefix になる
#
# 対象 glob: <state-root>/.rite/review-results/<pr>-*.json*  (`.json` と `.json.corrupt-*` の両方)
# 退避先:    <state-root>/.rite/review-results/archive/
#
# Exit codes:
#   0: 正常終了 (処理対象 0 件を含む)。個々のファイルの失敗は非ブロッキングで WARNING + marker
#   1: 引数不正 (caller 契約違反)
#
# Emitted markers (stderr):
#   [CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1; reason=<r>; pr=<n>
#     reason ∈ { review_results_rm_failure
#              , review_results_archive_mkdir_failure    退避先ディレクトリを作れない
#              , review_results_archive_mv_failure       mv 自体が失敗
#              , review_results_archive_name_collision   退避先に同名既存 (上書きせず元の場所に残す)
#              , review_results_gitignore_failure        保存先の .gitignore を作れない (下記)
#              , review_results_undecidable              中身を判定できず退避側へ倒した
#              }
#   `review_results_undecidable` だけは `cause=` を伴う。`cause=jq_rc_<n>` はファイル単体の
#   壊れ (routine、人手の対応は不要) で、`cause=jq_missing` は jq 不在 (要対処の環境不備 —
#   全ファイルが無判定で退避され続ける)。consumer 側の判定表はこの `cause=` で列を分ける。
#   本 helper を起動できなかったとき (rc=127 等) の `review_results_helper_failed` は caller
#   (cleanup/SKILL.md ステップ 6) が emit する。helper 自身は emit しないが、marker family が
#   同一なので reason を追う人がここで行き止まらないよう併記しておく。
#   `_undecidable` 以外の失敗では **ファイルは削除しない** (退避できないなら元の場所に残す)。
#   `_undecidable` は退避自体は成功しうるので `failed` には数えない (観測用の marker)。
#   consumer 側 (cleanup ステップ 12 の判定表) も `_undecidable` だけは残作業に数えない。
#   `_gitignore_failure` も同じ理由で `failed` には数えない (ファイル自体は処理済み) が、
#   `_undecidable` と違い consumer 側では**実失敗側**へ倒す — 除外の欠落は退避した全文が
#   `git add -A` で公開リポジトリへ入る経路そのもので、人手の確認を要する。
#
# 保存先 `.gitignore` の同梱 (`_gitignore_failure`):
#   本 helper は `<results_dir>/archive/` に非実測指摘の全文を積む。除外は保存経路
#   (hooks/review-result-save.sh) が同じ `*` だけの .gitignore を書いて担保するが、機構の導入
#   前に作られた results_dir や保存時の書き込み失敗ではそれが無いまま cleanup を迎える。
#   保存を挟まずに cleanup が走るインストールでは保護が一度も効かないため、退避側でも保証する。
#
# Emitted summary (stdout, 1 行):
#   [review-results-archive-or-rm] archived=<n>; removed=<n>; failed=<n>; pr=<n>
set -uo pipefail

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
# shellcheck source=../gitignore-ensure.sh
source "$SCRIPT_DIR/../gitignore-ensure.sh"

STATE_ROOT=""
PR_NUMBER=""
# reason / メッセージの prefix。唯一の caller が単一の artifact 種別しか渡さないため定数。
# 実行時パラメータにすると reason 集合が静的に確定しなくなる (SoT を docstring に置けない)。
LABEL="review_results"

# 値の存在を検査してから shift 2 する。`hooks/wiki-query-inject.sh` の `_require_option_value` と
# 同じ契約・同じ引数順 (オプション名, 値) にしてある。素の `"$2"` + `set -u` でも nounset が
# 先に落とすので無限ループにはならないが、その診断は `$2: unbound variable` でどのオプションが
# 悪いのか分からない。ここで落とすのはメッセージを名指しにするため。
_require_option_value() {
  if [ -z "${2:-}" ]; then
    echo "ERROR: review-results-archive-or-rm: $1 requires a value" >&2
    exit 1
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --state-root) _require_option_value "$1" "${2:-}"; STATE_ROOT="$2"; shift 2 ;;
    --pr)         _require_option_value "$1" "${2:-}"; PR_NUMBER="$2"; shift 2 ;;
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

results_dir="$STATE_ROOT/.rite/review-results"
archive_dir="$results_dir/archive"
archived=0
removed=0
failed=0

# 保存先の `.gitignore` を保証する (docstring「保存先 .gitignore の同梱」参照)。
# ループ**前**に置き `[ -d "$results_dir" ]` を前提条件にする: (a) results_dir 不在の
# 新規 PR では 1 度も試行せず marker も出ない、(b) results_dir が実在するが当該 PR の
# 結果 JSON が 0 件の cleanup (archive/ に前回までの退避物だけが残る状態) でも除外が
# 張られる。ループ内に置くと (b) で保護が一度も発火しないまま `git add -A` が全文を
# 拾う経路が残る。guard が存在 (`-f`) ではなく中身 (`-s`) なのと、`{ ...; } 2>&1` の
# グループスコープで捕捉する理由は保存経路 (hooks/review-result-save.sh) と同一。
if [ -d "$results_dir" ] && ! _ensure_dir_gitignore "$results_dir"; then
    echo "WARNING: ${LABEL} の保存先に .gitignore を作成できません (PR #${PR_NUMBER}): $results_dir/.gitignore — 退避した非実測指摘の全文が git の追跡対象に入る恐れがあります" >&2
    [ -n "$_RITE_GITIGNORE_ERROR" ] && printf '%s\n' "$_RITE_GITIGNORE_ERROR" | sed 's/^/  /' >&2
    echo "[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1; reason=${LABEL}_gitignore_failure; pr=${PR_NUMBER}" >&2
fi

for f in "$results_dir/${PR_NUMBER}"-*.json*; do
  # glob がマッチしないと pattern 文字列そのものが入るので実在検査で弾く
  { [ -e "$f" ] || [ -L "$f" ]; } || continue

  keep=no
  keep_reason=""
  if command -v jq >/dev/null 2>&1; then
    # rc=0 非空 → 退避 / rc=1 空・キー欠落・null → 削除 / それ以外 (4=出力なし, 5=parse 失敗 /
    # query error 等) → 判定不能として退避。`// []` を使うのは書式の読みやすさのためで、キー欠落と
    # 空配列はどちらも rc=1 に落ちて帰結が同じ (`// empty` でも rc が変わるだけで結論は同じ)。
    # stderr は捨てずに捕捉する — 判定不能の原因 (parse error の位置 / query の型不一致) は
    # ここでしか観測できない。
    jq_err=$(jq -e '((.non_blocking_findings // []) | length > 0) or ((.guardrail_audit_log // []) | length > 0)' "$f" 2>&1 >/dev/null)
    jq_rc=$?
    case "$jq_rc" in
      0) keep=yes; keep_reason="監査対象あり" ;;
      1) ;;
      *)
        keep=yes
        keep_reason="判定不能 (jq rc=${jq_rc})"
        echo "WARNING: ${LABEL} の内容を判定できません (退避側へ倒します) (PR #${PR_NUMBER}): $f (jq rc=${jq_rc})" >&2
        [ -n "$jq_err" ] && printf '%s\n' "$jq_err" | sed 's/^/  /' >&2
        # `cause=` で原因を分ける。ファイル単体の壊れ (routine、人手の対応は不要) と
        # jq 不在 (要対処の環境不備。全ファイルが無判定で退避され archive/ が肥大する) は
        # 帰結が違うのに reason 文字列が同じだと、consumer の判定表が両者を同じ列へ倒す。
        echo "[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1; reason=${LABEL}_undecidable; cause=jq_rc_${jq_rc}; pr=${PR_NUMBER}" >&2
        ;;
    esac
  else
    keep=yes
    keep_reason="判定不能 (jq 不在)"
    echo "WARNING: jq が見つからないため ${LABEL} の内容を判定できません (退避側へ倒します) (PR #${PR_NUMBER}): $f" >&2
    echo "  対処: jq を導入してください。未導入の間は全ファイルが無判定で退避され続けます" >&2
    echo "[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1; reason=${LABEL}_undecidable; cause=jq_missing; pr=${PR_NUMBER}" >&2
  fi

  if [ "$keep" != yes ]; then
    # rm の stderr も捨てない。下の mkdir / mv と同形にしておかないと、同じ関数の 4 失敗経路で
    # 診断の形が 1 つだけ違う状態になり、後続の編集者がどちらを規範と読むか決められない。
    # 列 0 へ素通しさせない点も重要 — cleanup 側の照合は列 0 の行だけを marker 候補とする。
    if rm_err=$(rm -f "$f" 2>&1); then
      echo "✅ ${LABEL} を削除: $f" >&2
      removed=$((removed + 1))
    else
      echo "WARNING: ${LABEL} 削除失敗 (PR #${PR_NUMBER}): $f" >&2
      [ -n "$rm_err" ] && printf '%s\n' "$rm_err" | sed 's/^/  /' >&2
      echo "[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1; reason=${LABEL}_rm_failure; pr=${PR_NUMBER}" >&2
      failed=$((failed + 1))
    fi
    continue
  fi

  # 退避経路。mkdir と mv を分離し、それぞれの stderr を捨てない — 守っている対象が「cycle 中の全文の
  # 唯一の保存先（マージ時は follow-up Issue にも転記）」である以上、守れなかったときに原因 (既存衝突 / 権限 / ENOSPC / EXDEV) が
  # 残らないのは silent failure。reason も分けて切り分け可能にする。
  # stderr の捕捉に tempfile を使わないのは、mktemp 自身が失敗する条件 (ENOSPC / read-only
  # TMPDIR) が mkdir の失敗条件と相関するため — 診断が最も要る場面でだけ診断が消える。
  # command substitution なら失敗する余地が無く、trap も要らない (orphan tempfile も生じない)。
  # mkdir / mv はいずれも成功時 stdout を持たないので、2>&1 の捕捉で情報は落ちない。
  if ! arch_err=$(mkdir -p "$archive_dir" 2>&1); then
    echo "WARNING: ${LABEL} の退避先ディレクトリを作成できません (PR #${PR_NUMBER}): $archive_dir — $f は削除もせずそのまま残します" >&2
    [ -n "$arch_err" ] && printf '%s\n' "$arch_err" | sed 's/^/  /' >&2
    echo "[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1; reason=${LABEL}_archive_mkdir_failure; pr=${PR_NUMBER}" >&2
    failed=$((failed + 1))
  elif ! arch_err=$(mv -n "$f" "$archive_dir/" 2>&1); then
    # `mv -n` で同名既存の無警告上書きを防ぐ (上書きすると前 cycle の全文が消える)
    echo "WARNING: ${LABEL} の退避に失敗 (PR #${PR_NUMBER}): $f -> $archive_dir/ — 削除もせずそのまま残します" >&2
    [ -n "$arch_err" ] && printf '%s\n' "$arch_err" | sed 's/^/  /' >&2
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
    echo "✅ ${LABEL} を退避 (${keep_reason}): $f -> $archive_dir/" >&2
    archived=$((archived + 1))
  fi
done

echo "[review-results-archive-or-rm] archived=${archived}; removed=${removed}; failed=${failed}; pr=${PR_NUMBER}"
exit 0
