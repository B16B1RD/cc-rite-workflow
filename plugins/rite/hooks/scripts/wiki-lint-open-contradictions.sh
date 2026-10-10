#!/usr/bin/env bash
# wiki-lint-open-contradictions.sh
#
# Read the open (unresolved) contradiction set recorded by the latest lint entry
# of `.rite/wiki/log.md`. Consumed by /rite:wiki-lint ステップ 3.1 (自動比較の
# 引継ぎ) and /rite:wiki-ingest ステップ 8.3.r (矛盾の解消).
#
# Every lint run writes each contradiction it reports as one fixed-format
# sub-bullet under its `* **lint:...**` bullet:
#
#   * 未解消の矛盾: [a](pages/{domain}/{slug}.md) ↔ [b](pages/{domain}/{slug}.md) — {subcategory}: {reason}
#
# so the latest lint entry is a snapshot of the open set. log.md keeps date
# headings newest-first and appends bullets at the end of a date section, so the
# latest entry is the LAST lint bullet of the FIRST date section that has one.
# Entries written before the fixed format existed carry no such lines and read
# as zero lines; the count check below still applies to them.
#
# The committed log.md is the source (separate_branch: the wiki branch ref,
# same_branch: HEAD), never the working file: an entry whose commit failed is
# not a record.
#
# Inputs:
#   --branch-strategy {separate_branch|same_branch}  (required)
#   --wiki-branch BRANCH                              (required for separate_branch)
#   --repo-root DIR                                   (default: git rev-parse --show-toplevel)
#
# stdout contract:
#   ---open_contradictions_begin---
#   {page_a}|{page_b}|{subcategory}   # 0..N lines, repo-root relative `.rite/wiki/pages/...`
#   ---open_contradictions_end---
#   n_open={n}
#
# Exit codes:
#   0  Normal (no lint entry yet also yields n_open=0)
#   1  Fail-fast (placeholder residue / unknown branch_strategy / log.md unreadable /
#      malformed open line / contradictions=N disagrees with the number of open lines)
#   2  Invocation error
#
# No `set -e`: every failure is checked explicitly and reported before exit.

branch_strategy=""
wiki_branch=""
REPO_ROOT=""

usage() {
  cat <<'EOF'
Usage: wiki-lint-open-contradictions.sh --branch-strategy STRATEGY [--wiki-branch BRANCH] [--repo-root DIR]

Reads the committed .rite/wiki/log.md and emits the open contradiction pairs
recorded by its latest lint entry.

Options:
  --branch-strategy STRATEGY  separate_branch | same_branch (required)
  --wiki-branch BRANCH        Wiki branch ref (required for separate_branch)
  --repo-root DIR             Repository root (default: git rev-parse --show-toplevel)
  -h, --help                  Show this help

Exit codes:
  0  Normal
  1  Fail-fast (placeholder residue / unknown branch_strategy / log.md unreadable /
     malformed open line / count mismatch)
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

for _v in "$branch_strategy" "$wiki_branch"; do
  case "$_v" in
    "{"*"}")
      echo "ERROR: 未解消の矛盾の読出で placeholder が literal substitute されていません (値: '$_v')" >&2
      exit 1
      ;;
  esac
done

case "$branch_strategy" in
  separate_branch) log_ref="$wiki_branch" ;;
  same_branch) log_ref="HEAD" ;;
  *)
    echo "ERROR: 未知の branch_strategy 値を検出しました: '$branch_strategy' (未解消の矛盾の読出)" >&2
    echo "  対処: rite-config.yml の wiki.branch_strategy を 'separate_branch' または 'same_branch' に設定してください" >&2
    exit 1
    ;;
esac

if [ -z "$log_ref" ]; then
  echo "ERROR: branch_strategy=separate_branch では --wiki-branch が必須です" >&2
  usage >&2
  exit 2
fi

if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
cd "$REPO_ROOT" || { echo "ERROR: cannot cd to repo root '$REPO_ROOT'" >&2; exit 2; }

if ! log_content=$(git show "${log_ref}:.rite/wiki/log.md"); then
  echo "ERROR: commit 済みの log.md を読めません (${log_ref}:.rite/wiki/log.md)" >&2
  echo "  未解消の矛盾の記録を確認できないため停止します" >&2
  exit 1
fi

# Print the latest lint bullet line, then the open lines under it (marker removed
# up to the colon, kept verbatim after it). Sub-lines are the indented lines that
# directly follow the bullet.
entry=$(printf '%s\n' "$log_content" | awk '
  /^## [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ {
    if (chosen) exit
    in_entry = 0
    next
  }
  /^\* \*\*lint:/ {
    chosen = 1
    in_entry = 1
    out = $0 "\n"
    next
  }
  in_entry && /^[[:space:]]/ {
    if ($0 ~ /^[[:space:]]+[*-] 未解消の矛盾:/) out = out $0 "\n"
    next
  }
  { in_entry = 0 }
  END { printf "%s", out }
')

n_open=0
pairs=""
if [ -n "$entry" ]; then
  header=$(printf '%s\n' "$entry" | head -n 1)
  n_recorded=$(printf '%s\n' "$header" | sed -n -E 's/.*contradictions=([0-9]+).*/\1/p')
  if [ -z "$n_recorded" ]; then
    echo "ERROR: 直近の lint エントリに contradictions= がありません: $header" >&2
    exit 1
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    pair=$(printf '%s\n' "$line" | sed -n -E \
      's#^[[:space:]]+[*-] 未解消の矛盾: \[[^]]+\]\((pages/(patterns|heuristics|anti-patterns)/[^/)]+\.md)\) ↔ \[[^]]+\]\((pages/(patterns|heuristics|anti-patterns)/[^/)]+\.md)\) — (タイトル衝突|方針逆転|重複情報): .+$#.rite/wiki/\1|.rite/wiki/\3|\5#p')
    if [ -z "$pair" ]; then
      echo "ERROR: 未解消の矛盾の行が固定書式に一致しません: $line" >&2
      exit 1
    fi
    pairs="${pairs}${pair}
"
    n_open=$((n_open + 1))
  done <<EOF
$(printf '%s\n' "$entry" | tail -n +2)
EOF
  if [ "$n_open" -ne "$n_recorded" ]; then
    echo "ERROR: 直近の lint エントリの contradictions=$n_recorded と未解消の矛盾の行数 $n_open が一致しません" >&2
    echo "  対処: /rite:wiki-lint（--auto なし）を実行して、全ページ比較による新しい記録を作ってください" >&2
    exit 1
  fi
fi

echo "---open_contradictions_begin---"
printf '%s' "$pairs"
echo "---open_contradictions_end---"
echo "n_open=$n_open"
