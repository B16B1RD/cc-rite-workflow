#!/usr/bin/env bash
# wiki-lint-descriptive-refs.sh
#
# Count descriptive Issue/PR number references left in Wiki page bodies, for
# wiki-lint ステップ 7.5 (informational). The Wiki is a place for Why prose, not a
# holder of numbers (Comment Best Practices SoT 適用スコープ includes Wiki pages),
# so a body carrying 「PR #N は…」「詳細は #N」「(refs #N)」 is surfaced as a finding.
#
# rationale (why a helper, why normalization, why not `\b`, exclusion measurements):
#   skills/wiki-lint/references/descriptive-refs-rationale.md#exclusions
#
# Symmetry note: this is the ステップ 7.5 counterpart to ステップ 6.0's
# `wiki-lint-skipped-refs.sh` and ステップ 6.2's `wiki-lint-source-refs.sh`. The stdin
# `pages_list` contract is shared with 6.2 only (6.0 discovers its own inputs and reads
# no stdin); the marker block + read_ok enum shape is shared with both. Keep aligned.
#
# Detection (2 normalized rules, NOT a list of surface forms):
#
#   R1: a reference keyword immediately preceding a number
#       (^|[^A-Za-z])([Ii]ssues?|[Pp][Rr]s?|[Rr]efs?|[Ss]ee|…) *#[0-9]+([^0-9]|$)
#       The keyword list is a vocabulary, not a form enumeration. Adding a surface
#       form means adding a word here, never a new branch.
#       Case is symmetric; the left `(^|[^A-Za-z])` boundary keeps `prefs #12` /
#       `hrefs #3` from matching on their tail.
#
#   R2: the two keyword-less Japanese descriptive constructs
#       #[0-9]+ ?で(別途)?対応  および  詳細は ?#[0-9]+
#       These carry no reference keyword, so they cannot fold into R1.
#
#   Bare `#N` with no keyword is deliberately NOT detected (see rationale ref above).
#
# Word boundary:
#   Number matches end with `([^0-9]|$)` so a match can never stop mid-number
#   (`#204` inside `#2047`). The explicit boundary pins that as a contract so a later
#   narrowing of the number pattern cannot silently reintroduce prefix collision.
#   MUST keep this a character class rather than `\b`: the regex is handed to awk via
#   `-v re=`, and gawk reads `\b` as backspace — it never matches and never errors, so
#   a `\b` here makes the detector silently report 0 for every page.
#
# Exclusions (each is a deliberate blind spot; measurements and trade-offs are recorded
# in the rationale ref above):
#
#   E1 frontmatter `sources:` block only (NOT the whole frontmatter — `description:` /
#      `title:` prose is scanned; ref values are paths that cannot match anyway)
#   E2 `## ソース` section, scoped heading → next `##` heading (NOT to EOF), with heading
#      suffix tolerance (`## ソース（追記分）`)
#   E3 code fence
#   E4 inline code span — replaced with `_`, never removed (removing would join a keyword
#      to a following number and manufacture a match)
#   E5 TODO / FIXME lines (forward-tracking numbers are kept by the 廃止判定ルール)
#
# Scan scope — what is scanned, and what is deliberately left out:
#
#   scanned   `.rite/wiki/pages/**` (stdin `pages_list`) — Why prose, the metric's core
#   scanned   `.rite/wiki/index.md` — auto-discovered by this helper, not required on stdin.
#             Only the per-entry summary is scanned (see `_RITE_INDEX_COUNT_ACTION`): the
#             summary shares its source with the page frontmatter `description`, and
#             `/rite:wiki-query` Pass 1 matches keywords against it, so it is part of the
#             surface a reader goes to for Why.
#
#   NOT scanned — each is a deliberate exclusion, not an unfinished area:
#     `.rite/wiki/log.md`   append-only ingest / lint 台帳。SoT が commit message と
#                           PR description を「番号の正しい受け皿」として対象外にしているのと
#                           同じ性質で、散文化すると監査証跡の追跡可能性を失う (実測 987 hits)。
#     `.rite/wiki/raw/**`   レビュー / fix の生ログ = provenance 資料。番号は出典そのもので
#                           あって説明的参照ではない (実測 1458 ファイル)。
#     `.rite/wiki/SCHEMA.md` スキーマ定義。散文を持たず実測 0 hits のため対象化する利得がない。
#
# Inputs:
#   --branch-strategy {separate_branch|same_branch}  (required)
#   --wiki-branch BRANCH                              (required for separate_branch)
#   --repo-root DIR                                   (default: git rev-parse --show-toplevel)
#   pages_list                                        (stdin; one `.rite/wiki/pages/...` path per line.
#                                                      `.rite/wiki/index.md` is accepted too, but need not
#                                                      be passed — the helper discovers it either way.)
#
# stdout contract:
#   ---descriptive_refs_begin---
#   page={path}; hits={n}      # 0..N lines, hits>0 のページのみ
#   ---descriptive_refs_end---
#   descriptive_refs_pages={n}
#   descriptive_refs_read_errors={n}
#   descriptive_refs_skipped_rows={n}   # index.md でサマリーを抽出できなかったエントリ行数
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
#   2  invocation error (引数欠落 / repo-root cd 失敗)
#
# NOTE on shell flags: the per-page read and the per-page detection both capture `$?`
# explicitly (`page_rc` / `hits_rc`) so either failure is isolated as a skipped page and
# counted into `descriptive_refs_read_errors`; a global `set -e` would abort on those rc
# values instead, so it is intentionally not set. `set -o pipefail` is unnecessary because
# no filter stage follows the awk, so awk's rc IS the pipeline's meaningful rc — that is why
# the trailing `grep -c` had to go: it returned 1 on zero matches and made a broken detector
# indistinguishable from a clean page. `set -u` is not set either; every
# variable is assigned before first use, so it would add nothing.

# shellcheck source=../control-char-neutralize.sh
source "$(dirname "${BASH_SOURCE[0]}")/../control-char-neutralize.sh"

branch_strategy=""
wiki_branch=""
REPO_ROOT=""

usage() {
  cat <<'EOF'
Usage: wiki-lint-descriptive-refs.sh --branch-strategy STRATEGY [--wiki-branch BRANCH] [--repo-root DIR]

Reads pages_list from stdin (one `.rite/wiki/pages/...` path per line) and emits the
per-page descriptive-reference hit counts as a marker block plus the
WIKI_DESCRIPTIVE_REFS total and a read_ok enum on stdout.

`.rite/wiki/index.md` is scanned as well (per-entry summary only) and is discovered by
this helper, so it need not appear on stdin; passing it is accepted and not double-counted.
`.rite/wiki/log.md` and `.rite/wiki/raw/**` are deliberately excluded — see the exclusion
rationale in the header comment of this script.

Options:
  --branch-strategy STRATEGY  separate_branch | same_branch (required)
  --wiki-branch BRANCH        Wiki branch ref (required for separate_branch)
  --repo-root DIR             Repository root (default: git rev-parse --show-toplevel)
  -h, --help                  Show this help

Exit codes:
  0  Normal (read failures expressed via descriptive_refs_read_ok)
  1  Fail-fast (placeholder residue / unknown branch_strategy)
  2  Invocation error
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

# partial pollution gate: raw_list 行の混入は検出対象を取り違えるため fail-fast
# (ステップ 2.2 stdout の separator 以降を巻き込んだ substitute の検出)。
# index.md だけは **完全一致** で許容する。prefix (`.rite/wiki/*`) へ緩めると raw_list 行も
# 通ってしまい、gate 本来の目的 (取り違えの検出) を失う。
if [ -n "$pages_list" ]; then
  _polluted=""; _pollute_reason=""
  while IFS= read -r _p; do
    [ -z "$_p" ] && continue
    case "$_p" in
      *..*) _polluted="$_p"; _pollute_reason=traversal; break ;;
      "$_RITE_INDEX_PATH") ;;
      .rite/wiki/pages/*) ;;
      *) _polluted="$_p"; break ;;
    esac
  done <<< "$pages_list"
  if [ -n "$_polluted" ]; then
    if [ "$_pollute_reason" = traversal ]; then
      echo "ERROR: ステップ 7.5 の \$pages_list に '..' を含むパスがあります (パストラバーサル遮断)" >&2
    else
      echo "ERROR: ステップ 7.5 の \$pages_list に '.rite/wiki/pages/' prefix も index.md 完全一致も持たない行が含まれています (partial pollution 検出)" >&2
    fi
    echo "  検出行: $(printf '%s' "$_polluted" | neutralize_ctrl)" >&2
    echo "  対処: ステップ 2.2 stdout から separator より前の '.rite/wiki/pages/...' 行のみを substitute してください" >&2
    exit 1
  fi
fi

# ---- 走査対象の確定: pages_list + index.md ----------------------------------
# index.md は stdin で渡してもよい (上の gate が完全一致で許容する) が、渡されなくても helper が
# 自力で拾う。stdin 経由だけに依存すると、LLM の substitute 忘れが「index.md を走査しなかった」
# ではなく「index.md に指摘が無かった」として通過し、本 helper が塞ごうとしている盲点そのものを
# 再導入するため。自力読出は sibling の `wiki-lint-orphans.sh` が index.md に対して行っているのと同型。
#
# 存在プローブを read より前に置くのは、**不在と読出失敗を別の結果に落とす**ため。
# `git show` / `cat` はどちらの場合も非ゼロを返すので、読出 rc だけでは区別できない:
#   不在 (Wiki 初期化直後)   → 静かに落とす。read_errors にも走査母数にも数えない
#   存在するが読めない (IO)  → 走査対象に入れ、per-page 失敗として read_errors に計上する
if [ "$branch_strategy" = "separate_branch" ]; then
  git cat-file -e "${wiki_branch}:${_RITE_INDEX_PATH}" 2>/dev/null && index_present=yes || index_present=no
else
  [ -f "$_RITE_INDEX_PATH" ] && index_present=yes || index_present=no
fi

# stdin 由来の index.md 行を一度落としてから付け直すことで、入力経路によらず
# 「存在プローブを通った 1 行だけ」に正規化する (重複計上の防止も兼ねる)。
scan_list=$(printf '%s\n' "$pages_list" | grep -vxF "$_RITE_INDEX_PATH" | awk 'NF>0')
[ "$index_present" = yes ] && scan_list="${scan_list}${scan_list:+$'\n'}${_RITE_INDEX_PATH}"

# ---- 検出本体 ---------------------------------------------------------------

# 本文抽出フィルタ: E1 frontmatter の sources: ブロック / E3 code fence / E2 `## ソース` 節 / E5 TODO・FIXME を落とし、
# E4 inline code span を `_` へマスクした残りを stdout に出す。
# 順序が契約: fence の toggle は他のどの `next` よりも先に評価する。TODO を含む行や
# `## ソース` 行で先に打ち切ると fence 状態が desync し、以降の判定が丸ごとずれる。
# `## ソース` は **節スコープ**で落とす (見出しから次の `##` 見出しの手前まで)。ファイル末尾まで
# 打ち切ると、wiki-ingest が `## ソース` の後ろに追記する `## 補強:` 等の本文が丸ごと盲点になる
# (実測: 現行の接尾辞許容見出しに対して 7 ページ / 28 hits。接尾辞許容前は 13 ページ / 81 hits)。
# 節の判定は fence より後に置く — フェンス内に引用された
# `## ソース` で節スコープが誤発火しないようにするため。
# 見出しは接尾辞を許容する: wiki-ingest は `## ソース（追記分）` / `## ソース（追記分 N）` を
# 生成する (実測 13 箇所。template にもコードにも定義がない LLM 生成形)。厳密一致にすると
# これらが「節の開始」として認識されないまま「次の見出し」としては認識され、直前の節の除外を
# 打ち切ったうえで provenance ラベルを走査対象に戻す (実測 53 hits の誤検出)。全角・半角の
# 両括弧を受ける。
_RITE_BODY_FILTER='
NR==1 && /^---[[:space:]]*$/ { infm=1; next }
infm && /^---[[:space:]]*$/  { infm=0; insrcblk=0; next }
infm && /^sources:[[:space:]]*$/ { insrcblk=1; next }
infm && insrcblk && /^[^[:space:]]/ { insrcblk=0 }
infm && insrcblk            { next }
/^[[:space:]]*```/          { infence = !infence; next }
infence                     { next }
/^##[[:space:]]+ソース([[:space:]]*$|[（(])/ { insrc=1; next }
insrc && /^##[[:space:]]/   { insrc=0 }
insrc                       { next }
/(TODO|FIXME)/              { next }
'
# 終端アクション: インラインコードスパンを `_` へマスクしてから検出 regex で数える。
# 「落とす行の規則」と「終端アクション」を 2 変数に分ける。読み分けができるほか、
# mutation test (TC-16) が本文フィルタだけを差し替える seam にもなっている。
_RITE_COUNT_ACTION='{ gsub(/`[^`]*`/, "_"); if ($0 ~ re) n++ } END { print n+0 }'

# index.md 専用の終端アクション。index.md は散文ページではなくページ一覧のカタログで、
# 検出対象は **エントリ 1 件あたりのサマリー (説明文) だけ**。リンクテキスト・ドメイン・更新日・
# 確信度の各列は対象外にする (ページタイトル由来の番号は本文側の維持判断と同じ扱いのため)。
#
# エントリ行の判定は `](pages/` リンクの有無で行い、テーブル行と OKF 箇条書きの両方を **行単位**で
# 受ける。現行の wiki ブランチは 5 列テーブルだが、`templates/wiki/index-template.md` と wiki-ingest
# ステップ 6 が生成するのは箇条書き `* [title](pages/...) - desc` であり、テーブル専用にすると
# 形式移行の時点で検出が無言で 0 件へ倒れる。ファイル単位で形式を判定しないのは移行途中の混在に耐えるため。
#
# サマリー列の位置はヘッダー行 (`| ページ | ドメイン | サマリー | 更新日 | 確信度 |`) から決める。
# 位置固定の列パースは列の増減で全行 skip の silent no-op に倒れるため、ヘッダー由来の位置決めと
# **スキップ行数の stdout 露出** を対にする (`/rite:wiki-query positional-parse-row-count-guard` で参照)。
# ガードを「全行 skip」条件にしないのは、`templates/wiki/index-template.md` の前文が箇条書きの記法例を
# 含みエントリ行として 1 件 parse されるため、全滅条件では構造的に発火しないことによる。
#
# split の前にリンクスパンをマスクする: リンクテキストに素のパイプを含むページタイトル
# (`grep -c || echo 0` 等) があると列数が合わず実エントリが無言で落ちる。bullet 分岐の match() を
# 壊さないため `s` 自体は書き換えず作業変数 `t` を使う。
_RITE_INDEX_COUNT_ACTION='
/^[[:space:]]*\|/ && /サマリー/ && sumcol == 0 {
  hn = split($0, hc, "|")
  for (i = 1; i <= hn; i++) if (hc[i] ~ /サマリー/) { sumcol = i; sumncol = hn; break }
  next
}
{
  s = $0
  gsub(/`[^`]*`/, "_", s)
  gsub(/\\\|/, "_", s)
  if (s !~ /\]\(pages\//) next
  entries++
  if (s ~ /^[[:space:]]*\|/) {
    t = s
    gsub(/\[[^]]*\]\(pages\/[^)]*\)/, "_", t)
    fn = split(t, fc, "|")
    col = (sumcol > 0 ? sumcol : 4)
    want = (sumncol > 0 ? sumncol : 0)
    if (fn <= col || (want > 0 && fn != want)) {
      skipped++
      if (skipped <= 3)
        printf "WARNING: index.md %d 行目: テーブルの列数が想定と異なるため行をスキップしました (列数=%d, 期待=%s)\n", NR, fn - 2, (want > 0 ? want - 2 : "不明 — サマリー列ヘッダーを検出できず既定列 " col - 1 " を仮定") > "/dev/stderr"
      next
    }
    summary = fc[col]
  } else {
    if (match(s, /\]\(pages\/[^)]*\)/) == 0) { skipped++; next }
    summary = substr(s, RSTART + RLENGTH)
    sub(/^[[:space:]]*(-|—|–)[[:space:]]*/, "", summary)
  }
  parsed++
  if (summary ~ re) n++
}
END {
  if (skipped > 0)
    printf "WARNING: index.md のエントリ行 %d 件中 %d 件からサマリーを抽出できませんでした (形式変更の可能性)。欠損は descriptive_refs_skipped_rows として stdout に出ます\n", entries, skipped > "/dev/stderr"
  print n+0, skipped+0
}
'

# R1 (keyword vocabulary + number) と R2 (keyword-less な日本語 2 構文) の 2 規則。
# 語境界は `\b` ではなく `([^0-9]|$)` — gawk の `\b` はバックスペース扱いで never-match。
# 左側にも文字クラス境界 `(^|[^A-Za-z])` を置く: 右境界だけだと `prefs #12` / `hrefs #3` の語尾が
# `refs` に一致して誤検出する。語彙は大小文字を対称に受ける (`issue #12` / `pr #3` を取りこぼさない)。
_RITE_DESCRIPTIVE_RE='(^|[^A-Za-z])([Ii]ssues?|[Pp][Rr]s?|[Rr]efs?|[Ss]ee|[Rr]elated to|[Cc]loses|[Ff]ixes|[Rr]esolves) *#[0-9]+([^0-9]|$)|#[0-9]+ ?で(別途)?対応|詳細は ?#[0-9]+([^0-9]|$)'

n_descriptive_refs=0
n_pages_with_hits=0
n_read_errors=0
n_index_skipped_rows=0
hit_lines=""

# per-page 読出の stderr 退避先。捨てると `descriptive_refs_read_errors=3` と出ても
# 運用者が「なぜ読めなかったか」を得られない (sibling helper と同じ理由で captures する)。
# signal-specific trap: references/bash-trap-patterns.md#signal-specific-trap-template
page_err=""
_rite_wldr_cleanup() { [ -n "${page_err:-}" ] && rm -f "$page_err"; return 0; }
trap 'rc=$?; _rite_wldr_cleanup; exit $rc' EXIT
trap '_rite_wldr_cleanup; exit 130' INT
trap '_rite_wldr_cleanup; exit 143' TERM
trap '_rite_wldr_cleanup; exit 129' HUP
page_err=$(mktemp "${TMPDIR:-/tmp}/rite-wldr-page-err-XXXXXX" 2>/dev/null) || {
  echo "WARNING: stderr 退避 tempfile の mktemp に失敗しました。ページ読出失敗の詳細は失われます" >&2
  page_err=""
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
  # 本文抽出と計数を 1 つの awk に閉じる。終端に `grep -c` を置くと no-match の rc=1 と
  # awk の異常終了が区別できず、検出器が壊れても「0 件」として read_ok=true で通っていた
  # (検出器そのものの破損だけが未実測ゲートをすり抜ける唯一の穴だった)。
  # 除外規則 (_RITE_BODY_FILTER) は index.md にも一貫適用し、終端アクションだけを差し替える。
  # index.md の終端アクションは `hits skipped` の 2 値を返す (skipped = エントリ行と判定したが
  # サマリーを抽出できなかった行数。部分欠損を stdout 契約へ載せるため — 行単位の値なので
  # ファイル単位の算術で io_error を決める n_read_errors には混ぜない)。
  if [ "$page" = "$_RITE_INDEX_PATH" ]; then _action="$_RITE_INDEX_COUNT_ACTION"; else _action="$_RITE_COUNT_ACTION"; fi
  hits=$(printf '%s\n' "$page_content" | awk -v re="$_RITE_DESCRIPTIVE_RE" "${_RITE_BODY_FILTER}${_action}"); awk_rc=$?; hits_rc=$awk_rc
  if [ "$page" = "$_RITE_INDEX_PATH" ]; then
    _skipped_field=${hits#* }; hits=${hits%% *}
    case "$_skipped_field" in ''|*[!0-9]*) _skipped_field=0 ;; esac
    n_index_skipped_rows=$_skipped_field
  fi
  case "$hits" in ''|*[!0-9]*) [ "$hits_rc" -eq 0 ] && hits_rc=1 ;; esac
  if [ "$hits_rc" -ne 0 ]; then
    # 検出器が機能していないページは「0 件」ではなく読出失敗として計上する。
    page_disp=$(printf '%s' "$page" | neutralize_ctrl)
    echo "WARNING: ページ ${page_disp} の検出 awk が失敗しました (rc=$hits_rc, awk_rc=$awk_rc, 出力='$hits')" >&2
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
  echo "WARNING: 走査対象の全 ${n_pages_total} ファイルを読み出せませんでした (branch_strategy=$branch_strategy)" >&2
  echo "  影響: 説明的番号参照 0 件は実体を反映していません (informational 指標のため lint は継続します)" >&2
  echo "  対処: wiki branch ref / ページパスの整合を確認してください" >&2
elif [ "$n_read_errors" -gt 0 ]; then
  echo "WARNING: ${n_read_errors}/${n_pages_total} ファイルを読み出せず集計から除外しました" >&2
fi

echo "---descriptive_refs_begin---"
[ -n "$hit_lines" ] && printf '%s' "$hit_lines"
echo "---descriptive_refs_end---"
echo "descriptive_refs_pages=$n_pages_with_hits"
echo "descriptive_refs_read_errors=$n_read_errors"
echo "descriptive_refs_skipped_rows=$n_index_skipped_rows"
echo "[CONTEXT] WIKI_DESCRIPTIVE_REFS=$n_descriptive_refs"
echo "descriptive_refs_read_ok=$descriptive_refs_read_ok"
