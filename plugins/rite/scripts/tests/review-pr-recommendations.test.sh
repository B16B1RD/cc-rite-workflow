#!/bin/bash
# Tests for review-pr-recommendations.sh (reviewer recommendations routed to an in-PR fix)
#
# Usage: bash plugins/rite/scripts/tests/review-pr-recommendations.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../review-pr-recommendations.sh"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ FAIL: $1"; }
check() { if eval "$2"; then pass "$1"; else fail "$1 (out=$OUT err=$ERR)"; fi; }

run() {
  OUT=$(cd "$REPO" && bash "$TARGET" "$@" 2>"$TEST_DIR/.err")
  RC=$?
  ERR=$(cat "$TEST_DIR/.err")
}

# --- fixture repo: base..HEAD adds a.sh:3-4, deletes del.sh:5-6, renames old.sh -> new.sh (+ line 6)
REPO="$TEST_DIR/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name t
seq 1 10 > "$REPO/a.sh"
seq 1 10 > "$REPO/del.sh"
printf 'alpha\nbeta\ngamma\ndelta\nepsilon\n' > "$REPO/old.sh"
seq 1 3 > "$REPO/other.sh"
git -C "$REPO" add -A && git -C "$REPO" commit -qm base
git -C "$REPO" branch base
{ seq 1 2; echo added-3; echo added-4; seq 3 10; } > "$REPO/a.sh"
{ seq 1 4; seq 7 10; } > "$REPO/del.sh"
git -C "$REPO" mv old.sh new.sh
echo zeta >> "$REPO/new.sh"
git -C "$REPO" commit -qam head

STATE="$TEST_DIR/state"
mkdir -p "$STATE/.rite/review-results" "$STATE/.rite/state"
WORK="$TEST_DIR/work"
mkdir -p "$WORK"

ctx() { printf '{"session_id":"s","run_id":"%s","pr_number":7,"cycle_count":%s,"commit_sha":"%s"}' "$1" "$2" "${3:-c0}"; }
review() {  # review <path> <assessment> <run_id> <cycle> [commit]
  jq -n --arg oa "$2" --argjson ctx "$(ctx "$3" "$4" "${5:-c0}")" --arg sha "${5:-c0}" \
    '{schema_version:"1.1.0", pr_number:7, commit_sha:$sha, overall_assessment:$oa, verdict:$oa,
      review_context:$ctx, findings:[], non_blocking_findings:[], reviewers:["code-quality-reviewer"]}' > "$1"
}
cat > "$WORK/items.json" <<'EOF'
{"recommendation_items": [
  {"reviewer_type": "code-quality", "content": "added line", "classification": "actionable", "file_line": "a.sh:3"},
  {"reviewer_type": "tech-writer", "content": "design note", "classification": "design_confirmation", "file_line": "a.sh:3"},
  {"reviewer_type": "code-quality", "content": "context line", "classification": "actionable", "file_line": "a.sh:8"},
  {"reviewer_type": "code-quality", "content": "deleted line", "classification": "actionable", "file_line": "del.sh:5"},
  {"reviewer_type": "code-quality", "content": "no location", "classification": "actionable", "file_line": null},
  {"reviewer_type": "test", "content": "partial overlap", "classification": "actionable", "file_line": "a.sh:4-8"},
  {"reviewer_type": "code-quality", "content": "renamed file", "classification": "actionable", "file_line": "new.sh:6"},
  {"reviewer_type": "code-quality", "content": "untouched file", "classification": "actionable", "file_line": "other.sh:1"},
  {"reviewer_type": "security", "content": "boundary", "classification": "boundary", "file_line": "a.sh:3"},
  {"reviewer_type": "code-quality", "content": "path without line", "classification": "actionable", "file_line": "a.sh"},
  {"reviewer_type": "security", "content": "boundary without line", "classification": "boundary", "file_line": "a.sh"},
  {"reviewer_type": "tech-writer", "content": "design without location", "classification": "design_confirmation", "file_line": null}
]}
EOF
register() { run register --input "$1" --items "${2:-$WORK/items.json}" --base-ref base --state-root "$STATE"; }

echo "=== register: selection ==="
review "$WORK/r.json" mergeable run1 1
cp "$WORK/r.json" "$WORK/r.orig.json"
register "$WORK/r.json"
check "registers actionable items on + lines only, in item order; unlocated lists actionable items without path:line" \
  '[ $RC -eq 0 ] && [ "$OUT" = "[CONTEXT] PR_RECOMMENDATIONS=registered; count=3; ids=R-01,R-02,R-03; positions=0,5,6; unlocated=4,9" ]'
expected='[{"reviewer":"code-quality","file":"a.sh","line":3,"description":"added line","id":"R-01"},{"reviewer":"test","file":"a.sh","line":4,"description":"partial overlap","id":"R-02"},{"reviewer":"code-quality","file":"new.sh","line":6,"description":"renamed file","id":"R-03"}]'
check "pr_recommendations shape is exactly the selected entries" \
  '[ "$(jq -cS .pr_recommendations "$WORK/r.json")" = "$(printf "%s" "$expected" | jq -cS .)" ]'
check "nothing else in the review JSON changes" \
  '[ "$(jq -cS "del(.pr_recommendations)" "$WORK/r.json")" = "$(jq -cS . "$WORK/r.orig.json")" ]'
# Registered and unregistered actionable items partition the actionable set:
# the unregistered ones stay step 7 candidates (Decision Log), never both.
actionable=$(jq -c '[.recommendation_items | to_entries[] | select(.value.classification == "actionable") | .key]' "$WORK/items.json")
registered=$(printf '%s' "$OUT" | sed -n 's/.*positions=\([0-9,]*\).*/[\1]/p')
check "registered positions are actionable and the rest stay unregistered" \
  '[ "$(jq -nc --argjson a "$actionable" --argjson r "$registered" "[(\$r - \$a | length), (\$a - \$r)]")" = "[0,[2,3,4,7,9]]" ]'

echo "=== register: idempotent re-run of the same cycle ==="
cp "$WORK/r.json" "$STATE/.rite/review-results/7-20260101000000.json"
cp "$WORK/r.json" "$WORK/r.first.json"
register "$WORK/r.json"
check "same review_context saved with recommendations is not the cap; bytes unchanged" \
  '[ $RC -eq 0 ] && cmp -s "$WORK/r.json" "$WORK/r.first.json" && [[ "$OUT" == *"=registered; count=3"* ]]'

echo "=== register: once per run ==="
review "$WORK/r2.json" mergeable run1 2 c1
cp "$WORK/r2.json" "$WORK/r2.orig.json"
register "$WORK/r2.json"
check "a later cycle of the same run hits the cap and leaves the JSON unchanged" \
  '[ $RC -eq 0 ] && [ "$OUT" = "[CONTEXT] PR_RECOMMENDATIONS=none; reason=cap_reached" ] && cmp -s "$WORK/r2.json" "$WORK/r2.orig.json"'
review "$WORK/r3.json" mergeable run2 1 c1
register "$WORK/r3.json"
check "another run registers again" '[ $RC -eq 0 ] && [[ "$OUT" == *"=registered; count=3"* ]]'
rm -f "$STATE/.rite/review-results/"*
review "$STATE/.rite/review-results/7-20260101000002.json" fix-needed run1 1
review "$WORK/r4.json" mergeable run1 2 c1
register "$WORK/r4.json"
check "a same-run earlier cycle without recommendations does not use up the registration" \
  '[ $RC -eq 0 ] && [[ "$OUT" == *"=registered; count=3"* ]]'
rm -f "$STATE/.rite/review-results/"*
FRESH="$TEST_DIR/fresh-state"
mkdir -p "$FRESH"
review "$WORK/r5.json" mergeable run1 1
run register --input "$WORK/r5.json" --items "$WORK/items.json" --base-ref base --state-root "$FRESH"
check "a state root with no saved review yet registers (no results dir is an empty set)" \
  '[ $RC -eq 0 ] && [[ "$OUT" == *"=registered; count=3"* ]] && [ ! -e "$FRESH/.rite/review-results" ]'

echo "=== register: not at the last allowed cycle ==="
printf 'safety:\n  max_review_cycles: 2\n' > "$REPO/rite-config.yml"
review "$WORK/c2.json" mergeable run3 2 c1
cp "$WORK/c2.json" "$WORK/c2.orig.json"
register "$WORK/c2.json"
check "a mergeable at max_review_cycles does not register (its fix could not be re-reviewed)" \
  '[ $RC -eq 0 ] && [ "$OUT" = "[CONTEXT] PR_RECOMMENDATIONS=none; reason=cycle_cap" ] && cmp -s "$WORK/c2.json" "$WORK/c2.orig.json"'
review "$WORK/c1.json" mergeable run3 1 c1
register "$WORK/c1.json"
check "a mergeable below max_review_cycles registers" '[ $RC -eq 0 ] && [[ "$OUT" == *"=registered; count=3"* ]]'
rm -f "$REPO/rite-config.yml"

echo "=== register: no registration ==="
review "$WORK/f.json" fix-needed run1 1
cp "$WORK/f.json" "$WORK/f.orig.json"
register "$WORK/f.json"
check "fix-needed does not register" \
  '[ $RC -eq 0 ] && [ "$OUT" = "[CONTEXT] PR_RECOMMENDATIONS=none; reason=not_mergeable" ] && cmp -s "$WORK/f.json" "$WORK/f.orig.json"'
jq '{recommendation_items: [.recommendation_items[] | select(.classification != "actionable")]}' "$WORK/items.json" > "$WORK/none.json"
review "$WORK/n.json" mergeable run1 1
cp "$WORK/n.json" "$WORK/n.orig.json"
register "$WORK/n.json" "$WORK/none.json"
check "no candidates leaves the JSON unchanged (boundary / design_confirmation without path:line are not unlocated)" \
  '[ $RC -eq 0 ] && [ "$OUT" = "[CONTEXT] PR_RECOMMENDATIONS=none; reason=no_candidates" ] && cmp -s "$WORK/n.json" "$WORK/n.orig.json"'
jq '{recommendation_items: [.recommendation_items[] | select(.classification == "actionable" and .content == "no location")]}' "$WORK/items.json" > "$WORK/unlocated.json"
review "$WORK/u.json" mergeable run1 1
cp "$WORK/u.json" "$WORK/u.orig.json"
register "$WORK/u.json" "$WORK/unlocated.json"
check "no candidates still reports actionable items without path:line" \
  '[ $RC -eq 0 ] && [ "$OUT" = "[CONTEXT] PR_RECOMMENDATIONS=none; reason=no_candidates; unlocated=0" ] && cmp -s "$WORK/u.json" "$WORK/u.orig.json"'

echo "=== register: fail-loud ==="
review "$STATE/.rite/review-results/7-20260101000001.json" mergeable run1 1
cp "$STATE/.rite/review-results/7-20260101000001.json" "$WORK/saved.orig.json"
register "$STATE/.rite/review-results/7-20260101000001.json"
check "a saved result path is refused and not written" \
  '[ $RC -eq 1 ] && [[ "$ERR" == *"reason=saved_result_path"* ]] && cmp -s "$STATE/.rite/review-results/7-20260101000001.json" "$WORK/saved.orig.json"'
rm -f "$STATE/.rite/review-results/"*
printf '{broken' > "$WORK/bad.json"
register "$WORK/bad.json"
check "invalid review JSON fails" '[ $RC -eq 1 ] && [[ "$ERR" == *"reason=json_invalid"* ]]'
review "$WORK/i.json" mergeable run1 1
printf '{}' > "$WORK/bad-items.json"
register "$WORK/i.json" "$WORK/bad-items.json"
check "items without recommendation_items fail" '[ $RC -eq 1 ] && [[ "$ERR" == *"reason=items_invalid"* ]]'
run register --input "$WORK/i.json" --items "$WORK/items.json" --base-ref no-such-ref --state-root "$STATE"
check "an unresolvable base ref fails" '[ $RC -eq 1 ] && [[ "$ERR" == *"reason=diff_failed"* ]] && [ "$(jq "has(\"pr_recommendations\")" "$WORK/i.json")" = false ]'
# 停止は既定値で続行しない。各ケースは reason に加えて入力が不変で、登録結果を出さないことまで見る。
# 同名のディレクトリは実行ユーザーの権限に依らず config ファイルとして読めない
review "$WORK/u.json" mergeable run1 1
cp "$WORK/u.json" "$WORK/u.orig.json"
mkdir "$REPO/rite-config.yml"
register "$WORK/u.json"
rmdir "$REPO/rite-config.yml"
check "an unreadable rite-config.yml fails instead of using the default cycle cap" \
  '[ $RC -eq 1 ] && [[ "$ERR" == *"reason=config_unreadable"* ]] && [[ "$OUT" != *"PR_RECOMMENDATIONS="* ]] && cmp -s "$WORK/u.json" "$WORK/u.orig.json"'
review "$WORK/nc.json" mergeable run1 1
jq 'del(.review_context.cycle_count)' "$WORK/nc.json" > "$WORK/nc.tmp" && mv "$WORK/nc.tmp" "$WORK/nc.json"
cp "$WORK/nc.json" "$WORK/nc.orig.json"
register "$WORK/nc.json"
check "a review_context without cycle_count fails" \
  '[ $RC -eq 1 ] && [[ "$ERR" == *"reason=json_invalid"* ]] && [[ "$ERR" == *"review_context.cycle_count missing"* ]] && [[ "$OUT" != *"PR_RECOMMENDATIONS="* ]] && cmp -s "$WORK/nc.json" "$WORK/nc.orig.json"'
# 実物の resolver は git root を解決できなくても cwd を返して成功するため、失敗する resolver を持つ plugin tree に複製して
# 呼ぶ。cwd を git 外に置くと config は /dev/null に解決され、state root の解決まで進む。
STUB="$TEST_DIR/stub-plugin"
mkdir -p "$STUB/scripts" "$STUB/hooks/scripts/lib"
cp "$TARGET" "$STUB/scripts/review-pr-recommendations.sh"
cp "$PLUGIN_ROOT/hooks/scripts/lib/rite-config-path.sh" "$STUB/hooks/scripts/lib/"
printf '#!/bin/bash\nexit 1\n' > "$STUB/hooks/state-path-resolve.sh"
OUTSIDE="$TEST_DIR/outside"
mkdir -p "$OUTSIDE"
review "$WORK/sr.json" mergeable run1 1
cp "$WORK/sr.json" "$WORK/sr.orig.json"
OUT=$(cd "$OUTSIDE" && GIT_CEILING_DIRECTORIES="$TEST_DIR" bash "$STUB/scripts/review-pr-recommendations.sh" register \
  --input "$WORK/sr.json" --items "$WORK/items.json" --base-ref base 2>"$TEST_DIR/.err")
RC=$?
ERR=$(cat "$TEST_DIR/.err")
check "an unresolvable state root fails" \
  '[ $RC -eq 1 ] && [[ "$ERR" == *"reason=state_root_unresolved"* ]] && [[ "$OUT" != *"PR_RECOMMENDATIONS="* ]] && cmp -s "$WORK/sr.json" "$WORK/sr.orig.json"'

echo "=== check / mark ==="
R="$STATE/.rite/review-results"
run check --pr 7 --state-root "$STATE"
check "no saved review fails" '[ $RC -eq 1 ] && [[ "$ERR" == *"reason=json_missing"* ]]'
cp "$WORK/r.json" "$R/7-20260101000000.json"
run check --pr 7 --state-root "$STATE"
check "latest review with recommendations is pending" '[ $RC -eq 0 ] && [[ "$OUT" == "[CONTEXT] PR_RECOMMENDATIONS_CHECK=pending; count=3; json="*"7-20260101000000.json" ]]'
run mark --pr 7 --state-root "$STATE"
check "mark records the handed review" '[ $RC -eq 0 ] && [ "$(cat "$STATE/.rite/state/pr-recommendations-done-7.txt")" = "7-20260101000000.json c0" ]'
run check --pr 7 --state-root "$STATE"
check "the handed review is not pending again" '[ $RC -eq 0 ] && [[ "$OUT" == "[CONTEXT] PR_RECOMMENDATIONS_CHECK=none; "* ]]'
cp "$WORK/r.json" "$R/7-20260101000005.json"
run check --pr 7 --state-root "$STATE"
check "a copy of the same reviewed commit under a new name is not pending" '[[ "$OUT" == "[CONTEXT] PR_RECOMMENDATIONS_CHECK=none; "* ]]'
jq '.commit_sha = "c9"' "$WORK/r.json" > "$R/7-20260101000009.json"
run check --pr 7 --state-root "$STATE"
check "a review of a new commit with recommendations is pending again" '[[ "$OUT" == *"=pending; count=3; json="*"7-20260101000009.json" ]]'
review "$R/7-20260101000010.json" mergeable run1 2 c10
run check --pr 7 --state-root "$STATE"
check "latest review without recommendations is none even if an older one has them" '[[ "$OUT" == "[CONTEXT] PR_RECOMMENDATIONS_CHECK=none; "*"7-20260101000010.json" ]]'

echo "=== the key survives the review gates; NB helpers ignore it ==="
jq -n --argjson ctx "$(ctx run1 1)" '{schema_version:"1.1.0", pr_number:7, commit_sha:"c0", overall_assessment:"fix-needed",
  review_context:$ctx, reviewers:["code-quality-reviewer"], acceptance_criteria:{skipped:"no_ac_section"},
  findings:[{id:"F-01", reviewer:"code-quality-reviewer", category:"code_quality", severity:"MEDIUM", file:"a.sh", line:3,
    description:"Verification: repro sample => failed", suggestion:"s", status:"open", scope:"current-pr"}],
  non_blocking_findings:[], guardrail_audit_log:[]}' > "$WORK/g.json"
jq --argjson recs "$expected" '.pr_recommendations = $recs' "$WORK/g.json" > "$WORK/g2.json" && mv "$WORK/g2.json" "$WORK/g.json"
keep() { [ "$(jq -cS .pr_recommendations "$WORK/g.json")" = "$(printf '%s' "$expected" | jq -cS .)" ]; }
bash "$PLUGIN_ROOT/scripts/review-measured-gate.sh" --input "$WORK/g.json" --reject-preset-verification >/dev/null 2>&1
check "measured gate keeps pr_recommendations" 'keep'
printf '{"classifications":[{"id":"F-01","class":"B","scenario":"wording only"}]}' > "$WORK/cls.json"
bash "$PLUGIN_ROOT/scripts/review-class-demotion-gate.sh" --input "$WORK/g.json" --classification "$WORK/cls.json" >/dev/null 2>&1
check "class demotion gate keeps pr_recommendations (and demotes to mergeable)" 'keep && [ "$(jq -r .overall_assessment "$WORK/g.json")" = mergeable ]'
bash "$PLUGIN_ROOT/scripts/acceptance-criteria-check.sh" final --expected "" --input "$WORK/g.json" >/dev/null 2>&1
check "acceptance final check keeps pr_recommendations" 'keep'
bash "$PLUGIN_ROOT/scripts/review-findings-maps.sh" --review-source local_file --review-source-path "$WORK/g.json" >/dev/null 2>&1
check "findings maps keep pr_recommendations" 'keep'
OUT=$(bash "$PLUGIN_ROOT/hooks/scripts/nb-sweep-collect.sh" --json "$WORK/g.json" 2>/dev/null)
check "NB sweep collect does not pick up recommendations" \
  '[ "$(printf "%s" "$OUT" | jq -c "[.targets[] | select((.id // \"\") | startswith(\"R-\"))] | length")" = 0 ]'

echo "=== the done marker lives as long as nb-sweep-done ==="
# Every place that ends nb-sweep-done's life (fresh run, review-restart, cleanup,
# orphan GC) removes the done marker too; a stale one would hide a new run's registration.
for site in scripts/iterate-step.sh hooks/flow-state.sh hooks/scripts/cleanup-pr-state-purge.sh hooks/scripts/pr-cycle-cleanup.sh; do
  check "$site removes the done marker beside nb-sweep-done" 'grep -q "pr-recommendations-done-\${[a-z_]*}\.txt" "$PLUGIN_ROOT/$site"'
done

echo "=== pr-review keeps unlocated actionables in the triage source ==="
# An actionable recommendation without path:line is never registered, so this sentence is
# the only thing that keeps it in Source B instead of dropping it. The expected text lives
# outside check's eval because it carries backquotes.
UNLOCATED_LINE='marker 末尾の `unlocated=`（file:line を読めない actionable の位置）は Source B から除外しない。行き先はステップ 7 の処分で決まる（Decision Log に記録する場合は 7.4.3 の先送り欠陥トークン付きになり、cleanup が follow-up へ転記する）。'
UNLOCATED_COUNT=$(awk '/^#### 5\.3\.0\.R /{ f = 1; next } f && /^#{2,4} /{ exit } f' "$PLUGIN_ROOT/skills/pr-review/SKILL.md" | grep -cxF -- "$UNLOCATED_LINE")
check "pr-review 5.3.0.R states once that unlocated actionables stay in Source B" '[ "$UNLOCATED_COUNT" = 1 ]'

echo ""
echo "=== Summary: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
