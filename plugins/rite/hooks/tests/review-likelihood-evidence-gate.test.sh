#!/usr/bin/env bash
set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
HELPER="$ROOT/hooks/scripts/review-likelihood-evidence-gate.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
check() { if "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi; }

printf '%s\n' '### 指摘事項' '| 重要度 | ファイル:行 | 内容 |' '|---|---|---|' '| HIGH | a.sh:1 | defect. Likelihood-Evidence: existing_call_site a.sh:1 |' > "$TMP/valid.md"
printf '%s\n' '### 指摘事項' '| 重要度 | ファイル:行 | 内容 |' '|---|---|---|' '| HIGH | a.sh:1 | defect without anchor |' > "$TMP/missing.md"
printf '%s\n' '### 指摘事項' '| 重要度 | ファイル:行 | 内容 |' '|---|---|---|' '| HIGH | a.sh:1 | risk. Likelihood: Hypothetical (例外カテゴリ: security) |' > "$TMP/hypothetical.md"

check "$HELPER" --reviewer-type application --input "$TMP/valid.md"
check bash -c '! "$1" --reviewer-type application --input "$2" >/dev/null 2>&1' _ "$HELPER" "$TMP/missing.md"
check "$HELPER" --reviewer-type security --input "$TMP/hypothetical.md"
check bash -c '! "$1" --reviewer-type test --input "$2" >/dev/null 2>&1' _ "$HELPER" "$TMP/hypothetical.md"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
