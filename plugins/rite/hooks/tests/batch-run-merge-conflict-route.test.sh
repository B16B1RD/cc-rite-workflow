#!/bin/bash
# Tests for the merge-time base conflict route (skills/merge/SKILL.md 非 MERGEABLE の再判定 /
# skills/batch-run/SKILL.md ステップ 5)
#
# Purpose:
#   merge が競合だけを他の未マージ理由と区別できる marker で返し、batch-run の merge 段が
#   その marker を伴う not-ready のときだけ base 取り込み → iterate へ戻ることを固定する。
#   marker を伴わない not-ready / error / sentinel 不在は従来どおり停止に残る。
#
# Test cases:
#   T-01 batch-run ステップ 5 の競合行が汎用 not-ready 行より前にあり、draft 戻し → phase=fix →
#        base 取り込み → ステップ 3 の順で経路を持つ。orchestration コメントも同じ経路を持つ
#   T-02 marker なしの not-ready・[merge:error]・sentinel 不在がステップ 8 に対応付けられたまま
#   T-03 merge の再判定 bash を gh stub で実行: CONFLICTING のときだけ [merge:not-ready] の次行に
#        marker を出し、UNKNOWN / gh 失敗 / MERGEABLE では出さない。gh pr view は 1 回だけ。
#        gh 失敗は not-ready・非ゼロ終了・ERROR 診断で止まる。
#        marker は再判定ブロックの外に書かれていない
#
# Usage: bash plugins/rite/hooks/tests/batch-run-merge-conflict-route.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BATCH="$PLUGIN_ROOT/skills/batch-run/SKILL.md"
MERGE="$PLUGIN_ROOT/skills/merge/SKILL.md"
for f in "$BATCH" "$MERGE"; do
  [ -f "$f" ] || { echo "FATAL: target not found: $f" >&2; exit 1; }
done

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/rite-brmc-test-XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM HUP

# ステップ 5 の節（見出しから次の見出しまで）を切り出す
STEP5="$TMP_ROOT/step5.md"
awk '/^## ステップ 5: /{s=1} s && /^## ステップ 6: /{exit} s' "$BATCH" > "$STEP5"
[ -s "$STEP5" ] || { echo "FATAL: batch-run ステップ 5 の節を切り出せません" >&2; exit 1; }

line_of() { grep -n -E "$1" "$STEP5" | head -1 | cut -d: -f1; }

echo "--- T-01: 競合行が base 取り込み経路へ進む ---"
conflict_row=$(line_of '^\| `\[merge:not-ready\]` \+ `\[CONTEXT\] MERGE_NOT_READY=conflicting` \|.*ステップ 3 へ戻る')
generic_row=$(line_of '^\| `MERGE_NOT_READY=conflicting` を伴わない `\[merge:not-ready\]`')
if [ -n "$conflict_row" ] && [ -n "$generic_row" ] && [ "$conflict_row" -lt "$generic_row" ]; then
  pass "T-01 競合行は汎用 not-ready 行より前にある"
else
  fail "T-01 競合行が汎用 not-ready 行より前にない (conflict=$conflict_row generic=$generic_row)"
fi
undo_line=$(line_of '^1\. `gh pr ready \{pr_number\} -R \{owner_repo\} --undo`')
phase_line=$(line_of 'flow-state.sh set --phase fix --issue \{current_issue\}')
intake_line=$(line_of '^2\. \[fix-plan の base 取り込み\]\(\.\./fix/references/fix-plan\.md#base-取り込み\)')
back_line=$(line_of '^3\. ステップ 3（iterate）へ戻る')
if [ -n "$undo_line" ] && [ -n "$phase_line" ] && [ -n "$intake_line" ] && [ -n "$back_line" ] \
  && [ "$undo_line" -le "$phase_line" ] && [ "$phase_line" -lt "$intake_line" ] && [ "$intake_line" -lt "$back_line" ]; then
  pass "T-01 draft 戻し → phase=fix → base 取り込み → ステップ 3 の順"
else
  fail "T-01 経路の順序が崩れている (undo=$undo_line phase=$phase_line intake=$intake_line back=$back_line)"
fi
assert_grep "T-01 base 取り込みの停止条件はステップ 8" "$STEP5" '停止条件.*ステップ 8（段階=merge）'
assert_grep "T-01 再レビューのブレーカー停止はステップ 8 へ合流" "$STEP5" 'サーキットブレーカーで止まればステップ 3 の表でステップ 8 に合流'
assert_grep "T-01 orchestration コメントが競合経路を持つ" "$STEP5" \
  '<!-- run orchestration:.*MERGE_NOT_READY=conflicting -> revert to draft, base intake, then ステップ 3'

echo "--- T-02: 競合以外の not-ready は停止のまま ---"
assert_grep "T-02 marker なし not-ready / error / sentinel 不在はステップ 8" "$STEP5" \
  '^\| `MERGE_NOT_READY=conflicting` を伴わない `\[merge:not-ready\]` / `\[merge:error\]` / sentinel 不在 \| \*\*失敗\*\* → ステップ 8（段階=merge） \|$'
assert_not_grep "T-02 marker を条件にしない旧来の not-ready 行が残っていない" "$STEP5" \
  '^\| `\[merge:not-ready\]` / `\[merge:error\]`'
assert_grep "T-02 orchestration コメントで他の not-ready はステップ 8" "$STEP5" \
  'Any other not-ready / error / missing sentinel -> ステップ 8'

echo "--- T-03: merge は競合のときだけ理由 marker を出す ---"
BLOCK="$TMP_ROOT/rematch.sh"
awk '
  /^```bash$/ {inside=1; block=""; next}
  /^```$/ {if (inside && index(block, "# merge-rematch")) {printf "%s", block; exit}; inside=0}
  inside {block=block $0 "\n"}
' "$MERGE" > "$BLOCK"
assert_grep "T-03 再判定ブロックを抽出できる" "$BLOCK" '^# merge-rematch$'
assert_grep "T-03 抽出ブロックが not-ready を出す" "$BLOCK" '\[merge:not-ready\]'
assert_grep "T-03 抽出ブロックが競合 marker を出す" "$BLOCK" 'MERGE_NOT_READY=conflicting'
marker_total=$(grep -c 'echo "\[CONTEXT\] MERGE_NOT_READY=conflicting' "$MERGE" || true)
if [ "$marker_total" = 1 ]; then
  pass "T-03 marker の出力は再判定ブロックの 1 箇所だけ"
else
  fail "T-03 marker の出力箇所は 1 のはず (got=$marker_total)"
fi

# $1=gh stub の振る舞い (conflicting / unknown / mergeable / fail)
run_rematch() {
  local mode=$1 dir
  dir=$(mktemp -d "$TMP_ROOT/case-XXXXXX")
  mkdir -p "$dir/bin"
  cat > "$dir/bin/gh" <<'STUB'
#!/bin/bash
echo "$*" >> "$STUB_DIR/gh.log"
case "$STUB_MODE" in
  conflicting) m=CONFLICTING; st=DIRTY ;;
  unknown) m=UNKNOWN; st=UNKNOWN ;;
  mergeable) m=MERGEABLE; st=CLEAN ;;
  fail) echo "simulated gh failure" >&2; exit 1 ;;
esac
printf '{"mergeable":"%s","mergeStateStatus":"%s","isDraft":false,"headRefName":"fix/x","statusCheckRollup":[]}\n' "$m" "$st"
STUB
  chmod +x "$dir/bin/gh"
  : > "$dir/gh.log"
  sed -e 's|{pr_number}|77|g' -e 's|{owner_repo}|owner/repo|g' "$BLOCK" > "$dir/run.sh"
  STUB_DIR="$dir" STUB_MODE="$mode" PATH="$dir/bin:$PATH" bash "$dir/run.sh" > "$dir/out" 2> "$dir/err"
  echo "$?" > "$dir/rc"
  printf '%s' "$dir"
}

d=$(run_rematch conflicting)
out=$(cat "$d/out")
next_line=$(printf '%s\n' "$out" | awk 'prev=="[merge:not-ready]" {print; exit} {prev=$0}')
assert "T-03 CONFLICTING: not-ready の次行が marker" "[CONTEXT] MERGE_NOT_READY=conflicting; pr=77" "$next_line"
assert "T-03 CONFLICTING: 非ゼロ終了" 1 "$(cat "$d/rc")"
assert "T-03 CONFLICTING: gh pr view は 1 回だけ" 1 "$(grep -c '^pr view ' "$d/gh.log")"

for mode in unknown fail mergeable; do
  d=$(run_rematch "$mode")
  assert "T-03 $mode: marker を出さない" 0 "$(grep -c 'MERGE_NOT_READY' "$d/out")"
done
d=$(run_rematch fail)
assert "T-03 gh 失敗: not-ready は出す" 1 "$(grep -c '^\[merge:not-ready\]$' "$d/out")"
assert "T-03 gh 失敗: 非ゼロ終了" 1 "$(cat "$d/rc")"
assert "T-03 gh 失敗: ERROR 診断を出す" 1 "$(grep -c '^ERROR: 再判定で PR 状態を取得できない' "$d/err")"
d=$(run_rematch unknown)
assert "T-03 UNKNOWN: not-ready は出す" 1 "$(grep -c '^\[merge:not-ready\]$' "$d/out")"
d=$(run_rematch mergeable)
assert "T-03 MERGEABLE: not-ready を出さず続行" 0 "$(grep -c 'merge:not-ready' "$d/out")"
assert "T-03 MERGEABLE: 成功終了" 0 "$(cat "$d/rc")"

echo "--- BEHIND: specific failure classification and recovery ---"
behind_row=$(line_of '^\| `\[merge:error\]` \+ `\[CONTEXT\] MERGE_ERROR=behind`')
if [ -n "$behind_row" ] && [ -n "$generic_row" ] && [ "$behind_row" -lt "$generic_row" ]; then
  pass "BEHIND error is classified before the generic error stop"
else
  fail "BEHIND error must precede the generic row (behind=$behind_row generic=$generic_row)"
fi
assert_grep "BEHIND stops at step 8" "$STEP5" 'MERGE_ERROR=behind.*\*\*失敗\*\*.*ステップ 8'
STOP="$TMP_ROOT/stop.md"
awk '/^## ステップ 8: /{s=1} s' "$BATCH" > "$STOP"
assert_grep "BEHIND replaces generic recover/retry instructions" "$STOP" 'MERGE_ERROR=behind.*汎用復旧 2 行.*置き換える'
assert_grep "BEHIND draft and base intake precede review" "$STOP" '^> 1\..*draft 戻し → phase=fix.*base 取り込み.*検証・Wiki 適用証跡の取り直し・commit・head 更新・push'
assert_grep "BEHIND reviewed head and CI are required before ready" "$STOP" '^> 2\..*/rite:iterate.*全 CI job.*完了・成功.*rite:ready'
assert_grep "BEHIND resumes queue only after recovery" "$STOP" '^> 3\..*取り込み・再レビュー・CI 確認・ready.*完了した後.*rite:batch-run --merge'
assert_grep "failed recovery does not restart the queue" "$STOP" '未完のままキューを再開しない'

print_summary
