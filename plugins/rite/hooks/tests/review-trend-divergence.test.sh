#!/bin/bash
# Tests for hooks/scripts/review-trend-divergence.sh
#
# 本 script は /rite:iterate のサーキットブレーカーを「cycle 数上限」から「収束トレンドベースの
# 発散検出」へ移す判定層である。ここで固定するのは **較正された判定式そのもの** — 実装前 backtest
# で確定した「収束 run を殺さず既知の発散 run を上限より早く切る」条件を fixture として pin し、
# 後の式変更が実測に反する形へ退行するのを防ぐ。
#
# ## ソース (fixture トラジェクトリの出所 — 較正の監査証跡)
#
# 判定式は「実測されたトラジェクトリで殺してはいけない列 / 切るべき列」を分離できることを
# 根拠に確定した。数列が創作でないことを後から監査できるよう、各列の出所を残す:
#
#   - `3,6,5,3,0` / `3,7,7,4` / `2,3,6` : 受入基準が Given 節に literal に書いた契約値。
#     受入基準はこの数列に束縛されるため契約 fixture として扱う
#   - `10,8,8`                          : 起票時の Open Question に記載された観測値 (#2081)
#   - `12,5,3,2,2`                      : scripts/tests/fixtures/pr-2070 の実測 JSON から復元した
#                                         補助 fixture。契約値 `3,6,5,3,0` とは一致しないが、
#                                         当該 cycle の実行時期は中間サイクル JSON の無音欠落を
#                                         塞いだ修正より前で、保存済み 9 件が連続 9 cycle である
#                                         保証がない。どちらも他方を反証できないため両方を pin する
#   - `10,11,11,13`                     : ループ打ち切り時に記録された 3 run 目の実測 (#2052)
#
# Convention (shared with the sibling suite): mktemp sandbox, no network, no gh,
# GNU/BSD portable (jq only). --results-dir を明示するため git repo は不要。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"

SCRIPT="$SCRIPT_DIR/../scripts/review-trend-divergence.sh"

echo "=== review-trend-divergence.sh tests ==="

if [ ! -f "$SCRIPT" ]; then
  echo "ERROR: $SCRIPT not found" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  # Floor first: jq is a prerequisite for every leg, so its absence on the blocking
  # gate means it was removed or shadowed on PATH, not that the platform lacks it.
  # Skipping there would drop this file's entire coverage while the run stays green.
  if [ -d /proc ]; then
    echo "  ❌ FAIL: review-trend-divergence floor: jq unavailable on Linux (missing or shadowed on PATH?) — this file's coverage must never be skipped on the blocking gate"
    echo "Results: 0 passed, 1 failed"
    exit 1
  fi
  skip "review-trend-divergence: jq unavailable"
  print_summary "review-trend-divergence"
  exit $?
fi

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
OUT="$SANDBOX/out.txt"

# ---------------------------------------------------------------------------
# Fixture builder
#
# blocking 件数 N のレビュー結果 JSON を 1 件生成する。scope=current-pr かつ
# verification.measured=true の finding を N 件並べる (consumer 式の blocking 定義に合致する
# 最小形)。timestamp は連番で与え、ファイル名の lexicographic 順 = 時系列順を保つ。
# ---------------------------------------------------------------------------
make_result() {
  # $1 = dir, $2 = pr, $3 = seq (2 桁), $4 = blocking count, $5 = schema_version (省略時 1.1.0),
  # $6 = basename suffix (省略時なし)。`~<hex>` を渡すと review-result-save.sh の
  # collision-resolved 命名 (`{ts}~{hex}.json`) を再現する — `.` < `~` の LC_ALL=C 昇順で
  # 同 ts の後ろへ並ぶことが実装 2 経路 (要素順 / 境界選別) の前提になっている。
  local dir="$1" pr="$2" seq="$3" n="$4" sv="${5:-1.1.0}" sfx="${6:-}"
  jq -n --arg sv "$sv" --argjson pr "$pr" --argjson n "$n" '
    {
      schema_version: $sv,
      pr_number: $pr,
      timestamp: "2026-01-01T00:00:00+09:00",
      commit_sha: "deadbeef",
      overall_assessment: (if $n == 0 then "mergeable" else "fix-needed" end),
      findings: [ range(0; $n) | {
        id: ("F-" + tostring),
        reviewer: "code-quality-reviewer",
        category: "code_quality",
        severity: "HIGH",
        scope: "current-pr",
        pre_existing: false,
        verification: { measured: true, repro: "cmd => err", failing_test: null },
        file: "a.ts", line: 1,
        description: "d", suggestion: "s", status: "open"
      } ],
      non_blocking_findings: []
    }' > "$dir/${pr}-202601010000${seq}${sfx}.json"
}

# トラジェクトリを 1 ディレクトリに展開し、判定結果を $OUT へ書く。
run_trend() {
  # $1 = pr, $2.. = counts
  local pr="$1"; shift
  local dir="$SANDBOX/pr-$pr"
  rm -rf "$dir"; mkdir -p "$dir"
  local i=0 n
  for n in "$@"; do
    i=$((i + 1))
    make_result "$dir" "$pr" "$(printf '%02d' "$i")" "$n"
  done
  # pin を渡さない = 単一 run のディレクトリ (全件を 1 本の列として読む)
  bash "$SCRIPT" --pr "$pr" --cycle-count "$#" --results-dir "$dir" > "$OUT" 2>/dev/null
}

# ---------------------------------------------------------------------------
# T-01: 収束トラジェクトリで不発火 (AC-1)
# ---------------------------------------------------------------------------
echo "--- T-01: 収束 run の保護 (AC-1) ---"

run_trend 100 3 6 5 3 0
assert_grep "T-01a: AC-1 契約列 3,6,5,3,0 は発火しない" "$OUT" "TREND_DIVERGENCE=ok"
assert_grep "T-01a: トレンドが通知用に出力される" "$OUT" "trend=3,6,5,3,0"

run_trend 101 10 8 8
assert_grep "T-01b: #2081 実測の 10,8,8 は発火しない" "$OUT" "TREND_DIVERGENCE=ok"

run_trend 102 12 5 3 2 2
assert_grep "T-01c: #2070 実測の 12,5,3,2,2 は発火しない (残 2 件で予算切れの保護対象)" "$OUT" "TREND_DIVERGENCE=ok"

# AC-1 は「どの時点でも発火しない」を要求する。各 prefix を独立に評価する。
run_trend 103 3 6 5
assert_grep "T-01d: 3,6,5,3,0 の先頭 3 cycle 時点でも発火しない" "$OUT" "TREND_DIVERGENCE=ok"
run_trend 104 3 6 5 3
assert_grep "T-01e: 先頭 4 cycle 時点でも発火しない" "$OUT" "TREND_DIVERGENCE=ok"

# ---------------------------------------------------------------------------
# T-02: 発散トラジェクトリで cycle 上限 (既定 5) より早く発火 (AC-2)
# ---------------------------------------------------------------------------
echo "--- T-02: 発散 run の早期検出 (AC-2) ---"

run_trend 200 3 7 7 4
assert_grep "T-02a: #2052 run1 の 3,7,7,4 は発火する" "$OUT" "TREND_DIVERGENCE=fire"
assert_grep "T-02a: 既定上限 5 より早い cycle 3 で発火する" "$OUT" "fire_at=3"

run_trend 201 2 3 6
assert_grep "T-02b: #2052 run3 の 2,3,6 は発火する" "$OUT" "TREND_DIVERGENCE=fire"
assert_grep "T-02b: cycle 3 で発火する" "$OUT" "fire_at=3"

run_trend 202 10 11 11 13
assert_grep "T-02c: #2052 run2 の 10,11,11,13 は発火する" "$OUT" "TREND_DIVERGENCE=fire"
assert_grep "T-02c: cycle 3 で発火する" "$OUT" "fire_at=3"

# escape 節 (直近 2 値が狭義単調減少なら見逃す) が「永久に見逃す」形へ退行していないこと。
# 3,6,5 は escape するが、そこから再上昇した 3,6,5,7 は cycle 4 で発火しなければならない。
run_trend 203 3 6 5 7
assert_grep "T-02d: escape 後に再発散した 3,6,5,7 は cycle 4 で発火する" "$OUT" "fire_at=4"

# ---------------------------------------------------------------------------
# T-03: 漸減非収束は本判定をすり抜け max_review_cycles の保険に落ちる (AC-3)
# ---------------------------------------------------------------------------
echo "--- T-03: 上限保険の維持 (AC-3) ---"

run_trend 300 10 9 8 7 6
assert_grep "T-03a: 漸減非収束 10,9,8,7,6 は発火せず上限保険へ委ねる" "$OUT" "TREND_DIVERGENCE=ok"

run_trend 301 5 4 3 2 1
assert_grep "T-03b: 0 に達しない単調減少も発火しない" "$OUT" "TREND_DIVERGENCE=ok"

# 「過去の最良水準で平坦」(4,4,4,4) は発火しない — これは意図した境界であって取りこぼしではない。
# 判定条件は「直近 2 値が過去の最良水準を **超える**」であり、最良水準と同値の平坦は超えない。
# `>` を `>=` に緩めると 7 本の実トラジェクトリは全て通るが、`12,5,3,2,2,2` のように最良水準で
# 数サイクル足踏みする run が発火するようになる。本判定が存在する動機そのものが「残り数件まで
# 来たループを予算で殺さない」ことであり、そこで足踏みしている run を早期に殺すのは AC-1 が最優先で禁じる
# false positive にあたる。平坦な非収束は AC-3 の「発散判定をすり抜ける遅い非収束」として
# max_review_cycles の保険が受け止める。
run_trend 302 4 4 4 4
assert_grep "T-03c: 最良水準で平坦な 4,4,4,4 は発火せず上限保険へ委ねる (false positive 回避)" "$OUT" "TREND_DIVERGENCE=ok"

# 一方、最良水準を **超えた** 位置での平坦 (3 の後の 7,7) は発火する。escape 節は「下降中」だけを
# 見逃す規定であり、平坦を見逃す規定ではない — ここが緩むと AC-2 の 3,7,7,4 / 10,11,11,13 が通る。
run_trend 303 3 7 7 7
assert_grep "T-03d: 最良水準を超えた位置での平坦 3,7,7,7 は発火する" "$OUT" "TREND_DIVERGENCE=fire"

# 条件 (1) の `>` 境界は a 側・b 側の 2 辺を持つ。4,4,4,4 は両辺が同時に min と同値のため
# 「両辺を同時に緩めた」変異しか検出できない。a 側だけを `>=` に緩める 1 文字改変を捕まえるには
# 「a == min かつ b > min」の列が要る — これは「最良水準まで下げた後に 1 件戻った」形で、
# AC-1 が最優先で禁じる false positive 側の向きそのもの。
run_trend 304 4 4 5
assert_grep "T-03e: 最良水準と同値からの再上昇 4,4,5 は発火しない (a 側境界の pin)" "$OUT" "TREND_DIVERGENCE=ok"

# header の rationale が名指しする実データ形状も同じ向きで pin する
run_trend 305 12 5 3 2 2 3
assert_grep "T-03f: 残り僅かで足踏み後に 1 件戻った 12,5,3,2,2,3 は発火しない" "$OUT" "TREND_DIVERGENCE=ok"

# ---------------------------------------------------------------------------
# T-05: 決定論性 (AC-5)
# ---------------------------------------------------------------------------
echo "--- T-05: 判定の決定論性 (AC-5) ---"

det_dir="$SANDBOX/determinism"; mkdir -p "$det_dir"
det_i=0
for det_n in 3 7 7 4; do
  det_i=$((det_i + 1))
  make_result "$det_dir" 500 "$(printf '%02d' "$det_i")" "$det_n"
done
det_first=$(bash "$SCRIPT" --pr 500 --cycle-count 4 --results-dir "$det_dir" 2>/dev/null)
# 「5 回同じ」だけでは helper が無出力になっても通る (両辺が空文字で一致する)。
# 決定論の対象が期待どおりの verdict であることを先に固定してから一致を見る。
printf '%s' "$det_first" > "$OUT"
assert_grep "T-05: 決定論の対象が期待 verdict であること" "$OUT" "TREND_DIVERGENCE=fire; trend=3,7,7,4; cycles=4; lost=0; fire_at=3"
det_same=yes
for _ in 1 2 3 4; do
  det_again=$(bash "$SCRIPT" --pr 500 --cycle-count 4 --results-dir "$det_dir" 2>/dev/null)
  [ "$det_again" = "$det_first" ] || det_same=no
done
assert "T-05: 同一入力に対し 5 回連続で同一出力を返す" "yes" "$det_same"

# ---------------------------------------------------------------------------
# T-06: データ不足・データ異常はすべて安全側 (不発火) かつ理由付き (AC-3 の backstop へ委譲)
# ---------------------------------------------------------------------------
echo "--- T-06: 不足・異常時の安全側判定 ---"

run_trend 600 5
assert_grep "T-06a: 1 cycle 目は判定対象外 (need_3_cycles)" "$OUT" "reason=need_3_cycles"
assert_not_grep "T-06a: 1 cycle 目に発火しない" "$OUT" "TREND_DIVERGENCE=fire"

run_trend 601 5 9
assert_grep "T-06b: 2 cycle 目も判定対象外" "$OUT" "reason=need_3_cycles"

# データ不足の 2 経路は cycle_count で正常系と異常系に分かれる。cycle_count>=1 は
# 「N 回レビュー済みなのに結果が読めない」= 発散検出の全面不作動なので WARNING を出す。
# 無音のままだと呼び出し側の marker が正常系 (need_3_cycles) と完全一致して観測不能になる。
empty_dir="$SANDBOX/empty"; mkdir -p "$empty_dir"
bash "$SCRIPT" --pr 602 --cycle-count 3 --results-dir "$empty_dir" > "$OUT" 2>"$SANDBOX/empty-err.txt"
assert_grep "T-06c: JSON が 1 件も無いとき no_results_file で不発火" "$OUT" "reason=no_results_file"
assert_grep "T-06c: cycle_count>=1 の 0 件は異常として WARNING を出す" "$SANDBOX/empty-err.txt" "レビュー結果 JSON が 1 件もありません"
assert_grep "T-06c: WARNING に cycle_count を含める (全面不作動の識別材料)" "$SANDBOX/empty-err.txt" "cycle_count=3"

bash "$SCRIPT" --pr 603 --cycle-count 3 --results-dir "$SANDBOX/does-not-exist" > "$OUT" 2>"$SANDBOX/nodir-err.txt"
assert_grep "T-06d: ディレクトリ不在で results_dir_missing" "$OUT" "reason=results_dir_missing"
assert_grep "T-06d: cycle_count>=1 の dir 不在は異常として WARNING を出す" "$SANDBOX/nodir-err.txt" "レビュー結果ディレクトリが存在しません"
assert_grep "T-06d: WARNING に cycle_count を含める (全面不作動の識別材料)" "$SANDBOX/nodir-err.txt" "cycle_count=3"

# cycle_count=0 は呼び出し側の live path (fresh run の初回 cycle で必ず渡る)。
# このときの不足は正常系なので WARNING を出さない — 出すと毎 run の初回に必ずノイズが乗り、
# 本当に surface したい異常が埋もれる。
bash "$SCRIPT" --pr 612 --cycle-count 0 --results-dir "$SANDBOX/does-not-exist" > "$OUT" 2>"$SANDBOX/fresh-err.txt"
assert_grep "T-06m: cycle_count=0 (fresh run 初回) でも判定不能を返す" "$OUT" "reason=results_dir_missing"
assert_not_grep "T-06m: cycle_count=0 の不足は正常系なので WARNING を出さない" "$SANDBOX/fresh-err.txt" "WARNING:"
assert_not_grep "T-06m: cycle_count=0 で発火しない" "$OUT" "TREND_DIVERGENCE=fire"

# ファイル数 < cycle_count: 保存失敗 / review 中断で結果が失われた状態。
# run 境界は pin が決めるため、欠落は「列に穴が空く」だけで前 run の混入とは別種。
# 判定を降ろすと、その run の残り全 cycle で発散検出が恒久的に無効化される (中断からの
# resume は counter を戻さないため差が縮まらない) ため、実在する列で判定を続行し
# 失われた件数を WARNING で surface する。
short_dir="$SANDBOX/short"; mkdir -p "$short_dir"
make_result "$short_dir" 604 01 2
make_result "$short_dir" 604 02 3
make_result "$short_dir" 604 03 6
bash "$SCRIPT" --pr 604 --cycle-count 5 --results-dir "$short_dir" > "$OUT" 2>"$SANDBOX/short-err.txt"
assert_grep "T-06e: ファイル数不足でも実在する列で判定を続行する" "$OUT" "trend=2,3,6"
assert_grep "T-06e: 発散列は欠落があっても発火する (恒久無効化しない)" "$OUT" "TREND_DIVERGENCE=fire"
assert_grep "T-06e: 失われた件数を WARNING で surface する" "$SANDBOX/short-err.txt" "files=3 < cycles=5"

# 欠落が生じても run 境界は pin が守る: 前 run のファイルが同居していても混入しない。
# (旧 cycle_count 切り出しでは _total >= cycle_count を満たしてしまい前 run を取り込んだ)
short_multi_dir="$SANDBOX/short-multirun"; mkdir -p "$short_multi_dir"
make_result "$short_multi_dir" 610 01 8
make_result "$short_multi_dir" 610 02 5
make_result "$short_multi_dir" 610 03 3
make_result "$short_multi_dir" 610 04 1
make_result "$short_multi_dir" 610 05 3
make_result "$short_multi_dir" 610 06 3
bash "$SCRIPT" --pr 610 --cycle-count 3 --since "610-20260101000004.json" --results-dir "$short_multi_dir" > "$OUT" 2>/dev/null
assert_grep "run 境界 (pin): 現 run が cycle_count に 1 件不足でも前 run を取り込まない" "$OUT" "trend=3,3"
assert_not_grep "run 境界 (pin): 前 run の低い件数で健全な run を発散判定しない" "$OUT" "TREND_DIVERGENCE=fire"

# insufficient (need_3_cycles) 経路の lost= も pin する。消費側は lost= 欠落を無音で 0 に倒すため、
# 未 pin だと退行しても「列に穴がある」signal が消え、停止通知が合成推移を実測として描画する。
short2_dir="$SANDBOX/short2"; mkdir -p "$short2_dir"
make_result "$short2_dir" 614 01 4
make_result "$short2_dir" 614 02 5
bash "$SCRIPT" --pr 614 --cycle-count 3 --results-dir "$short2_dir" > "$OUT" 2>/dev/null
assert_grep "T-06o: 3 cycle 未満でも lost= を marker に載せる" "$OUT" "cycles=2; lost=1; reason=need_3_cycles"

# 破損 JSON / 未知 schema / pr_number 不一致はいずれも「判定不能」であって発散ではない。
bad_dir="$SANDBOX/bad"; mkdir -p "$bad_dir"
make_result "$bad_dir" 605 01 2
make_result "$bad_dir" 605 02 3
printf 'not json at all' > "$bad_dir/605-20260101000003.json"
bash "$SCRIPT" --pr 605 --cycle-count 3 --results-dir "$bad_dir" > "$OUT" 2>/dev/null
assert_grep "T-06f: 破損 JSON は json_parse_failure で不発火" "$OUT" "reason=json_parse_failure"

ver_dir="$SANDBOX/ver"; mkdir -p "$ver_dir"
make_result "$ver_dir" 606 01 2
make_result "$ver_dir" 606 02 3
make_result "$ver_dir" 606 03 6 "9.9.9"
bash "$SCRIPT" --pr 606 --cycle-count 3 --results-dir "$ver_dir" > "$OUT" 2>/dev/null
assert_grep "T-06g: 未知 schema_version は schema_version_unknown で不発火" "$OUT" "reason=schema_version_unknown"

# scope が 3 値 enum に解決できない finding は、黙って blocking 件数から落とさない。
# 落とすと件数が過少になり「発火しない」方向へ静かに倒れる (方向としては安全側だが、
# 他 5 つの異常経路がすべて理由付きで返すのに対しここだけ理由なしの数値を返すのは非対称)。
scope_bad_dir="$SANDBOX/scope-bad"; mkdir -p "$scope_bad_dir"
make_result "$scope_bad_dir" 608 01 2
make_result "$scope_bad_dir" 608 02 3
# schema 1.1.0 で scope 欠落 (default mapping の対象外 — 1.0 系のみが対象)
jq '.findings[0] |= del(.scope)' "$scope_bad_dir/608-20260101000002.json" > "$scope_bad_dir/608-20260101000003.json"
bash "$SCRIPT" --pr 608 --cycle-count 3 --results-dir "$scope_bad_dir" > "$OUT" 2>/dev/null
assert_grep "T-06i: 1.1.0 で scope 欠落は scope_enum_violation で不発火 (silent 過少計上を排除)" "$OUT" "reason=scope_enum_violation"
assert_not_grep "T-06i: scope 解決不能では発火しない" "$OUT" "TREND_DIVERGENCE=fire"

# enum 外の値も同様に扱う (値の外れとキー欠落で扱いを割らない)
jq '.findings[0].scope = "whole-repo"' "$scope_bad_dir/608-20260101000002.json" > "$scope_bad_dir/608-20260101000003.json"
bash "$SCRIPT" --pr 608 --cycle-count 3 --results-dir "$scope_bad_dir" > "$OUT" 2>/dev/null
assert_grep "T-06j: enum 外の scope 値も scope_enum_violation で不発火" "$OUT" "reason=scope_enum_violation"

# schema 1.0.0 の scope 欠落は severity ベース default mapping で解決するため違反ではない
mixed_dir="$SANDBOX/scope-legacy"; mkdir -p "$mixed_dir"
make_result "$mixed_dir" 609 01 2
make_result "$mixed_dir" 609 02 2
cat > "$mixed_dir/609-20260101000003.json" <<'EOF'
{
  "schema_version": "1.0.0", "pr_number": 609,
  "timestamp": "2026-01-01T00:00:00+09:00", "commit_sha": "abc",
  "overall_assessment": "fix-needed",
  "findings": [{"id":"F-01","severity":"HIGH"},{"id":"F-02","severity":"LOW"}],
  "non_blocking_findings": []
}
EOF
bash "$SCRIPT" --pr 609 --cycle-count 3 --results-dir "$mixed_dir" > "$OUT" 2>/dev/null
assert_grep "T-06k: schema 1.0.0 の scope 欠落は default mapping で解決し違反にしない" "$OUT" "trend=2,2,1"

# accept list の 3 値すべてを read 側で pin する。1.1.0 は上の全 fixture が、1.0.0 は T-06k が
# 踏むが、legacy の MAJOR.MINOR 形式 (1.0) だけが未固定で、case から 1 値落とす改変が通っていた。
legacy_dir="$SANDBOX/schema-legacy-minor"; mkdir -p "$legacy_dir"
make_result "$legacy_dir" 611 01 6 "1.0"
make_result "$legacy_dir" 611 02 3 "1.0"
make_result "$legacy_dir" 611 03 1 "1.0"
bash "$SCRIPT" --pr 611 --cycle-count 3 --results-dir "$legacy_dir" > "$OUT" 2>/dev/null
assert_grep "T-06l: schema_version 1.0 (MAJOR.MINOR) を accept する" "$OUT" "trend=6,3,1"
assert_not_grep "T-06l: 1.0 を未知 schema として弾かない" "$OUT" "reason=schema_version_unknown"

# 診断へ埋め込む JSON 由来値の制御文字中和 (_nz)。中和が無いと schema_version に仕込んだ改行が
# WARNING を 2 行に割り、2 行目が独立した診断行に偽装できる (呼び出し側 iterate は helper の
# stderr を capture せず素通しさせる設計のため端末まで届く)。中和を外しても緑のままだと
# この防御は dead surface になるため、破壊入力を fixture 化して pin する。
ctl_dir="$SANDBOX/ctrlchars"; mkdir -p "$ctl_dir"
make_result "$ctl_dir" 613 01 2
_ctl_esc=$(printf '\033')
jq --arg sv "9.9.9${_ctl_esc}[31mRED
WARNING: FORGED DIAGNOSTIC" '.schema_version = $sv' "$ctl_dir/613-20260101000001.json" > "$ctl_dir/613-20260101000002.json"
bash "$SCRIPT" --pr 613 --cycle-count 2 --results-dir "$ctl_dir" > "$OUT" 2>"$SANDBOX/ctl-err.txt"
assert_grep "T-06n: ESC を含む値は ? へ中和して埋め込む" "$SANDBOX/ctl-err.txt" "schema_version='9\.9\.9[?]"
assert_grep "T-06n: 埋め込んだ改行も ? へ中和する (偽の診断行を作らせない)" "$SANDBOX/ctl-err.txt" "RED[?]WARNING: FORGED DIAGNOSTIC'"
assert "T-06n: 中和により WARNING は 1 行に収まる (偽の診断行を作らせない)" "1" "$(wc -l < "$SANDBOX/ctl-err.txt" | tr -d '[:space:]')"
assert "T-06n: 生 ESC バイトが stderr へ素通ししない" "0" "$(od -An -c < "$SANDBOX/ctl-err.txt" | grep -c '033')"

mism_dir="$SANDBOX/mismatch"; mkdir -p "$mism_dir"
make_result "$mism_dir" 607 01 2
make_result "$mism_dir" 607 02 3
# ファイル名 prefix 607 に対し JSON の pr_number を 999 にする (cross-field invariant #1 違反)
jq '.pr_number = 999' "$mism_dir/607-20260101000002.json" > "$mism_dir/607-20260101000003.json"
bash "$SCRIPT" --pr 607 --cycle-count 3 --results-dir "$mism_dir" > "$OUT" 2>/dev/null
assert_grep "T-06h: pr_number 不一致は pr_number_mismatch で不発火" "$OUT" "reason=pr_number_mismatch"

# 集計 filter そのものが落ちる経路 (findings[] に object でない要素が混ざる)。`jq empty` は
# 通過するため schema / pr_number gate では捕まらず、blocking 件数の算出だけが失敗する。
# 本 fixture は reason の pin に加え、jq の診断本文が stderr へ届くこと (診断転記を no-op に
# しても緑のままになる穴を塞ぐ) と、診断が対応する WARNING の**後**に出ること (継続行規約 —
# 前に出すと直前の別 WARNING の継続行位置へ着地して原因が誤帰属する) を pin する。
bcf_dir="$SANDBOX/blocking-count-failed"; mkdir -p "$bcf_dir"
make_result "$bcf_dir" 608 01 2
make_result "$bcf_dir" 608 02 1
jq '.findings = [1, 2]' "$bcf_dir/608-20260101000002.json" > "$bcf_dir/608-20260101000003.json"
bash "$SCRIPT" --pr 608 --cycle-count 3 --results-dir "$bcf_dir" > "$OUT" 2>"$SANDBOX/bcf-err.txt"
assert_grep "T-06b: 集計 filter の失敗は blocking_count_failed で不発火" "$OUT" "reason=blocking_count_failed"
assert_grep "T-06b: jq の診断本文が stderr へ届く (抑止を外した意図の pin)" "$SANDBOX/bcf-err.txt" "jq: error"
bcf_warn_line=$(grep -n '^WARNING: blocking 件数を算出できません' "$SANDBOX/bcf-err.txt" | head -1 | cut -d: -f1)
bcf_diag_line=$(grep -n 'jq: error' "$SANDBOX/bcf-err.txt" | head -1 | cut -d: -f1)
assert "T-06b: 診断は対応する WARNING の後に出る (継続行規約)" "yes" \
  "$([ -n "$bcf_warn_line" ] && [ -n "$bcf_diag_line" ] && [ "$bcf_diag_line" -gt "$bcf_warn_line" ] && echo yes || echo no)"

# ---------------------------------------------------------------------------
# run 境界
#
# review-results は /rite:cleanup まで削除されないため同一 PR の複数 run が同居する。
# run 開始点 pin (--since) で切り出さないと、再実行直後に前 run の件数を読んで即発火する。
# ---------------------------------------------------------------------------
echo "--- run 境界の切り出し (D-05) ---"

multi_dir="$SANDBOX/multirun"; mkdir -p "$multi_dir"
multi_i=0
# 前 run (発散して打ち切られた 3,7,7,4) + 現 run (収束中の 5,3,1)
for multi_n in 3 7 7 4 5 3 1; do
  multi_i=$((multi_i + 1))
  make_result "$multi_dir" 700 "$(printf '%02d' "$multi_i")" "$multi_n"
done
# pin = 前 run の最終ファイル (4 件目)。それより新しい 3 件だけが現 run。
bash "$SCRIPT" --pr 700 --cycle-count 3 --since "700-20260101000004.json" --results-dir "$multi_dir" > "$OUT" 2>/dev/null
assert_grep "run 境界: pin より新しい 3 件だけを読む" "$OUT" "trend=5,3,1"
assert_grep "run 境界: 前 run の発散を現 run に持ち越さない" "$OUT" "TREND_DIVERGENCE=ok"

bash "$SCRIPT" --pr 700 --cycle-count 7 --results-dir "$multi_dir" > "$OUT" 2>/dev/null
assert_grep "run 境界: pin なしなら全件を 1 本の列として読む (後方互換)" "$OUT" "trend=3,7,7,4,5,3,1"

# pin は「厳密に新しい」— pin 自身 (前 run の最終ファイル) を現 run に含めない
bash "$SCRIPT" --pr 700 --cycle-count 4 --since "700-20260101000003.json" --results-dir "$multi_dir" > "$OUT" 2>/dev/null
assert_grep "run 境界: pin 自身は現 run に含まれない (厳密に新しいもののみ)" "$OUT" "trend=4,5,3,1"

# pin より新しいファイルが 1 件も無い = 現 run の結果がすべて失われている
bash "$SCRIPT" --pr 700 --cycle-count 2 --since "700-20260101000007.json" --results-dir "$multi_dir" > "$OUT" 2>"$SANDBOX/pin-err.txt"
assert_grep "run 境界: pin より新しい結果が 0 件なら判定不能 (前 run を読まない)" "$OUT" "reason=no_file_after_pin"
assert_not_grep "run 境界: pin 後 0 件は dir 不在系の reason と混同しない" "$OUT" "reason=no_results_file"
assert_grep "run 境界: 0 件の理由を WARNING で surface する" "$SANDBOX/pin-err.txt" "run 開始点 pin"

# **過剰取り込みの invariant**: 実在数が cycle_count を超えたら他 run の混入として判定を降ろす。
# pin が書けなかった環境 / pin 導入前の run では since が空で全件を読むため、複数 run が同居して
# いればここで捕まる。この guard が無いと前 run 末尾の低い件数が prefix_min を汚染し、健全な run を
# 発散判定で殺す (AC-1 の否定)。cycle_count=0 (現 run でまだ 1 度もレビューしていない) も同式が拾う。
bash "$SCRIPT" --pr 700 --cycle-count 3 --results-dir "$multi_dir" > "$OUT" 2>"$SANDBOX/over-err.txt"
assert_grep "run 境界: pin 不在で実在数が cycle_count を超えたら判定を降ろす" "$OUT" "reason=run_boundary_unresolved"
assert_not_grep "run 境界: 過剰取り込みでは発火しない (健全な run を殺さない)" "$OUT" "TREND_DIVERGENCE=fire"
assert_grep "run 境界: 過剰取り込みの理由を WARNING で surface する" "$SANDBOX/over-err.txt" "files=7 > cycles=3"
assert_grep "run 境界: 境界を確定できない理由を WARNING が示す" "$SANDBOX/over-err.txt" "run 開始点 pin が無いか、現 run でまだ 1 度もレビューが完了していない"

bash "$SCRIPT" --pr 700 --cycle-count 0 --results-dir "$multi_dir" > "$OUT" 2>/dev/null
assert_grep "run 境界: pin 不在かつ cycle_count=0 でも判定を降ろす" "$OUT" "reason=run_boundary_unresolved"
assert_not_grep "run 境界: cycle_count=0 では発火しない (旧実装の構造的保護を維持)" "$OUT" "TREND_DIVERGENCE=fire"

# **pin 有りの超過は判定を降ろさない**。pin があれば列は現 run のものと保証されており、超過は
# counter 側の skew (INC 失敗 / Stop hook 再注入) にすぎない。ここで降ろすと skew が run 終了まで
# 解消しないため発散検出が恒久的に無効化される — 不足側で降ろしていた旧実装と同型の失敗になる。
bash "$SCRIPT" --pr 700 --cycle-count 1 --since "700-20260101000004.json" --results-dir "$multi_dir" > "$OUT" 2>"$SANDBOX/over-pin-err.txt"
assert_grep "run 境界: pin 有りの超過は判定を降ろさず実在列で続行する" "$OUT" "trend=5,3,1"
assert_not_grep "run 境界: pin 有りの超過を run_boundary_unresolved にしない" "$OUT" "reason=run_boundary_unresolved"
assert_grep "run 境界: 超過の理由 (counter skew) を WARNING で surface する" "$SANDBOX/over-pin-err.txt" "files=3 > cycles=1"
assert_grep "run 境界: 判定を続行することを WARNING が明示する" "$SANDBOX/over-pin-err.txt" "run 境界は pin が保証しているため"

# 続行の**向き**を両方 pin する。収束列だけだと、AC-1 が最優先で禁じる向き (健全な run を殺す)
# へ挙動が動いても検出できない。発散列は pin 有り超過でも fire するのが正。
over_div_dir="$SANDBOX/over-div"; mkdir -p "$over_div_dir"
make_result "$over_div_dir" 705 01 9
make_result "$over_div_dir" 705 02 1
make_result "$over_div_dir" 705 03 5
make_result "$over_div_dir" 705 04 6
bash "$SCRIPT" --pr 705 --cycle-count 2 --since "705-20260101000001.json" --results-dir "$over_div_dir" > "$OUT" 2>/dev/null
assert_grep "run 境界: pin 有りの超過で発散列は発火する (続行の向きを pin)" "$OUT" "trend=1,5,6;"
assert_grep "run 境界: pin 有りの超過での発火点を固定する" "$OUT" "fire_at=3"

# cycle_count=0 は pin が非空でも境界未知として扱う (stale pin の捕捉)。
bash "$SCRIPT" --pr 705 --cycle-count 0 --since "705-20260101000001.json" --results-dir "$over_div_dir" > "$OUT" 2>/dev/null
assert_grep "run 境界: cycle_count=0 は pin 非空でも判定を降ろす (stale pin の捕捉)" "$OUT" "reason=run_boundary_unresolved"
assert_not_grep "run 境界: stale pin で前 run の列を読んで発火しない" "$OUT" "TREND_DIVERGENCE=fire"

# 不足側は降ろさない (方向で扱いを分ける)。過剰と同じ扱いにすると中断 1 回で恒久無効化する。
bash "$SCRIPT" --pr 700 --cycle-count 5 --since "700-20260101000004.json" --results-dir "$multi_dir" > "$OUT" 2>/dev/null
assert_grep "run 境界: 不足側は判定を降ろさず実在列で続行する" "$OUT" "trend=5,3,1"
assert_grep "run 境界: 失われた件数を marker の lost= に載せる" "$OUT" "lost=2"

# collision-resolved 名 (`{ts}~{hex}.json`) は review-result-save.sh が同秒衝突時に実際に作る形。
# `.` (0x2e) < `~` (0x7e) の LC_ALL=C 昇順により同 ts の後ろへ並ぶ。この順序前提は独立した 2 経路が
# 依存する — find のソートは trend の**要素順**、pin 比較のソートは **run 境界の選別**。
# 非 C locale では `~` の照合位置が変わりうるため、両方を別々に pin する。
# **非 C locale の明示が必要**: ambient locale では検出できない。glibc の ja_JP / C.UTF-8 は
# どちらもドットとチルダを C と同順に照合するため、`LC_ALL=C` を外しても順序が変わらず
# 全 PASS のまま通る (実測)。`en_US.UTF-8` を明示すると mutant と pristine が分離できるので、
# これは原理的限界ではなく塞げる穴。**無条件に付けてはならない** — locale 未生成の環境では
# C 照合へ黙って縮退し、無シグナルで「契約未 pin」の状態へ戻るため、存在を確認して
# 無ければ skip する (SKIP は集計されるので gate 落ちが可視化される)。
coll_dir="$SANDBOX/collision"; mkdir -p "$coll_dir"
make_result "$coll_dir" 901 01 5 "" ""
make_result "$coll_dir" 901 02 4 "" ""
make_result "$coll_dir" 901 03 1 "" ""
make_result "$coll_dir" 901 03 3 "" "~ab12"
make_result "$coll_dir" 901 04 7 "" ""
if locale -a 2>/dev/null | grep -qiE '^en_US\.utf-?8$'; then
  LC_ALL=en_US.UTF-8 bash "$SCRIPT" --pr 901 --cycle-count 5 --results-dir "$coll_dir" > "$OUT" 2>/dev/null
  assert_grep "collision 名: 同 ts の ~ 版が直後に並ぶ (要素順の pin)" "$OUT" "trend=5,4,1,3,7;"

  LC_ALL=en_US.UTF-8 bash "$SCRIPT" --pr 901 --cycle-count 3 --since "901-20260101000003.json" --results-dir "$coll_dir" > "$OUT" 2>/dev/null
  assert_grep "collision 名: ~ 版は pin より新しい側に入る (境界選別の pin)" "$OUT" "trend=3,7;"
else
  skip "collision 順序契約: en_US.UTF-8 が無く LC_ALL=C 除去を検出できない"
fi

# **guard の限界を意図した仕様として pin する**。`cycle_count == 0` が捕まえるのは stale pin の
# 部分集合だけで、stale pin と counter が同量繰り上がった形 (実在数 == cycle_count) では
# guard 条件が偽になり、前 run の列を診断なしで読んで判定する。これは「塞いだ」のではなく
# 「ここまで塞いだ」であり、残余はステップ 5.0.1 (正常終了時に run を閉じる) が担う。
# 限界を assert として書くことで、次に guard を触る担当者が残余を誤解しない。
stale_dir="$SANDBOX/stale-equal"; mkdir -p "$stale_dir"
make_result "$stale_dir" 707 01 9
make_result "$stale_dir" 707 02 3
make_result "$stale_dir" 707 03 2
make_result "$stale_dir" 707 04 0
make_result "$stale_dir" 707 05 4
make_result "$stale_dir" 707 06 4
bash "$SCRIPT" --pr 707 --cycle-count 5 --since "707-20260101000001.json" --results-dir "$stale_dir" > "$OUT" 2>"$SANDBOX/stale-err.txt"
assert_grep "guard の限界: stale pin + 実在数 == cycle_count は素通りする (意図した限界)" "$OUT" "trend=3,2,0,4,4;"
assert_not_grep "guard の限界: 素通り時は run_boundary_unresolved にならない" "$OUT" "reason=run_boundary_unresolved"
assert_not_grep "guard の限界: 素通り時は WARNING も出ない (残余はステップ 5.0.1 が担う)" "$SANDBOX/stale-err.txt" "WARNING:"

# fresh run の初回 (pin == 最新ファイル、cycle_count=0) は guard に到達せず無音で判定不能を返す。
# `no_file_after_pin` が先に return するため。これが崩れると毎 run の初回にノイズが乗る。
bash "$SCRIPT" --pr 707 --cycle-count 0 --since "707-20260101000006.json" --results-dir "$stale_dir" > "$OUT" 2>"$SANDBOX/fresh0-err.txt"
assert_grep "正常系: fresh run 初回は no_file_after_pin (guard に到達しない)" "$OUT" "reason=no_file_after_pin"
assert_not_grep "正常系: fresh run 初回は WARNING を出さない" "$SANDBOX/fresh0-err.txt" "WARNING:"

# F-06: 既定 results_dir 解決ブロック (本番の 100% がここを通る) のカバレッジ。
# resolver を実行できない隔離コピーで、cycle 4 が `2>/dev/null` を外した意図を pin する。
iso_dir="$SANDBOX/iso"; mkdir -p "$iso_dir"
cp "$SCRIPT" "$iso_dir/h.sh"
( cd "$iso_dir" && bash ./h.sh --pr 707 --cycle-count 1 ) > "$OUT" 2>"$SANDBOX/iso-err.txt"
assert_grep "既定 results_dir: resolver 不在時は cwd 相対へフォールバックし理由を残す" "$SANDBOX/iso-err.txt" "state-path-resolve.sh の解決に失敗"
# 直前の assertion が pin する WARNING は script 自身の echo で、resolver の stderr ではない。
# 部分文字列で照合すると `2>/dev/null` を再付与しても両方緑のままになる (identification power 0)。
# resolver の stderr にしか現れない `bash: <path>:` prefix を needle にする (ENOENT 本文はロケール
# 依存だが prefix は不変)。
assert_grep "既定 results_dir: 抑止を外したので resolver 自身の原因行が届く" "$SANDBOX/iso-err.txt" "^bash: .*/\.\./state-path-resolve\.sh"

# 同一 PR 番号を prefix に持つ別 PR (700 等) を巻き込まないこと
prefix_dir="$SANDBOX/prefix"; mkdir -p "$prefix_dir"
make_result "$prefix_dir" 70 01 1
make_result "$prefix_dir" 70 02 1
make_result "$prefix_dir" 70 03 1
make_result "$prefix_dir" 700 01 9
bash "$SCRIPT" --pr 70 --cycle-count 3 --results-dir "$prefix_dir" > "$OUT" 2>/dev/null
assert_grep "PR 番号 prefix: 70 の glob が 700 を巻き込まない" "$OUT" "trend=1,1,1"

# ---------------------------------------------------------------------------
# blocking 件数の定義 (references/severity-levels.md §実測必須ゲート の consumer 式)
# ---------------------------------------------------------------------------
echo "--- blocking 件数の算出 ---"

scope_dir="$SANDBOX/scope"; mkdir -p "$scope_dir"
# gate 対象 scope 2 件 + nit-noted 1 件 + measured=false 1 件 → blocking は 2 件
cat > "$scope_dir/800-20260101000001.json" <<'EOF'
{
  "schema_version": "1.1.0", "pr_number": 800,
  "timestamp": "2026-01-01T00:00:00+09:00", "commit_sha": "abc",
  "overall_assessment": "fix-needed",
  "findings": [
    {"id":"F-01","severity":"HIGH","scope":"current-pr","verification":{"measured":true}},
    {"id":"F-02","severity":"HIGH","scope":"follow-up","verification":{"measured":true}},
    {"id":"F-03","severity":"LOW","scope":"nit-noted","verification":{"measured":true}},
    {"id":"F-04","severity":"HIGH","scope":"current-pr","verification":{"measured":false}}
  ],
  "non_blocking_findings": []
}
EOF
# 未判定 (verification 欠落) は blocking のまま扱う (3 値モデル)
cat > "$scope_dir/800-20260101000002.json" <<'EOF'
{
  "schema_version": "1.1.0", "pr_number": 800,
  "timestamp": "2026-01-01T00:00:00+09:00", "commit_sha": "abc",
  "overall_assessment": "fix-needed",
  "findings": [
    {"id":"F-01","severity":"HIGH","scope":"current-pr"}
  ],
  "non_blocking_findings": []
}
EOF
# schema 1.0.0 は scope 欠落 → severity ベース default mapping
# (CRITICAL/HIGH/MEDIUM → current-pr, LOW/LOW-MEDIUM → nit-noted) で 2 件
cat > "$scope_dir/800-20260101000003.json" <<'EOF'
{
  "schema_version": "1.0.0", "pr_number": 800,
  "timestamp": "2026-01-01T00:00:00+09:00", "commit_sha": "abc",
  "overall_assessment": "fix-needed",
  "findings": [
    {"id":"F-01","severity":"CRITICAL"},
    {"id":"F-02","severity":"MEDIUM"},
    {"id":"F-03","severity":"LOW"},
    {"id":"F-04","severity":"LOW-MEDIUM"}
  ],
  "non_blocking_findings": []
}
EOF
bash "$SCRIPT" --pr 800 --cycle-count 3 --results-dir "$scope_dir" > "$OUT" 2>/dev/null
assert_grep "blocking 件数: gate 対象 scope + 未判定を数え nit-noted と measured=false を除く" "$OUT" "trend=2,1,2"

# ---------------------------------------------------------------------------
# 呼び出しエラー (exit 2) — データ条件 (exit 0) と混同しないこと
# ---------------------------------------------------------------------------
echo "--- 呼び出しエラーの分離 ---"

bash "$SCRIPT" >/dev/null 2>&1; rc=$?
assert "引数なしは exit 2 (呼び出しエラー)" "2" "$rc"

bash "$SCRIPT" --pr abc --cycle-count 3 >/dev/null 2>&1; rc=$?
assert "非数値 --pr は exit 2" "2" "$rc"

bash "$SCRIPT" --pr 1 --cycle-count x >/dev/null 2>&1; rc=$?
assert "非数値 --cycle-count は exit 2" "2" "$rc"

bash "$SCRIPT" --pr 1 --cycle-count 3 --results-dir "$SANDBOX/nope" >/dev/null 2>&1; rc=$?
assert "データ条件 (dir 不在) は exit 0 で判定不能を返す" "0" "$rc"

# ---------------------------------------------------------------------------
# 実 fixture (scripts/tests/fixtures/pr-2070) に対する回帰
# ---------------------------------------------------------------------------
echo "--- 実 fixture 回帰 (pr-2070) ---"

REAL_FIXTURE="$SCRIPT_DIR/../../scripts/tests/fixtures/pr-2070"
if [ -d "$REAL_FIXTURE" ]; then
  # pin = 4 件目。それより新しい 5 件が「現 run」に相当する。
  bash "$SCRIPT" --pr 2070 --cycle-count 5 --since "2070-20260731150058.json" --results-dir "$REAL_FIXTURE" > "$OUT" 2>/dev/null
  assert_grep "実 fixture: pin より新しい 5 件の blocking 列を実 JSON から復元できる" "$OUT" "trend=2,4,6,7,4"
  # 抽出層だけでなく判定層も実データで固定する (判定式が変われば落ちる)
  assert_grep "実 fixture: 直近 5 件の列に対する判定結果を固定する" "$OUT" "fire_at=3"
  bash "$SCRIPT" --pr 2070 --cycle-count 9 --results-dir "$REAL_FIXTURE" > "$OUT" 2>/dev/null
  assert_grep "実 fixture: 全 9 件の blocking 列を実 JSON から復元できる" "$OUT" "trend=12,5,3,2,2,4,6,7,4"
  assert_grep "実 fixture: 全 9 件の列に対する判定結果を固定する" "$OUT" "fire_at=7"
else
  # fixture は同一リポジトリの tracked ファイル (#2074 で commit 済) のため、不在 = 削除された
  # ことを意味する。skip すると唯一の実データ回帰 2 件が消えてもスイートは緑のまま通るため、
  # 上部の jq floor と同じ形で Linux では hard fail させる。
  if [ -d /proc ]; then
    echo "  ❌ FAIL: 実 fixture pr-2070 が存在しない ($REAL_FIXTURE) — tracked fixture の欠落は実データ回帰の消失を意味するため skip しない"
    echo "Results: 0 passed, 1 failed"
    exit 1
  fi
  skip "実 fixture pr-2070 が存在しない"
fi

print_summary "review-trend-divergence"
