#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

PREAMBLE="$SCRIPT_DIR/../../skills/rite-workflow/references/autonomous-execution.md"
BATCH="$SCRIPT_DIR/../../skills/batch-run/SKILL.md"
ITERATE="$SCRIPT_DIR/../../skills/iterate/SKILL.md"
OPEN="$SCRIPT_DIR/../../skills/open/SKILL.md"
PR_CREATE="$SCRIPT_DIR/../../skills/pr-create/SKILL.md"
PRINCIPLES="$SCRIPT_DIR/../../skills/rite-workflow/references/coding-principles.md"

assert_file_exists_or_fail "autonomous execution SoT exists" "$PREAMBLE"
assert_grep "SoT requires execution instead of ending with a plan" "$PREAMBLE" \
  '計画・約束・質問だけで turn を終えず、いま実行する'
assert_grep "SoT permits reversible in-scope action without confirmation" "$PREAMBLE" \
  '依頼範囲内で可逆な行動は確認なしで進め'
assert_grep "SoT limits end-turn to completion or user-only input" "$PREAMBLE" \
  'タスク完了またはユーザーにしか出せない入力でブロックされたときだけ turn を終える'
assert_grep "SoT pins reviewer effort high in frontmatter" "$PREAMBLE" \
  'reviewer agent は frontmatter の `effort: high` で固定する'
assert_grep "SoT gives host-independent routine effort guidance" "$PREAMBLE" \
  'ルーチン作業を effort 調整可能なモデルで実行する場合は、過剰な熟考・検証を避けるため低めの effort を選ぶ（ホスト固有設定として強制しない）'
assert_grep "SoT forbids self-stop for context-budget concern" "$PREAMBLE" \
  'コンテキスト制限を理由に停止・要約・新セッション提案・作業の切り詰めをしない'
assert_grep "SoT limits reports to outcome and next action" "$PREAMBLE" \
  '報告は outcome と次の一手のみ'
assert_grep "SoT pins parallel tool-call nudge" "$PREAMBLE" \
  '次に必要なものを先に列挙し、他の結果に依存しないものは同じ応答で全部要求する。'

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

REPO_ROOT="$(_helpers_resolve_repo_root "$SCRIPT_DIR")"
AGENTS_DIR="$REPO_ROOT/plugins/rite/agents"
REVIEWER_BASE="$AGENTS_DIR/_reviewer-base.md"
assert_file_exists_or_fail "reviewer base exists" "$REVIEWER_BASE"
nudge_line=$(grep -nF '次に必要なものを先に列挙し、他の結果に依存しないものは同じ応答で全部要求する。' "$REVIEWER_BASE" | head -1 | cut -d: -f1)
input_line=$(awk '/^## Input$/ { print NR; exit }' "$REVIEWER_BASE")
if [ -n "$nudge_line" ] && [ -n "$input_line" ] && [ "$nudge_line" -lt "$input_line" ]; then
  pass "reviewer-base pins parallel tool-call nudge before ## Input"
else
  fail "reviewer-base pins parallel tool-call nudge before ## Input (nudge_line=${nudge_line:-missing} input_line=${input_line:-missing})"
fi
reviewers=(
  application-reviewer
  code-quality-reviewer
  dependencies-reviewer
  devops-reviewer
  error-handling-reviewer
  prompt-engineer-reviewer
  security-reviewer
  tech-writer-reviewer
  test-reviewer
)
effort_lines=""
for r in "${reviewers[@]}"; do
  f="$AGENTS_DIR/$r.md"
  assert_file_exists_or_fail "reviewer agent exists: $r.md" "$f" || continue
  assert_grep "$r.md pins effort: high" "$f" '^effort: high$'
  assert_not_grep "$r.md does not pin model: opus" "$f" '^model:[[:space:]]*opus'
  effort_lines="${effort_lines}$(grep -E '^effort:' "$f" || true)"$'\n'
done
effort_uniq=$(printf '%s' "$effort_lines" | sed -n 's/^effort:[[:space:]]*//p' | sort -u | wc -l | tr -d '[:space:]')
assert "all reviewer agents share a single effort value" "1" "$effort_uniq"

# T-01 / T-04: 正規確認ゲート表（5 種 + standalone/batch + 破壊的操作）
assert_grep "T-01 gate table names 計画承認" "$PREAMBLE" '計画承認'
assert_grep "T-01 gate table names Issue 状態確認" "$PREAMBLE" 'Issue 状態確認'
assert_grep "T-01 gate table names dirty 衝突" "$PREAMBLE" 'dirty 衝突'
assert_grep "T-01 gate table names 強制取得" "$PREAMBLE" '強制取得'
assert_grep "T-01 gate table names 破壊的操作" "$PREAMBLE" '破壊的操作'
assert_grep "T-01 gate table has standalone column" "$PREAMBLE" '\| standalone \|'
assert_grep "T-01 plan approval is batch auto-approved" "$PREAMBLE" 'batch では自動承認'
assert_grep "T-01 out-of-table is one auto-retry then recover" "$PREAMBLE" \
  '1 回自動再試行し、再失敗で停止して `/rite:recover` を案内する'
assert_grep "T-04 destructive rm -rf remains in table" "$PREAMBLE" '`rm -rf`'
assert_grep "T-04 force-claim remains in table" "$PREAMBLE" '他セッションからの強制取得'

# T-02: coding-principles 前提文
assert_grep "T-02 preamble uses assume-and-proceed wording" "$PRINCIPLES" \
  '仮定を述べて進め、答えに依存しない部分を先に終える'
assert_not_grep "T-02 preamble no longer says stop-on-contradiction" "$PRINCIPLES" \
  '矛盾検出時の停止'

# T-03: open / pr-create 再試行型は 1 回自動再試行。品質ゲートの AskUserQuestion は残す
assert_grep "T-03 open pr-create-failed auto-retries once" "$OPEN" \
  '`rite:pr-create` を \*\*1 回だけ\*\* 再 invoke'
assert_grep "T-03 open pr-create-failed does not AskUserQuestion" "$OPEN" \
  '再失敗なら停止し、失敗理由と `/rite:recover` を案内する。AskUserQuestion は出さない'
assert_grep "T-03 open lint-error auto-retries once" "$OPEN" \
  '`rite:lint` を \*\*1 回だけ\*\* 再 invoke'
assert_grep "T-03 open lint-error forbids 強制続行" "$OPEN" \
  'AskUserQuestion は出さない（強制続行はしない）'
assert_grep "T-03 open missing sentinel auto-retries lint once" "$OPEN" \
  '`rite:lint` を \*\*1 回だけ\*\* invoke'
assert_grep "T-03 open error-policy auto-retries then recover" "$OPEN" \
  '不在なら当該 sub-skill を 1 回だけ再 invoke。再失敗なら停止し `/rite:recover` を案内する'
assert_grep "T-03 pr-create bang-backtick retries once" "$PR_CREATE" \
  'default は stderr `WARNING` \+ \*\*1 回だけ再実行\*\*'
assert_grep "T-03 pr-create PR creation failure retries once" "$PR_CREATE" \
  'retry once; on second failure stop and `/rite:recover`'
assert_grep "T-03 open keeps closed-issue AskUserQuestion" "$OPEN" \
  '再オープンして作業 / 中止'
assert_grep "T-03 open keeps parent-issue AskUserQuestion" "$OPEN" \
  '子 Issue を選んで作業'
assert_grep "T-03 open keeps quality C/D AskUserQuestion" "$OPEN" \
  '既存情報で開始'
assert_grep "T-03 open keeps force-claim AskUserQuestion" "$OPEN" \
  '強制取得して続行'
assert_grep "T-03 open keeps stale_residue AskUserQuestion" "$OPEN" \
  '削除して再作成'
assert_grep "T-03 open keeps dirty-overlap AskUserQuestion" "$OPEN" \
  '搬送して続行'
assert_grep "T-03 open keeps plan-approval AskUserQuestion" "$OPEN" \
  'この計画で実装開始'

if ! print_summary "$(basename "$0")"; then
  exit 1
fi
