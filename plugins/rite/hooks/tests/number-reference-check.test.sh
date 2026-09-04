#!/bin/bash
# Tests for number-reference-check.sh
# Usage: bash plugins/rite/hooks/tests/number-reference-check.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
REPO_ROOT="$(_helpers_resolve_repo_root "$SCRIPT_DIR")"
TARGET="$PLUGIN_ROOT/hooks/scripts/number-reference-check.sh"
LINT_SKILL="$PLUGIN_ROOT/skills/lint/SKILL.md"
PR_REVIEW_SKILL="$PLUGIN_ROOT/skills/pr-review/SKILL.md"
FIX_SKILL="$PLUGIN_ROOT/skills/fix/SKILL.md"
IMPLEMENT_SKILL="$PLUGIN_ROOT/skills/issue-implement/SKILL.md"
ISSUE_CLOSE_SKILL="$PLUGIN_ROOT/skills/issue-close/SKILL.md"

if [ ! -x "$TARGET" ] && [ ! -f "$TARGET" ]; then
  echo "ERROR: helper not found: $TARGET" >&2
  exit 1
fi

cleanup_dirs=()
cleanup() {
  local p
  for p in "${cleanup_dirs[@]:-}"; do [ -n "$p" ] && rm -rf "$p"; done
}
trap cleanup EXIT

init_git_sb() {
  local sb="$1"
  git -C "$sb" init -q
  git -C "$sb" config user.email test@example.com
  git -C "$sb" config user.name test
}

commit_all() {
  local sb="$1" msg="$2"
  git -C "$sb" add -A
  git -C "$sb" commit -qm "$msg"
}

run_all() {
  local sb="$1"
  shift
  bash "$TARGET" --all --repo-root "$sb" "$@"
}

run_diff() {
  local sb="$1" base="$2"
  shift 2
  bash "$TARGET" --diff "$base" --repo-root "$sb" "$@"
}

echo "=== number-reference-check.sh ==="

# --------------------------------------------------------------------------
# CLI contract
# --------------------------------------------------------------------------
sb=$(make_plain_sandbox) && cleanup_dirs+=("$sb") || { echo "ERROR: sandbox" >&2; exit 1; }
init_git_sb "$sb"

rc=0; bash "$TARGET" --repo-root "$sb" >/dev/null 2>&1 || rc=$?
assert "no mode → exit 2" "2" "$rc"

rc=0; bash "$TARGET" --target foo.md --repo-root "$sb" >/dev/null 2>&1 || rc=$?
assert "unknown --target → exit 2" "2" "$rc"

rc=0; bash "$TARGET" --bogus --repo-root "$sb" >/dev/null 2>&1 || rc=$?
assert "unknown argument → exit 2" "2" "$rc"

rc=0; bash "$TARGET" --diff --repo-root "$sb" >/dev/null 2>&1 || rc=$?
assert "--diff without base → exit 2" "2" "$rc"

rc=0; bash "$TARGET" --stdin >/dev/null 2>&1 || rc=$?
assert "--stdin without --label → exit 2" "2" "$rc"

rc=0; bash "$TARGET" --all --label x --repo-root "$sb" >/dev/null 2>&1 || rc=$?
assert "--label without --stdin → exit 2" "2" "$rc"

rc=0; bash "$TARGET" --all --diff HEAD --repo-root "$sb" >/dev/null 2>&1 || rc=$?
assert "exclusive --all and --diff → exit 2" "2" "$rc"

rc=0; out=$(bash "$TARGET" --repo-root /nonexistent/rite-xyz --all 2>&1) || rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'repo-root not a directory'; then
  pass "bad --repo-root → exit 2"
else
  fail "bad --repo-root expected rc=2 with ERROR, got rc=$rc: $out"
fi

# --------------------------------------------------------------------------
# T-12: unresolved --diff base
# --------------------------------------------------------------------------
printf 'clean\n' > "$sb/README.md"
commit_all "$sb" init
rc=0; out=$(run_diff "$sb" does-not-exist 2>&1) || rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'ERROR'; then
  pass "T-12 unresolved base → exit 2 + ERROR"
else
  fail "T-12 expected rc=2 + ERROR, got rc=$rc: $out"
fi

# --------------------------------------------------------------------------
# T-01 --diff: pre-existing / added / uncommitted / deletion
# --------------------------------------------------------------------------
mkdir -p "$sb/plugins/rite/skills/x"
printf 'pre-existing token (#1500)\n' > "$sb/plugins/rite/skills/x/SKILL.md"
commit_all "$sb" base
base=$(git -C "$sb" rev-parse HEAD)

printf 'clean addition\n' >> "$sb/plugins/rite/skills/x/SKILL.md"
commit_all "$sb" clean
rc=0; out=$(run_diff "$sb" "$base" --quiet 2>&1) || rc=$?
assert "T-01(a) pre-existing on base is not prosecuted" "0" "$rc"

printf 'added token (#1600)\n' >> "$sb/plugins/rite/skills/x/SKILL.md"
commit_all "$sb" added
rc=0; out=$(run_diff "$sb" HEAD~1 --quiet 2>&1) || rc=$?
if [ "$rc" -eq 1 ] \
   && printf '%s' "$out" | grep -qE '^plugins/rite/skills/x/SKILL.md:[0-9]+: added token \(#1600\)$' \
   && printf '%s' "$out" | grep -q 'Total number-ref findings: 1'; then
  pass "T-01(b) added + line → exit 1 + file:line: matched line + summary"
else
  fail "T-01(b) expected rc=1 with stdout format, got rc=$rc: $out"
fi

printf 'uncommitted token (#1700)\n' >> "$sb/plugins/rite/skills/x/SKILL.md"
rc=0; out=$(run_diff "$sb" HEAD --quiet 2>&1) || rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '#1700' \
   && printf '%s' "$out" | grep -q 'Total number-ref findings:'; then
  pass "T-01(c) uncommitted + line is detected"
else
  fail "T-01(c) expected rc=1 with uncommitted hit, got rc=$rc: $out"
fi
git -C "$sb" checkout -- plugins/rite/skills/x/SKILL.md

# deletion of a numbered line must not hit
printf 'keep\nnumbered (#1800)\n' > "$sb/plugins/rite/skills/x/SKILL.md"
commit_all "$sb" before-del
printf 'keep\n' > "$sb/plugins/rite/skills/x/SKILL.md"
commit_all "$sb" after-del
rc=0; out=$(run_diff "$sb" HEAD~1 --quiet 2>&1) || rc=$?
assert "T-01(d) deleted numbered line is not a hit" "0" "$rc"

# --------------------------------------------------------------------------
# T-02 Issue #N / PR #N share the same grammar
# --------------------------------------------------------------------------
issue_label=Issue
pr_label=PR
number_mark='#'
printf '%s %s1234 rationale\n%s %s367 loader\n' \
  "$issue_label" "$number_mark" "$pr_label" "$number_mark" \
  > "$sb/plugins/rite/skills/x/SKILL.md"
commit_all "$sb" prose-forms
rc=0; out=$(run_diff "$sb" HEAD~1 --quiet 2>&1) || rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '#1234' && printf '%s' "$out" | grep -q '#367'; then
  pass "T-02 Issue/PR prose forms detected"
else
  fail "T-02 expected both prose forms, got rc=$rc: $out"
fi

# --------------------------------------------------------------------------
# T-03 anchors / placeholder / ignore
# --------------------------------------------------------------------------
printf '#100-letter heading\nplaceholder #123 stays\nhistorical (#1900) drift-check-ignore\n' \
  > "$sb/plugins/rite/skills/x/SKILL.md"
commit_all "$sb" exclusions
rc=0; out=$(run_diff "$sb" HEAD~1 --quiet 2>&1) || rc=$?
assert "T-03 anchor / #123 / ignore → hit 0" "0" "$rc"

# adjacent pin: #123 excluded, #1234 detected
printf 'skip #123 and catch #1234 here\n' > "$sb/plugins/rite/skills/x/SKILL.md"
commit_all "$sb" adjacent
rc=0; out=$(run_diff "$sb" HEAD~1 --quiet 2>&1) || rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '#1234' \
   && [ "$(printf '%s' "$out" | grep -c 'Total number-ref findings: 1' || true)" -eq 1 ]; then
  pass "T-03 adjacent #123 skip / #1234 hit"
else
  fail "T-03 adjacent pin failed rc=$rc: $out"
fi

# hyphen + digit is not an anchor
printf 'not-anchor (#200-1)\n' > "$sb/plugins/rite/skills/x/SKILL.md"
commit_all "$sb" hyphen-digit
rc=0; out=$(run_diff "$sb" HEAD~1 --quiet 2>&1) || rc=$?
assert "T-03 hyphen+digit is not an anchor" "1" "$rc"

# word-char after 3-4 digits is not a bare number (heading id / hex color)
hex_color='161B22'
heading_id='530c'
bare_token='2045'
printf 'link to assessment-rules.md#%s-class\ncolor #%s\nreal token (#%s)\n' \
  "$heading_id" "$hex_color" "$bare_token" \
  > "$sb/plugins/rite/skills/x/SKILL.md"
commit_all "$sb" word-char
rc=0; out=$(run_diff "$sb" HEAD~1 --quiet 2>&1) || rc=$?
if [ "$rc" -eq 1 ] \
   && printf '%s' "$out" | grep -qE "real token \\(#${bare_token}\\)" \
   && ! printf '%s' "$out" | grep -q "${heading_id}-class" \
   && ! printf '%s' "$out" | grep -q "$hex_color"; then
  pass "word-char after digits miss; bare token hit (--diff)"
else
  fail "word-char skip failed rc=$rc: $out"
fi

rc=0; out=$(printf 'link to assessment-rules.md#%s-class\ncolor #%s\nreal token (#%s)\n' \
  "$heading_id" "$hex_color" "$bare_token" \
  | bash "$TARGET" --stdin --label probe.md --quiet 2>&1) || rc=$?
if [ "$rc" -eq 1 ] \
   && printf '%s' "$out" | grep -qE "^probe.md:3: real token \\(#${bare_token}\\)$" \
   && ! printf '%s' "$out" | grep -q 'probe.md:1:' \
   && ! printf '%s' "$out" | grep -q 'probe.md:2:'; then
  pass "word-char after digits miss; bare token hit (--stdin)"
else
  fail "word-char --stdin failed rc=$rc: $out"
fi

# --------------------------------------------------------------------------
# Band: #100 / #9999 hit, #99 / #12345 miss
# --------------------------------------------------------------------------
printf 'lower (#100)\nupper (#9999)\nbelow #99\nabove #12345\n' > "$sb/plugins/rite/skills/x/SKILL.md"
commit_all "$sb" band
rc=0; out=$(run_diff "$sb" HEAD~1 --quiet 2>&1) || rc=$?
if [ "$rc" -eq 1 ] \
   && printf '%s' "$out" | grep -qE '\(#100\)' \
   && printf '%s' "$out" | grep -qE '\(#9999\)' \
   && ! printf '%s' "$out" | grep -qE 'below #99' \
   && ! printf '%s' "$out" | grep -qE 'above #12345'; then
  pass "band #100/#9999 hit, #99/#12345 miss"
else
  fail "band boundaries failed rc=$rc: $out"
fi

# --------------------------------------------------------------------------
# T-04 path exclusions — all five contracted paths
# --------------------------------------------------------------------------
mkdir -p "$sb/.rite/wiki/raw" \
  "$sb/.rite/wiki/raw-notes" \
  "$sb/plugins/rite/scripts/tests/fixtures" \
  "$sb/plugins/rite/scripts/tests/fixtures-other" \
  "$sb/plugins/rite/hooks/tests"
printf 'raw (#2100)\n' > "$sb/.rite/wiki/raw/note.md"
printf 'fixture (#2101)\n' > "$sb/plugins/rite/scripts/tests/fixtures/x.md"
printf 'self (#2102)\n' > "$sb/plugins/rite/hooks/tests/number-reference-check.test.sh"
printf 'cjc (#2103)\n' > "$sb/plugins/rite/hooks/tests/comment-journal-check.test.sh"
printf 'wiki (#2104)\n' > "$sb/plugins/rite/hooks/tests/wiki-lint-descriptive-refs.test.sh"
printf 'other (#2105)\n' > "$sb/plugins/rite/hooks/tests/other.test.sh"
printf 'raw sibling (#2106)\n' > "$sb/.rite/wiki/raw-notes/x.md"
printf 'fixture sibling (#2107)\n' > "$sb/plugins/rite/scripts/tests/fixtures-other/x.md"
printf 'clean surface\n' > "$sb/plugins/rite/skills/x/SKILL.md"
commit_all "$sb" path-excl

rc=0; out=$(run_all "$sb" --quiet 2>&1) || rc=$?
if [ "$rc" -eq 1 ] \
   && printf '%s' "$out" | grep -q 'hooks/tests/other.test.sh' \
   && printf '%s' "$out" | grep -q 'wiki/raw-notes/x.md' \
   && printf '%s' "$out" | grep -q 'scripts/tests/fixtures-other/x.md' \
   && ! printf '%s' "$out" | grep -q 'wiki/raw/' \
   && ! printf '%s' "$out" | grep -q 'scripts/tests/fixtures/' \
   && ! printf '%s' "$out" | grep -q 'number-reference-check.test.sh' \
   && ! printf '%s' "$out" | grep -q 'comment-journal-check.test.sh' \
   && ! printf '%s' "$out" | grep -q 'wiki-lint-descriptive-refs.test.sh'; then
  pass "T-04 --all excluded 5 paths miss; other hooks/tests hit"
else
  fail "T-04 --all path exclusions failed rc=$rc: $out"
fi

rc=0; out=$(run_diff "$sb" HEAD~1 --quiet 2>&1) || rc=$?
if [ "$rc" -eq 1 ] \
   && printf '%s' "$out" | grep -q 'hooks/tests/other.test.sh' \
   && printf '%s' "$out" | grep -q 'wiki/raw-notes/x.md' \
   && printf '%s' "$out" | grep -q 'scripts/tests/fixtures-other/x.md' \
   && ! printf '%s' "$out" | grep -q 'wiki/raw/' \
   && ! printf '%s' "$out" | grep -q 'scripts/tests/fixtures/' \
   && ! printf '%s' "$out" | grep -q 'number-reference-check.test.sh' \
   && ! printf '%s' "$out" | grep -q 'comment-journal-check.test.sh' \
   && ! printf '%s' "$out" | grep -q 'wiki-lint-descriptive-refs.test.sh'; then
  pass "T-04 --diff excluded 5 paths miss; other hooks/tests hit"
else
  fail "T-04 --diff path exclusions failed rc=$rc: $out"
fi

for excluded_path in \
  .rite/wiki/raw/nested.md \
  plugins/rite/scripts/tests/fixtures/nested.md \
  plugins/rite/hooks/tests/number-reference-check.test.sh \
  plugins/rite/hooks/tests/comment-journal-check.test.sh \
  plugins/rite/hooks/tests/wiki-lint-descriptive-refs.test.sh; do
  rc=0; out=$(printf 'excluded token (#2106)\n' \
    | bash "$TARGET" --stdin --label "$excluded_path" --quiet 2>&1) || rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'Total number-ref findings: 0'; then
    pass "T-04 --stdin excludes $excluded_path"
  else
    fail "T-04 --stdin expected exclusion for $excluded_path, got rc=$rc: $out"
  fi
done

rc=0; out=$(printf 'sibling token (#2107)\n' \
  | bash "$TARGET" --stdin --label plugins/rite/hooks/tests/other.test.sh --quiet 2>&1) || rc=$?
if [ "$rc" -eq 1 ] \
   && printf '%s' "$out" | grep -q '^plugins/rite/hooks/tests/other.test.sh:1:' \
   && printf '%s' "$out" | grep -q 'Total number-ref findings: 1'; then
  pass "T-04 --stdin scans sibling path"
else
  fail "T-04 --stdin expected sibling hit, got rc=$rc: $out"
fi

for sibling_path in .rite/wiki/raw-notes/x.md plugins/rite/scripts/tests/fixtures-other/x.md; do
  rc=0; out=$(printf 'directory sibling token (#2113)\n' \
    | bash "$TARGET" --stdin --label "$sibling_path" --quiet 2>&1) || rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "^$sibling_path:1:" \
     && printf '%s' "$out" | grep -q 'Total number-ref findings: 1'; then
    pass "T-04 --stdin scans directory sibling $sibling_path"
  else
    fail "T-04 --stdin expected directory sibling hit for $sibling_path, got rc=$rc: $out"
  fi
done

# Directory prefixes are boundaries: the root and descendants are excluded,
# while merely similar prefixes remain in scope.
for excluded_label in .rite/wiki/raw .rite/wiki/raw/child.md; do
  rc=0; out=$(printf 'excluded token (#2108)\n' \
    | bash "$TARGET" --stdin --label "$excluded_label" --quiet 2>&1) || rc=$?
  assert "T-04 directory boundary excludes $excluded_label" "0" "$rc"
done
rc=0; out=$(printf 'prefix sibling (#2109)\n' \
  | bash "$TARGET" --stdin --label .rite/wiki/raw-notes/x.md --quiet 2>&1) || rc=$?
assert "T-04 similar directory prefix remains in scope" "1" "$rc"

# Both chunk orders pin that an excluded file cannot leak skip state into the
# following included file (or vice versa).
printf 'excluded base\n' > "$sb/.rite/wiki/raw/note.md"
printf 'included base\n' > "$sb/plugins/rite/hooks/tests/other.test.sh"
printf 'excluded fixture base\n' > "$sb/plugins/rite/scripts/tests/fixtures/x.md"
commit_all "$sb" diff-chunk-reset-base
printf 'excluded changed (#2110)\n' > "$sb/.rite/wiki/raw/note.md"
printf 'included changed (#2111)\n' > "$sb/plugins/rite/hooks/tests/other.test.sh"
printf 'excluded fixture changed (#2112)\n' > "$sb/plugins/rite/scripts/tests/fixtures/x.md"
rc=0; out=$(run_diff "$sb" HEAD --quiet 2>&1) || rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '#2111' \
   && ! printf '%s' "$out" | grep -q '#2110' \
   && ! printf '%s' "$out" | grep -q '#2112' \
   && printf '%s' "$out" | grep -q 'Total number-ref findings: 1'; then
  pass "T-04 --diff resets skip state across included/excluded chunks"
else
  fail "T-04 --diff chunk reset failed rc=$rc: $out"
fi
git -C "$sb" checkout -q -- .

# The five path literals are data in one Bash definition, never copied into awk.
script_without_header=$(sed -n '/^set -uo pipefail/,$p' "$TARGET")
for exclusion_literal in \
  .rite/wiki/raw/ \
  plugins/rite/scripts/tests/fixtures/ \
  plugins/rite/hooks/tests/number-reference-check.test.sh \
  plugins/rite/hooks/tests/comment-journal-check.test.sh \
  plugins/rite/hooks/tests/wiki-lint-descriptive-refs.test.sh; do
  literal_count=$(printf '%s\n' "$script_without_header" | grep -F -c "$exclusion_literal")
  assert "T-04 exclusion literal has one non-header definition: $exclusion_literal" "1" "$literal_count"
done

# --------------------------------------------------------------------------
# T-04b --path narrows --diff to a pathspec (scan range == commit range)
# --------------------------------------------------------------------------
mkdir -p "$sb/.rite/wiki/pages" "$sb/src"
printf 'clean wiki page\n' > "$sb/.rite/wiki/pages/p.md"
printf 'clean source\n' > "$sb/src/a.md"
commit_all "$sb" path-scope-base
printf 'wiki page with (#1300)\n' > "$sb/.rite/wiki/pages/p.md"
printf 'source with (#1301)\n' > "$sb/src/a.md"

rc=0; out=$(run_diff "$sb" HEAD --path .rite/wiki --quiet 2>&1) || rc=$?
if [ "$rc" -eq 1 ] \
   && printf '%s' "$out" | grep -q '.rite/wiki/pages/p.md' \
   && ! printf '%s' "$out" | grep -q 'src/a.md'; then
  pass "T-04b --path limits findings to the pathspec"
else
  fail "T-04b --path scoping failed rc=$rc: $out"
fi

# Without --path the same tree reports both (proves the option is load-bearing)
rc=0; out=$(run_diff "$sb" HEAD --quiet 2>&1) || rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'src/a.md'; then
  pass "T-04b without --path the out-of-scope file is reported"
else
  fail "T-04b baseline (no --path) failed rc=$rc: $out"
fi

# A pathspec that only contains clean changes is clean (rc=0), not silently skipped
printf 'wiki page clean again\n' > "$sb/.rite/wiki/pages/p.md"
rc=0; out=$(run_diff "$sb" HEAD --path .rite/wiki --quiet 2>&1) || rc=$?
if [ "$rc" -eq 0 ]; then
  pass "T-04b --path with clean changes exits 0"
else
  fail "T-04b --path clean case failed rc=$rc: $out"
fi

# --path is rejected outside --diff (no silent no-op)
rc=0; out=$(bash "$TARGET" --all --path .rite/wiki --repo-root "$sb" --quiet 2>&1) || rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q -- '--path is only valid with --diff'; then
  pass "T-04b --path outside --diff is an invocation error"
else
  fail "T-04b --path misuse not rejected rc=$rc: $out"
fi

# --path as the final argument (真の空値ブランチ) — message まで見ないと、--path アームを
# 丸ごと削った変異が unknown-argument の同じ rc=2 で通ってしまう
rc=0; out=$(bash "$TARGET" --repo-root "$sb" --quiet --diff HEAD --path 2>&1) || rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q -- '--path requires a directory'; then
  pass "T-04b --path without a value is an invocation error"
else
  fail "T-04b --path empty value not rejected rc=$rc: $out"
fi

# --path followed by another flag (ダッシュ接頭辞ブランチ) — 次の引数を値として食わない
rc=0; out=$(bash "$TARGET" --diff HEAD --path --repo-root "$sb" --quiet 2>&1) || rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q -- '--path requires a directory'; then
  pass "T-04b --path does not swallow the next flag as its value"
else
  fail "T-04b --path dash-prefixed value not rejected rc=$rc: $out"
fi

# 一致しないパスは「検査済みの clean」ではなく invocation error（走査母数 0 の silent-0 を塞ぐ）
rc=0; out=$(bash "$TARGET" --diff HEAD --path no/such/dir --repo-root "$sb" --quiet 2>&1) || rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q -- '--path が repo 内のどのパスにも一致しません'; then
  pass "T-04b --path with a non-matching pathspec is an invocation error"
else
  fail "T-04b --path non-matching pathspec not rejected rc=$rc: $out"
fi

# 実在するが tracked も staged も 0 件のディレクトリ — 本番呼び出し (--path .rite/wiki) と
# 同じ shape。ディレクトリの実在を免除条件にすると、この silent-0 の主要形が素通りする
mkdir -p "$sb/empty_dir"
rc=0; out=$(run_diff "$sb" HEAD --path empty_dir --quiet 2>&1) || rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q -- '--path が repo 内のどのパスにも一致しません'; then
  pass "T-04b --path with an existing but untracked directory is an invocation error"
else
  fail "T-04b --path empty-but-existing dir not rejected rc=$rc: $out"
fi
# untracked ファイルだけを含むディレクトリも母数 0 なので同じ扱い
printf 'PR #1305 を参照\n' > "$sb/empty_dir/u.md"
rc=0; out=$(run_diff "$sb" HEAD --path empty_dir --quiet 2>&1) || rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q -- '--path が repo 内のどのパスにも一致しません'; then
  pass "T-04b --path with untracked-only content is an invocation error"
else
  fail "T-04b --path untracked-only dir not rejected rc=$rc: $out"
fi
rm -rf "$sb/empty_dir"

# staged deletion のみの pathspec — ls-files は空だが git diff HEAD は削除 hunk を返す。
# 「diff が空のときだけ error にする」変異はこの shape でしか死なない
# commit_all は add -A なので、それまでの一時的な dirty をまとめて HEAD へ昇格させてしまう。
# この TC が触るパスだけを commit する
mkdir -p "$sb/deldir"
printf 'clean\n' > "$sb/deldir/a.md"
git -C "$sb" add deldir || fail "T-04b staged-deletion fixture の add に失敗"
git -C "$sb" commit -qm del-base || fail "T-04b staged-deletion fixture の commit に失敗"
git -C "$sb" rm -q --cached deldir/a.md
printf 'number here (#1500)\n' > "$sb/deldir/a.md"
rc=0; out=$(run_diff "$sb" HEAD --path deldir --quiet 2>&1) || rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q -- '--path が repo 内のどのパスにも一致しません'; then
  pass "T-04b --path with only staged deletions is an invocation error"
else
  fail "T-04b --path staged-deletion-only not rejected rc=$rc: $out"
fi
# index を HEAD へ戻す (checkout -q -- . では index の削除が残り後続へ漏れる)。
# deldir/a.md は HEAD に残るが内容は 'clean' で、後続の走査に findings を足さない
git -C "$sb" reset -q || fail "T-04b index 復元 (reset) に失敗（以降のケースが汚染された index で走る）"

# restore the tree for the following cases (失敗を握り潰すと後続 T-05+ が汚染ツリーで走り、
# 原因が「T-04b の片付け失敗」ではなく無関係な assert の赤として現れる)
git -C "$sb" checkout -q -- . || fail "T-04b 後片付けの checkout に失敗（以降のケースが汚染されたツリーで走る）"

# --------------------------------------------------------------------------
# T-05 --all detects newly tracked files without a target list
# --------------------------------------------------------------------------
mkdir -p "$sb/docs"
printf 'new tracked (#2200)\n' > "$sb/docs/new.md"
commit_all "$sb" new-tracked
rc=0; out=$(run_all "$sb" --quiet 2>&1) || rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'docs/new.md' && printf '%s' "$out" | grep -q '#2200'; then
  pass "T-05 --all detects newly tracked file"
else
  fail "T-05 expected docs/new.md hit, got rc=$rc: $out"
fi

# CHANGELOG is in scope for --all
printf 'history (#2300)\n' > "$sb/CHANGELOG.md"
commit_all "$sb" changelog
rc=0; out=$(run_all "$sb" --quiet 2>&1) || rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'CHANGELOG.md'; then
  pass "--all scans CHANGELOG"
else
  fail "--all should scan CHANGELOG, got rc=$rc: $out"
fi

# --quiet suppresses Scanning but not the summary
rc=0; err=$(run_all "$sb" --quiet 2>&1 >/dev/null) || rc=$?
if printf '%s' "$err" | grep -q 'Total number-ref findings:' \
   && ! printf '%s' "$err" | grep -q 'Scanning'; then
  pass "--quiet suppresses Scanning, keeps summary"
else
  fail "--quiet contract failed: $err"
fi

# --------------------------------------------------------------------------
# --stdin --label
# --------------------------------------------------------------------------
rc=0; out=$(printf 'stdin token (#2400)\n' | bash "$TARGET" --stdin --label docs/in.md --quiet 2>&1) || rc=$?
if [ "$rc" -eq 1 ] \
   && printf '%s' "$out" | grep -qE '^docs/in.md:1: stdin token \(#2400\)$' \
   && printf '%s' "$out" | grep -q 'Total number-ref findings: 1'; then
  pass "--stdin --label reports with label"
else
  fail "--stdin expected labeled finding, got rc=$rc: $out"
fi

rc=0; out=$(printf 'raw (#2500)\n' | bash "$TARGET" --stdin --label .rite/wiki/raw/x.md --quiet 2>&1) || rc=$?
assert "--stdin excluded label is not scanned" "0" "$rc"

rc=0; out=$(printf 'placeholder #123 only\n' | bash "$TARGET" --stdin --label docs/p.md --quiet 2>&1) || rc=$?
assert "--stdin #123 placeholder is excluded" "0" "$rc"

# --------------------------------------------------------------------------
# T-06 / T-09 / T-11 static pins (SKILL wiring)
# --------------------------------------------------------------------------
assert_grep "T-06 lint Phase 3.5 preamble calls --diff" "$LINT_SKILL" \
  'number-reference-check\.sh --diff'
assert_grep "T-06 lint rc 1|2 routes through error_count" "$LINT_SKILL" \
  'error_count=\$\(\(error_count \+ 1\)\)'
assert_not_grep "T-06 lint no longer invokes retired gate" "$LINT_SKILL" \
  'descriptive-number-diff-gate\.sh'
assert_grep "T-06 pr-review rail calls --diff" "$PR_REVIEW_SKILL" \
  'number-reference-check\.sh --diff'
assert_grep "T-06 pr-review finding uses Verification: canonical form" "$PR_REVIEW_SKILL" \
  '`description` は `Verification:` で始める'
assert_grep "T-06 pr-review finding template starts with Verification: repro bash --diff" "$PR_REVIEW_SKILL" \
  'Verification: repro bash \{plugin_root\}/hooks/scripts/number-reference-check.sh --diff'
assert_grep "T-06 pr-review finding explanation follows the anchor" "$PR_REVIEW_SKILL" \
  '。永続成果物に Issue/PR 番号が追加されている'
assert_grep "T-06 pr-review finding substitutes raw pipe in matched line" "$PR_REVIEW_SKILL" \
  '生のパイプが含まれる場合は `¦` に置換する'
assert_not_grep "T-06 pr-review finding no longer uses same-segment trailing Verification:" "$PR_REVIEW_SKILL" \
  'に同一セグメントの `Verification:`'
assert_not_grep "T-06 pr-review finding does not place explanation before the anchor" "$PR_REVIEW_SKILL" \
  '説明文の後にアンカー'
assert_grep "T-06 pr-review orchestrator reviewer id" "$PR_REVIEW_SKILL" \
  'reviewer: "pr-review"'
assert_not_grep "T-06 pr-review does not skip on cycle-scope" "$PR_REVIEW_SKILL" \
  'number-reference-check.*cycle-scope'
assert_grep "T-06 fix 3.1 self-check calls --diff" "$FIX_SKILL" \
  'number-reference-check\.sh --diff'
assert_grep "T-06 fix 3.1 self-check intent-to-add uses {changed_files}" "$FIX_SKILL" \
  'for f in \{changed_files\}'
assert_grep "T-06 fix 3.1 add -N uses existing-path subset" "$FIX_SKILL" \
  'git add -N -- \$nref_addn'
assert_grep "T-06 fix 3.1 empty {changed_files} skips intent-to-add" "$FIX_SKILL" \
  'if \[ -n "\{changed_files\}" \]'
assert_grep "T-06 fix 3.1 skips missing paths before add -N" "$FIX_SKILL" \
  '\[ -e "\$f" \] && nref_addn='
assert_grep "T-06 fix 3.1 intent-to-add fail-loud ERROR" "$FIX_SKILL" \
  'ERROR: intent-to-add に失敗しました'
assert_not_grep "T-06 fix 3.1 does not use add -N ." "$FIX_SKILL" \
  'add -N[[:space:]]+(\.[[:space:]]|$)'
assert_not_grep "T-06 fix 3.1 does not use add -N -- ." "$FIX_SKILL" \
  'add -N[[:space:]]+--[[:space:]]+\.'
assert_not_grep "T-06 fix 3.1 does not use add -A" "$FIX_SKILL" \
  'add -A'

# AC-4 / T-04: add -N 行 < --diff 行。AC-2 / T-02: その区間に固有 ERROR と [fix:error]
# （既存 --diff rc 分岐の [fix:error] 一致では FAIL）。
fix_skip_line=$(awk '
  /^### 3\.1 Verify Changes/ { s=1 }
  s && /^### 3\.1\.1 / { exit }
  s && /^[[:space:]]*if \[ -n "\{changed_files\}" \]/ { print NR; exit }
' "$FIX_SKILL")
fix_addn_line=$(awk '
  /^### 3\.1 Verify Changes/ { s=1 }
  s && /^### 3\.1\.1 / { exit }
  s && /^[[:space:]]*git add -N -- \$nref_addn/ { print NR; exit }
' "$FIX_SKILL")
fix_diff_line=$(awk '
  /^### 3\.1 Verify Changes/ { s=1 }
  s && /^### 3\.1\.1 / { exit }
  s && /^[[:space:]]*bash \{plugin_root\}\/hooks\/scripts\/number-reference-check\.sh --diff/ { print NR; exit }
' "$FIX_SKILL")
if [ -n "$fix_addn_line" ] && [ -n "$fix_diff_line" ] \
   && [ "$fix_addn_line" -lt "$fix_diff_line" ]; then
  pass "T-06 fix 3.1 add -N precedes --diff"
else
  fail "T-06 expected add -N line < --diff line, got add_n=$fix_addn_line diff=$fix_diff_line"
fi
if [ -n "$fix_skip_line" ] && [ -n "$fix_addn_line" ] \
   && [ "$fix_skip_line" -lt "$fix_addn_line" ]; then
  pass "T-06 fix 3.1 empty-set skip precedes add -N"
else
  fail "T-06 expected empty-set skip before add -N, got skip=$fix_skip_line add_n=$fix_addn_line"
fi
fix_intent_arm=""
if [ -n "$fix_addn_line" ] && [ -n "$fix_diff_line" ]; then
  fix_intent_arm=$(awk -v a="$fix_addn_line" -v d="$fix_diff_line" 'NR > a && NR < d' "$FIX_SKILL")
fi
if printf '%s' "$fix_intent_arm" | grep -q 'ERROR: intent-to-add に失敗しました' \
   && printf '%s' "$fix_intent_arm" | grep -q '\[fix:error\]'; then
  pass "T-06 fix 3.1 intent-to-add arm has unique ERROR and [fix:error]"
else
  fail "T-06 expected intent-to-add ERROR + [fix:error] between add -N and --diff"
fi

# --------------------------------------------------------------------------
# Helper: intent-to-add で未追跡が --diff に載る（既存 $sb は汚さない）
# --------------------------------------------------------------------------
nref_sb=$(make_plain_sandbox) && cleanup_dirs+=("$nref_sb") || { echo "ERROR: nref sandbox" >&2; exit 1; }
init_git_sb "$nref_sb"
mkdir -p "$nref_sb/plugins/rite/skills/x"
printf 'clean surface\n' > "$nref_sb/plugins/rite/skills/x/SKILL.md"
commit_all "$nref_sb" nref-init
printf 'untracked token (#2700)\n' > "$nref_sb/plugins/rite/skills/x/new.md"
rc=0; out=$(run_diff "$nref_sb" HEAD --quiet 2>&1) || rc=$?
assert "T-01 untracked without intent-to-add is not scanned" "0" "$rc"
git -C "$nref_sb" add -N -- plugins/rite/skills/x/new.md
rc=0; out=$(run_diff "$nref_sb" HEAD --quiet 2>&1) || rc=$?
if [ "$rc" -eq 1 ] \
   && printf '%s' "$out" | grep -qE '^plugins/rite/skills/x/new.md:[0-9]+: untracked token \(#2700\)$'; then
  pass "T-01 untracked after add -N → rc=1 + file:line"
else
  fail "T-01 expected rc=1 with file:line after add -N, got rc=$rc: $out"
fi

nref_tracked=$(make_plain_sandbox) && cleanup_dirs+=("$nref_tracked") || { echo "ERROR: nref tracked sandbox" >&2; exit 1; }
init_git_sb "$nref_tracked"
mkdir -p "$nref_tracked/plugins/rite/skills/x"
printf 'clean surface\n' > "$nref_tracked/plugins/rite/skills/x/SKILL.md"
commit_all "$nref_tracked" nref-tracked-init
printf 'still clean\n' >> "$nref_tracked/plugins/rite/skills/x/SKILL.md"
git -C "$nref_tracked" add -N -- plugins/rite/skills/x/SKILL.md
rc=0; out=$(run_diff "$nref_tracked" HEAD --quiet 2>&1) || rc=$?
porcelain=$(git -C "$nref_tracked" status --porcelain)
if [ "$rc" -eq 0 ] \
   && ! printf '%s' "$porcelain" | grep -qE '^A|^\?\?'; then
  pass "T-03 tracked-only add -N → rc=0 and no new intent-to-add entry"
else
  fail "T-03 expected rc=0 with no new porcelain entry, got rc=$rc porcelain=$porcelain out=$out"
fi

# 削除パスを含む集合へ add -N すると 3.3 の git add が pathspec 失敗する。
# worktree に残っているパスだけ -N すれば 3.3 相当の git add は rc=0 で全パスを stage する。
nref_del=$(make_plain_sandbox) && cleanup_dirs+=("$nref_del") || { echo "ERROR: nref del sandbox" >&2; exit 1; }
init_git_sb "$nref_del"
printf 'keep\n' > "$nref_del/keep.md"
printf 'gone\n' > "$nref_del/gone.md"
commit_all "$nref_del" nref-del-init
printf 'keep2\n' >> "$nref_del/keep.md"
printf 'untracked token (#2701)\n' > "$nref_del/new.md"
rm -f "$nref_del/gone.md"
nref_addn=""
for f in keep.md new.md gone.md; do
  [ -e "$nref_del/$f" ] && nref_addn="$nref_addn $f"
done
nref_stage_rc=0
git -C "$nref_del" add -N -- $nref_addn || nref_stage_rc=$?
add_rc=0
git -C "$nref_del" add keep.md new.md gone.md >/dev/null 2>&1 || add_rc=$?
staged=$(git -C "$nref_del" diff --cached --name-only)
if [ "$nref_stage_rc" -eq 0 ] && [ "$add_rc" -eq 0 ] \
   && printf '%s\n' "$staged" | grep -qx 'keep.md' \
   && printf '%s\n' "$staged" | grep -qx 'new.md' \
   && printf '%s\n' "$staged" | grep -qx 'gone.md'; then
  pass "T-03b existence-filtered add -N leaves 3.3 git add able to stage all paths"
else
  fail "T-03b expected add -N rc=0 and git add rc=0 staging keep/new/gone, got stage_rc=$nref_stage_rc add_rc=$add_rc staged=$staged"
fi

assert_grep "T-11 issue-implement forbids number/AC tokens in generated prose" "$IMPLEMENT_SKILL" \
  '番号・AC番号を書かない'
assert_grep "T-11 issue-implement commit body Why is required" "$IMPLEMENT_SKILL" \
  'body は why を自由形式'
assert_not_grep "T-11 issue-implement trivial body omit withdrawn" "$IMPLEMENT_SKILL" \
  'trivial は省略可'

# T-09: --title arguments must not contain #{
title_hits=$(grep -nE -- '--title[[:space:]]+"[^"]*#\{' \
  "$PR_REVIEW_SKILL" "$FIX_SKILL" "$ISSUE_CLOSE_SKILL" 2>/dev/null || true)
if [ -z "$title_hits" ]; then
  pass "T-09 --title arguments contain no #{ }"
else
  fail "T-09 --title still contains #{ }: $title_hits"
fi

# T-10: retired gate name gone from the tree (tests/ of this detector excluded by design)
if ! git -C "$REPO_ROOT" grep -l 'descriptive-number-diff-gate' -- \
  ':!plugins/rite/hooks/tests/number-reference-check.test.sh' >/dev/null 2>&1; then
  pass "T-10 descriptive-number-diff-gate grep is 0"
else
  fail "T-10 descriptive-number-diff-gate still referenced"
fi

# --------------------------------------------------------------------------
# TC-013 / TC-014 preserved
# --------------------------------------------------------------------------
echo "TC-013: generic rationale placeholders are absent"
placeholder_pattern='the governing'' rationale|The observed'' review run|the contract''[.]s'
if ! grep -ERn "$placeholder_pattern" \
  "$REPO_ROOT/plugins/rite" "$REPO_ROOT/docs" >/dev/null; then
  pass "generic rationale placeholders are absent"
else
  fail "generic rationale placeholder residue found under plugins/rite or docs"
fi

echo "TC-014: deletion-damage residue is absent"
deletion_residue_patterns=(
  '[(（]で '
  '[(（]の '
  'machine-gated since[)]'
  'stdout emit、[)）:]'
  'tracked by[[:space:]]*[.]'
  'approved by[[:space:]]*[.]'
  "of 's"
  'pattern[.]POSIX'
  '、）'
  ',[)]'
  '[[:lower:]][.][(][[:upper:]]'
  '構築。[^|]*と対称[)][[:space:]]*[|]'
  'emit、[[:space:]]+で'
  '。[[:space:]]+以降'
  '[(（]の[^[:space:]]'
  'emit[*]*、[[:space:]]+で'
  '[.] D-[0-9]+'
  'frozen[.][)]'
  'AC-[0-9]+[.][)]'
  '[[:alpha:]][,][[:space:]]*[;]'
  'Static contract( tests)? for[[:space:]]*:'
  '。[[:space:]]+D-[0-9]+'
  '。[[:space:]]+で(は|本体|log)'
  '（で(機械|配線|skip)'
  '[(（][。．]'
  '、[。．]'
  '`[^`]+` は[[:space:]]+[、）]'
  '[[:space:]]{2,}で修正'
  '[(（][[:space:]]*:[[:space:]]'
  '[[:space:]]{2,}では'
  '、[[:space:]]+がまさに'
  '、[[:space:]]+と同じ'
  '、[[:space:]]+が消した'
  '（[[:space:]]'
  '[^[:space:]　][[:space:]]）'
  '—[[:space:]]?[)）]'
  '[[:alnum:]][[:space:]]\([[:space:]][a-z][^)]*[[:alnum:]/][)]'
  '[(（]で導入'
)
deletion_residue_samples=(
  'context (で rationale'
  'context (の rationale'
  'machine-gated since)'
  'stdout emit、):'
  'tracked by .'
  'approved by .'
  "half of 's contract"
  'pattern.POSIX'
  '理由、）'
  'reason,)'
  'silently.(The next sentence)'
  '集合を構築。helper と対称) |'
  'helper が emit、 で LLM'
  '完了。 以降'
  '(の実測必須ゲート'
  'helper が emit**、 で LLM'
  '. D-01 requirement'
  'intentionally frozen.)'
  'AC-1.)'
  'other, ; next'
  'Static contract tests for : workflow'
  '。 D-01 requirement'
  '。 で本体'
  '（で機械比率計算'
  '(。TMPDIR'
  '環境制約、。'
  '`updated_at` は 、'
  '点を  で修正'
  '(: missing rationale'
  'run —  では nine cycles'
  '完了してしまい、 がまさに'
  '環境制約、 と同じ扱い'
  '拒否され、 が消した'
  'WM 採用元選定ブロックを抽出できません（ の契約消失）'
  'stub fallback 時の WARNING が無い（silent 切替禁止 ）'
  'multi_session worktree 化漏れの可能性 —)'
  '# Responsibility 2 ( source OR standalone): provide'
  '# Wiki branch を checkout した永続 git worktree (で導入)。'
)
deletion_residue_pattern=$(IFS='|'; printf '%s' "${deletion_residue_patterns[*]}")
scan_deletion_residue() {
  local manifest
  manifest=$(mktemp)
  local file grep_rc grep_bin="${DELETION_GREP_BIN:-grep}"
  if ! find "$@" -type f ! -path '*/fixtures/*' \
    ! -name 'number-reference-check.test.sh' -print0 > "$manifest"; then
    rm -f "$manifest"
    return 2
  fi
  while IFS= read -r -d '' file; do
    grep_rc=0
    "$grep_bin" -En "$deletion_residue_pattern" "$file" >/dev/null || grep_rc=$?
    case "$grep_rc" in
      0) rm -f "$manifest"; return 0 ;;
      1) ;;
      *) rm -f "$manifest"; return 2 ;;
    esac
  done < "$manifest"
  rm -f "$manifest"
  return 1
}
for i in "${!deletion_residue_patterns[@]}"; do
  if printf '%s\n' "${deletion_residue_samples[$i]}" | grep -Eq "${deletion_residue_patterns[$i]}"; then
    pass "deletion-damage matcher arm $((i + 1)) has a positive control"
  else
    fail "deletion-damage matcher arm $((i + 1)) missed its positive control"
  fi
done
if ! printf '%s\n' 'context with durable rationale' | grep -Eq "$deletion_residue_pattern"; then
  pass "deletion-damage matcher accepts valid prose"
else
  fail "deletion-damage matcher rejected valid prose"
fi
# The open-paren arm is deliberately narrower than "`( ` followed by a lowercase
# word": bash subshells share that shape, so a broad arm flags working code as
# residue. Pin the narrowing so a later widening fails here rather than turning
# the whole-tree scan below into a wall of false residue.
if ! printf '%s\n' 'if ( set -C; printf "%s" "$json" > "$file" ) 2>/dev/null; then' \
  'if ( exec 8>.rite/state/wiki-worktree-setup.lock ) 2>/dev/null; then' \
  'else ( if ($f.severity == "CRITICAL" or $f.severity == "MEDIUM")' \
  | grep -Eq "$deletion_residue_pattern"; then
  pass "deletion-damage matcher accepts bash subshells"
else
  fail "deletion-damage matcher rejected a bash subshell"
fi
scan_rc=0
# .gitignore also carries prose that a number removal can damage, and it lives
# outside both directory roots, so name it explicitly.
scan_deletion_residue "$REPO_ROOT/plugins/rite" "$REPO_ROOT/docs" "$REPO_ROOT/.gitignore" || scan_rc=$?
case "$scan_rc" in
  1) pass "deletion-damage residue is absent" ;;
  0) fail "deletion-damage residue found under the scanned roots" ;;
  *) fail "deletion-damage residue scan failed operationally" ;;
esac
scan_rc=0
scan_deletion_residue "$sb/definitely-missing-root" 2>/dev/null || scan_rc=$?
if [ "$scan_rc" -eq 2 ]; then
  pass "deletion-damage scan fails closed when a scan root is unavailable"
else
  fail "deletion-damage scan did not distinguish an unavailable root (rc=$scan_rc)"
fi
scan_fixture="$sb/deletion-scan-fixture"
mkdir -p "$scan_fixture"
printf '%s\n' "${deletion_residue_samples[0]}" > "$scan_fixture/residue.md"
scan_rc=0
scan_deletion_residue "$scan_fixture" || scan_rc=$?
if [ "$scan_rc" -eq 0 ]; then
  pass "deletion-damage scan reports residue found through the scan helper"
else
  fail "deletion-damage scan missed helper-level residue (rc=$scan_rc)"
fi
grep_fail_shim="$sb/grep-fail"
printf '%s\n' '#!/bin/bash' 'exit 2' > "$grep_fail_shim"
chmod +x "$grep_fail_shim"
scan_rc=0
DELETION_GREP_BIN="$grep_fail_shim" scan_deletion_residue "$scan_fixture" || scan_rc=$?
if [ "$scan_rc" -eq 2 ]; then
  pass "deletion-damage scan fails closed on grep operational errors"
else
  fail "deletion-damage scan misclassified a grep operational error (rc=$scan_rc)"
fi

if ! print_summary "$(basename "$0")" \
  "drift: number-reference-check.sh CLI / grammar / path exclusions / SKILL wiring"; then
  exit 1
fi
