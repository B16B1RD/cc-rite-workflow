#!/bin/bash
# Canonical write schema と reader accept list の parity を固定する。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PR_REVIEW="$PLUGIN_DIR/skills/pr-review/SKILL.md"
SCHEMA="$PLUGIN_DIR/references/review-result-schema.md"
SOURCE_RESOLVE="$PLUGIN_DIR/scripts/review-source-resolve.sh"
FIX="$PLUGIN_DIR/skills/fix/SKILL.md"
TREND="$PLUGIN_DIR/hooks/scripts/review-trend-divergence.sh"

PASS=0
FAIL=0

assert_count() {
  local name="$1" expected="$2" pattern="$3" file="$4" actual
  actual=$(LC_ALL=C grep -cF -- "$pattern" "$file" || true)
  if [ "$actual" = "$expected" ]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected=$expected actual=$actual)"
    FAIL=$((FAIL + 1))
  fi
}

assert_count "pr-review requires canonical write schema 1.1.0 once" 1 \
  'Required JSON fields: `schema_version: "1.1.0"`' "$PR_REVIEW"
assert_count "pr-review no longer requires write schema 1.0.0" 0 \
  'Required JSON fields: `schema_version: "1.0.0"`' "$PR_REVIEW"
assert_count "schema SoT declares canonical 1.1.0 writer" 1 \
  'ステップ 6.1.a — canonical `"1.1.0"` のみを出力する' "$SCHEMA"
assert_count "schema SoT names the reader parity regression test" 1 \
  '`plugins/rite/hooks/tests/review-schema-write-version-parity.test.sh` が 4 箇所の accept list' "$SCHEMA"
assert_count "invariant 6 documents helper evidence and preset residual path" 1 \
  '`computed_verification` が `measured: true` を設定するとき、検出したアンカーから必ず `repro` または `failing_test` の片方を同時に設定する' "$SCHEMA"
assert_count "invariant 6 removes obsolete no-verification premise" 0 \
  'write 側が `verification` を出力しないため auto-correct' "$SCHEMA"
assert_count "schema table marks pre_existing optional" 1 \
  '| `pre_existing` | bool | (任意、1.1.0+) |' "$SCHEMA"
assert_count "legacy mapping applies only to scope and preserves missing pre_existing" 1 \
  'default mapping を適用するのは **`scope` のみ**で、`pre_existing` は欠落のまま保持し Cross-field invariant #5 を発火させない' "$SCHEMA"
assert_count "generation rules couple canonical 1.1.0 with pre_existing omission" 1 \
  'pre_existing` は書かない** — canonical `schema_version: "1.1.0"`' "$PR_REVIEW"
assert_count "required-field list explicitly omits pre_existing" 1 \
  '`pre_existing`: **出力しない**' "$PR_REVIEW"

# Reader は引き続き legacy 2 値 + canonical 1.1.0 の3値を受理する。write bump で
# accept listを狭めたり増やしたりしない。
accept='"1.0.0"|"1.0"|"1.1.0"'
assert_count "review-source-resolve keeps two reader accept sites" 2 "$accept" "$SOURCE_RESOLVE"
assert_count "fix keeps one reader accept site" 1 "$accept" "$FIX"
assert_count "trend keeps one reader accept site" 1 "$accept" "$TREND"

echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
