#!/bin/bash
# rite workflow - review⇄fix ループの収束トレンド判定 (発散検出)
#
# Responsibility: 永続レビュー結果 JSON 群から「現在の run の per-cycle blocking 件数」を
# 復元し、そのトレンドが発散しているかを決定論的に判定する。/rite:iterate のサーキット
# ブレーカーは cycle 数上限だけでなく本判定でも発火する。
#
# Called from:
#   - skills/iterate/SKILL.md ステップ 1 (cycle 上限チェックの直後)。
#     上限未到達でも本 helper が fire を返せばブレーカーへ分岐する。
#
# Usage:
#   bash review-trend-divergence.sh --pr N --cycle-count N [--results-dir PATH]
#
# 出力 (stdout, 1 行):
#   [CONTEXT] TREND_DIVERGENCE=fire|ok|insufficient; trend=<c1,c2,...>; cycles=N; reason=<...>
#   fire のときのみ `fire_at=<cycle>` が付く。
# WARNING / 診断は stderr。
#
# Why 件数上限ではなくトレンドか:
#   cycle 数上限は努力と無駄を区別できない。健全に収束中のループも残り数件のところで予算切れに
#   なり、発散しているループも上限まで燃やしてしまう (どちらも実測されている — 下記 backtest の
#   トラジェクトリがその記録)。「品質を予算で縛らない・無駄は排除する」(CLAUDE.md プロジェクト
#   原則) に従い、切るべきは発散 (無駄) であって収束に向かう実サイクルではない。
#   max_review_cycles は遠い backstop として存置する。
#
# 判定式 (定数。窓幅も閾値も config キーにしない — 調整の実需が観測されてから設定化する
# = no_speculative_structure):
#   cycle n >= 3 で、次の両方を満たすとき発散と判定する。
#     (1) 直近 2 値 (c[n-1], c[n]) が **ともに** min(c[1..n-2]) を超える
#     (2) 直近 2 値が **狭義単調減少ではない** (c[n-1] > c[n] が偽)
#
#   (1) は「過去の最良水準へ戻れていない」、(2) は「それでもまだ下降中なら見逃す」という
#   escape 節。両方が要る理由は下記 backtest が示す。
#
# Why 「窓 K サイクルで減っていない」型ではないか (実測較正の結論):
#   窓幅ベースの式は **どの K を選んでも** 収束 run と発散 run を分離できない:
#     - K=2: `3,6,5,3,0` (収束) の `6,5` が「2 サイクル減っていない」に該当し殺される
#     - K>=3: `2,3,6` (発散) は 3 点しかなく窓が埋まる前に終わるため拾えない
#   判別軸は窓幅ではなく「直近窓がまだ下降中か」である。`6→5` は回復中、`3→6` / `7→7` は違う。
#
# backtest (実運用で観測されたトラジェクトリでの較正結果。各列の出所と fixture 本体は
# hooks/tests/review-trend-divergence.test.sh が持つ):
#   | trajectory      | 期待           | 判定       |
#   |-----------------|----------------|------------|
#   | 3,6,5,3,0       | 不発火         | 不発火     |
#   | 10,8,8          | 不発火         | 不発火     |
#   | 12,5,3,2,2      | 不発火         | 不発火     |
#   | 3,7,7,4         | 上限より早く   | cycle 3    |
#   | 2,3,6           | 上限より早く   | cycle 3    |
#   | 10,11,11,13     | 上限より早く   | cycle 3    |
#   | 10,9,8,7,6      | 上限保険へ     | 不発火     |
#
#   escape 節 (2) が AC-3 を非空虚にする — 漸減が続くが 0 に達しない run は本判定をすり抜け、
#   従来どおり max_review_cycles で止まる。escape 節が無いと AC-3 のケースが本判定に吸われ、
#   「上限保険の維持」を検証するテストが空虚になる。
#
# 意図した境界: 最良水準での平坦は発火しない (`>` であって `>=` ではない):
#   `4,4,4,4` のように過去の最良水準と同値で足踏みする run は (1) を満たさず発火しない。
#   `>=` に緩めると 7 本の実トラジェクトリは全て通るが、`12,5,3,2,2,2` のように残り僅かで
#   足踏みしている run が発火するようになる。本判定が存在する動機そのものが「残り数件まで来た
#   ループを予算で殺さない」ことであり、それを早期に殺すのは最も避けたい false positive である。
#   平坦な非収束は「発散判定をすり抜ける遅い非収束」として上限保険が受け止める。
#   一方、最良水準を **超えた** 位置での平坦 (`3,7,7`) は (1)(2) をともに満たし発火する —
#   escape 節は「下降中」だけを見逃す規定であって、平坦を見逃す規定ではない。
#
# Why run 境界に cycle_count を使うか:
#   `.rite/review-results/{pr}-*.json` は /rite:cleanup (マージ後) まで削除されないため、
#   **同一 PR の複数 run が同一ディレクトリに同居する** (打ち切り後に人間が再実行した PR では
#   実際に 3 run 分が同居していた)。glob + timestamp ソートだけで読むと 3 run を 1 本の列として誤読し、人間が
#   `/rite:iterate` を再実行した直後 (cycle_count は 0 にリセット済) でも前 run の件数を見て
#   cycle 2 で即発火する。呼び出し側が渡す cycle_count (= 現 run で完了したレビュー数) で
#   新しい側から切り出すことで run 境界を復元する。
#
# Why 判定不能を「発火しない」に倒すか:
#   fallback ではなく設計。判定できない入力で発火させると健全な run を殺す (AC-1 の否定) が、
#   発火させなければ max_review_cycles が従来どおり backstop として働く (AC-3)。
#   ただし **silent にはしない** — 理由を reason= に載せ、データ異常は WARNING を stderr へ出す。
#
# Exit codes:
#   0  判定完了 (fire / ok / insufficient のいずれか。insufficient も正常系を含む)
#   2  呼び出しエラー (引数不正 / jq 不在)

set -u

pr_number=""
cycle_count=""
results_dir=""

usage() {
  cat <<'EOF'
Usage: review-trend-divergence.sh --pr N --cycle-count N [--results-dir PATH]

Options:
  --pr N            対象 PR 番号 (必須)
  --cycle-count N   現 run で完了したレビュー cycle 数 (必須)。run 境界の復元に使う
  --results-dir P   レビュー結果 JSON のディレクトリ (既定: state-path-resolve.sh 経由で解決)
  -h, --help        Show this help

Exit codes:
  0  判定完了 (fire / ok / insufficient)
  2  呼び出しエラー (引数不正 / jq 不在)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --pr) pr_number="${2:-}"; shift; shift ;;
    --cycle-count) cycle_count="${2:-}"; shift; shift ;;
    --results-dir) results_dir="${2:-}"; shift; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$pr_number" in
  ''|*[!0-9]*) echo "ERROR: --pr は必須で、数値でなければなりません (受領: '${pr_number}')" >&2; usage >&2; exit 2 ;;
esac
case "$cycle_count" in
  ''|*[!0-9]*) echo "ERROR: --cycle-count は必須で、数値でなければなりません (受領: '${cycle_count}')" >&2; usage >&2; exit 2 ;;
esac

# jq 不在を「データ異常」と誤ラベルしない。判定できない理由が環境要因なのかデータ要因なのかを
# 取り違えると、運用者はレビュー結果を疑って空振りする (sibling scripts/review-measured-gate.sh と同型)。
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq が見つかりません (PATH を確認してください)" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 判定不能で終了する共通経路。reason を必ず載せる (silent skip を作らない)。
_undecidable() {
  # $1 = reason, $2 = 人間向け WARNING (空なら WARNING を出さない = 正常系の不足)
  if [ -n "${2:-}" ]; then
    echo "WARNING: $2" >&2
  fi
  echo "[CONTEXT] TREND_DIVERGENCE=insufficient; trend=; cycles=0; reason=$1"
  exit 0
}

# ---- results dir の解決 -------------------------------------------------------
# hooks/review-result-save.sh と同一の解決順 (state-path-resolve.sh → cwd 相対)。
# セッション worktree 内から呼ばれても main checkout と同一パスへ解決される。
if [ -z "$results_dir" ]; then
  _state_root=$(bash "$SCRIPT_DIR/../state-path-resolve.sh" 2>/dev/null) || _state_root=""
  if [ -n "$_state_root" ]; then
    results_dir="$_state_root/.rite/review-results"
  else
    echo "WARNING: state-path-resolve.sh の解決に失敗。cwd 相対の .rite/review-results へフォールバックします" >&2
    results_dir=".rite/review-results"
  fi
fi

if [ ! -d "$results_dir" ]; then
  _undecidable results_dir_missing ""
fi

# ---- 現 run の JSON 群を切り出す ----------------------------------------------
# ファイル名 `{pr}-{timestamp}.json` の lexicographic 昇順 = 時系列昇順
# (`{ts}~{hex}.json` の collision-resolved 版は `.` < `~` により同 ts の後ろへ並ぶ。
#  SoT: references/review-result-schema.md §保存場所)。
# `*.json.corrupt-*` は末尾が .json でないため glob に入らない。
_all_files=()
while IFS= read -r _f; do
  [ -n "$_f" ] && _all_files+=("$_f")
done < <(find "$results_dir" -maxdepth 1 -type f -name "${pr_number}-*.json" 2>/dev/null | LC_ALL=C sort)

_total=${#_all_files[@]}
if [ "$_total" -eq 0 ]; then
  _undecidable no_results_file ""
fi

# cycle_count が示す現 run 分を新しい側から採る。ファイル数が cycle_count に満たない場合は
# トレンドが欠けている (中間サイクルの JSON が無音欠落していた頃に書かれた残骸、または cleanup 後の再開)。
# 欠けた列で判定すると存在しない上昇・下降を読むため、判定せず backstop へ委ねる。
if [ "$_total" -lt "$cycle_count" ]; then
  _undecidable fewer_files_than_cycles \
    "レビュー結果 JSON が cycle_count に不足しています (files=$_total < cycles=$cycle_count)。トレンド判定を行わず max_review_cycles の判定に委ねます"
fi

# `${arr[@]+"${arr[@]}"}` は空配列を set -u 下で展開するための既存慣習 (bash 4.0-4.3 では
# 素の `"${arr[@]}"` が unbound variable で落ちる。floor は references/bash-compat-guard.md が
# 定める bash 4.0+)。cycle_count=0 (現 run の初回 cycle) で必ず空になる経路のため必須。
_run_files=("${_all_files[@]:$((_total - cycle_count)):$cycle_count}")

# ---- 各 cycle の blocking 件数を数える ----------------------------------------
# blocking の定義 (consumer 式) の SoT は references/severity-levels.md §実測必須ゲート:
#   blocking = scope ∈ {current-pr, follow-up} かつ measured != false
#              (verification 欠落 / null = 未判定 = blocking のまま)
# schema 1.0 / 1.0.0 は scope 欠落のため severity ベース default mapping を適用する
# (SoT: references/review-result-schema.md §scope の default mapping)。
#
# schema_version accept list は読取側 3 箇所 (fix.md ステップ 1.2.0 の Priority 0 / 2 / 3) と
# 同期する義務がある — 本 script は 4 番目の読取側として同 SoT に登録済み
# (references/review-result-schema.md §Schema Version)。
_counts=()
for _f in "${_run_files[@]+"${_run_files[@]}"}"; do
  if ! jq empty "$_f" >/dev/null 2>&1; then
    _undecidable json_parse_failure "レビュー結果 JSON が parse できません: $_f"
  fi

  _sv=$(jq -r '.schema_version // ""' "$_f" 2>/dev/null)
  case "$_sv" in
    "1.0.0"|"1.0"|"1.1.0") : ;;
    *) _undecidable schema_version_unknown "未知の schema_version='$_sv': $_f" ;;
  esac

  # ファイル名 prefix と JSON の pr_number の一致 (cross-field invariant #1。
  # SoT: references/review-result-schema.md §Cross-field invariants)。手動 rename でのみ発火しうる。
  _json_pr=$(jq -r '.pr_number // ""' "$_f" 2>/dev/null)
  if [ "$_json_pr" != "$pr_number" ]; then
    _undecidable pr_number_mismatch "ファイル名の PR 番号と JSON の pr_number が不一致 (file=$pr_number json=$_json_pr): $_f"
  fi

  # scope を 3 値 enum へ解決する。schema 1.0 / 1.0.0 のみ severity ベースの default mapping を
  # 適用し、1.1.0 で scope が欠落 / enum 外の値の場合は解決できない finding として数える。
  # **解決できない finding を黙って除外しない** — 除外は blocking 件数の過少計上になり、
  # 「発火しない」方向へ静かに倒れる。他 5 つの異常経路 (parse / schema / pr_number / count /
  # file 不足) がすべて理由付きで判定不能を返すのに、ここだけが理由なしの数値を返すのは非対称。
  # 方向としては安全側 (過少 → 不発火 → backstop) だが、silent であること自体を排除する
  # (sibling の scripts/review-measured-gate.sh も同条件を scope_enum_violation で hard fail させる)。
  _resolved=$(jq -r --arg sv "$_sv" '
    [ .findings[]?
      | . as $f
      | ( if ($f | has("scope")) then $f.scope
          elif $sv == "1.1.0" then null
          else ( if ($f.severity == "CRITICAL" or $f.severity == "HIGH" or $f.severity == "MEDIUM")
                 then "current-pr" else "nit-noted" end )
          end ) as $scope
      | { gated: (($scope == "current-pr" or $scope == "follow-up")
                  and ((($f.verification // {}) | .measured) != false)),
          unresolved: (($scope != "current-pr") and ($scope != "follow-up") and ($scope != "nit-noted")) }
    ]
    | { blocking: (map(select(.gated)) | length), unresolved: (map(select(.unresolved)) | length) }
    | "\(.blocking) \(.unresolved)"
  ' "$_f" 2>/dev/null)

  _n=${_resolved%% *}
  _unresolved=${_resolved##* }
  case "$_n" in
    ''|*[!0-9]*) _undecidable blocking_count_failed "blocking 件数を算出できません: $_f" ;;
  esac
  case "$_unresolved" in
    ''|*[!0-9]*) _undecidable blocking_count_failed "scope 解決結果を算出できません: $_f" ;;
  esac
  if [ "$_unresolved" -gt 0 ]; then
    _undecidable scope_enum_violation \
      "scope が 3 値 enum (current-pr / follow-up / nit-noted) に解決できない finding が ${_unresolved} 件あります (blocking 件数を過少に数えるため判定しません): $_f"
  fi
  _counts+=("$_n")
done

_trend=$(IFS=,; echo "${_counts[*]+"${_counts[*]}"}")
_n_cycles=${#_counts[@]}

# ---- 判定 ---------------------------------------------------------------------
# n >= 3 が必要。1〜2 cycle 目は「過去の最良水準」を定義できないため判定対象外
# (T-06 の安全側判定。データ不足であって発散ではない)。
if [ "$_n_cycles" -lt 3 ]; then
  echo "[CONTEXT] TREND_DIVERGENCE=insufficient; trend=$_trend; cycles=$_n_cycles; reason=need_3_cycles"
  exit 0
fi

# 全 cycle 時点を走査して最初に発散と判定される時点を返す。判定を「呼ばれた時点」ではなく
# トレンド全体の純関数にすることで、resume や helper 導入前の run に対しても同一入力 →
# 同一出力を保つ (AC-5 決定論)。live なループでは前 cycle で既に停止しているため、
# 走査結果は「最新時点だけを見た場合」と一致する。
_fire_at=0
for ((_i = 3; _i <= _n_cycles; _i++)); do
  _prefix_min=${_counts[0]}
  for ((_j = 0; _j < _i - 2; _j++)); do
    if [ "${_counts[_j]}" -lt "$_prefix_min" ]; then _prefix_min=${_counts[_j]}; fi
  done
  _a=${_counts[_i - 2]}
  _b=${_counts[_i - 1]}
  if [ "$_a" -gt "$_prefix_min" ] && [ "$_b" -gt "$_prefix_min" ] && [ ! "$_a" -gt "$_b" ]; then
    _fire_at=$_i
    break
  fi
done

if [ "$_fire_at" -gt 0 ]; then
  echo "[CONTEXT] TREND_DIVERGENCE=fire; trend=$_trend; cycles=$_n_cycles; fire_at=$_fire_at; reason=no_new_minimum_and_not_descending"
else
  echo "[CONTEXT] TREND_DIVERGENCE=ok; trend=$_trend; cycles=$_n_cycles; reason=converging_or_descending"
fi
exit 0
