#!/bin/bash
# review-loop-judgment-rules-wiring.test.sh
#
# Static-pin: iterate / fix / pr-review each link to their own section of
# references/review-loop-judgment-rules.md, and the linked heading exists.
# Each pin is also run against a mutant without the pinned text.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
REF="$PLUGIN_ROOT/references/review-loop-judgment-rules.md"

[ -f "$REF" ] || { echo "ERROR: $REF not found" >&2; exit 1; }

echo "=== review-loop-judgment-rules-wiring.test.sh ==="

check_link() { grep -qF -- "$2" "$1"; }

pin() {
  local label="$1" file="$2" link="$3" heading="$4"
  if check_link "$file" "$link"; then pass "$label: link"; else fail "$label: link"; fi
  if grep -qxF -- "$heading" "$REF"; then pass "$label: heading"; else fail "$label: heading"; fi
  local mutant
  mutant=$(mktemp "${TMPDIR:-/tmp}/rite-judgment-pin-XXXXXX") || { fail "$label (mktemp failed)"; return; }
  grep -vF -- "$link" "$file" > "$mutant" || true
  if ! cmp -s "$file" "$mutant" && ! check_link "$mutant" "$link"; then
    pass "NC: $label is live"
  else
    fail "NC: $label is not live"
  fi
  rm -f "$mutant"
}

pin "iterate" "$PLUGIN_ROOT/skills/iterate/SKILL.md" \
  'review-loop-judgment-rules.md#2-iterate-収束終了の読み方' '## 2. iterate: 収束・終了の読み方'
pin "fix" "$PLUGIN_ROOT/skills/fix/SKILL.md" \
  'review-loop-judgment-rules.md#1-fix-修正の適用と検証' '## 1. fix: 修正の適用と検証'
pin "pr-review" "$PLUGIN_ROOT/skills/pr-review/SKILL.md" \
  'review-loop-judgment-rules.md#3-pr-review-採否と集約' '## 3. pr-review: 採否と集約'

print_summary "review-loop-judgment-rules-wiring.test.sh"
