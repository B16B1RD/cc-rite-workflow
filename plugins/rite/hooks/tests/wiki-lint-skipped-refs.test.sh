#!/bin/bash
# wiki-lint-skipped-refs.test.sh
#
# Tests for wiki-lint-skipped-refs.sh (wiki/lint.md ステップ 6.0 delegation
# target). Issue #1520 (Sub-3): the skip SoT moved from log.md (a table) to each
# raw source's frontmatter (`ingest_status: skipped`). The helper now scans
# `.rite/wiki/raw/**/*.md` frontmatter and emits the `skipped_refs` set
# (`raw/{type}/{filename}`) inside a marker block + a 4-value `log_read_ok` enum
# (enum name retained for the lint.md stdout contract; value reflects the raw
# scan). Structure mirrors wiki-lint-source-refs.test.sh (6.2 counterpart).
#
# Coverage:
#   TC-1  same_branch 抽出 (ingest_status:skipped 抽出 / 引用符許容 / sort 整列 / raw/{type}/{file} 形式)
#   TC-2  same_branch raw ディレクトリ不在 (legitimate absence) → log_read_ok=absent, 空集合
#   TC-3  skipped 0 件 (ingest_status 欠落の raw のみ = AC-6 後方互換) → count=0 + read_ok=true
#   TC-4  placeholder residue (--branch-strategy "{...}") → exit 1 + LINT_PHASE_6_0_PLACEHOLDER_RESIDUE marker
#   TC-5  placeholder residue (--wiki-branch "{...}") → exit 1
#   TC-6  unknown branch_strategy → exit 1
#   TC-7  separate_branch 抽出 (git ls-tree + git show)
#   TC-8  separate_branch 既存 branch + raw tree 不在 (ls-tree 成功・空) → log_read_ok=true
#   TC-9  --branch-strategy 欠落 → exit 2 (invocation error)
#   TC-10 separate_branch + 空 --wiki-branch → exit 2 (invocation error)
#   TC-11 値なしフラグ末尾 → no-hang (timeout ガード)
#   TC-12 same_branch io_error (raw が directory でなくファイル → find 失敗) → log_read_ok=io_error
#   TC-13 separate_branch 不在 wiki branch → log_read_ok=absent (raw 無し = 妥当)
#   TC-14 separate_branch io_error (fault injection: chmod 000 .git/objects → ls-tree 失敗) → io_error
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
SCRIPT="$PLUGIN_ROOT/hooks/scripts/wiki-lint-skipped-refs.sh"

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

# Write a raw source with the given frontmatter (+ trivial body) under
# .rite/wiki/raw/ in $root.
write_raw() {
  local root="$1" relpath="$2" frontmatter="$3"
  mkdir -p "$root/$(dirname "$relpath")"
  { printf '%s\n' "$frontmatter"; printf '本文\n'; } > "$root/$relpath"
}

# Populate the standard raw fixture set under $root (.rite/wiki working tree):
#   raw/fixes/skip1.md   → ingest_status: skipped         (counted)
#   raw/reviews/skip2.md → ingest_status: "skipped" (引用符) (counted)
#   raw/reviews/done.md  → ingested:true, no ingest_status  (AC-6 excluded)
populate_raw_fixtures() {
  local root="$1"
  write_raw "$root" .rite/wiki/raw/fixes/skip1.md '---
type: fixes
ingested: true
ingest_status: skipped
skip_reason: "価値なし"
---'
  write_raw "$root" .rite/wiki/raw/reviews/skip2.md '---
type: reviews
ingested: true
ingest_status: "skipped"
skip_reason: "重複"
---'
  write_raw "$root" .rite/wiki/raw/reviews/done.md '---
type: reviews
ingested: true
---'
}

make_same_branch_sandbox() {
  local name="$1" with_raw="$2"
  local repo="$TEST_DIR/$name"
  mkdir -p "$repo/.rite/wiki"
  (cd "$repo" && git init -q -b main . 2>/dev/null)
  [ "$with_raw" = "1" ] && populate_raw_fixtures "$repo"
  echo "$repo"
}

make_separate_branch_sandbox() {
  local name="$1" with_raw="$2"
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
    if [ "$with_raw" = "1" ]; then
      populate_raw_fixtures "$repo"
      git add .rite/wiki/raw && git commit -qm "wiki raw"
    else
      git commit -q --allow-empty -m "empty wiki"
    fi
    git checkout -q main
  )
  echo "$repo"
}

run_helper() {
  local repo="$1"; shift
  local rc=0
  HELPER_STDOUT=$( (cd "$repo" && _timeout 10 bash "$SCRIPT" --repo-root "$repo" "$@") 2>"$TEST_DIR/helper_stderr" ) || rc=$?
  HELPER_RC=$rc
  HELPER_STDERR=$(cat "$TEST_DIR/helper_stderr")
  return 0
}

echo "=== wiki-lint-skipped-refs.sh tests (raw frontmatter scan, Issue #1520) ==="
echo ""

# === TC-1: same_branch 抽出 ===
echo "TC-1: same_branch 抽出 (ingest_status:skipped / 引用符許容 / sort 整列 / raw 形式)"
repo=$(make_same_branch_sandbox tc1 1)
run_helper "$repo" --branch-strategy same_branch --wiki-branch wiki
expected_block='skipped_refs_count=2
---skipped_refs_begin---
raw/fixes/skip1.md
raw/reviews/skip2.md
---skipped_refs_end---
log_read_ok=true'
if [ "$HELPER_RC" = "0" ] && [ "$HELPER_STDOUT" = "$expected_block" ]; then
  pass "count=2 / 引用符 skipped 含む / done.md (ingest_status 欠落) 除外 / read_ok=true"
else
  fail "unexpected (rc=$HELPER_RC): $HELPER_STDOUT"
fi

# === TC-2: same_branch raw 不在 → absent ===
echo "TC-2: same_branch legitimate absence (raw dir なし)"
repo=$(make_same_branch_sandbox tc2 0)
run_helper "$repo" --branch-strategy same_branch --wiki-branch wiki
if [ "$HELPER_RC" = "0" ] && grep -q '^log_read_ok=absent$' <<<"$HELPER_STDOUT" && grep -q '^skipped_refs_count=0$' <<<"$HELPER_STDOUT"; then
  pass "absent + 空集合 + exit 0"
else
  fail "unexpected (rc=$HELPER_RC): $HELPER_STDOUT"
fi

# === TC-3: skipped 0 件 (AC-6 後方互換) → count=0 + read_ok=true ===
echo "TC-3: ingest_status 欠落の raw のみ (AC-6 後方互換) → 0 件"
repo=$(make_same_branch_sandbox tc3 0)
write_raw "$repo" .rite/wiki/raw/reviews/a.md '---
type: reviews
ingested: true
---'
run_helper "$repo" --branch-strategy same_branch --wiki-branch wiki
if [ "$HELPER_RC" = "0" ] && grep -q '^skipped_refs_count=0$' <<<"$HELPER_STDOUT" && grep -q '^log_read_ok=true$' <<<"$HELPER_STDOUT"; then
  pass "count=0 + 空 marker block + read_ok=true (ingest_status 欠落は非 skip)"
else
  fail "unexpected (rc=$HELPER_RC): $HELPER_STDOUT"
fi

# === TC-4: placeholder residue (branch_strategy) → exit 1 + sentinel ===
echo "TC-4: placeholder residue (branch_strategy)"
repo=$(make_same_branch_sandbox tc4 1)
run_helper "$repo" --branch-strategy "{branch_strategy}" --wiki-branch wiki
if [ "$HELPER_RC" = "1" ] && grep -q 'LINT_PHASE_6_0_PLACEHOLDER_RESIDUE=1' <<<"$HELPER_STDERR"; then
  pass "exit 1 + LINT_PHASE_6_0_PLACEHOLDER_RESIDUE sentinel"
else
  fail "unexpected (rc=$HELPER_RC): $HELPER_STDERR"
fi

# === TC-5: placeholder residue (wiki_branch) → exit 1 ===
echo "TC-5: placeholder residue (wiki_branch)"
repo=$(make_same_branch_sandbox tc5 1)
run_helper "$repo" --branch-strategy separate_branch --wiki-branch "{wiki_branch}"
if [ "$HELPER_RC" = "1" ] && grep -q '{wiki_branch} placeholder が literal substitute されていません' <<<"$HELPER_STDERR"; then
  pass "exit 1 + wiki_branch residue error"
else
  fail "unexpected (rc=$HELPER_RC): $HELPER_STDERR"
fi

# === TC-6: unknown branch_strategy → exit 1 ===
echo "TC-6: unknown branch_strategy"
repo=$(make_same_branch_sandbox tc6 1)
run_helper "$repo" --branch-strategy bogus --wiki-branch wiki
if [ "$HELPER_RC" = "1" ] && grep -q "未知の branch_strategy 値を検出しました: 'bogus' (ステップ 6.0)" <<<"$HELPER_STDERR"; then
  pass "exit 1 + 未知値メッセージ"
else
  fail "unexpected (rc=$HELPER_RC): $HELPER_STDERR"
fi

# === TC-7: separate_branch 抽出 (git ls-tree + git show) ===
# TC-1 (same_branch) と同じ exact block を pin し、separate_branch 固有の path 正規化
# (${f#.rite/wiki/}) を経た ref prefix 形式 (raw/{type}/{file}) まで検証する。count のみだと
# ref 形式の regression をこの読出機構 (ls-tree+show) では検出できないため。
echo "TC-7: separate_branch 抽出 (exact block で ref 形式も検証)"
repo=$(make_separate_branch_sandbox tc7 1)
run_helper "$repo" --branch-strategy separate_branch --wiki-branch wiki
expected_block='skipped_refs_count=2
---skipped_refs_begin---
raw/fixes/skip1.md
raw/reviews/skip2.md
---skipped_refs_end---
log_read_ok=true'
if [ "$HELPER_RC" = "0" ] && [ "$HELPER_STDOUT" = "$expected_block" ]; then
  pass "git ls-tree + git show 経由で exact block 一致 (count=2 / ref prefix 形式 / read_ok=true)"
else
  fail "unexpected (rc=$HELPER_RC): $HELPER_STDOUT / stderr: $HELPER_STDERR"
fi

# === TC-8: separate_branch 既存 branch + raw tree 不在 → read_ok=true ===
# wiki branch は存在するが .rite/wiki/raw/ tree が無いケース。git ls-tree は path 不在でも
# rc=0 + 空出力で成功する (path 不在 ≠ エラー) ため、これは absent ではなく scan 成功・空集合
# = true。不在 *branch* (ls-tree 失敗) の absent 経路は TC-13 が、io_error 経路は TC-14 が担う。
echo "TC-8: separate_branch 既存 branch + raw tree 不在 (ls-tree 成功・空 → read_ok=true)"
repo=$(make_separate_branch_sandbox tc8 0)
run_helper "$repo" --branch-strategy separate_branch --wiki-branch wiki
if [ "$HELPER_RC" = "0" ] && grep -q '^skipped_refs_count=0$' <<<"$HELPER_STDOUT" \
   && grep -q '^log_read_ok=true$' <<<"$HELPER_STDOUT"; then
  pass "既存 branch・raw tree 無し → 空集合 + read_ok=true (path 不在は非エラー)"
else
  fail "unexpected (rc=$HELPER_RC): $HELPER_STDOUT / stderr: $HELPER_STDERR"
fi

# === TC-9: --branch-strategy 欠落 → exit 2 ===
echo "TC-9: --branch-strategy 欠落"
repo=$(make_same_branch_sandbox tc9 1)
run_helper "$repo" --wiki-branch wiki
if [ "$HELPER_RC" = "2" ]; then
  pass "exit 2 (invocation error)"
else
  fail "unexpected rc=$HELPER_RC"
fi

# === TC-10: separate_branch + 空 --wiki-branch → exit 2 ===
echo "TC-10: separate_branch + 空 wiki-branch"
repo=$(make_same_branch_sandbox tc10 1)
run_helper "$repo" --branch-strategy separate_branch
if [ "$HELPER_RC" = "2" ] && grep -q -- '--wiki-branch が必須です' <<<"$HELPER_STDERR"; then
  pass "exit 2 + --wiki-branch 必須エラー"
else
  fail "unexpected (rc=$HELPER_RC): $HELPER_STDERR"
fi

# === TC-11: 値なしフラグ末尾 → no-hang ===
echo "TC-11: 値なしフラグ末尾 no-hang"
repo=$(make_same_branch_sandbox tc11 1)
run_helper "$repo" --branch-strategy same_branch --wiki-branch
if [ "$HELPER_RC" != "124" ]; then
  pass "no hang (rc=$HELPER_RC)"
else
  fail "hang detected (timeout)"
fi

# === TC-12: same_branch io_error (raw dir を chmod 000 → find が rc≠0) ===
# raw dir の実行/読取権限を剥がすと find は rc≠0 で失敗する。io_error への降格判定は特定の
# stderr 文言 (例: "Permission denied"、locale/find 実装で変動) への依存ではなく、absent 判別
# regex (No such file or directory) に **match しない** ことで成立する。アサーションも helper
# 自身の locale 非依存 WARNING ("find に失敗しました") を grep する。root は権限チェックを透過
# するため (find が成功してしまう) root 実行時はアサーションを skip する。
echo "TC-12: same_branch io_error (fault injection: chmod 000 raw dir)"
repo=$(make_same_branch_sandbox tc12 1)
if [ "$(id -u)" = "0" ]; then
  pass "TC-12 skip (root 実行では permission injection が無効)"
else
  chmod 000 "$repo/.rite/wiki/raw"
  run_helper "$repo" --branch-strategy same_branch --wiki-branch wiki
  chmod 755 "$repo/.rite/wiki/raw" 2>/dev/null || true  # cleanup 用に権限復帰
  if [ "$HELPER_RC" = "0" ] && grep -q '^log_read_ok=io_error$' <<<"$HELPER_STDOUT" \
     && grep -q '^skipped_refs_count=0$' <<<"$HELPER_STDOUT" \
     && grep -q 'find に失敗しました' <<<"$HELPER_STDERR"; then
    pass "io_error + 空集合 + WARNING (exit 0 非ブロッキング)"
  else
    fail "unexpected (rc=$HELPER_RC): stdout=$HELPER_STDOUT / stderr=$HELPER_STDERR"
  fi
fi

# === TC-13: separate_branch 不在 wiki branch → absent (raw 無し = 妥当) ===
# 旧 SoT (log.md) では不在 branch を io_error 扱いしていたが、raw 走査では存在しない
# branch = scan 対象 raw が無い legitimate absence として absent に降格する。
echo "TC-13: separate_branch 不在 wiki branch → absent"
repo=$(make_separate_branch_sandbox tc13 1)
run_helper "$repo" --branch-strategy separate_branch --wiki-branch no-such-branch
if [ "$HELPER_RC" = "0" ] && grep -q '^log_read_ok=absent$' <<<"$HELPER_STDOUT" \
   && grep -q '^skipped_refs_count=0$' <<<"$HELPER_STDOUT"; then
  pass "不在 branch → absent + 空集合 (exit 0 非ブロッキング)"
else
  fail "unexpected (rc=$HELPER_RC): stdout=$HELPER_STDOUT / stderr=$HELPER_STDERR"
fi

# === TC-14: separate_branch io_error (fault injection: chmod 000 .git/objects) ===
# 不在 branch (TC-13) は raw 走査では absent に降格するため、separate_branch の真の io_error
# 経路を object store 破損で別途検証する。.git/objects を読めなくすると git の repository
# discovery が rc=128 (fatal: not a git repository) で落ち、absent 判別 regex
# (Not a valid object name|not a tree object|does not exist) に match しないため io_error に
# 降格する。root は権限を透過するため (ls-tree が成功し得る) root 実行時はアサーションを skip する。
echo "TC-14: separate_branch io_error (fault injection: chmod 000 .git/objects)"
repo=$(make_separate_branch_sandbox tc14 1)
if [ "$(id -u)" = "0" ]; then
  pass "TC-14 skip (root 実行では permission injection が無効)"
else
  chmod -R 000 "$repo/.git/objects" 2>/dev/null  # 自己再帰の "読み込めません" ノイズは無視
  run_helper "$repo" --branch-strategy separate_branch --wiki-branch wiki
  chmod -R 755 "$repo/.git/objects" 2>/dev/null || true  # cleanup 用に権限復帰 (rm -rf 可能化)
  if [ "$HELPER_RC" = "0" ] && grep -q '^log_read_ok=io_error$' <<<"$HELPER_STDOUT" \
     && grep -q '^skipped_refs_count=0$' <<<"$HELPER_STDOUT" \
     && grep -q 'git ls-tree に失敗しました' <<<"$HELPER_STDERR"; then
    pass "io_error + 空集合 + WARNING (exit 0 非ブロッキング)"
  else
    fail "unexpected (rc=$HELPER_RC): stdout=$HELPER_STDOUT / stderr=$HELPER_STDERR"
  fi
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
