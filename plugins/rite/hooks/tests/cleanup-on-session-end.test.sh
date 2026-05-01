#!/bin/bash
# Tests for per-session cleanup on session end — Issue #672 / #684 (T-10 / AC-10)
#
# Purpose:
#   `session-end.sh` (Option A: 正常終了時の per-session file 削除) の cleanup が:
#     (a) 当該 session の per-session file (`.rite/sessions/{sid}.flow-state`) を削除
#     (b) **兄弟 session** の file には影響なし (blast radius 0)
#     (c) `.rite-flow-state.legacy.*` backup には影響なし (#747 cycle 3/4 regression)
#     (d) cleanup 後は state-read.sh が ENOENT 経路 (default 値) を返し resume 不能
#     (e) 異なる cwd (別 repo) の per-session file には影響なし
#   を verify する。
#
# Differentiation from session-end.test.sh:
#   既存 `session-end.test.sh` の TC-680-A は「per-session file removed after
#   session-end (AC-10)」を最低限 verify している。本テストはそれを起点に、
#   **blast radius 0 の structural guarantee** (兄弟 / backup / 別 cwd) を独立 TC
#   として追加で固定する。Wiki 経験則「新規 file 命名と既存 find glob が collision
#   して silent 削除を起こす」を踏まえ、cleanup logic が legacy backup を巻き添えに
#   しないことを mutation 視点でも verify する。
#
# Test cases:
#   TC-1: 当該 session の per-session file 削除 (TC-680-A 等価、再 pin)
#   TC-2: 兄弟 session の file は影響なし (blast radius 0)
#   TC-3: `.rite-flow-state.legacy.*` backup は影響なし (#747 cycle 3/4 regression guard)
#   TC-4: cleanup 後 state-read.sh は default 値 (ENOENT 経路) を返す (resume 不能)
#   TC-5: 異なる cwd (別 repo) の per-session file は影響なし
#   TC-6: cleanup 後 sessions ディレクトリ自体は残る (mkdir レース回避)
#
# Out of scope:
#   - lifecycle warning (create_interview / cleanup) → session-end.test.sh TC-475/608
#   - JQ atomic-write WARN → session-end.test.sh TC-749-JQ-WRITE-WARN
#   - Stale tempfile cleanup → session-end.test.sh TC-009/010
#
# Usage: bash plugins/rite/hooks/tests/cleanup-on-session-end.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$HOOKS_DIR/session-end.sh"
STATE_READ="$HOOKS_DIR/state-read.sh"
PASS=0
FAIL=0
FAILED_NAMES=()

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi

# ---- helpers ----
cleanup_dirs=()
cleanup() {
  local d
  for d in "${cleanup_dirs[@]:-}"; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
  done
  return 0
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); echo "  ❌ FAIL: $1"; }

make_test_dir() {
  local d
  d=$(mktemp -d) || { echo "ERROR: mktemp -d failed" >&2; return 1; }
  cleanup_dirs+=("$d")
  cat > "$d/rite-config.yml" <<EOF
flow_state:
  schema_version: 2
EOF
  echo "$d"
}

# Run session-end with a stdin payload describing the cwd
run_session_end() {
  local cwd="$1"
  echo "{\"cwd\":\"$cwd\"}" | bash "$HOOK" 2>&1
}

echo "=== cleanup-on-session-end tests (Issue #672 / #684 T-10 AC-10) ==="
echo ""

# -------------------------------------------------------------------------
# TC-1: per-session file 削除 (TC-680-A 等価、再 pin)
# -------------------------------------------------------------------------
echo "TC-1: per-session file 削除 (AC-10 base contract)"
TD=$(make_test_dir)
SID="aaaaaaaa-1010-1010-1010-101010101010"
echo "$SID" > "$TD/.rite-session-id"
mkdir -p "$TD/.rite/sessions"
target_file="$TD/.rite/sessions/${SID}.flow-state"
echo "{\"active\":true,\"phase\":\"phase5_test\",\"issue_number\":684,\"branch\":\"feat/x\",\"session_id\":\"$SID\"}" > "$target_file"

run_session_end "$TD" >/dev/null
if [ ! -f "$target_file" ]; then
  pass "TC-1.1: per-session file removed"
else
  fail "TC-1.1: per-session file still exists"
fi

# -------------------------------------------------------------------------
# TC-2: 兄弟 session の file は影響なし (blast radius 0)
# -------------------------------------------------------------------------
echo "TC-2: 兄弟 session file への blast radius 0"
TD=$(make_test_dir)
SID_OWN="bbbbbbbb-1010-1010-1010-101010101010"
SID_SIB="cccccccc-1010-1010-1010-101010101010"
echo "$SID_OWN" > "$TD/.rite-session-id"
mkdir -p "$TD/.rite/sessions"
own_file="$TD/.rite/sessions/${SID_OWN}.flow-state"
sib_file="$TD/.rite/sessions/${SID_SIB}.flow-state"
echo "{\"active\":true,\"phase\":\"own_phase\",\"issue_number\":684,\"branch\":\"feat/own\",\"session_id\":\"$SID_OWN\"}" > "$own_file"
echo "{\"active\":true,\"phase\":\"sib_phase\",\"issue_number\":684,\"branch\":\"feat/sib\",\"session_id\":\"$SID_SIB\"}" > "$sib_file"
sib_hash_before=$(sha1sum "$sib_file" | awk '{print $1}')

run_session_end "$TD" >/dev/null

if [ ! -f "$own_file" ]; then
  pass "TC-2.1: own per-session file removed"
else
  fail "TC-2.1: own file still exists"
fi
if [ -f "$sib_file" ]; then
  sib_hash_after=$(sha1sum "$sib_file" | awk '{print $1}')
  if [ "$sib_hash_before" = "$sib_hash_after" ]; then
    pass "TC-2.2: sibling session file untouched (byte-identical)"
  else
    fail "TC-2.2: sibling file mutated despite no ownership claim"
  fi
else
  fail "TC-2.2: sibling session file removed (blast radius leak)"
fi

# -------------------------------------------------------------------------
# TC-3: `.rite-flow-state.legacy.*` backup は影響なし (#747 cycle 3/4 regression)
# -------------------------------------------------------------------------
echo "TC-3: legacy backup file への blast radius 0 (#747 regression guard)"
TD=$(make_test_dir)
SID="dddddddd-1010-1010-1010-101010101010"
echo "$SID" > "$TD/.rite-session-id"
mkdir -p "$TD/.rite/sessions"
echo "{\"active\":true,\"phase\":\"phase5\",\"issue_number\":684,\"session_id\":\"$SID\"}" \
  > "$TD/.rite/sessions/${SID}.flow-state"
# Pre-place a migration backup (per migrate-flow-state.sh naming)
backup_file="$TD/.rite-flow-state.legacy.20260101120000"
echo '{"legacy":"backup","schema_version":1}' > "$backup_file"
backup_hash_before=$(sha1sum "$backup_file" | awk '{print $1}')

run_session_end "$TD" >/dev/null

if [ -f "$backup_file" ]; then
  backup_hash_after=$(sha1sum "$backup_file" | awk '{print $1}')
  if [ "$backup_hash_before" = "$backup_hash_after" ]; then
    pass "TC-3.1: legacy backup file untouched"
  else
    fail "TC-3.1: legacy backup mutated"
  fi
else
  fail "TC-3.1: legacy backup deleted by session-end (#747 regression)"
fi

# -------------------------------------------------------------------------
# TC-4: cleanup 後 state-read.sh は default 値を返す (resume 不能)
# -------------------------------------------------------------------------
echo "TC-4: cleanup 後 state-read.sh は default 値を返す (ENOENT 経路)"
TD=$(make_test_dir)
SID="eeeeeeee-1010-1010-1010-101010101010"
echo "$SID" > "$TD/.rite-session-id"
mkdir -p "$TD/.rite/sessions"
echo "{\"active\":true,\"phase\":\"phase5_pre_cleanup\",\"issue_number\":684,\"session_id\":\"$SID\"}" \
  > "$TD/.rite/sessions/${SID}.flow-state"

# Sanity check pre-cleanup
phase_before=$(cd "$TD" && bash "$STATE_READ" --field phase --default "default_unset")
if [ "$phase_before" = "phase5_pre_cleanup" ]; then
  pass "TC-4.0 (pre): state-read returns the live state before cleanup"
else
  fail "TC-4.0 (pre): expected phase5_pre_cleanup, got '$phase_before'"
fi

run_session_end "$TD" >/dev/null

phase_after=$(cd "$TD" && bash "$STATE_READ" --field phase --default "default_unset")
if [ "$phase_after" = "default_unset" ]; then
  pass "TC-4.1: state-read returns default after cleanup (resume not possible)"
else
  fail "TC-4.1: state-read returned '$phase_after' instead of default — cleanup incomplete"
fi

# -------------------------------------------------------------------------
# TC-5: 異なる cwd (別 repo) の per-session file は影響なし
# -------------------------------------------------------------------------
echo "TC-5: 別 cwd の per-session file への blast radius 0"
TD_A=$(make_test_dir)
TD_B=$(make_test_dir)
SID_A="11111111-1010-1010-1010-101010101010"
SID_B="22222222-1010-1010-1010-101010101010"
echo "$SID_A" > "$TD_A/.rite-session-id"
echo "$SID_B" > "$TD_B/.rite-session-id"
mkdir -p "$TD_A/.rite/sessions" "$TD_B/.rite/sessions"
file_a="$TD_A/.rite/sessions/${SID_A}.flow-state"
file_b="$TD_B/.rite/sessions/${SID_B}.flow-state"
echo "{\"active\":true,\"phase\":\"phase_a\",\"issue_number\":684,\"session_id\":\"$SID_A\"}" > "$file_a"
echo "{\"active\":true,\"phase\":\"phase_b\",\"issue_number\":684,\"session_id\":\"$SID_B\"}" > "$file_b"
b_hash_before=$(sha1sum "$file_b" | awk '{print $1}')

# session-end run only on TD_A
run_session_end "$TD_A" >/dev/null

if [ ! -f "$file_a" ] && [ -f "$file_b" ]; then
  b_hash_after=$(sha1sum "$file_b" | awk '{print $1}')
  if [ "$b_hash_before" = "$b_hash_after" ]; then
    pass "TC-5.1: TD_A cleanup did not affect TD_B (cross-cwd isolation)"
  else
    fail "TC-5.1: TD_B file mutated by TD_A cleanup"
  fi
else
  fail "TC-5.1: file_a_exists=$([ -f "$file_a" ] && echo y || echo n) file_b_exists=$([ -f "$file_b" ] && echo y || echo n)"
fi

# -------------------------------------------------------------------------
# TC-6: cleanup 後 sessions ディレクトリ自体は残る
# -------------------------------------------------------------------------
echo "TC-6: cleanup 後 sessions ディレクトリ自体は残る (race-free re-create)"
TD=$(make_test_dir)
SID="ffffffff-1010-1010-1010-101010101010"
echo "$SID" > "$TD/.rite-session-id"
mkdir -p "$TD/.rite/sessions"
echo "{\"active\":true,\"phase\":\"phase5\",\"issue_number\":684,\"session_id\":\"$SID\"}" \
  > "$TD/.rite/sessions/${SID}.flow-state"

run_session_end "$TD" >/dev/null

if [ -d "$TD/.rite/sessions" ]; then
  pass "TC-6.1: sessions ディレクトリは cleanup 後も存在 (subsequent session can mkdir-free)"
else
  fail "TC-6.1: sessions ディレクトリが消失した — race window 発生の余地"
fi

# -------------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------------
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
echo "All cleanup-on-session-end tests passed!"
