#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
SAVE="$SCRIPT_DIR/../review-result-save.sh"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
SENTINEL="__RITE_TS_PLACEHOLDER_7f3a9b2c__"

make_body() {
  jq -n --arg ts "$1" --arg top "$2" --arg gate "$3" --argjson include_gate "$4" '
    {schema_version:"1.1.0", pr_number:2563, timestamp:$ts, commit_sha:$top,
     verdict:"mergeable", reviewers:["code-quality-reviewer"], findings:[], guardrail_audit_log:[]}
    + (if $include_gate then {measured_gate:{commit_sha:$gate, applied_at:"2026-01-01T00:00:00Z", blocking:0, demoted:0, anchor_undetermined:0}} else {} end)'
}

run_case() {
  local name="$1" body="$2" expected_rc="$3" reason="$4" rc=0 saved
  local dir="$TMP_ROOT/$name"
  printf '%s\n' "$body" > "$TMP_ROOT/$name.json"
  bash "$SAVE" --pr 2563 --content-file "$TMP_ROOT/$name.json" --results-dir "$dir" \
    >/dev/null 2>"$TMP_ROOT/$name.err" || rc=$?
  assert "$name rc" "$expected_rc" "$rc"
  if [ -n "$reason" ]; then
    assert_grep "$name reason" "$TMP_ROOT/$name.err" "reason=$reason"
  else
    assert_grep "$name saved" "$TMP_ROOT/$name.err" 'JSON_SAVED=true'
    saved=$(find "$dir" -type f -name '2563-*.json' | head -1)
    assert_not_grep "$name timestamp injected" "$saved" "$SENTINEL"
  fi
}

run_case missing_gate "$(make_body "$SENTINEL" abc1234 abc1234 false)" 1 gate_not_applied
run_case mixed_cycle "$(make_body "$SENTINEL" abc1234 def5678 true)" 1 gate_record_mismatch
run_case bad_timestamp "$(make_body '2026-01-01T00:00:00+09:00' abc1234 abc1234 true)" 1 timestamp_not_injected
run_case incomplete_gate "$(make_body "$SENTINEL" abc1234 abc1234 true | jq 'del(.measured_gate.applied_at)')" 1 gate_not_applied
run_case bad_gate_stats "$(make_body "$SENTINEL" abc1234 abc1234 true | jq '.measured_gate.blocking = -1')" 1 gate_not_applied
run_case valid "$(make_body "$SENTINEL" abc1234 abc1234 true)" 0 ""

print_summary "review-result-save gate record"
