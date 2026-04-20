#!/bin/bash
# tests/hooks/test-stop-guard-cleanup.sh
# Unit test for stop-guard.sh block behavior during cleanup Phase 4.W.
# Issue #621: AC-3 automation (stop-guard が cleanup_pre_ingest / cleanup_post_ingest
# phase で end_turn を block し、session log にその痕跡が残ることを verify)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STOP_GUARD="$REPO_ROOT/plugins/rite/hooks/stop-guard.sh"

if [ ! -x "$STOP_GUARD" ]; then
  echo "FAIL: stop-guard.sh not executable at $STOP_GUARD" >&2
  exit 1
fi

# Isolated fixture workspace
FIXTURE_DIR=$(mktemp -d /tmp/rite-test-stop-guard-XXXXXX)
cleanup() { rm -rf "$FIXTURE_DIR"; }
trap cleanup EXIT INT TERM

SESSION_ID="00000000-0000-0000-0000-000000000001"

# Fabricate .rite-flow-state for the given phase with active=true
# $1: phase name
# $2: previous_phase (for whitelist check)
make_state() {
  local phase="$1"
  local prev="${2:-cleanup}"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")
  cat > "$FIXTURE_DIR/.rite-flow-state" <<EOF
{
  "active": true,
  "issue_number": 621,
  "branch": "fix/issue-621-test",
  "phase": "$phase",
  "previous_phase": "$prev",
  "pr_number": 0,
  "parent_issue_number": 0,
  "next_action": "test fixture",
  "updated_at": "$ts",
  "session_id": "$SESSION_ID",
  "error_count": 0
}
EOF
}

# Run stop-guard with a constructed hook input JSON, capture exit + stderr
# $1: phase
# $2: previous_phase
run_guard() {
  local phase="$1"
  local prev="$2"
  make_state "$phase" "$prev"
  local input
  input=$(printf '{"cwd":"%s","session_id":"%s"}' "$FIXTURE_DIR" "$SESSION_ID")
  local stderr_file
  stderr_file=$(mktemp /tmp/rite-test-stop-guard-err-XXXXXX)
  printf '%s' "$input" | bash "$STOP_GUARD" 2>"$stderr_file"
  local rc=$?
  STDERR_CONTENT=$(cat "$stderr_file")
  rm -f "$stderr_file"
  return "$rc"
}

# Assertion helpers
PASS=0
FAIL=0
assert() {
  local name="$1"
  local expected="$2"
  local actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    echo "ok  - $name"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL - $name (expected: $expected, actual: $actual)"
  fi
}
assert_contains() {
  local name="$1"
  local needle="$2"
  local haystack="$3"
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    PASS=$((PASS + 1))
    echo "ok  - $name"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL - $name (missing: $needle)"
    printf '  stderr: %s\n' "$haystack" | head -5
  fi
}

# Test 1: cleanup_pre_ingest phase should block with exit 2
echo "# Test 1: cleanup_pre_ingest blocks end_turn"
run_guard "cleanup_pre_ingest" "cleanup"
rc=$?
assert "cleanup_pre_ingest exits 2" "2" "$rc"
assert_contains "stderr contains Phase:" "Phase:" "$STDERR_CONTENT"
assert_contains "stderr contains cleanup_pre_ingest" "cleanup_pre_ingest" "$STDERR_CONTENT"

# Test 2: cleanup_post_ingest phase should block with exit 2
echo "# Test 2: cleanup_post_ingest blocks end_turn"
run_guard "cleanup_post_ingest" "cleanup_pre_ingest"
rc=$?
assert "cleanup_post_ingest exits 2" "2" "$rc"
assert_contains "stderr contains Phase:" "Phase:" "$STDERR_CONTENT"
assert_contains "stderr contains cleanup_post_ingest" "cleanup_post_ingest" "$STDERR_CONTENT"

# Test 3: cleanup phase (Phase 1-4 protection) should also block
echo "# Test 3: cleanup phase blocks end_turn"
run_guard "cleanup" ""
rc=$?
assert "cleanup exits 2" "2" "$rc"
assert_contains "stderr contains Phase:" "Phase:" "$STDERR_CONTENT"

# Test 4: cleanup_completed with active=false should allow stop (exit 0)
echo "# Test 4: cleanup_completed + active:false allows stop"
cat > "$FIXTURE_DIR/.rite-flow-state" <<EOF
{
  "active": false,
  "issue_number": 621,
  "branch": "fix/issue-621-test",
  "phase": "cleanup_completed",
  "previous_phase": "cleanup_post_ingest",
  "pr_number": 0,
  "parent_issue_number": 0,
  "next_action": "none",
  "updated_at": "$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")",
  "session_id": "$SESSION_ID",
  "error_count": 0
}
EOF
input=$(printf '{"cwd":"%s","session_id":"%s"}' "$FIXTURE_DIR" "$SESSION_ID")
stderr_file=$(mktemp /tmp/rite-test-stop-guard-err-XXXXXX)
printf '%s' "$input" | bash "$STOP_GUARD" 2>"$stderr_file"
rc=$?
rm -f "$stderr_file"
assert "cleanup_completed (active:false) exits 0" "0" "$rc"

echo ""
echo "# Summary: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
