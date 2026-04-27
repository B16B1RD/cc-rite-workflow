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
#     TC-2-no-sid を追加して resume.md Phase 3.0.1 trailing prose の sid 無し legacy fallback 経路
#     (state-read.sh fallbacks legacy when per-session is absent under schema_version=2) も pin
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
  return 0  # Form B (portability variant) → return 0 必須 (bash-trap-patterns.md "cleanup 関数の契約" 節 Form B 参照)
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
# helper が skip メッセージを stderr に出すことを確認
# (resume.md Phase 3.0.1 の `if ! bash {plugin_root}/hooks/resume-active-flag-restore.sh` guard が実際に発火)
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
echo "TC-2-no-sid: schema_v=1 + legacy file 存在 + sid 無し → patch (--session なし) 成功経路 (resume-active-flag-restore.sh の patch_args 配列内 sid 有無分岐)"
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
echo "TC-3: phase が空文字列 → helper skip (resume.md Phase 3.0.1 trailing prose の canonical enumeration の path 3 \"phase is an empty string\")"
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

# --- TC-mktemp-fail: mktemp 失敗経路で helper が exit 0 を保持する (cycle 24 F-01 CRITICAL regression guard) ---
# cycle 22 で追加した signal-specific trap が `_rite_resume_active_cleanup` 関数を直接 trap 登録していたため、
# `_err=""` (mktemp 失敗 fallback) 時に cleanup function の `[ -n "" ] && rm -f` が `&&` short-circuit
# で return 1 を返し、`set -euo pipefail` 下で EXIT trap return code が script exit 0 を上書き → helper
# exit 1 で resume が hard-abort する silent regression があった (patch 自体は成功しているのに)。
# cycle 24 で cleanup 関数末尾に `return 0` を追加して関数自体が非 0 を返さないよう保証することで、
# `set -euo pipefail` 下で cleanup の rc が script exit code を上書きする経路を遮断するよう修正
# (rc=$? 退避は wiki-query-inject.sh の trap pattern との表記統一であり defense-in-depth として機能しない —
# 詳細は resume-active-flag-restore.sh の cycle 24 fix コメント参照)。本 TC は PATH 経由で fake mktemp を
# 注入し、mktemp が常に失敗する状況下で helper が exit 0 を返すことを pin する。
echo "TC-mktemp-fail: mktemp 失敗時に helper が exit 0 を保持する (cycle 24 F-01 CRITICAL regression guard)"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
write_legacy "$SBX" '{"phase":"phase5_lint","next_action":"continue","active":false}'
# fake mktemp directory を sandbox 内に作成 (test isolation 保証)
# 重要: helper 専用 pattern (rite-resume-flow-err-) のみ fail させ、flow-state-update.sh の内部 mktemp
# 呼び出し (rite-flow-state-* 等) は real mktemp に passthrough させる。aggressive fake は
# flow-state-update.sh 自身を fail させて legitimate な exit 1 を引き起こすため、F-01 (helper 自身の
# trap regression) を isolate できない。
#
# PR #688 followup F-05 LOW (mktemp coupling sanity check): fake mktemp の case pattern と
# helper の mktemp template が一致していることを test 開始前に grep で検証する。helper 側で
# template name が変更された場合、fake mktemp が常に passthrough して TC-mktemp-fail が
# silent passthrough する regression (mktemp 失敗を simulate せず常に成功扱い → cycle 22 trap regression
# を再導入しても気付けない silent regression) を防ぐ。
if ! grep -qF 'rite-resume-flow-err-XXXXXX' "$HELPER"; then
  echo "FAIL (TC-mktemp-fail sanity check): helper does not use 'rite-resume-flow-err-XXXXXX' template (literal string match required)" >&2
  echo "  対処: helper の mktemp template name (helper:163 周辺) と本 test の case pattern を同期させてください" >&2
  echo "  影響: fake mktemp が silent passthrough して mktemp 失敗 simulate が無効化される" >&2
  echo "  Note: substring grep ('rite-resume-flow-err-') を fixed-string XXXXXX 一致に強化 (false negative 防止)" >&2
  exit 1
fi
fake_bin="$SBX/.fake-bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/mktemp" <<'FAKE_MKTEMP'
#!/bin/bash
# Selective fake: helper 専用 pattern のみ fail、それ以外は real mktemp に passthrough
case "$*" in
  *rite-resume-flow-err-XXXXXX*)
    echo "fake mktemp: simulated failure for helper's _err tempfile" >&2
    exit 1
    ;;
  *)
    # Find real mktemp by searching common paths (PATH の先頭に self が居るため $PATH 検索は循環する)
    for p in /usr/bin/mktemp /bin/mktemp /usr/local/bin/mktemp; do
      if [ -x "$p" ]; then
        exec "$p" "$@"
      fi
    done
    echo "fake mktemp: real mktemp not found in standard paths" >&2
    exit 1
    ;;
esac
FAKE_MKTEMP
chmod +x "$fake_bin/mktemp"

helper_err=$(mktemp /tmp/rite-resume-mktemp-fail-err-XXXXXX)
if (cd "$SBX" && PATH="$fake_bin:$PATH" bash "$HELPER" "$PLUGIN_ROOT" 2>"$helper_err"); then
  helper_rc=0
else
  helper_rc=$?
fi
if [ "$helper_rc" -ne 0 ]; then
  echo "  helper_err (cycle 22 trap regression が再発した可能性):" >&2
  head -10 "$helper_err" | sed 's/^/    /' >&2
fi
rm -f "$helper_err"
assert_eq "TC-mktemp-fail.1: helper exit 0 (mktemp 失敗時も EXIT trap が exit code を保持)" "0" "$helper_rc"
# mktemp 失敗でも patch 自体は実行され active=true に書き戻されることを確認
final_active=$(jq -c '.active' "$SBX/.rite-flow-state" 2>/dev/null)
assert_eq "TC-mktemp-fail.2: legacy file の active が true (mktemp 失敗でも patch は成功)" "true" "$final_active"

# --- Summary ---
# --------------------------------------------------------------------------
# TC-AC-4-RESUME-FALLBACK-SAME-SESSION (PR #688 cycle 32 F-06):
#
# resume helper の AC-4 reproduction scenario (helper 経由の E2E pin) を追加。
# Setup: schema_v=2 + valid sid + per-session 不在 + legacy が **同 session** の遺物
# 期待挙動: helper が legacy fallback path を経由して active=true を legacy に書き戻す
# (cycle 32 fix で fallback は same-session のときのみ発火する)
# --------------------------------------------------------------------------
echo "TC-AC-4-RESUME-FALLBACK-SAME-SESSION (cycle 32 F-06): helper restores active=true via legacy fallback for same-session legacy"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
write_config_v2 "$SBX"
CURR_SID="55555555-5555-5555-5555-555555555555"
write_session_id "$SBX" "$CURR_SID"
# legacy = same session, active=false, OLD phase (F-05 fix と同じ phase 分離 pattern)
write_legacy "$SBX" "{\"schema_version\":2,\"active\":false,\"issue_number\":42,\"branch\":\"feat/foo\",\"phase\":\"phase4_pre_resume\",\"next_action\":\"old next\",\"session_id\":\"$CURR_SID\",\"error_count\":0}"
# per-session は作らない (precondition)

stderr_file=$(mktemp /tmp/rite-resume-tc-ac4-same-stderr-XXXXXX)
if run_helper "$SBX" "$stderr_file"; then
  rc=0
else
  rc=$?
fi
assert_eq "TC-AC-4-RESUME-FALLBACK-SAME-SESSION: helper exit 0" "0" "$rc"

# Verify legacy was actually updated (helper 経由の E2E)
legacy_active=$(jq -r '.active' "$SBX/.rite-flow-state")
legacy_phase=$(jq -r '.phase' "$SBX/.rite-flow-state")
assert_eq "TC-AC-4-RESUME-FALLBACK-SAME-SESSION: legacy active flipped to true via helper" "true" "$legacy_active"
# phase は state-read.sh が読んだ legacy.phase (phase4_pre_resume) で書き戻されるため、
# 旧値のまま残るのが期待挙動 (helper は phase を変更せず active のみ復元する)
assert_eq "TC-AC-4-RESUME-FALLBACK-SAME-SESSION: legacy phase preserved (helper is phase-preserving)" "phase4_pre_resume" "$legacy_phase"
rm -f "$stderr_file"

# --------------------------------------------------------------------------
# TC-AC-4-RESUME-FALLBACK-CROSS-SESSION-REFUSED (PR #688 cycle 32 F-06):
#
# Cross-session legacy のとき helper が **silent corruption を起こさない** ことを E2E pin。
# Setup: schema_v=2 + valid sid (CURR) + per-session 不在 + legacy が **別 session** の遺物
# 期待挙動: helper が flow-state-update.sh の cross-session refuse 経路に流れ、
#          patch は --if-exists silent skip → exit 0、legacy は完全未変更、
#          stderr に WORKFLOW_INCIDENT 含む warning
# --------------------------------------------------------------------------
echo "TC-AC-4-RESUME-FALLBACK-CROSS-SESSION-REFUSED (cycle 32 F-01): helper preserves legacy when cross-session"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
write_config_v2 "$SBX"
CURR_SID="66666666-6666-6666-6666-666666666666"
OTHER_SID="77777777-7777-7777-7777-777777777777"
write_session_id "$SBX" "$CURR_SID"
# legacy = OTHER session's residue (different session_id)
write_legacy "$SBX" "{\"schema_version\":2,\"active\":false,\"issue_number\":999,\"branch\":\"fix/other\",\"phase\":\"phase_other\",\"session_id\":\"$OTHER_SID\",\"error_count\":3}"
# per-session for CURR_SID は作らない

stderr_file=$(mktemp /tmp/rite-resume-tc-ac4-cross-stderr-XXXXXX)
if run_helper "$SBX" "$stderr_file"; then
  rc=0
else
  rc=$?
fi
# helper itself returns exit 0 (patch --if-exists silent skips on cross-session per-session-absent path)
assert_eq "TC-AC-4-RESUME-FALLBACK-CROSS-SESSION-REFUSED: helper exit 0" "0" "$rc"

# CRITICAL invariant: legacy file must be UNCHANGED (cross-session corruption refused)
legacy_active=$(jq -r '.active' "$SBX/.rite-flow-state")
legacy_sid=$(jq -r '.session_id' "$SBX/.rite-flow-state")
legacy_issue=$(jq -r '.issue_number' "$SBX/.rite-flow-state")
legacy_branch=$(jq -r '.branch' "$SBX/.rite-flow-state")
assert_eq "TC-AC-4-RESUME-FALLBACK-CROSS-SESSION-REFUSED: legacy active unchanged" "false" "$legacy_active"
assert_eq "TC-AC-4-RESUME-FALLBACK-CROSS-SESSION-REFUSED: legacy session_id preserved (no cross-session takeover)" "$OTHER_SID" "$legacy_sid"
assert_eq "TC-AC-4-RESUME-FALLBACK-CROSS-SESSION-REFUSED: legacy issue_number preserved (no metadata corruption)" "999" "$legacy_issue"
assert_eq "TC-AC-4-RESUME-FALLBACK-CROSS-SESSION-REFUSED: legacy branch preserved" "fix/other" "$legacy_branch"

# Verify WORKFLOW_INCIDENT sentinel in stderr (observability)
stderr_content=$(cat "$stderr_file")
assert_contains "TC-AC-4-RESUME-FALLBACK-CROSS-SESSION-REFUSED: WORKFLOW_INCIDENT sentinel emitted (observability)" \
  "cross_session_takeover_refused" "$stderr_content"
rm -f "$stderr_file"

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
