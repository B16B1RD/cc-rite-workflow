#!/bin/bash
# Tests for workflow-incident-emit.sh (#366)
# Usage: bash plugins/rite/hooks/tests/workflow-incident-emit.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../workflow-incident-emit.sh"
TEST_DIR="$(mktemp -d)"
STDERR_FILE="$TEST_DIR/stderr"
PASS=0
FAIL=0

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

echo "=== workflow-incident-emit.sh tests ==="
echo ""

# --------------------------------------------------------------------------
# TC-001: Basic skill_load_failure sentinel
# --------------------------------------------------------------------------
# stdout / stderr 分離パターン (cycle 1 review M2 fix - pre-tool-bash-guard.test.sh と同型)
echo "TC-001: skill_load_failure → sentinel with required fields"
output=$(bash "$HOOK" --type skill_load_failure --details "rite:pr:fix loader error" 2>"$STDERR_FILE")
if echo "$output" | grep -qE '^\[CONTEXT\] WORKFLOW_INCIDENT=1; type=skill_load_failure; details=rite:pr:fix loader error; iteration_id=0-[0-9]+$'; then
  pass "skill_load_failure sentinel format correct"
else
  fail "Unexpected output: $output (stderr: $(cat "$STDERR_FILE"))"
fi
echo ""

# --------------------------------------------------------------------------
# TC-002: hook_abnormal_exit with root_cause_hint
# --------------------------------------------------------------------------
echo "TC-002: hook_abnormal_exit + root_cause_hint → sentinel includes hint"
output=$(bash "$HOOK" --type hook_abnormal_exit --details "guard exit 1" --root-cause-hint "missing arg" 2>"$STDERR_FILE")
if echo "$output" | grep -qE '^\[CONTEXT\] WORKFLOW_INCIDENT=1; type=hook_abnormal_exit; details=guard exit 1; root_cause_hint=missing arg; iteration_id=0-[0-9]+$'; then
  pass "hook_abnormal_exit with hint emits correctly"
else
  fail "Unexpected output: $output (stderr: $(cat "$STDERR_FILE"))"
fi
echo ""

# --------------------------------------------------------------------------
# TC-003: manual_fallback_adopted with --pr-number
# --------------------------------------------------------------------------
echo "TC-003: manual_fallback_adopted + --pr-number → iteration_id includes PR"
output=$(bash "$HOOK" --type manual_fallback_adopted --details "Edit fallback" --pr-number 363 2>"$STDERR_FILE")
if echo "$output" | grep -qE '^\[CONTEXT\] WORKFLOW_INCIDENT=1; type=manual_fallback_adopted; details=Edit fallback; iteration_id=363-[0-9]+$'; then
  pass "iteration_id format includes PR number"
else
  fail "Unexpected output: $output (stderr: $(cat "$STDERR_FILE"))"
fi
echo ""

# --------------------------------------------------------------------------
# TC-004: Missing --type → exit 1
# --------------------------------------------------------------------------
echo "TC-004: Missing --type → exit 1 with error message"
output=$(bash "$HOOK" --details "no type" 2>&1) && rc=0 || rc=$?
if [ "$rc" -eq 1 ] && echo "$output" | grep -q "ERROR: --type is required"; then
  pass "Missing --type exits 1 with error"
else
  fail "Expected exit 1 with error, got rc=$rc output='$output'"
fi
echo ""

# --------------------------------------------------------------------------
# TC-005: Missing --details → exit 1
# --------------------------------------------------------------------------
echo "TC-005: Missing --details → exit 1 with error message"
output=$(bash "$HOOK" --type skill_load_failure 2>&1) && rc=0 || rc=$?
if [ "$rc" -eq 1 ] && echo "$output" | grep -q "ERROR: --details is required"; then
  pass "Missing --details exits 1 with error"
else
  fail "Expected exit 1 with error, got rc=$rc output='$output'"
fi
echo ""

# --------------------------------------------------------------------------
# TC-006: Invalid --type → exit 1
# --------------------------------------------------------------------------
echo "TC-006: Invalid --type → exit 1 with error message"
output=$(bash "$HOOK" --type bogus_type --details "x" 2>&1) && rc=0 || rc=$?
if [ "$rc" -eq 1 ] && echo "$output" | grep -q "ERROR: Invalid --type"; then
  pass "Invalid --type exits 1 with error"
else
  fail "Expected exit 1 with error, got rc=$rc output='$output'"
fi
echo ""

# --------------------------------------------------------------------------
# TC-007: Invalid --pr-number (non-integer) → exit 1
# --------------------------------------------------------------------------
echo "TC-007: Invalid --pr-number (non-integer) → exit 1"
output=$(bash "$HOOK" --type skill_load_failure --details "x" --pr-number "abc" 2>&1) && rc=0 || rc=$?
if [ "$rc" -eq 1 ] && echo "$output" | grep -q "ERROR: --pr-number must be a non-negative integer"; then
  pass "Invalid --pr-number exits 1"
else
  fail "Expected exit 1, got rc=$rc output='$output'"
fi
echo ""

# --------------------------------------------------------------------------
# TC-008: Unknown option → exit 1
# --------------------------------------------------------------------------
echo "TC-008: Unknown option → exit 1"
output=$(bash "$HOOK" --type skill_load_failure --details "x" --unknown-flag value 2>&1) && rc=0 || rc=$?
if [ "$rc" -eq 1 ] && echo "$output" | grep -q "ERROR: Unknown option"; then
  pass "Unknown option exits 1"
else
  fail "Expected exit 1, got rc=$rc output='$output'"
fi
echo ""

# --------------------------------------------------------------------------
# TC-009: Sanitization — semicolons in details replaced by commas
# --------------------------------------------------------------------------
echo "TC-009: Semicolons in --details replaced by commas (parser safety)"
output=$(bash "$HOOK" --type skill_load_failure --details "a; b; c" 2>&1)
# Sentinel must have exactly 3 semicolons (separators) — none from details
sentinel_only=$(echo "$output" | grep '^\[CONTEXT\]')
sep_count=$(echo "$sentinel_only" | tr -cd ';' | wc -c)
if [ "$sep_count" -eq 3 ] && echo "$output" | grep -q "details=a, b, c;"; then
  pass "Semicolons in details sanitized to commas"
else
  fail "Sanitization failed. sep_count=$sep_count output='$output'"
fi
echo ""

# --------------------------------------------------------------------------
# TC-010: Sanitization — newlines stripped from root_cause_hint
# --------------------------------------------------------------------------
echo "TC-010: Newlines in --root-cause-hint stripped"
output=$(bash "$HOOK" --type hook_abnormal_exit --details "x" --root-cause-hint "$(printf 'line1\nline2')" 2>&1)
# Output must be a single line
line_count=$(echo "$output" | wc -l)
if [ "$line_count" -eq 1 ] && echo "$output" | grep -q "root_cause_hint=line1line2"; then
  pass "Newlines in root_cause_hint stripped"
else
  fail "Newline sanitization failed. line_count=$line_count output='$output'"
fi
echo ""

# --------------------------------------------------------------------------
# TC-011: iteration_id epoch is reasonable (within ±60s of current time)
# --------------------------------------------------------------------------
echo "TC-011: iteration_id epoch is current Unix time"
before=$(date +%s)
output=$(bash "$HOOK" --type skill_load_failure --details "epoch test" 2>&1)
after=$(date +%s)
epoch=$(echo "$output" | grep -oE 'iteration_id=0-[0-9]+' | grep -oE '[0-9]+$')
if [ -n "$epoch" ] && [ "$epoch" -ge "$before" ] && [ "$epoch" -le "$after" ]; then
  pass "iteration_id epoch within expected range"
else
  fail "epoch=$epoch not in [$before, $after]"
fi
echo ""

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
echo ""

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
