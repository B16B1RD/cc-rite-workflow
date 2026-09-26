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
  {"reviewer_type": "security", "content": "boundary", "classification": "boundary", "file_line": "a.sh:3"}
]}
EOF
register() { run register --input "$1" --items "${2:-$WORK/items.json}" --base-ref base --state-root "$STATE"; }

echo "=== register: selection ==="
review "$WORK/r.json" mergeable run1 1
cp "$WORK/r.json" "$WORK/r.orig.json"
register "$WORK/r.json"
check "registers actionable items on + lines only, in item order" \
  '[ $RC -eq 0 ] && [ "$OUT" = "[CONTEXT] PR_RECOMMENDATIONS=registered; count=3; ids=R-01,R-02,R-03; positions=0,5,6" ]'
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
  '[ "$(jq -nc --argjson a "$actionable" --argjson r "$registered" "[(\$r - \$a | length), (\$a - \$r)]")" = "[0,[2,3,4,7]]" ]'

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
check "no candidates leaves the JSON unchanged" \
  '[ $RC -eq 0 ] && [ "$OUT" = "[CONTEXT] PR_RECOMMENDATIONS=none; reason=no_candidates" ] && cmp -s "$WORK/n.json" "$WORK/n.orig.json"'

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

echo ""
echo "=== Summary: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
