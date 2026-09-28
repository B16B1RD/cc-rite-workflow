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
# When anything is held, nothing may be written: every candidate of the run with its full
# text (held_ids names the held ones), the source, the reviewed commit and how to resume
# are saved to the hold file and the gate exits 3. A decided run removes a stale hold file
# of the same path. The next run must still carry every candidate the previous hold saved
# (compared by full text without id, since triage renumbers ids); otherwise the dropped
# ones are kept in the hold. Triage compares on any commit, since its candidates live
# nowhere else; sweep and followup compare only on the same commit, since they rebuild
# their candidates from the review results. With no candidate and nothing dropped, the run
# decides with no verdict (and so retires a sweep or followup hold of another commit).
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
#         [CONTEXT] ADOPTION_GATE=error; kind=K; reason=hold_write_failed|hold_unreadable; pr=N
# Hold file: STATE_ROOT/.rite/state/adoption-hold-PR-KIND.json
#   {kind, pr, head, review_result, reason, detail, held_ids, candidates, resume}
#   resume names how to get out of each held reason (also printed in the WARNING).
#
# Exit: 0 decided, 3 held, 1 the hold could not be saved or read, 2 usage.
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

case "$kind" in followup) cmd="/rite:cleanup $pr" ;; *) cmd="/rite:iterate $pr" ;; esac
dropped='[]' verdicts='[]'

# How to get out of a hold: $1 reason, $2 the verdicts (an undecided hold reads the held ones).
resume_for() {
  local reason=$1 verdicts=$2 records="判定記録 $adoption を補う・直してから $cmd を再実行する" ways=() way joined=""
  case "$reason" in
    context_unavailable)
      echo "detail に出ている取得失敗の原因（gh 認証・ネットワーク・本文の読み取りなど）を解消してから $cmd を再実行する（判定記録は直さない）"
      return ;;
    held_candidates_dropped)
      if [ "$kind" = triage ]; then
        echo "前回の hold ファイルの candidates にある候補が今回の候補に含まれていない。欠けた候補を全文のまま候補へ戻してから $cmd を再実行する（スコープ外処分の手順 1 が hold ファイルの候補を合流させる）"
      else
        echo "前回の hold ファイルの candidates にある候補が今回の候補に含まれていない。同じ入力（レビュー結果 JSON）で候補を作り直してから $cmd を再実行する"
      fi
      return ;;
    undecided) ;;
    *) echo "$records"; return ;;
  esac
  jq -e 'any(.[]; .verdict == "hold" and (.pr_blocking | not))' <<< "$verdicts" >/dev/null && ways+=("$records")
  if jq -e 'any(.[]; .verdict == "hold" and .pr_blocking)' <<< "$verdicts" >/dev/null; then
    if [ "$kind" = followup ]; then
      ways+=("PR 起因の保留はマージ済み PR では同じ PR で直せず、この出口の扱いは仕様で未定義のため、保留のまま止め、人間に報告する（再実行しても同じ保留になる。判定記録を pre_existing や REJECT に書き換えて解除しない）")
    else
      ways+=("PR 起因の保留は同じ PR で直す。コードを直して push し $cmd で再レビューする（HEAD が変わると新しいレビューで判定し直す）")
      jq -e 'any(.[]; .verdict == "hold" and .exit == "RECONCILE")' <<< "$verdicts" >/dev/null \
        && ways+=("RECONCILE は矛盾する処分を裁定してから $cmd を再実行する")
    fi
  fi
  for way in "${ways[@]}"; do joined+="${joined:+。}$way"; done
  echo "$joined"
}

# Save every candidate of the run with its full text, then stop. $3 lists the held ids
# (JSON array); without it every candidate is held. Candidates dropped from the previous
# hold are appended and held, renamed when their id is taken by a current candidate.
hold() {
  local reason=$1 detail=$2 ids=${3:-null} resume
  resume=$(resume_for "$reason" "$verdicts")
  if ! mkdir -p "$state_root/.rite/state"; then
    echo "ERROR: cannot create $state_root/.rite/state; nothing may be written" >&2
    echo "[CONTEXT] ADOPTION_GATE=error; kind=$kind; reason=hold_write_failed; pr=$pr" >&2
    exit 1
  fi
  if ! jq -n --arg kind "$kind" --argjson pr "$pr" --arg head "$head" --arg rr "$review_result" \
      --arg reason "$reason" --arg detail "$detail" --arg resume "$resume" --argjson ids "$ids" \
      --argjson dropped "$dropped" --slurpfile c "$candidates" '
      ($c[0].candidates // []) as $all
      | [$all[].id] as $taken
      | [$dropped[] | .id |= until(. as $i | $taken | index($i) | not; "held-" + .)] as $kept
      | (if $ids == null then [$all[].id] else $ids end) as $held
      | {kind: $kind, pr: $pr, head: $head, review_result: $rr, reason: $reason, detail: $detail,
         held_ids: ($held + [$kept[].id]),
         candidates: ($all + $kept), resume: $resume}
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
head=$(jq -r '.commit_sha' "$review_result")

# The next run keeps the previous hold's candidates: triage on any commit, sweep and
# followup on the same commit. Triage renumbers ids, so each saved candidate is looked up
# by its full text without id.
if [ -e "$hold_file" ]; then
  dropped=$(jq -nc --arg head "$head" --arg kind "$kind" --slurpfile h "$hold_file" --slurpfile c "$candidates" '
      if ($h | length) != 1 or ($h[0].head | type) != "string" or ($h[0].candidates | type) != "array"
         or any($h[0].candidates[]; (.id | type) != "string") then error("malformed hold file")
      elif $h[0].head != $head and $kind != "triage" then []
      else [$c[0].candidates[] | del(.id)] as $now
        | [$h[0].candidates[] | select(del(.id) as $x | any($now[]; . == $x) | not)] end
    ' 2>"$work/err") || {
    neutralize_ctrl --keep-newline < "$work/err" >&2
    echo "ERROR: the previous hold $hold_file cannot be read; it is kept and nothing may be written" >&2
    echo "[CONTEXT] ADOPTION_GATE=error; kind=$kind; reason=hold_unreadable; pr=$pr" >&2
    exit 1
  }
  [ "$dropped" = '[]' ] || hold held_candidates_dropped \
    "前回の hold ファイルの候補のうち $(jq 'length' <<< "$dropped") 件が今回の候補にありません: $(jq -r '[.[].id] | join(", ")' <<< "$dropped")"
fi

# With no candidate left and none dropped from the previous hold there is nothing to judge.
if [ "$(jq '.candidates | length' "$candidates")" -eq 0 ]; then
  rm -f "$hold_file"
  echo "[CONTEXT] ADOPTION_GATE=decided; kind=$kind; file=0; record=0; pr=$pr" >&2
  jq -cn --arg head "$head" '{held: false, head: $head, verdicts: []}'
  exit 0
fi

[ -f "$adoption" ] || hold no_records "判定記録がありません: $adoption"

# Contexts the helper cites. Each gh read is replaced by its file option in tests.
# callee_diag forwards the callee's stderr and prints its first diagnostic line.
callee_diag() {
  neutralize_ctrl --keep-newline < "$work/err" >&2
  { grep -m1 -E 'ERROR|reason=' "$work/err" || head -1 "$work/err"; } | neutralize_ctrl --keep-newline
}
if [ -z "$owner_repo" ] && { [ -z "$pr_body" ] || { [ -n "$issue" ] && [ -z "$issue_body" ]; } || [ -z "$ledger" ]; }; then
  owner_repo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>"$work/err") || owner_repo=""
  [ -n "$owner_repo" ] || hold context_unavailable "owner/repo を解決できません: $(callee_diag)"
fi
if [ -z "$pr_body" ]; then
  pr_body="$work/pr.md"
  gh pr view "$pr" -R "$owner_repo" --json body --jq '.body' > "$pr_body" 2>"$work/err" \
    || hold context_unavailable "PR 本文を取得できません: $(callee_diag)"
fi
if [ -n "$issue" ] && [ -z "$issue_body" ]; then
  issue_body="$work/issue.md"
  gh issue view "$issue" -R "$owner_repo" --json body --jq '.body' > "$issue_body" 2>"$work/err" \
    || hold context_unavailable "Issue 本文を取得できません: $(callee_diag)"
fi
if [ "$ac_ids_set" -eq 0 ] && [ -n "$issue_body" ]; then
  ac_ids=$(bash "$plugin_root/scripts/acceptance-criteria-check.sh" extract --body-file "$issue_body" 2>"$work/err") \
    || hold context_unavailable "受入条件を読めません: $(callee_diag)"
fi
if [ -z "$ledger" ]; then
  ledger="$work/ledger.md"
  bash "$plugin_root/hooks/review-nonblocking-record.sh" --print-record-body --pr "$pr" \
    --owner-repo "$owner_repo" > "$work/record.md" 2>"$work/err"
  record_rc=$?
  record_diag=$(callee_diag)
  if [ "$record_rc" -ne 0 ] && ! grep -q 'reason=related_issue_unresolved' "$work/err"; then
    hold context_unavailable "却下台帳の記録コメントを取得できません: $record_diag"
  fi
  : > "$ledger"
  if [ -s "$work/record.md" ]; then
    bash "$plugin_root/hooks/scripts/nb-sweep-ledger.sh" extract --body-file "$work/record.md" > "$ledger" 2>"$work/err" \
      || hold context_unavailable "却下台帳を読めません: $(callee_diag)"
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
