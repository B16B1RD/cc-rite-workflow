#!/bin/bash
# Test for _emit-cross-session-incident.sh
#
# 検証範囲 (defensive paths が caller の indirect test で exercise されない):
#   TC-1: $# < 4 で exit 1
#   TC-2: $# > 5 で exit 1 (upper bound check, cycle 37 followup で追加)
#   TC-3: invalid layer で exit 1
#   TC-4: invalid classification で exit 1
#   TC-5: workflow-incident-emit.sh 不在で WARNING + exit 0 (caller 後段 DEFAULT 降格を阻害しない)
#   TC-6: foreign 正常 emit (details 文字列の構成検証)
#   TC-7: corrupt 正常 emit (extra_arg=jq_rc 検証)
#   TC-8: invalid_uuid 正常 emit (root_cause_hint differentiation)

set -euo pipefail

# PR #688 followup: cycle 41 review F-06 MEDIUM — set -uo → set -euo に統一 + Form B
# cleanup trap を追加。旧実装は本ファイルのみ `set -uo pipefail` (set -e なし、他 6 test は
# `set -euo pipefail`) かつ Form B trap 不在で、各 TC 末尾の `rm -rf $sandbox` は INT/TERM
# 中断時に到達せず /tmp/rite-emit-test-XXXXXX を leak していた (state-read.test.sh:32-47 で
# 同型 cleanup pattern を bash-trap-patterns.md "Form B" として確立済み)。
cleanup_dirs=()
_emit_test_cleanup() {
  # cycle 43 F-01 followup: `[ -n ] && [ -d ] && rm` 形式は set -e 下で `[ -d ]` false 時に
  # exit 1 が発火し EXIT trap 経路で script 全体の RC を 1 に汚染していた (sandbox は各 TC 末尾で
  # `rm -rf` 済みのため、cleanup 時には [ -d ] が必ず false を返す経路がある)。
  # if-then-fi 形式に変更して set -e の伝播を遮断する。
  local dir
  for dir in "${cleanup_dirs[@]:-}"; do
    if [ -n "$dir" ] && [ -d "$dir" ]; then
      rm -rf "$dir"
    fi
  done
}
trap '_emit_test_cleanup' EXIT
trap '_emit_test_cleanup; exit 130' INT
trap '_emit_test_cleanup; exit 143' TERM
trap '_emit_test_cleanup; exit 129' HUP

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
HELPER="$REPO_ROOT/plugins/rite/hooks/_emit-cross-session-incident.sh"

if [ ! -x "$HELPER" ]; then
  echo "ERROR: helper not executable: $HELPER" >&2
  exit 1
fi

PASS=0
FAIL=0

assert_eq() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  ✅ $label"
    PASS=$((PASS + 1))
  else
    echo "  ❌ $label"
    echo "       expected: $expected"
    echo "       actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_match() {
  local label="$1"
  local pattern="$2"
  local actual="$3"
  if printf '%s' "$actual" | grep -qF "$pattern"; then
    echo "  ✅ $label"
    PASS=$((PASS + 1))
  else
    echo "  ❌ $label"
    echo "       pattern (literal substring): $pattern"
    echo "       actual: $actual"
    FAIL=$((FAIL + 1))
  fi
}

# Sandbox helper bin so we can simulate workflow-incident-emit.sh availability
make_fake_emit_dir() {
  local mode="$1"  # "ok" / "missing" / "fail"
  local d
  d=$(mktemp -d /tmp/rite-emit-test-XXXXXX)
  case "$mode" in
    ok)
      cat > "$d/workflow-incident-emit.sh" <<'EMIT_OK'
#!/bin/bash
# fake: print invocation args to stdout for assertion
echo "EMIT_CALLED type=$2 details=$4 hint=$6"
exit 0
EMIT_OK
      chmod +x "$d/workflow-incident-emit.sh"
      ;;
    missing)
      : # do not create file
      ;;
    fail)
      cat > "$d/workflow-incident-emit.sh" <<'EMIT_FAIL'
#!/bin/bash
echo "fake emit failure" >&2
exit 7
EMIT_FAIL
      chmod +x "$d/workflow-incident-emit.sh"
      ;;
  esac
  echo "$d"
}

# Run helper with overridden SCRIPT_DIR (helper resolves emit_script via SCRIPT_DIR)
# 直接 helper を実行すると SCRIPT_DIR は本物の hooks/ ディレクトリを返すため、
# fake emit を使うには helper 自体を sandbox にコピーする
run_helper_in_sandbox() {
  local sandbox="$1"; shift
  cp "$HELPER" "$sandbox/_emit-cross-session-incident.sh"
  chmod +x "$sandbox/_emit-cross-session-incident.sh"
  bash "$sandbox/_emit-cross-session-incident.sh" "$@"
}

# Phase 1.2 cycle 43 F-01 (CRITICAL) 対応: set -euo pipefail 下で `out=$(cmd)` の cmd が exit != 0 を
# 返すと command substitution が失敗し set -e が script abort する。これにより TC-1 で abort し
# TC-2〜TC-8 が silent skip する false-confidence test だった (test-reviewer Likelihood-Evidence:
# runtime_observation で実証)。`if out=$(... 2>&1); then rc=0; else rc=$?; fi` 形式に統一する。
echo "TC-1: 引数不足 ($# < 4) で exit 1"
sandbox=$(make_fake_emit_dir ok)
cleanup_dirs+=("$sandbox")
if out=$(run_helper_in_sandbox "$sandbox" foreign reader 2>&1); then rc=0; else rc=$?; fi
assert_eq "TC-1.1: exit code is 1" "1" "$rc"
assert_match "TC-1.2: ERROR message contains '4 arguments required'" "4 arguments required" "$out"
rm -rf "$sandbox"

echo "TC-2: 引数過多 ($# > 5) で exit 1 (cycle 37 followup)"
sandbox=$(make_fake_emit_dir ok)
cleanup_dirs+=("$sandbox")
if out=$(run_helper_in_sandbox "$sandbox" foreign reader sid1 sid2 extra ARG6 ARG7 2>&1); then rc=0; else rc=$?; fi
assert_eq "TC-2.1: exit code is 1" "1" "$rc"
assert_match "TC-2.2: ERROR message contains 'too many arguments'" "too many arguments" "$out"
rm -rf "$sandbox"

echo "TC-3: invalid layer で exit 1"
sandbox=$(make_fake_emit_dir ok)
cleanup_dirs+=("$sandbox")
if out=$(run_helper_in_sandbox "$sandbox" foreign invalid sid1 sid2 2>&1); then rc=0; else rc=$?; fi
assert_eq "TC-3.1: exit code is 1" "1" "$rc"
assert_match "TC-3.2: ERROR contains 'invalid layer'" "invalid layer" "$out"
rm -rf "$sandbox"

echo "TC-4: invalid classification で exit 1"
sandbox=$(make_fake_emit_dir ok)
cleanup_dirs+=("$sandbox")
if out=$(run_helper_in_sandbox "$sandbox" bogus reader sid1 sid2 2>&1); then rc=0; else rc=$?; fi
assert_eq "TC-4.1: exit code is 1" "1" "$rc"
assert_match "TC-4.2: ERROR contains 'unknown classification'" "unknown classification" "$out"
rm -rf "$sandbox"

echo "TC-5: workflow-incident-emit.sh 不在で WARNING + exit 0"
sandbox=$(make_fake_emit_dir missing)
cleanup_dirs+=("$sandbox")
if out=$(run_helper_in_sandbox "$sandbox" foreign reader sid1 sid2 2>&1); then rc=0; else rc=$?; fi
assert_eq "TC-5.1: exit code is 0 (caller 後段 DEFAULT 降格を阻害しない)" "0" "$rc"
assert_match "TC-5.2: WARNING contains 'workflow-incident-emit.sh missing'" "workflow-incident-emit.sh missing" "$out"
assert_match "TC-5.3: WARNING records type for fallback audit" "type=cross_session_takeover_refused" "$out"
rm -rf "$sandbox"

echo "TC-6: foreign 正常 emit (details 構成検証)"
sandbox=$(make_fake_emit_dir ok)
cleanup_dirs+=("$sandbox")
if out=$(run_helper_in_sandbox "$sandbox" foreign reader "current-uuid" "legacy-uuid" 2>&1); then rc=0; else rc=$?; fi
assert_eq "TC-6.1: exit code is 0" "0" "$rc"
assert_match "TC-6.2: emit type is cross_session_takeover_refused" "type=cross_session_takeover_refused" "$out"
assert_match "TC-6.3: details has layer=reader" "layer=reader" "$out"
assert_match "TC-6.4: details has current_sid=current-uuid" "current_sid=current-uuid" "$out"
assert_match "TC-6.5: details has legacy_sid=legacy-uuid" "legacy_sid=legacy-uuid" "$out"
assert_match "TC-6.6: root_cause_hint = legacy_belongs_to_another_session_use_create_mode" "hint=legacy_belongs_to_another_session_use_create_mode" "$out"
rm -rf "$sandbox"

echo "TC-7: corrupt 正常 emit (extra_arg=jq_rc 検証)"
sandbox=$(make_fake_emit_dir ok)
cleanup_dirs+=("$sandbox")
if out=$(run_helper_in_sandbox "$sandbox" corrupt writer "current-uuid" "/path/to/legacy" "4" 2>&1); then rc=0; else rc=$?; fi
assert_eq "TC-7.1: exit code is 0" "0" "$rc"
assert_match "TC-7.2: emit type is legacy_state_corrupt" "type=legacy_state_corrupt" "$out"
assert_match "TC-7.3: details has layer=writer" "layer=writer" "$out"
assert_match "TC-7.4: details has path=/path/to/legacy" "path=/path/to/legacy" "$out"
assert_match "TC-7.5: details has jq_rc=4" "jq_rc=4" "$out"
assert_match "TC-7.6: root_cause_hint = legacy_jq_parse_failed_cannot_verify_session_ownership" "hint=legacy_jq_parse_failed_cannot_verify_session_ownership" "$out"
rm -rf "$sandbox"

echo "TC-8: invalid_uuid 正常 emit (root_cause_hint differentiation)"
sandbox=$(make_fake_emit_dir ok)
cleanup_dirs+=("$sandbox")
if out=$(run_helper_in_sandbox "$sandbox" invalid_uuid reader "current-uuid" "/path/to/legacy" "1" 2>&1); then rc=0; else rc=$?; fi
assert_eq "TC-8.1: exit code is 0" "0" "$rc"
assert_match "TC-8.2: emit type is legacy_state_corrupt (semantically equivalent to corrupt)" "type=legacy_state_corrupt" "$out"
assert_match "TC-8.3: details has reason=invalid_uuid_format (distinguishes from corrupt:*)" "reason=invalid_uuid_format" "$out"
assert_match "TC-8.4: root_cause_hint = legacy_session_id_failed_uuid_validation_tampered_or_legacy_schema" "hint=legacy_session_id_failed_uuid_validation_tampered_or_legacy_schema" "$out"
rm -rf "$sandbox"

echo ""
echo "─── _emit-cross-session-incident.test.sh summary ──────────────────────────"
echo "PASS: $PASS"
echo "FAIL: $FAIL"
# cycle 43 F-01 fix: silent abort regression を再発検出する gate
# 計算根拠: TC-1 (2) + TC-2 (2) + TC-3 (2) + TC-4 (2) + TC-5 (3) + TC-6 (6) + TC-7 (6) + TC-8 (4) = 27
expected_total=27
total=$((PASS + FAIL))
if [ "$total" -lt "$expected_total" ]; then
  echo "ERROR: only $total/$expected_total assertions ran (silent abort regression detected)"
  echo "  原因候補: set -euo pipefail 下で command substitution が exit != 0 で失敗し set -e で script abort"
  echo "  対処: out=\$(cmd) を if out=\$(cmd 2>&1); then rc=0; else rc=\$?; fi 形式に揃える"
  exit 1
fi
if [ "$FAIL" -gt 0 ]; then
  echo "Some tests failed."
  exit 1
fi
echo "All tests passed."
