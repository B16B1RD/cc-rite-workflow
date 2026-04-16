#!/bin/bash
# rite workflow - Wiki Worktree Commit (worktree-based page integration)
#
# Responsibility: commit pending changes in the `.rite/wiki-worktree`
# worktree (checked out to the configured `wiki.branch_name`) and push
# to origin. Used by commands/wiki/ingest.md Phase 5 after the LLM has
# written raw-source `ingested: true` updates, new pages under
# `.rite/wiki/pages/**`, index.md updates, and log.md appendices
# directly into the worktree tree.
#
# Design rationale (Issue #547): this script replaces the Block A/B
# shell contract in ingest.md. Because the worktree lives at a stable
# path alongside the dev-branch tree, there is no need for:
#   - `git stash push -u` (dev-branch work is untouched)
#   - `git checkout wiki` on the dev-branch tree (worktree owns wiki)
#   - `processed_files[]` bash array literal substitution (the LLM
#     writes straight into the worktree path, so `git add .rite/wiki`
#     in the worktree picks up exactly the modified files)
#
# Pair scripts:
#   - `wiki-worktree-setup.sh` — creates the worktree (idempotent)
#   - `wiki-ingest-commit.sh`  — legacy shell-only raw-source committer
#     (still used by review.md / fix.md / close.md Phase X.X.W for
#     raw-source staging, unchanged by this Issue)
#
# Usage:
#   bash wiki-worktree-commit.sh [--message "<msg>"] [--dry-run]
#
# Options:
#   --message MSG   Commit message (default: "chore(wiki): ingest page integration")
#   --dry-run       Report pending changes and target branch but perform no
#                   git operations. Always exits 0.
#
# Output (stdout): one structured status line
#   [wiki-worktree-commit] committed=<N>; branch=<wiki>; head=<sha>[; push=<ok|failed>]
#   [wiki-worktree-commit] committed=0; branch=<wiki>; reason=<no-pending|no-staged-diff|concurrent-invocation>
#
# Exit codes:
#   0  success (committed, or nothing pending)
#   1  environment / argument error (not a git repo, worktree missing, etc.)
#   2  wiki feature disabled (skip)
#   3  git operation failure (add / commit — push NOT included)
#   4  push failed after successful local commit (caller MUST emit
#      wiki_ingest_push_failed sentinel; commit is preserved on the
#      local wiki branch and can be pushed manually with
#      `git -C .rite/wiki-worktree push origin wiki`)
#
# Notes:
#   - All git operations run with `git -C "$worktree_path"` to scope
#     them to the worktree's HEAD. The dev-branch tree is never touched.
#   - Advisory locking via flock ensures parallel invocations
#     (e.g. sprint team-execute) do not race on the same worktree.
#   - Credential prompts are suppressed via GIT_TERMINAL_PROMPT=0 so
#     hook-invoked runs do not hang on missing auth.
# --- END HEADER ---

set -euo pipefail

export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}"

# -----------------------------------------------------------------------
# Option parsing
# -----------------------------------------------------------------------
DRY_RUN=false
COMMIT_MSG="chore(wiki): ingest page integration"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --message)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --message requires a value" >&2
        exit 1
      fi
      COMMIT_MSG="$2"
      shift 2
      ;;
    --help|-h)
      sed -n '/^#/{/# --- END HEADER ---/q;p;}' "$0"
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# Reject commit messages containing newlines or NUL to prevent smuggling
# extra headers into `git commit -m`.
if [[ "$COMMIT_MSG" =~ [$'\n'$'\r'] ]]; then
  echo "ERROR: --message must not contain newline or carriage return" >&2
  exit 1
fi

# -----------------------------------------------------------------------
# Environment sanity
# -----------------------------------------------------------------------
if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "ERROR: not inside a git repository" >&2
  exit 1
fi

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

# Advisory lock (same pattern as wiki-ingest-commit.sh). flock may be
# absent on minimal containers / macOS without util-linux; in that case
# we skip the lock and accept the race (matching legacy behaviour).
if command -v flock >/dev/null 2>&1; then
  if mkdir -p .rite/state 2>/dev/null; then
    exec 9>.rite/state/wiki-worktree-commit.lock
    if ! flock -n 9; then
      echo "[wiki-worktree-commit] committed=0; branch=unknown; reason=concurrent-invocation"
      exit 0
    fi
  else
    echo "WARNING: .rite/state の作成に失敗しました。advisory lock をスキップします" >&2
    echo "  影響: 並列実行時の race を検出できません (best-effort 降格、機能自体は継続)" >&2
  fi
fi

if [[ ! -f "rite-config.yml" ]]; then
  echo "ERROR: rite-config.yml not found at $repo_root" >&2
  exit 1
fi

# -----------------------------------------------------------------------
# rite-config.yml parser (lenient, matches wiki-ingest-commit.sh)
# -----------------------------------------------------------------------
parse_wiki_scalar() {
  local key="$1"
  local section line val
  section=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null || true)
  [[ -z "$section" ]] && return 0
  line=$(printf '%s\n' "$section" | awk -v k="$key" '
    BEGIN { pat = "^[[:space:]]+" k ":" }
    $0 ~ pat { print; exit }
  ' 2>/dev/null || true)
  [[ -z "$line" ]] && return 0
  val=$(printf '%s' "$line" \
    | sed 's/[[:space:]]#.*//' \
    | awk -v k="$key" '{
        sub("^[[:space:]]*" k ":[[:space:]]*", "")
        print
      }' \
    | tr -d '[:space:]"'"'")
  printf '%s' "$val"
}

wiki_enabled_raw=$(parse_wiki_scalar enabled)
wiki_enabled_norm=$(printf '%s' "$wiki_enabled_raw" | tr '[:upper:]' '[:lower:]')
case "$wiki_enabled_norm" in
  false|no|0)
    echo "[wiki-worktree-commit] committed=0; branch=unknown; reason=wiki-disabled"
    exit 2
    ;;
esac

wiki_branch=$(parse_wiki_scalar branch_name)
wiki_branch="${wiki_branch:-wiki}"

# Reject unsafe branch names (mirrors wiki-ingest-commit.sh MEDIUM #6 fix).
if [[ -z "$wiki_branch" ]] || [[ "$wiki_branch" == -* ]] || \
   [[ ! "$wiki_branch" =~ ^[A-Za-z0-9._/-]+$ ]]; then
  echo "ERROR: invalid wiki.branch_name '${wiki_branch}' in rite-config.yml" >&2
  exit 1
fi

# -----------------------------------------------------------------------
# Verify the worktree exists at the expected path and is on wiki_branch.
# -----------------------------------------------------------------------
worktree_path=".rite/wiki-worktree"
abs_worktree="${repo_root}/${worktree_path}"

if [[ ! -d "$worktree_path" ]]; then
  echo "ERROR: worktree '$worktree_path' does not exist" >&2
  echo "  hint: run 'bash plugins/rite/hooks/scripts/wiki-worktree-setup.sh' first" >&2
  exit 1
fi

# Confirm the worktree HEAD points to wiki_branch. A misaligned worktree
# (e.g. user ran `git -C .rite/wiki-worktree checkout develop` by hand)
# would otherwise route wiki commits onto the wrong branch.
wt_head=$(git -C "$worktree_path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
if [[ "$wt_head" != "$wiki_branch" ]]; then
  echo "ERROR: worktree at '$worktree_path' is on branch '$wt_head', expected '$wiki_branch'" >&2
  echo "  hint: git -C '$worktree_path' checkout '$wiki_branch'" >&2
  exit 1
fi

# -----------------------------------------------------------------------
# Detect pending changes within the worktree's .rite/wiki tree.
# We intentionally scope to the wiki directory so unrelated worktree
# state (e.g. a stray file left by a contributor) does not accidentally
# end up in wiki commits.
# -----------------------------------------------------------------------
wiki_rel=".rite/wiki"

has_unstaged=false
has_untracked=false

set +e
git -C "$worktree_path" diff --quiet -- "$wiki_rel"
diff_rc=$?
set -e
case "$diff_rc" in
  0) ;;
  1) has_unstaged=true ;;
  *)
    echo "ERROR: git diff on worktree failed (rc=$diff_rc)" >&2
    exit 3
    ;;
esac

untracked=$(git -C "$worktree_path" ls-files --others --exclude-standard -- "$wiki_rel" 2>/dev/null || true)
if [[ -n "$untracked" ]]; then
  has_untracked=true
fi

# Also detect already-staged (rare — normally the LLM writes unstaged files,
# but guard against operators who pre-staged content).
set +e
git -C "$worktree_path" diff --cached --quiet -- "$wiki_rel"
cached_rc=$?
set -e
has_staged=false
case "$cached_rc" in
  0) ;;
  1) has_staged=true ;;
  *)
    echo "ERROR: git diff --cached on worktree failed (rc=$cached_rc)" >&2
    exit 3
    ;;
esac

if [[ "$has_unstaged" == "false" ]] && [[ "$has_untracked" == "false" ]] && [[ "$has_staged" == "false" ]]; then
  echo "[wiki-worktree-commit] committed=0; branch=${wiki_branch}; reason=no-pending"
  exit 0
fi

if [[ "$DRY_RUN" == "true" ]]; then
  echo "[wiki-worktree-commit] dry-run; branch=${wiki_branch}; unstaged=${has_unstaged}; untracked=${has_untracked}; staged=${has_staged}"
  if [[ "$has_untracked" == "true" ]]; then
    printf '%s\n' "$untracked" | sed 's/^/  + /'
  fi
  if [[ "$has_unstaged" == "true" ]]; then
    git -C "$worktree_path" diff --name-only -- "$wiki_rel" | sed 's/^/  M /'
  fi
  exit 0
fi

# -----------------------------------------------------------------------
# Stage all changes under .rite/wiki and commit.
# -----------------------------------------------------------------------
if ! git -C "$worktree_path" add -- "$wiki_rel" >/dev/null 2>&1; then
  echo "ERROR: git add '$wiki_rel' failed in worktree" >&2
  exit 3
fi

# Re-check staged diff (the `add` may have staged zero files if everything
# was already in the working index but matched .gitignore — defensive).
set +e
git -C "$worktree_path" diff --cached --quiet
post_add_rc=$?
set -e
case "$post_add_rc" in
  0)
    echo "[wiki-worktree-commit] committed=0; branch=${wiki_branch}; reason=no-staged-diff"
    exit 0
    ;;
  1) ;; # staged diff present, proceed
  *)
    echo "ERROR: git diff --cached after add failed (rc=$post_add_rc)" >&2
    exit 3
    ;;
esac

if ! git -C "$worktree_path" commit --quiet -m "$COMMIT_MSG" 2>/dev/null; then
  echo "ERROR: git commit failed in worktree" >&2
  exit 3
fi

committed_sha=$(git -C "$worktree_path" rev-parse HEAD 2>/dev/null || echo unknown)

# -----------------------------------------------------------------------
# Push with incident-observable failure semantics (exit 4).
# Mirrors wiki-ingest-commit.sh CRITICAL #1 fix.
# -----------------------------------------------------------------------
push_status="ok"
push_failed=false

push_err=""
trap 'rm -f "${push_err:-}"' EXIT INT TERM HUP
push_err=$(mktemp /tmp/rite-wwc-push-err-XXXXXX 2>/dev/null || echo "")

if ! git -C "$worktree_path" push --quiet origin "$wiki_branch" 2>"${push_err:-/dev/null}"; then
  push_status="failed"
  push_failed=true
  echo "WARNING: git push origin '$wiki_branch' failed — commit is local only" >&2
  if [[ -n "$push_err" ]] && [[ -s "$push_err" ]]; then
    head -n 10 "$push_err" | sed 's/^/  git: /' >&2
  fi
  echo "  manual recovery: git -C '$worktree_path' push origin '$wiki_branch'" >&2
fi

[[ -n "$push_err" ]] && rm -f "$push_err"
trap - EXIT INT TERM HUP

echo "[wiki-worktree-commit] committed=1; branch=${wiki_branch}; head=${committed_sha}; push=${push_status}"

if [[ "$push_failed" == "true" ]]; then
  exit 4
fi
exit 0
