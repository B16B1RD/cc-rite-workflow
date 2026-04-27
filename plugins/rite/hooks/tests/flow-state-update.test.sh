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
  return 0  # Form B (portability variant) → return 0 必須 (bash-trap-patterns.md "cleanup 関数の契約" 節 Form B 参照)
}
# Signal-specific traps mirror flow-state-update.sh (review #686 F-09): EXIT
# alone leaks /tmp/tmp.XXXX TEST_DIRs when the run is interrupted with Ctrl+C
# or killed externally. POSIX exit codes per BSD/Linux convention.
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

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
# T-LOCAL-2 / AC-LOCAL-2: two sessions keep state independent
#
# Coverage strategy (review #686 F-07): AC-LOCAL-2 says "並行 2 session" but
# verifies state independence regardless of timing. This test combines:
#   (a) sequential interleave  — A.create → B.create → B.patch — proves that
#       per-session paths route writes independently.
#   (b) concurrent create      — A.create & B.create wait — proves that the
#       mkdir/mktemp/mv sequence has no race against a concurrent peer hitting
#       the same `.rite/sessions/` parent dir.
# Sub-second timing on (b) is best-effort (depends on host scheduler), but
# both files MUST exist after the wait regardless of execution order.
# --------------------------------------------------------------------------
echo ""
echo "T-LOCAL-2 (AC-LOCAL-2): sessions keep state independent (sequential interleave)"
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
  pass "both session files created (sequential interleave)"
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

# (b) Concurrent create — both creates fire in parallel & wait for both PIDs.
# Tests the mkdir/mktemp/mv pipeline against a concurrent peer hitting the same
# .rite/sessions/ parent dir. Per-session paths are structurally race-free, but
# the assertion is that BOTH files exist regardless of completion order.
echo ""
echo "T-LOCAL-2 (concurrent create): two sessions create in parallel with wait"
TD=$(make_test_dir); cleanup_dirs+=("$TD")
write_config "$TD" 2
SID_C="cccccccc-cccc-cccc-cccc-cccccccccccc"
SID_D="dddddddd-dddd-dddd-dddd-dddddddddddd"

# Each session passes its UUID via --session (avoids .rite-session-id race).
(cd "$TD" && bash "$HOOK" create --session "$SID_C" \
  --phase "phase_c" --issue 1 --branch "bc" --pr 0 --next "nc" >/dev/null 2>&1) &
PID_C=$!
(cd "$TD" && bash "$HOOK" create --session "$SID_D" \
  --phase "phase_d" --issue 2 --branch "bd" --pr 0 --next "nd" >/dev/null 2>&1) &
PID_D=$!
wait "$PID_C" "$PID_D"

C="$TD/.rite/sessions/$SID_C.flow-state"
D="$TD/.rite/sessions/$SID_D.flow-state"
if [ -f "$C" ] && [ -f "$D" ]; then
  pass "both session files created under concurrent execution"
else
  fail "concurrent create lost a file: c=$([ -f "$C" ] && echo y || echo n) d=$([ -f "$D" ] && echo y || echo n)"
fi
if [ "$(jq -r '.phase' "$C" 2>/dev/null)" = "phase_c" ] && [ "$(jq -r '.phase' "$D" 2>/dev/null)" = "phase_d" ]; then
  pass "concurrent sessions retain independent phase values"
else
  fail "concurrent phase mismatch: c=$(jq -r '.phase' "$C" 2>/dev/null) d=$(jq -r '.phase' "$D" 2>/dev/null)"
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
# T-LOCAL-4 / AC-9: corrupt-state fail-fast preserves no-orphan invariant
#
# AC-9 spec scope (review #686 F-08): The literal "atomic write 中の SIGKILL →
# state 破壊なし" cannot be reproduced deterministically in bash (kill -9 timing
# during a subshell is racy). We split the spec into two verifiable pieces:
#
#   1. mktemp + mv pattern (atomicity guarantee) — verified by inspection of
#      flow-state-update.sh (mktemp `${FLOW_STATE}.XXXXXX` + `mv`); the kernel
#      rename(2) is atomic, so a SIGKILL between mv-call boundary keeps the
#      target either fully old or fully new.
#   2. Fail-fast on corrupt input — when the script detects partial-write or
#      corruption (jq parse error in patch / create read), it exits non-zero
#      WITHOUT mv-ing a partial temp into the target. This is the deterministic
#      half of AC-9 that this test covers (Part A: patch mode, Part B: create
#      mode). True SIGKILL stress is left to manual integration testing.
# --------------------------------------------------------------------------
echo ""
echo "T-LOCAL-4 (AC-9 part A): patch mode fail-fast on corrupt JSON, no orphan temp"
TD=$(make_test_dir); cleanup_dirs+=("$TD")
write_config "$TD" 2
SID="33333333-3333-3333-3333-333333333333"
write_session_id "$TD" "$SID"

(cd "$TD" && bash "$HOOK" create \
  --phase "intact_phase" --issue 1 --branch "b" --pr 0 --next "n" >/dev/null 2>&1)
TARGET="$TD/.rite/sessions/$SID.flow-state"

# Corrupt the file to make jq parse fail. patch mode reads the file via jq;
# on parse failure the script must exit without mv-ing a partial temp into
# the target.
echo "{not valid json" > "$TARGET"
err_log_a="$TD/err-part-a.log"
set +e
(cd "$TD" && bash "$HOOK" patch --phase "wont_apply" --next "n2" >/dev/null 2>"$err_log_a")
rc=$?
set -e

# Post-conditions: rc != 0 AND no orphan ${FLOW_STATE}.XXXXXX temp remains AND
# the failure message identifies the parse error (review #686 cycle 2 LOW —
# verify stderr content, not just exit code, so a regression that drops the
# message but keeps `exit 1` is still caught).
orphan=$(ls "$TD/.rite/sessions/" 2>/dev/null | grep -E '\.flow-state\.[a-zA-Z0-9]{6,}$' || true)
if [ "$rc" -ne 0 ] && [ -z "$orphan" ]; then
  pass "patch mode exits non-zero on jq failure with no temp orphan"
else
  fail "rc=$rc orphan='$orphan'"
fi
if grep -q "parse failed" "$err_log_a"; then
  pass "patch fail-fast preserves parse-failure message in stderr"
else
  fail "patch stderr missing 'parse failed' message: $(head -3 "$err_log_a")"
fi

# Part B: create mode fail-fast on corrupt state preserves file content.
# Verifies that when create mode encounters a corrupt JSON (jq parse fail in
# PREV_PHASE capture), it exits 1 BEFORE writing — the corrupted bytes remain
# untouched (no silent overwrite that would erase forensic evidence).
echo ""
echo "T-LOCAL-4 (AC-9 part B): create mode fail-fast on corrupt state preserves bytes"
TD=$(make_test_dir); cleanup_dirs+=("$TD")
write_config "$TD" 2
SID="44444444-4444-4444-4444-444444444444"
write_session_id "$TD" "$SID"
(cd "$TD" && bash "$HOOK" create \
  --phase "v1" --issue 1 --branch "b" --pr 0 --next "n" >/dev/null 2>&1)
TARGET="$TD/.rite/sessions/$SID.flow-state"

# Corrupt the existing state to a non-JSON form. create mode requires reading
# .phase via jq; parse failure must fail-fast without overwriting the file.
echo "{corrupt" > "$TARGET"
err_log_b="$TD/err-part-b.log"
set +e
(cd "$TD" && bash "$HOOK" create \
  --phase "v2" --issue 1 --branch "b" --pr 0 --next "n" >/dev/null 2>"$err_log_b")
rc2=$?
set -e
remaining=$(cat "$TARGET")
if [ "$rc2" -ne 0 ] && [ "$remaining" = "{corrupt" ]; then
  pass "create mode fail-fast on corrupt state preserves file content (no silent overwrite)"
else
  fail "rc2=$rc2 remaining='$remaining'"
fi
if grep -q "parse failed" "$err_log_b"; then
  pass "create fail-fast preserves parse-failure message in stderr"
else
  fail "create stderr missing 'parse failed' message: $(head -3 "$err_log_b")"
fi

# --------------------------------------------------------------------------
# T-LOCAL-5: F-01 path-traversal regression test (review #686 cycle 2 MEDIUM)
#
# Cycle 1 commit `432a507` added UUID validation to _resolve_session_id's
# --session arg path. The fix rejects malformed input with rc=1 and an
# "invalid session_id format" error, instead of silently writing to
# `.rite/sessions/../foo.flow-state` (which resolves to `.rite/foo.flow-state`
# escaping the per-session sandbox). This test guards the security invariant
# from regressions: validation order, regex, return code, and stderr message
# all matter — losing any one of them silently re-opens the traversal.
# --------------------------------------------------------------------------
echo ""
echo "T-LOCAL-5 (#686 F-01): --session UUID validation rejects path traversal"
TD=$(make_test_dir); cleanup_dirs+=("$TD")
write_config "$TD" 2

err_log="$TD/err-traversal.log"
set +e
(cd "$TD" && bash "$HOOK" create --session "../escape" \
  --phase "p" --issue 1 --branch "b" --pr 0 --next "n" >/dev/null 2>"$err_log")
rc_traversal=$?
set -e

# Three independent assertions — losing any one of them re-opens the regression
if [ "$rc_traversal" -ne 0 ]; then
  pass "--session traversal input rejected with non-zero exit ($rc_traversal)"
else
  fail "--session traversal accepted (rc=0); UUID validation regressed"
fi
if grep -q "invalid session_id format" "$err_log"; then
  pass "--session traversal emits 'invalid session_id format' error"
else
  fail "missing 'invalid session_id format' in stderr: $(head -3 "$err_log")"
fi
# No file should leak outside .rite/sessions/. Both relative and absolute
# escape patterns are checked.
if [ ! -e "$TD/.rite-flow-state.escape" ] && [ ! -e "$TD/escape.flow-state" ] \
  && [ ! -e "$TD/.rite/escape.flow-state" ]; then
  pass "--session traversal did not create any escape-path file"
else
  fail "traversal escape file detected"
fi

# Also verify a non-UUID but harmless string (no slashes) still rejected.
err_log2="$TD/err-bad-uuid.log"
set +e
(cd "$TD" && bash "$HOOK" create --session "not-a-uuid" \
  --phase "p" --issue 1 --branch "b" --pr 0 --next "n" >/dev/null 2>"$err_log2")
rc_bad=$?
set -e
if [ "$rc_bad" -ne 0 ] && grep -q "invalid session_id format" "$err_log2"; then
  pass "--session 'not-a-uuid' rejected (defense-in-depth, non-traversal input)"
else
  fail "non-UUID --session not rejected: rc=$rc_bad"
fi

# --------------------------------------------------------------------------
# T-LOCAL-5 (cycle 22 F-03 MEDIUM): RFC 4122 strict pattern validation
# --------------------------------------------------------------------------
# 旧 `^[0-9a-f-]{36}$` は hyphen 位置を強制せず、36 字 hex 連続 (hyphen 0 個) や hyphen 位置の
# 異なる 36 字 hex も valid 扱いだった。cycle 22 で
# `^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$` (RFC 4122 strict) に強化したため、
# 非準拠形式が reject されることを pin する (将来 SESSION_ID を別 context で流用したときの
# spec drift で脆弱性化を防ぐ defense-in-depth)。
err_log_rfc1="$TD/err-rfc1.log"
set +e
(cd "$TD" && bash "$HOOK" create --session "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
  --phase "p" --issue 1 --branch "b" --pr 0 --next "n" >/dev/null 2>"$err_log_rfc1")
rc_rfc1=$?
set -e
if [ "$rc_rfc1" -ne 0 ] && grep -q "invalid session_id format" "$err_log_rfc1"; then
  pass "T-LOCAL-5 (cycle 22 F-03): hyphen 無し 36 字 hex は RFC 4122 非準拠で reject"
else
  fail "T-LOCAL-5: hyphen 無し 36 字 hex が reject されない (RFC 4122 strict 退行): rc=$rc_rfc1"
fi

err_log_rfc2="$TD/err-rfc2.log"
set +e
# 9-3-4-4-12 (合計 36 字、hyphen 4 個だが位置が 8-4-4-4-12 と異なる)
(cd "$TD" && bash "$HOOK" create --session "aaaaaaaaa-aaa-aaaa-aaaa-aaaaaaaaaaaa" \
  --phase "p" --issue 1 --branch "b" --pr 0 --next "n" >/dev/null 2>"$err_log_rfc2")
rc_rfc2=$?
set -e
if [ "$rc_rfc2" -ne 0 ] && grep -q "invalid session_id format" "$err_log_rfc2"; then
  pass "T-LOCAL-5 (cycle 22 F-03): hyphen 位置不正な 36 字 hex は RFC 4122 非準拠で reject"
else
  fail "T-LOCAL-5: hyphen 位置不正な 36 字 hex が reject されない: rc=$rc_rfc2"
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
# TC-SESSION-PATCH (PR #688 cycle 6 F-03): patch mode で session_id が書き戻される
#
# resume 時の所有権移転 semantics: 別 session が作成した flow-state を引き継ぐ caller が
# 自身の session_id を patch で書き戻すことで、後続の stop-guard / state-read 等が
# 「現在の所有 session」として認識する。cycle 5 で legacy direct jq write を patch 経由化した際に
# session_id 書き戻しが drop されたため、cycle 6 で patch filter に session_id 条件付き update を追加。
# --------------------------------------------------------------------------
echo ""
echo "TC-SESSION-PATCH (cycle 6 F-03): patch mode writes back session_id"
TD=$(make_test_dir); cleanup_dirs+=("$TD")
write_config "$TD" 2
SID="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
write_session_id "$TD" "$SID"
(cd "$TD" && bash "$HOOK" create \
  --phase "p" --issue 1 --branch "b" --pr 0 --next "n" >/dev/null 2>&1)
TARGET="$TD/.rite/sessions/$SID.flow-state"

# Verify create wrote the session_id
created_sid=$(jq -r '.session_id // ""' "$TARGET")
if [ "$created_sid" = "$SID" ]; then
  pass "create mode wrote initial session_id"
else
  fail "create did not set session_id: got '$created_sid'"
fi

# Simulate session_id drift / corruption (e.g., previous owner left a stale value in the file
# while .rite-session-id has been updated to the current owner). resume.md cycle 5 (旧実装)
# は legacy direct jq write で `.session_id = $sid` を書き戻すことで所有権メタデータを再同期
# していたが、cycle 5 で patch 経由化した際に session_id 書き戻しが drop された。
# このテストは patch mode が file 内の stale session_id を `--session` (or auto-resolved
# .rite-session-id) で上書きすることを検証する。
tmp=$(mktemp); jq '.session_id = "stale-or-other-session-uuid"' "$TARGET" > "$tmp" && mv "$tmp" "$TARGET"

(cd "$TD" && bash "$HOOK" patch \
  --phase "p" --next "n2" --active true --session "$SID" >/dev/null 2>&1)
patched_sid=$(jq -r '.session_id // ""' "$TARGET")
if [ "$patched_sid" = "$SID" ]; then
  pass "patch mode writes back session_id (overrides stale value with caller's session)"
else
  fail "patch did not update session_id: got '$patched_sid' expected '$SID'"
fi

# Negative case: legacy mode + .rite-session-id 不在 → SESSION 解決が空 → session_id 更新しない
# (caller が session を持たない場合に既存値を上書き破壊しない契約の検証)
TD2=$(make_test_dir); cleanup_dirs+=("$TD2")
write_config "$TD2" 1  # legacy mode (schema_version=1)
# .rite-session-id 作らない
echo '{"phase":"p","next_action":"n","session_id":"original-uuid-keepme","active":true}' \
  > "$TD2/.rite-flow-state"
(cd "$TD2" && bash "$HOOK" patch \
  --phase "p" --next "n2" --active true >/dev/null 2>&1)
kept_sid=$(jq -r '.session_id // ""' "$TD2/.rite-flow-state")
if [ "$kept_sid" = "original-uuid-keepme" ]; then
  pass "patch mode without resolved session preserves existing session_id (no destructive overwrite)"
else
  fail "patch overwrote session_id with empty: got '$kept_sid'"
fi

# --------------------------------------------------------------------------
# TC-AC-4-SAME-SESSION-FALLBACK (PR #688 cycle 32 F-05 fix — refines cycle 30 F-01):
#
# **Same-session legacy** (legacy.session_id matches current sid) において writer fallback が
# 機能することを pin する。cycle 31 F-01 で「cross-session takeover が silent corruption」を
# CRITICAL 認定したため、cycle 32 で fallback を session-id 一致時のみに限定。本 TC は
# 「legitimate な same-session fallback」が引き続き機能することを assert する。
#
# F-05 修正: fixture OLD phase と patch 引数 phase を異なる値に分離 (cycle 30 では同値で dead
# assertion だった)。これにより pre-fix base に対し phase assertion が確実に FAIL し identification
# power を持つ。
# --------------------------------------------------------------------------
echo ""
echo "TC-AC-4-SAME-SESSION-FALLBACK (cycle 32 F-05): writer falls back to legacy for same-session, with phase divergence"
TD=$(make_test_dir); cleanup_dirs+=("$TD")
write_config "$TD" 2
CURR_SID="22222222-2222-2222-2222-222222222222"
write_session_id "$TD" "$CURR_SID"

# legacy file = SAME session (session_id matches CURR_SID), active=false, OLD phase
cat > "$TD/.rite-flow-state" <<EOF
{
  "schema_version": 2,
  "active": false,
  "issue_number": 42,
  "branch": "feat/foo",
  "phase": "phase4_pre_resume",
  "previous_phase": "phase3",
  "pr_number": 100,
  "parent_issue_number": 0,
  "next_action": "old next",
  "updated_at": "2026-04-01T00:00:00Z",
  "session_id": "$CURR_SID",
  "last_synced_phase": "phase3",
  "error_count": 0,
  "wm_comment_id": 0
}
EOF

# Verify per-session for CURR_SID does NOT exist (precondition)
if [ -f "$TD/.rite/sessions/$CURR_SID.flow-state" ]; then
  fail "TC-AC-4-SAME-SESSION-FALLBACK precondition: per-session for current sid unexpectedly exists"
else
  pass "TC-AC-4-SAME-SESSION-FALLBACK precondition: per-session for current sid absent"
fi

# Run patch with --if-exists and --session $CURR_SID (matches helper's invocation pattern)
# Note: NEW phase differs from OLD fixture phase (F-05 fix — gives identification power)
set +e
(cd "$TD" && bash "$HOOK" patch \
  --phase "phase5_post_review" \
  --next "resumed by cycle 32 fix" \
  --active true \
  --if-exists \
  --session "$CURR_SID" >/dev/null 2>&1)
rc=$?
set -e

if [ "$rc" -eq 0 ]; then
  pass "TC-AC-4-SAME-SESSION-FALLBACK: patch exit 0"
else
  fail "TC-AC-4-SAME-SESSION-FALLBACK: patch wrong exit: $rc"
fi

# Verify legacy file was actually updated
legacy_active=$(jq -r '.active' "$TD/.rite-flow-state")
legacy_sid=$(jq -r '.session_id' "$TD/.rite-flow-state")
legacy_phase=$(jq -r '.phase' "$TD/.rite-flow-state")

if [ "$legacy_active" = "true" ]; then
  pass "TC-AC-4-SAME-SESSION-FALLBACK: legacy active flipped to true"
else
  fail "TC-AC-4-SAME-SESSION-FALLBACK: legacy active still '$legacy_active'"
fi

if [ "$legacy_sid" = "$CURR_SID" ]; then
  pass "TC-AC-4-SAME-SESSION-FALLBACK: legacy session_id preserved (same session)"
else
  fail "TC-AC-4-SAME-SESSION-FALLBACK: legacy session_id is '$legacy_sid', expected '$CURR_SID'"
fi

# F-05 fix: phase assertion has identification power because fixture OLD phase
# (phase4_pre_resume) differs from patch arg new phase (phase5_post_review)
if [ "$legacy_phase" = "phase5_post_review" ]; then
  pass "TC-AC-4-SAME-SESSION-FALLBACK: legacy phase updated (phase4_pre_resume → phase5_post_review)"
else
  fail "TC-AC-4-SAME-SESSION-FALLBACK: legacy phase is '$legacy_phase', expected 'phase5_post_review'"
fi

if [ ! -f "$TD/.rite/sessions/$CURR_SID.flow-state" ]; then
  pass "TC-AC-4-SAME-SESSION-FALLBACK: per-session NOT created (writer used legacy path)"
else
  fail "TC-AC-4-SAME-SESSION-FALLBACK: per-session unexpectedly created"
fi

# --------------------------------------------------------------------------
# TC-AC-4-CROSS-SESSION-REFUSED (PR #688 cycle 32 F-01 CRITICAL fix):
#
# **Cross-session legacy** (legacy.session_id != current sid) において writer fallback が
# REFUSE されることを pin する。cycle 30 fix の simple fallback は jq per-field merge で
# silent metadata corruption (issue_number / branch / pr_number が別 session の値を保持) を
# 引き起こしていた CRITICAL silent regression を、cycle 32 で fail-safe に修正。
# Setup: schema_v=2 + valid sid + per-session 不在 + legacy が別 session の遺物
# 期待挙動: patch は exit 0 (silent skip on per-session absent via --if-exists)、
#          legacy は **完全に未変更**、cross-session corruption が起きない
# --------------------------------------------------------------------------
echo ""
echo "TC-AC-4-CROSS-SESSION-REFUSED (cycle 32 F-01): writer refuses fallback when legacy belongs to another session"
TD=$(make_test_dir); cleanup_dirs+=("$TD")
write_config "$TD" 2
CURR_SID="22222222-2222-2222-2222-222222222222"
OTHER_SID="11111111-1111-1111-1111-111111111111"
write_session_id "$TD" "$CURR_SID"

# legacy file = OTHER session's residue
cat > "$TD/.rite-flow-state" <<EOF
{
  "schema_version": 2,
  "active": false,
  "issue_number": 999,
  "branch": "fix/other-session-branch",
  "phase": "phase5_other_session",
  "pr_number": 999,
  "next_action": "other session action",
  "updated_at": "2026-04-01T00:00:00Z",
  "session_id": "$OTHER_SID",
  "error_count": 5
}
EOF

# Capture stderr to verify WORKFLOW_INCIDENT emit
stderr_file=$(mktemp /tmp/rite-tc-cross-stderr-XXXXXX)
set +e
(cd "$TD" && bash "$HOOK" patch \
  --phase "phase5_post_review" \
  --next "resumed by cycle 32 fix" \
  --active true \
  --if-exists \
  --session "$CURR_SID" 2>"$stderr_file")
rc=$?
set -e

if [ "$rc" -eq 0 ]; then
  pass "TC-AC-4-CROSS-SESSION-REFUSED: patch exit 0 (silent skip via --if-exists)"
else
  fail "TC-AC-4-CROSS-SESSION-REFUSED: patch unexpected exit: $rc"
fi

# CRITICAL invariant: legacy file must be UNCHANGED (cross-session corruption refused)
legacy_active=$(jq -r '.active' "$TD/.rite-flow-state")
legacy_sid=$(jq -r '.session_id' "$TD/.rite-flow-state")
legacy_phase=$(jq -r '.phase' "$TD/.rite-flow-state")
legacy_issue=$(jq -r '.issue_number' "$TD/.rite-flow-state")
legacy_branch=$(jq -r '.branch' "$TD/.rite-flow-state")

if [ "$legacy_active" = "false" ] && [ "$legacy_sid" = "$OTHER_SID" ] && \
   [ "$legacy_phase" = "phase5_other_session" ] && [ "$legacy_issue" = "999" ] && \
   [ "$legacy_branch" = "fix/other-session-branch" ]; then
  pass "TC-AC-4-CROSS-SESSION-REFUSED: legacy file completely unchanged (cross-session corruption refused)"
else
  fail "TC-AC-4-CROSS-SESSION-REFUSED: legacy file modified — active=$legacy_active sid=$legacy_sid phase=$legacy_phase issue=$legacy_issue branch=$legacy_branch"
fi

# Verify WORKFLOW_INCIDENT sentinel was emitted to stderr
if grep -q 'WORKFLOW_INCIDENT=1; type=cross_session_takeover_refused' "$stderr_file"; then
  pass "TC-AC-4-CROSS-SESSION-REFUSED: WORKFLOW_INCIDENT sentinel emitted (observability confirmed)"
else
  fail "TC-AC-4-CROSS-SESSION-REFUSED: WORKFLOW_INCIDENT sentinel missing from stderr"
fi
rm -f "$stderr_file"

# --------------------------------------------------------------------------
# TC-AC-4-EMPTY-LEGACY-NO-FALLBACK (PR #688 cycle 32 F-02 HIGH fix):
#
# size-0 legacy のときに writer fallback が **発火しない** ことを pin する。
# 旧実装 (cycle 30): [ -f LEGACY ] のみで size-0 を「存在」扱い → fallback → jq 空出力 →
#   silent skip という silent failure 経路。
# 新実装 (cycle 32): [ -f LEGACY ] && [ -s LEGACY ] で size-0 を fallback 対象から除外。
# 期待挙動: --if-exists で silent skip (per-session 不在 + size-0 legacy → 両不在扱い)
# --------------------------------------------------------------------------
echo ""
echo "TC-AC-4-EMPTY-LEGACY-NO-FALLBACK (cycle 32 F-02): writer rejects size-0 legacy as fallback target"
TD=$(make_test_dir); cleanup_dirs+=("$TD")
write_config "$TD" 2
SID="44444444-4444-4444-4444-444444444444"
write_session_id "$TD" "$SID"
touch "$TD/.rite-flow-state"  # size 0

set +e
(cd "$TD" && bash "$HOOK" patch \
  --phase "x" --next "y" --active true --if-exists \
  --session "$SID" >/dev/null 2>&1)
rc=$?
set -e

if [ "$rc" -eq 0 ]; then
  pass "TC-AC-4-EMPTY-LEGACY-NO-FALLBACK: patch exit 0 (silent skip via --if-exists)"
else
  fail "TC-AC-4-EMPTY-LEGACY-NO-FALLBACK: patch unexpected exit: $rc"
fi

# Verify legacy file remains size 0 (writer did NOT write to size-0 legacy)
legacy_size=$(stat -c%s "$TD/.rite-flow-state" 2>/dev/null || stat -f%z "$TD/.rite-flow-state" 2>/dev/null)
if [ "$legacy_size" = "0" ]; then
  pass "TC-AC-4-EMPTY-LEGACY-NO-FALLBACK: legacy remains size 0 (no fallback to empty file)"
else
  fail "TC-AC-4-EMPTY-LEGACY-NO-FALLBACK: legacy size is $legacy_size (expected 0)"
fi

# Verify per-session was NOT created either
if [ ! -f "$TD/.rite/sessions/$SID.flow-state" ]; then
  pass "TC-AC-4-EMPTY-LEGACY-NO-FALLBACK: per-session NOT created (--if-exists silent skip)"
else
  fail "TC-AC-4-EMPTY-LEGACY-NO-FALLBACK: per-session unexpectedly created"
fi

# --------------------------------------------------------------------------
# verified-review cycle 36 F-05 + F-04 fix: writer-side metatest
# --------------------------------------------------------------------------
# 背景: cycle 36 F-05 で flow-state-update.test.sh の writer 側 `legacy_state_corrupt` sentinel
# emit を pin する TC が不在と指摘された。state-read.test.sh と異なり、本 test は writer 側の
# corrupt branch を test するための fixture (per-session 不在 + corrupt legacy + --if-exists patch)
# のセットアップが複雑なため、軽量な metatest 形式で「caller-side `2>/dev/null` redirection の
# source-pin」と「invalid_uuid:* arm の存在」を grep で確認する。これにより:
# (a) cycle 35 F-02 fix (`2>&1` → `2>/dev/null`) の writer 側 partial revert を検出
# (b) cycle 36 F-16 fix (invalid_uuid:* arm 追加) の writer 側 partial revert を検出
echo ""
echo "=== verified-review cycle 36 F-05 + F-04 fix: writer-side metatest ==="
flow_state_path="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")/flow-state-update.sh"
if grep -qE '_resolve-cross-session-guard\.sh.*2>/dev/null' "$flow_state_path"; then
  echo "  ✅ writer-side metatest 1: flow-state-update.sh contains '_resolve-cross-session-guard.sh ... 2>/dev/null' redirection"
  PASS=$((PASS+1))
else
  echo "  ❌ writer-side metatest 1: flow-state-update.sh の caller-side redirection が `2>/dev/null` でない (cycle 35 F-02 fix が revert された可能性)"
  FAIL=$((FAIL+1))
fi
if grep -q '^      invalid_uuid:\*)' "$flow_state_path"; then
  echo "  ✅ writer-side metatest 2: flow-state-update.sh has 'invalid_uuid:*)' case arm (F-16 fix)"
  PASS=$((PASS+1))
else
  echo "  ❌ writer-side metatest 2: flow-state-update.sh の 'invalid_uuid:*' arm が存在しない (cycle 36 F-16 fix が revert された可能性)"
  FAIL=$((FAIL+1))
fi
# defensive arm pattern check (`if cmd; then :; else rc=$?; fi` not `elif ! cmd; then rc=$?`)
if grep -qE '^[[:space:]]*if bash "\$SCRIPT_DIR/workflow-incident-emit\.sh"' "$flow_state_path"; then
  echo "  ✅ writer-side metatest 3: flow-state-update.sh uses canonical 'if cmd; then :; else rc=$?; fi' pattern (F-01 fix)"
  PASS=$((PASS+1))
else
  echo "  ❌ writer-side metatest 3: flow-state-update.sh が canonical if/else pattern を使っていない (F-01 anti-pattern が再発した可能性)"
  FAIL=$((FAIL+1))
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
