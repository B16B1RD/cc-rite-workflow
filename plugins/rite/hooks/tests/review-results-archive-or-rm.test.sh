#!/bin/bash
# review-results-archive-or-rm.test.sh
#
# Behavioral tests for hooks/scripts/review-results-archive-or-rm.sh (/rite:cleanup ステップ 6)。
#
# 守っている invariant: 非実測指摘 (non_blocking_findings[]) の **全文の唯一の保存先** である
# レビュー結果 JSON を、判定できないまま消さないこと。
# 「判定不能はすべて退避側へ倒す」という宣言は、jq の rc を捨てると容易に破れる — 本 suite は
# その分岐を rc 値域ごとに固定する。加えて「倒したことが観測できる」ことも固定する (退避 IO の
# 失敗だけ loud にして判定そのものを無音にすると、保存パイプラインの壊れが永久に観測されない)。
#
# Coverage:
#   TC-1 判定分岐: 非空 -> 退避 / 空・キー欠落・null -> 削除。`.json.corrupt-*` も同 glob が拾う
#   TC-2 判定不能 (parse 失敗 / top-level 非 object = jq query error / 空ファイル) -> 退避 + marker
#   TC-3 jq 不在 -> 退避 + marker (PATH shim)
#   TC-4 失敗 4 種 (rm 失敗 / mkdir 失敗 / mv 失敗 or 同名衝突 / mv rc=0 の同名衝突) は
#        **削除せず** WARNING + reason marker。外部コマンドの stderr 3 本 (jq / mkdir / mv) が
#        捨てられないことも pin する。name_collision 分岐は BSD mv (rc=0) 専用の経路で、
#        GNU coreutils では手前の mv_failure が先に拾うため mv stub で到達させる
#   TC-5 引数 gate (--pr 非数値 / --state-root 欠落 / 未知オプション / 値なし末尾オプション) は exit 1
#   TC-6 summary 行と 0 件時の no-op
#   TC-7 他 PR のファイルに触れない (prefix 固定。`10-` / `90-` の両方向)
#   TC-8 唯一の呼び出し元 (cleanup ステップ 6) が helper を呼び rc を捨てていない (caller coupling)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

TARGET="$SCRIPT_DIR/../scripts/review-results-archive-or-rm.sh"
[ -f "$TARGET" ] || { echo "FATAL: target not found: $TARGET" >&2; exit 1; }

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/rite-rrar-test-XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM HUP

OUT="$TMP_ROOT/out"; ERR="$TMP_ROOT/err"; RC=0

# $1=state_root, remaining=extra args
# 本 suite は `set -uo pipefail` 始まりで errexit を有効化していない。ここで `set -e` を呼ぶと
# 「復元」ではなく「有効化」になり、以降 top-level の非ゼロ終了で print_summary 前に中断する。
# 姉妹 suite (review-helpers-gate-behavior.test.sh) と同じく素で rc を拾う。
run_target() {
  local root="$1"; shift
  bash "$TARGET" --state-root "$root" "$@" >"$OUT" 2>"$ERR"
  RC=$?
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
# `.json.corrupt-<epoch>` も同 glob (`{pr}-*.json*`) が拾う。corrupt は「中身を判定できない」
# 状態そのもので、別経路で無条件削除すると「判定不能は保全」の宣言と正面から矛盾する。
# 判定できる corrupt (rename 理由が必須フィールド欠落 / 型不正で JSON 自体は valid) も同じ
# 判定に載る — 中身が空なら削除されるのが正しい。
put_json "$r" "9-corrupt.json.corrupt-1700000000" '{"non_blocking_findings":[{"id":"F-02"}]}'
put_json "$r" "9-corrupt-empty.json.corrupt-1700000001" '{"non_blocking_findings":[]}'
run_target "$r" --pr 9
assert "TC-1 exit 0" "0" "$RC"
assert "TC-1 非空 -> 退避" "ARCHIVED" "$(where "$r" 9-nonempty.json)"
assert "TC-1 空配列 -> 削除" "DELETED" "$(where "$r" 9-empty.json)"
assert "TC-1 キー欠落 (旧形式) -> 削除" "DELETED" "$(where "$r" 9-missing.json)"
assert "TC-1 null -> 削除" "DELETED" "$(where "$r" 9-null.json)"
assert "TC-1 .corrupt-* も同 glob が拾い、非空なら退避" "ARCHIVED" "$(where "$r" 9-corrupt.json.corrupt-1700000000)"
assert "TC-1 .corrupt-* でも中身が空なら削除" "DELETED" "$(where "$r" 9-corrupt-empty.json.corrupt-1700000001)"
assert_grep "TC-1 summary が件数を報告" "$OUT" 'archived=2; removed=4; failed=0; pr=9'

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
# 「退避側へ倒した」だけでは判定不能が起きた事実がどこにも残らない (壊れた JSON と正常な JSON が
# 同一文言・同一カウントで退避され、保存パイプラインの壊れが永久に無警告になる)。3 件分の marker を固定する。
assert "TC-2 判定不能 3 件それぞれに undecidable marker が出る" "3" \
  "$(grep -cE 'reason=review_results_undecidable; pr=9' "$ERR" || true)"
# jq の診断 (parse error の位置等) を捨てない。捨てると「なぜ判定できなかったか」が消える。
assert_grep "TC-2 jq の stderr を捨てない (診断が残る)" "$ERR" '^  '
# 退避メッセージが「非実測指摘あり」と「判定不能」を弁別する (同一文言だと archive/ の中身から
# 全文が読めるファイルと読めないファイルを区別できない)
assert_grep "TC-2 退避理由が判定不能と明示される" "$ERR" 'を退避 \(判定不能'
assert "TC-2 判定不能では failed に数えない (退避自体は成功)" "0" \
  "$(sed -n 's/.*failed=\([0-9]*\);.*/\1/p' "$OUT")"

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
PATH="$shim" "$abs_bash" "$TARGET" --state-root "$r" --pr 9 >"$OUT" 2>"$ERR"; RC=$?
assert "TC-3 exit 0" "0" "$RC"
assert "TC-3 jq 不在なら空配列でも退避 (判定不能)" "ARCHIVED" "$(where "$r" 9-empty.json)"
assert_grep "TC-3 jq 不在も undecidable marker で観測できる" "$ERR" 'reason=review_results_undecidable; pr=9'

echo "--- TC-4: 失敗は削除せず WARNING + reason marker ---"
# (0) rm 失敗: 削除対象が入っているディレクトリを read-only にして unlink を失敗させる。
# 退行 (WARNING + marker + failed カウンタの 3 つ) を落とすと、/rite:cleanup は failed=0 を報告し
# marker も出さないまま JSON が消えずに残り、orchestrator が完全成功と読む。
if [ "$(id -u)" -eq 0 ]; then
  skip "TC-4-rm root 実行では chmod a-w が rm を止められないため skip"
else
  r=$(new_root tc4rm)
  put_json "$r" "9-del.json" '{"non_blocking_findings":[]}'
  chmod a-w "$r/.rite/review-results"
  run_target "$r" --pr 9
  chmod u+w "$r/.rite/review-results"
  assert "TC-4-rm exit 0 (非ブロッキング)" "0" "$RC"
  assert "TC-4-rm 削除失敗でもファイルは残る" "kept-in-place" "$(where "$r" 9-del.json)"
  assert_grep "TC-4-rm reason=..._rm_failure" "$ERR" 'reason=review_results_rm_failure; pr=9'
  # rm の stderr 転送も mkdir / mv と同型に pin する (4 失敗経路すべてに診断 pin を揃える)。
  # 素通しさせると列 0 に着地し、cleanup 側の「列 0 の行だけを marker 候補とする」照合と衝突する。
  assert_grep "TC-4-rm rm の stderr を捨てない (診断が残る)" "$ERR" '^  rm'
  assert "TC-4-rm failed=1" "1" "$(sed -n 's/.*failed=\([0-9]*\);.*/\1/p' "$OUT")"
fi

# (a) mkdir 失敗: archive を通常ファイルで塞ぐ
r=$(new_root tc4a)
printf 'BLOCKER\n' > "$r/.rite/review-results/archive"
put_json "$r" "9-x.json" '{"non_blocking_findings":[{"id":"F-01"}]}'
run_target "$r" --pr 9
assert "TC-4a exit 0 (非ブロッキング)" "0" "$RC"
assert "TC-4a mkdir 失敗でも削除しない" "kept-in-place" "$(where "$r" 9-x.json)"
assert_grep "TC-4a reason=..._archive_mkdir_failure" "$ERR" 'reason=review_results_archive_mkdir_failure; pr=9'
# pattern を素の `mkdir` にすると直上の assert が既に見ている reason marker 行
# (`..._archive_mkdir_failure`) にも match し、helper の stderr 転送を削除しても緑のままになる。
# 転送行に固有の形へ anchor する: 先頭 2 スペースは helper の `sed 's/^/  /'` 由来、`mkdir:` の
# program-name prefix は locale 非依存 (ja_JP でも `  mkdir: ...` と出る)。
assert_grep "TC-4a mkdir の stderr を捨てない (診断が残る)" "$ERR" '^  mkdir'
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
# mv の stderr 転送も pin する。jq (TC-2) / mkdir (TC-4a) には pin があるのに mv だけ無検査だと、
# helper docstring が「守れなかったときに原因 (既存衝突 / 権限 / ENOSPC / EXDEV) が残らないのは
# silent failure」と宣言している 3 経路のうち 1 本だけ強制層を欠く。anchor は TC-4a と同型
# (`sed 's/^/  /'` 由来の先頭 2 スペース + locale 非依存の program-name prefix)。
assert_grep "TC-4b mv の stderr を捨てない (診断が残る)" "$ERR" '^  mv'
# 「GNU では必ず mv_failure 側に落ちる」ことは **assert しない** — ラベル自身が platform 限定を
# 表明する assert を無条件評価すると、BSD (`mv -n` が衝突時 rc=0) の CI leg に恒久 red を作り、
# TC-4b の本質 (削除しない + marker が出る = 上の 2 assert) が platform 非依存に守られている事実を
# 覆い隠す。BSD 側の name_collision 分岐は TC-4c が mv stub で決定論的にカバーする。

# (c) BSD 相当の `mv -n` (同名既存で rc=0 のまま何もしない) を PATH shim で再現する。
# helper が rc に依らず source 残存で衝突を検出できることの behavioral pin。
r=$(new_root tc4c)
mkdir -p "$r/.rite/review-results/archive"
printf 'PRE-EXISTING\n' > "$r/.rite/review-results/archive/9-w.json"
put_json "$r" "9-w.json" '{"non_blocking_findings":[{"id":"F-01"}]}'
mvshim="$TMP_ROOT/mv-noop-bin"; mkdir -p "$mvshim"
printf '#!/bin/bash\nexit 0\n' > "$mvshim/mv"
chmod +x "$mvshim/mv"
# 前提の自己検査: shim が実体の mv より先に解決されること (されなければ本 TC は vacuous)
assert "TC-4c [前提] shim の mv が PATH 先頭で解決される" "$mvshim/mv" \
  "$(PATH="$mvshim:$PATH" command -v mv)"
PATH="$mvshim:$PATH" bash "$TARGET" --state-root "$r" --pr 9 >"$OUT" 2>"$ERR"; RC=$?
assert "TC-4c exit 0 (非ブロッキング)" "0" "$RC"
assert "TC-4c mv rc=0 でも source 残存を見て衝突と判定する" "kept-in-place" "$(where "$r" 9-w.json)"
assert "TC-4c 退避先の既存を上書きしない" "PRE-EXISTING" "$(cat "$r/.rite/review-results/archive/9-w.json")"
assert_grep "TC-4c reason=..._archive_name_collision" "$ERR" 'reason=review_results_archive_name_collision; pr=9'
assert "TC-4c failed=1" "1" "$(sed -n 's/.*failed=\([0-9]*\);.*/\1/p' "$OUT")"
assert "TC-4c 成功と誤報告しない (archived=0)" "0" \
  "$(sed -n 's/.*archived=\([0-9]*\);.*/\1/p' "$OUT")"

echo "--- TC-5: 引数 gate (caller 契約違反は exit 1) ---"
r=$(new_root tc5)
run_target "$r" --pr abc
assert "TC-5 --pr 非数値は exit 1" "1" "$RC"
assert_grep "TC-5 --pr 非数値の診断" "$ERR" 'must be numeric'
bash "$TARGET" --pr 9 >"$OUT" 2>"$ERR"; RC=$?
assert "TC-5 --state-root 欠落は exit 1" "1" "$RC"
run_target "$r" --pr 9 --bogus x
assert "TC-5 未知オプションは exit 1" "1" "$RC"
assert_grep "TC-5 未知オプションの診断" "$ERR" 'unknown option'
# 値なし末尾オプション: 素の `"$2"` + `set -u` でも nounset が落とすが、その診断は
# `$2: unbound variable` でどのオプションが悪いか分からない。オプション名を名指しする
# 明示診断が出ることを固定する。`_timeout` (portable wrapper) で囲むのは、`shift 2` を
# 無条件に呼ぶ形へ退行させたときのハングでランナー全体が止まるのを防ぐため
# (run-tests.sh は per-file timeout を持たない)。bare `timeout` は macOS leg に coreutils が
# 無く rc=127 になるため使わない。
for opt in --pr --state-root; do
  _timeout 5 bash "$TARGET" --state-root "$r" "$opt" >"$OUT" 2>"$ERR"; RC=$?
  assert "TC-5 値なし末尾 $opt は exit 1 (ハングしない)" "1" "$RC"
  # pattern の先頭を `--` にしない (grep がオプションとして解釈する)。診断行の prefix を含める
  assert_grep "TC-5 値なし末尾 $opt の診断" "$ERR" "review-results-archive-or-rm: $opt requires a value"
done

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
# prefix 拡張の弁別: glob を `${PR}*` へ緩める退行を落とす (`9-` の `-` が境界を作っている)
put_json "$r" "90-other.json" '{"non_blocking_findings":[]}'
run_target "$r" --pr 9
assert "TC-7 自 PR は削除" "DELETED" "$(where "$r" 9-mine.json)"
assert "TC-7 他 PR は無傷" "kept-in-place" "$(where "$r" 10-other.json)"
assert "TC-7 prefix 拡張 (90-) も無傷" "kept-in-place" "$(where "$r" 90-other.json)"

# helper の唯一の呼び出し元を固定する。helper 本体をいくら厚く pin しても、cleanup ステップ 6 の
# 呼び出しを旧 `rite_rm review_results` 形へ戻せば退避機構は丸ごと消え、それを検出する層が
# どこにも無い (記録コメントが全文を持たなくなった後にこれが起きると、merge 直後に非実測
# CRITICAL の詳細がどこにも残らない)。SKILL.md ⇄ helper の coupling を静的に pin する
# 既存の規律 (review-helpers-gate-behavior.test.sh の TC-5c / TC-5g 等) と同型。
echo "--- TC-8: cleanup ステップ 6 が helper を呼んでいる (caller coupling) ---"
CLEANUP_MD="$SCRIPT_DIR/../../skills/cleanup/SKILL.md"
if [ ! -f "$CLEANUP_MD" ]; then
  fail "TC-8 cleanup/SKILL.md が見つからない: $CLEANUP_MD"
else
  assert "TC-8 helper 呼び出しが 1 本存在する" "1" \
    "$(grep -cF 'hooks/scripts/review-results-archive-or-rm.sh \' "$CLEANUP_MD" || true)"
  # 旧形 (無条件削除) への差し戻しを落とす。`rite_rm` の第 1 引数が `review_results` の行が
  # 復活したら退避機構が bypass されている。
  assert "TC-8 旧 rite_rm review_results 形が復活していない" "0" \
    "$(grep -cE '^rite_rm[[:space:]]+review_results([[:space:]]|$)' "$CLEANUP_MD" || true)"
  # rc を捨てていないこと (helper が起動できなかった cycle が「完了」と報告されるのを防ぐ)
  assert "TC-8 helper の rc を捕捉している" "1" \
    "$(grep -cF '|| _rrar_rc=$?' "$CLEANUP_MD" || true)"
fi

print_summary "review-results-archive-or-rm.test.sh"
