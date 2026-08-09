#!/bin/bash
# Tests for pr-cycle-cleanup.sh Step 5 — session worktree lazy reap
# (S4, multi-session design §8).
#
#   AC-1: a worktree whose claim is LIVE is NOT reaped.
#   AC-2: a worktree whose claim is STALE and clean IS reaped, claim file deleted.
#   AC-3: a DIRTY worktree is NOT reaped (claim stale) — WARNING + manual hint.
#   AC-4: after reap a MERGED branch is recovered (TC-4); an UNMERGED, non-manifest-recorded branch is preserved (B-01) — #1670 refined "preserve the branch" to "recover merge-confirmed branches only, never destroy unmerged work".
#   AC-5: `.rite/wiki-worktree` and non-issue dirs are NOT matched (regression).
#
# Gate 0 — self-exclusion guard. A long-lived session must never
# reap the worktree it is itself running in (the real incident: review Step 1.0.0
# deleted the in-flight worktree under a stale/free claim). TC-7..TC-11 invoke
# cleanup FROM INSIDE the candidate worktree (or via RITE_WORKTREE) and assert it
# survives even when gates 1-3 alone would reap it:
#   TC-7  → AC-1: cwd == self worktree → NOT reaped (would-be-reaped: stale+clean)
#   TC-8  → AC-2: the self-exclusion skip is logged to stderr (not silent)
#   TC-9  → AC-3: a coexisting OTHER stale orphan is still reaped (surgical)
#   TC-10 → AC-4: a dirty self worktree is also never reaped (TC-3 covers
#                       the dirty + non-self half — Gate 3 unchanged)
#   TC-11 → AC-1: RITE_WORKTREE env resolves self even when cwd is elsewhere
#                       (the lost-cwd robustness path; cleanup runs from main checkout)
set -euo pipefail

# Clean session-id env (Issue #1530). The reaper resolves its session via
# `issue-claim.sh check`, which is now env-first; this test makes the reaper act as
# SID_B by writing `.rite-session-id`=SID_B, so the dogfooding session's ambient
# CLAUDE_CODE_SESSION_ID must not leak in (it would make the reaper resolve a foreign
# sid instead of SID_B). run-tests.sh unsets the same vars for suite runs; this keeps
# the standalone run deterministic too.
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

PCC="$SCRIPT_DIR/../scripts/pr-cycle-cleanup.sh"
FS="$SCRIPT_DIR/../flow-state.sh"
IC="$SCRIPT_DIR/../issue-claim.sh"
GIT="git -c user.email=t@test.local -c user.name=test -c commit.gpgsign=false"

cleanup_dirs=()
holder_pids=()   # background processes that hold cwd inside a worktree (Issue #1544 TCs)
cleanup() {
  local p d
  # `|| true`: a holder killed inline earlier is already dead here, so kill returns
  # non-zero — without the guard, set -e would abort the EXIT trap and the whole
  # test would exit non-zero despite all assertions passing.
  for p in "${holder_pids[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
  for d in "${cleanup_dirs[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done
  return 0
}
trap cleanup EXIT

# SID_A = the "working" session that holds the claim; SID_B = the (different)
# session that triggers the reap (a new session-start / another session's
# cleanup). session↔worktree is not 1:1 so the reaping session is never the
# holder in practice.
SID_A="aaaaaaaa-1111-2222-3333-444444444444"
SID_B="bbbbbbbb-5555-6666-7777-888888888888"

# Build a main checkout with multi_session config + a session worktree for issue N.
# Echoes the main repo path. The holder session ($SID_A) gets an active flow-state
# and the claim; `.rite-session-id` is SID_B (the reaping session).
make_repo() {
  local n="$1" root
  root=$(make_sandbox --branch develop)
  printf 'multi_session:\n  enabled: true\n  worktree_base: ".rite/worktrees"\n' > "$root/rite-config.yml"
  printf '%s' "$SID_B" > "$root/.rite-session-id"
  ( cd "$root" && $GIT worktree add -q -b "feat/issue-$n" ".rite/worktrees/issue-$n" >/dev/null 2>&1 )
  RITE_STATE_ROOT="$root" bash "$FS" set --session "$SID_A" --phase implement --issue "$n" --branch "feat/issue-$n" --next n >/dev/null 2>&1
  RITE_STATE_ROOT="$root" bash "$IC" claim --issue "$n" --session "$SID_A" --worktree "$root/.rite/worktrees/issue-$n" >/dev/null 2>&1
  printf '%s' "$root"
}

run_pcc() { ( cd "$1" && bash "$PCC" 2>"$1/pcc.err"; echo "rc=$?" ) ; }

echo "=== TC-1 (AC-1): live claim → worktree NOT reaped ==="
R=$(make_repo 50); cleanup_dirs+=("$R")
# Holder SID_A is active → from the reaping session (SID_B) the claim is "other" (live).
run_pcc "$R" >/dev/null
assert "TC-1 live worktree survives" "1" "$( [ -d "$R/.rite/worktrees/issue-50" ] && echo 1 || echo 0 )"
assert "TC-1 claim file survives" "1" "$( [ -f "$R/.rite/state/issue-claims/issue-50.json" ] && echo 1 || echo 0 )"

echo "=== TC-2 (AC-2): stale claim + clean → reaped, claim deleted ==="
R=$(make_repo 51); cleanup_dirs+=("$R")
# make holder (SID_A) stale (inactive) → from SID_B the claim is "stale"
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
out=$(run_pcc "$R")
assert "TC-2 stale worktree reaped" "0" "$( [ -d "$R/.rite/worktrees/issue-51" ] && echo 1 || echo 0 )"
assert "TC-2 claim file deleted" "0" "$( [ -f "$R/.rite/state/issue-claims/issue-51.json" ] && echo 1 || echo 0 )"
case "$out" in *"session_worktrees=1"*) pass "TC-2 status reports session_worktrees=1" ;; *) fail "TC-2 status: $out" ;; esac

echo "=== TC-4 (#1670): merged-into-base branch recovered after reap ==="
# feat/issue-51 was created from develop with no new commits → merged/even with the
# base, so `git branch -d` recovers it once the worktree is gone (#1670 branch
# recovery, closing the dead-letter gap). Previously the branch was preserved.
assert "TC-4 merged branch feat/issue-51 recovered (gone)" "0" "$( cd "$R" && $GIT rev-parse --verify feat/issue-51 >/dev/null 2>&1 && echo 1 || echo 0 )"
case "$out" in *"session_branches=1"*) pass "TC-4 status reports session_branches=1" ;; *) fail "TC-4 status: $out" ;; esac

echo "=== TC-3 (AC-3): dirty worktree (stale claim) → NOT reaped + WARNING ==="
R=$(make_repo 52); cleanup_dirs+=("$R")
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
echo "uncommitted" > "$R/.rite/worktrees/issue-52/dirty.txt"   # untracked → dirty porcelain
run_pcc "$R" >/dev/null
assert "TC-3 dirty worktree survives" "1" "$( [ -d "$R/.rite/worktrees/issue-52" ] && echo 1 || echo 0 )"
assert_grep "TC-3 WARNING emitted for dirty" "$R/pcc.err" "未コミット変更があるため auto-reap をスキップ"

echo "=== TC-3b (#2048 AC-3/4): ignored ambient files → reaped ==="
R=$(make_repo 55); cleanup_dirs+=("$R")
printf '.claude/\n.mcp.json\n' >> "$R/.gitignore"
( cd "$R" && $GIT add .gitignore && $GIT commit -q -m 'ignore ambient session files' )
( cd "$R/.rite/worktrees/issue-55" && $GIT merge -q --ff-only develop )
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
mkdir -p "$R/.rite/worktrees/issue-55/.claude/agents"
printf 'ambient\n' > "$R/.rite/worktrees/issue-55/.claude/agents/session.md"
printf '{}\n' > "$R/.rite/worktrees/issue-55/.mcp.json"
ambient_filtered=$(cd "$R/.rite/worktrees/issue-55" && bash "$SCRIPT_DIR/../scripts/lib/git-status-filtered.sh")
out=$(run_pcc "$R")
assert "TC-3b filtered status agrees ambient worktree is clean" "" "$ambient_filtered"
assert "TC-3b ambient-only worktree reaped" "0" "$( [ -d "$R/.rite/worktrees/issue-55" ] && echo 1 || echo 0 )"
case "$out" in *"session_worktrees=1"*) pass "TC-3b status reports session_worktrees=1" ;; *) fail "TC-3b status: $out" ;; esac

echo "=== TC-3c (#2048 AC-5): tracked modification remains protected ==="
R=$(make_repo 56); cleanup_dirs+=("$R")
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
printf 'tracked change\n' >> "$R/.rite/worktrees/issue-56/README.md"
run_pcc "$R" >/dev/null
assert "TC-3c tracked-dirty worktree survives" "1" "$( [ -d "$R/.rite/worktrees/issue-56" ] && echo 1 || echo 0 )"
assert_grep "TC-3c tracked dirty emits WARNING" "$R/pcc.err" "未コミット変更があるため auto-reap をスキップ"

echo "=== TC-5 (AC-5): .rite/wiki-worktree + non-issue dirs NOT matched ==="
R=$(make_repo 53); cleanup_dirs+=("$R")
# A wiki-worktree-shaped registered worktree must be excluded by the strict regex.
( cd "$R" && $GIT worktree add -q -b wiki ".rite/wiki-worktree" >/dev/null 2>&1 )
# holder SID_A made stale so issue-53 WOULD be reaped (proves the loop runs)
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
run_pcc "$R" >/dev/null
assert "TC-5 issue-53 reaped (loop active)" "0" "$( [ -d "$R/.rite/worktrees/issue-53" ] && echo 1 || echo 0 )"
assert "TC-5 .rite/wiki-worktree untouched" "1" "$( [ -d "$R/.rite/wiki-worktree" ] && echo 1 || echo 0 )"

echo "=== TC-6: session-start.sh best-effort wiring reaps a stale worktree ==="
R=$(make_repo 54); cleanup_dirs+=("$R")
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
SS="$SCRIPT_DIR/../session-start.sh"
printf '{"session_id":"%s","cwd":"%s","hook_event_name":"SessionStart","source":"startup"}' "$SID_B" "$R" \
  | bash "$SS" >/dev/null 2>&1 || true
assert "TC-6 session-start reaped stale worktree" "0" "$( [ -d "$R/.rite/worktrees/issue-54" ] && echo 1 || echo 0 )"

# Run pr-cycle-cleanup from an arbitrary cwd ($1), capturing stderr to an
# explicit, stable path ($2). Used to simulate self-invocation from INSIDE a
# session worktree — the path the real incident took. RITE_WORKTREE is
# unset so these cases exercise the cwd-based Gate 0 resolution; TC-11 covers the
# env-based path separately. $2 is absolute so the redirect is unaffected by the cd.
run_pcc_from() { ( cd "$1" && env -u RITE_WORKTREE bash "$PCC" 2>"$2"; echo "rc=$?" ) ; }

echo "=== TC-7 (AC-1): cwd == self worktree → NOT reaped even when reapable ==="
R=$(make_repo 60); cleanup_dirs+=("$R")
# Make the holder (SID_A) stale so issue-60 would pass gates 1-3 (clean + stale).
# Only Gate 0 can save it now → non-vacuous (drop Gate 0 and every TC-7 assert flips).
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
out=$(run_pcc_from "$R/.rite/worktrees/issue-60" "$R/pcc.err")
assert "TC-7 self worktree survives (cwd self-exclusion)" "1" "$( [ -d "$R/.rite/worktrees/issue-60" ] && echo 1 || echo 0 )"
assert "TC-7 claim file survives (not reaped)" "1" "$( [ -f "$R/.rite/state/issue-claims/issue-60.json" ] && echo 1 || echo 0 )"
case "$out" in *"session_worktrees=0"*) pass "TC-7 status reports session_worktrees=0" ;; *) fail "TC-7 status: $out" ;; esac

echo "=== TC-8 (AC-2): self-exclusion skip is logged to stderr (not silent) ==="
# Reuses R/pcc.err from TC-7's self-invocation.
assert_grep "TC-8 self-exclusion WARNING on stderr" "$R/pcc.err" "self-exclusion"

echo "=== TC-9 (AC-3): a coexisting OTHER orphan is still reaped (surgical) ==="
R=$(make_repo 61); cleanup_dirs+=("$R")
# A second session worktree (issue-62), also held by SID_A, becomes a reapable
# orphan once SID_A goes stale. Self-exclusion must skip ONLY the self worktree
# (issue-61), never the sibling — proving the guard is surgical, not "skip all".
( cd "$R" && $GIT worktree add -q -b "feat/issue-62" ".rite/worktrees/issue-62" >/dev/null 2>&1 )
RITE_STATE_ROOT="$R" bash "$IC" claim --issue 62 --session "$SID_A" --worktree "$R/.rite/worktrees/issue-62" >/dev/null 2>&1
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
out=$(run_pcc_from "$R/.rite/worktrees/issue-61" "$R/pcc.err")
assert "TC-9 self worktree (issue-61) survives" "1" "$( [ -d "$R/.rite/worktrees/issue-61" ] && echo 1 || echo 0 )"
assert "TC-9 sibling orphan (issue-62) reaped" "0" "$( [ -d "$R/.rite/worktrees/issue-62" ] && echo 1 || echo 0 )"
case "$out" in *"session_worktrees=1"*) pass "TC-9 status reports session_worktrees=1" ;; *) fail "TC-9 status: $out" ;; esac

echo "=== TC-10 (AC-4): a dirty self worktree is also never reaped ==="
# AC-4 = dirty protection unchanged. TC-3 covers dirty + NON-self (Gate 3 path);
# this is the dirty + self half of T-4's "self-exclusion 判定の有無に関わらず".
# Gate 0 sits before Gate 3, so a dirty SELF worktree is skipped via self-exclusion
# (not the dirty gate). Asserting the self-exclusion WARNING (rather than just
# survival) makes TC-10 non-vacuous for Gate 0: drop Gate 0 and the dirty self
# falls through to the Gate 3 dirty WARNING instead, flipping this assert.
R=$(make_repo 63); cleanup_dirs+=("$R")
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
echo "uncommitted" > "$R/.rite/worktrees/issue-63/dirty.txt"   # untracked → dirty porcelain
out=$(run_pcc_from "$R/.rite/worktrees/issue-63" "$R/pcc.err")
assert "TC-10 dirty self worktree survives" "1" "$( [ -d "$R/.rite/worktrees/issue-63" ] && echo 1 || echo 0 )"
assert_grep "TC-10 dirty self skipped via Gate 0 (not Gate 3)" "$R/pcc.err" "self-exclusion"
case "$out" in *"session_worktrees=0"*) pass "TC-10 status reports session_worktrees=0" ;; *) fail "TC-10 status: $out" ;; esac

echo "=== TC-11 (AC-1): RITE_WORKTREE env resolves self even when cwd is elsewhere ==="
# Gate 0 has two inputs: cwd (TC-7/9/10) and RITE_WORKTREE env. Here cleanup runs
# from the MAIN checkout (cwd would NOT match the candidate), but RITE_WORKTREE
# points at the worktree → Gate 0 still protects it (the lost-cwd robustness path).
R=$(make_repo 64); cleanup_dirs+=("$R")
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
out=$( cd "$R" && RITE_WORKTREE="$R/.rite/worktrees/issue-64" bash "$PCC" 2>"$R/pcc.err"; echo "rc=$?" )
assert "TC-11 RITE_WORKTREE-named worktree survives" "1" "$( [ -d "$R/.rite/worktrees/issue-64" ] && echo 1 || echo 0 )"
assert_grep "TC-11 self-exclusion WARNING on stderr" "$R/pcc.err" "self-exclusion"
case "$out" in *"session_worktrees=0"*) pass "TC-11 status reports session_worktrees=0" ;; *) fail "TC-11 status: $out" ;; esac

# ===========================================================================
# Issue #1524 — worktree liveness guard, signal (A): flow-state.worktree scan
# (4th protection layer) + reap-time flow-state worktree null-ing. The guard
# protects a worktree that ANOTHER live session (flow-state active=true) records
# as its `worktree`, EVEN when that session's claim has gone stale — flow-state
# liveness > claim liveness (Gate 2). (Signal (B), the #1552 claim-join, is
# covered by T-09/T-10 below for the case where flow-state.worktree drifted empty.)
# SID_C = a third (distinct) holder session used by the prefix-collision test.
# ===========================================================================
SID_C="cccccccc-9999-aaaa-bbbb-cccccccccccc"

# Helper: age a flow-state's updated_at so the holder's CLAIM goes stale while
# keeping active=true + worktree recorded — the exact incident shape (live session,
# expired claim heartbeat). Without aging, the claim stays "other" (live) and Gate 2
# alone would protect the worktree, making the new guard's contribution vacuous.
# "3 hours ago" is deliberate (Issue #1923): it must clear the 2h claim-staleness
# window (so Gate 2 alone would reap — non-vacuous) while staying WELL within the
# liveness TTL default of 24h (so the guard this helper exercises still protects).
age_flow_state() {
  local sf="$1" tmp ts
  tmp=$(mktemp) || return 1
  ts=$(date -u -d '3 hours ago' +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-3H +"%Y-%m-%dT%H:%M:%SZ")
  jq --arg ts "$ts" '.updated_at = $ts' "$sf" > "$tmp" && mv "$tmp" "$sf"
}

echo "=== T-01 (AC-1): live-session flow-state worktree ref → NOT reaped even when claim stale ==="
R=$(make_repo 70); cleanup_dirs+=("$R")
# Record the worktree in SID_A's flow-state (the live-session reference), then age
# updated_at so the claim is "stale" (Gate 2 would reap) while active=true (guard protects).
RITE_STATE_ROOT="$R" bash "$FS" set --session "$SID_A" --phase implement --issue 70 \
  --branch "feat/issue-70" --next n --worktree "$R/.rite/worktrees/issue-70" >/dev/null 2>&1
age_flow_state "$R/.rite/sessions/${SID_A}.flow-state"
claim_now=$(RITE_STATE_ROOT="$R" bash "$IC" check --issue 70 --session "$SID_B" 2>/dev/null)
out=$(run_pcc "$R")
assert "T-01 claim is stale (guard non-vacuous: Gate 2 alone would reap)" "stale" "$claim_now"
assert "T-01 live-referenced worktree survives (worktree liveness)" "1" "$( [ -d "$R/.rite/worktrees/issue-70" ] && echo 1 || echo 0 )"
assert_grep "T-01 worktree-liveness WARNING on stderr" "$R/pcc.err" "worktree liveness"
case "$out" in *"session_worktrees=0"*) pass "T-01 status reports session_worktrees=0" ;; *) fail "T-01 status: $out" ;; esac

echo "=== T-03 (AC-3): inactive flow-state worktree ref does NOT over-protect → reaped + owner ref nulled ==="
R=$(make_repo 71); cleanup_dirs+=("$R")
# SID_A records the worktree but is then deactivated (active=false) → NOT a live ref.
RITE_STATE_ROOT="$R" bash "$FS" set --session "$SID_A" --phase implement --issue 71 \
  --branch "feat/issue-71" --next n --worktree "$R/.rite/worktrees/issue-71" >/dev/null 2>&1
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
out=$(run_pcc "$R")
assert "T-03 orphan worktree reaped (inactive ref not over-protected)" "0" "$( [ -d "$R/.rite/worktrees/issue-71" ] && echo 1 || echo 0 )"
assert "T-03 claim file deleted" "0" "$( [ -f "$R/.rite/state/issue-claims/issue-71.json" ] && echo 1 || echo 0 )"
assert "T-03 owner flow-state worktree nulled after reap" "false" "$(jq -r 'has("worktree")' "$R/.rite/sessions/${SID_A}.flow-state" 2>/dev/null)"
case "$out" in *"session_worktrees=1"*) pass "T-03 status reports session_worktrees=1" ;; *) fail "T-03 status: $out" ;; esac

echo "=== T-04 (AC-4): flow-state parse failure → conservative skip + WARNING ==="
R=$(make_repo 72); cleanup_dirs+=("$R")
# Stale the claim so the worktree WOULD be reaped (non-vacuous), then drop a corrupt
# flow-state so the guard's jq parse fails → conservative skip. Corrupt-file (vs
# chmod) keeps the test uid-independent (root would bypass an unreadable dir).
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
printf '{ this is not valid json' > "$R/.rite/sessions/corrupt-sess.flow-state"
out=$(run_pcc "$R")
assert "T-04 worktree survives (conservative skip on parse failure)" "1" "$( [ -d "$R/.rite/worktrees/issue-72" ] && echo 1 || echo 0 )"
assert_grep "T-04 conservative-skip WARNING on stderr" "$R/pcc.err" "保護判定に必要な flow-state"
case "$out" in *"session_worktrees=0"*) pass "T-04 status reports session_worktrees=0" ;; *) fail "T-04 status: $out" ;; esac

echo "=== T-06 (AC-6): new guard + strict regex — issue-1 (live-ref) protected, issue-12 (orphan) reaped, no prefix bleed ==="
R=$(make_repo 1); cleanup_dirs+=("$R")
# issue-1: live flow-state ref (active + worktree) with a stale claim → guard protects.
RITE_STATE_ROOT="$R" bash "$FS" set --session "$SID_A" --phase implement --issue 1 \
  --branch "feat/issue-1" --next n --worktree "$R/.rite/worktrees/issue-1" >/dev/null 2>&1
age_flow_state "$R/.rite/sessions/${SID_A}.flow-state"
# issue-12: a sibling orphan held by a DIFFERENT inactive session → reapable. Proves the
# guard's path matching + Gate 1 strict regex do not let issue-1 protect issue-12.
( cd "$R" && $GIT worktree add -q -b "feat/issue-12" ".rite/worktrees/issue-12" >/dev/null 2>&1 )
RITE_STATE_ROOT="$R" bash "$IC" claim --issue 12 --session "$SID_C" --worktree "$R/.rite/worktrees/issue-12" >/dev/null 2>&1
RITE_STATE_ROOT="$R" bash "$FS" set --session "$SID_C" --phase implement --issue 12 --branch "feat/issue-12" --next n >/dev/null 2>&1
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_C" --next done >/dev/null 2>&1
out=$(run_pcc "$R")
assert "T-06 issue-1 (live-ref) survives" "1" "$( [ -d "$R/.rite/worktrees/issue-1" ] && echo 1 || echo 0 )"
assert "T-06 issue-12 (orphan) reaped (no prefix bleed from issue-1)" "0" "$( [ -d "$R/.rite/worktrees/issue-12" ] && echo 1 || echo 0 )"
case "$out" in *"session_worktrees=1"*) pass "T-06 status reports session_worktrees=1 (only issue-12)" ;; *) fail "T-06 status: $out" ;; esac

# ===========================================================================
# Issue #1544 — OS-level live-cwd guard (regression of #1524). The cross-session
# liveness guard only protects worktrees a session records as its `active`
# `worktree`; it misses the dangling cases where the owning session's harness cwd
# is still IN the tree but its flow-state has drifted (active=false, no `worktree`
# field, stale session-id). The live-cwd guard (worktree-live-cwd.sh) closes that
# gap by reading the OS's own per-process cwd, independent of flow-state.
# ===========================================================================
echo "=== T-07 (Issue #1544): a live process standing in a clean+stale worktree → NOT reaped (live-cwd guard) ==="
# The OS-level live-cwd guard resolves to /proc on Linux but lsof on macOS, and
# the lsof path has an exit-code false-negative (#2011) that reaps a live tree.
# Guard behind /proc so the macOS leg skips this rather than failing on the known
# lsof bug (Issue #2008 Family B). T-08 (no live cwd → reaped) stays platform-agnostic.
if [ -d /proc ]; then
R=$(make_repo 80); cleanup_dirs+=("$R")
# Fully drift flow-state so neither flow-state-based guard protects issue-80:
# `deactivate` sets SID_A's flow-state active=false, so the worktree liveness
# guard short-circuits at its `active=true` requirement (_rite_worktree_protected_by_flow_state:
# both the flow-state scan and the #1552 claim-join protect only active=true holders)
# — the `worktree` field value is irrelevant once active=false — and the deactivated
# claim resolves to `stale`, which the claim gate treats as reapable. Only the
# OS-level live-cwd guard can save it (non-vacuous: drop the guard and T-07 flips).
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
# A live process stands in the worktree — the exact "harness cwd still in the
# tree" shape that makes /clear fail when the tree is reaped out from under it.
( cd "$R/.rite/worktrees/issue-80" && sleep 30 ) & _h80=$!
holder_pids+=("$_h80")
sleep 0.3
out=$(run_pcc "$R")
assert "T-07 worktree with live cwd survives (live-cwd guard)" "1" "$( [ -d "$R/.rite/worktrees/issue-80" ] && echo 1 || echo 0 )"
assert "T-07 claim file survives (not reaped)" "1" "$( [ -f "$R/.rite/state/issue-claims/issue-80.json" ] && echo 1 || echo 0 )"
assert_grep "T-07 live-cwd guard WARNING on stderr" "$R/pcc.err" "live-cwd guard"
case "$out" in *"session_worktrees=0"*) pass "T-07 status reports session_worktrees=0" ;; *) fail "T-07 status: $out" ;; esac
kill "$_h80" 2>/dev/null || true; wait "$_h80" 2>/dev/null || true
else
  skip "T-07 skipped (no /proc: OS-level live-cwd guard uses lsof; exit-code false-negative reaps live tree, tracked in #2011)"
fi

echo "=== T-08 (Issue #1544 non-regression): same clean+stale worktree with NO live cwd → reaped ==="
R=$(make_repo 81); cleanup_dirs+=("$R")
# Identical drift to T-07 but with nobody standing in the tree → the live-cwd
# guard must NOT over-protect: a genuine orphan is still reaped.
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
out=$(run_pcc "$R")
assert "T-08 free clean+stale worktree reaped (no over-protection)" "0" "$( [ -d "$R/.rite/worktrees/issue-81" ] && echo 1 || echo 0 )"
assert "T-08 claim file deleted" "0" "$( [ -f "$R/.rite/state/issue-claims/issue-81.json" ] && echo 1 || echo 0 )"
case "$out" in *"session_worktrees=1"*) pass "T-08 status reports session_worktrees=1" ;; *) fail "T-08 status: $out" ;; esac

# ===========================================================================
# Issue #1552 — claim-join (regression of #1524/#1544). The claim's liveness is
# `active=true` AND flow-state.updated_at within 2h; an active-but-idle (>2h)
# session has a `stale` claim that Gate 2 alone would reap — destroying a tree the
# harness can still resume into, so `/clear` fails with `Path does not exist`. The
# claim-join protects when the issue's claim records this tree AND its holder is
# still active=true, regardless of the 2h heartbeat staleness.
# ===========================================================================
echo "=== T-09 (Issue #1552): active=true holder with a STALE claim (idle >2h) → NOT reaped (claim-join) ==="
R=$(make_repo 82); cleanup_dirs+=("$R")
# Holder stays active=true (resumable), but its claim heartbeat ages out: claim
# liveness = active=true AND flow-state.updated_at within 2h. Backdate updated_at
# so issue-claim.sh classifies the claim as `stale` → Gate 2 alone would reap it.
# make_repo does NOT set flow-state.worktree, so the (A) flow-state scan cannot
# match; only the (B) claim-join (claim.worktree==tree AND holder active=true) can
# save it. Non-vacuous: revert the claim-join and issue-82 reaps (stale, no live cwd).
# "3 hours ago" (not a fixed old date): must clear the 2h claim-staleness window
# but stay within the liveness TTL default of 24h (Issue #1923) so claim-join
# still protects — see age_flow_state()'s comment above for the same rationale.
hf82="$R/.rite/sessions/$SID_A.flow-state"
ts82=$(date -u -d '3 hours ago' +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-3H +"%Y-%m-%dT%H:%M:%SZ")
tmp82=$(mktemp); jq --arg ts "$ts82" '.updated_at=$ts' "$hf82" > "$tmp82" && mv "$tmp82" "$hf82"
out=$(run_pcc "$R")
assert "T-09 active+idle(stale-claim) worktree survives (claim-join)" "1" "$( [ -d "$R/.rite/worktrees/issue-82" ] && echo 1 || echo 0 )"
assert "T-09 claim file survives (not reaped)" "1" "$( [ -f "$R/.rite/state/issue-claims/issue-82.json" ] && echo 1 || echo 0 )"
assert_grep "T-09 worktree-liveness WARNING on stderr" "$R/pcc.err" "worktree liveness"
case "$out" in *"session_worktrees=0"*) pass "T-09 status reports session_worktrees=0" ;; *) fail "T-09 status: $out" ;; esac

echo "=== T-10 (Issue #1552 surgical): active+stale holder whose claim records a DIFFERENT worktree → candidate still reaped ==="
R=$(make_repo 83); cleanup_dirs+=("$R")
# Same active+idle(stale) holder as T-09, but rewrite the claim's `worktree` to a
# path that does NOT match issue-83's tree. The claim-join MUST require a real
# worktree match — a blanket "holder active → protect" would wrongly save issue-83
# (and, by the same exact-match logic, an `issue-1` claim never protects `issue-12`).
hf83="$R/.rite/sessions/$SID_A.flow-state"
tmp83=$(mktemp); jq --arg ts "2000-01-01T00:00:00Z" '.updated_at=$ts' "$hf83" > "$tmp83" && mv "$tmp83" "$hf83"
cf83="$R/.rite/state/issue-claims/issue-83.json"
tmpc=$(mktemp); jq --arg wt "$R/.rite/worktrees/issue-999-bogus" '.worktree=$wt' "$cf83" > "$tmpc" && mv "$tmpc" "$cf83"
out=$(run_pcc "$R")
assert "T-10 mismatched-claim worktree IS reaped (no blanket protection)" "0" "$( [ -d "$R/.rite/worktrees/issue-83" ] && echo 1 || echo 0 )"
case "$out" in *"session_worktrees=1"*) pass "T-10 status reports session_worktrees=1" ;; *) fail "T-10 status: $out" ;; esac

# ===========================================================================
# Issue #1670 — session-feature-branch recovery after reap (dead-letter fix).
# The lazy reap used to delete the worktree but NEVER the branch, so a feature
# branch whose cleanup deferred its worktree (live-cwd guard) leaked forever.
# Step 5 now recovers the branch after reaping its worktree: SAFE-delete first
# (preserves unmerged work — AC-4); FORCE-delete only when the branch is recorded
# in the reap manifest (cleanup.md confirmed its PR merged — the squash-merge case
# `git branch -d` cannot detect). TC-4 above already covers the merged-into-base
# branch recovered by the safe delete + session_branches=1 status.
# ===========================================================================
GITC() { $GIT -C "$1" "${@:2}"; }   # run git in worktree $1

echo "=== B-01 (#1670 AC-4): UNMERGED branch (not manifest-recorded) is PRESERVED after reap ==="
R=$(make_repo 90); cleanup_dirs+=("$R")
# Give feat/issue-90 a commit that is NOT in develop → `git branch -d` refuses it.
# The commit is COMMITTED (worktree stays clean → Gate 3 passes → worktree reaped),
# but the branch is NOT in the manifest → must be preserved (no data loss).
echo "wip" > "$R/.rite/worktrees/issue-90/wip.txt"
GITC "$R/.rite/worktrees/issue-90" add wip.txt >/dev/null 2>&1
GITC "$R/.rite/worktrees/issue-90" commit -q -m "wip: unmerged work" >/dev/null 2>&1
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
out=$(run_pcc "$R")
assert "B-01 unmerged worktree reaped (clean → Gate 3 passes)" "0" "$( [ -d "$R/.rite/worktrees/issue-90" ] && echo 1 || echo 0 )"
assert "B-01 unmerged branch PRESERVED (not destroyed)" "1" "$( cd "$R" && $GIT rev-parse --verify feat/issue-90 >/dev/null 2>&1 && echo 1 || echo 0 )"
assert_grep "B-01 unmerged-branch WARNING on stderr" "$R/pcc.err" "未マージのため保持"
case "$out" in *"session_branches=0"*) pass "B-01 status reports session_branches=0" ;; *) fail "B-01 status: $out" ;; esac

echo "=== B-02 (#1670 AC-3): squash-merged branch RECORDED in manifest → force-recovered after reap ==="
R=$(make_repo 91); cleanup_dirs+=("$R")
# Same unmerged shape as B-01 (a commit not in develop, so `git branch -d` refuses —
# the squash-merge signature), but cleanup.md confirmed the PR merged and recorded
# the branch in the reap manifest. Step 5 must FORCE-delete it (single-session
# recovery of the deferred dead-letter branch).
echo "squashed" > "$R/.rite/worktrees/issue-91/done.txt"
GITC "$R/.rite/worktrees/issue-91" add done.txt >/dev/null 2>&1
GITC "$R/.rite/worktrees/issue-91" commit -q -m "feat: squash-merged work" >/dev/null 2>&1
printf 'branch\tfeat/issue-91\n' > "$R/.rite/tmp-artifacts.tsv"   # cleanup.md's merge-confirmed record
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
out=$(run_pcc "$R")
assert "B-02 worktree reaped" "0" "$( [ -d "$R/.rite/worktrees/issue-91" ] && echo 1 || echo 0 )"
assert "B-02 manifest-recorded merged branch FORCE-recovered (gone)" "0" "$( cd "$R" && $GIT rev-parse --verify feat/issue-91 >/dev/null 2>&1 && echo 1 || echo 0 )"
case "$out" in *"session_branches=1"*) pass "B-02 status reports session_branches=1" ;; *) fail "B-02 status: $out" ;; esac
# Clean-recovery contract: the deferred-branch manifest entry is still checked out in
# its worktree when Step 4.5 runs (before Step 5 reaps it). That expected case must
# NOT flip the run to status=failed nor emit a "failed to reap manifest branch" WARNING
# — the recovery is clean (status=cleaned, errors absent). Without this the false
# "status=failed; errors=1" of the marquee dead-letter path slips through silently.
case "$out" in *"status=cleaned"*) pass "B-02 reports status=cleaned (no false failure)" ;; *) fail "B-02 status not cleaned: $out" ;; esac
assert_not_grep "B-02 no misleading 'failed to reap manifest branch' WARNING" "$R/pcc.err" "failed to reap manifest branch"

echo "=== B-03 (#1670 surgical): a manifest entry NEVER force-deletes an unrecorded unmerged sibling ==="
R=$(make_repo 92); cleanup_dirs+=("$R")
# issue-92 has an unmerged commit and IS recorded → force-recovered. A second
# orphan issue-93 has an unmerged commit but is NOT recorded → preserved. Proves
# the manifest gate is exact (a recorded branch never licenses deleting another).
echo "a" > "$R/.rite/worktrees/issue-92/a.txt"
GITC "$R/.rite/worktrees/issue-92" add a.txt >/dev/null 2>&1
GITC "$R/.rite/worktrees/issue-92" commit -q -m "feat: 92" >/dev/null 2>&1
( cd "$R" && $GIT worktree add -q -b "feat/issue-93" ".rite/worktrees/issue-93" >/dev/null 2>&1 )
RITE_STATE_ROOT="$R" bash "$IC" claim --issue 93 --session "$SID_A" --worktree "$R/.rite/worktrees/issue-93" >/dev/null 2>&1
echo "b" > "$R/.rite/worktrees/issue-93/b.txt"
GITC "$R/.rite/worktrees/issue-93" add b.txt >/dev/null 2>&1
GITC "$R/.rite/worktrees/issue-93" commit -q -m "wip: 93" >/dev/null 2>&1
printf 'branch\tfeat/issue-92\n' > "$R/.rite/tmp-artifacts.tsv"   # only issue-92 recorded
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
out=$(run_pcc "$R")
assert "B-03 recorded branch feat/issue-92 force-recovered (gone)" "0" "$( cd "$R" && $GIT rev-parse --verify feat/issue-92 >/dev/null 2>&1 && echo 1 || echo 0 )"
assert "B-03 unrecorded sibling feat/issue-93 PRESERVED" "1" "$( cd "$R" && $GIT rev-parse --verify feat/issue-93 >/dev/null 2>&1 && echo 1 || echo 0 )"
# issue-93's worktree MUST be reaped for the "preserved" assertion to be meaningful:
# the surgical guarantee (a recorded entry never licenses deleting an unrecorded
# sibling) only has teeth when issue-93's branch-recovery path actually ran. Pin it so
# a future regression where issue-93 is never reaped cannot make "preserved" pass for
# the wrong reason.
assert "B-03 issue-93 worktree reaped (recovery path ran)" "0" "$( [ -d "$R/.rite/worktrees/issue-93" ] && echo 1 || echo 0 )"
case "$out" in *"status=cleaned"*) pass "B-03 reports status=cleaned (no false failure)" ;; *) fail "B-03 status not cleaned: $out" ;; esac
assert_not_grep "B-03 no misleading 'failed to reap manifest branch' WARNING" "$R/pcc.err" "failed to reap manifest branch"

# ===========================================================================
# Issue #1966 — Gate 2 free-arm manifest bypass. cleanup.md defers the worktree
# removal (self-cwd / live-cwd / sandbox mask), records the merge-confirmed
# branch in the reap manifest (recovery=auto), and releases the claim
# unconditionally — so the real-world deferred worktree arrives at Gate 2
# claim-FREE with a FRESH mtime (the harness touches the worktree root every
# session, so the 24h age guard never expires). A manifest-recorded branch is
# an explicit rite-origin "reap me" intent → the age guard is bypassed; the
# unrecorded shapes keep the guard.
# ===========================================================================

echo "=== D-01 (#1966): claim-free FRESH worktree, manifest-recorded branch → reaped (age-guard bypass) ==="
R=$(make_repo 110); cleanup_dirs+=("$R")
# The real-world leak shape (5 merged-PR worktrees observed on 2026-07-22):
# squash-merge residue commit (`-d` refuses → manifest `-D` path runs
# end-to-end), claim released by cleanup (free), mtime fresh (just created — no
# age_dir). Old implementation: silent continue at the free-arm age guard →
# permanent leak. Non-vacuous: drop the bypass and D-01 flips.
echo "squashed" > "$R/.rite/worktrees/issue-110/done.txt"
GITC "$R/.rite/worktrees/issue-110" add done.txt >/dev/null 2>&1
GITC "$R/.rite/worktrees/issue-110" commit -q -m "feat: squash-merged work" >/dev/null 2>&1
printf 'branch\tfeat/issue-110\n' > "$R/.rite/tmp-artifacts.tsv"   # cleanup.md's merge-confirmed record
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
rm -f "$R/.rite/state/issue-claims/issue-110.json"                 # cleanup released the claim
out=$(run_pcc "$R")
assert "D-01 fresh manifest-recorded worktree reaped" "0" "$( [ -d "$R/.rite/worktrees/issue-110" ] && echo 1 || echo 0 )"
assert "D-01 branch force-recovered (gone)" "0" "$( cd "$R" && $GIT rev-parse --verify feat/issue-110 >/dev/null 2>&1 && echo 1 || echo 0 )"
assert_grep "D-01 bypass is LOGGED (not silent)" "$R/pcc.err" "age guard をバイパスします"
# Hardening: the manifest entry is consumed in the SAME run. A lingering entry
# is no longer inert with the bypass keyed
# on it — a same-named branch recreated in a new claim-free worktree would
# inherit the bypass. Single-entry manifest → the whole file is removed.
assert "D-01 manifest entry consumed (file removed)" "0" "$( [ -f "$R/.rite/tmp-artifacts.tsv" ] && echo 1 || echo 0 )"
case "$out" in *"session_worktrees=1"*) pass "D-01 status reports session_worktrees=1" ;; *) fail "D-01 status: $out" ;; esac
case "$out" in *"session_branches=1"*)  pass "D-01 status reports session_branches=1"  ;; *) fail "D-01 status: $out" ;; esac
case "$out" in *"status=cleaned"*)      pass "D-01 reports status=cleaned (no false failure)" ;; *) fail "D-01 status: $out" ;; esac
assert_not_grep "D-01 no misleading 'failed to reap manifest branch' WARNING" "$R/pcc.err" "failed to reap manifest branch"

echo "=== D-02 (#1966 control): claim-free FRESH worktree, NOT recorded → survives (age guard intact) ==="
R=$(make_repo 111); cleanup_dirs+=("$R")
# Same claim-free + fresh shape but no manifest entry → the in-flight
# protection the age guard exists for must still hold.
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
rm -f "$R/.rite/state/issue-claims/issue-111.json"
out=$(run_pcc "$R")
assert "D-02 unrecorded fresh worktree survives" "1" "$( [ -d "$R/.rite/worktrees/issue-111" ] && echo 1 || echo 0 )"
case "$out" in *"session_worktrees=0"*) pass "D-02 status reports session_worktrees=0" ;; *) fail "D-02 status: $out" ;; esac

echo "=== D-03 (#1966 surgical): manifest records a DIFFERENT branch → fresh worktree survives ==="
R=$(make_repo 112); cleanup_dirs+=("$R")
# The bypass requires an EXACT match between the worktree's checked-out branch
# and a manifest entry. The mismatch entry MUST survive Step 4.5 to reach the
# Step 5 bypass grep at all: an entry naming a nonexistent branch is dropped by
# Step 4.5's verify-already-gone (manifest deleted → identical code path to
# D-02, vacuous). So the entry names a REAL branch checked out in a second,
# claim-LIVE worktree (B-03's preservation structure): Step 4.5's `-D` fails
# "used by worktree" and preserves the entry, and Step 5 evaluates issue-112's
# bypass against a present-but-mismatched entry. SID_A stays active to protect
# issue-113; only the candidate's claim is released.
( cd "$R" && $GIT worktree add -q -b "feat/issue-113" ".rite/worktrees/issue-113" >/dev/null 2>&1 )
RITE_STATE_ROOT="$R" bash "$IC" claim --issue 113 --session "$SID_A" --worktree "$R/.rite/worktrees/issue-113" >/dev/null 2>&1
printf 'branch\tfeat/issue-113\n' > "$R/.rite/tmp-artifacts.tsv"
rm -f "$R/.rite/state/issue-claims/issue-112.json"   # candidate is claim-free + fresh
out=$(run_pcc "$R")
assert "D-03 mismatched-entry fresh worktree survives" "1" "$( [ -d "$R/.rite/worktrees/issue-112" ] && echo 1 || echo 0 )"
assert "D-03 mismatch entry survived Step 4.5 (non-vacuous: bypass grep saw it)" "1" "$( grep -qxF "branch$(printf '\t')feat/issue-113" "$R/.rite/tmp-artifacts.tsv" 2>/dev/null && echo 1 || echo 0 )"
assert "D-03 live second worktree untouched" "1" "$( [ -d "$R/.rite/worktrees/issue-113" ] && echo 1 || echo 0 )"
case "$out" in *"session_worktrees=0"*) pass "D-03 status reports session_worktrees=0" ;; *) fail "D-03 status: $out" ;; esac

echo "=== D-04 (#1966 write-side surgical): multi-entry manifest → only the reaped entry is consumed ==="
R=$(make_repo 120); cleanup_dirs+=("$R")
# Two recorded branches: issue-120 (reap target — squash residue, claim-free,
# fresh) and issue-121 (claim-LIVE second worktree — Step 4.5 preserves its
# entry via "used by worktree", Step 5 skips its worktree via claim liveness).
# After the run the manifest must still exist with ONLY the issue-121 entry:
# this exercises the consumption's survivors-preserving `cp` branch (multi-entry
# manifest) that D-01's single-entry `rm -f` branch cannot reach, and pins the
# write-side surgical `grep -vxF` (an unrelated co-pending entry is never lost).
echo "squashed" > "$R/.rite/worktrees/issue-120/done.txt"
GITC "$R/.rite/worktrees/issue-120" add done.txt >/dev/null 2>&1
GITC "$R/.rite/worktrees/issue-120" commit -q -m "feat: squash-merged work" >/dev/null 2>&1
( cd "$R" && $GIT worktree add -q -b "feat/issue-121" ".rite/worktrees/issue-121" >/dev/null 2>&1 )
RITE_STATE_ROOT="$R" bash "$IC" claim --issue 121 --session "$SID_A" --worktree "$R/.rite/worktrees/issue-121" >/dev/null 2>&1
printf 'branch\tfeat/issue-120\nbranch\tfeat/issue-121\n' > "$R/.rite/tmp-artifacts.tsv"
rm -f "$R/.rite/state/issue-claims/issue-120.json"   # target claim-free; SID_A stays active for issue-121
out=$(run_pcc "$R")
assert "D-04 target worktree reaped (bypass)" "0" "$( [ -d "$R/.rite/worktrees/issue-120" ] && echo 1 || echo 0 )"
assert "D-04 target branch force-recovered (gone)" "0" "$( cd "$R" && $GIT rev-parse --verify feat/issue-120 >/dev/null 2>&1 && echo 1 || echo 0 )"
assert "D-04 reaped entry consumed from manifest" "0" "$( grep -qxF "branch$(printf '\t')feat/issue-120" "$R/.rite/tmp-artifacts.tsv" 2>/dev/null && echo 1 || echo 0 )"
assert "D-04 co-pending entry preserved (cp survivors branch)" "1" "$( grep -qxF "branch$(printf '\t')feat/issue-121" "$R/.rite/tmp-artifacts.tsv" 2>/dev/null && echo 1 || echo 0 )"
assert "D-04 live second worktree survives" "1" "$( [ -d "$R/.rite/worktrees/issue-121" ] && echo 1 || echo 0 )"
case "$out" in *"session_worktrees=1"*) pass "D-04 status reports session_worktrees=1" ;; *) fail "D-04 status: $out" ;; esac
case "$out" in *"status=cleaned"*) pass "D-04 reports status=cleaned (no false failure)" ;; *) fail "D-04 status: $out" ;; esac

echo "=== D-05 (#1966 symmetry): manifest-recorded branch recovered via safe -d → entry consumed too ==="
R=$(make_repo 130); cleanup_dirs+=("$R")
# No residue commit → the branch is merged-even with develop and `git branch -d`
# succeeds. Consumption must fire on the -d arm too (symmetrization): a
# lingering entry after a -d recovery would keep licensing the bypass for a
# same-named recreated branch, exactly like the -D arm.
printf 'branch\tfeat/issue-130\n' > "$R/.rite/tmp-artifacts.tsv"
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
rm -f "$R/.rite/state/issue-claims/issue-130.json"
out=$(run_pcc "$R")
assert "D-05 fresh manifest-recorded worktree reaped (bypass)" "0" "$( [ -d "$R/.rite/worktrees/issue-130" ] && echo 1 || echo 0 )"
assert "D-05 branch safe-recovered via -d (gone)" "0" "$( cd "$R" && $GIT rev-parse --verify feat/issue-130 >/dev/null 2>&1 && echo 1 || echo 0 )"
assert "D-05 manifest entry consumed on -d arm (file removed)" "0" "$( [ -f "$R/.rite/tmp-artifacts.tsv" ] && echo 1 || echo 0 )"
case "$out" in *"session_branches=1"*) pass "D-05 status reports session_branches=1" ;; *) fail "D-05 status: $out" ;; esac

# ===========================================================================
# Issue #1957 — corpse reap. A sandbox-masked `git worktree remove --force`
# half-destroys the admin dir (HEAD alone unlinked; commondir/gitdir/index and
# the working tree survive). Such a corpse fails EVERY `git -C <wt>` operation,
# so Gate 3's conservative skip would protect it forever, and manual
# `git worktree remove --force` is rejected by validation (no recovery path).
# Step 5 now detects corpses (admin HEAD missing AND git does not recognize the
# tree) and reaps them via rm -rf (working tree + admin dir) once the claim is
# not live AND the tree aged past 24h (D-01: a corpse's dirty state is
# structurally unexaminable; claim + age guards bound the accepted risk).
# ===========================================================================

# Corpse fixture: unlink the admin HEAD — the exact signature of the 13
# real-world corpses observed on 2026-07-20〜21.
make_corpse() { rm "$1/.git/worktrees/issue-$2/HEAD"; }
# Age a dir's mtime past the 24h reap guard (GNU touch first, BSD fallback).
age_dir() { touch -d '25 hours ago' "$1" 2>/dev/null || touch -t "$(date -v-25H +%Y%m%d%H%M)" "$1"; }

echo "=== C-01 (#1957 AC-3): aged corpse + stale claim → reaped (working tree + admin dir) ==="
R=$(make_repo 100); cleanup_dirs+=("$R")
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
make_corpse "$R" 100
age_dir "$R/.rite/worktrees/issue-100"
out=$(run_pcc "$R")
assert "C-01 corpse working tree reaped" "0" "$( [ -d "$R/.rite/worktrees/issue-100" ] && echo 1 || echo 0 )"
assert "C-01 corpse admin dir reaped" "0" "$( [ -d "$R/.git/worktrees/issue-100" ] && echo 1 || echo 0 )"
assert "C-01 claim file deleted" "0" "$( [ -f "$R/.rite/state/issue-claims/issue-100.json" ] && echo 1 || echo 0 )"
assert_grep "C-01 corpse reap WARNING names the target" "$R/pcc.err" "corpse session worktree.*issue-100.*回収します"
case "$out" in *"session_worktrees=1"*) pass "C-01 status reports session_worktrees=1" ;; *) fail "C-01 status: $out" ;; esac

echo "=== C-02 (#1957 AC-4): fresh corpse (age ≤ 24h) + stale claim → NOT reaped + WARNING ==="
R=$(make_repo 101); cleanup_dirs+=("$R")
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
make_corpse "$R" 101
out=$(run_pcc "$R")
assert "C-02 fresh corpse survives (age guard)" "1" "$( [ -d "$R/.rite/worktrees/issue-101" ] && echo 1 || echo 0 )"
assert "C-02 admin dir survives" "1" "$( [ -d "$R/.git/worktrees/issue-101" ] && echo 1 || echo 0 )"
assert_grep "C-02 age-guard skip WARNING on stderr (not silent)" "$R/pcc.err" "age guard \(24h\) 未達のため回収を見送ります"
case "$out" in *"session_worktrees=0"*) pass "C-02 status reports session_worktrees=0" ;; *) fail "C-02 status: $out" ;; esac

echo "=== C-02b (#1957 MUST silent-skip 禁止): free-claim fresh corpse → NOT reaped + WARNING (not silent) ==="
R=$(make_repo 105); cleanup_dirs+=("$R")
# The real-world corpse shape: cleanup releases the claim unconditionally, so the
# corpse is claim-FREE (not stale). Deactivate the holder (liveness guard off) and
# delete the claim file (release). Without the corpse exclusion in Gate 2's free
# age guard, this skips through the pre-existing silent continue — stderr empty —
# violating the Issue #1957 MUST (skips must be logged). Non-vacuous: revert the
# `_corpse -eq 0` condition and the WARNING assert flips.
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
rm -f "$R/.rite/state/issue-claims/issue-105.json"
make_corpse "$R" 105
out=$(run_pcc "$R")
assert "C-02b free fresh corpse survives (age guard)" "1" "$( [ -d "$R/.rite/worktrees/issue-105" ] && echo 1 || echo 0 )"
assert_grep "C-02b free fresh corpse skip is LOGGED (corpse age guard WARNING)" "$R/pcc.err" "age guard \(24h\) 未達のため回収を見送ります"
case "$out" in *"session_worktrees=0"*) pass "C-02b status reports session_worktrees=0" ;; *) fail "C-02b status: $out" ;; esac

echo "=== C-03 (#1957 AC-4): aged corpse but LIVE claim → NOT reaped ==="
R=$(make_repo 102); cleanup_dirs+=("$R")
# SID_A stays active → the claim is live ("other" from SID_B). Aged + corpse,
# so only the claim-side protections stand between the corpse and the reap
# (non-vacuous for AC-4's claim-live half; whichever liveness guard fires, the
# contract is survival).
make_corpse "$R" 102
age_dir "$R/.rite/worktrees/issue-102"
out=$(run_pcc "$R")
assert "C-03 claim-live corpse survives" "1" "$( [ -d "$R/.rite/worktrees/issue-102" ] && echo 1 || echo 0 )"
assert "C-03 admin dir survives" "1" "$( [ -d "$R/.git/worktrees/issue-102" ] && echo 1 || echo 0 )"
case "$out" in *"session_worktrees=0"*) pass "C-03 status reports session_worktrees=0" ;; *) fail "C-03 status: $out" ;; esac

echo "=== C-03b (#1957 MUST): aged corpse + live worktree-less claim → NOT reaped + Gate 2 skip LOGGED ==="
R=$(make_repo 106); cleanup_dirs+=("$R")
# The open-claims-first window shape: the claim holder is live but the claim has
# no worktree recorded yet (open Step 1.6 claims before the worktree exists), so
# the claim-join liveness guard cannot match the tree and the corpse reaches
# Gate 2's live-claim arm. That skip must be loud (Issue #1957 MUST) — the
# protection is correct, the anomaly must still be visible.
tmpc106=$(mktemp)
jq 'del(.worktree)' "$R/.rite/state/issue-claims/issue-106.json" > "$tmpc106" && mv "$tmpc106" "$R/.rite/state/issue-claims/issue-106.json"
make_corpse "$R" 106
age_dir "$R/.rite/worktrees/issue-106"
out=$(run_pcc "$R")
assert "C-03b live worktree-less claim corpse survives" "1" "$( [ -d "$R/.rite/worktrees/issue-106" ] && echo 1 || echo 0 )"
assert_grep "C-03b Gate 2 live-claim corpse skip is LOGGED (not silent)" "$R/pcc.err" "live claim \(other\) 保持中のため回収を見送ります"
case "$out" in *"session_worktrees=0"*) pass "C-03b status reports session_worktrees=0" ;; *) fail "C-03b status: $out" ;; esac

echo "=== C-04 (#1957 AC-5): HEAD present + status rc≠0 (NOT a corpse) → conservative skip unchanged ==="
R=$(make_repo 103); cleanup_dirs+=("$R")
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
# Break commondir so git stops recognizing the tree while HEAD survives — the
# corpse condition is an AND (HEAD missing AND unrecognized), so this must stay
# on Gate 3's conservative-skip path. Aged + stale, so ONLY the AND-condition
# keeps it protected (drop either half of the AND and this reaps).
rm "$R/.git/worktrees/issue-103/commondir"
age_dir "$R/.rite/worktrees/issue-103"
out=$(run_pcc "$R")
assert "C-04 non-corpse broken worktree survives (conservative skip)" "1" "$( [ -d "$R/.rite/worktrees/issue-103" ] && echo 1 || echo 0 )"
assert_grep "C-04 Gate 3 conservative-skip WARNING (not the corpse path)" "$R/pcc.err" "status を判定できません"
assert_not_grep "C-04 no corpse WARNING emitted" "$R/pcc.err" "corpse session worktree"
case "$out" in *"session_worktrees=0"*) pass "C-04 status reports session_worktrees=0" ;; *) fail "C-04 status: $out" ;; esac

# ===========================================================================
# Issue #1945 — corpse age-guard manifest bypass, keyed on PATH not branch. A
# corpse cannot resolve its checked-out branch (git no longer recognizes the
# tree), so the #1966 branch-keyed bypass above structurally never matches
# one — every corpse would wait the full 24h even when cleanup.md Step 4-W
# already recorded the failed removal. cleanup.md now records the worktree's
# own PATH into the manifest (under the distinct `session_worktree` type —
# NOT the ephemeral-artifact `worktree` type Step 4.5 reaps ungated) when
# removal fails/is skipped for a busy/sandbox-mask reason (only when the PR
# was merged — AC-4 parity with the branch bypass). Step 5's corpse age
# guard checks for that PATH entry before falling back to the 24h wait.
# ===========================================================================

echo "=== C-05 (#1945): fresh corpse + manifest-recorded PATH → reaped (age-guard bypass, no branch needed) ==="
R=$(make_repo 140); cleanup_dirs+=("$R")
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
rm -f "$R/.rite/state/issue-claims/issue-140.json"   # cleanup releases the claim unconditionally
printf 'session_worktree\t%s\n' "$R/.rite/worktrees/issue-140" > "$R/.rite/tmp-artifacts.tsv"
make_corpse "$R" 140
out=$(run_pcc "$R")
assert "C-05 fresh manifest-recorded corpse reaped (working tree)" "0" "$( [ -d "$R/.rite/worktrees/issue-140" ] && echo 1 || echo 0 )"
assert "C-05 fresh manifest-recorded corpse reaped (admin dir)" "0" "$( [ -d "$R/.git/worktrees/issue-140" ] && echo 1 || echo 0 )"
assert_grep "C-05 bypass is LOGGED (not silent)" "$R/pcc.err" "manifest 記録済み \(削除失敗確認済み\) corpse session worktree のため age guard をバイパスします"
assert "C-05 manifest entry consumed (file removed)" "0" "$( [ -f "$R/.rite/tmp-artifacts.tsv" ] && echo 1 || echo 0 )"
case "$out" in *"session_worktrees=1"*) pass "C-05 status reports session_worktrees=1" ;; *) fail "C-05 status: $out" ;; esac

echo "=== C-05b (#1945 control): fresh corpse + manifest records a DIFFERENT path → survives (surgical, age guard intact) ==="
R=$(make_repo 141); cleanup_dirs+=("$R")
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
rm -f "$R/.rite/state/issue-claims/issue-141.json"
# A real, existing-but-not-a-git-worktree directory: Step 4.5's new
# session_worktree case only checks path existence (no dirty check, no reap —
# it defers entirely to Step 5), so an existing decoy path KEEPS the entry
# (survives to reach Step 5's exact-match grep) — a non-vacuous mismatch,
# mirroring D-03's approach for the branch bypass.
mkdir -p "$R/.rite/worktrees/issue-141-decoy"
printf 'session_worktree\t%s\n' "$R/.rite/worktrees/issue-141-decoy" > "$R/.rite/tmp-artifacts.tsv"
make_corpse "$R" 141
out=$(run_pcc "$R")
assert "C-05b mismatched-entry fresh corpse survives (age guard)" "1" "$( [ -d "$R/.rite/worktrees/issue-141" ] && echo 1 || echo 0 )"
assert_grep "C-05b age-guard skip WARNING on stderr (not silent)" "$R/pcc.err" "age guard \(24h\) 未達のため回収を見送ります"
assert "C-05b mismatch entry survived Step 4.5 (non-vacuous: bypass grep saw it)" "1" "$( grep -qxF "session_worktree$(printf '\t')$R/.rite/worktrees/issue-141-decoy" "$R/.rite/tmp-artifacts.tsv" 2>/dev/null && echo 1 || echo 0 )"
case "$out" in *"session_worktrees=0"*) pass "C-05b status reports session_worktrees=0" ;; *) fail "C-05b status: $out" ;; esac

echo "=== C-05c (#1945): manifest-recorded LIVE session worktree is NOT reaped by Step 4.5's ungated pass ==="
R=$(make_repo 142); cleanup_dirs+=("$R")
# A clean, healthy (non-corpse) session worktree whose path is manifest-recorded
# (as would happen from a sandbox-mask-skip deferred removal) but SID_A (the
# claim holder) stays live. If session_worktree entries were reaped by Step
# 4.5's ungated worktree-type pass (dirty-check only, no claim/self-exclusion/
# live-cwd gates), this live worktree would be destroyed silently. It must
# survive entirely (Step 4.5 defers, Step 5's own claim-liveness Gate 2 also
# protects it).
printf 'session_worktree\t%s\n' "$R/.rite/worktrees/issue-142" > "$R/.rite/tmp-artifacts.tsv"
out=$(run_pcc "$R")
assert "C-05c live session worktree survives Step 4.5's ungated pass" "1" "$( [ -d "$R/.rite/worktrees/issue-142" ] && echo 1 || echo 0 )"
assert "C-05c claim file survives (worktree never reached Step 5 reap either)" "1" "$( [ -f "$R/.rite/state/issue-claims/issue-142.json" ] && echo 1 || echo 0 )"
assert "C-05c manifest entry survives (Step 4.5 preserved it verbatim, path still exists)" "1" "$( grep -qxF "session_worktree$(printf '\t')$R/.rite/worktrees/issue-142" "$R/.rite/tmp-artifacts.tsv" 2>/dev/null && echo 1 || echo 0 )"
case "$out" in *"session_worktrees=0"*) pass "C-05c status reports session_worktrees=0 (nothing reaped)" ;; *) fail "C-05c status: $out" ;; esac

echo "=== C-05d (#1945): manifest-recorded session_worktree entry for an ALREADY-GONE path is dropped by Step 4.5 (self-heal) ==="
R=$(make_repo 143); cleanup_dirs+=("$R")
# The worktree was already reaped by a prior run (or never existed at this
# path); the manifest entry is a stale leftover. Step 4.5's session_worktree
# case must drop it (the "already gone" self-heal), same as the worktree/
# branch cases already do for their own types.
printf 'session_worktree\t%s\n' "$R/.rite/worktrees/issue-999-gone" > "$R/.rite/tmp-artifacts.tsv"
run_pcc "$R" >/dev/null
assert "C-05d stale already-gone entry is dropped" "0" "$( [ -f "$R/.rite/tmp-artifacts.tsv" ] && grep -qxF "session_worktree$(printf '\t')$R/.rite/worktrees/issue-999-gone" "$R/.rite/tmp-artifacts.tsv" && echo 1 || echo 0 )"

echo "=== C-06 (#1945, mirrors D-04): multi-entry session_worktree manifest → only the reaped entry is consumed ==="
R=$(make_repo 150); cleanup_dirs+=("$R")
# Two recorded session_worktree entries: issue-150 (reap target — fresh
# corpse, claim-free) and a co-pending decoy path that must survive the
# consumption write-back untouched. This exercises the survivor-preserving
# `cp` branch (multi-entry manifest) that C-05's single-entry `rm -f` branch
# cannot reach — without this test, a survivor-drop bug in the cp branch
# would go undetected by the full suite.
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
rm -f "$R/.rite/state/issue-claims/issue-150.json"
mkdir -p "$R/.rite/worktrees/issue-150-copending-decoy"
printf 'session_worktree\t%s\nsession_worktree\t%s\n' \
  "$R/.rite/worktrees/issue-150" "$R/.rite/worktrees/issue-150-copending-decoy" > "$R/.rite/tmp-artifacts.tsv"
make_corpse "$R" 150
out=$(run_pcc "$R")
assert "C-06 target corpse reaped (bypass)" "0" "$( [ -d "$R/.rite/worktrees/issue-150" ] && echo 1 || echo 0 )"
assert "C-06 target manifest entry consumed" "0" "$( grep -qxF "session_worktree$(printf '\t')$R/.rite/worktrees/issue-150" "$R/.rite/tmp-artifacts.tsv" 2>/dev/null && echo 1 || echo 0 )"
assert "C-06 co-pending entry preserved (cp survivors branch, not silently dropped)" "1" "$( grep -qxF "session_worktree$(printf '\t')$R/.rite/worktrees/issue-150-copending-decoy" "$R/.rite/tmp-artifacts.tsv" 2>/dev/null && echo 1 || echo 0 )"
assert "C-06 co-pending decoy directory untouched" "1" "$( [ -d "$R/.rite/worktrees/issue-150-copending-decoy" ] && echo 1 || echo 0 )"
case "$out" in *"session_worktrees=1"*) pass "C-06 status reports session_worktrees=1" ;; *) fail "C-06 status: $out" ;; esac

print_summary "$(basename "$0")" \
  "Drift hint: pr-cycle-cleanup.sh Step 5 §8 — Gate 0 self-exclusion (cwd/RITE_WORKTREE == self → never reap) + worktree liveness guard (Issue #1524: a session's active flow-state worktree ref → never reap; reap → null owner ref / Issue #1552: claim-join — issue's claim holder still active=true, even with a stale 2h heartbeat → never reap) + OS-level live-cwd guard (Issue #1544: any live process standing in the tree → never reap, via worktree-live-cwd.sh) + 3 gates (strict ^issue-[0-9]+$ / claim not-live / clean); Issue #1957 corpse reap: admin-HEAD-missing AND git-unrecognized trees bypass Gate 3 and reap (rm -rf tree + admin dir) behind claim + 24h age guards — HEAD-present rc≠0 trees stay on the conservative skip; Issue #1670 branch recovery: after reap, SAFE-delete the branch (merged → recovered) and FORCE-delete only manifest-recorded (merge-confirmed) branches, preserving unmerged work; Issue #1966 free-arm manifest bypass: a claim-free worktree whose checked-out branch is manifest-recorded (merge-confirmed) bypasses the 24h age guard (harness mtime churn would otherwise leak it forever) and its manifest entry is consumed immediately after any successful branch recovery (-d and -D alike, best-effort with WARNING on failure); Issue #1945 corpse-path manifest bypass: a corpse cannot resolve its branch (git doesn't recognize the tree) so the #1966 branch bypass never fires for one — cleanup.md Step 4-W now records the worktree's own PATH (not branch) into the manifest when removal fails/is skipped for busy/sandbox-mask reasons (merge-confirmed only), and the corpse age guard checks that PATH before falling back to the 24h wait, consuming the entry on successful reap (surgical: a mismatched path entry does not bypass); wiki-worktree excluded; session-start best-effort wiring."
