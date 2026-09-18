#!/bin/bash
# Block Ready / merge when the target PR's head is not the latest reviewed commit.
# The head under comparison is the PR's headRefOid in the named repository, never
# the local checkout: a checkout of another commit must not reject a reviewed PR,
# and a local match must not pass a PR whose head moved on.
# Reviewed commit := .commit_sha of the newest .rite/review-results/{pr}-*.json
# (schema field; PR-comment marker name is reviewed_commit). Archive is not
# a current result, so this helper never reads it.
# Sweep exception: after JSON mismatch, line 2 of
# nb-sweep-done-{pr}.txt may name the one known sweep commit.
set -u
pr_number=""; owner_repo=""; plugin_root=""; results_dir=""; state_root=""
ac_mode="inspect"; attest_ids=""; skip_head_check=0
results_dir_explicit=0
state_root_explicit=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pr)
      [ "$#" -ge 2 ] || { echo "ERROR: Ready reviewed-head gate: --pr requires a value" >&2; exit 2; }
      pr_number="$2"; shift 2 ;;
    --repo)
      [ "$#" -ge 2 ] || { echo "ERROR: Ready reviewed-head gate: --repo requires a value" >&2; exit 2; }
      owner_repo="$2"; shift 2 ;;
    --plugin-root)
      [ "$#" -ge 2 ] || { echo "ERROR: Ready reviewed-head gate: --plugin-root requires a value" >&2; exit 2; }
      plugin_root="$2"; shift 2 ;;
    --results-dir)
      [ "$#" -ge 2 ] || { echo "ERROR: Ready reviewed-head gate: --results-dir requires a value" >&2; exit 2; }
      results_dir="$2"; results_dir_explicit=1; shift 2 ;;
    --state-root)
      [ "$#" -ge 2 ] || { echo "ERROR: Ready reviewed-head gate: --state-root requires a value" >&2; exit 2; }
      state_root="$2"; state_root_explicit=1; shift 2 ;;
    --attest)
      [ "$#" -ge 2 ] || { echo "ERROR: Ready reviewed-head gate: --attest requires AC IDs" >&2; exit 2; }
      [ "$ac_mode" = inspect ] || { echo "ERROR: Ready reviewed-head gate: AC modes are mutually exclusive" >&2; exit 2; }
      ac_mode="attest"; attest_ids="$2"; shift 2 ;;
    --enforce-ac)
      [ "$ac_mode" = inspect ] || { echo "ERROR: Ready reviewed-head gate: AC modes are mutually exclusive" >&2; exit 2; }
      ac_mode="enforce"; shift ;;
    --skip-head-check)
      skip_head_check=1; shift ;;
    *) echo "ERROR: Ready reviewed-head gate: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ "$skip_head_check" -eq 0 ] || [ "$ac_mode" = enforce ] || { echo "ERROR: Ready reviewed-head gate: --skip-head-check requires --enforce-ac" >&2; exit 2; }
case "$pr_number" in ''|*[!0-9]*) echo "ERROR: Ready reviewed-head gate: PR number is required" >&2; exit 2 ;; esac
[ -n "$owner_repo" ] || { echo "ERROR: Ready reviewed-head gate: --repo OWNER/REPO is required" >&2; exit 2; }
if [ -z "$results_dir" ]; then
  [ -n "$plugin_root" ] || { echo "ERROR: Ready reviewed-head gate: --plugin-root is required when --results-dir is omitted" >&2; exit 2; }
  [ -x "$plugin_root/hooks/state-path-resolve.sh" ] || {
    echo "ERROR: Ready reviewed-head gate: state-path-resolve.sh not found. 照合不能のため Ready 化を拒否します。" >&2
    exit 1
  }
  results_dir=$(bash "$plugin_root/hooks/state-path-resolve.sh")/.rite/review-results || {
    echo "ERROR: Ready reviewed-head gate: state root を解決できません。照合不能のため Ready 化を拒否します。" >&2
    exit 1
  }
fi

# No fallback to the local checkout: an unresolved PR head is a refusal.
_pr_head_unresolved() {
  echo "ERROR: Ready reviewed-head gate: PR #$pr_number ($owner_repo) の head を解決できません: $1。照合不能のため拒否します。" >&2
  echo "[CONTEXT] READY_REVIEWED_HEAD=pr_head_unresolved; pr=$pr_number" >&2
  exit 1
}
head_sha=$(gh pr view "$pr_number" -R "$owner_repo" --json headRefOid --jq '.headRefOid') \
  || _pr_head_unresolved "gh pr view に失敗しました"
head_sha=$(printf '%s' "$head_sha" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
case "$head_sha" in
  '') _pr_head_unresolved "headRefOid が空です" ;;
  *[!0-9a-f]*) _pr_head_unresolved "headRefOid が SHA ではありません (received: '$head_sha')" ;;
esac
[ "${#head_sha}" -eq 40 ] || _pr_head_unresolved "headRefOid が完全な SHA ではありません (received: '$head_sha')"

_sha_matches() {
  [ "${#1}" -ge 7 ] && [ "${#2}" -ge 7 ] || return 1
  case "$2" in "$1"*) return 0 ;; esac
  case "$1" in "$2"*) return 0 ;; esac
  return 1
}

_check_acceptance_criteria() {
  local ac_type invalid ids ids_tmp tmp now
  if ! ac_type=$(jq -r 'if has("acceptance_criteria") then (.acceptance_criteria | type) else "missing" end' "$latest" 2>/dev/null); then
    echo "[CONTEXT] REVIEWED_AC=malformed; reason=invalid_json; file=$latest" >&2
    return 1
  fi
  if [ "$ac_type" = missing ]; then
    echo "  次の行動: /rite:pr-review を再実行してください。" >&2
    echo "[CONTEXT] REVIEWED_AC=missing; file=$latest" >&2
    return 1
  fi
  if [ "$ac_type" = object ]; then
    if jq -e '.acceptance_criteria | keys == ["skipped"] and (.skipped == "no_issue" or .skipped == "no_ac_section")' "$latest" >/dev/null 2>&1; then
      echo "[CONTEXT] REVIEWED_AC=skipped; file=$latest" >&2
      return 0
    fi
    echo "[CONTEXT] REVIEWED_AC=malformed; reason=invalid_skipped; file=$latest" >&2
    return 1
  fi
  if [ "$ac_type" != array ]; then
    echo "[CONTEXT] REVIEWED_AC=malformed; reason=not_array_or_skipped; file=$latest" >&2
    return 1
  fi
  if ! jq -e '.acceptance_criteria | length > 0 and ([.[].id] | length == (unique | length))' "$latest" >/dev/null 2>&1; then
    echo "[CONTEXT] REVIEWED_AC=malformed; reason=empty_or_duplicate_ids; file=$latest" >&2
    return 1
  fi
  if ! invalid=$(jq -r --arg head "$reviewed" '
    [.acceptance_criteria[] |
      select((type != "object") or
        ((.id | type) != "string") or (.id | test("^AC-[0-9]+$") | not) or
        ((.status | type) != "string") or
        ((.evidence | type) != "string") or (.evidence | length == 0) or
        (has("finding_id") | not) or
        (.status == "unmet" and (((.finding_id | type) != "string") or (.finding_id | test("^F-[0-9]{2,}$") | not))) or
        (.status != "unmet" and .finding_id != null) or
        (.status != "human-verified" and (has("head") or has("at"))) or
        (.status != "satisfied" and .status != "unmet" and .status != "unverified" and .status != "human-verified") or
        (.status == "human-verified" and
          (((.head | type) != "string") or ((.at | type) != "string") or
           ((.head | ascii_downcase) != $head) or
           (.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{2}:[0-9]{2})$") | not))))] | length
  ' "$latest" 2>/dev/null); then
    echo "[CONTEXT] REVIEWED_AC=malformed; reason=ac_query_failed; file=$latest" >&2
    return 1
  fi
  if [ "$invalid" -ne 0 ] 2>/dev/null; then
    echo "[CONTEXT] REVIEWED_AC=malformed; reason=invalid_row_or_attestation; file=$latest" >&2
    return 1
  fi

  case "$ac_mode" in
    attest)
      ids=$(printf '%s' "$attest_ids" | tr ',' '\n' | tr ' ' '\n' | sed '/^$/d')
      [ -n "$ids" ] || { echo "[CONTEXT] REVIEWED_AC=malformed; reason=empty_attest_ids; file=$latest" >&2; return 1; }
      if [ "$(printf '%s\n' "$ids" | sort | uniq -d | wc -l | tr -d '[:space:]')" -ne 0 ] ||
         ! printf '%s\n' "$ids" | awk '/^AC-[0-9]+$/{next}{exit 1}'; then
        echo "[CONTEXT] REVIEWED_AC=malformed; reason=duplicate_or_invalid_attest_ids; file=$latest" >&2
        return 1
      fi
      ids_tmp="$latest.ids.tmp.$$"
      if ! printf '%s\n' "$ids" | jq -R -s 'split("\n") | map(select(length > 0))' > "$ids_tmp"; then
        rm -f "$ids_tmp"; echo "[CONTEXT] REVIEWED_AC=malformed; reason=attest_ids_encode_failed; file=$latest" >&2; return 1
      fi
      if ! jq -e --slurpfile ids "$ids_tmp" '
        ($ids[0]) as $want |
        ([.acceptance_criteria[].id] | length == (unique | length)) and
        ([$want[] as $id | [.acceptance_criteria[] | select(.id == $id)] |
          (length == 1 and .[0].status == "unverified")] | all)
      ' "$latest" >/dev/null 2>&1; then
        rm -f "$ids_tmp"
        echo "  次の行動: 修正または Issue の AC 訂正後に /rite:pr-review を再実行してください。" >&2
        echo "[CONTEXT] REVIEWED_AC=malformed; reason=unknown_duplicate_or_mixed_attest_ids; file=$latest" >&2
        return 1
      fi
      if ! now=$(date -u +'%Y-%m-%dT%H:%M:%SZ'); then
        rm -f "$ids_tmp"
        echo "[CONTEXT] REVIEWED_AC=malformed; reason=attest_time_failed; file=$latest" >&2
        return 1
      fi
      tmp="$latest.tmp.$$"
      if ! jq --slurpfile ids "$ids_tmp" --arg head "$reviewed" --arg at "$now" '
        ($ids[0]) as $want | .acceptance_criteria |= map(
          if (.id as $id | $want | index($id)) != null
          then .status = "human-verified" | .head = $head | .at = $at
          else . end)
      ' "$latest" > "$tmp" || ! mv "$tmp" "$latest"; then
        rm -f "$tmp" "$ids_tmp"
        echo "[CONTEXT] REVIEWED_AC=malformed; reason=attest_write_failed; file=$latest" >&2
        return 1
      fi
      rm -f "$ids_tmp"
      echo "[CONTEXT] REVIEWED_AC=attested; ac=$(printf '%s' "$ids" | paste -sd, -); head=$reviewed; file=$latest" >&2
      ;;
    enforce)
      if ! ids=$(jq -r '[.acceptance_criteria[] | select(.status == "unmet") | .id] | join(",")' "$latest"); then
        echo "[CONTEXT] REVIEWED_AC=malformed; reason=ac_query_failed; file=$latest" >&2; return 1
      fi
      if [ -n "$ids" ]; then
        echo "[CONTEXT] REVIEWED_AC=unmet; ac=$ids; file=$latest" >&2
        return 1
      fi
      if ! ids=$(jq -r --arg head "$reviewed" '[.acceptance_criteria[] | select(.status == "unverified" or (.status == "human-verified" and (.head | ascii_downcase) != $head)) | .id] | join(",")' "$latest"); then
        echo "[CONTEXT] REVIEWED_AC=malformed; reason=ac_query_failed; file=$latest" >&2; return 1
      fi
      if [ -n "$ids" ]; then
        echo "[CONTEXT] REVIEWED_AC=unverified; ac=$ids; file=$latest" >&2
        return 1
      fi
      echo "[CONTEXT] REVIEWED_AC=satisfied; file=$latest" >&2
      ;;
    *)
      if ! ids=$(jq -r '[.acceptance_criteria[] | select(.status == "unmet") | .id] | join(",")' "$latest"); then
        echo "[CONTEXT] REVIEWED_AC=malformed; reason=ac_query_failed; file=$latest" >&2; return 1
      fi
      if [ -n "$ids" ]; then echo "[CONTEXT] REVIEWED_AC=unmet; ac=$ids; file=$latest" >&2; return 0; fi
      if ! ids=$(jq -r '[.acceptance_criteria[] | select(.status == "unverified") | .id] | join(",")' "$latest"); then
        echo "[CONTEXT] REVIEWED_AC=malformed; reason=ac_query_failed; file=$latest" >&2; return 1
      fi
      if [ -n "$ids" ]; then echo "[CONTEXT] REVIEWED_AC=unverified; ac=$ids; file=$latest" >&2
      fi
      ;;
  esac
}

latest=""
if [ -d "$results_dir" ]; then
  find_raw=$(find "$results_dir" -maxdepth 1 -type f -name "${pr_number}-*.json") || {
    echo "ERROR: Ready reviewed-head gate: review JSON を検索できません ($results_dir)。照合不能のため Ready 化を拒否します。" >&2
    echo "[CONTEXT] READY_REVIEWED_HEAD=find_failed; pr=$pr_number" >&2
    exit 1
  }
  latest=$(printf '%s\n' "$find_raw" | LC_ALL=C sort -r | head -n 1)
fi
if [ -z "$latest" ] || [ ! -f "$latest" ]; then
  echo "ERROR: Ready reviewed-head gate: PR #$pr_number の review JSON がありません（レビュー未実施、または archive 済み）。Ready 化を拒否します。" >&2
  echo "  探索先: $results_dir/${pr_number}-*.json" >&2
  echo "  次の行動: /rite:iterate $pr_number" >&2
  echo "[CONTEXT] READY_REVIEWED_HEAD=missing_json; pr=$pr_number" >&2
  exit 1
fi

if ! reviewed=$(jq -r '.commit_sha // empty' "$latest"); then
  echo "ERROR: Ready reviewed-head gate: $latest から commit_sha を読めません。照合不能のため Ready 化を拒否します。" >&2
  echo "[CONTEXT] READY_REVIEWED_HEAD=jq_failed; pr=$pr_number; file=$latest" >&2
  exit 1
fi
reviewed=$(printf '%s' "$reviewed" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
case "$reviewed" in
  ''|*[!0-9a-f]*)
    echo "ERROR: Ready reviewed-head gate: $latest の commit_sha が空または SHA ではありません (received: '$reviewed')。照合不能のため Ready 化を拒否します。" >&2
    echo "  次の行動: /rite:iterate $pr_number" >&2
    echo "[CONTEXT] READY_REVIEWED_HEAD=missing_sha; pr=$pr_number; file=$latest" >&2
    exit 1
    ;;
esac

if [ "$skip_head_check" -eq 1 ]; then
  echo "[CONTEXT] READY_REVIEWED_HEAD=override; reviewed=$reviewed; head=$head_sha" >&2
  _check_acceptance_criteria
  exit $?
fi

if _sha_matches "$reviewed" "$head_sha"; then
  echo "[CONTEXT] READY_REVIEWED_HEAD=match; reviewed=$reviewed; head=$head_sha; via=json" >&2
  _check_acceptance_criteria
  exit $?
fi

# Sweep exception: only after JSON mismatch. --results-dir without --state-root
# is the existing test injection and must not require state-path-resolve.sh
# (done-file absent ≡ existing mismatch wording).
sweep_file=""
if [ "$state_root_explicit" = 1 ]; then
  sweep_file="$state_root/.rite/state/nb-sweep-done-${pr_number}.txt"
elif [ "$results_dir_explicit" = 0 ] && [ -n "$plugin_root" ]; then
  if [ -x "$plugin_root/hooks/state-path-resolve.sh" ]; then
    resolved_root=$(bash "$plugin_root/hooks/state-path-resolve.sh") || resolved_root=""
    [ -n "$resolved_root" ] && sweep_file="$resolved_root/.rite/state/nb-sweep-done-${pr_number}.txt"
  fi
fi

if [ -n "$sweep_file" ] && [ -f "$sweep_file" ]; then
  if ! sweep_line2=$(sed -n '2p' "$sweep_file"); then
    echo "ERROR: Ready reviewed-head gate: $sweep_file を読めません。照合不能のため Ready 化を拒否します。" >&2
    echo "[CONTEXT] READY_REVIEWED_HEAD=done_file_unreadable; pr=$pr_number; file=$sweep_file" >&2
    exit 1
  fi
  sweep_nlines=$(wc -l < "$sweep_file" | tr -d '[:space:]')
  case "$sweep_nlines" in ''|*[!0-9]*) sweep_nlines=0 ;; esac
  if [ "$sweep_nlines" -ge 2 ]; then
    sweep=$(printf '%s' "$sweep_line2" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    case "$sweep" in
      ''|*[!0-9a-f]*)
        echo "ERROR: Ready reviewed-head gate: nb-sweep-done の 2 行目が空または SHA ではありません (received: '$sweep')。照合不能のため Ready 化を拒否します。" >&2
        echo "  次の行動: /rite:iterate $pr_number" >&2
        echo "[CONTEXT] READY_REVIEWED_HEAD=sweep_sha_invalid; pr=$pr_number; reviewed=$reviewed; head=$head_sha" >&2
        exit 1
        ;;
    esac
    if [ "${#sweep}" -lt 7 ]; then
      echo "ERROR: Ready reviewed-head gate: nb-sweep-done の 2 行目が SHA ではありません (received: '$sweep')。照合不能のため Ready 化を拒否します。" >&2
      echo "  次の行動: /rite:iterate $pr_number" >&2
      echo "[CONTEXT] READY_REVIEWED_HEAD=sweep_sha_invalid; pr=$pr_number; reviewed=$reviewed; head=$head_sha" >&2
      exit 1
    fi
    if _sha_matches "$sweep" "$head_sha"; then
      echo "[CONTEXT] READY_REVIEWED_HEAD=match; reviewed=$reviewed; head=$head_sha; via=sweep" >&2
      _check_acceptance_criteria
      exit $?
    fi
    echo "ERROR: Ready reviewed-head gate: 最終レビュー済み commit と PR head が不一致です" >&2
    echo "  reviewed_commit (review JSON の commit_sha): $reviewed" >&2
    echo "  sweep (nb-sweep-done 2 行目): $sweep" >&2
    echo "  PR head (headRefOid): $head_sha" >&2
    echo "  意味: PR head がレビュー済み commit ではないため、Ready 化を拒否します。" >&2
    echo "  次の行動: /rite:iterate $pr_number" >&2
    echo "  強行する場合: ユーザーが「未レビューのまま Ready 化を強行」と明示した再実行のみ（既定では拒否）。" >&2
    echo "[CONTEXT] READY_REVIEWED_HEAD=mismatch; reviewed=$reviewed; sweep=$sweep; head=$head_sha" >&2
    exit 1
  fi
fi

echo "ERROR: Ready reviewed-head gate: 最終レビュー済み commit と PR head が不一致です" >&2
echo "  reviewed_commit (review JSON の commit_sha): $reviewed" >&2
echo "  PR head (headRefOid): $head_sha" >&2
echo "  意味: PR head がレビュー済み commit ではないため、Ready 化を拒否します。" >&2
echo "  次の行動: /rite:iterate $pr_number" >&2
echo "  強行する場合: ユーザーが「未レビューのまま Ready 化を強行」と明示した再実行のみ（既定では拒否）。" >&2
echo "[CONTEXT] READY_REVIEWED_HEAD=mismatch; reviewed=$reviewed; head=$head_sha" >&2
exit 1
