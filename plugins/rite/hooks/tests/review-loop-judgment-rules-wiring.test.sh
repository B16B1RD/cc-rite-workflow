#!/bin/bash
# review-loop-judgment-rules-wiring.test.sh
#
# Static-pin: iterate / fix / pr-review each point to a section of
# references/review-loop-judgment-rules.md from the place where the rule is used.
#   - the pointer sits inside the expected section of the skill
#   - one line ends with "着手前に [判断規則 §N](../../references/...#slug) を Read して従う。"
#     (outside code fences / indented code / comments; nothing may follow it)
#   - slug == GitHub slug of the referenced heading (heading appears exactly once)
#   - the referenced section holds at least one table data row
# Each pin has a negative control run only when the positive pin passed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
REF="$PLUGIN_ROOT/references/review-loop-judgment-rules.md"
LINK_PREFIX='](../../references/review-loop-judgment-rules.md#'

[ -f "$REF" ] || { echo "ERROR: $REF not found" >&2; exit 1; }

TMPS=()
cleanup() { [ "${#TMPS[@]}" -eq 0 ] || rm -f "${TMPS[@]}"; }
trap cleanup EXIT

echo "=== review-loop-judgment-rules-wiring.test.sh ==="

# GitHub slug: lowercase, drop everything but word chars / hyphens / spaces, space -> hyphen
slug_of() {
  python3 -I -c 'import re,sys; print(re.sub(r"[^\w\- ]", "", sys.argv[1].lower()).replace(" ", "-"))' "$1"
}

# file ($1) の、行頭が $2 の行から $3 の行の手前までを出力する。開始行・終了行のどちらかが無ければ失敗する
section_of() {
  awk -v s="$2" -v e="$3" 'index($0, s) == 1 { on = 1; seen = 1; next } on && index($0, e) == 1 { hit = 1; exit } on { print } END { exit !(seen && hit) }' "$1"
}

# 参照先の節 ($2 の接頭辞の ## 見出し) の表に、区切り行より後のデータ行（空でないセルが 2 つ以上）が 1 行以上あること
ref_section_has_rows() {
  awk -v p="## $2" '
    index($0, p) == 1 { on = 1; next }
    on && /^## / { exit }
    on && /^\|[-: |]+\|$/ { sep = 1; next }
    on && sep && /^\|.*\|$/ { t = $0; gsub(/^\||\|$/, "", t); m = split(t, c, "|"); k = 0
      for (x = 1; x <= m; x++) { v = c[x]; gsub(/[ \t]/, "", v); if (v != "") k++ }
      if (k >= 2) n++ }
    END { exit !(n >= 1) }' "$1"
}

# 本文 ($1) の中に、フェンス・インデントコード・コメントの外で、行末が
# 「着手前に [判断規則 §N](link) を Read して従う。」で終わる行が 1 つあること ($2 = N + link)
pointer_line_ok() {
  awk -v want="着手前に [判断規則 §$2 を Read して従う。" '
    /^[ \t]*```/ { fence = !fence; next }
    fence { next }
    /<!--/ { if ($0 !~ /-->/) cmt = 1; next }
    cmt { if ($0 ~ /-->/) cmt = 0; next }
    /^(    |\t)/ { next }
    { n = length($0); w = length(want)
      if (n >= w && substr($0, n - w + 1) == want) {
        pre = substr($0, 1, n - w)
        if (pre == "" || pre ~ /、$/) ok = 1 } }
    END { exit !ok }' <<<"$1"
}

# check_pin <ref> <skill> <skill-section-start> <skill-section-end> <heading-prefix>
check_pin() {
  local ref="$1" skill="$2" start="$3" end="$4" prefix="$5" heading slug body n
  n=$(awk -v p="## ${prefix}" 'index($0, p) == 1 { n++ } END { print n + 0 }' "$ref")
  [ "$n" = "1" ] || { echo "  reason: heading '## ${prefix}' appears $n times" >&2; return 1; }
  heading=$(awk -v p="## ${prefix}" 'index($0, p) == 1 { print substr($0, 4); exit }' "$ref")
  slug=$(slug_of "$heading")
  body=$(section_of "$skill" "$start" "$end") || { echo "  reason: skill section markers not found" >&2; return 1; }
  pointer_line_ok "$body" "${prefix%%.*}${LINK_PREFIX}${slug})" || { echo "  reason: no single pointer line with link #${slug} and 'Read して従う。'" >&2; return 1; }
  ref_section_has_rows "$ref" "$prefix" || { echo "  reason: no table data row under '## ${prefix}'" >&2; return 1; }
}

pin() {
  local label="$1" skill="$2" start="$3" end="$4" prefix="$5"
  if ! check_pin "$REF" "$skill" "$start" "$end" "$prefix"; then
    fail "$label: pointer inside its section, anchor == slug(heading), Read, rows"
    return
  fi
  pass "$label: pointer inside its section, anchor == slug(heading), Read, rows"
  local mutant
  mutant=$(mktemp "${TMPDIR:-/tmp}/rite-judgment-pin-XXXXXX"); TMPS+=("$mutant")
  nc() { # nc <name> <ref> <skill>
    if ! check_pin "$2" "$3" "$start" "$end" "$prefix" 2>/dev/null; then pass "NC: $label breaks on $1"; else fail "NC: $label survives $1"; fi
  }
  awk -v p="## ${prefix}" 'index($0, p) == 1 { print $0 "X"; next } { print }' "$REF" > "$mutant"
  nc "heading rename" "$mutant" "$skill"
  awk -v p="## ${prefix}" 'index($0, p) == 1 { print; print "" } { print }' "$REF" > "$mutant"
  nc "duplicated heading" "$mutant" "$skill"
  sed 's/を Read して従う。/を Read して従う。ただし任意。/' "$skill" > "$mutant"
  nc "trailing text after Read" "$REF" "$mutant"
  sed 's/を Read して従う。/を\nRead して従う。/' "$skill" > "$mutant"
  nc "Read split across lines" "$REF" "$mutant"
  sed 's/着手前に/任意で着手前に/' "$skill" > "$mutant"
  nc "optional prefix" "$REF" "$mutant"
  sed 's/^\(.*着手前に.*Read して従う。\)$/```\n\1\n```/' "$skill" > "$mutant"
  nc "pointer inside a code fence" "$REF" "$mutant"
  grep -vF -- "$start" "$skill" > "$mutant"
  nc "losing the section start" "$REF" "$mutant"
  grep -vF -- "$end" "$skill" > "$mutant"
  nc "losing the section end" "$REF" "$mutant"
  sed 's/Read して従う。/Read しなくてよい。/' "$skill" > "$mutant"
  nc "negated Read" "$REF" "$mutant"
  sed 's/着手前に//' "$skill" > "$mutant"
  nc "dropped 着手前に" "$REF" "$mutant"
  sed 's/review-loop-judgment-rules.md#/review-loop-judgment-rules.md#x-/' "$skill" > "$mutant"
  nc "wrong anchor" "$REF" "$mutant"
  awk -v p="## ${prefix}" 'index($0, p) == 1 { print; on = 1; next } on && /^## / { on = 0 } on && /^\|/ && !/^\|-/ && !/^\| 条件 / { next } { print }' "$REF" > "$mutant"
  nc "emptied table rows" "$mutant" "$skill"
}

pin "iterate" "$PLUGIN_ROOT/skills/iterate/SKILL.md" 'ブレーカー発火は review⇄fix ループの停止 signal' '途中で止まったら flow-state' '2. iterate'
pin "fix" "$PLUGIN_ROOT/skills/fix/SKILL.md" '### 2.3 Apply the Fix' '### 2.3.1 Propagation Scan' '1. fix'
pin "pr-review" "$PLUGIN_ROOT/skills/pr-review/SKILL.md" '### 5.2 Cross-Validation' '**Same file/line**' '3. pr-review'

print_summary "review-loop-judgment-rules-wiring.test.sh"
