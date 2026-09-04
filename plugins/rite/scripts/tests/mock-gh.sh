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
#                              but the iteration assignment mutation fails
#   "gql_items_lookup_fail"  - GraphQL fields query OK (items.nodes=[]),
#                              but the GQL_ITEMS_QUERY (items lookup retry) fails
#   "jp_field_names"         - Project fields use Japanese names (ステータス/優先度/複雑度);
#                              resolved by the helper's built-in aliases (zero config)
#   "custom_field_name"      - Priority field named "重要度" (matches an input
#                              field_names.priority override, not the 優先度 alias)
#   "missing_priority_field" - Project has no Priority field under any candidate name
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
#   "psu_current_cancelled"    - item Status is Cancelled
#   "psu_current_done"         - item Status is Done
#   "psu_fieldvalues_missing"  - item has no fieldValues key (unreadable)
#   "psu_fieldvalues_null"     - item has fieldValues: null (unreadable)
#   "psu_graphql_errors"       - HTTP 200 + data + errors[] (unreadable; no write)
#   "psu_fieldvalues_empty"    - fieldValues.nodes is empty (unset)
#   "psu_fieldvalues_nostatus" - fieldValues has no Status entry (unset)
#
# Scenarios (projects-items-fetch.sh):
#   "pif_success"              - project view + 1-page items query succeed
#   "pif_multi_page"           - 2-page pagination (state file in MOCK_GH_STATE_DIR)
#   "pif_project_view_fail"    - gh project view fails (stderr + exit 1)
#   "pif_view_null_id"         - project view succeeds but id is null
#   "pif_graphql_fail"         - items query fails (stderr + exit 1)
#   "pif_graphql_errors"       - items query returns top-level errors array
#   "pif_missing_items"        - items query returns data.node = null (partial response)
#   "pif_normalize_fail"       - gh succeeds (default shapes); the failure is injected by the
#                                jq shim in projects-items-fetch.test.sh (final `jq -s` exits 2)
#
# Both create-issue-with-projects.sh and projects-status-update.sh root their
# GraphQL queries at `repository(owner:, name:)`, but with different sub-shapes:
# create uses `repository.projectV2(number:)` (-> `data.repository.projectV2`)
# while status-update uses `repository.issue(number:).projectItems`. This mock
# discriminates them via the `projectV2(number:` token and branches accordingly.
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
      view)
        # `gh project view PROJECT_NUMBER --owner OWNER --format json`
        # Used by projects-items-fetch.sh to resolve the ProjectV2 node ID.
        if [ "$SCENARIO" = "pif_project_view_fail" ]; then
          echo "error: could not view project" >&2
          exit 1
        fi
        if [ "$SCENARIO" = "pif_view_null_id" ]; then
          printf '{"id": null, "title": "Mock Project"}\n'
          exit 0
        fi
        printf '{"id": "%s", "title": "Mock Project"}\n' "$MOCK_PROJECT_ID"
        ;;
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
      {"id": "OPT_DONE", "name": "Done"},
      {"id": "OPT_CANCELLED", "name": "Cancelled"}
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
        # Real `gh repo view --json owner` returns the owner object as {id, login}
        # only — there is NO __typename discriminator. The mock mirrors that exact
        # shape (regression guard for the old owner-type bug, AC-3). The org_owner
        # scenario no longer branches here; owner type is irrelevant to the new
        # owner-type-independent repository(owner,name) path.
        json_data="{\"owner\":{\"id\":\"O_kgM0test\",\"login\":\"test-owner\"}}"
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

        # Detect query shape: both scripts query `repository(owner:`, so discriminate
        # by sub-shape — create-issue-with-projects.sh uses `projectV2(number:` while
        # projects-status-update.sh uses `issue(...).projectItems`.
        # gql_items_lookup_fail: fields query (containing
        # `fields(first: 20)`) succeeds with empty items, but the items lookup
        # retry query (containing `items(last: 20)` and NOT `fields(first: 20)`)
        # fails with exit 1.
        is_repository_query=false
        is_projectv2_query=false
        is_mutation=false
        is_items_lookup_only=false
        is_items_pagination_query=false
        has_cursor_arg=false
        for arg in "$@"; do
          if [[ "$arg" == query=* ]]; then
            if [[ "$arg" == *"repository(owner:"* ]]; then
              is_repository_query=true
            fi
            # create-issue-with-projects.sh roots its project queries at
            # repository(owner,name).projectV2(number:...); projects-status-update.sh
            # instead queries repository(...).issue(...).projectItems. The projectV2
            # token discriminates the two repository-rooted shapes so the create path
            # is not misrouted to the projectItems (psu) branch below.
            if [[ "$arg" == *"projectV2(number:"* ]]; then
              is_projectv2_query=true
            fi
            if [[ "$arg" == *mutation* ]]; then
              is_mutation=true
            fi
            if [[ "$arg" == *"items(last: 20)"* ]] && [[ "$arg" != *"fields(first: 20)"* ]]; then
              is_items_lookup_only=true
            fi
            # projects-items-fetch.sh queries `node(id: $pid)` + `items(first: 100, after: $cursor)`
            if [[ "$arg" == *"items(first: 100, after:"* ]]; then
              is_items_pagination_query=true
            fi
          fi
          if [[ "$arg" == cursor=* ]]; then
            has_cursor_arg=true
          fi
        done

        if [ "$SCENARIO" = "gql_items_lookup_fail" ] && [ "$is_items_lookup_only" = true ]; then
          echo "error: GraphQL items lookup query failed" >&2
          exit 1
        fi

        # --- projects-items-fetch.sh path (node(id:) + items(first: 100) pagination) ---
        if [ "$is_items_pagination_query" = true ]; then
          case "$SCENARIO" in
            pif_graphql_fail)
              echo "error: GraphQL items query failed" >&2
              exit 1
              ;;
            pif_graphql_errors)
              printf '{"errors":[{"message":"Something went wrong"},{"message":"Rate limited"}],"data":null}\n'
              exit 0
              ;;
            pif_missing_items)
              printf '{"data":{"node":null}}\n'
              exit 0
              ;;
            pif_multi_page)
              # Page 1 (no cursor arg): hasNextPage=true + item.
              # Page 2 (cursor arg present): hasNextPage=false + item.
              if [ "$has_cursor_arg" = true ]; then
                printf '{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"content":{"number":102},"fieldValues":{"nodes":[{"name":"Done","field":{"name":"Status"}}]}}]}}}}\n'
              else
                printf '{"data":{"node":{"items":{"pageInfo":{"hasNextPage":true,"endCursor":"CURSOR1"},"nodes":[{"content":{"number":101},"fieldValues":{"nodes":[{"name":"Todo","field":{"name":"Status"}}]}}]}}}}\n'
              fi
              exit 0
              ;;
            *)
              # pif_success (default): single page with a Status item, a status-less
              # item, and a draft item (content {}) that the normalizer must exclude.
              printf '{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"content":{"number":101},"fieldValues":{"nodes":[{"name":"In Progress","field":{"name":"Status"}},{}]}},{"content":{"number":102},"fieldValues":{"nodes":[{}]}},{"content":{},"fieldValues":{"nodes":[]}}]}}}}\n'
              exit 0
              ;;
          esac
        fi

        if [ "$is_mutation" = true ]; then
          # iteration_mutation_fail: simulate iteration assignment mutation failure
          if [ "$SCENARIO" = "iteration_mutation_fail" ]; then
            echo "error: iteration mutation failed" >&2
            exit 1
          fi
          # No stdout output for mutations (only exit code matters to caller)
          exit 0
        fi

        # --- create-issue-with-projects.sh path (repository.projectV2 shape) ---
        # Owner-type-independent: the SAME response is returned whether the owner is
        # a User or an Organization (the org_owner scenario now succeeds, AC-4). Must
        # be checked before the projectItems (psu) branch since both are rooted at
        # repository(owner:...).
        if [ "$is_projectv2_query" = true ]; then
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

          # Field names default to canonical English. Localized / custom / missing-field
          # scenarios override them so the helper's alias + input-override
          # resolution is exercised. Option *values* stay English (option localization
          # is out of scope for).
          STATUS_FIELD_NAME="Status"
          PRIORITY_FIELD_NAME="Priority"
          COMPLEXITY_FIELD_NAME="Complexity"
          INCLUDE_PRIORITY_FIELD=true
          case "$SCENARIO" in
            jp_field_names)
              # Project uses Japanese field names → resolved by the built-in aliases (zero config).
              STATUS_FIELD_NAME="ステータス"
              PRIORITY_FIELD_NAME="優先度"
              COMPLEXITY_FIELD_NAME="複雑度"
              ;;
            custom_field_name)
              # Priority field is named "重要度" — matches an input field_names.priority
              # override but NOT the built-in 優先度 alias (exercises override > alias).
              PRIORITY_FIELD_NAME="重要度"
              ;;
            missing_priority_field)
              # No Priority field under any candidate name (Priority / 優先度 / override).
              INCLUDE_PRIORITY_FIELD=false
              ;;
          esac

          PRIORITY_FIELD_NODE=""
          if [ "$INCLUDE_PRIORITY_FIELD" = true ]; then
            PRIORITY_FIELD_NODE=',
            {
              "id": "FIELD_PRIORITY",
              "name": "'"$PRIORITY_FIELD_NAME"'",
              "options": [
                {"id": "OPT_HIGH", "name": "High"},
                {"id": "OPT_MEDIUM", "name": "Medium"},
                {"id": "OPT_LOW", "name": "Low"}
              ]
            }'
          fi

          cat <<EOJSON
{
  "data": {
    "repository": {
      "projectV2": {
        "id": ${PROJECT_ID_VALUE},
        "items": {
          "nodes": ${ITEMS_NODES}
        },
        "fields": {
          "nodes": [
            {
              "id": "FIELD_STATUS",
              "name": "${STATUS_FIELD_NAME}",
              "options": [
                {"id": "OPT_TODO", "name": "Todo"},
                {"id": "OPT_INPROGRESS", "name": "In Progress"},
                {"id": "OPT_DONE", "name": "Done"}
              ]
            }${PRIORITY_FIELD_NODE},
            {
              "id": "FIELD_COMPLEXITY",
              "name": "${COMPLEXITY_FIELD_NAME}",
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
          exit 0
        fi

        # --- projects-status-update.sh path ---
        if [ "$is_repository_query" = true ]; then
          # $1 = Status name, or missing / empty / nostatus for unreadable / unset.
          _psu_node() {
            local kind="${1:-Todo}"
            case "$kind" in
              missing)
                printf '{"id":"%s","project":{"id":"%s","number":6}}' "$MOCK_ITEM_ID" "$MOCK_PROJECT_ID"
                ;;
              null)
                printf '{"id":"%s","project":{"id":"%s","number":6},"fieldValues":null}' "$MOCK_ITEM_ID" "$MOCK_PROJECT_ID"
                ;;
              empty)
                printf '{"id":"%s","project":{"id":"%s","number":6},"fieldValues":{"nodes":[]}}' "$MOCK_ITEM_ID" "$MOCK_PROJECT_ID"
                ;;
              nostatus)
                printf '{"id":"%s","project":{"id":"%s","number":6},"fieldValues":{"nodes":[{"name":"High","field":{"name":"Priority"}}]}}' "$MOCK_ITEM_ID" "$MOCK_PROJECT_ID"
                ;;
              *)
                printf '{"id":"%s","project":{"id":"%s","number":6},"fieldValues":{"nodes":[{"name":"%s","field":{"name":"Status"}}]}}' "$MOCK_ITEM_ID" "$MOCK_PROJECT_ID" "$kind"
                ;;
            esac
          }
          _psu_issue() {
            printf '{"data":{"repository":{"issue":{"url":"https://github.com/test-owner/test-repo/issues/%s","projectItems":{"nodes":[%s]}}}}}\n' "$MOCK_ISSUE_NUMBER" "$1"
          }

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
              # Second response must include non-terminal fieldValues or the
              # unreadable-current-Status path fails TC-005.
              state_dir="${MOCK_GH_STATE_DIR:-/tmp}"
              state_file="$state_dir/psu_autoadd_count"
              if [ -f "$state_file" ]; then
                _psu_issue "$(_psu_node Todo)"
              else
                echo "1" > "$state_file"
                printf '{"data":{"repository":{"issue":{"url":"https://github.com/test-owner/test-repo/issues/%s","projectItems":{"nodes":[]}}}}}\n' "$MOCK_ISSUE_NUMBER"
              fi
              exit 0
              ;;
            psu_current_cancelled)
              _psu_issue "$(_psu_node Cancelled)"
              exit 0
              ;;
            psu_current_done)
              _psu_issue "$(_psu_node Done)"
              exit 0
              ;;
            psu_fieldvalues_missing)
              _psu_issue "$(_psu_node missing)"
              exit 0
              ;;
            psu_fieldvalues_null)
              _psu_issue "$(_psu_node null)"
              exit 0
              ;;
            psu_graphql_errors)
              # HTTP 200 + data (Cancelled item) + errors[]. gh exits 0; helper must not write.
              printf '{"data":{"repository":{"issue":{"url":"https://github.com/test-owner/test-repo/issues/%s","projectItems":{"nodes":[%s]}}}},"errors":[{"message":"Field values unavailable"}]}\n' \
                "$MOCK_ISSUE_NUMBER" "$(_psu_node Cancelled)"
              exit 0
              ;;
            psu_fieldvalues_empty)
              _psu_issue "$(_psu_node empty)"
              exit 0
              ;;
            psu_fieldvalues_nostatus)
              _psu_issue "$(_psu_node nostatus)"
              exit 0
              ;;
            psu_success|psu_field_list_fail|psu_no_status_field|psu_no_status_option|psu_item_edit_fail)
              _psu_issue "$(_psu_node Todo)"
              exit 0
              ;;
            *)
              _psu_issue "$(_psu_node Todo)"
              exit 0
              ;;
          esac
        fi

        # Unrecognized GraphQL query shape: return empty (no create/psu/pif/mutation
        # token matched). Real callers always match one of the branches above.
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
