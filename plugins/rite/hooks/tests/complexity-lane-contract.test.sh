#!/bin/bash
# Tests for the XS/S 軽量レーン contract (Issue #2136).
#
# pr-review / reviewers / issue-implement は散文駆動スキル (LLM 実行、script ではない) のため、
# cycle-scope-contract.test.sh と同じ static-contract 方式で literal を grep-pin する。
# 判定ロジック本体 (body 解析・fail-safe 分岐) は scripts/issue-complexity-lane.sh に切り出され
# scripts/tests/issue-complexity-lane.test.sh が挙動を検証するので、本 suite が守るのは
# **散文側にしか存在しない契約** — cap の配置・mandate の合成・生産量制約・観測性の 4 つに絞る。
#
# 感度に関する注意 (cycle-scope-contract.test.sh が記録した教訓の適用):
# 単語 1 個の pin はセクション内の別行にも同語が出現すると mutation を素通りさせる。
# 本 suite は「隣接して現れること」を 1 本の line-anchored パターンで pin することで、
# 合成 (例: light と complexity_max=3 が同じ規則として書かれていること) が消えたら落ちるようにする。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

PR_REVIEW="$SCRIPT_DIR/../../skills/pr-review/SKILL.md"
REVIEWERS="$SCRIPT_DIR/../../skills/reviewers/SKILL.md"
IMPLEMENT="$SCRIPT_DIR/../../skills/issue-implement/SKILL.md"
LANE="$SCRIPT_DIR/../../skills/pr-review/references/complexity-lane.md"
PROMPT_GEN="$SCRIPT_DIR/../../skills/pr-review/references/reviewer-prompt-generator.md"
REPORT_TPL="$SCRIPT_DIR/../../skills/pr-review/references/integrated-report-templates.md"
HELPER="$SCRIPT_DIR/../../scripts/issue-complexity-lane.sh"

echo "=== ステップ 1.3.2: レーン判定は helper へ委譲し宣言 Complexity を入力とする (AC-1 / T-01) ==="
assert_file_exists_or_fail "issue-complexity-lane.sh exists" "$HELPER"
assert_file_exists_or_fail "complexity-lane.md exists" "$LANE"
assert_grep "1.3.2 invokes the complexity-lane helper" "$PR_REVIEW" \
  'scripts/issue-complexity-lane\.sh --issue \{issue_number\}'
assert_grep "1.3.2 declares the Issue's own Complexity as the sole input" "$PR_REVIEW" \
  '判定入力は Issue の\*\*宣言 Complexity\*\* のみ'
# light/full の 2 値分岐表が本体に残っていること (marker を読んだ後の行動を決める唯一の表)。
# レーンと cap と mandate が 1 行に同居していることを pin する — 3 つを別行に分けた形へ
# 崩れると「light だが cap を渡さない」等の部分適用が green のまま通る。
assert_grep "1.3.2 keeps the light row binding lane, cap and mandate together" "$PR_REVIEW" \
  '^\| `light` \| `complexity_max = 3`.*`\{complexity_lane_mandate\}` を注入'
assert_grep "1.3.2 keeps the full row as the unchanged path" "$PR_REVIEW" \
  '^\| `full` \| 既存 `max_reviewers`.*注入しない（空文字列、セクションごと省略）'

echo "=== ステップ 1.3.2: fail-safe は必ず full へ倒れる (AC-2 / T-02) ==="
# reason 語彙の列挙と「reason は分岐を変えない (全て full)」が 1 行に同居していることを pin する。
# 語彙だけの pin だと「full へ倒す」規則が消えても green のままになる。
assert_grep "1.3.2 enumerates every helper-side reason and pins that they all fall back to full" "$PR_REVIEW" \
  'gh_missing.*repo_unresolved.*issue_fetch_failed.*complexity_absent.*complexity_invalid.*reason は分岐を変えない.*`full`'
assert_grep "helper docstring is the reason SoT" "$HELPER" \
  'Fallback reason 語彙 \(SoT'
assert_grep "complexity-lane.md forbids narrowing on missing information" "$LANE" \
  '軽い方で妥協する」経路は持たない'
assert_grep "complexity-lane.md states the safe side is always the heavier lane" "$LANE" \
  '安全側は常に\*\*儀式を減らさない方\*\*'
# reason 語彙は helper docstring が SoT だが、SKILL.md と complexity-lane.md にコピーがある。
# 3 コピーのどれかが欠けると「その経路は fail-safe しない」と読める記述が残る
# (cycle-scope の jq_missing が実際に 1 コピーから欠落していた前例の予防)。
for _f in "$HELPER" "$PR_REVIEW" "$LANE"; do
  for _r in gh_missing repo_unresolved issue_fetch_failed complexity_absent complexity_invalid; do
    assert_grep "$(basename "$_f") documents reason '$_r'" "$_f" "$_r"
  done
done
# helper を呼べない / marker を出せない経路の consumer 側既定。helper の reason 語彙では
# 表現できないため SKILL.md 側に置く必要がある。
assert_grep "1.3.2 defines the consumer-side default when the helper emits no marker" "$PR_REVIEW" \
  'marker を観測できない場合も `full` として扱い'
assert_grep "1.3.2 defines the consumer-side reason for a missing Issue number" "$PR_REVIEW" \
  'issue_number_missing'
assert_grep "1.3.2 names helper_failed as the consumer-side reason literal" "$PR_REVIEW" \
  'reason=helper_failed'

echo "=== cap の SoT は reviewers Phase 5 (二重管理の防止) ==="
# cap を Phase 5 の effective_max 解決へ入れることと、値 3 が 1 行に同居していること。
assert_grep "Phase 5 owns the complexity-derived bound" "$REVIEWERS" \
  'complexity lane bound.*COMPLEXITY_LANE == light'
assert_grep "Phase 5 binds effective_max to min(effective_max, 3)" "$REVIEWERS" \
  'effective_max = min\(effective_max, complexity_max\) where complexity_max = 3'
# 順序が壊れると floor / mandatory 保護が cap に負ける。「final clamp の前」を明示的に pin する。
assert_grep "Phase 5 applies the bound BEFORE the final clamp" "$REVIEWERS" \
  'Applied BEFORE the final clamp'
# full のとき解決が完全に不変であること (AC-4)。
assert_grep "Phase 5 declares the full lane a no-op" "$REVIEWERS" \
  'this line is a no-op and the'
# SKILL.md 側は配線とレンダリングのみを持ち、アルゴリズムを再掲しない。
assert_grep "3.2.1 wires the bound without restating the algorithm" "$PR_REVIEW" \
  'Complexity lane bound.*`complexity_max = 3` を Phase 5 の `effective_max` 解決へ渡す'
assert_grep "3.2.1 forbids a new config key for the lane" "$PR_REVIEW" \
  '新 config キーは作らない'
# 除外 reviewer の記録先を 3.3 (cap 超過表示) ではなく 5.4 のレーン section に固定する。
# 片方だけ書くと「cap 超過として表示され、レーンの効果が見えない」形に戻る。
assert_grep "3.2.1 routes lane-derived exclusions to the 5.4 lane section, not the 3.3 cap display" "$PR_REVIEW" \
  'ステップ 3.3 の省略表示ではなく ステップ 5.4 の `### レビューレーン（XS/S 軽量レーン）` section に記録する'
assert_grep "complexity-lane.md explains why the bound lives in Phase 5" "$LANE" \
  '^## reviewer 上限を Phase 5 に置く理由$'
# 「light は常に 3 名以下」ではないこと (mandatory 保護と floor が優先される)。
assert_grep "1.3.2 states that light does not mean at most 3" "$PR_REVIEW" \
  '\*\*`light` は「常に 3 名以下」を意味しない\*\*'

echo "=== reviewer mandate の合成 (AC-1 / AC-4) ==="
assert_grep "prompt generator declares the lane mandate section" "$PROMPT_GEN" \
  '\{complexity_lane_mandate\}'
assert_grep "prompt generator omits the whole section on the full lane" "$PROMPT_GEN" \
  'full のときは空文字列で、このセクションごと省略する'
assert_grep "4.5 placeholder table maps the mandate to complexity-lane.md" "$PR_REVIEW" \
  '\| `\{complexity_lane_mandate\}` \| \[complexity-lane\.md\]'
# full で空文字列にすることを AC-4 の根拠つきで pin する (空見出しの残留は M+ の prompt を変える)。
assert_grep "4.5 pins the empty-string contract with its AC-4 rationale" "$PR_REVIEW" \
  '`full` のときは空文字列（セクションごと省略 — 空見出しが残ると M\+ の prompt が変化し AC-4 に違反する）'
# 差分スコープ mandate と直交し共存しうること (両方非空を禁じる読みへの退行を防ぐ)。
assert_grep "4.5 declares the two mandates orthogonal" "$PR_REVIEW" \
  '\{cycle_scope_mandate\}` とは直交し、両方が非空になりうる'
assert_grep "complexity-lane.md carries the mandate body" "$LANE" \
  '^## Reviewer mandate（軽量レーン適用時に注入する本文）$'
# mandate 本文の 4 点。軽量化する対象と、軽量化しない対象が同居していること。
assert_grep "mandate limits verification to touched tests" "$LANE" \
  '検証は touched テストまで'
assert_grep "mandate names the M\+ only equipment" "$LANE" \
  'sandbox 複製実行と mutation 実験.*M\+ の装備であり、本レーンでは実施しません'
assert_grep "mandate keeps the finding admission criteria unchanged" "$LANE" \
  '指摘の採否基準は緩めない'
assert_grep "mandate keeps Cross-File Impact Check at full depth" "$LANE" \
  'Cross-File Impact Check は縮小しない'
# Scenario 2: 過小宣言そのものを指摘させる経路 (軽量化の誤適用を検出する唯一の手段)。
assert_grep "mandate requires reporting an under-declared Complexity" "$LANE" \
  'Complexity 過小宣言はそれ自体を指摘する'
# 「軽量だから報告しない」への退行を明示的に禁じていること。
assert_grep "mandate forbids suppressing findings because of the lane" "$LANE" \
  '軽量レーンだから報告しない」は禁止'

echo "=== implement の生産量制約 (AC-3 / T-03) ==="
assert_grep "implement resolves the lane through the shared helper" "$IMPLEMENT" \
  'scripts/issue-complexity-lane\.sh --issue \{issue_number\}'
assert_grep "implement declares the production-constraint step" "$IMPLEMENT" \
  '^#### 5\.1\.0\.8 XS/S Production Constraint \(Conditional\)$'
assert_grep "5.1.0.8 runs only on the light lane" "$IMPLEMENT" \
  '5\.0\.C の `COMPLEXITY_LANE == light`'
# XS/S と XS-only の非対称が消えると、要求されていない制約が S に及ぶ (または XS で緩む)。
# 適用列と制約名が同じ行にあることを pin して、行を分ける形の崩れを落とす。
assert_grep "new test files are suppressed for XS and S" "$IMPLEMENT" \
  '^\| \*\*新規テストファイルを作らない\*\* \| XS / S \|'
assert_grep "derived prose is forbidden for XS only" "$IMPLEMENT" \
  '^\| \*\*説明的派生散文を新設しない\*\* \| \*\*XS のみ\*\* \|'
# 削るのであって follow-up Issue へ回さない (issue_accountability と同旨)。
assert_grep "5.1.0.8 requires removing the excess before commit" "$IMPLEMENT" \
  'コミット前に\*\*削る\*\*（follow-up Issue へ回さない）'
# 縮小してはならない既存ゲート。5.1.0.7 の stale doc 修正は「既存記述の同期」として XS でも必須。
assert_grep "5.1.0.8 keeps the existing pre-commit gates intact" "$IMPLEMENT" \
  '縮小しないもの.*5\.1\.0\.6 Test Verification Gate.*5\.1\.0\.7 Documentation Impact Investigation'
assert_grep "5.1.0.8 still requires stale-doc fixes on XS" "$IMPLEMENT" \
  'XS でも\*\*必ず実施する\*\*'
# 新ステップがコミットへの経路から外れないこと。チェーン宣言が 5.1.0.8 を含むこと。
assert_grep "the pre-commit chain includes 5.1.0.8" "$IMPLEMENT" \
  '5\.1\.0\.6 → 5\.1\.0\.6\.1 → 5\.1\.0\.7 → 5\.1\.0\.8 → 5\.1\.1'
assert_grep "the chain forbids bypassing 5.1.0.8" "$IMPLEMENT" \
  'never bypass 5\.1\.0\.7 or 5\.1\.0\.8 on the way to commit'
# Complexity の読み取りを 1 箇所へ集約したこと (2 箇所で別々に body を解析する drift の防止)。
assert_grep "5.1.0.1 consumes the lane marker instead of re-parsing the body" "$IMPLEMENT" \
  'ここで body を再解析しない'

echo "=== 観測性: 選抜結果と軽量化の記録 (MUST) ==="
assert_grep "report template carries the lane section" "$REPORT_TPL" \
  '^### レビューレーン（XS/S 軽量レーン）（該当がある場合のみ）$'
assert_grep "report template records the skipped reviewers" "$REPORT_TPL" \
  'レーンによりスキップした reviewer'
assert_grep "report template records what was lightened" "$REPORT_TPL" \
  '軽量化した検証 mandate'
# 軽量化していない項目も併記する (何が守られたかが読めないと、記録が「削った」証拠にしかならない)。
assert_grep "report template records what stayed unchanged" "$REPORT_TPL" \
  '\*\*不変\*\*.*Cross-File Impact Check'
assert_grep "5.4 declares the lane section rendering condition" "$PR_REVIEW" \
  '`### レビューレーン（XS/S 軽量レーン）` section.*`COMPLEXITY_LANE == light`'
assert_grep "5.4 forbids silent narrowing" "$PR_REVIEW" \
  'silent な絞り込みは禁止で、本 section は E2E でも省略禁止（上記 E2E Output Minimization 表の例外 3）'
# E2E 例外は 3 番目として E2E Output Minimization 表に登録されていること。
assert_grep "E2E Output Minimization registers the lane section as 例外 3" "$PR_REVIEW" \
  '例外 3: ステップ 5\.4 の `### レビューレーン（XS/S 軽量レーン）` section'
# 例外の根拠は #2118 の複製ではなく Scenario 1 (自律マージ) に基づくこと。
assert_grep "the E2E exemption is justified by the autonomous-merge scenario" "$LANE" \
  '「XS が 1 サイクル収束して\*\*自律マージ\*\*される」経路は'

echo "=== レーン境界と no_speculative_structure ==="
assert_grep "complexity-lane.md pins the lane boundary table" "$LANE" \
  '^\| XS \| `light` \| `complexity_max = 3` \|'
assert_grep "complexity-lane.md keeps M/L/XL on the unchanged path" "$LANE" \
  '^\| M / L / XL \| `full` \| 既存 `max_reviewers`'
assert_grep "complexity-lane.md refuses to add a new floor" "$LANE" \
  '^## 選抜の最低人数フロアを新設しない理由$'
assert_grep "complexity-lane.md refuses to auto-detect Complexity" "$LANE" \
  '\*\*Complexity の自動判定はしない\*\*'
# 2 記法の併存を吸収すること (片方だけ読む実装への退行は「レーンが一度も発動しない」形で現れる)。
assert_grep "complexity-lane.md documents accepting both body notations" "$LANE" \
  'helper は\*\*両方を受理する\*\*'

if ! print_summary "$(basename "$0")" \
  "XS/S 軽量レーンの散文契約。挙動側は plugins/rite/scripts/tests/issue-complexity-lane.test.sh を参照。"; then
  exit 1
fi
