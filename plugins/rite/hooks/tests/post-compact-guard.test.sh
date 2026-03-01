#!/bin/bash
# Tests for post-compact-guard.sh (PreToolUse hook)
# Usage: bash plugins/rite/hooks/tests/post-compact-guard.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../post-compact-guard.sh"
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0

# Prerequisite check: jq is required
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
  echo "  PASS: $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
}

# Helper: run hook with given CWD
run_guard() {
  local cwd="$1"
  local rc=0
  local output
  output=$(echo "{\"cwd\": \"$cwd\"}" | bash "$HOOK" 2>/dev/null) || rc=$?
  echo "$output"
  return $rc
}

echo "=== post-compact-guard.sh tests ==="
echo ""

# --------------------------------------------------------------------------
# TC-001: No .rite-compact-state → exit 0 (allow, no JSON output)
# --------------------------------------------------------------------------
echo "TC-001: No .rite-compact-state → exit 0 (allow)"
dir001="$TEST_DIR/tc001"
mkdir -p "$dir001"

output=$(run_guard "$dir001") && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ -z "$output" ]; then
  pass "No compact state file → allow (no output)"
else
  fail "Expected exit 0 with no output, got rc=$rc, output='$output'"
fi
echo ""

# --------------------------------------------------------------------------
# TC-002: compact_state=normal → exit 0 (allow)
#
# .rite-flow-state に active=true を設定し、self-healing パスではなく
# compact_state=normal による正規の allow パスを通ることを検証。
# self-healing が発動した場合 .rite-compact-state が削除されるため、
# ファイル残存で正規パスを確認する。
# --------------------------------------------------------------------------
echo "TC-002: compact_state=normal → exit 0 (allow)"
dir002="$TEST_DIR/tc002"
mkdir -p "$dir002"
echo '{"compact_state": "normal"}' > "$dir002/.rite-compact-state"
echo '{"active": true, "issue_number": 1}' > "$dir002/.rite-flow-state"

output=$(run_guard "$dir002") && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ -z "$output" ]; then
  pass "compact_state=normal → allow (no output)"
else
  fail "Expected exit 0 with no output, got rc=$rc, output='$output'"
fi
# Verify normal path was taken (not self-healing): compact state file should still exist
if [ -f "$dir002/.rite-compact-state" ]; then
  pass "compact state file preserved (normal path, not self-healing)"
else
  fail "compact state file was removed (self-healing path was taken instead of normal path)"
fi
echo ""

# --------------------------------------------------------------------------
# TC-003: compact_state=resuming → exit 0 (allow)
#
# .rite-flow-state に active=true を設定し、self-healing パスではなく
# compact_state=resuming による正規の allow パスを通ることを検証。
# self-healing が発動した場合 .rite-compact-state が削除されるため、
# ファイル残存で正規パスを確認する。
# --------------------------------------------------------------------------
echo "TC-003: compact_state=resuming → exit 0 (allow)"
dir003="$TEST_DIR/tc003"
mkdir -p "$dir003"
echo '{"compact_state": "resuming"}' > "$dir003/.rite-compact-state"
echo '{"active": true, "issue_number": 1}' > "$dir003/.rite-flow-state"

output=$(run_guard "$dir003") && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ -z "$output" ]; then
  pass "compact_state=resuming → allow (no output)"
else
  fail "Expected exit 0 with no output, got rc=$rc, output='$output'"
fi
# Verify resuming path was taken (not self-healing): compact state file should still exist
if [ -f "$dir003/.rite-compact-state" ]; then
  pass "compact state file preserved (resuming path, not self-healing)"
else
  fail "compact state file was removed (self-healing path was taken instead of resuming path)"
fi
echo ""

# --------------------------------------------------------------------------
# TC-004: compact_state=blocked → deny JSON + stays blocked (persistent block, #854)
# --------------------------------------------------------------------------
echo "TC-004: compact_state=blocked → deny JSON + stays blocked"
dir004="$TEST_DIR/tc004"
mkdir -p "$dir004"
echo '{"compact_state": "blocked", "active_issue": 42}' > "$dir004/.rite-compact-state"
echo '{"active": true, "issue_number": 42, "phase": "phase5_review", "next_action": "proceed to fix"}' > "$dir004/.rite-flow-state"

output=$(run_guard "$dir004") && rc=0 || rc=$?
if [ $rc -eq 0 ] && echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
  pass "compact_state=blocked → deny JSON (persistent block)"
else
  fail "Expected exit 0 with deny JSON, got rc=$rc, output='$output'"
fi
# Verify compact_state stays blocked (no transition to resuming — #854)
compact_after=$(jq -r '.compact_state' "$dir004/.rite-compact-state" 2>/dev/null)
if [ "$compact_after" = "blocked" ]; then
  pass "compact_state stays blocked (persistent block, #854)"
else
  fail "compact_state should stay blocked, got '$compact_after'"
fi
# Verify deny reason contains phase info
reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
if echo "$reason" | grep -q "phase5_review"; then
  pass "deny reason contains phase info"
else
  fail "deny reason missing flow context: '$reason'"
fi
echo ""

# --------------------------------------------------------------------------
# TC-004b: Second tool use after block → still denied (persistent block, #854)
#
# Verifies that compact_state=blocked denies ALL tool calls, not just the first.
# This prevents the re-compact loop where LLM generates massive text output
# after a one-shot denial, triggering a second compact (#854).
# Uses TC-004's directory to verify persistent blocking:
# blocked → deny (TC-004) → still blocked → deny again (TC-004b).
#
# ⚠️ Dependency: This test reuses TC-004's directory ($dir004) and depends on
# TC-004 having kept compact_state as "blocked". If TC-004 fails,
# this test will also fail (cascading failure by design for E2E validation).
# --------------------------------------------------------------------------
echo "TC-004b: compact_state=blocked (after first deny) → still denied (#854)"

# Reuse TC-004's directory (compact_state should still be blocked)
output=$(run_guard "$dir004") && rc=0 || rc=$?
if [ $rc -eq 0 ] && echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
  pass "compact_state=blocked (after first deny) → still denied (#854)"
else
  fail "Expected exit 0 with deny JSON, got rc=$rc, output='$output'"
fi
# Verify compact state file still exists and still blocked
compact_after2=$(jq -r '.compact_state' "$dir004/.rite-compact-state" 2>/dev/null)
if [ "$compact_after2" = "blocked" ]; then
  pass "compact state still blocked after second denial"
else
  fail "compact state should still be blocked, got '$compact_after2'"
fi
echo ""

# --------------------------------------------------------------------------
# TC-005: Corrupted .rite-compact-state → deny (fail-closed)
# --------------------------------------------------------------------------
echo "TC-005: Corrupted .rite-compact-state → deny (fail-closed)"
dir005="$TEST_DIR/tc005"
mkdir -p "$dir005"
echo "{broken json" > "$dir005/.rite-compact-state"
echo '{"active": true, "issue_number": 1}' > "$dir005/.rite-flow-state"

output=$(run_guard "$dir005") && rc=0 || rc=$?
if [ $rc -eq 0 ] && echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
  pass "Corrupted compact state → deny (fail-closed)"
else
  fail "Expected deny for corrupted state, got rc=$rc, output='$output'"
fi
echo ""

# --------------------------------------------------------------------------
# TC-006: Deny JSON structure validation
# --------------------------------------------------------------------------
echo "TC-006: Deny JSON structure validation"
dir006="$TEST_DIR/tc006"
mkdir -p "$dir006"
echo '{"compact_state": "blocked"}' > "$dir006/.rite-compact-state"
echo '{"active": true, "issue_number": 1}' > "$dir006/.rite-flow-state"

output=$(run_guard "$dir006") && rc=0 || rc=$?
HAS_EVENT=$(echo "$output" | jq -r '.hookSpecificOutput.hookEventName // empty' 2>/dev/null)
HAS_DECISION=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
HAS_REASON=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)

if [ "$HAS_EVENT" = "PreToolUse" ] && \
   [ "$HAS_DECISION" = "deny" ] && \
   [ -n "$HAS_REASON" ]; then
  pass "Deny JSON has all required fields (hookEventName, permissionDecision, permissionDecisionReason)"
else
  fail "Deny JSON missing required fields. event='$HAS_EVENT', decision='$HAS_DECISION', reason='$HAS_REASON'"
fi
echo ""

# --------------------------------------------------------------------------
# TC-007: No CWD in input → exit 0 (allow)
# --------------------------------------------------------------------------
echo "TC-007: No CWD in input → exit 0 (allow)"
output=$(echo "{}" | bash "$HOOK" 2>/dev/null) && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ -z "$output" ]; then
  pass "Missing CWD → allow (no output)"
else
  fail "Expected exit 0 with no output, got rc=$rc, output='$output'"
fi
echo ""

# --------------------------------------------------------------------------
# TC-008: compact_state=blocked + tool_name=Read → deny (all tools blocked)
# --------------------------------------------------------------------------
echo "TC-008: compact_state=blocked + tool_name=Read → deny (all tools blocked)"
dir008="$TEST_DIR/tc008"
mkdir -p "$dir008"
echo '{"compact_state": "blocked"}' > "$dir008/.rite-compact-state"
echo '{"active": true, "issue_number": 1}' > "$dir008/.rite-flow-state"

output=$(echo "{\"cwd\": \"$dir008\", \"tool_name\": \"Read\"}" | bash "$HOOK" 2>/dev/null) && rc=0 || rc=$?
if [ $rc -eq 0 ] && echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
  pass "compact_state=blocked + Read → deny"
else
  fail "Expected deny JSON, got rc=$rc, output='$output'"
fi
echo ""

# --------------------------------------------------------------------------
# TC-009: compact_state=blocked + tool_name=Edit → deny (write tool blocked)
# --------------------------------------------------------------------------
echo "TC-009: compact_state=blocked + tool_name=Edit → deny (write tool blocked)"
dir009="$TEST_DIR/tc009"
mkdir -p "$dir009"
echo '{"compact_state": "blocked"}' > "$dir009/.rite-compact-state"
echo '{"active": true, "issue_number": 1}' > "$dir009/.rite-flow-state"

output=$(echo "{\"cwd\": \"$dir009\", \"tool_name\": \"Edit\"}" | bash "$HOOK" 2>/dev/null) && rc=0 || rc=$?
if [ $rc -eq 0 ] && echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
  pass "compact_state=blocked + Edit → deny"
else
  fail "Expected deny JSON, got rc=$rc, output='$output'"
fi
echo ""

# --------------------------------------------------------------------------
# TC-010: compact_state=blocked + tool_name=Bash → deny (exec tool blocked)
# --------------------------------------------------------------------------
echo "TC-010: compact_state=blocked + tool_name=Bash → deny (exec tool blocked)"
dir010="$TEST_DIR/tc010"
mkdir -p "$dir010"
echo '{"compact_state": "blocked"}' > "$dir010/.rite-compact-state"
echo '{"active": true, "issue_number": 1}' > "$dir010/.rite-flow-state"

output=$(echo "{\"cwd\": \"$dir010\", \"tool_name\": \"Bash\"}" | bash "$HOOK" 2>/dev/null) && rc=0 || rc=$?
if [ $rc -eq 0 ] && echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
  pass "compact_state=blocked + Bash → deny"
else
  fail "Expected deny JSON, got rc=$rc, output='$output'"
fi
echo ""

# --------------------------------------------------------------------------
# TC-011: compact_state=blocked + active=false → allow (self-healing: stale compact state)
# --------------------------------------------------------------------------
echo "TC-011: compact_state=blocked + active=false → allow (self-healing)"
dir011="$TEST_DIR/tc011"
mkdir -p "$dir011"
echo '{"compact_state": "blocked", "active_issue": 99}' > "$dir011/.rite-compact-state"
echo '{"active": false, "issue_number": 99}' > "$dir011/.rite-flow-state"

output=$(run_guard "$dir011") && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ -z "$output" ]; then
  pass "compact_state=blocked + active=false → allow (stale compact state cleaned up)"
else
  fail "Expected exit 0 with no output, got rc=$rc, output='$output'"
fi
# Verify compact state was cleaned up
if [ ! -f "$dir011/.rite-compact-state" ]; then
  pass "compact state file was removed"
else
  fail "compact state file should have been removed"
fi
echo ""

# --------------------------------------------------------------------------
# TC-012: compact_state=blocked + no .rite-flow-state → allow (self-healing: flow state absent)
# --------------------------------------------------------------------------
echo "TC-012: compact_state=blocked + no .rite-flow-state → allow (self-healing)"
dir012="$TEST_DIR/tc012"
mkdir -p "$dir012"
echo '{"compact_state": "blocked", "active_issue": 100}' > "$dir012/.rite-compact-state"
# No .rite-flow-state file

output=$(run_guard "$dir012") && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ -z "$output" ]; then
  pass "compact_state=blocked + no flow state → allow (stale compact state cleaned up)"
else
  fail "Expected exit 0 with no output, got rc=$rc, output='$output'"
fi
# Verify compact state was cleaned up
if [ ! -f "$dir012/.rite-compact-state" ]; then
  pass "compact state file was removed"
else
  fail "compact state file should have been removed"
fi
echo ""

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ $FAIL -gt 0 ]; then
  exit 1
fi
