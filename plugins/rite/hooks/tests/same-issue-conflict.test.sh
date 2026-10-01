#!/bin/bash
# Tests for same-issue concurrent target — T-05 / AC-5
#
# Contract (Option C):
#   per-session file では「両 session が同一 issue_number を
#   target にしても、それぞれ独立した per-session file (`.rite/sessions/{sid}.flow-state`)
#   に書き込まれるため両方成功する」を **明示的 contract として固定** する。
#
#   per-session 構造の core value proposition (lock 不要で並行性が構造的に保証)
#   と一致する設計判断であり、SHOULD 要件「同 issue 同時 target 時の
#   明示的競合エラー reject」は別 Issue で tracking する (本 PR scope 外)。
#
# Test cases:
#   TC-1: sequential 同 issue 2 session create → 両方成功 + 独立 file (Option C)
#   TC-2: concurrent 同 issue 2 session create → 両方成功 (race-free)
#   TC-3: 同 issue patch → 各 session 独立に更新 (no field leak)
#   TC-6: contract sentence regression guard — 本ファイル冒頭の Option C 文言を pin
#
# Removed (PR 2a refactor, v3 SoT):
#   - TC-4 / TC-5: legacy schema_version=1 single-file reject/overwrite. The
#     legacy single-file path no longer exists in v3, so the "two sessions
#     targeting the same legacy file" scenario is structurally unreachable.
#
# Out of scope:
#   - per-session での明示的競合エラー (SHOULD 要件、別 Issue で tracking)
#   - concurrent-sessions.test.sh の TC-4 と相補
#
# Usage: bash plugins/rite/hooks/tests/same-issue-conflict.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../flow-state.sh"
SELF="$SCRIPT_DIR/same-issue-conflict.test.sh"
PASS=0
FAIL=0
FAILED_NAMES=()

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi

# ---- helpers ----
cleanup_dirs=()
cleanup() {
  local d
  for d in "${cleanup_dirs[@]:-}"; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
  done
  return 0
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); echo "  ❌ FAIL: $1"; }

make_test_dir() {
  local d
  d=$(mktemp -d) || { echo "ERROR: mktemp -d failed" >&2; return 1; }
  cleanup_dirs+=("$d")
  git -C "$d" init -q
  # rite-config.yml sandbox marker. flow-state is always per-session (no
  # `flow_state.schema_version` selection).
  printf '# rite test sandbox config\n' > "$d/rite-config.yml"
  echo "$d"
}

echo "=== same-issue-conflict tests (T-05 AC-5, Option C) ==="
echo ""

# -------------------------------------------------------------------------
# TC-1: sequential 同 issue 2 session create → 両方成功
# -------------------------------------------------------------------------
echo "TC-1: sequential 同 issue 2 session → 両方成功 + 独立 file (Option C)"
TD=$(make_test_dir)
ISSUE=684
SID_A="aaaaaaaa-1111-2222-3333-444455556601"
SID_B="bbbbbbbb-1111-2222-3333-444455556601"

(cd "$TD" && bash "$HOOK" set --session "$SID_A" \
  --phase "phase_a" --issue $ISSUE --branch "feat/a" --pr 0 --next "na" >/dev/null 2>&1)
(cd "$TD" && bash "$HOOK" set --session "$SID_B" \
  --phase "phase_b" --issue $ISSUE --branch "feat/b" --pr 0 --next "nb" >/dev/null 2>&1)

fa="$TD/.rite/sessions/${SID_A}.flow-state"
fb="$TD/.rite/sessions/${SID_B}.flow-state"

if [ -f "$fa" ] && [ -f "$fb" ]; then
  pass "TC-1.1: 同 issue=$ISSUE で 2 session が独立 file に共存"
else
  fail "TC-1.1: missing files: a=$([ -f "$fa" ] && echo y || echo n) b=$([ -f "$fb" ] && echo y || echo n)"
fi

# Each file must hold its own session_id and branch
if [ "$(jq -r '.issue_number' "$fa")" = "$ISSUE" ] \
    && [ "$(jq -r '.issue_number' "$fb")" = "$ISSUE" ] \
    && [ "$(jq -r '.session_id' "$fa")" = "$SID_A" ] \
    && [ "$(jq -r '.session_id' "$fb")" = "$SID_B" ] \
    && [ "$(jq -r '.branch' "$fa")" = "feat/a" ] \
    && [ "$(jq -r '.branch' "$fb")" = "feat/b" ]; then
  pass "TC-1.2: 各 file が own session_id + branch を保持 (no leak)"
else
  fail "TC-1.2: field leak detected"
fi

# -------------------------------------------------------------------------
# TC-2: concurrent 同 issue 2 session create → 両方成功
# -------------------------------------------------------------------------
# F-06 fix: barrier sync で起動 jitter を排除し true concurrent 化。
# 単純な `cmd & cmd &` で両 process を background 起動すると、bash の forked
# process startup には数十 ms の jitter があり、片方が write 完了後にもう
# 片方が start する経路で sequential 化する false negative が起こり得る
# (起動順序が決定的でないため race condition 検証としての identification
# power が dilute される)。
# canonical 防御: barrier file (`$TD/.barrier-tc2`) を pre-create し、各 child は
# `while [ -f barrier ]; do sleep 0.001; done` で busy-wait → parent が rm barrier
# して同時 release。これで両 child が ms 単位で同時起動することを保証する。
echo "TC-2: concurrent 同 issue 2 session create → race-free 両方成功"
TD=$(make_test_dir)
SID_C="cccccccc-1111-2222-3333-444455556601"
SID_D="dddddddd-1111-2222-3333-444455556601"

# F-06: pre-create barrier file before launching children
barrier_file="$TD/.barrier-tc2"
touch "$barrier_file"

(
  cd "$TD"
  while [ -f "$barrier_file" ]; do sleep 0.001; done
  bash "$HOOK" set --session "$SID_C" \
    --phase "phase_c" --issue $ISSUE --branch "feat/c" --pr 0 --next "nc" >/dev/null 2>&1
) &
PID_C=$!
(
  cd "$TD"
  while [ -f "$barrier_file" ]; do sleep 0.001; done
  bash "$HOOK" set --session "$SID_D" \
    --phase "phase_d" --issue $ISSUE --branch "feat/d" --pr 0 --next "nd" >/dev/null 2>&1
) &
PID_D=$!

# Brief wait to ensure both children have entered their barrier wait loops,
# then release the barrier — both children proceed simultaneously.
sleep 0.05
rm -f "$barrier_file"

c_rc=0; d_rc=0
wait "$PID_C" || c_rc=$?
wait "$PID_D" || d_rc=$?

fc="$TD/.rite/sessions/${SID_C}.flow-state"
fd="$TD/.rite/sessions/${SID_D}.flow-state"

if [ "$c_rc" -eq 0 ] && [ "$d_rc" -eq 0 ] && [ -f "$fc" ] && [ -f "$fd" ]; then
  pass "TC-2.1: concurrent 同 issue create rc=0 + 両 file 存在 (Option C contract)"
else
  fail "TC-2.1: c_rc=$c_rc d_rc=$d_rc fc=$([ -f "$fc" ] && echo y || echo n) fd=$([ -f "$fd" ] && echo y || echo n)"
fi

# -------------------------------------------------------------------------
# TC-3: 同 issue patch → 各 session 独立に更新 (no field leak)
# -------------------------------------------------------------------------
echo "TC-3: 同 issue patch → 独立更新 (no cross-session leak)"
TD=$(make_test_dir)
SID_E="eeeeeeee-1111-2222-3333-444455556601"
SID_F="ffffffff-1111-2222-3333-444455556601"

(cd "$TD" && bash "$HOOK" set --session "$SID_E" \
  --phase "phase_e1" --issue $ISSUE --branch "feat/e" --pr 0 --next "ne" >/dev/null 2>&1)
(cd "$TD" && bash "$HOOK" set --session "$SID_F" \
  --phase "phase_f1" --issue $ISSUE --branch "feat/f" --pr 0 --next "nf" >/dev/null 2>&1)

(cd "$TD" && bash "$HOOK" set --session "$SID_E" \
  --phase "phase_e2" --next "ne2" >/dev/null 2>&1)
(cd "$TD" && bash "$HOOK" set --session "$SID_F" \
  --phase "phase_f2" --next "nf2" >/dev/null 2>&1)

fe="$TD/.rite/sessions/${SID_E}.flow-state"
ff="$TD/.rite/sessions/${SID_F}.flow-state"
if [ "$(jq -r '.phase' "$fe")" = "phase_e2" ] \
    && [ "$(jq -r '.phase' "$ff")" = "phase_f2" ] \
    && [ "$(jq -r '.branch' "$fe")" = "feat/e" ] \
    && [ "$(jq -r '.branch' "$ff")" = "feat/f" ]; then
  pass "TC-3.1: patch で phase 独立更新 + branch field は preserve (no leak)"
else
  fail "TC-3.1: cross-session leak — e_phase=$(jq -r '.phase' "$fe") f_phase=$(jq -r '.phase' "$ff") e_branch=$(jq -r '.branch' "$fe") f_branch=$(jq -r '.branch' "$ff")"
fi

# -------------------------------------------------------------------------
# TC-4 / TC-5: removed (PR 2a refactor)
# -------------------------------------------------------------------------
# Previously verified the legacy schema_version=1 single-file reject-on-active
# contract (canonical phrase "別のワークフローが進行中です" for fresh foreign
# state + overwrite-allowed for stale state). Under v3 the legacy single-file
# path is gone — every session writes to its own `.rite/sessions/<sid>.flow-state`,
# so the "two sessions targeting the same legacy file" scenario is structurally
# unreachable. The Option C contract (TC-1..TC-3) replaces the reject behavior
# with per-session isolation.

# -------------------------------------------------------------------------
# TC-6: contract sentence regression guard
# -------------------------------------------------------------------------
# 本ファイル冒頭の Option C contract 文言を pin する。canonical phrase が
# 削除/書換された場合、誰かが contract を勝手に変更した signal として fail
# する (Wiki 経験則「Test pin protection theater」を本ファイル自身にも適用)。
echo "TC-6: Option C contract sentence pin (self-reference)"
expected_contract='両 session が同一 issue_number を'
if grep -qF -- "$expected_contract" "$SELF"; then
  pass "TC-6.1: Option C contract sentence preserved in this test file"
else
  fail "TC-6.1: contract sentence missing — Option C decision may have drifted"
fi

# -------------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------------
echo ""
echo "==============================="
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed:"
  for n in "${FAILED_NAMES[@]}"; do
    echo "  - $n"
  done
  exit 1
fi
echo "All same-issue-conflict tests passed!"
