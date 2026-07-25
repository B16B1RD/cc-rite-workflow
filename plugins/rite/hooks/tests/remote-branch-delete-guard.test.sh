#!/bin/bash
# remote-branch-delete-guard.test.sh
#
# cleanup/SKILL.md ステップ 5 のリモートブランチ削除ガードを SKILL.md から literal 抽出して
# sandbox で実行し、`git ls-remote --exit-code` の exit code 3 分岐を pin する (Issue #2016)。
# あわせて merge/SKILL.md の設計判断が `--delete-branch=false` の効果を過大に主張していない
# ことを静的検査する。
#
# 抽出実行方式の理由: ガードは SKILL.md 内の bash block テンプレートで、テストへコピーすると
# SKILL.md 側の修正がテストに反映されず drift する (base-update-classify.test.sh と同方式)。
# 抽出アンカーが壊れた場合はテスト自体が fail するため、アンカー変更もテストが検出する。
#
# 修正前の欠陥 (#2016): `git ls-remote --heads origin BR && git push origin --delete BR` は、
# `git ls-remote --heads` が ref 不在でも rc=0 (空 stdout) を返すため `&&` が常に成立し、
# delete_branch_on_merge: true の環境 (merge 時にサーバサイドで head が削除済み) では
# cleanup が完全に成功しているのに `error: unable to delete ...` を 2 行出していた。
#
# TC 対応 (Issue #2016 Section 7):
# - TC-1 = T-01 (AC-1): ref 不在 → push --delete を呼ばず REMOTE_BRANCH_ALREADY_ABSENT を emit
# - TC-2 = T-02 (AC-2): ref 存在 → 従来どおり削除経路へ入り、リモートから実際に消える
# - TC-3       (AC-1): ls-remote 自体の失敗 (rc=0/2 以外) は「既削除」に丸めず
#                      REMOTE_BRANCH_CHECK_FAILED を emit し、削除も試行しない
# - TC-4 = T-03 (AC-3): merge/SKILL.md の設計判断が全称的な「保証する」を主張せず、
#                      サーバサイド auto-delete を明示して区別している
# - TC-5 = T-04       : 修正前のガード式へ mutation で戻すと TC-1 が落ちる
#                      (ガードが load-bearing であることの実証)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLEANUP_MD="$SCRIPT_DIR/../../skills/cleanup/SKILL.md"
MERGE_MD="$SCRIPT_DIR/../../skills/merge/SKILL.md"
TEST_DIR="$(mktemp -d)" || exit 1
TEST_DIR="$(cd "$TEST_DIR" && pwd -P)" || exit 1
REAL_GIT="$(command -v git)" || { echo "FATAL: git が見つかりません"; exit 1; }
PASS=0
FAIL=0

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

BRANCH="fix/issue-2016-sample"

# --- SKILL.md からリモート削除ガードを抽出 ({branch_name} はテスト用ブランチ名に置換) ---
# アンカー: 導入コメント行 `# リモートブランチ削除` 〜 case を閉じる `esac`
extract_guard() {
  awk '/^# リモートブランチ削除/{f=1} f{print} f && /^esac$/{exit}' "$CLEANUP_MD" \
    | sed -e "s|{branch_name}|$BRANCH|g"
}
GUARD_SNIPPET="$TEST_DIR/guard.sh"
extract_guard > "$GUARD_SNIPPET"
for required in 'ls-remote --exit-code' 'REMOTE_BRANCH_ALREADY_ABSENT' 'REMOTE_BRANCH_CHECK_FAILED' '^esac$'; do
  if ! grep -q "$required" "$GUARD_SNIPPET"; then
    echo "FAIL: cleanup/SKILL.md からのガード抽出に失敗しました ('$required' 不在。アンカーが変更された可能性)"
    echo "  抽出結果: $(wc -l < "$GUARD_SNIPPET") 行"
    exit 1
  fi
done

# --- git ラッパー stub: push 呼び出しを記録しつつ実 git へ委譲する ---
# 「push --delete が呼ばれなかった」を出力の不在ではなく呼び出し記録で直接検証するため
# (出力ベースだと、たまたまエラーが出ないだけの偽 PASS を許してしまう)。
BIN_DIR="$TEST_DIR/bin"
CALL_LOG="$TEST_DIR/git-calls.log"
mkdir -p "$BIN_DIR"
cat > "$BIN_DIR/git" <<EOF
#!/bin/bash
if [ "\${1:-}" = "push" ]; then printf '%s\n' "push \$*" >> "$CALL_LOG"; fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$BIN_DIR/git"

# ガードを stub git 経由で実行し、stdout+stderr をまとめて返す
run_guard() {
  local snippet="$1"
  : > "$CALL_LOG"
  PATH="$BIN_DIR:$PATH" bash "$snippet" 2>&1
}
push_delete_called() { grep -q -- "--delete" "$CALL_LOG" 2>/dev/null; }

# --- sandbox: bare origin + clone ---
ORIGIN="$TEST_DIR/origin.git"
REPO="$TEST_DIR/repo"
git init -q --bare -b main "$ORIGIN" || { echo "FATAL: sandbox origin init 失敗"; exit 1; }
git clone -q "$ORIGIN" "$REPO" 2>/dev/null || { echo "FATAL: sandbox clone 失敗"; exit 1; }
# cd 失敗のまま続行すると後続の git 操作が親 repo に向く
cd "$REPO" || { echo "FATAL: sandbox cd 失敗"; exit 1; }
git config user.email test@example.com
git config user.name test
echo "v1" > file.txt
git add -A && git commit -qm init && git push -q origin main 2>/dev/null

echo "=== remote branch delete guard tests (SKILL.md 抽出実行) ==="
echo ""

# ─── TC-0: 前提 pin — `git ls-remote --heads` (--exit-code なし) は ref 不在でも rc=0 ───
# 本 Issue の根本原因そのもの。git 側の仕様が変わればガードの前提も変わるため明示的に pin する。
echo "TC-0: git ls-remote --heads (no --exit-code) returns rc=0 for a missing ref"
git ls-remote --heads origin "$BRANCH" >/dev/null 2>&1; legacy_rc=$?
if [ "$legacy_rc" -eq 0 ]; then
  pass "TC-0 (rc=$legacy_rc — 修正前の && ガードが常に成立していた前提を確認)"
else
  fail "TC-0: expected rc=0, got '$legacy_rc' (git の exit code 仕様が変わった可能性)"
fi

# ─── TC-1 (T-01 / AC-1): ref 不在 → push --delete を呼ばず ALREADY_ABSENT ───
echo "TC-1: absent remote ref -> no push --delete, REMOTE_BRANCH_ALREADY_ABSENT"
out=$(run_guard "$GUARD_SNIPPET")
if push_delete_called; then
  fail "TC-1: git push origin --delete が呼ばれた ($(cat "$CALL_LOG"))"
elif ! printf '%s' "$out" | grep -q 'REMOTE_BRANCH_ALREADY_ABSENT=1'; then
  fail "TC-1: REMOTE_BRANCH_ALREADY_ABSENT marker が出力されていない (出力: '$out')"
elif printf '%s' "$out" | grep -q '^error:'; then
  fail "TC-1: error: 行が出力された (AC-1 違反。出力: '$out')"
else
  pass "TC-1 (削除を試行せず既削除として marker を emit)"
fi

# ─── TC-2 (T-02 / AC-2): ref 存在 → 削除経路へ入りリモートから消える ───
echo "TC-2: existing remote ref -> push --delete runs and the ref is gone (backward compat)"
git switch -qc "$BRANCH" 2>/dev/null
echo "v2" > file.txt
git add -A && git commit -qm work && git push -q origin "$BRANCH" 2>/dev/null
git switch -q main
git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1 \
  || { echo "FATAL: TC-2 setup: origin へのブランチ push に失敗"; exit 1; }
out=$(run_guard "$GUARD_SNIPPET")
if ! push_delete_called; then
  fail "TC-2: git push origin --delete が呼ばれていない (delete_branch_on_merge:false 環境の機能後退)"
elif git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
  fail "TC-2: リモートブランチが削除されていない"
elif printf '%s' "$out" | grep -q 'REMOTE_BRANCH_ALREADY_ABSENT=1'; then
  fail "TC-2: 存在するのに ALREADY_ABSENT marker が出た (出力: '$out')"
else
  pass "TC-2 (従来どおりリモートブランチを削除)"
fi

# ─── TC-3 (AC-1): ls-remote 自体の失敗 → CHECK_FAILED、削除は試行しない ───
# ネットワーク断・認証失敗は rc=128 になる。これを rc=2 (不在) と取り違えて「既削除」に
# 丸めると、delete_branch_on_merge:false のリポジトリでリモートブランチが黙って残る (§8 リスク)。
echo "TC-3: ls-remote failure (unreachable origin) -> REMOTE_BRANCH_CHECK_FAILED, no delete attempt"
git remote set-url origin "$TEST_DIR/does-not-exist.git"
out=$(run_guard "$GUARD_SNIPPET")
if push_delete_called; then
  fail "TC-3: 存在判定できていないのに push --delete が呼ばれた ($(cat "$CALL_LOG"))"
elif printf '%s' "$out" | grep -q 'REMOTE_BRANCH_ALREADY_ABSENT=1'; then
  fail "TC-3: ネットワーク失敗を「既削除」に丸めた (出力: '$out')"
elif ! printf '%s' "$out" | grep -q 'REMOTE_BRANCH_CHECK_FAILED=1'; then
  fail "TC-3: REMOTE_BRANCH_CHECK_FAILED marker が出力されていない (出力: '$out')"
else
  pass "TC-3 (判定不能を未完了として surface)"
fi
git remote set-url origin "$ORIGIN"

# ─── TC-4 (T-03 / AC-3): merge/SKILL.md の設計判断が保証を主張していない ───
echo "TC-4: merge/SKILL.md states what --delete-branch=false can and cannot suppress"
decision=$(grep -n -- '--delete-branch=false` 明示' "$MERGE_MD" | head -1)
if [ -z "$decision" ]; then
  fail "TC-4: merge/SKILL.md に --delete-branch=false の設計判断項目が見つからない"
elif printf '%s' "$decision" | grep -q '保証する'; then
  fail "TC-4: 全称的な「保証する」が残っている: $decision"
elif ! printf '%s' "$decision" | grep -q 'delete_branch_on_merge'; then
  fail "TC-4: サーバサイド auto-delete (delete_branch_on_merge) への言及がない: $decision"
else
  pass "TC-4 (抑止できるもの/できないものを区別して記述)"
fi

# ─── TC-5 (T-04): mutation — 修正前のガード式に戻すと TC-1 が落ちる ───
# ガードが load-bearing であることの実証 (経験則「Mutation testing で test の真正性を
# empirical 検証する」)。vacuous pass (ガードを外しても緑のまま) を排除する。
echo "TC-5: mutation — reverting to the pre-fix guard makes TC-1 fail (guard is load-bearing)"
MUTANT="$TEST_DIR/guard-mutant.sh"
printf '%s\n' "git ls-remote --heads origin $BRANCH && git push origin --delete $BRANCH" > "$MUTANT"
out=$(run_guard "$MUTANT")
if push_delete_called; then
  pass "TC-5 (修正前の式では不在ブランチにも push --delete が走る = ガードは load-bearing)"
else
  fail "TC-5: 修正前の式でも push --delete が呼ばれなかった。TC-1 がガードを検証できていない (vacuous pass)"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -gt 0 ] && exit 1
exit 0
