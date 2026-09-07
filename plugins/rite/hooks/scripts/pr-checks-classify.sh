#!/bin/bash
# Classify the CI checks shared by review and merge.
# Usage: bash pr-checks-classify.sh < pr.json (no arguments)
# Input: exactly one JSON value from gh pr view --json statusCheckRollup.
# Output: JSON {state, checks, failed}; state is healthy, pending, unhealthy,
# unknown, or none. Each check is {name, status, conclusion, url}, using
# CheckRun name/status/conclusion/detailsUrl or StatusContext
# context/state/state/targetUrl. Missing or malformed display fields are null.
# failed contains completed CheckRun failures and failed StatusContexts even
# when another check is pending; it does not infer continue-on-error policy.
# Invalid rollup structure is unknown. Display metadata never changes state.
# Exit: 0 for a classified JSON value (including unknown); nonzero with a
# stderr diagnostic for arguments, empty/invalid JSON, or jq execution failure.
set -uo pipefail

if [ "$#" -ne 0 ]; then
  echo "ERROR: pr-checks-classify: expected JSON on stdin and no arguments" >&2
  exit 1
fi

if ! result=$(jq -ces '
  if length != 1 then error("expected exactly one JSON value") else .[0] end |
  def classify:
  if (.statusCheckRollup | type) != "array" then "unknown"
  elif (.statusCheckRollup | length) == 0 then "none"
  # 集約 precedence は unknown > pending > unhealthy > healthy。
  # mixed pending+unknown を pending に落とすと --force-ci で unknown を迂回できるため unknown を先に判定する。
  elif any(.statusCheckRollup[];
      (.__typename == "CheckRun" and
        ((.status | type) != "string" or
         (.status as $s | (["QUEUED", "IN_PROGRESS", "WAITING", "REQUESTED", "PENDING", "COMPLETED"] | index($s)) == null) or
         (.status == "COMPLETED" and (.conclusion | type) != "string"))) or
      (.__typename == "StatusContext" and
        ((.state | type) != "string" or
         (.state as $s | (["PENDING", "EXPECTED", "SUCCESS", "ERROR", "FAILURE"] | index($s)) == null))) or
      (.__typename != "CheckRun" and .__typename != "StatusContext")) then "unknown"
  elif any(.statusCheckRollup[];
      (.__typename == "CheckRun" and .status != "COMPLETED") or
      (.__typename == "StatusContext" and (.state == "PENDING" or .state == "EXPECTED"))) then "pending"
  elif any(.statusCheckRollup[];
      (.__typename == "CheckRun" and
        (.conclusion as $c | (["SUCCESS", "NEUTRAL", "SKIPPED"] | index($c)) == null)) or
      (.__typename == "StatusContext" and (.state == "ERROR" or .state == "FAILURE"))) then "unhealthy"
  elif all(.statusCheckRollup[];
      (.__typename == "CheckRun" and .status == "COMPLETED" and
        (.conclusion as $c | (["SUCCESS", "NEUTRAL", "SKIPPED"] | index($c)) != null)) or
      (.__typename == "StatusContext" and .state == "SUCCESS")) then "healthy"
  else "unknown"
  end;
  def display_string: if type == "string" then . else null end;
  def normalized:
    if .__typename == "StatusContext" then
      {name: (.context | display_string), status: (.state | display_string),
       conclusion: (.state | display_string), url: (.targetUrl | display_string)}
    else
      {name: (.name | display_string), status: (.status | display_string),
       conclusion: (.conclusion | display_string), url: (.detailsUrl | display_string)}
    end;
  (try classify catch "unknown") as $state |
  (if type == "object" then .statusCheckRollup else null end) as $rollup |
  (if ($rollup | type) == "array" then
     [$rollup[] | select(type == "object")]
   else [] end) as $checks |
  {state: $state, checks: [$checks[] | normalized],
   failed: [$checks[] | select(
     (.__typename == "CheckRun" and .status == "COMPLETED" and
       (.conclusion | type) == "string" and
       (.conclusion as $c | (["SUCCESS", "NEUTRAL", "SKIPPED"] | index($c)) == null)) or
     (.__typename == "StatusContext" and (.state == "ERROR" or .state == "FAILURE"))) |
     normalized]}
'); then
  echo "ERROR: pr-checks-classify: could not classify input JSON (jq failed)" >&2
  exit 1
fi
printf '%s\n' "$result"
