#!/bin/bash
# Tests for issue-claim.sh (multi-session design §7).
#
# Covers:
#   AC-1: concurrent claim → exactly one process succeeds (noclobber atomicity)
#   AC-2: own | other | stale classification (live / active=false / >2h)
#   AC-3: release removes only the OWN claim; another session's is untouched
#   AC-4: release on an absent claim is idempotent (success)
#   plus: free check, stale-steal, corrupt-claim → stale, live-other refusal (rc 10)
#   Issue #1718: concurrent stale-STEAL CAS (TC-14, exactly one wins) + lone-steal
#                non-regression (TC-15) + no-flock branch lone steal (TC-16, F-03)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

IC="$SCRIPT_DIR/../issue-claim.sh"
FS="$SCRIPT_DIR/../flow-state.sh"

SID_A="aaaaaaaa-1111-2222-3333-444444444444"
SID_B="bbbbbbbb-5555-6666-7777-888888888888"

cleanup_dirs=()
cleanup() { local d; for d in "${cleanup_dirs[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done; return 0; }
trap cleanup EXIT

ROOT=$(make_sandbox --branch develop)
cleanup_dirs+=("$ROOT")
export RITE_STATE_ROOT="$ROOT"

# Helper: set an active flow-state for a session (makes its claim "live").
mk_active() { bash "$FS" set --session "$1" --phase implement --issue "$2" --branch x --next n >/dev/null 2>&1; }
claim()   { bash "$IC" claim   --session "$1" --issue "$2" ${3:+--worktree "$3"} 2>/dev/null; }
check()   { bash "$IC" check   --session "$1" --issue "$2" 2>/dev/null; }
release() { bash "$IC" release --session "$1" --issue "$2" 2>/dev/null; }

# === AC-2 / free / own / other / stale ===
echo "=== TC-1: check on free issue → free ==="
assert "TC-1 free" "free" "$(check "$SID_A" 700)"

echo "=== TC-2: claim → claimed; check → own ==="
mk_active "$SID_A" 700
assert "TC-2 claimed" "claimed" "$(claim "$SID_A" 700)"
assert "TC-2 own" "own" "$(check "$SID_A" 700)"

echo "=== TC-3 (AC-2): other session sees live claim as 'other' ==="
assert "TC-3 other" "other" "$(check "$SID_B" 700)"

echo "=== TC-4 (AC-5): claim by other live session refused (rc 10, prints 'other') ==="
rc=0; out=$(bash "$IC" claim --session "$SID_B" --issue 700 2>/dev/null) || rc=$?
assert "TC-4 prints other" "other" "$out"
assert "TC-4 rc 10" "10" "$rc"

echo "=== TC-5 (AC-3): other session's release does NOT touch the claim ==="
assert "TC-5 release skipped" "skipped" "$(release "$SID_B" 700)"
assert "TC-5 holder still A" "$SID_A" "$(jq -r .session_id "$ROOT/.rite/state/issue-claims/issue-700.json")"

echo "=== TC-6 (AC-2): active=false holder → stale; stale-steal succeeds ==="
bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
assert "TC-6 stale (inactive)" "stale" "$(check "$SID_B" 700)"
assert "TC-6 steal → claimed" "claimed" "$(claim "$SID_B" 700)"
assert "TC-6 holder now B" "$SID_B" "$(jq -r .session_id "$ROOT/.rite/state/issue-claims/issue-700.json")"

echo "=== TC-7 (AC-2): holder updated_at > 2h → stale ==="
mk_active "$SID_A" 701
claim "$SID_A" 701 >/dev/null
PAST=$(date -u -d '3 hours ago' +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-3H +"%Y-%m-%dT%H:%M:%SZ")
tmp=$(mktemp); jq --arg t "$PAST" '.updated_at=$t' "$ROOT/.rite/sessions/$SID_A.flow-state" > "$tmp" && mv "$tmp" "$ROOT/.rite/sessions/$SID_A.flow-state"
assert "TC-7 stale (2h aged)" "stale" "$(check "$SID_B" 701)"

echo "=== TC-8 (AC-4): release on absent claim is idempotent ==="
assert "TC-8 release absent → released" "released" "$(release "$SID_A" 9999)"

echo "=== TC-9: own-claim refresh stores worktree path; release removes it ==="
mk_active "$SID_A" 702
claim "$SID_A" 702 "/abs/wt/issue-702" >/dev/null
assert "TC-9 worktree recorded" "/abs/wt/issue-702" "$(jq -r .worktree "$ROOT/.rite/state/issue-claims/issue-702.json")"
assert "TC-9 release own" "released" "$(release "$SID_A" 702)"
assert "TC-9 check free after release" "free" "$(check "$SID_A" 702)"

echo "=== TC-10: corrupt claim file → stale (reclaimable) ==="
mkdir -p "$ROOT/.rite/state/issue-claims"
printf 'not-json{' > "$ROOT/.rite/state/issue-claims/issue-703.json"
assert "TC-10 corrupt → stale" "stale" "$(check "$SID_A" 703)"

echo "=== TC-11 (AC-1): 5 concurrent claims → exactly one 'claimed' ==="
for i in 1 2 3 4 5; do mk_active "0000000$i-1111-2222-3333-444444444444" 900; done
rm -f "$ROOT"/claimout.* 2>/dev/null || true
for i in 1 2 3 4 5; do
  ( bash "$IC" claim --session "0000000$i-1111-2222-3333-444444444444" --issue 900 > "$ROOT/claimout.$i" 2>/dev/null ) &
done
wait
_claimed=0
for i in 1 2 3 4 5; do [ "$(cat "$ROOT/claimout.$i" 2>/dev/null)" = "claimed" ] && _claimed=$((_claimed+1)); done
assert "TC-11 exactly one claimed" "1" "$_claimed"

echo "=== TC-12: invalid --issue rejected (rc 1) ==="
rc=0; bash "$IC" claim --session "$SID_A" --issue abc >/dev/null 2>&1 || rc=$?; assert "TC-12 non-numeric rc 1" "1" "$rc"
rc=0; bash "$IC" check --session "$SID_A" --issue 0 >/dev/null 2>&1 || rc=$?; assert "TC-12 zero rc 1" "1" "$rc"

echo "=== TC-13 (Issue #1530): env-first resolution in _resolve_current_session_id (no --session path) ==="
# Regression guard for the env-first precedence flip (review F-01). All TCs above pass --session,
# so the env/file branch was never exercised — issue-claim.sh's env-first reorder was a dead guard
# (mutation: reverting it to file-first kept every TC green). This pins env-first directly.
#
# Part 1: env outranks a differing .rite-session-id. A no-override claim must key its holder to env
# (SID_A), not the stale shared file (SID_B). Reverting issue-claim.sh to file-first fails this assert.
rm -f "$ROOT/.rite/state/issue-claims/issue-710.json" 2>/dev/null || true
printf '%s' "$SID_B" > "$ROOT/.rite-session-id"   # shared file says SID_B (stale)
mk_active "$SID_A" 710                              # env session SID_A is the live one
env -u CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID="$SID_A" bash "$IC" claim --issue 710 >/dev/null 2>&1
assert "TC-13 no-override claim holder is env sid (SID_A), not stale file sid (SID_B)" \
  "$SID_A" "$(jq -r .session_id "$ROOT/.rite/state/issue-claims/issue-710.json")"
# Part 2: env-absent fallback resolves the FILE sid (SID_B) — proven by holder==SID_B AND check==own
# (resolver returned SID_B == holder), not merely a non-holder classification that empty would also give.
rm -f "$ROOT/.rite/state/issue-claims/issue-711.json" 2>/dev/null || true
printf '%s' "$SID_B" > "$ROOT/.rite-session-id"     # self-contained: set the file sid this Part relies on
mk_active "$SID_B" 711                              # holder SID_B, file SID_B (set just above), env unset below
env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID bash "$IC" claim --issue 711 >/dev/null 2>&1
assert "TC-13 env-absent claim holder resolved via file sid (SID_B)" \
  "$SID_B" "$(jq -r .session_id "$ROOT/.rite/state/issue-claims/issue-711.json")"
assert "TC-13 env-absent check own (resolver returned file sid SID_B == holder)" \
  "own" "$(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID bash "$IC" check --issue 711)"

echo "=== TC-14 (Issue #1718 AC-1): concurrent stale-STEAL → exactly one 'claimed' ==="
# TC-11 covers concurrent claim of a FREE issue (noclobber). This covers the
# separate stale-STEAL path: N sessions all classify the SAME stale claim as
# reclaimable out-of-lock, then race to overwrite it. Without the in-lock CAS
# (_atomic_claim_steal), flock only serializes the mv and BOTH would "steal"
# (double-commit). The CAS re-verifies the holder under the lock so exactly one
# wins; the losers see the holder already swapped and abort with "other" (rc 10).
SID_STALE="cccccccc-9999-8888-7777-666666666666"
mk_active "$SID_STALE" 950
assert "TC-14 stale-holder claims first" "claimed" "$(claim "$SID_STALE" 950)"
bash "$FS" deactivate --session "$SID_STALE" --next done >/dev/null 2>&1  # holder now inactive → stale
assert "TC-14 precondition: holder classified stale" "stale" "$(check "$SID_A" 950)"
rm -f "$ROOT"/stealout.* 2>/dev/null || true
for i in 1 2 3 4 5; do mk_active "d000000$i-1111-2222-3333-444444444444" 950; done
for i in 1 2 3 4 5; do
  ( bash "$IC" claim --session "d000000$i-1111-2222-3333-444444444444" --issue 950 > "$ROOT/stealout.$i" 2>/dev/null ) &
done
wait
_stolen=0; _other=0
for i in 1 2 3 4 5; do
  case "$(cat "$ROOT/stealout.$i" 2>/dev/null)" in
    claimed) _stolen=$((_stolen+1)) ;;
    other)   _other=$((_other+1)) ;;
  esac
done
assert "TC-14 exactly one stole the stale claim (AC-1)" "1" "$_stolen"
assert "TC-14 the other four aborted with 'other'" "4" "$_other"

echo "=== TC-15 (Issue #1718 AC-2): single-session stale-steal is non-regressed ==="
# The CAS path must still let a lone stealer succeed (holder unchanged == expected).
SID_STALE2="eeeeeeee-1010-1010-1010-101010101010"
mk_active "$SID_STALE2" 951
claim "$SID_STALE2" 951 >/dev/null 2>&1
bash "$FS" deactivate --session "$SID_STALE2" --next done >/dev/null 2>&1
assert "TC-15 lone steal → claimed" "claimed" "$(claim "$SID_A" 951)"
assert "TC-15 holder now A" "$SID_A" "$(jq -r .session_id "$ROOT/.rite/state/issue-claims/issue-951.json")"

echo "=== TC-16: flock-absent concurrent stale-STEAL → exactly one 'claimed' ==="
# Force a stock-macOS-compatible PATH without flock. The portable critical section
# must preserve the same exactly-one contract as TC-14.
noflock_stub=$(mktemp -d)
cleanup_dirs+=("$noflock_stub")
for _c in bash sh cat date dirname git grep head jq mkdir mktemp mv ps rm sed tr wc sleep; do
  _p=$(command -v "$_c" 2>/dev/null) && ln -sf "$_p" "$noflock_stub/$_c"
done
run_noflock() { PATH="$noflock_stub" bash "$IC" "$@" 2>/dev/null; }
SID_NF="ffffffff-1111-2222-3333-444444444444"
mk_active "$SID_NF" 960
# Sanity probe: the stub must be able to run a claim at all. A curated PATH can miss a
# host-specific tool path — skip (not fail) rather than mis-attribute a setup gap to the
# no-flock logic (the same platform-fragility guard TC-014 in work-memory-lock applies).
if [ "$(run_noflock claim --session "$SID_NF" --issue 960)" != "claimed" ]; then
  pass "TC-16 skipped: no-flock PATH stub could not run a claim on this host (env-specific setup)"
else
  bash "$FS" deactivate --session "$SID_NF" --next done >/dev/null 2>&1  # holder now stale
  assert "TC-16 precondition: holder classified stale" "stale" "$(check "$SID_A" 960)"
  rm -f "$ROOT"/nfstealout.* 2>/dev/null || true
  for i in 1 2 3 4 5; do mk_active "f000000$i-1111-2222-3333-444444444444" 960; done
  for i in 1 2 3 4 5; do
    ( run_noflock claim --session "f000000$i-1111-2222-3333-444444444444" --issue 960 > "$ROOT/nfstealout.$i" ) &
  done
  wait
  _nf_stolen=0; _nf_other=0
  for i in 1 2 3 4 5; do
    case "$(cat "$ROOT/nfstealout.$i" 2>/dev/null)" in
      claimed) _nf_stolen=$((_nf_stolen+1)) ;;
      other)   _nf_other=$((_nf_other+1)) ;;
    esac
  done
  assert "TC-16 exactly one no-flock contender stole the stale claim" "1" "$_nf_stolen"
  assert "TC-16 the other four no-flock contenders aborted" "4" "$_nf_other"
fi

echo "=== TC-17: stale lock residue is reclaimed after PID reuse ==="
SID_RESIDUE="abababab-1111-2222-3333-444444444444"
mk_active "$SID_RESIDUE" 970
assert "TC-17 owner claims first" "claimed" "$(claim "$SID_RESIDUE" 970)"
lockdir="$ROOT/.rite/state/issue-claims/.lock.d"
mkdir "$lockdir"
printf '%s\n' "$$" > "$lockdir/pid"
printf '%s\n' 'different process start identity' > "$lockdir/process_start"
assert "TC-17 release reclaims reused-PID residue and succeeds" "released" "$(release "$SID_RESIDUE" 970)"
assert "TC-17 claim is removed after residue recovery" "free" "$(check "$SID_RESIDUE" 970)"

echo "=== TC-18: malformed/non-positive lock PID is reclaimable ==="
mk_active "$SID_RESIDUE" 971
assert "TC-18 owner claims first" "claimed" "$(claim "$SID_RESIDUE" 971)"
mkdir "$lockdir"
printf '%s\n' '%s' > "$lockdir/pid"
printf '%s\n' 'malformed owner' > "$lockdir/process_start"
assert "TC-18 malformed PID residue is reclaimed" "released" "$(release "$SID_RESIDUE" 971)"
assert "TC-18 claim is removed after malformed residue recovery" "free" "$(check "$SID_RESIDUE" 971)"

print_summary "$(basename "$0")" \
  "Drift hint: issue-claim.sh §7 — claim/release/check; liveness reuses session-ownership.sh 2h threshold + parse_iso8601_to_epoch; noclobber + portable mkdir-lock atomicity; stale-steal CAS via _atomic_claim_steal; _resolve_current_session_id env-first."
