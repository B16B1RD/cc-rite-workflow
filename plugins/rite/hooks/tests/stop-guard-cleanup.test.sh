#!/bin/bash
# plugins/rite/hooks/tests/stop-guard-cleanup.test.sh
#
# Unit test for stop-guard.sh block behavior during cleanup Phase 4.W.
# Issue #621: AC-3 automation (stop-guard が cleanup_pre_ingest / cleanup_post_ingest
# phase で end_turn を block し、session log にその痕跡が残ることを verify)
#
# Relationship with existing stop-guard.test.sh TC-608-A〜H:
# - TC-608-A/B/D/E/F/H は HINT-specific 文言を細かく pin し、文言 drift を検知する
#   regression-detection 最適化型 fixture。`bash plugins/rite/hooks/tests/run-tests.sh` から
#   自動実行される。
# - 本 fixture は「standalone で独立実行可能な fixture ベース」の役割を担う。
#   runner 外で単体起動したいケース (個別 debug / CI 部分実行) に対応し、cleanup 系 3 phase
#   (cleanup / cleanup_pre_ingest / cleanup_post_ingest) の block と terminal 経路をまとめて verify。
#   HINT-specific 文言は Test 1/2 で pin するが、同じ文言を TC-608-B/H も pin しているため、
#   片方の regression でもう片方が catch する相補関係を形成する。
# 本 fixture は `*.test.sh` 命名規約に従い、run-tests.sh の glob に拾われる。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# SCRIPT_DIR = plugins/rite/hooks/tests → 4 levels up to repo root
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
STOP_GUARD="$REPO_ROOT/plugins/rite/hooks/stop-guard.sh"

if [ ! -x "$STOP_GUARD" ]; then
  echo "FAIL: stop-guard.sh not executable at $STOP_GUARD" >&2
  exit 1
fi

# Isolated fixture workspace (cleanup() 関数定義 → trap 登録 → mktemp の順で race window 排除)
FIXTURE_DIR=""
cleanup() { [ -n "${FIXTURE_DIR:-}" ] && rm -rf "$FIXTURE_DIR"; }
trap cleanup EXIT INT TERM HUP

FIXTURE_DIR=$(mktemp -d /tmp/rite-test-stop-guard-XXXXXX) || {
  echo "FAIL: mktemp -d failed (/tmp が full / read-only / permission denied)" >&2
  exit 1
}

SESSION_ID="00000000-0000-0000-0000-000000000001"

# Fabricate .rite-flow-state for the given phase with active=true
# $1: phase name
# $2: previous_phase (for whitelist check)
make_state() {
  local phase="$1"
  local prev="${2:-cleanup}"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")
  cat > "$FIXTURE_DIR/.rite-flow-state" <<EOF
{
  "active": true,
  "issue_number": 621,
  "branch": "fix/issue-621-test",
  "phase": "$phase",
  "previous_phase": "$prev",
  "pr_number": 0,
  "parent_issue_number": 0,
  "next_action": "test fixture",
  "updated_at": "$ts",
  "session_id": "$SESSION_ID",
  "error_count": 0
}
EOF
}

# Run stop-guard with a constructed hook input JSON, capture exit + stderr.
# stderr_file は FIXTURE_DIR 内に配置する (F-15: trap cleanup が一括削除、orphan 防止)。
# $1: phase
# $2: previous_phase
STDERR_CONTENT=""
run_guard() {
  local phase="$1"
  local prev="$2"
  make_state "$phase" "$prev"
  local input
  input=$(printf '{"cwd":"%s","session_id":"%s"}' "$FIXTURE_DIR" "$SESSION_ID")
  local stderr_file
  stderr_file=$(mktemp "$FIXTURE_DIR/stderr.XXXXXX")
  STDERR_CONTENT=""  # stale 混入防止 (明示 reset)
  printf '%s' "$input" | bash "$STOP_GUARD" 2>"$stderr_file"
  local rc=$?
  STDERR_CONTENT=$(cat "$stderr_file")
  return "$rc"
}

# Assertion helpers
PASS=0
FAIL=0
assert() {
  local name="$1"
  local expected="$2"
  local actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    echo "ok  - $name"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL - $name (expected: $expected, actual: $actual)"
  fi
}
assert_contains() {
  local name="$1"
  local needle="$2"
  local haystack="$3"
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    PASS=$((PASS + 1))
    echo "ok  - $name"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL - $name (missing: $needle)"
    printf '  stderr: %s\n' "$haystack" | head -5
  fi
}
assert_not_contains() {
  local name="$1"
  local needle="$2"
  local haystack="$3"
  if ! printf '%s' "$haystack" | grep -qF "$needle"; then
    PASS=$((PASS + 1))
    echo "ok  - $name"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL - $name (unexpected presence of: $needle)"
    printf '  stderr: %s\n' "$haystack" | head -5
  fi
}

# Test 1: cleanup_pre_ingest phase should block with exit 2 and emit HINT-specific phrase
echo "# Test 1: cleanup_pre_ingest blocks end_turn + HINT specific pin"
run_guard "cleanup_pre_ingest" "cleanup"
rc=$?
assert "cleanup_pre_ingest exits 2" "2" "$rc"
assert_contains "stderr contains Phase:" "Phase:" "$STDERR_CONTENT"
assert_contains "stderr contains cleanup_pre_ingest" "cleanup_pre_ingest" "$STDERR_CONTENT"
# HINT-specific phrase pin (F-13): fallback STOP_MSG でも Phase 名は出るが、下記文言は
# cleanup_pre_ingest case arm 内にのみ存在するため、arm 削除 regression を検知できる。
assert_contains "stderr contains 'Phase 4.W.2 phase recorded'" "Phase 4.W.2 phase recorded" "$STDERR_CONTENT"

# Test 2: cleanup_post_ingest phase should block with exit 2 and emit HINT-specific phrase
echo "# Test 2: cleanup_post_ingest blocks end_turn + HINT specific pin"
run_guard "cleanup_post_ingest" "cleanup_pre_ingest"
rc=$?
assert "cleanup_post_ingest exits 2" "2" "$rc"
assert_contains "stderr contains Phase:" "Phase:" "$STDERR_CONTENT"
assert_contains "stderr contains cleanup_post_ingest" "cleanup_post_ingest" "$STDERR_CONTENT"
# HINT-specific phrase pin (F-13): cleanup_post_ingest case arm 内の TC-608-H pinned phrase を
# 併せて検査することで、文言 drift / case arm 削除 regression を検知。
assert_contains "stderr contains 'rite:wiki:ingest returned'" "rite:wiki:ingest returned" "$STDERR_CONTENT"
assert_contains "stderr contains 'Phase 5 Completion Report has NOT been output'" "Phase 5 Completion Report has NOT been output" "$STDERR_CONTENT"

# Test 3: cleanup phase (Phase 1-4 protection) should also block
echo "# Test 3: cleanup phase blocks end_turn"
run_guard "cleanup" ""
rc=$?
assert "cleanup exits 2" "2" "$rc"
assert_contains "stderr contains Phase:" "Phase:" "$STDERR_CONTENT"

# Test 4: cleanup_completed with active=false should allow stop (exit 0) and NOT emit STOP_MSG
echo "# Test 4: cleanup_completed + active:false allows stop (negative assertion)"
cat > "$FIXTURE_DIR/.rite-flow-state" <<EOF
{
  "active": false,
  "issue_number": 621,
  "branch": "fix/issue-621-test",
  "phase": "cleanup_completed",
  "previous_phase": "cleanup_post_ingest",
  "pr_number": 0,
  "parent_issue_number": 0,
  "next_action": "none",
  "updated_at": "$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")",
  "session_id": "$SESSION_ID",
  "error_count": 0
}
EOF
input=$(printf '{"cwd":"%s","session_id":"%s"}' "$FIXTURE_DIR" "$SESSION_ID")
stderr_file=$(mktemp "$FIXTURE_DIR/stderr.XXXXXX")
printf '%s' "$input" | bash "$STOP_GUARD" 2>"$stderr_file"
rc=$?
test4_stderr=$(cat "$stderr_file")
assert "cleanup_completed (active:false) exits 0" "0" "$rc"
# Negative assertion (F-14): active=false で誤って STOP_MSG が emit される regression を検知。
# stop-guard.sh は terminal 経路では "Normal operation" / "stop prevented" を出力しないはず。
assert_not_contains "Test 4 stderr does not contain 'stop prevented'" "stop prevented" "$test4_stderr"
assert_not_contains "Test 4 stderr does not contain 'Normal operation'" "Normal operation" "$test4_stderr"

echo ""
echo "# Summary: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
