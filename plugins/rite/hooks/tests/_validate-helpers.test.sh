#!/bin/bash
# Tests for _validate-helpers.sh (verified-review F11-06 対応で新規追加)
#
# Purpose:
#   PR #688 cycle 10 F-06 で抽出された `_validate-helpers.sh` (helper existence
#   check の DRY 化) は state-read.sh / flow-state-update.sh の 2 caller で SoT
#   として使われるため、helper 自体のバグは両 caller を巻き込む blast radius
#   を持つ。本テストは helper 単体の defensive paths を pin する。
#
# Test cases:
#   TC-1: 引数 0 個で exit 1 + ERROR メッセージ
#   TC-2: 引数 1 個 (script_dir のみ、helper 名なし) で exit 1
#   TC-3: 全 helper 存在 + executable で exit 0 silent (success path)
#   TC-4: 1 helper missing (chmod -x) で exit 1 + ERROR contains helper basename
#   TC-5: invalid script_dir (`/nonexistent`) で exit 1 + ERROR contains path
#   TC-6: 複数 helper missing で最初の missing で fail-fast (順序保証)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$HOOKS_DIR/_validate-helpers.sh"

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
  # 検査対象 helper 群を sandbox に配置 (executable)
  for h in state-path-resolve.sh _resolve-session-id.sh _resolve-session-id-from-file.sh \
           _resolve-schema-version.sh _resolve-cross-session-guard.sh \
           _emit-cross-session-incident.sh _mktemp-stderr-guard.sh; do
    : > "$sbx/$h"
    chmod +x "$sbx/$h"
  done
  printf '%s' "$sbx"
}

# ================================================================
echo "TC-1: 引数 0 個 (script_dir 不在) で exit 1 + ERROR"
# ================================================================
out=$(bash "$HELPER" 2>&1) && rc=0 || rc=$?
assert_eq "TC-1.1: exit code is 1" "1" "$rc"
assert_match "TC-1.2: ERROR mentions 'at least 2 arguments'" "at least 2 arguments" "$out"

# ================================================================
echo "TC-2: 引数 1 個 (script_dir のみ、helper 名なし) で exit 1"
# ================================================================
sbx=$(make_sandbox)
out=$(bash "$HELPER" "$sbx" 2>&1) && rc=0 || rc=$?
assert_eq "TC-2.1: exit code is 1" "1" "$rc"
assert_match "TC-2.2: ERROR mentions 'at least 2 arguments'" "at least 2 arguments" "$out"

# ================================================================
echo "TC-3: 全 helper 存在 + executable で exit 0 silent (success path)"
# ================================================================
sbx=$(make_sandbox)
out=$(bash "$HELPER" "$sbx" \
  state-path-resolve.sh _resolve-session-id.sh _resolve-session-id-from-file.sh \
  _resolve-schema-version.sh _resolve-cross-session-guard.sh \
  _emit-cross-session-incident.sh _mktemp-stderr-guard.sh 2>&1) && rc=0 || rc=$?
assert_eq "TC-3.1: exit code is 0" "0" "$rc"
assert_eq "TC-3.2: stdout/stderr is silent" "" "$out"

# ================================================================
echo "TC-4: 1 helper missing (chmod -x) で exit 1 + ERROR"
# ================================================================
sbx=$(make_sandbox)
chmod -x "$sbx/_mktemp-stderr-guard.sh"
out=$(bash "$HELPER" "$sbx" \
  state-path-resolve.sh _resolve-session-id.sh _resolve-session-id-from-file.sh \
  _resolve-schema-version.sh _resolve-cross-session-guard.sh \
  _emit-cross-session-incident.sh _mktemp-stderr-guard.sh 2>&1) && rc=0 || rc=$?
assert_eq "TC-4.1: exit code is 1" "1" "$rc"
assert_match "TC-4.2: ERROR mentions missing helper basename" "_mktemp-stderr-guard.sh" "$out"
assert_match "TC-4.3: ERROR mentions 'not found or not executable'" "not found or not executable" "$out"

# ================================================================
echo "TC-5: invalid script_dir で exit 1 + ERROR mentions path"
# ================================================================
out=$(bash "$HELPER" "/nonexistent-${RANDOM}-dir" state-path-resolve.sh 2>&1) && rc=0 || rc=$?
assert_eq "TC-5.1: exit code is 1" "1" "$rc"
assert_match "TC-5.2: ERROR mentions helper basename" "state-path-resolve.sh" "$out"

# ================================================================
echo "TC-6: 複数 helper missing で最初の missing で fail-fast (順序保証)"
# ================================================================
sbx=$(make_sandbox)
chmod -x "$sbx/_resolve-session-id.sh"
chmod -x "$sbx/_emit-cross-session-incident.sh"
out=$(bash "$HELPER" "$sbx" \
  state-path-resolve.sh _resolve-session-id.sh _resolve-session-id-from-file.sh \
  _resolve-schema-version.sh _resolve-cross-session-guard.sh \
  _emit-cross-session-incident.sh _mktemp-stderr-guard.sh 2>&1) && rc=0 || rc=$?
assert_eq "TC-6.1: exit code is 1" "1" "$rc"
assert_match "TC-6.2: ERROR mentions FIRST missing helper (順序保証)" "_resolve-session-id.sh" "$out"
# 後続 helper は loop が早期 exit するため検査されない (deterministic order)

# ================================================================
echo ""
echo "─── _validate-helpers.test.sh summary ──────────────────────────"
echo "PASS: $PASS"
echo "FAIL: $FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo "All tests passed."
  exit 0
else
  echo "Some tests failed."
  exit 1
fi
