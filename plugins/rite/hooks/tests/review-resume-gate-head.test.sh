#!/bin/bash
# review-resume-gate-head.test.sh
#
# iterate/SKILL.md の review-cycle-resume-gate が、凍結 context の HEAD と現 HEAD を
# 照合してから早期 exit することを pin する（T-01 / T-02）。
#
# ゲートはテストへコピーせず SKILL.md から literal 抽出して実行する。コピーすると
# SKILL.md 側の変更が反映されず drift するため、max-review-cycles-default.test.sh と
# 同じ抽出実行方式を取る。抽出アンカーが壊れたらテスト自体が FATAL で落ちる。
#
# 早期 exit の観測条件は「exit 0 かつ REVIEW_RESUME=1 を出す」。単に exit code を見るだけでは
# 不一致経路（exit せず後続へ落ちる = ブロック末尾まで走って 0 で終わる）と区別できない。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
ITERATE="$PLUGIN_ROOT/skills/iterate/SKILL.md"

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

assert_file_exists_or_fail "iterate/SKILL.md exists" "$ITERATE" || exit 1

# --- SKILL.md から再開ガードを抽出 ---------------------------------------------

GATE="$TEST_DIR/gate.sh"
awk '/^# review-cycle-resume-gate$/{f=1} f{print} f&&/^    marker_emit ITERATE_ABANDON "\$abandon_state" "cycle=\$cc" "status=\$cycle_status"$/{g=1} g&&/^fi$/{exit}' \
  "$ITERATE" > "$GATE"

gate_lines=$(wc -l < "$GATE")
if [ "$gate_lines" -lt 30 ] || [ "$gate_lines" -gt 80 ]; then
  fail "resume gate extraction is implausible ($gate_lines 行)。抽出アンカーが壊れている可能性があります"
  print_summary "$(basename "$0")" "抽出アンカー: '# review-cycle-resume-gate' 〜 refused / done 側の marker_emit 直後の 'fi'"
  exit 1
fi
assert_grep "extracted gate reads the frozen commit_sha" "$GATE" 'review_context\.commit_sha'
assert_grep "extracted gate reads the current HEAD" "$GATE" 'git rev-parse HEAD'

# 抽出した本文は `bash {plugin_root}/hooks/flow-state.sh get` を呼ぶ。テストでは state を
# 直接与えたいので、その 1 行だけを固定の読み取りへ差し替える（他行は literal のまま）。
RUNNER="$TEST_DIR/runner.sh"
{
  printf '%s\n' '#!/bin/bash'
  printf '%s\n' 'marker_emit() { local key="$1" value="$2"; shift 2; printf "[CONTEXT] %s=%s" "$key" "$value"; for f in "$@"; do printf "; %s" "$f"; done; printf "\n"; }'
  printf '%s\n' 'neutralize_ctrl() { cat; }'
  printf '%s\n' 'cc=1'
  printf '%s\n' 'max_cycles=15'
  # state の読み取りと放棄呼び出しだけを差し替える。他は SKILL.md の literal のまま走らせる。
  # 放棄は $ABANDON_RC / $ABANDON_OUT で結果を与え、成功時は $STATE_FILE_AFTER へ切り替える。
  sed -e 's#^review_state=\$(bash {plugin_root}/hooks/flow-state\.sh get --jq-filter \.) || exit 1$#review_state=$(cat "$STATE_FILE") || exit 1#' \
      -e 's#^      review_state=\$(bash {plugin_root}/hooks/flow-state\.sh get --jq-filter \.) || exit 1$#      review_state=$(cat "${STATE_FILE_AFTER:-$STATE_FILE}") || exit 1#' \
      -e 's#^    if abandon_out=\$(LC_ALL=C bash {plugin_root}/hooks/flow-state\.sh review-abandon \\$#    if abandon_out=$(printf "%s" "${ABANDON_OUT:-}"; exit "${ABANDON_RC:-0}") \\#' \
      -e 's#^      bash {plugin_root}/hooks/flow-state\.sh set --phase "\$iteration_phase" .*|| handoff_clear=failed$#      ( exit "${HANDOFF_CLEAR_RC:-0}" ) || handoff_clear=failed#' \
      -e 's#^      --reason "HEAD changed before any evidence was recorded" 2>&1); then$#      ; then#' \
      -e 's#{issue_number}#99#g' "$GATE"
  # 放棄後の state 読み直しが生きているかは iteration_phase にしか現れないので、
  # 後段が読む値をそのまま出す。読み直しを消すと古い phase が出て固定が落ちる。
  printf '%s\n' 'echo "FELL_THROUGH=1; ITERATE_PHASE=${iteration_phase:-}"'
} > "$RUNNER"

assert_not_grep "runner has no unsubstituted placeholder" "$RUNNER" '{plugin_root}'

# --- git fixture ---------------------------------------------------------------

REPO="$TEST_DIR/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" -c user.email=test@example.com -c user.name=test commit -q --allow-empty -m first
FROZEN_HEAD=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" -c user.email=test@example.com -c user.name=test commit -q --allow-empty -m second
CURRENT_HEAD=$(git -C "$REPO" rev-parse HEAD)

make_state() {
  # $1 = commit_sha to freeze, $2 = cycle status
  jq -n --arg sha "$1" --arg status "$2" \
    '{phase:"review", cycle_count:1,
      review_cycle:{status:$status, review_context:{commit_sha:$sha, pr_number:99, cycle_count:1}}}'
}

run_gate() {
  # $1 = commit_sha to freeze, $2 = cycle status
  make_state "$1" "$2" > "$TEST_DIR/state.json"
  ( cd "$REPO" && STATE_FILE="$TEST_DIR/state.json" bash "$RUNNER" 2>&1 )
}

# --- T-02: 同一 HEAD の再開は従来どおり早期 exit --------------------------------

out=$(run_gate "$CURRENT_HEAD" collecting); rc=$?
if [ "$rc" -eq 0 ]; then pass "T-02 same-HEAD resume exits 0"; else fail "T-02 same-HEAD resume exits 0 (rc=$rc)"; fi
case "$out" in
  *"REVIEW_RESUME=1"*) pass "T-02 same-HEAD resume emits REVIEW_RESUME=1" ;;
  *) fail "T-02 same-HEAD resume emits REVIEW_RESUME=1 (出力: $out)" ;;
esac
case "$out" in
  *"FELL_THROUGH=1"*) fail "T-02 same-HEAD resume must not fall through to the lost gate" ;;
  *) pass "T-02 same-HEAD resume stops at the gate" ;;
esac
case "$out" in
  *"ITERATE_RESUME_HEAD=match"*) pass "T-02 same-HEAD resume reports match" ;;
  *) fail "T-02 same-HEAD resume reports match (出力: $out)" ;;
esac

# completed でも同一 HEAD なら従来どおり（既存 cycle の続行経路を弱めない）。
out=$(run_gate "$CURRENT_HEAD" completed)
case "$out" in
  *"REVIEW_RESUME=1"*) pass "T-02 same-HEAD completed cycle still resumes" ;;
  *) fail "T-02 same-HEAD completed cycle still resumes (出力: $out)" ;;
esac

# --- T-01: HEAD 不一致では早期 exit せず後段へ落ちる -----------------------------

for status in collecting completed; do
  out=$(run_gate "$FROZEN_HEAD" "$status"); rc=$?
  if [ "$rc" -eq 0 ]; then pass "T-01 changed-HEAD ($status) does not error out"; else fail "T-01 changed-HEAD ($status) does not error out (rc=$rc)"; fi
  case "$out" in
    *"REVIEW_RESUME=1"*) fail "T-01 changed-HEAD ($status) must not emit REVIEW_RESUME=1 (出力: $out)" ;;
    *) pass "T-01 changed-HEAD ($status) suppresses REVIEW_RESUME" ;;
  esac
  case "$out" in
    *"FELL_THROUGH=1"*) pass "T-01 changed-HEAD ($status) reaches the lost repair gate" ;;
    *) fail "T-01 changed-HEAD ($status) reaches the lost repair gate (出力: $out)" ;;
  esac
  case "$out" in
    *"ITERATE_RESUME_HEAD=changed"*) pass "T-01 changed-HEAD ($status) reports the mismatch" ;;
    *) fail "T-01 changed-HEAD ($status) reports the mismatch (出力: $out)" ;;
  esac
done

# 放棄は lost 修復ゲートの前に、その結果に依存せず走る。後段へ移すと前 cycle の JSON が
# 残る経路で放棄されず、どの道も review-start の HEAD 一致要求で止まる。
out=$(run_gate "$FROZEN_HEAD" collecting)
case "$out" in
  *"ITERATE_ABANDON=done"*) pass "collecting mismatch abandons before the lost gate is evaluated" ;;
  *) fail "collecting mismatch abandons before the lost gate is evaluated (出力: $out)" ;;
esac
out=$(run_gate "$FROZEN_HEAD" completed)
case "$out" in
  *"ITERATE_ABANDON"*) fail "completed mismatch must not be abandoned (出力: $out)" ;;
  *) pass "completed mismatch is left for the receipt path" ;;
esac

# helper を実行できないときは証跡の有無を判定できていないので、放棄も再レビューも成立しない。
make_state "$FROZEN_HEAD" collecting > "$TEST_DIR/state.json"
out=$( cd "$REPO" && STATE_FILE="$TEST_DIR/state.json" ABANDON_RC=127 \
  ABANDON_OUT="bash: line 1: flow-state.sh: No such file or directory" bash "$RUNNER" 2>&1 ); rc=$?
if [ "$rc" -ne 0 ]; then pass "unavailable abandon stops the loop"; else fail "unavailable abandon stops the loop (rc=$rc, 出力: $out)"; fi
case "$out" in
  *"ITERATE_ABANDON=unavailable"*) pass "unavailable abandon is reported as such" ;;
  *) fail "unavailable abandon is reported as such (出力: $out)" ;;
esac
case "$out" in
  *"FELL_THROUGH=1"*) fail "unavailable abandon must not fall through" ;;
  *) pass "unavailable abandon stops before the lost gate" ;;
esac

# 停止する前に handoff を落とす。Stop hook の consume-handoff は jq とシェルだけで動くので、
# helper を実行できない版 skew でも handoff は消費され、/rite:pr-review が再注入されて
# 未放棄の cycle のままゲートを迂回する。落とせたか落とせなかったかを marker に残す。
case "$out" in
  *"HANDOFF_CLEAR=ok"*) pass "the unavailable stop clears the handoff" ;;
  *) fail "the unavailable stop clears the handoff (出力: $out)" ;;
esac

out=$( cd "$REPO" && STATE_FILE="$TEST_DIR/state.json" ABANDON_RC=127 HANDOFF_CLEAR_RC=1 \
  ABANDON_OUT="bash: line 1: flow-state.sh: No such file or directory" bash "$RUNNER" 2>&1 ); rc=$?
case "$out" in
  *"HANDOFF_CLEAR=failed"*) pass "a failed handoff clear is reported rather than assumed" ;;
  *) fail "a failed handoff clear is reported rather than assumed (出力: $out)" ;;
esac
case "$out" in
  *"handoff を落とせませんでした"*) pass "a failed handoff clear warns about the bypass it leaves" ;;
  *) fail "a failed handoff clear warns about the bypass it leaves (出力: $out)" ;;
esac

# 放棄は phase を pr へ戻す。後段の set が古い phase を書き戻さないよう、ガードは state を
# 読み直して iteration_phase を作り直す。読み直しを消しても気づけるよう、放棄後の state を
# 差し替えて、再計算された phase がそちらから来ることを固定する。
make_state "$FROZEN_HEAD" collecting > "$TEST_DIR/state.json"
jq '.phase = "pr" | del(.review_cycle)' "$TEST_DIR/state.json" > "$TEST_DIR/state-after.json"
out=$( cd "$REPO" && STATE_FILE="$TEST_DIR/state.json" \
  STATE_FILE_AFTER="$TEST_DIR/state-after.json" ABANDON_RC=0 bash "$RUNNER" 2>&1 ); rc=$?
case "$out" in
  *"ITERATE_PHASE=pr"*) pass "the phase is recomputed from the state the abandon left" ;;
  *) fail "the phase is recomputed from the state the abandon left (出力: $out)" ;;
esac

# helper が証跡を検出して拒否したときは、断定してよいのはこの枝だけ。
out=$( cd "$REPO" && STATE_FILE="$TEST_DIR/state.json" ABANDON_RC=1 \
  ABANDON_OUT='ERROR: review-cycle: "cycle retains evidence at manifest_path=/x.json"' bash "$RUNNER" 2>&1 ); rc=$?
case "$out" in
  *"ITERATE_ABANDON=refused"*) pass "evidence-bearing refusal is reported as refused" ;;
  *) fail "evidence-bearing refusal is reported as refused (出力: $out)" ;;
esac
if [ "$rc" -eq 0 ]; then pass "refused abandon still falls through to the lost gate"; else fail "refused abandon still falls through (rc=$rc)"; fi

case "$out" in
  *"FELL_THROUGH=1"*) pass "refused abandon reaches the lost gate" ;;
  *) fail "refused abandon reaches the lost gate (出力: $out)" ;;
esac

# --- 判定不能は HEAD 変更と混同せず停止 -----------------------------------------

jq -n '{phase:"review", cycle_count:1,
        review_cycle:{status:"collecting", review_context:{pr_number:99, cycle_count:1}}}' \
  > "$TEST_DIR/state.json"
out=$( cd "$REPO" && STATE_FILE="$TEST_DIR/state.json" bash "$RUNNER" 2>&1 ); rc=$?
if [ "$rc" -ne 0 ]; then pass "missing frozen commit_sha stops the gate"; else fail "missing frozen commit_sha stops the gate (rc=$rc, 出力: $out)"; fi
case "$out" in
  *"ITERATE_RESUME_HEAD=undecidable"*) pass "missing frozen commit_sha is reported as undecidable" ;;
  *) fail "missing frozen commit_sha is reported as undecidable (出力: $out)" ;;
esac
case "$out" in
  *"FELL_THROUGH=1"*) fail "undecidable must not fall through to the lost gate" ;;
  *) pass "undecidable stops before the lost gate" ;;
esac

# 非 git ディレクトリでは現 HEAD を取れない → HEAD 変更と区別できないので停止する。
NOGIT="$TEST_DIR/nogit"
mkdir -p "$NOGIT"
make_state "$CURRENT_HEAD" collecting > "$TEST_DIR/state.json"
out=$( cd "$NOGIT" && STATE_FILE="$TEST_DIR/state.json" bash "$RUNNER" 2>&1 ); rc=$?
if [ "$rc" -ne 0 ]; then pass "unreadable HEAD stops the gate"; else fail "unreadable HEAD stops the gate (rc=$rc, 出力: $out)"; fi
case "$out" in
  *"reason=git_head_failed"*) pass "unreadable HEAD names its reason" ;;
  *) fail "unreadable HEAD names its reason (出力: $out)" ;;
esac

# --- mutation: HEAD 照合を外すと T-01 が落ちること -------------------------------

MUTANT="$TEST_DIR/mutant.sh"
sed 's#^  if \[ "\$current_head" = "\$frozen_head" \]; then$#  if true; then#' "$RUNNER" > "$MUTANT"
if assert_mutant_changed "HEAD comparison removal" "$RUNNER" "$MUTANT"; then
  make_state "$FROZEN_HEAD" collecting > "$TEST_DIR/state.json"
  mut_out=$( cd "$REPO" && STATE_FILE="$TEST_DIR/state.json" bash "$MUTANT" 2>&1 )
  case "$mut_out" in
    *"REVIEW_RESUME=1"*) pass "HEAD comparison removal is detected by T-01" ;;
    *) fail "HEAD comparison removal is detected by T-01 (mutant 出力: $mut_out)" ;;
  esac
fi

if ! print_summary "$(basename "$0")" \
  "再開ガードの本体は plugins/rite/skills/iterate/SKILL.md が SoT。本テストは抽出して実行する。"; then
  exit 1
fi
