#!/usr/bin/env bash
# Collect remaining non-blocking findings for iterate's post-mergeable sweep.
#
# Targets:
#   - all non_blocking_findings[]
#   - findings[] with scope == "nit-noted" (blocking-out remainder)
#   - guardrail_audit_log[] copied as already_rejected (record only, no re-judge)
# --json is an offline transform; pass --pr as well to exclude persisted ledger rows.
#
# Usage:
#   bash nb-sweep-collect.sh --json <path>
#   bash nb-sweep-collect.sh --pr <n> --state-root <path>
#
# stdout: JSON {status, count, record, targets[], already_rejected[]}
# stderr: [CONTEXT] NB_SWEEP_COLLECT=ok|empty|failed; count=N; record=PATH
#
# Exit:
#   0  ok (count>=1) or empty (count==0)
#   1  JSON missing / unreadable / invalid (fail-loud)
#   2  argument error
set -euo pipefail

json=""
pr=""
state_root=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) json=${2:-}; shift 2 ;;
    --pr) pr=${2:-}; shift 2 ;;
    --state-root) state_root=${2:-}; shift 2 ;;
    *) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$json" ]; then
  case "$pr" in ''|*[!0-9]*) echo "ERROR: --pr must be a positive integer (or pass --json)" >&2; exit 2 ;; esac
  [ -n "$state_root" ] || { echo "ERROR: --state-root is required when --json is omitted" >&2; exit 2; }
  results_dir="$state_root/.rite/review-results"
  if [ ! -d "$results_dir" ]; then
    echo "ERROR: review results dir missing: $results_dir" >&2
    echo "[CONTEXT] NB_SWEEP_COLLECT=failed; count=0; record=; reason=results_dir_missing" >&2
    exit 1
  fi
  if ! json=$(find "$results_dir" -maxdepth 1 -type f -name "${pr}-*.json" | LC_ALL=C sort | tail -1); then
    echo "ERROR: review result JSON search failed for PR #$pr" >&2
    echo "[CONTEXT] NB_SWEEP_COLLECT=failed; count=0; record=; reason=json_search_failed" >&2
    exit 1
  fi
  if [ -z "$json" ]; then
    echo "ERROR: no review JSON for PR #$pr in $results_dir" >&2
    echo "[CONTEXT] NB_SWEEP_COLLECT=failed; count=0; record=; reason=json_missing" >&2
    exit 1
  fi
fi

if [ ! -f "$json" ] || [ ! -r "$json" ]; then
  echo "ERROR: review JSON unreadable: $json" >&2
  echo "[CONTEXT] NB_SWEEP_COLLECT=failed; count=0; record=$json; reason=json_unreadable" >&2
  exit 1
fi

if ! jq empty "$json" >/dev/null 2>&1; then
  echo "ERROR: review JSON invalid: $json" >&2
  echo "[CONTEXT] NB_SWEEP_COLLECT=failed; count=0; record=$json; reason=json_invalid" >&2
  exit 1
fi

# Ledger reads are mandatory in the live --pr path. A failed read must not
# silently re-issue findings already handled by a prior sweep.
ledger_keys='[]'
collect_fail() {
  echo "ERROR: non-blocking ledger read failed: $1" >&2
  echo "[CONTEXT] NB_SWEEP_COLLECT=failed; count=0; record=$json; reason=$1" >&2
  exit 1
}
if [ -n "$pr" ]; then
  case "$pr" in ''|*[!0-9]*|0) echo "ERROR: --pr must be a positive integer" >&2; exit 2 ;; esac
  owner_repo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner') || collect_fail repo_unresolved
  [ -n "$owner_repo" ] || collect_fail repo_unresolved
  pr_body=$(gh pr view "$pr" -R "$owner_repo" --json body --jq '.body') || collect_fail related_issue_unresolved
  # Keep the same closing-keyword / issue-N branch precedence as
  # review-nonblocking-record.sh::_resolve_related_issue.
  issue=$(printf '%s' "$pr_body" | grep -ioE '(close[sd]?|fix(e[sd])?|resolve[sd]?) #[0-9]+' | head -1 | grep -oE '[0-9]+$' || true)
  if [ -z "$issue" ]; then
    head_ref=$(gh pr view "$pr" -R "$owner_repo" --json headRefName --jq '.headRefName') || collect_fail related_issue_unresolved
    if [[ "$head_ref" =~ issue-([0-9]+) ]]; then issue=${BASH_REMATCH[1]}; fi
  fi
  case "$issue" in ''|*[!0-9]*|0) collect_fail related_issue_unresolved ;; esac
  comments=$(gh api --paginate --slurp "repos/$owner_repo/issues/$issue/comments") || collect_fail comments_unreadable
  if ! ledger_keys=$(printf '%s' "$comments" | jq -ce '
    def trim: gsub("^\\s+|\\s+$"; "");
    if type != "array" or any(.[]; type != "array") then error("invalid comment pages") else . end
    | [ .[][]
        | .body // ""
        | select(startswith("## 📜 rite 非実測指摘の記録"))
        | select((split("\n") | map(sub("\r$"; "")) | map(select(test("\\S"))) | last) == "<!-- rite:nbr:v1 -->")
        | split("### 却下台帳\n")[1:][]
        | split("📎 non_blocking_count:")[0] | split("\n### ")[0]
        | split("\n")[] | select(startswith("|"))
        | split("|") | map(trim)
        | select(.[3] == "rejected" or .[3] == "recorded" or .[3] == "issued")
        | [.[1], .[2]] ] | unique
  '); then collect_fail ledger_invalid; fi
fi

if ! out=$(jq -c --arg record "$json" --argjson ledger_keys "$ledger_keys" '
  def target:
    {
      id: (.id // ""),
      source: .source,
      file: (.file // ""),
      line: (.line // null),
      severity: (.severity // "UNKNOWN"),
      scope: (.scope // ""),
      description: (.description // ""),
      suggestion: (.suggestion // ""),
      verification: .verification,
      route: (if .scope != "nit-noted" and .severity == "MEDIUM"
        and (try .verification.measured catch null) == true then "issued" else "recorded" end)
    };
  def pending($id; $location):
    ($ledger_keys | any(. == [$id, $location])) | not;
  (.non_blocking_findings // []) as $nb
  | (.findings // []) as $findings
  | ($nb | map(. + {source: "non_blocking_findings"} | target)) as $from_nb
  | ($findings
      | map(select(.scope == "nit-noted") | . + {source: "findings_nit_noted"} | target)
    ) as $from_nit
  | ($from_nb + $from_nit) as $all
  | ($all | map(select(pending(.id; .file + ":" + (.line | tostring))))) as $pending
  | (reduce $pending[] as $t ({};
      if ($t.id | tostring | length) > 0 and (.[$t.id] | not)
      then .[$t.id] = $t
      elif ($t.id | tostring | length) == 0
      then .["_anon_" + ($t.file|tostring) + ":" + ($t.line|tostring)] = $t
      else .
      end
    ) | [.[]]) as $targets
  | ((.guardrail_audit_log // []) | map({
        source: "guardrail_audit_log",
        route: "recorded",
        severity: (.original_severity // ""),
        verification: {measured: false},
        reviewer: (.reviewer // ""),
        file_line: (.file_line // ""),
        original_severity: (.original_severity // ""),
        description: (.description // ""),
        filter_reason: (.filter_reason // "")
      }) | map(select(pending(.reviewer; .file_line)))) as $guardrails
  | (($targets | length) + ($guardrails | length)) as $count
  | {
      status: (if $count == 0 then "empty" else "ok" end),
      count: $count,
      record: $record,
      targets: $targets,
      already_rejected: $guardrails
    }
' "$json"); then
  echo "ERROR: review JSON collect transform failed: $json" >&2
  echo "[CONTEXT] NB_SWEEP_COLLECT=failed; count=0; record=$json; reason=jq_transform_failed" >&2
  exit 1
fi

count=$(printf '%s' "$out" | jq -r '.count')
status=$(printf '%s' "$out" | jq -r '.status')
echo "[CONTEXT] NB_SWEEP_COLLECT=$status; count=$count; record=$json" >&2
printf '%s\n' "$out"
