#!/bin/bash
# test-pin-mutation-principles-contract.test.sh
#
# テストの pin・mutation 設計原則 (references/test-pin-mutation-principles.md) の配線契約を固定する。
# 実装側 (issue-implement 5.0.F) と reviewer 側 (test-reviewer) が同じ reference を読むこと、
# reference が節構造を保つことを pin する。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
REF="$PLUGIN_ROOT/references/test-pin-mutation-principles.md"
IMPL="$PLUGIN_ROOT/skills/issue-implement/SKILL.md"
REVIEWER="$PLUGIN_ROOT/agents/test-reviewer.md"
NAME="test-pin-mutation-principles.md"

# reference が存在し、各節見出しが揃う (見出し改名は caller の節参照を壊す)
assert_file_exists_or_fail "reference が存在する" "$REF" || exit 1
for n in 1 2 3 4 5 6 7 8 9 10; do
  c=$(grep -cE "^## ${n}\. " "$REF")
  assert "reference: 節 ${n} の見出しが 1 つ" "1" "$c"
done

# 各節に「条件 → 期待」表がある (表ヘッダ行が節数と一致)
assert "reference: 表ヘッダが全 10 節にある" "10" "$(grep -cE '^\| 条件 \| 期待 \|$' "$REF")"

# 中核規則の literal を pin (表現ごと消すと落ちる)
for lit in \
  '書く前に mutation を当て、素通りしたときだけ pin を足す' \
  'positive control を先に置く' \
  '行末まで完全一致' \
  'pin も両側に置く' \
  '`pwd -P` で正規化する' \
  '移設前後でテストの検査数が無言で減っていないか'; do
  if grep -qF -- "$lit" "$REF"; then pass "reference: 中核規則 '$lit'"; else fail "reference: 中核規則が無い: $lit"; fi
done

# caller の配線 (実装側・reviewer 側の両方が reference を指す)
assert "issue-implement 5.0.F が reference を指す" "1" "$(grep -cF "references/$NAME" "$IMPL")"
assert "test-reviewer が reference を指す" "1" "$(grep -cF "references/$NAME" "$REVIEWER")"

# 負例: 配線を欠いた入力 (reference 名を別名に置換) は上の pin に一致しない (positive control)
neg="$(sed "s/$NAME/renamed.md/g" "$IMPL" | grep -cF "references/$NAME")"
assert "control: reference 名を変えた SKILL は pin に一致しない" "0" "$neg"

# 配布境界: 永続成果物に Issue / PR 番号を書かない
assert "reference: Issue/PR 番号を含まない" "0" "$(grep -cE '(#|PR |Issue )[0-9]{3,}' "$REF")"

if ! print_summary "$(basename "$0")" "drift: test-pin-mutation-principles.md の節構成、または issue-implement 5.0.F / test-reviewer の参照が変更された可能性"; then
  exit 1
fi
