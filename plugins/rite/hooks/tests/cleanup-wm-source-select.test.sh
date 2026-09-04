#!/bin/bash
# cleanup-wm-source-select.test.sh
#
# cleanup/SKILL.md ステップ 3 の WM 採用元選定（存在検査 → 内容検査）を pin する。
# SKILL.md から選定ブロックを抽出して sandbox で実行し、stub / 実 WM / 両不在の 3 経路を検証する。
#
# - T-01 (AC-1): stub（進捗セクションなし）→ stub_fallback → comment 採用 + WARNING
# - T-02 (AC-2): 進捗セクションありの実 WM → local 採用（comment を呼ばない）
# - T-03 (AC-3): ローカル WM もコメントも無い → none

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

# 選定ブロック抽出: `# WM 採用元の選定` 〜 incomplete 抽出の直前まで
extract_select() {
  awk '/^# WM 採用元の選定/{f=1} f && /^# 未完了タスク抽出/{exit} f{print}' "$CLEANUP_MD" \
    | sed -e 's|{issue_number}|9999|g' -e 's|{owner}|o|g' -e 's|{repo}|r|g'
}

SELECT="$TEST_DIR/select.sh"
extract_select > "$SELECT"
if [ ! -s "$SELECT" ] || ! grep -q 'WM_SOURCE=stub_fallback' "$SELECT"; then
  echo "FAIL: cleanup/SKILL.md から WM 採用元選定ブロックを抽出できません（契約消失）"
  echo "  抽出: $(wc -l < "$SELECT") 行"
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

run_select() {
  ( cd "$1" && FAKE_COMMENT="${2:-}" bash "$SELECT" 2>&1 )
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

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
