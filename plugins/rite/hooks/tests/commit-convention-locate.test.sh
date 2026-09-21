#!/bin/bash
# Tests for commit-convention-locate.sh and commit-convention-message.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"

LOCATE="$SCRIPT_DIR/../scripts/commit-convention-locate.sh"
MSG="$SCRIPT_DIR/../scripts/commit-convention-message.sh"

echo "=== commit-convention-locate.sh tests ==="

assert_file_exists_or_fail "locate helper exists" "$LOCATE" || exit 1
assert_file_exists_or_fail "message helper exists" "$MSG" || exit 1

SANDBOXES=()
cleanup() {
  local d
  for d in "${SANDBOXES[@]:-}"; do
    [ -n "$d" ] && chmod -R u+w "$d" 2>/dev/null
    [ -n "$d" ] && [ -d "$d" ] && git -C "$d" worktree prune 2>/dev/null || true
    [ -n "$d" ] && rm -rf "$d"
  done
}
trap 'rc=$?; cleanup; exit $rc' EXIT INT TERM HUP

new_repo() {
  local repo
  repo="$(mktemp -d)"
  SANDBOXES+=("$repo")
  git -C "$repo" init -q \
    && git -C "$repo" config user.email t@test.local \
    && git -C "$repo" config user.name test \
    && git -C "$repo" config commit.gpgsign false \
    || { echo "FAIL: git init" >&2; exit 1; }
  printf 'init\n' > "$repo/README"
  git -C "$repo" add README && git -C "$repo" commit -qm init
  printf '%s' "$repo"
}

# --- neither file: PRESENT=0 ---
none_repo="$(new_repo)"
none_out=$(cd "$none_repo" && bash "$LOCATE")
assert "no files: PRESENT=0" "0" "$(printf '%s\n' "$none_out" | sed -n 's/^COMMIT_CONVENTION_PRESENT=//p')"
assert "no files: CLAUDE missing" "missing" "$(printf '%s\n' "$none_out" | sed -n 's/^CLAUDE_MD=//p')"
assert "no files: AGENTS missing" "missing" "$(printf '%s\n' "$none_out" | sed -n 's/^AGENTS_MD=//p')"

# --- CLAUDE.md present ---
claude_repo="$(new_repo)"
printf 'Commits must be English.\n' > "$claude_repo/CLAUDE.md"
claude_out=$(cd "$claude_repo" && bash "$LOCATE")
assert "CLAUDE present: PRESENT=1" "1" "$(printf '%s\n' "$claude_out" | sed -n 's/^COMMIT_CONVENTION_PRESENT=//p')"
assert "CLAUDE path is absolute file" "$claude_repo/CLAUDE.md" "$(printf '%s\n' "$claude_out" | sed -n 's/^CLAUDE_MD=//p')"

# --- AGENTS.md present ---
agents_repo="$(new_repo)"
printf 'Subject only.\n' > "$agents_repo/AGENTS.md"
agents_out=$(cd "$agents_repo" && bash "$LOCATE")
assert "AGENTS present: PRESENT=1" "1" "$(printf '%s\n' "$agents_out" | sed -n 's/^COMMIT_CONVENTION_PRESENT=//p')"

# --- nested files ignored ---
nested_repo="$(new_repo)"
mkdir -p "$nested_repo/pkg"
printf 'nested\n' > "$nested_repo/pkg/CLAUDE.md"
printf 'nested\n' > "$nested_repo/pkg/AGENTS.md"
nested_out=$(cd "$nested_repo/pkg" && bash "$LOCATE")
assert "nested only: PRESENT=0" "0" "$(printf '%s\n' "$nested_out" | sed -n 's/^COMMIT_CONVENTION_PRESENT=//p')"
assert "nested CLAUDE ignored" "missing" "$(printf '%s\n' "$nested_out" | sed -n 's/^CLAUDE_MD=//p')"

# --- unreadable file is fail-loud (not missing) ---
unread_repo="$(new_repo)"
printf 'secret\n' > "$unread_repo/CLAUDE.md"
chmod 000 "$unread_repo/CLAUDE.md"
unread_rc=0
unread_err=$(cd "$unread_repo" && bash "$LOCATE" 2>&1) || unread_rc=$?
chmod 644 "$unread_repo/CLAUDE.md"
assert "unreadable CLAUDE.md exits 1" "1" "$unread_rc"
if printf '%s' "$unread_err" | grep -q '読めません'; then
  pass "unreadable file names the path"
else
  fail "unreadable diagnostic missing: $unread_err"
fi
if printf '%s' "$unread_err" | grep -q 'COMMIT_CONVENTION_PRESENT=0'; then
  fail "unreadable must not degrade to PRESENT=0"
else
  pass "unreadable does not report PRESENT=0"
fi

# --- directory named CLAUDE.md is fail-loud ---
dir_repo="$(new_repo)"
mkdir "$dir_repo/CLAUDE.md"
dir_rc=0
dir_err=$(cd "$dir_repo" && bash "$LOCATE" 2>&1) || dir_rc=$?
assert "CLAUDE.md directory exits 1" "1" "$dir_rc"

# --- wiki worktree cwd still sees main-root convention (T-04) ---
wiki_repo="$(new_repo)"
orig_branch=$(git -C "$wiki_repo" branch --show-current)
printf 'English commits only.\n' > "$wiki_repo/CLAUDE.md"
git -C "$wiki_repo" add CLAUDE.md && git -C "$wiki_repo" commit -qm claude
git -C "$wiki_repo" checkout -q --orphan wiki
git -C "$wiki_repo" rm -rfq --ignore-unmatch .
mkdir -p "$wiki_repo/.rite/wiki"
printf 'wiki\n' > "$wiki_repo/.rite/wiki/index.md"
git -C "$wiki_repo" add .rite/wiki && git -C "$wiki_repo" commit -qm wiki-init
git -C "$wiki_repo" checkout -q "$orig_branch"
git -C "$wiki_repo" worktree add -q "$wiki_repo/.rite/wiki-worktree" wiki
wiki_out=$(cd "$wiki_repo/.rite/wiki-worktree" && bash "$LOCATE")
assert "wiki cwd PRESENT=1" "1" "$(printf '%s\n' "$wiki_out" | sed -n 's/^COMMIT_CONVENTION_PRESENT=//p')"
assert "wiki cwd CLAUDE is main root" "$wiki_repo/CLAUDE.md" "$(printf '%s\n' "$wiki_out" | sed -n 's/^CLAUDE_MD=//p')"
if [ -f "$wiki_repo/.rite/wiki-worktree/CLAUDE.md" ]; then
  fail "wiki worktree unexpectedly has CLAUDE.md"
else
  pass "wiki worktree has no CLAUDE.md of its own"
fi

# --- --root override ---
root_out=$(bash "$LOCATE" --root "$claude_repo")
assert "--root PRESENT=1" "1" "$(printf '%s\n' "$root_out" | sed -n 's/^COMMIT_CONVENTION_PRESENT=//p')"

# --- message helper: default when absent ---
def=$(mktemp)
printf 'chore(wiki): default\n' > "$def"
got=$(bash "$MSG" --default-file "$def" --root "$none_repo")
assert "default used when files absent" "chore(wiki): default" "$(printf '%s' "$got" | tr -d '\n')"

# --- message helper: files present without --message-file fails ---
msg_rc=0
msg_err=$(bash "$MSG" --default-file "$def" --root "$claude_repo" 2>&1) || msg_rc=$?
assert "present without message-file exits 1" "1" "$msg_rc"
if printf '%s' "$msg_err" | grep -q -- '--message-file'; then
  pass "missing message-file names the required flag"
else
  fail "missing message-file diagnostic: $msg_err"
fi

# --- message helper: --message-file wins even with default ---
ov=$(mktemp)
printf 'feat: from file\n\nbody with quotes '\'' and `date`\n' > "$ov"
got2=$(bash "$MSG" --default-file "$def" --message-file "$ov" --root "$claude_repo")
assert "message-file used when present" "feat: from file" "$(printf '%s\n' "$got2" | head -1)"
if printf '%s' "$got2" | grep -q '`date`'; then
  pass "message-file keeps backtick text as data"
else
  fail "backtick text lost: $got2"
fi
rm -f "$def" "$ov"

if ! print_summary "commit-convention-locate.test.sh"; then
  exit 1
fi
