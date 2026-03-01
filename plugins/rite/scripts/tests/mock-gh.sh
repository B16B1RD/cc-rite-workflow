#!/bin/bash
# Mock gh CLI for testing create-issue-with-projects.sh
# This script intercepts gh commands and returns predefined responses.
#
# Usage:
#   Set MOCK_GH_SCENARIO before running tests to control behavior.
#   The test harness prepends the directory containing this script to PATH
#   so that `gh` resolves here instead of the real binary.
#
# Scenarios:
#   "success"              - All commands succeed (default)
#   "issue_create_fail"    - gh issue create fails
#   "project_add_fail"     - gh project item-add fails
#   "graphql_fail"         - gh api graphql fails
#   "no_item_id"           - GraphQL returns empty items, but item-add --format json provides ITEM_ID
#   "no_item_id_no_json"   - item-add succeeds without JSON output AND GraphQL returns empty items
#   "field_edit_fail"      - gh project item-edit fails
#   "org_owner"            - Owner type is Organization
#   "iteration_success"    - GraphQL includes iteration field with current iteration
#   "no_current_iteration" - GraphQL includes iteration field but only future iterations
#   "no_project_id"        - GraphQL returns null project ID
#   "url_parse_fail"       - gh issue create returns non-URL string (no trailing number)
set -euo pipefail

SCENARIO="${MOCK_GH_SCENARIO:-success}"
MOCK_ISSUE_NUMBER="${MOCK_ISSUE_NUMBER:-42}"
MOCK_ISSUE_URL="https://github.com/test-owner/test-repo/issues/${MOCK_ISSUE_NUMBER}"
MOCK_PROJECT_ID="PVT_mock123"
MOCK_ITEM_ID="PVTI_mock456"

# Log calls for assertion (append to MOCK_GH_LOG if set)
if [ -n "${MOCK_GH_LOG:-}" ]; then
  echo "gh $*" >> "$MOCK_GH_LOG"
fi

case "$1" in
  issue)
    case "$2" in
      create)
        if [ "$SCENARIO" = "issue_create_fail" ]; then
          echo "error: failed to create issue" >&2
          exit 1
        fi
        if [ "$SCENARIO" = "url_parse_fail" ]; then
          echo "Created issue successfully"
          exit 0
        fi
        echo "$MOCK_ISSUE_URL"
        ;;
      *)
        echo "mock: unhandled gh issue subcommand: $2" >&2
        exit 1
        ;;
    esac
    ;;

  project)
    case "$2" in
      item-add)
        if [ "$SCENARIO" = "project_add_fail" ]; then
          echo "error: failed to add item to project" >&2
          exit 1
        fi
        # no_item_id_no_json: simulate item-add succeeding but without JSON output
        if [ "$SCENARIO" = "no_item_id_no_json" ]; then
          exit 0
        fi
        # Check if --format json was requested (pair detection: --format followed by json)
        has_format_json=false
        prev_arg=""
        for arg in "$@"; do
          if [ "$prev_arg" = "--format" ] && [ "$arg" = "json" ]; then
            has_format_json=true
            break
          fi
          prev_arg="$arg"
        done
        if [ "$has_format_json" = true ]; then
          cat <<ITEMJSON
{"id":"${MOCK_ITEM_ID}","title":"Mock Issue","type":"Issue","body":"","url":"${MOCK_ISSUE_URL}"}
ITEMJSON
        fi
        ;;
      item-edit)
        if [ "$SCENARIO" = "field_edit_fail" ]; then
          echo "error: failed to edit project item" >&2
          exit 1
        fi
        # Real gh outputs to stdout; suppress to avoid polluting captured output
        ;;
      *)
        echo "mock: unhandled gh project subcommand: $2" >&2
        exit 1
        ;;
    esac
    ;;

  repo)
    case "$2" in
      view)
        local_owner_type="User"
        if [ "$SCENARIO" = "org_owner" ]; then
          local_owner_type="Organization"
        fi
        json_data="{\"owner\":{\"login\":\"test-owner\",\"__typename\":\"${local_owner_type}\"}}"
        # Handle --jq flag: apply jq filter like real gh CLI
        jq_filter=""
        prev_arg=""
        for arg in "$@"; do
          if [ "$prev_arg" = "--jq" ]; then
            jq_filter="$arg"
            break
          fi
          prev_arg="$arg"
        done
        if [ -n "$jq_filter" ]; then
          printf '%s\n' "$json_data" | jq -r "$jq_filter"
        else
          echo "$json_data"
        fi
        ;;
      *)
        echo "mock: unhandled gh repo subcommand: $2" >&2
        exit 1
        ;;
    esac
    ;;

  api)
    case "$2" in
      graphql)
        if [ "$SCENARIO" = "graphql_fail" ]; then
          echo "error: GraphQL query failed" >&2
          exit 1
        fi

        # Detect mutation vs query (for iteration assignment)
        # Note: query arg may have leading newline (e.g., query=\nmutation...)
        is_mutation=false
        for arg in "$@"; do
          if [[ "$arg" == query=* ]] && [[ "$arg" == *mutation* ]]; then
            is_mutation=true
            break
          fi
        done

        if [ "$is_mutation" = true ]; then
          # No stdout output for mutations (only exit code matters to caller)
          exit 0
        fi

        # Determine GQL root based on owner type
        GQL_ROOT="user"
        if [ "$SCENARIO" = "org_owner" ]; then
          GQL_ROOT="organization"
        fi

        ITEMS_NODES="[{\"id\":\"${MOCK_ITEM_ID}\",\"content\":{\"number\":${MOCK_ISSUE_NUMBER}}}]"
        if [ "$SCENARIO" = "no_item_id" ] || [ "$SCENARIO" = "no_item_id_no_json" ]; then
          ITEMS_NODES="[]"
        fi

        PROJECT_ID_VALUE="\"${MOCK_PROJECT_ID}\""
        if [ "$SCENARIO" = "no_project_id" ]; then
          PROJECT_ID_VALUE="null"
        fi

        # Iteration field (conditionally included based on scenario)
        ITER_FIELD=""
        MOCK_CURRENT_SPRINT_START=$(date +%Y-%m-01)
        if [ "$SCENARIO" = "iteration_success" ]; then
          ITER_FIELD=',
            {
              "id": "FIELD_SPRINT",
              "name": "Sprint",
              "configuration": {
                "iterations": [
                  {"id": "ITER_PAST", "title": "Past Sprint", "startDate": "2020-01-01"},
                  {"id": "ITER_CURRENT", "title": "Current Sprint", "startDate": "'"$MOCK_CURRENT_SPRINT_START"'"}
                ]
              }
            }'
        elif [ "$SCENARIO" = "no_current_iteration" ]; then
          ITER_FIELD=',
            {
              "id": "FIELD_SPRINT",
              "name": "Sprint",
              "configuration": {
                "iterations": [
                  {"id": "ITER_FUTURE", "title": "Future Sprint", "startDate": "2099-01-01"}
                ]
              }
            }'
        fi

        cat <<EOJSON
{
  "data": {
    "${GQL_ROOT}": {
      "projectV2": {
        "id": ${PROJECT_ID_VALUE},
        "items": {
          "nodes": ${ITEMS_NODES}
        },
        "fields": {
          "nodes": [
            {
              "id": "FIELD_STATUS",
              "name": "Status",
              "options": [
                {"id": "OPT_TODO", "name": "Todo"},
                {"id": "OPT_INPROGRESS", "name": "In Progress"},
                {"id": "OPT_DONE", "name": "Done"}
              ]
            },
            {
              "id": "FIELD_PRIORITY",
              "name": "Priority",
              "options": [
                {"id": "OPT_HIGH", "name": "High"},
                {"id": "OPT_MEDIUM", "name": "Medium"},
                {"id": "OPT_LOW", "name": "Low"}
              ]
            },
            {
              "id": "FIELD_COMPLEXITY",
              "name": "Complexity",
              "options": [
                {"id": "OPT_XS", "name": "XS"},
                {"id": "OPT_S", "name": "S"},
                {"id": "OPT_M", "name": "M"},
                {"id": "OPT_L", "name": "L"},
                {"id": "OPT_XL", "name": "XL"}
              ]
            }${ITER_FIELD}
          ]
        }
      }
    }
  }
}
EOJSON
        ;;
      *)
        echo "mock: unhandled gh api subcommand: $2" >&2
        exit 1
        ;;
    esac
    ;;

  *)
    echo "mock: unhandled gh command: $1" >&2
    exit 1
    ;;
esac
