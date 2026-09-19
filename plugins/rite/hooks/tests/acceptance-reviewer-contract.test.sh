#!/bin/bash
# acceptance-reviewer-contract.test.sh
#
# 受入条件確認 (acceptance reviewer) の配線契約を固定する。helper 単体の分岐は
# scripts/tests/acceptance-criteria-check.test.sh が持ち、本テストは SKILL / agent / reference の
# 配線と、正典 helper チェーンを通した結果 JSON の保持を扱う。
#
# Coverage (Issue テスト仕様 → TC / 観測条件):
#   T-01 → TC-1 + TC-8   agent 定義と mandatory 追加の配線 / チェーン後の JSON に reviewers と 3 行の acceptance_criteria
#   T-02 → TC-8 + TC-9   全充足 JSON で final が unverified 空・verdict mergeable / 5.4 と両テンプレートの受入条件確認 section
#   T-03 → TC-8          アンカー付き未充足が gate 後も findings[] に残り verdict fix-needed、行は unmet + finding_id
#   T-04 → TC-5          8.0 / 8.1 の停止行が同一条件文言で並び、8.1 は mergeable 行より前、8.0 の停止 set は handoff なし /
#                        6.5.1 は独自の判定表を持たず 8.1 を参照し、standalone の未検証分岐は Merge OK より前 /
#                        6.5.1 と E2E 表のステップ 7 実行条件、8.0.2 / 7.7 の MUST NOT 対象、rationale anchor と本文の対応
#   T-05 → TC-6          iterate が行頭 marker で再試行を skip し、既存の再試行文言は残る
#   T-06 → TC-3          5.1.0.AC が 5.1.0.L と 5.1.1 の間にあり、reroll 1 回 → [review:error]
#   T-07 → TC-4 + TC-8   5.3.0.A が 5.3.0.C の後・5.3.8 の前、unverified への書き換え禁止 / アンカー欠落は final が rc=1
#   T-08 → TC-8          未充足 finding が non_blocking_findings[] にある JSON で final が rc=1
#   T-09 → TC-2          対象外 2 種の 1 行通知と skipped の保持
#   T-10 → TC-2          AC 節ありで 0 件は [review:error] (helper の rc を bash が停止へつなぐ)
#   T-11 → TC-2          gh issue view 失敗で [review:error]
#   T-12 → TC-1          incremental でも差分 mandate の代わりに acceptance mandate、cap 枠外
#   T-13 → TC-7          fix 1.2.2 の保持指示 / 保存 JSON を review-findings-maps.sh に通しても acceptance_criteria が残る
#   T-14 → TC-9          schema / CLAUDE.md / docs の同期 (registry drift は reviewer-registry-drift-check.test.sh)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
REPO_ROOT="$(_helpers_resolve_repo_root "$SCRIPT_DIR")"
AGENT="$PLUGIN_ROOT/agents/acceptance-reviewer.md"
REVIEWERS="$PLUGIN_ROOT/skills/reviewers/SKILL.md"
PR_REVIEW="$PLUGIN_ROOT/skills/pr-review/SKILL.md"
GENERATOR="$PLUGIN_ROOT/skills/pr-review/references/reviewer-prompt-generator.md"
TEMPLATES="$PLUGIN_ROOT/skills/pr-review/references/integrated-report-templates.md"
ITERATE="$PLUGIN_ROOT/skills/iterate/SKILL.md"
FIX="$PLUGIN_ROOT/skills/fix/SKILL.md"
SCHEMA="$PLUGIN_ROOT/references/review-result-schema.md"
STOP_CONTRACT="$PLUGIN_ROOT/references/stop-loop-continuation-contract.md"
SCOPE_TRIAGE="$PLUGIN_ROOT/skills/pr-review/references/scope-triage.md"
RATIONALE="$PLUGIN_ROOT/skills/pr-review/references/design-rationale.md"
CHECK="$PLUGIN_ROOT/scripts/acceptance-criteria-check.sh"
MGATE="$PLUGIN_ROOT/scripts/review-measured-gate.sh"
MAPS="$PLUGIN_ROOT/scripts/review-findings-maps.sh"
SAVE="$PLUGIN_ROOT/hooks/review-result-save.sh"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 1; }
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rite-acceptance-contract-XXXXXX")" || exit 1
trap 'rm -rf "$TMP_ROOT"' EXIT

# 固定文字列の存在 (ERE の特殊文字を気にせず pin する)
pin() {
  local label="$1" file="$2" text="$3"
  if grep -qF -- "$text" "$file"; then pass "$label"; else fail "$label (not found in $(basename "$file"): $text)"; fi
}
# 固定文字列を含む最初の行番号 (無ければ 0)
line_of() {
  local n
  n=$(grep -nF -- "$2" "$1" | head -1 | cut -d: -f1)
  echo "${n:-0}"
}
# a < b < c の順序 (いずれも存在すること)
in_order() {
  local label="$1" a="$2" b="$3" c="${4:-}"
  if [ "$a" -gt 0 ] && [ "$b" -gt "$a" ] && { [ -z "$c" ] || [ "$c" -gt "$b" ]; }; then
    pass "$label"
  else
    fail "$label (lines: $a $b ${c:-})"
  fi
}

echo "=== TC-1: agent 定義と選抜・prompt の配線 (T-01 / T-12) ==="
pin "agent: effort high" "$AGENT" "effort: high"
pin "agent: 上書き 1 revert test 免除" "$AGENT" "**No revert test.**"
pin "agent: 上書き 2 file と line: null" "$AGENT" '(`line: null`'
pin "agent: 上書き 3 diff 導入問題への限定を外す" "$AGENT" "**Not limited to problems the diff introduced.**"
pin "agent: 上書き 4 毎 cycle 全 AC を HEAD で" "$AGENT" "**Every cycle, every criterion, on HEAD.**"
pin "agent: 未充足は [AC-N] 接頭辞の CRITICAL / current-pr" "$AGENT" 'whose `内容` **starts with `[AC-N]`**, with severity `CRITICAL` and scope `current-pr`'
pin "agent: 未充足は runtime_observation と Verification アンカー" "$AGENT" 'Likelihood-Evidence: runtime_observation <what you ran>` followed by `Verification: repro <command> => <observed outcome>`'
pin "agent: 観測した失敗を未検証にしない" "$AGENT" "Never use 未検証 for a criterion you observed to fail."
pin "reviewers: Type Identifiers に acceptance" "$REVIEWERS" '| acceptance | 受入条件確認担当 | `acceptance-reviewer.md` |'
pin "reviewers: cap 適用後に mandatory 追加" "$REVIEWERS" 'ステップ 3.2.1 の cap 適用**後**に `selection_type: mandatory` で追加する'
pin "reviewers: Phase 5 で cap 枠外" "$REVIEWERS" "The acceptance reviewer is outside this cap"
in_order "pr-review: 3.2.2 は 3.2.1 の後・3.3 の前" \
  "$(line_of "$PR_REVIEW" '### 3.2.1 Apply max_reviewers Cap')" \
  "$(line_of "$PR_REVIEW" '### 3.2.2 Acceptance Reviewer Addition')" \
  "$(line_of "$PR_REVIEW" '### 3.3 Confirm Reviewers')"
pin "pr-review: cycle / レーンに依らず毎 cycle・母数に数えない" "$PR_REVIEW" '`REVIEW_CYCLE_SCOPE` / `COMPLEXITY_LANE` に依らず毎 cycle 追加し、sole-reviewer guard と `effective_max` の母数には数えない'
pin "pr-review: subagent mapping" "$PR_REVIEW" '| `acceptance` | `rite:acceptance-reviewer` |'
pin "pr-review: acceptance には差分 mandate の代わりに受入条件 mandate" "$PR_REVIEW" '**`reviewer_type == acceptance`** のときは `REVIEW_CYCLE_SCOPE` に依らず本文を注入せず'
pin "pr-review: acceptance の relevant_files は PR 全体" "$PR_REVIEW" '**`acceptance`** は Activation パターンと `REVIEW_CYCLE_SCOPE` に依らずステップ 1.2.3 の PR 全体の変更ファイルを渡す'
pin "pr-review: acceptance に 4.5.1 を注入しない" "$PR_REVIEW" '**`acceptance`** には `review_mode` に依らず本節のテンプレートを注入しない'
pin "pr-review: acceptance には軽量レーン mandate を注入しない" "$PR_REVIEW" '**`reviewer_type == acceptance`** のときは `COMPLEXITY_LANE` に依らず空文字列（セクションごと省略）とする'
pin "generator: 受入条件確認の mandate 節" "$GENERATOR" "## 受入条件確認の mandate"
pin "generator: 全 AC を毎 cycle 再確認" "$GENERATOR" "**全 AC を毎 cycle 再確認する**"
pin "generator: 未変更部の再監査制限を適用しない" "$GENERATOR" "**未変更部の再監査制限を適用しない**"
pin "generator: mandate 項目0 読み取り形式" "$GENERATOR" "0. **AC の読み取り形式**"
pin "agent: Procedure 対応形式" "$AGENT" 'The section is a level-2 heading — `Acceptance Criteria`'
pin "1.3.1: 対応形式段落" "$PR_REVIEW" '対応形式は `acceptance-criteria-check.sh extract` が正典'

echo ""
echo "=== TC-2: 1.3.1 の対象判定と停止 (T-09 / T-10 / T-11) ==="
pin "1.3.1: Issue 番号なしは no_issue の 1 行通知" "$PR_REVIEW" '`[CONTEXT] ACCEPTANCE_SCOPE=skipped; reason=no_issue` として `受入条件確認: 対象外（関連 Issue なし）` を 1 行表示し'
pin "1.3.1: AC 節なしは 1 行通知" "$PR_REVIEW" '`受入条件確認: 対象外（AC 節なし）` を 1 行表示'
pin "1.3.1: gh issue view 失敗は skip せず停止" "$PR_REVIEW" '受入条件確認を skip せず停止します'
pin "1.3.1: extract の失敗を [review:error] へ" "$PR_REVIEW" 'acceptance-criteria-check.sh extract --body-file "$issue_body_file" || { rm -f "$issue_body_file"; echo "[review:error]"; exit 1; }'
pin "1.3.1: ids= を 5.1.0.AC が読む {acceptance_ids} として retain" "$PR_REVIEW" '| `target; ids=` | `ids=` を `{acceptance_ids}` として retain。'
pin "1.3.1: 抽出後に一時ファイルを削除" "$PR_REVIEW" '抽出後に `rm -f "{issue_body_file}"`（`ISSUE_BODY_FILE=` の値）で一時ファイルを削除する'

# 1.3.1 の bash を実際に実行し、gh 失敗 / 0 件 / 対象 / 対象外の終端を観測する
block_131="$TMP_ROOT/block-131.sh"
awk '/^### 1\.3\.1 Load Issue Specification/{s=1} s && /^ ```bash$/{b=1; next} s && b && /^ ```$/{exit} s && b {sub(/^ /, ""); print}' "$PR_REVIEW" > "$block_131"
if [ -s "$block_131" ] && grep -q 'gh issue view' "$block_131"; then pass "1.3.1 の bash block を抽出できる"; else fail "1.3.1 の bash block を抽出できない"; fi
mkdir -p "$TMP_ROOT/bin"
run_131() {
  # $1 = gh stub の本文ファイル (空なら gh を失敗させる)
  local body="$1" script="$TMP_ROOT/run-131.sh"
  {
    printf '#!/bin/bash\n'
    if [ -n "$body" ]; then printf 'cat %q\n' "$body"; else printf 'exit 1\n'; fi
  } > "$TMP_ROOT/bin/gh"
  chmod +x "$TMP_ROOT/bin/gh"
  sed -e "s|{plugin_root}|$PLUGIN_ROOT|g" -e 's|{issue_number}|1|g' -e 's|{owner_repo}|o/r|g' "$block_131" > "$script"
  rm -f "$TMP_ROOT"/rite-review-issue-body-*
  RUN_OUT=$(PATH="$TMP_ROOT/bin:$PATH" TMPDIR="$TMP_ROOT" bash "$script" 2>&1)
  RUN_RC=$?
}
# 1.3.1 の mktemp が TMPDIR 直下に残した本文ファイルの件数
body_tmp_count() { find "$TMP_ROOT" -maxdepth 1 -name 'rite-review-issue-body-*' | wc -l | tr -d ' '; }
run_131 ""
if [ "$RUN_RC" -ne 0 ] && grep -q '^\[review:error\]$' <<<"$RUN_OUT"; then pass "1.3.1 実行: gh 失敗で [review:error]"; else fail "1.3.1 実行: gh 失敗 (rc=$RUN_RC out=$RUN_OUT)"; fi
assert "1.3.1 実行: gh 失敗で一時ファイルを残さない" "0" "$(body_tmp_count)"
printf '## 5. Acceptance Criteria\n\n- 小見出しなし\n' > "$TMP_ROOT/body-noids.md"
run_131 "$TMP_ROOT/body-noids.md"
if [ "$RUN_RC" -ne 0 ] && grep -q 'reason=no_ac_ids' <<<"$RUN_OUT" && grep -q '^\[review:error\]$' <<<"$RUN_OUT"; then pass "1.3.1 実行: AC 節ありで 0 件は [review:error]"; else fail "1.3.1 実行: 0 件 (rc=$RUN_RC out=$RUN_OUT)"; fi
assert "1.3.1 実行: 0 件の停止で一時ファイルを残さない" "0" "$(body_tmp_count)"
printf '## 5. Acceptance Criteria\n\n### AC-1: a\n\n### AC-2: b\n' > "$TMP_ROOT/body-target.md"
run_131 "$TMP_ROOT/body-target.md"
if [ "$RUN_RC" -eq 0 ] && grep -qF '[CONTEXT] ACCEPTANCE_SCOPE=target; ids=AC-1,AC-2' <<<"$RUN_OUT"; then pass "1.3.1 実行: 対象 Issue は target と AC 集合"; else fail "1.3.1 実行: target (rc=$RUN_RC out=$RUN_OUT)"; fi
# 陽性対照: 抽出成功時は後段が削除するまで残るため、件数の glob が実際の mktemp 名に一致することを示す
assert "1.3.1 実行: 抽出成功時は一時ファイルが残る (glob の陽性対照)" "1" "$(body_tmp_count)"
printf '## 概要\n\n本文のみ\n' > "$TMP_ROOT/body-none.md"
run_131 "$TMP_ROOT/body-none.md"
if [ "$RUN_RC" -eq 0 ] && grep -qF 'ACCEPTANCE_SCOPE=skipped; reason=no_ac_section' <<<"$RUN_OUT" && ! grep -q 'review:error' <<<"$RUN_OUT"; then pass "1.3.1 実行: AC 節なしは skipped で続行"; else fail "1.3.1 実行: skipped (rc=$RUN_RC out=$RUN_OUT)"; fi

for heading in '受入基準' '受入条件' '受け入れ条件' 'Acceptance Criteria'; do
  printf '## %s\n- [ ] AC-1: criterion\n' "$heading" > "$TMP_ROOT/body-localized.md"
  run_131 "$TMP_ROOT/body-localized.md"
  if [ "$RUN_RC" -eq 0 ] && grep -Fq 'ACCEPTANCE_SCOPE=target; ids=AC-1' <<<"$RUN_OUT" \
    && ! grep -Fq 'ACCEPTANCE_SCOPE=skipped' <<<"$RUN_OUT"; then
    pass "1.3.1 実行: $heading checkboxはreview対象"
  else fail "1.3.1 localized (rc=$RUN_RC out=$RUN_OUT)"; fi
done
printf '## 受入基準\n- [ ] AC-1: valid\n- [ ] IDなしの条件\n' > "$TMP_ROOT/body-malformed-localized.md"
run_131 "$TMP_ROOT/body-malformed-localized.md"
if [ "$RUN_RC" -ne 0 ] && grep -Fq 'reason=malformed_ac_item' <<<"$RUN_OUT" \
  && grep -Fxq '[review:error]' <<<"$RUN_OUT" && ! grep -Fq 'ACCEPTANCE_SCOPE=skipped' <<<"$RUN_OUT"; then
  pass "1.3.1 実行: 不正な日本語AC節はskipせずreviewを停止"
else fail "1.3.1 malformed localized (rc=$RUN_RC out=$RUN_OUT)"; fi

echo ""
echo "=== TC-3: 5.1.0.AC 判定表 post-condition (T-06) ==="
in_order "5.1.0.AC は 5.1.0.L の後・5.1.1 の前" \
  "$(line_of "$PR_REVIEW" '##### 5.1.0.L Likelihood-Evidence Producer Post-Condition')" \
  "$(line_of "$PR_REVIEW" '##### 5.1.0.AC 受入条件確認の判定表 Post-Condition')" \
  "$(line_of "$PR_REVIEW" '#### 5.1.1 Verification Mode Findings Collection')"
pin "5.1.0.AC: table を Issue の AC 集合で実行" "$PR_REVIEW" '--expected "{acceptance_ids}" --input "{raw_reviewer_output_file}"'
pin "5.1.0.AC: 集合不一致は reroll 1 回" "$PR_REVIEW" 'id_set_mismatch, status_invalid, evidence_missing, unmet_finding_missing}`, first occurrence | acceptance reviewer を 1 回だけ reroll する'
pin "5.1.0.AC: reroll 後の再発は [review:error]" "$PR_REVIEW" '| rc=1 after the one reroll、その他の reason、rc=2 | `[review:error]` で停止する。aggregation へ進まない |'
pin "5.1.1.1: acceptance は修正検証結果の対象外" "$PR_REVIEW" '`acceptance` の出力は対象外（判定表が前回指摘の解消検証を兼ねる）'
pin "5.2: acceptance の指摘は dedup で統合しない" "$PR_REVIEW" '`acceptance-reviewer` の指摘は他の指摘と統合しない'

echo ""
echo "=== TC-4: 5.3.0.A 最終整合検査 (T-07) ==="
in_order "5.3 実行順: 5.3.0.C → 5.3.0.A → 5.3.1-5.3.7" \
  "$(line_of "$PR_REVIEW" '3. **5.3.0.C 帰結クラス降格政策**')" \
  "$(line_of "$PR_REVIEW" '4. **5.3.0.A 受入条件の最終整合検査**')" \
  "$(line_of "$PR_REVIEW" '5. **5.3.1-5.3.7**')"
in_order "5.3.0.A 節は 5.3.0.C の後・5.3.8 の前" \
  "$(line_of "$PR_REVIEW" '#### 5.3.0.C 帰結クラス降格政策実行手順')" \
  "$(line_of "$PR_REVIEW" '#### 5.3.0.A 受入条件の最終整合検査')" \
  "$(line_of "$PR_REVIEW" '### 5.3.8 Fix-Introduced Finding Attribution')"
in_order "5.3.0.A 節は 6.1.a より前" \
  "$(line_of "$PR_REVIEW" '#### 5.3.0.A 受入条件の最終整合検査')" \
  "$(line_of "$PR_REVIEW" '#### 6.1.a Local JSON File Save')"
pin "5.3.0.A: final を Issue の AC 集合で実行" "$PR_REVIEW" '--expected "{acceptance_ids}" --input {review_tmp_dir}/rite-review-result-{pr_number}.json'
pin "1.3.1: no_issue 分岐で {acceptance_ids} を空文字列" "$PR_REVIEW" '`受入条件確認: 対象外（関連 Issue なし）` を 1 行表示し、`{acceptance_ids}` を空文字列としてステップ 5.3.0.A まで retain する'
pin "1.3.1: no_ac_section の cycle は {acceptance_ids} を空文字列" "$PR_REVIEW" '`skipped; reason=no_ac_section` の cycle では `{acceptance_ids}` を空文字列とする'
pin "2.2: prev_finders の acceptance は合流させない" "$PR_REVIEW" '`{prev_finders}` の `acceptance` は合流させない（ステップ 3.2.2 が cap 後に毎 cycle 追加する）'
pin "3.2.2: 既に acceptance があれば追加しない" "$PR_REVIEW" '`{selected_reviewers}` に既に `acceptance` があれば追加しない'
pin "5.3.0.A: unverified への書き換え禁止" "$PR_REVIEW" '`acceptance_criteria[].status` を `unverified` に書き換えて通してはならない'
pin "5.3.0.A: reroll 後は降格ゲートを通してから再検査" "$PR_REVIEW" '5.1 の回収完了ゲート → 5.1.0.L → 5.1.0.AC → 5.1.2.A → 5.2 → 5.2.1 → 5.2.2 → Fact-Checking → 5.3.0 → 5.3.0.M step 1 → step 2 → step 3 → 5.3.0.C → 本検査を同 cycle 内で再実行する'
pin "5.3.0.A: reroll の再実行は置き換わった acceptance の finding に限る" "$PR_REVIEW" '再実行する 5.2 / 5.2.1 / 5.2.2 / Fact-Checking の対象は reroll で置き換わった acceptance の finding（既存 finding との矛盾検出を含む）とし、他 reviewer の finding、初回に決まった矛盾の disposition、fact-check 判定は保持する'
pin "5.3.0.A: reroll は Verification 追加だけで 5.2.2 不採用を再採用しない" "$PR_REVIEW" '5.2.2 不採用は Verification 追加だけで再採用しない'
pin "5.3.0.M step 1: acceptance_criteria を常に書く" "$PR_REVIEW" '- **`acceptance_criteria` を常に書く**'

echo ""
echo "=== TC-5: 8.0 / 8.1 の停止行 (T-04) ==="
COND='`total_findings == 0` かつ `{acceptance_unverified}` が非空'
pin "8.0: 停止行が同じ条件文言" "$PR_REVIEW" "| \`[review:error]\`（受入条件未検証: ${COND}）"
pin "8.1: 停止行が同じ条件文言" "$PR_REVIEW" "| ${COND}（受入条件未検証） | \`[review:error]\` と \`[CONTEXT] REVIEW_STOP=ac_unverified; ac={acceptance_unverified}\` |"
in_order "8.1: 停止行は mergeable 行より前 (上から評価)" \
  "$(line_of "$PR_REVIEW" "| ${COND}（受入条件未検証） |")" \
  "$(line_of "$PR_REVIEW" '| `total_findings == 0` (blocking findings ゼロ) | `[review:mergeable]` |')"
stop_set=$(awk '/^# 受入条件未検証の停止 \(--handoff を付けず/{s=1; next} s && /^```$/{exit} s' "$PR_REVIEW")
if grep -q 'flow-state.sh set' <<<"$stop_set" && ! grep -q -- '--handoff' <<<"$stop_set"; then
  pass "8.0: 停止の flow-state set は --handoff を付けない"
else
  fail "8.0: 停止の flow-state set (block=$stop_set)"
fi
# 6.5.1 は 8.1 の出力表を参照するだけで、停止行を迂回する独自の判定表を持たない
block_651=$(awk '/^#### 6\.5\.1 Next Step Branching by Invocation Source$/{s=1} /^## ステップ 7: /{s=0} s' "$PR_REVIEW")
if [ -n "$block_651" ] && ! grep -q '^| \*\*Merge OK\*\*' <<<"$block_651" && ! grep -q '^|.*total_findings == 0' <<<"$block_651"; then
  pass "6.5.1: 独自の判定表を持たない"
else
  fail "6.5.1: 判定表の行が残っている、または節を切り出せない"
fi
pin "6.5.1: 8.1 の出力表を上から評価する" "$PR_REVIEW" 'ステップ 8.1 の出力表を上から順に評価し、最初に一致した行の pattern を出す'
# ステップ 7 は終端の出力 (mergeable と受入条件未検証の停止) で実行し、fix-needed でだけ skip する。
# 受入条件未検証の停止には後続レビューが無く、skip すると候補が処分されずに消える
cond_651=$(grep -F '**Condition**:' <<<"$block_651")
if grep -qF '**Condition**: `[review:mergeable]` と、受入条件未検証の停止（ステップ 8.1 の受入条件未検証行に一致する `[review:error]`）のとき。' <<<"$cond_651"; then
  pass "6.5.1: ステップ 7 は mergeable と受入条件未検証の停止で実行"
else
  fail "6.5.1: ステップ 7 の実行条件 (condition=$cond_651)"
fi
if grep -qF '`[review:fix-needed:N]` では ステップ 7 を skip する。' <<<"$cond_651"; then
  pass "6.5.1: ステップ 7 は fix-needed で skip"
else
  fail "6.5.1: fix-needed の skip (condition=$cond_651)"
fi
assert "6.5.1: 受入条件未検証の停止で skip する旧条件が無い" "0" "$(grep -cF '受入条件未検証の停止を含む `[review:error]` では' "$PR_REVIEW")"
pin "E2E 表: ステップ 7 の実行条件が 6.5.1 と同じ" "$PR_REVIEW" '`[review:mergeable]` と受入条件未検証の停止のときに実行し、`[review:fix-needed:N]` では skip する。 |'
assert "E2E 表: mergeable だけで実行する旧条件が無い" "0" "$(grep -cF 'Only when `[review:mergeable]`.' "$PR_REVIEW")"
MUST_NOT_7='[review:fix-needed:{n}], or the acceptance-unverified stop [review:error] (REVIEW_STOP=ac_unverified) until ステップ 7'
MUST_NOT_7_OLD='[review:fix-needed:{n}] until ステップ 7'
assert "8.0.2: 2 つの ERROR 文が受入条件未検証の停止も止める" "2" "$(grep -cF -- "$MUST_NOT_7" "$PR_REVIEW")"
assert "8.0.2: 停止を含まない旧 MUST NOT が無い" "0" "$(grep -cF -- "$MUST_NOT_7_OLD" "$PR_REVIEW")"
assert "7.7: ERROR 文が受入条件未検証の停止も止める" "1" "$(grep -cF -- "$MUST_NOT_7" "$SCOPE_TRIAGE")"
assert "7.7: 停止を含まない旧 MUST NOT が無い" "0" "$(grep -cF -- "$MUST_NOT_7_OLD" "$SCOPE_TRIAGE")"
anchor_651=$(grep -A1 -F '**Condition**:' <<<"$block_651" | sed -n 's|^rationale: references/design-rationale\.md#||p')
if [ -n "$anchor_651" ]; then
  assert "6.5.1: rationale anchor の見出しが 1 つある" "1" "$(grep -cxF "## $anchor_651" "$RATIONALE")"
  rationale_651=$(awk -v heading="## $anchor_651" '
    $0 == heading { found=1; next }
    found && /^## / { exit }
    found { print }
  ' "$RATIONALE")
  if [ -n "$rationale_651" ]; then
    assert "6.5.1: rationale 本文が終端 2 経路での実行を説明する" "1" "$(grep -cF 'ステップ 7 を `[review:mergeable]` と受入条件未検証の停止で走らせ' <<<"$rationale_651")"
    assert "6.5.1: rationale 本文が受入条件未検証の停止を終端と説明する" "1" "$(grep -cF '受入条件未検証の停止はループの終端であり' <<<"$rationale_651")"
    assert "6.5.1: rationale 本文に mergeable 限定の旧理由が無い" "0" "$(grep -cF 'のときだけ走らせる理由' <<<"$rationale_651")"
  else
    fail "6.5.1: rationale anchor の節本文を切り出せる"
  fi
else
  fail "6.5.1: Condition の直後に rationale ポインタが無い"
fi
assert "rationale: 旧 anchor を参照しない" "0" "$(grep -cF 'step7-mergeable-only' "$PR_REVIEW" "$RATIONALE" | awk -F: '{s+=$NF} END {print s+0}')"
in_order "6.5.1: standalone の受入条件未検証分岐は Merge OK 分岐より前" \
  "$(line_of "$PR_REVIEW" '**受入条件未検証**（ステップ 8.1 の受入条件未検証行に一致）')" \
  "$(line_of "$PR_REVIEW" '**Merge OK**: Ready for review（推奨）')"
pin "8.0: 2 variant だけが handoff を付ける" "$PR_REVIEW" 'mergeable / fix-needed の 2 variant は `--handoff` を付け、受入条件未検証の停止行は付けない'
pin "stop-loop contract: 受入条件未検証は handoff を持たない" "$STOP_CONTRACT" '**受入条件未検証の `[review:error]`（`REVIEW_STOP=ac_unverified`）も handoff を持たない**'

echo ""
echo "=== TC-6: iterate の停止分岐 (T-05) ==="
in_order "iterate: REVIEW_STOP 行が汎用 [review:error] 行より前" \
  "$(line_of "$ITERATE" '| `[review:error]` + 行頭の `[CONTEXT] REVIEW_STOP=ac_unverified; ac={ids}` |')" \
  "$(line_of "$ITERATE" '| `[review:error]` | 可逆な再試行を推奨として 1 回だけ自動実行')"
pin "iterate: 再試行せず sentinel を出さない" "$ITERATE" '再試行せず、下記の停止通知を出して終了する（成功 sentinel も新しい sentinel も出さない）'
pin "iterate: 行頭 marker だけで判定" "$ITERATE" '`REVIEW_STOP` は行頭 `[CONTEXT] ` の marker だけを判定に使う'
pin "iterate: 停止通知の見出し" "$ITERATE" '## /rite:iterate 停止（受入条件未検証）'

echo ""
echo "=== TC-8: 正典 helper チェーン (T-01 / T-02 / T-03 / T-07 / T-08) ==="
SENTINEL="__RITE_TS_PLACEHOLDER_7f3a9b2c__"
printf '## 5. Acceptance Criteria\n\n### AC-1: a\n\n### AC-2: b\n\n### AC-3: c\n' > "$TMP_ROOT/issue.md"
ids=$(bash "$CHECK" extract --body-file "$TMP_ROOT/issue.md" 2>"$TMP_ROOT/extract.err")
if [ "$ids" = "AC-1,AC-2,AC-3" ]; then pass "TC-8 extract が AC 集合を返す"
else fail "TC-8 extract (out=$ids err=$(cat "$TMP_ROOT/extract.err"))"; fi

cat > "$TMP_ROOT/acceptance-out.md" <<'EOF'
### 評価: 要修正
### 所見
AC-2 が満たされていない。
### 受入条件確認
| AC | 判定 | 根拠 |
|----|------|------|
| AC-1 | 充足 | bash t.sh => PASS |
| AC-2 | 未充足 | 指摘事項 [AC-2] を参照 |
| AC-3 | 未検証 | 実環境が必要 |
### 指摘事項
| 重要度 | スコープ | ファイル:行 | 内容 | 推奨対応 |
|--------|----------|------------|------|----------|
| CRITICAL | current-pr | app.sh | [AC-2] 空入力で exit 0<br>Likelihood-Evidence: runtime_observation bash app.sh ''<br>Verification: repro bash app.sh '' => exit 0 | ガードを戻す |
### 監査ログ
なし
EOF
rows=$(bash "$CHECK" table --expected "$ids" --input "$TMP_ROOT/acceptance-out.md" 2>"$TMP_ROOT/table.err")
if [ "$(jq 'length' <<<"$rows" 2>/dev/null)" = 3 ]; then pass "TC-8 table が 3 行を返す"
else fail "TC-8 table (out=$rows err=$(cat "$TMP_ROOT/table.err"))"; fi

# 5.3.0.M step 1 形の JSON。$1 = file, $2 = description, $3 = rows JSON
step1_json() {
  jq -n --arg d "$2" --argjson rows "$3" --arg ts "$SENTINEL" '{
    schema_version: "1.1.0", pr_number: 4343, timestamp: $ts, commit_sha: "0123456789abcdef",
    overall_assessment: "fix-needed", reviewers: ["acceptance-reviewer", "test-reviewer"],
    findings: [{id: "F-01", reviewer: "acceptance-reviewer", category: "acceptance", severity: "CRITICAL",
      scope: "current-pr", file: "app.sh", line: null, description: $d, suggestion: "ガードを戻す", status: "open"}],
    non_blocking_findings: [], guardrail_audit_log: [],
    acceptance_criteria: ($rows | map(.finding_id = (if .status == "unmet" then "F-01" else null end)))}' > "$1"
}
DESC_ANCHOR="[AC-2] 空入力で exit 0<br>Likelihood-Evidence: runtime_observation bash app.sh ''<br>Verification: repro bash app.sh '' => exit 0"
step1_json "$TMP_ROOT/chain.json" "$DESC_ANCHOR" "$rows"
bash "$MGATE" --input "$TMP_ROOT/chain.json" --reject-preset-verification >/dev/null 2>&1
assert "TC-8 アンカー付き未充足で verdict fix-needed" "fix-needed" "$(jq -r '.verdict' "$TMP_ROOT/chain.json")"
final_err=$(bash "$CHECK" final --expected "$ids" --input "$TMP_ROOT/chain.json" 2>&1 >/dev/null); final_rc=$?
if [ "$final_rc" -eq 0 ] && grep -Fxq '[CONTEXT] ACCEPTANCE_FINAL=ok; unmet=AC-2; unverified=AC-3' <<<"$final_err"; then
  pass "TC-8 final が未充足の残存を確認し未検証 AC-3 を返す"
else fail "TC-8 final (rc=$final_rc err=$final_err)"; fi
assert "TC-8 gate 後も AC-2 行は unmet + finding_id" "unmet F-01" "$(jq -r '.acceptance_criteria[] | select(.id == "AC-2") | "\(.status) \(.finding_id)"' "$TMP_ROOT/chain.json")"

mkdir -p "$TMP_ROOT/results"
bash "$SAVE" --pr 4343 --content-file "$TMP_ROOT/chain.json" --results-dir "$TMP_ROOT/results" >/dev/null 2>"$TMP_ROOT/save.err"
saved=$(find "$TMP_ROOT/results" -name '4343-*.json' | head -1)
if [ -n "$saved" ] && grep -q 'JSON_SAVED=true' "$TMP_ROOT/save.err"; then pass "TC-8 正典チェーンの JSON が保存される"; else fail "TC-8 保存 ($(head -3 "$TMP_ROOT/save.err" | tr '\n' ' '))"; fi
assert "TC-8 保存 JSON が acceptance_criteria を保持する" \
  "$(jq -cS '.acceptance_criteria' "$TMP_ROOT/chain.json")" "$(jq -cS '.acceptance_criteria' "$saved" 2>/dev/null)"
assert "TC-8 保存 JSON の reviewers に acceptance-reviewer" "true" "$(jq '.reviewers | index("acceptance-reviewer") != null' "$saved" 2>/dev/null)"

step1_json "$TMP_ROOT/chain-noanchor.json" "[AC-2] 空入力で exit 0<br>Likelihood-Evidence: runtime_observation bash app.sh ''" "$rows"
bash "$MGATE" --input "$TMP_ROOT/chain-noanchor.json" --reject-preset-verification >/dev/null 2>&1
bash "$CHECK" final --expected "$ids" --input "$TMP_ROOT/chain-noanchor.json" >/dev/null 2>"$TMP_ROOT/final-noanchor.err"; rc=$?
if [ "$rc" -eq 1 ] && grep -q 'reason=unmet_finding_not_blocking' "$TMP_ROOT/final-noanchor.err" \
  && [ "$(jq -r '.non_blocking_findings[0].id' "$TMP_ROOT/chain-noanchor.json")" = "F-01" ] \
  && [ "$(jq -r '.acceptance_criteria[1].status' "$TMP_ROOT/chain-noanchor.json")" = "unmet" ]; then
  pass "TC-8 アンカー欠落の未充足は non_blocking へ降格し final が rc=1 (行は unmet のまま)"
else fail "TC-8 アンカー欠落 (rc=$rc $(cat "$TMP_ROOT/final-noanchor.err"))"; fi

allrows=$(jq -c 'map(.status = "satisfied")' <<<"$rows")
jq -n --argjson rows "$allrows" --arg ts "$SENTINEL" '{schema_version: "1.1.0", pr_number: 4344, timestamp: $ts,
  commit_sha: "0123456789abcdef", overall_assessment: "fix-needed", reviewers: ["acceptance-reviewer", "test-reviewer"],
  findings: [], non_blocking_findings: [], guardrail_audit_log: [],
  acceptance_criteria: ($rows | map(.finding_id = null))}' > "$TMP_ROOT/all.json"
bash "$MGATE" --input "$TMP_ROOT/all.json" --reject-preset-verification >/dev/null 2>&1
final_err=$(bash "$CHECK" final --expected "$ids" --input "$TMP_ROOT/all.json" 2>&1 >/dev/null); final_rc=$?
if [ "$final_rc" -eq 0 ] && [ "$(jq -r '.verdict' "$TMP_ROOT/all.json")" = "mergeable" ] \
  && grep -Fxq '[CONTEXT] ACCEPTANCE_FINAL=ok; unmet=; unverified=' <<<"$final_err"; then
  pass "TC-8 全充足は verdict mergeable で未検証なし"
else fail "TC-8 全充足 ($final_err)"; fi

echo ""
echo "=== TC-7: fix 1.2.2 の保持 (T-13) ==="
pin "fix 1.2.2: P1/P3 の再保存で acceptance_criteria を保持" "$FIX" '元の gate receipt と verification、`acceptance_criteria` を保持'
if [ -n "${saved:-}" ]; then
  cp "$saved" "$TMP_ROOT/triage.json"
  bash "$MAPS" --review-source local_file --review-source-path "$TMP_ROOT/triage.json" --repo-root "$REPO_ROOT" >/dev/null 2>"$TMP_ROOT/maps.err"
  maps_rc=$?
  if [ "$maps_rc" -eq 0 ] && [ "$(jq -cS '.acceptance_criteria' "$TMP_ROOT/triage.json")" = "$(jq -cS '.acceptance_criteria' "$saved")" ]; then
    pass "TC-7 review-findings-maps.sh の in-place triage 後も acceptance_criteria が残る"
  else
    fail "TC-7 triage (rc=$maps_rc $(head -3 "$TMP_ROOT/maps.err" | tr '\n' ' '))"
  fi
else
  fail "TC-7 triage (TC-8 の保存 JSON が無い)"
fi

echo ""
echo "=== TC-9: schema / レポート / docs の同期 (T-02 / T-14) ==="
pin "schema: トップレベル行" "$SCHEMA" '| `acceptance_criteria` | array \| object | write 側 ✅ (1.1.0 additive) |'
pin "schema: status enum" "$SCHEMA" '`"satisfied"` (充足) / `"unmet"` (未充足) / `"unverified"` (未検証)'
pin "schema: skip 形" "$SCHEMA" '`{"skipped": "no_issue"}`（関連 Issue を特定できない）/ `{"skipped": "no_ac_section"}`'
pin "5.4: 受入条件確認の情報源と例外 7" "$PR_REVIEW" '**`### 受入条件確認` の情報源**: ゲート適用済 JSON の `acceptance_criteria` を Read して描画する'
pin "E2E: 例外 7" "$PR_REVIEW" '**例外 7: ステップ 5.4 の `### 受入条件確認` section は E2E でも省略禁止**'
assert "templates: full / verification の両方に受入条件確認" "2" "$(grep -c '^### 受入条件確認$' "$TEMPLATES")"
assert "templates: 両方の判定表で finding_id を根拠列に書く" "2" "$(grep -cF '| {ac_id} | 充足 / 未充足 / 未検証 | {evidence}（未充足行は {finding_id} を併記） |' "$TEMPLATES")"
assert "templates: 判定列に finding_id を書く旧形式が無い" "0" "$(grep -cF '未充足（{finding_id}）' "$TEMPLATES")"
pin "SPEC: Current Agents 表に acceptance-reviewer" "$REPO_ROOT/docs/SPEC.md" '| `acceptance-reviewer` | inherit | high |'
pin "SPEC: pr-review の並列 spawn 図に acceptance-reviewer" "$REPO_ROOT/docs/SPEC.md" ' └─ acceptance-reviewer:'
pin "CLAUDE.md: reviewer 数" "$REPO_ROOT/CLAUDE.md" "+ 10 reviewer agent"
pin "SPEC: agents 一覧" "$REPO_ROOT/docs/SPEC.md" "│ ├── acceptance-reviewer.md"
pin "CONFIGURATION: Available reviewers 表" "$REPO_ROOT/docs/CONFIGURATION.md" '| `acceptance-reviewer` |'

if ! print_summary "$(basename "$0")" "drift: acceptance reviewer の配線 (agent / reviewers SKILL / pr-review 1.3.1・3.2.2・5.1.0.AC・5.3.0.A・6.5.1・E2E 表・8.0・8.0.2・8.1 / scope-triage 7.7 / design-rationale / iterate ステップ 2 / fix 1.2.2 / review-result-schema) のいずれかが変更された可能性"; then
  exit 1
fi
