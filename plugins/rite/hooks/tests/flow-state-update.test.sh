#!/bin/bash
# Tests for flow-state-update.sh — multi-state (per-session file) API
# Covers Issue #678 acceptance criteria:
#   - AC-9       : atomic write integrity (new format)
#   - AC-LOCAL-1 : new create writes .rite/sessions/{id}.flow-state with schema_version: 2
#   - AC-LOCAL-2 : two parallel sessions keep state files independent
#   - AC-LOCAL-3 : --preserve-error-count retains error_count on same-phase self-patch
# Plus non-regression for legacy-mode, schema_version=1 config, increment mode,
# and patch mode session_id auto-read.
#
# Usage: bash plugins/rite/hooks/tests/flow-state-update.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../flow-state-update.sh"
PASS=0
FAIL=0

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi

# Each test uses its own TEST_DIR so failures don't pollute others.
make_test_dir() {
  local d
  d=$(mktemp -d)
  (
    cd "$d"
    git init -q
    echo a > a && git add a
    git -c user.email=t@test.local -c user.name=test commit -q -m init
  )
  echo "$d"
}

write_config() {
  # $1=test_dir, $2=schema_version (1 or 2 or "absent")
  local d="$1" sv="$2"
  if [[ "$sv" == "absent" ]]; then
    : > "$d/rite-config.yml"
  else
    cat > "$d/rite-config.yml" << EOF
flow_state:
  schema_version: $sv
EOF
  fi
}

write_session_id() {
  echo "$2" > "$1/.rite-session-id"
}

pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ FAIL: $1"; }

cleanup_dirs=()
cleanup() {
  local d
  for d in "${cleanup_dirs[@]:-}"; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
  done
}
trap cleanup EXIT

echo "=== flow-state-update.sh tests (multi-state API #678) ==="
echo ""

# --------------------------------------------------------------------------
# T-LOCAL-1 / AC-LOCAL-1: new create writes per-session file with schema_version: 2
# --------------------------------------------------------------------------
echo "T-LOCAL-1 (AC-LOCAL-1): create with schema_version=2 writes new format"
TD=$(make_test_dir); cleanup_dirs+=("$TD")
write_config "$TD" 2
SID="11111111-1111-1111-1111-111111111111"
write_session_id "$TD" "$SID"

(cd "$TD" && bash "$HOOK" create \
  --phase "create_interview" --issue 100 --branch "test" \
  --pr 0 --next "test" >/dev/null 2>&1)

NEW="$TD/.rite/sessions/$SID.flow-state"
LEG="$TD/.rite-flow-state"
if [ -f "$NEW" ] && [ ! -f "$LEG" ]; then
  pass "new format file created at .rite/sessions/{sid}.flow-state, legacy absent"
else
  fail "expected new format only; new=$([ -f "$NEW" ] && echo y || echo n) legacy=$([ -f "$LEG" ] && echo y || echo n)"
fi

if [ -f "$NEW" ] && [ "$(jq -r '.schema_version' "$NEW")" = "2" ]; then
  pass "schema_version: 2 present in new format object"
else
  fail "schema_version field missing or wrong: $([ -f "$NEW" ] && jq -r '.schema_version // \"absent\"' "$NEW")"
fi

# Required 11 fields from existing schema must all be present (drift guard)
if [ -f "$NEW" ]; then
  expected_fields="active issue_number branch phase previous_phase pr_number parent_issue_number next_action updated_at session_id last_synced_phase"
  missing=""
  for f in $expected_fields; do
    if ! jq -e "has(\"$f\")" "$NEW" >/dev/null 2>&1; then
      missing="$missing $f"
    fi
  done
  if [ -z "$missing" ]; then
    pass "all 11 required fields present"
  else
    fail "missing required fields:$missing"
  fi
fi

# --------------------------------------------------------------------------
# T-LOCAL-2 / AC-LOCAL-2: two parallel sessions keep files independent
# --------------------------------------------------------------------------
echo ""
echo "T-LOCAL-2 (AC-LOCAL-2): parallel sessions keep state independent"
TD=$(make_test_dir); cleanup_dirs+=("$TD")
write_config "$TD" 2
SID_A="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
SID_B="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

write_session_id "$TD" "$SID_A"
(cd "$TD" && bash "$HOOK" create \
  --phase "phase_a" --issue 1 --branch "ba" --pr 0 --next "na" >/dev/null 2>&1)

write_session_id "$TD" "$SID_B"
(cd "$TD" && bash "$HOOK" create \
  --phase "phase_b" --issue 2 --branch "bb" --pr 0 --next "nb" >/dev/null 2>&1)

A="$TD/.rite/sessions/$SID_A.flow-state"
B="$TD/.rite/sessions/$SID_B.flow-state"
if [ -f "$A" ] && [ -f "$B" ]; then
  pass "both session files created"
else
  fail "session files missing: a=$([ -f "$A" ] && echo y || echo n) b=$([ -f "$B" ] && echo y || echo n)"
fi

if [ "$(jq -r '.phase' "$A")" = "phase_a" ] && [ "$(jq -r '.phase' "$B")" = "phase_b" ]; then
  pass "both sessions retain independent phase values"
else
  fail "phase mismatch: a=$(jq -r '.phase' "$A" 2>/dev/null) b=$(jq -r '.phase' "$B" 2>/dev/null)"
fi

# Patching session B should not modify session A
write_session_id "$TD" "$SID_B"
(cd "$TD" && bash "$HOOK" patch \
  --phase "phase_b_post" --next "np" >/dev/null 2>&1)
if [ "$(jq -r '.phase' "$A")" = "phase_a" ] && [ "$(jq -r '.phase' "$B")" = "phase_b_post" ]; then
  pass "patch on session B leaves session A untouched"
else
  fail "isolation violated: a=$(jq -r '.phase' "$A") b=$(jq -r '.phase' "$B")"
fi

# --------------------------------------------------------------------------
# T-LOCAL-3 / AC-LOCAL-3: --preserve-error-count retains error_count on self-patch
# --------------------------------------------------------------------------
echo ""
echo "T-LOCAL-3 (AC-LOCAL-3): --preserve-error-count retains error_count"
TD=$(make_test_dir); cleanup_dirs+=("$TD")
write_config "$TD" 2
SID="22222222-2222-2222-2222-222222222222"
write_session_id "$TD" "$SID"

(cd "$TD" && bash "$HOOK" create \
  --phase "p" --issue 1 --branch "b" --pr 0 --next "n" >/dev/null 2>&1)
TARGET="$TD/.rite/sessions/$SID.flow-state"
tmp=$(mktemp); jq '.error_count = 5' "$TARGET" > "$tmp" && mv "$tmp" "$TARGET"

# Same-phase self-patch with --preserve-error-count → keeps 5
(cd "$TD" && bash "$HOOK" patch --phase "p" --next "n2" --preserve-error-count >/dev/null 2>&1)
ec=$(jq -r '.error_count' "$TARGET")
if [ "$ec" = "5" ]; then
  pass "--preserve-error-count keeps error_count=5"
else
  fail "--preserve-error-count dropped error_count: got $ec, expected 5"
fi

# Same-phase self-patch without --preserve-error-count → resets to 0
tmp=$(mktemp); jq '.error_count = 5' "$TARGET" > "$tmp" && mv "$tmp" "$TARGET"
(cd "$TD" && bash "$HOOK" patch --phase "p" --next "n3" >/dev/null 2>&1)
ec=$(jq -r '.error_count' "$TARGET")
if [ "$ec" = "0" ]; then
  pass "patch without preserve flag resets error_count to 0 (non-regression)"
else
  fail "default patch failed to reset: got $ec, expected 0"
fi

# --------------------------------------------------------------------------
# T-LOCAL-4 / AC-9: atomic write integrity — original preserved on jq failure
# --------------------------------------------------------------------------
echo ""
echo "T-LOCAL-4 (AC-9): atomic write keeps original intact when jq fails"
TD=$(make_test_dir); cleanup_dirs+=("$TD")
write_config "$TD" 2
SID="33333333-3333-3333-3333-333333333333"
write_session_id "$TD" "$SID"

(cd "$TD" && bash "$HOOK" create \
  --phase "intact_phase" --issue 1 --branch "b" --pr 0 --next "n" >/dev/null 2>&1)
TARGET="$TD/.rite/sessions/$SID.flow-state"
ORIG_HASH=$(sha256sum "$TARGET" | awk '{print $1}')

# Corrupt the file to make jq parse fail (simulates partial-write recovery)
# patch mode reads the file via jq; on parse failure the script must exit
# without mv-ing a partial temp into the target.
echo "{not valid json" > "$TARGET"
set +e
(cd "$TD" && bash "$HOOK" patch --phase "wont_apply" --next "n2" >/dev/null 2>&1)
rc=$?
set -e

# After jq failure: TARGET stays as corrupted content (we corrupted it deliberately)
# AND no orphan .rite-flow-state.XXXXXX temp remains.
orphan=$(ls "$TD/.rite/sessions/" 2>/dev/null | grep -E '\.flow-state\.[a-zA-Z0-9]{6,}$' || true)
if [ "$rc" -ne 0 ] && [ -z "$orphan" ]; then
  pass "patch mode exits non-zero on jq failure with no temp orphan"
else
  fail "rc=$rc orphan='$orphan'"
fi

# Restore valid JSON, then test create-mode behavior on simulated mv failure
# by making the parent directory read-only.
TD=$(make_test_dir); cleanup_dirs+=("$TD")
write_config "$TD" 2
SID="44444444-4444-4444-4444-444444444444"
write_session_id "$TD" "$SID"
(cd "$TD" && bash "$HOOK" create \
  --phase "v1" --issue 1 --branch "b" --pr 0 --next "n" >/dev/null 2>&1)
TARGET="$TD/.rite/sessions/$SID.flow-state"
V1_HASH=$(sha256sum "$TARGET" | awk '{print $1}')
V1_PHASE=$(jq -r '.phase' "$TARGET")

# Corrupt the existing state to a non-JSON form. create mode requires reading
# .phase via jq; parse failure must fail-fast without overwriting the file.
echo "{corrupt" > "$TARGET"
set +e
(cd "$TD" && bash "$HOOK" create \
  --phase "v2" --issue 1 --branch "b" --pr 0 --next "n" >/dev/null 2>&1)
rc2=$?
set -e
remaining=$(cat "$TARGET")
if [ "$rc2" -ne 0 ] && [ "$remaining" = "{corrupt" ]; then
  pass "create mode fail-fast on corrupt state preserves file content (no silent overwrite)"
else
  fail "rc2=$rc2 remaining='$remaining'"
fi

# --------------------------------------------------------------------------
# Non-regression: --legacy-mode forces legacy single-file path
# --------------------------------------------------------------------------
echo ""
echo "TC-NR-1: --legacy-mode forces .rite-flow-state regardless of schema_version=2"
TD=$(make_test_dir); cleanup_dirs+=("$TD")
write_config "$TD" 2
SID="55555555-5555-5555-5555-555555555555"
write_session_id "$TD" "$SID"

(cd "$TD" && bash "$HOOK" create \
  --phase "lp" --issue 1 --branch "b" --pr 0 --next "n" --legacy-mode >/dev/null 2>&1)
LEG="$TD/.rite-flow-state"
NEW="$TD/.rite/sessions/$SID.flow-state"
if [ -f "$LEG" ] && [ ! -f "$NEW" ]; then
  pass "--legacy-mode wrote legacy path, no new format file"
else
  fail "leg=$([ -f "$LEG" ] && echo y || echo n) new=$([ -f "$NEW" ] && echo y || echo n)"
fi

# Legacy create object MUST NOT contain schema_version (bytewise compat)
if [ -f "$LEG" ] && ! jq -e 'has("schema_version")' "$LEG" >/dev/null 2>&1; then
  pass "legacy object omits schema_version (bytewise compat with pre-#678 readers)"
else
  fail "legacy object has schema_version field (compat regression)"
fi

# --------------------------------------------------------------------------
# Non-regression: schema_version=1 in config writes legacy path
# --------------------------------------------------------------------------
echo ""
echo "TC-NR-2: rite-config.yml schema_version=1 writes legacy path"
TD=$(make_test_dir); cleanup_dirs+=("$TD")
write_config "$TD" 1
SID="66666666-6666-6666-6666-666666666666"
write_session_id "$TD" "$SID"

(cd "$TD" && bash "$HOOK" create \
  --phase "p" --issue 1 --branch "b" --pr 0 --next "n" >/dev/null 2>&1)
if [ -f "$TD/.rite-flow-state" ] && [ ! -f "$TD/.rite/sessions/$SID.flow-state" ]; then
  pass "schema_version=1 writes legacy path"
else
  fail "schema_version=1 routing wrong"
fi

# --------------------------------------------------------------------------
# Non-regression: rite-config.yml absent → legacy path (safe fallback)
# --------------------------------------------------------------------------
echo ""
echo "TC-NR-3: rite-config.yml absent → legacy fallback"
TD=$(make_test_dir); cleanup_dirs+=("$TD")
# No rite-config.yml at all
SID="77777777-7777-7777-7777-777777777777"
write_session_id "$TD" "$SID"

(cd "$TD" && bash "$HOOK" create \
  --phase "p" --issue 1 --branch "b" --pr 0 --next "n" >/dev/null 2>&1)
if [ -f "$TD/.rite-flow-state" ]; then
  pass "absent config defaults to legacy path"
else
  fail "absent config did not write legacy"
fi

# --------------------------------------------------------------------------
# Non-regression: increment mode with new format
# --------------------------------------------------------------------------
echo ""
echo "TC-NR-4: increment mode operates on per-session file"
TD=$(make_test_dir); cleanup_dirs+=("$TD")
write_config "$TD" 2
SID="88888888-8888-8888-8888-888888888888"
write_session_id "$TD" "$SID"

(cd "$TD" && bash "$HOOK" create --phase "p" --issue 1 --branch "b" --pr 0 --next "n" >/dev/null 2>&1)
(cd "$TD" && bash "$HOOK" increment --field error_count >/dev/null 2>&1)
(cd "$TD" && bash "$HOOK" increment --field error_count >/dev/null 2>&1)
TARGET="$TD/.rite/sessions/$SID.flow-state"
ec=$(jq -r '.error_count // 0' "$TARGET")
if [ "$ec" = "2" ]; then
  pass "increment mode increments error_count on new format file"
else
  fail "increment broke: got $ec expected 2"
fi

# --------------------------------------------------------------------------
# Non-regression: --if-exists on absent target exits 0 (new format)
# --------------------------------------------------------------------------
echo ""
echo "TC-NR-5: --if-exists exits 0 when new format file absent"
TD=$(make_test_dir); cleanup_dirs+=("$TD")
write_config "$TD" 2
write_session_id "$TD" "99999999-9999-9999-9999-999999999999"

set +e
(cd "$TD" && bash "$HOOK" patch --phase "p" --next "n" --if-exists >/dev/null 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  pass "--if-exists on absent file exits 0"
else
  fail "--if-exists wrong exit: $rc"
fi

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"

if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
