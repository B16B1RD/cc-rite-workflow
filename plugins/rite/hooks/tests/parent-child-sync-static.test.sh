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
assert_grep "close.md Shared table dispatches skipped_terminal_conflict" "$CLOSE_MD" 'skipped_terminal_conflict'
assert_grep "close.md 4.6.3 case arm sets skipped_terminal" "$CLOSE_MD" 'status_update_result="skipped_terminal"'
assert_grep "close.md 4.6.3 Step 3 treats skipped_terminal as 整合性 OK" "$CLOSE_MD" 'success:skipped_terminal'

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

echo "=== Phase 6: open.md が検出した親番号を flow-state へ書く (#2460) ==="
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

# 文書同期: ステップ 10 の「全子完了→auto-close」旧要約が残っていない
assert_grep_in_section "cleanup ステップ 10 auto-close requires stateReason != NOT_PLANNED" "$CLEANUP_MD" \
  "$S10_START" "$S10_END" \
  'stateReason != NOT_PLANNED'
assert_not_grep "cleanup ステップ 10 no longer says 全子 Issue が完了していれば parent も auto-close" "$CLEANUP_MD" \
  '全子 Issue が完了していれば parent も auto-close'

# regression: Method B state 失敗→OPEN 保全 / OPEN+null は欠落にしない
assert_grep_in_section "Method B state fetch failure still fail-closed as OPEN" "$CLOSE_MD" \
  "$S461_START" "$S461_END" \
  'state 取得失敗は fail-closed \(OPEN 扱い\)'
assert_grep_in_section "OPEN child null stateReason is not treated as unavailable" "$CLOSE_MD" \
  "$S461_START" "$S461_END" \
  'OPEN 子の stateReason null は正常'
assert_not_grep "OPEN fail-closed is not folded into skip_reason_unavailable" "$CLOSE_MD" \
  'state 取得失敗は fail-closed.*skip_reason_unavailable'

if ! print_summary "$(basename "$0")" "If you remove any of the 3 parent-detection methods (body meta / GraphQL trackedIssues / tasklist) from close.md or pr/open.md ステップ 1.2, or drop stateReason from parent auto-close, regression risk reopens. Re-confirm cross-references before removing methods."; then
  exit 1
fi
