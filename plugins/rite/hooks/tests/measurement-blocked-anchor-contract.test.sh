#!/bin/bash
# T-01〜T-05: 静的検証済み指摘のアンカー添付必須 + 実測阻害 fail-loud surface
#
# reviewer / 統合層は散文駆動のため、cycle-scope-contract.test.sh と同じ
# static-contract 方式で literal を grep-pin する。実測必須ゲートの成功値と形式エラーそのものは
# scripts/tests/review-measured-gate.test.sh が挙動を検証する（T-05 非回帰）。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
REPO_ROOT="$(_helpers_resolve_repo_root "$SCRIPT_DIR")"

BASE_FILE="$REPO_ROOT/plugins/rite/agents/_reviewer-base.md"
PROMPT_GEN="$REPO_ROOT/plugins/rite/skills/pr-review/references/reviewer-prompt-generator.md"
SEVERITY="$REPO_ROOT/plugins/rite/references/severity-levels.md"
PR_REVIEW="$REPO_ROOT/plugins/rite/skills/pr-review/SKILL.md"
REPORT_TPL="$REPO_ROOT/plugins/rite/skills/pr-review/references/integrated-report-templates.md"
MEASURED_GATE="$REPO_ROOT/plugins/rite/scripts/review-measured-gate.sh"

echo "=== T-01: 検証実施済み指摘の Verification: 添付必須 ==="
assert_grep "_reviewer-base.md requires Verification: on executed verification" "$BASE_FILE" \
  '検証を実施した指摘には `Verification:` 添付を必須とする'
assert_grep "_reviewer-base.md forbids authoring that skips the anchor" "$BASE_FILE" \
  '検証できたのに添付しない authoring は禁止'
assert_grep "prompt 自問 5 requires mandatory Verification: attachment" "$PROMPT_GEN" \
  '確認した → `Verification:` アンカーを `内容` 列に\*\*必須添付\*\*する'
assert_grep "severity-levels.md treats static Verification: as measured input" "$SEVERITY" \
  '静的検証（grep / ファイル対照 / 配布物読解 / コマンド実行）で欠陥を確認した指摘に `Verification: repro` を添付すれば measured 判定の対象になる'

echo "=== T-02: 実測阻害は Measurement-Blocked: で構造化する ==="
assert_grep "_reviewer-base.md documents Measurement-Blocked: format" "$BASE_FILE" \
  'Measurement-Blocked: <ブロックされたコマンド> => <理由>'
assert_grep "_reviewer-base.md forbids silent demotion on blocked measurement" "$BASE_FILE" \
  '実測阻害は無言の降格にしない'
assert_grep "prompt 自問 5 routes blocked commands to Measurement-Blocked:" "$PROMPT_GEN" \
  '回避不能なら `Measurement-Blocked: <cmd> => <reason>` を添付する'
assert_grep "prompt example includes Measurement-Blocked: row" "$PROMPT_GEN" \
  'Measurement-Blocked: bash hooks/foo.sh && bash hooks/bar.sh => worktree isolation denied compound command'
assert_grep "severity-levels.md documents Measurement-Blocked: without changing measurement logic" "$SEVERITY" \
  'helper はこの marker を実測アンカーとして読まない（実測判定に介入しない）'

echo "=== T-03: 統合層が実測阻害の件数・内訳を surface する ==="
assert_grep "E2E minimization table exempts 実測阻害 as 例外 6" "$PR_REVIEW" \
  '例外 6: ステップ 5\.4 の `### 実測阻害` section は `measurement_blocked_count > 0` のとき E2E でも省略禁止'
assert_grep "5.4 documents 実測阻害 source and 例外 6" "$PR_REVIEW" \
  '本 section は E2E でも省略禁止（上記 E2E Output Minimization 表の例外 6）'
assert_grep "E2E output line includes measurement-blocked suffix" "$PR_REVIEW" \
  '\| measurement-blocked: \{measurement_blocked_count\}'
assert_grep "E2E suffix rule is count-gated" "$PR_REVIEW" \
  '`\| measurement-blocked: \{n\}` suffix は `measurement_blocked_count > 0` のときのみ付与する'
heading_count=$(grep -c '^### 実測阻害（該当がある場合のみ）$' "$REPORT_TPL" || true)
assert "integrated-report-templates.md has 実測阻害 heading in both templates" "2" "$heading_count"
assert_grep "template table has blocked-command and reason columns" "$REPORT_TPL" \
  '\| レビュアー \| 重要度 \| ファイル:行 \| ブロックされたコマンド \| 理由 \|'

echo "=== T-04: 原理的に検証不能な指摘は従来の non-blocking 経路 ==="
assert_grep "_reviewer-base.md keeps unverifiable findings on the legacy path" "$BASE_FILE" \
  '原理的に検証不能な指摘は従来経路'
assert_grep "_reviewer-base.md does not attach either marker when unverifiable" "$BASE_FILE" \
  '認証付き実環境アクセスが必要な指摘は、READ-ONLY を破らず `Verification:` も `Measurement-Blocked:` も付けずに報告する'
assert_grep "prompt 自問 5 keeps unverifiable findings marker-less" "$PROMPT_GEN" \
  '原理的に検証不能（認証付き実環境が必要等）→ どちらの marker も付けずに報告する'
assert_grep "severity-levels.md keeps unverifiable findings on the legacy record path" "$SEVERITY" \
  '原理的に検証不能（認証付き実環境が必要等）な指摘は本 marker も付けず、従来どおり non-blocking 記録経路へ倒す'

echo "=== T-05: 実測 marker の解釈非回帰（helper は Measurement-Blocked: を実測アンカーとして読まない） ==="
assert_not_grep "measured-gate detect regex does not mention Measurement-Blocked" "$MEASURED_GATE" \
  'Measurement-Blocked'
assert_grep "measured-gate still detects Verification: repro|failing_test only" "$MEASURED_GATE" \
  'Verification:\[\[:space:\]\]\*\(repro\|failing_test\)'
assert_grep "pr-review still says helper does not read Measurement-Blocked as a measured anchor" "$PR_REVIEW" \
  'helper は本 marker を実測アンカーとして読まない'

echo "=== T-06: anchor_undetermined は reviewer 再生成へ同 cycle 内で差し戻す ==="
# routing 行を切り出す。同じ文言が別 phase にあるだけでは契約を満たさない。
routing_file=$(mktemp)
trap 'rm -f "$routing_file"' EXIT
grep '^| .*reason=verification_preset_by_caller.*anchor_undetermined' "$PR_REVIEW" > "$routing_file" || true
assert "routing row is extracted exactly once" "1" "$(wc -l < "$routing_file" | tr -d ' ')"
assert_grep "routing rerolls only reviewers that emitted the diagnostic finding IDs" "$routing_file" \
  '診断の対象 finding IDs を出した reviewer のみ'
assert_grep "routing uses reviewer reject and reroll" "$routing_file" \
  'Reviewer reject \+ reroll'
# reroll 後の規則は「reroll 後の再実行」段落の 1 か所だけに書き、routing 行はそこを指す。
rule_file=$(mktemp)
trap 'rm -f "$routing_file" "$rule_file"' EXIT
grep '^\*\*reroll 後の再実行\*\*' "$PR_REVIEW" > "$rule_file" || true
assert "reroll rule paragraph is extracted exactly once" "1" "$(wc -l < "$rule_file" | tr -d ' ')"
assert_grep "routing row points to the reroll rule" "$routing_file" \
  '回収結果を下記「reroll 後の再実行」に従って統合・再実行してから、同 cycle 内で step 1 の JSON を作り直し step 2 を再実行する'
# routing 行は共有規則を指すだけなので、行全体を固定する（列挙・規則文・言い換えの追加を語の選び方に依らず落とす）。
routing_row_expected='| `[CONTEXT] MEASURED_GATE_FAILED=1; reason=verification_preset_by_caller` / `scope_enum_violation` / `anchor_undetermined` (helper 非ゼロ終了) | **同 cycle 内で契約違反を修復する。** preset は step 1 の JSON を作り直す。scope 違反または `anchor_undetermined` は診断の対象 finding IDs を出した reviewer のみ **Reviewer reject + reroll** とし、当該 reviewer を元 prompt（`{shared_reviewer_principles}` / `{prose_reviewer_principles}` / `{additional_reviewer_references}` を含む）+ 診断（対象 finding IDs と正規形アンカーの案内）で再生成させ、先頭行の読取完了申告も含める。アンカーは `Verification: repro <cmd> => <観測>` または `Verification: failing_test <path> => <失敗出力>`、raw pipe は `¦` と案内する。回収結果を下記「reroll 後の再実行」に従って統合・再実行してから、同 cycle 内で step 1 の JSON を作り直し step 2 を再実行する。`measured_gate_retry_count` が `1` なら `[review:error]` で停止する。`/rite:fix` に形式修正を渡さず、review cycle を増やさない |'
assert "routing row is the pointer row and states no other rule" "$routing_row_expected" "$(cat "$routing_file")"
assert "the reroll rule body appears once in pr-review" "1" "$(grep -o '通常どおりの条件で再実行' "$PR_REVIEW" | wc -l | tr -d ' ')"
# 作り直した出力の統合方法は丸ごと置き換えの 1 つだけで、5.1.1.1 の retry と同じ方式であること。
# 置き換え・破棄・他 reviewer 保持の 3 文を、段落の先頭から連続した文全体で固定し、文の極性反転や頭・間への例外の挿入も落とす。
replace_sentences='従う唯一の規則）: 作り直した出力は当該 reviewer の元の出力を丸ごと置き換える（5.1.1.1 の結果 merge 戦略と同じ。元 prompt を送り直すので元の出力と同じ範囲を対象にする）。元の出力を破棄し、作り直した出力のみを使う。他 reviewer の出力は保持する。'
if grep -qF -- "$replace_sentences" "$rule_file"; then
  pass "reroll rule replaces the original output, discards it, and keeps other reviewers' outputs"
else
  fail "reroll rule replaces the original output, discards it, and keeps other reviewers' outputs (sentences not found in rule paragraph)"
fi
# 相反文のうち 保持・差し替え・両方・元の出力・初回分・入れ替え の語を含むものを数で拒否する（語を避けた言い換えまでは拒否しない）。
assert "reroll rule has exactly one 保持 token" "1" "$(grep -o '保持' "$rule_file" | wc -l | tr -d ' ')"
assert "reroll rule has no 差し替え token" "0" "$(grep -o '差し替え' "$rule_file" | wc -l | tr -d ' ')"
assert_not_grep "reroll rule has no 両方 token" "$rule_file" '両方'
assert "reroll rule has exactly four 元の出力 tokens" "4" "$(grep -o '元の出力' "$rule_file" | wc -l | tr -d ' ')"
assert_not_grep "pr-review uses neither 初回分 nor 入れ替え for the reroll" "$PR_REVIEW" '初回分|入れ替え'
assert_grep "reroll rule reruns the normal path from the collection gate to 5.3.0 for the rerolled output" "$rule_file" \
  '5\.1 の回収完了ゲート（読取完了申告の照合を含む）から 5\.3\.0 までの通常経路の各段（5\.1 のゲート通過後の収集、5\.1\.0\.L、5\.1\.0\.AC を含む）を、作り直した出力に対して通常どおりの条件で再実行し'
# 作り直した reviewer が関わる初回の値は、他 reviewer と組み合わせた値（矛盾の合意と disposition）も含めて作り直す。
assert_grep "reroll rule rebuilds values made from the rerolled reviewer's original output" "$rule_file" \
  'のうち、当該 reviewer の元の出力から作られた値は作り直した出力から作り直して置き換える。他 reviewer の出力と組み合わせて作られた値（5\.2 の矛盾、5\.2\.1 の合意 finding と disposition、全 reviewer に量化した 5\.1\.1\.1 の判定など）もこれに含め、作り直した出力と他 reviewer の出力から作り直す。他 reviewer の出力だけから作られた値は初回のまま使う。'
assert_not_grep "pr-review no longer keeps the initial contradiction disposition" "$PR_REVIEW" '初回に決まった矛盾の disposition'
# 5.2.2 の例外の 2 文と件数の文は共有規則の一部で、段落の中にあり、手順書全体でそれぞれ 1 回だけ現れる（行へ戻す・複製する・消す・限定句を落とす変更を落とす）。
assert_grep "reroll rule keeps the 5.2.2 exception and the rejected count" "$rule_file" \
  '例外として、5\.2\.2 不採用は Verification 追加だけで再採用しない。再実行 5\.2\.2 は初回の不採用行を破棄しない。`evidence_claim_rejected_count` は初回の不採用行と再実行 5\.2\.2 の不採用行を合わせた件数とする（skip 時に 0 とするのは本 cycle で 5\.2\.2 が未判定のときに限る）。'
assert "the 5.2.2 exception appears once in pr-review" "1" "$(grep -o '5\.2\.2 不採用は Verification 追加だけで再採用しない' "$PR_REVIEW" | wc -l | tr -d ' ')"
assert "the keep-initial-rejections sentence appears once in pr-review" "1" "$(grep -o '再実行 5\.2\.2 は初回の不採用行を破棄しない' "$PR_REVIEW" | wc -l | tr -d ' ')"
assert "the rejected-count sentence appears once in pr-review" "1" "$(grep -o '再実行 5\.2\.2 の不採用行を合わせた件数とする' "$PR_REVIEW" | wc -l | tr -d ' ')"
assert_not_grep "reviewer prompt does not regenerate only the target findings" "$PROMPT_GEN" \
  '対象 finding のみ再生成|対象 finding の再生成'
assert_grep "5.1.1.1 merge strategy is still replace" "$PR_REVIEW" \
  'retry 結果は元 reviewer の output を \*\*置き換える\*\* \(append ではない\)'
assert_grep "routing retries JSON generation and helper in the same cycle" "$routing_file" \
  '同 cycle 内.*step 1 の JSON を作り直し step 2 を再実行する'
assert_grep "routing does not hand format repair to fix or increment the review cycle" "$routing_file" \
  '/rite:fix.*形式修正を渡さず、review cycle を増やさない'
assert_grep "routing stops with review:error when the shared retry is spent" "$routing_file" \
  'measured_gate_retry_count.*1.*\[review:error\].*停止'
assert_grep "shared retry count increments before helper and allows only one retry" "$PR_REVIEW" \
  '^\*\*`measured_gate_retry_count`.*step 2 再実行の直前に \+1.*上記 3 reason.*1 回まで'
assert_grep "failure diagnostic lists the count and target IDs" "$PR_REVIEW" \
  'MEASURED_GATE_FAILED=1; reason=anchor_undetermined; count=N; findings=F-xx'

if ! print_summary "$(basename "$0")"; then
  exit 1
fi
