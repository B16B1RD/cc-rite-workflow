#!/bin/bash
# Tests for batch-run resume-stage dispatch (skills/batch-run/SKILL.md ステップ 1.5)
#
# Purpose:
#   引数省略の再開で、止まった Issue の flow-state phase から再開段階を決める bash ブロックを
#   SKILL.md から抽出し、per-session flow-state fixture に対して実行して marker を固定する。
#   段階を決められない状態は open へ倒さず stop になることを含む。
#
# Test cases:
#   T-01 phase=ready / merge モード / PR あり → stage=merge（ready 化は完了済み）。ready_error → stage=ready
#   T-02 phase=review / fix → stage=iterate、pr= と branch= を運ぶ
#   T-03 phase=implement、flow-state が別 Issue / active=false / 不在 → stage=open
#   T-04 PR 以降の phase で PR 番号 0 / 空 → stop(pr_number_missing)。flow-state 読出失敗（helper 失敗 /
#        壊れた JSON）→ stop(state_read_failed)
#   T-05 default モードで phase=ready / cleanup → advance（ready / merge / cleanup を実行しない）
#   T-06 phase=cleanup / merge モード / branch 空 → stop(branch_missing)。ingest / completed / 未知 phase → stop
#   T-07 静的 pin: 分岐表が各 stage 値の行を持つ / ステップ 1 の process 行が 1.5 へ振る / ステップ 2 冒頭の
#        前提行 / ステップ 8 復旧行 / ステップ 1.5 の bash が gh を呼ばない / recover Phase 5.3 の phase 集合を
#        漏れなく扱う（集合が空なら FAIL）
#
# Usage: bash plugins/rite/hooks/tests/batch-run-resume-dispatch.test.sh
set -uo pipefail

unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL="$PLUGIN_ROOT/skills/batch-run/SKILL.md"
RECOVER="$PLUGIN_ROOT/skills/recover/SKILL.md"
HOOK="$PLUGIN_ROOT/hooks/flow-state.sh"
[ -f "$SKILL" ] || { echo "FATAL: target not found: $SKILL" >&2; exit 1; }

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/rite-brrd-test-XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM HUP

# SKILL.md から needle を含む bash ブロックを抽出する
extract_block() {
  awk -v needle="$1" '
    /^```bash$/ {inside=1; block=""; next}
    /^```$/ {if (inside && index(block, needle)) {printf "%s", block; exit}; inside=0}
    inside {block=block $0 "\n"}
  ' "$SKILL"
}
BLOCK="$TMP_ROOT/resume-stage.sh"
extract_block '# batch-run-resume-stage' > "$BLOCK"
assert_grep "抽出したブロックが RUN_RESUME_STAGE を出す" "$BLOCK" 'RUN_RESUME_STAGE='

# fixture: state root ごとに .rite-session-id と flow-state を置き、ブロックを実行して marker を返す
# $1=issue $2=mode $3=phase $4=pr $5=branch $6=active $7=state_issue（省略時は $1）
run_stage() {
  local issue=$1 mode=$2 phase=$3 pr=$4 branch=$5 active=$6 state_issue=${7:-$1}
  local root; root=$(mktemp -d "$TMP_ROOT/root-XXXXXX")
  local sid="sess-$RANDOM"
  mkdir -p "$root/.rite/sessions"
  # session_id は実行環境の runtime session ID から解決されるため、fixture ごとに env で与える
  (cd "$root" && RITE_STATE_ROOT="$root" CLAUDE_CODE_SESSION_ID="$sid" bash "$HOOK" set \
    --phase "$phase" --issue "$state_issue" --branch "$branch" --pr "$pr" --active "$active" \
    --next "fixture" >/dev/null 2>&1)
  local script="$root/block.sh"
  sed -e "s|{plugin_root}|$PLUGIN_ROOT|g" -e "s|{current_issue}|$issue|g" -e "s|{run_mode}|$mode|g" "$BLOCK" > "$script"
  (cd "$root" && RITE_STATE_ROOT="$root" CLAUDE_CODE_SESSION_ID="$sid" bash "$script" 2>/dev/null | grep -E '^\[CONTEXT\] RUN_RESUME_STAGE=' | tail -1)
}
stage_of() { printf '%s' "$1" | sed -n 's/^\[CONTEXT\] RUN_RESUME_STAGE=\([a-z_]*\);.*/\1/p'; }
field_of() { printf '%s' "$1" | sed -n "s/.*; $2=\([^;]*\).*/\1/p"; }

echo "--- T-01: phase=ready / merge / PR あり → merge、ready_error → ready ---"
out=$(run_stage 41 merge ready 900 fix/issue-41-x true)
assert "T-01 ready は merge（ready 化は完了済み）" merge "$(stage_of "$out")"
assert "T-01 pr を運ぶ" 900 "$(field_of "$out" pr)"
out=$(run_stage 41 merge ready_error 900 fix/issue-41-x true)
assert "T-01 ready_error は ready（再試行）" ready "$(stage_of "$out")"

echo "--- T-02: phase=review / fix → iterate ---"
out=$(run_stage 42 merge review 901 fix/issue-42-y true)
assert "T-02 review は iterate" iterate "$(stage_of "$out")"
assert "T-02 pr を運ぶ" 901 "$(field_of "$out" pr)"
assert "T-02 branch を運ぶ" fix/issue-42-y "$(field_of "$out" branch)"
out=$(run_stage 42 default fix 901 fix/issue-42-y true)
assert "T-02 fix は default でも iterate" iterate "$(stage_of "$out")"

echo "--- T-03: PR 作成前 / 別 Issue → open ---"
out=$(run_stage 43 merge implement 0 fix/issue-43-z true)
assert "T-03 implement は open" open "$(stage_of "$out")"
out=$(run_stage 43 merge pr 0 fix/issue-43-z true)
assert "T-03 pr は open" open "$(stage_of "$out")"
out=$(run_stage 43 merge review 902 fix/issue-99-w true 99)
assert "T-03 別 Issue の state は open" open "$(stage_of "$out")"
assert "T-03 別 Issue の reason" fresh_or_mismatched "$(field_of "$out" reason)"
out=$(run_stage 43 merge review 902 fix/issue-43-z false)
assert "T-03 active=false は open" open "$(stage_of "$out")"
# state 不在: fixture を set せずにブロックだけ実行する
absent_root=$(mktemp -d "$TMP_ROOT/absent-XXXXXX")
mkdir -p "$absent_root/.rite/sessions"
sed -e "s|{plugin_root}|$PLUGIN_ROOT|g" -e "s|{current_issue}|43|g" -e "s|{run_mode}|merge|g" "$BLOCK" > "$absent_root/block.sh"
out=$(cd "$absent_root" && RITE_STATE_ROOT="$absent_root" CLAUDE_CODE_SESSION_ID="sess-absent" bash block.sh 2>/dev/null | grep -E '^\[CONTEXT\] RUN_RESUME_STAGE=' | tail -1)
assert "T-03 state 不在は open" open "$(stage_of "$out")"
assert "T-03 state 不在の reason" fresh_or_mismatched "$(field_of "$out" reason)"

echo "--- T-04: 決められない状態は stop ---"
out=$(run_stage 44 merge ready 0 fix/issue-44-v true)
assert "T-04 PR 番号 0 は stop" stop "$(stage_of "$out")"
assert "T-04 reason=pr_number_missing" pr_number_missing "$(field_of "$out" reason)"
# flow-state.sh set --pr "" は pr_number: 0 を書くため、空文字は set 後に path の
# ファイルを直接書き換える（壊れた JSON fixture と同じ手順。run_stage は使わない）。
empty_root=$(mktemp -d "$TMP_ROOT/empty-pr-XXXXXX")
mkdir -p "$empty_root/.rite/sessions"
(cd "$empty_root" && RITE_STATE_ROOT="$empty_root" CLAUDE_CODE_SESSION_ID="sess-empty-pr" bash "$HOOK" set \
  --phase review --issue 44 --branch fix/issue-44-v --pr 905 --active true --next "fixture" >/dev/null 2>&1)
empty_path=$(cd "$empty_root" && RITE_STATE_ROOT="$empty_root" CLAUDE_CODE_SESSION_ID="sess-empty-pr" bash "$HOOK" path)
jq '.pr_number = ""' "$empty_path" > "$empty_path.tmp" && mv "$empty_path.tmp" "$empty_path"
sed -e "s|{plugin_root}|$PLUGIN_ROOT|g" -e "s|{current_issue}|44|g" -e "s|{run_mode}|merge|g" "$BLOCK" > "$empty_root/block.sh"
out=$(cd "$empty_root" && RITE_STATE_ROOT="$empty_root" CLAUDE_CODE_SESSION_ID="sess-empty-pr" bash block.sh 2>/dev/null | grep -E '^\[CONTEXT\] RUN_RESUME_STAGE=' | tail -1)
assert "T-04 PR 番号 空は stop" stop "$(stage_of "$out")"
assert "T-04 空の reason=pr_number_missing" pr_number_missing "$(field_of "$out" reason)"
assert "T-04 空の pr= は空文字（0 ではない）" "" "$(field_of "$out" pr)"
# 読出失敗 (a): state ファイルが壊れた JSON。flow-state.sh get は default を返して rc=0 で戻るため、
# ブロックがファイルを直接検査しないと open に倒れる
corrupt_root=$(mktemp -d "$TMP_ROOT/corrupt-XXXXXX")
mkdir -p "$corrupt_root/.rite/sessions"
(cd "$corrupt_root" && RITE_STATE_ROOT="$corrupt_root" CLAUDE_CODE_SESSION_ID="sess-corrupt" bash "$HOOK" set \
  --phase review --issue 44 --branch fix/issue-44-v --pr 905 --active true --next "fixture" >/dev/null 2>&1)
corrupt_path=$(cd "$corrupt_root" && RITE_STATE_ROOT="$corrupt_root" CLAUDE_CODE_SESSION_ID="sess-corrupt" bash "$HOOK" path)
printf '{not json' > "$corrupt_path"
sed -e "s|{plugin_root}|$PLUGIN_ROOT|g" -e "s|{current_issue}|44|g" -e "s|{run_mode}|merge|g" "$BLOCK" > "$corrupt_root/block.sh"
out=$(cd "$corrupt_root" && RITE_STATE_ROOT="$corrupt_root" CLAUDE_CODE_SESSION_ID="sess-corrupt" bash block.sh 2>/dev/null | grep -E '^\[CONTEXT\] RUN_RESUME_STAGE=' | tail -1)
assert "T-04 壊れた JSON は stop" stop "$(stage_of "$out")"
assert "T-04 壊れた JSON の reason=state_read_failed" state_read_failed "$(field_of "$out" reason)"
# 読出失敗 (b): flow-state.sh を壊れた helper に差し替える
broken_root=$(mktemp -d "$TMP_ROOT/broken-XXXXXX")
mkdir -p "$broken_root/hooks"
printf '#!/bin/bash\nexit 1\n' > "$broken_root/hooks/flow-state.sh"
broken_script="$broken_root/block.sh"
sed -e "s|{plugin_root}|$broken_root|g" -e "s|{current_issue}|44|g" -e "s|{run_mode}|merge|g" "$BLOCK" > "$broken_script"
out=$(bash "$broken_script" 2>/dev/null | grep -E '^\[CONTEXT\] RUN_RESUME_STAGE=' | tail -1)
assert "T-04 読出失敗は stop" stop "$(stage_of "$out")"
assert "T-04 reason=state_read_failed" state_read_failed "$(field_of "$out" reason)"

echo "--- T-05: default モードは ready / cleanup を実行しない ---"
out=$(run_stage 45 default ready 903 fix/issue-45-u true)
assert "T-05 default の ready は advance" advance "$(stage_of "$out")"
out=$(run_stage 45 default cleanup 903 fix/issue-45-u true)
assert "T-05 default の cleanup は advance" advance "$(stage_of "$out")"
out=$(run_stage 45 default ready_error 903 fix/issue-45-u true)
assert "T-05 default の ready_error は advance" advance "$(stage_of "$out")"
out=$(run_stage 45 merge cleanup 903 fix/issue-45-u true)
assert "T-05 merge の cleanup は cleanup" cleanup "$(stage_of "$out")"

echo "--- T-06: branch 空の cleanup / 未知 phase は stop ---"
out=$(run_stage 46 merge cleanup 904 "" true)
assert "T-06 merge で branch 空の cleanup は stop" stop "$(stage_of "$out")"
assert "T-06 reason=branch_missing" branch_missing "$(field_of "$out" reason)"
out=$(run_stage 46 merge completed 904 fix/issue-46-t true)
assert "T-06 completed は stop" stop "$(stage_of "$out")"
out=$(run_stage 46 merge ingest 904 fix/issue-46-t true)
assert "T-06 ingest は stop（recover 5.3 は wiki-ingest 再呼び出し）" stop "$(stage_of "$out")"
out=$(run_stage 46 merge bogus_phase 904 fix/issue-46-t true)
assert "T-06 未知 phase は stop" stop "$(stage_of "$out")"

echo "--- T-07: 静的 pin ---"
for s in open iterate ready merge cleanup advance stop; do
  assert_grep "T-07 分岐表に $s の行がある" "$SKILL" "^\\| \`$s\` \\| "
done
assert_grep "T-07 ステップ 1 の process 行は最初の process を 1.5 へ振る" "$SKILL" '^\| `process` \| .*run 起動後の最初の `process` はステップ 1\.5'
assert_grep "T-07 ステップ 2 は marker=open のときのみ" "$SKILL" 'ステップ 1\.5 の marker が `open` のときのみ実行する'
assert_grep "T-07 ステップ 8 の復旧行が 1.5 の再開段階判定を指す" "$SKILL" '^- 残りをまとめて再開: /rite:batch-run（.*ステップ 1\.5 が flow-state の phase から再開段階を決める'
assert_not_grep "T-07 ステップ 1.5 の bash は gh を呼ばない" "$BLOCK" '(^|[^a-z_])gh '
assert_grep "T-07 run 起動あたり 1 回だけ評価する" "$SKILL" 'run 起動後の最初の `RUN_NEXT=process` でのみ評価する'
assert_grep "T-07 stop 行は recover を案内する" "$SKILL" '^\| `stop` \| .*/rite:recover {current_issue}'
# recover Phase 5.3 の phase 集合を ステップ 1.5 の case が漏れなく扱う（既定 FS では $1 が行頭の | なので $2 を取る）
recover_phases=$(awk '/^### 5\.3 Phase enum/{f=1;next} f&&/^### /{exit} f&&/^\| `[a-z_]+` \|/{gsub(/[`| ]/,"",$2); print $2}' "$RECOVER" | sort -u)
recover_count=$(printf '%s\n' "$recover_phases" | grep -c '^[a-z_]\+$')
if [ "$recover_count" -gt 0 ]; then
  assert "T-07 recover 5.3 から phase を 1 件以上抽出した（空集合の pin を防ぐ）" 1 1
else
  assert "T-07 recover 5.3 から phase を 1 件以上抽出した（空集合の pin を防ぐ）" 1 0
fi
recover_table_count=$(awk '/^### 5\.3 Phase enum/{f=1;next} f&&/^### /{exit} f&&/^\| `[a-z_]+` \|/{c++} END{print c+0}' "$RECOVER")
assert "T-07 recover 5.3 の backtick phase 行数と抽出件数が一致する" "$recover_table_count" "$recover_count"
missing=""
for p in $recover_phases; do
  grep -qE "^[[:space:]]*([a-z_]+\|)*$p(\|[a-z_]+)*\)" "$BLOCK" || missing="$missing $p"
done
assert "T-07 recover 5.3 の phase を case が扱う（未扱い: ${missing:-なし}）" "" "$missing"

print_summary "$(basename "$0")"
