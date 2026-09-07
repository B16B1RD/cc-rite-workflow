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

# --- id 書式検査は findings[] と non_blocking_findings[] の和集合で hard fail (Issue 2593 AC-6 / T-06) ---
#
# AC-6 の文言は「非ゼロ終了」だが、本 codebase の hard fail は `exit 0` + `LOCAL_SAVE_FAILED` +
# `JSON_SAVED=false` (= 保存しない) で表現される。rc=1 は provenance 契約違反 3 種に予約されており、
# 4 つ目を足すと `skills/pr-review/SKILL.md` の reason 列挙 (15 件) / rc=1 列挙 (3 種) が stale に
# なるが、当該ファイルは本 Issue の Non-Target。したがって assert は rc ではなく
# 「保存されない」+「reason が出る」に置く (Decision Log D-05)。
_nb_finding() {
  jq -n --arg id "$1" '{id:$id, reviewer:"code-quality-reviewer", severity:"LOW",
    file:"a.md", line:1, description:"d", suggestion:"s", status:"open", scope:"current-pr"}'
}

run_id_case() {
  local name="$1" body="$2" expect_saved="$3" rc=0
  local dir="$TMP_ROOT/$name"
  printf '%s\n' "$body" > "$TMP_ROOT/$name.json"
  bash "$SAVE" --pr 2563 --content-file "$TMP_ROOT/$name.json" --results-dir "$dir" \
    >/dev/null 2>"$TMP_ROOT/$name.err" || rc=$?
  if [ "$expect_saved" = "no" ]; then
    assert_grep "$name reason" "$TMP_ROOT/$name.err" 'reason=finding_id_format_or_uniqueness_violation'
    assert_grep "$name JSON_SAVED=false" "$TMP_ROOT/$name.err" 'JSON_SAVED=false'
    assert "$name ファイルを残さない" "0" "$(find "$dir" -type f -name '2563-*.json' 2>/dev/null | wc -l | tr -d ' ')"
  else
    assert_grep "$name saved" "$TMP_ROOT/$name.err" 'JSON_SAVED=true'
    assert_not_grep "$name id reason なし" "$TMP_ROOT/$name.err" 'reason=finding_id_format_or_uniqueness_violation'
  fi
}

# non_blocking_findings[] 側の書式外 id (H-01) で保存が止まる
run_id_case nb_id_format \
  "$(make_body "$SENTINEL" abc1234 abc1234 true | jq --argjson f "$(_nb_finding H-01)" '.non_blocking_findings = [$f]')" \
  no
# findings[] 側の書式外 id も従来どおり止まる (非回帰)
run_id_case blocking_id_format \
  "$(make_body "$SENTINEL" abc1234 abc1234 true | jq --argjson f "$(_nb_finding H-01)" '.findings = [$f] | .non_blocking_findings = []')" \
  no
# non_blocking_findings[] 側に閉じた**一意性**違反は非ブロッキングのまま (保存は続行)
run_id_case nb_id_duplicate \
  "$(make_body "$SENTINEL" abc1234 abc1234 true | jq --argjson f "$(_nb_finding F-01)" '.non_blocking_findings = [$f, $f]')" \
  yes
# 書式が正しければ和集合でも保存される
run_id_case union_id_ok \
  "$(make_body "$SENTINEL" abc1234 abc1234 true | jq --argjson a "$(_nb_finding F-01)" --argjson b "$(_nb_finding F-02)" '.findings = [$a] | .non_blocking_findings = [$b]')" \
  yes
# 非配列の non_blocking_findings は型 check の非ブロッキング marker に留まり id gate を hard fail に化けさせない
run_id_case nb_non_array \
  "$(make_body "$SENTINEL" abc1234 abc1234 true | jq '.non_blocking_findings = "abc"')" \
  yes

print_summary "review-result-save gate record"
