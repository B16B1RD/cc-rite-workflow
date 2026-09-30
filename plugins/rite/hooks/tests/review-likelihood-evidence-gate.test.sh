#!/usr/bin/env bash
set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
HELPER="$ROOT/hooks/scripts/review-likelihood-evidence-gate.sh"
SKILL="$ROOT/skills/pr-review/SKILL.md"
SCRIPT_DIR="$ROOT/hooks/tests"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
check() { if "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi; }

printf '%s\n' '### 指摘事項' '| 重要度 | スコープ | ファイル:行 | 内容 | 推奨対応 |' '|---|---|---|---|---|' '| HIGH | current-pr | a.sh:1 | defect. Likelihood-Evidence: existing_call_site a.sh:1 | fix |' > "$TMP/valid.md"
printf '%s\n' '### 指摘事項' '| 重要度 | スコープ | ファイル:行 | 内容 | 推奨対応 |' '|---|---|---|---|---|' '| HIGH | current-pr | a.sh:1 | defect without anchor | fix |' > "$TMP/missing.md"
printf '%s\n' '### 指摘事項' '| 重要度 | スコープ | ファイル:行 | 内容 | 推奨対応 |' '|---|---|---|---|---|' '| HIGH | current-pr | a.sh:1 | risk. Likelihood: Hypothetical (例外カテゴリ: security) | mitigate |' > "$TMP/hypothetical.md"
printf '%s\n' '### 指摘事項' '| 重要度 | スコープ | ファイル:行 | 内容 | 推奨対応 |' '|---|---|---|---|---|' '| HIGH | current-pr | a.sh:1 | defect without anchor | add Likelihood-Evidence: existing_call_site a.sh:1 |' > "$TMP/wrong-column.md"
printf '%s\n' '### 指摘事項' '| 重要度 | スコープ | ファイル:行 | 内容 | 推奨対応 |' '|---|---|---|---|---|' '| HIGH | current-pr | a.sh:1 | risk. Likelihood: Hypothetical (例外カテゴリ: banana) | mitigate |' > "$TMP/wrong-category.md"
printf '%s\n' '| 重要度 | スコープ | ファイル:行 | 内容 | 推奨対応 |' '|---|---|---|---|---|' '| HIGH | current-pr | a.sh:1 | defect without anchor | fix |' > "$TMP/missing-heading.md"
printf '%s\n' '### 指摘事項' '| 重要度 | スコープ | ファイル:行 | 内容 | 推奨対応 |' '|---|---|---|---|---|' > "$TMP/empty.md"
printf '%s\n' '### 指摘事項' '| 重要度 | ファイル:行 | 内容 |' '|---|---|---|' > "$TMP/malformed-empty.md"
printf '%s\n' '### 指摘事項' '| 重要度 | スコープ | ファイル:行 | 内容 | 推奨対応 |' '|---|---|---|' > "$TMP/malformed-separator.md"
printf '%s\n' '### 指摘事項' '| 重要度 | スコープ | ファイル:行 | 内容 | 推奨対応 |' '|-|--|-|--|-|' > "$TMP/short-separator.md"
printf '%s\n' '### Findings' '| Severity | Scope | File:Line | Description | Recommendation |' '|:---|---:|:---:|----|-----|' > "$TMP/aligned-empty.md"

check "$HELPER" --reviewer-type application --input "$TMP/valid.md"
check bash -c '! "$1" --reviewer-type application --input "$2" >/dev/null 2>&1' _ "$HELPER" "$TMP/missing.md"
check "$HELPER" --reviewer-type security --input "$TMP/hypothetical.md"
check bash -c '! "$1" --reviewer-type test --input "$2" >/dev/null 2>&1' _ "$HELPER" "$TMP/hypothetical.md"
check bash -c '! "$1" --reviewer-type application --input "$2" >/dev/null 2>&1' _ "$HELPER" "$TMP/wrong-column.md"
check bash -c '! "$1" --reviewer-type security --input "$2" >/dev/null 2>&1' _ "$HELPER" "$TMP/wrong-category.md"
check bash -c '! "$1" --reviewer-type application --input "$2" >/dev/null 2>&1' _ "$HELPER" "$TMP/missing-heading.md"
check "$HELPER" --reviewer-type application --input "$TMP/empty.md"
check bash -c '! "$1" --reviewer-type application --input "$2" >/dev/null 2>&1' _ "$HELPER" "$TMP/malformed-empty.md"
check bash -c '! "$1" --reviewer-type application --input "$2" >/dev/null 2>&1' _ "$HELPER" "$TMP/malformed-separator.md"
check bash -c '! "$1" --reviewer-type application --input "$2" >/dev/null 2>&1' _ "$HELPER" "$TMP/short-separator.md"
check "$HELPER" --reviewer-type application --input "$TMP/aligned-empty.md"
check bash -c 'source "$1"; _timeout 1 "$2" --input >/dev/null 2>&1; [ "$?" -eq 2 ]' _ "$SCRIPT_DIR/_test-helpers.sh" "$HELPER"
check bash -c 'source "$1"; _timeout 1 "$2" --reviewer-type >/dev/null 2>&1; [ "$?" -eq 2 ]' _ "$SCRIPT_DIR/_test-helpers.sh" "$HELPER"
FINDINGS_EMPTY=('### 指摘事項' '| 重要度 | スコープ | ファイル:行 | 内容 | 推奨対応 |' '|---|---|---|---|---|')
printf '%s\n' "${FINDINGS_EMPTY[@]}" '### 推奨事項' '- 分類: actionable — a.sh:1 の説明を直す' '- 別 Issue で扱う改善' > "$TMP/rec-missing.md"
printf '%s\n' "${FINDINGS_EMPTY[@]}" '### 推奨事項' '- 分類: follow-up — 別 Issue で直す' > "$TMP/rec-unknown.md"
printf '%s\n' "${FINDINGS_EMPTY[@]}" '### 推奨事項' '- 分類: follow-up — x' '- 分類: 文書整合 — y' > "$TMP/rec-two.md"
printf '%s\n' '### 指摘事項' '| 重要度 | スコープ | ファイル:行 | 内容 | 推奨対応 |' '|---|---|---|---|---|' '| HIGH | current-pr | a.sh:1 | defect without anchor | fix |' '### 推奨事項' '- 分類: follow-up — x' > "$TMP/rec-with-finding-violation.md"
printf '%s\n' "${FINDINGS_EMPTY[@]}" '### 推奨事項' '- 分類: actionable — a' '  続きの行' '* `分類: design_confirmation` — b' '+ **分類**: boundary — c' '1. 分類: actionable、d' '### 監査ログ' 'なし' > "$TMP/rec-valid.md"
printf '%s\n' '### Findings' '| Severity | Scope | File:Line | Description | Recommendation |' '|---|---|---|---|---|' '### Recommendations' '- 分類: boundary — e' > "$TMP/rec-valid-en.md"
printf '%s\n' "${FINDINGS_EMPTY[@]}" '### 推奨事項' 'なし' > "$TMP/rec-none.md"
printf '%s\n' "${FINDINGS_EMPTY[@]}" '### 推奨事項' '| 分類 | 内容 |' '|---|---|' '| actionable | a |' > "$TMP/rec-table.md"

gate_out() { "$HELPER" --reviewer-type application --input "$1" 2>&1; }
check bash -c '! "$1" --reviewer-type application --input "$2" >/dev/null 2>&1' _ "$HELPER" "$TMP/rec-missing.md"
check grep -q 'reason=recommendation_classification_invalid; reviewer=application; recommendations=2; invalid=1$' <<<"$(gate_out "$TMP/rec-missing.md")"
check grep -qx '  line 6: 分類=(missing)' <<<"$(gate_out "$TMP/rec-missing.md")"
check bash -c '! "$1" --reviewer-type application --input "$2" >/dev/null 2>&1' _ "$HELPER" "$TMP/rec-unknown.md"
check grep -qx '  line 5: 分類=follow-up' <<<"$(gate_out "$TMP/rec-unknown.md")"
check grep -q 'recommendations=2; invalid=2$' <<<"$(gate_out "$TMP/rec-two.md")"
check [ "$(gate_out "$TMP/rec-two.md" | grep -c '^  line ')" -eq 2 ]
check grep -q 'reason=anchor_missing' <<<"$(gate_out "$TMP/rec-with-finding-violation.md")"
check bash -c '! grep -q recommendation_classification_invalid <<<"$1"' _ "$(gate_out "$TMP/rec-with-finding-violation.md")"
check grep -q 'findings=0; recommendations=4$' <<<"$(gate_out "$TMP/rec-valid.md")"
check grep -q 'findings=0; recommendations=1$' <<<"$(gate_out "$TMP/rec-valid-en.md")"
check grep -q 'findings=0; recommendations=0$' <<<"$(gate_out "$TMP/rec-none.md")"
check grep -q 'findings=0; recommendations=0$' <<<"$(gate_out "$TMP/empty.md")"
check grep -q 'recommendations=2; invalid=2$' <<<"$(gate_out "$TMP/rec-table.md")"

for reason in anchor_missing findings_heading_missing table_header_missing table_malformed recommendation_classification_invalid; do
  check grep -q "$reason" "$SKILL"
done

BASE_FILE="$ROOT/agents/_reviewer-base.md"
PROMPT_GEN="$ROOT/skills/pr-review/references/reviewer-prompt-generator.md"
EMPTY_HEADER_RULE='指摘が 0 件でも 5 列ヘッダ行と区切り行を必ず出力し、本文行は空にする'
EMPTY_HEADER_BAN='見出しのあとに「なし」と書いてヘッダを省いてはならない'
check grep -q "$EMPTY_HEADER_RULE" "$BASE_FILE"
check grep -q "$EMPTY_HEADER_BAN" "$BASE_FILE"
check grep -q "$EMPTY_HEADER_RULE" "$PROMPT_GEN"
check grep -q "$EMPTY_HEADER_BAN" "$PROMPT_GEN"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
