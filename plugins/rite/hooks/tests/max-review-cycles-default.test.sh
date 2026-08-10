#!/bin/bash
# max-review-cycles-default.test.sh
#
# `safety.max_review_cycles` の既定値 15 を pin する 。
#
# 2 系統の検査を持つ:
#   1. 挙動 (T-01〜T-03) — iterate/SKILL.md から fallback ブロックを literal 抽出し、
#      sandbox の rite-config.yml に対して実行して解決値を確かめる。テストへコピーすると
#      SKILL.md 側の変更が反映されず drift するため、base-update-classify.test.sh と同じ
#      抽出実行方式を取る。抽出アンカーが壊れたらテスト自体が FATAL で落ちる。
#   2. 記述の一致 (T-04) / 契約の不変 (T-05) — 既定値は 8 ファイルに複製されており、
#      1 箇所でも取り残されると読者が「その経路は別の値」と誤読する。cycle-scope-contract.test.sh
#      と同じ static-contract 方式で grep-pin する。
#      この仕様により fix-relaxation-rules.md と review-trend-divergence.sh の散文も
#      T-04 の sweep と positive pin に追加した。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
REPO_ROOT="$(_helpers_resolve_repo_root "$SCRIPT_DIR")"

ITERATE="$PLUGIN_ROOT/skills/iterate/SKILL.md"
TEMPLATE_CFG="$PLUGIN_ROOT/templates/config/rite-config.yml"
EXEC_METRICS="$PLUGIN_ROOT/references/execution-metrics.md"
CONFIG_DOC="$REPO_ROOT/docs/CONFIGURATION.md"
SPEC_DOC="$REPO_ROOT/docs/SPEC.md"
FIX_RELAXATION="$PLUGIN_ROOT/skills/fix/references/fix-relaxation-rules.md"
TREND_HELPER="$PLUGIN_ROOT/hooks/scripts/review-trend-divergence.sh"

DEFAULT_CYCLES=15
BACKSTOP_CYCLE=$((DEFAULT_CYCLES + 1))

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

# --- SKILL.md から 2 つの fallback サイトを抽出 ---------------------------------

STEP06="$TEST_DIR/step06.sh"
awk '/^# \(1\) max_review_cycles を rite-config\.yml から読取・検証/{f=1} f{print} f&&/^esac$/{exit}' \
  "$ITERATE" > "$STEP06"
printf 'echo "max_cycles=$max_cycles"\n' >> "$STEP06"
# 行数上限は over-extraction (終端アンカーを取り逃して後続ブロックを巻き込む) の検出を担う。
# アンカー literal の存在検査だけでは、途中に別の `esac` が挿入されて範囲が伸びても通過してしまう。
if ! grep -qE '^case "\$raw_max" in' "$STEP06" || ! grep -qx 'esac' "$STEP06" \
   || [ "$(wc -l < "$STEP06")" -gt 12 ]; then
  echo "FATAL: ステップ 0.6 の fallback ブロック抽出に失敗しました (アンカーが変更された可能性)" >&2
  echo "  抽出結果: $(wc -l < "$STEP06") 行 (期待: 12 行以下)" >&2
  exit 1
fi

# ステップ 1 の silent 再読込は 1 行の case。直前の raw_max= 代入 (2 行) と組で意味を持つため、
# 「最後に現れた raw_max= から silent fallback 行まで」を取る。ステップ 0.6 側の raw_max= で
# 一度バッファが立つが、ステップ 1 の raw_max= で捨てて取り直すので混線しない。
STEP1="$TEST_DIR/step1.sh"
awk '/^raw_max=\$\(awk/ { buf=$0; c=1; next }
     c { buf = buf "\n" $0; if (/silent fallback/) { print buf; exit } }' \
  "$ITERATE" > "$STEP1"
printf 'echo "max_cycles=$max_cycles"\n' >> "$STEP1"
# ステップ 0.6 側と同じ理由で行数上限を課す。こちらは開始アンカーが「最後の raw_max=」という
# 相対位置なので、SKILL.md 側の些細な整形 (`$(awk` の前後に空白が入る等) で開始点がステップ 0.6 側へ
# 巻き戻ると 200 行超の markdown スラブを実行してしまう。存在検査 2 本はどちらもそれを通過させる。
if ! grep -q 'silent fallback' "$STEP1" || ! grep -q '^raw_max=' "$STEP1" \
   || [ "$(wc -l < "$STEP1")" -gt 6 ]; then
  echo "FATAL: ステップ 1 の silent fallback 抽出に失敗しました (アンカーが変更された可能性)" >&2
  echo "  抽出結果: $(wc -l < "$STEP1") 行 (期待: 6 行以下)" >&2
  exit 1
fi

STDERR_LOG="$TEST_DIR/stderr.log"

# run_snippet <snippet> <config-body> — sandbox に rite-config.yml を置いて解決値を返す
run_snippet() {
  local snippet="$1" cfg="$2"
  local sandbox="$TEST_DIR/sandbox"
  rm -rf "$sandbox"; mkdir -p "$sandbox"
  printf '%s\n' "$cfg" > "$sandbox/rite-config.yml"
  ( cd "$sandbox" && bash "$snippet" 2>"$STDERR_LOG" ) | sed -n 's/^max_cycles=//p'
}

CFG_KEY_ABSENT='safety:
  max_implementation_rounds: 20
  time_budget_minutes: 120'
CFG_NO_SAFETY='commands:
  test: null'
CFG_ZERO='safety:
  max_review_cycles: 0'
CFG_NON_NUMERIC='safety:
  max_review_cycles: abc'
CFG_EXPLICIT='safety:
  max_review_cycles: 7'
CFG_EXPLICIT_COMMENTED='safety:
  max_review_cycles: 7   # explicit override'

echo "=== T-01: キー未設定時の既定は $DEFAULT_CYCLES (AC-1) ==="
assert "T-01a: ステップ 0.6 — safety はあるがキー欠落" \
  "$DEFAULT_CYCLES" "$(run_snippet "$STEP06" "$CFG_KEY_ABSENT")"
assert "T-01b: ステップ 0.6 — safety セクションごと不在" \
  "$DEFAULT_CYCLES" "$(run_snippet "$STEP06" "$CFG_NO_SAFETY")"
assert "T-01c: ステップ 1 — safety はあるがキー欠落" \
  "$DEFAULT_CYCLES" "$(run_snippet "$STEP1" "$CFG_KEY_ABSENT")"
assert "T-01d: ステップ 1 — safety セクションごと不在" \
  "$DEFAULT_CYCLES" "$(run_snippet "$STEP1" "$CFG_NO_SAFETY")"
# キー欠落は正常系。WARNING を出さないことまで pin する (出すと通常運用が毎回ノイズを吐く)
run_snippet "$STEP06" "$CFG_KEY_ABSENT" >/dev/null
assert "T-01e: キー欠落は WARNING を出さない (正常系)" "" "$(cat "$STDERR_LOG")"

echo "=== T-02: 無効値のフォールバック先も $DEFAULT_CYCLES + WARNING (AC-2) ==="
assert "T-02a: ステップ 0.6 — 0 は既定へフォールバック" \
  "$DEFAULT_CYCLES" "$(run_snippet "$STEP06" "$CFG_ZERO")"
assert_grep "T-02b: 0 のとき WARNING の値も $DEFAULT_CYCLES" "$STDERR_LOG" \
  "既定値 $DEFAULT_CYCLES を使用します"
assert "T-02c: ステップ 0.6 — 非数値は既定へフォールバック" \
  "$DEFAULT_CYCLES" "$(run_snippet "$STEP06" "$CFG_NON_NUMERIC")"
assert_grep "T-02d: 非数値のとき WARNING の値も $DEFAULT_CYCLES" "$STDERR_LOG" \
  "既定値 $DEFAULT_CYCLES を使用します"
assert "T-02e: ステップ 1 — 0 は既定へフォールバック" \
  "$DEFAULT_CYCLES" "$(run_snippet "$STEP1" "$CFG_ZERO")"
assert "T-02f: ステップ 1 — 非数値は既定へフォールバック" \
  "$DEFAULT_CYCLES" "$(run_snippet "$STEP1" "$CFG_NON_NUMERIC")"
# ステップ 1 は検証済み前提の silent 再読込。ここで WARNING を出すと cycle ごとに重複告知になる
run_snippet "$STEP1" "$CFG_ZERO" >/dev/null
assert "T-02g: ステップ 1 の無効値フォールバックは silent" "" "$(cat "$STDERR_LOG")"

echo "=== T-03: 明示設定は既定値に上書きされない (AC-3) ==="
assert "T-03a: ステップ 0.6 — 明示値 7 をそのまま使う" \
  "7" "$(run_snippet "$STEP06" "$CFG_EXPLICIT")"
assert "T-03b: ステップ 1 — 明示値 7 をそのまま使う" \
  "7" "$(run_snippet "$STEP1" "$CFG_EXPLICIT")"
assert "T-03c: ステップ 0.6 — 行末コメント付きの明示値も 7" \
  "7" "$(run_snippet "$STEP06" "$CFG_EXPLICIT_COMMENTED")"
assert "T-03d: ステップ 1 — 行末コメント付きの明示値も 7" \
  "7" "$(run_snippet "$STEP1" "$CFG_EXPLICIT_COMMENTED")"

echo "=== T-04: 既定値の記述が全複製箇所で揃っている (AC-4) ==="
# 実装 fallback は 3 サイト (ステップ 0.6 のキー欠落 / 無効値、ステップ 1 の silent)。
# 数まで pin するのは、1 サイトだけ書き換えて残りが取り残される drift が本 Issue の主因のため。
assert "T-04a: iterate/SKILL.md の fallback 3 サイトすべてが $DEFAULT_CYCLES" \
  "3" "$(grep -c "max_cycles=$DEFAULT_CYCLES" "$ITERATE")"
assert_not_grep "T-04b: iterate/SKILL.md に旧 fallback (max_cycles=5) が残っていない" "$ITERATE" \
  'max_cycles=5([^0-9]|$)'
assert_grep "T-04c: 無効値 WARNING の文言も $DEFAULT_CYCLES" "$ITERATE" \
  "既定値 $DEFAULT_CYCLES を使用します"

# AC-4 が名指しする 3 ファイル + 既定値を書いている他 2 ファイル。
# 「既定 N」「default: N」形式の断定的な記述だけを見る (「引き上げ前の 5」のような
# 履歴の言及は誤検出しない)。
for f in "$ITERATE" "$TEMPLATE_CFG" "$CONFIG_DOC" "$SPEC_DOC" "$EXEC_METRICS" "$FIX_RELAXATION" "$TREND_HELPER"; do
  base="$(basename "$f")"
  assert_file_exists_or_fail "T-04: $base が存在する" "$f" || continue
  # `既定(値)?` とグループ化する。`既定値?` は ERE の `?` が多バイト文字 `値` の最終バイトに
  # 掛かるため、LC_ALL=C では「既定 5」(値 なし形) を検出できない。
  # スペースを `[[:space:]]*` にするのは、`（既定5）` のようにスペース無しで書かれた残留を
  # 素通しさせないため。閉じ括弧を伴わない `（既定 15、` 形が 4 サイトあり、そこが 5 へ
  # 差し戻されても T-04o (完全 literal の count) は数を保つので検出できない。
  assert_not_grep "T-04: $base に「既定 5」が残っていない" "$f" '既定(値)?[[:space:]]*5([^0-9]|$)'
  assert_not_grep "T-04: $base に「default: 5」が残っていない" "$f" 'max_review_cycles.*default: 5([^0-9]|$)'
  assert_not_grep "T-04: $base に YAML 値 5 が残っていない" "$f" 'max_review_cycles: 5([^0-9]|$)'
done

# positive 側。値を消しただけ / 別の値に書き換わった drift は negative 検査を素通りする。
assert_grep "T-04d: templates/config が $DEFAULT_CYCLES" "$TEMPLATE_CFG" \
  "max_review_cycles: $DEFAULT_CYCLES .*default: $DEFAULT_CYCLES"
assert "T-04e: execution-metrics の config サンプル 2 箇所が $DEFAULT_CYCLES" \
  "2" "$(grep -c "max_review_cycles: $DEFAULT_CYCLES # .*default: $DEFAULT_CYCLES" "$EXEC_METRICS")"
assert_grep "T-04f: CONFIGURATION.md の safety 表の Default 列が $DEFAULT_CYCLES" "$CONFIG_DOC" \
  "\`max_review_cycles\` \| integer \| \`$DEFAULT_CYCLES\`"
assert "T-04g: CONFIGURATION.md の YAML 例 2 箇所が $DEFAULT_CYCLES" \
  "2" "$(grep -c "max_review_cycles: $DEFAULT_CYCLES" "$CONFIG_DOC")"
assert "T-04h: SPEC.md の既定値言及 2 箇所が $DEFAULT_CYCLES" \
  "2" "$(grep -c "default $DEFAULT_CYCLES" "$SPEC_DOC")"
# 既定値から導出される事実 (trend が武装する cycle 4 から backstop 到達までの loop head 数、
# backstop が止める収束 run の長さ)。数値だけ置換して散文を放置する drift を止める。
assert_grep "T-04i: CONFIGURATION.md の loop head 数が $DEFAULT_CYCLES から導出された値" "$CONFIG_DOC" \
  "default budget of $DEFAULT_CYCLES that leaves twelve loop heads"
assert_grep "T-04j: CONFIGURATION.md の backstop 到達 cycle が 16" "$CONFIG_DOC" \
  'backstop takes over at the head of cycle 16'
assert_grep "T-04k: iterate/SKILL.md が「16 cycle 以上」で記述されている" "$ITERATE" \
  '16 cycle 以上'
# トレンド判定が発火しうる下限 (4 以上) を満たす値であることの明記 (§4.4 MUST)
assert_grep "T-04l: CONFIGURATION.md が下限 4 制約と既定値の関係を明記" "$CONFIG_DOC" \
  "is 4 or more.*default of $DEFAULT_CYCLES satisfies that lower bound"
# 既定値の複製が多いこと自体を drift 源として記録する (§4.4 SHOULD)
assert_grep "T-04m: CONFIGURATION.md が既定値の複製箇所を drift 源として記録" "$CONFIG_DOC" \
  'default for `max_review_cycles` is duplicated across the repository'
# 散文が既定値を述べる箇所は negative 検査 (「既定 5」/「default: 5」形) の網から外れる。
# 英文の `at the default of N` と日本語の `（既定 N）` は、5 へ差し戻しても negative パターンに
# 掛からず全件 green で通るため、既存 T-04a/e/g/h と同じ positive count pin で押さえる。
# 本 pin だけ `grep -o | wc -l` で**出現数**を数える。CONFIGURATION.md の safety 表と backstop 節は
# 1 段落 = 1 行の markdown で、同一行に `the default of 15` が 2 つ同居するため、行数を数える
# `grep -c` では 4 出現を 2 と数えてしまう。`at` を含めず `the default of N` で数えるのは、
# 下限制約の記述 (`the default of 15 satisfies that lower bound`) と引き上げ根拠の記述
# (`Whether the default of 15 is right`) も既定値を述べる箇所として同じ網に入れるため。
assert "T-04n: CONFIGURATION.md の英文既定値 4 箇所が $DEFAULT_CYCLES" \
  "4" "$(grep -o "the default of $DEFAULT_CYCLES" "$CONFIG_DOC" | wc -l | tr -d '[:space:]')"
# `${DEFAULT_CYCLES}` をブレースで囲む。直後が多バイト文字 `）` のため、素の `$DEFAULT_CYCLES` だと
# 非 UTF-8 ロケールで後続バイトが変数名に畳み込まれ set -u を踏む (flow-state.test.sh TC-8b-h)。
assert "T-04o: iterate/SKILL.md の散文既定値 3 箇所が $DEFAULT_CYCLES" \
  "3" "$(grep -c "（既定 ${DEFAULT_CYCLES}）" "$ITERATE")"
assert "T-04p: SPEC.md の英文既定値 1 箇所が $DEFAULT_CYCLES" \
  "1" "$(grep -c "at the default of $DEFAULT_CYCLES" "$SPEC_DOC")"
assert "T-04q: fix relaxation rules の既定値 3 箇所が $DEFAULT_CYCLES" \
  "3" "$(grep -o "既定 $DEFAULT_CYCLES" "$FIX_RELAXATION" | wc -l | tr -d '[:space:]')"
assert_grep "T-04r: fix relaxation rules の既定値と導出 cycle が同期" "$FIX_RELAXATION" \
  "既定 $DEFAULT_CYCLES では $BACKSTOP_CYCLE cycle 以上"
assert_grep "T-04s: trend helper header の既定値と導出 cycle が同期" "$TREND_HELPER" \
  "既定 $DEFAULT_CYCLES では $BACKSTOP_CYCLE cycle 以上"

echo "=== T-05: backstop の発火条件と sentinel が不変 (AC-5) ==="
# 既定値の引き上げは backstop を撤廃しない (the governing rationale D-01 / MUST NOT)。
assert_grep "T-05a: ステップ 1 の backstop 判定 (cc >= max_cycles) が残っている" "$ITERATE" \
  '^if \[ "\$cc" -ge "\$max_cycles" \] 2>/dev/null; then'
assert_grep "T-05b: ステップ 0.6 の再発火述語 (cur_cc >= max_cycles) が残っている" "$ITERATE" \
  '^if \[ "\$cur_cc" -ge "\$max_cycles" \] 2>/dev/null; then'
assert_grep "T-05c: batch 側 sentinel が変わっていない" "$ITERATE" \
  '<!-- \[iterate:max-cycles-reached\] -->'
assert_grep "T-05d: 対話側 sentinel が変わっていない" "$ITERATE" \
  '<!-- \[iterate:max-cycles-stopped\] -->'
assert_grep "T-05e: batch-run 側のブレーカー受けが同じ sentinel を見ている" \
  "$PLUGIN_ROOT/skills/batch-run/SKILL.md" '\[iterate:max-cycles-reached\]'

print_summary "max-review-cycles-default"
