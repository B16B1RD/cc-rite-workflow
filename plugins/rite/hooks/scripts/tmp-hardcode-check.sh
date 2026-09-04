#!/usr/bin/env bash
# tmp-hardcode-check.sh
#
# Detect sandbox-incompatible patterns in rite plugin markdown / shell sources
# (recurrence guard). Under the Claude Code bash sandbox, writes are
# restricted to $TMPDIR (e.g. /tmp/claude-<uid>/...) and /tmp itself is mounted
# read-only, while `.git/config` writes are always denied (harness built-in
# protection). Three pattern families regressed repeatedly across sweeps
# (-> -> ->), so this check pins all of them:
#
#   P1: mktemp with a /tmp-prefixed template
#       regex: mktemp + optional flags (-d 等) + optional quote + /tmp/
#       Fails under sandbox with "read-only file system". Safe form:
#         mktemp "${TMPDIR:-/tmp}/rite-...-XXXXXX"
#       The safe form never places `/tmp/` directly after the (optionally
#       quoted) template start — the parameter expansion `${TMPDIR:-` always
#       interposes — so it never matches even in quoted / flagged variants.
#
#   P2: fixed /tmp path hardcode (assignment / redirect / -file option)
#       regex: =["']?/tmp/  |  >[[:space:]]*["']?/tmp/  |  -file[[:space:]]+["']?/tmp/
#       Direct writes to /tmp-fixed paths die under sandbox; option guidance
#       (`--content-file /tmp/...`) steers callers into the same failure.
#       Quoted variants (="/tmp/..., ='/tmp/...') and unquoted (=/tmp/...) are
#       all matched. Safe form: "${TMPDIR:-/tmp}/rite-..." (never matches —
#       `/tmp/` never directly follows the =/>/-file + optional quote position
#       in the parameter-expansion form).
#
#   P3: git push with upstream tracking (-u / --set-upstream)
#       regex: git push + optional interposed flags + (-u | --set-upstream)
#       The upstream write hits the always-denied .git/config protection and
#       makes an otherwise-successful push exit non-zero. `git stash push -u`
#       (include-untracked stash) is a different command and does NOT match:
#       the interposed "stash" word breaks the `git push` token sequence.
#       Known boundary: combined short flags (`-qu`) and the flag-after-refspec
#       form (`git push origin -u branch`) are not detected — the regex only
#       allows flag-shaped tokens between `git push` and `-u`/`--set-upstream`.
#
# Scan scope: plugins/rite/**/*.{md,sh} plus docs/**/*.md when present.
# Exclusions:
# - */tests/*: test harnesses run outside the sandbox (tracked as)
#   - references/gh-cli-error-catalog.md : intentional error-illustration examples
#   - this script itself (pattern definitions would self-match)
#
# Usage:
#   tmp-hardcode-check.sh [--all] [--target FILE]... [--repo-root DIR] [--quiet]
#                         [--skip-if-no-target]
#
# Exit codes: 0 = clean (or not-applicable skip), 1 = pattern detected,
#             2 = invocation error.

set -uo pipefail

REPO_ROOT=""
QUIET=0
declare -a TARGETS=()
USE_ALL=0
SKIP_IF_NO_TARGET=0

usage() {
  cat <<'EOF'
Usage: tmp-hardcode-check.sh [options]

Options:
  --all              Scan plugins/rite/**/*.{md,sh} and docs/**/*.md
  --target FILE      Check FILE (repeatable). Path relative to repo root.
  --repo-root DIR    Repository root (default: git rev-parse --show-toplevel)
  --quiet            Suppress progress/summary log lines on stderr
  --skip-if-no-target
                     With --all, exit 0 (not 2) when no scan directory exists
                     under the repo root (consumer-repo marketplace install).
  -h, --help         Show this help

Exit codes:
  0  No sandbox-incompatible pattern detected (or not-applicable skip)
  1  Pattern detected
  2  Invocation error (bad args, missing files)
EOF
}

log() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --all) USE_ALL=1; shift ;;
    --target)
      [ $# -ge 2 ] || { echo "ERROR: --target requires a value" >&2; usage >&2; exit 2; }
      TARGETS+=("$2"); shift 2 ;;
    --repo-root)
      [ $# -ge 2 ] || { echo "ERROR: --repo-root requires a value" >&2; usage >&2; exit 2; }
      REPO_ROOT="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    --skip-if-no-target) SKIP_IF_NO_TARGET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
cd "$REPO_ROOT" || { echo "ERROR: cannot cd to $REPO_ROOT" >&2; exit 2; }

# 明示 --target の存在検査 (usage の「2 = Invocation error (bad args, missing files)」契約
# に実装を一致させる)。この時点の TARGETS は明示 --target 値のみ (--all の find 追加は後段で、
# find(1) は不在エントリを生成しない)。check_file 内の [ ! -f ] は TOCTOU backstop として残す。
if [ "${#TARGETS[@]}" -gt 0 ]; then
  for t in "${TARGETS[@]}"; do
    [ -f "$t" ] || { echo "ERROR: target not found: $t" >&2; exit 2; }
  done
fi

SELF_REL="plugins/rite/hooks/scripts/tmp-hardcode-check.sh"

if [ "$USE_ALL" -eq 1 ]; then
  for d in "plugins/rite" "docs"; do
    [ -d "$d" ] || echo "WARNING: $d not found under $REPO_ROOT (skipped)" >&2
  done
  # docs/ だけの環境 (plugins/rite 不在) は gate 対象の rite ソースが無い
  if [ ! -d "plugins/rite" ]; then
    if [ "$SKIP_IF_NO_TARGET" -eq 1 ]; then
      echo "[tmp-hardcode] not applicable: no plugins/rite under $REPO_ROOT — clean skip (--skip-if-no-target)" >&2
      exit 0
    fi
    echo "ERROR: --all requested but plugins/rite does not exist under $REPO_ROOT" >&2
    echo "  Likely cause: invoked outside the rite plugin repo (e.g. marketplace install)" >&2
    echo "  Recovery: run from the rite plugin source tree, pass --target FILE, or pass --skip-if-no-target" >&2
    exit 2
  fi
  # docs は documented scope どおり *.md のみ (plugins/rite は *.md + *.sh)
  while IFS= read -r f; do
    case "$f" in
      */tests/*) continue ;;
      plugins/rite/references/gh-cli-error-catalog.md) continue ;;
      "$SELF_REL") continue ;;
    esac
    TARGETS+=("$f")
  done < <( { find plugins/rite -type f \( -name '*.md' -o -name '*.sh' \); \
              [ -d docs ] && find docs -type f -name '*.md'; } 2>/dev/null | sort)
fi

if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "ERROR: no targets specified (use --all or --target FILE)" >&2
  usage >&2
  exit 2
fi

FINDINGS_FILE="$(mktemp)" || { echo "ERROR: mktemp failed" >&2; exit 2; }
trap 'rm -f "$FINDINGS_FILE"' EXIT

check_file() {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo "WARNING: target not found: $file" >&2
    return 0
  fi
  # 読み取り不能ファイルが grep rc=2 → silent clean 化するのを防ぐ (loud に skip する)
  if [ ! -r "$file" ]; then
    echo "WARNING: target not readable: $file" >&2
    return 0
  fi
  # P1: mktemp + /tmp template (flag 介在・quote 付きバリアントも検出)。
  # ${TMPDIR:-/tmp} 形式は quote 直後が `/tmp/` にならないため構造的に除外される
  grep -nE 'mktemp[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*["'"'"']?/tmp/' "$file" 2>/dev/null | while IFS=: read -r ln _; do
    printf '[tmp-hardcode][P1] %s:%s: mktemp /tmp template (sandbox read-only) — use mktemp "${TMPDIR:-/tmp}/..."\n' "$file" "$ln"
  done >> "$FINDINGS_FILE"
  # P2: fixed /tmp path (assignment / redirect / -file option)。quote 有無の両形を検出。
  # ${TMPDIR:-/tmp} 形式は =/>/-file + optional quote の直後に `/tmp/` が来ないため除外される
  grep -nE '=["'"'"']?/tmp/|>[[:space:]]*["'"'"']?/tmp/|-file[[:space:]]+["'"'"']?/tmp/' "$file" 2>/dev/null | while IFS=: read -r ln _; do
    printf '[tmp-hardcode][P2] %s:%s: fixed /tmp path hardcode (sandbox read-only) — use "${TMPDIR:-/tmp}/..."\n' "$file" "$ln"
  done >> "$FINDINGS_FILE"
  # P3: git push -u / --set-upstream (upstream 書込は .git/config 保護で常時拒否)。
  # flag 介在形 (git push --force -u 等) も検出。`git stash push -u` は token 列が異なりマッチしない。
  # Known boundary: 結合短形 (-qu) と refspec 後置形 (git push origin -u branch) は非検出 (docstring 参照)
  grep -nE 'git push[[:space:]]+(-[a-zA-Z-]+[[:space:]]+)*(-u|--set-upstream)([[:space:]]|$)' "$file" 2>/dev/null | while IFS=: read -r ln _; do
    printf '[tmp-hardcode][P3] %s:%s: git push -u/--set-upstream (upstream write denied under sandbox) — drop it\n' "$file" "$ln"
  done >> "$FINDINGS_FILE"
}

log "Scanning ${#TARGETS[@]} file(s)..."
for t in "${TARGETS[@]}"; do
  check_file "$t"
done

if [ -s "$FINDINGS_FILE" ]; then
  cat "$FINDINGS_FILE"
  # BSD/macOS の wc -l は先頭空白パディングを付けるため正規化する (lint 側の
  # count-line regex `findings: (\d+)` が padding で不一致になるのを防ぐ)
  total=$(wc -l < "$FINDINGS_FILE" | tr -d '[:space:]')
else
  total=0
fi
log "==> Total tmp-hardcode findings: ${total}"

if [ "$total" -gt 0 ]; then
  exit 1
fi
exit 0
