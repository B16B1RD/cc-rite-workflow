#!/bin/bash
# Classify fatal review findings and persist non-fatal findings atomically.
# stdout: one JSON object containing ID-keyed maps; context marker on stderr.
# Errors: [fix:error] reason=...; findings=ID,..., exit 1; source stays unchanged.
set -uo pipefail

review_source=""
review_source_path=""
repo_root=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --review-source|--review-source-path|--repo-root)
      [ "$#" -ge 2 ] || { echo "ERROR: missing value for $1" >&2; exit 2; }
      case "$1" in
        --review-source) review_source="$2" ;;
        --review-source-path) review_source_path="$2" ;;
        --repo-root) repo_root="$2" ;;
      esac
      shift 2 ;;
    -h|--help)
      echo "Usage: review-findings-maps.sh --review-source SOURCE --review-source-path PATH [--repo-root DIR]"
      exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$review_source" in local_file|explicit_file) ;; *) exit 0 ;; esac
[ -n "$review_source_path" ] || { echo "ERROR: review source path required" >&2; exit 2; }
if [ -n "$repo_root" ]; then
  cd "$repo_root" || exit 2
fi

fail() {
  printf '[fix:error] reason=%s; findings=%s\n' "$1" "${2:-}"
  exit 1
}
tmp=""
trap '[ -z "$tmp" ] || rm -f -- "$tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Validate before moving any findings. nit-noted findings retain their full data.
result=$(jq -c '
  def gated: .scope == "current-pr" or .scope == "follow-up";
  def measured: if (.verification | type) == "object" then .verification.measured else null end;
  def fatal: gated and (.severity == "CRITICAL" or .severity == "HIGH")
    and measured == true;
  def invalid($reason; $items): {error: $reason, findings: [$items[] | .id]};
  if (.findings | type) != "array"
    or ((.non_blocking_findings // []) | type) != "array" then
    {error: "invalid_review_json", findings: []}
  else
    [.findings[] | select(.severity as $s |
      ["CRITICAL", "HIGH", "MEDIUM", "LOW-MEDIUM", "LOW"] | index($s) | not)] as $severity
    | [.findings[] | select(.scope as $s |
      ["current-pr", "follow-up", "nit-noted"] | index($s) | not)] as $scope
    | [.findings[] | select(gated) | select((measured | type) != "boolean")] as $measured
    | [.findings[] | select((.id | type) != "string" or .id == "")] as $ids
    | if ($severity | length) > 0 then invalid("severity_enum_violation"; $severity)
      elif ($scope | length) > 0 then invalid("scope_enum_violation"; $scope)
      elif ($measured | length) > 0 then invalid("measured_undetermined"; $measured)
      elif ($ids | length) > 0 then invalid("finding_id_invalid"; $ids)
      elif ([.findings[].id] | length) != ([.findings[].id] | unique | length) then
        {error: "finding_id_duplicate", findings: [.findings[].id]}
      else
        [.findings[] | select(gated and (fatal | not)) | .demotion_reason = "non_fatal"] as $moved
        | {fatal: ([.findings[] | select(fatal)] | length), moved: ($moved | length),
           maps: {
             fatal_map: ([.findings[] | {key: .id, value: fatal}] | from_entries),
             severity_map: ([.findings[] | {key: .id, value: .severity}] | from_entries),
             scope_map: ([.findings[] | {key: .id, value: .scope}] | from_entries)},
           document: (.findings |= map(select((gated | not) or fatal))
             | if ($moved | length) > 0 then
                 .non_blocking_findings = ((.non_blocking_findings // []) + $moved)
               else . end)}
      end
  end
' "$review_source_path") || fail invalid_review_json
error=$(jq -r '.error // empty' <<< "$result") || fail invalid_review_json
[ -z "$error" ] || fail "$error" "$(jq -r '.findings | map(tostring) | join(",")' <<< "$result")"

# Use a sibling tempfile so rename is atomic on the source filesystem.
tmp=$(mktemp "${review_source_path}.triage.XXXXXX") || fail io_error
jq '.document' <<< "$result" > "$tmp" || fail io_error
mv -- "$tmp" "$review_source_path" || fail io_error
tmp=""
jq -r '"[CONTEXT] FIX_FATAL_TRIAGE=applied; fatal=\(.fatal); moved=\(.moved)"' <<< "$result" >&2
jq -c '.maps' <<< "$result"
