#!/bin/bash
# rite workflow - Wiki Worktree Commit (worktree-based page integration)
#
# Responsibility: commit pending changes in the `.rite/wiki-worktree`
# worktree (checked out to the configured `wiki.branch_name`) and push
# to origin. Used by skills/wiki-ingest/SKILL.md ステップ 5 after the LLM has
# written raw-source `ingested: true` updates, new pages under
# `.rite/wiki/pages/**`, index.md updates, and log.md appendices
# directly into the worktree tree. `--commit-only` / `--push-only` (
# wiki push batch/defer) split this into two calls so a caller looping over
# several raw sources (wiki-ingest) or delegating to wiki-lint mid-flow can
# commit each one locally and push ONCE at the end of the flow, instead of
# once per commit — see skills/wiki-ingest/SKILL.md ステップ 5.1 / 8.6 and
# skills/wiki-lint/SKILL.md ステップ 8.3.
#
# Design rationale: this script replaces the Block A/B
# shell contract in ingest.md. Because the worktree lives at a stable
# path alongside the dev-branch tree, there is no need for:
# - `git stash push -u` (dev-branch work is untouched)
# - `git checkout wiki` on the dev-branch tree (worktree owns wiki)
# - `processed_files[]` bash array literal substitution (the LLM
# writes straight into the worktree path, so `git add .rite/wiki`
# in the worktree picks up exactly the modified files)
#
# Pair scripts:
# - `wiki-worktree-setup.sh` — creates the worktree (idempotent)
# - `wiki-ingest-commit.sh` — legacy shell-only raw-source committer
# (still used by pr-review.md / fix.md / close.md Phase X.X.W for
# raw-source staging, unchanged by this Issue)
#
# Usage:
# bash wiki-worktree-commit.sh [--message "<msg>"] [--dry-run]
# bash wiki-worktree-commit.sh --commit-only [--message "<msg>"]
# bash wiki-worktree-commit.sh --push-only
#
# Options:
# --message MSG Commit message (default: "chore(wiki): ingest page integration")
# --dry-run Report pending changes and target branch but perform no
# git operations. Always exits 0. Not valid with --push-only
# (push-only has no "pending changes" to report — it pushes
# whatever is already committed).
# --commit-only Stage + commit pending changes but do NOT push (wiki
# push batch/defer). Intended for a caller processing several
# raw sources in a loop: commit each one locally, then push
# ONCE via --push-only after the loop. Mutually exclusive with
# --push-only.
# --push-only Push whatever is already committed on the worktree's branch;
# does not stage or commit anything. Self-gates on "nothing to
# push" (no-op, no network call) — safe to call unconditionally
# at the end of a --commit-only loop. Mutually exclusive with
# --commit-only and --dry-run.
#
# Output (stdout): one structured status line
# [wiki-worktree-commit] committed=<N>; branch=<wiki>; head=<sha>[; push=<ok|failed>]
# [wiki-worktree-commit] committed=1; branch=<wiki>; head=<sha>; push=deferred   (--commit-only)
# [wiki-worktree-commit] branch=<wiki>; head=<sha>; push=<ok|failed|no-op>       (--push-only)
# [wiki-worktree-commit] committed=0; branch=<wiki>; reason=<no-pending|no-staged-diff|concurrent-invocation>
#
# Exit codes:
# 0 success (committed and/or pushed, or nothing pending/to push)
# 1 environment / argument error (not a git repo, worktree missing, etc.)
# 2 wiki feature disabled (skip)
# 3 git operation failure (add / commit — push NOT included)
# 4 push failed (caller MUST emit wiki_ingest_push_failed sentinel;
# commit is preserved on the local wiki branch and can be pushed
# manually with `git -C .rite/wiki-worktree push origin wiki`).
# Not reachable with --commit-only (no push is attempted).
#
# Notes:
# - All git operations run with `git -C "$worktree_path"` to scope
# them to the worktree's HEAD. The dev-branch tree is never touched.
# - Advisory locking via flock ensures parallel invocations
# (e.g. multiple concurrent sessions) do not race on the same worktree.
# - Credential prompts are suppressed via GIT_TERMINAL_PROMPT=0 so
# hook-invoked runs do not hang on missing auth.
# --- END HEADER ---

set -euo pipefail

export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}"

# -----------------------------------------------------------------------
# Option parsing
# -----------------------------------------------------------------------
DRY_RUN=false
COMMIT_ONLY=false
PUSH_ONLY=false
COMMIT_MSG="chore(wiki): ingest page integration"
while [[ $# -gt 0 ]]; do
 case "$1" in
 --dry-run)
 DRY_RUN=true
 shift
 ;;
 --commit-only)
 COMMIT_ONLY=true
 shift
 ;;
 --push-only)
 PUSH_ONLY=true
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

if [[ "$COMMIT_ONLY" == "true" ]] && [[ "$PUSH_ONLY" == "true" ]]; then
 echo "ERROR: --commit-only and --push-only are mutually exclusive" >&2
 exit 1
fi
if [[ "$PUSH_ONLY" == "true" ]] && [[ "$DRY_RUN" == "true" ]]; then
 echo "ERROR: --push-only and --dry-run are mutually exclusive (push-only has no pending changes to preview)" >&2
 exit 1
fi

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

# Resolve the canonical lib path BEFORE `cd`. See wiki-worktree-setup.sh
# for rationale — `$(dirname "$0")` after `cd` breaks under relative
# invocation paths.
_SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../control-char-neutralize.sh
source "$_SCRIPT_DIR/../control-char-neutralize.sh"

# Resolve to the SHARED state root (main checkout). See wiki-worktree-setup.sh
# for rationale — a linked-worktree session must land its wiki worktree + flock
# on the main checkout's single inode (multi-session design §1). Byte-identical
# to `git rev-parse --show-toplevel` for non-worktree sessions.
repo_root=$("$_SCRIPT_DIR/../state-path-resolve.sh" 2>/dev/null) || repo_root=""
[ -n "$repo_root" ] || repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

# Advisory lock (same pattern as wiki-ingest-commit.sh). flock may be
# absent on minimal containers / macOS without util-linux; in that case
# we skip the lock and accept the race (matching legacy behaviour).
#
# `exec 9>...` は set -euo pipefail 配下で permission denied / disk full /
# read-only filesystem 等の I/O エラー発生時に script 全体を hard fail
# させる。lock 機能自体が best-effort であるため、ここで hard fail させて
# しまうと flock 不在経路 (legacy 互換) との挙動が大きく食い違う。
# サブシェル経由で `exec` の失敗を捕捉し、失敗時は WARNING のみで継続する。
if command -v flock >/dev/null 2>&1; then
 if mkdir -p .rite/state 2>/dev/null; then
 if ( exec 9>.rite/state/wiki-worktree-commit.lock ) 2>/dev/null; then
 exec 9>.rite/state/wiki-worktree-commit.lock
 if ! flock -n 9; then
 # branch=unknown は意図的: lock 取得前に rite-config.yml をパースしておらず
 # wiki_branch が未確定のため、既存の concurrent-invocation 終了経路と
 # 整合させる目的で固定値 unknown を出力する (機械パース側は branch 値
 # ではなく reason=concurrent-invocation で routing する)。
 echo "[wiki-worktree-commit] committed=0; branch=unknown; reason=concurrent-invocation"
 exit 0
 fi
 else
 echo "WARNING: .rite/state/wiki-worktree-commit.lock を open できませんでした (permission / read-only fs)" >&2
 echo " 影響: 並列実行時の race を検出できません (best-effort 降格、機能自体は継続)" >&2
 fi
 else
 echo "WARNING: .rite/state の作成に失敗しました。advisory lock をスキップします" >&2
 echo " 影響: 並列実行時の race を検出できません (best-effort 降格、機能自体は継続)" >&2
 fi
fi

if [[ ! -f "rite-config.yml" ]]; then
 echo "ERROR: rite-config.yml not found at $repo_root" >&2
 exit 1
fi

# -----------------------------------------------------------------------
# Shared lib: parser/validator + worktree add/commit/push helper.
# -----------------------------------------------------------------------
# shellcheck source=lib/wiki-config.sh
source "$_SCRIPT_DIR/lib/wiki-config.sh"
# shellcheck source=lib/worktree-git.sh
source "$_SCRIPT_DIR/lib/worktree-git.sh"

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

validate_wiki_branch_name "$wiki_branch" || exit 1

# -----------------------------------------------------------------------
# Verify the worktree exists at the expected path and is on wiki_branch.
# -----------------------------------------------------------------------
worktree_path=".rite/wiki-worktree"
abs_worktree="${repo_root}/${worktree_path}"

if [[ ! -d "$worktree_path" ]]; then
 echo "ERROR: worktree '$worktree_path' does not exist" >&2
 echo " hint: run 'bash plugins/rite/hooks/scripts/wiki-worktree-setup.sh' first" >&2
 exit 1
fi

# Confirm the worktree HEAD points to wiki_branch. A misaligned worktree
# (e.g. user ran `git -C .rite/wiki-worktree checkout develop` by hand)
# would otherwise route wiki commits onto the wrong branch.
# rev-parse + stderr capture + branch compare は
# lib/worktree-git.sh の verify_worktree_branch() に統合済み。
verify_worktree_branch "$worktree_path" "$wiki_branch" "wwc" "" || exit 1

# -----------------------------------------------------------------------
# --push-only: push whatever is already committed and return. No staging,
# no commit, no "pending changes" detection — that concept does not apply
# here (wiki push batch/defer).
# -----------------------------------------------------------------------
if [[ "$PUSH_ONLY" == "true" ]]; then
 set +e
 push_out=$(worktree_push_branch "$worktree_path" "$wiki_branch")
 push_rc=$?
 set -e
 echo "[wiki-worktree-commit] branch=${wiki_branch}; ${push_out}"
 case "$push_rc" in
 0) exit 0 ;;
 4) exit 4 ;;
 *)
 echo "ERROR: worktree_push_branch が予期しない exit code ($push_rc) を返しました" >&2
 exit 1
 ;;
 esac
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

# `|| true` で silent に握り潰さず、IO error / permission denied / broken worktree
# の場合は WARNING + exit 3 で fail-fast する (cycle 2 MEDIUM F-12 fix)。
# `|| true` で `untracked=""` → `has_untracked=false` に倒すと、本来検出すべき untracked を
# silent miss し、`reason=no-pending` で skip してしまう経路が生じる。
lsf_err=""
trap 'rm -f "${lsf_err:-}"' EXIT INT TERM HUP
lsf_err=$(mktemp "${TMPDIR:-/tmp}/rite-wwc-lsf-err-XXXXXX" 2>/dev/null) || lsf_err=""
set +e
untracked=$(git -C "$worktree_path" ls-files --others --exclude-standard -- "$wiki_rel" 2>"${lsf_err:-/dev/null}")
lsf_rc=$?
set -e
if [ "$lsf_rc" -ne 0 ]; then
 echo "ERROR: git -C '$worktree_path' ls-files --others が失敗しました (rc=$lsf_rc)" >&2
 if [ -n "$lsf_err" ] && [ -s "$lsf_err" ]; then
 head -3 "$lsf_err" | neutralize_ctrl --keep-newline | sed 's/^/ git: /' >&2
 fi
 echo " 原因候補: broken worktree (.git file 破損) / permission denied / git binary 異常" >&2
 echo " 影響: untracked file 検出が skip されると pending change を誤って 'なし' と判定する経路があるため fail-fast" >&2
 [ -n "$lsf_err" ] && rm -f "$lsf_err"
 exit 3
fi
[ -n "$lsf_err" ] && rm -f "$lsf_err"
trap - EXIT INT TERM HUP
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

# Collapse the 3 detection booleans into a single `has_changes` for the
# early-exit decision (matches wiki-ingest-commit.sh `has_changes` pattern).
# We keep the granular booleans for the DRY_RUN diagnostic block below
# because their per-category visibility is genuinely useful when an
# operator inspects what would be committed.
has_changes=false
if [[ "$has_unstaged" == "true" ]] || [[ "$has_untracked" == "true" ]] || [[ "$has_staged" == "true" ]]; then
 has_changes=true
fi

if [[ "$has_changes" == "false" ]]; then
 echo "[wiki-worktree-commit] committed=0; branch=${wiki_branch}; reason=no-pending"
 exit 0
fi

if [[ "$DRY_RUN" == "true" ]]; then
 echo "[wiki-worktree-commit] dry-run; branch=${wiki_branch}; unstaged=${has_unstaged}; untracked=${has_untracked}; staged=${has_staged}"
 if [[ "$has_untracked" == "true" ]]; then
 printf '%s\n' "$untracked" | sed 's/^/ + /'
 fi
 if [[ "$has_unstaged" == "true" ]]; then
 git -C "$worktree_path" diff --name-only -- "$wiki_rel" | sed 's/^/ M /'
 fi
 exit 0
fi

# -----------------------------------------------------------------------
# Stage all changes under .rite/wiki, commit, and (unless --commit-only)
# push via shared helper. worktree_commit_push (lib/worktree-git.sh)
# handles the stderr capture + head -n 10 extraction pattern for the
# caller. Exit codes: 3 = add/commit failure, 4 = commit ok / push failed
# (--commit-only never returns 4 — no push is attempted), 5 = no staged
# diff after add (no-op).
# -----------------------------------------------------------------------
set +e
if [[ "$COMMIT_ONLY" == "true" ]]; then
 wtcp_out=$(WTGP_COMMIT_ONLY=1 worktree_commit_push "$worktree_path" "$wiki_branch" "$COMMIT_MSG" "$wiki_rel")
else
 wtcp_out=$(worktree_commit_push "$worktree_path" "$wiki_branch" "$COMMIT_MSG" "$wiki_rel")
fi
wtcp_rc=$?
set -e

case "$wtcp_rc" in
 0)
 if [[ "$COMMIT_ONLY" == "true" ]]; then
 # wtcp_out = "head=<sha>" — push is deferred to a later --push-only call
 echo "[wiki-worktree-commit] committed=1; branch=${wiki_branch}; ${wtcp_out}; push=deferred"
 else
 # wtcp_out = "head=<sha>; push=ok"
 echo "[wiki-worktree-commit] committed=1; branch=${wiki_branch}; ${wtcp_out}"
 fi
 exit 0
 ;;
 4)
 echo "[wiki-worktree-commit] committed=1; branch=${wiki_branch}; ${wtcp_out}"
 exit 4
 ;;
 5)
 echo "[wiki-worktree-commit] committed=0; branch=${wiki_branch}; reason=no-staged-diff"
 exit 0
 ;;
 *)
 # 3 (add/commit failed) or anything unexpected — error already on stderr
 exit 3
 ;;
esac
