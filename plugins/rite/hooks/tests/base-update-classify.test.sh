#!/bin/bash
# base-update-classify.test.sh
#
# cleanup/SKILL.md ステップ 4 の BASE_UPDATE 検証 block (retry break 後の成否検証) を
# SKILL.md から literal 抽出して sandbox で実行し、4-way 分類 (ok / ff_failed_clean /
# ff_failed_discardable / ff_failed_divergent) を pin する。
#
# 抽出実行方式の理由: 分類ロジックは SKILL.md 内の bash block テンプレートで、テストへ
# コピーすると SKILL.md 側の修正がテストに反映されず drift する。抽出アンカー
# (「# retry break 後の成否検証」〜 outer if の else) が壊れた場合はテスト自体が
# fail するため、アンカー変更もテストが検出する。
#
# 回帰 pin の背景 (review cycles):
# - TC-2: tree 全体比較はマージが追加したファイルを D と数え discardable を divergent に
#   誤流出させた。pathspec 限定後の正分類を pin
# - TC-4: grep '^[^ ?]' は untracked (??) を素通りさせた。混在 dirty の
#   divergent 分類を pin
# - TC-5: staged を含む dirty は working tree 比較で内容検証できない。divergent 分類を pin
# - TC-6: 非 -z の --name-only は quotePath がファイル名を C-quote し、pathspec 不一致の
#   git diff --quiet が exit 0 を返して相違変更が discardable に誤流出、破棄承認で
#   データ喪失した。非 ASCII 名の相違が divergent に落ちることを pin
# - TC-9 (#1936, T-05): sandbox の書き込みブロック用 character device マウントが
#   untracked (`??`) として誤検出され ff_failed_divergent に誤流出しないことを pin。
#   dirty 判定が lib/git-status-filtered.sh 経由になったことで、ゴーストマウントのみ・
#   HEAD が origin と同一の状態では ok に分類される
# - TC-10 (#1937 cross-validation): lib/git-status-filtered.sh 自体が失敗した場合
#   （mktemp 枯渇等、旧来の `git status --porcelain` には無かった新規失敗モード）、
#   `_bu_dirty` の空文字列フォールバックにより ff_failed_clean へ silent に倒れず
#   ff_failed_divergent（安全側）に分類されることを pin。stub plugin_root で
#   helper を強制失敗させて検証する

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_MD="$SCRIPT_DIR/../../skills/cleanup/SKILL.md"
# tests/ -> hooks/ -> rite (2 up), same resolution as _test-helpers.sh's
# _helpers_resolve_plugin_root. Needed because the extracted classify block
# now calls lib/git-status-filtered.sh via the {plugin_root} placeholder (#1936).
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

# --- SKILL.md から検証 block を抽出 ({base_branch} は main に置換) ---
CLASSIFY_SNIPPET="$TEST_DIR/classify.sh"
awk '/# retry break 後の成否検証/{f=1} f && /^else$/{exit} f{print}' "$SKILL_MD" \
  | sed -e 's/{base_branch}/main/g' -e "s|{plugin_root}|$PLUGIN_ROOT|g" > "$CLASSIFY_SNIPPET"
if ! grep -q 'BASE_UPDATE=ff_failed_discardable' "$CLASSIFY_SNIPPET"; then
  echo "FAIL: SKILL.md からの検証 block 抽出に失敗しました (アンカーが変更された可能性)"
  echo "  抽出結果: $(wc -l < "$CLASSIFY_SNIPPET") 行"
  exit 1
fi

classify() {
  # sandbox repo 内 (cwd) で抽出 block を実行し BASE_UPDATE marker 値を返す
  bash "$CLASSIFY_SNIPPET" 2>/dev/null | sed -n 's/^\[CONTEXT\] BASE_UPDATE=//p' | head -1
}

# --- sandbox: origin + main clone ---
ORIGIN="$TEST_DIR/origin.git"
REPO="$TEST_DIR/repo"
git init -q --bare -b main "$ORIGIN" || { echo "FATAL: sandbox origin init 失敗"; exit 1; }
git clone -q "$ORIGIN" "$REPO" 2>/dev/null || { echo "FATAL: sandbox clone 失敗"; exit 1; }
# cd 失敗のまま続行すると後続の破壊的 git 操作 (add/commit/checkout/reset) が親 repo に向く
cd "$REPO" || { echo "FATAL: sandbox cd 失敗"; exit 1; }
git config user.email test@example.com
git config user.name test
git switch -qc main 2>/dev/null || true
echo "v1" > file.txt
mkdir sub && echo "s1" > sub/inner.txt
git add -A && git commit -qm init && git push -qu origin main 2>/dev/null

# origin を先行させる helper (別 clone 経由で file.txt 更新 + 新規ファイル追加)
advance_origin() {
  local content="$1" newfile="$2"
  local other="$TEST_DIR/other-$RANDOM"
  git clone -q "$ORIGIN" "$other" 2>/dev/null
  ( cd "$other" && git config user.email t@e.c && git config user.name t \
    && echo "$content" > file.txt \
    && { [ -n "$newfile" ] && echo new > "$newfile" || true; } \
    && git add -A && git commit -qm advance && git push -q origin main )
  git fetch -q origin main
}

echo "=== BASE_UPDATE classify tests (SKILL.md 抽出実行) ==="
echo ""

# ─── TC-1: HEAD == origin → ok ───
echo "TC-1: up-to-date -> ok"
r=$(classify)
[ "$r" = "ok" ] && pass "TC-1 ($r)" || fail "TC-1: expected ok, got '$r'"

# ─── TC-2: unstaged tracked 変更が origin と同一 + マージが新規ファイル追加 → discardable ───
echo "TC-2: unstaged identical (+ merge-added file) -> discardable"
advance_origin "v2" "added-by-merge.txt"
echo "v2" > file.txt
r=$(classify)
[ "$r" = "ff_failed_discardable" ] && pass "TC-2 ($r)" || fail "TC-2: expected ff_failed_discardable, got '$r'"
git checkout -- :/

# ─── TC-3: unstaged tracked 変更が origin と相違 → divergent ───
echo "TC-3: unstaged different -> divergent"
echo "LOCAL-EDIT" > file.txt
r=$(classify)
[ "$r" = "ff_failed_divergent" ] && pass "TC-3 ($r)" || fail "TC-3: expected ff_failed_divergent, got '$r'"
git checkout -- :/

# ─── TC-4: unstaged 同一 + untracked 混在 → divergent (untracked 混在の回帰 pin) ───
echo "TC-4: identical unstaged + untracked mix -> divergent"
echo "v2" > file.txt
echo "brand-new" > untracked-new.txt
r=$(classify)
[ "$r" = "ff_failed_divergent" ] && pass "TC-4 ($r)" || fail "TC-4: expected ff_failed_divergent, got '$r'"
rm -f untracked-new.txt && git checkout -- :/

# ─── TC-5: staged 変更を含む dirty → divergent (staged の回帰 pin) ───
echo "TC-5: staged change -> divergent"
echo "STAGED-C" > file.txt && git add file.txt && echo "v2" > file.txt
r=$(classify)
[ "$r" = "ff_failed_divergent" ] && pass "TC-5 ($r)" || fail "TC-5: expected ff_failed_divergent, got '$r'"
git reset -q --hard HEAD

# ─── TC-6: 非 ASCII ファイル名の相違 → divergent (quotePath C-quote 経路の回帰 pin) ───
echo "TC-6: non-ASCII filename divergent -> divergent (quotePath regression)"
other="$TEST_DIR/other-jp"
git clone -q "$ORIGIN" "$other" 2>/dev/null
( cd "$other" && git config user.email t@e.c && git config user.name t \
  && echo "jp1" > "設計.md" && git add -A && git commit -qm jp && git push -q origin main )
git fetch -q origin main
# setup の ff が失敗すると 設計.md が untracked になり、quotePath 経路を通らず偽 PASS する
git merge -q --ff-only origin/main || { fail "TC-6 setup: ff-only merge 失敗"; }
advance_origin "v3" ""
echo "MY-DIFFERENT-DRAFT" > "設計.md"
r=$(classify)
if [ "$r" = "ff_failed_divergent" ]; then
  pass "TC-6 ($r)"
else
  fail "TC-6: expected ff_failed_divergent, got '$r' (quotePath 誤分類の再発 = 破棄承認でデータ喪失)"
fi
git checkout -- :/

# ─── TC-7: clean だが履歴 behind (ff 失敗相当) → ff_failed_clean ───
echo "TC-7: clean but behind -> ff_failed_clean"
r=$(classify)
[ "$r" = "ff_failed_clean" ] && pass "TC-7 ($r)" || fail "TC-7: expected ff_failed_clean, got '$r'"

# ─── TC-8: subdir cwd から相違変更 → divergent (root 固定 pathspec の回帰 pin) ───
echo "TC-8: divergent from subdir cwd -> divergent (root-pinned pathspec)"
echo "SUBDIR-LOCAL" > file.txt
r=$(cd sub && bash "$CLASSIFY_SNIPPET" 2>/dev/null | sed -n 's/^\[CONTEXT\] BASE_UPDATE=//p' | head -1)
[ "$r" = "ff_failed_divergent" ] && pass "TC-8 ($r)" || fail "TC-8: expected ff_failed_divergent, got '$r'"
git checkout -- :/

# ─── TC-9: sandbox ゴーストマウント (character device) のみ + HEAD == origin → ok (T-05, #1936) ───
# mknod は root/CAP_MKNOD 必須で本環境では使えないため、/dev/null への symlink で
# character device を模す (test -c は symlink を辿るため実マウントと等価)。
echo "TC-9: sandbox ghost-mount only (up-to-date) -> ok"
git fetch -q origin main && git merge -q --ff-only origin/main
ln -s /dev/null ghost_devnull
r=$(classify)
[ "$r" = "ok" ] && pass "TC-9 ($r)" || fail "TC-9: expected ok, got '$r' (#1936 sandbox ghost mount regression)"
rm -f ghost_devnull && git checkout -- :/

# ─── TC-10: lib/git-status-filtered.sh 自体の失敗時 → divergent (fail-safe,  cross-validation) ───
echo "TC-10: git-status-filtered.sh helper failure -> divergent (fail-safe, not silently clean)"
advance_origin "v4" ""
stub_root="$TEST_DIR/stub-plugin-root"
mkdir -p "$stub_root/hooks/scripts/lib"
cat > "$stub_root/hooks/scripts/lib/git-status-filtered.sh" << 'STUB_EOF'
echo "WARNING: git-status-filtered: simulated failure (test stub)" >&2
exit 1
STUB_EOF
CLASSIFY_SNIPPET_FAIL="$TEST_DIR/classify-fail.sh"
awk '/# retry break 後の成否検証/{f=1} f && /^else$/{exit} f{print}' "$SKILL_MD" \
  | sed -e 's/{base_branch}/main/g' -e "s|{plugin_root}|$stub_root|g" > "$CLASSIFY_SNIPPET_FAIL"
r=$(bash "$CLASSIFY_SNIPPET_FAIL" 2>/dev/null | sed -n 's/^\[CONTEXT\] BASE_UPDATE=//p' | head -1)
if [ "$r" = "ff_failed_divergent" ]; then
  pass "TC-10 ($r)"
else
  fail "TC-10: expected ff_failed_divergent (fail-safe), got '$r' (helper failure must not be silently treated as clean)"
fi
git checkout -- :/

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -gt 0 ] && exit 1
exit 0
