#!/usr/bin/env bash
# cleanup-branch-delete.sh の単体テスト（Issue #2492 T-03 / T-04 / T-06）。
#
# 対応 AC:
#   AC-3 ローカル / リモート双方を削除する
#   AC-4 未マージブランチを保護し、抽出前と同じ診断を stderr に出す
#   AC-6 --dry-run が削除しない
#
# marker の網羅的な分岐（refname 非合法 / ref store 障害 / ls-remote の rc 分岐 / 完全一致検証）は
# remote-branch-delete-guard.test.sh が helper から抽出して実行する形で pin する。本ファイルは
# helper を **プロセスとして起動したときの** end-to-end 契約（削除の実効・保護・dry-run・usage）を
# 見る。marker は行まるごと固定する。
set -u
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HELPER="$SCRIPT_DIR/../scripts/cleanup-branch-delete.sh"
pass=0 fail=0
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
ok(){ pass=$((pass+1)); echo "  ✅ $1"; }
bad(){ fail=$((fail+1)); echo "  ❌ $1"; }
assert_contains(){ case "$2" in *"$3"*) ok "$1";; *) bad "$1 (出力: $2)";; esac; }
assert_not_contains(){ case "$2" in *"$3"*) bad "$1 (出力: $2)";; *) ok "$1";; esac; }
assert_eq(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected='$3' actual='$2')"; fi; }

BR="fix/issue-2492-sample"

# origin 付きのリポジトリを作る。$1 が merged なら feature を develop へ取り込んでから
# ブランチを残す（`git branch -d` が通る = 通常削除経路）。
make_repo(){
  local merged="$1"
  local d origin
  d=$(mktemp -d "$TMP_ROOT/repo.XXXXXX")
  # origin は作業ツリーの**外**に置く。中に置くと `git add .` がリモートの管理ファイル
  # (HEAD / config / hooks/*.sample など) を tree に取り込み、fixture に switch / merge を
  # 足した瞬間にリモート自身の HEAD / config が working tree 復元で書き換わりうる。
  origin=$(mktemp -d "$TMP_ROOT/origin.XXXXXX")/bare.git
  git init -q --bare "$origin"
  git -C "$d" init -q -b develop
  git -C "$d" config user.email test@example.com
  git -C "$d" config user.name test
  git -C "$d" remote add origin "$origin"
  printf 'base\n' > "$d/README.md"
  git -C "$d" add . && git -C "$d" commit -qm base
  git -C "$d" switch -q -c "$BR"
  printf 'feature\n' >> "$d/README.md"
  git -C "$d" commit -qam feature
  git -C "$d" push -q origin "$BR"
  git -C "$d" switch -q develop
  if [ "$merged" = "merged" ]; then
    git -C "$d" merge -q --no-ff "$BR" -m merge
  fi
  printf '%s\n' "$d"
}

local_exists(){ git -C "$1" show-ref --verify --quiet "refs/heads/$BR"; }
remote_exists(){ git -C "$1" ls-remote --exit-code --heads origin "refs/heads/$BR" >/dev/null 2>&1; }

echo "=== cleanup-branch-delete: マージ済み（AC-3）==="

r=$(make_repo merged)
out=$(cd "$r" && bash "$HELPER" --branch "$BR" --pr-merged true --branch-identity-verified true 2>&1); rc=$?
assert_eq "merged: exit 0" "$rc" "0"
# `via=` が続かないことまで見る。付けないと squash 残渣の強制削除経路
# (`...; branch=$BR; via=squash-merged`) の部分文字列にも一致し、通常削除と区別できない。
assert_contains "merged: ローカル削除の marker を出す" "$out" "[CONTEXT] BRANCH_DELETED=1; branch=$BR"
assert_not_contains "merged: 通常削除は via= を付けない" "$out" "branch=$BR; via="
assert_contains "merged: リモート削除の marker を出す" "$out" "[CONTEXT] REMOTE_BRANCH_DELETED=1; branch=$BR"
local_exists "$r" && bad "merged: ローカルブランチが残っている" || ok "merged: ローカルブランチが消える"
remote_exists "$r" && bad "merged: リモートブランチが残っている" || ok "merged: リモートブランチが消える"

echo "=== cleanup-branch-delete: 未マージ（AC-4）==="

# {pr_merged}=false（未マージ PR の強制 cleanup）では `git branch -d` の拒否を
# BRANCH_DELETE_UNMERGED として surface し、helper 側では強制削除しない（作業損失防止）。
r=$(make_repo unmerged)
out=$(cd "$r" && bash "$HELPER" --branch "$BR" --pr-merged false --branch-identity-verified true 2>&1); rc=$?
assert_eq "unmerged: exit 0（非ブロッキング）" "$rc" "0"
assert_contains "unmerged: 保留 marker を出す" "$out" "[CONTEXT] BRANCH_DELETE_UNMERGED=1; branch=$BR"
# `[CONTEXT] ` prefix 込みで照合する。`REMOTE_BRANCH_DELETED` は `BRANCH_DELETED` を部分文字列と
# して含むため、非アンカーで書くと「リモートは削除された」という正しい出力を根拠に落ちる
# （ステップ 12 の判定表が消費側へ課しているのと同じ規約をテスト側でも守る）。
# 未マージで保護されるのはローカルのみ。リモート削除は抽出前も実行されていた（振る舞い不変）。
assert_not_contains "unmerged: ローカルを削除済みと主張しない" "$out" "[CONTEXT] BRANCH_DELETED=1"
local_exists "$r" && ok "unmerged: ローカルブランチを保護する" || bad "unmerged: ローカルブランチが消えた"
# 未マージ marker は stderr 側（ステップ 12 の付記に載る診断）。
err=$(cd "$r" && bash "$HELPER" --branch "$BR" --pr-merged false --branch-identity-verified true 2>&1 >/dev/null)
assert_contains "unmerged: 診断は stderr に出る" "$err" "BRANCH_DELETE_UNMERGED=1; branch=$BR"

# squash merge の残渣: PR が merged 済みなら "not fully merged" を強制削除して安全。
r=$(make_repo unmerged)
out=$(cd "$r" && bash "$HELPER" --branch "$BR" --pr-merged true --branch-identity-verified true 2>&1)
assert_contains "squash 残渣: via=squash-merged で削除する" "$out" \
  "[CONTEXT] BRANCH_DELETED=1; branch=$BR; via=squash-merged"
local_exists "$r" && bad "squash 残渣: ローカルブランチが残っている" || ok "squash 残渣: ローカルブランチが消える"

echo "=== cleanup-branch-delete: identity 未確認 ==="

# 削除対象が PR head と一致すると確認できていない場合、ローカル・リモートとも試行しない。
r=$(make_repo merged)
out=$(cd "$r" && bash "$HELPER" --branch "$BR" --pr-merged true --branch-identity-verified false 2>&1)
assert_contains "identity 未確認: ローカルは sentinel marker" "$out" \
  "[CONTEXT] BRANCH_CHECK_FAILED=1; branch=<unsupported branch name>; rc=branch-identity-unverified"
assert_contains "identity 未確認: リモートは sentinel marker" "$out" \
  "[CONTEXT] REMOTE_BRANCH_CHECK_FAILED=1; branch=<unsupported branch name>; rc=branch-identity-unverified"
local_exists "$r" && ok "identity 未確認: ローカルを削除しない" || bad "identity 未確認でローカルを削除した"
remote_exists "$r" && ok "identity 未確認: リモートを削除しない" || bad "identity 未確認でリモートを削除した"

echo "=== cleanup-branch-delete: --dry-run（AC-6）==="

r=$(make_repo merged)
out=$(cd "$r" && bash "$HELPER" --branch "$BR" --pr-merged true --branch-identity-verified true --dry-run 2>/dev/null); rc=$?
assert_eq "dry-run: exit 0" "$rc" "0"
assert_contains "dry-run: ローカル対象を stdout の marker で報告する" "$out" \
  "[CONTEXT] DRY_RUN_BRANCH_DELETE=1; branch=$BR"
assert_contains "dry-run: リモート対象を stdout の marker で報告する" "$out" \
  "[CONTEXT] DRY_RUN_REMOTE_BRANCH_DELETE=1; branch=$BR"
assert_not_contains "dry-run: ローカル削除済み marker を出さない" "$out" "[CONTEXT] BRANCH_DELETED=1"
assert_not_contains "dry-run: リモート削除済み marker を出さない" "$out" "[CONTEXT] REMOTE_BRANCH_DELETED=1"
# dry-run marker は消費側 (SKILL.md ステップ 12) が scope する 2 つの glob の外に居ること。
# family 内だと判定表のどの行にも一致せず fallback にも落ちない未定義状態を作る。
assert_not_contains "dry-run: ローカル marker family に入らない" "$out" "[CONTEXT] BRANCH_DELETE_"
assert_not_contains "dry-run: リモート marker family に入らない" "$out" "[CONTEXT] REMOTE_BRANCH_"
local_exists "$r" && ok "dry-run: ローカルブランチを削除しない" || bad "dry-run がローカルブランチを削除した"
remote_exists "$r" && ok "dry-run: リモートブランチを削除しない" || bad "dry-run がリモートブランチを削除した"

echo "=== cleanup-branch-delete: 既に不在（冪等）==="

r=$(make_repo merged)
git -C "$r" branch -D "$BR" >/dev/null 2>&1
git -C "$r" push -q origin --delete "refs/heads/$BR" >/dev/null 2>&1
out=$(cd "$r" && bash "$HELPER" --branch "$BR" --pr-merged true --branch-identity-verified true 2>&1); rc=$?
assert_eq "既に不在: exit 0" "$rc" "0"
assert_contains "既に不在: ローカルは正常系 marker" "$out" "[CONTEXT] BRANCH_ALREADY_ABSENT=1; branch=$BR"
assert_contains "既に不在: リモートは正常系 marker" "$out" "[CONTEXT] REMOTE_BRANCH_ALREADY_ABSENT=1; branch=$BR"

echo "=== cleanup-branch-delete: usage ==="

# 呼び出し側の判断でしか決まらない 2 引数に既定値を置かない（検証していないのに削除する経路を作らない）。
bash "$HELPER" --branch "$BR" --pr-merged true >/dev/null 2>&1; rc=$?
assert_eq "--branch-identity-verified 欠落は usage error" "$rc" "2"
bash "$HELPER" --branch "$BR" --branch-identity-verified true >/dev/null 2>&1; rc=$?
assert_eq "--pr-merged 欠落は usage error" "$rc" "2"
bash "$HELPER" --branch "$BR" --pr-merged yes --branch-identity-verified true >/dev/null 2>&1; rc=$?
assert_eq "--pr-merged の非 boolean は usage error" "$rc" "2"

echo "PASS: $pass"
echo "FAIL: $fail"
[ "$fail" -eq 0 ]
