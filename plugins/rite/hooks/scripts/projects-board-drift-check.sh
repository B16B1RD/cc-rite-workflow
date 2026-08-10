#!/bin/bash
# rite workflow - Projects Board "Done" Drift Check
#
# Reconciliation drift-guard for the "CLOSED but board != Done" gap.
# A Done transition is only wired into /rite:cleanup and /rite:issue-close, but
# GitHub auto-closes Issues via a PR body "Closes #N" the moment the PR merges. When
# /rite:cleanup is not run afterwards, the board freezes at its last value (In Review
# for a ready Issue, Todo for an untouched one). No reconciliation picks these back up.
#
# This script scans recently-updated CLOSED Issues and reports the ones whose GitHub
# Projects board Status is not "Done". It is a read-only detector by default (matching
# the other hooks/scripts/*-check.sh lint checks); with --reconcile it drives
# scripts/projects-status-update.sh to set Status to Done.
#
# Closure-reason policy: the closure reason is not consulted. The board's Status field
# has no Cancelled-equivalent terminal option, so a wontfix / duplicate closure has
# nowhere to land other than Done — leaving it filtered out only strands it in a
# non-terminal column that no reconciler ever revisits.
#
# On-board policy: an Issue that is not on the project board (no projectItem for the
# configured project_number) is NOT a drift — there is no board Status to reconcile.
# Only Issues that ARE on the board with Status != "Done" are reported.
#
# Usage:
#   bash projects-board-drift-check.sh [options]
#
# Options:
#   --dry-run     Report only; do not reconcile (default)
#   --reconcile   Update each drifted Issue's Status -> "Done" via
#                 projects-status-update.sh (auto_add false / non_blocking true / 冪等).
#                 Failures are logged but never block.
#   --limit N     Maximum CLOSED Issues to scan, most-recently-updated first
#                 (default: 100). GitHub GraphQL caps a single page at 100; values
#                 above 100 are clamped to 100 and a note is emitted (no pagination —
#                 drift forms at closure time, so the recent window is what matters).
#   --quiet       Suppress stderr WARNING lines (stdout report still produced)
#   -h, --help    Show usage
#
# Output (stdout): human-readable findings, terminated by the summary line
#   ==> Total projects-board-drift findings: N
# consumed by skills/lint/SKILL.md Phase 3.18 (regex: /Total projects-board-drift findings: (\d+)/).
#
# Exit codes (lint Phase 3.x drift-check convention):
#   0  no drift — OR a legitimate no-op (projects disabled / project_number unset /
#      rite-config.yml absent). Summary line reports 0 findings.
#   1  drift detected (warning, non-blocking in lint)
#   2  invocation error (bad args, gh/network failure, malformed API response)
set -euo pipefail

# --- Arg parse ---
RECONCILE=false
LIMIT=100
QUIET=false

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)   RECONCILE=false; shift ;;
    --reconcile) RECONCILE=true; shift ;;
    --limit)
      # A bare trailing `--limit` (no value) leaves only 1 positional, so `shift 2`
      # would fail under `set -e` and abort with exit 1 — which lint Phase 3.18 maps to
      # "drift detected" (warning). Guard the value's presence so a missing --limit value
      # exits 2 (invocation error) like the other bad-args paths below.
      if [ "$#" -lt 2 ]; then
        echo "ERROR: --limit requires a value" >&2
        exit 2
      fi
      LIMIT="$2"; shift 2 ;;
    --quiet)     QUIET=true; shift ;;
    -h|--help)
      cat <<'USAGE_EOF'
projects-board-drift-check.sh - Projects Board "Done" Drift Check

Scans recently-updated CLOSED Issues and reports the ones whose GitHub Projects board
Status is not "Done" — the symptom of a closure that never reached the board, such as a
merge that auto-closed an Issue without /rite:cleanup running to set Done.

Usage:
  bash projects-board-drift-check.sh [options]

Options:
  --dry-run     Report only; do not reconcile (default)
  --reconcile   Update each drifted Issue's Status -> "Done" via projects-status-update.sh
  --limit N     Maximum CLOSED Issues to scan, most-recently-updated first (default: 100)
  --quiet       Suppress stderr WARNING lines (stdout report still produced)
  -h, --help    Show usage
USAGE_EOF
      exit 0 ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      exit 2 ;;
  esac
done

if ! [[ "$LIMIT" =~ ^[0-9]+$ ]] || [ "$LIMIT" -eq 0 ]; then
  echo "ERROR: --limit must be a positive integer (got: '$LIMIT')" >&2
  exit 2
fi

# GitHub GraphQL caps a single issues() page at 100. Clamp and note rather than paginate.
LIMIT_NOTE=""
if [ "$LIMIT" -gt 100 ]; then
  LIMIT_NOTE="note: --limit $LIMIT clamped to 100 (single GraphQL page; recent-closure window)"
  LIMIT=100
fi

# --- Locate rite-config.yml (walk upward, same idiom as watchdog-status-mismatch.sh) ---
CWD="$(pwd)"
REPO_ROOT="$CWD"
while [ "$REPO_ROOT" != "/" ] && [ ! -f "$REPO_ROOT/rite-config.yml" ] && [ ! -d "$REPO_ROOT/.git" ]; do
  REPO_ROOT="$(dirname "$REPO_ROOT")"
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../control-char-neutralize.sh
source "$SCRIPT_DIR/../control-char-neutralize.sh"
# SCRIPT_DIR is .../hooks/scripts; plugin root (plugins/rite) is its grandparent (../..)
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

emit_noop() {
  # Legitimate no-op: emit a 0-findings summary so lint Phase 3.18 records success.
  local reason="$1"
  [ "$QUIET" = "true" ] || echo "projects-board-drift: no-op ($reason)" >&2
  echo "projects-board-drift check: $reason — nothing to scan"
  echo "==> Total projects-board-drift findings: 0"
  exit 0
}

if [ ! -f "$REPO_ROOT/rite-config.yml" ]; then
  emit_noop "rite-config.yml not found from $CWD upward"
fi

# AC-4: skip when Projects integration is disabled.
PROJECTS_ENABLED=$(awk '/^github:/{h=1;next} h && /^  projects:/{p=1;next} p && /^    enabled:/{print $2; exit}' "$REPO_ROOT/rite-config.yml" 2>/dev/null) || PROJECTS_ENABLED=""
PROJECT_NUMBER=$(awk '/^github:/{h=1;next} h && /^  projects:/{p=1;next} p && /^    project_number:/{print $2; exit}' "$REPO_ROOT/rite-config.yml" 2>/dev/null) || PROJECT_NUMBER=""

if [ "$PROJECTS_ENABLED" != "true" ] || ! [[ "$PROJECT_NUMBER" =~ ^[0-9]+$ ]]; then
  emit_noop "github.projects disabled or project_number unset"
fi

# --- Trap setup: tempfile orphan 防止 (EXIT/INT/TERM/HUP), same idiom as watchdog ---
repo_view_err=""
git_remote_err=""
gql_err=""
jq_err=""
reconcile_err=""
_rite_board_drift_cleanup() {
  rm -f "${repo_view_err:-}" "${git_remote_err:-}" "${gql_err:-}" "${jq_err:-}" "${reconcile_err:-}"
}
trap 'rc=$?; _rite_board_drift_cleanup; exit $rc' EXIT
trap '_rite_board_drift_cleanup; exit 130' INT
trap '_rite_board_drift_cleanup; exit 143' TERM
trap '_rite_board_drift_cleanup; exit 129' HUP

# --- Repo info ---
# git-remote parse first: works even when `origin` is an SSH Host alias
# unrecognized by gh's host allowlist (#1899). Falls through to
# `gh repo view` whenever the parse fails (no origin remote, unparseable
# URL, charset-rejected) — its stderr is captured so a two-sided failure
# can be attributed on both sides.
REPO_OWNER=""
REPO_NAME=""
git_remote_err=$(mktemp "${TMPDIR:-/tmp}/rite-board-drift-git-remote-err-XXXXXX") || git_remote_err=""
_git_or_line=$(bash "$SCRIPT_DIR/lib/git-remote.sh" resolve-owner-repo 2>"${git_remote_err:-/dev/null}") || _git_or_line=""
if [ -n "$_git_or_line" ]; then
  IFS=$'\t' read -r REPO_OWNER REPO_NAME <<< "$_git_or_line"
fi
if [ -z "$REPO_OWNER" ] || [ -z "$REPO_NAME" ]; then
  repo_view_err=$(mktemp "${TMPDIR:-/tmp}/rite-board-drift-repo-err-XXXXXX") || repo_view_err=""
  if ! REPO_INFO=$(gh repo view --json owner,name 2>"${repo_view_err:-/dev/null}"); then
    echo "ERROR: gh repo view failed" >&2
    if [ -n "$repo_view_err" ] && [ -s "$repo_view_err" ]; then
      head -5 "$repo_view_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    fi
    if [ -n "$git_remote_err" ] && [ -s "$git_remote_err" ]; then
      head -3 "$git_remote_err" | neutralize_ctrl --keep-newline | sed 's/^/  git-remote: /' >&2
    fi
    echo "  対処: gh auth status / network 接続を確認してください" >&2
    exit 2
  fi
  REPO_OWNER=$(printf '%s' "$REPO_INFO" | jq -r '.owner.login // empty' 2>/dev/null) || REPO_OWNER=""
  REPO_NAME=$(printf '%s' "$REPO_INFO" | jq -r '.name // empty' 2>/dev/null) || REPO_NAME=""
  if [ -z "$REPO_OWNER" ] || [ -z "$REPO_NAME" ]; then
    echo "ERROR: failed to parse owner/name from gh repo view (owner='$REPO_OWNER' name='$REPO_NAME')" >&2
    exit 2
  fi
fi

# --- Scan recently-updated CLOSED Issues (single GraphQL page) ---
gql_err=$(mktemp "${TMPDIR:-/tmp}/rite-board-drift-gql-err-XXXXXX") || gql_err=""
jq_err=$(mktemp "${TMPDIR:-/tmp}/rite-board-drift-jq-err-XXXXXX") || jq_err=""

# jq emits one TSV line per drifted Issue: number<TAB>status<TAB>title
# Drift = on board (projectItem for $pn) AND Status != "Done".
if ! DRIFT_TSV=$(set -o pipefail; gh api graphql -f query='
query($owner: String!, $repo: String!, $first: Int!) {
  repository(owner: $owner, name: $repo) {
    issues(first: $first, states: CLOSED, orderBy: {field: UPDATED_AT, direction: DESC}) {
      nodes {
        number
        title
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
  }
}' -f owner="$REPO_OWNER" -f repo="$REPO_NAME" -F first="$LIMIT" 2>"${gql_err:-/dev/null}" \
  | jq -r --argjson pn "$PROJECT_NUMBER" '
      .data.repository.issues.nodes[]
      | . as $i
      | (([$i.projectItems.nodes[] | select(.project.number == $pn)][0]) // null) as $pitem
      | select($pitem != null)
      | (([$pitem.fieldValues.nodes[] | select(.field.name == "Status") | .name][0]) // "<no-status>") as $st
      | select($st != "Done")
      | "\($i.number)\t\($st)\t\($i.title)"
    ' 2>"${jq_err:-/dev/null}"); then
  echo "ERROR: gh api graphql or jq pipeline failed while scanning CLOSED Issues" >&2
  if [ -n "$gql_err" ] && [ -s "$gql_err" ]; then head -5 "$gql_err" | neutralize_ctrl --keep-newline | sed 's/^/  gh: /' >&2; fi
  if [ -n "$jq_err" ] && [ -s "$jq_err" ]; then head -5 "$jq_err" | neutralize_ctrl --keep-newline | sed 's/^/  jq: /' >&2; fi
  echo "  対処: gh auth status / network 接続 / repository 権限を確認してください" >&2
  exit 2
fi
[ -n "$gql_err" ] && rm -f "$gql_err"; gql_err=""
[ -n "$jq_err" ] && rm -f "$jq_err"; jq_err=""

[ -n "$LIMIT_NOTE" ] && echo "$LIMIT_NOTE"

DRIFT_COUNT=0
RECONCILED=0
RECONCILE_FAILURES=0

if [ -n "$DRIFT_TSV" ]; then
  while IFS=$'\t' read -r issue_number status title; do
    [ -n "$issue_number" ] || continue
    DRIFT_COUNT=$((DRIFT_COUNT + 1))

    reconcile_suffix=""
    if [ "$RECONCILE" = "true" ]; then
      reconcile_err=$(mktemp "${TMPDIR:-/tmp}/rite-board-drift-reconcile-err-XXXXXX") || reconcile_err=""
      reconcile_json=$(bash "$PLUGIN_ROOT/scripts/projects-status-update.sh" "$(jq -n \
        --argjson issue "$issue_number" --arg owner "$REPO_OWNER" --arg repo "$REPO_NAME" \
        --argjson project_number "$PROJECT_NUMBER" --arg status "Done" \
        --argjson auto_add false --argjson non_blocking true \
        '{issue_number:$issue, owner:$owner, repo:$repo, project_number:$project_number, status_name:$status, auto_add:$auto_add, non_blocking:$non_blocking}')" 2>"${reconcile_err:-/dev/null}") || reconcile_json=""
      reconcile_result=$(printf '%s' "$reconcile_json" | jq -r '.result // "failed"' 2>/dev/null) || reconcile_result="failed"
      if [ "$reconcile_result" = "updated" ]; then
        RECONCILED=$((RECONCILED + 1))
        reconcile_suffix=" -> reconciled to Done"
      else
        RECONCILE_FAILURES=$((RECONCILE_FAILURES + 1))
        reconcile_suffix=" -> reconcile FAILED ($reconcile_result)"
        # projects-status-update.sh は non_blocking=true の handled failure では自身の stderr へ
        # 何も書かず、診断を stdout JSON の .warnings[] にのみ載せる。.result だけを読むと失敗理由が
        # どこにも出ないため、ここで .warnings[] を stderr へ転記する (skills/ready と同じ契約)。
        if [ "$QUIET" != "true" ] && [ -n "$reconcile_json" ]; then
          printf '%s' "$reconcile_json" | jq -r '.warnings[]? // empty' 2>/dev/null \
            | while IFS= read -r w; do
                [ -n "$w" ] || continue
                echo "projects-board-drift: reconcile #$issue_number: $(printf '%s' "$w" | neutralize_ctrl --c0-only)" >&2
              done
        fi
        # reconcile_err に中身が入るのは helper を exec できなかった場合のみ (handled failure は
        # 上の .warnings[] が担う)。両方空なら理由不明として exec 失敗の可能性を示す。
        if [ "$QUIET" != "true" ] && [ -n "$reconcile_err" ] && [ -s "$reconcile_err" ]; then
          echo "projects-board-drift: reconcile exec failed for #$issue_number: $(head -c 200 "$reconcile_err" | tr '\n' ' ' | neutralize_ctrl --c0-only)" >&2
        fi
      fi
      [ -n "$reconcile_err" ] && rm -f "$reconcile_err"; reconcile_err=""
    fi

    echo "[projects-board-drift] #$issue_number \"$title\" status=\"$status\" (expected Done)$reconcile_suffix"
    [ "$QUIET" = "true" ] || echo "projects-board-drift: WARNING #$issue_number CLOSED but board Status=\"$status\" (expected Done)" >&2
  done <<< "$DRIFT_TSV"
fi

if [ "$DRIFT_COUNT" -gt 0 ] && [ "$RECONCILE" != "true" ]; then
  echo "対処: 'bash $PLUGIN_ROOT/hooks/scripts/projects-board-drift-check.sh --reconcile' で Status を Done へ是正できます (または /rite:issue-close / /rite:cleanup を当該 Issue に対して実行)"
fi
if [ "$RECONCILE" = "true" ]; then
  echo "reconcile summary: $RECONCILED updated, $RECONCILE_FAILURES failed"
fi

echo "==> Total projects-board-drift findings: $DRIFT_COUNT"

if [ "$DRIFT_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
