#!/bin/bash
# Tests for cleanup.md ステップ 4-W / 5 / 12 の message・配線 contract (T-06).
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
DEFERRED_HELPER="$SCRIPT_DIR/../scripts/cleanup-deferred-branch-recovery.sh"
# ステップ 4-W / 5 の bash 本体は helper へ抽出済み。SKILL.md 側に残るのは routing の指示語と
# ステップ 12 の判定表なので、コード行を対象にする pin は helper を、指示語・報告文面を対象に
# する pin は SKILL.md を見る。
TEARDOWN_HELPER="$SCRIPT_DIR/../scripts/cleanup-session-worktree-teardown.sh"
BRANCH_DELETE_HELPER="$SCRIPT_DIR/../scripts/cleanup-branch-delete.sh"

echo "=== ステップ 4-W: self-exclusion 付き live-cwd guard の配線 ==="
assert_grep "4-W uses worktree-foreign-cwd.sh (not the bare live-cwd probe)" "$TEARDOWN_HELPER" "worktree-foreign-cwd\.sh"
assert_grep "4-W passes --self-root (excludes the cleanup session's harness)" "$TEARDOWN_HELPER" 'worktree-foreign-cwd\.sh.*--self-root'
# helper 内の $PPID は helper を起動したシェルを指すため、ハーネスの pid は呼び出し側が渡す。
# 呼び出しから --self-root が落ちると helper は usage error で落ちるが、SKILL.md 側でも pin する
# (helper が既定値を持つ方向へ緩められたときに、この行の消失として検出できるようにする)。
assert_grep "4-W call site passes the harness \$PPID as --self-root" "$CLEANUP" '\-\-self-root "\$PPID"'

echo "=== ステップ 4-W: session_worktree manifest 記録が {pr_merged}=true ガード配下にあること (AC-4) ==="
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
  "$TEARDOWN_HELPER" 'echo "\\[CONTEXT\\] WORKTREE_REMOVE_SKIPPED_SANDBOX_MASK=1' '^  elif \\[ "\\$dry_run" = "true" \\]; then$' \
  'record --type session_worktree'
assert_grep_in_section "4-W sandbox-mask branch: record is inside the --pr-merged=true guard" \
  "$TEARDOWN_HELPER" 'echo "\\[CONTEXT\\] WORKTREE_REMOVE_SKIPPED_SANDBOX_MASK=1' '^  elif \\[ "\\$dry_run" = "true" \\]; then$' \
  '\$pr_merged" = "true"'
assert_grep_in_section "4-W busy-failed branch: session_worktree record call present" \
  "$TEARDOWN_HELPER" 'echo "\\[CONTEXT\\] WORKTREE_REMOVE_FAILED=1' '\\[ -n "\\$_wt_rm_err" \\] && rm -f' \
  'record --type session_worktree'
assert_grep_in_section "4-W busy-failed branch: record is inside the --pr-merged=true guard" \
  "$TEARDOWN_HELPER" 'echo "\\[CONTEXT\\] WORKTREE_REMOVE_FAILED=1' '\\[ -n "\\$_wt_rm_err" \\] && rm -f' \
  '\$pr_merged" = "true"'

echo "=== ステップ 5: squash-merge 確認済みブランチの強制削除 + 遅延ブランチの manifest 記録 ==="
assert_grep "Step 5 reads the {pr_merged} signal" "$CLEANUP" "pr_merged"
assert_grep "Step 5 emits via=squash-merged on confirmed-merged force delete" "$CLEANUP" "via=squash-merged"
assert_grep "Step 5 records the deferred branch to the reap manifest" "$DEFERRED_HELPER" "rite-tmp-artifact\.sh.*record --type branch"
# Deferred branch only auto-recovers when the manifest record succeeds and the
# target worktree passes the same filtered dirty gate as the reaper (#2048).
assert_grep "Step 5 delegates recovery classification to the executable helper" "$BRANCH_DELETE_HELPER" "cleanup-deferred-branch-recovery\.sh"
assert_grep "Step 5 emits recovery=auto only after its guards" "$CLEANUP" "recovery=auto"
assert_grep "Step 5 emits recovery=manual for unsafe worktrees" "$CLEANUP" "recovery=manual"
assert_not_grep "Step 5 never prescribes force-removing a dirty worktree" "$DEFERRED_HELPER" 'git worktree remove --force'

echo "=== ステップ 12: ユーザー向けメッセージの平易化・正確化 (AC-6) ==="
# branch の遅延メッセージは「自動で削除される（手動不要）」を明記する（実装の自動回収と整合）。
assert_grep "deferred-branch message states automatic recovery (no manual step)" "$CLEANUP" "自動で削除されます（手動操作は不要）"
# worktree skip メッセージは次セッションでの自動回収を平易に伝える。
assert_grep "worktree-skip message states next-session automatic recovery" "$CLEANUP" "次回のセッション開始時に"

echo "=== ステップ 4-W: busy (EBUSY) 失敗時の sandbox 干渉 WARNING (AC-5) ==="
assert_grep "4-W detects busy git-worktree-remove stderr" "$TEARDOWN_HELPER" 'grep -qi "busy"'
assert_grep "4-W busy WARNING names sandbox ro-mount interference" "$TEARDOWN_HELPER" "config\.worktree・commondir に read-only bind mount"
assert_grep "4-W busy WARNING gives the sandbox-outside manual recovery command" "$TEARDOWN_HELPER" "sandbox 外のシェルで次を実行してください"
# busy WARNING は sandbox 起因を明示するため、harness の「sandbox 起因の失敗は
# dangerouslyDisableSandbox で即再試行」ルールの発火条件を自ら満たしてしまう。
# この WARNING を読む実行エージェント自身への「この場での再試行はしない」明示が必要
# (non-blocking で遅延 reap へ委譲する設計を守るため)。
assert_grep "4-W busy WARNING tells the executing agent not to auto-retry" "$TEARDOWN_HELPER" "実行エージェントはこの場で sandbox を無効化して同コマンドを再試行しないこと"

echo "=== ステップ 4-W: sandbox マスク検知による remove 抑止 (AC-1/AC-2) ==="
# AC-1: 検知は remove 試行の前 — 削除試行自体が admin dir を半壊させるため、検知時は
# remove (--force 含む) を一切実行せず遅延 reap (pr-cycle-cleanup.sh Step 5 corpse 回収) へ
# 委譲する。behavioral 検証 (corpse 回収側) は pr-cycle-cleanup-session-reap.test.sh C-01..C-04。
assert_grep "4-W resolves the admin dir from the worktree's .git file" "$TEARDOWN_HELPER" '_wt_admin=\$\(sed -n .s/.gitdir: //p. "\$flow_wt/\.git"'
assert_grep "4-W detects the mask as a character device on config.worktree" "$TEARDOWN_HELPER" '\-c "\$_wt_admin/config\.worktree"'
assert_grep "4-W emits the sandbox-mask skip marker" "$TEARDOWN_HELPER" "WORKTREE_REMOVE_SKIPPED_SANDBOX_MASK=1"
assert_grep "4-W mask WARNING states removal is not attempted at all" "$TEARDOWN_HELPER" "削除自体を試行しません"
assert_grep "4-W mask WARNING forbids in-place sandbox-disable retry" "$TEARDOWN_HELPER" "実行エージェントはこの場で sandbox を無効化して remove を再試行しないこと"
# AC-2 (非回帰): マスク非検知時の従来 remove 経路 (LC_ALL=C 固定の remove → --force fallback)
# が残存している — 検知ガードが常時抑止に化けたらこの pin ごと落ちる。
assert_grep "4-W keeps the conventional remove path for unmasked worktrees" "$TEARDOWN_HELPER" 'LC_ALL=C git worktree remove "\$flow_wt"'
# ステップ 12 報告: SANDBOX_MASK skip の分岐が存在し、sandbox 外での手動回収コマンドを示す。
assert_grep "Step 12 has a SANDBOX_MASK branch in {session_worktree_check}" "$CLEANUP" 'WORKTREE_REMOVE_SKIPPED_SANDBOX_MASK=1. のとき'
assert_grep "Step 12 mask message points to a sandbox-outside manual removal" "$CLEANUP" "sandbox 外のシェルで git worktree remove --force"
# Step 5 deferral 経路: mask skip が自セッション由来の第 2 ルートを作るため、旧「別 live セッション
# 在席時のみ」の排他性主張と「別のセッションの作業ツリーで使用中」の原因断定 WARNING は不正確。
# コメントは mask ルートに言及し、branch-deferral 系 WARNING は原因中立の文面を使う。
assert_grep "Step 5 comment names the SANDBOX_MASK deferral route" "$BRANCH_DELETE_HELPER" 'WORKTREE_REMOVE_SKIPPED_SANDBOX_MASK = sandbox マスク'
assert_grep "Step 5 deferred WARNING is cause-neutral" "$DEFERRED_HELPER" "まだ削除されていない作業ツリーで使用中のため、削除を見送りました"
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

echo "=== ステップ 4-W: in_worktree_unrecorded の委譲 routing (T-01/T-03) ==="
# T-01: ExitWorktree が no-op な path 入場を独立 arm に分離し、委譲 marker を emit する。
# 分岐の基準は「worktree 内か」ではなく「ExitWorktree で main checkout へ退出できるか」。
# case arm は helper の cmd_detect 内にあるためインデントが 2 → 4 スペースになった。
# ラベルと隣接構造そのものは抽出前のまま保持している（排他性 pin が依存する）。
assert_grep "4-W splits in_worktree_unrecorded into its own case arm" "$TEARDOWN_HELPER" '^    in_worktree_unrecorded\)$'
assert_grep "4-W emits the delegation marker" "$TEARDOWN_HELPER" 'CLEANUP_DELEGATED=1; reason=exit_worktree_unavailable'
assert_grep "4-W states the branch criterion is ExitWorktree availability" "$CLEANUP" 'ExitWorktree` で main checkout へ退出できるか'
# ガード迂回の禁止を明記する (MUST NOT — 実測で拒否済みの複合コマンドを再試行させない)。
assert_grep "4-W forbids bypassing the harness guard" "$CLEANUP" "ガードを迂回する複合コマンド"
# T-03 (非回帰): in_worktree arm は従来どおり dirty チェックを持ち、ExitWorktree(keep) 手順も残る。
# 委譲 arm が in_worktree まで巻き込んで batch-run 経路を止めたらこの pin ごと落ちる。
# start/end パターンの `)` は二重エスケープで書く — `-v` 経由で C 風エスケープが 1 段階解釈され、
# single backslash だと gawk が「不要なエスケープ」として潰し警告を出す（本ファイル冒頭の
# `echo "\\[CONTEXT\\] WORKTREE_REMOVE_SKIPPED_SANDBOX_MASK=1` を start に使う assert 群に付した
# エスケープ規約コメントと同型。`\*` の場合は量化子へ潰れてレンジが EOF まで伸びる）。
assert_grep_in_section "in_worktree arm keeps the dirty check" "$TEARDOWN_HELPER" \
  '^    in_worktree\\)$' '^    in_worktree_unrecorded\\)$' 'git-status-filtered\.sh'
assert_grep "in_worktree arm still routes through ExitWorktree(keep)" "$CLEANUP" 'action: "keep"'

echo "=== ステップ 4/5/9: 委譲モードのスキップガード (T-01) ==="
# main checkout 操作を持つ 3 ステップすべてに対称にガードを置く。1 箇所でも欠けると
# harness の worktree 隔離ガードに拒否され、この委譲ガードが消した長文の診断報告に戻る。
# marker 名の在処だけでなく **「実行しない」という指示語** まで pin する — prose-driven skill では
# 指示語そのものが実装本体で、marker だけを見る assert は指示の反転 (「実行しない」→「通常どおり
# 実行する」) を素通しする (mutation 実測で 4 サイト反転しても全 assert green だった)。
assert_grep_in_section "Step 4 (base update) pins the do-not-execute directive" "$CLEANUP" \
  '^### 4 base ブランチの更新' '^## ステップ 5:' 'を emit している場合、本ステップの bash を\*\*実行しない\*\*'
assert_grep_in_section "Step 5 (branch delete) pins the do-not-execute directive" "$CLEANUP" \
  '^## ステップ 5:' '^## ステップ 6:' 'を emit している場合、本ステップの bash ブロックを\*\*いずれも実行しない\*\*'
assert_grep_in_section "Step 9 (wiki ingest) pins the whole-step do-not-execute directive" "$CLEANUP" \
  '^## ステップ 9:' '^## ステップ 10:' 'を emit している場合、\*\*本ステップ全体を実行しない\*\*'
# 3 ガードとも発火条件に CLEANUP_DELEGATED と CLEANUP_WT=unknown の **両方** を持つこと。
# unknown 側が落ちると、detect 不能のまま main checkout 操作へ進む経路が復活する。
assert_grep_in_section "Step 4 gate keys on both delegation markers" "$CLEANUP" \
  '^### 4 base ブランチの更新' '^## ステップ 5:' 'CLEANUP_DELEGATED=1` \*\*または `\[CONTEXT\] CLEANUP_WT=unknown`\*\*'
assert_grep_in_section "Step 5 gate keys on both delegation markers" "$CLEANUP" \
  '^## ステップ 5:' '^## ステップ 6:' 'CLEANUP_DELEGATED=1` \*\*または `\[CONTEXT\] CLEANUP_WT=unknown`\*\*'
assert_grep_in_section "Step 9 gate keys on both delegation markers" "$CLEANUP" \
  '^## ステップ 9:' '^## ステップ 10:' 'CLEANUP_DELEGATED=1` \*\*または `\[CONTEXT\] CLEANUP_WT=unknown`\*\*'
# 4-W routing 文の指示語も同様に pin する (ガード 3 箇所と同じ理由)。
assert_grep "4-W routing pins the do-not-execute directive" "$CLEANUP" \
  '\*\*下記の手順 1〜4 を実行しない\*\*'
assert_grep "4-W routing pins the not-attempted directive" "$CLEANUP" '\*\*試行せず\*\*'

echo "=== 委譲配線の排他性 (T-01/T-03 negative control) ==="
# 「在ること」だけを見る assert は、marker の漏出 (in_worktree arm からの emit) と
# ガードの混入 (state 系ステップへの誤挿入) を検出できない。前者は AC-3 を、後者は AC-1 前半
# 「state 系項目は成功し」を丸ごと無効化するため、件数を固定して排他性そのものを pin する。
assert "delegation marker is emitted exactly once" "1" \
  "$(grep -c 'echo "\[CONTEXT\] CLEANUP_DELEGATED=1' "$TEARDOWN_HELPER")"
assert "delegation skip guard exists in exactly three steps" "3" \
  "$(grep -c '委譲モード（#2133）' "$CLEANUP")"
# 件数固定は marker の **追加** を捕まえるが **移設** は捕まえない（総数が変わらないため）。
# 住所は positive / negative の両方向で固定する — 片方だけでは変異が生存することを実測済み:
#   `*)` arm への移設 / case 文の前への持ち上げ → negative control（下段）を素通りし positive（上段）が捕まえる
#   case arm ラベルの入れ替え                    → positive（上段）を素通りし negative control（下段）が捕まえる
# 前者は再実行セッション（CLEANUP_WT=none）が `*)` に落ちるため委譲が再帰し AC-2 の Then を、
# 後者は batch-run 経路で委譲が発火し AC-3 の Then を、それぞれ無効化する。
# end パターンの `)` `*` は上記と同じ理由で二重エスケープ。
# 内側 grep は emit の **実行行** へアンカーする — 素の部分文字列一致だと、コメントアウトされた
# emit を live として数え、arm 内に marker 名を含むコメントを 1 行足すだけで赤くなる。
assert "delegation marker is emitted only from the in_worktree_unrecorded arm" "1" \
  "$(awk -v start='^    in_worktree_unrecorded\\)$' -v end='^    \\*\\)$' '$0 ~ start, $0 ~ end' "$TEARDOWN_HELPER" | grep -c '^ *echo "\[CONTEXT\] CLEANUP_DELEGATED=1')"
assert "in_worktree arm never emits the delegation marker" "0" \
  "$(awk -v start='^    in_worktree\\)$' -v end='^    in_worktree_unrecorded\\)$' '$0 ~ start, $0 ~ end' "$TEARDOWN_HELPER" | grep -c '^ *echo "\[CONTEXT\] CLEANUP_DELEGATED=1')"

echo "=== ステップ 12: 委譲モードの定型報告 (T-01/T-02) ==="
# fail-loud: 委譲 4 項目は x に丸めず未完了として列挙する。固定対象は委譲 4 項目に限り、
# 委譲モードでも実行される check (ステップ 6 / 8) は個別判定を維持する。
assert_grep "Step 12 pins the four delegated checks to unchecked" "$CLEANUP" \
  '\*\*委譲した 4 項目に限り\*\*下記の個別判定を行わず'
assert_grep "Step 12 keeps per-check judgement for steps that still run" "$CLEANUP" \
  '\*\*従来どおり個別判定する\*\*'
assert_grep "Step 12 counts outstanding as 4 plus the unchecked runtime checks" "$CLEANUP" \
  '`4` \+ 個別判定で空欄になった check の件数'
# fail-loud の「未完了として明示列挙する」側 — 4 項目リスト本体を個別に pin する
# (checkbox と件数だけの pin では、列挙が消えても「4 件未完了」とだけ告げる報告が通ってしまう)。
assert_grep "Step 12 enumerates the base update item" "$CLEANUP" '^- base ブランチの更新（fetch \+ merge --ff-only）$'
assert_grep "Step 12 enumerates the wiki ingest item" "$CLEANUP" '^- Wiki ingest（pending raw source は wiki branch に保持されています）$'
assert_grep "Step 12 enumerates the session worktree removal item" "$CLEANUP" '^- セッション worktree の削除$'
assert_grep "Step 12 enumerates the branch deletion item" "$CLEANUP" '^- ローカル/リモートブランチの削除$'
# T-02: 委譲先は main checkout での再実行 1 系統。再実行が何をどう完了させるかまで案内に含める
# （worktree とローカルブランチは再実行の**その場**では消えず、ステップ 5 の manifest 記録を経て
#  次回セッション開始時に回収される — この経路を落とすと「再実行したのに残っている」の説明が消える）。
assert_grep "Step 12 delegation notice points to a main-checkout re-run" "$CLEANUP" \
  'main checkout でセッションを開き `/rite:cleanup \{pr_number\}` を再実行してください'
assert_grep "Step 12 delegation notice states the re-run is idempotent" "$CLEANUP" \
  "実行済みの項目は冪等にスキップされます"
# 自動回収は無条件ではない（記録はステップ 5 の {pr_merged}=true gate 配下、reap は dirty guard 配下）。
# 外れる経路は 3 つ（未マージ / dirty / 記録漏れ）あるが、それぞれ案内先が違うため、案内先を 1 つに
# 名指しすると必ずどれかで外れる（実測: dirty は再実行時に評価されず recovery=auto と報告される）。
# 条件も案内先も列挙せず、退路は直後の手動コマンドが与える形に留める —  In Scope の
# 「簡潔な定型」に収める形でもある。条件節や案内先の列挙を足す方向へ戻さない。
assert_grep "Step 12 delegation notice names the deferred reclamation path" "$CLEANUP" \
  'セッション worktree とローカルブランチは次回セッション開始時の自動回収の対象になります'
# 手動コマンドは main checkout で実行する前提（worktree 内では remove が cwd を消して連鎖が止まる）。
# 失敗モードを防ぐのは限定句のみで、prune を外したのは remove --force が admin エントリを解除する
# ため冗長だから。コマンド本体まで含めて固定し、限定句・引数のどちらが欠けても落ちるようにする。
assert_grep "Step 12 manual fallback is scoped to the main checkout with its exact commands" "$CLEANUP" \
  "すぐに消したい場合（main checkout でセッションを開いたあと）: git worktree remove --force '\{flow_wt\}' && git branch -D \{branch_name\}"
# 委譲 arm は記録を行わない（記録するのは再実行時のステップ 5 の `--type branch`）。arm に
# `--type session_worktree` の record を足しても consumer 側の bypass は `_corpse -eq 1` を要求する
# ため発火せず、ブランチの force-delete arm も `branch` エントリしか受け付けない = 不発コードになる。
# 出現数を #1945 の 2 分岐（sandbox マスク検知 / busy 失敗）に固定して 3 箇所目の追加を検出する。
assert "session_worktree record stays confined to the two #1945 branches" "2" \
  "$(grep -c 'record --type session_worktree' "$TEARDOWN_HELPER")"

echo "=== ガード拒否条件の正確化 ==="
# 「構造的に拒否」の一般化は誤り — helper スクリプト内部の cd は拒否されない (実測)。
# 拒否される形を特定して書かないと、自動化可能な項目を恒久的に人手へ委ね続ける根拠になる。
assert_grep "4-W states which command shape the guard rejects" "$CLEANUP" \
  'Bash ツール呼び出しのコマンド文字列に直接 `cd \{main_root\}` / `git -C \{main_root\}` を書く形'
assert_not_grep "over-general 'structurally rejected' claim removed" "$CLEANUP" \
  'worktree 隔離ガードに構造的に拒否されるため'

echo "=== ステップ 4-W / 5 / 6: 削除処理の bash が SKILL.md に残っていない (Issue #2492 T-09 / AC-9) ==="
# 抽出の完了条件は「helper が存在する」ではなく「SKILL.md 側に実行本体が残っていない」。
# 両方に存在する状態 (コピーしただけ) は drift 源そのもので、helper 側の pin だけでは検出できない。
# 検査はセクション単位で行う — ファイル全体を grep すると、ステップ 4 (base 更新) や
# ステップ 7 (transient branch) の抽出対象外 bash に一致して vacuous になる。
_s4w=$(awk '/^### 4-W /{f=1} f && /^### 4 base/{exit} f' "$CLEANUP")
_s5=$(awk '/^## ステップ 5: /{f=1} f && /^## ステップ 6: /{exit} f' "$CLEANUP")
_s6=$(awk '/^## ステップ 6: /{f=1} f && /^## ステップ 7: /{exit} f' "$CLEANUP")
# セクション抽出そのものが空振りしていないことを先に固定する (空文字列は下の -c 検査を全て 0 にし、
# 「削除処理が残っていない」を無条件で満たしてしまう)。
assert "T-09 section 4-W extraction is non-empty" "yes" "$([ -n "$_s4w" ] && echo yes || echo no)"
assert "T-09 section 5 extraction is non-empty" "yes" "$([ -n "$_s5" ] && echo yes || echo no)"
assert "T-09 section 6 extraction is non-empty" "yes" "$([ -n "$_s6" ] && echo yes || echo no)"
# 削除本体の検出は行頭アンカーに依存させない。実行行は `if cmd; then` / `|| cmd` / `elif x=$(cmd)`
# の位置にも現れるため、`^[[:space:]]*git ...` だけでは抽出前のコード形にすら一致せず
# (実測: 抽出前の 4-W 節に当てると prune の 1 行しか拾わない)、AC-9 のゲートが検査したつもりの
# 対象を最初から見ていないことになる。コメント行を除いてからコマンド境界で照合する。
# 検査対象はフェンス内の行のみ (言語タグは見ない。素フェンスに置かれた削除本体も覆うため)。
# 散文には marker 名や手動復旧コマンドが引用として現れるため (例: BRANCH_DELETE_UNMERGED 時に
# ユーザーが強制削除を選ぶ手順の説明)、節全体に当てると AC-9 が禁じていない散文で赤くなる。
# 逆に、手動復旧コマンドを **素フェンスで** 4-W / ステップ 5 / ステップ 6 に置くと本ゲートが
# false positive で赤くなる (ステップ 12 の素フェンスは検査対象外の節にあるので現状は無害)。
# フェンスは info string を見ずにトグルする。`” ```bash ”` の完全一致で開始判定すると、
# フェンス言語を `sh` に変える・`title=` を付ける等の無害に見える Markdown 編集だけで抽出が
# 0 行になり、下の 3 ゲートが揃って vacuous 0 で pass する (実測: step 5 のフェンスを ```sh に
# 変えると削除コマンドを再注入してもスイート green)。タグ無しフェンス内の削除本体も同時に覆う。
_fenced() { awk '/^[[:space:]]*```/{f=!f;next} f'; }
_strip_comments() { grep -v '^[[:space:]]*#'; }
# フェンス抽出そのものの空振りも固定する (セクション抽出と同じ理由。こちらは節が非空でも
# フェンス判定が外れた瞬間に 0 行になるため、上の section 非空 assert では守れない)。
assert "T-09 4-W bash-fence extraction is non-empty" "yes" \
  "$(printf '%s\n' "$_s4w" | _fenced | grep -q . && echo yes || echo no)"
assert "T-09 step 5 bash-fence extraction is non-empty" "yes" \
  "$(printf '%s\n' "$_s5" | _fenced | grep -q . && echo yes || echo no)"
assert "T-09 step 6 bash-fence extraction is non-empty" "yes" \
  "$(printf '%s\n' "$_s6" | _fenced | grep -q . && echo yes || echo no)"
# 4-W: worktree の削除・prune の実行行が無く、teardown helper を呼んでいる。
assert "T-09 4-W has no inline worktree removal" "0" \
  "$(printf '%s\n' "$_s4w" | _fenced | _strip_comments | grep -cE '(^|[;&|[:space:]])git worktree (remove|prune)')"
assert "T-09 4-W delegates to the teardown helper" "2" \
  "$(printf '%s\n' "$_s4w" | grep -cE '^[[:space:]]*bash \{plugin_root\}/hooks/scripts/cleanup-session-worktree-teardown\.sh')"
# 5: ブランチ削除の実行行が無く、branch delete helper を呼んでいる。
assert "T-09 step 5 has no inline branch deletion" "0" \
  "$(printf '%s\n' "$_s5" | _fenced | _strip_comments | grep -cE '(^|[;&|[:space:]])git (branch -[dD]|push origin --delete|ls-remote)')"
assert "T-09 step 5 delegates to the branch delete helper" "1" \
  "$(printf '%s\n' "$_s5" | grep -cE '^[[:space:]]*bash \{plugin_root\}/hooks/scripts/cleanup-branch-delete\.sh')"
# 呼び出しの **引数** を pin する。件数だけの pin は、ガードを駆動する 2 引数を literal へ潰す
# 変異 (identity→true / pr-merged→true) をスイート全体で素通しする (実測済み)。
assert "T-09 step 5 threads the identity flag" "1" \
  "$(printf '%s\n' "$_s5" | grep -cF -- '--branch-identity-verified "{branch_identity_verified}"')"
assert "T-09 step 5 threads the pr-merged flag" "1" \
  "$(printf '%s\n' "$_s5" | grep -cF -- '--pr-merged "{pr_merged}"')"
assert "T-09 4-W threads the pr-merged flag" "1" \
  "$(printf '%s\n' "$_s4w" | grep -cF -- '--pr-merged "{pr_merged}"')"
# 以下 5 本は **実行行であること** まで固定する。生セクションへの grep だと、対象行をコメント
# アウトする / フェンス外の散文へ移設する変異を素通しし、「散文は言っているが bash はやっていない」
# drift をそのまま通す (実測: 5 pin とも SURVIVED)。上の否定 assert 群と同じ filter を通す。
# detect の --issue も quote する。unquoted だと値が複数トークンに割れたとき helper が
# unknown option で exit 2 し、marker を 1 本も出さない。
assert "T-09 4-W quotes the issue argument" "1" \
  "$(printf '%s\n' "$_s4w" | _fenced | _strip_comments | grep -cF -- 'detect --issue "{issue_number}"')"
# helper の rc を捨てないこと。marker 不在を「削除成功」と読む消費側の規約は、helper が
# 起動しなかった場合に marker が 1 本も出ないことで破れる。
assert "T-09 4-W captures the detect helper rc" "1" \
  "$(printf '%s\n' "$_s4w" | _fenced | _strip_comments | grep -cF -- '|| _dt_rc=$?')"
assert "T-09 4-W captures the teardown helper rc" "1" \
  "$(printf '%s\n' "$_s4w" | _fenced | _strip_comments | grep -cF -- '|| _wt_rc=$?')"
assert "T-09 step 6 captures the state purge helper rc" "1" \
  "$(printf '%s\n' "$_s6" | _fenced | _strip_comments | grep -cF -- '|| _sp_rc=$?')"
# rc 捕捉だけでは修正の本体を守れない。rc を捕捉しても marker を出さなければ消費側の
# 「marker 不在 = 削除成功」は閉じないため、marker emit 行そのものを pin する
# (実測: marker 行だけを削除した変異はスイート全体で差分ゼロだった)。
assert "T-09 4-W emits the detect failure marker" "1" \
  "$(printf '%s\n' "$_s4w" | _fenced | _strip_comments | grep -cF -- '[CONTEXT] CLEANUP_WT=unknown; reason=detect_helper_failed; rc=')"
assert "T-09 4-W emits the removal failure marker" "1" \
  "$(printf '%s\n' "$_s4w" | _fenced | _strip_comments | grep -cF -- '[CONTEXT] WORKTREE_REMOVE_FAILED=1; path={flow_wt}; rc=')"
assert "T-09 step 6 emits the state purge failure marker" "1" \
  "$(printf '%s\n' "$_s6" | _fenced | _strip_comments | grep -cF -- '[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1; reason=state_purge_helper_failed')"
# marker の **消費側** も pin する。producer だけを守っても、ステップ 12 の routing 規則や 4-W の
# 分岐指示が失われれば unknown は末尾ルール (WORKTREE_REMOVE_* 不在 = 削除成功) に落ち、detect が
# 一度も走っていないのに完了報告に x が立つ。散文の指示は marker 名の grep では守れない
# (実測: 指示を反転させる変異がスイート全体で差分ゼロだった)。
# SoT: references/wiki-promotions/patterns/prose-pin-requires-positive-control.md
assert_grep "Step 12 treats an unknown or absent CLEANUP_WT as unverified" "$CLEANUP" \
  "作業ツリーの検出自体が実行できませんでした"
assert_grep "Step 12 scopes the marker-absence read to the removal family" "$CLEANUP" \
  "この読み替えが許されるのは削除側"
assert_grep "Step 12 picks the last CLEANUP_WT occurrence (batch-run recency)" "$CLEANUP" \
  "複数あれば最後の出現 1 行だけ"
assert_grep "Step 12 omits the row only for a scoped none" "$CLEANUP" \
  "行ごと省略してよいのは .none. かつ"
assert_grep "4-W unknown routing forbids running steps 1-4" "$CLEANUP" \
  "分類不能なので\*\*上記の手順 1〜4 を実行しない\*\*"
# unknown は既存 4 gate (base 更新 / ブランチ削除 / wiki ingest / ステップ 12 委譲段落) に
# 配線されていること。CLEANUP_DELEGATED だけを見る形に戻ると、宣言だけがあって実効が無くなる。
assert "unknown is wired into the delegation gates" "3" \
  "$(grep -cF -- 'または `[CONTEXT] CLEANUP_WT=unknown`' "$CLEANUP")"
# 6: state 削除の実行行 (rite_rm の定義・呼び出し、rm -f) が無く、purge helper を呼んでいる。
# ステップ 6.0 (follow-up 起票) は抽出対象外なので、その helper 呼び出しはここでは数えない。
assert "T-09 step 6 has no inline rite_rm" "0" \
  "$(printf '%s\n' "$_s6" | grep -cE '^[[:space:]]*(rite_rm[[:space:]]|rite_rm\(\))')"
assert "T-09 step 6 delegates to the state purge helper" "1" \
  "$(printf '%s\n' "$_s6" | grep -cE '^[[:space:]]*bash \{plugin_root\}/hooks/scripts/cleanup-pr-state-purge\.sh')"

if ! print_summary "$(basename "$0")" "cleanup.md ステップ 4-W/5/12 の self-exclusion 配線・branch 回収・平易メッセージ contract (T-06) + in_worktree_unrecorded 委譲 routing + helper 抽出の完了 (T-09)"; then
  exit 1
fi
