#!/bin/bash
# review-converging-chain.test.sh
#
# 書き手 (fix-step skip-cycle-state / pr-review-step attribution-write) から読み手
# (attribution-gate / review-converging.sh) までを、手書き JSON ではなく実際の書き込みでつなぐ。
# あわせて review-stagnation.py の converging() が helper の失敗・無出力を「延長しない」側へ倒すことを確かめる。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
FIX_STEP="$PLUGIN_ROOT/scripts/fix-step.sh"
REVIEW_STEP="$PLUGIN_ROOT/scripts/pr-review-step.sh"
HELPER="$PLUGIN_ROOT/hooks/scripts/review-converging.sh"

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
git -C "$TEST_DIR" init -q
git -C "$TEST_DIR" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
echo '[]' > "$TEST_DIR/addressed.json"

in_repo() { (cd "$TEST_DIR" && "$@" 2>&1); }
fix_cycle() { in_repo bash "$FIX_STEP" skip-cycle-state --pr 9 --findings-addressed-file "$TEST_DIR/addressed.json" --non-fatal-moved-count 0 --triage-review-path /dev/null; }
gate() { in_repo bash "$REVIEW_STEP" attribution-gate --pr 9; }
write() { in_repo bash "$REVIEW_STEP" attribution-write --pr 9 --total "$1" --fix-introduced "$2" --critical 0 --high 0 --medium 0 --low-medium 0 --low 0; }
converging() { in_repo bash "$HELPER" --pr 9 --trend "$1" ${2:+--max-trailing "$2"}; }
has() { printf '%s\n' "$OUT" > "$TEST_DIR/out.txt"; assert_grep "$1" "$TEST_DIR/out.txt" "$2"; }

# fix → review の 1 周: fix が entry を足し、gate は進み、attribution-write が計測値を書く
fix_cycle >/dev/null
OUT=$(gate); printf '%s\n' "$OUT" > "$TEST_DIR/out.txt"
assert_not_grep "T-01: fix 直後の review では gate が進む" "$TEST_DIR/out.txt" "FINDING_ATTRIBUTION skip"
OUT=$(converging 9,6,3)
has "T-02: 未計測の初期値 0 だけでは延長しない" "REVIEW_CONVERGING=no; reason=fix_state_unmeasured"

write 3 0 >/dev/null
OUT=$(gate)
has "T-03: 帰属を書いた後の gate は skip (計測済み entry を上書きしない)" "FINDING_ATTRIBUTION skip"
OUT=$(converging 9,6,3)
has "T-04: 書かれた fix 由来 0 件の計測値で延長する" "REVIEW_CONVERGING=yes; reason=descending_without_fix_regressions"

# 次の fix 直後 (cycle-gate): 未計測 entry が 1 件までは直前の計測値で判定できる。review 完了直後 (max-trailing 0) では判定しない
fix_cycle >/dev/null
OUT=$(converging 9,6,3)
has "T-05: fix 直後 (trailing=1) は直前の計測値で延長する" "REVIEW_CONVERGING=yes"
OUT=$(converging 9,6,3 0)
has "T-06: review 完了直後に呼ぶ側 (--max-trailing 0) は計測が抜けたものとして延長しない" "reason=fix_state_stale"

# 書き込みが抜けて fix だけが積まれた場合
fix_cycle >/dev/null
OUT=$(converging 9,6,3)
has "T-07: 帰属の書き込みを 1 回飛ばすと古い計測値で延長しない" "reason=fix_state_stale"

# fix 由来の新規指摘が 1 件ある計測
write 3 1 >/dev/null
OUT=$(converging 9,6,3)
has "T-08: 書かれた fix 由来 1 件で延長しない" "reason=fix_introduced_findings"

OUT=$(converging 9,6,3 2); rc=$?
has "T-08b: --max-trailing は 0 か 1 のみ (2 は呼び出しエラー)" "ERROR"

# python 側: helper が失敗・無出力でも延長せず理由を返す (fail-open に倒さない)
STUB="$TEST_DIR/stub"
cp -r "$PLUGIN_ROOT/hooks/scripts" "$STUB"
run_converging() {
  python3 - "$STUB" <<'PY' 2>&1
import importlib.util, sys
stub = sys.argv[1]
sys.argv = ["x"]
sys.path.insert(0, stub + "/lib")
spec = importlib.util.spec_from_file_location("rs", stub + "/lib/review-stagnation.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print("RESULT", module.converging({"pr_number": 9}, {"trend": "3,2,1"}))
PY
}
printf '#!/bin/bash\nexit 2\n' > "$STUB/review-converging.sh"
OUT=$(run_converging)
has "T-09: helper が rc≠0 なら延長せず helper_failed" "RESULT .*False.*helper_failed"
has "T-09: WARNING を stderr に出す" "WARNING: convergence check could not run"
printf '#!/bin/bash\nexit 0\n' > "$STUB/review-converging.sh"
OUT=$(run_converging)
has "T-10: helper が verdict を出さなければ延長せず helper_no_marker" "RESULT .*False.*helper_no_marker"
printf '#!/bin/bash\necho "[CONTEXT] REVIEW_CONVERGING=yes; reason=descending_without_fix_regressions"\n' > "$STUB/review-converging.sh"
OUT=$(run_converging)
has "T-11: verdict が yes なら延長する" "RESULT .*True.*descending_without_fix_regressions"

print_summary "review-converging-chain"
