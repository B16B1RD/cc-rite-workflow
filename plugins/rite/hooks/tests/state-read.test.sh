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
# History: see plugins/rite/references/state-read-evolution.md
#
# Usage: bash plugins/rite/hooks/tests/state-read.test.sh
set -euo pipefail

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

# Signal trap (EXIT/INT/TERM/HUP) で sandbox / 個別 file の leak を防ぐ。
# 実装は Form B (portability variant、return 0 必須) — 詳細は L46 / bash-trap-patterns.md "cleanup 関数の契約" 節 Form B 参照
# History: state-read-evolution.md (集約された helper)
cleanup_dirs=()
cleanup_files=()
_state_read_test_cleanup() {
  local d f
  for d in "${cleanup_dirs[@]:-}"; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
  done
  for f in "${cleanup_files[@]:-}"; do
    [ -n "$f" ] && [ -f "$f" ] && rm -f "$f"
  done
  return 0  # Form B (portability variant) → return 0 必須 (bash-trap-patterns.md "cleanup 関数の契約" 節 Form B 参照)
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
# git failure は silent suppression せず fail-fast (CI で git config 由来の問題で sandbox が
# 破損すると state-path-resolve.sh が cwd fallback して偶発的 silent regression を起こすため)。
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

echo "TC-3: both absent → default returned"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
write_config_v2 "$SBX"
write_session_id "$SBX" "11111111-1111-1111-1111-111111111111"
result=$(run_helper "$SBX" --field phase --default "default_phase")
assert_eq "TC-3.1: phase default returned" "default_phase" "$result"
result=$(run_helper "$SBX" --field parent_issue_number --default 0)
assert_eq "TC-3.2: parent_issue_number default 0" "0" "$result"
rm -rf "$SBX"

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

# bad SID 名で per-session file を作成し regex を `.*` に mutate すると bad per-session が
# 読まれて assert 失敗で kill される (mutation kill power 確保)。OS-friendly な non-UUID vector
# (`..` traversal 系は WSL2 等で path 解決失敗するため避ける)。
# History: state-read-evolution.md (Cycle 別の主要な修正 — TC-6 non-UUID vector OS-friendly 化)
echo "TC-6: tampered .rite-session-id (non-UUID format) → strict regex reject → legacy fallback"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
write_config_v2 "$SBX"
# underscore は RFC 4122 hex 範囲外、filesystem 上に作成可能
BAD_SID_NON_UUID="not_a_uuid"
echo "$BAD_SID_NON_UUID" > "$SBX/.rite-session-id"
mkdir -p "$SBX/.rite/sessions"
printf '%s' '{"phase":"BAD_NON_UUID"}' > "$SBX/.rite/sessions/${BAD_SID_NON_UUID}.flow-state"
write_legacy "$SBX" '{"phase":"safe_legacy"}'
result=$(run_helper "$SBX" --field phase --default "")
assert_eq "TC-6.1: non-UUID session_id ignored, legacy used (mutation kill via per-session file が必ず存在)" "safe_legacy" "$result"
rm -rf "$SBX"

# 旧 regex `^[0-9a-f-]{36}$` は hyphen 位置を強制せず 36 字 hex 連続も valid 扱いだったため、
# `^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$` strict に強化済み。
# per-session 不在で revert test すると pre-fix/post-fix が同一 legacy 値を返し pin 機能不全に
# なるため、bad SESSION_ID 名で per-session file を作成して revert test を成立させる必須条件。
# History: state-read-evolution.md (Cycle 別の主要な修正 — RFC 4122 strict 化、writer/reader 対称化 doctrine)
echo "TC-6.RFC: ハイフン無し 36 字 hex (RFC 4122 非準拠) → reject されて legacy fallback"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
write_config_v2 "$SBX"
# 36 字 hex 連続 (旧 regex を通過するが RFC 4122 では invalid) — 1 行に書く
BAD_SID_NO_HYPHEN="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
echo "$BAD_SID_NO_HYPHEN" > "$SBX/.rite-session-id"
mkdir -p "$SBX/.rite/sessions"
printf '%s' '{"phase":"BAD_RFC1"}' > "$SBX/.rite/sessions/${BAD_SID_NO_HYPHEN}.flow-state"
write_legacy "$SBX" '{"phase":"safe_legacy_rfc"}'
result=$(run_helper "$SBX" --field phase --default "")
assert_eq "TC-6.RFC.1: hyphen 無し 36 字 hex は reject されて legacy fallback (revert test 有効)" "safe_legacy_rfc" "$result"
rm -rf "$SBX"

# ハイフン位置が間違った 36 字 (例: 9-3-4-4-12 や 7-5-4-4-12 等) も reject
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
write_config_v2 "$SBX"
BAD_SID_BAD_POS="aaaaaaaaa-aaa-aaaa-aaaa-aaaaaaaaaaaa"
echo "$BAD_SID_BAD_POS" > "$SBX/.rite-session-id"
mkdir -p "$SBX/.rite/sessions"
printf '%s' '{"phase":"BAD_RFC2"}' > "$SBX/.rite/sessions/${BAD_SID_BAD_POS}.flow-state"
write_legacy "$SBX" '{"phase":"safe_legacy_pos"}'
result=$(run_helper "$SBX" --field phase --default "")
assert_eq "TC-6.RFC.2: ハイフン位置不正な 36 字 hex は reject されて legacy fallback (revert test 有効)" "safe_legacy_pos" "$result"
rm -rf "$SBX"

# TC-4 / TC-6 は 3 vector のみ pin していたため、newline / shell metachar / mixed case /
# 長さ制約破壊の追加 vector を pin (regex 緩和 / `tr` 削除時の silent regression 検出)。
# 設計選択: `^[0-9a-f]{8}-...` は canonical lowercase form のみ accept する defensive 仕様
# (RFC 4122 §3 は input case-insensitive 規定だが、本リポの SID 生成は lowercase デフォルトの
# ため uppercase は外部 injection 経路のみ → canonical form 強制が defense-in-depth として機能)。
# History: state-read-evolution.md (Cycle 別の主要な修正 — canonical lowercase form 強制 / case-sensitive FS gate)
echo "TC-6.INJECTION: SID injection vector defense"

# bad per-session file 作成成功数 tracking (file system が bad SID 名を accept した数)。
# 実 kill power とは別概念。kill 経路は backtick / too_short / too_long / non_hex /
# hyphen_misplaced (+ case-sensitive FS で uppercase / mixed_case)。newline / 空白を含む
# vector は `_resolve-session-id-from-file.sh` の tr -d '[:space:]' 副作用で kill power 0。
inject_created_count=0

# 各 vector で make_sandbox + bad SID + per-session (BAD_*) + legacy (safe_legacy_*) を作成。
# reject されると legacy fallback で safe_legacy_* が返る。design intent: kill power 5/7
# (non_hex / hyphen_misplaced / backtick / too_short / too_long が確実に kill)。
inject_vectors=(
  # 形式: "vector_name|sid_value|legacy_phase|description"
  "non_hex|zzzzzzzz-aaaa-aaaa-aaaa-aaaaaaaaaaaa|safe_legacy_nonhex|non-hex characters (RFC 4122 strict reject, tr 副作用なし)"
  "hyphen_misplaced|aaaaaaaaa-aaa-aaaa-aaaa-aaaaaaaaaaaa|safe_legacy_hyphen|hyphen position invalid (9-3-4-4-12 instead of 8-4-4-4-12, tr 副作用なし)"
  "backtick|\`whoami\`|safe_legacy_backtick|backtick command substitution"
  # uppercase / mixed_case は **case-sensitive FS 前提** (Linux ext4/btrfs/xfs)。case-insensitive
  # FS (macOS HFS+ default / NTFS / exFAT) では fixture と lookup が一致して false-positive
  # 失敗を起こすため、下の loop の `[ "$(uname -s)" != "Linux" ]` skip gate を適用する。
  "uppercase|AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA|safe_legacy_upcase|lowercase normalize の SoT pin (per-session path は normalize 後 lowercase で resolve、fixture uppercase 名は not-found → legacy fallback。tr A-F a-f normalize 削除で TC が落ちる。⚠️ case-sensitive FS 前提)"
  "mixed_case|aaaaaaaa-AAAA-aaaa-AAAA-aaaaaaaaaaaa|safe_legacy_mixcase|uppercase と同型 vector。⚠️ case-sensitive FS 前提"
  "too_short|aaaa-aaaa-aaaa-aaaa-aaaa|safe_legacy_short|36 字未満 (regex 長さ制約)"
  "too_long|aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaaaa|safe_legacy_long|36 字超過 (regex 長さ制約)"
)

for vector_entry in "${inject_vectors[@]}"; do
  IFS='|' read -r vector_name sid_value legacy_phase desc <<< "$vector_entry"

  # case-sensitive FS 前提の vector を Linux 以外では skip (macOS / Windows でローカル実行時の
  # false-positive 防止)。CI (Linux only) は引き続き kill power を確保。
  case "$vector_name" in
    uppercase|mixed_case)
      if [ "$(uname -s)" != "Linux" ]; then
        echo "  ⏭ TC-6.INJECTION.$vector_name: skipped on $(uname -s) (case-insensitive FS would defeat mutation kill power)"
        continue
      fi
      ;;
  esac

  SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
  write_config_v2 "$SBX"
  # printf '%b' で escape (e.g. \n) を解釈して newline injection を実装 (echo より portable)
  printf '%b' "$sid_value" > "$SBX/.rite-session-id"

  # bad SID 名で per-session file (BAD_INJECTION_*) を作成。pre-fix (緩い regex) は bad per-session
  # 読込 → BAD_* 返却 → assert 失敗で kill。post-fix (strict regex) は reject → legacy fallback。
  # per-session 不在経路では regex を `.*` に mutate しても全 vector pass する false-positive
  # (kill power 0) になるため bad SID 名 per-session 作成は必須。FS 制約で作成失敗する vector
  # は元実装と等価な経路に流れて kill power 失うが、coverage 0/7 → 4/7 に向上。
  bad_phase="BAD_INJECTION_${vector_name}"
  expanded_sid=$(printf '%b' "$sid_value")
  mkdir -p "$SBX/.rite/sessions"
  # 特殊文字ファイル名は best-effort (FS 制約は test bug ではないため stderr suppress)
  if printf '%s' "{\"phase\":\"$bad_phase\"}" > "$SBX/.rite/sessions/${expanded_sid}.flow-state" 2>/dev/null; then
    inject_created_count=$((${inject_created_count:-0} + 1))
  fi

  write_legacy "$SBX" "{\"phase\":\"$legacy_phase\"}"

  result=$(run_helper "$SBX" --field phase --default "DEFAULT_FALLBACK")
  # post-fix: legacy_phase 返却。pre-fix (`.*` mutation): bad_phase 返却 → kill。
  if [ "$result" = "$legacy_phase" ]; then
    echo "  ✅ TC-6.INJECTION.$vector_name: $desc → legacy fallback ($legacy_phase)"
    PASS=$((PASS+1))
  else
    echo "  ❌ TC-6.INJECTION.$vector_name: $desc — expected '$legacy_phase' got '$result'"
    FAIL=$((FAIL+1))
    FAILED_NAMES+=("TC-6.INJECTION.$vector_name")
  fi
  rm -rf "$SBX"  # inline rm -rf と EXIT trap cleanup_dirs[] の二重防御
done
# label "files created" は実 kill power と乖離するのを避けた表現 (旧 "mutation-kill effective" は誤解を招いた)。
# 想定値を下回る場合、operator は FS 制約 (case-insensitive FS / quota / 特殊文字 reject 等) を疑える。
echo "  ℹ️ TC-6.INJECTION files created (filesystem accept): $inject_created_count/${#inject_vectors[@]}"

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

# `flow_state:` セクションあり / `schema_version:` キー欠落の degenerate config で、
# `set -euo pipefail` 下で grep no-match (exit 1) が pipeline 全体 exit 1 を引き起こし、
# helper が silent に exit 1 する regression を再現。修正後は `|| v=""` で吸収され、
# case "*)" 分岐で SCHEMA_VERSION="1" fallback → legacy 直接 routing で正常完走することを pin。
echo "TC-8: flow_state セクションあり / schema_version 行なし → grep 不一致で pipefail silent failure しない"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
cat > "$SBX/rite-config.yml" <<EOF
flow_state:
  enabled: true
EOF
write_legacy "$SBX" '{"phase":"degenerate_config_legacy"}'
# 注: SID 不在 + schema_version 行なし → SCHEMA_VERSION="1" fallback → legacy 直接 routing
result=$(run_helper "$SBX" --field phase --default "")
assert_eq "TC-8.1: schema_version 行欠落でも helper が exit 0 で完走し legacy を読む" "degenerate_config_legacy" "$result"
rm -rf "$SBX"

# hard-coded line number reference は drift するため function/region 名で参照する
# (本体 hook と同じ refactor 耐性パターン)。
echo "TC-9: corrupt JSON state file → DEFAULT fallback (state-read.sh の jq error path / corrupt JSON branch)"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
write_config_v2 "$SBX"
SID="11111111-1111-1111-1111-111111111111"
write_session_id "$SBX" "$SID"
# truncated JSON (closing brace 欠落)
mkdir -p "$SBX/.rite/sessions"
printf '%s' '{"phase":"corrupt' > "$SBX/.rite/sessions/${SID}.flow-state"
# state-read.sh は jq parse error を WARNING on stderr で emit する。
# stdout-only capture で DEFAULT return value のみを assert する。
result=$(cd "$SBX" && bash "$HOOK" --field phase --default "corrupt_default" 2>/dev/null)
assert_eq "TC-9.1: corrupt JSON は DEFAULT を返す (silent fallback)" "corrupt_default" "$result"
rm -rf "$SBX"

# 旧 post-processing block (`if [ "$value" = "null" ]`) は dead code (mutation testing で判明)。
# jq の `//` 演算子 (alternative operator) が null/false を自動的に default に置換する仕様で
# 動いていたため block は削除済み。本 TC は jq // 経由の null normalization 動作を pin する。
# History: state-read-evolution.md (Cycle 別の主要な修正 — TC-10 dead-code post-processing block 削除)
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

# 空ファイル (touch で作成された size 0) に対する DEFAULT fallback 経路。
# `[ -s "$STATE_FILE" ]` size check で corrupt JSON (TC-9) と挙動を一致させる。
# History: state-read-evolution.md (Cycle 別の主要な修正 — 空ファイル edge case)
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

# 非 JSON ファイルは size > 0 で `[ -s ]` を通過し jq parse error fallback (`|| value="$DEFAULT"`)
# 経路で処理される。TC-12 (空ファイル / size 0) と組み合わせて size check と jq fallback の
# 両 path を個別に pin する (どちらか単独でも DEFAULT を返すことを保証)。
echo "TC-13: 非 JSON ファイル (plain text) → DEFAULT 返却 (jq parse-error fallback、size check と独立)"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
write_config_v2 "$SBX"
SID="11111111-1111-1111-1111-111111111111"
write_session_id "$SBX" "$SID"
mkdir -p "$SBX/.rite/sessions"
# 完全に非 JSON (plain text) — jq は parse error で stderr 出力 + exit 非 0 → || で DEFAULT
printf 'this is not json at all\nplain text content\n' > "$SBX/.rite/sessions/${SID}.flow-state"
# state-read.sh は jq parse error を WARNING on stderr で emit する。
# stdout-only capture で DEFAULT return value のみを assert する。
result=$(cd "$SBX" && bash "$HOOK" --field phase --default "non_json_default" 2>/dev/null)
assert_eq "TC-13.1: 非 JSON ファイルは DEFAULT を返す (jq parse error fallback)" "non_json_default" "$result"
rm -rf "$SBX"

# state-read.sh の "⚠️ Boolean field caveat" 節で文書化された jq `// $default` の boolean caveat
# を pin する。JSON `false` / `null` は jq の `//` で「falsy」と判定されて DEFAULT に置換される
# (jq 仕様: `false // "x"` → "x")。caveat は『boolean field を read してはいけない』ことを
# document しており、本 TC は「false が default に置換される」性質を pin することで、
# 将来 boolean field caller (例: `.active` を読む resume helper) を追加してはいけないことを強制。
echo "TC-14: boolean field caveat — JSON false は jq // 演算子で default に置換される (state-read.sh の Boolean field caveat 節)"
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

# state-read.sh の `case "$DEFAULT" in true|false)` ブロックが emit する WARNING を pin する。
# defense-in-depth として導入された警告経路を明示的に test 化することで、将来の refactor で
# silent に削除されても回帰を検知できる (WARNING を mutate / 削除すると本 TC が落ちる)。
echo "TC-14.3: boolean caveat WARNING — --default true / false 指定時に stderr へ警告を emit する"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
write_config_v2 "$SBX"
SID="11111111-1111-1111-1111-111111111111"
write_session_id "$SBX" "$SID"
write_per_session "$SBX" "$SID" '{"active":true,"phase":"phase5_lint","next_action":"continue"}'

# stderr のみを capture して WARNING line を grep で検索する
boolean_warn_true_path=$(mktemp /tmp/rite-tc14-warn-true-XXXXXX); cleanup_files+=("$boolean_warn_true_path")
(cd "$SBX" && bash "$HOOK" --field active --default "true") >/dev/null 2>"$boolean_warn_true_path"
if grep -q "boolean リテラル値" "$boolean_warn_true_path"; then
  echo "  ✅ TC-14.3.a: --default true で boolean caveat WARNING が emit される"
  PASS=$((PASS+1))
else
  echo "  ❌ TC-14.3.a: --default true で WARNING が emit されない (mutation kill power 不在)"
  echo "     stderr:"
  sed 's/^/       /' "$boolean_warn_true_path"
  FAIL=$((FAIL+1))
  FAILED_NAMES+=("TC-14.3.a: boolean caveat WARNING for --default true")
fi
rm -f "$boolean_warn_true_path"

boolean_warn_false_path=$(mktemp /tmp/rite-tc14-warn-false-XXXXXX); cleanup_files+=("$boolean_warn_false_path")
(cd "$SBX" && bash "$HOOK" --field active --default "false") >/dev/null 2>"$boolean_warn_false_path"
if grep -q "boolean リテラル値" "$boolean_warn_false_path"; then
  echo "  ✅ TC-14.3.b: --default false で boolean caveat WARNING が emit される"
  PASS=$((PASS+1))
else
  echo "  ❌ TC-14.3.b: --default false で WARNING が emit されない (mutation kill power 不在)"
  echo "     stderr:"
  sed 's/^/       /' "$boolean_warn_false_path"
  FAIL=$((FAIL+1))
  FAILED_NAMES+=("TC-14.3.b: boolean caveat WARNING for --default false")
fi
rm -f "$boolean_warn_false_path"

# negative test: --default true / false 以外では WARNING が出ないことを pin (false positive 検出)
boolean_warn_other_path=$(mktemp /tmp/rite-tc14-warn-other-XXXXXX); cleanup_files+=("$boolean_warn_other_path")
(cd "$SBX" && bash "$HOOK" --field active --default "OTHER_VALUE") >/dev/null 2>"$boolean_warn_other_path"
if grep -q "boolean リテラル値" "$boolean_warn_other_path"; then
  echo "  ❌ TC-14.3.c: --default OTHER_VALUE で boolean caveat WARNING が誤 emit (case 文の guard が緩い)"
  FAIL=$((FAIL+1))
  FAILED_NAMES+=("TC-14.3.c: boolean caveat WARNING false positive")
else
  echo "  ✅ TC-14.3.c: --default OTHER_VALUE では WARNING が emit されない (false positive なし)"
  PASS=$((PASS+1))
fi
rm -f "$boolean_warn_other_path"
rm -rf "$SBX"

# 「per-session 不在 + legacy が **別 session_id** を持つ」case で reader が DEFAULT 降格 +
# WORKFLOW_INCIDENT sentinel を emit する経路を直接 pin する。TC-2 は `legacy_sid=""` 経路のみ
# 検証していたため、`[ -z "$legacy_sid" ] || [ "$legacy_sid" = "$SESSION_ID" ]` 比較を `!=` への
# typo / inverted condition で regress させても TC-2 は通る silent regression 経路があった。
# writer 側 (flow-state-update.test.sh TC-AC-4-CROSS-SESSION-REFUSED) と対称な test coverage を
# reader 側に持たせて writer/reader 対称化 doctrine を test レベルで保証する。
# History: state-read-evolution.md (Doctrines / Principles, Cycle 別の主要な修正 — reader-side cross-session guard)
echo "TC-15: reader-side cross-session guard (per-session 不在 + legacy が別 session_id) → DEFAULT + WORKFLOW_INCIDENT emit"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
write_config_v2 "$SBX"
SID="11111111-1111-1111-1111-111111111111"
LEGACY_SID="22222222-2222-2222-2222-222222222222"
write_session_id "$SBX" "$SID"
# per-session file は不在 (writer-symmetric: fresh session で legacy のみ存在する scenario)
# legacy file は別 session_id を持つ
write_legacy "$SBX" "{\"phase\":\"phase5_post_stop_hook\",\"session_id\":\"${LEGACY_SID}\"}"
# stdout/stderr を別々に capture して両方を assert する
stdout_path=$(mktemp /tmp/rite-tc15-stdout-XXXXXX); cleanup_files+=("$stdout_path")
stderr_path=$(mktemp /tmp/rite-tc15-stderr-XXXXXX); cleanup_files+=("$stderr_path")
(cd "$SBX" && bash "$HOOK" --field phase --default "DEFAULT_REJECTED") >"$stdout_path" 2>"$stderr_path"
result=$(cat "$stdout_path")
assert_eq "TC-15.1: 別 session_id の legacy → DEFAULT 返却 (silent take-over 防止)" "DEFAULT_REJECTED" "$result"
# stderr に WORKFLOW_INCIDENT sentinel が emit されることを確認 (canonical helper 経由)
if grep -q "WORKFLOW_INCIDENT=1" "$stderr_path" && grep -q "type=cross_session_takeover_refused" "$stderr_path" && grep -q "layer=reader" "$stderr_path"; then
  echo "  ✅ TC-15.2: WORKFLOW_INCIDENT sentinel emit (canonical helper 経由)"
  PASS=$((PASS+1))
else
  echo "  ❌ TC-15.2: WORKFLOW_INCIDENT sentinel emit が確認できません"
  echo "     stderr:"
  sed 's/^/       /' "$stderr_path"
  FAIL=$((FAIL+1))
  FAILED_NAMES+=("TC-15.2: WORKFLOW_INCIDENT sentinel emit")
fi
rm -f "$stdout_path" "$stderr_path"
rm -rf "$SBX"

# 対比 case: legacy.session_id == current_sid は take-over OK。
# `[ -z "$legacy_sid" ] || [ "$legacy_sid" = "$SESSION_ID" ]` の後半 OR 分岐の revert test coverage。
echo "TC-15.B: reader-side same-session legacy fallback (legacy.session_id == current_sid) → legacy 値返却"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
write_config_v2 "$SBX"
SID="11111111-1111-1111-1111-111111111111"
write_session_id "$SBX" "$SID"
# per-session file 不在、legacy が **同じ** session_id を持つ
write_legacy "$SBX" "{\"phase\":\"same_session_legacy_phase\",\"session_id\":\"${SID}\"}"
result=$(run_helper "$SBX" --field phase --default "")
assert_eq "TC-15.B.1: 同一 session_id の legacy → legacy 値返却 (legitimate take-over)" "same_session_legacy_phase" "$result"
rm -rf "$SBX"

# `_resolve-cross-session-guard.sh` の `corrupt:*` 経路を 3 重 assert で pin:
# (1) DEFAULT 返却 + (2) sentinel emit + (3) jq_rc 非ゼロ。
# History: state-read-evolution.md (Cycle 別の主要な修正 — corrupt:* 経路分類 / legacy_state_corrupt sentinel pin)
echo "TC-15.C: reader-side legacy corrupt JSON → legacy_state_corrupt sentinel emit + DEFAULT 返却"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
write_config_v2 "$SBX"
SID="22222222-3333-4444-5555-666666666666"
write_session_id "$SBX" "$SID"
# per-session file 不在、legacy が corrupt JSON (truncated, size > 0)
printf '{"phase":"corrupt_payload' > "$SBX/.rite-flow-state"
stdout_path=$(mktemp /tmp/rite-tc15c-stdout-XXXXXX); cleanup_files+=("$stdout_path")
stderr_path=$(mktemp /tmp/rite-tc15c-stderr-XXXXXX); cleanup_files+=("$stderr_path")
(cd "$SBX" && bash "$HOOK" --field phase --default "DEFAULT_C") >"$stdout_path" 2>"$stderr_path"
result=$(cat "$stdout_path")
assert_eq "TC-15.C.1: corrupt legacy + per-session 不在 → DEFAULT 返却" "DEFAULT_C" "$result"
# stderr に legacy_state_corrupt sentinel が emit されることを確認
if grep -q "WORKFLOW_INCIDENT=1" "$stderr_path" \
    && grep -q "type=legacy_state_corrupt" "$stderr_path" \
    && grep -q "layer=reader" "$stderr_path"; then
  echo "  ✅ TC-15.C.2: legacy_state_corrupt sentinel emit (corrupt 分類経路 revert test)"
  PASS=$((PASS+1))
else
  echo "  ❌ TC-15.C.2: legacy_state_corrupt sentinel emit が確認できません"
  echo "     stderr:"
  sed 's/^/       /' "$stderr_path"
  FAIL=$((FAIL+1))
  FAILED_NAMES+=("TC-15.C.2: legacy_state_corrupt sentinel emit")
fi
# jq_rc が実 jq exit code (>= 1) を含むことを確認
if grep -qE "jq_rc=[1-9]" "$stderr_path"; then
  echo "  ✅ TC-15.C.3: jq_rc が実 jq exit code (>= 1) を含む (jq_rc revert test)"
  PASS=$((PASS+1))
else
  echo "  ❌ TC-15.C.3: jq_rc=0 または欠落 (jq_rc fix が revert された可能性)"
  echo "     stderr (relevant lines):"
  grep "WORKFLOW_INCIDENT" "$stderr_path" | sed 's/^/       /'
  FAIL=$((FAIL+1))
  FAILED_NAMES+=("TC-15.C.3: jq_rc must be >= 1 for corrupt JSON")
fi
rm -f "$stdout_path" "$stderr_path"
rm -rf "$SBX"

# `_resolve-cross-session-guard.sh` の sentinel が `corrupt:1` から `invalid_uuid:1` に分離された
# 経路を pin。state-read.sh は `legacy_state_corrupt` sentinel に `reason=invalid_uuid_format` を
# embed する。3 重 assert: (a) helper invalid_uuid:1 返却 + (b) sentinel emit + (c) reason field 含有。
# History: state-read-evolution.md (Cycle 別の主要な修正 — corrupt:1 → invalid_uuid:1 sentinel 分離)
echo "TC-15.D: reader-side legacy session_id failed UUID validation → invalid_uuid sentinel emit"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
write_config_v2 "$SBX"
SID="33333333-4444-5555-6666-777777777777"
write_session_id "$SBX" "$SID"
# legacy file は valid JSON だが session_id が UUID format に非準拠
write_legacy "$SBX" '{"phase":"some_phase","session_id":"not-a-valid-uuid"}'
stdout_path=$(mktemp /tmp/rite-tc15d-stdout-XXXXXX); cleanup_files+=("$stdout_path")
stderr_path=$(mktemp /tmp/rite-tc15d-stderr-XXXXXX); cleanup_files+=("$stderr_path")
(cd "$SBX" && bash "$HOOK" --field phase --default "DEFAULT_D") >"$stdout_path" 2>"$stderr_path"
result=$(cat "$stdout_path")
assert_eq "TC-15.D.1: invalid UUID legacy + per-session 不在 → DEFAULT 返却" "DEFAULT_D" "$result"
if grep -q "WORKFLOW_INCIDENT=1" "$stderr_path" \
    && grep -q "type=legacy_state_corrupt" "$stderr_path" \
    && grep -q "reason=invalid_uuid_format" "$stderr_path"; then
  echo "  ✅ TC-15.D.2: legacy_state_corrupt sentinel emit with reason=invalid_uuid_format (revert test)"
  PASS=$((PASS+1))
else
  echo "  ❌ TC-15.D.2: legacy_state_corrupt sentinel + invalid_uuid_format reason が確認できません"
  echo "     stderr:"
  sed 's/^/       /' "$stderr_path"
  FAIL=$((FAIL+1))
  FAILED_NAMES+=("TC-15.D.2: invalid_uuid sentinel emit")
fi
if grep -q "root_cause_hint=legacy_session_id_failed_uuid_validation_tampered_or_legacy_schema" "$stderr_path"; then
  echo "  ✅ TC-15.D.3: root_cause_hint differentiates invalid_uuid from jq parse failure (full-string pin)"
  PASS=$((PASS+1))
else
  echo "  ❌ TC-15.D.3: root_cause_hint=legacy_session_id_failed_uuid_validation_tampered_or_legacy_schema が含まれません"
  FAIL=$((FAIL+1))
  FAILED_NAMES+=("TC-15.D.3: root_cause_hint distinguishes UUID validation from jq parse")
fi
rm -f "$stdout_path" "$stderr_path"
rm -rf "$SBX"

# TC-15.2 / TC-15.C.2 は caller-side single revert (`2>/dev/null` → `2>&1`) を fail しない
# silent regression があったため、state-read.sh の `_resolve-cross-session-guard.sh` 呼び出しが
# 必ず `2>/dev/null` を含むことを grep で source-pin する metatest を追加。
# 旧 grep はコメント行 (`... so 2>/dev/null is safe.`) にマッチして false-positive で常に pass
# していたため、コメント除外 + 実 invocation line を anchor で検査する形に修正済み。
# History: state-read-evolution.md (Cycle 別の主要な修正 — caller-side stderr redirection source-pin)
echo 'TC-15.E: state-read.sh caller-side stderr redirection source-pin metatest (revert test)'
state_read_path="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")/state-read.sh"
state_read_caller=$(grep -v '^[[:space:]]*#' "$state_read_path" | grep -E 'classification=\$\(bash[^)]*_resolve-cross-session-guard\.sh[^)]*2>')
if [ -n "$state_read_caller" ]; then
  echo "  ✅ TC-15.E.1: state-read.sh caller line preserves stderr redirection (caller-side fix is preserved)"
  PASS=$((PASS+1))
else
  echo "  ❌ TC-15.E.1: state-read.sh の caller-side stderr redirection が消失 (caller-side fix が revert された可能性)"
  echo "     現状の caller line (コメント除外後):"
  grep -v '^[[:space:]]*#' "$state_read_path" | grep "_resolve-cross-session-guard.sh" | sed 's/^/       /'
  FAIL=$((FAIL+1))
  FAILED_NAMES+=("TC-15.E.1: state-read.sh caller-side stderr redirection source-pin")
fi

# state-read.sh 冒頭の helper 存在チェックループは Issue #687 同型の deploy regression
# (chmod -x / 削除 / install 不整合) を構造的に防ぐ目的で導入された。test 不在では loop の typo /
# rename による silent 空 loop 化を検出できず structural defense が無音消滅するため、全 helper ×
# chmod -x 経路を実発火して exit 1 + ERROR with helper name を pin する。
# History: state-read-evolution.md (Cycle 別の主要な修正 — helper-missing fail-fast / deploy regression structural defense)
echo "TC-DEPLOY-REGRESSION: state-read.sh helper-missing fail-fast"
HOOKS_DIR="$(cd "$(dirname "$HOOK")" && pwd)"
SANDBOX_HOOKS=$(mktemp -d) || { echo "ERROR: TC-DEPLOY-REGRESSION mktemp -d failed"; exit 1; }
cleanup_dirs+=("$SANDBOX_HOOKS")

# Copy all .sh helpers to sandbox so SCRIPT_DIR of state-read.sh points there
cp "$HOOKS_DIR"/*.sh "$SANDBOX_HOOKS/"
chmod +x "$SANDBOX_HOOKS"/*.sh

# Sandbox repo for STATE_ROOT resolution
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
write_config_v2 "$SBX"
write_session_id "$SBX" "11111111-1111-1111-1111-111111111111"

# helpers checked by state-read.sh's `_validate-helpers.sh` invocation。
# _validate-helpers.sh の DEFAULT_HELPERS 配列を SoT として動的抽出することで、ADD 方向の drift
# (新 helper 追加に本配列が未追従) も検出可能 (helper-list SoT 集約 doctrine、state-read-evolution.md 参照)。
mapfile -t deploy_regression_helpers < <(
  awk '/^DEFAULT_HELPERS=\(/,/^\)$/' "$HOOKS_DIR/_validate-helpers.sh" \
    | grep -oE '[a-z_][a-z_0-9-]*\.sh'
)
if [ "${#deploy_regression_helpers[@]}" -eq 0 ]; then
  echo "FATAL: deploy_regression_helpers の動的抽出が空。_validate-helpers.sh の DEFAULT_HELPERS 配列が読み取れません" >&2
  exit 1
fi

for _h in "${deploy_regression_helpers[@]}"; do
  # 全 helper を restore してから対象のみ chmod -x (各 case を independent に保つ)
  chmod +x "$SANDBOX_HOOKS"/*.sh
  if [ ! -f "$SANDBOX_HOOKS/$_h" ]; then
    echo "  ❌ TC-DEPLOY-REGRESSION.$_h: helper not found in sandbox copy"
    FAIL=$((FAIL+1))
    FAILED_NAMES+=("TC-DEPLOY-REGRESSION.$_h: missing in sandbox")
    continue
  fi
  chmod -x "$SANDBOX_HOOKS/$_h"

  dr_output=$(cd "$SBX" && bash "$SANDBOX_HOOKS/state-read.sh" --field phase --default "" 2>&1; echo "_EXIT_$?")
  dr_exit_marker=$(printf '%s' "$dr_output" | grep -oE '_EXIT_[0-9]+$' | tail -1)
  if [ "$dr_exit_marker" = "_EXIT_1" ] && printf '%s' "$dr_output" | grep -qF "$_h"; then
    echo "  ✅ TC-DEPLOY-REGRESSION.$_h: chmod -x → exit 1 + ERROR contains helper name"
    PASS=$((PASS+1))
  else
    echo "  ❌ TC-DEPLOY-REGRESSION.$_h: did not fail-fast as expected"
    echo "     exit_marker: $dr_exit_marker"
    echo "     output:"
    printf '%s\n' "$dr_output" | sed 's/^/       /' | head -10
    FAIL=$((FAIL+1))
    FAILED_NAMES+=("TC-DEPLOY-REGRESSION.$_h")
  fi
done
chmod +x "$SANDBOX_HOOKS"/*.sh  # Restore for cleanup safety
rm -rf "$SBX"  # 他 SBX と inline rm -rf の symmetry。EXIT trap cleanup_dirs[] が二重防御

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
