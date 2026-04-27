#!/bin/bash
# Caller markdown source-pin metatest (PR #688 verified-review cycle 39 G-01 / G-02 対応)
#
# Purpose:
#   commands/issue/start.md / commands/issue/implement.md / commands/pr/review.md 内に
#   含まれる state-read.sh 呼出 caller bash block について、以下を grep ベースで pin する:
#
#   G-01 (type validation pin):
#     parent_issue_number / loop_count を読む caller 3 箇所が `case "$X" in ''|*[!0-9]*) ... esac`
#     形式の type validation を持つことを確認する。validation を将来 revert / 削除した場合に
#     test が落ちて気付ける source-pin。
#
#   G-02 (`if !` anti-pattern revert 検出):
#     caller 6 箇所すべてが canonical `if cmd; then :; else rc=$?; fi` pattern を使い、
#     cycle 35 F-04 で empirical に bash spec 違反 ($? が常に rc=0) と判明した
#     `if ! var=$(bash {plugin_root}/hooks/state-read.sh ...)` 形式に revert されないことを pin する。
#     revert された場合 Issue #687 同型の silent regression を再導入するため fail-fast で検出する。
#
# Background:
#   Phase 1.2.0 / Phase 5 の caller markdown 内の inline bash block は run-tests.sh の通常テスト
#   対象ではない (markdown を grep するメタテスト)。手動レビュー依存だった部分を機械化する。
#
# Caller sites covered (6 箇所):
#   - commands/issue/start.md (4 箇所): Phase 3 / 5.5.1 / 5.6 (phase) + Phase 5.7 (parent_issue_number)
#   - commands/issue/implement.md (1 箇所): Phase 5.1.2 (parent_issue_number)
#   - commands/pr/review.md (1 箇所): Phase 5.3.8 (loop_count)
#
# Type validation only applies to numeric fields (parent_issue_number / loop_count).
# `phase` は文字列のため type validation は不要 (3 箇所は本テストの type validation 対象外)。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMMANDS_DIR="$PLUGIN_ROOT/commands"

PASS=0
FAIL=0

assert() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  ✅ PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  ❌ FAIL: $label (expected='$expected' actual='$actual')"
    FAIL=$((FAIL + 1))
  fi
}

assert_grep() {
  local label="$1"
  local file="$2"
  local pattern="$3"
  if grep -qE "$pattern" "$file"; then
    echo "  ✅ PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  ❌ FAIL: $label (pattern not found in $file: $pattern)"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_grep() {
  local label="$1"
  local file="$2"
  local pattern="$3"
  if grep -qE "$pattern" "$file"; then
    echo "  ❌ FAIL: $label (anti-pattern found in $file: $pattern)"
    FAIL=$((FAIL + 1))
  else
    echo "  ✅ PASS: $label"
    PASS=$((PASS + 1))
  fi
}

START_MD="$COMMANDS_DIR/issue/start.md"
IMPLEMENT_MD="$COMMANDS_DIR/issue/implement.md"
REVIEW_MD="$COMMANDS_DIR/pr/review.md"

# === Test 1: caller bash block の存在確認 (regression 対策の前提) ===
echo "TC-1: state-read.sh 呼出 caller bash block の存在確認"

# start.md は 4 箇所
start_count=$(grep -cE '^if [a-z_]+=\$\(bash \{plugin_root\}/hooks/state-read\.sh' "$START_MD" || echo 0)
assert "TC-1.1: start.md の caller bash block は 4 箇所" "4" "$start_count"

# implement.md は 1 箇所
implement_count=$(grep -cE '^if [a-z_]+=\$\(bash \{plugin_root\}/hooks/state-read\.sh' "$IMPLEMENT_MD" || echo 0)
assert "TC-1.2: implement.md の caller bash block は 1 箇所" "1" "$implement_count"

# review.md は 1 箇所
review_count=$(grep -cE '^if [a-z_]+=\$\(bash \{plugin_root\}/hooks/state-read\.sh' "$REVIEW_MD" || echo 0)
assert "TC-1.3: review.md の caller bash block は 1 箇所" "1" "$review_count"

# === Test 2: G-02 — `if !` anti-pattern revert 検出 ===
# cycle 35 F-04 で empirical に bash spec 違反と判明した形式が caller markdown に revert されないこと。
# 該当行: `if ! var=$(bash {plugin_root}/hooks/state-read.sh ...)`
echo ""
echo "TC-2: G-02 — \`if !\` anti-pattern (cycle 35 F-04 revert) が caller markdown に存在しないこと"

assert_not_grep "TC-2.1: start.md に \`if !\` state-read.sh anti-pattern が存在しない" \
  "$START_MD" \
  'if !\s+[a-z_]+=\$\(bash\s+\{plugin_root\}/hooks/state-read\.sh'

assert_not_grep "TC-2.2: implement.md に \`if !\` state-read.sh anti-pattern が存在しない" \
  "$IMPLEMENT_MD" \
  'if !\s+[a-z_]+=\$\(bash\s+\{plugin_root\}/hooks/state-read\.sh'

assert_not_grep "TC-2.3: review.md に \`if !\` state-read.sh anti-pattern が存在しない" \
  "$REVIEW_MD" \
  'if !\s+[a-z_]+=\$\(bash\s+\{plugin_root\}/hooks/state-read\.sh'

# === Test 3: G-02 — canonical pattern の存在確認 ===
echo ""
echo "TC-3: G-02 — canonical \`if cmd; then :; else rc=\$?; fi\` pattern の存在確認"

# canonical 直後 (else 節) に `rc=$?` を持つこと
# (start.md は phase / parent_issue_number で 4 箇所すべて、implement.md は 1 箇所、review.md は 1 箇所)
start_canonical=$(grep -cE 'if [a-z_]+=\$\(bash \{plugin_root\}/hooks/state-read\.sh.*then$' "$START_MD" || echo 0)
assert "TC-3.1: start.md の canonical pattern (4 箇所) が存続" "4" "$start_canonical"

implement_canonical=$(grep -cE 'if [a-z_]+=\$\(bash \{plugin_root\}/hooks/state-read\.sh.*then$' "$IMPLEMENT_MD" || echo 0)
assert "TC-3.2: implement.md の canonical pattern (1 箇所) が存続" "1" "$implement_canonical"

review_canonical=$(grep -cE 'if [a-z_]+=\$\(bash \{plugin_root\}/hooks/state-read\.sh.*then$' "$REVIEW_MD" || echo 0)
assert "TC-3.3: review.md の canonical pattern (1 箇所) が存続" "1" "$review_canonical"

# === Test 4: G-01 — type validation pin (numeric field のみ対象) ===
# parent_issue_number / loop_count を読む caller 直後に
# `case "$X" in` (line N) + `  ''|*[!0-9]*)` (line N+1) の 2-line pattern が存在することを pin する。
# silent regression: validation 削除や `[!0-9]` パターン破損で shell injection 経路が無防備化する。
# grep -A 1 で `case "$X" in` の次行を取得し、それが `''|*[!0-9]*)` を含むかを別 grep で確認する。
echo ""
echo "TC-4: G-01 — type validation case 文の pin (parent_issue_number / loop_count)"

assert_2line_validation() {
  local label="$1"
  local file="$2"
  local var_name="$3"
  # case "$VAR" in の次行 (within 1 line) に `''|*[!0-9]*)` を持つことを pin
  local next_line
  next_line=$(grep -A 1 "case \"\\\$${var_name}\" in\$" "$file" | grep -E "^\s*''\|\*\[!0-9\]\*\)" || true)
  if [ -n "$next_line" ]; then
    echo "  ✅ PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  ❌ FAIL: $label (case \"\$${var_name}\" in の直後行に \`''|*[!0-9]*)\` が存在しない: $file)"
    FAIL=$((FAIL + 1))
  fi
}

# start.md Phase 5.7: parent_issue_number
assert_2line_validation "TC-4.1: start.md に parent_issue_number の type validation pattern が存在" \
  "$START_MD" "parent_issue_number"

# implement.md Phase 5.1.2: parent_issue_number
assert_2line_validation "TC-4.2: implement.md に parent_issue_number の type validation pattern が存在" \
  "$IMPLEMENT_MD" "parent_issue_number"

# review.md Phase 5.3.8: loop_count
assert_2line_validation "TC-4.3: review.md に loop_count の type validation pattern が存在" \
  "$REVIEW_MD" "loop_count"

# === Test 5: type validation の defaulting 動作 pin ===
# validation がマッチした場合に変数を 0 (parent_issue_number / loop_count) または "" (phase) に降格すること。
# silent regression: validation 後に `default=999` 等にすり替わると後続の比較が壊れる。
echo ""
echo "TC-5: type validation の default 値 pin (numeric field は 0 に降格)"

assert_grep "TC-5.1: start.md の parent_issue_number validation が default 0 に降格する" \
  "$START_MD" \
  'parent_issue_number=0'

assert_grep "TC-5.2: implement.md の parent_issue_number validation が default 0 に降格する" \
  "$IMPLEMENT_MD" \
  'parent_issue_number=0'

assert_grep "TC-5.3: review.md の loop_count validation が default 0 に降格する" \
  "$REVIEW_MD" \
  'loop_count=0'

# === Summary ===
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
