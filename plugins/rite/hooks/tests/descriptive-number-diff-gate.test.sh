#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
GATE="$SCRIPT_DIR/../scripts/descriptive-number-diff-gate.sh"
DETECTOR="$SCRIPT_DIR/../scripts/comment-journal-check.sh"
LINT_SKILL="$SCRIPT_DIR/../../skills/lint/SKILL.md"

sb=$(make_plain_sandbox)
trap 'rm -rf "$sb"' EXIT
mkdir -p "$sb/plugins/rite/hooks/tests" "$sb/plugins/rite/skills/x" "$sb/plugins/rite/hooks/scripts"
cp "$GATE" "$sb/plugins/rite/hooks/scripts/"
cp "$DETECTOR" "$sb/plugins/rite/hooks/scripts/"
git -C "$sb" init -q
git -C "$sb" config user.email test@example.com
git -C "$sb" config user.name test
printf 'Issue #100 is pre-existing\n' > "$sb/plugins/rite/skills/x/SKILL.md" # example: detector fixture
git -C "$sb" add . && git -C "$sb" commit -qm base
base=$(git -C "$sb" rev-parse HEAD)

printf 'clean addition\n' >> "$sb/plugins/rite/skills/x/SKILL.md"
git -C "$sb" add . && git -C "$sb" commit -qm clean
out=$(bash "$sb/plugins/rite/hooks/scripts/descriptive-number-diff-gate.sh" --repo-root "$sb" --base-ref "$base" 2>&1); rc=$?
assert "pre-existing reference is not prosecuted" "0" "$rc"

printf 'PR #200 supplied the reason\n' >> "$sb/plugins/rite/skills/x/SKILL.md" # example: detector fixture
git -C "$sb" add . && git -C "$sb" commit -qm bad
out=$(bash "$sb/plugins/rite/hooks/scripts/descriptive-number-diff-gate.sh" --repo-root "$sb" --base-ref HEAD~1 2>&1); rc=$?
assert "added descriptive reference blocks" "1" "$rc"
printf '%s\n' "$out" > "$sb/gate-output.txt"
assert_grep "gate reports the Why rewrite" "$sb/gate-output.txt" '修正方針: 番号を削除し、番号が担っていた理由を自己完結した Why 散文'

printf '詳細は #201\n' >> "$sb/plugins/rite/skills/x/SKILL.md" # example: P6 detector fixture
git -C "$sb" add . && git -C "$sb" commit -qm p6
out=$(bash "$sb/plugins/rite/hooks/scripts/descriptive-number-diff-gate.sh" --repo-root "$sb" --base-ref HEAD~1 2>&1); rc=$?
assert "added P6 descriptive reference blocks" "1" "$rc"
printf '%s\n' "$out" > "$sb/p6-output.txt"
assert_grep "gate preserves the detector P6 classification" "$sb/p6-output.txt" '\[P6\]'

printf 'Issue #300 fixture\n' > "$sb/plugins/rite/hooks/tests/fixture.md" # example: excluded test fixture
printf 'TODO: refs #301\n`refs #302`\n' >> "$sb/plugins/rite/skills/x/SKILL.md"
git -C "$sb" add . && git -C "$sb" commit -qm excluded
out=$(bash "$sb/plugins/rite/hooks/scripts/descriptive-number-diff-gate.sh" --repo-root "$sb" --base-ref HEAD~1 2>&1); rc=$?
assert "tests and detector exclusions remain allowed" "0" "$rc"

mkdir -p "$sb/plugins/rite/skills/path space"
printf 'base\n' > "$sb/plugins/rite/skills/path space/SKILL.md"
git -C "$sb" add . && git -C "$sb" commit -qm space-base
printf 'PR #303 path with space\n' >> "$sb/plugins/rite/skills/path space/SKILL.md" # example: path fixture
git -C "$sb" add . && git -C "$sb" commit -qm space-bad
out=$(bash "$sb/plugins/rite/hooks/scripts/descriptive-number-diff-gate.sh" --repo-root "$sb" --base-ref HEAD~1 2>&1); rc=$?
assert "space-containing plugin path cannot bypass the gate" "1" "$rc"

tab_dir=$'plugins/rite/skills/tab\tpath'
mkdir -p "$sb/$tab_dir"
printf 'base\n' > "$sb/$tab_dir/SKILL.md"
git -C "$sb" add . && git -C "$sb" commit -qm tab-base
printf 'PR #304 tab path\n' >> "$sb/$tab_dir/SKILL.md" # example: tab path fixture
git -C "$sb" add . && git -C "$sb" commit -qm tab-bad
out=$(bash "$sb/plugins/rite/hooks/scripts/descriptive-number-diff-gate.sh" --repo-root "$sb" --base-ref HEAD~1 2>&1); rc=$?
assert "TAB-containing plugin path cannot bypass the gate" "1" "$rc"

mkdir -p "$sb/plugins/rite/skills/rename-old"
printf 'PR #401 pre-existing\na\nb\nc\nd\ne\nf\n' > "$sb/plugins/rite/skills/rename-old/SKILL.md" # example: rename fixture
git -C "$sb" add . && git -C "$sb" commit -qm rename-base
mv "$sb/plugins/rite/skills/rename-old" "$sb/plugins/rite/skills/rename-new"
printf 'PR #401 pre-existing\na\nb\nchanged-1\nchanged-2\nchanged-3\nPR #402 new reference\n' > "$sb/plugins/rite/skills/rename-new/SKILL.md" # example: rename fixture
git -C "$sb" add -A && git -C "$sb" commit -qm rename-edit
out=$(bash "$sb/plugins/rite/hooks/scripts/descriptive-number-diff-gate.sh" --repo-root "$sb" --base-ref HEAD~1 2>&1); rc=$?
assert "rename with edits still blocks a genuinely new reference" "1" "$rc"
case "$out" in *'PR #401'*) fail "rename does not re-prosecute an identical moved reference" ;; *) pass "rename does not re-prosecute an identical moved reference" ;; esac
case "$out" in *'PR #402'*) pass "rename reports the genuinely added reference" ;; *) fail "rename reports the genuinely added reference" ;; esac

printf 'Issue #777 moved text\n' > "$sb/plugins/rite/hooks/tests/source.md" # example: excluded source fixture
git -C "$sb" add . && git -C "$sb" commit -qm excluded-source
rm "$sb/plugins/rite/hooks/tests/source.md"
printf 'Issue #777 moved text\n' >> "$sb/plugins/rite/skills/x/SKILL.md" # example: production destination fixture
git -C "$sb" add -A && git -C "$sb" commit -qm excluded-to-production
out=$(bash "$sb/plugins/rite/hooks/scripts/descriptive-number-diff-gate.sh" --repo-root "$sb" --base-ref HEAD~1 2>&1); rc=$?
assert "a tests deletion cannot mask a production addition" "1" "$rc"

mkdir -p "$sb/plugins/rite/skills/日本語"
printf 'base\n' > "$sb/plugins/rite/skills/日本語/SKILL.md"
git -C "$sb" add . && git -C "$sb" commit -qm unicode-base
printf 'Issue #778 unicode path\n' >> "$sb/plugins/rite/skills/日本語/SKILL.md" # example: unicode path fixture
git -C "$sb" add . && git -C "$sb" commit -qm unicode-bad
out=$(bash "$sb/plugins/rite/hooks/scripts/descriptive-number-diff-gate.sh" --repo-root "$sb" --base-ref HEAD~1 2>&1); rc=$?
assert "non-ASCII plugin path cannot bypass the gate" "1" "$rc"

printf 'Issue #779 crossed boundary\n' > "$sb/plugins/rite/hooks/tests/rename-source.md" # example: excluded rename source
git -C "$sb" add . && git -C "$sb" commit -qm boundary-rename-base
mkdir -p "$sb/plugins/rite/skills/renamed-from-tests"
mv "$sb/plugins/rite/hooks/tests/rename-source.md" "$sb/plugins/rite/skills/renamed-from-tests/SKILL.md"
for i in $(seq 1 40); do printf 'unrelated-%s\n' "$i" >> "$sb/plugins/rite/skills/renamed-from-tests/SKILL.md"; done
git -C "$sb" add -A && git -C "$sb" commit -qm boundary-rename
out=$(bash "$sb/plugins/rite/hooks/scripts/descriptive-number-diff-gate.sh" --repo-root "$sb" --base-ref HEAD~1 2>&1); rc=$?
assert "rename from tests into production treats destination as added" "1" "$rc"
case "$out" in *'Issue #779'*) pass "boundary-crossing rename reports the moved reference" ;; *) fail "boundary-crossing rename reports the moved reference" ;; esac

bash "$sb/plugins/rite/hooks/scripts/descriptive-number-diff-gate.sh" --repo-root "$sb" --base-ref does-not-exist >/dev/null 2>&1; rc=$?
assert "invalid diff base fails closed" "2" "$rc"

assert_grep "lint invokes the dedicated diff gate" "$LINT_SKILL" \
  'descriptive-number-diff-gate\.sh'
assert_grep "lint treats findings and unreadable diffs as errors" "$LINT_SKILL" \
  '^  1\|2\)$'
assert_grep "lint routes gate failures through error_count" "$LINT_SKILL" \
  'error_count=\$\(\(error_count \+ 1\)\)'

if ! print_summary "$(basename "$0")"; then exit 1; fi
