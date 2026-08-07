#!/bin/bash
# Tests for marker_emit / marker_get in hooks/scripts/lib/context-marker.sh (#2025)
#
# These fixtures ARE the marker contract. Before this lib the rules lived in
# SKILL.md prose, where "does the rule cover this case too?" could be asked
# indefinitely and answered only by argument; the point of the file under test
# is that such a question now has to arrive as a failing assertion here.
#
# The four rules each get a fixture that fails if the rule is dropped, plus the
# three cases where two rules interact and a naive implementation satisfies each
# rule alone while breaking their conjunction:
#   - branch filter BEFORE recency (AC-3 x AC-4): the newest line belongs to
#     another branch, so a filter-after-recency implementation returns empty or
#     the wrong branch's value while still passing AC-3 and AC-4 separately.
#   - whole-token key: `ITERATE_CB` must not read an `ITERATE_CB_MODE=` line.
#   - whole-token field: `--field RESET` must not read a `FIRE_RESET=` field.
# Both token pairs are live in skills/iterate/SKILL.md; substring matching would
# make the marker say the opposite of what was emitted.
#
# The byte-exact emit assertions exist because the wire format is frozen:
# consumers outside this lib grep it, so a separator or spacing change is a
# contract break that no behavioural assertion would catch.
#
# Convention: source the lib (it has no subprocess entry point), no network, no
# gh, no git repo needed. GNU/BSD portable — the lib parses with bash `case`
# globs precisely so this suite runs identically on the macOS CI leg.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"

LIB="$SCRIPT_DIR/../scripts/lib/context-marker.sh"
REPO_ROOT="$(_helpers_resolve_repo_root "$SCRIPT_DIR")"

echo "=== context-marker.sh (marker_emit / marker_get) ==="

if [ ! -f "$LIB" ]; then
  echo "ERROR: $LIB not found" >&2
  exit 1
fi

# shellcheck source=../scripts/lib/context-marker.sh
source "$LIB"

# --- T-01 (AC-1): line anchor -------------------------------------------------
# A WARNING that quotes a marker is the real-world shape of this: helpers embed
# marker text in diagnostics, and the unanchored `sed -n 's/.*KEY=...'` idiom
# this lib replaces read those quotes as the marker.
anchor_fixture() {
  printf '%s\n' \
    'WARNING: 直前の出力に [CONTEXT] ITERATE_CB=bogus が含まれていました' \
    '  hint: see [CONTEXT] ITERATE_CB=alsobogus below' \
    '[CONTEXT] ITERATE_CB=ok; cycle=2; max=15'
}
assert "T-01 行頭の marker のみが返る (AC-1)" "ok" "$(anchor_fixture | marker_get ITERATE_CB)"
assert "T-01 行中 marker だけの入力は空 (AC-1)" "" \
  "$(printf '%s\n' 'note: [CONTEXT] ITERATE_CB=bogus' | marker_get ITERATE_CB)"
# Ordering matters: the replaced idiom ended in `| tail -1`, so a quoted marker
# appearing *after* the real one won. Measured on the pre-change extraction, the
# fixture below returned `fire` — a spurious circuit-breaker firing read out of a
# diagnostic line. Anchoring is what makes the trailing noise inert.
# The trailing noise embeds the marker prefix verbatim, so this also kills the
# weaker "require `[CONTEXT] ` but do not anchor it" implementation, not just the
# `.*KEY=` one.
assert "T-01 marker の後ろに引用行が来ても誤読しない (AC-1)" "ok" \
  "$(printf '%s\n' \
       '[CONTEXT] TREND_DIVERGENCE=ok; trend=5,3,1; cycles=3; lost=0; reason=converging_or_descending' \
       'WARNING: 直前は [CONTEXT] TREND_DIVERGENCE=fire でした（診断の引用）' \
     | marker_get TREND_DIVERGENCE)"
assert "T-01 marker の後ろの reason= 引用も誤読しない (AC-1)" "run_boundary_unresolved" \
  "$(printf '%s\n' \
       '[CONTEXT] TREND_DIVERGENCE=insufficient; trend=; cycles=0; reason=run_boundary_unresolved' \
       '  hint: [CONTEXT] TREND_DIVERGENCE=ok; reason=stale_pin を疑ってください' \
     | marker_get TREND_DIVERGENCE --field reason)"

# --- T-02 (AC-2): multi-line stderr tolerance ---------------------------------
noisy_fixture() {
  printf '%s\n' \
    'WARNING: state-path-resolve.sh を実行できませんでした' \
    '  mktemp: failed to create file' \
    '' \
    '[CONTEXT] TREND_DIVERGENCE=fire; trend=8,5,4,6,3; cycles=5; lost=0; reason=no_new_minimum_and_not_descending' \
    'WARNING: 現 run のレビュー結果 JSON が cycle_count に不足しています' \
    '  files=4 < cycles=5'
}
assert "T-02 前後に複数行 stderr が混入しても値が返る (AC-2)" "fire" \
  "$(noisy_fixture | marker_get TREND_DIVERGENCE)"
assert "T-02 同条件で --field も正しく返る (AC-2)" "8,5,4,6,3" \
  "$(noisy_fixture | marker_get TREND_DIVERGENCE --field trend)"
assert "T-02 数字を含む reason が切り詰められない (AC-2)" "no_new_minimum_and_not_descending" \
  "$(noisy_fixture | marker_get TREND_DIVERGENCE --field reason)"

# --- T-03 / T-07 (AC-3): branch scope -----------------------------------------
two_branch_fixture() {
  printf '%s\n' \
    '[CONTEXT] WT_ENSURE=reenter; path=/wt/issue-1; branch=feat/issue-1-a' \
    '[CONTEXT] WT_ENSURE=reconstructed; path=/wt/issue-2; branch=feat/issue-2-b'
}
assert "T-03 --branch 指定で該当ブランチの値のみ返る (AC-3)" "reenter" \
  "$(two_branch_fixture | marker_get WT_ENSURE --branch feat/issue-1-a)"
assert "T-03 --branch 指定で該当ブランチの field が返る (AC-3)" "/wt/issue-2" \
  "$(two_branch_fixture | marker_get WT_ENSURE --branch feat/issue-2-b --field path)"
assert "T-07 他ブランチの値しか無いときは空 (AC-3)" "" \
  "$(two_branch_fixture | marker_get WT_ENSURE --branch feat/issue-3-c)"
assert "T-07 branch= field を持たない marker は --branch に一致しない (AC-3)" "" \
  "$(printf '%s\n' '[CONTEXT] WT_ENSURE=disabled; path=' | marker_get WT_ENSURE --branch feat/issue-1-a)"

# --- T-04 (AC-4): recency -----------------------------------------------------
assert "T-04 同一 KEY 2 回 emit で最新値が返る (AC-4)" "ok" \
  "$(printf '%s\n' '[CONTEXT] ITERATE_CB=fire; cycle=15' 'noise' '[CONTEXT] ITERATE_CB=ok; cycle=1' \
     | marker_get ITERATE_CB)"
assert "T-04 --field も最新行から読まれる (AC-4)" "1" \
  "$(printf '%s\n' '[CONTEXT] ITERATE_CB=fire; cycle=15' '[CONTEXT] ITERATE_CB=ok; cycle=1' \
     | marker_get ITERATE_CB --field cycle)"

# --- AC-3 x AC-4 conjunction: filter first, THEN recency ----------------------
# Not one of the T-xx rows on its own — it is what AC-3 and AC-4 mean together,
# and it is the single assertion that separates a correct implementation from
# the plausible-but-wrong "take the last marker, then check its branch".
# The newest line is branch b2; asking for b1 must return the OLDER value, not
# empty (that is the recency-first bug) and not b2's value (that is no filter).
order_fixture() {
  printf '%s\n' \
    '[CONTEXT] WT_ENSURE=reenter; path=/wt/a; branch=b1' \
    '[CONTEXT] WT_ENSURE=reconstructed; path=/wt/b; branch=b2'
}
assert "branch フィルタは recency より先に適用される (AC-3 x AC-4)" "reenter" \
  "$(order_fixture | marker_get WT_ENSURE --branch b1)"
assert "同一ブランチが複数あれば最新が勝つ (AC-3 x AC-4)" "reconstructed" \
  "$(printf '%s\n' \
       '[CONTEXT] WT_ENSURE=reenter; path=/wt/a; branch=b1' \
       '[CONTEXT] WT_ENSURE=residue; path=/wt/x; branch=b2' \
       '[CONTEXT] WT_ENSURE=reconstructed; path=/wt/c; branch=b1' \
     | marker_get WT_ENSURE --branch b1)"

# --- Whole-token matching (key and field) -------------------------------------
# Both pairs below are live in skills/iterate/SKILL.md. Substring matching on
# either axis makes marker_get report a value that was never emitted for the
# key/field that was asked for — the exact class of defect the prose rule at
# iterate/SKILL.md used to guard by asking the reader to be careful.
assert "KEY はトークン完全一致 (ITERATE_CB は ITERATE_CB_MODE を読まない)" "" \
  "$(printf '%s\n' '[CONTEXT] ITERATE_CB_MODE=batch; issue=2025' | marker_get ITERATE_CB)"
assert "KEY 完全一致: ITERATE_CB_MODE 自身は読める" "batch" \
  "$(printf '%s\n' '[CONTEXT] ITERATE_CB_MODE=batch; issue=2025' | marker_get ITERATE_CB_MODE)"
assert "field はトークン完全一致 (RESET は FIRE_RESET を読まない)" "" \
  "$(printf '%s\n' '[CONTEXT] ITERATE_CB_MODE=batch; FIRE_RESET=failed' | marker_get ITERATE_CB_MODE --field RESET)"
assert "field 完全一致: FIRE_RESET 自身は読める" "failed" \
  "$(printf '%s\n' '[CONTEXT] ITERATE_CB_MODE=batch; FIRE_RESET=failed' | marker_get ITERATE_CB_MODE --field FIRE_RESET)"

# --- T-05 (AC-5): backward compatibility with plain `echo` --------------------
# The migration is staged: iterate/SKILL.md goes through marker_emit, everything
# else still echoes. Reading both must be the same operation, or the staging
# itself would be a behaviour change.
legacy_line=$(echo "[CONTEXT] WT_ENSURE=reenter; path=/wt/issue-9; branch=fix/issue-9-x")
assert "T-05 直接 echo された marker が読める (AC-5)" "reenter" \
  "$(printf '%s\n' "$legacy_line" | marker_get WT_ENSURE)"
assert "T-05 直接 echo された marker の field が読める (AC-5)" "/wt/issue-9" \
  "$(printf '%s\n' "$legacy_line" | marker_get WT_ENSURE --field path)"
assert "T-05 直接 echo された marker が --branch で絞れる (AC-5)" "reenter" \
  "$(printf '%s\n' "$legacy_line" | marker_get WT_ENSURE --branch fix/issue-9-x)"

# --- T-06 (§4.5): absent marker -> empty, exit 0 ------------------------------
absent_out=$(printf '%s\n' 'WARNING: nothing here' 'plain text' | marker_get ITERATE_CB); absent_rc=$?
assert "T-06 marker 不在時は空を返す (§4.5)" "" "$absent_out"
assert "T-06 marker 不在時も exit 0 (§4.5)" "0" "$absent_rc"
empty_out=$(printf '' | marker_get ITERATE_CB); empty_rc=$?
assert "T-06 空入力でも空 + exit 0 (§4.5)" "" "$empty_out"
assert "T-06 空入力でも exit 0 (§4.5)" "0" "$empty_rc"
assert "T-06 存在しない field は空を返す" "" \
  "$(printf '%s\n' '[CONTEXT] ITERATE_CB=ok; cycle=1' | marker_get ITERATE_CB --field nosuch)"

# --- Empty values survive emit and lookup ------------------------------------
# `path=` is a real emission (WT_ENSURE=disabled). An implementation that drops
# empty fields would make `--field path` indistinguishable from "no such field",
# and both from "no marker" — three states the callers branch on separately.
assert "空値の marker が emit できる" "[CONTEXT] WT_ENSURE=disabled; path=; branch=foo" \
  "$(marker_emit WT_ENSURE disabled "path=" "branch=foo")"
assert "空 field 値が往復する" "" \
  "$(marker_emit WT_ENSURE disabled "path=" "branch=foo" | marker_get WT_ENSURE --field path)"
assert "空 field 値でも branch フィルタは効く" "disabled" \
  "$(marker_emit WT_ENSURE disabled "path=" "branch=foo" | marker_get WT_ENSURE --branch foo)"
assert "空の主値が往復する" "" \
  "$(marker_emit TREND_DIVERGENCE "" "reason=need_3_cycles" | marker_get TREND_DIVERGENCE)"
assert "空の主値でも field は読める" "need_3_cycles" \
  "$(marker_emit TREND_DIVERGENCE "" "reason=need_3_cycles" | marker_get TREND_DIVERGENCE --field reason)"

# --- Byte-exact wire format (§3.3: the format is frozen) ----------------------
# Existing consumers grep this text. Assert the whole line, not its parts: a
# separator changed from "; " to ";" round-trips through marker_get unharmed
# and would break every grep outside this lib.
assert "書式 golden: 単一値" "[CONTEXT] ITERATE_RUN_CLOSE=ok" \
  "$(marker_emit ITERATE_RUN_CLOSE ok)"
assert "書式 golden: 追加フィールド付き" "[CONTEXT] ITERATE_CB=fire; cycle=3; max=15" \
  "$(marker_emit ITERATE_CB fire "cycle=3" "max=15")"
golden_bytes=$(marker_emit ITERATE_CB fire "cycle=3" "max=15" | wc -c | tr -d '[:space:]')
assert "書式 golden: バイト数 (末尾改行 1 個ちょうど)" "43" "$golden_bytes"

# --- Round-trip: what emit writes, get reads back -----------------------------
rt=$(marker_emit ITERATE_CYCLE_MAX 15 "ITERATE_CYCLE=3" "RESET=failed-stale" "REFIRE=0")
assert "往復: 主値" "15" "$(printf '%s\n' "$rt" | marker_get ITERATE_CYCLE_MAX)"
assert "往復: field (ハイフン入りの値)" "failed-stale" \
  "$(printf '%s\n' "$rt" | marker_get ITERATE_CYCLE_MAX --field RESET)"
assert "往復: 値の部分一致で拾わない (failed は failed-stale と別)" "failed-stale" \
  "$(printf '%s\n' "$rt" | marker_get ITERATE_CYCLE_MAX --field RESET)"

# --- emit rejects what the reader could not parse back ------------------------
# Rejection is loud (ERROR + rc 1) and writes nothing to stdout: a half-written
# marker is worse than none, because the reader cannot tell it is half-written.
nl_out=$(marker_emit KEY "$(printf 'a\nb')" 2>/dev/null); nl_rc=$?
assert "改行入りの値は拒否される (rc)" "1" "$nl_rc"
assert "改行入りの値は stdout に何も書かない" "" "$nl_out"
semi_out=$(marker_emit KEY "a;b" 2>/dev/null); semi_rc=$?
assert "';' 入りの値は拒否される (rc)" "1" "$semi_rc"
assert "';' 入りの値は stdout に何も書かない" "" "$semi_out"
semif_out=$(marker_emit KEY ok "f=a;b" 2>/dev/null); semif_rc=$?
assert "';' 入りの field 値は拒否される (rc)" "1" "$semif_rc"
assert "';' 入りの field 値は stdout に何も書かない" "" "$semif_out"
badkey_rc=0; marker_emit "BAD KEY" v >/dev/null 2>&1 || badkey_rc=$?
assert "不正な KEY は拒否される" "1" "$badkey_rc"
badfield_rc=0; marker_emit KEY v "no-equals-sign" >/dev/null 2>&1 || badfield_rc=$?
assert "'=' の無い追加引数は拒否される" "1" "$badfield_rc"
badfname_rc=0; marker_emit KEY v "bad name=v" >/dev/null 2>&1 || badfname_rc=$?
assert "不正な field 名は拒否される" "1" "$badfname_rc"
noval_rc=0; marker_emit KEY >/dev/null 2>&1 || noval_rc=$?
assert "VALUE 欠落は拒否される" "1" "$noval_rc"
badarg_rc=0; printf '%s\n' 'x' | marker_get KEY --nope >/dev/null 2>&1 || badarg_rc=$?
assert "marker_get の不明な引数は拒否される" "1" "$badarg_rc"

# --- Input without a trailing newline is not silently dropped -----------------
assert "末尾改行の無い最終行も読まれる" "ok" \
  "$(printf '%s' '[CONTEXT] ITERATE_CB=ok' | marker_get ITERATE_CB)"
# Assert the exit code, not the output: a hang produces empty stdout too, so an
# output-only assertion passes whether or not the loop terminates.
_timeout 5 bash -c "source '$LIB'; printf '%s' 'not a marker' | marker_get ITERATE_CB" >/dev/null 2>&1
loop_rc=$?
assert "末尾改行の無い非 marker 行で無限ループしない (rc≠124)" "0" "$loop_rc"

# --- T-08 (AC-6): no direct [CONTEXT] echo left in skills/iterate/SKILL.md ----
# Anchored on the emit idiom, not on the string `[CONTEXT]`: the branch tables,
# the placeholder legend and the routing prose all name markers and must survive.
# A count of 0 only means something if the pattern can reach 1, so the pattern is
# pinned in both directions against inline fixtures below — not against git
# history, which would resolve to the post-change file once this lands and turn
# the "it can still fire" check permanently red.
ITERATE_SKILL="$REPO_ROOT/plugins/rite/skills/iterate/SKILL.md"
EMIT_IDIOM='(echo|printf)[[:space:]]+([^|;&]*[[:space:]])?["'"'"']?\[CONTEXT\]'
assert "T-08 grep が直接 echo emit を検出する (positive)" "1" \
  "$(printf '%s\n' 'echo "[CONTEXT] ITERATE_CB=ok; cycle=1"' | grep -cE "$EMIT_IDIOM" || true)"
assert "T-08 grep が printf 経由の emit も検出する (positive)" "1" \
  "$(printf '%s\n' "printf '%s\\\\n' \"[CONTEXT] ITERATE_CB=ok\"" | grep -cE "$EMIT_IDIOM" || true)"
assert "T-08 grep は marker を語る散文・分岐表を拾わない (negative)" "0" \
  "$(printf '%s\n' '| `[CONTEXT] ITERATE_CB=fire` | 発火 (ステップ 6 へ) |' | grep -cE "$EMIT_IDIOM" || true)"
assert "T-08 grep は共有関数の呼び出しを拾わない (negative)" "0" \
  "$(printf '%s\n' 'marker_emit ITERATE_CB fire "cycle=1"' | grep -cE "$EMIT_IDIOM" || true)"
if assert_file_exists_or_fail "T-08 iterate/SKILL.md が存在する" "$ITERATE_SKILL"; then
  direct_emits=$(grep -cE "$EMIT_IDIOM" "$ITERATE_SKILL" || true)
  assert "T-08 iterate/SKILL.md に共有関数を経由しない emit が無い (AC-6)" "0" "$direct_emits"

  # The shared-function call sites must actually exist — "0 direct emits"
  # would also be satisfied by deleting every marker from the file.
  # Anchored at line start so the prose line that *names* marker_emit is not
  # counted as a call — otherwise deleting one real emit would still pass.
  shared_emits=$(grep -cE '^[[:space:]]*marker_emit[[:space:]]' "$ITERATE_SKILL" || true)
  if [ "$shared_emits" -ge 6 ]; then
    pass "T-08 iterate/SKILL.md が marker_emit を 6 箇所以上呼ぶ ($shared_emits)"
  else
    fail "T-08 iterate/SKILL.md の marker_emit 呼び出しが不足 ($shared_emits < 6)"
  fi
fi

if ! print_summary "$(basename "${BASH_SOURCE[0]}")" \
  "marker 契約 (行頭アンカー / 複数行耐性 / branch スコープ / recency / 後方互換 / 書式) は本ファイルが SoT。SKILL.md 散文へ規約を書き戻さないこと。"; then
  exit 1
fi
