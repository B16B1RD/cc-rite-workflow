#!/bin/bash
# Execute the documented collection blocks so their exit status and output stay in sync.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

extract_block() {
  awk '
    /^### 2\.2 / { section=1; next }
    section && /^```bash$/ { block=1; next }
    block && /^```$/ { exit }
    block { print }
  ' "$1"
}
extract_block "$PLUGIN_ROOT/skills/wiki-lint/SKILL.md" > "$TEST_DIR/lint.template"
extract_block "$PLUGIN_ROOT/skills/wiki-ingest/SKILL.md" > "$TEST_DIR/ingest.template"
test -s "$TEST_DIR/lint.template"
test -s "$TEST_DIR/ingest.template"

repo="$TEST_DIR/repo"
mkdir -p "$repo/.rite/wiki/pages/patterns" "$repo/.rite/wiki/raw/reviews"
git -C "$repo" init -q
git -C "$repo" -c user.name=Test -c user.email=test@example.com commit -q --allow-empty -m init
git -C "$repo" branch wiki-empty
printf 'page\n' > "$repo/.rite/wiki/pages/patterns/page.md"
git -C "$repo" add .rite/wiki/pages
git -C "$repo" -c user.name=Test -c user.email=test@example.com commit -qm page
git -C "$repo" branch wiki-pages
printf 'raw\n' > "$repo/.rite/wiki/raw/reviews/raw.md"
git -C "$repo" add .rite/wiki/raw
git -C "$repo" -c user.name=Test -c user.email=test@example.com commit -qm raw
git -C "$repo" branch wiki-both

run_lint() {
  sed -e "s/{branch_strategy}/$1/g" -e "s/{wiki_branch}/$2/g" \
    "$TEST_DIR/lint.template" > "$TEST_DIR/lint.sh"
  rc=0
  (cd "$repo" && bash "$TEST_DIR/lint.sh") > "$TEST_DIR/out" 2> "$TEST_DIR/err" || rc=$?
  output=$(cat "$TEST_DIR/out")
}

for strategy in same_branch separate_branch; do
  rm -f "$repo/.rite/wiki/pages/patterns/page.md" "$repo/.rite/wiki/raw/reviews/raw.md"
  run_lint "$strategy" wiki-empty
  assert "$strategy empty exit" 0 "$rc"
  assert "$strategy empty output" '---' "$output"
  assert "$strategy empty output has one newline" 4 "$(wc -c < "$TEST_DIR/out" | tr -d '[:space:]')"
  assert "$strategy empty stderr" '' "$(cat "$TEST_DIR/err")"

  printf 'page\n' > "$repo/.rite/wiki/pages/patterns/page.md"
  run_lint "$strategy" wiki-pages
  assert "$strategy pages without raw exit" 0 "$rc"
  assert "$strategy pages without raw output" $'.rite/wiki/pages/patterns/page.md\n---' "$output"

  rm -f "$repo/.rite/wiki/pages/patterns/page.md"
  printf 'raw\n' > "$repo/.rite/wiki/raw/reviews/raw.md"
  git -C "$repo" rm -q --cached .rite/wiki/pages/patterns/page.md
  git -C "$repo" -c user.name=Test -c user.email=test@example.com commit -qm raw-only
  git -C "$repo" branch -f wiki-raw
  run_lint "$strategy" wiki-raw
  assert "$strategy raw without pages exit" 0 "$rc"
  assert "$strategy raw without pages output" $'---\n.rite/wiki/raw/reviews/raw.md' "$output"

  printf 'page\n' > "$repo/.rite/wiki/pages/patterns/page.md"
  run_lint "$strategy" wiki-both
  assert "$strategy both exit" 0 "$rc"
  assert "$strategy both output" $'.rite/wiki/pages/patterns/page.md\n---\n.rite/wiki/raw/reviews/raw.md' "$output"
  # Restore the index for the next strategy's raw-only fixture.
  git -C "$repo" add .rite/wiki/pages/patterns/page.md
  git -C "$repo" -c user.name=Test -c user.email=test@example.com commit -qm restore-page
done

run_lint invalid wiki-empty
assert 'unknown strategy exit' 1 "$rc"
assert_grep 'unknown strategy diagnostic' "$TEST_DIR/err" 'ERROR:.*branch_strategy'
run_lint separate_branch missing-wiki
assert 'ls-tree failure remains non-blocking' 0 "$rc"
assert 'ls-tree failure empty output' '---' "$output"
assert_grep 'ls-tree failure warning' "$TEST_DIR/err" 'WARNING: git ls-tree.*rc='

rm -f "$repo/.rite/wiki/raw/reviews/raw.md"
for strategy in same_branch separate_branch; do
  sed -e "s/{branch_strategy}/$strategy/g" -e "s|{wiki_worktree_abs}|$repo|g" \
    "$TEST_DIR/ingest.template" > "$TEST_DIR/ingest.sh"
  rc=0
  (cd "$repo" && bash "$TEST_DIR/ingest.sh") > "$TEST_DIR/out" 2> "$TEST_DIR/err" || rc=$?
  assert "ingest $strategy empty exit" 0 "$rc"
  assert "ingest $strategy empty output" 'Found 0 candidate raw source(s)' "$(cat "$TEST_DIR/out")"
done

print_summary "$(basename "$0")"
