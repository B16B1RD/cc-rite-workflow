#!/bin/bash
# Tests for _resolve-session-id.sh (PR #688 cycle 13 F-03 対応)
#
# Purpose:
#   PR #688 cycle 12 F-03 の指摘により、`_resolve-session-id.sh:38-46` の UUID
#   validation helper には direct test がない。cycle 44 F-10 で導入された
#   case-insensitive accept + lowercase normalize 動作 (`tr 'A-F' 'a-f'`) は
#   caller (state-read.sh) の TC-6.INJECTION (uppercase / mixed_case vectors)
#   経由で indirect カバーされるが、normalize 部分 (uppercase 入力 → lowercase 出力)
#   を直接 assert する test がない。`tr 'A-F' 'a-f'` を `cat` に mutate しても
#   全 caller TC が pass する経路があった (caller が path-not-exist で legacy fallback
#   するため、normalized path の検証ができない false-negative)。
#
# Test cases:
#   TC-1 (valid lowercase): canonical UUID → exit 0 + 同一 lowercase stdout
#   TC-2 (case normalize, UPPERCASE): UPPERCASE UUID → exit 0 + 完全 lowercase stdout
#   TC-3 (case normalize, mixed_case): mixed_case → exit 0 + 完全 lowercase stdout
#   TC-4 (invalid, too_short): 8 文字未満 → exit 1 + empty stdout
#   TC-5 (invalid, hyphen position): 8-3-4-4-12 (3 文字 group) → exit 1
#   TC-6 (invalid, non_hex): hex 範囲外文字 (g-z) → exit 1
#   TC-7 (invalid, shell metachar): UUID 形式に shell metachar 混入 → exit 1
#   TC-8 (invalid, empty): 空文字列 → exit 1 + empty stdout
#   TC-9 (invalid, no_arg): 引数なし → exit 1 + empty stdout
#   TC-10 (boundary, all_zeros): 00000000-0000-0000-0000-000000000000 → exit 0 (valid)
#   TC-11 (boundary, all_fs lowercase): ffffffff-ffff-ffff-ffff-ffffffffffff → exit 0 (valid)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$HOOKS_DIR/_resolve-session-id.sh"

PASS=0
FAIL=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  ✅ $label"
    PASS=$((PASS + 1))
  else
    echo "  ❌ $label"
    echo "     Expected: $expected"
    echo "     Actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

# helper を 1 引数で呼んで (out, rc) を取得
run_helper() {
  local arg="$1"
  out=$(bash "$HELPER" "$arg" 2>&1) && rc=0 || rc=$?
}

# ================================================================
echo "TC-1 (valid lowercase): canonical UUID → exit 0 + 同一 lowercase stdout"
# ================================================================
run_helper "550e8400-e29b-41d4-a716-446655440000"
assert_eq "TC-1.1: exit code is 0" "0" "$rc"
assert_eq "TC-1.2: stdout is same lowercase UUID" "550e8400-e29b-41d4-a716-446655440000" "$out"

# ================================================================
echo "TC-2 (case normalize, UPPERCASE): UPPERCASE UUID → exit 0 + 完全 lowercase"
# ================================================================
run_helper "550E8400-E29B-41D4-A716-446655440000"
assert_eq "TC-2.1: exit code is 0 (case-insensitive accept)" "0" "$rc"
assert_eq "TC-2.2: UPPERCASE は完全 lowercase に正規化される" "550e8400-e29b-41d4-a716-446655440000" "$out"

# ================================================================
echo "TC-3 (case normalize, mixed_case): mixed_case → exit 0 + 完全 lowercase"
# ================================================================
run_helper "550E8400-e29b-41D4-a716-446655440000"
assert_eq "TC-3.1: exit code is 0" "0" "$rc"
assert_eq "TC-3.2: mixed_case は完全 lowercase に正規化される" "550e8400-e29b-41d4-a716-446655440000" "$out"

# ================================================================
echo "TC-4 (invalid, too_short): 8 文字未満 → exit 1"
# ================================================================
run_helper "550e84-e29b-41d4-a716-446655440000"
assert_eq "TC-4.1: exit code is 1" "1" "$rc"
assert_eq "TC-4.2: stdout is empty" "" "$out"

# ================================================================
echo "TC-5 (invalid, hyphen position): 8-3-4-4-12 (group 短縮) → exit 1"
# ================================================================
# 2 番目の group が 3 文字
run_helper "550e8400-e29-41d4-a716-446655440000"
assert_eq "TC-5.1: exit code is 1" "1" "$rc"
assert_eq "TC-5.2: stdout is empty" "" "$out"

# ================================================================
echo "TC-6 (invalid, non_hex): hex 範囲外文字 → exit 1"
# ================================================================
run_helper "550e8400-e29b-41g4-a716-446655440000"
assert_eq "TC-6.1: exit code is 1 (g は hex 範囲外)" "1" "$rc"
assert_eq "TC-6.2: stdout is empty" "" "$out"

# ================================================================
echo "TC-7 (invalid, shell metachar): UUID 形式に shell metachar → exit 1"
# ================================================================
# `$(date)` のような command substitution 形式は UUID regex に match しない
run_helper '550e8400-$(id)-41d4-a716-446655440000'
assert_eq "TC-7.1: exit code is 1" "1" "$rc"
assert_eq "TC-7.2: stdout is empty" "" "$out"

# ================================================================
echo "TC-8 (invalid, empty): 空文字列 → exit 1"
# ================================================================
run_helper ""
assert_eq "TC-8.1: exit code is 1" "1" "$rc"
assert_eq "TC-8.2: stdout is empty" "" "$out"

# ================================================================
echo "TC-9 (invalid, no_arg): 引数なし → exit 1"
# ================================================================
out=$(bash "$HELPER" 2>&1) && rc=0 || rc=$?
assert_eq "TC-9.1: exit code is 1" "1" "$rc"
assert_eq "TC-9.2: stdout is empty" "" "$out"

# ================================================================
echo "TC-10 (boundary, all_zeros): 00000000-... → exit 0 (valid hex)"
# ================================================================
run_helper "00000000-0000-0000-0000-000000000000"
assert_eq "TC-10.1: exit code is 0" "0" "$rc"
assert_eq "TC-10.2: stdout matches" "00000000-0000-0000-0000-000000000000" "$out"

# ================================================================
echo "TC-11 (boundary, all_fs lowercase): ffffffff-... → exit 0 (valid hex)"
# ================================================================
run_helper "ffffffff-ffff-ffff-ffff-ffffffffffff"
assert_eq "TC-11.1: exit code is 0" "0" "$rc"
assert_eq "TC-11.2: stdout matches lowercase" "ffffffff-ffff-ffff-ffff-ffffffffffff" "$out"

# ================================================================
echo "TC-12 (boundary, all_FS uppercase normalize): FFFFFFFF-... → 完全 lowercase"
# ================================================================
# 全て uppercase の F でも tr 'A-F' 'a-f' で完全 lowercase になることを verify
run_helper "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"
assert_eq "TC-12.1: exit code is 0" "0" "$rc"
assert_eq "TC-12.2: 全 UPPERCASE は全 lowercase に変換される" "ffffffff-ffff-ffff-ffff-ffffffffffff" "$out"

# ================================================================
echo "TC-13 (mutation kill): tr が cat に mutate された場合の検出"
# ================================================================
# このテストは「TC-2 と TC-3 と TC-12 の 3 つ」で normalize 動作を verify することで
# `tr 'A-F' 'a-f'` を `cat` に mutate した時に必ず複数 TC が fail することを保証する。
# (`cat` mutate なら uppercase/mixed_case で stdout が input と同じ非 lowercase に
# なるため TC-2.2 / TC-3.2 / TC-12.2 で必ず fail する。)
echo "  ℹ️  TC-13: TC-2.2 / TC-3.2 / TC-12.2 の 3 重 invariant で mutation kill power を保証"

# ================================================================
echo ""
echo "─── _resolve-session-id.test.sh summary ──────────────────────────"
echo "PASS: $PASS"
echo "FAIL: $FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo "All tests passed."
  exit 0
else
  echo "Some tests failed."
  exit 1
fi
