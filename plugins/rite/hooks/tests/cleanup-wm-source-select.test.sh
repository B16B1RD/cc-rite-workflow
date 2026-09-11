#!/bin/bash
# cleanup-wm-source-select.test.sh
#
# cleanup/SKILL.md ステップ 3 の WM 採用元選定（存在検査 → 内容検査）を pin する。
# SKILL.md から選定ブロックを抽出して sandbox で実行し、stub / 実 WM / 両不在 /
# state_root≠cwd / resolver 失敗 の経路を検証する。
#
# - T-01 (AC-1): stub（進捗セクションなし）→ stub_fallback → comment 採用 + WARNING
# - T-02 (AC-2): 進捗セクションありの実 WM → local 採用（comment を呼ばない）
# - T-03 (AC-3): ローカル WM もコメントも無い → none
# - T-04: state_root ≠ cwd。MAIN 側 primary の絶対パスを採用し cwd 側を使わない
# - T-05: resolver 空/非ゼロ + コメントあり → WARNING 全文 → resolver_unresolved → comment
# - T-05b: resolver 空/非ゼロ + コメントなし → none（cwd の実 WM を local にしない）
# - T-06: resolver 成功・state_root 側 primary/legacy 不在・cwd に実 WM → comment

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLEANUP_MD="$SCRIPT_DIR/../../skills/cleanup/SKILL.md"
TEST_DIR=""
cleanup() { [ -n "$TEST_DIR" ] && rm -rf "$TEST_DIR"; return 0; }
trap cleanup EXIT
TEST_DIR="$(mktemp -d)" || exit 1
_canon="$(cd "$TEST_DIR" && pwd -P)" || exit 1
TEST_DIR="$_canon"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

PLUGIN_FIXTURE="$TEST_DIR/plugin"
mkdir -p "$PLUGIN_FIXTURE/hooks"
cat > "$PLUGIN_FIXTURE/hooks/state-path-resolve.sh" <<'EOF'
#!/bin/bash
# STUB_RESOLVER_FAIL=1 → 非ゼロ終了（stdout 空）
# STUB_STATE_ROOT が set されている → その値を出力。空なら非ゼロ
# 未 set → sandbox cwd（既存 T-01..T-03 が cwd 配置のまま通る）
if [ "${STUB_RESOLVER_FAIL:-0}" = 1 ]; then
  exit 1
fi
if [ "${STUB_STATE_ROOT+x}" = x ]; then
  printf '%s\n' "$STUB_STATE_ROOT"
  [ -n "$STUB_STATE_ROOT" ] && exit 0
  exit 1
fi
pwd -P
exit 0
EOF
chmod +x "$PLUGIN_FIXTURE/hooks/state-path-resolve.sh"

# 選定ブロック抽出: `# WM 採用元の選定` 〜 incomplete 抽出の直前まで
extract_select() {
  awk '/^# WM 採用元の選定/{f=1} f && /^# 未完了タスク抽出/{exit} f{print}' "$CLEANUP_MD" \
    | sed -e 's|{issue_number}|9999|g' -e 's|{owner}|o|g' -e 's|{repo}|r|g' \
          -e "s|{plugin_root}|$PLUGIN_FIXTURE|g"
}

SELECT="$TEST_DIR/select.sh"
extract_select > "$SELECT"
if [ ! -s "$SELECT" ] || ! grep -q 'WM_SOURCE=stub_fallback' "$SELECT"; then
  echo "FAIL: cleanup/SKILL.md から WM 採用元選定ブロックを抽出できません（契約消失）"
  echo "  抽出: $(wc -l < "$SELECT") 行"
  exit 1
fi
if ! grep -q 'state-path-resolve.sh' "$SELECT"; then
  echo "FAIL: 選定ブロックに state-path-resolve.sh が無い"
  exit 1
fi
if grep -qE '^_wm_local="\.rite/work-memory/' "$SELECT"; then
  echo "FAIL: cwd 相対の _wm_local 代入が残っている"
  exit 1
fi
# 静的 pin: 存在検査のみで採用しないこと（-f だけで local に倒さない）
if ! grep -q '進捗(サマリー)?' "$SELECT" && ! grep -q '進捗' "$SELECT"; then
  echo "FAIL: 内容検査（進捗セクション）が選定ブロックに無い"
  exit 1
fi
if ! grep -q 'WARNING:.*stub' "$SELECT"; then
  echo "FAIL: stub fallback 時の WARNING が無い（silent 切替禁止）"
  exit 1
fi
if ! grep -q 'WARNING: state-path-resolve.sh の解決に失敗（空/非ゼロ）。cwd には倒さず Issue コメント側へ fallback します' "$SELECT"; then
  echo "FAIL: resolver 失敗時の WARNING 全文が無い"
  exit 1
fi

# gh stub: コメント本文を返す / 空
FAKE_COMMENT=""
export PATH="$TEST_DIR/bin:$PATH"
mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/gh" <<'EOF'
#!/bin/bash
# only used for: gh api repos/.../comments --jq ...
if [ -n "${FAKE_COMMENT:-}" ]; then
  printf '%s' "$FAKE_COMMENT"
else
  printf ''
fi
exit 0
EOF
chmod +x "$TEST_DIR/bin/gh"

# $1=cwd  $2=FAKE_COMMENT  $3=STUB_STATE_ROOT (省略時は unset)  $4=STUB_RESOLVER_FAIL
run_select() {
  local cwd="$1" comment="${2:-}" root_set="${3-__UNSET__}" fail="${4:-0}"
  (
    cd "$cwd" || exit 1
    export FAKE_COMMENT="$comment"
    export STUB_RESOLVER_FAIL="$fail"
    if [ "$root_set" = "__UNSET__" ]; then
      unset STUB_STATE_ROOT
    else
      export STUB_STATE_ROOT="$root_set"
    fi
    bash "$SELECT" 2>&1
  )
}

echo "=== cleanup WM source select tests ==="

# T-01: stub only
echo "T-01: stub local WM -> stub_fallback + comment"
SB1="$TEST_DIR/sb1"
mkdir -p "$SB1/.rite-work-memory"
cat > "$SB1/.rite-work-memory/issue-9999.md" <<'EOF'
---
phase: init
issue_number: 9999
---
Local work memory auto-created by PostToolUse hook.
EOF
FAKE_COMMENT=$'📜 rite 作業メモリ\n\n### 進捗サマリー\n\n- [ ] real task from comment\n'
out=$(run_select "$SB1" "$FAKE_COMMENT")
if ! printf '%s' "$out" | grep -q 'WM_SOURCE=stub_fallback'; then
  fail "T-01: stub_fallback marker 不在 (出力: $out)"
elif ! printf '%s' "$out" | grep -qi 'WARNING:.*stub'; then
  fail "T-01: WARNING 不在 (出力: $out)"
elif ! printf '%s' "$out" | grep -q 'WM_SOURCE=comment'; then
  fail "T-01: comment fallback 不在 (出力: $out)"
else
  pass "T-01 (stub → WARNING + comment fallback)"
fi

# T-02: real local WM
echo "T-02: real local WM with progress section -> local"
SB2="$TEST_DIR/sb2"
mkdir -p "$SB2/.rite-work-memory"
cat > "$SB2/.rite-work-memory/issue-9999.md" <<'EOF'
---
phase: implement
---
### 進捗サマリー

| Step | Status |
|------|--------|
| 1    | done   |

- [ ] remaining local task
EOF
# comment があっても local を優先すべき
out=$(run_select "$SB2" $'📜 rite 作業メモリ\n### 進捗サマリー\n- [ ] should not win\n')
if ! printf '%s' "$out" | grep -q 'WM_SOURCE=local'; then
  fail "T-02: local 採用されない (出力: $out)"
elif printf '%s' "$out" | grep -q 'stub_fallback'; then
  fail "T-02: 実 WM を stub と誤判定 (出力: $out)"
elif printf '%s' "$out" | grep -q 'resolver_unresolved'; then
  fail "T-02: 成功経路に resolver_unresolved が混入 (出力: $out)"
else
  pass "T-02 (実 WM を local 採用)"
fi

# T-03: neither
echo "T-03: no local WM and no comment -> none"
SB3="$TEST_DIR/sb3"
mkdir -p "$SB3"
out=$(run_select "$SB3" "")
if ! printf '%s' "$out" | grep -q 'WM_SOURCE=none'; then
  fail "T-03: none に倒れていない (出力: $out)"
else
  pass "T-03 (両不在 → none)"
fi

# T-02b: v1 heading ### 進捗 also counts as real
echo "T-02b: v1 ### 進捗 heading counts as content"
SB2b="$TEST_DIR/sb2b"
mkdir -p "$SB2b/.rite-work-memory"
cat > "$SB2b/.rite-work-memory/issue-9999.md" <<'EOF'
### 進捗

- [x] old step
EOF
out=$(run_select "$SB2b" "")
if ! printf '%s' "$out" | grep -q 'WM_SOURCE=local'; then
  fail "T-02b: v1 進捗見出しが local にならない (出力: $out)"
else
  pass "T-02b (v1 ### 進捗 も内容ありと判定)"
fi

# T-04: state_root ≠ cwd。MAIN primary の絶対パスを採用
echo "T-04: state_root != cwd adopts MAIN primary absolute path"
T04_MAIN="$TEST_DIR/t04_main"
T04_CWD="$TEST_DIR/t04_cwd"
mkdir -p "$T04_MAIN/.rite/work-memory" "$T04_CWD/.rite/work-memory"
cat > "$T04_MAIN/.rite/work-memory/issue-9999.md" <<'EOF'
### 進捗サマリー

- [ ] main sot task
EOF
cat > "$T04_CWD/.rite/work-memory/issue-9999.md" <<'EOF'
### 進捗サマリー

- [ ] cwd should not win
EOF
T04_MAIN="$(cd "$T04_MAIN" && pwd -P)"
T04_CWD="$(cd "$T04_CWD" && pwd -P)"
T04_EXPECT="$T04_MAIN/.rite/work-memory/issue-9999.md"
T04_CWD_PATH="$T04_CWD/.rite/work-memory/issue-9999.md"
out=$(run_select "$T04_CWD" $'📜 rite 作業メモリ\n### 進捗サマリー\n- [ ] comment should not win\n' "$T04_MAIN")
if ! printf '%s' "$out" | grep -q 'WM_SOURCE=local'; then
  fail "T-04: local 採用されない (出力: $out)"
elif ! printf '%s' "$out" | grep -qF "path=$T04_EXPECT"; then
  fail "T-04: 採用 path が MAIN 絶対パスと一致しない (期待: $T04_EXPECT / 出力: $out)"
elif printf '%s' "$out" | grep -F "path=$T04_CWD_PATH"; then
  fail "T-04: cwd 側 path を採用している (出力: $out)"
elif printf '%s' "$out" | grep -q 'path=\.rite/work-memory/'; then
  fail "T-04: cwd 相対 path を採用している (出力: $out)"
elif printf '%s' "$out" | grep -q 'resolver_unresolved'; then
  fail "T-04: 成功経路に resolver_unresolved が混入 (出力: $out)"
else
  pass "T-04 (MAIN 絶対パス採用、cwd 非採用)"
fi

# T-05: resolver fail + comment
echo "T-05: resolver fail + comment -> WARNING then resolver_unresolved then comment"
T05="$TEST_DIR/t05"
mkdir -p "$T05/.rite/work-memory"
cat > "$T05/.rite/work-memory/issue-9999.md" <<'EOF'
### 進捗サマリー

- [ ] cwd real wm must not win
EOF
T05_WARN='WARNING: state-path-resolve.sh の解決に失敗（空/非ゼロ）。cwd には倒さず Issue コメント側へ fallback します'
out=$(run_select "$T05" $'📜 rite 作業メモリ\n### 進捗サマリー\n- [ ] comment wins\n' "" 1)
# 順序: WARNING 全文 → resolver_unresolved → 最終 comment
_order=$(printf '%s\n' "$out" | grep -n -E "state-path-resolve.sh の解決に失敗|WM_SOURCE=resolver_unresolved|WM_SOURCE=comment|WM_SOURCE=local" || true)
_n_warn=$(printf '%s\n' "$out" | grep -n -F "$T05_WARN" | head -1 | cut -d: -f1)
_n_mid=$(printf '%s\n' "$out" | grep -n 'WM_SOURCE=resolver_unresolved' | head -1 | cut -d: -f1)
_n_final=$(printf '%s\n' "$out" | grep -n 'WM_SOURCE=comment' | head -1 | cut -d: -f1)
if ! printf '%s' "$out" | grep -F -q "$T05_WARN"; then
  fail "T-05: WARNING 全文が無い (出力: $out)"
elif [ -z "$_n_mid" ]; then
  fail "T-05: resolver_unresolved 不在 (出力: $out)"
elif [ -z "$_n_final" ]; then
  fail "T-05: 最終 comment 不在 (出力: $out)"
elif ! [ "$_n_warn" -lt "$_n_mid" ] || ! [ "$_n_mid" -lt "$_n_final" ]; then
  fail "T-05: 順序が WARNING → resolver_unresolved → comment ではない (lines: $_n_warn/$_n_mid/$_n_final / 出力: $out)"
elif printf '%s' "$out" | grep -q 'WM_SOURCE=local'; then
  fail "T-05: cwd の local を採用している (出力: $out)"
else
  pass "T-05 (resolver 失敗 → WARNING → unresolved → comment、cwd local 不採用)"
fi

# T-05b: resolver fail + no comment → none (cwd 実 WM を local にしない)
echo "T-05b: resolver fail + no comment -> none (cwd WM ignored)"
T05b="$TEST_DIR/t05b"
mkdir -p "$T05b/.rite/work-memory"
cat > "$T05b/.rite/work-memory/issue-9999.md" <<'EOF'
### 進捗サマリー

- [ ] cwd real wm must not win
EOF
out=$(run_select "$T05b" "" "" 1)
if ! printf '%s' "$out" | grep -q 'WM_SOURCE=resolver_unresolved'; then
  fail "T-05b: resolver_unresolved 不在 (出力: $out)"
elif ! printf '%s' "$out" | grep -q 'WM_SOURCE=none'; then
  fail "T-05b: none に倒れていない (出力: $out)"
elif printf '%s' "$out" | grep -q 'WM_SOURCE=local'; then
  fail "T-05b: cwd の local を採用している (出力: $out)"
elif printf '%s' "$out" | grep -q 'WM_SOURCE=comment'; then
  fail "T-05b: コメント無しなのに comment になった (出力: $out)"
else
  pass "T-05b (resolver 失敗 + コメントなし → none、cwd local 不採用)"
fi

# T-06: resolver 成功、state_root 側 primary/legacy 不在、cwd に実 WM、コメントあり
echo "T-06: resolver ok, state_root empty, cwd has real WM -> comment"
T06_ROOT="$TEST_DIR/t06_root"
T06_CWD="$TEST_DIR/t06_cwd"
mkdir -p "$T06_ROOT" "$T06_CWD/.rite/work-memory"
cat > "$T06_CWD/.rite/work-memory/issue-9999.md" <<'EOF'
### 進捗サマリー

- [ ] cwd real wm must not win when state_root has none
EOF
T06_ROOT="$(cd "$T06_ROOT" && pwd -P)"
T06_CWD="$(cd "$T06_CWD" && pwd -P)"
T06_CWD_PATH="$T06_CWD/.rite/work-memory/issue-9999.md"
out=$(run_select "$T06_CWD" $'📜 rite 作業メモリ\n### 進捗サマリー\n- [ ] comment wins when root empty\n' "$T06_ROOT")
if printf '%s' "$out" | grep -q 'WM_SOURCE=local'; then
  fail "T-06: cwd の local を採用している (出力: $out)"
elif printf '%s' "$out" | grep -F "path=$T06_CWD_PATH"; then
  fail "T-06: cwd path を採用している (出力: $out)"
elif ! printf '%s' "$out" | grep -q 'WM_SOURCE=comment'; then
  fail "T-06: 最終 comment にならない (出力: $out)"
elif printf '%s' "$out" | grep -q 'resolver_unresolved'; then
  fail "T-06: 成功経路に resolver_unresolved が混入 (出力: $out)"
else
  pass "T-06 (state_root 空・cwd 実 WM → comment、local 不採用)"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
