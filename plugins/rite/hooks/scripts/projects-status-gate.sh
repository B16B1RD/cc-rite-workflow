#!/bin/bash
# rite workflow - Projects Status Gate
#
# Verification gate for the "/rite:open ステップ 2.4(A) が実行されないまま先へ進む" gap.
# 2.4(A) drives the board to "In Progress" through projects-status-update.sh, but every
# result branch there is non-blocking, so both a skipped step and a failed helper leave
# the same silence behind. This script is the post-condition: it reads the Issue's ACTUAL
# board Status and reports whether the transition landed.
#
# Reading the live board rather than a marker the caller emitted is deliberate. A marker
# check only proves that something claimed success; the board query also catches the
# helper reporting "updated" without effect, and it cannot be satisfied by a stale value
# carried forward from an earlier run (the reason a flow-state field would not work here —
# flow-state merge-preserves its scalars, so a recorded result stays true forever).
#
# The caller decides what to do with the verdict. This script never blocks: the
# non-blocking contract of 2.4(A) is a MUST NOT for the Issue that introduced this gate,
# so the exit code is 0 on every path and the verdict travels in the marker.
#
# Usage:
#   bash projects-status-gate.sh --issue N [--expect ROLE] [--quiet]
#
# Options:
#   --issue N        Issue number to verify (required)
#   --expect ROLE    Minimum expected Status role: todo / in_progress / in_review / done
#                    (default: in_progress). The board's display name for each role comes
#                    from rite-config.yml (github.projects.fields.status.options), so the
#                    caller never names a column.
#   --quiet          Suppress stderr WARNING lines (marker is still emitted)
#   -h, --help       Show usage
#
# Output (stdout): a single marker line
#   [CONTEXT] PROJECTS_STATUS_INVARIANT=ok|missing|skipped|unknown; issue=N; role=...; status=...; expected=...
#
#   ok       board Status has reached (or passed) the expected role
#   missing  the transition did not land — the Issue is on the board below the expected
#            role, its Status field carries no value, or it is not on the board at all.
#            A column that maps to no role (one the user added themselves, or a board
#            the config does not describe) lands here too, with a WARNING naming the
#            column: the expected role has not been reached, and the gate does not guess
#            what an unmapped column means. A board sitting on the terminal role
#            `cancelled` also lands here (the expected role will never be reached), but
#            carries its own diagnostic naming the abandonment instead of a dropped
#            transition.
#            All of these mean the same thing at this call site: 2.4(A) passes auto_add, so
#            a successful run always leaves an item on the board. Absence is evidence that
#            2.4(A) never ran or failed, not that there is nothing to check. (The
#            on-board-is-not-a-drift policy of projects-board-drift-check.sh does not carry
#            over: that check runs with auto_add off, where an absent item is legitimate.)
#   skipped  nothing to verify — the project itself is out of the picture (Projects
#            disabled / project_number unset / rite-config.yml absent)
#   unknown  the verification itself could not run (gh / jq failure, an invalid Status
#            configuration, an --expect value that is not a role, or a response whose
#            issue node is null — an Issue number or owner/repo that does not resolve);
#            a WARNING carrying the root cause goes to stderr. Never reported as ok.
#
#   The `role=` field carries the role the board's Status name resolved to, or the empty
#   string when the name maps to no role or there is no name. The `status=` field carries
#   the board's own Status name; one of the three sentinels the jq program emits when there
#   is no name to report (`<not-on-board>` and `<no-status>` route to `missing`,
#   `<no-issue>` to `unknown` — see the jq program for what each means); or the empty
#   string, on the paths that end without a Status name to report.
#
# Exit code: always 0 (verdict travels in the marker, not the exit status)
set -euo pipefail

ISSUE=""
EXPECT="in_progress"
QUIET=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../control-char-neutralize.sh
source "$SCRIPT_DIR/../control-char-neutralize.sh"
# shellcheck source=lib/projects-status-config.sh
source "$SCRIPT_DIR/lib/projects-status-config.sh"

# Defined before the argument loop so that every marker in this file — including the ones
# the loop's own error arms emit — goes out through the same neutralized path. A raw echo
# there would let a newline inside an argument forge a second marker line.
emit() {
  # $1=verdict $2=resolved role (or empty) $3=observed status
  printf '[CONTEXT] PROJECTS_STATUS_INVARIANT=%s; issue=%s; role=%s; status=%s; expected=%s\n' \
    "$1" "$(printf '%s' "$ISSUE" | neutralize_ctrl)" \
    "$(printf '%s' "$2" | neutralize_ctrl)" \
    "$(printf '%s' "$3" | neutralize_ctrl)" \
    "$(printf '%s' "$EXPECT" | neutralize_ctrl)"
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --issue)
      if [ "$#" -lt 2 ]; then
        echo "ERROR: --issue requires a value" >&2
        emit unknown "" ""
      fi
      ISSUE="$2"; shift 2 ;;
    --expect)
      if [ "$#" -lt 2 ]; then
        echo "ERROR: --expect requires a value" >&2
        # EXPECT still holds the default here, and the marker reports it — the run was
        # about to verify against that value, so blanking the field would misreport it.
        emit unknown "" ""
      fi
      EXPECT="$2"; shift 2 ;;
    --quiet) QUIET=true; shift ;;
    -h|--help)
      cat <<'USAGE_EOF'
projects-status-gate.sh - Projects Status Gate

Reads an Issue's actual GitHub Projects board Status, maps the column name to its rite
role through rite-config.yml, and reports whether it has reached the expected role. Used
by /rite:open ステップ 2.6 to verify that ステップ 2.4(A) (Status -> in_progress) landed.

Usage:
  bash projects-status-gate.sh --issue N [--expect ROLE] [--quiet]

Options:
  --issue N        Issue number to verify (required)
  --expect ROLE    Minimum expected Status role: todo / in_progress / in_review / done
                   (default: in_progress)
  --quiet          Suppress stderr WARNING lines (marker is still emitted)
  -h, --help       Show usage

Emits one marker line on stdout and always exits 0:
  [CONTEXT] PROJECTS_STATUS_INVARIANT=ok|missing|skipped|unknown; issue=N; role=...; status=...; expected=...
USAGE_EOF
      exit 0 ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      emit unknown "" "" ;;
  esac
done

warn() {
  [ "$QUIET" = "true" ] && return 0
  echo "WARNING: projects-status-gate: $1" >&2
  return 0
}

if ! [[ "$ISSUE" =~ ^[0-9]+$ ]]; then
  warn "--issue must be a positive integer (got: '$(printf '%s' "$ISSUE" | neutralize_ctrl)')"
  emit unknown "" ""
fi

# The expected value is a role, never a column name. A value outside the ranked roles
# has no rank to compare against, and projects_status_rank() answers 0 for it — the same
# answer it gives an unmapped column — so letting it through would turn every board into
# `missing`. cancelled is refused too: it is terminal, not a stage to reach.
case "$EXPECT" in
  todo|in_progress|in_review|done) ;;
  *)
    warn "--expect must be one of todo / in_progress / in_review / done (got: '$(printf '%s' "$EXPECT" | neutralize_ctrl)')"
    emit unknown "" "" ;;
esac

# --- Locate rite-config.yml (walk upward, same idiom as projects-board-drift-check.sh) ---
CWD="$(pwd)"
REPO_ROOT="$CWD"
while [ "$REPO_ROOT" != "/" ] && [ ! -f "$REPO_ROOT/rite-config.yml" ] && [ ! -d "$REPO_ROOT/.git" ]; do
  REPO_ROOT="$(dirname "$REPO_ROOT")"
done

if [ ! -f "$REPO_ROOT/rite-config.yml" ]; then
  warn "rite-config.yml not found from $CWD upward — nothing to verify"
  emit skipped "" ""
fi

PROJECTS_ENABLED=$(awk '/^github:/{h=1;next} h && /^  projects:/{p=1;next} p && /^    enabled:/{print $2; exit}' "$REPO_ROOT/rite-config.yml" 2>/dev/null) || PROJECTS_ENABLED=""
PROJECT_NUMBER=$(awk '/^github:/{h=1;next} h && /^  projects:/{p=1;next} p && /^    project_number:/{print $2; exit}' "$REPO_ROOT/rite-config.yml" 2>/dev/null) || PROJECT_NUMBER=""

if [ "$PROJECTS_ENABLED" != "true" ] || ! [[ "$PROJECT_NUMBER" =~ ^[0-9]+$ ]]; then
  emit skipped "" ""
fi

# --- Tempfile lifecycle: owned by lib/tempfile.sh (creation, cleanup registration, signals) ---
# shellcheck source=lib/tempfile.sh
source "$SCRIPT_DIR/lib/tempfile.sh"
rite_tempfile_init

# --- Status role configuration ---
# The resolver reads rite-config.yml from the git toplevel (or cwd); run it from REPO_ROOT
# so it reads the same file the projects-enabled check above did. An invalid configuration
# is a verification failure, not a board verdict: nothing below can map a column name.
rite_tempfile_new cfg_err "status-gate-cfg-err" || emit unknown "" ""
if ! FIELD_CANDIDATES=$(cd "$REPO_ROOT" && projects_status_field_candidates 2>"$cfg_err"); then
  warn "invalid Status configuration in rite-config.yml; cannot map board columns to roles"
  if [ "$QUIET" != "true" ] && [ -s "$cfg_err" ]; then
    head -3 "$cfg_err" | neutralize_ctrl --keep-newline | sed 's/^/  config: /' >&2
  fi
  emit unknown "" ""
fi

# --- Repo info: git-remote parse first (SSH Host alias origin), gh repo view as fallback ---
REPO_OWNER=""
REPO_NAME=""
rite_tempfile_new git_remote_err "status-gate-git-remote-err" || emit unknown "" ""
_git_or_line=$(bash "$SCRIPT_DIR/lib/git-remote.sh" resolve-owner-repo 2>"$git_remote_err") || _git_or_line=""
if [ -n "$_git_or_line" ]; then
  IFS=$'\t' read -r REPO_OWNER REPO_NAME <<< "$_git_or_line"
fi
if [ -z "$REPO_OWNER" ] || [ -z "$REPO_NAME" ]; then
  rite_tempfile_new repo_view_err "status-gate-repo-err" || emit unknown "" ""
  if ! REPO_INFO=$(gh repo view --json owner,name 2>"$repo_view_err"); then
    warn "gh repo view failed; cannot verify board Status"
    if [ "$QUIET" != "true" ] && [ -s "$repo_view_err" ]; then
      head -3 "$repo_view_err" | neutralize_ctrl --keep-newline | sed 's/^/  gh: /' >&2
    fi
    if [ "$QUIET" != "true" ] && [ -s "$git_remote_err" ]; then
      head -3 "$git_remote_err" | neutralize_ctrl --keep-newline | sed 's/^/  git-remote: /' >&2
    fi
    emit unknown "" ""
  fi
  REPO_OWNER=$(printf '%s' "$REPO_INFO" | jq -r '.owner.login // empty' 2>/dev/null) || REPO_OWNER=""
  REPO_NAME=$(printf '%s' "$REPO_INFO" | jq -r '.name // empty' 2>/dev/null) || REPO_NAME=""
  if [ -z "$REPO_OWNER" ] || [ -z "$REPO_NAME" ]; then
    warn "failed to parse owner/name from gh repo view"
    emit unknown "" ""
  fi
fi

# --- Read the Issue's board Status ---
# The jq program prints a sentinel word rather than an empty string for each case that has
# no Status name to report, so the caller can tell them apart:
#   <no-issue>      the response has no issue node — an Issue number or owner/repo that
#                   does not resolve. The verification could not run, so this is `unknown`,
#                   not a verdict about the board.
#   <not-on-board>  the issue exists but has no item for the configured project
#   <no-status>     item present, Status field carries no value
rite_tempfile_new gql_err "status-gate-gql-err" || emit unknown "" ""
rite_tempfile_new jq_err "status-gate-jq-err" || emit unknown "" ""
if ! CURRENT=$(set -o pipefail; gh api graphql -f query='
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    issue(number: $number) {
      projectItems(first: 10) {
        nodes {
          project { number }
          fieldValues(first: 20) {
            nodes {
              ... on ProjectV2ItemFieldSingleSelectValue {
                field { ... on ProjectV2SingleSelectField { name } }
                name
              }
            }
          }
        }
      }
    }
  }
}' -f owner="$REPO_OWNER" -f repo="$REPO_NAME" -F number="$ISSUE" 2>"$gql_err" \
  | jq -r --argjson pn "$PROJECT_NUMBER" --arg candidates "$FIELD_CANDIDATES" '
      ($candidates | split("\n") | map(select(. != ""))) as $fields
      | if (.data.repository.issue // null) == null then "<no-issue>"
      else
        (([.data.repository.issue.projectItems.nodes[]? | select(.project.number == $pn)][0]) // null) as $pitem
        | if $pitem == null then "<not-on-board>"
          else (([$pitem.fieldValues.nodes[] | select((.field.name // "") as $fn | $fields | index($fn) != null) | .name][0]) // "<no-status>")
          end
      end
    ' 2>"$jq_err"); then
  warn "gh api graphql or jq pipeline failed while reading Issue #$ISSUE board Status"
  if [ "$QUIET" != "true" ] && [ -s "$gql_err" ]; then
    head -3 "$gql_err" | neutralize_ctrl --keep-newline | sed 's/^/  gh: /' >&2
  fi
  if [ "$QUIET" != "true" ] && [ -s "$jq_err" ]; then
    head -3 "$jq_err" | neutralize_ctrl --keep-newline | sed 's/^/  jq: /' >&2
  fi
  emit unknown "" ""
fi

# An empty capture means the pipeline produced nothing at all — a malformed response the
# jq program could not classify. That is a failed verification, not a clean board.
if [ -z "$CURRENT" ]; then
  warn "empty board Status response for Issue #$ISSUE (malformed API response)"
  emit unknown "" ""
fi

# A response with no issue node means the query did not reach the Issue it was asked
# about — the verification never happened, so it must not be reported as a board verdict.
if [ "$CURRENT" = "<no-issue>" ]; then
  warn "Issue #$ISSUE did not resolve in $REPO_OWNER/$REPO_NAME (no issue node in the response) — cannot verify board Status"
  emit unknown "" "$CURRENT"
fi

# Absence from the board is a missed transition here, not "nothing to verify": the caller
# (2.4(A)) passes auto_add, so a successful run always leaves an item behind. Falling
# through to `skipped` would hand a clean bill to the one state this gate exists to catch.
if [ "$CURRENT" = "<not-on-board>" ]; then
  warn "Issue #$ISSUE is not on project $PROJECT_NUMBER — 2.4(A) adds the item itself, so its absence means the step did not land"
  emit missing "" "$CURRENT"
fi

# An item whose Status field carries no value is the other shape of a missed transition:
# the item exists but the Status write did not land. It is routed here, before the role
# lookup, because the sentinel is not a column name — passed through the mapping it would
# be reported as an unmapped column, telling the reader to declare a role for a column
# that does not exist and, in the caller's routing, suppressing the one re-run that
# repairs this state.
if [ "$CURRENT" = "<no-status>" ]; then
  warn "Issue #$ISSUE is on project $PROJECT_NUMBER but its Status field carries no value — the Status transition did not land"
  emit missing "" "$CURRENT"
fi

# --- Map the column name to a role and compare against the expected role ---
# The board's Status columns are ordered stages, and the gate asks "has the Issue reached
# this stage", not "is it exactly here". A re-entry through /rite:recover after ready or
# cleanup legitimately observes in_review / done, and reporting those as a missed
# in_progress transition would make the gate cry wolf on every resume. The comparison is
# made on roles, never on column names: the name is whatever the user's board calls the
# stage, and rite-config.yml (github.projects.fields.status.options) is where that name is
# declared. A column the config does not map has no role and cannot be ranked — it is
# reported as missing with the column named, not guessed at.
rite_tempfile_new role_err "status-gate-role-err" || emit unknown "" "$CURRENT"
if ! CUR_ROLE=$(cd "$REPO_ROOT" && projects_status_role_for_name "$CURRENT" 2>"$role_err"); then
  warn "invalid Status configuration in rite-config.yml; cannot map board column \"$(printf '%s' "$CURRENT" | neutralize_ctrl)\" to a role"
  if [ "$QUIET" != "true" ] && [ -s "$role_err" ]; then
    head -3 "$role_err" | neutralize_ctrl --keep-newline | sed 's/^/  config: /' >&2
  fi
  emit unknown "" "$CURRENT"
fi

if [ -z "$CUR_ROLE" ]; then
  warn "Issue #$ISSUE board Status column \"$(printf '%s' "$CURRENT" | neutralize_ctrl)\" maps to no role in rite-config.yml (github.projects.fields.status.options), so \"$EXPECT\" cannot be confirmed — declare the column's role in the config, or move the Issue to a mapped column"
  emit missing "" "$CURRENT"
fi

# cancelled is terminal, not a progress stage (references/projects-integration.md,
# "Terminal Status Set"), so projects_status_rank() leaves it at 0 and the comparison
# below would report it as a dropped transition. That reading is wrong and
# sends the reader looking for a failed update: the board is where someone deliberately put
# it. Say so before the rank comparison gets a chance to phrase it as a missing transition.
# The verdict stays `missing` — the expected role genuinely has not been reached, and
# calling an abandoned Issue `ok` would smuggle back the ranking the resolver deliberately
# omits, by another door.
if [ "$CUR_ROLE" = "cancelled" ]; then
  warn "Issue #$ISSUE board Status is \"$(printf '%s' "$CURRENT" | neutralize_ctrl)\" (role cancelled) — the Issue was abandoned (closed as not planned: wontfix / superseded), so \"$EXPECT\" will not be reached. This is a cancelled Issue, not a dropped Status transition; reopen it or drop the work rather than re-running the transition"
  emit missing "$CUR_ROLE" "$CURRENT"
fi

if [ "$CUR_ROLE" = "$EXPECT" ]; then
  emit ok "$CUR_ROLE" "$CURRENT"
fi
cur_rank=$(projects_status_rank "$CUR_ROLE")
exp_rank=$(projects_status_rank "$EXPECT")
if [ "$cur_rank" -gt 0 ] && [ "$exp_rank" -gt 0 ] && [ "$cur_rank" -ge "$exp_rank" ]; then
  emit ok "$CUR_ROLE" "$CURRENT"
fi

warn "Issue #$ISSUE board Status is \"$(printf '%s' "$CURRENT" | neutralize_ctrl)\" (role $CUR_ROLE) but role \"$EXPECT\" was expected — the Status transition did not land"
emit missing "$CUR_ROLE" "$CURRENT"
