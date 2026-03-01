#!/bin/bash
# Tests for notification.sh
# Usage: bash plugins/rite/hooks/tests/notification.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../notification.sh"
TEST_DIR="$(mktemp -d)"
LAST_STDERR_FILE=""
PASS=0
FAIL=0
SKIP=0

# Note: notification.sh has best-effort exit handling (exits 0 if jq is missing)
# so jq is not strictly required for the hook, but tests verify behavior with it

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

skip() {
  SKIP=$((SKIP + 1))
  echo "  ⏭️ SKIP: $1"
}

# Helper: show captured stderr on failure for debugging
show_stderr() {
  local stderr_file="${LAST_STDERR_FILE:-}"
  if [ -s "$stderr_file" ]; then
    echo "    stderr: $(cat "$stderr_file")"
  fi
}

# Helper: run notification hook with given CWD and event type
run_hook() {
  local cwd="$1"
  local event_type="${2:-}"
  local event_data="${3:-}"
  local rc=0
  local output
  LAST_STDERR_FILE="$(mktemp "$TEST_DIR/stderr.XXXXXX")"
  output=$(echo "{\"cwd\": \"$cwd\"}" | bash "$HOOK" "$event_type" "$event_data" 2>"$LAST_STDERR_FILE") || rc=$?
  echo "$output"
  return $rc
}

echo "=== notification.sh tests ==="
echo ""

# --------------------------------------------------------------------------
# TC-001: jq not available → graceful exit 0
# --------------------------------------------------------------------------
echo "TC-001: jq not available → graceful exit 0"
if command -v jq >/dev/null 2>&1; then
  skip "jq is available, cannot test jq-missing scenario"
else
  dir001="$TEST_DIR/tc001"
  mkdir -p "$dir001"
  output=$(run_hook "$dir001" "pr_created") && rc=0 || rc=$?
  if [ $rc -eq 0 ]; then
    pass "jq missing → exit 0 (best-effort)"
  else
    fail "Expected exit 0 when jq is missing, got rc=$rc"
  fi
fi
echo ""

# --------------------------------------------------------------------------
# TC-002: No CWD in input → exit 0
# --------------------------------------------------------------------------
echo "TC-002: No CWD in input → exit 0"
output=$(echo "{}" | bash "$HOOK" "pr_created" 2>/dev/null) && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ -z "$output" ]; then
  pass "Missing CWD → exit 0 with no output"
else
  fail "Expected exit 0 with no output, got rc=$rc, output='$output'"
fi
echo ""

# --------------------------------------------------------------------------
# TC-003: CWD is not a directory → exit 0
# --------------------------------------------------------------------------
echo "TC-003: CWD is not a directory → exit 0"
output=$(echo "{\"cwd\": \"$TEST_DIR/nonexistent\"}" | bash "$HOOK" "pr_created" 2>/dev/null) && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ -z "$output" ]; then
  pass "Nonexistent CWD → exit 0 with no output"
else
  fail "Expected exit 0 with no output, got rc=$rc, output='$output'"
fi
echo ""

# --------------------------------------------------------------------------
# TC-004: rite-config.yml does not exist → exit 0
# --------------------------------------------------------------------------
echo "TC-004: rite-config.yml does not exist → exit 0"
dir004="$TEST_DIR/tc004"
mkdir -p "$dir004"

output=$(run_hook "$dir004" "pr_created") && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ -z "$output" ]; then
  pass "No rite-config.yml → exit 0 with no output"
else
  fail "Expected exit 0 with no output, got rc=$rc, output='$output'"
fi
echo ""

# --------------------------------------------------------------------------
# TC-005: Known event type "pr_created" → echo message
# --------------------------------------------------------------------------
echo "TC-005: Known event type 'pr_created' → echo message"
dir005="$TEST_DIR/tc005"
mkdir -p "$dir005"
touch "$dir005/rite-config.yml"

output=$(run_hook "$dir005" "pr_created")
if echo "$output" | grep -q "Notification for PR created"; then
  pass "pr_created event → correct echo message"
else
  fail "Expected 'Notification for PR created', got: $output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-006: Known event type "pr_ready" → echo message
# --------------------------------------------------------------------------
echo "TC-006: Known event type 'pr_ready' → echo message"
dir006="$TEST_DIR/tc006"
mkdir -p "$dir006"
touch "$dir006/rite-config.yml"

output=$(run_hook "$dir006" "pr_ready")
if echo "$output" | grep -q "Notification for PR ready for review"; then
  pass "pr_ready event → correct echo message"
else
  fail "Expected 'Notification for PR ready for review', got: $output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-007: Known event type "issue_closed" → echo message
# --------------------------------------------------------------------------
echo "TC-007: Known event type 'issue_closed' → echo message"
dir007="$TEST_DIR/tc007"
mkdir -p "$dir007"
touch "$dir007/rite-config.yml"

output=$(run_hook "$dir007" "issue_closed")
if echo "$output" | grep -q "Notification for Issue closed"; then
  pass "issue_closed event → correct echo message"
else
  fail "Expected 'Notification for Issue closed', got: $output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-008: Unknown event type → no output (skip)
# --------------------------------------------------------------------------
echo "TC-008: Unknown event type → no output (skip)"
dir008="$TEST_DIR/tc008"
mkdir -p "$dir008"
touch "$dir008/rite-config.yml"

output=$(run_hook "$dir008" "unknown_event")
if [ -z "$output" ]; then
  pass "Unknown event type → no output (skipped)"
else
  fail "Expected no output for unknown event, got: $output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-009: No event type specified → no output (skip)
# --------------------------------------------------------------------------
echo "TC-009: No event type specified → no output (skip)"
dir009="$TEST_DIR/tc009"
mkdir -p "$dir009"
touch "$dir009/rite-config.yml"

output=$(run_hook "$dir009" "")
if [ -z "$output" ]; then
  pass "No event type → no output (skipped)"
else
  fail "Expected no output when no event type, got: $output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-010: Webhook validation - only https:// URLs accepted
# --------------------------------------------------------------------------
echo "TC-010: Webhook validation (integration test stub)"
# Note: The actual send_* functions are not tested here because they require
# a real webhook endpoint. This test verifies the URL pattern validation logic.
dir010="$TEST_DIR/tc010"
mkdir -p "$dir010"
touch "$dir010/rite-config.yml"

# Verify the hook script contains https:// validation
if grep -q 'webhook_url.*=.*https://' "$HOOK"; then
  pass "Webhook URL validation pattern found in script"
else
  fail "Expected https:// validation pattern in hook script"
fi
echo ""

# --------------------------------------------------------------------------
# TC-011: curl command structure - best-effort with timeouts
# --------------------------------------------------------------------------
echo "TC-011: curl command structure (static analysis)"
# Verify that curl commands have proper flags: -sf, --connect-timeout, --max-time, || true
if grep -q 'curl -sf --connect-timeout' "$HOOK" && \
   grep -q '|| true' "$HOOK"; then
  pass "curl commands have best-effort flags (silent-fail, timeouts, || true)"
else
  fail "curl commands missing required best-effort flags"
fi
echo ""

# --------------------------------------------------------------------------
# TC-012: send_slack function signature
# --------------------------------------------------------------------------
echo "TC-012: send_slack function signature"
if grep -q 'send_slack()' "$HOOK" && \
   grep -A5 'send_slack()' "$HOOK" | grep -q 'webhook_url' && \
   grep -A5 'send_slack()' "$HOOK" | grep -q 'message'; then
  pass "send_slack function has correct signature (webhook_url, message)"
else
  fail "send_slack function signature incorrect"
fi
echo ""

# --------------------------------------------------------------------------
# TC-013: send_discord function signature
# --------------------------------------------------------------------------
echo "TC-013: send_discord function signature"
if grep -q 'send_discord()' "$HOOK" && \
   grep -A5 'send_discord()' "$HOOK" | grep -q 'webhook_url' && \
   grep -A5 'send_discord()' "$HOOK" | grep -q 'message'; then
  pass "send_discord function has correct signature (webhook_url, message)"
else
  fail "send_discord function signature incorrect"
fi
echo ""

# --------------------------------------------------------------------------
# TC-014: send_teams function signature
# --------------------------------------------------------------------------
echo "TC-014: send_teams function signature"
if grep -q 'send_teams()' "$HOOK" && \
   grep -A5 'send_teams()' "$HOOK" | grep -q 'webhook_url' && \
   grep -A5 'send_teams()' "$HOOK" | grep -q 'message'; then
  pass "send_teams function has correct signature (webhook_url, message)"
else
  fail "send_teams function signature incorrect"
fi
echo ""

# --------------------------------------------------------------------------
# TC-015: Event data parameter reserved for future use
# --------------------------------------------------------------------------
echo "TC-015: Event data parameter (reserved, currently unused)"
dir015="$TEST_DIR/tc015"
mkdir -p "$dir015"
touch "$dir015/rite-config.yml"

# Pass event_data parameter - should be accepted but not used
output=$(run_hook "$dir015" "pr_created" '{"pr_number": 42}') && rc=0 || rc=$?
if [ $rc -eq 0 ] && echo "$output" | grep -q "Notification for PR created"; then
  pass "Event data parameter accepted (reserved for future use)"
else
  fail "Hook failed with event_data parameter, rc=$rc, output='$output'"
fi
echo ""

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo "=== Results: $PASS passed, $FAIL failed, $SKIP skipped ==="
if [ $FAIL -gt 0 ]; then
  exit 1
fi
