#!/usr/bin/env bash
# wiki-lint-open-contradictions.sh
#
# Read the open (unresolved) contradiction set recorded by the latest lint entry
# of `.rite/wiki/log.md`. Consumed by /rite:wiki-lint ステップ 3.1 (自動比較の
# 引継ぎ) and /rite:wiki-ingest ステップ 8.3.r (矛盾の解消).
#
# Every lint run writes its result bullet `* **lint:{clean|warning}** — contradictions={n}, ...`
# and each contradiction it reports as one fixed-format sub-bullet under it:
#
#   * 未解消の矛盾: [a](pages/{domain}/{slug}.md) ↔ [b](pages/{domain}/{slug}.md) — {subcategory}: {reason}
#
# so the latest result bullet is a snapshot of the open set. log.md keeps date
# headings newest-first and appends bullets at the end of a date section, so the
# latest entry is the LAST result bullet of the FIRST date section that has one.
# Only that six-field result bullet is a record: other `**lint:...**` bullets
# (scope notes, older formats without `contradictions=`) are skipped. An open line
# under such a bullet (for example a result bullet whose heading lost the ` — `
# separator) stops the read instead of being dropped with the bullet.
# Result bullets written before the fixed lines existed read as zero lines; the
# count check below still applies to them.
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
#   {page_a}|{page_b}|{subcategory}|{reason}   # 0..N lines, pages repo-root relative `.rite/wiki/pages/...`
#   (reason is the last field and may itself contain `|`: split on the first three only)
#   ---open_contradictions_end---
#   n_open={n}
#
# Exit codes:
#   0  Normal (no lint entry yet also yields n_open=0)
#   1  Fail-fast (placeholder residue / unknown branch_strategy / log.md unreadable /
#      malformed open line / open line under a non-result lint bullet /
#      contradictions=N disagrees with the number of open lines)
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
     malformed open line / open line under a non-result lint bullet / count mismatch)
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

# Print the latest result bullet line, then the open lines under it. Sub-lines are
# the indented lines that directly follow the bullet.
if ! entry=$(printf '%s\n' "$log_content" | awk '
  /^## [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ {
    if (chosen) exit
    in_entry = 0
    in_other = 0
    next
  }
  /^\* \*\*lint:(clean|warning)\*\* — contradictions=[0-9]/ {
    chosen = 1
    in_entry = 1
    in_other = 0
    out = $0 "\n"
    next
  }
  /^\* \*\*lint:/ {
    in_entry = 0
    in_other = 1
    next
  }
  in_entry && /^[[:space:]]/ {
    if ($0 ~ /^[[:space:]]+[*-] 未解消の矛盾:/) out = out $0 "\n"
    next
  }
  in_other && /^[[:space:]]+[*-] 未解消の矛盾:/ {
    print "ERROR: 6 フィールドの結果行でない lint bullet の下に未解消の矛盾の行があります (log.md " NR " 行目): " $0 > "/dev/stderr"
    bad = 1
    exit
  }
  in_other && /^[[:space:]]/ { next }
  {
    in_entry = 0
    in_other = 0
  }
  END {
    if (bad) exit 1
    printf "%s", out
  }
'); then
  echo "  未解消の矛盾の記録を確認できないため停止します" >&2
  exit 1
fi

n_open=0
pairs=""
if [ -n "$entry" ]; then
  header=$(printf '%s\n' "$entry" | head -n 1)
  n_recorded=$(printf '%s\n' "$header" | sed -n -E 's/^\* \*\*lint:[a-z]+\*\* — contradictions=([0-9]+).*/\1/p')
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    pair=$(printf '%s\n' "$line" | sed -n -E \
      's#^[[:space:]]+[*-] 未解消の矛盾: \[[^]]+\]\((pages/(patterns|heuristics|anti-patterns)/[^/)]+\.md)\) ↔ \[[^]]+\]\((pages/(patterns|heuristics|anti-patterns)/[^/)]+\.md)\) — (タイトル衝突|方針逆転|重複情報): (.+)$#.rite/wiki/\1|.rite/wiki/\3|\5|\6#p')
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
