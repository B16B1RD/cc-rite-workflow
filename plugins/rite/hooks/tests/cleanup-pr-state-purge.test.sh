#!/usr/bin/env bash
# cleanup-pr-state-purge.sh の単体テスト（Issue #2492 T-05 / T-06）。
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
assert_not_contains "dry-run: 削除したと報告しない" "$out" "を削除: "

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
