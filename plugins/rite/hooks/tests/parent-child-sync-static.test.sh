#!/bin/bash
# Static regression tests for Issue #513 parent-child Issue status sync.
#
# Guards against re-introduction of silent-skip patterns that caused
# past incidents #115, #381, #15 and the #513 reopening. Verifies that
# the three canonical files contain the 3-method OR detection and that
# close.md has Phase 4.6 Parent Auto-Close logic.
#
# Usage: bash plugins/rite/hooks/tests/parent-child-sync-static.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
PROJECTS_INTEGRATION="$REPO_ROOT/plugins/rite/references/projects-integration.md"
CLOSE_MD="$REPO_ROOT/plugins/rite/commands/issue/close.md"
START_MD="$REPO_ROOT/plugins/rite/commands/issue/start.md"

PASS=0
FAIL=0
FAILURES=()

assert_file_contains() {
  local file="$1"
  local pattern="$2"
  local description="$3"
  # Use `-e` explicitly so patterns that start with `-` (e.g. `--jq...`) are not
  # interpreted as grep flags. `-E` must precede `-e` for extended regex.
  if grep -qE -e "$pattern" "$file"; then
    PASS=$((PASS + 1))
    echo "  ✓ $description"
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("$description (file: $(basename "$file"), pattern: $pattern)")
    echo "  ✗ $description" >&2
  fi
}

assert_file_not_contains() {
  local file="$1"
  local pattern="$2"
  local description="$3"
  if grep -qE -e "$pattern" "$file"; then
    FAIL=$((FAIL + 1))
    FAILURES+=("$description (file: $(basename "$file"), forbidden pattern found: $pattern)")
    echo "  ✗ $description" >&2
  else
    PASS=$((PASS + 1))
    echo "  ✓ $description"
  fi
}

echo "=== T-07: Parent-child sync regression guards (Issue #513) ==="

# Prerequisite: all three files exist
for f in "$PROJECTS_INTEGRATION" "$CLOSE_MD" "$START_MD"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: required file not found: $f" >&2
    exit 1
  fi
done

echo ""
echo "[Group 1] projects-integration.md 2.4.7.1: 3-method OR detection"
assert_file_contains "$PROJECTS_INTEGRATION" '## 親 Issue' \
  "Method 1 (body meta '## 親 Issue') is present"
assert_file_contains "$PROJECTS_INTEGRATION" 'parent[[:space:]]*\{[[:space:]]*number' \
  "Method 2 (Sub-Issues API 'parent { number }') is present"
# --state filter is intentionally context-dependent (open=start side / all=close side);
# check for --state presence without fixing the value, plus `in:body` tasklist search marker.
assert_file_contains "$PROJECTS_INTEGRATION" 'gh issue list[[:space:]]+--state[[:space:]]+[a-z]+[[:space:]]+--search.*in:body' \
  "Method 3 (tasklist search) is present"
assert_file_contains "$PROJECTS_INTEGRATION" '\[DEBUG\] parent not detected' \
  "Silent-skip guard: explicit debug log on no-parent case (AC-4)"

echo ""
echo "[Group 2] close.md Phase 4.5.1: 3-method OR detection (consistency with start)"
assert_file_contains "$CLOSE_MD" '## 親 Issue' \
  "Method 1 (body meta '## 親 Issue') is present"
assert_file_contains "$CLOSE_MD" 'parent[[:space:]]*\{[[:space:]]*number[[:space:]]*\}' \
  "Method 2 (Sub-Issues API 'parent { number }') is present"
assert_file_contains "$CLOSE_MD" 'gh issue list[[:space:]]+--state[[:space:]]+[a-z]+.*--search.*in:body' \
  "Method 3 (tasklist search) is present"
assert_file_contains "$CLOSE_MD" '\[DEBUG\] parent not detected' \
  "Silent-skip guard: explicit debug log on no-parent case (AC-4)"

echo ""
echo "[Group 3] close.md Phase 4.6: Parent Auto-Close logic (AC-2 + AC-6)"
assert_file_contains "$CLOSE_MD" '^##[[:space:]]+Phase[[:space:]]+4\.6' \
  "Phase 4.6 heading is present"
# AC-6 idempotency guard: parent_state == CLOSED short-circuit
assert_file_contains "$CLOSE_MD" 'parent_state[[:space:]]*=.*gh issue view.*parent_number.*--jq.*\.state' \
  "AC-6 idempotency guard: parent_state check exists"
assert_file_contains "$CLOSE_MD" 'already closed.*AC-6 idempotent' \
  "AC-6 idempotency guard: idempotent no-op skip path exists"
# all-children-closed check — match the jq all(.[]; ...) form with flexible whitespace
assert_file_contains "$CLOSE_MD" 'all_closed=.*all\([[:space:]]*\.\[\][[:space:]]*;[[:space:]]*\.state[[:space:]]*==[[:space:]]*"CLOSED"' \
  "All-children-closed check logic is present"
assert_file_contains "$CLOSE_MD" 'gh issue close.*parent_number' \
  "Parent close command is present"
assert_file_contains "$CLOSE_MD" 'done_option_id' \
  "Projects Status -> Done update logic is present"
# CRITICAL fix: explicit jq extraction for project item / status field / done option (determinism)
assert_file_contains "$CLOSE_MD" 'jq -r .*projectItems\.nodes\[\].*select.*\.project\.number' \
  "Phase 4.6.3 Step 1: deterministic jq extraction for parent_item_id exists"
assert_file_contains "$CLOSE_MD" 'jq -r .*fields\[\].*select.*name.*==.*"Status".*options\[\].*select.*name.*==.*"Done"' \
  "Phase 4.6.3 Step 2: deterministic jq extraction for done_option_id exists"
# state-inconsistency summary (MEDIUM fix)
assert_file_contains "$CLOSE_MD" 'state 不整合' \
  "Phase 4.6.3 Step 5: state inconsistency summary is emitted"
assert_file_contains "$CLOSE_MD" 'AskUserQuestion' \
  "User confirmation via AskUserQuestion (AC-2: not silent auto-close)"
# HIGH fix: no Method A 2>/dev/null silent stderr suppression in Phase 4.6.1
# (presence of method_a_err tempfile capture signals the fix)
assert_file_contains "$CLOSE_MD" 'method_a_err=.*mktemp' \
  "Phase 4.6.1 Method A stderr capture (no silent suppression)"

echo ""
echo "[Group 4] start.md: no inline trackedInIssues simplification (Issue #513 root cause)"
assert_file_not_contains "$START_MD" 'Query trackedInIssues for the current Issue' \
  "Regression guard: inline 'Query trackedInIssues' simplification is removed"
assert_file_contains "$START_MD" 'projects-integration\.md#247' \
  "Delegation to projects-integration.md §2.4.7 is present"
assert_file_contains "$START_MD" 'Issue #513 regression guard' \
  "Regression guard comment is present (prevents re-introduction)"

echo ""
echo "==============================="
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "Failures:"
  for msg in "${FAILURES[@]}"; do
    echo "  - $msg"
  done
  exit 1
fi
echo "All parent-child-sync static checks passed."
