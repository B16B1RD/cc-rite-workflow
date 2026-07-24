#!/bin/bash
# wiki-lint-stale.test.sh
#
# Tests for wiki-lint-stale.sh (wiki/lint.md ステップ 4 delegation target).
# The helper compares each page's `updated` frontmatter against the cutoff
# and emits a marker block + stale_check_ok enum + [CONTEXT] sentinel.
# Structure mirrors wiki-lint-skipped-refs.test.sh (6.0 counterpart).
#
# Coverage:
#   TC-1  same_branch 検出 (stale 1 + fresh 1 + updated 欠落 1 + パース不能 1 → n_stale=1)
#   TC-2  separate_branch 検出 (git show 経由)
#   TC-3  --stale-days 境界 (大きい閾値 → 0 件)
#   TC-4  placeholder residue (--branch-strategy "{...}") → exit 1 + marker
#   TC-5  placeholder residue (--wiki-branch "{...}") → exit 1
#   TC-6  unknown branch_strategy → exit 1
#   TC-7  --branch-strategy 欠落 → exit 2 (invocation error)
#   TC-8  separate_branch + 空 --wiki-branch → exit 2 (invocation error)
#   TC-9  空 stdin → n_stale=0 + 空 marker block + stale_check_ok=true
#   TC-10 --stale-days 非整数 → exit 2
#
# NOT covered (environment-dependent): GNU date 非互換環境の skipped_no_gnu_date
# 経路 (CI/dev は GNU 環境前提。経路自体は reading で検証済みの単純 early-return)。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
SCRIPT="$PLUGIN_ROOT/hooks/scripts/wiki-lint-stale.sh"

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

# ページフィクスチャ: stale (2020 年) / fresh (現在) / updated 欠落 / パース不能
make_page() {
  local path="$1" updated="$2"
  mkdir -p "$(dirname "$path")"
  if [ "$updated" = "__none__" ]; then
    printf -- '---\ntitle: "t"\n---\nbody\n' > "$path"
  else
    printf -- '---\ntitle: "t"\nupdated: "%s"\n---\nbody\n' "$updated" > "$path"
  fi
}

FRESH_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

make_same_branch_sandbox() {
  local name="$1"
  local repo="$TEST_DIR/$name"
  mkdir -p "$repo/.rite/wiki/pages/patterns"
  (cd "$repo" && git init -q -b main . 2>/dev/null)
  make_page "$repo/.rite/wiki/pages/patterns/stale.md" "2020-01-01T00:00:00Z"
  make_page "$repo/.rite/wiki/pages/patterns/fresh.md" "$FRESH_TS"
  make_page "$repo/.rite/wiki/pages/patterns/no-updated.md" "__none__"
  make_page "$repo/.rite/wiki/pages/patterns/bad-date.md" "not-a-date"
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
    make_page ".rite/wiki/pages/patterns/stale.md" "2020-01-01T00:00:00Z"
    make_page ".rite/wiki/pages/patterns/fresh.md" "$FRESH_TS"
    git add .rite && git commit -qm "wiki pages"
    git checkout -q main
  )
  echo "$repo"
}

PAGES_4='.rite/wiki/pages/patterns/stale.md
.rite/wiki/pages/patterns/fresh.md
.rite/wiki/pages/patterns/no-updated.md
.rite/wiki/pages/patterns/bad-date.md'

PAGES_2='.rite/wiki/pages/patterns/stale.md
.rite/wiki/pages/patterns/fresh.md'

run_helper() {
  local repo="$1" input="$2"; shift 2
  local rc=0
  HELPER_STDOUT=$( (cd "$repo" && printf '%s\n' "$input" | _timeout 10 bash "$SCRIPT" --repo-root "$repo" "$@") 2>"$TEST_DIR/helper_stderr" ) || rc=$?
  HELPER_RC=$rc
  HELPER_STDERR=$(cat "$TEST_DIR/helper_stderr")
  return 0
}

echo "=== TC-1: same_branch 検出 (stale 1 / fresh 1 / 欠落 1 / パース不能 1) ==="
repo=$(make_same_branch_sandbox tc1)
run_helper "$repo" "$PAGES_4" --branch-strategy same_branch
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'n_stale=1' \
   && printf '%s\n' "$HELPER_STDOUT" | grep -q '^\.rite/wiki/pages/patterns/stale\.md|2020-01-01T00:00:00Z|' \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'stale_check_ok=true' \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx '\[CONTEXT\] WIKI_LINT_STALE=1'; then
  pass "TC-1 stale 1 件のみ検出 + enum/sentinel emit"
else
  fail "TC-1 (rc=$HELPER_RC stdout=$HELPER_STDOUT)"
fi
if printf '%s\n' "$HELPER_STDERR" | grep -q 'no-updated.md に updated フィールドが存在しません' \
   && printf '%s\n' "$HELPER_STDERR" | grep -q "bad-date.md の updated フィールド 'not-a-date' をパースできません"; then
  pass "TC-1 欠落 / パース不能の WARNING を stderr に emit"
else
  fail "TC-1 WARNING (stderr=$HELPER_STDERR)"
fi

echo "=== TC-2: separate_branch 検出 (git show 経由) ==="
repo=$(make_separate_branch_sandbox tc2)
run_helper "$repo" "$PAGES_2" --branch-strategy separate_branch --wiki-branch wiki
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'n_stale=1' \
   && printf '%s\n' "$HELPER_STDOUT" | grep -q '^\.rite/wiki/pages/patterns/stale\.md|'; then
  pass "TC-2 separate_branch で stale 検出"
else
  fail "TC-2 (rc=$HELPER_RC stdout=$HELPER_STDOUT)"
fi

echo "=== TC-3: --stale-days 境界 (巨大閾値 → 0 件) ==="
repo=$(make_same_branch_sandbox tc3)
run_helper "$repo" "$PAGES_2" --branch-strategy same_branch --stale-days 36500
if [ "$HELPER_RC" -eq 0 ] && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'n_stale=0'; then
  pass "TC-3 閾値内は 0 件"
else
  fail "TC-3 (rc=$HELPER_RC stdout=$HELPER_STDOUT)"
fi

echo "=== TC-4: placeholder residue (--branch-strategy) → exit 1 ==="
repo=$(make_same_branch_sandbox tc4)
run_helper "$repo" "" --branch-strategy "{branch_strategy}"
if [ "$HELPER_RC" -eq 1 ] && printf '%s\n' "$HELPER_STDERR" | grep -q 'LINT_PHASE_4_PLACEHOLDER_RESIDUE=1'; then
  pass "TC-4 exit 1 + residue marker"
else
  fail "TC-4 (rc=$HELPER_RC stderr=$HELPER_STDERR)"
fi

echo "=== TC-5: placeholder residue (--wiki-branch) → exit 1 ==="
run_helper "$repo" "" --branch-strategy separate_branch --wiki-branch "{wiki_branch}"
if [ "$HELPER_RC" -eq 1 ]; then
  pass "TC-5 exit 1"
else
  fail "TC-5 (rc=$HELPER_RC)"
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

echo "=== TC-8: separate_branch + 空 --wiki-branch → exit 2 ==="
run_helper "$repo" "" --branch-strategy separate_branch
if [ "$HELPER_RC" -eq 2 ]; then
  pass "TC-8 exit 2"
else
  fail "TC-8 (rc=$HELPER_RC)"
fi

echo "=== TC-9: 空 stdin → n_stale=0 + 空 marker block ==="
run_helper "$repo" "" --branch-strategy same_branch
if [ "$HELPER_RC" -eq 0 ] \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx 'n_stale=0' \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx -- '---stale_pages_begin---' \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx -- '---stale_pages_end---' \
   && printf '%s\n' "$HELPER_STDOUT" | grep -qx '\[CONTEXT\] WIKI_LINT_STALE=0'; then
  pass "TC-9 空入力で 0 件 + marker block 維持"
else
  fail "TC-9 (rc=$HELPER_RC stdout=$HELPER_STDOUT)"
fi

echo "=== TC-10: --stale-days 非整数 → exit 2 ==="
run_helper "$repo" "" --branch-strategy same_branch --stale-days abc
if [ "$HELPER_RC" -eq 2 ]; then
  pass "TC-10 exit 2"
else
  fail "TC-10 (rc=$HELPER_RC)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
