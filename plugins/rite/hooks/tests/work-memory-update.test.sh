#!/bin/bash
# Tests for hooks/work-memory-update.sh — caller-side AC-4 migration verification.
#
# Covers the acceptance criteria from caller perspective:
#   AC-4 — caller (work-memory-update.sh) integrates with flow-state.sh transparently:
#          (TC-1) per-session file present + legacy absent + WM_REQUIRE_FLOW_STATE=true
#                 → return 0 with WM updated (cycle 12 false negative regression guard)
#          (TC-2) both files absent + WM_REQUIRE_FLOW_STATE=true
#                 → return 1 (skip, no WM written)
#          (TC-3) WM_READ_FROM_FLOW_STATE=true + per-session file with pr_number=100/loop_count=3
#                 → generated WM frontmatter contains pr_number: 100 / loop_count: 3
#                 (cycle 10 stale residue regression guard)
#   AC-7 — regression test discoverable under hooks/tests/
#
# 注: 上記 AC-4 / AC-7 は flow-state 移行 Issue の受入基準を指す。T- 番号を持つアサーションラベルが
# 使う (AC-1)〜(AC-5) は Issue #2082 の受入基準で、番号体系が別。同じ AC-4 が両方に存在するため、
# テスト出力のラベルから基準を引くときは T- 番号の有無で体系を判別すること。
#
# Removed (PR 2a refactor, v3 SoT):
#   (TC-4) schema_version=1 + legacy `.rite-flow-state` file present — the
#          legacy single-file path was retired in Phase E (commit bf5a2415);
#          v1/v2 files are now one-shot migrated to v3 per-session form by
#          flow-state.sh migrate at session-start, not handled inline by
#          work-memory-update.sh.
#
# Usage: bash plugins/rite/hooks/tests/work-memory-update.test.sh
set -euo pipefail

# Hermeticity guard (Issue #1929): flow-state.sh path resolves session_id with
# priority env CLAUDE_CODE_SESSION_ID > env CLAUDE_SESSION_ID > .rite-session-id
# file (Issue #1530). When this test suite runs inside a live Claude Code
# session, that session's own id leaks into the `flow-state.sh get --field ...`
# call inside work-memory-update.sh's run_update() helper (no `--session`
# passed) and silently overrides the file-based per-session fixtures, making
# the read resolve a nonexistent (or wrong) flow-state file. Unsetting both
# here forces every invocation to resolve session_id from the fixture's
# `.rite-session-id` file, matching the intended test isolation.
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELPER="$SCRIPT_DIR/../work-memory-update.sh"

if [ ! -f "$HELPER" ]; then
  echo "ERROR: work-memory-update.sh missing: $HELPER" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required but not installed" >&2
  exit 1
fi

# Source common helpers for make_sandbox.
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"

cleanup_dirs=()
_wm_update_test_cleanup() {
  local d
  for d in "${cleanup_dirs[@]:-}"; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
  done
  return 0  # Form B (portability variant) → return 0 必須 (bash-trap-patterns.md "cleanup 関数の契約" 節 Form B 参照)
}
trap '_wm_update_test_cleanup' EXIT
trap '_wm_update_test_cleanup; exit 130' INT
trap '_wm_update_test_cleanup; exit 143' TERM
trap '_wm_update_test_cleanup; exit 129' HUP

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

assert_contains() {
  local name="$1" expected_substring="$2" actual="$3"
  if [[ "$actual" == *"$expected_substring"* ]]; then
    echo "  ✅ $name"
    PASS=$((PASS+1))
  else
    echo "  ❌ $name"
    echo "     expected substring: $expected_substring"
    echo "     actual:             $actual"
    FAIL=$((FAIL+1))
    FAILED_NAMES+=("$name")
  fi
}

# make_sandbox is now provided by _test-helpers.sh; callers below
# invoke `make_sandbox --branch fix/issue-687-test` to preserve the
# branch-based issue-number extraction path validated by TC-1.
# The fix/issue-687-test branch name is the SoT for EXPECTED_ISSUE_NUM=687
# below (any branch rename would require both call sites to sync).

# rite-config.yml sandbox marker. flow-state is always per-session (no
# `flow_state.schema_version` selection), so the fixture writes a
# neutral config rather than modeling the removed schema_version key.
write_config() {
  printf '# rite test sandbox config\n' > "$1/rite-config.yml"
}

write_session_id() {
  echo "$2" > "$1/.rite-session-id"
}

write_per_session() {
  mkdir -p "$1/.rite/sessions"
  printf '%s' "$3" > "$1/.rite/sessions/${2}.flow-state"
}

write_legacy() {
  printf '%s' "$2" > "$1/.rite-flow-state"
}

run_update() {
  local d="$1"
  shift
  # 残りの引数 (KEY=VALUE 形式) を env に渡し、その後 bash -c で関数を呼ぶ
  (cd "$d" && env WM_PLUGIN_ROOT="$PLUGIN_ROOT" "$@" bash -c \
    'source "$WM_PLUGIN_ROOT/hooks/work-memory-update.sh" && update_local_work_memory')
}

# 読み戻し不能 WARNING の照合文字列。肯定側 / 否定側の双方から参照されるため 1 箇所に集約する —
# 別々にリテラルを持つと、文言変更で肯定側だけ追随して否定側が恒久的に vacuous になる
# (grep が何にも一致しなくなり「WARNING が出ていない」と誤って PASS する)。
WARN_CARRY_FWD="既存 WM から値を読み戻せませんでした"
# corrupt 判定でも .data が埋まっている経路で出る別 WARNING。読み戻し不能側と文面を分けてあるので、
# 照合文字列も分けて持ち、両者の取り違えを検出できるようにする。
WARN_CORRUPT_FWD="既存 WM は corrupt 判定"

# --- TC-1: per-session present + legacy absent + WM_REQUIRE_FLOW_STATE=true ---
# cycle 12 fix の core invariant: WM_REQUIRE_FLOW_STATE check が legacy file 直接 [ -f ] check ではなく
# flow-state.sh 経由になったので per-session のみで skip しない
echo "TC-1: per-session present + legacy absent + WM_REQUIRE_FLOW_STATE=true → return 0 (cycle 12 false negative regression guard)"
SBX=$(make_sandbox --branch fix/issue-687-test); cleanup_dirs+=("$SBX")
write_config "$SBX"
SID="11111111-1111-1111-1111-111111111111"
write_session_id "$SBX" "$SID"
write_per_session "$SBX" "$SID" '{"phase":"phase5_lint","next_action":"continue","pr_number":42,"loop_count":2,"active":true}'
# legacy は意図的に作成しない (per-session only path)

# Cycle 16 fix (F-01 MEDIUM cross-validated 3 reviewers): TC-1.2 dead code 削除。
# work-memory-update.sh の update_local_work_memory 関数内の branch-based issue_number 抽出
# (`grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+'` chain) は数字のみ抽出するため、
# branch=fix/issue-687-test では生成 file 名は issue-687.md (not 687-test)。
# issue-687-test.md を期待する if 分岐は数字のみ抽出する extraction chain と矛盾するため到達せず、
# 常に else 経路 (WM_ISSUE_NUMBER override) が実行される dead 分岐になる。本 TC は branch-based
# extraction の結果 (issue-687.md) を直接 assert し、その dead 分岐への退行を guard する。
# branch-based extraction の直接検証 (cycle 12 false negative regression guard):
# `make_sandbox --branch fix/issue-687-test` が指定の branch を作るため、branch parsing が `687`
# を抽出して `.rite-work-memory/issue-687.md` を生成することを確認する。
#
# F-06 LOW (branch-name coupling 軽減): make_sandbox 呼び出しで渡している
# `--branch fix/issue-687-test` 引数と本 TC の assertion で参照する issue 番号 (687) を local var
# で 1 か所に集約。cycle 3 F-01: make_sandbox は _test-helpers.sh の共通 helper に
# 集約されたため、コメントの「関数内」は誤り — call site の `--branch` 引数が SoT。
# branch 名を変更する場合は本 var と make_sandbox --branch 引数の両方を同期更新する。
EXPECTED_ISSUE_NUM=687  # make_sandbox --branch 引数 "fix/issue-687-test" (下記 call site 参照) から抽出される値 (branch 名を変更する場合は本 var と --branch 引数の両方を同期更新)
if run_update "$SBX" \
  WM_SOURCE="lint" WM_PHASE="phase5_lint" WM_PHASE_DETAIL="quality check" \
  WM_NEXT_ACTION="rite:lint" WM_BODY_TEXT="Test body." \
  WM_REQUIRE_FLOW_STATE="true"; then
  rc=0
else
  rc=$?
fi
assert_eq "TC-1.1: return 0 (per-session resolved via flow-state.sh, branch parsing extracts ${EXPECTED_ISSUE_NUM})" "0" "$rc"
assert_eq "TC-1.2: WM file created via branch parsing (issue-${EXPECTED_ISSUE_NUM}.md)" "yes" \
  "$([ -f "$SBX/.rite-work-memory/issue-${EXPECTED_ISSUE_NUM}.md" ] && echo yes || echo no)"

# --- TC-2: both files absent + WM_REQUIRE_FLOW_STATE=true ---
echo "TC-2: per-session/legacy 両不在 + WM_REQUIRE_FLOW_STATE=true → return 1 (skip)"
SBX=$(make_sandbox --branch fix/issue-687-test); cleanup_dirs+=("$SBX")
write_config "$SBX"
write_session_id "$SBX" "22222222-2222-2222-2222-222222222222"
# per-session は作成しない、legacy も作成しない

if run_update "$SBX" \
  WM_SOURCE="lint" WM_PHASE="phase5_lint" WM_PHASE_DETAIL="quality check" \
  WM_NEXT_ACTION="rite:lint" WM_BODY_TEXT="Test body." \
  WM_REQUIRE_FLOW_STATE="true" WM_ISSUE_NUMBER="687"; then
  rc=0
else
  rc=$?
fi
assert_eq "TC-2.1: return 1 (両 file 不在で skip)" "1" "$rc"
assert_eq "TC-2.2: WM file NOT created" "no" \
  "$([ -f "$SBX/.rite-work-memory/issue-687.md" ] && echo yes || echo no)"

# --- TC-3: WM_READ_FROM_FLOW_STATE=true + per-session has pr_number/loop_count ---
echo "TC-3: per-session pr_number=100 loop_count=3 + WM_READ_FROM_FLOW_STATE=true → frontmatter 反映 (cycle 10 stale residue regression guard)"
SBX=$(make_sandbox --branch fix/issue-687-test); cleanup_dirs+=("$SBX")
write_config "$SBX"
SID="33333333-3333-3333-3333-333333333333"
write_session_id "$SBX" "$SID"
write_per_session "$SBX" "$SID" '{"phase":"phase5_lint","next_action":"continue","pr_number":100,"loop_count":3,"active":true}'
# legacy には別の値を入れて per-session 優先を確認
write_legacy "$SBX" '{"phase":"stale","next_action":"stale","pr_number":999,"loop_count":99,"active":false}'

if run_update "$SBX" \
  WM_SOURCE="lint" WM_PHASE="phase5_lint" WM_PHASE_DETAIL="quality check" \
  WM_NEXT_ACTION="rite:lint" WM_BODY_TEXT="Test body." \
  WM_READ_FROM_FLOW_STATE="true" WM_ISSUE_NUMBER="687"; then
  rc=0
else
  rc=$?
fi
assert_eq "TC-3.1: return 0" "0" "$rc"
WM_FILE="$SBX/.rite-work-memory/issue-687.md"
if [ -f "$WM_FILE" ]; then
  body=$(cat "$WM_FILE")
  assert_contains "TC-3.2: pr_number=100 (per-session 値、legacy 999 を override)" "pr_number: 100" "$body"
  assert_contains "TC-3.3: loop_count=3 (per-session 値、legacy 99 を override)" "loop_count: 3" "$body"
else
  echo "  ❌ TC-3.2/3.3: WM file not created at $WM_FILE"
  FAIL=$((FAIL+2))
  FAILED_NAMES+=("TC-3.2" "TC-3.3")
fi

# TC-4 removed (PR 2a refactor): schema_version=1 + legacy file path is no
# longer reachable. flow-state.sh always writes / reads per-session files at
# `.rite/sessions/<sid>.flow-state`; the legacy single-file form is gone.
# Backward compat for legacy state has migrated to flow-state.sh migrate
# (one-shot v1/v2 → v3 conversion at session-start), not to a parallel
# read path inside work-memory-update.sh.

# ─── TC-5: 蓄積セクション保持 (AC-3) ───────────────────────────────
# `## Detail` 以下に追記された自由記述内容 (蓄積セクション) がフェーズ遷移更新
# (WM_BODY_TEXT による body 再構築) 後も保持されることを検証する。stock の先頭
# Phase:/Branch: 行は最新値で再生成され、それ以外の蓄積内容が verbatim で残る契約。
echo "TC-5: 蓄積セクション保持 (フェーズ遷移更新で Detail 以下が消えない)"
SBX5=$(make_sandbox --branch fix/issue-687-test)
cleanup_dirs+=("$SBX5")
write_config "$SBX5"

# 1 回目の更新で WM ファイルを生成
run_update "$SBX5" \
  WM_SOURCE="implement" WM_PHASE="implement" WM_PHASE_DETAIL="impl" \
  WM_NEXT_ACTION="next" WM_BODY_TEXT="First body." WM_ISSUE_NUMBER="687" >/dev/null 2>&1 || true
WM_FILE5="$SBX5/.rite-work-memory/issue-687.md"
# 蓄積セクションを Detail 以下に追記 (local `## Detail` への自由記述追記を模擬)
cat >> "$WM_FILE5" <<'ACCUM_EOF'

### 決定事項・メモ
- 2026-07-13: 重要な設計判断テスト行

### 計画逸脱ログ
- S2: 逸脱テスト行
ACCUM_EOF

# 2 回目の更新 (フェーズ遷移)
if run_update "$SBX5" \
  WM_SOURCE="ready" WM_PHASE="ready" WM_PHASE_DETAIL="Ready処理完了" \
  WM_NEXT_ACTION="merge" WM_BODY_TEXT="Second body." WM_ISSUE_NUMBER="687" >/dev/null 2>&1; then
  rc5=0
else
  rc5=$?
fi
assert_eq "TC-5.1: return 0" "0" "$rc5"
if [ -f "$WM_FILE5" ]; then
  body5=$(cat "$WM_FILE5")
  assert_contains "TC-5.2: 決定事項・メモ の追記が保持される" "重要な設計判断テスト行" "$body5"
  assert_contains "TC-5.3: 計画逸脱ログ の追記が保持される" "S2: 逸脱テスト行" "$body5"
  assert_contains "TC-5.4: サマリー領域は新 WM_BODY_TEXT に置換される" "Second body." "$body5"
  assert_contains "TC-5.5: stock Phase 行は最新 phase で再生成される" $'## Detail\nPhase: ready' "$body5"
  # stock Phase:/Branch: 行が重複していないこと (保持ロジックが stock 行を二重化しない)
  phase_line_count=$(printf '%s\n' "$body5" | grep -c '^Phase: ' || true)
  assert_eq "TC-5.6: Phase 行が 1 本のみ (stock 行の二重化なし)" "1" "$phase_line_count"
else
  echo "  ❌ TC-5.x: WM file not created at $WM_FILE5"
  FAIL=$((FAIL+5))
  FAILED_NAMES+=("TC-5.2" "TC-5.3" "TC-5.4" "TC-5.5" "TC-5.6")
fi

# ─── T-01 / T-02: 通常更新経路の carry-forward ────────────────────
# 通常更新 (env override も flow-state 読みも伴わない、全スキルが通る経路) で pr_number /
# loop_count が既定値に巻き戻らないことを検証する。fixture は frontmatter を手書きせず 1 回目の run_update
# (env override で seed) で writer 実体に生成させ、2 回目を bare 呼び出しにする — TC-5 と同じ
# 2 段パターンで、writer の書式変更にテストが追随できなくなるドリフトを防ぐ。
echo "T-01/T-02: 通常更新で pr_number / loop_count が carry-forward される"
SBX6=$(make_sandbox --branch fix/issue-687-test); cleanup_dirs+=("$SBX6")
write_config "$SBX6"
run_update "$SBX6" \
  WM_SOURCE="create" WM_PHASE="pr" WM_PHASE_DETAIL="PR作成完了" \
  WM_NEXT_ACTION="next" WM_BODY_TEXT="Seed body." WM_ISSUE_NUMBER="687" \
  WM_PR_NUMBER="123" WM_LOOP_COUNT="3" >/dev/null 2>&1 || true
WM_FILE6="$SBX6/.rite-work-memory/issue-687.md"
seed6=$(cat "$WM_FILE6" 2>/dev/null || echo "")
assert_contains "T-01.0: seed で pr_number=123 が書かれる (前提確認)" "pr_number: 123" "$seed6"
assert_contains "T-02.0: seed で loop_count=3 が書かれる (前提確認)" "loop_count: 3" "$seed6"

if run_update "$SBX6" \
  WM_SOURCE="implement" WM_PHASE="lint" WM_PHASE_DETAIL="品質チェック準備" \
  WM_NEXT_ACTION="rite:lint" WM_BODY_TEXT="Post-implementation." WM_ISSUE_NUMBER="687" >/dev/null 2>&1; then
  rc6=0
else
  rc6=$?
fi
assert_eq "T-01.1: 通常更新が return 0" "0" "$rc6"
body6=$(cat "$WM_FILE6" 2>/dev/null || echo "")
assert_contains "T-01.2: pr_number=123 が保持される (AC-1)" "pr_number: 123" "$body6"
assert_contains "T-02.1: loop_count=3 が保持される (AC-2)" "loop_count: 3" "$body6"
assert_contains "T-01.3: sync_revision は加算され続ける (carry-forward が版管理を壊さない)" "sync_revision: 2" "$body6"

# ─── T-03: frontmatter 破損時は既定値に倒れる ─────────────────────
# fixture はヘッダマーカー行を削る。work-memory-parse.py は missing_header で .data を空のまま
# 返すため carry-forward の材料が無くなる — キー欠落だけの fixture では .data が埋まって
# carry-forward が正当に発火し、本 TC が空虚になる。
echo "T-03: frontmatter 破損時は exit 0 かつ既定値 (null / 0) で書き出される"
SBX7=$(make_sandbox --branch fix/issue-687-test); cleanup_dirs+=("$SBX7")
write_config "$SBX7"
run_update "$SBX7" \
  WM_SOURCE="create" WM_PHASE="pr" WM_PHASE_DETAIL="PR作成完了" \
  WM_NEXT_ACTION="next" WM_BODY_TEXT="Seed body." WM_ISSUE_NUMBER="687" \
  WM_PR_NUMBER="123" WM_LOOP_COUNT="3" >/dev/null 2>&1 || true
WM_FILE7="$SBX7/.rite-work-memory/issue-687.md"
# seed を 2 回回して sync_revision: 2 の状態を作ってから壊す。1 回だけだと元ファイルが
# sync_revision: 1 で、縮退後の「1 から採番し直す」と値が一致してしまい T-03.5 が空虚になる。
run_update "$SBX7" \
  WM_SOURCE="implement" WM_PHASE="lint" WM_PHASE_DETAIL="品質チェック準備" \
  WM_NEXT_ACTION="next" WM_BODY_TEXT="Second seed." WM_ISSUE_NUMBER="687" >/dev/null 2>&1 || true
assert_contains "T-03.0: 破壊前の sync_revision が 2 になっている (前提確認)" "sync_revision: 2" "$(cat "$WM_FILE7" 2>/dev/null || echo "")"
grep -v '^# 📜 rite 作業メモリ$' "$WM_FILE7" > "$WM_FILE7.tmp" && mv "$WM_FILE7.tmp" "$WM_FILE7"

# stderr のみを捕捉する (T-06 と同じ `2>&1 >/dev/null` の順序が必須)。rc は別呼び出しで取ると
# sandbox 状態が変わってしまうため、stderr 捕捉側の rc をそのまま使う。
if err7=$(run_update "$SBX7" \
  WM_SOURCE="implement" WM_PHASE="lint" WM_PHASE_DETAIL="品質チェック準備" \
  WM_NEXT_ACTION="rite:lint" WM_BODY_TEXT="Post-implementation." WM_ISSUE_NUMBER="687" 2>&1 >/dev/null); then
  rc7=0
else
  rc7=$?
fi
assert_eq "T-03.1: return 0 (parse 失敗でも更新は続行、AC-3)" "0" "$rc7"
body7=$(cat "$WM_FILE7" 2>/dev/null || echo "")
assert_contains "T-03.2: pr_number: null (既定値、AC-3)" "pr_number: null" "$body7"
assert_contains "T-03.3: loop_count: 0 (既定値、AC-3)" "loop_count: 0" "$body7"
assert_contains "T-03.4: 読み戻し不能が WARNING で可視化される (silent に既定値へ倒れない)" \
  "$WARN_CARRY_FWD" "$err7"
# WARNING が断定する挙動をそのまま assert する (2 → 1 の巻き戻りなので値で判別できる)
assert_contains "T-03.5: sync_revision が 1 から採番し直される (WARNING の文面どおり)" "sync_revision: 1" "$body7"
# 2 つの WARNING は排他。片方の発火条件が広がって両方出るようになる回帰を検出する
corrupt7=$(printf '%s' "$err7" | grep -c "$WARN_CORRUPT_FWD") || true
assert_eq "T-03.6: 読み戻し不能時は corrupt WARNING を出さない (2 文面の排他性)" "0" "$corrupt7"

# :220 の WARNING は「env override も flow-state 読み取りも無い場合のみ既定値へ倒れます」と
# 条件付きで宣言する。その条件節が守られていること (degraded path が env override を握り潰さない
# こと) を走行で固定する。文言リテラルではなく振る舞いを pin するのは、他コンポーネントの
# メッセージ形式への結合を増やさないため。
SBX22=$(make_sandbox --branch fix/issue-687-test); cleanup_dirs+=("$SBX22")
write_config "$SBX22"
run_update "$SBX22" \
  WM_SOURCE="create" WM_PHASE="pr" WM_PHASE_DETAIL="PR作成完了" \
  WM_NEXT_ACTION="next" WM_BODY_TEXT="Seed body." WM_ISSUE_NUMBER="687" \
  WM_PR_NUMBER="123" WM_LOOP_COUNT="3" >/dev/null 2>&1 || true
WM_FILE22="$SBX22/.rite-work-memory/issue-687.md"
grep -v '^# 📜 rite 作業メモリ$' "$WM_FILE22" > "$WM_FILE22.tmp" && mv "$WM_FILE22.tmp" "$WM_FILE22"
err22=$(run_update "$SBX22" \
  WM_SOURCE="pre-compact" WM_PHASE="lint" WM_PHASE_DETAIL="compact 前保存" \
  WM_NEXT_ACTION="resume" WM_BODY_TEXT="Post." WM_ISSUE_NUMBER="687" \
  WM_PR_NUMBER="456" WM_LOOP_COUNT="9" 2>&1 >/dev/null) || true
body22=$(cat "$WM_FILE22" 2>/dev/null || echo "")
assert_contains "T-03.7a: 読み戻し不能経路に入っている (前提確認)" "$WARN_CARRY_FWD" "$err22"
assert_contains "T-03.7: 読み戻し不能でも env override は握り潰されない (pr_number)" "pr_number: 456" "$body22"
assert_contains "T-03.8: 同 (loop_count — 変異は 2 field 同時に潰すため片側だけでは残る)" "loop_count: 9" "$body22"

# ─── T-04: env override が既存ファイル値より優先される ───────────
# pr_number / loop_count は独立した 2 つの条件式で守られているため、両方を検証する
# (片方だけだと、もう一方のガード除去が無検知で通る)。
echo "T-04: WM_PR_NUMBER / WM_LOOP_COUNT 設定時は既存ファイル値ではなく env 値が採用される"
SBX8=$(make_sandbox --branch fix/issue-687-test); cleanup_dirs+=("$SBX8")
write_config "$SBX8"
run_update "$SBX8" \
  WM_SOURCE="create" WM_PHASE="pr" WM_PHASE_DETAIL="PR作成完了" \
  WM_NEXT_ACTION="next" WM_BODY_TEXT="Seed body." WM_ISSUE_NUMBER="687" \
  WM_PR_NUMBER="123" WM_LOOP_COUNT="3" >/dev/null 2>&1 || true
WM_FILE8="$SBX8/.rite-work-memory/issue-687.md"
seed8=$(cat "$WM_FILE8" 2>/dev/null || echo "")
# seed 前提確認: これが無いと seed 失敗時に 2 回目の env 値がそのまま書かれて
# 「既存ファイル値を override した」検証が空虚に PASS する
assert_contains "T-04.0a: seed で pr_number=123 が書かれる (前提確認)" "pr_number: 123" "$seed8"
assert_contains "T-04.0b: seed で loop_count=3 が書かれる (前提確認)" "loop_count: 3" "$seed8"

if run_update "$SBX8" \
  WM_SOURCE="pre-compact" WM_PHASE="lint" WM_PHASE_DETAIL="compact 前保存" \
  WM_NEXT_ACTION="resume" WM_BODY_TEXT="Pre-compact." WM_ISSUE_NUMBER="687" \
  WM_PR_NUMBER="456" WM_LOOP_COUNT="9" >/dev/null 2>&1; then
  rc8=0
else
  rc8=$?
fi
assert_eq "T-04.1: return 0" "0" "$rc8"
body8=$(cat "$WM_FILE8" 2>/dev/null || echo "")
assert_contains "T-04.2: pr_number=456 (env が既存ファイル値 123 を override、AC-4)" "pr_number: 456" "$body8"
assert_contains "T-04.3: loop_count=9 (env が既存ファイル値 3 を override、AC-4)" "loop_count: 9" "$body8"

# ─── T-05: WM_READ_FROM_FLOW_STATE 経路の非回帰 ──────────────────
# carry-forward ブロックより後段の flow-state 上書きが最終値である契約 (優先順位 1 位) を守る。
# 優先順位 1 位は敗者を 2 つ持つ (env override / 既存ファイル値) が、1 本の走行では両方を同時に
# 立てられない。carry-forward のガードが `-z "${WM_PR_NUMBER:-}"` なので、env override を渡した
# 走行では carry-forward がそもそも発火せず、既存ファイル値は候補にすらならない。よって 2 本走らせる。
# 走行 1 は flow-state 読取を carry-forward ガードと同型の「env 未設定時のみ」へ縮退させる変異で
# Red になり、走行 2 はその変異では Green のまま素通りする (実測確認済み)。
# TC-3 も flow-state 読取を通るが、既存 WM を持たない fixture なので carry-forward との競合が
# 起きない。走行 2 はその競合を起こす入力を与える。
echo "T-05: WM_READ_FROM_FLOW_STATE=true では flow-state 値が既存ファイル値・env override の双方に優先される"
SBX9=$(make_sandbox --branch fix/issue-687-test); cleanup_dirs+=("$SBX9")
write_config "$SBX9"
SID9="99999999-9999-9999-9999-999999999999"
write_session_id "$SBX9" "$SID9"
write_per_session "$SBX9" "$SID9" '{"phase":"lint","next_action":"continue","pr_number":789,"loop_count":7,"active":true}'
run_update "$SBX9" \
  WM_SOURCE="create" WM_PHASE="pr" WM_PHASE_DETAIL="PR作成完了" \
  WM_NEXT_ACTION="next" WM_BODY_TEXT="Seed body." WM_ISSUE_NUMBER="687" \
  WM_PR_NUMBER="123" WM_LOOP_COUNT="4" >/dev/null 2>&1 || true
WM_FILE9="$SBX9/.rite-work-memory/issue-687.md"

# 走行 1: env override 有り
if run_update "$SBX9" \
  WM_SOURCE="lint" WM_PHASE="lint" WM_PHASE_DETAIL="quality check" \
  WM_NEXT_ACTION="rite:lint" WM_BODY_TEXT="Lint body." WM_ISSUE_NUMBER="687" \
  WM_PR_NUMBER="555" WM_LOOP_COUNT="55" \
  WM_READ_FROM_FLOW_STATE="true" >/dev/null 2>&1; then
  rc9=0
else
  rc9=$?
fi
assert_eq "T-05.1: return 0 (env override 有り)" "0" "$rc9"
body9=$(cat "$WM_FILE9" 2>/dev/null || echo "")
assert_contains "T-05.2: pr_number=789 (flow-state 値が env override 555 に勝つ、AC-5)" "pr_number: 789" "$body9"
assert_contains "T-05.3: loop_count=7 (flow-state 値が env override 55 に勝つ、AC-5)" "loop_count: 7" "$body9"

# 走行 2: env override 無し (carry-forward が材料を持つ状態で flow-state が勝つことを固定する)
SBX9B=$(make_sandbox --branch fix/issue-687-test); cleanup_dirs+=("$SBX9B")
write_config "$SBX9B"
SID9B="99999999-9999-9999-9999-99999999999b"
write_session_id "$SBX9B" "$SID9B"
write_per_session "$SBX9B" "$SID9B" '{"phase":"lint","next_action":"continue","pr_number":789,"loop_count":7,"active":true}'
run_update "$SBX9B" \
  WM_SOURCE="create" WM_PHASE="pr" WM_PHASE_DETAIL="PR作成完了" \
  WM_NEXT_ACTION="next" WM_BODY_TEXT="Seed body." WM_ISSUE_NUMBER="687" \
  WM_PR_NUMBER="123" WM_LOOP_COUNT="4" >/dev/null 2>&1 || true
# 走行 2 は seed が書けたことに依存する。seed が落ちると carry-forward の材料が消え、flow-state の
# 値がそのまま書かれて T-05.5 / T-05.6 が vacuous に PASS する (走行 2 が脱出しようとした TC-3 と
# 同じ状態への silent な縮退)。他群と同形の前提確認で pin する。
seed9b=$(cat "$SBX9B/.rite-work-memory/issue-687.md" 2>/dev/null || echo "")
assert_contains "T-05.0a: seed で pr_number=123 が書かれる (前提確認)" "pr_number: 123" "$seed9b"
assert_contains "T-05.0b: seed で loop_count=4 が書かれる (前提確認)" "loop_count: 4" "$seed9b"
if run_update "$SBX9B" \
  WM_SOURCE="lint" WM_PHASE="lint" WM_PHASE_DETAIL="quality check" \
  WM_NEXT_ACTION="rite:lint" WM_BODY_TEXT="Lint body." WM_ISSUE_NUMBER="687" \
  WM_READ_FROM_FLOW_STATE="true" >/dev/null 2>&1; then
  rc9b=0
else
  rc9b=$?
fi
assert_eq "T-05.4: return 0 (env override 無し)" "0" "$rc9b"
body9b=$(cat "$SBX9B/.rite-work-memory/issue-687.md" 2>/dev/null || echo "")
assert_contains "T-05.5: pr_number=789 (flow-state 値が既存ファイル値 123 に勝つ、AC-5)" "pr_number: 789" "$body9b"
assert_contains "T-05.6: loop_count=7 (flow-state 値が既存ファイル値 4 に勝つ、AC-5)" "loop_count: 7" "$body9b"

# ─── T-06: 改竄値の carry-forward は null へ降格し WARNING が出る ──
# carry-forward が _validate_numeric_yaml_value を迂回しないこと (YAML injection 防御の維持)。
# pr_number / loop_count は独立に carry-forward されるため両方を改竄して検証する。
echo "T-06: 非数値を含む改竄 WM の carry-forward が null へ降格し WARNING が出る"
SBX10=$(make_sandbox --branch fix/issue-687-test); cleanup_dirs+=("$SBX10")
write_config "$SBX10"
run_update "$SBX10" \
  WM_SOURCE="create" WM_PHASE="pr" WM_PHASE_DETAIL="PR作成完了" \
  WM_NEXT_ACTION="next" WM_BODY_TEXT="Seed body." WM_ISSUE_NUMBER="687" \
  WM_PR_NUMBER="123" WM_LOOP_COUNT="3" >/dev/null 2>&1 || true
WM_FILE10="$SBX10/.rite-work-memory/issue-687.md"
# fixture 改竄は awk read→transform→write→mv 形式で行う (GNU 形式の `sed -i '<expr>'` は
# BSD sed が -i の引数を必須とするため macOS で失敗し、set -e 下でスイート全体が中断する)
awk '{
  if ($0 == "pr_number: 123") print "pr_number: \"12x3\"";
  else if ($0 == "loop_count: 3") print "loop_count: \"3y\"";
  else print
}' "$WM_FILE10" > "$WM_FILE10.tmp" && mv "$WM_FILE10.tmp" "$WM_FILE10"

# stderr のみを捕捉する (run_update は subshell。`2>&1 >/dev/null` の順序が必須 —
# 逆順だと stdout の複製先が /dev/null になり WARNING を取り逃がす)
err10=$(run_update "$SBX10" \
  WM_SOURCE="implement" WM_PHASE="lint" WM_PHASE_DETAIL="品質チェック準備" \
  WM_NEXT_ACTION="rite:lint" WM_BODY_TEXT="Post-implementation." WM_ISSUE_NUMBER="687" 2>&1 >/dev/null) || true
body10=$(cat "$WM_FILE10" 2>/dev/null || echo "")
assert_contains "T-06.1: 非数値は pr_number: null へ降格する" "pr_number: null" "$body10"
assert_contains "T-06.2: WARNING が stderr に出る (silent 降格しない)" "non-numeric character" "$err10"
assert_contains "T-06.3: 非数値は loop_count: null へ降格する" "loop_count: null" "$body10"

# ─── T-07: set -e 下の bare 呼び出しでも更新が完走する ────────────
# 本 helper を source する caller (pre-compact.sh / post-tool-wm-sync.sh) は `set -euo pipefail`
# 下にあり、現状はいずれも if 条件文脈で呼ぶため bash が errexit を停止している。その呼び出し形に
# 「carry-forward の失敗で更新全体を失敗させない」契約を依存させないことを、条件文脈を使わない
# bare 呼び出しで検証する。run_update は bash -c 経由で errexit を持たないため、本 TC のみ
# 明示的に set -euo pipefail を張った sandbox 実行を組む。
echo "T-07: set -e 下の bare 呼び出しで corrupt WM を読んでも更新が完走する"
SBX11=$(make_sandbox --branch fix/issue-687-test); cleanup_dirs+=("$SBX11")
write_config "$SBX11"
mkdir -p "$SBX11/.rite-work-memory"
# ヘッダマーカー不在 = work-memory-parse.py が exit 2 を返す corrupt fixture
printf '## Summary\n---\nschema_version: 1\nissue_number: 687\nsync_revision: 1\npr_number: 123\n---\nbody\n' \
  > "$SBX11/.rite-work-memory/issue-687.md"

if (cd "$SBX11" && env WM_PLUGIN_ROOT="$PLUGIN_ROOT" \
  WM_SOURCE="implement" WM_PHASE="lint" WM_PHASE_DETAIL="品質チェック準備" \
  WM_NEXT_ACTION="rite:lint" WM_BODY_TEXT="Post-implementation." WM_ISSUE_NUMBER="687" \
  bash -c 'set -euo pipefail; source "$WM_PLUGIN_ROOT/hooks/work-memory-update.sh"; update_local_work_memory') >/dev/null 2>&1; then
  rc11=0
else
  rc11=$?
fi
assert_eq "T-07.1: set -e + bare 呼び出しで return 0 (errexit で中断しない)" "0" "$rc11"
body11=$(cat "$SBX11/.rite-work-memory/issue-687.md" 2>/dev/null || echo "")
assert_contains "T-07.2: WM が実際に書き換わる (更新が完走している)" "Post-implementation." "$body11"

# ─── T-08: corrupt 判定でも .data が埋まるファイルは carry-forward される ──
# 「`|| _parse_rc=$?` であって `|| parse_out=空文字` ではない」という設計判断を固定する。
# T-03 / T-07 の fixture はヘッダマーカー不在型で work-memory-parse.py が .data を空で返すため、
# この 2 つの書き方を判別できない。判別にはヘッダマーカーを保ったまま corrupt になる fixture が
# 要る — parse.py は corrupt 判定を返しつつ .data を全埋めするため、stdout を捨てる書き方だと
# sync_revision が 1 へ巻き戻り pr_number / loop_count も既定値へ落ちる。
# **種別は missing_keys を使う** — issue_number_mismatch は .data が別 Issue のものなので
# carry-forward してはならず (T-14 がその側を pin する)、carry-forward 肯定側の fixture には使えない。
# あわせて、この経路で縮退 WARNING が出ないこと (parse の rc ではなく carry-forward の材料の
# 有無で発火判定していること) も固定する — rc を条件にすると成功経路で誤報になる。
echo "T-08: corrupt-but-parseable (missing_keys) な WM でも carry-forward と sync_revision 加算が維持される"
SBX12=$(make_sandbox --branch fix/issue-687-test); cleanup_dirs+=("$SBX12")
write_config "$SBX12"
mkdir -p "$SBX12/.rite-work-memory"
printf '# 📜 rite 作業メモリ\n\n## Summary\n---\nissue_number: 687\nsync_revision: 5\npr_number: 123\nloop_count: 4\n---\n\nbody\n' \
  > "$SBX12/.rite-work-memory/issue-687.md"
# 前提確認: この fixture が「corrupt 判定 かつ .data 全埋め かつ 種別が missing_keys」であること
# (この性質が崩れると本 TC は空虚になる)
parse12=$(python3 "$PLUGIN_ROOT/hooks/work-memory-parse.py" "$SBX12/.rite-work-memory/issue-687.md" 2>/dev/null || true)
assert_contains "T-08.0a: fixture が corrupt 判定される (前提確認)" '"status": "corrupt"' "$parse12"
assert_contains "T-08.0b: corrupt でも .data に sync_revision が埋まる (前提確認)" '"sync_revision": 5' "$parse12"
assert_contains "T-08.0c: 種別が missing_keys である (前提確認 — mismatch だと carry-forward が止まる)" 'missing_keys' "$parse12"

if err12=$(run_update "$SBX12" \
  WM_SOURCE="implement" WM_PHASE="lint" WM_PHASE_DETAIL="品質チェック準備" \
  WM_NEXT_ACTION="rite:lint" WM_BODY_TEXT="Post-implementation." WM_ISSUE_NUMBER="687" 2>&1 >/dev/null); then
  rc12=0
else
  rc12=$?
fi
assert_eq "T-08.1: return 0 (corrupt 判定でも更新は続行)" "0" "$rc12"
body12=$(cat "$SBX12/.rite-work-memory/issue-687.md" 2>/dev/null || echo "")
assert_contains "T-08.2: sync_revision が 6 へ加算される (版が逆行しない)" "sync_revision: 6" "$body12"
assert_contains "T-08.3: pr_number=123 が carry-forward される" "pr_number: 123" "$body12"
assert_contains "T-08.4: loop_count=4 が carry-forward される" "loop_count: 4" "$body12"
warn12=$(printf '%s' "$err12" | grep -c "$WARN_CARRY_FWD") || true
assert_eq "T-08.5: carry-forward 成功時は読み戻し不能 WARNING を出さない (誤報しない)" "0" "$warn12"
# 照合 literal に errors 本文を含める。WARNING の文言だけを見ると、corrupt の**種別**を落とす変異
# (errors 添付の撤去 / "(種別不明)" への恒久縮退) が素通りする。種別が出ないと、
# 人間は「どの corrupt 判定から carry-forward したのか」を WARNING 単体から特定できない。
assert_contains "T-08.6: corrupt 判定からの carry-forward は corrupt 種別つきの WARNING で可視化される" \
  "$WARN_CORRUPT_FWD (parse rc=2, errors: missing_keys: schema_version)" "$err12"

# ─── T-14: issue_number_mismatch からは carry-forward しない ─────────
# .data が別 Issue のものである以上、carry-forward は他 Issue の pr_number / loop_count を本 Issue の
# WM へ転写する。しかも同じ書き込みが issue_number をファイル名側の値へ直すため、次回 parse は
# valid 判定になり転写の痕跡が消えて再検出できない。sync_revision の加算 (版が逆行しないための
# `.data` 保持) は維持したまま、値の採用だけを止めることを固定する。
echo "T-14: issue_number_mismatch の WM からは carry-forward せず既定値へ倒す"
SBX18=$(make_sandbox --branch fix/issue-687-test); cleanup_dirs+=("$SBX18")
write_config "$SBX18"
mkdir -p "$SBX18/.rite-work-memory"
printf '# 📜 rite 作業メモリ\n\n## Summary\n---\nschema_version: 1\nissue_number: 999\nsync_revision: 5\npr_number: 4242\nloop_count: 7\n---\n\nbody\n' \
  > "$SBX18/.rite-work-memory/issue-687.md"
parse18=$(python3 "$PLUGIN_ROOT/hooks/work-memory-parse.py" "$SBX18/.rite-work-memory/issue-687.md" 2>/dev/null || true)
assert_contains "T-14.0a: fixture が issue_number_mismatch と判定される (前提確認)" 'issue_number_mismatch' "$parse18"
assert_contains "T-14.0b: mismatch でも .data に pr_number が埋まる (前提確認 — 転写の材料は存在する)" '"pr_number": 4242' "$parse18"

if err18=$(run_update "$SBX18" \
  WM_SOURCE="implement" WM_PHASE="lint" WM_PHASE_DETAIL="品質チェック準備" \
  WM_NEXT_ACTION="rite:lint" WM_BODY_TEXT="Post-implementation." WM_ISSUE_NUMBER="687" 2>&1 >/dev/null); then
  rc18=0
else
  rc18=$?
fi
assert_eq "T-14.1: return 0 (mismatch でも更新は続行)" "0" "$rc18"
body18=$(cat "$SBX18/.rite-work-memory/issue-687.md" 2>/dev/null || echo "")
assert_contains "T-14.2: sync_revision は 6 へ加算される (版の逆行防止は維持)" "sync_revision: 6" "$body18"
assert_contains "T-14.3: pr_number は転写されず null へ倒れる (AC-1)" "pr_number: null" "$body18"
assert_contains "T-14.4: loop_count も転写されず 0 へ倒れる (AC-2)" "loop_count: 0" "$body18"
assert_contains "T-14.5: carry-forward を止めたことが WARNING に出る (silent に倒さない)" \
  "carry-forward は行いません" "$err18"

# :239 の _block_tag も :220 と同じ条件節を宣言する。遮断が env override まで潰していないことを
# 走行で固定する (T-03.7 / T-03.8 と対の関係)。
SBX23=$(make_sandbox --branch fix/issue-687-test); cleanup_dirs+=("$SBX23")
write_config "$SBX23"
mkdir -p "$SBX23/.rite-work-memory"
printf '# 📜 rite 作業メモリ\n\n## Summary\n---\nschema_version: 1\nissue_number: 999\nsync_revision: 5\npr_number: 4242\nloop_count: 7\n---\n\nbody\n' \
  > "$SBX23/.rite-work-memory/issue-687.md"
err23=$(run_update "$SBX23" \
  WM_SOURCE="pre-compact" WM_PHASE="lint" WM_PHASE_DETAIL="compact 前保存" \
  WM_NEXT_ACTION="resume" WM_BODY_TEXT="Post." WM_ISSUE_NUMBER="687" \
  WM_PR_NUMBER="456" WM_LOOP_COUNT="9" 2>&1 >/dev/null) || true
body23=$(cat "$SBX23/.rite-work-memory/issue-687.md" 2>/dev/null || echo "")
assert_contains "T-14.6a: carry-forward 遮断経路に入っている (前提確認)" "carry-forward は行いません" "$err23"
assert_contains "T-14.6: 遮断時でも env override は握り潰されない (pr_number)" "pr_number: 456" "$body23"
assert_contains "T-14.7: 同 (loop_count)" "loop_count: 9" "$body23"

# ─── T-19: identity を確認できない corrupt (issue_number 欠落) も遮断する ──
# mismatch だけを判定キーにすると、issue_number 行を「消す」だけで遮断を迂回できる。
# 書き込み側は issue_number をファイル名側の値で再生成するため次回 parse は valid に戻り、
# 転写の痕跡も消える (T-14 が塞いだ経路と結果は同じで、入口だけが違う)。
echo "T-19: issue_number 欠落の corrupt からも carry-forward しない"
SBX25=$(make_sandbox --branch fix/issue-687-test); cleanup_dirs+=("$SBX25")
write_config "$SBX25"
mkdir -p "$SBX25/.rite-work-memory"
printf '# 📜 rite 作業メモリ\n\n## Summary\n---\nschema_version: 1\nsync_revision: 5\npr_number: 4242\nloop_count: 7\n---\n\nbody\n' \
  > "$SBX25/.rite-work-memory/issue-687.md"
parse25=$(python3 "$PLUGIN_ROOT/hooks/work-memory-parse.py" "$SBX25/.rite-work-memory/issue-687.md" 2>/dev/null || true)
assert_contains "T-19.0a: fixture が missing_keys: issue_number と判定される (前提確認)" 'missing_keys: issue_number' "$parse25"
assert_contains "T-19.0b: .data に pr_number が埋まる (前提確認 — 転写の材料は存在する)" '"pr_number": 4242' "$parse25"
err25=$(run_update "$SBX25" \
  WM_SOURCE="implement" WM_PHASE="lint" WM_PHASE_DETAIL="品質チェック準備" \
  WM_NEXT_ACTION="rite:lint" WM_BODY_TEXT="Post-implementation." WM_ISSUE_NUMBER="687" 2>&1 >/dev/null) || true
body25=$(cat "$SBX25/.rite-work-memory/issue-687.md" 2>/dev/null || echo "")
assert_contains "T-19.1: sync_revision は 6 へ加算される (版の逆行防止は維持)" "sync_revision: 6" "$body25"
assert_contains "T-19.2: pr_number は転写されず null へ倒れる" "pr_number: null" "$body25"
assert_contains "T-19.3: loop_count も転写されず 0 へ倒れる" "loop_count: 0" "$body25"
assert_contains "T-19.4: 遮断したことが WARNING に出る (silent に転写しない)" "carry-forward は行いません" "$err25"

# ─── T-15: corrupt WARNING は errors がファイル内容大でも clamp される ──
# parse.py の issue_number_mismatch は frontmatter の値をそのまま埋め込むため、errors は
# ファイル内容と同オーダーまで伸びる。この WARNING は改行を含まない 1 行なので、clamp しないと
# 同時に出ている他の診断行が実質的に読めなくなる。clamp は jq 側の `.[0:200]` で行っており、
# pipeline 末尾の `head -c` ではない (後者は上流 jq を SIGPIPE で殺し、pipefail を張る caller で
# 巨大 errors のときだけ種別が丸ごと失われる)。**pipefail 下でも clamp が効くこと**を pin する。
echo "T-15: corrupt WARNING の errors は巨大入力でも clamp される (pipefail 下でも縮退しない)"
SBX19=$(make_sandbox --branch fix/issue-687-test); cleanup_dirs+=("$SBX19")
write_config "$SBX19"
mkdir -p "$SBX19/.rite-work-memory"
# 非数値にする — 数値だと parse.py の int() が Python 3.11+ の桁数上限で ValueError を投げ、
# stdout 空 = 読み戻し不能経路へ落ちて corrupt WARNING 自体が出ない (本 TC が空虚になる)。
# 長さは pipe buffer (64 KiB) 超に取る — clamp を pipeline 末尾の head -c へ戻す変異は、
# この閾値を超えたときだけ SIGPIPE で種別を失うため。
BIG19=$(python3 -c "print('a'*70000)")
printf '# 📜 rite 作業メモリ\n\n## Summary\n---\nschema_version: 1\nissue_number: %s\nsync_revision: 5\npr_number: 123\nloop_count: 4\n---\n\nbody\n' "$BIG19" \
  > "$SBX19/.rite-work-memory/issue-687.md"
# bare 呼び出し + set -o pipefail で本番 caller (pre-compact.sh / post-tool-wm-sync.sh) と同条件にする
err19=$( (cd "$SBX19" && env WM_PLUGIN_ROOT="$PLUGIN_ROOT" \
  WM_SOURCE="implement" WM_PHASE="lint" WM_PHASE_DETAIL="品質チェック準備" \
  WM_NEXT_ACTION="rite:lint" WM_BODY_TEXT="Post-implementation." WM_ISSUE_NUMBER="687" \
  bash -c 'set -euo pipefail; source "$WM_PLUGIN_ROOT/hooks/work-memory-update.sh"; update_local_work_memory') 2>&1 >/dev/null ) || true
warn19=$(printf '%s' "$err19" | grep "$WARN_CORRUPT_FWD" | head -1) || true
assert_eq "T-15.1: corrupt WARNING 行が clamp されている (2000 バイト未満)" "yes" \
  "$([ "$(printf '%s' "$warn19" | wc -c)" -lt 2000 ] && echo yes || echo no)"
assert_eq "T-15.2: pipefail 下でも corrupt 種別が (種別不明) へ潰れない" "no" \
  "$(printf '%s' "$warn19" | grep -q '種別不明' && echo yes || echo no)"
assert_contains "T-15.3: 種別は issue_number_mismatch として出る" "issue_number_mismatch" "$warn19"

# ─── T-16: 読み戻し不能 WARNING の stderr スニペットは根因行を含む ──────
# python3 の未捕捉例外は traceback の**最終行**に例外メッセージを載せる。スニペットを `head -N` で
# 出すと `Traceback (most recent call last):` とフレームだけが残り、根因が構造的に落ちる。
# 4300 桁超の整数 frontmatter は Python 3.11+ の int↔str 桁数上限で ValueError を投げるため、
# parse.py が multi-line traceback を吐いて stdout 空 (= 読み戻し不能経路) になる。
if python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
  echo "T-16: 読み戻し不能 WARNING のスニペットが python3 traceback の根因行を含む"
  SBX20=$(make_sandbox --branch fix/issue-687-test); cleanup_dirs+=("$SBX20")
  write_config "$SBX20"
  mkdir -p "$SBX20/.rite-work-memory"
  BIG20=$(python3 -c "print('9'*5000)")
  printf '# 📜 rite 作業メモリ\n\n## Summary\n---\nschema_version: 1\nissue_number: %s\nsync_revision: 5\npr_number: 123\nloop_count: 4\n---\n\nbody\n' "$BIG20" \
    > "$SBX20/.rite-work-memory/issue-687.md"
  err20=$(run_update "$SBX20" \
    WM_SOURCE="implement" WM_PHASE="lint" WM_PHASE_DETAIL="品質チェック準備" \
    WM_NEXT_ACTION="rite:lint" WM_BODY_TEXT="Post-implementation." WM_ISSUE_NUMBER="687" 2>&1 >/dev/null) || true
  assert_contains "T-16.0: 前提確認 — 読み戻し不能経路に入る (parse が stdout を出さない)" \
    "$WARN_CARRY_FWD" "$err20"
  assert_contains "T-16.1: スニペットに traceback の根因行 (例外メッセージ) が含まれる" \
    "ValueError" "$err20"
else
  echo "T-16: skip (python3 < 3.11 — int 桁数上限による ValueError を再現できない)"
fi

# ─── T-09: pr-create が WM_PR_NUMBER を seed する静的 pin ─────────
# carry-forward は「保持する」だけで値を生成しない。seed 行が消えると pr_number は
# どの通常更新経路でも書かれないまま (seed も carry-forward の材料も無い状態) に戻るため、
# skill markdown 側を静的に pin する (既存 parity テストと同型)。
echo "T-09: pr-create/SKILL.md が WM_PR_NUMBER seed 行を持つ"
PR_CREATE_MD="$PLUGIN_ROOT/skills/pr-create/SKILL.md"
assert_eq "T-09.0: pr-create/SKILL.md が存在する (前提確認)" "yes" \
  "$([ -f "$PR_CREATE_MD" ] && echo yes || echo no)"
pr_create_body=$(cat "$PR_CREATE_MD" 2>/dev/null || echo "")
# 照合 literal に行継続を含める。継続が落ちると Step 1 冒頭 (WM_SOURCE="create") から本行までの
# WM_* 代入群が「コマンドを伴わない変数代入」
# (= 非 export のシェル変数) に退化し、次行の bash local-wm-update.sh が WM_* を 1 つも受け取らずに
# 実行される — この経路は rc=0 を返し stderr にも何も出さないため、2>/dev/null / || true に
# 関係なく無警告で通る。しかもブランチ名から issue_number が復元されるため no-op にならず、
# source / phase / phase_detail / next_action を空文字で上書きしたまま sync_revision だけを
# 加算する (no-op より重い破壊的上書き。実測確認済み)。
# literal から継続を落とすと、行削除の drift は捕捉できるが 1 文字削除の drift は素通りする。
assert_contains "T-09.1: WM_PR_NUMBER=\"{pr_number}\" の seed 行がある (行継続込み)" 'WM_PR_NUMBER="{pr_number}" \' "$pr_create_body"

# ─── T-10: 既定値状態の WM でも読み戻し不能 WARNING を出さない ────
# 誤報の検証は、否定が最も破られやすい入力で行う必要がある。T-08.5 の fixture は 2 field とも
# 非既定値だが、production で最も多いのは env override 無しで書かれた pr_number: null /
# loop_count: 0 の状態で、pr-create が seed するまでの全更新がこれを先行ファイルとして読む。
# この状態で誤発火すると sync_revision が 1 に凍結し、work-memory-format.md が定義する
# ordering / conflict detection が働かなくなる。あわせて WM 不在からの初回作成でも
# WARNING が出ないことを見る (材料が無いのは正常であって縮退ではない)。
echo "T-10: 既定値状態の WM / WM 不在からの初回作成では読み戻し不能 WARNING を出さない"
SBX13=$(make_sandbox --branch fix/issue-687-test); cleanup_dirs+=("$SBX13")
write_config "$SBX13"
# 1 回目 = WM 不在からの新規作成 (env override なし → pr_number: null / loop_count: 0 が書かれる)
err13a=$(run_update "$SBX13" \
  WM_SOURCE="implement" WM_PHASE="implement" WM_PHASE_DETAIL="実装中" \
  WM_NEXT_ACTION="next" WM_BODY_TEXT="First." WM_ISSUE_NUMBER="687" 2>&1 >/dev/null) || true
WM_FILE13="$SBX13/.rite-work-memory/issue-687.md"
seed13=$(cat "$WM_FILE13" 2>/dev/null || echo "")
assert_contains "T-10.0a: 新規作成で pr_number: null が書かれる (前提確認)" "pr_number: null" "$seed13"
assert_contains "T-10.0b: 新規作成で loop_count: 0 が書かれる (前提確認)" "loop_count: 0" "$seed13"
warn13a=$(printf '%s' "$err13a" | grep -c "$WARN_CARRY_FWD") || true
assert_eq "T-10.1: WM 不在からの初回作成で WARNING を出さない" "0" "$warn13a"

# 2 回目 = 既定値状態の WM を先行ファイルとして読む通常更新
err13b=$(run_update "$SBX13" \
  WM_SOURCE="lint" WM_PHASE="lint" WM_PHASE_DETAIL="品質チェック準備" \
  WM_NEXT_ACTION="rite:lint" WM_BODY_TEXT="Second." WM_ISSUE_NUMBER="687" 2>&1 >/dev/null) || true
body13=$(cat "$WM_FILE13" 2>/dev/null || echo "")
warn13b=$(printf '%s' "$err13b" | grep -c "$WARN_CARRY_FWD") || true
assert_eq "T-10.2: 既定値状態の WM を読んでも WARNING を出さない (誤報しない)" "0" "$warn13b"
assert_contains "T-10.3: sync_revision が 2 へ加算される (1 に凍結しない)" "sync_revision: 2" "$body13"
assert_contains "T-10.4: pr_number: null が維持される" "pr_number: null" "$body13"
assert_contains "T-10.5: loop_count: 0 が維持される" "loop_count: 0" "$body13"
corrupt13=$(printf '%s' "$err13b" | grep -c "$WARN_CORRUPT_FWD") || true
assert_eq "T-10.6: 健全な WM では corrupt WARNING を出さない (誤報しない)" "0" "$corrupt13"

# ─── T-11: env override を片側だけ渡す更新 ────────────────────────
# pr_number / loop_count は独立した 2 つのガードで守られており、片方が他方の env 変数を参照する
# 取り違えは「両方渡す」「両方渡さない」のどちらのケースでも表面化しない。本 PR が pr-create に
# 追加した seed 行は WM_PR_NUMBER だけを渡す = まさにこの片側構成なので、直接 pin する。
echo "T-11: env override を片側だけ渡すと、その field は override / 他方は carry-forward される"
SBX14=$(make_sandbox --branch fix/issue-687-test); cleanup_dirs+=("$SBX14")
write_config "$SBX14"
run_update "$SBX14" \
  WM_SOURCE="create" WM_PHASE="pr" WM_PHASE_DETAIL="PR作成完了" \
  WM_NEXT_ACTION="next" WM_BODY_TEXT="Seed body." WM_ISSUE_NUMBER="687" \
  WM_PR_NUMBER="999" WM_LOOP_COUNT="4" >/dev/null 2>&1 || true
WM_FILE14="$SBX14/.rite-work-memory/issue-687.md"
seed14=$(cat "$WM_FILE14" 2>/dev/null || echo "")
assert_contains "T-11.0a: seed で pr_number=999 が書かれる (前提確認)" "pr_number: 999" "$seed14"
assert_contains "T-11.0b: seed で loop_count=4 が書かれる (前提確認)" "loop_count: 4" "$seed14"

# pr-create の seed 形 = WM_PR_NUMBER だけを渡す
if run_update "$SBX14" \
  WM_SOURCE="create" WM_PHASE="pr" WM_PHASE_DETAIL="PR作成完了" \
  WM_NEXT_ACTION="rite:pr-review を実行" WM_BODY_TEXT="PR created." WM_ISSUE_NUMBER="687" \
  WM_PR_NUMBER="123" >/dev/null 2>&1; then
  rc14=0
else
  rc14=$?
fi
assert_eq "T-11.1: return 0" "0" "$rc14"
body14=$(cat "$WM_FILE14" 2>/dev/null || echo "")
assert_contains "T-11.2: 渡した側は env 値が採用される (pr_number=123)" "pr_number: 123" "$body14"
assert_contains "T-11.3: 渡していない側は carry-forward される (loop_count=4)" "loop_count: 4" "$body14"

# ─── T-12: jq 展開失敗でも既定値に倒して完走する ──────────────────
# python3 側の errexit ガードは T-07 が固定しているが、1 行下の jq 側ガードは同じリスク構造を
# 持ちながら無防備だった。ガードを外すと `set -e` 下の bare 呼び出しが rc=1 で中断し、WM が
# まったく書かれない (best-effort 契約の直接違反)。shim は sync_revision を含む呼び出しだけを
# 失敗させる — jq を全面的に壊すと flow-state.sh 依存の他 TC を巻き込む。
echo "T-12: jq 展開失敗でも既定値へ倒して更新が完走する"
SBX15=$(make_sandbox --branch fix/issue-687-test); cleanup_dirs+=("$SBX15")
write_config "$SBX15"
run_update "$SBX15" \
  WM_SOURCE="create" WM_PHASE="pr" WM_PHASE_DETAIL="PR作成完了" \
  WM_NEXT_ACTION="next" WM_BODY_TEXT="Seed body." WM_ISSUE_NUMBER="687" \
  WM_PR_NUMBER="123" WM_LOOP_COUNT="4" >/dev/null 2>&1 || true
WM_FILE15="$SBX15/.rite-work-memory/issue-687.md"
assert_contains "T-12.0: seed で pr_number=123 が書かれる (前提確認)" "pr_number: 123" "$(cat "$WM_FILE15" 2>/dev/null || echo "")"
mkdir -p "$SBX15/bin"
REAL_JQ=$(command -v jq)
cat > "$SBX15/bin/jq" <<SHIM_EOF
#!/bin/bash
for a in "\$@"; do
  case "\$a" in *sync_revision*) exit 1 ;; esac
done
exec "$REAL_JQ" "\$@"
SHIM_EOF
chmod +x "$SBX15/bin/jq"

if (cd "$SBX15" && env WM_PLUGIN_ROOT="$PLUGIN_ROOT" PATH="$SBX15/bin:$PATH" \
  WM_SOURCE="implement" WM_PHASE="lint" WM_PHASE_DETAIL="品質チェック準備" \
  WM_NEXT_ACTION="rite:lint" WM_BODY_TEXT="Post-jq-failure." WM_ISSUE_NUMBER="687" \
  bash -c 'set -euo pipefail; source "$WM_PLUGIN_ROOT/hooks/work-memory-update.sh"; update_local_work_memory' \
  2>"$SBX15/err15") >/dev/null; then
  rc15=0
else
  rc15=$?
fi
err15=$(cat "$SBX15/err15" 2>/dev/null || echo "")
body15=$(cat "$WM_FILE15" 2>/dev/null || echo "")
assert_eq "T-12.1: set -e 下の bare 呼び出しで return 0 (best-effort 契約)" "0" "$rc15"
assert_contains "T-12.2: WM が実際に書き換わる (更新が完走している)" "Post-jq-failure." "$body15"
assert_contains "T-12.3: pr_number: null (既定値へ倒れる)" "pr_number: null" "$body15"
assert_contains "T-12.4: loop_count: 0 (既定値へ倒れる)" "loop_count: 0" "$body15"
assert_contains "T-12.5: 読み戻し不能 WARNING が出る (silent に倒れない)" "$WARN_CARRY_FWD" "$err15"

# ─── T-13: flow-state の「PR 未作成」sentinel 0 は carry-forward しない ──
# flow-state は PR 作成前の pr_number を 0 で表す (書き手の全数は
# `grep -rn -- "--pr 0" plugins/rite/skills/`)。WM_READ_FROM_FLOW_STATE 経路がその 0 を WM へ
# 運んだあと、carry-forward が 0 を
# 実値として拾うと work-memory-format.md の `null if not created` を表現できないまま恒久化する。
# carry-forward 導入前は次の通常更新で null へ戻っていたので、これは新機構が持ち込む退行にあたる。
echo "T-13: flow-state 由来の pr_number: 0 は carry-forward されず null へ戻る"
SBX16=$(make_sandbox --branch fix/issue-687-test); cleanup_dirs+=("$SBX16")
write_config "$SBX16"
# WM_READ_FROM_FLOW_STATE 経路を使わず、同経路が書き込む結果 (pr_number: 0) を env で直接再現する。
# flow-state fixture を組むと本 TC が flow-state 解決の健全性にも依存してしまい、検証したい
# 「0 を carry-forward するか」から焦点がぶれるため。
run_update "$SBX16" \
  WM_SOURCE="lint" WM_PHASE="lint" WM_PHASE_DETAIL="lint 実行中" \
  WM_NEXT_ACTION="next" WM_BODY_TEXT="Seed body." WM_ISSUE_NUMBER="687" \
  WM_PR_NUMBER="0" WM_LOOP_COUNT="4" >/dev/null 2>&1 || true
WM_FILE16="$SBX16/.rite-work-memory/issue-687.md"
seed16=$(cat "$WM_FILE16" 2>/dev/null || echo "")
assert_contains "T-13.0a: seed で pr_number: 0 が書かれる (前提確認)" "pr_number: 0" "$seed16"
assert_contains "T-13.0b: seed で loop_count: 4 が書かれる (前提確認)" "loop_count: 4" "$seed16"

# env を渡さない通常更新 = carry-forward が発火する経路
if run_update "$SBX16" \
  WM_SOURCE="implement" WM_PHASE="implement" WM_PHASE_DETAIL="実装中" \
  WM_NEXT_ACTION="next" WM_BODY_TEXT="Normal update." WM_ISSUE_NUMBER="687" >/dev/null 2>&1; then
  rc16=0
else
  rc16=$?
fi
body16=$(cat "$WM_FILE16" 2>/dev/null || echo "")
assert_eq "T-13.1: return 0" "0" "$rc16"
assert_contains "T-13.2: pr_number: null へ戻る (sentinel 0 を carry-forward しない)" "pr_number: null" "$body16"
# loop_count 側の 0 は「まだ 1 周もしていない」という実値なので、同じ除外を適用してはならない。
# 本アサーションは pr_number の除外が loop_count へ波及していないことを固定する。
assert_contains "T-13.3: loop_count は carry-forward される (0 除外を波及させない)" "loop_count: 4" "$body16"

# 実 PR 番号が非退行であることの確認。loop_count: 0 側は既定値と同値になるため carry-forward の
# 有無を出力から判別できない (0 除外を loop_count へ波及させる変更は全入力で同じ出力になる等価変異で、
# アサーションを強化しても殺せない — 実測でも当該変異は全 PASS のまま生存する)。
SBX17=$(make_sandbox --branch fix/issue-687-test); cleanup_dirs+=("$SBX17")
write_config "$SBX17"
run_update "$SBX17" \
  WM_SOURCE="lint" WM_PHASE="lint" WM_PHASE_DETAIL="lint 実行中" \
  WM_NEXT_ACTION="next" WM_BODY_TEXT="Seed body." WM_ISSUE_NUMBER="687" \
  WM_PR_NUMBER="4242" WM_LOOP_COUNT="0" >/dev/null 2>&1 || true
WM_FILE17="$SBX17/.rite-work-memory/issue-687.md"
run_update "$SBX17" \
  WM_SOURCE="implement" WM_PHASE="implement" WM_PHASE_DETAIL="実装中" \
  WM_NEXT_ACTION="next" WM_BODY_TEXT="Normal update." WM_ISSUE_NUMBER="687" >/dev/null 2>&1 || true
body17=$(cat "$WM_FILE17" 2>/dev/null || echo "")
# 完走確認を先に置く。T-13.4 / T-13.5 が照合する値は seed が env override で書いた値と同一のため、
# 2 回目の更新が no-op でも abort でも両方 Green になる。body 差し替えの照合 (T-07.2 / T-12.2 と同型)
# だけがその区別をつける。
assert_contains "T-13.4a: 2 回目の更新が完走している (前提確認)" "Normal update." "$body17"
assert_contains "T-13.4: 実 PR 番号は従来どおり carry-forward される (非退行)" "pr_number: 4242" "$body17"
assert_contains "T-13.5: loop_count: 0 は据え置き (既定値と同値のため carry-forward の有無は出力から判別不能)" "loop_count: 0" "$body17"

# ─── T-17: 区切り (0x1f) を含む改竄値でも carry-forward の列がずれない ──
# jq の join は区切りを値側でエスケープしないため、値に 0x1f が入ると read の列が右へずれ、
# pr_number の後半が loop_count の位置へ回り込んで実 loop_count が痕跡なく消える。判定値である
# .data 要素数の位置にも別 field (数値) が入るため、読み戻し不能ガードも corrupt 判定も発火しない。
# T-06 が固定する「非数値 → null 降格」は、ずれた値が数値のままなので素通りする。
echo "T-17: 区切り文字を含む改竄 WM でも carry-forward の列がずれない"
SBX21=$(make_sandbox --branch fix/issue-687-test); cleanup_dirs+=("$SBX21")
write_config "$SBX21"
run_update "$SBX21" \
  WM_SOURCE="create" WM_PHASE="pr" WM_PHASE_DETAIL="PR作成完了" \
  WM_NEXT_ACTION="next" WM_BODY_TEXT="Seed body." WM_ISSUE_NUMBER="687" \
  WM_PR_NUMBER="123" WM_LOOP_COUNT="7" >/dev/null 2>&1 || true
WM_FILE21="$SBX21/.rite-work-memory/issue-687.md"
seed21=$(cat "$WM_FILE21" 2>/dev/null || echo "")
# seed 前提確認: これが無いと seed 失敗時に T-17.1 が「既定値 0 のまま」を掴んで空虚に PASS する
assert_contains "T-17.0: seed で loop_count=7 が書かれる (前提確認)" "loop_count: 7" "$seed21"
# fixture 改竄は T-06 と同じ awk read→transform→write→mv 形式 (BSD sed -i 非互換の回避)
US_SEP=$(printf '\037')
awk -v us="$US_SEP" '{
  if ($0 == "pr_number: 123") printf "pr_number: \"12%s34\"\n", us;
  else print
}' "$WM_FILE21" > "$WM_FILE21.tmp" && mv "$WM_FILE21.tmp" "$WM_FILE21"
err21=$(run_update "$SBX21" \
  WM_SOURCE="implement" WM_PHASE="lint" WM_PHASE_DETAIL="品質チェック準備" \
  WM_NEXT_ACTION="rite:lint" WM_BODY_TEXT="Post-implementation." WM_ISSUE_NUMBER="687" 2>&1 >/dev/null) || true
body21=$(cat "$WM_FILE21" 2>/dev/null || echo "")
# 列がずれると loop_count には pr_number の後半 (34) が入り、実値 7 が消える
assert_contains "T-17.1: loop_count は seed 値のまま (ずれた field を掴まない)" "loop_count: 7" "$body21"
# 列がずれると、ずれた前半 (12) は数値なので降格されず「正常な carry-forward」として書かれる
assert_contains "T-17.2: 区切り混入値は null へ降格する" "pr_number: null" "$body21"
assert_contains "T-17.3: 降格が WARNING で可視化される (silent に通さない)" "non-numeric character" "$err21"

# ─── T-18: 制御文字 (NUL) 混入値は連結されず null へ降格する ─────────
# NUL は列をずらさない — command substitution が削除するため断片が連結し、12<NUL>34 が
# 「1234」という実在しない数値になって降格も WARNING も発火しない。T-17 (0x1f = 列ずれ) と
# 迂回の形は違うが、どちらも「区切り 1 種類だけを潰す実装」では捕捉できない同一クラス。
echo "T-18: 制御文字 (NUL) 混入値は連結されず null へ降格する"
SBX24=$(make_sandbox --branch fix/issue-687-test); cleanup_dirs+=("$SBX24")
write_config "$SBX24"
run_update "$SBX24" \
  WM_SOURCE="create" WM_PHASE="pr" WM_PHASE_DETAIL="PR作成完了" \
  WM_NEXT_ACTION="next" WM_BODY_TEXT="Seed body." WM_ISSUE_NUMBER="687" \
  WM_PR_NUMBER="123" WM_LOOP_COUNT="7" >/dev/null 2>&1 || true
WM_FILE24="$SBX24/.rite-work-memory/issue-687.md"
seed24=$(cat "$WM_FILE24" 2>/dev/null || echo "")
assert_contains "T-18.0a: seed で pr_number=123 が書かれる (前提確認)" "pr_number: 123" "$seed24"
assert_contains "T-18.0b: seed で loop_count=7 が書かれる (前提確認)" "loop_count: 7" "$seed24"
# awk は NUL を扱えないため python3 の read→replace→write 形式で改竄する
python3 -c "
import pathlib, sys
f = pathlib.Path(sys.argv[1])
f.write_text(f.read_text().replace('pr_number: 123', 'pr_number: \"12' + chr(0) + '34\"'))
" "$WM_FILE24"
err24=$(run_update "$SBX24" \
  WM_SOURCE="implement" WM_PHASE="lint" WM_PHASE_DETAIL="品質チェック準備" \
  WM_NEXT_ACTION="rite:lint" WM_BODY_TEXT="Post-implementation." WM_ISSUE_NUMBER="687" 2>&1 >/dev/null) || true
body24=$(cat "$WM_FILE24" 2>/dev/null || echo "")
# 連結されると pr_number: 1234 という実在しない値が降格も WARNING もなく書かれる
assert_contains "T-18.1: 制御文字混入値は null へ降格する (1234 のような連結値を書かない)" "pr_number: null" "$body24"
assert_contains "T-18.2: 降格が WARNING で可視化される (silent に通さない)" "non-numeric character" "$err24"
# 降格が他 field へ波及していないことの非回帰 (NUL 単体では列はずれない)
assert_contains "T-18.3: loop_count は非回帰 (降格が他 field へ波及しない)" "loop_count: 7" "$body24"

echo
echo "─── work-memory-update.test.sh summary ──────────────────────────"
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
