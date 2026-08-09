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

check "$HELPER" --reviewer-type application --input "$TMP/valid.md"
check bash -c '! "$1" --reviewer-type application --input "$2" >/dev/null 2>&1' _ "$HELPER" "$TMP/missing.md"
check "$HELPER" --reviewer-type security --input "$TMP/hypothetical.md"
check bash -c '! "$1" --reviewer-type test --input "$2" >/dev/null 2>&1' _ "$HELPER" "$TMP/hypothetical.md"
check bash -c '! "$1" --reviewer-type application --input "$2" >/dev/null 2>&1' _ "$HELPER" "$TMP/wrong-column.md"
check bash -c '! "$1" --reviewer-type security --input "$2" >/dev/null 2>&1' _ "$HELPER" "$TMP/wrong-category.md"
check bash -c '! "$1" --reviewer-type application --input "$2" >/dev/null 2>&1' _ "$HELPER" "$TMP/missing-heading.md"
check "$HELPER" --reviewer-type application --input "$TMP/empty.md"
check bash -c '! "$1" --reviewer-type application --input "$2" >/dev/null 2>&1' _ "$HELPER" "$TMP/malformed-empty.md"
check bash -c 'source "$1"; _timeout 1 "$2" --input >/dev/null 2>&1; [ "$?" -eq 2 ]' _ "$SCRIPT_DIR/_test-helpers.sh" "$HELPER"
check bash -c 'source "$1"; _timeout 1 "$2" --reviewer-type >/dev/null 2>&1; [ "$?" -eq 2 ]' _ "$SCRIPT_DIR/_test-helpers.sh" "$HELPER"
for reason in anchor_missing findings_heading_missing table_header_missing table_malformed; do
  check grep -q "$reason" "$SKILL"
done

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
