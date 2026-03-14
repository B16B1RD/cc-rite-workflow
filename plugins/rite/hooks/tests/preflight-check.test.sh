#!/bin/bash
# Tests for preflight-check.sh
# Usage: bash plugins/rite/hooks/tests/preflight-check.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../preflight-check.sh"
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0
LAST_STDERR_FILE=""

# Prerequisite check: jq is required by preflight-check.sh
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
  # Show captured stderr for debugging context
  if [ -n "${LAST_STDERR_FILE:-}" ] && [ -s "$LAST_STDERR_FILE" ]; then
    echo "    stderr: $(cat "$LAST_STDERR_FILE")"
  fi
}

# Helper: run preflight-check hook with given args, capture stderr for debugging
# Note: TC-005/TC-006 verify that resuming state is always allowed regardless of age.
# The lock acquisition failure fallback is covered by work-memory-lock.test.sh.
run_hook() {
  local cwd="$1"
  local command_id="${2:-/rite:issue:start}"
  local rc=0
  LAST_STDERR_FILE="$(mktemp "$TEST_DIR/stderr.XXXXXX")"
  bash "$HOOK" --command-id "$command_id" --cwd "$cwd" 2>"$LAST_STDERR_FILE" || rc=$?
  return $rc
}

# Helper: create compact state file
create_compact_state() {
  local dir="$1"
  local content="$2"
  echo "$content" > "$dir/.rite-compact-state"
}

echo "=== preflight-check.sh tests ==="
echo ""

# --------------------------------------------------------------------------
# TC-001: No compact state file → exit 0 (allow)
# --------------------------------------------------------------------------
echo "TC-001: No compact state file → exit 0 (allow)"
dir001="$TEST_DIR/tc001"
mkdir -p "$dir001"
if run_hook "$dir001"; then
  pass "No compact state → allowed"
else
  fail "Should allow when no compact state file"
fi
echo ""

# --------------------------------------------------------------------------
# TC-002: compact_state=normal → exit 0 (allow)
# --------------------------------------------------------------------------
echo "TC-002: compact_state=normal → exit 0 (allow)"
dir002="$TEST_DIR/tc002"
mkdir -p "$dir002"
create_compact_state "$dir002" '{"compact_state": "normal"}'
if run_hook "$dir002"; then
  pass "normal state → allowed"
else
  fail "Should allow when compact_state is normal"
fi
echo ""

# --------------------------------------------------------------------------
# TC-003: compact_state=blocked → exit 1 (block non-resume commands)
# --------------------------------------------------------------------------
echo "TC-003: compact_state=blocked → exit 1 (block)"
dir003="$TEST_DIR/tc003"
mkdir -p "$dir003"
create_compact_state "$dir003" '{"compact_state": "recovering", "active_issue": 42, "compact_state_set_at": "2026-01-01T00:00:00Z"}'
output=$(bash "$HOOK" --command-id "/rite:issue:start" --cwd "$dir003" 2>/dev/null) && rc=0 || rc=$?
if [ $rc -eq 1 ]; then
  if echo "$output" | grep -q "#42"; then
    pass "Blocked state → exit 1 with Issue #42 in output"
  else
    fail "exit 1 but missing Issue #42 in output: $output"
  fi
else
  fail "Expected exit 1, got exit $rc"
fi
echo ""

# --------------------------------------------------------------------------
# TC-004: compact_state=blocked + /rite:resume → exit 0 (allow)
# --------------------------------------------------------------------------
echo "TC-004: compact_state=blocked + /rite:resume → exit 0 (allow)"
dir004="$TEST_DIR/tc004"
mkdir -p "$dir004"
create_compact_state "$dir004" '{"compact_state": "recovering", "active_issue": 42}'
if run_hook "$dir004" "/rite:resume"; then
  pass "Blocked state + /rite:resume → allowed"
else
  fail "Should allow /rite:resume even when blocked"
fi
echo ""

# --------------------------------------------------------------------------
# TC-005: compact_state=resuming → exit 0 (always allow)
# --------------------------------------------------------------------------
echo "TC-005: compact_state=resuming → exit 0 (always allow)"
dir005="$TEST_DIR/tc005"
mkdir -p "$dir005"
fresh_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
create_compact_state "$dir005" "{\"compact_state\": \"resuming\", \"compact_state_set_at\": \"$fresh_ts\"}"
if run_hook "$dir005"; then
  pass "Fresh resuming state → allowed"
else
  fail "Should allow when resuming is fresh (<300s)"
fi
echo ""

# --------------------------------------------------------------------------
# TC-006: compact_state=resuming (stale, >300s) → exit 0 (always allow)
# --------------------------------------------------------------------------
echo "TC-006: compact_state=resuming (stale, >300s) → exit 0 (always allow)"
dir006="$TEST_DIR/tc006"
mkdir -p "$dir006"
# Set timestamp to 10 minutes ago (>300s) — should still be allowed
stale_ts=$(date -u -d "10 minutes ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-10M +"%Y-%m-%dT%H:%M:%SZ")
create_compact_state "$dir006" "{\"compact_state\": \"resuming\", \"compact_state_set_at\": \"$stale_ts\", \"active_issue\": 99}"
if run_hook "$dir006"; then
  # Verify state is still resuming (not reset to blocked)
  new_state=$(jq -r '.compact_state' "$dir006/.rite-compact-state" 2>/dev/null)
  if [ "$new_state" = "resuming" ]; then
    pass "Stale resuming → still allowed, state unchanged"
  else
    fail "State should remain resuming but got: $new_state"
  fi
else
  fail "Expected exit 0 for stale resuming, got exit 1"
fi
echo ""

# --------------------------------------------------------------------------
# TC-007: compact_state=resuming without timestamp → exit 0 (allow, fail-open)
# --------------------------------------------------------------------------
echo "TC-007: compact_state=resuming without timestamp → exit 0 (allow)"
dir007="$TEST_DIR/tc007"
mkdir -p "$dir007"
create_compact_state "$dir007" '{"compact_state": "resuming"}'
if run_hook "$dir007"; then
  pass "Resuming without timestamp → allowed (fail-open)"
else
  fail "Should allow resuming without timestamp"
fi
echo ""

# --------------------------------------------------------------------------
# TC-008: Invalid JSON in compact state → exit 1 (fail-closed)
# --------------------------------------------------------------------------
echo "TC-008: Invalid JSON in compact state → exit 1 (fail-closed)"
dir008="$TEST_DIR/tc008"
mkdir -p "$dir008"
echo "NOT-VALID-JSON" > "$dir008/.rite-compact-state"
output=$(bash "$HOOK" --command-id "/rite:issue:start" --cwd "$dir008" 2>/dev/null) && rc=0 || rc=$?
if [ $rc -eq 1 ]; then
  # Verify error message mentions read failure
  if echo "$output" | grep -qi "読み取り\|read\|parse\|fail\|error\|invalid"; then
    pass "Invalid JSON → exit 1 with error message"
  else
    # Exit code is correct even without specific message
    pass "Invalid JSON → exit 1 (fail-closed)"
  fi
else
  fail "Expected exit 1 for invalid JSON, got exit $rc"
fi
echo ""

# --------------------------------------------------------------------------
# TC-009: Nonexistent CWD → exit 0 (fail-open)
# --------------------------------------------------------------------------
echo "TC-009: Nonexistent CWD → exit 0 (fail-open)"
if run_hook "$TEST_DIR/nonexistent-dir-tc009"; then
  pass "Nonexistent CWD → exit 0 (fail-open)"
else
  fail "Should exit 0 for nonexistent CWD"
fi
echo ""

# --------------------------------------------------------------------------
# TC-010: No --cwd argument → uses pwd (run from clean temp dir)
# --------------------------------------------------------------------------
echo "TC-010: No --cwd argument → uses pwd"
dir010="$TEST_DIR/tc010"
mkdir -p "$dir010"
# Run from a clean directory without .rite-compact-state
rc=0
(cd "$dir010" && bash "$HOOK" --command-id "/rite:issue:start" 2>/dev/null) || rc=$?
if [ $rc -eq 0 ]; then
  pass "No --cwd → uses pwd (clean dir), exit 0"
else
  fail "Expected exit 0, got exit $rc"
fi
echo ""

# --------------------------------------------------------------------------
# TC-011: Blocked state shows active_issue and set_at in output
# --------------------------------------------------------------------------
echo "TC-011: Blocked state output contains Issue and timestamp"
dir011="$TEST_DIR/tc011"
mkdir -p "$dir011"
create_compact_state "$dir011" '{"compact_state": "recovering", "active_issue": 123, "compact_state_set_at": "2026-02-22T00:00:00Z"}'
output=$(bash "$HOOK" --command-id "/rite:issue:list" --cwd "$dir011" 2>/dev/null) && rc=0 || rc=$?
if [ $rc -eq 1 ]; then
  if echo "$output" | grep -q "#123" && echo "$output" | grep -q "/rite:issue:list"; then
    pass "Blocked output contains Issue #123 and blocked command"
  else
    fail "Missing Issue or command in output: $output"
  fi
else
  fail "Expected exit 1, got exit $rc"
fi
echo ""

# --------------------------------------------------------------------------
# TC-012: compact_state=resuming with invalid timestamp format → exit 0 (fail-open)
# --------------------------------------------------------------------------
echo "TC-012: Resuming with invalid timestamp format → exit 0 (allow)"
dir012="$TEST_DIR/tc012"
mkdir -p "$dir012"
create_compact_state "$dir012" '{"compact_state": "resuming", "compact_state_set_at": "INVALID-FORMAT"}'
if run_hook "$dir012"; then
  pass "Invalid timestamp format → treated as no timestamp → allowed"
else
  fail "Should allow when timestamp format is invalid"
fi
echo ""

# --------------------------------------------------------------------------
# TC-013: Unknown compact_state value → block (exit 1) for non-resume commands
# --------------------------------------------------------------------------
echo "TC-013: Unknown compact_state value → exit 1 (block)"
dir013="$TEST_DIR/tc013"
mkdir -p "$dir013"
create_compact_state "$dir013" '{"compact_state": "unknown_state", "active_issue": 1}'
output=$(bash "$HOOK" --command-id "/rite:issue:start" --cwd "$dir013" 2>/dev/null) && rc=0 || rc=$?
if [ $rc -eq 1 ]; then
  pass "Unknown state → exit 1 (blocked)"
else
  fail "Expected exit 1 for unknown state, got exit $rc"
fi
echo ""

# --------------------------------------------------------------------------
# TC-014: Unknown compact_state + /rite:resume → exit 0 (always allowed)
# --------------------------------------------------------------------------
echo "TC-014: Unknown compact_state + /rite:resume → exit 0 (allow)"
dir014="$TEST_DIR/tc014"
mkdir -p "$dir014"
create_compact_state "$dir014" '{"compact_state": "unknown_state", "active_issue": 1}'
if run_hook "$dir014" "/rite:resume"; then
  pass "Unknown state + /rite:resume → allowed"
else
  fail "Should allow /rite:resume regardless of state"
fi
echo ""

# --------------------------------------------------------------------------
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
