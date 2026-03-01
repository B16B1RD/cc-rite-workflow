#!/bin/bash
# Tests for work-memory-lock.sh
# Usage: bash plugins/rite/hooks/tests/work-memory-lock.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCK_SH="$SCRIPT_DIR/../work-memory-lock.sh"
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0

# Source the lock functions once (they are idempotent)
source "$LOCK_SH"

# Save default threshold for restoration after tests that modify it
DEFAULT_WM_LOCK_STALE_THRESHOLD="${WM_LOCK_STALE_THRESHOLD:-120}"

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

echo "=== work-memory-lock.sh tests ==="
echo ""

# --------------------------------------------------------------------------
# TC-001: acquire_wm_lock creates lockdir and returns 0
# --------------------------------------------------------------------------
echo "TC-001: acquire_wm_lock creates lockdir and returns 0"
lockdir="$TEST_DIR/tc001.lock"
if acquire_wm_lock "$lockdir" 5; then
  if [ -d "$lockdir" ]; then
    pass "Lock acquired, lockdir exists"
  else
    fail "Lock acquired but lockdir not found"
  fi
  release_wm_lock "$lockdir"
else
  fail "acquire_wm_lock returned non-zero"
fi
echo ""

# --------------------------------------------------------------------------
# TC-002: release_wm_lock removes lockdir
# --------------------------------------------------------------------------
echo "TC-002: release_wm_lock removes lockdir"
lockdir="$TEST_DIR/tc002.lock"
acquire_wm_lock "$lockdir" 5
release_wm_lock "$lockdir"
if [ ! -d "$lockdir" ]; then
  pass "Lock released, lockdir removed"
else
  fail "lockdir still exists after release"
fi
echo ""

# --------------------------------------------------------------------------
# TC-003: is_wm_locked returns true when locked
# --------------------------------------------------------------------------
echo "TC-003: is_wm_locked returns true when locked"
lockdir="$TEST_DIR/tc003.lock"
acquire_wm_lock "$lockdir" 5
if is_wm_locked "$lockdir"; then
  pass "is_wm_locked returns true when locked"
else
  fail "is_wm_locked returned false when locked"
fi
release_wm_lock "$lockdir"
echo ""

# --------------------------------------------------------------------------
# TC-004: is_wm_locked returns false when not locked
# --------------------------------------------------------------------------
echo "TC-004: is_wm_locked returns false when not locked"
lockdir="$TEST_DIR/tc004.lock"
if is_wm_locked "$lockdir"; then
  fail "is_wm_locked returned true when not locked"
else
  pass "is_wm_locked returns false when not locked"
fi
echo ""

# --------------------------------------------------------------------------
# TC-005: PID file is written inside lockdir
# --------------------------------------------------------------------------
echo "TC-005: PID file is written inside lockdir"
lockdir="$TEST_DIR/tc005.lock"
acquire_wm_lock "$lockdir" 5
if [ -f "$lockdir/pid" ]; then
  pid_content=$(cat "$lockdir/pid")
  if [[ "$pid_content" =~ ^[0-9]+$ ]]; then
    pass "PID file exists with numeric content: $pid_content"
  else
    fail "PID file has non-numeric content: $pid_content"
  fi
else
  fail "PID file not created in lockdir"
fi
release_wm_lock "$lockdir"
echo ""

# --------------------------------------------------------------------------
# TC-006: release_wm_lock removes PID file
# --------------------------------------------------------------------------
echo "TC-006: release_wm_lock removes PID file"
lockdir="$TEST_DIR/tc006.lock"
acquire_wm_lock "$lockdir" 5
release_wm_lock "$lockdir"
if [ ! -f "$lockdir/pid" ]; then
  pass "PID file removed after release"
else
  fail "PID file still exists after release"
fi
echo ""

# --------------------------------------------------------------------------
# TC-007: Concurrent lock fails (second acquire returns 1)
# Note: With timeout=1, acquire_wm_lock retries once, then checks stale lock.
# Since the lock is fresh (not stale), acquisition fails as expected.
# --------------------------------------------------------------------------
echo "TC-007: Concurrent lock fails (second acquire returns 1)"
lockdir="$TEST_DIR/tc007.lock"
acquire_wm_lock "$lockdir" 5
# Attempt second acquire with minimal timeout (1 iteration)
# The lock is fresh so stale detection won't reclaim it → acquire fails
if acquire_wm_lock "$lockdir" 1; then
  fail "Second acquire should fail but succeeded"
else
  pass "Second acquire correctly failed (concurrent lock)"
fi
release_wm_lock "$lockdir"
echo ""

# --------------------------------------------------------------------------
# TC-008: Timeout with minimal iterations
# --------------------------------------------------------------------------
echo "TC-008: Timeout with minimal iterations (1 iteration)"
lockdir="$TEST_DIR/tc008.lock"
# Create lockdir manually to simulate held lock
# PID 999999999 is intentionally chosen as it exceeds typical OS PID limits
# (Linux default max: 4194304, most systems: 32768) to ensure it doesn't exist.
mkdir -p "$lockdir"
echo "999999999" > "$lockdir/pid"
if acquire_wm_lock "$lockdir" 1; then
  fail "Should have timed out but succeeded"
else
  pass "Timed out as expected after 1 iteration"
fi
rm -rf "$lockdir"
echo ""

# --------------------------------------------------------------------------
# TC-009: Stale lock detection (lock older than threshold)
# --------------------------------------------------------------------------
echo "TC-009: Stale lock detection (lock older than threshold)"
lockdir="$TEST_DIR/tc009.lock"
# Create a lockdir with old mtime
mkdir -p "$lockdir"
# Write a PID that doesn't exist (use a very high PID)
echo "999999999" > "$lockdir/pid"
# Set mtime to 2 minutes ago
touch -t "$(date -u -d '2 minutes ago' +'%Y%m%d%H%M' 2>/dev/null || date -u -v-2M +'%Y%m%d%H%M')" "$lockdir" 2>/dev/null || true
# Set stale threshold to 1 second for fast test
WM_LOCK_STALE_THRESHOLD=1
if acquire_wm_lock "$lockdir" 2; then
  pass "Stale lock detected and recovered"
  release_wm_lock "$lockdir"
else
  fail "Failed to recover stale lock"
  rm -rf "$lockdir"
fi
# Reset threshold
WM_LOCK_STALE_THRESHOLD="$DEFAULT_WM_LOCK_STALE_THRESHOLD"
echo ""

# --------------------------------------------------------------------------
# TC-010: Stale lock with live process is NOT removed
# --------------------------------------------------------------------------
echo "TC-010: Stale lock with live process is NOT removed"
lockdir="$TEST_DIR/tc010.lock"
mkdir -p "$lockdir"
# Write current shell PID (which is alive)
echo "$$" > "$lockdir/pid"
# Set mtime to old
touch -t "$(date -u -d '5 minutes ago' +'%Y%m%d%H%M' 2>/dev/null || date -u -v-5M +'%Y%m%d%H%M')" "$lockdir" 2>/dev/null || true
WM_LOCK_STALE_THRESHOLD=1
if acquire_wm_lock "$lockdir" 2; then
  fail "Should not acquire lock when process is still alive"
  release_wm_lock "$lockdir"
else
  pass "Lock not acquired because PID $$ is still alive"
  rm -rf "$lockdir"
fi
WM_LOCK_STALE_THRESHOLD="$DEFAULT_WM_LOCK_STALE_THRESHOLD"
echo ""

# --------------------------------------------------------------------------
# TC-011: Stale lock without PID file is treated as stale
# --------------------------------------------------------------------------
echo "TC-011: Stale lock without PID file is treated as stale"
lockdir="$TEST_DIR/tc011.lock"
mkdir -p "$lockdir"
# No pid file — older version scenario
touch -t "$(date -u -d '5 minutes ago' +'%Y%m%d%H%M' 2>/dev/null || date -u -v-5M +'%Y%m%d%H%M')" "$lockdir" 2>/dev/null || true
WM_LOCK_STALE_THRESHOLD=1
if acquire_wm_lock "$lockdir" 2; then
  pass "Stale lock without PID file recovered"
  release_wm_lock "$lockdir"
else
  fail "Failed to recover stale lock without PID file"
  rm -rf "$lockdir"
fi
WM_LOCK_STALE_THRESHOLD="$DEFAULT_WM_LOCK_STALE_THRESHOLD"
echo ""

# --------------------------------------------------------------------------
# TC-012: Default timeout (50 iterations) parameter
# --------------------------------------------------------------------------
echo "TC-012: Default timeout parameter (no second argument)"
lockdir="$TEST_DIR/tc012.lock"
# Just verify it works without explicit timeout
if acquire_wm_lock "$lockdir"; then
  pass "acquire_wm_lock works with default timeout"
  release_wm_lock "$lockdir"
else
  fail "acquire_wm_lock failed with default timeout"
fi
echo ""

# --------------------------------------------------------------------------
# TC-013: release_wm_lock on non-existent lockdir is safe
# --------------------------------------------------------------------------
echo "TC-013: release_wm_lock on non-existent lockdir is safe (no error)"
lockdir="$TEST_DIR/tc013.lock"
# Release without acquiring — should not error, verify exit code explicitly
if release_wm_lock "$lockdir"; then
  pass "release_wm_lock on non-existent lockdir returns 0"
else
  fail "release_wm_lock on non-existent lockdir should return 0"
fi
echo ""

# --------------------------------------------------------------------------
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
