#!/bin/bash
# Static pin: no Status consumer in plugins/rite decides or writes on an English column
# name. Every judgement and every write goes through the role the resolver returns
# (hooks/scripts/lib/projects-status-config.sh), so a board that spells its columns
# differently behaves the same way.
#
# Detection grammar (deliberately narrow — messages, prose and examples that merely
# *mention* a column name are not decisions):
#   - shell test comparisons against a column name:   = "In Progress"   != "Done"
#   - case labels on a column name:                    "In Review")     Todo)
#   - creation payload defaults carrying a column:     status: "Todo"   "status": "Todo"
#                                                      --arg status "Todo"   // "Todo"
#   - a column name bound to an identifier:            TERMINAL="Done"
#     (a comparison against that identifier is a decision on the name by one indirection)
# Exclusions: the resolver itself (its legacy defaults are the one legitimate home of
# the English names), the test fixtures / mocks, and the setup skill (it provisions
# board options by name, which is not a judgement on a row).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"

COLUMN_NAMES='Todo|In Progress|In Review|Done|Cancelled'
# Each alternative is one grammar arm from the header. Kept as separate patterns so a
# failure names the arm that matched.
PATTERNS=(
  "[!=]= *\"($COLUMN_NAMES)\""
  "^[[:space:]]*\"($COLUMN_NAMES)\"\\)"
  "^[[:space:]]*(Todo|Done|Cancelled)\\)"
  "\"?status\"?: *\"Todo\""
  "--arg status \"Todo\""
  "// *\"Todo\""
  "[A-Za-z_0-9]=\"($COLUMN_NAMES)\""
)

# $1=file  — prints matching lines (grep -nE) for every arm, or nothing.
scan_file() {
  local file="$1" pat
  for pat in "${PATTERNS[@]}"; do
    grep -nE -- "$pat" "$file" 2>/dev/null | sed "s|^|${file#"$PLUGIN_ROOT/"}:|"
  done
}

echo "=== positive control: the grammar detects each decision shape ==="
# A fixture carrying one line per arm must produce one hit per arm; a grammar that
# silently stopped matching would make the sweep below pass on an empty net.
fixture=$(mktemp "${TMPDIR:-/tmp}/rite-status-role-static-XXXXXX")
cat > "$fixture" <<'FIX'
if [ "$CURRENT" != "In Review" ]; then :; fi
case "$s" in
  "In Progress") :;;
  Todo) :;;
esac
  status: "Todo",
jq -n --arg status "Todo"
x=$(spec_get '.projects.status // "Todo"')
TERMINAL="Done"
FIX
hits=$(scan_file "$fixture" | wc -l | tr -d ' ')
if [ "$hits" -ge 7 ]; then
  pass "grammar detects the seven decision shapes in the fixture ($hits hits)"
else
  fail "grammar detected only $hits of 7 decision shapes: $(scan_file "$fixture" | tr '\n' ' ')"
fi
rm -f "$fixture"

echo "=== negative control: messages and prose are not decisions ==="
fixture=$(mktemp "${TMPDIR:-/tmp}/rite-status-role-static-XXXXXX")
cat > "$fixture" <<'FIX'
echo "Projects Status を \"In Progress\" に更新しました"
# A row already on Cancelled is never drift.
| `ok` | 盤面が `In Progress` 以降に到達済み |
warn "Issue #$ISSUE board Status is \"Cancelled\" — abandoned"
FIX
hits=$(scan_file "$fixture" | wc -l | tr -d ' ')
if [ "$hits" -eq 0 ]; then
  pass "messages, comments and tables that mention a column name are not flagged"
else
  fail "grammar flagged $hits non-decision lines: $(scan_file "$fixture" | tr '\n' ' ')"
fi
rm -f "$fixture"

echo "=== sweep: plugins/rite has no column-name decisions outside the exclusions ==="
findings=""
while IFS= read -r file; do
  case "$file" in
    "$PLUGIN_ROOT"/hooks/scripts/lib/projects-status-config.sh) continue ;;
    "$PLUGIN_ROOT"/skills/setup/SKILL.md) continue ;;
    */tests/*) continue ;;
  esac
  hit=$(scan_file "$file")
  [ -n "$hit" ] && findings="${findings}${hit}"$'\n'
done < <(find "$PLUGIN_ROOT" -type f \( -name '*.sh' -o -name '*.md' \) | sort)
if [ -z "$findings" ]; then
  pass "no consumer decides or writes on a column name (resolver, setup, tests excluded)"
else
  fail "column-name decisions remain:"$'\n'"$findings"
fi

if ! print_summary "$(basename "$0")" "Status consumers must map the column name to a role (projects_status_role_for_name) before deciding, and pass roles (status_role / status: todo) when writing"; then
  exit 1
fi
