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
# directories. The placement asymmetry is transitional — both should
# eventually live in hooks/scripts/. No dedicated tracking Issue exists
# yet for the consolidation; grep this file for "placement asymmetry"
# when the cleanup Issue is filed so the matching comment in
# wiki-ingest-trigger.sh (if any) can be updated together.
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
#   3  git operation failure (stash / checkout / commit — push NOT included)
#   4  push failed after successful local commit (commit landed locally,
#      but origin push failed — caller MUST emit wiki_ingest_push_failed
#      sentinel so the incident layer can observe the silent regression
#      that occurred in pre-PR-529 designs where push=failed was silent).
#
# Notes:
#   - Designed to be idempotent: when called with no pending raw sources,
#     it exits 0 without touching git state.
#   - Preserves any unrelated uncommitted work in the current branch via
#     full `git stash push -u`, and pops the stash afterwards.
#   - The current branch is restored before exit on the happy path. On
#     cleanup failure (checkout-back failing or stash pop failing), a
#     manual-recovery hint is printed to stderr and the staging directory
#     is preserved so the user can recover by hand. This is best-effort,
#     not absolute — see the cleanup_body function for the exact semantics.
#   - Emits a structured status line to stdout on success so the caller
#     (review.md / fix.md / close.md Phase X.X.W) can observe the result:
#       [wiki-ingest-commit] committed=<N>; branch=<wiki>; head=<sha>
#     or when there is nothing to do:
#       [wiki-ingest-commit] committed=0; branch=<wiki>; reason=no-pending
# --- END HEADER ---

set -euo pipefail

# verified-review cycle 4 LOW (devops): suppress credential prompts.
# In CI / hook contexts this script runs non-interactively; a git push
# requiring auth prompts would otherwise hang the hook forever. Force
# git to fail fast on missing credentials instead of prompting.
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}"

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

# verified-review cycle 4 MEDIUM (devops): advisory lock for parallel safety.
# Multiple concurrent invocations (e.g. sprint team-execute running fix /
# review / close on different issues in parallel terminals) share the same
# working tree and cannot safely run git checkout/stash/commit concurrently.
# Acquire a non-blocking advisory lock; on contention, exit 0 with an
# explicit skip marker so the caller treats it as a best-effort no-op and
# the next cycle picks up the raw sources. Lock file under repo_root so a
# stale /tmp lock from a crashed process still points back to the project.
#
# flock may not be available (macOS without util-linux, minimal containers).
# When absent we skip the lock acquisition entirely and accept the race —
# this matches the pre-fix behaviour, so parallel callers are no worse off
# than they were before this guard was added.
# verified-review cycle 5 MEDIUM (F-03): `mkdir -p .rite/state 2>/dev/null || true`
# followed by an unchecked `exec 9>.rite/state/wiki-ingest-commit.lock` aborted
# under `set -euo pipefail` with a cryptic "No such file or directory" when the
# mkdir actually failed (permission denied / `.rite` exists as a regular file /
# read-only filesystem). Split the two steps so mkdir failure produces an
# explicit WARNING and the lock acquisition is skipped (best-effort, matching
# the `flock` not available branch) instead of terminating the script with a
# native bash error.
if command -v flock >/dev/null 2>&1; then
  if mkdir -p .rite/state 2>/dev/null; then
    exec 9>.rite/state/wiki-ingest-commit.lock
    if ! flock -n 9; then
      echo "[wiki-ingest-commit] skipped; reason=concurrent-invocation" >&2
      echo "[wiki-ingest-commit] committed=0; branch=unknown; reason=concurrent-invocation"
      exit 0
    fi
  else
    echo "WARNING: .rite/state の作成に失敗しました。advisory lock をスキップします" >&2
    echo "  原因候補: permission denied / .rite が通常ファイル / read-only filesystem" >&2
    echo "  影響: 並列実行時の race を検出できません (best-effort 降格、機能自体は継続)" >&2
  fi
fi

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
  #
  # verified-review cycle 4 LOW (security/defence-in-depth): key value
  # extraction uses awk -v rather than sed with interpolated $key. Current
  # callers pass hardcoded literal keys only, so there is no injection
  # path today, but sed "s/.*${key}:[[:space:]]*//" would treat sed
  # metacharacters in $key as pattern metacharacters if a future caller
  # ever passed user-controlled input. awk -v k=... keeps $key in a
  # variable binding that is never re-parsed as a regex.
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
   [[ "$wiki_branch" == .* ]] || \
   [[ "$wiki_branch" == *..* ]] || \
   [[ "$wiki_branch" == *//* ]] || \
   [[ ! "$wiki_branch" =~ ^[A-Za-z0-9._/-]+$ ]]; then
  echo "ERROR: invalid wiki.branch_name '${wiki_branch}' in rite-config.yml" >&2
  echo "  allowed: [A-Za-z0-9._/-]+, must not start with '-' / '.', must not contain '..' or '//'" >&2
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
  # verified-review cycle 4 MEDIUM (error-handling): surface awk stderr
  # instead of swallowing it entirely. awk IO errors / binary exec failure
  # / malformed / truncated frontmatter used to fall through to the `*)`
  # case as pending, which is a fail-open default but silenced the reason.
  # Capture stderr to a tempfile and, if non-empty, emit a WARNING so the
  # operator understands why the file was treated as pending.
  fm_err=""
  trap 'rm -f "${fm_err:-}"' EXIT INT TERM HUP
  fm_err=$(mktemp /tmp/rite-wic-fm-err-XXXXXX 2>/dev/null || echo "")
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
    ' "$f" 2>"${fm_err:-/dev/null}" || true)
    if [[ -n "$fm_err" ]] && [[ -s "$fm_err" ]]; then
      echo "WARNING: frontmatter parse produced stderr for '$f' — treating as pending" >&2
      head -n 3 "$fm_err" | sed 's/^/  awk: /' >&2
      : > "$fm_err" 2>/dev/null || true
    fi
    ingested_norm=$(printf '%s' "$ingested_val" | tr -d '"'"'" | tr '[:upper:]' '[:lower:]')
    case "$ingested_norm" in
      true|yes|1) ;;  # already ingested → skip
      *) pending_files+=("$f") ;;
    esac
  done < <(find .rite/wiki/raw -type f -name '*.md' -print0 2>/dev/null || true)
  [[ -n "$fm_err" ]] && rm -f "$fm_err"
  trap - EXIT INT TERM HUP
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
  #
  # Cycle 3 LOW #3 — ref_err is created here, *before* the main cleanup_body
  # trap is installed at line 380. A signal arriving between mktemp and the
  # manual `rm -f "$ref_err"` on exit would orphan the tempfile. Guard with a
  # scope-limited mini-trap so SIGINT / SIGTERM / SIGHUP all remove ref_err.
  ref_err=""
  trap 'rm -f "${ref_err:-}"' EXIT INT TERM HUP
  ref_err=$(mktemp /tmp/rite-wic-ref-err-XXXXXX 2>/dev/null || echo "")
  if [[ -n "$ref_err" ]]; then
    git show-ref --verify "refs/heads/${wiki_branch}" >/dev/null 2>"$ref_err" || true
  fi
  echo "ERROR: wiki branch '$wiki_branch' does not exist locally" >&2
  if [[ -n "$ref_err" ]] && [[ -s "$ref_err" ]]; then
    sed 's/^/  git: /' "$ref_err" >&2
  fi
  echo "  hint (run one of these, in order of preference):" >&2
  echo "    1) git fetch origin ${wiki_branch}:${wiki_branch}  # fresh clone: create local branch from origin/${wiki_branch}" >&2
  echo "    2) /rite:wiki:init                                  # uninitialized repo: initialize Wiki structure" >&2
  echo "  NOTE: Issue #528 trade-off — this exit 2 silently defers raw source commit" >&2
  echo "         until the wiki branch exists locally. On a fresh clone the caller" >&2
  echo "         emits wiki_ingest_skipped with reason=commit_branch_missing." >&2
  # Explicit cleanup + disarm the mini-trap so the main cleanup_body trap
  # (installed later at line ~380) can take over without double-remove.
  [[ -n "$ref_err" ]] && rm -f "$ref_err"
  trap - EXIT INT TERM HUP
  exit 2
fi

current_branch=$(git branch --show-current || true)
if [[ -z "$current_branch" ]]; then
  echo "ERROR: detached HEAD state — cannot run wiki-ingest-commit.sh safely" >&2
  echo "  hint: checkout a named branch first (e.g. git checkout develop)" >&2
  exit 1
fi

# verified-review cycle 4 HIGH #2: scope-limited mini-trap for stage_dir.
# Same class of bug as the ref_err leak fixed in cycle 3 LOW #3 (lines
# 269-270, 282-283). stage_dir is created at this line but the main
# cleanup_body trap is not installed until line ~400. A signal arriving
# between mktemp and trap install would orphan /tmp/rite-wiki-stage-XXXXXX.
# Install a scope-limited mini-trap immediately after mktemp and disarm it
# right before the main trap is installed, so the orphan race window is
# closed without double-cleanup with cleanup_body.
#
# Also add explicit error handling for mktemp -d failure (cycle 4 devops LOW).
# set -euo pipefail would abort but the user would see only the mktemp
# message with no context — emit an explicit ERROR first.
stage_dir=""
trap 'rm -rf "${stage_dir:-}" 2>/dev/null || true' EXIT INT TERM HUP
if ! stage_dir=$(mktemp -d /tmp/rite-wiki-stage-XXXXXX 2>/dev/null); then
  echo "ERROR: failed to create staging directory under /tmp" >&2
  echo "  hint: check /tmp permission / disk space / inode exhaustion / read-only filesystem" >&2
  trap - EXIT INT TERM HUP
  exit 3
fi
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
      echo "  manual recovery:" >&2
      echo "    git stash list | grep rite-wiki-ingest-commit-stash" >&2
      echo "    git stash pop  # resolve conflicts if any" >&2
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
      # Cycle 3 LOW #4 — count the files that actually made it back rather
      # than reporting the full pending_files length. On a mid-Step-1 signal
      # the staging dir may hold fewer files than pending_files[], and the
      # old message ("restored N raw source(s)") over-reported the count.
      local staged rel target restored=0
      while IFS= read -r -d '' staged; do
        rel="${staged#$stage_dir/}"
        target=".rite/wiki/raw/${rel}"
        if ! mkdir -p "$(dirname "$target")" 2>/dev/null; then
          echo "WARNING: cleanup failed to recreate target directory for '$target'" >&2
          continue
        fi
        if cp -f "$staged" "$target" 2>/dev/null; then
          restored=$((restored + 1))
        else
          echo "WARNING: cleanup failed to copy '$staged' -> '$target'" >&2
        fi
      done < <(find "$stage_dir" -type f -print0 2>/dev/null || true)
      echo "INFO: restored ${restored}/${#pending_files[@]} raw source(s) back to the dev branch working tree after failure (rc=$rc)" >&2
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
# Disarm the stage_dir mini-trap before installing cleanup_body traps, so
# the main cleanup_body is the single authority for stage_dir removal /
# staging restore (avoiding double-cleanup race).
trap - EXIT INT TERM HUP

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

# -----------------------------------------------------------------------
# Git stderr capture + helpers (git_err / dump_git_err / surface_git_warnings)
#
# verified-review cycle 5 CRITICAL (F-01): この初期化ブロックと関数定義は以前
# **Step 3 冒頭 (stash push の直前)** に配置されており (before commit 5212573)、
# Step 3 以降でのみ必要と想定されていた。しかし Step 2 の
# `rm -f "$f" 2>"${git_err:-/dev/null}"` と直後の `dump_git_err "rm -f $f"`
# 呼び出しが前方参照していた。rm 失敗時に (1) stderr が常に /dev/null に routing
# され rm の OS エラーが失われ、(2) `dump_git_err` は `command not found` で set -e
# 配下で rc=127 abort し `exit 3` に到達しない — cycle 4 で cherry-pick した「rm
# stderr を propagate する」修正が構造的に無効化されていた。Step 1 は git_err を
# 参照しないため Step 1/Step 2 の境界に helper block を配置することで、Step 2 の
# rm 失敗経路が正しく診断情報を出せるようにし、cycle 4 の error-handling contract
# を再び有効にする。
#
# Cycle 2 MEDIUM (noise reduction): only dump stderr on failure paths.
# Previous design called `dump_git_err` after **every** git command, including
# successful ones, which surfaced git informational messages like `Switched to
# branch 'wiki'` on stderr — noise that drowned out real error signals. The
# helper is now failure-only; success paths call `surface_git_warnings` which
# only prints lines matching `^(warning|hint|error):`.
#
# git_err cleanup is delegated to `cleanup_body` (see the EXIT/INT/TERM/HUP
# traps below). A separate trap would overwrite cleanup_body's and break the
# HIGH #1/#2 rollback-safety rewrites from cycle 1.
#
# verified-review cycle 4 HIGH #4: mktemp failure must NOT silently swallow
# all git stderr. The previous `|| echo ""` fallback made dump_git_err and
# surface_git_warnings no-op (guarded on `[[ -n "$git_err" ]]`) while the
# stderr redirect `2>"${git_err:-/dev/null}"` kept routing git errors to
# /dev/null. Net effect: every real git failure on a /tmp-broken host was
# diagnosable only by re-running the script without this wrapper. Emit an
# explicit WARNING so the operator understands why git stderr disappears,
# and set git_err="" so the no-op path is obvious from the warning trail.
if ! git_err=$(mktemp /tmp/rite-wic-git-err-XXXXXX 2>/dev/null); then
  echo "WARNING: mktemp failed for git stderr capture — git error details will be suppressed" >&2
  echo "  hint: check /tmp permission / disk space / inode exhaustion" >&2
  echo "  impact: dump_git_err and surface_git_warnings will be no-op for this run" >&2
  git_err=""
fi

# dump_git_err <label>: print captured git stderr with a label prefix,
# then truncate. Call only on failure paths. No-op when git_err absent.
dump_git_err() {
  local label="$1"
  if [[ -n "$git_err" ]] && [[ -s "$git_err" ]]; then
    head -n 10 "$git_err" | sed 's/^/  git ('"$label"'): /' >&2
    : > "$git_err" 2>/dev/null || true
  fi
}

# surface_git_warnings <label>: called on success paths. Instead of silently
# truncating the captured git stderr (which previously dropped legitimate
# warnings like "unable to rmdir 'foo': Directory not empty" or remote-side
# hook advice), selectively surface lines that look like warnings / hints,
# then truncate. This preserves operator visibility without re-introducing
# informational noise like "Switched to branch 'wiki'" (which git emits
# without a "warning:" / "hint:" prefix and which `-q` already suppresses).
#
# Cycle 3 MEDIUM #1 fix — replaces the old unconditional `clear_git_err`
# truncation on success paths, which silently dropped warnings.
#
# LOW #5 — all writes to git_err in this helper are `|| true` guarded so an
# ENOSPC / EACCES truncate failure does not abort the script under set -e.
surface_git_warnings() {
  local label="$1"
  if [[ -n "$git_err" ]] && [[ -s "$git_err" ]]; then
    local warnings
    warnings=$(head -n 10 "$git_err" | grep -iE '^(warning|hint|error):' || true)
    if [[ -n "$warnings" ]]; then
      printf '%s\n' "$warnings" | sed 's/^/  git ('"$label"'): /' >&2
    fi
    : > "$git_err" 2>/dev/null || true
  fi
  return 0
}

# Step 2: remove the pending raw files from the dev branch working tree
# so they are not captured by the stash in Step 3.
#
# verified-review cycle 4 MEDIUM (error-handling): tracked raw file must
# be an invariant violation, not a silent continue. Raw source capture
# contract (wiki-ingest-trigger.sh) should only produce untracked files on
# the dev branch; a tracked raw file indicates either a stray accidental
# commit on the dev branch or someone running the script in an unexpected
# workflow. Silent continue lets that state persist and forms a double
# state (tracked on dev + committed on wiki) that corrupts subsequent fix
# cycles. Fail fast instead so the user resolves the invariant violation.
for f in "${pending_files[@]}"; do
  if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
    echo "ERROR: '$f' is tracked on '$current_branch' — invariant violation" >&2
    echo "  raw source capture should only produce untracked files on the dev branch" >&2
    echo "  hint: this usually means an accidental commit of the raw source on the dev branch" >&2
    echo "  manual recovery:" >&2
    echo "    1) git rm --cached '$f'" >&2
    echo "    2) commit the removal on the dev branch" >&2
    echo "    3) re-run wiki-ingest-commit.sh" >&2
    exit 3
  fi
  # verified-review cycle 4 MEDIUM (error-handling): rm -f stderr was
  # previously suppressed entirely. Propagate failures so the operator can
  # see which file could not be removed (EACCES / EIO / race).
  if ! rm -f "$f" 2>"${git_err:-/dev/null}"; then
    echo "ERROR: failed to remove untracked raw source '$f' from '$current_branch'" >&2
    dump_git_err "rm -f $f"
    exit 3
  fi
done
# Remove now-empty raw subdirectories so git status stays clean.
# verified-review cycle 4 LOW: intentionally cosmetic; failures are
# silently ignored because the commit / push path below does not depend
# on empty directory cleanup and the next fix cycle will re-run this.
find .rite/wiki/raw -type d -empty -delete 2>/dev/null || true

# Step 3: stash any remaining uncommitted work so checkout is safe.
# We use `git stash push -u` with a specific message for traceability.
#
# Cycle 3 MEDIUM #2 fix — explicitly classify `git diff --quiet` exit codes.
# The old `if ! git diff --quiet; then has_changes=true; fi` pattern folded
# rc=1 (has-diff, expected) and rc>1 (real IO/index error) into the same
# `has_changes=true` branch, silently routing real failures into the stash
# path. Use a case statement to distinguish 0 (clean) / 1 (has-diff) /
# anything else (real error → fail-fast with dump_git_err).
has_changes=false

set +e
git diff --quiet HEAD 2>"${git_err:-/dev/null}"
diff_rc=$?
set -e
case "$diff_rc" in
  0) ;;
  1) has_changes=true ;;
  *)
    echo "ERROR: git diff --quiet HEAD failed with rc=$diff_rc" >&2
    dump_git_err "diff HEAD"
    exit 3
    ;;
esac
surface_git_warnings "diff HEAD"

set +e
git diff --cached --quiet HEAD 2>"${git_err:-/dev/null}"
diff_cached_rc=$?
set -e
case "$diff_cached_rc" in
  0) ;;
  1) has_changes=true ;;
  *)
    echo "ERROR: git diff --cached --quiet HEAD failed with rc=$diff_cached_rc" >&2
    dump_git_err "diff --cached HEAD"
    exit 3
    ;;
esac
surface_git_warnings "diff --cached HEAD"

set +e
untracked=$(git ls-files --others --exclude-standard 2>"${git_err:-/dev/null}")
ls_files_rc=$?
set -e
if [[ "$ls_files_rc" -ne 0 ]]; then
  echo "ERROR: git ls-files --others --exclude-standard failed with rc=$ls_files_rc" >&2
  dump_git_err "ls-files --others"
  exit 3
fi
if [[ -n "$untracked" ]]; then
  has_changes=true
fi
surface_git_warnings "ls-files --others"

if [[ "$has_changes" == "true" ]]; then
  if ! git stash push -u -m "rite-wiki-ingest-commit-stash" >/dev/null 2>"${git_err:-/dev/null}"; then
    echo "ERROR: git stash push failed" >&2
    dump_git_err "stash push"
    exit 3
  fi
  surface_git_warnings "stash push"
  stash_pushed=true
fi

# Step 4: checkout the wiki branch. Use -q to suppress the "Switched to
# branch" informational message so only true errors land in git_err.
if ! git checkout -q "$wiki_branch" 2>"${git_err:-/dev/null}"; then
  echo "ERROR: git checkout '$wiki_branch' failed" >&2
  dump_git_err "checkout $wiki_branch"
  exit 3
fi
surface_git_warnings "checkout $wiki_branch"
checked_out_wiki=true

# Step 5: replay staged raw files into the wiki branch working tree.
while IFS= read -r -d '' staged; do
  rel="${staged#$stage_dir/}"
  target=".rite/wiki/raw/${rel}"
  mkdir -p "$(dirname "$target")"
  cp -f "$staged" "$target"
done < <(find "$stage_dir" -type f -print0)

# Step 6: git add / commit / push.
# verified-review cycle 4 LOW (security): use `--` separator to prevent
# git option interpretation of the path argument. Even though .rite/wiki/raw
# is hardcoded here, use the same defence-in-depth pattern as the
# same_branch path above (line 216) for consistency.
if ! git add -- .rite/wiki/raw >/dev/null 2>"${git_err:-/dev/null}"; then
  echo "ERROR: git add .rite/wiki/raw failed on '$wiki_branch'" >&2
  dump_git_err "add .rite/wiki/raw"
  exit 3
fi
surface_git_warnings "add .rite/wiki/raw"
#
# Cycle 3 MEDIUM #2 fix — same case-based classification for this second
# `git diff --cached --quiet` probe: rc=0 (no staged diff, early-exit
# success) / rc=1 (staged diff present, continue) / rc>1 (real error).
set +e
git diff --cached --quiet 2>"${git_err:-/dev/null}"
cached_check_rc=$?
set -e
case "$cached_check_rc" in
  0)
    # Nothing new to commit — the raw files already existed verbatim on
    # the wiki branch. Treat as a no-op success (still return to original
    # branch via cleanup trap).
    surface_git_warnings "diff --cached (no-staged)"
    echo "[wiki-ingest-commit] committed=0; branch=${wiki_branch}; reason=no-staged-diff"
    exit 0
    ;;
  1)
    # Staged diff present — proceed to commit.
    surface_git_warnings "diff --cached"
    ;;
  *)
    echo "ERROR: git diff --cached --quiet failed with rc=$cached_check_rc" >&2
    dump_git_err "diff --cached"
    exit 3
    ;;
esac
commit_msg="chore(wiki): ingest ${#pending_files[@]} raw source(s) from ${current_branch}"
if ! git commit -m "$commit_msg" >/dev/null 2>"${git_err:-/dev/null}"; then
  echo "ERROR: git commit failed on '$wiki_branch'" >&2
  dump_git_err "commit"
  exit 3
fi
surface_git_warnings "commit"
committed_sha=$(git rev-parse HEAD 2>/dev/null || echo unknown)

# Push is best-effort vs incident-observable:
# (verified-review cycle 4 CRITICAL #1) Push failure MUST be observable by the
# incident layer. Previous design exited 0 on push failure with only a stdout
# `push=failed` marker, which the callers (review.md / fix.md / close.md Phase
# X.X.W.2) did not parse — so flaky remote / auth expiry / rate limit drove
# all push failures through the success branch and silently emitted
# WIKI_INGEST_DONE=1 without any wiki_ingest_push_failed sentinel.
#
# Fix: exit 4 on push failure so the caller's bash `if commit_out=$(...)`
# takes the failure branch and emits a dedicated `wiki_ingest_push_failed`
# sentinel via workflow-incident-emit.sh. The commit itself has already
# landed on the local wiki branch, so the stdout status line still reports
# `committed=N; head=<sha>; push=failed` — callers classify exit 4 as
# "commit landed but push needs retry" rather than a full rollback.
#
# Use --quiet to suppress progress updates (they go to stderr) so only
# real errors appear in git_err.
push_status="ok"
push_failed=false
if ! git push --quiet origin "$wiki_branch" 2>"${git_err:-/dev/null}"; then
  push_status="failed"
  push_failed=true
  echo "WARNING: git push origin '$wiki_branch' failed — commit is local only" >&2
  dump_git_err "push origin $wiki_branch"
  echo "  manual recovery: git push origin $wiki_branch" >&2
fi
surface_git_warnings "push origin $wiki_branch"
# git_err cleanup is handled by the EXIT trap installed above.

echo "[wiki-ingest-commit] committed=${#pending_files[@]}; branch=${wiki_branch}; head=${committed_sha}; push=${push_status}"

# cleanup trap handles checkout-back + stash pop + /tmp rm.
# Exit 4 signals "commit landed, push failed" so the caller emits a
# dedicated wiki_ingest_push_failed sentinel (CRITICAL #1 fix).
if [[ "$push_failed" == "true" ]]; then
  exit 4
fi
exit 0
