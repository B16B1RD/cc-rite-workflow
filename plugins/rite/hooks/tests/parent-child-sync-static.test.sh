#!/bin/bash
# parent-child-sync-static.test.sh
#
# Parent/child Issue closure relies on detecting the relationship via three
# methods (body meta, GraphQL trackedIssues, tasklist). A past inline
# simplification that kept only trackedIssues silently broke parent-close
# when child Issues used the other two methods. Pin the static invariants:
#
#   - close.md Phase 4.5.1 keeps all three Method 1/2/3 blocks
#   - close.md Phase 4.6 keeps the auto-close skeleton (P460_DECISION)
#   - pr/open.md ステップ 1.2 uses the trackedIssues query (was start.md ステップ 8.4)
#   - projects-integration.md §2.4.7 documents all three methods

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"

CLOSE_MD="$PLUGIN_ROOT/skills/issue-close/SKILL.md"
PR_OPEN_MD="$PLUGIN_ROOT/skills/open/SKILL.md"
PROJECTS_REF="$PLUGIN_ROOT/references/projects-integration.md"
ARCHIVE_MD="$PLUGIN_ROOT/skills/cleanup/references/archive-procedures.md"
CLEANUP_MD="$PLUGIN_ROOT/skills/cleanup/SKILL.md"

for f in "$CLOSE_MD" "$PR_OPEN_MD" "$PROJECTS_REF" "$ARCHIVE_MD" "$CLEANUP_MD"; do
  [ -f "$f" ] || { echo "ERROR: required file not found: $f" >&2; exit 1; }
done

echo "=== Phase 1: close.md retains 3 detection methods (regression guard) ==="
assert_grep "close.md retains Method 1 (## 親 Issue body meta)" "$CLOSE_MD" "## 親 Issue"
assert_grep "close.md retains trackedIssues field usage" "$CLOSE_MD" "trackedIssues"
assert_grep "close.md retains tasklist search method" "$CLOSE_MD" "in:body|tasklist"

echo "=== Phase 2: close.md Phase 4.6 auto-close decision skeleton ==="
assert_grep "close.md retains P460_DECISION skip_already_closed branch" "$CLOSE_MD" "P460_DECISION|skip_already_closed|Phase 4\.6"

echo "=== Phase 2b: close.md 4.6.3 skipped_terminal_conflict is a legitimate skip ==="
SHARED_START='^## Shared: Projects Status'
SHARED_END='^## Phase 1:'
S463_START='^### 4\.6\.3'
S463_END='^## Phase 5:'
S3721_START='^##### 3\.7\.2\.1'
S3721_END='^##### 3\.7\.2\.2'
assert_grep_in_section "close.md Shared table dispatches skipped_terminal_conflict" "$CLOSE_MD" \
  "$SHARED_START" "$SHARED_END" \
  '"skipped_terminal_conflict"'
assert_grep_in_section "close.md 4.6.3 case arm sets skipped_terminal" "$CLOSE_MD" \
  "$S463_START" "$S463_END" \
  'status_update_result="skipped_terminal"'
assert_grep_in_section "close.md 4.6.3 Step 3 treats skipped_terminal as 整合性 OK" "$CLOSE_MD" \
  "$S463_START" "$S463_END" \
  'success:skipped_terminal'
assert_grep_in_section "archive 3.7.2.1 table has skipped_terminal_conflict" "$ARCHIVE_MD" \
  "$S3721_START" "$S3721_END" \
  '"skipped_terminal_conflict"'
assert_grep_in_section "archive 3.7.2.1 case arm skipped_terminal_conflict" "$ARCHIVE_MD" \
  "$S3721_START" "$S3721_END" \
  'skipped_terminal_conflict\)'

echo "=== Phase 3: pr/open.md ステップ 1.2 trackedIssues query (no inline simplification) ==="
assert_grep "pr/open.md ステップ 1.2 uses trackedIssues GraphQL (not bare trackedInIssues)" "$PR_OPEN_MD" "trackedIssues"
# Negative: regression guard. Old simplification used `trackedInIssues` which is not the canonical name.
# トラッキング trackedInIssues (Inヌキ) は GitHub API 名で本来正しいが、過去に誤った
# 簡略化が起きたため defensive assertion として `trackedIssues` 名の存在を必須にする。
assert_grep "pr/open.md retains Method 1 (親 Issue body meta) reference" "$PR_OPEN_MD" "親 Issue"

echo "=== Phase 4: projects-integration.md retains 3-method documentation ==="
# The root cause was silent collapse of the 3-method OR documentation to a
# single method. Each method is asserted independently so partial removal (e.g.
# dropping `## 親 Issue` while keeping the GraphQL block) cannot slide through.
# Method 2 here uses the child-to-parent GraphQL query `parent { number }` via
# the `sub_issues` feature flag — different from close.md / pr/open.md which use
# the parent-to-children `trackedIssues` field.
assert_grep "projects-integration.md §2.4.7 retains Method 1 (## 親 Issue body meta)" "$PROJECTS_REF" "## 親 Issue"
assert_grep "projects-integration.md §2.4.7 retains Method 2 (sub_issues GraphQL feature)" "$PROJECTS_REF" "sub_issues"
assert_grep "projects-integration.md §2.4.7 retains Method 3 (tasklist / in:body search)" "$PROJECTS_REF" "in:body|tasklist"

echo "=== Phase 5: already-closed parent still syncs Status → Done ==="
# close 冪等 skip と board 同期が同一 skip に畳まれると AC-1 が壊れる。
assert_grep "close.md skip_already_closed continues for Status → Done" "$CLOSE_MD" "continue for Status"
assert_grep "close.md skip_already_closed + all-closed runs Shared Status on parent" "$CLOSE_MD" "skip_already_closed.*Shared: Status|Shared: Status → Done（\\{issue\\} = \\{parent_number\\}）"
assert_not_grep "close.md skip_already_closed no longer exits Phase 4.6 before enumeration" "$CLOSE_MD" "skipping Phase 4.6 \\(close-side idempotency\\)"
assert_grep "archive-procedures already-CLOSED parent runs 3.7.2.1 only" "$ARCHIVE_MD" "parent is already CLOSED.*3\\.7\\.2\\.1"
assert_grep "archive-procedures 3.7.2.2 skipped when parent already CLOSED" "$ARCHIVE_MD" "Skip this substep if the parent Issue is already CLOSED"

echo "=== Phase 6: open.md が検出した親番号を flow-state へ書く ==="
# 検出だけして flow-state へ書かないと issue-implement 5.1.2 が常に PARENT_ISSUE=none で skip する。
# open.md には `flow-state.sh set` が複数箇所あるため、ファイル全体の grep では「どの set に
# 付いたか」を pin できない。2.6 節に限定して assert する。
S26_START='^### 2.6 flow-state 更新'
S26_END='^## ステップ 3'
S24_START='^### 2.4 GitHub Projects Status 更新'
S24_END='^### 2.5 Work Memory 初期化'
assert_grep_in_section "open.md 2.4(B) が親番号を {parent_issue_number} として retain する" "$PR_OPEN_MD" \
  "$S24_START" "$S24_END" \
  '\{parent_issue_number\}`? として retain'
assert_grep_in_section "open.md 2.6 の flow-state set が --parent-issue を渡す" "$PR_OPEN_MD" \
  "$S26_START" "$S26_END" \
  '\-\-parent-issue \{parent_issue_number\}'
# standalone AC: 未検出時に 0 を明示せずフラグ自体を省く (flow-state 側の merge-preserve に載せる)
assert_grep_in_section "open.md 2.6 が未検出時はフラグを付けないと明記する" "$PR_OPEN_MD" \
  "$S26_START" "$S26_END" \
  '未検出時.*フラグ自体を付けない'
# substitution 契約: 2.6 が {parent_issue_number} を渡せるのは、Legend と Note が本コマンド body での
# substitute を許しているからである。この 1 箇所だけが base 版へ戻ると 2.4(B)/2.6 の追記は残るのに
# 執行者は placeholder を解決できず、上の 3 assert は green のまま AC が壊れる。
SLEG_START='^## Placeholder Legend'
SLEG_END='^---$'
assert_grep_in_section "open.md Legend に {parent_issue_number} 行がある" "$PR_OPEN_MD" \
  "$SLEG_START" "$SLEG_END" \
  '^\| `\{parent_issue_number\}` \|'
assert_grep_in_section "open.md Note が {parent_issue_number} の substitute 例外を明記する" "$PR_OPEN_MD" \
  "$SLEG_START" "$SLEG_END" \
  '\{parent_issue_number\}`? は例外'
# 禁止リストへの再混入を防ぐ (base 版 Note の 4 placeholder 列挙は本ファイル内で一意)
assert_not_grep "open.md Note の禁止リストに {parent_issue_number} が戻っていない" "$PR_OPEN_MD" \
  '\{project_number\}` / `\{parent_issue_number\}` は本コマンド body で substitute しない'

echo "=== Phase 7: parent auto-close uses stateReason (NOT_PLANNED 子は Done にしない) ==="
S371_START='^#### 3\.7\.1'
S371_END='^#### 3\.7\.2'
S373_START='^#### 3\.7\.3'
S373_END='^#### 3\.7\.4'
S461_START='^### 4\.6\.0'
S461_END='^### 4\.6\.2'
S10_START='^## ステップ 10:'
S10_END='^## ステップ 11:'
S12_START='^## ステップ 12:'
S12_END='^## Error Handling'

# T-01: 両クエリが stateReason を取得する（形: GraphQL nodes / --jq 投影 / Method B --json）
assert_grep_in_section "archive 3.7.1 query nodes include stateReason" "$ARCHIVE_MD" \
  "$S371_START" "$S371_END" \
  'stateReason'
assert_grep_in_section "close.md 4.6.1 GraphQL nodes include stateReason" "$CLOSE_MD" \
  "$S461_START" "$S461_END" \
  'nodes \{ number state stateReason \}'
assert_grep_in_section "close.md 4.6.1 jq projection includes stateReason" "$CLOSE_MD" \
  "$S461_START" "$S461_END" \
  '\{number, state, stateReason\}'
assert_grep_in_section "close.md Method B gh issue view fetches state,stateReason" "$CLOSE_MD" \
  "$S461_START" "$S461_END" \
  'json state,stateReason'
assert_not_grep "close.md Method B no longer fetches --json state alone for children" "$CLOSE_MD" \
  'issue view "\$n".*--json state --jq'
assert_not_grep "close.md jq projection is not state-only" "$CLOSE_MD" \
  '\{number, state\}\]'

# T-02: NOT_PLANNED / skip_cancelled_children は Done / proceed_to_confirmation へ進まない
assert_grep_in_section "archive Assessment has NOT_PLANNED row that skips Done" "$ARCHIVE_MD" \
  "$S371_START" "$S371_END" \
  'stateReason == NOT_PLANNED'
assert_grep_in_section "archive NOT_PLANNED row does not update parent Status to Done" "$ARCHIVE_MD" \
  "$S371_START" "$S371_END" \
  'NOT_PLANNED.*Do not update parent Status to Done|Do not update parent Status to Done.*NOT_PLANNED'
assert_not_grep "archive NOT_PLANNED row does not proceed to 3.7.2" "$ARCHIVE_MD" \
  'NOT_PLANNED` \| Proceed to Phase 3\.7\.2'
assert_grep_in_section "close.md P461 skip_cancelled_children exists" "$CLOSE_MD" \
  "$S461_START" "$S461_END" \
  'P461_DECISION=skip_cancelled_children'
assert_not_grep "skip_cancelled_children is not the same routing cell as proceed_to_confirmation" "$CLOSE_MD" \
  'skip_cancelled_children.*proceed_to_confirmation'
assert_not_grep "skip_cancelled_children is not the same routing cell as Shared Status→Done" "$CLOSE_MD" \
  'skip_cancelled_children.*Shared: Status'

# T-02b: skip_reason_unavailable fail-loud は proceed / Done と同一セルに無い
assert_grep_in_section "close.md P461 skip_reason_unavailable exists" "$CLOSE_MD" \
  "$S461_START" "$S461_END" \
  'P461_DECISION=skip_reason_unavailable'
assert_not_grep "skip_reason_unavailable is not the same routing cell as proceed_to_confirmation" "$CLOSE_MD" \
  'skip_reason_unavailable.*proceed_to_confirmation'
assert_not_grep "skip_reason_unavailable is not the same routing cell as Shared Status→Done" "$CLOSE_MD" \
  'skip_reason_unavailable.*Shared: Status'
assert_grep_in_section "cleanup ステップ 12 値域 has stateReason 判定不能行" "$CLEANUP_MD" \
  "$S12_START" "$S12_END" \
  'stateReason 判定不能'

# T-03: 全 COMPLETED（NOT_PLANNED なし）の既存行が残る。generic 行は skip 行と互いに素
assert_grep_in_section "archive all-CLOSED parent OPEN still goes to 3.7.2" "$ARCHIVE_MD" \
  "$S371_START" "$S371_END" \
  'none `NOT_PLANNED`'
assert_grep_in_section "archive generic CLOSED+OPEN row excludes unavailable stateReason" "$ARCHIVE_MD" \
  "$S371_START" "$S371_END" \
  'no unavailable `stateReason`, and parent is OPEN'
assert_grep_in_section "close.md P461 proceed_to_confirmation remains" "$CLOSE_MD" \
  "$S461_START" "$S461_END" \
  'P461_DECISION=proceed_to_confirmation'
# T-02 pin の実体: bash elif cancelled が proceed else より前（routing 表の文字列存在だけでは不足）
assert_grep_in_section "close.md cancelled elif precedes proceed else" "$CLOSE_MD" \
  "$S461_START" "$S461_END" \
  'elif \[ "\$cancelled_count" -gt 0'
assert_grep_in_section "close.md cancelled elif emit includes numbers=" "$CLOSE_MD" \
  "$S461_START" "$S461_END" \
  'P461_DECISION=skip_cancelled_children; numbers='

# T-01/AC-1 報告: Cancelled 子番号明示
assert_grep_in_section "archive 3.7.3 Cancelled 通知 names Cancelled children" "$ARCHIVE_MD" \
  "$S373_START" "$S373_END" \
  'Cancelled の子'
assert_grep_in_section "archive 3.7.3 Cancelled 通知 includes NOT_PLANNED" "$ARCHIVE_MD" \
  "$S373_START" "$S373_END" \
  'Cancelled \(NOT_PLANNED\)'
assert_grep "close.md user-facing report names Cancelled children and unfinished parent" "$CLOSE_MD" \
  'Cancelled の子 .*親 .*は未完了扱い'
assert_grep_in_section "cleanup ステップ 12 値域 has Cancelled 未完了扱い" "$CLEANUP_MD" \
  "$S12_START" "$S12_END" \
  'Cancelled の子を含むため親は未完了扱い'
assert_grep_in_section "cleanup ステップ 12 値域 has Cancelled のため Done 上書きをスキップ" "$CLEANUP_MD" \
  "$S12_START" "$S12_END" \
  '^- `⚠️ Cancelled のため Done 上書きをスキップ`'
# 件数は値域ブロック内の行頭 `- `` 行だけを数える（任意の `- ` ではない）。
# 終端空行が無いときは NOEND で fail し、0 件を pass と読まない。
_value_domain_count() {
  local file="$1"
  start_re='`{parent_close_result}` の値域' awk '
    $0 ~ ENVIRON["start_re"] { inblk=1; next }
    inblk && /^$/ { ended=1; exit }
    inblk && index($0, "- `") == 1 { n++ }
    END {
      if (!ended) { print "NOEND"; exit 1 }
      print n+0
    }
  ' "$file"
}
_value_domain_heading_n() {
  local file="$1"
  start_re='`{parent_close_result}` の値域' awk '
    $0 ~ ENVIRON["start_re"] {
      if (match($0, /[0-9]+ 種類/)) {
        s = substr($0, RSTART, RLENGTH)
        sub(/ 種類/, "", s)
        print s
      }
      exit
    }
  ' "$file"
}
_vd_count=$(_value_domain_count "$CLEANUP_MD") || true
if [ "$_vd_count" = "NOEND" ] || [ -z "$_vd_count" ]; then
  fail "cleanup ステップ 12 値域ブロック終端（空行）が見つからない（0 件を pass と読まない）"
elif [ "$_vd_count" = "7" ]; then
  pass "cleanup ステップ 12 値域 - \` 行数が 7"
else
  fail "cleanup ステップ 12 値域 - \` 行数が ${_vd_count}（expected 7）"
fi
_vd_heading=$(_value_domain_heading_n "$CLEANUP_MD")
if [ -n "$_vd_heading" ] && [ "$_vd_heading" = "$_vd_count" ]; then
  pass "cleanup ステップ 12 値域見出し数詞と - \` 件数が一致 ($_vd_heading)"
else
  fail "cleanup ステップ 12 値域見出し数詞 (${_vd_heading:-empty}) と件数 (${_vd_count:-empty}) が不一致"
fi
assert_not_grep "cleanup ステップ 12 値域 no longer says 6 種類" "$CLEANUP_MD" \
  '6 種類'

# 文書同期: ステップ 10 の「全子完了→auto-close」旧要約が残っていない
assert_grep_in_section "cleanup ステップ 10 auto-close requires stateReason != NOT_PLANNED" "$CLEANUP_MD" \
  "$S10_START" "$S10_END" \
  'stateReason != NOT_PLANNED'
assert_not_grep "cleanup ステップ 10 no longer says 全子 Issue が完了していれば parent も auto-close" "$CLEANUP_MD" \
  '全子 Issue が完了していれば parent も auto-close'
assert_grep_in_section "cleanup ステップ 10 maps skipped_terminal_conflict to parent_close_result" "$CLEANUP_MD" \
  "$S10_START" "$S10_END" \
  'skipped_terminal_conflict'
assert_grep_in_section "cleanup ステップ 10 skipped_terminal_conflict sets parent_close_result" "$CLEANUP_MD" \
  "$S10_START" "$S10_END" \
  'parent_close_result'

# regression: Method B state 失敗→OPEN 保全 / OPEN+null は欠落にしない
assert_grep_in_section "Method B state fetch failure still fail-closed as OPEN" "$CLOSE_MD" \
  "$S461_START" "$S461_END" \
  'state 取得失敗は fail-closed \(OPEN 扱い\)'
assert_grep_in_section "OPEN child null stateReason is not treated as unavailable" "$CLOSE_MD" \
  "$S461_START" "$S461_END" \
  'OPEN 子の stateReason null は正常'
assert_not_grep "OPEN fail-closed is not folded into skip_reason_unavailable" "$CLOSE_MD" \
  'state 取得失敗は fail-closed.*skip_reason_unavailable'

echo "=== Phase 2c: 4.4 / 3.7.2.3 completion reports branch on .result (no hardcoded Done after skip) ==="
S44_START='^### 4\.4 Completion Report'
S44_END='^### 4\.4\.W'
S3723_START='^##### 3\.7\.2\.3'
S3723_END='^#### 3\.7\.3'

# 同一枝の合成: `.result=<name>` から次の別 `.result=` までを 1 枝として観測する。
# 同名が 2 回（既 CLOSED / close）続く場合は両方を同一枝に含める。
_result_block() {
  local file="$1" start="$2" end="$3" result="$4"
  # start/end は ERE。awk -v は代入時に \. を解釈して警告を出すため ENVIRON 経由。
  # r は .result= 名の文字列照合であり正規表現ではないので -v のまま。
  start_re="$start" end_re="$end" awk -v r="$result" '
    $0 ~ ENVIRON["start_re"] {insec=1}
    insec && $0 ~ ENVIRON["end_re"] && $0 !~ ENVIRON["start_re"] {insec=0}
    insec {
      if (index($0, ".result=" r) > 0) p=1
      else if (p && index($0, ".result=") > 0 && index($0, ".result=" r) == 0) p=0
      else if (p && index($0, "3.7.2.1 skip") > 0) p=0
      if (p) print
    }
  ' "$file"
}
_heading_block() {
  local file="$1"
  start_re="$2" end_re="$3" awk '
    $0 ~ ENVIRON["start_re"] { p=1 }
    p && $0 ~ ENVIRON["end_re"] && $0 !~ ENVIRON["start_re"] { ended=1; exit }
    p { buf = buf $0 ORS; n++ }
    END {
      if (!ended) { print "NOEND"; exit 1 }
      printf "%s", buf
    }
  ' "$file"
}
_assert_block_grep() {
  local label="$1" block="$2" pattern="$3"
  if printf '%s\n' "$block" | grep -qE "$pattern"; then
    pass "$label"
  else
    fail "$label (pattern not in extracted block: $pattern)"
  fi
}
_assert_block_not_grep() {
  local label="$1" block="$2" pattern="$3"
  if printf '%s\n' "$block" | grep -qE "$pattern"; then
    fail "$label (forbidden pattern in extracted block: $pattern)"
  else
    pass "$label"
  fi
}

# 4.4: Shared 4 値で分岐し、未分岐テンプレの単独 Status: Done に戻っていない
assert_grep_in_section "close.md 4.4 table updated → Status: Done" "$CLOSE_MD" \
  "$S44_START" "$S44_END" \
  '`updated`[[:space:]]*\|[[:space:]]*`Status: Done`'
assert_grep_in_section "close.md 4.4 table skipped_terminal_conflict → Status: Cancelled" "$CLOSE_MD" \
  "$S44_START" "$S44_END" \
  '`skipped_terminal_conflict`[[:space:]]*\|[[:space:]]*`Status: Cancelled`'
assert_grep_in_section "close.md 4.4 table failed → 更新失敗" "$CLOSE_MD" \
  "$S44_START" "$S44_END" \
  '`failed`[[:space:]]*\|[[:space:]]*`Status: 更新失敗`'
assert_grep_in_section "close.md 4.4 table skipped_not_in_project omits Status" "$CLOSE_MD" \
  "$S44_START" "$S44_END" \
  '`skipped_not_in_project`[[:space:]]*\|[[:space:]]*Status 行なし'

_close_updated=$(_result_block "$CLOSE_MD" "$S44_START" "$S44_END" "updated")
_close_skip=$(_result_block "$CLOSE_MD" "$S44_START" "$S44_END" "skipped_terminal_conflict")
_close_failed=$(_result_block "$CLOSE_MD" "$S44_START" "$S44_END" "failed")
_close_nip=$(_result_block "$CLOSE_MD" "$S44_START" "$S44_END" "skipped_not_in_project")
_assert_block_grep "close.md 4.4 updated branch has Status: Done" "$_close_updated" 'Status: Done'
_assert_block_grep "close.md 4.4 skipped_terminal_conflict branch has Status: Cancelled" "$_close_skip" 'Status: Cancelled'
_assert_block_not_grep "close.md 4.4 skipped_terminal_conflict branch has no Status: Done" "$_close_skip" 'Status: Done'
_assert_block_grep "close.md 4.4 failed branch has 更新失敗" "$_close_failed" 'Status: 更新失敗'
_assert_block_not_grep "close.md 4.4 failed branch has no Status: Done" "$_close_failed" 'Status: Done'
_assert_block_not_grep "close.md 4.4 skipped_not_in_project branch has no Status: Done" "$_close_nip" 'Status: Done'

# 4.4.W / 4.4.W.2 見出しは wiki-push-sandbox-retry-contract の抽出起点。改稿で落とさない
assert_grep "close.md retains ### 4.4.W heading" "$CLOSE_MD" '^### 4\.4\.W Wiki Ingest'
assert_grep "close.md retains ### 4.4.W.2 heading" "$CLOSE_MD" '^### 4\.4\.W\.2'

# 3.7.2.3: 4 値分岐。Done 同期成功は updated だけ。skip 3 枝には既 CLOSED / close 両方の成功文言が無い
assert_grep_in_section "archive 3.7.2.3 table has updated" "$ARCHIVE_MD" \
  "$S3723_START" "$S3723_END" \
  '`updated`'
assert_grep_in_section "archive 3.7.2.3 table has skipped_terminal_conflict" "$ARCHIVE_MD" \
  "$S3723_START" "$S3723_END" \
  '`skipped_terminal_conflict`'
assert_grep_in_section "archive 3.7.2.3 table has failed" "$ARCHIVE_MD" \
  "$S3723_START" "$S3723_END" \
  '`failed`'
assert_grep_in_section "archive 3.7.2.3 table has skipped_not_in_project" "$ARCHIVE_MD" \
  "$S3723_START" "$S3723_END" \
  '`skipped_not_in_project`'

_arch_updated=$(_result_block "$ARCHIVE_MD" "$S3723_START" "$S3723_END" "updated")
_arch_skip=$(_result_block "$ARCHIVE_MD" "$S3723_START" "$S3723_END" "skipped_terminal_conflict")
_arch_failed=$(_result_block "$ARCHIVE_MD" "$S3723_START" "$S3723_END" "failed")
_arch_nip=$(_result_block "$ARCHIVE_MD" "$S3723_START" "$S3723_END" "skipped_not_in_project")
_assert_block_grep "archive 3.7.2.3 updated branch keeps Done に同期しました" "$_arch_updated" 'Done に同期しました'
_assert_block_grep "archive 3.7.2.3 updated branch keeps Status: Done に更新" "$_arch_updated" 'Status: Done に更新'
_assert_block_not_grep "archive 3.7.2.3 skipped_terminal_conflict has no Done に同期しました" "$_arch_skip" 'Done に同期しました'
_assert_block_not_grep "archive 3.7.2.3 skipped_terminal_conflict has no Status: Done" "$_arch_skip" 'Status: Done'
_assert_block_grep "archive 3.7.2.3 skipped_terminal_conflict has Cancelled skip" "$_arch_skip" 'Cancelled のため Done 上書きをスキップ'
_assert_block_not_grep "archive 3.7.2.3 failed has no Done に同期しました" "$_arch_failed" 'Done に同期しました'
_assert_block_not_grep "archive 3.7.2.3 failed has no Status: Done" "$_arch_failed" 'Status: Done'
_assert_block_not_grep "archive 3.7.2.3 skipped_not_in_project has no Done に同期しました" "$_arch_nip" 'Done に同期しました'
_assert_block_not_grep "archive 3.7.2.3 skipped_not_in_project has no Status: Done" "$_arch_nip" 'Status: Done'

# 3.7.2.3 projects.enabled: false skip 枝。表行はパイプ列まで同一行で pin し、
# 節リードの `projects.enabled: false` 散文だけでは表行削除を pass にしない。
# skip テンプレは `.result=` ではないので固有見出しから次枝まで切る。
assert_grep_in_section "archive 3.7.2.3 table has projects.enabled: false skip row" "$ARCHIVE_MD" \
  "$S3723_START" "$S3723_END" \
  '3\.7\.2\.1 skip（`projects\.enabled: false`）[[:space:]]*\|[[:space:]]*Status 行なし[[:space:]]*\|[[:space:]]*Status 行なし'

_SKIP_CLOSED_RE='3\.7\.2\.1 skip（`projects\.enabled: false`）（親が既 CLOSED'
_SKIP_CLOSE_RE='3\.7\.2\.1 skip（`projects\.enabled: false`）（3\.7\.2\.2 で close）'
_arch_skip_closed=$(_heading_block "$ARCHIVE_MD" "$_SKIP_CLOSED_RE" "$_SKIP_CLOSE_RE") || true
_arch_skip_close=$(_heading_block "$ARCHIVE_MD" "$_SKIP_CLOSE_RE" "$S3723_END") || true
if [ "$_arch_skip_closed" = "NOEND" ] || [ -z "$_arch_skip_closed" ]; then
  fail "archive 3.7.2.3 skip already-CLOSED heading 終端が見つからない"
else
  _n_closed=$(printf '%s\n' "$_arch_skip_closed" | grep -c . || true)
  if [ "$_n_closed" -lt 3 ] || [ "$_n_closed" -gt 20 ]; then
    fail "archive 3.7.2.3 skip already-CLOSED heading 行数が ${_n_closed}（expected 3..20）"
  fi
fi
if [ "$_arch_skip_close" = "NOEND" ] || [ -z "$_arch_skip_close" ]; then
  fail "archive 3.7.2.3 skip close heading 終端が見つからない"
else
  _n_close=$(printf '%s\n' "$_arch_skip_close" | grep -c . || true)
  if [ "$_n_close" -lt 3 ] || [ "$_n_close" -gt 20 ]; then
    fail "archive 3.7.2.3 skip close heading 行数が ${_n_close}（expected 3..20）"
  fi
fi
_assert_block_grep "archive 3.7.2.3 skip already-CLOSED template exists" "$_arch_skip_closed" '既に CLOSED'
_assert_block_not_grep "archive 3.7.2.3 skip already-CLOSED has no Done に同期しました" "$_arch_skip_closed" 'Done に同期しました'
_assert_block_not_grep "archive 3.7.2.3 skip already-CLOSED has no Status: Done" "$_arch_skip_closed" 'Status: Done'
_assert_block_grep "archive 3.7.2.3 skip close template exists" "$_arch_skip_close" '完了した子 Issue'
_assert_block_not_grep "archive 3.7.2.3 skip close has no Done に同期しました" "$_arch_skip_close" 'Done に同期しました'
_assert_block_not_grep "archive 3.7.2.3 skip close has no Status: Done" "$_arch_skip_close" 'Status: Done'
_assert_block_not_grep "archive 3.7.2.3 skip close has no Status: line" "$_arch_skip_close" 'Status:'

# T-05: _result_block の start/end が ENVIRON。mawk でも revert を fail-loud にする。
# awk stderr の escape 警告も 1 回分観測する（gawk では警告、mawk では空で pass）。
SELF="$SCRIPT_DIR/$(basename "$0")"
assert_grep "_result_block reads start via ENVIRON" "$SELF" '\$0 ~ ENVIRON\["start_re"\] \{insec=1\}'
assert_grep "_result_block reads end via ENVIRON" "$SELF" 'insec && \$0 ~ ENVIRON\["end_re"\]'
_rb_err=$(mktemp)
_result_block "$CLOSE_MD" "$S44_START" "$S44_END" "updated" >/dev/null 2>"$_rb_err"
if grep -qE 'エスケープシーケンス|escape sequence' "$_rb_err"; then
  fail "T-05 _result_block awk stderr has escape-sequence warning"
else
  pass "T-05 _result_block awk stderr has no escape-sequence warning"
fi
rm -f "$_rb_err"

echo "=== Phase 8: close.md Phase 2 PR lookup is Issue-scoped ==="
# linked:issue / glob --head は絞り込めていないのに成功して見える。コマンド行だけを
# 禁じ、禁止を説明する散文は残してよい。
assert_not_grep "T-01 close.md does not use the unscoped linked:issue search" "$CLOSE_MD" \
  '^gh pr list.*--search "linked:issue:'
assert_not_grep "T-02 close.md does not pass a glob to --head" "$CLOSE_MD" \
  '\-\-head "\*issue-'
# 現行 2.1 fallback だった無制限 body 検索（--search / --head / --limit なし）の残存を落とす。
assert_not_grep "T-01b close.md Phase 2 has no unscoped gh pr list --state all --json body fetch" "$CLOSE_MD" \
  '^gh pr list -R \{owner_repo\} --state all --json'
assert_grep_in_section "T-03 close.md looks the PR up by the resolved branch with an exact --head" "$CLOSE_MD" \
  '^### 2\.2 関連 PR の検索' '^### 2\.3' \
  'gh pr list .*\-\-head "\{branch_name\}"'
# no-match は空（set -euo pipefail でも T-04 の else へ届ける）
_first_line() { grep -nE "$2" "$1" 2>/dev/null | head -1 | cut -d: -f1 || true; }
_branch_sec_line=$(_first_line "$CLOSE_MD" '^### 2\.1 作業ブランチの解決')
_pr_sec_line=$(_first_line "$CLOSE_MD" '^### 2\.2 関連 PR の検索')
if [ -n "$_branch_sec_line" ] && [ -n "$_pr_sec_line" ] && [ "$_branch_sec_line" -lt "$_pr_sec_line" ]; then
  pass "T-04 close.md branch resolution precedes the PR lookup"
else
  fail "T-04 close.md branch resolution must precede the PR lookup (branch=${_branch_sec_line:-none} pr=${_pr_sec_line:-none})"
fi
assert_grep_in_section "T-05 close.md binds the flow-state branch to the target Issue" "$CLOSE_MD" \
  '^### 2\.1 作業ブランチの解決' '^### 2\.2' 'get --field issue_number'
assert_grep "T-05 close.md adopts the flow-state branch only on an Issue-number match" "$CLOSE_MD" \
  '^\| `state_issue == \{issue_number\}` かつ `state_branch` が非空 \|'
assert_grep_in_section "T-06 close.md fallback lookup is Issue-scoped via the timeline API" "$CLOSE_MD" \
  '^### 2\.2 関連 PR の検索' '^### 2\.3' \
  '^_tl_raw=\$\(gh api "repos/\{owner\}/\{repo\}/issues/\{issue_number\}/timeline" --paginate'
assert_grep_in_section "T-06 close.md routes unresolved or empty --head to timeline" "$CLOSE_MD" \
  '^### 2\.2 関連 PR の検索' '^### 2\.3' \
  'ブランチが未確定、または上記が 0 件のときは'
assert_not_grep "T-06 close.md uses no unscoped gh pr list --limit window" "$CLOSE_MD" \
  '^gh pr list.*--limit'
assert_grep_in_section "T-07 close.md captures timeline rc from a single command, not a pipeline" "$CLOSE_MD" \
  '^### 2\.2 関連 PR の検索' '^### 2\.3' \
  '^  2>"\$_tl_err"\) \|\| _tl_rc=\$\?$'
assert_grep_in_section "T-08 close.md timeline jq filter uses truthiness, not != null" "$CLOSE_MD" \
  '^### 2\.2 関連 PR の検索' '^### 2\.3' \
  'select\(\.pull_request\) \| \.number'
assert_not_grep "T-08 close.md contains no jq select(... != null)" "$CLOSE_MD" \
  'select\(.*!= *null'
assert_grep_in_section "T-09 close.md filters by closing keyword before the aggregate table" "$CLOSE_MD" \
  '^### 2\.2 関連 PR の検索' '^### 2\.3' \
  'Closes/Fixes/Resolves #\{issue_number\}'
assert_grep_in_section "T-09 close.md also filters by headRefName before the aggregate table" "$CLOSE_MD" \
  '^### 2\.2 関連 PR の検索' '^### 2\.3' \
  'headRefName` が `issue-\{issue_number\}-'
assert_grep_in_section "T-09 close.md does not put the unfiltered set on the 2.3 table" "$CLOSE_MD" \
  '^### 2\.2 関連 PR の検索' '^### 2\.3' \
  '\*\*絞り込み前の集合を 2\.3 の集約表に載せてはならない\*\*'
assert_grep_in_section "T-09 close.md passes only the filtered set to Phase 3 Pattern A/B/C/D" "$CLOSE_MD" \
  '^### 2\.2 関連 PR の検索' '^### 2\.3' \
  '絞り込み後集合だけを 2\.3 と Phase 3 の Pattern A/B/C/D に渡す'
assert_grep_in_section "T-10 close.md treats empty filter results as no related PR" "$CLOSE_MD" \
  '^### 2\.2 関連 PR の検索' '^### 2\.3' \
  '\*\*絞り込み結果 0 件は「関連 PR が無い」と読んでよい\*\*'
assert_grep_in_section "T-10 close.md stops on a failed timeline fetch" "$CLOSE_MD" \
  '^### 2\.2 関連 PR の検索' '^### 2\.3' \
  '^  echo "ERROR: Issue timeline を取得できません'
assert_grep_in_section "T-10 close.md does not fold a fetch failure into Pattern D" "$CLOSE_MD" \
  '^### 2\.2 関連 PR の検索' '^### 2\.3' \
  'Pattern D に倒さない'
assert_grep_in_section "T-11 close.md applies the charset predicate at assignment time" "$CLOSE_MD" \
  '^### 2\.1 作業ブランチの解決' '^### 2\.2' \
  '\*\*charset 述語（値を `\{branch_name\}` に代入する時点で適用する）\*\*'
assert_grep_in_section "T-11 close.md charset mismatch falls through to unresolved then timeline" "$CLOSE_MD" \
  '^### 2\.1 作業ブランチの解決' '^### 2\.2' \
  '2\.2 は `--head` を使わず timeline へ倒す'
assert_grep "T-12 close.md retains Pattern A (MERGED + closing keyword → auto-closed)" "$CLOSE_MD" \
  '^#### Pattern A: Already Auto-Closed'
assert_grep "T-12 close.md retains Pattern B (PR exists but no auto-close)" "$CLOSE_MD" \
  '^#### Pattern B: PR Exists but No Auto-Close'
assert_grep "T-12 close.md retains Pattern C (PR awaiting merge)" "$CLOSE_MD" \
  '^#### Pattern C: PR Awaiting Merge'
assert_grep "T-12 close.md retains Pattern D (no PR → AskUserQuestion)" "$CLOSE_MD" \
  '^#### Pattern D: No PR Found'
assert_grep_in_section "T-12 close.md Pattern D still uses AskUserQuestion" "$CLOSE_MD" \
  '^#### Pattern D: No PR Found' '^## Phase 4' \
  'AskUserQuestion'
assert_not_grep "T-12 close.md Phase 2 does not stop on mergedAt like issue-cancel" "$CLOSE_MD" \
  '^\| `mergedAt` が非 null の PR がある \|'

if ! print_summary "$(basename "$0")" "If you remove any of the 3 parent-detection methods (body meta / GraphQL trackedIssues / tasklist) from close.md or pr/open.md ステップ 1.2, or drop stateReason from parent auto-close, or restore unscoped linked:issue / glob --head PR lookup in close.md Phase 2, regression risk reopens. Re-confirm cross-references before removing methods."; then
  exit 1
fi
