#!/bin/bash
# wiki-index-update.test.sh
#
# Tests for wiki-index-update.sh (wiki-ingest SKILL.md ステップ 6 delegation
# target, Issue #2089). The helper applies the #2047-fixed index.md spec
# (identification predicate / escaping / duplicate reclamation / stats sync)
# deterministically; these fixtures pin the behavior the prose era established,
# including the edge cases PR #2052's review loop surfaced (raw-pipe title,
# blank lines inside the section, old-format coexistence, duplicate rows).
#
# Coverage (IDs map to Issue #2089 Section 6 Test Specification):
#   TC-1  (T-01) 新規行追加 parity: 行形式・テーブル末尾追加・統計同期
#   TC-2  (T-01) 既存行更新 parity: description ありで行全体を再生成
#   TC-3  (T-01) 既存行更新: description 空 → 既存サマリー保持 (空上書き禁止)
#   TC-4  (T-02) 生パイプ title の既存行を first-link 述語で同定し 5 列へ是正
#   TC-5  (T-02) エスケープ規約 (a): `\` → `\\` の後 `|` → `\|` (title/description)
#   TC-6  (T-02) エスケープ規約 (b): 保持サマリーの `\|` を再エスケープしない
#         (2 サイクル回して `\` が増殖しないことを固定)
#   TC-7  (T-03) 節内の `|` 行間の空行を除去 (節境界の空行は保持)
#   TC-8  (T-03) 旧形式箇条書き行の共存維持: 述語対象外・新規追加扱い・無改変
#   TC-9  (T-03) 重複行回収: 対象外ページの後発行も 3a が削除 (先発保持)
#   TC-10 (T-03) 対象ページ重複 → aborted_duplicate (中止) + 3a が後発を回収
#   TC-11 (T-03) `## 統計` 節不在 → stats_sync=skipped_no_section (節を新設しない)
#   TC-12 (T-03) `## ページ一覧` 節不在 → `## 統計` の直前に template 形で新設
#   TC-13 (T-04) index.md 不在 → exit 1 (fail-loud)
#   TC-14 (T-04) `## ページ一覧` 見出し重複 (想定外構造) → exit 1 + 無変更
#   TC-15 (T-04) invocation error: domain/confidence enum 違反・`|` 入り updated・
#         必須引数欠落 → exit 2 + 無変更
#   TC-16 (T-04) pages 一覧 0 件 → stats_sync=skipped_unreadable + 統計値は既存保持
#         (行操作自体は適用される — silent ではなく WARNING 付きの部分スキップ)
#   TC-17 (T-06) SKILL.md ステップ 6 の縮退: helper 呼び出しが存在し、操作
#         アルゴリズムの散文 (同定・抽出・削除手順の記述) が残っていない
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
SCRIPT="$PLUGIN_ROOT/hooks/scripts/wiki-index-update.sh"
INGEST_MD="$PLUGIN_ROOT/skills/wiki-ingest/SKILL.md"

if [ ! -x "$SCRIPT" ]; then
  echo "ERROR: helper not executable: $SCRIPT" >&2
  exit 1
fi

TEST_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ FAIL: $1"; }

# 基本フィクスチャ: 5 列テーブル + 統計節。pages/ には patterns 1 / heuristics 1
make_sandbox() {
  local name="$1"
  local dir="$TEST_DIR/$name"
  mkdir -p "$dir/pages/patterns" "$dir/pages/heuristics" "$dir/pages/anti-patterns"
  touch "$dir/pages/patterns/foo.md" "$dir/pages/heuristics/bar.md"
  cat > "$dir/index.md" <<'EOF'
# Wiki Index

カタログ本文。

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
| [Foo Pattern](pages/patterns/foo.md) | patterns | 既存サマリー | 2026-01-01T00:00:00+09:00 | high |

## 統計

- 総ページ数: 1
- ドメイン別: patterns=1, heuristics=0, anti-patterns=0
- 最終更新: 2026-01-01T00:00:00+09:00
EOF
  printf '%s' "$dir"
}

run_helper() {
  HELPER_STDOUT=$("$SCRIPT" "$@" 2>"$TEST_DIR/stderr.txt")
  HELPER_RC=$?
  HELPER_STDERR=$(cat "$TEST_DIR/stderr.txt")
}

# ──────────────────────────────────────────────────────────────────────
# TC-1 (T-01): 新規行追加 parity
# ──────────────────────────────────────────────────────────────────────
dir=$(make_sandbox tc1)
run_helper --index "$dir/index.md" --title "Bar Heuristic" --domain heuristics \
  --slug bar --description "bar の説明" --updated "2026-08-04T22:00:00+09:00" \
  --confidence medium --pages-root "$dir/pages"
expected_row='| [Bar Heuristic](pages/heuristics/bar.md) | heuristics | bar の説明 | 2026-08-04T22:00:00+09:00 | medium |'
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'row_action=added' \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'stats_sync=synced' \
   && printf '%s\n' "$HELPER_STDOUT" | grep -q '^\[CONTEXT\] WIKI_INDEX_UPDATE=row_action=added; dedup_removed=0; stats_sync=synced$' \
   && grep -qxF "$expected_row" "$dir/index.md" \
   && grep -qx -- '- 総ページ数: 2' "$dir/index.md" \
   && grep -qx -- '- ドメイン別: patterns=1, heuristics=1, anti-patterns=0' "$dir/index.md" \
   && grep -qx -- '- 最終更新: 2026-08-04T22:00:00+09:00' "$dir/index.md"; then
  # 追加位置 = テーブル末尾 (既存 Foo 行の後)
  if awk '/foo\.md/{f=NR} /bar\.md/{b=NR} END{exit !(f && b && b>f)}' "$dir/index.md"; then
    pass "TC-1 新規行追加 (行形式・末尾追加・統計同期)"
  else
    fail "TC-1 追加位置がテーブル末尾でない"
  fi
else
  fail "TC-1 (rc=$HELPER_RC stdout=$HELPER_STDOUT)"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-2 (T-01): 既存行更新 (description あり → 行全体再生成)
# ──────────────────────────────────────────────────────────────────────
dir=$(make_sandbox tc2)
run_helper --index "$dir/index.md" --title "Foo Pattern v2" --domain patterns \
  --slug foo --description "新サマリー" --updated "2026-08-05T00:00:00+09:00" \
  --confidence low --pages-root "$dir/pages"
expected_row='| [Foo Pattern v2](pages/patterns/foo.md) | patterns | 新サマリー | 2026-08-05T00:00:00+09:00 | low |'
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'row_action=updated' \
   && grep -qxF "$expected_row" "$dir/index.md" \
   && ! grep -q 'Foo Pattern](pages' "$dir/index.md"; then
  pass "TC-2 既存行更新 (行全体を新形式で再生成)"
else
  fail "TC-2 (rc=$HELPER_RC stdout=$HELPER_STDOUT)"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-3 (T-01): description 空 → 既存サマリー保持
# ──────────────────────────────────────────────────────────────────────
dir=$(make_sandbox tc3)
run_helper --index "$dir/index.md" --title "Foo Pattern v3" --domain patterns \
  --slug foo --updated "2026-08-06T00:00:00+09:00" --confidence high \
  --pages-root "$dir/pages"
expected_row='| [Foo Pattern v3](pages/patterns/foo.md) | patterns | 既存サマリー | 2026-08-06T00:00:00+09:00 | high |'
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'row_action=updated' \
   && grep -qxF "$expected_row" "$dir/index.md"; then
  pass "TC-3 description 空で既存サマリー保持 (空文字上書きしない)"
else
  fail "TC-3 (rc=$HELPER_RC stdout=$HELPER_STDOUT)"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-4 (T-02): 生パイプ title の既存行を first-link 述語で同定し是正
# ──────────────────────────────────────────────────────────────────────
dir=$(make_sandbox tc4)
touch "$dir/pages/patterns/pipe-page.md"
cat > "$dir/index.md" <<'EOF'
# Wiki Index

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
| [broken | title](pages/patterns/pipe-page.md) | patterns | ズレた行のサマリー | 2026-01-01T00:00:00+09:00 | low |
EOF
run_helper --index "$dir/index.md" --title "broken | title" --domain patterns \
  --slug pipe-page --updated "2026-08-04T23:00:00+09:00" --confidence medium \
  --pages-root "$dir/pages"
expected_row='| [broken \| title](pages/patterns/pipe-page.md) | patterns | ズレた行のサマリー | 2026-08-04T23:00:00+09:00 | medium |'
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'row_action=updated' \
   && grep -qxF "$expected_row" "$dir/index.md"; then
  pass "TC-4 生パイプ title 行の同定・エスケープ是正・サマリー位置抽出"
else
  fail "TC-4 (rc=$HELPER_RC stdout=$HELPER_STDOUT actual=$(grep 'pipe-page' "$dir/index.md"))"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-5 (T-02): エスケープ規約 (a) — `\` を先に、次に `|`
# ──────────────────────────────────────────────────────────────────────
dir=$(make_sandbox tc5)
run_helper --index "$dir/index.md" --title 'C:\path | pipe' --domain patterns \
  --slug foo --description 'literal \| here' --updated "2026-08-04T23:50:00+09:00" \
  --confidence low --pages-root "$dir/pages"
expected_row='| [C:\\path \| pipe](pages/patterns/foo.md) | patterns | literal \\\| here | 2026-08-04T23:50:00+09:00 | low |'
if [ "$HELPER_RC" -eq 0 ] && grep -qxF "$expected_row" "$dir/index.md"; then
  pass "TC-5 規約 (a): backslash 先行エスケープで literal \\| が GFM 誤読されない"
else
  fail "TC-5 (rc=$HELPER_RC actual=$(grep 'foo\.md' "$dir/index.md"))"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-6 (T-02): 規約 (b) — 保持サマリーを再エスケープしない (増殖なし)
# ──────────────────────────────────────────────────────────────────────
dir=$(make_sandbox tc6)
cat > "$dir/index.md" <<'EOF'
# Wiki Index

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
| [Esc Page](pages/patterns/foo.md) | patterns | 済み \| と生 | の混在 | 2026-01-01T00:00:00+09:00 | high |
EOF
run_helper --index "$dir/index.md" --title "Esc Page" --domain patterns \
  --slug foo --updated "2026-08-05T00:10:00+09:00" --confidence high \
  --pages-root "$dir/pages"
rc1=$HELPER_RC
row_cycle1=$(grep 'foo\.md' "$dir/index.md")
run_helper --index "$dir/index.md" --title "Esc Page" --domain patterns \
  --slug foo --updated "2026-08-05T00:20:00+09:00" --confidence high \
  --pages-root "$dir/pages"
row_cycle2=$(grep 'foo\.md' "$dir/index.md")
expected_summary='済み \| と生 \| の混在'
expected_cycle2="| [Esc Page](pages/patterns/foo.md) | patterns | $expected_summary | 2026-08-05T00:20:00+09:00 | high |"
if [ "$rc1" -eq 0 ] && [ "$HELPER_RC" -eq 0 ] \
   && [ "$row_cycle2" = "$expected_cycle2" ] \
   && [ "${row_cycle1%|*|*|}" = "${row_cycle2%|*|*|}" ]; then
  pass "TC-6 規約 (b): 生 | のみエスケープ・既存 \\| は 2 サイクル回しても増殖しない"
else
  fail "TC-6 (cycle1=$row_cycle1 cycle2=$row_cycle2)"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-7 (T-03): 節内の `|` 行間の空行を除去
# ──────────────────────────────────────────────────────────────────────
dir=$(make_sandbox tc7)
touch "$dir/pages/heuristics/late.md"
cat > "$dir/index.md" <<'EOF'
# Wiki Index

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
| [Foo Pattern](pages/patterns/foo.md) | patterns | 既存 | 2026-01-01T00:00:00+09:00 | high |

| [Late Row](pages/heuristics/late.md) | heuristics | 空行の後の行 | 2026-01-02T00:00:00+09:00 | low |

## 統計

- 総ページ数: 2
- ドメイン別: patterns=1, heuristics=1, anti-patterns=0
- 最終更新: 2026-01-02T00:00:00+09:00
EOF
run_helper --index "$dir/index.md" --title "Late Row" --domain heuristics \
  --slug late --updated "2026-08-05T01:00:00+09:00" --confidence medium \
  --pages-root "$dir/pages"
blank_between=$(awk '/^\|/{p=1} p && /^[ \t]*$/{c++} /^## 統計/{exit} END{print c+0}' "$dir/index.md")
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'row_action=updated' \
   && [ "$blank_between" -le 1 ] \
   && grep -q 'Late Row' "$dir/index.md"; then
  # 空行除去後は Late 行が同定・更新されている (空行があると GFM 上は段落落ちしていた行)
  if grep -qxF '| [Late Row](pages/heuristics/late.md) | heuristics | 空行の後の行 | 2026-08-05T01:00:00+09:00 | medium |' "$dir/index.md"; then
    pass "TC-7 節内空行を除去し空行後の登録行も同定対象になる"
  else
    fail "TC-7 空行後の行が更新されていない"
  fi
else
  fail "TC-7 (rc=$HELPER_RC blank_between=$blank_between)"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-8 (T-03): 旧形式箇条書き行の共存維持
# ──────────────────────────────────────────────────────────────────────
dir=$(make_sandbox tc8)
touch "$dir/pages/heuristics/old-style.md"
cat > "$dir/index.md" <<'EOF'
# Wiki Index

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
| [Foo Pattern](pages/patterns/foo.md) | patterns | 既存 | 2026-01-01T00:00:00+09:00 | high |

- [旧形式ページ](pages/heuristics/old-style.md) - 旧箇条書きの説明
EOF
run_helper --index "$dir/index.md" --title "旧形式ページ" --domain heuristics \
  --slug old-style --description "テーブルへ新規登録" --updated "2026-08-05T02:00:00+09:00" \
  --confidence medium --pages-root "$dir/pages"
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'row_action=added' \
   && grep -qxF -- '- [旧形式ページ](pages/heuristics/old-style.md) - 旧箇条書きの説明' "$dir/index.md" \
   && grep -qxF '| [旧形式ページ](pages/heuristics/old-style.md) | heuristics | テーブルへ新規登録 | 2026-08-05T02:00:00+09:00 | medium |' "$dir/index.md"; then
  pass "TC-8 旧箇条書き行は述語対象外 (新規追加扱い・旧行は無改変で共存)"
else
  fail "TC-8 (rc=$HELPER_RC stdout=$HELPER_STDOUT)"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-9 (T-03): 対象外ページの重複行も 3a が回収 (先発保持)
# ──────────────────────────────────────────────────────────────────────
dir=$(make_sandbox tc9)
touch "$dir/pages/patterns/dup.md"
cat > "$dir/index.md" <<'EOF'
# Wiki Index

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
| [Dup 先発](pages/patterns/dup.md) | patterns | 1本目 | 2026-01-01T00:00:00+09:00 | high |
| [Dup 後発](pages/patterns/dup.md) | patterns | 2本目 | 2026-01-02T00:00:00+09:00 | low |
| [Foo Pattern](pages/patterns/foo.md) | patterns | 既存サマリー | 2026-01-01T00:00:00+09:00 | high |
EOF
run_helper --index "$dir/index.md" --title "Foo Pattern" --domain patterns \
  --slug foo --updated "2026-08-05T03:00:00+09:00" --confidence high \
  --pages-root "$dir/pages"
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'row_action=updated' \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'dedup_removed=1' \
   && grep -q 'Dup 先発' "$dir/index.md" \
   && ! grep -q 'Dup 後発' "$dir/index.md"; then
  pass "TC-9 対象外ページの重複も 3a が後発削除 (先発保持)"
else
  fail "TC-9 (rc=$HELPER_RC stdout=$HELPER_STDOUT)"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-10 (T-03): 対象ページ重複 → aborted_duplicate + 3a 回収
# ──────────────────────────────────────────────────────────────────────
dir=$(make_sandbox tc10)
touch "$dir/pages/patterns/dup.md"
cat > "$dir/index.md" <<'EOF'
# Wiki Index

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
| [Dup 先発](pages/patterns/dup.md) | patterns | 1本目 | 2026-01-01T00:00:00+09:00 | high |
| [Dup 後発](pages/patterns/dup.md) | patterns | 2本目 | 2026-01-02T00:00:00+09:00 | low |
EOF
run_helper --index "$dir/index.md" --title "Dup NEW" --domain patterns \
  --slug dup --description "中止されるべき更新" --updated "2026-08-05T04:00:00+09:00" \
  --confidence medium --pages-root "$dir/pages"
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'row_action=aborted_duplicate' \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'dedup_removed=1' \
   && printf '%s\n' "$HELPER_STDERR" | grep -q 'WARNING' \
   && grep -q 'Dup 先発' "$dir/index.md" \
   && ! grep -q 'Dup NEW' "$dir/index.md" \
   && ! grep -q 'Dup 後発' "$dir/index.md"; then
  pass "TC-10 対象ページ重複で中止 (fallback なし・WARNING) + 3a が後発回収"
else
  fail "TC-10 (rc=$HELPER_RC stdout=$HELPER_STDOUT)"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-11 (T-03): `## 統計` 節不在 → skip + 節を新設しない
# ──────────────────────────────────────────────────────────────────────
dir=$(make_sandbox tc11)
cat > "$dir/index.md" <<'EOF'
# Wiki Index

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
| [Foo Pattern](pages/patterns/foo.md) | patterns | 既存 | 2026-01-01T00:00:00+09:00 | high |
EOF
run_helper --index "$dir/index.md" --title "Foo Pattern" --domain patterns \
  --slug foo --updated "2026-08-05T05:00:00+09:00" --confidence high \
  --pages-root "$dir/pages"
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'stats_sync=skipped_no_section' \
   && ! grep -q '^## 統計' "$dir/index.md"; then
  pass "TC-11 統計節不在は skip し節を新設しない"
else
  fail "TC-11 (rc=$HELPER_RC stdout=$HELPER_STDOUT)"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-12 (T-03): `## ページ一覧` 節不在 → `## 統計` の直前に新設
# ──────────────────────────────────────────────────────────────────────
dir=$(make_sandbox tc12)
cat > "$dir/index.md" <<'EOF'
# Wiki Index

本文と HTML コメント。
<!-- comment -->

## 統計

- 総ページ数: 0
- ドメイン別: patterns=0, heuristics=0, anti-patterns=0
- 最終更新: 2026-01-01T00:00:00+09:00
EOF
run_helper --index "$dir/index.md" --title "First Page" --domain patterns \
  --slug foo --description "最初の登録" --updated "2026-08-05T06:00:00+09:00" \
  --confidence high --pages-root "$dir/pages"
list_line=$(grep -n '^## ページ一覧' "$dir/index.md" | cut -d: -f1)
stats_line=$(grep -n '^## 統計' "$dir/index.md" | cut -d: -f1)
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'row_action=added' \
   && [ -n "$list_line" ] && [ -n "$stats_line" ] && [ "$list_line" -lt "$stats_line" ] \
   && grep -qxF '| ページ | ドメイン | サマリー | 更新日 | 確信度 |' "$dir/index.md" \
   && grep -qxF '| [First Page](pages/patterns/foo.md) | patterns | 最初の登録 | 2026-08-05T06:00:00+09:00 | high |' "$dir/index.md" \
   && grep -qx -- '- 総ページ数: 2' "$dir/index.md"; then
  pass "TC-12 節不在時は統計の直前にヘッダ付きで新設"
else
  fail "TC-12 (rc=$HELPER_RC list_line=$list_line stats_line=$stats_line)"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-13 (T-04): index.md 不在 → exit 1
# ──────────────────────────────────────────────────────────────────────
run_helper --index "$TEST_DIR/nonexistent/index.md" --title t --domain patterns \
  --slug s --updated "2026-08-05T07:00:00+09:00" --confidence high
if [ "$HELPER_RC" -eq 1 ] && printf '%s\n' "$HELPER_STDERR" | grep -q 'ERROR'; then
  pass "TC-13 index.md 不在で exit 1 (fail-loud)"
else
  fail "TC-13 (rc=$HELPER_RC stderr=$HELPER_STDERR)"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-14 (T-04): `## ページ一覧` 見出し重複 (想定外構造) → exit 1 + 無変更
# ──────────────────────────────────────────────────────────────────────
dir=$(make_sandbox tc14)
cat > "$dir/index.md" <<'EOF'
# Wiki Index

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
EOF
before=$(cat "$dir/index.md")
run_helper --index "$dir/index.md" --title t --domain patterns --slug s \
  --updated "2026-08-05T08:00:00+09:00" --confidence high --pages-root "$dir/pages"
after=$(cat "$dir/index.md")
if [ "$HELPER_RC" -eq 1 ] \
   && printf '%s\n' "$HELPER_STDERR" | grep -q 'ERROR' \
   && [ "$before" = "$after" ]; then
  pass "TC-14 見出し重複 (想定外構造) で exit 1・部分適用なし"
else
  fail "TC-14 (rc=$HELPER_RC)"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-15 (T-04): invocation error 群 → exit 2 + 無変更
# ──────────────────────────────────────────────────────────────────────
dir=$(make_sandbox tc15)
before=$(cat "$dir/index.md")
tc15_ok=1
run_helper --index "$dir/index.md" --title t --domain bogus --slug s \
  --updated "2026-08-05T09:00:00+09:00" --confidence high
[ "$HELPER_RC" -eq 2 ] || { tc15_ok=0; echo "  (domain enum 違反が rc=$HELPER_RC)"; }
run_helper --index "$dir/index.md" --title t --domain patterns --slug s \
  --updated "2026-08-05T09:00:00+09:00" --confidence urgent
[ "$HELPER_RC" -eq 2 ] || { tc15_ok=0; echo "  (confidence enum 違反が rc=$HELPER_RC)"; }
run_helper --index "$dir/index.md" --title t --domain patterns --slug s \
  --updated "2026|08" --confidence high
[ "$HELPER_RC" -eq 2 ] || { tc15_ok=0; echo "  (| 入り updated が rc=$HELPER_RC)"; }
run_helper --index "$dir/index.md" --title t --domain patterns --slug 'bad/slug' \
  --updated "2026-08-05T09:00:00+09:00" --confidence high
[ "$HELPER_RC" -eq 2 ] || { tc15_ok=0; echo "  (不正 slug が rc=$HELPER_RC)"; }
run_helper --index "$dir/index.md" --domain patterns --slug s \
  --updated "2026-08-05T09:00:00+09:00" --confidence high
[ "$HELPER_RC" -eq 2 ] || { tc15_ok=0; echo "  (--title 欠落が rc=$HELPER_RC)"; }
after=$(cat "$dir/index.md")
if [ "$tc15_ok" -eq 1 ] && [ "$before" = "$after" ]; then
  pass "TC-15 invocation error 群で exit 2・index.md 無変更"
else
  fail "TC-15"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-16 (T-04): pages 一覧 0 件 → stats skip + 既存統計値保持
# ──────────────────────────────────────────────────────────────────────
dir=$(make_sandbox tc16)
rm -rf "$dir/pages"
run_helper --index "$dir/index.md" --title "Foo Pattern" --domain patterns \
  --slug foo --updated "2026-08-05T10:00:00+09:00" --confidence high \
  --pages-root "$dir/pages"
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'stats_sync=skipped_unreadable' \
   && printf '%s\n' "$HELPER_STDERR" | grep -q 'WARNING' \
   && grep -qx -- '- 総ページ数: 1' "$dir/index.md" \
   && grep -qx -- '- 最終更新: 2026-01-01T00:00:00+09:00' "$dir/index.md" \
   && grep -q '2026-08-05T10:00:00+09:00' "$dir/index.md"; then
  pass "TC-16 pages 取得不能は WARNING + 統計値保持 (行操作は適用)"
else
  fail "TC-16 (rc=$HELPER_RC stdout=$HELPER_STDOUT)"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-17 (T-06): SKILL.md ステップ 6 の縮退 (grep 検査)
# ──────────────────────────────────────────────────────────────────────
if [ ! -f "$INGEST_MD" ]; then
  echo "ERROR: $INGEST_MD not found" >&2
  exit 1
fi
step6=$(awk '/^## ステップ 6:/{f=1} f && /^## ステップ 7/{exit} f{print}' "$INGEST_MD")
tc17_ok=1
printf '%s\n' "$step6" | grep -q 'wiki-index-update\.sh' || { tc17_ok=0; echo "  (helper 呼び出しがステップ 6 に無い)"; }
# 操作アルゴリズムの散文が残っていないこと (各フレーズは旧手順 0-3b の記述に固有)
for phrase in '最初に現れる' '閉じ括弧までの範囲' '末尾 2 つを更新日列' \
              '後発行を削除' '空行があれば削除' 'エスケープして substitute' \
              '見出しの直後（既存の登録行より前）に補う'; do
  if printf '%s\n' "$step6" | grep -qF "$phrase"; then
    tc17_ok=0; echo "  (操作散文が残存: $phrase)"
  fi
done
if [ "$tc17_ok" -eq 1 ]; then
  pass "TC-17 ステップ 6 は helper 呼び出しへ縮退し操作散文が残っていない"
else
  fail "TC-17"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
