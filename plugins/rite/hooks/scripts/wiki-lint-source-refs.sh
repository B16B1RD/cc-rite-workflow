#!/usr/bin/env bash
# wiki-lint-source-refs.sh
#
# Build the `all_source_refs` set consumed by wiki/lint.md ステップ 6.2
# (対応ページの存在確認と 3 分岐). For each Wiki page in the supplied
# pages_list, read its body (via `git show` for separate_branch, `cat` for
# same_branch), extract frontmatter `sources[].resource` entries, dedup, and emit
# the set inside a marker block alongside a 3-value read_ok enum.
#
# Why a helper:
#   The inline implementation in lint.md was a ~240-line HIGH-weight bash
#   block. Delegating it removes a heredoc-malform / drift source while
#   keeping the cross-Bash-tool-boundary state-transfer contract verbatim.
#   See ../../skills/wiki-lint/references/bash-cross-boundary-state-transfer.md
#   (Pattern 2: marker-delimited block, Pattern 1: multi-value enum via
#   key=value stdout).
#
# Symmetry note: this is the step 6.2 counterpart to step 6.0's
# `wiki-lint-skipped-refs.sh`.
# Both share the marker block + io_error enum shape; keep them aligned.
#
# Inputs:
#   --branch-strategy {separate_branch|same_branch}  (required)
#   --wiki-branch BRANCH                              (required for separate_branch)
#   --repo-root DIR                                   (default: git rev-parse --show-toplevel)
#   pages_list                                        (stdin; one `.rite/wiki/pages/...` path per line)
#
# stdout contract (LLM holds these in conversation context; see lint.md step 3
# and step 9.1 で `all_source_refs_read_ok` を false-positive note 展開に使う):
#   ---all_source_refs_begin---
#   {ref}            # 0..N lines, sort -u 済み
#   ---all_source_refs_end---
#   all_source_refs_read_ok={unknown|true|io_error}
#   all_source_refs_read_errors={n}
#
# Exit codes:
#   0  正常 (read_ok / read_errors は stdout enum で表現、IO 失敗は io_error 降格)
#   1  fail-fast (placeholder residue / partial pollution / unknown branch_strategy)
#   2  invocation error (引数欠落 / repo-root cd 失敗)
#
# NOTE on shell flags: this is a faithful port of the inline block which
# manages `$?` explicitly per command. A global `set -e` would break those
# explicit rc checks (git show / cat / sort failures are handled, not fatal),
# so it is intentionally NOT set. `set -o pipefail` is toggled locally around
# the sort/awk pipelines exactly as the inline block did. `set -u` is likewise
# omitted to preserve verbatim behavior; all variable refs are `${var:-}`-guarded.

# shellcheck source=../control-char-neutralize.sh
source "$(dirname "${BASH_SOURCE[0]}")/../control-char-neutralize.sh"
branch_strategy=""
wiki_branch=""
REPO_ROOT=""

usage() {
  cat <<'EOF'
Usage: wiki-lint-source-refs.sh --branch-strategy STRATEGY [--wiki-branch BRANCH] [--repo-root DIR]

Reads pages_list from stdin (one `.rite/wiki/pages/...` path per line) and emits
the all_source_refs marker block + read_ok enum on stdout.

Options:
  --branch-strategy STRATEGY  separate_branch | same_branch (required)
  --wiki-branch BRANCH        Wiki branch ref (required for separate_branch)
  --repo-root DIR             Repository root (default: git rev-parse --show-toplevel)
  -h, --help                  Show this help

Exit codes:
  0  Normal (read_ok / read_errors expressed via stdout enum)
  1  Fail-fast (placeholder residue / partial pollution / unknown branch_strategy)
  2  Invocation error
EOF
}

# 各値付きフラグは `shift; shift` で消費する。値なしフラグが末尾に来た場合 ($#=1)、
# `shift 2` は $# を減らせず set -e 非設定下で無限ループに陥る。1 回目の shift で $# を
# 確実に 0 にし、2 回目は no-op で安全に抜ける (値欠落は下流の必須チェックが exit 2 で検出)。
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

# pages_list を stdin から全量読み込む (placeholder residue / partial pollution
# gate を集合全体に対して走らせるため、iteration 前に変数へ確定させる)。
pages_list="$(cat)"

# ---- Placeholder residue fail-fast gate -------------------------------------
# (lint.md の同型 gate: ステップ 1.1 / 1.3 / 4.2 / 6.0 / 6.2 / 8.1 / 8.3。
#  LLM が `{branch_strategy}` / `{wiki_branch}` / `{pages_list}` を literal
#  substitute せずに helper を呼んだ場合の検出。)
case "$branch_strategy" in
  "{"*"}")
    echo "ERROR: ステップ 6.2 の {branch_strategy} placeholder が literal substitute されていません (値: '$branch_strategy')" >&2
    echo "  LLM は ステップ 1.1 の stdout から会話コンテキストに保持された branch_strategy 値を literal substitute する必要があります" >&2
    echo "[CONTEXT] LINT_PHASE_6_2_PLACEHOLDER_RESIDUE=1; reason=branch_strategy_unsubstituted; value=$branch_strategy" >&2
    exit 1
    ;;
esac
case "$wiki_branch" in
  "{"*"}")
    echo "ERROR: ステップ 6.2 の {wiki_branch} placeholder が literal substitute されていません (値: '$wiki_branch')" >&2
    exit 1
    ;;
esac
# pages_list は空 (Wiki 初期化直後 / 0 件) が legitimate のため、literal 完全一致のみ error
case "$pages_list" in
  "{pages_list}")
    echo "ERROR: ステップ 6.2 の {pages_list} placeholder が literal substitute されていません (値: '$pages_list')" >&2
    echo "  LLM は ステップ 2.2 stdout から separator より前の '.rite/wiki/pages/...' 行のみを substitute する必要があります" >&2
    exit 1
    ;;
esac

# ---- Partial pollution 検出 gate --------------------------------------------
# (silent missing_concept 誤分類再発防止): LLM が ステップ 2.2 stdout の 3 部構造を
# 全体 substitute すると `.rite/wiki/raw/...` path が混入し、本来 pages 用の git show で
# legitimate absence (blob not found) として処理され、全 ingested raw が step 3(c) で
# missing_concept 誤分類される。既存の literal 残留 gate は「未 substitute」のみ検出し
# partial pollution を捕捉できないため、本 runtime 契約を追加。
if [ -n "$pages_list" ]; then
  partial_pollution_line=""
  while IFS= read -r pollution_check_line; do
    [ -z "$pollution_check_line" ] && continue  # blank line guard
    case "$pollution_check_line" in
      .rite/wiki/pages/*) ;;  # OK: 正当な pages_list 行
      *)
        partial_pollution_line="$pollution_check_line"
        break
        ;;
    esac
  done <<< "$pages_list"
  if [ -n "$partial_pollution_line" ]; then
    echo "ERROR: ステップ 6.2 の \$pages_list に '.rite/wiki/pages/' prefix を持たない行が含まれています (partial pollution 検出)" >&2
    echo "  違反行: '$partial_pollution_line'" >&2
    echo "  原因: LLM が ステップ 2.2 stdout の separator ('---') より後 (raw_list) を含めて HEREDOC に substitute した可能性があります" >&2
    echo "  対処: ステップ 2.2 stdout から separator より前の '.rite/wiki/pages/...' 行のみを substitute してください" >&2
    exit 1
  fi
fi

# branch_strategy を early に case 検証 (unknown は fail-fast、loop に入る前に弾く)
case "$branch_strategy" in
  separate_branch|same_branch) ;;
  *)
    echo "ERROR: 未知の branch_strategy 値を検出しました: '$branch_strategy' (ステップ 6.2)" >&2
    echo "  対処: rite-config.yml の wiki.branch_strategy を 'separate_branch' または 'same_branch' に設定してください" >&2
    exit 1
    ;;
esac

# separate_branch では --wiki-branch が必須。空のまま進むと git show "${wiki_branch}:$page" が
# git show ":$page" となり、ref ではなく git index (staging area) を読む別 semantics に陥り、
# legitimate absence と区別できない誤集合を構築する。header の "required for separate_branch"
# 契約を runtime で enforce する (引数欠落 → exit 2)。
if [ "$branch_strategy" = "separate_branch" ] && [ -z "$wiki_branch" ]; then
  echo "ERROR: branch_strategy=separate_branch では --wiki-branch が必須です (空のため fail-fast)" >&2
  usage >&2
  exit 2
fi

# repo root へ移動 (separate_branch の git show / same_branch の cat はいずれも
# repo-relative path を前提とする)。
if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
cd "$REPO_ROOT" || { echo "ERROR: cannot cd to repo root '$REPO_ROOT'" >&2; exit 2; }

# ---- 集合構築本体 (inline block の faithful port) ---------------------------
# signal-specific trap (per-iteration mktemp の orphan 防止)
page_err=""
awk_diag=""
sort_err=""
_cleanup() {
  [ -n "${page_err:-}" ] && rm -f "$page_err"
  [ -n "${awk_diag:-}" ] && rm -f "$awk_diag"
  [ -n "${sort_err:-}" ] && rm -f "$sort_err"
  return 0
}
trap 'rc=$?; _cleanup; exit $rc' EXIT
trap '_cleanup; exit 130' INT
trap '_cleanup; exit 143' TERM
trap '_cleanup; exit 129' HUP

all_source_refs_read_ok="unknown"  # 3 値 enum: unknown / true / io_error
all_source_refs_read_errors=0
all_source_refs=""
awk_diag_mktemp_failed=0  # accumulator (失敗件数)
page_err_mktemp_failed=0  # accumulator (失敗件数)

# `while IFS= read -r` 形式: ページパスに空白が含まれた場合の word-split 脆弱性排除
while IFS= read -r page; do
  [ -z "$page" ] && continue  # blank line guard

  page_err=$(mktemp "${TMPDIR:-/tmp}/rite-lint-page-err-XXXXXX" 2>/dev/null) || { page_err=""; page_err_mktemp_failed=$((page_err_mktemp_failed + 1)); }

  # branch_strategy ごとに 2 経路:
  #   separate_branch: git show (worktree には存在しない、ref から読取)
  #   same_branch:     cat (filesystem 上の tracked file を直接読む)
  # 分岐欠落で全 ingested raw が missing_concept 誤分類される regression を防ぐ。
  # LC_ALL=C で locale 固定 (legitimate absence regex との不一致による誤分類防止)
  case "$branch_strategy" in
    separate_branch)
      page_read_cmd_result=$(LC_ALL=C git show "${wiki_branch}:$page" 2>"${page_err:-/dev/null}")
      page_read_cmd_rc=$?
      ;;
    same_branch)
      page_read_cmd_result=$(LC_ALL=C cat "$page" 2>"${page_err:-/dev/null}")
      page_read_cmd_rc=$?
      ;;
  esac

  if [ "$page_read_cmd_rc" -eq 0 ]; then
    page_content="$page_read_cmd_result"
    # frontmatter YAML list から sources[].resource を抽出。
    # awk diag mktemp で sources_seen / extracted のカウントを stderr 経由で per-page 可視化
    # (「sources: 節は検出したが resource が 0 件」という YAML 破損を可視化)
    awk_diag=$(mktemp "${TMPDIR:-/tmp}/rite-lint-p62-awk-diag-XXXXXX" 2>/dev/null) || awk_diag=""
    if [ -z "$awk_diag" ]; then
      awk_diag_mktemp_failed=$((awk_diag_mktemp_failed + 1))
    fi
    # page-template.md の canonical YAML は multi-line 形式 (`- type: "..."\n  resource: "..."`)。
    # 同一行 `- resource:` の legacy 単行形式と multi-line 形式 ` resource:` (dash なしインデント付き) の両方を support する。
    page_refs=$(printf '%s\n' "$page_content" | awk -v diag="${awk_diag:-/dev/null}" -v page="$page" '
      /^sources:/ { in_sources=1; sources_seen++; next }
      # frontmatter terminator (`---`) を明示検出。
      # minimal frontmatter (sources: 直後に `---` で閉じる、tags:/confidence: なし) でも
      # sources 節が確実に閉じ、body 内 YAML code block の ` resource:` 誤抽出を防ぐ。
      in_sources && /^---[[:space:]]*$/ { in_sources=0; next }
      in_sources && /^[a-zA-Z]/ { in_sources=0 }
      in_sources && /^[[:space:]]*-[[:space:]]*resource:[[:space:]]/ {
        # legacy 単行形式: `- resource: "..."`
        sub(/^[[:space:]]*-[[:space:]]*resource:[[:space:]]*/, "")
        gsub(/["\x27]/, "")
        sub(/^\.rite\/wiki\//, "")  # prefix 正規化
        extracted++
        print
        next
      }
      in_sources && /^[[:space:]]+resource:[[:space:]]/ {
        # canonical multi-line 形式: `  resource: "..."` (前行が `- type: ...`)
        sub(/^[[:space:]]+resource:[[:space:]]*/, "")
        gsub(/["\x27]/, "")
        sub(/^\.rite\/wiki\//, "")
        extracted++
        print
      }
      END {
        if (sources_seen > 0 && extracted == 0) {
          if (diag == "/dev/null") {
            # mktemp 失敗 fallback: bash 側 check が false になるため awk から直接 stderr に emit
            printf "WARNING: %s の frontmatter に sources: 節が存在しますが resource が 1 件も抽出できませんでした (awk_diag mktemp 失敗経路 fallback)\n", page > "/dev/stderr"
            printf "  原因候補: YAML 構造破損 (改行混入 / quote 不整合 / インデント不正)\n" > "/dev/stderr"
            printf "  影響: 本ページが参照する raw source が all_source_refs 集合から欠落し、登録済み raw が missing_concept に誤分類される可能性\n" > "/dev/stderr"
          } else {
            printf "sources_section_empty\n" > diag
          }
        }
      }
    ')
    if [ -n "$awk_diag" ] && [ -s "$awk_diag" ]; then
      echo "WARNING: $page の frontmatter に sources: 節が存在しますが resource が 1 件も抽出できませんでした" >&2
      echo "  原因候補: YAML 構造破損 (改行混入 / quote 不整合 / インデント不正)" >&2
      echo "  影響: 本ページが参照する raw source が all_source_refs 集合から欠落し、登録済み raw が missing_concept に誤分類される可能性" >&2
    fi
    [ -n "$awk_diag" ] && rm -f "$awk_diag"
    awk_diag=""  # 次 iteration の trap cleanup で stale path を二重 rm しないため明示 reset
    if [ -n "$page_refs" ]; then
      all_source_refs=$(printf '%s\n%s' "$all_source_refs" "$page_refs")
    fi
  else
    # ステップ 6.0 と同じ stderr pattern matching で legitimate absence と io_error を判別。
    # branch_strategy ごとに legitimate absence の文言が異なるため両経路の pattern を OR する:
    #   separate_branch (git show): blob 不在
    #   same_branch (cat):          ENOENT / No such file
    if [ -n "$page_err" ] && [ -s "$page_err" ] && grep -qE "does not exist|path '.+' exists on disk, but not in|Not a valid object name|fatal: invalid object name '[^']*:|No such file or directory|cannot open .* for reading" "$page_err"; then
      # legitimate absence: 集合には追加しないが read_ok は下げない
      :
    else
      # 真の IO error: all_source_refs_read_errors を increment (後段で io_error に畳み込み)
      all_source_refs_read_errors=$((all_source_refs_read_errors + 1))
      echo "WARNING: $page の sources[].resource 抽出に失敗 (rc=$page_read_cmd_rc, branch_strategy=$branch_strategy)" >&2
      [ -n "$page_err" ] && [ -s "$page_err" ] && head -3 "$page_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    fi
  fi
  [ -n "$page_err" ] && rm -f "$page_err"
  page_err=""
done <<< "$pages_list"

# mktemp 失敗の集約 WARNING (per-iteration spam 回避のため post-loop で 1 回のみ emit)
if [ "$awk_diag_mktemp_failed" -gt 0 ]; then
  echo "WARNING: awk_diag tempfile の mktemp が $awk_diag_mktemp_failed 件失敗しました。per-page WARNING は awk END block から /dev/stderr 経由で emit 済みです" >&2
  echo "  対処: /tmp の容量 / 権限 / readonly filesystem を確認してください" >&2
fi
if [ "$page_err_mktemp_failed" -gt 0 ]; then
  echo "WARNING: page_err tempfile の mktemp が $page_err_mktemp_failed 件失敗しました" >&2
  echo "  対処: /tmp の容量 / 権限 / inode 枯渇 / readonly filesystem を確認してください" >&2
  echo "  影響: 本 Block の legitimate absence / io_error 判別は失敗経路でのみ精度低下 (io_error 側に倒す defense で silent 0 件は防止済み)" >&2
fi

# 終状態の enum 決定 (部分成功を silent に 0 件扱いしない)
if [ "$all_source_refs_read_errors" -gt 0 ]; then
  all_source_refs_read_ok="io_error"
else
  all_source_refs_read_ok="true"
fi

# sort -u で重複排除 (ステップ 6.0 awk/sort と対称に pipefail + stderr 捕捉)
if [ -n "$all_source_refs" ]; then
  set -o pipefail
  sort_err=$(mktemp "${TMPDIR:-/tmp}/rite-lint-p62-sort-err-XXXXXX" 2>/dev/null) || {
    echo "WARNING: stderr 退避 tempfile (sort_err) の mktemp に失敗しました。sort/awk pipeline の詳細エラー情報は失われます" >&2
    echo "  対処: /tmp の容量 / permission / inode 枯渇を確認してください" >&2
    echo "  影響: pipeline 失敗時の根本原因 (sort バイナリ異常 / OOM / SIGPIPE 等) が不可視になり、all_source_refs が io_error 降格しても理由が追えません" >&2
    sort_err=""
  }
  # 末尾 `awk 'NF>0'` は grep -c の no-match (rc=1) 問題を回避 (空行 only の edge case 対応)
  normalized=$(printf '%s\n' "$all_source_refs" | LC_ALL=C sort -u 2>"${sort_err:-/dev/null}" | awk 'NF>0' 2>>"${sort_err:-/dev/null}")
  sort_rc=$?
  if [ "$sort_rc" -ne 0 ]; then
    echo "WARNING: ステップ 6.2 の all_source_refs 正規化 pipeline が失敗しました (rc=$sort_rc)" >&2
    [ -n "$sort_err" ] && [ -s "$sort_err" ] && head -3 "$sort_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    echo "  対処: sort バイナリ / /tmp の容量 / 権限を確認してください" >&2
    echo "  影響: all_source_refs が部分出力で populate されると真の欠落判定が false positive になるため io_error に降格します" >&2
    all_source_refs_read_ok="io_error"
  else
    all_source_refs="$normalized"
  fi
  [ -n "$sort_err" ] && rm -f "$sort_err"
  sort_err=""
  set +o pipefail
fi

# marker block で集合を出力 (ステップ 6.0 の skipped_refs と同じパターン)
echo "---all_source_refs_begin---"
[ -n "$all_source_refs" ] && printf '%s\n' "$all_source_refs"
echo "---all_source_refs_end---"

echo "all_source_refs_read_ok=$all_source_refs_read_ok"
echo "all_source_refs_read_errors=$all_source_refs_read_errors"
