#!/bin/bash
# Tests for flow-state-update.sh _resolve_session_state_path subshell isolation
# property.
#
# Invariant under test:
#   `_resolve_session_state_path` は subshell-isolating context (command substitution
#   `$(...)`、backtick `` `...` ``、process substitution `< <(...)` / `<(...)`、
#   pipeline `... |`、background `&`) で呼ばれることを前提に設計されている。bash の
#   subshell isolation により関数内の `trap` 変更は parent shell に leak しないため、
#   関数末尾の `trap - EXIT INT TERM HUP` reset は安全である。本テストはこの不変条件を
#   経験的に固定する。
#
# Coverage:
#   TC-1 (negative control)  — Direct call で trap leak が発生する (bash 仕様への依存性 assert)
#   TC-2 (positive control)  — Command substitution `$()` で parent trap が保持され、
#                              かつ INNER_TRAP は subshell 内に閉じる
#   TC-3 (semantic check)    — flow-state-update.sh が subshell-isolating context で関数を呼ぶ
#                              (allowlist regex で wide に検出。direct call は反対側で flag)
#   TC-4 (edge cases)        — nested function call / set -e の有無 (positive + negative twin)
#
# Note: TC-3 は static check (grep allowlist) であり、direct call regression を検出した場合の
#   修正方向 (caller を `$(...)` 形に戻す) は実装者の判断に委ねる。本テスト自体は invariant
#   違反の発見が責務で、修正方針の指示は出さない。
#
# Usage: bash plugins/rite/hooks/tests/flow-state-update-trap-isolation.test.sh

set -euo pipefail

# bash version check (bash 4+ で stable な subshell isolation 仕様に依存)
# BASH_VERSINFO[0] で major version を厳密検査する (BASH_VERSION 非空 check は bash 3.x も通る)
if [ -z "${BASH_VERSION:-}" ]; then
  echo "ERROR: bash で実行してください (POSIX sh 等では subshell isolation の挙動が異なる可能性があります)" >&2
  exit 1
fi
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  echo "ERROR: bash 4.0+ が必要です (検出: $BASH_VERSION)" >&2
  echo "  対処: macOS では brew install bash で 4+ をインストールし PATH 先頭に追加してください" >&2
  exit 1
fi
echo "[INFO] bash version: $BASH_VERSION"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_SCRIPT="$SCRIPT_DIR/../flow-state-update.sh"

# 静的 grep のみで検査するため -f (regular file 存在) で十分
if [ ! -f "$TARGET_SCRIPT" ]; then
  echo "ERROR: flow-state-update.sh missing: $TARGET_SCRIPT" >&2
  exit 1
fi

PASS=0
FAIL=0
FAILED_NAMES=()

# 既存 codebase convention に合わせた引数順序 (name, expected_substring, actual)。
# work-memory-update.test.sh:68 / resume-active-flag-restore.test.sh:83 と同型。
assert_contains() {
  local name="$1" expected_substring="$2" actual="$3"
  if [[ "$actual" == *"$expected_substring"* ]]; then
    echo "  ✅ $name"
    PASS=$((PASS+1))
  else
    echo "  ❌ $name"
    echo "     expected substring: $expected_substring"
    echo "     actual:             $actual"
    FAIL=$((FAIL+1))
    FAILED_NAMES+=("$name")
  fi
}

# Negative assertion: substring が含まれていないことを検証
assert_not_contains() {
  local name="$1" forbidden_substring="$2" actual="$3"
  if [[ "$actual" != *"$forbidden_substring"* ]]; then
    echo "  ✅ $name"
    PASS=$((PASS+1))
  else
    echo "  ❌ $name"
    echo "     forbidden substring: $forbidden_substring"
    echo "     actual:              $actual"
    FAIL=$((FAIL+1))
    FAILED_NAMES+=("$name")
  fi
}

# stderr capture 付きで bash -c を実行する helper。
# inner script の異常終了を silent suppress しないため stderr を tempfile に退避し、
# trap で SIGINT/SIGTERM/SIGHUP の orphan を防ぐ。
# cat の rc も明示捕捉して race condition で空文字 silent fall-through を防ぐ。
run_bash_c() {
  local script="$1"
  local out_var="$2"
  local err_var="$3"
  local rc_var="$4"
  local stderr_tmp=""
  local _run_cleanup
  _run_cleanup() {
    [ -n "${stderr_tmp:-}" ] && [ -f "${stderr_tmp:-}" ] && rm -f "${stderr_tmp:-}"
  }
  trap '_run_cleanup' RETURN
  if ! stderr_tmp=$(mktemp /tmp/rite-trap-isolation-stderr-XXXXXX); then
    echo "  ❌ run_bash_c: stderr_tmp mktemp 失敗" >&2
    return 1
  fi
  local out rc err_content
  if out=$(bash -c "$script" 2>"$stderr_tmp"); then
    rc=0
  else
    rc=$?
  fi
  # cat の rc を明示捕捉 (race condition で silent empty を防ぐ)
  if ! err_content=$(cat "$stderr_tmp" 2>/dev/null); then
    err_content="<cat failed: $stderr_tmp>"
  fi
  printf -v "$out_var" '%s' "$out"
  printf -v "$err_var" '%s' "$err_content"
  printf -v "$rc_var" '%s' "$rc"
}

# 共通の precondition check (inner bash の異常終了を検出)
check_inner_bash_clean() {
  local prefix="$1" out="$2" err="$3" rc="$4"
  if [ -n "$err" ]; then
    echo "  ❌ ${prefix}.precond: inner bash が stderr を出力 (script 破壊の兆候):"
    echo "     stderr: $err"
    FAIL=$((FAIL+1))
    FAILED_NAMES+=("${prefix}.precond")
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    echo "  ❌ ${prefix}.precond: inner bash が rc=$rc で終了 (期待: rc=0)"
    FAIL=$((FAIL+1))
    FAILED_NAMES+=("${prefix}.precond")
    return 1
  fi
  echo "  ✅ ${prefix}.precond: inner bash が clean に rc=0 で終了"
  PASS=$((PASS+1))
  return 0
}

# ---------------------------------------------------------------
# TC-1 (negative control): Direct call leaks `trap -` reset to parent
#   bash の subshell isolation 仕様への依存性を assert する。POSIX/bash 5.x で stable な
#   仕様だが、仕様変更で leak しなくなった場合は本 TC が fail する設計 (期待動作)。
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
direct_out=""; direct_err=""; direct_rc=""
run_bash_c "$direct_script" direct_out direct_err direct_rc

if check_inner_bash_clean "TC-1" "$direct_out" "$direct_err" "$direct_rc"; then
  assert_contains "TC-1.a: MAIN_DONE が出力される" "MAIN_DONE" "$direct_out"
  assert_not_contains "TC-1.b: 直接呼び出しで OUTER_TRAP は leak する (bash 仕様依存性 assert)" "OUTER_TRAP" "$direct_out"
fi

# ---------------------------------------------------------------
# TC-2 (positive control): Command substitution `$()` isolates trap
#   parent OUTER_TRAP が保持されること、かつ INNER_TRAP が parent shell に
#   leak しないこと (subshell 境界が双方向に効いている) を assert する。
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
subshell_out=""; subshell_err=""; subshell_rc=""
run_bash_c "$subshell_script" subshell_out subshell_err subshell_rc

if check_inner_bash_clean "TC-2" "$subshell_out" "$subshell_err" "$subshell_rc"; then
  assert_contains "TC-2.a: function output が capture される" "MAIN result=function_output" "$subshell_out"
  assert_contains "TC-2.b: parent OUTER_TRAP が保持される (subshell isolation)" "OUTER_TRAP" "$subshell_out"
  assert_not_contains "TC-2.c: INNER_TRAP は subshell 内に閉じる (parent leak 不在)" "INNER_TRAP" "$subshell_out"
fi

# ---------------------------------------------------------------
# TC-3 (semantic check): flow-state-update.sh が subshell-isolating context で
#   `_resolve_session_state_path` を呼ぶ。allowlist 方式で legitimate な isolation
#   形式を全て受理し、それ以外は direct として flag する (反転ロジック)。
# ---------------------------------------------------------------
echo ""
echo "=== TC-3: flow-state-update.sh uses subshell-isolating contexts ==="

# 関数定義行 (`_resolve_session_state_path()`) と コメント行を除外して呼び出し行を抽出
# (コメント検出: 行頭から `_resolve_session_state_path` までの間に `#` がある場合)
call_lines=$(grep -nE '_resolve_session_state_path' "$TARGET_SCRIPT" \
  | grep -vE ':[[:space:]]*#' \
  | grep -vE ':_resolve_session_state_path[[:space:]]*\(\)' \
  | grep -vE '^[0-9]+:[^_]*#[^_]*_resolve_session_state_path' || true)

if [ -z "$call_lines" ]; then
  echo "  ❌ TC-3.precond: _resolve_session_state_path への参照が 1 件も見つかりません"
  FAIL=$((FAIL+1))
  FAILED_NAMES+=("TC-3.precond")
else
  # Allowlist 方式: 以下のいずれかにマッチ → subshell-isolating (legitimate)
  #   - command substitution: `$(...)` (内部空白許容)
  #   - backtick: `` `...` `` (内部空白許容)
  #   - process substitution: `<(...)` / `> >(...)` (内部空白許容)
  #   - pipeline (左辺): `... | ` (関数を左辺で呼ぶと producer が subshell に閉じる)
  #   - background: `... &` (& 末尾、ただし `&&` 連結は除外)
  isolating_regex='\$\([[:space:]]*_resolve_session_state_path|`[[:space:]]*_resolve_session_state_path|<[[:space:]]*\([[:space:]]*_resolve_session_state_path|_resolve_session_state_path[^|&]*\|[^|]|_resolve_session_state_path[^&]*&([[:space:]]|$)'

  isolating_count=0
  direct_count=0
  total=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    total=$((total + 1))
    if echo "$line" | grep -qE "$isolating_regex"; then
      isolating_count=$((isolating_count + 1))
    else
      direct_count=$((direct_count + 1))
      echo "  [DEBUG] non-isolating call: $line"
    fi
  done <<< "$call_lines"

  # TC-3.a: 全行が isolating であること (mixed mutation 検出のため total 一致を assert)
  if [ "$isolating_count" -eq "$total" ] && [ "$total" -ge 1 ]; then
    echo "  ✅ TC-3.a: 全 ${total} 件の呼び出しが subshell-isolating context"
    PASS=$((PASS+1))
  else
    echo "  ❌ TC-3.a: 期待は all-isolating だが ${isolating_count}/${total} 件のみ"
    FAIL=$((FAIL+1))
    FAILED_NAMES+=("TC-3.a")
  fi

  # TC-3.b: direct call (subshell wrapping なし) が 0 件であること
  if [ "$direct_count" -eq 0 ]; then
    echo "  ✅ TC-3.b: direct call (subshell wrapping なし) は 0 件"
    PASS=$((PASS+1))
  else
    echo "  ❌ TC-3.b: direct call が ${direct_count} 件検出された (上記 [DEBUG] 行を確認)"
    FAIL=$((FAIL+1))
    FAILED_NAMES+=("TC-3.b")
  fi
fi

# ---------------------------------------------------------------
# TC-4 (edge cases): nested function call / set -e (positive + negative)
# ---------------------------------------------------------------
echo ""
echo "=== TC-4: Edge cases (nested call, set -e) ==="

# TC-4.a: nested direct call で MAIN_TRAP と OUTER_FN_TRAP の両方が消える
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
nested_out=""; nested_err=""; nested_rc=""
run_bash_c "$nested_script" nested_out nested_err nested_rc

if check_inner_bash_clean "TC-4.a" "$nested_out" "$nested_err" "$nested_rc"; then
  assert_not_contains "TC-4.a.1: nested direct で MAIN_TRAP が消える" "MAIN_TRAP" "$nested_out"
  assert_not_contains "TC-4.a.2: nested direct で OUTER_FN_TRAP も消える" "OUTER_FN_TRAP" "$nested_out"
fi

# TC-4.b: set -e + subshell で OUTER_TRAP 保持 (positive)
sete_subshell_script='
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
sete_sub_out=""; sete_sub_err=""; sete_sub_rc=""
run_bash_c "$sete_subshell_script" sete_sub_out sete_sub_err sete_sub_rc

if check_inner_bash_clean "TC-4.b" "$sete_sub_out" "$sete_sub_err" "$sete_sub_rc"; then
  assert_contains "TC-4.b: set -e + subshell で OUTER_TRAP 保持" "OUTER_TRAP" "$sete_sub_out"
fi

# TC-4.c: set -e + direct call で OUTER_TRAP が消える (negative twin)
sete_direct_script='
set -e
f() {
  trap "echo INNER_TRAP" EXIT
  trap - EXIT INT TERM HUP
}
trap "echo OUTER_TRAP" EXIT
f
echo MAIN_DONE
'
sete_dir_out=""; sete_dir_err=""; sete_dir_rc=""
run_bash_c "$sete_direct_script" sete_dir_out sete_dir_err sete_dir_rc

if check_inner_bash_clean "TC-4.c" "$sete_dir_out" "$sete_dir_err" "$sete_dir_rc"; then
  assert_contains "TC-4.c.1: set -e + direct でも MAIN_DONE が出力される" "MAIN_DONE" "$sete_dir_out"
  assert_not_contains "TC-4.c.2: set -e + direct で OUTER_TRAP は消える (negative twin)" "OUTER_TRAP" "$sete_dir_out"
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
