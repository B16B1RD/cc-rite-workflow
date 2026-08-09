#!/usr/bin/env bash
set -u
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HELPER="$SCRIPT_DIR/../scripts/cleanup-deferred-branch-recovery.sh"
pass=0 fail=0
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
ok(){ pass=$((pass+1)); echo "  ✅ $1"; }
bad(){ fail=$((fail+1)); echo "  ❌ $1"; }
assert_contains(){ case "$2" in *"$3"*) ok "$1";; *) bad "$1: $2";; esac; }

make_repo(){
  d=$(mktemp -d "$TMP_ROOT/repo.XXXXXX")
  git -C "$d" init -q -b develop
  git -C "$d" config user.email test@example.com
  git -C "$d" config user.name test
  printf 'base\n' > "$d/README.md"
  printf '.claude/\n.mcp.json\n' > "$d/.gitignore"
  git -C "$d" add . && git -C "$d" commit -qm base
  mkdir -p "$d/.rite/worktrees"
  git -C "$d" branch feat/test
  git -C "$d" worktree add -q "$d/.rite/worktrees/issue-1" feat/test
  printf '%s\n' "$d"
}

echo "=== deferred branch recovery classifier ==="
r=$(make_repo); wt="$r/.rite/worktrees/issue-1"
mkdir -p "$wt/.claude"; printf '{}\n' > "$wt/.mcp.json"; printf ambient > "$wt/.claude/state"
out=$(cd "$r" && RITE_STATE_ROOT="$r" bash "$HELPER" --branch feat/test --pr-merged true 2>&1)
assert_contains "ambient-only clean worktree emits auto" "$out" "recovery=auto"

r=$(make_repo); wt="$r/.rite/worktrees/issue-1"; printf dirty >> "$wt/README.md"
out=$(cd "$r" && RITE_STATE_ROOT="$r" bash "$HELPER" --branch feat/test --pr-merged true 2>&1)
assert_contains "tracked dirty worktree emits manual" "$out" "recovery=manual"
assert_contains "manual warning carries resolved path" "$out" "git -C $wt status --short"
assert_contains "manual warning requires preservation" "$out" "commit / stash / copy"
case "$out" in *"worktree remove --force"*) bad "dirty warning must not prescribe --force";; *) ok "dirty warning never prescribes --force";; esac
[ -d "$wt" ] && ok "classifier preserves dirty worktree" || bad "classifier removed dirty worktree"

r=$(make_repo); wt="$r/.rite/worktrees/issue-1"
out=$(cd "$r" && RITE_STATE_ROOT="$r" bash "$HELPER" --branch feat/test --pr-merged false 2>&1)
assert_contains "unmerged branch emits manual with actual path" "$out" "path_q=$wt"

echo "PASS: $pass"
echo "FAIL: $fail"
[ "$fail" -eq 0 ]
