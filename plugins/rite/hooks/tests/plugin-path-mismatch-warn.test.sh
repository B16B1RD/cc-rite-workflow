#!/bin/bash
# plugin-path-mismatch-warn.test.sh
#
# setup/SKILL.md 4.5.0 の hooks dir 検出 block を SKILL.md から literal 抽出して実行し、
# plugin パス解決方式間 (direct key lookup vs 正準 one-liner) のバージョン不一致検出を pin する。
# 抽出実行方式の理由は base-update-classify.test.sh と同じ (コピーは SKILL.md との drift を生む)。
#
# 背景: installed_plugins.json に複数の rite@* エントリがあると 2 方式が異なる
# バージョンのパスを返し、1 セッション内で hooks と skills が別バージョンを参照する混在が
# silent に進行した。4.5.0 に照合 WARNING を追加し、本テストがその発火条件を pin する。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_MD="$SCRIPT_DIR/../../skills/setup/SKILL.md"
TEST_DIR="$(mktemp -d)" || { echo "FATAL: mktemp 失敗"; exit 1; }
PASS=0
FAIL=0

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

# --- SKILL.md から 4.5.0 の bash block を抽出 ---
SNIPPET="$TEST_DIR/resolve.sh"
awk '/^### 4\.5\.0 Resolve Hook Script Directory/{sect=1}
     sect && /^```bash$/{fence=1; next}
     sect && fence && /^```$/{exit}
     sect && fence {print}' "$SKILL_MD" > "$SNIPPET"
if ! grep -q 'MARKETPLACE:' "$SNIPPET" || ! grep -q 'CANON_PATH' "$SNIPPET"; then
  echo "FAIL: SKILL.md からの 4.5.0 block 抽出に失敗しました (アンカーまたは照合ロジックが変更された可能性)"
  echo "  抽出結果: $(wc -l < "$SNIPPET") 行"
  exit 1
fi

# --- sandbox: fake HOME + fake install paths ---
FAKE_HOME="$TEST_DIR/home"
mkdir -p "$FAKE_HOME/.claude/plugins"
INSTALL_A="$TEST_DIR/cache/rite/0.8.0"
INSTALL_B="$TEST_DIR/cache/rite/0.8.1"
mkdir -p "$INSTALL_A/hooks" "$INSTALL_B/hooks"
touch "$INSTALL_A/hooks/pre-compact.sh" "$INSTALL_B/hooks/pre-compact.sh"

# 実行 cwd は plugins/rite が存在しないディレクトリ (LOCAL 分岐を通らない)
RUN_DIR="$TEST_DIR/proj"
mkdir -p "$RUN_DIR"

run_snippet() {
  ( cd "$RUN_DIR" && HOME="$FAKE_HOME" bash "$SNIPPET" 2>"$TEST_DIR/err" )
}

echo "=== plugin-path mismatch warn tests (SKILL.md 4.5.0 抽出実行) ==="
echo ""

# ─── TC-1 (T-01/AC-1): 方式間不一致 → WARNING あり + 両パス表示、解決結果は direct key ───
echo "TC-1: mismatch (rite@alpha 0.8.0 first, rite@rite-marketplace 0.8.1) -> WARNING"
cat > "$FAKE_HOME/.claude/plugins/installed_plugins.json" <<JSON
{
  "plugins": {
    "rite@alpha-marketplace": [{"installPath": "$INSTALL_A"}],
    "rite@rite-marketplace": [{"installPath": "$INSTALL_B"}]
  }
}
JSON
out=$(run_snippet)
err=$(cat "$TEST_DIR/err")
if printf '%s' "$err" | grep -q '解決方式間で不一致' && \
   printf '%s' "$err" | grep -qF "$INSTALL_A" && \
   printf '%s' "$err" | grep -qF "$INSTALL_B" && \
   [ "$out" = "MARKETPLACE:$INSTALL_B/hooks" ]; then
  pass "TC-1: WARNING (両パス表示) + 解決は direct key 維持"
else
  fail "TC-1: expected WARNING with both paths + MARKETPLACE:$INSTALL_B/hooks, got out='$out' err_has_warn=$(printf '%s' "$err" | grep -c '不一致' || true)"
fi

# ─── TC-2 (T-02/AC-2): 一致 → WARNING なし ───
echo "TC-2: single entry (agree) -> no WARNING"
cat > "$FAKE_HOME/.claude/plugins/installed_plugins.json" <<JSON
{
  "plugins": {
    "rite@rite-marketplace": [{"installPath": "$INSTALL_B"}]
  }
}
JSON
out=$(run_snippet)
err=$(cat "$TEST_DIR/err")
if ! printf '%s' "$err" | grep -q '不一致' && [ "$out" = "MARKETPLACE:$INSTALL_B/hooks" ]; then
  pass "TC-2: WARNING なし + 従来どおり解決"
else
  fail "TC-2: expected no WARNING + MARKETPLACE, got out='$out' err='$err'"
fi

# ─── TC-3 (T-03/AC-3): installed_plugins.json 不在 → 従来どおり NOT_FOUND、警告なし ───
echo "TC-3: no installed_plugins.json -> NOT_FOUND:NO_HOOKS, no WARNING"
rm -f "$FAKE_HOME/.claude/plugins/installed_plugins.json"
out=$(run_snippet)
err=$(cat "$TEST_DIR/err")
if [ "$out" = "NOT_FOUND:NO_HOOKS" ] && [ -z "$err" ]; then
  pass "TC-3: 従来どおり NOT_FOUND (警告なし)"
else
  fail "TC-3: expected NOT_FOUND:NO_HOOKS silent, got out='$out' err='$err'"
fi

# ─── TC-4 (T-03/AC-3): ローカル開発 (plugins/rite あり) → LOCAL 解決、照合は走らない ───
echo "TC-4: local dev -> LOCAL resolution, no probe"
mkdir -p "$RUN_DIR/plugins/rite/hooks"
touch "$RUN_DIR/plugins/rite/hooks/pre-compact.sh"
out=$(run_snippet)
err=$(cat "$TEST_DIR/err")
if [ "$out" = "LOCAL:$RUN_DIR/plugins/rite/hooks" ] && [ -z "$err" ]; then
  pass "TC-4: LOCAL 解決 (警告なし)"
else
  fail "TC-4: expected LOCAL:$RUN_DIR/plugins/rite/hooks silent, got out='$out' err='$err'"
fi
rm -rf "$RUN_DIR/plugins"

# ─── TC-5: direct key 不在 (rite@* 別キーのみ) → WARNING なしで従来どおり NOT_FOUND ───
echo "TC-5: direct key absent -> no spurious WARNING, NOT_FOUND"
cat > "$FAKE_HOME/.claude/plugins/installed_plugins.json" <<JSON
{
  "plugins": {
    "rite@alpha-marketplace": [{"installPath": "$INSTALL_A"}]
  }
}
JSON
out=$(run_snippet)
err=$(cat "$TEST_DIR/err")
if [ "$out" = "NOT_FOUND:NO_HOOKS" ] && ! printf '%s' "$err" | grep -q '不一致'; then
  pass "TC-5: INSTALL_PATH 空のため照合せず従来どおり NOT_FOUND"
else
  fail "TC-5: expected NOT_FOUND:NO_HOOKS without WARNING, got out='$out' err='$err'"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -gt 0 ] && exit 1
exit 0
