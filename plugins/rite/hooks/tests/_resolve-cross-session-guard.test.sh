#!/bin/bash
# Tests for hooks/_resolve-cross-session-guard.sh — cross-session legacy classification helper.
#
# Background (verified-review cycle 41 CG-1): Helper is invoked by both writer
# (flow-state-update.sh) and reader (state-read.sh) layers, but had no direct test
# until cycle 41. caller 経由の indirect test では仕様変更時の片肺更新 drift を
# caller grep に依存して検出するため、本 helper の output schema (5 classification +
# printf trailing-newline-less semantics + mktemp 失敗 WARNING) を直接 stdout 比較で pin する。
#
# Output classifications under test (semantic anchor for drift detection):
#   - "empty"             — legacy file missing / size 0 / .session_id null
#   - "same"              — legacy.session_id == current_sid
#   - "foreign:<UUID>"    — legacy.session_id != current_sid (validated UUID)
#   - "corrupt:<jq_rc>"   — jq parse failure (rc=4 typical, rc=5 IO)
#   - "invalid_uuid:1"    — legacy.session_id JSON-parseable but UUID validation fails
#
# Usage: bash plugins/rite/hooks/tests/_resolve-cross-session-guard.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../_resolve-cross-session-guard.sh"

if [ ! -x "$HOOK" ]; then
  echo "ERROR: _resolve-cross-session-guard.sh missing or not executable: $HOOK" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi

PASS=0
FAIL=0
FAILED_NAMES=()

# Form B cleanup pattern (bash-trap-patterns.md "cleanup 関数の契約" 節)
cleanup_files=()
_cross_session_test_cleanup() {
  local f
  for f in "${cleanup_files[@]:-}"; do
    [ -n "$f" ] && [ -e "$f" ] && rm -f "$f"
  done
  return 0
}
trap '_cross_session_test_cleanup' EXIT
trap '_cross_session_test_cleanup; exit 130' INT
trap '_cross_session_test_cleanup; exit 143' TERM
trap '_cross_session_test_cleanup; exit 129' HUP

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  ✅ $name"
    PASS=$((PASS+1))
  else
    echo "  ❌ $name"
    echo "     expected: '$expected'"
    echo "     actual:   '$actual'"
    FAIL=$((FAIL+1))
    FAILED_NAMES+=("$name")
  fi
}

CURR_SID="11111111-1111-1111-1111-111111111111"
OTHER_SID="22222222-2222-2222-2222-222222222222"

# mktemp_legacy: returns a fresh tempfile path on stdout.
# IMPORTANT: cleanup_files registration MUST be performed by the caller in the
# parent shell, NOT inside this function. command substitution `legacy=$(mktemp_legacy)`
# runs the function in a subshell, so any `cleanup_files+=(...)` here would be
# lost when the subshell exits. Pattern is symmetric with state-read.test.sh's
# `SBX=$(make_sandbox); cleanup_dirs+=("$SBX")`.
mktemp_legacy() {
  local f
  f=$(mktemp /tmp/rite-cross-session-test-XXXXXX) || { echo "ERROR: mktemp failed" >&2; exit 1; }
  echo "$f"
}

# --- TC-1: legacy file missing → "empty" ---
echo "TC-1: legacy file missing → 'empty'"
nonexistent="/tmp/rite-cross-session-test-nonexistent-$$"
result=$(bash "$HOOK" "$nonexistent" "$CURR_SID")
assert_eq "TC-1.1: missing file → 'empty'" "empty" "$result"

# --- TC-2: legacy file size 0 → "empty" ---
echo "TC-2: legacy file size 0 → 'empty'"
legacy=$(mktemp_legacy); cleanup_files+=("$legacy")
: > "$legacy"
result=$(bash "$HOOK" "$legacy" "$CURR_SID")
assert_eq "TC-2.1: size 0 → 'empty'" "empty" "$result"

# --- TC-3: .session_id absent (null) → "empty" ---
echo "TC-3: .session_id absent (jq // empty) → 'empty'"
legacy=$(mktemp_legacy); cleanup_files+=("$legacy")
printf '%s' '{"phase":"x","issue_number":42}' > "$legacy"
result=$(bash "$HOOK" "$legacy" "$CURR_SID")
assert_eq "TC-3.1: missing .session_id → 'empty'" "empty" "$result"

# --- TC-4: legacy.session_id == current_sid → "same" ---
echo "TC-4: legacy.session_id == current_sid → 'same'"
legacy=$(mktemp_legacy); cleanup_files+=("$legacy")
printf '%s' "{\"phase\":\"x\",\"session_id\":\"$CURR_SID\"}" > "$legacy"
result=$(bash "$HOOK" "$legacy" "$CURR_SID")
assert_eq "TC-4.1: same sid → 'same'" "same" "$result"

# --- TC-5: legacy.session_id != current_sid (valid UUID) → "foreign:<UUID>" ---
echo "TC-5: legacy.session_id != current_sid (valid UUID) → 'foreign:<UUID>'"
legacy=$(mktemp_legacy); cleanup_files+=("$legacy")
printf '%s' "{\"phase\":\"x\",\"session_id\":\"$OTHER_SID\"}" > "$legacy"
result=$(bash "$HOOK" "$legacy" "$CURR_SID")
assert_eq "TC-5.1: foreign valid UUID → 'foreign:<other_sid>'" "foreign:$OTHER_SID" "$result"

# --- TC-6: corrupt JSON → "corrupt:<jq_rc>" ---
echo "TC-6: corrupt JSON → 'corrupt:<jq_rc>' (jq exit code embedded)"
legacy=$(mktemp_legacy); cleanup_files+=("$legacy")
printf '%s' '{corrupt invalid json' > "$legacy"
result=$(bash "$HOOK" "$legacy" "$CURR_SID")
case "$result" in
  corrupt:[0-9]*)
    # rc は jq の実 exit code (4=parse error が典型)
    rc_part="${result#corrupt:}"
    if [ "$rc_part" -ge 1 ]; then
      echo "  ✅ TC-6.1: corrupt → 'corrupt:$rc_part' (rc=$rc_part >= 1)"
      PASS=$((PASS+1))
    else
      echo "  ❌ TC-6.1: rc=$rc_part is not >= 1 (expected actual jq exit code, F-03 fix revert?)"
      FAIL=$((FAIL+1))
      FAILED_NAMES+=("TC-6.1: jq_rc embedding")
    fi
    ;;
  *)
    echo "  ❌ TC-6.1: result '$result' did not match 'corrupt:<rc>' pattern"
    FAIL=$((FAIL+1))
    FAILED_NAMES+=("TC-6.1: corrupt classification")
    ;;
esac

# --- TC-7: legacy.session_id JSON-parseable but invalid UUID → "invalid_uuid:1" ---
echo "TC-7: legacy.session_id JSON-parseable but invalid UUID → 'invalid_uuid:1' (cycle 36 F-16)"
legacy=$(mktemp_legacy); cleanup_files+=("$legacy")
printf '%s' '{"phase":"x","session_id":"not-a-uuid"}' > "$legacy"
result=$(bash "$HOOK" "$legacy" "$CURR_SID")
assert_eq "TC-7.1: invalid UUID → 'invalid_uuid:1'" "invalid_uuid:1" "$result"

# --- TC-8: legacy.session_id with shell metachar → 'invalid_uuid:1' (defense-in-depth) ---
echo "TC-8: legacy.session_id with shell metachar → 'invalid_uuid:1' (defense-in-depth)"
legacy=$(mktemp_legacy); cleanup_files+=("$legacy")
printf '%s' '{"phase":"x","session_id":"$(rm /tmp/x)"}' > "$legacy"
result=$(bash "$HOOK" "$legacy" "$CURR_SID")
assert_eq "TC-8.1: shell metachar UUID → 'invalid_uuid:1'" "invalid_uuid:1" "$result"

# --- TC-9: printf trailing-newline-less semantics ---
# Caller (state-read.sh / flow-state-update.sh) uses parameter expansion `${classification#foreign:}`
# to strip prefix. If helper appended trailing newline, the captured value would carry a stray \n.
# Verify the entire stdout has NO trailing newline.
#
# PR #688 followup: cycle 41 review F-05 HIGH — 旧実装は bash command substitution の trailing
# newline 自動 strip 仕様により、helper が `printf "%s\n"` (改行付き) に regress しても test が
# pass する false-positive 構造だった (`raw_out=$(...; echo END)` で末尾 NL が strip され両ケース
# 同形状)。bytes-exact pin に変更し、helper stdout を tempfile に書き出して `wc -c` で実バイト数
# を比較する (`echo END` 経由ではなく直接 redirect で trailing NL を保持)。
echo "TC-9: printf no trailing newline (caller parameter expansion safety)"
legacy=$(mktemp_legacy); cleanup_files+=("$legacy")
printf '%s' "{\"phase\":\"x\",\"session_id\":\"$OTHER_SID\"}" > "$legacy"
# Capture helper stdout to tempfile (preserves trailing NL exactly as helper wrote it).
helper_stdout=$(mktemp); cleanup_files+=("$helper_stdout")
bash "$HOOK" "$legacy" "$CURR_SID" > "$helper_stdout"
expected_str="foreign:$OTHER_SID"
expected_bytes=$(printf '%s' "$expected_str" | wc -c | tr -d ' ')
actual_bytes=$(wc -c < "$helper_stdout" | tr -d ' ')
if [ "$actual_bytes" = "$expected_bytes" ]; then
  echo "  ✅ TC-9.1: helper output is exactly $expected_bytes bytes (no trailing newline)"
  PASS=$((PASS+1))
else
  echo "  ❌ TC-9.1: helper output bytes mismatch (expected: $expected_bytes, actual: $actual_bytes)"
  echo "       expected content: '$expected_str'"
  echo "       actual content (od -c):"
  od -c "$helper_stdout" | head -2 | sed 's/^/         /'
  FAIL=$((FAIL+1))
  FAILED_NAMES+=("TC-9.1: trailing newline detected (bytes mismatch)")
fi
rm -f "$helper_stdout"

# --- TC-10: missing arguments → exit 1 ---
echo "TC-10: missing arguments → exit 1 with usage error"
output=$(bash "$HOOK" 2>&1; echo "_EXIT_$?") || true
exit_marker=$(printf '%s' "$output" | grep -oE '_EXIT_[0-9]+$' | tail -1)
if [ "$exit_marker" = "_EXIT_1" ] && printf '%s' "$output" | grep -qF "usage:"; then
  echo "  ✅ TC-10.1: missing args → exit 1 + usage message"
  PASS=$((PASS+1))
else
  echo "  ❌ TC-10.1: did not fail-fast on missing args"
  echo "     output: $output"
  FAIL=$((FAIL+1))
  FAILED_NAMES+=("TC-10.1: missing args fail-fast")
fi

# --- TC-11: only one argument → exit 1 ---
echo "TC-11: only legacy_path argument (missing current_sid) → exit 1"
output=$(bash "$HOOK" "/tmp/x" 2>&1; echo "_EXIT_$?") || true
exit_marker=$(printf '%s' "$output" | grep -oE '_EXIT_[0-9]+$' | tail -1)
assert_eq "TC-11.1: missing current_sid → exit 1" "_EXIT_1" "$exit_marker"

# --- TC-12: Empty current_sid → exit 1 ---
echo "TC-12: empty current_sid argument → exit 1"
output=$(bash "$HOOK" "/tmp/x" "" 2>&1; echo "_EXIT_$?") || true
exit_marker=$(printf '%s' "$output" | grep -oE '_EXIT_[0-9]+$' | tail -1)
assert_eq "TC-12.1: empty current_sid → exit 1" "_EXIT_1" "$exit_marker"

# --- TC-13: classification 6 値 enumeration source-pin metatest (drift detection) ---
# helper file 内に classification token (`empty` / `same` / `foreign:` / `corrupt:` / `invalid_uuid:`)
# が printf として残っていることを grep で pin。caller (state-read.sh / flow-state-update.sh) の
# case statement と整合を保つための drift 検出。
#
# F-10 (LOW, PR #688 cycle 9 review): cycle 39 H-01 で追加された `printf 'corrupt:126'` (合計 6 token に
# 拡張) を TC-13 に追加。本 fallback は `_resolve-session-id.sh` 不在時の collapse-prevention emit で、
# 削除されると helper 不在時に `invalid_uuid:1` に collapse し root cause 診断時の区別が失われる
# silent regression を起こす。`printf 'corrupt:%d'` (生 jq rc 経路) と区別するため `corrupt:126` literal を pin。
echo "TC-13: source-pin 6 classifications via grep (drift detection)"
helper_path="$HOOK"
expected_tokens=(
  "printf 'empty'"
  "printf 'same'"
  "printf 'foreign:%s'"
  "printf 'corrupt:%d'"
  "printf 'corrupt:126'"
  "printf 'invalid_uuid:1'"
)
for token in "${expected_tokens[@]}"; do
  if grep -qF "$token" "$helper_path"; then
    echo "  ✅ TC-13: helper contains '$token'"
    PASS=$((PASS+1))
  else
    echo "  ❌ TC-13: helper missing '$token' (classification API drift)"
    FAIL=$((FAIL+1))
    FAILED_NAMES+=("TC-13: missing classification token '$token'")
  fi
done

# --- Summary ---
echo ""
echo "─── _resolve-cross-session-guard.test.sh summary ──────────────────────────"
echo "PASS: $PASS"
echo "FAIL: $FAIL"
if [ $FAIL -gt 0 ]; then
  echo ""
  echo "Failed tests:"
  for n in "${FAILED_NAMES[@]}"; do echo "  - $n"; done
  exit 1
fi
echo "All tests passed."
exit 0
