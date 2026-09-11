#!/bin/bash
# Tests for the "未完了事項" (outstanding items) aggregation contract added by
#  (T-01/T-02/T-03): non-blocking failures that a flow continued
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

echo "=== cleanup.md ステップ 8/12: skipped_terminal_conflict は outstanding に倒さない ==="
assert_grep "step 8 case arm for skipped_terminal_conflict" "$CLEANUP" 'skipped_terminal_conflict'
assert_grep "step 8 emits PROJECTS_STATUS_UPDATED=skipped_terminal" "$CLEANUP" 'projects_status_updated="skipped_terminal"'
assert_grep "step 12 maps skipped_terminal to projects_check=x on the same rule" "$CLEANUP" \
  'PROJECTS_STATUS_UPDATED=skipped_terminal` が見つかったとき: `\{projects_status_result\}` = `Cancelled のため Done 上書きをスキップ`、`\{projects_check\}` = `x`'
assert_not_grep "skipped_terminal rule does not set empty checkbox (outstanding)" "$CLEANUP" \
  'PROJECTS_STATUS_UPDATED=skipped_terminal.*\{projects_check\}` = ` `'
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

echo "=== wiki-ingest.md ステップ 9: 未完了事項 (In Scope) ==="
assert_grep "Step 9 report template has 未完了事項 line" "$WIKI_INGEST" '\{ingest_outstanding_line\}'
assert_grep "ingest_outstanding_line reuses WIKI_INGEST_PUSH marker (no new record store)" "$WIKI_INGEST" '新しい記録先は持たない'
assert_grep "ingest_outstanding_line emits explicit none line when push ok" "$WIKI_INGEST" 'なし（非ブロッキングで継続した失敗はありませんでした）'
# marker なし (未確認) は「なし」と混同せず {wiki_push_line} と同じ ⚠️ 未確認扱いにする
assert_grep "ingest_outstanding_line treats marker-absent as unconfirmed, not none" "$WIKI_INGEST" '\{wiki_push_line\}` の同ケースと同じ扱い'

echo "=== recover.md: 未完了事項の検出 (cleanup/completed 到達時のみ, informational) ==="
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

echo "=== 要対応: stderr の WARNING を完了報告へ転記する contract ==="
# stderr は LLM 向けの診断で端末に届く保証がない。転記規則の 2 点 (LLM 専用 / 完了報告へ転記) と、
# 3 orchestrator の `要対応:` 欄・zero-item rule を literal で pin する。0 件で欄が消える挙動は
# 実行時にしか観測できないため、省略を指示する文言そのものを契約として固定する。
AUTONOMOUS="$SCRIPT_DIR/../../skills/rite-workflow/references/autonomous-execution.md"
COMMON_ERR="$SCRIPT_DIR/../../references/common-error-handling.md"
OPEN="$SCRIPT_DIR/../../skills/open/SKILL.md"
ITERATE="$SCRIPT_DIR/../../skills/iterate/SKILL.md"
WORKFLOW="$SCRIPT_DIR/../../skills/rite-workflow/SKILL.md"
SPEC="$SCRIPT_DIR/../../../../docs/SPEC.md"

assert_grep "autonomous-execution states bash output is for the LLM, not the terminal" "$AUTONOMOUS" 'ユーザーの端末に届く保証はない'
assert_grep "autonomous-execution mandates transcription into the completion report" "$AUTONOMOUS" '完了報告の `要対応:` 欄へ 1 行ずつ転記する'
assert_grep "common-error-handling states the duty as stderr + transcription" "$COMMON_ERR" 'stderr 出力 \+ 完了報告への転記義務'
assert_not_grep "common-error-handling no longer claims a bare stderr display duty" "$COMMON_ERR" 'stderr 表示義務'
# 報告経路の本数を skill ごとに literal で pin する。期待値を実測値から作ると 0 本でも 0 == 0 で
# 通る（真空パス）ため、欄・プレースホルダの対の本数を直接固定する。
# 停止・失敗経路こそユーザーの操作が必要な WARNING が残る出口なので、正常終了だけを数えない。
# 経路を増減させたときは本 assert の期待値も更新する（新経路が欄なしで増える方向は本数側では
# 検出できないため、ここは人手ゲートに倒す）。
# open は完了通知 1 本。iterate は完了 3 テンプレ + 中断 1 テンプレ + ブレーカー停止 2 テンプレ。
# batch-run はステップ 7 完了通知 2 本 + ステップ 8 停止報告 1 本。
for entry in "$OPEN:1" "$ITERATE:6" "$BATCH_RUN:3"; do
  f="${entry%:*}"
  expected="${entry##*:}"
  name=$(basename "$(dirname "$f")")
  assert_grep "$name defines the {action_items} placeholder" "$f" '\{action_items\}'
  assert_grep "$name omits the section when there is nothing to transcribe" "$f" '0 件なら `要対応:` 行ごと省略する'
  assert "$name carries the 要対応 section on all $expected report paths" "$expected" "$(grep -c '^要対応:$' "$f")"
  # 欄とプレースホルダを対で pin する。presence-only では、{action_items} が placeholder 表と
  # 規則の散文でも hit するためテンプレ本体から消えても素通りする。
  assert "$name pairs every 要対応 section with {action_items}" "$expected" "$(grep -A1 '^要対応:$' "$f" | grep -c '^{action_items}$')"
done

echo "=== 要対応: 最終試行・重複・skill 固有分類 ==="
assert_grep "autonomous-execution uses the final attempt for unresolved action items" "$AUTONOMOUS" \
  '同じ command / phase の最終試行で WARNING / ERROR が残り、かつ後続に同じ操作の成功 marker が無い行を転記する'
assert_grep "autonomous-execution defines severity plus normalized body as the dedup key" "$AUTONOMOUS" \
  '重複キーは severity と本文の組とする'
assert_grep "autonomous-execution only merges exact duplicate keys" "$AUTONOMOUS" \
  'この 2 要素が完全一致する行だけを最初の出現 1 行へまとめる'
assert_grep "autonomous-execution preserves warnings with a different target, reason, or remedy" "$AUTONOMOUS" \
  'severity・対象・理由・対処のいずれかが異なる行は別項目として出現順を保つ'
assert_grep "batch-run delegates final-attempt and duplicate handling to the shared contract" "$BATCH_RUN" \
  '最終試行と重複の判定は \[Autonomous Execution\]'
assert_grep "docs/SPEC pins the merge command in the decomposed workflow" "$SPEC" \
  '`/rite:merge <pr>` runs `gh pr merge --squash`'

direct_warning_emit_count=$(grep -cE '^[[:space:]]*echo "WARNING:' "$OPEN")
classified_warning_count=$(awk '
  /^### `open` 直接 WARNING の転記判定$/ { inside=1; next }
  inside == 1 && /^---$/ { inside=0 }
  inside == 1 && /^\| `WARNING:/ { count++ }
  END { print count+0 }
' "$OPEN")
assert "open has exactly 3 direct WARNING emit sites" "3" "$direct_warning_emit_count"
assert "open classifies exactly the same 3 direct WARNING sites" "$direct_warning_emit_count" "$classified_warning_count"
assert_grep "open emits the exact git-status guard warning" "$OPEN" \
  '^[[:space:]]*echo "WARNING: git status の実行に失敗したため dirty main checkout ガードを skip します \(従来挙動で続行\)" >&2$'
assert_grep "open emits the exact gitignore warning" "$OPEN" \
  '^[[:space:]]*echo "WARNING: \$wt_path/\.rite/\.gitignore を作成できませんでした。このディレクトリが git から除外されているか手動で確認してください" >&2$'
assert_grep "open emits the exact settings-copy warning" "$OPEN" \
  '^[[:space:]]*echo "WARNING: \.claude/settings\.local\.json のコピーに失敗しました — ドッグフーディング上書きが worktree に反映されません" >&2$'
assert_grep_in_section "open classifies the git-status guard warning" "$OPEN" \
  '^### `open` 直接 WARNING の転記判定$' '^---$' \
  '^\| `WARNING: git status の実行に失敗したため dirty main checkout ガードを skip します` \| 常に転記 \|$'
assert_grep_in_section "open classifies the gitignore warning and its diagnostic continuation" "$OPEN" \
  '^### `open` 直接 WARNING の転記判定$' '^---$' \
  '^\| `WARNING: \{wt_path\}/\.rite/\.gitignore を作成できませんでした`.*`_RITE_GITIGNORE_ERROR`'
assert_grep_in_section "open classifies the settings copy warning" "$OPEN" \
  '^### `open` 直接 WARNING の転記判定$' '^---$' \
  '^\| `WARNING: \.claude/settings\.local\.json のコピーに失敗しました`'

echo "=== iterate: action_items legend とブレーカー復旧情報 ==="
assert_grep_in_section "iterate declares action_items in the Placeholder Legend" "$ITERATE" \
  '^## Placeholder Legend$' '^---$' '^\| `\{action_items\}` \|'
assert_grep_in_section "iterate routes REFIRE recovery detail through action_items" "$ITERATE" \
  '^#### `\{action_items\}` 追加項目（ステップ 6\.2 のみ）$' '^---$' \
  '起動時点で cycle counter が上限に達していたため、この起動では review を 1 回も回さずに発火しました'
assert_grep_in_section "iterate routes atomic-set recovery detail through action_items" "$ITERATE" \
  '^#### `\{action_items\}` 追加項目（ステップ 6\.2 のみ）$' '^---$' \
  '発火時の cycle counter リセットと `stop_reason` の永続化に失敗しました'
assert_grep_in_section "iterate routes handoff recovery detail through action_items" "$ITERATE" \
  '^#### `\{action_items\}` 追加項目（ステップ 6\.2 のみ）$' '^---$' \
  '継続 handoff のクリアにも失敗しています'
assert_grep_in_section "iterate preserves the manual cycle-counter reset command" "$ITERATE" \
  '^#### `\{action_items\}` 追加項目（ステップ 6\.2 のみ）$' '^---$' \
  'flow-state\.sh set --session \{session_id\} --phase review --next "cycle counter 手動リセット" --cycle-count 0'
assert_grep_in_section "iterate preserves the reset-first restart replacement" "$ITERATE" \
  '^#### `\{action_items\}` 追加項目（ステップ 6\.2 のみ）$' '^---$' \
  'ループを再開する: 上記の手動リセットを実行してから /rite:iterate \{pr_number\} を再実行する'
assert_grep_in_section "iterate does not place action items beside the breaker reason" "$ITERATE" \
  '^#### `\{action_items\}` 追加項目（ステップ 6\.2 のみ）$' '^---$' \
  '「理由」行の直後には追加しない'
assert_grep_in_section "iterate replaces raw breaker warnings with detailed recovery items" "$ITERATE" \
  '^#### `\{action_items\}` 追加項目（ステップ 6\.2 のみ）$' '^---$' \
  '\(b\) / \(c\) は対応する raw WARNING の項目を詳細な復旧項目で置換し、raw 項目が無い場合だけ末尾へ追加する'
assert_grep_in_section "iterate forbids raw and detailed breaker items from coexisting" "$ITERATE" \
  '^#### `\{action_items\}` 追加項目（ステップ 6\.2 のみ）$' '^---$' \
  'raw WARNING と詳細な復旧項目を両方残してはならない'
assert_grep_in_section "iterate applies breaker items without reviving add-all semantics" "$ITERATE" \
  '^#### `\{action_items\}` 追加項目（ステップ 6\.2 のみ）$' '^---$' \
  '\(a\) は末尾へ追加し、\(b\) / \(c\) は上記の raw WARNING 置換規則に従う'
assert_not_grep "iterate removed the conflicting add-all action-items instruction" "$ITERATE" \
  '\(a\) / \(b\) / \(c\).*順に.*追加する'
assert_not_grep "iterate removed the conflicting b-addition wording" "$ITERATE" \
  '\(b\) は `\{action_items\}` への追加だけでは足りない'
assert_not_grep "iterate removed the duplicate reason-adjacent notice instruction" "$ITERATE" \
  '「理由」行の直後に注意行を追加する'

echo "=== common-error-handling: canonical jq contract remains without journal provenance ==="
assert_not_grep "canonical jq description has no review-cycle journal provenance" "$COMMON_ERR" \
  'verified-review cycle [0-9]+'
assert_grep "canonical jq description still names all 3 required fields" "$COMMON_ERR" \
  'schema_version 非空文字列 / pr_number 数値型 / findings\[\] 配列型'
assert_grep "canonical jq description still names all 4 consumers" "$COMMON_ERR" \
  'ステップ 6\.1\.a \(pr-review\.md\) と ステップ 1\.2\.0 Priority 0 / 2 / 3 \(fix\.md\) の 4 箇所から参照される'
assert_grep "canonical jq snippet still checks findings as an array" "$COMMON_ERR" \
  'and \(\.findings \| type == "array"\)'
# 転記主体の列挙を positive 側で pin する。負の節（欄を持たない ready / merge）だけを見ていると、
# 主体の列挙全体を「orchestrator」のような総称へ書き換える変異が素通りする。
assert_grep "rite-workflow names the section-carrying orchestrators as the transcription subjects" "$WORKFLOW" \
  '`要対応:` 欄を持つ `/rite:open` / `/rite:iterate` / `/rite:batch-run`\*\* がユーザーの操作が必要な行を完了報告へ転記する'
# 欄を持たない ready / merge の集約先は無条件ではない。batch-run 配下のみ集約され、standalone /
# recover 単体では stderr に留まる（既知の非カバー経路）ことまで書かせる。
# ready / merge 側に欄が無いことは契約ではなく既知の穴なので、ここでは pin しない。
assert_grep "rite-workflow keeps ready / merge as the skills without a section" "$WORKFLOW" \
  '欄を持たない `/rite:ready` / `/rite:merge` の WARNING は'
assert_grep "rite-workflow limits the collection claim to the batch-run report paths" "$WORKFLOW" \
  '`/rite:batch-run` の報告経路に載るときだけその欄に集約される'
assert_grep "rite-workflow names the uncovered standalone / non-batch recover path" "$WORKFLOW" \
  'batch を継続しない `/rite:recover`（`BATCH_CONTINUE=none`）から起動された経路では転記先が無く stderr に留まる'

if ! print_summary "$(basename "$0")" "cleanup/batch-run/wiki-ingest/recover の未完了事項集約 + 要対応 転記 contract (T-01/T-02/T-03)"; then
  exit 1
fi
