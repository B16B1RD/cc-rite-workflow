#!/bin/bash
# T-01〜T-05: 静的検証済み指摘のアンカー添付必須 + 実測阻害 fail-loud surface
#
# reviewer / 統合層は散文駆動のため、cycle-scope-contract.test.sh と同じ
# static-contract 方式で literal を grep-pin する。実測必須ゲートの 3 値判定そのものは
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
assert_grep "severity-levels.md documents Measurement-Blocked: without changing 3-value logic" "$SEVERITY" \
  'helper はこの marker を実測アンカーとして読まない（3 値判定に介入しない）'

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

echo "=== T-05: 3 値モデル非回帰（helper は Measurement-Blocked: を実測アンカーとして読まない） ==="
assert_not_grep "measured-gate detect regex does not mention Measurement-Blocked" "$MEASURED_GATE" \
  'Measurement-Blocked'
assert_grep "measured-gate still detects Verification: repro|failing_test only" "$MEASURED_GATE" \
  'Verification:\[\[:space:\]\]\*\(repro\|failing_test\)'
assert_grep "pr-review still says helper does not read Measurement-Blocked as a measured anchor" "$PR_REVIEW" \
  'helper は本 marker を実測アンカーとして読まない'

if ! print_summary "$(basename "$0")"; then
  exit 1
fi
