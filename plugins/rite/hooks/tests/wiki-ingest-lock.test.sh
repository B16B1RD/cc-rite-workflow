#!/bin/bash
# Tests for wiki-ingest-lock.sh (multi-session design §9).
#
# Verifies the ingest session lock used to serialize the LLM Write/Edit phase
# across sessions. Liveness is the lock's own acquired_at (within 2h), never the
# holder's flow-state:
#   a lock acquired within 2h blocks other sessions (concurrent_ingest rc 11),
#   even when the holder has no active flow-state
#   acquired_at older than 2h / missing / unparsable → reclaimable
#   a failed acquired_at write stops acquire and leaves no lockdir behind
#   release removes only the OWN lock; idempotent on absent lock
#   wiki-ingest step 9.0 warns on stderr when the lock is no longer own
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
# shellcheck source=../session-ownership.sh
source "$SCRIPT_DIR/../session-ownership.sh"

WIL="$SCRIPT_DIR/../scripts/wiki-ingest-lock.sh"
FS="$SCRIPT_DIR/../flow-state.sh"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INGEST_SKILL="$PLUGIN_ROOT/skills/wiki-ingest/SKILL.md"
SID_A="aaaaaaaa-1111-2222-3333-444444444444"
SID_B="bbbbbbbb-5555-6666-7777-888888888888"

cleanup_dirs=()
cleanup() { local d; for d in "${cleanup_dirs[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done; return 0; }
trap cleanup EXIT

ROOT=$(make_sandbox --branch develop)
cleanup_dirs+=("$ROOT")
export RITE_STATE_ROOT="$ROOT"
LOCKDIR="$ROOT/.rite/state/wiki-ingest-session.lockdir"

mk_active() { bash "$FS" set --session "$1" --phase ingest --issue 1 --branch x --next n >/dev/null 2>&1; }
ago() { date -u -d "$1 ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-"$2" +"%Y-%m-%dT%H:%M:%SZ"; }
reset_lock() { rm -rf "$LOCKDIR"; }

# acquired_at is a UTC ISO8601 stamp, differs from the planted value, and is within 60s of now.
assert_fresh_acquired_at() {
  local label="$1" planted="$2" at epoch
  at=$(cat "$LOCKDIR/acquired_at" 2>/dev/null || printf '')
  assert "$label acquired_at format" "1" \
    "$(printf '%s\n' "$at" | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' || true)"
  assert "$label acquired_at replaced the planted value" "1" "$([ "$at" != "$planted" ] && echo 1 || echo 0)"
  epoch=$(parse_iso8601_to_epoch "$at")
  assert "$label acquired_at within 60s of now" "1" \
    "$([ "$epoch" -gt 0 ] && [ $(( $(date +%s) - epoch )) -le 60 ] && echo 1 || echo 0)"
}

echo "=== TC-1: free → acquire → own ==="
assert "TC-1 free" "free" "$(bash "$WIL" check --session "$SID_A")"
mk_active "$SID_A"
assert "TC-1 acquired" "acquired" "$(bash "$WIL" acquire --session "$SID_A")"
assert "TC-1 own" "own" "$(bash "$WIL" check --session "$SID_A")"
assert "TC-1 holder recorded" "$SID_A" "$(cat "$LOCKDIR/session_id")"
assert_fresh_acquired_at "TC-1" ""

echo "=== TC-2: other session while the lock is fresh → concurrent_ingest (rc 11) ==="
assert "TC-2 check held" "held" "$(bash "$WIL" check --session "$SID_B")"
rc=0; out=$(bash "$WIL" acquire --session "$SID_B" 2>/dev/null) || rc=$?
assert "TC-2 concurrent_ingest" "concurrent_ingest" "$out"
assert "TC-2 rc 11" "11" "$rc"

echo "=== TC-3: own re-acquire is idempotent ==="
assert "TC-3 re-acquire own" "acquired" "$(bash "$WIL" acquire --session "$SID_A")"

echo "=== TC-4: holder without an active flow-state keeps the lock ==="
reset_lock
rm -f "$ROOT/.rite/sessions/$SID_A.flow-state"
assert "TC-4 precondition: A has no active flow-state" "false" \
  "$(bash "$FS" get --session "$SID_A" --field active --default false 2>/dev/null)"
assert "TC-4 A acquires without an active flow" "acquired" "$(bash "$WIL" acquire --session "$SID_A")"
rc=0; out=$(bash "$WIL" acquire --session "$SID_B" 2>/dev/null) || rc=$?
assert "TC-4 B acquire → concurrent_ingest" "concurrent_ingest" "$out"
assert "TC-4 B acquire rc 11" "11" "$rc"
assert "TC-4 holder stays A" "$SID_A" "$(cat "$LOCKDIR/session_id")"
assert "TC-4 B check → held" "held" "$(bash "$WIL" check --session "$SID_B")"
mk_active "$SID_A"
bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
assert "TC-4 after A is deactivated, B check → held" "held" "$(bash "$WIL" check --session "$SID_B")"
rc=0; bash "$WIL" acquire --session "$SID_B" >/dev/null 2>&1 || rc=$?
assert "TC-4 after A is deactivated, B acquire rc 11" "11" "$rc"

echo "=== TC-5: acquired_at older than 2h → B reclaims, holder and acquired_at refreshed ==="
PAST=$(ago "3 hours" 3H)
printf '%s' "$PAST" > "$LOCKDIR/acquired_at"
assert "TC-5 check stale" "stale" "$(bash "$WIL" check --session "$SID_B")"
assert "TC-5 reclaim" "acquired_stale_reclaimed" "$(bash "$WIL" acquire --session "$SID_B")"
assert "TC-5 holder now B" "$SID_B" "$(cat "$LOCKDIR/session_id")"
assert_fresh_acquired_at "TC-5" "$PAST"

echo "=== TC-6: release only own; other's lock untouched ==="
assert "TC-6 A release skipped (B holds)" "skipped" "$(bash "$WIL" release --session "$SID_A" 2>/dev/null)"
assert "TC-6 still held by B" "$SID_B" "$(cat "$LOCKDIR/session_id")"
assert "TC-6 B release" "released" "$(bash "$WIL" release --session "$SID_B")"
assert "TC-6 free after release" "free" "$(bash "$WIL" check --session "$SID_A")"

echo "=== TC-7: release on absent lock is idempotent ==="
assert "TC-7 idempotent release" "released" "$(bash "$WIL" release --session "$SID_A")"

echo "=== TC-8: lock without acquired_at (older format) → reclaimable ==="
# The holders are active here, so only the missing / unparsable acquired_at can make them stale.
reset_lock
mk_active "$SID_A"
mk_active "$SID_B"
mkdir -p "$LOCKDIR"
printf '%s' "$SID_A" > "$LOCKDIR/session_id"
assert "TC-8 check stale" "stale" "$(bash "$WIL" check --session "$SID_B")"
assert "TC-8 reclaim" "acquired_stale_reclaimed" "$(bash "$WIL" acquire --session "$SID_B")"
assert "TC-8 holder now B" "$SID_B" "$(cat "$LOCKDIR/session_id")"
printf 'not-a-timestamp' > "$LOCKDIR/acquired_at"
assert "TC-8 unparsable acquired_at → stale" "stale" "$(bash "$WIL" check --session "$SID_A")"

echo "=== TC-9: own re-acquire refreshes acquired_at ==="
reset_lock
bash "$WIL" acquire --session "$SID_A" >/dev/null
HOUR_AGO=$(ago "1 hour" 1H)
printf '%s' "$HOUR_AGO" > "$LOCKDIR/acquired_at"
assert "TC-9 re-acquire → acquired" "acquired" "$(bash "$WIL" acquire --session "$SID_A")"
assert_fresh_acquired_at "TC-9" "$HOUR_AGO"

echo "=== TC-10: acquired_at cannot be written → ERROR, rc 1, no lockdir left ==="
nodate_stub=$(mktemp -d)
cleanup_dirs+=("$nodate_stub")
for _c in bash sh awk basename cat chmod dirname find git grep head jq \
          mkdir mktemp mv python3 rm sed sleep tail touch tr wc; do
  _p=$(command -v "$_c" 2>/dev/null) && ln -sf "$_p" "$nodate_stub/$_c"
done
printf '#!/bin/sh\nexit 1\n' > "$nodate_stub/date"
chmod +x "$nodate_stub/date"
reset_lock
err=$(mktemp); cleanup_dirs+=("$err")
rc=0; PATH="$nodate_stub" bash "$WIL" acquire --session "$SID_A" >/dev/null 2>"$err" || rc=$?
assert "TC-10 fresh acquire rc 1" "1" "$rc"
assert "TC-10 fresh acquire ERROR on stderr" "1" "$(grep -c '^ERROR' "$err" || true)"
assert "TC-10 fresh acquire leaves no lockdir" "0" "$([ -e "$LOCKDIR" ] && echo 1 || echo 0)"
mkdir -p "$LOCKDIR"
printf '%s' "$SID_B" > "$LOCKDIR/session_id"
rc=0; PATH="$nodate_stub" bash "$WIL" acquire --session "$SID_A" >/dev/null 2>"$err" || rc=$?
assert "TC-10 stale reclaim rc 1" "1" "$rc"
assert "TC-10 stale reclaim ERROR on stderr" "1" "$(grep -c '^ERROR' "$err" || true)"
assert "TC-10 stale reclaim leaves no lockdir" "0" "$([ -e "$LOCKDIR" ] && echo 1 || echo 0)"

echo "=== TC-11: env-first resolution — env outranks a differing .rite-session-id ==="
# Regression guard for the env-first precedence in _resolve_sid (no --session override path).
# Write a STALE .rite-session-id (SID_B) but make the live session SID_A via env. The no-override
# resolver MUST key the lock to env (SID_A), not the stale shared file (SID_B).
reset_lock
printf '%s' "$SID_B" > "$ROOT/.rite-session-id"   # shared file says SID_B (stale)
# Precondition only — acquire on a fresh lock returns "acquired" regardless of which sid resolves;
# the precedence guard is the holder assert on the next line.
got=$(env -u CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID="$SID_A" bash "$WIL" acquire)
assert "TC-11 acquire succeeds (precondition; precedence pinned by next assert)" "acquired" "$got"
assert "TC-11 holder is env sid (SID_A), not stale file sid (SID_B)" "$SID_A" "$(cat "$LOCKDIR/session_id")"
# env-absent fallback: with env cleared AND holder==SID_B, the no-override resolver resolves the FILE
# sid (SID_B) — proven by check==own (resolver returned SID_B == holder), not merely "held" which an
# empty resolution would also yield. This pins that the file fallback returns SID_B specifically.
reset_lock
printf '%s' "$SID_B" > "$ROOT/.rite-session-id"     # self-contained: set the file sid this block relies on
env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID bash "$WIL" acquire >/dev/null
assert "TC-11 env-absent acquire holder resolved via file sid (SID_B)" "$SID_B" "$(cat "$LOCKDIR/session_id")"
assert "TC-11 env-absent check own (resolver returned file sid SID_B == holder)" "own" "$(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID bash "$WIL" check)"

echo "=== TC-12: the lock path runs without flock on PATH ==="
# wiki-ingest-lock.sh is a mkdir lock and must not depend on flock. With flock absent from
# PATH, acquire → own → held (from another session, which proves acquired_at was recorded
# under the stub PATH) → release must all succeed.
reset_lock
noflock_stub=$(mktemp -d)
cleanup_dirs+=("$noflock_stub")
for _c in bash sh awk basename cat chmod date dirname find git grep head jq \
          mkdir mktemp mv python3 rm sed sleep tail touch tr wc; do
  _p=$(command -v "$_c" 2>/dev/null) && ln -sf "$_p" "$noflock_stub/$_c"
done
SID_NF="cccccccc-9999-9999-9999-999999999999"
nf_err=$(mktemp); cleanup_dirs+=("$nf_err")
fail_before=$FAIL
rc=0; got=$(PATH="$noflock_stub" bash "$WIL" acquire --session "$SID_NF" 2>>"$nf_err") || rc=$?
assert "TC-12 no-flock acquire → acquired" "acquired" "$got"
assert "TC-12 no-flock acquire rc 0" "0" "$rc"
assert "TC-12 no-flock check → own" "own" "$(PATH="$noflock_stub" bash "$WIL" check --session "$SID_NF" 2>>"$nf_err")"
assert "TC-12 no-flock other session check → held" "held" "$(PATH="$noflock_stub" bash "$WIL" check --session "$SID_A" 2>>"$nf_err")"
assert "TC-12 no-flock release → released" "released" "$(PATH="$noflock_stub" bash "$WIL" release --session "$SID_NF" 2>>"$nf_err")"
# Show the captured stderr when an assert failed (do not swallow the diagnosis).
if [ "$FAIL" -gt "$fail_before" ] && [ -s "$nf_err" ]; then
  head -5 "$nf_err" | sed 's/^/    stderr: /'
fi

echo "=== TC-13: wiki-ingest step 9.0 warns when the lock is no longer own ==="
step90=$(awk '
  /^### 9\.0 / { in_sec = 1; next }
  in_sec && /^##/ { exit }
  in_sec && /^```bash$/ { in_code = 1; next }
  in_sec && in_code && /^```$/ { exit }
  in_sec && in_code { print }
' "$INGEST_SKILL")
assert "TC-13 step 9.0 bash block is not empty" "1" "$([ -n "$step90" ] && echo 1 || echo 0)"
check_line=$(printf '%s\n' "$step90" | grep -n 'wiki-ingest-lock.sh" check' | head -1 | cut -d: -f1 || true)
release_line=$(printf '%s\n' "$step90" | grep -n 'wiki-ingest-lock.sh" release' | head -1 | cut -d: -f1 || true)
assert "TC-13 check runs before release" "1" \
  "$([ -n "$check_line" ] && [ -n "$release_line" ] && [ "$check_line" -lt "$release_line" ] && echo 1 || echo 0)"
step90_file=$(mktemp); cleanup_dirs+=("$step90_file")
printf '%s\n' "${step90//\{plugin_root\}/$PLUGIN_ROOT}" > "$step90_file"
run_step90() {
  local out_f="$1" err_f="$2"
  env -u CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID="$SID_A" RITE_STATE_ROOT="$ROOT" \
    bash "$step90_file" >"$out_f" 2>"$err_f"
}
s_out=$(mktemp); s_err=$(mktemp); cleanup_dirs+=("$s_out" "$s_err")
# (a) another session holds the lock
reset_lock
bash "$WIL" acquire --session "$SID_B" >/dev/null
rc=0; run_step90 "$s_out" "$s_err" || rc=$?
assert "TC-13a held by other: rc 0" "0" "$rc"
assert "TC-13a held by other: WARNING on stderr" "1" "$(grep -c '^WARNING' "$s_err" || true)"
assert "TC-13a held by other: release output skipped" "skipped" "$(cat "$s_out")"
assert "TC-13a held by other: B still holds" "$SID_B" "$(cat "$LOCKDIR/session_id")"
# (b) the lock is gone
reset_lock
rc=0; run_step90 "$s_out" "$s_err" || rc=$?
assert "TC-13b lock absent: rc 0" "0" "$rc"
assert "TC-13b lock absent: WARNING on stderr" "1" "$(grep -c '^WARNING' "$s_err" || true)"
assert "TC-13b lock absent: release output released" "released" "$(cat "$s_out")"
# (c) this session still owns the lock
bash "$WIL" acquire --session "$SID_A" >/dev/null
rc=0; run_step90 "$s_out" "$s_err" || rc=$?
assert "TC-13c own: rc 0" "0" "$rc"
assert "TC-13c own: no WARNING" "0" "$(grep -c '^WARNING' "$s_err" || true)"
assert "TC-13c own: release output released" "released" "$(cat "$s_out")"
assert "TC-13c own: lock released" "0" "$([ -e "$LOCKDIR" ] && echo 1 || echo 0)"

print_summary "$(basename "$0")" \
  "Drift hint: wiki-ingest-lock.sh §9 — mkdir lock whose liveness is its own acquired_at (2h), reclaim stale/missing/unparsable, concurrent_ingest rc 11, acquired_at write failure stops acquire; _resolve_sid env-first; no-flock PATH; wiki-ingest step 9.0 check → WARNING when not own."
