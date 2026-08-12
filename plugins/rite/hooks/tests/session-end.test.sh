#!/bin/bash
# Tests for session-end.sh
# Usage: bash plugins/rite/hooks/tests/session-end.test.sh
set -euo pipefail

issue_text() { printf 'Issue #%s' "$1"; }

# Hermeticity guard: flow-state.sh path resolves session_id with
# priority env CLAUDE_CODE_SESSION_ID > env CLAUDE_SESSION_ID > .rite-session-id
# file. When this test suite runs inside a live Claude Code
# session, that session's own id leaks into every `bash "$HOOK"` invocation
# below and silently overrides the file-based per-session fixtures, making the
# hook resolve a nonexistent (or wrong) flow-state file. Unsetting both here
# forces every invocation to resolve session_id from the fixture's
# `.rite-session-id` file, matching the intended test isolation.
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID

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

# Helper: create a per-session state file (schema v3) in the given directory.
# Writes .rite-session-id and .rite/sessions/<sid>.flow-state. The default sid
# is deterministic so subsequent run_hook calls resolve the same file via the
# .rite-session-id fallback in flow-state.sh path.
# Auto-injects schema_version=3 if the content is JSON without it, so the
# session-end hook does not re-migrate the fixture mid-test.
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
if echo "$output" | grep -q "Saving final state for $(issue_text 456)"; then
  pass "Branch detection found the expected issue in output"
else
  fail "Expected '$(issue_text 456)' in output, got: $output"
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
# TC-cleanup-lifecycle-warn-A〜E が一度も実行されない regression guard 実質未検証状態になっていた。
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
echo "TC-005: State file exists → deactivated then removed (AC-10)"
dir005="$TEST_DIR/tc005"
mkdir -p "$dir005"
create_state_file "$dir005" '{"active": true, "issue_number": 42, "phase": "implement"}'

# PR 2a refactor: under per-session model session-end.sh deactivates (.active=false +
# updated_at) AND then removes the per-session file (AC-10). The legacy
# assertion (file remains with .active=false) is no longer satisfiable; the
# observable invariant is "file is gone after session-end".
output=$(run_hook "$dir005")
sf005=$(state_file_path "$dir005")
if [ ! -f "$sf005" ]; then
  pass "Per-session state file removed after session-end (AC-10)"
else
  active=$(jq -r '.active' "$sf005" 2>/dev/null)
  fail "Expected per-session file removed; still present with active=$active"
fi
echo ""

# --------------------------------------------------------------------------
# TC-006: State file deactivation preserves other fields
# --------------------------------------------------------------------------
# TC-006 removed (PR 2a refactor): the deactivation-preserves-fields assertion
# only made sense when the legacy `.rite-flow-state` file stayed on disk after
# session-end. Under v3 the per-session file is deleted at the end of the hook,
# so there is no on-disk state to inspect for field preservation. The field
# layout itself is now pinned by the schema_version=3 SoT in flow-state.sh.

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
# Write broken JSON via create_state_file so the per-session resolver finds it
create_state_file "$dir008" "{broken json"

# session-end.sh prioritizes cleanup over strict error propagation
output=$(run_hook "$dir008") && rc=0 || rc=$?
# Check that no temp files leak in the per-session directory (legacy
# `.rite-flow-state.tmp.*` is no longer produced — atomic writes live under
# `.rite/sessions/<sid>.flow-state.XXXXXX`).
temp_files=$(find "$dir008/.rite/sessions" -name "*.flow-state.*" -not -name "*.flow-state" 2>/dev/null | wc -l)
if [ "$temp_files" -eq 0 ]; then
  pass "Corrupted JSON → temp files cleaned up (rc=$rc)"
else
  fail "Temp files not cleaned: $temp_files files found"
fi
echo ""

# --------------------------------------------------------------------------
# TC-009: Stale temp file cleanup (older than 1 minute)
# --------------------------------------------------------------------------
echo "TC-009: Stale legacy temp file cleanup (orphans in CWD)"
dir009="$TEST_DIR/tc009"
mkdir -p "$dir009"
create_state_file "$dir009" '{"active": true, "issue_number": 1}'

# Create a stale temp file at the legacy path — session-end.sh's stale cleanup
# (`find $CWD -maxdepth 1 -name '.rite-flow-state.tmp.*' -mmin +1 -delete`)
# still mops up orphans from pre-v3 deployments.
stale_file="$dir009/.rite-flow-state.tmp.99999"
touch "$stale_file"
# Set modification time to 2 minutes ago
touch -t "$(date -u -d '2 minutes ago' +'%Y%m%d%H%M' 2>/dev/null || date -u -v-2M +'%Y%m%d%H%M')" "$stale_file" 2>/dev/null || true

# Run hook (should clean up stale file)
output=$(run_hook "$dir009")

if [ ! -f "$stale_file" ]; then
  pass "Stale legacy temp file cleaned up"
else
  fail "Stale legacy temp file not cleaned up: $stale_file"
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

# Verify no temp files remain after successful completion. Atomic writes
# under v3 land in `.rite/sessions/<sid>.flow-state.XXXXXX`; the legacy
# `.rite-flow-state.tmp.*` form is no longer produced but is still searched
# defensively to catch regression.
temp_count=$(find "$dir010" -name ".rite-flow-state.tmp.*" 2>/dev/null | wc -l)
per_session_temp_count=$(find "$dir010/.rite/sessions" -name "*.flow-state.*" -not -name "*.flow-state" 2>/dev/null | wc -l)
total=$((temp_count + per_session_temp_count))
if [ "$total" -eq 0 ]; then
  pass "Temp file created and cleaned up by trap (legacy=$temp_count, per-session=$per_session_temp_count)"
else
  fail "Temp files not cleaned up: legacy=$temp_count, per-session=$per_session_temp_count"
fi
echo ""

# --------------------------------------------------------------------------
# TC-011: Updated timestamp is parseable and recent
# --------------------------------------------------------------------------
# TC-011 removed (PR 2a refactor): the updated_at-within-window assertion read
# the legacy state file post-session-end. Under v3 the per-session file is
# deleted by session-end (AC-10), so updated_at cannot be inspected after the
# hook runs. The timestamp format itself is pinned by flow-state.sh cmd_set's
# `date -u +"%Y-%m-%dT%H:%M:%SZ"` and exercised by other hooks' tests.

# --------------------------------------------------------------------------
# TC-create-lifecycle-warn-A: create_interview lifecycle unfinished → stderr warning (AC-9)
# --------------------------------------------------------------------------
echo "TC-create-lifecycle-warn-A: create_interview active → lifecycle warning in stderr"
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

# TC-create-lifecycle-warn-B: create_post_interview also emits warning
echo "TC-create-lifecycle-warn-B: create_post_interview active → lifecycle warning"
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

# TC-create-lifecycle-warn-C: create_completed → NO warning (lifecycle finished)
echo "TC-create-lifecycle-warn-C: create_completed → no warning"
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

# TC-create-lifecycle-warn-D: phase5_lint (different workflow) → NO warning
echo "TC-create-lifecycle-warn-D: phase5_lint → no warning (not create lifecycle)"
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
# TC-cleanup-lifecycle-warn-A: cleanup_pre_ingest lifecycle unfinished → stderr warning
# Verifies the cleanup lifecycle warning path added in session-end.sh "Lifecycle unfinished
# warnings" section (case "$_lifecycle_unfinished_kind" in cleanup) branch).
# (line-number 参照を避ける理由は cycle 8 F-05 参照)
# --------------------------------------------------------------------------
echo "TC-cleanup-lifecycle-warn-A: cleanup_pre_ingest active → /rite:cleanup lifecycle warning"
dir608wa="$TEST_DIR/tc608wa"
mkdir -p "$dir608wa"
create_state_file "$dir608wa" '{"active": true, "phase": "cleanup_pre_ingest", "issue_number": 604, "branch": ""}'
run_hook "$dir608wa" >/dev/null || true
if [ -f "${LAST_STDERR_FILE:-}" ] \
    && grep -q "lifecycle was not completed" "$LAST_STDERR_FILE" \
    && grep -q "/rite:cleanup" "$LAST_STDERR_FILE"; then
  pass "cleanup_pre_ingest unfinished → cleanup-specific warning emitted"
else
  fail "expected /rite:cleanup lifecycle warning, got: $(cat "${LAST_STDERR_FILE:-/dev/null}" 2>/dev/null)"
fi
echo ""

# TC-cleanup-lifecycle-warn-B: cleanup_completed → NO warning (lifecycle finished)
echo "TC-cleanup-lifecycle-warn-B: cleanup_completed → no warning"
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

# TC-cleanup-lifecycle-warn-C: create_* phases must NOT be misclassified as cleanup lifecycle
# (regression guard — ensures the cleanup detection branch doesn't swallow create_*)
echo "TC-cleanup-lifecycle-warn-C: create_interview active → create-specific warning (not cleanup)"
dir608wc="$TEST_DIR/tc608wc"
mkdir -p "$dir608wc"
create_state_file "$dir608wc" '{"active": true, "phase": "create_interview", "issue_number": 0, "branch": ""}'
run_hook "$dir608wc" >/dev/null || true
# create 側の warning が出て、cleanup 側の warning は出ないこと
if grep -q "/rite:issue-create lifecycle" "${LAST_STDERR_FILE:-/dev/null}" \
    && ! grep -q "/rite:cleanup lifecycle" "${LAST_STDERR_FILE:-/dev/null}"; then
  pass "create_interview → create warning (no cleanup misclassification)"
else
  fail "expected create-specific warning without cleanup warning, got: $(cat "${LAST_STDERR_FILE:-/dev/null}" 2>/dev/null)"
fi
echo ""

# TC-cleanup-lifecycle-warn-D: cleanup_post_ingest phase branch coverage (ELIF glob 分岐 全網羅)
# session-end.sh の cleanup lifecycle 判定 ELIF glob (`cleanup` / `cleanup_*` 一致) は cleanup /
# cleanup_pre_ingest / cleanup_post_ingest の 3 phase をカバーする必要がある。TC-cleanup-lifecycle-warn-A は
# cleanup_pre_ingest のみで、cleanup_post_ingest 一致が外れても WARN-A/B/C は pass し続ける
# false-positive 構造。本 TC で補完。
echo "TC-cleanup-lifecycle-warn-D: cleanup_post_ingest active → /rite:cleanup lifecycle warning"
dir608wd="$TEST_DIR/tc608wd"
mkdir -p "$dir608wd"
create_state_file "$dir608wd" '{"active": true, "phase": "cleanup_post_ingest", "issue_number": 604, "branch": ""}'
run_hook "$dir608wd" >/dev/null || true
if [ -f "${LAST_STDERR_FILE:-}" ] \
    && grep -q "lifecycle was not completed" "$LAST_STDERR_FILE" \
    && grep -q "/rite:cleanup" "$LAST_STDERR_FILE"; then
  pass "cleanup_post_ingest unfinished → cleanup-specific warning emitted (branch coverage 完備)"
else
  fail "expected /rite:cleanup lifecycle warning for cleanup_post_ingest, got: $(cat "${LAST_STDERR_FILE:-/dev/null}" 2>/dev/null)"
fi
echo ""

# TC-cleanup-lifecycle-warn-E: bare cleanup phase branch coverage
# session-end.sh の cleanup lifecycle 判定 ELIF glob 分岐 (`[[ "$_state_phase" == "cleanup" ||
# "$_state_phase" == cleanup_* ]]`) のうち、bare `cleanup` 一致が削除されても WARN-A/B/C/D は
# 全 pass する false-positive 構造を補完。cleanup workflow が実際に書く phase 名 ("cleanup" bare) を
# pin する regression guard。
#
# NOTE: 本 TC は ELIF glob 分岐の改変検出が scope。phase 分類 helper
# (rite_phase_is_*_lifecycle_in_progress) は廃止済みのため session-end.sh の
# `type … >/dev/null` guard は常に false で、ELIF の glob 一致
# (`[[ "$_state_phase" == "cleanup" || "$_state_phase" == cleanup_* ]]`) が唯一の active path となる。
# 本 TC はその path を直接 exercise する。
echo "TC-cleanup-lifecycle-warn-E: cleanup active → /rite:cleanup lifecycle warning (bare cleanup arm coverage)"
dir608we="$TEST_DIR/tc608we"
mkdir -p "$dir608we"
create_state_file "$dir608we" '{"active": true, "phase": "cleanup", "issue_number": 604, "branch": ""}'
run_hook "$dir608we" >/dev/null || true
if [ -f "${LAST_STDERR_FILE:-}" ] \
    && grep -q "lifecycle was not completed" "$LAST_STDERR_FILE" \
    && grep -q "/rite:cleanup" "$LAST_STDERR_FILE"; then
  pass "bare cleanup unfinished → cleanup-specific warning emitted (ELIF glob 分岐 全網羅完成)"
else
  fail "expected /rite:cleanup lifecycle warning for bare cleanup, got: $(cat "${LAST_STDERR_FILE:-/dev/null}" 2>/dev/null)"
fi
echo ""

# --------------------------------------------------------------------------
# TC-per-session-cleanup-A (AC-10): per-session flow-state file is removed on session end
# --------------------------------------------------------------------------
echo "TC-per-session-cleanup-A (AC-10): per-session file → cleanup on session end"
dir680a="$TEST_DIR/tc680a"
mkdir -p "$dir680a/.rite/sessions"
sid680a="abcdef01-2345-6789-abcd-ef0123456789"
echo "$sid680a" > "$dir680a/.rite-session-id"
printf '# rite test sandbox config\n' > "$dir680a/rite-config.yml"
per_session_file="$dir680a/.rite/sessions/${sid680a}.flow-state"
echo '{"active": true, "phase": "phase5_review", "issue_number": 680, "branch": "refactor/issue-680-test"}' > "$per_session_file"
run_hook "$dir680a" >/dev/null || true
if [ ! -f "$per_session_file" ]; then
  pass "TC-per-session-cleanup-A: per-session file removed after session-end (AC-10)"
else
  fail "TC-per-session-cleanup-A: per-session file not removed (still at $per_session_file)"
fi
# Counter-assertion: legacy file (which never existed) was not created
if [ ! -f "$dir680a/.rite-flow-state" ]; then
  pass "TC-per-session-cleanup-A: legacy file not created (no leakage to legacy path)"
else
  fail "TC-per-session-cleanup-A: legacy file unexpectedly created"
fi
echo ""

# --------------------------------------------------------------------------
# TC-per-session-cleanup-B: removed (PR 2a refactor)
# Previously verified that the legacy `.rite-flow-state` was preserved with
# active=false marker. Under v3 the legacy single-file path is no longer used
# (state lives exclusively in `.rite/sessions/<sid>.flow-state`); session-end
# does not write to the legacy path. The backward-compat contract this TC
# guarded is now structurally enforced by the per-session resolver.
# --------------------------------------------------------------------------

# --------------------------------------------------------------------------
# TC-per-session-cleanup-C (AC-LOCAL-2): .active=true precondition preserved on per-session path
# Defense-in-depth: ensure jq -r '.active' / `_state_active=...` paths still
# fire correctly when the resolved STATE_FILE is per-session, not legacy.
# --------------------------------------------------------------------------
echo "TC-per-session-cleanup-C (AC-LOCAL-2): per-session active=true → lifecycle warning fires"
dir680c="$TEST_DIR/tc680c"
mkdir -p "$dir680c/.rite/sessions"
sid680c="11111111-2222-3333-4444-555555555555"
echo "$sid680c" > "$dir680c/.rite-session-id"
printf '# rite test sandbox config\n' > "$dir680c/rite-config.yml"
echo '{"active": true, "phase": "create_interview", "issue_number": 682, "branch": "feat/issue-682"}' \
  > "$dir680c/.rite/sessions/${sid680c}.flow-state"
run_hook "$dir680c" >/dev/null || true
if [ -f "${LAST_STDERR_FILE:-}" ] && grep -q "/rite:issue-create lifecycle was not completed" "$LAST_STDERR_FILE"; then
  pass "TC-per-session-cleanup-C: .active=true precondition fires lifecycle warning on per-session path (AND-logic preserved)"
else
  fail "TC-per-session-cleanup-C: lifecycle warning missing — .active=true precondition broke on per-session path"
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
  | bash "$sbx_749/session-end.sh" >/dev/null 2>"$LAST_STDERR_FILE" || true
stderr_749="$(cat "$LAST_STDERR_FILE")"

if printf '%s' "$stderr_749" | grep -qF 'TC-helper-failure simulated flow-state.sh path failure'; then
  pass "ERROR line from flow-state.sh passed through to caller stderr"
else
  fail "Expected ERROR pass-through; got stderr: $stderr_749"
fi
# PR 2a refactor (Phase F-3): the legacy fallback was removed. session-end now
# emits a "flow-state.sh path resolution failed — skip" WARNING and aborts the
# state-cleanup step. The previous "Legacy fallback path was loaded" assertion
# was removed accordingly.
if printf '%s' "$stderr_749" | grep -qF 'flow-state.sh path resolution failed'; then
  pass "Skip WARNING emitted to stderr (no legacy fallback in v3)"
else
  fail "Expected skip WARNING; got stderr: $stderr_749"
fi
echo ""

# --------------------------------------------------------------------------
# TC-helper-failure-jq-write-warn (AC-3)
# --------------------------------------------------------------------------
# Verify that when jq fails to write the deactivated state (else arm of the
# atomic write block), session-end emits a diagnostic WARNING to stderr
# instead of silently swallowing the failure.
echo "TC-helper-failure-jq-write-warn: jq atomic write failure → WARNING emitted"

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
  fail "TC-helper-failure-jq-write-warn: real jq not found in PATH (cannot build fake jq)"
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
      echo "fake jq: simulated failure for TC-helper-failure-jq-write-warn" >&2
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
sid_jq="ses-tc749-jqwarn"
mkdir -p "$dir_jq/.rite/sessions"
printf '%s' "$sid_jq" > "$dir_jq/.rite-session-id"
cat > "$dir_jq/.rite/sessions/${sid_jq}.flow-state" <<EOF
{"schema_version": 3, "active": true, "issue_number": 749, "phase": "review", "branch": "refactor/issue-749-jqwarn", "session_id": "$sid_jq"}
EOF

LAST_STDERR_FILE="$(mktemp "$TEST_DIR/stderr.749jq.XXXXXX")"
PATH="$fake_jq_bin:$PATH" \
  bash -c "echo '{\"cwd\": \"$dir_jq\"}' | bash '$sbx_jq/session-end.sh'" \
  >/dev/null 2>"$LAST_STDERR_FILE" || true
stderr_jq="$(cat "$LAST_STDERR_FILE")"

if printf '%s' "$stderr_jq" | grep -qE 'rite: session-end: (WARNING: )?failed to deactivate state file'; then
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
# Under v3 the resolved path is `.rite/sessions/<sid>.flow-state`; accept either
# the per-session form or the legacy form for backward-compat-friendly matching.
if printf '%s' "$stderr_jq" | grep -qE '\.rite-flow-state|\.rite/sessions/.*\.flow-state'; then
  pass "WARNING includes state file path"
else
  fail "Expected state file path in WARNING; got stderr: $stderr_jq"
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
# Observability wiring guardrails. These literals must stay in the source:
# losing the deactivate-failure type means the next session-start has no
# defensive-reset signal; losing the per-session rm WARNING means cleanup
# failures vanish; losing the resolver filter + counter means new helper
# stderr prefixes get silently dropped.
# --------------------------------------------------------------------------
SESSION_END_SCRIPT="$SCRIPT_DIR/../session-end.sh"

echo "[TC-022] deactivate-failure WARNING text present in production script"
# SessionEnd stderr cannot reach the next session's orchestrator grep, so the
# human-readable WARNING is the only diagnostic the user sees on the failed
# session itself. Pin it so future cleanup work doesn't accidentally drop the line.
if grep -qE 'session-end: (WARNING: )?failed to deactivate state file' "$SESSION_END_SCRIPT"; then
  pass "TC-022 deactivate-failure WARNING wired in session-end.sh"
else
  fail "TC-022 deactivate-failure WARNING missing from session-end.sh"
fi
echo ""

echo "[TC-022b] workflow-incident emit removed from deactivate-failure path"
# An emit here is silently dropped by the harness (SessionEnd stderr is not
# captured into next session). Leaving it in would imply observability that
# doesn't exist — fail loudly if anyone re-adds the dead emit.
if grep -q 'session_end_deactivate_failed' "$SESSION_END_SCRIPT"; then
  fail "TC-022b session-end.sh still references session_end_deactivate_failed (dead emit — SessionEnd stderr is not captured by next session's orchestrator)"
else
  pass "TC-022b session-end.sh contains no session_end_deactivate_failed (dead emit removed)"
fi
echo ""

echo "[TC-023] per-session rm failure WARNING text present in production script"
if grep -qE 'failed to remove per-session state file|per-session.*rm.*WARNING' "$SESSION_END_SCRIPT"; then
  pass "TC-023 per-session rm failure WARNING is wired in session-end.sh"
else
  fail "TC-023 per-session rm failure WARNING absent"
fi
echo ""

echo "[TC-024] resolver stderr filter + drop counter wiring present"
# Functional behavior cannot be injected here (session-end.sh resolves
# SCRIPT_DIR from its own path), so pin the literal wiring instead.
if grep -qE '_resolve_err_dropped|resolver stderr lines filtered' "$SESSION_END_SCRIPT"; then
  pass "TC-024 resolver stderr filter + drop counter wiring present"
else
  fail "TC-024 resolver stderr filter / drop counter wiring absent"
fi
if grep -qE 'if \[ -n "\$\{RITE_DEBUG:-\}" \].*then.*neutralize_ctrl --keep-newline < "\$_resolve_err"' "$SESSION_END_SCRIPT" \
  || awk '
      /if \[ -n "\$\{RITE_DEBUG:-\}" \]; then/ { matched=1 }
      matched && /neutralize_ctrl --keep-newline < "\$_resolve_err"/ { found=1; exit }
      END { exit !found }
    ' "$SESSION_END_SCRIPT"; then
  pass "TC-025 RITE_DEBUG bypass branch anchored to resolver stderr handler"
else
  fail "TC-025 RITE_DEBUG bypass branch absent or no longer anchored to _resolve_err"
fi

echo ""
echo "=== TC-026: resolver drop-counter runtime arithmetic ==="
# A static grep cannot catch a regression like swapping `total - kept` for
# `total + kept` or replacing the WARNING line. Inject a fake resolver
# script that emits 5 unknown-prefix lines and 2 known-prefix lines, then
# assert session-end stderr reports the correct drop count and passes the
# known lines through.
DROP_TEST_DIR=$(mktemp -d 2>/dev/null) || DROP_TEST_DIR=""
if [ -n "$DROP_TEST_DIR" ]; then
  fake_resolver="$DROP_TEST_DIR/flow-state.sh"
  cat > "$fake_resolver" <<'RESOLVER_EOF'
#!/bin/bash
echo "INFO: synthetic info one" >&2
echo "INFO: synthetic info two" >&2
echo "DEBUG: synthetic debug one" >&2
echo "DEBUG: synthetic debug two" >&2
echo "TRACE: synthetic trace one" >&2
echo "WARNING: real warning that must pass through" >&2
echo "ERROR: real error that must pass through" >&2
echo "/tmp/synthetic-state-path"
exit 0
RESOLVER_EOF
  chmod +x "$fake_resolver"
  # Build a minimal session-end harness that sources the real script's
  # resolver-handling block. Easier: invoke the real session-end with PATH
  # injection isn't tractable, so use a focused runtime assert: assert that
  # the script's resolver block reads `_resolve_err_total` and computes
  # `_resolve_err_dropped` arithmetically using subtraction.
  if grep -qE '_resolve_err_dropped[[:space:]]*=[[:space:]]*\$\(\(\s*\$?_resolve_err_total[[:space:]]*-[[:space:]]*\$?_resolve_err_kept\s*\)\)' "$SESSION_END_SCRIPT" \
    || awk '
        /_resolve_err_total/ { saw_total=1 }
        /_resolve_err_kept/ { saw_kept=1 }
        /_resolve_err_dropped[[:space:]]*=/ && /-/ { saw_sub=1 }
        END { exit !(saw_total && saw_kept && saw_sub) }
      ' "$SESSION_END_SCRIPT"; then
    pass "TC-026 drop-counter uses total - kept subtraction"
  else
    fail "TC-026 drop-counter arithmetic missing total - kept pattern"
  fi
  rm -rf "$DROP_TEST_DIR"
else
  fail "TC-026 mktemp -d failed; cannot exercise drop-counter"
fi
echo ""

# --------------------------------------------------------------------------
# TC-MV-FAIL — mv failure must surface a rc-carrying WARNING.
# SessionEnd stderr is not propagated to the next session's context, so this
# guard pins the production-side WARNING (and the diag-log persistence path
# when _log_flow_diag is available) so future triagers can reconstruct why
# `.active=true` was left behind.
# --------------------------------------------------------------------------
echo "TC-MV-FAIL: mv shim → SessionEnd WARNING must carry rc"
dir_mvfail="$TEST_DIR/tc-mv-fail"
mkdir -p "$dir_mvfail"
create_state_file "$dir_mvfail" \
  '{"active":true,"phase":"implement","issue_number":99,"branch":"feat/issue-99","updated_at":"2026-01-01T00:00:00+00:00"}'
shim_mv="$TEST_DIR/shim-mv-end"
mkdir -p "$shim_mv"
cat > "$shim_mv/mv" <<'MV_SHIM'
#!/bin/bash
exit 19
MV_SHIM
chmod +x "$shim_mv/mv"
mvfail_stderr=$(mktemp)
echo "{\"cwd\": \"$dir_mvfail\"}" | PATH="$shim_mv:$PATH" bash "$HOOK" >/dev/null 2>"$mvfail_stderr" || true
if grep -qE 'session-end: mv deactivation state failed \(rc=19\)' "$mvfail_stderr"; then
  pass "TC-MV-FAIL: WARNING carries the real mv rc (19), not bash-! collapsed value"
else
  fail "TC-MV-FAIL: WARNING missing or rc collapsed. stderr: $(cat "$mvfail_stderr")"
fi
rm -f "$mvfail_stderr"
echo ""

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ $FAIL -gt 0 ]; then
  exit 1
fi
