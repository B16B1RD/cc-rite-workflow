#!/usr/bin/env bash
# cleanup-pr-state-purge.sh — PR-specific state ファイルの削除。
# cleanup/SKILL.md ステップ 6 から抽出した後片付けロジック。振る舞いは抽出前と同一。
# 引数はすべて名前付きオプションで受けるため、cleanup 以外の経路からも呼べる。
#
# 他 PR 誤削除防止のため glob は `<pr>-` prefix 固定。
#
# Usage:
#   cleanup-pr-state-purge.sh --pr <N> [--state-root <path>] [--dry-run]
#
# 出力 (stderr):
#   ✅ <label> を削除: <path>                                    (削除成功ごと)
#   [CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1; reason=<...>; pr=<N>
#   --dry-run では削除せず `[DRY-RUN] <label> を削除対象として検出: <path>` を **stdout** に出す。
#
# ステップ 6.0（残存非実測指摘からの follow-up Issue 起票）は本 helper の対象外。起票は既に
# cleanup-follow-up-issue.sh が担っており、Issue 中止の経路では起票自体が不要なため、
# ここへ引き込む理由がない。
#
# exit code: 全運用経路 0（非ブロッキング。invalid pr_number も 0）。usage error のみ 2。
#
# `set -e` は使わない: rm の失敗を捕捉して marker に変換する構造に依存している。
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

pr_number=""
state_root=""
dry_run=false

usage() {
  echo "ERROR: $1" >&2
  echo "Usage: cleanup-pr-state-purge.sh --pr <N> [--state-root <path>] [--dry-run]" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --pr)         shift; [ "$#" -gt 0 ] || usage "--pr requires a value"; pr_number=$1; shift ;;
    --state-root) shift; [ "$#" -gt 0 ] || usage "--state-root requires a value"; state_root=$1; shift ;;
    --dry-run)    dry_run=true; shift ;;
    *) usage "unknown option: $1" ;;
  esac
done

# PR 番号が数値でない場合は削除を一切行わず marker で surface する（glob が prefix 固定を失い、
# 他 PR の state を巻き込む経路を構造的に塞ぐ）。運用経路なので exit 0。
case "$pr_number" in
  ''|*[!0-9]*)
    echo "ERROR: invalid pr_number: '$pr_number'" >&2
    echo "[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1; reason=invalid_pr_number" >&2
    exit 0 ;;
esac

# 削除対象はリポジトリ共通の state ルート基準 (state-path-resolve.sh)。書込側
# (review-result-save.sh / fix.md 2.1.A / fix.md 3.3.1) と同一解決のため、セッション worktree に
# 書かれて main checkout の削除が no-op になる不整合を防ぐ (解決失敗時は cwd fallback)
if [ -z "$state_root" ]; then
  state_root=$(bash "$SCRIPT_DIR/../state-path-resolve.sh" 2>/dev/null) || state_root=""
  [ -n "$state_root" ] || { echo "WARNING: state-path-resolve.sh の解決に失敗。cwd をフォールバック使用します" >&2; state_root="$(pwd)"; }
fi

rite_rm() {
  local label="$1"; shift
  local f
  for f in "$@"; do
    { [ -e "$f" ] || [ -L "$f" ]; } || continue
    if [ "$dry_run" = "true" ]; then
      # dry-run の対象一覧は stdout（削除実行時の `✅ … を削除:` は従来どおり stderr）。
      echo "[DRY-RUN] ${label} を削除対象として検出: $f"
    elif rm -f "$f"; then
      echo "✅ ${label} を削除: $f" >&2
    else
      echo "WARNING: ${label} 削除失敗 (PR #${pr_number}): $f" >&2
      echo "[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1; reason=${label}_rm_failure; pr=${pr_number}" >&2
    fi
  done
}

# レビュー結果 JSON は一律削除しない。**非実測指摘 (non_blocking_findings[]) を持つものは
# 削除せず archive/ へ退避する** — 関連 Issue 記録コメントはポインタ (reviewer / severity /
# file:line) + 降格理由 (判定文) しか載せないため、無条件削除すると非実測 CRITICAL の詳細が
# merge 直後に失われ、人間が拾い直せなくなる。
# 判定 (jq rc の値域分岐 / 判定不能は退避側へ倒す) と退避 (mkdir・mv の分離、同名衝突の検出) は
# helper へ委譲済み。契約と reason 語彙の SoT は helper docstring、挙動は
# hooks/tests/review-results-archive-or-rm.test.sh が behavioral に固定する。
# `.json.corrupt-*` も同 helper の glob (`{pr}-*.json*`) が拾う。corrupt は「中身を判定できない」
# 状態そのものなので、別経路で無条件削除すると同一ブロック内に「判定不能は保全」と「判定不能は
# 削除」の 2 ポリシーが並ぶ (corrupt rename の 3 経路のうち 2 つは構造的に valid な JSON で、
# non_blocking_findings[] の全文を保持しうる)。
#
# helper の rc は捨てない。**marker 不在を「削除成功」と読んではならない**という本ステップの規約
# は、helper が起動すらしなかった場合 (helper 欠落で rc=127) に marker が 1 本も出ないことで
# 破れる。rc を見て失敗を marker に変換する。
if [ "$dry_run" = "true" ]; then
  # archive/rm helper は --dry-run を持たないため、対象の列挙のみ行う（実際の判定 = 退避か削除かは
  # helper の責務であり、ここで再実装すると 2 つ目のポリシーが生まれる）。
  for _rr in "$state_root/.rite/review-results/${pr_number}"-*.json*; do
    { [ -e "$_rr" ] || [ -L "$_rr" ]; } || continue
    echo "[DRY-RUN] review_results を退避/削除対象として検出: $_rr"
  done
else
  _rrar_rc=0
  bash "$SCRIPT_DIR/review-results-archive-or-rm.sh" \
    --state-root "$state_root" --pr "$pr_number" || _rrar_rc=$?
  if [ "$_rrar_rc" -ne 0 ]; then
    echo "WARNING: review-results の退避/削除 helper が rc=${_rrar_rc} で失敗しました。レビュー結果 JSON は未処理のまま残っています" >&2
    echo "  原因候補: helper 欠落・非可読 (rc=127) / 引数不正 (rc=1)" >&2
    echo "[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1; reason=review_results_helper_failed; pr=${pr_number}; rc=${_rrar_rc}" >&2
  fi
fi

rite_rm fix_retry_state "$state_root/.rite/state/fix-fallback-retry-${pr_number}.count"
rite_rm fix_cycle_state "$state_root/.rite/fix-cycle-state/${pr_number}.json"
rite_rm legacy_fix_cycle_state "$state_root/.rite/fix-cycle-state.json"
rite_rm accepted_fingerprints "$state_root/.rite/state/accepted-fingerprints-${pr_number}.txt"
rite_rm review_run_since "$state_root/.rite/state/review-run-since-${pr_number}.txt"
rite_rm nb_sweep_done "$state_root/.rite/state/nb-sweep-done-${pr_number}.txt"

exit 0
