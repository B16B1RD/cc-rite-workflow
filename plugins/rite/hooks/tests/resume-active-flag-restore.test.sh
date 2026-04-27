#!/bin/bash
# Tests for resume.md Phase 3.0.1 building blocks — active flag restore semantics.
#
# PR #688 cycle 16 fix (F-05 MEDIUM、cycle 15 review test reviewer):
# resume.md の Phase 3.0.1 bash block (cycle 10 で導入された [ -z "$curr_phase" ] guard) に対する
# 自動テストが不在だった。本 test は Phase 3.0.1 が依存する building blocks
# (state-read.sh + flow-state-update.sh patch --if-exists) の integration を pin する。
#
# 検証する invariants:
#   (a) per-session/legacy 両不在 → state-read.sh は "" を返す → patch を skip すべき
#   (b) per-session 存在 + valid phase → state-read.sh が phase を返す → patch --if-exists が成功
#   (c) phase 空文字列 → state-read.sh は "" を返す → patch を skip すべき
#   (d) flow-state-update.sh patch --phase "" は validation で reject される
#       (cycle 9 で実際に発生した resume hard abort silent regression の経路を pin)
#
# Note: 本 test は resume.md の bash block 自体を実行するわけではない (md ファイルから抽出する
# のは複雑性が高いため別 Issue で対応)。代わりに resume.md が依存する building blocks の
# semantics を pin することで、cycle 10 fix の core invariant (空文字 guard が必要な根拠) を
# 回帰時に即座に検出する。
#
# Usage: bash plugins/rite/hooks/tests/resume-active-flag-restore.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_READ="$HOOKS_DIR/state-read.sh"
FLOW_STATE_UPDATE="$HOOKS_DIR/flow-state-update.sh"

if [ ! -x "$STATE_READ" ]; then
  echo "ERROR: state-read.sh missing or not executable: $STATE_READ" >&2
  exit 1
fi
if [ ! -x "$FLOW_STATE_UPDATE" ]; then
  echo "ERROR: flow-state-update.sh missing or not executable: $FLOW_STATE_UPDATE" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi

PASS=0
FAIL=0
FAILED_NAMES=()

cleanup_dirs=()
_resume_test_cleanup() {
  local d
  for d in "${cleanup_dirs[@]:-}"; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
  done
}
trap '_resume_test_cleanup' EXIT
trap '_resume_test_cleanup; exit 130' INT
trap '_resume_test_cleanup; exit 143' TERM
trap '_resume_test_cleanup; exit 129' HUP

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  ✅ $name"
    PASS=$((PASS+1))
  else
    echo "  ❌ $name"
    echo "     expected: $expected"
    echo "     actual:   $actual"
    FAIL=$((FAIL+1))
    FAILED_NAMES+=("$name")
  fi
}

make_sandbox() {
  local d sandbox_err
  d=$(mktemp -d) || { echo "ERROR: mktemp -d failed" >&2; exit 1; }
  sandbox_err=$(mktemp /tmp/rite-resume-sandbox-err-XXXXXX) || sandbox_err="/dev/null"
  if ! (
    cd "$d"
    git init -q 2>"$sandbox_err"
    echo a > a && git add a 2>>"$sandbox_err"
    git -c user.email=t@test.local -c user.name=test commit -q -m init 2>>"$sandbox_err"
  ); then
    echo "ERROR: make_sandbox: git init/commit failed in $d" >&2
    [ "$sandbox_err" != "/dev/null" ] && [ -s "$sandbox_err" ] && head -5 "$sandbox_err" | sed 's/^/  /' >&2
    rm -rf "$d"
    [ "$sandbox_err" != "/dev/null" ] && rm -f "$sandbox_err"
    exit 1
  fi
  [ "$sandbox_err" != "/dev/null" ] && rm -f "$sandbox_err"
  echo "$d"
}

write_config_v2() {
  cat > "$1/rite-config.yml" <<EOF
flow_state:
  schema_version: 2
EOF
}

write_session_id() {
  echo "$2" > "$1/.rite-session-id"
}

write_per_session() {
  mkdir -p "$1/.rite/sessions"
  printf '%s' "$3" > "$1/.rite/sessions/${2}.flow-state"
}

# resume.md Phase 3.0.1 が呼ぶ pattern:
#   curr_phase=$(bash state-read.sh --field phase --default "")
#   if [ -z "$curr_phase" ]; then skip; else flow-state-update.sh patch --phase "$curr_phase" ...; fi
read_phase_via_helper() {
  local d="$1"
  (cd "$d" && bash "$STATE_READ" --field phase --default "")
}

# --- TC-1: per-session/legacy 両不在 → state-read.sh が "" を返す → patch を skip すべき ---
echo "TC-1: per-session/legacy 両不在 → curr_phase 空文字 → patch skip 経路 (cycle 10 F-01 CRITICAL guard)"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
write_config_v2 "$SBX"
write_session_id "$SBX" "11111111-1111-1111-1111-111111111111"
# per-session も legacy も作成しない

curr_phase=$(read_phase_via_helper "$SBX")
assert_eq "TC-1.1: 両不在では curr_phase は空文字" "" "$curr_phase"

# resume.md Phase 3.0.1 の guard semantics を pin: 空文字なら patch を skip
# (空文字で patch を呼ぶと flow-state-update.sh:289-291 の validation で reject されて
# resume が hard abort する経路。cycle 9 で実際に発生した CRITICAL silent regression)
if [ -z "$curr_phase" ]; then
  patch_skipped="true"
else
  patch_skipped="false"
fi
assert_eq "TC-1.2: [ -z curr_phase ] guard が patch skip を決定する" "true" "$patch_skipped"

# --- TC-2: per-session 存在 + valid phase → state-read.sh が phase を返す → patch --if-exists が成功 ---
echo "TC-2: per-session 存在 + valid phase → patch --if-exists 成功経路"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
write_config_v2 "$SBX"
SID="22222222-2222-2222-2222-222222222222"
write_session_id "$SBX" "$SID"
write_per_session "$SBX" "$SID" '{"phase":"phase5_lint","next_action":"continue","pr_number":42,"loop_count":2,"active":false}'

curr_phase=$(read_phase_via_helper "$SBX")
assert_eq "TC-2.1: per-session 存在で phase 値を返す" "phase5_lint" "$curr_phase"

# patch --if-exists --active true を実際に実行して成功することを確認
# (resume.md Phase 3.0.1 の else branch が呼ぶ pattern)
patch_err=$(mktemp /tmp/rite-resume-patch-err-XXXXXX)
if (cd "$SBX" && bash "$FLOW_STATE_UPDATE" patch \
    --phase "$curr_phase" \
    --next "Resume continuation." \
    --active true \
    --session "$SID" \
    --if-exists 2>"$patch_err"); then
  patch_rc=0
else
  patch_rc=$?
fi
if [ "$patch_rc" -ne 0 ]; then
  echo "  patch stderr:" >&2
  head -5 "$patch_err" | sed 's/^/    /' >&2
fi
rm -f "$patch_err"
assert_eq "TC-2.2: patch --if-exists が成功" "0" "$patch_rc"

# active flag が true に書き戻されたことを確認
active_value=$(jq -r '.active // empty' "$SBX/.rite/sessions/${SID}.flow-state" 2>/dev/null)
assert_eq "TC-2.3: active flag が true に書き戻される" "true" "$active_value"

# --- TC-3: phase 空文字列 → state-read.sh が "" を返す → patch を skip すべき ---
echo "TC-3: phase が空文字列 → curr_phase 空 → patch skip (resume.md L391 enumeration の path 3)"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
write_config_v2 "$SBX"
SID="33333333-3333-3333-3333-333333333333"
write_session_id "$SBX" "$SID"
write_per_session "$SBX" "$SID" '{"phase":"","next_action":"continue","active":false}'

curr_phase=$(read_phase_via_helper "$SBX")
assert_eq "TC-3.1: phase 空文字列で curr_phase は空" "" "$curr_phase"

if [ -z "$curr_phase" ]; then
  patch_skipped="true"
else
  patch_skipped="false"
fi
assert_eq "TC-3.2: [ -z curr_phase ] guard が空 phase で patch skip を決定する" "true" "$patch_skipped"

# --- TC-4: flow-state-update.sh patch --phase "" は validation で reject される ---
# (cycle 9 review F-01 で発生した hard abort 経路の直接証明)
# guard なしで empty phase を patch に渡すと validation エラーになることを pin する
echo "TC-4: patch --phase \"\" は validation で reject される (guard なし時の hard abort 経路)"
SBX=$(make_sandbox); cleanup_dirs+=("$SBX")
write_config_v2 "$SBX"
SID="44444444-4444-4444-4444-444444444444"
write_session_id "$SBX" "$SID"
write_per_session "$SBX" "$SID" '{"phase":"phase5_lint","next_action":"continue","active":false}'

# わざと empty phase を渡す (cycle 9 で発生した silent regression の経路)
patch_err=$(mktemp /tmp/rite-resume-patch-empty-err-XXXXXX)
if (cd "$SBX" && bash "$FLOW_STATE_UPDATE" patch \
    --phase "" \
    --next "Test." \
    --active true \
    --session "$SID" \
    --if-exists 2>"$patch_err"); then
  patch_empty_rc=0
else
  patch_empty_rc=$?
fi
rm -f "$patch_err"
# patch は exit non-zero で reject すべき (これが cycle 9 で hard abort を引き起こした根本原因)
if [ "$patch_empty_rc" -ne 0 ]; then
  rejected="yes"
else
  rejected="no"
fi
assert_eq "TC-4.1: empty phase は patch validation で reject される (cycle 10 guard が必要な根拠)" "yes" "$rejected"

# --- Summary ---
echo
echo "─── resume-active-flag-restore.test.sh summary ──────────────────────────"
echo "PASS: $PASS"
echo "FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed tests:"
  for n in "${FAILED_NAMES[@]}"; do
    echo "  - $n"
  done
  exit 1
fi
echo "All tests passed."
