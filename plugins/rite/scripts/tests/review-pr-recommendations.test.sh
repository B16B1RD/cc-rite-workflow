#!/bin/bash
# Tests for review-pr-recommendations.sh (adopted PR-origin root causes routed to an in-PR fix)
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

# capacity reads rite-config.yml from the working directory's repository
REPO="$TEST_DIR/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
STATE="$TEST_DIR/state"
mkdir -p "$STATE/.rite/review-results" "$STATE/.rite/state"
WORK="$TEST_DIR/work"
mkdir -p "$WORK"
REG="$STATE/.rite/state/pr-recommendations-7.json"

review() {  # review <path> <cycle> <commit>
  jq -n --argjson cycle "$2" --arg sha "$3" \
    '{schema_version:"1.1.0", pr_number:7, commit_sha:$sha, overall_assessment:"mergeable", verdict:"mergeable",
      review_context:{session_id:"s", run_id:"run1", pr_number:7, cycle_count:$cycle, commit_sha:$sha},
      findings:[], non_blocking_findings:[], reviewers:["code-quality-reviewer"]}' > "$1"
}

echo "=== capacity: only the last allowed cycle closes it ==="
review "$WORK/r1.json" 1 c1
run capacity --input "$WORK/r1.json"
check "a cycle below max_review_cycles (default 15) is open" '[ $RC -eq 0 ] && [ "$OUT" = "[CONTEXT] PR_RECOMMENDATIONS_CAPACITY=open" ]'
review "$WORK/r15.json" 15 c1
run capacity --input "$WORK/r15.json"
check "the default max_review_cycles closes it" '[ $RC -eq 0 ] && [ "$OUT" = "[CONTEXT] PR_RECOMMENDATIONS_CAPACITY=cycle_cap" ]'
printf 'safety:\n  max_review_cycles: 2\n' > "$REPO/rite-config.yml"
review "$WORK/r2.json" 2 c1
run capacity --input "$WORK/r2.json"
check "a cycle at safety.max_review_cycles is cycle_cap (its fix could not be re-reviewed)" '[ "$OUT" = "[CONTEXT] PR_RECOMMENDATIONS_CAPACITY=cycle_cap" ]'
run capacity --input "$WORK/r1.json"
check "a cycle below the configured max is open" '[ "$OUT" = "[CONTEXT] PR_RECOMMENDATIONS_CAPACITY=open" ]'
rm -f "$REPO/rite-config.yml"
# 停止は既定値で続行しない。同名のディレクトリは実行ユーザーの権限に依らず config ファイルとして読めない
mkdir "$REPO/rite-config.yml"
run capacity --input "$WORK/r1.json"
rmdir "$REPO/rite-config.yml"
check "an unreadable rite-config.yml fails instead of using the default" \
  '[ $RC -eq 1 ] && [[ "$ERR" == *"reason=config_unreadable"* ]] && [[ "$OUT" != *"CAPACITY="* ]]'
jq 'del(.review_context.cycle_count)' "$WORK/r1.json" > "$WORK/nc.json"
run capacity --input "$WORK/nc.json"
check "a review without cycle_count fails" '[ $RC -eq 1 ] && [[ "$ERR" == *"reason=json_invalid"* ]] && [[ "$OUT" != *"CAPACITY="* ]]'

echo "=== record: every fix verdict, in verdict order ==="
cat > "$WORK/candidates.json" <<'EOF'
{"candidates": [
  {"id": "C-1", "source": "推奨", "file_line": "a.sh:3", "reviewer": "code-quality", "severity": "", "content": "added line"},
  {"id": "C-2", "source": "指摘", "file_line": "b.sh:9", "reviewer": "test", "severity": "LOW", "content": "second"},
  {"id": "C-3", "source": "推奨", "file_line": "", "reviewer": "security", "severity": "", "content": "no location"},
  {"id": "C-4", "source": "推奨", "file_line": "c.sh:1", "reviewer": "tech-writer", "severity": "", "content": "rejected"}
]}
EOF
cat > "$WORK/verdicts.json" <<'EOF'
{"held": false, "head": "c1", "verdicts": [
  {"ids": ["C-3"], "exit": "ADOPT", "origin": "pr", "action": "fix_in_pr", "verdict": "fix", "tracker": null,
   "record": {"contract": {"ref": "AC-1"}, "evidence": "e3"}},
  {"ids": ["C-4"], "exit": "REJECT", "origin": "pre_existing", "action": "record_rejected", "verdict": "record", "tracker": null,
   "record": {"reason": "r"}},
  {"ids": ["C-1", "C-2"], "exit": "ADOPT", "origin": "pr", "action": "fix_in_pr", "verdict": "fix", "tracker": null,
   "record": {"contract": {"ref": "pr", "text": "t"}, "evidence": "e1"}}
]}
EOF
record() { run record --pr 7 --review-result "$1" --verdicts "${2:-$WORK/verdicts.json}" --candidates "$WORK/candidates.json" --state-root "$STATE"; }
record "$WORK/r1.json"
check "registers the fix verdicts only, numbered in verdict order" \
  '[ $RC -eq 0 ] && [ "$OUT" = "[CONTEXT] PR_RECOMMENDATIONS=registered; count=2; ids=R-01,R-02" ]'
expected='{"commit_sha":"c1","review_result":"r1.json","recommendations":[{"id":"R-01","candidates":["C-3"],"reviewer":"security","file_line":"","description":"no location","contract":{"ref":"AC-1"},"evidence":"e3"},{"id":"R-02","candidates":["C-1","C-2"],"reviewer":"code-quality","file_line":"a.sh:3","description":"added line\nsecond","contract":{"ref":"pr","text":"t"},"evidence":"e1"}]}'
check "the registration carries the root cause's candidates, contract and evidence" \
  '[ "$(jq -cS . "$REG")" = "$(printf "%s" "$expected" | jq -cS .)" ]'
check "the review JSON is not written" '[ "$(jq -r "has(\"pr_recommendations\")" "$WORK/r1.json")" = false ]'
cp "$REG" "$WORK/reg.first.json"
record "$WORK/r1.json"
check "re-running the same commit gives the same bytes" 'cmp -s "$REG" "$WORK/reg.first.json"'
# No count limit: a later cycle of the same run registers its adopted PR-origin root causes too.
review "$WORK/r3.json" 3 c3
record "$WORK/r3.json"
check "a later cycle of the same run still registers (no per-run cap)" \
  '[ "$OUT" = "[CONTEXT] PR_RECOMMENDATIONS=registered; count=2; ids=R-01,R-02" ] && [ "$(jq -r .commit_sha "$REG")" = c3 ]'
jq '.verdicts |= map(select(.verdict != "fix"))' "$WORK/verdicts.json" > "$WORK/no-fix.json"
record "$WORK/r3.json" "$WORK/no-fix.json"
check "no fix verdict rewrites the registration empty for that commit" \
  '[ "$OUT" = "[CONTEXT] PR_RECOMMENDATIONS=none" ] && [ "$(jq -c "[.commit_sha, .recommendations]" "$REG")" = "[\"c3\",[]]" ]'
printf '{}' > "$WORK/bad.json"
record "$WORK/r3.json" "$WORK/bad.json"
check "gate output without verdicts fails" '[ $RC -eq 1 ] && [[ "$ERR" == *"reason=verdicts_invalid"* ]]'
jq 'del(.commit_sha)' "$WORK/r3.json" > "$WORK/nosha.json"
record "$WORK/nosha.json"
check "a review without commit_sha fails" '[ $RC -eq 1 ] && [[ "$ERR" == *"reason=json_invalid"* ]]'

echo "=== check / mark ==="
R="$STATE/.rite/review-results"
rm -f "$REG"
run check --pr 7 --state-root "$STATE"
check "no saved review fails" '[ $RC -eq 1 ] && [[ "$ERR" == *"reason=json_missing"* ]]'
cp "$WORK/r1.json" "$R/7-20260101000000.json"
run check --pr 7 --state-root "$STATE"
check "no registration is none" '[ $RC -eq 0 ] && [[ "$OUT" == "[CONTEXT] PR_RECOMMENDATIONS_CHECK=none; "* ]]'
record "$WORK/r1.json"
run check --pr 7 --state-root "$STATE"
check "a registration on the latest review's commit is pending" '[[ "$OUT" == "[CONTEXT] PR_RECOMMENDATIONS_CHECK=pending; count=2; json="*"7-20260101000000.json" ]]'
run mark --pr 7 --state-root "$STATE"
check "mark records the handed review" '[ $RC -eq 0 ] && [ "$(cat "$STATE/.rite/state/pr-recommendations-done-7.txt")" = "7-20260101000000.json c1" ]'
run check --pr 7 --state-root "$STATE"
check "the handed review is not pending again" '[[ "$OUT" == "[CONTEXT] PR_RECOMMENDATIONS_CHECK=none; "* ]]'
cp "$WORK/r1.json" "$R/7-20260101000005.json"
run check --pr 7 --state-root "$STATE"
check "a copy of the same reviewed commit under a new name is not pending" '[[ "$OUT" == "[CONTEXT] PR_RECOMMENDATIONS_CHECK=none; "* ]]'
cp "$WORK/r3.json" "$R/7-20260101000009.json"
run check --pr 7 --state-root "$STATE"
check "a registration on another commit is not pending for the latest review" '[[ "$OUT" == "[CONTEXT] PR_RECOMMENDATIONS_CHECK=none; "*"7-20260101000009.json" ]]'
record "$WORK/r3.json"
run check --pr 7 --state-root "$STATE"
check "a registration on the new commit is pending again" '[[ "$OUT" == *"=pending; count=2; json="*"7-20260101000009.json" ]]'
printf '{broken' > "$REG"
run check --pr 7 --state-root "$STATE"
check "an unreadable registration fails" '[ $RC -eq 1 ] && [[ "$ERR" == *"reason=json_invalid"* ]]'

echo "=== the done marker lives as long as nb-sweep-done ==="
# Every place that ends nb-sweep-done's life (fresh run, review-restart, cleanup,
# orphan GC) removes the done marker too; a stale one would hide a new run's registration.
for site in scripts/iterate-step.sh hooks/flow-state.sh hooks/scripts/cleanup-pr-state-purge.sh hooks/scripts/pr-cycle-cleanup.sh; do
  check "$site removes the done marker beside nb-sweep-done" 'grep -q "pr-recommendations-done-\${[a-z_]*}\.txt" "$PLUGIN_ROOT/$site"'
done
check "cleanup removes the registration of the merged PR" \
  'grep -q "pr-recommendations-\${[a-z_]*}\.json" "$PLUGIN_ROOT/hooks/scripts/cleanup-pr-state-purge.sh"'

echo ""
echo "=== Summary: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
