#!/usr/bin/env bash
# wiki-lint-descriptive-refs.sh
#
# Count Issue/PR number references left in the Wiki's persistent artifacts, for
# wiki-lint ステップ 7.5 (informational). The Wiki is a place for Why prose, not a
# holder of numbers (Comment Best Practices SoT 適用スコープ includes Wiki pages),
# so a body carrying a 3-4 digit hash-number token — with a reference keyword or not —
# is surfaced as a finding.
#
# rationale (why a helper, why the grammar is delegated, scan scope, exclusion measurements):
#   skills/wiki-lint/references/descriptive-refs-rationale.md#exclusions
#
# Symmetry note: this is the ステップ 7.5 counterpart to ステップ 6.0's
# `wiki-lint-skipped-refs.sh` and ステップ 6.2's `wiki-lint-source-refs.sh`. The stdin
# `pages_list` contract is shared with 6.2 only (6.0 discovers its own inputs and reads
# no stdin); the marker block + read_ok enum shape is shared with both. Keep aligned.
#
# Detection — delegated, NOT reimplemented here:
#
#   The grammar lives in `number-reference-check.sh` and only there. This script
#   extracts the scannable body of each target (the exclusions below) and pipes it
#   into `number-reference-check.sh --stdin --label <path>`, then counts the emitted
#   finding lines. A copy of the regex here would drift from the SoT the moment either
#   side changed, and this script's whole job is to measure the Wiki against that SoT.
#
#   Properties of the delegated grammar, spelled out because they define what gets counted:
#     - a bare hash-number token counts; a reference keyword next to it is not required
#     - 1-2 digit and 5+ digit hash-number tokens do NOT count; the SoT scopes the token
#       to 3-4 digits. Wiki prose legitimately carries the short and long forms
#       (upstream tracker ids, enumerated conditions), and they stay
#     - `drift-check-ignore` on a line suppresses that line, in Wiki bodies too. Wiki
#       pages MUST NOT use that marker: it is an escape hatch for the detector's own
#       fixtures, and a page carrying it opts its prose out of the very metric this
#       script exists to report
#
#   `hits` is the number of finding lines the SoT emits for the target, so it stays
#   "matching body lines" (not occurrences, and not a 0/1 per target). The delegate's
#   exit code is 0/1/2 — it is a clean/hit/error signal, never a count, so it must not
#   be used as one.
#
# Exclusions (each is a deliberate blind spot; measurements and trade-offs are recorded
# in the rationale ref above):
#
#   E1 frontmatter `sources:` block only (NOT the whole frontmatter — `description:` /
#      `title:` prose is scanned; ref values are paths that cannot match anyway)
#   E3 code fence
#   E4 inline code span — replaced with `_`, never removed (removing would join a keyword
#      to a following number and manufacture a match)
#   E5 TODO / FIXME lines (forward-tracking numbers are kept by the 廃止判定ルール)
#
#   The `## ソース` section is NOT excluded. Its bullets are display text a reader sees,
#   so a number there is as much a number in the Wiki as one in a paragraph; the link
#   target beside it is where provenance belongs. E2 (the section-scoped skip that used
#   to sit between E1 and E3) is gone, and the numbering is left as-is so the surviving
#   exclusions keep the identifiers the tests and rationale already name.
#
# Scan scope — what is scanned, and what is deliberately left out:
#
#   scanned   `.rite/wiki/pages/**` (stdin `pages_list`) — Why prose, the metric's core
#   scanned   `.rite/wiki/index.md` — auto-discovered by this helper, not required on stdin.
#             Only the per-entry summary is scanned (see `_RITE_INDEX_EMIT_ACTION`): the
#             summary shares its source with the page frontmatter `description`. In OKF
#             either catalog form `/rite:wiki-query` Pass 1 matches keywords against it —
#             table rows are parsed per row (page-column first link, cell escapes
#             restored), the bullet form as before.
#             Either way it is the surface a reader goes to for Why.
#
#   scanned   `.rite/wiki/log.md` — the ingest / lint 台帳, auto-discovered like index.md
#             and not required on stdin. It is a persistent artifact a reader consults,
#             so it carries no exemption; each entry's raw path already holds the
#             provenance that a number in the prose would duplicate. append-only governs
#             how ingest and lint WRITE the log (they append, they never rewrite past
#             entries) — it is not a claim that past entries are exempt from the number
#             rule.
#
#   NOT scanned — a deliberate exclusion, not an unfinished area:
#     `.rite/wiki/raw/**`   レビュー / fix の生ログ = provenance 資料。番号は出典そのもので
#                           あって説明的参照ではない (実測 1,400 ファイル超。review / fix
#                           サイクルごとに増えるため厳密値は持たない)。stdin にこのパスが
#                           現れた場合は下の partial pollution gate が exit 1 で弾く
#                           (取り違えの検出)。委譲先も同じパスを除外するため、仮に到達しても
#                           findings は 0 になる — 二重の保証。
#     `.rite/wiki/SCHEMA.md` スキーマ定義。散文を持たず実測 0 hits のため対象化する利得がない。
#
# Inputs:
#   --branch-strategy {separate_branch|same_branch}  (required)
#   --wiki-branch BRANCH                              (required for separate_branch)
#   --repo-root DIR                                   (default: git rev-parse --show-toplevel)
#   pages_list                                        (stdin; one `.rite/wiki/pages/...` path per line.
#                                                      `.rite/wiki/index.md` and `.rite/wiki/log.md` are
#                                                      accepted too, but need not be passed — the helper
#                                                      discovers both either way.)
#
# stdout contract:
#   ---descriptive_refs_begin---
#   page={path}; hits={n}      # 0..N lines, hits>0 のページのみ
#   ---descriptive_refs_end---
#   descriptive_refs_pages={n}
#   descriptive_refs_read_errors={n}
#   descriptive_refs_skipped_rows={n}   # index.md でサマリーを抽出できなかったエントリ行数
#                                       # (エントリ行数そのものは stdout 契約に出さない —
#                                       #  entries==0 は read_errors へ寄せて既存の enum で表す)
#   [CONTEXT] WIKI_DESCRIPTIVE_REFS={n}
#   descriptive_refs_read_ok={true|io_error}
#
# Who reads what: wiki-lint/SKILL.md ステップ 7.5 / ステップ 9 完了レポートが消費するのは
# `WIKI_DESCRIPTIVE_REFS` (件数) と `descriptive_refs_read_ok` / `descriptive_refs_read_errors` /
# `descriptive_refs_skipped_rows` (未実測・部分欠損の併記条件) の 4 つ。`descriptive_refs_pages` は
# 「hits を持つ対象ファイル数」で index.md を含むが、フィールド名は sibling helper との出力形状
# parity のため据え置く (実体に合わせて改名すると parity が崩れる)。marker block と併せて sibling helper
# (`wiki-lint-source-refs.sh` / `wiki-lint-skipped-refs.sh`) との出力形状 parity のために出しており、
# ステップ 9 の検出詳細一覧には転記されない (informational 指標のため — SKILL.md ステップ 7.5 の
# 「検出結果の記録」節が転記しない旨を明示している)。
#
# `hits` counts matching body lines (not occurrences), preserving the metric the
# inline `grep -c` implementation reported.
#
# Exit codes:
#   0  正常 (読出失敗・検出失敗は descriptive_refs_read_errors が件数、全件失敗時のみ read_ok=io_error)
#   1  fail-fast (placeholder residue / unknown branch_strategy)
#   2  invocation error / 実行環境エラー (引数欠落 / repo-root cd 失敗 / 委譲先不在 /
#      tempfile 確保失敗)。この経路では marker block を 1 行も出さないため、呼出側 (wiki-lint
#      ステップ 7.5) は marker 未受信として `skipped_helper_missing` に畳む
#
# NOTE on shell flags: the per-page read and the per-page detection both capture `$?`
# explicitly (`page_rc` / `hits_rc`) so either failure is isolated as a skipped page and
# counted into `descriptive_refs_read_errors`; a global `set -e` would abort on those rc
# values instead, so it is intentionally not set. `set -o pipefail` is unnecessary because
# no filter stage follows the awk, so awk's rc IS the pipeline's meaningful rc — that is why
# the trailing `grep -c` had to go: it returned 1 on zero matches and made a broken detector
# indistinguishable from a clean page. `set -u` is not set either; every
# variable is assigned before first use, so it would add nothing.

# スクリプト自身の位置は `cd "$REPO_ROOT"` より前に一度だけ確定する。cd の後で
# `$(dirname "${BASH_SOURCE[0]}")` を評価すると、相対パスで起動されたときに解決先が cwd 相対へ
# ずれる。ずれた先にたまたま同名ファイルがあれば別の文法を無言で使うことになる。
_RITE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../control-char-neutralize.sh
source "$_RITE_SCRIPT_DIR/../control-char-neutralize.sh"

# 検出文法の SoT。本ファイルは正規表現のコピーを持たない。委譲先は同ディレクトリに置かれる契約
# （両者とも hooks/scripts/ 配下）。不在は fail-fast する — 委譲先が引けないまま続けると全ページが
# 0 件になり、それが「clean」として通ってしまう。
_RITE_NUMREF_CHECK="$_RITE_SCRIPT_DIR/number-reference-check.sh"
if [ ! -f "$_RITE_NUMREF_CHECK" ]; then
  echo "ERROR: 検出文法の委譲先 '$_RITE_NUMREF_CHECK' が見つかりません (本 helper は文法のコピーを持たないため続行できません)" >&2
  exit 2
fi

branch_strategy=""
wiki_branch=""
REPO_ROOT=""

usage() {
  cat <<'EOF'
Usage: wiki-lint-descriptive-refs.sh --branch-strategy STRATEGY [--wiki-branch BRANCH] [--repo-root DIR]

Reads pages_list from stdin (one `.rite/wiki/pages/...` path per line) and emits the
per-page descriptive-reference hit counts as a marker block plus the
WIKI_DESCRIPTIVE_REFS total and a read_ok enum on stdout.

`.rite/wiki/index.md` (per-entry summary only) and `.rite/wiki/log.md` are scanned as
well and are discovered by this helper, so neither need appear on stdin; passing either
is accepted and not double-counted. `.rite/wiki/raw/**` is deliberately excluded — see
the exclusion rationale in the header comment of this script.

Detection is delegated to number-reference-check.sh; this script holds no copy of the
grammar.

Options:
  --branch-strategy STRATEGY  separate_branch | same_branch (required)
  --wiki-branch BRANCH        Wiki branch ref (required for separate_branch)
  --repo-root DIR             Repository root (default: git rev-parse --show-toplevel)
  -h, --help                  Show this help

Exit codes:
  0  Normal (read failures expressed via descriptive_refs_read_ok)
  1  Fail-fast (placeholder residue / unknown branch_strategy)
  2  Invocation error / environment failure (missing args, repo-root cd, missing
     delegate, tempfile allocation)
EOF
}

# 値付きフラグは `shift; shift` で消費する。値なしフラグが末尾に来た場合 ($#=1)、`shift 2` は
# $# を減らせず set -e 非設定下で無限ループに陥る。1 回目の shift で $# を確実に 0 にし、
# 2 回目は no-op で安全に抜ける (値欠落は下流の必須チェックが exit 2 で検出)。
while [ $# -gt 0 ]; do
  case "$1" in
    --branch-strategy) branch_strategy="${2:-}"; shift; shift ;;
    --wiki-branch) wiki_branch="${2:-}"; shift; shift ;;
    --repo-root) REPO_ROOT="${2:-}"; shift; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# pages_list を stdin から全量読み込む (placeholder residue / partial pollution gate の対象)
pages_list="$(cat)"

if [ -z "$branch_strategy" ]; then
  echo "ERROR: --branch-strategy は必須です" >&2
  usage >&2
  exit 2
fi

# ---- Placeholder residue fail-fast gate -------------------------------------
# (ステップ 6.0 / 6.2 helper の gate と対称。LLM が placeholder を literal substitute
#  せずに helper を呼んだ場合の検出。未 substitute のまま走ると git show / cat が双方
#  空を返し、検出 0 件という silent no-op に倒れる。)
case "$branch_strategy" in
  "{"*"}")
    echo "ERROR: ステップ 7.5 の {branch_strategy} placeholder が literal substitute されていません (値: '$branch_strategy')" >&2
    echo "  LLM は ステップ 1.1 の stdout から会話コンテキストに保持された branch_strategy 値を literal substitute する必要があります" >&2
    echo "[CONTEXT] LINT_PHASE_7_5_PLACEHOLDER_RESIDUE=1; reason=branch_strategy_unsubstituted; value=$branch_strategy" >&2
    exit 1
    ;;
esac
case "$wiki_branch" in
  "{"*"}")
    echo "ERROR: ステップ 7.5 の {wiki_branch} placeholder が literal substitute されていません (値: '$wiki_branch')" >&2
    echo "[CONTEXT] LINT_PHASE_7_5_PLACEHOLDER_RESIDUE=1; reason=wiki_branch_unsubstituted; value=$wiki_branch" >&2
    exit 1
    ;;
esac
# pages_list は空 (Wiki 初期化直後 / 0 件) が legitimate のため、literal 完全一致のみ error
case "$pages_list" in
  "{pages_list}")
    echo "ERROR: ステップ 7.5 の {pages_list} placeholder が literal substitute されていません" >&2
    echo "  LLM は ステップ 2.2 stdout から separator より前の '.rite/wiki/pages/...' 行のみを substitute する必要があります" >&2
    echo "[CONTEXT] LINT_PHASE_7_5_PLACEHOLDER_RESIDUE=1; reason=pages_list_unsubstituted" >&2
    exit 1
    ;;
esac

case "$branch_strategy" in
  separate_branch|same_branch) ;;
  *)
    echo "ERROR: 未知の branch_strategy 値を検出しました: '$branch_strategy' (ステップ 7.5)" >&2
    echo "  対処: rite-config.yml の wiki.branch_strategy を 'separate_branch' または 'same_branch' に設定してください" >&2
    exit 1
    ;;
esac

# separate_branch で --wiki-branch が空のまま進むと `git show ":path"` が ref ではなく
# git index (staging area) を読む別 semantics に陥る (sibling helper と同じ runtime enforcement)。
if [ "$branch_strategy" = "separate_branch" ] && [ -z "$wiki_branch" ]; then
  echo "ERROR: branch_strategy=separate_branch では --wiki-branch が必須です (空のため fail-fast)" >&2
  usage >&2
  exit 2
fi

if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
cd "$REPO_ROOT" || { echo "ERROR: cannot cd to repo root '$REPO_ROOT'" >&2; exit 2; }

_RITE_INDEX_PATH=".rite/wiki/index.md"
_RITE_LOG_PATH=".rite/wiki/log.md"

# partial pollution gate: raw_list 行の混入は検出対象を取り違えるため fail-fast
# (ステップ 2.2 stdout の separator 以降を巻き込んだ substitute の検出)。
# index.md / log.md だけは **完全一致** で許容する。prefix (`.rite/wiki/*`) へ緩めると
# raw_list 行も通ってしまい、gate 本来の目的 (取り違えの検出) を失う。
if [ -n "$pages_list" ]; then
  _polluted=""; _pollute_reason=""
  while IFS= read -r _p; do
    [ -z "$_p" ] && continue
    case "$_p" in
      *..*) _polluted="$_p"; _pollute_reason=traversal; break ;;
      "$_RITE_INDEX_PATH") ;;
      "$_RITE_LOG_PATH") ;;
      .rite/wiki/pages/*) ;;
      *) _polluted="$_p"; break ;;
    esac
  done <<< "$pages_list"
  if [ -n "$_polluted" ]; then
    if [ "$_pollute_reason" = traversal ]; then
      echo "ERROR: ステップ 7.5 の \$pages_list に '..' を含むパスがあります (パストラバーサル遮断)" >&2
    else
      echo "ERROR: ステップ 7.5 の \$pages_list に '.rite/wiki/pages/' prefix も index.md / log.md 完全一致も持たない行が含まれています (partial pollution 検出)" >&2
    fi
    echo "  検出行: $(printf '%s' "$_polluted" | neutralize_ctrl)" >&2
    echo "  対処: ステップ 2.2 stdout から separator より前の '.rite/wiki/pages/...' 行のみを substitute してください" >&2
    exit 1
  fi
fi

# ---- 走査対象の確定: pages_list + index.md + log.md --------------------------
# index.md / log.md は stdin で渡してもよい (上の gate が完全一致で許容する) が、渡されなくても
# helper が自力で拾う。stdin 経由だけに依存すると、LLM の substitute 忘れが「走査しなかった」
# ではなく「指摘が無かった」として通過し、本 helper が塞ごうとしている盲点そのものを
# 再導入するため。自力読出は sibling の `wiki-lint-orphans.sh` が index.md に対して行っているのと同型。
# log.md を自力で拾う必要は index.md より強い: ステップ 2.2 の pages_list は `pages/` 配下しか
# 列挙しないため、stdin にはそもそも現れない。
#
# 存在プローブを read より前に置くのは、**不在と読出失敗を別の結果に落とす**ため。
# `git show` / `cat` はどちらの場合も非ゼロを返すので、読出 rc だけでは区別できない:
#   不在 (Wiki 初期化直後)   → 静かに落とす。read_errors にも走査母数にも数えない
#   存在するが読めない (IO)  → 走査対象に入れ、per-page 失敗として read_errors に計上する
#
# ref が引けない場合は不在ではなく読出失敗として扱い、走査対象に入れて read_errors へ載せる。
# `git cat-file -e` は「ref が無い」と「ref 内に path が無い」をどちらも rc=128 で返すため、
# これを畳むと壊れた wiki ref が「ファイル不在」と同じ静かな縮退になる (pages_list も空だと
# stderr すら出ないまま 0 件が実測済みとして通る)。
_rite_probe_present() {
  # $1 = path。stdout に yes / no を返す。
  if [ "$branch_strategy" = "separate_branch" ]; then
    if git rev-parse --verify -q "${wiki_branch}^{commit}" >/dev/null 2>&1; then
      git cat-file -e "${wiki_branch}:${1}" 2>/dev/null && echo yes || echo no
    else
      echo "WARNING: wiki ブランチ ref '$(printf '%s' "$wiki_branch" | neutralize_ctrl)' を解決できません。${1} の存在を判定できないため読出失敗として計上します" >&2
      echo yes
    fi
  else
    [ -f "$1" ] && echo yes || echo no
  fi
}
index_present=$(_rite_probe_present "$_RITE_INDEX_PATH")
log_present=$(_rite_probe_present "$_RITE_LOG_PATH")

# stdin 由来の index.md / log.md 行を一度落としてから付け直すことで、入力経路によらず
# 「存在プローブを通った 1 行だけ」に正規化する (重複計上の防止も兼ねる)。
# grep を挟まず awk 1 本に畳む。多段パイプでは `$?` が最終段しか見えず、前段の実行失敗と
# 「filter 後に 0 行」が同じ空文字列に潰れる。1 段にすれば空文字列の意味が「対象 0 件」に一意化し、
# rc が走査母数構築の成否を表す唯一の値になる (走査母数が丸ごと消えても read_errors=0 /
# read_ok=true のまま「全件実測済み」を宣言する silent-0 を塞ぐ)。
scan_list=$(printf '%s\n' "$pages_list" \
  | awk -v idx="$_RITE_INDEX_PATH" -v lg="$_RITE_LOG_PATH" 'NF>0 && $0 != idx && $0 != lg'); _scan_rc=$?
_scan_build_failed=0
if [ "$_scan_rc" -ne 0 ]; then
  echo "WARNING: 走査対象リストの構築に失敗しました (rc=$_scan_rc)。io_error として扱います" >&2
  scan_list=""; _scan_build_failed=1
fi
[ "$index_present" = yes ] && scan_list="${scan_list}${scan_list:+$'\n'}${_RITE_INDEX_PATH}"
[ "$log_present" = yes ] && scan_list="${scan_list}${scan_list:+$'\n'}${_RITE_LOG_PATH}"

# ---- 検出本体 ---------------------------------------------------------------

# 本文抽出フィルタ: E1 frontmatter の sources: ブロック / E3 code fence を落とし、
# 残りを stdout に出す (E4 inline code span のマスクと E5 TODO・FIXME の除外は終端アクション側)。
# 順序が契約: fence の toggle は他のどの `next` よりも先に評価する。TODO を含む行で先に
# 打ち切ると fence 状態が desync し、以降の判定が丸ごとずれる。
# `## ソース` 節は落とさない (E2 撤廃)。bullet の表示テキストは読者が読む散文であり、
# 番号の受け皿は隣のリンク先である。
_RITE_BODY_FILTER='
NR==1 && /^---[[:space:]]*$/ { infm=1; next }
infm && /^---[[:space:]]*$/  { infm=0; insrcblk=0; next }
infm && /^sources:[[:space:]]*$/ { insrcblk=1; next }
infm && insrcblk && /^[^[:space:]]/ { insrcblk=0 }
infm && insrcblk            { next }
/^[[:space:]]*```/          { infence = !infence; next }
infence                     { next }
'
# E5 (TODO / FIXME) は本文フィルタではなく終端アクション側で落とす。フィルタ段で next すると
# index.md のエントリ行が END の分母 (entries = エントリ行数) に載らないまま消え、
# 「エントリを 1 件も認識できない = 検出失敗」ガードの判定が実体からずれる。
# E5 行は終端アクション側で落としても skipped には載らない (entries++ の後に next するため) —
# 意図的除外であって抽出失敗ではないので、これは設計どおり。フェンス内行 (E3) も同様に
# entries へ載らないが、そちらはエントリ記法の例示であって実エントリではないため意図どおり。
# 終端アクション: インラインコードスパンを `_` へマスクした残りを **そのまま出力**する。
# 数えるのは委譲先 (number-reference-check.sh) であり、本アクションは検出文法を持たない。
# 「落とす行の規則」と「終端アクション」を 2 変数に分ける。読み分けができるほか、
# mutation test が本文フィルタだけを差し替える seam にもなっている。
_RITE_EMIT_ACTION='/(TODO|FIXME)/ { next } { gsub(/`[^`]*`/, "_"); print }'

# index.md 専用の終端アクション。index.md は散文ページではなくページ一覧のカタログで、
# 検出対象は **エントリ 1 件あたりのサマリー (説明文) だけ**。リンクテキスト・ドメイン・更新日・
# 確信度の各列は対象外にする (ページタイトル由来の番号は本文側の維持判断と同じ扱いのため)。
#
# エントリ行の判定は `](pages/...)` リンクの有無で行い、テーブル行と OKF 箇条書きの両方を **行単位**で
# 受ける。`templates/wiki/index-template.md` と wiki-ingest ステップ 6 はどちらもテーブル形式を生成し、
# 現行の wiki ブランチもテーブルで維持されている。一方、箇条書きテンプレートが配布されていた期間に初期化された bundle の
# index.md は箇条書き `* [title](pages/...) - desc` のまま残り、移行を促す producer も存在しないため、
# 箇条書きは放っておけば消える残滓ではなくテーブルと併存し続ける。どちらか一方専用にすると、
# そうした bundle で検出が無言で 0 件へ倒れる。ファイル単位で形式を判定しないのは、ingest が
# テーブル行を追記しても節の外の旧箇条書き行を削除も移送もしない以上、混在が「起きうる」ではなく
# **そうした bundle が到達する終端状態**だから。なお本リポジトリの wiki ブランチでは箇条書き形式の
# index.md は観測されておらず、両形式対応は外部 bundle に対する防御的サポートである。
# リンクの regex は同じ index.md を読む `wiki-lint-orphans.sh` と同一定義にする (`./pages/` /
# `../pages/` 形式も受ける)。片方だけ狭いと、その形式の index で本 helper だけが無言で 0 件に倒れる。
#
# サマリー列の位置はヘッダー行 (`| ページ | ドメイン | サマリー | 更新日 | 確信度 |`) から決める。
# ヘッダーを検出できないテーブル行は既定列を当てずっぽうで読まずスキップする — 当てると
# 見出し語が drift しただけで別列を黙って走査し、hits が無言で 0 に倒れる。
# 位置固定の列パースは列の増減で全行 skip の silent no-op に倒れるため、ヘッダー由来の位置決めと
# **スキップ行数の stdout 露出** を対にする (`/rite:wiki-query positional-parse-row-count-guard` で参照)。
#
# HTML コメントブロック (`<!-- ... -->`) は行の分類より前に落とす。箇条書きテンプレートが配布されていた期間の
# `templates/wiki/index-template.md` の前文はコメント内に箇条書きの記法例
# `* [ページタイトル](pages/{domain}/{slug}.md) - …` を含み (現行テンプレートでは記法例ごと削除済みだが、
# それ以前に初期化された bundle の index.md には残る)、落とさないと **記法例が実エントリとして
# 数えられる**。そうなると下の検出失敗ガード (`entries == 0 && linkrows > 0`) は `entries` が恒久的に
# 1 以上へ押し上げられて発火せず、それらの index.md では **リンク形式が drift しても無言で 0 件**
# に倒れる (本 helper が塞ごうとしている silent-0 そのもの)。コメント行を数えないことは
# `entries` / `linkrows` の定義 (実カタログのエントリ数 / リンク行数) を回復するものであって、
# ガード専用の特例ではない。同じ `index.md` を読む `hooks/wiki-query-inject.sh` の Pass 1 も
# 記法例を落とす同種の規則を持つ。
# **共有の `_RITE_BODY_FILTER` には足さない** — 足すと全ページ本文の検出規則が変わり、新たな
# 除外規則として独自の rationale と実測が要る。本ファイル固有の事情なので終端アクション側に置く。
#
# **開始は行頭 anchor (`^[[:space:]]*<!--`) で判定する**。素の `/<!--/` にすると、サマリー本文中に
# `<!-- comment -->` を**引用している実エントリ行**まで落ちる。実測: 現行 wiki の index.md には
# 該当行が 2 件あり (`html-comment-breaks-gfm-table-boundary` / `in-doc-tbd-placeholder-without-merge-gate`)、
# anchor 無しだと該当 2 行分 hits が減る（実測時 230 → 228。index.md は ingest ごとに増えるため絶対値はスナップショット）。落としたいのは「行そのものがコメント」であって
# 「コメントに言及している行」ではない。`wiki-query-inject.sh` の Pass 1 も table 行を候補にする
# ようになった際に同じ 2 行を落としたため、同じ行頭 anchor を採用している。
# 終了は anchor を付けない — 箇条書きテンプレートが配布されていた期間に初期化された bundle の
#   index.md 前文のコメントは 2 行目末尾の `-->` で閉じるため。
# 境界: 閉じ `-->` を含む行は行全体を落とす (コメント閉じ後に実エントリが続く 1 行は拾えない)。
# producer (ingest / template) はその形を生成しない。
#
# split の前にリンクスパンをマスクする: リンクテキストに素のパイプを含むページタイトル
# (`grep -c || echo 0` 等) があると列数が合わず実エントリが無言で落ちる。bullet 分岐の match() を
# 壊さないため `s` 自体は書き換えず作業変数 `t` を使う。
#
# 出力の分離: サマリー行は stdout へ、診断 3 値 (skipped / entries / linkrows) は
# `-v diagfile=` の指すファイルへ書く。stdout は委譲先 (number-reference-check.sh) の入力に
# なるため、診断値を混ぜると番号として数えられる。サマリーは配列にバッファし END で出す —
# 未閉鎖ラッチを検出したとき、既に print 済みの行を取り消せないため。
_RITE_INDEX_EMIT_ACTION='
/^[[:space:]]*<!--/ { in_comment=1 }
in_comment { if (index($0, "-->") > 0) in_comment=0; next }
/^[[:space:]]*\|/ && /サマリー/ && sumcol == 0 && $0 !~ /\]\((\.{0,2}\/?pages\/[^)]+)\)/ {
  h = $0
  gsub(/`[^`]*`/, "_", h)
  gsub(/\\\|/, "_", h)
  hn = split(h, hc, "|")
  for (i = 1; i <= hn; i++) if (hc[i] ~ /サマリー/) { sumcol = i; sumncol = hn; break }
  next
}
{
  s = $0
  gsub(/`[^`]*`/, "_", s)
  gsub(/\\\|/, "_", s)
  # linkrows = インラインリンクを持つ行数。entries (リンク先が pages/ の行) の上位集合で、
  # 下の検出失敗ガードが「リンク先だけが想定と食い違う drift」と「そもそもカタログが空」を
  # 区別するために使う。コードスパンは上でマスク済みなので記法例は数えない。
  # 判定材料に散文の箇条書き / テーブル行を含めない理由: 実エントリを持たない手書き index
  # (「- 準備中」等) を検出失敗として誤計上しないため。
  if (s ~ /\]\(/) linkrows++
  if (s !~ /\]\((\.{0,2}\/?pages\/[^)]+)\)/) next
  entries++
  if (s ~ /^[[:space:]]*\|/) {
    t = s
    gsub(/\[[^]]*\]\((\.{0,2}\/?pages\/[^)]+)\)/, "_", t)
    if (sumcol == 0) {
      skipped++
      if (skipped <= 3)
        printf "WARNING: index.md %d 行目: サマリー列ヘッダーを検出できないため行をスキップしました (既定列を当てずっぽうで読むと別列を黙って走査するため)\n", NR > "/dev/stderr"
      next
    }
    fn = split(t, fc, "|")
    if (fn != sumncol) {
      skipped++
      if (skipped <= 3)
        printf "WARNING: index.md %d 行目: テーブルの列数がヘッダーと異なるため行をスキップしました (列数=%d, ヘッダー=%d)\n", NR, fn - 2, sumncol - 2 > "/dev/stderr"
      next
    }
    summary = fc[sumcol]
  } else {
    match(s, /\]\((\.{0,2}\/?pages\/[^)]+)\)/)
    summary = substr(s, RSTART + RLENGTH)
    sub(/^[[:space:]]*(-|—|–)[[:space:]]*/, "", summary)
  }
  if (summary ~ /(TODO|FIXME)/) next
  buf[++nbuf] = summary
}
END {
  # 除外ブロック (HTML コメント / コードフェンス) が閉じないまま EOF に達した = ラッチが立ったまま
  # 以降の全行を落としている。この状態は entries / linkrows / skipped のどれにも現れないため、
  # 検査しないと「実在する参照が丸ごと落ちたのに 0 件 (実測済み)」で通る — 本 helper が塞ぐ対象の
  # silent-0 そのものになる。**判定は `entries == 0` ではなくラッチ変数自身で行う**: エントリを
  # 数え終えた後にラッチが立つ部分欠損では entries >= 1 のため、entries を条件にすると取り逃す。
  # 検出したら entries=0 / linkrows=1 を返して呼出側の既存の検出失敗ガードへ合流させる
  # (診断ファイルのフィールド数を増やさない = arity 契約を維持する)。
  # バッファしたサマリーは stdout へ出さずに捨てる — 一部しか読めていない本文を委譲先へ渡すと
  # その hits が実測済みとして計上されるため。
  if (in_comment || infence) {
    printf "WARNING: index.md: %sが閉じられないままファイル終端に達しました (以降の行が全て走査対象から落ちています)。検出失敗として計上します\n", (in_comment ? "HTML コメント" : "コードフェンス") > "/dev/stderr"
    printf "%d %d %d\n", 0, 0, 1 > diagfile
    exit
  }
  if (skipped > 0) {
    rest = skipped - 3
    if (rest > 0)
      printf "WARNING: index.md のエントリ行 %d 件中 %d 件からサマリーを抽出できませんでした (列位置不明 / 列数不一致。行番号は上の WARNING を参照 — 先頭 3 件のみ表示、残り %d 件は行番号未表示)。欠損は descriptive_refs_skipped_rows として stdout に出ます\n", entries, skipped, rest > "/dev/stderr"
    else
      printf "WARNING: index.md のエントリ行 %d 件中 %d 件からサマリーを抽出できませんでした (列位置不明 / 列数不一致。行番号は上の WARNING を参照)。欠損は descriptive_refs_skipped_rows として stdout に出ます\n", entries, skipped > "/dev/stderr"
  }
  for (i = 1; i <= nbuf; i++) print buf[i]
  printf "%d %d %d\n", skipped+0, entries+0, linkrows+0 > diagfile
}
'

n_descriptive_refs=0
n_pages_with_hits=0
n_read_errors=0
n_index_skipped_rows=0
n_index_entries=-1
n_index_linkrows=0
hit_lines=""

# per-page 読出の stderr 退避先。捨てると `descriptive_refs_read_errors=3` と出ても
# 運用者が「なぜ読めなかったか」を得られない (sibling helper と同じ理由で captures する)。
# signal-specific trap: references/bash-trap-patterns.md#signal-specific-trap-template
page_err=""
# index.md の終端アクションが診断 3 値を書き出す先。stdout は委譲先の入力なので混ぜられない。
diag_file=""
# 本文抽出の結果を置く中間ファイル。段を分けるために要る (rationale は per-page ループ内)。
body_file=""
_rite_wldr_cleanup() {
  [ -n "${page_err:-}" ] && rm -f "$page_err"
  [ -n "${diag_file:-}" ] && rm -f "$diag_file"
  [ -n "${body_file:-}" ] && rm -f "$body_file"
  return 0
}
trap 'rc=$?; _rite_wldr_cleanup; exit $rc' EXIT
trap '_rite_wldr_cleanup; exit 130' INT
trap '_rite_wldr_cleanup; exit 143' TERM
trap '_rite_wldr_cleanup; exit 129' HUP
page_err=$(mktemp "${TMPDIR:-/tmp}/rite-wldr-page-err-XXXXXX" 2>/dev/null) || {
  echo "WARNING: stderr 退避 tempfile の mktemp に失敗しました。ページ読出失敗の詳細は失われます" >&2
  page_err=""
}
# 診断ファイルは fail-loud: 取れないと index.md の検出失敗ガードが判定材料を失い、
# 形式 drift が「0 件 (実測済み)」として通る。WARNING で流さず止める。
diag_file=$(mktemp "${TMPDIR:-/tmp}/rite-wldr-diag-XXXXXX" 2>/dev/null) || {
  echo "ERROR: index.md 診断値の退避 tempfile を mktemp できませんでした (検出失敗ガードが機能しないため続行しません)" >&2
  exit 2
}
body_file=$(mktemp "${TMPDIR:-/tmp}/rite-wldr-body-XXXXXX" 2>/dev/null) || {
  echo "ERROR: 本文抽出結果の中間 tempfile を mktemp できませんでした (検出を委譲できないため続行しません)" >&2
  exit 2
}

while IFS= read -r page; do
  [ -z "$page" ] && continue
  # 読出コマンドの rc で「読めなかった」を判定する。空文字判定に頼ると 0 バイト / 改行のみの
  # 正当な空ページが読出失敗として数えられ、逆に読出失敗が空ページと同じ扱いになる
  # (sibling の wiki-lint-source-refs.sh は rc で切り分けており、その parity を満たすため)。
  if [ "$branch_strategy" = "separate_branch" ]; then
    page_content=$(LC_ALL=C git show "${wiki_branch}:${page}" 2>"${page_err:-/dev/null}"); page_rc=$?
  else
    page_content=$(LC_ALL=C cat "$page" 2>"${page_err:-/dev/null}"); page_rc=$?
  fi
  if [ "$page_rc" -ne 0 ]; then
    n_read_errors=$((n_read_errors + 1))
    page_disp=$(printf '%s' "$page" | neutralize_ctrl)
    echo "WARNING: ページ ${page_disp} の読出に失敗しました (rc=$page_rc, branch_strategy=$branch_strategy)" >&2
    # パスは sed 式へ入れない。定数 sed でインデントし、パスは別行で中和して出す
    # (sibling helper が例外なく定数 sed なのはこのため)。
    [ -n "$page_err" ] && [ -s "$page_err" ] && \
      head -3 "$page_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    continue
  fi
  # 本文抽出 (awk) → 検出 (委譲先) の 2 段。awk は検出文法を持たず、走査対象の行を出すだけ。
  # 除外規則 (_RITE_BODY_FILTER) は index.md にも一貫適用し、終端アクションだけを差し替える。
  # index.md の終端アクションだけは診断 3 値を別ファイル (diagfile) へ書く。
  if [ "$page" = "$_RITE_INDEX_PATH" ]; then _action="$_RITE_INDEX_EMIT_ACTION"; else _action="$_RITE_EMIT_ACTION"; fi
  : > "$diag_file"
  # 2 段を **別コマンドに分ける**。1 本のパイプにすると、その rc を受け取る唯一の場所が
  # command substitution の外側になり PIPESTATUS が届かない (assignment 自身の rc で上書きされる)。
  # 段ごとに rc を持てば「awk が落ちた」と「委譲先が hit を返した」が別の値として残る。
  # `body_file` は下の `> "$body_file"` がリダイレクト設定時点で truncate するため明示 truncate は不要
  # (`diag_file` は awk が index.md 以外では書かないので前 cycle の値が残る — そちらは上で truncate する)。
  printf '%s\n' "$page_content" \
    | awk -v diagfile="$diag_file" "${_RITE_BODY_FILTER}${_action}" > "$body_file"; awk_rc=$?
  findings=""
  check_rc=0
  if [ "$awk_rc" -eq 0 ]; then
    findings=$(bash "$_RITE_NUMREF_CHECK" --stdin --label "$page" --quiet \
      < "$body_file" 2>"${page_err:-/dev/null}"); check_rc=$?
  fi
  hits_rc=0
  if [ "${awk_rc:-1}" -ne 0 ]; then
    page_disp=$(printf '%s' "$page" | neutralize_ctrl)
    echo "WARNING: ページ ${page_disp} の本文抽出 awk が失敗しました (rc=$awk_rc)" >&2
    hits_rc=1
  elif [ "${check_rc:-2}" -ne 0 ] && [ "${check_rc:-2}" -ne 1 ]; then
    # 委譲先の rc は 0=clean / 1=hit / 2=実行エラー。2 だけが失敗で、1 は正常な検出結果。
    page_disp=$(printf '%s' "$page" | neutralize_ctrl)
    echo "WARNING: ページ ${page_disp} の検出委譲が失敗しました (number-reference-check.sh rc=$check_rc)" >&2
    [ -n "$page_err" ] && [ -s "$page_err" ] && \
      head -3 "$page_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    hits_rc=1
  fi
  # hits は委譲先が emit した findings の行数。rc は 0/1 の二値で件数ではないため使えない。
  if [ -z "$findings" ]; then hits=0; else hits=$(printf '%s\n' "$findings" | grep -c .); fi
  # rc と件数は独立に決まるので、両者の矛盾を検出失敗として扱う。委譲先が hit を主張しながら
  # findings を 1 行も出さない状態 (計数経路の破損 — たとえば findings の出力先が変わる) は、
  # ここで捕まえないと「実測済みの 0 件」として read_ok=true のまま完了レポートに載る。
  # 本 helper が塞ぐ対象そのものの silent-0 なので、既存の read_errors 経路へ合流させる。
  if [ "$hits_rc" -eq 0 ] && [ "$check_rc" -eq 1 ] && [ "$hits" -eq 0 ]; then
    page_disp=$(printf '%s' "$page" | neutralize_ctrl)
    echo "WARNING: ページ ${page_disp} の委譲先が hit (rc=1) を返したのに findings が空です (計数経路の破損)" >&2
    hits_rc=1
  fi
  if [ "$page" = "$_RITE_INDEX_PATH" ] && [ "$hits_rc" -eq 0 ]; then
    # index.md の終端アクションは `skipped entries linkrows` の 3 値を diagfile へ書く
    # (skipped = エントリ行と判定したがサマリーを抽出できなかった行数。部分欠損を stdout 契約へ
    # 載せるため — 行単位の値なので、ファイル単位の算術で io_error を決める n_read_errors には
    # 混ぜない。entries = エントリ行と認識できた行数 = 下の検出失敗ガードの分母。
    # linkrows = インラインリンクを持つ行数 = 同ガードが「drift」と「空カタログ」を分ける材料)。
    # arity は個別値の数値検証より **先に** 検査する。フィールド数がずれた状態で下の case だけに
    # 頼ると、未束縛が 0 / -1 へ無言で正規化され entries==0 の検出失敗ガードが沈黙する
    # (終端アクションのフィールドを減らす変異がそれで素通りする)。既存の hits_rc 経路へ倒して
    # read_errors 計上 + continue に合流させる。
    _diag=$(cat "$diag_file" 2>/dev/null)
    _arity=$(printf '%s' "$_diag" | wc -w | tr -d '[:space:]')
    if [ "$_arity" != "3" ]; then
      page_disp=$(printf '%s' "$page" | neutralize_ctrl)
      echo "WARNING: ページ ${page_disp} の検出アクションが 3 値を返しませんでした (フィールド数=${_arity}, 出力='$_diag')" >&2
      hits_rc=1
    else
      read -r _skipped_field _entries_field _linkrows_field <<< "$_diag"
      case "$_skipped_field" in ''|*[!0-9]*) _skipped_field=0 ;; esac
      case "$_entries_field" in ''|*[!0-9]*) _entries_field=-1 ;; esac
      case "$_linkrows_field" in ''|*[!0-9]*) _linkrows_field=0 ;; esac
      n_index_skipped_rows=$_skipped_field
      n_index_entries=$_entries_field
      n_index_linkrows=$_linkrows_field
    fi
  fi
  case "$hits" in ''|*[!0-9]*) [ "$hits_rc" -eq 0 ] && hits_rc=1 ;; esac
  if [ "$hits_rc" -ne 0 ]; then
    # 検出器が機能していないページは「0 件」ではなく読出失敗として計上する。
    n_read_errors=$((n_read_errors + 1))
    continue
  fi
  # index.md を読めたのにエントリ行を 1 件も認識できなかった = 形式が判定不能。
  # skipped は「エントリと認識できた行の抽出失敗」しか数えないため、この状態は
  # どのカウンタにも現れず 0 件が「実測済み」として通ってしまう (実測 230 hits 以上が丸ごと落ちる)。
  # 発火条件は index.md 自身の内容で決める — リンク形状の行 (linkrows) はあるのに、その
  # リンク先が pages/ と認識できない (entries==0) 状態だけを検出失敗とする。リンク行が
  # 1 行も無い index は「まだ登録が無いカタログ」であって drift ではないので静かに落とす。
  # **stdin (pages_list) を条件にしてはならない** — ステップ 2.2 は pages_list が空でも
  # 本ステップを実行する契約 (wiki 初期化直後 / git ls-tree 失敗時に index.md の指摘を
  # 落とさないため) であり、そこを条件にするとガードが必要な経路でだけ無効化される。
  if [ "$page" = "$_RITE_INDEX_PATH" ] && [ "${n_index_entries:--1}" -eq 0 ] 2>/dev/null \
     && [ "${n_index_linkrows:-0}" -gt 0 ] 2>/dev/null; then
    page_disp=$(printf '%s' "$page" | neutralize_ctrl)
    echo "WARNING: ページ ${page_disp} からエントリ行を 1 件も認識できませんでした (リンク形式 / 本文フィルタの想定と不一致、または除外ブロックの未閉鎖。原因は直上の WARNING を参照)。検出失敗として計上します" >&2
    n_read_errors=$((n_read_errors + 1))
    continue
  fi
  if [ "$hits" -gt 0 ]; then
    n_descriptive_refs=$((n_descriptive_refs + hits))
    n_pages_with_hits=$((n_pages_with_hits + 1))
    hit_lines="${hit_lines}page=$(printf '%s' "$page" | neutralize_ctrl); hits=${hits}"$'\n'
    echo "WikiDescriptiveRef: page=$(printf '%s' "${page#.rite/wiki/}" | neutralize_ctrl), hits=${hits}" >&2
  fi
done <<< "$scan_list"

# read_ok: ページが 1 件以上あるのに全件読めなかった場合のみ io_error。
# 一部読めなかった場合は残りの集計が有効なため true を維持するが、件数を `descriptive_refs_read_errors`
# として stdout に出す — WARNING は stderr にしか出ず、完了レポートの併記条件が read_ok だけだと
# 部分欠損した集計が注記なしで「実測済み」として載るため (sibling の all_source_refs_read_errors と同型)。
n_pages_total=$(printf '%s\n' "$scan_list" | awk 'NF>0 {n++} END {print n+0}')
# 走査母数の構築自体が失敗していた場合は「対象 0 件」ではなく io_error へ寄せる
if [ "${_scan_build_failed:-0}" -eq 1 ]; then
  n_pages_total=0
  [ "$n_read_errors" -eq 0 ] && n_read_errors=1
fi
case "$n_pages_total" in
  ''|*[!0-9]*)
    # ページ数を数える awk まで落ちている = 実行環境の異常。0 に倒すと io_error 分岐が
    # 到達不能になり「0 件」が実測済みとして通るため、io_error 側へ寄せる。
    echo "WARNING: 走査対象リストの件数計算に失敗しました (値: '$n_pages_total')。io_error として扱います" >&2
    n_pages_total=0
    [ "$n_read_errors" -eq 0 ] && n_read_errors=1
    ;;
esac
descriptive_refs_read_ok="true"
if { [ "$n_pages_total" -gt 0 ] && [ "$n_read_errors" -eq "$n_pages_total" ]; } || { [ "$n_pages_total" -eq 0 ] && [ "$n_read_errors" -gt 0 ]; }; then
  descriptive_refs_read_ok="io_error"
  echo "WARNING: 走査対象の全 ${n_pages_total} ファイルを読み出せない、または検出できませんでした (branch_strategy=$branch_strategy)" >&2
  echo "  影響: 番号参照 0 件は実体を反映していません (informational 指標のため lint は継続します)" >&2
  echo "  対処: wiki branch ref / ページパスの整合、および index.md のエントリ記法が想定どおりかを確認してください" >&2
elif [ "$n_read_errors" -gt 0 ]; then
  echo "WARNING: ${n_read_errors}/${n_pages_total} ファイルを読み出せない、または検出できず集計から除外しました" >&2
  echo "  対処: wiki branch ref / ページパスの整合、および index.md のエントリ記法が想定どおりかを確認してください" >&2
fi

echo "---descriptive_refs_begin---"
[ -n "$hit_lines" ] && printf '%s' "$hit_lines"
echo "---descriptive_refs_end---"
echo "descriptive_refs_pages=$n_pages_with_hits"
echo "descriptive_refs_read_errors=$n_read_errors"
echo "descriptive_refs_skipped_rows=$n_index_skipped_rows"
echo "[CONTEXT] WIKI_DESCRIPTIVE_REFS=$n_descriptive_refs"
echo "descriptive_refs_read_ok=$descriptive_refs_read_ok"
