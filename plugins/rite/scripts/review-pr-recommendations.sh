#!/bin/bash
# rite workflow - reviewer recommendations routed to an in-PR fix
#
# Responsibility: pick the reviewer recommendations that point at a defect the
# PR itself added, record them in the review result as pr_recommendations[], and
# tell iterate whether the latest saved review still has them to fix. A
# recommendation is not a finding, so without this record a mergeable review
# leaves no fix entry for it, and a hand commit after mergeable leaves a HEAD the
# next review cannot start from (it has no fix verification record).
#
# Usage:
#   bash review-pr-recommendations.sh register --input <review JSON> --items <items JSON> --base-ref <ref> [--state-root <dir>]
#   bash review-pr-recommendations.sh check --pr <n> [--state-root <dir>]
#   bash review-pr-recommendations.sh mark --pr <n> [--state-root <dir>]
#
# register (pr-review, after every gate, before the result is saved):
#   Selects items with classification "actionable" whose file_line
#   ("path:line" or "path:start-end") overlaps a + hunk of `git diff -U0
#   <base-ref>...HEAD`, and writes them to the input as
#   pr_recommendations[] = {id: "R-NN", reviewer, file, line, description}.
#   Deleted and unchanged lines never qualify. Registers only when
#   overall_assessment is mergeable, and at most once per review run: a saved
#   result with the same review_context.run_id, a different review_context and a
#   non-empty pr_recommendations[] means the run already had its in-PR fix, so
#   later recommendations go to the Decision Log as before. Re-running the same
#   cycle gives the same bytes. Nothing else in the input changes.
#   The input must be the unsaved working copy. The saved result is what the
#   stagnation receipt and review-finish compare against, so a path under
#   .rite/review-results/ is refused.
#   --items is {"recommendation_items": [{reviewer_type, content, classification, file_line}]}.
#   Markers (stdout):
#     [CONTEXT] PR_RECOMMENDATIONS=registered; count=N; ids=R-01,...; positions=I,...
#     [CONTEXT] PR_RECOMMENDATIONS=none; reason=not_mergeable|cap_reached|no_candidates
#   positions are 0-based indexes into recommendation_items, in id order; step 7
#   of pr-review leaves exactly those out of its triage candidates.
#
# check (iterate, after the 5.S sweep): reads the latest saved result for the PR
# (LC_ALL=C sort, last). A result for a commit already handed to fix (see
# mark) is none.
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
#   jq_missing / input_unreadable / saved_result_path / json_invalid /
#   items_invalid / results_dir_missing / json_missing / diff_failed /
#   write_failure
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
  sed -n '11,14p' "${BASH_SOURCE[0]}" >&2
  exit 2
}

command -v jq >/dev/null 2>&1 || fail jq_missing "jq is required"

mode=${1:-}
[ -n "$mode" ] || usage
shift
input="" items="" base_ref="" pr="" state_root=""
while [ $# -gt 0 ]; do
  case "$1" in
    --input) input=${2:-}; shift 2 ;;
    --items) items=${2:-}; shift 2 ;;
    --base-ref) base_ref=${2:-}; shift 2 ;;
    --pr) pr=${2:-}; shift 2 ;;
    --state-root) state_root=${2:-}; shift 2 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage ;;
  esac
done

results_dir=""
resolve_results_dir() {
  if [ -z "$state_root" ]; then
    state_root=$(bash "$HOOKS_DIR/state-path-resolve.sh") || fail results_dir_missing "state root unresolved"
  fi
  results_dir="$state_root/.rite/review-results"
  [ -d "$results_dir" ] || fail results_dir_missing "review results dir missing: $results_dir"
}

latest_json() {
  json=$(find "$results_dir" -maxdepth 1 -type f -name "${pr}-*.json" | LC_ALL=C sort | tail -1)
  [ -n "$json" ] || fail json_missing "no review JSON for PR #$pr in $results_dir"
  jq empty "$json" >/dev/null 2>&1 || fail json_invalid "review JSON invalid: $json"
}

case "$mode" in
  register)
    [ -n "$input" ] && [ -n "$items" ] && [ -n "$base_ref" ] || usage
    [ -f "$input" ] && [ -r "$input" ] || fail input_unreadable "review JSON unreadable: $input"
    case "$(cd "$(dirname "$input")" && pwd)/" in
      */.rite/review-results/*) fail saved_result_path "register writes only the unsaved working copy, not $input" ;;
    esac
    jq -e 'type == "object" and (.review_context | type == "object") and (.pr_number | type == "number")' "$input" >/dev/null 2>&1 \
      || fail json_invalid "review JSON invalid or without review_context / pr_number: $input"
    jq -e '.recommendation_items | type == "array"' "$items" >/dev/null 2>&1 \
      || fail items_invalid "recommendation_items array missing: $items"

    if [ "$(jq -r '.overall_assessment' "$input")" != "mergeable" ]; then
      echo "[CONTEXT] PR_RECOMMENDATIONS=none; reason=not_mergeable"
      exit 0
    fi

    resolve_results_dir
    context=$(jq -c '.review_context' "$input")
    run_id=$(jq -r '.review_context.run_id // empty' "$input")
    [ -n "$run_id" ] || fail json_invalid "review_context.run_id missing: $input"
    while IFS= read -r saved; do
      [ -n "$saved" ] || continue
      if jq -e --arg run "$run_id" --argjson ctx "$context" \
          '.review_context.run_id == $run and .review_context != $ctx and ((.pr_recommendations // []) | length > 0)' \
          "$saved" >/dev/null 2>&1; then
        echo "[CONTEXT] PR_RECOMMENDATIONS=none; reason=cap_reached"
        exit 0
      fi
    done < <(find "$results_dir" -maxdepth 1 -type f -name "$(jq -r '.pr_number' "$input")-*.json")

    diff_out=$(git diff -U0 "${base_ref}...HEAD") || fail diff_failed "git diff ${base_ref}...HEAD failed"
    # shellcheck source=../hooks/scripts/lib/diff-hunks.sh
    source "$HOOKS_DIR/scripts/lib/diff-hunks.sh"
    diff_hunks_parse <<< "$diff_out"

    selected='[]'
    n=$(jq '.recommendation_items | length' "$items")
    i=0
    while [ "$i" -lt "$n" ]; do
      item=$(jq -c ".recommendation_items[$i]" "$items")
      pos=$i
      i=$((i + 1))
      [ "$(printf '%s' "$item" | jq -r '.classification')" = "actionable" ] || continue
      spec=$(printf '%s' "$item" | jq -r '.file_line // empty')
      if [[ "$spec" =~ ^(.+):([0-9]+)-([0-9]+)$ ]]; then
        f=${BASH_REMATCH[1]} s=${BASH_REMATCH[2]} e=${BASH_REMATCH[3]}
      elif [[ "$spec" =~ ^(.+):([0-9]+)$ ]]; then
        f=${BASH_REMATCH[1]} s=${BASH_REMATCH[2]} e=${BASH_REMATCH[2]}
      else
        continue
      fi
      # plus_hunks only: minus_hunks holds old-file numbers of deleted lines,
      # which are not lines this PR added.
      range_overlaps "$plus_hunks" "$f" "$s" "$e" || continue
      selected=$(printf '%s' "$selected" | jq -c --argjson item "$item" --argjson pos "$pos" \
        --arg f "$f" --argjson line "$s" '. + [{pos: $pos, reviewer: $item.reviewer_type, file: $f, line: $line, description: $item.content}]')
    done

    count=$(printf '%s' "$selected" | jq 'length')
    if [ "$count" -eq 0 ]; then
      echo "[CONTEXT] PR_RECOMMENDATIONS=none; reason=no_candidates"
      exit 0
    fi

    tmp=$(mktemp "$input.XXXXXX") || fail write_failure "mktemp failed next to $input"
    if ! jq --argjson sel "$selected" '
        .pr_recommendations = [$sel | to_entries[] | .value + {id: ("R-" + ((.key + 1) | tostring | if length < 2 then "0" + . else . end))} | del(.pos)]
      ' "$input" > "$tmp" || ! mv "$tmp" "$input"; then
      rm -f "$tmp"
      fail write_failure "could not write pr_recommendations to $input"
    fi
    ids=$(jq -r '[.pr_recommendations[].id] | join(",")' "$input")
    positions=$(printf '%s' "$selected" | jq -r 'map(.pos | tostring) | join(",")')
    echo "[CONTEXT] PR_RECOMMENDATIONS=registered; count=$count; ids=$ids; positions=$positions"
    ;;
  check|mark)
    case "$pr" in ''|*[!0-9]*|0) usage ;; esac
    resolve_results_dir
    latest_json
    done_file="$state_root/.rite/state/pr-recommendations-done-$pr.txt"
    base=$(basename "$json")
    sha=$(jq -r '.commit_sha // empty' "$json")
    [ -n "$sha" ] || fail json_invalid "commit_sha missing: $json"
    if [ "$mode" = mark ]; then
      mkdir -p "$state_root/.rite/state" && printf '%s %s\n' "$base" "$sha" > "$done_file" \
        || fail write_failure "could not write $done_file"
      echo "[CONTEXT] PR_RECOMMENDATIONS_MARK=done; json=$base"
      exit 0
    fi
    count=$(jq '(.pr_recommendations // []) | length' "$json")
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
