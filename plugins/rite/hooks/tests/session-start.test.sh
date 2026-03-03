#!/bin/bash
# Tests for session-start.sh
# Usage: bash plugins/rite/hooks/tests/session-start.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../session-start.sh"
TEST_DIR="$(mktemp -d)"
LAST_STDERR_FILE=""
PASS=0
FAIL=0

# Prerequisite check: jq is required by session-start.sh
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

# Helper: run session-start hook with given CWD, capture stdout and stderr
run_hook() {
  local cwd="$1"
  local rc=0
  local output
  LAST_STDERR_FILE="$(mktemp "$TEST_DIR/stderr.XXXXXX")"
  output=$(echo "{\"cwd\": \"$cwd\"}" | bash "$HOOK" 2>"$LAST_STDERR_FILE") || rc=$?
  echo "$output"
  return $rc
}

# Helper: run session-start hook with given CWD and source field
run_hook_with_source() {
  local cwd="$1"
  local source="$2"
  local rc=0
  local output
  LAST_STDERR_FILE="$(mktemp "$TEST_DIR/stderr.XXXXXX")"
  output=$(echo "{\"cwd\": \"$cwd\", \"source\": \"$source\"}" | bash "$HOOK" 2>"$LAST_STDERR_FILE") || rc=$?
  echo "$output"
  return $rc
}

echo "=== session-start.sh tests ==="
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
# TC-003: No state file + issue branch + source=compact → silent (no message) (#772)
# Note: Tests compact source path. TC-025 tests the same scenario with explicit startup source.
# --------------------------------------------------------------------------
echo "TC-003: No state file + issue branch + source=compact → silent (no message)"
git_repo_003="$TEST_DIR/git_tc003"
mkdir -p "$git_repo_003"
(cd "$git_repo_003" && git init -q && git -c user.name="test" -c user.email="test@test.com" commit --allow-empty -m "init" -q && git checkout -b "feat/issue-123-test-feature" -q)

output=$(run_hook_with_source "$git_repo_003" "compact")
if [ -z "$output" ]; then
  pass "No state file + issue branch + compact → no output (branch detection noise removed)"
else
  fail "Expected no output, got: $output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-004: No state file and no issue branch → exit 0 silently
# --------------------------------------------------------------------------
echo "TC-004: No state file and no issue branch → exit 0 silently"
git_repo_004="$TEST_DIR/git_tc004"
mkdir -p "$git_repo_004"
(cd "$git_repo_004" && git init -q && git -c user.name="test" -c user.email="test@test.com" commit --allow-empty -m "init" -q)

output=$(run_hook "$git_repo_004")
if [ -z "$output" ]; then
  pass "No state file, no issue branch → no output"
else
  fail "Expected no output, got: $output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-005: State file exists but active=false → exit 0 silently
# --------------------------------------------------------------------------
echo "TC-005: State file exists but active=false → exit 0 silently"
dir005="$TEST_DIR/tc005"
mkdir -p "$dir005"
create_state_file "$dir005" '{"active": false, "issue_number": 42}'

output=$(run_hook "$dir005")
if [ -z "$output" ]; then
  pass "active=false → no output"
else
  fail "Expected no output, got: $output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-006: State file with active=true + source=compact → re-inject message
# --------------------------------------------------------------------------
echo "TC-006: State file with active=true + source=compact → re-inject message"
dir006="$TEST_DIR/tc006"
mkdir -p "$dir006"
create_state_file "$dir006" '{
  "active": true,
  "issue_number": 42,
  "phase": "implementing",
  "next_action": "continue work",
  "loop_count": 3
}'

output=$(run_hook_with_source "$dir006" "compact")
if echo "$output" | grep -q "CRITICAL: Active rite workflow detected" && \
   echo "$output" | grep -q "Issue: #42" && \
   echo "$output" | grep -q "Phase: implementing" && \
   echo "$output" | grep -q "Loop: 3" && \
   echo "$output" | grep -q "Next action: continue work"; then
  pass "Active workflow re-inject message contains all expected fields"
else
  fail "Re-inject message missing expected fields, got: $output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-007: State file missing issue_number + source=compact → CRITICAL (fields shifted)
# Known limitation: when issue_number is missing, jq @tsv produces an empty first
# field that bash `read` with IFS=$'\t' strips (tab is IFS whitespace), causing
# field values to shift. The -z "$ISSUE" guard doesn't trigger because ISSUE gets
# the phase value instead of empty string.
# --------------------------------------------------------------------------
echo "TC-007: State file missing issue_number + source=compact → CRITICAL (fields shifted)"
dir007="$TEST_DIR/tc007"
mkdir -p "$dir007"
create_state_file "$dir007" '{"active": true, "phase": "test"}'

output=$(run_hook_with_source "$dir007" "compact")
if echo "$output" | grep -q "CRITICAL: Active rite workflow detected" && \
   echo "$output" | grep -q "Issue: #test"; then
  pass "Missing issue_number + compact → CRITICAL message with shifted fields (Issue: #test, known limitation)"
else
  fail "Expected CRITICAL message with 'Issue: #test' (field shift), got: $output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-008: State file with null/missing fields + source=compact → defaults to "unknown"
# --------------------------------------------------------------------------
echo "TC-008: State file with null/missing optional fields + source=compact → defaults"
dir008="$TEST_DIR/tc008"
mkdir -p "$dir008"
create_state_file "$dir008" '{"active": true, "issue_number": 99}'

output=$(run_hook_with_source "$dir008" "compact")
if echo "$output" | grep -q "Phase: unknown" && \
   echo "$output" | grep -q "Next action: unknown" && \
   echo "$output" | grep -q "Loop: 0"; then
  pass "Missing optional fields → default values (unknown, 0)"
else
  fail "Expected default values for missing fields, got: $output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-009: Stale temp file cleanup (older than 1 minute) - source=compact
# --------------------------------------------------------------------------
echo "TC-009: Stale temp file cleanup"
dir009="$TEST_DIR/tc009"
mkdir -p "$dir009"
create_state_file "$dir009" '{"active": true, "issue_number": 1}'

# Create a stale temp file (simulate old file with touch -t)
stale_file="$dir009/.rite-flow-state.tmp.12345"
touch "$stale_file"
# Set modification time to 2 minutes ago (touch -t format: YYYYMMDDhhmm)
touch -t "$(date -u -d '2 minutes ago' +'%Y%m%d%H%M' 2>/dev/null || date -u -v-2M +'%Y%m%d%H%M')" "$stale_file" 2>/dev/null || true

# Run hook with compact source (startup hits defensive reset which exits before cleanup)
output=$(run_hook_with_source "$dir009" "compact")

if [ ! -f "$stale_file" ]; then
  pass "Stale temp file cleaned up"
else
  fail "Stale temp file not cleaned up: $stale_file"
fi
echo ""

# --------------------------------------------------------------------------
# TC-010: Invalid JSON in state file → graceful fallback (exit 0)
# --------------------------------------------------------------------------
echo "TC-010: Invalid JSON in state file → exit 0 (graceful fallback)"
dir010="$TEST_DIR/tc010"
mkdir -p "$dir010"
echo "{broken json" > "$dir010/.rite-flow-state"

output=$(echo "{\"cwd\": \"$dir010\"}" | bash "$HOOK" 2>/dev/null) && rc=0 || rc=$?
if [ $rc -eq 0 ]; then
  pass "Invalid JSON → exit 0 (graceful fallback)"
else
  fail "Expected exit 0 for invalid JSON (graceful fallback), got exit $rc"
fi
echo ""

# --------------------------------------------------------------------------
# TC-011: Field extraction with process substitution and IFS=$'\t' - source=compact
# --------------------------------------------------------------------------
echo "TC-011: Field extraction with tab-delimited IFS"
dir011="$TEST_DIR/tc011"
mkdir -p "$dir011"
create_state_file "$dir011" '{
  "active": true,
  "issue_number": 77,
  "phase": "Phase with spaces",
  "next_action": "Action: with special chars",
  "loop_count": 5
}'

output=$(run_hook_with_source "$dir011" "compact")
if echo "$output" | grep -q "Issue: #77" && \
   echo "$output" | grep -q "Phase: Phase with spaces" && \
   echo "$output" | grep -q "Loop: 5" && \
   echo "$output" | grep -q "Next action: Action: with special chars"; then
  pass "Tab-delimited field extraction handles spaces and special chars"
else
  fail "Field extraction failed with spaces/special chars, got: $output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-012: source=compact + compact_state=blocked → STOP message
# --------------------------------------------------------------------------
echo "TC-012: source=compact + compact_state=blocked → STOP message"
dir012="$TEST_DIR/tc012"
mkdir -p "$dir012"
create_state_file "$dir012" '{"active": true, "issue_number": 55, "phase": "implementing"}'
echo '{"compact_state": "blocked", "active_issue": 55}' > "$dir012/.rite-compact-state"

output=$(run_hook_with_source "$dir012" "compact")
if echo "$output" | grep -q "STOP. DO NOT CONTINUE" && \
   echo "$output" | grep -q "Affected Issue: #55"; then
  pass "source=compact + blocked → STOP message with issue number"
else
  fail "Expected STOP message with issue #55, got: $output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-013: source=compact + compact_state=normal → fall through to CRITICAL
# --------------------------------------------------------------------------
echo "TC-013: source=compact + compact_state=normal → fall through to CRITICAL"
dir013="$TEST_DIR/tc013"
mkdir -p "$dir013"
create_state_file "$dir013" '{"active": true, "issue_number": 56, "phase": "reviewing"}'
echo '{"compact_state": "normal"}' > "$dir013/.rite-compact-state"

output=$(run_hook_with_source "$dir013" "compact")
if echo "$output" | grep -q "CRITICAL: Active rite workflow detected" && \
   echo "$output" | grep -q "Issue: #56"; then
  pass "source=compact + normal → normal CRITICAL message"
else
  fail "Expected normal CRITICAL message, got: $output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-014: source=compact + no .rite-compact-state → fall through to CRITICAL
# --------------------------------------------------------------------------
echo "TC-014: source=compact + no .rite-compact-state → fall through to CRITICAL"
dir014="$TEST_DIR/tc014"
mkdir -p "$dir014"
create_state_file "$dir014" '{"active": true, "issue_number": 57, "phase": "testing"}'

output=$(run_hook_with_source "$dir014" "compact")
if echo "$output" | grep -q "CRITICAL: Active rite workflow detected" && \
   echo "$output" | grep -q "Issue: #57"; then
  pass "source=compact + no compact state file → normal CRITICAL message"
else
  fail "Expected normal CRITICAL message, got: $output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-015: source=clear + compact_state=blocked → transition to resuming
# --------------------------------------------------------------------------
echo "TC-015: source=clear + compact_state=blocked → transition to resuming"
dir015="$TEST_DIR/tc015"
mkdir -p "$dir015"
create_state_file "$dir015" '{"active": true, "issue_number": 58, "phase": "implementing"}'
echo '{"compact_state": "blocked", "active_issue": 58}' > "$dir015/.rite-compact-state"

output=$(run_hook_with_source "$dir015" "clear")
COMPACT_VAL=$(jq -r '.compact_state' "$dir015/.rite-compact-state" 2>/dev/null)
if [ "$COMPACT_VAL" = "resuming" ] && \
   echo "$output" | grep -q "CRITICAL: Active rite workflow detected"; then
  pass "source=clear + blocked → compact_state transitioned to resuming + CRITICAL message"
else
  fail "Expected compact_state=resuming and CRITICAL message, got state=$COMPACT_VAL, output: $output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-016: source=startup + compact_state=blocked + active=true → defensive reset (#761)
# --------------------------------------------------------------------------
echo "TC-016: source=startup + compact_state=blocked + active=true → defensive reset"
dir016="$TEST_DIR/tc016"
mkdir -p "$dir016"
create_state_file "$dir016" '{"active": true, "issue_number": 59, "phase": "reviewing"}'
echo '{"compact_state": "blocked", "active_issue": 59}' > "$dir016/.rite-compact-state"

output=$(run_hook_with_source "$dir016" "startup")
if echo "$output" | grep -q "前回のセッション状態が残っていたためリセットしました" && \
   ! echo "$output" | grep -q "STOP. DO NOT CONTINUE"; then
  pass "source=startup + blocked → defensive reset message (not STOP, not CRITICAL)"
else
  fail "Expected defensive reset message (not STOP), got: $output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-017: source=startup + compact_state=blocked + active=false → clean compact state (#756)
# --------------------------------------------------------------------------
echo "TC-017: source=startup + compact_state=blocked + active=false → clean compact state"
dir017="$TEST_DIR/tc017"
mkdir -p "$dir017"
create_state_file "$dir017" '{"active": false, "issue_number": 60, "phase": "completed"}'
echo '{"compact_state": "blocked", "active_issue": 60}' > "$dir017/.rite-compact-state"

output=$(run_hook_with_source "$dir017" "startup") && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ ! -f "$dir017/.rite-compact-state" ]; then
  pass "source=startup + active=false → stale compact state cleaned up"
else
  fail "Expected exit 0 and .rite-compact-state removed, got rc=$rc"
fi
echo ""

# --------------------------------------------------------------------------
# TC-018: source=startup + compact_state=blocked + no flow state → clean compact state (#756)
# --------------------------------------------------------------------------
echo "TC-018: source=startup + compact_state=blocked + no flow state → clean compact state"
dir018="$TEST_DIR/tc018"
mkdir -p "$dir018"
# No .rite-flow-state at all
echo '{"compact_state": "blocked", "active_issue": 61}' > "$dir018/.rite-compact-state"

output=$(run_hook_with_source "$dir018" "startup") && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ ! -f "$dir018/.rite-compact-state" ]; then
  pass "source=startup + no flow state → stale compact state cleaned up"
else
  fail "Expected exit 0 and .rite-compact-state removed, got rc=$rc"
fi
echo ""

# --------------------------------------------------------------------------
# TC-019: source=startup + compact_state=blocked + active=true → compact state cleaned (#761, #772)
# --------------------------------------------------------------------------
echo "TC-019: source=startup + compact_state=blocked + active=true → compact state cleaned"
dir019="$TEST_DIR/tc019"
mkdir -p "$dir019"
create_state_file "$dir019" '{"active": true, "issue_number": 62, "phase": "implementing"}'
echo '{"compact_state": "blocked", "active_issue": 62}' > "$dir019/.rite-compact-state"

output=$(run_hook_with_source "$dir019" "startup") && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ ! -f "$dir019/.rite-compact-state" ]; then
  pass "source=startup + active=true → compact state cleaned (defensive reset calls _cleanup_stale_compact)"
else
  fail "Expected exit 0 and .rite-compact-state removed, got rc=$rc"
fi
echo ""

# --------------------------------------------------------------------------
# TC-020: source=startup + compact_state=blocked + lockdir → both cleaned (#756)
# --------------------------------------------------------------------------
echo "TC-020: source=startup + compact_state=blocked + lockdir → both cleaned"
dir020="$TEST_DIR/tc020"
mkdir -p "$dir020"
create_state_file "$dir020" '{"active": false, "issue_number": 63, "phase": "completed"}'
echo '{"compact_state": "blocked", "active_issue": 63}' > "$dir020/.rite-compact-state"
mkdir -p "$dir020/.rite-compact-state.lockdir"

output=$(run_hook_with_source "$dir020" "startup") && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ ! -f "$dir020/.rite-compact-state" ] && [ ! -d "$dir020/.rite-compact-state.lockdir" ]; then
  pass "source=startup + active=false → compact state and lockdir both cleaned"
else
  fail "Expected exit 0 and both .rite-compact-state and .lockdir removed, got rc=$rc"
fi
echo ""

# --------------------------------------------------------------------------
# TC-021: source=compact + compact_state=blocked + active=false → DO NOT clean (#756)
# --------------------------------------------------------------------------
echo "TC-021: source=compact + compact_state=blocked + active=false → compact state preserved"
dir021="$TEST_DIR/tc021"
mkdir -p "$dir021"
create_state_file "$dir021" '{"active": false, "issue_number": 64, "phase": "completed"}'
echo '{"compact_state": "blocked", "active_issue": 64}' > "$dir021/.rite-compact-state"

output=$(run_hook_with_source "$dir021" "compact") && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ -f "$dir021/.rite-compact-state" ]; then
  pass "source=compact + active=false → compact state NOT cleaned (startup only)"
else
  fail "Expected exit 0 and .rite-compact-state preserved for non-startup source, got rc=$rc"
fi
echo ""

# --------------------------------------------------------------------------
# TC-022: source=startup + active=false + no compact state → no-op (#756)
# --------------------------------------------------------------------------
echo "TC-022: source=startup + active=false + no compact state → no-op"
dir022="$TEST_DIR/tc022"
mkdir -p "$dir022"
create_state_file "$dir022" '{"active": false, "issue_number": 65, "phase": "completed"}'
# No .rite-compact-state file

output=$(run_hook_with_source "$dir022" "startup") && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ ! -f "$dir022/.rite-compact-state" ]; then
  pass "source=startup + active=false + no compact state → no-op (no error)"
else
  fail "Expected exit 0 with no errors, got rc=$rc"
fi
echo ""

# --------------------------------------------------------------------------
# TC-023: source=startup + active=true + phase=completed → silent reset + compact cleanup (#772)
# --------------------------------------------------------------------------
echo "TC-023: source=startup + active=true + phase=completed → silent reset + compact cleanup"
dir023="$TEST_DIR/tc023"
mkdir -p "$dir023"
create_state_file "$dir023" '{"active": true, "issue_number": 70, "branch": "fix/issue-70-test", "phase": "completed"}'
echo '{"compact_state": "blocked", "active_issue": 70}' > "$dir023/.rite-compact-state"

output=$(run_hook_with_source "$dir023" "startup") && rc=0 || rc=$?
ACTIVE_AFTER=$(jq -r '.active' "$dir023/.rite-flow-state" 2>/dev/null)
if [ $rc -eq 0 ] && [ -z "$output" ] && [ "$ACTIVE_AFTER" = "false" ] && [ ! -f "$dir023/.rite-compact-state" ]; then
  pass "source=startup + phase=completed → silent reset (no message, active=false, compact state cleaned)"
else
  fail "Expected exit 0, no output, active=false, compact cleaned. Got rc=$rc, active=$ACTIVE_AFTER, compact=$([ -f "$dir023/.rite-compact-state" ] && echo 'exists' || echo 'removed'), output='$output'"
fi
echo ""

# --------------------------------------------------------------------------
# TC-024: source=startup + active=true + phase=implementing → message shown (#772)
# --------------------------------------------------------------------------
echo "TC-024: source=startup + active=true + phase=implementing → message shown"
dir024="$TEST_DIR/tc024"
mkdir -p "$dir024"
create_state_file "$dir024" '{"active": true, "issue_number": 71, "branch": "feat/issue-71-test", "phase": "implementing"}'

output=$(run_hook_with_source "$dir024" "startup") && rc=0 || rc=$?
ACTIVE_AFTER=$(jq -r '.active' "$dir024/.rite-flow-state" 2>/dev/null)
if [ $rc -eq 0 ] && [ "$ACTIVE_AFTER" = "false" ] && echo "$output" | grep -q "前回のセッション状態が残っていたためリセットしました"; then
  pass "source=startup + phase=implementing → reset message shown and active=false"
else
  fail "Expected reset message and active=false, got rc=$rc, active=$ACTIVE_AFTER, output='$output'"
fi
echo ""

# --------------------------------------------------------------------------
# TC-025: No state file + issue branch + source=startup → silent (#772)
# --------------------------------------------------------------------------
echo "TC-025: No state file + issue branch + source=startup → silent"
git_repo_025="$TEST_DIR/git_tc025"
mkdir -p "$git_repo_025"
(cd "$git_repo_025" && git init -q && git -c user.name="test" -c user.email="test@test.com" commit --allow-empty -m "init" -q && git checkout -b "feat/issue-200-test" -q)

output=$(run_hook_with_source "$git_repo_025" "startup") && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ -z "$output" ]; then
  pass "No state file + issue branch + startup → no output"
else
  fail "Expected exit 0 with no output, got rc=$rc, output='$output'"
fi
echo ""

# --------------------------------------------------------------------------
# TC-026: source=startup + active=true + phase=completed + needs_clear=true → silent reset (#772)
# Edge case: completed takes priority over needs_clear flag
# --------------------------------------------------------------------------
echo "TC-026: source=startup + phase=completed + needs_clear=true → silent reset (completed priority)"
dir026="$TEST_DIR/tc026"
mkdir -p "$dir026"
create_state_file "$dir026" '{"active": true, "issue_number": 73, "branch": "fix/issue-73-test", "phase": "completed", "needs_clear": true}'

output=$(run_hook_with_source "$dir026" "startup") && rc=0 || rc=$?
ACTIVE_AFTER=$(jq -r '.active' "$dir026/.rite-flow-state" 2>/dev/null)
if [ $rc -eq 0 ] && [ -z "$output" ] && [ "$ACTIVE_AFTER" = "false" ]; then
  pass "source=startup + phase=completed + needs_clear=true → silent reset (completed takes priority)"
else
  fail "Expected exit 0, no output, active=false. Got rc=$rc, active=$ACTIVE_AFTER, output='$output'"
fi
echo ""

# --------------------------------------------------------------------------
# TC-027: source=startup + active=true + no issue_number + phase=implementing → silent reset, no message (#772)
# Tests the code path where ISSUE is empty after defensive reset (phase != completed)
# --------------------------------------------------------------------------
echo "TC-027: source=startup + active=true + no issue_number → silent reset, no message"
dir027="$TEST_DIR/tc027"
mkdir -p "$dir027"
create_state_file "$dir027" '{"active": true, "phase": "implementing"}'

output=$(run_hook_with_source "$dir027" "startup") && rc=0 || rc=$?
ACTIVE_AFTER=$(jq -r '.active' "$dir027/.rite-flow-state" 2>/dev/null)
if [ $rc -eq 0 ] && [ -z "$output" ] && [ "$ACTIVE_AFTER" = "false" ]; then
  pass "source=startup + no issue_number → silent reset (no message because ISSUE is empty)"
else
  fail "Expected exit 0, no output, active=false. Got rc=$rc, active=$ACTIVE_AFTER, output='$output'"
fi
echo ""

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ $FAIL -gt 0 ]; then
  exit 1
fi
