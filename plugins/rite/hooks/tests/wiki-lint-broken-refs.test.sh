#!/bin/bash
# wiki-lint-broken-refs.test.sh
#
# Tests for wiki-lint-broken-refs.sh (wiki/lint.md ステップ 7 delegation
# target). The helper extracts Markdown links from each page, resolves them
# page-dir 起点 (realpath -m -s, canonical:
# skills/wiki-lint/references/broken-ref-resolution.md), and emits a marker
# block + broken_refs_read_ok enum + [CONTEXT] sentinel.
# Structure mirrors wiki-lint-skipped-refs.test.sh (6.0 counterpart).
#
# Coverage:
#   TC-1  same_branch 検出 — 有効 link / broken link / 外部 URL / 絶対パス /
#         アンカーのみ / 画像 link / raw 有効 / raw broken の混在 → broken 2 件のみ
#   TC-2  indent 付き code fence 内の link は対象外 (awk fence tracking の改善点)
#   TC-3  インライン code span 内の link 引用は対象外
#   TC-4  separate_branch 検出 (git show 経由)
#   TC-5  ページ読出失敗 → broken_refs_read_ok=io_error (false negative note 用)
#   TC-6  placeholder residue (--branch-strategy "{...}") → exit 1 + marker
#   TC-7  unknown branch_strategy → exit 1
#   TC-8  --branch-strategy 欠落 → exit 2 (invocation error)
#   TC-9  空 stdin → n_broken_refs=0 + 空 marker block
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
SCRIPT="$PLUGIN_ROOT/hooks/scripts/wiki-lint-broken-refs.sh"

if [ ! -x "$SCRIPT" ]; then
  echo "ERROR: helper not executable: $SCRIPT" >&2
  exit 1
fi

TEST_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

# wiki-lint-broken-refs.sh hard-requires GNU `realpath -m -s` (a documented known
# limitation) and fails fast with exit 1 on BSD/macOS. The detection TCs are
# unrunnable there by design, so guard them; the arg-validation TCs (TC-6/7/8)
# exit before the realpath gate and stay platform-agnostic .
if realpath -m -s -- / >/dev/null 2>&1; then HAS_GNU_REALPATH=1; else HAS_GNU_REALPATH=0; fi

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ FAIL: $1"; }
# Skips are counted so a platform-gated green states how many assertions never ran
# (the governing rationale review G-04). Same shape as _test-helpers.sh skip().
SKIP=0
skip() { SKIP=$((SKIP + 1)); echo "  ⏭️ SKIP: $1"; }

# The probe above is a capability check, not a platform check: `realpath` missing
# or shadowed on a Linux host would skip TC-1..TC-5 and TC-9 and still exit 0,
# leaving the blocking gate with only the arg-validation TCs. Require the probe to
# succeed where the gate actually blocks. `[ -d /proc ]` rather than `uname -s`
# because `uname` resolves through the same PATH that would be hiding `realpath`.
if [ -d /proc ] && [ "$HAS_GNU_REALPATH" != 1 ]; then
  fail "HAS_GNU_REALPATH probe: GNU 'realpath -m -s' unavailable on Linux (missing or shadowed on PATH?) — the broken-refs detection TCs must never be skipped on the blocking gate"
fi

# page A: 検査対象。有効 / broken / 除外対象の link を混在させる
PAGE_A='---
title: "A"
---
有効: [B](../heuristics/b.md) と [B anchor](../heuristics/b.md#sec)
broken: [missing](../patterns/missing.md)
外部: [ext](https://example.com/x.md) / [ext2](http://example.com)
絶対: [abs](/etc/passwd)
アンカーのみ: [self](#section)
画像: ![img](../assets/img.png)
raw 有効: [raw ok](../../raw/reviews/r1.md)
raw broken: [raw ng](../../raw/reviews/missing.md)
'

# page B: 被参照側 (link なし)
PAGE_B='---
title: "B"
---
本文のみ
'

# page C: indent fence + インライン code span 内の link 引用のみ (broken 0 件であるべき)
PAGE_C='---
title: "C"
---
- list 項目:
  ```bash
  cat [fenced](../patterns/in-fence-missing.md)
  ```
説明文中の引用: `[desc](../patterns/in-span-missing.md)` は抽出対象外
'

PAGES_LIST='.rite/wiki/pages/patterns/a.md
.rite/wiki/pages/heuristics/b.md
.rite/wiki/pages/heuristics/c.md'

RAW_LIST='.rite/wiki/raw/reviews/r1.md'

stdin_input() {
  printf '%s\n---\n%s\n' "$PAGES_LIST" "$RAW_LIST"
}

write_fixtures() {
  local root="$1"
  mkdir -p "$root/.rite/wiki/pages/patterns" "$root/.rite/wiki/pages/heuristics" "$root/.rite/wiki/raw/reviews"
  printf '%s' "$PAGE_A" > "$root/.rite/wiki/pages/patterns/a.md"
  printf '%s' "$PAGE_B" > "$root/.rite/wiki/pages/heuristics/b.md"
  printf '%s' "$PAGE_C" > "$root/.rite/wiki/pages/heuristics/c.md"
  printf -- '---\ningested: true\n---\nraw\n' > "$root/.rite/wiki/raw/reviews/r1.md"
}

make_same_branch_sandbox() {
  local name="$1"
  local repo="$TEST_DIR/$name"
  mkdir -p "$repo"
  (cd "$repo" && git init -q -b main . 2>/dev/null)
  write_fixtures "$repo"
  echo "$repo"
}

make_separate_branch_sandbox() {
  local name="$1"
  local repo="$TEST_DIR/$name"
  git init -q -b main "$repo"
  (
    cd "$repo" || exit 1
    git config user.email "test@example.com"
    git config user.name "Test"
    echo base > base.txt
    git add base.txt && git commit -qm "init"
    git checkout -q --orphan wiki
    git rm -qrf . 2>/dev/null || true
    write_fixtures "."
    git add .rite && git commit -qm "wiki pages"
    git checkout -q main
    rm -rf .rite
  )
  echo "$repo"
}

run_helper() {
  local repo="$1" input="$2"; shift 2
  local rc=0
  HELPER_STDOUT=$( (cd "$repo" && printf '%s' "$input" | _timeout 10 bash "$SCRIPT" --repo-root "$repo" "$@") 2>"$TEST_DIR/helper_stderr" ) || rc=$?
  HELPER_RC=$rc
  HELPER_STDERR=$(cat "$TEST_DIR/helper_stderr")
  return 0
}

if [ "$HAS_GNU_REALPATH" = 1 ]; then
echo "=== TC-1: same_branch 検出 (broken 2 件のみ、除外対象は非検出) ==="
repo=$(make_same_branch_sandbox tc1)
run_helper "$repo" "$(stdin_input)" --branch-strategy same_branch
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'n_broken_refs=2' \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx '\.rite/wiki/pages/patterns/a\.md|\.\./patterns/missing\.md' \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx '\.rite/wiki/pages/patterns/a\.md|\.\./\.\./raw/reviews/missing\.md' \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'broken_refs_read_ok=true' \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx '\[CONTEXT\] WIKI_LINT_BROKEN_REFS=2'; then
  pass "TC-1 broken 2 件のみ検出 + enum/sentinel emit"
else
  fail "TC-1 (rc=$HELPER_RC stdout=$HELPER_STDOUT)"
fi

echo "=== TC-2/TC-3: indent fence + インライン code span 内 link は対象外 ==="
if ! printf '%s\n' "$HELPER_STDOUT" | grep -q 'in-fence-missing' \
   && ! printf '%s\n' "$HELPER_STDOUT" | grep -q 'in-span-missing'; then
  pass "TC-2/TC-3 fence / code span 内の link 引用は非検出"
else
  fail "TC-2/TC-3 (stdout=$HELPER_STDOUT)"
fi

echo "=== TC-4: separate_branch 検出 (git show 経由、working tree に .rite なし) ==="
repo=$(make_separate_branch_sandbox tc4)
run_helper "$repo" "$(stdin_input)" --branch-strategy separate_branch --wiki-branch wiki
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'n_broken_refs=2' \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'broken_refs_read_ok=true'; then
  pass "TC-4 separate_branch で broken 検出"
else
  fail "TC-4 (rc=$HELPER_RC stdout=$HELPER_STDOUT)"
fi

echo "=== TC-5: ページ読出失敗 → io_error ==="
repo=$(make_same_branch_sandbox tc5)
rm "$repo/.rite/wiki/pages/heuristics/c.md"
run_helper "$repo" "$(stdin_input)" --branch-strategy same_branch
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'broken_refs_read_ok=io_error' \
   && printf '%s\n' "$HELPER_STDERR" | grep -q 'c.md を読み出せません'; then
  pass "TC-5 io_error 降格 + WARNING"
else
  fail "TC-5 (rc=$HELPER_RC stdout=$HELPER_STDOUT stderr=$HELPER_STDERR)"
fi
else
  skip "TC-1..TC-5 skipped (GNU 'realpath -m -s' absent; broken-refs detection is a no-op here by design)"
  # TC-6/7/8 (arg validation) still run — they exit before the realpath gate —
  # but need a valid $repo to cd into (the detection TCs above normally set it).
  repo=$(make_same_branch_sandbox tc_argval)
fi

echo "=== TC-6: placeholder residue (--branch-strategy) → exit 1 ==="
run_helper "$repo" "" --branch-strategy "{branch_strategy}"
if [ "$HELPER_RC" -eq 1 ] && printf '%s\n' "$HELPER_STDERR" | grep -q 'LINT_PHASE_7_PLACEHOLDER_RESIDUE=1'; then
  pass "TC-6 exit 1 + residue marker"
else
  fail "TC-6 (rc=$HELPER_RC stderr=$HELPER_STDERR)"
fi

echo "=== TC-7: unknown branch_strategy → exit 1 ==="
run_helper "$repo" "" --branch-strategy bogus
if [ "$HELPER_RC" -eq 1 ] && printf '%s\n' "$HELPER_STDERR" | grep -q "未知の branch_strategy 値"; then
  pass "TC-7 exit 1 + 未知値メッセージ"
else
  fail "TC-7 (rc=$HELPER_RC stderr=$HELPER_STDERR)"
fi

echo "=== TC-8: --branch-strategy 欠落 → exit 2 ==="
run_helper "$repo" ""
if [ "$HELPER_RC" -eq 2 ]; then
  pass "TC-8 exit 2"
else
  fail "TC-8 (rc=$HELPER_RC)"
fi

if [ "$HAS_GNU_REALPATH" = 1 ]; then
echo "=== TC-9: 空 stdin → n_broken_refs=0 + 空 marker block ==="
run_helper "$repo" "" --branch-strategy same_branch
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'n_broken_refs=0' \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx -- '---broken_refs_begin---' \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx -- '---broken_refs_end---' \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx '\[CONTEXT\] WIKI_LINT_BROKEN_REFS=0'; then
  pass "TC-9 空入力で 0 件 + marker block 維持"
else
  fail "TC-9 (rc=$HELPER_RC stdout=$HELPER_STDOUT)"
fi
else
  skip "TC-9 skipped (GNU 'realpath -m -s' absent; broken-refs is a no-op here by design)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed$( [ "$SKIP" -gt 0 ] && printf ", %s skipped" "$SKIP" )"
[ "$FAIL" -eq 0 ] || exit 1
