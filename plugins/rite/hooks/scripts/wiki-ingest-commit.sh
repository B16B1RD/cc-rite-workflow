#!/bin/bash
# rite workflow - Wiki Ingest Commit (shell-only raw source commit path)
#
# Responsibility: commit all pending raw source files under .rite/wiki/raw/
# to the configured wiki branch in a SINGLE shell process, without any
# dependency on Claude orchestrator multi-step execution.
#
# Pair script: `../wiki-ingest-trigger.sh` (in plugins/rite/hooks/, not in
# hooks/scripts/). The trigger is a pure file writer that stages raw
# sources under `.rite/wiki/raw/{type}/`; this script is the shell
# committer that moves those files onto the wiki branch. Grep for
# `wiki-ingest-trigger.sh` when auditing the wiki capture / commit path.
# The two scripts form a tightly-coupled pair despite living in different
# directories (the placement asymmetry is a transitional state tracked
# for future cleanup — both should eventually live in hooks/scripts/).
#
# This script is the shell-only counterpart of commands/wiki/ingest.md
# Phase 5.1 Block A + Block B. It exists because the markdown-based Phase
# 5.1 requires Claude to chain three Bash tool invocations across an LLM
# Write/Edit phase, which is structurally fragile under E2E output
# minimization and sub-skill auto-continuation failures (Issue #525, and
# the repeated but ineffective silent-skip defence layers of #515, #518,
# #524). By moving the git stash/checkout/commit/push sequence into a
# single shell script, the raw source always lands on the wiki branch as
# long as this script is invoked even once — regardless of whether Claude
# correctly continues its prose contract afterwards.
#
# Scope boundary: this script commits raw sources only. It does NOT run
# the LLM-driven page integration (Phase 4 / Phase 5.0 steps 3-6 of
# ingest.md). Wiki page integration remains the responsibility of the
# /rite:wiki:ingest Skill and can be executed at a later time, either
# automatically or manually. The split enforces a clean separation:
#
#   (1) raw source capture       — wiki-ingest-trigger.sh (file writer)
#   (2) raw source commit path   — THIS script (shell, deterministic)
#   (3) wiki page integration    — /rite:wiki:ingest (LLM)
#
# Steps (1) and (2) together guarantee that the wiki branch grows for
# every review/fix/close cycle, even if step (3) is deferred.
#
# Usage:
#   bash wiki-ingest-commit.sh [--dry-run]
#
# Options:
#   --dry-run   Report the pending raw sources and the target wiki branch
#               but perform no git operations. Returns exit 0 even when
#               pending sources exist (unlike the normal path).
#
# Exit codes:
#   0  success (pending raw sources were committed, OR there were none)
#   1  argument / environment error (not a git repo, detached HEAD, etc.)
#   2  wiki feature disabled or wiki branch missing (treated as skip)
#   3  git operation failure (stash / checkout / commit / push)
#
# Notes:
#   - Designed to be idempotent: when called with no pending raw sources,
#     it exits 0 without touching git state.
#   - Preserves any unrelated uncommitted work in the current branch via
#     full `git stash push -u`, and pops the stash afterwards.
#   - The current branch is always restored before exit, via cleanup trap,
#     even on signal (INT/TERM/HUP) or error.
#   - Emits a structured status line to stdout on success so the caller
#     (review.md / fix.md / close.md Phase X.X.W) can observe the result:
#       [wiki-ingest-commit] committed=<N>; branch=<wiki>; head=<sha>
#     or when there is nothing to do:
#       [wiki-ingest-commit] committed=0; branch=<wiki>; reason=no-pending
# --- END HEADER ---

set -euo pipefail

# -----------------------------------------------------------------------
# Option parsing
# -----------------------------------------------------------------------
DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --help|-h)
      # Extract header block up to the `--- END HEADER ---` sentinel so the
      # help text never drifts out of sync with the documented surface.
      sed -n '/^#/{/# --- END HEADER ---/q;p;}' "$0"
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# -----------------------------------------------------------------------
# Environment sanity
# -----------------------------------------------------------------------
if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "ERROR: not inside a git repository" >&2
  exit 1
fi

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

if [[ ! -f "rite-config.yml" ]]; then
  echo "ERROR: rite-config.yml not found at $repo_root" >&2
  echo "  hint: run /rite:init first" >&2
  exit 1
fi

# -----------------------------------------------------------------------
# rite-config.yml: wiki.enabled / wiki.branch_name / wiki.branch_strategy
#
# Same lenient YAML parsing approach as wiki-ingest-trigger.sh and
# ingest.md Phase 1.1 (awk + inline-comment strip + quote strip).
# -----------------------------------------------------------------------
parse_wiki_scalar() {
  # $1 = key name (e.g. "enabled" / "branch_name" / "branch_strategy")
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
    | sed "s/.*${key}:[[:space:]]*//" \
    | tr -d '[:space:]"'"'")
  printf '%s' "$val"
}

wiki_enabled_raw=$(parse_wiki_scalar enabled)
wiki_enabled_norm=$(printf '%s' "$wiki_enabled_raw" | tr '[:upper:]' '[:lower:]')
case "$wiki_enabled_norm" in
  false|no|0)
    echo "[wiki-ingest-commit] skipped; reason=wiki-disabled" >&2
    exit 2
    ;;
esac

wiki_branch=$(parse_wiki_scalar branch_name)
wiki_branch="${wiki_branch:-wiki}"

# MEDIUM #6 (git option injection via branch_name): validate that the
# configured branch name is a safe git ref. Without this guard, a
# rite-config.yml entry like `branch_name: "--upload-pack=foo"` would be
# interpreted by subsequent `git` commands as an option flag rather than
# a ref. We restrict to the common ref-name alphabet and forbid leading
# dashes explicitly. Combined with the per-command `git show-ref --verify
# refs/heads/...` style below, this is defence-in-depth.
if [[ -z "$wiki_branch" ]] || [[ "$wiki_branch" == -* ]] || \
   [[ ! "$wiki_branch" =~ ^[A-Za-z0-9._/-]+$ ]]; then
  echo "ERROR: invalid wiki.branch_name '${wiki_branch}' in rite-config.yml" >&2
  echo "  allowed: [A-Za-z0-9._/-]+ and must not start with '-'" >&2
  exit 1
fi

branch_strategy=$(parse_wiki_scalar branch_strategy)
branch_strategy="${branch_strategy:-separate_branch}"

case "$branch_strategy" in
  separate_branch|same_branch) ;;
  *)
    echo "ERROR: unknown wiki.branch_strategy in rite-config.yml: '$branch_strategy'" >&2
    exit 1
    ;;
esac

# -----------------------------------------------------------------------
# Enumerate pending raw sources on the CURRENT branch working tree.
#
# Only files with `ingested: false` (or missing ingested field, treated as
# false per the ingest.md Phase 2.3 convention) are considered pending.
# -----------------------------------------------------------------------
pending_files=()
if [[ -d ".rite/wiki/raw" ]]; then
  while IFS= read -r -d '' f; do
    # extract `ingested` value from YAML frontmatter
    ingested_val=$(awk '
      BEGIN { in_fm = 0 }
      /^---$/ { in_fm++; next }
      in_fm == 1 && /^ingested:[[:space:]]*/ {
        sub(/^ingested:[[:space:]]*/, "")
        sub(/[[:space:]]*$/, "")
        print
        exit
      }
    ' "$f" 2>/dev/null || true)
    ingested_norm=$(printf '%s' "$ingested_val" | tr -d '"'"'" | tr '[:upper:]' '[:lower:]')
    case "$ingested_norm" in
      true|yes|1) ;;  # already ingested → skip
      *) pending_files+=("$f") ;;
    esac
  done < <(find .rite/wiki/raw -type f -name '*.md' -print0 2>/dev/null || true)
fi

if [[ "${#pending_files[@]}" -eq 0 ]]; then
  echo "[wiki-ingest-commit] committed=0; branch=${wiki_branch}; reason=no-pending"
  exit 0
fi

if [[ "$DRY_RUN" == "true" ]]; then
  echo "[wiki-ingest-commit] dry-run; pending=${#pending_files[@]}; branch=${wiki_branch}"
  for f in "${pending_files[@]}"; do
    echo "  - $f"
  done
  exit 0
fi

# -----------------------------------------------------------------------
# same_branch strategy short-circuit: when raw sources live on the
# current branch and get committed on the current branch, we just add
# and commit in place. No stash/checkout dance needed.
# -----------------------------------------------------------------------
if [[ "$branch_strategy" == "same_branch" ]]; then
  git add -- "${pending_files[@]}" || {
    echo "ERROR: git add failed for pending raw sources" >&2
    exit 3
  }
  if git diff --cached --quiet; then
    echo "[wiki-ingest-commit] committed=0; branch=${wiki_branch}; reason=no-staged-diff"
    exit 0
  fi
  git commit -m "chore(wiki): ingest ${#pending_files[@]} raw source(s)" || {
    echo "ERROR: git commit failed" >&2
    exit 3
  }
  head_sha=$(git rev-parse HEAD 2>/dev/null || echo unknown)
  echo "[wiki-ingest-commit] committed=${#pending_files[@]}; branch=${wiki_branch}; head=${head_sha}"
  exit 0
fi

# -----------------------------------------------------------------------
# separate_branch strategy: the main path this script exists for.
#
# Design:
#   1. Copy each pending raw file into /tmp/rite-wiki-stage-$$ (preserving
#      the relative path under .rite/wiki/raw/).
#   2. Remove the pending raw files from the dev branch working tree so
#      that they do not end up in the stash (which would later resurrect
#      them on stash pop and pollute PR diffs).
#   3. If the working tree still has unrelated changes, stash them
#      (including untracked) via `git stash push -u`.
#   4. Remember the current branch and checkout the wiki branch.
#   5. Replay the staged raw files from /tmp back into the working tree
#      on the wiki branch at the same relative paths.
#   6. git add / commit / push.
#   7. Checkout back to the original branch.
#   8. Pop the stash (if any).
#   9. Cleanup the /tmp staging directory.
#
# A trap ensures that on any failure or signal we attempt to return the
# user to the original branch and restore any stashed state.
# -----------------------------------------------------------------------

# MEDIUM #6 (defence-in-depth for git option injection): verify the wiki
# branch exists via `git show-ref --verify refs/heads/...` rather than
# `git rev-parse --verify "$wiki_branch"`, because `rev-parse` cannot be
# guarded with `--` and would still accept `-<anything>` as an option if
# the validation above were ever bypassed. `show-ref --verify` requires a
# fully-qualified ref and refuses option-like strings outright.
if ! git show-ref --verify --quiet "refs/heads/${wiki_branch}"; then
  # stderr is captured separately for MEDIUM #7 (surface real cause).
  ref_err=$(mktemp /tmp/rite-wic-ref-err-XXXXXX 2>/dev/null || echo "")
  if [[ -n "$ref_err" ]]; then
    git show-ref --verify "refs/heads/${wiki_branch}" >/dev/null 2>"$ref_err" || true
  fi
  echo "ERROR: wiki branch '$wiki_branch' does not exist locally" >&2
  if [[ -n "$ref_err" ]] && [[ -s "$ref_err" ]]; then
    sed 's/^/  git: /' "$ref_err" >&2
  fi
  echo "  hint: run /rite:wiki:init first, or fetch the branch from origin" >&2
  [[ -n "$ref_err" ]] && rm -f "$ref_err"
  exit 2
fi

current_branch=$(git branch --show-current || true)
if [[ -z "$current_branch" ]]; then
  echo "ERROR: detached HEAD state — cannot run wiki-ingest-commit.sh safely" >&2
  echo "  hint: checkout a named branch first (e.g. git checkout develop)" >&2
  exit 1
fi

stage_dir=$(mktemp -d /tmp/rite-wiki-stage-XXXXXX)
stash_pushed=false
checked_out_wiki=false

# HIGH #1 / HIGH #2 — rollback-safety rewrite.
#
# Previous design had two latent bugs that could only surface on error /
# signal paths (happy path was unaffected — AC-1/2/3 dogfooding still
# passed, which is why the bugs were not caught by empirical testing):
#
#   (a) stash pop was attempted unconditionally even after checkout-back
#       to $current_branch failed, meaning a dev-branch stash could get
#       applied while the HEAD was still on the wiki branch — corrupting
#       the wiki branch working tree with unrelated dev-branch changes.
#
#   (b) The cleanup function captured `local rc=$?` on entry. When the
#       cleanup was reached via a signal trap (INT/TERM/HUP), bash's `$?`
#       at that point reflects the last completed command (usually 0 on
#       the happy path — e.g. after `echo "[wiki-ingest-commit] ..."`),
#       not the signal. As a result, cleanup would see rc=0, skip the
#       staging-dir restore block, and exit 0. A SIGINT mid-run would
#       therefore silently drop the raw sources on the floor.
#
# Fix:
#   - cleanup_body takes an explicit rc parameter (`$1`) instead of
#     reading `$?`, so signal handlers can pass the POSIX-conventional
#     exit codes (130 = SIGINT, 143 = SIGTERM, 129 = SIGHUP).
#   - stash pop is gated on a successful checkout-back. If we fail to
#     return to $current_branch, the stash is deliberately left intact
#     and a manual-recovery hint is printed so the user can resolve the
#     state by hand. No silent cross-branch pop.
#   - The staging-dir restore now fires on any non-zero rc, including
#     signal-forced exits, so SIGINT mid-copy does not lose raw sources.
cleanup_body() {
  local rc="${1:-1}"
  set +e
  if [[ "$checked_out_wiki" == "true" ]]; then
    if git checkout "$current_branch" >/dev/null 2>&1; then
      checked_out_wiki=false
    else
      echo "WARNING: cleanup failed to return to '$current_branch'" >&2
      echo "  manual recovery: git checkout $current_branch && git stash pop" >&2
      echo "  (stash is intentionally left intact to avoid cross-branch pop)" >&2
    fi
  fi
  # Only pop the stash once we are safely back on the original branch.
  # If checkout-back failed, $checked_out_wiki remains true and we skip
  # pop entirely — the user must resolve manually to avoid corrupting
  # the wiki branch working tree with dev-branch changes.
  if [[ "$checked_out_wiki" == "false" ]] && [[ "$stash_pushed" == "true" ]]; then
    if git stash pop >/dev/null 2>&1; then
      stash_pushed=false
    else
      echo "WARNING: cleanup failed to pop stash" >&2
      echo "  manual recovery: git stash list" >&2
    fi
  fi
  # Restore staged raw sources whenever we did not complete successfully,
  # including signal-forced exits. Cycle 2 MEDIUM: only attempt the
  # restore when we are back on the original branch — otherwise the
  # `cp -f` targets would land on the wiki branch working tree and the
  # message below would misreport the destination. When checkout-back
  # failed, the staging dir is preserved so the user can recover raw
  # sources manually after resolving the branch state.
  if [[ "$rc" -ne 0 ]] && [[ -d "$stage_dir" ]]; then
    if [[ "$checked_out_wiki" == "false" ]]; then
      local staged rel target
      while IFS= read -r -d '' staged; do
        rel="${staged#$stage_dir/}"
        target=".rite/wiki/raw/${rel}"
        mkdir -p "$(dirname "$target")" 2>/dev/null || true
        cp -f "$staged" "$target" 2>/dev/null || true
      done < <(find "$stage_dir" -type f -print0 2>/dev/null || true)
      echo "INFO: restored ${#pending_files[@]} raw source(s) back to the dev branch working tree after failure (rc=$rc)" >&2
      rm -rf "$stage_dir" 2>/dev/null || true
    else
      # We are still on the wiki branch (checkout-back failed). Do NOT
      # copy raw sources here — they would land on the wrong branch.
      # Preserve the staging dir so the user can recover by hand.
      echo "WARNING: staging directory preserved at $stage_dir (raw sources not restored)" >&2
      echo "  (checkout-back to '$current_branch' failed earlier; copying now would write onto the wiki branch)" >&2
      echo "  manual recovery:" >&2
      echo "    1) resolve the branch state: git checkout $current_branch" >&2
      echo "    2) copy staged raw sources back: cp -r $stage_dir/. .rite/wiki/raw/" >&2
      echo "    3) clean up: rm -rf $stage_dir" >&2
    fi
  else
    rm -rf "$stage_dir" 2>/dev/null || true
  fi
  # Cycle 2 MEDIUM: cleanup the git stderr capture file here so signal
  # exits (INT/TERM/HUP) do not leak /tmp/rite-wic-git-err-*.
  [[ -n "${git_err:-}" ]] && rm -f "$git_err" 2>/dev/null || true
}
# Signal-specific handlers pass explicit exit codes so cleanup_body sees
# the real termination reason rather than a stale `$?` from the last
# happy-path echo. EXIT handler preserves the normal `$?` capture.
trap 'rc=$?; cleanup_body "$rc"; exit "$rc"' EXIT
trap 'trap - EXIT; cleanup_body 130; exit 130' INT
trap 'trap - EXIT; cleanup_body 143; exit 143' TERM
trap 'trap - EXIT; cleanup_body 129; exit 129' HUP

# Step 1: stage raw files into /tmp with preserved relative paths.
for f in "${pending_files[@]}"; do
  rel="${f#.rite/wiki/raw/}"
  dst="${stage_dir}/${rel}"
  mkdir -p "$(dirname "$dst")"
  cp -f "$f" "$dst"
done

# Step 2: remove the pending raw files from the dev branch working tree
# so they are not captured by the stash in Step 3. We only remove files
# that are untracked — tracked files are left alone as a safety net
# against accidental deletion of reviewed content.
for f in "${pending_files[@]}"; do
  if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
    echo "WARNING: '$f' is tracked on '$current_branch' — leaving in place" >&2
    echo "  (raw source capture should only produce untracked files on the dev branch)" >&2
    continue
  fi
  rm -f "$f"
done
# Remove now-empty raw subdirectories so git status stays clean.
find .rite/wiki/raw -type d -empty -delete 2>/dev/null || true

# MEDIUM #7 — capture git stderr on critical-path commands so the real
# cause ("would overwrite untracked files", "not a valid object name",
# network auth failures, etc.) surfaces to the user on **failure**.
# Suppressing stderr with `2>/dev/null` on the old implementation made
# git failures opaque and required the user to re-run by hand to see
# the actual reason.
#
# Cycle 2 MEDIUM (noise reduction): only dump stderr on failure paths.
# Previous design called `dump_git_err` after **every** git command,
# including successful ones, which surfaced git informational messages
# like `Switched to branch 'wiki'` on stderr — noise that drowned out
# real error signals. The helper is now failure-only; success paths
# call `clear_git_err` to truncate the buffer for the next command.
#
# git_err cleanup is delegated to `cleanup_body` (see the EXIT/INT/TERM/HUP
# traps below). A separate trap would overwrite cleanup_body's and break
# the HIGH #1/#2 rollback-safety rewrites from cycle 1.
git_err=$(mktemp /tmp/rite-wic-git-err-XXXXXX 2>/dev/null || echo "")

# dump_git_err <label>: print captured git stderr with a label prefix,
# then truncate. Call only on failure paths. No-op when git_err absent.
dump_git_err() {
  local label="$1"
  if [[ -n "$git_err" ]] && [[ -s "$git_err" ]]; then
    head -n 10 "$git_err" | sed 's/^/  git ('"$label"'): /' >&2
    : > "$git_err"
  fi
}

# clear_git_err: truncate captured stderr so the next command starts
# with a clean buffer. Used on success paths instead of dump_git_err
# to avoid surfacing git informational messages as noise.
clear_git_err() {
  [[ -n "$git_err" ]] && [[ -f "$git_err" ]] && : > "$git_err"
}

# Step 3: stash any remaining uncommitted work so checkout is safe.
# We use `git stash push -u` with a specific message for traceability.
has_changes=false
if ! git diff --quiet HEAD 2>"${git_err:-/dev/null}"; then has_changes=true; fi
clear_git_err
if ! git diff --cached --quiet HEAD 2>"${git_err:-/dev/null}"; then has_changes=true; fi
clear_git_err
if [[ -n "$(git ls-files --others --exclude-standard 2>"${git_err:-/dev/null}")" ]]; then
  has_changes=true
fi
clear_git_err
if [[ "$has_changes" == "true" ]]; then
  if ! git stash push -u -m "rite-wiki-ingest-commit-stash" >/dev/null 2>"${git_err:-/dev/null}"; then
    echo "ERROR: git stash push failed" >&2
    dump_git_err "stash push"
    exit 3
  fi
  clear_git_err
  stash_pushed=true
fi

# Step 4: checkout the wiki branch. Use -q to suppress the "Switched to
# branch" informational message so only true errors land in git_err.
if ! git checkout -q "$wiki_branch" 2>"${git_err:-/dev/null}"; then
  echo "ERROR: git checkout '$wiki_branch' failed" >&2
  dump_git_err "checkout $wiki_branch"
  exit 3
fi
clear_git_err
checked_out_wiki=true

# Step 5: replay staged raw files into the wiki branch working tree.
while IFS= read -r -d '' staged; do
  rel="${staged#$stage_dir/}"
  target=".rite/wiki/raw/${rel}"
  mkdir -p "$(dirname "$target")"
  cp -f "$staged" "$target"
done < <(find "$stage_dir" -type f -print0)

# Step 6: git add / commit / push.
if ! git add .rite/wiki/raw >/dev/null 2>"${git_err:-/dev/null}"; then
  echo "ERROR: git add .rite/wiki/raw failed on '$wiki_branch'" >&2
  dump_git_err "add .rite/wiki/raw"
  exit 3
fi
clear_git_err
if git diff --cached --quiet 2>"${git_err:-/dev/null}"; then
  # Nothing new to commit — the raw files already existed verbatim on the
  # wiki branch. Treat as a no-op success (still return to original branch
  # via cleanup trap).
  clear_git_err
  echo "[wiki-ingest-commit] committed=0; branch=${wiki_branch}; reason=no-staged-diff"
  exit 0
fi
clear_git_err
commit_msg="chore(wiki): ingest ${#pending_files[@]} raw source(s) from ${current_branch}"
if ! git commit -m "$commit_msg" >/dev/null 2>"${git_err:-/dev/null}"; then
  echo "ERROR: git commit failed on '$wiki_branch'" >&2
  dump_git_err "commit"
  exit 3
fi
clear_git_err
committed_sha=$(git rev-parse HEAD 2>/dev/null || echo unknown)

# Push is best-effort: we do NOT exit 3 on push failure, because the
# commit has already landed on the local wiki branch and the caller may
# not have network access (or origin may be gone in tests). We report the
# push result so the caller can decide. Use --quiet to suppress progress
# updates (they go to stderr) so only real errors appear in git_err.
push_status="ok"
if ! git push --quiet origin "$wiki_branch" 2>"${git_err:-/dev/null}"; then
  push_status="failed"
  echo "WARNING: git push origin '$wiki_branch' failed — commit is local only" >&2
  dump_git_err "push origin $wiki_branch"
  echo "  manual recovery: git push origin $wiki_branch" >&2
fi
clear_git_err
# git_err cleanup is handled by the EXIT trap installed above.

echo "[wiki-ingest-commit] committed=${#pending_files[@]}; branch=${wiki_branch}; head=${committed_sha}; push=${push_status}"

# cleanup trap handles checkout-back + stash pop + /tmp rm.
exit 0
