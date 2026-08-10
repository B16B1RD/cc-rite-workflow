#!/bin/bash
# Tests for cleanup-worktree-detect.sh — cleanup.md ステップ 4-W の session-worktree
# 検出を物理 cwd ベースに頑健化する純粋ロジック。
#
#   AC-1 (T-01): flow-state 未記録でも物理 cwd が当該 Issue の worktree なら
#                in_worktree_unrecorded を返し worktree= に cur_top を導出する。
#   AC-3 (T-03): flow_wt 記録ありで cwd 一致 → 従来どおり in_worktree（後方互換）。
#   AC-4 (T-04): flow_wt 記録あり but cwd 不一致 → in_main / multi_session 無効 → none。
#   AC-5 (T-05): cur_top 空 → 物理導出を発火させず none（安全側）。
#   AC-6 (T-06): cwd が別 Issue の worktree（issue-M, M≠N）→ 導出しない（none）。
#   境界: cwd が main checkout（worktree でない）+ flow_wt 空 → none。
#         worktree_base が既定以外でも leaf を照合して導出する。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

DETECT="$SCRIPT_DIR/../scripts/cleanup-worktree-detect.sh"

# Helper: run detect and return the bare CLEANUP_WT state token.
detect_state() {
  bash "$DETECT" "$@" | sed 's/CLEANUP_WT=\([^;]*\);.*/\1/'
}
# Helper: run detect and return the derived worktree= value.
detect_wt() {
  bash "$DETECT" "$@" | sed 's/.*worktree=//'
}

WT="/repo/.rite/worktrees/issue-1622"

# --- TC-1 (AC-1, T-01): unrecorded physical worktree ---
echo "=== TC-1: flow_wt empty + cwd is this issue's worktree → in_worktree_unrecorded ==="
assert "TC-1 state" "in_worktree_unrecorded" \
  "$(detect_state --ms-enabled true --flow-wt "" --cur-top "$WT" --issue 1622)"
assert "TC-1 derives cur_top into worktree=" "$WT" \
  "$(detect_wt --ms-enabled true --flow-wt "" --cur-top "$WT" --issue 1622)"

# --- TC-2 (AC-3, T-03): recorded worktree, cwd matches → in_worktree (backward compat) ---
echo "=== TC-2: flow_wt recorded + cwd matches → in_worktree ==="
assert "TC-2 state" "in_worktree" \
  "$(detect_state --ms-enabled true --flow-wt "$WT" --cur-top "$WT" --issue 1622)"
assert "TC-2 keeps recorded worktree=" "$WT" \
  "$(detect_wt --ms-enabled true --flow-wt "$WT" --cur-top "$WT" --issue 1622)"

# --- TC-3 (AC-4, T-04a): recorded worktree, cwd is main → in_main ---
echo "=== TC-3: flow_wt recorded + cwd is main checkout → in_main ==="
assert "TC-3 state" "in_main" \
  "$(detect_state --ms-enabled true --flow-wt "$WT" --cur-top "/repo" --issue 1622)"
assert "TC-3 keeps recorded worktree=" "$WT" \
  "$(detect_wt --ms-enabled true --flow-wt "$WT" --cur-top "/repo" --issue 1622)"

# --- TC-4 (AC-4, T-04b): multi_session disabled → none ---
echo "=== TC-4: ms_enabled=false → none (even when physically in a worktree) ==="
assert "TC-4 state" "none" \
  "$(detect_state --ms-enabled false --flow-wt "" --cur-top "$WT" --issue 1622)"

# --- TC-5 (AC-5, T-05): cur_top empty → none, no derivation ---
echo "=== TC-5: cur_top empty → none (no physical derivation) ==="
assert "TC-5 state" "none" \
  "$(detect_state --ms-enabled true --flow-wt "" --cur-top "" --issue 1622)"

# --- TC-6 (AC-6, T-06): cwd is a DIFFERENT issue's worktree → none ---
echo "=== TC-6: cwd is issue-9999 but target is 1622 → none (no cross-issue match) ==="
assert "TC-6 state" "none" \
  "$(detect_state --ms-enabled true --flow-wt "" --cur-top "/repo/.rite/worktrees/issue-9999" --issue 1622)"

# --- TC-7 (boundary): cwd is main checkout (not a worktree) + flow_wt empty → none ---
echo "=== TC-7: flow_wt empty + cwd is main checkout (not a worktree) → none ==="
assert "TC-7 state" "none" \
  "$(detect_state --ms-enabled true --flow-wt "" --cur-top "/repo" --issue 1622)"

# --- TC-8 (boundary): custom worktree_base leaf is honored ---
echo "=== TC-8: custom worktree_base leaf → still derives in_worktree_unrecorded ==="
assert "TC-8 state" "in_worktree_unrecorded" \
  "$(detect_state --ms-enabled true --flow-wt "" --cur-top "/repo/.custom/wt/issue-1622" --issue 1622 --worktree-base ".custom/wt")"

# --- TC-9 (boundary): right leaf but wrong dir name (not issue-N) → none ---
echo "=== TC-9: parent leaf=worktrees but dir is not issue-{N} → none ==="
assert "TC-9 state" "none" \
  "$(detect_state --ms-enabled true --flow-wt "" --cur-top "/repo/.rite/worktrees/scratch" --issue 1622)"

# --- TC-10 (AC-6 regression): issue-number prefix collision must NOT match ---
# issue-12 is NOT this session's worktree when the target issue is 1; the full-tail
# match (`.rite/worktrees/issue-1`) must not prefix-match `.../issue-12`.
echo "=== TC-10: cur_top is issue-12 but target is issue-1 → none (no prefix match) ==="
assert "TC-10 state (issue-1 vs issue-12)" "none" \
  "$(detect_state --ms-enabled true --flow-wt "" --cur-top "/repo/.rite/worktrees/issue-12" --issue 1)"
assert "TC-10 state (issue-12 self matches)" "in_worktree_unrecorded" \
  "$(detect_state --ms-enabled true --flow-wt "" --cur-top "/repo/.rite/worktrees/issue-12" --issue 12)"

# --- TC-11 (boundary): absolute worktree_base matches by exact tail equality ---
echo "=== TC-11: absolute worktree_base → derives in_worktree_unrecorded ==="
assert "TC-11 state (abs base)" "in_worktree_unrecorded" \
  "$(detect_state --ms-enabled true --flow-wt "" --cur-top "/abs/wt/issue-1622" --issue 1622 --worktree-base "/abs/wt")"

# --- TC-12 (F3 regression): unrelated parent sharing only the base leaf must NOT match ---
# `/repo/UNRELATED/worktrees/issue-1622` shares the leaf `worktrees` with base
# `expected/worktrees` but the full tail `expected/worktrees/issue-1622` does not
# match — the helper matches the configured tail, not just the leaf.
echo "=== TC-12: unrelated parent with matching leaf only → none ==="
assert "TC-12 state (leaf-only false-positive rejected)" "none" \
  "$(detect_state --ms-enabled true --flow-wt "" --cur-top "/repo/UNRELATED/worktrees/issue-1622" --issue 1622 --worktree-base "expected/worktrees")"

# --- TC-13 (boundary): leading ./ and trailing / in worktree_base are normalized ---
echo "=== TC-13: worktree_base with ./ prefix and trailing / is normalized ==="
assert "TC-13 state (normalized base)" "in_worktree_unrecorded" \
  "$(detect_state --ms-enabled true --flow-wt "" --cur-top "/repo/.rite/worktrees/issue-1622" --issue 1622 --worktree-base "./.rite/worktrees/")"

print_summary "cleanup-worktree-detect.test.sh"
