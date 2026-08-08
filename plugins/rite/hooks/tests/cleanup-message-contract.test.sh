#!/bin/bash
# Tests for cleanup.md ステップ 4-W / 5 / 12 の message・配線 contract (Issue #1670, T-06).
#
# cleanup.md は prose-driven command なので、behavioral 検証は worktree-foreign-cwd.test.sh
# (self-exclusion 判定) と pr-cycle-cleanup-session-reap.test.sh (branch recovery) が担う。
# 本テストは、それらに配線する cleanup.md 側の記述が drift しないことを grep で固定する:
#   1. ステップ 4-W が self-exclusion 付き worktree-foreign-cwd.sh に --self-root を渡している
#   2. ステップ 5 が squash-merge 確認済みブランチを強制削除し、遅延ブランチを manifest 記録する
#   3. ユーザー向け遅延メッセージが平易・正確（内部実装語が無く、branch の自動回収を明記）
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

CLEANUP="$SCRIPT_DIR/../../skills/cleanup/SKILL.md"

echo "=== ステップ 4-W: self-exclusion 付き live-cwd guard の配線 ==="
assert_grep "4-W uses worktree-foreign-cwd.sh (not the bare live-cwd probe)" "$CLEANUP" "worktree-foreign-cwd\.sh"
assert_grep "4-W passes --self-root \$PPID (excludes the cleanup session's harness)" "$CLEANUP" 'worktree-foreign-cwd\.sh.*--self-root'

echo "=== ステップ 4-W: session_worktree manifest 記録が {pr_merged}=true ガード配下にあること (Issue #1945 AC-4) ==="
# 未マージ PR の強制 cleanup で corpse worktree のパスが記録され、Step 5 の corpse age-guard
# バイパス（dirty チェック無し）に晒される事故を防ぐ唯一の防波堤。ガード行と record 呼び出しの
# 両方を、それぞれの分岐（sandbox マスク検知 / busy 削除失敗）の狭いセクション内で固定する — 汎用の
# "pr_merged という語がどこかにある" だけの assert では、ガードが record 呼び出しから外れて
# 常時記録に regression しても検知できない。
## start パターンは `echo "[CONTEXT] ...` 形式の bash コード行にのみ一致させる（`[CONTEXT]` 接頭辞
## を含めない生の marker 名だけだと、ステップ 12 の説明文（同じ marker 名をバッククォート引用する
## prose 行）にも一致し、awk flip-flop レンジが最初の end 一致後にそこで再起動して EOF まで伸びる
## — section scoping が実質無効化され、コード側 guard が regression しても prose 側の記述が
## 生き残る限り silent pass しうる。`echo "[CONTEXT] ` 接頭辞は bash コード行にしか出現しないため、
## この曖昧さを構造的に排除する。
## start/end は assert_grep_in_section 内部で `awk -v` に渡り、awk の -v 引数は C 風エスケープを
## 1段階解釈してから正規表現エンジンに渡す（`\[` は「不要なエスケープ」として警告付きで `[` に
## 潰される）。ERE として `\[`/`\]`（リテラル bracket）を正規表現エンジンまで届けるには、-v 側の
## 解釈で 1 段階消費される分を見越して `\\[`/`\\]`（バックスラッシュ2つ）を渡す必要がある
## （1つだけだと `[CONTEXT]` が bracket 式として解釈され match しなくなる／過剰マッチの温床にもなる）。
assert_grep_in_section "4-W sandbox-mask branch: session_worktree record call present" \
  "$CLEANUP" 'echo "\\[CONTEXT\\] WORKTREE_REMOVE_SKIPPED_SANDBOX_MASK=1' '^     else$' \
  'record --type session_worktree'
assert_grep_in_section "4-W sandbox-mask branch: record is inside the {pr_merged}=true guard" \
  "$CLEANUP" 'echo "\\[CONTEXT\\] WORKTREE_REMOVE_SKIPPED_SANDBOX_MASK=1' '^     else$' \
  '\{pr_merged\}" = "true"'
assert_grep_in_section "4-W busy-failed branch: session_worktree record call present" \
  "$CLEANUP" 'echo "\\[CONTEXT\\] WORKTREE_REMOVE_FAILED=1' '\\[ -n "\\$_wt_rm_err" \\] && rm -f' \
  'record --type session_worktree'
assert_grep_in_section "4-W busy-failed branch: record is inside the {pr_merged}=true guard" \
  "$CLEANUP" 'echo "\\[CONTEXT\\] WORKTREE_REMOVE_FAILED=1' '\\[ -n "\\$_wt_rm_err" \\] && rm -f' \
  '\{pr_merged\}" = "true"'

echo "=== ステップ 5: squash-merge 確認済みブランチの強制削除 + 遅延ブランチの manifest 記録 ==="
assert_grep "Step 5 reads the {pr_merged} signal" "$CLEANUP" "pr_merged"
assert_grep "Step 5 emits via=squash-merged on confirmed-merged force delete" "$CLEANUP" "via=squash-merged"
assert_grep "Step 5 records the deferred branch to the reap manifest" "$CLEANUP" "rite-tmp-artifact\.sh record --type branch"
# Deferred branch only auto-recovers when the manifest record actually succeeds; the
# marker carries recovery=auto/manual so Step 12 never promises auto-recovery on a
# path that did not record (unmerged force-cleanup / record failure) — AC-6.
assert_grep "Step 5 emits recovery=auto when manifest record succeeds" "$CLEANUP" "recovery=auto"
assert_grep "Step 5 emits recovery=manual when not recorded" "$CLEANUP" "recovery=manual"

echo "=== ステップ 12: ユーザー向けメッセージの平易化・正確化 (AC-6) ==="
# branch の遅延メッセージは「自動で削除される（手動不要）」を明記する（実装の自動回収と整合）。
assert_grep "deferred-branch message states automatic recovery (no manual step)" "$CLEANUP" "自動で削除されます（手動操作は不要）"
# worktree skip メッセージは次セッションでの自動回収を平易に伝える。
assert_grep "worktree-skip message states next-session automatic recovery" "$CLEANUP" "次回のセッション開始時に"

echo "=== ステップ 4-W: busy (EBUSY) 失敗時の sandbox 干渉 WARNING (Issue #1923 AC-5) ==="
assert_grep "4-W detects busy git-worktree-remove stderr" "$CLEANUP" 'grep -qi "busy"'
assert_grep "4-W busy WARNING names sandbox ro-mount interference" "$CLEANUP" "config\.worktree・commondir に read-only bind mount"
assert_grep "4-W busy WARNING gives the sandbox-outside manual recovery command" "$CLEANUP" "sandbox 外のシェルで次を実行してください"
# busy WARNING は sandbox 起因を明示するため、harness の「sandbox 起因の失敗は
# dangerouslyDisableSandbox で即再試行」ルールの発火条件を自ら満たしてしまう。
# この WARNING を読む実行エージェント自身への「この場での再試行はしない」明示が必要
# (non-blocking で遅延 reap へ委譲する設計を守るため)。
assert_grep "4-W busy WARNING tells the executing agent not to auto-retry" "$CLEANUP" "実行エージェントはこの場で sandbox を無効化して同コマンドを再試行しないこと"

echo "=== ステップ 4-W: sandbox マスク検知による remove 抑止 (Issue #1957 AC-1/AC-2) ==="
# AC-1: 検知は remove 試行の前 — 削除試行自体が admin dir を半壊させるため、検知時は
# remove (--force 含む) を一切実行せず遅延 reap (pr-cycle-cleanup.sh Step 5 corpse 回収) へ
# 委譲する。behavioral 検証 (corpse 回収側) は pr-cycle-cleanup-session-reap.test.sh C-01..C-04。
assert_grep "4-W resolves the admin dir from the worktree's .git file" "$CLEANUP" '_wt_admin=\$\(sed -n .s/.gitdir: //p. "\{flow_wt\}/\.git"'
assert_grep "4-W detects the mask as a character device on config.worktree" "$CLEANUP" '\-c "\$_wt_admin/config\.worktree"'
assert_grep "4-W emits the sandbox-mask skip marker" "$CLEANUP" "WORKTREE_REMOVE_SKIPPED_SANDBOX_MASK=1"
assert_grep "4-W mask WARNING states removal is not attempted at all" "$CLEANUP" "削除自体を試行しません"
assert_grep "4-W mask WARNING forbids in-place sandbox-disable retry" "$CLEANUP" "実行エージェントはこの場で sandbox を無効化して remove を再試行しないこと"
# AC-2 (非回帰): マスク非検知時の従来 remove 経路 (LC_ALL=C 固定の remove → --force fallback)
# が残存している — 検知ガードが常時抑止に化けたらこの pin ごと落ちる。
assert_grep "4-W keeps the conventional remove path for unmasked worktrees" "$CLEANUP" 'LC_ALL=C git worktree remove "\{flow_wt\}"'
# ステップ 12 報告: SANDBOX_MASK skip の分岐が存在し、sandbox 外での手動回収コマンドを示す。
assert_grep "Step 12 has a SANDBOX_MASK branch in {session_worktree_check}" "$CLEANUP" 'WORKTREE_REMOVE_SKIPPED_SANDBOX_MASK=1. のとき'
assert_grep "Step 12 mask message points to a sandbox-outside manual removal" "$CLEANUP" "sandbox 外のシェルで git worktree remove --force"
# Step 5 deferral 経路: mask skip が自セッション由来の第 2 ルートを作るため、旧「別 live セッション
# 在席時のみ」の排他性主張と「別のセッションの作業ツリーで使用中」の原因断定 WARNING は不正確。
# コメントは mask ルートに言及し、branch-deferral 系 WARNING は原因中立の文面を使う (Issue #1957)。
assert_grep "Step 5 comment names the SANDBOX_MASK deferral route" "$CLEANUP" 'WORKTREE_REMOVE_SKIPPED_SANDBOX_MASK = sandbox マスク'
assert_grep "Step 5 deferred WARNING is cause-neutral" "$CLEANUP" "まだ削除されていない作業ツリーで使用中のため、削除を見送りました"
assert_not_grep "old exclusive-cause claim removed from Step 5 comment" "$CLEANUP" "本経路に来るのは"
assert_not_grep "old other-session attribution removed from deferred WARNINGs" "$CLEANUP" "はまだ別のセッションの作業ツリーで使用中のため"
assert_not_grep "old exclusive-cause claim removed from in_main note" "$CLEANUP" "別セッション在席時のみ遅延する"
assert_not_grep "old other-session release attribution removed from Step 5 manifest comment" "$CLEANUP" "別 live セッションが worktree を"
assert_not_grep "old other-session gloss removed from BRANCH_DELETE_DEFERRED definition" "$CLEANUP" "（別セッションが worktree を使用中で削除を遅延したケース）"

echo "=== ステップ 12: 旧・内部実装語/不正確な記述が除去されている ==="
# 旧 worktree-skip メッセージの内部用語「遅延 reap が後で回収します」は撤去済み。
assert_not_grep "old jargon '遅延 reap が後で回収します' removed" "$CLEANUP" "遅延 reap が後で回収します"
# 旧 branch-deferred メッセージ「worktree で checkout 中のため残置しました」は撤去済み。
assert_not_grep "old branch-deferred residue wording removed" "$CLEANUP" "worktree で checkout 中のため残置しました"

echo "=== ステップ 4-W: in_worktree_unrecorded の委譲 routing (Issue #2133 T-01/T-03) ==="
# T-01: ExitWorktree が no-op な path 入場を独立 arm に分離し、委譲 marker を emit する。
# 分岐の基準は「worktree 内か」ではなく「ExitWorktree で main checkout へ退出できるか」。
assert_grep "4-W splits in_worktree_unrecorded into its own case arm" "$CLEANUP" '^  in_worktree_unrecorded\)$'
assert_grep "4-W emits the delegation marker" "$CLEANUP" 'CLEANUP_DELEGATED=1; reason=exit_worktree_unavailable'
assert_grep "4-W states the branch criterion is ExitWorktree availability" "$CLEANUP" 'ExitWorktree` で main checkout へ退出できるか'
# ガード迂回の禁止を明記する (Issue #2133 MUST NOT — 実測で拒否済みの複合コマンドを再試行させない)。
assert_grep "4-W forbids bypassing the harness guard" "$CLEANUP" "ガードを迂回する複合コマンド"
# T-03 (非回帰): in_worktree arm は従来どおり dirty チェックを持ち、ExitWorktree(keep) 手順も残る。
# 委譲 arm が in_worktree まで巻き込んで batch-run 経路を止めたらこの pin ごと落ちる。
assert_grep_in_section "in_worktree arm keeps the dirty check" "$CLEANUP" \
  '^  in_worktree\)$' '^  in_worktree_unrecorded\)$' 'git-status-filtered\.sh'
assert_grep "in_worktree arm still routes through ExitWorktree(keep)" "$CLEANUP" 'action: "keep"'

echo "=== ステップ 4/5/9: 委譲モードのスキップガード (Issue #2133 T-01) ==="
# main checkout 操作を持つ 3 ステップすべてに対称にガードを置く。1 箇所でも欠けると
# harness の worktree 隔離ガードに拒否され、Issue #2133 が消した長文の診断報告に戻る。
assert_grep_in_section "Step 4 (base update) has the delegation skip guard" "$CLEANUP" \
  '^### 4 base ブランチの更新' '^## ステップ 5:' 'CLEANUP_DELEGATED=1'
assert_grep_in_section "Step 5 (branch delete) has the delegation skip guard" "$CLEANUP" \
  '^## ステップ 5:' '^## ステップ 6:' 'CLEANUP_DELEGATED=1'
assert_grep_in_section "Step 9 (wiki ingest) has the delegation skip guard" "$CLEANUP" \
  '^## ステップ 9:' '^## ステップ 10:' 'CLEANUP_DELEGATED=1'

echo "=== ステップ 12: 委譲モードの定型報告 (Issue #2133 T-01/T-02) ==="
# fail-loud: 委譲 4 項目は x に丸めず未完了として列挙する。
assert_grep "Step 12 pins the four delegated checks to unchecked" "$CLEANUP" \
  '4 つを ` `（未完了）に固定'
assert_grep "Step 12 fixes the outstanding count to 4" "$CLEANUP" '`\{n\}` は `4` 固定'
# T-02: 委譲先は main checkout での再実行 1 行。冪等であることを案内に含める。
assert_grep "Step 12 delegation notice points to a main-checkout re-run" "$CLEANUP" \
  'main checkout でセッションを開き `/rite:cleanup \{pr_number\}` を再実行してください'
assert_grep "Step 12 delegation notice states the re-run is idempotent" "$CLEANUP" \
  "実行済みの項目は冪等にスキップされます"

if ! print_summary "$(basename "$0")" "cleanup.md ステップ 4-W/5/12 の self-exclusion 配線・branch 回収・平易メッセージ contract (Issue #1670 T-06) + in_worktree_unrecorded 委譲 routing (Issue #2133)"; then
  exit 1
fi
