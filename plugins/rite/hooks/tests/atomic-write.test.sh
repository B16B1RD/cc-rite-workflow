#!/bin/bash
# Tests for atomic write integrity — Issue #672 / #684 (T-09 / AC-9)
#
# Purpose:
#   `flow-state-update.sh` は state file を更新する際、
#     mktemp ${FLOW_STATE}.XXXXXX  →  jq 出力で tempfile に書き込み  →  mv tempfile state_file
#   の atomic write pattern を採る。POSIX で `mv` は同一 filesystem 内では
#   atomic な rename(2) syscall として実装され、SIGKILL や process crash で
#   write が中断されても state file 本体は **直前の整合状態を保持** するか
#   **新しい完全な状態にすり替わる** いずれかになる。partial-write は構造的に
#   不在となる。
#
#   本テストはこの atomic invariant を:
#     (a) 連続 SIGKILL probe で state file の整合性を 100 iteration verify
#     (b) sandboxed mutation test (`mv` を `cp` に改変) で test 自身の
#         identification power を empirical 確認 (Wiki 経験則「Test pin
#         protection theater」+「Mutation testing」)
#   で固定する。
#
# Test cases:
#   TC-1: 100 iteration SIGKILL probe → state file 常に integral (jq parse 成功 or ENOENT)
#   TC-2: 連続 patch (急速 50 回) 完了後 → 最終 phase が最後の patch と一致 (no lost update outside SIGKILL)
#   TC-3: Mutation test — sandbox に hook をコピー、create mode の `mv` を `false` に改変、
#         改変版を実行後 (a) exit code 非 0 (b) state file が baseline のまま を verify
#         (mutation 検出 → test の identification power、Wiki 経験則「Test pin protection theater」)
#   TC-4: per-session と legacy 両 schema で atomic invariant 成立
#   TC-5: 連続 SIGKILL 後の最終 state file が完全な JSON object (key 数 ≥ 5) を保持
#
# Out of scope:
#   - trap-based cleanup の隔離 → flow-state-update-trap-isolation.test.sh
#   - crash resume の再開可能性 → crash-resume.test.sh
#
# Usage: bash plugins/rite/hooks/tests/atomic-write.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$HOOKS_DIR/flow-state-update.sh"
PASS=0
FAIL=0
FAILED_NAMES=()

# Outcome classifier helper (F-01 fix): SIGKILL race window probe で kill が
# write 中に landed したか (mid_or_temp) を区別する。pre しか観測できないと
# atomic invariant 検証が dead code 化するため、各 TC で mid_or_temp + post >= 1 を
# assert することで race window が実際に当たったことを実証する (review F-01)。
classify_outcome() {
  local f="$1"
  if [ -e "$f" ]; then
    if jq empty "$f" 2>/dev/null; then
      echo "post"
    else
      echo "corrupt"  # partial-write detected (must be 0)
    fi
  else
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

# Per-session state file path lookup
state_path() {
  local d="$1" sid="$2" schema="${3:-2}"
  if [ "$schema" = "2" ]; then
    echo "$d/.rite/sessions/${sid}.flow-state"
  else
    echo "$d/.rite-flow-state"
  fi
}

# state file integrity predicate: ENOENT は許容、存在時は jq parse 成功必須
state_file_is_integral() {
  local f="$1"
  if [ ! -e "$f" ]; then
    return 0
  fi
  jq empty "$f" >/dev/null 2>&1
}

echo "=== atomic-write tests (Issue #672 / #684 T-09 AC-9) ==="
echo ""

# -------------------------------------------------------------------------
# TC-1: 50 iteration SIGKILL probe → state file 常に integral + race window 実証
# -------------------------------------------------------------------------
# F-01 fix: race window probe の identification power を確保するため、
# (a) sleep を 0.003 → 0.05 に拡大、(b) iteration outcome を classify、
# (c) mid_or_temp + post >= 1 を assert して race が実際に当たったことを実証
# (旧実装は全 100 iter pre のみで PASS する false positive 経路があった)
echo "TC-1: 50 iter SIGKILL probe → integral + race window 実証"
TD=$(make_test_dir 2)
SID="aaaaaaaa-9999-9999-9999-999999999999"
ITERATIONS=50
flake_partial=0
pre_count=0
mid_or_temp_count=0
post_count=0

for i in $(seq 1 "$ITERATIONS"); do
  (
    cd "$TD"
    bash "$HOOK" create --session "$SID" \
      --phase "phase_iter_${i}" --issue 684 --branch "feat/iter${i}" --pr 0 --next "n${i}" >/dev/null 2>&1
  ) &
  pid=$!
  sleep 0.05  # F-01: 0.003 → 0.05
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
  fail "TC-1.1: partial-write ${flake_partial}/${ITERATIONS}"
fi

race_hit=$((mid_or_temp_count + post_count))
if [ "$race_hit" -ge 1 ]; then
  pass "TC-1.2: race window hit ${race_hit}/${ITERATIONS} (pre=$pre_count mid_or_temp=$mid_or_temp_count post=$post_count) — atomic invariant 検証 alive"
else
  fail "TC-1.2: race window 全 miss (pre=$pre_count) — sleep 短すぎ test dead code 化"
fi

# -------------------------------------------------------------------------
# TC-2: 連続 patch (50 回、no SIGKILL) → 最終 phase が最後の patch と一致
# -------------------------------------------------------------------------
# Counter-test for TC-1: when we don't kill the writer, atomic write must
# still produce the expected final state. This guards against "atomic
# property holds because nothing ever wrote" false-positive.
echo "TC-2: 連続 patch 50 回 (no kill) → 最終 phase が完了 patch と一致"
TD=$(make_test_dir 2)
SID="bbbbbbbb-9999-9999-9999-999999999999"
state_file=$(state_path "$TD" "$SID" 2)

(cd "$TD" && bash "$HOOK" create --session "$SID" \
  --phase "phase_init" --issue 684 --branch "feat/test" --pr 0 --next "init" >/dev/null 2>&1)

for i in $(seq 1 50); do
  (cd "$TD" && bash "$HOOK" patch --session "$SID" \
    --phase "phase_patch_${i}" --next "p${i}" >/dev/null 2>&1)
done

final_phase=$(jq -r '.phase' "$state_file")
if [ "$final_phase" = "phase_patch_50" ]; then
  pass "TC-2.1: 連続 patch 完了 → 最終 phase=$final_phase (no lost update without SIGKILL)"
else
  fail "TC-2.1: expected 'phase_patch_50', got '$final_phase'"
fi

# -------------------------------------------------------------------------
# TC-3: Mutation test — atomic `mv` を `false` に改変した hook が全 mode で
#       state を破壊しないことを empirical 検証
# -------------------------------------------------------------------------
# Wiki 経験則「Mutation testing で test の真正性 (dead code 検出 + identification
# power) を empirical 検証する」。flow-state-update.sh は 3 つの atomic rename
# site を持つ (create / patch / increment 各 mode の `if ! mv "$TMP_STATE"
# "$FLOW_STATE"`)。3 つすべてを `false` に置換した mutated hook を sandbox で
# 動かし、各 mode を順次起動して全 mode で
#   (a) `if ! false` が常に真 → "mv failed" error path に入り exit 1
#   (b) atomic rename が起きないので state file は baseline のまま不変
# の 2 条件を assert する。これにより mode ごとに mutation を独立検出できる。
#
# F-05 fix (Issue #760): 旧実装は `0,/PAT/` で create mode 1 occurrence のみを
# 置換していたため、patch / increment の atomic mv が破壊的に退化しても test が
# PASS する false positive 経路を持っていた。canonical 防御は (1) `s|...|g` で
# 3 occurrence 全てを mutate、(2) sed regression guard で mutation 数を pin
# (`grep -c == 3`)、(3) create/patch/increment 各 mode を独立に起動して
# rc!=0 + state hash 不変を mode ごとに assert。
#
# 注意: trap (`_rite_flow_state_atomic_cleanup`) が EXIT で TMP_STATE を rm するため、
# mutation を `cp` にしてしまうと tempfile が trap で消されて mutation を検出できない
# (Wiki 経験則「test の identification power 検証」の好例)。`false` 置換にすることで
# trap の cleanup 経路と独立に mutation を検出できる。
echo "TC-3: Mutation test (mv→false × 3 mode) で exit code + state 不変を観測"
TD=$(make_test_dir 2)
sandbox="$TD/sandbox-hooks"
mkdir -p "$sandbox"
cp -a "$HOOKS_DIR/." "$sandbox/"

# Pre-place a baseline state so we can verify it remains unchanged after the
# mutated hook runs (mutation = atomic rename never happens).
SID_M="cccccccc-9999-9999-9999-999999999999"
mkdir -p "$TD/.rite/sessions"
mut_state_file="$TD/.rite/sessions/${SID_M}.flow-state"
echo '{"active":true,"phase":"baseline_phase","issue_number":1,"session_id":"'$SID_M'"}' > "$mut_state_file"
baseline_phase=$(jq -r '.phase' "$mut_state_file")
# Hash the baseline file so we can detect any mutation-induced change byte-exact.
baseline_hash=$(sha1sum "$mut_state_file" | awk '{print $1}')

# F-05: Replace ALL 3 `mv` occurrences (create + patch + increment).
# `s|...|...|g` performs global substitution within each line, but since each
# `mv` site is on its own line we effectively substitute every site in the file.
sed -i.bak -e 's|if ! mv "\$TMP_STATE" "\$FLOW_STATE"|if ! false "\$TMP_STATE" "\$FLOW_STATE"|g' \
  "$sandbox/flow-state-update.sh"
rm -f "$sandbox/flow-state-update.sh.bak"

# F-05: Verify exactly 3 mutations applied (sed regression guard with count pin).
# `|| true` is required because grep -c returns exit 1 when count == 0, which
# would trip `set -e`. We rely on the count value, not the exit status.
mut_count=$(grep -c 'if ! false "$TMP_STATE" "$FLOW_STATE"' "$sandbox/flow-state-update.sh" || true)
unmutated_count=$(grep -c 'if ! mv "$TMP_STATE" "$FLOW_STATE"' "$sandbox/flow-state-update.sh" || true)
if [ "$mut_count" -eq 3 ] && [ "$unmutated_count" -eq 0 ]; then
  pass "TC-3.0: mutation sed applied (mut=3, unmutated=0 → all create/patch/increment mv→false)"
else
  fail "TC-3.0: expected mut=3 unmutated=0, got mut=$mut_count unmutated=$unmutated_count — test infrastructure error"
fi

if [ "$mut_count" -eq 3 ]; then
  # ---------- TC-3.1: create mode mutation ----------
  # Pre-existing baseline state belongs to SID_M — mutation will fail at mv,
  # leaving the existing state file unchanged. Use create mode with --session to
  # bypass session ownership reject (same SID == own state, fast-path).
  mut_rc=0
  mut_out=$(cd "$TD" && bash "$sandbox/flow-state-update.sh" create --session "$SID_M" \
    --phase "phase_mut" --issue 999 --branch "feat/mut" --pr 0 --next "n_mut" 2>&1) || mut_rc=$?

  if [ "$mut_rc" -ne 0 ]; then
    pass "TC-3.1a: create mode mutated hook exit non-zero (rc=$mut_rc) — create mv path exercised"
  else
    fail "TC-3.1a: create mode mutated hook unexpectedly succeeded (rc=$mut_rc) — sed/branch mismatch?"
  fi

  current_hash=$(sha1sum "$mut_state_file" | awk '{print $1}')
  current_phase=$(jq -r '.phase' "$mut_state_file")
  if [ "$current_hash" = "$baseline_hash" ] && [ "$current_phase" = "$baseline_phase" ]; then
    pass "TC-3.1b: create mutation → state file unchanged (phase=$current_phase, hash matches)"
  else
    fail "TC-3.1b: create mutation → state mutated despite mv→false — phase=$current_phase"
  fi

  # ---------- TC-3.2: patch mode mutation (F-05) ----------
  # patch mode の mv も mutation で fail することを mode 独立に確認する。
  # patch は既存 state の更新なので、baseline は同じ mut_state_file を流用。
  mut_rc=0
  mut_out=$(cd "$TD" && bash "$sandbox/flow-state-update.sh" patch --session "$SID_M" \
    --phase "phase_patch_mut" --next "n_patch_mut" 2>&1) || mut_rc=$?

  if [ "$mut_rc" -ne 0 ]; then
    pass "TC-3.2a: patch mode mutated hook exit non-zero (rc=$mut_rc) — patch mv path exercised"
  else
    fail "TC-3.2a: patch mode mutated hook unexpectedly succeeded (rc=$mut_rc) — line 687 mv mutation may have failed"
  fi

  current_hash=$(sha1sum "$mut_state_file" | awk '{print $1}')
  current_phase=$(jq -r '.phase' "$mut_state_file")
  if [ "$current_hash" = "$baseline_hash" ] && [ "$current_phase" = "$baseline_phase" ]; then
    pass "TC-3.2b: patch mutation → state file unchanged (phase=$current_phase, hash matches)"
  else
    fail "TC-3.2b: patch mutation → state mutated despite mv→false — phase=$current_phase"
  fi

  # ---------- TC-3.3: increment mode mutation (F-05) ----------
  # increment mode は loop_count 等の counter 増分。同様に mutation で fail を確認。
  mut_rc=0
  mut_out=$(cd "$TD" && bash "$sandbox/flow-state-update.sh" increment --session "$SID_M" \
    --field "loop_count" 2>&1) || mut_rc=$?

  if [ "$mut_rc" -ne 0 ]; then
    pass "TC-3.3a: increment mode mutated hook exit non-zero (rc=$mut_rc) — increment mv path exercised"
  else
    fail "TC-3.3a: increment mode mutated hook unexpectedly succeeded (rc=$mut_rc) — line 705 mv mutation may have failed"
  fi

  current_hash=$(sha1sum "$mut_state_file" | awk '{print $1}')
  current_phase=$(jq -r '.phase' "$mut_state_file")
  if [ "$current_hash" = "$baseline_hash" ] && [ "$current_phase" = "$baseline_phase" ]; then
    pass "TC-3.3b: increment mutation → state file unchanged (phase=$current_phase, hash matches)"
  else
    fail "TC-3.3b: increment mutation → state mutated despite mv→false — phase=$current_phase"
  fi

  # ---------- TC-3.4: counter-positive — production hook全 mode 成功 ----------
  # production (unmutated) hook on the same scenario MUST successfully update the
  # state file (rc=0, phase changes) for create/patch/increment all three modes.
  TD2=$(make_test_dir 2)
  SID_P="dddddddd-9999-9999-9999-999999999999"
  prod_state_file="$TD2/.rite/sessions/${SID_P}.flow-state"
  mkdir -p "$TD2/.rite/sessions"
  echo '{"active":true,"phase":"baseline_phase","issue_number":1,"session_id":"'$SID_P'"}' > "$prod_state_file"
  prod_rc=0
  (cd "$TD2" && bash "$HOOK" create --session "$SID_P" \
    --phase "phase_prod" --issue 999 --branch "feat/prod" --pr 0 --next "n_prod" >/dev/null 2>&1) || prod_rc=$?
  prod_phase=$(jq -r '.phase' "$prod_state_file")
  if [ "$prod_rc" -eq 0 ] && [ "$prod_phase" = "phase_prod" ]; then
    pass "TC-3.4: production hook (create) updates state successfully (rc=0, phase=$prod_phase) — counter-positive"
  else
    fail "TC-3.4: production hook (create) failed — rc=$prod_rc phase=$prod_phase"
  fi
fi

# -------------------------------------------------------------------------
# TC-4: per-session と legacy 両 schema で atomic invariant 成立
# -------------------------------------------------------------------------
echo "TC-4: legacy schema=1 でも atomic invariant + race window 実証 (30 iter)"
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
      --phase "legacy_${i}" --issue 684 --branch "feat/legacy${i}" --pr 0 --next "nL${i}" >/dev/null 2>&1
  ) &
  pid=$!
  sleep 0.05  # F-01: 0.003 → 0.05
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
  fail "TC-4.1: legacy partial-write ${flake_legacy}/${LEGACY_ITERS}"
fi

legacy_race_hit=$((legacy_mid + legacy_post))
if [ "$legacy_race_hit" -ge 1 ]; then
  pass "TC-4.2: legacy race window hit ${legacy_race_hit}/${LEGACY_ITERS} (pre=$legacy_pre mid=$legacy_mid post=$legacy_post)"
else
  fail "TC-4.2: legacy race window 全 miss (pre=$legacy_pre)"
fi

# -------------------------------------------------------------------------
# TC-5: 最終 state file が完全な JSON object (必須 key 群) を保持
# -------------------------------------------------------------------------
echo "TC-5: SIGKILL'd writes 後の state file が完全 JSON object を保持"
TD=$(make_test_dir 2)
SID="eeeeeeee-9999-9999-9999-999999999999"
state_file=$(state_path "$TD" "$SID" 2)

# Make a clean baseline with full keys
(cd "$TD" && bash "$HOOK" create --session "$SID" \
  --phase "baseline" --issue 684 --branch "feat/keys" --pr 42 --next "nbase" >/dev/null 2>&1)

# Then 10 SIGKILL'd patches (F-01: sleep 0.05 で race window 拡大)
for i in $(seq 1 10); do
  (cd "$TD" && bash "$HOOK" patch --session "$SID" \
    --phase "patch_${i}" --next "np${i}" >/dev/null 2>&1) &
  pid=$!
  sleep 0.05
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
done

# state file must be parseable AND contain all baseline keys (no field truncation)
if jq empty "$state_file" 2>/dev/null; then
  required_keys=("active" "phase" "issue_number" "branch" "session_id" "next_action")
  missing=0
  for key in "${required_keys[@]}"; do
    val=$(jq -r ".$key // \"__MISSING__\"" "$state_file")
    if [ "$val" = "__MISSING__" ]; then
      missing=$((missing + 1))
      echo "  missing key: $key" >&2
    fi
  done
  if [ "$missing" -eq 0 ]; then
    pass "TC-5.1: state file preserves all required keys after 10 SIGKILL'd patches"
  else
    fail "TC-5.1: $missing required key(s) missing from state file"
  fi
else
  fail "TC-5.1: state file failed to parse"
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
echo "All atomic-write tests passed!"
