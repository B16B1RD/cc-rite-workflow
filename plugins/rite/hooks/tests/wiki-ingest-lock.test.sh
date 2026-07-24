#!/bin/bash
# Tests for wiki-ingest-lock.sh (multi-session design §9).
#
# Verifies the ingest session lock used to serialize the LLM Write/Edit phase
# across sessions:
#   AC-3: a second session whose holder is LIVE is told concurrent_ingest (rc 11)
#   stale (holder inactive / >2h) → reclaimable
#   release removes only the OWN lock; idempotent on absent lock (AC-4 parity)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

WIL="$SCRIPT_DIR/../scripts/wiki-ingest-lock.sh"
FS="$SCRIPT_DIR/../flow-state.sh"
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

echo "=== TC-1: free → acquire → own ==="
assert "TC-1 free" "free" "$(bash "$WIL" check --session "$SID_A")"
mk_active "$SID_A"
assert "TC-1 acquired" "acquired" "$(bash "$WIL" acquire --session "$SID_A")"
assert "TC-1 own" "own" "$(bash "$WIL" check --session "$SID_A")"
assert "TC-1 holder recorded" "$SID_A" "$(cat "$LOCKDIR/session_id")"

echo "=== TC-2 (AC-3): live other session → concurrent_ingest (rc 11) ==="
assert "TC-2 check held" "held" "$(bash "$WIL" check --session "$SID_B")"
rc=0; out=$(bash "$WIL" acquire --session "$SID_B" 2>/dev/null) || rc=$?
assert "TC-2 concurrent_ingest" "concurrent_ingest" "$out"
assert "TC-2 rc 11" "11" "$rc"

echo "=== TC-3: own re-acquire is idempotent ==="
assert "TC-3 re-acquire own" "acquired" "$(bash "$WIL" acquire --session "$SID_A")"

echo "=== TC-4: stale holder (inactive) → reclaimable ==="
bash "$FS" deactivate --session "$SID_A" --next done >/dev/null 2>&1
assert "TC-4 stale" "stale" "$(bash "$WIL" check --session "$SID_B")"
assert "TC-4 reclaim" "acquired_stale_reclaimed" "$(bash "$WIL" acquire --session "$SID_B")"
assert "TC-4 holder now B" "$SID_B" "$(cat "$LOCKDIR/session_id")"

echo "=== TC-5: release only own; other's lock untouched ==="
assert "TC-5 A release skipped (B holds)" "skipped" "$(bash "$WIL" release --session "$SID_A")"
assert "TC-5 still held by B" "$SID_B" "$(cat "$LOCKDIR/session_id")"
assert "TC-5 B release" "released" "$(bash "$WIL" release --session "$SID_B")"
assert "TC-5 free after release" "free" "$(bash "$WIL" check --session "$SID_A")"

echo "=== TC-6: release on absent lock is idempotent ==="
assert "TC-6 idempotent release" "released" "$(bash "$WIL" release --session "$SID_A")"

echo "=== TC-7: holder updated_at > 2h → stale ==="
mk_active "$SID_A"
bash "$WIL" acquire --session "$SID_A" >/dev/null
PAST=$(date -u -d '3 hours ago' +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-3H +"%Y-%m-%dT%H:%M:%SZ")
tmp=$(mktemp); jq --arg t "$PAST" '.updated_at=$t' "$ROOT/.rite/sessions/$SID_A.flow-state" > "$tmp" && mv "$tmp" "$ROOT/.rite/sessions/$SID_A.flow-state"
assert "TC-7 stale (2h aged)" "stale" "$(bash "$WIL" check --session "$SID_B")"

echo "=== TC-8 (Issue #1530): env-first resolution — env outranks a differing .rite-session-id ==="
# Regression guard for the env-first precedence flip in _resolve_sid (no --session override path).
# Write a STALE .rite-session-id (SID_B) but make the live session SID_A via env. The no-override
# resolver MUST key the lock to env (SID_A), not the stale shared file (SID_B) — this is the
# cross-component coherence the half-migration finding (Issue #1530 review) flagged.
bash "$WIL" release --session "$SID_A" >/dev/null 2>&1 || true
rm -rf "$LOCKDIR" 2>/dev/null || true
printf '%s' "$SID_B" > "$ROOT/.rite-session-id"   # shared file says SID_B (stale)
mk_active "$SID_A"                                  # but env session SID_A is the live one
# Precondition only — acquire on a fresh lock returns "acquired" regardless of which sid resolves;
# the precedence guard is the holder assert on the next line.
got=$(env -u CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID="$SID_A" bash "$WIL" acquire)
assert "TC-8 acquire succeeds (precondition; precedence pinned by next assert)" "acquired" "$got"
assert "TC-8 holder is env sid (SID_A), not stale file sid (SID_B)" "$SID_A" "$(cat "$LOCKDIR/session_id")"
# env-absent fallback: with env cleared AND holder==SID_B, the no-override resolver resolves the FILE
# sid (SID_B) — proven by check==own (resolver returned SID_B == holder), not merely "held" which an
# empty resolution would also yield. This pins that the file fallback returns SID_B specifically.
bash "$WIL" release --session "$SID_A" >/dev/null 2>&1 || true
rm -rf "$LOCKDIR" 2>/dev/null || true
printf '%s' "$SID_B" > "$ROOT/.rite-session-id"     # self-contained: set the file sid this block relies on
mk_active "$SID_B"                                  # holder SID_B; file SID_B (set just above)
env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID bash "$WIL" acquire >/dev/null
assert "TC-8 env-absent acquire holder resolved via file sid (SID_B)" "$SID_B" "$(cat "$LOCKDIR/session_id")"
assert "TC-8 env-absent check own (resolver returned file sid SID_B == holder)" "own" "$(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID bash "$WIL" check)"

echo "=== TC-9 (Issue #1999 / T-03 / AC-3): flock 不在 PATH でロック経路が続行する ==="
# wiki-ingest-lock.sh 自体は mkdir ロックで flock を呼ばないが、liveness 判定が
# flow-state.sh get/set を経由するため、flock 不在環境で set→acquire→check→release の
# 全経路がエラー終了せず続行することを PATH スタブで固定する（issue-claim.test.sh
# TC-16 と同じスタブ方式）。判別は locale 非依存の 2 assert で行う:
#   (1) no-flock `set` の rc を直接 assert（degrade が壊れると rc 非 0）
#   (2) 別セッションからの check が `held` を返すことを assert — holder SID_NF の
#       liveness 判定が flow-state get を経由するため、state 書込が失敗していれば
#       `stale` になり検出できる（TC-2/TC-4 と同じ挙動の再利用）
# エラーメッセージ文字列の grep は locale 依存（非英語 locale では bash がローカライズ
# 済みメッセージを出す）のため判別に使わない。probe は write 経路（set）を SID_NF とは
# 別の probe 専用 sid で行い、環境起因の setup gap を degrade 不具合と誤判定せず、
# かつ probe の flock あり書込が SID_NF の liveness 判定を汚染しないようにする。
bash "$WIL" release --session "$SID_B" >/dev/null 2>&1 || true
rm -rf "$LOCKDIR" 2>/dev/null || true
noflock_stub=$(mktemp -d)
cleanup_dirs+=("$noflock_stub")
for _c in bash sh awk basename cat chmod date dirname find git grep head jq \
          mkdir mktemp mv rm sed sleep tail touch tr wc; do
  _p=$(command -v "$_c" 2>/dev/null) && ln -sf "$_p" "$noflock_stub/$_c"
done
SID_NF="cccccccc-9999-9999-9999-999999999999"
SID_PROBE="dddddddd-9999-9999-9999-999999999999"
_flock_path=$(command -v flock 2>/dev/null) || _flock_path=""
probe_ok=1
if [ -n "$_flock_path" ]; then
  ln -sf "$_flock_path" "$noflock_stub/flock"
  if ! PATH="$noflock_stub" bash "$FS" set --session "$SID_PROBE" --phase ingest --issue 1 --branch x --next n >/dev/null 2>&1; then
    probe_ok=0
  fi
  rm -f "$noflock_stub/flock"
fi
if [ "$probe_ok" -eq 0 ]; then
  pass "TC-9 skipped: PATH スタブがこのホストで set を実行できない (環境起因の setup gap)"
else
  nf_err=$(mktemp)
  fail_before=$FAIL
  set_rc=0
  PATH="$noflock_stub" bash "$FS" set --session "$SID_NF" --phase ingest --issue 1 --branch x --next n \
    >/dev/null 2>>"$nf_err" || set_rc=$?
  assert "TC-9 no-flock flow-state set rc 0" "0" "$set_rc"
  rc=0; got=$(PATH="$noflock_stub" bash "$WIL" acquire --session "$SID_NF" 2>>"$nf_err") || rc=$?
  assert "TC-9 no-flock acquire → acquired" "acquired" "$got"
  assert "TC-9 no-flock acquire rc 0" "0" "$rc"
  assert "TC-9 no-flock check → own" "own" "$(PATH="$noflock_stub" bash "$WIL" check --session "$SID_NF" 2>>"$nf_err")"
  assert "TC-9 no-flock 別セッション check → held (state 書込が liveness 判定に到達)" "held" "$(PATH="$noflock_stub" bash "$WIL" check --session "$SID_A" 2>>"$nf_err")"
  assert "TC-9 no-flock release → released" "released" "$(PATH="$noflock_stub" bash "$WIL" release --session "$SID_NF" 2>>"$nf_err")"
  # assert 失敗時は捕捉済み stderr を表示してから削除する（診断の握り潰し防止、TC-6 の
  # err_file 表示と対称）
  if [ "$FAIL" -gt "$fail_before" ] && [ -s "$nf_err" ]; then
    head -5 "$nf_err" | sed 's/^/    stderr: /'
  fi
  rm -f "$nf_err"
fi

print_summary "$(basename "$0")" \
  "Drift hint: wiki-ingest-lock.sh §9 — mkdir lock with session-flow-state liveness (2h), reclaim stale, concurrent_ingest rc 11; _resolve_sid env-first (Issue #1530); no-flock PATH degrade continuation (Issue #1999)."
