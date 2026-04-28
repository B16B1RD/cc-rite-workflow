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
# verified-review cycle 44 F-03 HIGH 対応:
# 旧実装は per-session file を作らない設計だったが、`.*` mutation で UUID validation が bypass
# されると STATE_FILE = `$SBX/.rite/sessions/../../../etc/passwd.flow-state` という path に
# 解決されて helper はそのファイルが存在しないため legacy fallback、結果 `safe_legacy` が
# 返る test pass の false-positive (mutation kill power 0) だった。
#
# 修正: TC-6.RFC.1/2 と同型の per-session file 作成 pattern を適用。bad SID 名で per-session
# file を作成し phase=BAD_TRAVERSAL を書き込む。pre-fix (緩い regex) では bad per-session が
# 読まれ BAD_TRAVERSAL 返却 → assert 失敗で kill される。post-fix (strict regex) では reject
# されて legacy fallback で safe_legacy 返却 → assert 通過。
# 注: `../../../etc/passwd` を含む file name は OS によっては作れない。`mkdir -p` の中間ディレクトリ
# 作成と `printf > path` の組み合わせで sandbox 内 `$SBX/etc/passwd.flow-state` を作る経路になる
# (sandbox 外には書かない、`rm -rf "$SBX"` で削除される)。失敗時は legacy fallback で test 通過するため
# false negative にはならないが、mutation kill power はその vector では失われる (best-effort)。
echo "TC-6: tampered .rite-session-id (path traversal pattern) → fallback to legacy"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
write_config_v2 "$SBX"
BAD_SID_TRAVERSAL="../../../etc/passwd"
echo "$BAD_SID_TRAVERSAL" > "$SBX/.rite-session-id"
# best-effort per-session file 作成 (mutation kill power 確保のため):
mkdir -p "$SBX/.rite/sessions" 2>/dev/null
printf '%s' '{"phase":"BAD_TRAVERSAL"}' > "$SBX/.rite/sessions/${BAD_SID_TRAVERSAL}.flow-state" 2>/dev/null || true
write_legacy "$SBX" '{"phase":"safe_legacy"}'
result=$(run_helper "$SBX" --field phase --default "")
assert_eq "TC-6.1: tampered session_id ignored, legacy used (mutation kill via per-session file)" "safe_legacy" "$result"
rm -rf "$SBX"

# --- TC-6 RFC 4122 strict (cycle 22 F-03 MEDIUM): hyphen 位置の異なる 36 字 hex も reject ---
# 旧実装 `^[0-9a-f-]{36}$` は hyphen 位置を強制せず、36 字 hex 連続 (hyphen 0 個) も valid 扱い
# だった。cycle 22 で `^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$` (RFC 4122
# strict) に強化し、これらの非準拠形式も reject されることを pin する (将来 SESSION_ID を別 context
# に流用したときの spec drift で脆弱性化を防ぐ defense-in-depth)。
#
# PR #688 cycle 24 fix (F-02 HIGH): per-session file を bad-name UUID で作成して fallback 経路を分岐
# させる。cycle 22 旧実装は per-session file を作成せずに legacy のみ書き込んでいたため、pre-fix
# (lax regex で SESSION_ID accept) と post-fix (strict regex で SESSION_ID="") の両方が legacy
# fallback で同一値を返し、revert test として機能していなかった (test 自身が validation logic を
# pin できていない false-positive)。
# 修正方法: 本 TC で使う bad SESSION_ID 値を per-session file 名として作成し、{"phase":"BAD_RFC*"}
# を書き込む。pre-fix では SESSION_ID が accept されて per-session file が読まれ BAD_RFC* が返る。
# post-fix では SESSION_ID="" で legacy fallback され safe_legacy_* が返る。assert は post-fix の
# 期待値 (safe_legacy_*) のため、pre-fix で BAD_RFC* が返ると test が fail し regex strict 化が
# pin される。
echo "TC-6.RFC: ハイフン無し 36 字 hex (RFC 4122 非準拠) → reject されて legacy fallback (cycle 22 F-03)"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
write_config_v2 "$SBX"
# 36 字 hex 連続 (旧 regex を通過するが RFC 4122 では invalid) — 1 行に書く
BAD_SID_NO_HYPHEN="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
echo "$BAD_SID_NO_HYPHEN" > "$SBX/.rite-session-id"
# bad SESSION_ID 名で per-session file を作成 (pre-fix の lax regex で読み込まれる経路)。
# post-fix の strict regex では SESSION_ID="" になり下記の per-session file は参照されず legacy fallback。
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

# --- TC-6.INJECTION: SID injection vector defense-in-depth (verified-review cycle 41 II-4) ---
# 背景: 既存の TC-4 (path traversal) と TC-6 (no-hyphen / bad-position) は 3 種類の attack vector
# のみ pin していた。本 TC は newline injection / shell metachar / mixed case 等の追加 vector を
# pin する (defense-in-depth で正規表現緩和 / `tr` 削除時の silent regression 検出)。
#
# **正当化** (verified-review cycle 41 II-4 訂正): 旧 verified-review テキストは「RFC 4122 strict は
# lowercase only」と表現したが、これは不正確 — RFC 4122 §3 (Output and Input) は
# 「The hexadecimal values "a" through "f" are output as lower case characters and **are case
# insensitive on input**」と明記しており、ABNF grammar も `hexDigit = ... / "F"` で uppercase を
# accept する。実装の `^[0-9a-f]{8}-...` 正規表現は **canonical lowercase output 形式のみを
# defensive に accept する** 設計選択であり、RFC strict 準拠の input case-insensitivity からは
# 緩い (= reject すべきでない uppercase UUID も reject する) 仕様。本 test は正規表現の
# defensive 動作 (canonical lowercase form 以外を reject) を pin する。
#
# 本リポでは uuidgen / git の SID 生成は lowercase デフォルトのため、uppercase UUID は外部
# injection 経路でのみ発生する。canonical lowercase form の defensive accept は実用上 valid な
# defense-in-depth として機能する (理由付けが「RFC 4122 strict」ではなく「canonical form 強制」
# である点が cycle 41 II-4 訂正の核心)。
#
# 攻撃 vector:
#   - newline injection: SID 内に改行を埋め込んで後続 line を別 field とする攻撃
#   - shell metachar: `$()` / バッククォート で command substitution を狙う攻撃
#   - mixed case (uppercase): canonical lowercase form 以外を reject する defensive 動作
#   - 短すぎる / 長すぎる SID: regex の長さ制約破壊試行
echo "TC-6.INJECTION: SID injection vector defense (cycle 41 II-4)"

# 各 vector ごとに make_sandbox + bad SESSION_ID + per-session file (BAD_*) + legacy (safe_legacy_*)
# のパターンで pin する (TC-6.RFC と同型)。reject されると legacy fallback で safe_legacy_* が返る。
inject_vectors=(
  # 形式: "vector_name|sid_value|legacy_phase|description"
  "newline|aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa\nphase5_post_stop_hook|safe_legacy_newline|newline injection"
  "command_sub|\$(echo INJECTED)|safe_legacy_cmdsub|shell command substitution"
  "backtick|\`whoami\`|safe_legacy_backtick|backtick command substitution"
  "uppercase|AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA|safe_legacy_upcase|lowercase normalize の SoT を pin (uppercase は accept されるが per-session path は normalized lowercase で resolution されるため、fixture が uppercase 名 (BAD_*) で per-session を作る限り not-found → legacy fallback で safe_legacy_upcase が返る。tr A-F a-f の normalize 削除で TC が落ちる identification power を持つ)"
  "mixed_case|aaaaaaaa-AAAA-aaaa-AAAA-aaaaaaaaaaaa|safe_legacy_mixcase|lowercase normalize の SoT を pin (mixed case も accept + normalize 経路を辿る同型 vector。uppercase entry と同じ逻輯で fallback が発火)"
  "too_short|aaaa-aaaa-aaaa-aaaa-aaaa|safe_legacy_short|36 字未満 (regex 長さ制約)"
  "too_long|aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaaaa|safe_legacy_long|36 字超過 (regex 長さ制約)"
)

for vector_entry in "${inject_vectors[@]}"; do
  IFS='|' read -r vector_name sid_value legacy_phase desc <<< "$vector_entry"

  SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
  write_config_v2 "$SBX"
  # printf '%b' で escape (e.g. \n) を解釈させて newline injection を実装。bash の echo より portable。
  printf '%b' "$sid_value" > "$SBX/.rite-session-id"

  # verified-review cycle 44 F-01 CRITICAL 対応:
  # 旧実装は per-session file を作らない設計だったが、これは UUID validation regex を `.*` に
  # mutate しても全 vector が pass する false-positive (mutation kill power 0) だった。
  # 真因: per-session file 不在で validation を bypass しても helper は存在しない
  # `.rite/sessions/<bad-sid>.flow-state` を探して legacy fallback するため、reject/accept
  # 両経路が同一結果 (legacy_phase) に収束し pin 不能。
  #
  # 修正: bad SESSION_ID 名で per-session file を作成し phase=BAD_INJECTION_<vector> を書き込む。
  # pre-fix (緩い regex) では bad per-session が読まれ BAD_INJECTION_* 返却 → assert 失敗で kill される。
  # post-fix (strict regex) では reject されて legacy fallback で safe_legacy_* 返却 → assert 通過。
  # TC-6.RFC.1/2 と同型のパターンで mutation testing canonical doctrine (PR #688 cycles 3-5/31) と整合。
  #
  # ファイルシステム制約: newline / command substitution char (`$()`) / backtick (` `` `) を含む
  # ファイル名は OS が受け付けない場合があるため、`mkdir -p ... && printf > ...` を best-effort で
  # 試行する。作成失敗した vector は元実装と等価な「per-session 不在 → legacy fallback」経路で
  # mutation kill power は得られないが、それ以外 (uppercase / mixed_case / too_short / too_long)
  # では確実に mutation kill power が成立する (regex 緩和を kill する coverage が 0/7 → 4/7 に向上)。
  bad_phase="BAD_INJECTION_${vector_name}"
  expanded_sid=$(printf '%b' "$sid_value")
  mkdir -p "$SBX/.rite/sessions"
  # 特殊文字を含むファイル名作成は best-effort。失敗しても test は continue する (legacy fallback に流れる)。
  # printf 失敗は stderr suppress (file system が受け付けないだけで test bug ではない)。
  printf '%s' "{\"phase\":\"$bad_phase\"}" > "$SBX/.rite/sessions/${expanded_sid}.flow-state" 2>/dev/null || true

  write_legacy "$SBX" "{\"phase\":\"$legacy_phase\"}"

  result=$(run_helper "$SBX" --field phase --default "DEFAULT_FALLBACK")
  # assert: post-fix (strict regex) では bad SID は reject され legacy_phase が返る。
  # pre-fix (`.*` への regex 緩和 mutation) では bad per-session が読まれ bad_phase が返り test fail で kill される。
  # ファイル作成失敗 vector でも legacy_phase が返るため assert 通過 (false negative にはならない)。
  if [ "$result" = "$legacy_phase" ]; then
    echo "  ✅ TC-6.INJECTION.$vector_name: $desc → legacy fallback ($legacy_phase)"
    PASS=$((PASS+1))
  else
    echo "  ❌ TC-6.INJECTION.$vector_name: $desc — expected '$legacy_phase' got '$result'"
    FAIL=$((FAIL+1))
    FAILED_NAMES+=("TC-6.INJECTION.$vector_name")
  fi
done

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
# verified-review cycle 35 fix F-09 LOW: state-read.sh now emits jq parse error as WARNING on stderr.
# Use stdout-only capture to assert just the DEFAULT return value.
result=$(cd "$SBX" && bash "$HOOK" --field phase --default "corrupt_default" 2>/dev/null)
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
# verified-review cycle 35 fix F-09 LOW: state-read.sh now emits jq parse error as WARNING on stderr.
# Use stdout-only capture to assert just the DEFAULT return value.
result=$(cd "$SBX" && bash "$HOOK" --field phase --default "non_json_default" 2>/dev/null)
assert_eq "TC-13.1: 非 JSON ファイルは DEFAULT を返す (jq parse error fallback)" "non_json_default" "$result"
rm -rf "$SBX"

# --- TC-14: boolean field caveat (cycle 16 fix F-04 MEDIUM、cycle 15 review test reviewer) ---
# state-read.sh の "⚠️ Boolean field caveat" 節 (jq // 演算子 boolean caveat コメント) で文書化された
# jq `// $default` 演算子の boolean caveat を pin する。
# JSON `false` / `null` はいずれも jq の `//` 演算子で「falsy」とみなされ DEFAULT に置換される。
# これは jq の仕様: `false // "x"` → "x" (`null // "x"` も同様)。
# 現状の caller は全て非 boolean (phase / pr_number / loop_count 等) のため実害はないが、
# 将来 boolean field caller (例: `.active` を読む resume helper) を追加するときに
# caveat が test で守られていないと silent regression 化する。
# 重要: caveat は『boolean field を read してはいけない』ことを document しており、本 TC は
# その「false が default に置換される」性質を pin する (回帰時に test が落ちて caller 側で
# boolean read を追加すべきではないことを強制する)。
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

# --- TC-14.3: boolean caveat WARNING の存在を pin (verified-review cycle 44 F-06 MEDIUM) ---
# state-read.sh の `case "$DEFAULT" in true|false)` ブロックが emit する WARNING を pin する。
# 旧実装では caveat WARNING を mutate (`true|false)` を `DISABLED_*)` に置換) しても全 TC が pass する
# false-positive (mutation kill power 0) だった。defense-in-depth として導入された警告経路が pin されて
# おらず、将来の refactor で silent に削除されても気付けないリスクがあったため本 TC で pin する。
echo "TC-14.3: boolean caveat WARNING — --default true / false 指定時に stderr へ警告を emit する"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
write_config_v2 "$SBX"
SID="11111111-1111-1111-1111-111111111111"
write_session_id "$SBX" "$SID"
write_per_session "$SBX" "$SID" '{"active":true,"phase":"phase5_lint","next_action":"continue"}'

# stderr のみを capture して WARNING line を grep で検索する
boolean_warn_true_path=$(mktemp /tmp/rite-tc14-warn-true-XXXXXX)
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

boolean_warn_false_path=$(mktemp /tmp/rite-tc14-warn-false-XXXXXX)
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
boolean_warn_other_path=$(mktemp /tmp/rite-tc14-warn-other-XXXXXX)
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

# --- TC-15: reader-side cross-session guard (verified-review cycle 34 fix F-12 MEDIUM) ---
# state-read.sh の cross-session guard 経路を直接 pin する test case。cycle 33 で導入された
# 「per-session 不在 + legacy が **別 session_id** を持つ」ケースで、reader が DEFAULT に降格 +
# WORKFLOW_INCIDENT sentinel を emit する経路をカバーする。
#
# TC-2 (per-session 不在 + legacy 存在) は legacy file に session_id field を含めず
# `legacy_sid=""` 経路でのみ fall-through を検証していた。`[ -z "$legacy_sid" ] || [ "$legacy_sid" = "$SESSION_ID" ]`
# 比較を将来 (例: `!=` への typo / inverted condition) regress させても TC-2 は通る silent regression
# 経路があった。本 TC で `legacy_sid != current_sid` 経路を直接 pin することで mutation 耐性を強化する。
#
# 背景: writer 側の cross-session takeover refusal は flow-state-update.test.sh TC-AC-4-CROSS-SESSION-REFUSED で
# 既に pin されている。reader 側 (state-read.sh) も同等の test coverage を持つことで writer/reader
# 対称化を test レベルでも保証する。
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
stdout_path=$(mktemp /tmp/rite-tc15-stdout-XXXXXX)
stderr_path=$(mktemp /tmp/rite-tc15-stderr-XXXXXX)
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

# --- TC-15.B: reader-side same-session legacy fallback (legitimate take-over) ---
# 対比 case: legacy.session_id == current_sid なら take-over OK (TC-2 では sessionless legacy のみ
# 検証していたが、本 TC で「同じ session_id を持つ legacy」も accept されることを pin する。
# `[ -z "$legacy_sid" ] || [ "$legacy_sid" = "$SESSION_ID" ]` 条件のうち後半の OR 分岐の
# revert test coverage)。
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

# --- TC-15.C: reader-side legacy_state_corrupt sentinel emit (verified-review cycle 35 F-06 MEDIUM) ---
# 背景: cycle 35 review で `_resolve-cross-session-guard.sh` の `corrupt:*` 経路 (legacy_state_corrupt
# sentinel emit path) が新規 4 test file のいずれでも pin されていなかった。これにより F-01/F-02/F-03 の
# CRITICAL/HIGH バグが cycle 28-34 の review-fix loop で検出されず残存していた構造的盲点。本 TC は
# `corrupt:*` 分類経路全体を 3 重 assert で pin する (DEFAULT 返却 + sentinel emit + jq_rc 非ゼロ)。
echo "TC-15.C: reader-side legacy corrupt JSON → legacy_state_corrupt sentinel emit + DEFAULT 返却"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
write_config_v2 "$SBX"
SID="22222222-3333-4444-5555-666666666666"
write_session_id "$SBX" "$SID"
# per-session file 不在、legacy が corrupt JSON (truncated, size > 0)
printf '{"phase":"corrupt_payload' > "$SBX/.rite-flow-state"
stdout_path=$(mktemp /tmp/rite-tc15c-stdout-XXXXXX)
stderr_path=$(mktemp /tmp/rite-tc15c-stderr-XXXXXX)
(cd "$SBX" && bash "$HOOK" --field phase --default "DEFAULT_C") >"$stdout_path" 2>"$stderr_path"
result=$(cat "$stdout_path")
assert_eq "TC-15.C.1: corrupt legacy + per-session 不在 → DEFAULT 返却" "DEFAULT_C" "$result"
# stderr に legacy_state_corrupt sentinel が emit されることを確認 (F-01 fix revert test)
if grep -q "WORKFLOW_INCIDENT=1" "$stderr_path" \
    && grep -q "type=legacy_state_corrupt" "$stderr_path" \
    && grep -q "layer=reader" "$stderr_path"; then
  echo "  ✅ TC-15.C.2: legacy_state_corrupt sentinel emit (F-01/F-02 fix revert test)"
  PASS=$((PASS+1))
else
  echo "  ❌ TC-15.C.2: legacy_state_corrupt sentinel emit が確認できません"
  echo "     stderr:"
  sed 's/^/       /' "$stderr_path"
  FAIL=$((FAIL+1))
  FAILED_NAMES+=("TC-15.C.2: legacy_state_corrupt sentinel emit")
fi
# jq_rc が実 jq exit code (>= 1) を含むことを確認 (F-03 fix の revert test)
if grep -qE "jq_rc=[1-9]" "$stderr_path"; then
  echo "  ✅ TC-15.C.3: jq_rc が実 jq exit code (>= 1) を含む (F-03 fix revert test)"
  PASS=$((PASS+1))
else
  echo "  ❌ TC-15.C.3: jq_rc=0 または欠落 (F-03 fix が revert された可能性)"
  echo "     stderr (relevant lines):"
  grep "WORKFLOW_INCIDENT" "$stderr_path" | sed 's/^/       /'
  FAIL=$((FAIL+1))
  FAILED_NAMES+=("TC-15.C.3: jq_rc must be >= 1 for corrupt JSON")
fi
rm -f "$stdout_path" "$stderr_path"
rm -rf "$SBX"

# --- TC-15.D: invalid_uuid:* sentinel emit (verified-review cycle 36 F-06 + F-16 MEDIUM/LOW) ---
# 背景: cycle 36 F-16 で `_resolve-cross-session-guard.sh` の sentinel を `corrupt:1` から
# `invalid_uuid:1` に分離。caller (state-read.sh) は `invalid_uuid:*` arm を新設し、
# `legacy_state_corrupt` sentinel に `reason=invalid_uuid_format` を embed する。
# 本 TC は (a) helper が invalid_uuid:1 を返すこと、(b) state-read.sh が sentinel を emit する
# こと、(c) reason field が `invalid_uuid_format` を含むことを 3 重 assert で pin する。
# F-06 の F-10 corrupt:1 → invalid_uuid:1 sentinel pin として機能する。
echo "TC-15.D: reader-side legacy session_id failed UUID validation → invalid_uuid sentinel emit"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
write_config_v2 "$SBX"
SID="33333333-4444-5555-6666-777777777777"
write_session_id "$SBX" "$SID"
# legacy file は valid JSON だが session_id が UUID format に非準拠
write_legacy "$SBX" '{"phase":"some_phase","session_id":"not-a-valid-uuid"}'
stdout_path=$(mktemp /tmp/rite-tc15d-stdout-XXXXXX)
stderr_path=$(mktemp /tmp/rite-tc15d-stderr-XXXXXX)
(cd "$SBX" && bash "$HOOK" --field phase --default "DEFAULT_D") >"$stdout_path" 2>"$stderr_path"
result=$(cat "$stdout_path")
assert_eq "TC-15.D.1: invalid UUID legacy + per-session 不在 → DEFAULT 返却" "DEFAULT_D" "$result"
if grep -q "WORKFLOW_INCIDENT=1" "$stderr_path" \
    && grep -q "type=legacy_state_corrupt" "$stderr_path" \
    && grep -q "reason=invalid_uuid_format" "$stderr_path"; then
  echo "  ✅ TC-15.D.2: legacy_state_corrupt sentinel emit with reason=invalid_uuid_format (F-16 fix revert test)"
  PASS=$((PASS+1))
else
  echo "  ❌ TC-15.D.2: legacy_state_corrupt sentinel + invalid_uuid_format reason が確認できません"
  echo "     stderr:"
  sed 's/^/       /' "$stderr_path"
  FAIL=$((FAIL+1))
  FAILED_NAMES+=("TC-15.D.2: invalid_uuid sentinel emit")
fi
if grep -q "root_cause_hint=legacy_session_id_failed_uuid_validation" "$stderr_path"; then
  echo "  ✅ TC-15.D.3: root_cause_hint differentiates invalid_uuid from jq parse failure"
  PASS=$((PASS+1))
else
  echo "  ❌ TC-15.D.3: root_cause_hint=legacy_session_id_failed_uuid_validation が含まれません"
  FAIL=$((FAIL+1))
  FAILED_NAMES+=("TC-15.D.3: root_cause_hint distinguishes UUID validation from jq parse")
fi
rm -f "$stdout_path" "$stderr_path"
rm -rf "$SBX"

# --- TC-15.E: caller-side 2>/dev/null source-pin metatest (verified-review cycle 36 F-04 MEDIUM) ---
# 背景: cycle 36 review で TC-15.2 / TC-15.C.2 が caller-side single revert (`2>/dev/null` → `2>&1`)
# を fail しないこと (helper-side `cat $jq_err >&2` 削除と組み合わせた場合のみ test が落ちる) が指摘
# された。F-04 fix として、caller の redirection 形式を test 側で構造的に守る metatest を追加。
# state-read.sh の `_resolve-cross-session-guard.sh` 呼び出しが必ず `2>/dev/null` を含むことを
# grep で source-pin する。
echo 'TC-15.E: state-read.sh caller-side stderr redirection source-pin metatest (F-04 fix revert test)'
state_read_path="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")/state-read.sh"
# cycle 43 F-03 (HIGH) 対応: 旧 grep `_resolve-cross-session-guard\.sh.*2>/dev/null` は
# state-read.sh L136/L138 のコメント行 (`... so 2>/dev/null is safe.`) にマッチして
# false-positive で常に pass していた (test-reviewer Likelihood-Evidence: runtime_observation
# empirical grep で実証)。実装の redirection 全体を削除しても comment は残るため metatest
# 素通り。修正: (1) コメント行を `grep -v '^[[:space:]]*#'` で除外し、(2) 実 invocation line
# (`classification=$(bash ... _resolve-cross-session-guard.sh ... 2>...)`) を anchor で検査する。
state_read_caller=$(grep -v '^[[:space:]]*#' "$state_read_path" | grep -E 'classification=\$\(bash[^)]*_resolve-cross-session-guard\.sh[^)]*2>')
if [ -n "$state_read_caller" ]; then
  echo "  ✅ TC-15.E.1: state-read.sh caller line preserves stderr redirection (cycle 35 F-01 fix is preserved)"
  PASS=$((PASS+1))
else
  echo "  ❌ TC-15.E.1: state-read.sh の caller-side stderr redirection が消失 (cycle 35 F-01 fix が revert された可能性)"
  echo "     現状の caller line (コメント除外後):"
  grep -v '^[[:space:]]*#' "$state_read_path" | grep "_resolve-cross-session-guard.sh" | sed 's/^/       /'
  FAIL=$((FAIL+1))
  FAILED_NAMES+=("TC-15.E.1: state-read.sh caller-side stderr redirection source-pin")
fi

# --- TC-DEPLOY-REGRESSION: helper-missing fail-fast 経路 (verified-review cycle 41 CG-2) ---
# 背景: state-read.sh の冒頭 `for _helper in ...` 存在チェックループは、cycle 38 F-01/F-09 で
# Issue #687 同型の deploy regression (helper の chmod -x / 削除 / install 不整合) を構造的に
# 防ぐ目的で導入された。しかし test 不在の場合、将来 loop の typo / rename で silent 空 loop 化しても
# regression を検出できず、Issue #687 root cause structural defense が無音で消滅するリスクがある。
# 本 TC は 6 helper × chmod -x 経路を実発火させて、必ず exit 1 + ERROR with helper name が
# 出力されることを pin する (defense-in-depth の test 化)。
echo "TC-DEPLOY-REGRESSION: state-read.sh helper-missing fail-fast (cycle 41 CG-2)"
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

# 6 helpers checked by state-read.sh's upfront for-loop (semantic anchor: state-path-resolve guard +
# 5 private helpers). 並び順は state-read.sh の loop と完全一致させる (drift 検出を兼ねる)。
deploy_regression_helpers=(
  state-path-resolve.sh
  _resolve-session-id.sh
  _resolve-session-id-from-file.sh
  _resolve-schema-version.sh
  _resolve-cross-session-guard.sh
  _emit-cross-session-incident.sh
)

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
