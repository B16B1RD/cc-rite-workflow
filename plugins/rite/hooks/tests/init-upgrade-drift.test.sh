#!/bin/bash
# Static / offline drift + consistency tests for the `/rite:setup --upgrade` config
# follow-through.
#
# Sources the shared `_test-helpers.sh` for pass / fail /
# assert_grep / assert_not_grep / _helpers_resolve_repo_root / print_summary,
# so the pass/fail stream, glyphs (✅/❌) and summary block follow the same
# convention as the other source-based tests in this directory.
#
# Verifies:
#   T-10 (AC-10): every active top-level key in the template above the
#        `# --- Advanced (below this line) ---` marker is enumerated in init.md's
#        "Active top-level sections covered on --upgrade" drift anchor. A new
#        template section that is not listed in init.md fails this test, forcing
#        init.md to be updated so `--upgrade` does not silently miss it.
#   T-11 (AC-11): the template and init.md agree that `multi_session:` is
#        back-added on --upgrade (with `enabled: true`), and no stale "do NOT
#        back-add" / "NOT back-added" / "left absent" wording survives in either
#        file.
#   T-12: every DIRECT sub-key of each active top-level section
#        (above the `# --- Advanced ---` marker) is enumerated in init.md's
#        "Active sub-keys covered on --upgrade" drift anchor, under its section's
#        row. This extends T-10's protection one level down: a new sub-key added
#        to an existing template section that init.md fails to list fails this
#        test, forcing init.md to be updated so `--upgrade` does not silently
#        miss it (mirrors the sub-key merge rule, init.md Step 6 item 4).
#   T-13: the `--upgrade` `current >= latest` short-circuit path is
#        routed through Step 4 Identify -> Step 6 Apply (drift back-add) instead of
#        skipping Step 4-6, and the Wiki-only Step 3.5 block is folded into Step 6
#        item 7. Static guards on init.md's branching table + Step 6 wording; the
#        back-add behavior itself runs in the LLM procedure (init.md), not a fixture,
#        so these assert the corrected routing cannot silently regress.
#
# Usage: bash plugins/rite/hooks/tests/init-upgrade-drift.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
REPO_ROOT="$(_helpers_resolve_repo_root "$SCRIPT_DIR")"
INIT_MD="$REPO_ROOT/plugins/rite/skills/setup/SKILL.md"
TEMPLATE="$REPO_ROOT/plugins/rite/templates/config/rite-config.yml"

# --- Preconditions ---
[ -f "$INIT_MD" ]   || { echo "FATAL: init.md not found at $INIT_MD" >&2; exit 1; }
[ -f "$TEMPLATE" ]  || { echo "FATAL: template not found at $TEMPLATE" >&2; exit 1; }

echo "=== T-10: template active top-level sections ⊆ init.md upgrade enumeration ==="

# Active top-level keys in the template above the Advanced boundary.
# Key regex allows digits/hyphens after the first char (e.g. a future `oauth2:`),
# a strict superset of the current all-lowercase keys so this does not change
# T-10's extraction for today's template.
template_sections=$(awk '
  /# --- Advanced \(below this line\) ---/ { exit }
  /^[a-z_][a-zA-Z0-9_-]*:/ { key=$0; sub(/:.*/, "", key); print key }
' "$TEMPLATE")

[ -n "$template_sections" ] || { echo "FATAL: no template sections extracted (parser drift?)" >&2; exit 1; }

# The init.md drift anchor line (single source of the enumeration).
enum_line=$(grep -nF 'Active top-level sections covered on --upgrade' "$INIT_MD" | head -1 | cut -d: -f1 || true)
if [ -z "$enum_line" ]; then
  fail "init.md is missing the 'Active top-level sections covered on --upgrade' drift anchor"
else
  pass "init.md drift anchor present"
  enum_text=$(sed -n "${enum_line}p" "$INIT_MD")
  for sec in $template_sections; do
    if printf '%s' "$enum_text" | grep -qF -- "\`$sec\`"; then
      pass "template section '$sec' is enumerated in init.md"
    else
      fail "template section '$sec' is NOT enumerated in init.md upgrade handling"
    fi
  done
fi

echo "=== T-11: multi_session back-add wording is consistent (no stale text) ==="

# Positive: both files state the back-add policy.
# assert_grep takes ERE patterns; the originals already used grep -E so the
# patterns carry over unchanged.
assert_grep "init.md Step 4 row states multi_session is back-added with enabled: true" \
  "$INIT_MD" 'multi_session.*[Bb]ack-add on --upgrade with .enabled: true.'
assert_grep "template comment states multi_session is back-added with enabled: true on --upgrade" \
  "$TEMPLATE" 'back-added with .enabled: true.'

# Negative: no stale "do not back-add" wording remains. The original assert_absent
# matched fixed strings; these three patterns contain no ERE metacharacters, so
# assert_not_grep (ERE) is exactly equivalent.
assert_not_grep "init.md no longer says 'Do NOT back-add on --upgrade'" \
  "$INIT_MD" 'Do NOT back-add on --upgrade'
assert_not_grep "template no longer says 'intentionally NOT back-added'" \
  "$TEMPLATE" 'intentionally NOT back-added'
assert_not_grep "init.md no longer says multi_session is 'left absent' on upgrade" \
  "$INIT_MD" 'left absent'

echo "=== T-12: template active section direct sub-keys ⊆ init.md sub-key drift anchor ==="

# Direct (exactly 2-space indented) sub-keys per active top-level section in the
# template, emitted as "section.subkey". Deeper-nested keys (4+ spaces) and list
# items are excluded so only one level below each section is asserted.
template_subkeys=$(awk '
  /# --- Advanced \(below this line\) ---/ { exit }
  /^[a-z_][a-zA-Z0-9_-]*:/ { section=$0; sub(/:.*/, "", section); next }
  /^  [a-z_][a-zA-Z0-9_-]*:/ { key=$0; sub(/^  /, "", key); sub(/:.*/, "", key); print section "." key }
' "$TEMPLATE")

[ -n "$template_subkeys" ] || { echo "FATAL: no template sub-keys extracted (parser drift?)" >&2; exit 1; }

# The init.md sub-key drift anchor block: from the marker line through its closing
# "When a new sub-key is added" guard line (single source of the enumeration).
sub_anchor_start=$(grep -nF 'Active sub-keys covered on --upgrade' "$INIT_MD" | head -1 | cut -d: -f1 || true)
if [ -z "$sub_anchor_start" ]; then
  fail "init.md is missing the 'Active sub-keys covered on --upgrade' drift anchor"
else
  pass "init.md sub-key drift anchor present"
  sub_anchor_end=$(awk -v s="$sub_anchor_start" 'NR>s && /When a new sub-key is added/ { print NR; exit }' "$INIT_MD")
  [ -n "$sub_anchor_end" ] || sub_anchor_end=$(wc -l < "$INIT_MD")
  anchor_block=$(sed -n "${sub_anchor_start},${sub_anchor_end}p" "$INIT_MD")

  for pair in $template_subkeys; do
    sec=${pair%%.*}
    key=${pair#*.}
    # The anchor row for this section, e.g. "- `review`: `min_reviewers`, ...".
    row=$(printf '%s\n' "$anchor_block" | grep -F -- "- \`$sec\`:" | head -1 || true)
    if [ -z "$row" ]; then
      fail "init.md sub-key anchor has no row for section '$sec' (needed for '$pair')"
    elif printf '%s' "$row" | grep -qF -- "\`$key\`"; then
      pass "template sub-key '$pair' is enumerated in init.md"
    else
      fail "template sub-key '$pair' is NOT enumerated in init.md sub-key anchor"
    fi
  done
fi

echo "=== T-13: current >= latest short-circuit path runs drift back-add ==="

# If the `current >= latest` short-circuit path runs only
# "Step 3 Backup -> Step 3.5 Wiki Append -> Step 7" and skips Step 4-6, then
# multi_session / new active sections / missing sub-keys are silently omitted.
# The correct routing sends the short-circuit path through Step 4 Identify -> Step 6 Apply
# (drift back-add) and folds the Wiki-only Step 3.5 into Step 6 item 7. init.md is
# an LLM procedure doc, so the back-add behavior itself is exercised by the LLM at
# runtime, not by a fixture here; these static assertions guard that init.md keeps
# the corrected routing so the short-circuit path cannot silently regress.

# Positive: the short-circuit row backs up FIRST, then routes Step 4 Identify -> Step 6
# Apply, asserted as one ordered pattern so it doubles as the AC-6 Backup-precondition
# guard AND the routing guard. Ordering matters: a regression that restores the old
# "Step 3 Backup -> Step 3.5 Wiki Append -> skip Step 4-6" routing fails this assertion
# because Step 4 Identify / Step 6 Apply are absent from that row. (A bare
# 'current >= latest.*Step 3 Backup' would pass even on the buggy old row, since Backup
# was always present on the short-circuit row — anchoring Backup *before* Step 4/6 is
# what gives the assertion its regression-detecting power.)
assert_grep "init.md 'current >= latest' row backs up first, then routes Step 4 Identify -> Step 6 Apply -> Step 6.5 nested gitignore migrate (AC-6 precondition + routing order)" \
  "$INIT_MD" 'current >= latest.*Step 3 Backup.*Step 4 Identify.*Step 6 Apply.*Step 6.5'
# Step 6 spells out which items the short-circuit path applies (the drift back-add set).
assert_grep "init.md Step 6 applies only the drift back-add items on the short-circuit path" \
  "$INIT_MD" 'short-circuit path.*only items 3, 4, 6, 7'

# Negative: the old skip wording and the folded-away Wiki-only Step 3.5 block are gone.
assert_not_grep "init.md no longer says the short-circuit path skips Step 4-6" \
  "$INIT_MD" 'Step 4-6 はスキップ'
assert_not_grep "init.md no longer carries the Wiki-only 'Step 3.5: Wiki Section Append' block" \
  "$INIT_MD" 'Step 3\.5: Wiki Section Append'

# --- Summary ---
if ! print_summary "init-upgrade-drift" \
  "Drift: sync init.md's '--upgrade' anchors ('Active top-level sections covered on --upgrade' and 'Active sub-keys covered on --upgrade') with the template's active sections/sub-keys above the '--- Advanced ---' marker."; then
  exit 1
fi
echo "All init-upgrade-drift checks passed!"
