#!/usr/bin/env bash
# Collect remaining non-blocking findings for iterate's post-mergeable sweep.
#
# Targets:
#   - all non_blocking_findings[]
#   - findings[] with scope == "nit-noted" (blocking-out remainder)
#   - guardrail_audit_log[] copied as already_rejected (no re-judge)
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

if ! out=$(jq -c --arg record "$json" '
  def target:
    {
      id: (.id // ""),
      source: .source,
      file: (.file // ""),
      line: (.line // null),
      severity: (.severity // "UNKNOWN"),
      scope: (.scope // ""),
      description: (.description // ""),
      suggestion: (.suggestion // "")
    };
  (.non_blocking_findings // []) as $nb
  | (.findings // []) as $findings
  | ($nb | map(. + {source: "non_blocking_findings"} | target)) as $from_nb
  | ($findings
      | map(select(.scope == "nit-noted") | . + {source: "findings_nit_noted"} | target)
    ) as $from_nit
  | ($from_nb + $from_nit) as $all
  | (reduce $all[] as $t ({};
      if ($t.id | tostring | length) > 0 and (.[$t.id] | not)
      then .[$t.id] = $t
      elif ($t.id | tostring | length) == 0
      then .["_anon_" + ($t.file|tostring) + ":" + ($t.line|tostring)] = $t
      else .
      end
    ) | [.[]]) as $targets
  | {
      status: (if ($targets | length) == 0 then "empty" else "ok" end),
      count: ($targets | length),
      record: $record,
      targets: $targets,
      already_rejected: ((.guardrail_audit_log // []) | map({
        source: "guardrail_audit_log",
        reviewer: (.reviewer // ""),
        file_line: (.file_line // ""),
        original_severity: (.original_severity // ""),
        description: (.description // ""),
        filter_reason: (.filter_reason // "")
      }))
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
