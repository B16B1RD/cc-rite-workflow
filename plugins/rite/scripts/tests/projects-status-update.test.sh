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
run_script() {
  local json_args="$1"
  local scenario="${2:-psu_success}"
  local issue_number="${3:-42}"
  local state_dir
  state_dir=$(mktemp -d "$TEST_DIR/mockstate.XXXXXX")
  local rc=0
  local output
  output=$(
    MOCK_GH_SCENARIO="$scenario" \
    MOCK_ISSUE_NUMBER="$issue_number" \
    MOCK_GH_STATE_DIR="$state_dir" \
    PATH="$MOCK_BIN_DIR:$PATH" \
    bash "$TARGET" "$json_args" 2>"$TEST_DIR/last_stderr"
  ) || rc=$?
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
rc=0
output=$(PATH="$MOCK_BIN_DIR:$PATH" bash "$TARGET" 2>&1) || rc=$?
if [ "$rc" = "1" ] && printf '%s\n' "$output" | jq -e '.result == "failed"' >/dev/null; then
  pass "No args → exit 1 with failed result"
else
  fail "Expected exit 1 with failed result, got rc=$rc output=$output"
fi

# --------------------------------------------------------------------------
# TC-002: Invalid JSON → exit 1
# --------------------------------------------------------------------------
echo "TC-002: Invalid JSON → exit 1"
rc=0
output=$(PATH="$MOCK_BIN_DIR:$PATH" bash "$TARGET" "not-json" 2>&1) || rc=$?
if [ "$rc" = "1" ] && printf '%s\n' "$output" | jq -e '.warnings | map(select(. == "Invalid JSON argument")) | length == 1' >/dev/null; then
  pass "Invalid JSON → exit 1"
else
  fail "Expected exit 1 with 'Invalid JSON argument' warning, got rc=$rc output=$output"
fi

# --------------------------------------------------------------------------
# TC-003: Missing required field (owner) → exit 1
# --------------------------------------------------------------------------
echo "TC-003: Missing owner → exit 1"
rc=0
output=$(PATH="$MOCK_BIN_DIR:$PATH" bash "$TARGET" '{"issue_number": 42, "repo": "test-repo", "project_number": 6, "status_name": "Todo"}' 2>&1) || rc=$?
if [ "$rc" = "1" ] && printf '%s\n' "$output" | jq -e '.warnings | map(select(. == "owner is required")) | length == 1' >/dev/null; then
  pass "Missing owner → exit 1"
else
  fail "Expected exit 1 with 'owner is required', got rc=$rc output=$output"
fi

# --------------------------------------------------------------------------
# TC-004: Basic success path → result=updated
# --------------------------------------------------------------------------
echo "TC-004: Basic success → updated"
run_script "$(build_json 42 'In Progress')" psu_success
if [ "$LAST_RC" = "0" ] && [ "$(json_field '.result')" = "updated" ] && [ "$(json_field '.item_id')" = "PVTI_mock456" ] && [ "$(json_field '.option_id')" = "OPT_INPROGRESS" ]; then
  pass "Basic success: result=updated, item_id+option_id set"
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
rc=0
output=$(PATH="$MOCK_BIN_DIR:$PATH" bash "$TARGET" '{"owner": "x", "repo": "y", "project_number": 1, "status_name": "Todo"}' 2>&1) || rc=$?
if [ "$rc" = "1" ] && printf '%s\n' "$output" | jq -e '.warnings | map(select(. == "issue_number is required")) | length == 1' >/dev/null; then
  pass "Missing issue_number → exit 1"
else
  fail "TC-015 unexpected: rc=$rc output=$output"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" = "0" ]
