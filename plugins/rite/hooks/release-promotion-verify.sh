#!/bin/bash
# Verify that a develop -> main promotion contains only commits already merged
# through pull requests, then persist a short-lived merge-gate attestation.
#
# Invariant (squash-only): every commit on develop since the previous release
# must itself be the merge_commit_sha of a merged PR. Squash merges satisfy
# this; a merge-commit or rebase merge leaves the original commit SHA on
# develop and fails the jq check below (merged_at present and
# merge_commit_sha equal to the commit oid). Release prep PRs must be
# squash-merged (`gh pr merge {PREP_PR_NUMBER} --squash`). This script
# does not relax the condition — a non-squash commit is a hard fail (exit 5).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_NUMBER="${1:-}"
case "$PR_NUMBER" in ''|*[!0-9]*) echo "ERROR: release promotion PR number must be numeric" >&2; exit 2 ;; esac

owner_repo_tab=$(bash "$SCRIPT_DIR/scripts/lib/git-remote.sh" resolve-owner-repo 2>/dev/null) || owner_repo_tab=""
owner=""; repo=""
[ -n "$owner_repo_tab" ] && IFS=$'\t' read -r owner repo <<< "$owner_repo_tab"
if [ -z "$owner" ] || [ -z "$repo" ]; then
  owner=$(gh repo view --json owner --jq '.owner.login')
  repo=$(gh repo view --json name --jq '.name')
fi
owner_repo="$owner/$repo"

pr_json=$(gh pr view "$PR_NUMBER" -R "$owner_repo" --json baseRefName,headRefName,headRefOid)
base=$(jq -r '.baseRefName // empty' <<< "$pr_json")
head=$(jq -r '.headRefName // empty' <<< "$pr_json")
head_oid=$(jq -r '.headRefOid // empty' <<< "$pr_json")
commits_output=$(gh api --paginate -H 'Accept: application/vnd.github+json' \
  "repos/$owner/$repo/pulls/$PR_NUMBER/commits" --jq '.[].sha')
mapfile -t commits <<< "$commits_output"
expected_commit_count=$(gh api -H 'Accept: application/vnd.github+json' \
  "repos/$owner/$repo/pulls/$PR_NUMBER" --jq '.commits')

if [ "$base" != "main" ] || [ "$head" != "develop" ]; then
  echo "ERROR: release promotion must be develop -> main (actual: $head -> $base)" >&2
  exit 3
fi
if [[ ! "$head_oid" =~ ^[0-9a-fA-F]{40}$ ]] || [ -z "$commits_output" ] || [ "${#commits[@]}" -eq 0 ]; then
  echo "ERROR: release promotion PR head/commit list could not be verified" >&2
  exit 4
fi
case "$expected_commit_count" in ''|*[!0-9]*) echo "ERROR: release promotion total commit count could not be verified" >&2; exit 4 ;; esac
if [ "${#commits[@]}" -ne "$expected_commit_count" ]; then
  echo "ERROR: release promotion commit list is incomplete (${#commits[@]}/$expected_commit_count); merge denied" >&2
  exit 4
fi

for oid in "${commits[@]}"; do
  pulls=$(gh api -H 'Accept: application/vnd.github+json' "repos/$owner/$repo/commits/$oid/pulls")
  if ! jq -e --arg oid "$oid" 'any(.[]; .merged_at != null and .merge_commit_sha == $oid)' <<< "$pulls" >/dev/null; then
    echo "ERROR: release promotion contains commit without a merged PR: $oid" >&2
    exit 5
  fi
done

if [ -n "${RITE_STATE_ROOT:-}" ] && [ -d "$RITE_STATE_ROOT" ]; then
  state_root="$RITE_STATE_ROOT"
else
  state_root=$(bash "$SCRIPT_DIR/state-path-resolve.sh")
fi
attestation_dir="$state_root/.rite/release-promotions"
mkdir -p "$attestation_dir"
attestation="$attestation_dir/$PR_NUMBER.json"
now=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
jq -n --argjson pr "$PR_NUMBER" --arg base "$base" --arg head "$head" \
  --arg head_oid "$head_oid" --arg verified_at "$now" --argjson commits "$(printf '%s\n' "${commits[@]}" | jq -R . | jq -s .)" \
  '{schema_version:"1.0.0",pr_number:$pr,base:$base,head:$head,head_oid:$head_oid,commits:$commits,verified_at:$verified_at}' \
  > "$attestation.tmp"
mv "$attestation.tmp" "$attestation"
printf '%s\n' "$head_oid"
