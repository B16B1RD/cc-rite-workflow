#!/bin/bash
# Behavioral fixtures for the shared CI classifier and its JSON transport.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
CLASSIFIER="$SCRIPT_DIR/../scripts/pr-checks-classify.sh"
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/pr-checks-classify-XXXXXX") || exit 1
trap 'rm -rf "$SANDBOX"' EXIT

classify() {
  local label="$1" expected="$2" input="$3"
  if RESULT=$(printf '%s' "$input" | bash "$CLASSIFIER" 2>"$SANDBOX/stderr"); then
    assert "$label state" "$expected" "$(printf '%s' "$RESULT" | jq -r '.state')"
  else
    fail "$label classifier failed: $(cat "$SANDBOX/stderr")"
    RESULT='{}'
  fi
}

checkrun() {
  jq -cn --arg status "$1" --arg conclusion "$2" \
    '{__typename:"CheckRun",name:"tests",status:$status,conclusion:(if $conclusion == "null" then null else $conclusion end),detailsUrl:"https://example.test/check"}'
}
rollup() { jq -cn --argjson checks "$1" '{statusCheckRollup:$checks}'; }

for conclusion in SUCCESS NEUTRAL SKIPPED; do
  classify "CheckRun $conclusion" healthy "$(rollup "[$(checkrun COMPLETED "$conclusion")]")"
  assert "$conclusion has no failures" '[]' "$(printf '%s' "$RESULT" | jq -c '.failed')"
done
for status in QUEUED IN_PROGRESS WAITING REQUESTED PENDING; do
  classify "CheckRun $status" pending "$(rollup "[$(checkrun "$status" null)]")"
done
for conclusion in FAILURE CANCELLED TIMED_OUT ACTION_REQUIRED STARTUP_FAILURE STALE UNKNOWN; do
  classify "CheckRun $conclusion" unhealthy "$(rollup "[$(checkrun COMPLETED "$conclusion")]")"
  assert "$conclusion preserves failure details" \
    "[{\"name\":\"tests\",\"status\":\"COMPLETED\",\"conclusion\":\"$conclusion\",\"url\":\"https://example.test/check\"}]" \
    "$(printf '%s' "$RESULT" | jq -c '.failed')"
done
for state in SUCCESS PENDING EXPECTED ERROR FAILURE; do
  case "$state" in SUCCESS) expected=healthy ;; PENDING|EXPECTED) expected=pending ;; *) expected=unhealthy ;; esac
  classify "StatusContext $state" "$expected" \
    "$(jq -cn --arg state "$state" '{statusCheckRollup:[{__typename:"StatusContext",context:"legacy",state:$state,targetUrl:"https://example.test/status"}]}')"
  assert "StatusContext $state metadata" \
    "[{\"name\":\"legacy\",\"status\":\"$state\",\"conclusion\":\"$state\",\"url\":\"https://example.test/status\"}]" \
    "$(printf '%s' "$RESULT" | jq -c '.checks')"
done
classify 'no checks' none '{"statusCheckRollup":[]}'
classify 'missing rollup' unknown '{}'
classify 'null rollup' unknown '{"statusCheckRollup":null}'
classify 'object rollup' unknown '{"statusCheckRollup":{}}'
classify 'non-object document' unknown '[]'
classify 'scalar entry' unknown '{"statusCheckRollup":[7]}'
classify 'missing status' unknown '{"statusCheckRollup":[{"__typename":"CheckRun","conclusion":"SUCCESS"}]}'
classify 'unknown typename' unknown '{"statusCheckRollup":[{"__typename":"Other"}]}'
classify 'unknown status' unknown "$(rollup "[$(checkrun FUTURE SUCCESS)]")"
classify 'missing completed conclusion' unknown "$(rollup "[$(checkrun COMPLETED null)]")"
classify 'unknown legacy state' unknown '{"statusCheckRollup":[{"__typename":"StatusContext","state":"FUTURE"}]}'
classify 'unknown precedes pending' unknown "$(rollup "[$(checkrun IN_PROGRESS null),{}]")"
classify 'pending precedes failure' pending "$(rollup "[$(checkrun IN_PROGRESS null),$(checkrun COMPLETED FAILURE)]")"
assert 'pending retains completed failure' 'tests' "$(printf '%s' "$RESULT" | jq -r '.failed[0].name')"
classify 'allowed conclusions mixed with failure' unhealthy \
  "$(rollup "[$(checkrun COMPLETED SKIPPED),$(checkrun COMPLETED NEUTRAL),$(checkrun COMPLETED FAILURE)]")"
assert 'allowed conclusions excluded from failures' 1 "$(printf '%s' "$RESULT" | jq '.failed | length')"
classify 'malformed display metadata preserves healthy classification' healthy \
  '{"statusCheckRollup":[{"__typename":"CheckRun","name":{},"status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":[]}]}'
assert 'malformed display metadata becomes null' '[{"name":null,"status":"COMPLETED","conclusion":"SUCCESS","url":null}]' \
  "$(printf '%s' "$RESULT" | jq -c '.checks')"

hostile_name='tests; $(touch should-not-exist), `command`'
classify 'job names remain data' unhealthy \
  "$(jq -cn --arg name "$hostile_name" '{statusCheckRollup:[{__typename:"CheckRun",name:$name,status:"COMPLETED",conclusion:"FAILURE"}]}')"
assert 'job name round trip' "$hostile_name" "$(printf '%s' "$RESULT" | jq -r '.failed[0].name')"

for input in '' '{' '{} {}'; do
  if printf '%s' "$input" | bash "$CLASSIFIER" >"$SANDBOX/stdout" 2>"$SANDBOX/stderr"; then
    fail "invalid input rejected: $input"
  else
    pass "invalid input rejected: $input"
  fi
  assert 'invalid input emits no JSON result' '' "$(cat "$SANDBOX/stdout")"
  assert_grep 'invalid input has diagnostic' "$SANDBOX/stderr" 'ERROR: pr-checks-classify:'
done
mkdir "$SANDBOX/bin"
printf '#!/bin/bash\nexit 42\n' >"$SANDBOX/bin/jq"
chmod +x "$SANDBOX/bin/jq"
if printf '{}' | PATH="$SANDBOX/bin:$PATH" bash "$CLASSIFIER" >"$SANDBOX/stdout" 2>"$SANDBOX/stderr"; then
  fail 'jq failure is nonzero'
else
  pass 'jq failure is nonzero'
fi
assert_grep 'jq failure is diagnosed' "$SANDBOX/stderr" 'ERROR: pr-checks-classify:'

if ! print_summary "$(basename "$0")" 'Shared classifier states, precedence, metadata, and failure transport'; then
  exit 1
fi
