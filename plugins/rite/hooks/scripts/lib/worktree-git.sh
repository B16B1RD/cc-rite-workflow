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
# -> sed prefix) was structurally identical across the two scripts. A
# shared helper removes that drift vector. PR #550 review further
# tightened the contract so the lib does not silently toggle caller
# shell options or clobber caller traps.
#
# Usage:
#   source "$_SCRIPT_DIR/lib/worktree-git.sh"
#   worktree_commit_push "$worktree_path" "$wiki_branch" "$commit_msg" "$wiki_rel"
#   rc=$?
#   case "$rc" in
#     0) ;;  # committed and pushed
#     3) exit 3 ;;  # add/commit failed — error already surfaced to stderr
#     4) push_failed=true ;;  # commit landed, push failed
#     5) ;;  # no staged diff — caller decides policy (stdout is silent)
#   esac
#
# Arguments:
#   WORKTREE      path to the worktree (caller must have validated it)
#   BRANCH        expected branch name for the push (caller-validated;
#                 lib does NOT re-derive via `rev-parse --abbrev-ref`
#                 because a detached HEAD would silently fall back to
#                 the literal "HEAD" and misclassify push failures).
#   COMMIT_MSG    commit message (must not contain newline / CR — callers
#                 that read from user input should validate first)
#   PATH1...      pathspecs to `git add --`. At least one is required.
#
# Exit codes:
#   0  success — committed and pushed
#   2  argument error (missing worktree / branch / commit message / pathspec)
#   3  git add or commit failed (error details already on stderr)
#   4  commit OK, push failed (caller should emit wiki_ingest_push_failed
#      sentinel and decide whether to exit 4 or continue)
#   5  no staged diff after add (no-op, caller decides skip/success)
#
# stdout:
#   On exit 0 or 4: "head=<sha>; push=<ok|failed>"
#   On exit 5:      (empty — caller emits its own reason=no-staged-diff)
#   Otherwise:      empty (errors are on stderr)
#
# Contract:
#   - Does NOT toggle `set -e` / `set -u` / `set -o pipefail`. The
#     function saves the caller's `errexit` state before any `set +e`
#     probe and restores it before return, so the caller's shell-option
#     environment is preserved in every exit path.
#   - Does NOT install EXIT / INT / TERM / HUP traps that persist past
#     return. Any trap installed for internal tempfile cleanup is
#     restored to the caller's previous trap via `trap -p` / `eval`
#     before every return path, so the caller may install its own
#     outer trap without surprise clobbering.
#   - Signal-handling limitation: while this helper is executing, its
#     internal trap OVERRIDES the caller's signal traps for EXIT / INT
#     / TERM / HUP. Signals delivered during the helper body (e.g.
#     user Ctrl-C while `git push` is in flight) clean up the helper's
#     internal tempfiles only — the caller's signal-driven cleanup
#     (e.g. stash pop on SIGINT) is NOT invoked until after the helper
#     returns and the caller's trap is restored. Callers that need
#     signal-safe rollback during helper execution must either wrap
#     the helper in their own subshell or accept best-effort cleanup.
#   - Nested function `_wtgp_restore_caller_state` leaks into the
#     caller's global scope (bash dynamic scoping). The underscore
#     prefix marks it as a private helper: callers MUST NOT invoke it
#     directly from outside `worktree_commit_push`, and MUST NOT
#     redefine a function with the same name.
#   - Caller must have ALREADY verified:
#       * worktree exists at WORKTREE path
#       * worktree HEAD is on BRANCH
#       * COMMIT_MSG has been checked for newline/CR injection
#       * BRANCH matches the expected wiki.branch_name

# -----------------------------------------------------------------------
# verify_worktree_branch: confirm a worktree's HEAD is on an expected branch.
#
# Responsibility (cycle 3 C3-M1 fix): eliminate the duplicated rev-parse
# --abbrev-ref HEAD verification block that previously lived in both
# wiki-worktree-commit.sh and wiki-ingest-commit.sh. Both callers ran
# essentially the same sequence (mktemp stderr tempfile + scope-limited
# trap + `set +e` / `set -e` fence + rev-parse + ERROR + `head -3` + rm -f
# + branch compare) with only the tempfile prefix differing. This helper
# centralizes that logic so fixes propagate to both callers automatically.
#
# Usage:
#   verify_worktree_branch "$worktree_path" "$wiki_branch" "wwc" "$extra_hint"
#   # returns 0 if worktree HEAD == expected_branch
#   # returns non-zero after emitting ERROR to stderr (caller should exit 1)
#
# Arguments:
#   WORKTREE          worktree path (caller has already confirmed existence)
#   EXPECTED_BRANCH   branch name the worktree must be on
#   TEMPFILE_TAG      short tag (4-8 chars) for the mktemp prefix, so
#                     concurrent runs from different callers produce
#                     distinguishable tempfile names. Example: "wwc",
#                     "wic-wt".
#   EXTRA_HINT        optional extra stderr line to emit when the branch
#                     mismatch is detected (used by ingest-commit.sh to
#                     clarify that silent fall-through would be even more
#                     confusing). Pass empty string to omit.
#
# Exit codes:
#   0  worktree is on expected branch
#   2  rev-parse failed (worktree corrupt / permission / git binary issue)
#   3  worktree is on a different branch
verify_worktree_branch() {
  local worktree="$1"
  local expected_branch="$2"
  local tempfile_tag="${3:-vwb}"
  local extra_hint="${4:-}"

  local rev_parse_err=""
  # Save caller's outer trap to avoid clobbering it.
  local _vwb_outer_exit _vwb_outer_int _vwb_outer_term _vwb_outer_hup
  _vwb_outer_exit=$(trap -p EXIT)
  _vwb_outer_int=$(trap -p INT)
  _vwb_outer_term=$(trap -p TERM)
  _vwb_outer_hup=$(trap -p HUP)

  trap 'rm -f "${rev_parse_err:-}"' EXIT INT TERM HUP
  rev_parse_err=$(mktemp "/tmp/rite-${tempfile_tag}-revparse-err-XXXXXX" 2>/dev/null) || rev_parse_err=""

  # Save caller's errexit so we can restore exactly.
  local _vwb_errexit=0
  case $- in *e*) _vwb_errexit=1 ;; esac
  set +e
  local wt_head wt_head_rc
  wt_head=$(git -C "$worktree" rev-parse --abbrev-ref HEAD 2>"${rev_parse_err:-/dev/null}")
  wt_head_rc=$?
  if [[ $_vwb_errexit -eq 1 ]]; then set -e; fi

  _vwb_restore_traps() {
    if [[ -n "$_vwb_outer_exit" ]]; then eval "$_vwb_outer_exit"; else trap - EXIT; fi
    if [[ -n "$_vwb_outer_int"  ]]; then eval "$_vwb_outer_int";  else trap - INT;  fi
    if [[ -n "$_vwb_outer_term" ]]; then eval "$_vwb_outer_term"; else trap - TERM; fi
    if [[ -n "$_vwb_outer_hup"  ]]; then eval "$_vwb_outer_hup";  else trap - HUP;  fi
  }

  if [ "$wt_head_rc" -ne 0 ]; then
    echo "ERROR: git -C '$worktree' rev-parse --abbrev-ref HEAD が失敗しました (rc=$wt_head_rc)" >&2
    if [ -n "$rev_parse_err" ] && [ -s "$rev_parse_err" ]; then
      head -3 "$rev_parse_err" | sed 's/^/  git: /' >&2
    fi
    echo "  原因候補: worktree corrupt (.git file 破損) / permission denied / git binary 異常" >&2
    echo "  対処: git worktree remove '$worktree' && bash plugins/rite/hooks/scripts/wiki-worktree-setup.sh" >&2
    [ -n "$rev_parse_err" ] && rm -f "$rev_parse_err"
    _vwb_restore_traps
    return 2
  fi
  [ -n "$rev_parse_err" ] && rm -f "$rev_parse_err"
  _vwb_restore_traps

  if [ "$wt_head" != "$expected_branch" ]; then
    echo "ERROR: worktree at '$worktree' is on branch '$wt_head', expected '$expected_branch'" >&2
    echo "  hint: git -C '$worktree' checkout '$expected_branch'" >&2
    if [ -n "$extra_hint" ]; then
      echo "  $extra_hint" >&2
    fi
    return 3
  fi

  return 0
}

worktree_commit_push() {
  local worktree="$1"
  local branch="$2"
  local commit_msg="$3"
  shift 3 || true

  if [[ -z "$worktree" ]] || [[ -z "$branch" ]] || [[ -z "$commit_msg" ]] || [[ $# -eq 0 ]]; then
    echo "ERROR: worktree_commit_push: WORKTREE / BRANCH / COMMIT_MSG / PATH... required" >&2
    return 2
  fi

  # Save caller's errexit state so we can restore it instead of force-
  # setting `set -e` on return (contract: caller owns shell options).
  local _wtgp_errexit=0
  case $- in *e*) _wtgp_errexit=1 ;; esac

  # Save caller's outer traps (EXIT / INT / TERM / HUP) so we can restore
  # them instead of clearing via `trap -`. `trap -p` output is POSIX-safe
  # for `eval` reinput, including traps with quoted strings.
  local _wtgp_outer_exit _wtgp_outer_int _wtgp_outer_term _wtgp_outer_hup
  _wtgp_outer_exit=$(trap -p EXIT)
  _wtgp_outer_int=$(trap -p INT)
  _wtgp_outer_term=$(trap -p TERM)
  _wtgp_outer_hup=$(trap -p HUP)

  # Restore caller's errexit + outer traps; caller expects none of
  # these to differ from their pre-call state.
  _wtgp_restore_caller_state() {
    # Restore traps: empty output from `trap -p` means no trap was set.
    if [[ -n "$_wtgp_outer_exit" ]]; then eval "$_wtgp_outer_exit"; else trap - EXIT; fi
    if [[ -n "$_wtgp_outer_int"  ]]; then eval "$_wtgp_outer_int";  else trap - INT;  fi
    if [[ -n "$_wtgp_outer_term" ]]; then eval "$_wtgp_outer_term"; else trap - TERM; fi
    if [[ -n "$_wtgp_outer_hup"  ]]; then eval "$_wtgp_outer_hup";  else trap - HUP;  fi
    # Restore errexit.
    if [[ $_wtgp_errexit -eq 1 ]]; then set -e; else set +e; fi
  }

  local add_err="" diff_err="" commit_err="" push_err=""
  # Internal cleanup trap (EXIT only — caller's signal traps are
  # re-applied below on any non-signal return path).
  trap 'rm -f "${add_err:-}" "${diff_err:-}" "${commit_err:-}" "${push_err:-}"' EXIT INT TERM HUP

  # mktemp failures are surfaced to stderr (not silently swallowed) so
  # operators can see when stderr capture is degraded to /dev/null.
  if ! add_err=$(mktemp /tmp/rite-wtgit-add-err-XXXXXX 2>/dev/null); then
    echo "WARNING: mktemp for worktree_commit_push add stderr capture failed — diagnostics will be lost" >&2
    add_err=""
  fi
  if ! diff_err=$(mktemp /tmp/rite-wtgit-diff-err-XXXXXX 2>/dev/null); then
    echo "WARNING: mktemp for worktree_commit_push diff stderr capture failed — diagnostics will be lost" >&2
    diff_err=""
  fi
  if ! commit_err=$(mktemp /tmp/rite-wtgit-commit-err-XXXXXX 2>/dev/null); then
    echo "WARNING: mktemp for worktree_commit_push commit stderr capture failed — diagnostics will be lost" >&2
    commit_err=""
  fi
  if ! push_err=$(mktemp /tmp/rite-wtgit-push-err-XXXXXX 2>/dev/null); then
    echo "WARNING: mktemp for worktree_commit_push push stderr capture failed — diagnostics will be lost" >&2
    push_err=""
  fi

  # Step 1: stage paths. Quote the first pathspec in the error message
  # to mirror the pre-refactor wiki-worktree-commit.sh format, so log
  # greppers that anchor on `'<path>'` keep working.
  local _first_path="$1"
  if ! git -C "$worktree" add -- "$@" 2>"${add_err:-/dev/null}"; then
    echo "ERROR: git add '$_first_path' failed in worktree '$worktree'" >&2
    [ -n "$add_err" ] && [ -s "$add_err" ] && head -n 10 "$add_err" | sed 's/^/  git: /' >&2
    echo "  hint: index lock / path error / permission denied のいずれかを確認してください" >&2
    rm -f "${add_err:-}" "${diff_err:-}" "${commit_err:-}" "${push_err:-}"
    _wtgp_restore_caller_state
    return 3
  fi

  # Step 2: verify staged diff is non-empty. Use a dedicated diff_err
  # tempfile so the add-step warnings are not mixed with diff-step
  # errors on rc>1 — otherwise `head -n 10 "$add_err"` in the error
  # branch would display add warnings alongside the diff failure and
  # obscure the true root cause.
  set +e
  git -C "$worktree" diff --cached --quiet 2>"${diff_err:-/dev/null}"
  local cached_rc=$?
  if [[ $_wtgp_errexit -eq 1 ]]; then set -e; fi
  case "$cached_rc" in
    0)
      # Silent on stdout: callers emit their own `reason=no-staged-diff`
      # status line (wiki-worktree-commit.sh / wiki-ingest-commit.sh
      # both do this). Returning 5 is the sole signal.
      rm -f "${add_err:-}" "${diff_err:-}" "${commit_err:-}" "${push_err:-}"
      _wtgp_restore_caller_state
      return 5
      ;;
    1) ;;  # staged diff present, proceed
    *)
      echo "ERROR: git diff --cached failed in worktree '$worktree' (rc=$cached_rc)" >&2
      [ -n "$diff_err" ] && [ -s "$diff_err" ] && head -n 10 "$diff_err" | sed 's/^/  git: /' >&2
      rm -f "${add_err:-}" "${diff_err:-}" "${commit_err:-}" "${push_err:-}"
      _wtgp_restore_caller_state
      return 3
      ;;
  esac

  # Step 3: commit
  if ! git -C "$worktree" commit --quiet -m "$commit_msg" 2>"${commit_err:-/dev/null}"; then
    echo "ERROR: git commit failed in worktree '$worktree'" >&2
    [ -n "$commit_err" ] && [ -s "$commit_err" ] && head -n 10 "$commit_err" | sed 's/^/  git: /' >&2
    echo "  hint: pre-commit hook / gpg sign / author config / permission のいずれかを確認" >&2
    rm -f "${add_err:-}" "${diff_err:-}" "${commit_err:-}" "${push_err:-}"
    _wtgp_restore_caller_state
    return 3
  fi

  # head_sha capture: post-commit rev-parse should normally succeed. If it
  # fails (corrupt worktree between commit and rev-parse, extremely rare),
  # surface a WARNING rather than silently embedding "unknown" in the
  # status line — otherwise the caller sees `head=unknown; push=ok` and
  # treats it as a successful commit.
  local head_sha head_err=""
  # cycle 3 C3-L1 fix: extend internal trap to cover head_err so SIGINT /
  # SIGTERM / SIGHUP during the post-commit rev-parse does not leak the
  # tempfile. Must be set BEFORE mktemp.
  trap 'rm -f "${add_err:-}" "${diff_err:-}" "${commit_err:-}" "${push_err:-}" "${head_err:-}"' EXIT INT TERM HUP
  head_err=$(mktemp /tmp/rite-wtgit-head-err-XXXXXX 2>/dev/null) || head_err=""
  if head_sha=$(git -C "$worktree" rev-parse HEAD 2>"${head_err:-/dev/null}"); then
    :
  else
    local head_rc=$?
    echo "WARNING: git -C '$worktree' rev-parse HEAD failed post-commit (rc=$head_rc)" >&2
    [ -n "$head_err" ] && [ -s "$head_err" ] && head -n 5 "$head_err" | sed 's/^/  git: /' >&2
    echo "  head SHA will be reported as 'unknown' — the commit itself succeeded but the worktree may be corrupt" >&2
    head_sha="unknown"
  fi
  [ -n "$head_err" ] && rm -f "$head_err"

  # Step 4: push using the caller-supplied branch (no silent
  # `rev-parse --abbrev-ref HEAD` fallback to literal "HEAD"). Push
  # failure is incident-observable (return 4) but the caller owns the
  # policy decision (continue workflow vs. hard fail).
  local push_status="ok"
  if ! git -C "$worktree" push --quiet origin "$branch" 2>"${push_err:-/dev/null}"; then
    push_status="failed"
    echo "WARNING: git push origin '$branch' failed in worktree '$worktree' — commit is local only" >&2
    [ -n "$push_err" ] && [ -s "$push_err" ] && head -n 10 "$push_err" | sed 's/^/  git: /' >&2
    echo "  manual recovery: git -C '$worktree' push origin '$branch'" >&2
  fi

  echo "head=${head_sha}; push=${push_status}"

  rm -f "${add_err:-}" "${diff_err:-}" "${commit_err:-}" "${push_err:-}" "${head_err:-}"
  _wtgp_restore_caller_state

  if [[ "$push_status" == "failed" ]]; then
    return 4
  fi
  return 0
}
