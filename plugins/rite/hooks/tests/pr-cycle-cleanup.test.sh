#!/bin/bash
# Tests for pr-cycle-cleanup.sh
# Usage: bash plugins/rite/hooks/tests/pr-cycle-cleanup.test.sh
#
# Test cases map to Acceptance Criteria:
#   T-01 → AC-1: 1 サイクル正常終了後の残置ゼロ
#   T-02 → AC-2: 複数サイクル後の残置ゼロ
#   T-03 → AC-3: 異常終了時の回復経路
#   T-04 → AC-4: 無関係ブランチの保護
#
# Per-item failure-branch coverage — the `status=failed; errors=N`
# path of each step's individual delete failure (T-10 covers only Step 3's find
# *wholesale* failure):
#   T-11 → Step 1: `git worktree remove --force` failure (locked worktree)
#   T-12 → Step 2: `git branch -D` failure (read-only refs/heads)
#   T-13 → Step 3: `rm -rf` failure (read-only orphan-workdir itself)
#   T-16 → Step 4: `git worktree remove --force || rm -rf` failure (read-only
#                  mutation-worktree itself) — extends the symmetry to the
#                  mutation-worktree reap added in Step 4
#
# Step 4 mutation worktree reaping — path-based sweep of orphan
# detached `rite-review-mutation-*` worktrees that the Step 1 branch sweep cannot
# catch (they have no named branch):
#   T-14 → Step 4: aged orphan mutation worktree reaped (mutation_worktrees=1)
#   T-15 → Step 4: age guard protects a fresh mutation worktree (in-flight safety)
#
# Each test creates an isolated temp git repository, simulates branch /
# worktree creation, runs the cleanup script, and asserts the result.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLEANUP="$SCRIPT_DIR/../scripts/pr-cycle-cleanup.sh"
PASS=0
FAIL=0
SKIP=0

if [ ! -f "$CLEANUP" ]; then
  echo "ERROR: $CLEANUP not found" >&2
  exit 1
fi

# Track all temp repos created across tests so trap can clean them on
# unexpected exit (set -e fire / SIGINT / SIGTERM / SIGHUP). Without this,
# tests that fail mid-run leave /tmp/rite-pr-cleanup-test-* orphans.
TEST_REPOS=()
_cleanup_all_test_repos() {
  local repo
  for repo in "${TEST_REPOS[@]:-}"; do
    [ -z "$repo" ] && continue
    if [ -d "$repo" ]; then
      chmod -R u+rwX "$repo" 2>/dev/null || true
      rm -rf "$repo"
    fi
  done
}
trap '_cleanup_all_test_repos' EXIT
trap '_cleanup_all_test_repos; exit 130' INT
trap '_cleanup_all_test_repos; exit 143' TERM
trap '_cleanup_all_test_repos; exit 129' HUP

# Isolate TMPDIR so the orphan-workdir GC (Step 3 of the cleanup script)
# scans an empty, test-owned directory instead of the developer's real /tmp.
# Without this, a real /tmp/rite-pr-create-* orphan on the host would make T-05
# (noop assertion) flaky and could even delete a developer's in-flight workdir.
# The workdir tests (T-06+) populate this directory explicitly. make_temp_repo
# and the standalone base mktemp calls use HOST_TMPDIR (captured BEFORE the
# export below) so test repos stay OUTSIDE the scan directory — preserving the
# isolation invariant while remaining sandbox-compatible (host tmp namespace).
HOST_TMPDIR="${TMPDIR:-/tmp}"
WORKDIR_SCAN_TMP=$(mktemp -d "$HOST_TMPDIR/rite-pr-cleanup-tmpdir-XXXXXX")
TEST_REPOS+=("$WORKDIR_SCAN_TMP")
export TMPDIR="$WORKDIR_SCAN_TMP"

# -----------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------
pass() {
  PASS=$((PASS + 1))
  echo "  ✅ PASS: $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "  ❌ FAIL: $1"
}

skip() {
  SKIP=$((SKIP + 1))
  echo "  ⏭️ SKIP: $1"
}

# T-12 / T-13 / T-16 force a delete failure via read-only permission bits
# (chmod 0500). root bypasses DAC permission checks, so the forced failure would
# not occur and the test would report a misleading FAIL. Detect root to skip
# those tests explicitly rather than emit a false failure. (T-11 uses a git
# worktree lock, which is enforced by git regardless of uid, so it is not gated.)
IS_ROOT=0
if [ "$(id -u)" = "0" ]; then IS_ROOT=1; fi

# The per-item failure tests below capture cleanup output with
# `t*_output=$( cd "$REPO" && bash "$CLEANUP" 2>&1 )`. This relies on the cleanup
# script's contract of always returning exit 0 (it reports failure via the
# `status=failed` line, not a non-zero exit — see pr-cycle-cleanup.sh `exit 0`).
# If that contract ever changes, these command substitutions would abort under
# `set -e` before the restore/assert lines; the global trap still restores perms.

# Create a fresh temp git repository with an initial commit.
# Returns the absolute path on stdout.
make_temp_repo() {
  local tmp
  tmp=$(mktemp -d "$HOST_TMPDIR/rite-pr-cleanup-test-XXXXXX")
  TEST_REPOS+=("$tmp")
  (
    cd "$tmp"
    git init --quiet --initial-branch=main
    git config user.email "test@example.com"
    git config user.name "Test"
    echo "init" > README.md
    git add README.md
    git commit --quiet -m "init"
  )
  echo "$tmp"
}

cleanup_temp_repo() {
  local repo="$1"
  if [ -n "$repo" ] && [ -d "$repo" ]; then
    chmod -R u+rwX "$repo" 2>/dev/null || true
    rm -rf "$repo"
  fi
}

# Count branches matching pr-*-cycle*
# `|| true` swallows grep's exit 1 when no matches — required under pipefail.
count_pr_cycle_branches() {
  local repo="$1"
  ( cd "$repo" && git for-each-ref --format='%(refname:short)' refs/heads/ \
    | { grep -E '^pr-[0-9]+-cycle[0-9]+$' || true; } | wc -l | tr -d ' ' )
}

# -----------------------------------------------------------------------
# T-01: 1 サイクル正常終了後の残置ゼロ
# Given: A reviewer-created worktree + branch in pr-N-cycleX form
# When: Cleanup runs after the cycle
# Then: Both the branch and worktree are removed
# -----------------------------------------------------------------------
echo "T-01: 1 サイクル正常終了後の残置ゼロ (AC-1)"
TEST_REPO=$(make_temp_repo)
(
  cd "$TEST_REPO"
  # Simulate reviewer creating a worktree with -b (the leak pattern)
  git worktree add --quiet -b pr-100-cycle1 .review-wt main >/dev/null 2>&1
)
# Run cleanup inside the test repo. NEVER run the cleanup outside the test
# repo — it would operate on the developer's actual repository and could
# delete legitimate `pr-*-cycle*` branches that exist there.
( cd "$TEST_REPO" && bash "$CLEANUP" >/dev/null 2>&1 )
remaining=$(count_pr_cycle_branches "$TEST_REPO")
if [ "$remaining" = "0" ]; then
  pass "T-01: 1 サイクル後にブランチが残らない"
else
  fail "T-01: $remaining branch(es) remaining (expected 0)"
fi
cleanup_temp_repo "$TEST_REPO"

# -----------------------------------------------------------------------
# T-02: 複数サイクル後の残置ゼロ
# Given: 3 cycles each created its own pr-N-cycleX branch + worktree
# When: Cleanup runs after the final cycle
# Then: All 3 branches are removed
# -----------------------------------------------------------------------
echo "T-02: 複数サイクル後の残置ゼロ (AC-2)"
TEST_REPO=$(make_temp_repo)
(
  cd "$TEST_REPO"
  git worktree add --quiet -b pr-200-cycle1 .wt-c1 main >/dev/null 2>&1
  git worktree add --quiet -b pr-200-cycle2 .wt-c2 main >/dev/null 2>&1
  git worktree add --quiet -b pr-200-cycle3 .wt-c3 main >/dev/null 2>&1
)
( cd "$TEST_REPO" && bash "$CLEANUP" >/dev/null 2>&1 )
remaining=$(count_pr_cycle_branches "$TEST_REPO")
if [ "$remaining" = "0" ]; then
  pass "T-02: 3 サイクル後にすべて削除された"
else
  fail "T-02: $remaining branch(es) remaining (expected 0)"
fi
cleanup_temp_repo "$TEST_REPO"

# -----------------------------------------------------------------------
# T-03: 異常終了時の回復経路
# Given: A previous cycle was interrupted, leaving a residual branch
#        (the worktree was rm -rf'd without `git worktree remove`)
# When: Cleanup runs at the next cycle start
# Then: The orphaned branch is deleted; prune handles dangling worktree metadata
# -----------------------------------------------------------------------
echo "T-03: 異常終了時の回復経路 (AC-3)"
TEST_REPO=$(make_temp_repo)
(
  cd "$TEST_REPO"
  git worktree add --quiet -b pr-300-cycle1 .wt-orphan main >/dev/null 2>&1
  # Simulate abnormal termination: directory deleted but worktree metadata + branch persist
  rm -rf .wt-orphan
)
# Capture stdout to verify the cleanup status line (asserts that `git worktree prune`
# completed successfully, which is the AC-3 核心ロジック — branch deletion alone is
# not sufficient evidence that the orphan worktree metadata was reclaimed).
t03_output=$( cd "$TEST_REPO" && bash "$CLEANUP" 2>&1 )
remaining=$(count_pr_cycle_branches "$TEST_REPO")
if [ "$remaining" = "0" ] && echo "$t03_output" | grep -q 'status=cleaned'; then
  pass "T-03: 異常終了後の orphan branch が削除され、status=cleaned が返った"
else
  fail "T-03: remaining=$remaining (expected 0), status check failed. Output: $t03_output"
fi
cleanup_temp_repo "$TEST_REPO"

# -----------------------------------------------------------------------
# T-04: 無関係ブランチの保護
# Given: User-created branches with similar-but-non-matching names exist
# When: Cleanup runs
# Then: Only branches matching the strict regex are deleted; others survive
# -----------------------------------------------------------------------
echo "T-04: 無関係ブランチの保護 (AC-4)"
TEST_REPO=$(make_temp_repo)
(
  cd "$TEST_REPO"
  # Match — should be deleted
  git branch pr-400-cycle1 main
  # Non-matches — must survive (test the regex boundary)
  git branch pr-400-cycle1-feature main           # suffix
  git branch feature/pr-400-cycle1 main           # prefix
  git branch pr-foo-cycle1 main                   # non-numeric N
  git branch pr-400-cycleA main                   # non-numeric X
  git branch pr-cycle1 main                       # missing N
  git branch user-pr-400-cycle1 main              # prefix
)
( cd "$TEST_REPO" && bash "$CLEANUP" >/dev/null 2>&1 )

# Verify the matching one is gone
matching=$(cd "$TEST_REPO" && git for-each-ref --format='%(refname:short)' refs/heads/ \
  | { grep -E '^pr-400-cycle1$' || true; } | wc -l | tr -d ' ')

# Verify the non-matching ones all survive (6 in addition to main)
survivors=$(cd "$TEST_REPO" && git for-each-ref --format='%(refname:short)' refs/heads/ \
  | { grep -v -E '^main$' || true; } | wc -l | tr -d ' ')

if [ "$matching" = "0" ] && [ "$survivors" = "6" ]; then
  pass "T-04: matching deleted, 6/6 non-matching branches survived"
else
  fail "T-04: matching=$matching (expect 0), survivors=$survivors (expect 6)"
  ( cd "$TEST_REPO" && git for-each-ref --format='%(refname:short)' refs/heads/ ) | sed 's/^/    surviving: /'
fi
cleanup_temp_repo "$TEST_REPO"

# -----------------------------------------------------------------------
# T-04b: reviewer variation branches (`pr-N-test` /
# `pr-N-experiment` / `pr-N-mutation` / `pr-N-verify` / `pr-N-check` /
# `pr-N-sandbox`) are cleaned up alongside `pr-N-cycleX`.
# Suffix variations (e.g. `pr-994-testing-suite`) must still survive.
# -----------------------------------------------------------------------
echo "T-04b: reviewer variation branches"
TEST_REPO=$(make_temp_repo)
(
  cd "$TEST_REPO"
  # Match — should be deleted (reviewer variation suffixes)
  git branch pr-994-test main
  git branch pr-995-experiment main
  git branch pr-996-mutation main
  git branch pr-997-verify main
  git branch pr-998-check main
  git branch pr-999-sandbox main
  # Non-matches — must survive
  git branch pr-994-testing-suite main             # suffix continuation
  git branch pr-994-testfile main                  # not exact-match
  git branch feature/pr-994-test main              # prefix
  git branch pr-994-experimental main              # suffix continuation
)
( cd "$TEST_REPO" && bash "$CLEANUP" >/dev/null 2>&1 )

# Verify all 6 reviewer variation branches are gone
matched_remaining=$(cd "$TEST_REPO" && git for-each-ref --format='%(refname:short)' refs/heads/ \
  | { grep -cE '^pr-99[4-9]-(test|experiment|mutation|verify|check|sandbox)$' || true; })
# Verify the 4 non-matching branches survived (+ main = 5)
survivors=$(cd "$TEST_REPO" && git for-each-ref --format='%(refname:short)' refs/heads/ \
  | { grep -v -E '^main$' || true; } | wc -l | tr -d ' ')

if [ "$matched_remaining" = "0" ] && [ "$survivors" = "4" ]; then
  pass "T-04b: 6/6 reviewer variations deleted, 4/4 non-matching branches survived"
else
  fail "T-04b: matched_remaining=$matched_remaining (expect 0), survivors=$survivors (expect 4)"
  ( cd "$TEST_REPO" && git for-each-ref --format='%(refname:short)' refs/heads/ ) | sed 's/^/    surviving: /'
fi
cleanup_temp_repo "$TEST_REPO"

# -----------------------------------------------------------------------
# T-04c: cycle 1 — worktree-loop の regex sync を独立検証
# (test-reviewer 指摘: T-04b は bare branch のみで worktree-loop の regex が
# desync しても PASS する。worktree シナリオを追加し、worktree + branch のセット leak が
# cleanup されることを確認する)
# -----------------------------------------------------------------------
echo "T-04c: reviewer variation worktrees + branches (worktree-loop regex sync)"
TEST_REPO=$(make_temp_repo)
(
  cd "$TEST_REPO"
  # Match — should be cleaned up via worktree-loop (worktree first, then branch)
  git worktree add --quiet -b pr-994-test .wt-test main >/dev/null 2>&1
  git worktree add --quiet -b pr-995-experiment .wt-exp main >/dev/null 2>&1
  git worktree add --quiet -b pr-996-cycle1 .wt-cyc main >/dev/null 2>&1
  # Non-match worktree — must survive (suffix continuation in branch name)
  git worktree add --quiet -b pr-994-experimental .wt-survive main >/dev/null 2>&1
)
( cd "$TEST_REPO" && bash "$CLEANUP" >/dev/null 2>&1 )

# Verify the 3 reviewer-variation/cycle worktrees + branches are gone
matched_wt=$(cd "$TEST_REPO" && git worktree list --porcelain 2>/dev/null \
  | { grep -E '^branch refs/heads/pr-9(94|95|96)-(test|experiment|cycle1)$' || true; } | wc -l | tr -d ' ')
matched_br=$(cd "$TEST_REPO" && git for-each-ref --format='%(refname:short)' refs/heads/ \
  | { grep -cE '^pr-9(94|95|96)-(test|experiment|cycle1)$' || true; })

# Verify the non-matching worktree + branch survived
survivor_wt=$(cd "$TEST_REPO" && git worktree list --porcelain 2>/dev/null \
  | { grep -F 'branch refs/heads/pr-994-experimental' || true; } | wc -l | tr -d ' ')

if [ "$matched_wt" = "0" ] && [ "$matched_br" = "0" ] && [ "$survivor_wt" = "1" ]; then
  pass "T-04c: 3/3 reviewer-variation worktrees+branches cleaned, 1/1 non-match worktree survived"
else
  fail "T-04c: matched_wt=$matched_wt (expect 0), matched_br=$matched_br (expect 0), survivor_wt=$survivor_wt (expect 1)"
  ( cd "$TEST_REPO" && git worktree list ) | sed 's/^/    worktree: /'
  ( cd "$TEST_REPO" && git for-each-ref --format='%(refname:short)' refs/heads/ ) | sed 's/^/    branch: /'
fi
cleanup_temp_repo "$TEST_REPO"

# -----------------------------------------------------------------------
# T-05: Idempotent — re-running on a clean repo is a no-op
# -----------------------------------------------------------------------
echo "T-05: idempotent (no-op when nothing matches)"
TEST_REPO=$(make_temp_repo)
output=$( cd "$TEST_REPO" && bash "$CLEANUP" 2>&1 )
if echo "$output" | grep -q 'status=noop'; then
  pass "T-05: noop status returned on clean repo"
else
  fail "T-05: expected status=noop, got: $output"
fi
cleanup_temp_repo "$TEST_REPO"

# -----------------------------------------------------------------------
# T-06: orphan workdir reaping
# Given: aged `rite-pr-create-*` workdirs (one empty = after-(A) orphan, one with
#        files = after-(B) orphan) older than the age threshold exist in TMPDIR
# When: Cleanup runs
# Then: Both are reaped via rm -rf and the status line reports workdirs=2
# Uses `touch -t 202001010000` (POSIX-portable, far older than 24h) to backdate
# the directory mtime AFTER writing contents (writing a file bumps the dir mtime).
# -----------------------------------------------------------------------
echo "T-06: 古い orphan workdir 回収"
rm -rf "$WORKDIR_SCAN_TMP"/rite-pr-create-* 2>/dev/null || true
mkdir -p "$WORKDIR_SCAN_TMP/rite-pr-create-old1"
echo "stale title" > "$WORKDIR_SCAN_TMP/rite-pr-create-old1/pr_title.txt"  # after-(B) orphan: has files
mkdir -p "$WORKDIR_SCAN_TMP/rite-pr-create-old2"                          # after-(A) orphan: empty
touch -t 202001010000 "$WORKDIR_SCAN_TMP/rite-pr-create-old1" "$WORKDIR_SCAN_TMP/rite-pr-create-old2"
TEST_REPO=$(make_temp_repo)
t06_output=$( cd "$TEST_REPO" && bash "$CLEANUP" 2>&1 )
if [ ! -d "$WORKDIR_SCAN_TMP/rite-pr-create-old1" ] && [ ! -d "$WORKDIR_SCAN_TMP/rite-pr-create-old2" ] \
   && echo "$t06_output" | grep -q 'status=cleaned' && echo "$t06_output" | grep -q 'workdirs=2'; then
  pass "T-06: 古い orphan workdir 2 件 (空 + 非空) が回収され workdirs=2"
else
  fail "T-06: old1=$([ -d "$WORKDIR_SCAN_TMP/rite-pr-create-old1" ] && echo present || echo gone), old2=$([ -d "$WORKDIR_SCAN_TMP/rite-pr-create-old2" ] && echo present || echo gone). Output: $t06_output"
fi
rm -rf "$WORKDIR_SCAN_TMP"/rite-pr-create-* 2>/dev/null || true
cleanup_temp_repo "$TEST_REPO"

# -----------------------------------------------------------------------
# T-07: age 未満の workdir は保護 (in-flight 誤回収防止)
# Given: a freshly-created `rite-pr-create-*` workdir (mtime = now) exists
# When: Cleanup runs
# Then: The workdir survives (age guard) and status=noop (nothing reaped)
# This is the core safety assertion: a concurrent session's in-flight workdir is
# never reaped by another session's cleanup.
# -----------------------------------------------------------------------
echo "T-07: age 未満の workdir は保護 (in-flight 誤回収防止)"
rm -rf "$WORKDIR_SCAN_TMP"/rite-pr-create-* 2>/dev/null || true
mkdir -p "$WORKDIR_SCAN_TMP/rite-pr-create-fresh"  # just created -> mtime now -> must survive
TEST_REPO=$(make_temp_repo)
t07_output=$( cd "$TEST_REPO" && bash "$CLEANUP" 2>&1 )
if [ -d "$WORKDIR_SCAN_TMP/rite-pr-create-fresh" ] && echo "$t07_output" | grep -q 'status=noop'; then
  pass "T-07: age 未満の workdir が保護され status=noop"
else
  fail "T-07: fresh=$([ -d "$WORKDIR_SCAN_TMP/rite-pr-create-fresh" ] && echo present || echo gone). Output: $t07_output"
fi
rm -rf "$WORKDIR_SCAN_TMP"/rite-pr-create-* 2>/dev/null || true
cleanup_temp_repo "$TEST_REPO"

# -----------------------------------------------------------------------
# T-08: 無関係 prefix のディレクトリは age 超過でも保護
# Given: an aged matching `rite-pr-create-victim` plus aged non-matching dirs
#        (`rite-pr-cleanup-test-*` — the test-repo prefix — and `unrelated-dir`)
# When: Cleanup runs
# Then: Only `rite-pr-create-*` is reaped; the name-glob boundary protects others
# -----------------------------------------------------------------------
echo "T-08: 無関係 prefix のディレクトリは age 超過でも保護"
rm -rf "$WORKDIR_SCAN_TMP"/rite-pr-create-* "$WORKDIR_SCAN_TMP/rite-pr-cleanup-test-xyz" "$WORKDIR_SCAN_TMP/unrelated-dir" 2>/dev/null || true
mkdir -p "$WORKDIR_SCAN_TMP/rite-pr-create-victim"      # match -> reaped
mkdir -p "$WORKDIR_SCAN_TMP/rite-pr-cleanup-test-xyz"   # different prefix -> survive
mkdir -p "$WORKDIR_SCAN_TMP/unrelated-dir"             # unrelated -> survive
touch -t 202001010000 "$WORKDIR_SCAN_TMP/rite-pr-create-victim" "$WORKDIR_SCAN_TMP/rite-pr-cleanup-test-xyz" "$WORKDIR_SCAN_TMP/unrelated-dir"
TEST_REPO=$(make_temp_repo)
( cd "$TEST_REPO" && bash "$CLEANUP" >/dev/null 2>&1 )
if [ ! -d "$WORKDIR_SCAN_TMP/rite-pr-create-victim" ] \
   && [ -d "$WORKDIR_SCAN_TMP/rite-pr-cleanup-test-xyz" ] \
   && [ -d "$WORKDIR_SCAN_TMP/unrelated-dir" ]; then
  pass "T-08: rite-pr-create-* のみ回収、無関係 prefix は保護"
else
  fail "T-08: victim=$([ -d "$WORKDIR_SCAN_TMP/rite-pr-create-victim" ] && echo present || echo gone), test-xyz=$([ -d "$WORKDIR_SCAN_TMP/rite-pr-cleanup-test-xyz" ] && echo present || echo gone), unrelated=$([ -d "$WORKDIR_SCAN_TMP/unrelated-dir" ] && echo present || echo gone)"
fi
rm -rf "$WORKDIR_SCAN_TMP"/rite-pr-create-* "$WORKDIR_SCAN_TMP/rite-pr-cleanup-test-xyz" "$WORKDIR_SCAN_TMP/unrelated-dir" 2>/dev/null || true
cleanup_temp_repo "$TEST_REPO"

# -----------------------------------------------------------------------
# T-09: --dry-run は orphan workdir を削除しない
# Given: an aged matching `rite-pr-create-*` workdir exists
# When: Cleanup runs with --dry-run
# Then: The workdir survives and a `[dry-run] would reap ...` line is printed
# -----------------------------------------------------------------------
echo "T-09: --dry-run は orphan workdir を削除しない"
rm -rf "$WORKDIR_SCAN_TMP"/rite-pr-create-* 2>/dev/null || true
mkdir -p "$WORKDIR_SCAN_TMP/rite-pr-create-dry"
touch -t 202001010000 "$WORKDIR_SCAN_TMP/rite-pr-create-dry"
TEST_REPO=$(make_temp_repo)
t09_output=$( cd "$TEST_REPO" && bash "$CLEANUP" --dry-run 2>&1 )
if [ -d "$WORKDIR_SCAN_TMP/rite-pr-create-dry" ] && echo "$t09_output" | grep -q 'would reap orphan workdir'; then
  pass "T-09: dry-run は削除せず候補をリスト"
else
  fail "T-09: dry=$([ -d "$WORKDIR_SCAN_TMP/rite-pr-create-dry" ] && echo present || echo gone). Output: $t09_output"
fi
rm -rf "$WORKDIR_SCAN_TMP"/rite-pr-create-* 2>/dev/null || true
cleanup_temp_repo "$TEST_REPO"

# -----------------------------------------------------------------------
# T-10: find wholesale 失敗が silent でない
# Given: TMPDIR は実在するが read 権限のない (0300: write+execute のみ) ディレクトリを指す
# When: Cleanup runs
# Then: find 失敗は WARNING + errors++ で surface され status=failed になる
#       (process substitution の rc 非伝播による silent no-op 化を防ぐ回帰テスト)
# 0300 は mktemp によるファイル作成 (write+execute で足りる) を許可しつつ find の readdir
# (read が必要) だけを失敗させ、mktemp の走査出力先確保と find の wholesale 失敗を分離する。
# mktemp が TMPDIR を尊重するようになった (Issue #1900) ため、旧来の「存在しないパス」技法
# では mktemp 自身も失敗し別の WARNING (走査の出力先 mktemp に失敗) に化けてしまう。
# root は DAC 権限チェックをバイパスするため本テストはスキップする。
# -----------------------------------------------------------------------
echo "T-10: find wholesale 失敗が silent でない"
if [ "$IS_ROOT" = "1" ]; then
  skip "T-10: root では perms がバイパスされ強制失敗にならないためスキップ"
else
  T10_NOREAD_BASE=$(mktemp -d "$HOST_TMPDIR/rite-pr-cleanup-noread-XXXXXX") || T10_NOREAD_BASE=""
  if [ -z "$T10_NOREAD_BASE" ]; then
    fail "T-10: mktemp -d による no-read base 作成に失敗"
  else
    TEST_REPOS+=("$T10_NOREAD_BASE")
    chmod 0300 "$T10_NOREAD_BASE"
    TEST_REPO=$(make_temp_repo)
    t10_output=$( cd "$TEST_REPO" && TMPDIR="$T10_NOREAD_BASE" bash "$CLEANUP" 2>&1 )
    chmod 0700 "$T10_NOREAD_BASE"
    if echo "$t10_output" | grep -q 'status=failed' \
       && echo "$t10_output" | grep -q 'find による orphan workdir 走査が失敗'; then
      pass "T-10: find 失敗が WARNING + status=failed で surface される (silent 化しない)"
    else
      fail "T-10: status=failed と find WARNING を期待。Output: $t10_output"
    fi
    rm -rf "$T10_NOREAD_BASE" 2>/dev/null || true
    cleanup_temp_repo "$TEST_REPO"
  fi
fi

# -----------------------------------------------------------------------
# T-11: Step 1 per-item worktree removal failure -> status=failed
# Given: a matching `pr-N-cycleX` worktree that is git-locked
# When: cleanup runs — `git worktree remove --force` uses a SINGLE --force, which
#       refuses to remove a locked worktree (`-f -f` would be required)
# Then: the per-item failure branch fires (WARNING "failed to remove worktree" +
#       errors++) -> status=failed, and the worktree survives intact
# A git lock — not chmod — is used here: chmod 0500 on the parent would let
# `git worktree remove` delete the worktree CONTENTS before failing at the final
# rmdir, leaving a half-removed tree; the lock makes the removal refuse up-front
# with the worktree fully intact, and is enforced regardless of uid. The matching
# branch stays checked out in the locked worktree, so Step 2 additionally emits a
# "failed to delete branch" WARNING — that cascade is expected; this test pins the
# Step 1 branch by asserting the worktree-specific WARNING.
# -----------------------------------------------------------------------
echo "T-11: Step 1 worktree 削除失敗で status=failed"
TEST_REPO=$(make_temp_repo)
(
  cd "$TEST_REPO"
  git worktree add --quiet -b pr-100-cycle1 .wt-locked main >/dev/null 2>&1
  git worktree lock .wt-locked
)
t11_output=$( cd "$TEST_REPO" && bash "$CLEANUP" 2>&1 )
if echo "$t11_output" | grep -q 'status=failed' \
   && echo "$t11_output" | grep -q 'failed to remove worktree' \
   && [ -d "$TEST_REPO/.wt-locked" ]; then
  pass "T-11: locked worktree の削除失敗が WARNING + status=failed で surface"
else
  fail "T-11: status=failed と worktree WARNING を期待。wt=$([ -d "$TEST_REPO/.wt-locked" ] && echo present || echo gone). Output: $t11_output"
fi
cleanup_temp_repo "$TEST_REPO"

# -----------------------------------------------------------------------
# T-12: Step 2 per-item branch deletion failure -> status=failed
# Given: a matching `pr-N-cycleX` branch whose `.git/refs/heads` is read-only
#        (chmod 0500), with NO worktree (so Step 1 is a clean no-op and only the
#        Step 2 branch was the failure source)
# When: cleanup runs
# Then: `git branch -D` cannot unlink the loose ref -> WARNING "failed to delete
#       branch" + errors++ -> status=failed, and the branch survives
# -----------------------------------------------------------------------
echo "T-12: Step 2 branch 削除失敗で status=failed"
if [ "$IS_ROOT" = "1" ]; then
  skip "T-12: root では perms がバイパスされ強制失敗にならないためスキップ"
else
  TEST_REPO=$(make_temp_repo)
  ( cd "$TEST_REPO" && git branch pr-200-cycle1 main && chmod 0500 .git/refs/heads )
  t12_output=$( cd "$TEST_REPO" && bash "$CLEANUP" 2>&1 )
  # Restore write permission so the survival check and repo cleanup can proceed.
  ( cd "$TEST_REPO" && chmod 0700 .git/refs/heads )
  t12_br=$(cd "$TEST_REPO" && git for-each-ref --format='%(refname:short)' refs/heads/ \
    | { grep -c '^pr-200-cycle1$' || true; })
  if echo "$t12_output" | grep -q 'status=failed' \
     && echo "$t12_output" | grep -q 'failed to delete branch' \
     && [ "$t12_br" = "1" ]; then
    pass "T-12: read-only refs/heads での branch -D 失敗が WARNING + status=failed で surface"
  else
    fail "T-12: status=failed と branch WARNING を期待。branch_present=$t12_br (expect 1). Output: $t12_output"
  fi
  cleanup_temp_repo "$TEST_REPO"
fi

# -----------------------------------------------------------------------
# T-13: Step 3 per-item orphan workdir reap failure -> status=failed
# Given: an aged matching `rite-pr-create-*` workdir that itself lacks write
#        permission (chmod 0500) and contains a file, so `rm -rf` cannot
#        unlink the file inside it
# When: cleanup runs with TMPDIR pointed at the (fully writable) base
#       directory containing that workdir
# Then: WARNING "failed to reap orphan workdir" + errors++ -> status=failed, and
#       the workdir survives. (T-10 covers the find *wholesale* failure; this is
#       the symmetric Step 3 gap: the per-item rm failure.)
# The base directory itself stays fully writable (mktemp -d default 0700) so
# the cleanup script's own mktemp (workdir_find_err/out) and find succeed
# normally — only the victim workdir's OWN permission blocks its removal.
# Chmod'ing the shared *base* to 0500 (as an earlier version of this test did)
# would now also break the script's own TMPDIR-respecting mktemp (Issue #1900),
# masking this per-item rm failure behind the wholesale mktemp-failure branch.
# -----------------------------------------------------------------------
echo "T-13: Step 3 orphan workdir rm 失敗で status=failed"
if [ "$IS_ROOT" = "1" ]; then
  skip "T-13: root では perms がバイパスされ強制失敗にならないためスキップ"
else
  # `|| LOCKED_BASE=""` keeps a mktemp failure from aborting the suite under
  # `set -e`: a plain `VAR=$(cmd)` propagates the command-substitution exit status
  # (unlike `local VAR=$(cmd)`, where `local` masks it), so without the `||` a
  # failed mktemp would `exit 1` here and never reach the guard below. With it,
  # LOCKED_BASE is empty on failure and the guard fails the test instead of
  # letting `mkdir -p "$LOCKED_BASE/..."` target the filesystem root
  # (`/rite-pr-create-victim`). Matches the sibling `|| var=""` convention in
  # pr-cycle-cleanup.sh.
  LOCKED_BASE=$(mktemp -d "$HOST_TMPDIR/rite-pr-cleanup-locked-XXXXXX") || LOCKED_BASE=""
  if [ -z "$LOCKED_BASE" ]; then
    fail "T-13: mktemp -d による locked base 作成に失敗"
  else
    TEST_REPOS+=("$LOCKED_BASE")
    mkdir -p "$LOCKED_BASE/rite-pr-create-victim"
    echo "blocked" > "$LOCKED_BASE/rite-pr-create-victim/blocked.txt"
    touch -t 202001010000 "$LOCKED_BASE/rite-pr-create-victim"
    chmod 0500 "$LOCKED_BASE/rite-pr-create-victim"
    TEST_REPO=$(make_temp_repo)
    t13_output=$( cd "$TEST_REPO" && TMPDIR="$LOCKED_BASE" bash "$CLEANUP" 2>&1 )
    # Restore write permission so the survival check and cleanup can proceed.
    chmod 0700 "$LOCKED_BASE/rite-pr-create-victim"
    if echo "$t13_output" | grep -q 'status=failed' \
       && echo "$t13_output" | grep -q 'failed to reap orphan workdir' \
       && [ -d "$LOCKED_BASE/rite-pr-create-victim" ]; then
      pass "T-13: read-only workdir 自身での rm 失敗が WARNING + status=failed で surface"
    else
      fail "T-13: status=failed と reap WARNING を期待。victim=$([ -d "$LOCKED_BASE/rite-pr-create-victim" ] && echo present || echo gone). Output: $t13_output"
    fi
    rm -rf "$LOCKED_BASE" 2>/dev/null || true
    cleanup_temp_repo "$TEST_REPO"
  fi
fi

# -----------------------------------------------------------------------
# T-14: orphan mutation worktree reaping
# Given: an aged registered detached `rite-review-mutation-*` worktree (created
#        via `git worktree add --detach`, mirroring _reviewer-base.md's
#        worktree-only mutation pattern) older than the age threshold in TMPDIR
# When: Cleanup runs from the owning repo
# Then: It is reaped via `git worktree remove --force` and the status line
#       reports mutation_worktrees=1 / status=cleaned, and the worktree is
#       deregistered (git worktree list no longer shows it).
# These detached worktrees have no named branch, so the Step 1 branch sweep
# cannot catch them — this asserts the path-based Step 4 sweep.
# -----------------------------------------------------------------------
echo "T-14: 古い orphan mutation worktree 回収"
rm -rf "$WORKDIR_SCAN_TMP"/rite-review-mutation-* 2>/dev/null || true
TEST_REPO=$(make_temp_repo)
( cd "$TEST_REPO" && git worktree add --detach -q "$WORKDIR_SCAN_TMP/rite-review-mutation-old" HEAD )
touch -t 202001010000 "$WORKDIR_SCAN_TMP/rite-review-mutation-old"
t14_output=$( cd "$TEST_REPO" && bash "$CLEANUP" 2>&1 )
t14_registered=$( cd "$TEST_REPO" && git worktree list | { grep -c 'rite-review-mutation-old' || true; } )
if [ ! -e "$WORKDIR_SCAN_TMP/rite-review-mutation-old" ] \
   && echo "$t14_output" | grep -q 'status=cleaned' \
   && echo "$t14_output" | grep -q 'mutation_worktrees=1' \
   && [ "$t14_registered" = "0" ]; then
  pass "T-14: 古い orphan mutation worktree が回収され mutation_worktrees=1 + deregistered"
else
  fail "T-14: dir=$([ -e "$WORKDIR_SCAN_TMP/rite-review-mutation-old" ] && echo present || echo gone), registered=$t14_registered. Output: $t14_output"
fi
rm -rf "$WORKDIR_SCAN_TMP"/rite-review-mutation-* 2>/dev/null || true
cleanup_temp_repo "$TEST_REPO"

# -----------------------------------------------------------------------
# T-15: fresh detached TMPDIR worktree は Step 4-P (porcelain) で即回収 (Issue #2145)
# Given: a freshly-created registered detached worktree under TMPDIR (mtime now)
# When: Cleanup runs
# Then: The worktree is reaped (porcelain path has no 24h age guard) and
#       mutation_worktrees >= 1. In-flight protection is self-exclusion via
#       worktree-foreign-cwd (別 live セッション), not age — cleanup only runs at
#       review entry / iterate end, never mid-parallel-review.
# -----------------------------------------------------------------------
echo "T-15: fresh detached TMPDIR worktree は Step 4-P で即回収 (Issue #2145)"
rm -rf "$WORKDIR_SCAN_TMP"/rite-review-mutation-* 2>/dev/null || true
TEST_REPO=$(make_temp_repo)
( cd "$TEST_REPO" && git worktree add --detach -q "$WORKDIR_SCAN_TMP/rite-review-mutation-fresh" HEAD )
t15_output=$( cd "$TEST_REPO" && bash "$CLEANUP" 2>&1 )
t15_mut=$(echo "$t15_output" | sed -n 's/.*mutation_worktrees=\([0-9]*\).*/\1/p' | head -1)
if [ ! -e "$WORKDIR_SCAN_TMP/rite-review-mutation-fresh" ] \
   && [ "${t15_mut:-0}" -ge 1 ] 2>/dev/null; then
  pass "T-15: fresh detached TMPDIR worktree が Step 4-P で回収され mutation_worktrees=$t15_mut"
else
  fail "T-15: fresh=$([ -e "$WORKDIR_SCAN_TMP/rite-review-mutation-fresh" ] && echo present || echo gone) mut=$t15_mut. Output: $t15_output"
fi
( cd "$TEST_REPO" && git worktree remove --force "$WORKDIR_SCAN_TMP/rite-review-mutation-fresh" 2>/dev/null ) || true
rm -rf "$WORKDIR_SCAN_TMP"/rite-review-mutation-* 2>/dev/null || true
cleanup_temp_repo "$TEST_REPO"

# -----------------------------------------------------------------------
# T-16: Step 4 per-item mutation worktree reap failure -> status=failed
# Given: an aged registered detached `rite-review-mutation-*` worktree (as in T-14)
#        that itself lacks write permission (chmod 0500), so neither
#        `git worktree remove --force` nor the `rm -rf` fallback can delete
#        its contents (the `.git` file / checked-out files inside it)
# When: cleanup runs with TMPDIR pointed at the (fully writable) base
#       directory containing that worktree
# Then: WARNING "failed to reap orphan mutation worktree" + errors++ -> status=failed,
#       mutation_worktrees=0 (nothing reaped), and the worktree directory survives.
#       This is the Step 4 analogue of T-13's Step 3 gap: Step 1/2/3 pin per-item
#       delete failures (T-11/T-12/T-13); Step 4's mutation reap was the missing
#       symmetric case.
# The base directory itself stays fully writable (mktemp -d default 0700) so
# the cleanup script's own mktemp (mutation_find_err/out) and find succeed
# normally — only the victim worktree's OWN permission blocks its removal.
# Chmod'ing the shared *base* to 0500 (as an earlier version of this test did)
# would now also break the script's own TMPDIR-respecting mktemp (Issue #1900),
# masking this per-item reap failure behind the wholesale mktemp-failure branch.
# -----------------------------------------------------------------------
echo "T-16: Step 4 mutation worktree reap 失敗で status=failed"
if [ "$IS_ROOT" = "1" ]; then
  skip "T-16: root では perms がバイパスされ強制失敗にならないためスキップ"
else
  # `|| LOCKED_BASE=""` — see T-13's note: a plain `VAR=$(cmd)` propagates the
  # command-substitution exit status under `set -e`, so the `||` keeps a failed
  # mktemp from aborting the suite and lets the guard fail this test instead.
  LOCKED_BASE=$(mktemp -d "$HOST_TMPDIR/rite-pr-cleanup-mut-locked-XXXXXX") || LOCKED_BASE=""
  if [ -z "$LOCKED_BASE" ]; then
    fail "T-16: mktemp -d による locked base 作成に失敗"
  else
    TEST_REPOS+=("$LOCKED_BASE")
    TEST_REPO=$(make_temp_repo)
    # Register the detached mutation worktree inside the base BEFORE locking it.
    ( cd "$TEST_REPO" && git worktree add --detach -q "$LOCKED_BASE/rite-review-mutation-victim" HEAD )
    touch -t 202001010000 "$LOCKED_BASE/rite-review-mutation-victim"
    chmod 0500 "$LOCKED_BASE/rite-review-mutation-victim"
    t16_output=$( cd "$TEST_REPO" && TMPDIR="$LOCKED_BASE" bash "$CLEANUP" 2>&1 )
    # Restore write permission so the survival check and cleanup can proceed.
    chmod 0700 "$LOCKED_BASE/rite-review-mutation-victim"
    if echo "$t16_output" | grep -q 'status=failed' \
       && echo "$t16_output" | grep -q 'mutation_worktrees=0' \
       && echo "$t16_output" | grep -q 'failed to reap orphan mutation worktree' \
       && [ -d "$LOCKED_BASE/rite-review-mutation-victim" ]; then
      pass "T-16: read-only worktree 自身での reap 失敗が WARNING + status=failed (mutation_worktrees=0) で surface"
    else
      fail "T-16: status=failed と reap WARNING を期待。victim=$([ -d "$LOCKED_BASE/rite-review-mutation-victim" ] && echo present || echo gone). Output: $t16_output"
    fi
    ( cd "$TEST_REPO" && git worktree remove --force "$LOCKED_BASE/rite-review-mutation-victim" 2>/dev/null ) || true
    rm -rf "$LOCKED_BASE" 2>/dev/null || true
    cleanup_temp_repo "$TEST_REPO"
  fi
fi

# -----------------------------------------------------------------------
# T-17: Step 3 newline-in-name workdir is reaped as a single entry
# Given: an aged `rite-pr-create-*` workdir whose directory name contains an
#        embedded newline (the pathological case the find -print0 migration targets)
# When: cleanup runs
# Then: the workdir is reaped (status=cleaned, workdirs=1) and the directory is gone.
# Regression intent: under the prior `find | while IFS= read -r` + here-string code,
# the newline split the single path into two non-existent partial paths, so `rm -rf`
# no-op'd on both (rm -f ignores missing) — the real dir survived while workdirs was
# miscounted. The `find -print0` + `read -r -d ''` migration reads the whole path as
# one NUL-delimited entry, so the real dir is removed and counted once.
# -----------------------------------------------------------------------
echo "T-17: Step 3 改行入り名の workdir が単一エントリで回収される"
rm -rf "$WORKDIR_SCAN_TMP"/rite-pr-create-* 2>/dev/null || true
# ANSI-C quoting ($'\n') で **literal 改行** を埋め込む。`$(printf '\n')` は command
# substitution の末尾改行ストリップで改行が消え、テストが病的入力を生成しない false
# positive (改行を含まない入力では欠陥のある実装でも PASS してしまう) になるため使わない。
t17_nl_name="rite-pr-create-nl"$'\n'"evil"
# 前提条件 self-check: フィクスチャ名が本当に改行を含むことを固定する。将来 $'\n' が
# 誤って書き換えられても、この guard が「病的入力を生成していない」状態を即座に検出する。
# 注: `case ... in *"$(printf '\n')"*` は command substitution の改行ストリップで pattern が
# 空になり常時マッチする欠陥があるため使わない。tr+wc で改行バイト数を直接数える。
t17_nl_count=$(printf '%s' "$t17_nl_name" | tr -dc '\n' | wc -c | tr -d '[:space:]')
if [ "$t17_nl_count" -lt 1 ]; then
  fail "T-17: フィクスチャ名に改行が含まれていません (テスト前提崩壊、nl_count=$t17_nl_count)"
  t17_nl_name=""
fi
if [ -n "$t17_nl_name" ]; then
  mkdir -p "$WORKDIR_SCAN_TMP/$t17_nl_name"
  touch -t 202001010000 "$WORKDIR_SCAN_TMP/$t17_nl_name"
  TEST_REPO=$(make_temp_repo)
  t17_output=$( cd "$TEST_REPO" && bash "$CLEANUP" 2>&1 )
  if [ ! -d "$WORKDIR_SCAN_TMP/$t17_nl_name" ] \
     && echo "$t17_output" | grep -q 'status=cleaned' \
     && echo "$t17_output" | grep -q 'workdirs=1'; then
    pass "T-17: 改行入り名の workdir が単一エントリとして回収され workdirs=1"
  else
    fail "T-17: dir=$([ -d "$WORKDIR_SCAN_TMP/$t17_nl_name" ] && echo present || echo gone) を期待 gone / workdirs=1。Output: $t17_output"
  fi
  rm -rf "$WORKDIR_SCAN_TMP"/rite-pr-create-* 2>/dev/null || true
  cleanup_temp_repo "$TEST_REPO"
fi

# =======================================================================
# Issue #1526 — name-independent reap (bare pr-N / revert-test / manifest).
# IDs below map to Issue #1526 §6 Test Specification:
#   T-18 → Issue T-01 / AC-1: bare `pr-{N}` branch reaped
#   T-19 → Issue T-03 / AC-3: near-miss branches survive (bare pattern is exact)
#   T-20 → Issue T-02 / AC-2: aged `rite-revert-test-*` worktree reaped
#   T-21 → Issue T-07 / AC-1: `pr-{N}-cycle{X}` regression still reaped
#   T-22 → Issue T-04 / AC-4: manifest unknown-named branch reaped (name-independent)
#   T-23 → Issue T-04 / AC-4: manifest worktree reaped + manifest emptied
#   T-24 → Issue T-06 / AC-6: dirty manifest worktree skipped + kept in manifest
#   T-25 → Issue T-03 / AC-3: non-recorded weird branch survives (誤削除防止)
#   T-26 → Issue T-05 / AC-5: manifest branch reap FAILURE → status=failed, exit 0
#   T-27 → Issue T-06 / AC-6: manifest worktree pointing at a non-git path is
#          skipped WITHOUT aborting the run (regression for the set -e rc-capture fix)
#   T-28 → Issue T-04 / AC-4: stale manifest entry (branch already gone) is dropped
#   T-29 → Issue #1945: rite-tmp-artifact.sh `session_worktree` type round-trip
#          (helper writes the manifest line for an absolute path, rejects a
#          relative one) — the reap-side behavior for this type is covered by
#          pr-cycle-cleanup-session-reap.test.sh's C-05/C-05b/C-05c/C-05d/C-06;
#          this test covers the producer (recorder) side only.
# (Steps 1-4 non-blocking failure paths are covered by T-10..T-16; T-26 adds the
#  same contract for the new Step 4.5 manifest reap. Issue T-06 session-worktree
#  protection by the gated Step 5 reap lives in pr-cycle-cleanup-session-reap.test.sh.)
# -----------------------------------------------------------------------
ARTIFACT_HELPER="$SCRIPT_DIR/../scripts/rite-tmp-artifact.sh"

# T-18: bare `pr-{N}` branch reaped (AC-1)
echo "T-18: bare pr-{N} ブランチ回収 (AC-1)"
TEST_REPO=$(make_temp_repo)
( cd "$TEST_REPO" && git branch pr-2024 >/dev/null 2>&1 )
t18_output=$( cd "$TEST_REPO" && bash "$CLEANUP" 2>&1 )
t18_remaining=$( cd "$TEST_REPO" && git for-each-ref --format='%(refname:short)' refs/heads/ | { grep -cx 'pr-2024' || true; } )
if [ "$t18_remaining" = "0" ] && echo "$t18_output" | grep -q 'status=cleaned'; then
  pass "T-18: bare pr-2024 が削除された"
else
  fail "T-18: remaining=$t18_remaining. Output: $t18_output"
fi
cleanup_temp_repo "$TEST_REPO"

# T-19: near-miss branches are NOT deleted by the bare/suffix patterns (AC-3 boundary)
echo "T-19: near-miss ブランチ保護 (AC-3)"
TEST_REPO=$(make_temp_repo)
(
  cd "$TEST_REPO"
  # None of these match `^pr-[0-9]+$` or the suffixed PATTERN.
  git branch pr-100-feature >/dev/null 2>&1   # suffix not in allowed set
  git branch pr-fix >/dev/null 2>&1           # not all-digits after pr-
  git branch my-pr-123 >/dev/null 2>&1        # not anchored at start
  git branch develop >/dev/null 2>&1
)
( cd "$TEST_REPO" && bash "$CLEANUP" >/dev/null 2>&1 )
t19_survivors=$( cd "$TEST_REPO" && git for-each-ref --format='%(refname:short)' refs/heads/ \
  | { grep -Exc 'pr-100-feature|pr-fix|my-pr-123|develop' || true; } )
if [ "$t19_survivors" = "4" ]; then
  pass "T-19: near-miss ブランチ 4 件すべて保護された"
else
  fail "T-19: survivors=$t19_survivors (expected 4)"
fi
cleanup_temp_repo "$TEST_REPO"

# T-20: aged `rite-revert-test-*` detached worktree reaped (AC-2)
echo "T-20: 古い orphan revert-test worktree 回収 (AC-2)"
rm -rf "$WORKDIR_SCAN_TMP"/rite-revert-test-* 2>/dev/null || true
TEST_REPO=$(make_temp_repo)
( cd "$TEST_REPO" && git worktree add --detach -q "$WORKDIR_SCAN_TMP/rite-revert-test-old" HEAD )
touch -t 202001010000 "$WORKDIR_SCAN_TMP/rite-revert-test-old"
t20_output=$( cd "$TEST_REPO" && bash "$CLEANUP" 2>&1 )
t20_registered=$( cd "$TEST_REPO" && git worktree list | { grep -c 'rite-revert-test-old' || true; } )
if [ ! -e "$WORKDIR_SCAN_TMP/rite-revert-test-old" ] \
   && echo "$t20_output" | grep -q 'status=cleaned' \
   && echo "$t20_output" | grep -q 'mutation_worktrees=1' \
   && [ "$t20_registered" = "0" ]; then
  pass "T-20: 古い revert-test worktree が回収され mutation_worktrees=1 + deregistered"
else
  fail "T-20: dir=$([ -e "$WORKDIR_SCAN_TMP/rite-revert-test-old" ] && echo present || echo gone), registered=$t20_registered. Output: $t20_output"
fi
rm -rf "$WORKDIR_SCAN_TMP"/rite-revert-test-* 2>/dev/null || true
cleanup_temp_repo "$TEST_REPO"

# T-21: `pr-{N}-cycle{X}` regression — still reaped alongside the new patterns (AC-1)
echo "T-21: pr-{N}-cycle{X} 回収の非退行 (AC-1)"
TEST_REPO=$(make_temp_repo)
( cd "$TEST_REPO" && git worktree add --quiet -b pr-777-cycle3 .review-wt main >/dev/null 2>&1 )
( cd "$TEST_REPO" && bash "$CLEANUP" >/dev/null 2>&1 )
t21_remaining=$(count_pr_cycle_branches "$TEST_REPO")
if [ "$t21_remaining" = "0" ]; then
  pass "T-21: pr-777-cycle3 が引き続き回収される"
else
  fail "T-21: $t21_remaining branch(es) remaining (expected 0)"
fi
cleanup_temp_repo "$TEST_REPO"

# T-22: manifest-recorded unknown-named branch reaped name-independently (AC-4)
echo "T-22: マニフェスト記録の未知命名ブランチ回収 (AC-4)"
TEST_REPO=$(make_temp_repo)
(
  cd "$TEST_REPO"
  # A name no strict pattern would ever match.
  git branch zztmp-experiment-42 >/dev/null 2>&1
  bash "$ARTIFACT_HELPER" record --type branch --id "zztmp-experiment-42" >/dev/null 2>&1
)
t22_output=$( cd "$TEST_REPO" && bash "$CLEANUP" 2>&1 )
t22_remaining=$( cd "$TEST_REPO" && git for-each-ref --format='%(refname:short)' refs/heads/ | { grep -cx 'zztmp-experiment-42' || true; } )
t22_manifest_gone=$([ ! -f "$TEST_REPO/.rite/tmp-artifacts.tsv" ] && echo yes || echo no)
if [ "$t22_remaining" = "0" ] \
   && echo "$t22_output" | grep -q 'status=cleaned' \
   && echo "$t22_output" | grep -q 'manifest=1' \
   && [ "$t22_manifest_gone" = "yes" ]; then
  pass "T-22: 未知命名ブランチが manifest 経由で回収され manifest=1 + 空 manifest 削除"
else
  fail "T-22: remaining=$t22_remaining, manifest_gone=$t22_manifest_gone. Output: $t22_output"
fi
cleanup_temp_repo "$TEST_REPO"

# T-23: manifest-recorded worktree reaped (AC-4)
echo "T-23: マニフェスト記録の worktree 回収 (AC-4)"
rm -rf "$WORKDIR_SCAN_TMP"/mf-wt-* 2>/dev/null || true
TEST_REPO=$(make_temp_repo)
(
  cd "$TEST_REPO"
  git worktree add --detach -q "$WORKDIR_SCAN_TMP/mf-wt-clean" HEAD
  bash "$ARTIFACT_HELPER" record --type worktree --id "$WORKDIR_SCAN_TMP/mf-wt-clean" >/dev/null 2>&1
)
t23_output=$( cd "$TEST_REPO" && bash "$CLEANUP" 2>&1 )
t23_registered=$( cd "$TEST_REPO" && git worktree list | { grep -c 'mf-wt-clean' || true; } )
if [ ! -e "$WORKDIR_SCAN_TMP/mf-wt-clean" ] \
   && echo "$t23_output" | grep -q 'manifest=1' \
   && [ "$t23_registered" = "0" ]; then
  pass "T-23: manifest 記録の worktree が回収され manifest=1 + deregistered"
else
  fail "T-23: dir=$([ -e "$WORKDIR_SCAN_TMP/mf-wt-clean" ] && echo present || echo gone), registered=$t23_registered. Output: $t23_output"
fi
rm -rf "$WORKDIR_SCAN_TMP"/mf-wt-* 2>/dev/null || true
cleanup_temp_repo "$TEST_REPO"

# T-24: dirty manifest worktree is skipped + kept in manifest (AC-6 / Step 4.5)
# Path is under TEST_REPO (not TMPDIR) so Step 4-P porcelain sweep does not
# reap it first — Issue #2158 made dirty TMPDIR detached worktrees reaped by
# Step 4-P, which would otherwise collapse this Step 4.5-only assertion.
echo "T-24: dirty な manifest worktree は保護 + manifest 保持 (AC-6)"
TEST_REPO=$(make_temp_repo)
t24_wt="$TEST_REPO/mf-wt-dirty"
(
  cd "$TEST_REPO"
  git worktree add --detach -q "$t24_wt" HEAD
  echo "uncommitted" > "$t24_wt/scratch.txt"   # untracked → dirty
  bash "$ARTIFACT_HELPER" record --type worktree --id "$t24_wt" >/dev/null 2>&1
)
t24_output=$( cd "$TEST_REPO" && bash "$CLEANUP" 2>&1 )
t24_kept=$( { grep -c 'mf-wt-dirty' "$TEST_REPO/.rite/tmp-artifacts.tsv" 2>/dev/null || true; } )
if [ -e "$t24_wt" ] \
   && echo "$t24_output" | grep -q 'manifest=0' \
   && [ "$t24_kept" = "1" ]; then
  pass "T-24: dirty worktree は reap されず manifest=0 + manifest にエントリ保持"
else
  fail "T-24: dir=$([ -e "$t24_wt" ] && echo present || echo gone), kept=$t24_kept. Output: $t24_output"
fi
( cd "$TEST_REPO" && git worktree remove --force "$t24_wt" 2>/dev/null ) || true
cleanup_temp_repo "$TEST_REPO"

# T-25: a non-recorded weird-named branch survives (誤削除防止 — manifest reaps only recorded) (AC-3)
echo "T-25: 未記録の未知命名ブランチは保護 (AC-3)"
TEST_REPO=$(make_temp_repo)
( cd "$TEST_REPO" && git branch zztmp-not-recorded >/dev/null 2>&1 )   # weird name, NOT in manifest
( cd "$TEST_REPO" && bash "$CLEANUP" >/dev/null 2>&1 )
t25_survives=$( cd "$TEST_REPO" && git for-each-ref --format='%(refname:short)' refs/heads/ | { grep -cx 'zztmp-not-recorded' || true; } )
if [ "$t25_survives" = "1" ]; then
  pass "T-25: 未記録の未知命名ブランチは削除されず保護された"
else
  fail "T-25: survives=$t25_survives (expected 1)"
fi
cleanup_temp_repo "$TEST_REPO"

# T-26: manifest branch reap FAILURE surfaces as status=failed + exit 0 (AC-5)
# Force `git branch -D` to fail by making refs/heads read-only (same technique as
# T-12). root bypasses DAC perms, so skip under root to avoid a false failure.
echo "T-26: manifest branch reap 失敗が status=failed + exit 0 (AC-5)"
if [ "$IS_ROOT" = "1" ]; then
  skip "T-26: root では refs/heads read-only による削除失敗を再現できない"
else
  TEST_REPO=$(make_temp_repo)
  (
    cd "$TEST_REPO"
    git branch zztmp-reap-fail >/dev/null 2>&1
    bash "$ARTIFACT_HELPER" record --type branch --id "zztmp-reap-fail" >/dev/null 2>&1
    chmod 0500 .git/refs/heads
  )
  t26_output=$( cd "$TEST_REPO" && bash "$CLEANUP" 2>&1 ); t26_rc=$?
  ( cd "$TEST_REPO" && chmod 0700 .git/refs/heads )   # restore so cleanup_temp_repo can rm
  t26_kept=$( { grep -c 'zztmp-reap-fail' "$TEST_REPO/.rite/tmp-artifacts.tsv" 2>/dev/null || true; } )
  if echo "$t26_output" | grep -q 'status=failed' \
     && echo "$t26_output" | grep -q 'manifest=0' \
     && [ "$t26_rc" = "0" ] \
     && [ "$t26_kept" = "1" ]; then
    pass "T-26: 削除失敗が WARNING + status=failed + manifest=0 + exit 0、entry は manifest に保持"
  else
    fail "T-26: rc=$t26_rc, kept=$t26_kept. Output: $t26_output"
  fi
  cleanup_temp_repo "$TEST_REPO"
fi

# T-27: manifest worktree pointing at a NON-git path is skipped without aborting.
# Regression for the `set -e` rc-capture fix: a bare `var=$(git -C ... status)`
# would abort the whole run at git rc=128, never reaching the status line.
echo "T-27: 非 git path の manifest worktree は abort せず skip (AC-6 / set -e 回帰)"
rm -rf "$WORKDIR_SCAN_TMP"/mf-nongit-* 2>/dev/null || true
TEST_REPO=$(make_temp_repo)
mkdir -p "$WORKDIR_SCAN_TMP/mf-nongit-dir"   # exists but is NOT a git worktree
( cd "$TEST_REPO" && bash "$ARTIFACT_HELPER" record --type worktree --id "$WORKDIR_SCAN_TMP/mf-nongit-dir" >/dev/null 2>&1 )
t27_output=$( cd "$TEST_REPO" && bash "$CLEANUP" 2>&1 ); t27_rc=$?
t27_kept=$( { grep -c 'mf-nongit-dir' "$TEST_REPO/.rite/tmp-artifacts.tsv" 2>/dev/null || true; } )
if [ "$t27_rc" = "0" ] \
   && echo "$t27_output" | grep -q '\[pr-cycle-cleanup\] status=' \
   && [ -d "$WORKDIR_SCAN_TMP/mf-nongit-dir" ] \
   && [ "$t27_kept" = "1" ]; then
  pass "T-27: 非 git path は abort せず status 行に到達 + skip + manifest 保持 + dir 保護"
else
  fail "T-27: rc=$t27_rc, kept=$t27_kept, dir=$([ -d "$WORKDIR_SCAN_TMP/mf-nongit-dir" ] && echo present || echo gone). Output: $t27_output"
fi
rm -rf "$WORKDIR_SCAN_TMP"/mf-nongit-* 2>/dev/null || true
cleanup_temp_repo "$TEST_REPO"

# T-28: a stale manifest entry (branch already deleted) is dropped without error (AC-4)
echo "T-28: stale manifest エントリ (branch 既削除) は無害に drop (AC-4)"
TEST_REPO=$(make_temp_repo)
(
  cd "$TEST_REPO"
  git branch zztmp-stale >/dev/null 2>&1
  bash "$ARTIFACT_HELPER" record --type branch --id "zztmp-stale" >/dev/null 2>&1
  git branch -D zztmp-stale >/dev/null 2>&1   # gone before cleanup runs
)
t28_output=$( cd "$TEST_REPO" && bash "$CLEANUP" 2>&1 ); t28_rc=$?
t28_manifest_gone=$([ ! -f "$TEST_REPO/.rite/tmp-artifacts.tsv" ] && echo yes || echo no)
if [ "$t28_rc" = "0" ] \
   && ! echo "$t28_output" | grep -q 'status=failed' \
   && echo "$t28_output" | grep -q 'manifest=0' \
   && [ "$t28_manifest_gone" = "yes" ]; then
  pass "T-28: stale エントリは status≠failed + manifest=0 + 空 manifest 削除で drop"
else
  fail "T-28: rc=$t28_rc, manifest_gone=$t28_manifest_gone. Output: $t28_output"
fi
cleanup_temp_repo "$TEST_REPO"

# T-29: rite-tmp-artifact.sh `session_worktree` type round-trip (Issue #1945, producer side)
echo "T-29: rite-tmp-artifact.sh session_worktree type の記録・バリデーション (Issue #1945)"
TEST_REPO=$(make_temp_repo)
t29_abs_id="$TEST_REPO/.rite/worktrees/issue-t29"
(
  cd "$TEST_REPO"
  bash "$ARTIFACT_HELPER" record --type session_worktree --id "$t29_abs_id" >/dev/null 2>&1
)
t29_recorded=$(grep -qxF "session_worktree$(printf '\t')$t29_abs_id" "$TEST_REPO/.rite/tmp-artifacts.tsv" 2>/dev/null && echo yes || echo no)
t29_rel_rc=0
( cd "$TEST_REPO" && bash "$ARTIFACT_HELPER" record --type session_worktree --id "relative/path" >/dev/null 2>&1 ) || t29_rel_rc=$?
if [ "$t29_recorded" = "yes" ] && [ "$t29_rel_rc" -ne 0 ]; then
  pass "T-29: session_worktree type は絶対パスで manifest に記録され、相対パスは拒否される (rc=$t29_rel_rc)"
else
  fail "T-29: recorded=$t29_recorded, rel_rc=$t29_rel_rc"
fi
cleanup_temp_repo "$TEST_REPO"

# -----------------------------------------------------------------------
# T-30: Step 4-P porcelain — 2 fresh detached under nested TMPDIR (AC-1 / Issue #2145)
# Given: two detached worktrees at $TMPDIR/nested/probe-{1,2} (NOT the name pattern
#        find-based Step 4 looks for; nested so maxdepth-1 find cannot see them)
# When: Cleanup runs
# Then: both gone, mutation_worktrees=2
# -----------------------------------------------------------------------
echo "T-30: Step 4-P porcelain が nested TMPDIR の fresh detached を 2 件回収 (AC-1)"
TEST_REPO=$(make_temp_repo)
t30_nest="$WORKDIR_SCAN_TMP/nested-claude"
mkdir -p "$t30_nest"
( cd "$TEST_REPO" && git worktree add --detach -q "$t30_nest/probe-1" HEAD )
( cd "$TEST_REPO" && git worktree add --detach -q "$t30_nest/probe-2" HEAD )
t30_output=$( cd "$TEST_REPO" && bash "$CLEANUP" 2>&1 )
t30_mut=$(echo "$t30_output" | sed -n 's/.*mutation_worktrees=\([0-9]*\).*/\1/p' | head -1)
if [ ! -e "$t30_nest/probe-1" ] && [ ! -e "$t30_nest/probe-2" ] \
   && [ "${t30_mut:-0}" -eq 2 ] 2>/dev/null; then
  pass "T-30: nested detached 2 件が回収され mutation_worktrees=2"
else
  fail "T-30: p1=$([ -e "$t30_nest/probe-1" ] && echo present || echo gone) p2=$([ -e "$t30_nest/probe-2" ] && echo present || echo gone) mut=$t30_mut. Output: $t30_output"
fi
( cd "$TEST_REPO" && git worktree remove --force "$t30_nest/probe-1" 2>/dev/null ) || true
( cd "$TEST_REPO" && git worktree remove --force "$t30_nest/probe-2" 2>/dev/null ) || true
rm -rf "$t30_nest"
cleanup_temp_repo "$TEST_REPO"

# -----------------------------------------------------------------------
# T-31: Step 4-P does NOT reap .rite/worktrees/* (AC-2 / Issue #2145)
# Given: a detached worktree under $TEST_REPO/.rite/worktrees/issue-N (session path shape)
# When: Cleanup runs
# Then: the worktree remains (repo-root exclusion)
# -----------------------------------------------------------------------
echo "T-31: Step 4-P は .rite/worktrees/* を回収しない (AC-2)"
TEST_REPO=$(make_temp_repo)
t31_wt="$TEST_REPO/.rite/worktrees/issue-t31"
mkdir -p "$(dirname "$t31_wt")"
( cd "$TEST_REPO" && git worktree add --detach -q "$t31_wt" HEAD )
t31_output=$( cd "$TEST_REPO" && bash "$CLEANUP" 2>&1 )
if [ -d "$t31_wt" ]; then
  pass "T-31: .rite/worktrees/issue-t31 が残存"
else
  fail "T-31: session-shaped worktree が消えた. Output: $t31_output"
fi
( cd "$TEST_REPO" && git worktree remove --force "$t31_wt" 2>/dev/null ) || true
cleanup_temp_repo "$TEST_REPO"

# -----------------------------------------------------------------------
# T-32: Step 4-P 対象 0 件 → mutation_worktrees=0 と status=noop 両立 (AC-3)
# -----------------------------------------------------------------------
echo "T-32: Step 4-P 対象 0 件で mutation_worktrees=0 + status=noop (AC-3)"
TEST_REPO=$(make_temp_repo)
t32_output=$( cd "$TEST_REPO" && bash "$CLEANUP" 2>&1 )
if echo "$t32_output" | grep -q 'status=noop' \
   && echo "$t32_output" | grep -q 'mutation_worktrees=0'; then
  pass "T-32: 対象 0 件で status=noop / mutation_worktrees=0"
else
  fail "T-32: Output: $t32_output"
fi
cleanup_temp_repo "$TEST_REPO"

# -----------------------------------------------------------------------
# T-33: Step 4-P — tracked modified (dirty) mutation worktree を回収 (Issue #2158 AC-1)
# Given: detached TMPDIR worktree with uncommitted modification to a tracked file
# When: Cleanup runs
# Then: worktree reaped; mutation_worktrees >= 1 (dirty is NOT a skip reason)
# -----------------------------------------------------------------------
echo "T-33: Step 4-P が tracked modified な mutation worktree を回収 (Issue #2158 AC-1)"
TEST_REPO=$(make_temp_repo)
rm -rf "$WORKDIR_SCAN_TMP"/rite-review-mutation-* 2>/dev/null || true
( cd "$TEST_REPO" && git worktree add --detach -q "$WORKDIR_SCAN_TMP/rite-review-mutation-dirty-mod" HEAD )
echo "mutated" >> "$WORKDIR_SCAN_TMP/rite-review-mutation-dirty-mod/README.md"
t33_output=$( cd "$TEST_REPO" && bash "$CLEANUP" 2>&1 )
t33_mut=$(echo "$t33_output" | sed -n 's/.*mutation_worktrees=\([0-9]*\).*/\1/p' | head -1)
if [ ! -e "$WORKDIR_SCAN_TMP/rite-review-mutation-dirty-mod" ] \
   && [ "${t33_mut:-0}" -ge 1 ] 2>/dev/null; then
  pass "T-33: tracked modified worktree が回収され mutation_worktrees=$t33_mut"
else
  fail "T-33: dir=$([ -e "$WORKDIR_SCAN_TMP/rite-review-mutation-dirty-mod" ] && echo present || echo gone) mut=$t33_mut. Output: $t33_output"
fi
( cd "$TEST_REPO" && git worktree remove --force "$WORKDIR_SCAN_TMP/rite-review-mutation-dirty-mod" 2>/dev/null ) || true
rm -rf "$WORKDIR_SCAN_TMP"/rite-review-mutation-* 2>/dev/null || true
cleanup_temp_repo "$TEST_REPO"

# -----------------------------------------------------------------------
# T-34: Step 4-P — untracked のみの dirty worktree を回収 (Issue #2158 AC-2)
# -----------------------------------------------------------------------
echo "T-34: Step 4-P が untracked のみの mutation worktree を回収 (Issue #2158 AC-2)"
TEST_REPO=$(make_temp_repo)
rm -rf "$WORKDIR_SCAN_TMP"/rite-review-mutation-* 2>/dev/null || true
( cd "$TEST_REPO" && git worktree add --detach -q "$WORKDIR_SCAN_TMP/rite-review-mutation-untracked" HEAD )
echo "experiment" > "$WORKDIR_SCAN_TMP/rite-review-mutation-untracked/mutate.py"
t34_output=$( cd "$TEST_REPO" && bash "$CLEANUP" 2>&1 )
t34_mut=$(echo "$t34_output" | sed -n 's/.*mutation_worktrees=\([0-9]*\).*/\1/p' | head -1)
if [ ! -e "$WORKDIR_SCAN_TMP/rite-review-mutation-untracked" ] \
   && [ "${t34_mut:-0}" -ge 1 ] 2>/dev/null; then
  pass "T-34: untracked のみ worktree が回収され mutation_worktrees=$t34_mut"
else
  fail "T-34: dir=$([ -e "$WORKDIR_SCAN_TMP/rite-review-mutation-untracked" ] && echo present || echo gone) mut=$t34_mut. Output: $t34_output"
fi
( cd "$TEST_REPO" && git worktree remove --force "$WORKDIR_SCAN_TMP/rite-review-mutation-untracked" 2>/dev/null ) || true
rm -rf "$WORKDIR_SCAN_TMP"/rite-review-mutation-* 2>/dev/null || true
cleanup_temp_repo "$TEST_REPO"

# -----------------------------------------------------------------------
# T-35: Step 4-P — 到達不能 commit を持つ worktree は WARNING 付きで残存 (Issue #2158 AC-3)
# Given: detached worktree with a unique commit not reachable from any named ref
# When: Cleanup runs
# Then: worktree remains; WARNING mentions 到達不能 commit
# -----------------------------------------------------------------------
echo "T-35: Step 4-P が到達不能 commit worktree を WARNING 付きで保護 (Issue #2158 AC-3)"
TEST_REPO=$(make_temp_repo)
rm -rf "$WORKDIR_SCAN_TMP"/rite-review-mutation-* 2>/dev/null || true
( cd "$TEST_REPO" && git worktree add --detach -q "$WORKDIR_SCAN_TMP/rite-review-mutation-orphan-commit" HEAD )
(
  cd "$WORKDIR_SCAN_TMP/rite-review-mutation-orphan-commit"
  echo "unique-only-here" > orphan-payload.txt
  git add orphan-payload.txt
  git -c user.email=test@example.com -c user.name=Test commit --quiet -m "orphan-only-on-detached"
)
t35_output=$( cd "$TEST_REPO" && bash "$CLEANUP" 2>&1 )
if [ -d "$WORKDIR_SCAN_TMP/rite-review-mutation-orphan-commit" ] \
   && echo "$t35_output" | grep -q '到達不能 commit'; then
  pass "T-35: 到達不能 commit worktree が WARNING 付きで残存"
else
  fail "T-35: dir=$([ -d "$WORKDIR_SCAN_TMP/rite-review-mutation-orphan-commit" ] && echo present || echo gone). Output: $t35_output"
fi
( cd "$TEST_REPO" && git worktree remove --force "$WORKDIR_SCAN_TMP/rite-review-mutation-orphan-commit" 2>/dev/null ) || true
rm -rf "$WORKDIR_SCAN_TMP"/rite-review-mutation-* 2>/dev/null || true
cleanup_temp_repo "$TEST_REPO"

# -----------------------------------------------------------------------
# T-36: Step 4-P — 到達可能性判定不能時は安全側で見送り + WARNING (Issue #2158 AC-4)
# Given: detached worktree whose HEAD cannot be resolved (broken gitdir pointer)
# When: Cleanup runs
# Then: worktree remains; WARNING about HEAD 判定失敗
# -----------------------------------------------------------------------
echo "T-36: Step 4-P 判定不能時は残存 + WARNING (Issue #2158 AC-4)"
TEST_REPO=$(make_temp_repo)
rm -rf "$WORKDIR_SCAN_TMP"/rite-review-mutation-* 2>/dev/null || true
t36_wt="$WORKDIR_SCAN_TMP/rite-review-mutation-broken-head"
( cd "$TEST_REPO" && git worktree add --detach -q "$t36_wt" HEAD )
# Break worktree gitdir so `git -C wt rev-parse HEAD` fails (判定不能 = 安全側見送り)
printf 'gitdir: /nonexistent/rite-broken-gitdir\n' > "$t36_wt/.git"
t36_output=$( cd "$TEST_REPO" && bash "$CLEANUP" 2>&1 )
if [ -d "$t36_wt" ] \
   && echo "$t36_output" | grep -qE 'HEAD 判定に失敗|到達可能性判定に失敗'; then
  pass "T-36: 判定不能 worktree が WARNING 付きで残存"
else
  fail "T-36: dir=$([ -d "$t36_wt" ] && echo present || echo gone). Output: $t36_output"
fi
# force-remove may fail on broken gitdir; fall back to prune + rm
( cd "$TEST_REPO" && git worktree remove --force "$t36_wt" 2>/dev/null ) || true
rm -rf "$t36_wt"
( cd "$TEST_REPO" && git worktree prune 2>/dev/null ) || true
rm -rf "$WORKDIR_SCAN_TMP"/rite-review-mutation-* 2>/dev/null || true
cleanup_temp_repo "$TEST_REPO"

# -----------------------------------------------------------------------
# T-37: Step 4-P — TMPDIR がシンボリックリンクでも porcelain 物理パスを回収する
# (macOS: /var/folders → /private/var/folders、/tmp → /private/tmp)
# Given: logical TMPDIR is a symlink to a physical dir; detached worktree is
#        registered under the physical path (git worktree porcelain form)
# When: Cleanup runs with TMPDIR=logical (unresolved) form
# Then: worktree is reaped; mutation_worktrees >= 1
# Without pwd -P normalization, string-prefix match of logical vs physical
# fails and Step 4-P reports mutation_worktrees=0 (macOS CI T-15/T-30/T-33+).
# -----------------------------------------------------------------------
echo "T-37: Step 4-P が TMPDIR シンボリックリンク先の porcelain 物理パスを回収する"
TEST_REPO=$(make_temp_repo)
t37_phys=$(mktemp -d "$HOST_TMPDIR/rite-pr-cleanup-t37-phys-XXXXXX")
TEST_REPOS+=("$t37_phys")
t37_link=$(mktemp -u "$HOST_TMPDIR/rite-pr-cleanup-t37-link-XXXXXX")
if ! ln -s "$t37_phys" "$t37_link" 2>/dev/null; then
  skip "T-37: シンボリックリンクを作成できない環境のためスキップ"
else
  TEST_REPOS+=("$t37_link")
  # git often stores the physical path; put the worktree under the phys dir
  # while TMPDIR points at the logical (symlink) form — the macOS mismatch.
  ( cd "$TEST_REPO" && git worktree add --detach -q "$t37_phys/rite-review-mutation-symlink" HEAD )
  t37_output=$( cd "$TEST_REPO" && TMPDIR="$t37_link" bash "$CLEANUP" 2>&1 )
  t37_mut=$(echo "$t37_output" | sed -n 's/.*mutation_worktrees=\([0-9]*\).*/\1/p' | head -1)
  if [ ! -e "$t37_phys/rite-review-mutation-symlink" ] \
     && [ "${t37_mut:-0}" -ge 1 ] 2>/dev/null; then
    pass "T-37: シンボリックリンク TMPDIR 越しに porcelain 物理パスを回収 (mut=$t37_mut)"
  else
    fail "T-37: dir=$([ -e "$t37_phys/rite-review-mutation-symlink" ] && echo present || echo gone) mut=$t37_mut. Output: $t37_output"
  fi
  ( cd "$TEST_REPO" && git worktree remove --force "$t37_phys/rite-review-mutation-symlink" 2>/dev/null ) || true
  rm -rf "$t37_phys/rite-review-mutation-symlink" 2>/dev/null || true
  rm -f "$t37_link" 2>/dev/null || true
  rm -rf "$t37_phys" 2>/dev/null || true
fi
cleanup_temp_repo "$TEST_REPO"

# -----------------------------------------------------------------------
# T-38..42: orphan review JSON / run-start pin machine cleanup (#2175)
# -----------------------------------------------------------------------
echo "T-38..42: orphan review JSON / pin cleanup"
TEST_REPO=$(make_temp_repo)
mkdir -p "$TEST_REPO/.rite/review-results" "$TEST_REPO/.rite/sessions" "$TEST_REPO/.rite/state"
printf '{"active":true,"pr_number":700}\n' > "$TEST_REPO/.rite/sessions/live.flow-state"
printf '{"non_blocking_findings":[]}\n' > "$TEST_REPO/.rite/review-results/701-clean.json"
printf '{"non_blocking_findings":[{"id":"F-01"},{"id":"F-02"}]}\n' > "$TEST_REPO/.rite/review-results/702-notes.json"
printf '{"non_blocking_findings":[]}\n' > "$TEST_REPO/.rite/review-results/700-active.json"
printf 'broken\n' > "$TEST_REPO/.rite/review-results/703-broken.json"
printf '701-clean.json\n' > "$TEST_REPO/.rite/state/review-run-since-701.txt"
printf '700-active.json\n' > "$TEST_REPO/.rite/state/review-run-since-700.txt"
t38_output=$(cd "$TEST_REPO" && bash "$CLEANUP" 2>&1)
if [ ! -e "$TEST_REPO/.rite/review-results/701-clean.json" ] && [ ! -e "$TEST_REPO/.rite/state/review-run-since-701.txt" ]; then pass "T-38 orphan nb=0 JSON + pin deleted"; else fail "T-38 orphan nb=0 residue remained"; fi
if [ -e "$TEST_REPO/.rite/review-results/archive/702-notes.json" ] && [ ! -e "$TEST_REPO/.rite/review-results/702-notes.json" ]; then pass "T-39 orphan nb>0 JSON archived"; else fail "T-39 nb>0 JSON not archived"; fi
if [ -e "$TEST_REPO/.rite/review-results/700-active.json" ] && [ -e "$TEST_REPO/.rite/state/review-run-since-700.txt" ]; then pass "T-40 active PR artifacts protected"; else fail "T-40 active PR artifacts changed"; fi
if [ -e "$TEST_REPO/.rite/review-results/703-broken.json" ] && echo "$t38_output" | grep -q '解析できない'; then pass "T-41 malformed JSON protected with WARNING"; else fail "T-41 malformed JSON was not safely surfaced"; fi
if echo "$t38_output" | grep -q 'orphan_reviews_deleted=1' && echo "$t38_output" | grep -q 'orphan_reviews_archived=1' && echo "$t38_output" | grep -q 'orphan_review_pins=1'; then pass "T-42 cleanup counters observable"; else fail "T-42 counters missing: $t38_output"; fi
cleanup_temp_repo "$TEST_REPO"

echo "T-43: unreadable flow-state skips orphan review cleanup"
TEST_REPO=$(make_temp_repo)
mkdir -p "$TEST_REPO/.rite/review-results" "$TEST_REPO/.rite/sessions"
printf 'broken\n' > "$TEST_REPO/.rite/sessions/broken.flow-state"
printf '{"non_blocking_findings":[]}\n' > "$TEST_REPO/.rite/review-results/704-clean.json"
t43_output=$(cd "$TEST_REPO" && bash "$CLEANUP" 2>&1)
if [ -e "$TEST_REPO/.rite/review-results/704-clean.json" ] && echo "$t43_output" | grep -q '回収をスキップ'; then pass "T-43 unreadable flow-state fails safe"; else fail "T-43 flow-state failure did not protect review JSON"; fi
cleanup_temp_repo "$TEST_REPO"

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------
echo
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
echo "  SKIP: $SKIP"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
