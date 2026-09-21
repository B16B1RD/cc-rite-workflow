#!/bin/bash
# Tests for commit-convention-locate.sh and commit-convention-message.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"

LOCATE="$SCRIPT_DIR/../scripts/commit-convention-locate.sh"
MSG="$SCRIPT_DIR/../scripts/commit-convention-message.sh"
# shellcheck source=../scripts/lib/canon-path.sh
source "$SCRIPT_DIR/../scripts/lib/canon-path.sh"

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
  repo=$(CDPATH= cd -- "$repo" && pwd -P)
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
assert "CLAUDE path is absolute file" "$(canon_abs_path "$claude_repo/CLAUDE.md")" "$(printf '%s\n' "$claude_out" | sed -n 's/^CLAUDE_MD=//p')"

# --- AGENTS.md present ---
agents_repo="$(new_repo)"
printf 'Subject only.\n' > "$agents_repo/AGENTS.md"
agents_out=$(cd "$agents_repo" && bash "$LOCATE")
assert "AGENTS present: PRESENT=1" "1" "$(printf '%s\n' "$agents_out" | sed -n 's/^COMMIT_CONVENTION_PRESENT=//p')"

# --- nested files are listed (host hierarchy); not uniformly ignored ---
nested_repo="$(new_repo)"
mkdir -p "$nested_repo/pkg"
printf 'nested\n' > "$nested_repo/pkg/CLAUDE.md"
printf 'nested\n' > "$nested_repo/pkg/AGENTS.md"
root_nested_out=$(cd "$nested_repo" && bash "$LOCATE")
assert "root cwd without --path omits nested" "" "$(printf '%s\n' "$root_nested_out" | sed -n 's/^NESTED_CLAUDE_MD=//p')"
assert "root cwd nested-only PRESENT=0" "0" "$(printf '%s\n' "$root_nested_out" | sed -n 's/^COMMIT_CONVENTION_PRESENT=//p')"
nested_out=$(cd "$nested_repo/pkg" && bash "$LOCATE")
assert "pkg cwd PRESENT=1" "1" "$(printf '%s\n' "$nested_out" | sed -n 's/^COMMIT_CONVENTION_PRESENT=//p')"
assert "nested root CLAUDE missing" "missing" "$(printf '%s\n' "$nested_out" | sed -n 's/^CLAUDE_MD=//p')"
assert "pkg cwd lists nested CLAUDE" "$(canon_abs_path "$nested_repo/pkg/CLAUDE.md")" "$(printf '%s\n' "$nested_out" | sed -n 's/^NESTED_CLAUDE_MD=//p')"
path_out=$(cd "$nested_repo" && bash "$LOCATE" --path README)
assert "unrelated --path omits nested CLAUDE" "" "$(printf '%s\n' "$path_out" | sed -n 's/^NESTED_CLAUDE_MD=//p')"
pkg_out=$(cd "$nested_repo" && bash "$LOCATE" --path pkg/x)
assert "pkg --path keeps nested CLAUDE" "$(canon_abs_path "$nested_repo/pkg/CLAUDE.md")" "$(printf '%s\n' "$pkg_out" | sed -n 's/^NESTED_CLAUDE_MD=//p')"
abs_rc=0
abs_err=$(cd "$nested_repo" && bash "$LOCATE" --path /tmp/x 2>&1) || abs_rc=$?
assert "absolute --path exits 1" "1" "$abs_rc"
if grep -q '作業ツリー相対' <<<"$abs_err"; then
  pass "absolute --path names the policy"
else
  fail "absolute --path diagnostic: $abs_err"
fi
esc_rc=0
esc_err=$(cd "$nested_repo" && bash "$LOCATE" --path ../outside-leaf 2>&1) || esc_rc=$?
assert "dotdot --path exits 1" "1" "$esc_rc"
if grep -q '作業ツリーの外' <<<"$esc_err"; then
  pass "dotdot --path names the escape"
else
  fail "dotdot --path diagnostic: $esc_err"
fi
for p in '../' '..'; do
  p_rc=0
  p_err=$(cd "$nested_repo" && bash "$LOCATE" --path "$p" 2>&1) || p_rc=$?
  assert "dotdot path $p exits 1" "1" "$p_rc"
  if grep -q '作業ツリーの外' <<<"$p_err"; then
    pass "dotdot path $p names the escape"
  else
    fail "dotdot path $p diagnostic: $p_err"
  fi
  if grep -q 'COMMIT_CONVENTION_PRESENT=0' <<<"$p_err"; then
    fail "dotdot path $p must not degrade to PRESENT=0"
  else
    pass "dotdot path $p does not report PRESENT=0"
  fi
done
chmod 000 "$nested_repo/pkg/CLAUDE.md"
nest_unread_rc=0
nest_unread_err=$(cd "$nested_repo" && bash "$LOCATE" --path pkg/x 2>&1) || nest_unread_rc=$?
chmod 644 "$nested_repo/pkg/CLAUDE.md"
assert "unreadable nested CLAUDE.md exits 1" "1" "$nest_unread_rc"
if grep -q 'ネストした規約ファイルを読めません' <<<"$nest_unread_err"; then
  pass "unreadable nested names the path"
else
  fail "unreadable nested diagnostic: $nest_unread_err"
fi
if grep -q 'COMMIT_CONVENTION_PRESENT=0' <<<"$nest_unread_err"; then
  fail "unreadable nested must not degrade to PRESENT=0"
else
  pass "unreadable nested does not report PRESENT=0"
fi
cwd_unread_rc=0
chmod 000 "$nested_repo/pkg/CLAUDE.md"
cwd_unread_err=$(cd "$nested_repo/pkg" && bash "$LOCATE" 2>&1) || cwd_unread_rc=$?
chmod 644 "$nested_repo/pkg/CLAUDE.md"
assert "unreadable nested via cwd exits 1" "1" "$cwd_unread_rc"

# --- unreadable file is fail-loud (not missing) ---
unread_repo="$(new_repo)"
printf 'secret\n' > "$unread_repo/CLAUDE.md"
chmod 000 "$unread_repo/CLAUDE.md"
unread_rc=0
unread_err=$(cd "$unread_repo" && bash "$LOCATE" 2>&1) || unread_rc=$?
chmod 644 "$unread_repo/CLAUDE.md"
assert "unreadable CLAUDE.md exits 1" "1" "$unread_rc"
if grep -q '読めません' <<<"$unread_err"; then
  pass "unreadable file names the path"
else
  fail "unreadable diagnostic missing: $unread_err"
fi
if grep -q 'COMMIT_CONVENTION_PRESENT=0' <<<"$unread_err"; then
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
assert "wiki cwd CLAUDE is main root" "$(canon_abs_path "$wiki_repo/CLAUDE.md")" "$(printf '%s\n' "$wiki_out" | sed -n 's/^CLAUDE_MD=//p')"

# --- feature worktree reads its own CLAUDE.md (not the shared checkout) ---
feat_repo="$(new_repo)"
printf 'Commit messages must be English.\n' > "$feat_repo/CLAUDE.md"
git -C "$feat_repo" add CLAUDE.md && git -C "$feat_repo" commit -qm claude-en
git -C "$feat_repo" worktree add -q "$feat_repo/feature" -b feature
printf 'コミットメッセージは日本語にする。\n' > "$feat_repo/feature/CLAUDE.md"
feat_out=$(cd "$feat_repo/feature" && bash "$LOCATE")
assert "feature cwd PRESENT=1" "1" "$(printf '%s\n' "$feat_out" | sed -n 's/^COMMIT_CONVENTION_PRESENT=//p')"
assert "feature cwd CLAUDE is the feature tree" "$(canon_abs_path "$feat_repo/feature/CLAUDE.md")" "$(printf '%s\n' "$feat_out" | sed -n 's/^CLAUDE_MD=//p')"
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
if grep -q -- '--message-file' <<<"$msg_err"; then
  pass "missing message-file names the required flag"
else
  fail "missing message-file diagnostic: $msg_err"
fi

# --- message helper: --message-file wins even with default ---
ov=$(mktemp)
printf 'feat: from file\n\nbody with quotes '\'' and `date`\n' > "$ov"
got2=$(bash "$MSG" --default-file "$def" --message-file "$ov" --root "$claude_repo")
assert "message-file used when present" "feat: from file" "$(printf '%s\n' "$got2" | head -1)"
if grep -q '`date`' <<<"$got2"; then
  pass "message-file keeps backtick text as data"
else
  fail "backtick text lost: $got2"
fi
rm -f "$def" "$ov"

if ! print_summary "commit-convention-locate.test.sh"; then
  exit 1
fi
