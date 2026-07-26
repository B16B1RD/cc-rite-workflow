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
# - TC-2b      (AC-1/AC-4): rc=0 経路で push --delete 自体が失敗したとき
#                      REMOTE_BRANCH_DELETE_FAILED を emit する (marker 不在を
#                      「削除成功」と解釈するステップ 12 の契約に対し、削除失敗が
#                      完了として報告される false-success を防ぐ)
# - TC-3       (AC-1): ls-remote 自体の失敗 (rc=0/2 以外) は「既削除」に丸めず
#                      REMOTE_BRANCH_CHECK_FAILED を emit し、削除も試行しない
# - TC-4 = T-03 (AC-3): merge/SKILL.md の設計判断が全称的な保証を主張せず、
#                      抑止できないものを否定表現で明示して区別している
# - TC-6       (AC-4): ステップ 12 リモート側の判定 3 ルール + marker family スコープ +
#                      ローカル/リモート独立評価の AND ルール文を静的に pin する
#                      (emitter だけ検証して consumer が無防備になる穴を塞ぐ)
# - TC-5 = T-04       : 修正前のガード式へ mutation で戻すと TC-1 が落ちる
#                      (ガードが load-bearing であることの実証)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLEANUP_MD="$SCRIPT_DIR/../../skills/cleanup/SKILL.md"
MERGE_MD="$SCRIPT_DIR/../../skills/merge/SKILL.md"
# cleanup/trap を mktemp より前に設置する (直後の cd / command -v の exit 1 経路で temp dir が
# leak しないようにする)。TEST_DIR は先行宣言して set -u 下でも参照可能にする。
TEST_DIR=""
cleanup() { [ -n "$TEST_DIR" ] && rm -rf "$TEST_DIR"; return 0; }
trap cleanup EXIT
TEST_DIR="$(mktemp -d)" || exit 1
TEST_DIR="$(cd "$TEST_DIR" && pwd -P)" || exit 1
REAL_GIT="$(command -v git)" || { echo "FATAL: git が見つかりません"; exit 1; }
PASS=0
FAIL=0

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
# 3 分岐すべてを必須文字列に含める (rc=0 の削除分岐だけが対象外という非対称を残さない)
for required in 'ls-remote --exit-code' 'push origin --delete' 'REMOTE_BRANCH_DELETE_FAILED' \
                'REMOTE_BRANCH_ALREADY_ABSENT' 'REMOTE_BRANCH_CHECK_FAILED' '^esac$'; do
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
# grep の rc=1 (マッチなし = 期待動作) と rc=2 (CALL_LOG 不在 / IO エラー) を区別する。
# 融合させると記録機構が壊れたときに否定アサーションが vacuous に PASS する。
push_delete_called() {
  local rc
  grep -q -- "--delete" "$CALL_LOG"; rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) echo "FATAL: CALL_LOG の grep が IO エラー (rc=$rc): $CALL_LOG" >&2; exit 1 ;;
  esac
}

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

# ─── TC-2b (AC-1/AC-4): rc=0 経路で push --delete が失敗 → REMOTE_BRANCH_DELETE_FAILED ───
# ステップ 12 は「REMOTE_BRANCH_* marker 不在 = 削除成功」と解釈するため、この分岐が marker を
# 出さないと削除失敗が完了 (`x`) として報告される。receive.denyDeletes で server 側拒否を再現する。
echo "TC-2b: push --delete failure -> REMOTE_BRANCH_DELETE_FAILED (not silent success)"
git switch -qc "$BRANCH" 2>/dev/null || git switch -q "$BRANCH"
echo "v3" > file.txt
git add -A && git commit -qm work2 && git push -q origin "$BRANCH" 2>/dev/null
git switch -q main
git -C "$ORIGIN" config receive.denyDeletes true
out=$(run_guard "$GUARD_SNIPPET")
git -C "$ORIGIN" config --unset receive.denyDeletes
if ! push_delete_called; then
  fail "TC-2b: setup 不備 — ref が存在するのに push --delete が呼ばれていない"
elif ! printf '%s' "$out" | grep -q 'REMOTE_BRANCH_DELETE_FAILED=1'; then
  fail "TC-2b: push 失敗が marker で surface されていない。ステップ 12 が削除失敗を x と報告する (出力: '$out')"
elif ! git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
  fail "TC-2b: setup 不備 — 削除が拒否されたはずだがリモート ref が消えている"
else
  pass "TC-2b (push 失敗を marker で surface)"
fi
git push -q origin --delete "$BRANCH" 2>/dev/null || true

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
# 「保証する」literal の不在だけを見ると「必ず残ることを保証します」等の言い換えを素通しするため
# (実測で確認)、AC-3 が要求する性質「できないことを明示している」を否定語の存在で肯定的に assert する。
echo "TC-4: merge/SKILL.md states what --delete-branch=false can and cannot suppress"
decision=$(grep -n -- '--delete-branch=false` 明示' "$MERGE_MD" | head -1)
if [ -z "$decision" ]; then
  fail "TC-4: merge/SKILL.md に --delete-branch=false の設計判断項目が見つからない"
elif printf '%s' "$decision" | grep -qE '保証する|保証します|保証される|保証できる'; then
  fail "TC-4: 全称的な保証の主張が残っている: $decision"
elif ! printf '%s' "$decision" | grep -q 'delete_branch_on_merge'; then
  fail "TC-4: サーバサイド auto-delete (delete_branch_on_merge) への言及がない: $decision"
elif ! printf '%s' "$decision" | grep -qE '保証されない|止められない|抑止できるのは'; then
  fail "TC-4: 「抑止できないもの」を明示する否定表現がない (AC-3 が求める区別に届いていない): $decision"
else
  pass "TC-4 (抑止できるもの/できないものを区別して記述)"
fi

# ─── TC-6 (AC-4): ステップ 12 リモート側判定の契約を pin する ───
# emitter (ステップ 5 のガード) だけを検証すると consumer (完了報告の判定ルール) が無防備になる。
# 当該ブロックを削除する mutation でも全スイートが green になっていたため、散文側も静的に pin する。
echo "TC-6: cleanup/SKILL.md ステップ 12 pins the remote-side judgement rules"
remote_section=$(awk '/^  \*\*リモート側\*\*/{f=1} f{print} f && /^- `\{projects_status_result\}/{exit}' "$CLEANUP_MD")
tc6_fail=""
printf '%s' "$remote_section" | grep -q 'REMOTE_BRANCH_DELETE_FAILED=1' || tc6_fail="REMOTE_BRANCH_DELETE_FAILED の判定行がない"
[ -z "$tc6_fail" ] && { printf '%s' "$remote_section" | grep -q 'REMOTE_BRANCH_CHECK_FAILED=1' || tc6_fail="REMOTE_BRANCH_CHECK_FAILED の判定行がない"; }
[ -z "$tc6_fail" ] && { printf '%s' "$remote_section" | grep -qE 'REMOTE_BRANCH_ALREADY_ABSENT=1.*`x`' || tc6_fail="REMOTE_BRANCH_ALREADY_ABSENT が x (正常系) に割り当てられていない"; }
[ -z "$tc6_fail" ] && { printf '%s' "$remote_section" | grep -q 'REMOTE_BRANCH_\*' || tc6_fail="fallback が REMOTE_BRANCH_* の marker family でスコープされていない"; }
# 両側独立評価の AND ルール文 (ローカル成功でリモート失敗が握り潰される回帰の pin)
[ -z "$tc6_fail" ] && { grep -q '両方が `x` 相当のときだけ `x`' "$CLEANUP_MD" || tc6_fail="ローカル/リモート独立評価の AND ルール文がない"; }
if [ -n "$tc6_fail" ]; then
  fail "TC-6: $tc6_fail"
else
  pass "TC-6 (ステップ 12 リモート側判定 3 ルール + fallback スコープ + AND ルールを pin)"
fi

# ─── TC-5 (T-04): mutation — 修正前のガード式に戻すと TC-1 が落ちる ───
# TC-3 が origin を差し替えたままだと mutant の ls-remote が rc=128 で短絡し push が呼ばれず、
# 「TC-1 が vacuous」という事実と異なるメッセージで落ちる。origin 到達性を明示的に担保する。
git remote set-url origin "$ORIGIN"
git ls-remote --exit-code --heads origin main >/dev/null 2>&1 \
  || { echo "FATAL: TC-5 precondition: origin が到達不能"; exit 1; }
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
