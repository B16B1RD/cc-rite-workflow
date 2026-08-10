#!/bin/bash
# wiki-lint-orphans.test.sh
#
# Tests for wiki-lint-orphans.sh (wiki/lint.md ステップ 5 delegation target).
# The helper reads index.md per branch strategy, extracts registered page
# links, diffs against pages_list (stdin), and emits a marker block +
# orphan_check_ok enum + [CONTEXT] sentinel.
# Structure mirrors wiki-lint-skipped-refs.test.sh (6.0 counterpart).
#
# Coverage:
#   TC-1  same_branch 検出 (登録 2 / 実在 3 → orphan 1。./pages/ 形式 link も登録扱い)
#   TC-2  index.md 不在 → orphan_check_ok=index_unreadable + n_orphans=0
#   TC-3  index.md にページ link なし → orphan_check_ok=index_empty + n_orphans=0
#   TC-4  separate_branch 検出 (git show 経由)
#   TC-5  placeholder residue (--branch-strategy "{...}") → exit 1 + marker
#   TC-6  unknown branch_strategy → exit 1
#   TC-7  --branch-strategy 欠落 → exit 2 (invocation error)
#   TC-8  空 stdin (index 有効) → n_orphans=0 + orphan_check_ok=true
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
SCRIPT="$PLUGIN_ROOT/hooks/scripts/wiki-lint-orphans.sh"

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

# index.md フィクスチャ: pages/ 形式と ./pages/ 形式の両方で 2 ページを登録
INDEX_FIXTURE='# Wiki Index

## ページ一覧

| タイトル | パス |
|---------|------|
| [Pattern A](pages/patterns/a.md) | patterns |
| [Heuristic B](./pages/heuristics/b.md) | heuristics |
'

PAGES_3='.rite/wiki/pages/patterns/a.md
.rite/wiki/pages/heuristics/b.md
.rite/wiki/pages/anti-patterns/orphan.md'

make_same_branch_sandbox() {
  local name="$1" with_index="$2" index_content="${3:-$INDEX_FIXTURE}"
  local repo="$TEST_DIR/$name"
  mkdir -p "$repo/.rite/wiki"
  (cd "$repo" && git init -q -b main . 2>/dev/null)
  if [ "$with_index" = "1" ]; then
    printf '%s' "$index_content" > "$repo/.rite/wiki/index.md"
  fi
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
    mkdir -p .rite/wiki
    printf '%s' "$INDEX_FIXTURE" > .rite/wiki/index.md
    git add .rite/wiki/index.md && git commit -qm "wiki index"
    git checkout -q main
  )
  echo "$repo"
}

run_helper() {
  local repo="$1" input="$2"; shift 2
  local rc=0
  HELPER_STDOUT=$( (cd "$repo" && printf '%s\n' "$input" | _timeout 10 bash "$SCRIPT" --repo-root "$repo" "$@") 2>"$TEST_DIR/helper_stderr" ) || rc=$?
  HELPER_RC=$rc
  HELPER_STDERR=$(cat "$TEST_DIR/helper_stderr")
  return 0
}

echo "=== TC-1: same_branch 検出 (登録 2 / 実在 3 → orphan 1) ==="
repo=$(make_same_branch_sandbox tc1 1)
run_helper "$repo" "$PAGES_3" --branch-strategy same_branch
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'n_orphans=1' \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx '\.rite/wiki/pages/anti-patterns/orphan\.md' \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'orphan_check_ok=true' \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx '\[CONTEXT\] WIKI_LINT_ORPHANS=1'; then
  pass "TC-1 orphan 1 件のみ検出 (./pages/ 形式 link も登録扱い) + enum/sentinel emit"
else
  fail "TC-1 (rc=$HELPER_RC stdout=$HELPER_STDOUT)"
fi

echo "=== TC-2: index.md 不在 → index_unreadable ==="
repo=$(make_same_branch_sandbox tc2 0)
run_helper "$repo" "$PAGES_3" --branch-strategy same_branch
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'n_orphans=0' \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'orphan_check_ok=index_unreadable' \
   && printf '%s\n' "$HELPER_STDERR" | grep -q '読み出せません'; then
  pass "TC-2 index_unreadable + n_orphans=0 + WARNING"
else
  fail "TC-2 (rc=$HELPER_RC stdout=$HELPER_STDOUT stderr=$HELPER_STDERR)"
fi

echo "=== TC-3: index.md にページ link なし → index_empty ==="
repo=$(make_same_branch_sandbox tc3 1 '# Wiki Index

(まだページはありません)
')
run_helper "$repo" "$PAGES_3" --branch-strategy same_branch
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'n_orphans=0' \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'orphan_check_ok=index_empty' \
   && printf '%s\n' "$HELPER_STDERR" | grep -q '抽出できませんでした'; then
  pass "TC-3 index_empty + 全ページ orphan 誤検出なし"
else
  fail "TC-3 (rc=$HELPER_RC stdout=$HELPER_STDOUT stderr=$HELPER_STDERR)"
fi

echo "=== TC-4: separate_branch 検出 (git show 経由) ==="
repo=$(make_separate_branch_sandbox tc4)
run_helper "$repo" "$PAGES_3" --branch-strategy separate_branch --wiki-branch wiki
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'n_orphans=1' \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx '\.rite/wiki/pages/anti-patterns/orphan\.md'; then
  pass "TC-4 separate_branch で orphan 検出"
else
  fail "TC-4 (rc=$HELPER_RC stdout=$HELPER_STDOUT)"
fi

echo "=== TC-5: placeholder residue (--branch-strategy) → exit 1 ==="
run_helper "$repo" "" --branch-strategy "{branch_strategy}"
if [ "$HELPER_RC" -eq 1 ] && printf '%s\n' "$HELPER_STDERR" | grep -q 'LINT_PHASE_5_PLACEHOLDER_RESIDUE=1'; then
  pass "TC-5 exit 1 + residue marker"
else
  fail "TC-5 (rc=$HELPER_RC stderr=$HELPER_STDERR)"
fi

echo "=== TC-6: unknown branch_strategy → exit 1 ==="
run_helper "$repo" "" --branch-strategy bogus
if [ "$HELPER_RC" -eq 1 ] && printf '%s\n' "$HELPER_STDERR" | grep -q "未知の branch_strategy 値"; then
  pass "TC-6 exit 1 + 未知値メッセージ"
else
  fail "TC-6 (rc=$HELPER_RC stderr=$HELPER_STDERR)"
fi

echo "=== TC-7: --branch-strategy 欠落 → exit 2 ==="
run_helper "$repo" ""
if [ "$HELPER_RC" -eq 2 ]; then
  pass "TC-7 exit 2"
else
  fail "TC-7 (rc=$HELPER_RC)"
fi

echo "=== TC-8: 空 stdin (index 有効) → n_orphans=0 + orphan_check_ok=true ==="
repo=$(make_same_branch_sandbox tc8 1)
run_helper "$repo" "" --branch-strategy same_branch
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'n_orphans=0' \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'orphan_check_ok=true' \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx '\[CONTEXT\] WIKI_LINT_ORPHANS=0'; then
  pass "TC-8 空入力で 0 件 + true enum"
else
  fail "TC-8 (rc=$HELPER_RC stdout=$HELPER_STDOUT)"
fi

echo "=== TC-9: OKF 箇条書き index (Sub-2 reshape) でも orphan 検出 (登録 2 / 実在 3 → orphan 1) ==="
# the governing rationale: index.md がテーブル → OKF 箇条書き (`* [title](pages/...) - desc`) に
# reshape されてもリンク grep `](pages/...)` が生存し orphan 検出が機能することを検証する。
INDEX_FIXTURE_BULLET='# Wiki Index

* [Pattern A](pages/patterns/a.md) - Pattern A の説明
* [Heuristic B](./pages/heuristics/b.md) - Heuristic B の説明
'
repo=$(make_same_branch_sandbox tc9 1 "$INDEX_FIXTURE_BULLET")
run_helper "$repo" "$PAGES_3" --branch-strategy same_branch
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'n_orphans=1' \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx '\.rite/wiki/pages/anti-patterns/orphan\.md' \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'orphan_check_ok=true'; then
  pass "TC-9 OKF 箇条書き形式でも orphan 1 件のみ検出 (./pages/ 形式 link も登録扱い)"
else
  fail "TC-9 (rc=$HELPER_RC stdout=$HELPER_STDOUT)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
