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
PR_CYCLE="$PLUGIN_ROOT/hooks/scripts/pr-cycle-cleanup.sh"
SCHEMA="$PLUGIN_ROOT/references/review-result-schema.md"
CONTRACT="$PLUGIN_ROOT/hooks/tests/nb-sweep-contract.test.sh"

echo "=== nb-sweep re-entry guard (#2433) ==="

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
# 既存 T-06〜T-08 は残す。本 ID は #2439 の 2 行化回帰。
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

# --- T-10 / AC-5: 1.3.S ステップ 6 は {nb_sweep_fixed}>=1 の then に限り 2 行 printf ---
assert_grep_in_section "T-10 nb_sweep_fixed placeholder" "$FIX" \
  '### 1.3.S `--nb-sweep` consume' '### 1.4 Display Comment List' \
  'nb_sweep_fixed="{nb_sweep_fixed}"'
assert_grep_in_section "T-10 numeric gate -ge 1" "$FIX" \
  '### 1.3.S `--nb-sweep` consume' '### 1.4 Display Comment List' \
  '\[ "\$nb_sweep_fixed" -ge 1 \]'
ge1_has_two_line=$(awk '
  /### 1.3.S `--nb-sweep` consume/ {sec=1}
  sec && /### 1.4 Display Comment List/ {exit}
  sec && /nb_sweep_fixed="-ge 1"|nb_sweep_fixed" -ge 1/ {thenb=1}
  thenb && /printf .done\\n%s\\n/ {hit=1}
  thenb && /git rev-parse HEAD/ {rev=1}
  thenb && /^[[:space:]]*else$/ {if (!hit) miss=1; thenb=0}
  END { print (hit+0) "," (rev+0) }
' "$FIX")
assert "T-10 -ge 1 then has 2-line printf and rev-parse" "1,1" "$ge1_has_two_line"
nonnum=$(awk '
  /### 1.3.S `--nb-sweep` consume/ {sec=1}
  sec && /### 1.4 Display Comment List/ {exit}
  sec && /nb_sweep_fixed="/ {w=1}
  w && /\[!0-9\]/ {p=1}
  p && /printf .done.n/ && $0 !~ /%s/ {hit=1}
  p && /^[[:space:]]*;;$/ {exit}
  END { print hit+0 }
' "$FIX")
assert "T-10 non-numeric branch writes 1-line done" "1" "$nonnum"
nonnum_warn=$(awk '
  /### 1.3.S `--nb-sweep` consume/ {sec=1}
  sec && /### 1.4 Display Comment List/ {exit}
  sec && /nb_sweep_fixed="/ {w=1}
  w && /\[!0-9\]/ {p=1}
  p && /WARNING: nb_sweep_fixed/ {hit=1}
  p && /^[[:space:]]*;;$/ {exit}
  END { print hit+0 }
' "$FIX")
assert "T-12 non-numeric branch emits WARNING" "1" "$nonnum_warn"
assert_grep_in_section "T-12 non-numeric WARNING names received value" "$FIX" \
  '### 1.3.S `--nb-sweep` consume' '### 1.4 Display Comment List' \
  "WARNING: nb_sweep_fixed が数値ではありません \\(received:"
rev_fail=$(awk '
  /### 1.3.S `--nb-sweep` consume/ {sec=1}
  sec && /### 1.4 Display Comment List/ {exit}
  sec && /git rev-parse HEAD/ {g=1}
  g && /WARNING: git rev-parse HEAD/ {w=1}
  g && /printf .done\\n./ && $0 !~ /%s/ {one=1}
  END { print (w+0) "," (one+0) }
' "$FIX")
assert "T-10 rev-parse fail is WARNING + 1-line done" "1,1" "$rev_fail"

# --- T-11 / AC-6: push 無し（empty noop / fixed=0）は 1 行のまま ---
assert_grep_in_section "T-11 empty collect still writes noop" "$FIX" \
  '### 1.3.S `--nb-sweep` consume' '### 1.4 Display Comment List' \
  "printf 'noop"
# 外側 else（nb_sweep_fixed=0）だけを見る。内側 if/else（rev-parse 成否）は
# -ge 1 行と同じインデントの else/fi で切り、最初の else に誤ヒットしない。
# first-else に戻すと内側（既に 1 行）で hit し、外側 2 行化を見逃す。
t11_outer_else_one_line() {
  awk '
    /### 1.3.S `--nb-sweep` consume/ {sec=1}
    sec && /### 1.4 Display Comment List/ {exit}
    sec && /nb_sweep_fixed" -ge 1/ {
      ge=1
      match($0, /^[[:space:]]*/)
      indent = substr($0, RSTART, RLENGTH)
      next
    }
    ge && !el && $0 == indent "else" { el=1; next }
    el && /printf .done\\n./ && $0 !~ /%s/ {hit=1}
    el && $0 == indent "fi" {exit}
    END { print hit+0 }
  ' "$1"
}
t11_one_line_done_count() {
  awk '
    /### 1.3.S `--nb-sweep` consume/ {sec=1}
    sec && /### 1.4 Display Comment List/ {exit}
    sec && /printf .done\\n./ && $0 !~ /%s/ {n++}
    END { print n+0 }
  ' "$1"
}
zero_one_line=$(t11_outer_else_one_line "$FIX")
assert "T-11 fixed=0 else writes 1-line done" "1" "$zero_one_line"

t11_src="" t11_mut_outer="" t11_mut_inner=""
t11_src=$(mktemp) || { echo "ERROR: T-11 mktemp src failed" >&2; exit 1; }
t11_mut_outer=$(mktemp) || { rm -f "$t11_src"; echo "ERROR: T-11 mktemp outer failed" >&2; exit 1; }
t11_mut_inner=$(mktemp) || { rm -f "$t11_src" "$t11_mut_outer"; echo "ERROR: T-11 mktemp inner failed" >&2; exit 1; }
cp "$FIX" "$t11_src"
cp "$t11_src" "$t11_mut_outer"
cp "$t11_src" "$t11_mut_inner"
python3 - "$t11_mut_outer" "$t11_mut_inner" <<'PY'
import pathlib, sys
outer_path, inner_path = sys.argv[1], sys.argv[2]
outer = """      else
        if printf 'done\\n' > "$sweep_done_file"; then sweep_write_ok=1; fi
      fi"""
outer_2 = """      else
        if printf 'done\\n%s\\n' extra > "$sweep_done_file"; then sweep_write_ok=1; fi
      fi"""
inner = """          echo "WARNING: git rev-parse HEAD に失敗したため nb-sweep-done の 2 行目を書きません" >&2
          if printf 'done\\n' > "$sweep_done_file"; then sweep_write_ok=1; fi"""
inner_2 = """          echo "WARNING: git rev-parse HEAD に失敗したため nb-sweep-done の 2 行目を書きません" >&2
          if printf 'done\\n%s\\n' extra > "$sweep_done_file"; then sweep_write_ok=1; fi"""
p = pathlib.Path(outer_path)
text = p.read_text()
if outer not in text:
    raise SystemExit("T-11 outer else block not found")
p.write_text(text.replace(outer, outer_2, 1))
p = pathlib.Path(inner_path)
text = p.read_text()
if inner not in text:
    raise SystemExit("T-11 inner else block not found")
p.write_text(text.replace(inner, inner_2, 1))
PY
t11_py_rc=$?
if [ "$t11_py_rc" -ne 0 ]; then
  rm -f -- "$t11_src" "$t11_mut_outer" "$t11_mut_inner"
  echo "ERROR: T-11 mutation copy failed (rc=$t11_py_rc)" >&2
  exit 1
fi
if cmp -s "$t11_src" "$t11_mut_outer"; then t11_outer_changed=0; else t11_outer_changed=1; fi
assert "T-11 outer mutation changed the copy" "1" "$t11_outer_changed"
remain_outer=$(t11_one_line_done_count "$t11_mut_outer")
assert "T-11 outer mutation leaves inner and non-numeric 1-line printf" "2" "$remain_outer"
assert "T-11 outer 2-line else is hit=0" "0" "$(t11_outer_else_one_line "$t11_mut_outer")"
if cmp -s "$t11_src" "$t11_mut_inner"; then t11_inner_changed=0; else t11_inner_changed=1; fi
assert "T-11 inner mutation changed the copy" "1" "$t11_inner_changed"
assert "T-11 inner 2-line else is still hit=1" "1" "$(t11_outer_else_one_line "$t11_mut_inner")"
rm -f -- "$t11_src" "$t11_mut_outer" "$t11_mut_inner"

if ! print_summary "$(basename "$0")" "nb-sweep re-entry guard drift — iterate 5.S / fix 1.3.S / cleanup / 0.6"; then
  exit 1
fi
