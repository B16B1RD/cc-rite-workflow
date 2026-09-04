#!/bin/bash
# cleanup-worktree-detect.sh — classify cleanup.md ステップ 4-W's session-worktree
# state from pre-resolved inputs, deriving the worktree path from the PHYSICAL cwd
# when flow-state did not record it.
#
# Why this exists:
#   ステップ 4-W previously trusted ONLY flow-state's `worktree` field (`flow_wt`)
#   as the source of truth for "am I in a session worktree?". When a session runs
#   physically inside `.rite/worktrees/issue-{N}` but flow-state never recorded
#   that path (path-entered a worktree another session created, post-reset
#   flow-state, or a worktree-記録漏れ), the equality test `flow_wt == cur_top`
#   was false with `flow_wt` empty, so 4-W classified `none` and skipped the whole
#   step. The worktree + its checked-out local branch then fell into an air-pocket:
#   neither the in-session removal (4-W skipped) nor the lazy reap
#   (pr-cycle-cleanup.sh Step 5 self-excludes the running session's own worktree)
#   handled them, and (at the time) the lazy reap never deleted branches — so the
#   local branch leaked permanently. A later guard added self-exclusion
#   to the 4-W live-cwd guard so the running session removes its own worktree, and a
#   merge-confirmed branch-recovery path to the lazy reap; this helper's
#   in_worktree_unrecorded routing remains the front-line fix for the detection gap.)
#
#   This helper adds a PHYSICAL derivation: with `flow_wt` empty but `cur_top`
#   shaped like the rite session worktree for THIS issue
#   (`<worktree_base_leaf>/issue-{issue}`), it derives `flow_wt = cur_top` and
#   reports `in_worktree_unrecorded` — routed identically to `in_worktree` by the
#   caller, but distinguished so the completion report can note the unrecorded
#   detection.
#
# Pure path logic (no git / filesystem dependency) so it is unit-testable with
# synthetic paths. The caller still performs the dirty check and the live-cwd
# guard against the returned worktree path.
#
# Usage:
#   cleanup-worktree-detect.sh --ms-enabled <true|false> --flow-wt <path> \
#     --cur-top <path> --issue <N> [--worktree-base <rel|abs path>]
#
# Output (stdout, single line):
#   CLEANUP_WT=<none|in_main|in_worktree|in_worktree_unrecorded>; worktree=<path>
#
# State semantics (matches cleanup.md ステップ 4-W routing):
#   none                    multi_session off, or no worktree association
#   in_main                 flow-state records a worktree but cwd is elsewhere
#                           (resume / main checkout)
#   in_worktree             flow-state records a worktree and cwd is in it
#   in_worktree_unrecorded  flow-state empty, but cwd is physically this issue's
# rite session worktree (derivation)
set -euo pipefail

ms_enabled=""
flow_wt=""
cur_top=""
issue=""
worktree_base=".rite/worktrees"

while [ $# -gt 0 ]; do
  case "$1" in
    --ms-enabled)     ms_enabled="${2:-}"; shift 2 ;;
    --flow-wt)        flow_wt="${2:-}"; shift 2 ;;
    --cur-top)        cur_top="${2:-}"; shift 2 ;;
    --issue)          issue="${2:-}"; shift 2 ;;
    --worktree-base)  worktree_base="${2:-}"; shift 2 ;;
    *)                shift ;;
  esac
done

[ -n "$worktree_base" ] || worktree_base=".rite/worktrees"
# Normalize so the suffix compare is exact: strip a leading `./` and any trailing `/`.
wt_base_norm=${worktree_base#./}
wt_base_norm=${wt_base_norm%/}

state="none"
worktree="$flow_wt"

if [ "$ms_enabled" = "true" ]; then
  if [ -n "$flow_wt" ] && [ "$flow_wt" = "$cur_top" ]; then
    state="in_worktree"
  elif [ -z "$flow_wt" ] && [ -n "$cur_top" ] && [ -n "$issue" ]; then
    # Physical derivation: cwd IS this issue's rite session worktree even
    # though flow-state never recorded it. Match the FULL configured tail
    # `<worktree_base>/issue-<issue>`, NOT just the leaf — so an unrelated parent
    # dir that merely shares the base leaf (e.g. `/x/UNRELATED/worktrees/issue-N`)
    # cannot false-match, and a sibling issue (`issue-12` vs `issue-1`) cannot
    # prefix-match. A relative base matches as a suffix of the absolute cur_top; an
    # absolute base matches by exact equality. Route as in_worktree, flagged unrecorded.
    expected_tail="${wt_base_norm}/issue-${issue}"
    case "$cur_top" in
      "$expected_tail"|*/"$expected_tail")
        state="in_worktree_unrecorded"
        worktree="$cur_top"
        ;;
    esac
  elif [ -n "$flow_wt" ]; then
    state="in_main"
  fi
fi

echo "CLEANUP_WT=${state}; worktree=${worktree}"
