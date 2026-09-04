#!/usr/bin/env bash
# comment-journal-check.sh
#
# Detect high-confidence "journal" narration patterns in plugins/rite/**/*.{sh,md},
# repo-root docs/**/*.md, and .rite/wiki/**/*.md. These are mechanical comment
# violations that accumulate when authors paste review-cycle / fix-history wording
# into persistent artifacts (code / docs prose / Wiki) instead of into commit
# messages or PR descriptions.
#
# `.rite/wiki/**` に届く条件 (wiki.branch_strategy 依存):
#   same_branch     Wiki の実体が dev ブランチのワークツリーにあるため、pages / index.md /
#                   log.md / raw のすべてに到達する。
#   separate_branch Wiki ページ (pages/ / index.md) の実体は wiki ブランチにあり到達しない。
#                   ただし dev checkout の `.rite/wiki/raw/` には ingest 待ちの Raw Source が
#                   一時的に実在する (wiki-ingest-trigger が書き、wiki-ingest-commit が wiki
#                   ブランチへ移すまでの窓) ため、その間は raw 由来の検出が出うる。
#   ここでは wiki ブランチを読みに行かない。本スクリプトはワークツリー上のファイルを
#   走査する CI 向けの高速レイヤであり、ブランチ解決を持ち込むと検出責務が二重化する。
#   separate_branch で Wiki ページ分の指摘が 0 件でも「Wiki が clean」ではなく
#   「本スクリプトの走査範囲外」である点に注意する。
#
# Layered defense:
#   This script is the fast-fail layer below the LLM reviewers. The reviewers
#   focus on WHY > WHAT semantic judgments; mechanical 100%-confidence patterns
#   are killed here before they reach the reviewer queue. Operationally invoked
#   from /rite:lint (manual). PR review integration is intentionally out of
#   scope (採択方針: CI のみ運用).
#
# Detected patterns (4 regexes scanned in a single while-match awk loop, so
# multiple triggers on the same line are all reported — same multi-match
# discipline as bang-backtick-check.sh):
#
#   P1: verified-review cycle N
#       regex: verified-review cycle [0-9]+
#       semantics: leftover narration referring to a verified-review iteration.
#                  The iteration number drifts as soon as cycles add up; the
#                  reference becomes wrong-but-confident over time.
#
#   P2: 旧実装(は|では) - "the old implementation (was|did)"
#       regex: 旧実装(は|では)
#       semantics: comments that explain what the previous version did. The
#                  WHAT of removed code belongs in commit/PR history, not in
#                  the tree where it ages out of sync with the current code.
#
#   P3: PR #N cycle N fix
#       regex: PR #[0-9]+ cycle [0-9]+ fix
#       semantics: comments tagging a fix to a specific PR review cycle. PR
#                  numbers carry no meaning at read time; the cycle number
#                  is tied to a workflow run that no longer exists.
#
#   P4: cycle N F-N で(導入|確立|集約) - "introduced/established/consolidated in cycle N F-N"
#       regex: cycle [0-9]+ F-[0-9]+ で(導入|確立|集約)
#       semantics: comments referencing review-finding identifiers (F-NN).
#                  Finding IDs are scoped to one review run; the reference
#                  decays the moment that review is closed.
#
# Whitelist (line-level skip):
#
#   Lines containing any of the following markers are skipped entirely:
#     - <!-- example: ...    (markdown HTML-comment example marker)
#     - # example: ...        (shell / Python comment example marker)
#     - // example: ...       (TypeScript / JavaScript comment example marker)
#     - TODO / FIXME          (P1-P4 のジャーナル叙述対象外。番号例外ではない)
#
#   Self-exclusion: this script's own regex literals would otherwise match.
#   When --all is requested the find walk skips (1) this script's own path,
#   (2) the SoT 本体 comment-best-practices.md, (3) parity test
#   comment-best-practices-parity.test.sh, and (4) 検出器自身の test
#   (comment-journal-check.test.sh) —
#   (2)-(4) は禁止句を「定義・例示」する性質上、走査すると Bad 例の語句 (test では
#   fixture 文字列) が本物の違反として誤検出されるため除外する。
#
# Future extension: rite-config.yml workflow.lint.comment_journal.whitelist
# can list extra prefix tokens. Not implemented in this revision; the prefix
# markers above already cover SoT bad-example sections when the author wraps
# the example with one of the three markers.
#
# Usage:
#   comment-journal-check.sh [--all] [--target FILE]... [--repo-root DIR] [--quiet]
#
# Exit codes: 0 = clean, 1 = pattern detected, 2 = invocation error.

set -euo pipefail

REPO_ROOT=""
QUIET=0
declare -a TARGETS=()
USE_ALL=0

usage() {
  cat <<'EOF'
Usage: comment-journal-check.sh [options]

Options:
  --all              Scan plugins/rite/**/*.sh and plugins/rite/**/*.md
  --target FILE      Check FILE (repeatable). Path relative to repo root.
  --repo-root DIR    Repository root (default: git rev-parse --show-toplevel)
  --quiet            Suppress progress/summary log lines on stderr
  -h, --help         Show this help

Detected patterns:
  P1  verified-review cycle N
  P2  旧実装(は|では)
  P3  PR #N cycle N fix
  P4  cycle N F-N で(導入|確立|集約)

Whitelist markers (line-level skip):
  <!-- example:    /    # example:    /    // example:    /    TODO / FIXME

Scan scope (--all):
  plugins/rite/**/*.{sh,md}, docs/**/*.md, .rite/wiki/**/*.md
  (self-exclude: this script, comment-best-practices.md SoT, parity test,
   検出器自身の test: comment-journal-check.test.sh)
  .rite/wiki/ の Wiki ページ (pages/ / index.md) に到達するのは same_branch 構成のみ。
  separate_branch では wiki ブランチにあるため走査しないが、ingest 待ちの Raw Source が
  .rite/wiki/raw/ に一時的に実在する窓では raw 由来の検出が出うる。

Exit codes:
  0  No journal narration detected
  1  Pattern detected
  2  Invocation error
EOF
}

log() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --all) USE_ALL=1; shift ;;
    --target) TARGETS+=("$2"); shift 2 ;;
    --repo-root) REPO_ROOT="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
cd "$REPO_ROOT" || { echo "ERROR: cannot cd to $REPO_ROOT" >&2; exit 2; }

if [ "$USE_ALL" -eq 1 ]; then
  base="plugins/rite"
  if [ ! -d "$base" ]; then
    echo "ERROR: --all requested but $base does not exist under $REPO_ROOT" >&2
    echo "  Likely cause: invoked outside the rite plugin repo (e.g. marketplace install)" >&2
    echo "  Recovery: run from the rite plugin source tree, or pass --target FILE explicitly" >&2
    exit 2
  fi
  # ジャーナル叙述は永続成果物全般 (in-source コメント + ドキュメント散文 + Wiki ページ) が対象であり、
  # plugins/rite に加えて repo-root の docs/ と .rite/wiki/ も走査する。後二者は存在するときのみ加える
  # (marketplace install や Wiki 無効プロジェクトでは plugins/rite のみで走査が成立する)。
  # `.rite/wiki/` に Wiki ページの実体があるのは wiki.branch_strategy: same_branch のときだけ。
  # separate_branch では不在なら scan_root に加わらず、空ディレクトリなら加わるが対象は 0 件になる。
  # ただし ingest 待ちの Raw Source が `.rite/wiki/raw/` に一時的に置かれる窓ではそれが走査対象に入る。
  scan_roots=("$base")
  [ -d "docs" ] && scan_roots+=("docs")
  [ -d ".rite/wiki" ] && scan_roots+=(".rite/wiki")
  self_abs="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"
  self_rel=""
  case "$self_abs" in
    "$REPO_ROOT"/*) self_rel="${self_abs#"$REPO_ROOT"/}" ;;
  esac
  while IFS= read -r f; do
    # 定義ファイルの self-exclusion: スクリプト自身に加え、禁止句を「例示として保持する」SoT 本体と
    # parity test を除外する。これらは禁止句リストを定義する性質上、走査すると definitional な例
    # (Bad 例の語句) が本物の違反として誤検出される。
    case "$f" in
      "$self_rel") continue ;;
      plugins/rite/skills/rite-workflow/references/comment-best-practices.md) continue ;;
      plugins/rite/hooks/tests/comment-best-practices-parity.test.sh) continue ;;
      plugins/rite/hooks/tests/comment-journal-check.test.sh) continue ;;
    esac
    TARGETS+=("$f")
  done < <(find "${scan_roots[@]}" -type f \( -name '*.sh' -o -name '*.md' \) 2>/dev/null | sort)
fi

if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "ERROR: no targets specified (use --all or --target FILE)" >&2
  usage >&2
  exit 2
fi

FINDINGS_FILE=""
_rite_journal_cleanup() {
  rm -f "${FINDINGS_FILE:-}"
}
trap 'rc=$?; _rite_journal_cleanup; exit $rc' EXIT
trap '_rite_journal_cleanup; exit 130' INT
trap '_rite_journal_cleanup; exit 143' TERM
trap '_rite_journal_cleanup; exit 129' HUP

FINDINGS_FILE="$(mktemp)" || { echo "ERROR: mktemp failed" >&2; exit 2; }

# Single awk pass per file. Whitelist check happens up-front; the four pattern
# scans share the same while-match loop idiom so multi-match per line is
# preserved (parity with bang-backtick-check.sh).
check_file() {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo "WARNING: target not found: $file" >&2
    return 0
  fi
  awk -v F="$file" '
    {
      line = $0
      # Whitelist: any line carrying an "example:" marker is skipped wholesale.
      if (line ~ /(<!--[[:space:]]*example:|#[[:space:]]+example:|\/\/[[:space:]]+example:)/) next
      # TODO/FIXME 行は P1-P4 のジャーナル叙述対象外としてスキップする（番号例外ではない）。
      if (line ~ /(TODO|FIXME)/) next

      # P1: verified-review cycle N
      pos = 1
      while (pos <= length(line)) {
        rest = substr(line, pos)
        if (!match(rest, /verified-review cycle [0-9]+/)) break
        print "[comment-journal][P1] " F ":" NR ": verified-review cycle reference: " substr(rest, RSTART, RLENGTH)
        pos = pos + RSTART + RLENGTH - 1
      }

      # P2: 旧実装(は|では)
      pos = 1
      while (pos <= length(line)) {
        rest = substr(line, pos)
        if (!match(rest, /旧実装(は|では)/)) break
        print "[comment-journal][P2] " F ":" NR ": legacy-impl narration: " substr(rest, RSTART, RLENGTH)
        pos = pos + RSTART + RLENGTH - 1
      }

      # P3: PR #N cycle N fix
      pos = 1
      while (pos <= length(line)) {
        rest = substr(line, pos)
        if (!match(rest, /PR #[0-9]+ cycle [0-9]+ fix/)) break
        print "[comment-journal][P3] " F ":" NR ": PR cycle fix narration: " substr(rest, RSTART, RLENGTH)
        pos = pos + RSTART + RLENGTH - 1
      }

      # P4: cycle N F-N で(導入|確立|集約)
      pos = 1
      while (pos <= length(line)) {
        rest = substr(line, pos)
        if (!match(rest, /cycle [0-9]+ F-[0-9]+ で(導入|確立|集約)/)) break
        print "[comment-journal][P4] " F ":" NR ": review-finding narration: " substr(rest, RSTART, RLENGTH)
        pos = pos + RSTART + RLENGTH - 1
      }
    }
  ' "$file" >> "$FINDINGS_FILE"
}

log "Scanning ${#TARGETS[@]} file(s)..."
for t in "${TARGETS[@]}"; do
  check_file "$t"
done

if [ -s "$FINDINGS_FILE" ]; then
  cat "$FINDINGS_FILE"
  total=$(wc -l < "$FINDINGS_FILE")
else
  total=0
fi
log "==> Total comment-journal findings: ${total}"

if [ "$total" -gt 0 ]; then
  exit 1
fi
exit 0
