#!/usr/bin/env bash
set -u

# Validate the producer contract before reviewer output reaches aggregation.
# rc=0: every finding has a valid evidence anchor (or an explicit allowed
#       Hypothetical exception); rc=1: retryable contract violation; rc=2: usage.

reviewer_type=""
input=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --reviewer-type|--input)
      option="$1"
      if [ "$#" -lt 2 ]; then
        echo "ERROR: $option requires a value" >&2
        exit 2
      fi
      value="$2"
      [ "$option" = "--reviewer-type" ] && reviewer_type="$value" || input="$value"
      shift 2 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$reviewer_type" ] || [ -z "$input" ] || [ ! -r "$input" ]; then
  echo "ERROR: --reviewer-type and readable --input are required" >&2
  exit 2
fi

case "$reviewer_type" in
  security) exception_category="security" ;;
  devops) exception_category="devops infra" ;;
  dependencies) exception_category="dependencies" ;;
  application) exception_category="database migration" ;;
  *) exception_category="" ;;
esac

stats=$(awk -v exception_category="$exception_category" -v reviewer_type="$reviewer_type" '
  BEGIN { in_findings=0; saw_heading=0; saw_header=0; saw_separator=0; findings=0; missing=0; malformed=0 }
  function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
  /^###[[:space:]]*(指摘事項|Findings)[[:space:]]*$/ { in_findings=1; saw_heading=1; next }
  in_findings && /^###[[:space:]]/ { in_findings=0 }
  !in_findings || $0 !~ /^[[:space:]]*\|/ { next }
  /^\|[[:space:]]*(重要度|Severity)[[:space:]]*\|/ {
    header_columns = split($0, header_cell, "|")
    if (header_columns == 7 && trim(header_cell[5]) ~ /^(内容|Description)$/) saw_header=1
    else malformed++
    next
  }
  /^\|[[:space:]]*:?-+/ {
    separator_columns = split($0, separator_cell, "|")
    separator_valid = (separator_columns == 7)
    for (i = 2; i <= 6 && separator_valid; i++) {
      if (trim(separator_cell[i]) !~ /^:?-+:?$/) separator_valid=0
    }
    if (separator_valid) saw_separator=1
    else malformed++
    next
  }
  /^\|[[:space:]]*(なし|None)[[:space:]]*\|/ { next }
  {
    columns = split($0, cell, "|")
    # Canonical reviewer finding table: leading/trailing pipe plus five cells.
    if (columns != 7) { malformed++; next }
    content = trim(cell[5])
    findings++
    evidence = (content ~ /Likelihood-Evidence:[[:space:]]*(existing_call_site|new_call_site|entrypoint_connection|runtime_observation)[[:space:]]+[^[:space:]]/)
    hypothetical = (exception_category != "" && index(content, "Likelihood: Hypothetical (例外カテゴリ: " exception_category ")") > 0)
    if (!evidence && !hypothetical) missing++
  }
  END { printf "%d\t%d\t%d\t%d\t%d\t%d\n", findings, missing, malformed, saw_heading, saw_header, saw_separator }
' "$input") || {
  echo "[CONTEXT] LIKELIHOOD_EVIDENCE_GATE_FAILED=1; reason=parse_failed; reviewer=$reviewer_type" >&2
  exit 2
}

IFS=$'\t' read -r findings missing malformed saw_heading saw_header saw_separator <<EOF
$stats
EOF
if [ "$saw_heading" -ne 1 ]; then
  echo "ERROR: reviewer output is missing the canonical findings heading" >&2
  echo "[CONTEXT] LIKELIHOOD_EVIDENCE_GATE_FAILED=1; reason=findings_heading_missing; reviewer=$reviewer_type" >&2
  exit 1
fi
if [ "$saw_header" -ne 1 ]; then
  echo "ERROR: reviewer output is missing the canonical five-column findings table header" >&2
  echo "[CONTEXT] LIKELIHOOD_EVIDENCE_GATE_FAILED=1; reason=table_header_missing; reviewer=$reviewer_type" >&2
  exit 1
fi
if [ "$saw_separator" -ne 1 ]; then
  echo "ERROR: reviewer output is missing a canonical five-column table separator" >&2
  echo "[CONTEXT] LIKELIHOOD_EVIDENCE_GATE_FAILED=1; reason=table_malformed; reviewer=$reviewer_type; malformed=$malformed" >&2
  exit 1
fi
if [ "$malformed" -gt 0 ]; then
  echo "ERROR: reviewer output contains $malformed malformed finding table row(s); expected exactly five columns" >&2
  echo "[CONTEXT] LIKELIHOOD_EVIDENCE_GATE_FAILED=1; reason=table_malformed; reviewer=$reviewer_type; malformed=$malformed" >&2
  exit 1
fi
if [ "$missing" -gt 0 ]; then
  echo "ERROR: reviewer output contains $missing finding(s) without a valid Likelihood-Evidence anchor" >&2
  echo "[CONTEXT] LIKELIHOOD_EVIDENCE_GATE_FAILED=1; reason=anchor_missing; reviewer=$reviewer_type; findings=$findings; missing=$missing" >&2
  exit 1
fi

echo "[CONTEXT] LIKELIHOOD_EVIDENCE_GATE=passed; reviewer=$reviewer_type; findings=$findings"
