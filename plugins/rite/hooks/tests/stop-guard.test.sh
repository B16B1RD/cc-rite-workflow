#!/bin/bash
# Tests for stop-guard.sh
# Usage: bash plugins/rite/hooks/tests/stop-guard.test.sh
set -euo pipefail

# Note: symlink-safe resolution (readlink -f) not used here as this test is
# expected to run directly, not via symlinks.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GUARD="$SCRIPT_DIR/../stop-guard.sh"
GUARD_TEST_DIR="$(mktemp -d)"
LAST_STDERR_FILE=""
PASS=0
FAIL=0

# Prerequisite check: jq is required by stop-guard.sh
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi

cleanup() {
  rm -rf "$GUARD_TEST_DIR"
}
trap cleanup EXIT

# Helper: run stop-guard with given JSON input, capture exit code, stdout, and stderr
run_guard() {
  local input="$1"
  local output
  local rc=0
  LAST_STDERR_FILE="$(mktemp "$GUARD_TEST_DIR/stderr.XXXXXX")"
  output=$(echo "$input" | bash "$GUARD" 2>"$LAST_STDERR_FILE") || rc=$?
  echo "$output"
  return $rc
}

# Helper: show captured stderr on failure for debugging
show_stderr() {
  local stderr_file="${LAST_STDERR_FILE:-}"
  if [ -s "$stderr_file" ]; then
    echo "    stderr: $(cat "$stderr_file")"
  fi
}

# Helper: assert stderr file contains all given patterns; echo first missing pattern on failure
assert_stderr_contains() {
  local file="$1"
  shift
  local content
  content=$(cat "$file")
  for pat in "$@"; do
    if ! echo "$content" | grep -q "$pat"; then
      echo "$pat"
      return 1
    fi
  done
  return 0
}

# Helper: create a state file in the temp directory
create_state_file() {
  local dir="$1"
  local content="$2"
  echo "$content" > "$dir/.rite-flow-state"
}

pass() {
  PASS=$((PASS + 1))
  echo "  ✅ PASS: $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "  ❌ FAIL: $1"
  show_stderr
}

echo "=== stop-guard.sh tests ==="
echo ""

# --------------------------------------------------------------------------
# TC-001: stop_hook_active=true は無視され通常フローへ（チェック削除済み）
#
# stop_hook_active チェックは削除された（preventedContinuation が常に false の
# ため無限ループは発生しない）。cwd が存在しないため通常の cwd チェックで exit 0。
# --------------------------------------------------------------------------
echo "TC-001: stop_hook_active=true は無視され通常フローへ"
input="{\"stop_hook_active\": true, \"cwd\": \"$GUARD_TEST_DIR/nonexistent-dir\"}"
output=$(run_guard "$input") && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ -z "$output" ]; then
  pass "stop_hook_active=true → cwd チェックで exit 0（チェック削除済み）"
else
  fail "exit=$rc, output='$output'"
fi

# --------------------------------------------------------------------------
# TC-002: ステートファイルが存在しない場合 exit 0
# --------------------------------------------------------------------------
echo "TC-002: ステートファイル不存在で exit 0"
input="{\"stop_hook_active\": false, \"cwd\": \"$GUARD_TEST_DIR/no-state\"}"
mkdir -p "$GUARD_TEST_DIR/no-state"
output=$(run_guard "$input") && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ -z "$output" ]; then
  pass "ステートファイルなし → exit 0"
else
  fail "exit=$rc, output='$output'"
fi

# --------------------------------------------------------------------------
# TC-003: active=false の場合 exit 0
# --------------------------------------------------------------------------
echo "TC-003: active=false で exit 0"
dir003="$GUARD_TEST_DIR/tc003"
mkdir -p "$dir003"
create_state_file "$dir003" '{"active": false, "updated_at": "2026-01-01T00:00:00+00:00"}'
input="{\"stop_hook_active\": false, \"cwd\": \"$dir003\"}"
output=$(run_guard "$input") && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ -z "$output" ]; then
  pass "active=false → exit 0"
else
  fail "exit=$rc, output='$output'"
fi

# --------------------------------------------------------------------------
# TC-004: STATE_TS が非数値（date パース失敗）→ echo 0 フォールバック → AGE 大 → exit 0
#
# $AGE 変数のクォートが正しく機能し、STATE_TS=0 でも算術展開が安全であること
# --------------------------------------------------------------------------
echo "TC-004: STATE_TS 非数値フォールバック（AGE 変数クォート安全性）"
dir004="$GUARD_TEST_DIR/tc004"
mkdir -p "$dir004"
# updated_at に date がパースできない文字列を設定
create_state_file "$dir004" '{"active": true, "updated_at": "INVALID-TIMESTAMP", "phase": "test", "next_action": "test"}'
input="{\"stop_hook_active\": false, \"cwd\": \"$dir004\"}"
output=$(run_guard "$input") && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ -z "$output" ]; then
  pass "非数値 STATE_TS → フォールバック echo 0 → AGE 大 → exit 0"
else
  fail "exit=$rc, output='$output'"
fi

# --------------------------------------------------------------------------
# TC-005: GNU date -d による ISO 8601 タイムスタンプパース検証
#
# GNU date -d でパース可能な ISO 8601 文字列を使用。
# Linux 環境では date -d が成功するため、フォールバック先（date -j -f, echo 0）は
# 実行されない。ここでは date -d が正しいエポック秒を返すことを間接的に確認する。
# --------------------------------------------------------------------------
echo "TC-005: GNU date -d による ISO 8601 パース検証"
dir005="$GUARD_TEST_DIR/tc005"
mkdir -p "$dir005"
# 5分前のタイムスタンプ → AGE < 7200 → block (exit 2 + stderr)
recent_ts=$(date -u -d "5 minutes ago" +"%Y-%m-%dT%H:%M:%S+00:00" 2>/dev/null || date -u -v-5M +"%Y-%m-%dT%H:%M:%S+00:00")
create_state_file "$dir005" "{\"active\": true, \"updated_at\": \"$recent_ts\", \"phase\": \"impl\", \"next_action\": \"continue\"}"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir005\"}"
stderr_file005="$(mktemp "$GUARD_TEST_DIR/stderr005.XXXXXX")"
output=$(echo "$input" | bash "$GUARD" 2>"$stderr_file005") && rc=0 || rc=$?
if [ $rc -eq 2 ] && [ -z "$output" ]; then
  if missing=$(assert_stderr_contains "$stderr_file005" "Normal operation" "impl" "continue" "NOT re-invoke"); then
    pass "5分前のタイムスタンプ → date -d 成功 → exit 2（stderr にフェーズ/アクション/再実行禁止含む）"
  else
    fail "exit 2 だが stderr にパターン不在 '$missing': '$(cat "$stderr_file005")'"
  fi
else
  fail "exit=$rc, output='$output'"
fi

# --------------------------------------------------------------------------
# TC-006: タイムゾーン付き日時文字列の sed コロン除去
#
# +09:00 形式 → sed で +0900 に変換 → date -j -f でパース可能
# Linux では date -d が +09:00 を直接パースできるため、sed 分岐には到達しない。
# ここでは +09:00 形式のタイムスタンプが正しく処理されることを確認。
# --------------------------------------------------------------------------
echo "TC-006: タイムゾーン付き日時文字列（+09:00 形式）"
dir006="$GUARD_TEST_DIR/tc006"
mkdir -p "$dir006"
# 古い固定日時（JST +09:00）→ AGE > 7200 → exit 0
old_ts="2020-01-01T00:00:00+09:00"
create_state_file "$dir006" "{\"active\": true, \"updated_at\": \"$old_ts\", \"phase\": \"test\", \"next_action\": \"test\"}"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir006\"}"
output=$(run_guard "$input") && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ -z "$output" ]; then
  pass "+09:00 形式の古いタイムスタンプ → exit 0（staleness 検出）"
else
  fail "exit=$rc, output='$output'"
fi

# --------------------------------------------------------------------------
# TC-007: STATE_TS=0 時のフォールバック動作
#
# STATE_TS=0 の場合、AGE = CURRENT - 0 = CURRENT（数十億秒）→ > 7200 → exit 0
# --------------------------------------------------------------------------
echo "TC-007: STATE_TS=0 フォールバック動作"
dir007="$GUARD_TEST_DIR/tc007"
mkdir -p "$dir007"
# updated_at を空文字列にして全 date コマンドを失敗させ、echo 0 に到達
create_state_file "$dir007" '{"active": true, "updated_at": "", "phase": "test", "next_action": "test"}'
input="{\"stop_hook_active\": false, \"cwd\": \"$dir007\"}"
output=$(run_guard "$input") && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ -z "$output" ]; then
  pass "STATE_TS=0 → AGE=CURRENT → exit 0"
else
  fail "exit=$rc, output='$output'"
fi

# --------------------------------------------------------------------------
# TC-008: 通常ケース（アクティブ、2時間以内）→ block
# --------------------------------------------------------------------------
echo "TC-008: アクティブかつ2時間以内 → block (exit 2 + stderr)"
dir008="$GUARD_TEST_DIR/tc008"
mkdir -p "$dir008"
now_ts=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")
create_state_file "$dir008" "{\"active\": true, \"updated_at\": \"$now_ts\", \"phase\": \"implementing\", \"next_action\": \"run tests\"}"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir008\"}"
stderr_file008="$(mktemp "$GUARD_TEST_DIR/stderr008.XXXXXX")"
output=$(echo "$input" | bash "$GUARD" 2>"$stderr_file008") && rc=0 || rc=$?
if [ $rc -eq 2 ] && [ -z "$output" ]; then
  if missing=$(assert_stderr_contains "$stderr_file008" "Normal operation" "implementing" "run tests" "NOT re-invoke"); then
    pass "exit 2、stderr に固定テキスト・フェーズ・アクション・再実行禁止が含まれる"
  else
    fail "exit 2 だが stderr にパターン不在 '$missing': '$(cat "$stderr_file008")'"
  fi
else
  fail "exit=$rc, output='$output'"
fi

# --------------------------------------------------------------------------
# TC-009: 2時間超過（stale）→ exit 0
#
# プロダクションコードの閾値は 7200秒（2時間）。3時間前のタイムスタンプで
# AGE > 7200 を確実に満たし、stale 判定で exit 0 になることを確認。
# --------------------------------------------------------------------------
echo "TC-009: 2時間超過で exit 0（stale 判定）"
dir009="$GUARD_TEST_DIR/tc009"
mkdir -p "$dir009"
old_ts=$(date -u -d "3 hours ago" +"%Y-%m-%dT%H:%M:%S+00:00" 2>/dev/null || date -u -v-3H +"%Y-%m-%dT%H:%M:%S+00:00")
create_state_file "$dir009" "{\"active\": true, \"updated_at\": \"$old_ts\", \"phase\": \"impl\", \"next_action\": \"continue\"}"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir009\"}"
output=$(run_guard "$input") && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ -z "$output" ]; then
  pass "3時間前 → stale（AGE > 7200）→ exit 0"
else
  fail "exit=$rc, output='$output'"
fi

# --------------------------------------------------------------------------
# TC-010: 境界値テスト（閾値未満）→ block
#
# プロダクションコードの閾値は 7200秒（2時間）。
# 7150秒前を使用（7199秒だとテスト実行中の1-2秒の遅延で AGE が 7200-7201 に
# なり flaky になるため、余裕を持たせる）
# --------------------------------------------------------------------------
echo "TC-010: 境界値 閾値未満（7150秒前）→ block (exit 2)"
dir010="$GUARD_TEST_DIR/tc010"
mkdir -p "$dir010"
# 7150秒前 → AGE ≈ 7150（< 7200）→ block (exit 2 + stderr)
boundary_ts=$(date -u -d "7150 seconds ago" +"%Y-%m-%dT%H:%M:%S+00:00" 2>/dev/null || date -u -v-7150S +"%Y-%m-%dT%H:%M:%S+00:00")
create_state_file "$dir010" "{\"active\": true, \"updated_at\": \"$boundary_ts\", \"phase\": \"impl\", \"next_action\": \"continue\"}"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir010\"}"
stderr_file010="$(mktemp "$GUARD_TEST_DIR/stderr010.XXXXXX")"
output=$(echo "$input" | bash "$GUARD" 2>"$stderr_file010") && rc=0 || rc=$?
if [ $rc -eq 2 ] && [ -z "$output" ]; then
  if missing=$(assert_stderr_contains "$stderr_file010" "Normal operation" "impl" "continue" "NOT re-invoke"); then
    pass "7150秒前 → AGE < 7200 → exit 2（stderr に phase・アクション・再実行禁止含む）"
  else
    fail "exit 2 だが stderr にパターン不在 '$missing': '$(cat "$stderr_file010")'"
  fi
else
  fail "exit=$rc, output='$output'"
fi

# --------------------------------------------------------------------------
# TC-011: 境界値テスト（7201秒 = 閾値超過）→ exit 0
#
# プロダクションコードは [ "$AGE" -gt 7200 ] なので、AGE > 7200 で stale 判定。
# --------------------------------------------------------------------------
echo "TC-011: 境界値 7201秒（閾値超過）→ exit 0"
dir011="$GUARD_TEST_DIR/tc011"
mkdir -p "$dir011"
# 7201秒前（= 2時間0分1秒前）→ AGE > 7200 → exit 0
boundary_ts2=$(date -u -d "7201 seconds ago" +"%Y-%m-%dT%H:%M:%S+00:00" 2>/dev/null || date -u -v-7201S +"%Y-%m-%dT%H:%M:%S+00:00")
create_state_file "$dir011" "{\"active\": true, \"updated_at\": \"$boundary_ts2\", \"phase\": \"impl\", \"next_action\": \"continue\"}"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir011\"}"
output=$(run_guard "$input") && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ -z "$output" ]; then
  pass "7201秒前 → AGE > 7200 → exit 0（stale 判定）"
else
  fail "exit=$rc, output='$output'"
fi

# --------------------------------------------------------------------------
# TC-012: 境界値テスト（閾値近傍）→ block
#
# プロダクションコードは [ "$AGE" -gt 7200 ] なので、AGE ≤ 7200 は block になる。
# 7195秒前を使用（7200秒だとテスト実行中の1秒の遅延で AGE=7201 になり
# flaky になるため、余裕を持たせる）
# --------------------------------------------------------------------------
echo "TC-012: 境界値 閾値近傍（7195秒前）→ block (exit 2)"
dir012="$GUARD_TEST_DIR/tc012"
mkdir -p "$dir012"
# 7195秒前 → AGE ≈ 7195（≤ 7200）→ -gt 7200 は false → block (exit 2 + stderr)
boundary_ts3=$(date -u -d "7195 seconds ago" +"%Y-%m-%dT%H:%M:%S+00:00" 2>/dev/null || date -u -v-7195S +"%Y-%m-%dT%H:%M:%S+00:00")
create_state_file "$dir012" "{\"active\": true, \"updated_at\": \"$boundary_ts3\", \"phase\": \"impl\", \"next_action\": \"continue\"}"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir012\"}"
stderr_file012="$(mktemp "$GUARD_TEST_DIR/stderr012.XXXXXX")"
output=$(echo "$input" | bash "$GUARD" 2>"$stderr_file012") && rc=0 || rc=$?
if [ $rc -eq 2 ] && [ -z "$output" ]; then
  if missing=$(assert_stderr_contains "$stderr_file012" "Normal operation" "impl" "continue" "NOT re-invoke"); then
    pass "7195秒前 → AGE ≤ 7200 → exit 2（-gt なので block、stderr に phase・アクション・再実行禁止含む）"
  else
    fail "exit 2 だが stderr にパターン不在 '$missing': '$(cat "$stderr_file012")'"
  fi
else
  fail "exit=$rc, output='$output'"
fi

# --------------------------------------------------------------------------
# TC-013: 不正 JSON 入力のエラーハンドリング
#
# プロダクションコードは set -e のため、jq パース失敗で非ゼロ exit する。
# run_guard ヘルパーを使わず直接実行する理由: run_guard は stdout をキャプチャし
# echo するが、不正 JSON では stdout が空かつ非ゼロ exit のみが重要。また run_guard
# 内の stderr リダイレクトではなく /dev/null で完全に抑制したいため。
# --------------------------------------------------------------------------
echo "TC-013: 不正 JSON 入力で非ゼロ exit"
output=$(echo "NOT-VALID-JSON" | bash "$GUARD" 2>/dev/null) && rc=0 || rc=$?
if [ $rc -ne 0 ]; then
  pass "不正 JSON → 非ゼロ exit（rc=$rc）"
else
  fail "不正 JSON で exit 0 になった（期待: 非ゼロ exit）"
fi

# --------------------------------------------------------------------------
# TC-014: phase/next_action 欠落時のデフォルト値（"unknown"）検証
#
# ステートファイルに phase/next_action がない場合、jq の // "unknown" フォールバック
# により reason に "unknown" が含まれることを確認
# --------------------------------------------------------------------------
echo "TC-014: phase/next_action 欠落時のデフォルト値検証"
dir014="$GUARD_TEST_DIR/tc014"
mkdir -p "$dir014"
now_ts014=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")
# phase と next_action を含まないステートファイル
create_state_file "$dir014" "{\"active\": true, \"updated_at\": \"$now_ts014\"}"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir014\"}"
stderr_file014="$(mktemp "$GUARD_TEST_DIR/stderr014.XXXXXX")"
output=$(echo "$input" | bash "$GUARD" 2>"$stderr_file014") && rc=0 || rc=$?
if [ $rc -eq 2 ] && [ -z "$output" ]; then
  if missing=$(assert_stderr_contains "$stderr_file014" "Normal operation" "unknown" "NOT re-invoke"); then
    pass "phase/next_action 欠落 → stderr に 'Normal operation' と 'unknown' と 'NOT re-invoke' が含まれる"
  else
    fail "exit 2 だが stderr にパターン不在 '$missing': '$(cat "$stderr_file014")'"
  fi
else
  fail "exit=$rc, output='$output'"
fi

# --------------------------------------------------------------------------
# TC-015: ステートファイルが不正 JSON の場合 → fail-closed (exit 2)
#
# .rite-flow-state に不正 JSON が書かれた場合、jq パース失敗しても
# fail-open (exit 0) にならず、fail-closed (exit 2) で stop を
# ブロックすることを確認
# --------------------------------------------------------------------------
echo "TC-015: ステートファイル不正 JSON → fail-closed (exit 2)"
dir015="$GUARD_TEST_DIR/tc015"
mkdir -p "$dir015"
# 不正 JSON をステートファイルに書き込み
create_state_file "$dir015" "NOT-VALID-JSON-IN-STATE-FILE"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir015\"}"
stderr_file015="$(mktemp "$GUARD_TEST_DIR/stderr015.XXXXXX")"
output=$(echo "$input" | bash "$GUARD" 2>"$stderr_file015") && rc=0 || rc=$?
if [ $rc -eq 2 ] && [ -z "$output" ]; then
  if missing=$(assert_stderr_contains "$stderr_file015" "Normal operation" "state unreadable"); then
    pass "不正 JSON ステートファイル → fail-closed exit 2（stderr に state unreadable 含む）"
  else
    fail "exit 2 だが stderr にパターン不在 '$missing': '$(cat "$stderr_file015")'"
  fi
else
  fail "exit=$rc（期待: exit 2）, output='$output', stderr='$(cat "$stderr_file015")'"
fi

# --------------------------------------------------------------------------
# TC-016〜TC-020: error_count circuit breaker tests
#
# Note: run_guard helper is not used here because TC-020 needs to inspect
# .rite-flow-state after execution. Using explicit named stderr files keeps
# the invocation pattern consistent across the entire test group.
# --------------------------------------------------------------------------

# --------------------------------------------------------------------------
# TC-016: error_count = 0 (< threshold 3) → まだブロック (exit 2)
# --------------------------------------------------------------------------
echo "TC-016: error_count=0 (< 閾値3) → ブロック (exit 2)"
dir016="$GUARD_TEST_DIR/tc016"
mkdir -p "$dir016"
now_ts016=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")
create_state_file "$dir016" "{\"active\": true, \"updated_at\": \"$now_ts016\", \"phase\": \"impl\", \"next_action\": \"continue\", \"error_count\": 0}"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir016\"}"
stderr_file016="$(mktemp "$GUARD_TEST_DIR/stderr016.XXXXXX")"
output=$(echo "$input" | bash "$GUARD" 2>"$stderr_file016") && rc=0 || rc=$?
if [ $rc -eq 2 ] && [ -z "$output" ]; then
  if missing=$(assert_stderr_contains "$stderr_file016" "Normal operation" "impl" "continue" "NOT re-invoke"); then
    pass "error_count=0 → exit 2（閾値未満でブロック）"
  else
    fail "exit 2 だが stderr にパターン不在 '$missing': '$(cat "$stderr_file016")'"
  fi
else
  fail "exit=$rc, output='$output'"
fi

# --------------------------------------------------------------------------
# TC-017: error_count = 2 (閾値-1) → まだブロック (exit 2)
# --------------------------------------------------------------------------
echo "TC-017: error_count=2 (閾値3-1) → ブロック (exit 2)"
dir017="$GUARD_TEST_DIR/tc017"
mkdir -p "$dir017"
now_ts017=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")
create_state_file "$dir017" "{\"active\": true, \"updated_at\": \"$now_ts017\", \"phase\": \"impl\", \"next_action\": \"continue\", \"error_count\": 2}"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir017\"}"
stderr_file017="$(mktemp "$GUARD_TEST_DIR/stderr017.XXXXXX")"
output=$(echo "$input" | bash "$GUARD" 2>"$stderr_file017") && rc=0 || rc=$?
if [ $rc -eq 2 ] && [ -z "$output" ]; then
  if missing=$(assert_stderr_contains "$stderr_file017" "Normal operation" "impl" "NOT re-invoke"); then
    pass "error_count=2 → exit 2（閾値3未満でブロック）"
  else
    fail "exit 2 だが stderr にパターン不在 '$missing': '$(cat "$stderr_file017")'"
  fi
else
  fail "exit=$rc, output='$output'"
fi

# --------------------------------------------------------------------------
# TC-018: error_count = 3 (≥ 閾値) → 停止を許可 (exit 0)
# --------------------------------------------------------------------------
echo "TC-018: error_count=3 (≥ 閾値3) → 停止許可 (exit 0)"
dir018="$GUARD_TEST_DIR/tc018"
mkdir -p "$dir018"
now_ts018=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")
create_state_file "$dir018" "{\"active\": true, \"updated_at\": \"$now_ts018\", \"phase\": \"impl\", \"next_action\": \"continue\", \"error_count\": 3}"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir018\"}"
stderr_file018="$(mktemp "$GUARD_TEST_DIR/stderr018.XXXXXX")"
output=$(echo "$input" | bash "$GUARD" 2>"$stderr_file018") && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ -z "$output" ]; then
  if missing=$(assert_stderr_contains "$stderr_file018" "Error threshold reached" "consecutive" "threshold"); then
    pass "error_count=3 → exit 0（閾値到達、停止許可、stderr に threshold メッセージ）"
  else
    fail "exit 0 だが stderr にパターン不在 '$missing': '$(cat "$stderr_file018")'"
  fi
else
  fail "exit=$rc（期待: exit 0）, output='$output', stderr='$(cat "$stderr_file018")'"
fi

# --------------------------------------------------------------------------
# TC-019: カスタム閾値（rite-config.yml の threshold=1）→ error_count=1 で停止許可
# --------------------------------------------------------------------------
echo "TC-019: カスタム閾値 (threshold=1) → error_count=1 で停止許可 (exit 0)"
dir019="$GUARD_TEST_DIR/tc019"
mkdir -p "$dir019"
now_ts019=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")
create_state_file "$dir019" "{\"active\": true, \"updated_at\": \"$now_ts019\", \"phase\": \"impl\", \"next_action\": \"continue\", \"error_count\": 1}"
# カスタム閾値を持つ rite-config.yml を作成
cat > "$dir019/rite-config.yml" <<'CFGEOF'
safety:
  repeated_failure_threshold: 1
CFGEOF
input="{\"stop_hook_active\": false, \"cwd\": \"$dir019\"}"
stderr_file019="$(mktemp "$GUARD_TEST_DIR/stderr019.XXXXXX")"
output=$(echo "$input" | bash "$GUARD" 2>"$stderr_file019") && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ -z "$output" ]; then
  if missing=$(assert_stderr_contains "$stderr_file019" "Error threshold reached" "1"); then
    pass "カスタム threshold=1 → error_count=1 で exit 0"
  else
    fail "exit 0 だが stderr にパターン不在 '$missing': '$(cat "$stderr_file019")'"
  fi
else
  fail "exit=$rc（期待: exit 0）, output='$output', stderr='$(cat "$stderr_file019")'"
fi

# --------------------------------------------------------------------------
# TC-020: ブロック後に error_count がインクリメントされてファイルに書き込まれる
# --------------------------------------------------------------------------
echo "TC-020: ブロック後に error_count がインクリメントされる"
dir020="$GUARD_TEST_DIR/tc020"
mkdir -p "$dir020"
now_ts020=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")
create_state_file "$dir020" "{\"active\": true, \"updated_at\": \"$now_ts020\", \"phase\": \"impl\", \"next_action\": \"continue\", \"error_count\": 1}"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir020\"}"
echo "$input" | bash "$GUARD" 2>/dev/null && rc=0 || rc=$?
# exit 2 でブロックされたはず。インクリメント後の error_count を確認
if [ $rc -eq 2 ]; then
  updated_count=$(jq -r '.error_count // 0' "$dir020/.rite-flow-state" 2>/dev/null || echo "parse-error")
  preserved_active=$(jq -r '.active // "missing"' "$dir020/.rite-flow-state" 2>/dev/null || echo "parse-error")
  preserved_phase=$(jq -r '.phase // "missing"' "$dir020/.rite-flow-state" 2>/dev/null || echo "parse-error")
  preserved_next=$(jq -r '.next_action // "missing"' "$dir020/.rite-flow-state" 2>/dev/null || echo "parse-error")
  if [ "$updated_count" = "2" ] && [ "$preserved_active" = "true" ] && \
     [ "$preserved_phase" = "impl" ] && [ "$preserved_next" = "continue" ]; then
    pass "exit 2 後に error_count が 1→2 にインクリメント、他フィールドも保持された"
  elif [ "$updated_count" != "2" ]; then
    fail "exit 2 だが error_count=$updated_count（期待: 2）"
  else
    fail "exit 2 だが他フィールド破損: active=$preserved_active phase=$preserved_phase next_action=$preserved_next"
  fi
else
  fail "exit=$rc（期待: exit 2）"
fi

# --------------------------------------------------------------------------
# TC-021: error_count フィールドなし（後方互換性）→ exit 2、error_count = 1 に初期化
# --------------------------------------------------------------------------
echo "TC-021: error_count フィールドなし → exit 2 で error_count=1 に初期化（後方互換）"
dir021="$GUARD_TEST_DIR/tc021"
mkdir -p "$dir021"
now_ts021=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")
# error_count フィールドなし（古い .rite-flow-state フォーマット）
create_state_file "$dir021" "{\"active\": true, \"updated_at\": \"$now_ts021\", \"phase\": \"impl\", \"next_action\": \"continue\"}"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir021\"}"
echo "$input" | bash "$GUARD" 2>/dev/null && rc=0 || rc=$?
if [ $rc -eq 2 ]; then
  initialized_count=$(jq -r '.error_count // "missing"' "$dir021/.rite-flow-state" 2>/dev/null || echo "parse-error")
  if [ "$initialized_count" = "1" ]; then
    pass "error_count フィールドなし → exit 2、error_count が 1 に初期化された（後方互換）"
  else
    fail "exit 2 だが error_count=$initialized_count（期待: 1）"
  fi
else
  fail "exit=$rc（期待: exit 2）"
fi

# --------------------------------------------------------------------------
# TC-022: 不正値閾値（rite-config.yml の repeated_failure_threshold: abc）→ デフォルト 3 にフォールバック
# --------------------------------------------------------------------------
echo "TC-022: 不正値閾値（threshold=abc）→ デフォルト 3 にフォールバック、error_count=2 でブロック"
dir022="$GUARD_TEST_DIR/tc022"
mkdir -p "$dir022"
now_ts022=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")
create_state_file "$dir022" "{\"active\": true, \"updated_at\": \"$now_ts022\", \"phase\": \"impl\", \"next_action\": \"continue\", \"error_count\": 2}"
cat > "$dir022/rite-config.yml" <<'CFGEOF'
safety:
  repeated_failure_threshold: abc
CFGEOF
input="{\"stop_hook_active\": false, \"cwd\": \"$dir022\"}"
echo "$input" | bash "$GUARD" 2>/dev/null && rc=0 || rc=$?
if [ $rc -eq 2 ]; then
  pass "不正値 threshold=abc → デフォルト 3 にフォールバック、error_count=2 でブロック（exit 2）"
else
  fail "exit=$rc（期待: exit 2）: 不正値 threshold で誤動作の可能性"
fi

# --------------------------------------------------------------------------
# TC-023: threshold=0 → 最小値ガード（THRESHOLD≥1）、error_count=0 でブロック
# --------------------------------------------------------------------------
echo "TC-023: threshold=0 → 最小値ガード（THRESHOLD≥1）、error_count=0 でブロック（exit 2）"
dir023="$GUARD_TEST_DIR/tc023"
mkdir -p "$dir023"
now_ts023=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")
create_state_file "$dir023" "{\"active\": true, \"updated_at\": \"$now_ts023\", \"phase\": \"impl\", \"next_action\": \"continue\", \"error_count\": 0}"
cat > "$dir023/rite-config.yml" <<'CFGEOF'
safety:
  repeated_failure_threshold: 0
CFGEOF
input="{\"stop_hook_active\": false, \"cwd\": \"$dir023\"}"
echo "$input" | bash "$GUARD" 2>/dev/null && rc=0 || rc=$?
if [ $rc -eq 2 ]; then
  pass "threshold=0 → 最小値ガード適用、error_count=0 でブロック（exit 2）"
else
  fail "exit=$rc（期待: exit 2）: threshold=0 でガードが機能していない"
fi

# --------------------------------------------------------------------------
# TC-024: compact_state=blocked + active=true → exit 0（デッドロック防止 #30）
#
# compact_state=blocked のとき、post-compact-guard が全ツール使用を拒否する。
# stop-guard も stop をブロックするとデッドロックになるため、即座に stop を
# 許可する（exit 0）。旧 AC-6 の動作を #30 で上書き。
# --------------------------------------------------------------------------
echo "TC-024: compact_state=blocked + active=true → exit 0（デッドロック防止 #30）"
dir024="$GUARD_TEST_DIR/tc024"
mkdir -p "$dir024"
now_ts024=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")
create_state_file "$dir024" "{\"active\": true, \"updated_at\": \"$now_ts024\", \"phase\": \"impl\", \"next_action\": \"continue\", \"error_count\": 0}"
echo '{"compact_state": "blocked"}' > "$dir024/.rite-compact-state"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir024\"}"
stderr_file024="$(mktemp "$GUARD_TEST_DIR/stderr024.XXXXXX")"
output=$(echo "$input" | bash "$GUARD" 2>"$stderr_file024") && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ -z "$output" ]; then
  if missing=$(assert_stderr_contains "$stderr_file024" "compact 検出" "/clear"); then
    pass "compact_state=blocked → exit 0（デッドロック防止 #30）"
  else
    fail "exit 0 だが stderr にパターン不在 '$missing': '$(cat "$stderr_file024")'"
  fi
else
  fail "exit=$rc, output='$output'（期待: exit 0）"
fi

# --------------------------------------------------------------------------
# TC-025: compact_state=resuming + active=true → exit 2（通常ブロック維持）
#
# resuming 状態ではツールが使えるため、デッドロックではない。
# stop-guard は通常通り停止をブロックすべき。
# --------------------------------------------------------------------------
echo "TC-025: compact_state=resuming + active=true → exit 2（通常ブロック維持）"
dir025="$GUARD_TEST_DIR/tc025"
mkdir -p "$dir025"
now_ts025=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")
create_state_file "$dir025" "{\"active\": true, \"updated_at\": \"$now_ts025\", \"phase\": \"impl\", \"next_action\": \"continue\", \"error_count\": 0}"
echo '{"compact_state": "resuming"}' > "$dir025/.rite-compact-state"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir025\"}"
stderr_file025="$(mktemp "$GUARD_TEST_DIR/stderr025.XXXXXX")"
output=$(echo "$input" | bash "$GUARD" 2>"$stderr_file025") && rc=0 || rc=$?
if [ $rc -eq 2 ] && [ -z "$output" ]; then
  if missing=$(assert_stderr_contains "$stderr_file025" "Normal operation" "impl" "NOT re-invoke"); then
    pass "compact_state=resuming → exit 2（デッドロックではないので通常ブロック）"
  else
    fail "exit 2 だが stderr にパターン不在 '$missing': '$(cat "$stderr_file025")'"
  fi
else
  fail "exit=$rc, output='$output'（期待: exit 2）"
fi

# --------------------------------------------------------------------------
# TC-026: needs_clear=true + active=true → exit 2（needs_clear は stop を許可しない）
#
# needs_clear フラグは廃止され、存在しても無視される（AC-1, D-01）。
# active フローの stop は常にブロックされるべき。
# --------------------------------------------------------------------------
echo "TC-026: needs_clear=true + active=true → exit 2（needs_clear 無視、AC-1）"
dir026="$GUARD_TEST_DIR/tc026"
mkdir -p "$dir026"
now_ts026=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")
create_state_file "$dir026" "{\"active\": true, \"updated_at\": \"$now_ts026\", \"phase\": \"phase5_review\", \"next_action\": \"proceed to fix\", \"error_count\": 0, \"needs_clear\": true}"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir026\"}"
stderr_file026="$(mktemp "$GUARD_TEST_DIR/stderr026.XXXXXX")"
output=$(echo "$input" | bash "$GUARD" 2>"$stderr_file026") && rc=0 || rc=$?
if [ $rc -eq 2 ] && [ -z "$output" ]; then
  if missing=$(assert_stderr_contains "$stderr_file026" "Normal operation" "phase5_review" "NOT re-invoke"); then
    pass "needs_clear=true → exit 2（フラグ無視、stop ブロック維持）"
  else
    fail "exit 2 だが stderr にパターン不在 '$missing': '$(cat "$stderr_file026")'"
  fi
else
  fail "exit=$rc, output='$output'（期待: exit 2）"
fi

# --------------------------------------------------------------------------
# TC-027: needs_clear=true + compact_state=blocked + active=true → exit 0
#
# needs_clear=true は廃止フラグで無視される（AC-1）。
# compact_state=blocked は即座に stop を許可する（#30）。
# 両方が存在する場合、compact_state=blocked が優先され exit 0 となる。
# --------------------------------------------------------------------------
echo "TC-027: needs_clear=true + compact_state=blocked → exit 0（#30 優先）"
dir027="$GUARD_TEST_DIR/tc027"
mkdir -p "$dir027"
now_ts027=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")
create_state_file "$dir027" "{\"active\": true, \"updated_at\": \"$now_ts027\", \"phase\": \"phase5_review\", \"next_action\": \"proceed to fix\", \"error_count\": 0, \"needs_clear\": true}"
echo '{"compact_state": "blocked"}' > "$dir027/.rite-compact-state"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir027\"}"
stderr_file027="$(mktemp "$GUARD_TEST_DIR/stderr027.XXXXXX")"
output=$(echo "$input" | bash "$GUARD" 2>"$stderr_file027") && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ -z "$output" ]; then
  if missing=$(assert_stderr_contains "$stderr_file027" "compact 検出" "/clear"); then
    pass "needs_clear=true + compact_state=blocked → exit 0（#30 デッドロック防止優先）"
  else
    fail "exit 0 だが stderr にパターン不在 '$missing': '$(cat "$stderr_file027")'"
  fi
else
  fail "exit=$rc, output='$output'（期待: exit 0）"
fi

# --------------------------------------------------------------------------
# TC-028: exit 2 パスで診断ログに EXIT:2 が記録される（AC-3）
# --------------------------------------------------------------------------
echo "TC-028: exit 2 パスで診断ログに EXIT:2 が記録される"
dir028="$GUARD_TEST_DIR/tc028"
mkdir -p "$dir028"
now_ts028=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")
create_state_file "$dir028" "{\"active\": true, \"updated_at\": \"$now_ts028\", \"phase\": \"phase5_review\", \"next_action\": \"proceed to fix\", \"error_count\": 0}"
# Clear any existing diag log
rm -f "$dir028/.rite-stop-guard-diag.log"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir028\"}"
echo "$input" | bash "$GUARD" 2>/dev/null && rc=0 || rc=$?
if [ $rc -eq 2 ]; then
  diag_file="$dir028/.rite-stop-guard-diag.log"
  if [ -f "$diag_file" ] && grep -q "EXIT:2" "$diag_file"; then
    pass "exit 2 パスで診断ログに EXIT:2 が記録された（AC-3）"
  else
    fail "exit 2 だが診断ログに EXIT:2 が記録されていない（ファイル存在: $([ -f "$diag_file" ] && echo yes || echo no)）"
  fi
else
  fail "exit=$rc（期待: exit 2）"
fi

# --------------------------------------------------------------------------
# TC-029: exit 0 パスで診断ログに reason=not_active が記録される（AC-3）
# --------------------------------------------------------------------------
echo "TC-029: exit 0 パスで診断ログに reason=not_active が記録される"
dir029="$GUARD_TEST_DIR/tc029"
mkdir -p "$dir029"
create_state_file "$dir029" '{"active": false, "updated_at": "2026-01-01T00:00:00+00:00"}'
# Clear any existing diag log
rm -f "$dir029/.rite-stop-guard-diag.log"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir029\"}"
output=$(run_guard "$input") && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ -z "$output" ]; then
  diag_file="$dir029/.rite-stop-guard-diag.log"
  if [ -f "$diag_file" ] && grep -q "reason=not_active" "$diag_file"; then
    pass "exit 0 パスで診断ログに reason=not_active が記録された（AC-3）"
  else
    fail "exit 0 だが診断ログに reason=not_active が記録されていない（ファイル存在: $([ -f "$diag_file" ] && echo yes || echo no)）"
  fi
else
  fail "exit=$rc, output='$output'（期待: exit 0）"
fi

# --------------------------------------------------------------------------
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ $FAIL -gt 0 ]; then
  exit 1
fi
