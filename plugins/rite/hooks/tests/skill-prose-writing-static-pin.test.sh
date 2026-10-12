#!/bin/bash
# skill-prose-writing-static-pin.test.sh
#
# Static pins for plugins/rite/references/skill-prose-writing.md. The file is a
# prose-only reference, so nothing fails when a later edit breaks its contract:
#   - the 9 section headings stay as written, in order, with no heading-level skips
#   - the entry points (skill-diet-method.md, docs/SPEC.md) keep pointing at it
#   - the `${var:-}` rule keeps its trap-cleanup exclusion
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

print_summary "skill-prose-writing-static-pin.test.sh" "Re-read plugins/rite/references/skill-prose-writing.md and restore the pinned contract."
