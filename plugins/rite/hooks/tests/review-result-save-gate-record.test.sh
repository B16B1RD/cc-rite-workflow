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

# 書式違反による保存拒否は exit 0 + LOCAL_SAVE_FAILED + JSON_SAVED=false で表す。
_nb_finding() {
  jq -n --arg id "$1" '{id:$id, reviewer:"code-quality-reviewer", severity:"LOW",
    file:"a.md", line:1, description:"d", suggestion:"s", status:"open", scope:"current-pr"}'
}

run_id_case() {
  local name="$1" body="$2" expect_saved="$3" expect_union="${4:-no}" rc=0
  local dir="$TMP_ROOT/$name"
  printf '%s\n' "$body" > "$TMP_ROOT/$name.json"
  bash "$SAVE" --pr 2563 --content-file "$TMP_ROOT/$name.json" --results-dir "$dir" \
    >/dev/null 2>"$TMP_ROOT/$name.err" || rc=$?
  if [ "$expect_saved" = "no" ]; then
    assert "$name rc" "0" "$rc"
    assert_grep "$name reason" "$TMP_ROOT/$name.err" 'reason=finding_id_format_or_uniqueness_violation'
    assert_grep "$name JSON_SAVED=false" "$TMP_ROOT/$name.err" 'JSON_SAVED=false'
    assert "$name ファイルを残さない" "0" "$(find "$dir" -type f -name '2563-*.json' 2>/dev/null | wc -l | tr -d ' ')"
  else
    assert_grep "$name saved" "$TMP_ROOT/$name.err" 'JSON_SAVED=true'
    assert "$name ファイルを残す" "1" "$(find "$dir" -type f -name '2563-*.json' | wc -l | tr -d ' ')"
    assert_not_grep "$name id reason なし" "$TMP_ROOT/$name.err" 'reason=finding_id_format_or_uniqueness_violation'
    # ゲート (2) は和集合の**一意性のみ**を非ブロッキング marker で報告する。両方向を pin しないと
    # ゲート丸ごとの削除も常時発火もテストを素通りする (marker が唯一の観測可能出力のため)。
    if [ "$expect_union" = "yes" ]; then
      assert_grep "$name union marker" "$TMP_ROOT/$name.err" 'NON_BLOCKING_FINDINGS_ID_UNION_VIOLATION=1'
    else
      assert_not_grep "$name union marker なし" "$TMP_ROOT/$name.err" 'NON_BLOCKING_FINDINGS_ID_UNION_VIOLATION'
    fi
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
  yes yes
# 末尾改行付き id は書式違反 (jq の `$` は末尾改行の直前にも一致するため明示排除が要る)
run_id_case nb_id_trailing_newline \
  "$(make_body "$SENTINEL" abc1234 abc1234 true | jq --argjson f "$(_nb_finding 'F-05')" '.non_blocking_findings = [($f | .id = "F-05\n")]')" \
  no
# 書式が正しければ和集合でも保存される
run_id_case union_id_ok \
  "$(make_body "$SENTINEL" abc1234 abc1234 true | jq --argjson a "$(_nb_finding F-01)" --argjson b "$(_nb_finding F-02)" '.findings = [$a] | .non_blocking_findings = [$b]')" \
  yes
# 非配列の non_blocking_findings は型 check の非ブロッキング marker に留まり id gate を hard fail に化けさせない
run_id_case nb_non_array \
  "$(make_body "$SENTINEL" abc1234 abc1234 true | jq '.non_blocking_findings = "abc"')" \
  yes

print_summary "review-result-save gate record"
