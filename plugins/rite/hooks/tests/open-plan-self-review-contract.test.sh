#!/bin/bash
# Tests for /rite:open ステップ 3.3.1 計画セルフレビュー contract.
#
# open は散文駆動スキル (LLM 実行、script ではない) のため、
# complexity-lane-contract.test.sh と同じ static-contract 方式で literal を grep-pin する。
# 感度: 単語 1 個の pin は同一ファイルの別行に同語があると mutation を素通りさせる。
# 本 suite は「隣接して現れること」を 1 本のパターンで pin する。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

OPEN="$SCRIPT_DIR/../../skills/open/SKILL.md"
PROMPT="$SCRIPT_DIR/../../skills/open/references/plan-self-review.md"
RATIONALE="$SCRIPT_DIR/../../skills/open/references/rationale.md"
HELPER="$SCRIPT_DIR/../../scripts/issue-complexity-lane.sh"

assert_file_exists_or_fail "open/SKILL.md exists" "$OPEN" || true
assert_file_exists_or_fail "plan-self-review.md exists" "$PROMPT" || true
assert_file_exists_or_fail "open rationale.md exists" "$RATIONALE" || true
assert_file_exists_or_fail "issue-complexity-lane.sh exists" "$HELPER" || true

# AC-1 / AC-4 の helper・S+ 行・PLAN_REVIEW=done は 3.3.1 セクション内に無いと
# 別節の同語で vacuous PASS する。start/end は見出し行そのもの（ドットは既存 caller と同じ未エスケープ）。
S331_START='^### 3.3.1 計画レビュー'
S331_END='^### 3.4 計画承認'
S34_START='^### 3.4 計画承認'
S34_END='^### 3.5'

echo "=== T-01 / AC-1: S 以上で 3.4 の前に 1 回レビューし承認時に結果を提示する ==="
l331=$(grep -n '^### 3.3.1 計画レビュー' "$OPEN" | head -1 | cut -d: -f1)
l34=$(grep -n '^### 3.4 計画承認' "$OPEN" | head -1 | cut -d: -f1)
if [ -n "$l331" ] && [ -n "$l34" ] && [ "$l331" -lt "$l34" ]; then
  pass "3.3.1 heading appears before 3.4 heading (T-01 placement)"
else
  fail "3.3.1 heading must appear before 3.4 (got 3.3.1=$l331 3.4=$l34)"
fi
assert_grep_in_section "3.3.1 invokes the complexity-lane helper" "$OPEN" \
  "$S331_START" "$S331_END" \
  'scripts/issue-complexity-lane\.sh --issue \{issue_number\}'
assert_grep_in_section "S+ row spawns Task once then reflects then goes to 3.4" "$OPEN" \
  "$S331_START" "$S331_END" \
  '`S` / `M` / `L` / `XL` \| 下記 Task を 1 回 spawn → 指摘を計画へ反映 → 3.4 へ'
assert_grep_in_section "Task fence prompt is plan_self_review_prompt" "$OPEN" \
  "$S331_START" "$S331_END" \
  '^prompt: \{plan_self_review_prompt\}$'
assert_grep_in_section "Task fence includes plan_body on its own line" "$OPEN" \
  "$S331_START" "$S331_END" \
  '^\{plan_body\}$'
assert_grep_in_section "Task sets run_in_background false" "$OPEN" \
  "$S331_START" "$S331_END" \
  'run_in_background: false'
assert_grep_in_section "done path emits PLAN_REVIEW=done with findings count as 承認材料" "$OPEN" \
  "$S331_START" "$S331_END" \
  '\[CONTEXT\] PLAN_REVIEW=done; findings=N.*承認材料として提示して 3.4 へ'
assert_grep_in_section "3.4 includes PLAN_REVIEW in 承認材料" "$OPEN" \
  "$S34_START" "$S34_END" \
  '3.3.1 の `PLAN_REVIEW=` を承認材料に含める'
# 3.3.1 内の Task は 1 本。2 本目を足すと「1 回」契約が破れる。
_sec331=$(awk -v start="$S331_START" -v end="$S331_END" '$0 ~ start, $0 ~ end' "$OPEN")
_st_count=$(printf '%s\n' "$_sec331" | grep -cE '^subagent_type:' || true)
assert "3.3.1 has exactly one subagent_type" "1" "$_st_count"
assert_grep_in_section "3.3.1 Task is general-purpose" "$OPEN" \
  "$S331_START" "$S331_END" \
  '^subagent_type: general-purpose$'

echo "=== T-02 / AC-2: XS はレビューせず追加出力なしで 3.4 へ ==="
assert_grep_in_section "XS row skips review with no user-facing extra output and no PLAN_REVIEW marker" "$OPEN" \
  "$S331_START" "$S331_END" \
  '`XS` \| レビューせず 3.4 へ（ユーザー向け追加出力なし。`PLAN_REVIEW=` も出さない）'
assert_grep_in_section "3.3.1 XS path does not spawn Task" "$OPEN" \
  "$S331_START" "$S331_END" \
  'Task（S 以上のみ'

echo "=== T-03 / AC-3: 指摘は承認前の計画へ反映する ==="
assert_grep_in_section "findings are reflected as plan edits or 要判断ポイント promotion" "$OPEN" \
  "$S331_START" "$S331_END" \
  '種別=` が 実装ステップ追記 / 変更対象ファイル追記 / 要判断ポイントへ昇格'
assert_grep "plan-self-review.md names 反映先 種別 enum" "$PROMPT" \
  '種別=` は 実装ステップ追記 / 変更対象ファイル追記 / 要判断ポイントへ昇格'
# 反映が先、blocking にしないはその直後。順序が逆だと承認前反映契約が壊れる。
assert_grep_in_section "done path reflects first then does not treat findings as blocking" "$OPEN" \
  "$S331_START" "$S331_END" \
  '指摘を計画へ反映（`種別=` どおり。新規ステップ追加はしない）。blocking にしない'

echo "=== T-04 / AC-4: 反映後に再レビューしない ==="
assert_grep_in_section "3.3.1 forbids re-review after reflection" "$OPEN" \
  "$S331_START" "$S331_END" \
  '反映後に再レビューしない'
assert_grep_in_section "done path forbids re-spawn" "$OPEN" \
  "$S331_START" "$S331_END" \
  '承認材料として提示して 3.4 へ。再 spawn しない'
assert_grep_in_section "Task block is one-shot" "$OPEN" \
  "$S331_START" "$S331_END" \
  'Task（S 以上のみ。1 回。再 spawn しない）'

echo "=== T-05 / AC-5: batch 経路でも同一のレビューを実行する ==="
assert_grep_in_section "3.3.1 runs identically on batch and standalone" "$OPEN" \
  "$S331_START" "$S331_END" \
  'batch / standalone とも同一'
# レビュー発火を OPEN_PLAN_MODE / plan_mode に掛けないこと。掛けてしまうと batch 自動承認がレビューを飛ばす。
if printf '%s\n' "$_sec331" | grep -qE 'OPEN_PLAN_MODE|plan_mode='; then
  fail "3.3.1 section must not branch on OPEN_PLAN_MODE or plan_mode (AC-5)"
else
  pass "3.3.1 section does not branch on OPEN_PLAN_MODE or plan_mode (AC-5)"
fi

echo "=== T-06 / AC-6: agent 失敗は WARNING + 未実施明記（silent skip なし） ==="
assert_grep_in_section "unavailable path WARNING and 未実施 marker are adjacent" "$OPEN" \
  "$S331_START" "$S331_END" \
  'WARNING `計画レビュー未実施: \{reason\}`.*\[CONTEXT\] PLAN_REVIEW=unavailable; reason='
assert_grep_in_section "unavailable path forbids guessing missing output" "$OPEN" \
  "$S331_START" "$S331_END" \
  '出力の推測補完をしない。`\[CONTEXT\] PLAN_REVIEW=unavailable'
assert_grep_in_section "3.4 presents 未実施 when unavailable" "$OPEN" \
  "$S34_START" "$S34_END" \
  '`unavailable` = 「計画レビュー未実施」'
assert_grep_in_section "3.4 XS skip adds no extra 承認材料" "$OPEN" \
  "$S34_START" "$S34_END" \
  'marker なし = XS skip で追加提示しない'
assert_grep_in_section "complexity missing is fail-loud and ignores helper full fallback" "$OPEN" \
  "$S331_START" "$S331_END" \
  '欠落（`reason=` のみ / marker 不在 / helper 非ゼロ） \| \*\*ERROR\*\*（fail-loud）。helper の `COMPLEXITY_LANE=full`'
assert_grep_in_section "3.4/3.5/3.6 consume the post-3.3.1 plan" "$OPEN" \
  "$S34_START" "$S34_END" \
  '3.4 / 3.5 / 3.6 の入力は 3.3.1 反映後の計画（未実施なら 3.3 のまま）'

echo "=== prompt SoT: 4 視点と判定出力形式 ==="
assert_grep "prompt lists 検証網設計" "$PROMPT" '\*\*検証網設計\*\*'
assert_grep "prompt lists 文書同期スコープ" "$PROMPT" '\*\*文書同期スコープ\*\*'
assert_grep "prompt lists CI・統合配線" "$PROMPT" '\*\*CI・統合配線\*\*'
assert_grep "prompt lists regression 面" "$PROMPT" '\*\*regression 面\*\*'
assert_grep "prompt limits review to the four listed perspectives" "$PROMPT" \
  '視点は上記 4 つのみ。予約枠を足さない'
assert_grep "prompt SoT names general-purpose Task with foreground" "$PROMPT" \
  'subagent_type: general-purpose`、`run_in_background: false'
assert_grep "prompt requires 指摘件数 line" "$PROMPT" '指摘件数: \{n\}'
assert_grep "spawn payload concatenates Prompt + format + constraints" "$PROMPT" \
  'Prompt 節 \+ 判定出力形式 \+ 本ファイル冒頭の制約'
assert_grep_in_section "SKILL.md points prompt SoT at plan-self-review.md" "$OPEN" \
  "$S331_START" "$S331_END" \
  '\[plan-self-review.md\]\(references/plan-self-review.md\)'
assert_grep "rationale records why fail-loud vs WARNING" "$RATIONALE" \
  'Complexity 未確定は fail-loud で止める'

print_summary "$(basename "$0")" \
  "If 3.3.1 placement, XS skip, one-shot, batch sameness, or fail-loud/WARNING split drifts, AC-1..AC-6 no longer hold. Re-read skills/open/SKILL.md ステップ 3.3.1 before relaxing a pin."
