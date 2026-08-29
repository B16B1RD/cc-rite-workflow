#!/bin/bash
# Tests for session-start.sh
# Usage: bash plugins/rite/hooks/tests/session-start.test.sh
set -euo pipefail

issue_text() { printf 'Issue #%s' "$1"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../session-start.sh"
# Canonicalize the sandbox root: on macOS $TMPDIR is under /var/folders (a
# symlink to /private/var/...), while session-start.sh resolves paths via
# state-path-resolve.sh (git rev-parse) to the /private form. Comparing the raw
# mktemp path against the canonical one would spuriously fail the reap-gate
# path-equality checks (Family D — TC-6, T-03, TC-1968-*).
#
# Two steps, not `$(cd "$(mktemp -d)" && pwd -P)`: bash `cd ""` returns 0 without
# changing directory, so a failed mktemp inside that nesting would yield the
# current directory (the repository checkout under CI) with a zero exit status,
# and the `rm -rf "$TEST_DIR"` in the EXIT trap below would delete it.
TEST_DIR="$(mktemp -d)" || exit 1
TEST_DIR="$(cd "$TEST_DIR" && pwd -P)" || exit 1
LAST_STDERR_FILE=""
PASS=0
FAIL=0

# Prerequisite check: jq is required by session-start.sh
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi

# Clean session-id env. session-start.sh resolves the active state
# file via flow-state.sh, which is now env-first; the sandboxes here simulate a
# session through `.rite-session-id`, so the dogfooding session's ambient
# CLAUDE_CODE_SESSION_ID must not leak in (it would point the hook at a foreign
# per-session state file). It also keeps the env-absent branch of the conditional
# `.rite-session-id` write under test below as the default. Tests that need env
# present set it explicitly. (run-tests.sh unsets the same vars for suite runs.)
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID

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

# Helper: show captured stderr on failure for debugging
show_stderr() {
  local stderr_file="${LAST_STDERR_FILE:-}"
  if [ -s "$stderr_file" ]; then
    echo "    stderr: $(cat "$stderr_file")"
  fi
}

# Helper: create a per-session state file in the given directory (schema v3).
# Writes .rite-session-id and the per-session .rite/sessions/<sid>.flow-state.
# Args: $1 = dir, $2 = JSON content (legacy `.rite-flow-state` content shape OK —
# active/issue_number/phase/branch/next_action/loop_count are read by the hook).
# A deterministic sid is used so run_hook (no explicit session_id arg) still resolves
# the same per-session file via .rite-session-id fallback in flow-state.sh path.
# Note: schema_version is NOT injected — fixtures that need migration-skip behavior
# (e.g., phase value preservation across the auto-migrate step in session-start.sh)
# should encode `"schema_version": 3` directly in $content.
create_state_file() {
  local dir="$1"
  local content="$2"
  local sid="${3:-test-sid-$(basename "$dir")}"
  mkdir -p "$dir/.rite/sessions"
  printf '%s' "$sid" > "$dir/.rite-session-id"
  # Inject schema_version=3 if not already present so the auto-migrate step
  # in session-start.sh skips the file and the original phase value is read by
  # the hook (otherwise legacy phase names like `implementing` get rewritten to
  # `implement` mid-test). Tests that intentionally exercise the migrate path
  # should pass content with a different schema_version value.
  local merged
  if printf '%s' "$content" | grep -q '"schema_version"'; then
    merged="$content"
  elif printf '%s' "$content" | jq -e . >/dev/null 2>&1; then
    merged=$(printf '%s' "$content" | jq -c '. + {schema_version: 3}')
  else
    # Non-JSON (broken-JSON fixtures) — write content verbatim so tests that
    # exercise corrupt-state code paths still see invalid JSON.
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
# session-start.sh's _cleanup_stale_compact derivation from the resolved
# STATE_FILE: .rite/sessions/<sid>.flow-state → .compact-state.
compact_state_path() {
  local dir="$1"
  local sid="${2:-test-sid-$(basename "$dir")}"
  echo "$dir/.rite/sessions/${sid}.compact-state"
}

# Helper: run session-start hook with given CWD, capture stdout and stderr
run_hook() {
  local cwd="$1"
  local rc=0
  local output
  LAST_STDERR_FILE="$(mktemp "$TEST_DIR/stderr.XXXXXX")"
  output=$(echo "{\"cwd\": \"$cwd\"}" | bash "$HOOK" 2>"$LAST_STDERR_FILE") || rc=$?
  echo "$output"
  return $rc
}

# Helper: run session-start hook with given CWD and source field
run_hook_with_source() {
  local cwd="$1"
  local source="$2"
  local rc=0
  local output
  LAST_STDERR_FILE="$(mktemp "$TEST_DIR/stderr.XXXXXX")"
  output=$(echo "{\"cwd\": \"$cwd\", \"source\": \"$source\"}" | bash "$HOOK" 2>"$LAST_STDERR_FILE") || rc=$?
  echo "$output"
  return $rc
}

# Helper: run session-start hook with CWD, source, and explicit session_id
# Produces a hook JSON payload containing session_id so check_session_ownership
# can compare against the state file's session_id.
run_hook_with_session() {
  local cwd="$1"
  local source="$2"
  local session_id="$3"
  local rc=0
  local output
  LAST_STDERR_FILE="$(mktemp "$TEST_DIR/stderr.XXXXXX")"
  output=$(jq -n --arg cwd "$cwd" --arg src "$source" --arg sid "$session_id" \
    '{cwd: $cwd, source: $src, session_id: $sid}' \
    | bash "$HOOK" 2>"$LAST_STDERR_FILE") || rc=$?
  echo "$output"
  return $rc
}

# ISO 8601 timestamp helper for state files
# Args: $1 = offset in seconds (negative = past, default 0 = now)
iso8601_now() {
  local offset="${1:-0}"
  if date -u -d "@$(( $(date +%s) + offset ))" +"%Y-%m-%dT%H:%M:%S+00:00" 2>/dev/null; then
    return 0
  fi
  # macOS fallback
  date -u -r "$(( $(date +%s) + offset ))" +"%Y-%m-%dT%H:%M:%S+00:00"
}

echo "=== session-start.sh tests ==="
echo ""

# --------------------------------------------------------------------------
# TC-001: No CWD in input → exit 0
# --------------------------------------------------------------------------
echo "TC-001: No CWD in input → exit 0"
output=$(echo "{}" | bash "$HOOK" 2>/dev/null) && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ -z "$output" ]; then
  pass "Missing CWD → exit 0 with no output"
else
  fail "Expected exit 0 with no output, got rc=$rc, output='$output'"
fi
echo ""

# --------------------------------------------------------------------------
# TC-006b: circuit-breaker stop reason is distinct from an ordinary interruption
# --------------------------------------------------------------------------
echo "TC-006b: stop_reason changes compact interruption notice to failure stop"
dir006b="$TEST_DIR/tc006b"
mkdir -p "$dir006b"
create_state_file "$dir006b" '{
  "active": true,
  "issue_number": 2045,
  "phase": "review",
  "stop_reason": "circuit-breaker:max-cycles"
}'
output=$(run_hook_with_source "$dir006b" "compact")
if echo "$output" | grep -q "失敗停止した rite workflow" && \
   echo "$output" | grep -q "cycle が上限に到達" && \
   ! echo "$output" | grep -q "中断した rite workflow"; then
  pass "stop_reason produces a failure-specific compact notice"
else
  fail "Expected failure-specific stop notice, got: $output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-006c: startup defensive reset preserves and surfaces the stop reason
# --------------------------------------------------------------------------
echo "TC-006c: startup reset reports circuit-breaker failure reason"
dir006c="$TEST_DIR/tc006c"
mkdir -p "$dir006c"
create_state_file "$dir006c" '{
  "active": true,
  "issue_number": 2045,
  "branch": "fix/issue-2045",
  "phase": "review",
  "stop_reason": "circuit-breaker:divergence"
}'
output=$(run_hook_with_source "$dir006c" "startup")
if echo "$output" | grep -q "失敗停止した rite workflow の状態をリセット" && \
   echo "$output" | grep -q "収束トレンドの発散を検出"; then
  pass "startup defensive reset surfaces the durable failure reason"
else
  fail "Expected failure-specific startup reset notice, got: $output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-002: CWD is not a directory → exit 0
# --------------------------------------------------------------------------
echo "TC-002: CWD is not a directory → exit 0"
output=$(echo "{\"cwd\": \"$TEST_DIR/nonexistent\"}" | bash "$HOOK" 2>/dev/null) && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ -z "$output" ]; then
  pass "Nonexistent CWD → exit 0 with no output"
else
  fail "Expected exit 0 with no output, got rc=$rc, output='$output'"
fi
echo ""

# --------------------------------------------------------------------------
# TC-003: No state file + issue branch + source=compact → silent (no message)
# Note: Tests compact source path. TC-025 tests the same scenario with explicit startup source.
# --------------------------------------------------------------------------
echo "TC-003: No state file + issue branch + source=compact → silent (no message)"
git_repo_003="$TEST_DIR/git_tc003"
mkdir -p "$git_repo_003"
(cd "$git_repo_003" && git init -q && git -c user.name="test" -c user.email="test@test.com" commit --allow-empty -m "init" -q && git checkout -b "feat/issue-123-test-feature" -q)

output=$(run_hook_with_source "$git_repo_003" "compact")
if [ -z "$output" ]; then
  pass "No state file + issue branch + compact → no output (branch detection noise removed)"
else
  fail "Expected no output, got: $output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-004: No state file and no issue branch → exit 0 silently
# --------------------------------------------------------------------------
echo "TC-004: No state file and no issue branch → exit 0 silently"
git_repo_004="$TEST_DIR/git_tc004"
mkdir -p "$git_repo_004"
(cd "$git_repo_004" && git init -q && git -c user.name="test" -c user.email="test@test.com" commit --allow-empty -m "init" -q)

output=$(run_hook "$git_repo_004")
if [ -z "$output" ]; then
  pass "No state file, no issue branch → no output"
else
  fail "Expected no output, got: $output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-005: State file exists but active=false → exit 0 silently
# --------------------------------------------------------------------------
echo "TC-005: State file exists but active=false → exit 0 silently"
dir005="$TEST_DIR/tc005"
mkdir -p "$dir005"
create_state_file "$dir005" '{"active": false, "issue_number": 42}'

output=$(run_hook "$dir005")
if [ -z "$output" ]; then
  pass "active=false → no output"
else
  fail "Expected no output, got: $output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-006: State file with active=true + source=compact → re-inject message
# --------------------------------------------------------------------------
echo "TC-006: State file with active=true + source=compact → re-inject message"
dir006="$TEST_DIR/tc006"
mkdir -p "$dir006"
create_state_file "$dir006" '{
  "active": true,
  "issue_number": 42,
  "phase": "implementing",
  "next_action": "continue work",
  "loop_count": 3
}'

output=$(run_hook_with_source "$dir006" "compact")
if echo "$output" | grep -q "中断した rite workflow を検出" && \
   echo "$output" | grep -q "$(issue_text 42)" && \
   echo "$output" | grep -q "phase: implementing" && \
   echo "$output" | grep -q "/rite:recover"; then
  pass "Interruption notice contains issue + phase + resume hint"
else
  fail "Interruption notice missing expected fields, got: $output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-007: State file missing issue_number + source=compact → "issue_number is missing" warning
# cycle 12 HIGH F-02: cycle 11 で IFS=$'\t' → $'\x1f' に変更 (cycle 11 MEDIUM F-04) したため、
# 旧 buggy field shift 挙動 (ISSUE='test' + CRITICAL) は消滅。unit separator は empty field を
# preserve するため ISSUE="" になり、session-start.sh の `if [ -z "$ISSUE" ]` guard が正しく
# 発火して "issue_number is missing. Use /rite:recover to recover" warning を出力する。
# 旧 TC-007 assertion は buggy 挙動を期待していたため、fixed 挙動に合わせて更新。
# --------------------------------------------------------------------------
echo "TC-007: State file missing issue_number + source=compact → issue_number missing warning"
dir007="$TEST_DIR/tc007"
mkdir -p "$dir007"
create_state_file "$dir007" '{"active": true, "phase": "test"}'

output=$(run_hook_with_source "$dir007" "compact")
if echo "$output" | grep -q "issue_number is missing" && \
   echo "$output" | grep -q "/rite:recover"; then
  pass "Missing issue_number → empty ISSUE guard fires with recovery hint (IFS=\$'\\x1f' correctly preserves empty field)"
else
  fail "Expected 'issue_number is missing' + '/rite:recover' guard (cycle 11 IFS fix should have eliminated field shift), got: $output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-008: State file with null/missing fields + source=compact → defaults to "unknown"
# --------------------------------------------------------------------------
echo "TC-008: State file with null/missing optional fields + source=compact → defaults"
dir008="$TEST_DIR/tc008"
mkdir -p "$dir008"
create_state_file "$dir008" '{"active": true, "issue_number": 99}'

output=$(run_hook_with_source "$dir008" "compact")
if echo "$output" | grep -q "$(issue_text 99)" && \
   echo "$output" | grep -q "phase: unknown"; then
  pass "Missing optional fields → phase defaults to unknown"
else
  fail "Expected phase default (unknown), got: $output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-009: Stale temp file cleanup (older than 1 minute) - source=compact
# --------------------------------------------------------------------------
echo "TC-009: Stale temp file cleanup"
dir009="$TEST_DIR/tc009"
mkdir -p "$dir009"
create_state_file "$dir009" '{"active": true, "issue_number": 1}'

# Create a stale temp file (simulate old file with touch -t)
stale_file="$dir009/.rite-flow-state.tmp.12345"
touch "$stale_file"
# Set modification time to 2 minutes ago (touch -t format: YYYYMMDDhhmm)
touch -t "$(date -u -d '2 minutes ago' +'%Y%m%d%H%M' 2>/dev/null || date -u -v-2M +'%Y%m%d%H%M')" "$stale_file" 2>/dev/null || true

# Run hook with compact source (startup hits defensive reset which exits before cleanup)
output=$(run_hook_with_source "$dir009" "compact")

if [ ! -f "$stale_file" ]; then
  pass "Stale temp file cleaned up"
else
  fail "Stale temp file not cleaned up: $stale_file"
fi
echo ""

# --------------------------------------------------------------------------
# TC-010: Invalid JSON in state file → line 111 fallback (ACTIVE=false) → exit 0
# Note: Line 111's `jq '.active' || ACTIVE=false` catches invalid JSON before
# reaching the defense-in-depth fallback at line 213-221. Line 213-221 is only
# reachable if the file becomes corrupt between the two jq reads (race condition)
# and cannot be unit-tested with static file content.
# --------------------------------------------------------------------------
echo "TC-010: Invalid JSON in state file → exit 0 (line 111 ACTIVE fallback)"
dir010="$TEST_DIR/tc010"
mkdir -p "$dir010"
# Write broken JSON via create_state_file so the per-session path resolver finds it
create_state_file "$dir010" "{broken json"

output=$(run_hook_with_source "$dir010" "compact") && rc=0 || rc=$?
if [ $rc -eq 0 ]; then
  # Verify no jq parse error leaked to stderr (2>/dev/null on line 111 suppresses it)
  if [ -s "$LAST_STDERR_FILE" ]; then
    stderr_content=$(cat "$LAST_STDERR_FILE")
    # Only jq parse errors are unexpected; rite: warnings are expected (defense-in-depth)
    if echo "$stderr_content" | grep -qv "^rite:"; then
      fail "Unexpected stderr output: $stderr_content"
    else
      pass "Invalid JSON → exit 0 (line 111 ACTIVE fallback, no jq error on stderr)"
    fi
  else
    pass "Invalid JSON → exit 0 (line 111 ACTIVE fallback, clean stderr)"
  fi
else
  fail "Expected exit 0 for invalid JSON (line 111 ACTIVE fallback), got exit $rc"
fi
echo ""

# --------------------------------------------------------------------------
# TC-011: Field extraction with process substitution and IFS=$'\x1f' (unit separator) — source=compact
# cycle 13 HIGH F-01: cycle 11 MEDIUM F-04 で IFS を $'\t' → $'\x1f' に変更したが TC-011 の
# 文言更新が漏れていた (cycle 12 で TC-007 のみ更新)。spaces / special chars を含むフィールドが
# unit separator 区切りで正しく抽出されることを verify する目的は不変、文言のみ現行実装に揃える。
# --------------------------------------------------------------------------
echo "TC-011: Field extraction with unit-separator-delimited IFS"
dir011="$TEST_DIR/tc011"
mkdir -p "$dir011"
create_state_file "$dir011" '{
  "active": true,
  "issue_number": 77,
  "phase": "Phase with spaces",
  "next_action": "Action: with special chars",
  "loop_count": 5
}'

output=$(run_hook_with_source "$dir011" "compact")
if echo "$output" | grep -q "$(issue_text 77)" && \
   echo "$output" | grep -q "phase: Phase with spaces"; then
  pass "Unit-separator-delimited field extraction handles spaces in phase"
else
  fail "Field extraction failed with spaces, got: $output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-012: source=compact + compact_state=recovering → interruption notice
# PostCompact hook now handles recovery; SessionStart(compact) falls through to the notice.
# --------------------------------------------------------------------------
echo "TC-012: source=compact + compact_state=recovering → interruption notice"
dir012="$TEST_DIR/tc012"
mkdir -p "$dir012"
create_state_file "$dir012" '{"active": true, "issue_number": 55, "phase": "implementing"}'
echo '{"compact_state": "recovering", "active_issue": 55}' > "$dir012/.rite-compact-state"

output=$(run_hook_with_source "$dir012" "compact")
if echo "$output" | grep -q "中断した rite workflow を検出" && \
   echo "$output" | grep -q "$(issue_text 55)"; then
  pass "source=compact + recovering → interruption notice (PostCompact handles recovery)"
else
  fail "Expected interruption notice with issue 55, got: $output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-013: source=compact + compact_state=normal → fall through to interruption notice
# --------------------------------------------------------------------------
echo "TC-013: source=compact + compact_state=normal → fall through to interruption notice"
dir013="$TEST_DIR/tc013"
mkdir -p "$dir013"
create_state_file "$dir013" '{"active": true, "issue_number": 56, "phase": "reviewing"}'
echo '{"compact_state": "normal"}' > "$dir013/.rite-compact-state"

output=$(run_hook_with_source "$dir013" "compact")
if echo "$output" | grep -q "中断した rite workflow を検出" && \
   echo "$output" | grep -q "$(issue_text 56)"; then
  pass "source=compact + normal → interruption notice"
else
  fail "Expected interruption notice, got: $output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-014: source=compact + no .rite-compact-state → fall through to interruption notice
# --------------------------------------------------------------------------
echo "TC-014: source=compact + no .rite-compact-state → fall through to interruption notice"
dir014="$TEST_DIR/tc014"
mkdir -p "$dir014"
create_state_file "$dir014" '{"active": true, "issue_number": 57, "phase": "testing"}'

output=$(run_hook_with_source "$dir014" "compact")
if echo "$output" | grep -q "中断した rite workflow を検出" && \
   echo "$output" | grep -q "$(issue_text 57)"; then
  pass "source=compact + no compact state file → interruption notice"
else
  fail "Expected interruption notice, got: $output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-015: source=clear + compact_state=recovering → defensive reset
# /clear now applies the same defensive reset as startup (compact recovery is handled by PostCompact).
# --------------------------------------------------------------------------
echo "TC-015: source=clear + compact_state=recovering → defensive reset"
dir015="$TEST_DIR/tc015"
mkdir -p "$dir015"
create_state_file "$dir015" '{"active": true, "issue_number": 58, "phase": "implementing"}'
echo '{"compact_state": "recovering", "active_issue": 58}' > "$dir015/.rite-compact-state"

output=$(run_hook_with_source "$dir015" "clear")
ACTIVE_VAL=$(jq -r '.active' "$(state_file_path "$dir015")" 2>/dev/null)
if [ "$ACTIVE_VAL" = "false" ] && \
   ! [ -f "$dir015/.rite-compact-state" ] && \
   echo "$output" | grep -q "リセットしました"; then
  pass "source=clear + recovering → defensive reset (active=false, compact state cleaned)"
else
  fail "Expected defensive reset, got active=$ACTIVE_VAL, compact_exists=$([ -f "$dir015/.rite-compact-state" ] && echo yes || echo no), output: $output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-per-session-legacy-compact-cleanup: source=clear → _cleanup_stale_compact removes BOTH the per-session
# compact-state and the legacy shared file.
# Non-vacuous: seeds the per-session file so a regression that only cleans the
# legacy shared path (the pre-fix behavior) would leave the per-session file
# behind and fail this assertion.
# --------------------------------------------------------------------------
echo "TC-per-session-legacy-compact-cleanup: source=clear → per-session AND legacy compact-state both cleaned"
dir1371="$TEST_DIR/tc1371"
mkdir -p "$dir1371"
create_state_file "$dir1371" '{"active": true, "issue_number": 1371, "phase": "implement"}'
cs1371_session="$(compact_state_path "$dir1371")"
cs1371_legacy="$dir1371/.rite-compact-state"
echo '{"compact_state": "recovering", "active_issue": 1371}' > "$cs1371_session"
echo '{"compact_state": "recovering", "active_issue": 1371}' > "$cs1371_legacy"

run_hook_with_source "$dir1371" "clear" >/dev/null
if ! [ -f "$cs1371_session" ] && ! [ -f "$cs1371_legacy" ]; then
  pass "Both per-session and legacy compact-state removed on defensive reset"
else
  fail "Compact-state not fully cleaned: per_session_exists=$([ -f "$cs1371_session" ] && echo yes || echo no), legacy_exists=$([ -f "$cs1371_legacy" ] && echo yes || echo no)"
fi
echo ""

# --------------------------------------------------------------------------
# TC-016: source=startup + compact_state=blocked + active=true → defensive reset
# --------------------------------------------------------------------------
echo "TC-016: source=startup + compact_state=blocked + active=true → defensive reset"
dir016="$TEST_DIR/tc016"
mkdir -p "$dir016"
create_state_file "$dir016" '{"active": true, "issue_number": 59, "phase": "reviewing"}'
echo '{"compact_state": "recovering", "active_issue": 59}' > "$dir016/.rite-compact-state"

output=$(run_hook_with_source "$dir016" "startup")
if echo "$output" | grep -q "前回のセッション状態が残っていたためリセットしました" && \
   ! echo "$output" | grep -q "STOP. DO NOT CONTINUE"; then
  pass "source=startup + blocked → defensive reset message (not STOP, not CRITICAL)"
else
  fail "Expected defensive reset message (not STOP), got: $output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-017: source=startup + compact_state=blocked + active=false → clean compact state
# --------------------------------------------------------------------------
echo "TC-017: source=startup + compact_state=blocked + active=false → clean compact state"
dir017="$TEST_DIR/tc017"
mkdir -p "$dir017"
create_state_file "$dir017" '{"active": false, "issue_number": 60, "phase": "completed"}'
echo '{"compact_state": "recovering", "active_issue": 60}' > "$dir017/.rite-compact-state"

output=$(run_hook_with_source "$dir017" "startup") && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ ! -f "$dir017/.rite-compact-state" ]; then
  pass "source=startup + active=false → stale compact state cleaned up"
else
  fail "Expected exit 0 and .rite-compact-state removed, got rc=$rc"
fi
echo ""

# --------------------------------------------------------------------------
# TC-018: source=startup + compact_state=blocked + no flow state → clean compact state
# --------------------------------------------------------------------------
echo "TC-018: source=startup + compact_state=blocked + no flow state → clean compact state"
dir018="$TEST_DIR/tc018"
mkdir -p "$dir018"
# No .rite-flow-state at all
echo '{"compact_state": "recovering", "active_issue": 61}' > "$dir018/.rite-compact-state"

output=$(run_hook_with_source "$dir018" "startup") && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ ! -f "$dir018/.rite-compact-state" ]; then
  pass "source=startup + no flow state → stale compact state cleaned up"
else
  fail "Expected exit 0 and .rite-compact-state removed, got rc=$rc"
fi
echo ""

# --------------------------------------------------------------------------
# TC-019: source=startup + compact_state=blocked + active=true → compact state cleaned
# --------------------------------------------------------------------------
echo "TC-019: source=startup + compact_state=blocked + active=true → compact state cleaned"
dir019="$TEST_DIR/tc019"
mkdir -p "$dir019"
create_state_file "$dir019" '{"active": true, "issue_number": 62, "phase": "implementing"}'
echo '{"compact_state": "recovering", "active_issue": 62}' > "$dir019/.rite-compact-state"

output=$(run_hook_with_source "$dir019" "startup") && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ ! -f "$dir019/.rite-compact-state" ]; then
  pass "source=startup + active=true → compact state cleaned (defensive reset calls _cleanup_stale_compact)"
else
  fail "Expected exit 0 and .rite-compact-state removed, got rc=$rc"
fi
echo ""

# --------------------------------------------------------------------------
# TC-020: source=startup + compact_state=blocked + lockdir → both cleaned
# --------------------------------------------------------------------------
echo "TC-020: source=startup + compact_state=blocked + lockdir → both cleaned"
dir020="$TEST_DIR/tc020"
mkdir -p "$dir020"
create_state_file "$dir020" '{"active": false, "issue_number": 63, "phase": "completed"}'
echo '{"compact_state": "recovering", "active_issue": 63}' > "$dir020/.rite-compact-state"
mkdir -p "$dir020/.rite-compact-state.lockdir"

output=$(run_hook_with_source "$dir020" "startup") && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ ! -f "$dir020/.rite-compact-state" ] && [ ! -d "$dir020/.rite-compact-state.lockdir" ]; then
  pass "source=startup + active=false → compact state and lockdir both cleaned"
else
  fail "Expected exit 0 and both .rite-compact-state and .lockdir removed, got rc=$rc"
fi
echo ""

# --------------------------------------------------------------------------
# TC-021: source=compact + compact_state=recovering + active=false → clean
# PostCompact handles active flows; SessionStart always cleans up inactive state.
# --------------------------------------------------------------------------
echo "TC-021: source=compact + compact_state=recovering + active=false → compact state cleaned"
dir021="$TEST_DIR/tc021"
mkdir -p "$dir021"
create_state_file "$dir021" '{"active": false, "issue_number": 64, "phase": "completed"}'
echo '{"compact_state": "recovering", "active_issue": 64}' > "$dir021/.rite-compact-state"

output=$(run_hook_with_source "$dir021" "compact") && rc=0 || rc=$?
if [ $rc -eq 0 ] && ! [ -f "$dir021/.rite-compact-state" ]; then
  pass "source=compact + active=false → compact state cleaned"
else
  fail "Expected exit 0 and .rite-compact-state cleaned, got rc=$rc, exists=$([ -f "$dir021/.rite-compact-state" ] && echo yes || echo no)"
fi
echo ""

# --------------------------------------------------------------------------
# TC-022: source=startup + active=false + no compact state → no-op
# --------------------------------------------------------------------------
echo "TC-022: source=startup + active=false + no compact state → no-op"
dir022="$TEST_DIR/tc022"
mkdir -p "$dir022"
create_state_file "$dir022" '{"active": false, "issue_number": 65, "phase": "completed"}'
# No .rite-compact-state file

output=$(run_hook_with_source "$dir022" "startup") && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ ! -f "$dir022/.rite-compact-state" ]; then
  pass "source=startup + active=false + no compact state → no-op (no error)"
else
  fail "Expected exit 0 with no errors, got rc=$rc"
fi
echo ""

# --------------------------------------------------------------------------
# TC-023: source=startup + active=true + phase=completed → silent reset + compact cleanup
# --------------------------------------------------------------------------
echo "TC-023: source=startup + active=true + phase=completed → silent reset + compact cleanup"
dir023="$TEST_DIR/tc023"
mkdir -p "$dir023"
create_state_file "$dir023" '{"active": true, "issue_number": 70, "branch": "fix/issue-70-test", "phase": "completed"}'
echo '{"compact_state": "recovering", "active_issue": 70}' > "$dir023/.rite-compact-state"

output=$(run_hook_with_source "$dir023" "startup") && rc=0 || rc=$?
ACTIVE_AFTER=$(jq -r '.active' "$(state_file_path "$dir023")" 2>/dev/null)
if [ $rc -eq 0 ] && [ -z "$output" ] && [ "$ACTIVE_AFTER" = "false" ] && [ ! -f "$dir023/.rite-compact-state" ]; then
  pass "source=startup + phase=completed → silent reset (no message, active=false, compact state cleaned)"
else
  fail "Expected exit 0, no output, active=false, compact cleaned. Got rc=$rc, active=$ACTIVE_AFTER, compact=$([ -f "$dir023/.rite-compact-state" ] && echo 'exists' || echo 'removed'), output='$output'"
fi
echo ""

# --------------------------------------------------------------------------
# TC-024: source=startup + active=true + phase=implementing → message shown
# --------------------------------------------------------------------------
echo "TC-024: source=startup + active=true + phase=implementing → message shown"
dir024="$TEST_DIR/tc024"
mkdir -p "$dir024"
create_state_file "$dir024" '{"active": true, "issue_number": 71, "branch": "feat/issue-71-test", "phase": "implementing"}'

output=$(run_hook_with_source "$dir024" "startup") && rc=0 || rc=$?
ACTIVE_AFTER=$(jq -r '.active' "$(state_file_path "$dir024")" 2>/dev/null)
if [ $rc -eq 0 ] && [ "$ACTIVE_AFTER" = "false" ] && echo "$output" | grep -q "前回のセッション状態が残っていたためリセットしました"; then
  pass "source=startup + phase=implementing → reset message shown and active=false"
else
  fail "Expected reset message and active=false, got rc=$rc, active=$ACTIVE_AFTER, output='$output'"
fi
echo ""

# --------------------------------------------------------------------------
# TC-025: No state file + issue branch + source=startup → silent
# --------------------------------------------------------------------------
echo "TC-025: No state file + issue branch + source=startup → silent"
git_repo_025="$TEST_DIR/git_tc025"
mkdir -p "$git_repo_025"
(cd "$git_repo_025" && git init -q && git -c user.name="test" -c user.email="test@test.com" commit --allow-empty -m "init" -q && git checkout -b "feat/issue-200-test" -q)

output=$(run_hook_with_source "$git_repo_025" "startup") && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ -z "$output" ]; then
  pass "No state file + issue branch + startup → no output"
else
  fail "Expected exit 0 with no output, got rc=$rc, output='$output'"
fi
echo ""

# --------------------------------------------------------------------------
# TC-026: source=startup + active=true + phase=completed + needs_clear=true → silent reset
# Edge case: completed takes priority over needs_clear flag
# --------------------------------------------------------------------------
echo "TC-026: source=startup + phase=completed + needs_clear=true → silent reset (completed priority)"
dir026="$TEST_DIR/tc026"
mkdir -p "$dir026"
create_state_file "$dir026" '{"active": true, "issue_number": 73, "branch": "fix/issue-73-test", "phase": "completed", "needs_clear": true}'

output=$(run_hook_with_source "$dir026" "startup") && rc=0 || rc=$?
ACTIVE_AFTER=$(jq -r '.active' "$(state_file_path "$dir026")" 2>/dev/null)
if [ $rc -eq 0 ] && [ -z "$output" ] && [ "$ACTIVE_AFTER" = "false" ]; then
  pass "source=startup + phase=completed + needs_clear=true → silent reset (completed takes priority)"
else
  fail "Expected exit 0, no output, active=false. Got rc=$rc, active=$ACTIVE_AFTER, output='$output'"
fi
echo ""

# --------------------------------------------------------------------------
# TC-027: source=startup + active=true + no issue_number + phase=implementing → silent reset, no message
# Tests the code path where ISSUE is empty after defensive reset (phase != completed)
# --------------------------------------------------------------------------
echo "TC-027: source=startup + active=true + no issue_number → silent reset, no message"
dir027="$TEST_DIR/tc027"
mkdir -p "$dir027"
create_state_file "$dir027" '{"active": true, "phase": "implementing"}'

output=$(run_hook_with_source "$dir027" "startup") && rc=0 || rc=$?
ACTIVE_AFTER=$(jq -r '.active' "$(state_file_path "$dir027")" 2>/dev/null)
if [ $rc -eq 0 ] && [ -z "$output" ] && [ "$ACTIVE_AFTER" = "false" ]; then
  pass "source=startup + no issue_number → silent reset (no message because ISSUE is empty)"
else
  fail "Expected exit 0, no output, active=false. Got rc=$rc, active=$ACTIVE_AFTER, output='$output'"
fi
echo ""

# --------------------------------------------------------------------------
# TC-T01: own-session startup → reset (session_id matches)
# --------------------------------------------------------------------------
echo "TC-T01: own-session startup → reset proceeds"
dirT01="$TEST_DIR/tcT01"
mkdir -p "$dirT01"
sid_t01="ses-T01-$(date +%s)"
ts_t01=$(iso8601_now 0)
create_state_file "$dirT01" \
  "{\"active\": true, \"issue_number\": 200, \"branch\": \"feat/issue-200-own\", \"phase\": \"implementing\", \"session_id\": \"$sid_t01\", \"updated_at\": \"$ts_t01\"}" \
  "$sid_t01"

output=$(run_hook_with_session "$dirT01" "startup" "$sid_t01") && rc=0 || rc=$?
ACTIVE_AFTER=$(jq -r '.active' "$(state_file_path "$dirT01" "$sid_t01")" 2>/dev/null)
if [ $rc -eq 0 ] && [ "$ACTIVE_AFTER" = "false" ] && echo "$output" | grep -q "前回のセッション状態が残っていたためリセットしました"; then
  pass "TC-T01: own-session → reset (active=false, message shown)"
else
  fail "TC-T01: expected own-session reset; got rc=$rc, active=$ACTIVE_AFTER, output='$output'"
fi
echo ""

# --------------------------------------------------------------------------
# TC-T02: other-session startup → SKIP reset (file unchanged)
# --------------------------------------------------------------------------
echo "TC-T02: other-session startup → reset skipped (regression guard)"
dirT02="$TEST_DIR/tcT02"
mkdir -p "$dirT02"
sid_state="ses-T02-state-$(date +%s)"
sid_hook="ses-T02-hook-$(date +%s)"
ts_t02=$(iso8601_now 0)
state_t02='{"schema_version": 3, "active": true, "issue_number": 201, "branch": "feat/issue-201-other", "phase": "implement", "session_id": "'"$sid_state"'", "updated_at": "'"$ts_t02"'"}'
# In the per-session model the hook can only see its own session's file, so the
# "other-session" state is written under sid_state's per-session path and must
# remain untouched after the hook runs with sid_hook.
state_t02_path=$(state_file_path "$dirT02" "$sid_state")
mkdir -p "$(dirname "$state_t02_path")"
printf '%s' "$state_t02" > "$state_t02_path"
mtime_before=$(stat -c '%Y' "$state_t02_path" 2>/dev/null || stat -f '%m' "$state_t02_path")
content_before=$(cat "$state_t02_path")
sleep 1  # ensure mtime resolution can detect a change

output=$(run_hook_with_session "$dirT02" "startup" "$sid_hook") && rc=0 || rc=$?
mtime_after=$(stat -c '%Y' "$state_t02_path" 2>/dev/null || stat -f '%m' "$state_t02_path")
content_after=$(cat "$state_t02_path")
ACTIVE_AFTER=$(jq -r '.active' "$state_t02_path" 2>/dev/null)
if [ $rc -eq 0 ] && [ "$ACTIVE_AFTER" = "true" ] && [ -z "$output" ] && [ "$content_before" = "$content_after" ] && [ "$mtime_before" = "$mtime_after" ]; then
  pass "TC-T02: other-session → file unchanged (active=true, no output, mtime preserved)"
else
  fail "TC-T02: expected file unchanged; got rc=$rc, active=$ACTIVE_AFTER, output='$output', mtime_before=$mtime_before mtime_after=$mtime_after, content_diff=$([ "$content_before" = "$content_after" ] && echo no || echo yes)"
fi
echo ""

# --------------------------------------------------------------------------
# TC-T03: legacy state (no session_id) startup → reset (backward compat)
# --------------------------------------------------------------------------
echo "TC-T03: per-session state without internal session_id field → reset"
dirT03="$TEST_DIR/tcT03"
mkdir -p "$dirT03"
sid_t03="ses-T03-hook"
ts_t03=$(iso8601_now 0)
# Schema v3: state files are keyed by filename's session_id, not by an internal
# session_id field. ownership is structurally "own" via the per-session path
# (is_per_session_state_file fast-path in check_session_ownership).
create_state_file "$dirT03" \
  "{\"active\": true, \"issue_number\": 202, \"branch\": \"feat/issue-202-legacy\", \"phase\": \"implementing\", \"updated_at\": \"$ts_t03\"}" \
  "$sid_t03"

output=$(run_hook_with_session "$dirT03" "startup" "$sid_t03") && rc=0 || rc=$?
ACTIVE_AFTER=$(jq -r '.active' "$(state_file_path "$dirT03" "$sid_t03")" 2>/dev/null)
if [ $rc -eq 0 ] && [ "$ACTIVE_AFTER" = "false" ] && echo "$output" | grep -q "前回のセッション状態が残っていたためリセットしました"; then
  pass "TC-T03: per-session state (no internal session_id) → reset (active=false, message shown)"
else
  fail "TC-T03: expected per-session reset; got rc=$rc, active=$ACTIVE_AFTER, output='$output'"
fi
echo ""

# --------------------------------------------------------------------------
# TC-T04: check_session_ownership unavailable → fail-safe reset
# Sandbox: copy session-start.sh + dependencies, replace session-ownership.sh
# with a stub that fails to define the function → command -v false → reset
# --------------------------------------------------------------------------
echo "TC-T04: check_session_ownership unavailable → fail-safe reset"
dirT04="$TEST_DIR/tcT04"
mkdir -p "$dirT04/sandbox/hooks"
sandbox_hook_dir="$dirT04/sandbox/hooks"
src_hook_dir="$(cd "$SCRIPT_DIR/.." && pwd)"
cp "$src_hook_dir/session-start.sh" "$sandbox_hook_dir/"
cp "$src_hook_dir/hook-preamble.sh" "$sandbox_hook_dir/"
cp "$src_hook_dir/state-path-resolve.sh" "$sandbox_hook_dir/"
cp "$src_hook_dir/control-char-neutralize.sh" "$sandbox_hook_dir/"
cp "$src_hook_dir/gitignore-ensure.sh" "$sandbox_hook_dir/"
cp "$src_hook_dir/flow-state.sh" "$sandbox_hook_dir/"
# Sandbox に canonical mktemp helper を含める (silent suppress 禁止 — sibling cp と同じ fail-fast)
cp "$src_hook_dir/_mktemp-stderr-guard.sh" "$sandbox_hook_dir/"
# Stub session-ownership.sh: define helpers that don't break source, but omit check_session_ownership
cat > "$sandbox_hook_dir/session-ownership.sh" <<'STUB_EOF'
#!/bin/bash
# Test stub: check_session_ownership intentionally NOT defined
extract_session_id() { echo ""; }
get_state_session_id() { echo ""; }
parse_iso8601_to_epoch() { echo 0; }
STUB_EOF
sid_t04="ses-T04-hook"
ts_t04=$(iso8601_now 0)
mkdir -p "$dirT04/.rite/sessions"
printf '%s' "$sid_t04" > "$dirT04/.rite-session-id"
cat > "$dirT04/.rite/sessions/${sid_t04}.flow-state" <<EOF
{"active": true, "issue_number": 203, "branch": "feat/issue-203-failsafe", "phase": "implementing", "session_id": "$sid_t04", "updated_at": "$ts_t04"}
EOF
LAST_STDERR_FILE="$(mktemp "$TEST_DIR/stderr.XXXXXX")"
output=$(jq -n --arg cwd "$dirT04" --arg src "startup" --arg sid "$sid_t04" \
  '{cwd: $cwd, source: $src, session_id: $sid}' \
  | bash "$sandbox_hook_dir/session-start.sh" 2>"$LAST_STDERR_FILE") && rc=0 || rc=$?
ACTIVE_AFTER=$(jq -r '.active' "$dirT04/.rite/sessions/${sid_t04}.flow-state" 2>/dev/null)
if [ $rc -eq 0 ] && [ "$ACTIVE_AFTER" = "false" ] && echo "$output" | grep -q "前回のセッション状態が残っていたためリセットしました"; then
  pass "TC-T04: check_session_ownership undefined → fail-safe reset (active=false)"
else
  fail "TC-T04: expected fail-safe reset; got rc=$rc, active=$ACTIVE_AFTER, output='$output'"
fi
echo ""

# --------------------------------------------------------------------------
# TC-T04b (review M-EH1): check_session_ownership unavailable + RITE_DEBUG=1
#                                 → debug log "ownership check unavailable" 出力 (AC-04 spec)
# --------------------------------------------------------------------------
echo "TC-T04b: helper undefined + RITE_DEBUG=1 → 'ownership check unavailable' debug log"
dirT04b="$TEST_DIR/tcT04b"
mkdir -p "$dirT04b/sandbox/hooks"
sandbox_hook_dir_b="$dirT04b/sandbox/hooks"
src_hook_dir_b="$(cd "$SCRIPT_DIR/.." && pwd)"
cp "$src_hook_dir_b/session-start.sh" "$sandbox_hook_dir_b/"
cp "$src_hook_dir_b/hook-preamble.sh" "$sandbox_hook_dir_b/"
cp "$src_hook_dir_b/state-path-resolve.sh" "$sandbox_hook_dir_b/"
cp "$src_hook_dir_b/control-char-neutralize.sh" "$sandbox_hook_dir_b/"
cp "$src_hook_dir_b/gitignore-ensure.sh" "$sandbox_hook_dir_b/"
cp "$src_hook_dir_b/flow-state.sh" "$sandbox_hook_dir_b/"
# canonical mktemp helper を sandbox に同期コピーする (silent suppress 禁止 — sibling cp と同じ fail-fast)
cp "$src_hook_dir_b/_mktemp-stderr-guard.sh" "$sandbox_hook_dir_b/"
cat > "$sandbox_hook_dir_b/session-ownership.sh" <<'STUB_EOF'
#!/bin/bash
extract_session_id() { echo ""; }
get_state_session_id() { echo ""; }
parse_iso8601_to_epoch() { echo 0; }
STUB_EOF
sid_t04b="ses-T04b-hook"
ts_t04b=$(iso8601_now 0)
mkdir -p "$dirT04b/.rite/sessions"
printf '%s' "$sid_t04b" > "$dirT04b/.rite-session-id"
cat > "$dirT04b/.rite/sessions/${sid_t04b}.flow-state" <<EOF
{"active": true, "issue_number": 204, "branch": "feat/issue-204-debuglog", "phase": "implementing", "session_id": "$sid_t04b", "updated_at": "$ts_t04b"}
EOF
LAST_STDERR_FILE="$(mktemp "$TEST_DIR/stderr.XXXXXX")"
output=$(jq -n --arg cwd "$dirT04b" --arg src "startup" --arg sid "$sid_t04b" \
  '{cwd: $cwd, source: $src, session_id: $sid}' \
  | RITE_DEBUG=1 bash "$sandbox_hook_dir_b/session-start.sh" 2>"$LAST_STDERR_FILE") && rc=0 || rc=$?
stderr_content=$(cat "$LAST_STDERR_FILE")
ACTIVE_AFTER=$(jq -r '.active' "$dirT04b/.rite/sessions/${sid_t04b}.flow-state" 2>/dev/null)
if [ $rc -eq 0 ] && [ "$ACTIVE_AFTER" = "false" ] \
   && echo "$stderr_content" | grep -q "ownership check unavailable" \
   && echo "$stderr_content" | grep -q "check_session_ownership not sourced"; then
  pass "TC-T04b: helper undefined + RITE_DEBUG → debug log 'ownership check unavailable' shown"
else
  fail "TC-T04b: expected debug log 'ownership check unavailable'; got rc=$rc, active=$ACTIVE_AFTER, stderr='$stderr_content'"
fi
echo ""

# --------------------------------------------------------------------------
# TC-T05: static grep — old comment removed (AC-05)
# --------------------------------------------------------------------------
echo "TC-T05: static grep — old comment 'Always proceeds with reset...' removed"
HOOK_FILE="$SCRIPT_DIR/../session-start.sh"
# grep -c always prints the count to stdout (0 with exit 1 if no matches), so use || true (not || echo 0) to avoid double-printed "0".
old_match_count=$(grep -c "Always proceeds with reset regardless of session ownership" "$HOOK_FILE" 2>/dev/null || true)
old_match_count=${old_match_count:-0}
if [ "$old_match_count" = "0" ]; then
  pass "TC-T05: old comment 'Always proceeds with reset regardless of session ownership' removed (0 matches)"
else
  fail "TC-T05: old comment still present ($old_match_count matches in $HOOK_FILE)"
fi
echo ""

# --------------------------------------------------------------------------
# TC-per-session-detect-A (AC-LOCAL-2): per-session active=true → interruption notice
# Verifies that session-start reads the per-session file (not legacy) when
# a valid SID + per-session file exists, and that the
# `.active=true` precondition still fires the workflow-detected output.
# --------------------------------------------------------------------------
echo "TC-per-session-detect-A (AC-LOCAL-2): per-session active=true → workflow detected"
dir680a="$TEST_DIR/tc680a"
mkdir -p "$dir680a/.rite/sessions"
sid680a="aaaabbbb-cccc-dddd-eeee-ffffaaaa1111"
echo "$sid680a" > "$dir680a/.rite-session-id"
printf '# rite test sandbox config\n' > "$dir680a/rite-config.yml"
ts_t680a=$(iso8601_now 0)
cat > "$dir680a/.rite/sessions/${sid680a}.flow-state" <<EOF
{"active": true, "issue_number": 680, "branch": "refactor/issue-680-test", "phase": "phase5_review", "next_action": "review", "loop_count": 0, "session_id": "$sid680a", "updated_at": "$ts_t680a"}
EOF
output=$(run_hook_with_session "$dir680a" "resume" "$sid680a") && rc=0 || rc=$?
if [ $rc -eq 0 ] && echo "$output" | grep -q "中断した rite workflow を検出" \
   && echo "$output" | grep -q "$(issue_text 680)"; then
  pass "TC-per-session-detect-A: per-session file read → interruption notice fired (AC-LOCAL-2)"
else
  fail "TC-per-session-detect-A: expected workflow-detected output from per-session file; got rc=$rc, output='$output'"
fi
echo ""

# --------------------------------------------------------------------------
# TC-per-session-detect-B  : per-session active=false → no workflow-detected output
# Counter-assertion: ensure the .active=false branch on per-session path
# does NOT trigger the workflow-detected output (AND-logic precondition).
# --------------------------------------------------------------------------
echo "TC-per-session-detect-B  : per-session active=false → no detection (AND-logic preserved)"
dir680b="$TEST_DIR/tc680b"
mkdir -p "$dir680b/.rite/sessions"
sid680b="22222222-3333-4444-5555-666666666666"
echo "$sid680b" > "$dir680b/.rite-session-id"
printf '# rite test sandbox config\n' > "$dir680b/rite-config.yml"
ts_t680b=$(iso8601_now 0)
cat > "$dir680b/.rite/sessions/${sid680b}.flow-state" <<EOF
{"active": false, "issue_number": 681, "branch": "refactor/issue-681-test", "phase": "completed", "session_id": "$sid680b", "updated_at": "$ts_t680b"}
EOF
output=$(run_hook_with_session "$dir680b" "resume" "$sid680b") && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ -z "$output" ]; then
  pass "TC-per-session-detect-B: per-session active=false → no detection output (silent exit)"
else
  fail "TC-per-session-detect-B: expected silent exit; got rc=$rc, output='$output'"
fi
echo ""

# --------------------------------------------------------------------------
# TC-helper-failure-stderr-passthrough (AC-1)
# --------------------------------------------------------------------------
# Verify that when flow-state.sh path exits non-zero, its stderr (ERROR: lines
# from validate helpers) is passed through to the user AND a skip WARNING is
# emitted on stderr. Defends against the silent-fall-through regression that
# the previous `2>/dev/null` produced.
#
# The hook does NOT fall back to a legacy `.rite-flow-state` file on resolver
# failure: it emits a "STATE_FILE 不明、recovery を skip" WARNING and exits
# without touching any legacy file. This test therefore validates only that the
# ERROR pass-through and the skip WARNING reach stderr; it does not assert any
# legacy-fallback load, since reintroducing one would be a regression.
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

dir_749="$TEST_DIR/tc749"
mkdir -p "$dir_749"

LAST_STDERR_FILE="$(mktemp "$TEST_DIR/stderr.749.XXXXXX")"
echo "{\"cwd\": \"$dir_749\", \"source\": \"startup\"}" \
  | bash "$sbx_749/session-start.sh" >/dev/null 2>"$LAST_STDERR_FILE" || true
stderr_749="$(cat "$LAST_STDERR_FILE")"

if printf '%s' "$stderr_749" | grep -qF 'TC-helper-failure simulated flow-state.sh path failure'; then
  pass "ERROR line from flow-state.sh passed through to caller stderr"
else
  fail "Expected ERROR pass-through; got stderr: $stderr_749"
fi
if printf '%s' "$stderr_749" | grep -qF 'flow-state.sh path resolution failed'; then
  pass "Skip WARNING emitted to stderr (no legacy fallback in v3)"
else
  fail "Expected skip WARNING; got stderr: $stderr_749"
fi
echo ""

# --------------------------------------------------------------------------
# TC-EXTRACT-SID-WARNING — malformed stdin JSON exercises the unsuppressed
# extract_session_id stderr path. If a future refactor re-introduces
# `2>/dev/null` (or routes through a helper that swallows stderr), the
# production-safety signal disappears and this assertion fires.
# --------------------------------------------------------------------------
echo "TC-EXTRACT-SID-WARNING: malformed stdin → extract_session_id WARNING reaches caller stderr"
dir_sid="$TEST_DIR/tc-sid-warning"
mkdir -p "$dir_sid"
sid_stderr=$(mktemp "$TEST_DIR/stderr.sid.XXXXXX")
echo '{"cwd":"'"$dir_sid"'","session_id":"not-json-{{","extra":' | bash "$HOOK" >/dev/null 2>"$sid_stderr" || true
if grep -qE 'extract_session_id|jq parse failed' "$sid_stderr"; then
  pass "TC-EXTRACT-SID-WARNING: corrupt stdin surfaces session-id WARNING on stderr"
else
  fail "TC-EXTRACT-SID-WARNING: no WARNING reached caller stderr — silent classification possible. stderr: $(cat "$sid_stderr")"
fi
echo ""

# --------------------------------------------------------------------------
# TC-PY-REPAIR-PIN: settings.local.json 修復経路の rc capture が `if !` antipattern に
# 書き戻されると silent regression する (rc collapse → 修復 skip が WARNING 一切無しで通過)。
# python3 / mv の rc capture と修復ヒント出力が source 上に残っていることを static に pin する。
# behavioral 経路 (PATH-shim python3 + stderr-capture) はテスト harness 拡張が必要なため、
# まず regression detector として canonical 文字列を保持する。
# --------------------------------------------------------------------------
echo "TC-PY-REPAIR-PIN: settings.local.json repair path retains rc capture doctrine"
HOOK_SOURCE="$SCRIPT_DIR/../session-start.sh"
if grep -q '_py_rc=\$?' "$HOOK_SOURCE"; then
  pass "session-start.sh captures python3 repair rc via _py_rc=\$?"
else
  fail "session-start.sh missing _py_rc=\$? — python3 failure may be collapsed to silent skip"
fi
if grep -q "settings.local.json repair python3 failed" "$HOOK_SOURCE"; then
  pass "session-start.sh retains 'settings.local.json repair python3 failed' WARNING"
else
  fail "session-start.sh missing 'settings.local.json repair python3 failed' WARNING — repair failure is silent"
fi
if grep -q "mv settings.local.json repair failed" "$HOOK_SOURCE"; then
  pass "session-start.sh retains 'mv settings.local.json repair failed' WARNING (mv rc capture)"
else
  fail "session-start.sh missing mv-failure WARNING — settings.local.json repair mv failure is silent"
fi
echo ""

# --------------------------------------------------------------------------
# TC-settings-local-invalid-json (subtask 2a): behavioral verification that an
# invalid settings.local.json drives the cleanup script's rc=2 path WITHOUT
# aborting the hook (set -e regression guard), surfaces the corruption WARNING,
# and shows the JSON-format hint (the cleanup script writes nothing to stderr on
# invalid JSON, so _py_err is empty → the hint is the correct disambiguation).
# Pre-fix (python3 as a bare statement under set -e) the hook aborted rc=2 here.
# --------------------------------------------------------------------------
echo "TC-settings-local-invalid-json: invalid settings.local.json → hook continues + corruption surfaces + JSON hint"
dir_1241a="$TEST_DIR/tc1241a"
mkdir -p "$dir_1241a/.claude"
# No .rite-settings-hooks-cleaned marker → _needs_cleanup=true; source=startup gates the repair path.
# Run the hook directly in the main shell rather than via the run_hook_* helpers:
# those capture stderr into LAST_STDERR_FILE *inside* a command-substitution subshell,
# so the assignment never reaches this shell and a later cat would read a stale file.
printf '%s' '{ this is not valid json' > "$dir_1241a/.claude/settings.local.json"
stderr_1241a="$(mktemp "$TEST_DIR/stderr.1241a.XXXXXX")"
echo "{\"cwd\": \"$dir_1241a\", \"source\": \"startup\"}" \
  | bash "$HOOK" >/dev/null 2>"$stderr_1241a" && rc_1241a=0 || rc_1241a=$?
err_1241a="$(cat "$stderr_1241a")"
if [ "$rc_1241a" -eq 0 ]; then
  pass "TC-settings-local-invalid-json: hook exits 0 (set -e did not abort on python3 rc=2)"
else
  fail "TC-settings-local-invalid-json: hook aborted (rc=$rc_1241a) — set -e regression on python3 non-zero exit"
fi
if printf '%s' "$err_1241a" | grep -qF 'settings.local.json repair python3 failed (rc=2)'; then
  pass "TC-settings-local-invalid-json: invalid JSON corruption surfaces on stderr (rc=2 reported, not dead code)"
else
  fail "TC-settings-local-invalid-json: corruption not surfaced (report branch is dead code); stderr: $err_1241a"
fi
if printf '%s' "$err_1241a" | grep -qF 'settings.local.json の JSON 形式 / encoding'; then
  pass "TC-settings-local-invalid-json: JSON-format hint shown for genuine invalid JSON (empty script stderr)"
else
  fail "TC-settings-local-invalid-json: JSON hint missing for invalid JSON; stderr: $err_1241a"
fi
echo ""

# --------------------------------------------------------------------------
# TC-settings-local-noop-downstream (subtask 2b): behavioral verification that
# a rc=1 no-op repair (valid settings.local.json with no rite hooks) does NOT
# abort, stays silent (no failure WARNING), and lets the hook proceed to the
# downstream STATE_FILE resolution + defensive reset (the reset message proves
# the post-repair code path executed). Pre-fix the hook aborted rc=1 at python3.
# --------------------------------------------------------------------------
echo "TC-settings-local-noop-downstream: rc=1 no-op repair → hook continues silently to STATE_FILE resolution"
dir_1241b="$TEST_DIR/tc1241b"
sid_1241b="11112222-3333-4444-5555-666677778888"
mkdir -p "$dir_1241b/.claude"
# Valid JSON with no rite hook entries → cleanup script returns rc=1 (intentional no-op).
printf '%s' '{"permissions":{"allow":["Bash(ls:*)"]}}' > "$dir_1241b/.claude/settings.local.json"
# Active flow-state so the downstream defensive reset (line ~414) fires and prints a
# reset message — the observable proof that the hook reached past the repair block.
create_state_file "$dir_1241b" '{"active":true,"issue_number":1241,"phase":"implement","branch":"fix/issue-1241-test","session_id":"'"$sid_1241b"'"}' "$sid_1241b"
# Direct main-shell invocation (see TC-settings-local-invalid-json note on LAST_STDERR_FILE/subshell).
stderr_1241b="$(mktemp "$TEST_DIR/stderr.1241b.XXXXXX")"
out_1241b=$(jq -n --arg cwd "$dir_1241b" --arg src "startup" --arg sid "$sid_1241b" \
  '{cwd: $cwd, source: $src, session_id: $sid}' \
  | bash "$HOOK" 2>"$stderr_1241b") && rc_1241b=0 || rc_1241b=$?
err_1241b="$(cat "$stderr_1241b")"
if [ "$rc_1241b" -eq 0 ]; then
  pass "TC-settings-local-noop-downstream: hook exits 0 (set -e did not abort on python3 rc=1)"
else
  fail "TC-settings-local-noop-downstream: hook aborted (rc=$rc_1241b) — set -e regression on rc=1 no-op"
fi
if printf '%s' "$err_1241b" | grep -qF 'settings.local.json repair python3 failed'; then
  fail "TC-settings-local-noop-downstream: rc=1 no-op misreported as failure; stderr: $err_1241b"
else
  pass "TC-settings-local-noop-downstream: rc=1 no-op stays silent (no false failure WARNING)"
fi
if printf '%s' "$out_1241b" | grep -qF '前回のセッション状態が残っていたためリセットしました' \
   && printf '%s' "$out_1241b" | grep -qF "$(issue_text 1241)"; then
  pass "TC-settings-local-noop-downstream: downstream STATE_FILE resolution + defensive reset reached"
else
  fail "TC-settings-local-noop-downstream: downstream not reached (hook stopped before reset); stdout: $out_1241b"
fi
echo ""

# --------------------------------------------------------------------------
# TC-settings-local-missing-script (subtask 3): behavioral verification that a
# missing/unreadable cleanup script (python3 emits its OWN diagnostic to stderr,
# exit 2) is reported WITHOUT the JSON-format hint — that hint is invalid-JSON
# specific and would misdirect here. Run against a sandbox copy with the cleanup
# script removed so python3 fails to open it.
# --------------------------------------------------------------------------
echo "TC-settings-local-missing-script: missing cleanup script → reported without misdirecting JSON hint"
HOOKS_REAL_DIR_1241="$(cd "$SCRIPT_DIR/.." && pwd)"
sbx_1241c="$(mktemp -d "$TEST_DIR/sbx-1241c-XXXXXX")"
cp -a "$HOOKS_REAL_DIR_1241/." "$sbx_1241c/"
rm -f "$sbx_1241c/scripts/settings-local-rite-hook-cleanup.py"
dir_1241c="$TEST_DIR/tc1241c"
mkdir -p "$dir_1241c/.claude"
printf '%s' '{"permissions":{"allow":[]}}' > "$dir_1241c/.claude/settings.local.json"
stderr_1241c="$(mktemp "$TEST_DIR/stderr.1241c.XXXXXX")"
echo "{\"cwd\": \"$dir_1241c\", \"source\": \"startup\"}" \
  | bash "$sbx_1241c/session-start.sh" >/dev/null 2>"$stderr_1241c" && rc_1241c=0 || rc_1241c=$?
err_1241c="$(cat "$stderr_1241c")"
if [ "$rc_1241c" -eq 0 ]; then
  pass "TC-settings-local-missing-script: hook exits 0 (set -e did not abort on missing-script python3 rc)"
else
  fail "TC-settings-local-missing-script: hook aborted (rc=$rc_1241c) — set -e regression on missing script"
fi
if printf '%s' "$err_1241c" | grep -qF 'settings.local.json repair python3 failed'; then
  pass "TC-settings-local-missing-script: python3 failure reported on stderr"
else
  fail "TC-settings-local-missing-script: missing-script failure not reported; stderr: $err_1241c"
fi
if printf '%s' "$err_1241c" | grep -qF 'settings.local.json の JSON 形式 / encoding'; then
  fail "TC-settings-local-missing-script: JSON hint misdirects on missing-script (subtask 3 regression); stderr: $err_1241c"
else
  pass "TC-settings-local-missing-script: JSON hint suppressed when python3 emits its own stderr (no misdirection)"
fi
echo ""

# --------------------------------------------------------------------------
# TC-DEP-1..4: flow_state.schema_version: 1 deprecation warning
#   AC-2 / T-02: explicit `: 1` at startup → one-line stderr deprecation warning.
#   AC-3 / T-03: gated on SOURCE=startup (only session-start emits it, and only
#                on startup), so a session start surfaces exactly one — verified
#                via count==1 plus the non-startup-source negative case (TC-DEP-4).
#   AC-4 / T-04: flow_state section absent → no warning.
#   AC-1 boundary: explicit `: 2` → no warning.
# --------------------------------------------------------------------------
_dep_git_repo() {
  local d="$1" sv="$2"  # sv: "1" | "2" | "" (empty → omit flow_state section)
  mkdir -p "$d"
  (cd "$d" && git init -q && git -c user.name="test" -c user.email="test@test.com" commit --allow-empty -m "init" -q && git checkout -b "feat/issue-1458-test" -q)
  if [ -n "$sv" ]; then
    printf 'schema_version: 2\nlanguage: ja\nflow_state:\n  schema_version: %s\n' "$sv" > "$d/rite-config.yml"
  else
    printf 'schema_version: 2\nlanguage: ja\n' > "$d/rite-config.yml"
  fi
}
# Invoke the hook directly (not via run_hook_with_source) and capture stderr to a
# parent-scope file: run_hook_with_source assigns LAST_STDERR_FILE inside a
# command-substitution subshell, so the value never reaches the parent and a
# `grep "$LAST_STDERR_FILE"` here would read a stale earlier file. Echoes the
# count of deprecation-warning lines (grep -c prints 0 / exits 1 on no match).
_dep_warn_count() {
  local d="$1" src="$2" stderr_f
  stderr_f=$(mktemp "$TEST_DIR/stderr.dep.XXXXXX")
  echo "{\"cwd\": \"$d\", \"source\": \"$src\"}" | bash "$HOOK" >/dev/null 2>"$stderr_f" || true
  grep -c 'flow_state.schema_version: 1' "$stderr_f" 2>/dev/null || true
}

echo "TC-DEP-1: startup + flow_state.schema_version: 1 → one deprecation warning"
_dep_git_repo "$TEST_DIR/git_dep1" "1"
dep_n=$(_dep_warn_count "$TEST_DIR/git_dep1" "startup")
if [ "$dep_n" -eq 1 ]; then
  pass "explicit flow_state.schema_version: 1 → exactly one deprecation warning (AC-2/AC-3)"
else
  fail "Expected exactly one deprecation warning, got count=$dep_n"
fi
echo ""

echo "TC-DEP-2: startup + no flow_state section → no deprecation warning"
_dep_git_repo "$TEST_DIR/git_dep2" ""
dep_n=$(_dep_warn_count "$TEST_DIR/git_dep2" "startup")
if [ "$dep_n" -eq 0 ]; then
  pass "flow_state section absent → no deprecation warning (AC-4)"
else
  fail "Expected no warning, got count=$dep_n"
fi
echo ""

echo "TC-DEP-3: startup + flow_state.schema_version: 2 → no deprecation warning"
_dep_git_repo "$TEST_DIR/git_dep3" "2"
dep_n=$(_dep_warn_count "$TEST_DIR/git_dep3" "startup")
if [ "$dep_n" -eq 0 ]; then
  pass "flow_state.schema_version: 2 → no deprecation warning (AC-1 boundary)"
else
  fail "Expected no warning, got count=$dep_n"
fi
echo ""

echo "TC-DEP-4: compact source + flow_state.schema_version: 1 → no deprecation warning (startup gate)"
_dep_git_repo "$TEST_DIR/git_dep4" "1"
dep_n=$(_dep_warn_count "$TEST_DIR/git_dep4" "compact")
if [ "$dep_n" -eq 0 ]; then
  pass "compact source → no deprecation warning (startup-gated; supports AC-3 once-per-session)"
else
  fail "Expected no warning on compact source, got count=$dep_n"
fi
echo ""

# --------------------------------------------------------------------------
# TC-YAML-LITERAL-PREFIX: _rite_read_yaml_key uses literal-prefix match
# --------------------------------------------------------------------------
# A regression to the regex form `$0 ~ k` would let YAML keys containing regex
# metacharacters (e.g. `flow.state.v2`) silently overmatch unrelated lines.
# Pin the literal-prefix form so the contract for future keys is enforced even
# before such keys exist.
echo "TC-YAML-LITERAL-PREFIX: _rite_read_yaml_key uses index() literal prefix"
if grep -qF 'index($0, k) == 1' "$HOOK_SOURCE"; then
  pass "session-start.sh _rite_read_yaml_key uses literal index() prefix match"
else
  fail "session-start.sh _rite_read_yaml_key regressed to regex form — YAML keys with regex metachars will overmatch"
fi
echo ""

# --------------------------------------------------------------------------
# TC-1524-* : dangling session-worktree self-heal (AC-2 / AC-5)
# When flow-state records a `worktree` path that no longer exists (reaped by
# another session's GC while this session was paused), session-start nulls the
# field so re-entry / harness cwd-restore is not aimed at a dead dir.
# --------------------------------------------------------------------------
# Shared sandbox builder: copies session-start.sh + its real deps and stubs
# session-ownership.sh (mirrors TC-T04). Echoes the sandbox hooks dir.
_mk_wt_sandbox() {
  local dir="$1" sbx src f
  mkdir -p "$dir/sandbox/hooks"
  sbx="$dir/sandbox/hooks"
  src="$(cd "$SCRIPT_DIR/.." && pwd)"
  for f in session-start.sh hook-preamble.sh state-path-resolve.sh control-char-neutralize.sh gitignore-ensure.sh flow-state.sh _mktemp-stderr-guard.sh; do
    cp "$src/$f" "$sbx/"
  done
  cat > "$sbx/session-ownership.sh" <<'STUB_EOF'
#!/bin/bash
extract_session_id() { echo ""; }
get_state_session_id() { echo ""; }
parse_iso8601_to_epoch() { echo 0; }
STUB_EOF
  printf '%s' "$sbx"
}

echo "TC-1524-a (AC-2): /clear with dangling worktree → flow-state worktree nulled, no re-entry"
dirWT="$TEST_DIR/tc1524a"
sbx_wt="$(_mk_wt_sandbox "$dirWT")"
sid_wt="ses-1524a"
ts_wt=$(iso8601_now 0)
mkdir -p "$dirWT/.rite/sessions"
printf '%s' "$sid_wt" > "$dirWT/.rite-session-id"
# `worktree` points at a path that does NOT exist (the reaped session worktree).
cat > "$dirWT/.rite/sessions/${sid_wt}.flow-state" <<EOF
{"active": true, "issue_number": 1524, "branch": "fix/issue-1524", "phase": "implement", "session_id": "$sid_wt", "worktree": "$dirWT/.rite/worktrees/issue-1524", "updated_at": "$ts_wt"}
EOF
LAST_STDERR_FILE="$(mktemp "$TEST_DIR/stderr.XXXXXX")"
out_wt=$(jq -n --arg cwd "$dirWT" --arg src "clear" --arg sid "$sid_wt" \
  '{cwd: $cwd, source: $src, session_id: $sid}' \
  | bash "$sbx_wt/session-start.sh" 2>"$LAST_STDERR_FILE") && rc_wt=0 || rc_wt=$?
wt_after=$(jq -r 'has("worktree")' "$dirWT/.rite/sessions/${sid_wt}.flow-state" 2>/dev/null)
if [ "$rc_wt" -eq 0 ] && [ "$wt_after" = "false" ] \
   && grep -q "存在しないため flow-state から参照をクリア" "$LAST_STDERR_FILE"; then
  pass "TC-1524-a: dangling worktree nulled on /clear (rc=0, self-heal WARNING shown)"
else
  fail "TC-1524-a: expected worktree cleared; rc=$rc_wt has_worktree=$wt_after stderr=$(cat "$LAST_STDERR_FILE")"
fi
echo ""

echo "TC-1524-b (AC-2 boundary): existing worktree dir → NOT cleared (self-heal does not over-fire)"
dirWTb="$TEST_DIR/tc1524b"
sbx_wtb="$(_mk_wt_sandbox "$dirWTb")"
sid_wtb="ses-1524b"
ts_wtb=$(iso8601_now 0)
mkdir -p "$dirWTb/.rite/sessions"
mkdir -p "$dirWTb/.rite/worktrees/issue-1525"   # the recorded worktree DOES exist
printf '%s' "$sid_wtb" > "$dirWTb/.rite-session-id"
cat > "$dirWTb/.rite/sessions/${sid_wtb}.flow-state" <<EOF
{"active": true, "issue_number": 1525, "branch": "fix/issue-1525", "phase": "implement", "session_id": "$sid_wtb", "worktree": "$dirWTb/.rite/worktrees/issue-1525", "updated_at": "$ts_wtb"}
EOF
LAST_STDERR_FILE="$(mktemp "$TEST_DIR/stderr.XXXXXX")"
jq -n --arg cwd "$dirWTb" --arg src "clear" --arg sid "$sid_wtb" \
  '{cwd: $cwd, source: $src, session_id: $sid}' \
  | bash "$sbx_wtb/session-start.sh" >/dev/null 2>"$LAST_STDERR_FILE" || true
wt_after_b=$(jq -r '.worktree // "ABSENT"' "$dirWTb/.rite/sessions/${sid_wtb}.flow-state" 2>/dev/null)
if [ "$wt_after_b" = "$dirWTb/.rite/worktrees/issue-1525" ]; then
  pass "TC-1524-b: existing worktree dir preserved (self-heal correctly scoped to missing dir)"
else
  fail "TC-1524-b: expected worktree preserved, got '$wt_after_b'"
fi
echo ""

echo "TC-1524-c (AC-5): clear-worktree write failure → session-start non-blocking (exit 0) + WARNING"
if [ "$(id -u)" -eq 0 ]; then
  # root bypasses dir-permission bits, so a read-only sessions dir cannot force the
  # atomic-write failure this case exercises. Not a product failure — skip honestly.
  pass "TC-1524-c: skipped under root (chmod cannot force a write failure as uid 0)"
else
  dirWTc="$TEST_DIR/tc1524c"
  sbx_wtc="$(_mk_wt_sandbox "$dirWTc")"
  sid_wtc="ses-1524c"
  ts_wtc=$(iso8601_now 0)
  mkdir -p "$dirWTc/.rite/sessions"
  printf '%s' "$sid_wtc" > "$dirWTc/.rite-session-id"
  cat > "$dirWTc/.rite/sessions/${sid_wtc}.flow-state" <<EOF
{"active": true, "issue_number": 1526, "branch": "fix/issue-1526", "phase": "implement", "session_id": "$sid_wtc", "worktree": "$dirWTc/.rite/worktrees/issue-1526", "updated_at": "$ts_wtc"}
EOF
  # Read-only sessions dir → clear-worktree's _atomic_write (mktemp in dir) fails.
  chmod 555 "$dirWTc/.rite/sessions"
  LAST_STDERR_FILE="$(mktemp "$TEST_DIR/stderr.XXXXXX")"
  jq -n --arg cwd "$dirWTc" --arg src "clear" --arg sid "$sid_wtc" \
    '{cwd: $cwd, source: $src, session_id: $sid}' \
    | bash "$sbx_wtc/session-start.sh" >/dev/null 2>"$LAST_STDERR_FILE" && rc_wtc=0 || rc_wtc=$?
  chmod 755 "$dirWTc/.rite/sessions"   # restore so the EXIT trap can rm -rf
  if [ "$rc_wtc" -eq 0 ] && grep -q "dangling worktree 参照のクリアに失敗" "$LAST_STDERR_FILE"; then
    pass "TC-1524-c: clear-worktree write failure is non-blocking (exit 0) + WARNING emitted"
  else
    fail "TC-1524-c: expected non-blocking WARNING; rc=$rc_wtc stderr=$(cat "$LAST_STDERR_FILE")"
  fi
fi
echo ""

# --------------------------------------------------------------------------
# TC-1530: .rite/session-id write is conditioned on env-absence
# --------------------------------------------------------------------------
echo "TC-1530: .rite/session-id write conditioned on env-absence"

# Case A: env absent → session-start writes .rite/session-id (the fallback channel
# env-absent runtimes rely on for flow-state.sh resolution).
dir1530a="$TEST_DIR/cond-env-absent"
mkdir -p "$dir1530a"
sid1530a="dddddddd-1111-2222-3333-444444444444"
LAST_STDERR_FILE="$(mktemp "$TEST_DIR/stderr.XXXXXX")"
jq -n --arg cwd "$dir1530a" --arg src "startup" --arg sid "$sid1530a" \
  '{cwd: $cwd, source: $src, session_id: $sid}' \
  | env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID bash "$HOOK" >/dev/null 2>"$LAST_STDERR_FILE" || true
if [ "$(cat "$dir1530a/.rite/session-id" 2>/dev/null)" = "$sid1530a" ] && [ ! -f "$dir1530a/.rite-session-id" ]; then
  pass "TC-1530a: env-absent → .rite/session-id written with payload sid (fallback)"
else
  fail "TC-1530a: expected .rite/session-id='$sid1530a' and no legacy file, got new='$(cat "$dir1530a/.rite/session-id" 2>/dev/null)' old='$(cat "$dir1530a/.rite-session-id" 2>/dev/null)'"
fi

# Case B: env present → session-start must NOT write/clobber the shared
# session-id file; the per-session env var is authoritative, so leaving the
# shared file untouched is what prevents concurrent sessions from overwriting it.
dir1530b="$TEST_DIR/cond-env-present"
mkdir -p "$dir1530b"
sid1530b="eeeeeeee-5555-6666-7777-888888888888"
env_sid_b="ffffffff-9999-0000-1111-222222222222"
LAST_STDERR_FILE="$(mktemp "$TEST_DIR/stderr.XXXXXX")"
jq -n --arg cwd "$dir1530b" --arg src "startup" --arg sid "$sid1530b" \
  '{cwd: $cwd, source: $src, session_id: $sid}' \
  | env -u CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID="$env_sid_b" bash "$HOOK" >/dev/null 2>"$LAST_STDERR_FILE" || true
if [ ! -f "$dir1530b/.rite-session-id" ] && [ ! -f "$dir1530b/.rite/session-id" ]; then
  pass "TC-1530b: env-present → shared session-id not written on new or legacy path"
else
  fail "TC-1530b: expected no session-id file when env present, new='$(cat "$dir1530b/.rite/session-id" 2>/dev/null)' old='$(cat "$dir1530b/.rite-session-id" 2>/dev/null)'"
fi
echo ""

echo "TC-1552 (AC-5): dangling harness cwd at a reaped session worktree → recovery guide + exit 0"
# A non-existent cwd shaped like a reaped session worktree (.../worktrees/issue-N).
# rite cannot repair the harness's own cwd record, but session-start surfaces a
# recovery guide to stderr and exits 0 (non-blocking) — the user-facing half of
# the /clear `Path does not exist` fix. _RITE_HOOK_RUNNING_SESSIONSTART must be
# unset or the double-execution guard exits 0 before reaching the cwd check.
dir1552_root="$TEST_DIR/dangling-cwd"
mkdir -p "$dir1552_root"
dangling_cwd="$dir1552_root/.rite/worktrees/issue-1231"   # intentionally NOT created
LAST_STDERR_FILE="$(mktemp "$TEST_DIR/stderr.XXXXXX")"
jq -n --arg cwd "$dangling_cwd" --arg src "clear" \
  '{cwd: $cwd, source: $src, hook_event_name: "SessionStart"}' \
  | env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID -u _RITE_HOOK_RUNNING_SESSIONSTART \
      bash "$HOOK" >/dev/null 2>"$LAST_STDERR_FILE"; rc1552=$?
if [ "$rc1552" -eq 0 ]; then
  pass "TC-1552a: dangling cwd → hook exits 0 (non-blocking)"
else
  fail "TC-1552a: expected exit 0, got rc=$rc1552"
fi
if grep -q "Path does not exist" "$LAST_STDERR_FILE" && grep -q "/rite:recover" "$LAST_STDERR_FILE"; then
  pass "TC-1552b: recovery guide emitted to stderr (mentions /clear failure + /rite:recover)"
else
  fail "TC-1552b: recovery guide missing on stderr: $(cat "$LAST_STDERR_FILE")"
fi

echo "TC-1552c (boundary): dangling cwd NOT shaped like a session worktree → no recovery guide"
LAST_STDERR_FILE="$(mktemp "$TEST_DIR/stderr.XXXXXX")"
jq -n --arg cwd "$dir1552_root/some/unrelated/deleted-dir" --arg src "clear" \
  '{cwd: $cwd, source: $src, hook_event_name: "SessionStart"}' \
  | env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID -u _RITE_HOOK_RUNNING_SESSIONSTART \
      bash "$HOOK" >/dev/null 2>"$LAST_STDERR_FILE"; rc1552c=$?
if [ "$rc1552c" -eq 0 ] && ! grep -q "/rite:recover" "$LAST_STDERR_FILE"; then
  pass "TC-1552c: non-worktree dangling cwd → exit 0, no recovery guide (no false positive)"
else
  fail "TC-1552c: unexpected output rc=$rc1552c stderr=$(cat "$LAST_STDERR_FILE")"
fi
echo ""

# --------------------------------------------------------------------------
# TC-1968: lazy reap output redirected to log file instead of discarded (#1968)
# --------------------------------------------------------------------------
echo "TC-1968-01 (AC-1): reap output is captured to .rite/logs/pr-cycle-cleanup.log"
dir_reap_ac1="$TEST_DIR/reap-ac1"
mkdir -p "$dir_reap_ac1"
(cd "$dir_reap_ac1" && git init -q && git -c user.name="test" -c user.email="test@test.com" commit --allow-empty -m "init" -q)
# TMPDIR isolation: a real git fixture lets reap run to completion, which also
# triggers pr-cycle-cleanup.sh's orphan-workdir sweep under ${TMPDIR:-/tmp}. An
# isolated TMPDIR keeps that sweep from touching the host's real temp dir.
iso_tmpdir_ac1="$TEST_DIR/reap-ac1-tmpdir"
mkdir -p "$iso_tmpdir_ac1"
LAST_STDERR_FILE="$(mktemp "$TEST_DIR/stderr.XXXXXX")"
echo "{\"cwd\": \"$dir_reap_ac1\"}" | TMPDIR="$iso_tmpdir_ac1" bash "$HOOK" >/dev/null 2>"$LAST_STDERR_FILE" || true
if grep -q '\[pr-cycle-cleanup\] status=' "$dir_reap_ac1/.rite/logs/pr-cycle-cleanup.log" 2>/dev/null; then
  pass "TC-1968-01: reap status line written to .rite/logs/pr-cycle-cleanup.log"
else
  fail "TC-1968-01: expected [pr-cycle-cleanup] status= line at $dir_reap_ac1/.rite/logs/pr-cycle-cleanup.log, got: $(cat "$dir_reap_ac1/.rite/logs/pr-cycle-cleanup.log" 2>/dev/null)"
fi
echo ""

echo "TC-1968-02 (AC-2): reap output does not leak into hook stdout"
dir_reap_ac2="$TEST_DIR/reap-ac2"
mkdir -p "$dir_reap_ac2"
(cd "$dir_reap_ac2" && git init -q && git -c user.name="test" -c user.email="test@test.com" commit --allow-empty -m "init" -q)
iso_tmpdir_ac2="$TEST_DIR/reap-ac2-tmpdir"
mkdir -p "$iso_tmpdir_ac2"
LAST_STDERR_FILE="$(mktemp "$TEST_DIR/stderr.XXXXXX")"
output=$(echo "{\"cwd\": \"$dir_reap_ac2\"}" | TMPDIR="$iso_tmpdir_ac2" bash "$HOOK" 2>"$LAST_STDERR_FILE") || true
if ! printf '%s' "$output" | grep -q '\[pr-cycle-cleanup\]'; then
  pass "TC-1968-02: hook stdout does not contain reap output"
else
  fail "TC-1968-02: reap output leaked into hook stdout: $output"
fi
echo ""

echo "TC-1968-03 (AC-3): log dir creation failure falls back to discard, hook still exits 0"
dir_reap_ac3="$TEST_DIR/reap-ac3"
mkdir -p "$dir_reap_ac3/.rite"
# A file named "logs" at the target path blocks `mkdir -p .../.rite/logs`,
# forcing the fallback-to-discard branch without disturbing other .rite/ state.
touch "$dir_reap_ac3/.rite/logs"
LAST_STDERR_FILE="$(mktemp "$TEST_DIR/stderr.XXXXXX")"
echo "{\"cwd\": \"$dir_reap_ac3\"}" | bash "$HOOK" >/dev/null 2>"$LAST_STDERR_FILE"; rc1968_03=$?
# Assert the fallback branch actually ran: mkdir -p must have failed (the path
# is still the file we touched, not a directory), not just "exit 0 either way".
if [ "$rc1968_03" -eq 0 ] && [ -f "$dir_reap_ac3/.rite/logs" ] && [ ! -d "$dir_reap_ac3/.rite/logs" ]; then
  pass "TC-1968-03: hook exits 0 with mkdir failure intact (fallback branch not directly asserted)"
else
  fail "TC-1968-03: expected exit 0 with mkdir failure intact, got rc=$rc1968_03, .rite/logs is $([ -d "$dir_reap_ac3/.rite/logs" ] && echo dir || echo not-a-dir)"
fi
echo ""

echo "TC-1968-05 (AC-1): a reap WARNING line (not just the status line) is captured to the log"
dir_reap_ac5="$TEST_DIR/reap-ac5"
mkdir -p "$dir_reap_ac5"
(cd "$dir_reap_ac5" && git init -q && git -c user.name="test" -c user.email="test@test.com" commit --allow-empty -m "init" -q)
iso_tmpdir_ac5="$TEST_DIR/reap-ac5-tmpdir"
mkdir -p "$iso_tmpdir_ac5"
LAST_STDERR_FILE="$(mktemp "$TEST_DIR/stderr.XXXXXX")"
# An invalid RITE_SESSION_LIVENESS_TTL_HOURS is the lightest-weight way to make
# pr-cycle-cleanup.sh emit a WARNING line (no worktree/manifest fixture needed) —
# AC-1 names "WARNING / status" lines, and TC-1968-01 only exercises the latter.
echo "{\"cwd\": \"$dir_reap_ac5\"}" | TMPDIR="$iso_tmpdir_ac5" RITE_SESSION_LIVENESS_TTL_HOURS="invalid" bash "$HOOK" >/dev/null 2>"$LAST_STDERR_FILE" || true
if grep -q '^WARNING:' "$dir_reap_ac5/.rite/logs/pr-cycle-cleanup.log" 2>/dev/null; then
  pass "TC-1968-05: reap WARNING line captured to log"
else
  fail "TC-1968-05: expected a WARNING line in $dir_reap_ac5/.rite/logs/pr-cycle-cleanup.log, got: $(cat "$dir_reap_ac5/.rite/logs/pr-cycle-cleanup.log" 2>/dev/null)"
fi
echo ""

echo "TC-1968-06 (AC-3): mkdir succeeds but the log file itself is not writable → falls back to discard"
dir_reap_ac6="$TEST_DIR/reap-ac6"
mkdir -p "$dir_reap_ac6/.rite/logs"
# Existing read-only dir: mkdir -p is a no-op success even though writes inside
# it fail — the exact gap the writability probe (`{ : > file; } 2>/dev/null`)
# in session-start.sh closes.
chmod 555 "$dir_reap_ac6/.rite/logs"
# Verify chmod actually enforces read-only for this user/filesystem before
# asserting on the hook's behavior: root bypasses DAC bits entirely, and some
# filesystems (WSL2 DrvFs, certain overlay/container mounts) don't enforce
# owner write bits either — in either case a probe write here would silently
# succeed, making the assertion below meaningless rather than a real check.
# Braced so the open-failure message (not just the `:` command's own stderr)
# is captured by the redirect too — same pattern as session-start.sh's probe.
if { : > "$dir_reap_ac6/.rite/logs/.write-probe"; } 2>/dev/null; then
  rm -f "$dir_reap_ac6/.rite/logs/.write-probe"
  pass "TC-1968-06: filesystem/user does not enforce chmod 555 here — skipping assertion (not a real read-only dir on this host)"
else
  LAST_STDERR_FILE="$(mktemp "$TEST_DIR/stderr.XXXXXX")"
  echo "{\"cwd\": \"$dir_reap_ac6\"}" | bash "$HOOK" >/dev/null 2>"$LAST_STDERR_FILE"; rc1968_06=$?
  # A naive `if mkdir -p ...; then` (without the writability probe) would still
  # leave no log file here (the later `>file` redirect fails too), so absence of
  # the log file alone can't distinguish the fix from the bug it closes. What
  # distinguishes them: with the probe, the redirect that touches the read-only
  # dir is `{ : > file; } 2>/dev/null` (silenced); without it, the *reap
  # invocation's own* redirect (`>file 2>&1`, no local silencing) would fail and
  # bash would print its own "cannot create/Permission denied" line — with a
  # `session-start.sh: line N:` prefix — to the hook's stderr.
  if [ "$rc1968_06" -eq 0 ] && [ ! -e "$dir_reap_ac6/.rite/logs/pr-cycle-cleanup.log" ] \
       && ! grep -qE 'session-start\.sh: (line|行) [0-9]+:' "$LAST_STDERR_FILE"; then
    pass "TC-1968-06: hook exits 0, falls back to discard, and no bash redirect error leaks to stderr"
  else
    fail "TC-1968-06: expected exit 0, no log file, no bash redirect error; got rc=$rc1968_06, log exists: $([ -e "$dir_reap_ac6/.rite/logs/pr-cycle-cleanup.log" ] && echo yes || echo no), stderr: $(cat "$LAST_STDERR_FILE")"
  fi
fi
chmod 755 "$dir_reap_ac6/.rite/logs" 2>/dev/null || true
echo ""

echo "TC-1968-04 (AC-4): reap not invoked from a worktree-rooted CWD → log left untouched"
main_repo_1968="$TEST_DIR/reap-ac4-main"
mkdir -p "$main_repo_1968"
(cd "$main_repo_1968" && git init -q && git -c user.name="test" -c user.email="test@test.com" commit --allow-empty -m "init" -q)
wt_1968="$TEST_DIR/reap-ac4-wt"
(cd "$main_repo_1968" && git worktree add -q -b "feat/issue-1968-test" "$wt_1968") >/dev/null 2>&1
mkdir -p "$main_repo_1968/.rite/logs"
echo "PRE-EXISTING" > "$main_repo_1968/.rite/logs/pr-cycle-cleanup.log"
LAST_STDERR_FILE="$(mktemp "$TEST_DIR/stderr.XXXXXX")"
echo "{\"cwd\": \"$wt_1968\"}" | bash "$HOOK" >/dev/null 2>"$LAST_STDERR_FILE" || true
if [ "$(cat "$main_repo_1968/.rite/logs/pr-cycle-cleanup.log" 2>/dev/null)" = "PRE-EXISTING" ]; then
  pass "TC-1968-04: reap not invoked from worktree cwd → main-repo log unchanged"
else
  fail "TC-1968-04: main-repo log was modified even though reap should not run from a worktree cwd: $(cat "$main_repo_1968/.rite/logs/pr-cycle-cleanup.log" 2>/dev/null)"
fi
echo ""

echo "TC-1968-07 (self-contained gitignore): reap log dir gets its own .gitignore (*) on first creation"
dir_reap_ac7="$TEST_DIR/reap-ac7"
mkdir -p "$dir_reap_ac7"
(cd "$dir_reap_ac7" && git init -q && git -c user.name="test" -c user.email="test@test.com" commit --allow-empty -m "init" -q)
# TMPDIR isolation: same rationale as TC-1968-01/02/05 (real git fixture lets reap
# complete, which also triggers the orphan-workdir sweep under ${TMPDIR:-/tmp}).
iso_tmpdir_ac7="$TEST_DIR/reap-ac7-tmpdir"
mkdir -p "$iso_tmpdir_ac7"
LAST_STDERR_FILE="$(mktemp "$TEST_DIR/stderr.XXXXXX")"
echo "{\"cwd\": \"$dir_reap_ac7\"}" | TMPDIR="$iso_tmpdir_ac7" bash "$HOOK" >/dev/null 2>"$LAST_STDERR_FILE" || true
if [ "$(cat "$dir_reap_ac7/.rite/logs/.gitignore" 2>/dev/null)" = "*" ]; then
  pass "TC-1968-07: .rite/logs/.gitignore created with content '*' (self-excludes without relying on downstream setup coverage)"
else
  fail "TC-1968-07: expected .rite/logs/.gitignore with content '*', got: $(cat "$dir_reap_ac7/.rite/logs/.gitignore" 2>/dev/null)"
fi
echo ""

echo "TC-1968-08 (regression: .gitignore write failure does not leak a bash redirect error): .gitignore path collides with a directory"
dir_reap_ac8="$TEST_DIR/reap-ac8"
mkdir -p "$dir_reap_ac8"
(cd "$dir_reap_ac8" && git init -q && git -c user.name="test" -c user.email="test@test.com" commit --allow-empty -m "init" -q)
# Name collision: pre-create .gitignore as a directory so the `-f` check is
# false (attempt proceeds) but the printf redirect fails (can't write a file
# where a directory exists) — same failure shape as the read-only-dir case in
# TC-1968-06, without needing DAC bits (portable across root/WSL2/overlayfs).
mkdir -p "$dir_reap_ac8/.rite/logs/.gitignore"
iso_tmpdir_ac8="$TEST_DIR/reap-ac8-tmpdir"
mkdir -p "$iso_tmpdir_ac8"
LAST_STDERR_FILE="$(mktemp "$TEST_DIR/stderr.XXXXXX")"
echo "{\"cwd\": \"$dir_reap_ac8\"}" | TMPDIR="$iso_tmpdir_ac8" bash "$HOOK" >/dev/null 2>"$LAST_STDERR_FILE"; rc1968_08=$?
if [ "$rc1968_08" -eq 0 ] && ! grep -qE 'session-start\.sh: (line|行) [0-9]+:' "$LAST_STDERR_FILE"; then
  pass "TC-1968-08: .gitignore write failure (path collision) does not leak bash redirect error to stderr"
else
  fail "TC-1968-08: expected exit 0, no bash redirect error; got rc=$rc1968_08, stderr: $(cat "$LAST_STDERR_FILE")"
fi
echo ""

echo "nested .rite mkdir failure: file at .rite emits WARNING, hook exits 0"
dir_rite_file="$TEST_DIR/rite-as-file"
mkdir -p "$dir_rite_file"
(cd "$dir_rite_file" && git init -q && git -c user.name="test" -c user.email="test@test.com" commit --allow-empty -m "init" -q)
# A file named ".rite" at STATE_ROOT blocks `mkdir -p .../.rite`, so the
# nested gitignore else branch runs without needing a read-only filesystem
# (same collision pattern as TC-1968-03).
printf 'not-a-dir\n' > "$dir_rite_file/.rite"
iso_tmpdir_rite_file="$TEST_DIR/rite-as-file-tmpdir"
mkdir -p "$iso_tmpdir_rite_file"
LAST_STDERR_FILE="$(mktemp "$TEST_DIR/stderr.XXXXXX")"
echo "{\"cwd\": \"$dir_rite_file\"}" | TMPDIR="$iso_tmpdir_rite_file" bash "$HOOK" >/dev/null 2>"$LAST_STDERR_FILE"; rc_rite_file=$?
if [ "$rc_rite_file" -eq 0 ] \
  && grep -q 'nested gitignore not written' "$LAST_STDERR_FILE" \
  && [ -f "$dir_rite_file/.rite" ] \
  && [ ! -d "$dir_rite_file/.rite" ]; then
  pass "nested .rite mkdir failure: WARNING emitted and hook exits 0"
else
  fail "nested .rite mkdir failure: expected rc=0 + 'nested gitignore not written' with .rite still a file; got rc=$rc_rite_file, .rite is $([ -d "$dir_rite_file/.rite" ] && echo dir || echo file-or-missing), stderr: $(cat "$LAST_STDERR_FILE")"
fi
echo ""

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ $FAIL -gt 0 ]; then
  exit 1
fi
