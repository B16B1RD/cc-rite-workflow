#!/usr/bin/env bash
# Tests for flow-state-update.sh _resolve_session_state_path subshell isolation
# property.
#
# Invariant under test:
#   `_resolve_session_state_path` は subshell-isolating context (command substitution
#   `$(...)`、backtick `` `...` ``、process substitution `< <(...)`、pipeline `... |`)
#   で呼ばれることを前提に設計されている。bash の subshell isolation により関数内の
#   `trap` 変更は parent shell に leak しないため、関数末尾の `trap - EXIT INT TERM HUP`
#   reset は安全である。本テストはこの不変条件を経験的に固定する。
#
# Coverage:
#   TC-1 (negative control) — bash 仕様への依存性 assert: direct call で trap leak が発生する
#                              ことを確認する。bash subshell isolation 仕様が将来変更され leak しなく
#                              なった場合は本 TC が fail する設計 (期待通り — 仕様変更を回帰として
#                              検出する)。bash の POSIX 仕様は安定しているため事実上の問題はない。
#   TC-2 (positive control) — Command substitution `$()` で parent trap が保持される
#   TC-3 — flow-state-update.sh が subshell-isolating context で関数を呼ぶ (semantic check):
#          `$(...)` / backtick / process substitution / pipeline のいずれかで呼ばれていればよい
#   TC-4 — Edge cases: nested function call の trap propagation / `set -e` 環境下の trap 挙動
#
# Usage: bash plugins/rite/hooks/tests/flow-state-update-trap-isolation.test.sh

set -euo pipefail

# bash version check (TC が依存する subshell isolation 仕様は bash 4+ で stable)
if [ -z "${BASH_VERSION:-}" ]; then
  echo "ERROR: bash で実行してください (POSIX sh 等では subshell isolation の挙動が異なる可能性があります)" >&2
  exit 1
fi
echo "[INFO] bash version: $BASH_VERSION"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_SCRIPT="$SCRIPT_DIR/../flow-state-update.sh"

# 本 test は静的 grep のみで検査するため -f (regular file 存在) で十分
if [ ! -f "$TARGET_SCRIPT" ]; then
  echo "ERROR: flow-state-update.sh missing: $TARGET_SCRIPT" >&2
  exit 1
fi

PASS=0
FAIL=0
FAILED_NAMES=()

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

# stderr capture 付きで bash -c を実行し、inner script の異常終了を silent suppress しない。
# stdout / stderr / rc を別々に取得する (silent regression 防止)。
# ⚠️ heredoc 経由の引数渡しは bash の `<<<` を使う (here-string)。
run_bash_c() {
  local script="$1"
  local out_var="$2"
  local err_var="$3"
  local rc_var="$4"
  local stderr_tmp
  stderr_tmp=$(mktemp /tmp/rite-trap-isolation-stderr-XXXXXX) || {
    echo "  ❌ stderr_tmp mktemp 失敗" >&2
    return 1
  }
  local out rc
  if out=$(bash -c "$script" 2>"$stderr_tmp"); then
    rc=0
  else
    rc=$?
  fi
  printf -v "$out_var" '%s' "$out"
  printf -v "$err_var" '%s' "$(cat "$stderr_tmp")"
  printf -v "$rc_var" '%s' "$rc"
  rm -f "$stderr_tmp"
}

# ---------------------------------------------------------------
# TC-1 (negative control): Direct function call leaks `trap -` reset
#   bash subshell isolation 仕様が機能していることを確認する。bash の仕様変更で
#   direct call でも leak が発生しなくなった場合、本 TC が fail する (期待通り — 仕様変更を
#   回帰として検出する設計)。POSIX/bash 5.x で stable。
# ---------------------------------------------------------------
echo "=== TC-1: Direct call leaks trap reset (bash 仕様依存性 assert) ==="
direct_script='
f() {
  trap "echo INNER_TRAP" EXIT
  trap - EXIT INT TERM HUP
}
trap "echo OUTER_TRAP" EXIT
f
echo MAIN_DONE
'
direct_out=""
direct_err=""
direct_rc=""
run_bash_c "$direct_script" direct_out direct_err direct_rc

# inner bash の syntax error / 異常終了を silent suppress しない (stderr empty を assert)
if [ -n "$direct_err" ]; then
  echo "  ❌ TC-1.precond: inner bash が stderr を出力しました (script 破壊の兆候):"
  echo "     stderr: $direct_err"
  FAIL=$((FAIL+1))
  FAILED_NAMES+=("TC-1.precond")
elif [ "$direct_rc" -ne 0 ]; then
  echo "  ❌ TC-1.precond: inner bash が rc=$direct_rc で終了 (期待: rc=0)"
  FAIL=$((FAIL+1))
  FAILED_NAMES+=("TC-1.precond")
else
  echo "  ✅ TC-1.precond: inner bash が clean に rc=0 で終了 (stderr empty)"
  PASS=$((PASS+1))

  assert_contains "TC-1.a: MAIN_DONE が出力される" "$direct_out" "MAIN_DONE"
  if printf '%s' "$direct_out" | grep -qF "OUTER_TRAP"; then
    echo "  ❌ TC-1.b: bash 仕様変更検出 — direct call でも OUTER_TRAP が leak しなかった"
    echo "     これは bash の subshell isolation 仕様変更を意味します。コードは安全側にあるため修正不要ですが、本 TC の前提 (仕様への依存性 assert) が変わったことを確認してください"
    FAIL=$((FAIL+1))
    FAILED_NAMES+=("TC-1.b")
  else
    echo "  ✅ TC-1.b: 直接呼び出しで OUTER_TRAP は leak する (期待通り — F-09 reproducer)"
    PASS=$((PASS+1))
  fi
fi

# ---------------------------------------------------------------
# TC-2 (positive control): Command substitution `$()` isolates trap modifications
#   This is the actual code path used by flow-state-update.sh.
# ---------------------------------------------------------------
echo ""
echo "=== TC-2: Command substitution preserves parent trap ==="
subshell_script='
f() {
  trap "echo INNER_TRAP" EXIT
  trap - EXIT INT TERM HUP
  echo "function_output"
}
trap "echo OUTER_TRAP" EXIT
result=$(f)
echo "MAIN result=$result"
'
subshell_out=""
subshell_err=""
subshell_rc=""
run_bash_c "$subshell_script" subshell_out subshell_err subshell_rc

if [ -n "$subshell_err" ]; then
  echo "  ❌ TC-2.precond: inner bash が stderr を出力しました (script 破壊の兆候):"
  echo "     stderr: $subshell_err"
  FAIL=$((FAIL+1))
  FAILED_NAMES+=("TC-2.precond")
elif [ "$subshell_rc" -ne 0 ]; then
  echo "  ❌ TC-2.precond: inner bash が rc=$subshell_rc で終了 (期待: rc=0)"
  FAIL=$((FAIL+1))
  FAILED_NAMES+=("TC-2.precond")
else
  echo "  ✅ TC-2.precond: inner bash が clean に rc=0 で終了 (stderr empty)"
  PASS=$((PASS+1))

  assert_contains "TC-2.a: function output が capture される" "$subshell_out" "MAIN result=function_output"
  assert_contains "TC-2.b: parent OUTER_TRAP が保持される (subshell isolation)" "$subshell_out" "OUTER_TRAP"
fi

# ---------------------------------------------------------------
# TC-3 (semantic check): flow-state-update.sh が subshell-isolating context で
#   `_resolve_session_state_path` を呼ぶ。`$(...)` だけでなく backtick / process
#   substitution / pipeline 形式も isolation 維持として allowlist に含める。
# ---------------------------------------------------------------
echo ""
echo "=== TC-3: flow-state-update.sh uses a subshell-isolating context ==="

# `_resolve_session_state_path` 関数定義行 (`_resolve_session_state_path()`) を除いた
# 呼び出し行を grep で抽出する。コメント行 (`^\s*#`) も除く。
call_lines=$(grep -nE '_resolve_session_state_path' "$TARGET_SCRIPT" \
  | grep -vE ':[[:space:]]*#' \
  | grep -vE ':_resolve_session_state_path\(\)' || true)

if [ -z "$call_lines" ]; then
  echo "  ❌ TC-3.precond: _resolve_session_state_path への参照が 1 件も見つかりません"
  FAIL=$((FAIL+1))
  FAILED_NAMES+=("TC-3.precond")
else
  # 各 call line を allowlist regex で検査する。少なくとも 1 行が allowlist にマッチすればよい。
  # allowlist:
  #   - command substitution `$(_resolve_session_state_path`
  #   - backtick `` `_resolve_session_state_path ``
  #   - process substitution `< <(_resolve_session_state_path` または `<(_resolve_session_state_path`
  #   - pipeline `_resolve_session_state_path ... |` (右辺 pipe で reader が subshell)
  isolating_count=0
  direct_call_count=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    # allowlist 形式のいずれかにマッチするか
    if echo "$line" | grep -qE '\$\(_resolve_session_state_path|`_resolve_session_state_path|<[[:space:]]*\(_resolve_session_state_path|_resolve_session_state_path[^|]*\|'; then
      isolating_count=$((isolating_count + 1))
    else
      # 行頭 (whitespace 後) で `_resolve_session_state_path` が直接呼ばれているケース
      # (関数定義行は上で除外済み)
      if echo "$line" | grep -qE ':[[:space:]]*_resolve_session_state_path([[:space:]]|$|;)'; then
        direct_call_count=$((direct_call_count + 1))
        echo "  [DEBUG] direct call detected: $line"
      fi
    fi
  done <<< "$call_lines"

  if [ "$isolating_count" -ge 1 ]; then
    echo "  ✅ TC-3.a: subshell-isolating context での呼び出しを ${isolating_count} 件検出"
    PASS=$((PASS+1))
  else
    echo "  ❌ TC-3.a: subshell-isolating context での呼び出しが 0 件"
    echo "     対処: command substitution \$(...) / backtick / process substitution / pipeline で呼び出すよう refactor が必要"
    FAIL=$((FAIL+1))
    FAILED_NAMES+=("TC-3.a")
  fi

  if [ "$direct_call_count" -eq 0 ]; then
    echo "  ✅ TC-3.b: direct call (subshell wrapping なし) は存在しない"
    PASS=$((PASS+1))
  else
    echo "  ❌ TC-3.b: direct call (subshell wrapping なし) が ${direct_call_count} 件検出された"
    FAIL=$((FAIL+1))
    FAILED_NAMES+=("TC-3.b")
  fi
fi

# ---------------------------------------------------------------
# TC-4 (edge cases): nested function call + `set -e` 環境下の trap 挙動
# ---------------------------------------------------------------
echo ""
echo "=== TC-4: Edge cases (nested call, set -e) ==="

# TC-4.a: nested function call で direct path だと両方の trap が消える
nested_script='
inner() {
  trap "echo INNER_TRAP" EXIT
  trap - EXIT INT TERM HUP
}
outer() {
  trap "echo OUTER_FN_TRAP" EXIT
  inner
  echo "outer body"
}
trap "echo MAIN_TRAP" EXIT
outer
echo MAIN_DONE
'
nested_out=""
nested_err=""
nested_rc=""
run_bash_c "$nested_script" nested_out nested_err nested_rc

if [ -n "$nested_err" ] || [ "$nested_rc" -ne 0 ]; then
  echo "  ❌ TC-4.a.precond: inner bash が異常終了 (rc=$nested_rc, stderr=$nested_err)"
  FAIL=$((FAIL+1))
  FAILED_NAMES+=("TC-4.a.precond")
else
  # nested direct call では全 trap が消える (subshell isolation なしのため)
  if printf '%s' "$nested_out" | grep -qF "MAIN_TRAP"; then
    echo "  ❌ TC-4.a: nested direct call で MAIN_TRAP が leak しなかった (期待: 消える)"
    FAIL=$((FAIL+1))
    FAILED_NAMES+=("TC-4.a")
  else
    echo "  ✅ TC-4.a: nested direct call で MAIN_TRAP が消える (subshell isolation なしの仕様確認)"
    PASS=$((PASS+1))
  fi
fi

# TC-4.b: set -e 環境下でも subshell isolation は維持される
sete_script='
set -e
f() {
  trap "echo INNER_TRAP" EXIT
  trap - EXIT INT TERM HUP
  echo "function_output"
}
trap "echo OUTER_TRAP" EXIT
result=$(f)
echo "MAIN result=$result"
'
sete_out=""
sete_err=""
sete_rc=""
run_bash_c "$sete_script" sete_out sete_err sete_rc

if [ -n "$sete_err" ] || [ "$sete_rc" -ne 0 ]; then
  echo "  ❌ TC-4.b.precond: inner bash が異常終了 (rc=$sete_rc, stderr=$sete_err)"
  FAIL=$((FAIL+1))
  FAILED_NAMES+=("TC-4.b.precond")
else
  assert_contains "TC-4.b: set -e 環境下でも subshell isolation で OUTER_TRAP が保持される" \
    "$sete_out" "OUTER_TRAP"
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
