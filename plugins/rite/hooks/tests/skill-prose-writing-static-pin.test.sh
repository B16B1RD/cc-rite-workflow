#!/bin/bash
# skill-prose-writing-static-pin.test.sh
#
# Static pins for plugins/rite/references/skill-prose-writing.md. The file is a
# prose-only reference, so nothing fails when a later edit breaks its contract:
#   - the 9 numbered sections stay in order, with no heading-level skips
#   - no Issue / PR number is written in the file (permanent artifact rule)
#   - the file names no reviewer as a consumer unless that agent file references it
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

# Prints "line:from->to" for every heading that skips a level (outside code fences).
heading_skips() {
  awk '
    /^```/ { inb = !inb; next }
    inb { next }
    /^#+ / { match($0, /^#+/); lv = RLENGTH
             if (prev && lv > prev + 1) print NR ":" prev "->" lv
             prev = lv }
  ' "$1"
}

# 1. Sections 1..9 present, in order
sections="$(grep -E '^## [0-9]+\. ' "$DOC" | sed -E 's/^## ([0-9]+)\..*/\1/' | tr '\n' ' ')"
assert "9 numbered sections in order" "1 2 3 4 5 6 7 8 9 " "$sections"

# 2. No heading-level skip (+ negative control)
assert "no heading-level skip" "" "$(heading_skips "$DOC")"
NEG="$(mktemp)"
printf '# a\n\n#### b\n' > "$NEG"
assert "heading-skip detector is live" "3:1->4" "$(heading_skips "$NEG")"
rm -f "$NEG"

# 3. No Issue / PR number
if grep -nE '#[0-9]{2,}|(Issue|PR) ?[0-9]+' "$DOC" >/dev/null; then
  fail "no Issue/PR number in the file"
else
  pass "no Issue/PR number in the file"
fi

# 4. Reviewers named as consumers must reference the file themselves
for rv in prompt-engineer tech-writer; do
  agent="$PLUGIN_ROOT/agents/$rv-reviewer.md"
  if grep -q "$rv" "$DOC"; then
    if grep -q "skill-prose-writing" "$agent"; then
      pass "$rv named as consumer and references the file"
    else
      fail "$rv named as consumer but $agent does not reference the file"
    fi
  else
    pass "$rv not claimed as consumer"
  fi
done

# 5. Entry points keep pointing at the file
assert_grep "skill-diet-method.md points at it" "$PLUGIN_ROOT/references/skill-diet-method.md" "skill-prose-writing\.md"
assert_grep "docs/SPEC.md tree lists it" "$REPO_ROOT/docs/SPEC.md" "skill-prose-writing\.md"

# 6. ${var:-} rule keeps the trap-cleanup exclusion
assert_grep "var-default rule keeps trap cleanup exclusion" "$DOC" 'trap の cleanup'

print_summary "skill-prose-writing-static-pin.test.sh" "Re-read plugins/rite/references/skill-prose-writing.md and restore the pinned contract."
