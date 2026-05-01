#!/bin/bash
# Tests for crash resume — Issue #672 / #684 (T-03 / AC-3)
#
# Purpose:
#   Process crash 後の state resume 可能性を verify する。flow-state-update.sh は
#   `mktemp ${FLOW_STATE}.XXXXXX` → 書込 → `mv` の atomic write pattern を採るため、
#   write 中に SIGKILL されても state file 本体は (a) 直前の整合状態を保持するか
#   (b) ENOENT のいずれかであり、partial-write は構造的に不在となる。本テストは
#   その invariant を per-session file (schema_version=2) と legacy (schema_version=1)
#   両経路で empirical 検証する。
#
# Test cases:
#   TC-1: write 中 SIGKILL → state file 整合 (jq parse 成功 or ENOENT)、partial-write 不在
#   TC-2: active=true の state を pre-place → state-read.sh で resume 用 fields (active /
#         phase / issue_number / branch) が読み出せる
#   TC-3: per-session file 構造で session A SIGKILL 中に session B が独立に create 可能
#         (兄弟 session blast radius なし)
#   TC-4: legacy mode (schema_version=1) でも crash resume invariant が成立
#   TC-5: stale tempfile (`${FLOW_STATE}.XXXXXX`) は filesystem に残るが、state file 本体
#         には流入しない (atomic property の structural guarantee)
#
# Out of scope (他テストでカバー):
#   - atomic write の trap 周り → flow-state-update-trap-isolation.test.sh
#   - tempfile の stale cleanup → session-end.test.sh TC-009 / TC-010
#   - migration の crash resume → migrate-flow-state.test.sh TC-10
#
# Usage: bash plugins/rite/hooks/tests/crash-resume.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../flow-state-update.sh"
STATE_READ="$SCRIPT_DIR/../state-read.sh"
PASS=0
FAIL=0
FAILED_NAMES=()

# Outcome classifier helper (F-02 fix): SIGKILL race window probe で「kill が write
# 中に landed した iter (mid_or_temp)」「kill が write 完了後の iter (post)」「kill が
# write 開始前の iter (pre = ENOENT)」を区別する。pre しか観測できないと
# atomic invariant 検証が dead code 化するため、各 ファイルで mid_or_temp + post >= 1 を
# assert することで race window が実際に当たっていることを保証する (review F-02)。
classify_outcome() {
  local f="$1"
  local dir
  dir=$(dirname "$f")
  if [ -e "$f" ]; then
    if jq empty "$f" 2>/dev/null; then
      echo "post"
    else
      echo "corrupt"  # partial-write detected (must be 0)
    fi
  else
    # Tempfile present? mid_or_temp; otherwise pre
    if compgen -G "${f}.*" >/dev/null 2>&1; then
      echo "mid_or_temp"
    else
      echo "pre"
    fi
  fi
}

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

# Look up the state file path for a given (test_dir, session_id, schema).
state_path() {
  local d="$1" sid="$2" schema="${3:-2}"
  if [ "$schema" = "2" ]; then
    echo "$d/.rite/sessions/${sid}.flow-state"
  else
    echo "$d/.rite-flow-state"
  fi
}

# Detect partial-write artefacts in the state directory. Atomic property
# guarantees that the state file is either (a) the previous integral content
# or (b) absent — never a half-written JSON. Tempfiles (`*.flow-state.XXXXXX`,
# `*.tmp.*`) may exist; they are intentional intermediate state, not corruption.
state_file_is_integral() {
  local f="$1"
  if [ ! -e "$f" ]; then
    return 0  # ENOENT is acceptable per atomic invariant
  fi
  # File exists → must parse cleanly. partial-write would fail jq.
  jq empty "$f" >/dev/null 2>&1
}

echo "=== crash-resume tests (Issue #672 / #684 T-03 AC-3) ==="
echo ""

# -------------------------------------------------------------------------
# TC-1: write 中 SIGKILL → state file 整合 (jq parse 成功 or ENOENT)
# -------------------------------------------------------------------------
# 戦略: flow-state-update.sh を background で起動し、sleep で write 中の race
# window を狙って SIGKILL する。50 iteration 回し、state file が常に integral
# (jq parse 成功 or ENOENT) であることを verify。partial-write は構造的にあり
# 得ないため flake は 0 でなければならない。
#
# F-02 fix: race window probe の identification power を確保するため、(a)
# sleep を 0.003 から 0.05 に拡大して mid_or_temp / post 状態が確実に観測
# されるようにし、(b) iteration outcome を classify_outcome で 4 状態
# (pre / mid_or_temp / post / corrupt) に分類、(c) 「mid_or_temp + post >= 1」
# を assert することで race window が実際に当たったことを実証する (旧実装は
# 全 50 iter pre のみで PASS する経路があり、production の mv が破壊的に退化
# しても false positive で PASS していた)。さらに (d) 末尾に kill しない
# wait iter を 1 回追加し、jq empty が dead code でないことも mechanical に
# 通す。
echo "TC-1: write 中 SIGKILL → state file 整合 (atomic invariant + race window 実証)"
TD=$(make_test_dir 2)
SID="aabbccdd-eeff-0011-2233-445566778899"
ITERATIONS=50
flake_partial=0
pre_count=0
mid_or_temp_count=0
post_count=0

for i in $(seq 1 "$ITERATIONS"); do
  (
    cd "$TD"
    bash "$HOOK" create --session "$SID" \
      --phase "phase_${i}" --issue 684 --branch "feat/iter-${i}" --pr 0 --next "n${i}" >/dev/null 2>&1
  ) &
  pid=$!
  sleep 0.05  # F-02: 0.003 → 0.05 に拡大して race window probe を実証
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  state_file=$(state_path "$TD" "$SID" 2)
  outcome=$(classify_outcome "$state_file")
  case "$outcome" in
    pre)         pre_count=$((pre_count + 1)) ;;
    mid_or_temp) mid_or_temp_count=$((mid_or_temp_count + 1)) ;;
    post)        post_count=$((post_count + 1)) ;;
    corrupt)     flake_partial=$((flake_partial + 1)) ;;
  esac
done

if [ "$flake_partial" -eq 0 ]; then
  pass "TC-1.1: ${ITERATIONS} iter all integral (partial-write=0)"
else
  fail "TC-1.1: partial-write detected ${flake_partial}/${ITERATIONS} iter"
fi

# F-02 fix: race window が実際に当たったことを assert (mid_or_temp + post >= 1)
# pre のみで PASS する false positive 経路を遮断する
race_hit=$((mid_or_temp_count + post_count))
if [ "$race_hit" -ge 1 ]; then
  pass "TC-1.2: race window hit ${race_hit}/${ITERATIONS} (pre=$pre_count mid_or_temp=$mid_or_temp_count post=$post_count) — atomic invariant 検証が dead code でない"
else
  fail "TC-1.2: race window 全 miss (pre=$pre_count) — sleep が短すぎ、test が dead code 化している"
fi

# F-02 fix: 末尾に kill しない 1 iter を追加し、jq empty 経路を mechanical に通す
# (旧実装のコメント line 105-107 で謳いつつ未実装だった意図を実装化)
(cd "$TD" && bash "$HOOK" create --session "$SID" \
  --phase "phase_final" --issue 684 --branch "feat/final" --pr 0 --next "nfinal" >/dev/null 2>&1)
state_file=$(state_path "$TD" "$SID" 2)
if [ -f "$state_file" ] && jq empty "$state_file" 2>/dev/null; then
  pass "TC-1.3: kill しない iter で state file integral (jq empty 経路を mechanical に通過)"
else
  fail "TC-1.3: kill しない iter で state file が integral でない"
fi

# -------------------------------------------------------------------------
# TC-2: active=true state を pre-place → resume 用 fields が読み出せる
# -------------------------------------------------------------------------
echo "TC-2: pre-placed active state → resume fields readable"
TD=$(make_test_dir 2)
SID="11223344-5566-7788-99aa-bbccddeeff00"
state_file=$(state_path "$TD" "$SID" 2)

# state-read.sh resolves session_id from `.rite-session-id` when no --session is
# passed. Pre-place the file so a fresh process can locate the per-session state.
echo "$SID" > "$TD/.rite-session-id"

(
  cd "$TD"
  bash "$HOOK" create --session "$SID" \
    --phase "phase5_lint" --issue 684 --branch "feat/issue-684-test" --pr 0 \
    --next "Resume from phase5_lint" >/dev/null 2>&1
)

if [ ! -f "$state_file" ]; then
  fail "TC-2.1: state file missing after create"
else
  # state-read.sh per-session resolution check (uses .rite-session-id for SID)
  active_v=$(cd "$TD" && bash "$STATE_READ" --field active --default "false" 2>/dev/null)
  phase_v=$(cd "$TD" && bash "$STATE_READ" --field phase --default "" 2>/dev/null)
  issue_v=$(cd "$TD" && bash "$STATE_READ" --field issue_number --default "0" 2>/dev/null)
  branch_v=$(cd "$TD" && bash "$STATE_READ" --field branch --default "" 2>/dev/null)
  if [ "$active_v" = "true" ] && [ "$phase_v" = "phase5_lint" ] \
      && [ "$issue_v" = "684" ] && [ "$branch_v" = "feat/issue-684-test" ]; then
    pass "TC-2.1: state-read.sh restored active/phase/issue/branch correctly (resume path)"
  else
    fail "TC-2.1: resume read mismatch — active=$active_v phase=$phase_v issue=$issue_v branch=$branch_v"
  fi
fi

# -------------------------------------------------------------------------
# TC-3: per-session file → session A SIGKILL 中に session B 独立 create 可能
# -------------------------------------------------------------------------
echo "TC-3: session A SIGKILL → session B 独立 create (兄弟 blast radius なし)"
TD=$(make_test_dir 2)
SID_A="aaaa1111-2222-3333-4444-555566667777"
SID_B="bbbb1111-2222-3333-4444-555566667777"

# Launch A in background, kill mid-write (sleep 0.05: F-02 expanded race window)
(
  cd "$TD"
  bash "$HOOK" create --session "$SID_A" \
    --phase "phaseA" --issue 684 --branch "fa" --pr 0 --next "na" >/dev/null 2>&1
) &
pid_a=$!
sleep 0.05
kill -KILL "$pid_a" 2>/dev/null || true
wait "$pid_a" 2>/dev/null || true

# Now launch B and assert it succeeds independently
b_rc=0
(cd "$TD" && bash "$HOOK" create --session "$SID_B" \
  --phase "phaseB" --issue 684 --branch "fb" --pr 0 --next "nb" >/dev/null 2>&1) || b_rc=$?

state_b=$(state_path "$TD" "$SID_B" 2)
if [ "$b_rc" -eq 0 ] && [ -f "$state_b" ] && [ "$(jq -r '.phase' "$state_b")" = "phaseB" ]; then
  pass "TC-3.1: session B create succeeded after session A SIGKILL"
else
  fail "TC-3.1: session B create failed — rc=$b_rc state_b_exists=$([ -f "$state_b" ] && echo y || echo n)"
fi

# Verify session A's file (if it exists) is integral — partial-write guard
state_a=$(state_path "$TD" "$SID_A" 2)
if state_file_is_integral "$state_a"; then
  pass "TC-3.2: session A state file is integral (jq parse ok or ENOENT)"
else
  fail "TC-3.2: session A state file corrupted by SIGKILL"
fi

# -------------------------------------------------------------------------
# TC-4: legacy mode (schema_version=1) でも crash resume invariant 成立
# -------------------------------------------------------------------------
echo "TC-4: legacy mode crash resume invariant + race window 実証"
TD=$(make_test_dir 1)
state_file_legacy="$TD/.rite-flow-state"
flake_legacy=0
LEGACY_ITERS=30
legacy_pre=0
legacy_mid=0
legacy_post=0

for i in $(seq 1 "$LEGACY_ITERS"); do
  (
    cd "$TD"
    bash "$HOOK" create \
      --phase "phaseL_${i}" --issue 684 --branch "feat/legacy-${i}" --pr 0 --next "nL${i}" >/dev/null 2>&1
  ) &
  pid=$!
  sleep 0.05  # F-02: 0.005 → 0.05
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  outcome=$(classify_outcome "$state_file_legacy")
  case "$outcome" in
    pre)         legacy_pre=$((legacy_pre + 1)) ;;
    mid_or_temp) legacy_mid=$((legacy_mid + 1)) ;;
    post)        legacy_post=$((legacy_post + 1)) ;;
    corrupt)     flake_legacy=$((flake_legacy + 1)) ;;
  esac
done

if [ "$flake_legacy" -eq 0 ]; then
  pass "TC-4.1: legacy ${LEGACY_ITERS} iter all integral (partial-write=0)"
else
  fail "TC-4.1: legacy partial-write detected ${flake_legacy}/${LEGACY_ITERS}"
fi

legacy_race_hit=$((legacy_mid + legacy_post))
if [ "$legacy_race_hit" -ge 1 ]; then
  pass "TC-4.2: legacy race window hit ${legacy_race_hit}/${LEGACY_ITERS} (pre=$legacy_pre mid=$legacy_mid post=$legacy_post)"
else
  fail "TC-4.2: legacy race window 全 miss (pre=$legacy_pre) — sleep が短すぎ test dead code 化"
fi

# -------------------------------------------------------------------------
# TC-5: stale tempfile は filesystem に残るが state file 本体には流入しない
# -------------------------------------------------------------------------
# Atomic write is mktemp → write → mv. After SIGKILL during write, the
# tempfile (`${FLOW_STATE}.XXXXXX`) may persist. The state file itself
# remains either at its previous integral content or absent. This TC
# asserts the structural separation: state file integrity is independent
# of stale tempfiles.
echo "TC-5: stale tempfile residue does not corrupt state file"
TD=$(make_test_dir 2)
SID="cccc1111-2222-3333-4444-555566667777"
state_file=$(state_path "$TD" "$SID" 2)

# First, create a baseline state
(cd "$TD" && bash "$HOOK" create --session "$SID" \
  --phase "baseline" --issue 684 --branch "fbase" --pr 0 --next "nbase" >/dev/null 2>&1)
baseline_phase=$(jq -r '.phase' "$state_file")

# Trigger several SIGKILL'd writes (F-02: sleep 0.05 で race window 拡大)
for i in 1 2 3 4 5; do
  (
    cd "$TD"
    bash "$HOOK" patch --session "$SID" \
      --phase "patch_${i}" --next "np${i}" >/dev/null 2>&1
  ) &
  pid=$!
  sleep 0.05
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
done

# State file MUST still parse and contain a non-empty phase (either baseline
# or one of the patched values — both are atomic-integral outcomes).
if jq empty "$state_file" 2>/dev/null; then
  current_phase=$(jq -r '.phase' "$state_file")
  if [ -n "$current_phase" ] && [ "$current_phase" != "null" ]; then
    pass "TC-5.1: state file integral after 5 SIGKILL'd writes (phase=$current_phase, baseline=$baseline_phase)"
  else
    fail "TC-5.1: state file phase is empty/null after SIGKILL'd writes"
  fi
else
  fail "TC-5.1: state file failed to parse after SIGKILL'd writes"
fi

# F-02 fix: mv→cp mutation の責務は S4 atomic-write.test.sh 担当 (本 TC は
# user-visible invariant: state file integrity のみ assert)
# F-09 fix: state_dir / unset state_dir baseline_phase current_phase 削除 (dead code)

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
echo "All crash-resume tests passed!"
