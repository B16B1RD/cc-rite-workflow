#!/bin/bash
# rite workflow - Status Mismatch Watchdog
#
# Scans Issues linked to OPEN PRs and detects ones whose GitHub Projects Status lags
# behind where the PR already is. Outputs JSON to stdout and a warning summary to stderr.
# Optionally attempts reconciliation when --reconcile is passed.
#
# Two rules, evaluated per scanned PR:
#
#   Todo residue         Status = "Todo" with ANY open PR, draft included → expected
#                        "In Progress". A draft PR means /rite:open already ran, so a
#                        board still on Todo means its Status transition never landed.
#                        Drafts must be in scope: the whole iterate loop happens while
#                        the PR is a draft, which is exactly the window a ready-only
#                        scan cannot see.
#   In Progress residue  Status = "In Progress" with a Ready PR (isDraft=false) →
#                        expected "In Review". The isDraft=false qualifier belongs to this
#                        rule alone: "In Progress" during a draft is the correct state,
#                        not a mismatch.
#
# An Issue that is not on the project board is never a mismatch — there is no board
# Status to reconcile (same on-board policy as hooks/scripts/projects-board-drift-check.sh).
#
# Usage:
#   bash watchdog-status-mismatch.sh [options]
#
# Options:
#   --dry-run         Report only; do not reconcile (default)
#   --reconcile      Attempt to update each mismatched Issue Status to the status the
#                    fired rule expects (Todo → "In Progress", In Progress → "In Review")
#                    via projects-status-update.sh. A single hardcoded target would push
#                    a Todo residue straight to "In Review", manufacturing the very gap
#                    this watchdog exists to report. Failures are logged but never block.
#   --limit N        Maximum PRs to scan (default: 50)
#   --quiet          Suppress stderr warnings (JSON output still produced)
#   -h, --help       Show usage
#
# Output (stdout):
#   {
#     "scan_summary": {
#       "prs_scanned": N,
#       "mismatches_found": M,
#       "reconciled": K,
#       "reconcile_failures": F
#     },
#     "mismatches": [
#       { "pr_number": 1001, "issue_number": 998, "current_status": "In Progress", "expected_status": "In Review", "reconcile_result": "updated|failed|skipped|not_attempted" }
#     ],
#     "warnings": []
#   }
#
# Exit codes:
#   0  success, no mismatches
#   1  fatal error (missing config / gh failure)
#   2  mismatches detected (intended for CI gating)
set -euo pipefail

# --- Arg parse ---
DRY_RUN=true
RECONCILE=false
LIMIT=50
QUIET=false

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)   DRY_RUN=true; RECONCILE=false; shift ;;
    --reconcile) DRY_RUN=false; RECONCILE=true; shift ;;
    --limit)     LIMIT="$2"; shift 2 ;;
    --quiet)     QUIET=true; shift ;;
    -h|--help)
      # here-doc usage で BSD head 互換性問題 (head -n -1) を回避
      cat <<'USAGE_EOF'
watchdog-status-mismatch.sh - Status Mismatch Watchdog

Scans Issues linked to OPEN PRs and detects ones whose GitHub Projects Status lags behind
where the PR already is. Outputs JSON to stdout and a warning summary to stderr.
Optionally attempts reconciliation when --reconcile is passed.

Rules:
  Todo residue         Status "Todo" + any open PR (draft included) -> expected "In Progress"
  In Progress residue  Status "In Progress" + Ready PR (isDraft=false) -> expected "In Review"

Issues that are not on the project board are never reported (no board Status to reconcile).

Usage:
  bash watchdog-status-mismatch.sh [options]

Options:
  --dry-run         Report only; do not reconcile (default)
  --reconcile      Attempt to update each mismatched Issue Status to the status the fired
                   rule expects (Todo -> "In Progress", In Progress -> "In Review") via
                   projects-status-update.sh. Failures are logged but never block.
  --limit N        Maximum PRs to scan (default: 50)
  --quiet          Suppress stderr warnings (JSON output still produced)
  -h, --help       Show usage
USAGE_EOF
      exit 0 ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      exit 1 ;;
  esac
done

if ! [[ "$LIMIT" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --limit must be a positive integer (got: $LIMIT)" >&2
  exit 1
fi

# --- Locate rite-config.yml ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=../hooks/control-char-neutralize.sh
source "$SCRIPT_DIR/../hooks/control-char-neutralize.sh"

# Find repo root (look upward for rite-config.yml or .git)
CWD="$(pwd)"
REPO_ROOT="$CWD"
while [ "$REPO_ROOT" != "/" ] && [ ! -f "$REPO_ROOT/rite-config.yml" ] && [ ! -d "$REPO_ROOT/.git" ]; do
  REPO_ROOT="$(dirname "$REPO_ROOT")"
done

if [ ! -f "$REPO_ROOT/rite-config.yml" ]; then
  echo "ERROR: rite-config.yml not found from $CWD upward" >&2
  exit 1
fi

PROJECTS_ENABLED=$(awk '/^github:/{h=1;next} h && /^  projects:/{p=1;next} p && /^    enabled:/{print $2; exit}' "$REPO_ROOT/rite-config.yml" 2>/dev/null) || PROJECTS_ENABLED=""
PROJECT_NUMBER=$(awk '/^github:/{h=1;next} h && /^  projects:/{p=1;next} p && /^    project_number:/{print $2; exit}' "$REPO_ROOT/rite-config.yml" 2>/dev/null) || PROJECT_NUMBER=""

if [ "$PROJECTS_ENABLED" != "true" ] || [ -z "$PROJECT_NUMBER" ]; then
  jq -n --arg reason "projects_disabled_or_unconfigured" \
    '{scan_summary: {prs_scanned: 0, mismatches_found: 0, reconciled: 0, reconcile_failures: 0}, mismatches: [], warnings: [$reason]}'
  exit 0
fi

# --- Trap setup: tempfile orphan 防止 (EXIT/INT/TERM/HUP) ---
# stderr-capture symmetry contract: this script and hooks/post-compact.sh form
# the 2-site set for gh/jq stderr discrimination. Update both together if the
# set changes.
# path 先行宣言 → trap 先行設定 → mktemp の順序で race window を排除する。
# loop 内 gql_err は毎 iteration mktemp + 末尾 rm の現行構造を維持しつつ、signal 経路では
# 本 trap が一括 cleanup する (defense-in-depth)。
# gh repo view と gh pr list は別 tempfile (repo_view_err / pr_list_err) に分けて capture し、
# 前者の non-fatal warning が後者の redirect で truncate されないようにする。
repo_view_err=""
git_remote_err=""
pr_list_err=""
gql_err=""
jq_err=""
reconcile_err=""
_rite_watchdog_cleanup() {
  rm -f "${repo_view_err:-}" "${git_remote_err:-}" "${pr_list_err:-}" "${gql_err:-}" "${jq_err:-}" "${reconcile_err:-}"
}
trap 'rc=$?; _rite_watchdog_cleanup; exit $rc' EXIT
trap '_rite_watchdog_cleanup; exit 130' INT
trap '_rite_watchdog_cleanup; exit 143' TERM
trap '_rite_watchdog_cleanup; exit 129' HUP

# --- Repo info ---
# git-remote parse first: works even when `origin` is an SSH Host alias
# unrecognized by gh's host allowlist. Falls through to
# `gh repo view` (stderr captured to repo_view_err per the 2-site contract
# declared above) whenever the parse fails (no origin remote, unparseable
# URL, charset-rejected) — its stderr is captured so a two-sided failure
# can be attributed on both sides.
REPO_OWNER=""
REPO_NAME=""
git_remote_err=$(mktemp "${TMPDIR:-/tmp}/rite-watchdog-git-remote-err-XXXXXX") || git_remote_err=""
_git_or_line=$(bash "$PLUGIN_ROOT/hooks/scripts/lib/git-remote.sh" resolve-owner-repo 2>"${git_remote_err:-/dev/null}") || _git_or_line=""
if [ -n "$_git_or_line" ]; then
  IFS=$'\t' read -r REPO_OWNER REPO_NAME <<< "$_git_or_line"
fi
if [ -z "$REPO_OWNER" ] || [ -z "$REPO_NAME" ]; then
  repo_view_err=$(mktemp "${TMPDIR:-/tmp}/rite-watchdog-repo-err-XXXXXX") || repo_view_err=""
  if ! REPO_INFO=$(gh repo view --json owner,name 2>"${repo_view_err:-/dev/null}"); then
    echo "ERROR: gh repo view failed" >&2
    if [ -n "$repo_view_err" ] && [ -s "$repo_view_err" ]; then
      head -5 "$repo_view_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    fi
    if [ -n "$git_remote_err" ] && [ -s "$git_remote_err" ]; then
      head -3 "$git_remote_err" | neutralize_ctrl --keep-newline | sed 's/^/  git-remote: /' >&2
    fi
    echo "  対処: gh auth status / network 接続を確認してください" >&2
    exit 1
  fi
  # cycle 8 C7-F02 対応: jq の `// empty` fallback + 明示 fail で `set -euo pipefail` 下の silent abort を防ぐ。
  # `// empty` を付けない素朴な `jq -r '.owner.login'` は auth-scope 縮退時に `null` 文字列を代入するか
  # jq exit 5 で診断情報を破棄する。空文字列で fail-fast し、stderr に root cause を出力する。
  REPO_OWNER=$(printf '%s' "$REPO_INFO" | jq -r '.owner.login // empty' 2>/dev/null) || REPO_OWNER=""
  REPO_NAME=$(printf '%s' "$REPO_INFO" | jq -r '.name // empty' 2>/dev/null) || REPO_NAME=""
  if [ -z "$REPO_OWNER" ] || [ -z "$REPO_NAME" ]; then
    echo "ERROR: failed to parse owner/name from gh repo view (owner='$REPO_OWNER' name='$REPO_NAME')" >&2
    echo "  対処: gh auth refresh で scope を更新するか、PAT の repo permission を確認してください" >&2
    exit 1
  fi
fi

# --- Scan OPEN PRs (drafts included; the Todo-residue rule needs them) ---
pr_list_err=$(mktemp "${TMPDIR:-/tmp}/rite-watchdog-pr-list-err-XXXXXX") || pr_list_err=""
if ! PR_LIST=$(gh pr list --repo "$REPO_OWNER/$REPO_NAME" --state open --limit "$LIMIT" --json number,isDraft,body,headRefName 2>"${pr_list_err:-/dev/null}"); then
  echo "ERROR: gh pr list failed" >&2
  if [ -n "$pr_list_err" ] && [ -s "$pr_list_err" ]; then
    head -5 "$pr_list_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  fi
  echo "  対処: gh auth status / network 接続 / repository 権限を確認してください" >&2
  exit 1
fi

PRS_SCANNED=0
MISMATCHES=()
RECONCILED=0
RECONCILE_FAILURES=0

# cycle 10 F-10 対応: process substitution の exit code は親に伝播しないため、
# jq 失敗時 (PR_LIST malformed) に loop body が 0 回実行され silent success (`exit 0`) する経路を防ぐ。
# pre-check として jq 'length' で PR_LIST の有効性を検証する。
pr_count_check=$(printf '%s' "$PR_LIST" | jq 'length' 2>/dev/null) || pr_count_check=""
if [ -z "$pr_count_check" ]; then
  echo "ERROR: PR_LIST が valid JSON ではないか jq バイナリ異常です (silent loop skip 防止)" >&2
  echo "  対処: gh pr list の出力と jq バージョンを確認してください" >&2
  exit 1
fi

while IFS= read -r pr_entry; do
  # cycle 10 F-09 対応: jq 失敗時の error handling を追加 (set -euo pipefail 下で script 全体が
  # abort し PR scan が完全停止する fragility を排除)。失敗 entry は continue で skip し warnings に記録。
  pr_number=$(printf '%s' "$pr_entry" | jq -r '.number' 2>/dev/null) || pr_number=""
  is_draft=$(printf '%s' "$pr_entry" | jq -r '.isDraft' 2>/dev/null) || is_draft=""
  pr_body=$(printf '%s' "$pr_entry" | jq -r '.body // empty' 2>/dev/null) || pr_body=""
  head_ref=$(printf '%s' "$pr_entry" | jq -r '.headRefName // empty' 2>/dev/null) || head_ref=""
  if [ -z "$pr_number" ] || [ -z "$is_draft" ]; then
    if [ "$QUIET" != "true" ]; then
      echo "[watchdog] ⚠️ jq parse failed for PR entry, skipping (pr_entry preview: $(printf '%s' "$pr_entry" | head -c 80 | neutralize_ctrl))" >&2
    fi
    continue
  fi
  PRS_SCANNED=$((PRS_SCANNED + 1))

  # Drafts are in scope here: the Todo-residue rule below needs them. The isDraft
  # qualifier belongs to the In-Progress rule alone.

  # Extract linked Issue number from PR body (Closes #N / Fixes #N / Resolves #N) or branch name (issue-N)
  issue_number=$(printf '%s' "$pr_body" | grep -ioE '(close[sd]?|fix(e[sd])?|resolve[sd]?) #[0-9]+' | head -1 | grep -oE '[0-9]+$' || true)
  if [ -z "$issue_number" ] && [[ "$head_ref" =~ issue-([0-9]+) ]]; then
    issue_number="${BASH_REMATCH[1]}"
  fi
  if [ -z "$issue_number" ]; then
    continue  # No linked Issue
  fi

  # Query Issue's current Status in the Project. Capture gh and jq stderr into
  # independent tempfiles so a failed pipeline can be triaged by side (gh vs jq).
  gql_err=$(mktemp "${TMPDIR:-/tmp}/rite-watchdog-gql-err-XXXXXX") || gql_err=""
  jq_err=$(mktemp "${TMPDIR:-/tmp}/rite-watchdog-jq-err-XXXXXX") || jq_err=""
  # Inner `set -o pipefail` mirrors the outer setting; making it explicit keeps
  # the inheritance contract obvious when this block is run in a sub-shell.
  if ! current_status=$(set -o pipefail; gh api graphql -f query='
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
}' -f owner="$REPO_OWNER" -f repo="$REPO_NAME" -F number="$issue_number" 2>"${gql_err:-/dev/null}" \
      | jq -r --argjson pn "$PROJECT_NUMBER" \
        '[.data.repository.issue.projectItems.nodes[]? | select(.project.number == $pn) | .fieldValues.nodes[] | select(.field.name == "Status") | .name][0] // empty' 2>"${jq_err:-/dev/null}"); then
    # gh / jq pipeline 失敗 — silent skip せず warnings に記録 (debug 可能性向上)
    # 4-site stderr root cause attribution: gh_stderr と jq_stderr を独立表示
    if [ "$QUIET" != "true" ]; then
      gql_err_oneline=$(head -c 200 "${gql_err:-/dev/null}" 2>/dev/null | tr '\n' ' ' | neutralize_ctrl)
      jq_err_oneline=$(head -c 200 "${jq_err:-/dev/null}" 2>/dev/null | tr '\n' ' ' | neutralize_ctrl)
      echo "[watchdog] ⚠️ gh api graphql or jq failed for Issue #$issue_number (gh_stderr=$gql_err_oneline, jq_stderr=$jq_err_oneline)" >&2
    fi
    current_status=""
  fi
  [ -n "$gql_err" ] && rm -f "$gql_err"
  [ -n "$jq_err" ] && rm -f "$jq_err"
  # Reset path variables after rm so the trap (signal cleanup) does not attempt
  # a second rm on the now-stale path.
  gql_err=""
  jq_err=""

  # Rule dispatch. expected_status stays empty when no rule fires, which is also what
  # keeps an Issue that is not on the board out of the report: current_status is empty
  # there, so neither arm matches.
  # The arms use `if` rather than `[ ... ] && assign`: under `set -e` a false `[` at the
  # head of an AND list makes the whole case return non-zero and aborts the scan.
  expected_status=""
  case "$current_status" in
    Todo)
      expected_status="In Progress" ;;
    "In Progress")
      if [ "$is_draft" = "false" ]; then expected_status="In Review"; fi ;;
  esac

  if [ -n "$expected_status" ]; then
    reconcile_result="not_attempted"
    reconcile_stderr_oneline=""
    if [ "$RECONCILE" = "true" ]; then
      # stderr を tempfile に退避して失敗時の原因 (auth / rate limit / partial failure) を可視化する。
      # silent suppress (2>/dev/null) では RECONCILE_FAILURES non-zero 時に user が失敗原因を triage できない。
      reconcile_err=$(mktemp "${TMPDIR:-/tmp}/rite-watchdog-reconcile-err-XXXXXX") || reconcile_err=""
      reconcile_json=$(bash "$PLUGIN_ROOT/scripts/projects-status-update.sh" "$(jq -n \
        --argjson issue "$issue_number" --arg owner "$REPO_OWNER" --arg repo "$REPO_NAME" \
        --argjson project_number "$PROJECT_NUMBER" --arg status "$expected_status" \
        --argjson auto_add false --argjson non_blocking true \
        '{issue_number:$issue, owner:$owner, repo:$repo, project_number:$project_number, status_name:$status, auto_add:$auto_add, non_blocking:$non_blocking}')" 2>"${reconcile_err:-/dev/null}") || reconcile_json=""
      reconcile_result=$(printf '%s' "$reconcile_json" | jq -r '.result // "failed"' 2>/dev/null) || reconcile_result="failed"
      if [ "$reconcile_result" = "updated" ]; then
        RECONCILED=$((RECONCILED + 1))
      else
        RECONCILE_FAILURES=$((RECONCILE_FAILURES + 1))
        if [ -n "$reconcile_err" ] && [ -s "$reconcile_err" ]; then
          reconcile_stderr_oneline=$(head -c 200 "$reconcile_err" | tr '\n' ' ' | neutralize_ctrl)
          if [ "$QUIET" != "true" ]; then
            echo "[watchdog] ⚠️ reconcile failed for Issue #$issue_number: $reconcile_stderr_oneline" >&2
          fi
        fi
      fi
      [ -n "$reconcile_err" ] && rm -f "$reconcile_err"
      reconcile_err=""
    fi
    MISMATCHES+=("$(jq -n --argjson pr "$pr_number" --argjson issue "$issue_number" \
      --arg status "$current_status" --arg expected "$expected_status" \
      --arg recon "$reconcile_result" \
      --arg recon_stderr "$reconcile_stderr_oneline" \
      '{pr_number:$pr, issue_number:$issue, current_status:$status, expected_status:$expected, reconcile_result:$recon, reconcile_stderr:$recon_stderr}')")
    if [ "$QUIET" != "true" ]; then
      echo "[watchdog] ⚠️ mismatch: PR=#$pr_number isDraft=$is_draft → Issue #$issue_number Status=\"$current_status\" (expected $expected_status)" >&2
    fi
  fi
done < <(printf '%s' "$PR_LIST" | jq -c '.[]')

MISMATCH_COUNT=${#MISMATCHES[@]}

# Build output JSON
if [ "$MISMATCH_COUNT" -eq 0 ]; then
  mismatches_json='[]'
else
  mismatches_json=$(printf '%s\n' "${MISMATCHES[@]}" | jq -s '.')
fi

jq -n \
  --argjson scanned "$PRS_SCANNED" \
  --argjson found "$MISMATCH_COUNT" \
  --argjson reconciled "$RECONCILED" \
  --argjson failures "$RECONCILE_FAILURES" \
  --argjson mismatches "$mismatches_json" \
  '{scan_summary: {prs_scanned: $scanned, mismatches_found: $found, reconciled: $reconciled, reconcile_failures: $failures}, mismatches: $mismatches, warnings: []}'

if [ "$MISMATCH_COUNT" -gt 0 ]; then
  exit 2
fi
exit 0
