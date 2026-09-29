#!/bin/bash
# Contract tests for persistent NB sweep re-entry guard.
#
# 5.S / 0.6 のシェル本体は scripts/iterate-step.sh の step_nb_sweep_collect / step_nb_sweep_record /
# step_init_cycle 関数にある。コード片はその関数範囲、分岐表・散文は SKILL.md の節を見る。
#
# T-01 5.S entry: skipped only when line 1 field 2 equals the latest review JSON basename;
#      the skip branch runs neither collect nor --nb-sweep, the other branch calls collect
# T-02 empty collect writes noop; write-failure must not leave a skip file
# T-03 --nb-sweep return never uses step-4 generic table to re-enter step 1
# T-04 done-file writers (iterate post-return + fix 1.3.S empty + digest)
# T-05 cleanup rite_rm AND pr-cycle-cleanup.sh both name the file
# T-06 fix 5.1 row 1.5/1.6; regular loop does not consult the file
# T-07 existing nb-sweep-contract rails remain; 5.0.2 has skipped; step_init_cycle (0.6) has the
#      line that removes the file (the removal on a fresh run is executed in
#      review-trend-divergence.test.sh; the removal on a resume whose counter is 0, the keep on a
#      resume with a nonzero counter and the review-restart removal are not pinned by any test)
# T-08 AC-6 sidecar _ensure_dir_gitignore + setup dir_entry; git check-ignore -q rc=0
# T-09 kind is line 1 field 1; fix 5.1 never treats the file's existence alone as done
# T-10 sweep writers keep a one-line done marker and never add a SHA or run git
# T-11 5.S entry executed: skip only on basename match; latest JSON is the lexical tail, not
#      the mtime max; a missing record removes an existing file instead of leaving a rangeless one
# T-12 fix 5.1 reader, the digest writer and the iterate post-return writer executed: each
#      picks the lexical tail even when another JSON has the newer mtime
# T-13 nb-sweep-resume（iterate ステップ 0.7）を dispatch 経由で実行する。分岐ごとに marker 値・reason・rc・
#      入口記録の存否を見る（無し / basename 不一致 / HEAD 不一致 / commit_sha 読めず / 値不正 / 一致）
# T-14 nb-sweep-collect は --sweep-origin を dispatch で検証し、pending のときだけ入口記録を 1 行で書く。
#      書けなければ pending を出さない。noop / skipped と nb-sweep-record は入口記録を消す
# T-15 fix の手順 1: 残った entries が今回の record のものなら起票を飛ばす marker を出し、他の record の
#      ものなら起票も persist も始めずに止まる。empty 経路は entries から件数を数えて entries を消す
# T-16 fix の手順 4: entries の判定列から件数を数え（セル内のエスケープ済みパイプでずれない）、entries を消す
# T-17 iterate SKILL の配線: 0.7 は 0.6 と 1 の間、resume は 5.S へ、collect に入口を単一引用で渡す。
#      0.6（step_init_cycle）は入口記録と entries を消さない
# T-18 採否ゲートが保留した sweep（done なし・入口記録あり）は 0.7 で resume、collect は pending で入口記録を残す。
#      done を書く nb-sweep-record は [fix:sweep-done] の後だけで、[fix:error] の行は停止する
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"

PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
ITERATE="$PLUGIN_ROOT/skills/iterate/SKILL.md"
ITERATE_STEP="$PLUGIN_ROOT/scripts/iterate-step.sh"
FIX="$PLUGIN_ROOT/skills/fix/SKILL.md"
# fix 5.1 の NB_SWEEP_DONE_FILE 判定のコード片は scripts/fix-step.sh の step_nb_sweep_done_file にある
FIX_STEP="$PLUGIN_ROOT/scripts/fix-step.sh"
FIX_SWEEP="$PLUGIN_ROOT/skills/fix/references/nb-sweep.md"
SETUP="$PLUGIN_ROOT/skills/setup/SKILL.md"
CLEANUP_SKILL="$PLUGIN_ROOT/skills/cleanup/SKILL.md"
# cleanup ステップ 6 の state 削除は helper へ抽出済み。sweep 行の pin はそちらを見る。
STATE_PURGE="$PLUGIN_ROOT/hooks/scripts/cleanup-pr-state-purge.sh"
PR_CYCLE="$PLUGIN_ROOT/hooks/scripts/pr-cycle-cleanup.sh"
SCHEMA="$PLUGIN_ROOT/references/review-result-schema.md"
CONTRACT="$PLUGIN_ROOT/hooks/tests/nb-sweep-contract.test.sh"

echo "=== nb-sweep re-entry guard ==="

assert_file_exists_or_fail "iterate skill" "$ITERATE" || true
assert_file_exists_or_fail "iterate-step.sh" "$ITERATE_STEP" || true
assert_file_exists_or_fail "fix skill" "$FIX" || true
assert_file_exists_or_fail "setup skill" "$SETUP" || true
assert_file_exists_or_fail "cleanup skill" "$CLEANUP_SKILL" || true
assert_file_exists_or_fail "pr-cycle-cleanup.sh" "$PR_CYCLE" || true

# --- T-01: 5.S 入口は第 2 フィールドが最新 JSON の basename と一致するときだけ skipped。
#     skip 分岐では collect/--nb-sweep に進まず、それ以外は collect を呼ぶ ---
assert_grep_in_section "T-01 done-file path in 5.S" "$ITERATE_STEP" \
  '^step_nb_sweep_collect[(][)] [{]$' '^}$' \
  'nb-sweep-done-\$pr_number\.txt'
assert_grep_in_section "T-01 skipped emit" "$ITERATE_STEP" \
  '^step_nb_sweep_collect[(][)] [{]$' '^}$' \
  'marker_emit ITERATE_NB_SWEEP skipped'
assert_grep_in_section "T-01 already_done reason" "$ITERATE_STEP" \
  '^step_nb_sweep_collect[(][)] [{]$' '^}$' \
  'reason=already_done'
assert_grep_in_section "T-01 file-guard precedes collect" "$ITERATE_STEP" \
  '^step_nb_sweep_collect[(][)] [{]$' '^}$' \
  'nb_done_file=.*nb-sweep-done'
assert_grep_in_section "T-01 skipped branch skips collect helper" "$ITERATE_STEP" \
  '^step_nb_sweep_collect[(][)] [{]$' '^}$' \
  'nb-sweep-collect.sh'
assert_grep_in_section "T-01 skip predicate is recorded basename" "$ITERATE_STEP" \
  '^step_nb_sweep_collect[(][)] [{]$' '^}$' \
  'if \[ -n "\$nb_range" \] && \[ "\$nb_range" = "\$nb_latest_base" \]'
assert_grep_in_section "T-01 a sweep hold keeps the done JSON from being skipped" "$ITERATE_STEP" \
  '^step_nb_sweep_collect[(][)] [{]$' '^}$' \
  '&& \[ ! -e "\$nb_root/.rite/state/adoption-hold-\$pr_number-sweep.json" \]; then'
then_collect=$(awk '
  /^step_nb_sweep_collect\(\) \{$/ {sec=1}
  sec && /^}$/ {exit}
  sec && /if \[ -n "\$nb_range" \] && \[ "\$nb_range" = "\$nb_latest_base" \]/ {thenb=1; next}
  thenb && /^else$/ {exit}
  thenb && /nb-sweep-collect\.sh/ {hit=1}
  END { print hit+0 }
' "$ITERATE_STEP")
assert "T-01 match branch has no collect helper" "0" "$then_collect"
else_collect=$(awk '
  /^step_nb_sweep_collect\(\) \{$/ {sec=1}
  sec && /^}$/ {exit}
  sec && /if \[ -n "\$nb_range" \] && \[ "\$nb_range" = "\$nb_latest_base" \]/ {thenb=1; next}
  thenb && /^else$/ {elseb=1; next}
  elseb && /nb-sweep-collect\.sh/ {hit=1}
  END { print hit+0 }
' "$ITERATE_STEP")
assert "T-01 mismatch else calls collect helper" "1" "$else_collect"
assert_not_grep "T-01 no conversation-marker skip" "$ITERATE" '既出ならステップ 5'
assert_grep_in_section "T-01 skip authority is basename match" "$ITERATE" \
  '## ステップ 5.S: NB digest sweep' '## ステップ 5: 完了通知' \
  '第 2 フィールドが最新 review JSON の basename と一致し、sweep の保留ファイルが無いときだけ'
# fix を invoke するかは marker 表だけが決める。件数 0 の pending（止まった sweep の片付け）を no-op と読ませない
assert_grep_in_section "T-01 fix is skipped only for noop / skipped (table decides)" "$ITERATE" \
  '## ステップ 5.S: NB digest sweep' '## ステップ 5: 完了通知' \
  '`noop` / `skipped` では fix を invoke しない（下表）'
assert_not_grep "T-01 no count-zero no-op rule" "$ITERATE" '対象 0 (件)?は no-op'

# --- T-02: empty → noop ファイル write。失敗時はファイルを残さない（偽 skip 禁止） ---
assert_grep_in_section "T-02 empty writes noop basename" "$ITERATE_STEP" \
  '^step_nb_sweep_collect[(][)] [{]$' '^}$' \
  "printf 'noop %s\\\\n"
assert_grep_in_section "T-02 write-fail removes skip file" "$ITERATE_STEP" \
  '^step_nb_sweep_collect[(][)] [{]$' '^}$' \
  'rm -f "\$nb_done_file"'
noop_rm=$(awk '
  /^step_nb_sweep_collect\(\) \{$/ {sec=1}
  sec && /^}$/ {exit}
  sec && /printf .noop/ {p=1}
  p && /rm -f / && /nb_done_file/ {hit=1}
  p && $0 ~ /^[[:space:]]*fi$/ {exit}
  END { print hit+0 }
' "$ITERATE_STEP")
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
assert_grep_in_section "T-03 sweep-done from --nb-sweep goes to in-PR recommendation fix, never step 1" "$ITERATE" \
  '## ステップ 5.S: NB digest sweep' '## ステップ 5: 完了通知' \
  '^\| `\[fix:sweep-done\]` \| PR 内推奨の修正。ステップ 1 に戻らない'
assert_grep "T-03 existing MUST NOT second 5.S" "$ITERATE" '同一 review JSON で 5\.S を 2 回'
assert_grep "T-03 existing step-1 ban" "$ITERATE" 'ステップ 1 に戻らない'

# --- T-04: done ファイルの書き手 ---
assert_grep_in_section "T-04 iterate post-return writes done basename" "$ITERATE_STEP" \
  '^step_nb_sweep_record[(][)] [{]$' '^}$' \
  "printf 'done %s\\\\n"
# 起票の無い sweep は noop、台帳 persist 後に止まった sweep は done（kind は変数で渡す。T-15 が両方を実行で確かめる）
assert_grep_in_section "T-04 fix empty writes kind basename" "$FIX_SWEEP" \
  '### 1.3.S `--nb-sweep` consume' '### 1.4 Display Comment List' \
  "printf '%s %s\\\\n' \"\\\$nb_kind\""
assert_grep_in_section "T-04 fix empty uses collect record" "$FIX_SWEEP" \
  '### 1.3.S `--nb-sweep` consume' '### 1.4 Display Comment List' \
  'jq -r '"'"'.record // empty'"'"
assert_grep_in_section "T-04 fix digest writes done basename" "$FIX_SWEEP" \
  '### 1.3.S `--nb-sweep` consume' '### 1.4 Display Comment List' \
  "printf 'done %s\\\\n"
assert_grep_in_section "T-04 fix consume is not gated on missing file" "$FIX_SWEEP" \
  '### 1.3.S `--nb-sweep` consume' '### 1.4 Display Comment List' \
  'あっても consume を skip しない'
assert_grep "T-04 fix 1.3.S done-file path" "$FIX_SWEEP" 'nb-sweep-done-\{pr_number\}\.txt'

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

# --- T-07: 既存 rails + skipped 完了通知 + 0.6 の step_init_cycle に done ファイル削除行がある ---
assert_grep "T-07 existing noop emit rail" "$ITERATE_STEP" 'marker_emit ITERATE_NB_SWEEP noop'
assert_grep "T-07 existing contract test still pins 5.S rails" "$CONTRACT" 'T-07 iterate no second sweep'
assert_grep_in_section "T-07 5.0.2 skipped row" "$ITERATE" \
  '### ステップ 5.0.2:' '### 正常終了 (`\[review:mergeable\]`)' \
  'ITERATE_NB_SWEEP=skipped'
assert_grep_in_section "T-07 step_init_cycle has done-file rm line" "$ITERATE_STEP" \
  '^step_init_cycle[(][)] [{]$' '^}$' \
  'rm -f "\$pin_root/\.rite/state/nb-sweep-done-\$\{pr_number\}\.txt"'

# --- T-08: AC-6 gitignore — sidecar * + setup nested 3-line。git check-ignore -q rc=0 ---
assert_grep_in_section "T-08 setup Phase 4.6 calls nested gitignore helper" "$SETUP" \
  '## Phase 4.6:' '## Phase 4.7:' \
  '_ensure_rite_nested_gitignore'
# 5.S の書き込みブロックは collect（noop 書き込みと pending の入口記録）と record（done 書き込み）の 3 箇所。
iter_5s_bodies() {
  awk '/^step_nb_sweep_(collect|record)\(\) \{$/,/^}$/' "$ITERATE_STEP"
}
iter_ensure=$(iter_5s_bodies | grep -c '_ensure_dir_gitignore' || true)
assert "T-08 5.S has three _ensure_dir_gitignore calls" "3" "$iter_ensure"
iter_src=$(iter_5s_bodies | grep -c '^[[:space:]]*source .*gitignore-ensure.sh' || true)
assert "T-08 5.S sources gitignore-ensure in each write block" "3" "$iter_src"
fix_ensure=$(awk '/### 1.3.S `--nb-sweep` consume/,/### 1.4 Display Comment List/' "$FIX_SWEEP" \
  | grep -c '_ensure_dir_gitignore' || true)
assert "T-08 fix 1.3.S has two _ensure_dir_gitignore calls" "2" "$fix_ensure"
fix_src=$(awk '/### 1.3.S `--nb-sweep` consume/,/### 1.4 Display Comment List/' "$FIX_SWEEP" \
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

# --- T-09: kind は第 1 フィールド。fix 5.1 は -f 単独を成功にしない ---
assert_grep_in_section "T-09 iterate kind is field 1" "$ITERATE_STEP" \
  '^step_nb_sweep_collect[(][)] [{]$' '^}$' \
  'awk '"'"'NR==1 \{ print \$1 \}'"'"
assert_grep_in_section "T-09 fix 1.5 matches recorded basename" "$FIX_STEP" \
  '^step_nb_sweep_done_file[(][)] [{]$' '^}$' \
  'if \[ -n "\$_nb_range" \] && \[ "\$_nb_range" = "\$_nb_latest_base" \]; then'
fix_dash_f=$(awk '/^step_nb_sweep_done_file\(\) \{$/,/^}$/' "$FIX_STEP" | grep -c '\[ -f "\$_nb_done_root' || true)
assert "T-09 fix 5.1 no longer treats -f alone as done" "0" "$fix_dash_f"

# New sweep writers keep a one-line done marker and never grant a new HEAD.
sweep_section=$(awk '/^### 1.3.S `--nb-sweep` consume/,/^### 1.4 Display Comment List/' "$FIX_SWEEP")
assert "T-10 no fixed count or git command in sweep" "0" "$(printf '%s\n' "$sweep_section" | grep -cE 'nb_sweep_fixed|git (rev-parse|commit|push|add)' || true)"
assert_grep_in_section "T-10 digest writes one-line done basename" "$FIX_SWEEP" \
  '### 1.3.S `--nb-sweep` consume' '### 1.4 Display Comment List' \
  "printf 'done %s\\\\n"
assert "T-10 no SHA printf in sweep" "0" "$(printf '%s\n' "$sweep_section" | grep -c 'done\\n%s' || true)"
assert "T-10 digest write is not inside ! -f" "0" "$(printf '%s\n' "$sweep_section" | grep -c '! -f' || true)"

# --- T-11: 5.S 入口（step_nb_sweep_collect 関数）を抽出して実行する。述語はテスト内に再実装しない ---
entry_fence=$(awk '/^step_nb_sweep_collect\(\) \{$/{f=1} f{print} f && /^}$/{exit}' "$ITERATE_STEP")
[ -n "$entry_fence" ] || { echo "FAIL: T-11 entry fence missing"; exit 1; }
# 行数上限は終端アンカー (`^}$`) を取り逃して後続関数を巻き込む over-extraction を loud にする。
entry_lines=$(printf '%s\n' "$entry_fence" | wc -l | tr -d '[:space:]')
if [ "$entry_lines" -gt 130 ] || ! { _gq_out=$(tail -1 <<< "$entry_fence") && grep -qx '}' <<< "$_gq_out"; }; then
  echo "FAIL: T-11 entry fence extraction overran or lost its end anchor ($entry_lines lines)"; exit 1
fi
nb_collect_stub=$(mktemp "${TMPDIR:-/tmp}/rite-nb-collect-stub-XXXXXX")
cat > "$nb_collect_stub" <<'STUB'
#!/bin/bash
printf 'called\n' >> "${NB_COLLECT_LOG:?}"
if [ "${NB_STUB_RECORD:-}" = "missing" ]; then
  printf '%s\n' '{"status":"empty","count":0,"record":""}'
else
  rec=$(find "${NB_FIX_ROOT:?}/.rite/review-results" -maxdepth 1 -type f -name '42-*.json' | LC_ALL=C sort | tail -1)
  jq -nc --arg record "$rec" '{status:"empty",count:0,record:$record}'
fi
exit 0
STUB
chmod +x "$nb_collect_stub"
# 関数定義の前に引数と plugin_root を置き、末尾で呼ぶ。source 行は plugin_root で解決させ、
# 外部 helper 2 つだけを stub に差し替える。
render_entry() {
  printf 'pr_number=42\nplugin_root=%q\n' "$PLUGIN_ROOT"
  printf '%s\n' "$entry_fence" | sed \
    -e 's#bash "$plugin_root"/hooks/state-path-resolve.sh#printf %s "$NB_FIX_ROOT"#g' \
    -e "s#bash \"\$plugin_root\"/hooks/scripts/nb-sweep-collect.sh#bash \"$nb_collect_stub\"#g"
  printf 'step_nb_sweep_collect\n'
}
run_entry() {
  local label="$1" root out log
  root=$(make_sandbox)
  log="$root/collect.log"
  mkdir -p "$root/.rite/review-results" "$root/.rite/state"
  printf '{}\n' > "$root/.rite/review-results/42-20200101000000.json"
  printf '{}\n' > "$root/.rite/review-results/42-20200202000000.json"
  touch -d '2020-01-02 00:00:00' "$root/.rite/review-results/42-20200202000000.json" \
    || touch -t 202001020000 "$root/.rite/review-results/42-20200202000000.json"
  touch -d '2020-03-03 00:00:00' "$root/.rite/review-results/42-20200101000000.json" \
    || touch -t 202003030000 "$root/.rite/review-results/42-20200101000000.json"
  if [ -n "${2:-}" ]; then
    printf '%s\n' "$2" > "$root/.rite/state/nb-sweep-done-42.txt"
  fi
  out=$(NB_FIX_ROOT="$root" NB_COLLECT_LOG="$log" NB_STUB_RECORD="${3:-}" bash -c "$(render_entry)" 2>&1) || true
  printf '%s\n' "$out" > "$root/out.txt"
  echo "$root"
}
lexical_tail=42-20200202000000.json
mtime_max=42-20200101000000.json

match_root=$(run_entry match "$(printf 'done %s\n%s\n' "$lexical_tail" 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb')")
nb_mtime() { stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1"; }
nb_mtime_max_base() {
  local older newer
  older="$1/.rite/review-results/42-20200202000000.json"
  newer="$1/.rite/review-results/42-20200101000000.json"
  if [ "$(nb_mtime "$newer")" -ge "$(nb_mtime "$older")" ]; then
    basename "$newer"
  else
    basename "$older"
  fi
}
assert "T-11 lexical tail is not the mtime max" "$mtime_max" "$(nb_mtime_max_base "$match_root")"
assert "T-11 match skips" "1" "$(grep -c "ITERATE_NB_SWEEP=skipped" "$match_root/out.txt" || true)"
assert "T-11 match kind is done not concatenated" "1" "$(grep -c 'kind=done;' "$match_root/out.txt" || true)"
assert "T-11 match record is lexical tail" "1" "$(grep -c "record=$lexical_tail" "$match_root/out.txt" || true)"
assert "T-11 match does not call collect" "0" "$([ -f "$match_root/collect.log" ] && echo 1 || echo 0)"
rm -rf -- "$match_root"

miss_root=$(run_entry miss "done $mtime_max")
assert "T-11 mtime-max record does not skip" "0" "$(grep -c 'ITERATE_NB_SWEEP=skipped' "$miss_root/out.txt" || true)"
assert "T-11 mismatch calls collect" "1" "$(grep -c called "$miss_root/collect.log" || true)"
assert "T-11 mismatch writes noop plus lexical tail" "noop $lexical_tail" "$(awk 'NR==1{print}' "$miss_root/.rite/state/nb-sweep-done-42.txt")"
rm -rf -- "$miss_root"

bare_root=$(run_entry bare $'done')
assert "T-11 missing range does not skip" "0" "$(grep -c 'ITERATE_NB_SWEEP=skipped' "$bare_root/out.txt" || true)"
assert "T-11 missing range calls collect" "1" "$(grep -c called "$bare_root/collect.log" || true)"
rm -rf -- "$bare_root"

sha_keep=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
sha_root=$(run_entry sha "$(printf 'done\n%s\n' "$sha_keep")")
assert "T-11 legacy sha line survives rewrite" "$sha_keep" "$(sed -n '2p' "$sha_root/.rite/state/nb-sweep-done-42.txt" | tr -d '[:space:]')"
assert "T-11 legacy rewrite records lexical tail" "noop $lexical_tail" "$(awk 'NR==1{print}' "$sha_root/.rite/state/nb-sweep-done-42.txt")"
rm -rf -- "$sha_root"

empty_root=$(run_entry empty-record "" missing)
assert "T-11 empty record leaves no rangeless file" "0" "$([ -f "$empty_root/.rite/state/nb-sweep-done-42.txt" ] && echo 1 || echo 0)"
rm -rf -- "$empty_root"

# 既存の done ファイル（最新 JSON と食い違う basename + 旧版の 2 行目 SHA）があり record が得られないとき、
# 削除する側の分岐を通す
stale_root=$(run_entry stale-empty-record "$(printf 'done %s\n%s\n' "$mtime_max" "$sha_keep")" missing)
assert "T-11 empty record reached collect over an existing file" "1" "$(grep -c called "$stale_root/collect.log" || true)"
assert "T-11 empty record warns that the marker was not written" "1" "$(grep -c 'nb-sweep-done marker を書けませんでした' "$stale_root/out.txt" || true)"
assert "T-11 empty record removes an existing file" "0" "$([ -f "$stale_root/.rite/state/nb-sweep-done-42.txt" ] && echo 1 || echo 0)"
rm -rf -- "$stale_root"
rm -f -- "$nb_collect_stub"

# --- T-12: 5.S 入口以外の読み手・書き手も、字句順の末尾と mtime 最大が食い違う fixture で実行する ---
# fixture の JSON 2 本と done ファイルは T-11 の run_entry と同じ配置（字句順の末尾 = mtime が古い側）。
nb_fixture() {
  local root
  root=$(make_sandbox)
  mkdir -p "$root/.rite/review-results" "$root/.rite/state"
  printf '{}\n' > "$root/.rite/review-results/42-20200101000000.json"
  printf '{}\n' > "$root/.rite/review-results/42-20200202000000.json"
  touch -d '2020-01-02 00:00:00' "$root/.rite/review-results/42-20200202000000.json" \
    || touch -t 202001020000 "$root/.rite/review-results/42-20200202000000.json"
  touch -d '2020-03-03 00:00:00' "$root/.rite/review-results/42-20200101000000.json" \
    || touch -t 202003030000 "$root/.rite/review-results/42-20200101000000.json"
  [ -n "${1:-}" ] && printf '%s\n' "$1" > "$root/.rite/state/nb-sweep-done-42.txt"
  echo "$root"
}
# fenced bash ブロックのうち、指定の行を含むものだけを取り出す。一致が 1 件でなければ空を返す。
fenced_block_with() {
  awk -v needle="$2" '
    /^```bash$/ { inb=1; buf=""; hit=0; next }
    inb && /^```$/ { if (hit) { n++; out=buf } inb=0; next }
    inb { buf = buf $0 "\n"; if (index($0, needle)) hit=1 }
    END { if (n == 1) printf "%s", out }
  ' "$1"
}
# state-path-resolve の呼び出しを fixture root へ差し替え、placeholder を置換する。
# 置換漏れがあると本物の state root に書き込むか、find が 0 件になって判定 0 側が空振りするので止める。
render_fenced() {
  local rendered
  rendered=$(printf '%s' "$1" | sed \
    -e 's#bash {plugin_root}/hooks/state-path-resolve.sh#printf %s "$NB_FIX_ROOT"#g' \
    -e "s#{plugin_root}#$PLUGIN_ROOT#g" \
    -e 's#{pr_number}#42#g')
  if grep -qE '\{(plugin_root|pr_number)\}|state-path-resolve\.sh' <<< "$rendered"; then
    echo "FAIL: T-12 rendered block still has a placeholder or a real state-path-resolve call" >&2
    return 1
  fi
  printf '%s\n' "$rendered"
}
fenced_ok() {
  [ -n "$2" ] && [ "$(printf '%s\n' "$2" | wc -l | tr -d '[:space:]')" -le 60 ] \
    || { echo "FAIL: T-12 $1 fence missing, ambiguous or overran"; exit 1; }
}

# fix 5.1 は SKILL.md の 1 行呼び出しを fixture plugin の fix-step.sh で dispatch 経由に実行する。
# fixture は state-path-resolve だけを fixture root を返す stub に差し替える。
fix51_call=$(grep -xF 'bash {plugin_root}/scripts/fix-step.sh nb-sweep-done-file --pr {pr_number}' "$FIX")
[ "$(printf '%s\n' "$fix51_call" | grep -c .)" = "1" ] \
  || { echo "FAIL: T-12 fix 5.1 one-line call is missing or duplicated in SKILL.md"; exit 1; }
fix51_plugin=$(mktemp -d)
mkdir -p "$fix51_plugin/scripts" "$fix51_plugin/hooks"
cp "$FIX_STEP" "$fix51_plugin/scripts/fix-step.sh"
ln -s "$PLUGIN_ROOT/hooks/control-char-neutralize.sh" "$fix51_plugin/hooks/control-char-neutralize.sh"
cat > "$fix51_plugin/hooks/state-path-resolve.sh" <<'STUB'
#!/bin/bash
printf '%s\n' "${NB_FIX_ROOT:?}"
STUB
fix51_run() {
  local root out
  root=$(nb_fixture "$1")
  out=$(NB_FIX_ROOT="$root" bash -c "$(printf '%s\n' "$fix51_call" \
    | sed -e "s#{plugin_root}#$fix51_plugin#g" -e 's#{pr_number}#42#g')" 2>&1) || true
  rm -rf -- "$root"
  printf '%s\n' "$out" | sed -n 's/^\[CONTEXT\] NB_SWEEP_DONE_FILE=\([01]\)$/\1/p'
}
assert "T-12 fix 5.1 done on lexical tail" "1" "$(fix51_run "done $lexical_tail")"
assert "T-12 fix 5.1 not done on mtime max" "0" "$(fix51_run "done $mtime_max")"
rm -rf -- "$fix51_plugin"

digest_block=$(fenced_block_with "$FIX_SWEEP" 'sweep_done_file="$sweep_root/.rite/state/nb-sweep-done-{pr_number}.txt"')
fenced_ok "digest writer" "$digest_block"
render_fenced "$digest_block" >/dev/null || exit 1
digest_run() {
  local root
  root=$(nb_fixture "$1")
  NB_FIX_ROOT="$root" bash -c "$(render_fenced "$digest_block")" >/dev/null 2>&1 || true
  echo "$root"
}
digest_root=$(digest_run "")
assert "T-12 digest writer records lexical tail" "done $lexical_tail" "$(awk 'NR==1{print}' "$digest_root/.rite/state/nb-sweep-done-42.txt" 2>/dev/null)"
rm -rf -- "$digest_root"
digest_root=$(digest_run "$(printf 'noop %s\n%s\n' "$mtime_max" "$sha_keep")")
assert "T-12 digest rewrite records lexical tail" "done $lexical_tail" "$(awk 'NR==1{print}' "$digest_root/.rite/state/nb-sweep-done-42.txt" 2>/dev/null)"
assert "T-12 digest rewrite keeps the legacy sha line" "$sha_keep" "$(sed -n '2p' "$digest_root/.rite/state/nb-sweep-done-42.txt" 2>/dev/null)"
rm -rf -- "$digest_root"

# step_nb_sweep_record は関数なので T-11 と同じく関数範囲を抽出し、state-path-resolve だけを差し替える
record_fence=$(awk '/^step_nb_sweep_record\(\) \{$/{f=1} f{print} f && /^}$/{exit}' "$ITERATE_STEP")
[ -n "$record_fence" ] && _gq_out=$(tail -1 <<< "$record_fence") && grep -qx '}' <<< "$_gq_out" \
  || { echo "FAIL: T-12 record fence extraction lost its end anchor"; exit 1; }
record_run() {
  local root
  root=$(nb_fixture "$1")
  NB_FIX_ROOT="$root" bash -c "$(
    printf 'pr_number=42\nplugin_root=%q\n' "$PLUGIN_ROOT"
    printf '%s\n' "$record_fence" | sed -e 's#bash "$plugin_root"/hooks/state-path-resolve.sh#printf %s "$NB_FIX_ROOT"#g'
    printf 'step_nb_sweep_record\n'
  )" >/dev/null 2>&1 || true
  echo "$root"
}
record_root=$(record_run "")
assert "T-12 iterate post-return writer records lexical tail" "done $lexical_tail" "$(awk 'NR==1{print}' "$record_root/.rite/state/nb-sweep-done-42.txt" 2>/dev/null)"
rm -rf -- "$record_root"
record_root=$(record_run "$(printf 'noop %s\n%s\n' "$mtime_max" "$sha_keep")")
assert "T-12 iterate post-return rewrite records lexical tail" "done $lexical_tail" "$(awk 'NR==1{print}' "$record_root/.rite/state/nb-sweep-done-42.txt" 2>/dev/null)"
assert "T-12 iterate post-return rewrite keeps the legacy sha line" "$sha_keep" "$(sed -n '2p' "$record_root/.rite/state/nb-sweep-done-42.txt" 2>/dev/null)"
rm -rf -- "$record_root"
record_root=$(record_run "noop $lexical_tail")
assert "T-12 iterate post-return leaves a matching file untouched" "noop $lexical_tail" "$(awk 'NR==1{print}' "$record_root/.rite/state/nb-sweep-done-42.txt" 2>/dev/null)"
rm -rf -- "$record_root"

# --- 台帳 persist の前に止まった sweep を別の会話から重複起票なしで戻す (T-13〜T-17) ---
LEDGER="$PLUGIN_ROOT/hooks/scripts/nb-sweep-ledger.sh"
cleanup_dirs=()
trap 'rm -rf "${cleanup_dirs[@]}"' EXIT

# iterate-step.sh は自分の位置から plugin_root を決める。collect helper だけ stub にした plugin の複製を作る
fake_plugin=$(mktemp -d); cleanup_dirs+=("$fake_plugin")
mkdir -p "$fake_plugin/scripts" "$fake_plugin/hooks/scripts"
cp "$ITERATE_STEP" "$fake_plugin/scripts/iterate-step.sh"
for dep in state-path-resolve.sh gitignore-ensure.sh control-char-neutralize.sh flow-state.sh; do
  ln -s "$PLUGIN_ROOT/hooks/$dep" "$fake_plugin/hooks/$dep"
done
ln -s "$PLUGIN_ROOT/hooks/scripts/lib" "$fake_plugin/hooks/scripts/lib"
cat > "$fake_plugin/hooks/scripts/nb-sweep-collect.sh" <<'STUB'
#!/bin/bash
case "${NB_STUB_STATUS:-ok}" in
  ok) printf '%s\n' '{"status":"ok","count":1,"record":"x"}' ;;
  empty) printf '%s\n' '{"status":"empty","count":0,"record":"'"${NB_STUB_RECORD:-}"'"}' ;;
esac
STUB
chmod +x "$fake_plugin/hooks/scripts/nb-sweep-collect.sh"

# sandbox git リポジトリ（state root = その root）と最新 review JSON を用意する
new_repo() {  # $1=commit_sha の扱い (head / other / none)
  local sbx head sha
  sbx=$(make_sandbox)
  mkdir -p "$sbx/.rite/review-results" "$sbx/.rite/state"
  head=$(git -C "$sbx" rev-parse HEAD)
  case "$1" in
    head) sha="\"$head\"" ;;
    short) sha="\"${head:0:7}\"" ;;
    other) sha='"0123456789abcdef0123456789abcdef01234567"' ;;
    none) sha='null' ;;
  esac
  printf '{"commit_sha":%s}\n' "$sha" > "$sbx/.rite/review-results/7-20260101000000.json"
  printf '{"commit_sha":%s}\n' "$sha" > "$sbx/.rite/review-results/7-20260202000000.json"
  echo "$sbx"
}
run_step() {  # $1=sandbox, rest=args. stdout+stderr -> $1/out, rc -> $1/rc
  local sbx="$1"; shift
  ( cd "$sbx" && bash "$fake_plugin/scripts/iterate-step.sh" "$@" ) > "$sbx/out" 2>&1
  echo $? > "$sbx/rc"
}
origin_of() { printf '%s\n' "$1/.rite/state/nb-sweep-origin-7.txt"; }
marker_line() { grep -E "^\[CONTEXT\] $2=" "$1/out" | tail -1; }

# --- T-13: nb-sweep-resume ---
r=$(new_repo head); cleanup_dirs+=("$r")
run_step "$r" nb-sweep-resume --pr 7
assert "T-13 無し: none/no_origin" "[CONTEXT] ITERATE_NB_SWEEP_RESUME=none; reason=no_origin" "$(marker_line "$r" ITERATE_NB_SWEEP_RESUME)"
assert "T-13 無し: rc=0" 0 "$(cat "$r/rc")"

r=$(new_repo head); cleanup_dirs+=("$r")
printf '7-20260101000000.json [review:mergeable]\n' > "$(origin_of "$r")"
run_step "$r" nb-sweep-resume --pr 7
assert "T-13 basename 不一致: none/stale_origin" \
  "[CONTEXT] ITERATE_NB_SWEEP_RESUME=none; reason=stale_origin; record=7-20260101000000.json" "$(marker_line "$r" ITERATE_NB_SWEEP_RESUME)"
assert "T-13 basename 不一致: rc=0" 0 "$(cat "$r/rc")"
assert "T-13 basename 不一致: 入口記録を消す" 0 "$([ -e "$(origin_of "$r")" ] && echo 1 || echo 0)"

r=$(new_repo other); cleanup_dirs+=("$r")
printf '7-20260202000000.json [review:mergeable]\n' > "$(origin_of "$r")"
run_step "$r" nb-sweep-resume --pr 7
assert "T-13 HEAD 不一致: none/head_changed" \
  "[CONTEXT] ITERATE_NB_SWEEP_RESUME=none; reason=head_changed; record=7-20260202000000.json" "$(marker_line "$r" ITERATE_NB_SWEEP_RESUME)"
assert "T-13 HEAD 不一致: rc=0" 0 "$(cat "$r/rc")"
assert "T-13 HEAD 不一致: 入口記録を消す" 0 "$([ -e "$(origin_of "$r")" ] && echo 1 || echo 0)"

r=$(new_repo none); cleanup_dirs+=("$r")
printf '7-20260202000000.json [review:mergeable]\n' > "$(origin_of "$r")"
run_step "$r" nb-sweep-resume --pr 7
assert "T-13 commit_sha 読めず: failed/head_unverified" \
  "[CONTEXT] ITERATE_NB_SWEEP_RESUME=failed; reason=head_unverified" "$(marker_line "$r" ITERATE_NB_SWEEP_RESUME)"
assert "T-13 commit_sha 読めず: rc=1" 1 "$(cat "$r/rc")"
assert "T-13 commit_sha 読めず: [iterate:nb-sweep-error]" 1 "$(grep -cx '\[iterate:nb-sweep-error\]' "$r/out")"
assert "T-13 commit_sha 読めず: 入口記録は残す" 1 "$([ -e "$(origin_of "$r")" ] && echo 1 || echo 0)"

r=$(new_repo head); cleanup_dirs+=("$r")
printf '7-20260202000000.json [fix:error]\n' > "$(origin_of "$r")"
run_step "$r" nb-sweep-resume --pr 7
assert "T-13 値不正: failed/origin_invalid" \
  "[CONTEXT] ITERATE_NB_SWEEP_RESUME=failed; reason=origin_invalid" "$(marker_line "$r" ITERATE_NB_SWEEP_RESUME)"
assert "T-13 値不正: rc=1" 1 "$(cat "$r/rc")"

for origin in '[review:mergeable]' '[fix:non-fatal-only]' '[fix:replied-only]'; do
  r=$(new_repo short); cleanup_dirs+=("$r")
  printf '7-20260202000000.json %s\n' "$origin" > "$(origin_of "$r")"
  run_step "$r" nb-sweep-resume --pr 7
  assert "T-13 一致 ($origin): resume と記録した入口" \
    "[CONTEXT] ITERATE_NB_SWEEP_RESUME=resume; origin=$origin; record=7-20260202000000.json" "$(marker_line "$r" ITERATE_NB_SWEEP_RESUME)"
  assert "T-13 一致 ($origin): rc=0" 0 "$(cat "$r/rc")"
  assert "T-13 一致 ($origin): 入口記録は残す" 1 "$([ -e "$(origin_of "$r")" ] && echo 1 || echo 0)"
done

# --- T-14: nb-sweep-collect / nb-sweep-record ---
r=$(new_repo head); cleanup_dirs+=("$r")
run_step "$r" nb-sweep-collect --pr 7 --sweep-origin '[fix:non-fatal-only]'
assert "T-14 pending を出す" "[CONTEXT] ITERATE_NB_SWEEP=pending; count=1" "$(marker_line "$r" ITERATE_NB_SWEEP)"
assert "T-14 入口記録は 1 行" 1 "$(wc -l < "$(origin_of "$r")" | tr -d ' ')"
assert "T-14 入口記録は最新 JSON の basename と入口" "7-20260202000000.json [fix:non-fatal-only]" "$(cat "$(origin_of "$r")")"

for bad in '' '[fix:error]'; do
  r=$(new_repo head); cleanup_dirs+=("$r")
  if [ -z "$bad" ]; then
    run_step "$r" nb-sweep-collect --pr 7
  else
    run_step "$r" nb-sweep-collect --pr 7 --sweep-origin "$bad"
  fi
  assert "T-14 入口 '${bad:-<欠落>}' は exit 2" 2 "$(cat "$r/rc")"
  assert "T-14 入口 '${bad:-<欠落>}' は記録を作らない" 0 "$([ -e "$(origin_of "$r")" ] && echo 1 || echo 0)"
done

if [ "$(id -u)" != 0 ]; then
  r=$(new_repo head); cleanup_dirs+=("$r")
  printf '*\n' > "$r/.rite/state/.gitignore"
  chmod 555 "$r/.rite/state"
  run_step "$r" nb-sweep-collect --pr 7 --sweep-origin '[review:mergeable]'
  chmod 755 "$r/.rite/state"
  assert "T-14 書けなければ failed/origin_write_failed" \
    "[CONTEXT] ITERATE_NB_SWEEP=failed; reason=origin_write_failed" "$(marker_line "$r" ITERATE_NB_SWEEP)"
  assert "T-14 書けなければ pending を出さない" 0 "$(grep -c 'ITERATE_NB_SWEEP=pending' "$r/out")"
  assert "T-14 書けなければ rc=1" 1 "$(cat "$r/rc")"
  assert "T-14 書けなければ記録を残さない" 0 "$([ -e "$(origin_of "$r")" ] && echo 1 || echo 0)"
fi

r=$(new_repo head); cleanup_dirs+=("$r")
printf '7-20260202000000.json [review:mergeable]\n' > "$(origin_of "$r")"
( export NB_STUB_STATUS=empty NB_STUB_RECORD="$r/.rite/review-results/7-20260202000000.json"
  run_step "$r" nb-sweep-collect --pr 7 --sweep-origin '[review:mergeable]' )
assert "T-14 noop" "[CONTEXT] ITERATE_NB_SWEEP=noop; count=0" "$(marker_line "$r" ITERATE_NB_SWEEP)"
assert "T-14 noop は入口記録を消す" 0 "$([ -e "$(origin_of "$r")" ] && echo 1 || echo 0)"

# 台帳 persist の後・完了の前に止まった sweep: collect は empty でも entries が残るので fix へ渡す
r=$(new_repo head); cleanup_dirs+=("$r")
printf '7-20260202000000.json [review:mergeable]\n' > "$(origin_of "$r")"
printf '| A-1 | a.ts:1 | issued | #5 | 7-20260202000000.json |\n' > "$r/.rite/state/nb-sweep-entries-7.md"
( export NB_STUB_STATUS=empty NB_STUB_RECORD="$r/.rite/review-results/7-20260202000000.json"
  run_step "$r" nb-sweep-resume --pr 7
  cp "$r/out" "$r/resume.out"
  run_step "$r" nb-sweep-collect --pr 7 --sweep-origin '[review:mergeable]' )
assert "T-14 persist 後の再開: 0.7 は resume" 1 "$(grep -c '^\[CONTEXT\] ITERATE_NB_SWEEP_RESUME=resume;' "$r/resume.out")"
assert "T-14 collect empty でも entries があれば pending（fix へ渡す）" 1 "$(grep -c '^\[CONTEXT\] ITERATE_NB_SWEEP=pending; count=0$' "$r/out")"
assert "T-14 collect empty でも entries があれば noop を書かない" 0 "$([ -e "$r/.rite/state/nb-sweep-done-7.txt" ] && echo 1 || echo 0)"
assert "T-14 collect empty でも entries があれば入口記録を残す" "7-20260202000000.json [review:mergeable]" "$(cat "$(origin_of "$r")")"

r=$(new_repo head); cleanup_dirs+=("$r")
printf '7-20260202000000.json [review:mergeable]\n' > "$(origin_of "$r")"
printf 'done 7-20260202000000.json\n' > "$r/.rite/state/nb-sweep-done-7.txt"
run_step "$r" nb-sweep-collect --pr 7 --sweep-origin '[review:mergeable]'
assert "T-14 skipped" 1 "$(grep -c '^\[CONTEXT\] ITERATE_NB_SWEEP=skipped; reason=already_done' "$r/out")"
assert "T-14 skipped は入口記録を消す" 0 "$([ -e "$(origin_of "$r")" ] && echo 1 || echo 0)"

r=$(new_repo head); cleanup_dirs+=("$r")
printf '7-20260202000000.json [review:mergeable]\n' > "$(origin_of "$r")"
run_step "$r" nb-sweep-record --pr 7
assert "T-14 record は done を書く" "done 7-20260202000000.json" "$(cat "$r/.rite/state/nb-sweep-done-7.txt")"
assert "T-14 record は入口記録を消す" 0 "$([ -e "$(origin_of "$r")" ] && echo 1 || echo 0)"

# 採否ゲートが保留 (held) した sweep: fix は起票も entries も done も書かずに止まる。入口記録は残り、
# 再実行はステップ 0.7 から 5.S へ戻り、collect は skip せず fix へ渡す
r=$(new_repo head); cleanup_dirs+=("$r")
printf '7-20260202000000.json [fix:replied-only]\n' > "$(origin_of "$r")"
printf '{"kind":"sweep","pr":7,"held_ids":["F-01"]}\n' > "$r/.rite/state/adoption-hold-7-sweep.json"
run_step "$r" nb-sweep-resume --pr 7
cp "$r/out" "$r/resume.out"
run_step "$r" nb-sweep-collect --pr 7 --sweep-origin '[fix:replied-only]'
assert "T-18 held の再開: 0.7 は resume" 1 "$(grep -c '^\[CONTEXT\] ITERATE_NB_SWEEP_RESUME=resume; origin=\[fix:replied-only\];' "$r/resume.out")"
assert "T-18 held の再開: collect は skip せず pending" 1 "$(grep -c '^\[CONTEXT\] ITERATE_NB_SWEEP=pending;' "$r/out")"
assert "T-18 held の再開: done を書かない" 0 "$([ -e "$r/.rite/state/nb-sweep-done-7.txt" ] && echo 1 || echo 0)"
assert "T-18 held の再開: 入口記録を残す" "7-20260202000000.json [fix:replied-only]" "$(cat "$(origin_of "$r")")"
# sweep の保留ファイルがあれば、最新 JSON の done があっても skip せず collect に候補を合流させる
r=$(new_repo head); cleanup_dirs+=("$r")
printf 'done 7-20260202000000.json\n' > "$r/.rite/state/nb-sweep-done-7.txt"
printf '{"kind":"sweep","pr":7,"held_ids":["F-01"]}\n' > "$r/.rite/state/adoption-hold-7-sweep.json"
run_step "$r" nb-sweep-collect --pr 7 --sweep-origin '[review:mergeable]'
assert "T-18 done でも sweep の保留があれば skip しない" 0 "$(grep -c 'ITERATE_NB_SWEEP=skipped' "$r/out")"
assert "T-18 done でも sweep の保留があれば fix へ渡す" 1 "$(grep -c '^\[CONTEXT\] ITERATE_NB_SWEEP=pending;' "$r/out")"
# triage の保留が残っていれば、done の有無を問わず完了へ進まずに止まる
for t18_done in yes no; do
  r=$(new_repo head); cleanup_dirs+=("$r")
  [ "$t18_done" = yes ] && printf 'done 7-20260202000000.json\n' > "$r/.rite/state/nb-sweep-done-7.txt"
  printf '{"kind":"triage","pr":7,"held_ids":["C-1"]}\n' > "$r/.rite/state/adoption-hold-7-triage.json"
  run_step "$r" nb-sweep-collect --pr 7 --sweep-origin '[fix:replied-only]'
  assert "T-18 triage の保留 (done=$t18_done): failed で止まる" \
    "[CONTEXT] ITERATE_NB_SWEEP=failed; reason=triage_adoption_held; hold_file=$r/.rite/state/adoption-hold-7-triage.json" \
    "$(marker_line "$r" ITERATE_NB_SWEEP)"
  assert "T-18 triage の保留 (done=$t18_done): [iterate:nb-sweep-error]" 1 "$(grep -cx '\[iterate:nb-sweep-error\]' "$r/out")"
  assert "T-18 triage の保留 (done=$t18_done): 保留を残す" 1 "$([ -e "$r/.rite/state/adoption-hold-7-triage.json" ] && echo 1 || echo 0)"
  assert "T-18 triage の保留 (done=$t18_done): 入口記録を書かない" 0 "$([ -e "$(origin_of "$r")" ] && echo 1 || echo 0)"
done
# done を書く nb-sweep-record は [fix:sweep-done] の後だけ。[fix:error] の行は停止し、record を呼ばない
t18_sec=$(awk '/^## ステップ 5\.S: NB digest sweep$/{s=1} /^### 5\.S 後の PR 内推奨の修正$/{s=0} s' "$ITERATE")
t18_err=$(printf '%s\n' "$t18_sec" | grep -E '^\| `\[fix:error\]` / その他 / sentinel 不在 \|')
assert "T-18 [fix:error] 行は停止し nb-sweep-record を呼ばない" 1 \
  "$(printf '%s\n' "$t18_err" | grep -F '`[iterate:nb-sweep-error]` で停止' | grep -vcF 'nb-sweep-record')"
t18_record=$(printf '%s\n' "$t18_sec" | grep -n 'iterate-step.sh nb-sweep-record' | cut -d: -f1)
t18_done=$(printf '%s\n' "$t18_sec" | grep -n '^fix が emit した `\[CONTEXT\] NB_SWEEP_RESULT=done' | cut -d: -f1)
if [ -n "$t18_record" ] && [ -n "$t18_done" ] && [ "$t18_done" -lt "$t18_record" ]; then
  pass "T-18 nb-sweep-record は NB_SWEEP_RESULT=done を読んだ後の段落にある"
else
  fail "T-18 nb-sweep-record は NB_SWEEP_RESULT=done を読んだ後の段落にある (done=$t18_done record=$t18_record)"
fi

# --- fix 側の手順 1 / 手順 4 の bash を nb-sweep.md から抜き出して実行する ---
# 手順 N の見出しから次の見出しまでの最初の ```bash ブロック
sweep_block() {
  awk -v head="$1" '
    index($0, head) == 1 { s = 1; next }
    s && /^```bash$/ { f = 1; next }
    f && /^```$/ { exit }
    f { print }
  ' "$FIX_SWEEP"
}
fix_plugin=$(mktemp -d); cleanup_dirs+=("$fix_plugin")
mkdir -p "$fix_plugin/hooks/scripts"
ln -s "$LEDGER" "$fix_plugin/hooks/scripts/nb-sweep-ledger.sh"
ln -s "$PLUGIN_ROOT/hooks/gitignore-ensure.sh" "$fix_plugin/hooks/gitignore-ensure.sh"
ln -s "$PLUGIN_ROOT/hooks/scripts/lib" "$fix_plugin/hooks/scripts/lib"
ln -s "$PLUGIN_ROOT/hooks/scripts/review-adoption-gate.sh" "$fix_plugin/hooks/scripts/review-adoption-gate.sh"
ln -s "$PLUGIN_ROOT/hooks/control-char-neutralize.sh" "$fix_plugin/hooks/control-char-neutralize.sh"
cat > "$fix_plugin/hooks/state-path-resolve.sh" <<'STUB'
#!/bin/bash
printf '%s\n' "${FIX_STATE_ROOT:?}"
STUB
cat > "$fix_plugin/hooks/scripts/nb-sweep-collect.sh" <<'STUB'
#!/bin/bash
printf '{"status":"%s","count":1,"record":"%s/.rite/review-results/7-20260202000000.json","targets":[],"candidates":%s}\n' \
  "${NB_STUB_STATUS:?}" "${FIX_STATE_ROOT:?}" "${NB_STUB_CANDIDATES:-[]}"
STUB
render() {
  sweep_block "$1" | sed -e "s|{plugin_root}|$fix_plugin|g" -e 's|{pr_number}|7|g' \
    -e 's|{base_branch}|develop|g' -e 's|{owner_repo}|test/repo|g'
}
step1=$(render '1. **collect**')
step2=$(render '2. **採否ゲートと起票**')
step4=$(render '4. **完了**')
assert "T-15 手順 1 の bash を抜き出せる" 1 "$(printf '%s\n' "$step1" | grep -c 'NB_SWEEP_ENTRIES=present')"
assert "T-19 手順 2 のゲートの bash を抜き出せる" 1 "$(printf '%s\n' "$step2" | grep -c 'review-adoption-gate.sh --pr 7 --kind sweep')"
assert "T-16 手順 4 の bash を抜き出せる" 1 "$(printf '%s\n' "$step4" | grep -c 'tally --entries-file')"
fix_root() {
  local d; d=$(mktemp -d)
  mkdir -p "$d/.rite/state" "$d/.rite/review-results"
  printf '{}\n' > "$d/.rite/review-results/7-20260202000000.json"
  echo "$d"
}
run_fix() {  # $1=root $2=status $3=script
  FIX_STATE_ROOT="$1" NB_STUB_STATUS="$2" bash -c "$3" > "$1/out" 2>&1
  echo $? > "$1/rc"
}
entries_of() { printf '%s\n' "$1/.rite/state/nb-sweep-entries-7.md"; }
# entries の 1 行目は手順 3 が書かせる見出しをそのまま使う（手順書の書式が変われば再開のテストが落ちる）
entries_head=$(grep -o '<!-- nb-sweep-record: {sweep_record} -->' "$FIX_SWEEP" | head -1)
assert "T-15 手順 3 が entries の 1 行目の見出しを書かせる" '<!-- nb-sweep-record: {sweep_record} -->' "$entries_head"
write_entries() {  # $1=root $2=record basename (1 行目の見出しと全行の出典)
  printf '%s\n' "${entries_head//\{sweep_record\}/$2}" "| A-1 | a.ts:1 | issued | #5 https://example.test/5 | $2 |" \
    "| A\\|2 | b.ts:2 | recorded | severity=LOW; measured=false | $2 |" \
    "| A-3 | c.ts:3 | issued | #6 x\\|y | $2 |" > "$(entries_of "$1")"
}

# T-15
d=$(fix_root); cleanup_dirs+=("$d")
run_fix "$d" ok "$step1"
assert "T-15 entries 無し: absent" 1 "$(grep -c '^\[CONTEXT\] NB_SWEEP_ENTRIES=absent;' "$d/out")"
assert "T-15 entries 無し: rc=0" 0 "$(cat "$d/rc")"

d=$(fix_root); cleanup_dirs+=("$d")
write_entries "$d" 7-20260202000000.json
run_fix "$d" ok "$step1"
assert "T-15 今回の record の entries: present（起票を飛ばす）" 1 "$(grep -c '^\[CONTEXT\] NB_SWEEP_ENTRIES=present;' "$d/out")"
assert "T-15 今回の record の entries: rc=0" 0 "$(cat "$d/rc")"
assert "T-15 今回の record の entries: entries は残す" 1 "$([ -e "$(entries_of "$d")" ] && echo 1 || echo 0)"

d=$(fix_root); cleanup_dirs+=("$d")
write_entries "$d" 7-20260101000000.json
run_fix "$d" ok "$step1"
assert "T-15 他の record の entries: [fix:error] で止まる" 1 "$(grep -c '^\[fix:error\] reason=nb_sweep_entries_stale$' "$d/out")"
assert "T-15 他の record の entries: rc=1" 1 "$(cat "$d/rc")"
assert "T-15 他の record の entries: present を出さない" 0 "$(grep -c 'NB_SWEEP_ENTRIES=present' "$d/out")"

d=$(fix_root); cleanup_dirs+=("$d")
write_entries "$d" 7-20260202000000.json
run_fix "$d" empty "$step1"
assert "T-15 empty: entries から件数を数える" 1 "$(grep -c '^\[CONTEXT\] NB_SWEEP_RESULT=done; issued=2; recorded=1$' "$d/out")"
assert "T-15 empty: entries を消す" 0 "$([ -e "$(entries_of "$d")" ] && echo 1 || echo 0)"
assert "T-15 empty: 起票があった sweep は done で記録する" "done 7-20260202000000.json" "$(cat "$d/.rite/state/nb-sweep-done-7.txt")"

d=$(fix_root); cleanup_dirs+=("$d")
write_entries "$d" 7-20260101000000.json
run_fix "$d" empty "$step1"
assert "T-15 empty で他の record の entries: [fix:error] で止まる" 1 "$(grep -c '^\[fix:error\] reason=nb_sweep_entries_stale$' "$d/out")"
assert "T-15 empty で他の record の entries: 件数を出さない" 0 "$(grep -c 'NB_SWEEP_RESULT=' "$d/out")"
assert "T-15 empty で他の record の entries: entries を消さない" 1 "$([ -e "$(entries_of "$d")" ] && echo 1 || echo 0)"

# 合流した保留候補の行は元の review JSON を出典に持つ。どの sweep の entries かは 1 行目で決まるので、
# 手順 3 で止まった sweep は手順 3 から続き、手順 4 が件数を出せる
d=$(fix_root); cleanup_dirs+=("$d")
write_entries "$d" 7-20260202000000.json
printf '%s\n' "| F-01 | old.ts:4 | REJECT | 前提は不変 | 7-20260101000000.json |" >> "$(entries_of "$d")"
run_fix "$d" ok "$step1"
assert "T-15 合流候補の行を含む entries: present（手順 3 から続く）" 1 "$(grep -c '^\[CONTEXT\] NB_SWEEP_ENTRIES=present;' "$d/out")"
assert "T-15 合流候補の行を含む entries: rc=0" 0 "$(cat "$d/rc")"
run_fix "$d" empty "$step1"
assert "T-15 合流候補の行を含む entries: 件数に数える" 1 "$(grep -c '^\[CONTEXT\] NB_SWEEP_RESULT=done; issued=2; recorded=2$' "$d/out")"
d=$(fix_root); cleanup_dirs+=("$d")
write_entries "$d" 7-20260202000000.json
tail -n +2 "$(entries_of "$d")" > "$d/entries.tmp" && mv "$d/entries.tmp" "$(entries_of "$d")"
run_fix "$d" ok "$step1"
assert "T-15 1 行目の見出しを欠く entries: stale で止まる" 1 "$(grep -c '^\[fix:error\] reason=nb_sweep_entries_stale$' "$d/out")"

d=$(fix_root); cleanup_dirs+=("$d")
run_fix "$d" empty "$step1"
assert "T-15 empty で entries 無し: 0 件" 1 "$(grep -c '^\[CONTEXT\] NB_SWEEP_RESULT=done; issued=0; recorded=0$' "$d/out")"
assert "T-15 empty で entries 無し: noop で記録する" "noop 7-20260202000000.json" "$(cat "$d/.rite/state/nb-sweep-done-7.txt")"

# T-19 手順 2 はゲートへ collect の candidates[]（合流させた保留候補を含む）を渡す。
# 別の commit で保存した保留でも、候補が欠ければ退役させずに held で止まる
sha_a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
sha_b=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
t19_cand='{"id":"F-01","key":"F-01","finding_id":"F-01","source":"findings_nit_noted","file":"a.ts","line":1,"description":"d","record":"7-20260101000000.json"}'
hold_root() {  # 保留は commit A、今回のレビュー結果は commit B
  local d; d=$(fix_root)
  printf '{"commit_sha":"%s"}\n' "$sha_b" > "$d/.rite/review-results/7-20260202000000.json"
  jq -n --arg head "$sha_a" --argjson c "$t19_cand" '{kind:"sweep",pr:7,head:$head,review_result:"x",reason:"no_records",
    detail:"",held_ids:["F-01"],candidates:[$c],resume:"r"}' > "$d/.rite/state/adoption-hold-7-sweep.json"
  echo "$d"
}
hold_of() { printf '%s\n' "$1/.rite/state/adoption-hold-7-sweep.json"; }
for t19_case in "carried|[$(jq -c '.id = "7-20260101000000.json#F-01"' <<< "$t19_cand")]|no_records" "dropped|[]|held_candidates_dropped"; do
  IFS='|' read -r t19_label t19_cands t19_reason <<< "$t19_case"
  d=$(hold_root); cleanup_dirs+=("$d")
  NB_STUB_CANDIDATES="$t19_cands" run_fix "$d" ok "$step2"
  assert "T-19 ($t19_label) ゲートは退役させず held で止まる" 1 "$(grep -cx '\[fix:error\] reason=nb_sweep_adoption_held' "$d/out")"
  assert "T-19 ($t19_label) held の理由" 1 "$(grep -c "ADOPTION_GATE=held; kind=sweep; reason=$t19_reason;" "$d/out")"
  assert "T-19 ($t19_label) 保留を残す" 1 "$([ -e "$(hold_of "$d")" ] && echo 1 || echo 0)"
  assert "T-19 ($t19_label) 保留候補の元の出典を保つ" "7-20260101000000.json" \
    "$(jq -r '.candidates[] | select(.file == "a.ts") | .record' "$(hold_of "$d")")"
  assert "T-19 ($t19_label) 完了の件数を出さない" 0 "$(grep -c 'NB_SWEEP_RESULT=' "$d/out")"
  assert "T-19 ($t19_label) done を書かない" 0 "$([ -e "$d/.rite/state/nb-sweep-done-7.txt" ] && echo 1 || echo 0)"
done

# 起票を飛ばす判定は手順 2 の起票より前に書かれている
skip_line=$(grep -n '`NB_SWEEP_ENTRIES=present` なら' "$FIX_SWEEP" | head -1 | cut -d: -f1)
issue_line=$(grep -n 'create-issue-with-projects.sh' "$FIX_SWEEP" | head -1 | cut -d: -f1)
if [ -n "$skip_line" ] && [ -n "$issue_line" ] && [ "$skip_line" -lt "$issue_line" ]; then
  pass "T-15 起票を飛ばす判定は手順 2 の起票より前"
else
  fail "T-15 起票を飛ばす判定は手順 2 の起票より前 (skip=$skip_line issue=$issue_line)"
fi

# T-16
d=$(fix_root); cleanup_dirs+=("$d")
write_entries "$d" 7-20260202000000.json
run_fix "$d" ok "$step4"
assert "T-16 件数はエスケープ済みパイプでずれない" 1 "$(grep -c '^\[CONTEXT\] NB_SWEEP_RESULT=done; issued=2; recorded=1$' "$d/out")"
assert "T-16 entries を消す" 0 "$([ -e "$(entries_of "$d")" ] && echo 1 || echo 0)"
assert "T-16 done を書く" "done 7-20260202000000.json" "$(cat "$d/.rite/state/nb-sweep-done-7.txt")"

d=$(fix_root); cleanup_dirs+=("$d")
run_fix "$d" ok "$step4"
assert "T-16 entries 無し: 件数を出さない" 0 "$(grep -c 'NB_SWEEP_RESULT=' "$d/out")"
assert "T-16 entries 無し: fix を止める理由を出す" 1 "$(grep -c 'FIX_FALLBACK_FAILED=1; reason=nb_sweep_entries_tally_failed' "$d/out")"

# --- T-17: iterate SKILL の配線と 0.6 の削除範囲 ---
h06=$(grep -n '^## ステップ 0.6:' "$ITERATE" | cut -d: -f1)
h07=$(grep -n '^## ステップ 0.7:' "$ITERATE" | cut -d: -f1)
h1=$(grep -n '^## ステップ 1:' "$ITERATE" | cut -d: -f1)
if [ -n "$h06" ] && [ -n "$h07" ] && [ -n "$h1" ] && [ "$h06" -lt "$h07" ] && [ "$h07" -lt "$h1" ]; then
  pass "T-17 ステップ 0.7 は 0.6 と 1 の間"
else
  fail "T-17 ステップ 0.7 は 0.6 と 1 の間 (0.6=$h06 0.7=$h07 1=$h1)"
fi
assert "T-17 0.7 は nb-sweep-resume を呼ぶ" 1 \
  "$(awk -v a="$h07" -v b="$h1" 'NR > a && NR < b' "$ITERATE" | grep -cx 'bash {plugin_root}/scripts/iterate-step.sh nb-sweep-resume --pr {pr_number}')"
assert "T-17 resume 行は入口を保持して 5.S へ" 1 \
  "$(grep -E '^\| `resume` \|' "$ITERATE" | grep -F '`{sweep_origin}` として保持' | grep -cF 'ステップ 5.S へ')"
assert "T-17 collect は入口を単一引用で渡す" 1 \
  "$(grep -cxF "bash {plugin_root}/scripts/iterate-step.sh nb-sweep-collect --pr {pr_number} --sweep-origin '{sweep_origin}'" "$ITERATE")"
init_body=$(awk '/^step_init_cycle\(\) \{$/,/^}$/' "$ITERATE_STEP")
assert "T-17 step_init_cycle を抜き出せる" 1 "$(printf '%s\n' "$init_body" | grep -c 'nb-sweep-done-')"
assert "T-17 0.6 は入口記録と entries を消さない" 0 "$(printf '%s\n' "$init_body" | grep -cE 'nb-sweep-(origin|entries)-')"

if ! print_summary "$(basename "$0")" "nb-sweep re-entry guard drift — iterate 5.S / fix 1.3.S / cleanup / 0.6"; then
  exit 1
fi
