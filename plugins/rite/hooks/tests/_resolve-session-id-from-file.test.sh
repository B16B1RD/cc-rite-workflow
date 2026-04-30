#!/bin/bash
# Tests for _resolve-session-id-from-file.sh (PR #688 cycle 13 F-02 対応)
#
# Purpose:
#   PR #688 cycle 12 F-05 で `_resolve-session-id-from-file.sh:90-107` に追加された
#   path traversal / shell metachar / 制御文字 reject ロジック (security defense-in-depth)
#   は caller 3 site (state-read.sh / flow-state-update.sh / resume-active-flag-restore.sh)
#   が validated path のみ渡すため、悪意ある STATE_ROOT 入力経路を exercise する test が
#   不在だった。validation を `:` (no-op) に mutate しても全 caller TC が pass する
#   false-negative 経路を防ぐため、本 helper の direct test を追加する。
#
# Test cases:
#   TC-1: 正常 path + valid UUID file → exit 0 + UUID stdout (lowercase normalized)
#   TC-2: 正常 path + .rite-session-id 不在 → exit 0 + empty stdout
#   TC-3: 正常 path + invalid UUID content → exit 0 + empty stdout (validation 失敗 fallback)
#   TC-4: 正常 path + empty file → exit 0 + empty stdout
#   TC-5: STATE_ROOT に path traversal (../foo) → exit 1 + ERROR
#   TC-6: STATE_ROOT に shell variable expansion ($VAR) → exit 1 + ERROR
#   TC-7: STATE_ROOT に command substitution (backtick) → exit 1 + ERROR
#   TC-8: STATE_ROOT に newline (制御文字) → exit 1 + ERROR
#   TC-9: STATE_ROOT 引数なし (空文字) → exit 1 + ERROR
#   TC-10: STATE_ROOT は正常だが .rite-session-id が whitespace のみ → exit 0 + empty stdout

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$HOOKS_DIR/_resolve-session-id-from-file.sh"

PASS=0
FAIL=0
cleanup_dirs=()

cleanup() {
  for d in "${cleanup_dirs[@]}"; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
  done
}
trap cleanup EXIT INT TERM HUP

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

assert_match() {
  local label="$1" pattern="$2" actual="$3"
  if [[ "$actual" == *"$pattern"* ]]; then
    echo "  ✅ $label"
    PASS=$((PASS + 1))
  else
    echo "  ❌ $label"
    echo "     Pattern (substring): $pattern"
    echo "     Actual:              $actual"
    FAIL=$((FAIL + 1))
  fi
}

make_sandbox() {
  local sbx
  sbx=$(mktemp -d)
  cleanup_dirs+=("$sbx")
  printf '%s' "$sbx"
}

# ================================================================
echo "TC-1: 正常 path + valid UUID file → exit 0 + UUID stdout (lowercase)"
# ================================================================
sbx=$(make_sandbox)
echo "550e8400-e29b-41d4-a716-446655440000" > "$sbx/.rite-session-id"
out=$(bash "$HELPER" "$sbx" 2>&1) && rc=0 || rc=$?
assert_eq "TC-1.1: exit code is 0" "0" "$rc"
assert_eq "TC-1.2: stdout is the validated UUID" "550e8400-e29b-41d4-a716-446655440000" "$out"

# ================================================================
echo "TC-2: 正常 path + .rite-session-id 不在 → exit 0 + empty stdout"
# ================================================================
sbx=$(make_sandbox)
out=$(bash "$HELPER" "$sbx" 2>&1) && rc=0 || rc=$?
assert_eq "TC-2.1: exit code is 0" "0" "$rc"
assert_eq "TC-2.2: stdout is empty (file absent → graceful)" "" "$out"

# ================================================================
echo "TC-3: 正常 path + invalid UUID content → exit 0 + empty stdout"
# ================================================================
sbx=$(make_sandbox)
echo "not-a-valid-uuid" > "$sbx/.rite-session-id"
out=$(bash "$HELPER" "$sbx" 2>&1) && rc=0 || rc=$?
assert_eq "TC-3.1: exit code is 0 (graceful fallback)" "0" "$rc"
assert_eq "TC-3.2: stdout is empty (validation 失敗 → empty)" "" "$out"

# ================================================================
echo "TC-4: 正常 path + empty file → exit 0 + empty stdout"
# ================================================================
sbx=$(make_sandbox)
: > "$sbx/.rite-session-id"
out=$(bash "$HELPER" "$sbx" 2>&1) && rc=0 || rc=$?
assert_eq "TC-4.1: exit code is 0" "0" "$rc"
assert_eq "TC-4.2: stdout is empty" "" "$out"

# ================================================================
echo "TC-5: STATE_ROOT に path traversal (../foo) → exit 1 + ERROR"
# ================================================================
out=$(bash "$HELPER" "$(make_sandbox)/../foo" 2>&1) && rc=0 || rc=$?
assert_eq "TC-5.1: exit code is 1" "1" "$rc"
assert_match "TC-5.2: ERROR mentions 'unsafe traversal or shell metacharacter'" "unsafe traversal or shell metacharacter" "$out"

# ================================================================
echo "TC-6: STATE_ROOT に shell variable expansion (\$VAR) → exit 1 + ERROR"
# ================================================================
# 注意: bash がシェル展開しないように single-quote で囲むこと
out=$(bash "$HELPER" '/tmp/test$VAR' 2>&1) && rc=0 || rc=$?
assert_eq "TC-6.1: exit code is 1" "1" "$rc"
assert_match "TC-6.2: ERROR mentions metacharacter" "shell metacharacter" "$out"

# ================================================================
echo "TC-7: STATE_ROOT に command substitution (backtick) → exit 1 + ERROR"
# ================================================================
# bash literal で backtick を含む文字列を渡す
backtick_path='/tmp/test`whoami`'
out=$(bash "$HELPER" "$backtick_path" 2>&1) && rc=0 || rc=$?
assert_eq "TC-7.1: exit code is 1" "1" "$rc"
assert_match "TC-7.2: ERROR mentions metacharacter" "shell metacharacter" "$out"

# ================================================================
echo "TC-8: STATE_ROOT に newline (制御文字) → exit 1 + ERROR"
# ================================================================
# $'\n' は bash ANSI-C quoting で newline を含む文字列を生成
newline_path=$'/tmp/test\n/etc/passwd'
out=$(bash "$HELPER" "$newline_path" 2>&1) && rc=0 || rc=$?
assert_eq "TC-8.1: exit code is 1" "1" "$rc"
assert_match "TC-8.2: ERROR mentions control characters" "control characters" "$out"

# ================================================================
echo "TC-9: STATE_ROOT 引数なし (空文字) → exit 1 + ERROR"
# ================================================================
out=$(bash "$HELPER" "" 2>&1) && rc=0 || rc=$?
assert_eq "TC-9.1: exit code is 1" "1" "$rc"
assert_match "TC-9.2: ERROR mentions usage" "usage" "$out"

# ================================================================
echo "TC-10: 正常 path + .rite-session-id が whitespace のみ → exit 0 + empty"
# ================================================================
sbx=$(make_sandbox)
printf '   \t\n   ' > "$sbx/.rite-session-id"
out=$(bash "$HELPER" "$sbx" 2>&1) && rc=0 || rc=$?
assert_eq "TC-10.1: exit code is 0 (whitespace strip → empty raw → fallback)" "0" "$rc"
assert_eq "TC-10.2: stdout is empty (whitespace stripped → no UUID)" "" "$out"

# ================================================================
echo "TC-11 (NEW API verification): UPPERCASE UUID input → lowercase normalized output"
# ================================================================
# _resolve-session-id.sh が cycle 44 F-10 で導入した case-insensitive accept + lowercase
# normalize の transitive 動作を helper 経由で verify する (caller 経由の indirect カバレッジ
# を補強する direct test)。
sbx=$(make_sandbox)
echo "550E8400-E29B-41D4-A716-446655440000" > "$sbx/.rite-session-id"
out=$(bash "$HELPER" "$sbx" 2>&1) && rc=0 || rc=$?
assert_eq "TC-11.1: exit code is 0" "0" "$rc"
assert_eq "TC-11.2: UPPERCASE UUID は完全 lowercase に正規化される" "550e8400-e29b-41d4-a716-446655440000" "$out"

# ================================================================
echo ""
echo "─── _resolve-session-id-from-file.test.sh summary ──────────────────────────"
echo "PASS: $PASS"
echo "FAIL: $FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo "All tests passed."
  exit 0
else
  echo "Some tests failed."
  exit 1
fi
