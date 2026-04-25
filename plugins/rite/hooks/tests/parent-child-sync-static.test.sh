#!/bin/bash
# Static regression tests for Issue #513 parent-child Issue status sync.
#
# Guards against re-introduction of silent-skip patterns that caused
# past incidents #115, #381, #15 and the #513 reopening. Verifies that
# the three canonical files contain the 3-method OR detection and that
# close.md has Phase 4.6 Parent Auto-Close logic.
#
# Usage: bash plugins/rite/hooks/tests/parent-child-sync-static.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
PROJECTS_INTEGRATION="$REPO_ROOT/plugins/rite/references/projects-integration.md"
CLOSE_MD="$REPO_ROOT/plugins/rite/commands/issue/close.md"
START_MD="$REPO_ROOT/plugins/rite/commands/issue/start.md"

PASS=0
FAIL=0
FAILURES=()

assert_file_contains() {
  local file="$1"
  local pattern="$2"
  local description="$3"
  # Use `-e` explicitly so patterns that start with `-` (e.g. `--jq...`) are not
  # interpreted as grep flags. `-E` must precede `-e` for extended regex.
  if grep -qE -e "$pattern" "$file"; then
    PASS=$((PASS + 1))
    echo "  ✓ $description"
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("$description (file: $(basename "$file"), pattern: $pattern)")
    echo "  ✗ $description" >&2
  fi
}

assert_file_not_contains() {
  local file="$1"
  local pattern="$2"
  local description="$3"
  if grep -qE -e "$pattern" "$file"; then
    FAIL=$((FAIL + 1))
    FAILURES+=("$description (file: $(basename "$file"), forbidden pattern found: $pattern)")
    echo "  ✗ $description" >&2
  else
    PASS=$((PASS + 1))
    echo "  ✓ $description"
  fi
}

echo "=== T-07: Parent-child sync regression guards (Issue #513) ==="

# Prerequisite: all three files exist
for f in "$PROJECTS_INTEGRATION" "$CLOSE_MD" "$START_MD"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: required file not found: $f" >&2
    exit 1
  fi
done

echo ""
echo "[Group 1] projects-integration.md 2.4.7.1: 3-method OR detection"
assert_file_contains "$PROJECTS_INTEGRATION" '## 親 Issue' \
  "Method 1 (body meta '## 親 Issue') is present"
assert_file_contains "$PROJECTS_INTEGRATION" 'parent[[:space:]]*\{[[:space:]]*number' \
  "Method 2 (Sub-Issues API 'parent { number }') is present"
# --state filter is intentionally context-dependent (open=start side / all=close side);
# check for --state presence without fixing the value, plus `in:body` tasklist search marker.
assert_file_contains "$PROJECTS_INTEGRATION" 'gh issue list[[:space:]]+--state[[:space:]]+[a-z]+[[:space:]]+--search.*in:body' \
  "Method 3 (tasklist search) is present"
assert_file_contains "$PROJECTS_INTEGRATION" '\[DEBUG\] parent not detected' \
  "Silent-skip guard: explicit debug log on no-parent case (AC-4)"

echo ""
echo "[Group 2] close.md Phase 4.5.1: 3-method OR detection (consistency with start)"
assert_file_contains "$CLOSE_MD" '## 親 Issue' \
  "Method 1 (body meta '## 親 Issue') is present"
assert_file_contains "$CLOSE_MD" 'parent[[:space:]]*\{[[:space:]]*number[[:space:]]*\}' \
  "Method 2 (Sub-Issues API 'parent { number }') is present"
assert_file_contains "$CLOSE_MD" 'gh issue list[[:space:]]+--state[[:space:]]+[a-z]+.*--search.*in:body' \
  "Method 3 (tasklist search) is present"
assert_file_contains "$CLOSE_MD" '\[DEBUG\] parent not detected' \
  "Silent-skip guard: explicit debug log on no-parent case (AC-4)"

echo ""
echo "[Group 3] close.md Phase 4.6: Parent Auto-Close logic (AC-2 + close-side idempotency)"
assert_file_contains "$CLOSE_MD" '^##[[:space:]]+Phase[[:space:]]+4\.6' \
  "Phase 4.6 heading is present"
# Close-side idempotency guard: parent_state retrieval + CLOSED short-circuit
assert_file_contains "$CLOSE_MD" 'parent_state=.*gh issue view.*parent_number.*--jq.*\.state' \
  "Phase 4.6.0 idempotency guard: parent_state retrieval exists"
assert_file_contains "$CLOSE_MD" 'P460_DECISION=skip_already_closed' \
  "Phase 4.6.0 idempotency guard: skip_already_closed sentinel exists"
# HIGH fix (cycle 2): parent_state retrieval failure branch is in bash, not prose-only
assert_file_contains "$CLOSE_MD" 'P460_DECISION=skip_retrieval_failed' \
  "Phase 4.6.0 retrieval-failure branch: skip_retrieval_failed sentinel exists"
# all-children-closed check — flexible whitespace around operators
assert_file_contains "$CLOSE_MD" 'all_closed=.*all\([[:space:]]*\.\[\][[:space:]]*;[[:space:]]*\.state[[:space:]]*==[[:space:]]*"CLOSED"' \
  "All-children-closed check logic is present"
assert_file_contains "$CLOSE_MD" 'gh issue close.*parent_number' \
  "Parent close command is present"
# Issue #658 PR #659 で Phase 4.6.3 の bash 構造が抜本的に変更された:
#   - Step 1-5 → Step 1-3 に整理 (Step 1=script delegate / Step 2=gh issue close / Step 3=inconsistency summary)
#   - inline `gh api graphql` + `gh project field-list` + `gh project item-edit` の 3 段 pipeline を
#     `bash {plugin_root}/scripts/projects-status-update.sh` への delegate に統一
#   - `p463_err_s1-4` (4 変数) → `p463_err_close` + `p463_err_status` (2 変数) に統合
#   - `success:field_lookup_failed` 独立 case を `success:update_failed` へ合流 (5-class → 4-class)
#   - `done_option_id` / `parent_item_id` の jq 抽出は script に移管 (caller 側では不要)
# 本 group のアサーションは新構造 (delegate + 2-tempfile + 4-class) を期待する形に更新する
# (Issue #513 / #517 / #658 incident regression gate を維持)
assert_file_contains "$CLOSE_MD" 'projects-status-update\.sh' \
  "Phase 4.6.3 Step 1: delegate to projects-status-update.sh (Issue #658)"
assert_file_contains "$CLOSE_MD" 'jq -r .*\.result.*//.*"failed"' \
  "Phase 4.6.3 Step 1: delegate result jq extraction (.result // \"failed\")"
assert_file_contains "$CLOSE_MD" 'jq -r .*\.warnings\[\]' \
  "Phase 4.6.3 Step 1: delegate warnings jq extraction (.warnings[]?)"
# state-inconsistency summary (Issue #517 invariants preserved)
assert_file_contains "$CLOSE_MD" 'state 不整合' \
  "Phase 4.6.3 Step 3: state inconsistency summary is emitted"
# 4-class case 構造 (5-class field_lookup_failed → update_failed 合流、Issue #658)
assert_file_contains "$CLOSE_MD" '"success:update_failed"\)' \
  "Phase 4.6.3 Step 3: success:update_failed dedicated case (5-class → 4-class merge)"
# F-09 修正で failed:projects_disabled と failed:not_registered は独立 case に分離 (Issue #658 cycle 1)
assert_file_contains "$CLOSE_MD" '"failed:projects_disabled"\)' \
  "Phase 4.6.3 Step 3: failed:projects_disabled is a dedicated case"
assert_file_contains "$CLOSE_MD" '"failed:not_registered"\)' \
  "Phase 4.6.3 Step 3: failed:not_registered is a dedicated case (separated from catch-all)"
assert_file_contains "$CLOSE_MD" 'gh project item-add' \
  "Phase 4.6.3 Step 3: failed:not_registered case offers gh project item-add hint"
assert_file_contains "$CLOSE_MD" 'AskUserQuestion' \
  "User confirmation via AskUserQuestion (AC-2: not silent auto-close)"
# Cycle 1 HIGH fix: Method A uses tempfile stderr capture (not 2>/dev/null)
assert_file_contains "$CLOSE_MD" 'method_a_err=.*mktemp' \
  "Phase 4.6.1 Method A stderr capture (no silent suppression)"
# Issue #658 cycle 1 F-03 修正: Phase 4.6.3 では stderr capture 用 tempfile が
# `p463_err_close` (gh issue close stderr) と `p463_err_status` (script invocation stderr) の
# 2 変数に統合された (旧 p463_err_s1-4 の 4 変数からの delegate 移行)。
# F-03 で導入した script invocation stderr capture により JSON 出力前死亡時 (jq 不在 / mktemp
# 失敗 / placeholder 置換漏れ) の原因を `status_warning_lines` に注入して Step 3 で surface する。
assert_file_contains "$CLOSE_MD" 'p463_err_close.*mktemp' \
  "Phase 4.6.3 Step 2 (gh issue close): stderr tempfile capture (p463_err_close)"
assert_file_contains "$CLOSE_MD" 'p463_err_status.*mktemp' \
  "Phase 4.6.3 Step 1 (script invocation): stderr tempfile capture (p463_err_status, F-03)"
assert_file_contains "$CLOSE_MD" 'script invocation died before JSON emit' \
  "Phase 4.6.3 Step 1: F-03 stderr injection prefix into status_warning_lines"
# Regression guard: 旧 p463_err_s1-4 (4 変数) への参照が残存していないこと (delegate 移行後 dead state)
assert_file_not_contains "$CLOSE_MD" 'p463_err_s[1-4]' \
  "Regression guard: legacy p463_err_s1-4 references removed (delegate 化で 2 変数に統合)"
# Regression guard: success:field_lookup_failed 独立 case が削除されている (4-class 合流済み)
assert_file_not_contains "$CLOSE_MD" '"success:field_lookup_failed"' \
  "Regression guard: legacy success:field_lookup_failed case removed (5-class → 4-class merge)"
# Cycle 2 MEDIUM fix: strict mode (set -uo pipefail) in Phase 4.6.0, 4.6.1, 4.6.3 bash blocks
assert_file_contains "$CLOSE_MD" 'Phase 4\.6\.0.*parent already closed' \
  "Phase 4.6.0 bash block header present"
# Cycle 2 HIGH fix: trackedIssues is labeled as Tasklists API (not Sub-Issues API)
assert_file_contains "$CLOSE_MD" 'trackedIssues.*Tasklists' \
  "Phase 4.6.1 Method A is correctly labeled as Tasklists API (not Sub-Issues API)"
assert_file_not_contains "$CLOSE_MD" 'Method A: Sub-Issues API' \
  "Regression guard: Method A mislabel 'Sub-Issues API' is removed"
# Cycle 2 HIGH fix: stale subsection reference 4.6.1-4.6.5 is corrected to 4.6.1-4.6.3
assert_file_not_contains "$CLOSE_MD" '4\.6\.1–4\.6\.5' \
  "Regression guard: stale 4.6.1-4.6.5 reference is removed (actual range is 4.6.1-4.6.3)"
# Cycle 2 MEDIUM fix: AC-6 citation is clarified as close-side extension, not literal AC-6
assert_file_contains "$CLOSE_MD" 'close-side idempotency' \
  "Phase 4.6.0 clarifies close-side idempotency (AC-6 applies to start side, not close side)"
# Cycle 3 LOW fix: Phase 4.6.0 placeholder sanity guard (unsubstituted / non-numeric parent_number)
assert_file_contains "$CLOSE_MD" 'P460_DECISION=skip_routing_bug' \
  "Phase 4.6.0 placeholder sanity guard: skip_routing_bug sentinel exists"
assert_file_contains "$CLOSE_MD" "''[|]'\\{parent_number\\}'" \
  "Phase 4.6.0 placeholder sanity guard: empty-or-literal placeholder case pattern exists"
# Cycle 3 LOW fix: _mktemp_or_warn helper takes exactly 1 arg (label), no dead var_name parameter
assert_file_contains "$CLOSE_MD" '_mktemp_or_warn\(\) \{' \
  "Helper _mktemp_or_warn is defined"
assert_file_not_contains "$CLOSE_MD" 'local var_name=' \
  "Regression guard: _mktemp_or_warn no longer takes dead var_name parameter"
assert_file_not_contains "$CLOSE_MD" '_mktemp_or_warn "p463_err_s' \
  "Regression guard: callers no longer pass dead var_name first arg"

echo ""
echo "[Group 4] start.md: no inline trackedInIssues simplification (Issue #513 root cause)"
assert_file_not_contains "$START_MD" 'Query trackedInIssues for the current Issue' \
  "Regression guard: inline 'Query trackedInIssues' simplification is removed"
assert_file_contains "$START_MD" 'projects-integration\.md#247' \
  "Delegation to projects-integration.md §2.4.7 is present"
assert_file_contains "$START_MD" 'Issue #513 regression guard' \
  "Regression guard comment is present (prevents re-introduction)"

echo ""
echo "==============================="
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "Failures:"
  for msg in "${FAILURES[@]}"; do
    echo "  - $msg"
  done
  exit 1
fi
echo "All parent-child-sync static checks passed."
