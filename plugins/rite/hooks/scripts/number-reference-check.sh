#!/usr/bin/env bash
# number-reference-check.sh
#
# Detect bare Issue/PR number tokens (`#[0-9]{3,4}`) in persistent artifacts.
# Grammar and exclusion rules live only here. Callers must not copy the regex.
#
# Modes (exactly one):
#   --all                 git ls-files 全件 − 除外パス
#   --diff <base_ref>     git diff <base_ref> の追加行（未 commit を含む）
#   --stdin --label NAME  stdin を NAME として走査（除外パスなら走査しない）
#
# Detected: a 3-4 digit hash-number token. This subsumes `Issue #NNN` /
# `PR #NNN` (the `#NNN` substring matches). 1-2 digit tokens and 5+ digit
# tokens are not matched.
#
# Line-level exclusions:
#   - token is the literal placeholder #123
#   - token is immediately followed by -[A-Za-z] (markdown heading anchors)
#   - line contains the marker drift-check-ignore
#
# Path exclusions:
#   - .rite/wiki/raw/**
#   - plugins/rite/scripts/tests/fixtures/**
#   - plugins/rite/hooks/tests/number-reference-check.test.sh
#   - plugins/rite/hooks/tests/comment-journal-check.test.sh
#   - plugins/rite/hooks/tests/wiki-lint-descriptive-refs.test.sh
#
# Output:
#   findings → stdout  as  file:line: matched line
#   summary  → stderr  as  Total number-ref findings: N
#
# Exit codes: 0 = clean, 1 = reference detected, 2 = usage or git failure.

set -uo pipefail

REPO_ROOT=""
QUIET=0
MODE=""
DIFF_BASE=""
STDIN_LABEL=""

usage() {
  cat <<'EOF'
Usage: number-reference-check.sh --all [--repo-root DIR] [--quiet]
       number-reference-check.sh --diff <base_ref> [--repo-root DIR] [--quiet]
       number-reference-check.sh --stdin --label <name> [--quiet]

Options:
  --all              Scan all git-tracked files minus path exclusions
  --diff BASE        Scan added lines of git diff BASE (includes uncommitted)
  --stdin            Scan stdin (requires --label)
  --label NAME       Path label for --stdin findings
  --repo-root DIR    Repository root (default: git rev-parse --show-toplevel)
  --quiet            Suppress progress lines on stderr (summary still emitted)
  -h, --help         Show this help

Detected: #[0-9]{3,4} tokens (Issue/PR number references).
Exclusions: placeholder #123, markdown anchors (#NNN-letter), drift-check-ignore,
            wiki raw, script fixtures, detector test files.

Exit codes:
  0  No reference detected
  1  Reference detected
  2  Invocation error or git failure
EOF
}

log() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*" >&2; }

set_mode() {
  local next="$1"
  if [ -n "$MODE" ] && [ "$MODE" != "$next" ]; then
    echo "ERROR: modes --all, --diff, and --stdin are mutually exclusive" >&2
    usage >&2
    exit 2
  fi
  MODE="$next"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --all) set_mode all; shift ;;
    --diff)
      set_mode diff
      DIFF_BASE="${2:-}"
      if [ -z "$DIFF_BASE" ] || [ "${DIFF_BASE#-}" != "$DIFF_BASE" ]; then
        echo "ERROR: --diff requires a base ref" >&2
        usage >&2
        exit 2
      fi
      shift 2
      ;;
    --stdin) set_mode stdin; shift ;;
    --label)
      STDIN_LABEL="${2:-}"
      if [ -z "$STDIN_LABEL" ]; then
        echo "ERROR: --label requires a name" >&2
        usage >&2
        exit 2
      fi
      shift 2
      ;;
    --repo-root)
      REPO_ROOT="${2:-}"
      if [ -z "$REPO_ROOT" ]; then
        echo "ERROR: --repo-root requires a directory" >&2
        exit 2
      fi
      shift 2
      ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$MODE" ]; then
  echo "ERROR: no mode specified (use --all, --diff BASE, or --stdin --label NAME)" >&2
  usage >&2
  exit 2
fi

if [ "$MODE" = "stdin" ] && [ -z "$STDIN_LABEL" ]; then
  echo "ERROR: --stdin requires --label" >&2
  usage >&2
  exit 2
fi
if [ "$MODE" != "stdin" ] && [ -n "$STDIN_LABEL" ]; then
  echo "ERROR: --label is only valid with --stdin" >&2
  usage >&2
  exit 2
fi

if [ "$MODE" != "stdin" ]; then
  if [ -z "$REPO_ROOT" ]; then
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
      echo "ERROR: repository root could not be resolved" >&2
      exit 2
    }
  fi
  if [ ! -d "$REPO_ROOT" ]; then
    echo "ERROR: repo-root not a directory: $REPO_ROOT" >&2
    exit 2
  fi
  cd "$REPO_ROOT" || { echo "ERROR: cannot cd to $REPO_ROOT" >&2; exit 2; }
fi

# Path exclusion. Grammar SoT is this function only.
is_excluded_path() {
  local p="$1"
  p="${p#./}"
  case "$p" in
    .rite/wiki/raw|.rite/wiki/raw/*) return 0 ;;
    plugins/rite/scripts/tests/fixtures|plugins/rite/scripts/tests/fixtures/*) return 0 ;;
    plugins/rite/hooks/tests/number-reference-check.test.sh) return 0 ;;
    plugins/rite/hooks/tests/comment-journal-check.test.sh) return 0 ;;
    plugins/rite/hooks/tests/wiki-lint-descriptive-refs.test.sh) return 0 ;;
  esac
  return 1
}

is_binary_file() {
  local f="$1"
  [ -f "$f" ] || return 1
  grep -qI '' "$f" 2>/dev/null
  case $? in
    0) return 1 ;;
    1) return 0 ;;
    *) return 1 ;;
  esac
}

# Grammar SoT: this awk function only (duplicated in scan_diff, not copied to other files).
awk_has_hit_and_emit() {
  local file="$1"
  awk -v file="$file" '
    function has_hit(s,    i, j, n, tok, nxt, nxt2) {
      i = 1
      while (i <= length(s)) {
        if (substr(s, i, 1) != "#") { i++; continue }
        j = i + 1
        n = 0
        while (j <= length(s) && substr(s, j, 1) ~ /[0-9]/) {
          n++
          j++
        }
        if (n >= 5) { i = j; continue }
        if (n >= 3 && n <= 4) {
          tok = substr(s, i, n + 1)
          if (tok == "#123") { i = j; continue }
          nxt = (j <= length(s)) ? substr(s, j, 1) : ""
          nxt2 = (j + 1 <= length(s)) ? substr(s, j + 1, 1) : ""
          if (nxt == "-" && nxt2 ~ /[A-Za-z]/) { i = j; continue }
          return 1
        }
        i++
      }
      return 0
    }
    {
      if (index($0, "drift-check-ignore") > 0) next
      if (has_hit($0)) printf "%s:%d: %s\n", file, NR, $0
    }
  '
}

count_lines() {
  local s="$1"
  if [ -z "$s" ]; then
    echo 0
    return 0
  fi
  printf '%s\n' "$s" | grep -c .
}

emit_findings() {
  local out="$1"
  [ -n "$out" ] && printf '%s\n' "$out"
}

scan_file() {
  local file="$1"
  if is_excluded_path "$file"; then
    return 0
  fi
  if [ ! -f "$file" ]; then
    return 0
  fi
  if is_binary_file "$file"; then
    return 0
  fi
  local out hits
  out=$(awk_has_hit_and_emit "$file" < "$file") || {
    echo "ERROR: scanner failed for $file" >&2
    exit 2
  }
  emit_findings "$out"
  hits=$(count_lines "$out")
  total=$((total + hits))
}

total=0

scan_all() {
  local list
  if ! list=$(git ls-files); then
    echo "ERROR: git ls-files failed" >&2
    exit 2
  fi
  local f n=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    n=$((n + 1))
    scan_file "$f"
  done <<< "$list"
  log "Scanning $n tracked file(s)..."
}

scan_diff() {
  local base="$1"
  if ! git rev-parse --verify "${base}^{commit}" >/dev/null 2>&1; then
    echo "ERROR: diff base could not be resolved: $base" >&2
    exit 2
  fi
  local diff_out
  if ! diff_out=$(git -c core.quotePath=false diff -U0 --no-color "$base"); then
    echo "ERROR: git diff failed for base: $base" >&2
    exit 2
  fi
  local hits
  hits=$(printf '%s\n' "$diff_out" | awk '
    function excluded(p) {
      if (p == ".rite/wiki/raw" || index(p, ".rite/wiki/raw/") == 1) return 1
      if (p == "plugins/rite/scripts/tests/fixtures" || index(p, "plugins/rite/scripts/tests/fixtures/") == 1) return 1
      if (p == "plugins/rite/hooks/tests/number-reference-check.test.sh") return 1
      if (p == "plugins/rite/hooks/tests/comment-journal-check.test.sh") return 1
      if (p == "plugins/rite/hooks/tests/wiki-lint-descriptive-refs.test.sh") return 1
      return 0
    }
    function has_hit(s,    i, j, n, tok, nxt, nxt2) {
      i = 1
      while (i <= length(s)) {
        if (substr(s, i, 1) != "#") { i++; continue }
        j = i + 1
        n = 0
        while (j <= length(s) && substr(s, j, 1) ~ /[0-9]/) {
          n++
          j++
        }
        if (n >= 5) { i = j; continue }
        if (n >= 3 && n <= 4) {
          tok = substr(s, i, n + 1)
          if (tok == "#123") { i = j; continue }
          nxt = (j <= length(s)) ? substr(s, j, 1) : ""
          nxt2 = (j + 1 <= length(s)) ? substr(s, j + 1, 1) : ""
          if (nxt == "-" && nxt2 ~ /[A-Za-z]/) { i = j; continue }
          return 1
        }
        i++
      }
      return 0
    }
    function unquote(p) {
      if (p ~ /^".*"$/) {
        sub(/^"/, "", p)
        sub(/"$/, "", p)
      }
      return p
    }
    /^diff --git / { skip = 0; path = ""; next }
    /^Binary files / { skip = 1; next }
    /^\+\+\+ / {
      rest = substr($0, 5)
      rest = unquote(rest)
      if (rest == "/dev/null") { skip = 1; path = ""; next }
      if (index(rest, "b/") == 1) rest = substr(rest, 3)
      path = rest
      skip = excluded(path)
      next
    }
    /^@@ / {
      if (match($0, /\+[0-9]+/)) line = substr($0, RSTART + 1, RLENGTH - 1) + 0
      else line = 0
      next
    }
    skip { next }
    path == "" { next }
    /^\+/ && !/^\+\+\+/ {
      content = substr($0, 2)
      if (index(content, "drift-check-ignore") == 0 && has_hit(content)) {
        printf "%s:%d: %s\n", path, line, content
      }
      line++
      next
    }
    /^-/ { next }
    /^\\/ { next }
    { if (line > 0) line++ }
  ')
  local awk_rc=$?
  if [ "$awk_rc" -ne 0 ]; then
    echo "ERROR: diff scanner failed" >&2
    exit 2
  fi
  emit_findings "$hits"
  total=$(count_lines "$hits")
}

scan_stdin() {
  local label="$STDIN_LABEL"
  label="${label#./}"
  if is_excluded_path "$label"; then
    total=0
    return 0
  fi
  local out
  out=$(awk_has_hit_and_emit "$label") || {
    echo "ERROR: scanner failed for $label" >&2
    exit 2
  }
  emit_findings "$out"
  total=$(count_lines "$out")
}

case "$MODE" in
  all) scan_all ;;
  diff) scan_diff "$DIFF_BASE" ;;
  stdin) scan_stdin ;;
esac

echo "Total number-ref findings: ${total}" >&2

if [ "$total" -gt 0 ]; then
  exit 1
fi
exit 0
