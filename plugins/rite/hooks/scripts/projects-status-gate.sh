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
#   bash projects-status-gate.sh --issue N [--expect STATUS] [--quiet]
#
# Options:
#   --issue N        Issue number to verify (required)
#   --expect STATUS  Minimum expected board Status (default: "In Progress")
#   --quiet          Suppress stderr WARNING lines (marker is still emitted)
#   -h, --help       Show usage
#
# Output (stdout): a single marker line
#   [CONTEXT] PROJECTS_STATUS_INVARIANT=ok|missing|skipped|unknown; issue=N; status=...; expected=...
#
#   ok       board Status has reached (or passed) the expected status
#   missing  the transition did not land — the Issue is on the board below the expected
#            status, its Status field carries no value, or it is not on the board at all.
#            All three mean the same thing at this call site: 2.4(A) passes auto_add, so a
#            successful run always leaves an item on the board. Absence is evidence that
#            2.4(A) never ran or failed, not that there is nothing to check. (The
#            on-board-is-not-a-drift policy of projects-board-drift-check.sh does not carry
#            over: that check runs with auto_add off, where an absent item is legitimate.)
#   skipped  nothing to verify — the project itself is out of the picture (Projects
#            disabled / project_number unset / rite-config.yml absent)
#   unknown  the verification itself could not run (gh / jq failure, or a response whose
#            issue node is null — an Issue number or owner/repo that does not resolve);
#            a WARNING carrying the root cause goes to stderr. Never reported as ok.
#
#   The `status=` field carries the board's own Status name; one of the three sentinels the
#   jq program emits when there is no name to report (`<not-on-board>` and `<no-status>`
#   route to `missing`, `<no-issue>` to `unknown` — see the jq program for what each means);
#   or the empty string, on the paths that end before the board is ever read.
#
# Exit code: always 0 (verdict travels in the marker, not the exit status)
set -euo pipefail

ISSUE=""
EXPECT="In Progress"
QUIET=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../control-char-neutralize.sh
source "$SCRIPT_DIR/../control-char-neutralize.sh"

# Defined before the argument loop so that every marker in this file — including the ones
# the loop's own error arms emit — goes out through the same neutralized path. A raw echo
# there would let a newline inside an argument forge a second marker line.
emit() {
  # $1=verdict $2=observed status
  printf '[CONTEXT] PROJECTS_STATUS_INVARIANT=%s; issue=%s; status=%s; expected=%s\n' \
    "$1" "$(printf '%s' "$ISSUE" | neutralize_ctrl)" \
    "$(printf '%s' "$2" | neutralize_ctrl)" \
    "$(printf '%s' "$EXPECT" | neutralize_ctrl)"
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --issue)
      if [ "$#" -lt 2 ]; then
        echo "ERROR: --issue requires a value" >&2
        emit unknown ""
      fi
      ISSUE="$2"; shift 2 ;;
    --expect)
      if [ "$#" -lt 2 ]; then
        echo "ERROR: --expect requires a value" >&2
        # EXPECT still holds the default here, and the marker reports it — the run was
        # about to verify against that value, so blanking the field would misreport it.
        emit unknown ""
      fi
      EXPECT="$2"; shift 2 ;;
    --quiet) QUIET=true; shift ;;
    -h|--help)
      cat <<'USAGE_EOF'
projects-status-gate.sh - Projects Status Gate

Reads an Issue's actual GitHub Projects board Status and reports whether it has reached
the expected status. Used by /rite:open ステップ 2.6 to verify that ステップ 2.4(A)
(Status -> In Progress) actually landed.

Usage:
  bash projects-status-gate.sh --issue N [--expect STATUS] [--quiet]

Options:
  --issue N        Issue number to verify (required)
  --expect STATUS  Minimum expected board Status (default: "In Progress")
  --quiet          Suppress stderr WARNING lines (marker is still emitted)
  -h, --help       Show usage

Emits one marker line on stdout and always exits 0:
  [CONTEXT] PROJECTS_STATUS_INVARIANT=ok|missing|skipped|unknown; issue=N; status=...; expected=...
USAGE_EOF
      exit 0 ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      emit unknown "" ;;
  esac
done

warn() {
  [ "$QUIET" = "true" ] && return 0
  echo "WARNING: projects-status-gate: $1" >&2
  return 0
}

if ! [[ "$ISSUE" =~ ^[0-9]+$ ]]; then
  warn "--issue must be a positive integer (got: '$(printf '%s' "$ISSUE" | neutralize_ctrl)')"
  emit unknown ""
fi

# --- Locate rite-config.yml (walk upward, same idiom as projects-board-drift-check.sh) ---
CWD="$(pwd)"
REPO_ROOT="$CWD"
while [ "$REPO_ROOT" != "/" ] && [ ! -f "$REPO_ROOT/rite-config.yml" ] && [ ! -d "$REPO_ROOT/.git" ]; do
  REPO_ROOT="$(dirname "$REPO_ROOT")"
done

if [ ! -f "$REPO_ROOT/rite-config.yml" ]; then
  warn "rite-config.yml not found from $CWD upward — nothing to verify"
  emit skipped ""
fi

PROJECTS_ENABLED=$(awk '/^github:/{h=1;next} h && /^  projects:/{p=1;next} p && /^    enabled:/{print $2; exit}' "$REPO_ROOT/rite-config.yml" 2>/dev/null) || PROJECTS_ENABLED=""
PROJECT_NUMBER=$(awk '/^github:/{h=1;next} h && /^  projects:/{p=1;next} p && /^    project_number:/{print $2; exit}' "$REPO_ROOT/rite-config.yml" 2>/dev/null) || PROJECT_NUMBER=""

if [ "$PROJECTS_ENABLED" != "true" ] || ! [[ "$PROJECT_NUMBER" =~ ^[0-9]+$ ]]; then
  emit skipped ""
fi

# --- Tempfile lifecycle: owned by lib/tempfile.sh (creation, cleanup registration, signals) ---
# shellcheck source=lib/tempfile.sh
source "$SCRIPT_DIR/lib/tempfile.sh"
rite_tempfile_init

# --- Repo info: git-remote parse first (SSH Host alias origin), gh repo view as fallback ---
REPO_OWNER=""
REPO_NAME=""
rite_tempfile_new git_remote_err "status-gate-git-remote-err" || emit unknown ""
_git_or_line=$(bash "$SCRIPT_DIR/lib/git-remote.sh" resolve-owner-repo 2>"$git_remote_err") || _git_or_line=""
if [ -n "$_git_or_line" ]; then
  IFS=$'\t' read -r REPO_OWNER REPO_NAME <<< "$_git_or_line"
fi
if [ -z "$REPO_OWNER" ] || [ -z "$REPO_NAME" ]; then
  rite_tempfile_new repo_view_err "status-gate-repo-err" || emit unknown ""
  if ! REPO_INFO=$(gh repo view --json owner,name 2>"$repo_view_err"); then
    warn "gh repo view failed; cannot verify board Status"
    if [ "$QUIET" != "true" ] && [ -s "$repo_view_err" ]; then
      head -3 "$repo_view_err" | neutralize_ctrl --keep-newline | sed 's/^/  gh: /' >&2
    fi
    if [ "$QUIET" != "true" ] && [ -s "$git_remote_err" ]; then
      head -3 "$git_remote_err" | neutralize_ctrl --keep-newline | sed 's/^/  git-remote: /' >&2
    fi
    emit unknown ""
  fi
  REPO_OWNER=$(printf '%s' "$REPO_INFO" | jq -r '.owner.login // empty' 2>/dev/null) || REPO_OWNER=""
  REPO_NAME=$(printf '%s' "$REPO_INFO" | jq -r '.name // empty' 2>/dev/null) || REPO_NAME=""
  if [ -z "$REPO_OWNER" ] || [ -z "$REPO_NAME" ]; then
    warn "failed to parse owner/name from gh repo view"
    emit unknown ""
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
rite_tempfile_new gql_err "status-gate-gql-err" || emit unknown ""
rite_tempfile_new jq_err "status-gate-jq-err" || emit unknown ""
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
  | jq -r --argjson pn "$PROJECT_NUMBER" '
      if (.data.repository.issue // null) == null then "<no-issue>"
      else
        (([.data.repository.issue.projectItems.nodes[]? | select(.project.number == $pn)][0]) // null) as $pitem
        | if $pitem == null then "<not-on-board>"
          else (([$pitem.fieldValues.nodes[] | select(.field.name == "Status") | .name][0]) // "<no-status>")
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
  emit unknown ""
fi

# An empty capture means the pipeline produced nothing at all — a malformed response the
# jq program could not classify. That is a failed verification, not a clean board.
if [ -z "$CURRENT" ]; then
  warn "empty board Status response for Issue #$ISSUE (malformed API response)"
  emit unknown ""
fi

# A response with no issue node means the query did not reach the Issue it was asked
# about — the verification never happened, so it must not be reported as a board verdict.
if [ "$CURRENT" = "<no-issue>" ]; then
  warn "Issue #$ISSUE did not resolve in $REPO_OWNER/$REPO_NAME (no issue node in the response) — cannot verify board Status"
  emit unknown "$CURRENT"
fi

# Absence from the board is a missed transition here, not "nothing to verify": the caller
# (2.4(A)) passes auto_add, so a successful run always leaves an item behind. Falling
# through to `skipped` would hand a clean bill to the one state this gate exists to catch.
if [ "$CURRENT" = "<not-on-board>" ]; then
  warn "Issue #$ISSUE is not on project $PROJECT_NUMBER — 2.4(A) adds the item itself, so its absence means the step did not land"
  emit missing "$CURRENT"
fi

# --- Compare against the expected status ---
# The board's Status options are ordered stages, and the gate asks "has the Issue reached
# this stage", not "is it exactly here". A re-entry through /rite:recover after ready or
# cleanup legitimately observes In Review / Done, and reporting those as a missed
# In Progress transition would make the gate cry wolf on every resume. An unknown option
# name (a localized or customized board) has no rank and is compared by equality only.
status_rank() {
  case "$1" in
    Todo) echo 1 ;;
    "In Progress") echo 2 ;;
    "In Review") echo 3 ;;
    Done) echo 4 ;;
    *) echo 0 ;;
  esac
}
cur_rank=$(status_rank "$CURRENT")
exp_rank=$(status_rank "$EXPECT")

if [ "$CURRENT" = "$EXPECT" ]; then
  emit ok "$CURRENT"
fi
if [ "$cur_rank" -gt 0 ] && [ "$exp_rank" -gt 0 ] && [ "$cur_rank" -ge "$exp_rank" ]; then
  emit ok "$CURRENT"
fi

warn "Issue #$ISSUE board Status is \"$(printf '%s' "$CURRENT" | neutralize_ctrl)\" but \"$(printf '%s' "$EXPECT" | neutralize_ctrl)\" was expected — the Status transition did not land"
emit missing "$CURRENT"
