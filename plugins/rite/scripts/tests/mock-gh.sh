#!/bin/bash
# Mock gh CLI for testing create-issue-with-projects.sh AND projects-status-update.sh
# This script intercepts gh commands and returns predefined responses.
#
# Usage:
#   Set MOCK_GH_SCENARIO before running tests to control behavior.
#   The test harness prepends the directory containing this script to PATH
#   so that `gh` resolves here instead of the real binary.
#
# Scenarios (create-issue-with-projects.sh):
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
#   "iteration_mutation_fail" - GraphQL fields query OK (iteration field present),
#                              but the iteration assignment mutation fails (#669 F-02)
#   "gql_items_lookup_fail"  - GraphQL fields query OK (items.nodes=[]),
#                              but the GQL_ITEMS_QUERY (items lookup retry) fails (#669 cycle 2 follow-up)
#
# Scenarios (projects-status-update.sh):
#   "psu_success"              - Issue in project, Status updated
#   "psu_issue_not_found"      - repository.issue returns null
#   "psu_not_in_project"       - projectItems.nodes is empty (no auto_add)
#   "psu_auto_add_then_ok"     - First query empty, item-add succeeds, re-query finds item
#   "psu_auto_add_fail"        - item-add fails
#   "psu_auto_add_requery_empty" - item-add succeeds but re-query still empty
#   "psu_field_list_fail"      - gh project field-list fails
#   "psu_no_status_field"      - field-list returns no Status field
#   "psu_no_status_option"     - Status field exists but requested option name missing
#   "psu_item_edit_fail"       - gh project item-edit fails
#
# The projects-status-update.sh script uses a different GraphQL shape
# (`data.repository.issue.projectItems`) than create-issue-with-projects.sh
# (`data.{user|organization}.projectV2`), so this mock detects the query shape
# via the `repository(owner:` token in the query string and branches accordingly.
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
      field-list)
        # New: `gh project field-list PROJECT_NUMBER --owner OWNER --format json`
        # Used by projects-status-update.sh to resolve Status field + option ids.
        if [ "$SCENARIO" = "psu_field_list_fail" ]; then
          echo "error: failed to list project fields" >&2
          exit 1
        fi
        if [ "$SCENARIO" = "psu_no_status_field" ]; then
          cat <<'FLJSON'
{"fields": [{"id": "FIELD_PRIORITY", "name": "Priority", "options": [{"id": "OPT_P_HIGH", "name": "High"}]}]}
FLJSON
          exit 0
        fi
        if [ "$SCENARIO" = "psu_no_status_option" ]; then
          cat <<'FLJSON'
{"fields": [{"id": "FIELD_STATUS", "name": "Status", "options": [{"id": "OPT_TODO", "name": "Todo"}]}]}
FLJSON
          exit 0
        fi
        cat <<'FLJSON'
{
  "fields": [
    {"id": "FIELD_STATUS", "name": "Status", "options": [
      {"id": "OPT_TODO", "name": "Todo"},
      {"id": "OPT_INPROGRESS", "name": "In Progress"},
      {"id": "OPT_INREVIEW", "name": "In Review"},
      {"id": "OPT_DONE", "name": "Done"}
    ]}
  ]
}
FLJSON
        ;;
      item-add)
        if [ "$SCENARIO" = "project_add_fail" ] || [ "$SCENARIO" = "psu_auto_add_fail" ]; then
          echo "error: failed to add item to project" >&2
          exit 1
        fi
        # no_item_id_no_json / gql_items_lookup_fail: simulate item-add succeeding but without JSON output
        # (forces ITEM_ID retrieval to fall through to GQL_RESULT.items.nodes, then GQL_ITEMS_QUERY retry)
        if [ "$SCENARIO" = "no_item_id_no_json" ] || [ "$SCENARIO" = "gql_items_lookup_fail" ]; then
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
        if [ "$SCENARIO" = "field_edit_fail" ] || [ "$SCENARIO" = "psu_item_edit_fail" ]; then
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

        # Detect query shape: projects-status-update.sh queries `repository(owner:`
        # while create-issue-with-projects.sh queries `user|organization(login:`.
        # gql_items_lookup_fail (#669 cycle 2 follow-up): fields query (containing
        # `fields(first: 20)`) succeeds with empty items, but the items lookup
        # retry query (containing `items(last: 20)` and NOT `fields(first: 20)`)
        # fails with exit 1.
        is_repository_query=false
        is_mutation=false
        is_items_lookup_only=false
        for arg in "$@"; do
          if [[ "$arg" == query=* ]]; then
            if [[ "$arg" == *"repository(owner:"* ]]; then
              is_repository_query=true
            fi
            if [[ "$arg" == *mutation* ]]; then
              is_mutation=true
            fi
            if [[ "$arg" == *"items(last: 20)"* ]] && [[ "$arg" != *"fields(first: 20)"* ]]; then
              is_items_lookup_only=true
            fi
            break
          fi
        done

        if [ "$SCENARIO" = "gql_items_lookup_fail" ] && [ "$is_items_lookup_only" = true ]; then
          echo "error: GraphQL items lookup query failed" >&2
          exit 1
        fi

        if [ "$is_mutation" = true ]; then
          # iteration_mutation_fail: simulate iteration assignment mutation failure (#669 F-02)
          if [ "$SCENARIO" = "iteration_mutation_fail" ]; then
            echo "error: iteration mutation failed" >&2
            exit 1
          fi
          # No stdout output for mutations (only exit code matters to caller)
          exit 0
        fi

        # --- projects-status-update.sh path ---
        if [ "$is_repository_query" = true ]; then
          # Determine scenario-dependent response shape.
          case "$SCENARIO" in
            psu_graphql_fail)
              echo "error: GraphQL projectItems query failed" >&2
              exit 1
              ;;
            psu_issue_not_found)
              printf '{"data":{"repository":{"issue":null}}}\n'
              exit 0
              ;;
            psu_issue_url_null)
              # projectItems empty AND url is null → auto_add branch cannot proceed
              printf '{"data":{"repository":{"issue":{"url":null,"projectItems":{"nodes":[]}}}}}\n'
              exit 0
              ;;
            psu_not_in_project|psu_auto_add_requery_empty|psu_auto_add_fail)
              # All scenarios where the initial query returns no project items.
              # - psu_not_in_project: auto_add=false, script stops
              # - psu_auto_add_fail: auto_add=true, script tries item-add which then fails
              # - psu_auto_add_requery_empty: auto_add=true, item-add succeeds, re-query empty
              printf '{"data":{"repository":{"issue":{"url":"https://github.com/test-owner/test-repo/issues/%s","projectItems":{"nodes":[]}}}}}\n' "$MOCK_ISSUE_NUMBER"
              exit 0
              ;;
            psu_auto_add_then_ok)
              # State machine: first call returns empty, subsequent calls return item.
              # Use a fixed-name file in MOCK_GH_STATE_DIR (do NOT include $$ —
              # mock-gh.sh's own PID differs between the two gh invocations).
              state_dir="${MOCK_GH_STATE_DIR:-/tmp}"
              state_file="$state_dir/psu_autoadd_count"
              if [ -f "$state_file" ]; then
                printf '{"data":{"repository":{"issue":{"url":"https://github.com/test-owner/test-repo/issues/%s","projectItems":{"nodes":[{"id":"%s","project":{"id":"%s","number":6}}]}}}}}\n' "$MOCK_ISSUE_NUMBER" "$MOCK_ITEM_ID" "$MOCK_PROJECT_ID"
              else
                echo "1" > "$state_file"
                printf '{"data":{"repository":{"issue":{"url":"https://github.com/test-owner/test-repo/issues/%s","projectItems":{"nodes":[]}}}}}\n' "$MOCK_ISSUE_NUMBER"
              fi
              exit 0
              ;;
            psu_success|psu_field_list_fail|psu_no_status_field|psu_no_status_option|psu_item_edit_fail)
              printf '{"data":{"repository":{"issue":{"url":"https://github.com/test-owner/test-repo/issues/%s","projectItems":{"nodes":[{"id":"%s","project":{"id":"%s","number":6}}]}}}}}\n' "$MOCK_ISSUE_NUMBER" "$MOCK_ITEM_ID" "$MOCK_PROJECT_ID"
              exit 0
              ;;
            *)
              printf '{"data":{"repository":{"issue":{"url":"https://github.com/test-owner/test-repo/issues/%s","projectItems":{"nodes":[{"id":"%s","project":{"id":"%s","number":6}}]}}}}}\n' "$MOCK_ISSUE_NUMBER" "$MOCK_ITEM_ID" "$MOCK_PROJECT_ID"
              exit 0
              ;;
          esac
        fi

        # Determine GQL root based on owner type
        GQL_ROOT="user"
        if [ "$SCENARIO" = "org_owner" ]; then
          GQL_ROOT="organization"
        fi

        ITEMS_NODES="[{\"id\":\"${MOCK_ITEM_ID}\",\"content\":{\"number\":${MOCK_ISSUE_NUMBER}}}]"
        if [ "$SCENARIO" = "no_item_id" ] || [ "$SCENARIO" = "no_item_id_no_json" ] || [ "$SCENARIO" = "gql_items_lookup_fail" ]; then
          ITEMS_NODES="[]"
        fi

        PROJECT_ID_VALUE="\"${MOCK_PROJECT_ID}\""
        if [ "$SCENARIO" = "no_project_id" ]; then
          PROJECT_ID_VALUE="null"
        fi

        # Iteration field (conditionally included based on scenario)
        ITER_FIELD=""
        MOCK_CURRENT_SPRINT_START=$(date +%Y-%m-01)
        if [ "$SCENARIO" = "iteration_success" ] || [ "$SCENARIO" = "iteration_mutation_fail" ]; then
          # iteration_mutation_fail も fields query では Sprint field + current iteration を返し、
          # mutation 段階で初めて失敗させる (#669 F-02)
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
