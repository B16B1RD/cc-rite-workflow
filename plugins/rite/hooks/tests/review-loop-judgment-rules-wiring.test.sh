#!/bin/bash
# review-loop-judgment-rules-wiring.test.sh
#
# Static-pin: iterate / fix / pr-review each link to a section of
# references/review-loop-judgment-rules.md, and the link's anchor equals the
# GitHub slug computed from that section's heading (the heading must appear
# exactly once). The negative control renames the heading and must break the pin.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
REF="$PLUGIN_ROOT/references/review-loop-judgment-rules.md"

[ -f "$REF" ] || { echo "ERROR: $REF not found" >&2; exit 1; }

echo "=== review-loop-judgment-rules-wiring.test.sh ==="

# GitHub slug: lowercase, drop everything but word chars / hyphens / spaces, space -> hyphen
slug_of() {
  python3 -I -c 'import re,sys; print(re.sub(r"[^\w\- ]", "", sys.argv[1].lower()).replace(" ", "-"))' "$1"
}

# 見出し行 ($3 の接頭辞で始まる ## 見出し) が ref ($1) に 1 回だけ出現し、
# その slug が skill ($2) のリンクの anchor と一致すること
check_pin() {
  local ref="$1" skill="$2" prefix="$3" heading slug
  [ "$(grep -c "^## ${prefix}" "$ref")" = "1" ] || return 1
  heading=$(grep "^## ${prefix}" "$ref" | sed 's/^## //')
  slug=$(slug_of "$heading")
  grep -qF -- "review-loop-judgment-rules.md#${slug})" "$skill"
}

pin() {
  local label="$1" skill="$2" prefix="$3"
  if check_pin "$REF" "$skill" "$prefix"; then pass "$label: link anchor == slug(heading)"; else fail "$label: link anchor == slug(heading)"; fi
  local mutant
  mutant=$(mktemp "${TMPDIR:-/tmp}/rite-judgment-pin-XXXXXX") || { fail "$label (mktemp failed)"; return; }
  sed "s/^## ${prefix}/## ${prefix}X/" "$REF" > "$mutant"
  if ! cmp -s "$REF" "$mutant" && ! check_pin "$mutant" "$skill" "$prefix"; then
    pass "NC: $label breaks when the heading is renamed"
  else
    fail "NC: $label survives a heading rename"
  fi
  rm -f "$mutant"
}

pin "iterate" "$PLUGIN_ROOT/skills/iterate/SKILL.md" '2\. iterate'
pin "fix" "$PLUGIN_ROOT/skills/fix/SKILL.md" '1\. fix'
pin "pr-review" "$PLUGIN_ROOT/skills/pr-review/SKILL.md" '3\. pr-review'

print_summary "review-loop-judgment-rules-wiring.test.sh"
