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
echo "TC-024: compact_state=recovering (>120s) + active=true → exit 0（タイムアウト #133）"
dir024="$GUARD_TEST_DIR/tc024"
mkdir -p "$dir024"
now_ts024=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")
create_state_file "$dir024" "{\"active\": true, \"updated_at\": \"$now_ts024\", \"phase\": \"impl\", \"next_action\": \"continue\", \"error_count\": 0}"
# Set compact_state_set_at to 200 seconds ago (>120s timeout)
old_ts024=$(date -u -d "200 seconds ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-200S +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "2020-01-01T00:00:00Z")
echo "{\"compact_state\": \"recovering\", \"compact_state_set_at\": \"$old_ts024\"}" > "$dir024/.rite-compact-state"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir024\"}"
stderr_file024="$(mktemp "$GUARD_TEST_DIR/stderr024.XXXXXX")"
output=$(echo "$input" | bash "$GUARD" 2>"$stderr_file024") && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ -z "$output" ]; then
  if missing=$(assert_stderr_contains "$stderr_file024" "PostCompact タイムアウト" "/rite:resume"); then
    pass "compact_state=recovering (>120s) → exit 0（PostCompact タイムアウト #133）"
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
echo "TC-025: compact_state=recovering (<120s) + active=true → exit 2（PostCompact 処理待ち #133）"
dir025="$GUARD_TEST_DIR/tc025"
mkdir -p "$dir025"
now_ts025=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")
create_state_file "$dir025" "{\"active\": true, \"updated_at\": \"$now_ts025\", \"phase\": \"impl\", \"next_action\": \"continue\", \"error_count\": 0}"
# Set compact_state_set_at to just now (<120s, PostCompact should process soon)
echo "{\"compact_state\": \"recovering\", \"compact_state_set_at\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"}" > "$dir025/.rite-compact-state"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir025\"}"
stderr_file025="$(mktemp "$GUARD_TEST_DIR/stderr025.XXXXXX")"
output=$(echo "$input" | bash "$GUARD" 2>"$stderr_file025") && rc=0 || rc=$?
if [ $rc -eq 2 ] && [ -z "$output" ]; then
  if missing=$(assert_stderr_contains "$stderr_file025" "Normal operation" "impl" "NOT re-invoke"); then
    pass "compact_state=recovering (<120s) → exit 2（PostCompact 処理待ち）"
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
echo "TC-027: needs_clear=true + compact_state=recovering (>120s) → exit 0（タイムアウト優先 #133）"
dir027="$GUARD_TEST_DIR/tc027"
mkdir -p "$dir027"
now_ts027=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")
create_state_file "$dir027" "{\"active\": true, \"updated_at\": \"$now_ts027\", \"phase\": \"phase5_review\", \"next_action\": \"proceed to fix\", \"error_count\": 0, \"needs_clear\": true}"
old_ts027=$(date -u -d "200 seconds ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-200S +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "2020-01-01T00:00:00Z")
echo "{\"compact_state\": \"recovering\", \"compact_state_set_at\": \"$old_ts027\"}" > "$dir027/.rite-compact-state"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir027\"}"
stderr_file027="$(mktemp "$GUARD_TEST_DIR/stderr027.XXXXXX")"
output=$(echo "$input" | bash "$GUARD" 2>"$stderr_file027") && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ -z "$output" ]; then
  if missing=$(assert_stderr_contains "$stderr_file027" "PostCompact タイムアウト" "/rite:resume"); then
    pass "needs_clear=true + compact_state=recovering (>120s) → exit 0（タイムアウト優先 #133）"
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
output=$(run_guard "$input") && rc=0 || rc=$?
if [ $rc -eq 2 ] && [ -z "$output" ]; then
  diag_file="$dir028/.rite-stop-guard-diag.log"
  if [ -f "$diag_file" ] && grep -q "EXIT:2" "$diag_file"; then
    pass "exit 2 パスで診断ログに EXIT:2 が記録された（AC-3）"
  else
    fail "exit 2 だが診断ログに EXIT:2 が記録されていない（ファイル存在: $([ -f "$diag_file" ] && echo yes || echo no)）"
  fi
else
  fail "exit=$rc, output='$output'（期待: exit 2, stdout 空）"
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
# TC-475-A: create_post_interview phase (active=true, fresh) → exit 2 (block)
# #475 AC-4: stop-guard must block stop when lifecycle is mid-delegation
# --------------------------------------------------------------------------
echo "TC-475-A: create_post_interview active → exit 2 (block)"
dir475a="$GUARD_TEST_DIR/tc475a"
mkdir -p "$dir475a"
# F-13 (#636 cycle 6): 他箇所の ${fresh_ts:-$(date ...)} pattern と統一。
# :- fallback ありの形式にすることで 7200s 超 AGE stale early-exit による silent false-pass を防ぐ
# (将来 test suite が大量並列化 / mass TC 追加で長時間化した場合の保険)。
fresh_ts="${fresh_ts:-$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")}"
create_state_file "$dir475a" "{\"active\": true, \"phase\": \"create_post_interview\", \"previous_phase\": \"create_interview\", \"next_action\": \"Proceed to Phase 0.6. Do NOT stop.\", \"updated_at\": \"$fresh_ts\", \"issue_number\": 0, \"pr_number\": 0, \"error_count\": 0, \"session_id\": \"sid-475a\"}"
stderr_file475a="$(mktemp "$GUARD_TEST_DIR/stderr475a.XXXXXX")"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir475a\", \"session_id\": \"sid-475a\"}"
output=$(echo "$input" | bash "$GUARD" 2>"$stderr_file475a") && rc=0 || rc=$?
if [ $rc -eq 2 ] && grep -q "create_post_interview" "$stderr_file475a"; then
  pass "create_post_interview active → blocked with phase in stderr"
else
  fail "expected exit 2 with create_post_interview in stderr, got rc=$rc stderr='$(cat "$stderr_file475a")'"
fi

# --------------------------------------------------------------------------
# TC-475-B: create_interview → create_post_interview transition is whitelist-valid
# --------------------------------------------------------------------------
echo "TC-475-B: create_interview → create_post_interview whitelist-valid"
dir475b="$GUARD_TEST_DIR/tc475b"
mkdir -p "$dir475b"
create_state_file "$dir475b" "{\"active\": true, \"phase\": \"create_post_interview\", \"previous_phase\": \"create_interview\", \"next_action\": \"continue\", \"updated_at\": \"$fresh_ts\", \"issue_number\": 0, \"pr_number\": 0, \"error_count\": 0, \"session_id\": \"sid-475b\"}"
stderr_file475b="$(mktemp "$GUARD_TEST_DIR/stderr475b.XXXXXX")"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir475b\", \"session_id\": \"sid-475b\"}"
output=$(echo "$input" | bash "$GUARD" 2>"$stderr_file475b") && rc=0 || rc=$?
if [ $rc -eq 2 ] && ! grep -q "Invalid phase transition" "$stderr_file475b"; then
  pass "create_interview→create_post_interview accepted by whitelist (no invalid_transition)"
else
  fail "expected exit 2 without invalid_transition, got rc=$rc stderr='$(cat "$stderr_file475b")'"
fi

# TC-475-B2: invalid transition create_interview → create_delegation (bypassing post_interview)
echo "TC-475-B2: invalid transition create_interview → create_delegation → blocked with invalid_transition"
dir475b2="$GUARD_TEST_DIR/tc475b2"
mkdir -p "$dir475b2"
create_state_file "$dir475b2" "{\"active\": true, \"phase\": \"create_delegation\", \"previous_phase\": \"create_interview\", \"next_action\": \"skipped interview post-step\", \"updated_at\": \"$fresh_ts\", \"issue_number\": 0, \"pr_number\": 0, \"error_count\": 0, \"session_id\": \"sid-475b2\"}"
stderr_file475b2="$(mktemp "$GUARD_TEST_DIR/stderr475b2.XXXXXX")"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir475b2\", \"session_id\": \"sid-475b2\"}"
output=$(echo "$input" | bash "$GUARD" 2>"$stderr_file475b2") && rc=0 || rc=$?
if [ $rc -eq 2 ] && grep -q "Invalid phase transition" "$stderr_file475b2"; then
  pass "invalid transition create_interview→create_delegation detected"
else
  fail "expected exit 2 with invalid_transition, got rc=$rc stderr='$(cat "$stderr_file475b2")'"
fi

# --------------------------------------------------------------------------
# TC-475-C: session_id mismatch → exit 0 (stop allowed, AC-5)
# --------------------------------------------------------------------------
echo "TC-475-C: session_id mismatch during create_post_interview → exit 0"
dir475c="$GUARD_TEST_DIR/tc475c"
mkdir -p "$dir475c"
create_state_file "$dir475c" "{\"active\": true, \"phase\": \"create_post_interview\", \"next_action\": \"continue\", \"updated_at\": \"$fresh_ts\", \"issue_number\": 0, \"pr_number\": 0, \"session_id\": \"sid-other\"}"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir475c\", \"session_id\": \"sid-mine\"}"
output=$(run_guard "$input") && rc=0 || rc=$?
if [ $rc -eq 0 ]; then
  pass "session_id mismatch → stop allowed (AC-5)"
else
  fail "expected exit 0, got $rc"
fi

# --------------------------------------------------------------------------
# TC-622-A: create_interview phase (active=true, fresh) → exit 2 (block with HINT)
# Issue #622: stop-guard MUST block implicit stop while the interview sub-skill
# is mid-execution (or before its 🚨 MANDATORY Pre-flight has run). Prior to #622
# there was no `create_interview` case arm, so the general-block path fired
# without a phase-specific WORKFLOW_HINT and workflow_incident sentinel emit
# was possible but without routing guidance.
# --------------------------------------------------------------------------
echo "TC-622-A: create_interview active → exit 2 (block with HINT)"
dir622a="$GUARD_TEST_DIR/tc622a"
mkdir -p "$dir622a"
fresh_ts="${fresh_ts:-$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")}"
create_state_file "$dir622a" "{\"active\": true, \"phase\": \"create_interview\", \"previous_phase\": \"\", \"next_action\": \"After rite:issue:create-interview returns: proceed to Phase 0.6. Do NOT stop.\", \"updated_at\": \"$fresh_ts\", \"issue_number\": 0, \"pr_number\": 0, \"error_count\": 0, \"session_id\": \"sid-622a\"}"
stderr_file622a="$(mktemp "$GUARD_TEST_DIR/stderr622a.XXXXXX")"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir622a\", \"session_id\": \"sid-622a\"}"
output=$(echo "$input" | bash "$GUARD" 2>"$stderr_file622a") && rc=0 || rc=$?
# HINT の前半 (Delegation to Interview Pre-write) と後半 (MANDATORY Pre-flight / [create:completed:) を
# 2 段で検証し、HINT 文言が改変された場合の regression を確実に検出する
if [ $rc -eq 2 ] \
    && grep -q "Delegation to Interview Pre-write recorded create_interview" "$stderr_file622a" \
    && grep -q "MANDATORY Pre-flight" "$stderr_file622a" \
    && grep -q '\[create:completed:' "$stderr_file622a"; then
  pass "create_interview active → blocked with #622 HINT"
else
  fail "expected exit 2 with #622 HINT (Delegation to Interview + MANDATORY Pre-flight + [create:completed:), got rc=$rc stderr='$(cat "$stderr_file622a")'"
fi

# --------------------------------------------------------------------------
# TC-622-B: create_interview phase emits workflow_incident sentinel to stderr
# Issue #622: verify the workflow_incident_emit.sh helper is invoked for the
# create_interview phase (same contract as create_post_interview TC-475-A).
# The sentinel is echoed to stderr via the exit-2 feedback contract.
# --------------------------------------------------------------------------
echo "TC-622-B: create_interview active → workflow_incident sentinel in stderr"
dir622b="$GUARD_TEST_DIR/tc622b"
mkdir -p "$dir622b"
create_state_file "$dir622b" "{\"active\": true, \"phase\": \"create_interview\", \"previous_phase\": \"\", \"next_action\": \"continue\", \"updated_at\": \"$fresh_ts\", \"issue_number\": 622, \"pr_number\": 0, \"error_count\": 0, \"session_id\": \"sid-622b\"}"
stderr_file622b="$(mktemp "$GUARD_TEST_DIR/stderr622b.XXXXXX")"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir622b\", \"session_id\": \"sid-622b\"}"
output=$(echo "$input" | bash "$GUARD" 2>"$stderr_file622b") && rc=0 || rc=$?
if [ $rc -eq 2 ] \
    && grep -q "WORKFLOW_INCIDENT=1" "$stderr_file622b" \
    && grep -q "type=manual_fallback_adopted" "$stderr_file622b"; then
  pass "create_interview phase emits workflow_incident sentinel to stderr"
else
  fail "expected WORKFLOW_INCIDENT sentinel for create_interview, got rc=$rc stderr='$(cat "$stderr_file622b")'"
fi

# --------------------------------------------------------------------------
# TC-634-A: create_post_interview WORKFLOW_HINT includes concrete bash invocation
# Issue #634: HINT must now include the specific bash command for Step 0 Immediate
# Bash Action ("flow-state-update.sh patch --phase create_post_interview") so the
# LLM has a concrete next tool call instead of a natural turn-boundary. This test
# verifies the #634 HINT enhancement is applied to the create_post_interview case
# arm (symmetric with create_interview case arm TC-622-A).
# --------------------------------------------------------------------------
echo "TC-634-A: create_post_interview HINT includes Step 0 Immediate Bash Action"
dir634a="$GUARD_TEST_DIR/tc634a"
mkdir -p "$dir634a"
fresh_ts="${fresh_ts:-$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")}"
create_state_file "$dir634a" "{\"active\": true, \"phase\": \"create_post_interview\", \"previous_phase\": \"create_interview\", \"next_action\": \"Proceed to Phase 0.6. Do NOT stop.\", \"updated_at\": \"$fresh_ts\", \"issue_number\": 634, \"pr_number\": 0, \"error_count\": 0, \"session_id\": \"sid-634a\"}"
stderr_file634a="$(mktemp "$GUARD_TEST_DIR/stderr634a.XXXXXX")"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir634a\", \"session_id\": \"sid-634a\"}"
output=$(echo "$input" | bash "$GUARD" 2>"$stderr_file634a") && rc=0 || rc=$?
if [ $rc -eq 2 ] \
    && grep -q "Step 0 (Immediate Bash Action" "$stderr_file634a" \
    && grep -q "INTERVIEW_DONE=1" "$stderr_file634a" \
    && grep -q "plugins/rite/hooks/flow-state-update.sh patch --phase create_post_interview" "$stderr_file634a"; then
  pass "create_post_interview HINT includes Step 0 bash command (with full path) + INTERVIEW_DONE grep marker"
else
  fail "expected #634 HINT with Step 0 Immediate Bash Action + full path to flow-state-update.sh + INTERVIEW_DONE=1 grep marker, got rc=$rc stderr='$(cat "$stderr_file634a")'"
fi

# --------------------------------------------------------------------------
# TC-634-B: create_post_interview error_count escalation
# Issue #634: when error_count >= 1, WORKFLOW_HINT is extended with a RE-ENTRY
# DETECTED message to signal the LLM that the previous block did not advance the
# phase. This provides escalation pressure for persistent implicit-stop attempts.
# --------------------------------------------------------------------------
echo "TC-634-B: create_post_interview with error_count=1 emits RE-ENTRY DETECTED escalation"
dir634b="$GUARD_TEST_DIR/tc634b"
mkdir -p "$dir634b"
# verified-review F-07 / #636: cross-TC 独立性確保のため fresh_ts defensive fallback を
# TC-634-A 以降の全 TC と同じパターンで初期化する (TC-608-A 以降 12 箇所で統一されている convention)。
# 旧実装は TC-634-A の fresh_ts 設定が leak して動作していたが、TC-634-A を skip/削除/順序変更すると
# updated_at が空文字列で AGE check 早期 exit 0 → silent false-pass する経路があった。
fresh_ts="${fresh_ts:-$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")}"
create_state_file "$dir634b" "{\"active\": true, \"phase\": \"create_post_interview\", \"previous_phase\": \"create_interview\", \"next_action\": \"Proceed to Phase 0.6. Do NOT stop.\", \"updated_at\": \"$fresh_ts\", \"issue_number\": 634, \"pr_number\": 0, \"error_count\": 1, \"session_id\": \"sid-634b\"}"
stderr_file634b="$(mktemp "$GUARD_TEST_DIR/stderr634b.XXXXXX")"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir634b\", \"session_id\": \"sid-634b\"}"
output=$(echo "$input" | bash "$GUARD" 2>"$stderr_file634b") && rc=0 || rc=$?
# verified-review F-13 / #636: HINT 文字列だけでなく state file の .error_count 実値も検証する。
# L241-246 の jq write 失敗 (silent) が発生しても HINT だけは error_count=2 を emit するため、
# state 実値検証がないと silent write failure を test で検出できない経路があった。
state_error_count=$(jq -r '.error_count // empty' "$dir634b/.rite-flow-state" 2>/dev/null)
if [ $rc -eq 2 ] \
    && grep -q "RE-ENTRY DETECTED" "$stderr_file634b" \
    && grep -q "error_count=2" "$stderr_file634b" \
    && grep -q "execute the following bash block NOW as your next tool call" "$stderr_file634b" \
    && [ "$state_error_count" = "2" ]; then
  pass "create_post_interview error_count=1 → RE-ENTRY DETECTED escalation + case-arm-specific HINT + state file error_count=2"
else
  fail "expected RE-ENTRY DETECTED escalation + create_post_interview-specific HINT 'execute the following bash block' + error_count=2 in state, got rc=$rc, state_error_count='$state_error_count', stderr='$(cat "$stderr_file634b")'"
fi

# --------------------------------------------------------------------------
# TC-634-C: create_interview case arm also enhanced with Step 0 Immediate Bash Action
# Issue #634: symmetry with create_post_interview — the create_interview case arm
# (fires when the sub-skill Pre-flight was skipped) now also references Step 0 and
# INTERVIEW_DONE=1. This ensures both Pre-flight-ran and Pre-flight-skipped paths
# provide the same continuation guidance.
# --------------------------------------------------------------------------
echo "TC-634-C: create_interview HINT includes Step 0 Immediate Bash Action + INTERVIEW_DONE grep"
dir634c="$GUARD_TEST_DIR/tc634c"
mkdir -p "$dir634c"
# verified-review cycle 2 F-06 / #636: TC-634-A/B と対称に fresh_ts defensive fallback を適用。
# cross-TC 独立性を確保し、TC-634-A/B を skip/削除/順序変更しても silent false-pass しないようにする。
fresh_ts="${fresh_ts:-$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")}"
create_state_file "$dir634c" "{\"active\": true, \"phase\": \"create_interview\", \"previous_phase\": \"\", \"next_action\": \"continue\", \"updated_at\": \"$fresh_ts\", \"issue_number\": 634, \"pr_number\": 0, \"error_count\": 0, \"session_id\": \"sid-634c\"}"
stderr_file634c="$(mktemp "$GUARD_TEST_DIR/stderr634c.XXXXXX")"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir634c\", \"session_id\": \"sid-634c\"}"
output=$(echo "$input" | bash "$GUARD" 2>"$stderr_file634c") && rc=0 || rc=$?
if [ $rc -eq 2 ] \
    && grep -q "Step 0 (Immediate Bash Action" "$stderr_file634c" \
    && grep -q "INTERVIEW_DONE=1" "$stderr_file634c"; then
  pass "create_interview HINT includes Step 0 bash command + INTERVIEW_DONE grep marker (symmetric with create_post_interview)"
else
  fail "expected #634 HINT symmetry on create_interview case arm, got rc=$rc stderr='$(cat "$stderr_file634c")'"
fi

# --------------------------------------------------------------------------
# TC-634-D: create_interview case arm error_count escalation (verified-review cycle 2 F-09 / #636)
# Issue #634: stop-guard.sh の create_interview case arm における `error_count >= 1` で
# RE-ENTRY DETECTED HINT を追加する escalation branch (line-number 参照を避ける理由は cycle 8 F-05 参照)
# は cycle 1 テストでは未カバーだった。TC-634-B (create_post_interview) と対称に
# create_interview + error_count=1 での escalation を verify する。
# --------------------------------------------------------------------------
echo "TC-634-D: create_interview with error_count=1 emits RE-ENTRY DETECTED escalation (symmetric with TC-634-B)"
dir634d="$GUARD_TEST_DIR/tc634d"
mkdir -p "$dir634d"
fresh_ts="${fresh_ts:-$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")}"
create_state_file "$dir634d" "{\"active\": true, \"phase\": \"create_interview\", \"previous_phase\": \"\", \"next_action\": \"continue\", \"updated_at\": \"$fresh_ts\", \"issue_number\": 634, \"pr_number\": 0, \"error_count\": 1, \"session_id\": \"sid-634d\"}"
stderr_file634d="$(mktemp "$GUARD_TEST_DIR/stderr634d.XXXXXX")"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir634d\", \"session_id\": \"sid-634d\"}"
output=$(echo "$input" | bash "$GUARD" 2>"$stderr_file634d") && rc=0 || rc=$?
state_error_count_d=$(jq -r '.error_count // empty' "$dir634d/.rite-flow-state" 2>/dev/null)
if [ $rc -eq 2 ] \
    && grep -q "RE-ENTRY DETECTED" "$stderr_file634d" \
    && grep -q "error_count=2" "$stderr_file634d" \
    && grep -q "previous block did not advance the phase" "$stderr_file634d" \
    && [ "$state_error_count_d" = "2" ]; then
  pass "create_interview error_count=1 → RE-ENTRY DETECTED escalation + case-arm-specific HINT + state file error_count=2 (symmetric with TC-634-B)"
else
  fail "expected create_interview escalation with RE-ENTRY DETECTED + create_interview-specific HINT 'previous block did not advance the phase' + error_count=2 in state, got rc=$rc, state_error_count='$state_error_count_d', stderr='$(cat "$stderr_file634d")'"
fi

# --------------------------------------------------------------------------
# TC-634-E: STEP_0_PATCH_FAILED twin site contract verification (verified-review cycle 3 F-04 / #636)
# Issue #634: stop-guard.sh の create_post_interview case arm base HINT block (line-number 参照を避ける理由は cycle 8 F-05 参照) が '[CONTEXT] STEP_0_PATCH_FAILED=1' grep 参照を LLM に指示
# (cycle 2 F-05 consumer wiring として追加)。create.md Step 0 bash block 失敗時の emit 側との
# twin site contract を verify する。片側の削除/リネームを catch する。
# --------------------------------------------------------------------------
echo "TC-634-E: create_post_interview HINT includes STEP_0_PATCH_FAILED grep reference (twin site contract)"
dir634e="$GUARD_TEST_DIR/tc634e"
mkdir -p "$dir634e"
fresh_ts="${fresh_ts:-$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")}"
create_state_file "$dir634e" "{\"active\": true, \"phase\": \"create_post_interview\", \"previous_phase\": \"create_interview\", \"next_action\": \"Proceed to Phase 0.6. Do NOT stop.\", \"updated_at\": \"$fresh_ts\", \"issue_number\": 634, \"pr_number\": 0, \"error_count\": 0, \"session_id\": \"sid-634e\"}"
stderr_file634e="$(mktemp "$GUARD_TEST_DIR/stderr634e.XXXXXX")"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir634e\", \"session_id\": \"sid-634e\"}"
output=$(echo "$input" | bash "$GUARD" 2>"$stderr_file634e") && rc=0 || rc=$?
if [ $rc -eq 2 ] \
    && grep -q "STEP_0_PATCH_FAILED=1" "$stderr_file634e" \
    && grep -q "a patch site failed" "$stderr_file634e"; then
  pass "create_post_interview HINT includes [CONTEXT] STEP_0_PATCH_FAILED=1 grep reference (twin site contract preserved)"
else
  fail "expected STEP_0_PATCH_FAILED=1 grep hint + natural-language explanation ('a patch site failed') in HINT for twin site contract, got rc=$rc stderr='$(cat "$stderr_file634e")'"
fi

# --------------------------------------------------------------------------
# TC-475-D: create_completed is terminal — no block
# --------------------------------------------------------------------------
echo "TC-475-D: create_completed + active=false → exit 0 (terminal)"
dir475d="$GUARD_TEST_DIR/tc475d"
mkdir -p "$dir475d"
create_state_file "$dir475d" "{\"active\": false, \"phase\": \"create_completed\", \"next_action\": \"none\", \"updated_at\": \"$fresh_ts\", \"session_id\": \"sid-475d\"}"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir475d\", \"session_id\": \"sid-475d\"}"
output=$(run_guard "$input") && rc=0 || rc=$?
if [ $rc -eq 0 ]; then
  pass "create_completed terminal allows stop"
else
  fail "expected exit 0, got $rc"
fi

# --------------------------------------------------------------------------
# TC-608-A: cleanup phase (active=true, fresh) → exit 2 (block)
# Verifies that the cleanup initial phase added in #608 follow-up surfaces a HINT
# and blocks premature stop. Uses the direct `bash "$GUARD" 2>"$stderr_file"` pattern
# (parity with TC-475-A) because run_guard sets LAST_STDERR_FILE inside a subshell.
# --------------------------------------------------------------------------
echo "TC-608-A: cleanup active → exit 2 (block)"
dir608a="$GUARD_TEST_DIR/tc608a"
mkdir -p "$dir608a"
# Defensive: ${var:-default} は未定義・空のどちらにも作用する bash 仕様に従ったフォールバック。
# cross-TC 独立性 (TC-475-A が削除/移動されても単独実行可能) を担保する。
# (TC-475-A が定義する fresh_ts を優先し、単独実行時は新規生成する)
fresh_ts="${fresh_ts:-$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")}"
create_state_file "$dir608a" "{\"active\": true, \"phase\": \"cleanup\", \"previous_phase\": \"\", \"next_action\": \"Execute cleanup phases. Do NOT stop.\", \"updated_at\": \"$fresh_ts\", \"issue_number\": 0, \"pr_number\": 0, \"error_count\": 0, \"session_id\": \"sid-608a\"}"
stderr_file608a="$(mktemp "$GUARD_TEST_DIR/stderr608a.XXXXXX")"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir608a\", \"session_id\": \"sid-608a\"}"
output=$(echo "$input" | bash "$GUARD" 2>"$stderr_file608a") && rc=0 || rc=$?
# HINT の前半 (Phase 1.0) と後半 (cleanup_pre_ingest) を 2 段で検証し、
# HINT 文言が改変された場合の regression を確実に検出する
if [ $rc -eq 2 ] \
    && grep -q "/rite:pr:cleanup Phase 1.0" "$stderr_file608a" \
    && grep -q "cleanup_pre_ingest" "$stderr_file608a"; then
  pass "cleanup active → blocked with cleanup-specific HINT (Phase 1.0 + cleanup_pre_ingest)"
else
  fail "expected exit 2 with HINT containing both 'Phase 1.0' and 'cleanup_pre_ingest', got rc=$rc stderr='$(cat "$stderr_file608a")'"
fi

# --------------------------------------------------------------------------
# TC-608-B: cleanup → cleanup_pre_ingest transition is whitelist-valid
# --------------------------------------------------------------------------
echo "TC-608-B: cleanup → cleanup_pre_ingest whitelist-valid"
dir608b="$GUARD_TEST_DIR/tc608b"
mkdir -p "$dir608b"
# Defensive: ${var:-default} は未定義・空のどちらにも作用する bash 仕様に従ったフォールバック。
# cross-TC 独立性 (TC-475-A が削除/移動されても単独実行可能) を担保する。
fresh_ts="${fresh_ts:-$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")}"
create_state_file "$dir608b" "{\"active\": true, \"phase\": \"cleanup_pre_ingest\", \"previous_phase\": \"cleanup\", \"next_action\": \"continue\", \"updated_at\": \"$fresh_ts\", \"issue_number\": 0, \"pr_number\": 0, \"error_count\": 0, \"session_id\": \"sid-608b\"}"
stderr_file608b="$(mktemp "$GUARD_TEST_DIR/stderr608b.XXXXXX")"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir608b\", \"session_id\": \"sid-608b\"}"
output=$(echo "$input" | bash "$GUARD" 2>"$stderr_file608b") && rc=0 || rc=$?
# HINT 内容も検証 (TC-608-A と parity、stop-guard.sh の 'case "$PHASE" in ... cleanup_pre_ingest)' branch の
# "Phase 4.W.2 phase recorded" HINT の regression を検出。line-number 参照を避ける理由は cycle 8 F-05 参照)
if [ $rc -eq 2 ] \
    && ! grep -q "Invalid phase transition" "$stderr_file608b" \
    && grep -q "Phase 4.W.2 phase recorded" "$stderr_file608b"; then
  pass "cleanup→cleanup_pre_ingest whitelist-valid + Phase 4.W.2 HINT"
else
  fail "expected exit 2 without invalid_transition with Phase 4.W.2 HINT, got rc=$rc stderr='$(cat "$stderr_file608b")'"
fi

# --------------------------------------------------------------------------
# TC-608-C: invalid transition cleanup → cleanup_post_ingest (bypassing pre_ingest)
# --------------------------------------------------------------------------
echo "TC-608-C: invalid transition cleanup → cleanup_post_ingest → blocked with invalid_transition"
dir608c="$GUARD_TEST_DIR/tc608c"
mkdir -p "$dir608c"
# Defensive: ${var:-default} は未定義・空のどちらにも作用する bash 仕様に従ったフォールバック。
# cross-TC 独立性 (TC-475-A が削除/移動されても単独実行可能) を担保する。
fresh_ts="${fresh_ts:-$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")}"
create_state_file "$dir608c" "{\"active\": true, \"phase\": \"cleanup_post_ingest\", \"previous_phase\": \"cleanup\", \"next_action\": \"skipped pre_ingest\", \"updated_at\": \"$fresh_ts\", \"issue_number\": 0, \"pr_number\": 0, \"error_count\": 0, \"session_id\": \"sid-608c\"}"
stderr_file608c="$(mktemp "$GUARD_TEST_DIR/stderr608c.XXXXXX")"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir608c\", \"session_id\": \"sid-608c\"}"
output=$(echo "$input" | bash "$GUARD" 2>"$stderr_file608c") && rc=0 || rc=$?
if [ $rc -eq 2 ] && grep -q "Invalid phase transition" "$stderr_file608c"; then
  pass "invalid transition cleanup→cleanup_post_ingest detected"
else
  fail "expected exit 2 with Invalid phase transition, got rc=$rc stderr='$(cat "$stderr_file608c")'"
fi

# --------------------------------------------------------------------------
# TC-608-D: cleanup_completed is terminal — no block
# --------------------------------------------------------------------------
echo "TC-608-D: cleanup_completed + active=false → exit 0 (terminal)"
dir608d="$GUARD_TEST_DIR/tc608d"
mkdir -p "$dir608d"
# Defensive: ${var:-default} は未定義・空のどちらにも作用する bash 仕様に従ったフォールバック。
# cross-TC 独立性 (TC-475-A が削除/移動されても単独実行可能) を担保する。
fresh_ts="${fresh_ts:-$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")}"
create_state_file "$dir608d" "{\"active\": false, \"phase\": \"cleanup_completed\", \"next_action\": \"none\", \"updated_at\": \"$fresh_ts\", \"session_id\": \"sid-608d\"}"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir608d\", \"session_id\": \"sid-608d\"}"
output=$(run_guard "$input") && rc=0 || rc=$?
# NOTE: active=false で stop-guard.sh の `if [ "$ACTIVE" != "true" ]; then exit 0` early exit するため、
# whitelist の terminal acceptance (`rite_phase_transition_allowed()` の
# `[ "$next" = "cleanup_completed" ] && return 0` terminal fast-path) は経由しない。
# `cleanup_completed` を whitelist から削除しても本 TC は pass する false-positive 構造。
# Terminal acceptance 経由は TC-608-F で検証する。
if [ $rc -eq 0 ]; then
  pass "cleanup_completed + active=false → exit 0 (early exit at active check, whitelist not exercised)"
else
  fail "expected exit 0, got $rc"
fi

# --------------------------------------------------------------------------
# TC-608-E: cleanup_pre_ingest → cleanup_post_ingest transition is whitelist-valid (Mandatory After)
# Covers the core transition that Issue #604 multi-layer defense depends on.
# --------------------------------------------------------------------------
echo "TC-608-E: cleanup_pre_ingest → cleanup_post_ingest whitelist-valid"
dir608e="$GUARD_TEST_DIR/tc608e"
mkdir -p "$dir608e"
# Defensive: ${var:-default} は未定義・空のどちらにも作用する bash 仕様に従ったフォールバック。
# cross-TC 独立性 (TC-475-A が削除/移動されても単独実行可能) を担保する。
fresh_ts="${fresh_ts:-$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")}"
create_state_file "$dir608e" "{\"active\": true, \"phase\": \"cleanup_post_ingest\", \"previous_phase\": \"cleanup_pre_ingest\", \"next_action\": \"emit [cleanup:completed]\", \"updated_at\": \"$fresh_ts\", \"issue_number\": 0, \"pr_number\": 0, \"error_count\": 0, \"session_id\": \"sid-608e\"}"
stderr_file608e="$(mktemp "$GUARD_TEST_DIR/stderr608e.XXXXXX")"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir608e\", \"session_id\": \"sid-608e\"}"
output=$(echo "$input" | bash "$GUARD" 2>"$stderr_file608e") && rc=0 || rc=$?
# rc=2 を明示 assert (active=true 経路で block が維持されることを確認、active 判定 regression 検出)
if [ $rc -eq 2 ] && ! grep -q "Invalid phase transition" "$stderr_file608e"; then
  pass "cleanup_pre_ingest→cleanup_post_ingest whitelist pass + rc=2 block maintained"
else
  fail "expected rc=2 without invalid_transition, got rc=$rc stderr='$(cat "$stderr_file608e")'"
fi

# --------------------------------------------------------------------------
# TC-608-F: cleanup_post_ingest → cleanup_completed transition is whitelist-valid (Terminal Completion)
# Covers the terminal transition that must be accepted for Phase 5 Completion Report.
# active=true でも whitelist pass を保証する。
# --------------------------------------------------------------------------
echo "TC-608-F: cleanup_post_ingest → cleanup_completed whitelist-valid (active=true path)"
dir608f="$GUARD_TEST_DIR/tc608f"
mkdir -p "$dir608f"
# Defensive: ${var:-default} は未定義・空のどちらにも作用する bash 仕様に従ったフォールバック。
# cross-TC 独立性 (TC-475-A が削除/移動されても単独実行可能) を担保する。
fresh_ts="${fresh_ts:-$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")}"
create_state_file "$dir608f" "{\"active\": true, \"phase\": \"cleanup_completed\", \"previous_phase\": \"cleanup_post_ingest\", \"next_action\": \"terminal\", \"updated_at\": \"$fresh_ts\", \"issue_number\": 0, \"pr_number\": 0, \"error_count\": 0, \"session_id\": \"sid-608f\"}"
stderr_file608f="$(mktemp "$GUARD_TEST_DIR/stderr608f.XXXXXX")"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir608f\", \"session_id\": \"sid-608f\"}"
output=$(echo "$input" | bash "$GUARD" 2>"$stderr_file608f") && rc=0 || rc=$?
# whitelist の terminal acceptance path を経由 + rc=2 (active=true で block 維持) を明示検証
# NOTE (cycle 9 F-04/F-06 明示化): rite_phase_transition_allowed() 内の評価順序上、
#   terminal fast-path `[ "$next" = "cleanup_completed" ] && return 0` が explicit edge の
#   for-loop より先に return するため、next=cleanup_completed を input とする本 TC は
#   **terminal fast-path 経由のみ** が保証される。`["cleanup_post_ingest"]="cleanup_completed"`
#   の explicit edge entry を削除しても本 TC は依然 pass する false-positive 構造。
#   explicit edge の regression を検出するには phase-transition-whitelist.sh を source して
#   rite_phase_transition_allowed() を直接 unit-level で呼び出す別 test file が必要。
#   (integration test である本ファイルには internal 評価順序まで見えないため本質的限界)
#   TODO (cycle 10 F-09): phase-transition-whitelist unit test 新設は別 Issue で tracking 予定。
if [ $rc -eq 2 ] && ! grep -q "Invalid phase transition" "$stderr_file608f"; then
  pass "cleanup_post_ingest→cleanup_completed whitelist pass + rc=2 block maintained"
else
  fail "expected rc=2 without invalid_transition, got rc=$rc stderr='$(cat "$stderr_file608f")'"
fi

# --------------------------------------------------------------------------
# TC-608-G: Pin current permissive behavior — cleanup → cleanup_completed (skip pre/post_ingest)
# 現状は以下 2 つの受理要因が存在する (tighten 時は両方を対象に判断が必要):
#   (a) phase-transition-whitelist.sh の明示的 edge `["cleanup"]="cleanup_pre_ingest cleanup_completed"`
#   (b) phase-transition-whitelist.sh の terminal forward-compat (cleanup_completed が terminal acceptance)
# 将来 tighten された際に TC 追加が必要であることを pin する目的。
# --------------------------------------------------------------------------
echo "TC-608-G: cleanup → cleanup_completed direct skip is currently accepted (terminal forward-compat)"
dir608g="$GUARD_TEST_DIR/tc608g"
mkdir -p "$dir608g"
# Defensive: ${var:-default} は未定義・空のどちらにも作用する bash 仕様に従ったフォールバック。
# cross-TC 独立性 (TC-475-A が削除/移動されても単独実行可能) を担保する。
fresh_ts="${fresh_ts:-$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")}"
create_state_file "$dir608g" "{\"active\": true, \"phase\": \"cleanup_completed\", \"previous_phase\": \"cleanup\", \"next_action\": \"terminal\", \"updated_at\": \"$fresh_ts\", \"issue_number\": 0, \"pr_number\": 0, \"error_count\": 0, \"session_id\": \"sid-608g\"}"
stderr_file608g="$(mktemp "$GUARD_TEST_DIR/stderr608g.XXXXXX")"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir608g\", \"session_id\": \"sid-608g\"}"
output=$(echo "$input" | bash "$GUARD" 2>"$stderr_file608g") && rc=0 || rc=$?
# 現状は (a) 明示的 edge + (b) terminal forward-compat の両方により受理される
# rc=2 を明示 assert (active=true で block が維持されることを確認、permissive pin 目的)
# NOTE (cycle 9 F-04 明示化): rite_phase_transition_allowed() の評価順序上、
#   terminal fast-path `[ "$next" = "cleanup_completed" ] && return 0` が先に return するため、
#   next=cleanup_completed を input とする本 TC は **terminal fast-path 経由のみ** が保証される。
#   (a) 明示的 edge と (b) terminal fast-path は OR 結合で、片方を削除しても本 TC は依然 pass する。
#   discriminate するには phase-transition-whitelist.sh を source して rite_phase_transition_allowed()
#   を直接呼び出す unit test が必要 (integration test である本ファイルには internal 評価順序まで見えない)。
#   tighten 時は (a)(b) 両方を対象に判断する必要があり、その際は本 NOTE を更新すること。
#   TODO (cycle 10 F-09): phase-transition-whitelist unit test 新設は別 Issue で tracking 予定。
if [ $rc -eq 2 ] && ! grep -q "Invalid phase transition" "$stderr_file608g"; then
  pass "cleanup→cleanup_completed direct skip accepted + rc=2 block maintained (permissive NOTE pin)"
else
  fail "cleanup→cleanup_completed direct skip was rejected or rc != 2 — whitelist tightening may have occurred. Update TC-608-G and whitelist NOTE if intentional. rc=$rc stderr='$(cat "$stderr_file608g")'"
fi

# --------------------------------------------------------------------------
# TC-608-H: cleanup_post_ingest HINT 文言 regression guard
# stop-guard.sh の cleanup_post_ingest case の HINT 文言 "Phase 5 Completion Report has NOT been output yet"
# が改変されても検出するための 2 段検証 (TC-608-A/B と parity)。
# --------------------------------------------------------------------------
echo "TC-608-H: cleanup_post_ingest active → HINT '[Phase 5 Completion Report has NOT been output yet]' pinned"
dir608h="$GUARD_TEST_DIR/tc608h"
mkdir -p "$dir608h"
# Defensive: ${var:-default} は未定義・空のどちらにも作用する bash 仕様に従ったフォールバック。
# cross-TC 独立性 (TC-475-A が削除/移動されても単独実行可能) を担保する。
fresh_ts="${fresh_ts:-$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")}"
create_state_file "$dir608h" "{\"active\": true, \"phase\": \"cleanup_post_ingest\", \"previous_phase\": \"cleanup_pre_ingest\", \"next_action\": \"emit Phase 5 completion report\", \"updated_at\": \"$fresh_ts\", \"issue_number\": 0, \"pr_number\": 0, \"error_count\": 0, \"session_id\": \"sid-608h\"}"
stderr_file608h="$(mktemp "$GUARD_TEST_DIR/stderr608h.XXXXXX")"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir608h\", \"session_id\": \"sid-608h\"}"
output=$(echo "$input" | bash "$GUARD" 2>"$stderr_file608h") && rc=0 || rc=$?
# HINT の必須 phrase 2 つ (rite:wiki:ingest returned + Phase 5 Completion Report has NOT) を両方検証
if [ $rc -eq 2 ] \
    && grep -q "rite:wiki:ingest returned" "$stderr_file608h" \
    && grep -q "Phase 5 Completion Report has NOT been output" "$stderr_file608h"; then
  pass "cleanup_post_ingest active → blocked with HINT containing 'rite:wiki:ingest returned' and 'Phase 5 Completion Report has NOT been output'"
else
  fail "expected rc=2 with both HINT phrases present, got rc=$rc stderr='$(cat "$stderr_file608h")'"
fi

# --------------------------------------------------------------------------
# TC-608-I: IFS delimiter regression guard (cycle 10 CRITICAL F-01)
# previous_phase="" (新規 create 直後 / 手動 state file) のとき、旧実装
# `IFS=$'\t' read ... | @tsv` は POSIX whitespace IFS collapse により全フィールドが
# 1 つ左 shift し ERROR_COUNT が empty → `[ "" -ge "$THRESHOLD" ]` 整数エラーが発生、
# error loop の threshold path が永久に発火しない silent corruption を起こしていた。
# 本 TC は unit separator (\x1f) への修正が正しく適用され、ERROR_COUNT が整数として
# parse されることを verify する。
# --------------------------------------------------------------------------
echo "TC-608-I: IFS regression — previous_phase='' + error_count=0 → threshold path parses correctly"
dir608i="$GUARD_TEST_DIR/tc608i"
mkdir -p "$dir608i"
# Defensive: ${var:-default} は未定義・空のどちらにも作用する bash 仕様に従ったフォールバック。
# cross-TC 独立性 (TC-475-A が削除/移動されても単独実行可能) を担保する。
fresh_ts="${fresh_ts:-$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")}"
# previous_phase は空文字列 (新規 create 直後の初期状態を模倣)
# error_count は 0 (threshold 未達)、block が正しく機能することを確認
create_state_file "$dir608i" "{\"active\": true, \"phase\": \"phase5_implementation\", \"previous_phase\": \"\", \"next_action\": \"continue\", \"updated_at\": \"$fresh_ts\", \"issue_number\": 0, \"pr_number\": 0, \"error_count\": 0, \"session_id\": \"sid-608i\"}"
stderr_file608i="$(mktemp "$GUARD_TEST_DIR/stderr608i.XXXXXX")"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir608i\", \"session_id\": \"sid-608i\"}"
output=$(echo "$input" | bash "$GUARD" 2>"$stderr_file608i") && rc=0 || rc=$?
# IFS collapsing bug があると stderr に bash 整数比較エラー (日本語 locale では
# "整数の式が予期されます"、LC_ALL=C / en_US locale では "integer expression expected") が
# 出現し rc=0 (threshold-bypass) で許可してしまう。
# cycle 11 F-03: locale-independent 検証のため、両 phrase を OR で negative grep する。
# CI 環境 (多くが LC_ALL=C) で false-negative (silent pass) を起こさない設計。
if [ $rc -eq 2 ] \
    && ! grep -q "整数の式が予期されます" "$stderr_file608i" \
    && ! grep -q "integer expression expected" "$stderr_file608i"; then
  pass "previous_phase='' で ERROR_COUNT が正しく 0 として parse され block 継続 (IFS regression guard、locale-independent)"
else
  fail "expected rc=2 without integer parse error (either locale), got rc=$rc stderr='$(cat "$stderr_file608i")'"
fi

# --------------------------------------------------------------------------
# TC-634-F: escalation path STEP_0_PATCH_FAILED grep 指示 coverage
#   (verified-review cycle 4 F-07 / #636)
# TC-634-E は error_count=0 fresh state の通常 path のみカバー。本 TC は escalation 分岐
# (`error_count >= 1` で WORKFLOW_HINT に RE-ENTRY DETECTED を append する branch、
# line-number 参照を避ける理由は cycle 8 F-05 参照)
# を経由しても base HINT の STEP_0_PATCH_FAILED=1 grep 指示が保持されることを verify する。
# --------------------------------------------------------------------------
echo "TC-634-F: create_post_interview + error_count=1 (escalation) still emits STEP_0_PATCH_FAILED grep reference"
dir634f="$GUARD_TEST_DIR/tc634f"
mkdir -p "$dir634f"
fresh_ts="${fresh_ts:-$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")}"
create_state_file "$dir634f" "{\"active\": true, \"phase\": \"create_post_interview\", \"previous_phase\": \"create_interview\", \"next_action\": \"Proceed to Phase 0.6. Do NOT stop.\", \"updated_at\": \"$fresh_ts\", \"issue_number\": 634, \"pr_number\": 0, \"error_count\": 1, \"session_id\": \"sid-634f\"}"
stderr_file634f="$(mktemp "$GUARD_TEST_DIR/stderr634f.XXXXXX")"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir634f\", \"session_id\": \"sid-634f\"}"
output=$(echo "$input" | bash "$GUARD" 2>"$stderr_file634f") && rc=0 || rc=$?
if [ $rc -eq 2 ] \
    && grep -q "STEP_0_PATCH_FAILED=1" "$stderr_file634f" \
    && grep -q "RE-ENTRY DETECTED" "$stderr_file634f"; then
  pass "create_post_interview escalation path preserves STEP_0_PATCH_FAILED grep reference (twin site contract holds during error_count>=1)"
else
  fail "expected STEP_0_PATCH_FAILED=1 grep hint retained in escalation path, got rc=$rc stderr='$(cat "$stderr_file634f")'"
fi

# --------------------------------------------------------------------------
# TC-634-G/H/I/J: twin-site contract verification for the 4 additional retained flags
#   (verified-review cycle 4 F-04 / #636)
# cycle 3 F-04 で STEP_0_PATCH_FAILED の twin-site contract を TC-634-E で pin したが、cycle 3 で
# 新規追加された 4 flag (STEP_1_PATCH_FAILED, PREFLIGHT_PATCH_FAILED, PREFLIGHT_CREATE_FAILED,
# INTERVIEW_RETURN_PATCH_FAILED) は consumer 側 (stop-guard HINT + test) で grep 指示されていな
# かった (cycle 2 F-05 の dead-marker 回避方針に反する asymmetry)。cycle 4 で HINT に grep 指示
# を追加したので、本 4 TC でその contract を pin する。片側の削除/リネームを catch する。
# --------------------------------------------------------------------------
echo "TC-634-G: create_interview HINT includes PREFLIGHT_PATCH_FAILED grep reference (twin site contract)"
dir634g="$GUARD_TEST_DIR/tc634g"
mkdir -p "$dir634g"
fresh_ts="${fresh_ts:-$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")}"
create_state_file "$dir634g" "{\"active\": true, \"phase\": \"create_interview\", \"previous_phase\": \"\", \"next_action\": \"continue\", \"updated_at\": \"$fresh_ts\", \"issue_number\": 634, \"pr_number\": 0, \"error_count\": 0, \"session_id\": \"sid-634g\"}"
stderr_file634g="$(mktemp "$GUARD_TEST_DIR/stderr634g.XXXXXX")"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir634g\", \"session_id\": \"sid-634g\"}"
output=$(echo "$input" | bash "$GUARD" 2>"$stderr_file634g") && rc=0 || rc=$?
if [ $rc -eq 2 ] \
    && grep -q "PREFLIGHT_PATCH_FAILED=1" "$stderr_file634g"; then
  pass "create_interview HINT includes [CONTEXT] PREFLIGHT_PATCH_FAILED=1 grep reference"
else
  fail "expected PREFLIGHT_PATCH_FAILED=1 grep hint, got rc=$rc stderr='$(cat "$stderr_file634g")'"
fi

echo "TC-634-H: create_interview HINT includes PREFLIGHT_CREATE_FAILED grep reference (twin site contract)"
dir634h="$GUARD_TEST_DIR/tc634h"
mkdir -p "$dir634h"
fresh_ts="${fresh_ts:-$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")}"
create_state_file "$dir634h" "{\"active\": true, \"phase\": \"create_interview\", \"previous_phase\": \"\", \"next_action\": \"continue\", \"updated_at\": \"$fresh_ts\", \"issue_number\": 634, \"pr_number\": 0, \"error_count\": 0, \"session_id\": \"sid-634h\"}"
stderr_file634h="$(mktemp "$GUARD_TEST_DIR/stderr634h.XXXXXX")"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir634h\", \"session_id\": \"sid-634h\"}"
output=$(echo "$input" | bash "$GUARD" 2>"$stderr_file634h") && rc=0 || rc=$?
if [ $rc -eq 2 ] \
    && grep -q "PREFLIGHT_CREATE_FAILED=1" "$stderr_file634h"; then
  pass "create_interview HINT includes [CONTEXT] PREFLIGHT_CREATE_FAILED=1 grep reference"
else
  fail "expected PREFLIGHT_CREATE_FAILED=1 grep hint, got rc=$rc stderr='$(cat "$stderr_file634h")'"
fi

echo "TC-634-I: create_interview HINT includes INTERVIEW_RETURN_PATCH_FAILED grep reference (twin site contract)"
dir634i="$GUARD_TEST_DIR/tc634i"
mkdir -p "$dir634i"
fresh_ts="${fresh_ts:-$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")}"
create_state_file "$dir634i" "{\"active\": true, \"phase\": \"create_interview\", \"previous_phase\": \"\", \"next_action\": \"continue\", \"updated_at\": \"$fresh_ts\", \"issue_number\": 634, \"pr_number\": 0, \"error_count\": 0, \"session_id\": \"sid-634i\"}"
stderr_file634i="$(mktemp "$GUARD_TEST_DIR/stderr634i.XXXXXX")"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir634i\", \"session_id\": \"sid-634i\"}"
output=$(echo "$input" | bash "$GUARD" 2>"$stderr_file634i") && rc=0 || rc=$?
if [ $rc -eq 2 ] \
    && grep -q "INTERVIEW_RETURN_PATCH_FAILED=1" "$stderr_file634i"; then
  pass "create_interview HINT includes [CONTEXT] INTERVIEW_RETURN_PATCH_FAILED=1 grep reference"
else
  fail "expected INTERVIEW_RETURN_PATCH_FAILED=1 grep hint, got rc=$rc stderr='$(cat "$stderr_file634i")'"
fi

echo "TC-634-J: create_post_interview HINT includes STEP_1_PATCH_FAILED grep reference (twin site contract)"
dir634j="$GUARD_TEST_DIR/tc634j"
mkdir -p "$dir634j"
fresh_ts="${fresh_ts:-$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")}"
create_state_file "$dir634j" "{\"active\": true, \"phase\": \"create_post_interview\", \"previous_phase\": \"create_interview\", \"next_action\": \"Proceed to Phase 0.6. Do NOT stop.\", \"updated_at\": \"$fresh_ts\", \"issue_number\": 634, \"pr_number\": 0, \"error_count\": 0, \"session_id\": \"sid-634j\"}"
stderr_file634j="$(mktemp "$GUARD_TEST_DIR/stderr634j.XXXXXX")"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir634j\", \"session_id\": \"sid-634j\"}"
output=$(echo "$input" | bash "$GUARD" 2>"$stderr_file634j") && rc=0 || rc=$?
if [ $rc -eq 2 ] \
    && grep -q "STEP_1_PATCH_FAILED=1" "$stderr_file634j"; then
  pass "create_post_interview HINT includes [CONTEXT] STEP_1_PATCH_FAILED=1 grep reference"
else
  fail "expected STEP_1_PATCH_FAILED=1 grep hint, got rc=$rc stderr='$(cat "$stderr_file634j")'"
fi

# --------------------------------------------------------------------------
# TC-634-K/L: flow-state-update.sh --preserve-error-count flag behavior pin
#   (verified-review cycle 4 F-03 / #636)
# cycle 3 F-01 で patch mode JQ_FILTER 分岐 (--preserve-error-count) を実装したが、既存 TC-634-B/D
# の error_count=2 観察は stop-guard.sh の create_post_interview case arm 内 error_count increment
# block (直接 `jq --argjson cnt` で state file を atomic write する経路、line-number 参照を避ける理由は
# cycle 8 F-05 参照) 経由で、flow-state-update.sh patch mode の preserve 分岐 (新コード) を
# exercise しない。本 2 TC で JQ_FILTER 分岐を直接 verify し、将来の refactor で silent regression
# しないよう pin する。
# --------------------------------------------------------------------------
SCRIPT_UPDATER="$SCRIPT_DIR/../flow-state-update.sh"

echo "TC-634-K: flow-state-update.sh patch --preserve-error-count preserves existing error_count"
dir634k="$GUARD_TEST_DIR/tc634k"
mkdir -p "$dir634k"
fresh_ts="${fresh_ts:-$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")}"
# error_count=2 の state を手動作成
# root-cause(test-quality): stderr suppress + exit code 未検査 + next_action 未検査の 3 条件が
# 揃うと「スクリプトが一切実行されなくても pre-state の error_count=2 がそのまま残って PASS」
# する silent-false-pass を起こす。本 TC は JQ_FILTER 分岐 silent regression 検出 pin の
# 役割を果たせないため、exit code + next_action の両方を assertion する。
create_state_file "$dir634k" "{\"active\": true, \"phase\": \"create_post_interview\", \"previous_phase\": \"create_interview\", \"next_action\": \"before\", \"updated_at\": \"$fresh_ts\", \"issue_number\": 634, \"pr_number\": 0, \"error_count\": 2, \"session_id\": \"sid-634k\"}"
# --preserve-error-count 付き patch を実行 (同一 phase self-patch)
stderr_file634k=$(mktemp /tmp/rite-tc634k-stderr-XXXXXX)
(
  cd "$dir634k"
  bash "$SCRIPT_UPDATER" patch --phase "create_post_interview" --next "after preserve" --preserve-error-count
) 2>"$stderr_file634k"
rc634k=$?
state_error_count_k=$(jq -r '.error_count // empty' "$dir634k/.rite-flow-state" 2>/dev/null)
state_next_k=$(jq -r '.next_action // empty' "$dir634k/.rite-flow-state" 2>/dev/null)
if [ "$rc634k" -eq 0 ] && [ "$state_error_count_k" = "2" ] && [ "$state_next_k" = "after preserve" ]; then
  pass "flow-state-update.sh patch --preserve-error-count keeps error_count=2 intact (rc=0, next_action advanced)"
else
  fail "TC-634-K failed: rc=$rc634k, error_count='$state_error_count_k' (expected 2), next_action='$state_next_k' (expected 'after preserve'). stderr=$(cat "$stderr_file634k")"
fi
rm -f "$stderr_file634k"

echo "TC-634-L: flow-state-update.sh patch WITHOUT --preserve-error-count resets error_count to 0"
dir634l="$GUARD_TEST_DIR/tc634l"
mkdir -p "$dir634l"
fresh_ts="${fresh_ts:-$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")}"
# error_count=2 の state を手動作成
# root-cause(test-quality): TC-634-K と同じ silent-false-pass 経路を持つため、exit code +
# next_action 変化 + error_count reset の 3 条件を全て assertion して JQ_FILTER default 分岐
# (reset-to-zero) の silent regression を検出する。
create_state_file "$dir634l" "{\"active\": true, \"phase\": \"create_post_interview\", \"previous_phase\": \"create_interview\", \"next_action\": \"before\", \"updated_at\": \"$fresh_ts\", \"issue_number\": 634, \"pr_number\": 0, \"error_count\": 2, \"session_id\": \"sid-634l\"}"
# flag 無しの patch を実行
stderr_file634l=$(mktemp /tmp/rite-tc634l-stderr-XXXXXX)
(
  cd "$dir634l"
  bash "$SCRIPT_UPDATER" patch --phase "create_delegation" --next "after reset"
) 2>"$stderr_file634l"
rc634l=$?
state_error_count_l=$(jq -r '.error_count // empty' "$dir634l/.rite-flow-state" 2>/dev/null)
state_next_l=$(jq -r '.next_action // empty' "$dir634l/.rite-flow-state" 2>/dev/null)
if [ "$rc634l" -eq 0 ] && [ "$state_error_count_l" = "0" ] && [ "$state_next_l" = "after reset" ]; then
  pass "flow-state-update.sh patch without --preserve-error-count resets error_count=2 → 0 (rc=0, next_action advanced)"
else
  fail "TC-634-L failed: rc=$rc634l, error_count='$state_error_count_l' (expected 0), next_action='$state_next_l' (expected 'after reset'). stderr=$(cat "$stderr_file634l")"
fi
rm -f "$stderr_file634l"

# --------------------------------------------------------------------------
# TC-634-M/N: fault injection for mv failure diagnostic paths
#   (verified-review cycle 5 F-04 / #636)
# cycle 4 F-05/F-07/F-08 で stop-guard.sh の error_count atomic write 後 mv 失敗 path と
# flow-state-update.sh の create/patch/increment mode mv 失敗 path に diagnostic message を
# 追加したが、test が一切存在せず revert しても全 test が PASS する silent-failure 状態だった。
# fault injection (PATH override で偽の mv を先頭に挿入) で mv 失敗を再現し、diagnostic log が
# 記録されること / stderr に mv failed が emit されることを verify する。
# --------------------------------------------------------------------------

echo "TC-634-M: stop-guard.sh mv failure (fault injection) emits error_count_mv_failed diag log"
dir634m="$GUARD_TEST_DIR/tc634m"
mkdir -p "$dir634m"
# PATH override 用の fake mv binary (disk full / permission denied / EXDEV simulation)
fake_bin634m=$(mktemp -d "$GUARD_TEST_DIR/tc634m-bin-XXXXXX")
cat > "$fake_bin634m/mv" << 'FAKEMV_EOF'
#!/bin/sh
# Fault injection: simulate mv failure (e.g., disk full / permission denied / EXDEV)
exit 1
FAKEMV_EOF
chmod +x "$fake_bin634m/mv"
fresh_ts="${fresh_ts:-$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")}"
# active=true + error_count=0 で stop-guard が error_count を increment する path を通す
create_state_file "$dir634m" "{\"active\": true, \"phase\": \"create_post_interview\", \"previous_phase\": \"create_interview\", \"next_action\": \"before\", \"updated_at\": \"$fresh_ts\", \"issue_number\": 634, \"pr_number\": 0, \"error_count\": 0, \"session_id\": \"sid-634m\"}"
input634m="{\"stop_hook_active\": false, \"cwd\": \"$dir634m\"}"
# fake mv を PATH 先頭に差し込んで stop-guard.sh を起動
# stderr_file634m は debug 用に握っておく (stop-guard stderr 自体は exit 2 + block message を含む)
stderr_file634m=$(mktemp "$GUARD_TEST_DIR/tc634m-stderr-XXXXXX")
(
  PATH="$fake_bin634m:$PATH" bash "$GUARD" <<< "$input634m"
) >/dev/null 2>"$stderr_file634m" || true
# diag log に error_count_mv_failed エントリが記録されていることを verify
if [ -f "$dir634m/.rite-stop-guard-diag.log" ] \
    && grep -q "error_count_mv_failed phase=create_post_interview" "$dir634m/.rite-stop-guard-diag.log"; then
  pass "stop-guard.sh emits error_count_mv_failed diag log when mv fails (fault injection via PATH)"
else
  fail "expected 'error_count_mv_failed phase=create_post_interview' in diag log, got: $(cat "$dir634m/.rite-stop-guard-diag.log" 2>/dev/null || echo '(no diag log)'). stderr=$(cat "$stderr_file634m")"
fi
rm -f "$stderr_file634m"
rm -rf "$fake_bin634m"

echo "TC-634-N: flow-state-update.sh mv failure (fault injection) emits 'mv failed (patch mode)' stderr"
dir634n="$GUARD_TEST_DIR/tc634n"
mkdir -p "$dir634n"
fake_bin634n=$(mktemp -d "$GUARD_TEST_DIR/tc634n-bin-XXXXXX")
cat > "$fake_bin634n/mv" << 'FAKEMV_EOF'
#!/bin/sh
# Fault injection: simulate mv failure in flow-state-update.sh patch mode
exit 1
FAKEMV_EOF
chmod +x "$fake_bin634n/mv"
fresh_ts="${fresh_ts:-$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")}"
# patch mode の対象 state file を事前作成 (mv 失敗後に元の state が温存されることも暗黙に pin)
create_state_file "$dir634n" "{\"active\": true, \"phase\": \"create_post_interview\", \"previous_phase\": \"create_interview\", \"next_action\": \"before\", \"updated_at\": \"$fresh_ts\", \"issue_number\": 634, \"pr_number\": 0, \"error_count\": 0, \"session_id\": \"sid-634n\"}"
stderr_file634n=$(mktemp "$GUARD_TEST_DIR/tc634n-stderr-XXXXXX")
rc634n=0
(
  cd "$dir634n"
  PATH="$fake_bin634n:$PATH" bash "$SCRIPT_UPDATER" patch --phase "create_delegation" --next "after patch"
) >/dev/null 2>"$stderr_file634n" || rc634n=$?
# flow-state-update.sh は mv 失敗時に `exit 1` するため rc=1 を期待
# かつ stderr に 'ERROR: mv failed (patch mode)' の diagnostic を期待
# F-04 (#636 cycle 7): stderr だけでなく `.rite-stop-guard-diag.log` に
# `flow_state_mv_failed mode=patch` エントリが残る (= _log_flow_diag 永続痕跡) ことも同時に verify。
# 旧実装は stderr のみ assert しており、`_log_flow_diag` を silent に revert しても
# TC-634-N が PASS する false-positive test だった (cycle 5 F-04 silent-false-pass の再発)。
diag_file634n="$dir634n/.rite-stop-guard-diag.log"
if [ "$rc634n" -ne 0 ] \
    && grep -q "mv failed (patch mode)" "$stderr_file634n" \
    && [ -f "$diag_file634n" ] \
    && grep -q "flow_state_mv_failed mode=patch" "$diag_file634n"; then
  pass "flow-state-update.sh emits 'mv failed (patch mode)' stderr AND persists 'flow_state_mv_failed mode=patch' diag log on mv failure"
else
  fail "expected rc!=0, 'mv failed (patch mode)' stderr, AND 'flow_state_mv_failed mode=patch' diag log entry; got rc=$rc634n, stderr=$(cat "$stderr_file634n"), diag=$(cat "$diag_file634n" 2>/dev/null || echo '(no diag log)')"
fi
rm -f "$stderr_file634n"
rm -rf "$fake_bin634n"

# --------------------------------------------------------------------------
# TC-634-O: AC-5 contract phrase automation — #634 review cycle 6 F-06
# Issue #634 AC-5 で必須とされる contract phrase (anti-pattern / correct-pattern /
# same response turn / DO NOT stop) の各 count >= 1 を create.md で自動検証する。
# fixture の inline grep 手順にのみ依存していた状態を test suite automation に昇格し、
# LLM が contract phrase をうっかり削除しても CI で検出できるようにする。
# --------------------------------------------------------------------------
echo "TC-634-O: AC-5 contract phrases present in create.md (anti-pattern / correct-pattern / same response turn / DO NOT stop)"
create_md="$SCRIPT_DIR/../../../../plugins/rite/commands/issue/create.md"
tc634o_ok=1
tc634o_missing=""
for phrase in "anti-pattern" "correct-pattern" "same response turn" "DO NOT stop"; do
  # grep -c は 0 件時でも stdout に "0" を出力するが、exit code は非 0 を返す。
  # 旧実装 `|| echo 0` は grep 失敗時に stdout へ追加で "0" を append し、
  # `c="0"` + 改行 + `"0"` の 2 行文字列になり、直後の `[ "$c" -lt 1 ]` が integer parse
  # error を起こし非 0 rc を返して else 分岐へ fall-through、`tc634o_ok=1` のまま PASS する
  # silent-false-pass を起こしていた (#636 cycle 7 F-01 実測確認済み)。
  # `|| true` で exit code だけ握りつぶし、grep -c の stdout 側 "0" をそのまま数値として使う。
  c=$(grep -c -- "$phrase" "$create_md" 2>/dev/null || true)
  # 異常経路 (grep が全く stdout を出力せず空) でも integer 比較が fail しないよう空→0 正規化。
  [ -z "$c" ] && c=0
  if [ "$c" -lt 1 ]; then
    tc634o_ok=0
    tc634o_missing="${tc634o_missing} $phrase (count=$c)"
  fi
done
if [ "$tc634o_ok" -eq 1 ]; then
  pass "all AC-5 contract phrases present in create.md"
else
  fail "missing AC-5 contract phrase(s):${tc634o_missing}"
fi

# --------------------------------------------------------------------------
# TC-634-P: AC-6 structural non-regression automation — #634 review cycle 6 F-06
# HTML コメント sentinel + case arm + whitelist + Pre-flight の 4 点が保持されることを
# 自動検証する。fixture の inline grep 手順を test suite に昇格。
# --------------------------------------------------------------------------
echo "TC-634-P: AC-6 structural elements present (HTML sentinel / case arm / whitelist / Pre-flight)"
interview_md="$SCRIPT_DIR/../../../../plugins/rite/commands/issue/create-interview.md"
whitelist_sh="$SCRIPT_DIR/../../../../plugins/rite/hooks/phase-transition-whitelist.sh"
tc634p_ok=1
tc634p_missing=""
grep -qF '[interview:skipped]' "$interview_md" 2>/dev/null || { tc634p_ok=0; tc634p_missing="${tc634p_missing} interview:skipped-sentinel"; }
grep -qF '[interview:completed]' "$interview_md" 2>/dev/null || { tc634p_ok=0; tc634p_missing="${tc634p_missing} interview:completed-sentinel"; }
grep -qE 'create_post_interview\)$' "$GUARD" 2>/dev/null || { tc634p_ok=0; tc634p_missing="${tc634p_missing} create_post_interview-case-arm"; }
grep -qE '\["create_post_interview"\]=' "$whitelist_sh" 2>/dev/null || { tc634p_ok=0; tc634p_missing="${tc634p_missing} whitelist-edge"; }
grep -qF 'MANDATORY Pre-flight' "$interview_md" 2>/dev/null || { tc634p_ok=0; tc634p_missing="${tc634p_missing} Pre-flight-section"; }
# F-03 (#636 cycle 7): `[create:completed:` sentinel (create.md / create-register.md / create-decompose.md の 3 点) の
# 存在を verify。Issue #634 body で AC-6 判定手段として明示された構造要素のうち、cycle 6 までの
# TC-634-P に grep が欠落していた。sentinel 削除・改名が将来発生した場合に CI で検出する。
create_md_f03="$SCRIPT_DIR/../../../../plugins/rite/commands/issue/create.md"
create_register_md_f03="$SCRIPT_DIR/../../../../plugins/rite/commands/issue/create-register.md"
create_decompose_md_f03="$SCRIPT_DIR/../../../../plugins/rite/commands/issue/create-decompose.md"
grep -qF '[create:completed:' "$create_md_f03" 2>/dev/null || { tc634p_ok=0; tc634p_missing="${tc634p_missing} create-completed-sentinel-create.md"; }
grep -qF '[create:completed:' "$create_register_md_f03" 2>/dev/null || { tc634p_ok=0; tc634p_missing="${tc634p_missing} create-completed-sentinel-create-register.md"; }
grep -qF '[create:completed:' "$create_decompose_md_f03" 2>/dev/null || { tc634p_ok=0; tc634p_missing="${tc634p_missing} create-completed-sentinel-create-decompose.md"; }
if [ "$tc634p_ok" -eq 1 ]; then
  pass "all AC-6 structural elements intact"
else
  fail "missing AC-6 structural element(s):${tc634p_missing}"
fi

# --------------------------------------------------------------------------
# TC-651-A: AC-4 — create_post_interview phase で stop-guard が exit 2 + workflow_incident
# sentinel を emit することを mechanical assertion。Issue #651 root-cause 検証で実証された
# 「stop-guard 自体は完璧に動作」を CI で永久 pin する (将来 sentinel 形式変更時の
# silent regression 検出が目的)。
# --------------------------------------------------------------------------
echo "TC-651-A: create_post_interview phase で exit 2 + [CONTEXT] WORKFLOW_INCIDENT=1; type=manual_fallback_adopted emit"
dir651a="$GUARD_TEST_DIR/tc651a"
mkdir -p "$dir651a"
fresh_ts="${fresh_ts:-$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")}"
create_state_file "$dir651a" "{\"active\": true, \"phase\": \"create_post_interview\", \"previous_phase\": \"create_interview\", \"next_action\": \"Test invocation for AC-4 verification\", \"updated_at\": \"$fresh_ts\", \"issue_number\": 651, \"pr_number\": 0, \"error_count\": 0, \"session_id\": \"sid-651a\"}"
stderr_file651a="$(mktemp "$GUARD_TEST_DIR/stderr651a.XXXXXX")"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir651a\", \"session_id\": \"sid-651a\"}"
output=$(echo "$input" | bash "$GUARD" 2>"$stderr_file651a") && rc=0 || rc=$?
if [ $rc -eq 2 ] \
    && grep -qF '[CONTEXT] WORKFLOW_INCIDENT=1' "$stderr_file651a" \
    && grep -qF 'type=manual_fallback_adopted' "$stderr_file651a" \
    && grep -qF 'phase=create_post_interview' "$stderr_file651a" \
    && grep -qF 'iteration_id=' "$stderr_file651a"; then
  pass "AC-4: exit 2 + workflow_incident sentinel (manual_fallback_adopted) emitted on create_post_interview block"
else
  fail "expected exit 2 + sentinel, got exit=$rc, stderr=$(head -3 "$stderr_file651a")"
fi

# --------------------------------------------------------------------------
# TC-651-A2: AC-4 escalation path — error_count=1 状態 (TC-634-F 相当) でも
# `[CONTEXT] WORKFLOW_INCIDENT=1; type=manual_fallback_adopted` sentinel 4 句が
# 保持されることを mechanical assertion (PR #654 review F-07 対応、initial entry path
# のみ verify していた TC-651-A の補完)。
# --------------------------------------------------------------------------
echo "TC-651-A2: create_post_interview escalation (error_count=1) でも sentinel 4 句が emit される"
dir651a2="$GUARD_TEST_DIR/tc651a2"
mkdir -p "$dir651a2"
fresh_ts="${fresh_ts:-$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")}"
create_state_file "$dir651a2" "{\"active\": true, \"phase\": \"create_post_interview\", \"previous_phase\": \"create_interview\", \"next_action\": \"Test escalation path AC-4 verification\", \"updated_at\": \"$fresh_ts\", \"issue_number\": 651, \"pr_number\": 0, \"error_count\": 1, \"session_id\": \"sid-651a2\"}"
stderr_file651a2="$(mktemp "$GUARD_TEST_DIR/stderr651a2.XXXXXX")"
input="{\"stop_hook_active\": false, \"cwd\": \"$dir651a2\", \"session_id\": \"sid-651a2\"}"
output=$(echo "$input" | bash "$GUARD" 2>"$stderr_file651a2") && rc=0 || rc=$?
if [ $rc -eq 2 ] \
    && grep -qF '[CONTEXT] WORKFLOW_INCIDENT=1' "$stderr_file651a2" \
    && grep -qF 'type=manual_fallback_adopted' "$stderr_file651a2" \
    && grep -qF 'phase=create_post_interview' "$stderr_file651a2" \
    && grep -qF 'iteration_id=' "$stderr_file651a2" \
    && grep -qF 'RE-ENTRY DETECTED' "$stderr_file651a2"; then
  pass "AC-4 escalation: exit 2 + sentinel 4 句 + RE-ENTRY DETECTED emit on create_post_interview block (error_count=1)"
else
  fail "expected exit 2 + sentinel + RE-ENTRY DETECTED, got exit=$rc, stderr=$(head -3 "$stderr_file651a2")"
fi

# --------------------------------------------------------------------------
# TC-651-B: 4-site 対称性 — create-interview.md Return Output の caller HTML コメント内に
# Step 0 Immediate Bash Action と同一の bash literal が **2 site 内で** 含まれていることを
# verify (interview:skipped + interview:completed の両 example で 2 件以上 match)。
# 加えて bash literal が backtick で正しく区切られ syntax-valid であること、
# 4-site DRIFT-CHECK ANCHOR が保持されていることを確認 (PR #654 review F-01 / F-05 / F-08 対応)。
# --------------------------------------------------------------------------
echo "TC-651-B: create-interview.md Return Output 4-site 対称性 + 2-site count >= 2 + syntax-valid bash literal"
interview_md_651b="$SCRIPT_DIR/../../../../plugins/rite/commands/issue/create-interview.md"
tc651b_ok=1
tc651b_missing=""
# (1) caller HTML コメント内 bash literal (interview:skipped + interview:completed の両経路で
#     合計 >= 2 件) F-05 / F-08 対応: count check で 2-site 内対称性の崩れを検出
bash_literal_count=$(grep -cF "flow-state-update.sh patch --phase create_post_interview" "$interview_md_651b" 2>/dev/null)
if [ "$bash_literal_count" -lt 2 ]; then
  tc651b_ok=0
  tc651b_missing="${tc651b_missing} bash-literal-count(<2:got_${bash_literal_count})"
fi
# (2) --if-exists flag が含まれること (orchestrator 側想定、count >= 2 で 2-site 対称性確認)
preserve_count=$(grep -cF -- "--if-exists --preserve-error-count" "$interview_md_651b" 2>/dev/null)
if [ "$preserve_count" -lt 2 ]; then
  tc651b_ok=0
  tc651b_missing="${tc651b_missing} preserve-error-count-count(<2:got_${preserve_count})"
fi
# (3) 4-site DRIFT-CHECK ANCHOR (本 PR で追加した anchor) が grep 可能
grep -qF "DRIFT-CHECK ANCHOR (semantic, 4-site)" "$interview_md_651b" 2>/dev/null \
  || { tc651b_ok=0; tc651b_missing="${tc651b_missing} 4-site-drift-check-anchor"; }
# (4) F-01 対応: bash literal が `; then continue` という invalid syntax を含まないこと
#     (`; then` は `if cmd; then ... fi` の文法トークンであり、if 句なしで使うと syntax error。
#     PR #654 で散文 `THEN (after the bash command above succeeds)` に修正済み)
if grep -qE -- "--preserve-error-count[[:space:]]*;[[:space:]]*then[[:space:]]+continue" "$interview_md_651b" 2>/dev/null; then
  tc651b_ok=0
  tc651b_missing="${tc651b_missing} invalid-bash-syntax(;_then_continue_after_preserve-error-count)"
fi
# (5) F-01 対応: bash literal が backtick で囲まれていること (構文区切りの明示)
grep -qF '`bash plugins/rite/hooks/flow-state-update.sh patch --phase create_post_interview' "$interview_md_651b" 2>/dev/null \
  || { tc651b_ok=0; tc651b_missing="${tc651b_missing} bash-literal-not-in-backticks"; }
if [ "$tc651b_ok" -eq 1 ]; then
  pass "create-interview.md Return Output 4-site + 2-site count + syntax-valid (bash_literal=$bash_literal_count, preserve=$preserve_count, anchor + backtick + no-invalid-syntax)"
else
  fail "missing 4-site symmetry / syntax violation:${tc651b_missing}"
fi

# --------------------------------------------------------------------------
# TC-651-C: stop-guard.sh の create_post_interview WORKFLOW_HINT に
# **site-specific な** bash literal が含まれることを assert。create_post_interview 文脈と
# 組み合わせた literal を 1 行で grep し、cleanup_post_ingest 等の他 case arm の
# `--if-exists --preserve-error-count` flag への false-positive match を排除する
# (PR #654 review F-06 対応)。
# --------------------------------------------------------------------------
echo "TC-651-C: stop-guard.sh create_post_interview WORKFLOW_HINT に site-specific 4-site 対称 bash literal が含まれる"
tc651c_ok=1
tc651c_missing=""
# Site-specific pattern: `--phase create_post_interview --active true --next 'Step 0 Immediate Bash Action fired`
# は create_post_interview WORKFLOW_HINT 内にしか出現しない literal で、cleanup_post_ingest 等の
# 他 case arm にある同類 flag (`--if-exists --preserve-error-count` 単独) では false-positive しない。
# Issue #660: `--active true` を 4-site 対称引数 list に追加 (--phase / --active / --next / --preserve-error-count)
grep -qF "create_post_interview --active true --next 'Step 0 Immediate Bash Action fired" "$GUARD" 2>/dev/null \
  || { tc651c_ok=0; tc651c_missing="${tc651c_missing} site-specific-bash-literal-in-stop-guard"; }
# 4-site DRIFT-CHECK ANCHOR (PR #654 review F-03 で追加された 4-site 文言) も verify
grep -qF "DRIFT-CHECK ANCHOR (semantic, 4-site)" "$GUARD" 2>/dev/null \
  || { tc651c_ok=0; tc651c_missing="${tc651c_missing} 4-site-anchor-in-stop-guard"; }
if [ "$tc651c_ok" -eq 1 ]; then
  pass "stop-guard.sh WORKFLOW_HINT で site-specific 4-site 対称 bash literal + 4-site ANCHOR 保持"
else
  fail "missing site-specific 4-site symmetry in stop-guard.sh:${tc651c_missing}"
fi

# --------------------------------------------------------------------------
# TC-660-A (Issue #660 AC-2): 本番条件再現 — active=false で機能不全を実証
#
# Given: phase=create_post_interview, active=false の状態
# When: stop-guard.sh を起動
# Then: exit 0 + diag log に EXIT:0 reason=not_active が記録される
#
# 本 TC は Issue #660 の D4 (本番条件再現 TC を AC に必須化) に該当。
# 過去 60+ TC は active=true を pre-set してから起動していたため、本番起動条件
# (active=false) との gap で機能不全を検出できなかった。本 TC で gap を顕在化する。
#
# verified-review (PR #661) cycle 2 review #6 LOW (intent コメント): TC-475-A は
# exit 2 + create_post_interview emit のみ verify。本 TC は **runtime stderr 経由で
# WORKFLOW_HINT が active=false 経路で emit されないこと** (negative assertion) を
# verify する orthogonal 検知。TC-651-C は static source grep のため、case arm 削除
# regression は本 TC のみで catch する。
# --------------------------------------------------------------------------
echo "TC-660-A: phase=create_post_interview, active=false で stop-guard が exit 0 + reason=not_active"
# review #2 MEDIUM 対応 (verified-review): RITE_STOP_GUARD_DIAG_LOG 環境変数は本番コード
# (stop-guard.sh:43 の `local diag_file="$STATE_ROOT/.rite-stop-guard-diag.log"`) で参照されない
# dead code のため削除。stop-guard.sh は STATE_ROOT (= cwd fallback) からハードコードで diag log
# パスを解決するため、env var 設定は no-op だった。
# review #3 MEDIUM 対応: TC-029 と stop-guard.sh L79-85 early return path 上で意味的に等価のため、
# 本 TC の独立価値を確保するための negative assertion (active=false 経路では create_post_interview
# WORKFLOW_HINT が emit されない) を追加。
# verified-review (PR #661) cycle 2 F-07 対応: output_aoa=$(...) で stdout を変数捕捉していたが
# 以後一切参照されない (dead variable)。隣接 TC-660-B/C と pattern を揃えて >/dev/null に変更。
dir_660a="$GUARD_TEST_DIR/tc-660-A"
mkdir -p "$dir_660a"
now_660a=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")
create_state_file "$dir_660a" "{\"active\": false, \"phase\": \"create_post_interview\", \"updated_at\": \"$now_660a\", \"next_action\": \"continue\"}"
diag_660a="$dir_660a/.rite-stop-guard-diag.log"
input_660a="{\"stop_hook_active\": false, \"cwd\": \"$dir_660a\"}"
LAST_STDERR_FILE="$(mktemp "$GUARD_TEST_DIR/tc-660-A.stderr.XXXXXX")"
echo "$input_660a" | bash "$GUARD" >/dev/null 2>"$LAST_STDERR_FILE" && rc_660a=0 || rc_660a=$?
tc_660a_ok=1
tc_660a_missing=""
if [ "$rc_660a" -ne 0 ]; then
  tc_660a_ok=0
  tc_660a_missing="${tc_660a_missing} exit-not-0(rc=$rc_660a)"
fi
if ! grep -qF "EXIT:0 reason=not_active" "$diag_660a" 2>/dev/null; then
  tc_660a_ok=0
  tc_660a_missing="${tc_660a_missing} reason-not-active-not-in-diag"
fi
# Negative assertion: active=false 経路では WORKFLOW_HINT が stderr に emit されないこと
# (active=true なら create_post_interview の HINT bash literal が出るが、early return 経路では
# 出ないことを正の検証として追加。これにより TC-029 との独立価値を確保)
if grep -qF "create_post_interview --active true --next 'Step 0 Immediate Bash Action fired" "$LAST_STDERR_FILE" 2>/dev/null; then
  tc_660a_ok=0
  tc_660a_missing="${tc_660a_missing} workflow-hint-emitted-in-active-false-path"
fi
if [ "$tc_660a_ok" -eq 1 ]; then
  pass "active=false で exit 0 + diag log に EXIT:0 reason=not_active 記録 + WORKFLOW_HINT 非 emit (early return 確認)"
else
  fail "active=false 期待動作不在:${tc_660a_missing}"
fi

# --------------------------------------------------------------------------
# TC-660-B (Issue #660 AC-3): 本番条件成立 — active=true で防御層が fire
#
# Given: phase=create_post_interview, active=true の状態
# When: stop-guard.sh を起動
# Then: exit 2 + WORKFLOW_HINT に Step 0 bash literal を含む
#
# 本 TC は Issue #660 の link 修復後の動作を assert する。
# AC-1 で全 patch site に --active true が追加された結果、本 case が本番で再現する。
# --------------------------------------------------------------------------
echo "TC-660-B: phase=create_post_interview, active=true で stop-guard が exit 2 + WORKFLOW_HINT"
dir_660b="$GUARD_TEST_DIR/tc-660-B"
mkdir -p "$dir_660b"
now_660b=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")
create_state_file "$dir_660b" "{\"active\": true, \"phase\": \"create_post_interview\", \"updated_at\": \"$now_660b\", \"next_action\": \"continue\"}"
input_660b="{\"stop_hook_active\": false, \"cwd\": \"$dir_660b\"}"
LAST_STDERR_FILE="$(mktemp "$GUARD_TEST_DIR/tc-660-B.stderr.XXXXXX")"
echo "$input_660b" | bash "$GUARD" >/dev/null 2>"$LAST_STDERR_FILE" && rc_660b=0 || rc_660b=$?
tc_660b_ok=1
tc_660b_missing=""
if [ "$rc_660b" -ne 2 ]; then
  tc_660b_ok=0
  tc_660b_missing="${tc_660b_missing} exit-not-2(rc=$rc_660b)"
fi
# WORKFLOW_HINT 内に Step 0 Immediate Bash Action の bash literal (--active true 含む) があること
if ! grep -qF "create_post_interview --active true --next 'Step 0 Immediate Bash Action fired" "$LAST_STDERR_FILE" 2>/dev/null; then
  tc_660b_ok=0
  tc_660b_missing="${tc_660b_missing} step-0-bash-literal-with-active-true-in-stderr"
fi
if [ "$tc_660b_ok" -eq 1 ]; then
  pass "active=true で exit 2 + WORKFLOW_HINT に --active true を含む Step 0 bash literal 出力"
else
  fail "active=true 期待動作不在:${tc_660b_missing}"
fi

# --------------------------------------------------------------------------
# TC-660-C (Issue #660 AC-1 補強): --active true 付き patch の挙動検証
#
# Given: 既存 .rite-flow-state (active=false)
# When: flow-state-update.sh patch --phase X --active true ... を実行
# Then: active が true に更新される (--active true が反映される)
#
# 本 TC は flow-state-update.sh の --active 引数が正しく適用されることを assert する。
# patch mode の --active 省略時は既存値保持の semantics (TC-660-E で対称検証) と
# 区別するため、--active true 明示時の挙動を独立に検証。
# --------------------------------------------------------------------------
echo "TC-660-C: flow-state-update.sh patch --active true で active=false → true に更新"
# review #1 HIGH 対応 (verified-review): subshell + stderr 完全黙殺 + 終了コード未確認の三重盲検を解消。
# `set -euo pipefail` (L4) 下で flow-state-update.sh が失敗した場合に test 全体が silent abort
# する経路を防ぐため、(a) subshell の終了コードを `&& rc=0 || rc=$?` で捕捉、(b) stderr を別 mktemp
# file に redirect、(c) rc 非 0 時に明示 fail で診断 message を表示する。
# review #4 LOW 対応: TC-660-C 専用に LAST_STDERR_FILE を新規割当することで、TC-660-B
# の stderr が show_stderr 経由で誤表示される debug 誤誘導を防ぐ。
dir_660c="$GUARD_TEST_DIR/tc-660-C"
mkdir -p "$dir_660c"
now_660c=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")
create_state_file "$dir_660c" "{\"active\": false, \"phase\": \"create_interview\", \"updated_at\": \"$now_660c\", \"next_action\": \"continue\", \"error_count\": 0}"
FSU="$SCRIPT_DIR/../flow-state-update.sh"
LAST_STDERR_FILE="$(mktemp "$GUARD_TEST_DIR/tc-660-C.stderr.XXXXXX")"
(cd "$dir_660c" && bash "$FSU" patch \
  --phase "create_post_interview" --active true \
  --next "TC-660-C verification" \
  --if-exists --preserve-error-count >/dev/null 2>"$LAST_STDERR_FILE") && rc_660c=0 || rc_660c=$?
if [ "$rc_660c" -ne 0 ]; then
  fail "FSU patch failed: rc=$rc_660c"
else
  patched_active=$(jq -r '.active' "$dir_660c/.rite-flow-state" 2>/dev/null)
  patched_phase=$(jq -r '.phase' "$dir_660c/.rite-flow-state" 2>/dev/null)
  if [ "$patched_active" = "true" ] && [ "$patched_phase" = "create_post_interview" ]; then
    pass "patch --active true で active=false → true、phase 同時更新"
  else
    fail "patch --active true 失敗 (active=$patched_active, phase=$patched_phase)"
  fi
fi

# --------------------------------------------------------------------------
# TC-660-D (Issue #660 AC-1 機械検証 = test infrastructure 永続化):
#
# verified-review (PR #661) cycle 2 F-04 対応:
# Issue #660 spec と PR description で「block-level Python verification」が言及されたが、
# 実際の test infrastructure には永続化されていなかった。Wiki 経験則
# 「emit/consume/test 3 点セット契約」のうち test 点が欠落しており、将来別 patch site が
# --active true を omit して merge された場合、本 TC によって CI で catch できるようにする。
#
# Given: plugins/rite/commands/ 配下の全 .md ファイル
# When: bash で `flow-state-update.sh patch \` continuation block を block-aware に scan
# Then: terminal phase (create_completed/cleanup_completed/ingest_completed) を除く
#       全 non-terminal patch site が `--active true` を含む
# --------------------------------------------------------------------------
echo "TC-660-D: AC-1 機械検証 — 全 non-terminal patch site が --active true を含む"
# 動作: bash 内の awk で各 .md ファイルを走査し、`flow-state-update.sh patch \` で始まる
# block を抽出。block 内で terminal phase keyword がない && --active true がない場合 violation。
# script-relative (../../commands) で plugin root を解決して test 実行 cwd に依存しない。
COMMANDS_ROOT="$SCRIPT_DIR/../../commands"
violation_count=0
violation_paths=""
if [ -d "$COMMANDS_ROOT" ]; then
  while IFS= read -r md_file; do
    # awk で block-aware scan: `flow-state-update.sh patch \` で block 開始、
    # 行末が `\` でない行で block 終了。block 内全体に対して keyword を grep。
    block_violations=$(awk '
      /flow-state-update\.sh patch \\$/ { in_block=1; block=""; line_num=NR; next }
      in_block {
        block = block "\n" $0
        if ($0 !~ /\\$/) {
          # block 終了 — 判定
          # Terminal / terminal-equivalent phase の patch は意図的 deactivate のため除外:
          #   - create_completed / cleanup_completed / ingest_completed: sub-skill 終端 (Issue #660 spec)
          #   - phase5_post_parent_completion: /rite:issue:start Workflow Termination 前段の意図的 deactivate
          #   - "completed": /rite:issue:start Workflow Termination の terminal final state
          # `--phase "..."` 形式で厳密に match させ、finding description 等の偶然 match を避ける。
          if (block ~ /--phase "create_completed"/ || \
              block ~ /--phase "cleanup_completed"/ || \
              block ~ /--phase "ingest_completed"/ || \
              block ~ /--phase "phase5_post_parent_completion"/ || \
              block ~ /--phase "completed"/) {
            in_block=0
            block=""
            next
          }
          # active true / active false の有無を check
          if (block !~ /--active true/) {
            print line_num
          }
          in_block=0
          block=""
        }
      }
    ' "$md_file")
    if [ -n "$block_violations" ]; then
      while IFS= read -r line_num; do
        violation_count=$((violation_count + 1))
        # 相対 path で表示 (long absolute path を避ける)
        rel_path=$(echo "$md_file" | sed "s|^${COMMANDS_ROOT}/||")
        violation_paths="${violation_paths} ${rel_path}:${line_num}"
      done <<< "$block_violations"
    fi
  done < <(find "$COMMANDS_ROOT" -name '*.md' -type f)
fi
if [ "$violation_count" -eq 0 ]; then
  pass "全 non-terminal patch site が --active true を含む (block-aware scan で 0 violations)"
else
  fail "AC-1 violation: $violation_count patch site(s) lack --active true:${violation_paths}"
fi

# --------------------------------------------------------------------------
# TC-660-E (Issue #660 AC-1 補強 = inverse semantics):
#
# verified-review (PR #661) cycle 2 F-05 対応:
# TC-660-C は --active true 明示時の flip のみ assert している。本 PR の root cause は
# flow-state-update.sh:254 の `if [[ -n "$ACTIVE" ]]` 条件分岐 (= --active 省略時は既存値保持) に
# 直接依存しており、この semantics が変更されると AC-1 を full carpeted した本 PR の修正自体が
# 無効化される silent regression が発生する。本 TC で双方向 (active=false 既存 + active=true 既存)
# の preserve-existing semantics を対称検証する。
#
# Given: 既存 .rite-flow-state (active=false / active=true の 2 ケース)
# When: flow-state-update.sh patch --phase X (--active 省略) を実行
# Then: 既存の active 値が保持される (false → false / true → true)
# --------------------------------------------------------------------------
echo "TC-660-E: flow-state-update.sh patch (--active 省略) で既存 active 値が preserve される"
FSU="$SCRIPT_DIR/../flow-state-update.sh"
tc_660e_ok=1
tc_660e_missing=""
# Case 1: active=false で --active 省略 → active=false のまま preserve
dir_660e1="$GUARD_TEST_DIR/tc-660-E1"
mkdir -p "$dir_660e1"
now_660e1=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")
create_state_file "$dir_660e1" "{\"active\": false, \"phase\": \"create_interview\", \"updated_at\": \"$now_660e1\", \"next_action\": \"continue\", \"error_count\": 0}"
LAST_STDERR_FILE="$(mktemp "$GUARD_TEST_DIR/tc-660-E1.stderr.XXXXXX")"
(cd "$dir_660e1" && bash "$FSU" patch \
  --phase "create_post_interview" \
  --next "TC-660-E1 inverse verification (active omitted)" \
  --if-exists --preserve-error-count >/dev/null 2>"$LAST_STDERR_FILE") && rc_660e1=0 || rc_660e1=$?
if [ "$rc_660e1" -ne 0 ]; then
  tc_660e_ok=0
  tc_660e_missing="${tc_660e_missing} case1-fsu-failed(rc=$rc_660e1)"
else
  preserved_active_1=$(jq -r '.active' "$dir_660e1/.rite-flow-state" 2>/dev/null)
  if [ "$preserved_active_1" != "false" ]; then
    tc_660e_ok=0
    tc_660e_missing="${tc_660e_missing} case1-active-not-preserved(got=$preserved_active_1,expected=false)"
  fi
fi
# Case 2: active=true で --active 省略 → active=true のまま preserve
dir_660e2="$GUARD_TEST_DIR/tc-660-E2"
mkdir -p "$dir_660e2"
now_660e2=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")
create_state_file "$dir_660e2" "{\"active\": true, \"phase\": \"create_interview\", \"updated_at\": \"$now_660e2\", \"next_action\": \"continue\", \"error_count\": 0}"
LAST_STDERR_FILE="$(mktemp "$GUARD_TEST_DIR/tc-660-E2.stderr.XXXXXX")"
(cd "$dir_660e2" && bash "$FSU" patch \
  --phase "create_post_interview" \
  --next "TC-660-E2 inverse verification (active omitted)" \
  --if-exists --preserve-error-count >/dev/null 2>"$LAST_STDERR_FILE") && rc_660e2=0 || rc_660e2=$?
if [ "$rc_660e2" -ne 0 ]; then
  tc_660e_ok=0
  tc_660e_missing="${tc_660e_missing} case2-fsu-failed(rc=$rc_660e2)"
else
  preserved_active_2=$(jq -r '.active' "$dir_660e2/.rite-flow-state" 2>/dev/null)
  if [ "$preserved_active_2" != "true" ]; then
    tc_660e_ok=0
    tc_660e_missing="${tc_660e_missing} case2-active-not-preserved(got=$preserved_active_2,expected=true)"
  fi
fi
if [ "$tc_660e_ok" -eq 1 ]; then
  pass "patch (--active 省略) で active=false / active=true が双方向 preserve される (flow-state-update.sh:254 if-branch contract pin)"
else
  fail "patch (--active 省略) preserve-existing semantics 違反:${tc_660e_missing}"
fi

# --------------------------------------------------------------------------
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ $FAIL -gt 0 ]; then
  exit 1
fi
