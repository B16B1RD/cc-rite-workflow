# rite workflow - Worktree-scoped git add/commit/push helper
#
# Responsibility: provide the canonical `git -C <worktree> add / commit /
# push` flow with stderr tempfile capture, head -n 10 extraction, and
# exit-code semantics shared by:
#   - wiki-worktree-commit.sh  (pages/index/log commits on wiki branch)
#   - wiki-ingest-commit.sh    (worktree fast path for raw-source ingest)
#
# Design rationale (Issue #549): PR #548 cycle 4 F-06 identified that the
# add/commit/push block + error handling (stderr tempfile -> head -n 10
# -> sed prefix) was structurally identical across the two scripts. Any
# future enhancement (e.g. push retry with exponential backoff) would
# require synchronous edits across both. A shared helper eliminates that
# drift vector.
#
# Usage:
#   source "$(dirname "$0")/lib/worktree-git.sh"
#   worktree_commit_push WORKTREE COMMIT_MSG PATH1 [PATH2 ...]
#   rc=$?
#   case "$rc" in
#     0) ;;  # committed and pushed
#     3) exit 3 ;;  # add/commit failed — error already surfaced to stderr
#     4) push_failed=true ;;  # commit landed, push failed
#     5) ;;  # no staged diff — caller decides policy
#   esac
#
# Arguments:
#   WORKTREE      path to the worktree (caller must have validated it)
#   COMMIT_MSG    commit message (must not contain newline / CR — callers
#                 that read from user input should validate first)
#   PATH1...      pathspecs to `git add --`. At least one is required.
#
# Exit codes:
#   0  success — committed and pushed
#   2  argument error (missing worktree / commit message / pathspec)
#   3  git add or commit failed (error details already on stderr)
#   4  commit OK, push failed (caller should emit wiki_ingest_push_failed
#      sentinel and decide whether to exit 4 or continue)
#   5  no staged diff after add (no-op, caller decides skip/success)
#
# stdout:
#   On exit 0 or 4: "head=<sha>; push=<ok|failed>"
#   On exit 5:      "no-staged-diff"
#   Otherwise:      empty (errors are on stderr)
#
# Contract:
#   - Does NOT set `set -euo pipefail`. Caller owns shell options.
#   - Uses a local trap for stderr tempfile cleanup; caller's outer trap
#     is restored via `trap - EXIT INT TERM HUP` before return.
#   - Caller must have ALREADY verified:
#       * worktree exists at WORKTREE path
#       * worktree HEAD is on the expected branch
#       * COMMIT_MSG has been checked for newline/CR injection

worktree_commit_push() {
  local worktree="$1"
  local commit_msg="$2"
  shift 2 2>/dev/null || true

  if [[ -z "$worktree" ]] || [[ -z "$commit_msg" ]] || [[ $# -eq 0 ]]; then
    echo "ERROR: worktree_commit_push: WORKTREE / COMMIT_MSG / PATH... required" >&2
    return 2
  fi

  local add_err="" commit_err="" push_err=""
  trap 'rm -f "${add_err:-}" "${commit_err:-}" "${push_err:-}"' EXIT INT TERM HUP
  add_err=$(mktemp /tmp/rite-wtgit-add-err-XXXXXX 2>/dev/null) || add_err=""
  commit_err=$(mktemp /tmp/rite-wtgit-commit-err-XXXXXX 2>/dev/null) || commit_err=""
  push_err=$(mktemp /tmp/rite-wtgit-push-err-XXXXXX 2>/dev/null) || push_err=""

  # Step 1: stage paths
  if ! git -C "$worktree" add -- "$@" 2>"${add_err:-/dev/null}"; then
    echo "ERROR: git -C '$worktree' add failed" >&2
    [ -n "$add_err" ] && [ -s "$add_err" ] && head -n 10 "$add_err" | sed 's/^/  git: /' >&2
    echo "  hint: index lock / path error / permission denied のいずれかを確認してください" >&2
    rm -f "${add_err:-}" "${commit_err:-}" "${push_err:-}"
    trap - EXIT INT TERM HUP
    return 3
  fi

  # Step 2: verify staged diff is non-empty
  set +e
  git -C "$worktree" diff --cached --quiet 2>"${add_err:-/dev/null}"
  local cached_rc=$?
  set -e
  case "$cached_rc" in
    0)
      echo "no-staged-diff"
      rm -f "${add_err:-}" "${commit_err:-}" "${push_err:-}"
      trap - EXIT INT TERM HUP
      return 5
      ;;
    1) ;;  # staged diff present, proceed
    *)
      echo "ERROR: git -C '$worktree' diff --cached --quiet failed (rc=$cached_rc)" >&2
      [ -n "$add_err" ] && [ -s "$add_err" ] && head -n 10 "$add_err" | sed 's/^/  git: /' >&2
      rm -f "${add_err:-}" "${commit_err:-}" "${push_err:-}"
      trap - EXIT INT TERM HUP
      return 3
      ;;
  esac

  # Step 3: commit
  if ! git -C "$worktree" commit --quiet -m "$commit_msg" 2>"${commit_err:-/dev/null}"; then
    echo "ERROR: git -C '$worktree' commit failed" >&2
    [ -n "$commit_err" ] && [ -s "$commit_err" ] && head -n 10 "$commit_err" | sed 's/^/  git: /' >&2
    echo "  hint: pre-commit hook / gpg sign / author config / permission のいずれかを確認" >&2
    rm -f "${add_err:-}" "${commit_err:-}" "${push_err:-}"
    trap - EXIT INT TERM HUP
    return 3
  fi

  local head_sha
  head_sha=$(git -C "$worktree" rev-parse HEAD 2>/dev/null || echo unknown)

  # Step 4: push. Failure here is incident-observable (return 4) but caller
  # owns the policy decision (continue workflow vs. hard fail).
  local push_status="ok"
  local branch
  branch=$(git -C "$worktree" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
  if ! git -C "$worktree" push --quiet origin "$branch" 2>"${push_err:-/dev/null}"; then
    push_status="failed"
    echo "WARNING: git -C '$worktree' push origin '$branch' failed — commit is local only" >&2
    [ -n "$push_err" ] && [ -s "$push_err" ] && head -n 10 "$push_err" | sed 's/^/  git: /' >&2
    echo "  manual recovery: git -C '$worktree' push origin '$branch'" >&2
  fi

  echo "head=${head_sha}; push=${push_status}"

  rm -f "${add_err:-}" "${commit_err:-}" "${push_err:-}"
  trap - EXIT INT TERM HUP

  if [[ "$push_status" == "failed" ]]; then
    return 4
  fi
  return 0
}
