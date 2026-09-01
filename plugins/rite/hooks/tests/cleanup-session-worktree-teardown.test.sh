#!/usr/bin/env bash
# cleanup-session-worktree-teardown.sh の単体テスト（Issue #2492 T-01 / T-02 / T-06）。
#
# 対応 AC:
#   AC-1 worktree teardown helper が単独で動作する（削除 + main checkout パスの marker）
#   AC-2 対象外の cwd で何もせず exit 0
#   AC-6 --dry-run が削除しない
#
# marker は行まるごと固定する。呼び出し側（cleanup/SKILL.md ステップ 12）は marker 名 +
# フィールドで判定するため、フィールドが 1 つ落ちても helper 単体では動いて見える。
set -u
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HELPER="$SCRIPT_DIR/../scripts/cleanup-session-worktree-teardown.sh"
pass=0 fail=0
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
ok(){ pass=$((pass+1)); echo "  ✅ $1"; }
bad(){ fail=$((fail+1)); echo "  ❌ $1"; }
assert_contains(){ case "$2" in *"$3"*) ok "$1";; *) bad "$1 (出力: $2)";; esac; }
assert_not_contains(){ case "$2" in *"$3"*) bad "$1 (出力: $2)";; *) ok "$1";; esac; }
assert_eq(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected='$3' actual='$2')"; fi; }

# multi_session 有効なリポジトリ + セッション worktree を作る。
# worktree パスは helper が物理判定に使う `<worktree_base leaf>/issue-{N}` の形にする。
make_repo(){
  d=$(mktemp -d "$TMP_ROOT/repo.XXXXXX")
  git -C "$d" init -q -b develop
  git -C "$d" config user.email test@example.com
  git -C "$d" config user.name test
  printf 'base\n' > "$d/README.md"
  printf '.rite/\n' > "$d/.gitignore"
  printf 'multi_session:\n  enabled: true\n  worktree_base: ".rite/worktrees"\n' > "$d/rite-config.yml"
  git -C "$d" add . && git -C "$d" commit -qm base
  git -C "$d" branch feat/test
  git -C "$d" worktree add -q "$d/.rite/worktrees/issue-1" feat/test
  printf '%s\n' "$d"
}

echo "=== cleanup-session-worktree-teardown: detect ==="

# AC-1 前半: worktree 内から呼ぶと main checkout の絶対パスが marker で得られる。
# flow-state に記録が無くても物理 cwd から導出する（in_worktree_unrecorded）。
r=$(make_repo); wt="$r/.rite/worktrees/issue-1"
main_root=$(git -C "$r" rev-parse --show-toplevel)
out=$(cd "$wt" && RITE_STATE_ROOT="$r" bash "$HELPER" detect --issue 1 --config "$r/rite-config.yml" 2>/dev/null)
assert_contains "detect: worktree 内は in_worktree_unrecorded に分類する" "$out" \
  "[CONTEXT] CLEANUP_WT=in_worktree_unrecorded; worktree=$wt; main_root=$main_root"
assert_contains "detect: 退出不能な入場は委譲 marker を出す" "$out" \
  "[CONTEXT] CLEANUP_DELEGATED=1; reason=exit_worktree_unavailable"

# AC-2: 対象外の cwd（main checkout）では worktree を触らず none を返して exit 0。
r=$(make_repo); wt="$r/.rite/worktrees/issue-1"
out=$(cd "$r" && RITE_STATE_ROOT="$r" bash "$HELPER" detect --issue 1 --config "$r/rite-config.yml" 2>/dev/null); rc=$?
assert_eq "detect: 対象外 cwd でも exit 0" "$rc" "0"
assert_contains "detect: 対象外 cwd は none" "$out" "[CONTEXT] CLEANUP_WT=none;"
assert_not_contains "detect: none では委譲 marker を出さない" "$out" "CLEANUP_DELEGATED"
[ -d "$wt" ] && ok "detect: worktree を削除しない（read-only）" || bad "detect が worktree を削除した"

# multi_session 無効な config では分類自体が none（4-W 全体 no-op）。
r=$(make_repo); wt="$r/.rite/worktrees/issue-1"
printf 'multi_session:\n  enabled: false\n' > "$r/rite-config.yml"
out=$(cd "$wt" && RITE_STATE_ROOT="$r" bash "$HELPER" detect --issue 1 --config "$r/rite-config.yml" 2>/dev/null)
assert_contains "detect: multi_session 無効は none" "$out" "[CONTEXT] CLEANUP_WT=none;"

# detect は read-only なので --dry-run を受理して no-op（AC-6 の「各 helper」を満たす）。
r=$(make_repo); wt="$r/.rite/worktrees/issue-1"
out_plain=$(cd "$wt" && RITE_STATE_ROOT="$r" bash "$HELPER" detect --issue 1 --config "$r/rite-config.yml" 2>/dev/null)
out_dry=$(cd "$wt" && RITE_STATE_ROOT="$r" bash "$HELPER" detect --issue 1 --config "$r/rite-config.yml" --dry-run 2>/dev/null); rc=$?
assert_eq "detect --dry-run: exit 0" "$rc" "0"
assert_eq "detect --dry-run: 出力が通常実行と同一（no-op）" "$out_dry" "$out_plain"

echo "=== cleanup-session-worktree-teardown: remove ==="

# AC-1 後半: worktree を削除する。cwd は main checkout に置く（自己削除を避ける実運用と同じ）。
r=$(make_repo); wt="$r/.rite/worktrees/issue-1"
out=$(cd "$r" && bash "$HELPER" remove --worktree "$wt" --pr-merged true --self-root "$$" 2>&1); rc=$?
assert_eq "remove: exit 0" "$rc" "0"
[ -d "$wt" ] && bad "remove: worktree が残っている" || ok "remove: worktree を削除する"
# 削除成功時は marker を出さない契約（ステップ 12 は marker family 不在を削除成功と読む）。
assert_not_contains "remove: 成功時は WORKTREE_REMOVE_* marker を出さない" "$out" "WORKTREE_REMOVE_"

# AC-6: --dry-run は削除せず対象を stdout に報告する。
r=$(make_repo); wt="$r/.rite/worktrees/issue-1"
out=$(cd "$r" && bash "$HELPER" remove --worktree "$wt" --pr-merged true --self-root "$$" --dry-run 2>/dev/null); rc=$?
assert_eq "remove --dry-run: exit 0" "$rc" "0"
[ -d "$wt" ] && ok "remove --dry-run: worktree を削除しない" || bad "remove --dry-run が worktree を削除した"
assert_eq "remove --dry-run: 対象を stdout の marker で報告する" "$out" \
  "[CONTEXT] WORKTREE_REMOVE_DRY_RUN=1; path=$wt; action=remove_worktree"

# 既に消えている worktree に対しても非ブロッキング（cleanup 再実行の冪等性）。
r=$(make_repo); wt="$r/.rite/worktrees/issue-1"
git -C "$r" worktree remove "$wt" >/dev/null 2>&1
out=$(cd "$r" && bash "$HELPER" remove --worktree "$wt" --pr-merged true --self-root "$$" 2>&1); rc=$?
assert_eq "remove: 既に不在でも exit 0" "$rc" "0"

echo "=== cleanup-session-worktree-teardown: usage ==="

# --pr-merged / --self-root は呼び出し側の判断でしか決まらない。既定値を置くと
# 「未マージ作業を強制削除する」「self-exclusion が効かない」経路ができるため必須。
out=$(bash "$HELPER" remove --worktree /nonexistent --self-root "$$" 2>&1); rc=$?
assert_eq "remove: --pr-merged 欠落は usage error" "$rc" "2"
out=$(bash "$HELPER" remove --worktree /nonexistent --pr-merged true 2>&1); rc=$?
assert_eq "remove: --self-root 欠落は usage error" "$rc" "2"
out=$(bash "$HELPER" detect 2>&1); rc=$?
assert_eq "detect: --issue 欠落は usage error" "$rc" "2"
out=$(bash "$HELPER" bogus 2>&1); rc=$?
assert_eq "未知の subcommand は usage error" "$rc" "2"

echo "PASS: $pass"
echo "FAIL: $fail"
[ "$fail" -eq 0 ]
