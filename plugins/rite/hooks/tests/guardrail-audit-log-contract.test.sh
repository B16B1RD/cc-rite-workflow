#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
ROOT="$SCRIPT_DIR/../.."
BASE="$ROOT/agents/_reviewer-base.md"
GEN="$ROOT/skills/pr-review/references/reviewer-prompt-generator.md"
SKILL="$ROOT/skills/pr-review/SKILL.md"
TEMPLATES="$ROOT/skills/pr-review/references/integrated-report-templates.md"
SCHEMA="$ROOT/references/review-result-schema.md"
ARCHIVER="$ROOT/hooks/scripts/review-results-archive-or-rm.sh"

assert_grep "base requires Category #2 audit rows" "$BASE" 'Category #2 items MUST be listed'
assert_grep "base defines empty handling" "$BASE" 'When no item is logged, emit `なし`'
assert_grep "generated reviewer prompt contains audit section" "$GEN" '^### 監査ログ$'
assert_grep "collector retains Category #2 rows" "$SKILL" 'Category #2.*guardrail_audit_log'
assert_grep "collector derives the E2E display count from the array" "$SKILL" 'guardrail_audit_count = guardrail_audit_log\.length'
assert_grep "E2E minimization exempts audit output" "$SKILL" '例外 4:.*Guardrail 監査ログ.*guardrail_audit_count > 0'

full_count=$(awk '/^## full-mode-template$/{mode=1} mode && /^```markdown$/{fence=1; next} mode && fence && /^```$/{exit} mode && fence' "$TEMPLATES" | grep -c '^### Guardrail 監査ログ' || true)
verification_count=$(awk '/^## verification-mode-template$/{mode=1} mode && /^```markdown$/{fence=1; next} mode && fence && /^```$/{exit} mode && fence' "$TEMPLATES" | grep -c '^### Guardrail 監査ログ' || true)
assert "full report template renders audit log exactly once" "1" "$full_count"
assert "verification report template renders audit log exactly once" "1" "$verification_count"
assert_grep "collector and schema use canonical reviewer key" "$SKILL" 'guardrail_audit_log.*`reviewer`, `filter_category`'
assert_grep "collector enumerates all 7 canonical keys" "$SKILL" '`reviewer`, `filter_category`, `original_severity`, `file_line`, `description`, `filter_reason`, `verification`'
assert_grep "collector maps 除外した内容 to description" "$SKILL" '除外した内容→`description`'
assert_grep "collector maps 除外理由 to filter_reason" "$SKILL" '除外理由→`filter_reason`'
assert_grep "schema has durable audit array" "$SCHEMA" '^[|] `guardrail_audit_log` [|] array [|]'
assert_grep "cleanup preserves non-empty audit arrays" "$ARCHIVER" 'guardrail_audit_log.*length > 0'

SAVE="$ROOT/hooks/review-result-save.sh"
assert_file_exists_or_fail "review-result-save.sh exists" "$SAVE" || true
SENTINEL='__RITE_TS_PLACEHOLDER_7f3a9b2c__'
sandbox=$(make_plain_sandbox)
trap 'rm -rf -- "$sandbox"' EXIT HUP INT TERM

KEYS_JQ='def expected: ["description","file_line","filter_category","filter_reason","original_severity","reviewer","verification"];
has("guardrail_audit_log")
and (.guardrail_audit_log | type == "array")
and (.guardrail_audit_log | all((type == "object") and ((keys | sort) == expected)))'

write_save_json() {
  local path=$1
  cat > "$path"
}

base_save_fields() {
  cat <<EOF
  "schema_version": "1.1.0",
  "pr_number": 123,
  "timestamp": "$SENTINEL",
  "verdict": "mergeable",
  "reviewers": ["code-quality-reviewer", "security-reviewer"],
  "findings": []
EOF
}

canonical_entry='{"reviewer":"code-quality-reviewer","filter_category":"Category #2","original_severity":"MEDIUM","file_line":"src/a.ts:1","description":"filtered","filter_reason":"hypothetical","verification":"なし"}'
warped_entry='{"reviewer":"code-quality-reviewer","filter_category":"Category #2","original_severity":"MEDIUM","file_line":"src/a.ts:1","filtered_suggestion":"filtered","failed_condition":"hypothetical","verification":"なし"}'
missing_entry='{"reviewer":"code-quality-reviewer","filter_category":"Category #2","file_line":"src/a.ts:1","description":"filtered","filter_reason":"hypothetical","verification":"なし"}'

run_save_on() {
  local json=$1 dest=$2
  mkdir -p "$dest"
  bash "$SAVE" --pr 123 --content-file "$json" --results-dir "$dest" >"$sandbox/save.out" 2>"$sandbox/save.err" || true
}

# T-02 / T-06 / T-01(f) valid: 7 keys + empty array
ok_json="$sandbox/ok.json"
write_save_json "$ok_json" <<EOF
{
$(base_save_fields),
  "guardrail_audit_log": [$canonical_entry]
}
EOF
jq_rc=0
jq -e "$KEYS_JQ" "$ok_json" >/dev/null || jq_rc=$?
assert "T-02/T-01(f) valid 7-key jq predicate rc=0" "0" "$jq_rc"

run_save_on "$ok_json" "$sandbox/results-ok"
assert_grep "T-02 save JSON_SAVED=true" "$sandbox/save.err" 'JSON_SAVED=true'
assert_not_grep "T-02 no LOCAL_SAVE_FAILED" "$sandbox/save.err" 'LOCAL_SAVE_FAILED'
saved=$(find "$sandbox/results-ok" -name '123-*.json' | head -1)
assert "T-02 saved file exists" "1" "$([ -n "$saved" ] && [ -f "$saved" ] && echo 1 || echo 0)"
if [ -n "$saved" ] && [ -f "$saved" ]; then
  keys=$(jq -r '.guardrail_audit_log[0] | keys | sort | join(",")' "$saved")
  assert "T-02 saved exact 7 keys" "description,file_line,filter_category,filter_reason,original_severity,reviewer,verification" "$keys"
fi

empty_json="$sandbox/empty.json"
write_save_json "$empty_json" <<EOF
{
$(base_save_fields),
  "guardrail_audit_log": []
}
EOF
jq_rc=0
jq -e "$KEYS_JQ" "$empty_json" >/dev/null || jq_rc=$?
assert "T-06 empty array jq predicate rc=0" "0" "$jq_rc"
run_save_on "$empty_json" "$sandbox/results-empty"
assert_grep "T-06 save JSON_SAVED=true" "$sandbox/save.err" 'JSON_SAVED=true'
saved=$(find "$sandbox/results-empty" -name '123-*.json' | head -1)
if [ -n "$saved" ] && [ -f "$saved" ]; then
  assert "T-06 saved guardrail_audit_log is []" "[]" "$(jq -c '.guardrail_audit_log' "$saved")"
else
  fail "T-06 saved file exists"
fi

# T-01 / T-04 warped keys (description/filter_reason replaced)
warped_json="$sandbox/warped.json"
write_save_json "$warped_json" <<EOF
{
$(base_save_fields),
  "guardrail_audit_log": [$warped_entry]
}
EOF
jq_rc=0
jq -e "$KEYS_JQ" "$warped_json" >/dev/null || jq_rc=$?
assert "T-01 warped jq predicate rc!=0" "1" "$([ "$jq_rc" -ne 0 ] && echo 1 || echo 0)"
run_save_on "$warped_json" "$sandbox/results-warped"
assert_grep "T-01 LOCAL_SAVE_FAILED keys_violation" "$sandbox/save.err" 'LOCAL_SAVE_FAILED=1; reason=guardrail_audit_log_keys_violation'
assert "T-01 warped not saved" "0" "$(find "$sandbox/results-warped" -name '123-*.json' 2>/dev/null | wc -l | tr -d ' ')"

# T-05 missing original_severity
miss_json="$sandbox/missing-key.json"
write_save_json "$miss_json" <<EOF
{
$(base_save_fields),
  "guardrail_audit_log": [$missing_entry]
}
EOF
run_save_on "$miss_json" "$sandbox/results-miss"
assert_grep "T-05 missing key keys_violation" "$sandbox/save.err" 'LOCAL_SAVE_FAILED=1; reason=guardrail_audit_log_keys_violation'
assert "T-05 missing key not saved" "0" "$(find "$sandbox/results-miss" -name '123-*.json' 2>/dev/null | wc -l | tr -d ' ')"

# top-level key missing / non-array
nokey_json="$sandbox/nokey.json"
write_save_json "$nokey_json" <<EOF
{
$(base_save_fields)
}
EOF
run_save_on "$nokey_json" "$sandbox/results-nokey"
assert_grep "top-level key missing keys_violation" "$sandbox/save.err" 'LOCAL_SAVE_FAILED=1; reason=guardrail_audit_log_keys_violation'
assert "top-level key missing not saved" "0" "$(find "$sandbox/results-nokey" -name '123-*.json' 2>/dev/null | wc -l | tr -d ' ')"

nonarr_json="$sandbox/nonarr.json"
write_save_json "$nonarr_json" <<EOF
{
$(base_save_fields),
  "guardrail_audit_log": {}
}
EOF
run_save_on "$nonarr_json" "$sandbox/results-nonarr"
assert_grep "non-array keys_violation" "$sandbox/save.err" 'LOCAL_SAVE_FAILED=1; reason=guardrail_audit_log_keys_violation'
assert "non-array not saved" "0" "$(find "$sandbox/results-nonarr" -name '123-*.json' 2>/dev/null | wc -l | tr -d ' ')"

print_summary
