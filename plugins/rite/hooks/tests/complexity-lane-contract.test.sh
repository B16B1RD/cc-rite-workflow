#!/bin/bash
# Tests for the XS/S 軽量レーン contract.
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
# needle はレーン固有語まで書き切る — `marker を観測できない場合も \`full\` として扱い` だけだと
# sibling (cycle-scope) の 1.2.4 Reference 行にも一致し、レーン側の記述を削除しても green になる。
assert_grep "1.3.2 defines the consumer-side default when the helper emits no marker" "$PR_REVIEW" \
  '`COMPLEXITY_LANE=` marker を観測できない場合も `full` として扱い'
# needle は 1.3.2 の**操作的な指示**まで書き切る。裸の `issue_number_missing` だけだと、
# 同ファイルの Reference 行 (語彙の言及のみ) にも一致し、1.3.2 側の `full` を `light` へ
# 反転しても、当該括弧節を丸ごと削除しても green になる (sibling の helper_failed は
# 完全 literal で pin されており、片方だけ裸単語という非対称が原因だった)。
assert_grep "1.3.2 falls back to full when the Issue number is unresolved" "$PR_REVIEW" \
  'ステップ 1\.3 で Issue 番号を特定できなかった場合は helper を呼ばず `full` として扱い'
assert_grep "1.3.2 names issue_number_missing as the consumer-side reason literal" "$PR_REVIEW" \
  '⚠️ Complexity レーン判定のフォールバック: reason=issue_number_missing'
assert_grep "1.3.2 names helper_failed as the consumer-side reason literal" "$PR_REVIEW" \
  '⚠️ Complexity レーン判定のフォールバック: reason=helper_failed'

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
# 除外 reviewer は 3.3 の省略表示に**加えて** 5.4 のレーン section にも記録する（加算であって排他ではない）。
# 排他に書き戻すと、spawn 前の唯一の可視化である 3.3 の表示が消え「Silent capping is prohibited」に反する。
assert_grep "3.2.1 records lane-derived exclusions in BOTH the 3.3 display and the 5.4 lane section" "$PR_REVIEW" \
  'ステップ 3.3 の省略表示（.*）に加えて\*\*、ステップ 5.4 の `### レビューレーン（XS/S 軽量レーン）` section にも記録する'
assert_grep "3.2.1 forbids suppressing the 3.3 omission display for lane-derived drops" "$PR_REVIEW" \
  '\*\*3\.3 側を抑止してはならない\*\*'
assert_grep "complexity-lane.md explains why the bound lives in Phase 5" "$LANE" \
  '^## reviewer 上限を Phase 5 に置く理由$'
# 「light は常に 3 名以下」ではないこと (mandatory 保護と floor が優先される)。
assert_grep "1.3.2 states that light does not mean at most 3" "$PR_REVIEW" \
  '\*\*`light` は「常に 3 名以下」を意味しない\*\*'

echo "=== reviewer mandate の合成 (AC-1 / AC-4) ==="
assert_grep "prompt generator declares the lane mandate section" "$PROMPT_GEN" \
  '\{complexity_lane_mandate\}'
# 同ファイルには sibling の `{cycle_scope_mandate}` にも同文言があるため、レーン固有語で限定する。
assert_grep "prompt generator omits the whole section on the full lane" "$PROMPT_GEN" \
  'COMPLEXITY_LANE == light のときのみ.*full のときは空文字列で、このセクションごと省略する'
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
# mutation の全面禁止だけを pin すると、「契約対応の未 pin」クラスがアンカーを取得できず
# non-blocking へ落ち、下記「実測必須ゲートと帰結クラス分類は不変」が blocking 集合への
# 帰属という観点で偽になる。例外節はその乖離を閉じる唯一の記述なので個別に pin する。
assert_grep "mandate exempts the contract-coverage class from the mutation ban" "$LANE" \
  '「\*\*契約対応の未 pin\*\*」クラス.*本レーンでも mutation 実験を実施してください'
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

# 5.1.0.1 は「all of the following」を要求する AND ゲートなので、3 条件が 1 つの表に**連続して**
# いることまで pin する。行の存在だけを見ると、条件行が blockquote の下へ落ちて GFM 上は表から
# 脱落した状態 (raw markdown を読む LLM には 3 条件、レンダを読む人間には 2 条件のゲートに見える)
# でも green のまま通る。**3 行を 1 回の抽出で取り出して全ペアを検査する** — 隣接対を 1 つだけ
# 見る形にすると、検査していない側の行が脱落しても通ってしまう。
#
# `assert_grep_in_section` は使わない。同 helper はセクション**範囲**の抽出器であって行の
# **隣接**を表現できない (start と end の間に何行あっても pass する) ため、本 pin が検出したい
# 「行が blockquote 側へ落ちる」欠陥は範囲内に残って素通りする。加えて `awk -v` は代入時に
# バックスラッシュを剥がすので、終端に意味を変える escape (`\*` 等) を渡すと終端パターンが
# 成立せず範囲がファイル末尾まで伸びる (start が一致しない場合は empty section として fail するので
# 「常に PASS」ではない)。既存 caller は終端に `\*` 系を持つものが無く該当 0 件で、
# cleanup-message-contract.test.sh は同じ挙動を把握して二重 escape で回避している。
_impl_rows=$(grep -A3 '^|-----------|---------------------|$' "$IMPLEMENT" | tail -3)
_impl_expected='| `parallel.enabled: true` |
| Complexity M or above |
| 2 or more independent tasks |'
_impl_actual=$(printf '%s\n' "$_impl_rows" | sed 's/^\(| [^|]* |\).*/\1/')
if [ "$_impl_actual" = "$_impl_expected" ]; then
  pass "5.1.0.1 keeps all three AND-conditions contiguous in one table"
else
  fail "5.1.0.1 keeps all three AND-conditions contiguous in one table"
  echo "     期待 (表ヘッダ直後の 3 行の第 1 セル):"
  printf '%s\n' "$_impl_expected" | sed 's/^/       /'
  echo "     実際:"
  printf '%s\n' "$_impl_actual" | sed 's/^/       /'
fi

# 上の 3 行照合は第 1 セルだけを残して行の残りを捨てるため、条件行の第 2 セル (判定方法) は
# 検査対象外になる。2 行目の第 2 セルは「M or above」の判定キーを規定しており、ここから
# fail-safe 除外が落ちると 5.1.0.1 は complexity 不明の Issue を「M or above」と読んで並列
# sub-agent を起動する側 (攻撃側) へ倒れる。3 要素を 1 行 anchor でまとめて pin し、
# 行を分ける崩れも同時に落とす。**`|` は `\|` でエスケープする** — assert_grep は `grep -qE`
# (ERE) なので裸の `|` は交替演算子になり、`^` 単独腕が全行に一致して常に PASS になる。
assert_grep "5.1.0.1 excludes the fail-safe path from 'M or above'" "$IMPLEMENT" \
  '^\| Complexity M or above \|.*かつ `complexity=` を伴う.*`COMPLEXITY_LANE_FALLBACK=1` を伴う fail-safe 経路は満たさない'

echo "=== implement の生産量制約 (AC-3 / T-03) ==="
assert_grep "implement owns the all-Complexity contract-literalism mandate" "$IMPLEMENT" \
  '^### 5\.0\.L Contract Literalism Mandate（全 Complexity 共通）$'
assert_grep "contract literalism rejects structures not justified by the Issue contract" "$IMPLEMENT" \
  'Target Files、Scope、MUST / MUST NOT、Non-goal.*オプション・パラメータ・guard・一般化・予約フィールドは実装しない'
assert_grep "contract literalism chooses the smaller implementation when the contract is ambiguous" "$IMPLEMENT" \
  '迷った場合は小さい実装を選ぶ'
assert_grep "contract literalism returns out-of-contract needs to the Issue instead of implementing them" "$IMPLEMENT" \
  '契約外の必要性に気付いた場合は実装せず、既存の Issue コメントへ必要性と根拠を記録して差し戻す'
assert_grep "contract literalism applies to every declared Complexity" "$IMPLEMENT" \
  'XS / S / M / L / XL の全 Complexity に適用する'
assert_grep "complexity-lane references the mandate without redefining it" "$LANE" \
  '全 Complexity 共通 mandate の定義は .*issue-implement/SKILL\.md §5\.0\.L.*唯一の所有位置'
assert_not_grep "complexity-lane does not duplicate the mandate's normative definition" "$LANE" \
  'Target Files、Scope、MUST / MUST NOT、Non-goal.*オプション・パラメータ・guard・一般化・予約フィールド'
assert_grep "implement resolves the lane through the shared helper" "$IMPLEMENT" \
  'scripts/issue-complexity-lane\.sh --issue \{issue_number\}'
assert_grep "implement declares the production-constraint step" "$IMPLEMENT" \
  '^#### 5\.1\.0\.8 XS/S Production Constraint \(Conditional\)$'
# needle は帰結節まで含める — 条件節で止めると「full にも制約を適用する」への反転 mutant が
# 素通りし、AC-4 / MUST NOT「M+ の経路に変更を入れない」の番人が消える。
assert_grep "5.1.0.8 runs only on the light lane, and is a no-op on full" "$IMPLEMENT" \
  '5\.0\.C の `COMPLEXITY_LANE == light`。`full`.*本サブセクション全体を skip し、挙動は本機能導入前と完全に同一'
# 5.0.C の routing 表 3 行。表が消えると 5.1.0.1 / 5.1.0.8 の写像がどこにも残らない。
assert_grep "5.0.C routing table maps XS to both constraints" "$IMPLEMENT" \
  '^\| `light` \+ `complexity=XS` \|.*説明的派生散文の新設禁止'
assert_grep "5.0.C routing table maps S to the test-file constraint only" "$IMPLEMENT" \
  '^\| `light` \+ `complexity=S` \|.*新規テストファイル抑制'
assert_grep "5.0.C routing table keeps the full lane unchanged" "$IMPLEMENT" \
  '^\| `full`.*適用しない（現行どおり）'
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
# 行頭 anchor + 5.4 固有の帰結節まで書き切る。行頭を外すと E2E Output Minimization 表の
# 例外 3 セル (同じ section 名と条件を含む) にも一致し、5.4 の描画条件を `full` へ反転しても
# 表セル側が pin を満たして green になる (= 観測性 MUST が実行時に空文化しても検出されない)。
assert_grep "5.4 declares the lane section rendering condition" "$PR_REVIEW" \
  '^\*\*`### レビューレーン（XS/S 軽量レーン）` section\*\*: `COMPLEXITY_LANE == light`（ステップ 1\.3\.2）のときのみ描画する'
# 描画条件だけを pin すると section 見出しは残るが中身が空になる mutant が通る。
# MUST「スキップした reviewer と軽量化した mandate を統合レポートへ記録」の実体は列挙義務側にある。
assert_grep "5.4 requires enumerating the lane-skipped reviewers with reasons" "$PR_REVIEW" \
  'レーンの上限により起動しなかった reviewer 名と理由\*\*を列挙する'
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
# 3 記法の併存を吸収すること (一部だけ読む実装への退行は「レーンが一度も発動しない」形で現れる)。
# needle は「全記法受理」と「明示宣言 > 表行の優先」を**同じ 1 行の合成**として pin する — 2 つを
# 別行へ分解した崩れは、片方だけの単語 pin では素通りする (本 suite header の感度に関する注意を参照)。
# 優先順が消えると、表記法を説明している Issue が本文中の例から値を解決する経路が復活する。
assert_grep "complexity-lane.md binds accepting all three notations to declaration precedence" "$LANE" \
  'helper は\*\*3 記法すべてを受理し、明示宣言を表行より優先する\*\*'
# 表行を最後に読む根拠 (実測した 2 つの誤判定) が残っていること。消えると次の diet で
# 探索順が「たまたまそう書いてある」ものに見え、逆順へ戻されうる。
assert_grep "complexity-lane.md records why the table row is read last" "$LANE" \
  '\*\*表行を最後に読む理由\*\*'
# 記法 3 を足した根拠 (実測された failing Issue) が残っていること。消えると
# no_speculative_structure の観点で「予防的な一般化」に見え、次の diet で削られる。
assert_grep "complexity-lane.md records the measured demand behind notation 3" "$LANE" \
  '\*\*表形式を生成する code path は無い\*\*'

if ! print_summary "$(basename "$0")" \
  "XS/S 軽量レーンの散文契約。挙動側は plugins/rite/scripts/tests/issue-complexity-lane.test.sh を参照。"; then
  exit 1
fi
