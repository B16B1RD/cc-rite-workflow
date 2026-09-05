#!/bin/bash
# Contract tests for the fatal triage (致命性仕分け) contract in skills/fix/SKILL.md.
#
# 仕分けの判定そのものは scripts/review-findings-maps.sh 側にあり
# scripts/tests/review-findings-maps.test.sh が実挙動で pin する。本スイートが守るのは
# **SKILL.md 側の契約記述** — helper が no-op になる経路と、移送分を記録できない経路で
# fix が何をするかの規定。ここが消えると helper は無傷のまま「移送分が無記録で消える」に戻る。
#
# T-01 Priority 3 の非永続経路は fail-loud で停止する (Issue §4.4 MUST: 移送分を捨てない)
# T-02 移送件数の読み取り失敗を 0 へ倒さない (fail-loud、guard 自身の無効化を防ぐ)
# T-03 marker 不在経路 (会話 / legacy Markdown) では consumer 式を適用しない
# T-04 ステップ 2.1 の選択 UI が marker の有無で分岐する (AC-6)
# T-05 P3 の新 reason が reason 表と Eval-order enumeration の両方に登録されている
# T-06 helper が emit しない reason を SKILL.md 側が語彙として残していない
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"

PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
FIX="$PLUGIN_ROOT/skills/fix/SKILL.md"
MAPS="$PLUGIN_ROOT/scripts/review-findings-maps.sh"

echo "=== fix/SKILL.md 致命性仕分け契約 ==="

assert_file_exists_or_fail "fix/SKILL.md exists" "$FIX" || true
assert_file_exists_or_fail "review-findings-maps.sh exists" "$MAPS" || true

# --- T-01: P3 非永続経路の fail-loud ---
assert_grep "T-01 P3 の非永続移送で [fix:error] へ昇格する" "$FIX" \
  '\[fix:error\] reason=p3_triage_not_persistable'
assert_grep "T-01 停止理由に移送件数を添える" "$FIX" \
  'reason=p3_triage_not_persistable; moved='

# --- T-02: 移送件数の読み取り失敗を 0 へ倒さない ---
# `p3_moved=$(jq ...) || p3_moved=""` + 数値 case という旧形は、jq 失敗を「移送 0 件」に化けさせて
# 直後の fail-loud guard を必ず skip させる。else 節形式で rc を捕捉していることを pin する。
assert_grep "T-02 移送件数の probe が else 節形式で rc を捕捉する" "$FIX" \
  'if p3_moved=\$\(jq '
assert_grep "T-02 probe 失敗は専用 reason で停止する" "$FIX" \
  '\[fix:error\] reason=p3_triage_moved_probe_failed'
assert_not_grep "T-02 jq 失敗を空文字へ倒す旧形が残っていない" "$FIX" \
  '\) \|\| p3_moved=""'

# --- T-03: marker 不在経路では consumer 式を適用しない ---
assert_grep "T-03 marker 不在経路で consumer 式を適用しない旨の規定がある" "$FIX" \
  'それらの経路では consumer 式を適用してはならない'
assert_grep "T-03 marker 不在経路でも Raw JSON は仕分け対象と明記する" "$FIX" \
  'Priority 3 が tempfile 経由で通す Raw JSON'
assert_grep "T-03 marker 不在経路では非致命も従来どおり修正対象に残す" "$FIX" \
  '従来どおり修正対象にする'

# --- T-04: ステップ 2.1 の選択 UI が marker の有無で分岐する ---
assert_grep "T-04 marker ありでは致命だけを並べる" "$FIX" \
  'marker あり\).*手動起動時に並ぶのは致命 finding だけ'
assert_grep "T-04 marker 不在では非致命 gated も選択肢に並べる" "$FIX" \
  'marker 不在の経路.*非致命 gated finding も選択肢に並べる'

# --- T-05: 新 reason の documented-union 登録 ---
# emit 箇所だけ増えて reason 表 / Eval-order enumeration が追従しない drift を塞ぐ。
_eval_order=$(grep -n 'Eval-order enumeration.*emit reasons sequence' "$FIX" | head -1 | cut -d: -f1)
if [ -z "$_eval_order" ]; then
  fail "T-05 Eval-order enumeration 行を特定できない (見出し文言の drift)"
else
  _eval_line=$(sed -n "${_eval_order}p" "$FIX")
  for _r in p3_triage_moved_probe_failed p3_triage_not_persistable; do
    if printf '%s' "$_eval_line" | grep -q "$_r"; then
      pass "T-05 $_r が Eval-order enumeration に登録されている"
    else
      fail "T-05 $_r が Eval-order enumeration に無い"
    fi
    # reason 表 (先頭が `| \`reason\` |` の行) にも登録されていること
    if grep -qE "^\| \`$_r\` \|" "$FIX"; then
      pass "T-05 $_r が reason 表に登録されている"
    else
      fail "T-05 $_r が reason 表に無い"
    fi
  done
fi

# --- T-06: helper が emit しない reason を語彙として残さない ---
# helper 側の自己検証撤去に SKILL.md が追従しないと、存在しない検査を原因として案内することになる。
if grep -q 'fatal_triage_id_union_violation' "$MAPS"; then
  assert_grep "T-06 helper が emit する reason は SKILL.md にも載る" "$FIX" \
    'fatal_triage_id_union_violation'
else
  assert_not_grep "T-06 helper が emit しない reason を SKILL.md が残していない" "$FIX" \
    'fatal_triage_id_union_violation'
fi

if ! print_summary "$(basename "$0")" "fatal triage contract drift — check fix/SKILL.md ステップ 1.2.0 / 1.3 / 2.1"; then
  exit 1
fi
