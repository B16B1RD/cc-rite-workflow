#!/bin/bash
# promoted-helper-rules-pin.test.sh
#
# Static pins for the helper-defence rows in four prose references. Each pinned
# row must match a whole line exactly once inside its own section and exactly
# once in its file:
#   - bash-defensive-patterns.md "Parsing another program's output": git output format, removeprefix
#   - common-error-handling.md "Fetching to Decide Whether a Target Exists": absent vs unfetchable, cut lists
#   - gh-cli-patterns.md "Safe Issue/PR Body Updates": layer (4) re-fetch after a partial edit
#   - coding-principles.md "生成された文字列を受理する正規表現は生成側と揃える": the Rule line
#
# When this test fails:
#   Restore the row in its section, or update this test when the rule has legitimately changed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"

BASH_DOC="$PLUGIN_ROOT/references/bash-defensive-patterns.md"
ERR_DOC="$PLUGIN_ROOT/references/common-error-handling.md"
GH_DOC="$PLUGIN_ROOT/references/gh-cli-patterns.md"
CP_DOC="$PLUGIN_ROOT/skills/rite-workflow/references/coding-principles.md"

echo "=== promoted-helper-rules-pin.test.sh ==="

for doc in "$BASH_DOC" "$ERR_DOC" "$GH_DOC" "$CP_DOC"; do
  if [ ! -f "$doc" ]; then
    echo "ERROR: $doc not found" >&2
    exit 1
  fi
done

# The lines from the heading (exclusive) up to the next "## "/"### " heading or "---" rule.
section_of() { START="$2" awk '$0 == ENVIRON["START"] { f = 1; next } f && (/^##+ / || /^---$/) { exit } f { print }' "$1"; }

# pin_row label doc heading; the expected whole line is read from stdin.
pin_row() {
  local label=$1 doc=$2 heading=$3 line body in_section in_doc
  line=$(cat)
  body=$(section_of "$doc" "$heading")
  in_section=$(grep -cxF -- "$line" <<<"$body") || in_section=0
  in_doc=$(grep -cxF -- "$line" "$doc") || in_doc=0
  if [ "$in_section" = 1 ] && [ "$in_doc" = 1 ]; then
    pass "$label"
  else
    fail "$label (in section: $in_section, in file: $in_doc; want 1 and 1)"
  fi
}

H_PARSE="### Parsing another program's output"
H_FETCH="### Fetching to Decide Whether a Target Exists"
H_BODY="## Safe Issue/PR Body Updates"
H_REGEX="### 生成された文字列を受理する正規表現は生成側と揃える"

pin_row "git output parsed by a helper pins the user-config-dependent format" "$BASH_DOC" "$H_PARSE" <<'ROW'
| A helper parses `git diff` / `git status` / `git log` output whose format the user's git config changes (`core.quotePath` quotes non-ASCII paths, `diff.noprefix` / `diff.mnemonicPrefix` change the `a/` `b/` prefixes, `diff.external` replaces the diff, `color.ui=always` adds escapes) | Pin the format at the call site: `git -c core.quotePath=false diff --no-ext-diff --no-color --src-prefix=a/ --dst-prefix=b/ ...`. Output only shown to a person needs no pinning |
ROW
pin_row "a Python prefix is removed with removeprefix, not lstrip" "$BASH_DOC" "$H_PARSE" <<'ROW'
| A Python helper removes a prefix with `s.lstrip("prefix")`, which strips any leading characters in the set (`"refs/heads/hotfix".lstrip("refs/heads/")` returns `"otfix"`) | `s.removeprefix("prefix")` (Python 3.9+) |
ROW
pin_row "an existence fetch tells absent from unfetchable" "$ERR_DOC" "$H_FETCH" <<'ROW'
- A fetch whose result decides whether a target exists, where absence can be a normal outcome → treat "does not exist" (404, an empty result) as input to the decision, and "could not fetch" (authentication, permission, network, 5xx) as undecidable and stop. Do not fold both into one failure.
ROW
pin_row "a list cut at its count limit is marked and not used as evidence of absence" "$ERR_DOC" "$H_FETCH" <<'ROW'
- A list fetched with a count limit (`--limit`, stopped pagination) → keep a mark that the list was cut at the limit, and do not use a marked list as evidence that a target is absent. Fetch every page, or stop as undecidable.
ROW
pin_row "a partial body edit is followed by a re-fetch that checks the old text is gone" "$GH_DOC" "$H_BODY" <<'ROW'
| (4) Re-fetch after a partial edit | After replacing part of the body, fetch the body again and confirm the replaced old text no longer appears | Overwriting the body with lines read before the edit, which brings the old text back |
ROW
pin_row "an accepting regex matches the producer's output and the existing gate" "$CP_DOC" "$H_REGEX" <<'ROW'
**Rule**: LLM や別の helper が生成した文字列を正規表現で受理するゲートは、生成側が自然に出す形を受理し、同じ形を受理する既存のゲートの式と揃える。片方だけを厳しくすると、正しい出力が拒否される。
ROW

print_summary "promoted-helper-rules-pin.test.sh" "Re-read the four references and restore the pinned rows in their sections."
