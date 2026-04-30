#!/bin/bash
# Tests for flow-state-update.sh _resolve_session_state_path subshell isolation
# property (Issue #698 F-09).
#
# # Why this exists (Issue #698 F-09):
#   PR #688 verified-review cycle 10 で「`_resolve_session_state_path` 関数内で
#   `trap - EXIT INT TERM HUP` を実行しているため、line 220 から script-level の
#   atomic-cleanup trap install までの間 SIGINT/SIGTERM/SIGHUP/EXIT 用 trap が一切ない
#   race window が発生する」という MEDIUM 指摘 (F-09) が出された。
#
#   実際にはこの関数は `FLOW_STATE=$(_resolve_session_state_path ...)` という
#   command substitution で呼び出されており、bash の subshell isolation により関数内の
#   trap 変更は parent shell に leak しない。本テストはその不変条件を経験的に固定し、
#   将来 caller が direct call (`_resolve_session_state_path ...; FLOW_STATE=...`)
#   に refactor された場合に回帰として検出できるようにする。
#
# Coverage:
#   TC-1 — Direct call leaks parent shell trap (issue F-09 reproducer の確認)
#   TC-2 — Command substitution `$()` preserves parent shell trap (current code path)
#   TC-3 — flow-state-update.sh actually calls _resolve_session_state_path via $()
#
# Usage: bash plugins/rite/hooks/tests/flow-state-update-trap-isolation.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_SCRIPT="$SCRIPT_DIR/../flow-state-update.sh"

if [ ! -x "$TARGET_SCRIPT" ]; then
  echo "ERROR: flow-state-update.sh missing or not executable: $TARGET_SCRIPT" >&2
  exit 1
fi

PASS=0
FAIL=0
FAILED_NAMES=()

# Form B cleanup pattern (return 0 必須) — bash-trap-patterns.md "cleanup 関数の契約" 節 Form B 参照
cleanup_files=()
_trap_isolation_test_cleanup() {
  local f
  for f in "${cleanup_files[@]:-}"; do
    [ -n "$f" ] && [ -f "$f" ] && rm -f "$f"
  done
  return 0
}
trap '_trap_isolation_test_cleanup' EXIT
trap '_trap_isolation_test_cleanup; exit 130' INT
trap '_trap_isolation_test_cleanup; exit 143' TERM
trap '_trap_isolation_test_cleanup; exit 129' HUP

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  ✅ $name"
    PASS=$((PASS+1))
  else
    echo "  ❌ $name"
    echo "     expected: $expected"
    echo "     actual:   $actual"
    FAIL=$((FAIL+1))
    FAILED_NAMES+=("$name")
  fi
}

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "  ✅ $name"
    PASS=$((PASS+1))
  else
    echo "  ❌ $name"
    echo "     haystack: $haystack"
    echo "     needle:   $needle"
    FAIL=$((FAIL+1))
    FAILED_NAMES+=("$name")
  fi
}

# ---------------------------------------------------------------
# TC-1: Direct function call leaks `trap -` reset to parent shell
#   This is the empirical reproducer from Issue #698 F-09. It confirms that
#   without subshell isolation, an inner `trap - EXIT INT TERM HUP` would
#   cancel the parent's EXIT trap.
# ---------------------------------------------------------------
echo "=== TC-1: Direct call leaks trap reset ==="
direct_out=$(bash -c '
f() {
  trap "echo INNER_TRAP" EXIT
  trap - EXIT INT TERM HUP
}
trap "echo OUTER_TRAP" EXIT
f
echo MAIN_DONE
' 2>/dev/null)

# Direct call → trap leaks → OUTER_TRAP は実行されない (issue F-09 reproducer)
assert_contains "TC-1.a: MAIN_DONE が出力される" "$direct_out" "MAIN_DONE"
if printf '%s' "$direct_out" | grep -qF "OUTER_TRAP"; then
  echo "  ❌ TC-1.b: 直接呼び出しでも OUTER_TRAP が leak しなかった (bash の subshell isolation 仕様変更?)"
  FAIL=$((FAIL+1))
  FAILED_NAMES+=("TC-1.b")
else
  echo "  ✅ TC-1.b: 直接呼び出しでは OUTER_TRAP は leak する (期待通り — F-09 reproducer)"
  PASS=$((PASS+1))
fi

# ---------------------------------------------------------------
# TC-2: Command substitution `$()` isolates trap modifications
#   This is the actual code path used by flow-state-update.sh:
#     FLOW_STATE=$(_resolve_session_state_path ...)
#   The function runs in a subshell, so trap modifications stay scoped.
# ---------------------------------------------------------------
echo ""
echo "=== TC-2: Command substitution preserves parent trap ==="
subshell_out=$(bash -c '
f() {
  trap "echo INNER_TRAP" EXIT
  trap - EXIT INT TERM HUP
  echo "function_output"
}
trap "echo OUTER_TRAP" EXIT
result=$(f)
echo "MAIN result=$result"
' 2>/dev/null)

assert_contains "TC-2.a: function output が capture される" "$subshell_out" "MAIN result=function_output"
assert_contains "TC-2.b: parent OUTER_TRAP が保持される (subshell isolation)" "$subshell_out" "OUTER_TRAP"

# ---------------------------------------------------------------
# TC-3: flow-state-update.sh は実際に command substitution で関数を呼ぶ
#   Static analysis: future refactoring が direct call に変更した場合、
#   subshell isolation が失われ trap leak が発生する。grep で pattern が
#   保持されていることを確認する。
# ---------------------------------------------------------------
echo ""
echo "=== TC-3: flow-state-update.sh uses subshell pattern ==="
# Pattern: 何らかの代入の右辺に `$(_resolve_session_state_path` が含まれる
# (e.g. `FLOW_STATE=$(_resolve_session_state_path ...)`)
if grep -qE '=\$\(_resolve_session_state_path' "$TARGET_SCRIPT"; then
  echo "  ✅ TC-3.a: flow-state-update.sh は \$(_resolve_session_state_path ...) で関数を呼ぶ (subshell isolation 維持)"
  PASS=$((PASS+1))
else
  echo "  ❌ TC-3.a: flow-state-update.sh が _resolve_session_state_path を direct call している可能性 (regression)"
  echo "     対処: command substitution \$(...) で呼び出すよう refactor が必要"
  FAIL=$((FAIL+1))
  FAILED_NAMES+=("TC-3.a")
fi

# Direct call (`_resolve_session_state_path` 行頭 + space) が無いことも確認
# ただし comment / docstring / function definition は除外する
if grep -nE '^[[:space:]]*_resolve_session_state_path[[:space:]]' "$TARGET_SCRIPT" \
     | grep -vE '^\s*#' | grep -v '^[0-9]+:_resolve_session_state_path()' >/dev/null 2>&1; then
  echo "  ❌ TC-3.b: direct call (subshell wrapping なし) が検出された"
  FAIL=$((FAIL+1))
  FAILED_NAMES+=("TC-3.b")
else
  echo "  ✅ TC-3.b: direct call (subshell wrapping なし) は存在しない"
  PASS=$((PASS+1))
fi

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
echo ""
echo "================================="
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed tests:"
  for n in "${FAILED_NAMES[@]}"; do
    echo "  - $n"
  done
  exit 1
fi
exit 0
