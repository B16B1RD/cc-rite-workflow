#!/usr/bin/env bash
# cleanup-pr-state-purge.sh の単体テスト（T-05 prefix 固定削除 / T-06 dry-run）。
#
# 対応 AC:
#   AC-5 `<pr>-` prefix 固定で削除し、別 PR の state を巻き込まない
#   AC-6 --dry-run が削除しない
#
# review-results の退避/削除そのものは review-results-archive-or-rm.test.sh が behavioral に
# 固定する。本ファイルは purge helper が「どのファイルを対象にするか」と「失敗をどう surface
# するか」を見る。
set -u
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HELPER="$SCRIPT_DIR/../scripts/cleanup-pr-state-purge.sh"
pass=0 fail=0
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
ok(){ pass=$((pass+1)); echo "  ✅ $1"; }
bad(){ fail=$((fail+1)); echo "  ❌ $1"; }
assert_contains(){ case "$2" in *"$3"*) ok "$1";; *) bad "$1 (出力: $2)";; esac; }
assert_not_contains(){ case "$2" in *"$3"*) bad "$1 (出力: $2)";; *) ok "$1";; esac; }
assert_eq(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected='$3' actual='$2')"; fi; }
assert_absent(){ if [ -e "$2" ]; then bad "$1 ($2 が残っている)"; else ok "$1"; fi; }
assert_present(){ if [ -e "$2" ]; then ok "$1"; else bad "$1 ($2 が消えた)"; fi; }

# 対象 PR (42) と別 PR (4) / prefix が伸びた PR (420) の state を同居させる。
# 4 と 420 は `42` への部分一致・prefix 一致で巻き込まれうる境界値。
seed(){
  local root="$1"
  mkdir -p "$root/.rite/state" "$root/.rite/fix-cycle-state" "$root/.rite/review-results"
  for pr in 42 4 420; do
    printf 'x\n' > "$root/.rite/state/fix-fallback-retry-${pr}.count"
    printf 'x\n' > "$root/.rite/fix-cycle-state/${pr}.json"
    printf 'x\n' > "$root/.rite/state/accepted-fingerprints-${pr}.txt"
    printf 'x\n' > "$root/.rite/state/review-run-since-${pr}.txt"
    printf 'x\n' > "$root/.rite/state/nb-sweep-done-${pr}.txt"
    printf '{"non_blocking_findings":[]}\n' > "$root/.rite/review-results/${pr}-cycle1.json"
  done
  printf 'x\n' > "$root/.rite/fix-cycle-state.json"   # legacy（PR 非依存）
}

echo "=== cleanup-pr-state-purge: prefix 固定（AC-5）==="

r=$(mktemp -d "$TMP_ROOT/root.XXXXXX"); seed "$r"
out=$(bash "$HELPER" --pr 42 --state-root "$r" 2>&1); rc=$?
assert_eq "exit 0" "$rc" "0"
assert_absent "対象 PR の fix_retry_state を削除する" "$r/.rite/state/fix-fallback-retry-42.count"
assert_absent "対象 PR の fix_cycle_state を削除する" "$r/.rite/fix-cycle-state/42.json"
assert_absent "対象 PR の accepted_fingerprints を削除する" "$r/.rite/state/accepted-fingerprints-42.txt"
assert_absent "対象 PR の review_run_since を削除する" "$r/.rite/state/review-run-since-42.txt"
assert_absent "対象 PR の nb_sweep_done を削除する" "$r/.rite/state/nb-sweep-done-42.txt"
assert_absent "legacy fix_cycle_state を削除する" "$r/.rite/fix-cycle-state.json"
# 別 PR は残る（AC-5 の Then）。
assert_present "別 PR (4) の state を巻き込まない" "$r/.rite/state/nb-sweep-done-4.txt"
assert_present "prefix が伸びた PR (420) の state を巻き込まない" "$r/.rite/state/nb-sweep-done-420.txt"
assert_present "別 PR (4) の review-results を巻き込まない" "$r/.rite/review-results/4-cycle1.json"
assert_present "prefix が伸びた PR (420) の review-results を巻き込まない" "$r/.rite/review-results/420-cycle1.json"
# 削除の実行報告は stderr（marker と同じストリーム。抽出前と同一）。
assert_contains "削除ごとに ✅ 行を出す" "$out" "✅ nb_sweep_done を削除:"

echo "=== cleanup-pr-state-purge: --dry-run（AC-6）==="

r=$(mktemp -d "$TMP_ROOT/root.XXXXXX"); seed "$r"
out=$(bash "$HELPER" --pr 42 --state-root "$r" --dry-run 2>/dev/null); rc=$?
assert_eq "dry-run: exit 0" "$rc" "0"
assert_present "dry-run: state ファイルを削除しない" "$r/.rite/state/nb-sweep-done-42.txt"
assert_present "dry-run: review-results を削除しない" "$r/.rite/review-results/42-cycle1.json"
assert_contains "dry-run: 対象を stdout に列挙する" "$out" \
  "[DRY-RUN] nb_sweep_done を削除対象として検出: $r/.rite/state/nb-sweep-done-42.txt"
assert_contains "dry-run: review-results も列挙する" "$out" \
  "[DRY-RUN] review_results を退避/削除対象として検出: $r/.rite/review-results/42-cycle1.json"
# positive assert だけでは列挙 glob の prefix 固定を外す変異が生存する（実削除側の
# negative control は AC-5 が持つが、dry-run の報告内容は別に固定しないと守れない）。
# 先頭スラッシュでアンカーし、部分一致 PR (4) と prefix が伸びた PR (420) の両境界を塞ぐ。
assert_not_contains "dry-run: 別 PR の review-results を列挙しない" "$out" \
  "/4-cycle1.json"
assert_not_contains "dry-run: prefix が伸びた PR の review-results を列挙しない" "$out" \
  "/420-cycle1.json"
# `✅ … を削除:` は helper が **stderr** にしか出さない。stdout だけを見る assert は
# どんな実装でも落ちない false positive になるため、両ストリームを結合して照合する。
out_all=$(bash "$HELPER" --pr 42 --state-root "$r" --dry-run 2>&1)
assert_not_contains "dry-run: 削除したと報告しない (stdout+stderr)" "$out_all" "を削除: "

echo "=== cleanup-pr-state-purge: 不正な PR 番号 ==="

# glob が prefix 固定を失うと他 PR を巻き込むため、削除を一切行わず marker で surface する。
# 運用経路なので exit 0（cleanup を止めない）。
r=$(mktemp -d "$TMP_ROOT/root.XXXXXX"); seed "$r"
out=$(bash "$HELPER" --pr "abc" --state-root "$r" 2>&1); rc=$?
assert_eq "非数値 PR: exit 0（非ブロッキング）" "$rc" "0"
assert_contains "非数値 PR: marker を出す" "$out" \
  "[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1; reason=invalid_pr_number"
assert_present "非数値 PR: 何も削除しない" "$r/.rite/state/nb-sweep-done-42.txt"

r=$(mktemp -d "$TMP_ROOT/root.XXXXXX"); seed "$r"
out=$(bash "$HELPER" --pr "" --state-root "$r" 2>&1); rc=$?
assert_eq "空 PR: exit 0" "$rc" "0"
assert_contains "空 PR: marker を出す" "$out" "reason=invalid_pr_number"
assert_present "空 PR: 何も削除しない" "$r/.rite/state/nb-sweep-done-42.txt"

echo "=== cleanup-pr-state-purge: 既定の state-root 解決（本番経路）==="

# 本番 caller (cleanup/SKILL.md ステップ 6) は `--pr` だけを渡し `--state-root` を渡さない。
# 全 TC が `--state-root` を明示すると、helper の既定解決 (state-path-resolve.sh → 失敗時
# cwd fallback) がスイート全体で 1 度も実行されず、本番が通る唯一の経路が未検査になる。
# state-path-resolve.sh は git の toplevel (linked worktree なら main checkout) を返すため、
# 既定解決を通すには temp repo を git repo にして cwd をその中に置く。
r=$(mktemp -d "$TMP_ROOT/root.XXXXXX"); seed "$r"
git -C "$r" init -q
git -C "$r" config user.email test@example.com
git -C "$r" config user.name test
out=$(cd "$r" && bash "$HELPER" --pr 42 2>&1); rc=$?
assert_eq "既定解決: exit 0" "$rc" "0"
assert_absent "既定解決: 解決された root 配下の state を削除する" "$r/.rite/state/nb-sweep-done-42.txt"
assert_present "既定解決: 別 PR の state は残る" "$r/.rite/state/nb-sweep-done-4.txt"

# 上の TC は cwd == 解決先なので「resolver の結果を使っている」ことを判別できない
# (resolver を呼びつつ戻り値を捨てて cwd に倒す変異が素通りする)。linked worktree から呼んで
# cwd ≠ 解決先を作り、main checkout 側の state が消えることまで固定する。これは helper 自身が
# 「セッション worktree に書かれて main checkout の削除が no-op になる不整合を防ぐ」と名指しする
# 本番欠陥そのもの。
r=$(mktemp -d "$TMP_ROOT/root.XXXXXX")
git -C "$r" init -q -b main
git -C "$r" config user.email test@example.com
git -C "$r" config user.name test
echo x > "$r/README.md"
git -C "$r" add README.md
git -C "$r" commit -qm init
git -C "$r" worktree add -q "$r/.rite/worktrees/issue-99" -b feat/x
seed "$r"   # state は main checkout 側にだけ置く
out=$(cd "$r/.rite/worktrees/issue-99" && bash "$HELPER" --pr 42 2>&1); rc=$?
assert_eq "linked worktree: exit 0" "$rc" "0"
assert_absent "linked worktree から呼んでも main checkout 側の state を削除する" \
  "$r/.rite/state/nb-sweep-done-42.txt"
assert_present "linked worktree: 別 PR の state は残る" "$r/.rite/state/nb-sweep-done-4.txt"

# state root を解決できない環境では WARNING を出して cwd へ倒す（silent に no-op しない）。
# state-path-resolve.sh を欠いた stub plugin root から helper を呼んで再現する。
r=$(mktemp -d "$TMP_ROOT/root.XXXXXX"); seed "$r"
stub_root=$(mktemp -d "$TMP_ROOT/stubroot.XXXXXX")
mkdir -p "$stub_root/hooks/scripts"
cp "$HELPER" "$stub_root/hooks/scripts/"
# archive helper は依存ごと持ち込む。gitignore-ensure.sh を欠くと source 失敗のまま続行し
# (helper は -e を張らない)、review-results を 1 件も処理しないまま exit 0 する — この
# レッグを「検証したつもり」で素通りさせる。コピー元は常在するので失敗は fail-loud にする。
cp "$SCRIPT_DIR/../scripts/review-results-archive-or-rm.sh" "$stub_root/hooks/scripts/"
cp "$SCRIPT_DIR/../gitignore-ensure.sh" "$stub_root/hooks/"
# state-path-resolve.sh は意図的に置かない → 解決失敗 → cwd fallback
out=$(cd "$r" && bash "$stub_root/hooks/scripts/cleanup-pr-state-purge.sh" --pr 42 2>&1); rc=$?
assert_eq "state root 解決失敗: exit 0（非ブロッキング）" "$rc" "0"
assert_contains "state root 解決失敗: WARNING を出す" "$out" "state-path-resolve.sh の解決に失敗"
assert_absent "state root 解決失敗: cwd を root として削除する" "$r/.rite/state/nb-sweep-done-42.txt"
assert_absent "state root 解決失敗: cwd 配下の review-results も処理される" \
  "$r/.rite/review-results/42-cycle1.json"

echo "=== cleanup-pr-state-purge: 対象なし / helper 失敗 ==="

# 対象が 1 件も無くても失敗にしない（cleanup 再実行の冪等性）。
r=$(mktemp -d "$TMP_ROOT/root.XXXXXX"); mkdir -p "$r/.rite/state"
out=$(bash "$HELPER" --pr 999999 --state-root "$r" 2>&1); rc=$?
assert_eq "対象なし: exit 0" "$rc" "0"
assert_not_contains "対象なし: 失敗 marker を出さない" "$out" "REVIEW_CLEANUP_PARTIAL_FAILURE"

# archive helper が起動できない場合、marker 不在を「削除成功」と読ませない（rc を marker へ変換）。
r=$(mktemp -d "$TMP_ROOT/root.XXXXXX"); seed "$r"
stub_dir=$(mktemp -d "$TMP_ROOT/stub.XXXXXX")
mkdir -p "$stub_dir/hooks/scripts"
cp "$HELPER" "$stub_dir/hooks/scripts/"
cp "$SCRIPT_DIR/../state-path-resolve.sh" "$stub_dir/hooks/" 2>/dev/null || true
# review-results-archive-or-rm.sh は意図的に置かない → rc=127
out=$(bash "$stub_dir/hooks/scripts/cleanup-pr-state-purge.sh" --pr 42 --state-root "$r" 2>&1); rc=$?
assert_eq "archive helper 不在: exit 0（非ブロッキング）" "$rc" "0"
assert_contains "archive helper 不在: 失敗を marker へ変換する" "$out" \
  "[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1; reason=review_results_helper_failed; pr=42; rc=127"
assert_present "archive helper 不在: review-results は未処理のまま残る" "$r/.rite/review-results/42-cycle1.json"
assert_absent "archive helper 不在でも rite_rm は続行する" "$r/.rite/state/nb-sweep-done-42.txt"

echo "=== cleanup-pr-state-purge: usage ==="

# `--pr` 欠落は空値 = 不正な PR 番号として扱う（usage error にしない）。抽出前のインライン bash も
# 空値を `invalid_pr_number` marker + exit 0 で surface していた経路で、振る舞いを変えない。
r=$(mktemp -d "$TMP_ROOT/root.XXXXXX"); seed "$r"
out=$(bash "$HELPER" --state-root "$r" 2>&1); rc=$?
assert_eq "--pr 欠落は非ブロッキングで exit 0" "$rc" "0"
assert_contains "--pr 欠落は invalid_pr_number として surface する" "$out" "reason=invalid_pr_number"
assert_present "--pr 欠落では何も削除しない" "$r/.rite/state/nb-sweep-done-42.txt"
bash "$HELPER" --pr 42 --bogus x >/dev/null 2>&1; rc=$?
assert_eq "未知のオプションは usage error" "$rc" "2"

echo "PASS: $pass"
echo "FAIL: $fail"
[ "$fail" -eq 0 ]
