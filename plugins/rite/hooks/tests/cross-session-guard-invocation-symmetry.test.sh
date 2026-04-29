#!/bin/bash
# Tests for cross-session guard invocation block structural symmetry
# (PR #688 post-review F-05 MEDIUM 対応)
#
# Purpose:
#   `_resolve-cross-session-guard.sh` の invocation surrounding boilerplate
#   (mktemp _classify_err + helper call + rc capture + WARNING emit + grep filter
#   + cleanup) は state-read.sh (reader-side) と flow-state-update.sh (writer-side)
#   の 2 箇所に 22 行の構造的同一ブロックとして存在する。
#
#   両 caller は cycle 34 F-02 で `_resolve-cross-session-guard.sh` 自体を抽出する
#   形で DRY 化されたが、**invocation surrounding boilerplate** の DRY 化は未完了で、
#   将来 stderr filter regex (`^WARNING:|^  |^jq: `) や rc capture pattern を変更する
#   際に 2 箇所同時修正が必要な状態で残留している (Issue #687 root cause と同型構造)。
#
#   本 metatest は両ブロックの構造的同一性を grep で pin することで、片肺更新 drift を
#   CI で検出可能にする。invocation 経路を完全に DRY 化する `_invoke-cross-session-guard.sh`
#   wrapper helper を将来追加する場合は、本 test を削除して migration を完了させる。
#
# Test cases:
#   TC-1: state-read.sh と flow-state-update.sh の両方で同じ helper を呼び出していること
#   TC-2: 両 caller が同じ stderr filter regex (`^WARNING:|^  |^jq: `) を使っていること
#   TC-3: 両 caller が同じ rc capture pattern (`if classification=$(bash ...; then ... else _guard_rc=$?`) を使っていること
#   TC-4: 両 caller が同じ classify_err lifecycle pattern (mktemp → 渡し → grep → rm) を使っていること

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
READER="$HOOKS_DIR/state-read.sh"
WRITER="$HOOKS_DIR/flow-state-update.sh"

PASS=0
FAIL=0
FAILED_NAMES=()

assert_both_match() {
  local name="$1" pattern="$2"
  local reader_match writer_match
  reader_match=$(grep -cE "$pattern" "$READER" || true)
  writer_match=$(grep -cE "$pattern" "$WRITER" || true)
  if [ "$reader_match" -ge 1 ] && [ "$writer_match" -ge 1 ]; then
    echo "  ✅ $name (reader=$reader_match, writer=$writer_match)"
    PASS=$((PASS+1))
  else
    echo "  ❌ $name"
    echo "     reader (state-read.sh): match count = $reader_match (期待 >= 1)"
    echo "     writer (flow-state-update.sh): match count = $writer_match (期待 >= 1)"
    FAIL=$((FAIL+1))
    FAILED_NAMES+=("$name")
  fi
}

echo "=== TC-1: 両 caller が _resolve-cross-session-guard.sh を呼び出している ==="
assert_both_match \
  "両 caller が _resolve-cross-session-guard.sh 経由で classification を取得" \
  'classification=\$\(bash "\$SCRIPT_DIR/_resolve-cross-session-guard\.sh"'

echo "=== TC-2: 両 caller が同じ stderr filter regex を使っている ==="
assert_both_match \
  "両 caller が grep -E '^WARNING:|^  |^jq: ' で classify_err を filter" \
  "grep -E '\\^WARNING:\\|\\^  \\|\\^jq: ' \"\\\$_classify_err\""

echo "=== TC-3: 両 caller が _classify_err lifecycle を持つ ==="
assert_both_match \
  "両 caller が _mktemp-stderr-guard.sh で _classify_err を作成" \
  '_classify_err=\$\(bash "\$SCRIPT_DIR/_mktemp-stderr-guard\.sh"'
assert_both_match \
  "両 caller が _classify_err を rm -f で cleanup" \
  'rm -f "\$_classify_err"'

echo "=== TC-4: 両 caller が rc capture pattern を持つ ==="
assert_both_match \
  "両 caller が _guard_rc=\\\$? で helper の non-zero exit を捕捉" \
  '_guard_rc=\$\?'

echo
echo "─── cross-session-guard-invocation-symmetry.test.sh summary ──────────────────────"
echo "PASS: $PASS"
echo "FAIL: $FAIL"
if [ "$FAIL" -ne 0 ]; then
  echo "Failed tests:"
  for n in "${FAILED_NAMES[@]}"; do
    echo "  - $n"
  done
  echo
  echo "⚠️ 片肺更新 drift を検出しました。state-read.sh と flow-state-update.sh の"
  echo "   _resolve-cross-session-guard.sh invocation block で構造的乖離が発生しています。"
  echo "   両ブロックを同一 pattern で更新するか、_invoke-cross-session-guard.sh wrapper"
  echo "   helper を追加して invocation 経路を DRY 化してください。"
  exit 1
fi
echo "All tests passed."
exit 0
