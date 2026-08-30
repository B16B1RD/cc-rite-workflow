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
#   missing  Issue is on the board but Status has not reached it — 2.4(A) did not land
#   skipped  nothing to verify (Projects disabled / project_number unset /
#            rite-config.yml absent / Issue not on the board — same on-board policy as
#            projects-board-drift-check.sh)
#   unknown  the verification itself could not run (gh / jq failure); a WARNING carrying
#            the root cause goes to stderr. Never reported as ok.
#
# Exit code: always 0 (verdict travels in the marker, not the exit status)
set -euo pipefail

ISSUE=""
EXPECT="In Progress"
QUIET=false

while [ $# -gt 0 ]; do
  case "$1" in
    --issue)
      if [ "$#" -lt 2 ]; then
        echo "ERROR: --issue requires a value" >&2
        echo "[CONTEXT] PROJECTS_STATUS_INVARIANT=unknown; issue=; status=; expected=$EXPECT"
        exit 0
      fi
      ISSUE="$2"; shift 2 ;;
    --expect)
      if [ "$#" -lt 2 ]; then
        echo "ERROR: --expect requires a value" >&2
        echo "[CONTEXT] PROJECTS_STATUS_INVARIANT=unknown; issue=$ISSUE; status=; expected="
        exit 0
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
      echo "[CONTEXT] PROJECTS_STATUS_INVARIANT=unknown; issue=$ISSUE; status=; expected=$EXPECT"
      exit 0 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../control-char-neutralize.sh
source "$SCRIPT_DIR/../control-char-neutralize.sh"

emit() {
  # $1=verdict $2=observed status
  printf '[CONTEXT] PROJECTS_STATUS_INVARIANT=%s; issue=%s; status=%s; expected=%s\n' \
    "$1" "$(printf '%s' "$ISSUE" | neutralize_ctrl)" \
    "$(printf '%s' "$2" | neutralize_ctrl)" \
    "$(printf '%s' "$EXPECT" | neutralize_ctrl)"
  exit 0
}

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

# --- Trap setup: tempfile orphan 防止 (EXIT/INT/TERM/HUP), same idiom as the sibling checks ---
repo_view_err=""
git_remote_err=""
gql_err=""
jq_err=""
_rite_status_gate_cleanup() {
  rm -f "${repo_view_err:-}" "${git_remote_err:-}" "${gql_err:-}" "${jq_err:-}"
}
trap 'rc=$?; _rite_status_gate_cleanup; exit $rc' EXIT
trap '_rite_status_gate_cleanup; exit 130' INT
trap '_rite_status_gate_cleanup; exit 143' TERM
trap '_rite_status_gate_cleanup; exit 129' HUP

# --- Repo info: git-remote parse first (SSH Host alias origin), gh repo view as fallback ---
REPO_OWNER=""
REPO_NAME=""
git_remote_err=$(mktemp "${TMPDIR:-/tmp}/rite-status-gate-git-remote-err-XXXXXX") || git_remote_err=""
_git_or_line=$(bash "$SCRIPT_DIR/lib/git-remote.sh" resolve-owner-repo 2>"${git_remote_err:-/dev/null}") || _git_or_line=""
if [ -n "$_git_or_line" ]; then
  IFS=$'\t' read -r REPO_OWNER REPO_NAME <<< "$_git_or_line"
fi
if [ -z "$REPO_OWNER" ] || [ -z "$REPO_NAME" ]; then
  repo_view_err=$(mktemp "${TMPDIR:-/tmp}/rite-status-gate-repo-err-XXXXXX") || repo_view_err=""
  if ! REPO_INFO=$(gh repo view --json owner,name 2>"${repo_view_err:-/dev/null}"); then
    warn "gh repo view failed; cannot verify board Status"
    if [ "$QUIET" != "true" ] && [ -n "$repo_view_err" ] && [ -s "$repo_view_err" ]; then
      head -3 "$repo_view_err" | neutralize_ctrl --keep-newline | sed 's/^/  gh: /' >&2
    fi
    if [ "$QUIET" != "true" ] && [ -n "$git_remote_err" ] && [ -s "$git_remote_err" ]; then
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
# The jq program distinguishes three outcomes the caller must not conflate, so it prints a
# sentinel word rather than an empty string for the two "no Status value" cases:
#   <not-on-board>  no projectItem for the configured project (AC-7: not a violation)
#   <no-status>     on the board but the Status field carries no value
gql_err=$(mktemp "${TMPDIR:-/tmp}/rite-status-gate-gql-err-XXXXXX") || gql_err=""
jq_err=$(mktemp "${TMPDIR:-/tmp}/rite-status-gate-jq-err-XXXXXX") || jq_err=""
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
}' -f owner="$REPO_OWNER" -f repo="$REPO_NAME" -F number="$ISSUE" 2>"${gql_err:-/dev/null}" \
  | jq -r --argjson pn "$PROJECT_NUMBER" '
      (([.data.repository.issue.projectItems.nodes[]? | select(.project.number == $pn)][0]) // null) as $pitem
      | if $pitem == null then "<not-on-board>"
        else (([$pitem.fieldValues.nodes[] | select(.field.name == "Status") | .name][0]) // "<no-status>")
        end
    ' 2>"${jq_err:-/dev/null}"); then
  warn "gh api graphql or jq pipeline failed while reading Issue #$ISSUE board Status"
  if [ "$QUIET" != "true" ] && [ -n "$gql_err" ] && [ -s "$gql_err" ]; then
    head -3 "$gql_err" | neutralize_ctrl --keep-newline | sed 's/^/  gh: /' >&2
  fi
  if [ "$QUIET" != "true" ] && [ -n "$jq_err" ] && [ -s "$jq_err" ]; then
    head -3 "$jq_err" | neutralize_ctrl --keep-newline | sed 's/^/  jq: /' >&2
  fi
  emit unknown ""
fi
rm -f "${gql_err:-}" "${jq_err:-}"
gql_err=""
jq_err=""

# An empty capture means the pipeline produced nothing at all — a malformed response the
# jq program could not classify. That is a failed verification, not a clean board.
if [ -z "$CURRENT" ]; then
  warn "empty board Status response for Issue #$ISSUE (malformed API response)"
  emit unknown ""
fi

if [ "$CURRENT" = "<not-on-board>" ]; then
  emit skipped "$CURRENT"
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
