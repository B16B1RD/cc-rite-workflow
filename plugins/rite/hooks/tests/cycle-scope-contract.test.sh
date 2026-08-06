#!/bin/bash
# Tests for the cycle 2+ 差分スコープ / reviewer 動的選抜 contract (Issue #2118).
#
# pr-review / reviewers は散文駆動スキル (LLM 実行、script ではない) のため、
# outstanding-items-contract.test.sh と同じ static-contract 方式で literal を grep-pin する。
# 判定ロジック本体 (JSON 探索・fail-safe 分岐) は scripts/review-cycle-scope.sh に切り出され
# scripts/tests/review-cycle-scope.test.sh が挙動を検証するので、本 suite が守るのは
# **散文側にしか存在しない契約** — 選抜の合成規則・テンプレート合成・観測性の 3 つに絞る。
#
# 感度に関する注意 (outstanding-items-contract.test.sh が記録した教訓の適用):
# 単語 1 個の pin はセクション内の別行にも同語が出現すると mutation を素通りさせる。
# 本 suite は「隣接して現れること」を 1 本の line-anchored パターンで pin することで、
# 合成 (例: prev_finders と mandatory が同じ規則として書かれていること) が消えたら落ちるようにする。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

PR_REVIEW="$SCRIPT_DIR/../../skills/pr-review/SKILL.md"
REVIEWERS="$SCRIPT_DIR/../../skills/reviewers/SKILL.md"
CYCLE_SCOPE="$SCRIPT_DIR/../../skills/pr-review/references/cycle-scope.md"
PROMPT_GEN="$SCRIPT_DIR/../../skills/pr-review/references/reviewer-prompt-generator.md"
REPORT_TPL="$SCRIPT_DIR/../../skills/pr-review/references/integrated-report-templates.md"
HELPER="$SCRIPT_DIR/../../scripts/review-cycle-scope.sh"

echo "=== ステップ 1.2.4: スコープ決定は helper へ委譲し永続 JSON を入力とする (AC-1 / T-01) ==="
assert_file_exists_or_fail "review-cycle-scope.sh exists" "$HELPER"
assert_grep "1.2.4 invokes the cycle-scope helper" "$PR_REVIEW" \
  'scripts/review-cycle-scope\.sh --pr \{pr_number\}'
assert_grep "1.2.4 declares the persistent JSON as the sole input" "$PR_REVIEW" \
  '判定入力は ステップ 6\.1\.a が書く永続レビュー JSON のみ'
# full/incremental の 2 値分岐表が本体に残っていること (marker を読んだ後の行動を決める唯一の表)
assert_grep "1.2.4 keeps the full/incremental branch table in the body" "$PR_REVIEW" \
  '^\| `incremental` \| `\{cycle_base_sha\}\.\.HEAD` の diff \+ 前回 blocking の解消検証'

echo "=== ステップ 1.2.4: fail-safe は必ず full へ倒れる (AC-3 / T-03) ==="
# reason 語彙の列挙と「reason は分岐を変えない (全て full)」が 1 行に同居していることを pin する。
# 語彙だけの pin だと「full へ倒す」規則が消えても green のままになる。
assert_grep "1.2.4 enumerates every fail-safe reason and pins that they all fall back to full" "$PR_REVIEW" \
  'no_prev_json.*prev_json_unreadable.*commit_sha_missing.*commit_sha_unreachable.*diff_failed.*jq_missing.*reason は分岐を変えない.*`full`'
assert_grep "helper docstring is the reason SoT" "$HELPER" \
  'Fallback reason 語彙 \(SoT'
assert_grep "cycle-scope.md forbids narrowing on missing information" "$CYCLE_SCOPE" \
  '狭いスコープで妥協する」経路は持たない'
assert_grep "cycle-scope.md states the safe side is always the wider scope" "$CYCLE_SCOPE" \
  '安全側は常に\*\*広い方\*\*'
# reason 語彙は helper docstring が SoT だが、SKILL.md と cycle-scope.md にコピーがある。
# 3 コピーのどれかが欠けると「その経路は fail-safe しない」と読める記述が残る。
# jq_missing は cycle-scope.md の表から実際に欠落していた (SKILL.md と helper には存在)。
for _f in "$HELPER" "$PR_REVIEW" "$CYCLE_SCOPE"; do
  for _r in no_prev_json prev_json_unreadable commit_sha_missing commit_sha_unreachable diff_failed jq_missing; do
    assert_grep "$(basename "$_f") documents reason '$_r'" "$_f" "$_r"
  done
done
# helper が marker を出せない経路 (usage error) の consumer 側既定。helper の reason 語彙では
# 表現できないため SKILL.md 側に置く必要がある。
assert_grep "1.2.4 defines the consumer-side default when the helper emits no marker" "$PR_REVIEW" \
  'marker を観測できない場合も `full` として扱い'
# helper が marker を出せない経路の reason リテラル。他 6 reason は 3 コピー同期 pin に載っているが
# 本 reason だけは consumer 側にしか存在せず、drift 検査から外れていた。
assert_grep "helper_failed literal is documented in the SoT" "$CYCLE_SCOPE" 'helper_failed'
# consumer 側の {previous_blocking_findings} にも helper と同じ gated scope 規則が要る。
# helper 側は TC-14 が挙動で守るが、この規則を削って findings[] 全体を注入する変異は
# 本 pin が無いと両スイートを素通りする（受け流し済み nit が解消検証 mandate へ毎サイクル注入される）。
assert_grep "1.2.4 gates {previous_blocking_findings} to blocking scopes" "$PR_REVIEW" \
  '\{previous_blocking_findings\}.*scope ∈ \{current-pr, follow-up\}'
# 母集団は helper の prev_finders と同一（2 配列の和）。片方だけに戻す変異は helper 側 TC-14b が
# 守るが、consumer 側の散文は本 pin が唯一の防御。
assert_grep "1.2.4 reads both findings[] and non_blocking_findings[]" "$PR_REVIEW" \
  '\{previous_blocking_findings\}.*`findings\[\]` と `non_blocking_findings\[\]` の和'

echo "=== ステップ 2.2: 選抜は cap 後の filter でなくマッチ入力の差し替え (AC-2 / AC-4 / T-02 / T-04) ==="
assert_grep "2.2 substitutes the matching input with the fix diff" "$PR_REVIEW" \
  '^\| `incremental` \| `git diff --name-only \{cycle_base_sha\}\.\.HEAD` の結果'
assert_grep "2.2 keeps the pattern table itself unchanged across cycles" "$PR_REVIEW" \
  'パターン表は cycle で変わらない'
# AC-2 の核: 前サイクル finder の合流が **mandatory** であること。`recommended` では
# max_reviewers cap に落とされ「無条件に再起動」が破れる — 両者を 1 行で pin する。
assert_grep "2.2 merges previous-cycle finders as mandatory (not recommended)" "$PR_REVIEW" \
  '\{prev_finders\}.*`selection_type: mandatory`.*`recommended` は不可.*cap'
assert_grep "2.2 preserves the existing guards/floors unchanged" "$PR_REVIEW" \
  'sole-reviewer guard.*Security Expert 条件.*cap とフロアは\*\*すべて従来どおり適用する\*\*'
assert_grep "2.2 forbids silent narrowing and names both record channels" "$PR_REVIEW" \
  'ステップ 5\.4 の「レビュー範囲」section に記録.*silent な絞り込みは禁止'

echo "=== reviewers/SKILL.md: 選抜表は複製せず入力定義だけを追記 (AC-2 / D-06) ==="
assert_grep "Phase 1 redefines 'changed file' per REVIEW_CYCLE_SCOPE" "$REVIEWERS" \
  '"changed file" の定義は review cycle で変わる'
assert_grep "Phase 1 states the incremental input is the fix diff" "$REVIEWERS" \
  '`incremental`（cycle 2\+）.*git diff --name-only \{cycle_base_sha\}\.\.HEAD'
assert_grep "Phase 1 pins the mandatory merge and its cap rationale" "$REVIEWERS" \
  'mandatory.*として合流.*Phase 5 が落とさないことを保証しているのは `mandatory` のみ'
# 選抜表の複製を禁じる: Available Reviewers 表は 1 つだけであること
reviewer_table_headers=$(grep -c '^| Reviewer | Agent | File Patterns' "$REVIEWERS" || true)
assert "reviewers/SKILL.md keeps exactly one Available Reviewers table (no cycle-2+ duplicate)" \
  "1" "$reviewer_table_headers"

echo "=== reviewer prompt: 差分スコープ mandate の注入 (AC-1 / T-01) ==="
assert_grep "prompt template has the conditional cycle-scope section" "$PROMPT_GEN" \
  '\{cycle_scope_mandate\}'
assert_grep "prompt template marks the section conditional on incremental" "$PROMPT_GEN" \
  'REVIEW_CYCLE_SCOPE == incremental のときのみ内容が入る'
assert_grep "4.5 placeholder table wires cycle_scope_mandate to cycle-scope.md" "$PR_REVIEW" \
  '\| `\{cycle_scope_mandate\}` \|.*cycle-scope\.md'
assert_grep "4.5 scopes relevant_files to the fix diff under incremental" "$PR_REVIEW" \
  '\{relevant_files\}.*REVIEW_CYCLE_SCOPE == incremental.*\{cycle_base_sha\}\.\.HEAD'
assert_grep "4.5 scopes diff_content to the fix diff under incremental" "$PR_REVIEW" \
  '\{diff_content\}.*REVIEW_CYCLE_SCOPE == incremental.*\{cycle_base_sha\}\.\.HEAD'

echo "=== mandate 4 項目: 解消検証 / fix diff フル / Cross-File 維持 / 未変更部の再監査禁止 ==="
# mandate 1 の語は SoT 宣言・合成理由・注入本文の 3 箇所に出るため、単語 pin だと
# **注入本文から mandate 1 を削除しても残り 2 箇所で満たされ green のまま**になる
# (mandate 2/3/4 の pin は 1 箇所固有で問題ない — 本項だけが header の
# 「単語 1 個の pin は素通りする」教訓に違反していた)。注入本文の行形でアンカーする。
assert_grep "mandate 1: previous blocking resolution verification (注入本文の行形で pin)" "$CYCLE_SCOPE" \
  '^1\. \*\*前回 blocking の解消検証\*\*'
# 同 block の placeholder も未 pin だった。mandate 1 は前回指摘の一覧を、mandate 2 は差分の起点を
# それぞれ埋め込む必要があり、どちらが落ちても reviewer は解消検証 / 差分スコープを実行できない。
assert_grep "mandate block injects the previous blocking findings placeholder" "$CYCLE_SCOPE" \
  '^\{previous_blocking_findings\}$'
assert_grep "mandate block injects the diff base placeholder" "$CYCLE_SCOPE" \
  '\{cycle_base_sha\}\.\.HEAD'
assert_grep "mandate 2: fix diff reviewed at unchanged depth (scope narrows, criteria do not)" "$CYCLE_SCOPE" \
  'レビュー対象の\*\*範囲\*\*を絞るものであって、範囲内の\*\*基準\*\*を緩めるものではない'
# 契約 (§4.4 MUST NOT / AC-4 の Then) に文として現れる 2 本は、肯定句の存在だけを見ると
# 削除・言い換えの変異を素通りするため、**文の続き**まで pin を伸ばす。
# **撤回節の追記（「… という規則は cycle 2+ では適用しません」を後ろに足す変異）はこれでも
# 検出できない** — 実測で確認済みで、pin の書き方の問題ではなく肯定リテラルの grep では
# 加法的否定を検出できないという手法の限界。**同じ理由で必ず失敗するのでパターンを足さないこと**
# （1 cycle を空転させる）。当該クラスの検出は散文の意味レビュー側の責務。
assert_grep "mandate 3: Cross-File Impact Check is NOT reduced (文の続きまで pin)" "$CYCLE_SCOPE" \
  'Cross-File Impact Check は縮小しない\*\*: fix が触った symbol'
assert_grep "mandate 4: no re-audit of unchanged code" "$CYCLE_SCOPE" \
  '未変更部の再監査はしない'
assert_grep "mandate: out-of-previous-scope files get full scope (AC-4、文の続きまで pin)" "$CYCLE_SCOPE" \
  '^fix が前回レビュー範囲外のファイルへ触れている場合、そのファイルは.*フルスコープで審査'

echo "=== verification_mode との合成: incremental では 4.5.1 を注入しない (AC-5 / D-05) ==="
assert_grep "1.2.4.1 is skipped entirely when scope is incremental" "$PR_REVIEW" \
  'REVIEW_CYCLE_SCOPE == incremental. のときは .review_mode = .full.. を強制し\*\*本サブステップ全体を skip\*\* する'
# テンプレート選択表に incremental 行があり、そこで 4.5.1 を注入しないと書かれていること
assert_grep "4.5.1 template-selection table pins the incremental row as 4.5-only" "$PR_REVIEW" \
  '^\| `incremental` \|.*Normal template from ステップ 4\.5 のみ.*本節 4\.5\.1 のテンプレートは注入しない'
assert_grep "cycle-scope.md documents the composition rule" "$CYCLE_SCOPE" \
  '4\.5\.1 の検証テンプレートは\*\*追加注入しない\*\*'

echo "=== 終了意味論の不変 (AC-5 / T-05) ==="
assert_grep "cycle-scope.md pins that assessment semantics and gate composition are unchanged" "$CYCLE_SCOPE" \
  'ステップ 5\.3 系の判定・実測必須ゲート・帰結クラス Gate との合成順序も不変'
assert_grep "cycle-scope.md grounds the exit semantics on cycle 1 staying full" "$CYCLE_SCOPE" \
  '未変更部は cycle 1 で審査済み'

echo "=== cycle-count degradation 禁止規範との整合 ==="
assert_grep "cycle-scope.md explains why binary scoping is not progressive relaxation" "$CYCLE_SCOPE" \
  'cycle 数が増えても挙動は一切変わらない'
assert_grep "cycle-scope.md states no cycle-number threshold comparison exists" "$CYCLE_SCOPE" \
  'cycle 番号を数えて閾値と比較する経路を持たない'

echo "=== 観測性: 選抜結果は統合レポートに記録し E2E でも省略しない (AC-2 / MUST) ==="
assert_grep "integrated report template has the レビュー範囲 section" "$REPORT_TPL" \
  '^### レビュー範囲（cycle 2\+ 差分スコープ）（該当がある場合のみ）'
assert_grep "the section records skipped reviewers with reasons" "$REPORT_TPL" \
  '\{skipped_reviewers_with_reason\}'
assert_grep "the section's reason column enumerates selection rationales" "$REPORT_TPL" \
  '前サイクル finder（mandatory 合流）/ fix diff の領域担当'
# E2E minimization の例外に載っていること。これが無いと cycle 2+ (= E2E からしか起きない) で
# 記録が消え、観測性の MUST が空文になる。例外番号と section 名を 1 行で pin する。
assert_grep "E2E minimization table exempts the レビュー範囲 section" "$PR_REVIEW" \
  '例外 1: ステップ 5\.4 の `### レビュー範囲（cycle 2\+ 差分スコープ）` section は `REVIEW_CYCLE_SCOPE == incremental` のとき E2E でも省略禁止'
assert_grep "the pre-existing 実測なし指摘 E2E exemption is preserved" "$PR_REVIEW" \
  '例外 2: ステップ 5\.4 の `### 実測なし指摘 \(non-blocking\)` section は `non_blocking_count > 0` のとき E2E でも省略禁止'
assert_grep "5.4 requires rendering the section only under incremental" "$PR_REVIEW" \
  'REVIEW_CYCLE_SCOPE == incremental` のときのみ描画する'

echo "=== cycle 1 の不変 (Non-goal) ==="
assert_grep "cycle-scope.md pins cycle 1 as unchanged" "$CYCLE_SCOPE" \
  'cycle 1 のフルレビュー（全 reviewer・フル diff）は一切変更しない'
# reviewer prompt の通常テンプレートは cycle 1 でも使われるため、mandate は条件付きであること
assert_grep "prompt template omits the section entirely when scope is full" "$PROMPT_GEN" \
  'full のときは空文字列'

print_summary "cycle-scope-contract"
