#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
audit="$ROOT/plugins/rite/skills/pr-create/references/promotion-audit-inline-content-delegation.md"
create="$ROOT/plugins/rite/skills/pr-create/SKILL.md"
heaviness="$ROOT/plugins/rite/hooks/scripts/bash-heaviness-check.sh"
cleanup="$ROOT/plugins/rite/hooks/scripts/pr-cycle-cleanup.sh"
failures=0

assert_grep() {
  local label=$1 file=$2 pattern=$3
  if grep -Fq -- "$pattern" "$file"; then
    printf 'PASS: %s\n' "$label"
  else
    printf 'FAIL: %s\n' "$label" >&2
    failures=$((failures + 1))
  fi
}

assert_grep 'promotion is shelved as already mechanized' "$audit" \
  '| `inline-content-delegation-avoids-malformed-toolcall` | shelve — already mechanized |'
assert_grep 'audit points to producer protocol' "$audit" '`pr-create/SKILL.md` Phase 3.4 three-stage protocol'
assert_grep 'audit points to prevention signal' "$audit" '`inline-gh-create-title` signal'
assert_grep 'audit points to lifecycle backstop' "$audit" '`pr-cycle-cleanup.sh` orphan-workdir reaper'

assert_grep 'producer requires three-stage protocol' "$create" '**3 段プロトコル**'
assert_grep 'producer delegates title and body to Write tool' "$create" '**Write tool** で title / body を raw ファイル化'
assert_grep 'producer reads title through a variable' "$create" 'pr_title=$(cat "$pr_workdir/pr_title.txt")'
assert_grep 'producer passes body by file' "$create" '--title "$pr_title" --body-file "$pr_workdir/pr_body.md"'
assert_grep 'producer guards empty title' "$create" 'if [ -z "$pr_title" ]; then'
assert_grep 'producer guards empty body' "$create" 'if [ ! -s "$pr_workdir/pr_body.md" ]; then'

assert_grep 'lint signal emitter exists' "$heaviness" 'printf "[bash-heaviness] %s:%d: inline-gh-create-title — literal --title in gh {pr,issue} create; delegate the title to a file (Write tool) or a variable to avoid malformed tool-call\n", fname, gh_title_line'
assert_grep 'lint detects pr and issue create' "$heaviness" '/gh[[:space:]]+(pr|issue)[[:space:]]+create/'
assert_grep 'lint tracks continued commands' "$heaviness" 'gh_create_active == 1 && line !~ /\\[[:space:]]*$/'

assert_grep 'orphan reaper targets pr workdirs' "$cleanup" 'reap_orphan_dirs "orphan workdir" "$workdir_tmp_base" '\''rite-pr-create-*'\'' \'
assert_grep 'orphan reaper invokes workdir callback' "$cleanup" '_reap_workdir "$workdir_find_out" "$workdir_find_err"'
assert_grep 'orphan reaper has 24-hour guard' "$cleanup" 'readonly WORKDIR_REAP_AGE_MINUTES=1440'

if [ "$failures" -ne 0 ]; then
  printf '%s contract assertion(s) failed\n' "$failures" >&2
  exit 1
fi

printf 'All PR-create promotion contract assertions passed.\n'
