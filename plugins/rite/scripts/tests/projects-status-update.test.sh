#!/bin/bash
# Tests for projects-status-update.sh
# Usage: bash plugins/rite/scripts/tests/projects-status-update.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../projects-status-update.sh"
MOCK_DIR="$SCRIPT_DIR"
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0

MOCK_BIN_DIR="$TEST_DIR/mock-bin"
mkdir -p "$MOCK_BIN_DIR"
ln -s "$MOCK_DIR/mock-gh.sh" "$MOCK_BIN_DIR/gh"

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ FAIL: $1"; }

# Helper: run the target script with mock gh and given JSON args.
# Each call uses a fresh MOCK_GH_STATE_DIR so state-machine scenarios
# (e.g., psu_auto_add_then_ok) do not leak between test cases.
# stderr is redirected to a separate file (NOT merged into stdout) so JSON
# parsing assertions on $LAST_OUTPUT are not corrupted by incidental warnings.
run_script() {
  local json_args="$1"
  local scenario="${2:-psu_success}"
  local issue_number="${3:-42}"
  local state_dir
  state_dir=$(mktemp -d "$TEST_DIR/mockstate.XXXXXX")
  LAST_GH_LOG="$state_dir/gh.log"
  local rc=0
  local output
  output=$(
    MOCK_GH_SCENARIO="$scenario" \
    MOCK_ISSUE_NUMBER="$issue_number" \
    MOCK_GH_STATE_DIR="$state_dir" \
    MOCK_GH_LOG="$LAST_GH_LOG" \
    PATH="$MOCK_BIN_DIR:$PATH" \
    bash "$TARGET" "$json_args" 2>"$TEST_DIR/last_stderr"
  ) || rc=$?
  LAST_OUTPUT="$output"
  LAST_RC=$rc
  return 0
}

gh_log_has() {
  grep -qE "$1" "${LAST_GH_LOG:-/dev/null}" 2>/dev/null
}

# Skip/no-op must not treat an unwired empty log as "item-edit absent".
assert_item_edit_absent() {
  local label="$1"
  if gh_log_has 'item-edit'; then
    fail "$label: expected no item-edit, log=$(cat "$LAST_GH_LOG" 2>/dev/null)"
    return 1
  fi
  if ! gh_log_has 'graphql|field-list'; then
    fail "$label: MOCK_GH_LOG missing graphql/field-list (cannot treat as item-edit absent)"
    return 1
  fi
  return 0
}

assert_item_edit_present() {
  local label="$1"
  if gh_log_has 'item-edit'; then
    return 0
  fi
  fail "$label: expected item-edit in MOCK_GH_LOG, log=$(cat "$LAST_GH_LOG" 2>/dev/null)"
  return 1
}

# Validation helper: run script with no scenario / mock setup (validation
# branch exits before any `gh` call). stderr is isolated to avoid polluting
# the JSON stdout capture.
run_validation() {
  local args=("$@")
  local rc=0
  local output
  output=$(PATH="$MOCK_BIN_DIR:$PATH" bash "$TARGET" "${args[@]}" 2>"$TEST_DIR/last_stderr") || rc=$?
  LAST_OUTPUT="$output"
  LAST_RC=$rc
  return 0
}

json_field() {
  printf '%s\n' "$LAST_OUTPUT" | jq -r "$1"
}

# Build a standard input JSON document.
build_json() {
  local issue="${1:-42}"
  local status="${2:-In Progress}"
  local auto_add="${3:-true}"
  local non_blocking="${4:-true}"
  local project_number="${5:-6}"
  jq -n \
    --argjson issue "$issue" \
    --arg owner "test-owner" \
    --arg repo "test-repo" \
    --argjson project_number "$project_number" \
    --arg status "$status" \
    --argjson auto_add "$auto_add" \
    --argjson non_blocking "$non_blocking" \
    '{issue_number:$issue, owner:$owner, repo:$repo, project_number:$project_number, status_name:$status, auto_add:$auto_add, non_blocking:$non_blocking}'
}

echo "=== projects-status-update.sh tests ==="
echo ""

# --------------------------------------------------------------------------
# TC-001: No arguments → exit 1
# --------------------------------------------------------------------------
echo "TC-001: No arguments → exit 1"
run_validation
if [ "$LAST_RC" = "1" ] && printf '%s\n' "$LAST_OUTPUT" | jq -e '.result == "failed"' >/dev/null; then
  pass "No args → exit 1 with failed result"
else
  fail "Expected exit 1 with failed result, got rc=$LAST_RC output=$LAST_OUTPUT"
fi

# --------------------------------------------------------------------------
# TC-002: Invalid JSON → exit 1
# --------------------------------------------------------------------------
echo "TC-002: Invalid JSON → exit 1"
run_validation "not-json"
if [ "$LAST_RC" = "1" ] && printf '%s\n' "$LAST_OUTPUT" | jq -e '.warnings | map(select(. == "Invalid JSON argument")) | length == 1' >/dev/null; then
  pass "Invalid JSON → exit 1"
else
  fail "Expected exit 1 with 'Invalid JSON argument' warning, got rc=$LAST_RC output=$LAST_OUTPUT"
fi

# --------------------------------------------------------------------------
# TC-003: Missing required field (owner) → exit 1
# --------------------------------------------------------------------------
echo "TC-003: Missing owner → exit 1"
run_validation '{"issue_number": 42, "repo": "test-repo", "project_number": 6, "status_name": "Todo"}'
if [ "$LAST_RC" = "1" ] && printf '%s\n' "$LAST_OUTPUT" | jq -e '.warnings | map(select(. == "owner is required")) | length == 1' >/dev/null; then
  pass "Missing owner → exit 1"
else
  fail "Expected exit 1 with 'owner is required', got rc=$LAST_RC output=$LAST_OUTPUT"
fi

# --------------------------------------------------------------------------
# TC-003a/b/c: Missing remaining required fields → exit 1
# --------------------------------------------------------------------------
echo "TC-003a: Missing repo → exit 1"
run_validation '{"issue_number": 42, "owner": "x", "project_number": 6, "status_name": "Todo"}'
if [ "$LAST_RC" = "1" ] && printf '%s\n' "$LAST_OUTPUT" | jq -e '.warnings | map(select(. == "repo is required")) | length == 1' >/dev/null; then
  pass "Missing repo → exit 1"
else
  fail "TC-003a unexpected: rc=$LAST_RC output=$LAST_OUTPUT"
fi

echo "TC-003b: Missing project_number → exit 1"
run_validation '{"issue_number": 42, "owner": "x", "repo": "y", "status_name": "Todo"}'
if [ "$LAST_RC" = "1" ] && printf '%s\n' "$LAST_OUTPUT" | jq -e '.warnings | map(select(. == "project_number is required")) | length == 1' >/dev/null; then
  pass "Missing project_number → exit 1"
else
  fail "TC-003b unexpected: rc=$LAST_RC output=$LAST_OUTPUT"
fi

echo "TC-003c: Missing status_name → exit 1"
run_validation '{"issue_number": 42, "owner": "x", "repo": "y", "project_number": 6}'
if [ "$LAST_RC" = "1" ] && printf '%s\n' "$LAST_OUTPUT" | jq -e '.warnings | map(select(. == "status_name is required")) | length == 1' >/dev/null; then
  pass "Missing status_name → exit 1"
else
  fail "TC-003c unexpected: rc=$LAST_RC output=$LAST_OUTPUT"
fi

# --------------------------------------------------------------------------
# TC-004: Basic success path → result=updated
# --------------------------------------------------------------------------
echo "TC-004: Basic success → updated"
run_script "$(build_json 42 'In Progress')" psu_success
if [ "$LAST_RC" = "0" ] && [ "$(json_field '.result')" = "updated" ] && [ "$(json_field '.item_id')" = "PVTI_mock456" ] && [ "$(json_field '.option_id')" = "OPT_INPROGRESS" ] \
   && assert_item_edit_present "TC-004"; then
  pass "Basic success: result=updated, item_id+option_id set, item-edit issued"
else
  fail "TC-004 unexpected: rc=$LAST_RC output=$LAST_OUTPUT"
fi

# --------------------------------------------------------------------------
# TC-005: Not in project + auto_add=true → auto-add then updated
# --------------------------------------------------------------------------
echo "TC-005: Auto-add + re-query success"
run_script "$(build_json 42 'In Progress' true)" psu_auto_add_then_ok
if [ "$LAST_RC" = "0" ] && [ "$(json_field '.result')" = "updated" ]; then
  pass "Auto-add path: updated after re-query"
else
  fail "TC-005 unexpected: rc=$LAST_RC output=$LAST_OUTPUT"
fi

# --------------------------------------------------------------------------
# TC-006: Not in project + auto_add=false → skipped_not_in_project
# --------------------------------------------------------------------------
echo "TC-006: Not in project + auto_add=false → skipped"
run_script "$(build_json 42 'Todo' false)" psu_not_in_project
if [ "$LAST_RC" = "0" ] && [ "$(json_field '.result')" = "skipped_not_in_project" ]; then
  pass "skipped_not_in_project returned, exit 0"
else
  fail "TC-006 unexpected: rc=$LAST_RC output=$LAST_OUTPUT"
fi

# --------------------------------------------------------------------------
# TC-007: Issue not found → failed (non_blocking=true, exit 0)
# --------------------------------------------------------------------------
echo "TC-007: Issue not found → failed+exit 0"
run_script "$(build_json 42 'Todo' true true)" psu_issue_not_found
if [ "$LAST_RC" = "0" ] && [ "$(json_field '.result')" = "failed" ]; then
  pass "Issue not found → failed, non-blocking exit 0"
else
  fail "TC-007 unexpected: rc=$LAST_RC output=$LAST_OUTPUT"
fi

# --------------------------------------------------------------------------
# TC-008: item-add failure → failed
# --------------------------------------------------------------------------
echo "TC-008: item-add failure → failed"
run_script "$(build_json 42 'Todo' true)" psu_auto_add_fail
if [ "$LAST_RC" = "0" ] && [ "$(json_field '.result')" = "failed" ] && printf '%s\n' "$LAST_OUTPUT" | jq -e '.warnings | map(select(. | test("item-add failed"))) | length >= 1' >/dev/null; then
  pass "item-add failure captured in warnings"
else
  fail "TC-008 unexpected: rc=$LAST_RC output=$LAST_OUTPUT"
fi

# --------------------------------------------------------------------------
# TC-009: field-list failure → failed
# --------------------------------------------------------------------------
echo "TC-009: field-list failure → failed"
run_script "$(build_json 42 'Todo')" psu_field_list_fail
if [ "$LAST_RC" = "0" ] && [ "$(json_field '.result')" = "failed" ] && printf '%s\n' "$LAST_OUTPUT" | jq -e '.warnings | map(select(. | test("field-list failed"))) | length >= 1' >/dev/null; then
  pass "field-list failure captured in warnings"
else
  fail "TC-009 unexpected: rc=$LAST_RC output=$LAST_OUTPUT"
fi

# --------------------------------------------------------------------------
# TC-010: Status field missing → failed
# --------------------------------------------------------------------------
echo "TC-010: Status field missing → failed"
run_script "$(build_json 42 'Todo')" psu_no_status_field
if [ "$LAST_RC" = "0" ] && [ "$(json_field '.result')" = "failed" ] && printf '%s\n' "$LAST_OUTPUT" | jq -e '.warnings | map(select(. | test("Status field not found"))) | length >= 1' >/dev/null; then
  pass "Status field missing captured"
else
  fail "TC-010 unexpected: rc=$LAST_RC output=$LAST_OUTPUT"
fi

# --------------------------------------------------------------------------
# TC-011: Status option not found → failed
# --------------------------------------------------------------------------
echo "TC-011: Status option 'Archive' not found → failed"
run_script "$(build_json 42 'Archive')" psu_no_status_option
if [ "$LAST_RC" = "0" ] && [ "$(json_field '.result')" = "failed" ] && printf '%s\n' "$LAST_OUTPUT" | jq -e ".warnings | map(select(. | test(\"Status option 'Archive' not found\"))) | length >= 1" >/dev/null; then
  pass "Unknown Status option captured"
else
  fail "TC-011 unexpected: rc=$LAST_RC output=$LAST_OUTPUT"
fi

# --------------------------------------------------------------------------
# TC-012: item-edit failure → failed, fields partially populated
# --------------------------------------------------------------------------
echo "TC-012: item-edit failure → failed with item_id/project_id"
run_script "$(build_json 42 'In Progress')" psu_item_edit_fail
if [ "$LAST_RC" = "0" ] \
   && [ "$(json_field '.result')" = "failed" ] \
   && [ "$(json_field '.item_id')" = "PVTI_mock456" ] \
   && [ "$(json_field '.project_id')" = "PVT_mock123" ] \
   && [ "$(json_field '.status_field_id')" = "FIELD_STATUS" ] \
   && [ "$(json_field '.option_id')" = "OPT_INPROGRESS" ]; then
  pass "item-edit failure returns partial identifiers"
else
  fail "TC-012 unexpected: rc=$LAST_RC output=$LAST_OUTPUT"
fi

# --------------------------------------------------------------------------
# TC-013: non_blocking=false + item-edit failure → exit 1
# --------------------------------------------------------------------------
echo "TC-013: non_blocking=false + failure → exit 1"
run_script "$(build_json 42 'In Progress' true false)" psu_item_edit_fail
if [ "$LAST_RC" = "1" ] && [ "$(json_field '.result')" = "failed" ]; then
  pass "non_blocking=false correctly returns exit 1"
else
  fail "TC-013 unexpected: rc=$LAST_RC output=$LAST_OUTPUT"
fi

# --------------------------------------------------------------------------
# TC-014: status_field_id_hint provided → skips field id extraction but still
#         resolves option id from field-list
# --------------------------------------------------------------------------
echo "TC-014: status_field_id_hint honored"
json=$(jq -n --arg owner "test-owner" --arg repo "test-repo" --arg status "In Progress" --arg hint "PVTSSF_hinted" \
  '{issue_number:42, owner:$owner, repo:$repo, project_number:6, status_name:$status, status_field_id_hint:$hint, auto_add:true, non_blocking:true}')
run_script "$json" psu_success
if [ "$LAST_RC" = "0" ] && [ "$(json_field '.result')" = "updated" ] && [ "$(json_field '.status_field_id')" = "PVTSSF_hinted" ]; then
  pass "status_field_id_hint preserved in output"
else
  fail "TC-014 unexpected: rc=$LAST_RC output=$LAST_OUTPUT"
fi

# --------------------------------------------------------------------------
# TC-015: Missing issue_number → exit 1
# --------------------------------------------------------------------------
echo "TC-015: Missing issue_number → exit 1"
run_validation '{"owner": "x", "repo": "y", "project_number": 1, "status_name": "Todo"}'
if [ "$LAST_RC" = "1" ] && printf '%s\n' "$LAST_OUTPUT" | jq -e '.warnings | map(select(. == "issue_number is required")) | length == 1' >/dev/null; then
  pass "Missing issue_number → exit 1"
else
  fail "TC-015 unexpected: rc=$LAST_RC output=$LAST_OUTPUT"
fi

# --------------------------------------------------------------------------
# TC-016: Initial GraphQL projectItems query fails → failed
# --------------------------------------------------------------------------
echo "TC-016: GraphQL query failure → failed"
run_script "$(build_json 42 'Todo')" psu_graphql_fail
if [ "$LAST_RC" = "0" ] \
   && [ "$(json_field '.result')" = "failed" ] \
   && printf '%s\n' "$LAST_OUTPUT" | jq -e '.warnings | map(select(. | test("projectItems query failed"))) | length >= 1' >/dev/null; then
  pass "GraphQL query failure captured"
else
  fail "TC-016 unexpected: rc=$LAST_RC output=$LAST_OUTPUT"
fi

# --------------------------------------------------------------------------
# TC-017: auto-add succeeds but re-query still empty → failed
# (guards the scripts/projects-status-update.sh "Auto-add succeeded but project
# item not found in re-query" branch from regression)
# --------------------------------------------------------------------------
echo "TC-017: auto-add + re-query empty → failed"
run_script "$(build_json 42 'In Progress' true)" psu_auto_add_requery_empty
if [ "$LAST_RC" = "0" ] \
   && [ "$(json_field '.result')" = "failed" ] \
   && printf '%s\n' "$LAST_OUTPUT" | jq -e '.warnings | map(select(. | test("Auto-add succeeded but project item not found in re-query"))) | length >= 1' >/dev/null; then
  pass "auto-add re-query empty captured"
else
  fail "TC-017 unexpected: rc=$LAST_RC output=$LAST_OUTPUT"
fi

# --------------------------------------------------------------------------
# TC-018: Issue URL is null when auto_add=true → failed
# (guards the "Could not determine issue URL for auto-add" branch)
# --------------------------------------------------------------------------
echo "TC-018: auto_add=true + issue.url=null → failed"
run_script "$(build_json 42 'Todo' true)" psu_issue_url_null
if [ "$LAST_RC" = "0" ] \
   && [ "$(json_field '.result')" = "failed" ] \
   && printf '%s\n' "$LAST_OUTPUT" | jq -e '.warnings | map(select(. | test("Could not determine issue URL"))) | length >= 1' >/dev/null; then
  pass "issue URL null captured"
else
  fail "TC-018 unexpected: rc=$LAST_RC output=$LAST_OUTPUT"
fi

# --------------------------------------------------------------------------
# TC-019: query shape pin — fieldValues + ProjectV2ItemFieldSingleSelectValue
# --------------------------------------------------------------------------
echo "TC-019: helper query includes fieldValues fragment"
if grep -q 'fieldValues' "$TARGET" && grep -q 'ProjectV2ItemFieldSingleSelectValue' "$TARGET"; then
  pass "query_project_items reads fieldValues via ProjectV2ItemFieldSingleSelectValue"
else
  fail "TC-019: helper query missing fieldValues / ProjectV2ItemFieldSingleSelectValue"
fi

# --------------------------------------------------------------------------
# TC-020: Cancelled × Done → skipped_terminal_conflict, no item-edit (AC-1)
# --------------------------------------------------------------------------
echo "TC-020: Cancelled × Done → skipped_terminal_conflict"
run_script "$(build_json 42 'Done')" psu_current_cancelled
if [ "$LAST_RC" = "0" ] \
   && [ "$(json_field '.result')" = "skipped_terminal_conflict" ] \
   && [ "$(json_field '.warnings | length')" -ge 1 ] \
   && assert_item_edit_absent "TC-020"; then
  pass "Cancelled→Done skipped, WARNING present, no item-edit"
else
  fail "TC-020 unexpected: rc=$LAST_RC output=$LAST_OUTPUT"
fi

# --------------------------------------------------------------------------
# TC-021: Done × Cancelled → updated + item-edit (one-way guard; issue-cancel)
# --------------------------------------------------------------------------
echo "TC-021: Done × Cancelled → updated + item-edit"
run_script "$(build_json 42 'Cancelled')" psu_current_done
if [ "$LAST_RC" = "0" ] \
   && [ "$(json_field '.result')" = "updated" ] \
   && assert_item_edit_present "TC-021"; then
  pass "Done→Cancelled writes (issue-cancel resync preserved)"
else
  fail "TC-021 unexpected: rc=$LAST_RC output=$LAST_OUTPUT"
fi

# --------------------------------------------------------------------------
# TC-022: Done × Done → updated, no item-edit (AC-2 same-terminal no-op)
# --------------------------------------------------------------------------
echo "TC-022: Done × Done → updated no-op"
run_script "$(build_json 42 'Done')" psu_current_done
if [ "$LAST_RC" = "0" ] \
   && [ "$(json_field '.result')" = "updated" ] \
   && assert_item_edit_absent "TC-022"; then
  pass "Done→Done idempotent no-op, no item-edit"
else
  fail "TC-022 unexpected: rc=$LAST_RC output=$LAST_OUTPUT"
fi

# --------------------------------------------------------------------------
# TC-023: non-terminal × Done → updated + item-edit (AC-2)
# --------------------------------------------------------------------------
echo "TC-023: Todo × Done → updated + item-edit"
run_script "$(build_json 42 'Done')" psu_success
if [ "$LAST_RC" = "0" ] \
   && [ "$(json_field '.result')" = "updated" ] \
   && assert_item_edit_present "TC-023"; then
  pass "non-terminal→Done writes"
else
  fail "TC-023 unexpected: rc=$LAST_RC output=$LAST_OUTPUT"
fi

# --------------------------------------------------------------------------
# TC-024: Cancelled × Cancelled → updated, no item-edit (AC-3)
# --------------------------------------------------------------------------
echo "TC-024: Cancelled × Cancelled → updated no-op"
run_script "$(build_json 42 'Cancelled')" psu_current_cancelled
if [ "$LAST_RC" = "0" ] \
   && [ "$(json_field '.result')" = "updated" ] \
   && assert_item_edit_absent "TC-024"; then
  pass "Cancelled→Cancelled idempotent no-op"
else
  fail "TC-024 unexpected: rc=$LAST_RC output=$LAST_OUTPUT"
fi

# --------------------------------------------------------------------------
# TC-025: fieldValues key missing × Done → failed, no item-edit (AC-4)
# --------------------------------------------------------------------------
echo "TC-025: fieldValues missing × Done → failed"
run_script "$(build_json 42 'Done')" psu_fieldvalues_missing
if [ "$LAST_RC" = "0" ] \
   && [ "$(json_field '.result')" = "failed" ] \
   && printf '%s\n' "$LAST_OUTPUT" | jq -e '.warnings | map(select(. | test("Could not read current Status"))) | length >= 1' >/dev/null \
   && assert_item_edit_absent "TC-025"; then
  pass "unreadable current Status fails without write"
else
  fail "TC-025 unexpected: rc=$LAST_RC output=$LAST_OUTPUT"
fi

# --------------------------------------------------------------------------
# TC-026: fieldValues.nodes empty × Done → updated + item-edit (unset ≠ unreadable)
# --------------------------------------------------------------------------
echo "TC-026: fieldValues empty × Done → updated + item-edit"
run_script "$(build_json 42 'Done')" psu_fieldvalues_empty
if [ "$LAST_RC" = "0" ] \
   && [ "$(json_field '.result')" = "updated" ] \
   && assert_item_edit_present "TC-026"; then
  pass "empty fieldValues is unset, write allowed"
else
  fail "TC-026 unexpected: rc=$LAST_RC output=$LAST_OUTPUT"
fi

# --------------------------------------------------------------------------
# TC-027: no Status entry × Done → updated + item-edit (unset ≠ unreadable)
# --------------------------------------------------------------------------
echo "TC-027: no Status entry × Done → updated + item-edit"
run_script "$(build_json 42 'Done')" psu_fieldvalues_nostatus
if [ "$LAST_RC" = "0" ] \
   && [ "$(json_field '.result')" = "updated" ] \
   && assert_item_edit_present "TC-027"; then
  pass "Status-less fieldValues is unset, write allowed"
else
  fail "TC-027 unexpected: rc=$LAST_RC output=$LAST_OUTPUT"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" = "0" ]
