#!/bin/bash
# wiki-push-batch-defer-static-pin.test.sh
#
# Static-pin meta-test for the wiki push batch/defer contract: within one
# /rite:wiki-ingest flow, `git push origin {wiki_branch}` must land at most
# once (AC-1), regardless of how many raw sources are processed and whether
# auto_lint runs. The guarantee is implemented as markdown orchestration
# (wiki-ingest/SKILL.md ステップ 5.1 / 8.6, wiki-lint/SKILL.md ステップ 8.3)
# calling `wiki-worktree-commit.sh --commit-only` / `--push-only`
# (hooks/tests/wiki-worktree-commit.test.sh proves the script contract) —
# nothing at the shell-script level would fail if a future edit quietly
# reverted one of the three call sites back to the old commit+push-together
# invocation. This test pins those three sites so such a regression fails
# loudly instead of silently reintroducing per-page pushes.
#
# When this test fails:
#   One of ingest.md ステップ 5.1 / 8.6 or lint.md ステップ 8.3 no longer
# matches the batch/defer contract. Re-read 's Before/After Contract
#   and restore --commit-only (5.1, lint 8.3 --auto branch) / --push-only
#   (8.6), or update this test if the contract has legitimately changed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
INGEST_MD="$PLUGIN_ROOT/skills/wiki-ingest/SKILL.md"
LINT_MD="$PLUGIN_ROOT/skills/wiki-lint/SKILL.md"

if [ ! -f "$INGEST_MD" ]; then
  echo "ERROR: $INGEST_MD not found" >&2
  exit 1
fi
if [ ! -f "$LINT_MD" ]; then
  echo "ERROR: $LINT_MD not found" >&2
  exit 1
fi

echo "=== wiki-push-batch-defer-static-pin.test.sh ==="

# --- ingest.md ステップ 5.1: per-raw-source commit is --commit-only (no push) ---
assert_grep_in_section "ingest.md 5.1: wiki-worktree-commit.sh invoked with --commit-only" \
  "$INGEST_MD" '^### 5\.1 separate_branch 戦略' '^### 5\.2' \
  'wiki-worktree-commit\.sh" --commit-only'
assert_not_grep "ingest.md 5.1 does not fall back to a bare (push-included) commit invocation" \
  "$INGEST_MD" 'wiki-worktree-commit\.sh" --message "\$commit_msg"\)$'

# --- ingest.md ステップ 8.6: the single aggregate push, always run (auto_lint-independent) ---
assert_grep_in_section "ingest.md 8.6: wiki-worktree-commit.sh invoked with --push-only" \
  "$INGEST_MD" '^### 8\.6 Wiki push の集約' '^## ステップ 9' \
  'wiki-worktree-commit\.sh" --push-only'
assert_grep "ingest.md auto_lint=false does NOT skip ステップ 8.6 (push must still run)" \
  "$INGEST_MD" 'ステップ 8\.6.*スキップしない'

# --- lint.md ステップ 8.3: --auto (from ingest) defers to --commit-only; standalone still pushes ---
# (grep -E has no cross-line match, so the "auto_mode=true branch calls --commit-only" contract
# is pinned as two independent assertions — the gate exists, and --commit-only exists in the
# same section — rather than one pattern spanning both lines.)
assert_grep_in_section "lint.md 8.3: auto_mode gate is present" \
  "$LINT_MD" '^### 8\.3 書き込み手順' '^## ステップ 9' \
  'if \[ "\$auto_mode" = "true" \]'
assert_grep_in_section "lint.md 8.3: --commit-only call exists in the section" \
  "$LINT_MD" '^### 8\.3 書き込み手順' '^## ステップ 9' \
  'wiki-worktree-commit\.sh" --commit-only'
assert_grep_in_section "lint.md 8.3: standalone (non-auto) branch still commits + pushes immediately" \
  "$LINT_MD" '^### 8\.3 書き込み手順' '^## ステップ 9' \
  'wiki-worktree-commit\.sh" --message "\$commit_msg"\)$'

print_summary "wiki-push-batch-defer-static-pin.test.sh"
