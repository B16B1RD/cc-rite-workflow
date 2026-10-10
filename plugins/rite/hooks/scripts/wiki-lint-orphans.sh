#!/usr/bin/env bash
# wiki-lint-orphans.sh
#
# Detect orphan Wiki pages for wiki/lint.md ステップ 5 (孤児ページ検出). Read
# index.md per the branch strategy, extract the registered page links, diff
# them against pages_list (stdin), and emit the orphan set inside a marker
# block alongside an orphan_check_ok enum + [CONTEXT] sentinel.
#
# Why a helper:
#   The inline implementation of index.md read + lint.md ステップ 5 was a 2-step manual
#   flow (index.md read → LLM computes the set difference). A lint run that
#   never executes it can still claim "orphans=0" — the count is unverifiable
#   from the transcript. Delegating the whole category (index.md read included)
#   makes the count machine-produced: the LLM only transcribes the emitted
#   numbers (same structural guarantee as wiki-lint-skipped-refs.sh /
#   wiki-lint-source-refs.sh for ステップ 6.0 / 6.2).
#
# Inputs:
#   --branch-strategy {separate_branch|same_branch}  (required)
#   --wiki-branch BRANCH                              (required for separate_branch)
#   --repo-root DIR                                   (default: git rev-parse --show-toplevel)
#   stdin: pages_list (改行区切り、`.rite/wiki/pages/...` 形式。空なら 0 件)
#
# stdout contract (LLM holds these in conversation context; lint.md ステップ 5 の
# issues[] append と ステップ 9 完了レポートが参照する):
#   n_orphans={n}
#   ---orphans_begin---
#   {page}                                 # 0..N lines (`.rite/wiki/pages/...` 形式)
#   ---orphans_end---
#   orphan_check_ok={true|index_unreadable|index_empty}
#   n_index_defects={n}
#   ---index_defects_begin---
#   outside_section: {page}                # `## ページ一覧` 節の外にある登録行
#   duplicate: {page} ({k} 行)             # 同じページを指す登録行が 2 行以上 (節の内外を問わない)
#   ---index_defects_end---
#   n_orphan_category={n_orphans + n_index_defects}   # lint の `orphans` 件数として転記する合算値
#   [CONTEXT] WIKI_LINT_ORPHANS={n}
#   [CONTEXT] WIKI_LINT_INDEX_DEFECTS={n}
#
# orphan_check_ok enum:
#   true              通常実行 (n_orphans は信頼可能)
#   index_unreadable  index.md 読出失敗 (ENOENT / blob not found / IO error)。
#                     n_orphans=0 のまま skip (旧 lint.md の index.md 事前読出
#                     ステップの index_read_ok=false 経路を本 helper に内包)
#   index_empty       index.md は読めたがページ一覧テーブルから登録ページを
#                     抽出できなかった。全ページ orphan 誤検出を防ぐため skip
#                     (旧 lint.md ステップ 5 の orphan_check_ok=false 経路)
#
# Exit codes:
#   0  正常 (index 読出失敗 / 抽出 0 件の skip 含む — 非ブロッキング契約)
#   1  fail-fast (placeholder residue / unknown branch_strategy)
#   2  invocation error (引数欠落 / repo-root cd 失敗)
#
# NOTE on shell flags: sibling helpers と同じく per-command rc 管理のため
# `set -e` は意図的に設定しない。

# shellcheck source=../control-char-neutralize.sh
source "$(dirname "${BASH_SOURCE[0]}")/../control-char-neutralize.sh"
branch_strategy=""
wiki_branch=""
REPO_ROOT=""

usage() {
  cat <<'EOF'
Usage: wiki-lint-orphans.sh --branch-strategy STRATEGY [--wiki-branch BRANCH] [--repo-root DIR] < pages_list

Reads pages_list from stdin, reads index.md per the branch strategy, and
emits the orphan set marker block + orphan_check_ok enum + [CONTEXT]
sentinel on stdout.

Options:
  --branch-strategy STRATEGY  separate_branch | same_branch (required)
  --wiki-branch BRANCH        Wiki branch ref (required for separate_branch)
  --repo-root DIR             Repository root (default: git rev-parse --show-toplevel)
  -h, --help                  Show this help

Exit codes:
  0  Normal (incl. index-unreadable / index-empty skip)
  1  Fail-fast (placeholder residue / unknown branch_strategy)
  2  Invocation error
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --branch-strategy) branch_strategy="${2:-}"; shift; shift ;;
    --wiki-branch) wiki_branch="${2:-}"; shift; shift ;;
    --repo-root) REPO_ROOT="${2:-}"; shift; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$branch_strategy" ]; then
  echo "ERROR: --branch-strategy は必須です" >&2
  usage >&2
  exit 2
fi

# ---- Placeholder residue fail-fast gate -------------------------------------
case "$branch_strategy" in
  "{"*"}")
    echo "ERROR: ステップ 5 の {branch_strategy} placeholder が literal substitute されていません (値: '$branch_strategy')" >&2
    echo "  LLM は ステップ 1.1 の stdout から会話コンテキストに保持された branch_strategy 値を literal substitute する必要があります" >&2
    echo "[CONTEXT] LINT_PHASE_5_PLACEHOLDER_RESIDUE=1; reason=branch_strategy_unsubstituted; value=$branch_strategy" >&2
    exit 1
    ;;
esac
case "$wiki_branch" in
  "{"*"}")
    echo "ERROR: ステップ 5 の {wiki_branch} placeholder が literal substitute されていません (値: '$wiki_branch')" >&2
    exit 1
    ;;
esac

case "$branch_strategy" in
  separate_branch|same_branch) ;;
  *)
    echo "ERROR: 未知の branch_strategy 値を検出しました: '$branch_strategy' (ステップ 5)" >&2
    echo "  対処: rite-config.yml の wiki.branch_strategy を 'separate_branch' または 'same_branch' に設定してください" >&2
    exit 1
    ;;
esac

if [ "$branch_strategy" = "separate_branch" ] && [ -z "$wiki_branch" ]; then
  echo "ERROR: branch_strategy=separate_branch では --wiki-branch が必須です (空のため fail-fast)" >&2
  usage >&2
  exit 2
fi

if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
cd "$REPO_ROOT" || { echo "ERROR: cannot cd to repo root '$REPO_ROOT'" >&2; exit 2; }

# pages_list は index.md 読出より先に stdin から確定させる (read loop が index 読出の
# リダイレクトと干渉しないよう、stdin 消費を 1 箇所に固定する)。
pages_list=$(cat)

# skip 経路 3 行 + sentinel の共通 emit (index_unreadable / index_empty)
_emit_skipped() {
  local reason="$1"
  echo "n_orphans=0"
  echo "---orphans_begin---"
  echo "---orphans_end---"
  echo "orphan_check_ok=$reason"
  echo "n_index_defects=0"
  echo "---index_defects_begin---"
  echo "---index_defects_end---"
  echo "n_orphan_category=0"
  echo "[CONTEXT] WIKI_LINT_ORPHANS=0"
  echo "[CONTEXT] WIKI_LINT_INDEX_DEFECTS=0"
}

# ---- index.md 読出 (旧 lint.md の index.md 事前読出ステップを内包) ------------
# LC_ALL=C で locale 固定 (localize された diagnostic による stderr pattern 不一致を予防 —
# sibling helpers と同じ規約)。読出失敗は legitimate absence / IO error を区別せず
# index_unreadable に一本化する (index_read_ok=false の単一経路に集約する。
# 孤児検出は index.md が無ければ全ページ orphan 誤検出になるため、いずれの失敗でも skip が正解)。
index_err=$(mktemp "${TMPDIR:-/tmp}/rite-wiki-lint-orphans-err-XXXXXX" 2>/dev/null) || {
  echo "WARNING: stderr 退避 tempfile (index_err) の mktemp に失敗しました。index.md 読出の詳細エラー情報は失われます" >&2
  echo "  対処: /tmp の容量 / permission / inode 枯渇を確認してください" >&2
  index_err=""
}
_cleanup() { [ -n "${index_err:-}" ] && rm -f "$index_err"; return 0; }
trap 'rc=$?; _cleanup; exit $rc' EXIT
trap '_cleanup; exit 130' INT
trap '_cleanup; exit 143' TERM
trap '_cleanup; exit 129' HUP

case "$branch_strategy" in
  separate_branch)
    if index_content=$(LC_ALL=C git show "${wiki_branch}:.rite/wiki/index.md" 2>"${index_err:-/dev/null}"); then
      [ -n "$index_err" ] && [ -s "$index_err" ] && head -3 "$index_err" | neutralize_ctrl --keep-newline | sed 's/^/  WARNING(git hint): /' >&2
    else
      echo "WARNING: index.md を wiki ブランチから読み出せません" >&2
      [ -n "$index_err" ] && [ -s "$index_err" ] && head -3 "$index_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
      echo "  影響: 孤児ページ検出 (ステップ 5) を skip します（非ブロッキング）" >&2
      _emit_skipped "index_unreadable"
      exit 0
    fi
    ;;
  same_branch)
    if index_content=$(LC_ALL=C cat .rite/wiki/index.md 2>"${index_err:-/dev/null}"); then
      [ -n "$index_err" ] && [ -s "$index_err" ] && head -3 "$index_err" | neutralize_ctrl --keep-newline | sed 's/^/  WARNING(cat hint): /' >&2
    else
      echo "WARNING: .rite/wiki/index.md を読み出せません" >&2
      [ -n "$index_err" ] && [ -s "$index_err" ] && head -3 "$index_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
      echo "  影響: 孤児ページ検出 (ステップ 5) を skip します（非ブロッキング）" >&2
      _emit_skipped "index_unreadable"
      exit 0
    fi
    ;;
esac

# ---- 登録済みページの抽出 (旧 lint.md ステップ 5 の登録ページ抽出の faithful port) --
# `./pages/...` / `../pages/...` 形式にも対応する緩和 regex + grep no-match の明示処理。
set -o pipefail
indexed_pages=$(printf '%s\n' "$index_content" \
  | { grep -oE '\]\((\.{0,2}\/?pages/[^)]+)\)' || true; } \
  | sed -E 's/^\]\(//; s/\)$//' \
  | sed -E 's|^\.{0,2}/?||' \
  | LC_ALL=C sort -u)
set +o pipefail

if [ -z "$indexed_pages" ]; then
  echo "WARNING: index.md のページ一覧テーブルから登録済みページを抽出できませんでした" >&2
  echo "  対処: index.md のテーブルフォーマット（| [title](pages/foo.md) | ... |）を確認してください" >&2
  echo "  影響: 孤児判定を skip します（全ページを orphan と誤検出しないため）" >&2
  _emit_skipped "index_empty"
  exit 0
fi

# ---- 集合差分 (旧 lint.md ステップ 5 の孤児判定の faithful port) ---------------
# pages_list は `.rite/wiki/` プレフィックス付きのため、indexed_pages (`pages/...`
# 形式) と比較する前に正規化する。orphan は元の `.rite/wiki/...` 形式で出力する
# (issues[] の page フィールドと同形式)。
n_orphans=0
orphan_lines=""
while IFS= read -r page_path; do
  [ -z "$page_path" ] && continue
  normalized="${page_path#.rite/wiki/}"
  if ! printf '%s\n' "$indexed_pages" | grep -qxF -- "$normalized"; then
    n_orphans=$((n_orphans + 1))
    orphan_lines="${orphan_lines}${page_path}
"
  fi
done <<< "$pages_list"

# ---- 登録行の重複・節外検出 ---------------------------------------------------
# 登録行 = 表の行 (縦線始まり) または箇条書きの行で、行内の最初の `](pages/...)` リンクを
# 持つもの (サマリー内の相互リンクや、前文・統計節の散文リンクを数えない)。リンク形式は上の
# indexed_pages 抽出と同じ緩い regex (`./` `../` 付きも許す)。行頭が `<!--` の HTML コメント
# ブロックは落とす: 箇条書きテンプレート期に初期化された bundle の前文には記法例
# `* [ページタイトル](pages/{domain}/{slug}.md)` がコメント内に残り、数えると恒久的な節外
# 登録行になる (wiki-lint-descriptive-refs.sh も同じ規則で落とす)。節の範囲は
# wiki-index-update.sh の is_heading / is_list_head と同じ式で判定する (`###` は見出しでない)。
# `## ページ一覧` 見出しが無い index (見出し導入前の箇条書き bundle) は節外判定の対象外とし、
# 重複だけを検査する。index.md は読むだけで書き換えない。
index_defect_lines=$(printf '%s\n' "$index_content" | LC_ALL=C awk '
  function is_heading(s)   { return s ~ /^##[^#]/ || s ~ /^##$/ }
  function is_list_head(s) { return s ~ /^##[ \t]*ページ一覧[ \t]*$/ }
  /^[ \t]*<!--/ { in_comment = 1 }
  in_comment { if (index($0, "-->") > 0) in_comment = 0; next }
  {
    if (is_heading($0)) in_list = is_list_head($0) ? 1 : 0
    if (is_list_head($0)) has_list_head = 1
    if ($0 ~ /^[ \t]*(\||[*+-][ \t])/ && match($0, /\]\(\.{0,2}\/?pages\/[^)]+\)/)) {
      key = substr($0, RSTART + 2, RLENGTH - 3)
      sub(/^\.{0,2}\/?/, "", key)
      n++; keys[n] = key; inl[n] = in_list ? 1 : 0
      if (!(key in cnt)) order[++m] = key
      cnt[key]++
    }
  }
  END {
    if (in_comment) { print "index.md の HTML コメントが閉じられないままファイル終端に達しました" > "/dev/stderr"; exit 2 }
    if (has_list_head) for (i = 1; i <= n; i++) if (!inl[i]) print "outside_section: " keys[i]
    for (j = 1; j <= m; j++) if (cnt[order[j]] >= 2) print "duplicate: " order[j] " (" cnt[order[j]] " 行)"
  }
') || {
  echo "ERROR: index.md の登録行の重複・節外検査 (awk) に失敗しました" >&2
  exit 1
}
n_index_defects=0
[ -n "$index_defect_lines" ] && n_index_defects=$(printf '%s\n' "$index_defect_lines" | wc -l | tr -d '[:space:]')

echo "n_orphans=$n_orphans"
echo "---orphans_begin---"
[ -n "$orphan_lines" ] && printf '%s' "$orphan_lines"
echo "---orphans_end---"
echo "orphan_check_ok=true"
echo "n_index_defects=$n_index_defects"
echo "---index_defects_begin---"
[ -n "$index_defect_lines" ] && printf '%s\n' "$index_defect_lines"
echo "---index_defects_end---"
echo "n_orphan_category=$((n_orphans + n_index_defects))"
echo "[CONTEXT] WIKI_LINT_ORPHANS=$n_orphans"
echo "[CONTEXT] WIKI_LINT_INDEX_DEFECTS=$n_index_defects"
