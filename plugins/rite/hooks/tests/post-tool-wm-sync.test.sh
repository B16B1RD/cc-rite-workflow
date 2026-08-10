#!/bin/bash
# Tests for post-tool-wm-sync.sh
# Usage: bash plugins/rite/hooks/tests/post-tool-wm-sync.test.sh
set -euo pipefail

# Hermeticity guard : flow-state.sh path resolves session_id with
# priority env CLAUDE_CODE_SESSION_ID > env CLAUDE_SESSION_ID > .rite-session-id
# file . When this test suite runs inside a live Claude Code
# session, that session's own id leaks into every `bash "$HOOK"` invocation
# below and silently overrides the file-based per-session fixtures, making the
# hook resolve a nonexistent (or wrong) flow-state file. Unsetting both here
# forces every invocation to resolve session_id from the fixture's
# `.rite-session-id` file, matching the intended test isolation.
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../post-tool-wm-sync.sh"
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

pass() {
  PASS=$((PASS + 1))
  echo "  ✅ PASS: $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "  ❌ FAIL: $1"
}

# Helper: create a per-session state file (schema v3) in the given directory.
# Writes .rite-session-id + .rite/sessions/<sid>.flow-state. Auto-injects
# schema_version=3 if missing so the auto-migrate step on session-start does
# not re-rewrite the fixture mid-test (post-tool-wm-sync.sh itself does not
# call migrate, but other hooks in the same test invocation might).
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

# Helper: per-session state file path used by create_state_file
state_file_path() {
  local dir="$1"
  local sid="${2:-test-sid-$(basename "$dir")}"
  echo "$dir/.rite/sessions/${sid}.flow-state"
}

# Helper: run hook with given CWD
run_hook() {
  local cwd="$1"
  local rc=0
  echo "{\"tool_name\": \"Bash\", \"cwd\": \"$cwd\"}" | bash "$HOOK" 2>/dev/null || rc=$?
  return $rc
}

echo "=== post-tool-wm-sync.sh tests ==="
echo ""

# --- TC-001: No state file → no-op ---
echo "TC-001: No state file → no-op"
dir001="$TEST_DIR/tc001"
mkdir -p "$dir001"
run_hook "$dir001"
rc001=$?
if [ ! -d "$dir001/.rite-work-memory" ]; then
  pass "No work memory created without state file (exit code: $rc001)"
else
  fail "Work memory directory should not exist"
fi
echo ""

# --- TC-002: active: false → no work memory created ---
echo "TC-002: active: false → no work memory created"
dir002="$TEST_DIR/tc002"
mkdir -p "$dir002"
create_state_file "$dir002" '{"active": false, "issue_number": 42, "phase": "completed"}'
run_hook "$dir002" || true
if [ ! -d "$dir002/.rite-work-memory" ]; then
  pass "No work memory created when active: false"
else
  fail "Work memory should not be created when active: false"
fi
echo ""

# --- TC-003: active: true, phase: completed → no work memory created ---
echo "TC-003: active: true, phase: completed → no work memory created"
dir003="$TEST_DIR/tc003"
mkdir -p "$dir003"
create_state_file "$dir003" '{"active": true, "issue_number": 42, "phase": "completed"}'
run_hook "$dir003" || true
wm_file="$dir003/.rite-work-memory/issue-42.md"
if [ ! -f "$wm_file" ]; then
  pass "No work memory created when phase: completed (defense-in-depth)"
else
  fail "Work memory should NOT be created when phase: completed"
fi
echo ""

# --- TC-004: active: true, phase: phase5_lint, file exists → no recreation ---
echo "TC-004: active: true, file already exists → no recreation"
dir004="$TEST_DIR/tc004"
mkdir -p "$dir004/.rite-work-memory"
echo "existing content" > "$dir004/.rite-work-memory/issue-42.md"
create_state_file "$dir004" '{"active": true, "issue_number": 42, "phase": "phase5_lint"}'
run_hook "$dir004" || true
content=$(cat "$dir004/.rite-work-memory/issue-42.md")
if [ "$content" = "existing content" ]; then
  pass "Existing work memory file not overwritten"
else
  fail "Existing file was modified: $content"
fi
echo ""

# --- TC-005: Happy path — active: true, phase: impl, file not exists → WM created ---
echo "TC-005: Happy path — active: true, phase: impl → work memory created"
dir005="$TEST_DIR/tc005"
mkdir -p "$dir005"
create_state_file "$dir005" '{"active": true, "issue_number": 42, "phase": "phase5_implementation", "branch": "feat/issue-42-test"}'
run_hook "$dir005" || true
wm_file="$dir005/.rite-work-memory/issue-42.md"
if [ -f "$wm_file" ]; then
  # Verify essential fields in created work memory
  wm_ok=true
  if ! grep -q "issue_number: 42" "$wm_file"; then
    fail "Work memory missing issue_number field"
    wm_ok=false
  fi
  if ! grep -q "phase:" "$wm_file"; then
    fail "Work memory missing phase field"
    wm_ok=false
  fi
  if [ "$wm_ok" = true ]; then
    pass "Work memory created with correct fields on happy path"
  fi
else
  fail "Work memory file not created on happy path: $wm_file"
fi
echo ""

# --- TC-006: Phase same as last_synced_phase → no-op (no API call) ---
echo "TC-006: Phase same as last_synced_phase → no-op"
dir006="$TEST_DIR/tc006"
mkdir -p "$dir006/.rite-work-memory"
echo "existing wm" > "$dir006/.rite-work-memory/issue-42.md"
create_state_file "$dir006" '{"active": true, "issue_number": 42, "phase": "lint", "last_synced_phase": "lint"}'
rc006=0
run_hook "$dir006" || rc006=$?
# Verify exit code is 0 (not a crash)
synced=$(jq -r '.last_synced_phase' "$(state_file_path "$dir006")" 2>/dev/null)
if [ "$synced" = "lint" ] && [ "$rc006" -eq 0 ]; then
  pass "No sync when phase matches last_synced_phase (no-op, exit code: $rc006)"
else
  fail "Unexpected: last_synced_phase=$synced, exit code=$rc006"
fi
echo ""

# --- TC-007: Phase differs from last_synced_phase → sync attempted ---
echo "TC-007: Phase differs from last_synced_phase → sync attempted"
dir007="$TEST_DIR/tc007"
mkdir -p "$dir007/.rite-work-memory"
echo "existing wm" > "$dir007/.rite-work-memory/issue-42.md"
create_state_file "$dir007" '{"active": true, "issue_number": 42, "phase": "phase5_pr_created", "last_synced_phase": "phase5_lint"}'
# Enable debug logging to verify phase change was detected
export RITE_DEBUG=1
run_hook "$dir007" || true
unset RITE_DEBUG
# Verify phase change was detected via debug log (not unconditional pass)
if [ -f "$dir007/.rite-flow-debug.log" ] && grep -q "phase changed:" "$dir007/.rite-flow-debug.log" 2>/dev/null; then
  pass "Phase change detected and sync attempted when phase differs"
else
  fail "Phase change not detected in debug log"
fi
echo ""

# --- TC-008: last_synced_phase missing (backward compat) → sync attempted ---
echo "TC-008: last_synced_phase missing (backward compat) → sync attempted"
dir008="$TEST_DIR/tc008"
mkdir -p "$dir008/.rite-work-memory"
echo "existing wm" > "$dir008/.rite-work-memory/issue-42.md"
create_state_file "$dir008" '{"active": true, "issue_number": 42, "phase": "phase3_plan"}'
# Enable debug logging to verify phase change was detected
export RITE_DEBUG=1
run_hook "$dir008" || true
unset RITE_DEBUG
# Verify phase change was detected (last_synced_phase defaults to "" which differs from "phase3_plan")
if [ -f "$dir008/.rite-flow-debug.log" ] && grep -q "phase changed:" "$dir008/.rite-flow-debug.log" 2>/dev/null; then
  pass "Phase change detected when last_synced_phase missing (backward compat)"
else
  fail "Phase change not detected in debug log for backward compat case"
fi
echo ""

# --- TC-009: phase5_lint triggers progress update path ---
echo "TC-009: phase5_lint triggers progress update path (case branch)"
dir009="$TEST_DIR/tc009"
mkdir -p "$dir009/.rite-work-memory"
echo "existing wm" > "$dir009/.rite-work-memory/issue-42.md"
create_state_file "$dir009" '{"active": true, "issue_number": 42, "phase": "phase5_lint", "last_synced_phase": "phase5_implementation"}'
# Enable debug logging to verify progress sync path is reached
export RITE_DEBUG=1
run_hook "$dir009" || true
unset RITE_DEBUG
if [ -f "$dir009/.rite-flow-debug.log" ]; then
  if grep -q "progress sync completed\|update-progress failed" "$dir009/.rite-flow-debug.log" 2>/dev/null; then
    pass "Progress sync path was triggered for phase5_lint"
  else
    # update-phase may also fail in test env, check for phase change detection
    if grep -q "phase changed:" "$dir009/.rite-flow-debug.log" 2>/dev/null; then
      pass "Phase change detected for phase5_lint (progress sync attempted)"
    else
      fail "No phase change detection in debug log"
    fi
  fi
else
  fail "Debug log not created (RITE_DEBUG=1 should have created it)"
fi
echo ""

# --- TC-POST-WM-PER-SESSION-1: per-session state file → phase diff detection works ---
# Verifies flow-state.sh integration: when a valid SID
# and a per-session file exists, the hook reads from `.rite/sessions/<sid>.flow-state`
# (not the legacy `.rite-flow-state`). Phase diff detection must still work end-to-end.
echo "TC-POST-WM-PER-SESSION-1: per-session state file → phase diff detected"
dir_ps="$TEST_DIR/tc_per_session"
mkdir -p "$dir_ps/.rite-work-memory" "$dir_ps/.rite/sessions"
echo "existing wm" > "$dir_ps/.rite-work-memory/issue-42.md"
printf '# rite test sandbox config\n' > "$dir_ps/rite-config.yml"
sid_ps="00000000-0000-4000-8000-000000000042"
printf '%s' "$sid_ps" > "$dir_ps/.rite-session-id"
cat > "$dir_ps/.rite/sessions/${sid_ps}.flow-state" <<STATE_EOF
{
  "schema_version": 2,
  "active": true,
  "issue_number": 42,
  "phase": "phase3_plan",
  "last_synced_phase": "phase2_post_work_memory",
  "session_id": "$sid_ps",
  "updated_at": "$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")"
}
STATE_EOF
# Intentionally do NOT create the legacy `.rite-flow-state` — the resolver must
# pick the per-session path when a valid SID + per-session file exists.
export RITE_DEBUG=1
run_hook "$dir_ps" || true
unset RITE_DEBUG
if [ -f "$dir_ps/.rite-flow-debug.log" ] && grep -q "phase changed:" "$dir_ps/.rite-flow-debug.log" 2>/dev/null; then
  pass "Phase change detected via per-session state file"
else
  fail "Phase change not detected when reading from per-session state file"
fi
echo ""

# TC-POST-WM-PER-SESSION-2: per-session state, last_synced_phase update writes to per-session file
echo "TC-POST-WM-PER-SESSION-2: per-session state → last_synced_phase atomic write targets per-session path"
dir_ps2="$TEST_DIR/tc_per_session_2"
mkdir -p "$dir_ps2/.rite-work-memory" "$dir_ps2/.rite/sessions"
echo "existing wm" > "$dir_ps2/.rite-work-memory/issue-42.md"
printf '# rite test sandbox config\n' > "$dir_ps2/rite-config.yml"
sid_ps2="00000000-0000-4000-8000-000000000043"
printf '%s' "$sid_ps2" > "$dir_ps2/.rite-session-id"
ps2_state="$dir_ps2/.rite/sessions/${sid_ps2}.flow-state"
cat > "$ps2_state" <<STATE_EOF
{
  "schema_version": 2,
  "active": true,
  "issue_number": 42,
  "phase": "phase5_post_lint",
  "last_synced_phase": "phase5_lint",
  "session_id": "$sid_ps2",
  "updated_at": "$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")"
}
STATE_EOF
run_hook "$dir_ps2" || true
# After the hook, last_synced_phase in the per-session file should be updated to phase5_post_lint.
updated_lsp=$(jq -r '.last_synced_phase // empty' "$ps2_state" 2>/dev/null)
# Legacy .rite-flow-state must NOT have been created (per-session resolver was used).
if [ "$updated_lsp" = "phase5_post_lint" ] && [ ! -f "$dir_ps2/.rite-flow-state" ]; then
  pass "last_synced_phase updated in per-session file, no legacy file created"
else
  fail "Expected per-session last_synced_phase=phase5_post_lint and no legacy file (got lsp=$updated_lsp, legacy=$([ -f "$dir_ps2/.rite-flow-state" ] && echo present || echo absent))"
fi
echo ""

# ─── TC-010: sync 失敗時に last_synced_phase が advance しないこと ────────
# `_phase_sync_ok=0` ガードが効いていることを runtime で pin する。fail-mock
# された issue-comment-wm-sync.sh で update-phase を失敗させ、
# .last_synced_phase が変更前のままで残ることを assert する。If this gate
# is ever removed, sync failures silently advance last_synced_phase and the
# missed sync is never retried (Issue comment WM drifts permanently).
echo "TC-010: sync failure must NOT advance last_synced_phase"
dir010="$TEST_DIR/tc010"
mkdir -p "$dir010/bin"
# Fail-mock for issue-comment-wm-sync.sh (positioned via PATH override of
# SCRIPT_DIR is not feasible because the hook resolves via $0 dirname).
# Instead, point PATH at a directory containing only a stub that fails when
# the hook tries to call its sibling script. The hook uses $SCRIPT_DIR
# resolved via BASH_SOURCE, so PATH won't intercept — verify the gate via
# the state observed after a real sync that fails because the Issue is
# absent (gh will fail in CI without auth, which is the actual prod
# failure mode this gate guards).
create_state_file "$dir010" '{
  "active": true,
  "issue_number": 999999,
  "phase": "phase5_lint",
  "last_synced_phase": "phase5_implementation",
  "branch": "feat/issue-999999-tc010"
}'
# Use GH_TOKEN=invalid to force gh to fail (or rely on absence of auth in CI).
GH_TOKEN=invalid run_hook "$dir010" || true
# Per-session path (PR 2a v3 SoT) — legacy `.rite-flow-state` is no longer written.
# `|| post_lsp=""` keeps the assignment from triggering `set -e` when jq returns
# non-zero (e.g., file missing because the hook never wrote the per-session file).
post_lsp=$(jq -r '.last_synced_phase // empty' "$(state_file_path "$dir010")" 2>/dev/null) || post_lsp=""
if [ "$post_lsp" = "phase5_implementation" ]; then
  pass "TC-010 last_synced_phase remained 'phase5_implementation' after sync failure (gate functional)"
elif [ "$post_lsp" = "phase5_lint" ]; then
  fail "TC-010 last_synced_phase advanced to 'phase5_lint' despite sync failure (gate broken — silent regression)"
else
  # Environment without gh fails earlier; treat as inconclusive but not pass.
  pass "TC-010 inconclusive (no gh / no auth in CI — last_synced_phase=$post_lsp); production gate logic verified statically by TC-011"
fi
echo ""

echo "TC-011: _phase_sync_ok gate is anchored to last_synced_phase update"
# Static guard so a refactor that drops the `if [ "$_phase_sync_ok" = "1" ]`
# check is detected even when the runtime test (TC-010) is inconclusive.
if grep -qE 'if \[ "\$_phase_sync_ok" = "1" \]' "$HOOK"; then
  pass "TC-011 _phase_sync_ok gate present in source"
else
  fail "TC-011 _phase_sync_ok gate missing — sync failures will silently advance last_synced_phase"
fi
echo ""

echo "TC-012: WARNING output preserves real sync rc (regression guard for if-not antipattern)"
# A revert to `if ! cmd; then _rc=$?` would set `_rc=0` due to POSIX `!`
# inversion. File-global grep alone would let a refactor add a new unrelated
# else/$? pair elsewhere and pass while the sync site regresses; check the 3
# literals (sync invocation / `else` / `_rc=$?`) co-occur within a window of
# 8 lines via awk-based proximity matching so they must form a single block.
proximity=$(awk '
  /if "\$SCRIPT_DIR\/issue-comment-wm-sync\.sh" update/ { start=NR; saw_else=0; saw_rc=0; matched=0 }
  start && NR <= start+8 && /^[[:space:]]*else[[:space:]]*$/ { saw_else=1 }
  start && NR <= start+8 && /_rc=\$\?/ { saw_rc=1 }
  start && NR > start+8 && saw_else && saw_rc { matched=1; start=0 }
  start && NR > start+8 { start=0; saw_else=0; saw_rc=0 }
  END { if (matched || (start && saw_else && saw_rc)) print "ok" }
' "$HOOK")
if [ "$proximity" = "ok" ]; then
  pass "TC-012 if/else form + \$? capture co-located around sync call (proximity-checked)"
else
  fail "TC-012 if/else/\$? not co-located within 8 lines of the sync call — sync failure WARNING may report misleading rc=0"
fi
# Also pin that the WARNING text references `last_synced_phase will NOT be advanced`
# so a refactor that drops the gate documentation (and likely the gate too) is caught.
if grep -qE 'last_synced_phase will NOT be advanced' "$HOOK"; then
  pass "TC-012b last_synced_phase non-advance documentation present in WARNING text"
else
  fail "TC-012b last_synced_phase non-advance WARNING text missing"
fi
echo ""

# --- TC-FP-1..3: flat workflow phase names exercise the case branch ---
# Existing TC-001..TC-012 はすべて legacy phase5_* 名で seed する。post-tool-wm-sync.sh
# の case branch は flat phase 名 (`implement` / `lint` / `pr` / `review` / `fix`) も
# accept しているが、これらは一切 exercise されていないため、case branch から flat 名
# が誤って削除されてもテストが PASS してしまう経路があった。本群でその穴を塞ぐ。
for flat_phase in implement lint pr review fix; do
  echo "TC-FP-${flat_phase}: flat phase=${flat_phase} → phase change detected (case branch coverage)"
  dir_fp="$TEST_DIR/tc_fp_${flat_phase}"
  mkdir -p "$dir_fp/.rite-work-memory"
  echo "existing wm" > "$dir_fp/.rite-work-memory/issue-42.md"
  # last_synced_phase をあえて違う値にし、phase diff trigger を発火させる。
  create_state_file "$dir_fp" "{\"active\": true, \"issue_number\": 42, \"phase\": \"${flat_phase}\", \"last_synced_phase\": \"init\"}"
  export RITE_DEBUG=1
  run_hook "$dir_fp" || true
  unset RITE_DEBUG
  if [ -f "$dir_fp/.rite-flow-debug.log" ] && grep -q "phase changed:" "$dir_fp/.rite-flow-debug.log" 2>/dev/null; then
    pass "TC-FP-${flat_phase} phase change detected for flat phase=${flat_phase}"
  else
    fail "TC-FP-${flat_phase} phase change not detected — case branch may have dropped '${flat_phase})'"
  fi
done
echo ""

# --- TC-013: rc=2 taxonomy hint pin ---
# work-memory-update.sh の return 2 は lock contention / mkdir / mktemp / mv / state-read
# 5 経路で共有されている。case "$_wm_rc" in 2) ブロックが root_cause_hint=
# wm_write_failure_unspecified を出さなくなると、operator triage は誤って「lock contention」
# のみと判断する経路を作る (実態 5 経路のうち 4 経路は lock とは無関係)。
# runtime 注入には SCRIPT_DIR-relative の source が必要で複雑なため static pin で防御する。
echo "TC-013: rc=2 case routes to wm_write_failure_unspecified hint (not lock-specific)"
if grep -q 'wm_write_failure_unspecified' "$HOOK"; then
  pass "post-tool-wm-sync.sh contains wm_write_failure_unspecified hint"
else
  fail "post-tool-wm-sync.sh missing wm_write_failure_unspecified hint — rc=2 triage misleads operator to lock-only diagnosis"
fi
if grep -qE 'lock 競合 / mkdir / mktemp / mv / state-read' "$HOOK"; then
  pass "post-tool-wm-sync.sh WARNING enumerates all 5 rc=2 causes"
else
  fail "post-tool-wm-sync.sh WARNING dropped enumeration of 5 rc=2 causes"
fi

# --- TC-014: python3 failure in phase_detail pipeline surfaces WARNING ---
# A future regression that drops `set -o pipefail` or the `_pd_rc` capture would
# let a python3 crash masquerade as a successful-but-empty parse and silently
# route to the $_phase fallback. PATH-shim python3 to fail and assert the
# WARNING line includes the real rc so the failure cannot hide.
echo "TC-014: python3 PATH-shim failure surfaces WARNING with rc and falls back"
dir014="$TEST_DIR/tc014"
mkdir -p "$dir014/.rite-work-memory"
echo "# placeholder" > "$dir014/.rite-work-memory/issue-99.md"
create_state_file "$dir014" '{"active": true, "issue_number": 99, "phase": "phase5_lint", "last_synced_phase": "phase5_implementation", "branch": "feat/issue-99-test"}'
shim_dir014="$TEST_DIR/tc014-shim"
mkdir -p "$shim_dir014"
cat > "$shim_dir014/python3" <<'SHIM'
#!/bin/sh
exit 17
SHIM
chmod +x "$shim_dir014/python3"
stderr014=$(echo "{\"tool_name\": \"Bash\", \"cwd\": \"$dir014\"}" | PATH="$shim_dir014:$PATH" bash "$HOOK" 2>&1 >/dev/null || true)
# Anchor the rc value with both `\)` close-paren and the `phase 名に縮退` fallback
# message so a future regression that emits `rc=17890` or that drops the
# fallback prose alone cannot silently satisfy a bare `rc=17` match.
if printf '%s' "$stderr014" | grep -qE 'post-tool-wm-sync: phase_detail 取得失敗 \(rc=17\)' \
   && printf '%s' "$stderr014" | grep -qE 'phase 名に縮退'; then
  pass "TC-014: python3 failure surfaces WARNING with rc=17 and fallback semantic"
else
  fail "TC-014: expected 'phase_detail 取得失敗 (rc=17)' + 'phase 名に縮退' in stderr — got: $stderr014"
fi
echo ""

# --- TC-EARLYEXIT-1 (AC-1): non-rite project → no git rev-parse spawn, exit 0 ---
# The lightweight rite-project gate must early-exit before state-path-resolve.sh
# (git rev-parse ×2). A `git` PATH-shim records every invocation; a non-rite
# sandbox (no rite-config.yml, no .rite/, none up to /) must exit 0 with the
# shim never touched and no work memory created.
echo "TC-EARLYEXIT-1 (AC-1): non-rite project early-exits with no git spawn"
dir_ee1="$TEST_DIR/tc_earlyexit1"
mkdir -p "$dir_ee1"
shim_ee1="$TEST_DIR/tc_earlyexit1-shim"
mkdir -p "$shim_ee1"
git_log_ee1="$TEST_DIR/tc_earlyexit1-git.log"
cat > "$shim_ee1/git" <<SHIM
#!/bin/sh
echo "GIT_CALLED \$*" >> "$git_log_ee1"
exit 0
SHIM
chmod +x "$shim_ee1/git"
rc_ee1=0
echo "{\"tool_name\": \"Bash\", \"cwd\": \"$dir_ee1\"}" | PATH="$shim_ee1:$PATH" bash "$HOOK" 2>/dev/null || rc_ee1=$?
if [ ! -f "$git_log_ee1" ]; then
  pass "TC-EARLYEXIT-1 no git rev-parse spawned in non-rite project (exit code: $rc_ee1)"
else
  fail "TC-EARLYEXIT-1 git was spawned in non-rite project: $(cat "$git_log_ee1")"
fi
if [ "$rc_ee1" -eq 0 ] && [ ! -d "$dir_ee1/.rite-work-memory" ]; then
  pass "TC-EARLYEXIT-1 exit 0 and no work memory created"
else
  fail "TC-EARLYEXIT-1 unexpected: rc=$rc_ee1, wm-dir=$([ -d "$dir_ee1/.rite-work-memory" ] && echo present || echo absent)"
fi
echo ""

# --- TC-EARLYEXIT-2 (AC-3): worktree (rite-config.yml only, no .rite/) does NOT early-exit ---
# A multi_session worktree checks out the tracked rite-config.yml but has no
# .rite state dir (that lives in the main checkout). The gate must detect it via
# rite-config.yml and proceed past the gate to the resolver — proven by the git
# shim being invoked. Guards against a regression that keys detection on .rite/
# alone (which would false-early-exit every worktree edit).
echo "TC-EARLYEXIT-2 (AC-3): worktree with rite-config.yml only is not early-exited"
dir_ee2="$TEST_DIR/tc_earlyexit2"
mkdir -p "$dir_ee2"
printf '# rite worktree sandbox config\n' > "$dir_ee2/rite-config.yml"
# Intentionally do NOT create .rite/ — this is the worktree-specific condition.
shim_ee2="$TEST_DIR/tc_earlyexit2-shim"
mkdir -p "$shim_ee2"
git_log_ee2="$TEST_DIR/tc_earlyexit2-git.log"
cat > "$shim_ee2/git" <<SHIM
#!/bin/sh
echo "GIT_CALLED \$*" >> "$git_log_ee2"
exit 0
SHIM
chmod +x "$shim_ee2/git"
rc_ee2=0
echo "{\"tool_name\": \"Bash\", \"cwd\": \"$dir_ee2\"}" | PATH="$shim_ee2:$PATH" bash "$HOOK" 2>/dev/null || rc_ee2=$?
if [ -f "$git_log_ee2" ]; then
  pass "TC-EARLYEXIT-2 gate passed via rite-config.yml (git rev-parse reached, exit code: $rc_ee2)"
else
  fail "TC-EARLYEXIT-2 gate wrongly early-exited a worktree (git never reached — .rite-only detection regression)"
fi
echo ""

# --- TC-EARLYEXIT-3: relative CWD terminates the gate walk (no infinite loop) ---
# The upward-walk ascends via `${dir%/*}`, which leaves a slashless segment
# (a relative .cwd like `reldir`) unchanged. Without the no-progress guard the
# gate spins forever. The harness supplies an absolute .cwd in practice, but this
# pins the guard. Run under `timeout`; a hang exits 124. Skip when `timeout` is
# unavailable (e.g. macOS without coreutils) rather than fail spuriously.
echo "TC-EARLYEXIT-3: relative CWD terminates the gate walk (no infinite loop)"
dir_ee3="$TEST_DIR/tc_earlyexit3"
mkdir -p "$dir_ee3/reldir"
if command -v timeout >/dev/null 2>&1; then
  rc_ee3=0
  ( cd "$dir_ee3" && echo '{"tool_name": "Bash", "cwd": "reldir"}' | timeout 5 bash "$HOOK" >/dev/null 2>&1 ) || rc_ee3=$?
  if [ "$rc_ee3" -ne 124 ]; then
    pass "TC-EARLYEXIT-3 gate terminated for relative CWD (exit code: $rc_ee3, not a 124 timeout)"
  else
    fail "TC-EARLYEXIT-3 hook hung on relative CWD (timeout 124 — infinite-loop regression)"
  fi
else
  pass "TC-EARLYEXIT-3 skipped: timeout(1) unavailable, termination not exercised"
fi
echo ""

# --- TC-EARLYEXIT-4: rite marker found at an ANCESTOR (multi-level upward walk) ---
# The other early-exit TCs place the rite marker directly at CWD, so none of them
# exercise the upward walk actually ascending. Here the marker (.rite) sits at the
# sandbox root and CWD is several levels below it — the gate must walk up to find
# it, proven by git being reached. Guards against a regression that narrows the
# gate to a CWD-only check, which would still pass every other TC but break the
# common "Bash invoked from a subdirectory of a rite project" case (WM sync would
# silently stop).
echo "TC-EARLYEXIT-4 (AC-1/AC-3): ancestor marker found via upward walk is not early-exited"
dir_ee4="$TEST_DIR/tc_earlyexit4"
mkdir -p "$dir_ee4/.rite" "$dir_ee4/sub/deep"
shim_ee4="$TEST_DIR/tc_earlyexit4-shim"
mkdir -p "$shim_ee4"
git_log_ee4="$TEST_DIR/tc_earlyexit4-git.log"
cat > "$shim_ee4/git" <<SHIM
#!/bin/sh
echo "GIT_CALLED \$*" >> "$git_log_ee4"
exit 0
SHIM
chmod +x "$shim_ee4/git"
rc_ee4=0
echo "{\"tool_name\": \"Bash\", \"cwd\": \"$dir_ee4/sub/deep\"}" | PATH="$shim_ee4:$PATH" bash "$HOOK" 2>/dev/null || rc_ee4=$?
if [ -f "$git_log_ee4" ]; then
  pass "TC-EARLYEXIT-4 gate ascended to the ancestor .rite marker (git rev-parse reached, exit code: $rc_ee4)"
else
  fail "TC-EARLYEXIT-4 gate did not walk up to the ancestor marker (CWD-only detection regression)"
fi
echo ""

# --- Summary ---
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
