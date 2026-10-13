#!/bin/bash
# attribution-gate.test.sh
#
# fix 後の再レビューかを fix-cycle-state の最新 entry が未計測か (findings_total 無し) で判定する
# (flow-state の loop_count には依存しない)。破損 state (非 JSON / 0 バイト / cycles が配列でない / 最新 entry が object でない) は ERROR (T-04〜T-07)。state 無し・entry 無し・最新が計測済みは skip し、未計測なら進む。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
STEP="$PLUGIN_ROOT/scripts/pr-review-step.sh"

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
git -C "$TEST_DIR" init -q
mkdir -p "$TEST_DIR/.rite/fix-cycle-state"

gate() { (cd "$TEST_DIR" && bash "$STEP" attribution-gate --pr 9 2>&1); }
out_has() { printf '%s\n' "$OUT" > "$TEST_DIR/out.txt"; assert_grep "$1" "$TEST_DIR/out.txt" "$2"; }

OUT=$(gate)
out_has "T-01: fix-cycle-state が無ければ初回 review として skip" "FINDING_ATTRIBUTION skip"

echo '{"cycles":[]}' > "$TEST_DIR/.rite/fix-cycle-state/9.json"
OUT=$(gate)
out_has "T-02: cycle 記録が 0 件なら skip" "FINDING_ATTRIBUTION skip"

echo '{"cycles":[{"findings_total":2,"findings_new_from_fix":0},{"findings_new_from_fix":0}]}' > "$TEST_DIR/.rite/fix-cycle-state/9.json"
OUT=$(gate); rc=$?
printf '%s\n' "$OUT" > "$TEST_DIR/out.txt"
assert_not_grep "T-03: 最新 entry が未計測 (fix 直後の review) なら skip しない (loop_count 不要)" "$TEST_DIR/out.txt" "FINDING_ATTRIBUTION skip"
assert_not_grep "T-03: 進む場合に ERROR を出さない" "$TEST_DIR/out.txt" "ERROR"
assert "T-03: 進む場合の終了コードは 0" "0" "$rc"

# 最新 entry が計測済み (前 run の残り) なら新しい run の初回 review として skip する
echo '{"cycles":[{"findings_total":2,"findings_new_from_fix":0}]}' > "$TEST_DIR/.rite/fix-cycle-state/9.json"
OUT=$(gate)
out_has "T-03b: 最新 entry が計測済みなら skip (前 run の残りを上書きしない)" "FINDING_ATTRIBUTION skip"

echo 'not json' > "$TEST_DIR/.rite/fix-cycle-state/9.json"
OUT=$(gate)
out_has "T-04: state が壊れていれば黙って skip せずエラーにする" "ERROR"
for bad in '{"cycles":"abc"}' '{"cycles":{}}' '{"cycles":null}'; do
  echo "$bad" > "$TEST_DIR/.rite/fix-cycle-state/9.json"
  OUT=$(gate)
  out_has "T-05: cycles が配列でなければエラー ($bad)" "ERROR"
done

: > "$TEST_DIR/.rite/fix-cycle-state/9.json"
OUT=$(gate)
out_has "T-06: 0 バイトの state は黙って skip せずエラーにする" "ERROR"

for bad in '{"cycles":[null]}' '{"cycles":[{"findings_total":1},"x"]}' '{"cycles":[1]}'; do
  echo "$bad" > "$TEST_DIR/.rite/fix-cycle-state/9.json"
  OUT=$(gate)
  out_has "T-07: 最新 entry が object でなければエラー ($bad)" "ERROR"
done

print_summary "attribution-gate"
