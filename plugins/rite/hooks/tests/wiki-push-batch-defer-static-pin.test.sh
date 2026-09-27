#!/bin/bash
# wiki-push-batch-defer-static-pin.test.sh
#
# Static-pin meta-test for the wiki push batch/defer contract: within one
# /rite:wiki-ingest flow, `git push origin {wiki_branch}` must land at most
# once (AC-1), regardless of how many raw sources are processed and whether
# auto_lint runs. The guarantee is implemented as markdown orchestration
# (wiki-ingest/SKILL.md ステップ 5.1 / 8.6, hooks/scripts/wiki-lint-log-commit.sh called
# from wiki-lint/SKILL.md ステップ 8.3)
# calling `wiki-worktree-commit.sh --commit-only` / `--push-only`
# (hooks/tests/wiki-worktree-commit.test.sh proves the script contract) —
# nothing at the shell-script level would fail if a future edit quietly
# reverted one of the three call sites back to the old commit+push-together
# invocation. This test pins those three sites so such a regression fails
# loudly instead of silently reintroducing per-page pushes.
#
# When this test fails:
#   One of ingest.md ステップ 5.1 / 8.6, lint.md ステップ 8.3 or wiki-lint-log-commit.sh no longer
# matches the batch/defer contract. Re-read 's Before/After Contract
#   and restore --commit-only (5.1, wiki-lint-log-commit.sh --auto branch) / --push-only
#   (8.6), or update this test if the contract has legitimately changed.
#   A failing wiki-lint-log-commit.sh rc case means the helper's keep_message /
#   cleanup contract (its header) no longer holds: only rc=6 keeps the message file.
#   A failing rc=1 reason case means the helper names the wrong cause for rc=1.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
INGEST_MD="$PLUGIN_ROOT/skills/wiki-ingest/SKILL.md"
LINT_MD="$PLUGIN_ROOT/skills/wiki-lint/SKILL.md"
LINT_COMMIT_SH="$PLUGIN_ROOT/hooks/scripts/wiki-lint-log-commit.sh"
INIT_MD="$PLUGIN_ROOT/skills/wiki-init/SKILL.md"

if [ ! -f "$INGEST_MD" ]; then
  echo "ERROR: $INGEST_MD not found" >&2
  exit 1
fi
if [ ! -f "$LINT_MD" ]; then
  echo "ERROR: $LINT_MD not found" >&2
  exit 1
fi
if [ ! -f "$INIT_MD" ]; then
  echo "ERROR: $INIT_MD not found" >&2
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

# rc=6 (admin dir not writable) must reach its own branch rather than the unknown-rc
# fallback, and tell the agent to retry the block once outside the sandbox.
mask_route_rc=0
bash -c 'commit_rc=6; commit_out=$1; source "$2"' _ \
  '[wiki-worktree-commit] committed=0; branch=wiki; reason=sandbox-mask' "$route_case" \
  >"$route_tmp/mask.out" 2>"$route_tmp/mask.err" || mask_route_rc=$?
assert "rc=6 exits 1" "1" "$mask_route_rc"
assert_grep "rc=6 emits the sandbox-mask marker" "$route_tmp/mask.out" '\[CONTEXT\] WIKI_INGEST_COMMIT=sandbox-mask'
assert_grep "rc=6 tells the agent to retry once outside the sandbox" "$route_tmp/mask.err" \
  'dangerouslyDisableSandbox: true を付けて 1 回だけ再実行'
assert_not_grep "rc=6 does not fall through to the unknown exit code branch" "$route_tmp/mask.err" '予期しない exit code'

assert_grep_in_section "ingest.md 5.0.n: sandbox-mask row retries the step once outside the sandbox" \
  "$INGEST_MD" '^### 5\.0\.n ' '^### 5\.1 ' \
  'reason=sandbox-mask.*dangerouslyDisableSandbox: true.*1 回だけ再実行'
assert_grep_in_section "ingest.md error table routes exit 6 to the one-shot sandbox retry" \
  "$INGEST_MD" '^## エラーハンドリング' '^---$' \
  'exit 6.*reason=sandbox-mask.*dangerouslyDisableSandbox: true.*1 回だけ再実行'

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
# The commit logic lives in wiki-lint-log-commit.sh; lint.md 8.3 only calls it. Both ends are pinned:
# the call must forward {mode} (otherwise an ingest-driven lint would push immediately), and the
# helper's --auto branch must hold --commit-only while the standalone branch must not.
assert_grep_in_section "lint.md 8.3: calls the commit helper with the lint mode and a message file" \
  "$LINT_MD" '^### 8\.3 書き込み手順' '^## ステップ 9' \
  '^bash \{plugin_root\}/hooks/scripts/wiki-lint-log-commit\.sh --branch-strategy "\{branch_strategy\}" --mode "\{mode\}" --message-file "\{wiki_lint_msg_file\}"$'
assert_grep_in_section "wiki-lint-log-commit.sh: --auto branch calls --commit-only" \
  "$LINT_COMMIT_SH" 'auto_mode" = "true" ]; then$' '^    else$' \
  'wiki-worktree-commit\.sh" --commit-only'
assert_grep_in_section "wiki-lint-log-commit.sh: standalone (non-auto) branch still commits + pushes immediately" \
  "$LINT_COMMIT_SH" '^    else$' '^    fi$' \
  'wiki-worktree-commit\.sh" --message-file "\$message_file"\)$'
assert_grep "wiki-lint-log-commit.sh: rc=6 arm exists" \
  "$LINT_COMMIT_SH" '^[[:space:]]*6\)$'
assert_grep "wiki-lint-log-commit.sh: rc=6 warns and points to the one-shot sandbox retry" \
  "$LINT_COMMIT_SH" 'reason=sandbox-mask.*dangerouslyDisableSandbox: true を付けて 1 回だけ再実行'
# Run the helper against a stubbed wiki-worktree-commit.sh: rc=6 stays non-blocking and keeps
# the message file for the one-shot retry; any other failure is non-blocking and removes it.
lint_commit_run() {
  local name="$1" stub_rc="$2" stub_out="${3-}" dir="$route_tmp/lint-$1" rc=0
  mkdir -p "$dir/scripts"
  cp "$LINT_COMMIT_SH" "$dir/scripts/wiki-lint-log-commit.sh"
  cp "$PLUGIN_ROOT/hooks/control-char-neutralize.sh" "$dir/control-char-neutralize.sh"
  # The optional stub stdout line carries the reason= the helper reads for rc=1.
  printf '#!/bin/bash\n[ -n "%s" ] && echo "%s"\necho "stub rc=%s" >&2\nexit %s\n' \
    "$stub_out" "$stub_out" "$stub_rc" "$stub_rc" > "$dir/scripts/wiki-worktree-commit.sh"
  printf 'docs(wiki): lint report\n' > "$dir/msg.txt"
  bash "$dir/scripts/wiki-lint-log-commit.sh" --branch-strategy separate_branch --mode "" \
    --message-file "$dir/msg.txt" >"$dir/out" 2>"$dir/err" || rc=$?
  assert "wiki-lint-log-commit.sh: stub rc=$stub_rc stays non-blocking" "0" "$rc"
  assert_grep "wiki-lint-log-commit.sh: stub rc=$stub_rc reaches the stub" "$dir/err" "stub rc=$stub_rc"
}
lint_commit_run mask 6
assert "wiki-lint-log-commit.sh: rc=6 keeps the message file for the retry" "1" \
  "$([ -s "$route_tmp/lint-mask/msg.txt" ] && echo 1 || echo 0)"
assert_grep "wiki-lint-log-commit.sh: rc=6 points to the one-shot sandbox retry" "$route_tmp/lint-mask/err" \
  'reason=sandbox-mask.*dangerouslyDisableSandbox: true'
# The retry re-runs only the helper with the kept file; a successful retry cleans it up.
printf '#!/bin/bash\necho "stub rc=0" >&2\nexit 0\n' > "$route_tmp/lint-mask/scripts/wiki-worktree-commit.sh"
lint_retry_rc=0
bash "$route_tmp/lint-mask/scripts/wiki-lint-log-commit.sh" --branch-strategy separate_branch --mode "" \
  --message-file "$route_tmp/lint-mask/msg.txt" >/dev/null 2>"$route_tmp/lint-mask/retry.err" || lint_retry_rc=$?
assert "wiki-lint-log-commit.sh: the retry after rc=6 succeeds" "0" "$lint_retry_rc"
assert_grep "wiki-lint-log-commit.sh: the retry reaches the stub" "$route_tmp/lint-mask/retry.err" 'stub rc=0'
assert "wiki-lint-log-commit.sh: the successful retry removes the message file" "0" \
  "$([ -e "$route_tmp/lint-mask/msg.txt" ] && echo 1 || echo 0)"
# Every other rc removes the message file. Each rc runs on its own copy, so keeping the file
# in any single arm (rc=4, the default arm, ...) fails that rc's case.
for lint_rc in 0 1 2 3 4 5; do
  lint_commit_run "rc$lint_rc" "$lint_rc"
  lint_err="$route_tmp/lint-rc$lint_rc/err"
  assert "wiki-lint-log-commit.sh: rc=$lint_rc removes the message file" "0" \
    "$([ -e "$route_tmp/lint-rc$lint_rc/msg.txt" ] && echo 1 || echo 0)"
  case "$lint_rc" in
    0) assert_not_grep "wiki-lint-log-commit.sh: rc=0 warns nothing" "$lint_err" 'WARNING' ;;
    2) assert_grep "wiki-lint-log-commit.sh: rc=2 reports the skip" "$lint_err" '\[CONTEXT\] WIKI_LINT_COMMIT=skipped' ;;
    1|3|4) assert_grep "wiki-lint-log-commit.sh: rc=$lint_rc reports its own rc" "$lint_err" "rc=$lint_rc\\)" ;;
    *) assert_grep "wiki-lint-log-commit.sh: rc=$lint_rc reaches the unexpected-rc arm" "$lint_err" "予期しない rc=$lint_rc " ;;
  esac
  assert_not_grep "wiki-lint-log-commit.sh: rc=$lint_rc does not show the sandbox retry" "$lint_err" \
    'reason=sandbox-mask'
done

# rc=1 is shared by the number-reference refusal, a failed number-reference check and
# environment / argument errors. The stdout reason= picks the cause and the remedy; only
# numref-hit points to hit lines, and a missing or look-alike reason must not claim numref.
lint_numref_case() {
  local name="$1" stub_out="$2" expected="$3" forbidden="$4" dir="$route_tmp/lint-$1"
  lint_commit_run "$name" 1 "$stub_out"
  assert "wiki-lint-log-commit.sh: rc=1 $name removes the message file" "0" \
    "$([ -e "$dir/msg.txt" ] && echo 1 || echo 0)"
  assert_grep "wiki-lint-log-commit.sh: rc=1 $name selects the expected cause" "$dir/err" "$expected"
  assert_not_grep "wiki-lint-log-commit.sh: rc=1 $name does not claim the other cause" "$dir/err" "$forbidden"
  assert_not_grep "wiki-lint-log-commit.sh: rc=1 $name does not reach the unexpected-rc arm" "$dir/err" '予期しない rc=1 '
  assert_not_grep "wiki-lint-log-commit.sh: rc=1 $name does not show the sandbox retry" "$dir/err" 'reason=sandbox-mask'
}
lint_numref_case "numref-hit" "[wiki-worktree-commit] committed=0; branch=wiki; reason=numref-hit" \
  '番号参照の commit 前検査で拒否.*(rc=1, reason=numref-hit)' '環境または引数エラー'
assert_grep "wiki-lint-log-commit.sh: rc=1 numref-hit points to the hit lines" \
  "$route_tmp/lint-numref-hit/err" '対処: 直前の hit 行が指す Wiki の番号参照を書き直して'
assert_not_grep "wiki-lint-log-commit.sh: rc=1 numref-hit does not claim a failed check" \
  "$route_tmp/lint-numref-hit/err" '完了できなかった'
lint_numref_case "numref-error" "[wiki-worktree-commit] committed=0; branch=wiki; reason=numref-error" \
  '番号参照の commit 前検査が完了できなかった.*(rc=1, reason=numref-error)' '番号参照の commit 前検査で拒否'
assert_grep "wiki-lint-log-commit.sh: rc=1 numref-error points to the check error reason" \
  "$route_tmp/lint-numref-error/err" '対処: 直前の stderr（\[CONTEXT\] WIKI_INGEST_NUMREF=error; reason= または ERROR 行）'
assert_not_grep "wiki-lint-log-commit.sh: rc=1 numref-error does not point to hit lines" \
  "$route_tmp/lint-numref-error/err" 'hit 行'
for numref_reason in numref-hit numref-error; do
  assert_grep "wiki-lint-log-commit.sh: rc=1 $numref_reason passes the stub stdout through" \
    "$route_tmp/lint-$numref_reason/out" "reason=$numref_reason\$"
done
for other_reason in reason-missing reason-lookalike; do
  case "$other_reason" in
    reason-missing) other_out="" ;;
    *) other_out="[wiki-worktree-commit] committed=0; branch=wiki; reason=numref-hit-extra" ;;
  esac
  lint_numref_case "$other_reason" "$other_out" '環境または引数エラー' '番号参照の commit 前検査'
done

# same_branch commits with git add + git-commit-file.sh. Both failures stay non-blocking,
# name their own step, and remove the message file and the stderr tempfiles.
lint_same_branch_run() {
  local name="$1" with_log="$2" dir="$route_tmp/lint-same-$1" rc=0
  mkdir -p "$dir/scripts" "$dir/repo" "$dir/tmp"
  cp "$LINT_COMMIT_SH" "$dir/scripts/wiki-lint-log-commit.sh"
  cp "$PLUGIN_ROOT/hooks/control-char-neutralize.sh" "$dir/control-char-neutralize.sh"
  printf '#!/bin/bash\necho "stub commit reached" >&2\necho "stub commit detail" >&2\nexit 1\n' > "$dir/scripts/git-commit-file.sh"
  git -C "$dir/repo" init -q
  if [ "$with_log" = yes ]; then
    mkdir -p "$dir/repo/.rite/wiki"
    printf '# log\n' > "$dir/repo/.rite/wiki/log.md"
  fi
  printf 'docs(wiki): lint report\n' > "$dir/msg.txt"
  (cd "$dir/repo" && TMPDIR="$dir/tmp" bash "$dir/scripts/wiki-lint-log-commit.sh" --branch-strategy same_branch \
    --mode "" --message-file "$dir/msg.txt") >"$dir/out" 2>"$dir/err" || rc=$?
  assert "wiki-lint-log-commit.sh: same_branch $name stays non-blocking" "0" "$rc"
  assert "wiki-lint-log-commit.sh: same_branch $name removes the message file" "0" \
    "$([ -e "$dir/msg.txt" ] && echo 1 || echo 0)"
  assert "wiki-lint-log-commit.sh: same_branch $name removes the stderr tempfiles" "0" \
    "$(find "$dir/tmp" -name 'rite-lint-*-err-*' | wc -l | tr -d '[:space:]')"
}
lint_same_branch_run add-failure no
assert_grep "wiki-lint-log-commit.sh: same_branch add-failure reports git add" \
  "$route_tmp/lint-same-add-failure/err" 'git add \.rite/wiki/log\.md に失敗'
assert_not_grep "wiki-lint-log-commit.sh: same_branch add-failure does not reach the commit" \
  "$route_tmp/lint-same-add-failure/err" 'stub commit reached'
lint_same_branch_run commit-failure yes
assert_grep "wiki-lint-log-commit.sh: same_branch commit-failure reports the commit" \
  "$route_tmp/lint-same-commit-failure/err" 'log\.md のコミットに失敗'
assert_grep "wiki-lint-log-commit.sh: same_branch commit-failure shows the commit stderr indented" \
  "$route_tmp/lint-same-commit-failure/err" '^  stub commit detail$'
assert_not_grep "wiki-lint-log-commit.sh: same_branch commit-failure does not report git add" \
  "$route_tmp/lint-same-commit-failure/err" 'git add \.rite/wiki/log\.md に失敗'

# Invocation errors (exit 2) also remove a message file that was already given. The exit 1
# fail-fast cases are pinned by commit-convention-inventory.test.sh (lint_fail_case).
lint_usage_case() {
  local name="$1" dir="$route_tmp/lint-usage-$1" rc=0
  shift
  mkdir -p "$dir"
  printf 'docs(wiki): lint report\n' > "$dir/msg.txt"
  bash "$LINT_COMMIT_SH" --message-file "$dir/msg.txt" "$@" >/dev/null 2>"$dir/err" || rc=$?
  assert "wiki-lint-log-commit.sh: $name exits 2" "2" "$rc"
  assert "wiki-lint-log-commit.sh: $name removes the message file" "0" \
    "$([ -e "$dir/msg.txt" ] && echo 1 || echo 0)"
}
lint_usage_case "missing --mode" --branch-strategy same_branch
lint_usage_case "unknown option" --branch-strategy same_branch --mode "" --no-such-option

# --- init.md ステップ 3.5.1: migration commit keeps sandbox-mask recovery actionable ---
assert_grep_in_section "init.md 3.5.1: rc=6 warns and points to the one-shot sandbox retry" \
  "$INIT_MD" '^### 3\.5\.1 ' '^## ステップ 4' \
  '^      6\) echo "WARNING: .*reason=sandbox-mask.*再試行専用 bash block.*dangerouslyDisableSandbox: true.*1 回だけ実行.*確認不要.*" >&2 ;;$'
assert_not_grep "init.md 3.5.1: rc=6 stays non-blocking (no exit 1 on the branch)" \
  "$INIT_MD" '^      6\).*exit 1'
assert_grep_in_section "init.md 3.5.1: retry guidance requires a separate Bash tool call" \
  "$INIT_MD" '^### 3\.5\.1 ' '^## ステップ 4' \
  '以下の再試行専用 block を\*\*別の Bash tool call\*\*.*dangerouslyDisableSandbox: true.*確認なしで1回だけ実行'
assert_grep_in_section "init.md 3.5.1: retry block calls the commit helper directly" \
  "$INIT_MD" '^### 3\.5\.1 ' '^## ステップ 4' \
  'retry_out=\$\(bash "\$plugin_root/hooks/scripts/wiki-worktree-commit\.sh" --message-file "\$_mig_retry_msg"\)'
assert_grep_in_section "init.md 3.5.1: second rc=6 stops without another retry" \
  "$INIT_MD" '^### 3\.5\.1 ' '^## ステップ 4' \
  '^  6\) echo "WARNING: .*retry rc=6, reason=sandbox-mask.*これ以上は再試行せず.*" >&2 ;;$'
assert_not_grep "init.md 3.5.1: retry block has no recursive sandbox retry instruction" \
  "$INIT_MD" '^  6\).*dangerouslyDisableSandbox'

print_summary "wiki-push-batch-defer-static-pin.test.sh"
