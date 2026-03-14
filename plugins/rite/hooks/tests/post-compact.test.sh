#!/bin/bash
# Tests for post-compact.sh (PostCompact hook)
# Usage: bash plugins/rite/hooks/tests/post-compact.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../post-compact.sh"
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

setup_test() {
  local test_cwd="$TEST_DIR/$1"
  mkdir -p "$test_cwd"
  # Create minimal state-path-resolve.sh mock
  mkdir -p "$test_cwd/.git"
  echo "$test_cwd"
}

echo "=== post-compact.sh tests ==="

# --- TC-001: active flow + recovering → stdout output + normal transition ---
echo "TC-001: Active flow + recovering → auto-recovery"
TC_DIR=$(setup_test "tc001")
jq -n '{active: true, issue_number: 42, phase: "phase5_implementation", next_action: "Continue coding", loop_count: 1, pr_number: 10, branch: "feat/issue-42-test"}' > "$TC_DIR/.rite-flow-state"
jq -n '{compact_state: "recovering", compact_state_set_at: "2026-03-14T12:00:00Z", active_issue: 42}' > "$TC_DIR/.rite-compact-state"

OUTPUT=$(echo '{"cwd": "'"$TC_DIR"'", "source": "auto"}' | bash "$HOOK" 2>/dev/null) || true
if echo "$OUTPUT" | grep -q "Auto-compact recovery"; then
  pass "stdout contains auto-recovery message"
else
  fail "stdout missing auto-recovery message: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "Issue #42"; then
  pass "stdout contains issue number"
else
  fail "stdout missing issue number"
fi
COMPACT_VAL=$(jq -r '.compact_state' "$TC_DIR/.rite-compact-state" 2>/dev/null) || COMPACT_VAL=""
if [ "$COMPACT_VAL" = "normal" ]; then
  pass "compact_state transitioned to normal"
else
  fail "compact_state is '$COMPACT_VAL', expected 'normal'"
fi

# --- TC-002: manual compact → state re-injection only ---
echo "TC-002: Manual compact → no auto-continue instruction"
TC_DIR=$(setup_test "tc002")
jq -n '{active: true, issue_number: 42, phase: "phase5_review", next_action: "Review PR", loop_count: 0, pr_number: 5, branch: "feat/issue-42-test"}' > "$TC_DIR/.rite-flow-state"
jq -n '{compact_state: "recovering", compact_state_set_at: "2026-03-14T12:00:00Z", active_issue: 42}' > "$TC_DIR/.rite-compact-state"

OUTPUT=$(echo '{"cwd": "'"$TC_DIR"'", "source": "manual"}' | bash "$HOOK" 2>/dev/null) || true
if echo "$OUTPUT" | grep -q "Compact recovery"; then
  pass "stdout contains recovery message for manual"
else
  fail "stdout missing recovery message: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "Auto-compact recovery"; then
  fail "manual should not contain auto-compact recovery"
else
  pass "manual does not contain auto-compact recovery"
fi

# --- TC-003: no flow state → cleanup + no stdout ---
echo "TC-003: No flow state → cleanup, no output"
TC_DIR=$(setup_test "tc003")
jq -n '{compact_state: "recovering"}' > "$TC_DIR/.rite-compact-state"

OUTPUT=$(echo '{"cwd": "'"$TC_DIR"'", "source": "auto"}' | bash "$HOOK" 2>/dev/null) || true
if [ -z "$OUTPUT" ]; then
  pass "no stdout output"
else
  fail "unexpected stdout: $OUTPUT"
fi
if [ ! -f "$TC_DIR/.rite-compact-state" ]; then
  pass "compact state cleaned up"
else
  fail "compact state not cleaned up"
fi

# --- TC-004: active=false → cleanup + no stdout ---
echo "TC-004: Active=false → cleanup, no output"
TC_DIR=$(setup_test "tc004")
jq -n '{active: false, issue_number: 42}' > "$TC_DIR/.rite-flow-state"
jq -n '{compact_state: "recovering"}' > "$TC_DIR/.rite-compact-state"

OUTPUT=$(echo '{"cwd": "'"$TC_DIR"'", "source": "auto"}' | bash "$HOOK" 2>/dev/null) || true
if [ -z "$OUTPUT" ]; then
  pass "no stdout output"
else
  fail "unexpected stdout: $OUTPUT"
fi
if [ ! -f "$TC_DIR/.rite-compact-state" ]; then
  pass "compact state cleaned up"
else
  fail "compact state not cleaned up"
fi

# --- TC-005: compact_state=normal → no action ---
echo "TC-005: compact_state=normal → no action"
TC_DIR=$(setup_test "tc005")
jq -n '{active: true, issue_number: 42}' > "$TC_DIR/.rite-flow-state"
jq -n '{compact_state: "normal"}' > "$TC_DIR/.rite-compact-state"

OUTPUT=$(echo '{"cwd": "'"$TC_DIR"'", "source": "auto"}' | bash "$HOOK" 2>/dev/null) || true
if [ -z "$OUTPUT" ]; then
  pass "no stdout output for normal state"
else
  fail "unexpected stdout: $OUTPUT"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
