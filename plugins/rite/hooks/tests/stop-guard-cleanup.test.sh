#!/bin/bash
# plugins/rite/hooks/tests/stop-guard-cleanup.test.sh
#
# Unit test for stop-guard.sh block behavior during cleanup Phase 4.W.
# Issue #621: AC-3 automation (stop-guard が cleanup_pre_ingest / cleanup_post_ingest
# phase で end_turn を block し、session log にその痕跡が残ることを verify)
#
# Relationship with existing stop-guard.test.sh TC-608-A〜H:
# - TC-608-A/B/D/E/F/H は HINT-specific 文言を細かく pin し、文言 drift を検知する
#   regression-detection 最適化型 fixture。`bash plugins/rite/hooks/tests/run-tests.sh` から
#   自動実行される。
# - 本 fixture は「standalone で独立実行可能な fixture ベース」の役割を担う。
#   runner 外で単体起動したいケース (個別 debug / CI 部分実行) に対応し、cleanup 系 3 phase
#   (cleanup / cleanup_pre_ingest / cleanup_post_ingest) の block と terminal 経路をまとめて verify。
#   HINT-specific 文言 (TC-608-B/H と同じ phrase) は Test 1/2 で pin し、
#   #652 canonical phrase (Phase 5.2 inline HTML sentinel 規約) は Test 1/2/5/6 の 4 site で pin する
#   (cycle 7 F-C6-03 で scope 拡張、cycle 8 F-C8-10 で header 更新、cycle 9 で factual clarification)。
#   TC-608-B/H も同一 HINT 文言を pin するため相補関係を形成する。
#   ⚠️ Test 6 の canonical phrase pin は L412 (cleanup_post_ingest primary HINT) と L415 (escalation
#   HINT の concatenation) のいずれか一方の canonical phrase が残っていれば pass する concat 構造の
#   ため、単一 site drift (L412-only / L415-only) は catch できない (net zero contribution for
#   single-site mutation)。L412 drift は Test 2 が直接 catch、L415 drift は現状 undocumented silent-pass
#   site (F-C8-01 cycle 9 で明文化)。future Issue で primary/escalation 独立 assert 設計を検討。
# 本 fixture は `*.test.sh` 命名規約に従い、run-tests.sh の glob に拾われる。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# SCRIPT_DIR = plugins/rite/hooks/tests → 4 levels up to repo root
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
STOP_GUARD="$REPO_ROOT/plugins/rite/hooks/stop-guard.sh"

if [ ! -x "$STOP_GUARD" ]; then
  echo "FAIL: stop-guard.sh not executable at $STOP_GUARD" >&2
  exit 1
fi

# Isolated fixture workspace (cleanup() 関数定義 → trap 登録 → mktemp の順で race window 排除)
#
# trap signal scope (EXIT INT TERM HUP):
# sibling hook test fixtures (stop-guard.test.sh 等 14 本) は `trap cleanup EXIT` のみで
# 統一されているが、本 fixture は defense-in-depth として INT/TERM/HUP も捕捉する。
# 理由: Ctrl-C / signal 経由で中断された場合も FIXTURE_DIR を確実に削除するため
# (mktemp -d で生成される /tmp/rite-test-stop-guard-XXXXXX の orphan を防ぐ)。
# sibling convention からの意図的 drift。test-file layer では許容範囲。
FIXTURE_DIR=""
cleanup() { [ -n "${FIXTURE_DIR:-}" ] && rm -rf "$FIXTURE_DIR"; }
trap cleanup EXIT INT TERM HUP

FIXTURE_DIR=$(mktemp -d /tmp/rite-test-stop-guard-XXXXXX) || {
  echo "FAIL: mktemp -d failed (/tmp が full / read-only / permission denied)" >&2
  exit 1
}

SESSION_ID="00000000-0000-0000-0000-000000000001"

# Fabricate .rite-flow-state for the given phase with active=true
# $1: phase name
# $2: previous_phase (optional、省略時は "cleanup" がデフォルト)
#     明示的に空文字を渡したい場合は "" を指定する (Test 3 がこの用途で使用)
# $3: error_count (optional、省略時は 0)。Issue #650 TC-650-E で escalation を trigger するため追加
make_state() {
  local phase="$1"
  # bash の ${2:-default} は「unset または null (空文字含む)」の両方で default 展開される。
  # $1 のみ指定 (= $2 unset) → prev="cleanup"
  # $1 + "" (= $2 set but null) → prev="cleanup" (unset と同じ扱い — bash 仕様)
  # したがって Test 3 の `run_guard "cleanup" ""` は実際には prev="cleanup" となる。
  # 旧コメントの「prev="" になる」は bash 仕様誤解に基づく記述だった。
  local prev="${2:-cleanup}"
  local ec="${3:-0}"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")
  cat > "$FIXTURE_DIR/.rite-flow-state" <<EOF
{
  "active": true,
  "issue_number": 621,
  "branch": "fix/issue-621-test",
  "phase": "$phase",
  "previous_phase": "$prev",
  "pr_number": 0,
  "parent_issue_number": 0,
  "next_action": "test fixture",
  "updated_at": "$ts",
  "session_id": "$SESSION_ID",
  "error_count": $ec
}
EOF
}

# Run stop-guard with a constructed hook input JSON, capture exit + stderr.
# stderr_file は FIXTURE_DIR 内に配置する (F-15: trap cleanup が一括削除、orphan 防止)。
# $1: phase
# $2: previous_phase
# $3: error_count (optional、省略時は 0)。Issue #650 TC-650-E で escalation trigger に使用
STDERR_CONTENT=""
run_guard() {
  local phase="$1"
  local prev="$2"
  local ec="${3:-0}"
  make_state "$phase" "$prev" "$ec"
  local input
  input=$(printf '{"cwd":"%s","session_id":"%s"}' "$FIXTURE_DIR" "$SESSION_ID")
  local stderr_file
  # mktemp failure guard (cycle 3 C3-eh-M3): set -e 無効下で mktemp 失敗を silent 通過させない。
  # line 43 の `mktemp -d` と同型の fail-fast pattern で diagnostic を明示化し、空 $stderr_file が
  # 後続 redirect に流れて misleading な assertion FAIL を起こす経路を塞ぐ。
  stderr_file=$(mktemp "$FIXTURE_DIR/stderr.XXXXXX") || {
    echo "FAIL: stderr tempfile mktemp failed (FIXTURE_DIR=$FIXTURE_DIR が full / read-only / permission denied)" >&2
    exit 1
  }
  # defensive reset: 直後の `STDERR_CONTENT=$(cat ...)` で無条件上書きされるため、
  # 現行 4 tests の制御フローでは stale 混入は発生しない。ただし将来 early-return 経路
  # (cat 前に return する path) が追加された場合に前回の STDERR_CONTENT が残る regression を
  # 未然に防ぐための defense-in-depth。
  STDERR_CONTENT=""
  printf '%s' "$input" | bash "$STOP_GUARD" 2>"$stderr_file"
  local rc=$?
  STDERR_CONTENT=$(cat "$stderr_file")
  return "$rc"
}

# Assertion helpers
PASS=0
FAIL=0
assert() {
  local name="$1"
  local expected="$2"
  local actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    echo "ok  - $name"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL - $name (expected: $expected, actual: $actual)"
  fi
}
assert_contains() {
  local name="$1"
  local needle="$2"
  local haystack="$3"
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    PASS=$((PASS + 1))
    echo "ok  - $name"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL - $name (missing: $needle)"
    printf '  stderr: %s\n' "$haystack" | head -5
  fi
}
assert_not_contains() {
  local name="$1"
  local needle="$2"
  local haystack="$3"
  if ! printf '%s' "$haystack" | grep -qF "$needle"; then
    PASS=$((PASS + 1))
    echo "ok  - $name"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL - $name (unexpected presence of: $needle)"
    printf '  stderr: %s\n' "$haystack" | head -5
  fi
}

# Test 1: cleanup_pre_ingest phase should block with exit 2 and emit HINT-specific phrase
echo "# Test 1: cleanup_pre_ingest blocks end_turn + HINT specific pin"
run_guard "cleanup_pre_ingest" "cleanup"
rc=$?
assert "cleanup_pre_ingest exits 2" "2" "$rc"
assert_contains "stderr contains Phase:" "Phase:" "$STDERR_CONTENT"
assert_contains "stderr contains cleanup_pre_ingest" "cleanup_pre_ingest" "$STDERR_CONTENT"
# HINT-specific phrase pin (F-13): fallback STOP_MSG でも Phase 名は出るが、下記文言は
# cleanup_pre_ingest case arm 内にのみ存在するため、arm 削除 regression を検知できる。
assert_contains "stderr contains 'Phase 4.W.2 phase recorded'" "Phase 4.W.2 phase recorded" "$STDERR_CONTENT"
# #655 F-C6-03 cycle 7 対応: Test 1 でも canonical phrase pin を適用し L383 drift を catch する。
# 旧 cycle 5 修正で「cleanup arm 3 site の完全一致を pin」と宣言しつつ実装は Test 2 のみに
# pin を追加した protection theater を是正 (F-C10-01 cycle 11 対応で factual correction: 旧 quote の
# `L409` は canonical phrase 非含有の boundary コメント行のため削除、実 site は 3 = primary x2 +
# escalation x1 の semantic breakdown が正確)。mutation test で primary HINT (cleanup_pre_ingest) の
# canonical phrase drift が Test 1 FAIL として検知されることを verify 済み。
assert_contains "Test 1 stderr contains #652 canonical phrase" "HTML sentinel at the trailing position of the final list item of Phase 5.2 (ordered list)" "$STDERR_CONTENT"
# Sentinel emission pin (cycle 3 C3-eh-M1): file header が「session log にその痕跡が残ることを verify」と
# 謳う以上、HINT phrase だけでなく実際の workflow_incident sentinel (sentinel stderr echo ブロック —
# manual_fallback_adopted case arm) が emit されることも assert する。WORKFLOW_INCIDENT_TYPE 初期
# 設定分岐の
# (F-C8-15 cycle 9 対応: literal 行番号 :389 / :332 を semantic 参照に書き換え、PR #617 規約準拠)
# silent regression (例: WORKFLOW_HINT 条件の削除) でも検知できる。
# sentinel format: `[CONTEXT] WORKFLOW_INCIDENT=1; type=manual_fallback_adopted; details=...; iteration_id=...`
assert_contains "stderr contains manual_fallback_adopted sentinel" "WORKFLOW_INCIDENT=1; type=manual_fallback_adopted" "$STDERR_CONTENT"

# Test 2: cleanup_post_ingest phase should block with exit 2 and emit HINT-specific phrase
echo "# Test 2: cleanup_post_ingest blocks end_turn + HINT specific pin"
run_guard "cleanup_post_ingest" "cleanup_pre_ingest"
rc=$?
assert "cleanup_post_ingest exits 2" "2" "$rc"
assert_contains "stderr contains Phase:" "Phase:" "$STDERR_CONTENT"
assert_contains "stderr contains cleanup_post_ingest" "cleanup_post_ingest" "$STDERR_CONTENT"
# HINT-specific phrase pin (F-13): cleanup_post_ingest case arm 内の TC-608-H pinned phrase を
# 併せて検査することで、文言 drift / case arm 削除 regression を検知。
assert_contains "stderr contains 'rite:wiki:ingest returned'" "rite:wiki:ingest returned" "$STDERR_CONTENT"
assert_contains "stderr contains 'Phase 5 Completion Report has NOT been output'" "Phase 5 Completion Report has NOT been output" "$STDERR_CONTENT"
# #652 canonical phrase pin (cycle 3 → cycle 5 強化 → cycle 7 scope 拡大): inline HTML sentinel at
# the trailing position of the final list item of Phase 5.2 が cleanup arm STOP_MSG から再 drift
# した場合に検知。#652 対応で cleanup 系と ingest 系の terminal 規約を意図的に divergence させた
# ため、canonical phrase 統一が将来の silent unification regression の grep anchor として機能する。
# #655 F-C4-03 cycle 5 で完全形 `of Phase 5.2 (ordered list)` suffix を含めて cleanup arm 3 site
# の完全一致を pin 宣言したが、cycle 5 実装は Test 2 のみに pin を追加しており宣言と実装が不一致
# だった (#655 F-C6-03 cycle 6 で指摘)。cycle 7 で Test 1 / Test 5 / Test 6 にも pin を追加し 4 Test
# site で pin する形に是正。F-C10-01 cycle 11 対応 (factual correction): canonical phrase の実在 site
# は stop-guard.sh 内の 3 箇所 — cleanup_pre_ingest primary HINT / cleanup_post_ingest primary HINT /
# cleanup_post_ingest escalation HINT (旧 quote の `L409` は case arm boundary コメント行で canonical
# phrase 非含有だった)。mutation test empirical 結果 (3 scenarios):
#   - primary HINT drift (cleanup_pre_ingest) → Test 1 + Test 5 catch (L383 共通経路)
#   - primary HINT drift (cleanup_post_ingest) → Test 2 が直接 catch、Test 6 は L412+L415 concat 構造
#     のため escalation HINT 側 canonical phrase が残存していれば silent pass (double regression canary)
#   - escalation HINT drift (cleanup_post_ingest) → undocumented silent-pass site (F-C8-01 cycle 9 で明文化)
# cycle 5/7 の narrative「全 Test で catch」主張は上記 3 scenario を集計すると empirical に false。
assert_contains "stderr contains #652 canonical phrase" "HTML sentinel at the trailing position of the final list item of Phase 5.2 (ordered list)" "$STDERR_CONTENT"
# Sentinel emission pin (cycle 3 C3-eh-M1): Test 1 と同じく sentinel stderr emit を verify。
assert_contains "stderr contains manual_fallback_adopted sentinel" "WORKFLOW_INCIDENT=1; type=manual_fallback_adopted" "$STDERR_CONTENT"

# Test 3: cleanup phase (Phase 1-4 protection) should also block
echo "# Test 3: cleanup phase blocks end_turn"
run_guard "cleanup" ""
rc=$?
assert "cleanup exits 2" "2" "$rc"
assert_contains "stderr contains Phase:" "Phase:" "$STDERR_CONTENT"
# HINT-specific phrase pin (cycle 3 C3-eh-M2): Test 1/2 と対称に cleanup case arm 固有 HINT を pin。
# Note (F-C8-21 cycle 9 対応): Test 3 (cleanup phase) は Phase 1.0 Activate 段階の HINT を pin —
# cleanup arm の #652 canonical phrase 規約 (Phase 5.2 sentinel) はこの phase ではまだ関与しない
# ため canonical pin は不要。cleanup_pre_ingest (Test 1) / cleanup_post_ingest (Test 2) から sentinel
# 規約が適用される。
# `Phase 1.0 (Activate Flow State) just recorded phase=cleanup` は cleanup case arm
# (F-C8-15 cycle 9 対応: literal 行番号 :307 を semantic 参照に書き換え、PR #617 規約準拠)
# 内にのみ存在するため、case arm 削除 regression を fallback STOP_MSG の `Phase:` 出力に紛れて
# silent pass させない。sibling stop-guard.test.sh TC-608-A とも相補関係 (同じ Phase 1.0 を pin)。
assert_contains "stderr contains 'Phase 1.0 (Activate Flow State)'" "Phase 1.0 (Activate Flow State)" "$STDERR_CONTENT"

# Test 5 (TC-650-E): cleanup_pre_ingest + error_count=1 → RE-ENTRY DETECTED escalation
# Issue #650 — create_post_interview TC-634-E/F と対称化。error_count>=1 時に
# cleanup_pre_ingest case arm が RE-ENTRY DETECTED 警告 + bash literal を含む追加 HINT
# を emit することを verify する。escalation 分岐 (stop-guard.sh の `if [ "${ERROR_COUNT:-0}" -ge 1 ]`)
# の削除 regression を検知。
echo "# Test 5 (TC-650-E): cleanup_pre_ingest error_count=1 → RE-ENTRY DETECTED + bash literal"
run_guard "cleanup_pre_ingest" "cleanup" 1
rc=$?
assert "cleanup_pre_ingest error_count=1 exits 2" "2" "$rc"
assert_contains "Test 5 stderr contains 'RE-ENTRY DETECTED'" "RE-ENTRY DETECTED" "$STDERR_CONTENT"
# bash literal pin: escalation HINT が LLM 直接実行可能な bash 呼び出しを含むこと (#650 AC-5)
assert_contains "Test 5 stderr contains escalation bash literal" "bash plugins/rite/hooks/flow-state-update.sh patch --phase cleanup_post_ingest" "$STDERR_CONTENT"
assert_contains "Test 5 stderr contains --preserve-error-count" "preserve-error-count" "$STDERR_CONTENT"
# #655 F-C6-03 cycle 7 対応 (F-C8-03 cycle 9 で factual correction): Test 5 は L383 primary HINT の
# canonical phrase drift を catch する。L388 (cleanup_pre_ingest escalation HINT) には canonical phrase
# は含まれない設計 — L383 primary が $WORKFLOW_HINT 経由で concat 出力されるため Test 5 は L383 由来
# の文字列のみ assert する。cycle 7 commit body の「L383 と L388 両方に canonical phrase」記述は誤り。
assert_contains "Test 5 stderr contains #652 canonical phrase" "HTML sentinel at the trailing position of the final list item of Phase 5.2 (ordered list)" "$STDERR_CONTENT"

# Test 6 (TC-650-F): cleanup_post_ingest + error_count=1 → RE-ENTRY DETECTED escalation
# Test 5 と対称。cleanup_post_ingest arm 用 terminal patch の bash literal が escalation HINT に含まれることを verify。
echo "# Test 6 (TC-650-F): cleanup_post_ingest error_count=1 → RE-ENTRY DETECTED + bash literal"
run_guard "cleanup_post_ingest" "cleanup_pre_ingest" 1
rc=$?
assert "cleanup_post_ingest error_count=1 exits 2" "2" "$rc"
assert_contains "Test 6 stderr contains 'RE-ENTRY DETECTED'" "RE-ENTRY DETECTED" "$STDERR_CONTENT"
# bash literal pin: terminal patch (cleanup_completed --active false) の bash 呼び出しを含むこと
assert_contains "Test 6 stderr contains escalation bash literal" "bash plugins/rite/hooks/flow-state-update.sh patch --phase cleanup_completed --next none --active false" "$STDERR_CONTENT"
# #655 F-C6-03 cycle 7 対応 (F-C8-01 / F-C8-16 cycle 9 で factual correction): Test 6 は L412 primary
# HINT + L415 escalation HINT の concatenation 構造のため、canonical phrase pin は L412 / L415 どちらか
# 一方に canonical phrase が残っていれば pass する。したがって:
#   - L412-only drift → Test 2 が直接 catch、Test 6 は L415 canonical 残存で silent pass
#   - L415-only drift → 全 Test silent pass (undocumented silent-pass site)
#   - L412+L415 double drift のみ Test 6 が catch する double regression canary
# cycle 7 commit body の「cycle 7 で FAIL に昇格」主張は factually 不正確 (Test 6 は single-site drift
# に net zero contribution)。future Issue で primary/escalation 独立 assert 設計を検討する。
assert_contains "Test 6 stderr contains #652 canonical phrase (double regression canary)" "HTML sentinel at the trailing position of the final list item of Phase 5.2 (ordered list)" "$STDERR_CONTENT"

# NOTE (#655 F-C6-14 cycle 7 対応): Test 4 は Test 5/6 の escalation verify 後に配置する意図的な順序
# (#650 対応で Test 5/6 を前方挿入した歴史的経緯)。宣言順序は 1→2→3→5→6→4 で非連続だが、
# error_count=1 の escalation verify を終えてから active:false negative assertion を行う構造で、
# FAIL 時のデバッグで Test 番号と L 行番号の対応を追う際は宣言位置ではなく Test 番号の意味論
# (1/2: cleanup arm primary / 3: fallback / 5/6: escalation / 4: terminal state negative) で読み解く。
# Test 4: cleanup_completed with active=false should allow stop (exit 0) and NOT emit STOP_MSG
echo "# Test 4: cleanup_completed + active:false allows stop (negative assertion)"
cat > "$FIXTURE_DIR/.rite-flow-state" <<EOF
{
  "active": false,
  "issue_number": 621,
  "branch": "fix/issue-621-test",
  "phase": "cleanup_completed",
  "previous_phase": "cleanup_post_ingest",
  "pr_number": 0,
  "parent_issue_number": 0,
  "next_action": "none",
  "updated_at": "$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")",
  "session_id": "$SESSION_ID",
  "error_count": 0
}
EOF
input=$(printf '{"cwd":"%s","session_id":"%s"}' "$FIXTURE_DIR" "$SESSION_ID")
# mktemp failure guard (cycle 3 C3-eh-M3): Test 4 は run_guard() を使わず inline mktemp するため
# 同等の fail-fast guard を適用する。
stderr_file=$(mktemp "$FIXTURE_DIR/stderr.XXXXXX") || {
  echo "FAIL: Test 4 stderr tempfile mktemp failed (FIXTURE_DIR=$FIXTURE_DIR が full / read-only / permission denied)" >&2
  exit 1
}
printf '%s' "$input" | bash "$STOP_GUARD" 2>"$stderr_file"
rc=$?
test4_stderr=$(cat "$stderr_file")
assert "cleanup_completed (active:false) exits 0" "0" "$rc"
# Negative assertion (F-14): active=false で誤って STOP_MSG が emit される regression を検知。
# stop-guard.sh は terminal 経路では "Normal operation" / "stop prevented" を出力しないはず。
assert_not_contains "Test 4 stderr does not contain 'stop prevented'" "stop prevented" "$test4_stderr"
assert_not_contains "Test 4 stderr does not contain 'Normal operation'" "Normal operation" "$test4_stderr"

echo ""
echo "# Summary: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
