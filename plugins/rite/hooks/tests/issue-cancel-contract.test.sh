#!/bin/bash
# Tests for skills/issue-cancel/SKILL.md の中止経路 contract (T-01〜T-10).
#
# issue-cancel は prose-driven skill なので、削除・クローズの behavioral 検証は委譲先 helper 側の
# 既存 suite (cleanup-session-worktree-teardown.test.sh / cleanup-branch-delete.test.sh /
# cleanup-pr-state-purge.test.sh) が担う。本テストが固定するのは、それらへ配線する SKILL.md 側の
# 記述が drift しないこと — とりわけ「順序」と「委譲」で、どちらも壊れても実行時まで露見しない:
#   1. PR クローズ → Projects Status → Issue クローズ の相対順序 (AC-3)
#   2. PR クローズ失敗時に Status も Issue クローズも進めない fail-loud (AC-4)
#   3. worktree remove → branch delete の順序と、その間に入る ExitWorktree (AC-2)
#   4. 後片付けが helper 委譲で、削除 bash が複製されていないこと (AC-9)
#   5. 親 Issue へ Done を伝播させないこと (AC-10)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

SKILL="$SCRIPT_DIR/../../skills/issue-cancel/SKILL.md"
RATIONALE="$SCRIPT_DIR/../../skills/issue-cancel/references/rationale.md"

# 行番号ベースの順序 pin に使うヘルパ。パターンの最初の出現行を返す (不在は空)。
_first_line() { grep -nE "$2" "$1" 2>/dev/null | head -1 | cut -d: -f1; }

echo "=== 前提: スキル本体と rationale が存在する ==="
assert_file_exists_or_fail "issue-cancel/SKILL.md exists" "$SKILL" || {
  print_summary "$(basename "$0")" "issue-cancel contract (skill missing)" || exit 1
  exit 1
}
assert_file_exists_or_fail "issue-cancel/references/rationale.md exists" "$RATIONALE" || true

echo "=== T-01: 着手前中止で NOT_PLANNED と Cancelled が両方適用される (AC-1) ==="
# 実行行にアンカーする。コマンド名だけで拾うと「実行順序の不変条件」節の散文引用と手動復旧ヒントの
# 表セルにも一致し、Phase 6 の実行行から --reason を落としても緑のまま通る (T-03 と同じ規則)。
assert_grep "T-01 closes the Issue with --reason \"not planned\"" "$SKILL" \
  '^if gh issue close .*--reason "not planned"'
assert_grep "T-01 writes Cancelled as the board Status" "$SKILL" \
  '\-\-arg status "Cancelled"'
# 理由コメントは close と同一コールに載る (理由なしクローズの窓を作らない)。
assert_grep "T-01 the close call carries the reason as a comment" "$SKILL" \
  '\-\-comment "🚫 この Issue を中止しました'

echo "=== T-02: 着手後中止で 4 helper が揃い、順序と ExitWorktree が保たれる (AC-2) ==="
for h in \
  'cleanup-session-worktree-teardown\.sh' \
  'cleanup-branch-delete\.sh' \
  'cleanup-pr-state-purge\.sh' \
  'cleanup-work-memory\.sh'; do
  assert_grep "T-02 delegates to $h" "$SKILL" "bash \{plugin_root\}/hooks/(scripts/)?$h"
done
# (a) worktree remove は branch delete より前。Git 制約 (checkout 中の branch は削除不可) を
#     SKILL.md の記述順として固定する。逆転しても実行時までは無症状に見えるため行番号で pin する。
_wt_remove_line=$(_first_line "$SKILL" 'cleanup-session-worktree-teardown\.sh remove')
_branch_del_line=$(_first_line "$SKILL" 'cleanup-branch-delete\.sh')
if [ -n "$_wt_remove_line" ] && [ -n "$_branch_del_line" ]; then
  if [ "$_wt_remove_line" -lt "$_branch_del_line" ]; then
    pass "T-02 (a) worktree remove precedes branch delete"
  else
    fail "T-02 (a) worktree remove must precede branch delete (remove=$_wt_remove_line branch=$_branch_del_line)"
  fi
else
  fail "T-02 (a) could not locate both calls (remove='${_wt_remove_line:-none}' branch='${_branch_del_line:-none}')"
fi
# (b) detect と remove の間に ExitWorktree が入る。helper のヘッダが構造的前提として明記している
#     ステップで、抜けると cwd が worktree 内のまま自己削除を試みる。
# 指示行 (`ExitWorktree` を `action: "keep"` で呼ぶ行) にアンカーする。素の `ExitWorktree` だと
# 順序制約を説明する散文行を拾い、指示行を逆順に書き換えても行番号比較が成立してしまう。
_detect_line=$(_first_line "$SKILL" 'cleanup-session-worktree-teardown\.sh detect')
_exit_wt_line=$(_first_line "$SKILL" 'ExitWorktree.*action: "keep"')
if [ -n "$_detect_line" ] && [ -n "$_exit_wt_line" ] && [ -n "$_wt_remove_line" ]; then
  if [ "$_detect_line" -lt "$_exit_wt_line" ] && [ "$_exit_wt_line" -lt "$_wt_remove_line" ]; then
    pass "T-02 (b) ExitWorktree sits between detect and remove"
  else
    fail "T-02 (b) ExitWorktree must sit between detect and remove (detect=$_detect_line exit=$_exit_wt_line remove=$_wt_remove_line)"
  fi
else
  fail "T-02 (b) could not locate detect / ExitWorktree / remove"
fi
assert_grep "T-02 (b) ExitWorktree is called with keep (path 入場した worktree は remove で消えない)" "$SKILL" \
  'ExitWorktree.*action: "keep"'
# (c) 中止経路は常に未マージ。reap manifest へ記録させない。ファイル全体の grep では
# cleanup-branch-delete.sh 側の同一リテラルが一致してしまうため、4.2.1 セクションに限定する。
assert_grep_in_section "T-02 (c) the worktree teardown receives --pr-merged false" "$SKILL" \
  '^#### 4\\.2\\.2 remove の実行' '^### 4\\.3' '\-\-worktree "\{flow_wt\}" \-\-pr-merged "false"'
# (d) worktree の削除対象が対象 Issue のものであることを確認してから remove へ進む
#     (detect の内側は --issue を見ないため、呼び出し側で束縛しないと別 Issue の worktree が消える)。
#     見出し語 'Issue 束縛ガード' の在否では pin にならない (節を残したまま照合式を緩めても緑)。
#     照合式そのもの — 末尾セグメントの完全一致 — にアンカーする。suffix 照合や部分一致へ
#     書き換えると赤くなる。
assert_grep_in_section "T-02 (d) the guard compares the path's last segment for exact identity" "$SKILL" \
  '^#### 4\\.2\\.0 Issue 束縛ガード' '^#### 4\\.2\\.1' \
  '^elif \[ "\$\(basename "\$wt_path"\)" = "issue-\{issue_number\}" \]; then'
# ガードが判定表の内側ではなく、ExitWorktree / remove の**前段**に独立した節として置かれていること。
# 節の順序を入れ替える / ガード節を消すと赤くなる (4.2.1 の表セルへ畳み戻す変更も同様)。
_guard_line=$(_first_line "$SKILL" '^#### 4\.2\.0 Issue 束縛ガード')
_exitwt_head_line=$(_first_line "$SKILL" '^#### 4\.2\.1 ExitWorktree')
_remove_head_line=$(_first_line "$SKILL" '^#### 4\.2\.2 remove の実行')
if [ -n "$_guard_line" ] && [ -n "$_exitwt_head_line" ] && [ -n "$_remove_head_line" ]; then
  if [ "$_guard_line" -lt "$_exitwt_head_line" ] && [ "$_exitwt_head_line" -lt "$_remove_head_line" ]; then
    pass "T-02 (d) the Issue-binding guard is a standalone step ahead of ExitWorktree and remove"
  else
    fail "T-02 (d) guard must precede ExitWorktree and remove as its own section (guard=$_guard_line exit=$_exitwt_head_line remove=$_remove_head_line)"
  fi
else
  fail "T-02 (d) could not locate the 4.2.0 / 4.2.1 / 4.2.2 headings (guard=${_guard_line:-none} exit=${_exitwt_head_line:-none} remove=${_remove_head_line:-none})"
fi
# 不一致は「消さない」で終わらせる (ブランチ削除まで止める)。'mismatch' 行の存在ではなく
# その行の帰結にアンカーする。
assert_grep "T-02 (d) a mismatching worktree stops the removal and the branch delete" "$SKILL" \
  '^\| `mismatch` \|.*\*\*4\.2\.1 / 4\.2\.2 と 4\.3 のブランチ削除を試行せず\*\*'

echo "=== T-03: gh pr close が Projects Status 更新より先に呼ばれる (AC-3) ==="
# 順序 pin は**実行行**を見る。冒頭の「実行順序の不変条件」節は同じコマンド名を散文で引用するため、
# コマンド名だけで拾うと散文の出現順を測ってしまい、bash 側が入れ替わっても緑のままになる。
# 実行行は fenced bash 内の `if gh ...` という固定の形なので、そこにアンカーする。
_pr_close_line=$(_first_line "$SKILL" '^if gh pr close')
_status_line=$(_first_line "$SKILL" '\-\-arg status "Cancelled"')
if [ -n "$_pr_close_line" ] && [ -n "$_status_line" ]; then
  if [ "$_pr_close_line" -lt "$_status_line" ]; then
    pass "T-03 gh pr close precedes the Cancelled Status write"
  else
    fail "T-03 gh pr close must precede the Cancelled Status write (close=$_pr_close_line status=$_status_line)"
  fi
else
  fail "T-03 could not locate both calls (close='${_pr_close_line:-none}' status='${_status_line:-none}')"
fi
# Issue クローズは Status の後。3 点の相対順序を 1 本の鎖として固定する。
_issue_close_line=$(_first_line "$SKILL" '^if gh issue close')
if [ -n "$_status_line" ] && [ -n "$_issue_close_line" ]; then
  if [ "$_status_line" -lt "$_issue_close_line" ]; then
    pass "T-03 the Cancelled Status write precedes the Issue close"
  else
    fail "T-03 Status write must precede Issue close (status=$_status_line close=$_issue_close_line)"
  fi
else
  fail "T-03 could not locate the Issue close call"
fi
assert_grep "T-03 records why the order is load-bearing (post-compact reconciliation window)" "$SKILL" \
  'post-compact\.sh'

echo "=== T-04: PR クローズ失敗時に Status も Issue クローズも進めない (AC-4) ==="
assert_grep "T-04 emits a distinguishable failure marker for the PR close" "$SKILL" \
  'CANCEL_PR_CLOSE_FAILED=1'
# 失敗時の指示は Phase 3 の marker 判定表にある。fail-loud 停止であって non-blocking ではない。
assert_grep_in_section "T-04 the failure branch stops fail-loud" "$SKILL" \
  '^## Phase 3: PR クローズ' '^## Phase 4:' 'fail-loud で停止'
assert_grep_in_section "T-04 the failure branch forbids advancing Status / Issue close / teardown" "$SKILL" \
  '^## Phase 3: PR クローズ' '^## Phase 4:' 'Cancelled. へ進めず'

echo "=== T-05: 中止理由が空のとき Issue をクローズしない (AC-5) ==="
assert_grep_in_section "T-05 Phase 1 refuses to close without a reason" "$SKILL" \
  '^## Phase 1: 引数と中止理由の確定' '^## Phase 2:' '理由を取得できない'
assert_grep_in_section "T-05 Phase 1 states the Issue is not closed in that case" "$SKILL" \
  '^## Phase 1: 引数と中止理由の確定' '^## Phase 2:' 'Issue はクローズしない'
# 理由の消失経路を塞ぐ 2 点。(a) 書き出し先が worktree 削除の影響外に固定されていること
# (worktree 配下だと Phase 4.2 が Phase 1 と Phase 6 の間でファイルごと消す)。
assert_grep_in_section "T-05 the reason file lives outside the session worktree" "$SKILL" \
  '^## Phase 1: 引数と中止理由の確定' '^## Phase 2:' \
  '^echo "\[CONTEXT\] CANCEL_TMP_DIR=\$\{TMPDIR:-/tmp\}"'
# Write ツールはシェル展開をしないため、書き出し先は marker が返した実パスのリテラル置換であること。
# `${TMPDIR:-/tmp}/...` をそのまま file_path に渡す形へ戻すと赤くなる。
assert_grep_in_section "T-05 the write target is the resolved marker value, not an unexpanded string" "$SKILL" \
  '^## Phase 1: 引数と中止理由の確定' '^## Phase 2:' \
  '^`\{reason_file\}` = `CANCEL_TMP_DIR` marker の値 \+ `/rite-issue-cancel-reason-\{issue_number\}\.txt` のリテラル置換'
# (b) 読み出し側が rc と空値の両方を fail-loud にすること (片方だけでは理由なしクローズが成立する)。
assert_grep_in_section "T-05 Phase 6 refuses to close when the reason cannot be read" "$SKILL" \
  '^## Phase 6: Issue を NOT_PLANNED でクローズ' '^## Phase 7:' 'if ! cancel_reason=\$\(cat'
assert_grep_in_section "T-05 Phase 6 refuses to close on an empty reason" "$SKILL" \
  '^## Phase 6: Issue を NOT_PLANNED でクローズ' '^## Phase 7:' '理由なしで Issue をクローズしません'
assert_grep_in_section "T-05 Phase 3 applies the same guard before the PR close" "$SKILL" \
  '^## Phase 3: PR クローズ' '^## Phase 4:' '理由なしで PR をクローズしません'

echo "=== T-06: 既に CLOSED な Issue では Status 同期のみ (AC-6) ==="
assert_grep_in_section "T-06 Phase 2.1 routes CLOSED to a Status-sync-only path" "$SKILL" \
  '^### 2\.1 Issue の状態' '^### 2\.2' 'Phase 5（board Status の同期）だけを実行'
assert_grep_in_section "T-06 Phase 2.1 skips PR close / teardown / re-close for CLOSED" "$SKILL" \
  '^### 2\.1 Issue の状態' '^### 2\.2' 'Phase 3 / Phase 4 / Phase 6 をすべてスキップ'

echo "=== T-07: projects.enabled false で Status skip、後片付けは走る (AC-7) ==="
assert_grep_in_section "T-07 Phase 5 skips when projects are disabled" "$SKILL" \
  '^## Phase 5: Projects Status を Cancelled に更新' '^## Phase 6:' 'github\.projects\.enabled'
assert_grep_in_section "T-07 the skip does not take Issue close / teardown with it" "$SKILL" \
  '^## Phase 5: Projects Status を Cancelled に更新' '^## Phase 6:' 'Issue クローズと後片付けは Projects の有無に依存しない'
# skip 側だけ書いて、有効時の書き込み失敗を素通しにしないこと。issue-close Shared 節と同型の
# .result 分岐 (updated / skipped_not_in_project / failed) を持つ。
for r in 'updated' 'skipped_not_in_project' 'failed'; do
  assert_grep_in_section "T-07 Phase 5 dispatches on .result=$r" "$SKILL" \
    '^## Phase 5: Projects Status を Cancelled に更新' '^## Phase 6:' "\"$r\""
done
assert_grep_in_section "T-07 the Status write is non-blocking (failure does not stop the cancel)" "$SKILL" \
  '^## Phase 5: Projects Status を Cancelled に更新' '^## Phase 6:' 'non-blocking'

echo "=== T-08: MERGED PR を持つ Issue では中止せず /rite:cleanup を案内 (AC-8) ==="
assert_grep_in_section "T-08 a merged PR routes to /rite:cleanup instead of cancelling" "$SKILL" \
  '^### 2\.3 関連 PR の検索と identity 検証' '^## Phase 3' '/rite:cleanup'
assert_grep_in_section "T-08 the merged-PR branch stops" "$SKILL" \
  '^### 2\.3 関連 PR の検索と identity 検証' '^## Phase 3' '停止する'
# PR 検索が Issue 番号でスコープされること。--search "linked:issue:N" は :N を無視し、
# --head の glob は exact-match のため常に空を返す。どちらも「絞り込めていないのに成功して見える」。
assert_not_grep "T-08 does not use the unscoped linked:issue search" "$SKILL" \
  'gh pr list.*--search "linked:issue:'
assert_not_grep "T-08 does not pass a glob to --head (exact-match only)" "$SKILL" \
  '\-\-head "\*issue-'
assert_grep_in_section "T-08 looks the PR up by the resolved branch with an exact --head" "$SKILL" \
  '^### 2\.3 関連 PR の検索と identity 検証' '^## Phase 3' 'gh pr list .*\-\-head "\{branch_name\}"'
assert_grep_in_section "T-08 filters the fallback set by closing keyword / headRefName before the routing table" "$SKILL" \
  '^### 2\.3 関連 PR の検索と identity 検証' '^## Phase 3' 'Closes/Fixes/Resolves #\{issue_number\}'
# ブランチ解決が PR 検索より前にあること (順序が逆だと exact --head に渡す値が無い)
_branch_sec_line=$(_first_line "$SKILL" '^### 2\.2 作業ブランチの解決')
_pr_sec_line=$(_first_line "$SKILL" '^### 2\.3 関連 PR の検索と identity 検証')
if [ -n "$_branch_sec_line" ] && [ -n "$_pr_sec_line" ] && [ "$_branch_sec_line" -lt "$_pr_sec_line" ]; then
  pass "T-08 branch resolution precedes the PR lookup"
else
  fail "T-08 branch resolution must precede the PR lookup (branch=${_branch_sec_line:-none} pr=${_pr_sec_line:-none})"
fi
# flow-state の branch を対象 Issue に束縛すること (cmd_get は --issue を取らない)
assert_grep_in_section "T-08 binds the flow-state branch to the target Issue" "$SKILL" \
  '^### 2\\.2 作業ブランチの解決' '^### 2\\.3' 'get --field issue_number'
# 取得するだけでは束縛にならない。判定表の第 1 行が「対象 Issue と等値のときだけ採用」であること
# にアンカーする (条件を落として state_branch を無条件採用へ戻すと赤くなる)。
assert_grep "T-08 the flow-state branch is adopted only on an Issue-number match" "$SKILL" \
  '^\| `state_issue == \{issue_number\}` かつ `state_branch` が非空 \| `state_branch` / `true`'
# 取得窓 (--limit) の飽和を「PR 無し」と読まない。fail-loud の帰結 (停止する) にアンカーする。
assert_grep_in_section "T-08 a saturated fetch window is not read as no-PR" "$SKILL" \
  '^### 2\\.3 関連 PR の検索' '^## Phase 3:' \
  '\*\*返却件数が `--limit` の値と等しいときは集合が切り詰められている可能性がある\*\*'
assert_grep_in_section "T-08 the saturated-window path stops instead of falling through" "$SKILL" \
  '^### 2\\.3 関連 PR の検索' '^## Phase 3:' \
  '該当 PR が 1 件も無い」へ落とさず、WARNING を出して\*\*停止する\*\*'
# identity 昇格は headRefName が Issue スコープを満たす場合に限る (body の closing keyword だけで
# 一致した PR の head をリモートごと消させない)。
assert_grep "T-08 identity promotion is restricted to a matching headRefName" "$SKILL" \
  '\*\*identity 昇格は `headRefName` が `issue-\{issue_number\}-` を含む場合に限る\*\*'
# CLOSED-unmerged の PR は Phase 3 を飛ばして Phase 4 (state purge) へ回す。
assert_grep "T-08 a closed-unmerged PR still reaches the state purge" "$SKILL" \
  '^\| `state == "CLOSED"` かつ `mergedAt` が null の PR がある \|.*\*\*Phase 3 はスキップ\*\*して Phase 4 へ'

echo "=== T-09: 後片付けが helper 委譲で、削除 bash が複製されていない (AC-9) ==="
# worktree の削除・prune・再帰削除は helper 内部の判断 (live-cwd guard / sandbox マスク検知) と
# 不可分。SKILL.md 側に現れたら委譲が壊れている。
assert_not_grep "T-09 no inline git worktree remove" "$SKILL" 'git worktree remove'
assert_not_grep "T-09 no inline git worktree prune" "$SKILL" 'git worktree prune'
assert_not_grep "T-09 no inline recursive delete" "$SKILL" 'rm -rf'
assert_not_grep "T-09 no inline state-file delete" "$SKILL" 'rm -f .*\.rite'
# 例外は BRANCH_DELETE_UNMERGED marker への応答 1 行だけ。これは helper のローカル削除ロジック
# (存在確認 / -d→-D fallback / deferred 判定 / remote ref 検証) の複製ではなく、helper が emit した
# marker を受けた分岐であり、cleanup/SKILL.md ステップ 5 の強制削除と同じ形。helper 呼び出しより
# 後に置かれていることを pin して、helper を迂回した直接削除に退化するのを防ぐ。
_force_del_line=$(_first_line "$SKILL" 'git branch -D')
if [ -n "$_force_del_line" ] && [ -n "$_branch_del_line" ]; then
  if [ "$_branch_del_line" -lt "$_force_del_line" ]; then
    pass "T-09 the force delete responds to the helper's marker (helper call comes first)"
  else
    fail "T-09 git branch -D must follow the helper call (helper=$_branch_del_line force=$_force_del_line)"
  fi
else
  fail "T-09 could not locate the helper call and the marker-driven force delete"
fi
# その 1 行が helper と同じ安全形であること。unquoted / `--` なしだと refname 中の `;` 以降が
# 別コマンドとして実行され、helper (-D -- "$branch") が守っている不変条件が呼び出し側で破れる。
assert_grep "T-09 the force delete is quoted and uses the end-of-options separator" "$SKILL" \
  'git branch -D -- "\{branch_name\}"'
# helper が削除を試行しなかった marker では強制削除へ進まないこと (fail-fast の迂回防止)。
# marker 名の在否では pin にならない ('BRANCH_CHECK_FAILED' は同節の 'REMOTE_BRANCH_CHECK_FAILED'
# に部分文字列一致するため、行ごと消しても緑になる)。行頭 '|' + 帰結にアンカーする。
assert_grep "T-09 an unverifiable branch state never reaches the force delete" "$SKILL" \
  '^\| `BRANCH_CHECK_FAILED=1` /.*\*\*強制削除しない\*\*'
assert_grep "T-09 marker 不在 is not read as deletion success" "$SKILL" \
  '^\| marker 不在 \| 削除結果を確認できていない。強制削除せず'
# 強制削除は BRANCH_DELETE_UNMERGED の行だけが入口であること。
assert_grep "T-09 the force delete is gated on BRANCH_DELETE_UNMERGED" "$SKILL" \
  '^\| `BRANCH_DELETE_UNMERGED=1` \| \*\*確認を挟まず強制削除する\*\*'
assert_grep "T-09 states the delegation rule explicitly" "$SKILL" \
  '削除処理の bash を本スキルへ複製しない'

echo "=== T-10: Cancelled の子を含む親を Done へ更新しない (AC-10) ==="
# 親 Done 更新は archive-procedures.md §3.7 にのみ存在する手順で、共有 helper ではない。
# issue-cancel が配線しないこと自体が AC-10 の充足条件なので、Done を書く経路の不在を pin する。
assert_not_grep "T-10 never writes Done to any board row" "$SKILL" '\-\-arg status "Done"'
assert_not_grep "T-10 does not reference the parent auto-close procedure" "$SKILL" 'archive-procedures'
assert_not_grep "T-10 does not touch the parent tasklist" "$SKILL" 'parent_issue_number'
assert_grep "T-10 states the non-propagation rule" "$SKILL" '親 Issue には伝播しない'

echo "=== 補助: rationale ポインタが実在の anchor を指す ==="
# 本体に残す 1 行ポインタ (CLAUDE.md スキル行数原則) が空振りしていないこと。
if [ -f "$RATIONALE" ]; then
  _missing=0
  while read -r anchor; do
    [ -n "$anchor" ] || continue
    if ! grep -qE "^## $anchor\$" "$RATIONALE"; then
      fail "rationale anchor '#$anchor' referenced by SKILL.md is missing in references/rationale.md"
      _missing=$((_missing + 1))
    fi
  done < <(grep -oE 'rationale: references/rationale\.md#[a-z0-9-]+' "$SKILL" | sed 's|.*#||' | sort -u)
  [ "$_missing" -eq 0 ] && pass "every rationale pointer resolves to an anchor"
else
  fail "references/rationale.md is missing (SKILL.md points into it)"
fi

echo "=== 補助: 起動が人間の明示指示に限られる (Non-goal) ==="
assert_grep "frontmatter states the skill does not auto-activate" "$SKILL" \
  'auto-activate しない'
assert_grep "the body states rite never invokes cancel on its own judgement" "$SKILL" \
  '自律判断して本スキルを呼ぶ経路は作らない'

if ! print_summary "$(basename "$0")" "issue-cancel の実行順序 (PR close → Status → Issue close) / fail-loud / helper 委譲 / 親非伝播 contract (T-01〜T-10)"; then
  exit 1
fi
