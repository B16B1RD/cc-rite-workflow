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
# T-01/T-02 感度強化: 8 個の check 名が enumeration 行に「この順序で」列挙されていることを
# line-anchored pattern で pin する (各 check 名は checklist 本体・判定 prose にも独立に出現するため、
# assert_grep_in_section によるセクションスコープは同一セクション内の別行にも同語が出現すると
# 判別できない — mutation テストで {local_branch_check} を enumeration から削除しても
# 別行の言及に一致し続けて green のままになることを確認済み。1 行内の順序付き列挙を
# 直接 anchor する本方式はこの穴を持たない)。
assert_grep "outstanding_items_block enumeration lists all 8 checks in order (T-01/T-02, AC-1/AC-2)" \
  "$CLEANUP" '\{base_update_check\}.*\{session_worktree_check\}.*\{local_branch_check\}.*\{projects_check\}.*\{wiki_ingest_check\}.*\{review_cleanup_check\}` / `\{wm_final_update_check\}` / `\{issue_close_check\}` のうち'
assert_grep "check count prose names 8 checks across steps 4/5/6/8/9/10/11" "$CLEANUP" '8 個の check が steps 4/5/6/8/9/10/11 の'
assert_not_grep "no stale 7-check count remains" "$CLEANUP" '7 個の check|7 check の判定ルール'

echo "=== cleanup.md ステップ 11/12: 作業メモリ最終更新の失敗を未完了事項に数える ==="
ARCHIVE="$SCRIPT_DIR/../../skills/cleanup/references/archive-procedures.md"
# チェックリストは作業メモリ更新を判定対象の行に分け、ローカル削除だけを無条件 x に残す
assert_grep "checklist carries the work-memory final update check" "$CLEANUP" \
  '^- \[\{wm_final_update_check\}\] 作業メモリ（Issue コメント）を最終更新$'
assert_grep "checklist keeps local work-memory deletion as its own line" "$CLEANUP" \
  '^- \[x\] ローカル作業メモリファイル削除$'
assert_not_grep "checklist no longer hard-codes the work-memory update as done" "$CLEANUP" \
  '^- \[x\] 作業メモリを最終更新 \+ ローカルファイル削除$'
# x にする値は許可リスト 3 値に限る (legitimate skip を含む)。失敗 status と marker 不在は未チェック
assert_grep "wm check allows exactly success / no_comment / section_absent as x (T-05/T-06)" "$CLEANUP" \
  '^  - `status=success` / `reason=no_comment` / `reason=section_absent` のいずれか: `x`（後 2 つは legitimate skip。x とする値はこの 3 つに限る）$'
assert_grep "wm check leaves any other status unchecked with an annotation (T-05)" "$CLEANUP" \
  '^  - 上記以外（`reason=invalid_args` / `reason=transform_failed` / `status=missing` 等）: ` ` \+ 「⚠️ 作業メモリの'
assert_grep "wm check leaves marker absence unchecked (T-07)" "$CLEANUP" \
  '^  - 該当行が無いとき: ` ` \+ 「⚠️ 作業メモリの\{対象\}の実行結果を確認できませんでした.*marker 不在を成功と読んではならない'
assert_grep "wm check scopes markers by issue and picks the last occurrence" "$CLEANUP" \
  '`issue=\{issue_number\}`（値の直後が `;` または行末）に該当する行を集め、\*\*その中の最後の出現 1 行だけを選ぶ\*\*'
assert_grep "wm check combines completion and progress like local_branch_check" "$CLEANUP" \
  '\*\*completion 側と progress 側を独立に評価し、両方が `x` 相当のときだけ `x`\*\*'
assert_grep "delegation mode still judges the wm and issue-close checks individually" "$CLEANUP" \
  '`\{wm_final_update_check\}` = ステップ 11 / `\{issue_close_check\}` = ステップ 10 / 冒頭の'
assert_grep "delegation mode counts 4 plus the individually unchecked items" "$CLEANUP" \
  '`\{n\}` は \*\*`4` \+ 個別判定で空欄になった check の件数\*\*'
# archive-procedures の §3.5.1 / §3.5.2 の bash がそれぞれ marker を 1 本だけ (実行行で) emit し、
# その payload が同じ節で helper の出力を受けた変数である。payload を定数や別節の変数に
# 差し替えると、helper の失敗がステップ 12 に届かず完了扱いに戻るため、行全体を固定する。
for part in "3.5.1:completion:wm_status" "3.5.2:progress:wm_progress_status"; do
  sec="${part%%:*}"; rest="${part#*:}"; side="${rest%%:*}"; var="${rest##*:}"
  section=$(awk -v start="^#### ${sec} " '$0 ~ start {f=1; next} f && /^#### /{exit} f' "$ARCHIVE")
  count=$(printf '%s\n' "$section" \
    | grep -cxF "echo \"[CONTEXT] WM_FINAL_UPDATE=${side}; issue={issue_number}; \${${var}:-status=missing}\"" || true)
  assert "archive-procedures §${sec} emits exactly one WM_FINAL_UPDATE=${side} marker carrying \$${var}" "1" "$count"
  count=$(printf '%s\n' "$section" \
    | grep -cF "${var}=\$(bash {plugin_root}/hooks/issue-comment-wm-sync.sh update" || true)
  assert "archive-procedures §${sec} marker status comes from the helper output in the same section" "1" "$count"
done

echo "=== cleanup.md ステップ 10/12: 関連 Issue のクローズを読み直しで確かめ、失敗を未完了事項に数える ==="
# base が default branch でない PR では Closes #N の自動クローズが働かず、クローズは cleanup だけが担う。
# チェックリストが無条件 x だと、クローズ失敗が完了報告にも outstanding 件数にも出ない。
assert_grep "checklist carries the issue-close check" "$CLEANUP" '^- \[\{issue_close_check\}\] 関連 Issue をクローズ$'
assert_not_grep "checklist no longer hard-codes the issue close as done" "$CLEANUP" '^- \[x\] 関連 Issue をクローズ$'
assert_grep "issue-close check allows exactly closed / already_closed / not_identified as x" "$CLEANUP" \
  '^  - `ISSUE_CLOSE=closed` / `ISSUE_CLOSE=already_closed` / `ISSUE_CLOSE=not_identified` のいずれか: `x`（x とする値はこの 3 つに限る）$'
assert_grep "issue-close check leaves failed values unchecked with an annotation" "$CLEANUP" \
  '^  - 上記以外（`ISSUE_CLOSE=failed` かつ `reason=` が `close_failed` / .*: ` ` \+ 「⚠️ Issue #\{issue_number\} のクローズを確認できませんでした'
assert_grep "issue-close check gives no_pr its own annotation without PR-number commands" "$CLEANUP" \
  '^  - `ISSUE_CLOSE=failed` かつ `reason=no_pr`: ` ` \+ 「⚠️ 関連 PR が無いため Issue #\{issue_number\} をクローズしていません。`gh issue view \{issue_number\}'
assert_grep "Error Handling points issue-close recovery to the step 12 annotation" "$CLEANUP" \
  '^\| Issue Close Failure \| .*回復はステップ 12 の `\{issue_close_check\}` の付記に従う \|$'
assert_grep "issue-close check leaves marker absence unchecked" "$CLEANUP" \
  '^  - 該当行が無いとき: ` ` \+ 「⚠️ Issue #\{issue_number\} のクローズの実行結果を確認できませんでした.*marker 不在を成功と読んではならない'
assert_grep "issue-close check scopes markers by issue and picks the last occurrence" "$CLEANUP" \
  '^- `\{issue_close_check\}`: .*`issue=\{issue_number\}`（値の直後が `;` または行末）に該当する行を集め、\*\*その中の最後の出現 1 行だけを選ぶ\*\*'

# §3.6 の bash が marker を実行行で 1 本だけ出し、その値が close より後の読み直しで決まることを固定する。
# 読み直しを close より前に置く・payload を close の終了コードだけで決める変更は、閉じていない Issue を
# closed と報告する経路に戻る。
issue_close_section=$(awk '/^### 3\.6 /{f=1; next} f && /^### 3\.6\.4 /{exit} f' "$ARCHIVE")
[ -n "$issue_close_section" ] || fail "archive-procedures §3.6 section could not be extracted"
count=$(printf '%s\n' "$issue_close_section" \
  | grep -cxF 'echo "[CONTEXT] ISSUE_CLOSE=$result; issue=$issue${reason:+; reason=$reason}"' || true)
assert "archive-procedures §3.6 emits exactly one ISSUE_CLOSE marker" "1" "$count"
close_line=$(printf '%s\n' "$issue_close_section" | grep -n 'gh issue close "\$issue"' | head -1 | cut -d: -f1)
reread_line=$(printf '%s\n' "$issue_close_section" | grep -n '^  after=\$(gh issue view "\$issue" -R {owner_repo} --json state' | head -1 | cut -d: -f1)
if [ -n "$close_line" ] && [ -n "$reread_line" ] && [ "$close_line" -lt "$reread_line" ]; then
  pass "archive-procedures §3.6 re-reads the state after gh issue close"
else
  fail "archive-procedures §3.6 re-reads the state after gh issue close (close=${close_line:-none} reread=${reread_line:-none})"
fi

# §3.6 の bash を抽出し、PATH 先頭の gh stub で実行して marker の値を観測する。
IC_TMP=$(mktemp -d "${TMPDIR:-/tmp}/rite-issue-close-test-XXXXXX")
trap 'rm -rf "$IC_TMP"' EXIT
awk '/^```bash$/ {inside=1; block=""; next}
     /^```$/ {if (inside && index(block, "# cleanup-issue-close")) {printf "%s", block; exit}; inside=0}
     inside {block=block $0 "\n"}' "$ARCHIVE" > "$IC_TMP/block.sh"
if [ ! -s "$IC_TMP/block.sh" ]; then
  fail "archive-procedures §3.6 bash block (# cleanup-issue-close) could not be extracted"
else
  mkdir -p "$IC_TMP/bin"
  # 1 回目の issue view は close 前、2 回目以降は close 後の読み直し。GH_AFTER=ERR は読み直しの失敗、
  # GH_PR_REFS=ERR は PR 本文・ブランチ名の取得失敗。呼び出しはすべて calls に記録する
  cat > "$IC_TMP/bin/gh" <<'STUB'
#!/bin/bash
echo "$1 $2" >> "$GH_STUB_DIR/calls"
case "$1 $2" in
  "pr view")
    [ "$GH_PR_REFS" = ERR ] && exit 1
    printf '%s\n' "$GH_PR_REFS" ;;
  "issue view")
    n=$(( $(cat "$GH_STUB_DIR/views" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$GH_STUB_DIR/views"
    if [ "$n" -eq 1 ]; then echo "$GH_BEFORE"; else [ "$GH_AFTER" = ERR ] && exit 1; echo "$GH_AFTER"; fi ;;
  "issue close") echo close >> "$GH_STUB_DIR/closes"; exit "${GH_CLOSE_RC:-0}" ;;
  *) exit 99 ;;
esac
STUB
  chmod +x "$IC_TMP/bin/gh"
  # $1=issue $2=before $3=close rc $4=after $5=PR 本文とブランチ名（省略時は Issue 41 を閉じる PR）
  # $6=PR 番号（省略時は 900。空文字は PR 無しで続行した cleanup）
  # → ISSUE_CLOSE marker 行と、gh issue close / gh 全体の呼び出し回数
  run_issue_close() {
    local d; d=$(mktemp -d "$IC_TMP/case-XXXXXX")
    sed -e "s|{issue_number}|$1|g" -e 's|{owner_repo}|owner/repo|g' -e "s|{pr_number}|${6-900}|g" "$IC_TMP/block.sh" > "$d/run.sh"
    GH_STUB_DIR="$d" GH_BEFORE="$2" GH_CLOSE_RC="$3" GH_AFTER="$4" GH_PR_REFS="${5-Closes #41${nl}fix/issue-41-x}" \
      PATH="$IC_TMP/bin:$PATH" bash "$d/run.sh" 2>/dev/null | grep '^\[CONTEXT\] ISSUE_CLOSE=' | tail -1
    printf 'closes=%s calls=%s\n' "$(cat "$d/closes" 2>/dev/null | wc -l | tr -d ' ')" "$(cat "$d/calls" 2>/dev/null | wc -l | tr -d ' ')"
  }
  nl=$'\n'
  assert "OPEN → close → re-read CLOSED is closed" "[CONTEXT] ISSUE_CLOSE=closed; issue=41${nl}closes=1 calls=4" "$(run_issue_close 41 OPEN 0 CLOSED)"
  assert "close command failure is failed/close_failed" "[CONTEXT] ISSUE_CLOSE=failed; issue=41; reason=close_failed${nl}closes=1 calls=3" "$(run_issue_close 41 OPEN 1 CLOSED)"
  assert "close succeeds but re-read stays OPEN is failed" "[CONTEXT] ISSUE_CLOSE=failed; issue=41; reason=state_OPEN${nl}closes=1 calls=4" "$(run_issue_close 41 OPEN 0 OPEN)"
  assert "re-read failure after close is failed/verify_failed, not closed" "[CONTEXT] ISSUE_CLOSE=failed; issue=41; reason=verify_failed${nl}closes=1 calls=4" "$(run_issue_close 41 OPEN 0 ERR)"
  assert "already CLOSED is already_closed without running gh issue close" "[CONTEXT] ISSUE_CLOSE=already_closed; issue=41${nl}closes=0 calls=2" "$(run_issue_close 41 CLOSED 0 CLOSED)"
  assert "unidentified issue is not_identified without calling gh" "[CONTEXT] ISSUE_CLOSE=not_identified; issue=${nl}closes=0 calls=0" "$(run_issue_close '' OPEN 0 CLOSED)"
  # 取り違え: PR が参照しない Issue は、OPEN でも既に CLOSED でも閉じずに failed にする
  assert "issue the PR does not reference is target_mismatch without closing" "[CONTEXT] ISSUE_CLOSE=failed; issue=41; reason=target_mismatch${nl}closes=0 calls=1" "$(run_issue_close 41 OPEN 0 CLOSED "Closes #57${nl}fix/issue-57-x")"
  assert "already CLOSED issue the PR does not reference is target_mismatch, not already_closed" "[CONTEXT] ISSUE_CLOSE=failed; issue=41; reason=target_mismatch${nl}closes=0 calls=1" "$(run_issue_close 41 CLOSED 0 CLOSED "Closes #57${nl}fix/issue-57-x")"
  assert "a longer number sharing the prefix is not a reference" "[CONTEXT] ISSUE_CLOSE=failed; issue=4; reason=target_mismatch${nl}closes=0 calls=1" "$(run_issue_close 4 OPEN 0 CLOSED)"
  assert "branch name issue-N alone is a reference" "[CONTEXT] ISSUE_CLOSE=closed; issue=41${nl}closes=1 calls=4" "$(run_issue_close 41 OPEN 0 CLOSED "body without keyword${nl}fix/issue-41-x")"
  assert "cleanup without a PR is no_pr without calling gh" "[CONTEXT] ISSUE_CLOSE=failed; issue=41; reason=no_pr${nl}closes=0 calls=0" "$(run_issue_close 41 OPEN 0 CLOSED "Closes #41" "")"
  assert "PR read failure is pr_view_failed without closing" "[CONTEXT] ISSUE_CLOSE=failed; issue=41; reason=pr_view_failed${nl}closes=0 calls=1" "$(run_issue_close 41 OPEN 0 CLOSED ERR)"
fi
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
assert_grep "ingest_outstanding_line has a lock row for the lost-lock WARNING" "$WIKI_INGEST" '^\| ロック \| .*ロックを失っていました'
assert_grep "ingest_outstanding_line has a lock row for the unconfirmed-state WARNING" "$WIKI_INGEST" '^\| ロック \| .*ロックの状態を確認できませんでした'
assert_grep "ingest_outstanding_line has a lock row for the release-failure WARNING" "$WIKI_INGEST" '^\| ロック \| .*ロックを解放できませんでした'
assert_grep "ingest_outstanding_line none row also requires no lock WARNING" "$WIKI_INGEST" '^\| （全系統） \| .*ロックの WARNING を出していない'

echo "=== cleanup.md ステップ 9/12: wiki-ingest がロックを失ったら最終報告の未完了事項に載せる ==="
# wiki-ingest 9.0 は own 以外のとき stdout に marker を出し、cleanup ステップ 9 がそれを pr= 付きで発火し、
# ステップ 12 の {wiki_ingest_check} が表とは独立に評価して空欄 + 付記にする。marker の実出力は
# wiki-ingest-lock.test.sh TC-13 が実物のロックで固定する。ここでは手順書間の配線を固定する。
assert_grep "wiki-ingest step 9.0 emits the lock-lost marker for a non-own lock" "$WIKI_INGEST" \
  '^  echo "\[CONTEXT\] WIKI_INGEST_LOCK_LOST=1; check=\$\{lock_state:-unknown\}"$'
step9_sentinels=$(awk '/^skill return 後、出力から以下のいずれかの sentinel を発火させる/{f=1} f{print} /^ingest の成否（skip 含む）に関わらずステップ 10 へ進む/{exit}' "$CLEANUP")
[ -n "$step9_sentinels" ] || fail "cleanup step 9 sentinel section could not be extracted"
count=$(printf '%s\n' "$step9_sentinels" | grep -cxF -- '- ロック喪失 (ingest 出力に `WIKI_INGEST_LOCK_LOST=1`): 上記のいずれとも併存しうる形で `[CONTEXT] WIKI_INGEST_LOCK_LOST=1; source=cleanup_step9; pr={pr_number}` を追加で発火する（取り込みの成否は変えない）' || true)
assert "cleanup step 9 fires the lock-lost sentinel with pr= inside its sentinel list" "1" "$count"
wiki_check_item=$(awk '/^- `\{wiki_ingest_check\}`:/{f=1} f && /^- `\{wm_final_update_check\}`:/{exit} f{print}' "$CLEANUP")
[ -n "$wiki_check_item" ] || fail "cleanup step 12 wiki_ingest_check item could not be extracted"
assert "wiki_ingest_check keeps WIKI_INGEST_DONE alone as x" "1" \
  "$(printf '%s\n' "$wiki_check_item" | grep -cxF -- '  | `WIKI_INGEST_DONE=1` 単独 | `x` | — |' || true)"
assert "wiki_ingest_check evaluates the lock loss independently of the table, scoped by pr=" "1" \
  "$(printf '%s\n' "$wiki_check_item" | grep -c 'ロック喪失は上の表と独立に評価する.*表の一致判定にも最終行（marker 不在）の判定にも数えない.*`source=cleanup_step9; pr={pr_number}`.*check を ` ` にし、表の付記の\*\*後ろに\*\*ロック喪失の付記を続ける' || true)"
lost_note='⚠️ ingest 中に wiki ingest のロックを失っていました。直近の wiki の commit に重複や上書きが無いか確認してください'
assert "wiki_ingest_check carries the lock-lost note" "1" \
  "$(printf '%s\n' "$wiki_check_item" | grep -cxF -- "  ${lost_note}" || true)"
# 付記の文面は wiki-ingest 自身のロック行の展開文と同じ語句を使う
assert "the lock-lost note shares its wording with the wiki-ingest lock row" "1" \
  "$(grep -c '^| ロック | .*ingest 中に wiki ingest のロックを失っていました.*直近の wiki の commit に重複や上書きが無いか確認してください' "$WIKI_INGEST" || true)"
push_note_line=$(printf '%s\n' "$wiki_check_item" | grep -n 'ℹ️\|⚠️ Wiki ingest: commit は local wiki branch に landed' | head -1 | cut -d: -f1)
lost_note_line=$(printf '%s\n' "$wiki_check_item" | grep -nF -- "  ${lost_note}" | head -1 | cut -d: -f1)
if [ -n "$push_note_line" ] && [ -n "$lost_note_line" ] && [ "$push_note_line" -lt "$lost_note_line" ]; then
  pass "wiki_ingest_check lists the push-failure note before the lock-lost note"
else
  fail "wiki_ingest_check lists the push-failure note before the lock-lost note (push=${push_note_line:-none} lost=${lost_note_line:-none})"
fi
assert "the marker-absence row does not count the lock-lost marker" "1" \
  "$(printf '%s\n' "$wiki_check_item" | grep -c 'LOCK_LOST しか無いとき（DONE 等の発火漏れ）は最終行を適用したうえでロック喪失の付記を続ける' || true)"
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
  'flow-state\.sh set --session \{session_id\} --phase "\$reset_phase" --next "cycle counter 手動リセット" --cycle-count 0'
assert_grep_in_section "iterate resolves the same session phase before manual reset" "$ITERATE" \
  '^#### `\{action_items\}` 追加項目（ステップ 6\.2 のみ）$' '^---$' \
  'reset_phase=\$\(RITE_STATE_ROOT="\{state_root\}" bash "\{plugin_root\}"/hooks/flow-state\.sh get --session \{session_id\} --field phase --default pr\) && RITE_STATE_ROOT="\{state_root\}"'
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
