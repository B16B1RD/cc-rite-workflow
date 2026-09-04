#!/bin/bash
# rite workflow - review⇄fix ループの収束トレンド判定 (発散検出)
#
# Responsibility: 永続レビュー結果 JSON 群から「現在の run の per-cycle blocking 件数」を
# 復元し、そのトレンドが発散しているかを決定論的に判定する。/rite:iterate のサーキット
# ブレーカーは cycle 数上限だけでなく本判定でも発火する。
#
# Called from:
#   - skills/iterate/SKILL.md ステップ 1 (発火条件チェック内、backstop 判定の直後)。
#     上限未到達でも本 helper が fire を返せばブレーカーへ分岐する。
#
# Usage:
#   bash review-trend-divergence.sh --pr N --cycle-count N [--since BASENAME] [--results-dir PATH]
#
# 出力 (stdout, 1 行):
#   [CONTEXT] TREND_DIVERGENCE=fire|ok|insufficient; trend=<c1,c2,...>; cycles=N; lost=N; reason=<...>
#   fire のときのみ `fire_at=<cycle>` が付く。`lost=` は cycle_count に対して失われた結果の件数
#   (保存失敗 / review 中断)。判定を降ろす経路 (_undecidable) は `trend=` と `cycles=0` を出すが
#   `lost=` は持たない。
# WARNING / 診断は stderr。
#
# Why 件数上限ではなくトレンドか:
#   cycle 数上限は努力と無駄を区別できない。健全に収束中のループも残り数件のところで予算切れに
#   なり、発散しているループも上限まで燃やしてしまう (どちらも実測されている — 下記 backtest の
#   トラジェクトリがその記録)。「品質を予算で縛らない・無駄は排除する」(CLAUDE.md プロジェクト
#   原則) に従い、切るべきは発散 (無駄) であって収束に向かう実サイクルではない。
#   max_review_cycles は backstop として存置する (既定 15 では 16 cycle 以上を要する収束中の run にも届く。15 は従来の 5 cycle 上限が収束中の run を停止した実測に基づく暫定値で、実運用データで再評価する)。
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
# Why run 境界に run-start pin を使うか (cycle_count では復元できない):
#   `.rite/review-results/{pr}-*.json` は /rite:cleanup (マージ後) まで削除されないため、
#   **同一 PR の複数 run が同一ディレクトリに同居する** (打ち切り後に人間が再実行した PR では
#   実際に 3 run 分が同居していた)。glob + timestamp ソートだけで読むと 3 run を 1 本の列として誤読し、人間が
#   `/rite:iterate` を再実行した直後でも前 run の件数を見て cycle 2 で即発火する。
#
#   当初は cycle_count (= 現 run で完了したレビュー数) で新しい側から切り出していたが、これは
#   「現 run のファイル数 == cycle_count」を暗黙の前提にしており、その前提は 2 経路で破れる:
#     (a) 保存失敗 — review-result-save.sh は D-04 非ブロッキング契約により保存できなくても
#         exit 0 で返る。ループは cycle_count を進めたまま継続するため 1 件欠ける。
#     (b) review 途中での中断 — iterate ステップ 1 は review を invoke する **前** に cycle_count を
#         +1 する。中断すると JSON は書かれず counter だけ進み、resume は phase=review を
#         そのまま routing するため skew がその run の間ずっと解消しない。
#   どちらの場合も「末尾 cycle_count 件」は前 run のファイルを現 run の先頭として取り込む。
#   前 run の末尾は収束途中の低い件数であることが多く、それが prefix_min に入ると健全な run が
#   発散判定で殺される — 本判定が最も避けたい false positive (AC-1 の否定) がまさに起きる。
#
#   そこで run 境界は cycle_count ではなく **run 開始時点の pin** で復元する。
#   `.rite/state/review-run-since-{pr}.txt` には、その run の 1 cycle 目に入る直前に存在していた
#   最新の結果ファイル basename が入る (iterate ステップ 0.6 が cycle_count == 0 のときに書く)。
#   本 script はそれより新しいファイルだけを現 run とみなす。pin ファイルが無ければ全件を
#   1 本の列として読む (pin 導入前の run / 手動実行に対する後方互換)。
#   cycle_count は run 境界の**決定**には使わないが、**過剰取り込みの検出**には使う。正しい境界の
#   下では `実在ファイル数 == cycle_count` が構造的に成立するため、実在数が cycle_count を超える
#   のは他 run が混ざっている証拠 → `run_boundary_unresolved` で判定を降ろす。**ただし pin が
#   無いとき、または `cycle_count == 0` のときに限る** — pin が**現 run の開始時に更新されていれば**
#   「pin より新しいファイル」は run 開始後の生成分だけなので混入は起きない (pin 更新はステップ 0.6 の
#   `cur_cc == 0` 経路だけで、それを保証するステップ 5.0.1 は非ブロッキングのため構造的保証ではない —
#   だから `cycle_count == 0` で stale pin を捕まえる)。この条件下では超過は counter 側の skew (INC 失敗 / Stop hook 再注入による counter
#   迂回) を意味するにすぎない。そこで判定を降ろすと skew が解消しないまま run 終了まで発散検出が
#   無効化され、不足側で降ろしていた旧実装と同型の失敗を向きだけ変えて再導入することになる。
#   よって **判定を降ろすのは「境界が未知」= pin 不在、または `cycle_count == 0`（現 run でまだ 1 度も
#   レビューが完了していないのに結果がある = stale pin）のときだけ**で、それ以外の過不足はどちらも
#   診断 (WARNING / marker の `lost=`) に留めて実在する列で判定する。
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
since=""

usage() {
  cat <<'EOF'
Usage: review-trend-divergence.sh --pr N --cycle-count N [--since BASENAME] [--results-dir PATH]

Options:
  --pr N            対象 PR 番号 (必須)
  --cycle-count N   現 run で完了したレビュー cycle 数 (必須)。run 境界の**決定**には使わないが、
                    pin 不在または本値が 0 のとき、実在数がこれを**超える**なら境界未知として判定を降ろす。
                    不足側は失われた件数を WARNING と marker の lost= に載せて判定を続行する
  --since BASENAME  run 開始点の pin。この basename より新しい結果ファイルだけを現 run とみなす。
                    空文字 / 省略時は全件を 1 本の列として読む (pin 導入前の run への後方互換)
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
    --since) since="${2:-}"; shift; shift ;;
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

# 診断へ埋め込む JSON 由来の値 (schema_version / pr_number / ファイルパス) を中和する。
# hooks/ の全診断 emission site に中和を課す control-char-neutralize.sh の SoT に従う
# (sibling の review-nonblocking-record.sh / review-result-save.sh と同型)。呼び出し側
# (iterate ステップ 1) は本 script の stderr を capture せず素通しさせるため、ここで中和しないと
# 制御文字がそのまま端末へ届く。helper 不在時は素通しへ縮退するが、縮退自体を WARNING で告知する
# (無言の縮退は「中和している」という前提だけを残して実効を失うため)。
# shellcheck source=../control-char-neutralize.sh
source "$SCRIPT_DIR/../control-char-neutralize.sh" 2>/dev/null || true
if ! command -v neutralize_ctrl >/dev/null 2>&1; then
  echo "WARNING: control-char-neutralize.sh を読み込めませんでした。診断に埋め込む JSON 由来の値の制御文字が素通しします" >&2
  neutralize_ctrl() { cat; }
fi

# 診断へ埋め込む 1 行用の中和。`--keep-newline` を付けない default モードは改行も `?` 化するため、
# 埋め込んだ値が WARNING を複数行へ割って別の診断行に見せかけることを防ぐ。
_nz() { printf '%s' "${1:-}" | neutralize_ctrl; }

# jq の診断本文を捨てない。`jq empty` を通過した妥当な JSON でも filter がエラーを返す入力
# (findings[] に object でない要素が混ざる等) があり、そのとき reason だけではファイル名しか
# 分からず原因の特定に filter の再構成が要る。sibling の scripts/review-measured-gate.sh と
# hooks/flow-state.sh は同目的で診断退避を持つ (本 script の header が手本として名指ししている)。
# 先行宣言 (cleanup が参照する)。実体の割当は trap 武装後の mktemp が行う。
_diag=""

# signal 別 trap。1 行形 (`trap '...' EXIT INT TERM HUP`) は INT/TERM/HUP の action に `exit` を
# 持たないため bash が signal を consume し、スクリプトが**継続実行して exit 0 で終わる**。
# Ctrl-C は foreground プロセスグループ全体へ届くので in-flight の jq が殺され、valid な入力に
# 対して pr_number_mismatch / blocking_count_failed という**偽の reason** を出しながら rc=0 で
# 返る (呼び出し側の `trend_rc -ne 0` guard も素通りする)。非ゼロ終了なら iterate ステップ 1 の
# 既存分岐が helper_unavailable として backstop へ縮退させる。
# canonical: references/bash-trap-patterns.md#signal-specific-trap-template
_cleanup() { rm -f "${_diag:-}"; }
trap 'rc=$?; _cleanup; exit $rc' EXIT
trap '_cleanup; exit 130' INT
trap '_cleanup; exit 143' TERM
trap '_cleanup; exit 129' HUP

if ! _diag=$(mktemp "${TMPDIR:-/tmp}/rite-trend-diag-XXXXXX" 2>/dev/null); then
  _diag=""
  echo "WARNING: 診断用 tempfile を作成できませんでした。判定不能時の jq stderr は表示されません" >&2
fi

# jq の stderr を吐き出す。抑止の除去であって fallback ではない。
_emit_diag() {
  [ -n "${_diag:-}" ] && [ -s "$_diag" ] || return 0
  head -5 "$_diag" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
}

# 判定不能で終了する共通経路。reason を必ず載せる (silent skip を作らない)。
_undecidable() {
  # $1 = reason, $2 = 人間向け WARNING (空なら WARNING を出さない = 正常系の不足)
  if [ -n "${2:-}" ]; then
    echo "WARNING: $2" >&2
    # 診断は WARNING の**直後**に出す。本プロジェクトは「WARNING 行 + 後続インデント行」を
    # 1 単位として読む継続行規約を採るため、先に出すと直前の別 WARNING (例: `_lost > 0`) の
    # 継続行位置に着地して原因が誤帰属する。sibling の scripts/review-measured-gate.sh の
    # `_fail` と hooks/review-result-save.sh も同順。
    _emit_diag
  fi
  echo "[CONTEXT] TREND_DIVERGENCE=insufficient; trend=; cycles=0; reason=$1"
  exit 0
}

# ---- results dir の解決 -------------------------------------------------------
# hooks/review-result-save.sh と同一の解決順 (state-path-resolve.sh → cwd 相対)。
# セッション worktree 内から呼ばれても main checkout と同一パスへ解決される。
if [ -z "$results_dir" ]; then
  # `2>/dev/null` は付けない — resolver は git 内外どちらでも rc=0 / 非空を返す設計なので、
  # ここに落ちるのは helper 自体を実行できない場合 (プラグイン破損 / 版 skew) だけであり、
  # その唯一の原因を示す診断を抑止してはならない (iterate ステップ 0.6 / 1 と同じ論拠)。
  _state_root=$(bash "$SCRIPT_DIR/../state-path-resolve.sh") || _state_root=""
  if [ -n "$_state_root" ]; then
    results_dir="$_state_root/.rite/review-results"
  else
    echo "WARNING: state-path-resolve.sh の解決に失敗。cwd 相対の .rite/review-results へフォールバックします" >&2
    results_dir=".rite/review-results"
  fi
fi

# データ不足の 2 経路 (results dir 不在 / 結果ファイル 0 件) は、cycle_count == 0 のときだけ
# 正常系 (まだ 1 度もレビューしていない) なので無音でよい。cycle_count >= 1 で成立するなら
# 「N 回レビュー済みなのに結果が 1 件も無い」= results dir の path skew か保存の全面失敗であり、
# 発散検出が丸ごと死んでいることを意味する。無音だと本 script が正常系の need_3_cycles を返した
# ときと呼び出し側の marker が完全に一致し、機構の全面不作動が観測不能になる。
_data_missing_warn() {
  # $1 = 人間向け WARNING 本文。cycle_count == 0 のときは空を返して無音に倒す。
  if [ "$cycle_count" -ge 1 ] 2>/dev/null; then printf '%s' "$1"; fi
}

if [ ! -d "$results_dir" ]; then
  _undecidable results_dir_missing \
    "$(_data_missing_warn "レビュー結果ディレクトリが存在しません ($(_nz "$results_dir"))。cycle_count=$cycle_count まで進んでいますが結果を 1 件も読めません (results dir の path skew / 保存の全面失敗 / review 中断のいずれか)。トレンド判定を行わず max_review_cycles の判定に委ねます")"
fi

# ---- 現 run の JSON 群を切り出す ----------------------------------------------
# ファイル名 `{pr}-{timestamp}.json` の lexicographic 昇順 = 時系列昇順
# (`{ts}~{hex}.json` の collision-resolved 版は `.` < `~` により同 ts の後ろへ並ぶ。
#  SoT: references/review-result-schema.md §保存場所)。
# `*.json.corrupt-*` は末尾が .json でないため glob に入らない。
_all_files=()
while IFS= read -r _f; do
  [ -n "$_f" ] && _all_files+=("$_f")
# `2>/dev/null` は付けない。dir を読めない (permission 等) とき find は 0 件を返し、後続の
# `no_results_file` WARNING は原因を「path skew / 保存の全面失敗 / review 中断」の 3 つに限定して
# 名指しする — 実際の原因はそのどれでもないため運用者が空振りする。正常系の find は stderr 0 バイト。
done < <(find "$results_dir" -maxdepth 1 -type f -name "${pr_number}-*.json" | LC_ALL=C sort)

_total=${#_all_files[@]}
if [ "$_total" -eq 0 ]; then
  _undecidable no_results_file \
    "$(_data_missing_warn "レビュー結果 JSON が 1 件もありません ($(_nz "$results_dir")/${pr_number}-*.json)。cycle_count=$cycle_count まで進んでいますが結果を読めません (results dir の path skew / 保存の全面失敗 / review 中断のいずれか)。トレンド判定を行わず max_review_cycles の判定に委ねます")"
fi

# ---- run 開始点 pin で現 run のファイルを選ぶ ----------------------------------
# pin より **厳密に新しい** basename だけを現 run とみなす (pin 自身は前 run の最終ファイル)。
# 比較は basename の LC_ALL=C 昇順 = 時系列昇順 (ファイル名 `{pr}-{timestamp}[~{hex}].json`)。
# pin が空 = 未 pin (導入前の run / 手動実行) → 全件を 1 本の列として読む (後方互換)。
# `${arr[@]+"${arr[@]}"}` は空配列を set -u 下で展開するための既存慣習 (bash 4.0-4.3 では
# 素の `"${arr[@]}"` が unbound variable で落ちる。floor は references/bash-compat-guard.md が
# 定める bash 4.0+)。現 run の初回 cycle では必ず空になる経路のため必須。
_run_files=()
if [ -z "$since" ]; then
  _run_files=("${_all_files[@]+"${_all_files[@]}"}")
else
  for _f in "${_all_files[@]+"${_all_files[@]}"}"; do
    _bn=$(basename "$_f")
    # `[[ > ]]` はロケール依存の照合順を使うため、LC_ALL=C 昇順 sort と一致させるには使えない。
    # sort に 2 行渡して pin が先に来る (= _bn の方が新しい) ことを確認する。
    if [ "$(printf '%s\n%s\n' "$_bn" "$since" | LC_ALL=C sort | head -1)" = "$since" ] && [ "$_bn" != "$since" ]; then
      _run_files+=("$_f")
    fi
  done
fi

_run_total=${#_run_files[@]}
# pin フィルタ後 0 件は「dir に該当 JSON が無い」(上の no_results_file) とは別条件。同じ reason に
# 畳むと、再実行直後の 1 cycle 目 (pin = 直近ファイル、現 run はまだ 0 件) という**全再実行が必ず
# 通る正常系**が「結果を読めない = 発散検出の全面不作動」と読まれる。
if [ "$_run_total" -eq 0 ]; then
  _undecidable no_file_after_pin \
    "$(_data_missing_warn "run 開始点 pin ($(_nz "$since")) より新しいレビュー結果 JSON が 1 件もありません (dir 内の全 ${_total} 件はすべて前 run 以前)。トレンド判定を行わず max_review_cycles の判定に委ねます")"
fi

# **過剰取り込みの invariant**: 正しい run 境界の下では `_run_total == cycle_count` が構造的に
# 成立する (iterate ステップ 1 は increment 前の counter を渡すため、cycle N の入場時点で
# counter = 現 run の完了レビュー数 = 保存済みファイル数)。実在数が cycle_count を**超える**のは
# 現 run の列に他 run のファイルが混ざっている証拠であり、その混入は前 run 末尾の低い件数を
# prefix_min に持ち込んで健全な run を発散判定で殺す — 本判定が最も避けたい false positive
# (AC-1 の否定) そのもの。pin が書けなかった / pin 導入前の run では since が空で全件を読むため、
# 複数 run が同居していればここで必ず捕まる (cycle_count=0 で `0 < _run_total` も同式が拾う)。
# 不足側 (`<`) は run 内の欠落にすぎず判定を降ろさない — 降ろすと中断 1 回でその run の発散検出が
# 恒久的に無効化される (旧 fewer_files_than_cycles の失敗)。**方向で扱いを分けるのが要点**。
# **境界が未知のときだけ**判定を降ろす（pin 不在、または `cycle_count == 0` = stale pin）。pin があれば「pin より新しいファイル」は run 開始後に
# 生成された分だけなので、他 run の混入は構造的に起きない — 超過は counter が実在数に
# 追いつかない skew (INC 失敗 / Stop hook 再注入による counter 迂回) を意味するにすぎず、
# そこで判定を降ろすと **その run の残り全 cycle で発散検出が恒久的に無効化される**
# (files と counter は以後同量ずつ増えるので skew は run 終了まで解消しない)。これは不足側で
# 判定を降ろしていた旧実装 (`fewer_files_than_cycles`) と同型の失敗で、向きを変えただけの
# 再導入になる。pin 有りの超過は不足側と同じく診断だけ残して実在列で判定を続行する。
# `cycle_count == 0` も pin 不在と同じく境界未知として扱う。counter skew (INC 失敗 / Stop hook
# 再注入) は **少なくとも 1 回 review が完了して初めて成立する**ため、`cycle_count == 0` かつ
# 実在数 > 0 かつ pin 非空という組は skew と重ならず、**stale pin（前 run の pin が残った状態）
# だけ**を指す。この状態で判定を続行すると、新 run の cycle 1 の頭で前 run の列を読んで発火する。
# pin 更新はステップ 0.6 の `cur_cc == 0` 経路だけで、それを保証するステップ 5.0.1 は非ブロッキング
# なので「pin があれば現 run のもの」は構造的保証にならない — その穴をここで塞ぐ。
if { [ -z "$since" ] || [ "$cycle_count" -eq 0 ]; } && [ "$_run_total" -gt "$cycle_count" ] 2>/dev/null; then
  _undecidable run_boundary_unresolved \
    "現 run の境界を確定できません (files=$_run_total > cycles=$cycle_count)。run 開始点 pin が無いか、現 run でまだ 1 度もレビューが完了していないのに結果が存在します (前 run の pin が残っている可能性)。誤発火を避けるためトレンド判定を行わず max_review_cycles の判定に委ねます"
fi

# 不足側は判定を降ろさず、失われた件数を診断として残す。件数は stdout の marker にも載せる —
# stderr の WARNING だけだと、呼び出し側 (iterate) も停止通知を読む人間も「この列には穴がある」
# ことを知らないまま、合成された推移を実測として受け取る (欠落は verdict を反転させうる)。
_lost=0
if [ "$_run_total" -lt "$cycle_count" ] 2>/dev/null; then
  _lost=$((cycle_count - _run_total))
  echo "WARNING: 現 run のレビュー結果 JSON が cycle_count に不足しています (files=$_run_total < cycles=$cycle_count)。結果の保存失敗か review の中断で ${cycle_count} 件中 ${_lost} 件の結果が失われています。実在する ${_run_total} 件の列でトレンド判定を続行します" >&2
elif [ "$_run_total" -gt "$cycle_count" ] 2>/dev/null; then
  # pin 有りでの超過。counter 側が遅れている (INC 失敗 / Stop hook 再注入で counter を迂回) のが
  # 通常の原因で、その場合 pin は現 run のものなので列も現 run のもの。ただし pin 自体が stale な
  # 経路 (iterate ステップ 0.6 の `write-failed-pin-retained`) もここに来るため、保証は断定しない。
  echo "WARNING: 現 run のレビュー結果 JSON が cycle_count を超えています (files=$_run_total > cycles=$cycle_count)。cycle counter の increment 失敗、または Stop hook の再注入で counter を経由せずレビューが進んだ可能性があります。pin が現 run のものであれば run 境界は保たれているため実在する ${_run_total} 件の列でトレンド判定を続行します (pin が stale な場合は前 run の結果が混ざります — iterate の RUN_SINCE marker で切り分けてください)" >&2
fi

# ---- 各 cycle の blocking 件数を数える ----------------------------------------
# 本 script が数えるのは **producer 側 blocking 集合** (SoT: references/severity-levels.md
# §実測必須ゲート の producer 式) であり、severity では絞らない:
#   blocking = scope ∈ {current-pr, follow-up} かつ measured != false
#              (verification 欠落 / null = 未判定 = blocking のまま)
# 同節の consumer 式 (fix の致命性仕分け: 実測あり × CRITICAL/HIGH × gated) とは別軸で、
# ここでそれを適用してはならない — 収束トレンドは reviewer が出した指摘の推移を見るものであり、
# fix が何を修正対象にしたかの推移ではない。
# schema 1.0 / 1.0.0 は scope 欠落のため severity ベース default mapping を適用する
# (SoT: references/review-result-schema.md §scope の default mapping)。
#
# schema_version accept list は他の読取側と同期する義務がある — 本 script は 4 番目の読取側として
# 同 SoT に登録済み (references/review-result-schema.md §Schema Version)。既存 3 サイトは
# scripts/review-source-resolve.sh (Priority 0 / 2) と skills/fix/SKILL.md (Priority 3)。
_counts=()
for _f in "${_run_files[@]+"${_run_files[@]}"}"; do
  if ! jq empty "$_f" >/dev/null 2>"${_diag:-/dev/null}"; then
    _undecidable json_parse_failure "レビュー結果 JSON が parse できません: $(_nz "$_f")"
  fi

  # rc も stderr も捨てない (同一ループの `jq empty` / 集計 filter と同形)。空値からの推測だけで
  # schema_version_unknown へ落とすと、jq が出した唯一の原因文が消える — header が「jq の診断本文を
  # 捨てない」と宣言している当の原則に反する。
  if ! _sv=$(jq -r '.schema_version // ""' "$_f" 2>"${_diag:-/dev/null}"); then
    _undecidable json_parse_failure "schema_version を読み出せません: $(_nz "$_f")"
  fi
  case "$_sv" in
    "1.0.0"|"1.0"|"1.1.0") : ;;
    *) _undecidable schema_version_unknown "未知の schema_version='$(_nz "$_sv")': $(_nz "$_f")" ;;
  esac

  # ファイル名 prefix と JSON の pr_number の一致 (cross-field invariant #1。
  # SoT: references/review-result-schema.md §Cross-field invariants)。手動 rename でのみ発火しうる。
  if ! _json_pr=$(jq -r '.pr_number // ""' "$_f" 2>"${_diag:-/dev/null}"); then
    _undecidable json_parse_failure "pr_number を読み出せません: $(_nz "$_f")"
  fi
  if [ "$_json_pr" != "$pr_number" ]; then
    _undecidable pr_number_mismatch "ファイル名の PR 番号と JSON の pr_number が不一致 (file=$pr_number json=$(_nz "$_json_pr")): $(_nz "$_f")"
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
  ' "$_f" 2>"${_diag:-/dev/null}")

  _n=${_resolved%% *}
  _unresolved=${_resolved##* }
  # `_n` と `_unresolved` は同一 jq 出力からの split なので、jq が落ちれば両方空になる。
  # 片方だけ検査すれば足りる (`_unresolved` 側にも同じ case を置くと到達不能な分岐になる)。
  case "$_n" in
    ''|*[!0-9]*) _undecidable blocking_count_failed "blocking 件数を算出できません: $(_nz "$_f")" ;;
  esac
  if [ "$_unresolved" -gt 0 ]; then
    _undecidable scope_enum_violation \
      "scope が 3 値 enum (current-pr / follow-up / nit-noted) に解決できない finding が ${_unresolved} 件あります (blocking 件数を過少に数えるため判定しません): $(_nz "$_f")"
  fi
  _counts+=("$_n")
done

_trend=$(IFS=,; echo "${_counts[*]+"${_counts[*]}"}")
_n_cycles=${#_counts[@]}

# ---- 判定 ---------------------------------------------------------------------
# n >= 3 が必要。1〜2 cycle 目は「過去の最良水準」を定義できないため判定対象外
# (T-06 の安全側判定。データ不足であって発散ではない)。
if [ "$_n_cycles" -lt 3 ]; then
  echo "[CONTEXT] TREND_DIVERGENCE=insufficient; trend=$_trend; cycles=$_n_cycles; lost=$_lost; reason=need_3_cycles"
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
  echo "[CONTEXT] TREND_DIVERGENCE=fire; trend=$_trend; cycles=$_n_cycles; lost=$_lost; fire_at=$_fire_at; reason=no_new_minimum_and_not_descending"
else
  echo "[CONTEXT] TREND_DIVERGENCE=ok; trend=$_trend; cycles=$_n_cycles; lost=$_lost; reason=converging_or_descending"
fi
exit 0
