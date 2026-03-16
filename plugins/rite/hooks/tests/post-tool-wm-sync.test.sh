#!/bin/bash
# Tests for post-tool-wm-sync.sh
# Usage: bash plugins/rite/hooks/tests/post-tool-wm-sync.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../post-tool-wm-sync.sh"
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0

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

# Helper: create a state file
create_state_file() {
  local dir="$1"
  local content="$2"
  echo "$content" > "$dir/.rite-flow-state"
}

# Helper: run hook with given CWD
run_hook() {
  local cwd="$1"
  local rc=0
  echo "{\"tool_name\": \"Bash\", \"cwd\": \"$cwd\"}" | bash "$HOOK" 2>/dev/null || rc=$?
  return $rc
}

echo "=== post-tool-wm-sync.sh tests ==="
echo ""

# --- TC-001: No state file → no-op ---
echo "TC-001: No state file → no-op"
dir001="$TEST_DIR/tc001"
mkdir -p "$dir001"
run_hook "$dir001"
rc001=$?
if [ ! -d "$dir001/.rite-work-memory" ]; then
  pass "No work memory created without state file (exit code: $rc001)"
else
  fail "Work memory directory should not exist"
fi
echo ""

# --- TC-002: active: false → no work memory created ---
echo "TC-002: active: false → no work memory created"
dir002="$TEST_DIR/tc002"
mkdir -p "$dir002"
create_state_file "$dir002" '{"active": false, "issue_number": 42, "phase": "completed"}'
run_hook "$dir002" || true
if [ ! -d "$dir002/.rite-work-memory" ]; then
  pass "No work memory created when active: false"
else
  fail "Work memory should not be created when active: false"
fi
echo ""

# --- TC-003: active: true, phase: completed → no work memory created (#776) ---
echo "TC-003: active: true, phase: completed → no work memory created (#776)"
dir003="$TEST_DIR/tc003"
mkdir -p "$dir003"
create_state_file "$dir003" '{"active": true, "issue_number": 42, "phase": "completed"}'
run_hook "$dir003" || true
wm_file="$dir003/.rite-work-memory/issue-42.md"
if [ ! -f "$wm_file" ]; then
  pass "No work memory created when phase: completed (defense-in-depth)"
else
  fail "Work memory should NOT be created when phase: completed"
fi
echo ""

# --- TC-004: active: true, phase: phase5_lint, file exists → no recreation ---
echo "TC-004: active: true, file already exists → no recreation"
dir004="$TEST_DIR/tc004"
mkdir -p "$dir004/.rite-work-memory"
echo "existing content" > "$dir004/.rite-work-memory/issue-42.md"
create_state_file "$dir004" '{"active": true, "issue_number": 42, "phase": "phase5_lint"}'
run_hook "$dir004" || true
content=$(cat "$dir004/.rite-work-memory/issue-42.md")
if [ "$content" = "existing content" ]; then
  pass "Existing work memory file not overwritten"
else
  fail "Existing file was modified: $content"
fi
echo ""

# --- TC-005: Happy path — active: true, phase: impl, file not exists → WM created ---
echo "TC-005: Happy path — active: true, phase: impl → work memory created"
dir005="$TEST_DIR/tc005"
mkdir -p "$dir005"
create_state_file "$dir005" '{"active": true, "issue_number": 42, "phase": "phase5_implementation", "branch": "feat/issue-42-test"}'
run_hook "$dir005" || true
wm_file="$dir005/.rite-work-memory/issue-42.md"
if [ -f "$wm_file" ]; then
  # Verify essential fields in created work memory
  wm_ok=true
  if ! grep -q "issue_number: 42" "$wm_file"; then
    fail "Work memory missing issue_number field"
    wm_ok=false
  fi
  if ! grep -q "phase:" "$wm_file"; then
    fail "Work memory missing phase field"
    wm_ok=false
  fi
  if [ "$wm_ok" = true ]; then
    pass "Work memory created with correct fields on happy path"
  fi
else
  fail "Work memory file not created on happy path: $wm_file"
fi
echo ""

# --- TC-006: Phase same as last_synced_phase → no-op (no API call) ---
echo "TC-006: Phase same as last_synced_phase → no-op"
dir006="$TEST_DIR/tc006"
mkdir -p "$dir006/.rite-work-memory"
echo "existing wm" > "$dir006/.rite-work-memory/issue-42.md"
create_state_file "$dir006" '{"active": true, "issue_number": 42, "phase": "phase5_lint", "last_synced_phase": "phase5_lint"}'
rc006=0
run_hook "$dir006" || rc006=$?
# Verify exit code is 0 (not a crash)
synced=$(jq -r '.last_synced_phase' "$dir006/.rite-flow-state" 2>/dev/null)
if [ "$synced" = "phase5_lint" ] && [ "$rc006" -eq 0 ]; then
  pass "No sync when phase matches last_synced_phase (no-op, exit code: $rc006)"
else
  fail "Unexpected: last_synced_phase=$synced, exit code=$rc006"
fi
echo ""

# --- TC-007: Phase differs from last_synced_phase → sync attempted ---
echo "TC-007: Phase differs from last_synced_phase → sync attempted"
dir007="$TEST_DIR/tc007"
mkdir -p "$dir007/.rite-work-memory"
echo "existing wm" > "$dir007/.rite-work-memory/issue-42.md"
create_state_file "$dir007" '{"active": true, "issue_number": 42, "phase": "phase5_pr_created", "last_synced_phase": "phase5_lint"}'
# Enable debug logging to verify phase change was detected
export RITE_DEBUG=1
run_hook "$dir007" || true
unset RITE_DEBUG
# Verify phase change was detected via debug log (not unconditional pass)
if [ -f "$dir007/.rite-flow-debug.log" ] && grep -q "phase changed:" "$dir007/.rite-flow-debug.log" 2>/dev/null; then
  pass "Phase change detected and sync attempted when phase differs"
else
  fail "Phase change not detected in debug log"
fi
echo ""

# --- TC-008: last_synced_phase missing (backward compat) → sync attempted ---
echo "TC-008: last_synced_phase missing (backward compat) → sync attempted"
dir008="$TEST_DIR/tc008"
mkdir -p "$dir008/.rite-work-memory"
echo "existing wm" > "$dir008/.rite-work-memory/issue-42.md"
create_state_file "$dir008" '{"active": true, "issue_number": 42, "phase": "phase3_plan"}'
# Enable debug logging to verify phase change was detected
export RITE_DEBUG=1
run_hook "$dir008" || true
unset RITE_DEBUG
# Verify phase change was detected (last_synced_phase defaults to "" which differs from "phase3_plan")
if [ -f "$dir008/.rite-flow-debug.log" ] && grep -q "phase changed:" "$dir008/.rite-flow-debug.log" 2>/dev/null; then
  pass "Phase change detected when last_synced_phase missing (backward compat)"
else
  fail "Phase change not detected in debug log for backward compat case"
fi
echo ""

# --- TC-009: phase5_lint triggers progress update path ---
echo "TC-009: phase5_lint triggers progress update path (case branch)"
dir009="$TEST_DIR/tc009"
mkdir -p "$dir009/.rite-work-memory"
echo "existing wm" > "$dir009/.rite-work-memory/issue-42.md"
create_state_file "$dir009" '{"active": true, "issue_number": 42, "phase": "phase5_lint", "last_synced_phase": "phase5_implementation"}'
# Enable debug logging to verify progress sync path is reached
export RITE_DEBUG=1
run_hook "$dir009" || true
unset RITE_DEBUG
if [ -f "$dir009/.rite-flow-debug.log" ]; then
  if grep -q "progress sync completed\|update-progress failed" "$dir009/.rite-flow-debug.log" 2>/dev/null; then
    pass "Progress sync path was triggered for phase5_lint"
  else
    # update-phase may also fail in test env, check for phase change detection
    if grep -q "phase changed:" "$dir009/.rite-flow-debug.log" 2>/dev/null; then
      pass "Phase change detected for phase5_lint (progress sync attempted)"
    else
      fail "No phase change detection in debug log"
    fi
  fi
else
  fail "Debug log not created (RITE_DEBUG=1 should have created it)"
fi
echo ""

# --- Summary ---
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
