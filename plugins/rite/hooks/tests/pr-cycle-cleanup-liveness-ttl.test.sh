#!/bin/bash
# Tests for pr-cycle-cleanup.sh's worktree liveness guard TTL judgment
# .
#
# Before this Issue, an `active=true` holder protected its session worktree
# with NO time bound (both signal (A) flow-state.worktree scan and signal (B)
# claim-join, per _rite_worktree_protected_by_flow_state). A session that
# ends WITHOUT session-end.sh's SessionEnd hook firing (forced quit / crash /
# terminal close) leaves its flow-state at `active=true` forever, so its
# worktree/branch could never be lazily reaped — a permanent dead-lock. The
# fix bounds that protection to a liveness TTL (default 24h,
# `RITE_SESSION_LIVENESS_TTL_HOURS`): an active=true holder is protected only
# while its flow-state `updated_at` is within the TTL.
#
#   AC-1: TTL-exceeded active=true holder (signal A) -> worktree is reaped
#   AC-2: TTL-within active=true holder -> protected (non-regression of #1524/#1552)
#   AC-3: after a TTL-exceeded holder's worktree is reaped, its manifest-recorded
#         (merge-confirmed) branch is force-recovered in the same run (#1670 wiring)
#   AC-4: updated_at missing / malformed (non-ISO-8601) -> protected, fail-safe,
#         no date-incompatible WARNING (that WARNING is reserved for a
#         well-formed-but-unparseable timestamp — see the 4.5 case below)
#   AC-6: TTL boundary — near-boundary within-margin age -> protected;
#         age == TTL+1s -> reaped (see TC-6's comment for why the literal
#         age == TTL equality itself is a one-line `-le` inspection rather
#         than a wall-clock-pinned assertion)
#   AC-7: an active=false holder is reaped regardless of updated_at (non-regression:
#         TTL only bounds active=true protection, it does not shorten anything else)
#   AC-8: Gate 0 self-exclusion still wins even when the self worktree's own TTL
#         has been exceeded (self-exclusion is evaluated independently of TTL)
#   4.5:  a well-formed (regex-matching) but unparseable timestamp (invalid
#         calendar value) -> TTL judgment skipped, protect + WARNING (fail-safe
#         for a host whose `date` can't parse a technically-valid-shaped string)
#   (extra) signal (B) claim-join in isolation (no flow-state.worktree recorded)
#         also honors the TTL, both exceeded (reaped) and within (protected)
#
# Each TC's non-vacuousness is established by construction: TC-1/TC-6b/TC-9/
# TC-10 all show the SAME setup reaping once the relevant updated_at crosses
# the TTL threshold that TC-2/TC-6/TC-11 show protected — flip either boundary
# and the corresponding pair of assertions inverts.
set -euo pipefail

# Clean session-id env (mirrors pr-cycle-cleanup-session-reap.test.sh): the
# reaper resolves its session via issue-claim.sh check, which is env-first, so
# ambient CLAUDE_CODE_SESSION_ID must not leak into these SID_B-as-reaper tests.
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

PCC="$SCRIPT_DIR/../scripts/pr-cycle-cleanup.sh"
FS="$SCRIPT_DIR/../flow-state.sh"
IC="$SCRIPT_DIR/../issue-claim.sh"
GIT="git -c user.email=t@test.local -c user.name=test -c commit.gpgsign=false"

cleanup_dirs=()
cleanup() {
  local d
  for d in "${cleanup_dirs[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done
  return 0
}
trap cleanup EXIT

# SID_A = the holder session whose worktree/claim is under test; SID_B = the
# (different) session that triggers the reap, matching the sibling test file's
# convention (a reaping session is never its own holder in practice).
SID_A="aaaaaaaa-1111-2222-3333-444444444444"
SID_B="bbbbbbbb-5555-6666-7777-888888888888"

# Portable "N hours/seconds ago" -> ISO 8601 UTC (GNU date -d, BSD date -v fallback
# — same two-path convention as issue-claim.test.sh / work-memory-lock.test.sh).
ts_hours_ago() {
  local hours="$1"
  date -u -d "${hours} hours ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -v-"${hours}"H +"%Y-%m-%dT%H:%M:%SZ"
}
ts_seconds_ago() {
  local secs="$1"
  date -u -d "${secs} seconds ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -v-"${secs}"S +"%Y-%m-%dT%H:%M:%SZ"
}

# Build a main checkout with multi_session config + a session worktree for issue
# N. Holder SID_A gets BOTH signal (A) (flow-state.worktree recorded) and signal
# (B) (a matching claim) so either alone would protect pre-#1923 — TTL must gate
# both. `.rite-session-id`=SID_B makes the reaping session distinct from the
# holder. Echoes the repo root.
make_repo() {
  local n="$1" root
  root=$(make_sandbox --branch develop)
  printf 'multi_session:\n  enabled: true\n  worktree_base: ".rite/worktrees"\n' > "$root/rite-config.yml"
  printf '%s' "$SID_B" > "$root/.rite-session-id"
  ( cd "$root" && $GIT worktree add -q -b "feat/issue-$n" ".rite/worktrees/issue-$n" >/dev/null 2>&1 )
  RITE_STATE_ROOT="$root" bash "$FS" set --session "$SID_A" --phase implement --issue "$n" \
    --branch "feat/issue-$n" --next n --worktree "$root/.rite/worktrees/issue-$n" >/dev/null 2>&1
  RITE_STATE_ROOT="$root" bash "$IC" claim --issue "$n" --session "$SID_A" \
    --worktree "$root/.rite/worktrees/issue-$n" >/dev/null 2>&1
  printf '%s' "$root"
}

set_updated_at() {
  local root="$1" value="$2" sf tmp
  sf="$root/.rite/sessions/${SID_A}.flow-state"
  tmp=$(mktemp) || return 1
  jq --arg ts "$value" '.updated_at = $ts' "$sf" > "$tmp" && mv "$tmp" "$sf"
}
del_updated_at() {
  local root="$1" sf tmp
  sf="$root/.rite/sessions/${SID_A}.flow-state"
  tmp=$(mktemp) || return 1
  jq 'del(.updated_at)' "$sf" > "$tmp" && mv "$tmp" "$sf"
}

run_pcc() { ( cd "$1" && bash "$PCC" 2>"$1/pcc.err"; echo "rc=$?" ) ; }

echo "=== TC-1 (AC-1): updated_at 25h ago (既定 TTL 24h 超過) -> reaped ==="
R=$(make_repo 200); cleanup_dirs+=("$R")
set_updated_at "$R" "$(ts_hours_ago 25)"
out=$(run_pcc "$R")
assert "TC-1 TTL-exceeded worktree reaped" "0" "$( [ -d "$R/.rite/worktrees/issue-200" ] && echo 1 || echo 0 )"
assert "TC-1 claim file deleted" "0" "$( [ -f "$R/.rite/state/issue-claims/issue-200.json" ] && echo 1 || echo 0 )"
case "$out" in *"session_worktrees=1"*) pass "TC-1 status reports session_worktrees=1" ;; *) fail "TC-1 status: $out" ;; esac

echo "=== TC-2 (AC-2, non-regression): updated_at 3h ago (TTL 以内) -> protected ==="
# 3h is deliberate (not 1h): it must clear issue-claim.sh's own independent 2h
# claim-staleness window so Gate 2 does NOT independently protect the worktree —
# otherwise a mutation that disables the TTL guard entirely would still pass
# this assertion (Gate 2 alone would protect a fresh-enough claim), making the
# TC vacuous. See age_flow_state()'s comment in pr-cycle-cleanup-session-reap.test.sh
# for the identical rationale.
R=$(make_repo 201); cleanup_dirs+=("$R")
set_updated_at "$R" "$(ts_hours_ago 3)"
out=$(run_pcc "$R")
assert "TC-2 TTL-within worktree survives" "1" "$( [ -d "$R/.rite/worktrees/issue-201" ] && echo 1 || echo 0 )"
assert_grep "TC-2 worktree-liveness WARNING on stderr" "$R/pcc.err" "worktree liveness"
case "$out" in *"session_worktrees=0"*) pass "TC-2 status reports session_worktrees=0" ;; *) fail "TC-2 status: $out" ;; esac

echo "=== TC-3 (AC-3, #1670 wiring): TTL 超過 holder の manifest 記録ブランチが worktree reap 後に回収される ==="
R=$(make_repo 202); cleanup_dirs+=("$R")
set_updated_at "$R" "$(ts_hours_ago 25)"
echo "wip" > "$R/.rite/worktrees/issue-202/wip.txt"
( cd "$R/.rite/worktrees/issue-202" && $GIT add wip.txt && $GIT commit -q -m "wip: unmerged (squash-merge shape)" ) >/dev/null 2>&1
printf 'branch\tfeat/issue-202\n' > "$R/.rite/tmp-artifacts.tsv"
out=$(run_pcc "$R")
assert "TC-3 worktree reaped" "0" "$( [ -d "$R/.rite/worktrees/issue-202" ] && echo 1 || echo 0 )"
assert "TC-3 manifest-recorded branch force-recovered (gone)" "0" "$( cd "$R" && $GIT rev-parse --verify feat/issue-202 >/dev/null 2>&1 && echo 1 || echo 0 )"
case "$out" in *"session_branches=1"*) pass "TC-3 status reports session_branches=1" ;; *) fail "TC-3 status: $out" ;; esac

echo "=== TC-4a (AC-4): updated_at 欠落 -> 保護 (fail-safe, date 非互換 WARNING 無し) ==="
R=$(make_repo 203); cleanup_dirs+=("$R")
del_updated_at "$R"
out=$(run_pcc "$R")
assert "TC-4a missing updated_at -> worktree survives (fail-safe protect)" "1" "$( [ -d "$R/.rite/worktrees/issue-203" ] && echo 1 || echo 0 )"
assert_not_grep "TC-4a no date-incompatible WARNING for merely-missing updated_at" "$R/pcc.err" "date コマンドで"
case "$out" in *"session_worktrees=0"*) pass "TC-4a status reports session_worktrees=0" ;; *) fail "TC-4a status: $out" ;; esac

echo "=== TC-4b (AC-4): updated_at 不正形式 (非 ISO-8601) -> 保護 (fail-safe, date 非互換 WARNING 無し) ==="
R=$(make_repo 204); cleanup_dirs+=("$R")
set_updated_at "$R" "not-a-timestamp"
out=$(run_pcc "$R")
assert "TC-4b malformed updated_at -> worktree survives (fail-safe protect)" "1" "$( [ -d "$R/.rite/worktrees/issue-204" ] && echo 1 || echo 0 )"
assert_not_grep "TC-4b no date-incompatible WARNING for malformed (non-ISO) updated_at" "$R/pcc.err" "date コマンドで"
case "$out" in *"session_worktrees=0"*) pass "TC-4b status reports session_worktrees=0" ;; *) fail "TC-4b status: $out" ;; esac

echo "=== TC-5 (4.5): 形式は正しいが日付として不正 (date 解釈不能) -> TTL 判定 skip + 保護 + WARNING ==="
R=$(make_repo 205); cleanup_dirs+=("$R")
set_updated_at "$R" "9999-13-45T99:99:99Z"
out=$(run_pcc "$R")
assert "TC-5 well-formed-but-unparseable timestamp -> worktree survives (fail-safe)" "1" "$( [ -d "$R/.rite/worktrees/issue-205" ] && echo 1 || echo 0 )"
assert_grep "TC-5 date-incompatible WARNING emitted" "$R/pcc.err" "date コマンドで"
case "$out" in *"session_worktrees=0"*) pass "TC-5 status reports session_worktrees=0" ;; *) fail "TC-5 status: $out" ;; esac

echo "=== TC-6 (AC-6): TTL 境界近傍 (24h-60s、以内側) -> 保護 ==="
# 86340s (TTL-60s), not exactly 86400s: this test computes `ts_seconds_ago 86400`
# at one wall-clock instant, but pr-cycle-cleanup.sh reads its own `now` afresh
# a moment later (after subshell + bash startup + test setup latency). That gap
# pushes the effective age past the exact 24h boundary often enough to flake
# (reap decided age > ttl, protect assertion fails). A 60s safety margin makes
# the "protected" side of the boundary immune to that drift.
#
# Honesty note (the governing rationale cycle 2 review): with this margin, no assertion in
# this suite pins the literal age == ttl_seconds equality AC-6 describes —
# TC-6/TC-6b together only pin which side of the comparison is "protect" vs
# "reap" near the boundary, not the exact integer where it flips. The
# equality itself (`[ "$age" -le "$ttl_seconds" ]` in _rite_ttl_protects,
# not `-lt`) is a one-line inspection, not something a wall-clock-driven
# integration test can pin without a deterministic "now" injection point
# (not worth adding solely for this — CLAUDE.md シンプルさを死守する).
R=$(make_repo 206); cleanup_dirs+=("$R")
set_updated_at "$R" "$(ts_seconds_ago 86340)"
out=$(run_pcc "$R")
assert "TC-6 TTL boundary (24h-60s, within) -> protected" "1" "$( [ -d "$R/.rite/worktrees/issue-206" ] && echo 1 || echo 0 )"
case "$out" in *"session_worktrees=0"*) pass "TC-6 status reports session_worktrees=0" ;; *) fail "TC-6 status: $out" ;; esac

echo "=== TC-6b (AC-6): TTL 境界+1秒 (24h超) -> reaped ==="
R=$(make_repo 207); cleanup_dirs+=("$R")
set_updated_at "$R" "$(ts_seconds_ago 86401)"
out=$(run_pcc "$R")
assert "TC-6b TTL boundary+1s -> exceeded, reaped" "0" "$( [ -d "$R/.rite/worktrees/issue-207" ] && echo 1 || echo 0 )"
case "$out" in *"session_worktrees=1"*) pass "TC-6b status reports session_worktrees=1" ;; *) fail "TC-6b status: $out" ;; esac

echo "=== TC-7 (AC-7, non-regression): active=false holder は updated_at に関わらず reap 可能 ==="
R=$(make_repo 208); cleanup_dirs+=("$R")
set_updated_at "$R" "$(ts_hours_ago 1)"   # recent — would be "within TTL" if active=true
RITE_STATE_ROOT="$R" bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
out=$(run_pcc "$R")
assert "TC-7 active=false holder reaped regardless of (recent) updated_at" "0" "$( [ -d "$R/.rite/worktrees/issue-208" ] && echo 1 || echo 0 )"
case "$out" in *"session_worktrees=1"*) pass "TC-7 status reports session_worktrees=1" ;; *) fail "TC-7 status: $out" ;; esac

echo "=== TC-8 (AC-8): Gate 0 self-exclusion は TTL 超過の自セッション worktree でも勝つ ==="
R=$(make_repo 209); cleanup_dirs+=("$R")
set_updated_at "$R" "$(ts_hours_ago 25)"   # TTL exceeded — would be reapable via the liveness guard alone
out=$( cd "$R/.rite/worktrees/issue-209" && env -u RITE_WORKTREE bash "$PCC" 2>"$R/pcc.err"; echo "rc=$?" )
assert "TC-8 self worktree survives despite TTL-exceeded (self-exclusion wins)" "1" "$( [ -d "$R/.rite/worktrees/issue-209" ] && echo 1 || echo 0 )"
assert_grep "TC-8 self-exclusion WARNING on stderr" "$R/pcc.err" "self-exclusion"
case "$out" in *"session_worktrees=0"*) pass "TC-8 status reports session_worktrees=0" ;; *) fail "TC-8 status: $out" ;; esac

echo "=== TC-9 (env override): RITE_SESSION_LIVENESS_TTL_HOURS=1 で 2.5h 前の holder が超過扱いになる ==="
# 2.5h is deliberate and must clear BOTH thresholds for this TC to be
# non-vacuous: issue-claim.sh's own independent 2h claim-staleness window
# (so Gate 2 also agrees "stale" once the liveness guard steps aside) AND the
# 1h custom TTL override (so the liveness guard itself says "exceeded").
# Without the override (default 24h), 2.5h is well within the TTL, so the
# liveness guard would protect and Gate 2 would never even run — the
# worktree would incorrectly survive. Only a working env override reaps it.
R=$(make_repo 210); cleanup_dirs+=("$R")
set_updated_at "$R" "$(ts_seconds_ago 9000)"   # 2.5 hours ago
out=$( cd "$R" && RITE_SESSION_LIVENESS_TTL_HOURS=1 bash "$PCC" 2>"$R/pcc.err"; echo "rc=$?" )
assert "TC-9 custom 1h TTL: 2.5h-old holder exceeded -> reaped" "0" "$( [ -d "$R/.rite/worktrees/issue-210" ] && echo 1 || echo 0 )"
case "$out" in *"session_worktrees=1"*) pass "TC-9 status reports session_worktrees=1" ;; *) fail "TC-9 status: $out" ;; esac

echo "=== TC-9b (env override, error path): RITE_SESSION_LIVENESS_TTL_HOURS が非数値 -> WARNING + 既定 24h へフォールバック ==="
# Non-numeric override must not raw-bash-error out of the arithmetic; it must
# WARN and behave exactly as if the (default) override were absent. A 25h-old
# holder is TTL-exceeded under the 24h fallback, so this also proves the
# fallback value itself (not just "no crash") by reaping.
R=$(make_repo 217); cleanup_dirs+=("$R")
set_updated_at "$R" "$(ts_hours_ago 25)"
out=$( cd "$R" && RITE_SESSION_LIVENESS_TTL_HOURS="24h" bash "$PCC" 2>"$R/pcc.err"; echo "rc=$?" )
assert "TC-9b non-numeric TTL override falls back to 24h -> reaped" "0" "$( [ -d "$R/.rite/worktrees/issue-217" ] && echo 1 || echo 0 )"
assert_grep "TC-9b non-numeric override WARNING emitted" "$R/pcc.err" "正の整数ではありません"
case "$out" in *"session_worktrees=1"*) pass "TC-9b status reports session_worktrees=1" ;; *) fail "TC-9b status: $out" ;; esac

echo "=== TC-9c (env override, reject path): RITE_SESSION_LIVENESS_TTL_HOURS=0 -> WARNING + 既定 24h へフォールバック ==="
# "0" matches a laxer ^[0-9]+$ but must still be rejected (positive integer
# required). A 25h-old holder is TTL-exceeded under the 24h fallback, so this
# pins the `-gt 0`-equivalent reject path (cycle 3 test-reviewer finding: the
# prior TC-9b only covered the non-numeric-regex reject path, not TTL=0).
R=$(make_repo 218); cleanup_dirs+=("$R")
set_updated_at "$R" "$(ts_hours_ago 25)"
out=$( cd "$R" && RITE_SESSION_LIVENESS_TTL_HOURS="0" bash "$PCC" 2>"$R/pcc.err"; echo "rc=$?" )
assert "TC-9c TTL=0 falls back to 24h -> reaped" "0" "$( [ -d "$R/.rite/worktrees/issue-218" ] && echo 1 || echo 0 )"
assert_grep "TC-9c TTL=0 WARNING emitted" "$R/pcc.err" "正の整数ではありません"
case "$out" in *"session_worktrees=1"*) pass "TC-9c status reports session_worktrees=1" ;; *) fail "TC-9c status: $out" ;; esac

echo "=== TC-9d (env override, leading-zero reject path): RITE_SESSION_LIVENESS_TTL_HOURS=\"010\" -> WARNING + 既定 24h へフォールバック ==="
# Cycle 3 finding (code-quality-reviewer + error-handling-reviewer, independently):
# a laxer ^[0-9]+$ regex accepts leading-zero values like "010", but bash
# arithmetic (`$(( 010 * 3600 ))`) parses a leading zero as OCTAL, silently
# turning an intended 10h TTL into 8h (and "08"/"09" into a raw arithmetic
# error). A 9h-old holder demonstrates the real-world failure mode: under the
# (buggy) octal misinterpretation it would be wrongly REAPED (9h > 8h), but
# the fix rejects "010" outright and falls back to the 24h default, which
# correctly PROTECTS a 9h-old holder (9h < 24h). This is the non-vacuous
# distinguishing assertion — a regex that still accepted "010" would reap here.
R=$(make_repo 219); cleanup_dirs+=("$R")
set_updated_at "$R" "$(ts_hours_ago 9)"
out=$( cd "$R" && RITE_SESSION_LIVENESS_TTL_HOURS="010" bash "$PCC" 2>"$R/pcc.err"; echo "rc=$?" )
assert "TC-9d leading-zero TTL rejected, 9h-old holder protected under 24h fallback" "1" "$( [ -d "$R/.rite/worktrees/issue-219" ] && echo 1 || echo 0 )"
assert_grep "TC-9d leading-zero override WARNING emitted" "$R/pcc.err" "正の整数ではありません"

# ---------------------------------------------------------------------------
# Signal (B) claim-join in isolation (no flow-state.worktree recorded), mirroring
# pr-cycle-cleanup-session-reap.test.sh's T-09/T-10 shape but pinning the NEW
# TTL gate specifically on the claim-join path (make_repo above always sets
# BOTH signals together, so TC-1..TC-9 do not by themselves prove signal (B)'s
# own _rite_ttl_protects call is wired — these two do).
# ---------------------------------------------------------------------------
make_repo_claim_only() {
  local n="$1" root
  root=$(make_sandbox --branch develop)
  printf 'multi_session:\n  enabled: true\n  worktree_base: ".rite/worktrees"\n' > "$root/rite-config.yml"
  printf '%s' "$SID_B" > "$root/.rite-session-id"
  ( cd "$root" && $GIT worktree add -q -b "feat/issue-$n" ".rite/worktrees/issue-$n" >/dev/null 2>&1 )
  # No --worktree on this flow-state.sh set: signal (A) cannot match.
  RITE_STATE_ROOT="$root" bash "$FS" set --session "$SID_A" --phase implement --issue "$n" \
    --branch "feat/issue-$n" --next n >/dev/null 2>&1
  RITE_STATE_ROOT="$root" bash "$IC" claim --issue "$n" --session "$SID_A" \
    --worktree "$root/.rite/worktrees/issue-$n" >/dev/null 2>&1
  printf '%s' "$root"
}

echo "=== TC-10 (signal B only): claim-join の TTL 超過 -> reaped (flow-state.worktree 不記録) ==="
R=$(make_repo_claim_only 211); cleanup_dirs+=("$R")
set_updated_at "$R" "$(ts_hours_ago 25)"
out=$(run_pcc "$R")
assert "TC-10 claim-join-only TTL exceeded -> reaped" "0" "$( [ -d "$R/.rite/worktrees/issue-211" ] && echo 1 || echo 0 )"
case "$out" in *"session_worktrees=1"*) pass "TC-10 status reports session_worktrees=1" ;; *) fail "TC-10 status: $out" ;; esac

echo "=== TC-11 (signal B only): claim-join の TTL 以内 -> protected (flow-state.worktree 不記録) ==="
# 3h (not 1h): same rationale as TC-2 — must clear the 2h claim-staleness window
# so Gate 2 alone cannot account for the "survives" assertion (non-vacuous for
# the claim-join TTL gate specifically).
R=$(make_repo_claim_only 212); cleanup_dirs+=("$R")
set_updated_at "$R" "$(ts_hours_ago 3)"
out=$(run_pcc "$R")
assert "TC-11 claim-join-only TTL within -> protected" "1" "$( [ -d "$R/.rite/worktrees/issue-212" ] && echo 1 || echo 0 )"
assert_grep "TC-11 worktree-liveness WARNING on stderr" "$R/pcc.err" "worktree liveness"
case "$out" in *"session_worktrees=0"*) pass "TC-11 status reports session_worktrees=0" ;; *) fail "TC-11 status: $out" ;; esac

# ---------------------------------------------------------------------------
# Signal (A) flow-state.worktree scan in isolation (the governing rationale cycle 2 review
# finding: TC-10/TC-11 above isolate signal B alone, but no fixture isolated
# signal A's "protect" direction — every TC-2/TC-6/TC-13-style "survives"
# assertion also has a matching claim (make_repo sets both signals together),
# so signal B's claim-join resolves "protect" BEFORE signal A's loop is even
# reached. A mutation that made A never protect (regardless of TTL) passed the
# entire suite above undetected). Here the claim is recorded but points at a
# DIFFERENT (bogus) worktree, so signal B's exact-match join never fires —
# only signal A's flow-state.worktree scan can protect this target.
# ---------------------------------------------------------------------------
make_repo_flow_state_only() {
  local n="$1" root
  root=$(make_sandbox --branch develop)
  printf 'multi_session:\n  enabled: true\n  worktree_base: ".rite/worktrees"\n' > "$root/rite-config.yml"
  printf '%s' "$SID_B" > "$root/.rite-session-id"
  ( cd "$root" && $GIT worktree add -q -b "feat/issue-$n" ".rite/worktrees/issue-$n" >/dev/null 2>&1 )
  # flow-state.worktree recorded (matches) -> signal (A) can match.
  RITE_STATE_ROOT="$root" bash "$FS" set --session "$SID_A" --phase implement --issue "$n" \
    --branch "feat/issue-$n" --next n --worktree "$root/.rite/worktrees/issue-$n" >/dev/null 2>&1
  # Claim exists (so Gate 2's no-claim/free mtime-age-guard branch, which would
  # otherwise protect any freshly-created worktree regardless of the liveness
  # guard's own verdict, is never reached) but points at a bogus, unrelated
  # worktree path -> signal (B)'s exact worktree-match join never fires.
  RITE_STATE_ROOT="$root" bash "$IC" claim --issue "$n" --session "$SID_A" \
    --worktree "$root/.rite/worktrees/issue-${n}-bogus" >/dev/null 2>&1
  printf '%s' "$root"
}

echo "=== TC-14 (signal A only): flow-state.worktree scan の TTL 以内 -> protected (claim は別 worktree を指すため signal B は不発) ==="
# 3h (not 1h): same rationale as TC-2/TC-11 — must clear the 2h claim-staleness
# window so Gate 2 classifies the (mismatched, but present) claim as "stale"
# (reapable) rather than "other" (live) — otherwise Gate 2 alone would explain
# the "survives" assertion and signal A's own TTL gate would remain untested.
R=$(make_repo_flow_state_only 215); cleanup_dirs+=("$R")
set_updated_at "$R" "$(ts_hours_ago 3)"
out=$(run_pcc "$R")
assert "TC-14 signal-A-only TTL within -> protected" "1" "$( [ -d "$R/.rite/worktrees/issue-215" ] && echo 1 || echo 0 )"
assert_grep "TC-14 worktree-liveness WARNING on stderr" "$R/pcc.err" "worktree liveness"
case "$out" in *"session_worktrees=0"*) pass "TC-14 status reports session_worktrees=0" ;; *) fail "TC-14 status: $out" ;; esac

echo "=== TC-15 (signal A only): flow-state.worktree scan の TTL 超過 -> reaped (claim は別 worktree を指すため signal B は不発) ==="
R=$(make_repo_flow_state_only 216); cleanup_dirs+=("$R")
set_updated_at "$R" "$(ts_hours_ago 25)"
out=$(run_pcc "$R")
assert "TC-15 signal-A-only TTL exceeded -> reaped" "0" "$( [ -d "$R/.rite/worktrees/issue-216" ] && echo 1 || echo 0 )"
case "$out" in *"session_worktrees=1"*) pass "TC-15 status reports session_worktrees=1" ;; *) fail "TC-15 status: $out" ;; esac

# ---------------------------------------------------------------------------
# `+00:00` offset format coverage (the governing rationale review finding F-01). flow-state.sh
# (the canonical writer) emits `Z`, but pre-compact.sh / session-start.sh /
# session-end.sh emit `+00:00` for the very same updated_at field — most
# critically pre-compact.sh, whose heartbeat updates `updated_at` alone
# (leaving `active=true` untouched), making it the realistic "last write before
# a crash" for a long-running session that has gone through `/compact`. TC-1..11
# above all use ts_hours_ago()/ts_seconds_ago() which only ever produce `Z`
# suffixes — without these two TCs, a regression that narrows the parser back
# to `Z`-only would pass the entire suite above while silently reintroducing
# this Issue's own dead-lock for `/compact`-then-crash sessions.
# ---------------------------------------------------------------------------
ts_hours_ago_offset() {
  local hours="$1"
  date -u -d "${hours} hours ago" +"%Y-%m-%dT%H:%M:%S+00:00" 2>/dev/null \
    || date -u -v-"${hours}"H +"%Y-%m-%dT%H:%M:%S+00:00"
}

echo "=== TC-12 (F-01 regression): +00:00 形式で updated_at 25h ago (TTL 超過) -> reaped ==="
R=$(make_repo 213); cleanup_dirs+=("$R")
set_updated_at "$R" "$(ts_hours_ago_offset 25)"
out=$(run_pcc "$R")
assert "TC-12 +00:00-format TTL-exceeded worktree reaped" "0" "$( [ -d "$R/.rite/worktrees/issue-213" ] && echo 1 || echo 0 )"
case "$out" in *"session_worktrees=1"*) pass "TC-12 status reports session_worktrees=1" ;; *) fail "TC-12 status: $out" ;; esac

echo "=== TC-13 (F-01 regression): +00:00 形式で updated_at 1h ago (TTL 以内) -> protected ==="
R=$(make_repo 214); cleanup_dirs+=("$R")
set_updated_at "$R" "$(ts_hours_ago_offset 1)"
out=$(run_pcc "$R")
assert "TC-13 +00:00-format TTL-within worktree survives" "1" "$( [ -d "$R/.rite/worktrees/issue-214" ] && echo 1 || echo 0 )"
assert_grep "TC-13 worktree-liveness WARNING on stderr" "$R/pcc.err" "worktree liveness"
assert_not_grep "TC-13 no date-incompatible WARNING (well-formed +00:00 must parse)" "$R/pcc.err" "date コマンドで"
case "$out" in *"session_worktrees=0"*) pass "TC-13 status reports session_worktrees=0" ;; *) fail "TC-13 status: $out" ;; esac

print_summary "$(basename "$0")" \
  "Drift hint: pr-cycle-cleanup.sh's worktree liveness guard (signals A/B, the governing rationale/#1552) now gates both on the liveness TTL (the governing rationale, RITE_SESSION_LIVENESS_TTL_HOURS, default 24h) instead of protecting active=true holders unconditionally — bounds the dead-lock where a session that never runs SessionEnd (crash/forced-quit) leaves active=true forever."
