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
print_summary
