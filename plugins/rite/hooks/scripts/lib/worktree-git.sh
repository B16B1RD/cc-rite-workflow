# shellcheck shell=bash
# rite workflow - Worktree git helpers (commit/push + session-worktree ensure)
#
# Responsibility 1 (source-only): provide the canonical
# `git -C <worktree> add / commit / push` flow with stderr tempfile
# capture, head -n 10 extraction, and exit-code semantics shared by:
# - wiki-worktree-commit.sh (pages/index/log commits on wiki branch)
# - wiki-ingest-commit.sh (worktree fast path for raw-source ingest)
#
# Responsibility 2 ( source OR standalone): provide
# `ensure_session_worktree`, the single bash-side SoT for the
# "branch exists ∧ session worktree absent → reconstruct" gate used by
# the flow ENTRY paths (resume / review / iterate / fix) so a
# missing worktree never silently degrades the flow onto the main
# checkout (develop). Callers invoke it standalone as
# `bash lib/worktree-git.sh ensure-session-worktree --issue <N> ...` and
# route on the emitted `[CONTEXT] WT_ENSURE=` marker (see the function
# header below and skills/recover/SKILL.md Phase 3.1.5 for the canonical
# marker→action table). The dispatch at the bottom of this file exposes
# only that subcommand; the commit/push helpers stay source-only.
#
# Design rationale: review identified that the
# add/commit/push block + error handling (stderr tempfile -> head -n 10
# -> sed prefix) was structurally identical across the two scripts. A
# shared helper removes that drift vector. A later review further
# tightened the contract so the lib does not silently toggle caller
# shell options or clobber caller traps.
#
# Usage:
# source "$_SCRIPT_DIR/lib/worktree-git.sh"
# worktree_commit_push "$worktree_path" "$wiki_branch" "$commit_msg" "$wiki_rel"
# rc=$?
# case "$rc" in
# 0) ;; # committed and pushed
# 3) exit 3 ;; # add/commit failed — error already surfaced to stderr
# 4) push_failed=true ;; # commit landed, push failed
# 5) ;; # no staged diff — caller decides policy (stdout is silent)
# esac
#
# Batch/defer push: a caller processing several commits in a loop
# (e.g. wiki-ingest, one commit per raw source) can defer the push to a
# single call at the end of the loop instead of pushing after every commit:
# WTGP_COMMIT_ONLY=1 worktree_commit_push "$worktree_path" "$wiki_branch" "$commit_msg" "$wiki_rel"
# # rc 0/3/5 as above, minus 4 (no push attempted — stdout is "head=<sha>" only)
# ...
# worktree_push_branch "$worktree_path" "$wiki_branch" # once, after the loop
# rc=$? # 0 pushed, 2 argument error, 4 push failed (commits stay local)
#
# Arguments:
# WORKTREE path to the worktree (caller must have validated it)
# BRANCH expected branch name for the push (caller-validated;
# lib does NOT re-derive via `rev-parse --abbrev-ref`
# because a detached HEAD would silently fall back to
# the literal "HEAD" and misclassify push failures).
# COMMIT_MSG commit message (must not contain newline / CR — callers
# that read from user input should validate first)
# PATH1... pathspecs to `git add --`. At least one is required.
#
# Exit codes:
# 0 success — committed and pushed
# 2 argument error (missing worktree / branch / commit message / pathspec)
# 3 git add or commit failed (error details already on stderr)
# 4 commit OK, push failed (caller should emit wiki_ingest_push_failed
# sentinel and decide whether to exit 4 or continue)
# 5 no staged diff after add (no-op, caller decides skip/success)
#
# stdout:
# On exit 0 or 4: "head=<sha>; push=<ok|failed>"
# On exit 5: (empty — caller emits its own reason=no-staged-diff)
# Otherwise: empty (errors are on stderr)
#
# Contract:
# - Does NOT toggle `set -e` / `set -u` / `set -o pipefail`. The
# function saves the caller's `errexit` state before any `set +e`
# probe and restores it before return, so the caller's shell-option
# environment is preserved in every exit path.
# - Does NOT install EXIT / INT / TERM / HUP traps that persist past
# return. Any trap installed for internal tempfile cleanup is
# restored to the caller's previous trap via `trap -p` / `eval`
# before every return path, so the caller may install its own
# outer trap without surprise clobbering.
# - Signal-handling limitation: while this helper is executing, its
# internal trap OVERRIDES the caller's signal traps for EXIT / INT
# / TERM / HUP. Signals delivered during the helper body (e.g.
# user Ctrl-C while `git push` is in flight) clean up the helper's
# internal tempfiles only — the caller's signal-driven cleanup
# (e.g. stash pop on SIGINT) is NOT invoked until after the helper
# returns and the caller's trap is restored. Callers that need
# signal-safe rollback during helper execution must either wrap
# the helper in their own subshell or accept best-effort cleanup.
# - Nested function `_wtgp_restore_caller_state` leaks into the
# caller's global scope (bash dynamic scoping). The underscore
# prefix marks it as a private helper: callers MUST NOT invoke it
# directly from outside `worktree_commit_push`, and MUST NOT
# redefine a function with the same name.
# - Caller must have ALREADY verified:
# * worktree exists at WORKTREE path
# * worktree HEAD is on BRANCH
# * COMMIT_MSG has been checked for newline/CR injection
# * BRANCH matches the expected wiki.branch_name

# shellcheck source=../../control-char-neutralize.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../control-char-neutralize.sh"

# -----------------------------------------------------------------------
# verify_worktree_branch: confirm a worktree's HEAD is on an expected branch.
#
# Responsibility: hold the single rev-parse --abbrev-ref HEAD verification
# block shared by wiki-worktree-commit.sh and wiki-ingest-commit.sh. Both
# callers need essentially the same sequence (mktemp stderr tempfile +
# scope-limited trap + `set +e` / `set -e` fence + rev-parse + ERROR +
# `head -3` + rm -f + branch compare) with only the tempfile prefix differing.
# Centralizing that logic here lets fixes propagate to both callers automatically.
#
# Usage:
# verify_worktree_branch "$worktree_path" "$wiki_branch" "wwc" "$extra_hint"
# # returns 0 if worktree HEAD == expected_branch
# # returns non-zero after emitting ERROR to stderr (caller should exit 1)
#
# Arguments:
# WORKTREE worktree path (caller has already confirmed existence)
# EXPECTED_BRANCH branch name the worktree must be on
# TEMPFILE_TAG short tag (4-8 chars) for the mktemp prefix, so
# concurrent runs from different callers produce
# distinguishable tempfile names. Example: "wwc",
# "wic-wt".
# EXTRA_HINT optional extra stderr line to emit when the branch
# mismatch is detected (used by ingest-commit.sh to
# clarify that silent fall-through would be even more
# confusing). Pass empty string to omit.
#
# Exit codes:
# 0 worktree is on expected branch
# 2 rev-parse failed (worktree corrupt / permission / git binary issue)
# 3 worktree is on a different branch
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
 rev_parse_err=$(mktemp "${TMPDIR:-/tmp}/rite-${tempfile_tag}-revparse-err-XXXXXX" 2>/dev/null) || rev_parse_err=""

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
 if [[ -n "$_vwb_outer_int" ]]; then eval "$_vwb_outer_int"; else trap - INT; fi
 if [[ -n "$_vwb_outer_term" ]]; then eval "$_vwb_outer_term"; else trap - TERM; fi
 if [[ -n "$_vwb_outer_hup" ]]; then eval "$_vwb_outer_hup"; else trap - HUP; fi
 }

 if [ "$wt_head_rc" -ne 0 ]; then
 echo "ERROR: git -C '$worktree' rev-parse --abbrev-ref HEAD が失敗しました (rc=$wt_head_rc)" >&2
 if [ -n "$rev_parse_err" ] && [ -s "$rev_parse_err" ]; then
 head -3 "$rev_parse_err" | neutralize_ctrl --keep-newline | sed 's/^/ git: /' >&2
 fi
 echo " 原因候補: worktree corrupt (.git file 破損) / permission denied / git binary 異常" >&2
 echo " 対処: git worktree remove '$worktree' && bash plugins/rite/hooks/scripts/wiki-worktree-setup.sh" >&2
 [ -n "$rev_parse_err" ] && rm -f "$rev_parse_err"
 _vwb_restore_traps
 return 2
 fi
 [ -n "$rev_parse_err" ] && rm -f "$rev_parse_err"
 _vwb_restore_traps

 if [ "$wt_head" != "$expected_branch" ]; then
 echo "ERROR: worktree at '$worktree' is on branch '$wt_head', expected '$expected_branch'" >&2
 echo " hint: git -C '$worktree' checkout '$expected_branch'" >&2
 if [ -n "$extra_hint" ]; then
 echo " $extra_hint" >&2
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
 if [[ -n "$_wtgp_outer_int" ]]; then eval "$_wtgp_outer_int"; else trap - INT; fi
 if [[ -n "$_wtgp_outer_term" ]]; then eval "$_wtgp_outer_term"; else trap - TERM; fi
 if [[ -n "$_wtgp_outer_hup" ]]; then eval "$_wtgp_outer_hup"; else trap - HUP; fi
 # Restore errexit.
 if [[ $_wtgp_errexit -eq 1 ]]; then set -e; else set +e; fi
 }

 local add_err="" diff_err="" commit_err=""
 # Internal cleanup trap (EXIT only — caller's signal traps are
 # re-applied below on any non-signal return path).
 trap 'rm -f "${add_err:-}" "${diff_err:-}" "${commit_err:-}"' EXIT INT TERM HUP

 # mktemp failures are surfaced to stderr (not silently swallowed) so
 # operators can see when stderr capture is degraded to /dev/null.
 if ! add_err=$(mktemp "${TMPDIR:-/tmp}/rite-wtgit-add-err-XXXXXX" 2>/dev/null); then
 echo "WARNING: mktemp for worktree_commit_push add stderr capture failed — diagnostics will be lost" >&2
 add_err=""
 fi
 if ! diff_err=$(mktemp "${TMPDIR:-/tmp}/rite-wtgit-diff-err-XXXXXX" 2>/dev/null); then
 echo "WARNING: mktemp for worktree_commit_push diff stderr capture failed — diagnostics will be lost" >&2
 diff_err=""
 fi
 if ! commit_err=$(mktemp "${TMPDIR:-/tmp}/rite-wtgit-commit-err-XXXXXX" 2>/dev/null); then
 echo "WARNING: mktemp for worktree_commit_push commit stderr capture failed — diagnostics will be lost" >&2
 commit_err=""
 fi

 # Step 1: stage paths. Quote the first pathspec in the error message
 # to mirror the pre-refactor wiki-worktree-commit.sh format, so log
 # greppers that anchor on `'<path>'` keep working.
 local _first_path="$1"
 if ! git -C "$worktree" add -- "$@" 2>"${add_err:-/dev/null}"; then
 echo "ERROR: git add '$_first_path' failed in worktree '$worktree'" >&2
 [ -n "$add_err" ] && [ -s "$add_err" ] && head -n 10 "$add_err" | neutralize_ctrl --keep-newline | sed 's/^/ git: /' >&2
 echo " hint: index lock / path error / permission denied のいずれかを確認してください" >&2
 rm -f "${add_err:-}" "${diff_err:-}" "${commit_err:-}"
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
 rm -f "${add_err:-}" "${diff_err:-}" "${commit_err:-}"
 _wtgp_restore_caller_state
 return 5
 ;;
 1) ;; # staged diff present, proceed
 *)
 echo "ERROR: git diff --cached failed in worktree '$worktree' (rc=$cached_rc)" >&2
 [ -n "$diff_err" ] && [ -s "$diff_err" ] && head -n 10 "$diff_err" | neutralize_ctrl --keep-newline | sed 's/^/ git: /' >&2
 rm -f "${add_err:-}" "${diff_err:-}" "${commit_err:-}"
 _wtgp_restore_caller_state
 return 3
 ;;
 esac

 # Step 3: commit
 if ! git -C "$worktree" commit --quiet -m "$commit_msg" 2>"${commit_err:-/dev/null}"; then
 echo "ERROR: git commit failed in worktree '$worktree'" >&2
 [ -n "$commit_err" ] && [ -s "$commit_err" ] && head -n 10 "$commit_err" | neutralize_ctrl --keep-newline | sed 's/^/ git: /' >&2
 echo " hint: pre-commit hook / gpg sign / author config / permission のいずれかを確認" >&2
 rm -f "${add_err:-}" "${diff_err:-}" "${commit_err:-}"
 _wtgp_restore_caller_state
 return 3
 fi

 # head_sha capture: post-commit rev-parse should normally succeed. If it
 # fails (corrupt worktree between commit and rev-parse, extremely rare),
 # surface a WARNING rather than silently embedding "unknown" in the
 # status line — otherwise the caller sees `head=unknown` and treats it
 # as a successful commit.
 local head_sha head_err=""
 # Extend internal trap to cover head_err so SIGINT / SIGTERM / SIGHUP during
 # the post-commit rev-parse cannot leak the tempfile. Must be set BEFORE mktemp.
 trap 'rm -f "${add_err:-}" "${diff_err:-}" "${commit_err:-}" "${head_err:-}"' EXIT INT TERM HUP
 head_err=$(mktemp "${TMPDIR:-/tmp}/rite-wtgit-head-err-XXXXXX" 2>/dev/null) || head_err=""
 if head_sha=$(git -C "$worktree" rev-parse HEAD 2>"${head_err:-/dev/null}"); then
 :
 else
 local head_rc=$?
 echo "WARNING: git -C '$worktree' rev-parse HEAD failed post-commit (rc=$head_rc)" >&2
 [ -n "$head_err" ] && [ -s "$head_err" ] && head -n 5 "$head_err" | neutralize_ctrl --keep-newline | sed 's/^/ git: /' >&2
 echo " head SHA will be reported as 'unknown' — the commit itself succeeded but the worktree may be corrupt" >&2
 head_sha="unknown"
 fi
 [ -n "$head_err" ] && rm -f "$head_err"

 # (wiki push batch/defer): a caller processing several commits in a
 # loop (wiki-ingest per raw source) sets WTGP_COMMIT_ONLY=1 to stage+commit
 # here WITHOUT pushing, then pushes once at the end of the loop via
 # worktree_push_branch directly. A plain env var (not a new positional
 # parameter) keeps the existing 3-fixed-args + variadic-paths call
 # signature — and every existing caller (wiki-init / standalone
 # wiki-lint) — untouched.
 if [[ "${WTGP_COMMIT_ONLY:-0}" == "1" ]]; then
 echo "head=${head_sha}"
 rm -f "${add_err:-}" "${diff_err:-}" "${commit_err:-}"
 _wtgp_restore_caller_state
 return 0
 fi

 # Step 4: push using the caller-supplied branch. The NFF-retry push logic
 # lives in worktree_push_branch so a batch caller can invoke it
 # standalone (push-only, after N commit-only commits) without duplicating
 # the retry loop here — this call is that same function used inline for
 # the traditional commit-then-push-immediately path.
 local push_out push_rc
 push_out=$(worktree_push_branch "$worktree" "$branch")
 push_rc=$?
 echo "$push_out"

 rm -f "${add_err:-}" "${diff_err:-}" "${commit_err:-}"
 _wtgp_restore_caller_state

 if [[ $push_rc -ne 0 ]]; then
 return 4
 fi
 return 0
}

# -----------------------------------------------------------------------
# worktree_push_branch: push WORKTREE's local BRANCH to origin, retrying
# on non-fast-forward rejection (fetch + rebase) up to 3 attempts.
#
# Responsibility ( wiki push batch/defer): hold the push-with-retry
# logic extracted from worktree_commit_push's Step 4, so a caller that has
# accumulated several WTGP_COMMIT_ONLY=1 commits (wiki-ingest processing
# multiple raw sources) can push them all with a single call instead of
# once per commit. worktree_commit_push calls this same function for its
# own Step 4, so the retry behavior is identical on both paths.
#
# Usage:
#   worktree_push_branch "$worktree" "$branch"
#   rc=$?
#   case "$rc" in
#     0) ;; # pushed (or origin already up to date)
#     2) ;; # argument error
#     4) ;; # push failed after retry budget exhausted — commit(s) stay local
#   esac
#
# Arguments:
#   WORKTREE  path to the worktree (caller must have validated it)
#   BRANCH    branch name to push (caller-validated; no silent
#             rev-parse --abbrev-ref HEAD fallback — mirrors
#             worktree_commit_push's detached-HEAD rationale)
#
# Self-gate: if BRANCH has no commits that the locally-known origin/BRANCH
# lacks (`git rev-list origin/BRANCH..BRANCH --count`, no fetch — a pure
# local ref comparison), no push is attempted at all (`push=no-op`). This
# costs nothing extra on the commit-then-push-immediately path (a just-made
# commit is always "ahead"), and lets a batch caller invoke this
# function unconditionally after a commit-only loop — without tracking its
# own commit count, and without the network call this Issue is reducing
# when there is genuinely nothing new to push (including a stale
# already-committed-but-unpushed state left by a prior failed run: the
# next call that reaches this function flushes it).
#
# Exit codes:
#   0  push succeeded, or origin already up to date (push=no-op)
#   2  argument error (missing worktree / branch)
#   4  push failed after retry budget exhausted (error already on stderr)
#
# stdout: "head=<sha>; push=<ok|failed|no-op>"
#
# Contract: does not toggle caller's `set -e` / traps (same discipline as
# worktree_commit_push — see that function's header for the full rationale).
worktree_push_branch() {
 local worktree="$1" branch="$2"

 if [[ -z "$worktree" ]] || [[ -z "$branch" ]]; then
 echo "ERROR: worktree_push_branch: WORKTREE / BRANCH required" >&2
 return 2
 fi

 local _wpb_errexit=0
 case $- in *e*) _wpb_errexit=1 ;; esac

 local _wpb_outer_exit _wpb_outer_int _wpb_outer_term _wpb_outer_hup
 _wpb_outer_exit=$(trap -p EXIT)
 _wpb_outer_int=$(trap -p INT)
 _wpb_outer_term=$(trap -p TERM)
 _wpb_outer_hup=$(trap -p HUP)

 _wpb_restore_caller_state() {
 if [[ -n "$_wpb_outer_exit" ]]; then eval "$_wpb_outer_exit"; else trap - EXIT; fi
 if [[ -n "$_wpb_outer_int" ]]; then eval "$_wpb_outer_int"; else trap - INT; fi
 if [[ -n "$_wpb_outer_term" ]]; then eval "$_wpb_outer_term"; else trap - TERM; fi
 if [[ -n "$_wpb_outer_hup" ]]; then eval "$_wpb_outer_hup"; else trap - HUP; fi
 if [[ $_wpb_errexit -eq 1 ]]; then set -e; else set +e; fi
 }

 local push_err="" head_err=""
 trap 'rm -f "${push_err:-}" "${head_err:-}"' EXIT INT TERM HUP

 if ! push_err=$(mktemp "${TMPDIR:-/tmp}/rite-wtgit-push-err-XXXXXX" 2>/dev/null); then
 echo "WARNING: mktemp for worktree_push_branch push stderr capture failed — diagnostics will be lost" >&2
 push_err=""
 fi
 if ! head_err=$(mktemp "${TMPDIR:-/tmp}/rite-wtgit-head-err-XXXXXX" 2>/dev/null); then
 echo "WARNING: mktemp for worktree_push_branch head stderr capture failed — diagnostics will be lost" >&2
 head_err=""
 fi

 # head_sha here reports whatever is currently on BRANCH (the commit(s)
 # about to be pushed) — not necessarily one just made in this call, since
 # this function is also invoked standalone after a batch of prior
 # WTGP_COMMIT_ONLY=1 commits.
 local head_sha
 if head_sha=$(git -C "$worktree" rev-parse HEAD 2>"${head_err:-/dev/null}"); then
 :
 else
 local head_rc=$?
 echo "WARNING: git -C '$worktree' rev-parse HEAD failed (rc=$head_rc)" >&2
 [ -n "$head_err" ] && [ -s "$head_err" ] && head -n 5 "$head_err" | neutralize_ctrl --keep-newline | sed 's/^/ git: /' >&2
 head_sha="unknown"
 fi
 [ -n "$head_err" ] && rm -f "$head_err"

 # Self-gate (see function header): skip the push entirely when there is
 # nothing local-only to send. Failure to compute ahead_count (rev-list
 # error, unexpected output) falls through to attempting the push rather
 # than silently skipping it.
 local ahead_count
 if ahead_count=$(git -C "$worktree" rev-list "origin/${branch}..${branch}" --count 2>/dev/null) \
   && [[ "$ahead_count" =~ ^[0-9]+$ ]] && [ "$ahead_count" -eq 0 ]; then
 echo "head=${head_sha}; push=no-op"
 rm -f "${push_err:-}" "${head_err:-}"
 _wpb_restore_caller_state
 return 0
 fi

 # Push using the caller-supplied branch (no silent `rev-parse
 # --abbrev-ref HEAD` fallback to literal "HEAD"). On a non-fast-forward
 # rejection (a concurrent session advanced origin/<branch>), fetch +
 # rebase onto origin/<branch> and retry, up to 3 push attempts
 # (multi-session design §9). wiki commits are append-mostly (new raw /
 # new pages / log appends) so the rebase is almost always conflict-free;
 # a rebase conflict aborts and falls through to the existing rc=4.
 # Non-NFF failures (auth / network) do NOT retry — they fail
 # immediately (AC-3: a deferred push that fails is surfaced and
 # left for manual/next-session recovery, not auto-retried within the
 # same flow).
 local push_status="failed" _push_max=3 _push_i=0
 while [ "$_push_i" -lt "$_push_max" ]; do
 _push_i=$((_push_i + 1))
 [ -n "$push_err" ] && : > "$push_err"
 if git -C "$worktree" push --quiet origin "$branch" 2>"${push_err:-/dev/null}"; then
 push_status="ok"
 break
 fi
 # Classify the failure. Only a non-fast-forward rejection is retried.
 if ! { [ -n "$push_err" ] && grep -qiE 'rejected|non-fast-forward|fetch first|behind' "$push_err"; }; then
 echo "WARNING: git push origin '$branch' failed in worktree '$worktree' — commit is local only" >&2
 [ -n "$push_err" ] && [ -s "$push_err" ] && head -n 10 "$push_err" | neutralize_ctrl --keep-newline | sed 's/^/ git: /' >&2
 echo " manual recovery: git -C '$worktree' push origin '$branch'" >&2
 break
 fi
 if [ "$_push_i" -ge "$_push_max" ]; then
 echo "WARNING: git push origin '$branch' rejected (non-fast-forward) after $_push_max attempts — commit is local only" >&2
 [ -n "$push_err" ] && [ -s "$push_err" ] && head -n 10 "$push_err" | neutralize_ctrl --keep-newline | sed 's/^/ git: /' >&2
 echo " manual recovery: git -C '$worktree' fetch origin '$branch' && git -C '$worktree' rebase 'origin/$branch' && git -C '$worktree' push origin '$branch'" >&2
 break
 fi
 echo "WARNING: push rejected (non-fast-forward) — fetch + rebase onto origin/$branch + retry (attempt $_push_i/$_push_max)" >&2
 if ! git -C "$worktree" fetch --quiet origin "$branch" 2>"${push_err:-/dev/null}"; then
 echo "WARNING: fetch origin '$branch' failed during non-fast-forward retry — commit is local only" >&2
 [ -n "$push_err" ] && [ -s "$push_err" ] && head -n 10 "$push_err" | neutralize_ctrl --keep-newline | sed 's/^/ git: /' >&2
 break
 fi
 if ! git -C "$worktree" rebase --quiet "origin/$branch" 2>"${push_err:-/dev/null}"; then
 git -C "$worktree" rebase --abort 2>/dev/null || true
 echo "WARNING: rebase onto origin/$branch failed (conflict) — aborted; push not retried (commit is local only)" >&2
 [ -n "$push_err" ] && [ -s "$push_err" ] && head -n 10 "$push_err" | neutralize_ctrl --keep-newline | sed 's/^/ git: /' >&2
 echo " manual recovery: git -C '$worktree' fetch origin '$branch' && git -C '$worktree' rebase 'origin/$branch'" >&2
 break
 fi
 # rebase succeeded — loop back and retry the push.
 done

 echo "head=${head_sha}; push=${push_status}"

 rm -f "${push_err:-}" "${head_err:-}"
 _wpb_restore_caller_state

 if [[ "$push_status" == "failed" ]]; then
 return 4
 fi
 return 0
}

# -----------------------------------------------------------------------
# ensure_session_worktree: detect + reconstruct a multi_session session
# worktree for an Issue at a flow ENTRY path.
#
# This is the single bash-side SoT for the "branch exists ∧ worktree
# absent → reconstruct" gate that first introduced inline in
# recover.md. It performs detection AND reconstruction (git worktree add);
# the EnterWorktree tool call and any AskUserQuestion routing stay with the
# LLM caller, driven by the emitted [CONTEXT] WT_ENSURE marker. The
# canonical marker→action routing table lives in skills/recover/SKILL.md
# Phase 3.1.5 (consumed verbatim by review / iterate / fix).
#
# It does NOT call EnterWorktree (an LLM tool, not a shell command) and it
# NEVER `git switch -c`-es onto the main checkout — a missing worktree is
# reconstructed in place or reported, never silently bypassed.
#
# Usage:
#   ensure_session_worktree --issue <N> [--branch <branch>] [--worktree-base <base>]
#   bash lib/worktree-git.sh ensure-session-worktree --issue <N> [...]
#
# Arguments:
#   --issue          Issue number (required, numeric)
#   --branch         feature branch name. Optional — resolved from
#                    local/remote refs matching issue-<N> when omitted.
#   --worktree-base  override multi_session.worktree_base (default: parsed
#                    from rite-config.yml, fallback .rite/worktrees)
#
# stdout (always exactly one marker line):
#   [CONTEXT] WT_ENSURE=<case>; path=<wt_path>; branch=<branch>[; other=<p>]
#
# <case> → caller action:
#   disabled              multi_session off → no-op, proceed on main checkout
#   already_in            registered AND cwd already inside it → no-op
#   reenter               registered, cwd elsewhere → EnterWorktree(path)
#   reconstructed         was missing, branch existed (local/remote),
#                         `git worktree add` succeeded → EnterWorktree(path)
#   residue               path exists but not a registered worktree (prune
#                         did not clear) → AskUserQuestion (rm -rf + re-run / abort)
#   branch_other_worktree branch checked out in ANOTHER worktree → caller
#                         aborts (concurrent session; structural double-start guard)
#   branch_absent         branch exists nowhere → caller delegates to its
#                         existing non-existence handling; DO NOT reconstruct
#   failed                fetch / git worktree add failed → caller STOPS loud;
#                         NO silent fallback to the main checkout
#
# Exit codes:
#   0  disabled|already_in|reenter|reconstructed|residue|branch_other_worktree|branch_absent
#   1  failed (cause on stderr; marker still emitted on stdout)
#   2  argument error (missing/invalid --issue)
#
# stdout discipline: every git command that could print to stdout is
# captured into a variable or redirected to stderr (1>&2) / /dev/null, so
# the marker line is the ONLY thing on stdout (callers grep for it).
ensure_session_worktree() {
  local issue="" branch="" wt_base_override=""
  while [ $# -gt 0 ]; do
    case "$1" in
      # `shift 2 || shift`: a value-taking flag passed as the LAST token (no
      # value) leaves $#=1; bash `shift 2` is then a no-op non-zero return and
      # the while loop would spin forever. The `|| shift` advances past the
      # lone flag so the loop terminates (issue/branch stay "" → caught by the
      # numeric guard below). Mirrors worktree-foreign-cwd.sh's underflow guard.
      --issue)         issue="${2:-}"; shift 2 || shift ;;
      --branch)        branch="${2:-}"; shift 2 || shift ;;
      --worktree-base) wt_base_override="${2:-}"; shift 2 || shift ;;
      *)               shift ;;
    esac
  done

  case "$issue" in
    ''|*[!0-9]*)
      echo "ERROR: ensure_session_worktree: --issue <N> (numeric) required" >&2
      return 2 ;;
  esac

  # --- read multi_session (same parser as open Step 2.1-G / recover.md Phase 1.1) ---
  local ms_section ms_enabled ms_base
  ms_section=$(sed -n '/^multi_session:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null) || ms_section=""
  ms_enabled=$(printf '%s\n' "$ms_section" | awk '/^[[:space:]]+enabled:/ {print; exit}' \
    | sed 's/[[:space:]]#.*//' | sed 's/.*enabled:[[:space:]]*//' | tr -d '[:space:]"'"'"'' | tr '[:upper:]' '[:lower:]')
  case "$ms_enabled" in true|yes|1) ms_enabled=true ;; *) ms_enabled=false ;; esac
  if [ -n "$wt_base_override" ]; then
    ms_base="$wt_base_override"
  else
    ms_base=$(printf '%s\n' "$ms_section" | awk '/^[[:space:]]+worktree_base:/ {print; exit}' \
      | sed 's/[[:space:]]#.*//' | sed 's/.*worktree_base:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
    [ -n "$ms_base" ] || ms_base=".rite/worktrees"
  fi

  if [ "$ms_enabled" != "true" ]; then
    echo "[CONTEXT] WT_ENSURE=disabled; path=; branch=$branch"
    return 0
  fi

  # --- derive the MAIN checkout root via --git-common-dir, NOT
  #     --show-toplevel (which returns the worktree itself when we are
  #     already inside one, breaking the already_in compare). ---
  local git_common main_root
  git_common=$(git rev-parse --git-common-dir 2>/dev/null) || {
    echo "ERROR: ensure_session_worktree: not in a git repository (issue #$issue)" >&2
    echo "[CONTEXT] WT_ENSURE=failed; path=; branch=$branch"
    return 1
  }
  case "$git_common" in /*) ;; *) git_common="$(pwd -P)/$git_common" ;; esac
  main_root=$(cd -- "$(dirname -- "$git_common")" 2>/dev/null && pwd -P) || main_root="$(pwd -P)"

  # --- compute this issue's session worktree path ---
  local wt_path
  case "$ms_base" in
    /*) wt_path="$ms_base/issue-$issue" ;;
    *)  wt_path="$main_root/$ms_base/issue-$issue" ;;
  esac

  # --- resolve the branch from issue-<N> refs when not supplied ---
  if [ -z "$branch" ]; then
    branch=$(git for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null \
      | grep -E "(^|/)issue-${issue}(-|$)" | head -1)
    if [ -z "$branch" ]; then
      branch=$(git for-each-ref --format='%(refname:short)' refs/remotes/origin/ 2>/dev/null \
        | sed 's|^origin/||' | grep -E "(^|/)issue-${issue}(-|$)" | head -1)
    fi
  fi

  # --- detection: registered / already_in / reenter / residue ---
  local cur_top registered
  cur_top=$(git rev-parse --show-toplevel 2>/dev/null) || cur_top=""
  registered=$(git worktree list --porcelain 2>/dev/null | awk -v p="$wt_path" '$1=="worktree" && $2==p {print "yes"}')

  if [ "$registered" = "yes" ] && [ "$cur_top" = "$wt_path" ]; then
    echo "[CONTEXT] WT_ENSURE=already_in; path=$wt_path; branch=$branch"
    return 0
  fi
  if [ "$registered" = "yes" ]; then
    echo "[CONTEXT] WT_ENSURE=reenter; path=$wt_path; branch=$branch"
    return 0
  fi
  if [ -e "$wt_path" ]; then
    git worktree prune >/dev/null 2>&1 || true
    if [ -e "$wt_path" ]; then
      echo "[CONTEXT] WT_ENSURE=residue; path=$wt_path; branch=$branch"
      return 0
    fi
  fi

  # --- worktree missing → reconstruct only if the branch exists somewhere ---
  # If the branch is checked out in ANOTHER worktree (concurrent session),
  # do not reconstruct — mirror open.md's branch_other_worktree guard.
  if [ -n "$branch" ]; then
    local branch_wt
    branch_wt=$(git worktree list --porcelain 2>/dev/null | awk -v b="refs/heads/$branch" '
      $1=="worktree"{wt=$2} $1=="branch" && $2==b {print wt}')
    if [ -n "$branch_wt" ]; then
      echo "[CONTEXT] WT_ENSURE=branch_other_worktree; path=$wt_path; branch=$branch; other=$branch_wt"
      return 0
    fi
  fi

  local branch_local=no branch_remote=no
  if [ -n "$branch" ]; then
    git rev-parse --verify --quiet "refs/heads/$branch" >/dev/null 2>&1 && branch_local=yes
    git rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null 2>&1 && branch_remote=yes
  fi

  if [ "$branch_local" = yes ]; then
    if git worktree add "$wt_path" "$branch" 1>&2; then
      # Dogfooding override: .claude/ is gitignored so `git worktree
      # add` never copies it. Without this, a reconstructed session worktree
      # loses enabledPlugins["rite@rite-marketplace"]:false and the stale
      # marketplace-cached skill definitions load instead of local plugins/rite.
      if [ -f "$main_root/.claude/settings.local.json" ] && ! { mkdir -p "$wt_path/.claude" && cp "$main_root/.claude/settings.local.json" "$wt_path/.claude/settings.local.json"; } 2>/dev/null; then
        echo "WARNING: ensure_session_worktree: .claude/settings.local.json のコピーに失敗しました（issue #${issue}）— ドッグフーディング上書きが worktree に反映されません" >&2
      fi
      echo "[CONTEXT] WT_ENSURE=reconstructed; path=$wt_path; branch=$branch"
      return 0
    fi
    echo "ERROR: ensure_session_worktree: git worktree add '$wt_path' '$branch' failed (issue #$issue)" >&2
    echo "  recovery: restart Claude Code from the repo root, or run: git worktree add '$wt_path' '$branch'" >&2
    echo "[CONTEXT] WT_ENSURE=failed; path=$wt_path; branch=$branch"
    return 1
  fi

  if [ "$branch_remote" = yes ]; then
    # fetch is best-effort (do NOT hard-fail — an offline resume must still
    # reconstruct from the existing origin/$branch ref). But all-retries-
    # exhausted is surfaced as a WARNING rather than swallowed, so a stale
    # reconstruction is never silent (error table: 取得不能を明示).
    local n=0 fetch_ok=no
    while [ "$n" -lt 3 ]; do
      if git fetch origin "$branch" >/dev/null 2>&1; then fetch_ok=yes; break; fi
      n=$((n+1)); [ "$n" -lt 3 ] && sleep 1
    done
    if [ "$fetch_ok" != yes ]; then
      echo "WARNING: ensure_session_worktree: git fetch origin '$branch' が 3 回失敗しました — 既存の origin/${branch}（stale の可能性）から再構築します (issue #$issue)" >&2
    fi
    if git worktree add --track -b "$branch" "$wt_path" "origin/$branch" 1>&2; then
      # Dogfooding override: see the branch_local reconstruction
      # branch above for why this copy is needed.
      if [ -f "$main_root/.claude/settings.local.json" ] && ! { mkdir -p "$wt_path/.claude" && cp "$main_root/.claude/settings.local.json" "$wt_path/.claude/settings.local.json"; } 2>/dev/null; then
        echo "WARNING: ensure_session_worktree: .claude/settings.local.json のコピーに失敗しました（issue #${issue}）— ドッグフーディング上書きが worktree に反映されません" >&2
      fi
      echo "[CONTEXT] WT_ENSURE=reconstructed; path=$wt_path; branch=$branch"
      return 0
    fi
    echo "ERROR: ensure_session_worktree: git worktree add --track -b '$branch' '$wt_path' 'origin/$branch' failed (issue #$issue)" >&2
    echo "  recovery: restart Claude Code from the repo root, or run the add manually" >&2
    echo "[CONTEXT] WT_ENSURE=failed; path=$wt_path; branch=$branch"
    return 1
  fi

  # branch exists nowhere → delegate to the caller's non-existence handling.
  echo "[CONTEXT] WT_ENSURE=branch_absent; path=$wt_path; branch=$branch"
  return 0
}

# -----------------------------------------------------------------------
# Standalone CLI dispatch. Sourcing this file is a no-op here (the guard is
# false); running it as `bash lib/worktree-git.sh <subcommand>` dispatches.
# Only ensure-session-worktree is exposed; the commit/push helpers above
# are source-only by design.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    ensure-session-worktree)
      shift
      ensure_session_worktree "$@"
      exit $?
      ;;
    *)
      echo "ERROR: worktree-git.sh: unknown subcommand '${1:-}' (expected: ensure-session-worktree)" >&2
      exit 2
      ;;
  esac
fi
