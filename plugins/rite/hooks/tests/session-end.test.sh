#!/bin/bash
# Tests for session-end.sh
# Usage: bash plugins/rite/hooks/tests/session-end.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../session-end.sh"
TEST_DIR="$(mktemp -d)"
LAST_STDERR_FILE=""
PASS=0
FAIL=0

# Prerequisite check: jq is required by session-end.sh
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

# Helper: run session-end hook with given CWD, capture stdout and stderr
run_hook() {
  local cwd="$1"
  local rc=0
  local output
  LAST_STDERR_FILE="$(mktemp "$TEST_DIR/stderr.XXXXXX")"
  output=$(echo "{\"cwd\": \"$cwd\"}" | bash "$HOOK" 2>"$LAST_STDERR_FILE") || rc=$?
  echo "$output"
  return $rc
}

echo "=== session-end.sh tests ==="
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
# TC-003: Branch with issue-{number} → message displayed
# --------------------------------------------------------------------------
echo "TC-003: Branch with issue-{number} → message displayed"
git_repo_003="$TEST_DIR/git_tc003"
mkdir -p "$git_repo_003"
(cd "$git_repo_003" && git init -q && git -c user.name="test" -c user.email="test@test.com" commit --allow-empty -m "init" -q && git checkout -b "feat/issue-456-cleanup" -q)

output=$(run_hook "$git_repo_003")
if echo "$output" | grep -q "Saving final state for Issue #456"; then
  pass "Branch detection found Issue #456 in output"
else
  fail "Expected 'Issue #456' in output, got: $output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-004: Branch without issue pattern → no special message
# --------------------------------------------------------------------------
echo "TC-004: Branch without issue pattern → no special message"
git_repo_004="$TEST_DIR/git_tc004"
mkdir -p "$git_repo_004"
# cycle 11 MEDIUM F-05: `git checkout -b main` は現代 git (init.defaultBranch=main) で
# 既存 main と衝突し `set -e` で script 全体を abort させる。その結果 cycle 9-10 で追加した
# TC-608-WARN-A〜E が一度も実行されない regression guard 実質未検証状態になっていた。
# `-B` (force reset, create if missing) を使用して defaultBranch 設定に依存しない形に修正。
(cd "$git_repo_004" && git init -q && git -c user.name="test" -c user.email="test@test.com" commit --allow-empty -m "init" -q && git checkout -B "main" -q)

output=$(run_hook "$git_repo_004")
if ! echo "$output" | grep -q "Saving final state for Issue"; then
  pass "No issue branch → no issue-specific message"
else
  fail "Expected no issue message, got: $output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-005: State file exists → active set to false, updated_at updated
# --------------------------------------------------------------------------
echo "TC-005: State file exists → active=false, updated_at updated"
dir005="$TEST_DIR/tc005"
mkdir -p "$dir005"
create_state_file "$dir005" '{"active": true, "issue_number": 42, "phase": "impl"}'

output=$(run_hook "$dir005")
active=$(jq -r '.active' "$dir005/.rite-flow-state")
updated_at=$(jq -r '.updated_at' "$dir005/.rite-flow-state")

if [ "$active" = "false" ] && echo "$updated_at" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\+00:00$'; then
  pass "State file deactivated and updated_at set"
else
  fail "active=$active, updated_at=$updated_at"
fi
echo ""

# --------------------------------------------------------------------------
# TC-006: State file deactivation preserves other fields
# --------------------------------------------------------------------------
echo "TC-006: State file deactivation preserves other fields"
dir006="$TEST_DIR/tc006"
mkdir -p "$dir006"
create_state_file "$dir006" '{"active": true, "issue_number": 99, "phase": "test", "loop_count": 5}'

output=$(run_hook "$dir006")
issue=$(jq -r '.issue_number' "$dir006/.rite-flow-state")
phase=$(jq -r '.phase' "$dir006/.rite-flow-state")
loop=$(jq -r '.loop_count' "$dir006/.rite-flow-state")

if [ "$issue" = "99" ] && [ "$phase" = "test" ] && [ "$loop" = "5" ]; then
  pass "Existing fields preserved (issue=$issue, phase=$phase, loop=$loop)"
else
  fail "Fields were modified: issue=$issue, phase=$phase, loop=$loop"
fi
echo ""

# --------------------------------------------------------------------------
# TC-007: No state file → no error, hook completes normally
# --------------------------------------------------------------------------
echo "TC-007: No state file → no error"
dir007="$TEST_DIR/tc007"
mkdir -p "$dir007"

output=$(run_hook "$dir007") && rc=0 || rc=$?
if [ $rc -eq 0 ]; then
  pass "No state file → exit 0"
else
  fail "Expected exit 0, got rc=$rc"
fi
echo ""

# --------------------------------------------------------------------------
# TC-008: Corrupted state file JSON → temp file cleanup, non-zero exit
# --------------------------------------------------------------------------
echo "TC-008: Corrupted state file JSON → cleanup, exit 0 (best-effort)"
dir008="$TEST_DIR/tc008"
mkdir -p "$dir008"
echo "{broken json" > "$dir008/.rite-flow-state"

# session-end.sh prioritizes cleanup over strict error propagation
output=$(run_hook "$dir008") && rc=0 || rc=$?
# Check that temp files are cleaned up even on jq failure
temp_files=$(find "$dir008" -name ".rite-flow-state.tmp.*" 2>/dev/null | wc -l)
if [ "$temp_files" -eq 0 ]; then
  pass "Corrupted JSON → temp files cleaned up (rc=$rc)"
else
  fail "Temp files not cleaned: $temp_files files found"
fi
echo ""

# --------------------------------------------------------------------------
# TC-009: Stale temp file cleanup (older than 1 minute)
# --------------------------------------------------------------------------
echo "TC-009: Stale temp file cleanup"
dir009="$TEST_DIR/tc009"
mkdir -p "$dir009"
create_state_file "$dir009" '{"active": true, "issue_number": 1}'

# Create a stale temp file
stale_file="$dir009/.rite-flow-state.tmp.99999"
touch "$stale_file"
# Set modification time to 2 minutes ago
touch -t "$(date -u -d '2 minutes ago' +'%Y%m%d%H%M' 2>/dev/null || date -u -v-2M +'%Y%m%d%H%M')" "$stale_file" 2>/dev/null || true

# Run hook (should clean up stale file)
output=$(run_hook "$dir009")

if [ ! -f "$stale_file" ]; then
  pass "Stale temp file cleaned up"
else
  fail "Stale temp file not cleaned up: $stale_file"
fi
echo ""

# --------------------------------------------------------------------------
# TC-010: PID-based temp file creation and trap cleanup
# --------------------------------------------------------------------------
echo "TC-010: PID-based temp file creation and cleanup"
dir010="$TEST_DIR/tc010"
mkdir -p "$dir010"
create_state_file "$dir010" '{"active": true, "issue_number": 123}'

# Run hook (temp file should be created and cleaned up by trap)
output=$(run_hook "$dir010")

# Verify no temp files remain after successful completion
temp_count=$(find "$dir010" -name ".rite-flow-state.tmp.*" 2>/dev/null | wc -l)
if [ "$temp_count" -eq 0 ]; then
  pass "Temp file created and cleaned up by trap"
else
  fail "Temp files not cleaned up: $temp_count files found"
fi
echo ""

# --------------------------------------------------------------------------
# TC-011: Updated timestamp is parseable and recent
# --------------------------------------------------------------------------
echo "TC-011: Updated timestamp is parseable and recent"
dir011="$TEST_DIR/tc011"
mkdir -p "$dir011"
create_state_file "$dir011" '{"active": true, "issue_number": 1}'

before_epoch=$(date +%s)
output=$(run_hook "$dir011")
after_epoch=$(date +%s)

updated_at=$(jq -r '.updated_at' "$dir011/.rite-flow-state")
# Parse timestamp with GNU date
if state_epoch=$(date -d "$updated_at" +%s 2>/dev/null); then
  if [ "$state_epoch" -ge "$before_epoch" ] && [ "$state_epoch" -le "$after_epoch" ]; then
    pass "Timestamp is parseable and within test execution window"
  else
    fail "Timestamp out of range: $updated_at (epoch: $state_epoch, expected: $before_epoch-$after_epoch)"
  fi
else
  fail "Timestamp not parseable by date -d: $updated_at"
fi
echo ""

# --------------------------------------------------------------------------
# TC-475-WARN-A: create_interview lifecycle unfinished → stderr warning (#475 AC-9)
# --------------------------------------------------------------------------
echo "TC-475-WARN-A: create_interview active → lifecycle warning in stderr"
dir475wa="$TEST_DIR/tc475wa"
mkdir -p "$dir475wa"
create_state_file "$dir475wa" '{"active": true, "phase": "create_interview", "issue_number": 0, "branch": ""}'
run_hook "$dir475wa" >/dev/null || true
if [ -f "${LAST_STDERR_FILE:-}" ] && grep -q "lifecycle was not completed" "$LAST_STDERR_FILE"; then
  pass "create_interview unfinished → warning emitted"
else
  fail "expected lifecycle warning in stderr, got: $(cat "${LAST_STDERR_FILE:-/dev/null}" 2>/dev/null)"
fi
echo ""

# TC-475-WARN-B: create_post_interview also emits warning
echo "TC-475-WARN-B: create_post_interview active → lifecycle warning"
dir475wb="$TEST_DIR/tc475wb"
mkdir -p "$dir475wb"
create_state_file "$dir475wb" '{"active": true, "phase": "create_post_interview", "issue_number": 0, "branch": ""}'
run_hook "$dir475wb" >/dev/null || true
if grep -q "lifecycle was not completed" "${LAST_STDERR_FILE:-/dev/null}"; then
  pass "create_post_interview unfinished → warning emitted"
else
  fail "expected lifecycle warning in stderr"
fi
echo ""

# TC-475-WARN-C: create_completed → NO warning (lifecycle finished)
echo "TC-475-WARN-C: create_completed → no warning"
dir475wc="$TEST_DIR/tc475wc"
mkdir -p "$dir475wc"
create_state_file "$dir475wc" '{"active": true, "phase": "create_completed", "issue_number": 0, "branch": ""}'
run_hook "$dir475wc" >/dev/null || true
if grep -q "lifecycle was not completed" "${LAST_STDERR_FILE:-/dev/null}"; then
  fail "unexpected warning for create_completed"
else
  pass "create_completed → no warning (lifecycle finished)"
fi
echo ""

# TC-475-WARN-D: phase5_lint (different workflow) → NO warning
echo "TC-475-WARN-D: phase5_lint → no warning (not create lifecycle)"
dir475wd="$TEST_DIR/tc475wd"
mkdir -p "$dir475wd"
create_state_file "$dir475wd" '{"active": true, "phase": "phase5_lint", "issue_number": 475, "branch": ""}'
run_hook "$dir475wd" >/dev/null || true
if grep -q "lifecycle was not completed" "${LAST_STDERR_FILE:-/dev/null}"; then
  fail "unexpected warning for non-create phase"
else
  pass "phase5_lint → no warning"
fi
echo ""

# --------------------------------------------------------------------------
# TC-608-WARN-A: cleanup_pre_ingest lifecycle unfinished → stderr warning (#604)
# Verifies the cleanup lifecycle warning path added in session-end.sh "Lifecycle unfinished
# warnings" section (case "$_lifecycle_unfinished_kind" in cleanup) branch).
# (line-number 参照を避ける理由は cycle 8 F-05 参照)
# --------------------------------------------------------------------------
echo "TC-608-WARN-A: cleanup_pre_ingest active → /rite:pr:cleanup lifecycle warning"
dir608wa="$TEST_DIR/tc608wa"
mkdir -p "$dir608wa"
create_state_file "$dir608wa" '{"active": true, "phase": "cleanup_pre_ingest", "issue_number": 604, "branch": ""}'
run_hook "$dir608wa" >/dev/null || true
if [ -f "${LAST_STDERR_FILE:-}" ] \
    && grep -q "lifecycle was not completed" "$LAST_STDERR_FILE" \
    && grep -q "/rite:pr:cleanup" "$LAST_STDERR_FILE"; then
  pass "cleanup_pre_ingest unfinished → cleanup-specific warning emitted"
else
  fail "expected /rite:pr:cleanup lifecycle warning, got: $(cat "${LAST_STDERR_FILE:-/dev/null}" 2>/dev/null)"
fi
echo ""

# TC-608-WARN-B: cleanup_completed → NO warning (lifecycle finished)
echo "TC-608-WARN-B: cleanup_completed → no warning"
dir608wb="$TEST_DIR/tc608wb"
mkdir -p "$dir608wb"
create_state_file "$dir608wb" '{"active": true, "phase": "cleanup_completed", "issue_number": 604, "branch": ""}'
run_hook "$dir608wb" >/dev/null || true
if grep -q "lifecycle was not completed" "${LAST_STDERR_FILE:-/dev/null}"; then
  fail "unexpected warning for cleanup_completed"
else
  pass "cleanup_completed → no warning (lifecycle finished)"
fi
echo ""

# TC-608-WARN-C: create_* phases must NOT be misclassified as cleanup lifecycle
# (regression guard — ensures the cleanup detection branch doesn't swallow create_*)
echo "TC-608-WARN-C: create_interview active → create-specific warning (not cleanup)"
dir608wc="$TEST_DIR/tc608wc"
mkdir -p "$dir608wc"
create_state_file "$dir608wc" '{"active": true, "phase": "create_interview", "issue_number": 0, "branch": ""}'
run_hook "$dir608wc" >/dev/null || true
# create 側の warning が出て、cleanup 側の warning は出ないこと
if grep -q "/rite:issue:create lifecycle" "${LAST_STDERR_FILE:-/dev/null}" \
    && ! grep -q "/rite:pr:cleanup lifecycle" "${LAST_STDERR_FILE:-/dev/null}"; then
  pass "create_interview → create warning (no cleanup misclassification)"
else
  fail "expected create-specific warning without cleanup warning, got: $(cat "${LAST_STDERR_FILE:-/dev/null}" 2>/dev/null)"
fi
echo ""

# TC-608-WARN-D: cleanup_post_ingest phase branch coverage (case branch 全網羅)
# session-end.sh の cleanup lifecycle check は cleanup / cleanup_pre_ingest / cleanup_post_ingest の
# 3 phase をカバーする必要がある。TC-608-WARN-A は cleanup_pre_ingest のみで、cleanup_post_ingest
# の case branch が削除されても WARN-A/B/C は pass し続ける false-positive 構造。本 TC で補完。
echo "TC-608-WARN-D: cleanup_post_ingest active → /rite:pr:cleanup lifecycle warning"
dir608wd="$TEST_DIR/tc608wd"
mkdir -p "$dir608wd"
create_state_file "$dir608wd" '{"active": true, "phase": "cleanup_post_ingest", "issue_number": 604, "branch": ""}'
run_hook "$dir608wd" >/dev/null || true
if [ -f "${LAST_STDERR_FILE:-}" ] \
    && grep -q "lifecycle was not completed" "$LAST_STDERR_FILE" \
    && grep -q "/rite:pr:cleanup" "$LAST_STDERR_FILE"; then
  pass "cleanup_post_ingest unfinished → cleanup-specific warning emitted (branch coverage 完備)"
else
  fail "expected /rite:pr:cleanup lifecycle warning for cleanup_post_ingest, got: $(cat "${LAST_STDERR_FILE:-/dev/null}" 2>/dev/null)"
fi
echo ""

# TC-608-WARN-E: bare cleanup phase branch coverage (cycle 9 F-11)
# rite_phase_is_cleanup_lifecycle_in_progress の case arm `cleanup|cleanup_pre_ingest|cleanup_post_ingest)`
# のうち、bare `cleanup` arm が削除されても WARN-A/B/C/D は全 pass する false-positive 構造を補完。
# Phase 1.0 Activate Flow State で実際に書かれる phase 名 (stop-guard.sh cleanup case と同一) の regression guard。
#
# NOTE (cycle 10 F-08): 本 TC は **case arm 改変の検出が scope**。関数定義全体が削除された場合は
# session-end.sh の ELIF fallback (`elif echo "$phase" | grep -q "^cleanup"`) が発火して同じ warning
# を出すため silently pass する限界あり (関数欠損時は call site が `rite_phase_is_cleanup_lifecycle_in_progress`
# 自体を呼べない別エラー経路で検出される想定)。関数欠損の regression guard は別 TC (phase-transition-whitelist
# unit test) で扱う必要あり (F-09 と合わせて別 Issue で tracking 推奨)。
echo "TC-608-WARN-E: cleanup active → /rite:pr:cleanup lifecycle warning (bare cleanup arm coverage)"
dir608we="$TEST_DIR/tc608we"
mkdir -p "$dir608we"
create_state_file "$dir608we" '{"active": true, "phase": "cleanup", "issue_number": 604, "branch": ""}'
run_hook "$dir608we" >/dev/null || true
if [ -f "${LAST_STDERR_FILE:-}" ] \
    && grep -q "lifecycle was not completed" "$LAST_STDERR_FILE" \
    && grep -q "/rite:pr:cleanup" "$LAST_STDERR_FILE"; then
  pass "bare cleanup unfinished → cleanup-specific warning emitted (case arm 全網羅完成)"
else
  fail "expected /rite:pr:cleanup lifecycle warning for bare cleanup, got: $(cat "${LAST_STDERR_FILE:-/dev/null}" 2>/dev/null)"
fi
echo ""

# --------------------------------------------------------------------------
# TC-680-A (Issue #680, AC-10): per-session flow-state file is removed on session end
# --------------------------------------------------------------------------
echo "TC-680-A (Issue #680, AC-10): per-session file → cleanup on session end"
dir680a="$TEST_DIR/tc680a"
mkdir -p "$dir680a/.rite/sessions"
sid680a="abcdef01-2345-6789-abcd-ef0123456789"
echo "$sid680a" > "$dir680a/.rite-session-id"
cat > "$dir680a/rite-config.yml" <<EOF
flow_state:
  schema_version: 2
EOF
per_session_file="$dir680a/.rite/sessions/${sid680a}.flow-state"
echo '{"active": true, "phase": "phase5_review", "issue_number": 680, "branch": "refactor/issue-680-test"}' > "$per_session_file"
run_hook "$dir680a" >/dev/null || true
if [ ! -f "$per_session_file" ]; then
  pass "TC-680-A: per-session file removed after session-end (AC-10)"
else
  fail "TC-680-A: per-session file not removed (still at $per_session_file)"
fi
# Counter-assertion: legacy file (which never existed) was not created
if [ ! -f "$dir680a/.rite-flow-state" ]; then
  pass "TC-680-A: legacy file not created (no leakage to legacy path)"
else
  fail "TC-680-A: legacy file unexpectedly created"
fi
echo ""

# --------------------------------------------------------------------------
# TC-680-B (Issue #680): legacy flow-state file is preserved (NOT deleted) on session end
# --------------------------------------------------------------------------
echo "TC-680-B (Issue #680): legacy file → preserved (active=false marker only)"
dir680b="$TEST_DIR/tc680b"
mkdir -p "$dir680b"
# No rite-config.yml → schema_version=1 (legacy mode)
create_state_file "$dir680b" '{"active": true, "phase": "phase5_review", "issue_number": 681}'
run_hook "$dir680b" >/dev/null || true
if [ -f "$dir680b/.rite-flow-state" ]; then
  active_after=$(jq -r '.active' "$dir680b/.rite-flow-state" 2>/dev/null)
  if [ "$active_after" = "false" ]; then
    pass "TC-680-B: legacy file preserved with active=false (backward compat)"
  else
    fail "TC-680-B: legacy file present but active=$active_after (expected false)"
  fi
else
  fail "TC-680-B: legacy file unexpectedly removed (would break v1 backward compat)"
fi
echo ""

# --------------------------------------------------------------------------
# TC-680-C (Issue #680, AC-LOCAL-2): .active=true precondition preserved on per-session path
# Defense-in-depth: ensure jq -r '.active' / `_state_active=...` paths still
# fire correctly when the resolved STATE_FILE is per-session, not legacy.
# --------------------------------------------------------------------------
echo "TC-680-C (Issue #680, AC-LOCAL-2): per-session active=true → lifecycle warning fires"
dir680c="$TEST_DIR/tc680c"
mkdir -p "$dir680c/.rite/sessions"
sid680c="11111111-2222-3333-4444-555555555555"
echo "$sid680c" > "$dir680c/.rite-session-id"
cat > "$dir680c/rite-config.yml" <<EOF
flow_state:
  schema_version: 2
EOF
echo '{"active": true, "phase": "create_interview", "issue_number": 682, "branch": "feat/issue-682"}' \
  > "$dir680c/.rite/sessions/${sid680c}.flow-state"
run_hook "$dir680c" >/dev/null || true
if [ -f "${LAST_STDERR_FILE:-}" ] && grep -q "/rite:issue:create lifecycle was not completed" "$LAST_STDERR_FILE"; then
  pass "TC-680-C: .active=true precondition fires lifecycle warning on per-session path (AND-logic preserved)"
else
  fail "TC-680-C: lifecycle warning missing — .active=true precondition broke on per-session path"
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
  | bash "$sbx_749/session-end.sh" >/dev/null 2>"$LAST_STDERR_FILE" || true
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
# session-end.sh should deactivate the legacy state file (set .active=false). If the
# fallback path silently broke, the file would remain .active=true.
deactivated_active=$(jq -r '.active' "$dir_749/.rite-flow-state" 2>/dev/null)
if [ "$deactivated_active" = "false" ]; then
  pass "Legacy fallback path was loaded (.active flipped to false)"
else
  fail "Expected .active=false in legacy state file; got: $deactivated_active"
fi
echo ""

# --------------------------------------------------------------------------
# TC-749-JQ-WRITE-WARN (Issue #749, AC-3)
# --------------------------------------------------------------------------
# Verify that when jq fails to write the deactivated state (else arm of the
# atomic write block), session-end emits a diagnostic WARNING to stderr
# instead of silently swallowing the failure.
echo "TC-749-JQ-WRITE-WARN: jq atomic write failure → WARNING emitted"

sbx_jq="$(mktemp -d "$TEST_DIR/sbx-hooks-jq-XXXXXX")"
cp -a "$HOOKS_REAL_DIR/." "$sbx_jq/"

# Inject a fake jq into a private bin dir at the front of PATH that exits 1
# only on the deactivation invocation, while passing through all other jq calls
# unchanged so the hook can still parse its inputs (cwd, source, ownership probe,
# lifecycle phase, etc.).
#
# The fake jq pattern below uses a relaxed match (`*'.active'*'.updated_at'*`)
# instead of the exact production string, so that harmless jq expression
# refactors (whitespace tweaks, order swaps) do not break this TC. The
# underlying invariant being tested is "WARNING is emitted when jq atomic
# write fails", not "the production jq expression has not been touched".
#
# Resolve the real jq path via `command -v jq` rather than hardcoding
# `/usr/bin/jq`, because macOS Homebrew installs jq under
# `/opt/homebrew/bin/jq` and Nix uses `/run/current-system/sw/bin/jq`, etc.
JQ_REAL="$(command -v jq)"
if [ -z "$JQ_REAL" ]; then
  fail "TC-749-JQ-WRITE-WARN: real jq not found in PATH (cannot build fake jq)"
else
  fake_jq_bin="$(mktemp -d "$TEST_DIR/fakejq-XXXXXX")"
  # Use double-quoted heredoc so $JQ_REAL is expanded into the fake script
  cat > "$fake_jq_bin/jq" <<FAKE_JQ_EOF
#!/bin/bash
# Fake jq: fail only on the session-end deactivation invocation
# Pattern intentionally relaxed — see test file comment above for rationale
for arg in "\$@"; do
  case "\$arg" in
    *'.active'*'.updated_at'*)
      echo "fake jq: simulated failure for TC-749-JQ-WRITE-WARN" >&2
      exit 1
      ;;
  esac
done
exec '$JQ_REAL' "\$@"
FAKE_JQ_EOF
  chmod +x "$fake_jq_bin/jq"
fi

dir_jq="$TEST_DIR/tc749-jq"
mkdir -p "$dir_jq"
(
  cd "$dir_jq" && git init -q \
    && git -c user.name=test -c user.email=test@test.com commit --allow-empty -m init -q \
    && git checkout -B "refactor/issue-749-jqwarn" -q
)
cat > "$dir_jq/.rite-flow-state" <<EOF
{"active": true, "issue_number": 749, "phase": "phase5_test", "branch": "refactor/issue-749-jqwarn"}
EOF

LAST_STDERR_FILE="$(mktemp "$TEST_DIR/stderr.749jq.XXXXXX")"
PATH="$fake_jq_bin:$PATH" \
  bash -c "echo '{\"cwd\": \"$dir_jq\"}' | bash '$sbx_jq/session-end.sh'" \
  >/dev/null 2>"$LAST_STDERR_FILE" || true
stderr_jq="$(cat "$LAST_STDERR_FILE")"

if printf '%s' "$stderr_jq" | grep -qF 'rite: session-end: failed to deactivate state file'; then
  pass "WARNING emitted on jq atomic write failure"
else
  fail "Expected jq-write WARNING; got stderr: $stderr_jq"
fi
# Assert the structural invariant ("WARNING contains an Issue number") instead
# of a literal number, which would only match by coincidence with the test
# branch name and become brittle if the branch convention changes.
if printf '%s' "$stderr_jq" | grep -qE 'Issue #[0-9]+'; then
  pass "WARNING includes Issue number from branch detection"
else
  fail "Expected 'Issue #<number>' in WARNING; got stderr: $stderr_jq"
fi
# Assert state_file path appears in WARNING (so $STATE_FILE substitution works
# and operators can locate the failed deactivation target without grepping git).
if printf '%s' "$stderr_jq" | grep -qF '.rite-flow-state'; then
  pass "WARNING includes state file path"
else
  fail "Expected state file path '.rite-flow-state' in WARNING; got stderr: $stderr_jq"
fi
# Assert jq stderr is passed through to the caller (not silently swallowed).
# session-end.sh runs `jq ... > "$TMP_FILE"` without `2>/dev/null`, so jq's own
# error diagnostics (line/column on parse errors, or here our fake script's
# stderr) MUST reach the user. Locking this in test prevents a future refactor
# from adding `2>/dev/null` and silently dropping the production jq diagnostic.
if printf '%s' "$stderr_jq" | grep -qF 'fake jq: simulated failure'; then
  pass "jq stderr passed through to caller"
else
  fail "Expected fake jq stderr in WARNING; got stderr: $stderr_jq"
fi
echo ""

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ $FAIL -gt 0 ]; then
  exit 1
fi
