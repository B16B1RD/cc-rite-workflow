#!/bin/bash
# Execute the review CI snapshot with a stubbed PR query and pin its consumers.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REVIEW="$PLUGIN_ROOT/skills/pr-review/SKILL.md"
scratch=$(mktemp -d) || exit 1
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin"
awk '
  /^#### 1\.2\.5\.C CI Check Snapshot$/ { section=1 }
  section && /^```bash$/ { code=1; next }
  code && /^```$/ { exit }
  code { print }
' "$REVIEW" | sed -e "s|{plugin_root}|$PLUGIN_ROOT|g" \
  -e 's/{pr_number}/7/g' -e 's|{owner_repo}|owner/repo|g' \
  -e 's/{current_commit_sha}/reviewed-sha/g' > "$scratch/snapshot.sh"
cat > "$scratch/bin/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" > "$CI_SCRATCH/query"
if [ "$CI_CASE" = failure ]; then
  echo 'fixture: API unavailable' >&2
  exit 1
fi
cat "$CI_SCRATCH/input.json"
STUB
cat > "$scratch/bin/sleep" <<'STUB'
#!/bin/bash
echo unexpected-wait >> "$CI_SCRATCH/wait"
exit 1
STUB
chmod +x "$scratch/bin/gh" "$scratch/bin/sleep"

snapshot() {
  CI_CASE="$1" CI_SCRATCH="$scratch" PATH="$scratch/bin:$PATH" \
    bash "$scratch/snapshot.sh" > "$scratch/out" 2> "$scratch/err"
  assert "$1 snapshot completes" 0 "$?"
  sed -n '1p' "$scratch/out" > "$scratch/result.json"
}

cat > "$scratch/input.json" <<'JSON'
{"headRefOid":"reviewed-sha","statusCheckRollup":[{"__typename":"CheckRun","name":"tests (macos)","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://example.test/jobs/1"}]}
JSON
snapshot matching
assert_grep 'matching SHA emits unhealthy and failed job' "$scratch/out" \
  '^\[CONTEXT\] REVIEW_CI_STATE=unhealthy; failed="tests \(macos\)"$'
assert 'reviewer data keeps job, conclusion, URL and target SHA' \
  '["reviewed-sha","tests (macos)","FAILURE","https://example.test/jobs/1"]' \
  "$(jq -c '[.commit_sha,.failed[0].name,.failed[0].conclusion,.failed[0].url]' "$scratch/result.json")"
assert_grep 'query pairs PR HEAD with its checks' "$scratch/query" \
  '^pr view 7 -R owner/repo --json headRefOid,statusCheckRollup$'

cp "$scratch/input.json" "$scratch/named.json"
jq 'del(.statusCheckRollup[0].name)' "$scratch/named.json" > "$scratch/input.json"
snapshot unnamed
assert_grep 'unnamed failed job remains observable' "$scratch/out" '^\[CONTEXT\] REVIEW_CI_STATE=unhealthy; failed="\(unnamed\)"$'
cp "$scratch/named.json" "$scratch/input.json"

sed 's/reviewed-sha/other-sha/' "$scratch/input.json" > "$scratch/other.json"
mv "$scratch/other.json" "$scratch/input.json"
snapshot mismatch
assert_grep 'mismatched SHA is unknown' "$scratch/out" '^\[CONTEXT\] REVIEW_CI_STATE=unknown; failed=$'
assert 'mismatched checks are discarded' 0 "$(jq '.checks | length' "$scratch/result.json")"
assert_grep 'mismatched SHA explains exclusion' "$scratch/err" 'PR HEAD.*一致しない'

snapshot failure
assert_grep 'fetch failure is unknown' "$scratch/out" '^\[CONTEXT\] REVIEW_CI_STATE=unknown; failed=$'
assert_grep 'fetch failure preserves API diagnostic' "$scratch/err" 'fixture: API unavailable'
assert 'fetch failure is retained for the report' true "$(jq '.note | contains("CI 取得に失敗")' "$scratch/result.json")"

printf '%s\n' '{"headRefOid":"reviewed-sha","statusCheckRollup":[{"__typename":"CheckRun","name":"tests","status":"IN_PROGRESS","conclusion":null}]}' > "$scratch/input.json"
snapshot pending
assert_grep 'pending remains observable' "$scratch/out" '^\[CONTEXT\] REVIEW_CI_STATE=pending; failed=$'
assert 'review does not wait' false "$([ -f "$scratch/wait" ] && echo true || echo false)"

printf '%s\n' '{"headRefOid":"reviewed-sha","statusCheckRollup":[]}' > "$scratch/input.json"
snapshot none
assert_grep 'no checks differs from healthy' "$scratch/out" '^\[CONTEXT\] REVIEW_CI_STATE=none; failed=$'
printf '%s\n' 'invalid JSON' > "$scratch/input.json"
snapshot malformed
assert_grep 'malformed response is unknown' "$scratch/out" '^\[CONTEXT\] REVIEW_CI_STATE=unknown; failed=$'
assert_grep 'malformed response explains missing HEAD' "$scratch/err" 'PR HEAD を取得できません'

for mode in generator verification; do
  prompt="$PLUGIN_ROOT/skills/pr-review/references/reviewer-prompt-$mode.md"
  assert_grep "$mode receives CI data" "$prompt" '^\{ci_status\}$'
  assert_grep "$mode requires actual failing test evidence" "$prompt" 'Verification: failing_test <path> => <失敗出力>'
  assert_grep "$mode excludes automatic blocking" "$prompt" '一律 blocking にせず'
done
assert 'both report templates include CI' 2 \
  "$(grep -c '^### CI$' "$PLUGIN_ROOT/skills/pr-review/references/integrated-report-templates.md")"
assert_grep 'CI is retained in minimized E2E output' "$REVIEW" '`### CI` は E2E でも常に表示する'
assert_grep 'E2E suffix carries CI state' "$REVIEW" '常に末尾へ `\| ci: \{ci_state\}`'
assert_grep 'report retains failure details even when pending' "$REVIEW" 'failed があれば集約 state に関係なく job 名・結論・詳細 URL'

# The snapshot remains non-blocking; finalization has a separate bounded gate.
cat > "$scratch/bin/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$CI_SCRATCH/final-query"
n=0
if [ -f "$CI_SCRATCH/query-count" ]; then n=$(cat "$CI_SCRATCH/query-count"); fi
n=$((n + 1))
printf '%s\n' "$n" > "$CI_SCRATCH/query-count"
case "$CI_CASE" in
  fetch-failure) echo 'fixture: final API unavailable' >&2; exit 1 ;;
  pending-fetch-failure) if [ "$n" -gt 1 ]; then echo 'fixture: later API unavailable' >&2; exit 1; fi ;;
esac
if [ "$n" -eq 1 ]; then cat "$CI_SCRATCH/first.json"; else cat "$CI_SCRATCH/later.json"; fi
STUB
cat > "$scratch/bin/sleep" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$CI_SCRATCH/final-wait"
if grep -q 'REVIEW_CI_FINAL=passed\|\[review:mergeable\]' "$CI_SCRATCH/final-out"; then
  echo gate-passed-early >> "$CI_SCRATCH/final-wait"
fi
STUB
chmod +x "$scratch/bin/gh" "$scratch/bin/sleep"
sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
jq -n --arg sha "$sha" '{pr_number:7,commit_sha:$sha,verdict:"mergeable",overall_assessment:"mergeable",measured_gate:{commit_sha:$sha}}' > "$scratch/review.json"
printf '%s\n' '{"headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","statusCheckRollup":[{"__typename":"CheckRun","name":"tests (macos)","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":"https://example.test/jobs/1"}]}' > "$scratch/success.json"
jq '.statusCheckRollup[0] |= (.status="IN_PROGRESS" | .conclusion=null)' "$scratch/success.json" > "$scratch/pending.json"
jq '.workflowConclusion="SUCCESS" | .statusCheckRollup[0].conclusion="FAILURE" | .statusCheckRollup[0].continueOnError=true' "$scratch/success.json" > "$scratch/unhealthy.json"
jq '.statusCheckRollup=[]' "$scratch/success.json" > "$scratch/none.json"
jq '.statusCheckRollup[0].status="FUTURE_STATUS"' "$scratch/success.json" > "$scratch/unknown.json"
jq '.headRefOid="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "$scratch/success.json" > "$scratch/mismatch.json"
cp "$scratch/success.json" "$scratch/later.json"

completion() {
  rm -f "$scratch/final-query" "$scratch/query-count" "$scratch/final-wait"
  CI_CASE="$1" CI_SCRATCH="$scratch" PATH="$scratch/bin:$PATH" \
    bash "$PLUGIN_ROOT/scripts/pr-review-step.sh" ci-completion-check \
      --owner-repo owner/repo --pr 7 --input "$scratch/review.json" \
      --wait-seconds 2 --poll-seconds 1 > "$scratch/final-out" 2> "$scratch/final-err"
  completion_rc=$?
}
completion_failed() {
  assert "$1 exits unsuccessfully" 1 "$completion_rc"
  assert_not_grep "$1 never passes or emits final mergeable" "$scratch/final-out" \
    'REVIEW_CI_FINAL=passed|\[review:mergeable\]'
}
cp "$scratch/success.json" "$scratch/first.json"
completion success
assert 'successful completion exits zero' 0 "$completion_rc"
assert_grep 'all jobs successful passes' "$scratch/final-out" 'REVIEW_CI_FINAL=passed; state=healthy; waited=0'
assert 'completion queries HEAD with checks' 'pr view 7 -R owner/repo --json headRefOid,statusCheckRollup' "$(cat "$scratch/final-query")"
assert 'success does not wait' false "$([ -f "$scratch/final-wait" ] && echo true || echo false)"

cp "$scratch/pending.json" "$scratch/first.json"
completion pending-success
assert 'pending to success exits zero' 0 "$completion_rc"
assert 'pending re-fetches after sleep' 2 "$(cat "$scratch/query-count")"
assert 'pending waits exactly once without an early pass' 1 "$(cat "$scratch/final-wait")"
assert_grep 'success after wait passes only after re-fetch' "$scratch/final-out" 'REVIEW_CI_FINAL=passed; state=healthy; waited=1'
cp "$scratch/pending.json" "$scratch/later.json"
completion timeout
completion_failed timeout
assert 'bounded pending queries initial and both polls' 3 "$(cat "$scratch/query-count")"
assert 'bounded pending waits twice' 2 "$(wc -l < "$scratch/final-wait" | tr -d ' ')"
assert_grep 'timeout reports unverified stop' "$scratch/final-out" 'REVIEW_CI_FINAL=error; reason=timeout'

cp "$scratch/unhealthy.json" "$scratch/first.json"
cp "$scratch/success.json" "$scratch/later.json"
completion continue-on-error
completion_failed continue-on-error
assert_grep 'failed job name is reported despite workflow success' "$scratch/final-out" 'REVIEW_CI_FINAL=failed; reason=unhealthy; failed="tests \(macos\)"'
sed -n '1p' "$scratch/final-out" > "$scratch/final-result.json"
assert 'failed proof keeps reviewed SHA, name, conclusion and URL' \
  '["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","tests (macos)","FAILURE","https://example.test/jobs/1"]' \
  "$(jq -c '[.commit_sha,.failed[0].name,.failed[0].conclusion,.failed[0].url]' "$scratch/final-result.json")"
cp "$scratch/pending.json" "$scratch/first.json"
cp "$scratch/unhealthy.json" "$scratch/later.json"
completion pending-failure
completion_failed pending-failure
assert_grep 'completion catches failure occurring during review' "$scratch/final-out" 'REVIEW_CI_FINAL=failed; reason=unhealthy'
jq --slurpfile pending "$scratch/pending.json" '.statusCheckRollup += $pending[0].statusCheckRollup' "$scratch/unhealthy.json" > "$scratch/first.json"
completion mixed-pending-failure
completion_failed mixed-pending-failure
assert 'mixed failed and pending jobs wait for the pending job' 1 "$(cat "$scratch/final-wait")"
assert 'mixed jobs are re-fetched before failure is final' 2 "$(cat "$scratch/query-count")"

cp "$scratch/none.json" "$scratch/first.json"
completion none
assert 'no checks succeeds' 0 "$completion_rc"
assert_grep 'no checks passes explicitly' "$scratch/final-out" 'REVIEW_CI_FINAL=passed; state=none; waited=0'
assert 'no checks does not wait' false "$([ -f "$scratch/final-wait" ] && echo true || echo false)"
completion fetch-failure
completion_failed fetch-failure
assert_grep 'fetch failure preserves diagnostic' "$scratch/final-err" 'fixture: final API unavailable'
cp "$scratch/pending.json" "$scratch/first.json"
completion pending-fetch-failure
completion_failed pending-fetch-failure
assert_grep 'later fetch failure stops explicitly' "$scratch/final-out" 'REVIEW_CI_FINAL=error; reason=fetch_failed'
cp "$scratch/unknown.json" "$scratch/first.json"
completion unknown
completion_failed unknown
assert_grep 'unknown state is an error' "$scratch/final-out" 'REVIEW_CI_FINAL=error; reason=state_unknown'
printf '%s\n' invalid-json > "$scratch/first.json"
completion malformed
completion_failed malformed
cp "$scratch/mismatch.json" "$scratch/first.json"
completion mismatch
completion_failed mismatch
assert_grep 'mismatched HEAD is an error' "$scratch/final-out" 'REVIEW_CI_FINAL=error; reason=head_mismatch'
cp "$scratch/pending.json" "$scratch/first.json"
cp "$scratch/mismatch.json" "$scratch/later.json"
completion head-changed
completion_failed head-changed
assert_grep 'head movement during wait is checked' "$scratch/final-out" 'REVIEW_CI_FINAL=error; reason=head_mismatch'

jq '.verdict="fix-needed" | .overall_assessment="fix-needed"' "$scratch/review.json" > "$scratch/fix-needed.json"
mv "$scratch/fix-needed.json" "$scratch/review.json"
completion fix-needed
assert 'fix-needed bypass exits zero' 0 "$completion_rc"
assert_grep 'fix-needed has explicit skip' "$scratch/final-out" 'REVIEW_CI_FINAL=skipped; reason=fix_needed'
assert 'fix-needed does not query' false "$([ -f "$scratch/final-query" ] && echo true || echo false)"
assert 'fix-needed does not wait' false "$([ -f "$scratch/final-wait" ] && echo true || echo false)"
jq '.measured_gate.commit_sha="different"' "$scratch/review.json" > "$scratch/invalid-result.json"
mv "$scratch/invalid-result.json" "$scratch/review.json"
completion invalid-result
completion_failed invalid-result
assert_grep 'invalid measured result cannot bypass checks' "$scratch/final-out" 'REVIEW_CI_FINAL=error; reason=review_result_invalid'
for pair in '--wait-seconds -1' '--poll-seconds 0' '--wait-seconds 08'; do
  # Deliberate split of these fixed option/value fixtures.
  # shellcheck disable=SC2086
  bash "$PLUGIN_ROOT/scripts/pr-review-step.sh" ci-completion-check \
    --owner-repo owner/repo --pr 7 --input "$scratch/review.json" $pair > "$scratch/argument-out" 2>&1
  assert "reject invalid wait option $pair" 2 "$?"
done

# Pin the skill's failure routing, not just individual success/failure counts.
python3 - "$REVIEW" <<'PY'
import re,sys
text=open(sys.argv[1]).read()
start=text.index('#### 5.3.0.CI ')
end=text.index('### 5.3.8 ',start)
section=text[start:end]
assert start < text.index('### 5.4 ') < text.index('## ステップ 6:')
assert 'ci-completion-check' in section and 'report/save は実行しない' in section
steps=re.split(r'\n[1-4]\. ',section)[1:]
assert len(steps)==4
assert 'failed job 証跡' in steps[0] and '--log-failed' in steps[0]
assert '未選定担当' in steps[1] and 'selection / manifest' in steps[1]
assert '変更せず保持' in steps[1] and 'review-restart' in steps[1] and '[review:error]' in steps[1]
assert '原 raw を保持' in steps[1] and '新 raw の別ファイル' in steps[1]
assert '再生成不能' in steps[1] and '[review:error]' in steps[1]
order=['completion','likelihood','AC 検証','JSON authoring','measured-gate','CI 再確認']
positions=[steps[2].index(token) for token in order]
assert positions==sorted(positions)
assert '検証失敗' in steps[2] and 'report/save は実行しない' in steps[2]
assert 'CI 失敗が継続し blocking 0' in steps[3]
assert '最終 mergeable を出力せず' in steps[3] and 'report/save は実行しない' in steps[3]
PY
assert 'CI failure retry routing precedes reports and saving' 0 "$?"
print_summary
