#!/usr/bin/env bash
# wiki-lint-descriptive-refs.sh
#
# Count descriptive Issue/PR number references left in Wiki page bodies, for
# wiki-lint ステップ 7.5 (informational). The Wiki is a place for Why prose, not a
# holder of numbers (Comment Best Practices SoT 適用スコープ includes Wiki pages),
# so a body carrying 「PR #N は…」「詳細は #N」「(refs #N)」 is surfaced as a finding.
#
# Why a helper:
#   The inline implementation in wiki-lint/SKILL.md ステップ 7.5 was a compact grep
#   pipeline. Once the detection widened to bare `PR #N` / `Issue #N`, the body had
#   to grow four exclusions (frontmatter / provenance section / code fence / code
#   span) — past bash-heaviness-check.sh's LINE_THRESHOLD, and past what a mutation
#   test can reach while the logic lives inside a Markdown fence. Delegating keeps
#   SKILL.md lean and makes the detection directly testable.
#
# Symmetry note: this is the ステップ 7.5 counterpart to ステップ 6.0's
# `wiki-lint-skipped-refs.sh` and ステップ 6.2's `wiki-lint-source-refs.sh`. All three
# share the stdin `pages_list` + marker block + read_ok enum shape; keep them aligned.
#
# Detection (2 normalized rules, NOT a list of surface forms):
#
#   R1: a reference keyword immediately preceding a number
#       (Issues?|PRs?|[Rr]efs?|[Ss]ee|Related to|Closes|Fixes|Resolves) *#[0-9]+
#       The keyword list is a vocabulary, not a form enumeration: the parenthesised
#       form 「(refs #N)」, the 「see PR #N」 form and the bare 「PR #N は…」 form all
#       reduce to "keyword, optional spaces, number", so they are one rule rather
#       than three alternatives. Adding a surface form here means adding a word to
#       the vocabulary, never a new branch.
#
#   R2: the two keyword-less Japanese descriptive constructs
#       #[0-9]+ ?で(別途)?対応  および  詳細は ?#[0-9]+
#       These carry no reference keyword, so they cannot fold into R1.
#
#   Bare `#N` with no keyword at all is deliberately NOT detected: it appears in too
#   many legitimate contexts to separate mechanically, and widening to it would force
#   exclusions far past the "cut exclusions minimally" rule. AC-1 asks for the bare
#   `PR #N` / `Issue #N` forms, which R1 covers.
#
# Word boundary:
#   Number matches end with `([^0-9]|$)` so a match can never stop mid-number
#   (`#204` inside `#2047`). Greedy `[0-9]+` already reaches the end of the digit run;
#   the explicit boundary pins that as a contract so a later narrowing of the number
#   pattern cannot silently reintroduce prefix collision.
#   NOTE: this must stay a character class, not `\b` — gawk reads `\b` as backspace,
#   so `/#[0-9]+\b/` never matches and the detector would silently go quiet.
#
# Exclusions (each is a deliberate blind spot; the trade-off is recorded per entry
# because an exclusion also hides genuine recurrences inside its scope):
#
#   E1 frontmatter          — `sources[].ref` is provenance (a file path), not a
#                             descriptive reference. Blind spot: a descriptive ref
#                             written into frontmatter prose is never seen.
#   E2 `## ソース` section   — the provenance link labels (`- [PR #N review results](...)`)
#                             are the audit trail for where the page came from and are
#                             maintained by design. Scanning them would report all 306
#                             pages that carry the section. Blind spot: everything below
#                             the heading, including any prose accidentally placed there.
#   E3 code fence           — fenced blocks quote commands and regexes verbatim; a number
#                             inside one is a literal, not a claim. Blind spot: a real
#                             descriptive ref written inside a fence.
#   E4 inline code span     — same reason as E3 for `` `refs #204` ``. Spans are replaced
#                             with `_` rather than removed, so masking cannot join a
#                             keyword to a following number and manufacture a match.
#   E5 TODO / FIXME lines   — a tracking number on TODO/FIXME is a forward pointer and is
#                             kept by the 廃止判定ルール. Blind spot: a descriptive ref on
#                             the same line as a TODO.
#
# Inputs:
#   --branch-strategy {separate_branch|same_branch}  (required)
#   --wiki-branch BRANCH                              (required for separate_branch)
#   --repo-root DIR                                   (default: git rev-parse --show-toplevel)
#   pages_list                                        (stdin; one `.rite/wiki/pages/...` path per line)
#
# stdout contract (wiki-lint/SKILL.md ステップ 7.5 / ステップ 9 完了レポートが読む):
#   ---descriptive_refs_begin---
#   page={path}; hits={n}      # 0..N lines, hits>0 のページのみ
#   ---descriptive_refs_end---
#   descriptive_refs_pages={n}
#   [CONTEXT] WIKI_DESCRIPTIVE_REFS={n}
#   descriptive_refs_read_ok={true|io_error}
#
# `hits` counts matching body lines (not occurrences), preserving the metric the
# inline `grep -c` implementation reported.
#
# Exit codes:
#   0  正常 (読出失敗は descriptive_refs_read_ok=io_error で表現)
#   1  fail-fast (placeholder residue / unknown branch_strategy)
#   2  invocation error (引数欠落 / repo-root cd 失敗)
#
# NOTE on shell flags: `$?` is checked explicitly per command (a per-page read failure
# is isolated as a skipped page, never fatal), so a global `set -e` would break those
# checks and is intentionally not set. `set -o pipefail` is likewise unused: no
# pipeline's rc is consumed — every capture is judged by its output. All variable refs
# are `${var:-}`-guarded, so `set -u` is not needed either.

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

# partial pollution gate: raw_list 行の混入は検出対象を取り違えるため fail-fast
# (ステップ 2.2 stdout の separator 以降を巻き込んだ substitute の検出)。
if [ -n "$pages_list" ]; then
  _polluted=""
  while IFS= read -r _p; do
    [ -z "$_p" ] && continue
    case "$_p" in
      .rite/wiki/pages/*) ;;
      *) _polluted="$_p"; break ;;
    esac
  done <<< "$pages_list"
  if [ -n "$_polluted" ]; then
    echo "ERROR: ステップ 7.5 の \$pages_list に '.rite/wiki/pages/' prefix を持たない行が含まれています (partial pollution 検出)" >&2
    echo "  検出行: $(printf '%s' "$_polluted" | neutralize_ctrl)" >&2
    echo "  対処: ステップ 2.2 stdout から separator より前の '.rite/wiki/pages/...' 行のみを substitute してください" >&2
    exit 1
  fi
fi

# ---- 検出本体 ---------------------------------------------------------------

# 本文抽出フィルタ: E1 frontmatter / E3 code fence / E2 `## ソース` 節 / E5 TODO・FIXME を落とし、
# E4 inline code span を `_` へマスクした残りを stdout に出す。
# 順序が契約: fence の toggle は他のどの `next` よりも先に評価する。TODO を含む行や
# `## ソース` 行で先に打ち切ると fence 状態が desync し、以降の判定が丸ごとずれる。
_RITE_BODY_FILTER='
NR==1 && /^---[[:space:]]*$/ { infm=1; next }
infm && /^---[[:space:]]*$/  { infm=0; next }
infm                        { next }
/^[[:space:]]*```/          { infence = !infence; next }
infence                     { next }
/^##[[:space:]]+ソース[[:space:]]*$/ { exit }
/(TODO|FIXME)/              { next }
{ gsub(/`[^`]*`/, "_"); print }
'

# R1 (keyword vocabulary + number) と R2 (keyword-less な日本語 2 構文) の 2 規則。
# 語境界は `\b` ではなく `([^0-9]|$)` — gawk の `\b` はバックスペース扱いで never-match。
_RITE_DESCRIPTIVE_RE='(Issues?|PRs?|[Rr]efs?|[Ss]ee|Related to|Closes|Fixes|Resolves) *#[0-9]+([^0-9]|$)|#[0-9]+ ?で(別途)?対応|詳細は ?#[0-9]+([^0-9]|$)'

n_descriptive_refs=0
n_pages_with_hits=0
n_read_errors=0
hit_lines=""

while IFS= read -r page; do
  [ -z "$page" ] && continue
  if [ "$branch_strategy" = "separate_branch" ]; then
    page_content=$(LC_ALL=C git show "${wiki_branch}:${page}" 2>/dev/null)
  else
    page_content=$(LC_ALL=C cat "$page" 2>/dev/null)
  fi
  if [ -z "$page_content" ]; then
    # 空ページと読出失敗はここでは区別できない。どちらも hits 0 で扱いつつ件数を数え、
    # 全ページが読めなかった場合のみ io_error へ降格する (空 Wiki の legitimate な 0 件と、
    # 読出総崩れによる偽の 0 件を取り違えないため)。
    n_read_errors=$((n_read_errors + 1))
    continue
  fi
  hits=$(printf '%s\n' "$page_content" | awk "$_RITE_BODY_FILTER" | grep -cE "$_RITE_DESCRIPTIVE_RE")
  case "$hits" in ''|*[!0-9]*) hits=0 ;; esac
  if [ "$hits" -gt 0 ]; then
    n_descriptive_refs=$((n_descriptive_refs + hits))
    n_pages_with_hits=$((n_pages_with_hits + 1))
    hit_lines="${hit_lines}page=${page}; hits=${hits}"$'\n'
    echo "WikiDescriptiveRef: page=${page#.rite/wiki/}, hits=${hits}" >&2
  fi
done <<< "$pages_list"

# read_ok: ページが 1 件以上あるのに全件読めなかった場合のみ io_error。
# 一部読めなかった場合は残りの集計が有効なため true を維持し、件数だけ WARNING で surface する。
n_pages_total=$(printf '%s\n' "$pages_list" | awk 'NF>0 {n++} END {print n+0}')
descriptive_refs_read_ok="true"
if [ "$n_pages_total" -gt 0 ] && [ "$n_read_errors" -eq "$n_pages_total" ]; then
  descriptive_refs_read_ok="io_error"
  echo "WARNING: pages_list の全 ${n_pages_total} ページを読み出せませんでした (branch_strategy=$branch_strategy)" >&2
  echo "  影響: 説明的番号参照 0 件は実体を反映していません (informational 指標のため lint は継続します)" >&2
  echo "  対処: wiki branch ref / ページパスの整合を確認してください" >&2
elif [ "$n_read_errors" -gt 0 ]; then
  echo "WARNING: ${n_read_errors}/${n_pages_total} ページを読み出せず集計から除外しました" >&2
fi

echo "---descriptive_refs_begin---"
[ -n "$hit_lines" ] && printf '%s' "$hit_lines"
echo "---descriptive_refs_end---"
echo "descriptive_refs_pages=$n_pages_with_hits"
echo "[CONTEXT] WIKI_DESCRIPTIVE_REFS=$n_descriptive_refs"
echo "descriptive_refs_read_ok=$descriptive_refs_read_ok"
