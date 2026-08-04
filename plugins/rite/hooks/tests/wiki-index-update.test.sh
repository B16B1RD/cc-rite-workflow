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
#   TC-13b (T-04) index.md 読み取り不能 → exit 1 + 'not readable' 診断 (root では skip)
#   TC-14 (T-04) `## ページ一覧` 見出し重複 (想定外構造) → exit 1 + 無変更
#   TC-14b (T-04) `## 統計` 見出し重複 → stats_sync=skipped_unreadable
#         (first-match で 1 節目だけ同期して synced を返さない・両節無変更・行操作は適用)
#   TC-15b (T-04) UTF-8 日本語 title/description の制御文字誤検出なし (rc=0、C1 除外の意図を pin)
#   TC-15c (T-04) brace 含み正当 title は residue gate に棄却されない (exact 突合の意図を pin)
#   TC-16g (T-04) 統計 3 行が全欠落 → stats_sync=skipped_unreadable (0 行同期を synced にしない)
#   TC-22 (T-04) 行末区切り欠落の登録行から summary 保持抽出 → exit 1 + 無変更
#         (positional 抽出の前提崩れを silent 空文字化させない)
#   TC-22b (T-04) セル数不足 (4/3 セル) + 余剰フラグメント行から summary 保持抽出 → exit 1 + 無変更
#         (欠損はセル数ガード、余剰は境界フラグメント検査が捕捉 — 各ガード単独の識別力を pin)
#   TC-22c (T-01) 空サマリーセルの正当な 5 列行は保持経路で rc=0 のまま (境界 pin)
#   TC-23 (T-03) サマリー欄の相互参照リンクは同定に使われない (FIRST link 述語、golden)
#   TC-24 (T-03) 新規追加と同時に別ページの重複行を回収 (added × dedup_removed=1)
#   TC-25 (T-02) リンク構文入り title の同定キー詐称防止 (`]` → &#93; 中和、golden)
#   TC-12b (T-03) 統計節も不在なら EOF に節新設 (golden)
#   TC-16b (T-04) pages 一覧 0 件 (*.md ゼロ、find rc=0) → skip + 統計保持
#   TC-16c (T-04) --pages-root 省略 (統計節あり) → skipped_unreadable + 統計保持
#   TC-16d (T-04) 統計行の一部欠落 → WARNING + 残存行のみ同期・新設しない (golden)
#   TC-16e (T-04) 祖先ディレクトリ名がドメイン名と衝突しても内訳が膨張しない
#   TC-16f (T-03) 節末端より後ろの別節の pages リンク行は不変 (golden)
#   TC-17b (T-06) SKILL.md ステップ 6 呼び出し契約の invocation-symmetry (フラグ集合突合)
#   TC-18 (T-01/T-03) 別ドメイン同一 slug は別ページ (同定キー = {domain}/{slug}、golden)
#   TC-19〜21 (T-03) ヘッダ行・区切り行の欠落補填 (両方欠落 / 区切りのみ / ヘッダのみ、golden)
#   (T-05 は既存 wiki-lint 系スイートの継続 green で担保 — 本ファイル対象外)
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
# description は生パイプ入り (新規追加経路のエスケープ規約 (a) を golden で固定する)
run_helper --index "$dir/index.md" --title "Bar Heuristic" --domain heuristics \
  --slug bar --description "bar の説明 | 補足" --updated "2026-08-04T22:00:00+09:00" \
  --confidence medium --pages-root "$dir/pages"
# golden 全文比較: grep 断片照合ではなく期待ファイル全文との diff で固定する
# (ヘッダ二重化・本文欠落・空行過剰削除・節末端誤検出を 1 assert で同時捕捉)
cat > "$TEST_DIR/tc1-expected.md" <<'EOF'
# Wiki Index

カタログ本文。

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
| [Foo Pattern](pages/patterns/foo.md) | patterns | 既存サマリー | 2026-01-01T00:00:00+09:00 | high |
| [Bar Heuristic](pages/heuristics/bar.md) | heuristics | bar の説明 \| 補足 | 2026-08-04T22:00:00+09:00 | medium |

## 統計

- 総ページ数: 2
- ドメイン別: patterns=1, heuristics=1, anti-patterns=0
- 最終更新: 2026-08-04T22:00:00+09:00
EOF
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -q '^\[CONTEXT\] WIKI_INDEX_UPDATE=row_action=added; dedup_removed=0; stats_sync=synced$' \
   && diff -u "$TEST_DIR/tc1-expected.md" "$dir/index.md" > "$TEST_DIR/tc1-diff.txt" 2>&1; then
  pass "TC-1 新規行追加 (golden 全文比較: 末尾追加・本文/構造保存・統計同期)"
else
  fail "TC-1 (rc=$HELPER_RC stdout=$HELPER_STDOUT)"
  cat "$TEST_DIR/tc1-diff.txt" 2>/dev/null
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
# golden 全文比較: パイプ行間の空行だけが消え、見出し直後・統計節直前の空行は保持される
# ことを diff で固定する (過剰削除の変異を捕捉。総ページ数は fixture の実 pages/ = 3)
cat > "$TEST_DIR/tc7-expected.md" <<'EOF'
# Wiki Index

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
| [Foo Pattern](pages/patterns/foo.md) | patterns | 既存 | 2026-01-01T00:00:00+09:00 | high |
| [Late Row](pages/heuristics/late.md) | heuristics | 空行の後の行 | 2026-08-05T01:00:00+09:00 | medium |

## 統計

- 総ページ数: 3
- ドメイン別: patterns=1, heuristics=2, anti-patterns=0
- 最終更新: 2026-08-05T01:00:00+09:00
EOF
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'row_action=updated' \
   && diff -u "$TEST_DIR/tc7-expected.md" "$dir/index.md" > "$TEST_DIR/tc7-diff.txt" 2>&1; then
  pass "TC-7 節内空行の除去 (golden 全文比較: 空行後の行の同定・境界空行の保持)"
else
  fail "TC-7 (rc=$HELPER_RC stdout=$HELPER_STDOUT)"
  cat "$TEST_DIR/tc7-diff.txt" 2>/dev/null
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
   && printf '%s\n' "$HELPER_STDERR" | grep -qF "2 rows register page 'patterns/dup'" \
   && grep -q 'Dup 先発' "$dir/index.md" \
   && ! grep -q 'Dup NEW' "$dir/index.md" \
   && ! grep -q 'Dup 後発' "$dir/index.md"; then
  pass "TC-10 対象ページ重複で中止 (page '{domain}/{slug}' 表記 WARNING) + 3a が後発回収"
else
  fail "TC-10 (rc=$HELPER_RC stdout=$HELPER_STDOUT stderr=$HELPER_STDERR)"
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
# golden 全文比較: 新設節の形状・位置・見出し literal を固定する
# (見出し汚染変異は is_list_head が二度と一致せず次サイクルで節が二重化するため)
cat > "$TEST_DIR/tc12-expected.md" <<'EOF'
# Wiki Index

本文と HTML コメント。
<!-- comment -->

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
| [First Page](pages/patterns/foo.md) | patterns | 最初の登録 | 2026-08-05T06:00:00+09:00 | high |

## 統計

- 総ページ数: 2
- ドメイン別: patterns=1, heuristics=1, anti-patterns=0
- 最終更新: 2026-08-05T06:00:00+09:00
EOF
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'row_action=added' \
   && diff -u "$TEST_DIR/tc12-expected.md" "$dir/index.md" > "$TEST_DIR/tc12-diff.txt" 2>&1; then
  pass "TC-12 節不在時は統計の直前にヘッダ付きで新設 (golden)"
else
  fail "TC-12 (rc=$HELPER_RC stdout=$HELPER_STDOUT)"
  cat "$TEST_DIR/tc12-diff.txt" 2>/dev/null
fi

# ──────────────────────────────────────────────────────────────────────
# TC-12b (T-03): 節・統計とも不在 → EOF に新設 (golden)
# ──────────────────────────────────────────────────────────────────────
dir=$(make_sandbox tc12b)
printf '# Wiki Index\n\n本文。\n' > "$dir/index.md"
run_helper --index "$dir/index.md" --title "EOF Page" --domain patterns \
  --slug foo --description "EOF 挿入" --updated "2026-08-05T06:30:00+09:00" \
  --confidence high --pages-root "$dir/pages"
cat > "$TEST_DIR/tc12b-expected.md" <<'EOF'
# Wiki Index

本文。

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
| [EOF Page](pages/patterns/foo.md) | patterns | EOF 挿入 | 2026-08-05T06:30:00+09:00 | high |
EOF
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -q '^\[CONTEXT\] WIKI_INDEX_UPDATE=row_action=added; dedup_removed=0; stats_sync=skipped_no_section$' \
   && diff -u "$TEST_DIR/tc12b-expected.md" "$dir/index.md" > "$TEST_DIR/tc12b-diff.txt" 2>&1; then
  pass "TC-12b 統計節も不在なら EOF に新設 (golden)"
else
  fail "TC-12b (rc=$HELPER_RC stdout=$HELPER_STDOUT)"
  cat "$TEST_DIR/tc12b-diff.txt" 2>/dev/null
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
# TC-13b (T-04): index.md 読み取り不能 → exit 1 + 'not readable' 診断
# rc=1 だけではガードの識別力がない (-r ガードを退行させても後段の awk 失敗が
# 原因を取り違えた ERROR で rc=1 を返す) ため、-r ガード固有の診断文言を stderr
# に対して assert し、無変更も前後比較で確認する
# ──────────────────────────────────────────────────────────────────────
if [ "$(id -u)" -eq 0 ]; then
  skip "TC-13b (root では chmod 000 が read を阻めないため測定不能)"
else
  dir=$(make_sandbox tc13b)
  before=$(cat "$dir/index.md")
  chmod 000 "$dir/index.md"
  run_helper --index "$dir/index.md" --title t --domain patterns \
    --slug s --updated "2026-08-05T07:30:00+09:00" --confidence high
  chmod 644 "$dir/index.md"
  after=$(cat "$dir/index.md")
  if [ "$HELPER_RC" -eq 1 ] \
     && printf '%s\n' "$HELPER_STDERR" | grep -q 'not readable' \
     && [ "$before" = "$after" ]; then
    pass "TC-13b index.md 読み取り不能で exit 1 + 'not readable' 診断 (fail-loud)"
  else
    fail "TC-13b (rc=$HELPER_RC stderr=$HELPER_STDERR)"
  fi
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
# TC-14b (T-04): `## 統計` 見出し重複 → 統計同期のみ skip (skipped_unreadable)
# ページ一覧側の見出し重複 (TC-14) と同じ破損クラスだが、行操作 (唯一の重複修復
# 経路 3a を含む) まで塞ぐのは過剰なため exit 1 ではなく WARNING + 同期 skip。
# first-match で 1 節目だけ同期して synced を返す縮退 (silent first-match) を殺す
# ──────────────────────────────────────────────────────────────────────
dir=$(make_sandbox tc14b)
cat > "$dir/index.md" <<'EOF'
# Wiki Index

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
| [Foo Pattern](pages/patterns/foo.md) | patterns | 既存サマリー | 2026-01-01T00:00:00+09:00 | high |

## 統計

- 総ページ数: 99
- ドメイン別: patterns=99, heuristics=0, anti-patterns=0
- 最終更新: 2020-01-01T00:00:00+09:00

## 統計

- 総ページ数: 77
- ドメイン別: patterns=77, heuristics=0, anti-patterns=0
- 最終更新: 2021-01-01T00:00:00+09:00
EOF
run_helper --index "$dir/index.md" --title "Foo Pattern" --domain patterns \
  --slug foo --description "更新後" --updated "2026-08-05T13:30:00+09:00" \
  --confidence high --pages-root "$dir/pages"
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qF '[CONTEXT] WIKI_INDEX_UPDATE=row_action=updated; dedup_removed=0; stats_sync=skipped_unreadable' \
   && printf '%s\n' "$HELPER_STDERR" | grep -q 'ambiguous sync target' \
   && grep -q '総ページ数: 99' "$dir/index.md" \
   && grep -q '総ページ数: 77' "$dir/index.md" \
   && grep -qxF '| [Foo Pattern](pages/patterns/foo.md) | patterns | 更新後 | 2026-08-05T13:30:00+09:00 | high |' "$dir/index.md"; then
  pass "TC-14b 統計見出し重複は同期 skip (skipped_unreadable)・両節無変更・行操作は適用"
else
  fail "TC-14b (rc=$HELPER_RC stdout=$HELPER_STDOUT stderr=$HELPER_STDERR)"
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
# 制御文字 reject 経路 (_has_c0_del): 改行入り title / 改行入り description /
# 制御文字 (TAB) 入り updated はいずれも exit 2 (1 行のテーブル行として表現不能)
run_helper --index "$dir/index.md" --title $'a\nb' --domain patterns --slug s \
  --updated "2026-08-05T09:00:00+09:00" --confidence high
[ "$HELPER_RC" -eq 2 ] || { tc15_ok=0; echo "  (改行入り title が rc=$HELPER_RC)"; }
run_helper --index "$dir/index.md" --title t --domain patterns --slug s \
  --description $'x\ny' --updated "2026-08-05T09:00:00+09:00" --confidence high
[ "$HELPER_RC" -eq 2 ] || { tc15_ok=0; echo "  (改行入り description が rc=$HELPER_RC)"; }
run_helper --index "$dir/index.md" --title t --domain patterns --slug s \
  --updated $'2026\t08' --confidence high
[ "$HELPER_RC" -eq 2 ] || { tc15_ok=0; echo "  (制御文字入り updated が rc=$HELPER_RC)"; }
# placeholder residue gate: 未置換の {title}/{description}/{updated} は exit 2
run_helper --index "$dir/index.md" --title '{title}' --domain patterns --slug s \
  --updated "2026-08-05T09:00:00+09:00" --confidence high
[ "$HELPER_RC" -eq 2 ] || { tc15_ok=0; echo "  (未置換 {title} が rc=$HELPER_RC)"; }
run_helper --index "$dir/index.md" --title t --domain patterns --slug s \
  --description '{description}' --updated "2026-08-05T09:00:00+09:00" --confidence high
[ "$HELPER_RC" -eq 2 ] || { tc15_ok=0; echo "  (未置換 {description} が rc=$HELPER_RC)"; }
run_helper --index "$dir/index.md" --title t --domain patterns --slug s \
  --updated '{updated}' --confidence high
[ "$HELPER_RC" -eq 2 ] || { tc15_ok=0; echo "  (未置換 {updated} が rc=$HELPER_RC)"; }
# unknown argument arm: フラグ誤記への唯一の fail-loud (silent no-op 退化の検出)
run_helper --index "$dir/index.md" --title t --domain patterns --slug s \
  --updated "2026-08-05T09:00:00+09:00" --confidence high --bogus x
if [ "$HELPER_RC" -ne 2 ] || ! printf '%s\n' "$HELPER_STDERR" | grep -qF 'unknown argument: --bogus'; then
  tc15_ok=0; echo "  (unknown argument --bogus が rc=$HELPER_RC / ERROR 文言不一致)"
fi
after=$(cat "$dir/index.md")
if [ "$tc15_ok" -eq 1 ] && [ "$before" = "$after" ]; then
  pass "TC-15 invocation error 群 (enum/slug/updated/欠落/制御文字) で exit 2・index.md 無変更"
else
  fail "TC-15"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-15b (T-04): UTF-8 日本語 title/description は制御文字誤検出しない (rc=0)
# _has_c0_del が C1 バイト (UTF-8 継続バイトと重複) を検査対象から除外した意図を pin
# ──────────────────────────────────────────────────────────────────────
dir=$(make_sandbox tc15b)
run_helper --index "$dir/index.md" --title "日本語タイトルのページ" --domain patterns \
  --slug foo --description "日本語の説明文です" --updated "2026-08-05T09:30:00+09:00" \
  --confidence high --pages-root "$dir/pages"
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'row_action=updated' \
   && grep -qxF '| [日本語タイトルのページ](pages/patterns/foo.md) | patterns | 日本語の説明文です | 2026-08-05T09:30:00+09:00 | high |' "$dir/index.md"; then
  pass "TC-15b UTF-8 日本語 title/description が制御文字誤検出されない (rc=0)"
else
  fail "TC-15b (rc=$HELPER_RC stdout=$HELPER_STDOUT)"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-15c (T-04): brace 含み正当 title は residue gate に棄却されない
# gate は literal `{title}`/`{description}`/`{updated}` の exact 突合のみ
# (形状ヒューリスティックだと free text の正当値を棄却し当該ページが孤児化する)
# ──────────────────────────────────────────────────────────────────────
dir=$(make_sandbox tc15c)
run_helper --index "$dir/index.md" --title '{CONTEXT} マーカーの設計 {emit}' --domain patterns \
  --slug foo --description '{description 風だが正当} な値' \
  --updated "2026-08-05T09:40:00+09:00" --confidence high --pages-root "$dir/pages"
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'row_action=updated' \
   && grep -qxF '| [{CONTEXT} マーカーの設計 {emit}](pages/patterns/foo.md) | patterns | {description 風だが正当} な値 | 2026-08-05T09:40:00+09:00 | high |' "$dir/index.md"; then
  pass "TC-15c brace 含み正当 title/description が residue gate に棄却されない (rc=0)"
else
  fail "TC-15c (rc=$HELPER_RC stdout=$HELPER_STDOUT stderr=$HELPER_STDERR)"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-16 (T-04): pages ディレクトリ不在 (find 非ゼロ終了) → stats skip + 既存統計値保持
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
  pass "TC-16 pages ディレクトリ不在 (find rc 非ゼロ) は WARNING + 統計値保持 (行操作は適用)"
else
  fail "TC-16 (rc=$HELPER_RC stdout=$HELPER_STDOUT)"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-16b (T-04): pages 一覧 0 件 (ディレクトリは在るが *.md ゼロ) → 同じく skip
# find は rc=0 で空出力を返すため [ -z "$pages_list" ] guard の実行可能仕様
# ──────────────────────────────────────────────────────────────────────
dir=$(make_sandbox tc16b)
rm -rf "$dir/pages"
mkdir -p "$dir/pages/patterns"
touch "$dir/pages/patterns/.gitkeep"
run_helper --index "$dir/index.md" --title "Foo Pattern" --domain patterns \
  --slug foo --updated "2026-08-05T10:10:00+09:00" --confidence high \
  --pages-root "$dir/pages"
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'stats_sync=skipped_unreadable' \
   && printf '%s\n' "$HELPER_STDERR" | grep -q 'WARNING' \
   && grep -qx -- '- 総ページ数: 1' "$dir/index.md" \
   && grep -qx -- '- ドメイン別: patterns=1, heuristics=0, anti-patterns=0' "$dir/index.md" \
   && grep -qx -- '- 最終更新: 2026-01-01T00:00:00+09:00' "$dir/index.md"; then
  pass "TC-16b pages 一覧 0 件 (*.md ゼロ) も統計値保持 (誤った 0 で上書きしない)"
else
  fail "TC-16b (rc=$HELPER_RC stdout=$HELPER_STDOUT)"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-16c (T-04): 統計節ありで --pages-root 省略 → skipped_unreadable + 統計保持
# ──────────────────────────────────────────────────────────────────────
dir=$(make_sandbox tc16c)
run_helper --index "$dir/index.md" --title "Foo Pattern" --domain patterns \
  --slug foo --updated "2026-08-05T10:20:00+09:00" --confidence high
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'stats_sync=skipped_unreadable' \
   && printf '%s\n' "$HELPER_STDERR" | grep -q 'WARNING' \
   && grep -qx -- '- 総ページ数: 1' "$dir/index.md" \
   && grep -qx -- '- 最終更新: 2026-01-01T00:00:00+09:00' "$dir/index.md" \
   && grep -q '2026-08-05T10:20:00+09:00' "$dir/index.md"; then
  pass "TC-16c --pages-root 省略は WARNING + skipped_unreadable + 統計保持"
else
  fail "TC-16c (rc=$HELPER_RC stdout=$HELPER_STDOUT)"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-16d (T-04): 統計 3 行の一部欠落 → 欠落行を新設せず残存行のみ同期 + WARNING
# docstring の never invented 不変条件の実行可能仕様 (golden)
# ──────────────────────────────────────────────────────────────────────
dir=$(make_sandbox tc16d)
cat > "$dir/index.md" <<'EOF'
# Wiki Index

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
| [Foo Pattern](pages/patterns/foo.md) | patterns | 既存 | 2026-01-01T00:00:00+09:00 | high |

## 統計

- 総ページ数: 1
- 最終更新: 2026-01-01T00:00:00+09:00
EOF
run_helper --index "$dir/index.md" --title "Foo Pattern" --domain patterns \
  --slug foo --updated "2026-08-05T10:30:00+09:00" --confidence high \
  --pages-root "$dir/pages"
cat > "$TEST_DIR/tc16d-expected.md" <<'EOF'
# Wiki Index

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
| [Foo Pattern](pages/patterns/foo.md) | patterns | 既存 | 2026-08-05T10:30:00+09:00 | high |

## 統計

- 総ページ数: 2
- 最終更新: 2026-08-05T10:30:00+09:00
EOF
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'stats_sync=synced' \
   && printf '%s\n' "$HELPER_STDERR" | grep -q 'ドメイン別' \
   && diff -u "$TEST_DIR/tc16d-expected.md" "$dir/index.md" > "$TEST_DIR/tc16d-diff.txt" 2>&1; then
  pass "TC-16d 統計行の一部欠落は WARNING (行名明示) + 残存行のみ同期・欠落行は新設しない (golden)"
else
  fail "TC-16d (rc=$HELPER_RC stdout=$HELPER_STDOUT)"
  cat "$TEST_DIR/tc16d-diff.txt" 2>/dev/null
fi

# ──────────────────────────────────────────────────────────────────────
# TC-16g (T-04): 統計 3 行が全欠落 → stats_sync=skipped_unreadable + WARNING
# 1 行も同期できていないのに synced を返すと marker 契約 (LLM への唯一の
# 機械可読チャネル) が WARNING と矛盾する — 0 行同期は「前サイクル値のまま」
# なので skipped_unreadable と同義に降ろす
# ──────────────────────────────────────────────────────────────────────
dir=$(make_sandbox tc16g)
cat > "$dir/index.md" <<'EOF'
# Wiki Index

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
| [Foo Pattern](pages/patterns/foo.md) | patterns | 既存 | 2026-01-01T00:00:00+09:00 | high |

## 統計

（統計行は手動整理で失われた）
EOF
run_helper --index "$dir/index.md" --title "Foo Pattern" --domain patterns \
  --slug foo --updated "2026-08-05T10:35:00+09:00" --confidence high \
  --pages-root "$dir/pages"
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'stats_sync=skipped_unreadable' \
   && printf '%s\n' "$HELPER_STDERR" | grep -q 'WARNING' \
   && grep -qxF '（統計行は手動整理で失われた）' "$dir/index.md" \
   && grep -q '2026-08-05T10:35:00+09:00' "$dir/index.md"; then
  pass "TC-16g 統計 3 行全欠落は skipped_unreadable (0 行同期を synced と偽装しない・行は新設しない)"
else
  fail "TC-16g (rc=$HELPER_RC stdout=$HELPER_STDOUT)"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-16e (T-04): 祖先ディレクトリ名がドメイン名と衝突しても内訳が膨張しない
# 前方一致 anchor (実装の case literal 前方一致) の実行可能仕様
# ──────────────────────────────────────────────────────────────────────
dir="$TEST_DIR/patterns/tc16e"
mkdir -p "$dir/pages/patterns" "$dir/pages/heuristics" "$dir/pages/anti-patterns"
touch "$dir/pages/patterns/p1.md" "$dir/pages/patterns/p2.md" \
      "$dir/pages/heuristics/h1.md" \
      "$dir/pages/anti-patterns/a1.md" "$dir/pages/anti-patterns/a2.md" "$dir/pages/anti-patterns/a3.md"
cat > "$dir/index.md" <<'EOF'
# Wiki Index

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
| [P1](pages/patterns/p1.md) | patterns | 既存 | 2026-01-01T00:00:00+09:00 | high |

## 統計

- 総ページ数: 0
- ドメイン別: patterns=0, heuristics=0, anti-patterns=0
- 最終更新: 2026-01-01T00:00:00+09:00
EOF
run_helper --index "$dir/index.md" --title "P1" --domain patterns \
  --slug p1 --updated "2026-08-05T10:40:00+09:00" --confidence high \
  --pages-root "$dir/pages"
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'stats_sync=synced' \
   && grep -qx -- '- 総ページ数: 6' "$dir/index.md" \
   && grep -qx -- '- ドメイン別: patterns=2, heuristics=1, anti-patterns=3' "$dir/index.md"; then
  pass "TC-16e 祖先 patterns/ ディレクトリ下でも内訳が膨張しない (前方一致 anchor)"
else
  fail "TC-16e (rc=$HELPER_RC stdout=$HELPER_STDOUT actual=$(grep 'ドメイン別' "$dir/index.md"))"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-16f (T-03): 節末端 — ページ一覧節の後ろの別節にある pages リンク行は不変
# 「次の ## 見出しまで」述語の実行可能仕様 (golden)
# ──────────────────────────────────────────────────────────────────────
dir=$(make_sandbox tc16f)
cat > "$dir/index.md" <<'EOF'
# Wiki Index

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
| [Foo Pattern](pages/patterns/foo.md) | patterns | 既存 | 2026-01-01T00:00:00+09:00 | high |

## 参考

| リンク | 説明 |
|--------|------|
| [Foo Pattern](pages/patterns/foo.md) | 参考リンク |
EOF
run_helper --index "$dir/index.md" --title "Foo Pattern v2" --domain patterns \
  --slug foo --updated "2026-08-05T10:50:00+09:00" --confidence high \
  --pages-root "$dir/pages"
cat > "$TEST_DIR/tc16f-expected.md" <<'EOF'
# Wiki Index

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
| [Foo Pattern v2](pages/patterns/foo.md) | patterns | 既存 | 2026-08-05T10:50:00+09:00 | high |

## 参考

| リンク | 説明 |
|--------|------|
| [Foo Pattern](pages/patterns/foo.md) | 参考リンク |
EOF
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -q '^\[CONTEXT\] WIKI_INDEX_UPDATE=row_action=updated; dedup_removed=0; stats_sync=skipped_no_section$' \
   && diff -u "$TEST_DIR/tc16f-expected.md" "$dir/index.md" > "$TEST_DIR/tc16f-diff.txt" 2>&1; then
  pass "TC-16f 節末端より後ろの別節にある pages リンク行は同定・回収の対象外 (golden)"
else
  fail "TC-16f (rc=$HELPER_RC stdout=$HELPER_STDOUT)"
  cat "$TEST_DIR/tc16f-diff.txt" 2>/dev/null
fi

# ──────────────────────────────────────────────────────────────────────
# TC-18 (T-01/T-03): 別ドメイン同一 slug は別ページ — 誤同定・誤削除しない
# 同定キーはページ path ({domain}/{slug})。slug 単独キーだと heuristics/c の行が
# patterns/c の「重複」と誤判定され silent 削除される (golden 全文比較で両行保持を固定)
# ──────────────────────────────────────────────────────────────────────
dir=$(make_sandbox tc18)
touch "$dir/pages/patterns/c.md" "$dir/pages/heuristics/c.md"
cat > "$dir/index.md" <<'EOF'
# Wiki Index

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
| [C patterns 側](pages/patterns/c.md) | patterns | sA | 2026-01-01T00:00:00+09:00 | high |
| [C heuristics 側](pages/heuristics/c.md) | heuristics | sB | 2026-01-02T00:00:00+09:00 | medium |
EOF
run_helper --index "$dir/index.md" --title "C patterns 側 v2" --domain patterns \
  --slug c --updated "2026-08-05T14:00:00+09:00" --confidence low \
  --pages-root "$dir/pages"
cat > "$TEST_DIR/tc18-expected.md" <<'EOF'
# Wiki Index

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
| [C patterns 側 v2](pages/patterns/c.md) | patterns | sA | 2026-08-05T14:00:00+09:00 | low |
| [C heuristics 側](pages/heuristics/c.md) | heuristics | sB | 2026-01-02T00:00:00+09:00 | medium |
EOF
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -q '^\[CONTEXT\] WIKI_INDEX_UPDATE=row_action=updated; dedup_removed=0; stats_sync=skipped_no_section$' \
   && diff -u "$TEST_DIR/tc18-expected.md" "$dir/index.md" > "$TEST_DIR/tc18-diff.txt" 2>&1; then
  pass "TC-18 別ドメイン同一 slug は両行保持 (対象ドメインの行のみ更新・dedup 0)"
else
  fail "TC-18 (rc=$HELPER_RC stdout=$HELPER_STDOUT)"
  cat "$TEST_DIR/tc18-diff.txt" 2>/dev/null
fi

# ──────────────────────────────────────────────────────────────────────
# TC-19/20/21 (T-03): ヘッダ行・区切り行の欠落補填 (手順 0) — golden 全文比較
# 節はあるがヘッダ/区切りが欠けた index を、見出し直後 (既存登録行より前) に補って
# 正規の 5 列テーブル形へ是正する分岐の実行可能仕様
# ──────────────────────────────────────────────────────────────────────
# TC-19: ヘッダ・区切り両方欠落 → 見出し直後に 2 行を挿入
dir=$(make_sandbox tc19)
cat > "$dir/index.md" <<'EOF'
# Wiki Index

## ページ一覧

| [Foo Pattern](pages/patterns/foo.md) | patterns | 既存 | 2026-01-01T00:00:00+09:00 | high |
EOF
run_helper --index "$dir/index.md" --title "Foo Pattern v19" --domain patterns \
  --slug foo --updated "2026-08-05T11:00:00+09:00" --confidence high \
  --pages-root "$dir/pages"
cat > "$TEST_DIR/tc19-expected.md" <<'EOF'
# Wiki Index

## ページ一覧
| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
| [Foo Pattern v19](pages/patterns/foo.md) | patterns | 既存 | 2026-08-05T11:00:00+09:00 | high |
EOF
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'row_action=updated' \
   && diff -u "$TEST_DIR/tc19-expected.md" "$dir/index.md" > "$TEST_DIR/tc19-diff.txt" 2>&1; then
  pass "TC-19 ヘッダ・区切り両方欠落を見出し直後に補填 (golden)"
else
  fail "TC-19 (rc=$HELPER_RC stdout=$HELPER_STDOUT)"
  cat "$TEST_DIR/tc19-diff.txt" 2>/dev/null
fi

# TC-20: 区切り行のみ欠落 → ヘッダ行の直後に挿入 (見出し直後ではない)
dir=$(make_sandbox tc20)
cat > "$dir/index.md" <<'EOF'
# Wiki Index

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
| [Foo Pattern](pages/patterns/foo.md) | patterns | 既存 | 2026-01-01T00:00:00+09:00 | high |
EOF
run_helper --index "$dir/index.md" --title "Foo Pattern v20" --domain patterns \
  --slug foo --updated "2026-08-05T12:00:00+09:00" --confidence high \
  --pages-root "$dir/pages"
cat > "$TEST_DIR/tc20-expected.md" <<'EOF'
# Wiki Index

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
| [Foo Pattern v20](pages/patterns/foo.md) | patterns | 既存 | 2026-08-05T12:00:00+09:00 | high |
EOF
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'row_action=updated' \
   && diff -u "$TEST_DIR/tc20-expected.md" "$dir/index.md" > "$TEST_DIR/tc20-diff.txt" 2>&1; then
  pass "TC-20 区切り行のみ欠落をヘッダ行直後に補填 (golden)"
else
  fail "TC-20 (rc=$HELPER_RC stdout=$HELPER_STDOUT)"
  cat "$TEST_DIR/tc20-diff.txt" 2>/dev/null
fi

# TC-21: ヘッダ行のみ欠落 → 見出し直後に挿入 (区切り行の前)
dir=$(make_sandbox tc21)
cat > "$dir/index.md" <<'EOF'
# Wiki Index

## ページ一覧

|--------|---------|---------|--------|--------|
| [Foo Pattern](pages/patterns/foo.md) | patterns | 既存 | 2026-01-01T00:00:00+09:00 | high |
EOF
run_helper --index "$dir/index.md" --title "Foo Pattern v21" --domain patterns \
  --slug foo --updated "2026-08-05T13:00:00+09:00" --confidence high \
  --pages-root "$dir/pages"
cat > "$TEST_DIR/tc21-expected.md" <<'EOF'
# Wiki Index

## ページ一覧
| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
| [Foo Pattern v21](pages/patterns/foo.md) | patterns | 既存 | 2026-08-05T13:00:00+09:00 | high |
EOF
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'row_action=updated' \
   && diff -u "$TEST_DIR/tc21-expected.md" "$dir/index.md" > "$TEST_DIR/tc21-diff.txt" 2>&1; then
  pass "TC-21 ヘッダ行のみ欠落を見出し直後 (区切り行の前) に補填 (golden)"
else
  fail "TC-21 (rc=$HELPER_RC stdout=$HELPER_STDOUT)"
  cat "$TEST_DIR/tc21-diff.txt" 2>/dev/null
fi

# ──────────────────────────────────────────────────────────────────────
# TC-22 (T-04): 行末区切り欠落の登録行 + description 省略 (summary 保持経路)
# → exit 1 + 無変更。この fixture (断片 5 個) は境界フラグメント検査とセル数
# ガードの両方に該当するため fail-loud 契約全体を pin するが、単独ガードの識別
# 力は持たない (片方を無効化しても他方が捕捉して緑のまま) — 境界検査だけが
# 検出できる形状 (余剰フラグメント) は TC-22b の第 3 shape が担う
# ──────────────────────────────────────────────────────────────────────
dir=$(make_sandbox tc22)
cat > "$dir/index.md" <<'EOF'
# Wiki Index

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
| [Foo Pattern](pages/patterns/foo.md) | patterns | 蓄積サマリー | 2026-01-01T00:00:00+09:00 | high
EOF
before=$(cat "$dir/index.md")
run_helper --index "$dir/index.md" --title "Foo Pattern" --domain patterns \
  --slug foo --updated "2026-08-05T11:00:00+09:00" --confidence high \
  --pages-root "$dir/pages"
after=$(cat "$dir/index.md")
if [ "$HELPER_RC" -eq 1 ] \
   && printf '%s\n' "$HELPER_STDERR" | grep -q 'ERROR' \
   && [ "$before" = "$after" ] \
   && [ "$(grep -c '蓄積サマリー' "$dir/index.md")" -eq 1 ]; then
  pass "TC-22 行末区切り欠落行の summary 保持抽出は exit 1・無変更 (silent 空文字化しない)"
else
  fail "TC-22 (rc=$HELPER_RC stdout=$HELPER_STDOUT stderr=$HELPER_STDERR)"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-22b (T-04): セル数不足/過剰の登録行 + description 省略 → exit 1 + 無変更
# 4 セル行は境界フラグメントが両方空白で境界検査を通過しセル数ガードが捕捉、
# 3 セル行は早期脱出 — どちらも欠けたセルを特定できず保持値を確定できない。
# 第 3 shape (末尾に余剰フラグメント 2 つ、行末区切りなし) はセル数ガード
# (n-2>=4) を通過し境界フラグメント検査だけが捕捉する: 境界検査を単独で
# 無効化する変異は summary 列が更新日列以降を飲み込む silent corruption に
# なるため、この shape が当該ガード単独の識別力を担う
# ──────────────────────────────────────────────────────────────────────
tc22b_ok=1
for shape in \
  '| [Foo Pattern](pages/patterns/foo.md) | patterns | 蓄積サマリー | 2026-01-01T00:00:00+09:00 |' \
  '| [Foo Pattern](pages/patterns/foo.md) | 蓄積サマリー |' \
  '| [Foo Pattern](pages/patterns/foo.md) | patterns | 蓄積サマリー | 2026-01-01T00:00:00+09:00 | high | junk1 | junk2'; do
  dir=$(make_sandbox "tc22b-$(printf '%s' "$shape" | wc -c)")
  cat > "$dir/index.md" <<EOF
# Wiki Index

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
$shape
EOF
  before=$(cat "$dir/index.md")
  run_helper --index "$dir/index.md" --title "Foo Pattern" --domain patterns \
    --slug foo --updated "2026-08-05T12:00:00+09:00" --confidence high \
    --pages-root "$dir/pages"
  after=$(cat "$dir/index.md")
  if [ "$HELPER_RC" -ne 1 ] || ! printf '%s\n' "$HELPER_STDERR" | grep -q 'ERROR' \
     || [ "$before" != "$after" ] || [ "$(grep -c '蓄積サマリー' "$dir/index.md")" -ne 1 ]; then
    tc22b_ok=0; echo "  (セル数 $(printf '%s' "$shape" | awk -F'|' '{print NF-2}') の行が rc=$HELPER_RC / 蓄積サマリー残存 $(grep -c '蓄積サマリー' "$dir/index.md"))"
  fi
done
if [ "$tc22b_ok" -eq 1 ]; then
  pass "TC-22b セル数不足 (4/3 セル) + 余剰フラグメント行の summary 保持抽出は exit 1・無変更"
else
  fail "TC-22b"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-22c (T-01): 空サマリーセルの正当な 5 列行は保持経路で rc=0 (境界 pin)
# セル数ガードの下限 (5 列ちょうど) を fail-loud 側へ倒しすぎない境界固定
# ──────────────────────────────────────────────────────────────────────
dir=$(make_sandbox tc22c)
cat > "$dir/index.md" <<'EOF'
# Wiki Index

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
| [Foo Pattern](pages/patterns/foo.md) | patterns |  | 2026-01-01T00:00:00+09:00 | high |
EOF
run_helper --index "$dir/index.md" --title "Foo Pattern" --domain patterns \
  --slug foo --updated "2026-08-05T12:10:00+09:00" --confidence high \
  --pages-root "$dir/pages"
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'row_action=updated' \
   && grep -qxF '| [Foo Pattern](pages/patterns/foo.md) | patterns |  | 2026-08-05T12:10:00+09:00 | high |' "$dir/index.md"; then
  pass "TC-22c 空サマリーセルの正当 5 列行は保持経路で rc=0 (ガードの過剰発火なし)"
else
  fail "TC-22c (rc=$HELPER_RC stdout=$HELPER_STDOUT stderr=$HELPER_STDERR)"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-23 (T-03): サマリー欄の相互参照リンクは同定に使われない (FIRST link 述語)
# 述語を「行内の最後のリンク」へ変える drift は Page B の登録行を silent 削除
# する — 両行保持 + dedup 0 を golden 全文比較で固定
# ──────────────────────────────────────────────────────────────────────
dir=$(make_sandbox tc23)
mkdir -p "$dir/pages/patterns"
touch "$dir/pages/patterns/a.md" "$dir/pages/patterns/b.md"
cat > "$dir/index.md" <<'EOF'
# Wiki Index

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
| [Page A](pages/patterns/a.md) | patterns | 詳細は [Page B](pages/patterns/b.md) を参照 | 2026-01-01T00:00:00+09:00 | high |
| [Page B](pages/patterns/b.md) | patterns | B の説明 | 2026-01-01T00:00:00+09:00 | high |

## 統計

- 総ページ数: 2
- ドメイン別: patterns=2, heuristics=0, anti-patterns=0
- 最終更新: 2026-01-01T00:00:00+09:00
EOF
run_helper --index "$dir/index.md" --title "Page A" --domain patterns \
  --slug a --updated "2026-08-05T12:20:00+09:00" --confidence high \
  --pages-root "$dir/pages"
cat > "$TEST_DIR/tc23-expected.md" <<'EOF'
# Wiki Index

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
| [Page A](pages/patterns/a.md) | patterns | 詳細は [Page B](pages/patterns/b.md) を参照 | 2026-08-05T12:20:00+09:00 | high |
| [Page B](pages/patterns/b.md) | patterns | B の説明 | 2026-01-01T00:00:00+09:00 | high |

## 統計

- 総ページ数: 4
- ドメイン別: patterns=3, heuristics=1, anti-patterns=0
- 最終更新: 2026-08-05T12:20:00+09:00
EOF
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -q '^\[CONTEXT\] WIKI_INDEX_UPDATE=row_action=updated; dedup_removed=0; stats_sync=synced$' \
   && diff -u "$TEST_DIR/tc23-expected.md" "$dir/index.md" > "$TEST_DIR/tc23-diff.txt" 2>&1; then
  pass "TC-23 サマリー欄の相互参照リンクは非同定 (FIRST link 述語・両行保持・golden)"
else
  fail "TC-23 (rc=$HELPER_RC stdout=$HELPER_STDOUT)"
  cat "$TEST_DIR/tc23-diff.txt" 2>/dev/null
fi

# ──────────────────────────────────────────────────────────────────────
# TC-24 (T-03): 新規追加と同時に別ページの重複行を回収 (3a は毎回走る)
# 追加経路だけ回収を止める drift の変異を殺す — added × dedup_removed=1
# ──────────────────────────────────────────────────────────────────────
dir=$(make_sandbox tc24)
mkdir -p "$dir/pages/heuristics"
touch "$dir/pages/heuristics/new.md"
cat > "$dir/index.md" <<'EOF'
# Wiki Index

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
| [Dup](pages/patterns/dup.md) | patterns | 先発 | 2026-01-01T00:00:00+09:00 | high |
| [Dup 重複](pages/patterns/dup.md) | patterns | 後発 | 2026-01-02T00:00:00+09:00 | low |
EOF
run_helper --index "$dir/index.md" --title "New Page" --domain heuristics \
  --slug new --description "追加" --updated "2026-08-05T12:30:00+09:00" \
  --confidence medium --pages-root "$dir/pages"
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qF '[CONTEXT] WIKI_INDEX_UPDATE=row_action=added; dedup_removed=1; stats_sync=skipped_no_section' \
   && [ "$(grep -c 'pages/patterns/dup\.md' "$dir/index.md")" -eq 1 ] \
   && grep -q '先発' "$dir/index.md" \
   && ! grep -q '後発' "$dir/index.md" \
   && grep -qxF '| [New Page](pages/heuristics/new.md) | heuristics | 追加 | 2026-08-05T12:30:00+09:00 | medium |' "$dir/index.md"; then
  pass "TC-24 新規追加と同時に別ページの重複後発行を回収 (added; dedup_removed=1)"
else
  fail "TC-24 (rc=$HELPER_RC stdout=$HELPER_STDOUT)"
fi

# ──────────────────────────────────────────────────────────────────────
# TC-25 (T-02): リンク構文を含む title は同定キーを詐称できない (`]` → &#93; 中和)
# 中和なしだと生成行の FIRST link が title 内の `](pages/patterns/foo.md)` になり、
# (a) 追加直後に 3a が既存 foo 行との「重複」として新規行を回収する (added なのに
#     行が残らず dedup_removed=1)、(b) 以後の foo 更新が詐称行を foo の行として
# 丸ごと書き換える — いずれも WARNING なし・rc=0・成功 marker のまま。
# 2 サイクル (詐称 title の追加 → 正規 foo の更新) を回して golden で固定する
# ──────────────────────────────────────────────────────────────────────
dir=$(make_sandbox tc25)
touch "$dir/pages/heuristics/beta.md"
run_helper --index "$dir/index.md" --title 'x ](pages/patterns/foo.md) y' --domain heuristics \
  --slug beta --description "beta 説明" --updated "2026-08-05T14:00:00+09:00" \
  --confidence medium --pages-root "$dir/pages"
tc25_rc1=$HELPER_RC
tc25_out1=$HELPER_STDOUT
run_helper --index "$dir/index.md" --title "Foo Pattern" --domain patterns \
  --slug foo --description "foo 更新" --updated "2026-08-05T14:10:00+09:00" \
  --confidence high --pages-root "$dir/pages"
cat > "$TEST_DIR/tc25-expected.md" <<'EOF'
# Wiki Index

カタログ本文。

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
| [Foo Pattern](pages/patterns/foo.md) | patterns | foo 更新 | 2026-08-05T14:10:00+09:00 | high |
| [x &#93;(pages/patterns/foo.md) y](pages/heuristics/beta.md) | heuristics | beta 説明 | 2026-08-05T14:00:00+09:00 | medium |

## 統計

- 総ページ数: 3
- ドメイン別: patterns=1, heuristics=2, anti-patterns=0
- 最終更新: 2026-08-05T14:10:00+09:00
EOF
if [ "$tc25_rc1" -eq 0 ] \
   && printf '%s\n' "$tc25_out1" | grep -qF '[CONTEXT] WIKI_INDEX_UPDATE=row_action=added; dedup_removed=0; stats_sync=synced' \
   && [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'row_action=updated' \
   && diff -u "$TEST_DIR/tc25-expected.md" "$dir/index.md" > "$TEST_DIR/tc25-diff.txt" 2>&1; then
  pass "TC-25 リンク構文入り title の同定キー詐称を &#93; 中和で防止 (added 行が回収されず foo 更新も非破壊・golden)"
else
  fail "TC-25 (rc1=$tc25_rc1 out1=$tc25_out1 rc2=$HELPER_RC stdout=$HELPER_STDOUT)"
  cat "$TEST_DIR/tc25-diff.txt" 2>/dev/null
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

# ──────────────────────────────────────────────────────────────────────
# TC-17b (T-06): SKILL.md ステップ 6 呼び出し契約の invocation-symmetry
# 委譲リファクタの唯一の統合シーム。フラグ集合は helper の case arm から動的抽出して
# 突合する (create-md-invocation-symmetry.test.sh と同型の契約テスト)
# ──────────────────────────────────────────────────────────────────────
step6_block=$(printf '%s\n' "$step6" | awk '/^```bash$/{f=1;next} /^```$/{f=0} f{print}')
tc17b_ok=1
[ -n "$step6_block" ] || { tc17b_ok=0; echo "  (ステップ 6 に fenced bash ブロックが無い)"; }
helper_flags=$(grep -oE '^[[:space:]]+--[a-z-]+\)' "$SCRIPT" | tr -d ' )' | LC_ALL=C sort)
skill_flags=$(printf '%s\n' "$step6_block" | grep -oE -- '--[a-z-]+' | LC_ALL=C sort -u)
if [ "$helper_flags" != "$skill_flags" ]; then
  tc17b_ok=0
  echo "  (フラグ集合が helper の case arm と不一致)"
  echo "  helper: $(printf '%s' "$helper_flags" | tr '\n' ' ')"
  echo "  skill:  $(printf '%s' "$skill_flags" | tr '\n' ' ')"
fi
printf '%s\n' "$step6_block" | grep -qF -- '--domain "{domain}"' || { tc17b_ok=0; echo "  (--domain の placeholder 対応が崩れている)"; }
printf '%s\n' "$step6_block" | grep -qF -- '--slug "{slug}"' || { tc17b_ok=0; echo "  (--slug の placeholder 対応が崩れている)"; }
printf '%s\n' "$step6_block" | grep -qF -- '--updated "{updated}"' || { tc17b_ok=0; echo "  (--updated の placeholder 対応が崩れている)"; }
printf '%s\n' "$step6_block" | grep -qF -- '--confidence "{confidence}"' || { tc17b_ok=0; echo "  (--confidence の placeholder 対応が崩れている)"; }
printf '%s\n' "$step6_block" | grep -qF -- '--title "$wiu_title"' || { tc17b_ok=0; echo "  (--title の heredoc 変数対応が崩れている)"; }
printf '%s\n' "$step6_block" | grep -qF -- '--description "$wiu_description"' || { tc17b_ok=0; echo "  (--description の heredoc 変数対応が崩れている)"; }
# 呼び出し行の実体 (コマンド語・値の形) も literal で pin する — フラグ名集合の突合だけでは
# 呼び出し行の削除・helper パス改名・パス値の相対化・quoted heredoc 解除が生存する
printf '%s\n' "$step6_block" | grep -qF -- 'bash "{plugin_root}/hooks/scripts/wiki-index-update.sh"' || { tc17b_ok=0; echo "  (helper 呼び出しコマンド行が無い/形が崩れている)"; }
printf '%s\n' "$step6_block" | grep -qF -- '--index "$wiki_root/index.md"' || { tc17b_ok=0; echo '  (--index の値が $wiki_root/index.md でない)'; }
printf '%s\n' "$step6_block" | grep -qF -- '--pages-root "$wiki_root/pages"' || { tc17b_ok=0; echo '  (--pages-root の値が $wiki_root/pages でない)'; }
# 継続行を 1 論理コマンドへ join して 8 フラグが同一コマンド内に並ぶことを assert する。
# 行単位断片の grep だけでは継続 backslash の脱落 (行が分断され後続フラグが別コマンド化し
# 実行時 rc=127 になる Edit 崩れ) が生存する
step6_joined=$(printf '%s\n' "$step6_block" | awk '{ if (sub(/[[:space:]]*\\$/, " ")) printf "%s", $0; else print }')
helper_call_line=$(printf '%s\n' "$step6_joined" | grep -F -- 'bash "{plugin_root}/hooks/scripts/wiki-index-update.sh"') || helper_call_line=""
if [ -z "$helper_call_line" ]; then
  tc17b_ok=0; echo "  (join 後に helper 呼び出しが 1 論理コマンドに正規化できない)"
else
  tc17b_split_flags=""
  for f in $helper_flags; do
    case "$helper_call_line" in
      *"$f "*) ;;
      *) tc17b_ok=0; tc17b_split_flags="$tc17b_split_flags $f" ;;
    esac
  done
  [ -z "$tc17b_split_flags" ] || echo "  (継続 backslash 脱落等でフラグが呼び出しコマンドの外にある:$tc17b_split_flags)"
fi
printf '%s\n' "$step6_block" | grep -qF -- "wiu_title=\$(cat <<'WIU_EOF'" || { tc17b_ok=0; echo "  (title の quoted heredoc が解除されている)"; }
printf '%s\n' "$step6_block" | grep -qF -- "wiu_description=\$(cat <<'WIU_EOF'" || { tc17b_ok=0; echo "  (description の quoted heredoc が解除されている)"; }
if [ "$tc17b_ok" -eq 1 ]; then
  pass "TC-17b ステップ 6 呼び出し契約 (8 フラグ + placeholder 対応 + 呼び出し行 literal) が helper と一致"
else
  fail "TC-17b"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
