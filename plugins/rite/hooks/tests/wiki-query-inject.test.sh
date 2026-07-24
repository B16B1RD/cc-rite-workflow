#!/usr/bin/env bash
# Test: wiki-query-inject.sh — OKF v0.1 2-pass query (Issue #1519, Sub-2)
#
# Covers the Issue #1519 Test Spec rows that the 2-pass rewrite introduces:
#   TC-1 (T-03/T-04) keyword match returns the page with frontmatter-derived metadata
#   TC-2 (T-05)      confidence weighting (high > low) ordering is preserved
#   TC-3 (T-08)      a candidate whose page is unreadable is skipped non-blocking
#                    (WARNING + exit 0, the remaining candidate still renders)
#   TC-4 (T-09)      an index with no bullet candidates yields empty output, exit 0
#   TC-5 (F-01)      a bullet example inside an HTML comment is NOT parsed as a
#                    candidate (no phantom "index.md may be stale" WARNING)
set -uo pipefail

# _timeout <seconds> <command...> — portable timeout(1) for this test (Issue #2008).
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
      # Reject rather than degrade.
      die "_timeout: fractional seconds are not supported by the perl fallback: $d\n" unless $d =~ /^[0-9]+$/;
      my $pid = fork;
      exit 127 unless defined $pid;
      if ($pid == 0) { exec { $ARGV[0] } @ARGV; exit 127; }
      $SIG{ALRM} = sub { kill "TERM", $pid; waitpid($pid, 0); exit 124; };
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
updated: "2026-06-15"
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
updated: "2026-06-15"
confidence: high
---'
write_page "$repo" pages/patterns/lo.md '---
title: "Low Page"
domain: patterns
description: "widget の低信頼"
updated: "2026-06-10"
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
updated: "2026-06-15"
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
updated: "2026-06-15"
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

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
