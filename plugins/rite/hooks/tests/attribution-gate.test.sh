#!/bin/bash
# attribution-gate.test.sh
#
# fix 後の再レビューかを fix-cycle-state の cycle 記録で判定する (flow-state の loop_count には依存しない)。
# 記録が無ければ初回 review として skip し、あれば帰属の分類へ進む (skip 行を出さない)。

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

echo '{"cycles":[{"findings_new_from_fix":0}]}' > "$TEST_DIR/.rite/fix-cycle-state/9.json"
OUT=$(gate)
printf '%s\n' "$OUT" > "$TEST_DIR/out.txt"
assert_not_grep "T-03: fix cycle 記録があれば skip しない (loop_count 不要)" "$TEST_DIR/out.txt" "FINDING_ATTRIBUTION skip"

echo 'not json' > "$TEST_DIR/.rite/fix-cycle-state/9.json"
OUT=$(gate)
out_has "T-04: state が壊れていれば黙って skip せずエラーにする" "ERROR"

print_summary "attribution-gate"
