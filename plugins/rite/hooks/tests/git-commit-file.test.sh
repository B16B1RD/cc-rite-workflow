#!/bin/bash
# Tests for git-commit-file.sh and commit-overflow-record.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"

COMMIT="$SCRIPT_DIR/../scripts/git-commit-file.sh"
OVERFLOW="$SCRIPT_DIR/../scripts/commit-overflow-record.sh"

echo "=== git-commit-file.sh tests ==="

assert_file_exists_or_fail "git-commit-file exists" "$COMMIT" || exit 1
assert_file_exists_or_fail "overflow helper exists" "$OVERFLOW" || exit 1

SANDBOXES=()
cleanup() {
  local d
  for d in "${SANDBOXES[@]:-}"; do
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

repo="$(new_repo)"
printf 'changed\n' >> "$repo/README"
git -C "$repo" add README

# inside-tree message file is rejected
inside="$repo/msg.txt"
printf 'feat: inside\n' > "$inside"
in_rc=0
in_err=$(bash "$COMMIT" --file "$inside" --worktree "$repo" 2>&1) || in_rc=$?
assert "in-tree message file exits 1" "1" "$in_rc"
if printf '%s' "$in_err" | grep -q '作業ツリーの外'; then
  pass "in-tree file names the policy"
else
  fail "in-tree diagnostic: $in_err"
fi

# outside-tree file with quotes, newline, command-like text
outside=$(mktemp "${TMPDIR:-/tmp}/rite-commit-msg-XXXXXX")
printf 'feat(wiki): quotes '\'' and "double"\n\nbody with `date` and $(whoami) and \nsecond line\n' > "$outside"
ok_rc=0
bash "$COMMIT" --file "$outside" --worktree "$repo" -- --quiet || ok_rc=$?
assert "outside-tree -F commit exits 0" "0" "$ok_rc"
subj=$(git -C "$repo" log -1 --format=%s)
body=$(git -C "$repo" log -1 --format=%b)
assert "subject keeps quotes" "feat(wiki): quotes ' and \"double\"" "$subj"
if printf '%s' "$body" | grep -q '`date`'; then
  pass "body keeps backtick text"
else
  fail "body lost backticks: $body"
fi
if printf '%s' "$body" | grep -q '$(whoami)'; then
  pass "body keeps command substitution text"
else
  fail "body lost \$(whoami): $body"
fi
if printf '%s' "$body" | grep -q 'second line'; then
  pass "body keeps newline-separated second line"
else
  fail "body lost second line: $body"
fi
# the command-like strings must not have been executed as the subject/body
if printf '%s' "$subj$body" | grep -qE '^[0-9]{4}|root|akiyoshi'; then
  # date output or whoami result would look like this if executed; allow author name only in commit metadata, not message
  if printf '%s' "$subj$body" | grep -q '`date`'; then
    pass "command-like tokens remain literal"
  else
    fail "command-like tokens look expanded: $subj $body"
  fi
else
  pass "command-like tokens remain literal"
fi
rm -f "$outside"

# relative --file rejected
rel_rc=0
rel_err=$(bash "$COMMIT" --file msg.txt --worktree "$repo" 2>&1) || rel_rc=$?
assert "relative --file exits 1" "1" "$rel_rc"

# --- overflow write/read and failure (T-06 / T-08) ---
store=$(mktemp "${TMPDIR:-/tmp}/rite-overflow-store-XXXXXX")
bodyf=$(mktemp "${TMPDIR:-/tmp}/rite-overflow-body-XXXXXX")
printf 'root cause text with `tick`\n' > "$bodyf"
w_rc=0
bash "$OVERFLOW" write --file "$store" --section "Root cause" --body-file "$bodyf" || w_rc=$?
assert "overflow write exits 0" "0" "$w_rc"
got=$(bash "$OVERFLOW" read --file "$store" --section "Root cause")
if printf '%s' "$got" | grep -q 'root cause text with `tick`'; then
  pass "overflow read returns stored body"
else
  fail "overflow read mismatch: $got"
fi

# missing section
miss_rc=0
bash "$OVERFLOW" read --file "$store" --section "Acknowledged-finding" >/dev/null 2>&1 || miss_rc=$?
assert "missing overflow section exits 2" "2" "$miss_rc"

# write to unwritable directory (T-08)
nowrite="$(mktemp -d)"
SANDBOXES+=("$nowrite")
chmod 500 "$nowrite"
fail_rc=0
fail_err=$(bash "$OVERFLOW" write --file "$nowrite/blocked.md" --section "Root cause" --body-file "$bodyf" 2>&1) || fail_rc=$?
chmod 700 "$nowrite"
assert "unwritable overflow store exits 1" "1" "$fail_rc"
if printf '%s' "$fail_err" | grep -qE '作成できません|保存できません|書き込みに失敗'; then
  pass "overflow failure names the IO error"
else
  fail "overflow failure diagnostic: $fail_err"
fi
if [ -f "$nowrite/blocked.md" ]; then
  fail "failed overflow write must not leave a success file"
else
  pass "failed overflow write left no store file"
fi

# verify-before-mv: a body with a nested ## heading must not mutate the store
cut_store=$(mktemp "${TMPDIR:-/tmp}/rite-overflow-cut-XXXXXX")
cut_body=$(mktemp "${TMPDIR:-/tmp}/rite-overflow-cut-body-XXXXXX")
printf '## Unrelated\n\nkeep me\n' > "$cut_store"
printf 'root cause paragraph\n## Details\nmore\n' > "$cut_body"
before=$(cat "$cut_store")
cut_rc=0
bash "$OVERFLOW" write --file "$cut_store" --section "Root cause" --body-file "$cut_body" >/dev/null 2>&1 || cut_rc=$?
assert "overflow nested heading write exits 1" "1" "$cut_rc"
assert "overflow nested heading leaves store bytes unchanged" "$before" "$(cat "$cut_store")"
miss_cut=0
bash "$OVERFLOW" read --file "$cut_store" --section "Root cause" >/dev/null 2>&1 || miss_cut=$?
assert "overflow nested heading read reports missing section" "2" "$miss_cut"
empty_body=$(mktemp "${TMPDIR:-/tmp}/rite-overflow-empty-XXXXXX")
: > "$empty_body"
empty_rc=0
bash "$OVERFLOW" write --file "$cut_store" --section "Root cause" --body-file "$empty_body" >/dev/null 2>&1 || empty_rc=$?
assert "overflow empty body write exits 1" "1" "$empty_rc"
assert "overflow empty body leaves store bytes unchanged" "$before" "$(cat "$cut_store")"
rm -f "$store" "$bodyf" "$cut_store" "$cut_body" "$empty_body"

if ! print_summary "git-commit-file.test.sh"; then
  exit 1
fi
