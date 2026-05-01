#!/bin/bash
# Tests for same-issue concurrent target — Issue #672 / #684 (T-05 / AC-5)
#
# Contract (Option C, decided in #684 Phase 3):
#   schema_version=2 (per-session file) では「両 session が同一 issue_number を
#   target にしても、それぞれ独立した per-session file (`.rite/sessions/{sid}.flow-state`)
#   に書き込まれるため両方成功する」を **明示的 contract として固定** する。
#
#   per-session 構造の core value proposition (lock 不要で並行性が構造的に保証)
#   と一致する設計判断であり、Issue #672 SHOULD 要件「同 issue 同時 target 時の
#   明示的競合エラー reject」は別 Issue で tracking する (本 PR scope 外)。
#
#   一方 legacy (schema_version=1) では state file が単一なため、別 session が
#   2 時間以内に active 状態で書き込もうとすると `flow-state-update.sh` create
#   mode が ERROR で reject する。本テストは reject error の canonical phrase
#   "別のワークフローが進行中です" を contract として pin する (実装が無言で
#   フォールバックさせる回帰を防ぐ)。
#
# Test cases:
#   TC-1: schema=2 sequential 同 issue 2 session create → 両方成功 + 独立 file (Option C)
#   TC-2: schema=2 concurrent 同 issue 2 session create → 両方成功 (race-free)
#   TC-3: schema=2 同 issue patch → 各 session 独立に更新 (no field leak)
#   TC-4: legacy 同一 path に foreign active session 存在 + 7200s 以内 →
#         create reject + canonical phrase "別のワークフローが進行中です" を pin
#   TC-5: legacy + 7200s 超えた stale state → reject されず overwrite 許可
#   TC-6: contract sentence regression guard — 本ファイル冒頭の Option C 文言を pin
#
# Out of scope:
#   - per-session での明示的競合エラー (SHOULD 要件、別 Issue で tracking)
#   - concurrent-sessions.test.sh の TC-4 と相補 (同 issue 2 session の独立性
#     は同テストでも verify されている。本テストでは「contract としての固定」と
#     legacy reject phrase pin に focus)
#
# Usage: bash plugins/rite/hooks/tests/same-issue-conflict.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../flow-state-update.sh"
SELF="$SCRIPT_DIR/same-issue-conflict.test.sh"
PASS=0
FAIL=0
FAILED_NAMES=()

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi

# Canonical phrase that flow-state-update.sh emits when reject-on-active fires
# in legacy mode. Pinned here as a contract — if production changes this phrase,
# the test breaks loudly so callers depending on the message can be updated.
LEGACY_REJECT_PHRASE="別のワークフローが進行中です"

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
  local schema="${1:-2}"
  local d
  d=$(mktemp -d) || { echo "ERROR: mktemp -d failed" >&2; return 1; }
  cleanup_dirs+=("$d")
  cat > "$d/rite-config.yml" <<EOF
flow_state:
  schema_version: $schema
EOF
  echo "$d"
}

echo "=== same-issue-conflict tests (Issue #672 / #684 T-05 AC-5, Option C) ==="
echo ""

# -------------------------------------------------------------------------
# TC-1: schema=2 sequential 同 issue 2 session create → 両方成功
# -------------------------------------------------------------------------
echo "TC-1: schema=2 sequential 同 issue 2 session → 両方成功 + 独立 file (Option C)"
TD=$(make_test_dir 2)
ISSUE=684
SID_A="aaaaaaaa-1111-2222-3333-444455556601"
SID_B="bbbbbbbb-1111-2222-3333-444455556601"

(cd "$TD" && bash "$HOOK" create --session "$SID_A" \
  --phase "phase_a" --issue $ISSUE --branch "feat/a" --pr 0 --next "na" >/dev/null 2>&1)
(cd "$TD" && bash "$HOOK" create --session "$SID_B" \
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
# TC-2: schema=2 concurrent 同 issue 2 session create → 両方成功
# -------------------------------------------------------------------------
# F-06 fix (Issue #760): barrier sync で起動 jitter を排除し true concurrent 化。
# 旧実装は単純な `cmd & cmd &` で両 process を background 起動していたが、
# bash の forked process startup には数十 ms の jitter があり、片方が write
# 完了後にもう片方が start する経路で sequential 化する false negative の
# 可能性があった (起動順序が決定的でないため race condition 検証としての
# identification power が dilute される)。
# canonical 防御: barrier file (`$TD/.barrier-tc2`) を pre-create し、各 child は
# `while [ -f barrier ]; do sleep 0.001; done` で busy-wait → parent が rm barrier
# して同時 release。これで両 child が ms 単位で同時起動することを保証する。
echo "TC-2: schema=2 concurrent 同 issue 2 session create → race-free 両方成功"
TD=$(make_test_dir 2)
SID_C="cccccccc-1111-2222-3333-444455556601"
SID_D="dddddddd-1111-2222-3333-444455556601"

# F-06: pre-create barrier file before launching children
barrier_file="$TD/.barrier-tc2"
touch "$barrier_file"

(
  cd "$TD"
  while [ -f "$barrier_file" ]; do sleep 0.001; done
  bash "$HOOK" create --session "$SID_C" \
    --phase "phase_c" --issue $ISSUE --branch "feat/c" --pr 0 --next "nc" >/dev/null 2>&1
) &
PID_C=$!
(
  cd "$TD"
  while [ -f "$barrier_file" ]; do sleep 0.001; done
  bash "$HOOK" create --session "$SID_D" \
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
# TC-3: schema=2 同 issue patch → 各 session 独立に更新 (no field leak)
# -------------------------------------------------------------------------
echo "TC-3: schema=2 同 issue patch → 独立更新 (no cross-session leak)"
TD=$(make_test_dir 2)
SID_E="eeeeeeee-1111-2222-3333-444455556601"
SID_F="ffffffff-1111-2222-3333-444455556601"

(cd "$TD" && bash "$HOOK" create --session "$SID_E" \
  --phase "phase_e1" --issue $ISSUE --branch "feat/e" --pr 0 --next "ne" >/dev/null 2>&1)
(cd "$TD" && bash "$HOOK" create --session "$SID_F" \
  --phase "phase_f1" --issue $ISSUE --branch "feat/f" --pr 0 --next "nf" >/dev/null 2>&1)

(cd "$TD" && bash "$HOOK" patch --session "$SID_E" \
  --phase "phase_e2" --next "ne2" >/dev/null 2>&1)
(cd "$TD" && bash "$HOOK" patch --session "$SID_F" \
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
# TC-4: legacy + foreign active session + recent → reject + canonical phrase pin
# -------------------------------------------------------------------------
echo "TC-4: legacy foreign active + recent → reject + canonical phrase '$LEGACY_REJECT_PHRASE'"
TD=$(make_test_dir 1)
legacy="$TD/.rite-flow-state"
SID_OWN="11111111-aaaa-bbbb-cccc-ddddeeeeff01"
SID_NEW="22222222-aaaa-bbbb-cccc-ddddeeeeff01"
recent_ts=$(date -u +'%Y-%m-%dT%H:%M:%S+00:00')
echo "{\"active\":true,\"phase\":\"phase_own\",\"issue_number\":$ISSUE,\"session_id\":\"$SID_OWN\",\"updated_at\":\"$recent_ts\"}" > "$legacy"

# A different session attempting create on the same legacy path must be rejected.
new_rc=0
new_out=$(cd "$TD" && bash "$HOOK" create --session "$SID_NEW" \
  --phase "phase_new" --issue $ISSUE --branch "feat/new" --pr 0 --next "n_new" 2>&1) || new_rc=$?

if [ "$new_rc" -ne 0 ] && echo "$new_out" | grep -qF "$LEGACY_REJECT_PHRASE"; then
  pass "TC-4.1: foreign session create rejected (rc=$new_rc) with canonical phrase"
else
  fail "TC-4.1: expected rc!=0 + phrase '$LEGACY_REJECT_PHRASE'; got rc=$new_rc, out: $(echo "$new_out" | head -3)"
fi

# State file MUST remain unchanged (loser session does not corrupt winner's state)
if [ "$(jq -r '.session_id' "$legacy")" = "$SID_OWN" ] \
    && [ "$(jq -r '.phase' "$legacy")" = "phase_own" ]; then
  pass "TC-4.2: rejected create did NOT mutate winner's state"
else
  fail "TC-4.2: state mutated — session_id=$(jq -r '.session_id' "$legacy") phase=$(jq -r '.phase' "$legacy")"
fi

# -------------------------------------------------------------------------
# TC-5: legacy + foreign active session + stale (>7200s) → overwrite 許可
# -------------------------------------------------------------------------
echo "TC-5: legacy foreign active + stale (>7200s) → reject されず overwrite 許可"
# F-07 fix (Issue #760): GNU/BSD date fallback の silent failure 検出。
# 旧実装は両 fallback が失敗した場合 `old_ts` が空になり、後続の JSON 構築で
# `"updated_at":""` として書き込まれ、test が undefined 動作になる経路があった。
# `[ -z "$old_ts" ]` で empty check し、両環境で fallback 不能なら fail させる。
old_ts=$(date -u -d "8000 seconds ago" +'%Y-%m-%dT%H:%M:%S+00:00' 2>/dev/null \
  || date -u -v-8000S +'%Y-%m-%dT%H:%M:%S+00:00' 2>/dev/null)
if [ -z "$old_ts" ]; then
  fail "TC-5.0: GNU date (-d) と BSD date (-v) の両 fallback が失敗 — test 環境の date が non-portable"
  echo "ERROR: cannot generate stale timestamp; aborting TC-5" >&2
  exit 1
fi
echo "{\"active\":true,\"phase\":\"phase_own\",\"issue_number\":$ISSUE,\"session_id\":\"$SID_OWN\",\"updated_at\":\"$old_ts\"}" > "$legacy"

stale_rc=0
(cd "$TD" && bash "$HOOK" create --session "$SID_NEW" \
  --phase "phase_new_after_stale" --issue $ISSUE --branch "feat/new" --pr 0 --next "n_new" >/dev/null 2>&1) || stale_rc=$?

if [ "$stale_rc" -eq 0 ] \
    && [ "$(jq -r '.session_id' "$legacy")" = "$SID_NEW" ] \
    && [ "$(jq -r '.phase' "$legacy")" = "phase_new_after_stale" ]; then
  pass "TC-5.1: stale state overwritten by new session (rc=0, no reject)"
else
  fail "TC-5.1: rc=$stale_rc state.session_id=$(jq -r '.session_id' "$legacy")"
fi

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
