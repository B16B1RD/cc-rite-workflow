#!/bin/bash
# gh-issue-develop-base.test.sh
#
# base がデフォルトブランチと異なる git-flow では、remote branch を作る
# `gh issue develop` に `--base` を明示する規則 (references/gh-cli-patterns.md)
# の機械検証。plugins/rite/ 配下の `gh issue develop` を含む行は、
# すべて同じ行に `--base` を伴わなければならない。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"

# TC-1: 全ての `gh issue develop` 記述が --base を伴う
violations=$(grep -rnE 'gh issue develop' "$PLUGIN_ROOT" --include='*.md' --include='*.sh' --include='*.yml' \
  | grep -v -F 'gh-issue-develop-base.test.sh' \
  | grep -v -e '--base' || true)
if [ -z "$violations" ]; then
  pass "TC-1 全ての gh issue develop 記述が --base を伴う"
else
  fail "TC-1 --base なしの gh issue develop を検出:
$violations"
fi

# TC-2: 検出器自体が機能する (--base なしの行を違反として拾う)
sample=$(printf '%s\n' 'gh issue develop 1 -R o/r' 'gh issue develop 1 -R o/r --base develop' | grep -v -e '--base' || true)
if [ "$sample" = "gh issue develop 1 -R o/r" ]; then
  pass "TC-2 検出パターンが --base なしの行のみを拾う"
else
  fail "TC-2 検出パターンが期待どおりに動作しない: $sample"
fi

print_summary "gh-issue-develop-base.test.sh"
