#!/bin/bash
# Inventory and scenario tests for rite-generated commit conventions (T-01..T-10).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"

PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
LOCATE="$PLUGIN_ROOT/hooks/scripts/commit-convention-locate.sh"
MSG="$PLUGIN_ROOT/hooks/scripts/commit-convention-message.sh"
COMMIT="$PLUGIN_ROOT/hooks/scripts/git-commit-file.sh"
OVERFLOW="$PLUGIN_ROOT/hooks/scripts/commit-overflow-record.sh"
WIKI_INIT="$PLUGIN_ROOT/hooks/scripts/wiki-branch-init.sh"
WIKI_INGEST="$PLUGIN_ROOT/hooks/scripts/wiki-ingest-commit.sh"
WIKI_WT="$PLUGIN_ROOT/hooks/scripts/wiki-worktree-commit.sh"
CONV="$PLUGIN_ROOT/references/commit-convention.md"

IMPLEMENT="$PLUGIN_ROOT/skills/issue-implement/SKILL.md"
FIX="$PLUGIN_ROOT/skills/fix/SKILL.md"
SETUP="$PLUGIN_ROOT/skills/setup/SKILL.md"
WIKI_INIT_SKILL="$PLUGIN_ROOT/skills/wiki-init/SKILL.md"
WIKI_INGEST_SKILL="$PLUGIN_ROOT/skills/wiki-ingest/SKILL.md"
WIKI_LINT_SKILL="$PLUGIN_ROOT/skills/wiki-lint/SKILL.md"
MERGE="$PLUGIN_ROOT/skills/merge/SKILL.md"
PR_WIKI="$PLUGIN_ROOT/skills/pr-review/references/wiki-recording.md"
FIX_WIKI="$PLUGIN_ROOT/skills/fix/references/wiki-recording.md"
CLOSE="$PLUGIN_ROOT/skills/issue-close/SKILL.md"

echo "=== commit-convention inventory (T-01..T-10) ==="

assert_file_exists_or_fail "commit-convention.md" "$CONV" || exit 1

SANDBOXES=()
cleanup() {
  local d
  for d in "${SANDBOXES[@]:-}"; do
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
    || { echo "ERROR: git init" >&2; exit 1; }
  printf 'init\n' > "$repo/README"
  git -C "$repo" add README && git -C "$repo" commit -qm init
  printf '%s' "$repo"
}

# --- T-07: equal-priority files, conflict fail-loud, nested ignored ---
assert_grep "T-07 both files are equal-priority" "$CONV" \
  '両ファイルを同じ適用対象として読む'
assert_grep "T-07 conflict is fail-loud" "$CONV" \
  '同一項目.*食い違うときは、食い違い箇所を示してコミットしない'
assert_grep "T-07 nested files are ignored" "$CONV" \
  'サブディレクトリの同名ファイルは読まない'
assert_not_grep "T-07 no CLAUDE-always-wins helper" "$PLUGIN_ROOT/hooks/scripts/commit-convention-message.sh" \
  'CLAUDE.md を優先'

# --- T-03: production paths wire --message-file / git-commit-file / -F / --body-file ---
assert_grep "T-03 implement uses git-commit-file" "$IMPLEMENT" \
  'git-commit-file.sh --file'
assert_grep "T-03 implement locates convention" "$IMPLEMENT" \
  'commit-convention.md'
assert_grep "T-03 fix uses git commit -F" "$FIX" \
  'git commit -F "\{commit_message_file\}"'
assert_grep "T-03 setup uses git-commit-file" "$SETUP" \
  'git-commit-file.sh'
assert_grep "T-03 wiki-init passes --message-file" "$WIKI_INIT_SKILL" \
  'message-file "\{wiki_init_msg_file\}"'
assert_grep "T-03 wiki-ingest 5.1 uses --message-file" "$WIKI_INGEST_SKILL" \
  'wiki-worktree-commit.sh" --commit-only --message-file'
assert_grep "T-03 wiki-ingest 5.2 uses git-commit-file" "$WIKI_INGEST_SKILL" \
  'git-commit-file.sh" --file "\$_ingest_msg"'
assert_grep "T-03 wiki-lint same_branch uses git-commit-file" "$WIKI_LINT_SKILL" \
  'git-commit-file.sh" --file "\$_lint_msg"'
assert_grep "T-03 wiki-lint separate_branch uses --message-file" "$WIKI_LINT_SKILL" \
  'wiki-worktree-commit.sh" --commit-only --message-file'
assert_grep "T-03 wiki-ingest-commit helper accepts --message-file" "$WIKI_INGEST" \
  '\[--message-file ABS\]'
assert_grep "T-03 squash passes --subject and --body-file" "$MERGE" \
  'subject "\{squash_subject\}" --body-file "\{squash_body_file\}"'
assert_grep "T-03 review wiki-recording passes --message-file" "$PR_WIKI" \
  'wiki-ingest-commit.sh --message-file'
assert_grep "T-03 fix wiki-recording passes --message-file" "$FIX_WIKI" \
  'wiki-ingest-commit.sh --message-file'
assert_grep "T-03 issue-close passes --message-file" "$CLOSE" \
  'wiki-ingest-commit.sh --message-file'

# --- T-05: squash keeps delete-branch=false + match-head-commit; CI red does not reach merge ---
assert_grep "T-05 squash keeps --delete-branch=false" "$MERGE" \
  'squash --delete-branch=false --match-head-commit "\$verified_head"'
assert_grep "T-05 CI unhealthy forbids gh pr merge" "$MERGE" \
  'ステップ 2 の `gh pr merge` は実行しない'

# --- T-06: overflow store + inspection reads the same place; PR-less is WM ---
assert_grep "T-06 overflow write helper is named" "$CONV" \
  'commit-overflow-record.sh write'
assert_grep "T-06 PR-less path is work memory" "$CONV" \
  '作業メモリの「決定事項・メモ」'
assert_grep "T-06 gate stays enabled" "$CONV" \
  'ゲート自体は無効化しない'
assert_grep "T-06 fix Root Cause Gate reads overflow" "$FIX" \
  'commit-overflow-record.sh'

# --- T-01 / T-02 / T-09: fixture convention → generated message; rewrite is re-read ---
repo="$(new_repo)"
def=$(mktemp "${TMPDIR:-/tmp}/rite-inv-def-XXXXXX")
printf 'chore(wiki): default-absent\n' > "$def"
got=$(bash "$MSG" --default-file "$def" --root "$repo")
assert "T-02 absent files use helper default" "chore(wiki): default-absent" "$(printf '%s' "$got" | tr -d '\n')"

printf 'Commits must be English.\nSubject form: feat(scope): description\nBody is required.\n' > "$repo/CLAUDE.md"
en_msg=$(mktemp "${TMPDIR:-/tmp}/rite-inv-en-XXXXXX")
printf 'feat(wiki): english subject\n\nwhy the first convention applies\n' > "$en_msg"
printf 'first\n' >> "$repo/README"
git -C "$repo" add README
en_rc=0
bash "$COMMIT" --file "$en_msg" --worktree "$repo" -- --quiet || en_rc=$?
assert "T-01 first convention commit exits 0" "0" "$en_rc"
assert "T-01 first subject follows English fixture" "feat(wiki): english subject" "$(git -C "$repo" log -1 --format=%s)"
if git -C "$repo" log -1 --format=%b | grep -q 'why the first convention applies'; then
  pass "T-01 first body follows English fixture"
else
  fail "T-01 first body missing: $(git -C "$repo" log -1 --format=%b)"
fi

printf '件名は日本語。形式: 種別: 説明。本文に理由を書く。\n' > "$repo/CLAUDE.md"
ja_msg=$(mktemp "${TMPDIR:-/tmp}/rite-inv-ja-XXXXXX")
printf 'docs(wiki): 日本語の件名\n\n二回目の規約を使う\n' > "$ja_msg"
printf 'second\n' >> "$repo/README"
git -C "$repo" add README
ja_rc=0
bash "$COMMIT" --file "$ja_msg" --worktree "$repo" -- --quiet || ja_rc=$?
assert "T-09 second generation after rewrite exits 0" "0" "$ja_rc"
assert "T-09 second subject follows rewritten fixture" "docs(wiki): 日本語の件名" "$(git -C "$repo" log -1 --format=%s)"
if git -C "$repo" log -1 --format=%b | grep -q '二回目の規約を使う'; then
  pass "T-09 second body follows rewritten fixture"
else
  fail "T-09 second body missing: $(git -C "$repo" log -1 --format=%b)"
fi
if git -C "$repo" log -1 --format=%s | grep -q 'english subject'; then
  fail "T-09 second commit reused the first convention"
else
  pass "T-09 second commit does not reuse the first subject"
fi
if find "$repo/.rite" -name '*.flow-state' 2>/dev/null | grep -q .; then
  fail "T-09 flow-state cache appeared under the fixture"
else
  pass "T-09 no flow-state convention cache"
fi
rm -f "$def" "$en_msg" "$ja_msg"

# --- T-04 already covered by locate test; re-observe wiki cwd here ---
wiki_repo="$(new_repo)"
orig=$(git -C "$wiki_repo" branch --show-current)
printf 'English commits only.\n' > "$wiki_repo/CLAUDE.md"
git -C "$wiki_repo" add CLAUDE.md && git -C "$wiki_repo" commit -qm claude
git -C "$wiki_repo" checkout -q --orphan wiki
git -C "$wiki_repo" rm -rfq --ignore-unmatch .
mkdir -p "$wiki_repo/.rite/wiki"
printf 'wiki\n' > "$wiki_repo/.rite/wiki/index.md"
git -C "$wiki_repo" add .rite/wiki && git -C "$wiki_repo" commit -qm wiki-init
git -C "$wiki_repo" checkout -q "$orig"
git -C "$wiki_repo" worktree add -q "$wiki_repo/.rite/wiki-worktree" wiki
wiki_out=$(cd "$wiki_repo/.rite/wiki-worktree" && bash "$LOCATE")
assert "T-04 wiki cwd PRESENT=1" "1" "$(printf '%s\n' "$wiki_out" | sed -n 's/^COMMIT_CONVENTION_PRESENT=//p')"
assert "T-04 wiki cwd CLAUDE is shared root" "$wiki_repo/CLAUDE.md" "$(printf '%s\n' "$wiki_out" | sed -n 's/^CLAUDE_MD=//p')"

# --- T-08: overflow write failure is not reported as stored ---
nowrite="$(mktemp -d)"
SANDBOXES+=("$nowrite")
chmod 500 "$nowrite"
bodyf=$(mktemp "${TMPDIR:-/tmp}/rite-inv-ov-XXXXXX")
printf 'root cause that must not vanish\n' > "$bodyf"
fail_rc=0
fail_err=$(bash "$OVERFLOW" write --file "$nowrite/blocked.md" --section "Root cause" --body-file "$bodyf" 2>&1) || fail_rc=$?
chmod 700 "$nowrite"
assert "T-08 unwritable overflow exits 1" "1" "$fail_rc"
if [ -f "$nowrite/blocked.md" ]; then
  fail "T-08 failed write left a store file"
else
  pass "T-08 failed write left no store file"
fi
rm -f "$bodyf"

# --- T-10: quotes / newlines / command-like text stay data on -F and --message-file ---
spec_repo="$(new_repo)"
printf 'changed\n' >> "$spec_repo/README"
git -C "$spec_repo" add README
spec_msg=$(mktemp "${TMPDIR:-/tmp}/rite-inv-spec-XXXXXX")
printf 'feat(wiki): quotes '\'' and "double"\n\nbody with `date` and $(whoami)\nsecond line\n' > "$spec_msg"
spec_rc=0
bash "$COMMIT" --file "$spec_msg" --worktree "$spec_repo" -- --quiet || spec_rc=$?
assert "T-10 git-commit-file special chars exit 0" "0" "$spec_rc"
spec_body=$(git -C "$spec_repo" log -1 --format=%b)
if printf '%s' "$spec_body" | grep -q '`date`' \
   && printf '%s' "$spec_body" | grep -q '$(whoami)' \
   && printf '%s' "$spec_body" | grep -q 'second line'; then
  pass "T-10 -F keeps quotes/newlines/command-like text"
else
  fail "T-10 -F mutated message: $spec_body"
fi
rm -f "$spec_msg"
assert_grep "T-10 squash uses --body-file not --body var" "$MERGE" \
  'body-file "\{squash_body_file\}"'
assert_not_grep "T-10 squash does not pass --body \"\$var\"" "$MERGE" \
  '[[:space:]]--body "\$'

# --- helper auto-path: wiki-init / wiki-ingest-commit with and without convention files ---
init_repo="$(new_repo)"
mkdir -p "$init_repo/.rite/wiki/pages/patterns" "$init_repo/.rite/wiki/raw/reviews"
printf '# index\n' > "$init_repo/.rite/wiki/index.md"
init_rc=0
init_out=$(cd "$init_repo" && bash "$WIKI_INIT" --branch-strategy same_branch --wiki-branch wiki 2>&1) || init_rc=$?
assert "T-02 wiki-init absent files uses default (rc 0)" "0" "$init_rc"
assert "T-02 wiki-init default subject" "feat(wiki): initialize Wiki structure" "$(git -C "$init_repo" log -1 --format=%s)"

conv_repo="$(new_repo)"
mkdir -p "$conv_repo/.rite/wiki/pages/patterns"
printf '# index\n' > "$conv_repo/.rite/wiki/index.md"
printf 'English only.\n' > "$conv_repo/CLAUDE.md"
conv_rc=0
conv_err=$(cd "$conv_repo" && bash "$WIKI_INIT" --branch-strategy same_branch --wiki-branch wiki 2>&1) || conv_rc=$?
assert "T-03 wiki-init CLAUDE.md without --message-file exits 1" "1" "$conv_rc"
if printf '%s' "$conv_err" | grep -q -- '--message-file'; then
  pass "T-03 wiki-init fail-loud names --message-file"
else
  fail "T-03 wiki-init diagnostic: $conv_err"
fi
passed=$(mktemp "${TMPDIR:-/tmp}/rite-inv-init-XXXXXX")
printf 'feat(wiki): custom with `date`\n\nwhy from file\n' > "$passed"
pass_repo="$(new_repo)"
mkdir -p "$pass_repo/.rite/wiki/pages/patterns"
printf '# index\n' > "$pass_repo/.rite/wiki/index.md"
printf 'English only.\n' > "$pass_repo/CLAUDE.md"
pass_rc=0
(cd "$pass_repo" && bash "$WIKI_INIT" --branch-strategy same_branch --wiki-branch wiki --message-file "$passed") >/dev/null || pass_rc=$?
assert "T-03 wiki-init --message-file with CLAUDE.md exits 0" "0" "$pass_rc"
assert "T-03 wiki-init uses passed subject" "feat(wiki): custom with \`date\`" "$(git -C "$pass_repo" log -1 --format=%s)"
if git -C "$pass_repo" log -1 --format=%B | grep -q '`date`'; then
  pass "T-10 wiki-init --message-file keeps backtick text"
else
  fail "T-10 wiki-init lost backticks: $(git -C "$pass_repo" log -1 --format=%B)"
fi
rm -f "$passed"

# same_branch wiki-ingest-commit default vs --message-file
ing_repo="$(new_repo)"
printf '%s\n' 'wiki:' '  enabled: true' '  branch_strategy: same_branch' '  branch_name: wiki' > "$ing_repo/rite-config.yml"
git -C "$ing_repo" add rite-config.yml && git -C "$ing_repo" commit -qm config
mkdir -p "$ing_repo/.rite/wiki/raw/reviews"
printf '%s\n' '---' 'ingested: false' '---' 'raw' > "$ing_repo/.rite/wiki/raw/reviews/pr-test.md"
ing_rc=0
ing_out=$(cd "$ing_repo" && bash "$WIKI_INGEST" 2>&1) || ing_rc=$?
assert "T-02 wiki-ingest-commit absent files rc 0" "0" "$ing_rc"
assert "T-02 wiki-ingest-commit default subject" "chore(wiki): ingest 1 raw source(s)" "$(git -C "$ing_repo" log -1 --format=%s)"

ing2="$(new_repo)"
printf '%s\n' 'wiki:' '  enabled: true' '  branch_strategy: same_branch' '  branch_name: wiki' > "$ing2/rite-config.yml"
git -C "$ing2" add rite-config.yml && git -C "$ing2" commit -qm config
mkdir -p "$ing2/.rite/wiki/raw/reviews"
printf '%s\n' '---' 'ingested: false' '---' 'raw' > "$ing2/.rite/wiki/raw/reviews/pr-test.md"
printf 'English only.\n' > "$ing2/CLAUDE.md"
ing2_rc=0
ing2_err=$(cd "$ing2" && bash "$WIKI_INGEST" 2>&1) || ing2_rc=$?
assert "T-03 wiki-ingest-commit CLAUDE.md without --message-file exits 1" "1" "$ing2_rc"

ing3="$(new_repo)"
printf '%s\n' 'wiki:' '  enabled: true' '  branch_strategy: same_branch' '  branch_name: wiki' > "$ing3/rite-config.yml"
git -C "$ing3" add rite-config.yml && git -C "$ing3" commit -qm config
mkdir -p "$ing3/.rite/wiki/raw/reviews"
printf '%s\n' '---' 'ingested: false' '---' 'raw' > "$ing3/.rite/wiki/raw/reviews/pr-test.md"
printf 'English only.\n' > "$ing3/CLAUDE.md"
ing3_msg=$(mktemp "${TMPDIR:-/tmp}/rite-inv-wic-XXXXXX")
printf 'docs(wiki): ingest with `tick`\n\n$(whoami) stays literal\n' > "$ing3_msg"
ing3_rc=0
(cd "$ing3" && bash "$WIKI_INGEST" --message-file "$ing3_msg") >/dev/null || ing3_rc=$?
assert "T-03 wiki-ingest-commit --message-file rc 0" "0" "$ing3_rc"
assert "T-03 wiki-ingest-commit uses passed subject" "docs(wiki): ingest with \`tick\`" "$(git -C "$ing3" log -1 --format=%s)"
if git -C "$ing3" log -1 --format=%b | grep -q '$(whoami) stays literal'; then
  pass "T-10 wiki-ingest-commit --message-file keeps command-like text"
else
  fail "T-10 wiki-ingest-commit mutated body: $(git -C "$ing3" log -1 --format=%b)"
fi
rm -f "$ing3_msg"

# worktree-git argv contract remains 3rd-argument message (internal -F)
assert_grep "T-03 worktree_commit_push argv is still COMMIT_MSG" \
  "$PLUGIN_ROOT/hooks/scripts/lib/worktree-git.sh" \
  'worktree_commit_push "\$worktree_path" "\$wiki_branch" "\$commit_msg"'
assert_grep "T-03 worktree_commit_push commits via -F" \
  "$PLUGIN_ROOT/hooks/scripts/lib/worktree-git.sh" \
  'git -C "\$worktree" commit --quiet -F "\$msg_file"'

# wiki-worktree-commit still rejects --message newlines
assert_file_exists_or_fail "wiki-worktree-commit helper" "$WIKI_WT" || true

if ! print_summary "commit-convention-inventory.test.sh"; then
  exit 1
fi
