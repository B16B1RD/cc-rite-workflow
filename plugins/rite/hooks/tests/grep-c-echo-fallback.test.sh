#!/bin/bash
# Regression guard: `grep -c ... || echo 0` (also `--count`, `-E -c`, `|| printf 0`) must not
# appear anywhere under plugins/rite. grep -c prints "0" and exits 1 on zero matches, so the
# `|| echo 0` branch appends a second "0" and the captured value becomes "0\n0".
# A scan error (grep rc>=2, e.g. a missing directory) fails the test instead of passing silently.
# Usage: bash plugins/rite/hooks/tests/grep-c-echo-fallback.test.sh
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
pat='grep( +[^|]*)? +(-[A-Za-z]*c[A-Za-z]*|--count) [^|]*\|\| *(echo|printf) +["'"'"']?0'

# 負例: 検出器自身が二重出力形を拾えること
for neg in 'x=$(printf "" | grep -c . 2>/dev/null || echo 0)' \
           'x=$(grep -E -c a f || echo 0)' 'x=$(grep --count a f || echo "0")' "x=\$(grep -cE 'ab' f || printf 0)"; do
  grep -qE "$pat" <<< "$neg" || { echo "FAIL: detector missed known-bad form: $neg" >&2; exit 1; }
done
# 正例: 修正後の形は拾わないこと
pos='x=$(printf "" | grep -c . 2>/dev/null) || x=0'
grep -qE "$pat" <<< "$pos" && { echo "FAIL: detector flagged the fixed form" >&2; exit 1; }

# このファイル自身は負例を引用するため走査から除く（検出器の自己検査で担保）。
# 説明・fixture として形を引用している行だけを「相対パス|固有文字列」で許可する
allow=(
  'hooks/scripts/wiki-lint-descriptive-refs.sh|(`grep -c || echo 0` 等)'
  'hooks/tests/wiki-lint-descriptive-refs.test.sh|grep -c || echo 0 の罠'
  'references/bash-defensive-patterns.md|`$(grep -c ... || echo 0)`'
)

hits=$(grep -rnE --include='*.md' --include='*.sh' --exclude='grep-c-echo-fallback.test.sh' -e "$pat" "$root"); rc=$?
if [ "$rc" -ge 2 ]; then echo "FAIL: scan error rc=$rc" >&2; exit 1; fi

bad=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  ok=0
  for a in "${allow[@]}"; do
    rel="${a%%|*}"; s="${a#*|}"
    p="${line%%:*}"
    if [[ "$p" == */"$rel" && "$line" == *"$s"* ]]; then ok=1; break; fi
  done
  [ "$ok" -eq 1 ] || bad+="$line"$'\n'
done <<< "$hits"

if [ -n "$bad" ]; then
  echo "FAIL: grep -c || echo found:" >&2; printf '%s' "$bad" >&2; exit 1
fi
echo "PASS: no grep -c || echo double-print form"
