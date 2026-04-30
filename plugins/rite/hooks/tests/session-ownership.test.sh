#!/bin/bash
# Tests for session-ownership.sh helper library
# Usage: bash plugins/rite/hooks/tests/session-ownership.test.sh
#
# Coverage:
#   - extract_session_id        (hook JSON parsing)
#   - get_state_session_id      (state file parsing)
#   - is_per_session_state_file (Issue #681 path predicate)
#   - check_session_ownership   (4-state legacy + per-session fast-path)
#   - parse_iso8601_to_epoch    (timezone normalization)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$SCRIPT_DIR/../session-ownership.sh"
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
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

pass() {
  PASS=$((PASS + 1))
  echo "  ✅ PASS: $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "  ❌ FAIL: $1"
}

# Source the library under test
# shellcheck source=../session-ownership.sh
source "$LIB"

echo "=== session-ownership.sh tests ==="
echo ""

# --- TC-001: is_per_session_state_file matches per-session pattern ---
echo "TC-001: is_per_session_state_file matches /<root>/.rite/sessions/<sid>.flow-state"
if is_per_session_state_file "/tmp/repo/.rite/sessions/00000000-0000-4000-8000-000000000001.flow-state"; then
  pass "Per-session path matched"
else
  fail "Per-session path should match"
fi
echo ""

# --- TC-002: is_per_session_state_file rejects legacy path ---
echo "TC-002: is_per_session_state_file rejects /<root>/.rite-flow-state"
if is_per_session_state_file "/tmp/repo/.rite-flow-state"; then
  fail "Legacy path should not match per-session pattern"
else
  pass "Legacy path correctly rejected"
fi
echo ""

# --- TC-003: is_per_session_state_file rejects empty/unrelated paths ---
echo "TC-003: is_per_session_state_file rejects empty / unrelated paths"
all_ok=1
if is_per_session_state_file ""; then all_ok=0; fi
if is_per_session_state_file "/some/random/path.txt"; then all_ok=0; fi
if is_per_session_state_file "/tmp/.rite/sessions/foo.txt"; then all_ok=0; fi  # missing .flow-state suffix
if [ "$all_ok" = "1" ]; then
  pass "Empty / unrelated paths correctly rejected"
else
  fail "Empty or unrelated paths should not match"
fi
echo ""

# --- TC-003b: is_per_session_state_file edge cases (empty SID part, non-UUID-like) ---
# Issue #681 F-06: the predicate uses path pattern matching only, so it accepts
# any non-empty SID-like segment between `/sessions/` and `.flow-state`. These
# tests pin the current behavior so future SID validation tightening can be
# detected as a deliberate change.
echo "TC-003b: is_per_session_state_file edge cases — empty SID segment is accepted by current path-pattern semantics"
# `/.rite/sessions/.flow-state` has an empty SID segment. The current case glob
# `*/.rite/sessions/*.flow-state` does not enforce non-empty SID, so this matches.
# Asserting the *current* behavior here documents the contract; if the predicate
# is later strengthened to require a non-empty UUID-like segment, this test will
# fail and force an explicit decision.
if is_per_session_state_file "/repo/.rite/sessions/.flow-state"; then
  pass "Empty SID segment is currently accepted (documented behavior, future SID validation may tighten this)"
else
  fail "Empty SID segment is rejected — predicate semantics changed unexpectedly"
fi
# Non-UUID-like SID (e.g. arbitrary string) is also accepted by the current
# pattern-only check. Document this for the same reason.
if is_per_session_state_file "/repo/.rite/sessions/not-a-uuid.flow-state"; then
  pass "Non-UUID SID segment is currently accepted (documented behavior)"
else
  fail "Non-UUID SID segment is rejected — predicate semantics changed unexpectedly"
fi
echo ""

# --- TC-004: check_session_ownership returns "own" for per-session file (matching SID fast-path) ---
# Issue #681: structurally-owned per-session files bypass the 4-state legacy check.
# When the hook payload's session_id matches the filename's session_id segment,
# the fast-path returns "own" without consulting the file body.
echo "TC-004: check_session_ownership returns 'own' for per-session path with matching SID"
sid_match="00000000-0000-4000-8000-000000000004"
hook_json="{\"session_id\": \"$sid_match\"}"
ps_path="/tmp/repo/.rite/sessions/${sid_match}.flow-state"
result=$(check_session_ownership "$hook_json" "$ps_path")
if [ "$result" = "own" ]; then
  pass "Per-session path with matching SID returns 'own' (structural fast-path)"
else
  fail "Expected 'own' for matching per-session path, got '$result'"
fi
echo ""

# --- TC-004b: check_session_ownership returns "other" for foreign per-session file (defense-in-depth) ---
# Issue #681 F-02: when the hook payload's session_id is non-empty AND does not match
# the filename's session_id segment, the fast-path defense-in-depth branch must
# return "other" rather than silently classifying as "own". This prevents a future
# caller bypassing the resolver from being misclassified as own (AC-4 alignment).
echo "TC-004b: check_session_ownership returns 'other' for foreign per-session path (defense-in-depth)"
sid_self="00000000-0000-4000-8000-000000000004b1"
sid_other="00000000-0000-4000-8000-000000000004b2"
hook_json="{\"session_id\": \"$sid_self\"}"
foreign_ps_path="/tmp/repo/.rite/sessions/${sid_other}.flow-state"
result=$(check_session_ownership "$hook_json" "$foreign_ps_path")
if [ "$result" = "other" ]; then
  pass "Foreign per-session path returns 'other' (filename SID mismatch detected)"
else
  fail "Expected 'other' for foreign per-session path, got '$result'"
fi
echo ""

# --- TC-004c: check_session_ownership returns "own" for per-session file with empty hook SID ---
# Backward-compat: when hook_json lacks session_id (legacy hook input), fall through
# to "own" — same behavior as legacy 4-state classification's "can't determine, assume own"
# branch.
echo "TC-004c: check_session_ownership returns 'own' for per-session path with empty hook SID"
hook_json='{}'
ps_path="/tmp/repo/.rite/sessions/some-session-uuid.flow-state"
result=$(check_session_ownership "$hook_json" "$ps_path")
if [ "$result" = "own" ]; then
  pass "Per-session path with empty hook SID returns 'own' (backward-compat fast-path)"
else
  fail "Expected 'own' for per-session path with empty hook SID, got '$result'"
fi
echo ""

# --- TC-005: check_session_ownership uses 4-state classification for legacy paths ---
echo "TC-005: check_session_ownership returns 'own' for legacy path with matching session_id"
state_file="$TEST_DIR/tc005.rite-flow-state"
cat > "$state_file" <<'STATE_EOF'
{
  "session_id": "session-aaa",
  "active": true,
  "updated_at": "2026-04-30T00:00:00+00:00"
}
STATE_EOF
hook_json='{"session_id": "session-aaa"}'
# Build a legacy-style path so the per-session fast-path is not hit
legacy_path="$TEST_DIR/.rite-flow-state"
cp "$state_file" "$legacy_path"
result=$(check_session_ownership "$hook_json" "$legacy_path")
if [ "$result" = "own" ]; then
  pass "Legacy path with matching SID returns 'own' (4-state classification preserved)"
else
  fail "Expected 'own', got '$result'"
fi
echo ""

# --- TC-006: check_session_ownership returns 'legacy' for state without session_id ---
echo "TC-006: check_session_ownership returns 'legacy' for state file missing session_id"
legacy_state="$TEST_DIR/tc006.rite-flow-state"
cat > "$legacy_state" <<'STATE_EOF'
{
  "active": true,
  "updated_at": "2026-04-30T00:00:00+00:00"
}
STATE_EOF
# Use a non-per-session path
hook_json='{"session_id": "current-uuid"}'
result=$(check_session_ownership "$hook_json" "$legacy_state")
if [ "$result" = "legacy" ]; then
  pass "Legacy state file (no session_id) returns 'legacy'"
else
  fail "Expected 'legacy', got '$result'"
fi
echo ""

# --- TC-007: check_session_ownership returns 'other' for foreign session within 2h ---
echo "TC-007: check_session_ownership returns 'other' for fresh foreign-session state"
foreign_state="$TEST_DIR/tc007.rite-flow-state"
fresh_ts=$(date -u -d '5 minutes ago' +"%Y-%m-%dT%H:%M:%S+00:00" 2>/dev/null \
  || date -u -v-5M +"%Y-%m-%dT%H:%M:%S+00:00")
cat > "$foreign_state" <<STATE_EOF
{
  "session_id": "foreign-session",
  "active": true,
  "updated_at": "$fresh_ts"
}
STATE_EOF
hook_json='{"session_id": "current-session"}'
result=$(check_session_ownership "$hook_json" "$foreign_state")
if [ "$result" = "other" ]; then
  pass "Fresh foreign-session state returns 'other'"
else
  fail "Expected 'other', got '$result'"
fi
echo ""

# --- TC-008: check_session_ownership returns 'stale' for foreign session > 2h ---
echo "TC-008: check_session_ownership returns 'stale' for foreign-session state > 2h old"
stale_state="$TEST_DIR/tc008.rite-flow-state"
stale_ts=$(date -u -d '3 hours ago' +"%Y-%m-%dT%H:%M:%S+00:00" 2>/dev/null \
  || date -u -v-3H +"%Y-%m-%dT%H:%M:%S+00:00")
cat > "$stale_state" <<STATE_EOF
{
  "session_id": "foreign-session",
  "active": true,
  "updated_at": "$stale_ts"
}
STATE_EOF
hook_json='{"session_id": "current-session"}'
result=$(check_session_ownership "$hook_json" "$stale_state")
if [ "$result" = "stale" ]; then
  pass "Stale foreign-session state (>2h) returns 'stale'"
else
  fail "Expected 'stale', got '$result'"
fi
echo ""

# --- TC-009: extract_session_id parses session_id from hook JSON ---
echo "TC-009: extract_session_id parses .session_id from hook JSON"
sid=$(extract_session_id '{"session_id": "abc-123", "tool_name": "Bash"}')
if [ "$sid" = "abc-123" ]; then
  pass "extract_session_id correctly returns abc-123"
else
  fail "Expected abc-123, got '$sid'"
fi
sid_empty=$(extract_session_id '{"tool_name": "Bash"}')
if [ -z "$sid_empty" ]; then
  pass "extract_session_id returns empty string when session_id absent"
else
  fail "Expected empty, got '$sid_empty'"
fi
echo ""

# --- TC-010: get_state_session_id parses session_id from state file ---
echo "TC-010: get_state_session_id parses session_id from state file"
gsid_file="$TEST_DIR/tc010.state"
cat > "$gsid_file" <<'STATE_EOF'
{ "session_id": "state-session-xyz", "active": true }
STATE_EOF
gsid=$(get_state_session_id "$gsid_file")
if [ "$gsid" = "state-session-xyz" ]; then
  pass "get_state_session_id correctly returns state-session-xyz"
else
  fail "Expected state-session-xyz, got '$gsid'"
fi
gsid_missing=$(get_state_session_id "$TEST_DIR/nonexistent.state")
if [ -z "$gsid_missing" ]; then
  pass "get_state_session_id returns empty for missing file"
else
  fail "Expected empty for missing file, got '$gsid_missing'"
fi
echo ""

# --- TC-011: parse_iso8601_to_epoch handles +00:00 / +09:00 / Z suffix ---
echo "TC-011: parse_iso8601_to_epoch normalizes timezone offsets"
e1=$(parse_iso8601_to_epoch "2026-04-30T12:00:00+00:00")
e2=$(parse_iso8601_to_epoch "2026-04-30T21:00:00+09:00")
e3=$(parse_iso8601_to_epoch "2026-04-30T12:00:00Z")
# All three timestamps refer to the same instant: 2026-04-30 12:00 UTC
if [ "$e1" = "$e2" ] && [ "$e1" = "$e3" ] && [ "$e1" != "0" ]; then
  pass "Equivalent timestamps yield identical epoch ($e1)"
else
  fail "Epoch normalization failed: e1=$e1 e2=$e2 e3=$e3"
fi
e_invalid=$(parse_iso8601_to_epoch "not-a-timestamp")
if [ "$e_invalid" = "0" ]; then
  pass "Invalid timestamp returns 0"
else
  fail "Expected 0 for invalid timestamp, got '$e_invalid'"
fi
echo ""

# --- Summary ---
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
