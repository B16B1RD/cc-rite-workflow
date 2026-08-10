#!/bin/bash
# Dogfooding 用 rite-config.yml の review.loop コメントを現行契約へ固定する。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
CONFIG="$ROOT_DIR/rite-config.yml"
LOOP_BLOCK="$(mktemp "${TMPDIR:-/tmp}/rite-review-loop-comments.XXXXXX")"
trap 'rm -f -- "$LOOP_BLOCK"' EXIT

# top-level `review:` の内側にある 2-space indent の `loop:` だけを対象にし、
# 次の同レベル mapping key の直前までに限定する。同じ文言や `loop:` block が
# 別 section にあっても通さない。
awk '
  /^review:[[:space:]]*$/ { in_review = 1; print; next }
  in_review && /^[[:alnum:]_]+:/ { exit }
  in_review && /^  loop:[[:space:]]*$/ { in_loop = 1 }
  in_loop && seen_loop && /^  [[:alnum:]_]+:/ { exit }
  in_loop { print; seen_loop = 1 }
' "$CONFIG" > "$LOOP_BLOCK"

PASS=0
FAIL=0

assert_grep() {
  local name="$1" pattern="$2"
  if LC_ALL=C grep -qE -- "$pattern" "$LOOP_BLOCK"; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_grep() {
  local name="$1" pattern="$2"
  if LC_ALL=C grep -qE -- "$pattern" "$LOOP_BLOCK"; then
    echo "FAIL: $name"
    FAIL=$((FAIL + 1))
  else
    echo "PASS: $name"
    PASS=$((PASS + 1))
  fi
}

assert_grep "review parent was extracted" '^review:[[:space:]]*$'
assert_grep "review.loop child was extracted" '^  loop:[[:space:]]*$'
assert_grep "normal exit is zero blocking findings with the severity SoT" \
  '正常出口は 0 blocking findings のみ.*plugins/rite/references/severity-levels\.md.*§実測必須ゲート'
assert_grep "circuit breaker documents trend divergence" \
  '収束トレンドの発散'
assert_grep "circuit breaker documents max_review_cycles backstop" \
  'safety\.max_review_cycles 到達（backstop）'
assert_grep "convergence_monitoring is scaffolding only with no runtime effect" \
  'convergence_monitoring: true.*Scaffolding only.*runtime effect はない'
assert_not_grep "obsolete four-signal escalation design is absent" \
  '以下の 4 品質シグナル|root-cause 不明 fix|cross-validation 不一致|finding quality gate 不通過'
assert_not_grep "obsolete semantic-cycle description is absent" \
  '同一 finding 循環の semantic 検知'

echo "PASS: $PASS"
echo "FAIL: $FAIL"

if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
