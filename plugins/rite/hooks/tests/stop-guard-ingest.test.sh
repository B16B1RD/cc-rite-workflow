#!/bin/bash
# plugins/rite/hooks/tests/stop-guard-ingest.test.sh
#
# Unit test for stop-guard.sh block behavior during ingest Phase 8.
# Issue #618: AC-4 automation (stop-guard が ingest_pre_lint / ingest_post_lint
# phase で end_turn を block し、manual_fallback_adopted workflow_incident sentinel
# を stderr に emit することを verify)
#
# Relationship with sibling stop-guard-cleanup.test.sh / stop-guard.test.sh:
# - stop-guard-cleanup.test.sh は cleanup_* phase 3 種の block と terminal 経路を verify
# - 本 fixture は ingest_* phase 3 種 (ingest_pre_lint / ingest_post_lint / ingest_completed)
#   の block と terminal 経路を verify。HINT-specific 文言 pin により stop-guard.sh の
#   case arm 削除 regression を catch する。
# - stop-guard.test.sh TC-618-* (future) と相補関係: 片方の文言 drift でもう片方が catch。
# 本 fixture は `*.test.sh` 命名規約に従い run-tests.sh の glob に拾われる。
#
# DRIFT-CHECK ANCHOR (semantic): plugins/rite/commands/wiki/ingest.md
# 🚨 Mandatory After Auto-Lint section / plugins/rite/hooks/stop-guard.sh
# ingest_pre_lint / ingest_post_lint case arm / plugins/rite/hooks/phase-transition-whitelist.sh
# ingest_pre_lint / ingest_post_lint entries と 3 site 対称。いずれかの構造変更時は本 test も
# 同時確認。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# SCRIPT_DIR = plugins/rite/hooks/tests → 4 levels up to repo root
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
STOP_GUARD="$REPO_ROOT/plugins/rite/hooks/stop-guard.sh"

if [ ! -x "$STOP_GUARD" ]; then
  echo "FAIL: stop-guard.sh not executable at $STOP_GUARD" >&2
  exit 1
fi

# Isolated fixture workspace (sibling stop-guard-cleanup.test.sh と同型 trap pattern)
FIXTURE_DIR=""
cleanup() { [ -n "${FIXTURE_DIR:-}" ] && rm -rf "$FIXTURE_DIR"; }
trap cleanup EXIT INT TERM HUP

FIXTURE_DIR=$(mktemp -d /tmp/rite-test-stop-guard-ingest-XXXXXX) || {
  echo "FAIL: mktemp -d failed (/tmp が full / read-only / permission denied)" >&2
  exit 1
}

SESSION_ID="00000000-0000-0000-0000-000000000002"

# Fabricate .rite-flow-state for the given phase with active=true
# $1: phase name
# $2: previous_phase (optional、省略時は "cleanup_pre_ingest" がデフォルト — caller 経由想定)
make_state() {
  local phase="$1"
  local prev="${2:-cleanup_pre_ingest}"
  local active="${3:-true}"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")
  cat > "$FIXTURE_DIR/.rite-flow-state" <<EOF
{
  "active": $active,
  "issue_number": 618,
  "branch": "fix/issue-618-test",
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
STDERR_CONTENT=""
run_guard() {
  local phase="$1"
  local prev="$2"
  local active="${3:-true}"
  make_state "$phase" "$prev" "$active"
  local input
  input=$(printf '{"cwd":"%s","session_id":"%s"}' "$FIXTURE_DIR" "$SESSION_ID")
  local stderr_file
  stderr_file=$(mktemp "$FIXTURE_DIR/stderr.XXXXXX") || {
    echo "FAIL: stderr tempfile mktemp failed" >&2
    exit 1
  }
  STDERR_CONTENT=""
  printf '%s' "$input" | bash "$STOP_GUARD" 2>"$stderr_file"
  local rc=$?
  STDERR_CONTENT=$(cat "$stderr_file")
  return "$rc"
}

# Assertion helpers (sibling stop-guard-cleanup.test.sh と同型)
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

# Test 1: ingest_pre_lint phase should block with exit 2 and emit HINT-specific phrase + sentinel
echo "# Test 1: ingest_pre_lint blocks end_turn + HINT specific pin + sentinel emit"
run_guard "ingest_pre_lint" "cleanup_pre_ingest"
rc=$?
assert "ingest_pre_lint exits 2" "2" "$rc"
assert_contains "stderr contains Phase:" "Phase:" "$STDERR_CONTENT"
assert_contains "stderr contains ingest_pre_lint" "ingest_pre_lint" "$STDERR_CONTENT"
# HINT-specific phrase pin (Issue #618 AC-4): ingest_pre_lint case arm 内にのみ存在する文言を pin
assert_contains "stderr contains 'Phase 8.2 Pre-write recorded'" "Phase 8.2 Pre-write recorded" "$STDERR_CONTENT"
# Sentinel emission pin: stop-guard.sh:332 の WORKFLOW_INCIDENT_TYPE 設定分岐で
# manual_fallback_adopted sentinel が stderr に echo されることを assert
assert_contains "stderr contains manual_fallback_adopted sentinel" "WORKFLOW_INCIDENT=1; type=manual_fallback_adopted" "$STDERR_CONTENT"

# Test 2: ingest_post_lint phase should block with exit 2 and emit HINT-specific phrase + sentinel
echo "# Test 2: ingest_post_lint blocks end_turn + HINT specific pin + sentinel emit"
run_guard "ingest_post_lint" "ingest_pre_lint"
rc=$?
assert "ingest_post_lint exits 2" "2" "$rc"
assert_contains "stderr contains Phase:" "Phase:" "$STDERR_CONTENT"
assert_contains "stderr contains ingest_post_lint" "ingest_post_lint" "$STDERR_CONTENT"
# HINT-specific phrase pin: ingest_post_lint case arm 内にのみ存在する文言を pin
assert_contains "stderr contains 'rite:wiki:lint --auto returned'" "rite:wiki:lint --auto returned" "$STDERR_CONTENT"
assert_contains "stderr contains 'Phase 9 Completion Report has NOT been output'" "Phase 9 Completion Report has NOT been output" "$STDERR_CONTENT"
# Sentinel emission pin
assert_contains "stderr contains manual_fallback_adopted sentinel" "WORKFLOW_INCIDENT=1; type=manual_fallback_adopted" "$STDERR_CONTENT"

# Test 3: ingest_completed with active=false should allow stop (exit 0) and NOT emit STOP_MSG
echo "# Test 3: ingest_completed + active:false allows stop (negative assertion)"
run_guard "ingest_completed" "ingest_post_lint" "false"
rc=$?
assert "ingest_completed (active:false) exits 0" "0" "$rc"
# Negative assertion: active=false で誤って STOP_MSG が emit される regression を検知
assert_not_contains "Test 3 stderr does not contain 'stop prevented'" "stop prevented" "$STDERR_CONTENT"
assert_not_contains "Test 3 stderr does not contain 'Normal operation'" "Normal operation" "$STDERR_CONTENT"

# Test 4: ingest_completed with active=true (caller 経由時の transient state) should block
# (caller が書き戻す前の瞬間 state を protect)
echo "# Test 4: ingest_completed + active:true still blocks (transient state protection)"
run_guard "ingest_completed" "ingest_post_lint" "true"
rc=$?
assert "ingest_completed (active:true) exits 2" "2" "$rc"
assert_contains "stderr contains Phase:" "Phase:" "$STDERR_CONTENT"

echo ""
echo "# Summary: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
