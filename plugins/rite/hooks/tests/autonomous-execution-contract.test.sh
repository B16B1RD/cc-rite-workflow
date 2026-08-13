#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

PREAMBLE="$SCRIPT_DIR/../../skills/rite-workflow/references/autonomous-execution.md"
BATCH="$SCRIPT_DIR/../../skills/batch-run/SKILL.md"
ITERATE="$SCRIPT_DIR/../../skills/iterate/SKILL.md"

assert_file_exists_or_fail "autonomous execution SoT exists" "$PREAMBLE"
assert_grep "SoT requires execution instead of ending with a plan" "$PREAMBLE" \
  '計画・約束・質問だけで turn を終えず、いま実行する'
assert_grep "SoT permits reversible in-scope action without confirmation" "$PREAMBLE" \
  '依頼範囲内で可逆な行動は確認なしで進め'
assert_grep "SoT limits end-turn to completion or user-only input" "$PREAMBLE" \
  'タスク完了またはユーザーにしか出せない入力でブロックされたときだけ turn を終える'
assert_grep "SoT gives host-independent routine effort guidance" "$PREAMBLE" \
  'ルーチン作業を effort 調整可能なモデルで実行する場合は、過剰な熟考・検証を避けるため低めの effort を選ぶ（ホスト固有設定として強制しない）'
assert_grep "SoT forbids self-stop for context-budget concern" "$PREAMBLE" \
  'コンテキスト制限を理由に停止・要約・新セッション提案・作業の切り詰めをしない'
assert_grep "SoT limits reports to outcome and next action" "$PREAMBLE" \
  '報告は outcome と次の一手のみ'

for skill in "$BATCH" "$ITERATE"; do
  assert_grep "$(basename "$(dirname "$skill")") references the autonomous execution SoT" "$skill" \
    '^> 実行開始時は \[Autonomous Execution\]\(\.\./rite-workflow/references/autonomous-execution\.md\) を適用する。$'
  for clause in \
    '計画・約束・質問だけで turn を終えず' \
    '依頼範囲内で可逆な行動は確認なしで進め' \
    'タスク完了またはユーザーにしか出せない入力でブロックされたときだけ turn を終える'; do
    assert_not_grep "$(basename "$(dirname "$skill")") does not duplicate a preamble clause" "$skill" "$clause"
  done
done

if ! print_summary "$(basename "$0")"; then
  exit 1
fi
