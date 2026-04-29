#!/bin/bash
# Tests for _validate-helpers.sh (verified-review F11-06 + PR #688 cycle 13 F-01 対応)
#
# Purpose:
#   PR #688 cycle 10 F-06 で抽出された `_validate-helpers.sh` (helper existence
#   check の DRY 化) は state-read.sh / flow-state-update.sh の 2 caller で SoT
#   として使われるため、helper 自体のバグは両 caller を巻き込む blast radius
#   を持つ。本テストは helper 単体の defensive paths を pin する。
#
#   PR #688 cycle 13 F-01 (HIGH): caller の helper-list 自体の duplication 解消の
#   ため、`DEFAULT_HELPERS` 配列を helper 内部に追加し、引数 0 個 (script_dir のみ)
#   で呼ばれた場合は default を使う API 拡張を行った。本テストは新旧両 API path を
#   検証する。
#
# Test cases:
#   TC-1: 引数 0 個 (script_dir 不在) で exit 1 + ERROR メッセージ
#   TC-2 (NEW API): 引数 1 個 (script_dir のみ) で DEFAULT_HELPERS を使用 — 全 helper 存在で exit 0
#   TC-3 (legacy API, backward compat): 明示 list で全 helper 存在 → exit 0 silent
#   TC-4 (legacy API): 1 helper missing (chmod -x) で exit 1 + ERROR contains helper basename
#   TC-5: invalid script_dir (`/nonexistent`) で exit 1 + ERROR contains path
#   TC-6 (legacy API): 複数 helper missing で最初の missing で fail-fast (順序保証)
#   TC-7 (NEW API): DEFAULT_HELPERS 経路で 1 helper missing → exit 1 + ERROR contains helper basename
#   TC-8 (NEW API): DEFAULT_HELPERS 配列の全 entry すべてが検査されることを確認

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

# DEFAULT_HELPERS の SoT (sandbox 構築時に使用)
DEFAULT_HELPERS_LIST=(
  state-path-resolve.sh
  _resolve-session-id.sh
  _resolve-session-id-from-file.sh
  _resolve-schema-version.sh
  _resolve-cross-session-guard.sh
  _emit-cross-session-incident.sh
  _mktemp-stderr-guard.sh
  _validate-state-root.sh
)

make_sandbox() {
  local sbx
  sbx=$(mktemp -d)
  cleanup_dirs+=("$sbx")
  # 検査対象 helper 群を sandbox に配置 (executable)
  for h in "${DEFAULT_HELPERS_LIST[@]}"; do
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
assert_match "TC-1.2: ERROR mentions 'at least 1 argument'" "at least 1 argument" "$out"

# ================================================================
echo "TC-2 (NEW API): 引数 1 個 (script_dir のみ) で DEFAULT_HELPERS を使用 — exit 0"
# ================================================================
sbx=$(make_sandbox)
out=$(bash "$HELPER" "$sbx" 2>&1) && rc=0 || rc=$?
assert_eq "TC-2.1: exit code is 0 (DEFAULT_HELPERS 使用、全 helper 存在)" "0" "$rc"
assert_eq "TC-2.2: stdout/stderr is silent" "" "$out"

# ================================================================
echo "TC-3 (legacy API, backward compat): 明示 list で全 helper 存在 → exit 0 silent"
# ================================================================
sbx=$(make_sandbox)
out=$(bash "$HELPER" "$sbx" \
  state-path-resolve.sh _resolve-session-id.sh _resolve-session-id-from-file.sh \
  _resolve-schema-version.sh _resolve-cross-session-guard.sh \
  _emit-cross-session-incident.sh _mktemp-stderr-guard.sh 2>&1) && rc=0 || rc=$?
assert_eq "TC-3.1: exit code is 0" "0" "$rc"
assert_eq "TC-3.2: stdout/stderr is silent" "" "$out"

# ================================================================
echo "TC-4 (legacy API): 1 helper missing (chmod -x) で exit 1 + ERROR"
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
echo "TC-6 (legacy API): 複数 helper missing で最初の missing で fail-fast (順序保証)"
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
echo "TC-7 (NEW API): DEFAULT_HELPERS 経路で 1 helper missing → exit 1 + ERROR"
# ================================================================
sbx=$(make_sandbox)
chmod -x "$sbx/_resolve-cross-session-guard.sh"
# 引数なし (script_dir のみ) で DEFAULT_HELPERS を使用
out=$(bash "$HELPER" "$sbx" 2>&1) && rc=0 || rc=$?
assert_eq "TC-7.1: exit code is 1 (DEFAULT_HELPERS 経路で fail-fast)" "1" "$rc"
assert_match "TC-7.2: ERROR mentions missing helper basename" "_resolve-cross-session-guard.sh" "$out"

# ================================================================
echo "TC-8 (NEW API): DEFAULT_HELPERS 配列の全 entry すべてが検査されることを確認"
# ================================================================
# 1 つずつ chmod -x して、それぞれが正しく検出されることを確認することで
# DEFAULT_HELPERS 配列の completeness を verify する (Issue #687 root cause と
# 同型の片肺更新 drift を防ぐための structural invariant 検証)
for missing_helper in "${DEFAULT_HELPERS_LIST[@]}"; do
  sbx=$(make_sandbox)
  chmod -x "$sbx/$missing_helper"
  out=$(bash "$HELPER" "$sbx" 2>&1) && rc=0 || rc=$?
  if [ "$rc" = "1" ] && [[ "$out" == *"$missing_helper"* ]]; then
    echo "  ✅ TC-8.${missing_helper}: chmod -x → DEFAULT_HELPERS 経路で fail-fast 検出"
    PASS=$((PASS + 1))
  else
    echo "  ❌ TC-8.${missing_helper}: rc=$rc, output=$out"
    FAIL=$((FAIL + 1))
  fi
done

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
