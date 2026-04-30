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

echo "TC-5: workflow-incident-emit.sh 不在で WARNING + exit 0 + canonical fallback sentinel emit (F-04)"
sandbox=$(make_fake_emit_dir missing)
cleanup_dirs+=("$sandbox")
if out=$(run_helper_in_sandbox "$sandbox" foreign reader sid1 sid2 2>&1); then rc=0; else rc=$?; fi
assert_eq "TC-5.1: exit code is 0 (caller 後段 DEFAULT 降格を阻害しない)" "0" "$rc"
assert_match "TC-5.2: WARNING contains 'workflow-incident-emit.sh missing'" "workflow-incident-emit.sh missing" "$out"
assert_match "TC-5.3: WARNING records type for fallback audit" "type=cross_session_takeover_refused" "$out"
# F-04 (MEDIUM, PR #688 cycle 9 review): cycle 38 F-08 で導入された canonical fallback sentinel
# `[CONTEXT] WORKFLOW_INCIDENT=1; type=...; details=...; root_cause_hint=...; iteration_id=...` の
# emit を assert する。旧実装は WARNING 行のみ確認しており、helper の fallback emit ブロックが
# silent regress (`exit 0` のみに巻き戻される / sentinel format が壊される) しても TC-5 が pass
# する false-positive 経路があった。Phase 5.4.4.1 orchestrator detection が break する CRITICAL gap
# を test 側で守る。
assert_match "TC-5.4: fallback sentinel emitted (F-04)" "[CONTEXT] WORKFLOW_INCIDENT=1" "$out"
assert_match "TC-5.5: fallback sentinel has type field (F-04)" "type=cross_session_takeover_refused" "$out"
assert_match "TC-5.6: fallback sentinel has root_cause_hint (F-04)" "root_cause_hint=legacy_belongs_to_another_session_use_create_mode" "$out"
rm -rf "$sandbox"

echo "TC-6: foreign 正常 emit (details 構成検証 + redaction — F-07)"
sandbox=$(make_fake_emit_dir ok)
cleanup_dirs+=("$sandbox")
# F-07 (MEDIUM): session_id / legacy path は先頭 8 文字 + *** に redact される
# - current-uuid (12 文字) → current-***
# - legacy-uuid (11 文字、先頭 8 文字 = "legacy-u") → legacy-u***
if out=$(run_helper_in_sandbox "$sandbox" foreign reader "current-uuid" "legacy-uuid" 2>&1); then rc=0; else rc=$?; fi
assert_eq "TC-6.1: exit code is 0" "0" "$rc"
assert_match "TC-6.2: emit type is cross_session_takeover_refused" "type=cross_session_takeover_refused" "$out"
assert_match "TC-6.3: details has layer=reader" "layer=reader" "$out"
assert_match "TC-6.4: details has redacted current_sid (F-07)" "current_sid=current-***" "$out"
assert_match "TC-6.5: details has redacted legacy_sid (F-07)" "legacy_sid=legacy-u***" "$out"
assert_match "TC-6.6: root_cause_hint = legacy_belongs_to_another_session_use_create_mode" "hint=legacy_belongs_to_another_session_use_create_mode" "$out"
# F-07 negative assertion: full UUID が details に含まれないこと (silent regression 防止)
# `current_sid=current-uuid` が details に **literal で含まれない** ことを inline grep で確認。
# `assert_no_match` ヘルパは未実装のため、`! grep -q` + `assert_eq "0" "$rc"` で表現する
# (FAIL 時に redacted 化が regression したことを明示する)。
if echo "$out" | grep -q "current_sid=current-uuid[^*]"; then
  rc_neg=1
else
  rc_neg=0
fi
assert_eq "TC-6.7: full current_sid 'current-uuid' must NOT appear unredacted in details (F-07)" "0" "$rc_neg"
rm -rf "$sandbox"

echo "TC-7: corrupt 正常 emit (extra_arg=jq_rc 検証 + redaction — F-07)"
sandbox=$(make_fake_emit_dir ok)
cleanup_dirs+=("$sandbox")
# F-13 (LOW): corrupt / invalid_uuid arm では path を basename + `.../` prefix の形に降格
# (旧 F-07 の 8-char redaction は incident response 時に「どの project / flow-state file か」が
# 特定不能になる UX 退行を生むため、cycle 9 verified-review F-13 で basename 形式に移行)
# - /path/to/legacy → .../legacy
if out=$(run_helper_in_sandbox "$sandbox" corrupt writer "current-uuid" "/path/to/legacy" "4" 2>&1); then rc=0; else rc=$?; fi
assert_eq "TC-7.1: exit code is 0" "0" "$rc"
assert_match "TC-7.2: emit type is legacy_state_corrupt" "type=legacy_state_corrupt" "$out"
assert_match "TC-7.3: details has layer=writer" "layer=writer" "$out"
assert_match "TC-7.4: details has basename-redacted path (F-13)" "path=.../legacy" "$out"
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
# F11-14 (LOW): TC-7.4 と対称的に invalid_uuid arm でも basename redaction (F-13) を pin する。
# `_path_basename` 関数が corrupt と invalid_uuid の両方で使われるため、片方だけ pin だと
# 将来 invalid_uuid arm が `_redact_sid` (8-char redact 形式) に revert された場合 silently pass する盲点があった。
assert_match "TC-8.5: details has basename-redacted path (F-13 symmetry with TC-7.4)" "path=.../legacy" "$out"
rm -rf "$sandbox"

echo "TC-9 (PR #688 cycle 13 F-04): fallback path で details / hint の sanitize 動作を direct verify"
# F-04 検証: 旧 TC-5 系列は input が clean な状態でしか fallback sentinel を verify していなかった。
# sanitize logic (`tr -d '[:cntrl:]' | tr ';' ','`) を no-op (cat) に mutate しても全 TC が pass する
# false-negative 経路があった (test-reviewer Likelihood-Evidence: runtime_observation で実証)。
# 制御文字 (newline) / `;` を current_sid に inject して fallback sentinel に sanitize が適用される
# ことを assert する。
sandbox=$(make_fake_emit_dir missing)
cleanup_dirs+=("$sandbox")
# bash ANSI-C quoting で newline + `;` を含む 11 chars 文字列を生成 ("foo;bar\nbaz")
# redact_sid は length >= 8 なら最初の 8 chars + "***" を返す。最初の 8 chars は "foo;bar\n"。
# sanitize で newline strip → "foo;bar***" 、`;` → `,` で → "foo,bar***" になることを verify。
control_sid=$'foo;bar\nbaz'
if out=$(run_helper_in_sandbox "$sandbox" foreign reader "$control_sid" "legacy-uuid-12chars" 2>&1); then rc=0; else rc=$?; fi
assert_eq "TC-9.1: exit code is 0 (fallback path 経由)" "0" "$rc"
assert_match "TC-9.2: fallback sentinel emitted" "[CONTEXT] WORKFLOW_INCIDENT=1" "$out"
# sentinel line を抽出 (WARNING line とは別)
sentinel_line=$(printf '%s\n' "$out" | grep '\[CONTEXT\] WORKFLOW_INCIDENT=1' || true)
# TC-9.3 (informational): grep '[CONTEXT] WORKFLOW_INCIDENT=1' は match 行のみを出力するため、
# sentinel 内に literal newline が embed されてもマッチ行は 1 行に切り詰められて常に wc -l == 1 になる
# (実証: printf '[CONTEXT]...\nbaz; rest\n' | grep '\[CONTEXT\]' | wc -l → 1)。
# したがって本 assertion は単独では「newline が tr -d '[:cntrl:]' で除去された」mutation kill
# 能力を持たない (verified-review F-05 で指摘)。実際の sanitize 動作の kill power は TC-9.4
# (current_sid=foo; の負 grep) と TC-9.5 (current_sid=foo,bar*** の正 grep) が担う。
# 本 assertion は「sentinel が `[CONTEXT]` で始まる単一行として grep 抽出可能であること」の
# 整合性確認のみを保証する informational assertion として残す。
sentinel_line_count=$(printf '%s\n' "$sentinel_line" | wc -l | tr -d ' ')
assert_eq "TC-9.3 (informational): sentinel が [CONTEXT] で始まる単一マッチ行として grep 抽出可能 (kill power は TC-9.4/9.5 が担う)" "1" "$sentinel_line_count"
# negative assertion: literal `;` が details 内に残っていないこと (sanitize が適用された証拠)
if printf '%s' "$sentinel_line" | grep -q "current_sid=foo;"; then
  rc_negative=1
else
  rc_negative=0
fi
assert_eq "TC-9.4: sentinel に literal ';' が残っていない (tr ';' ',' 適用)" "0" "$rc_negative"
# positive assertion: `;` → `,` 置換結果 "foo,bar***" が含まれる
assert_match "TC-9.5: sentinel に sanitize 後の 'foo,bar***' が含まれる" "current_sid=foo,bar***" "$sentinel_line"
rm -rf "$sandbox"

echo "TC-10 (PR #688 cycle 13 F-04): 0x07 (BEL) など複数の制御文字も全て strip される"
# `tr -d '[:cntrl:]'` は newline 以外にも tab / BEL (0x07) / form feed / DEL (0x7F) 等 0x00-0x1F + 0x7F を
# すべて strip する。BEL 注入で defense-in-depth の completeness を verify する。
sandbox=$(make_fake_emit_dir missing)
cleanup_dirs+=("$sandbox")
# $'\a' = BEL (0x07)、$'\t' = tab (0x09)
# 8 chars 以上を確保: "fooBARQUUX" (10 chars) + BEL 注入
bell_sid=$'foo\aBAR\tQUUX'  # 12 chars: f o o BEL B A R TAB Q U U X
if out=$(run_helper_in_sandbox "$sandbox" foreign reader "$bell_sid" "legacy-uuid-12chars" 2>&1); then rc=0; else rc=$?; fi
assert_eq "TC-10.1: exit code is 0" "0" "$rc"
sentinel_line=$(printf '%s\n' "$out" | grep '\[CONTEXT\] WORKFLOW_INCIDENT=1' || true)
# negative: BEL / tab が strip されていることを byte-level で verify
# bash の `[[ ... =~ $'\a' ]]` だと cntrl char regex が portable でないため、tr で count
bell_count=$(printf '%s' "$sentinel_line" | LC_ALL=C grep -c $'\a' || true)
tab_count=$(printf '%s' "$sentinel_line" | LC_ALL=C grep -c $'\t' || true)
assert_eq "TC-10.2: sentinel 内に BEL (0x07) が残っていない" "0" "$bell_count"
assert_eq "TC-10.3: sentinel 内に tab (0x09) が残っていない" "0" "$tab_count"
# 残った非制御部分が emit されている (10 chars - BEL - tab = 10 chars, 最初の 8 chars + ***)
# redact: first 8 chars = "foo\aBAR\t" → sanitize: "fooBAR" (BEL + tab strip) → "fooBAR***"
assert_match "TC-10.4: sanitize 後の 'fooBAR***' が含まれる" "current_sid=fooBAR***" "$sentinel_line"
rm -rf "$sandbox"

echo ""
echo "─── _emit-cross-session-incident.test.sh summary ──────────────────────────"
echo "PASS: $PASS"
echo "FAIL: $FAIL"
# cycle 43 F-01 fix: silent abort regression を再発検出する gate
# 計算根拠: TC-1 (2) + TC-2 (2) + TC-3 (2) + TC-4 (2) + TC-5 (6) + TC-6 (7) + TC-7 (6) + TC-8 (5) +
#          TC-9 (5) + TC-10 (4) = 41 (PR #688 cycle 13 F-04 で TC-9/TC-10 追加で +9)
expected_total=41
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
