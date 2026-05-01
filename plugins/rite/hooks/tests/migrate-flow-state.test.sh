#!/bin/bash
# Tests for hooks/scripts/migrate-flow-state.sh — Issue #672 / #679.
#
# Covers acceptance criteria:
#   AC-8 (Issue #672)        — legacy state auto-migration with explicit warning (silent skip forbidden)
#   AC-LOCAL-1 (Issue #679)  — session-start.sh fires migration; new format created with schema_version=2 + backup
#   AC-LOCAL-2 (Issue #679)  — migration failure leaves legacy source intact + ERROR message emitted
#   AC-LOCAL-3 (Issue #679)  — dry-run mode: detection only, no filesystem mutation
#   AC-LOCAL-4 (Issue #679)  — after rename, the legacy path is ENOENT so other sessions early-exit
#
# Usage: bash plugins/rite/hooks/tests/migrate-flow-state.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../scripts/migrate-flow-state.sh"
SESSION_START="$SCRIPT_DIR/../session-start.sh"

if [ ! -x "$SCRIPT" ]; then
  echo "ERROR: migrate-flow-state.sh missing or not executable: $SCRIPT" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi

PASS=0
FAIL=0
FAILED_NAMES=()

# Each test case runs in a fresh tempdir.  We export STATE_ROOT to that dir.
# _teardown is called explicitly at the end of every test block — we deliberately
# avoid `trap RETURN` because it would fire when _setup itself returns and clear
# TEST_ROOT before the test body could read it.
_setup() {
  TEST_ROOT=$(mktemp -d)
  # Migration is gated on `flow_state.schema_version: 2` in rite-config.yml.
  # All migrate-flow-state tests assume the user has opted into v2.
  cat > "$TEST_ROOT/rite-config.yml" <<'EOF'
flow_state:
  schema_version: 2
EOF
}
_teardown() {
  if [ -n "${TEST_ROOT:-}" ] && [ -d "$TEST_ROOT" ]; then
    rm -rf "$TEST_ROOT" 2>/dev/null || true
  fi
  TEST_ROOT=""
}

_assert() {
  local label="$1"
  local cond="$2"
  if [ "$cond" = "true" ]; then
    PASS=$((PASS + 1))
    echo "  ✓ $label"
  else
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$label")
    echo "  ✗ $label"
  fi
}

_count_files() {
  # Count files matching glob in $1 (works with no matches → returns 0).
  local pattern="$1"
  local count=0
  for f in $pattern; do
    [ -e "$f" ] && count=$((count + 1))
  done
  echo "$count"
}

# ---------- TC-01: No legacy file → silent no-op ----------
echo "TC-01: no legacy file → silent no-op"
_setup
out=$(STATE_ROOT="$TEST_ROOT" bash "$SCRIPT" 2>&1)
rc=$?
_assert "TC-01.exit-0" "$([ $rc -eq 0 ] && echo true || echo false)"
_assert "TC-01.no-output" "$([ -z "$out" ] && echo true || echo false)"
_assert "TC-01.no-sessions-dir" "$([ ! -d "$TEST_ROOT/.rite/sessions" ] && echo true || echo false)"
_teardown

# ---------- TC-02: schema_version=2 already → silent no-op (legacy left intact) ----------
# Files written to the legacy path with schema_version=2 are treated as legitimate
# (e.g., flow-state-update.sh may choose the legacy path when no session_id is
# available at write time). The migration script must NOT delete them — doing so
# would discard the only copy of that state.
echo "TC-02: schema_version>=2 in legacy → silent no-op (legacy intact)"
_setup
echo '{"schema_version":2,"active":false,"phase":"completed"}' > "$TEST_ROOT/.rite-flow-state"
out=$(STATE_ROOT="$TEST_ROOT" bash "$SCRIPT" 2>&1)
rc=$?
_assert "TC-02.exit-0" "$([ $rc -eq 0 ] && echo true || echo false)"
_assert "TC-02.no-output" "$([ -z "$out" ] && echo true || echo false)"
_assert "TC-02.legacy-intact" "$([ -f "$TEST_ROOT/.rite-flow-state" ] && echo true || echo false)"
_assert "TC-02.no-sessions-dir" "$([ ! -d "$TEST_ROOT/.rite/sessions" ] && echo true || echo false)"
_assert "TC-02.no-backup" "$(if compgen -G "$TEST_ROOT/.rite-flow-state.legacy.*" >/dev/null; then echo false; else echo true; fi)"
_teardown

# ---------- TC-03: dry-run on legacy file → detection msg only ----------
echo "TC-03: dry-run → detection only, no filesystem mutation"
_setup
echo '{"active":true,"issue_number":672,"phase":"phase5_lint","session_id":"00112233-4455-6677-8899-aabbccddeeff"}' > "$TEST_ROOT/.rite-flow-state"
out=$(STATE_ROOT="$TEST_ROOT" bash "$SCRIPT" --dry-run 2>&1)
rc=$?
_assert "TC-03.exit-0" "$([ $rc -eq 0 ] && echo true || echo false)"
_assert "TC-03.dryrun-msg" "$(echo "$out" | grep -q 'dry-run: would migrate' && echo true || echo false)"
_assert "TC-03.legacy-intact" "$([ -f "$TEST_ROOT/.rite-flow-state" ] && echo true || echo false)"
_assert "TC-03.no-sessions-dir" "$([ ! -d "$TEST_ROOT/.rite/sessions" ] && echo true || echo false)"
_assert "TC-03.no-backup" "$(if compgen -G "$TEST_ROOT/.rite-flow-state.legacy.*" >/dev/null; then echo false; else echo true; fi)"
_teardown

# ---------- TC-04: full migration with valid session_id ----------
echo "TC-04: full migration preserves session_id and core fields, schema_version=2 added"
_setup
mkdir -p "$TEST_ROOT/.rite/sessions"
cat > "$TEST_ROOT/.rite-flow-state" <<JSON
{"active":true,"issue_number":672,"branch":"feat/issue-672-x","phase":"phase5_lint","previous_phase":"phase5_post_review","pr_number":42,"parent_issue_number":100,"next_action":"resume","session_id":"00112233-4455-6677-8899-aabbccddeeff","last_synced_phase":"phase5_post_lint","wm_comment_id":987654321}
JSON
out=$(STATE_ROOT="$TEST_ROOT" bash "$SCRIPT" 2>&1)
rc=$?
new_file="$TEST_ROOT/.rite/sessions/00112233-4455-6677-8899-aabbccddeeff.flow-state"
backup_count=$(_count_files "$TEST_ROOT/.rite-flow-state.legacy.*")
_assert "TC-04.exit-0" "$([ $rc -eq 0 ] && echo true || echo false)"
_assert "TC-04.migration-msg" "$(echo "$out" | grep -q '\[rite\] migrated:' && echo true || echo false)"
_assert "TC-04.new-file-exists" "$([ -f "$new_file" ] && echo true || echo false)"
_assert "TC-04.legacy-removed" "$([ ! -f "$TEST_ROOT/.rite-flow-state" ] && echo true || echo false)"
_assert "TC-04.backup-created" "$([ "$backup_count" -eq 1 ] && echo true || echo false)"
_assert "TC-04.schema-version-2" "$([ "$(jq -r .schema_version "$new_file")" = "2" ] && echo true || echo false)"
_assert "TC-04.session-id-preserved" "$([ "$(jq -r .session_id "$new_file")" = "00112233-4455-6677-8899-aabbccddeeff" ] && echo true || echo false)"
_assert "TC-04.issue-number-preserved" "$([ "$(jq -r .issue_number "$new_file")" = "672" ] && echo true || echo false)"
_assert "TC-04.branch-preserved" "$([ "$(jq -r .branch "$new_file")" = "feat/issue-672-x" ] && echo true || echo false)"
_assert "TC-04.phase-preserved" "$([ "$(jq -r .phase "$new_file")" = "phase5_lint" ] && echo true || echo false)"
_assert "TC-04.pr-number-preserved" "$([ "$(jq -r .pr_number "$new_file")" = "42" ] && echo true || echo false)"
_assert "TC-04.parent-issue-preserved" "$([ "$(jq -r .parent_issue_number "$new_file")" = "100" ] && echo true || echo false)"
_assert "TC-04.wm-comment-preserved" "$([ "$(jq -r .wm_comment_id "$new_file")" = "987654321" ] && echo true || echo false)"
_teardown

# ---------- TC-05: legacy without session_id → fresh UUID generated ----------
echo "TC-05: legacy without session_id → UUID generated, new file at .rite/sessions/{uuid}.flow-state"
_setup
echo '{"active":false,"issue_number":1,"phase":""}' > "$TEST_ROOT/.rite-flow-state"
out=$(STATE_ROOT="$TEST_ROOT" bash "$SCRIPT" 2>&1)
rc=$?
sessions=("$TEST_ROOT/.rite/sessions/"*.flow-state)
generated_count=${#sessions[@]}
_assert "TC-05.exit-0" "$([ $rc -eq 0 ] && echo true || echo false)"
_assert "TC-05.exactly-one-new-file" "$([ "$generated_count" -eq 1 ] && [ -f "${sessions[0]}" ] && echo true || echo false)"
if [ -f "${sessions[0]}" ]; then
  generated_sid=$(jq -r .session_id "${sessions[0]}")
  _assert "TC-05.generated-uuid-format" "$(if [[ "$generated_sid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then echo true; else echo false; fi)"
fi
_teardown

# ---------- TC-06: schema_version=1 (numeric) → migrated ----------
echo "TC-06: schema_version=1 (legacy explicit version) → migrated"
_setup
echo '{"schema_version":1,"active":true,"issue_number":2,"phase":"phase2"}' > "$TEST_ROOT/.rite-flow-state"
out=$(STATE_ROOT="$TEST_ROOT" bash "$SCRIPT" 2>&1)
rc=$?
sessions=("$TEST_ROOT/.rite/sessions/"*.flow-state)
_assert "TC-06.exit-0" "$([ $rc -eq 0 ] && echo true || echo false)"
_assert "TC-06.migrated" "$([ -f "${sessions[0]:-/nonexistent}" ] && echo true || echo false)"
[ -f "${sessions[0]:-/nonexistent}" ] && \
  _assert "TC-06.schema-version-bumped-to-2" "$([ "$(jq -r .schema_version "${sessions[0]}")" = "2" ] && echo true || echo false)"
_teardown

# ---------- TC-07: invalid JSON in legacy → ERROR, legacy intact ----------
echo "TC-07: invalid JSON in legacy → ERROR + legacy preserved (no destructive migration)"
_setup
echo 'not-valid-json{{{' > "$TEST_ROOT/.rite-flow-state"
out=$(STATE_ROOT="$TEST_ROOT" bash "$SCRIPT" 2>&1) || rc=$?
rc=${rc:-$?}
_assert "TC-07.exit-non-zero" "$([ "$rc" -ne 0 ] && echo true || echo false)"
_assert "TC-07.error-msg" "$(echo "$out" | grep -q 'ERROR.*not valid JSON' && echo true || echo false)"
_assert "TC-07.legacy-intact" "$([ -f "$TEST_ROOT/.rite-flow-state" ] && echo true || echo false)"
_assert "TC-07.no-sessions-dir" "$([ ! -d "$TEST_ROOT/.rite/sessions" ] && echo true || echo false)"
unset rc
_teardown

# ---------- TC-08: dry-run when no legacy → silent no-op ----------
echo "TC-08: dry-run with no legacy → silent no-op"
_setup
out=$(STATE_ROOT="$TEST_ROOT" bash "$SCRIPT" --dry-run 2>&1)
rc=$?
_assert "TC-08.exit-0" "$([ $rc -eq 0 ] && echo true || echo false)"
_assert "TC-08.no-output" "$([ -z "$out" ] && echo true || echo false)"
_teardown

# ---------- TC-09: empty legacy file → removed silently ----------
echo "TC-09: empty legacy file → removed silently (treated as nothing meaningful)"
_setup
: > "$TEST_ROOT/.rite-flow-state"
out=$(STATE_ROOT="$TEST_ROOT" bash "$SCRIPT" 2>&1)
rc=$?
_assert "TC-09.exit-0" "$([ $rc -eq 0 ] && echo true || echo false)"
_assert "TC-09.legacy-removed" "$([ ! -f "$TEST_ROOT/.rite-flow-state" ] && echo true || echo false)"
_assert "TC-09.no-sessions-dir" "$([ ! -d "$TEST_ROOT/.rite/sessions" ] && echo true || echo false)"
_teardown

# ---------- TC-10: AC-LOCAL-2 — step 4 failure (rename) → new file rolled back, legacy intact ----------
echo "TC-10: step 4 (rename) failure → new file removed, legacy preserved (rollback semantics)"
_setup
# Make the legacy file a directory entry that 'mv' cannot rename out of: by
# making the parent directory read-only AFTER the new file has been written.
# We simulate this by intercepting via a wrapper that simulates rename failure.
# Simpler approach: use a legacy that points to a path on a write-protected
# subdir for rename. We use chmod a-w on STATE_ROOT.
echo '{"active":true,"issue_number":3,"phase":"phaseX","session_id":"11223344-5566-7788-99aa-bbccddeeff00"}' > "$TEST_ROOT/.rite-flow-state"
# Pre-create sessions dir so step 3 succeeds quickly.
mkdir -p "$TEST_ROOT/.rite/sessions"
chmod 555 "$TEST_ROOT"  # read+exec only — mv into . will fail (rename for backup)
set +e
out=$(STATE_ROOT="$TEST_ROOT" bash "$SCRIPT" 2>&1)
rc=$?
set -e
chmod 755 "$TEST_ROOT"  # restore so cleanup works
new_file="$TEST_ROOT/.rite/sessions/11223344-5566-7788-99aa-bbccddeeff00.flow-state"
_assert "TC-10.exit-non-zero" "$([ "$rc" -ne 0 ] && echo true || echo false)"
_assert "TC-10.error-step-4" "$(echo "$out" | grep -q 'step 4' && echo true || echo false)"
_assert "TC-10.legacy-intact" "$([ -f "$TEST_ROOT/.rite-flow-state" ] && echo true || echo false)"
_assert "TC-10.new-file-rolled-back" "$([ ! -f "$new_file" ] && echo true || echo false)"
_teardown

# ---------- TC-11: AC-LOCAL-1 — session-start.sh fires migration when STATE_ROOT has legacy ----------
echo "TC-11: session-start.sh fires migration on startup (integration)"
_setup
echo '{"active":true,"issue_number":42,"branch":"feat/x","phase":"phase5_lint","next_action":"resume","session_id":"22334455-6677-8899-aabb-ccddeeff0011"}' > "$TEST_ROOT/.rite-flow-state"
# Run session-start.sh with a mocked input (cwd=$TEST_ROOT, source=startup, session_id matches existing).
# We invoke session-start.sh directly with fake stdin so the migration block fires.
hook_input='{"cwd":"'"$TEST_ROOT"'","source":"startup","session_id":"22334455-6677-8899-aabb-ccddeeff0011"}'
set +e
out=$(echo "$hook_input" | bash "$SESSION_START" 2>&1)
rc=$?
set -e
new_file="$TEST_ROOT/.rite/sessions/22334455-6677-8899-aabb-ccddeeff0011.flow-state"
_assert "TC-11.session-start-completes" "$([ "$rc" -eq 0 ] && echo true || echo false)"
_assert "TC-11.migration-msg-on-stderr" "$(echo "$out" | grep -q '\[rite\] migrated:' && echo true || echo false)"
_assert "TC-11.new-format-file-created" "$([ -f "$new_file" ] && echo true || echo false)"
_assert "TC-11.legacy-renamed" "$([ ! -f "$TEST_ROOT/.rite-flow-state" ] && echo true || echo false)"
_assert "TC-11.backup-exists" "$(if compgen -G "$TEST_ROOT/.rite-flow-state.legacy.*" >/dev/null; then echo true; else echo false; fi)"
_teardown

# ---------- TC-12: AC-LOCAL-4 — after migration the legacy path is ENOENT ----------
echo "TC-12: after migration, legacy path is ENOENT (other sessions early-exit)"
_setup
echo '{"active":true,"issue_number":99,"phase":"phaseY","session_id":"33445566-7788-99aa-bbcc-ddeeff001122"}' > "$TEST_ROOT/.rite-flow-state"
STATE_ROOT="$TEST_ROOT" bash "$SCRIPT" >/dev/null 2>&1
# At this point the legacy file must NOT exist. Any subsequent reader probing
# the old path receives ENOENT and falls into its [ ! -f ] early-exit branch.
_assert "TC-12.legacy-enoent" "$([ ! -f "$TEST_ROOT/.rite-flow-state" ] && echo true || echo false)"
_assert "TC-12.new-format-present" "$([ -f "$TEST_ROOT/.rite/sessions/33445566-7788-99aa-bbcc-ddeeff001122.flow-state" ] && echo true || echo false)"
_teardown

# ---------- TC-13: stdout is empty (only stderr is used for messages) ----------
echo "TC-13: stdout never contains migration text (caller pipelines stay clean)"
_setup
echo '{"active":true,"issue_number":7,"phase":"phaseZ","session_id":"44556677-8899-aabb-ccdd-eeff00112233"}' > "$TEST_ROOT/.rite-flow-state"
stdout=$(STATE_ROOT="$TEST_ROOT" bash "$SCRIPT" 2>/dev/null)
_assert "TC-13.stdout-empty" "$([ -z "$stdout" ] && echo true || echo false)"
_teardown

# ---------- TC-15: rollback path — schema_version=1 in config → migration skipped ----------
echo "TC-15: rollback path (flow_state.schema_version: 1) → silent no-op, legacy untouched"
_setup
# Override the v2 config installed by _setup with the rollback config.
cat > "$TEST_ROOT/rite-config.yml" <<'EOF'
flow_state:
  schema_version: 1
EOF
echo '{"active":true,"issue_number":42,"phase":"phase5_lint"}' > "$TEST_ROOT/.rite-flow-state"
out=$(STATE_ROOT="$TEST_ROOT" bash "$SCRIPT" 2>&1)
rc=$?
_assert "TC-15.exit-0" "$([ $rc -eq 0 ] && echo true || echo false)"
_assert "TC-15.no-output" "$([ -z "$out" ] && echo true || echo false)"
_assert "TC-15.legacy-intact" "$([ -f "$TEST_ROOT/.rite-flow-state" ] && echo true || echo false)"
_assert "TC-15.no-sessions-dir" "$([ ! -d "$TEST_ROOT/.rite/sessions" ] && echo true || echo false)"
_teardown

# ---------- TC-16: missing rite-config.yml → migration skipped (default = legacy) ----------
echo "TC-16: missing rite-config.yml → silent no-op (default schema_version is 1)"
_setup
rm -f "$TEST_ROOT/rite-config.yml"  # remove the v2 config installed by _setup
echo '{"active":true,"issue_number":99,"phase":"phaseX"}' > "$TEST_ROOT/.rite-flow-state"
out=$(STATE_ROOT="$TEST_ROOT" bash "$SCRIPT" 2>&1)
rc=$?
_assert "TC-16.exit-0" "$([ $rc -eq 0 ] && echo true || echo false)"
_assert "TC-16.no-output" "$([ -z "$out" ] && echo true || echo false)"
_assert "TC-16.legacy-intact" "$([ -f "$TEST_ROOT/.rite-flow-state" ] && echo true || echo false)"
_teardown

# ---------- TC-14: backup file content equals pre-migration legacy content ----------
echo "TC-14: backup file content equals legacy content byte-for-byte (rename, not rebuild)"
_setup
legacy_payload='{"active":true,"issue_number":11,"phase":"phaseQ","session_id":"55667788-99aa-bbcc-ddee-ff0011223344","custom_field":"do-not-lose-me"}'
echo "$legacy_payload" > "$TEST_ROOT/.rite-flow-state"
STATE_ROOT="$TEST_ROOT" bash "$SCRIPT" >/dev/null 2>&1
backup_glob=("$TEST_ROOT"/.rite-flow-state.legacy.*)
backup_file="${backup_glob[0]}"
backup_payload=$(cat "$backup_file")
_assert "TC-14.backup-equals-legacy" "$([ "$backup_payload" = "$legacy_payload" ] && echo true || echo false)"
_teardown

# ---------- TC-17: backup file gets chmod 600 (security review MEDIUM, #679) ----------
echo "TC-17: backup file is chmod'd to 600 after step 4 rename (defense-in-depth)"
_setup
# Create a legacy file that was manually written with mode 644 (the threat scenario)
echo '{"active":true,"issue_number":1,"phase":"phaseW","session_id":"66778899-aabb-ccdd-eeff-001122334455"}' > "$TEST_ROOT/.rite-flow-state"
chmod 644 "$TEST_ROOT/.rite-flow-state"
STATE_ROOT="$TEST_ROOT" bash "$SCRIPT" >/dev/null 2>&1
backup_file=("$TEST_ROOT"/.rite-flow-state.legacy.*)
if [ -f "${backup_file[0]}" ]; then
  # stat -c on Linux, stat -f on BSD/macOS — try both
  perm=$(stat -c '%a' "${backup_file[0]}" 2>/dev/null || stat -f '%A' "${backup_file[0]}" 2>/dev/null)
  _assert "TC-17.backup-mode-600" "$([ "$perm" = "600" ] && echo true || echo false)"
else
  _assert "TC-17.backup-mode-600" "false"
fi
_teardown

# ---------- TC-18: backup file survives session-start/session-end find cleanup (#747 cycle 3 CRITICAL) ----------
# Regression guard: both session-start.sh and session-end.sh use the glob
# `.rite-flow-state.??????*` which matches any suffix of 6+ chars — including
# the migration backup name. Without `-not -name '.rite-flow-state.legacy.*'`,
# the backup disappears the next time either hook runs after the file ages
# past `-mmin +1`. This TC verifies (1) the spec backup name does follow the
# `legacy.*` convention, (2) back-dated backups survive the protected find,
# (3) the same find without the exception would have deleted the backup
# (counter-test, defense-in-depth against the exception being removed in
# future refactors).
echo "TC-18: backup file survives session-start/end stale-tempfile cleanup (#747 cycle 3/4 CRITICAL)"
_setup
echo '{"active":true,"issue_number":2,"phase":"phaseV","session_id":"77889900-aabb-ccdd-eeff-112233445566"}' > "$TEST_ROOT/.rite-flow-state"
STATE_ROOT="$TEST_ROOT" bash "$SCRIPT" >/dev/null 2>&1
backup_glob=("$TEST_ROOT"/.rite-flow-state.legacy.*)
backup_file="${backup_glob[0]}"
_assert "TC-18.backup-created" "$([ -f "$backup_file" ] && echo true || echo false)"

# Naming convention guard: the spec assumes the backup contains the literal
# `legacy.` token so the find exception can target it. If a future refactor
# changes the naming, this assertion fails before the silent-deletion regression
# can re-occur.
_assert "TC-18.backup-name-contains-legacy" "$([[ "$backup_file" == *.rite-flow-state.legacy.* ]] && echo true || echo false)"

# Back-date the backup file by 2 minutes so `-mmin +1` matches. Verify the
# back-date actually took effect — otherwise the survives-cleanup assertion
# would be a false positive (file looks fresh, find skips it for an unrelated
# reason). 3-tier touch fallback: GNU `touch -d`, GNU `date -d`, BSD `date -v`.
touch -d "2 minutes ago" "$backup_file" 2>/dev/null \
  || touch -t "$(date -d '2 minutes ago' +%Y%m%d%H%M.%S 2>/dev/null || date -v -2M +%Y%m%d%H%M.%S 2>/dev/null)" "$backup_file" 2>/dev/null
backup_mtime=$(stat -c '%Y' "$backup_file" 2>/dev/null || stat -f '%m' "$backup_file" 2>/dev/null || echo 0)
now_epoch=$(date +%s)
_assert "TC-18.back-date-applied" "$([ $((now_epoch - backup_mtime)) -gt 60 ] && echo true || echo false)"

# (a) Protected find (matches session-start.sh / session-end.sh canonical form): backup MUST survive.
find "$TEST_ROOT" -maxdepth 1 \( -name ".rite-flow-state.tmp.*" -o -name ".rite-flow-state.??????*" \) -not -name ".rite-flow-state.legacy.*" -type f -mmin +1 -delete 2>/dev/null || true
_assert "TC-18.backup-survives-protected-cleanup" "$([ -f "$backup_file" ] && echo true || echo false)"

# (b) Counter-test: unprotected find (the exception removed) MUST delete the backup.
# Defense-in-depth guard: if a future refactor accidentally removes the
# `-not -name` exception, this counter-test still confirms the regression
# would have triggered, helping a maintainer understand the protective
# intent of (a).
find "$TEST_ROOT" -maxdepth 1 \( -name ".rite-flow-state.tmp.*" -o -name ".rite-flow-state.??????*" \) -type f -mmin +1 -delete 2>/dev/null || true
_assert "TC-18.backup-deleted-by-unprotected-cleanup" "$([ ! -f "$backup_file" ] && echo true || echo false)"
_teardown

# ============================================================================
# T-08 拡充 (Issue #684, AC-8): edge case + non-regression の追加 TC
# ============================================================================
# 既存 TC-01〜TC-18 は AC-LOCAL-1〜AC-LOCAL-4 (Issue #679 内 AC) を中心にカバー。
# 以下 TC-19〜TC-21 は Issue #672 AC-8 の edge case 観点で:
#   - TC-19: migration 中 SIGKILL → atomic 3 状態 (pre / mid / post) のいずれか
#   - TC-20: production session-start.sh / session-end.sh の find pattern が
#            canonical exception `-not -name '.rite-flow-state.legacy.*'` を含む
#            ことを pin (#747 cycle 3/4 regression を本体側でも構造的に防ぐ)
#   - TC-21: rollback (TC-10 chmod 555) 後の filesystem 状態を更に pin
#            (backup 作成と rename がどちらも skip されることを byte-equal で verify)

# ---------- TC-19: migration 中 SIGKILL → atomic 3 状態のいずれか ----------
echo "TC-19: migration 中 SIGKILL → atomic invariant (3 states pre/mid/post)"
_setup
legacy_payload='{"active":true,"issue_number":684,"phase":"phaseM","session_id":"99887766-5544-3322-1100-aabbccddeeff"}'
echo "$legacy_payload" > "$TEST_ROOT/.rite-flow-state"
( STATE_ROOT="$TEST_ROOT" bash "$SCRIPT" >/dev/null 2>&1 ) &
_pid=$!
# micro-sleep to land mid-migration; the script does mkdir → write → rename
sleep 0.005
kill -KILL "$_pid" 2>/dev/null || true
wait "$_pid" 2>/dev/null || true

# Atomic invariant: state must be one of three deterministic snapshots.
#   (P) pre-migration: legacy intact, no per-session file, no backup
#   (M) mid-migration: legacy intact, per-session file partial OR backup absent
#   (S) post-migration: legacy gone, per-session file integral, backup integral
#
# In all three, the legacy file (if present) must still hold the original
# JSON byte-equal to the pre-write payload.  partial-write of the legacy file
# itself must NEVER occur (the migrator only renames, never edits in place).
legacy_after=""
[ -f "$TEST_ROOT/.rite-flow-state" ] && legacy_after=$(cat "$TEST_ROOT/.rite-flow-state")
sessions_glob=("$TEST_ROOT/.rite/sessions/"*.flow-state)
session_present=false
[ -f "${sessions_glob[0]:-/nonexistent}" ] && session_present=true
backup_glob=("$TEST_ROOT"/.rite-flow-state.legacy.*)
backup_present=false
[ -f "${backup_glob[0]:-/nonexistent}" ] && backup_present=true

# Classify
state_label="UNKNOWN"
if [ -n "$legacy_after" ] && [ "$session_present" = "false" ] && [ "$backup_present" = "false" ]; then
  state_label="P_pre"
elif [ -n "$legacy_after" ] && { [ "$session_present" = "true" ] || [ "$backup_present" = "true" ]; }; then
  state_label="M_mid"
elif [ -z "$legacy_after" ] && [ ! -f "$TEST_ROOT/.rite-flow-state" ] && [ "$session_present" = "true" ] && [ "$backup_present" = "true" ]; then
  state_label="S_post"
fi
case "$state_label" in
  P_pre|M_mid|S_post)
    _assert "TC-19.atomic-3-states (observed=$state_label)" "true"
    ;;
  *)
    _assert "TC-19.atomic-3-states (observed=$state_label)" "false"
    ;;
esac

# Stronger invariant: the legacy file (if present) must be byte-identical to
# pre-write payload — migrator never partially overwrites the legacy file.
if [ -f "$TEST_ROOT/.rite-flow-state" ]; then
  _assert "TC-19.legacy-byte-equal-to-payload" \
    "$([ "$legacy_after" = "$legacy_payload" ] && echo true || echo false)"
else
  _assert "TC-19.legacy-byte-equal-to-payload (legacy gone — post-state)" "true"
fi
_teardown

# ---------- TC-20: production find patterns include legacy-backup exception ----------
# Wiki 経験則「新規 file 命名と既存 find glob が collision して silent 削除を起こす」を
# production スクリプト側でも構造的に pin する。session-start.sh / session-end.sh が
# 「legacy.* を例外扱いする canonical phrase `-not -name '.rite-flow-state.legacy.*'`」
# を保持していることを mechanical に verify。誰かが将来 refactor で例外を消したら
# 本 assertion で fail する。
echo "TC-20: production session-start/end の find は legacy backup を例外扱いする"
HOOKS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
session_start="$HOOKS_DIR/session-start.sh"
session_end="$HOOKS_DIR/session-end.sh"
canonical_phrase=".rite-flow-state.legacy.*"
exception_token="-not -name"

# session-start.sh — `--` ends grep option parsing so the literal `-not -name`
# pattern (which begins with `-`) is not mis-parsed as a grep option.
if grep -qF -- "$exception_token" "$session_start" \
    && grep -qF -- "$canonical_phrase" "$session_start"; then
  _assert "TC-20.session-start-has-legacy-exception" "true"
else
  _assert "TC-20.session-start-has-legacy-exception" "false"
fi
# session-end.sh
if grep -qF -- "$exception_token" "$session_end" \
    && grep -qF -- "$canonical_phrase" "$session_end"; then
  _assert "TC-20.session-end-has-legacy-exception" "true"
else
  _assert "TC-20.session-end-has-legacy-exception" "false"
fi

# ---------- TC-21: rollback path leaves NO backup, legacy is byte-equal to original ----------
# TC-10 が rename 失敗 → new file rolled back を verify するが、本 TC は更に
# 「backup 作成も skip される (`.rite-flow-state.legacy.*` ファイル不在)」と
# 「legacy ファイルが元のペイロードと byte-equal」を pin する。
echo "TC-21: rollback で backup は作られず legacy は byte-equal で保持"
_setup
mkdir -p "$TEST_ROOT/.rite/sessions"
rollback_payload='{"active":true,"issue_number":3,"phase":"phaseRB","session_id":"deadbeef-1111-2222-3333-444455556666"}'
echo "$rollback_payload" > "$TEST_ROOT/.rite-flow-state"
chmod 555 "$TEST_ROOT"
set +e
STATE_ROOT="$TEST_ROOT" bash "$SCRIPT" >/dev/null 2>&1
rc=$?
set -e
chmod 755 "$TEST_ROOT"

# legacy is byte-identical
_assert "TC-21.rollback-rc-non-zero" "$([ "$rc" -ne 0 ] && echo true || echo false)"
legacy_content=$(cat "$TEST_ROOT/.rite-flow-state" 2>/dev/null || echo "")
_assert "TC-21.legacy-byte-equal-original" \
  "$([ "$legacy_content" = "$rollback_payload" ] && echo true || echo false)"
# no backup written
backup_glob=("$TEST_ROOT"/.rite-flow-state.legacy.*)
_assert "TC-21.no-backup-on-rollback" \
  "$([ ! -f "${backup_glob[0]:-/nonexistent}" ] && echo true || echo false)"
_teardown

# ---------- Summary ----------
echo ""
echo "==============================="
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed:"
  for n in "${FAILED_NAMES[@]}"; do
    echo "  - $n"
  done
  exit 1
fi
echo "All migrate-flow-state tests passed!"
