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
# コメント冒頭リテラルだけを見ると、本文から理由の差し込みを落としても緑のまま通る。
# AC-1 Then「理由がコメントとして残る」を守るのは差し込み行そのものなので、そこへ直接アンカーする。
assert_grep_in_section "T-01 the Issue-close comment interpolates the cancel reason" "$SKILL" \
  '^## Phase 6: Issue を NOT_PLANNED でクローズ' '^## Phase 7:' \
  '^理由: \$cancel_reason$'
assert_grep_in_section "T-01 the PR-close comment interpolates the cancel reason" "$SKILL" \
  '^## Phase 3: PR クローズ' '^## Phase 4:' \
  '\-\-comment "Issue #\{issue_number\} の中止に伴いクローズします。理由: \$pr_close_reason"'

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
  '^#### 4\\.2\\.2 remove の実行' '^### 4\\.3' '\-\-worktree "\{cancel_wt_target\}" \-\-pr-merged "false"'
# (d) 削除対象は detect の戻り値ではなく、対象 Issue に束縛して発見した path。detect は
#     現セッションの flow-state / cwd しか見ないため、main の新規セッションから中止すると
#     none に落ちて worktree が残る。発見 → 末尾セグメント完全一致 → cwd が対象の中なら
#     ExitWorktree 不能時は fail-loud、の経路を pin する。
assert_grep_in_section "T-02 (d) discovery lists registered worktrees" "$SKILL" \
  '^### 4\\.1\\.1 対象 Issue の worktree を発見する' '^### 4\\.2 ' \
  '^_wt_list=\$\(git worktree list --porcelain\) \|\| _list_rc=\$\?$'
assert_grep_in_section "T-02 (d) discovery matches the last path segment exactly" "$SKILL" \
  '^### 4\\.1\\.1 対象 Issue の worktree を発見する' '^### 4\\.2 ' \
  'basename "\$_p"\)" = "issue-\{issue_number\}"'
# 発見失敗は「記録なし」へ畳まず fail-loud。list 失敗を none に倒すと AC-2 が確認不能のまま
# Issue を閉じ、再実行が Phase 4 に届かなくなる。
_disc_fail_block=$(awk '/^  echo .*CANCEL_WT_TARGET=undetermined; reason=worktree_list_failed/{f=1} f{print} f&&/^  exit 1$/{exit}' "$SKILL")
if printf '%s\n' "$_disc_fail_block" | grep -qE '^  exit 1$'; then
  pass "T-02 (d) a failed worktree list exits non-zero (machine-enforced stop)"
else
  fail "T-02 (d) git worktree list failure must exit non-zero before closing the Issue"
fi
# ガードが判定表の内側ではなく、ExitWorktree / remove の**前段**に独立した節として置かれていること。
# 発見はガードより前（detect の直後）。節の順序を入れ替えると赤くなる。
_discover_line=$(_first_line "$SKILL" '^### 4\.1\.1 対象 Issue の worktree を発見する')
_guard_line=$(_first_line "$SKILL" '^#### 4\.2\.0 Issue 束縛ガード')
_exitwt_head_line=$(_first_line "$SKILL" '^#### 4\.2\.1 ExitWorktree')
_remove_head_line=$(_first_line "$SKILL" '^#### 4\.2\.2 remove の実行')
if [ -n "$_discover_line" ] && [ -n "$_guard_line" ] && [ -n "$_exitwt_head_line" ] && [ -n "$_remove_head_line" ]; then
  if [ "$_discover_line" -lt "$_guard_line" ] && [ "$_guard_line" -lt "$_exitwt_head_line" ] && [ "$_exitwt_head_line" -lt "$_remove_head_line" ]; then
    pass "T-02 (d) discovery then the Issue-binding guard sit ahead of ExitWorktree and remove"
  else
    fail "T-02 (d) discovery/guard must precede ExitWorktree and remove (discover=$_discover_line guard=$_guard_line exit=$_exitwt_head_line remove=$_remove_head_line)"
  fi
else
  fail "T-02 (d) could not locate the 4.1.1 / 4.2.0 / 4.2.1 / 4.2.2 headings (discover=${_discover_line:-none} guard=${_guard_line:-none} exit=${_exitwt_head_line:-none} remove=${_remove_head_line:-none})"
fi
# 現セッションの path が別 Issue ならその path は消さない。削除対象は発見した対象 path だけ。
assert_grep_in_section "T-02 (d) a foreign session worktree is never the remove target" "$SKILL" \
  '^#### 4\\.2\\.0 Issue 束縛ガード' '^#### 4\\.2\\.1' \
  '別 Issue のセッション worktree を remove 対象にしてはならない'
assert_grep_in_section "T-02 (d) a basename mismatch is not adopted as the target" "$SKILL" \
  '^#### 4\\.2\\.0 Issue 束縛ガード' '^#### 4\\.2\\.1' \
  'basename "\$target"\)" != "issue-\{issue_number\}"'
# 確認済み不在はリテラル none だけ。空文字 / undetermined / basename 不一致は blocked で
# Phase 5/6 の前に止める（空を none に畳むと F-01 と同型の復旧不能になる）。
assert_grep_in_section "T-02 (d) the none arm is the literal none token only" "$SKILL" \
  '^#### 4\\.2\\.0 Issue 束縛ガード' '^#### 4\\.2\\.1' \
  '^  none)$'
_empty_fail_block=$(awk '/CANCEL_WT_BOUND=blocked; reason=target_unconfirmed/{f=1} f{print} f&&/^    exit 1$/{exit}' "$SKILL")
if printf '%s\n' "$_empty_fail_block" | grep -qE '^    exit 1$'; then
  pass "T-02 (d) an empty or undetermined target exits non-zero"
else
  fail "T-02 (d) empty/undetermined target must exit non-zero before Status / Issue close"
fi
_mismatch_fail_block=$(awk '/CANCEL_WT_BOUND=blocked; reason=basename_mismatch/{f=1} f{print} f&&/^      exit 1$/{exit}' "$SKILL")
if printf '%s\n' "$_mismatch_fail_block" | grep -qE '^      exit 1$'; then
  pass "T-02 (d) a basename mismatch exits non-zero"
else
  fail "T-02 (d) basename mismatch must exit non-zero before Status / Issue close"
fi
# cwd が対象の中で ExitWorktree 不能なら Phase 5/6 の前に止める。閉じてから再実行する行は
# AC-6 で Phase 4 がスキップされるため復旧にならない。
assert_grep_in_section "T-02 (d) sitting in the target without ExitWorktree emits blocked" "$SKILL" \
  '^#### 4\\.2\\.0 Issue 束縛ガード' '^#### 4\\.2\\.1' \
  'CANCEL_WT_BOUND=blocked; reason=exit_worktree_unavailable'
_blocked_fail_block=$(awk '/CANCEL_WT_BOUND=blocked; reason=exit_worktree_unavailable/{f=1} f{print} f&&/^            exit 1$/{exit}' "$SKILL")
if printf '%s\n' "$_blocked_fail_block" | grep -qE '^            exit 1$'; then
  pass "T-02 (d) the blocked branch exits non-zero (machine-enforced stop)"
else
  fail "T-02 (d) exit_worktree_unavailable must exit non-zero before Status / Issue close"
fi
assert_grep_in_section "T-02 (d) blocked stops before Status and Issue close" "$SKILL" \
  '^#### 4\.2\.0 Issue 束縛ガード' '^#### 4\.2\.1' \
  '^\| `blocked` / marker 不在 \|.*\*\*fail-loud で停止する\*\*.*Phase 5 / Phase 6 を実行しない'
assert_not_grep "T-02 (d) does not close the Issue and ask for a re-run" "$SKILL" \
  'Phase 5・Phase 6 は通常どおり実行する'
# 判定表の行は 4.2.0 節の内側にあること (4.2.1 へ移設すると BOUND=ok のときしか読まれず
# 到達不能になるが、file スコープの pin では緑のまま通る)。
# 行数はヘッダ行 (`| `CANCEL_WT_BOUND` | アクション |`) を含む: 1 + 3 値 = 4。
assert "T-02 (d) the 4.2.0 routing table covers every CANCEL_WT_BOUND value (header + 3)" "4" \
  "$(awk -v start='^\\| `CANCEL_WT_BOUND` \\|' -v end='^#### 4\\.2\\.1 ' '$0 ~ start, $0 ~ end' "$SKILL" | grep -c '^| `')"
# 4.2.1 は ExitWorktree の keep 呼び出しだけ。CLEANUP_WT 表を戻すと in_main / unrecorded の
# 二重規則が復活する。
assert "T-02 (d) 4.2.1 has no CLEANUP_WT routing table" "0" \
  "$(awk -v start='^#### 4\\.2\\.1 ' -v end='^#### 4\\.2\\.2 ' '$0 ~ start, $0 ~ end' "$SKILL" | grep -c '^| `CLEANUP_WT`')"
assert_grep_in_section "T-02 (d) 4.2.1 runs only when exit is required" "$SKILL" \
  '^#### 4\\.2\\.1 ExitWorktree' '^#### 4\\.2\\.2' \
  '`CANCEL_WT_BOUND=ok` かつ `exit=required` のときだけ実行する'
# (e) state purge は「全運用経路で rc=0、部分失敗は marker のみ」契約の helper なので、rc だけを見ると
# 残置が完了として報告される。marker を判定に使うことと、その帰結（残置として列挙する）を pin する。
# 判定は bash の捕捉層に持たせない — 捕捉に失敗すると marker ごと消えて「観測できていない」が
# 「成功」に化けるため、sibling (cleanup/SKILL.md) と同じく出力を読む形であることも固定する。
# marker 名は helper 契約を説明する散文にも出るため、判定表の行そのものへアンカーする
# （散文の言及だけを pin すると、判定表の左辺を rc 単独へ書き換えても緑のまま通る）。
assert_grep_in_section "T-02 (e) state purge is judged by its partial-failure marker, not rc alone" "$SKILL" \
  '^### 4\.4 PR-specific state ファイルの削除' '^### 4\.5' \
  '^\| `REVIEW_CLEANUP_PARTIAL_FAILURE=1` を含む'
assert_grep_in_section "T-02 (e) a partial state purge is surfaced as residue" "$SKILL" \
  '^### 4\.4 PR-specific state ファイルの削除' '^### 4\.5' \
  'Phase 7 に「PR-specific state ファイル: 残置」として列挙する'
# 禁止したいのは「helper の stderr を変数保持のファイルへ退避する」構造そのもの。tempfile 名で
# pin すると別名の退避層を素通しする（それ自体が本 PR で消した欠陥クラス）ため、リダイレクト形で pin する。
assert_not_grep "T-02 (e) the state purge stderr is not diverted into a capture file" "$SKILL" \
  'cleanup-pr-state-purge\.sh.*2>"\$'
assert_not_grep "T-02 (e) the reap stderr is not diverted into a capture file" "$SKILL" \
  'flow-state\.sh reap-issue.*2>"\$'
# reap-issue には失敗専用 marker が無い (`WARNING: reap-issue:` は成功経路の告知にも使われる) ため、
# 接頭辞を bash の判別子にしてはならない。sibling と同じ素通し形であることを両側から pin する。
assert_grep_in_section "T-02 (e) reap-issue passes its output through instead of predicating on the prefix" "$SKILL" \
  '^### 4\.6 claim 解放と cross-session state の回収' '^### 4\.7' \
  '^bash \{plugin_root\}/hooks/flow-state\.sh reap-issue --issue \{issue_number\} 2>&1'
assert_not_grep "T-02 (e) no bash predicate treats the reap-issue WARNING prefix as failure-only" "$SKILL" \
  "grep -q.*WARNING: reap-issue:"
assert_grep_in_section "T-02 (e) the reap WARNING prefix is documented as not failure-only" "$SKILL" \
  '^### 4\.6 claim 解放と cross-session state の回収' '^### 4\.7' \
  '成功経路の告知にも使われる'
# 判定は除外形（告知行以外はすべて残置）で書く。失敗語彙の列挙形は helper に 5 種目が増えた時点で
# 静かに「残置なし」へ倒れるため、その形へ戻す変更を赤くする。
assert_grep_in_section "T-02 (e) the reap residue rule is written as an exclusion, not an enumeration" "$SKILL" \
  '^### 4\.6 claim 解放と cross-session state の回収' '^### 4\.7' \
  'の告知\*\*以外\*\*が 1 行でもある'
# helper が起動せず接頭辞行を 1 本も出さない rc≠0 経路も残置へ落とす（4.4 の判定表と対称）。
# 除外形だけだと母集団が空になり「残置なし」へ倒れる。
assert_grep_in_section "T-02 (e) a failed reap invocation is surfaced as residue too" "$SKILL" \
  '^### 4\.6 claim 解放と cross-session state の回収' '^### 4\.7' \
  '\*\*または上記 WARNING が出た\*\*'
assert_grep_in_section "T-02 (e) the reap residue consequence is pinned" "$SKILL" \
  '^### 4\.6 claim 解放と cross-session state の回収' '^### 4\.7' \
  'Phase 7 に「cross-session state: 残置」として列挙する'
# 呼び出し行そのものを固定する positive pin。negative control は grep が行単位のため、
# 行継続で書かれた捕捉層を素通しする。4.6 側と対称に 4.4 へも置く。
assert_grep_in_section "T-02 (e) the state purge call passes its output through" "$SKILL" \
  '^### 4\.4 PR-specific state ファイルの削除' '^### 4\.5' \
  '^bash \{plugin_root\}/hooks/scripts/cleanup-pr-state-purge\.sh --pr "\{pr_number\}" 2>&1'

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
assert_grep "T-03 records why the order is load-bearing (failed PR close must not advance the board)" "$SKILL" \
  'PR クローズが失敗した状態で Status を `Cancelled` へ進めてはならない'

echo "=== T-04: PR クローズ失敗時に Status も Issue クローズも進めない (AC-4) ==="
# marker の「生産側」（else 分岐の emit 行）を実行行アンカーで pin する。file-wide の grep だと
# 同じリテラルが直下の判定表行にも一致し、その判定表行を要求する下の 2 pin によって恒真化する
# （emit を成功 marker へ変異させても緑のまま通る）。T-01 / T-03 と同じ実行行アンカー規則。
assert_grep_in_section "T-04 the failure branch emits the failure marker" "$SKILL" \
  '^## Phase 3: PR クローズ' '^## Phase 4:' \
  '^  echo "\[CONTEXT\] CANCEL_PR_CLOSE_FAILED=1'
# 停止は散文だけでなく bash の非ゼロ exit で機械的に遮断されること（echo の rc は成功側・失敗側とも
# 0 のため、exit が無いと block 全体が rc=0 で終わり停止が判定表の読解に依存する）。
# 節スコープの `^  exit 1$` では pin にならない — 同節の理由ファイル検査 2 本が同じ行を持つため、
# else 経路の exit だけを消す変異を素通しする（直上の marker pin と同じ恒真化の機序）。marker
# emit 行からブロック終端 `fi` までの「隣接範囲」に限って exit を要求する。
# 判定表の行は `|` 始まりなので `^  echo ` とは衝突しない。marker 名アンカーで一意に決まる。
_pr_fail_block=$(awk '/^  echo .*CANCEL_PR_CLOSE_FAILED=1/{f=1} f{print} f&&/^fi$/{exit}' "$SKILL")
if printf '%s\n' "$_pr_fail_block" | grep -qE '^  exit 1$'; then
  pass "T-04 the failure branch exits non-zero (machine-enforced stop)"
else
  fail "T-04 the PR-close failure branch must exit non-zero before its closing fi"
fi
# Phase 6 の Issue クローズ失敗も同型に遮断されること（判定表は「停止する」と書くが、bash の rc が
# 0 のままだと state 不整合を抱えたまま Phase 7 の完了報告へ進みうる）。
_issue_fail_block=$(awk '/^  echo .*CANCEL_ISSUE_CLOSE_FAILED=1/{f=1} f{print} f&&/^fi$/{exit}' "$SKILL")
if printf '%s\n' "$_issue_fail_block" | grep -qE '^  exit 1$'; then
  pass "T-04 the Issue-close failure branch exits non-zero (machine-enforced stop)"
else
  fail "T-04 the Issue-close failure branch must exit non-zero before its closing fi"
fi
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
# 行キーとアクションを 1 本の regex で同時に固定する。リテラル単独の存在チェックだと、2 行の
# アクションセルを入れ替える変異 (NOT_PLANNED を停止へ / それ以外を Cancelled 同期へ) で
# すべて緑のまま通り、AC-6 の Then と F-02 が塞いだ board 上書きの両方を素通しする。
assert_grep_in_section "T-06 the NOT_PLANNED row keeps AC-6 (Status sync only)" "$SKILL" \
  '^### 2\.1 Issue の状態' '^### 2\.2' \
  '^\| `CLOSED` \+ `NOT_PLANNED` \|.*Phase 3 / Phase 4 / Phase 6 をすべてスキップ.*Phase 5（board Status の同期）だけを実行'
# COMPLETED (および未知値) では board へ何も書かずに停止する。ここが緩むと Done 行が Cancelled で
# 上書きされ、drift-check が終端行を母集団から外すため二度と戻らない (projects-integration.md Rule 1)。
assert_grep_in_section "T-06 the non-NOT_PLANNED row stops without writing Status" "$SKILL" \
  '^### 2\.1 Issue の状態' '^### 2\.2' \
  '^\| `CLOSED` \+ `NOT_PLANNED` 以外.*board Status を書かず\*\*停止し\*\*'
assert_grep_in_section "T-06 Phase 2.1 states the terminal-Status rule it protects" "$SKILL" \
  '^### 2\.1 Issue の状態' '^### 2\.2' '`Done` の行を `Cancelled` へ引きずらない'

echo "=== T-07: projects.enabled false で Status skip、後片付けは走る (AC-7) ==="
# 設定キーの言及だけを見ると、キーを読む第 1 文を残したまま「false でも実行する」へ反転させても
# 緑のまま通る。AC-7 Then の前半 (Status 更新をスキップする) は帰結の側へアンカーする。
assert_grep_in_section "T-07 Phase 5 skips when projects are disabled" "$SKILL" \
  '^## Phase 5: Projects Status を Cancelled に更新' '^## Phase 6:' \
  '`false`（または `rite-config\.yml` 不在）なら本 Phase を\*\*スキップ\*\*'
assert_grep_in_section "T-07 the skip does not take Issue close / teardown with it" "$SKILL" \
  '^## Phase 5: Projects Status を Cancelled に更新' '^## Phase 6:' 'Issue クローズと後片付けは Projects の有無に依存しない'
# skip 側だけ書いて、有効時の書き込み失敗を素通しにしないこと。issue-close Shared 節と同型の
# .result 分岐 (updated / skipped_not_in_project / skipped_terminal_conflict / failed) を持つ。
for r in 'updated' 'skipped_not_in_project' 'skipped_terminal_conflict' 'failed'; do
  assert_grep_in_section "T-07 Phase 5 dispatches on .result=$r" "$SKILL" \
    '^## Phase 5: Projects Status を Cancelled に更新' '^## Phase 6:' "\"$r\""
done
assert_grep_in_section "T-07 the Status write is non-blocking (failure does not stop the cancel)" "$SKILL" \
  '^## Phase 5: Projects Status を Cancelled に更新' '^## Phase 6:' 'non-blocking'

echo "=== T-08: MERGED PR を持つ Issue では中止せず /rite:cleanup を案内 (AC-8) ==="
assert_grep_in_section "T-08 a merged PR routes to /rite:cleanup instead of cancelling" "$SKILL" \
  '^### 2\.3 関連 PR の検索と identity 検証' '^## Phase 3' '/rite:cleanup'
# 素の「停止する」は同節の取得失敗ガードの散文 (「停止するのは取得自体が失敗したときだけで」) にも
# 一致するため、merged 行を「Phase 3 へ進む」へ書き換えても緑のまま通る。判定表の当該行へ直接
# アンカーする (T-02 (d) / T-09 と同じ「行頭のテーブル区切り + 帰結」形)。
assert_grep "T-08 the merged-PR branch stops" "$SKILL" \
  '^\| `mergedAt` が非 null の PR がある \|.*\*\*停止する\*\*'
# PR 検索が Issue 番号でスコープされること。--search "linked:issue:N" は :N を無視し、
# --head の glob は exact-match のため常に空を返す。どちらも「絞り込めていないのに成功して見える」。
assert_not_grep "T-08 does not use the unscoped linked:issue search" "$SKILL" \
  '^gh pr list.*--search "linked:issue:'
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
# ブランチ未確定時の取得は Issue スコープで、取得窓を持たないこと。`--limit N` の窓は Issue で
# スコープできず、本リポジトリでは常に飽和するため「飽和したら止める」は主経路 (着手前の Issue) を
# 恒真で殺す。timeline 経路へ戻さない pin。
assert_grep_in_section "T-08 the fallback lookup is Issue-scoped via the timeline API" "$SKILL" \
  '^### 2\\.3 関連 PR の検索' '^## Phase 3:' \
  '^_tl_raw=\$\(gh api "repos/\{owner\}/\{repo\}/issues/\{issue_number\}/timeline" --paginate'
assert_not_grep "T-08 no unscoped fetch window is used for the fallback" "$SKILL" \
  '^gh pr list.*--limit'
# 取得失敗の rc がガードへ届くこと。`gh api ... | sort -un` の形だと rc は最終段 sort のものになり、
# 直下の fail-loud が到達不能になる (0 件と取得失敗が畳まれる)。rc 保持コマンドを単体に保つ pin。
assert_grep_in_section "T-08 the timeline rc is captured from a single command, not a pipeline" "$SKILL" \
  '^### 2\\.3 関連 PR の検索' '^## Phase 3:' \
  '^  2>"\$_tl_err"\) \|\| _tl_rc=\$\?$'
# jq フィルタが PreToolUse ガード (jq-not-equal-null) に deny されない形であること。
# `!= null` を含む Bash 呼び出しは実行前に拒否されるため、書いたとおりには一度も走らない。
assert_grep_in_section "T-08 the timeline jq filter uses truthiness, not != null" "$SKILL" \
  '^### 2\\.3 関連 PR の検索' '^## Phase 3:' \
  'select\(\.pull_request\) \| \.number'
# 禁止するのは jq の `select(... != null)` そのもの。散文で禁止事実に言及する行まで赤くしない
# (pattern を `!= null` 一般へ広げると、この禁止を説明する記述自体が anti-pattern 判定される)。
assert_not_grep "T-08 SKILL.md contains no jq select(... != null) (denied by pre-tool-bash-guard)" "$SKILL" \
  'select\(.*!= *null'
# 0 件 (関連 PR が無い) と 取得失敗 を同じ値へ畳まない。停止するのは取得が失敗したときだけ。
assert_grep_in_section "T-08 an empty result is a real observation, not a window artifact" "$SKILL" \
  '^### 2\\.3 関連 PR の検索' '^## Phase 3:' \
  '\*\*絞り込み結果 0 件は「関連 PR が無い」と読んでよい\*\*'
assert_grep_in_section "T-08 a failed timeline fetch stops instead of reading as no-PR" "$SKILL" \
  '^### 2\\.3 関連 PR の検索' '^## Phase 3:' \
  '^  echo "ERROR: Issue timeline を取得できません'
assert_grep_in_section "T-08 the timeline candidates are still filtered before the routing table" "$SKILL" \
  '^### 2\\.3 関連 PR の検索' '^## Phase 3:' \
  '\*\*絞り込み前の集合を下記の判定表に載せてはならない\*\*'
# identity 昇格は headRefName が Issue スコープを満たす場合に限る (body の closing keyword だけで
# 一致した PR の head をリモートごと消させない)。
assert_grep "T-08 identity promotion is restricted to a matching headRefName" "$SKILL" \
  '\*\*identity 昇格は `headRefName` が `issue-\{issue_number\}-` を含む場合に限る\*\*'
# charset 束縛は producer ごとに並べず「値を {branch_name} に代入する時点」に 1 本置く。
# `{branch_name}` は 2.3 の `--head "{branch_name}"` と 4.3 の fenced bash へ literal substitute され、
# 引用符は `$(...)` の展開を止めない。節末の「後置条件」形だと 2.3 の consumer が未検査の値を受け取る
# (後置条件は定義上それより前の置換を遡って守れない)。述語は 2.2 に定義され 2.3 が再適用する。
assert_grep_in_section "T-08 the charset predicate is applied at assignment time, not as a post-condition" "$SKILL" \
  '^### 2\.2 作業ブランチの解決' '^### 2\.3' \
  '\*\*charset 述語（値を `\{branch_name\}` に代入する時点で適用する）\*\*'
# 2.2 の採用行が述語適用を明示していること (行が述語を参照しないと LLM が代入時に飛ばす)。
assert_grep_in_section "T-08 the 2.2 adopting rows name the predicate" "$SKILL" \
  '^### 2\.2 作業ブランチの解決' '^### 2\.3' \
  '\*\*代入の直前に下記 charset 述語を適用する\*\*'
# consumer の名指しに 2.3 の `--head` が含まれること (Phase 4.3 だけを列挙する形へ戻すと、
# 2.3 の consumer が束縛の対象外という誤読が復活する)。
assert_grep_in_section "T-08 the predicate names the 2.3 --head consumer as well" "$SKILL" \
  '^### 2\.2 作業ブランチの解決' '^### 2\.3' \
  'consumer は 2\.3 の `--head "\{branch_name\}"` と Phase 4\.3 の fenced bash の 2 つ'
# 束縛の帰結は「identity を倒す」= 既存の 4.3 ゲートに合流すること。新しい停止経路を足さない。
assert_grep_in_section "T-08 a charset violation falls into the existing identity-unverified path" "$SKILL" \
  '^### 2\.2 作業ブランチの解決' '^### 2\.3' \
  '`\{branch_identity_verified\}=false` に倒す'
# 2.3 の昇格経路にも同じ述語が再適用されること。
assert_grep_in_section "T-08 the 2.3 promotion re-applies the same predicate" "$SKILL" \
  '^### 2\.3 関連 PR の検索' '^## Phase 3:' \
  '代入の直前に 2\.2 の charset 述語を再適用する'
# 4.3 のゲートが述語を参照していること (参照が切れると LLM が 4.3 で再評価しなくなる)。
# bare 'charset' へ緩めると、参照先の語が旧称のまま取り残されても緑になる。exact literal で pin する。
assert_grep_in_section "T-08 the 4.3 gate names the charset predicate it depends on" "$SKILL" \
  '^### 4\.3 ブランチの削除' '^### 4\.4' \
  '2\.2 の charset 述語で倒れた場合を含む'
# Legend の {branch_name} 定義も同じ語彙を指すこと (実行者が Phase 2 に入る前に読む最初の指示行)。
assert_grep "T-08 the placeholder legend names the same predicate" "$SKILL" \
  '2\.2 の charset 述語（代入時点で適用）を満たしたものだけが確定値になる'
# CLOSED-unmerged の PR は Phase 3 を飛ばして Phase 4 (state purge) へ回す。
assert_grep "T-08 a closed-unmerged PR still reaches the state purge" "$SKILL" \
  '^\| `state == "CLOSED"` かつ `mergedAt` が null の PR がある \|.*\*\*Phase 3 はスキップ\*\*して Phase 4 へ'

echo "=== T-09: 後片付けが helper 委譲で、削除 bash が複製されていない (AC-9) ==="
# 削除処理は helper 内部の判断 (live-cwd guard / sandbox マスク検知 / remote ref 検証) と不可分。
# 動詞の「列挙」ではなく class 述語で pin する — 列挙形だと列挙外の削除手段 (リモート ref 削除・
# find -delete) をインライン化する退行が 4 pin すべてを素通りし、AC-9 の Then を否定したまま緑になる
# (_reviewer-base.md Defense Mechanism Integrity Gate #3: one-off deny の追加より class 述語を優先)。
# 走査対象は fenced bash 行に限定する (散文中の言及は委譲の破れではない)。
# 削除動詞は「ローカル ref / リモート ref / ファイル」を等しく含める。branch 削除を落とすと
# 例外 (b) が一度も発火しない dead 定義になり、その漏れを例外の存在が覆い隠す。
# 前置は空白ではなく「非識別子文字」で境界を取る。空白限定だと `out=$(rm -rf ...)` の `(` 直後が
# 漏れる。素の `rm[[:space:]]` へ広げると `warm ` 等が誤検出になるため境界指定は外さない。
_destructive_re='(^|[^A-Za-z0-9_-])(rm|rmdir|unlink|truncate)[[:space:]]|find[[:space:]].*-delete|git[[:space:]]+worktree[[:space:]]+(remove|prune)|git[[:space:]]+branch[[:space:]]+.*(-d|-D|--delete)|git[[:space:]]+push[[:space:]].*(--delete|[[:space:]]:)|gh[[:space:]]+api[[:space:]].*(-X|--method)[[:space:]=]*DELETE'
# 既知の例外は 2 class のみ。**いずれも行全体にアンカーする** — 部分文字列で許可すると、許可された
# 動詞と同じ行に別の破壊的操作を同居させるだけで行ごと除外され、検出力が列挙形より下がる。
#  (a) 自ブロックが mktemp した一時ファイルの後始末 — 削除対象が shell 変数のみ (`rm -f "$var"`)。
#      ワークフロー資産 (リテラルパス / `{placeholder}` を含むパス) の削除はこの形にならない。
#  (b) helper の BRANCH_DELETE_UNMERGED marker への応答 (helper 呼び出しより後にあることは下の
#      行番号比較が別途 pin する)。marker emit まで含めて 1 行として固定する。
_destructive_exception_re='^[[:space:]]*rm -f "\$[A-Za-z_][A-Za-z0-9_]*"[[:space:]]*$|^LC_ALL=C git branch -D -- "\{branch_name\}" && echo "\[CONTEXT\] BRANCH_DELETED=1;[^"]*"$'
# grep -n は付けない。行番号 prefix が付くと例外側の行頭アンカーが外れ、例外が例外として効かなくなる
# (抽出後の行番号は SKILL.md の行番号とも一致しないので、付けても診断の役に立たない)。
_destructive_hits=$(awk '/^```bash$/{f=1;next} /^```$/{f=0} f' "$SKILL" \
  | grep -E "$_destructive_re" | grep -vE "$_destructive_exception_re" || true)
if [ -z "$_destructive_hits" ]; then
  pass "T-09 no destructive verb in fenced bash outside the two known exception classes"
else
  fail "T-09 inline destructive operation found (delegation broken): $_destructive_hits"
fi
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
