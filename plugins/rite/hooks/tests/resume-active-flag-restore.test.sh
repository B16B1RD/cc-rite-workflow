#!/bin/bash
# Tests for hooks/resume-active-flag-restore.sh — active flag restore semantics.
#
# PR #688 cycle 16 fix (F-05 MEDIUM、cycle 15 review test reviewer):
# resume.md の Phase 3.0.1 bash block (cycle 10 で導入された [ -z "$curr_phase" ] guard) に対する
# 自動テストを追加。
#
# PR #688 cycle 18 fix (cycle 17 review):
#   - F-02 MEDIUM (code-quality): TC-1.2 直前のコメントの line range factual error を function
#     name 参照に置き換え (cycle 14 と同型の line-range drift 解消)
#   - F-03 MEDIUM (test): cycle 16 で実装した「building blocks integration」approach は test 自身が
#     `[ -z ]` を計算した結果を assert する tautology になっていた。bash block を helper script
#     `hooks/resume-active-flag-restore.sh` に抽出し、test は helper の exit code と side effect を
#     直接検証する形に変更
#   - F-04 MEDIUM (test): TC-2 が `--session $SID` 経路のみ test していた coverage gap を解消。
#     TC-2-no-sid を追加して resume.md L376-385 (sid 無し legacy fallback) も pin
#
# 検証する invariants:
#   (a) per-session/legacy 両不在 → helper が curr_phase 空文字判定で skip (exit 0、patch 未実行)
#   (b) per-session 存在 + valid phase + sid 有り → helper が --session 付き patch 実行 (active=true 書き戻し)
#   (c) per-session 存在 + valid phase + sid 無し → helper が --session 無し patch 実行 (legacy fallback path)
#   (d) phase 空文字列 → helper が skip (exit 0)
#   (e) flow-state-update.sh patch --phase "" は validation で reject される
#       (cycle 9 で実際に発生した resume hard abort silent regression の経路を pin)
#
# Usage: bash plugins/rite/hooks/tests/resume-active-flag-restore.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELPER="$PLUGIN_ROOT/hooks/resume-active-flag-restore.sh"
FLOW_STATE_UPDATE="$PLUGIN_ROOT/hooks/flow-state-update.sh"

if [ ! -x "$HELPER" ]; then
  echo "ERROR: resume-active-flag-restore.sh missing or not executable: $HELPER" >&2
  exit 1
fi
if [ ! -x "$FLOW_STATE_UPDATE" ]; then
  echo "ERROR: flow-state-update.sh missing or not executable: $FLOW_STATE_UPDATE" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi

PASS=0
FAIL=0
FAILED_NAMES=()

cleanup_dirs=()
_resume_test_cleanup() {
  local d
  for d in "${cleanup_dirs[@]:-}"; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
  done
}
trap '_resume_test_cleanup' EXIT
trap '_resume_test_cleanup; exit 130' INT
trap '_resume_test_cleanup; exit 143' TERM
trap '_resume_test_cleanup; exit 129' HUP

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

assert_contains() {
  local name="$1" expected_substring="$2" actual="$3"
  if [[ "$actual" == *"$expected_substring"* ]]; then
    echo "  ✅ $name"
    PASS=$((PASS+1))
  else
    echo "  ❌ $name"
    echo "     expected substring: $expected_substring"
    echo "     actual:             $actual"
    FAIL=$((FAIL+1))
    FAILED_NAMES+=("$name")
  fi
}

make_sandbox() {
  local d sandbox_err
  d=$(mktemp -d) || { echo "ERROR: mktemp -d failed" >&2; exit 1; }
  sandbox_err=$(mktemp /tmp/rite-resume-sandbox-err-XXXXXX) || sandbox_err="/dev/null"
  if ! (
    cd "$d"
    git init -q 2>"$sandbox_err"
    echo a > a && git add a 2>>"$sandbox_err"
    git -c user.email=t@test.local -c user.name=test commit -q -m init 2>>"$sandbox_err"
  ); then
    echo "ERROR: make_sandbox: git init/commit failed in $d" >&2
    [ "$sandbox_err" != "/dev/null" ] && [ -s "$sandbox_err" ] && head -5 "$sandbox_err" | sed 's/^/  /' >&2
    rm -rf "$d"
    [ "$sandbox_err" != "/dev/null" ] && rm -f "$sandbox_err"
    exit 1
  fi
  [ "$sandbox_err" != "/dev/null" ] && rm -f "$sandbox_err"
  echo "$d"
}

write_config_v2() {
  cat > "$1/rite-config.yml" <<EOF
flow_state:
  schema_version: 2
EOF
}

write_session_id() {
  echo "$2" > "$1/.rite-session-id"
}

write_per_session() {
  mkdir -p "$1/.rite/sessions"
  printf '%s' "$3" > "$1/.rite/sessions/${2}.flow-state"
}

write_legacy() {
  printf '%s' "$2" > "$1/.rite-flow-state"
}

# resume.md Phase 3.0.1 が bash block 内で行っていた処理を helper script で実行。
# test は helper の exit code と sandbox 内の side effect (active flag 書き戻し / stderr message)
# を直接検証することで、resume.md の guard を実際に exercise する (cycle 17 F-03 解消)。
run_helper() {
  local d="$1"
  local stderr_file="$2"
  if [ -n "$stderr_file" ]; then
    (cd "$d" && bash "$HELPER" "$PLUGIN_ROOT" 2>"$stderr_file")
  else
    (cd "$d" && bash "$HELPER" "$PLUGIN_ROOT")
  fi
}

# --- TC-1: per-session/legacy 両不在 → helper が skip (curr_phase 空文字判定) ---
echo "TC-1: per-session/legacy 両不在 → helper skip 経路 (cycle 10 F-01 CRITICAL guard)"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
write_config_v2 "$SBX"
write_session_id "$SBX" "11111111-1111-1111-1111-111111111111"
# per-session も legacy も作成しない

stderr_file=$(mktemp /tmp/rite-resume-tc1-stderr-XXXXXX)
if run_helper "$SBX" "$stderr_file"; then
  rc=0
else
  rc=$?
fi
assert_eq "TC-1.1: helper exit 0 (両不在で skip)" "0" "$rc"
# helper が skip メッセージを stderr に出すことを確認 (resume.md L348 の guard が実際に発火)
stderr_content=$(cat "$stderr_file")
assert_contains "TC-1.2: skip message が stderr に出力される (resume.md guard が実際に発火)" \
  "active flag 復元を skip しました" "$stderr_content"
rm -f "$stderr_file"

# --- TC-2: per-session 存在 + valid phase + sid 有り → patch --session 経路 ---
echo "TC-2: per-session 存在 + valid phase + sid 有り → patch --if-exists --session 成功経路"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
write_config_v2 "$SBX"
SID="22222222-2222-2222-2222-222222222222"
write_session_id "$SBX" "$SID"
write_per_session "$SBX" "$SID" '{"phase":"phase5_lint","next_action":"continue","pr_number":42,"loop_count":2,"active":false}'

stderr_file=$(mktemp /tmp/rite-resume-tc2-stderr-XXXXXX)
if run_helper "$SBX" "$stderr_file"; then
  rc=0
else
  rc=$?
fi
if [ "$rc" -ne 0 ]; then
  echo "  helper stderr:" >&2
  head -5 "$stderr_file" | sed 's/^/    /' >&2
fi
rm -f "$stderr_file"
assert_eq "TC-2.1: helper exit 0 (sid 有り経路で patch 成功)" "0" "$rc"
# active flag が true に書き戻されたことを確認
active_value=$(jq -r '.active // empty' "$SBX/.rite/sessions/${SID}.flow-state" 2>/dev/null)
assert_eq "TC-2.2: active flag が true に書き戻される (--session 引数経由)" "true" "$active_value"

# --- TC-2-no-sid: per-session 存在 + valid phase + sid 無し → legacy fallback patch 経路 (cycle 18 F-04) ---
echo "TC-2-no-sid: schema_v=1 + legacy file 存在 + sid 無し → patch (--session なし) 成功経路 (resume.md L376-385 path)"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
# schema_v=1 (legacy のみの環境) で sid 無し
cat > "$SBX/rite-config.yml" <<EOF
flow_state:
  schema_version: 1
EOF
# .rite-session-id を作らない (sid 無し経路)
write_legacy "$SBX" '{"phase":"phase5_lint","next_action":"continue","pr_number":50,"loop_count":1,"active":false}'

stderr_file=$(mktemp /tmp/rite-resume-tc2-nosid-stderr-XXXXXX)
if run_helper "$SBX" "$stderr_file"; then
  rc=0
else
  rc=$?
fi
if [ "$rc" -ne 0 ]; then
  echo "  helper stderr:" >&2
  head -5 "$stderr_file" | sed 's/^/    /' >&2
fi
rm -f "$stderr_file"
assert_eq "TC-2-no-sid.1: helper exit 0 (sid 無し経路で legacy fallback patch 成功)" "0" "$rc"
# legacy file の active flag が true に書き戻されたことを確認
active_value=$(jq -r '.active // empty' "$SBX/.rite-flow-state" 2>/dev/null)
assert_eq "TC-2-no-sid.2: legacy file の active flag が true に書き戻される (--session なし)" "true" "$active_value"

# --- TC-3: phase 空文字列 → helper が skip ---
echo "TC-3: phase が空文字列 → helper skip (resume.md L391 enumeration の path 3)"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
write_config_v2 "$SBX"
SID="33333333-3333-3333-3333-333333333333"
write_session_id "$SBX" "$SID"
write_per_session "$SBX" "$SID" '{"phase":"","next_action":"continue","active":false}'

stderr_file=$(mktemp /tmp/rite-resume-tc3-stderr-XXXXXX)
if run_helper "$SBX" "$stderr_file"; then
  rc=0
else
  rc=$?
fi
assert_eq "TC-3.1: helper exit 0 (phase 空文字で skip)" "0" "$rc"
stderr_content=$(cat "$stderr_file")
assert_contains "TC-3.2: skip message が stderr に出力される (空文字 phase で実際に発火)" \
  "active flag 復元を skip しました" "$stderr_content"
# active flag が変更されていない (false のまま) ことを確認
# state-read.sh の TC-14 で documented した jq `// $default` 仕様により、`// empty` は false を
# 空文字に変換するため使えない。`.active` 直接読みで boolean リテラル値を取得する。
active_value_after=$(jq -c '.active' "$SBX/.rite/sessions/${SID}.flow-state" 2>/dev/null)
assert_eq "TC-3.3: skip 経路では active flag が変更されない (false のまま)" "false" "$active_value_after"
rm -f "$stderr_file"

# --- TC-4: flow-state-update.sh patch --phase "" は validation で reject される ---
# (cycle 9 review F-01 で発生した hard abort 経路の直接証明 — guard が必要な根拠)
# guard なしで empty phase を patch に渡すと validation エラーになることを pin する
echo "TC-4: patch --phase \"\" は validation で reject される (guard なし時の hard abort 経路の根拠)"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
write_config_v2 "$SBX"
SID="44444444-4444-4444-4444-444444444444"
write_session_id "$SBX" "$SID"
write_per_session "$SBX" "$SID" '{"phase":"phase5_lint","next_action":"continue","active":false}'

# わざと empty phase を渡す (cycle 9 で発生した silent regression の経路)
patch_err=$(mktemp /tmp/rite-resume-patch-empty-err-XXXXXX)
if (cd "$SBX" && bash "$FLOW_STATE_UPDATE" patch \
    --phase "" \
    --next "Test." \
    --active true \
    --session "$SID" \
    --if-exists 2>"$patch_err"); then
  patch_empty_rc=0
else
  patch_empty_rc=$?
fi
if [ "$patch_empty_rc" -eq 0 ]; then
  # 期待: rejection で non-zero。0 が返ったら test 失敗で diagnostic を出す (TC-2 と対称化、cycle 17 推奨)
  echo "  patch_err:" >&2
  head -5 "$patch_err" | sed 's/^/    /' >&2
fi
rm -f "$patch_err"
# patch は exit non-zero で reject すべき (これが cycle 9 で hard abort を引き起こした根本原因)
if [ "$patch_empty_rc" -ne 0 ]; then
  rejected="yes"
else
  rejected="no"
fi
assert_eq "TC-4.1: empty phase は patch validation で reject される (cycle 10 guard が必要な根拠)" "yes" "$rejected"

# --- TC-tampered-sid: tampered .rite-session-id (non-UUID) → helper が legacy fallback で patch 成功 (cycle 22 F-01) ---
# 旧実装は tampered content (例: `../../../etc/passwd`) を validation せずに `--session "$_sid"` として
# 下流 flow-state-update.sh に流し、UUID validation で reject されて helper exit 1 → resume hard-abort
# する経路を持っていた。cycle 22 修正で _sid 抽出直後に UUID validation を入れ、invalid 時は空文字に
# 降格して legacy fallback patch (--session 引数なし) で成功するようにした。
echo "TC-tampered-sid: tampered .rite-session-id (non-UUID) → helper が legacy fallback patch で exit 0 (cycle 22 F-01 regression guard)"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
# legacy file に valid phase を入れて patch 経路を実行可能にする (両不在 skip 経路に流れないように)
write_legacy "$SBX" '{"phase":"phase5_lint","next_action":"continue","active":false}'
# tampered content を .rite-session-id に書き込む (UUID validation を bypass しようとする攻撃ベクトル)
echo "../../../etc/passwd" > "$SBX/.rite-session-id"
helper_err=$(mktemp /tmp/rite-resume-tampered-err-XXXXXX)
if (cd "$SBX" && bash "$HELPER" "$PLUGIN_ROOT" 2>"$helper_err"); then
  helper_rc=0
else
  helper_rc=$?
fi
if [ "$helper_rc" -ne 0 ]; then
  echo "  helper_err:" >&2
  head -5 "$helper_err" | sed 's/^/    /' >&2
fi
rm -f "$helper_err"
assert_eq "TC-tampered-sid.1: helper exit 0 (tampered sid は empty 扱いで legacy fallback patch 成功)" "0" "$helper_rc"
# patch が legacy file (.rite-flow-state) に対して active=true を反映していることを確認
final_active=$(jq -c '.active' "$SBX/.rite-flow-state" 2>/dev/null)
assert_eq "TC-tampered-sid.2: legacy file の active が true に restored される (patch 成功の side effect)" "true" "$final_active"

# --- Summary ---
echo
echo "─── resume-active-flag-restore.test.sh summary ──────────────────────────"
echo "PASS: $PASS"
echo "FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed tests:"
  for n in "${FAILED_NAMES[@]}"; do
    echo "  - $n"
  done
  exit 1
fi
echo "All tests passed."
