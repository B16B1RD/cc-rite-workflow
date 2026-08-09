#!/bin/bash
# Update Ready work memory only when both PR-head identity fields are available.
set -u
pr_number=""; issue_number=""; owner_repo=""; plugin_root=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pr) [ "$#" -ge 2 ] || exit 2; pr_number="$2"; shift 2 ;;
    --issue) [ "$#" -ge 2 ] || exit 2; issue_number="$2"; shift 2 ;;
    --repo) [ "$#" -ge 2 ] || exit 2; owner_repo="$2"; shift 2 ;;
    --plugin-root) [ "$#" -ge 2 ] || exit 2; plugin_root="$2"; shift 2 ;;
    *) echo "ERROR: ready work memory: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$pr_number" in ''|*[!0-9]*) echo "ERROR: ready work memory: numeric PR and Issue are required" >&2; exit 2 ;; esac
case "$issue_number" in ''|*[!0-9]*) echo "ERROR: ready work memory: numeric PR and Issue are required" >&2; exit 2 ;; esac
head_fields=$(gh pr view "$pr_number" -R "$owner_repo" --json headRefName,headRefOid --jq '[.headRefName,.headRefOid] | @tsv') || head_fields=""
IFS=$'\t' read -r ready_pr_branch ready_pr_oid <<< "$head_fields"
if [ -z "${ready_pr_branch:-}" ] || [ -z "${ready_pr_oid:-}" ]; then
  echo "WARNING: PR head 情報を取得できないため local work memory 更新をスキップします" >&2
  exit 0
fi
WM_SOURCE=ready WM_PHASE=ready WM_PHASE_DETAIL='Ready for review に変更完了' \
  WM_NEXT_ACTION='レビュー待ち' WM_BODY_TEXT='PR marked as ready for review.' \
  WM_ISSUE_NUMBER="$issue_number" WM_BRANCH_OVERRIDE="$ready_pr_branch" \
  WM_LAST_COMMIT_OVERRIDE="$ready_pr_oid" \
  bash "$plugin_root/hooks/local-wm-update.sh" 2>/dev/null || true
