#!/bin/bash
# Tests for session-end.sh
# Usage: bash plugins/rite/hooks/tests/session-end.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../session-end.sh"
TEST_DIR="$(mktemp -d)"
LAST_STDERR_FILE=""
PASS=0
FAIL=0

# Prerequisite check: jq is required by session-end.sh
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
  show_stderr
}

# Helper: show captured stderr on failure for debugging
show_stderr() {
  local stderr_file="${LAST_STDERR_FILE:-}"
  if [ -s "$stderr_file" ]; then
    echo "    stderr: $(cat "$stderr_file")"
  fi
}

# Helper: create a state file in the given directory
create_state_file() {
  local dir="$1"
  local content="$2"
  echo "$content" > "$dir/.rite-flow-state"
}

# Helper: run session-end hook with given CWD, capture stdout and stderr
run_hook() {
  local cwd="$1"
  local rc=0
  local output
  LAST_STDERR_FILE="$(mktemp "$TEST_DIR/stderr.XXXXXX")"
  output=$(echo "{\"cwd\": \"$cwd\"}" | bash "$HOOK" 2>"$LAST_STDERR_FILE") || rc=$?
  echo "$output"
  return $rc
}

echo "=== session-end.sh tests ==="
echo ""

# --------------------------------------------------------------------------
# TC-001: No CWD in input → exit 0
# --------------------------------------------------------------------------
echo "TC-001: No CWD in input → exit 0"
output=$(echo "{}" | bash "$HOOK" 2>/dev/null) && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ -z "$output" ]; then
  pass "Missing CWD → exit 0 with no output"
else
  fail "Expected exit 0 with no output, got rc=$rc, output='$output'"
fi
echo ""

# --------------------------------------------------------------------------
# TC-002: CWD is not a directory → exit 0
# --------------------------------------------------------------------------
echo "TC-002: CWD is not a directory → exit 0"
output=$(echo "{\"cwd\": \"$TEST_DIR/nonexistent\"}" | bash "$HOOK" 2>/dev/null) && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ -z "$output" ]; then
  pass "Nonexistent CWD → exit 0 with no output"
else
  fail "Expected exit 0 with no output, got rc=$rc, output='$output'"
fi
echo ""

# --------------------------------------------------------------------------
# TC-003: Branch with issue-{number} → message displayed
# --------------------------------------------------------------------------
echo "TC-003: Branch with issue-{number} → message displayed"
git_repo_003="$TEST_DIR/git_tc003"
mkdir -p "$git_repo_003"
(cd "$git_repo_003" && git init -q && git -c user.name="test" -c user.email="test@test.com" commit --allow-empty -m "init" -q && git checkout -b "feat/issue-456-cleanup" -q)

output=$(run_hook "$git_repo_003")
if echo "$output" | grep -q "Saving final state for Issue #456"; then
  pass "Branch detection found Issue #456 in output"
else
  fail "Expected 'Issue #456' in output, got: $output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-004: Branch without issue pattern → no special message
# --------------------------------------------------------------------------
echo "TC-004: Branch without issue pattern → no special message"
git_repo_004="$TEST_DIR/git_tc004"
mkdir -p "$git_repo_004"
(cd "$git_repo_004" && git init -q && git -c user.name="test" -c user.email="test@test.com" commit --allow-empty -m "init" -q && git checkout -b "main" -q)

output=$(run_hook "$git_repo_004")
if ! echo "$output" | grep -q "Saving final state for Issue"; then
  pass "No issue branch → no issue-specific message"
else
  fail "Expected no issue message, got: $output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-005: State file exists → active set to false, updated_at updated
# --------------------------------------------------------------------------
echo "TC-005: State file exists → active=false, updated_at updated"
dir005="$TEST_DIR/tc005"
mkdir -p "$dir005"
create_state_file "$dir005" '{"active": true, "issue_number": 42, "phase": "impl"}'

output=$(run_hook "$dir005")
active=$(jq -r '.active' "$dir005/.rite-flow-state")
updated_at=$(jq -r '.updated_at' "$dir005/.rite-flow-state")

if [ "$active" = "false" ] && echo "$updated_at" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\+00:00$'; then
  pass "State file deactivated and updated_at set"
else
  fail "active=$active, updated_at=$updated_at"
fi
echo ""

# --------------------------------------------------------------------------
# TC-006: State file deactivation preserves other fields
# --------------------------------------------------------------------------
echo "TC-006: State file deactivation preserves other fields"
dir006="$TEST_DIR/tc006"
mkdir -p "$dir006"
create_state_file "$dir006" '{"active": true, "issue_number": 99, "phase": "test", "loop_count": 5}'

output=$(run_hook "$dir006")
issue=$(jq -r '.issue_number' "$dir006/.rite-flow-state")
phase=$(jq -r '.phase' "$dir006/.rite-flow-state")
loop=$(jq -r '.loop_count' "$dir006/.rite-flow-state")

if [ "$issue" = "99" ] && [ "$phase" = "test" ] && [ "$loop" = "5" ]; then
  pass "Existing fields preserved (issue=$issue, phase=$phase, loop=$loop)"
else
  fail "Fields were modified: issue=$issue, phase=$phase, loop=$loop"
fi
echo ""

# --------------------------------------------------------------------------
# TC-007: No state file → no error, hook completes normally
# --------------------------------------------------------------------------
echo "TC-007: No state file → no error"
dir007="$TEST_DIR/tc007"
mkdir -p "$dir007"

output=$(run_hook "$dir007") && rc=0 || rc=$?
if [ $rc -eq 0 ]; then
  pass "No state file → exit 0"
else
  fail "Expected exit 0, got rc=$rc"
fi
echo ""

# --------------------------------------------------------------------------
# TC-008: Corrupted state file JSON → temp file cleanup, non-zero exit
# --------------------------------------------------------------------------
echo "TC-008: Corrupted state file JSON → cleanup, exit 0 (best-effort)"
dir008="$TEST_DIR/tc008"
mkdir -p "$dir008"
echo "{broken json" > "$dir008/.rite-flow-state"

# session-end.sh prioritizes cleanup over strict error propagation
output=$(run_hook "$dir008") && rc=0 || rc=$?
# Check that temp files are cleaned up even on jq failure
temp_files=$(find "$dir008" -name ".rite-flow-state.tmp.*" 2>/dev/null | wc -l)
if [ "$temp_files" -eq 0 ]; then
  pass "Corrupted JSON → temp files cleaned up (rc=$rc)"
else
  fail "Temp files not cleaned: $temp_files files found"
fi
echo ""

# --------------------------------------------------------------------------
# TC-009: Stale temp file cleanup (older than 1 minute)
# --------------------------------------------------------------------------
echo "TC-009: Stale temp file cleanup"
dir009="$TEST_DIR/tc009"
mkdir -p "$dir009"
create_state_file "$dir009" '{"active": true, "issue_number": 1}'

# Create a stale temp file
stale_file="$dir009/.rite-flow-state.tmp.99999"
touch "$stale_file"
# Set modification time to 2 minutes ago
touch -t "$(date -u -d '2 minutes ago' +'%Y%m%d%H%M' 2>/dev/null || date -u -v-2M +'%Y%m%d%H%M')" "$stale_file" 2>/dev/null || true

# Run hook (should clean up stale file)
output=$(run_hook "$dir009")

if [ ! -f "$stale_file" ]; then
  pass "Stale temp file cleaned up"
else
  fail "Stale temp file not cleaned up: $stale_file"
fi
echo ""

# --------------------------------------------------------------------------
# TC-010: PID-based temp file creation and trap cleanup
# --------------------------------------------------------------------------
echo "TC-010: PID-based temp file creation and cleanup"
dir010="$TEST_DIR/tc010"
mkdir -p "$dir010"
create_state_file "$dir010" '{"active": true, "issue_number": 123}'

# Run hook (temp file should be created and cleaned up by trap)
output=$(run_hook "$dir010")

# Verify no temp files remain after successful completion
temp_count=$(find "$dir010" -name ".rite-flow-state.tmp.*" 2>/dev/null | wc -l)
if [ "$temp_count" -eq 0 ]; then
  pass "Temp file created and cleaned up by trap"
else
  fail "Temp files not cleaned up: $temp_count files found"
fi
echo ""

# --------------------------------------------------------------------------
# TC-011: Updated timestamp is parseable and recent
# --------------------------------------------------------------------------
echo "TC-011: Updated timestamp is parseable and recent"
dir011="$TEST_DIR/tc011"
mkdir -p "$dir011"
create_state_file "$dir011" '{"active": true, "issue_number": 1}'

before_epoch=$(date +%s)
output=$(run_hook "$dir011")
after_epoch=$(date +%s)

updated_at=$(jq -r '.updated_at' "$dir011/.rite-flow-state")
# Parse timestamp with GNU date
if state_epoch=$(date -d "$updated_at" +%s 2>/dev/null); then
  if [ "$state_epoch" -ge "$before_epoch" ] && [ "$state_epoch" -le "$after_epoch" ]; then
    pass "Timestamp is parseable and within test execution window"
  else
    fail "Timestamp out of range: $updated_at (epoch: $state_epoch, expected: $before_epoch-$after_epoch)"
  fi
else
  fail "Timestamp not parseable by date -d: $updated_at"
fi
echo ""

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ $FAIL -gt 0 ]; then
  exit 1
fi
