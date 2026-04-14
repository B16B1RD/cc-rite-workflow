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
echo "[Group 3] close.md Phase 4.6: Parent Auto-Close logic (AC-2 + close-side idempotency)"
assert_file_contains "$CLOSE_MD" '^##[[:space:]]+Phase[[:space:]]+4\.6' \
  "Phase 4.6 heading is present"
# Close-side idempotency guard: parent_state retrieval + CLOSED short-circuit
assert_file_contains "$CLOSE_MD" 'parent_state=.*gh issue view.*parent_number.*--jq.*\.state' \
  "Phase 4.6.0 idempotency guard: parent_state retrieval exists"
assert_file_contains "$CLOSE_MD" 'P460_DECISION=skip_already_closed' \
  "Phase 4.6.0 idempotency guard: skip_already_closed sentinel exists"
# HIGH fix (cycle 2): parent_state retrieval failure branch is in bash, not prose-only
assert_file_contains "$CLOSE_MD" 'P460_DECISION=skip_retrieval_failed' \
  "Phase 4.6.0 retrieval-failure branch: skip_retrieval_failed sentinel exists"
# all-children-closed check — flexible whitespace around operators
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
# state-inconsistency summary (cycle 1 MEDIUM fix)
assert_file_contains "$CLOSE_MD" 'state 不整合' \
  "Phase 4.6.3 Step 5: state inconsistency summary is emitted"
# Cycle 2 MEDIUM fix: success:field_lookup_failed case is separated from success:update_failed
# and prints a field-list diagnostic command instead of a broken one-liner with empty vars.
assert_file_contains "$CLOSE_MD" '"success:field_lookup_failed"\)' \
  "Phase 4.6.3 Step 5: success:field_lookup_failed is a dedicated case (not merged)"
assert_file_contains "$CLOSE_MD" '診断コマンド: gh project field-list' \
  "Phase 4.6.3 Step 5: field_lookup_failed case prints diagnostic command (not broken one-liner)"
# Cycle 2 LOW fix: failed:projects_disabled / failed:not_registered are classified separately
assert_file_contains "$CLOSE_MD" '"failed:projects_disabled"[|]"failed:not_registered"\)' \
  "Phase 4.6.3 Step 5: failed:projects_disabled/not_registered case is separated from catch-all"
assert_file_contains "$CLOSE_MD" 'AskUserQuestion' \
  "User confirmation via AskUserQuestion (AC-2: not silent auto-close)"
# Cycle 1 HIGH fix: Method A uses tempfile stderr capture (not 2>/dev/null)
assert_file_contains "$CLOSE_MD" 'method_a_err=.*mktemp' \
  "Phase 4.6.1 Method A stderr capture (no silent suppression)"
# Cycle 2 HIGH fix: Phase 4.6.3 Step 1-4 all capture stderr to tempfile (not 2>/dev/null / >/dev/null 2>&1)
assert_file_contains "$CLOSE_MD" 'p463_err_s1.*mktemp' \
  "Phase 4.6.3 Step 1: stderr tempfile capture (p463_err_s1)"
assert_file_contains "$CLOSE_MD" 'p463_err_s2.*mktemp' \
  "Phase 4.6.3 Step 2: stderr tempfile capture (p463_err_s2)"
assert_file_contains "$CLOSE_MD" 'p463_err_s3.*mktemp' \
  "Phase 4.6.3 Step 3: stderr tempfile capture (p463_err_s3)"
assert_file_contains "$CLOSE_MD" 'p463_err_s4.*mktemp' \
  "Phase 4.6.3 Step 4: stderr tempfile capture (p463_err_s4)"
# Cycle 2 MEDIUM fix: strict mode (set -uo pipefail) in Phase 4.6.0, 4.6.1, 4.6.3 bash blocks
assert_file_contains "$CLOSE_MD" 'Phase 4\.6\.0.*parent already closed' \
  "Phase 4.6.0 bash block header present"
# Cycle 2 HIGH fix: trackedIssues is labeled as Tasklists API (not Sub-Issues API)
assert_file_contains "$CLOSE_MD" 'trackedIssues.*Tasklists' \
  "Phase 4.6.1 Method A is correctly labeled as Tasklists API (not Sub-Issues API)"
assert_file_not_contains "$CLOSE_MD" 'Method A: Sub-Issues API' \
  "Regression guard: Method A mislabel 'Sub-Issues API' is removed"
# Cycle 2 HIGH fix: stale subsection reference 4.6.1-4.6.5 is corrected to 4.6.1-4.6.3
assert_file_not_contains "$CLOSE_MD" '4\.6\.1–4\.6\.5' \
  "Regression guard: stale 4.6.1-4.6.5 reference is removed (actual range is 4.6.1-4.6.3)"
# Cycle 2 MEDIUM fix: AC-6 citation is clarified as close-side extension, not literal AC-6
assert_file_contains "$CLOSE_MD" 'close-side idempotency' \
  "Phase 4.6.0 clarifies close-side idempotency (AC-6 applies to start side, not close side)"
# Cycle 3 LOW fix: Phase 4.6.0 placeholder sanity guard (unsubstituted / non-numeric parent_number)
assert_file_contains "$CLOSE_MD" 'P460_DECISION=skip_routing_bug' \
  "Phase 4.6.0 placeholder sanity guard: skip_routing_bug sentinel exists"
assert_file_contains "$CLOSE_MD" "''[|]'\\{parent_number\\}'" \
  "Phase 4.6.0 placeholder sanity guard: empty-or-literal placeholder case pattern exists"
# Cycle 3 LOW fix: _mktemp_or_warn helper takes exactly 1 arg (label), no dead var_name parameter
assert_file_contains "$CLOSE_MD" '_mktemp_or_warn\(\) \{' \
  "Helper _mktemp_or_warn is defined"
assert_file_not_contains "$CLOSE_MD" 'local var_name=' \
  "Regression guard: _mktemp_or_warn no longer takes dead var_name parameter"
assert_file_not_contains "$CLOSE_MD" '_mktemp_or_warn "p463_err_s' \
  "Regression guard: callers no longer pass dead var_name first arg"

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
