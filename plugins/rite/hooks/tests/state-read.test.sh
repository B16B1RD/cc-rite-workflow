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

# PR #688 cycle 8 fix (F-02 MEDIUM): signal trap (EXIT/INT/TERM/HUP) で sandbox leak を防ぐ。
# flow-state-update.test.sh は cycle 5 F-09 で同型の cleanup pattern を導入済みで、本テストは
# その drift 状態だった (cycle 7 review で test reviewer 検出)。Ctrl+C / SIGTERM で `mktemp -d`
# で作られた sandbox が `/tmp/tmp.XXXXXX` に leak する経路を塞ぐ。
cleanup_dirs=()
_state_read_test_cleanup() {
  local d
  for d in "${cleanup_dirs[@]:-}"; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
  done
}
trap '_state_read_test_cleanup' EXIT
trap '_state_read_test_cleanup; exit 130' INT
trap '_state_read_test_cleanup; exit 143' TERM
trap '_state_read_test_cleanup; exit 129' HUP

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
# PR #688 cycle 5 review (code-quality + test reviewer LOW 推奨): git failure を silent suppression せず、
# fail-fast にする。CI 環境で git config 由来の問題 (init.defaultBranch 未設定 / HOME 不在等) が
# 発生した場合に sandbox が破損したまま test が走ると、`state-path-resolve.sh` が cwd fallback して
# 偶発的な silent regression を起こすため、明示的に exit 1 する。stderr を /dev/null に流さず捕捉する。
make_sandbox() {
  local d sandbox_err
  d=$(mktemp -d) || { echo "ERROR: make_sandbox: mktemp -d failed" >&2; exit 1; }
  sandbox_err=$(mktemp /tmp/rite-sandbox-err-XXXXXX) || sandbox_err="/dev/null"
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
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
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
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
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
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
write_config_v2 "$SBX"
write_session_id "$SBX" "11111111-1111-1111-1111-111111111111"
result=$(run_helper "$SBX" --field phase --default "default_phase")
assert_eq "TC-3.1: phase default returned" "default_phase" "$result"
result=$(run_helper "$SBX" --field parent_issue_number --default 0)
assert_eq "TC-3.2: parent_issue_number default 0" "0" "$result"
rm -rf "$SBX"

# --- TC-4: invalid field name rejected ---
echo "TC-4: invalid field name (path traversal style) → ERROR + exit 1"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
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
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
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
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
write_config_v2 "$SBX"
echo "../../../etc/passwd" > "$SBX/.rite-session-id"
write_legacy "$SBX" '{"phase":"safe_legacy"}'
result=$(run_helper "$SBX" --field phase --default "")
assert_eq "TC-6.1: tampered session_id ignored, legacy used" "safe_legacy" "$result"
rm -rf "$SBX"

# --- TC-7: schema_version=1 (or absent) routes directly to legacy even if SID + per-session exist ---
echo "TC-7: schema_version=1 routes to legacy"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
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
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
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
# PR #688 cycle 5 review (code-quality LOW + prompt-engineer 推奨 + security informational、
# 3-reviewer 独立検出): hard-coded line number reference は cycle ごとに drift するため、
# function/region 名で参照する (本体 hook と同じ refactor 耐性パターン)。
echo "TC-9: corrupt JSON state file → DEFAULT fallback (state-read.sh の jq error path / corrupt JSON branch)"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
write_config_v2 "$SBX"
SID="11111111-1111-1111-1111-111111111111"
write_session_id "$SBX" "$SID"
# truncated JSON (closing brace 欠落)
mkdir -p "$SBX/.rite/sessions"
printf '%s' '{"phase":"corrupt' > "$SBX/.rite/sessions/${SID}.flow-state"
result=$(run_helper "$SBX" --field phase --default "corrupt_default")
assert_eq "TC-9.1: corrupt JSON は DEFAULT を返す (silent fallback)" "corrupt_default" "$result"
rm -rf "$SBX"

# --- TC-10: JSON null value → jq の // 演算子で default に置換される ---
# PR #688 cycle 4 (test reviewer mutation testing 対応):
# 旧 TC-10 は state-read.sh の post-processing block (`if [ "$value" = "null" ]`) を検証する
# 意図だったが、mutation testing でその block を削除しても TC-10 が PASS することが判明
# → block は dead code であり、jq の `//` 演算子 (alternative operator) が null/false を
# 自動的に default に置換する仕様 (jq Manual) で動いていた。cycle 4 で post-processing
# block を削除し、本 TC を「jq の // 演算子による null normalization の動作確認」として
# 書き直す。state-read.sh の DEFAULT 値 (`"x"`) が確実に返ることで `// $default` の動作を pin。
echo "TC-10: JSON null value → jq の // 演算子で caller default に置換される"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
write_config_v2 "$SBX"
SID="11111111-1111-1111-1111-111111111111"
write_session_id "$SBX" "$SID"
write_per_session "$SBX" "$SID" '{"phase":null}'
# JSON null は jq の `// $default` で $default に置換される (literal "null" 文字列にはならない)
result=$(run_helper "$SBX" --field phase --default "x")
assert_eq "TC-10.1: JSON null は jq // 経由で default に置換される" "x" "$result"
# 追加検証: DEFAULT が空文字 "" の場合も同様に置換される (pin jq // 動作)
result_empty=$(run_helper "$SBX" --field phase --default "")
assert_eq "TC-10.2: JSON null + DEFAULT 空文字 → 空文字列を返す (literal 'null' を返さない)" "" "$result_empty"
rm -rf "$SBX"

# --- TC-11: --default 省略時の挙動 → 空文字列を返す ---
echo "TC-11: --default 省略時 → 空文字列を返す (CLI default behaviour)"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
write_config_v2 "$SBX"
SID="11111111-1111-1111-1111-111111111111"
write_session_id "$SBX" "$SID"
# field が存在しない state を作る
write_per_session "$SBX" "$SID" '{"phase":"x"}'
# --default を渡さずに存在しない field を読む
result=$(run_helper "$SBX" --field nonexistent_field)
assert_eq "TC-11.1: --default 省略 + field 不在 → 空文字列" "" "$result"
rm -rf "$SBX"

# --- TC-12: 空ファイル (size 0) → DEFAULT 返却 (F-C MEDIUM cycle 5) ---
# PR #688 cycle 5 (test reviewer F-C MEDIUM): 空ファイル (touch で作成された size 0) に対する
# DEFAULT fallback が cycle 4 まで未カバーだった。`[ -s "$STATE_FILE" ]` size check 追加で
# corrupt JSON (TC-9) と挙動を一致させる。
echo "TC-12: 空ファイル (size 0) → DEFAULT 返却 (空ファイル edge case)"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
write_config_v2 "$SBX"
SID="11111111-1111-1111-1111-111111111111"
write_session_id "$SBX" "$SID"
mkdir -p "$SBX/.rite/sessions"
# touch で 0 byte ファイル作成 (jq は exit 0 + 空出力を返す silent path)
touch "$SBX/.rite/sessions/${SID}.flow-state"
result=$(run_helper "$SBX" --field phase --default "empty_file_default")
assert_eq "TC-12.1: 空ファイル (size 0) は DEFAULT を返す (jq silent empty 防止)" "empty_file_default" "$result"
rm -rf "$SBX"

# --- TC-13: 非 JSON ファイル → DEFAULT 返却 (size check と独立した jq parse-error fallback の defensive coverage) ---
# PR #688 cycle 6 review (test reviewer F-04 MEDIUM 対応): cycle 5 のコメントは「F-C MEDIUM
# (size check 追加でカバー)」と記述していたが mutation testing で誤りと判明 — 非 JSON ファイルは
# size > 0 のため `[ -s "$STATE_FILE" ]` チェックを通過し、jq の parse error fallback (`|| value="$DEFAULT"`)
# 経路で処理される。本 TC は size check と **独立** に機能する jq parse-error fallback の defensive
# coverage を pin する。TC-12 (空ファイル / size 0) と組み合わせることで、size check と jq fallback の
# 両 path が個別に検証される。
echo "TC-13: 非 JSON ファイル (plain text) → DEFAULT 返却 (jq parse-error fallback、size check と独立)"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
write_config_v2 "$SBX"
SID="11111111-1111-1111-1111-111111111111"
write_session_id "$SBX" "$SID"
mkdir -p "$SBX/.rite/sessions"
# 完全に非 JSON (plain text) — jq は parse error で stderr 出力 + exit 非 0 → || で DEFAULT
printf 'this is not json at all\nplain text content\n' > "$SBX/.rite/sessions/${SID}.flow-state"
result=$(run_helper "$SBX" --field phase --default "non_json_default")
assert_eq "TC-13.1: 非 JSON ファイルは DEFAULT を返す (jq parse error fallback)" "non_json_default" "$result"
rm -rf "$SBX"

# --- TC-14: boolean field caveat (cycle 16 fix F-04 MEDIUM、cycle 15 review test reviewer) ---
# state-read.sh:128-134 で文書化された jq `// $default` 演算子の boolean caveat を pin する。
# JSON `false` / `null` はいずれも jq の `//` 演算子で「falsy」とみなされ DEFAULT に置換される。
# これは jq の仕様: `false // "x"` → "x" (`null // "x"` も同様)。
# 現状の caller は全て非 boolean (phase / pr_number / loop_count 等) のため実害はないが、
# 将来 boolean field caller (例: `.active` を読む resume helper) を追加するときに
# caveat が test で守られていないと silent regression 化する。
# 重要: caveat は『boolean field を read してはいけない』ことを document しており、本 TC は
# その「false が default に置換される」性質を pin する (回帰時に test が落ちて caller 側で
# boolean read を追加すべきではないことを強制する)。
echo "TC-14: boolean field caveat — JSON false は jq // 演算子で default に置換される (state-read.sh:128-134)"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
write_config_v2 "$SBX"
SID="11111111-1111-1111-1111-111111111111"
write_session_id "$SBX" "$SID"
write_per_session "$SBX" "$SID" '{"active":false,"phase":"phase5_lint","next_action":"continue"}'
# JSON false は jq の // で falsy とみなされ DEFAULT に置換される
result=$(run_helper "$SBX" --field active --default "default_for_false")
assert_eq "TC-14.1: JSON false は jq // 演算子で default に置換される (boolean read NG の根拠)" "default_for_false" "$result"
# 比較対象: 同一ファイルの phase field (string) は正しく値を返す
result_phase=$(run_helper "$SBX" --field phase --default "ignored")
assert_eq "TC-14.2: 同一ファイルの string field は正しく値を返す (boolean caveat は boolean field 限定)" "phase5_lint" "$result_phase"
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
