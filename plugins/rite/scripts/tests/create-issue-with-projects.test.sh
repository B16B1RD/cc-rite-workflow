#!/bin/bash
# Tests for create-issue-with-projects.sh
# Usage: bash plugins/rite/scripts/tests/create-issue-with-projects.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../create-issue-with-projects.sh"
MOCK_DIR="$SCRIPT_DIR"
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0

# Global mock bin directory: created once, reused by all tests
MOCK_BIN_DIR="$TEST_DIR/mock-bin"
mkdir -p "$MOCK_BIN_DIR"
ln -s "$MOCK_DIR/mock-gh.sh" "$MOCK_BIN_DIR/gh"

# Prerequisite check
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

pass() {
  PASS=$((PASS + 1))
  echo "  ✅ PASS: $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "  ❌ FAIL: $1"
}

# Helper: run the target script with mock gh and given JSON args
run_script() {
  local json_args="$1"
  local scenario="${2:-success}"
  local issue_number="${3:-42}"
  local mock_log="$TEST_DIR/gh_log_$$_$RANDOM"
  local rc=0
  local output
  output=$(
    MOCK_GH_SCENARIO="$scenario" \
    MOCK_ISSUE_NUMBER="$issue_number" \
    MOCK_GH_LOG="$mock_log" \
    RETRY_DELAY=0 \
    PATH="$MOCK_BIN_DIR:$PATH" \
    bash "$TARGET" "$json_args" 2>"$TEST_DIR/last_stderr"
  ) || rc=$?
  LAST_OUTPUT="$output"
  LAST_RC=$rc
  LAST_GH_LOG="$mock_log"
  LAST_STDERR="$TEST_DIR/last_stderr"
  return 0
}

# Helper: extract JSON field from LAST_OUTPUT
json_field() {
  printf '%s\n' "$LAST_OUTPUT" | jq -r "$1"
}

# Helper: create a body file for testing
create_body_file() {
  local content="${1:-Test body content}"
  local tmpfile="$TEST_DIR/body_$$_$RANDOM.md"
  printf '%s' "$content" > "$tmpfile"
  echo "$tmpfile"
}

echo "=== create-issue-with-projects.sh tests ==="
echo ""

# --------------------------------------------------------------------------
# TC-001: No arguments → exit 1
# --------------------------------------------------------------------------
echo "TC-001: No arguments → exit 1"
rc=0
output=$(bash "$TARGET" 2>/dev/null) || rc=$?
if [ $rc -ne 0 ]; then
  pass "No arguments → non-zero exit (rc=$rc)"
else
  fail "Expected non-zero exit, got 0"
fi

# --------------------------------------------------------------------------
# TC-002: Empty title → exit 1 + stderr/warning validation
# --------------------------------------------------------------------------
echo "TC-002: Empty title → exit 1 + stderr/warning validation"
run_script '{"issue": {"title": ""}, "projects": {"enabled": false}}'
if [ "$LAST_RC" -ne 0 ]; then
  stderr_content=$(cat "$LAST_STDERR" 2>/dev/null)
  warn_msg=$(json_field '.warnings[0] // empty')
  if echo "$warn_msg" | grep -qi "title"; then
    if [ -z "$stderr_content" ]; then
      pass "Empty title → exit $LAST_RC, warning='$warn_msg', stderr empty (JSON-only error output)"
    else
      fail "Unexpected stderr on validation error: '$stderr_content'"
    fi
  else
    fail "Expected warning about title, got '$warn_msg'"
  fi
else
  fail "Expected non-zero exit for empty title"
fi

# --------------------------------------------------------------------------
# TC-003: Missing body_file → exit 1 + stderr/warning validation
# --------------------------------------------------------------------------
echo "TC-003: Non-existent body_file → exit 1 + stderr/warning validation"
run_script '{"issue": {"title": "Test", "body_file": "/nonexistent/path/body.md"}, "projects": {"enabled": false}}'
if [ "$LAST_RC" -ne 0 ]; then
  stderr_content=$(cat "$LAST_STDERR" 2>/dev/null)
  warn_msg=$(json_field '.warnings[0] // empty')
  # Note: dots in "body.file" and "not.found" act as regex wildcards,
  # matching any separator (space, dot, etc.) — acceptable for this check
  if echo "$warn_msg" | grep -qi "body.file\|not.found"; then
    if [ -z "$stderr_content" ]; then
      pass "Non-existent body_file → exit $LAST_RC, warning='$warn_msg', stderr empty (JSON-only error output)"
    else
      fail "Unexpected stderr on validation error: '$stderr_content'"
    fi
  else
    fail "Expected warning about body file, got '$warn_msg'"
  fi
else
  fail "Expected non-zero exit for non-existent body_file"
fi

# --------------------------------------------------------------------------
# TC-004: Successful Issue creation (projects disabled)
# --------------------------------------------------------------------------
echo "TC-004: Successful Issue creation (projects disabled)"
body_file=$(create_body_file "Test issue body")
run_script "$(jq -n --arg bf "$body_file" '{
  issue: {title: "Test Issue", body_file: $bf},
  projects: {enabled: false}
}')"
if [ "$LAST_RC" -eq 0 ]; then
  url=$(json_field '.issue_url')
  num=$(json_field '.issue_number')
  reg=$(json_field '.project_registration')
  if [ "$num" = "42" ] && [ "$reg" = "skipped" ]; then
    pass "Issue created: #$num, registration=$reg"
  else
    fail "Unexpected output: num=$num, reg=$reg"
  fi
else
  fail "Expected exit 0, got $LAST_RC"
fi

# --------------------------------------------------------------------------
# TC-005: Successful Issue creation with Projects integration
# --------------------------------------------------------------------------
echo "TC-005: Successful Issue creation with full Projects integration"
body_file=$(create_body_file "Test with projects")
run_script "$(jq -n --arg bf "$body_file" '{
  issue: {title: "Test with Projects", body_file: $bf},
  projects: {
    enabled: true,
    project_number: 2,
    owner: "test-owner",
    status: "Todo",
    priority: "High",
    complexity: "M"
  },
  options: {source: "interactive"}
}')"
if [ "$LAST_RC" -eq 0 ]; then
  reg=$(json_field '.project_registration')
  pid=$(json_field '.project_id')
  iid=$(json_field '.item_id')
  if [ "$reg" = "ok" ] && [ -n "$pid" ] && [ -n "$iid" ]; then
    pass "Full Projects integration: reg=$reg, project_id=$pid, item_id=$iid"
  else
    fail "Unexpected: reg=$reg, pid=$pid, iid=$iid"
  fi
else
  fail "Expected exit 0, got $LAST_RC"
fi

# --------------------------------------------------------------------------
# TC-006: Issue create failure + stderr/warning validation
# --------------------------------------------------------------------------
echo "TC-006: gh issue create failure → exit 1 + warning validation"
body_file=$(create_body_file "Test fail")
run_script "$(jq -n --arg bf "$body_file" '{
  issue: {title: "Will Fail", body_file: $bf},
  projects: {enabled: false}
}')" "issue_create_fail"
if [ "$LAST_RC" -ne 0 ]; then
  stderr_content=$(cat "$LAST_STDERR" 2>/dev/null)
  reg=$(json_field '.project_registration')
  warn_msg=$(json_field '.warnings[0] // empty')
  if [ "$reg" = "failed" ]; then
    if [ -n "$warn_msg" ] && echo "$warn_msg" | grep -qi "failed"; then
      if [ -z "$stderr_content" ]; then
        pass "Issue create failure: exit=$LAST_RC, reg=$reg, warning='$warn_msg', stderr empty (JSON-only error output)"
      else
        fail "Unexpected stderr on issue create failure: '$stderr_content'"
      fi
    else
      fail "Expected 'failed' in warning message, got '$warn_msg'"
    fi
  else
    fail "Expected reg=failed, got $reg"
  fi
else
  fail "Expected non-zero exit for issue create failure"
fi

# --------------------------------------------------------------------------
# TC-007: Project item-add failure (non-blocking)
# --------------------------------------------------------------------------
echo "TC-007: gh project item-add failure (non_blocking=true) → exit 0"
body_file=$(create_body_file "Test project add fail")
run_script "$(jq -n --arg bf "$body_file" '{
  issue: {title: "Add Fail", body_file: $bf},
  projects: {
    enabled: true,
    project_number: 2,
    owner: "test-owner"
  },
  options: {non_blocking_projects: true}
}')" "project_add_fail"
if [ "$LAST_RC" -eq 0 ]; then
  reg=$(json_field '.project_registration')
  warns=$(json_field '.warnings | length')
  if [ "$reg" = "failed" ] && [ "$warns" -gt 0 ]; then
    pass "Project add fail (non-blocking): exit=0, reg=$reg, warnings=$warns"
  else
    fail "Unexpected: reg=$reg, warns=$warns"
  fi
else
  fail "Expected exit 0 for non-blocking failure, got $LAST_RC"
fi

# --------------------------------------------------------------------------
# TC-008: GraphQL query failure → partial
# --------------------------------------------------------------------------
echo "TC-008: GraphQL query failure → exit 0 with partial registration"
body_file=$(create_body_file "Test graphql fail")
run_script "$(jq -n --arg bf "$body_file" '{
  issue: {title: "GQL Fail", body_file: $bf},
  projects: {
    enabled: true,
    project_number: 2,
    owner: "test-owner"
  },
  options: {non_blocking_projects: true}
}')" "graphql_fail"
if [ "$LAST_RC" -eq 0 ]; then
  reg=$(json_field '.project_registration')
  if [ "$reg" = "partial" ]; then
    pass "GraphQL failure: exit=0, reg=$reg"
  else
    fail "Expected reg=partial, got $reg"
  fi
else
  fail "Expected exit 0, got $LAST_RC"
fi

# --------------------------------------------------------------------------
# TC-009: GraphQL items empty but item-add --format json provides ITEM_ID → ok
# --------------------------------------------------------------------------
echo "TC-009: GraphQL items empty, ITEM_ID from item-add → exit 0 with ok registration"
body_file=$(create_body_file "Test no item in gql")
run_script "$(jq -n --arg bf "$body_file" '{
  issue: {title: "No Item GQL", body_file: $bf},
  projects: {
    enabled: true,
    project_number: 2,
    owner: "test-owner",
    status: "Todo"
  },
  options: {non_blocking_projects: true}
}')" "no_item_id"
if [ "$LAST_RC" -eq 0 ]; then
  reg=$(json_field '.project_registration')
  iid=$(json_field '.item_id')
  # PVTI_mock456 corresponds to MOCK_ITEM_ID defined in mock-gh.sh
  if [ "$reg" = "ok" ] && [ -n "$iid" ] && [ "$iid" = "PVTI_mock456" ]; then
    pass "ITEM_ID from item-add: exit=0, reg=$reg, item_id=$iid"
  else
    fail "Expected reg=ok with item_id from item-add, got reg=$reg, iid=$iid"
  fi
else
  fail "Expected exit 0, got $LAST_RC"
fi

# --------------------------------------------------------------------------
# TC-009b: item-add returns no JSON AND GraphQL items empty → partial
# --------------------------------------------------------------------------
echo "TC-009b: item-add no JSON + GraphQL items empty → partial"
body_file=$(create_body_file "Test no item anywhere")
run_script "$(jq -n --arg bf "$body_file" '{
  issue: {title: "No Item Anywhere", body_file: $bf},
  projects: {
    enabled: true,
    project_number: 2,
    owner: "test-owner"
  },
  options: {non_blocking_projects: true}
}')" "no_item_id_no_json"
if [ "$LAST_RC" -eq 0 ]; then
  reg=$(json_field '.project_registration')
  iid=$(json_field '.item_id')
  # Cover both jq -r outputs: "null" (JSON null) and "" (missing key)
  if [ "$reg" = "partial" ] && { [ -z "$iid" ] || [ "$iid" = "null" ] || [ "$iid" = "" ]; }; then
    pass "No item ID anywhere: exit=0, reg=$reg, item_id empty"
  else
    fail "Expected reg=partial with empty item_id, got reg=$reg, iid=$iid"
  fi
else
  fail "Expected exit 0, got $LAST_RC"
fi

# --------------------------------------------------------------------------
# TC-010: Labels and assignees are passed to gh issue create
# --------------------------------------------------------------------------
echo "TC-010: Labels and assignees passed to gh CLI"
body_file=$(create_body_file "Test labels")
run_script "$(jq -n --arg bf "$body_file" '{
  issue: {
    title: "With Labels",
    body_file: $bf,
    labels: ["bug", "urgent"],
    assignees: ["user1"]
  },
  projects: {enabled: false}
}')"
if [ "$LAST_RC" -eq 0 ]; then
  if grep -q -- "--label bug" "$LAST_GH_LOG" && \
     grep -q -- "--label urgent" "$LAST_GH_LOG" && \
     grep -q -- "--assignee user1" "$LAST_GH_LOG"; then
    pass "Labels and assignees included in gh issue create call"
  else
    fail "Missing labels/assignees in gh call log: $(cat "$LAST_GH_LOG")"
  fi
else
  fail "Expected exit 0, got $LAST_RC"
fi

# --------------------------------------------------------------------------
# TC-011: Projects disabled when project_number is 0
# --------------------------------------------------------------------------
echo "TC-011: project_number=0 → Projects skipped"
body_file=$(create_body_file "Test skip projects")
run_script "$(jq -n --arg bf "$body_file" '{
  issue: {title: "Skip Projects", body_file: $bf},
  projects: {enabled: true, project_number: 0, owner: "test-owner"}
}')"
if [ "$LAST_RC" -eq 0 ]; then
  reg=$(json_field '.project_registration')
  if [ "$reg" = "skipped" ]; then
    pass "project_number=0 → reg=skipped"
  else
    fail "Expected reg=skipped, got $reg"
  fi
else
  fail "Expected exit 0, got $LAST_RC"
fi

# --------------------------------------------------------------------------
# TC-012: Projects disabled when owner is empty
# --------------------------------------------------------------------------
echo "TC-012: Empty owner → Projects skipped"
body_file=$(create_body_file "Test empty owner")
run_script "$(jq -n --arg bf "$body_file" '{
  issue: {title: "Empty Owner", body_file: $bf},
  projects: {enabled: true, project_number: 2, owner: ""}
}')"
if [ "$LAST_RC" -eq 0 ]; then
  reg=$(json_field '.project_registration')
  if [ "$reg" = "skipped" ]; then
    pass "Empty owner → reg=skipped"
  else
    fail "Expected reg=skipped, got $reg"
  fi
else
  fail "Expected exit 0, got $LAST_RC"
fi

# --------------------------------------------------------------------------
# TC-013: Field edit failure → partial (non-blocking)
# --------------------------------------------------------------------------
echo "TC-013: Field edit failure → partial registration"
body_file=$(create_body_file "Test field fail")
run_script "$(jq -n --arg bf "$body_file" '{
  issue: {title: "Field Fail", body_file: $bf},
  projects: {
    enabled: true,
    project_number: 2,
    owner: "test-owner",
    status: "Todo",
    priority: "High"
  },
  options: {non_blocking_projects: true}
}')" "field_edit_fail"
if [ "$LAST_RC" -eq 0 ]; then
  reg=$(json_field '.project_registration')
  if [ "$reg" = "partial" ]; then
    pass "Field edit failure: exit=0, reg=$reg"
  else
    fail "Expected reg=partial, got $reg"
  fi
else
  fail "Expected exit 0, got $LAST_RC"
fi

# --------------------------------------------------------------------------
# TC-014: Organization owner type detection
# --------------------------------------------------------------------------
echo "TC-014: Organization owner → correct GraphQL root"
body_file=$(create_body_file "Test org")
run_script "$(jq -n --arg bf "$body_file" '{
  issue: {title: "Org Test", body_file: $bf},
  projects: {
    enabled: true,
    project_number: 2,
    owner: "test-org",
    status: "Todo"
  }
}')" "org_owner"
if [ "$LAST_RC" -eq 0 ]; then
  reg=$(json_field '.project_registration')
  if [ "$reg" = "ok" ]; then
    # Verify GraphQL query used organization(login:) root
    if grep -q 'organization(login:' "$LAST_GH_LOG" 2>/dev/null; then
      pass "Organization owner: exit=0, reg=$reg, GraphQL root=organization"
    else
      fail "Expected organization(login:) in GraphQL query, got: $(cat "$LAST_GH_LOG")"
    fi
  else
    fail "Expected reg=ok, got $reg"
  fi
else
  fail "Expected exit 0, got $LAST_RC"
fi

# --------------------------------------------------------------------------
# TC-015: Invalid JSON argument → exit 1
# --------------------------------------------------------------------------
echo "TC-015: Invalid JSON argument → exit 1"
rc=0
output=$(PATH="$MOCK_BIN_DIR:$PATH" bash "$TARGET" "NOT-VALID-JSON" 2>/dev/null) || rc=$?
if [ $rc -ne 0 ]; then
  pass "Invalid JSON → exit $rc"
else
  fail "Expected non-zero exit for invalid JSON"
fi

# --------------------------------------------------------------------------
# TC-016: No body_file (optional) → Issue created without body
# --------------------------------------------------------------------------
echo "TC-016: No body_file → Issue created without --body-file flag"
run_script '{"issue": {"title": "No Body"}, "projects": {"enabled": false}}'
if [ "$LAST_RC" -eq 0 ]; then
  num=$(json_field '.issue_number')
  if [ "$num" = "42" ]; then
    # Verify --body-file was NOT passed
    if grep -q -- "--body-file" "$LAST_GH_LOG" 2>/dev/null; then
      fail "Unexpected --body-file flag in gh call"
    else
      pass "No body_file → Issue created without body (num=$num)"
    fi
  else
    fail "Unexpected issue_number: $num"
  fi
else
  fail "Expected exit 0, got $LAST_RC"
fi

# --------------------------------------------------------------------------
# TC-017: Warnings array in output JSON
# --------------------------------------------------------------------------
echo "TC-017: Warnings array populated on partial failure"
body_file=$(create_body_file "Test warnings")
run_script "$(jq -n --arg bf "$body_file" '{
  issue: {title: "Warn Test", body_file: $bf},
  projects: {
    enabled: true,
    project_number: 2,
    owner: "test-owner"
  },
  options: {non_blocking_projects: true}
}')" "project_add_fail"
if [ "$LAST_RC" -eq 0 ]; then
  warn_count=$(json_field '.warnings | length')
  first_warn=$(json_field '.warnings[0] // empty')
  if [ "$warn_count" -gt 0 ] && [ -n "$first_warn" ]; then
    pass "Warnings populated: count=$warn_count"
  else
    fail "Expected warnings, got count=$warn_count"
  fi
else
  fail "Expected exit 0, got $LAST_RC"
fi

# --------------------------------------------------------------------------
# TC-018: Default values for optional fields
# --------------------------------------------------------------------------
echo "TC-018: Default values for optional fields"
body_file=$(create_body_file "Test defaults")
run_script "$(jq -n --arg bf "$body_file" '{
  issue: {title: "Defaults Test", body_file: $bf},
  projects: {
    enabled: true,
    project_number: 2,
    owner: "test-owner"
  }
}')"
if [ "$LAST_RC" -eq 0 ]; then
  reg=$(json_field '.project_registration')
  # Default status=Todo should be set, iteration mode=none
  if [ "$reg" = "ok" ]; then
    # Verify default Status=Todo was set via project item-edit
    if grep -q "item-edit" "$LAST_GH_LOG" 2>/dev/null && grep -q -- "--single-select-option-id" "$LAST_GH_LOG" 2>/dev/null; then
      pass "Default values applied: reg=$reg, Status field edit confirmed"
    else
      fail "Expected item-edit for default Status=Todo in gh log"
    fi
  else
    fail "Expected reg=ok with defaults, got $reg"
  fi
else
  fail "Expected exit 0, got $LAST_RC"
fi

# --------------------------------------------------------------------------
# TC-019: Iteration auto-assign success (mode=auto)
# --------------------------------------------------------------------------
echo "TC-019: Iteration auto-assign (mode=auto) → success"
body_file=$(create_body_file "Test iteration")
run_script "$(jq -n --arg bf "$body_file" '{
  issue: {title: "Iteration Test", body_file: $bf},
  projects: {
    enabled: true,
    project_number: 2,
    owner: "test-owner",
    status: "Todo",
    iteration: {mode: "auto", field_name: "Sprint"}
  }
}')" "iteration_success"
if [ "$LAST_RC" -eq 0 ]; then
  reg=$(json_field '.project_registration')
  if [ "$reg" = "ok" ]; then
    pass "Iteration auto-assign: reg=$reg"
  else
    fail "Expected reg=ok, got $reg"
  fi
else
  fail "Expected exit 0, got $LAST_RC"
fi

# --------------------------------------------------------------------------
# TC-020: Iteration field not found → warning
# --------------------------------------------------------------------------
echo "TC-020: Iteration field missing → warning"
body_file=$(create_body_file "Test iter missing")
run_script "$(jq -n --arg bf "$body_file" '{
  issue: {title: "Iter Missing", body_file: $bf},
  projects: {
    enabled: true,
    project_number: 2,
    owner: "test-owner",
    iteration: {mode: "auto", field_name: "Sprint"}
  }
}')"
if [ "$LAST_RC" -eq 0 ]; then
  warns=$(json_field '.warnings | length')
  if [ "$warns" -gt 0 ]; then
    pass "Iteration field missing: warns=$warns"
  else
    fail "Expected warnings for missing iteration field"
  fi
else
  fail "Expected exit 0, got $LAST_RC"
fi

# --------------------------------------------------------------------------
# TC-021: No current iteration → warning
# --------------------------------------------------------------------------
echo "TC-021: No current iteration (all future) → warning"
body_file=$(create_body_file "Test no current iter")
run_script "$(jq -n --arg bf "$body_file" '{
  issue: {title: "No Current Iter", body_file: $bf},
  projects: {
    enabled: true,
    project_number: 2,
    owner: "test-owner",
    iteration: {mode: "auto", field_name: "Sprint"}
  }
}')" "no_current_iteration"
if [ "$LAST_RC" -eq 0 ]; then
  warns=$(json_field '.warnings | length')
  if [ "$warns" -gt 0 ]; then
    pass "No current iteration: warns=$warns"
  else
    fail "Expected warnings for no current iteration"
  fi
else
  fail "Expected exit 0, got $LAST_RC"
fi

# --------------------------------------------------------------------------
# TC-022: non_blocking_projects=false + item-add failure → exit 1
# --------------------------------------------------------------------------
echo "TC-022: non_blocking_projects=false + item-add failure → exit 1"
body_file=$(create_body_file "Test blocking fail")
run_script "$(jq -n --arg bf "$body_file" '{
  issue: {title: "Blocking Fail", body_file: $bf},
  projects: {
    enabled: true,
    project_number: 2,
    owner: "test-owner"
  },
  options: {non_blocking_projects: false}
}')" "project_add_fail"
if [ "$LAST_RC" -ne 0 ]; then
  reg=$(json_field '.project_registration')
  if [ "$reg" = "failed" ]; then
    pass "non_blocking=false + add fail → exit $LAST_RC, reg=$reg"
  else
    fail "Expected reg=failed, got $reg"
  fi
else
  fail "Expected non-zero exit for blocking project failure"
fi

# --------------------------------------------------------------------------
# TC-023: Non-existent field option → warning + partial
# --------------------------------------------------------------------------
echo "TC-023: Non-existent field option → partial"
body_file=$(create_body_file "Test bad option")
run_script "$(jq -n --arg bf "$body_file" '{
  issue: {title: "Bad Option", body_file: $bf},
  projects: {
    enabled: true,
    project_number: 2,
    owner: "test-owner",
    status: "NonExistentStatus"
  }
}')"
if [ "$LAST_RC" -eq 0 ]; then
  reg=$(json_field '.project_registration')
  if [ "$reg" = "partial" ]; then
    pass "Non-existent option → reg=$reg"
  else
    fail "Expected reg=partial, got $reg"
  fi
else
  fail "Expected exit 0, got $LAST_RC"
fi

# --------------------------------------------------------------------------
# TC-024: Project ID not found (null) → partial
# --------------------------------------------------------------------------
echo "TC-024: Project ID not found → partial"
body_file=$(create_body_file "Test no pid")
run_script "$(jq -n --arg bf "$body_file" '{
  issue: {title: "No PID", body_file: $bf},
  projects: {
    enabled: true,
    project_number: 2,
    owner: "test-owner"
  },
  options: {non_blocking_projects: true}
}')" "no_project_id"
if [ "$LAST_RC" -eq 0 ]; then
  reg=$(json_field '.project_registration')
  if [ "$reg" = "partial" ]; then
    pass "No project ID → reg=$reg"
  else
    fail "Expected reg=partial, got $reg"
  fi
else
  fail "Expected exit 0, got $LAST_RC"
fi

# --------------------------------------------------------------------------
# TC-025: Issue URL parse failure → exit 1
# --------------------------------------------------------------------------
echo "TC-025: Issue URL parse failure (no trailing number) → exit 1"
body_file=$(create_body_file "Test url parse fail")
run_script "$(jq -n --arg bf "$body_file" '{
  issue: {title: "URL Parse Fail", body_file: $bf},
  projects: {enabled: false}
}')" "url_parse_fail"
if [ "$LAST_RC" -ne 0 ]; then
  if [ -n "$LAST_OUTPUT" ]; then
    warn_msg=$(json_field '.warnings[0] // empty')
  else
    warn_msg=""
  fi
  if echo "$warn_msg" | grep -qi "issue number"; then
    pass "URL parse failure: exit=$LAST_RC, warning='$warn_msg'"
  else
    fail "Expected warning about issue number extraction, got '$warn_msg'"
  fi
else
  fail "Expected non-zero exit for URL parse failure"
fi

# --------------------------------------------------------------------------
# TC-026: Invalid RETRY_DELAY → warning + fallback to default 1
# --------------------------------------------------------------------------
echo "TC-026: Invalid RETRY_DELAY → warning + successful execution"
body_file=$(create_body_file "Test retry delay validation")
mock_log="$TEST_DIR/gh_log_$$_$RANDOM"
rc=0
output=$(
  MOCK_GH_SCENARIO="success" \
  MOCK_ISSUE_NUMBER="42" \
  MOCK_GH_LOG="$mock_log" \
  RETRY_DELAY="abc" \
  PATH="$MOCK_BIN_DIR:$PATH" \
  bash "$TARGET" "$(jq -n --arg bf "$body_file" '{
    issue: {title: "Retry Delay Test", body_file: $bf},
    projects: {enabled: false}
  }')" 2>"$TEST_DIR/last_stderr"
) || rc=$?
LAST_OUTPUT="$output"
LAST_RC=$rc
if [ "$LAST_RC" -eq 0 ]; then
  warns=$(json_field '.warnings | length')
  first_warn=$(json_field '.warnings[0] // empty')
  if [ "$warns" -gt 0 ] && echo "$first_warn" | grep -q "RETRY_DELAY"; then
    pass "Invalid RETRY_DELAY → warning generated: '$first_warn'"
  else
    fail "Expected RETRY_DELAY warning, got warns=$warns, first='$first_warn'"
  fi
else
  fail "Expected exit 0 with fallback, got $LAST_RC"
fi

# --------------------------------------------------------------------------
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ $FAIL -gt 0 ]; then
  exit 1
fi
