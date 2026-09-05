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
# T-02d 非空検査を probe より前に置く (readback_failed を到達可能に保つ)
# T-03 marker 不在経路 (会話 / legacy Markdown) では consumer 式を適用しない
# T-04 ステップ 2.1 の選択 UI が marker の有無で分岐する (AC-6)
# T-04b marker 不在時の表示規則が単一 SoT に定義されている
# T-05 P3 の新 reason が reason 表と Eval-order enumeration の両方に登録されている
# T-06 撤去済み reason (fatal_triage_id_union_violation) を helper / SKILL.md が同時に持つか同時に持たない
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
# 2 つの emit site (jq 失敗 / 非数値) を判別子で個別に pin する。存在だけを見ると
# 片方を消しても緑のままになり、消えた側が sentinel なしで exit 1 する
assert_grep "T-02 probe の jq 失敗分岐が rc 付きで停止する" "$FIX" \
  'reason=p3_triage_moved_probe_failed; rc='
assert_grep "T-02 probe の非数値分岐が value 付きで停止する" "$FIX" \
  'reason=p3_triage_moved_probe_failed; value='
assert_grep "T-02 非数値の移送件数でも停止する (0 へ正規化しない)" "$FIX" \
  'case "\$p3_moved" in .*\[!0-9\]'
assert_grep "T-02 probe 失敗は専用 reason で停止する" "$FIX" \
  '\[fix:error\] reason=p3_triage_moved_probe_failed'
assert_not_grep "T-02 jq 失敗を空文字へ倒す旧形が残っていない" "$FIX" \
  '\) \|\| p3_moved=""'

# --- T-02d: 非空検査は probe より前 ---
# 0 バイトファイルに jq を通すと rc=0 / 空出力になるため、順序が逆だと
# p3_triage_readback_failed が到達不能になり一次原因が診断から消える
_p3_empty_line=$(grep -n 'if \[ ! -s "\$p3_triage_file" \]' "$FIX" | head -1 | cut -d: -f1)
_p3_probe_line=$(grep -n 'if p3_moved=\$(jq ' "$FIX" | head -1 | cut -d: -f1)
if [ -n "$_p3_empty_line" ] && [ -n "$_p3_probe_line" ] && [ "$_p3_empty_line" -lt "$_p3_probe_line" ]; then
  pass "T-02d 非空検査が移送件数 probe より前に置かれている"
else
  fail "T-02d 非空検査が probe より後 (empty=$_p3_empty_line probe=$_p3_probe_line) — readback_failed が到達不能になる"
fi

# --- T-03: marker 不在経路では consumer 式を適用しない ---
assert_grep "T-03 marker 不在経路で consumer 式を適用しない旨の規定がある" "$FIX" \
  'それらの経路では consumer 式を適用してはならない'
assert_grep "T-03 Raw JSON も file-based source に含まれると明記する" "$FIX" \
  'Priority 3 が tempfile 経由で通す Raw JSON'
assert_grep "T-03 marker 不在経路では非致命も従来どおり修正対象に残す" "$FIX" \
  '\*\*従来どおり修正対象にする\*\*'

# --- T-04: ステップ 2.1 の選択 UI が marker の有無で分岐する ---
assert_grep "T-04 marker ありでは致命だけを並べる" "$FIX" \
  'marker あり\).*手動起動時に並ぶのは致命 finding だけ'
assert_grep "T-04 marker 不在では非致命 gated も選択肢に並べる" "$FIX" \
  'marker 不在の経路.*非致命 gated finding も選択肢に並べる'

# --- T-04b: marker 不在時の表示規則 ---
# 規則は 1.2.0 (moved_count 系) と 1.4 注記 (fatal_count) の 2 箇所だけに置く。
# 参照側 (4.5.3 / 4.6 / 5.1) が規則本文を再掲すると手書き複製が drift する
assert_grep "T-04b moved_count の marker 不在時規則が 1.2.0 にある" "$FIX" \
  '`{moved_count}件` を `件` ごと `不明 \(FIX_FATAL_TRIAGE marker 不在\)` に置換'
assert_grep "T-04b moved_pointer_suffix の marker 不在時値が定義されている" "$FIX" \
  '`{moved_pointer_suffix}` は空文字列にする'
assert_grep "T-04b fatal_count の規則は 1.4 注記が SoT と委譲されている" "$FIX" \
  '規則はそこの注記を SoT とする'
assert_grep "T-04b 1.4 の marker 不在時は severity 限定しない見出しへ差し替える" "$FIX" \
  '### 未対応の指摘（全 severity 帯）'
# 規則本文の手書き複製が増えていないこと (1.2.0 の 1 箇所だけ)
_nb_rule_count=$(grep -c '不明 (FIX_FATAL_TRIAGE marker 不在)' "$FIX")
if [ "$_nb_rule_count" = "1" ]; then
  pass "T-04b marker 不在時の文言が 1 箇所にのみ定義されている"
else
  fail "T-04b marker 不在時の文言が $_nb_rule_count 箇所に複製されている (drift 面)"
fi

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

# --- T-06: 撤去済み reason (fatal_triage_id_union_violation) の双方向 pin ---
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
