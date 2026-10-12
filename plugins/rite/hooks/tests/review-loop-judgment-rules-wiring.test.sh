#!/bin/bash
# review-loop-judgment-rules-wiring.test.sh
#
# Static-pin: iterate / fix / pr-review each point to a section of
# references/review-loop-judgment-rules.md from the place where the rule is used.
#   - the pointer sits inside the expected section of the skill
#   - it is a link of the exact form ](../../references/...#slug) and says Read
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

# file ($1) の、行頭が $2 の行から $3 の行の手前までを出力する
section_of() {
  awk -v s="$2" -v e="$3" 'index($0, s) == 1 { on = 1; next } on && index($0, e) == 1 { exit } on { print }' "$1"
}

# 参照先の節 ($4 の接頭辞の ## 見出し) の表にデータ行が 1 行以上あること
ref_section_has_rows() {
  awk -v p="## $1" 'index($0, p) == 1 { on = 1; next } on && /^## / { exit } on && /^\| / && !/^\| 条件 / { n++ } END { exit !(n >= 1) }' "$REF"
}

# check_pin <ref> <skill> <skill-section-start> <skill-section-end> <heading-prefix>
check_pin() {
  local ref="$1" skill="$2" start="$3" end="$4" prefix="$5" heading slug body
  [ "$(grep -cF -- "## ${prefix}" "$ref")" = "1" ] || return 1
  heading=$(grep -F -- "## ${prefix}" "$ref" | sed 's/^## //')
  slug=$(slug_of "$heading")
  body=$(section_of "$skill" "$start" "$end")
  grep -qF -- "${LINK_PREFIX}${slug})" <<<"$body" || return 1
  grep -qF -- 'Read して従う' <<<"$body" || return 1
  ref_section_has_rows "$prefix"
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
  # 見出しを改名すると落ちる
  awk -v p="## ${prefix}" 'index($0, p) == 1 { print $0 "X"; next } { print }' "$REF" > "$mutant"
  if ! check_pin "$mutant" "$skill" "$start" "$end" "$prefix"; then pass "NC: $label breaks on heading rename"; else fail "NC: $label survives heading rename"; fi
  # ポインタを節の外へ出す (節の開始行を消す) と落ちる
  grep -vF -- "$start" "$skill" > "$mutant"
  if ! check_pin "$REF" "$mutant" "$start" "$end" "$prefix"; then pass "NC: $label breaks when the section start is gone"; else fail "NC: $label survives losing its section"; fi
}

pin "iterate" "$PLUGIN_ROOT/skills/iterate/SKILL.md" 'ブレーカー発火は review⇄fix ループの停止 signal' '途中で止まったら flow-state' '2. iterate'
pin "fix" "$PLUGIN_ROOT/skills/fix/SKILL.md" '### 2.3 Apply the Fix' '### 2.3.1 Propagation Scan' '1. fix'
pin "pr-review" "$PLUGIN_ROOT/skills/pr-review/SKILL.md" '### 5.2 Cross-Validation' '**Same file/line**' '3. pr-review'

print_summary "review-loop-judgment-rules-wiring.test.sh"
