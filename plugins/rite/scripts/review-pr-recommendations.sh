#!/bin/bash
# rite workflow - review candidates routed to an in-PR fix
#
# Responsibility: register the review candidates whose adoption exit is ADOPT
# with origin=pr (action fix_in_pr: the PR itself caused the root cause, so the
# same PR fixes it) as in-PR recommendations, and tell iterate whether the
# latest saved review still has them to fix. A candidate that is not a blocking
# finding has no fix entry of its own, and a hand commit after mergeable leaves
# a HEAD the next review cannot start from (it has no fix verification record).
#
# Usage:
#   bash review-pr-recommendations.sh capacity --input <review JSON>
#   bash review-pr-recommendations.sh record --pr <n> --review-result <review JSON> --verdicts <gate stdout> --candidates <file> [--state-root <dir>]
#   bash review-pr-recommendations.sh list --pr <n> --review-result <review JSON> [--state-root <dir>]
#   bash review-pr-recommendations.sh check --pr <n> [--state-root <dir>]
#   bash review-pr-recommendations.sh mark --pr <n> [--state-root <dir>]
#
# capacity (the adoption gate, kind=triage): whether a fix registered on this
#   review could still be re-reviewed. A cycle at or past
#   safety.max_review_cycles could not: the next review would trip max-cycles and
#   leave the fix commit unreviewed. There is no other limit: an adopted
#   PR-origin root cause is never deferred by a count.
#     [CONTEXT] PR_RECOMMENDATIONS_CAPACITY=open|cycle_cap
#
# record (pr-review step 7.2, after the adoption gate decided): writes every
#   verdict "fix" of the gate output, in verdict order, to
#   .rite/state/pr-recommendations-<pr>.json as
#   {commit_sha, review_result: <basename>, recommendations: [{id: "R-NN",
#   candidates: [<candidate ids>], reviewer, file_line, description, contract,
#   evidence}]}. reviewer / file_line come from the first candidate of the
#   record, description joins the candidates' content. The file is rewritten on
#   every call (an empty recommendations[] when there is no "fix" verdict), so a
#   rerun on the same commit gives the same bytes.
#   --candidates is the gate's {"candidates": [{id, reviewer, file_line, content, ...}]}.
#     [CONTEXT] PR_RECOMMENDATIONS=registered; count=N; ids=R-01,...
#     [CONTEXT] PR_RECOMMENDATIONS=none
#
# list (fix, before the plan): prints the registrations recorded on the review's
#   commit as one JSON array line (empty array when none), for the fix plan to give
#   each R-NN a disposition. The scope gate reads the same file with the same commit rule.
#     [CONTEXT] PR_RECOMMENDATIONS_LIST=count=N; ids=R-01,...
#
# check (iterate, after the 5.S sweep): reads the latest saved result for the PR
# (LC_ALL=C sort, last). Registrations are pending only when they were recorded
# on that result's commit and the commit has not been handed to fix (see mark).
#     [CONTEXT] PR_RECOMMENDATIONS_CHECK=pending; count=N; json=<path>
#     [CONTEXT] PR_RECOMMENDATIONS_CHECK=none; json=<path>
#
# mark (iterate, right before invoking fix): records the latest saved result's
# basename and commit_sha in .rite/state/pr-recommendations-done-<pr>.txt so
# that re-entry does not hand the same reviewed commit to fix twice.
#     [CONTEXT] PR_RECOMMENDATIONS_MARK=done; json=<basename>
#
# --state-root defaults to state-path-resolve.sh.
#
# Errors (stderr, exit 1): [CONTEXT] PR_RECOMMENDATIONS_FAILED=1; reason=<reason>
#   jq_missing / input_unreadable / json_invalid / verdicts_invalid /
#   config_unreadable / results_dir_missing / json_missing / write_failure
# Exit 2: usage.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$SCRIPT_DIR/../hooks"

fail() {
  echo "ERROR: $2" >&2
  echo "[CONTEXT] PR_RECOMMENDATIONS_FAILED=1; reason=$1" >&2
  exit 1
}

usage() {
  sed -n '11,16p' "${BASH_SOURCE[0]}" >&2
  exit 2
}

command -v jq >/dev/null 2>&1 || fail jq_missing "jq is required"

mode=${1:-}
[ -n "$mode" ] || usage
shift
input="" review_result="" verdicts="" candidates="" pr="" state_root=""
while [ $# -gt 0 ]; do
  case "$1" in
    --input) input=${2:-}; shift 2 ;;
    --review-result) review_result=${2:-}; shift 2 ;;
    --verdicts) verdicts=${2:-}; shift 2 ;;
    --candidates) candidates=${2:-}; shift 2 ;;
    --pr) pr=${2:-}; shift 2 ;;
    --state-root) state_root=${2:-}; shift 2 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage ;;
  esac
done

resolve_state_root() {
  if [ -z "$state_root" ]; then
    state_root=$(bash "$HOOKS_DIR/state-path-resolve.sh") || fail results_dir_missing "state root unresolved"
  fi
}

case "$mode" in
  capacity)
    [ -n "$input" ] || usage
    [ -f "$input" ] && [ -r "$input" ] || fail input_unreadable "review JSON unreadable: $input"
    cycle=$(jq -r '.review_context.cycle_count // empty' "$input" 2>/dev/null)
    case "$cycle" in ''|*[!0-9]*) fail json_invalid "review_context.cycle_count missing: $input" ;; esac
    cfg=$(bash "$HOOKS_DIR/scripts/lib/rite-config-path.sh" --or-devnull) || fail config_unreadable "rite-config.yml unreadable"
    # 節は空白と # 以外で始まる次の行で終える（数字や _ で始まるキーでも終え、列 0 のコメント行では終えない）
    max_cycles=$(awk '/^safety:/{s=1;next} s&&/^[^[:space:]#]/{exit} s&&/^[[:space:]]+max_review_cycles:/{print;exit}' "$cfg" \
      | sed 's/[[:space:]]#.*//; s/.*max_review_cycles:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
    case "$max_cycles" in ''|0|*[!0-9]*) max_cycles=15 ;; esac
    if [ "$cycle" -ge "$max_cycles" ]; then
      echo "[CONTEXT] PR_RECOMMENDATIONS_CAPACITY=cycle_cap"
    else
      echo "[CONTEXT] PR_RECOMMENDATIONS_CAPACITY=open"
    fi
    ;;
  record)
    case "$pr" in ''|*[!0-9]*|0) usage ;; esac
    [ -n "$review_result" ] && [ -n "$verdicts" ] && [ -n "$candidates" ] || usage
    sha=$(jq -r '.commit_sha // empty' "$review_result" 2>/dev/null)
    [ -n "$sha" ] || fail json_invalid "commit_sha missing: $review_result"
    jq -e '(.verdicts | type) == "array"' "$verdicts" >/dev/null 2>&1 || fail verdicts_invalid "gate verdicts missing: $verdicts"
    jq -e '(.candidates | type) == "array"' "$candidates" >/dev/null 2>&1 || fail verdicts_invalid "candidates missing: $candidates"
    resolve_state_root
    out="$state_root/.rite/state/pr-recommendations-$pr.json"
    mkdir -p "$state_root/.rite/state" || fail write_failure "cannot create $state_root/.rite/state"
    tmp=$(mktemp "$out.XXXXXX") || fail write_failure "mktemp failed next to $out"
    if ! jq -n --arg sha "$sha" --arg rr "$(basename "$review_result")" \
        --slurpfile v "$verdicts" --slurpfile c "$candidates" '
        ($c[0].candidates) as $cands
        | {commit_sha: $sha, review_result: $rr,
           recommendations: [[$v[0].verdicts[] | select(.verdict == "fix")] | to_entries[]
             | .value as $d | [$d.ids[] as $i | $cands[] | select(.id == $i)] as $mine
             | {id: ("R-" + ((.key + 1) | tostring | if length < 2 then "0" + . else . end)),
                candidates: $d.ids, reviewer: ($mine[0].reviewer // ""), file_line: ($mine[0].file_line // ""),
                description: ([$mine[] | .content // .description // ""] | join("\n")),
                contract: $d.record.contract, evidence: ($d.record.evidence // "")}]}' > "$tmp" \
        || ! mv "$tmp" "$out"; then
      rm -f "$tmp"
      fail write_failure "could not write $out"
    fi
    count=$(jq '.recommendations | length' "$out")
    if [ "$count" -eq 0 ]; then
      echo "[CONTEXT] PR_RECOMMENDATIONS=none"
    else
      echo "[CONTEXT] PR_RECOMMENDATIONS=registered; count=$count; ids=$(jq -r '[.recommendations[].id] | join(",")' "$out")"
    fi
    ;;
  list)
    case "$pr" in ''|*[!0-9]*|0) usage ;; esac
    [ -n "$review_result" ] || usage
    sha=$(jq -r '.commit_sha // empty' "$review_result" 2>/dev/null)
    [ -n "$sha" ] || fail json_invalid "commit_sha missing: $review_result"
    resolve_state_root
    registered="$state_root/.rite/state/pr-recommendations-$pr.json"
    recs='[]'
    if [ -f "$registered" ]; then
      recs=$(jq -c --arg sha "$sha" 'if (.recommendations | type) != "array" then error("recommendations")
        elif .commit_sha == $sha then .recommendations else [] end' "$registered" 2>/dev/null) \
        || fail json_invalid "registrations unreadable: $registered"
    fi
    echo "[CONTEXT] PR_RECOMMENDATIONS_LIST=count=$(jq 'length' <<< "$recs"); ids=$(jq -r '[.[].id] | join(",")' <<< "$recs")"
    printf '%s\n' "$recs"
    ;;
  check|mark)
    case "$pr" in ''|*[!0-9]*|0) usage ;; esac
    resolve_state_root
    results_dir="$state_root/.rite/review-results"
    [ -d "$results_dir" ] || fail results_dir_missing "review results dir missing: $results_dir"
    json=$(find "$results_dir" -maxdepth 1 -type f -name "${pr}-*.json" | LC_ALL=C sort | tail -1)
    [ -n "$json" ] || fail json_missing "no review JSON for PR #$pr in $results_dir"
    sha=$(jq -r '.commit_sha // empty' "$json" 2>/dev/null)
    [ -n "$sha" ] || fail json_invalid "commit_sha missing: $json"
    done_file="$state_root/.rite/state/pr-recommendations-done-$pr.txt"
    if [ "$mode" = mark ]; then
      mkdir -p "$state_root/.rite/state" && printf '%s %s\n' "$(basename "$json")" "$sha" > "$done_file" \
        || fail write_failure "could not write $done_file"
      echo "[CONTEXT] PR_RECOMMENDATIONS_MARK=done; json=$(basename "$json")"
      exit 0
    fi
    registered="$state_root/.rite/state/pr-recommendations-$pr.json"
    count=0
    if [ -f "$registered" ]; then
      count=$(jq --arg sha "$sha" 'if .commit_sha == $sha then (.recommendations | length) else 0 end' "$registered" 2>/dev/null) \
        || fail json_invalid "registrations unreadable: $registered"
    fi
    # Compared by reviewed commit, not file name: fix may save a copy of the
    # same review under a new name, and that copy is not a new review.
    handed=""
    [ -f "$done_file" ] && handed=$(awk 'NR==1 { print $2 }' "$done_file")
    if [ "$count" -gt 0 ] && [ "$handed" != "$sha" ]; then
      echo "[CONTEXT] PR_RECOMMENDATIONS_CHECK=pending; count=$count; json=$json"
    else
      echo "[CONTEXT] PR_RECOMMENDATIONS_CHECK=none; json=$json"
    fi
    ;;
  *) usage ;;
esac
