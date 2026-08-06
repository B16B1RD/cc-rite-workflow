#!/bin/bash
# Tests for review-cycle-scope.sh (cycle 1 / cycle 2+ 差分スコープの決定)
#
# 本 helper は「cycle 2+ のレビュー対象を前回レビュー起点の差分に絞る」判定の唯一の実行層で、
# 判定を誤ると (a) cycle 1 相当のフルレビューが cycle 2+ でも走り続けて重複調査が残る、または
# (b) 起点が壊れているのに差分スコープへ入って未変更部が誰にも見られない、のどちらかになる。
# (b) は silent に品質を落とすため、本 suite は「情報が欠けた全経路で full へ倒れること」を
# reason ごとに個別に pin する (Issue #2118 AC-3 / T-03)。
#
# Usage: bash plugins/rite/scripts/tests/review-cycle-scope.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../review-cycle-scope.sh"
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ FAIL: $1"; }

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi

# helper 実行。marker は stderr 契約なので stderr を検証対象にする。
run_scope() {
  local err_file="$TEST_DIR/.stderr"
  SCOPE_STDOUT=$(bash "$TARGET" "$@" 2>"$err_file")
  SCOPE_RC=$?
  SCOPE_STDERR=$(cat "$err_file")
  return 0
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) pass "$label" ;;
    *) fail "$label"; echo "     期待する部分文字列: $needle"; echo "     実際: $haystack" ;;
  esac
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) fail "$label"; echo "     出現してはならない部分文字列: $needle" ;;
    *) pass "$label" ;;
  esac
}

assert_rc() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then pass "$label"; else fail "$label (expected rc=$expected, got rc=$actual)"; fi
}

# review-result JSON を書く: path commit_sha reviewer...
mk_result_json() {
  local path="$1" sha="$2"; shift 2
  local findings="[]"
  if [ "$#" -gt 0 ]; then
    findings=$(printf '%s\n' "$@" | jq -R '{id:"F-01", reviewer:., category:"c", severity:"HIGH",
      file:"a.sh", line:1, description:"d", suggestion:"s", status:"open", scope:"current-pr"}' | jq -s '.')
  fi
  jq -n --arg sha "$sha" --argjson f "$findings" \
    '{schema_version:"1.0.0", pr_number:42, timestamp:"2026-08-06T00:00:00+09:00",
      commit_sha:$sha, overall_assessment:"fix-needed", findings:$f, non_blocking_findings:[]}' > "$path"
}

# 検証用の git リポジトリを用意し、2 コミット目の HEAD と 1 コミット目の sha を返す
REPO="$TEST_DIR/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "test"
echo one > "$REPO/a.sh"
git -C "$REPO" add a.sh
git -C "$REPO" commit -qm "first"
FIRST_SHA=$(git -C "$REPO" rev-parse HEAD)
echo two >> "$REPO/a.sh"
git -C "$REPO" commit -qam "second"

RESULTS="$TEST_DIR/results"
mkdir -p "$RESULTS"

echo "=== TC-1: 前回 JSON が有効なら incremental (AC-1 / T-01) ==="
mk_result_json "$RESULTS/42-20260806-000000.json" "$FIRST_SHA" "code-quality-reviewer" "security-reviewer"
cd "$REPO" || exit 1
run_scope --pr 42 --results-dir "$RESULTS"
assert_rc "TC-1.1: rc=0" 0 "$SCOPE_RC"
assert_contains "TC-1.2: REVIEW_CYCLE_SCOPE=incremental" "$SCOPE_STDERR" "REVIEW_CYCLE_SCOPE=incremental"
assert_contains "TC-1.3: base_sha は前回 JSON の commit_sha" "$SCOPE_STDERR" "base_sha=$FIRST_SHA"
assert_not_contains "TC-1.4: fallback marker を出さない" "$SCOPE_STDERR" "REVIEW_CYCLE_SCOPE_FALLBACK"

echo "=== TC-2: prev_finders は agent 名を reviewer_type へ正規化し unique 化する (AC-2) ==="
assert_contains "TC-2.1: -reviewer サフィックスを除去して CSV 化" "$SCOPE_STDERR" "prev_finders=code-quality,security"
mk_result_json "$RESULTS/42-20260806-000001.json" "$FIRST_SHA" "test-reviewer" "test-reviewer"
run_scope --pr 42 --results-dir "$RESULTS"
assert_contains "TC-2.2: 同一 reviewer の重複は 1 件に畳まれる" "$SCOPE_STDERR" "prev_finders=test"

echo "=== TC-3: 複数 JSON があれば最新 (ファイル名降順の先頭) を採る ==="
assert_contains "TC-3.1: 最新ファイルが prev_json に入る" "$SCOPE_STDERR" "42-20260806-000001.json"

echo "=== TC-4: blocking 0 件でも incremental を維持する (finder 空) ==="
EMPTY_RESULTS="$TEST_DIR/results-empty"
mkdir -p "$EMPTY_RESULTS"
mk_result_json "$EMPTY_RESULTS/42-20260806-000000.json" "$FIRST_SHA"
run_scope --pr 42 --results-dir "$EMPTY_RESULTS"
assert_contains "TC-4.1: findings[] が空でも incremental" "$SCOPE_STDERR" "REVIEW_CYCLE_SCOPE=incremental"
assert_contains "TC-4.2: prev_finders は空" "$SCOPE_STDERR" "prev_finders="

echo "=== TC-5: results dir 不在は cycle 1 の正常経路 — WARNING を出さない (AC-3 / T-03) ==="
run_scope --pr 42 --results-dir "$TEST_DIR/does-not-exist"
assert_rc "TC-5.1: rc=0" 0 "$SCOPE_RC"
assert_contains "TC-5.2: reason=no_prev_json で full" "$SCOPE_STDERR" "REVIEW_CYCLE_SCOPE=full; reason=no_prev_json"
assert_not_contains "TC-5.3: 正常経路なので fallback marker を出さない" "$SCOPE_STDERR" "REVIEW_CYCLE_SCOPE_FALLBACK"
assert_not_contains "TC-5.4: 正常経路なので ⚠️ を出さない" "$SCOPE_STDERR" "⚠️"

echo "=== TC-6: 当該 PR の JSON が無い (別 PR のみ) も no_prev_json ==="
OTHER="$TEST_DIR/results-other"
mkdir -p "$OTHER"
mk_result_json "$OTHER/99-20260806-000000.json" "$FIRST_SHA"
run_scope --pr 42 --results-dir "$OTHER"
assert_contains "TC-6.1: 別 PR の JSON は拾わない" "$SCOPE_STDERR" "reason=no_prev_json"

echo "=== TC-7: 壊れた JSON は prev_json_unreadable で full + WARNING (AC-3 / T-03) ==="
BROKEN="$TEST_DIR/results-broken"
mkdir -p "$BROKEN"
printf '{ this is not json' > "$BROKEN/42-20260806-000000.json"
run_scope --pr 42 --results-dir "$BROKEN"
assert_rc "TC-7.1: rc=0 (レビュー自体は止めない)" 0 "$SCOPE_RC"
assert_contains "TC-7.2: reason=prev_json_unreadable" "$SCOPE_STDERR" "reason=prev_json_unreadable"
assert_contains "TC-7.3: fallback marker を出す" "$SCOPE_STDERR" "REVIEW_CYCLE_SCOPE_FALLBACK=1"
assert_contains "TC-7.4: 人間向け WARNING を出す (silent fallback 禁止)" "$SCOPE_STDERR" "⚠️ 差分スコープのフォールバック"

echo "=== TC-8: commit_sha 欠落は commit_sha_missing で full (AC-3 / T-03) ==="
NOSHA="$TEST_DIR/results-nosha"
mkdir -p "$NOSHA"
jq -n '{schema_version:"1.0.0", pr_number:42, findings:[], non_blocking_findings:[]}' > "$NOSHA/42-20260806-000000.json"
run_scope --pr 42 --results-dir "$NOSHA"
assert_contains "TC-8.1: reason=commit_sha_missing" "$SCOPE_STDERR" "reason=commit_sha_missing"
assert_contains "TC-8.2: full へ倒れる" "$SCOPE_STDERR" "REVIEW_CYCLE_SCOPE=full"

echo "=== TC-9: commit_sha が null でも commit_sha_missing (旧形式互換) ==="
NULLSHA="$TEST_DIR/results-nullsha"
mkdir -p "$NULLSHA"
jq -n '{schema_version:"1.0.0", pr_number:42, commit_sha:null, findings:[], non_blocking_findings:[]}' > "$NULLSHA/42-20260806-000000.json"
run_scope --pr 42 --results-dir "$NULLSHA"
assert_contains "TC-9.1: null は空扱いで commit_sha_missing" "$SCOPE_STDERR" "reason=commit_sha_missing"

echo "=== TC-10: 到達不能な commit_sha は commit_sha_unreachable (force-push/rebase, AC-3 / T-03) ==="
GONE="$TEST_DIR/results-gone"
mkdir -p "$GONE"
mk_result_json "$GONE/42-20260806-000000.json" "0000000000000000000000000000000000000000"
run_scope --pr 42 --results-dir "$GONE"
assert_contains "TC-10.1: reason=commit_sha_unreachable" "$SCOPE_STDERR" "reason=commit_sha_unreachable"
assert_contains "TC-10.2: full へ倒れる" "$SCOPE_STDERR" "REVIEW_CYCLE_SCOPE=full"

echo "=== TC-11: commit でない object (blob sha) を起点に採らない ==="
BLOB_SHA=$(git -C "$REPO" rev-parse HEAD:a.sh)
BLOB="$TEST_DIR/results-blob"
mkdir -p "$BLOB"
mk_result_json "$BLOB/42-20260806-000000.json" "$BLOB_SHA"
run_scope --pr 42 --results-dir "$BLOB"
assert_contains "TC-11.1: blob sha は commit_sha_unreachable" "$SCOPE_STDERR" "reason=commit_sha_unreachable"

echo "=== TC-12: usage error ==="
run_scope --results-dir "$RESULTS"
assert_rc "TC-12.1: --pr 欠落は rc=2" 2 "$SCOPE_RC"
run_scope --pr abc --results-dir "$RESULTS"
assert_rc "TC-12.2: 非数値 --pr は rc=2" 2 "$SCOPE_RC"
run_scope --pr 42 --bogus x
assert_rc "TC-12.3: 未知引数は rc=2" 2 "$SCOPE_RC"

echo "=== TC-13: 全経路で stdout を汚さない (marker は stderr 契約) ==="
run_scope --pr 42 --results-dir "$RESULTS"
if [ -z "$SCOPE_STDOUT" ]; then pass "TC-13.1: incremental 経路の stdout は空"; else fail "TC-13.1: stdout に出力あり: $SCOPE_STDOUT"; fi
run_scope --pr 42 --results-dir "$TEST_DIR/does-not-exist"
if [ -z "$SCOPE_STDOUT" ]; then pass "TC-13.2: full 経路の stdout は空"; else fail "TC-13.2: stdout に出力あり: $SCOPE_STDOUT"; fi

echo ""
echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] || exit 1
