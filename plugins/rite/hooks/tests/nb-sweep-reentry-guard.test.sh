#!/bin/bash
# Contract tests for persistent NB sweep re-entry guard (#2433).
#
# T-01 5.S entry: file exists → skipped, no collect / no --nb-sweep invoke in that branch
# T-02 empty collect writes noop; write-failure must not leave a skip file
# T-03 --nb-sweep return never uses step-4 generic table to re-enter step 1
# T-04 done-file writers (iterate post-return + fix 1.3.S empty + digest)
# T-05 cleanup rite_rm AND pr-cycle-cleanup.sh both name the file
# T-06 fix 5.1 row 1.5/1.6; regular loop does not consult the file
# T-07 existing nb-sweep-contract rails remain; 5.0.2 has skipped; 0.6 run-start deletes the file
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"

PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
ITERATE="$PLUGIN_ROOT/skills/iterate/SKILL.md"
FIX="$PLUGIN_ROOT/skills/fix/SKILL.md"
CLEANUP_SKILL="$PLUGIN_ROOT/skills/cleanup/SKILL.md"
PR_CYCLE="$PLUGIN_ROOT/hooks/scripts/pr-cycle-cleanup.sh"
SCHEMA="$PLUGIN_ROOT/references/review-result-schema.md"
CONTRACT="$PLUGIN_ROOT/hooks/tests/nb-sweep-contract.test.sh"

echo "=== nb-sweep re-entry guard (#2433) ==="

assert_file_exists_or_fail "iterate skill" "$ITERATE" || true
assert_file_exists_or_fail "fix skill" "$FIX" || true
assert_file_exists_or_fail "cleanup skill" "$CLEANUP_SKILL" || true
assert_file_exists_or_fail "pr-cycle-cleanup.sh" "$PR_CYCLE" || true

# --- T-01: 5.S 入口はファイル存在で skipped、同一ブロックで collect/--nb-sweep に進まない ---
assert_grep "T-01 done-file path in 5.S" "$ITERATE" 'nb-sweep-done-\{pr_number\}\.txt'
assert_grep "T-01 skipped emit" "$ITERATE" 'marker_emit ITERATE_NB_SWEEP skipped'
assert_grep "T-01 already_done reason" "$ITERATE" 'reason=already_done'
# collect は skipped の else 側。入口 if [ -f done-file ] の後に collect が来る合成を pin
assert_grep_in_section "T-01 file-guard precedes collect" "$ITERATE" \
  '## ステップ 5.S: NB digest sweep' '## ステップ 5: 完了通知' \
  'nb_done_file=.*nb-sweep-done'
assert_grep_in_section "T-01 skipped branch skips collect helper" "$ITERATE" \
  '## ステップ 5.S: NB digest sweep' '## ステップ 5: 完了通知' \
  'nb-sweep-collect.sh'

# --- T-02: empty → noop ファイル write。失敗時はファイルを残さない（偽 skip 禁止） ---
assert_grep_in_section "T-02 empty writes noop" "$ITERATE" \
  '## ステップ 5.S: NB digest sweep' '## ステップ 5: 完了通知' \
  "printf 'noop"
assert_grep_in_section "T-02 write-fail removes skip file" "$ITERATE" \
  '## ステップ 5.S: NB digest sweep' '## ステップ 5: 完了通知' \
  'rm -f "\$nb_done_file"'

# --- T-03: --nb-sweep 戻りはステップ 4 汎用表を使わず、pushed でもステップ 1 に戻らない ---
assert_grep_in_section "T-03 no generic step-4 table after sweep invoke" "$ITERATE" \
  '## ステップ 5.S: NB digest sweep' '## ステップ 5: 完了通知' \
  'ステップ 4 の汎用表を使わず'
assert_grep_in_section "T-03 pushed after sweep goes to step 5" "$ITERATE" \
  '## ステップ 5.S: NB digest sweep' '## ステップ 5: 完了通知' \
  '\[fix:pushed\].*ステップ 5'
assert_grep_in_section "T-03 pushed-wm-stale after sweep goes to step 5" "$ITERATE" \
  '## ステップ 5.S: NB digest sweep' '## ステップ 5: 完了通知' \
  '\[fix:pushed-wm-stale\].*ステップ 5'
assert_grep_in_section "T-03 replied-only after sweep goes to step 5" "$ITERATE" \
  '## ステップ 5.S: NB digest sweep' '## ステップ 5: 完了通知' \
  '\[fix:replied-only\].*ステップ 5'
assert_grep "T-03 existing sweep-done→step 5 rail" "$ITERATE" '\[fix:sweep-done\].*ステップ 5'
assert_grep "T-03 existing MUST NOT second 5.S" "$ITERATE" '同一 PR で 5.S を 2 回'
assert_grep "T-03 existing step-1 ban" "$ITERATE" 'ステップ 1 に戻らない'

# --- T-04: done ファイルの書き手 ---
assert_grep_in_section "T-04 iterate post-return writes done" "$ITERATE" \
  '## ステップ 5.S: NB digest sweep' '## ステップ 5: 完了通知' \
  "printf 'done"
assert_grep_in_section "T-04 fix empty writes noop" "$FIX" \
  '### 1.3.S `--nb-sweep` consume' '### 1.4 Display Comment List' \
  "printf 'noop"
assert_grep_in_section "T-04 fix digest writes done" "$FIX" \
  '### 1.3.S `--nb-sweep` consume' '### 1.4 Display Comment List' \
  "printf 'done"
assert_grep "T-04 fix 1.3.S done-file path" "$FIX" 'nb-sweep-done-\{pr_number\}\.txt'

# --- T-05: cleanup と pr-cycle-cleanup の両方 ---
assert_grep "T-05 cleanup rite_rm" "$CLEANUP_SKILL" 'nb-sweep-done-\$\{pr_number\}\.txt'
assert_grep "T-05 pr-cycle-cleanup deletes marker" "$PR_CYCLE" 'nb-sweep-done-'
assert_grep "T-05 schema lists the file" "$SCHEMA" 'nb-sweep-done-\{pr_number\}\.txt'

# --- T-06: fix 5.1 行 1.5/1.6。通常ループはファイル非参照 ---
assert_grep_in_section "T-06 row 1.5 conjunction" "$FIX" \
  '### 5.1 Output Pattern' '### 5.2 Standalone Execution Behavior' \
  'NB_SWEEP=1.*NB_SWEEP_RESULT=done'
assert_grep_in_section "T-06 row 1.5 file alternative" "$FIX" \
  '### 5.1 Output Pattern' '### 5.2 Standalone Execution Behavior' \
  'NB_SWEEP_DONE_FILE=1'
assert_grep_in_section "T-06 row 1.6 missing done is error" "$FIX" \
  '### 5.1 Output Pattern' '### 5.2 Standalone Execution Behavior' \
  'NB_SWEEP=1.*NB_SWEEP_RESULT=done 以外'
# 通常ループ（1.3 Classify / 5.1 通常行）が done-file パスを参照しない:
# 5.1 の sweep 行以外で nb-sweep-done が出ないことを、1.3 分類表セクションで確認
assert_not_grep "T-06 classify table ignores done-file" "$FIX" \
  '1.3 Classify Comments(.|\n)*nb-sweep-done'
# より狭い: 1.3 見出し〜1.3.S 直前にファイルパスが無い
classify_hit=$(awk '/^### 1.3 Classify Comments/,/^### 1.3.S/' "$FIX" | grep -c 'nb-sweep-done' || true)
assert "T-06 1.3 classify has no done-file refs" "0" "$classify_hit"

# --- T-07: 既存 rails + skipped 完了通知 + 0.6 で新 run 時に削除 ---
assert_grep "T-07 existing noop emit rail" "$ITERATE" 'marker_emit ITERATE_NB_SWEEP noop'
assert_grep "T-07 existing contract test still pins 5.S rails" "$CONTRACT" 'T-07 iterate no second sweep'
assert_grep_in_section "T-07 5.0.2 skipped row" "$ITERATE" \
  '### ステップ 5.0.2:' '### 正常終了 (`\[review:mergeable\]`)' \
  'ITERATE_NB_SWEEP=skipped'
assert_grep_in_section "T-07 0.6 deletes done-file on new run" "$ITERATE" \
  '## ステップ 0.6:' '## ステップ 1:' \
  'nb-sweep-done-{pr_number}.txt'

if ! print_summary "$(basename "$0")" "nb-sweep re-entry guard drift — iterate 5.S / fix 1.3.S / cleanup / 0.6"; then
  exit 1
fi
