#!/usr/bin/env bash
# ja-symbol-check.sh
#
# Detect half-width symbols and label delimiters that violate the Japanese
# symbol rules in a body file about to be published (Issue / PR body).
# The rules live in references/ja-symbol-style.md; this script is their
# detector. Callers must not copy the patterns.
#
# Usage:
#   ja-symbol-check.sh --body-file <absolute path> --language <ja|en|auto>
#
# Scope:
#   - Only the upper section is checked: lines before the first `<details>`.
#     The folded contract layer holds machine-read fixed forms.
#   - Only lines that still contain Japanese after exclusions are checked.
#   - Excluded: code fences, inline code, URLs, ASCII paths, Markdown link
#     targets, HTML comments and tags, frontmatter, table separator rows, the
#     fixed `**用語**:` heading, commit trailers, and a leading
#     `type(scope):` of a Conventional Commits subject.
#   - `--language en` is not checked (exit 0). The script never rewrites the file.
#
# Detection kinds:
#   半角記号 / ラベルの半角コロン / ラベルの句点区切り
#
# Output:
#   findings → stdout as  行番号:検出種別:該当行
#
# Exit codes: 0 = clean (or language en), 1 = violation found,
#             2 = invalid arguments / unreadable, missing or empty file.

set -uo pipefail

usage() {
  cat <<'EOF'
Usage: ja-symbol-check.sh --body-file <absolute path> --language <ja|en|auto>

Exit codes: 0 = clean, 1 = violation found, 2 = invalid arguments or unreadable file
EOF
}

body_file=""
language=""
while [ $# -gt 0 ]; do
  case "$1" in
    --body-file) [ $# -ge 2 ] || { echo "ERROR: --body-file requires a value" >&2; usage >&2; exit 2; }
                 body_file="$2"; shift 2 ;;
    --language)  [ $# -ge 2 ] || { echo "ERROR: --language requires a value" >&2; usage >&2; exit 2; }
                 language="$2"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$body_file" in
  /*) ;;
  *) echo "ERROR: --body-file must be an absolute path" >&2; exit 2 ;;
esac
case "$language" in
  ja|en|auto) ;;
  *) echo "ERROR: --language must be ja, en or auto" >&2; exit 2 ;;
esac
[ -f "$body_file" ] && [ -r "$body_file" ] || { echo "ERROR: body file missing or unreadable: $body_file" >&2; exit 2; }
[ -s "$body_file" ] || { echo "ERROR: body file is empty: $body_file" >&2; exit 2; }

[ "$language" = "en" ] && exit 0

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required" >&2; exit 2; }

python3 -I - "$body_file" <<'PY'
import re
import sys

J = "\u3000-\u303f\u3040-\u30ff\u3400-\u9fff\uff00-\uffef"
JP = re.compile("[" + J + "]")

try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        lines = fh.read().split("\n")
except (OSError, UnicodeDecodeError) as exc:
    print(f"ERROR: cannot read body file: {exc}", file=sys.stderr)
    sys.exit(2)

LIST = r"^\s*(?:[-*+]|\d+\.)\s+(?:\[[ xX]\]\s+)?"
LABEL_COLON = re.compile(LIST + r"(?:\*\*[^*]*[" + J + r"][^*]*\*\*|[^:*\n]*[" + J + r"][^:*\n]*):(?=\s|$)")
LABEL_PERIOD = re.compile(LIST + r"\*\*[^*]+\*\*。")
FIXED_LINE = re.compile(r"^\s*\*\*用語\*\*:\s*$|^\s*(?:Co-Authored-By|Signed-off-by):|^\s*\|?[\s:\-|]+\|?\s*$")
CC_PREFIX = re.compile(r"^(?:feat|fix|docs|refactor|chore|test|perf|ci|build|style|revert)(?:\([^)]*\))?!?:\s")
FENCE = re.compile(r"^\s*(`{3,}(?=[^`]*$)|~{3,})")
FENCE_CLOSE = re.compile(r"^\s*(`{3,}|~{3,})\s*$")

CODE_SPAN = re.compile(r"(`+)(?:(?!\1).)+?\1")
IMG_LINK = re.compile(r"!?\[([^\]]*)\]\([^)]*\)")
URL = re.compile(r"https?://\S+")
TAG = re.compile(r"<!--.*?-->|</?[A-Za-z][^>]*>")
ASCII_PATH = re.compile(r"(?<![A-Za-z0-9_])~?(?:\.{0,2}/)?[A-Za-z0-9_.\-]+(?:/[A-Za-z0-9_.\-]+)+/?|~/[A-Za-z0-9_.\-/]+")
MARKER = re.compile(LIST + r"|^\s*#{1,6}\s+")

def strip(line):
    s = MARKER.sub("", line, count=1)
    s = CODE_SPAN.sub(" ", s)
    s = IMG_LINK.sub(r"\1", s)
    s = URL.sub(" ", s)
    s = TAG.sub(" ", s)
    s = ASCII_PATH.sub(" ", s)
    return CC_PREFIX.sub("", s, count=1)

PAREN = re.compile(r"\(([^()]*)\)")
BRACKET = re.compile(r"\[([^\[\]]*)\]")
DQUOTE = re.compile(r'"([^"]*)"')
SQUOTE = re.compile(r"(?<![A-Za-z])'([^']*)'(?![A-Za-z])")

def has_j(m, s):
    return bool(JP.search(m.group(1))) or (m.start() > 0 and bool(JP.match(s[m.start() - 1]))) \
        or (m.end() < len(s) and bool(JP.match(s[m.end()])))

def half_width_symbol(s):
    for rx in (PAREN, BRACKET, DQUOTE, SQUOTE):
        if any(has_j(m, s) for m in rx.finditer(s)):
            return True
    if re.search(r"[" + J + r"][()\[\]]|[()\[\]][" + J + r"]", s):
        return True
    if re.search(r"(?<=[" + J + r"])/|/(?=[" + J + r"])", s):
        return True
    return bool(re.search(r"\.\.\.|~|[\uff5e\uff65\u00b7\uff62\uff63\u201c\u201d]", s))

findings = []
fence = None
in_comment = False
start = 0
if lines and lines[0].strip() == "---":
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            start = i + 1
            break

for idx in range(start, len(lines)):
    line = lines[idx]
    if fence:
        close = FENCE_CLOSE.match(line)
        if close and close.group(1)[0] == fence[0] and len(close.group(1)) >= fence[1]:
            fence = None
        continue
    opened = FENCE.match(line)
    if opened:
        fence = (opened.group(1)[0], len(opened.group(1)))
        continue
    if in_comment:
        in_comment = "-->" not in line
        continue
    if line.startswith("<details>"):
        break
    if line.lstrip().startswith("<!--") and "-->" not in line:
        in_comment = True
        continue
    if FIXED_LINE.match(line):
        continue
    kinds = []
    stripped = CODE_SPAN.sub(" ", line)
    if LABEL_COLON.match(stripped):
        kinds.append("ラベルの半角コロン")
    if LABEL_PERIOD.match(stripped):
        kinds.append("ラベルの句点区切り")
    s = strip(line)
    if JP.search(s) and half_width_symbol(s):
        kinds.append("半角記号")
    for kind in kinds:
        findings.append(f"{idx + 1}:{kind}:{line}")

for f in findings:
    print(f)
sys.exit(1 if findings else 0)
PY
