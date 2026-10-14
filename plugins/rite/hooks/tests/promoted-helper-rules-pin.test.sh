#!/bin/bash
# promoted-helper-rules-pin.test.sh
#
# Static pins for the helper-defence rows in four prose references. Each pinned
# row must match a whole line exactly once inside its own section and exactly
# once across the four references:
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

# The lines after the heading up to the next "## "/"### " heading or "---" rule. The heading line
# is resolved with grep -nxF (awk == on non-ASCII text is unreliable on some awks) and must be unique.
section_of() {
  local -a hits
  mapfile -t hits < <(grep -nxF -- "$2" "$1" | cut -d: -f1)
  [ "${#hits[@]}" -eq 1 ] || return 0
  awk -v start="${hits[0]}" 'NR > start && (/^##+ / || /^---$/) { exit } NR > start { print }' "$1"
}

# pin_row label doc heading; the expected whole line is read from stdin.
pin_row() {
  local label=$1 doc=$2 heading=$3 line body in_section in_refs
  line=$(cat)
  body=$(section_of "$doc" "$heading")
  in_section=$(grep -cxF -- "$line" <<<"$body") || in_section=0
  in_refs=$(cat "$BASH_DOC" "$ERR_DOC" "$GH_DOC" "$CP_DOC" | grep -cxF -- "$line") || in_refs=0
  if [ "$in_section" = 1 ] && [ "$in_refs" = 1 ]; then
    pass "$label"
  else
    fail "$label (in section: $in_section, in the four references: $in_refs; want 1 and 1)"
  fi
}

H_PARSE="### Parsing another program's output"
H_FETCH="### Fetching to Decide Whether a Target Exists"
H_BODY="## Safe Issue/PR Body Updates"
H_REGEX="### 生成された文字列を受理する正規表現は生成側と揃える"

pin_row "git output parsed by a helper pins the user-config-dependent format" "$BASH_DOC" "$H_PARSE" <<'ROW'
| A helper parses `git diff` or `git log -p` output whose format the user's git config and the repository's `.gitattributes` change (`core.quotePath` quotes non-ASCII paths, `diff.noprefix` / `diff.mnemonicPrefix` change the `a/` `b/` prefixes, `diff.external` and `diff.<driver>.textconv` replace the diff, `diff.relative` makes paths relative, `color.ui=always` adds escapes) | Pin the format at the call site: `git -c core.quotePath=false diff --no-ext-diff --no-textconv --no-relative --no-color --src-prefix=a/ --dst-prefix=b/ ...` (the same options for `git log -p`). Output only shown to a person needs no pinning |
ROW
pin_row "a Python prefix is removed with removeprefix, not lstrip" "$BASH_DOC" "$H_PARSE" <<'ROW'
| A Python helper removes a prefix with `s.lstrip("prefix")`, which strips any leading characters in the set (`"refs/heads/hotfix".lstrip("refs/heads/")` returns `"otfix"`) | `s.removeprefix("prefix")` (Python 3.9+) |
ROW
pin_row "an existence fetch tells absent from unfetchable" "$ERR_DOC" "$H_FETCH" <<'ROW'
- A fetch whose result decides whether a target exists, where absence can be a normal outcome → treat "does not exist" (the API reports the target itself as missing: a 404 or GraphQL `NOT_FOUND` for the target while its repository is visible, an empty result) as input to the decision, and "could not fetch" (authentication, permission, network, 5xx, or a 404 / `NOT_FOUND` for the repository itself, which GitHub also returns when the token cannot see a private repository) as undecidable and stop. Do not fold both into one failure.
ROW
pin_row "a list cut at its count limit is marked and not used as evidence of absence" "$ERR_DOC" "$H_FETCH" <<'ROW'
- A list fetched with a count limit (`--limit`, stopped pagination) → keep a mark that the list was cut at the limit, and do not use a marked list as evidence that a target is absent. Fetch every page, or stop as undecidable.
ROW
pin_row "a partial body edit keeps no pre-edit lines and re-fetches after the last write" "$GH_DOC" "$H_BODY" <<'ROW'
| (4) Re-fetch after a partial edit | Do not write back lines read before the edit; after the script's last write, fetch the body again and stop if the replaced old text still appears | Overwriting the body with lines read before the edit, which brings the old text back |
ROW
pin_row "an accepting regex matches the producer's output and the existing gate" "$CP_DOC" "$H_REGEX" <<'ROW'
**Rule**: LLM や別の helper が生成した文字列を正規表現で受理するゲートは、生成側が自然に出す形を受理し、同じ形を受理する既存のゲートの式と揃える。片方だけを厳しくすると、正しい出力が拒否される。
ROW

print_summary "promoted-helper-rules-pin.test.sh" "Re-read the four references and restore the pinned rows in their sections."
