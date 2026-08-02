#!/bin/bash
# Tests for the "未完了事項" (outstanding items) aggregation contract added by
# Issue #1946 (T-01/T-02/T-03): non-blocking failures that a flow continued
# past (wiki push failure, branch deletion deferral, etc.) must be surfaced
# in the flow's completion report instead of only appearing as scattered
# per-checkbox annotations that are easy to miss.
#
# cleanup.md / batch-run.md / wiki-ingest.md / recover.md are prose-driven
# skills (LLM-executed, not scripts), so this suite follows the same
# static-contract convention as cleanup-message-contract.test.sh: grep-pin
# the literal markers/sections so drift is caught without needing to run an
# LLM turn.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

CLEANUP="$SCRIPT_DIR/../../skills/cleanup/SKILL.md"
BATCH_RUN="$SCRIPT_DIR/../../skills/batch-run/SKILL.md"
WIKI_INGEST="$SCRIPT_DIR/../../skills/wiki-ingest/SKILL.md"
RECOVER="$SCRIPT_DIR/../../skills/recover/SKILL.md"

echo "=== cleanup.md ステップ 12: 未完了事項の集約セクション (T-01, T-02) ==="
assert_grep "Step 12 report has a 未完了事項 section" "$CLEANUP" '^未完了事項:$'
assert_grep "Step 12 has the {outstanding_items_block} placeholder" "$CLEANUP" '\{outstanding_items_block\}'
assert_grep "outstanding_items_block rule aggregates the same per-check annotations" "$CLEANUP" '付記文をそのまま箇条書きで列挙する'
# T-01/T-02 感度強化: 6 個の check 名が enumeration 行に「この順序で」列挙されていることを
# line-anchored pattern で pin する (各 check 名は checklist 本体・判定 prose にも独立に出現するため、
# assert_grep_in_section によるセクションスコープは同一セクション内の別行にも同語が出現すると
# 判別できない — mutation テストで {local_branch_check} を enumeration から削除しても
# 別行の言及に一致し続けて green のままになることを確認済み。1 行内の順序付き列挙を
# 直接 anchor する本方式はこの穴を持たない)。
assert_grep "outstanding_items_block enumeration lists all 6 checks in order (T-01/T-02, AC-1/AC-2)" \
  "$CLEANUP" '\{base_update_check\}.*\{session_worktree_check\}.*\{local_branch_check\}.*\{projects_check\}.*\{wiki_ingest_check\}.*\{review_cleanup_check\}'
# 判定基準は絵文字 prefix ではなくチェックボックスの空欄/x であることを pin する。
# 絵文字 prefix 一致方式は {local_branch_check} の BRANCH_DELETE_FAILED/UNMERGED（prefix 無しの
# bare-text 付記）を取りこぼし、まさに T-02 が守るべきシナリオ（ブランチ削除失敗）で
# AC-1/AC-2 を破っていた。チェックボックス基準ならこの取りこぼしが構造的に起きない。
assert_grep "outstanding_items_block selects by unchecked checkbox, not emoji prefix" "$CLEANUP" 'チェックボックスが `x` ではなく空欄（未チェック）として描画されたもの'
assert_not_grep "outstanding_items_block no longer relies on an emoji-prefix allowlist" "$CLEANUP" '`⚠️` で始まる付記'

echo "=== cleanup.md ステップ 12: 失敗ゼロ件時の明示 (T-03, AC-3) ==="
assert_grep "outstanding_items_block emits an explicit 'none' line when clean" "$CLEANUP" 'なし（非ブロッキングで継続した失敗はありませんでした）'

echo "=== cleanup.md ステップ 12: batch-run が読む outstanding count sentinel ==="
assert_grep "Step 12 emits the [cleanup:outstanding:{n}] sentinel" "$CLEANUP" '\[cleanup:outstanding:\{n\}\]'
assert_grep "outstanding sentinel is placed alongside returned-to-caller" "$CLEANUP" '\[cleanup:outstanding:\{n\}\] --> <!-- skill return signal'

echo "=== batch-run.md: run-queue に outstanding[] 配列を追加 ==="
assert_grep "run-queue schema includes outstanding field (init doc)" "$BATCH_RUN" 'cursor, mode, failed, outstanding, active, updated_at'
assert_grep "queue initialization literal includes outstanding:[]" "$BATCH_RUN" 'failed:\[\], outstanding:\[\], active:true'

echo "=== batch-run.md ステップ 6: cleanup の outstanding sentinel を run-queue に記録 ==="
assert_grep "Step 6 reads the [cleanup:outstanding:N] sentinel" "$BATCH_RUN" '\[cleanup:outstanding:N\]'
assert_grep "Step 6 records into outstanding[] via jq" "$BATCH_RUN" '\.outstanding = \(\(\.outstanding // \[\]\) \+ \[\$n\] \| unique\)'
assert_grep "Step 6 emits RUN_OUTSTANDING_RECORDED" "$BATCH_RUN" 'RUN_OUTSTANDING_RECORDED'

echo "=== batch-run.md ステップ 7: 完了通知への未完了事項ロールアップ ==="
assert_grep "Step 7 bash reads outstanding from the queue" "$BATCH_RUN" 'outstanding=\$\(jq -rc'
assert_grep "Step 7 merge-mode message has an 未完了事項 rollup line" "$BATCH_RUN" '未完了事項: （`outstanding=` が空のとき）なし'

echo "=== wiki-ingest.md ステップ 9: 未完了事項 (Issue #1946, In Scope) ==="
assert_grep "Step 9 report template has 未完了事項 line" "$WIKI_INGEST" '\{ingest_outstanding_line\}'
# pin literal は「その行を削除する変異を自分の assert が kill できる」ことが要件なので、
# ラベルが主張する契約と 1 対 1 に対応する行固有の literal を選ぶ (SKILL.md 内 1 hit を実測済)。
# 素の n_stats_abort (5 hits) や素の WIKI_INGEST_STATS=ok (3 hits) のような広い literal は、
# 対象行を消しても別箇所に一致し続けて変異が生存する。
assert_grep "ingest_outstanding_line adds no new record store" "$WIKI_INGEST" '新しい記録先は持たない'
assert_grep "ingest_outstanding_line evaluates exactly 2 markers" "$WIKI_INGEST" '2 marker を評価し'
assert_grep "ingest_outstanding_line pins the WIKI_INGEST_STATS abort row" "$WIKI_INGEST" '統計同期: {r} により中止'
assert_grep "ingest_outstanding_line treats a missing WIKI_INGEST_STATS marker as unconfirmed" "$WIKI_INGEST" '統計同期: 実行結果が確認できませんでした'
assert_grep "completion report breakdown surfaces n_stats_abort" "$WIKI_INGEST" '統計同期中止 \{n_stats_abort\}'
assert_grep "completion report equation includes n_stats_abort" "$WIKI_INGEST" '\+ n_lint_anomaly \+ n_stats_abort'
assert_grep "ingest_outstanding_line emits explicit none line when push ok" "$WIKI_INGEST" 'なし（非ブロッキングで継続した失敗はありませんでした）'
# marker なし (未確認) は「なし」と混同せず {wiki_push_line} と同じ ⚠️ 未確認扱いにする
assert_grep "ingest_outstanding_line treats marker-absent as unconfirmed, not none" "$WIKI_INGEST" '\{wiki_push_line\}` の同ケースと同じ扱い'

# consumer 行 (上記) だけを pin しても、producer が消えれば正常サイクルで「marker なし → ⚠️ 未確認」が
# 毎回誤発火するので守るものが無くなる。3 値契約は emit 側と解釈側を対で pin する。
echo "=== wiki-ingest.md ステップ 6 手順 3: WIKI_INGEST_STATS 3 値契約の producer 側 ==="
assert_grep "stats ok marker is emitted by the LLM after the 3-line Edit, not by the bash block" \
  "$WIKI_INGEST" 'LLM が 3 行の Edit を適用したあとに emit する'
assert_grep "stats ok marker literal exists on the producer side" "$WIKI_INGEST" '\[CONTEXT\] WIKI_INGEST_STATS=ok'
assert_grep "a no-op Edit (values already in sync) still emits ok" "$WIKI_INGEST" 'Edit が no-op になった場合も'
assert_grep "stats skip path pins the no_stats_section reason" "$WIKI_INGEST" 'reason=no_stats_section'
assert_grep "stats skip path pins the no_page_change reason" "$WIKI_INGEST" 'reason=no_page_change'
assert_grep "ok / skipped produce no outstanding row" "$WIKI_INGEST" '行を出さない'
assert_grep "step 3 runs once per cycle, gated on the n_raw_sources counter" "$WIKI_INGEST" 'に達したときに実行する'
# 重複行の削除は統計の可否から切り離す (統計節なし / 中止 5 経路でも index が自己修復できること)
assert_grep "duplicate-row removal is not gated on the stats sync" "$WIKI_INGEST" '\(3b\) の可否と無関係に常に実行する'

echo "=== recover.md: 未完了事項の検出 (Issue #1946, cleanup/completed 到達時のみ, informational) ==="
assert_grep "recover has the outstanding-item detection subsection" "$RECOVER" '### 3\.6 未完了事項の検出'
# gate は {resolved_phase} LLM placeholder 形式でなければならない ($resolved_phase シェル変数形式は
# 別 Bash tool 呼び出しで常に空文字になり検出ロジックが dead code 化する)
assert_grep "detection is gated on {resolved_phase} placeholder, not a shell variable" "$RECOVER" '\[ "\{resolved_phase\}" = "cleanup" \] \|\| \[ "\{resolved_phase\}" = "completed" \]'
assert_not_grep "detection no longer references the dead \$resolved_phase shell variable" "$RECOVER" '\[ "\$resolved_phase" = "cleanup" \]'
assert_grep "detection checks unpushed wiki worktree commits" "$RECOVER" 'RECOVER_OUTSTANDING_WIKI'
assert_grep "detection checks a residual local branch with no OPEN PR" "$RECOVER" 'RECOVER_OUTSTANDING_BRANCH'
# wiki-worktree パスは state-path-resolve.sh で root 解決してから触る (multi_session worktree 実行時に
# 相対パス .rite/wiki-worktree が cwd 基準で解決できないバグの修正)
assert_grep "wiki-worktree path is resolved via state-path-resolve.sh, not a bare relative path" "$RECOVER" 'wiki_wt="\$state_root/\.rite/wiki-worktree"'
# origin に対応 ref が無い (一度も push が成功していない最悪ケース) も検出側に倒す (false negative 修正)
assert_grep "detection distinguishes an unresolved origin ref from zero unpushed commits" "$RECOVER" 'reason=no_remote_ref'

if ! print_summary "$(basename "$0")" "cleanup/batch-run/wiki-ingest/recover の未完了事項集約 contract (Issue #1946 T-01/T-02/T-03)"; then
  exit 1
fi
