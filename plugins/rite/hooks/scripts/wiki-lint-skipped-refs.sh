#!/usr/bin/env bash
# wiki-lint-skipped-refs.sh
#
# Build the `skipped_refs` set consumed by wiki/lint.md ステップ 6.2 (b) 分岐
# (`unregistered_raw` 判定).  (Sub-3): the skip SoT moved from log.md
# (a table) to each raw source's frontmatter (`ingest_status: skipped`). This
# helper now scans `.rite/wiki/raw/**/*.md` frontmatter (via `git ls-tree` +
# `git show` for separate_branch, `find` + `cat` for same_branch), collects each
# `ingest_status: skipped` raw as `raw/{type}/{filename}`, dedups, and emits the
# set inside a marker block alongside a 4-value `log_read_ok` enum (enum name
# retained for the lint.md stdout contract; value now reflects the raw scan).
#
# Why a helper:
#   The inline implementation in lint.md ステップ 6.0 was a ~165-line bash
#   block. Delegating it removes a malform / drift source while keeping the
#   cross-Bash-tool-boundary state-transfer contract verbatim.
#   See ../../skills/wiki-lint/references/bash-cross-boundary-state-transfer.md
#   (Pattern 1: multi-value enum via key=value stdout, Pattern 2:
#   marker-delimited block).
#
# Symmetry note: this is the step 6.0 counterpart to step 6.2's
# `wiki-lint-source-refs.sh`. Both share the marker block +
# io_error enum shape and the legitimate-absence stderr pattern matching;
# keep them aligned.
#
# Inputs:
#   --branch-strategy {separate_branch|same_branch}  (required)
#   --wiki-branch BRANCH                              (required for separate_branch)
#   --repo-root DIR                                   (default: git rev-parse --show-toplevel)
#
# stdout contract (LLM holds these in conversation context; lint.md ステップ 6.2 (b)
# 分岐と ステップ 9.1 の false-positive note 展開が参照する):
#   skipped_refs_count={n}
#   ---skipped_refs_begin---
#   {ref}            # 0..N lines, sort -u 済み (`raw/{type}/{filename}` 形式)
#   ---skipped_refs_end---
#   log_read_ok={unknown|true|absent|io_error}
#
# Exit codes:
#   0  正常 (log_read_ok は stdout enum で表現、読出失敗は absent / io_error 降格)
#   1  fail-fast (placeholder residue / unknown branch_strategy)
#   2  invocation error (引数欠落 / repo-root cd 失敗)
#
# NOTE on shell flags: this script manages `$?` explicitly per command. A global
# `set -e` would break those explicit rc checks (git ls-tree / find listing
# failures degrade to io_error per AC-7; per-file git show / cat failures are
# isolated as non-skipped per AC-6 — all handled explicitly, none fatal), so it
# is intentionally NOT set.
# `set -o pipefail` is also NOT used: no pipeline's exit status is consumed here
# (every `$(... | ...)` capture is judged by its output via `[ -n ... ]` / sort,
# never by its rc), so a mid-pipeline failure cannot silently corrupt an rc check.
# `set -u` is likewise omitted; all variable refs are `${var:-}`-guarded.

# shellcheck source=../control-char-neutralize.sh
source "$(dirname "${BASH_SOURCE[0]}")/../control-char-neutralize.sh"
branch_strategy=""
wiki_branch=""
REPO_ROOT=""

usage() {
  cat <<'EOF'
Usage: wiki-lint-skipped-refs.sh --branch-strategy STRATEGY [--wiki-branch BRANCH] [--repo-root DIR]

Scans `.rite/wiki/raw/**/*.md` frontmatter (`ingest_status: skipped`) per the
branch strategy and emits the skipped_refs marker block + log_read_ok enum on
stdout.

Options:
  --branch-strategy STRATEGY  separate_branch | same_branch (required)
  --wiki-branch BRANCH        Wiki branch ref (required for separate_branch)
  --repo-root DIR             Repository root (default: git rev-parse --show-toplevel)
  -h, --help                  Show this help

Exit codes:
  0  Normal (log_read_ok expressed via stdout enum)
  1  Fail-fast (placeholder residue / unknown branch_strategy)
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

# ---- Placeholder residue fail-fast gate -------------------------------------
# (wiki-lint-source-refs.sh の 6.2 gate と対称。LLM が `{branch_strategy}` /
#  `{wiki_branch}` を literal substitute せずに helper を呼んだ場合の検出。
#  旧 inline block では `{wiki_branch}` 残留が git show の stderr 文言次第で
#  absent / io_error に揺れていた経路を fail-fast に統一する)
case "$branch_strategy" in
  "{"*"}")
    echo "ERROR: ステップ 6.0 の {branch_strategy} placeholder が literal substitute されていません (値: '$branch_strategy')" >&2
    echo "  LLM は ステップ 1.1 の stdout から会話コンテキストに保持された branch_strategy 値を literal substitute する必要があります" >&2
    echo "[CONTEXT] LINT_PHASE_6_0_PLACEHOLDER_RESIDUE=1; reason=branch_strategy_unsubstituted; value=$branch_strategy" >&2
    exit 1
    ;;
esac
case "$wiki_branch" in
  "{"*"}")
    echo "ERROR: ステップ 6.0 の {wiki_branch} placeholder が literal substitute されていません (値: '$wiki_branch')" >&2
    exit 1
    ;;
esac

# branch_strategy を early に case 検証 (unknown は fail-fast — 旧 inline block と同じ文言)
case "$branch_strategy" in
  separate_branch|same_branch) ;;
  *)
    echo "ERROR: 未知の branch_strategy 値を検出しました: '$branch_strategy' (ステップ 6.0)" >&2
    echo "  対処: rite-config.yml の wiki.branch_strategy を 'separate_branch' または 'same_branch' に設定してください" >&2
    exit 1
    ;;
esac

# separate_branch では --wiki-branch が必須。空のまま進むと git show ":.rite/wiki/raw/..." が
# ref ではなく git index (staging area) を読む別 semantics に陥る (wiki-lint-source-refs.sh と
# 同じ runtime enforcement)。
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
# signal-specific trap (canonical 4 行パターン)。
# 詳細は references/bash-trap-patterns.md#signal-specific-trap-template 参照。
log_err=""
_cleanup() {
  [ -n "${log_err:-}" ] && rm -f "$log_err"
  return 0
}
trap 'rc=$?; _cleanup; exit $rc' EXIT
trap '_cleanup; exit 130' INT
trap '_cleanup; exit 143' TERM
trap '_cleanup; exit 129' HUP

# skipped_refs 空継続時の「影響」文言 helper (複数 site の literal duplicate を集約)
_rite_log_read_impact_advice() {
  echo "  影響: skipped_refs を空として継続するため、skip 済み raw が誤って missing_concept に計上される可能性あり" >&2
}

log_err=$(mktemp "${TMPDIR:-/tmp}/rite-wiki-lint-p60-err-XXXXXX" 2>/dev/null) || {
  echo "WARNING: stderr 退避 tempfile (log_err) の mktemp に失敗しました。raw 走査の詳細エラー情報は失われます" >&2
  echo "  対処: /tmp の容量 / permission / inode 枯渇を確認してください" >&2
  echo "  影響: stderr pattern match が実行不能になり io_error 側に倒れ、false positive note が常に表示される regression が起き得ます" >&2
  log_err=""
}

skipped_refs=""
# log_read_ok は 4 値 enum (unknown / true / absent / io_error)。
#   unknown: 初期値 (placeholder/strategy fail-fast 経路でのみ残る、後段未到達)
#   true:    raw frontmatter 走査成功 (空集合含む。separate_branch では raw tree 不在も
#            git ls-tree rc=0 + 空出力で true に倒れる)
#   absent:  legitimate absence — same_branch: raw dir 不在 (find ENOENT) /
#            separate_branch: wiki_branch ref 自体が不在。いずれも skipped_refs="" は妥当
#   io_error: 真の IO error — false positive リスクあり、ステップ 9.1 完了レポートで note 表示
# canonical 定義: references/bash-cross-boundary-state-transfer.md#pattern-1-multi-value-enum-via-key-value-stdout
log_read_ok="unknown"

# (Sub-3): the `ingest:skip` SoT moved from log.md (a table this
# helper used to `awk -F'|'` parse) to each raw source's frontmatter
# (`ingest_status: skipped`). log.md is now a human-facing OKF change log and is
# NOT parsed here. This helper now scans `.rite/wiki/raw/**/*.md` frontmatter and
# emits each skipped raw as `raw/{type}/{filename}`.
#
# The `log_read_ok` enum NAME is retained for the lint.md stdout contract
# (ステップ 6.0 / 9.1 read it verbatim); its value now reflects the raw-frontmatter
# *scan* status rather than a log.md read:
#   true:     raw sources scanned successfully (set is reliable; an empty raw
#             tree under an existing separate_branch ref also yields true)
#   absent:   legitimate absence — same_branch: no raw dir (find ENOENT);
#             separate_branch: the wiki_branch ref itself is missing
#   io_error: raw directory listing failed — empty set may be a false negative,
#             so lint.md ステップ 9.1 shows the false-positive note
#
# _emit_if_skipped: print "$rel" when the given raw content's frontmatter has
# `ingest_status: skipped` (quotes tolerated, AC-6 permissive — absence of the
# field means "not skipped"). $rel is the raw path relative to .rite/wiki/.
_emit_if_skipped() {
  printf '%s\n' "$2" | awk -v rel="$1" '
    NR == 1 && /^---[[:space:]]*$/ { infm=1; next }
    infm && /^---[[:space:]]*$/ { exit }
    infm && /^ingest_status:[[:space:]]*["'"'"']?skipped["'"'"']?[[:space:]]*$/ { print rel; exit }
  '
}

# Accumulate skipped raw refs across all raw sources. A per-file content read
# failure skips that single raw (treated as non-skipped, AC-6) with a WARNING but
# does NOT empty the whole set; only a directory-listing failure degrades to
# io_error (AC-7).
_skip_acc=""
case "$branch_strategy" in
  separate_branch)
    # LC_ALL=C locale 固定で git stderr の翻訳による absence 判別揺れを防ぐ (旧実装と同規約)。
    if raw_files=$(LC_ALL=C git ls-tree -r --name-only "$wiki_branch" .rite/wiki/raw/ 2>"${log_err:-/dev/null}"); then
      # ls-tree success (空でも raw dir 不在として scan は成立) → 信頼できる集合
      log_read_ok="true"
      while IFS= read -r f; do
        [ -z "$f" ] && continue
        case "$f" in *.md) ;; *) continue ;; esac
        if content=$(LC_ALL=C git show "${wiki_branch}:${f}" 2>/dev/null); then
          line=$(_emit_if_skipped "${f#.rite/wiki/}" "$content")
          [ -n "$line" ] && _skip_acc="${_skip_acc}${line}"$'\n'
        else
          echo "WARNING: raw source ${f} を wiki branch から読めません (skip 判定をスキップ)" >&2
        fi
      done <<< "$raw_files"
    else
      rc=$?
      # ここに来るのは ls-tree が rc≠0 で失敗した時のみ。raw tree 不在 (path 欠落) は
      # rc=0 + 空出力で上の then 側 (true) に倒れるため、ここには来ない。wiki_branch ref
      # 自体の race-absence (Not a valid object name 等) のみ absent、それ以外は io_error。
      if [ -n "$log_err" ] && [ -s "$log_err" ] && \
         grep -qE "Not a valid object name|not a tree object|does not exist" "$log_err"; then
        log_read_ok="absent"
      else
        log_read_ok="io_error"
        echo "WARNING: .rite/wiki/raw/ の git ls-tree に失敗しました (rc=$rc)" >&2
        [ -n "$log_err" ] && [ -s "$log_err" ] && head -3 "$log_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
        _rite_log_read_impact_advice
        echo "  対処: wiki branch の integrity / 権限を確認してください" >&2
      fi
    fi
    ;;
  same_branch)
    if raw_files=$(LC_ALL=C find .rite/wiki/raw -type f -name '*.md' 2>"${log_err:-/dev/null}"); then
      log_read_ok="true"
      while IFS= read -r f; do
        [ -z "$f" ] && continue
        if content=$(LC_ALL=C cat "$f" 2>/dev/null); then
          line=$(_emit_if_skipped "${f#.rite/wiki/}" "$content")
          [ -n "$line" ] && _skip_acc="${_skip_acc}${line}"$'\n'
        else
          echo "WARNING: raw source ${f} を読めません (skip 判定をスキップ)" >&2
        fi
      done <<< "$raw_files"
    else
      rc=$?
      # find は .rite/wiki/raw 不在で "No such file or directory" + 非 0 → absent。
      if [ -n "$log_err" ] && [ -s "$log_err" ] && grep -qE "No such file or directory" "$log_err"; then
        log_read_ok="absent"
      else
        log_read_ok="io_error"
        echo "WARNING: .rite/wiki/raw/ の find に失敗しました (rc=$rc)" >&2
        [ -n "$log_err" ] && [ -s "$log_err" ] && head -3 "$log_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
        _rite_log_read_impact_advice
        echo "  対処: .rite/wiki/raw/ の存在 / 権限を確認してください" >&2
      fi
    fi
    ;;
esac

# 重複排除 (同一 raw が複数列挙されることは無いが、契約踏襲で sort -u)
if [ -n "$_skip_acc" ]; then
  skipped_refs=$(printf '%s' "$_skip_acc" | LC_ALL=C sort -u | sed '/^$/d')
fi

# 集合本体を marker block で stdout 出力 (ステップ 6.2 の (b) 分岐で LLM が会話コンテキストに保持する)。
# canonical: references/bash-cross-boundary-state-transfer.md#pattern-2-marker-delimited-multi-value-block
if [ -n "$skipped_refs" ]; then
  count=$(printf '%s\n' "$skipped_refs" | awk 'NF>0 {n++} END {print n+0}')
  echo "skipped_refs_count=$count"
  echo "---skipped_refs_begin---"
  printf '%s\n' "$skipped_refs"
  echo "---skipped_refs_end---"
else
  echo "skipped_refs_count=0"
  echo "---skipped_refs_begin---"
  echo "---skipped_refs_end---"
fi

# log_read_ok を stdout 出力 (LLM が ステップ 9.1 完了レポートで参照する契約)
echo "log_read_ok=$log_read_ok"
