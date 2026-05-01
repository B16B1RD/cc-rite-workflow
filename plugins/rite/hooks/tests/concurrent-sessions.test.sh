#!/bin/bash
# Tests for concurrent 2-session state independence (Issue #683 / parent #672 AC-1)
#
# Coverage:
#   - T-01       : 2 並行セッションでの state 独立性
#                  (a) sequential interleave / (b) concurrent create with wait
#                  (c) concurrent patch (independent updates) / (d) cross-session isolation
#   - T-LOCAL-1  : flake-free 100 連続実行 (concurrent create)
#
# Issue #672 の core value proposition (lock 不要で並行性が構造的に保証される) を
# verify する CRITICAL path。マルチステート (per-session file, schema_version=2)
# の上でのみ pass する設計。
#
# Out of scope (#684 で扱う):
#   - migration / atomic write integrity / cleanup / crash resume
#
# Usage: bash plugins/rite/hooks/tests/concurrent-sessions.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../flow-state-update.sh"
PASS=0
FAIL=0

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi

make_test_dir() {
  local d
  d=$(mktemp -d)
  (
    cd "$d"
    git init -q
    echo a > a && git add a
    git -c user.email=t@test.local -c user.name=test commit -q -m init
  )
  echo "$d"
}

write_config() {
  # $1=test_dir, $2=schema_version
  local d="$1" sv="$2"
  cat > "$d/rite-config.yml" << EOF
flow_state:
  schema_version: $sv
EOF
}

write_session_id() {
  echo "$2" > "$1/.rite-session-id"
}

pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ FAIL: $1"; }

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

echo "=== concurrent-sessions tests (Issue #683 / parent #672 AC-1) ==="
echo ""

# --------------------------------------------------------------------------
# TC-1: sequential interleave (両 session が独立に作成される)
# --------------------------------------------------------------------------
echo "TC-1: sequential interleave (independent per-session files)"
TD=$(make_test_dir); cleanup_dirs+=("$TD")
write_config "$TD" 2
SID_A="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01"
SID_B="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbb01"

(cd "$TD" && bash "$HOOK" create --session "$SID_A" \
  --phase "create_interview" --issue 100 --branch "test-a" --pr 0 --next "next-a" >/dev/null 2>&1)
(cd "$TD" && bash "$HOOK" create --session "$SID_B" \
  --phase "start_implementation" --issue 200 --branch "test-b" --pr 0 --next "next-b" >/dev/null 2>&1)

A="$TD/.rite/sessions/$SID_A.flow-state"
B="$TD/.rite/sessions/$SID_B.flow-state"

if [ -f "$A" ] && [ -f "$B" ]; then
  pass "両 session の per-session file が存在"
else
  fail "missing files: a=$([ -f "$A" ] && echo y || echo n) b=$([ -f "$B" ] && echo y || echo n)"
fi

if [ "$(jq -r '.phase' "$A")" = "create_interview" ] && [ "$(jq -r '.phase' "$B")" = "start_implementation" ]; then
  pass "phase が独立に保持されている"
else
  fail "phase mismatch: a=$(jq -r '.phase' "$A" 2>/dev/null) b=$(jq -r '.phase' "$B" 2>/dev/null)"
fi

if [ "$(jq -r '.issue_number' "$A")" = "100" ] && [ "$(jq -r '.issue_number' "$B")" = "200" ]; then
  pass "issue_number が独立に保持されている"
else
  fail "issue_number mismatch"
fi

if [ "$(jq -r '.session_id' "$A")" = "$SID_A" ] && [ "$(jq -r '.session_id' "$B")" = "$SID_B" ]; then
  pass "session_id が各 file に正しく書き込まれている"
else
  fail "session_id mismatch"
fi

# --------------------------------------------------------------------------
# TC-2: concurrent create — 同時起動で両 file が独立に作成される
# --------------------------------------------------------------------------
echo "TC-2: concurrent create (parallel subshells with wait)"
TD=$(make_test_dir); cleanup_dirs+=("$TD")
write_config "$TD" 2
SID_C="cccccccc-cccc-cccc-cccc-cccccccccc01"
SID_D="dddddddd-dddd-dddd-dddd-dddddddddd01"

(
  cd "$TD"
  bash "$HOOK" create --session "$SID_C" \
    --phase "phase_c" --issue 1 --branch "bc" --pr 0 --next "nc" >/dev/null 2>&1
) &
PID_C=$!
(
  cd "$TD"
  bash "$HOOK" create --session "$SID_D" \
    --phase "phase_d" --issue 2 --branch "bd" --pr 0 --next "nd" >/dev/null 2>&1
) &
PID_D=$!

wait "$PID_C" || fail "session C concurrent create failed (rc=$?)"
wait "$PID_D" || fail "session D concurrent create failed (rc=$?)"

C="$TD/.rite/sessions/$SID_C.flow-state"
D="$TD/.rite/sessions/$SID_D.flow-state"

if [ -f "$C" ] && [ -f "$D" ]; then
  pass "concurrent create で両 file が存在"
else
  fail "concurrent create: c=$([ -f "$C" ] && echo y || echo n) d=$([ -f "$D" ] && echo y || echo n)"
fi

if [ "$(jq -r '.phase' "$C")" = "phase_c" ] && [ "$(jq -r '.phase' "$D")" = "phase_d" ]; then
  pass "concurrent create で phase が独立"
else
  fail "concurrent create phase: c=$(jq -r '.phase' "$C" 2>/dev/null) d=$(jq -r '.phase' "$D" 2>/dev/null)"
fi

# --------------------------------------------------------------------------
# TC-3: concurrent patch — 一方の patch が他方の state に波及しない
# --------------------------------------------------------------------------
echo "TC-3: concurrent patch (cross-session isolation)"
TD=$(make_test_dir); cleanup_dirs+=("$TD")
write_config "$TD" 2
SID_E="eeeeeeee-eeee-eeee-eeee-eeeeeeeeee01"
SID_F="ffffffff-ffff-ffff-ffff-ffffffffff01"

# Both sessions create first
(cd "$TD" && bash "$HOOK" create --session "$SID_E" \
  --phase "phase_e1" --issue 10 --branch "be" --pr 0 --next "ne" >/dev/null 2>&1)
(cd "$TD" && bash "$HOOK" create --session "$SID_F" \
  --phase "phase_f1" --issue 20 --branch "bf" --pr 0 --next "nf" >/dev/null 2>&1)

# Then patch concurrently
(
  cd "$TD"
  bash "$HOOK" patch --session "$SID_E" \
    --phase "phase_e2" --next "ne2" >/dev/null 2>&1
) &
PID_E=$!
(
  cd "$TD"
  bash "$HOOK" patch --session "$SID_F" \
    --phase "phase_f2" --next "nf2" >/dev/null 2>&1
) &
PID_F=$!

wait "$PID_E" || fail "session E concurrent patch failed (rc=$?)"
wait "$PID_F" || fail "session F concurrent patch failed (rc=$?)"

E="$TD/.rite/sessions/$SID_E.flow-state"
F="$TD/.rite/sessions/$SID_F.flow-state"

if [ "$(jq -r '.phase' "$E")" = "phase_e2" ] && [ "$(jq -r '.phase' "$F")" = "phase_f2" ]; then
  pass "concurrent patch で各 session が独立に更新されている"
else
  fail "concurrent patch phase: e=$(jq -r '.phase' "$E" 2>/dev/null) f=$(jq -r '.phase' "$F" 2>/dev/null)"
fi

# Cross-session isolation: issue_number / branch は patch されていないので保持
if [ "$(jq -r '.issue_number' "$E")" = "10" ] && [ "$(jq -r '.issue_number' "$F")" = "20" ]; then
  pass "patch されない field (issue_number) が保持されている"
else
  fail "patch field leaked: e_issue=$(jq -r '.issue_number' "$E" 2>/dev/null) f_issue=$(jq -r '.issue_number' "$F" 2>/dev/null)"
fi

# --------------------------------------------------------------------------
# TC-4: same-issue concurrent — 両 session が同一 Issue を target にしても独立
# --------------------------------------------------------------------------
echo "TC-4: same-issue concurrent (両 session が同 Issue でも state は分離)"
TD=$(make_test_dir); cleanup_dirs+=("$TD")
write_config "$TD" 2
SID_G="11111111-1111-1111-1111-111111111101"
SID_H="22222222-2222-2222-2222-222222222201"

(
  cd "$TD"
  bash "$HOOK" create --session "$SID_G" \
    --phase "phase_g" --issue 999 --branch "bg" --pr 0 --next "ng" >/dev/null 2>&1
) &
PID_G=$!
(
  cd "$TD"
  bash "$HOOK" create --session "$SID_H" \
    --phase "phase_h" --issue 999 --branch "bh" --pr 0 --next "nh" >/dev/null 2>&1
) &
PID_H=$!
wait "$PID_G"; wait "$PID_H"

G="$TD/.rite/sessions/$SID_G.flow-state"
H="$TD/.rite/sessions/$SID_H.flow-state"
if [ -f "$G" ] && [ -f "$H" ]; then
  pass "same-issue でも 2 session が独立 file を持つ"
else
  fail "same-issue concurrent missing file"
fi
if [ "$(jq -r '.branch' "$G")" = "bg" ] && [ "$(jq -r '.branch' "$H")" = "bh" ]; then
  pass "same-issue でも branch field は session ごとに独立"
else
  fail "same-issue branch leaked"
fi

# --------------------------------------------------------------------------
# T-LOCAL-1: flake-free 100 iterations of concurrent create
# Issue #683 AC-LOCAL-1: 並行性テストが新形式 hook 群で 100% pass (10 連続実行で flake 0)
# 10 連続が AC だが、より強い保証として 100 連続を採用
# --------------------------------------------------------------------------
echo "T-LOCAL-1: 100 iteration flake-free check (concurrent create)"
ITERATIONS=100
flake=0
TD=$(make_test_dir); cleanup_dirs+=("$TD")
write_config "$TD" 2

# Each iteration uses fresh session UUIDs to avoid file reuse interference.
for i in $(seq 1 "$ITERATIONS"); do
  hex_i=$(printf "%012x" "$i")
  SID_X="aaaaaaaa-aaaa-aaaa-aaaa-${hex_i}"
  SID_Y="bbbbbbbb-bbbb-bbbb-bbbb-${hex_i}"
  (
    cd "$TD"
    bash "$HOOK" create --session "$SID_X" \
      --phase "px_$i" --issue "$i" --branch "bx_$i" --pr 0 --next "nx" >/dev/null 2>&1
  ) &
  pid_x=$!
  (
    cd "$TD"
    bash "$HOOK" create --session "$SID_Y" \
      --phase "py_$i" --issue "$i" --branch "by_$i" --pr 0 --next "ny" >/dev/null 2>&1
  ) &
  pid_y=$!
  wait "$pid_x" || { flake=$((flake + 1)); continue; }
  wait "$pid_y" || { flake=$((flake + 1)); continue; }

  fx="$TD/.rite/sessions/$SID_X.flow-state"
  fy="$TD/.rite/sessions/$SID_Y.flow-state"
  if [ ! -f "$fx" ] || [ ! -f "$fy" ]; then
    flake=$((flake + 1))
    continue
  fi
  px=$(jq -r '.phase' "$fx" 2>/dev/null || echo "")
  py=$(jq -r '.phase' "$fy" 2>/dev/null || echo "")
  if [ "$px" != "px_$i" ] || [ "$py" != "py_$i" ]; then
    flake=$((flake + 1))
    continue
  fi
done

if [ "$flake" -eq 0 ]; then
  pass "100 iteration concurrent create: flake=0 (構造的並行性保証 verified)"
else
  fail "100 iteration concurrent create: flake=$flake / 100"
fi

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo ""
echo "==============================="
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
