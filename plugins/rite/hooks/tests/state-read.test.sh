#!/bin/bash
# Tests for hooks/state-read.sh — multi-state read helper (Issue #687).
#
# Covers Issue #687 acceptance criteria:
#   AC-4 — multi-state file resolver behaves correctly when:
#          (a) per-session file exists with another session's residue in legacy file
#          (b) per-session file is absent and legacy file holds the live state
#          (c) both files are absent and the caller-supplied default is returned
#          (d) injection-style field names are rejected
#          (e) .rite-session-id is absent so the helper falls back to legacy
#   AC-7 — regression test added under hooks/tests/ and run-tests.sh-discoverable
#
# Usage: bash plugins/rite/hooks/tests/state-read.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../state-read.sh"

if [ ! -x "$HOOK" ]; then
  echo "ERROR: state-read.sh missing or not executable: $HOOK" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi

PASS=0
FAIL=0
FAILED_NAMES=()

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  ✅ $name"
    PASS=$((PASS+1))
  else
    echo "  ❌ $name"
    echo "     expected: $expected"
    echo "     actual:   $actual"
    FAIL=$((FAIL+1))
    FAILED_NAMES+=("$name")
  fi
}

# Each test uses its own sandbox so failures don't pollute siblings.
make_sandbox() {
  local d
  d=$(mktemp -d)
  (
    cd "$d"
    git init -q 2>/dev/null
    echo a > a && git add a 2>/dev/null
    git -c user.email=t@test.local -c user.name=test commit -q -m init 2>/dev/null
  )
  echo "$d"
}

write_config_v2() {
  local d="$1"
  cat > "$d/rite-config.yml" <<EOF
flow_state:
  schema_version: 2
EOF
}

write_session_id() {
  local d="$1" sid="$2"
  echo "$sid" > "$d/.rite-session-id"
}

write_per_session() {
  local d="$1" sid="$2" json="$3"
  mkdir -p "$d/.rite/sessions"
  printf '%s' "$json" > "$d/.rite/sessions/${sid}.flow-state"
}

write_legacy() {
  local d="$1" json="$2"
  printf '%s' "$json" > "$d/.rite-flow-state"
}

run_helper() {
  local d="$1"
  shift
  (cd "$d" && bash "$HOOK" "$@" 2>&1)
}

# --- TC-1: per-session present + legacy holding another session's residue ---
echo "TC-1: per-session present + legacy 別 session 残骸 → per-session 値返却 (#687 core)"
SBX=$(make_sandbox)
write_config_v2 "$SBX"
SID="11111111-1111-1111-1111-111111111111"
write_session_id "$SBX" "$SID"
write_per_session "$SBX" "$SID" '{"schema_version":2,"phase":"phase2_post_work_memory","issue_number":687,"parent_issue_number":0,"session_id":"11111111-1111-1111-1111-111111111111"}'
write_legacy "$SBX" '{"phase":"phase5_post_stop_hook","issue_number":678,"parent_issue_number":42,"session_id":"22222222-2222-2222-2222-222222222222"}'
result=$(run_helper "$SBX" --field phase --default "")
assert_eq "TC-1.1: phase reads per-session (phase2_post_work_memory)" "phase2_post_work_memory" "$result"
result=$(run_helper "$SBX" --field issue_number --default 0)
assert_eq "TC-1.2: issue_number reads per-session (687)" "687" "$result"
result=$(run_helper "$SBX" --field parent_issue_number --default 0)
assert_eq "TC-1.3: parent_issue_number reads per-session (0, not legacy 42)" "0" "$result"
rm -rf "$SBX"

# --- TC-2: per-session absent + legacy present → legacy fallback ---
echo "TC-2: per-session 不在 + legacy 存在 → legacy fallback"
SBX=$(make_sandbox)
write_config_v2 "$SBX"
write_session_id "$SBX" "11111111-1111-1111-1111-111111111111"
# No per-session file written.
write_legacy "$SBX" '{"phase":"legacy_phase","loop_count":3}'
result=$(run_helper "$SBX" --field phase --default "")
assert_eq "TC-2.1: phase falls back to legacy" "legacy_phase" "$result"
result=$(run_helper "$SBX" --field loop_count --default 0)
assert_eq "TC-2.2: loop_count falls back to legacy" "3" "$result"
rm -rf "$SBX"

# --- TC-3: both absent → default ---
echo "TC-3: both absent → default returned"
SBX=$(make_sandbox)
write_config_v2 "$SBX"
write_session_id "$SBX" "11111111-1111-1111-1111-111111111111"
result=$(run_helper "$SBX" --field phase --default "default_phase")
assert_eq "TC-3.1: phase default returned" "default_phase" "$result"
result=$(run_helper "$SBX" --field parent_issue_number --default 0)
assert_eq "TC-3.2: parent_issue_number default 0" "0" "$result"
rm -rf "$SBX"

# --- TC-4: invalid field name rejected ---
echo "TC-4: invalid field name (path traversal style) → ERROR + exit 1"
SBX=$(make_sandbox)
write_config_v2 "$SBX"
write_session_id "$SBX" "11111111-1111-1111-1111-111111111111"
write_per_session "$SBX" "11111111-1111-1111-1111-111111111111" '{"phase":"x"}'
output=$(run_helper "$SBX" --field "../etc/passwd" --default "" 2>&1; echo "EXITCODE_$?")
case "$output" in
  *"ERROR: invalid field name"*"EXITCODE_1"*)
    echo "  ✅ TC-4.1: invalid field rejected with exit 1"
    PASS=$((PASS+1))
    ;;
  *)
    echo "  ❌ TC-4.1: invalid field should be rejected"
    echo "     got: $output"
    FAIL=$((FAIL+1))
    FAILED_NAMES+=("TC-4.1: invalid field rejection")
    ;;
esac
rm -rf "$SBX"

# --- TC-5: .rite-session-id absent → legacy fallback ---
echo "TC-5: .rite-session-id absent → legacy fallback"
SBX=$(make_sandbox)
write_config_v2 "$SBX"
# No .rite-session-id, but per-session file would exist if SID were known.
mkdir -p "$SBX/.rite/sessions"
printf '%s' '{"phase":"never_read"}' > "$SBX/.rite/sessions/11111111-1111-1111-1111-111111111111.flow-state"
write_legacy "$SBX" '{"phase":"legacy_when_no_sid"}'
result=$(run_helper "$SBX" --field phase --default "")
assert_eq "TC-5.1: phase falls back to legacy when .rite-session-id absent" "legacy_when_no_sid" "$result"
rm -rf "$SBX"

# --- TC-6 (additional safeguard): tampered .rite-session-id rejected, falls back to legacy ---
echo "TC-6: tampered .rite-session-id (non-UUID) → fallback to legacy (no path traversal)"
SBX=$(make_sandbox)
write_config_v2 "$SBX"
echo "../../../etc/passwd" > "$SBX/.rite-session-id"
write_legacy "$SBX" '{"phase":"safe_legacy"}'
result=$(run_helper "$SBX" --field phase --default "")
assert_eq "TC-6.1: tampered session_id ignored, legacy used" "safe_legacy" "$result"
rm -rf "$SBX"

# --- TC-7: schema_version=1 (or absent) routes directly to legacy even if SID + per-session exist ---
echo "TC-7: schema_version=1 routes to legacy"
SBX=$(make_sandbox)
cat > "$SBX/rite-config.yml" <<EOF
flow_state:
  schema_version: 1
EOF
SID="11111111-1111-1111-1111-111111111111"
write_session_id "$SBX" "$SID"
write_per_session "$SBX" "$SID" '{"phase":"never_read_v1"}'
write_legacy "$SBX" '{"phase":"v1_legacy"}'
result=$(run_helper "$SBX" --field phase --default "")
assert_eq "TC-7.1: schema_version=1 reads legacy not per-session" "v1_legacy" "$result"
rm -rf "$SBX"

# --- TC-8: flow_state: section present but schema_version: line missing (pipefail regression #687 follow-up) ---
echo "TC-8: flow_state セクションあり / schema_version 行なし → grep 不一致で pipefail silent failure しない"
SBX=$(make_sandbox)
# `flow_state:` セクションは存在するが `schema_version:` キーが欠落する degenerate config。
# `set -euo pipefail` 下で grep no-match (exit 1) が pipeline 全体 exit 1 を引き起こし、
# top-level 代入で set -e により helper が silent に exit 1 する regression を再現する設定。
# 修正後は `|| v=""` で吸収され、case "*)" 分岐で SCHEMA_VERSION="1" にフォールバックして
# 正常に legacy fallback の値を返すことを確認する。
cat > "$SBX/rite-config.yml" <<EOF
flow_state:
  enabled: true
EOF
write_legacy "$SBX" '{"phase":"degenerate_config_legacy"}'
# 注: SID 不在 + schema_version 行なし → SCHEMA_VERSION="1" fallback → legacy 直接 routing
result=$(run_helper "$SBX" --field phase --default "")
assert_eq "TC-8.1: schema_version 行欠落でも helper が exit 0 で完走し legacy を読む" "degenerate_config_legacy" "$result"
rm -rf "$SBX"

# --- TC-9: corrupt JSON state file → DEFAULT 返却 + exit 0 (defensive coverage) ---
echo "TC-9: corrupt JSON state file → DEFAULT fallback (state-read.sh:127 jq error path)"
SBX=$(make_sandbox)
write_config_v2 "$SBX"
SID="11111111-1111-1111-1111-111111111111"
write_session_id "$SBX" "$SID"
# truncated JSON (closing brace 欠落)
mkdir -p "$SBX/.rite/sessions"
printf '%s' '{"phase":"corrupt' > "$SBX/.rite/sessions/${SID}.flow-state"
result=$(run_helper "$SBX" --field phase --default "corrupt_default")
assert_eq "TC-9.1: corrupt JSON は DEFAULT を返す (silent fallback)" "corrupt_default" "$result"
rm -rf "$SBX"

# --- TC-10: JSON null value → caller default に正規化 (line 130-135) ---
echo "TC-10: JSON null value → caller default に正規化 (null 文字列を返さない)"
SBX=$(make_sandbox)
write_config_v2 "$SBX"
SID="11111111-1111-1111-1111-111111111111"
write_session_id "$SBX" "$SID"
write_per_session "$SBX" "$SID" '{"phase":null}'
# JSON null は jq -r で literal "null" 文字列になるため、helper が default に変換するか確認
result=$(run_helper "$SBX" --field phase --default "x")
assert_eq "TC-10.1: JSON null は default に正規化される" "x" "$result"
rm -rf "$SBX"

# --- TC-11: --default 省略時の挙動 → 空文字列を返す ---
echo "TC-11: --default 省略時 → 空文字列を返す (CLI default behaviour)"
SBX=$(make_sandbox)
write_config_v2 "$SBX"
SID="11111111-1111-1111-1111-111111111111"
write_session_id "$SBX" "$SID"
# field が存在しない state を作る
write_per_session "$SBX" "$SID" '{"phase":"x"}'
# --default を渡さずに存在しない field を読む
result=$(run_helper "$SBX" --field nonexistent_field)
assert_eq "TC-11.1: --default 省略 + field 不在 → 空文字列" "" "$result"
rm -rf "$SBX"

# --- Summary ---
echo ""
echo "─── state-read.test.sh summary ──────────────────────────"
echo "PASS: $PASS"
echo "FAIL: $FAIL"
if [ $FAIL -gt 0 ]; then
  echo ""
  echo "Failed tests:"
  for n in "${FAILED_NAMES[@]}"; do echo "  - $n"; done
  exit 1
fi
echo "All tests passed."
exit 0
