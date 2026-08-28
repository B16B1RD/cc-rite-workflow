#!/bin/bash
# orphan-reference-check.sh
# Detect orphan reference files in plugins/rite/ — files that exist but are
# not referenced from any other file under plugins/rite/, docs/, or .github/
# and have no test pin (tracked separately in plugins/rite/hooks/tests/ and
# plugins/rite/scripts/tests/) protecting their content.
#
# Motivation: a review revealed that
# `plugins/rite/commands/issue/references/projects-status-update-callsites.md`
# (146 lines) was an orphan SoT file with zero inbound references and no test
# pin, surviving for multiple workflow refactorings undetected. This guard
# catches the same class of orphan accumulation mechanically.
#
# An orphan is defined as:
#   1. File exists under plugins/rite/ (typically a reference doc)
#   2. Inbound references from active scope (plugins/rite/ + docs/ + .github/)
#      excluding self-references total exactly 0
#   3. No test pin (assert_grep / assert_contains for this filename) exists
#      in plugins/rite/hooks/tests/ or plugins/rite/scripts/tests/
#
# False-positive defense:
#   - Self-references (the file's own absolute or relative path mentioned
#     inside itself) are excluded from the inbound count.
#   - References inside HISTORICAL/retired/deletion annotations (e.g.,
#     `(※ 削除済 — #N で removed)`) still count as inbound — this script
#     does NOT distinguish marker context, treating any plain-text mention
#     as a legitimate documentation reference of past relationship.
#   - Files matching common static asset patterns (`.gitkeep`, `__init__.py`,
#     `LICENSE`, `CHANGELOG.md`) are skipped entirely.
#   - --all mode excludes runtime/local artifact directories (`.git/`,
#     `.rite/`, `.rite-work-memory/`, `.rite/work-memory/`, `.rite-flow-state*`,
#     `.rite-compact-state*`, `node_modules/`) from the find walk.
#
# Usage:
#   orphan-reference-check.sh <file> [<file> ...]
#   orphan-reference-check.sh --all [--repo-root DIR]
#
#   --all expands to every `plugins/rite/{references,skills,agents}/**/*.md`
#   file under the resolved repository root. Use this from /rite:lint to enforce
#   the guard across every reference doc in a single invocation.
#
#   --repo-root DIR overrides the repository root resolution (default:
#   `git rev-parse --show-toplevel`, falling back to `pwd`).
#
# Note: `--quiet` is not implemented (unlike sibling lint scripts such as
# `gitignore-health-check.sh`). lint.md Phase 3.15 captures both the
# `[orphan-reference-check] checked=N orphans=M` summary line and the
# `ORPHAN: path (...)` per-orphan lines into the warning appendix, so
# suppressing the summary is not desirable for the canonical use case.
#
# Exit codes:
#   0 - No orphans found
#   1 - One or more orphans detected (printed to stderr with file path)
#   2 - Usage error (no arguments / file not found / --all expansion empty / invalid --repo-root)

set -euo pipefail

if [ $# -eq 0 ]; then
  echo "Usage: $0 [--all] [--repo-root DIR] <file> [<file> ...]" >&2
  exit 2
fi

# Parse common flags (--repo-root + --all) from anywhere in argv. Remaining
# positional args become the file list (or, with --all, are appended after
# expansion).
REPO_ROOT=""
USE_ALL=0
POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    --all)
      USE_ALL=1
      shift
      ;;
    --repo-root)
      shift
      if [ $# -eq 0 ]; then
        echo "ERROR: --repo-root requires a directory argument" >&2
        exit 2
      fi
      REPO_ROOT="$1"
      shift
      ;;
    --)
      shift
      while [ $# -gt 0 ]; do POSITIONAL+=("$1"); shift; done
      ;;
    -*)
      echo "ERROR: unknown flag: $1" >&2
      exit 2
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
# Strip trailing slash for consistent ${abs_path#$REPO_ROOT/} stripping
REPO_ROOT="${REPO_ROOT%/}"
if [ ! -d "$REPO_ROOT" ]; then
  echo "ERROR: repo-root not a directory: $REPO_ROOT" >&2
  exit 2
fi

if [ "$USE_ALL" -eq 1 ]; then
  FILES=()
  # find は REPO_ROOT 相対で走査し、結果に REPO_ROOT を再付加して絶対パス化する。
  # セッション worktree (.rite/worktrees/issue-N) では REPO_ROOT 自体のパスに
  # `/.rite/` セグメントが含まれるため、絶対パス基準で `-not -path "*/.rite/*"` を
  # 適用すると配下の全ファイルが誤って除外され `--all expansion empty` (exit 2) に
  # 陥る。相対パス基準なら除外パターンは plugins/rite 配下にネストした成果物
  # ディレクトリのみに作用し、通常 checkout との走査結果も一致する。
  while IFS= read -r f; do
    FILES+=("$REPO_ROOT/$f")
  done < <(cd "$REPO_ROOT" && find "plugins/rite" \
    -not -path "*/.git/*" \
    -not -path "*/.rite/*" \
    -not -path "*/.rite-work-memory/*" \
    -not -path "*/.rite/work-memory/*" \
    -not -path "*/.rite-flow-state*" \
    -not -path "*/.rite-compact-state*" \
    -not -path "*/node_modules/*" \
    \( -path "*/references/*" -o -path "*/skills/*" -o -path "*/agents/*" \) \
    -name "*.md" -type f 2>/dev/null | sort)
  if [ ${#FILES[@]} -eq 0 ]; then
    echo "ERROR: --all expansion empty (no plugins/rite/**/*.md files found under $REPO_ROOT)" >&2
    exit 2
  fi
  # Prepend expanded files; user-supplied positional args are appended after.
  if [ ${#POSITIONAL[@]} -gt 0 ]; then
    FILES+=("${POSITIONAL[@]}")
  fi
  set -- "${FILES[@]}"
else
  if [ ${#POSITIONAL[@]} -eq 0 ]; then
    echo "Usage: $0 [--all] [--repo-root DIR] <file> [<file> ...]" >&2
    exit 2
  fi
  set -- "${POSITIONAL[@]}"
fi

ORPHAN_COUNT=0
CHECKED_COUNT=0

for file in "$@"; do
  CHECKED_COUNT=$((CHECKED_COUNT + 1))
  if [ ! -f "$file" ]; then
    echo "ERROR: file not found: $file" >&2
    exit 2
  fi

  # Resolve absolute and repo-relative paths
  abs_path=$(cd "$(dirname "$file")" && pwd)/$(basename "$file")
  rel_path="${abs_path#$REPO_ROOT/}"
  basename=$(basename "$file")

  # Skip well-known static assets (whole-name match against basename, not path
  # — `__init__.py` substring match must not skip files like `__init__.py.md`
  # that happen to contain the substring elsewhere)
  case "$basename" in
    .gitkeep|__init__.py|LICENSE|CHANGELOG.md)
      continue
      ;;
  esac

  # Count inbound references from active scope.
  # Search in: plugins/rite/, docs/, .github/ — exclude:
  #   - the file itself (self-reference)
  #   - any path containing `tests/` (via grep --exclude-dir=tests below).
  #     This covers plugins/rite/hooks/tests/ + plugins/rite/scripts/tests/
  #     + any other tests/ subtree under the search dirs (e.g., docs/tests/
  #     which currently holds 8 markdown test fixtures plus 1 README and is
  #     excluded the same way). test_pin_count tracks plugins/rite/hooks/tests/
  #     and plugins/rite/scripts/tests/ only — those are the official test pin
  #     locations. Other tests/ directories are simply excluded from inbound
  #     count to avoid double-counting and to keep the (inbound=N, test_pin=M)
  #     annotation semantically clean.
  inbound_count=0
  search_dirs=()
  [ -d "$REPO_ROOT/plugins/rite" ] && search_dirs+=("$REPO_ROOT/plugins/rite")
  [ -d "$REPO_ROOT/docs" ] && search_dirs+=("$REPO_ROOT/docs")
  [ -d "$REPO_ROOT/.github" ] && search_dirs+=("$REPO_ROOT/.github")

  if [ ${#search_dirs[@]} -gt 0 ]; then
    # grep for basename (broader than full path — captures relative refs)
    # then post-filter to exclude self-matches
    while IFS= read -r match_line; do
      # match_line format: <path>:<line_no>:<content>
      match_file="${match_line%%:*}"
      # Self-reference exclusion: skip if match is in the file itself
      if [ "$match_file" = "$abs_path" ]; then
        continue
      fi
      inbound_count=$((inbound_count + 1))
    done < <(grep -rn -F "$basename" "${search_dirs[@]}" \
                --include='*.md' --include='*.sh' --include='*.json' \
                --include='*.yml' --include='*.yaml' --include='*.txt' \
                --exclude-dir=tests \
                2>/dev/null || true)
    # --exclude-dir=tests prevents double-counting: test pin matches are
    # tracked separately below and would otherwise be reported as both
    # inbound and test_pin, making the `(inbound=N, test_pin=M)` annotation
    # misleading. Inbound count reflects production references only.
  fi

  # Check for test pin (assert_grep / contains with filename in tests/)
  # set -o pipefail 下では grep no-match (exit 1) → pipeline 全体 fail → set -e abort
  # を防ぐため `|| true` で吸収。さらに wc -l も pipeline 末尾で no-match を pre-empt
  # するため、grep を独立変数 capture に分離する。
  test_pin_count=0
  test_dirs=()
  [ -d "$REPO_ROOT/plugins/rite/hooks/tests" ] && test_dirs+=("$REPO_ROOT/plugins/rite/hooks/tests")
  [ -d "$REPO_ROOT/plugins/rite/scripts/tests" ] && test_dirs+=("$REPO_ROOT/plugins/rite/scripts/tests")
  if [ ${#test_dirs[@]} -gt 0 ]; then
    grep_out=""
    grep_out=$(grep -rl -F "$basename" "${test_dirs[@]}" 2>/dev/null || true)
    if [ -n "$grep_out" ]; then
      test_pin_count=$(printf '%s\n' "$grep_out" | wc -l | tr -d '[:space:]')
      case "$test_pin_count" in ''|*[!0-9]*) test_pin_count=0 ;; esac
    fi
  fi

  if [ "$inbound_count" -eq 0 ] && [ "$test_pin_count" -eq 0 ]; then
    echo "ORPHAN: $rel_path (inbound=0, test_pin=0)" >&2
    ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
  fi
done

echo "[orphan-reference-check] checked=$CHECKED_COUNT orphans=$ORPHAN_COUNT" >&2

if [ "$ORPHAN_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
