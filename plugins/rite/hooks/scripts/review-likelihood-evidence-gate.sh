#!/usr/bin/env bash
set -u

# Validate the producer contract before reviewer output reaches aggregation.
# rc=0: every finding has a valid evidence anchor (or an explicit allowed
#       Hypothetical exception); rc=1: retryable contract violation; rc=2: usage.

reviewer_type=""
input=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --reviewer-type) reviewer_type="${2:-}"; shift 2 ;;
    --input) input="${2:-}"; shift 2 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$reviewer_type" ] || [ -z "$input" ] || [ ! -r "$input" ]; then
  echo "ERROR: --reviewer-type and readable --input are required" >&2
  exit 2
fi

case "$reviewer_type" in
  security|devops|dependencies) exception_category=1 ;;
  *) exception_category=0 ;;
esac

stats=$(awk -v exception_category="$exception_category" -v reviewer_type="$reviewer_type" '
  BEGIN { in_findings=0; findings=0; missing=0 }
  /^###[[:space:]]*(指摘事項|Findings)[[:space:]]*$/ { in_findings=1; next }
  in_findings && /^###[[:space:]]/ { in_findings=0 }
  !in_findings || $0 !~ /^[[:space:]]*\|/ { next }
  /^\|[[:space:]]*(-+:?|-*[[:space:]]*#)[[:space:]]*\|/ { next }
  /^\|[[:space:]]*(重要度|Severity)[[:space:]]*\|/ { next }
  /^\|[[:space:]]*(なし|None)[[:space:]]*\|/ { next }
  {
    findings++
    evidence = ($0 ~ /Likelihood-Evidence:[[:space:]]*(existing_call_site|new_call_site|entrypoint_connection|runtime_observation)[[:space:]]+[^|[:space:]]/)
    hypothetical = ($0 ~ /Likelihood:[[:space:]]*Hypothetical[[:space:]]*\(例外カテゴリ:[[:space:]]*[^)]+\)/)
    migration = (reviewer_type == "application" && $0 ~ /例外カテゴリ:[[:space:]]*database migration/)
    if (!evidence && !((exception_category || migration) && hypothetical)) missing++
  }
  END { printf "%d\t%d\n", findings, missing }
' "$input") || {
  echo "[CONTEXT] LIKELIHOOD_EVIDENCE_GATE_FAILED=1; reason=parse_failed; reviewer=$reviewer_type" >&2
  exit 2
}

IFS=$'\t' read -r findings missing <<EOF
$stats
EOF
if [ "$missing" -gt 0 ]; then
  echo "ERROR: reviewer output contains $missing finding(s) without a valid Likelihood-Evidence anchor" >&2
  echo "[CONTEXT] LIKELIHOOD_EVIDENCE_GATE_FAILED=1; reason=anchor_missing; reviewer=$reviewer_type; findings=$findings; missing=$missing" >&2
  exit 1
fi

echo "[CONTEXT] LIKELIHOOD_EVIDENCE_GATE=passed; reviewer=$reviewer_type; findings=$findings"
