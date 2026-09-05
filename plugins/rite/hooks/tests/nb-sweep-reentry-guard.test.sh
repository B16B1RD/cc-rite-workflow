#!/bin/bash
# Contract tests for persistent NB sweep re-entry guard.
#
# T-01 5.S entry: file exists → skipped, no collect / no --nb-sweep invoke in that branch
# T-02 empty collect writes noop; write-failure must not leave a skip file
# T-03 --nb-sweep return never uses step-4 generic table to re-enter step 1
# T-04 done-file writers (iterate post-return + fix 1.3.S empty + digest)
# T-05 cleanup rite_rm AND pr-cycle-cleanup.sh both name the file
# T-06 fix 5.1 row 1.5/1.6; regular loop does not consult the file
# T-07 existing nb-sweep-contract rails remain; 5.0.2 has skipped; 0.6 run-start deletes the file
# T-08 AC-6 sidecar _ensure_dir_gitignore + setup dir_entry; git check-ignore -q rc=0
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"

PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
ITERATE="$PLUGIN_ROOT/skills/iterate/SKILL.md"
FIX="$PLUGIN_ROOT/skills/fix/SKILL.md"
SETUP="$PLUGIN_ROOT/skills/setup/SKILL.md"
CLEANUP_SKILL="$PLUGIN_ROOT/skills/cleanup/SKILL.md"
# cleanup ステップ 6 の state 削除は helper へ抽出済み。sweep 行の pin はそちらを見る。
STATE_PURGE="$PLUGIN_ROOT/hooks/scripts/cleanup-pr-state-purge.sh"
PR_CYCLE="$PLUGIN_ROOT/hooks/scripts/pr-cycle-cleanup.sh"
SCHEMA="$PLUGIN_ROOT/references/review-result-schema.md"
CONTRACT="$PLUGIN_ROOT/hooks/tests/nb-sweep-contract.test.sh"

echo "=== nb-sweep re-entry guard ==="

assert_file_exists_or_fail "iterate skill" "$ITERATE" || true
assert_file_exists_or_fail "fix skill" "$FIX" || true
assert_file_exists_or_fail "setup skill" "$SETUP" || true
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
assert_grep_in_section "T-01 skip predicate polarity is file exists" "$ITERATE" \
  '## ステップ 5.S: NB digest sweep' '## ステップ 5: 完了通知' \
  'if \[ -f "\$nb_done_file" \]'
then_collect=$(awk '
  /## ステップ 5.S: NB digest sweep/ {sec=1}
  sec && /## ステップ 5: 完了通知/ {exit}
  sec && /if \[ -f / && /nb_done_file/ && $0 !~ /! -f/ {thenb=1; next}
  thenb && /^else$/ {exit}
  thenb && /nb-sweep-collect\.sh/ {hit=1}
  END { print hit+0 }
' "$ITERATE")
assert "T-01 then branch has no collect helper" "0" "$then_collect"
assert_not_grep "T-01 no conversation-marker skip" "$ITERATE" '既出ならステップ 5'
assert_grep_in_section "T-01 skip authority is file only" "$ITERATE" \
  '## ステップ 5.S: NB digest sweep' '## ステップ 5: 完了通知' \
  'skip 判定はファイル存在のみ'

# --- T-02: empty → noop ファイル write。失敗時はファイルを残さない（偽 skip 禁止） ---
assert_grep_in_section "T-02 empty writes noop" "$ITERATE" \
  '## ステップ 5.S: NB digest sweep' '## ステップ 5: 完了通知' \
  "printf 'noop"
assert_grep_in_section "T-02 write-fail removes skip file" "$ITERATE" \
  '## ステップ 5.S: NB digest sweep' '## ステップ 5: 完了通知' \
  'rm -f "\$nb_done_file"'
noop_rm=$(awk '
  /## ステップ 5.S: NB digest sweep/ {sec=1}
  sec && /## ステップ 5: 完了通知/ {exit}
  sec && /printf .noop/ {p=1}
  p && /rm -f / && /nb_done_file/ {hit=1}
  p && $0 ~ /^[[:space:]]*fi$/ {exit}
  END { print hit+0 }
' "$ITERATE")
assert "T-02 empty-collect write-fail rm is in noop then" "1" "$noop_rm"

# --- T-03: --nb-sweep 戻りはステップ 4 汎用表を使わず、pushed でもステップ 1 に戻らない ---
assert_grep_in_section "T-03 no generic step-4 table after sweep invoke" "$ITERATE" \
  '## ステップ 5.S: NB digest sweep' '## ステップ 5: 完了通知' \
  'ステップ 4 の汎用表を使わず'
assert_grep_in_section "T-03 step-4 defers nb-sweep returns" "$ITERATE" \
  '## ステップ 4: fix sentinel を判定' '## ステップ 5.S: NB digest sweep' \
  '経由の戻りは本表を使わない'
assert_grep "T-03 overview defers nb-sweep from step-4" "$ITERATE" '経由は 5.S 専用表'
assert_grep_in_section "T-03 unexpected sweep return stops" "$ITERATE" \
  '## ステップ 5.S: NB digest sweep' '## ステップ 5: 完了通知' \
  '\[iterate:nb-sweep-error\].*停止'
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
assert_grep "T-05 cleanup rite_rm" "$STATE_PURGE" 'nb-sweep-done-\$\{pr_number\}\.txt'
# cleanup ステップ 6 が state purge helper を呼んでいること（sweep 行が helper 側に移ったため、
# 呼び出しが外れると T-05 が helper 内の行だけを見て通り続ける空振りになる）
assert_grep "T-05 cleanup invokes the state purge helper" "$CLEANUP_SKILL" 'hooks/scripts/cleanup-pr-state-purge\.sh'
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

# --- T-08: AC-6 gitignore — sidecar * + setup nested 3-line。git check-ignore -q rc=0 ---
assert_grep_in_section "T-08 setup Phase 4.6 calls nested gitignore helper" "$SETUP" \
  '## Phase 4.6:' '## Phase 4.7:' \
  '_ensure_rite_nested_gitignore'
iter_ensure=$(awk '/## ステップ 5.S: NB digest sweep/,/## ステップ 5: 完了通知/' "$ITERATE" \
  | grep -c '_ensure_dir_gitignore' || true)
assert "T-08 5.S has two _ensure_dir_gitignore calls" "2" "$iter_ensure"
iter_src=$(awk '/## ステップ 5.S: NB digest sweep/,/## ステップ 5: 完了通知/' "$ITERATE" \
  | grep -c 'gitignore-ensure.sh' || true)
assert "T-08 5.S sources gitignore-ensure in each write block" "2" "$iter_src"
fix_ensure=$(awk '/### 1.3.S `--nb-sweep` consume/,/### 1.4 Display Comment List/' "$FIX" \
  | grep -c '_ensure_dir_gitignore' || true)
assert "T-08 fix 1.3.S has two _ensure_dir_gitignore calls" "2" "$fix_ensure"
fix_src=$(awk '/### 1.3.S `--nb-sweep` consume/,/### 1.4 Display Comment List/' "$FIX" \
  | grep -c 'gitignore-ensure.sh' || true)
assert "T-08 fix 1.3.S sources gitignore-ensure in each write block" "2" "$fix_src"

# shellcheck source=../gitignore-ensure.sh
source "$PLUGIN_ROOT/hooks/gitignore-ensure.sh"
gi_sbx=$(make_sandbox)
gi_file=".rite/state/nb-sweep-done-2435.txt"
mkdir -p "$gi_sbx/.rite/state"
_ensure_dir_gitignore "$gi_sbx/.rite/state"
printf 'noop\n' > "$gi_sbx/$gi_file"
gi_rc=0
git -C "$gi_sbx" check-ignore -q "$gi_file" || gi_rc=$?
assert "T-08 sidecar git check-ignore -q rc=0" "0" "$gi_rc"
git -C "$gi_sbx" add -A
gi_staged=$(git -C "$gi_sbx" diff --cached --name-only | grep -c 'nb-sweep-done' || true)
assert "T-08 sidecar git add -A does not stage nb-sweep-done" "0" "$gi_staged"
rm -rf -- "$gi_sbx"

gi_setup=$(make_sandbox)
mkdir -p "$gi_setup/.rite/state"
_ensure_rite_nested_gitignore "$gi_setup/.rite"
printf 'noop\n' > "$gi_setup/$gi_file"
gi_setup_rc=0
git -C "$gi_setup" check-ignore -q "$gi_file" || gi_setup_rc=$?
assert "T-08 nested 3-line git check-ignore -q rc=0 for nb-sweep-done" "0" "$gi_setup_rc"
git -C "$gi_setup" add -A
gi_setup_staged=$(git -C "$gi_setup" diff --cached --name-only | grep -c 'nb-sweep-done' || true)
assert "T-08 nested 3-line git add -A does not stage nb-sweep-done" "0" "$gi_setup_staged"
rm -rf -- "$gi_setup"

# --- T-09 / AC-7: 2 行 done-file でも 5.S skip と fix 1.5 は 1 行時と同一 ---
# 既存 T-06〜T-08 は残す。本 ID は 2 行化回帰。
assert_grep_in_section "T-09 iterate 5.S still uses head -1" "$ITERATE" \
  '## ステップ 5.S: NB digest sweep' '## ステップ 5: 完了通知' \
  'head -1 "\$nb_done_file"'
assert_grep_in_section "T-09 fix 1.5 still uses -f" "$FIX" \
  '### 5.1 Output Pattern' '### 5.2 Standalone Execution Behavior' \
  '\[ -f "\$_nb_done_root/.rite/state/nb-sweep-done-'
two_line_sbx=$(make_sandbox)
mkdir -p "$two_line_sbx/.rite/state"
two_line_file="$two_line_sbx/.rite/state/nb-sweep-done-2439.txt"
printf 'done\n%s\n' 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' > "$two_line_file"
skipped_kind=$(head -1 "$two_line_file" | tr -d '[:space:]')
assert "T-09 head -1 of 2-line file is done" "done" "$skipped_kind"
if [ -f "$two_line_file" ]; then two_line_present=1; else two_line_present=0; fi
assert "T-09 -f of 2-line file is 1" "1" "$two_line_present"
rm -rf -- "$two_line_sbx"

# New sweep writers keep a one-line done marker and never grant a new HEAD.
sweep_section=$(awk '/^### 1.3.S `--nb-sweep` consume/,/^### 1.4 Display Comment List/' "$FIX")
assert "T-10 no fixed count or git command in sweep" "0" "$(printf '%s\n' "$sweep_section" | grep -cE 'nb_sweep_fixed|git (rev-parse|commit|push|add)' || true)"
assert_grep_in_section "T-10 digest writes one-line done" "$FIX" \
  '### 1.3.S `--nb-sweep` consume' '### 1.4 Display Comment List' \
  "printf 'done"
assert "T-10 no SHA printf in sweep" "0" "$(printf '%s\n' "$sweep_section" | grep -c 'done\\n%s' || true)"

if ! print_summary "$(basename "$0")" "nb-sweep re-entry guard drift — iterate 5.S / fix 1.3.S / cleanup / 0.6"; then
  exit 1
fi
