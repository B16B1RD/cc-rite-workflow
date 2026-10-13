#!/bin/bash
# review-converging.test.sh
#
# 上限 (safety.max_review_cycles) 到達時に止めない「収束中」判定の境界を固定する。
# 収束中 = 直近 3 値が狭義単調減少 かつ 最新 cycle の findings_new_from_fix が 0。
# 収束中は yes (上限で止めない)、非収束・判定不能は no (従来どおり上限で止める)。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
HELPER="$PLUGIN_ROOT/hooks/scripts/review-converging.sh"
ITERATE_STEP="$PLUGIN_ROOT/scripts/iterate-step.sh"
STAGNATION="$PLUGIN_ROOT/hooks/scripts/lib/review-stagnation.py"

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

# fix_state <new_from_fix...> — 計測済み (findings_total あり) の cycles[] を順に持つ fix-cycle-state を作る
fix_state() {
  local f="$TEST_DIR/fix-state.json"
  printf '%s\n' "$@" | jq -s '{cycles: map({findings_total: 1, findings_new_from_fix: .})}' > "$f"
  printf '%s' "$f"
}

verdict() { # <trend> <fix-state-path>
  bash "$HELPER" --pr 1 --trend "$1" --fix-state "$2" 2>/dev/null
}

# out_has <label> <pattern> — 直前の OUT に pattern があること
out_has() { printf '%s\n' "$OUT" > "$TEST_DIR/out.txt"; assert_grep "$1" "$TEST_DIR/out.txt" "$2"; }

echo "=== T-01: 収束中は上限で止めない ==="
OUT=$(verdict "9,6,3" "$(fix_state 2 0)")
out_has "T-01a: 直近 3 値が狭義減少かつ fix 由来 0 は yes" "REVIEW_CONVERGING=yes"
OUT=$(verdict "20,12,10,9,7,4" "$(fix_state 0 0)")
out_has "T-01b: 長い列でも直近 3 値で判定し yes" "REVIEW_CONVERGING=yes"

echo "=== T-02: 非収束は上限で止める ==="
OUT=$(verdict "9,6,3" "$(fix_state 0 1)")
out_has "T-02a: fix 由来の新規指摘 が 1 件でも no" "REVIEW_CONVERGING=no; reason=fix_introduced_findings"
OUT=$(verdict "9,6,6" "$(fix_state 0)")
out_has "T-02b: 直近で足踏みなら no" "reason=not_descending"
OUT=$(verdict "9,3,6" "$(fix_state 0)")
out_has "T-02c: 直近で反転上昇なら no" "reason=not_descending"
OUT=$(verdict "9,9,6" "$(fix_state 0)")
out_has "T-02d: 2 cycle 連続の減少でなければ no (減少が 1 回のみ)" "reason=not_descending"
OUT=$(verdict "6,3" "$(fix_state 0)")
out_has "T-02e: 2 値以下は判定不能で no" "reason=need_3_cycles"

OUT=$(verdict "3,2,1,5,4,6" "$(fix_state 0)")
out_has "T-02f: 先頭 3 値が減少でも直近 3 値が足踏み・上昇なら no (変異: 先頭 3 値で判定)" "reason=not_descending"
OUT=$(verdict "1,5,4,3" "$(fix_state 0)")
out_has "T-02g: 先頭が上昇でも直近 3 値が減少なら yes" "REVIEW_CONVERGING=yes"

echo "=== T-03: 判定不能は no (silent にしない) ==="
OUT=$(bash "$HELPER" --pr 1 --trend "9,6,3" --fix-state "$TEST_DIR/none.json" 2>"$TEST_DIR/err.txt")
out_has "T-03a: fix-cycle-state 不在は no" "reason=fix_state_missing"
assert_grep "T-03a: 不在は WARNING を残す" "$TEST_DIR/err.txt" "WARNING"
echo '{"cycles":[{"findings_total":1,"findings_new_from_fix":"x"}]}' > "$TEST_DIR/bad.json"
OUT=$(verdict "9,6,3" "$TEST_DIR/bad.json")
out_has "T-03b: findings_new_from_fix が非整数なら no" "reason=fix_state_unreadable"
OUT=$(bash "$HELPER" --pr 1 --trend "9,x,3" --fix-state "$(fix_state 0)" 2>"$TEST_DIR/err.txt")
out_has "T-03c: 列が不正なら no" "reason=trend_malformed"
assert_grep "T-03c: 列不正は WARNING を残す" "$TEST_DIR/err.txt" "WARNING"
# fix は cycle 追加時に findings_new_from_fix=0 を置く。findings_total の無い entry は未計測で読まない。
echo '{"cycles":[{"findings_new_from_fix":0}]}' > "$TEST_DIR/unmeasured.json"
OUT=$(verdict "9,6,3" "$TEST_DIR/unmeasured.json")
out_has "T-03d: 初期値 0 だけの state は未計測で no" "reason=fix_state_unmeasured"
# 最新の計測済み entry を読む (後ろに未計測の entry があっても無視)
echo '{"cycles":[{"findings_total":4,"findings_new_from_fix":2},{"findings_total":3,"findings_new_from_fix":0},{"findings_new_from_fix":0}]}' > "$TEST_DIR/tail-unmeasured.json"
OUT=$(verdict "9,6,3" "$TEST_DIR/tail-unmeasured.json")
out_has "T-03e: 最新の計測済み entry (0) を読み yes" "REVIEW_CONVERGING=yes"
echo '{"cycles":[{"findings_total":4,"findings_new_from_fix":0},{"findings_total":3,"findings_new_from_fix":2},{"findings_new_from_fix":0}]}' > "$TEST_DIR/tail-unmeasured2.json"
OUT=$(verdict "9,6,3" "$TEST_DIR/tail-unmeasured2.json")
out_has "T-03f: 最新の計測済み entry (2) を読み no" "reason=fix_introduced_findings"
# 既定パス: --fix-state なしで state root から解決する (本番の呼び出し形)
mkdir -p "$TEST_DIR/root/.rite/fix-cycle-state" && git -C "$TEST_DIR/root" init -q
cp "$TEST_DIR/tail-unmeasured.json" "$TEST_DIR/root/.rite/fix-cycle-state/5.json"
OUT=$(cd "$TEST_DIR/root" && bash "$HELPER" --pr 5 --trend "9,6,3" 2>/dev/null)
out_has "T-03g: --fix-state なしでも state root の既定パスを読む" "REVIEW_CONVERGING=yes"
# 値の無い引数は無限ループせず rc=2 で終わる
# timeout(1) は macOS に無いので、バックグラウンド実行 + 5 秒後の kill で打ち切る (打ち切られると rc=143)
bash "$HELPER" --pr 1 --trend >/dev/null 2>&1 &
helper_pid=$!
( sleep 5; kill "$helper_pid" 2>/dev/null ) &
killer_pid=$!
wait "$helper_pid"; rc=$?
kill "$killer_pid" 2>/dev/null; wait "$killer_pid" 2>/dev/null
assert "T-03h: 値の無い --trend は rc=2 (無限ループしない)" "2" "$rc"

echo "=== T-04: 呼び出し側が判定を使っている ==="
assert_grep "T-04a: iterate-step.sh が上限判定で helper を呼ぶ" "$ITERATE_STEP" 'review-converging\.sh'
assert_grep "T-04b: review-stagnation.py が上限判定で helper を呼ぶ" "$STAGNATION" 'review-converging\.sh'

print_summary "review-converging"
