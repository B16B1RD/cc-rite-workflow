#!/usr/bin/env bash
set -u

# Validate the producer contract before reviewer output reaches aggregation.
# rc=0: every finding has a valid evidence anchor (or an explicit allowed
#       Hypothetical exception) and every recommendation carries one of the
#       three 分類 values; rc=1: retryable contract violation; rc=2: usage.

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

parsed=$(awk -v exception_category="$exception_category" -v reviewer_type="$reviewer_type" '
  BEGIN { in_findings=0; in_recommendations=0; saw_heading=0; saw_header=0; saw_separator=0; findings=0; missing=0; malformed=0; recommendations=0; invalid=0 }
  function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
  /^###[[:space:]]*(推奨事項|Recommendations)[[:space:]]*$/ { in_recommendations=1; in_findings=0; next }
  in_recommendations && /^#/ { in_recommendations=0 }
  in_recommendations {
    # Every non-indented line is one recommendation; indented lines continue the
    # previous one. An unclassified item must never fall out of adoption triage.
    if (trim($0) == "" || substr($0, 1, 1) ~ /[ \t]/ || $0 ~ /^\|[[:space:]]*:?-+/) next
    text = $0
    sub(/^([-*+]|[0-9]+\.)[[:space:]]+/, "", text)
    text = trim(text)
    if (text ~ /^(なし|None)$/) next
    recommendations++
    value = "(missing)"
    if (match(text, /分類[*`]*[[:space:]]*(:|：)/)) {
      clause = substr(text, RSTART + RLENGTH)
      while (clause != "" && substr(clause, 1, 1) ~ /[*` \t]/) clause = substr(clause, 2)
      cut = index(clause, "—")
      if (cut) clause = substr(clause, 1, cut - 1)
      clause = trim(clause)
      # The value ends at the first character outside [A-Za-z0-9_-], so a note may follow
      # it ("boundary（スコープ外）"). A second classification word reached across only
      # separators, decoration and "or"/"and" means the reviewer did not pick one value;
      # the whole clause is then reported. The same word inside a note is not a value.
      if (match(clause, /[A-Za-z0-9_-]+/) && RSTART == 1) {
        value = substr(clause, 1, RLENGTH)
        rest = substr(clause, RLENGTH + 1)
        while (rest != "") {
          if (substr(rest, 1, 1) ~ /[ \t\/,;&+|`*]/) rest = substr(rest, 2)
          else if (index(rest, "、") == 1) rest = substr(rest, length("、") + 1)
          else if (index(rest, "・") == 1) rest = substr(rest, length("・") + 1)
          else if (index(rest, "／") == 1) rest = substr(rest, length("／") + 1)
          else if (index(rest, "，") == 1) rest = substr(rest, length("，") + 1)
          else if (index(rest, "または") == 1) rest = substr(rest, length("または") + 1)
          else if (index(rest, "もしくは") == 1) rest = substr(rest, length("もしくは") + 1)
          else if (index(rest, "か") == 1) rest = substr(rest, length("か") + 1)
          else if (index(rest, "と") == 1) rest = substr(rest, length("と") + 1)
          else if (tolower(substr(rest, 1, 6)) == "and/or") rest = substr(rest, 7)
          else if (tolower(substr(rest, 1, 3)) == "(or") rest = substr(rest, 4)
          else if (tolower(substr(rest, 1, 3)) == "or ") rest = substr(rest, 4)
          else if (tolower(substr(rest, 1, 4)) == "and ") rest = substr(rest, 5)
          else break
        }
        rest = tolower(rest)
        if (index(rest, "actionable") == 1 || index(rest, "design_confirmation") == 1 || index(rest, "boundary") == 1) value = clause
      } else if (clause != "") {
        value = clause
        sub(/[[:space:]].*/, "", value)
      }
    }
    if (value != "actionable" && value != "design_confirmation" && value != "boundary") {
      invalid++
      bad[invalid] = NR "\t" value
    }
    next
  }
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
      if (trim(separator_cell[i]) !~ /^:?---+:?$/) separator_valid=0
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
  END {
    printf "%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", findings, missing, malformed, saw_heading, saw_header, saw_separator, recommendations, invalid
    for (i = 1; i <= invalid; i++) print bad[i]
  }
' "$input") || {
  echo "[CONTEXT] LIKELIHOOD_EVIDENCE_GATE_FAILED=1; reason=parse_failed; reviewer=$reviewer_type" >&2
  exit 2
}

IFS=$'\t' read -r findings missing malformed saw_heading saw_header saw_separator recommendations invalid <<EOF
${parsed%%$'\n'*}
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

if [ "$invalid" -gt 0 ]; then
  echo "ERROR: reviewer output contains $invalid recommendation(s) whose 分類 is missing or not one of actionable / design_confirmation / boundary" >&2
  printf '%s\n' "$parsed" | tail -n +2 | while IFS=$'\t' read -r line value; do
    echo "  line $line: 分類=$value" >&2
  done
  echo "[CONTEXT] LIKELIHOOD_EVIDENCE_GATE_FAILED=1; reason=recommendation_classification_invalid; reviewer=$reviewer_type; recommendations=$recommendations; invalid=$invalid" >&2
  exit 1
fi

echo "[CONTEXT] LIKELIHOOD_EVIDENCE_GATE=passed; reviewer=$reviewer_type; findings=$findings; recommendations=$recommendations"
