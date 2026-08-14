#!/usr/bin/env bash
# Test: wiki-query-inject.sh — OKF 2-pass query (Sub-2)
#
# Covers the two-pass rewrite Test Spec rows that the 2-pass rewrite introduces:
#   TC-1 (T-03/T-04) keyword match returns the page with frontmatter-derived metadata
#   TC-2 (T-05)      confidence weighting (high > low) ordering is preserved
#   TC-3 (T-08)      a candidate whose page is unreadable is skipped non-blocking
#                    (WARNING + exit 0, the remaining candidate still renders)
#   TC-4 (T-09)      an index with no bullet candidates yields empty output, exit 0
#   TC-5 (F-01)      a bullet example inside an HTML comment is NOT parsed as a
#                    candidate (no phantom "index.md may be stale" WARNING)
#
# Note: a zero-candidate run against an index that DOES carry registration rows
# emits a notice on stdout as well as stderr (five of the six callers discard
# stderr), so TC-9 / TC-15 assert the notice rather than an empty stdout. TC-4
# holds the negative side — an index with no registration rows stays silent on
# both streams.
set -uo pipefail

# _timeout <seconds> <command...> — portable timeout(1) for this test.
# GNU `timeout` is absent on macOS (BSD / no coreutils); fall back to a perl
# fork/waitpid shim reproducing timeout(1)'s exit-code contract: 124 on timeout,
# 128+N on signal death, the child's status otherwise (a naive
# `perl -e 'alarm; exec'` would exit 142 and defeat hang-detection assertions).
# This file does not source _test-helpers.sh, so the shim is inlined here — keep
# it byte-identical with _test-helpers.sh (timeout-shim.test.sh asserts no drift).
_timeout() {
  local _d="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$_d" "$@"
  else
    perl -e '
      my $d = shift;
      # alarm truncates to an integer, so a fractional deadline silently becomes
      # alarm 0 — no timeout at all, and waitpid blocks until the CI job limit.
      # Reject rather than degrade, and exit 125 rather than die: die exits 255,
      # which every caller reads as "not 124, so no hang" — the same silent pass
      # the rejection exists to prevent. GNU timeout accepts fractions, so this
      # shim only claims the contract for integer seconds.
      if ($d !~ /^[0-9]+$/) {
        print STDERR "_timeout: fractional seconds are not supported by the perl fallback: $d\n";
        exit 125;
      }
      my $pid = fork;
      exit 127 unless defined $pid;
      # setpgrp puts the child in its own process group so the alarm handler can
      # signal the whole tree with a negative pid. GNU timeout does the same; without
      # it the deadline only reaches the direct child, and a grandchild holding the
      # captured stdout keeps the caller blocked long past the timeout (measured 30s
      # against a 1s deadline). The runners capture output with $( ), so that stall
      # would consume the CI job limit instead of failing at 124.
      if ($pid == 0) { setpgrp(0, 0); exec { $ARGV[0] } @ARGV; exit 127; }
      $SIG{ALRM} = sub { kill "TERM", -$pid; waitpid($pid, 0); exit 124; };
      alarm $d; waitpid $pid, 0;
      my $st = $?; exit($st & 127 ? 128 + ($st & 127) : $st >> 8);
    ' "$_d" "$@"
  fi
}

# Fail closed when no backend exists. Every `_timeout` caller reads a non-124 rc
# as "no hang", so a missing backend would silently turn each hang assertion into
# a pass. Abort at source time rather than degrade.
if ! command -v timeout >/dev/null 2>&1 && ! command -v perl >/dev/null 2>&1; then
  echo "ERROR: neither timeout(1) nor perl(1) is available — _timeout cannot detect" >&2
  echo "  hangs, and every hang assertion in this suite would silently pass." >&2
  echo "  Install GNU coreutils (timeout) or perl before running the test suite." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../wiki-query-inject.sh"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rite-wiki-query-test-XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT

PASS=0
FAIL=0
pass() { echo "  ✅ PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ FAIL: $1"; FAIL=$((FAIL + 1)); }

# Build a same_branch wiki sandbox (git repo + rite-config.yml + .rite/wiki/...).
# Args: name, index_content; then page specs via global PAGE_SPECS (path|frontmatter).
make_query_sandbox() {
  local name="$1" index_content="$2"
  local repo="$TEST_DIR/$name"
  mkdir -p "$repo/.rite/wiki/pages"
  (cd "$repo" && git init -q -b main . 2>/dev/null)
  cat > "$repo/rite-config.yml" <<'CFG'
wiki:
  enabled: true
  branch_strategy: "same_branch"
language: ja
CFG
  printf '%s' "$index_content" > "$repo/.rite/wiki/index.md"
  echo "$repo"
}

# Write a page file with the given frontmatter + a trivial body.
write_page() {
  local repo="$1" relpath="$2" frontmatter="$3"
  mkdir -p "$repo/.rite/wiki/$(dirname "$relpath")"
  { printf '%s\n' "$frontmatter"; printf '# body\n本文\n'; } > "$repo/.rite/wiki/$relpath"
}

run_query() {
  local repo="$1"; shift
  QOUT=$( (cd "$repo" && _timeout 15 bash "$SCRIPT" "$@") 2>"$TEST_DIR/qerr" )
  QRC=$?
  QERR=$(cat "$TEST_DIR/qerr")
}

# --- TC-1 (T-03/T-04): keyword match + frontmatter-derived metadata ---
echo "=== TC-1: query がキーワード一致ページを返し frontmatter メタデータを表示 ==="
INDEX_1='# Wiki Index

* [Cache Strategy](pages/heuristics/cache.md) - キャッシュ戦略の cache 経験則
'
repo=$(make_query_sandbox tc1 "$INDEX_1")
write_page "$repo" pages/heuristics/cache.md '---
type: "heuristics"
title: "Cache Strategy"
domain: heuristics
description: "キャッシュ戦略の cache 経験則"
generated: { by: "rite-wiki-ingest/test", at: "2026-06-15" }
confidence: high
---'
run_query "$repo" --keywords "cache" --format compact
if [ "$QRC" -eq 0 ] \
   && printf '%s' "$QOUT" | grep -q 'Cache Strategy' \
   && printf '%s' "$QOUT" | grep -q '確信度.*: high' \
   && printf '%s' "$QOUT" | grep -q 'ドメイン.*: heuristics' \
   && printf '%s' "$QOUT" | grep -q '更新日.*: 2026-06-15'; then
  pass "TC-1 一致ページ + frontmatter 由来メタデータ (domain/confidence/updated)"
else
  fail "TC-1 (rc=$QRC out=$QOUT)"
fi

# --- TC-2 (T-05): confidence weighting (high above low) ---
echo "=== TC-2: confidence 重み付け順序 (high > low) ==="
INDEX_2='# Wiki Index

* [High Page](pages/heuristics/hi.md) - widget の高信頼
* [Low Page](pages/patterns/lo.md) - widget の低信頼
'
repo=$(make_query_sandbox tc2 "$INDEX_2")
write_page "$repo" pages/heuristics/hi.md '---
title: "High Page"
domain: heuristics
description: "widget の高信頼"
generated: { by: "rite-wiki-ingest/test", at: "2026-06-15" }
confidence: high
---'
write_page "$repo" pages/patterns/lo.md '---
title: "Low Page"
domain: patterns
description: "widget の低信頼"
generated: { by: "rite-wiki-ingest/test", at: "2026-06-10" }
confidence: low
---'
run_query "$repo" --keywords "widget" --format compact
hi_line=$(printf '%s\n' "$QOUT" | grep -n 'High Page' | head -1 | cut -d: -f1)
lo_line=$(printf '%s\n' "$QOUT" | grep -n 'Low Page' | head -1 | cut -d: -f1)
if [ "$QRC" -eq 0 ] && [ -n "$hi_line" ] && [ -n "$lo_line" ] && [ "$hi_line" -lt "$lo_line" ]; then
  pass "TC-2 high confidence ページが low より上位 (重み付け維持)"
else
  fail "TC-2 (rc=$QRC hi=$hi_line lo=$lo_line out=$QOUT)"
fi

# --- TC-3 (T-08): unreadable candidate page → non-blocking skip ---
echo "=== TC-3: 候補 page 読取失敗で WARNING + 非ブロッキング継続 (他候補は表示) ==="
INDEX_3='# Wiki Index

* [Good Page](pages/heuristics/good.md) - gizmo の良いページ
* [Missing Page](pages/heuristics/missing.md) - gizmo の欠落ページ
'
repo=$(make_query_sandbox tc3 "$INDEX_3")
write_page "$repo" pages/heuristics/good.md '---
title: "Good Page"
domain: heuristics
description: "gizmo の良いページ"
generated: { by: "rite-wiki-ingest/test", at: "2026-06-15" }
confidence: medium
---'
# missing.md は作らない
run_query "$repo" --keywords "gizmo" --format compact
if [ "$QRC" -eq 0 ] \
   && printf '%s' "$QOUT" | grep -q 'Good Page' \
   && printf '%s' "$QERR" | grep -q 'pages/heuristics/missing.md' \
   && printf '%s' "$QERR" | grep -qi 'skipping candidate'; then
  pass "TC-3 missing.md は WARNING + skip、Good Page は表示、exit 0"
else
  fail "TC-3 (rc=$QRC out=$QOUT err=$QERR)"
fi

# --- TC-4 (T-09): no candidates → empty output, exit 0 ---
echo "=== TC-4: 候補なし index で空出力 exit 0 ==="
INDEX_4='# Wiki Index

（まだページがありません）
'
repo=$(make_query_sandbox tc4 "$INDEX_4")
run_query "$repo" --keywords "anything" --format compact
if [ "$QRC" -eq 0 ] && [ -z "$QOUT" ]; then
  pass "TC-4 候補なしで空出力 exit 0"
else
  fail "TC-4 (rc=$QRC out=$QOUT)"
fi

# --- TC-5 (F-01): HTML comment bullet example is NOT parsed as candidate ---
echo "=== TC-5: HTML コメント内の箇条書きサンプルを候補化しない (phantom WARNING なし) ==="
INDEX_5='# Wiki Index

<!-- 登録箇条書きの形式例（このコメントは登録ではない）:
* [ページタイトル](pages/heuristics/example.md) - 1-2 文の説明 -->

* [Real Page](pages/patterns/real.md) - thing の実ページ
'
repo=$(make_query_sandbox tc5 "$INDEX_5")
write_page "$repo" pages/patterns/real.md '---
title: "Real Page"
domain: patterns
description: "thing の実ページ"
generated: { by: "rite-wiki-ingest/test", at: "2026-06-15" }
confidence: high
---'
# pages/heuristics/example.md は作らない（コメント内の例なので実在しない）
run_query "$repo" --keywords "thing" --format compact
if [ "$QRC" -eq 0 ] \
   && printf '%s' "$QOUT" | grep -q 'Real Page' \
   && ! printf '%s' "$QERR" | grep -q 'example.md'; then
  pass "TC-5 コメント内サンプル example.md を読みに行かず phantom WARNING なし"
else
  fail "TC-5 (rc=$QRC out=$QOUT err=$QERR)"
fi

# --- TC-6 (T-01): table-form index yields candidates ---
echo "=== TC-6: 5 列テーブル形式 index から候補抽出 ==="
INDEX_6='# Wiki Index

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
| [Table Page](pages/heuristics/tbl.md) | heuristics | mktemp 失敗時の扱い | 2026-06-15T10:00:00+09:00 | high |
'
repo=$(make_query_sandbox tc6 "$INDEX_6")
write_page "$repo" pages/heuristics/tbl.md '---
title: "Table Page"
domain: heuristics
description: "mktemp 失敗時の扱い"
generated: { by: "rite-wiki-ingest/test", at: "2026-06-15" }
confidence: high
---'
run_query "$repo" --keywords "mktemp" --format compact
if [ "$QRC" -eq 0 ] \
   && printf '%s' "$QOUT" | grep -q 'Table Page' \
   && printf '%s' "$QOUT" | grep -q '確信度.*: high'; then
  pass "TC-6 テーブル行から候補抽出 + frontmatter メタデータ"
else
  fail "TC-6 (rc=$QRC out=$QOUT err=$QERR)"
fi

# --- TC-7 (T-03): both forms in one index ---
echo "=== TC-7: 箇条書きとテーブルが混在する index から双方抽出 ==="
INDEX_7='# Wiki Index

* [Bullet Page](pages/patterns/bul.md) - gadget の箇条書きページ

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
| [Table Page](pages/heuristics/tbl.md) | heuristics | gadget のテーブルページ | 2026-06-15T10:00:00+09:00 | medium |
'
repo=$(make_query_sandbox tc7 "$INDEX_7")
write_page "$repo" pages/patterns/bul.md '---
title: "Bullet Page"
domain: patterns
description: "gadget の箇条書きページ"
generated: { by: "rite-wiki-ingest/test", at: "2026-06-14" }
confidence: high
---'
write_page "$repo" pages/heuristics/tbl.md '---
title: "Table Page"
domain: heuristics
description: "gadget のテーブルページ"
generated: { by: "rite-wiki-ingest/test", at: "2026-06-15" }
confidence: medium
---'
run_query "$repo" --keywords "gadget" --format compact
if [ "$QRC" -eq 0 ] \
   && printf '%s' "$QOUT" | grep -q 'Bullet Page' \
   && printf '%s' "$QOUT" | grep -q 'Table Page'; then
  pass "TC-7 両形式から候補抽出 (箇条書きの既存挙動を保ったままテーブルも拾う)"
else
  fail "TC-7 (rc=$QRC out=$QOUT err=$QERR)"
fi

# --- TC-8 (T-04): escaped pipe in cells is restored ---
echo "=== TC-8: セル内の \\| エスケープを元の | へ復元 ==="
INDEX_8='# Wiki Index

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
| [`cmd \| grep` の罠](pages/anti-patterns/pipe.md) | anti-patterns | `set -o pipefail` なしの `a \| b` は widget を取りこぼす | 2026-06-15T10:00:00+09:00 | high |
'
repo=$(make_query_sandbox tc8 "$INDEX_8")
write_page "$repo" pages/anti-patterns/pipe.md '---
title: "`cmd | grep` の罠"
domain: anti-patterns
description: "`set -o pipefail` なしの `a | b` は widget を取りこぼす"
generated: { by: "rite-wiki-ingest/test", at: "2026-06-15" }
confidence: high
---'
run_query "$repo" --keywords "widget" --format compact
if [ "$QRC" -eq 0 ] \
   && printf '%s' "$QOUT" | grep -qF 'cmd | grep' \
   && ! printf '%s' "$QOUT" | grep -qF 'cmd \| grep'; then
  pass "TC-8 \\| を含むセルが生の | として復元される"
else
  fail "TC-8 (rc=$QRC out=$QOUT err=$QERR)"
fi

# --- TC-9 (T-05): zero candidates but page links present → WARNING ---
echo "=== TC-9: 候補 0 件 + ](pages/...) 行あり → WARNING (silent 0 件にしない) ==="
INDEX_9='# Wiki Index

<ul>
<li><a href="pages/heuristics/html.md">HTML 形式の登録行</a> ](pages/heuristics/html.md)</li>
</ul>
'
repo=$(make_query_sandbox tc9 "$INDEX_9")
run_query "$repo" --keywords "anything" --format compact
if [ "$QRC" -eq 0 ] \
   && printf '%s' "$QOUT" | grep -q 'Wiki 経験則は注入されていません' \
   && printf '%s' "$QERR" | grep -q '候補を 1 件も抽出できませんでした'; then
  pass "TC-9 形式未対応による 0 件が stderr と stdout の両方で可視化される"
else
  fail "TC-9 (rc=$QRC out=$QOUT err=$QERR)"
fi

# --- TC-10 (T-06 / MUST NOT): table example inside an HTML comment ---
echo "=== TC-10: HTML コメント内のテーブル形式例を候補化しない ==="
INDEX_10='# Wiki Index

<!-- 登録テーブルの形式例（このコメントは登録ではない）:
| [ページタイトル](pages/heuristics/example.md) | heuristics | 1-2 文の説明 | 2026-01-01 | medium |
-->

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
| [Real Table Page](pages/patterns/realtbl.md) | patterns | doodad の実ページ | 2026-06-15T10:00:00+09:00 | high |
'
repo=$(make_query_sandbox tc10 "$INDEX_10")
write_page "$repo" pages/patterns/realtbl.md '---
title: "Real Table Page"
domain: patterns
description: "doodad の実ページ"
generated: { by: "rite-wiki-ingest/test", at: "2026-06-15" }
confidence: high
---'
# pages/heuristics/example.md は作らない（コメント内の例なので実在しない）
run_query "$repo" --keywords "doodad" --format compact
if [ "$QRC" -eq 0 ] \
   && printf '%s' "$QOUT" | grep -q 'Real Table Page' \
   && ! printf '%s' "$QERR" | grep -q 'example.md'; then
  pass "TC-10 コメント内テーブル例 example.md を読みに行かず phantom WARNING なし"
else
  fail "TC-10 (rc=$QRC out=$QOUT err=$QERR)"
fi

# --- TC-11: summary cross-link does not hijack the page target ---
# (T-02 — 箇条書き形式の非退行 — は TC-1〜TC-5 が新実装下でも通ることで担保する。
#  本 TC はテーブル固有の観点で、T-02 の担保先ではない)
echo "=== TC-11: サマリー列の相互リンクが候補のページ指定を奪わない ==="
INDEX_11='# Wiki Index

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
| [Owner Page](pages/patterns/owner.md) | patterns | thingamajig の話。詳細は [Other Page](pages/heuristics/other.md) を参照 | 2026-06-15T10:00:00+09:00 | high |
'
repo=$(make_query_sandbox tc11 "$INDEX_11")
write_page "$repo" pages/patterns/owner.md '---
title: "Owner Page"
domain: patterns
description: "thingamajig の話"
generated: { by: "rite-wiki-ingest/test", at: "2026-06-15" }
confidence: high
---'
# pages/heuristics/other.md は作らない（サマリー内の相互リンク先を候補にしていないことの検証）
run_query "$repo" --keywords "thingamajig" --format compact
if [ "$QRC" -eq 0 ] \
   && printf '%s' "$QOUT" | grep -q 'Owner Page' \
   && ! printf '%s' "$QERR" | grep -q 'other.md'; then
  pass "TC-11 ページ列の最初のリンクのみを候補にする (サマリー内リンクを読みに行かない)"
else
  fail "TC-11 (rc=$QRC out=$QOUT err=$QERR)"
fi

# --- TC-12: a page larger than the pipe buffer is still readable ---
# Pass 2 reads frontmatter with an awk that exits at the terminator. With a
# `printf | awk` pipeline the writer dies of SIGPIPE mid-write on a large page
# and `set -o pipefail` turns that into rc=141 — a readable page reported as
# unreadable. 128 KB is comfortably past the 64 KB pipe buffer.
echo "=== TC-12: パイプバッファ超のページでも候補が skip されない ==="
INDEX_12='# Wiki Index

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
| [Big Page](pages/patterns/big.md) | patterns | whatsit の大きいページ | 2026-06-15T10:00:00+09:00 | high |
'
repo=$(make_query_sandbox tc12 "$INDEX_12")
mkdir -p "$repo/.rite/wiki/pages/patterns"
{
  printf '%s\n' '---'
  printf '%s\n' 'title: "Big Page"'
  printf '%s\n' 'domain: patterns'
  printf '%s\n' 'description: "whatsit の大きいページ"'
  printf '%s\n' 'generated: { by: "rite-wiki-ingest/test", at: "2026-06-15" }'
  printf '%s\n' 'confidence: high'
  printf '%s\n' '---'
  printf '# body\n'
  # ~128 KB of body after the frontmatter terminator
  for _ in $(seq 1 2000); do
    printf 'padding line to push the body past the pipe buffer boundary xxxxx\n'
  done
} > "$repo/.rite/wiki/pages/patterns/big.md"
run_query "$repo" --keywords "whatsit" --format compact
if [ "$QRC" -eq 0 ] \
   && printf '%s' "$QOUT" | grep -q 'Big Page' \
   && printf '%s' "$QOUT" | grep -q '確信度.*: high' \
   && ! printf '%s' "$QERR" | grep -q 'cannot read frontmatter'; then
  pass "TC-12 大きいページの frontmatter を読めて候補として描画される"
else
  fail "TC-12 (rc=$QRC out=$QOUT err=$QERR)"
fi

# --- TC-13: real-index row shapes, asserted by count parity ---
# The single-line fixtures above all carry plain ASCII titles, which is exactly
# the shape the parser never had trouble with. The live index carries titles with
# parentheses, with brackets, with pipes inside inline code, and summaries that
# quote HTML comment syntax — each of which broke a different part of the parser
# while the suite stayed green. Assert registered-row count == rendered-candidate
# count rather than naming pages: a per-page existence assert cannot see a
# partial loss, which is the failure mode being pinned here.
echo "=== TC-13: 実 index の行形状 (括弧 / 角括弧 / コード内パイプ / コメント引用) を件数 parity で検証 ==="
INDEX_13='# Wiki Index

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
| [absence pin (assert_not_grep) は base 側も pin する](pages/patterns/paren.md) | patterns | doohickey の括弧タイトル | 2026-06-15T10:00:00+09:00 | high |
| [Bash 境界の値は [CONTEXT] sentinel で emit する](pages/patterns/bracket.md) | patterns | doohickey の角括弧タイトル | 2026-06-15T10:00:00+09:00 | high |
| [`cmd > file | true` は no-match と書込失敗を混同する](pages/anti-patterns/codepipe.md) | anti-patterns | doohickey のコード内パイプ | 2026-06-15T10:00:00+09:00 | high |
| [HTML コメントは GFM のテーブル境界を壊す](pages/anti-patterns/htmlcomment.md) | anti-patterns | doohickey の行。`<!-- 行内コメント -->` を引用する | 2026-06-15T10:00:00+09:00 | high |
| [Plain Title](pages/heuristics/plain.md) | heuristics | doohickey の単純行 | 2026-06-15T10:00:00+09:00 | high |
'
repo=$(make_query_sandbox tc13 "$INDEX_13")
for spec in "pages/patterns/paren.md|absence pin (assert_not_grep) は base 側も pin する|patterns" \
            "pages/patterns/bracket.md|Bash 境界の値は [CONTEXT] sentinel で emit する|patterns" \
            "pages/anti-patterns/codepipe.md|cmd > file の罠|anti-patterns" \
            "pages/anti-patterns/htmlcomment.md|HTML コメントは GFM のテーブル境界を壊す|anti-patterns" \
            "pages/heuristics/plain.md|Plain Title|heuristics"; do
  rel="${spec%%|*}"; restspec="${spec#*|}"; ttl="${restspec%%|*}"; dom="${restspec##*|}"
  write_page "$repo" "$rel" "---
title: \"$ttl\"
domain: $dom
description: \"doohickey のページ\"
generated: { by: \"rite-wiki-ingest/test\", at: \"2026-06-15\" }
confidence: high
---"
done
registered=$(grep -c '](pages/' "$repo/.rite/wiki/index.md")
run_query "$repo" --keywords "doohickey" --max-pages 20 --format compact
rendered=$(printf '%s\n' "$QOUT" | grep -c '^#### ')
if [ "$QRC" -eq 0 ] && [ "$registered" -eq 5 ] && [ "$rendered" -eq "$registered" ]; then
  pass "TC-13 登録 $registered 行すべてが候補として描画される (件数 parity)"
else
  fail "TC-13 registered=$registered rendered=$rendered (rc=$QRC err=$QERR)"
fi

# --- TC-14: a row that carries a page link but cannot be parsed is reported ---
# Partial loss must not be silent. The zero-candidate WARNING only fires when
# every row fails, so a row-level counter is what covers the 1-of-N case.
echo "=== TC-14: 解析できない登録行が 1 件でもあれば WARNING で可視化される ==="
INDEX_14='# Wiki Index

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
| [Good Row](pages/patterns/good14.md) | patterns | whozit の正常行 | 2026-06-15T10:00:00+09:00 | high |
| [Bad Row with a raw | pipe outside code](pages/patterns/bad14.md) | patterns | whozit の壊れた行 | 2026-06-15T10:00:00+09:00 | high |
'
repo=$(make_query_sandbox tc14 "$INDEX_14")
write_page "$repo" pages/patterns/good14.md '---
title: "Good Row"
domain: patterns
description: "whozit の正常行"
generated: { by: "rite-wiki-ingest/test", at: "2026-06-15" }
confidence: high
---'
run_query "$repo" --keywords "whozit" --format compact
if [ "$QRC" -eq 0 ] \
   && printf '%s' "$QOUT" | grep -q 'Good Row' \
   && printf '%s' "$QERR" | grep -q '候補になりませんでした'; then
  pass "TC-14 部分脱落が WARNING で可視化され、正常行は描画される"
else
  fail "TC-14 (rc=$QRC out=$QOUT err=$QERR)"
fi

# --- TC-15: the zero-candidate WARNING survives a large index ---
# The guard used to be `printf | sed | grep -q`; grep exits at the first match,
# the writer takes SIGPIPE, and pipefail turned the whole `if` false — so the
# warning went silent exactly on the large indexes that need it. Pin the size.
echo "=== TC-15: パイプバッファ超の index でも 0 件 WARNING が出る ==="
{
  printf '%s\n\n' '# Wiki Index'
  for i in $(seq 1 4000); do
    printf '<div>padding row %s to push the index past the pipe buffer boundary</div>\n' "$i"
  done
  printf '%s\n' '<ul><li><a href="pages/heuristics/html.md">HTML 形式</a> ](pages/heuristics/html.md)</li></ul>'
} > "$TEST_DIR/big_index.md"
repo=$(make_query_sandbox tc15 "$(cat "$TEST_DIR/big_index.md")")
idx_size=$(wc -c < "$repo/.rite/wiki/index.md")
run_query "$repo" --keywords "anything" --format compact
if [ "$QRC" -eq 0 ] \
   && [ "$idx_size" -gt 65536 ] \
   && printf '%s' "$QOUT" | grep -q 'Wiki 経験則は注入されていません' \
   && printf '%s' "$QERR" | grep -q '候補を 1 件も抽出できませんでした'; then
  pass "TC-15 ${idx_size} バイトの index でも 0 件 WARNING が発火する"
else
  fail "TC-15 size=$idx_size (rc=$QRC out=$QOUT err=$QERR)"
fi

# --- TC-16: two links in the page cell — the FIRST one wins ---
# TC-11 puts the second link in the summary cell, which `match(cells[1], ...)`
# never sees, so it passes even if the extraction goes greedy. This one puts
# both links in the page cell, which is the only shape that pins the contract
# the header comment and the wiki-ingest docs both state.
echo "=== TC-16: ページ列に 2 リンクがある行は最初のリンクを候補にする ==="
INDEX_16='# Wiki Index

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
| [First Link](pages/patterns/first.md)（cf. [Second Link](pages/heuristics/second.md)） | patterns | flapdoodle の 2 リンク行 | 2026-06-15T10:00:00+09:00 | high |
'
repo=$(make_query_sandbox tc16 "$INDEX_16")
write_page "$repo" pages/patterns/first.md '---
title: "First Link"
domain: patterns
description: "flapdoodle の 2 リンク行"
generated: { by: "rite-wiki-ingest/test", at: "2026-06-15" }
confidence: high
---'
# pages/heuristics/second.md は作らない（2 つ目に解決したら stale WARNING で露見する）
run_query "$repo" --keywords "flapdoodle" --format compact
if [ "$QRC" -eq 0 ] \
   && printf '%s' "$QOUT" | grep -q 'First Link' \
   && ! printf '%s' "$QERR" | grep -q 'second.md'; then
  pass "TC-16 ページ列の最初のリンクが候補になる (2 つ目を読みに行かない)"
else
  fail "TC-16 (rc=$QRC out=$QOUT err=$QERR)"
fi

# --- TC-17: cell counts on either side of 5 are reported, not dropped ---
# TC-14's fixture splits into 6 cells and fails on the page column, so it never
# exercises the cell-count guard itself. These two rows do: one collapses below
# the contract, one overflows it (an unescaped pipe in the summary would
# otherwise truncate that cell and render a page with half its text missing).
echo "=== TC-17: セル数が 5 でない登録行は両側とも WARNING に載る ==="
INDEX_17='# Wiki Index

## ページ一覧

| ページ | ドメイン | サマリー | 更新日 | 確信度 |
|--------|---------|---------|--------|--------|
| [Fine Row](pages/patterns/fine17.md) | patterns | thingummy の正常行 | 2026-06-15T10:00:00+09:00 | high |
| [Short Row](pages/patterns/short17.md) |
| [Long Row](pages/patterns/long17.md) | patterns | thingummy の A | B という 1 本の文字列 | 2026-06-15T10:00:00+09:00 | high |
'
repo=$(make_query_sandbox tc17 "$INDEX_17")
for rel in fine17 short17 long17; do
  write_page "$repo" "pages/patterns/$rel.md" "---
title: \"$rel\"
domain: patterns
description: \"thingummy のページ\"
generated: { by: \"rite-wiki-ingest/test\", at: \"2026-06-15\" }
confidence: high
---"
done
run_query "$repo" --keywords "thingummy" --max-pages 20 --format compact
rendered17=$(printf '%s\n' "$QOUT" | grep -c '^#### ')
if [ "$QRC" -eq 0 ] \
   && [ "$rendered17" -eq 1 ] \
   && printf '%s' "$QOUT" | grep -q 'Fine Row' \
   && printf '%s' "$QERR" | grep -q '2 行が登録リンク'; then
  pass "TC-17 3 セル未満と 5 セル超の両方が WARNING に載り、正常行だけ描画される"
else
  fail "TC-17 rendered=$rendered17 (rc=$QRC out=$QOUT err=$QERR)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
