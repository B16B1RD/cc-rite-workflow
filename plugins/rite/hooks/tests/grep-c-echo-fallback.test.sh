#!/bin/bash
# Regression guard: `grep -c ... || echo 0` must not appear in shipped skills/scripts.
# grep -c prints "0" and exits 1 on zero matches, so the `|| echo 0` branch appends a
# second "0" and the captured value becomes "0\n0" (integer tests then fail).
# Usage: bash plugins/rite/hooks/tests/grep-c-echo-fallback.test.sh
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
pat='grep +(-[A-Za-z]*c[A-Za-z]*)[^|]*\|\| *echo'

# 負例: 検出器自身が二重出力形を拾えること
neg='x=$(printf "" | grep -c . 2>/dev/null || echo 0)'
if ! grep -qE "$pat" <<< "$neg"; then
  echo "FAIL: detector missed known-bad form" >&2; exit 1
fi
# 正例: 修正後の形は拾わないこと
pos='x=$(printf "" | grep -c . 2>/dev/null) || x=0'
if grep -qE "$pat" <<< "$pos"; then
  echo "FAIL: detector flagged the fixed form" >&2; exit 1
fi

hits=$(grep -rnE --include='*.md' --include='*.sh' "$pat" "$root/skills" "$root/hooks/scripts" "$root/references" 2>/dev/null) || hits=""
# 注意書きとして形を引用している行（`grep -c || echo 0` をバッククォートで示す説明）は除外
hits=$(grep -vE '`[^`]*grep +-[A-Za-z]*c[^`]*\|\| *echo[^`]*`' <<< "$hits") || hits=""
if [ -n "$hits" ]; then
  echo "FAIL: grep -c || echo found:" >&2; echo "$hits" >&2; exit 1
fi
echo "PASS: no grep -c || echo double-print form"
