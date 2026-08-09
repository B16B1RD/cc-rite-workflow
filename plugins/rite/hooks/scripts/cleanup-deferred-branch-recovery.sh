#!/usr/bin/env bash
# Classify a branch deferred because it is checked out in another worktree.
# recovery=auto is allowed only when the manifest and the reaper's dirty gate agree.
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
branch=""
pr_merged="false"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --branch|--pr-merged)
      _opt=$1
      shift
      if [ "$#" -eq 0 ]; then
        echo "ERROR: $_opt requires a value" >&2
        exit 2
      fi
      if [ "$_opt" = "--branch" ]; then branch=$1; else pr_merged=$1; fi
      shift ;;
    *) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$branch" ] || ! git check-ref-format --branch "$branch" >/dev/null 2>&1; then
  echo "ERROR: --branch must be a valid non-empty branch name" >&2
  exit 2
fi
case "$pr_merged" in true|false) ;; *) echo "ERROR: --pr-merged must be true or false" >&2; exit 2 ;; esac

branch_wt=$(git worktree list --porcelain 2>/dev/null | awk -v wanted="refs/heads/$branch" '
  /^worktree / { wt=substr($0, 10) }
  /^branch / && substr($0, 8) == wanted { print wt; exit }
') || branch_wt=""

recovery=manual
manifest_ok=false
if [ "$pr_merged" = "true" ]; then
  bash "$SCRIPT_DIR/rite-tmp-artifact.sh" record --type branch --id "$branch" 2>/dev/null || true
  shared_root=$(bash "$SCRIPT_DIR/../state-path-resolve.sh" 2>/dev/null) || shared_root=""
  [ -n "$shared_root" ] || shared_root=$(git rev-parse --show-toplevel 2>/dev/null) || shared_root=""
  if [ -n "$shared_root" ] && grep -qxF "branch$(printf '\t')$branch" "$shared_root/.rite/tmp-artifacts.tsv" 2>/dev/null; then
    manifest_ok=true
  fi
fi

status_rc=1
status_out="?? (worktree unresolved — assume dirty for safety)"
if [ -n "$branch_wt" ] && [ -d "$branch_wt" ]; then
  status_rc=0
  status_out=$(cd "$branch_wt" && bash "$SCRIPT_DIR/lib/git-status-filtered.sh") || status_rc=$?
fi

if [ "$manifest_ok" = "true" ] && [ "$status_rc" -eq 0 ] && [ -z "$status_out" ]; then
  recovery=auto
fi

echo "[CONTEXT] BRANCH_DELETE_DEFERRED=1; branch=$branch; reason=checked_out_in_worktree; recovery=$recovery" >&2
if [ "$recovery" = "auto" ]; then
  echo "WARNING: ローカルブランチ $branch は、まだ削除されていない作業ツリーで使用中のため、削除を見送りました。その作業ツリーが解放されたあと、次回のセッション開始時に自動で回収されます。" >&2
  exit 0
fi

branch_q=$(printf '%q' "$branch")
if [ -n "$branch_wt" ] && [ -d "$branch_wt" ]; then
  wt_q=$(printf '%q' "$branch_wt")
  echo "[CONTEXT] BRANCH_DELETE_DEFERRED_WORKTREE=1; branch=$branch; path_q=$wt_q" >&2
  echo "WARNING: ローカルブランチ $branch の作業ツリーは reaper の dirty gate を通過できないため recovery=manual です。まず git -C $wt_q status --short で確認し、変更を commit / stash / copy してください。clean を確認した後だけ実行: git worktree remove $wt_q && git worktree prune && git branch -D -- $branch_q" >&2
else
  echo "WARNING: ローカルブランチ $branch の作業ツリーを解決できないため recovery=manual です。git worktree list --porcelain で branch refs/heads/$branch の実パスを特定し、変更を保全して clean を確認するまで削除しないでください。" >&2
fi
