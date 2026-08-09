#!/bin/bash
# Static contract tests for Issue #2128: /rite:merge must fail closed when CI is
# unhealthy, distinguish executed failures from jobs that never ran, and expose
# only an explicit override. The skill is prose-driven, so grep-pin the routing
# and classification invariants that an LLM executes.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

MERGE="$SCRIPT_DIR/../../skills/merge/SKILL.md"

echo "=== merge CI gate routing (T-01/T-02/T-05/T-06/T-07) ==="
assert_grep "canonical PR query includes the complete CI gate input" "$MERGE" \
  '^pr_json=\$\(gh pr view \{pr_number\} -R \{owner_repo\} --json mergeable,mergeStateStatus,isDraft,headRefName,statusCheckRollup\)'
assert_grep "force override defaults to disabled" "$MERGE" '^force_ci=false$'
assert_grep "force override parser is token-bounded and position-independent" "$MERGE" \
  '^case " \{arguments\} " in \*" --force-ci "\*\) force_ci=true ;; esac$'
assert_grep "healthy checks proceed to step 2" "$MERGE" 'checks が全件 healthy.*ステップ 2 へ'
assert_grep "MERGEABLE plus UNSTABLE is still not ready" "$MERGE" 'mergeStateStatus == "UNSTABLE".*\[merge:not-ready\]'
assert_grep "unhealthy default path forbids gh pr merge" "$MERGE" 'ステップ 2 の `gh pr merge` は実行しない'
assert_grep "pending checks stop without a wait loop" "$MERGE" 'checks が pending.*待機・自動 retry はしない'
assert_grep "pending predicate is mechanical" "$MERGE" '\.status != "COMPLETED" or \.conclusion == ""'
assert_grep "healthy conclusions are an allowlist" "$MERGE" '\["SUCCESS", "NEUTRAL", "SKIPPED"\]'
assert_grep "malformed and unknown states fail closed" "$MERGE" 'checks_state == "unknown".*\[merge:not-ready\]'
assert_grep "unknown cannot use force override" "$MERGE" '`--force-ci` でも unknown は override しない'
assert_grep "classification failure is surfaced" "$MERGE" '分類不能.*原因を表示'
assert_grep "classification failure is fail closed" "$MERGE" '`force_ci == false` では必ず `\[merge:not-ready\]` へ倒す'
assert_grep "explicit force-ci override is documented" "$MERGE" '/rite:merge --force-ci \{pr_number\}'

echo "=== job classification facts (T-03/T-04) ==="
assert_grep "jobs API is the classification input" "$MERGE" 'actions/runs/\{run_id\}/jobs --paginate'
assert_grep "never-run predicate uses empty runner and zero steps" "$MERGE" '`runner_name` が空、かつ `steps \| length == 0`'
assert_grep "cancelled with execution evidence is a real failure" "$MERGE" '`conclusion == "cancelled"` でも runner/steps が存在すればこちら'
assert_grep "display strings are named explicitly" "$MERGE" '`gh pr checks` の表示文字列'
assert_grep "display strings are not classification evidence" "$MERGE" '（`fail` 等）は分類根拠に使わない'

echo "=== no-check compatibility and operator guidance (T-01/T-07) ==="
assert_grep "repositories without checks preserve existing behavior" "$MERGE" 'checks 0 件.*従来どおりステップ 2 へ'
assert_grep "never-run jobs surface a concrete rerun command" "$MERGE" 'gh run rerun \{run_id\} -R \{owner_repo\} --failed'
assert_grep "all-never-run case says no CI signal exists" "$MERGE" 'CI シグナルが存在しない'
assert_grep "automatic rerun is prohibited" "$MERGE" '自動で rerun してはならない'

if ! print_summary "$(basename "$0")" "mergeStateStatus の CI gate・jobs API 分類・明示 override contract (Issue #2128 T-01〜T-08)"; then
  exit 1
fi
