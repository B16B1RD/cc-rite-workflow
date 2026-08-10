#!/bin/bash
# Functional regression test for corrupt/orphaned .rite/wiki-worktree recovery.
#
# Reproduces the silent raw-source accumulation stall : when the
# repository is relocated/copied, the wiki worktree's `.git` file keeps a stale
# `gitdir:` pointer to the old path, leaving `.rite/wiki-worktree` as a directory
# that exists on disk but is NOT a registered worktree. Before the fix:
#   - wiki-ingest-commit.sh hit `verify_worktree_branch ... || exit 1` and
#     hard-stopped (non-blocking upstream, so nobody saw the WARNING).
#   - wiki-worktree-setup.sh could not recover it either (`git worktree add`
#     aborts with "already exists" on the orphaned directory).
# Both scripts now self-heal. Unlike the sibling static-pin tests, this builds a
# real git fixture so the recovery cannot silently regress.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR/../scripts"
COMMIT_SH="$SCRIPTS_DIR/wiki-ingest-commit.sh"
SETUP_SH="$SCRIPTS_DIR/wiki-worktree-setup.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ FAIL: $1"; }

echo "=== wiki-worktree corrupt/orphaned recovery tests ==="
echo ""

for f in "$COMMIT_SH" "$SETUP_SH"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: $f not found" >&2
    exit 1
  fi
done

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap 'rc=$?; cleanup; exit $rc' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

# Build a fixture repo with a dev branch + a wiki branch, then leave an orphaned
# .rite/wiki-worktree directory whose `.git` pointer is stale. Echoes the repo
# root on stdout.
make_fixture() {
  # $1: "yes" (default) creates a local wiki branch; "no" omits it (to exercise
  #     the legacy fallthrough path where setup + legacy both exit 2 on the
  #     missing branch).
  local root with_wiki="${1:-yes}"
  root="$WORK/repo"
  mkdir -p "$root"
  git -C "$root" init -q -b develop
  git -C "$root" config user.email "test@example.com"
  git -C "$root" config user.name "rite test"
  # Disable commit signing locally so the fixture commits (and the recovery
  # commit made by the script under test) do not fail under a global
  # commit.gpgsign=true. Matches the convention in the sibling fixture tests.
  git -C "$root" config commit.gpgsign false

  printf 'wiki:\n  enabled: true\n  branch_strategy: separate_branch\n  branch_name: wiki\n' \
    > "$root/rite-config.yml"
  printf '.rite/wiki-worktree/\n.rite/state/\n' > "$root/.gitignore"
  git -C "$root" add rite-config.yml .gitignore
  git -C "$root" commit -q -m "init develop"

  if [ "$with_wiki" = "yes" ]; then
    # wiki branch: tracks .rite/wiki/raw/ structure.
    git -C "$root" checkout -q --orphan wiki
    git -C "$root" rm -q -rf . >/dev/null 2>&1 || true
    mkdir -p "$root/.rite/wiki/raw/retrospectives"
    printf '# wiki\n' > "$root/.rite/wiki/index.md"
    : > "$root/.rite/wiki/raw/retrospectives/.gitkeep"
    git -C "$root" add .rite/wiki/index.md .rite/wiki/raw/retrospectives/.gitkeep
    git -C "$root" commit -q -m "init wiki"
    git -C "$root" checkout -q develop
  fi

  # Stage a pending raw source on the dev tree (untracked, as the trigger leaves it).
  mkdir -p "$root/.rite/wiki/raw/retrospectives"
  printf -- '---\ntype: retrospectives\nsource_ref: "issue-1662"\ningested: false\n---\n\nTest retrospective body.\n' \
    > "$root/.rite/wiki/raw/retrospectives/20260626T000000Z-issue-1662.md"

  # Orphaned worktree directory with a stale gitdir pointer (the relocation bug):
  # exists on disk, `git -C` cannot resolve it, and `git worktree list` omits it.
  mkdir -p "$root/.rite/wiki-worktree"
  printf 'gitdir: /nonexistent/relocated/.git/worktrees/wiki-worktree\n' \
    > "$root/.rite/wiki-worktree/.git"

  printf '%s\n' "$root"
}

# --- Sanity: the fixture really reproduces the broken precondition ---
WORK="$(mktemp -d)"
REPO="$(make_fixture)"

echo "TC-PRECONDITION: orphaned .rite/wiki-worktree is unresolvable and unregistered"
precond_ok=true
if git -C "$REPO/.rite/wiki-worktree" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  precond_ok=false  # should FAIL to resolve
fi
if git -C "$REPO" worktree list --porcelain 2>/dev/null | grep -q "wiki-worktree"; then
  precond_ok=false  # should NOT be registered
fi
if [ "$precond_ok" = "true" ]; then
  pass "fixture reproduces corrupt + unregistered worktree"
else
  fail "fixture did not reproduce the broken precondition"
fi
echo ""

# --- TC-COMMIT-RECOVER: wiki-ingest-commit.sh self-heals and commits the raw ---
echo "TC-COMMIT-RECOVER: wiki-ingest-commit.sh recovers and commits pending raw"
wiki_before="$(git -C "$REPO" rev-parse wiki)"
set +e
commit_out="$(cd "$REPO" && bash "$COMMIT_SH" 2>commit_err.txt)"
commit_rc=$?
commit_err="$(cat "$REPO/commit_err.txt" 2>/dev/null || true)"
set -e
wiki_after="$(git -C "$REPO" rev-parse wiki)"

# rc 0 (push ok) or 4 (committed locally, push failed: no remote in fixture) both
# mean the raw landed on the wiki branch. The regression was a silent exit 1.
if { [ "$commit_rc" -eq 0 ] || [ "$commit_rc" -eq 4 ]; } && [ "$wiki_before" != "$wiki_after" ]; then
  pass "raw committed to wiki branch via self-heal (rc=$commit_rc)"
else
  fail "expected recovery+commit (rc 0/4, wiki advanced); got rc=$commit_rc, wiki_before=$wiki_before wiki_after=$wiki_after"
  echo "    --- stdout ---"; printf '%s\n' "$commit_out" | sed 's/^/    /'
  echo "    --- stderr ---"; printf '%s\n' "$commit_err" | sed 's/^/    /'
fi
echo ""

echo "TC-COMMIT-NOT-SILENT: a WARNING is emitted (no silent stall)"
# Match only the fix-specific recovery token `自己回復`. The earlier broad
# alternative `wiki-worktree-setup.sh` also matched the pre-fix code's
# verify_worktree_branch remediation hint ("対処: ... bash .../wiki-worktree-setup.sh"),
# so the assertion passed even on the broken (reverted) code — a non-discriminating
# test. `自己回復` appears only on the recovery path this PR adds.
if printf '%s' "$commit_err" | grep -q "自己回復"; then
  pass "recovery WARNING surfaced on stderr"
else
  fail "no recovery WARNING — silent-failure regression"
fi
echo ""

echo "TC-COMMIT-RAW-ON-WIKI: committed raw is present on the wiki branch tree"
if git -C "$REPO" ls-tree -r --name-only wiki | grep -q "raw/retrospectives/20260626T000000Z-issue-1662.md"; then
  pass "raw source present on wiki branch"
else
  fail "raw source missing from wiki branch after recovery"
fi
echo ""

# --- TC-SETUP-RECOVER: wiki-worktree-setup.sh recovers the orphaned directory ---
# Fresh fixture so setup.sh faces the orphaned dir directly.
rm -rf "$WORK"; WORK="$(mktemp -d)"
REPO="$(make_fixture)"
echo "TC-SETUP-RECOVER: wiki-worktree-setup.sh repairs orphaned .rite/wiki-worktree"
set +e
setup_out="$(cd "$REPO" && bash "$SETUP_SH" 2>setup_err.txt)"
setup_rc=$?
recovered_branch="$(git -C "$REPO/.rite/wiki-worktree" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
set -e
# Assert the recovered worktree is on the wiki branch specifically, not merely
# resolvable — a worktree recreated on the wrong branch would otherwise pass.
if [ "$setup_rc" -eq 0 ] && [ "$recovered_branch" = "wiki" ]; then
  pass "setup repaired worktree onto the wiki branch (rc=$setup_rc, branch=$recovered_branch)"
else
  fail "setup did not repair orphaned worktree onto wiki (rc=$setup_rc, branch='$recovered_branch')"
  printf '%s\n' "$setup_out" | sed 's/^/    out: /'
  cat "$REPO/setup_err.txt" 2>/dev/null | sed 's/^/    err: /'
fi
echo ""

# --- TC-FALLTHROUGH-NO-WIKI: legacy fallthrough is graceful when wiki branch is missing ---
# This pins the case *) fallthrough path that this PR introduced in
# wiki-ingest-commit.sh. With no local wiki branch: verify rc=2 (corrupt) →
# setup.sh exits 2 (branch missing, before the residue-removal step) → re-verify
# skipped → case *) falls through to the legacy stash/checkout path → legacy's own
# `git show-ref --verify` exits 2 on the missing branch. The expected outcome is a
# graceful exit 2 (commit_branch_missing), NOT a silent exit-1 stall or a crash.
rm -rf "$WORK"; WORK="$(mktemp -d)"
REPO="$(make_fixture no)"
echo "TC-FALLTHROUGH-NO-WIKI: commit.sh falls through to legacy gracefully (exit 2) when wiki branch missing"
set +e
ft_out="$(cd "$REPO" && bash "$COMMIT_SH" 2>ft_err.txt)"
ft_rc=$?
ft_err="$(cat "$REPO/ft_err.txt" 2>/dev/null || true)"
set -e
if [ "$ft_rc" -eq 2 ] && printf '%s' "$ft_err" | grep -q "自己回復"; then
  pass "graceful fallthrough exit 2 with recovery WARNING (no silent exit-1 stall)"
else
  fail "expected graceful exit 2 + recovery WARNING; got rc=$ft_rc"
  printf '%s\n' "$ft_out" | sed 's/^/    out: /'
  printf '%s\n' "$ft_err" | sed 's/^/    err: /'
fi
echo ""

echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
