#!/usr/bin/env bash
# Gate an external write (Issue creation / deferred token / follow-up) on the adoption exit.
#
# Every path that writes outside the PR calls this right before writing. It runs the
# adoption helper (review-adoption-check.sh) on the classifier's records for the path's
# candidates and turns each decision into one verdict:
#   file    the only verdict that may write externally (ADOPT pre_existing, DIAGNOSE
#           investigate). The record must also carry a non-empty `acceptance` (the filed
#           Issue's acceptance criterion); without it the decision is held.
#   record  RESOLVED / REJECT / LINK without pr_blocking: record the disposition only.
#   hold    anything else: pr_blocking decisions (RECONCILE, ADOPT pr/unknown, DIAGNOSE
#           pr/unknown, LINK pr/unknown) and DIAGNOSE without investigation.
# A missing record file, an unreadable context, or a helper ERROR holds every candidate.
# When anything is held, nothing may be written: the full held candidates, the source,
# the reviewed commit and the resume position are saved to the hold file and the gate
# exits 3. A decided run removes a stale hold file of the same path.
#
# Usage:
#   review-adoption-gate.sh --pr N --kind sweep|triage|followup --state-root DIR \
#     --candidates FILE --review-result FILE --base REF [--adoption FILE] [--issue N] \
#     [--owner-repo OWNER/REPO] [--issue-body FILE] [--pr-body FILE] [--ac-ids CSV] \
#     [--ledger FILE] [--repo-root DIR]
#
#   --candidates    {"candidates": [{"id": ..., <full candidate text>}, ...]}
#   --adoption      the classifier's records ({"adoption": {"head", "records"}}).
#                   Default: STATE_ROOT/.rite/state/adoption-PR-KIND.json
#   --issue         related Issue; its body gives the AC ids and issue citations.
#                   --issue-body / --pr-body / --ac-ids / --ledger replace the gh reads.
#
# stdout: decided {"held": false, "head", "verdicts": [{"ids", "exit", "origin", "action",
#           "tracker", "verdict", "record"}]}; held {"held": true, "reason", "hold_file"}
# stderr: [CONTEXT] ADOPTION_GATE=decided; kind=K; file=A; record=B; pr=N
#         [CONTEXT] ADOPTION_GATE=held; kind=K; reason=R; held=H; hold_file=PATH; pr=N
# Hold file: STATE_ROOT/.rite/state/adoption-hold-PR-KIND.json
#   {kind, pr, head, review_result, reason, detail, held_ids, candidates, resume}
#
# Exit: 0 decided, 3 held, 1 the hold could not be saved, 2 usage.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin_root="$(cd "$script_dir/../.." && pwd)"
# shellcheck source=../control-char-neutralize.sh
source "$script_dir/../control-char-neutralize.sh"

pr="" kind="" state_root="" candidates="" review_result="" base="" adoption="" issue=""
owner_repo="" issue_body="" pr_body="" ac_ids="" ac_ids_set=0 ledger="" repo_root=""
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || { echo "ERROR: $1 needs a value" >&2; exit 2; }
  case "$1" in
    --pr) pr=$2 ;;
    --kind) kind=$2 ;;
    --state-root) state_root=$2 ;;
    --candidates) candidates=$2 ;;
    --review-result) review_result=$2 ;;
    --base) base=$2 ;;
    --adoption) adoption=$2 ;;
    --issue) issue=$2 ;;
    --owner-repo) owner_repo=$2 ;;
    --issue-body) issue_body=$2 ;;
    --pr-body) pr_body=$2 ;;
    --ac-ids) ac_ids=$2; ac_ids_set=1 ;;
    --ledger) ledger=$2 ;;
    --repo-root) repo_root=$2 ;;
    *) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
  esac
  shift 2
done
case "$pr" in ''|*[!0-9]*|0) echo "ERROR: --pr must be a positive integer" >&2; exit 2 ;; esac
case "$kind" in sweep|triage|followup) ;; *) echo "ERROR: --kind must be sweep, triage or followup" >&2; exit 2 ;; esac
case "$issue" in ''|*[!0-9]*) [ -z "$issue" ] || { echo "ERROR: --issue must be a positive integer" >&2; exit 2; } ;; esac
for v in state_root candidates review_result base; do
  [ -n "${!v}" ] || { echo "ERROR: --${v//_/-} is required" >&2; exit 2; }
done
[ -n "$adoption" ] || adoption="$state_root/.rite/state/adoption-$pr-$kind.json"
hold_file="$state_root/.rite/state/adoption-hold-$pr-$kind.json"

work=$(mktemp -d "${TMPDIR:-/tmp}/rite-adoption-gate-XXXXXX") || { echo "ERROR: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$work"' EXIT

case "$kind" in
  sweep) resume="判定記録 $adoption を直してから /rite:iterate $pr を再実行する（ステップ 5.S の sweep から続く）" ;;
  triage) resume="判定記録 $adoption を直してから /rite:iterate $pr を再実行する（レビューのスコープ外処分から続く）" ;;
  followup) resume="判定記録 $adoption を直してから /rite:cleanup $pr を再実行する（ステップ 6.0 の follow-up 判定から続く）" ;;
esac

# Save every held candidate with its full text, then stop. $3 lists the held ids
# (JSON array); without it every candidate is held.
hold() {
  local reason=$1 detail=$2 ids=${3:-null} head
  head=$(jq -r '.commit_sha // ""' "$review_result" 2>/dev/null) || head=""
  mkdir -p "$state_root/.rite/state" || { echo "ERROR: cannot create $state_root/.rite/state" >&2; exit 1; }
  if ! jq -n --arg kind "$kind" --argjson pr "$pr" --arg head "$head" --arg rr "$review_result" \
      --arg reason "$reason" --arg detail "$detail" --arg resume "$resume" --argjson ids "$ids" \
      --slurpfile c "$candidates" '
      ($c[0].candidates // []) as $all
      | (if $ids == null then [$all[].id] else $ids end) as $held
      | {kind: $kind, pr: $pr, head: $head, review_result: $rr, reason: $reason, detail: $detail,
         held_ids: $held, candidates: [$all[] | select(.id as $i | $held | index($i))], resume: $resume}
    ' > "$hold_file.tmp" || ! mv "$hold_file.tmp" "$hold_file"; then
    rm -f "$hold_file.tmp"
    echo "ERROR: the hold could not be saved to $hold_file; nothing may be written" >&2
    echo "[CONTEXT] ADOPTION_GATE=error; kind=$kind; reason=hold_write_failed; pr=$pr" >&2
    exit 1
  fi
  local n
  n=$(jq '.held_ids | length' "$hold_file")
  echo "WARNING: ${n} 件の候補に採否の出口が出ていないため外部へ書きません（${reason}）。${resume}" >&2
  [ -n "$detail" ] && printf '  %s\n' "$detail" >&2
  echo "[CONTEXT] ADOPTION_GATE=held; kind=$kind; reason=$reason; held=$n; hold_file=$hold_file; pr=$pr" >&2
  jq -n --arg reason "$reason" --arg hf "$hold_file" '{held: true, reason: $reason, hold_file: $hf}'
  exit 3
}

jq -e '(.candidates | type) == "array" and all(.candidates[]; (.id | type) == "string" and .id != "")' \
  "$candidates" >/dev/null 2>&1 || { echo "ERROR: --candidates is not {\"candidates\": [{\"id\": ...}]}: $candidates" >&2; exit 2; }
jq -e '(.commit_sha | type) == "string"' "$review_result" >/dev/null 2>&1 \
  || { echo "ERROR: --review-result has no commit_sha: $review_result" >&2; exit 2; }

[ -f "$adoption" ] || hold no_records "判定記録がありません: $adoption"

# Contexts the helper cites. Each gh read is replaced by its file option in tests.
if [ -z "$owner_repo" ] && { [ -z "$pr_body" ] || { [ -n "$issue" ] && [ -z "$issue_body" ]; } || [ -z "$ledger" ]; }; then
  owner_repo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null) || owner_repo=""
  [ -n "$owner_repo" ] || hold context_unavailable "owner/repo を解決できません"
fi
if [ -z "$pr_body" ]; then
  pr_body="$work/pr.md"
  gh pr view "$pr" -R "$owner_repo" --json body --jq '.body' > "$pr_body" 2>"$work/err" \
    || hold context_unavailable "PR 本文を取得できません: $(head -1 "$work/err")"
fi
if [ -n "$issue" ] && [ -z "$issue_body" ]; then
  issue_body="$work/issue.md"
  gh issue view "$issue" -R "$owner_repo" --json body --jq '.body' > "$issue_body" 2>"$work/err" \
    || hold context_unavailable "Issue 本文を取得できません: $(head -1 "$work/err")"
fi
if [ "$ac_ids_set" -eq 0 ] && [ -n "$issue_body" ]; then
  ac_ids=$(bash "$plugin_root/scripts/acceptance-criteria-check.sh" extract --body-file "$issue_body" 2>"$work/err") \
    || hold context_unavailable "受入条件を読めません: $(grep -m1 ERROR "$work/err")"
fi
if [ -z "$ledger" ]; then
  ledger="$work/ledger.md"
  bash "$plugin_root/hooks/review-nonblocking-record.sh" --print-record-body --pr "$pr" \
    --owner-repo "$owner_repo" > "$work/record.md" 2>"$work/err"
  record_rc=$?
  if [ "$record_rc" -ne 0 ] && ! grep -q 'reason=related_issue_unresolved' "$work/err"; then
    hold context_unavailable "却下台帳の記録コメントを取得できません"
  fi
  : > "$ledger"
  if [ -s "$work/record.md" ]; then
    bash "$plugin_root/hooks/scripts/nb-sweep-ledger.sh" extract --body-file "$work/record.md" > "$ledger" 2>/dev/null \
      || hold context_unavailable "却下台帳を読めません"
  fi
fi

args=(--classification "$adoption" --candidates "$candidates" --review-result "$review_result"
      --base "$base" --ac-ids "$ac_ids" --ledger "$ledger")
[ -n "$issue_body" ] && args+=(--issue-body "$issue_body")
[ -n "$pr_body" ] && args+=(--pr-body "$pr_body")
[ -n "$repo_root" ] && args+=(--repo-root "$repo_root")
decisions=$(bash "$script_dir/review-adoption-check.sh" "${args[@]}" 2>"$work/err")
rc=$?
neutralize_ctrl --keep-newline < "$work/err" >&2
case "$rc" in
  0) ;;
  1) hold adoption_error "$(sed -n 's/^\[CONTEXT\] REVIEW_ADOPTION=error; //p' "$work/err" | head -1)" ;;
  *) hold adoption_error "採否判定 helper が rc=$rc で終了しました" ;;
esac

# Decisions come in record order, so decision i belongs to record i.
if ! verdicts=$(jq -c --slurpfile a "$adoption" --argjson d "$decisions" '
    ($a[0].adoption.records) as $records
    | [$d.decisions | to_entries[] | .value + {record: $records[.key]}
       | . + {verdict: (if .file then (if ((.record.acceptance // "") | type == "string" and test("\\S")) then "file" else "hold" end)
                        elif .pr_blocking or .action == "hold" then "hold" else "record" end)}]
  ' <<< '{}'); then
  hold adoption_error "判定結果を読めません"
fi
held_ids=$(jq -c '[.[] | select(.verdict == "hold") | .ids[]]' <<< "$verdicts")
if [ "$held_ids" != "[]" ]; then
  missing=$(jq -r '[.[] | select(.verdict == "hold" and .file) | .ids | join(",")] | join(" ")' <<< "$verdicts")
  detail="保留した出口: $(jq -r '[.[] | select(.verdict == "hold") | "\(.ids | join(",")) \(.exit)/\(.action)"] | join("; ")' <<< "$verdicts")"
  [ -n "$missing" ] && detail="${detail}（受入条件 acceptance が無い起票: ${missing}）"
  hold undecided "$detail" "$held_ids"
fi

rm -f "$hold_file"
n_file=$(jq '[.[] | select(.verdict == "file")] | length' <<< "$verdicts")
n_record=$(jq '[.[] | select(.verdict == "record")] | length' <<< "$verdicts")
echo "[CONTEXT] ADOPTION_GATE=decided; kind=$kind; file=$n_file; record=$n_record; pr=$pr" >&2
jq -c --arg head "$(jq -r '.head' <<< "$decisions")" '{held: false, head: $head, verdicts: .}' <<< "$verdicts"
