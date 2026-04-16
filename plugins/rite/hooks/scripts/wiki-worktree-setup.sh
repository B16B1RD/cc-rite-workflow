#!/bin/bash
# rite workflow - Wiki Worktree Setup (idempotent)
#
# Responsibility: ensure `.rite/wiki-worktree` is a valid git worktree
# checked out to the configured `wiki.branch_name`. Idempotent — running
# this script repeatedly is safe and cheap.
#
# Design rationale (Issue #547): the legacy Block A/B pattern in
# commands/wiki/ingest.md relied on `git stash + git checkout wiki` on
# the current working tree, which loses access to the dev-branch
# `plugins/rite/templates/wiki/page-template.md` during the LLM
# Write/Edit phase. A dedicated worktree keeps the dev-branch tree
# intact and still gives ingest.md a writable wiki-branch tree at a
# stable relative path.
#
# Usage:
#   bash wiki-worktree-setup.sh
#
# Output (stdout): one structured status line ending with a newline
#   [wiki-worktree-setup] status=<created|already|skipped|failed>; path=<abs-path>; branch=<wiki-branch>
#
# Exit codes:
#   0  worktree is now ready (either newly created OR already present)
#   1  environment / argument error (not a git repo, rite-config missing, etc.)
#   2  wiki feature disabled OR wiki branch not present locally (skip)
#   3  `git worktree add` failed (filesystem / permission / git error)
#
# Notes:
#   - The target path is always `.rite/wiki-worktree` relative to the
#     repository root. It must be ignored via `.gitignore` so the
#     worktree metadata file (`.rite/wiki-worktree/.git`) does not
#     pollute dev-branch diffs.
#   - The script does NOT fetch from origin. If the wiki branch only
#     exists remotely, the caller (e.g. /rite:wiki:init) is responsible
#     for running `git fetch origin wiki:wiki` first.
#   - The script does NOT prune stale worktrees. If `.rite/wiki-worktree`
#     was previously deleted without `git worktree remove`, run
#     `git worktree prune` manually before re-invoking this script.

set -euo pipefail

export GIT_TERMINAL_PROMPT=0
# Mirror wiki-worktree-commit.sh: avoid hangs on hosts without an ssh agent.
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}"

# -----------------------------------------------------------------------
# Environment sanity
# -----------------------------------------------------------------------
if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "ERROR: not inside a git repository" >&2
  exit 1
fi

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

# Advisory lock to serialise concurrent setup invocations against the
# same repository (mirrors wiki-worktree-commit.sh / wiki-ingest-commit.sh
# pattern). `git worktree add` is not safe to race against itself: two
# parallel invocations can both pass the idempotency check (line 140-149)
# and then conflict on the actual `git worktree add` call.
#
# `exec 8>...` は set -euo pipefail 配下で permission denied / disk full /
# read-only filesystem 等の I/O エラーで script 全体を hard fail させる。
# lock 機能自体が best-effort であるため、flock 不在経路 (legacy 互換) と
# 挙動を揃えるため、サブシェル経由で `exec` の失敗を捕捉し、失敗時は
# WARNING のみで継続する (wiki-worktree-commit.sh L113-138 と同型のパターン)。
if command -v flock >/dev/null 2>&1; then
  if mkdir -p .rite/state 2>/dev/null; then
    if ( exec 8>.rite/state/wiki-worktree-setup.lock ) 2>/dev/null; then
      exec 8>.rite/state/wiki-worktree-setup.lock
      if ! flock -n 8; then
        echo "[wiki-worktree-setup] status=skipped; path=-; branch=-; reason=concurrent-invocation"
        exit 0
      fi
    else
      echo "WARNING: .rite/state/wiki-worktree-setup.lock を open できませんでした (permission / read-only fs)" >&2
      echo "  影響: 並列 setup 時の race を検出できません (best-effort 降格、機能自体は継続)" >&2
    fi
  else
    echo "WARNING: .rite/state の作成に失敗しました。advisory lock をスキップします" >&2
    echo "  影響: 並列 setup 時の race を検出できません (best-effort 降格、機能自体は継続)" >&2
  fi
fi

if [[ ! -f "rite-config.yml" ]]; then
  echo "ERROR: rite-config.yml not found at $repo_root" >&2
  echo "  hint: run /rite:init first" >&2
  exit 1
fi

# -----------------------------------------------------------------------
# rite-config.yml parser + branch name validator (shared lib, Issue #549)
# -----------------------------------------------------------------------
# shellcheck source=lib/wiki-config.sh
source "$(dirname "$0")/lib/wiki-config.sh"

wiki_enabled_raw=$(parse_wiki_scalar enabled)
wiki_enabled_norm=$(printf '%s' "$wiki_enabled_raw" | tr '[:upper:]' '[:lower:]')
case "$wiki_enabled_norm" in
  false|no|0)
    echo "[wiki-worktree-setup] status=skipped; path=-; branch=-; reason=wiki-disabled"
    exit 2
    ;;
esac

wiki_branch=$(parse_wiki_scalar branch_name)
wiki_branch="${wiki_branch:-wiki}"

validate_wiki_branch_name "$wiki_branch" || exit 1

# -----------------------------------------------------------------------
# Verify the wiki branch exists locally. Remote-only existence is a skip.
# -----------------------------------------------------------------------
if ! git show-ref --verify --quiet "refs/heads/${wiki_branch}"; then
  echo "[wiki-worktree-setup] status=skipped; path=-; branch=${wiki_branch}; reason=commit_branch_missing"
  echo "  hint (run one of these, in order of preference):" >&2
  echo "    1) git fetch origin ${wiki_branch}:${wiki_branch}" >&2
  echo "    2) /rite:wiki:init" >&2
  exit 2
fi

target_path=".rite/wiki-worktree"
abs_target="${repo_root}/${target_path}"

# -----------------------------------------------------------------------
# Idempotency: detect existing worktree at `.rite/wiki-worktree`.
#
# `git worktree list --porcelain` emits records like:
#   worktree /abs/path
#   HEAD <sha>
#   branch refs/heads/<name>
#   prunable gitdir file points to non-existent location  ← optional
# separated by blank lines. We match on the `worktree ` line for an
# absolute-path exact match, then on the subsequent `branch ` line to
# confirm the checked-out branch matches `wiki_branch`. Additionally
# detect `prunable` markers so that phantom worktrees (when the user
# `rm -rf .rite/wiki-worktree/` per cleanup.md Phase 2.6 manual step)
# are not silently treated as healthy (cycle 2 MEDIUM F-10 fix).
#
# `git worktree list` の stderr を tempfile に capture して、corrupt
# `.git/worktrees/` / permission denied / git binary 異常を silent に
# 握り潰さない (cycle 2 MEDIUM F-11 fix)。
wt_list_err=""
trap 'rm -f "${wt_list_err:-}"' EXIT INT TERM HUP
wt_list_err=$(mktemp /tmp/rite-wts-list-err-XXXXXX 2>/dev/null) || wt_list_err=""

existing_line=""
existing_branch=""
existing_prunable=false
if wt_list=$(git worktree list --porcelain 2>"${wt_list_err:-/dev/null}"); then
  existing_line=$(printf '%s\n' "$wt_list" | awk -v p="$abs_target" '
    $1 == "worktree" && $2 == p { found = 1; next }
    found && $1 == "branch" { print $2; next }
    found && $1 == "prunable" { print "PRUNABLE"; exit }
    found && /^$/ { exit }
  ')
  if [[ "$existing_line" == *"PRUNABLE"* ]]; then
    existing_prunable=true
    # Strip the PRUNABLE marker to get the actual branch (if listed before)
    existing_branch=$(printf '%s\n' "$existing_line" | grep -v '^PRUNABLE$' | head -1)
    existing_branch="${existing_branch#refs/heads/}"
  else
    existing_branch="${existing_line#refs/heads/}"
  fi
else
  wt_list_rc=$?
  echo "WARNING: git worktree list --porcelain が失敗しました (rc=$wt_list_rc)" >&2
  if [ -n "$wt_list_err" ] && [ -s "$wt_list_err" ]; then
    head -3 "$wt_list_err" | sed 's/^/  git: /' >&2
  fi
  echo "  原因候補: corrupt .git/worktrees/ / permission denied / git binary 異常" >&2
  echo "  影響: idempotency check が空結果として進み、後段の git worktree add で初めて顕在化する可能性" >&2
fi

if [[ "$existing_prunable" == "true" ]]; then
  # phantom worktree (rm -rf でディレクトリ削除済み、metadata は dangling)
  echo "WARNING: phantom worktree を検出しました ('$abs_target' の git metadata は残存、ディレクトリは不在)" >&2
  echo "  自動回復: git worktree prune で metadata を整理してから worktree を再作成します" >&2
  if ! git worktree prune 2>"${wt_list_err:-/dev/null}"; then
    echo "ERROR: git worktree prune に失敗しました" >&2
    if [ -n "$wt_list_err" ] && [ -s "$wt_list_err" ]; then
      head -3 "$wt_list_err" | sed 's/^/  git: /' >&2
    fi
    echo "  手動回復: git worktree prune を直接実行してから本 script を再実行してください" >&2
    exit 3
  fi
  # prune 後は worktree が存在しないとみなして新規作成パスへ進む
  existing_branch=""
elif [[ -n "$existing_branch" ]]; then
  if [[ "$existing_branch" == "$wiki_branch" ]]; then
    [ -n "$wt_list_err" ] && rm -f "$wt_list_err"
    trap - EXIT INT TERM HUP
    echo "[wiki-worktree-setup] status=already; path=${abs_target}; branch=${wiki_branch}"
    exit 0
  fi
  # Unexpected: worktree exists but on the wrong branch.
  echo "ERROR: worktree at '$target_path' is checked out to '$existing_branch', expected '$wiki_branch'" >&2
  echo "  manual recovery: git worktree remove '$target_path' && re-run this script" >&2
  exit 3
fi
[ -n "$wt_list_err" ] && rm -f "$wt_list_err"
trap - EXIT INT TERM HUP

# -----------------------------------------------------------------------
# Create the worktree. Parent directory may already exist (e.g. because
# `.rite/review-results/` is populated). Use `git worktree add` without
# `-b` since the branch already exists.
# -----------------------------------------------------------------------
mkdir -p "$(dirname "$target_path")"

# Capture stderr so add failures report a meaningful reason.
add_err=""
trap 'rm -f "${add_err:-}"' EXIT INT TERM HUP
# mktemp 失敗 (read-only /tmp / inode 枯渇 / permission denied) を silent に握り潰さず
# WARNING で可視化する (wiki-ingest-commit.sh:559-564 の対称パターン)。
if ! add_err=$(mktemp /tmp/rite-wts-err-XXXXXX 2>/dev/null); then
  echo "WARNING: mktemp for add_err failed — git worktree add stderr will not be captured for diagnostics" >&2
  echo "  hint: /tmp permission / disk space / inode exhaustion を確認してください" >&2
  add_err=""
fi

if ! git worktree add --quiet "$target_path" "$wiki_branch" 2>"${add_err:-/dev/null}"; then
  echo "ERROR: git worktree add '$target_path' '$wiki_branch' failed" >&2
  if [[ -n "$add_err" ]] && [[ -s "$add_err" ]]; then
    head -n 10 "$add_err" | sed 's/^/  git: /' >&2
  fi
  echo "  hint: ensure the wiki branch is not already checked out elsewhere (git worktree list)" >&2
  exit 3
fi

# trap action を本 add 用 add_err 削除のみに絞ってリセットすることで、将来別 trap が
# 追加された場合に他 cleanup を巻き込まないようにする。
[[ -n "$add_err" ]] && rm -f "$add_err"
add_err=""
trap - EXIT INT TERM HUP

echo "[wiki-worktree-setup] status=created; path=${abs_target}; branch=${wiki_branch}"
exit 0
