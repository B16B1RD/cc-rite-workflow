#!/bin/bash
# skill-prose-writing-static-pin.test.sh
#
# Static pins for plugins/rite/references/skill-prose-writing.md. The file is a
# prose-only reference, so nothing fails when a later edit breaks its contract:
#   - the 9 section headings stay as written, in order, with no heading-level skips
#   - the entry points (skill-diet-method.md, docs/SPEC.md) keep pointing at it
#   - the `${var:-}` rule keeps its trap-cleanup exclusion
#   - the rows added or extended in §5 and §8 match whole lines within their own section
# A negative control feeds the heading-skip detector a synthetic skip to prove it is live.
#
# When this test fails:
#   Fix skill-prose-writing.md (or the entry point), or update this test when the
#   contract has legitimately changed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
REPO_ROOT="$(_helpers_resolve_repo_root "$SCRIPT_DIR")"
DOC="$PLUGIN_ROOT/references/skill-prose-writing.md"

echo "=== skill-prose-writing-static-pin.test.sh ==="

if [ ! -f "$DOC" ]; then
  echo "ERROR: $DOC not found" >&2
  exit 1
fi

# Prints "line:from->to" for every heading that skips a level. The document has no code fences.
heading_skips() {
  awk '
    /^#+ / { match($0, /^#+/); lv = RLENGTH
             if (prev && lv > prev + 1) print NR ":" prev "->" lv
             prev = lv }
  ' "$1"
}

# 1. The 9 section headings, exactly and in order
EXPECTED_HEADINGS=$(printf '%s\n' '## 1. 配置と順序' '## 2. 規範文の強さと衝突' '## 3. 限定・修飾・述語' '## 4. 列挙・件数・参照' '## 5. rationale ポインタと SoT' '## 6. 実装の裏づけと到達可能性' '## 7. 診断・案内文言' '## 8. 復旧・再実行の案内' '## 9. 変更時の自己適用と検算')
assert "9 section headings in order" "$EXPECTED_HEADINGS" "$(grep -E '^## ' "$DOC")"

# 2. No heading-level skip (+ negative control)
assert "no heading-level skip" "" "$(heading_skips "$DOC")"
assert "heading-skip detector is live" "3:1->4" "$(heading_skips <(printf '# a\n\n#### b\n'))"

# 3. Entry points keep pointing at the file
assert_grep "skill-diet-method.md points at it" "$PLUGIN_ROOT/references/skill-diet-method.md" '`skill-prose-writing\.md` を参照する'
assert_grep "docs/SPEC.md tree lists it" "$REPO_ROOT/docs/SPEC.md" '^ *(├|└)── skill-prose-writing\.md #'

# 4. The ${var:-} rule keeps its trap-cleanup exclusion on the same line
assert_grep "var-default rule keeps trap cleanup exclusion" "$DOC" '\$\{var:-\}.*trap の cleanup は対象外'

# 5. Rows in §5 / §8 match whole lines within their own section (moving a row out of its section fails)
section_of() { START="$2" awk '$0 == ENVIRON["START"] { f = 1; next } f && /^## / { exit } f { print }' "$1"; }
H5="## 5. rationale ポインタと SoT"
H8="## 8. 復旧・再実行の案内"
pin_section_row() { # label heading line
  local body; body="$(section_of "$DOC" "$2")"
  if grep -qxF -- "$3" <<<"$body"; then pass "$1"; else fail "$1 (no whole-line match in the section)"; fi
}
pin_section_row '§5 pointer target narrows to the part with the same conclusion' "$H5" '- ポインタ先は、anchor が解決するだけでなく、必要な内容を実際に含むかを個別に確かめる。含まなければ、参照する範囲を、同じ帰結を書いた部分だけに狭める。'
pin_section_row '§5 one place for handling the same return value' "$H5" '- 同じ戻り値への処理（再試行・停止）を、表と段落の 2 か所に書かず 1 か所に置く。'
pin_section_row '§5 changing a contract in one line reads every restatement' "$H5" '- 契約の方式を手順書の 1 行で変える → 旧方式の語で repo 全体を検索し、同じ契約を述べる prompt テンプレート・helper のエラー文言・reference を全件読んで直す。helper のエラー文言は方式を言い直さず、方式を書いた正本を指す。'
pin_section_row '§8 rerun range by condition and one sentence for first-run values' "$H8" '- 再実行の案内では、再実行の範囲を段の列挙でなく条件（どの条件の段から通常経路を再実行するか）で書き、範囲の始まりも条件で書く。作り直した出力が関わる初回の値（判定・収集した配列・件数）は作り直し、それ以外は保持する、と値の種類ごとに書き分けず 1 文で決める（再実行と保持を別々に並べると、同じ値に両方が当たる）。通常経路で強制している検査も範囲に含め、再試行の上限も書く。重複を除かない追記を含む手順では、既に成功していた場合を先に分けてから再実行させる。'
pin_section_row '§8 replacing output after later stages reruns them on the same line' "$H8" '- 後段（統合・矛盾検出・ファクトチェックなど）を終えた後で出力を差し替える手順 → 差し替えの後に後段を再実行することを、差し替えと同じ行に書く。後段より前の差し替えには書かない。'

print_summary "skill-prose-writing-static-pin.test.sh" "Re-read plugins/rite/references/skill-prose-writing.md and restore the pinned contract."
