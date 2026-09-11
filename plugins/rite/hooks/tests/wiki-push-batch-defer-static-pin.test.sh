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

# The helper shares rc=1 between pre-commit policy refusal and environment / argument
# errors. Exercise the embedded routing block so a future prose-only or unreachable
# reason check cannot silently restore the misleading numref-only recovery hint.
route_case=$(mktemp "${TMPDIR:-/tmp}/rite-wiki-ingest-route-case-XXXXXX")
route_tmp=$(mktemp -d "${TMPDIR:-/tmp}/rite-wiki-ingest-route-XXXXXX")
cleanup_route_test() { rm -f "$route_case"; rm -rf "$route_tmp"; }
trap cleanup_route_test EXIT

awk '
  /^  case "\$commit_rc" in$/ { capture=1 }
  capture {
    print
    if ($0 ~ /^[[:space:]]*case .* in$/) depth++
    if ($0 ~ /^[[:space:]]*esac$/) {
      depth--
      if (depth == 0) exit
    }
  }
' "$INGEST_MD" > "$route_case"

assert_route() {
  local name="$1" helper_out="$2" expected="$3" forbidden="$4"
  local out_file="$route_tmp/$name.out" err_file="$route_tmp/$name.err" rc=0
  bash -c 'commit_rc=1; commit_out=$1; source "$2"' _ "$helper_out" "$route_case" \
    >"$out_file" 2>"$err_file" || rc=$?
  assert "$name exits 1" "1" "$rc"
  assert_grep "$name selects expected recovery" "$err_file" "$expected"
  assert_not_grep "$name rejects the other recovery" "$err_file" "$forbidden"
}

assert_route "numref-hit" \
  '[wiki-worktree-commit] committed=0; branch=wiki; reason=numref-hit' \
  '番号参照の commit 前検査で拒否' '環境または引数エラー'
assert_route "numref-error" \
  '[wiki-worktree-commit] committed=0; branch=wiki; reason=numref-error' \
  '番号参照の commit 前検査で拒否' '環境または引数エラー'
assert_route "reason missing" '' \
  '環境または引数エラー' '番号参照の commit 前検査で拒否'
assert_route "unknown reason" \
  '[wiki-worktree-commit] committed=0; branch=wiki; reason=other-error' \
  '環境または引数エラー' '番号参照の commit 前検査で拒否'
assert_route "similar numref token" \
  '[wiki-worktree-commit] committed=0; branch=wiki; reason=numref-hit-extra' \
  '環境または引数エラー' '番号参照の commit 前検査で拒否'

assert_grep_in_section "ingest.md error table limits numref recovery to matching stdout reason" \
  "$INGEST_MD" '^## エラーハンドリング' '^---$' \
  'exit 1.*stdout `reason=numref-hit` / `numref-error`'
assert_grep_in_section "ingest.md error table routes other rc=1 failures to stderr diagnosis" \
  "$INGEST_MD" '^## エラーハンドリング' '^---$' \
  'exit 1.*stdout に `reason=numref-hit` / `numref-error` なし.*環境 / 引数エラー'

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
