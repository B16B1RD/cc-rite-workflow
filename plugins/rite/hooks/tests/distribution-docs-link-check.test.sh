#!/bin/bash
# Tests for hooks/scripts/distribution-docs-link-check.sh
#
# The checker is the recurrence guard for marketplace 404s: a relative
# markdown link that escapes plugins/rite/ is invisible at install
# destinations that do not ship the development tree. Without a helper-level
# pin, emptying LINK_RE still leaves the suite green.
#
# Convention: mktemp sandbox, no network, no gh, GNU/BSD portable. The checker
# resolves targets under --repo-root, so no git repo is needed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"

SCRIPT="$SCRIPT_DIR/../scripts/distribution-docs-link-check.sh"
REPO_ROOT="$(_helpers_resolve_repo_root "$SCRIPT_DIR")"
LINT_SKILL="$REPO_ROOT/plugins/rite/skills/lint/SKILL.md"

echo "=== distribution-docs-link-check.sh tests ==="

if [ ! -f "$SCRIPT" ]; then
  echo "ERROR: $SCRIPT not found" >&2
  exit 1
fi

SANDBOX="$(make_plain_sandbox)"
CONSUMER_SANDBOX="$(make_plain_sandbox)"
cleanup() {
  [ -n "${SANDBOX:-}" ] && chmod -R u+rwX "$SANDBOX" 2>/dev/null
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
  [ -n "${CONSUMER_SANDBOX:-}" ] && rm -rf "$CONSUMER_SANDBOX"
}
trap 'rc=$?; cleanup; exit $rc' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

DEMO="$SANDBOX/plugins/rite/skills/demo"
mkdir -p "$DEMO" "$SANDBOX/plugins/rite/hooks/tests"
OUT="$SANDBOX/out.txt"
ERR="$SANDBOX/err.txt"

run_on() {
  bash "$SCRIPT" --repo-root "$SANDBOX" --quiet "$@" >"$OUT" 2>"$ERR"
  echo $?
}

# --- lint Count line (row 20) is the contract this suite pins -----------------
# A wording drift here would show up as "warning (0 findings)" in /rite:lint
# rather than as a failure, so the cell is read from the table rather than
# copied as a second SoT.
COUNT_CELL=$(awk -F'`' '/distribution-docs-link-check\.sh/ {
  for (i = 1; i <= NF; i++) {
    if ($i ~ /Total distribution-docs-link findings/) { print $i; exit }
  }
}' "$LINT_SKILL")
if [ "$COUNT_CELL" = 'Total distribution-docs-link findings: (\d+)' ]; then
  pass "lint table Count line is the documented Total regex"
else
  fail "lint table Count line drifted — got: ${COUNT_CELL:-<empty>}"
fi

# --- (1) hop to docs/ is a finding, with tag / file:line / dest --------------
# From plugins/rite/skills/demo, ../../../../docs/SPEC.md resolves to repo-root
# docs/, which is outside the plugin. rc=1 alone is any failure; the finding
# shape is the pin.
printf 'Prose.\n\n[spec](../../../../docs/SPEC.md)\n' > "$DEMO/hop.md"
rc=$(run_on --target plugins/rite/skills/demo/hop.md)
assert "(1) docs hop exits 1" "1" "$rc"
assert_grep "(1) finding is tagged" "$OUT" '\[distribution-docs-link\]'
assert_grep "(1) finding carries file:line" "$OUT" 'hop\.md:3:'
assert_grep "(1) finding names the destination" "$OUT" 'docs/SPEC\.md'

# Sibling hop (not docs/) must be the same shape — the 404 is any escape past
# plugins/rite/, not a docs/-only rule.
printf 'Prose.\n\n[readme](../../../../README.md)\n' > "$DEMO/sibling-hop.md"
rc=$(run_on --target plugins/rite/skills/demo/sibling-hop.md)
assert "(1b) sibling hop exits 1" "1" "$rc"
assert_grep "(1b) sibling hop is tagged" "$OUT" '\[distribution-docs-link\]'
assert_grep "(1b) sibling hop names README.md" "$OUT" 'README\.md'

# --- (2) plugin-internal relative is clean, with (1) as positive control -----
# A file with no links would also exit 0, so the internal link must exist and
# a hop in the same run must still be reported.
printf '[ok](./sibling.md)\n' > "$DEMO/internal.md"
rc=$(run_on --target plugins/rite/skills/demo/internal.md --target plugins/rite/skills/demo/hop.md)
assert "(2) mixed internal+hop exits 1" "1" "$rc"
assert_grep "(2) hop remains a finding in the mixed run" "$OUT" 'hop\.md:3:'
assert_not_grep "(2) internal relative is not a finding" "$OUT" 'internal\.md'
rc=$(run_on --target plugins/rite/skills/demo/internal.md)
assert "(2) internal-only exits 0" "0" "$rc"
assert_not_grep "(2) internal-only has no finding lines" "$OUT" '\[distribution-docs-link\]'

# --- (3) fence skip is compositional: inner hop missed, outer hop found ------
{
  printf '```md\n[hidden](../../../../docs/SPEC.md)\n```\n'
  printf '[visible](../../../../docs/SPEC.md)\n'
} > "$DEMO/fence-mix.md"
rc=$(run_on --target plugins/rite/skills/demo/fence-mix.md)
assert "(3) fence-mix exits 1" "1" "$rc"
assert_grep "(3) unfenced hop is found" "$OUT" 'fence-mix\.md:4:'
assert_not_grep "(3) fenced hop is not a finding" "$OUT" 'fence-mix\.md:2:'
printf '```md\n[hidden](../../../../docs/SPEC.md)\n```\n' > "$DEMO/fence-only.md"
rc=$(run_on --target plugins/rite/skills/demo/fence-only.md)
assert "(3b) fence-only hop exits 0" "0" "$rc"

# --- (4) skip-if-no-target pair: fail-closed vs clean skip -------------------
rc=0
out=$(bash "$SCRIPT" --all --repo-root "$CONSUMER_SANDBOX" --quiet 2>&1) || rc=$?
assert "(4) --all without plugins/rite exits 2" "2" "$rc"
if printf '%s' "$out" | grep -qF 'plugins/rite does not exist'; then
  pass "(4) missing plugin root is an ERROR"
else
  fail "(4) missing plugin root produced no ERROR — got: $out"
fi
rc=0
out=$(bash "$SCRIPT" --all --skip-if-no-target --repo-root "$CONSUMER_SANDBOX" --quiet 2>&1) || rc=$?
assert "(4) --skip-if-no-target exits 0" "0" "$rc"
if printf '%s' "$out" | grep -qF 'not applicable'; then
  pass "(4) skip names not applicable"
else
  fail "(4) skip notice missing — got: $out"
fi

# --- (5) unbalanced fence is not a clean bill --------------------------------
printf 'Prose.\n\n```md\n[x](../../../../docs/SPEC.md)\n' > "$DEMO/unbalanced.md"
rc=$(run_on --target plugins/rite/skills/demo/unbalanced.md)
assert "(5) unbalanced fence exits 2" "2" "$rc"
assert_grep "(5) WARNING names unbalanced code fence" "$ERR" 'unbalanced code fence'
assert_grep "(5) unscannable is not a clean bill" "$ERR" 'could not be scanned'
assert_not_grep "(5) unbalanced does not emit a guessed finding" "$OUT" '\[distribution-docs-link\]'

# Findings win the exit code when an unscannable file shares --all with a hop.
# Folding "did not look" into "found nothing" is the defect class this rc=2
# exists to prevent; findings still have to surface as rc=1.
rc=$(run_on --all)
assert "(5b) --all with hop + unbalanced exits 1 (findings win)" "1" "$rc"
assert_grep "(5b) hop finding remains" "$OUT" '\[distribution-docs-link\]'
assert_grep "(5b) unscannable line remains on findings-win" "$ERR" 'could not be scanned'

# --- (6) real repo corpus + tests/ exclusion ---------------------------------
# --quiet / --skip-if-no-target would hide a zero-file walk. Scanning N with
# N>=1 is the evidence the corpus was actually looked at.
rc=0
bash "$SCRIPT" --all --repo-root "$REPO_ROOT" >/dev/null 2>"$SANDBOX/real.err" || rc=$?
real_err=$(cat "$SANDBOX/real.err")
assert "(6) real repo --all exits 0" "0" "$rc"
if printf '%s' "$real_err" | grep -qE 'Scanning [1-9][0-9]* file\(s\)'; then
  pass "(6) real repo scanned N>=1 files"
else
  fail "(6) Scanning N missing or zero — got: $real_err"
fi
if printf '%s' "$real_err" | grep -qF 'unbalanced code fence'; then
  fail "(6) real repo has an unscannable file: $real_err"
else
  pass "(6) no real-repo file is skipped for an unbalanced fence"
fi

# Plant a hop under tests/ and under skills/. --all must report the skills hop
# and must not walk tests/ (fixtures are out of scope).
printf '[planted](../../../../docs/SPEC.md)\n' > "$SANDBOX/plugins/rite/hooks/tests/planted.md"
rc=$(run_on --all)
assert "(6b) sandbox --all still exits 1 from skills hop" "1" "$rc"
assert_grep "(6b) skills hop is found by --all" "$OUT" 'skills/demo/hop\.md'
assert_not_grep "(6b) tests/ hop is not scanned" "$OUT" 'hooks/tests/planted'

# --- (7) Total line, --quiet polarity, stdout/stderr split, scheme skip ------
rc=$(run_on --target plugins/rite/skills/demo/internal.md)
assert_grep "(7) Total line is on stderr" "$ERR" 'Total distribution-docs-link findings: [0-9]+'
assert_not_grep "(7) Total line is not on stdout" "$OUT" 'Total distribution-docs-link findings:'
# The lint cell uses Python-style (\d+). Portable ERE is [0-9]+; pin both the
# cell literal and a line that cell would extract.
if printf '%s\n' "$(cat "$ERR")" | grep -qE 'Total distribution-docs-link findings: [0-9]+' \
  && [ "$COUNT_CELL" = 'Total distribution-docs-link findings: (\d+)' ]; then
  pass "(7) stderr Total matches the lint Count line regex"
else
  fail "(7) stderr Total does not match lint Count line — err=$(cat "$ERR") cell=$COUNT_CELL"
fi

# This detector keeps the Total line on stderr under --quiet so /rite:lint
# can still count. dollar-zero-check.sh suppresses it; do not copy that polarity.
rc=0
bash "$SCRIPT" --repo-root "$SANDBOX" --quiet \
  --target plugins/rite/skills/demo/internal.md >"$OUT" 2>"$ERR" || rc=$?
assert "(7) --quiet internal still exits 0" "0" "$rc"
assert_grep "(7) --quiet still emits Total on stderr" "$ERR" 'Total distribution-docs-link findings: 0'
assert_not_grep "(7) --quiet does not put Total on stdout" "$OUT" 'Total distribution-docs-link findings:'

printf '[a](https://example.com/docs)\n[b](mailto:x@y.z)\n[c](#only-frag)\n[d]({placeholder}/docs)\n[e](../../../../docs/SPEC.md)\n' \
  > "$DEMO/schemes.md"
rc=$(run_on --target plugins/rite/skills/demo/schemes.md)
assert "(7) schemes+hop exits 1" "1" "$rc"
assert_grep "(7) hop in schemes file is found" "$OUT" 'schemes\.md:5:'
assert_not_grep "(7) https is not a finding" "$OUT" 'https://'
assert_not_grep "(7) mailto is not a finding" "$OUT" 'mailto:'
assert_not_grep "(7) fragment-only is not a finding" "$OUT" 'only-frag'
assert_not_grep "(7) placeholder href is not a finding" "$OUT" 'placeholder'

# --- glob name: run-tests.sh discovers *.test.sh; a non-zero file fails the runner
case "$(basename "$0")" in
  *.test.sh) pass "this file matches the run-tests.sh *.test.sh glob" ;;
  *) fail "this file is not named *.test.sh so run-tests.sh will never see it" ;;
esac
if grep -q 'if \[ ${#FAILED_TESTS\[@\]} -gt 0 \]; then' "$SCRIPT_DIR/run-tests.sh" \
  && grep -q 'exit 1' "$SCRIPT_DIR/run-tests.sh"; then
  pass "run-tests.sh exits 1 when any discovered file fails"
else
  fail "run-tests.sh no longer fails the suite on a non-zero test file"
fi

print_summary "$(basename "$0")" \
  "If the detector stops flagging plugin-escaping relative links, or --quiet swallows the Total line the lint table counts, marketplace hops return silently. Keep the pins; do not copy dollar-zero's --quiet polarity."
