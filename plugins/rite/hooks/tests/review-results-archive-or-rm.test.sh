#!/bin/bash
# review-results-archive-or-rm.test.sh
#
# Behavioral tests for hooks/scripts/review-results-archive-or-rm.sh (/rite:cleanup ステップ 6)。
#
# 守っている invariant: 非実測指摘 (non_blocking_findings[]) の **全文の唯一の保存先** である
# レビュー結果 JSON を、判定できないまま消さないこと (Issue #2039 / #2024 D-01)。
# 「判定不能はすべて退避側へ倒す」という宣言は、jq の rc を捨てると容易に破れる — 本 suite は
# その分岐を rc 値域ごとに固定する。
#
# Coverage:
#   TC-1 判定分岐: 非空 -> 退避 / 空・キー欠落・null -> 削除
#   TC-2 判定不能 (parse 失敗 / top-level 非 object = jq query error / 空ファイル) -> 退避
#   TC-3 jq 不在 -> 退避 (PATH shim)
#   TC-4 退避失敗 3 種 (mkdir 失敗 / 同名衝突) は **削除せず** WARNING + reason marker
#   TC-5 引数 gate (--pr 非数値 / --state-root 欠落 / 未知オプション / --label 不正) は exit 1
#   TC-6 summary 行と 0 件時の no-op
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

TARGET="$SCRIPT_DIR/../scripts/review-results-archive-or-rm.sh"
[ -f "$TARGET" ] || { echo "FATAL: target not found: $TARGET" >&2; exit 1; }

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/rite-rrar-test-XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM HUP

OUT="$TMP_ROOT/out"; ERR="$TMP_ROOT/err"; RC=0

# $1=state_root, remaining=extra args
run_target() {
  local root="$1"; shift
  set +e
  bash "$TARGET" --state-root "$root" "$@" >"$OUT" 2>"$ERR"
  RC=$?
  set -e
}

# 新しい state root を用意し、`<pr>-<name>.json` を content で作る
new_root() {
  local root="$TMP_ROOT/root-$1"
  mkdir -p "$root/.rite/review-results"
  printf '%s' "$root"
}

# $1=root $2=basename $3=content
put_json() { printf '%s\n' "$3" > "$1/.rite/review-results/$2"; }

# $1=root $2=basename -> ARCHIVED | kept-in-place | DELETED
where() {
  if [ -f "$1/.rite/review-results/$2" ]; then echo kept-in-place
  elif [ -f "$1/.rite/review-results/archive/$2" ]; then echo ARCHIVED
  else echo DELETED; fi
}

echo "--- TC-1: 判定分岐 (非空 -> 退避 / 空・キー欠落・null -> 削除) ---"
r=$(new_root tc1)
put_json "$r" "9-nonempty.json" '{"non_blocking_findings":[{"id":"F-01"}]}'
put_json "$r" "9-empty.json"    '{"non_blocking_findings":[]}'
put_json "$r" "9-missing.json"  '{"findings":[]}'
put_json "$r" "9-null.json"     '{"non_blocking_findings":null}'
run_target "$r" --pr 9
assert "TC-1 exit 0" "0" "$RC"
assert "TC-1 非空 -> 退避" "ARCHIVED" "$(where "$r" 9-nonempty.json)"
assert "TC-1 空配列 -> 削除" "DELETED" "$(where "$r" 9-empty.json)"
assert "TC-1 キー欠落 (旧形式) -> 削除" "DELETED" "$(where "$r" 9-missing.json)"
assert "TC-1 null -> 削除" "DELETED" "$(where "$r" 9-null.json)"
assert_grep "TC-1 summary が件数を報告" "$OUT" 'archived=1; removed=3; failed=0; pr=9'

echo "--- TC-2: 判定不能はすべて退避側 (安全側) ---"
r=$(new_root tc2)
put_json "$r" "9-parse.json" '{ this is not json'
# top-level が object でない = query が rc=5 で落ちる。`if jq -e ...; then` 形だと
# 「非空でない」に丸められて無警告で削除される経路 (rc を値域で見ることの load-bearing な根拠)
put_json "$r" "9-toplevel-array.json" '[{"non_blocking_findings":[{"id":"F-01"}]}]'
: > "$r/.rite/review-results/9-emptyfile.json"
run_target "$r" --pr 9
assert "TC-2 exit 0 (非ブロッキング)" "0" "$RC"
assert "TC-2 parse 失敗 -> 退避" "ARCHIVED" "$(where "$r" 9-parse.json)"
assert "TC-2 top-level 非 object (jq query error) -> 退避" "ARCHIVED" "$(where "$r" 9-toplevel-array.json)"
assert "TC-2 空ファイル -> 退避" "ARCHIVED" "$(where "$r" 9-emptyfile.json)"
assert "TC-2 削除は 0 件" "0" "$(sed -n 's/.*removed=\([0-9]*\);.*/\1/p' "$OUT")"

echo "--- TC-3: jq 不在 -> 退避 ---"
r=$(new_root tc3)
put_json "$r" "9-empty.json" '{"non_blocking_findings":[]}'
shim="$TMP_ROOT/nojq-bin"; mkdir -p "$shim"
# jq **だけ**を PATH から消す (他コマンドは実体へ symlink 委譲)。bash 自身も含めないと
# `PATH=... bash` の解決に失敗して rc=127 になり、jq 不在の分岐を測れない。
for c in bash mktemp mkdir mv rm sed cat env; do
  p=$(command -v "$c" 2>/dev/null) && ln -sf "$p" "$shim/$c"
done
abs_bash=$(command -v bash)
# 前提の自己検査: shim 下で jq が本当に消えていること (消えていなければ TC-3 は vacuous)
assert "TC-3 [前提] shim PATH では jq が解決できない" "1" \
  "$(PATH="$shim" command -v jq >/dev/null 2>&1; echo $?)"
set +e
PATH="$shim" "$abs_bash" "$TARGET" --state-root "$r" --pr 9 >"$OUT" 2>"$ERR"; RC=$?
set -e
assert "TC-3 exit 0" "0" "$RC"
assert "TC-3 jq 不在なら空配列でも退避 (判定不能)" "ARCHIVED" "$(where "$r" 9-empty.json)"

echo "--- TC-4: 退避失敗は削除せず WARNING + reason marker ---"
# (a) mkdir 失敗: archive を通常ファイルで塞ぐ
r=$(new_root tc4a)
printf 'BLOCKER\n' > "$r/.rite/review-results/archive"
put_json "$r" "9-x.json" '{"non_blocking_findings":[{"id":"F-01"}]}'
run_target "$r" --pr 9
assert "TC-4a exit 0 (非ブロッキング)" "0" "$RC"
assert "TC-4a mkdir 失敗でも削除しない" "kept-in-place" "$(where "$r" 9-x.json)"
assert_grep "TC-4a reason=..._archive_mkdir_failure" "$ERR" 'reason=review_results_archive_mkdir_failure; pr=9'
assert_grep "TC-4a mkdir の stderr を捨てない (診断が残る)" "$ERR" 'mkdir'
assert "TC-4a failed=1" "1" "$(sed -n 's/.*failed=\([0-9]*\);.*/\1/p' "$OUT")"

# (b) 同名衝突: 退避先に同名を先置き。上書きせず元の場所に残す
r=$(new_root tc4b)
mkdir -p "$r/.rite/review-results/archive"
printf 'PRE-EXISTING\n' > "$r/.rite/review-results/archive/9-y.json"
put_json "$r" "9-y.json" '{"non_blocking_findings":[{"id":"F-09"}]}'
run_target "$r" --pr 9
assert "TC-4b exit 0" "0" "$RC"
assert "TC-4b 同名衝突では削除しない" "kept-in-place" "$(where "$r" 9-y.json)"
assert "TC-4b 退避先の既存を上書きしない" "PRE-EXISTING" "$(cat "$r/.rite/review-results/archive/9-y.json")"
# rc は mv 実装差があるため reason は mv_failure / name_collision のどちらでもよい。
# **どちらであっても** 「削除しない + marker が出る」ことが本 TC の invariant。
assert "TC-4b 衝突を示す reason marker が 1 本出る" "1" \
  "$(grep -cE 'reason=review_results_archive_(mv_failure|name_collision); pr=9' "$ERR" || true)"
assert "TC-4b failed=1" "1" "$(sed -n 's/.*failed=\([0-9]*\);.*/\1/p' "$OUT")"

echo "--- TC-5: 引数 gate (caller 契約違反は exit 1) ---"
r=$(new_root tc5)
run_target "$r" --pr abc
assert "TC-5 --pr 非数値は exit 1" "1" "$RC"
assert_grep "TC-5 --pr 非数値の診断" "$ERR" 'must be numeric'
set +e
bash "$TARGET" --pr 9 >"$OUT" 2>"$ERR"; RC=$?
set -e
assert "TC-5 --state-root 欠落は exit 1" "1" "$RC"
run_target "$r" --pr 9 --bogus x
assert "TC-5 未知オプションは exit 1" "1" "$RC"
assert_grep "TC-5 未知オプションの診断" "$ERR" 'unknown option'
run_target "$r" --pr 9 --label 'Bad-Label'
assert "TC-5 --label 不正は exit 1" "1" "$RC"

echo "--- TC-6: 0 件は no-op で exit 0 ---"
r=$(new_root tc6)
run_target "$r" --pr 9
assert "TC-6 対象 0 件でも exit 0" "0" "$RC"
assert_grep "TC-6 summary は全て 0" "$OUT" 'archived=0; removed=0; failed=0; pr=9'
# glob 未展開の pattern 文字列を掴んで誤って処理しないこと
assert "TC-6 archive ディレクトリを無用に作らない" "no" \
  "$([ -d "$r/.rite/review-results/archive" ] && echo yes || echo no)"

# 他 PR のファイルを巻き込まない (prefix 固定の確認)
echo "--- TC-7: 他 PR のファイルに触れない ---"
r=$(new_root tc7)
put_json "$r" "9-mine.json"  '{"non_blocking_findings":[]}'
put_json "$r" "10-other.json" '{"non_blocking_findings":[]}'
run_target "$r" --pr 9
assert "TC-7 自 PR は削除" "DELETED" "$(where "$r" 9-mine.json)"
assert "TC-7 他 PR は無傷" "kept-in-place" "$(where "$r" 10-other.json)"

print_summary "review-results-archive-or-rm.test.sh"
