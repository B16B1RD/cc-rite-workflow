#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
audit="$ROOT/plugins/rite/skills/pr-review/references/promotion-audit-2166.md"
reviewer="$ROOT/plugins/rite/agents/_reviewer-base.md"
principles="$ROOT/plugins/rite/skills/rite-workflow/references/coding-principles.md"
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

assert_not_grep() {
  local label=$1
  local file=$2
  local pattern=$3
  if grep -Fq -- "$pattern" "$file"; then
    printf 'not ok - %s\n' "$label" >&2
    failures=$((failures + 1))
  else
    printf 'ok - %s\n' "$label"
  fi
}

assert_grep 'audit routes all pages to the shared gate' "$audit" \
  'All four are mechanized by the shared Documentation Fidelity Gate'
assert_grep 'pivot page mechanized' "$audit" \
  '| `design-pivot-stale-cross-reference-comment` | mechanized here |'
assert_grep 'recovery page mechanized' "$audit" \
  '| `recovery-command-verified-in-human-execution-context` | mechanized here |'
assert_grep 'citation page mechanized' "$audit" \
  '| `references-extraction-content-fidelity` | mechanized here |'
assert_grep 'sample page mechanized' "$audit" \
  '| `canonical-reference-sample-code-strict-sync` | mechanized here |'

assert_grep 'gate is mandatory detection work' "$reviewer" \
  'This gate is mandatory detection work'
assert_grep 'pivot sweeps old vocabulary' "$reviewer" \
  '`Grep` the old vocabulary'
assert_grep 'pivot covers explanatory references' "$reviewer" \
  'complete changed files and their explanatory'
assert_grep 'recovery uses recipient context' "$reviewer" \
  'human recipient will actually run it'
assert_grep 'recovery inherits sibling qualifiers' "$reviewer" \
  'inspect sibling recovery guidance'
assert_grep 'recovery requires canonical helpers' "$reviewer" \
  'through their canonical helpers, require the intended target'
assert_grep 'recovery checks target existence' "$reviewer" \
  'mutation, and verify a command chain'
assert_grep 'recovery checks self-deleting chains' "$reviewer" \
  'does not delete its own cwd'
assert_grep 'recovery traces promised signals to their surface' "$reviewer" \
  'Trace every promised warning'
assert_grep 'logged-only messages are not human guidance' "$reviewer" \
  'redirected only to a log is not user-visible guidance'
assert_grep 'wrong-target rc zero is rejected' "$reviewer" \
  'a different target is not success'
assert_grep 'citation reads source' "$reviewer" \
  'cited source and use an exact `Grep` anchor'
assert_grep 'citation needs exact anchor' "$reviewer" \
  'use an exact `Grep` anchor'
assert_grep 'path existence is insufficient' "$reviewer" \
  'Path existence alone is insufficient'
assert_grep 'sample comparison is verbatim' "$reviewer" \
  'compare the complete blocks verbatim'
assert_grep 'sample comparison includes caller contract' "$reviewer" \
  'prerequisites supplied by the caller'
assert_grep 'nonidentical samples narrow their claim' "$reviewer" \
  'narrow the claim instead of saying "verbatim" or "identical"'
assert_grep 'findings remain evidence gated' "$reviewer" \
  'or sample fails one of these checks'
assert_grep 'shared checklist maps the gate' "$reviewer" \
  '**Documentation fidelity (when triggered)**'
assert_grep 'audit leaves blocking classification to measured gate' "$audit" \
  'classification remains the responsibility of the measured-confirmed gate'

assert_grep 'question policy defines the two allowed classes' "$principles" \
  'ユーザー固有の意思決定、または (b) merge、Issue close、外部公開、削除など不可逆操作'
assert_grep 'question policy defaults reversible recommendations' "$principles" \
  '質問せず推奨案で続行する'
assert_grep 'question policy reuses existing records' "$principles" \
  '新しい様式や marker を作らず'

for skill in iterate fix ready merge cleanup pr-review; do
  assert_grep "$skill points to the shared question policy" \
    "$ROOT/plugins/rite/skills/$skill/SKILL.md" \
    '[question_resolution](../rite-workflow/references/coding-principles.md#question_resolution-resolve-recommended-reversible-decisions-autonomously)'
done

assert_grep 'iterate retries reversible review errors automatically' \
  "$ROOT/plugins/rite/skills/iterate/SKILL.md" '可逆な再試行を推奨として 1 回だけ自動実行'
assert_grep 'fix regenerates a missing review source automatically' \
  "$ROOT/plugins/rite/skills/fix/SKILL.md" '推奨として `/rite:pr-review {pr_number}` を 1 回自動実行'
assert_grep 'ready preserves standalone publication confirmation' \
  "$ROOT/plugins/rite/skills/ready/SKILL.md" 'Ready 化は外部公開状態を変えるため、standalone 確認は維持する'
assert_grep 'merge preserves irreversible approval boundary' \
  "$ROOT/plugins/rite/skills/merge/SKILL.md" 'merge 自体は不可逆操作として既存の承認境界を維持する'
assert_grep 'cleanup preserves destructive confirmation' \
  "$ROOT/plugins/rite/skills/cleanup/SKILL.md" '削除・close・新規 Issue 公開は不可逆操作として確認を維持する'
assert_grep 'review auto-records reversible recommendations' \
  "$ROOT/plugins/rite/skills/pr-review/SKILL.md" 'Decision Log への記録である候補は可逆なので質問せず推奨で処理'
assert_grep 'review legacy gate covers automatic disposition' \
  "$ROOT/plugins/rite/skills/pr-review/SKILL.md" '自動 Decision Log 経路でも emit する'
assert_not_grep 'iterate overview does not restore review error questions' \
  "$ROOT/plugins/rite/skills/iterate/SKILL.md" 'その他 → AskUserQuestion'
assert_not_grep 'iterate overview does not restore fix error questions' \
  "$ROOT/plugins/rite/skills/iterate/SKILL.md" '`[fix:error]` → AskUserQuestion'
assert_not_grep 'fix fallback does not offer a second review run' \
  "$ROOT/plugins/rite/skills/fix/SKILL.md" '- レビュー実行: /rite:pr-review を起動してレビュー結果を生成する'
assert_not_grep 'review overview does not require recommendation questions' \
  "$ROOT/plugins/rite/skills/pr-review/SKILL.md" 'recommendations AskUserQuestion 等の処理本体'

if [ "$failures" -ne 0 ]; then
  printf '%s contract assertion(s) failed\n' "$failures" >&2
  exit 1
fi

printf 'All documentation fidelity promotion contract assertions passed.\n'
