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

for f in "$CLOSE_MD" "$PR_OPEN_MD" "$PROJECTS_REF" "$ARCHIVE_MD"; do
  [ -f "$f" ] || { echo "ERROR: required file not found: $f" >&2; exit 1; }
done

echo "=== Phase 1: close.md retains 3 detection methods (regression guard) ==="
assert_grep "close.md retains Method 1 (## 親 Issue body meta)" "$CLOSE_MD" "## 親 Issue"
assert_grep "close.md retains trackedIssues field usage" "$CLOSE_MD" "trackedIssues"
assert_grep "close.md retains tasklist search method" "$CLOSE_MD" "in:body|tasklist"

echo "=== Phase 2: close.md Phase 4.6 auto-close decision skeleton ==="
assert_grep "close.md retains P460_DECISION skip_already_closed branch" "$CLOSE_MD" "P460_DECISION|skip_already_closed|Phase 4\.6"

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

print_summary "$(basename "$0")" "If you remove any of the 3 parent-detection methods (body meta / GraphQL trackedIssues / tasklist) from close.md or pr/open.md ステップ 1.2, regression risk reopens. Re-confirm cross-references before removing methods."
