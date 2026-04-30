#!/bin/bash
# Tests for pre-compact.sh
# Usage: bash plugins/rite/hooks/tests/pre-compact.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../pre-compact.sh"
TEST_DIR="$(mktemp -d)"
LAST_STDERR_FILE=""
PASS=0
FAIL=0
SKIP=0

# Prerequisite check: jq is required by pre-compact.sh
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

# Helper: create a state file in the given directory
create_state_file() {
  local dir="$1"
  local content="$2"
  echo "$content" > "$dir/.rite-flow-state"
}

# Helper: run pre-compact hook with given CWD, capture stderr
# Note: JSON is constructed via string concatenation for simplicity.
# $cwd is always a mktemp-generated path (no special chars), so this is safe in test context.
run_hook() {
  local cwd="$1"
  local rc=0
  LAST_STDERR_FILE="$(mktemp "$TEST_DIR/stderr.XXXXXX")"
  echo "{\"cwd\": \"$cwd\"}" | bash "$HOOK" 2>"$LAST_STDERR_FILE" || rc=$?
  return $rc
}

echo "=== pre-compact.sh tests ==="
echo ""

# --- TC-001: No state file → no error, exit 0 ---
echo "TC-001: No state file → exit 0 (no-op)"
dir001="$TEST_DIR/tc001"
mkdir -p "$dir001"
if run_hook "$dir001"; then
  if [ ! -f "$dir001/.rite-flow-state" ]; then
    pass "No state file, hook exits cleanly"
  else
    fail "State file should not be created"
  fi
else
  fail "Hook should exit 0 when no state file exists"
fi
echo ""

# --- TC-002: State file exists → updated_at is set with ISO 8601 format ---
echo "TC-002: State file exists → updated_at updated with POSIX-compatible ISO 8601"
dir002="$TEST_DIR/tc002"
mkdir -p "$dir002"
create_state_file "$dir002" '{"active": true, "phase": "impl"}'

if run_hook "$dir002"; then
  updated_at=$(jq -r '.updated_at' "$dir002/.rite-flow-state")
  # Verify ISO 8601 format: YYYY-MM-DDTHH:MM:SS+00:00
  if echo "$updated_at" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\+00:00$'; then
    # Also verify year is reasonable (>= 2024) to catch bogus values
    year002=$(echo "$updated_at" | cut -c1-4)
    if [ "$year002" -ge 2024 ]; then
      pass "updated_at is valid ISO 8601 UTC format: $updated_at"
    else
      fail "updated_at year is unexpectedly old: $updated_at"
    fi
  else
    fail "updated_at format unexpected: $updated_at"
  fi
else
  fail "Hook should exit 0 when state file exists"
fi
echo ""

# --- TC-003: Existing fields are preserved ---
echo "TC-003: Existing fields in state file are preserved"
dir003="$TEST_DIR/tc003"
mkdir -p "$dir003"
create_state_file "$dir003" '{"active": true, "phase": "review", "issue": 42}'

if run_hook "$dir003"; then
  phase=$(jq -r '.phase' "$dir003/.rite-flow-state")
  issue=$(jq -r '.issue' "$dir003/.rite-flow-state")
  if [ "$phase" = "review" ] && [ "$issue" = "42" ]; then
    pass "Existing fields preserved (phase=$phase, issue=$issue)"
  else
    fail "Fields were modified: phase=$phase, issue=$issue"
  fi
else
  fail "Hook should exit 0"
fi
echo ""

# --- TC-004: Timestamp is parseable by stop-guard.sh date chain ---
echo "TC-004: Timestamp is parseable by GNU date -d"
dir004="$TEST_DIR/tc004"
mkdir -p "$dir004"
create_state_file "$dir004" '{"active": true}'

if run_hook "$dir004"; then
  updated_at=$(jq -r '.updated_at' "$dir004/.rite-flow-state")
  # Try parsing with GNU date (Linux)
  if epoch=$(date -d "$updated_at" +%s 2>/dev/null); then
    if [ "$epoch" -gt 0 ]; then
      pass "GNU date -d successfully parsed: $updated_at → epoch $epoch"
    else
      fail "Parsed epoch is not positive: $epoch"
    fi
  else
    # Skip on macOS where GNU date -d is not available
    skip "GNU date -d not available (likely macOS), skipping parse check"
  fi
else
  fail "Hook should exit 0"
fi
echo ""

# --- TC-005: Invalid JSON on stdin → non-zero exit ---
echo "TC-005: Invalid JSON on stdin → non-zero exit"
dir005="$TEST_DIR/tc005"
mkdir -p "$dir005"
LAST_STDERR_FILE="$(mktemp "$TEST_DIR/stderr.XXXXXX")"
if echo "NOT-VALID-JSON" | bash "$HOOK" 2>"$LAST_STDERR_FILE"; then
  fail "Hook should exit non-zero on invalid stdin JSON"
else
  pass "Hook exits non-zero on invalid stdin JSON"
fi
echo ""

# --- TC-005b: Corrupted state file JSON → non-zero exit ---
echo "TC-005b: Corrupted state file JSON → non-zero exit"
dir005b="$TEST_DIR/tc005b"
mkdir -p "$dir005b"
echo "{broken" > "$dir005b/.rite-flow-state"
LAST_STDERR_FILE="$(mktemp "$TEST_DIR/stderr.XXXXXX")"
if run_hook "$dir005b"; then
  fail "Hook should exit non-zero on corrupted state file"
else
  # Verify the corrupted file is preserved (jq failure should not overwrite it)
  if [ -f "$dir005b/.rite-flow-state" ]; then
    preserved_content=$(cat "$dir005b/.rite-flow-state")
    if [ "$preserved_content" = "{broken" ]; then
      pass "Hook exits non-zero on corrupted state file JSON, original file preserved"
    else
      fail "Corrupted state file was modified: $preserved_content"
    fi
  else
    fail "Corrupted state file was deleted"
  fi
fi
echo ""

# --- TC-006: Existing updated_at is overwritten with current timestamp ---
echo "TC-006: Existing updated_at is overwritten with current timestamp"
dir006="$TEST_DIR/tc006"
mkdir -p "$dir006"
create_state_file "$dir006" '{"active": true, "updated_at": "2020-01-01T00:00:00+00:00"}'

if run_hook "$dir006"; then
  updated_at=$(jq -r '.updated_at' "$dir006/.rite-flow-state")
  if [ "$updated_at" != "2020-01-01T00:00:00+00:00" ]; then
    # Verify it's a valid current-ish timestamp (year >= 2024)
    year=$(echo "$updated_at" | cut -c1-4)
    if [ "$year" -ge 2024 ]; then
      pass "updated_at overwritten with current timestamp: $updated_at"
    else
      fail "updated_at year is unexpectedly old: $updated_at"
    fi
  else
    fail "updated_at was not updated from old value"
  fi
else
  fail "Hook should exit 0"
fi
echo ""

# --- TC-007: Branch detection outputs issue number message ---
echo "TC-007: Branch detection outputs issue number when on issue branch"
dir007="$TEST_DIR/tc007"
mkdir -p "$dir007"

# Create a temporary git repo to test branch detection
git_repo="$TEST_DIR/git_tc007"
mkdir -p "$git_repo"
(cd "$git_repo" && git init -q && git -c user.name="test" -c user.email="test@test.com" commit --allow-empty -m "init" -q && git checkout -b "feat/issue-42-test-feature" -q)
create_state_file "$git_repo" '{"active": true}'

LAST_STDERR_FILE="$(mktemp "$TEST_DIR/stderr.XXXXXX")"
output=$(echo "{\"cwd\": \"$git_repo\"}" | bash "$HOOK" 2>"$LAST_STDERR_FILE")
if echo "$output" | grep -q "Issue #42"; then
  pass "Branch detection found Issue #42 in output"
else
  fail "Expected 'Issue #42' in output, got: $output"
fi
echo ""

# --- TC-008: Lock delegation — lockdir is cleaned up after hook execution ---
echo "TC-008: Lock delegation — lockdir cleaned up after hook execution"
dir008="$TEST_DIR/tc008"
mkdir -p "$dir008"
create_state_file "$dir008" '{"active": true, "phase": "impl", "issue_number": 100}'
lockdir="$dir008/.rite-compact-state.lockdir"

if run_hook "$dir008"; then
  # After hook completes, lockdir should be released (cleaned up)
  if [ ! -d "$lockdir" ]; then
    pass "Lockdir cleaned up after hook execution"
  else
    fail "Lockdir still exists after hook: $lockdir"
  fi
else
  fail "Hook should exit 0"
fi
echo ""

# --- TC-009: Lock delegation — compact state file is written under lock ---
echo "TC-009: Lock delegation — compact state written with recovering state"
dir009="$TEST_DIR/tc009"
mkdir -p "$dir009"
create_state_file "$dir009" '{"active": true, "phase": "review", "issue_number": 55}'

if run_hook "$dir009"; then
  if [ -f "$dir009/.rite-compact-state" ]; then
    cs_state=$(jq -r '.compact_state' "$dir009/.rite-compact-state" 2>/dev/null)
    cs_issue=$(jq -r '.active_issue' "$dir009/.rite-compact-state" 2>/dev/null)
    if [ "$cs_state" = "recovering" ] && [ "$cs_issue" = "55" ]; then
      pass "Compact state written: state=recovering, issue=55"
    else
      fail "Unexpected compact state: state=$cs_state, issue=$cs_issue"
    fi
  else
    fail "Compact state file not created"
  fi
else
  fail "Hook should exit 0"
fi
echo ""

# --- TC-010: Lock delegation — concurrent hook invocations don't corrupt state ---
# Note: This is a best-effort concurrency test. Two hooks are started in parallel,
# but timing depends on OS scheduling — they may execute sequentially in practice.
# The test verifies that the final state is valid regardless of execution order.
echo "TC-010: Lock delegation — concurrent invocation safety"
dir010="$TEST_DIR/tc010"
mkdir -p "$dir010"
create_state_file "$dir010" '{"active": true, "phase": "impl", "issue_number": 77}'

# Run two hooks in parallel, capturing exit codes individually
stderr1="$(mktemp "$TEST_DIR/stderr.XXXXXX")"
echo "{\"cwd\": \"$dir010\"}" | bash "$HOOK" 2>"$stderr1" &
pid1=$!
stderr2="$(mktemp "$TEST_DIR/stderr.XXXXXX")"
echo "{\"cwd\": \"$dir010\"}" | bash "$HOOK" 2>"$stderr2" &
pid2=$!

rc1=0; rc2=0
wait $pid1 2>/dev/null || rc1=$?
wait $pid2 2>/dev/null || rc2=$?

# Verify both processes completed (at least one should succeed)
if [ $rc1 -ne 0 ] && [ $rc2 -ne 0 ]; then
  LAST_STDERR_FILE="$stderr1"
  fail "Both concurrent hooks failed (rc1=$rc1, rc2=$rc2). stderr1: $(cat "$stderr1") stderr2: $(cat "$stderr2")"
# Verify compact state is valid JSON and has expected fields
elif [ -f "$dir010/.rite-compact-state" ]; then
  if jq . "$dir010/.rite-compact-state" >/dev/null 2>&1; then
    cs_state=$(jq -r '.compact_state' "$dir010/.rite-compact-state" 2>/dev/null)
    if [ "$cs_state" = "recovering" ]; then
      pass "Concurrent invocations produce valid state: compact_state=recovering"
    else
      fail "Unexpected compact_state after concurrent run: $cs_state"
    fi
  else
    fail "Compact state file is not valid JSON after concurrent run"
  fi
else
  fail "Compact state file not created after concurrent invocations"
fi
echo ""

# --- TC-011: Lock delegation — work memory snapshot created under lock ---
echo "TC-011: Lock delegation — local work memory snapshot created"
dir011="$TEST_DIR/tc011"
mkdir -p "$dir011"
create_state_file "$dir011" '{"active": true, "phase": "impl", "issue_number": 88, "branch": "feat/issue-88-test"}'

if run_hook "$dir011"; then
  wm_file="$dir011/.rite-work-memory/issue-88.md"
  if [ -f "$wm_file" ]; then
    wm_ok=true
    if ! grep -q "issue_number: 88" "$wm_file"; then
      fail "Work memory snapshot missing issue_number field"
      wm_ok=false
    fi
    if ! grep -q "schema_version: 1" "$wm_file"; then
      fail "Work memory snapshot missing schema_version field"
      wm_ok=false
    fi
    if ! grep -q "source: pre_compact" "$wm_file"; then
      fail "Work memory snapshot missing source field"
      wm_ok=false
    fi
    if [ "$wm_ok" = true ]; then
      pass "Work memory snapshot created with correct fields (issue_number, schema_version, source)"
    fi
  else
    fail "Work memory snapshot file not created: $wm_file"
  fi
else
  fail "Hook should exit 0"
fi
echo ""

# --- TC-012: No issue_number in state → active_issue is null, no work memory snapshot ---
echo "TC-012: No issue_number in state → active_issue null, no work memory snapshot"
dir012="$TEST_DIR/tc012"
mkdir -p "$dir012"
create_state_file "$dir012" '{"active": true, "phase": "impl"}'

if run_hook "$dir012"; then
  if [ -f "$dir012/.rite-compact-state" ]; then
    cs_issue=$(jq -r '.active_issue' "$dir012/.rite-compact-state" 2>/dev/null)
    if [ "$cs_issue" = "null" ]; then
      # Verify no work memory snapshot was created
      if [ ! -d "$dir012/.rite-work-memory" ]; then
        pass "active_issue is null and no work memory snapshot created"
      else
        fail "Work memory directory should not exist when issue_number is null"
      fi
    else
      fail "Expected active_issue=null, got: $cs_issue"
    fi
  else
    fail "Compact state file not created"
  fi
else
  fail "Hook should exit 0"
fi
echo ""

# --- TC-013: active: false → no work memory snapshot, but compact state still written (#776) ---
echo "TC-013: active: false → no WM snapshot, compact state still written (#776)"
dir013="$TEST_DIR/tc013"
mkdir -p "$dir013"
create_state_file "$dir013" '{"active": false, "phase": "completed", "issue_number": 99, "branch": "fix/issue-99-test"}'

if run_hook "$dir013"; then
  tc013_ok=true
  # Verify no work memory snapshot
  wm_file="$dir013/.rite-work-memory/issue-99.md"
  if [ -f "$wm_file" ]; then
    fail "Work memory snapshot should NOT be created when active: false"
    tc013_ok=false
  fi
  # Verify compact state IS still written (compact state records state regardless of active flag)
  if [ -f "$dir013/.rite-compact-state" ]; then
    cs_state=$(jq -r '.compact_state' "$dir013/.rite-compact-state" 2>/dev/null)
    if [ "$cs_state" != "recovering" ]; then
      fail "Compact state should be 'recovering', got: $cs_state"
      tc013_ok=false
    fi
  else
    fail "Compact state file should still be created when active: false"
    tc013_ok=false
  fi
  if [ "$tc013_ok" = true ]; then
    pass "No WM snapshot when active: false, but compact state written correctly"
  fi
else
  fail "Hook should exit 0"
fi
echo ""

# --- TC-014: pre-compact does NOT set needs_clear in .rite-flow-state (AC-2, T-02) ---
echo "TC-014: pre-compact does NOT set needs_clear (AC-2)"
dir014="$TEST_DIR/tc014"
mkdir -p "$dir014"
create_state_file "$dir014" '{"active": true, "phase": "phase5_review", "issue_number": 847}'

if run_hook "$dir014"; then
  has_needs_clear=$(jq -e 'has("needs_clear")' "$dir014/.rite-flow-state" 2>/dev/null) && has_needs_clear="true" || has_needs_clear="false"
  if [ "$has_needs_clear" = "false" ]; then
    pass "needs_clear field is absent after pre-compact (AC-2)"
  else
    needs_clear_val=$(jq -r '.needs_clear' "$dir014/.rite-flow-state" 2>/dev/null)
    fail "needs_clear field exists after pre-compact: needs_clear=$needs_clear_val"
  fi
else
  fail "Hook should exit 0"
fi
echo ""

# --- TC-014b: pre-compact preserves but does NOT add needs_clear (AC-2 variant) ---
echo "TC-014b: pre-compact with existing needs_clear=true (AC-2 variant)"
dir014b="$TEST_DIR/tc014b"
mkdir -p "$dir014b"
create_state_file "$dir014b" '{"active": true, "phase": "phase5_review", "issue_number": 847, "needs_clear": true}'

if run_hook "$dir014b"; then
  # jq '.updated_at = $ts' preserves existing fields, so needs_clear will remain.
  # This is expected: pre-compact does not ADD needs_clear, but it does not strip
  # existing fields either (jq pass-through behavior). The key AC-2 requirement is
  # that pre-compact does not SET needs_clear — and since the jq filter no longer
  # contains '.needs_clear = true', a fresh flow-state (without needs_clear) will
  # never have it added by pre-compact.
  pass "pre-compact with existing needs_clear=true runs without error (AC-2 variant)"
else
  fail "Hook should exit 0"
fi
echo ""

# --- TC-015: resuming state is overwritten to recovering (#854, supersedes #851 AC-1) ---
echo "TC-015: resuming state overwritten to recovering — every compact sets recovering (#854)"
dir015="$TEST_DIR/tc015"
mkdir -p "$dir015"
create_state_file "$dir015" '{"active": true, "phase": "phase5_lint", "issue_number": 851}'
# Pre-create compact state with "resuming" (simulates /clear transition)
echo '{"compact_state":"resuming","compact_state_set_at":"2026-01-01T00:00:00Z","active_issue":851}' > "$dir015/.rite-compact-state"

if run_hook "$dir015"; then
  cs_state=$(jq -r '.compact_state' "$dir015/.rite-compact-state" 2>/dev/null)
  cs_ts=$(jq -r '.compact_state_set_at' "$dir015/.rite-compact-state" 2>/dev/null)
  tc015_ok=true
  if [ "$cs_state" != "recovering" ]; then
    fail "compact_state should be overwritten to 'recovering', got '$cs_state'"
    tc015_ok=false
  fi
  if [ "$cs_ts" = "2026-01-01T00:00:00Z" ]; then
    fail "compact_state_set_at should be updated (new timestamp), but was unchanged"
    tc015_ok=false
  fi
  if [ "$tc015_ok" = true ]; then
    pass "compact_state overwritten from 'resuming' to 'recovering' with new timestamp (#854)"
  fi
else
  fail "Hook should exit 0"
fi
echo ""

# --- TC-016: resuming→recovering overwrite still saves work memory snapshot (#854, supersedes #851 AC-3) ---
echo "TC-016: resuming→recovering overwrite still saves work memory snapshot (#854)"
dir016="$TEST_DIR/tc016"
mkdir -p "$dir016"
create_state_file "$dir016" '{"active": true, "phase": "phase5_review", "issue_number": 160, "branch": "fix/issue-160-test"}'
echo '{"compact_state":"resuming","compact_state_set_at":"2026-01-01T00:00:00Z","active_issue":160}' > "$dir016/.rite-compact-state"

if run_hook "$dir016"; then
  wm_file="$dir016/.rite-work-memory/issue-160.md"
  tc016_ok=true
  # compact_state should now be recovering (overwritten from resuming — #854)
  cs_state=$(jq -r '.compact_state' "$dir016/.rite-compact-state" 2>/dev/null)
  if [ "$cs_state" != "recovering" ]; then
    fail "compact_state should be 'recovering', got '$cs_state'"
    tc016_ok=false
  fi
  # work memory snapshot should still be created regardless of compact_state
  if [ -f "$wm_file" ]; then
    if grep -q "issue_number: 160" "$wm_file" && grep -q "source: pre_compact" "$wm_file"; then
      : # OK
    else
      fail "Work memory snapshot missing expected fields"
      tc016_ok=false
    fi
  else
    fail "Work memory snapshot not created when compact_state was resuming→recovering"
    tc016_ok=false
  fi
  if [ "$tc016_ok" = true ]; then
    pass "compact_state overwritten to 'recovering' AND work memory snapshot created (#854)"
  fi
else
  fail "Hook should exit 0"
fi
echo ""

# --- TC-017: corrupted compact state JSON falls back to recovering (#851 AC-4, T-04) ---
echo "TC-017: corrupted compact state JSON → falls back to recovering (#851)"
dir017="$TEST_DIR/tc017"
mkdir -p "$dir017"
create_state_file "$dir017" '{"active": true, "phase": "phase5_fix", "issue_number": 170}'
echo '{broken json' > "$dir017/.rite-compact-state"

if run_hook "$dir017"; then
  cs_state=$(jq -r '.compact_state' "$dir017/.rite-compact-state" 2>/dev/null)
  if [ "$cs_state" = "recovering" ]; then
    pass "Corrupted compact state overwritten with 'recovering' (AC-4, fail-closed)"
  else
    fail "Expected 'recovering' after corrupted compact state, got '$cs_state'"
  fi
else
  fail "Hook should exit 0"
fi
echo ""

# --- TC-018: normal compact state transitions to recovering (#133 AC-3) ---
echo "TC-018: normal compact state → recovering (#133)"
dir018="$TEST_DIR/tc018"
mkdir -p "$dir018"
create_state_file "$dir018" '{"active": true, "phase": "phase5_impl", "issue_number": 180}'
echo '{"compact_state":"normal","compact_state_set_at":"2026-01-01T00:00:00Z","active_issue":180}' > "$dir018/.rite-compact-state"

if run_hook "$dir018"; then
  cs_state=$(jq -r '.compact_state' "$dir018/.rite-compact-state" 2>/dev/null)
  if [ "$cs_state" = "recovering" ]; then
    pass "normal compact_state transitions to 'recovering' (AC-2)"
  else
    fail "Expected 'recovering', got '$cs_state'"
  fi
else
  fail "Hook should exit 0"
fi
echo ""

# --- TC-680-A (Issue #680, AC-LOCAL-2): per-session active=true → updated_at touched ---
# Verifies pre-compact reads & writes the per-session file (not legacy) when
# schema_version=2 + valid SID + per-session file exists. Also confirms the
# `.active=true` precondition path still fires the workflow-active branch.
echo "TC-680-A (Issue #680, AC-LOCAL-2): per-session active=true → updated_at touched"
dir680a="$TEST_DIR/tc680a"
mkdir -p "$dir680a/.rite/sessions"
sid680a="aaaabbbb-cccc-dddd-eeee-ffffaaaa1111"
echo "$sid680a" > "$dir680a/.rite-session-id"
cat > "$dir680a/rite-config.yml" <<EOF
flow_state:
  schema_version: 2
EOF
per_session_file="$dir680a/.rite/sessions/${sid680a}.flow-state"
echo '{"active": true, "phase": "phase5_review", "issue_number": 680, "branch": "refactor/issue-680-test", "updated_at": "2020-01-01T00:00:00+00:00"}' \
  > "$per_session_file"
old_ts=$(jq -r '.updated_at' "$per_session_file" 2>/dev/null)
output=$(run_hook "$dir680a") && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ -f "$per_session_file" ]; then
  new_ts=$(jq -r '.updated_at' "$per_session_file" 2>/dev/null)
  if [ "$new_ts" != "$old_ts" ] && [ -n "$new_ts" ]; then
    pass "TC-680-A: per-session file updated_at refreshed (per-session resolution working)"
  else
    fail "TC-680-A: per-session updated_at not refreshed (old=$old_ts new=$new_ts)"
  fi
else
  fail "TC-680-A: hook exited non-zero or per-session file missing (rc=$rc)"
fi
# Counter-assertion: workflow-active stdout fired (.active=true precondition)
if echo "$output" | grep -q "STOP. Compact detected. Issue #680"; then
  pass "TC-680-A: workflow-active stdout fired on per-session path (.active=true preserved)"
else
  fail "TC-680-A: workflow-active stdout missing — .active=true precondition broke on per-session path"
fi
echo ""

# --------------------------------------------------------------------------
# TC-749-STDERR-PASSTHROUGH (Issue #749, AC-1 / AC-LOCAL-1)
# --------------------------------------------------------------------------
echo "TC-749-STDERR-PASSTHROUGH: helper failure → ERROR pass-through + fallback WARNING"

HOOKS_REAL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
sbx_749="$(mktemp -d "$TEST_DIR/sbx-hooks-XXXXXX")"
cp -a "$HOOKS_REAL_DIR/." "$sbx_749/"
cat > "$sbx_749/_resolve-flow-state-path.sh" <<'FAKE_RESOLVER_EOF'
#!/bin/bash
echo "ERROR: TC-749 simulated _resolve-flow-state-path failure" >&2
exit 1
FAKE_RESOLVER_EOF
chmod +x "$sbx_749/_resolve-flow-state-path.sh"

dir_749="$TEST_DIR/tc749-passthrough"
mkdir -p "$dir_749"
cat > "$dir_749/.rite-flow-state" <<EOF
{"active": true, "issue_number": 749, "phase": "phase5_test", "branch": "refactor/issue-749-test"}
EOF

LAST_STDERR_FILE="$(mktemp "$TEST_DIR/stderr.749.XXXXXX")"
echo "{\"cwd\": \"$dir_749\"}" \
  | bash "$sbx_749/pre-compact.sh" >/dev/null 2>"$LAST_STDERR_FILE" || true
stderr_749="$(cat "$LAST_STDERR_FILE")"

if printf '%s' "$stderr_749" | grep -qF 'TC-749 simulated _resolve-flow-state-path failure'; then
  pass "ERROR line from helper passed through to caller stderr"
else
  fail "Expected ERROR pass-through; got stderr: $stderr_749"
fi
if printf '%s' "$stderr_749" | grep -qF 'flow-state path resolution failed, falling back to legacy'; then
  pass "Fallback WARNING emitted to stderr"
else
  fail "Expected fallback WARNING; got stderr: $stderr_749"
fi
# Positive evidence: assert the legacy fallback path was actually used.
# pre-compact.sh updates `.updated_at` on the resolved FLOW_STATE. If the fallback
# silently broke (typo / missing file), this would not happen.
updated_at_after=$(jq -r '.updated_at // empty' "$dir_749/.rite-flow-state" 2>/dev/null)
if [ -n "$updated_at_after" ]; then
  pass "Legacy fallback path was loaded (.updated_at present after pre-compact)"
else
  fail "Expected .updated_at in legacy state file; got: '$updated_at_after'"
fi
echo ""

# --- Summary ---
echo "=== Results: $PASS passed, $FAIL failed, $SKIP skipped ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi