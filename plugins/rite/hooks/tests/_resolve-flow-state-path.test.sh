#!/bin/bash
# Tests for _resolve-flow-state-path.sh
# Usage: bash plugins/rite/hooks/tests/_resolve-flow-state-path.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../_resolve-flow-state-path.sh"
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ FAIL: $1"; }

# Helper: create a per-session test fixture with schema_version=2 + given session_id
# Args: $1 = test-dir, $2 = session_id (optional, default valid UUID), $3 = create_per_session (true/false)
make_fixture_v2() {
  local dir="$1"
  local sid="${2:-11111111-2222-3333-4444-555555555555}"
  local create_per="${3:-false}"
  mkdir -p "$dir"
  printf '%s' "$sid" > "$dir/.rite-session-id"
  cat > "$dir/rite-config.yml" <<EOF
flow_state:
  schema_version: 2
EOF
  if [ "$create_per" = "true" ]; then
    mkdir -p "$dir/.rite/sessions"
    echo '{"active":true}' > "$dir/.rite/sessions/${sid}.flow-state"
  fi
}

# Helper: create a v1 (legacy) fixture
make_fixture_v1() {
  local dir="$1"
  mkdir -p "$dir"
  # No rite-config.yml = schema_version=1 by default
}

echo "=== _resolve-flow-state-path.sh tests ==="
echo ""

# --- TC-001: Missing argument → exit 1 ---
echo "TC-001: Missing argument → exit 1"
if bash "$HELPER" 2>/dev/null; then
  fail "Expected exit 1 for missing argument"
else
  pass "exit 1 on missing argument"
fi
echo ""

# --- TC-002: schema_version=1 (no rite-config.yml) → legacy path ---
echo "TC-002: No rite-config.yml → legacy path"
dir002="$TEST_DIR/tc002"
make_fixture_v1 "$dir002"
result=$(bash "$HELPER" "$dir002")
expected="$dir002/.rite-flow-state"
if [ "$result" = "$expected" ]; then
  pass "v1 default → legacy path returned"
else
  fail "Expected '$expected', got '$result'"
fi
echo ""

# --- TC-003: schema_version=1 explicit → legacy path ---
echo "TC-003: Explicit schema_version=1 → legacy path"
dir003="$TEST_DIR/tc003"
mkdir -p "$dir003"
cat > "$dir003/rite-config.yml" <<EOF
flow_state:
  schema_version: 1
EOF
result=$(bash "$HELPER" "$dir003")
expected="$dir003/.rite-flow-state"
if [ "$result" = "$expected" ]; then
  pass "v1 explicit → legacy path"
else
  fail "Expected '$expected', got '$result'"
fi
echo ""

# --- TC-004: schema_version=2 + valid SID + per-session file exists → per-session ---
echo "TC-004: v2 + valid SID + per-session present → per-session path"
dir004="$TEST_DIR/tc004"
sid004="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
make_fixture_v2 "$dir004" "$sid004" "true"
result=$(bash "$HELPER" "$dir004")
expected="$dir004/.rite/sessions/${sid004}.flow-state"
if [ "$result" = "$expected" ]; then
  pass "per-session path returned when file exists"
else
  fail "Expected '$expected', got '$result'"
fi
echo ""

# --- TC-005: schema_version=2 + valid SID + per-session ABSENT + legacy exists → legacy fallback ---
echo "TC-005: v2 + valid SID + per-session absent + legacy present → legacy"
dir005="$TEST_DIR/tc005"
make_fixture_v2 "$dir005" "" "false"
echo '{"active":true}' > "$dir005/.rite-flow-state"
result=$(bash "$HELPER" "$dir005")
expected="$dir005/.rite-flow-state"
if [ "$result" = "$expected" ]; then
  pass "legacy fallback when per-session absent (mid-migration window)"
else
  fail "Expected '$expected', got '$result'"
fi
echo ""

# --- TC-006: schema_version=2 + valid SID + neither file exists → per-session path (for fresh writes) ---
echo "TC-006: v2 + valid SID + neither file → per-session path (writers create)"
dir006="$TEST_DIR/tc006"
sid006="00112233-4455-6677-8899-aabbccddeeff"
make_fixture_v2 "$dir006" "$sid006" "false"
result=$(bash "$HELPER" "$dir006")
expected="$dir006/.rite/sessions/${sid006}.flow-state"
if [ "$result" = "$expected" ]; then
  pass "per-session path returned for fresh writes (file absent)"
else
  fail "Expected '$expected', got '$result'"
fi
echo ""

# --- TC-007: schema_version=2 + invalid SID (non-UUID) → legacy path ---
echo "TC-007: v2 + invalid SID → legacy fallback"
dir007="$TEST_DIR/tc007"
mkdir -p "$dir007"
echo "not-a-uuid" > "$dir007/.rite-session-id"
cat > "$dir007/rite-config.yml" <<EOF
flow_state:
  schema_version: 2
EOF
result=$(bash "$HELPER" "$dir007")
expected="$dir007/.rite-flow-state"
if [ "$result" = "$expected" ]; then
  pass "legacy fallback on invalid SID (non-UUID)"
else
  fail "Expected '$expected', got '$result'"
fi
echo ""

# --- TC-008: schema_version=2 + missing .rite-session-id → legacy path ---
echo "TC-008: v2 + no .rite-session-id → legacy fallback"
dir008="$TEST_DIR/tc008"
mkdir -p "$dir008"
cat > "$dir008/rite-config.yml" <<EOF
flow_state:
  schema_version: 2
EOF
# No .rite-session-id file
result=$(bash "$HELPER" "$dir008")
expected="$dir008/.rite-flow-state"
if [ "$result" = "$expected" ]; then
  pass "legacy fallback when .rite-session-id missing"
else
  fail "Expected '$expected', got '$result'"
fi
echo ""

# --- TC-009: schema_version=2 + empty .rite-session-id → legacy path ---
echo "TC-009: v2 + empty .rite-session-id → legacy fallback"
dir009="$TEST_DIR/tc009"
mkdir -p "$dir009"
echo "" > "$dir009/.rite-session-id"
cat > "$dir009/rite-config.yml" <<EOF
flow_state:
  schema_version: 2
EOF
result=$(bash "$HELPER" "$dir009")
expected="$dir009/.rite-flow-state"
if [ "$result" = "$expected" ]; then
  pass "legacy fallback when .rite-session-id empty"
else
  fail "Expected '$expected', got '$result'"
fi
echo ""

# --- TC-010: STATE_ROOT path traversal attempt → rejected by _validate-state-root.sh ---
echo "TC-010: Path traversal STATE_ROOT → rejected"
if bash "$HELPER" "../../etc" 2>/dev/null; then
  fail "Path traversal should be rejected"
else
  pass "Path traversal rejected"
fi
echo ""

# --- TC-011: schema_version=2 + invalid value (e.g., "abc") → defaults to legacy ---
echo "TC-011: schema_version=invalid → legacy fallback"
dir011="$TEST_DIR/tc011"
mkdir -p "$dir011"
sid011="aaaabbbb-cccc-dddd-eeee-ffffaaaabbbb"
echo "$sid011" > "$dir011/.rite-session-id"
cat > "$dir011/rite-config.yml" <<EOF
flow_state:
  schema_version: abc
EOF
result=$(bash "$HELPER" "$dir011")
expected="$dir011/.rite-flow-state"
if [ "$result" = "$expected" ]; then
  pass "Invalid schema_version → legacy"
else
  fail "Expected '$expected', got '$result'"
fi
echo ""

# --- TC-012: Stable output (idempotent) — calling twice returns identical path ---
echo "TC-012: Idempotent output (called twice)"
dir012="$TEST_DIR/tc012"
sid012="12121212-3434-3434-5656-787878787878"
make_fixture_v2 "$dir012" "$sid012" "true"
r1=$(bash "$HELPER" "$dir012")
r2=$(bash "$HELPER" "$dir012")
if [ "$r1" = "$r2" ]; then
  pass "Idempotent: identical output across calls"
else
  fail "Output diverged: '$r1' vs '$r2'"
fi
echo ""

# --- Summary ---
echo "=== Results: $PASS passed, $FAIL failed ==="
[ $FAIL -eq 0 ]
