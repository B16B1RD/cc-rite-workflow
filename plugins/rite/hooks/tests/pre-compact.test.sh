#!/bin/bash
# Tests for pre-compact.sh
# Usage: bash plugins/rite/hooks/tests/pre-compact.test.sh
set -euo pipefail

issue_text() { printf 'Issue #%s' "$1"; }

# Hermeticity guard: flow-state.sh path resolves session_id with
# priority env CLAUDE_CODE_SESSION_ID > env CLAUDE_SESSION_ID > .rite-session-id
# file. When this test suite runs inside a live Claude Code
# session, that session's own id leaks into most `bash "$HOOK"` invocations
# below (only one call site had an inline `env -u` guard) and silently
# overrides the file-based per-session fixtures, making the hook resolve a
# nonexistent (or wrong) flow-state file — in the worst case crashing the
# suite outright under `set -euo pipefail`. Unsetting both here forces every
# invocation to resolve session_id from the fixture's `.rite-session-id` file,
# matching the intended test isolation. (The pre-existing inline `env -u`
# guard further down stays as defense in depth; it's redundant but harmless
# with this file-wide unset in place.)
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID

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

# Helper: create a per-session state file (schema v3) in the given directory.
# Writes .rite-session-id and .rite/sessions/<sid>.flow-state. Auto-injects
# schema_version=3 so the consuming hook does not re-migrate the fixture
# mid-test (the auto-migrate step on session-start would rewrite legacy
# phase names like `implementing`).
create_state_file() {
  local dir="$1"
  local content="$2"
  local sid="${3:-test-sid-$(basename "$dir")}"
  mkdir -p "$dir/.rite/sessions"
  printf '%s' "$sid" > "$dir/.rite-session-id"
  local merged
  if printf '%s' "$content" | grep -q '"schema_version"'; then
    merged="$content"
  elif printf '%s' "$content" | jq -e . >/dev/null 2>&1; then
    merged=$(printf '%s' "$content" | jq -c '. + {schema_version: 3}')
  else
    merged="$content"
  fi
  printf '%s\n' "$merged" > "$dir/.rite/sessions/${sid}.flow-state"
}

# Helper: path to the per-session state file written by create_state_file
state_file_path() {
  local dir="$1"
  local sid="${2:-test-sid-$(basename "$dir")}"
  echo "$dir/.rite/sessions/${sid}.flow-state"
}

# Helper: path to the per-session compact-state file. Mirrors
# pre-compact.sh's derivation: .rite/sessions/<sid>.flow-state → .compact-state.
compact_state_path() {
  local dir="$1"
  local sid="${2:-test-sid-$(basename "$dir")}"
  echo "$dir/.rite/sessions/${sid}.compact-state"
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
  updated_at=$(jq -r '.updated_at' "$(state_file_path "$dir002")")
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
  sf003=$(state_file_path "$dir003")
  phase=$(jq -r '.phase' "$sf003")
  issue=$(jq -r '.issue' "$sf003")
  if [ "$phase" = "review" ] && [ "$issue" = "42" ]; then
    pass "Existing fields preserved (phase=$phase, issue=$issue)"
  else
    fail "Fields were modified: phase=$phase, issue=$issue"
  fi
else
  fail "Hook should exit 0"
fi
echo ""

# --- TC-004: Timestamp must remain parseable by GNU date ---
echo "TC-004: Timestamp is parseable by GNU date -d"
dir004="$TEST_DIR/tc004"
mkdir -p "$dir004"
create_state_file "$dir004" '{"active": true}'

if run_hook "$dir004"; then
  updated_at=$(jq -r '.updated_at' "$(state_file_path "$dir004")")
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

# --- TC-005: Invalid JSON on stdin → exit 0 (best-effort, lifecycle 維持) ---
# pre-compact.sh は Claude Code lifecycle hook であり、invalid JSON で
# exit 1 を返すと compact 処理自体が止まる risk がある。production は best-effort
# 設計 (invalid stdin → silent skip + exit 0) を採用しており、本 TC はその contract
# を pin する。silent skip の真正性 (downstream に副作用が漏れない) は TC-005b と
# TC-006 以降で別途 verify される。
echo "TC-005: Invalid JSON on stdin → exit 0 (best-effort skip, lifecycle 維持)"
dir005="$TEST_DIR/tc005"
mkdir -p "$dir005"
LAST_STDERR_FILE="$(mktemp "$TEST_DIR/stderr.XXXXXX")"
if echo "NOT-VALID-JSON" | bash "$HOOK" 2>"$LAST_STDERR_FILE"; then
  pass "Hook exit 0 on invalid stdin JSON (best-effort skip preserves Claude Code lifecycle)"
else
  fail "Hook should exit 0 on invalid stdin JSON (best-effort contract violated)"
fi
echo ""

# --- TC-005b: Corrupted state file JSON → exit 0 + jq parse error stderr + 元ファイル保持 ---
# production は corrupted state file 検出時に exit 0 (lifecycle 維持) かつ
# jq parse error を stderr に出力 (silent failure 防止) かつ元ファイルを保持する
# (overwrite 防止)。この 3 contract を pin する。
echo "TC-005b: Corrupted state file → exit 0 + jq parse error stderr + 元ファイル保持"
dir005b="$TEST_DIR/tc005b"
mkdir -p "$dir005b"
create_state_file "$dir005b" "{broken"
sf005b=$(state_file_path "$dir005b")
LAST_STDERR_FILE="$(mktemp "$TEST_DIR/stderr.XXXXXX")"
if run_hook "$dir005b" >/dev/null; then
  rc=0
else
  rc=$?
fi
if [ "$rc" -eq 0 ]; then
  # Verify the corrupted file is preserved (jq failure should not overwrite it)
  if [ -f "$sf005b" ]; then
    preserved_content=$(cat "$sf005b")
    if [ "$preserved_content" = "{broken" ]; then
      # Verify jq parse error is emitted to stderr (silent failure 防止)
      if grep -q "parse error" "$LAST_STDERR_FILE" 2>/dev/null; then
        pass "Hook exit 0 + jq parse error stderr + 元ファイル保持 (3-contract verified)"
      else
        fail "Hook exit 0 + 元ファイル保持 OK だが jq parse error が stderr に出力されていない (silent failure)"
      fi
    else
      fail "Corrupted state file was modified: $preserved_content"
    fi
  else
    fail "Corrupted state file was deleted"
  fi
else
  fail "Hook should exit 0 on corrupted state file (best-effort contract violated, rc=$rc)"
fi
echo ""

# --- TC-006: Existing updated_at is overwritten with current timestamp ---
echo "TC-006: Existing updated_at is overwritten with current timestamp"
dir006="$TEST_DIR/tc006"
mkdir -p "$dir006"
create_state_file "$dir006" '{"active": true, "updated_at": "2020-01-01T00:00:00+00:00"}'

if run_hook "$dir006"; then
  updated_at=$(jq -r '.updated_at' "$(state_file_path "$dir006")")
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
if [ -z "$output" ] && grep -q "$(issue_text 42)" "$LAST_STDERR_FILE"; then
  pass "Branch detection found the expected issue in stderr; stdout empty"
else
  fail "Expected empty stdout + '$(issue_text 42)' in stderr, got stdout: $output stderr: $(cat "$LAST_STDERR_FILE")"
fi
echo ""

# --- TC-008: Lock delegation — lockdir is cleaned up after hook execution ---
echo "TC-008: Lock delegation — lockdir cleaned up after hook execution"
dir008="$TEST_DIR/tc008"
mkdir -p "$dir008"
create_state_file "$dir008" '{"active": true, "phase": "impl", "issue_number": 100}'
lockdir="$(compact_state_path "$dir008").lockdir"

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
  cs009="$(compact_state_path "$dir009")"
  if [ -f "$cs009" ]; then
    cs_state=$(jq -r '.compact_state' "$cs009" 2>/dev/null)
    cs_issue=$(jq -r '.active_issue' "$cs009" 2>/dev/null)
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
elif [ -f "$(compact_state_path "$dir010")" ]; then
  cs010="$(compact_state_path "$dir010")"
  if jq . "$cs010" >/dev/null 2>&1; then
    cs_state=$(jq -r '.compact_state' "$cs010" 2>/dev/null)
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
  wm_file="$dir011/.rite/work-memory/issue-88.md"
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
  cs012="$(compact_state_path "$dir012")"
  if [ -f "$cs012" ]; then
    cs_issue=$(jq -r '.active_issue' "$cs012" 2>/dev/null)
    if [ "$cs_issue" = "null" ]; then
      # Verify no work memory snapshot was created
      if [ ! -d "$dir012/.rite/work-memory" ]; then
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

# --- TC-013: active: false → no work memory snapshot, but compact state still written ---
echo "TC-013: active: false → no WM snapshot, compact state still written"
dir013="$TEST_DIR/tc013"
mkdir -p "$dir013"
create_state_file "$dir013" '{"active": false, "phase": "completed", "issue_number": 99, "branch": "fix/issue-99-test"}'

if run_hook "$dir013"; then
  tc013_ok=true
  # Verify no work memory snapshot
  wm_file="$dir013/.rite/work-memory/issue-99.md"
  if [ -f "$wm_file" ]; then
    fail "Work memory snapshot should NOT be created when active: false"
    tc013_ok=false
  fi
  # Verify compact state IS still written (compact state records state regardless of active flag)
  cs013="$(compact_state_path "$dir013")"
  if [ -f "$cs013" ]; then
    cs_state=$(jq -r '.compact_state' "$cs013" 2>/dev/null)
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
  sf014=$(state_file_path "$dir014")
  has_needs_clear=$(jq -e 'has("needs_clear")' "$sf014" 2>/dev/null) && has_needs_clear="true" || has_needs_clear="false"
  if [ "$has_needs_clear" = "false" ]; then
    pass "needs_clear field is absent after pre-compact (AC-2)"
  else
    needs_clear_val=$(jq -r '.needs_clear' "$sf014" 2>/dev/null)
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

# --- TC-015: resuming state is overwritten to recovering ---
echo "TC-015: resuming state overwritten to recovering — every compact sets recovering"
dir015="$TEST_DIR/tc015"
mkdir -p "$dir015"
create_state_file "$dir015" '{"active": true, "phase": "phase5_lint", "issue_number": 851}'
# Pre-create compact state with "resuming" (simulates /clear transition)
cs015="$(compact_state_path "$dir015")"
echo '{"compact_state":"resuming","compact_state_set_at":"2026-01-01T00:00:00Z","active_issue":851}' > "$cs015"

if run_hook "$dir015"; then
  cs_state=$(jq -r '.compact_state' "$cs015" 2>/dev/null)
  cs_ts=$(jq -r '.compact_state_set_at' "$cs015" 2>/dev/null)
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
    pass "compact_state overwritten from 'resuming' to 'recovering' with new timestamp"
  fi
else
  fail "Hook should exit 0"
fi
echo ""

# --- TC-016: resuming→recovering overwrite still saves work memory snapshot ---
echo "TC-016: resuming→recovering overwrite still saves work memory snapshot"
dir016="$TEST_DIR/tc016"
mkdir -p "$dir016"
create_state_file "$dir016" '{"active": true, "phase": "phase5_review", "issue_number": 160, "branch": "fix/issue-160-test"}'
cs016="$(compact_state_path "$dir016")"
echo '{"compact_state":"resuming","compact_state_set_at":"2026-01-01T00:00:00Z","active_issue":160}' > "$cs016"

if run_hook "$dir016"; then
  wm_file="$dir016/.rite/work-memory/issue-160.md"
  tc016_ok=true
  # compact_state should now be recovering (overwritten from resuming)
  cs_state=$(jq -r '.compact_state' "$cs016" 2>/dev/null)
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
    pass "compact_state overwritten to 'recovering' AND work memory snapshot created"
  fi
else
  fail "Hook should exit 0"
fi
echo ""

# --- TC-017: corrupted compact state JSON falls back to recovering ---
echo "TC-017: corrupted compact state JSON → falls back to recovering"
dir017="$TEST_DIR/tc017"
mkdir -p "$dir017"
create_state_file "$dir017" '{"active": true, "phase": "phase5_fix", "issue_number": 170}'
cs017="$(compact_state_path "$dir017")"
echo '{broken json' > "$cs017"

if run_hook "$dir017"; then
  cs_state=$(jq -r '.compact_state' "$cs017" 2>/dev/null)
  if [ "$cs_state" = "recovering" ]; then
    pass "Corrupted compact state overwritten with 'recovering' (AC-4, fail-closed)"
  else
    fail "Expected 'recovering' after corrupted compact state, got '$cs_state'"
  fi
else
  fail "Hook should exit 0"
fi
echo ""

# --- TC-018: normal compact state transitions to recovering ---
echo "TC-018: normal compact state → recovering"
dir018="$TEST_DIR/tc018"
mkdir -p "$dir018"
create_state_file "$dir018" '{"active": true, "phase": "phase5_impl", "issue_number": 180}'
cs018="$(compact_state_path "$dir018")"
echo '{"compact_state":"normal","compact_state_set_at":"2026-01-01T00:00:00Z","active_issue":180}' > "$cs018"

if run_hook "$dir018"; then
  cs_state=$(jq -r '.compact_state' "$cs018" 2>/dev/null)
  if [ "$cs_state" = "recovering" ]; then
    pass "normal compact_state transitions to 'recovering' (AC-2)"
  else
    fail "Expected 'recovering', got '$cs_state'"
  fi
else
  fail "Hook should exit 0"
fi
echo ""

# --- TC-per-session-detect-A (AC-LOCAL-2): per-session active=true → updated_at touched ---
# Verifies pre-compact reads & writes the per-session file (not legacy) when
# a valid SID + per-session file exists. Also confirms the
# `.active=true` precondition path still fires the workflow-active branch.
echo "TC-per-session-detect-A (AC-LOCAL-2): per-session active=true → updated_at touched"
dir680a="$TEST_DIR/tc680a"
mkdir -p "$dir680a/.rite/sessions"
sid680a="aaaabbbb-cccc-dddd-eeee-ffffaaaa1111"
echo "$sid680a" > "$dir680a/.rite-session-id"
printf '# rite test sandbox config\n' > "$dir680a/rite-config.yml"
per_session_file="$dir680a/.rite/sessions/${sid680a}.flow-state"
echo '{"active": true, "phase": "phase5_review", "issue_number": 680, "branch": "refactor/issue-680-test", "updated_at": "2020-01-01T00:00:00+00:00"}' \
  > "$per_session_file"
old_ts=$(jq -r '.updated_at' "$per_session_file" 2>/dev/null)
LAST_STDERR_FILE="$(mktemp "$TEST_DIR/stderr.XXXXXX")"
output=$(echo "{\"cwd\": \"$dir680a\"}" | bash "$HOOK" 2>"$LAST_STDERR_FILE") && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ -f "$per_session_file" ]; then
  new_ts=$(jq -r '.updated_at' "$per_session_file" 2>/dev/null)
  if [ "$new_ts" != "$old_ts" ] && [ -n "$new_ts" ]; then
    pass "TC-per-session-detect-A: per-session file updated_at refreshed (per-session resolution working)"
  else
    fail "TC-per-session-detect-A: per-session updated_at not refreshed (old=$old_ts new=$new_ts)"
  fi
else
  fail "TC-per-session-detect-A: hook exited non-zero or per-session file missing (rc=$rc)"
fi
# Counter-assertion: workflow-active path still fires (stderr compact detected; stdout empty)
if [ -z "$output" ] \
  && grep -q "compact detected" "$LAST_STDERR_FILE" \
  && grep -q "$(issue_text 680)" "$LAST_STDERR_FILE"; then
  pass "TC-per-session-detect-A: workflow-active stderr fired, stdout empty (.active=true preserved)"
else
  fail "TC-per-session-detect-A: expected empty stdout + stderr compact detected; stdout='$output' stderr=$(cat "$LAST_STDERR_FILE")"
fi
echo ""

# --------------------------------------------------------------------------
# TC-helper-failure-stderr-passthrough (AC-1 / AC-LOCAL-1)
# --------------------------------------------------------------------------
echo "TC-helper-failure-stderr-passthrough: helper failure → ERROR pass-through + skip WARNING"

HOOKS_REAL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
sbx_749="$(mktemp -d "$TEST_DIR/sbx-hooks-XXXXXX")"
cp -a "$HOOKS_REAL_DIR/." "$sbx_749/"
cat > "$sbx_749/flow-state.sh" <<'FAKE_RESOLVER_EOF'
#!/bin/bash
echo "ERROR: TC-helper-failure simulated flow-state.sh path failure" >&2
exit 1
FAKE_RESOLVER_EOF
chmod +x "$sbx_749/flow-state.sh"

dir_749="$TEST_DIR/tc749-passthrough"
mkdir -p "$dir_749"

LAST_STDERR_FILE="$(mktemp "$TEST_DIR/stderr.749.XXXXXX")"
echo "{\"cwd\": \"$dir_749\"}" \
  | bash "$sbx_749/pre-compact.sh" >/dev/null 2>"$LAST_STDERR_FILE" || true
stderr_749="$(cat "$LAST_STDERR_FILE")"

if printf '%s' "$stderr_749" | grep -qF 'TC-helper-failure simulated flow-state.sh path failure'; then
  pass "ERROR line from flow-state.sh passed through to caller stderr"
else
  fail "Expected ERROR pass-through; got stderr: $stderr_749"
fi
# PR 2a refactor (Phase F-3): the legacy fallback was removed. pre-compact now
# emits a "flow-state.sh path resolution failed — skip" WARNING and aborts the
# flow-state update. The previous "Legacy fallback path was loaded" assertion
# was removed accordingly.
if printf '%s' "$stderr_749" | grep -qF 'flow-state.sh path resolution failed'; then
  pass "Skip WARNING emitted to stderr (no legacy fallback in v3)"
else
  fail "Expected skip WARNING; got stderr: $stderr_749"
fi
echo ""

# --------------------------------------------------------------------------
# TC-ACTIVE-PARSE-WARNING — corrupt .rite-flow-state must surface a WARNING
# explaining the snapshot is skipped. A silent `2>/dev/null` here would let a
# recovery path proceed with a missing workflow snapshot and no diagnostic.
# --------------------------------------------------------------------------
echo "TC-ACTIVE-PARSE-WARNING: corrupt per-session flow-state → 'workflow snapshot will be skipped' WARNING"
dir_active_parse="$TEST_DIR/tc-active-parse"
mkdir -p "$dir_active_parse"
# Valid JSON-prefix that fails when jq tries to extract .active
create_state_file "$dir_active_parse" '{ not json'
LAST_STDERR_FILE="$(mktemp "$TEST_DIR/stderr.active-parse.XXXXXX")"
echo "{\"cwd\": \"$dir_active_parse\"}" \
  | bash "$HOOK" >/dev/null 2>"$LAST_STDERR_FILE" || true
stderr_ap="$(cat "$LAST_STDERR_FILE")"
if printf '%s' "$stderr_ap" | grep -qF 'workflow snapshot will be skipped'; then
  pass "TC-ACTIVE-PARSE-WARNING: corrupt flow-state .active parse surfaces 'workflow snapshot will be skipped' WARNING"
else
  fail "TC-ACTIVE-PARSE-WARNING: WARNING missing — recovery may silently lose workflow snapshot. stderr: $stderr_ap"
fi
if printf '%s' "$stderr_ap" | grep -qE 'jq rc=[0-9]+'; then
  pass "TC-ACTIVE-PARSE-WARNING: WARNING carries jq rc so triagers can distinguish failure modes"
else
  fail "TC-ACTIVE-PARSE-WARNING: WARNING missing rc capture — silent-failure regression"
fi
echo ""

# --------------------------------------------------------------------------
# TC-FLOW-MV-FAIL / TC-COMPACT-MV-FAIL / TC-CHMOD-FAIL — exercise the round-9
# mv / chmod if/else branches by overriding mv and chmod through PATH. A
# bash-! antipattern regression would collapse rc to 0/1 and these assertions
# would fail.
# --------------------------------------------------------------------------
echo "TC-FLOW-MV-FAIL: PATH-shimmed mv exits non-zero — flow-state mv WARNING must carry rc"
shim_dir="$TEST_DIR/shim-mv-only"
mkdir -p "$shim_dir"
cat > "$shim_dir/mv" <<'SHIM'
#!/bin/bash
exit 7
SHIM
chmod +x "$shim_dir/mv"
dir_mvfail="$TEST_DIR/tc-mv-fail"
mkdir -p "$dir_mvfail"
create_state_file "$dir_mvfail" '{"active":true,"phase":"implement","updated_at":"2026-01-01T00:00:00+00:00"}'
stderr_mvfail=$(echo "{\"cwd\": \"$dir_mvfail\"}" | PATH="$shim_dir:$PATH" bash "$HOOK" 2>&1 >/dev/null || true)
if printf '%s' "$stderr_mvfail" | grep -qE 'mv flow-state updated_at failed \(rc=[1-9][0-9]*'; then
  pass "TC-FLOW-MV-FAIL: flow-state mv WARNING carries real rc (≥1)"
else
  fail "TC-FLOW-MV-FAIL: missing rc-carrying WARNING (bash-! antipattern would collapse to rc=0). stderr: $stderr_mvfail"
fi
if printf '%s' "$stderr_mvfail" | grep -qE 'mv compact state failed \(rc=[1-9][0-9]*'; then
  pass "TC-COMPACT-MV-FAIL: compact_state mv WARNING carries real rc"
else
  fail "TC-COMPACT-MV-FAIL: missing rc-carrying WARNING. stderr: $stderr_mvfail"
fi

echo "TC-CHMOD-FAIL: PATH-shimmed chmod exits non-zero — chmod WARNING must carry rc (rc=0 would mean bash-! regression)"
shim_chmod_dir="$TEST_DIR/shim-chmod-only"
mkdir -p "$shim_chmod_dir"
# mv must succeed for control to reach chmod, so only shim chmod.
cat > "$shim_chmod_dir/chmod" <<'SHIM'
#!/bin/bash
exit 13
SHIM
chmod +x "$shim_chmod_dir/chmod"
dir_chmod="$TEST_DIR/tc-chmod-fail"
mkdir -p "$dir_chmod"
create_state_file "$dir_chmod" '{"active":true,"phase":"implement","updated_at":"2026-01-01T00:00:00+00:00"}'
stderr_chmod=$(echo "{\"cwd\": \"$dir_chmod\"}" | PATH="$shim_chmod_dir:$PATH" bash "$HOOK" 2>&1 >/dev/null || true)
if printf '%s' "$stderr_chmod" | grep -qE 'chmod 600 .* failed \(rc=13\)'; then
  pass "TC-CHMOD-FAIL: chmod WARNING carries the real rc (13), not bash-! collapsed value"
else
  fail "TC-CHMOD-FAIL: chmod WARNING missing or rc collapsed. stderr: $stderr_chmod"
fi
echo ""

# --------------------------------------------------------------------------
# TC-SENTINEL-PIN: pre-compact emits exact CONTEXT sentinel literals
# --------------------------------------------------------------------------
# These two sentinels are observability-only — no runtime consumer parses
# them — so a silent rename would never surface as a test failure elsewhere.
# Pin the literal strings here so triagers can trust grep against the diag
# log regardless of future refactors.
echo "TC-SENTINEL-PIN: PRE_COMPACT_SNAPSHOT_(RECORDED|FAILED) are emitted, not just present"
HOOK_SRC="$(dirname "$HOOK")/pre-compact.sh"
# Anchor the match to a line that begins with `echo` (after optional leading
# whitespace) so demotion to a comment, doc string, or never-executed branch
# cannot satisfy a bare literal grep.
if grep -qE '^[[:space:]]*echo .*PRE_COMPACT_SNAPSHOT_RECORDED=1' "$HOOK_SRC" \
   && grep -qE '^[[:space:]]*echo .*PRE_COMPACT_SNAPSHOT_FAILED=1' "$HOOK_SRC"; then
  pass "TC-SENTINEL-PIN: both sentinels emitted from echo lines"
else
  fail "TC-SENTINEL-PIN: one or both sentinels are not emitted (renamed, commented, or moved) in $HOOK_SRC"
fi
echo ""

# --------------------------------------------------------------------------
# TC-per-session-compact-independence-AC1: two sessions in the same state root write INDEPENDENT
# compact-state files (last-writer-wins resolved).
# --------------------------------------------------------------------------
# Drives two compacts in one state root under two distinct session ids (via
# CLAUDE_CODE_SESSION_ID, no .rite-session-id file so the env var wins). Each
# must land in its own .rite/sessions/<sid>.compact-state with its own
# active_issue. Before the fix both wrote the single shared .rite-compact-state
# and the second clobbered the first — this test would have caught that.
echo "TC-per-session-compact-independence-AC1: two sessions → independent compact-state files (no last-writer-wins)"
dirac1="$TEST_DIR/tc1371ac1"
mkdir -p "$dirac1/.rite/sessions"
sidA="session-aaaa-1371"
sidB="session-bbbb-1371"
printf '%s\n' '{"active": true, "phase": "implement", "issue_number": 100, "schema_version": 3, "session_id": "'"$sidA"'"}' > "$dirac1/.rite/sessions/${sidA}.flow-state"
printf '%s\n' '{"active": true, "phase": "review", "issue_number": 200, "schema_version": 3, "session_id": "'"$sidB"'"}' > "$dirac1/.rite/sessions/${sidB}.flow-state"

errA="$(mktemp "$TEST_DIR/stderr.XXXXXX")"
errB="$(mktemp "$TEST_DIR/stderr.XXXXXX")"
echo "{\"cwd\": \"$dirac1\"}" | CLAUDE_CODE_SESSION_ID="$sidA" bash "$HOOK" 2>"$errA" || true
echo "{\"cwd\": \"$dirac1\"}" | CLAUDE_CODE_SESSION_ID="$sidB" bash "$HOOK" 2>"$errB" || true

csA="$dirac1/.rite/sessions/${sidA}.compact-state"
csB="$dirac1/.rite/sessions/${sidB}.compact-state"
ac1_ok=true
if [ ! -f "$csA" ] || [ ! -f "$csB" ]; then
  fail "AC-1: expected both per-session compact-state files; A_exists=$([ -f "$csA" ] && echo y || echo n), B_exists=$([ -f "$csB" ] && echo y || echo n)"
  ac1_ok=false
else
  issueA=$(jq -r '.active_issue' "$csA" 2>/dev/null)
  issueB=$(jq -r '.active_issue' "$csB" 2>/dev/null)
  if [ "$issueA" != "100" ] || [ "$issueB" != "200" ]; then
    fail "AC-1: per-session snapshots clobbered — A.active_issue=$issueA (want 100), B.active_issue=$issueB (want 200)"
    ac1_ok=false
  fi
  # The legacy shared path must NOT be written by either per-session run.
  if [ -f "$dirac1/.rite-compact-state" ]; then
    fail "AC-1: legacy shared .rite-compact-state was written (per-session migration leaked to shared path)"
    ac1_ok=false
  fi
fi
if [ "$ac1_ok" = true ]; then
  pass "AC-1: sid A→issue 100 and sid B→issue 200 snapshots are independent (no last-writer-wins)"
fi
echo ""

# --- TC-LEGACY-FALLBACK: sid unresolvable → legacy .rite-compact-state written ---
# Complement of AC-1 (per-session isolation): when the session id cannot be resolved
# (no .rite-session-id file AND no CLAUDE_CODE_SESSION_ID / CLAUDE_SESSION_ID env),
# flow-state.sh path exits non-zero, FLOW_STATE="", and pre-compact.sh falls back to
# the legacy shared "$STATE_ROOT/.rite-compact-state". This pins the "preserving
# pre-per-session behavior" claim in the COMPACT_STATE derivation: the compact-state
# write is NOT guarded by [ -f "$FLOW_STATE" ], so the legacy path is actually written
# with compact_state=recovering. env -u strips any ambient session id so the fallback
# is reproduced regardless of the test runner's environment (.rite-session-id always
# wins over env, so existing fixture-based TCs are unaffected).
echo "TC-LEGACY-FALLBACK: sid unresolvable → legacy .rite-compact-state written (recovering)"
dirlf="$TEST_DIR/tc-legacy-fallback"
mkdir -p "$dirlf"
lf_stderr="$(mktemp "$TEST_DIR/stderr.XXXXXX")"
lf_rc=0
echo "{\"cwd\": \"$dirlf\"}" | env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID bash "$HOOK" 2>"$lf_stderr" || lf_rc=$?
LAST_STDERR_FILE="$lf_stderr"
cs_state=$(jq -r '.compact_state' "$dirlf/.rite-compact-state" 2>/dev/null)
if [ "$lf_rc" -ne 0 ]; then
  fail "Hook should exit 0 on legacy fallback (got rc=$lf_rc)"
elif [ ! -f "$dirlf/.rite-compact-state" ]; then
  fail "legacy .rite-compact-state should be written when session id is unresolvable"
elif [ -e "$dirlf/.rite/sessions" ]; then
  fail "per-session .rite/sessions must not be created on the legacy fallback path"
elif [ "$cs_state" != "recovering" ]; then
  fail "legacy compact_state should be 'recovering', got '$cs_state'"
elif ! grep -q 'flow-state.sh path resolution failed' "$lf_stderr"; then
  fail "expected resolver-failure WARNING on stderr"
else
  pass "sid unresolvable → legacy .rite-compact-state written with compact_state=recovering + resolver WARNING"
fi
echo ""

echo "T-04: active workflow → empty stdout, stderr compact detected, recovering+trigger written"
dir_t04="$TEST_DIR/tc-t04"
mkdir -p "$dir_t04/.rite/sessions"
sid_t04="test-sid-$(basename "$dir_t04")"
echo "$sid_t04" > "$dir_t04/.rite-session-id"
printf '# rite test sandbox config\n' > "$dir_t04/rite-config.yml"
echo '{"active": true, "phase": "implement", "issue_number": 2512, "branch": "fix/issue-2512-x", "updated_at": "2020-01-01T00:00:00+00:00"}' \
  > "$dir_t04/.rite/sessions/${sid_t04}.flow-state"
t04_err="$(mktemp "$TEST_DIR/stderr.XXXXXX")"
t04_out=$(echo "{\"cwd\": \"$dir_t04\", \"trigger\": \"manual\"}" | bash "$HOOK" 2>"$t04_err") || t04_rc=$?
t04_rc=${t04_rc:-0}
LAST_STDERR_FILE="$t04_err"
cs_t04="$(compact_state_path "$dir_t04" "$sid_t04")"
cs_state=$(jq -r '.compact_state' "$cs_t04" 2>/dev/null)
cs_trig=$(jq -r '.trigger' "$cs_t04" 2>/dev/null)
if [ "$t04_rc" -eq 0 ] \
  && [ -z "$t04_out" ] \
  && grep -q "compact detected" "$t04_err" \
  && [ "$cs_state" = "recovering" ] \
  && [ "$cs_trig" = "manual" ] \
  && [ -f "$dir_t04/.rite/work-memory/issue-2512.md" ]; then
  pass "T-04: stdout empty, stderr compact detected, compact-state recovering+trigger=manual, snapshot kept"
else
  fail "T-04: rc=$t04_rc stdout='$t04_out' state=$cs_state trigger=$cs_trig snapshot=$([ -f "$dir_t04/.rite/work-memory/issue-2512.md" ] && echo yes || echo no) stderr=$(cat "$t04_err")"
fi
echo ""

# --- Summary ---
echo "=== Results: $PASS passed, $FAIL failed, $SKIP skipped ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
